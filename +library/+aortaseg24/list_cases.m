function cases = list_cases(root)
%LIBRARY.AORTASEG24.LIST_CASES  Discover CT/label NIfTI pairs in the dataset.
%
%   cases = library.aortaseg24.list_cases()          % uses data_root()
%   cases = library.aortaseg24.list_cases(ROOT)
%
%   Recursively scans ROOT for NIfTI files and pairs each CT with its label
%   by a shared case id. Tolerant of the common AortaSeg naming variants:
%   files are classed as LABEL when the name contains seg/label/mask/gt/
%   annotation, else CT; the case id is the filename with those tags and the
%   nnU-Net `_0000` channel suffix stripped (falling back to the parent
%   folder name). Returns a struct array with fields:
%       .case_id  .ct_path  .label_path
%
%   Returns empty (with a note) if ROOT doesn't exist — the AortaSeg cohort
%   is CC-BY-NC and downloaded separately; see library.aortaseg24.data_root.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    if nargin < 1 || isempty(root); root = library.aortaseg24.data_root(); end
    cases = struct('case_id', {}, 'ct_path', {}, 'label_path', {});
    if ~exist(root, 'dir')
        fprintf(['[aortaseg24.list_cases] data root not found: %s\n' ...
                 '  Download the cohort and set AORTASEG24_DATA_ROOT ' ...
                 '(see library.aortaseg24.data_root).\n'], root);
        return;
    end

    files = [dir(fullfile(root, '**', '*.nii'));
             dir(fullfile(root, '**', '*.nii.gz'))];
    reg = containers.Map('KeyType', 'char', 'ValueType', 'any');
    label_re = '(seg|label|mask|gt|annotation)';
    for i = 1:numel(files)
        fpath = fullfile(files(i).folder, files(i).name);
        base  = lower(strip_ext(files(i).name));
        is_label = ~isempty(regexp(base, label_re, 'once'));
        cid = case_id_from(base, files(i).folder, label_re);
        if ~reg.isKey(cid); reg(cid) = struct('ct', '', 'label', ''); end
        e = reg(cid);
        if is_label; e.label = fpath; else; e.ct = fpath; end
        reg(cid) = e;
    end

    keys = reg.keys;
    for k = 1:numel(keys)
        e = reg(keys{k});
        if ~isempty(e.ct) && ~isempty(e.label)
            cases(end+1) = struct('case_id', keys{k}, ...
                'ct_path', e.ct, 'label_path', e.label); %#ok<AGROW>
        end
    end
    if isempty(cases)
        fprintf(['[aortaseg24.list_cases] no CT/label NIfTI pairs found under %s\n' ...
                 '  (need one CT and one seg/label .nii[.gz] per case).\n'], root);
    end
end

% =========================================================================
function s = strip_ext(name)
    s = name;
    if numel(s) > 3 && strcmpi(s(end-2:end), '.gz'); s = s(1:end-3); end
    [~, s] = fileparts(s);
end

function cid = case_id_from(base, folder, label_re)
    % Strip label tags + the nnU-Net _0000 channel suffix; fall back to the
    % parent folder name when the stripped id is empty/uninformative.
    cid = regexprep(base, label_re, '');
    cid = regexprep(cid, '_0000$', '');
    cid = regexprep(cid, '[_.\-]+$', '');
    cid = regexprep(cid, '(_cta|_ct|_image|_img|_vol)$', '');
    if isempty(cid) || numel(cid) < 3
        [~, cid] = fileparts(folder);
    end
end
