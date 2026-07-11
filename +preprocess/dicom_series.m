function S = dicom_series(root, anonymize)
%DICOM_SERIES  Group DICOM files under ROOT by SeriesInstanceUID.
%
%   S = DICOM_SERIES(ROOT) returns a table S, one row per series, with
%   columns describing each acquisition at-a-glance:
%
%       n_files           how many DICOM files belong to this series
%       total_frames      total number of image frames across the series
%                         (sum of NumberOfFrames over all files; ==
%                         n_files for plain single-frame series, larger
%                         for multi-frame cines)
%       modality          'CT', 'XA', etc.
%       rows, cols        image dimensions
%       series_descr      human-readable description (e.g. "Aorta 0.75 Br36 3"
%                         or "Abdomen Frontal 3fps")
%       primary_angle     median RAO/LAO angle across the series
%       secondary_angle   median CRA/CAU
%       SID, SOD          median source-to-image, source-to-patient (mm)
%       folder            common parent folder containing the series files
%
%   Use S to pick a series before loading. Typical workflow:
%       S = preprocess.dicom_series(patient_root);
%       disp(S);
%       D = preprocess.dicom_load(S.folder{i});

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    if nargin < 2 || isempty(anonymize); anonymize = true; end

    T = preprocess.dicom_list(root, anonymize);
    if isempty(T)
        S = table();
        return;
    end

    [G, gid] = findgroups(T.series_uid);

    n_files       = splitapply(@numel, T.file,         G);
    total_frames  = splitapply(@sum,   T.frames,       G);
    modality      = splitapply(@(x) {x{1}}, T.modality,     G);
    rows          = splitapply(@(x) x(1), T.rows,           G);
    cols          = splitapply(@(x) x(1), T.cols,           G);
    series_descr  = splitapply(@(x) {x{1}}, T.series_descr, G);
    primary       = splitapply(@(x) median(x, 'omitnan'),   T.primary_angle,   G);
    secondary     = splitapply(@(x) median(x, 'omitnan'),   T.secondary_angle, G);
    SID           = splitapply(@(x) median(x, 'omitnan'),   T.SID,             G);
    SOD           = splitapply(@(x) median(x, 'omitnan'),   T.SOD,             G);
    folder        = splitapply(@(x) {common_parent(x)},     T.file,            G);
    total_size_MB = splitapply(@sum, T.size_MB,             G);

    S = table(folder, n_files, total_frames, modality, rows, cols, ...
              series_descr, primary, secondary, SID, SOD, total_size_MB, ...
              gid, ...
        'VariableNames', {'folder','n_files','total_frames','modality', ...
                          'rows','cols','series_descr','primary_angle', ...
                          'secondary_angle','SID','SOD','total_size_MB', ...
                          'series_uid'});

    % Sort by modality (CT before XA), then total_frames descending
    [~, order] = sortrows(table(string(S.modality), -S.total_frames));
    S = S(order, :);
end

function p = common_parent(files)
    if numel(files) == 1
        p = fileparts(files{1});
    else
        parts = cellfun(@(f) split(f, filesep), files, 'Uni', false);
        nmin = min(cellfun(@numel, parts));
        prefix = parts{1}(1:nmin);
        for i = 2:numel(parts)
            for j = 1:nmin
                if ~strcmp(parts{i}{j}, prefix{j})
                    nmin = j - 1;
                    prefix = prefix(1:nmin);
                    break;
                end
            end
        end
        p = strjoin(prefix, filesep);
    end
end
