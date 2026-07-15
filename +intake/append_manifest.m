function manifest_path = append_manifest(row, manifest_path)
%INTAKE.APPEND_MANIFEST  Append one de-identified provenance row to the
%   cohort manifest CSV.
%
%   PATH = intake.append_manifest(ROW, MANIFEST_PATH)
%
%   The manifest is the Phase-0 provenance record for the learned-
%   segmentation cohort: one row per ingested study, carrying only
%   NON-PHI fields (codename + image geometry + user-assigned labels).
%   It is the artifact that lets the cohort be reasoned about (splits,
%   pathology mix, scanner spread) without ever touching the regulated
%   store.
%
%   ROW is a struct whose fields are drawn from the canonical column set
%   below; missing fields are written empty. Two guards keep the manifest
%   de-identified by construction:
%     1. `codename` MUST match `JohnDoeN` — a real name is rejected, so a
%        mistaken PHI value can never land in the file.
%     2. Any field whose NAME looks like a patient identifier
%        (PatientName, MRN, AccessionNumber, DOB, InstitutionName, ...)
%        with a non-empty value is refused. The codename<->real-ID key is
%        IRB-controlled and lives only in the regulated store, never here.
%
%   Canonical columns (fixed order; the file is plain CSV so it opens in
%   Excel / pandas / readtable):
%     codename, modality, manufacturer, model, series_description,
%     rows, cols, n_slices, pixel_spacing_mm, slice_thickness_mm, fov_mm,
%     contrast_phase, pathology, phase, split, deid_engine, n_files,
%     deid_utc
%
%   The header is written once (when the file is new/empty); subsequent
%   calls append a single line, so the manifest grows one study at a time
%   and is safe to re-open between runs.
%
%   RESEARCH USE ONLY. Governed by the approved IRB protocol.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        row           (1,1) struct
        manifest_path (1,:) char
    end

    COLS = { 'codename', 'modality', 'manufacturer', 'model', ...
             'series_description', 'rows', 'cols', 'n_slices', ...
             'pixel_spacing_mm', 'slice_thickness_mm', 'fov_mm', ...
             'contrast_phase', 'pathology', 'phase', 'split', ...
             'deid_engine', 'n_files', 'deid_utc' };

    % --- PHI guard: refuse a row that names a patient identifier --------
    BLOCK = { 'patientname', 'patient_name', 'name', 'mrn', 'patientid', ...
              'patient_id', 'accession', 'accessionnumber', 'dob', ...
              'birthdate', 'birth_date', 'patientbirthdate', 'ssn', ...
              'institution', 'institutionname', 'address', ...
              'patientaddress', 'phone', 'telephone', 'referringphysician' };
    fn = fieldnames(row);
    for i = 1:numel(fn)
        if ismember(lower(fn{i}), BLOCK) && ~is_empty_val(row.(fn{i}))
            error('intake:append_manifest:PHIField', ...
                ['Refusing to write the manifest: field "%s" looks like a ' ...
                 'patient identifier. The manifest is de-identified — ' ...
                 'codename + geometry + labels only.'], fn{i});
        end
    end

    % --- codename must be a JohnDoeN pseudonym, never a real name -------
    cn = char(string(field_or(row, 'codename', '')));
    if isempty(regexp(cn, '^JohnDoe\d+$', 'once'))
        error('intake:append_manifest:BadCodename', ...
            ['codename must match JohnDoeN (e.g. JohnDoe3); got "%s". Real ' ...
             'names/MRNs must never enter the manifest.'], cn);
    end

    % --- ensure the target directory exists -----------------------------
    out_dir = fileparts(manifest_path);
    if ~isempty(out_dir) && ~isfolder(out_dir); mkdir(out_dir); end

    new_file = ~isfile(manifest_path);
    if ~new_file
        d = dir(manifest_path);
        new_file = isempty(d) || d(1).bytes == 0;
    end

    fid = fopen(manifest_path, 'a');
    if fid < 0
        error('intake:append_manifest:OpenFailed', ...
            'Could not open manifest for append: %s', manifest_path);
    end
    cleaner = onCleanup(@() fclose(fid));

    if new_file
        fprintf(fid, '%s\n', strjoin(cellfun(@csv_escape, COLS, ...
            'UniformOutput', false), ','));
    end

    vals = cell(1, numel(COLS));
    for c = 1:numel(COLS)
        vals{c} = csv_escape(to_str(field_or(row, COLS{c}, '')));
    end
    fprintf(fid, '%s\n', strjoin(vals, ','));
end

% =========================================================================
function tf = is_empty_val(v)
    tf = isempty(v) || (ischar(v) && isempty(strtrim(v))) || ...
         (isstring(v) && (v == "" || ismissing(v)));
end

function v = field_or(s, name, default)
    if isfield(s, name) && ~is_empty_val(s.(name))
        v = s.(name);
    else
        v = default;
    end
end

function s = to_str(v)
    if ischar(v)
        s = v;
    elseif isstring(v)
        s = char(v);
    elseif isnumeric(v) || islogical(v)
        if isscalar(v)
            s = num2str(v);
        else
            s = strjoin(arrayfun(@(x) num2str(x), v(:).', ...
                'UniformOutput', false), 'x');
        end
    else
        s = char(string(v));
    end
end

function s = csv_escape(v)
    s = to_str(v);
    if contains(s, {',', '"', newline, sprintf('\r')})
        s = ['"', strrep(s, '"', '""'), '"'];
    end
end
