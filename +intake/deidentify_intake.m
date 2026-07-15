function info = deidentify_intake(src_dir, codename, opts)
%INTAKE.DEIDENTIFY_INTAKE  Phase-0 intake: de-identify one raw DICOM study
%   into the regulated store and record a de-identified provenance row.
%   This is the gate that makes everything downstream (annotation, cloud
%   training, publication) PHI-safe.
%
%   INFO = intake.deidentify_intake(SRC_DIR, CODENAME)
%   INFO = intake.deidentify_intake(SRC_DIR, CODENAME, OPTS)
%
%   Pipeline (never mutates SRC_DIR):
%     1. Copy the study to a fresh output folder (per codename).
%     2. Scrub PHI on the COPY — engine `dicomanon` (default; MATLAB-
%        native, DICOM PS3.15 profile, no Python) or `dicognito` (via
%        `preprocess.anonymize_dicom_dir`, for cohort-consistent UID
%        re-mapping across many studies). PatientName/ID are re-mapped to
%        CODENAME; new Study/Series/SOP UIDs are generated consistently so
%        the volume still loads as one series.
%     3. Independently VERIFY the result with `intake.verify_deid`, using
%        the originals held only in memory. On any residual PHI the output
%        is quarantined (renamed `*__QUARANTINE_FAILED`) and the call
%        errors — a failed scrub can never be mistaken for a clean one.
%     4. Append one de-identified row to the provenance manifest
%        (`intake.append_manifest`) — codename + geometry + labels only.
%
%   The codename<->real-identity key is NEVER produced or written by this
%   function. CODENAME must match `JohnDoeN`; a real name is rejected so a
%   mistaken PHI value cannot flow into the store or the manifest.
%
%   Inputs
%     SRC_DIR   folder of the raw study's DICOM files (read-only here).
%     CODENAME  `JohnDoeN` pseudonym (IRB-controlled mapping stays offline).
%     OPTS (all optional):
%       .out_root      parent for the de-identified copy
%                      (default: <SRC_DIR>/../<CODENAME>_deid). Point this
%                      at the IRB-approved regulated store in real use.
%       .manifest_path provenance CSV (default: <out_root>/../cohort_manifest.csv).
%       .engine        'dicomanon' (default) | 'dicognito'.
%       .python        interpreter with dicognito (engine='dicognito' only).
%       .salt          dicognito UID seed (engine='dicognito' only).
%       .pathology     label for the manifest (e.g. 'AAA', 'normal').
%       .phase         'pre-op' | 'post-op' (cohort scope column).
%       .split         'train' | 'val' | 'test' | 'holdout'.
%       .contrast_phase e.g. 'arterial', 'non-contrast' (best-effort;
%                      copied to the manifest, not inferred).
%       .to_nifti      true to also convert the de-identified DICOM to a
%                      training-ready NIfTI via `dcm2niix` (default false).
%                      Non-fatal: if dcm2niix is absent the intake still
%                      succeeds and INFO.nifti_paths is empty (a warning is
%                      printed). The `+library/+aortaseg24` loader ingests
%                      the resulting NIfTI.
%       .dcm2niix      path to the dcm2niix binary (default: `which dcm2niix`).
%       .nifti_gz      true (default) to emit compressed .nii.gz.
%       .forbid_private true (default) fail on residual private tags.
%       .overwrite     true to replace an existing output folder
%                      (default false -> error if it exists).
%       .dry_run       true to plan + print without writing (engine work
%                      is skipped; returns the intended paths).
%
%   Returns INFO:
%     .codename .src_dir .out_dir .manifest_path .engine
%     .n_files .verify (the intake.verify_deid report) .manifest_row
%     .nifti_paths (cellstr of converted NIfTI, empty unless to_nifti)
%     .ok (true on a clean, verified, manifested intake).
%
%   RESEARCH USE ONLY. Governed by the approved IRB protocol. Run this on
%   real patient DICOM only inside the regulated environment; the repo and
%   its tests use synthetic DICOM exclusively.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        src_dir  (1,:) char
        codename (1,:) char
        opts     (1,1) struct = struct()
    end
    opts = defaults(opts);

    % --- guard rails ----------------------------------------------------
    if isempty(regexp(codename, '^JohnDoe\d+$', 'once'))
        error('intake:deidentify_intake:BadCodename', ...
            ['CODENAME must match JohnDoeN (e.g. JohnDoe3); got "%s". Real ' ...
             'patient names/MRNs must never be passed here — the codename' ...
             '<->identity key stays offline in the regulated store.'], codename);
    end
    if ~isfolder(src_dir)
        error('intake:deidentify_intake:NoSource', 'Source not found: %s', src_dir);
    end
    if ~ismember(opts.engine, {'dicomanon', 'dicognito'})
        error('intake:deidentify_intake:BadEngine', ...
            'engine must be ''dicomanon'' or ''dicognito''; got ''%s''.', opts.engine);
    end

    % Resolve default paths now that src_dir/codename are known. Real use
    % should point out_root at the IRB-approved regulated store.
    src_parent = fileparts(strip_trailing_sep(src_dir));
    if isempty(opts.out_root)
        opts.out_root = fullfile(src_parent, [codename '_deid']);
    end
    if isempty(opts.manifest_path)
        opts.manifest_path = fullfile(fileparts(strip_trailing_sep(opts.out_root)), ...
            'cohort_manifest.csv');
    end

    src_files = list_dicom_files(src_dir);
    if isempty(src_files)
        error('intake:deidentify_intake:NoDicom', ...
            'No readable DICOM files under: %s', src_dir);
    end

    out_dir = fullfile(opts.out_root);
    info = struct('codename', codename, 'src_dir', src_dir, ...
        'out_dir', out_dir, 'manifest_path', opts.manifest_path, ...
        'engine', opts.engine, 'n_files', numel(src_files), ...
        'verify', struct(), 'manifest_row', struct(), ...
        'nifti_paths', {{}}, 'ok', false);

    if opts.dry_run
        fprintf(['[deidentify_intake] DRY RUN\n  src:      %s (%d files)\n' ...
                 '  out:      %s\n  engine:   %s\n  manifest: %s\n'], ...
            src_dir, numel(src_files), out_dir, opts.engine, opts.manifest_path);
        info.ok = true;
        return;
    end

    if isfolder(out_dir)
        if opts.overwrite
            rmdir(out_dir, 's');
        else
            error('intake:deidentify_intake:OutExists', ...
                ['Output folder already exists: %s\nPass opts.overwrite=true ' ...
                 'to replace it.'], out_dir);
        end
    end

    % --- capture originals (IN MEMORY ONLY) for the verify pass, and the
    %     de-identified geometry we still want for the manifest ----------
    orig = capture_originals(src_files{1});
    geom = capture_geometry(src_files{1}, numel(src_files));

    % --- scrub ----------------------------------------------------------
    switch opts.engine
        case 'dicomanon'
            scrub_with_dicomanon(src_files, src_dir, out_dir, codename);
        case 'dicognito'
            copy_tree(src_dir, out_dir);
            preprocess.anonymize_dicom_dir(out_dir, ...
                struct('python', opts.python, 'salt', opts.salt));
            % dicognito re-maps names to consistent pseudonyms and keeps
            % study/series UID relationships intact — we deliberately do
            % NOT re-run dicomanon here (that would regenerate UIDs and
            % split the series). verify_deid confirms the scrub via the
            % in-memory originals; the codename is recorded in the folder
            % name + manifest rather than forced into the header.
    end

    % --- independent verification --------------------------------------
    vreport = intake.verify_deid(out_dir, struct( ...
        'orig', orig, 'codename', codename, ...
        'forbid_private', opts.forbid_private));
    info.verify = vreport;

    if ~vreport.ok
        quarantine = [out_dir '__QUARANTINE_FAILED'];
        if isfolder(quarantine); rmdir(quarantine, 's'); end
        movefile(out_dir, quarantine);
        info.out_dir = quarantine;
        error('intake:deidentify_intake:VerifyFailed', ...
            ['De-identification VERIFY FAILED (%d issue(s)) — output ' ...
             'quarantined at:\n  %s\nResidual: %s\nNothing was written to ' ...
             'the manifest.'], numel(vreport.residual), quarantine, ...
             strjoin(vreport.residual, ' | '));
    end

    % --- manifest row (de-identified provenance) -----------------------
    row = geom;
    row.codename       = codename;
    row.contrast_phase = opts.contrast_phase;
    row.pathology      = opts.pathology;
    row.phase          = opts.phase;
    row.split          = opts.split;
    row.deid_engine    = opts.engine;
    row.n_files        = vreport.n_files;
    row.deid_utc       = utc_stamp();
    intake.append_manifest(row, opts.manifest_path);
    info.manifest_row = row;

    % --- optional: convert the de-identified DICOM to NIfTI ------------
    if opts.to_nifti
        info.nifti_paths = convert_to_nifti(out_dir, codename, ...
            opts.dcm2niix, opts.nifti_gz);
    end

    info.ok = true;
    fprintf(['[deidentify_intake] OK  %s: %d files de-identified (%s), ' ...
             'verified clean, manifest updated%s.\n'], ...
        codename, vreport.n_files, opts.engine, ...
        nifti_note(opts.to_nifti, info.nifti_paths));
end

% =========================================================================
function opts = defaults(opts)
    if ~isfield(opts, 'out_root');       opts.out_root       = ''; end
    if ~isfield(opts, 'manifest_path');  opts.manifest_path  = ''; end
    if ~isfield(opts, 'engine');         opts.engine         = 'dicomanon'; end
    if ~isfield(opts, 'python');         opts.python         = ''; end
    if ~isfield(opts, 'salt');           opts.salt           = ''; end
    if ~isfield(opts, 'pathology');      opts.pathology      = ''; end
    if ~isfield(opts, 'phase');          opts.phase          = ''; end
    if ~isfield(opts, 'split');          opts.split          = ''; end
    if ~isfield(opts, 'contrast_phase'); opts.contrast_phase = ''; end
    if ~isfield(opts, 'to_nifti');       opts.to_nifti       = false; end
    if ~isfield(opts, 'dcm2niix');       opts.dcm2niix       = ''; end
    if ~isfield(opts, 'nifti_gz');       opts.nifti_gz       = true; end
    if ~isfield(opts, 'forbid_private'); opts.forbid_private = true; end
    if ~isfield(opts, 'overwrite');      opts.overwrite      = false; end
    if ~isfield(opts, 'dry_run');        opts.dry_run        = false; end
end

function scrub_with_dicomanon(src_files, src_root, out_dir, codename)
% Per-file dicomanon with CONSISTENT new UIDs so the study still loads as
% one series: one StudyInstanceUID for the study, one SeriesInstanceUID
% per source series, one FrameOfReferenceUID per source FoR, a fresh
% SOPInstanceUID per instance. Geometry needed for volume assembly is
% kept; identifiers are re-mapped to the codename.
    study_uid = dicomuid();
    series_map = containers.Map('KeyType', 'char', 'ValueType', 'char');
    for_map    = containers.Map('KeyType', 'char', 'ValueType', 'char');

    keep = { 'Modality', 'Manufacturer', 'ManufacturerModelName', ...
             'SeriesDescription', 'Rows', 'Columns', 'PixelSpacing', ...
             'SliceThickness', 'SpacingBetweenSlices', 'SliceLocation', ...
             'ImagePositionPatient', 'ImageOrientationPatient', ...
             'PatientPosition', 'KVP', 'ContrastBolusAgent', ...
             'RescaleSlope', 'RescaleIntercept', 'RescaleType', ...
             'BitsAllocated', 'BitsStored', 'HighBit', 'PixelRepresentation', ...
             'SamplesPerPixel', 'PhotometricInterpretation', ...
             'WindowCenter', 'WindowWidth' };

    for k = 1:numel(src_files)
        f = src_files{k};
        try
            hdr = dicominfo(f, 'UseVRHeuristic', false);
        catch
            continue;   % not DICOM
        end
        src_series = char_or(hdr, 'SeriesInstanceUID', ['S' num2str(k)]);
        if ~isKey(series_map, src_series)
            series_map(src_series) = dicomuid();
        end
        upd = struct();
        upd.PatientName      = codename;
        upd.PatientID        = codename;
        % dicomanon's default profile blanks the direct identifiers
        % (accession, institution, physicians, device serials, DOB) but
        % KEEPS study/series/acquisition DATES and TIMES. Strip them
        % explicitly — a single-timepoint pre-op cohort needs no dates,
        % and a residual StudyDate is PHI (re-identification vector).
        for dt = { 'StudyDate', 'SeriesDate', 'AcquisitionDate', ...
                   'ContentDate', 'OverlayDate', 'CurveDate', ...
                   'StudyTime', 'SeriesTime', 'AcquisitionTime', ...
                   'ContentTime', 'OverlayTime', 'CurveTime' }
            if isfield(hdr, dt{1}); upd.(dt{1}) = ''; end
        end
        upd.StudyInstanceUID = study_uid;
        upd.SeriesInstanceUID = series_map(src_series);
        upd.SOPInstanceUID   = dicomuid();
        if isfield(hdr, 'FrameOfReferenceUID') && ~isempty(hdr.FrameOfReferenceUID)
            src_for = char(string(hdr.FrameOfReferenceUID));
            if ~isKey(for_map, src_for); for_map(src_for) = dicomuid(); end
            upd.FrameOfReferenceUID = for_map(src_for);
        end

        rel = relpath(src_root, f);
        of  = fullfile(out_dir, rel);
        od  = fileparts(of);
        if ~isfolder(od); mkdir(od); end

        dicomanon(f, of, 'update', upd, 'keep', keep, 'WritePrivate', false);
    end
end

function orig = capture_originals(a_file)
% Read the source identifiers into memory ONLY, for the verify comparison.
% This struct is never persisted and is discarded when the call returns.
    orig = struct();
    try
        hdr = dicominfo(a_file, 'UseVRHeuristic', false);
    catch
        return;
    end
    tags = { 'PatientName', 'PatientID', 'AccessionNumber', 'InstitutionName', ...
             'ReferringPhysicianName', 'StudyDate', 'PatientBirthDate', ...
             'DeviceSerialNumber', 'StationName' };
    for t = 1:numel(tags)
        if isfield(hdr, tags{t}); orig.(tags{t}) = hdr.(tags{t}); end
    end
end

function g = capture_geometry(a_file, n_files)
% De-identified geometry/scanner fields for the manifest (NOT PHI).
    g = struct('modality', '', 'manufacturer', '', 'model', '', ...
        'series_description', '', 'rows', '', 'cols', '', ...
        'n_slices', n_files, 'pixel_spacing_mm', '', 'slice_thickness_mm', '', ...
        'fov_mm', '');
    try
        hdr = dicominfo(a_file, 'UseVRHeuristic', false);
    catch
        return;
    end
    g.modality           = char_or(hdr, 'Modality', '');
    g.manufacturer       = char_or(hdr, 'Manufacturer', '');
    g.model              = char_or(hdr, 'ManufacturerModelName', '');
    g.series_description = char_or(hdr, 'SeriesDescription', '');
    if isfield(hdr, 'Rows');    g.rows = double(hdr.Rows); end
    if isfield(hdr, 'Columns'); g.cols = double(hdr.Columns); end
    if isfield(hdr, 'PixelSpacing') && ~isempty(hdr.PixelSpacing)
        ps = double(hdr.PixelSpacing(:).');
        g.pixel_spacing_mm = strjoin(arrayfun(@(x) num2str(x, '%.4g'), ps, ...
            'UniformOutput', false), 'x');
        if ~isempty(g.rows) && ~isempty(g.cols)
            g.fov_mm = sprintf('%.0fx%.0f', ps(1) * double(hdr.Rows), ...
                ps(min(2, numel(ps))) * double(hdr.Columns));
        end
    end
    if isfield(hdr, 'SliceThickness') && ~isempty(hdr.SliceThickness)
        g.slice_thickness_mm = double(hdr.SliceThickness);
    end
end

function v = char_or(s, name, default)
    if isfield(s, name) && ~isempty(s.(name))
        x = s.(name);
        if isstruct(x)                       % person-name struct
            parts = struct2cell(x);
            parts = parts(cellfun(@(c) ischar(c) || isstring(c), parts));
            v = strtrim(strjoin(cellfun(@char, parts, 'UniformOutput', false), '^'));
        else
            v = char(string(x));
        end
    else
        v = default;
    end
end

function copy_tree(src, dst)
    if ~isfolder(dst); mkdir(dst); end
    copyfile(src, dst);
end

function nii = convert_to_nifti(dicom_dir, codename, bin, gz)
% Convert a de-identified DICOM folder to training-ready NIfTI via
% dcm2niix. Non-fatal: a missing binary or a failed conversion warns and
% returns {} — the de-identification itself already succeeded and is the
% deliverable that matters. Only de-identified DICOM is ever passed here,
% so the NIfTI inherits the scrubbed headers (no PHI).
    nii = {};
    if isempty(bin)
        [rc, w] = system('which dcm2niix 2>/dev/null');
        if rc ~= 0 || isempty(strtrim(w))
            warning('intake:deidentify_intake:NoDcm2niix', ...
                ['to_nifti requested but dcm2niix is not on PATH — skipping ' ...
                 'NIfTI conversion (de-identification succeeded). Install ' ...
                 'dcm2niix, or pass opts.dcm2niix, to enable it.']);
            return;
        end
        bin = strtrim(w);
    elseif ~isfile(bin)
        warning('intake:deidentify_intake:NoDcm2niix', ...
            'opts.dcm2niix does not exist: %s — skipping NIfTI conversion.', bin);
        return;
    end

    zflag = 'n'; if gz; zflag = 'y'; end
    cmd = sprintf('"%s" -z %s -f "%s" -o "%s" "%s"', bin, zflag, ...
        codename, dicom_dir, dicom_dir);
    [rc, out] = system(cmd);
    if rc ~= 0
        warning('intake:deidentify_intake:Dcm2niixFailed', ...
            'dcm2niix failed (rc=%d):\n%s\nDe-identification still succeeded.', ...
            rc, out);
        return;
    end
    found = [dir(fullfile(dicom_dir, [codename '*.nii'])); ...
             dir(fullfile(dicom_dir, [codename '*.nii.gz']))];
    nii = arrayfun(@(x) fullfile(x.folder, x.name), found, ...
        'UniformOutput', false);
end

function s = nifti_note(to_nifti, paths)
    if ~to_nifti
        s = '';
    elseif isempty(paths)
        s = ' (NIfTI skipped)';
    else
        s = sprintf(' (+ %d NIfTI)', numel(paths));
    end
end

function p = strip_trailing_sep(p)
    p = char(p);
    while ~isempty(p) && (p(end) == '/' || p(end) == '\')
        p(end) = [];
    end
end

function r = relpath(root, f)
    root = char(root); f = char(f);
    if ~isempty(root) && startsWith(f, root)
        r = f(numel(root) + 1:end);
        r = regexprep(r, '^[/\\]+', '');
    else
        [~, nm, ext] = fileparts(f);
        r = [nm ext];
    end
    if isempty(r); [~, nm, ext] = fileparts(f); r = [nm ext]; end
end

function files = list_dicom_files(root)
    f = dir(fullfile(root, '**', '*'));
    f = f(~[f.isdir]);
    keep = false(numel(f), 1);
    for k = 1:numel(f)
        nm = f(k).name;
        if startsWith(nm, '._') || startsWith(nm, '.'); continue; end
        keep(k) = true;
    end
    f = f(keep);
    files = arrayfun(@(x) fullfile(x.folder, x.name), f, 'UniformOutput', false);
end

function s = utc_stamp()
    try
        s = char(datetime('now', 'TimeZone', 'UTC', ...
            'Format', 'yyyy-MM-dd''T''HH:mm:ss''Z'''));
    catch
        s = datestr(now, 'yyyy-mm-ddTHH:MM:SS');  %#ok<DATST,TNOW>
    end
end
