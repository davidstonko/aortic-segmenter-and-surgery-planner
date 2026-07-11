function out = run(D, opts)
%AUTOSEG.AORTASEG24.RUN  Run an AortaSeg24-compatible multi-class segmenter.
%
%   OUT = autoseg.aortaseg24.run(D)
%   OUT = autoseg.aortaseg24.run(D, OPTS)
%
%   The parallel of `autoseg.ts_run` for the AortaSeg24 multi-class
%   network. Produces a segmentation with up to 23 labels (per the
%   challenge dictionary) which is then translated into the pipeline's
%   canonical labels (1=aorta, 2/3=iliacs, 4/5=CFAs, 6/7=renals,
%   8=celiac, 9=SMA; 10/11 reserved for wall/ILT but NOT produced by
%   AortaSeg24 — see docs/AORTASEG24_LABEL_MAP.md).
%
%   Phase B1 — pretrained nnU-Net checkpoint inference (2026-06-15).
%   This wires the *inference glue* for a single-stage nnU-Net v2
%   `nnUNetv2_predict` run. It is structured so that the moment an
%   actual AortaSeg24 checkpoint dir is present (env AORTASEG24_MODEL_DIR
%   or a standard nnUNet_results location) the path executes end-to-end:
%     (a) detect the checkpoint + python/nnUNet env,
%     (b) write D.vol to NIfTI in nnU-Net's expected `_0000` layout,
%     (c) shell out to nnUNetv2_predict,
%     (d) read the multilabel output back,
%     (e) translate_labels → pipeline-canonical labels.
%
%   No weights are bundled (none are publicly distributed as of
%   2026-06-15 — see the B1 audit in docs/AORTASEG24_LABEL_MAP.md). When
%   the model dir is absent, run() errors cleanly with
%   'autoseg:aortaseg24:Phase_B_needs_weights' and precise instructions
%   rather than fabricating any segmentation.
%
%   Inputs
%       D     struct from preprocess.dicom_load — needs .vol + spacing
%             (.pixel_mm, .slice_spacing_mm)
%       opts  struct, optional:
%           .cache_dir       where intermediate NIfTI / checkpoint
%                            results live (default `.cache/aortaseg24/`)
%           .work_dir        scratch dir for this run (default a tempname
%                            under cache_dir)
%           .force_recompute (default false) — ignore on-disk cache
%           .keep_work       (default false) — retain scratch NIfTIs
%           .dataset         nnU-Net dataset name/id for the predict call
%                            (default from AORTASEG24_DATASET env, else
%                            'Dataset824_AortaSeg24_CTA_50')
%           .configuration   nnU-Net configuration (default '3d_fullres')
%           .folds           fold spec passed to -f (default 'all')
%           .trainer_plans   optional '<trainer>__<plans>' string passed
%                            via -tr/-p; default '' (let nnUNet pick the
%                            single model present)
%           .timeout_s       CLI hard timeout hint, informational only
%
%   Output struct
%       OUT.mask           Y×X×Z logical: union of all in-scope vessel
%                          classes (pipeline_label > 0)
%       OUT.label          Y×X×Z uint8: pipeline-canonical labels (see
%                          translate_labels.m)
%       OUT.label_raw      Y×X×Z uint8: raw AortaSeg24 multilabel output
%       OUT.classes        struct array describing each present class:
%                            .id, .name, .pipeline_label, .voxels
%       OUT.invocation     cellstr of CLI commands run
%       OUT.timing         struct of per-stage seconds
%       OUT.backend        which detect() backend produced this
%       OUT.from_cache     logical
%
%   Errors
%       'autoseg:aortaseg24:Unavailable'
%                       — no backend detected at all. See
%                         docs/AORTASEG24_LABEL_MAP.md for install paths.
%       'autoseg:aortaseg24:Phase_B_needs_weights'
%                       — a python/nnUNet env was found but no AortaSeg24
%                         checkpoint dir is present (the current state for
%                         everyone, since no public checkpoint exists).
%                         The error message lists the exact files/env vars
%                         the user must provide to close Phase B.
%       'autoseg:aortaseg24:PredictFailed'
%                       — nnUNetv2_predict returned non-zero.
%       'autoseg:aortaseg24:NoOutput'
%                       — predict succeeded but no NIfTI was written.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D    (1,1) struct
        opts (1,1) struct = struct()
    end
    proj_root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    if ~isfield(opts, 'cache_dir')
        opts.cache_dir = fullfile(proj_root, '.cache', 'aortaseg24');
    end
    if ~isfield(opts, 'force_recompute'); opts.force_recompute = false; end
    if ~isfield(opts, 'keep_work');       opts.keep_work       = false; end
    if ~isfield(opts, 'configuration');   opts.configuration   = '3d_fullres'; end
    if ~isfield(opts, 'folds');           opts.folds           = 'all'; end
    if ~isfield(opts, 'trainer_plans');   opts.trainer_plans   = ''; end
    if ~isfield(opts, 'dataset') || isempty(opts.dataset)
        ds = getenv('AORTASEG24_DATASET');
        if isempty(ds); ds = 'Dataset824_AortaSeg24_CTA_50'; end
        opts.dataset = ds;
    end

    info = autoseg.aortaseg24.detect();
    if ~info.available
        ME = MException('autoseg:aortaseg24:Unavailable', ...
            'AortaSeg24 backend not detected. %s', info.error);
        throw(ME);
    end

    % --- B1 guard: do we actually have weights to run? ----------------
    % detect() can report available=true on an `env_override` (developer
    % hook) or on a python/nnUNet env even before any checkpoint is on
    % disk. run() must NOT fabricate output, so verify a usable
    % checkpoint dir exists before shelling out.
    model_dir = resolve_model_dir(info);
    if isempty(model_dir)
        throw(needs_weights_error(info, opts));
    end

    % =====================================================================
    %  B1 inference path (executes once a real checkpoint dir is present)
    % =====================================================================
    if ~isfield(opts, 'work_dir')
        opts.work_dir = fullfile(opts.cache_dir, ...
            sprintf('run_%s', char(java.util.UUID.randomUUID)));
    end
    if ~exist(opts.work_dir, 'dir'); mkdir(opts.work_dir); end
    cleanup = onCleanup(@() cleanup_work(opts));

    timing = struct();
    invocation = {};
    sz = size(D.vol);

    % --- (b) write input volume to NIfTI in nnU-Net `_0000` layout -----
    % nnU-Net predict consumes a folder of `<case>_<modality4>.nii.gz`.
    % Single-modality CT → channel 0000.
    in_dir  = fullfile(opts.work_dir, 'in');
    out_dir = fullfile(opts.work_dir, 'out');
    if ~exist(in_dir, 'dir');  mkdir(in_dir);  end
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end
    ct_path = fullfile(in_dir, 'AORTASEG24_CASE_0000.nii.gz');
    t0 = tic;
    io.save_nifti(D, ct_path);
    % nnUNetv2_predict reads the input *directory* (in_dir), not ct_path
    % directly, so we only need to confirm save_nifti dropped a file in
    % the expected `_0000` layout (it normalizes the extension itself).
    if isempty(dir(fullfile(in_dir, 'AORTASEG24_CASE_0000*.nii*')))
        ME = MException('autoseg:aortaseg24:NoOutput', ...
            'save_nifti did not write the input volume into %s', in_dir);
        throw(ME);
    end
    timing.write_nifti = toc(t0);

    % --- (c) shell out to nnUNetv2_predict -----------------------------
    log_path = fullfile(opts.work_dir, 'predict_log.txt');
    cmd = build_predict_cmd(info, model_dir, in_dir, out_dir, log_path, opts);
    invocation{end+1} = cmd;
    t0 = tic;
    [rc, ~] = system(cmd);
    timing.predict = toc(t0);
    if rc ~= 0
        log_text = '';
        if exist(log_path, 'file'); log_text = fileread(log_path); end
        if numel(log_text) > 4000; log_text = log_text(end-4000:end); end
        ME = MException('autoseg:aortaseg24:PredictFailed', ...
            ['nnUNetv2_predict failed (rc=%d, %.1fs).\n\nCommand:\n  %s\n\n' ...
             'Tail of log:\n%s'], rc, timing.predict, cmd, log_text);
        throw(ME);
    end

    % --- (d) read the multilabel output back ---------------------------
    seg_path = find_seg_output(out_dir);
    if isempty(seg_path)
        d = dir(fullfile(out_dir, '*'));
        names = setdiff({d.name}, {'.', '..'});
        ME = MException('autoseg:aortaseg24:NoOutput', ...
            ['nnUNetv2_predict reported success but no NIfTI label volume ' ...
             'was found in %s. Files present: %s'], out_dir, ...
            strjoin(names, ', '));
        throw(ME);
    end
    t0 = tic;
    label_raw = io.load_nifti_int(seg_path, sz);
    label_raw = uint8(label_raw);
    timing.read_nifti = toc(t0);

    % --- (e) translate AortaSeg24 raw labels → pipeline labels ---------
    t0 = tic;
    [label_out, classes] = autoseg.aortaseg24.translate_labels( ...
        label_raw, info.class_map);
    timing.translate = toc(t0);

    out = struct();
    out.mask       = label_out > 0;
    out.label      = label_out;
    out.label_raw  = label_raw;
    out.classes    = classes;
    out.invocation = invocation;
    out.timing     = timing;
    out.backend    = info.backend;
    out.from_cache = false;
end

% =========================================================================
function model_dir = resolve_model_dir(info)
%RESOLVE_MODEL_DIR  Return a checkpoint dir only if one truly exists.
%   Priority: explicit AORTASEG24_MODEL_DIR env → detect()'s .weights.
%   Returns '' when nothing usable is on disk (the common case today).
    model_dir = '';
    envd = getenv('AORTASEG24_MODEL_DIR');
    if ~isempty(envd) && exist(envd, 'dir')
        model_dir = envd;
        return;
    end
    if isfield(info, 'weights') && ~isempty(info.weights) && exist(info.weights, 'dir')
        model_dir = info.weights;
    end
end

% =========================================================================
function cmd = build_predict_cmd(info, model_dir, in_dir, out_dir, log_path, opts)
%BUILD_PREDICT_CMD  Assemble the nnUNetv2_predict invocation.
%   nnU-Net v2 inference accepts either:
%     (A) a fully-specified model via -d/-c/-f (needs nnUNet_results env
%         pointing at the parent of the dataset dir), or
%     (B) a direct model folder via -m / --model.
%   We prefer (B) when model_dir points straight at a configuration dir
%   (it contains plans.json + fold_*/checkpoint_final.pth); otherwise we
%   fall back to (A) and let nnU-Net resolve from nnUNet_results.
    py = info.python;
    if isempty(py); py = 'python'; end

    use_direct_folder = isfile(fullfile(model_dir, 'plans.json')) || ...
                        isfile(fullfile(model_dir, 'dataset.json'));

    parts = {sprintf('%s -m nnunetv2.inference.predict_from_raw_data', escape(py))};
    % NOTE: the console-script `nnUNetv2_predict` is equivalent; we invoke
    % the module form so it binds to info.python's env explicitly (mirrors
    % how vmtk_centerline pins the interpreter rather than trusting PATH).

    if use_direct_folder
        parts{end+1} = '-m'; parts{end+1} = escape(model_dir);
    else
        % Resolve-from-results mode: model_dir is the dataset root.
        parts{end+1} = '-d'; parts{end+1} = escape(opts.dataset);
        parts{end+1} = '-c'; parts{end+1} = escape(opts.configuration);
        if ~isempty(opts.trainer_plans)
            tp = split(string(opts.trainer_plans), '__');
            if numel(tp) == 2
                parts{end+1} = '-tr'; parts{end+1} = escape(char(tp(1)));
                parts{end+1} = '-p';  parts{end+1} = escape(char(tp(2)));
            end
        end
    end
    parts{end+1} = '-i'; parts{end+1} = escape(in_dir);
    parts{end+1} = '-o'; parts{end+1} = escape(out_dir);
    parts{end+1} = '-f'; parts{end+1} = escape_folds(opts.folds);

    cmd = sprintf('%s > %s 2>&1', strjoin(parts, ' '), escape(log_path));
end

% =========================================================================
function s = escape_folds(folds)
%ESCAPE_FOLDS  Render the -f fold spec (scalar, 'all', or numeric list).
    if ischar(folds) || isstring(folds)
        s = char(folds);
    elseif isnumeric(folds)
        s = strjoin(arrayfun(@(x) sprintf('%d', x), folds(:)', ...
            'UniformOutput', false), ' ');
    else
        s = 'all';
    end
end

% =========================================================================
function p = find_seg_output(out_dir)
%FIND_SEG_OUTPUT  Locate the single label NIfTI nnU-Net wrote.
%   nnU-Net writes `<case>.nii.gz` (no `_0000`) plus aux json/npz files.
    p = '';
    d = dir(fullfile(out_dir, '*.nii.gz'));
    if isempty(d)
        d = dir(fullfile(out_dir, '*.nii'));
    end
    if isempty(d); return; end
    p = fullfile(d(1).folder, d(1).name);
end

% =========================================================================
function ME = needs_weights_error(info, opts)
%NEEDS_WEIGHTS_ERROR  Clean, actionable error when no checkpoint exists.
    msg = sprintf([ ...
        'AortaSeg24 backend (%s) detected, but NO trained checkpoint is ' ...
        'available, so run() refuses to fabricate a segmentation.\n\n' ...
        'No public AortaSeg24 checkpoint is distributed (verified ' ...
        '2026-06-15: the challenge repos ship training code only). To ' ...
        'close Phase B you must supply weights, then point the planner ' ...
        'at them:\n\n' ...
        '  1. Obtain a trained nnU-Net v2 AortaSeg24 model, EITHER by\n' ...
        '       (B2/B3) training from the public code + dataset, see\n' ...
        '       github.com/PengchengShi1220/AortaSeg24 (Apache-2.0), OR\n' ...
        '       by obtaining weights directly from a challenge team.\n' ...
        '  2. Place the configuration dir (the folder containing\n' ...
        '       plans.json/dataset.json + fold_*/checkpoint_final.pth)\n' ...
        '       somewhere on disk.\n' ...
        '  3. export AORTASEG24_MODEL_DIR=/path/to/that/dir\n' ...
        '       (or place it under $nnUNet_results/%s and set\n' ...
        '        nnUNet_results accordingly).\n' ...
        '  4. Ensure %s has nnunetv2 importable.\n\n' ...
        'Once AORTASEG24_MODEL_DIR exists, run() will execute the full\n' ...
        'nnUNetv2_predict inference path automatically. See\n' ...
        'docs/AORTASEG24_LABEL_MAP.md for the full B1/B2/B3 decision.'], ...
        info.backend, opts.dataset, py_or_default(info.python));
    ME = MException('autoseg:aortaseg24:Phase_B_needs_weights', '%s', msg);
end

function s = py_or_default(py)
    if isempty(py); s = 'your python interpreter'; else; s = py; end
end

% =========================================================================
function cleanup_work(opts)
    if ~opts.keep_work && isfield(opts, 'work_dir') && exist(opts.work_dir, 'dir')
        rmdir(opts.work_dir, 's');
    end
end

% =========================================================================
function s = escape(p)
    s = ['"', strrep(char(p), '"', '\"'), '"'];
end
