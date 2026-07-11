function D = dicom_load(src, anonymize)
%DICOM_LOAD  Read a DICOM source into a uniform struct.
%
%   D = DICOM_LOAD(SRC, ANONYMIZE) loads DICOM data and returns a
%   struct with a uniform schema regardless of input shape:
%
%       D.vol             rows x cols x N pixel array (double for CT,
%                         original integer type otherwise)
%       D.modality        e.g. 'CT', 'XA', 'CR', 'DX'
%       D.patient_id      string ('ANON' if anonymize is true)
%       D.study_date      yyyy-mm-dd string
%       D.rows, .cols     image dimensions
%       D.n_frames        number of slices/frames
%       D.pixel_mm        [dy dx] in mm
%       D.is_volume       true if data is a 3D CT/MR volume sorted in z
%       D.slice_z_mm      n_frames x 1 (volumes only)
%       D.slice_spacing_mm scalar (volumes only; mean adjacent gap)
%       D.carm_pose       struct with .primary_angle, .secondary_angle,
%                         .SID, .SOD (XA/CR/DX only; otherwise empty)
%       D.series_description, .study_description (raw fields)
%       D.info_first      raw dicominfo for the first file (debug)
%
%   Inputs
%       src       : path to a folder OR a single DICOM file. If a
%                   folder, all *.dcm files are read; for a CT/MR
%                   volume they are sorted by SliceLocation, and for
%                   a multi-frame DICOM the file is read as-is.
%       anonymize : if true (default), patient identifiers are blanked
%                   out as 'ANON' in the returned struct.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    if nargin < 2 || isempty(anonymize); anonymize = true; end

    % --- Resolve input to a list of files -----------------------------
    if exist(src, 'file') == 2
        files = {src};
    elseif exist(src, 'dir') == 7
        f = dir(fullfile(src, '*.dcm'));
        if isempty(f)
            % No .dcm in the chosen folder. Try a recursive search
            % (common when the user picks a parent of a multi-series
            % archive). If still empty, fall back to all files (some
            % exports omit the .dcm extension).
            f = dir(fullfile(src, '**', '*.dcm'));
            if isempty(f)
                f = dir(src);
                f = f(~[f.isdir]);
            end
        end
        files = arrayfun(@(x) fullfile(x.folder, x.name), f, 'Uni', false);
    else
        error('dicom_load:NotFound', 'Input not found: %s', src);
    end

    % Filter out:
    %   - Mac OS AppleDouble metadata files ("._filename") — these
    %     have the .dcm extension but contain no DICOM data.
    %   - Hidden files (.DS_Store, .Thumbs.db, etc.).
    %   - Anything that fails dicominfo silently (we try-catch below).
    keep = false(numel(files), 1);
    for k = 1:numel(files)
        [~, name, ext] = fileparts(files{k});
        if startsWith(name, '._') || startsWith(name, '.')
            continue;   % skip metadata / hidden files
        end
        keep(k) = true;
    end
    files = files(keep);

    if isempty(files); error('dicom_load:NoFiles', ...
            'No DICOM files in %s (after filtering hidden / metadata files).', src); end

    % If files come from multiple immediate-parent folders, pick the
    % single largest group. This handles the case where the user
    % selects a parent archive folder that contains several series in
    % subfolders — we don't want to mix them. The user can pick a
    % specific series folder if a different one is wanted.
    parents = cellfun(@fileparts, files, 'Uni', false);
    [unique_parents, ~, group] = unique(parents);
    if numel(unique_parents) > 1
        counts = accumarray(group, 1);
        [~, biggest] = max(counts);
        files = files(group == biggest);
        warning('dicom_load:MultipleSeries', ...
            ['Folder contains files from %d different sub-folders. ' ...
             'Loading the largest (%d files in %s). Pick a specific ' ...
             'series sub-folder if a different one is wanted.'], ...
            numel(unique_parents), counts(biggest), unique_parents{biggest});
    end

    % --- Read first file to determine modality and shape --------------
    % Try files in order until one parses as valid DICOM (some folders
    % mix DICOM with display LUTs or other non-DICOM payloads).
    info0 = []; first_ok = 0;
    for k = 1:numel(files)
        try
            info0 = dicominfo(files{k});
            first_ok = k;
            break;
        catch
            % Not DICOM, try next
        end
    end
    if isempty(info0)
        error('dicom_load:NoValidDICOM', ...
            'None of the %d files in %s parsed as valid DICOM.', ...
            numel(files), src);
    end
    % Drop any leading non-DICOM files we skipped
    files = files(first_ok:end);
    D = struct();
    D.modality           = field_or(info0, 'Modality', '');
    D.rows               = info0.Rows;
    D.cols               = info0.Columns;
    D.series_description = field_or(info0, 'SeriesDescription', '');
    D.study_description  = field_or(info0, 'StudyDescription', '');
    D.info_first         = info0;

    % Pixel spacing in mm (DICOM PixelSpacing is [row_mm col_mm])
    if isfield(info0, 'PixelSpacing'); D.pixel_mm = info0.PixelSpacing(:).';
    elseif isfield(info0, 'ImagerPixelSpacing'); D.pixel_mm = info0.ImagerPixelSpacing(:).';
    else; D.pixel_mm = [1 1];
    end

    % --- Patient/study metadata ---------------------------------------
    if anonymize
        D.patient_id = 'ANON';
    else
        D.patient_id = field_or(info0, 'PatientID', '');
    end
    if isfield(info0, 'StudyDate') && ~isempty(info0.StudyDate)
        d = info0.StudyDate;
        if numel(d) == 8
            D.study_date = sprintf('%s-%s-%s', d(1:4), d(5:6), d(7:8));
        else
            D.study_date = d;
        end
    else
        D.study_date = '';
    end

    % --- Branch: CT/MR volume vs single XA file vs multi-frame --------
    is_ct_mr = ismember(upper(D.modality), {'CT', 'MR', 'PT', 'OT'});
    n_frames_in_file = field_or(info0, 'NumberOfFrames', 1);

    if is_ct_mr && numel(files) > 1
        % --- CT/MR volume from multiple files -------------------------
        D.is_volume = true;
        % Read all files, skipping any that fail dicominfo (corrupt
        % file, AppleDouble shadow, mistaken non-DICOM).
        n = numel(files);
        info_all = cell(n, 1);
        valid    = false(n, 1);
        for k = 1:n
            try
                info_all{k} = dicominfo(files{k});
                valid(k) = true;
            catch
                % skip
            end
        end
        files    = files(valid);
        info_all = info_all(valid);
        n        = numel(files);
        if n == 0
            error('dicom_load:NoValidDICOM', 'No files parsed as DICOM.');
        end
        z = nan(n, 1);
        z_from_position = true(n, 1);   % did this slice's z come from a
                                        % real patient-position tag?
        for k = 1:n
            if isfield(info_all{k}, 'SliceLocation')
                z(k) = double(info_all{k}.SliceLocation);
            elseif isfield(info_all{k}, 'ImagePositionPatient')
                z(k) = double(info_all{k}.ImagePositionPatient(3));
            elseif isfield(info_all{k}, 'InstanceNumber')
                z(k) = double(info_all{k}.InstanceNumber);
                z_from_position(k) = false;   % InstanceNumber ≠ orientation
            end
        end
        % Sort DESCENDING in z so slice 1 of the volume = the most
        % superior slice (= patient head) and the LAST slice = most
        % caudal (= the legs / common femoral arteries). With this
        % convention, coronal/sagittal MIPs show head-at-top and the
        % femorals at the BOTTOM of the screen — the radiology display
        % convention every clinician expects (#36).
        %
        % craniocaudal_known is true only when EVERY slice's z came from
        % a real position tag (SliceLocation / ImagePositionPatient). If
        % any slice fell back to InstanceNumber, the descending sort does
        % NOT guarantee head-first, so downstream orientation checks
        % (autoseg.orientation_is_suspect) treat a femorals-not-caudal
        % result as a likely flip rather than borderline anatomy.
        D.craniocaudal_known = all(z_from_position);
        [zsort, ord] = sort(z, 'descend');
        files    = files(ord);
        info_all = info_all(ord);

        % Read pixel data and apply rescale slope/intercept (CT HU)
        vol = zeros(D.rows, D.cols, n, 'single');
        for k = 1:n
            img = single(dicomread(files{k}));
            sl = field_or(info_all{k}, 'RescaleSlope',     1);
            ic = field_or(info_all{k}, 'RescaleIntercept', 0);
            vol(:, :, k) = img * sl + ic;
        end
        D.vol         = vol;
        D.n_frames    = n;
        D.slice_z_mm  = zsort;
        D.slice_spacing_mm = abs(median(diff(zsort)));   % always positive

    else
        % --- XA / cine fluoro / multi-file multi-frame series ---------
        % Sort the files by InstanceNumber so multi-file cines come out
        % in the right temporal order, then concatenate all frames.
        D.is_volume = false;
        n = numel(files);
        inst = nan(n, 1);
        for k = 1:n
            ik = dicominfo(files{k});
            inst(k) = field_or(ik, 'InstanceNumber', k);
        end
        [~, ord] = sort(inst);
        files = files(ord);

        % Read first file to determine pixel data type and frame count
        first = dicomread(files{1});      % rows x cols x 1 x F (multi-frame)
                                          % or rows x cols (single-frame)
        first = squeeze(first);
        if ndims(first) == 2; n_first = 1; else; n_first = size(first, 3); end

        % Pre-allocate by reading frame counts from headers
        n_frames_each = zeros(n, 1);
        for k = 1:n
            ik = dicominfo(files{k});
            n_frames_each(k) = field_or(ik, 'NumberOfFrames', 1);
        end
        total_frames = sum(n_frames_each);

        vol = zeros([D.rows, D.cols, total_frames], 'like', first);
        vol(:, :, 1:n_first) = first;
        cursor = n_first + 1;
        for k = 2:n
            img = squeeze(dicomread(files{k}));
            if ndims(img) == 2
                vol(:, :, cursor) = img;
                cursor = cursor + 1;
            else
                f = size(img, 3);
                vol(:, :, cursor:cursor+f-1) = img;
                cursor = cursor + f;
            end
        end
        D.vol      = vol;
        D.n_frames = total_frames;
    end

    % --- C-arm pose (XA / CR / DX) ------------------------------------
    if any(strcmpi(D.modality, {'XA', 'CR', 'DX', 'RF'}))
        cp = struct();
        cp.primary_angle   = field_or(info0, 'PositionerPrimaryAngle',   NaN);
        cp.secondary_angle = field_or(info0, 'PositionerSecondaryAngle', NaN);
        cp.SID             = field_or(info0, 'DistanceSourceToDetector', NaN);
        cp.SOD             = field_or(info0, 'DistanceSourceToPatient',  NaN);
        D.carm_pose        = cp;
    else
        D.carm_pose = [];
    end
end

function v = field_or(s, name, default)
    if isfield(s, name); v = s.(name); else; v = default; end
end
