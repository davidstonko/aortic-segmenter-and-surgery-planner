function [mask, info] = totalsegmentator(D, opts)
%AUTOSEG.TOTALSEGMENTATOR  MATLAB wrapper around the TotalSegmentator CLI.
%
%   [MASK, INFO] = autoseg.totalsegmentator(D)
%   [MASK, INFO] = autoseg.totalsegmentator(D, opts)
%
%   Calls the external tool:
%       Wasserthal J, Breit H-C, Meyer MT, et al. TotalSegmentator:
%       Robust Segmentation of 104 Anatomic Structures in CT Images.
%       Radiology: Artificial Intelligence 2023;5(5):e230024.
%       https://github.com/wasserth/TotalSegmentator   (Apache 2.0)
%
%   Internals: writes D.vol to a temporary NIfTI, invokes the
%   TotalSegmentator CLI with the requested ROI subset, reads the
%   resulting label map(s) back into a logical mask aligned to the
%   original voxel grid, and cleans up temp files.
%
%   Inputs
%       D       struct from preprocess.dicom_load (must have .vol,
%               .pixel_mm, .slice_spacing_mm, .is_volume == true)
%       opts    struct with optional fields:
%           .targets        cellstr of TotalSegmentator label names
%                           default {'aorta', 'iliac_artery_left', ...
%                                    'iliac_artery_right'}
%           .task           default 'total' (full 117-class model)
%           .fast           logical, pass --fast for 3 mm model
%                           (default false — full-res model)
%           .device         'gpu' | 'cpu' | '' (auto, default '')
%           .cache_dir      where to keep temp + cached results
%                           default <project>/.cache/autoseg/
%           .force          true to bypass cache (default false)
%           .timeout_s      seconds before the CLI is considered hung
%                           default 600 (10 min)
%
%   Outputs
%       MASK    logical, same size as D.vol, true where ANY of the
%               requested ROIs are labeled.
%       INFO    struct:
%           .targets_found      cellstr of ROIs actually returned
%           .voxel_counts       int per target
%           .processing_time    seconds (CLI runtime)
%           .from_cache         logical
%           .invocation         the exact command we ran
%           .label_volume       optional Y×X×Z uint8 with per-target
%                               labels (1..N for the targets list);
%                               only populated if requested via
%                               opts.return_label_volume = true
%
%   Errors
%       Raises 'autoseg:totalsegmentator:Unavailable' if the CLI is
%       missing, or 'autoseg:totalsegmentator:Failed' on runtime error.
%
%   Notes
%       - Cache is keyed by an md5 of (volume size, spacing, target
%         set, fast/full mode). Re-running with the same arguments
%         returns the cached mask in milliseconds.
%       - The volume is shipped as a voxel-aligned identity-affine
%         NIfTI; the mask comes back on the same grid (no resampling
%         needed). See io.save_nifti for the convention.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D    (1,1) struct
        opts (1,1) struct = struct()
    end

    % --- Defaults -----
    if ~isfield(opts, 'targets')
        opts.targets = {'aorta', 'iliac_artery_left', 'iliac_artery_right'};
    end
    if ~isfield(opts, 'task');      opts.task      = 'total';  end
    if ~isfield(opts, 'fast');      opts.fast      = false;    end
    if ~isfield(opts, 'device') || isempty(opts.device)
        % Auto-detect best device. On Apple Silicon (M1/M2/M3),
        % use 'mps' (Metal Performance Shaders) — gives 3-10× speedup
        % over CPU. On Linux/Windows with CUDA, leave empty so TS
        % auto-picks GPU. Otherwise CPU.
        [rc_arch, arch] = system('uname -m');
        if rc_arch == 0 && contains(strtrim(arch), 'arm64')
            opts.device = 'mps';
        else
            opts.device = '';
        end
    end
    if ~isfield(opts, 'force');     opts.force     = false;    end
    if ~isfield(opts, 'timeout_s'); opts.timeout_s = 600;      end
    if ~isfield(opts, 'return_label_volume'); opts.return_label_volume = false; end
    if ~isfield(opts, 'cache_dir')
        % Default cache lives next to the package, gitignored.
        here = fileparts(mfilename('fullpath'));
        opts.cache_dir = fullfile(fileparts(here), '.cache', 'autoseg');
    end

    assert(D.is_volume, 'autoseg:totalsegmentator:NotVolume', 'D must be a CT volume.');
    sz = size(D.vol);

    % --- Availability check -----
    avail = autoseg.detect();
    if ~avail.available
        ME = MException('autoseg:totalsegmentator:Unavailable', ...
            ['TotalSegmentator CLI not found.\n\n%s\n\nInstall with:\n' ...
             '  conda create -n evar-tools python=3.11\n' ...
             '  conda activate evar-tools\n' ...
             '  pip install TotalSegmentator'], avail.error);
        throw(ME);
    end

    % --- Cache key ----
    if ~exist(opts.cache_dir, 'dir'); mkdir(opts.cache_dir); end
    key = struct( ...
        'sz', sz, ...
        'pixel_mm', D.pixel_mm, ...
        'slice_spacing_mm', D.slice_spacing_mm, ...
        'targets', sort(opts.targets), ...
        'task', opts.task, ...
        'fast', opts.fast);
    key_hash = simple_hash(jsonencode(key));
    cache_file = fullfile(opts.cache_dir, [key_hash, '.mat']);
    if ~opts.force && exist(cache_file, 'file')
        S = load(cache_file);
        mask = S.mask;
        info = S.info;  info.from_cache = true;
        return;
    end

    % --- Stage NIfTI -----
    work_dir = fullfile(opts.cache_dir, ['ts_', key_hash]);
    if ~exist(work_dir, 'dir'); mkdir(work_dir); end
    cleanup = onCleanup(@() rmdir_safe(work_dir));
    ct_path = fullfile(work_dir, 'ct.nii.gz');
    out_dir = fullfile(work_dir, 'ts_out');

    io.save_nifti(D, ct_path);

    % --- Build the CLI command -----
    %
    % Use TS's `-ml` (multilabel) mode: writes a SINGLE multi-label
    % NIfTI with integer labels 1..N for the 117 classes, instead of
    % per-class binary NIfTIs. We then extract the labels we want by
    % class ID. This avoids a known bug where `--roi_subset` on the
    % `total` task can silently fail to write some classes (e.g., on
    % the JohnDoe1 CT it wrote aorta only, dropping the iliacs entirely).
    parts = {avail.invocation, '-i', escape(ct_path), '-o', escape(out_dir)};
    parts{end+1} = '--task'; parts{end+1} = opts.task;
    parts{end+1} = '-ml';   % multi-label single-file output
    if opts.fast; parts{end+1} = '--fast'; end
    if ~isempty(opts.device)
        parts{end+1} = '--device'; parts{end+1} = opts.device;
    end
    cmd = strjoin(parts, ' ');

    % --- Run -----
    t0 = tic;
    [rc, out] = system(cmd);
    elapsed = toc(t0);
    if rc ~= 0
        ME = MException('autoseg:totalsegmentator:Failed', ...
            ['TotalSegmentator failed (rc=%d, %.1fs).\n\nCommand:\n  %s\n\n' ...
             'Output:\n%s'], rc, elapsed, cmd, out);
        throw(ME);
    end

    % --- Read multilabel NIfTI and extract requested classes ----------
    % TS in `-ml` mode writes the multilabel volume to a single file.
    % The output path varies by TS version:
    %   • <out_dir>.nii        (TS v2.x, uncompressed, when -o has no ext)
    %   • <out_dir>.nii.gz     (some versions / when -o ends in .nii.gz)
    %   • <out_dir>/<task>.nii.gz   (older or if -o is a directory)
    %   • <out_dir>/multilabel.nii.gz
    candidates_ml = { ...
        [out_dir, '.nii'],                              % TS v2 default
        [out_dir, '.nii.gz'], ...
        fullfile(out_dir, [opts.task, '.nii.gz']), ...
        fullfile(out_dir, [opts.task, '.nii']), ...
        fullfile(out_dir, 'multilabel.nii.gz'), ...
        fullfile(out_dir, 'multilabel.nii') };
    nii_ml = '';
    for ic = 1:numel(candidates_ml)
        if exist(candidates_ml{ic}, 'file')
            nii_ml = candidates_ml{ic};
            break;
        end
    end
    if isempty(nii_ml)
        % Fall back: search for any .nii / .nii.gz next to out_dir
        parent = fileparts(out_dir);
        siblings = [dir(fullfile(parent, '*.nii.gz')); dir(fullfile(parent, '*.nii'))];
        for si = 1:numel(siblings)
            if startsWith(siblings(si).name, [out_dir(numel(parent)+2:end), '.'])
                nii_ml = fullfile(siblings(si).folder, siblings(si).name);
                break;
            end
        end
    end
    if isempty(nii_ml)
        % Final fallback: any single .nii.gz inside out_dir
        d = dir(fullfile(out_dir, '*.nii.gz'));
        if numel(d) == 1
            nii_ml = fullfile(d(1).folder, d(1).name);
        end
    end
    if isempty(nii_ml)
        ME = MException('autoseg:totalsegmentator:NoOutput', ...
            'TotalSegmentator finished but no NIfTI output was found in %s', out_dir);
        throw(ME);
    end

    % Load the multilabel NIfTI as int volume
    label_full = io.load_nifti_int(nii_ml, sz);
    % Class-name → label-id map for TS v2.x `total` task
    name2id = autoseg.class_name_to_id();

    mask = false(sz);
    voxel_counts = zeros(1, numel(opts.targets));
    targets_found = {};
    if opts.return_label_volume
        label_vol = zeros(sz, 'uint8');
    end
    for k = 1:numel(opts.targets)
        nm = opts.targets{k};
        if ~isKey(name2id, nm)
            fprintf('[totalsegmentator] unknown class name "%s" — skipped\n', nm);
            continue;
        end
        cid = name2id(nm);
        m_k = (label_full == cid);
        if any(m_k(:))
            mask = mask | m_k;
            voxel_counts(k) = sum(m_k(:));
            targets_found{end+1} = nm; %#ok<AGROW>
            if opts.return_label_volume
                label_vol(m_k & label_vol == 0) = uint8(k);
            end
        end
    end

    info = struct();
    info.targets_found   = targets_found;
    info.voxel_counts    = voxel_counts;
    info.processing_time = elapsed;
    info.from_cache      = false;
    info.invocation      = cmd;
    info.cli_version     = avail.version;
    if opts.return_label_volume
        info.label_volume = label_vol; %#ok<STRNU>
    end

    % --- Cache the result ---
    save(cache_file, 'mask', 'info', '-v7.3');
end

% =========================================================================
function s = escape(p)
%ESCAPE  Wrap a shell argument in double quotes, handling spaces.
    s = ['"', strrep(p, '"', '\"'), '"'];
end

function rmdir_safe(p)
    if exist(p, 'dir'); rmdir(p, 's'); end
end

function h = simple_hash(s)
%SIMPLE_HASH  Short hex digest of a string. We prefer the platform's
%   md5 utility; if not present, a Java MessageDigest fallback works
%   on all MATLAB releases.
    try
        md = java.security.MessageDigest.getInstance('MD5');
        b  = typecast(uint8(s), 'int8');
        bs = md.digest(b);
        h  = lower(reshape(dec2hex(typecast(bs, 'uint8'), 2).', 1, []));
        h  = h(1:12);   % short prefix is plenty for cache keys
    catch
        h = sprintf('%010d', mod(sum(double(s)) * 2654435761, 1e10));
    end
end
