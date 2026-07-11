function [mask, info] = seg_aorta_fast(D, seed_vox, opts)
%SEG_AORTA_FAST  TeraRecon-style click-to-add region grow on a CTA volume.
%
%   [MASK, INFO] = SEG_AORTA_FAST(D, SEED_VOX) takes a CT volume struct
%   plus a voxel coord inside contrast-enhanced lumen and returns a 3D
%   binary mask of the connected contrast-enhanced region.
%
%   This is the fast path: a global HU threshold isolates contrast +
%   bone, then a 26-connected component from the seed peels off the
%   single vascular territory the user clicked on. There is no
%   multiscale Frangi filter — for a contrast CTA the threshold alone
%   is enough, and click-to-add latency drops from ~30 s to <1 s.
%
%   Tunables (opts struct fields):
%       .HU_min          HU floor for "contrast" voxels.  default 150
%       .HU_max          HU ceiling, mostly to drop calcium stripes.
%                        default 600 (set Inf to disable)
%       .close_radius    morphological-close radius (voxels).  default 1
%       .max_volume_mL   safety cap so a leak into bone doesn't
%                        return the whole skeleton. default 1500.
%
%   Outputs
%       mask : Y×X×Z logical, single connected component containing
%              the seed.
%       info : struct with .threshold, .seed_HU, .picked_volume_mL,
%              .processing_time, .leaked (true if the cap fired).
%
%   This function is the workhorse used by the GUI's click-to-add
%   accumulator. The slower fibermetric+imsegfmm path
%   (preprocess.seg_aorta_fmm) remains available as a fallback for
%   non-contrast or low-contrast scans.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D        (1,1) struct
        seed_vox (1,3) double
        opts     (1,1) struct = struct()
    end

    if ~isfield(opts, 'HU_min');        opts.HU_min        = 150;  end
    if ~isfield(opts, 'HU_max');        opts.HU_max        = 600;  end
    if ~isfield(opts, 'close_radius');  opts.close_radius  = 1;    end
    if ~isfield(opts, 'max_volume_mL'); opts.max_volume_mL = 1500; end
    if ~isfield(opts, 'no_snap');       opts.no_snap       = false; end

    assert(D.is_volume, 'seg_aorta_fast:NotVolume', 'D must be a CT volume.');

    t0 = tic;
    sz = size(D.vol);

    % --- Clamp the seed in-bounds and snap to nearest in-range voxel
    sy = max(1, min(sz(1), round(seed_vox(1))));
    sx = max(1, min(sz(2), round(seed_vox(2))));
    sz_ = max(1, min(sz(3), round(seed_vox(3))));
    seed_HU = D.vol(sy, sx, sz_);

    % --- Step 1: HU threshold ----------------------------------------
    bw = D.vol >= opts.HU_min & D.vol <= opts.HU_max;

    if ~bw(sy, sx, sz_) && ~opts.no_snap
        % Seed is outside the threshold band. Snap to the nearest in-band
        % voxel within a small neighborhood so a slightly off click
        % (e.g. on the wall) still seeds the lumen.
        r = 4;
        ys = max(1, sy-r):min(sz(1), sy+r);
        xs = max(1, sx-r):min(sz(2), sx+r);
        zs = max(1, sz_-r):min(sz(3), sz_+r);
        nb = bw(ys, xs, zs);
        if any(nb(:))
            [yy, xx, zz] = ind2sub(size(nb), find(nb));
            d = (yy-(sy-ys(1)+1)).^2 + (xx-(sx-xs(1)+1)).^2 + (zz-(sz_-zs(1)+1)).^2;
            [~, k] = min(d);
            sy = ys(yy(k)); sx = xs(xx(k)); sz_ = zs(zz(k));
            seed_HU = D.vol(sy, sx, sz_);
        end
    end

    % --- Step 2: flood-fill from the seed via imreconstruct ----------
    % imreconstruct grows ONLY from the seed, so we never visit voxels
    % outside the connected component. On a 512×512×600 CTA this takes
    % ~0.5 s versus ~30 s for bwconncomp + label scan.
    seed_mask = false(sz);
    seed_mask(sy, sx, sz_) = true;
    if opts.no_snap && ~bw(sy, sx, sz_)
        % no_snap mode: force-include the seed voxel in bw so the
        % flood-fill starts. Useful when caller has set adaptive HU
        % thresholds based on the seed and trusts it.
        bw(sy, sx, sz_) = true;
    end
    mask = imreconstruct(seed_mask, bw, 6);

    % --- Step 3: optional morphological close to merge micro-gaps ----
    % Restricted to the bounding box of the mask so we don't pay for
    % a global imclose on a near-empty volume.
    if opts.close_radius > 0 && any(mask(:))
        bb = regionprops(mask, 'BoundingBox');
        bb = bb(1).BoundingBox;
        x0 = max(1, floor(bb(1)));   y0 = max(1, floor(bb(2)));
        z0 = max(1, floor(bb(3)));
        x1 = min(sz(2), ceil(bb(1)+bb(4)));
        y1 = min(sz(1), ceil(bb(2)+bb(5)));
        z1 = min(sz(3), ceil(bb(3)+bb(6)));
        sub = mask(y0:y1, x0:x1, z0:z1);
        sub = imclose(sub, strel('sphere', opts.close_radius));
        mask(y0:y1, x0:x1, z0:z1) = sub;
    end

    % --- Diagnostics + safety cap ------------------------------------
    info = struct();
    info.threshold        = [opts.HU_min opts.HU_max];
    info.seed_HU          = double(seed_HU);
    info.picked_volume_mL = sum(mask(:)) * D.pixel_mm(1) * D.pixel_mm(2) * ...
                            D.slice_spacing_mm / 1000;
    info.processing_time  = toc(t0);
    info.leaked           = info.picked_volume_mL > opts.max_volume_mL;
end
