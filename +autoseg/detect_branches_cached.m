function [mask, label, info] = detect_branches_cached(D, seg, opts)
%AUTOSEG.DETECT_BRANCHES_CACHED  Disk-cached wrapper around
%   autoseg.extend_and_detect_branches. The branch labels rarely need
%   to be recomputed once you have a stable mask, but the underlying
%   call costs ~25 seconds on a typical 512×512×1219 CT. This wrapper
%   keys by the TS multilabel volume's MD5 + the volume's pixel spacing
%   so any change to either invalidates the cache. Same return shape as
%   extend_and_detect_branches: (MASK, LABEL, INFO).
%
%   OPTS:
%       .cache_dir   default `.cache/autoseg/` next to this file
%       .force       set true to bypass the cache (default false)
%       .verbose     forwarded to extend_and_detect_branches
%
%   Cache files: `<hash>_branches.mat` containing m_branch, label_branch, info.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D    (1,1) struct
        seg  uint8
        opts (1,1) struct = struct()
    end
    here = fileparts(mfilename('fullpath'));
    if ~isfield(opts, 'cache_dir')
        opts.cache_dir = fullfile(fileparts(here), '.cache', 'autoseg');
    end
    if ~isfield(opts, 'force');   opts.force = false; end
    if ~isfield(opts, 'verbose'); opts.verbose = true; end
    if ~exist(opts.cache_dir, 'dir'); mkdir(opts.cache_dir); end

    key = struct('size', size(seg), 'sum', sum(seg(:)>0), ...
                 'pixel_mm', D.pixel_mm, ...
                 'slice_spacing_mm', D.slice_spacing_mm);
    h = simple_hash(jsonencode(key));
    cache_path = fullfile(opts.cache_dir, [h '_branches.mat']);

    if ~opts.force && isfile(cache_path)
        if opts.verbose
            fprintf('[detect_branches_cached] cache HIT: %s\n', cache_path);
        end
        try
            S = load(cache_path);
            if all(isfield(S, {'m_branch', 'label_branch', 'info'}))
                mask = S.m_branch; label = S.label_branch; info = S.info;
                return;
            end
        catch ME
            if opts.verbose
                fprintf('[detect_branches_cached] cache read failed (%s) — recomputing\n', ME.message);
            end
        end
    end

    sub_opts = rmfield_if_present(opts, {'cache_dir', 'force'});
    [mask, label, info] = autoseg.extend_and_detect_branches(D, seg, sub_opts);
    try
        m_branch = mask; label_branch = label; %#ok<NASGU>
        save(cache_path, 'm_branch', 'label_branch', 'info', '-v7.3');
        if opts.verbose
            fprintf('[detect_branches_cached] cached → %s\n', cache_path);
        end
    catch ME
        if opts.verbose
            fprintf('[detect_branches_cached] cache write failed (%s)\n', ME.message);
        end
    end
end

function s = rmfield_if_present(s, fields)
    for k = 1:numel(fields)
        if isfield(s, fields{k}); s = rmfield(s, fields{k}); end
    end
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
