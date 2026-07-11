function report = scrub_phi_from_cache(root)
%SCRUB_PHI_FROM_CACHE  Strip DICOM patient-identifier tags from every
%   cached/result .mat under results/ and .cache/.
%
%   REPORT = scrub_phi_from_cache()            % default: project root
%   REPORT = scrub_phi_from_cache(ROOT)
%
%   Cached pipeline artefacts embed the source DICOM header struct
%   (typically `D.info_first`), which carries PatientName, MRN, DOB,
%   AccessionNumber, InstitutionName, ReferringPhysicianName, study
%   dates, etc. None of these are used by any measurement — only the
%   geometry (`vol`, `pixel_mm`, `slice_spacing_mm`, `slice_z_mm`) is.
%   This walks every loaded variable recursively and BLANKS any field
%   whose name is a known PHI tag, then re-saves the file only if it
%   changed. Geometry and all other data are preserved exactly, so
%   tests and the pipeline are unaffected. The operation is reversible
%   by regenerating the cache from the (separately de-identified)
%   source DICOM.
%
%   Run this before any `git init` / public release. The .gitignore
%   already excludes results/ + *.mat, so this is defense in depth for
%   the copies that live on disk.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    if nargin < 1 || isempty(root)
        root = fileparts(fileparts(mfilename('fullpath')));
    end

    % DICOM identifier tags to blank (DICOM keyword spellings).
    phi_tags = { ...
        'PatientName', 'PatientID', 'PatientBirthDate', 'PatientSex', ...
        'PatientAge', 'PatientAddress', 'PatientTelephoneNumbers', ...
        'OtherPatientIDs', 'OtherPatientNames', 'PatientMotherBirthName', ...
        'AccessionNumber', 'StudyID', 'StudyDate', 'StudyTime', ...
        'SeriesDate', 'SeriesTime', 'AcquisitionDate', 'AcquisitionTime', ...
        'ContentDate', 'ContentTime', 'InstitutionName', ...
        'InstitutionAddress', 'InstitutionalDepartmentName', ...
        'ReferringPhysicianName', 'PerformingPhysicianName', ...
        'NameOfPhysiciansReadingStudy', 'OperatorsName', ...
        'RequestingPhysician', 'ScheduledPerformingPhysicianName', ...
        'StationName', 'DeviceSerialNumber', ...
        'StudyInstanceUID', 'SeriesInstanceUID', 'SOPInstanceUID', ...
        'FrameOfReferenceUID', 'MediaStorageSOPInstanceUID'};

    files = [dir(fullfile(root, 'results', '**', '*.mat')); ...
             dir(fullfile(root, '.cache',  '**', '*.mat'))];

    report = struct('file', {}, 'scrubbed_fields', {});
    fprintf('Scanning %d cached .mat file(s) under results/ + .cache/\n', numel(files));

    for k = 1:numel(files)
        fpath = fullfile(files(k).folder, files(k).name);
        S = load(fpath);
        [S, hits] = scrub_struct(S, phi_tags, {});
        if ~isempty(hits)
            save(fpath, '-struct', 'S');
            rel = strrep(fpath, [root filesep], '');
            report(end+1) = struct('file', rel, 'scrubbed_fields', {hits}); %#ok<AGROW>
            fprintf('  SCRUBBED %-55s (%d tag(s))\n', rel, numel(hits));
        end
    end

    if isempty(report)
        fprintf('No PHI tags found — nothing to scrub.\n');
    else
        fprintf('\nScrubbed PHI from %d file(s).\n', numel(report));
    end
end

% =========================================================================
function [s, hits] = scrub_struct(s, phi_tags, path_prefix)
%SCRUB_STRUCT  Recursively blank PHI-tag fields in a struct / struct array
%   / cell, returning the cleaned value and the list of dotted paths hit.
    hits = {};
    if isstruct(s)
        fn = fieldnames(s);
        for e = 1:numel(s)            % handle struct arrays
            for i = 1:numel(fn)
                name = fn{i};
                here = [strjoin(path_prefix, '.') '.' name];
                if any(strcmp(name, phi_tags))
                    s(e).(name) = blank_like(s(e).(name));
                    hits{end+1} = here; %#ok<AGROW>
                else
                    v = s(e).(name);
                    if isstruct(v) || iscell(v)
                        [s(e).(name), sub] = scrub_struct(v, phi_tags, [path_prefix, {name}]);
                        hits = [hits, sub]; %#ok<AGROW>
                    end
                end
            end
        end
    elseif iscell(s)
        for i = 1:numel(s)
            if isstruct(s{i}) || iscell(s{i})
                [s{i}, sub] = scrub_struct(s{i}, phi_tags, path_prefix);
                hits = [hits, sub]; %#ok<AGROW>
            end
        end
    end
    hits = unique(hits);
end

% =========================================================================
function v = blank_like(v)
%BLANK_LIKE  Replace a value with an empty placeholder of a compatible
%   shape. DICOM PN tags are themselves structs (FamilyName, GivenName,
%   …) — blank each subfield; everything else becomes ''.
    if isstruct(v)
        fn = fieldnames(v);
        for e = 1:numel(v)
            for i = 1:numel(fn)
                v(e).(fn{i}) = '';
            end
        end
    else
        v = '';
    end
end
