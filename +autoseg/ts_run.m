function [mask, info] = ts_run(D, opts)
%AUTOSEG.TS_RUN  Simpler TS runner — no caching, verbose, debuggable.
%
%   [MASK, INFO] = autoseg.ts_run(D, opts)
%
%   opts:
%     .targets             cellstr of TS class names. Default = aorta + iliacs.
%     .ts_mode             'fast' (3 mm model, ~30 s) | 'full' (1.5 mm
%                          model, ~5-15 min, finer branch separation
%                          and missing-branch recovery). Default 'fast'.
%                          (Backward compat: a legacy `.fast` field is
%                          still honored if `.ts_mode` is not set.)
%     .fast                DEPRECATED: legacy boolean toggle. Equivalent
%                          to ts_mode='fast' (true) or ts_mode='full'
%                          (false). Honored if .ts_mode is unset; takes
%                          precedence only for backward compatibility.
%     .device              'mps' | 'cpu' | 'gpu' | '' (auto, default 'mps' on Apple Silicon).
%     .work_dir            scratch dir (default /tmp/ts_<pid>).
%     .return_label_volume true to populate info.label_volume with the
%                          full multilabel seg (uint8/16) — needed for
%                          anatomic seed detection (kidney/liver anchors).
%                          Default false.
%
%   Replaces autoseg.totalsegmentator for cases where the cache layer
%   was masking errors. Writes verbose log to <work_dir>/log.txt.

    arguments
        D    (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'targets')
        opts.targets = {'aorta', 'iliac_artery_left', 'iliac_artery_right'};
    end
    % Resolve ts_mode / legacy fast flag. Preferred field is .ts_mode
    % ('fast' | 'full'); .fast is the legacy boolean. Reconcile so the
    % rest of the function only reads .fast (which still drives the
    % --fast CLI flag and the cache key).
    if isfield(opts, 'ts_mode')
        switch lower(opts.ts_mode)
            case 'fast'; opts.fast = true;
            case 'full'; opts.fast = false;
            otherwise
                error('autoseg:ts_run:BadMode', ...
                    'opts.ts_mode must be ''fast'' or ''full'' (got ''%s'')', opts.ts_mode);
        end
    end
    if ~isfield(opts, 'fast'),    opts.fast    = true;  end
    if ~isfield(opts, 'device') || isempty(opts.device)
        [rc_arch, arch] = system('uname -m');
        if rc_arch == 0 && contains(strtrim(arch), 'arm64')
            opts.device = 'mps';
        else
            opts.device = '';
        end
    end
    if ~isfield(opts, 'cache_dir')
        here = fileparts(mfilename('fullpath'));
        opts.cache_dir = fullfile(fileparts(here), '.cache', 'autoseg');
    end
    if ~isfield(opts, 'return_label_volume'); opts.return_label_volume = false; end
    if ~exist(opts.cache_dir, 'dir'); mkdir(opts.cache_dir); end

    sz = size(D.vol);

    % --- Cache check (hash by volume size + spacing + fast flag) ------
    key = struct('sz', sz, 'pixel_mm', D.pixel_mm, ...
                 'slice_spacing_mm', D.slice_spacing_mm, ...
                 'fast', opts.fast);
    h = simple_hash(jsonencode(key));
    cache_seg = fullfile(opts.cache_dir, [h, '_seg.nii.gz']);
    if exist(cache_seg, 'file')
        fprintf('[ts_run] cache HIT: %s\n', cache_seg);
        try
            seg = niftiread(cache_seg);
            if isequal(size(seg), sz)
                [mask, info] = build_mask_from_seg(seg, opts.targets, sz);
                info.processing_time = 0;
                info.from_cache      = true;
                info.invocation      = 'cache';
                info.cli_version     = '';
                info.work_dir        = opts.cache_dir;
                if opts.return_label_volume
                    info.label_volume = seg;
                end
                return;
            end
        catch ME
            fprintf('[ts_run] cache read failed (%s) — re-running\n', ME.message);
        end
    end

    if ~isfield(opts, 'work_dir')
        opts.work_dir = sprintf('/tmp/ts_run_%s', char(java.util.UUID.randomUUID));
    end
    if ~exist(opts.work_dir, 'dir'); mkdir(opts.work_dir); end

    fprintf('[ts_run] work_dir = %s\n', opts.work_dir);

    avail = autoseg.detect();
    if ~avail.available
        error('autoseg:ts_run:Unavailable', ...
            'TotalSegmentator not found:\n%s', avail.error);
    end

    ct_path  = fullfile(opts.work_dir, 'ct.nii');     % uncompressed (faster, more reliable)
    seg_path = fullfile(opts.work_dir, 'seg.nii.gz');
    log_path = fullfile(opts.work_dir, 'log.txt');

    fprintf('[ts_run] saving NIfTI...\n');
    t0 = tic;
    io.save_nifti(D, ct_path);
    % save_nifti may have written .nii.gz instead — accept either
    if ~exist(ct_path, 'file') && exist([ct_path, '.gz'], 'file')
        ct_path = [ct_path, '.gz'];
    elseif ~exist(ct_path, 'file')
        % Some versions of save_nifti write .nii.gz when path ends .nii?
        d = dir(fullfile(opts.work_dir, 'ct*'));
        if numel(d) >= 1
            ct_path = fullfile(d(1).folder, d(1).name);
        end
    end
    fprintf('[ts_run] NIfTI saved at %s in %.2fs\n', ct_path, toc(t0));

    parts = {avail.invocation, '-i', escape(ct_path), '-o', escape(seg_path), ...
             '--task', 'total', '-ml'};
    if opts.fast, parts{end+1} = '--fast'; end
    if ~isempty(opts.device), parts{end+1} = '--device'; parts{end+1} = opts.device; end
    cmd = sprintf('%s > %s 2>&1', strjoin(parts, ' '), escape(log_path));
    fprintf('[ts_run] %s\n', cmd);

    t0 = tic;
    [rc, ~] = system(cmd);
    elapsed = toc(t0);
    if rc ~= 0
        log_text = '';
        if exist(log_path, 'file'), log_text = fileread(log_path); end
        if length(log_text) > 4000, log_text = log_text(end-4000:end); end
        error('autoseg:ts_run:Failed', ...
            'TS failed (rc=%d, %.1fs):\n%s', rc, elapsed, log_text);
    end
    fprintf('[ts_run] TS done in %.1fs\n', elapsed);

    if ~exist(seg_path, 'file')
        d = dir(fullfile(opts.work_dir, '*.nii*'));
        names = {d.name};
        error('autoseg:ts_run:NoOutput', ...
            'TS reported success but seg file missing. Files: %s', strjoin(names, ', '));
    end

    fprintf('[ts_run] reading multilabel NIfTI...\n');
    seg = niftiread(seg_path);
    if ~isequal(size(seg), sz)
        error('autoseg:ts_run:SizeMismatch', ...
            'Seg size [%s] != input size [%s]', mat2str(size(seg)), mat2str(sz));
    end

    [mask, info] = build_mask_from_seg(seg, opts.targets, sz);
    info.processing_time = elapsed;
    info.from_cache      = false;
    info.invocation      = strjoin(parts, ' ');
    info.cli_version     = avail.version;
    info.work_dir        = opts.work_dir;
    if opts.return_label_volume
        info.label_volume = seg;
    end

    % --- Save the multilabel seg into the long-lived cache so the
    %     next run with the same volume returns instantly.
    try
        copyfile(seg_path, cache_seg);
        fprintf('[ts_run] cached seg → %s\n', cache_seg);
    catch ME
        fprintf('[ts_run] cache write failed: %s\n', ME.message);
    end
end

function [mask, info] = build_mask_from_seg(seg, targets, sz)
    name2id = autoseg.class_name_to_id();
    mask = false(sz);
    voxel_counts = zeros(1, numel(targets));
    targets_found = {};
    for k = 1:numel(targets)
        nm = targets{k};
        if ~isKey(name2id, nm), continue; end
        cid = name2id(nm);
        m_k = (seg == cid);
        n = nnz(m_k);
        voxel_counts(k) = n;
        if n > 0
            mask = mask | m_k;
            targets_found{end+1} = nm; %#ok<AGROW>
        end
    end
    info = struct('targets_found', {targets_found}, ...
                  'voxel_counts', voxel_counts);
end

function h = simple_hash(s)
    try
        md = java.security.MessageDigest.getInstance('MD5');
        b = md.digest(uint8(s));
        h = sprintf('%02x', typecast(b, 'uint8'));
        h = h(1:12);
    catch
        h = sprintf('h%d', sum(double(s)));
    end
end

function s = escape(p)
    s = ['"', strrep(p, '"', '\"'), '"'];
end
