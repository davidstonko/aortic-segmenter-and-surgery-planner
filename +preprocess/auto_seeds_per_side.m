function seeds = auto_seeds_per_side(mask, D, label_vol)
%PREPROCESS.AUTO_SEEDS_PER_SIDE  Asymmetric CFA seed picker. Each side's
%   distal seed is the most-caudal voxel of THAT SIDE's mask, computed
%   independently. Use this when the iliac/CFA opacification is
%   asymmetric (e.g. delayed contrast on one side) so the seeds reflect
%   the true reach of each branch — not the slice where both happen to
%   be visible.
%
%   SEEDS = preprocess.auto_seeds_per_side(MASK, D)
%   SEEDS = preprocess.auto_seeds_per_side(MASK, D, LABEL_VOL)
%
%   If LABEL_VOL is provided, the proximal seed is anchored via the
%   kidney-top heuristic in `preprocess.auto_seeds_anatomic`. Otherwise
%   the proximal seed defaults to the centroid of the most-cranial
%   mask CC (matching the existing binary-mask path).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask      logical
        D         (1,1) struct
        label_vol = []
    end

    seeds = struct('proximal', [], 'right_cfa', [], 'left_cfa', [], ...
                   'ok', false, 'diagnostic', struct());

    if ~any(mask(:)); return; end
    sz = size(mask);

    % --- Proximal: prefer the anatomic detector when a label volume
    %     is provided; fall back to "topmost mask slice"
    if ~isempty(label_vol)
        a = preprocess.auto_seeds_anatomic(label_vol, D);
        seeds.proximal = a.proximal;
    else
        z_pres = squeeze(any(any(mask, 1), 2));
        z_top = find(z_pres, 1, 'first');
        slc = mask(:, :, z_top);
        cc = bwconncomp(slc, 8);
        sizes = cellfun(@numel, cc.PixelIdxList);
        [~, idx] = max(sizes);
        [yy, xx] = ind2sub([sz(1), sz(2)], cc.PixelIdxList{idx});
        seeds.proximal = [round(median(yy)), round(median(xx)), z_top];
    end

    % --- Distal: per-side, bottom of each side's mask
    x_mid = sz(2) / 2;
    side_R = false(sz); side_R(:, 1:floor(x_mid), :) = true;     % patient-right = low x
    side_L = false(sz); side_L(:, ceil(x_mid)+1:end, :) = true;  % patient-left = high x

    seeds.right_cfa = caudal_centroid(mask & side_R);
    seeds.left_cfa  = caudal_centroid(mask & side_L);

    seeds.diagnostic.right_z_extent = z_range(mask & side_R);
    seeds.diagnostic.left_z_extent  = z_range(mask & side_L);

    seeds.ok = ~isempty(seeds.proximal) && ...
               ~isempty(seeds.right_cfa) && ~isempty(seeds.left_cfa);
end

function p = caudal_centroid(M)
%CAUDAL_CENTROID  Centroid of the largest CC on the most-caudal slice.
    p = [];
    if ~any(M(:)); return; end
    sz = size(M);
    z_pres = squeeze(any(any(M, 1), 2));
    z_bot = find(z_pres, 1, 'last');
    slc = M(:, :, z_bot);
    cc = bwconncomp(slc, 8);
    if cc.NumObjects == 0; return; end
    sizes = cellfun(@numel, cc.PixelIdxList);
    [~, idx] = max(sizes);
    [yy, xx] = ind2sub([sz(1), sz(2)], cc.PixelIdxList{idx});
    p = [round(median(yy)), round(median(xx)), z_bot];
end

function r = z_range(M)
    z_pres = squeeze(any(any(M, 1), 2));
    if ~any(z_pres); r = [NaN NaN]; return; end
    r = [find(z_pres, 1, 'first'), find(z_pres, 1, 'last')];
end
