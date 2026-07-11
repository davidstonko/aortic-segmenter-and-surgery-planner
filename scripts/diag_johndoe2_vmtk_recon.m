function diag_johndoe2_vmtk_recon()
%DIAG_JOHNDOE2_VMTK_RECON  Why does the post-reconnection JohnDoe2 mask
%   (one 26-CC, reaches FOV bottom) yield a DEGENERATE VMTK centerline
%   (right branch = 2 nodes, arc 0 mm) when the pre-reconnection mask gave
%   a healthy full-length centerline?
%
%   Hypothesis: the reconnection's thin (1-2 voxel) contrast bridges keep
%   the VOLUME connected but get pinched off by marching-cubes decimation
%   (reduce=0.5) + Laplacian smoothing, splitting the SURFACE mesh so
%   vmtkcenterlines can't route source->distal target.
%
%   This probes mask-prep (morphological closing) and decimation knobs and
%   reports R/L node count + arc for each, plus a pre-reconnect control.
%   Writes results/logs/johndoe2_vmtk_recon.txt (pollable).

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(proj));
    logdir = fullfile(proj, 'results', 'logs');
    txt = fullfile(logdir, 'johndoe2_vmtk_recon.txt');
    fid = fopen(txt, 'w'); c = onCleanup(@() fclose(fid));
    logf = @(varargin) logboth(fid, varargin{:});

    SH = load(fullfile(logdir, 'johndoe2_ct.mat')); D = SH.D;
    H  = load(fullfile(logdir, 'johndoe2_completecheck', 'planner_result.mat'));
    P  = load(fullfile(logdir, 'johndoe2_leakfix', 'planner_result.mat'));
    prox = H.seeds.proximal; R = H.seeds.right_cfa; L = H.seeds.left_cfa;
    logf('JohnDoe2 seeds (post): prox=%s R=%s L=%s\n', mat2str(prox), mat2str(R), mat2str(L));
    logf('post-reconnect mask nnz=%d   pre-reconnect mask nnz=%d\n\n', nnz(H.mask), nnz(P.mask));

    klargest = @(M) keep_largest(M);
    variants = {
        'asis_r0.5',        H.mask,                              struct('reduce',0.5,'smooth_iters',10)
        'close1_r0.5',      klargest(imclose(H.mask, strel('sphere',1))), struct('reduce',0.5,'smooth_iters',10)
        'close2_r0.5',      klargest(imclose(H.mask, strel('sphere',2))), struct('reduce',0.5,'smooth_iters',10)
        'asis_r0.0',        H.mask,                              struct('reduce',0.0,'smooth_iters',10)
        'asis_r0.2',        H.mask,                              struct('reduce',0.2,'smooth_iters',10)
        'close1_r0.2',      klargest(imclose(H.mask, strel('sphere',1))), struct('reduce',0.2,'smooth_iters',10)
        'PRE_asis_r0.5',    P.mask,                              struct('reduce',0.5,'smooth_iters',10)
    };

    for vi = 1:size(variants,1)
        nm = variants{vi,1}; M = variants{vi,2}; o = variants{vi,3};
        o.keep_work = false;
        try
            t0 = tic;
            cl = vmtk_centerline.compute(M, prox, R, L, D, o);
            aR = arclen(cl.Pv_mm_right); aL = arclen(cl.Pv_mm_left);
            logf('%-14s nnz=%8d  R: n=%4d arc=%6.1f   L: n=%4d arc=%6.1f   (%.0fs)\n', ...
                nm, nnz(M), size(cl.Pv_mm_right,1), aR, size(cl.Pv_mm_left,1), aL, toc(t0));
        catch ME
            logf('%-14s ERROR: %s\n', nm, ME.message);
        end
    end
    logf('\nDONE.\n');
end

function logboth(fid, fmt, varargin)
    fprintf(1, fmt, varargin{:});
    fprintf(fid, fmt, varargin{:});
end

function M2 = keep_largest(M)
    cc = bwconncomp(M, 26);
    if cc.NumObjects <= 1; M2 = M; return; end
    [~, k] = max(cellfun(@numel, cc.PixelIdxList));
    M2 = false(size(M)); M2(cc.PixelIdxList{k}) = true;
end

function a = arclen(P)
    if size(P,1) < 2; a = 0; else; a = sum(vecnorm(diff(P),2,2)); end
end
