function T = list_cases(lib_root)
%LIBRARY.LIST_CASES  Return a table of all cases currently in the library.
%
%   T = library.list_cases() walks the default library folder
%   (<project root>/library/) and returns a table with one row per
%   .mat case, summarising patient_id, study_date, arc length, lumen
%   stats, and the saved-at timestamp.
%
%   T = library.list_cases(LIB_ROOT) uses a custom library root.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        lib_root (1,:) char = ''
    end

    if isempty(lib_root)
        here = fileparts(mfilename('fullpath'));
        lib_root = fullfile(fileparts(here), 'library');
    end
    if ~exist(lib_root, 'dir')
        T = table();
        return;
    end

    files = dir(fullfile(lib_root, '*.mat'));
    if isempty(files)
        T = table();
        return;
    end

    n = numel(files);
    file_name      = strings(n, 1);
    patient_id     = strings(n, 1);
    study_date     = strings(n, 1);
    saved_at       = strings(n, 1);
    n_nodes        = nan(n, 1);
    arc_length_mm  = nan(n, 1);
    median_R_mm    = nan(n, 1);
    has_landmarks  = false(n, 1);

    for k = 1:n
        fp = fullfile(files(k).folder, files(k).name);
        try
            S = load(fp);
        catch
            continue;
        end
        file_name(k) = files(k).name;
        if isfield(S, 'dicom_meta') && isstruct(S.dicom_meta)
            patient_id(k) = string(field_or(S.dicom_meta, 'patient_id', 'ANON'));
            study_date(k) = string(field_or(S.dicom_meta, 'study_date', ''));
        end
        if isfield(S, 'saved_at'); saved_at(k) = string(S.saved_at); end
        if isfield(S, 'Pv_mm') && ~isempty(S.Pv_mm)
            n_nodes(k) = size(S.Pv_mm, 1);
            arc_length_mm(k) = sum(vecnorm(diff(S.Pv_mm, 1, 1), 2, 2));
        end
        if isfield(S, 'R_mm') && ~isempty(S.R_mm)
            median_R_mm(k) = median(S.R_mm);
        end
        if isfield(S, 'landmarks') && isstruct(S.landmarks) && ...
                ~isempty(fieldnames(S.landmarks))
            has_landmarks(k) = true;
        end
    end

    T = table(file_name, patient_id, study_date, saved_at, ...
              n_nodes, arc_length_mm, median_R_mm, has_landmarks);
    % Sort newest first by saved_at, then study_date
    T = sortrows(T, {'saved_at'}, {'descend'});
end

function v = field_or(s, name, default)
    if isfield(s, name) && ~isempty(s.(name)); v = s.(name);
    else; v = default;
    end
end
