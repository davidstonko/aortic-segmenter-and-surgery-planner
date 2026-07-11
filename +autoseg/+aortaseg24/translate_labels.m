function [label_out, classes] = translate_labels(label_raw, class_map_path)
%AUTOSEG.AORTASEG24.TRANSLATE_LABELS  Map AortaSeg24's 23-class label
%   volume to the pipeline's canonical label scheme.
%
%   [LABEL_OUT, CLASSES] = autoseg.aortaseg24.translate_labels(LABEL_RAW)
%   [LABEL_OUT, CLASSES] = autoseg.aortaseg24.translate_labels(LABEL_RAW, MAP_PATH)
%
%   LABEL_RAW is a Y×X×Z uint8 volume from AortaSeg24's segmenter
%   (raw challenge class IDs ∈ [0, 23]).
%
%   The translation table lives in `data/aortaseg24_class_map.json` so
%   the mapping can be edited without touching MATLAB code. Schema:
%       {
%         "version": "1.0",
%         "source": "AortaSeg24 challenge label dictionary (Imran et al. 2024)",
%         "classes": [
%           {"id": 1, "name": "ascending_aorta",     "pipeline_label": 0},
%           {"id": 2, "name": "aortic_arch",         "pipeline_label": 0},
%            ...
%           {"id": 17,"name": "abdominal_aorta_lumen","pipeline_label": 1},
%           {"id": 18,"name": "right_common_iliac",  "pipeline_label": 3},
%            ...
%           {"id": 22,"name": "aortic_wall",         "pipeline_label": 10},
%           {"id": 23,"name": "thrombus",            "pipeline_label": 11}
%         ]
%       }
%
%   `pipeline_label = 0` means "not used downstream — ignored".
%   Pipeline labels in use today:
%       1  abdominal aorta (lumen)        — TS / AortaSeg24
%       2  L common iliac (lumen)
%       3  R common iliac (lumen)
%       4  L CFA (extension)              — from extend_to_cfa
%       5  R CFA (extension)              — from extend_to_cfa
%       6  L renal artery
%       7  R renal artery
%       8  celiac trunk
%       9  SMA
%      10  aortic wall                    — NEW with AortaSeg24
%      11  intraluminal thrombus          — NEW with AortaSeg24
%
%   Returns
%       LABEL_OUT  Y×X×Z uint8 in the pipeline canonical scheme above
%       CLASSES    struct array describing every present class:
%                    .id, .name, .pipeline_label, .voxels

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        label_raw       uint8
        class_map_path  (1,:) char = ''
    end

    if isempty(class_map_path)
        proj_root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
        class_map_path = fullfile(proj_root, 'data', 'aortaseg24_class_map.json');
    end
    if ~isfile(class_map_path)
        error('autoseg:aortaseg24:NoClassMap', ...
            ['AortaSeg24 class map not found at %s. ' ...
             'See docs/AORTASEG24_LABEL_MAP.md.'], class_map_path);
    end
    fid = fopen(class_map_path, 'r');
    cleaner = onCleanup(@() fclose(fid));
    txt = fread(fid, inf, '*char')';
    j = jsondecode(txt);

    if ~isfield(j, 'classes')
        error('autoseg:aortaseg24:BadClassMap', ...
            'Class map %s missing "classes" array', class_map_path);
    end
    cl = j.classes;
    if isstruct(cl) && numel(cl) == 1 && isfield(cl, 'id')
        % jsondecode collapses single-element arrays sometimes
        cl = cl(:);
    elseif iscell(cl)
        cl = cell2mat(cellfun(@(c) c, cl, 'UniformOutput', false));
    end

    label_out = zeros(size(label_raw), 'uint8');
    classes = struct('id', {}, 'name', {}, 'pipeline_label', {}, 'voxels', {});
    for k = 1:numel(cl)
        raw_id = uint8(cl(k).id);
        pl     = uint8(cl(k).pipeline_label);
        mask_k = label_raw == raw_id;
        n_vox  = nnz(mask_k);
        if n_vox == 0; continue; end
        if pl > 0
            label_out(mask_k) = pl;
        end
        classes(end+1) = struct( ...
            'id', raw_id, 'name', cl(k).name, ...
            'pipeline_label', pl, 'voxels', n_vox); %#ok<AGROW>
    end
end
