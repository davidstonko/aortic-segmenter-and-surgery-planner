function T = dicom_list(root, anonymize)
%DICOM_LIST  Catalog every DICOM file under a folder.
%
%   T = DICOM_LIST(ROOT) recursively scans ROOT, reads each DICOM file's
%   header, and returns a table T with columns describing what's inside:
%
%       file              full path to the file
%       size_MB           file size in megabytes
%       modality          'CT', 'XA', 'CR', 'DX', 'MR', etc.
%       rows, cols        image dimensions
%       frames            number of frames (1 for single-frame, >1 for cine)
%       series_uid        DICOM SeriesInstanceUID (unique per acquisition)
%       series_descr      human-readable series description
%       study_descr       human-readable study description
%       primary_angle     RAO/LAO angle (deg, NaN if absent)
%       secondary_angle   CRA/CAU angle (deg, NaN if absent)
%       SID, SOD          source-to-image / source-to-patient (mm)
%       slice_loc         z-position in patient coords (CT slices only)
%       instance_number   DICOM instance number
%
%   Use this to inventory a patient archive before deciding what to load.
%   For the JohnDoe1 EVAR data: one CT folder with 1219 slices in a single
%   series, plus an XA folder with multiple series (DSA cines + fluoro
%   stills) that need to be picked from.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    if nargin < 2 || isempty(anonymize); anonymize = true; end

    files = dir(fullfile(root, '**', '*.dcm'));
    if isempty(files)
        % Fallback: scan all files (some exports omit .dcm)
        files = dir(fullfile(root, '**'));
        files = files(~[files.isdir]);
    end
    n = numel(files);
    if n == 0
        T = table();
        return;
    end

    % Pre-allocate cell arrays
    file = cell(n, 1); size_MB = zeros(n, 1);
    modality = cell(n, 1); rows = zeros(n, 1); cols = zeros(n, 1);
    frames = zeros(n, 1);
    series_uid = cell(n, 1); series_descr = cell(n, 1); study_descr = cell(n, 1);
    primary = nan(n, 1); secondary = nan(n, 1);
    SID = nan(n, 1); SOD = nan(n, 1);
    slice_loc = nan(n, 1); instance_num = nan(n, 1);

    for k = 1:n
        f = fullfile(files(k).folder, files(k).name);
        try
            info = dicominfo(f);
        catch
            continue;       % not a DICOM file, skip
        end
        file{k}     = f;
        size_MB(k)  = files(k).bytes / 1e6;
        modality{k} = field_or(info, 'Modality', '');
        rows(k)     = field_or(info, 'Rows', 0);
        cols(k)     = field_or(info, 'Columns', 0);
        frames(k)   = field_or(info, 'NumberOfFrames', 1);
        series_uid{k}    = field_or(info, 'SeriesInstanceUID', '');
        series_descr{k}  = field_or(info, 'SeriesDescription',  '');
        study_descr{k}   = field_or(info, 'StudyDescription',   '');
        primary(k)       = field_or(info, 'PositionerPrimaryAngle',   NaN);
        secondary(k)     = field_or(info, 'PositionerSecondaryAngle', NaN);
        SID(k)           = field_or(info, 'DistanceSourceToDetector', NaN);
        SOD(k)           = field_or(info, 'DistanceSourceToPatient',  NaN);
        slice_loc(k)     = field_or(info, 'SliceLocation',            NaN);
        instance_num(k)  = field_or(info, 'InstanceNumber',           NaN);
    end

    % Drop rows where we couldn't read DICOM
    keep = ~cellfun(@isempty, file);
    T = table(file(keep), size_MB(keep), modality(keep), rows(keep), ...
              cols(keep), frames(keep), series_uid(keep), ...
              series_descr(keep), study_descr(keep), primary(keep), ...
              secondary(keep), SID(keep), SOD(keep), slice_loc(keep), ...
              instance_num(keep), ...
        'VariableNames', {'file','size_MB','modality','rows','cols','frames', ...
                          'series_uid','series_descr','study_descr', ...
                          'primary_angle','secondary_angle','SID','SOD', ...
                          'slice_loc','instance_number'});

    % We do NOT anonymize the .file column (those paths must remain
    % usable by downstream code). The `anonymize` flag affects only
    % what dicom_load returns to display. If you want a printable
    % anonymized table, use:
    %     Tdisp = T;
    %     Tdisp.file = regexprep(T.file, '[A-Z]+\^[A-Z\^]+', 'ANON');
end

function v = field_or(s, name, default)
    if isfield(s, name); v = s.(name); else; v = default; end
end
