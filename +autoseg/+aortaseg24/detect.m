function info = detect()
%AUTOSEG.AORTASEG24.DETECT  Locate an AortaSeg24-compatible segmenter.
%
%   INFO = autoseg.aortaseg24.detect()  returns:
%       INFO.available  logical
%       INFO.backend    string — which backend was found:
%                                 'nnunet_checkpoint' | 'docker' |
%                                 'python_module' | '' (none)
%       INFO.python     interpreter to use (may be '')
%       INFO.weights    path to weights / checkpoint dir (may be '')
%       INFO.class_map  path to the AortaSeg24 → pipeline-label JSON
%                       (e.g. data/aortaseg24_class_map.json); always
%                       checked relative to the project root.
%       INFO.error      reason if unavailable
%
%   This is the parallel of `vmtk_centerline.detect()` for VMTK and of
%   `autoseg.totalsegmentator()` for TotalSegmentator.
%
%   As of Phase B1 (2026-06-15) detect() is **honest about weights**: it
%   reports available=true ONLY when BOTH (a) an AortaSeg24 checkpoint
%   dir is present on disk AND (b) a python interpreter with nnunetv2 is
%   found. A python/nnUNet env without weights, or an env_override hook
%   without weights, reports available=true with backend set but
%   info.weights='' — run() then raises Phase_B_needs_weights rather than
%   fabricating output. No public AortaSeg24 checkpoint exists yet (see
%   docs/AORTASEG24_LABEL_MAP.md), so on a clean machine this returns
%   available=false.
%
%   How to make this report a *runnable* B1 backend (in priority order):
%     1. export AORTASEG24_MODEL_DIR=/path/to/nnunet/config_dir
%        — the folder holding plans.json/dataset.json + fold_*/ —
%        and have a python env with `pip install nnunetv2`.
%     2. Install nnUNet + place an AortaSeg24 checkpoint dir under a
%        standard nnUNet_results location (e.g.
%        `$nnUNet_results/Dataset824_AortaSeg24_CTA_50/` or
%        `~/nnUNet_results/Dataset400_AortaSeg24/`).
%     3. Pull a Docker image from the AortaSeg24 challenge and have it
%        on PATH.
%     4. Set the env var AORTASEG24_BACKEND with a custom invocation
%        (developer hook; reports a backend but no weights).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    info = struct('available', false, 'backend', '', 'python', '', ...
                  'weights', '', 'class_map', '', 'error', '');

    proj_root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    info.class_map = fullfile(proj_root, 'data', 'aortaseg24_class_map.json');

    home = char(java.lang.System.getProperty('user.home'));

    % --- Candidate 1: explicit checkpoint dir via env -------------
    % Highest priority: a fully-specified nnU-Net config dir. This is
    % the one-step path documented for B1 — point at the folder holding
    % plans.json/dataset.json + fold_*/checkpoint_final.pth.
    model_dir = getenv('AORTASEG24_MODEL_DIR');
    if ~isempty(model_dir) && exist(model_dir, 'dir')
        info.backend = 'nnunet_checkpoint';
        info.weights = model_dir;
        info.python  = locate_python();
        if isempty(info.python)
            info.error = ['AORTASEG24_MODEL_DIR set but no python ' ...
                'interpreter with nnunetv2 was found'];
        else
            info.available = true;
        end
        return;
    end

    % --- Candidate 2: nnUNet checkpoint on disk -------------------
    % Probe standard nnUNet_results roots for an AortaSeg24 dataset dir.
    % Dataset824_AortaSeg24_CTA_50 is the public training-code dataset id
    % (PengchengShi1220/AortaSeg24); Dataset400 is kept for back-compat
    % with the Phase-A scaffold's placeholder name.
    nnunet_roots = { ...
        getenv('nnUNet_results'), ...
        fullfile(home, 'nnUNet_results')};
    dataset_names = { ...
        'Dataset824_AortaSeg24_CTA_50', ...
        'Dataset400_AortaSeg24'};
    for k = 1:numel(nnunet_roots)
        r = nnunet_roots{k};
        if isempty(r); continue; end
        for di = 1:numel(dataset_names)
            cand = fullfile(r, dataset_names{di});
            if exist(cand, 'dir')
                info.backend  = 'nnunet_checkpoint';
                info.weights  = cand;
                info.python   = locate_python();
                if isempty(info.python)
                    info.error = 'nnUNet checkpoint found but no python interpreter detected';
                else
                    info.available = true;
                end
                return;
            end
        end
    end

    % --- Candidate 3: explicit env var override (dev hook) --------
    % A developer escape hatch that reports a backend WITHOUT weights.
    % detect() stays available=true so run()'s Phase_B_needs_weights
    % guard can be exercised; run() refuses to fabricate output.
    envv = getenv('AORTASEG24_BACKEND');
    if ~isempty(envv)
        info.backend   = 'env_override';
        info.error     = '';
        info.available = true;
        return;
    end

    % --- Candidate 4: docker image --------------------------------
    [rc, ~] = system('docker --version > /dev/null 2>&1');
    if rc == 0
        [rc2, out] = system('docker images --format "{{.Repository}}" 2>/dev/null');
        if rc2 == 0 && contains(string(out), 'aortaseg24')
            info.backend = 'docker';
            info.available = true;
            return;
        end
    end

    info.error = ['No AortaSeg24-compatible backend detected. ' ...
        'See docs/AORTASEG24_LABEL_MAP.md for the supported install paths.'];
end

function py = locate_python()
% Best-effort python that has nnunetv2 importable.
    home = char(java.lang.System.getProperty('user.home'));
    candidates = { ...
        fullfile(home, 'miniforge3', 'envs', 'aortaseg24', 'bin', 'python'), ...
        fullfile(home, 'miniconda3', 'envs', 'aortaseg24', 'bin', 'python'), ...
        fullfile(home, 'miniforge3', 'envs', 'nnunet',    'bin', 'python'), ...
        '/usr/bin/python3', 'python3', 'python'};
    py = '';
    for k = 1:numel(candidates)
        c = candidates{k};
        if isempty(c); continue; end
        cmd = sprintf('%s -c "import nnunetv2" 2>/dev/null', c);
        [rc, ~] = system(cmd);
        if rc == 0; py = c; return; end
    end
end
