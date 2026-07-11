function [grown, info] = hu_reconstruct_shell(mask, vol, opts)
%AUTOSEG.HU_RECONSTRUCT_SHELL  Grow a vessel MASK through CT contrast within
%   a thin shell around it, allocating the intermediate full-resolution
%   boolean volumes ONLY over the sub-volume the vessels occupy.
%
%   [GROWN, INFO] = autoseg.hu_reconstruct_shell(MASK, VOL, OPTS)
%
%   This is the Step-3c HU-reconstruct: it dilates MASK by a ~5 mm shell,
%   keeps the CT contrast voxels (HU in [contrast_hu_lo, contrast_hu_hi])
%   inside that shell — with an in-plane size cap so the grow can't leak
%   into cancellous bone / IVC / bowel — and 26-connected-reconstructs
%   MASK through them. No synthetic voxels are introduced: GROWN only ever
%   contains voxels connected to MASK through genuine contrast.
%
%   Memory (GOALS #39): on a large-FOV / runoff CTA the naive form
%   allocates 4-5 full-resolution boolean volumes (contrast mask, shell,
%   candidate, grown) over the WHOLE scan — hundreds of M-voxels each even
%   though the vessels span a fraction of the z-extent. Here every op runs
%   on a crop = bounding-box(MASK) padded by the shell radius in all three
%   dims. Because the reconstruction is bounded to `cand` ⊆ shell (within
%   shell_r of MASK), GROWN ⊆ dilate(MASK, shell_r); the padded crop
%   therefore contains every voxel any full-volume op could set, and the
%   per-slice size cap sees the full shell within each cropped slice — so
%   the cropped result is BIT-IDENTICAL to the full-volume result while
%   allocating only crop_frac of the memory.
%
%   OPTS:
%     .pix_mm           in-plane pixel size (mm), sets the shell radius
%                       (5 mm) and the in-plane cap    (default 1)
%     .contrast_hu_lo   contrast HU floor               (default 150)
%     .contrast_hu_hi   contrast HU ceiling             (default 1400)
%     .inplane_cap_mm2  drop in-plane CCs larger than this (default 400)
%
%   INFO fields: .n_added, .shell_r, .bbox [r0 r1 c0 c1 z0 z1], .crop_frac
%
%   RESEARCH USE ONLY.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask logical
        vol
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'pix_mm');          opts.pix_mm          = 1;    end
    if ~isfield(opts, 'contrast_hu_lo');  opts.contrast_hu_lo  = 150;  end
    if ~isfield(opts, 'contrast_hu_hi');  opts.contrast_hu_hi  = 1400; end
    if ~isfield(opts, 'inplane_cap_mm2'); opts.inplane_cap_mm2 = 400;  end

    grown = mask;
    info  = struct('n_added', 0, 'shell_r', 0, 'bbox', [], 'crop_frac', 1);
    if ~any(mask(:)) || isempty(vol); return; end

    pix_mm  = abs(opts.pix_mm);
    shell_r = max(3, round(5 / pix_mm));
    info.shell_r = shell_r;

    % --- Crop to bbox(mask) padded by the shell radius ---------------
    sz = size(mask);
    [ys, xs, zs] = ind2sub(sz, find(mask));
    pad = shell_r + 1;                              % +1 for safety margin
    r0 = max(1, min(ys) - pad); r1 = min(sz(1), max(ys) + pad);
    c0 = max(1, min(xs) - pad); c1 = min(sz(2), max(xs) + pad);
    z0 = max(1, min(zs) - pad); z1 = min(sz(3), max(zs) + pad);
    info.bbox      = [r0 r1 c0 c1 z0 z1];
    info.crop_frac = ((r1 - r0 + 1) * (c1 - c0 + 1) * (z1 - z0 + 1)) / numel(mask);

    m = mask(r0:r1, c0:c1, z0:z1);
    v = vol(r0:r1, c0:c1, z0:z1);

    % --- Shell-constrained, vessel-capped contrast grow --------------
    contrast = (v >= opts.contrast_hu_lo) & (v <= opts.contrast_hu_hi);
    shell    = imdilate(m, strel('sphere', shell_r));
    cand     = autoseg.drop_big_inplane_cc(contrast & shell, ...
                                           round(opts.inplane_cap_mm2 / pix_mm^2));
    g        = imreconstruct(m, m | cand, 26);

    grown = false(sz);
    grown(r0:r1, c0:c1, z0:z1) = g;
    info.n_added = nnz(grown) - nnz(mask);
end
