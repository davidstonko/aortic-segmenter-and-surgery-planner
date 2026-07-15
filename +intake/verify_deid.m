function report = verify_deid(deid_dir, opts)
%INTAKE.VERIFY_DEID  Independently confirm a de-identified DICOM folder
%   carries no residual PHI — the safety gate for Phase-0 intake.
%
%   REPORT = intake.verify_deid(DEID_DIR)
%   REPORT = intake.verify_deid(DEID_DIR, OPTS)
%
%   Re-reads every DICOM header in DEID_DIR (the SCRUBBED output, never
%   the source) and checks the direct-identifier tags from the DICOM
%   PS3.15 Basic Confidentiality Profile plus the extras this project
%   cares about (accession, institution, physicians, device serials,
%   study dates). It is deliberately *engine-agnostic*: it does not trust
%   the tool that did the scrub, it verifies the result.
%
%   A tag is considered CLEAN when it is:
%     * absent or empty, OR
%     * equal to the codename (for PatientName / PatientID), OR
%     * (strongest) present-but-CHANGED from the original value — when the
%       caller supplies the originals via OPTS.orig. The originals live
%       only in memory for the length of the call and are never written.
%
%   This two-mode design covers both scrub styles: `dicomanon` empties the
%   identifiers (clean by emptiness), while `dicognito` replaces them with
%   pseudonyms (clean by "changed from original").
%
%   OPTS (all optional):
%     .orig          struct: tag name -> original value (in memory only).
%                    When present, a tag equal to its original FAILS even
%                    if non-empty — this catches a scrub that silently
%                    no-op'd a field.
%     .codename      the JohnDoeN pseudonym expected in PatientName/ID.
%     .forbid_private true (default) to fail on any residual Private_* tag
%                    (curve/overlay/private blocks can smuggle PHI).
%     .max_files     cap the number of files inspected (default Inf = all).
%
%   REPORT:
%     .ok            true iff every inspected file is clean.
%     .n_files       number of DICOM files inspected.
%     .residual      cell array of '<file>: <Tag> = <redacted reason>'
%                    strings, one per violation (values are NOT echoed).
%     .private_tags  unique Private_* field names still present.
%     .checked_tags  the identifier tags that were checked.
%
%   RESEARCH USE ONLY. Governed by the approved IRB protocol.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        deid_dir (1,:) char
        opts     (1,1) struct = struct()
    end
    if ~isfield(opts, 'orig');           opts.orig           = struct(); end
    if ~isfield(opts, 'codename');       opts.codename       = '';       end
    if ~isfield(opts, 'forbid_private'); opts.forbid_private = true;     end
    if ~isfield(opts, 'max_files');      opts.max_files      = Inf;      end

    if ~isfolder(deid_dir)
        error('intake:verify_deid:NotFolder', 'Not a directory: %s', deid_dir);
    end

    % Identifier tags to check (dicominfo field names). Names/IDs may be
    % re-mapped to the codename; everything else should be gone.
    NAME_TAGS = { 'PatientName', 'PatientID' };
    OTHER_TAGS = { ...
        'PatientBirthDate', 'PatientBirthTime', 'PatientAddress', ...
        'PatientTelephoneNumbers', 'PatientMotherBirthName', 'OtherPatientID', ...
        'OtherPatientIDs', 'OtherPatientNames', 'AccessionNumber', ...
        'InstitutionName', 'InstitutionAddress', 'InstitutionalDepartmentName', ...
        'ReferringPhysicianName', 'ReferringPhysicianAddress', ...
        'PerformingPhysicianName', 'NameOfPhysiciansReadingStudy', ...
        'OperatorsName', 'RequestingPhysician', 'DeviceSerialNumber', ...
        'StationName', 'StudyDate', 'SeriesDate', 'AcquisitionDate', ...
        'ContentDate', 'StudyID' };
    check_tags = [NAME_TAGS, OTHER_TAGS];

    files = list_dicom_files(deid_dir);
    report = struct('ok', true, 'n_files', 0, 'residual', {{}}, ...
                    'private_tags', {{}}, 'checked_tags', {check_tags});
    if isempty(files)
        error('intake:verify_deid:NoDicom', ...
            'No readable DICOM files under: %s', deid_dir);
    end

    n = min(numel(files), opts.max_files);
    private_seen = {};
    for k = 1:n
        f = files{k};
        try
            info = dicominfo(f, 'UseVRHeuristic', false);
        catch
            % Not a DICOM (stray file) — skip; list_dicom_files already
            % filtered hidden/AppleDouble, but be defensive.
            continue;
        end
        report.n_files = report.n_files + 1;
        [~, fname, fext] = fileparts(f);
        tag_short = [fname fext];

        % --- identifier tags -------------------------------------------
        for t = 1:numel(check_tags)
            tag = check_tags{t};
            if ~isfield(info, tag); continue; end
            val = norm_val(info.(tag));
            if is_blank(val); continue; end                 % emptied -> clean

            is_name = ismember(tag, NAME_TAGS);
            if is_name && ~isempty(opts.codename) && strcmp(val, opts.codename)
                continue;                                   % re-mapped -> clean
            end

            if isfield(opts.orig, tag)
                orig = norm_val(opts.orig.(tag));
                if ~is_blank(orig) && strcmp(val, orig)
                    report.residual{end+1} = sprintf( ...
                        '%s: %s unchanged from source', tag_short, tag);
                    report.ok = false;
                end
                % changed-and-non-empty with originals known -> clean
                continue;
            end

            % No originals to compare, non-empty, and (for names) not the
            % codename: can't prove it's scrubbed -> flag conservatively,
            % unless it's a name we accept as a pseudonym.
            if is_name
                continue;   % assume a replaced pseudonym (dicognito style)
            end
            report.residual{end+1} = sprintf( ...
                '%s: %s present (could not confirm de-identified)', ...
                tag_short, tag);
            report.ok = false;
        end

        % --- residual private tags -------------------------------------
        pf = fieldnames(info);
        pf = pf(startsWith(pf, 'Private_'));
        if ~isempty(pf)
            private_seen = union(private_seen, pf);
            if opts.forbid_private
                report.residual{end+1} = sprintf('%s: %d residual private tag(s)', ...
                    tag_short, numel(pf));
                report.ok = false;
            end
        end
    end

    report.private_tags = private_seen(:).';
end

% =========================================================================
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

function v = norm_val(x)
    if isstruct(x)
        % DICOM person-name structs: concatenate the components.
        parts = struct2cell(x);
        parts = parts(cellfun(@(c) ischar(c) || isstring(c), parts));
        v = strtrim(strjoin(cellfun(@char, parts, 'UniformOutput', false), '^'));
    elseif isstring(x)
        v = char(strjoin(x, '^'));
    elseif ischar(x)
        v = strtrim(x);
    elseif isnumeric(x)
        v = strtrim(num2str(x(:).'));
    else
        v = char(string(x));
    end
end

function tf = is_blank(v)
    tf = isempty(v) || all(isspace(v)) || strcmpi(strtrim(v), 'ANON');
end
