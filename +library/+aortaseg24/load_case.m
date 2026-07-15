function C = load_case(ct_path, label_path, opts)
%LIBRARY.AORTASEG24.LOAD_CASE  Ingest a public AortaSeg case (CT + multi-
%   class label NIfTI) into the app's native format, so a real reference
%   case can be worked in the GUI / pipeline exactly like a phantom.
%
%   C = library.aortaseg24.load_case(CT_PATH, LABEL_PATH)
%   C = library.aortaseg24.load_case(CT_PATH, LABEL_PATH, OPTS)
%
%   Reads the CT and its integer label volume, maps the dataset's raw class
%   ids to the pipeline label scheme (1=aorta, 2/3=iliacs, 4/5=CFAs,
%   6/7=renals, 8=celiac, 9=SMA, 11=ILT) via
%   `autoseg.aortaseg24.translate_labels` + the class map, and builds a
%   `preprocess.dicom_load`-shaped D-struct plus an arterial mask.
%
%   OPTS (all optional):
%     .class_map_path   class-map JSON (default: data/aortaseg24_class_map.json).
%                       Pass a different map to ingest a compatible cohort
%                       (e.g. an "aortaseg60"-style set with its own ids).
%     .arterial_labels  pipeline labels to include in the centerline MASK
%                       (default [1 2 3 4 5] = aorta + iliacs + CFAs).
%     .permute          1x3 axis permutation applied to both volumes, for
%                       datasets whose NIfTI axis order isn't [Y X Z]
%                       (default [] = none).
%     .flip             axes (subset of 1:3) to flip after permuting, to get
%                       cranial-first / femorals-at-bottom (default []).
%     .patient_id       label for the case (default: derived from filename).
%
%   Returns C:
%     .D             D-struct: .vol .pixel_mm .slice_spacing_mm .slice_z_mm
%                    .is_volume .z_normalized .patient_id .study_date
%                    .series_description
%     .mask          logical arterial-tree mask (feed to the pipeline)
%     .label_branch  uint8 pipeline-scheme label volume (full translation)
%     .classes       per-class table from translate_labels
%     .case_id       identifier string
%
%   NIfTI only (uses `niftiread`/`niftiinfo`). Convert NRRD → NIfTI first
%   (e.g. 3D Slicer, or SimpleITK). HU assumption: the CT is stored in
%   Hounsfield units (standard for CTA NIfTI); the pipeline's HU gates need
%   that. Orientation may need per-dataset tuning via .permute/.flip — the
%   app's orientation guard (femorals must be caudal) will flag a bad guess.
%
%   RESEARCH USE ONLY. The AortaSeg24 cohort is CC-BY-NC and is never
%   redistributed with this repo — download it yourself and point
%   library.aortaseg24.data_root at it.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        ct_path    (1,:) char
        label_path (1,:) char
        opts       (1,1) struct = struct()
    end
    if ~isfield(opts, 'class_map_path');  opts.class_map_path  = ''; end
    if ~isfield(opts, 'arterial_labels'); opts.arterial_labels = [1 2 3 4 5]; end
    if ~isfield(opts, 'permute');         opts.permute         = []; end
    if ~isfield(opts, 'flip');            opts.flip            = []; end
    if ~isfield(opts, 'patient_id');      opts.patient_id      = ''; end

    if ~exist(ct_path, 'file')
        error('library:aortaseg24:load_case:NoCT', 'CT not found: %s', ct_path);
    end
    if ~exist(label_path, 'file')
        error('library:aortaseg24:load_case:NoLabel', 'Label not found: %s', label_path);
    end

    % --- read volumes ------------------------------------------------
    vol   = niftiread(ct_path);
    lab   = niftiread(label_path);
    info  = niftiinfo(ct_path);
    vox   = info.PixelDimensions;            % [dy dx dz] per stored axis
    if numel(vox) < 3; vox(end+1:3) = 1; end

    if ~isequal(size(vol), size(lab))
        error('library:aortaseg24:load_case:SizeMismatch', ...
            'CT size [%s] != label size [%s].', ...
            num2str(size(vol)), num2str(size(lab)));
    end

    % --- optional orientation fixup ----------------------------------
    if ~isempty(opts.permute)
        vol = permute(vol, opts.permute);
        lab = permute(lab, opts.permute);
        vox = vox(opts.permute);
    end
    for ax = opts.flip(:).'
        vol = flip(vol, ax);
        lab = flip(lab, ax);
    end

    % --- translate raw class ids -> pipeline label scheme ------------
    [label_out, classes] = autoseg.aortaseg24.translate_labels(uint8(lab), opts.class_map_path);
    mask = ismember(label_out, opts.arterial_labels);

    % --- build the D-struct (mirrors preprocess.dicom_load) ----------
    sz = size(vol);
    if isempty(opts.patient_id)
        [~, base] = fileparts(strip_gz(ct_path));
        opts.patient_id = base;
    end
    D = struct();
    D.vol              = vol;
    D.pixel_mm         = [vox(1) vox(2)];
    D.slice_spacing_mm = vox(3);
    D.slice_z_mm       = ((1:sz(3)) - 1).' * vox(3);
    D.is_volume        = true;
    D.z_normalized     = true;    % assume orientation handled via permute/flip
    D.patient_id       = opts.patient_id;
    D.study_date       = '';
    D.series_description = 'AortaSeg CTA';

    C = struct('D', D, 'mask', logical(mask), ...
               'label_branch', uint8(label_out), 'classes', classes, ...
               'case_id', opts.patient_id);
end

% =========================================================================
function s = strip_gz(p)
    s = p;
    if numel(s) > 3 && strcmpi(s(end-2:end), '.gz'); s = s(1:end-3); end
end
