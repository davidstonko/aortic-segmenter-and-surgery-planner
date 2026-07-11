function seeds = auto_seeds_from_mask(mask, D)
%PREPROCESS.AUTO_SEEDS_FROM_MASK  Auto-detect the three EVAR endpoint
%   seeds (proximal aorta, R-CFA, L-CFA) from a clean aorta+iliac mask.
%
%   SEEDS = preprocess.auto_seeds_from_mask(MASK, D)
%
%   The mask is assumed to be a TotalSegmentator-style segmentation of
%   the aorta + bilateral iliac arteries. The volume D is in head-at-z=1
%   convention (D.z_normalized = true after doLoad).
%
%   Heuristics
%       PROXIMAL  = centroid of the topmost mask slice that has at
%                   least one connected component, narrowed to the
%                   largest in-plane CC so we follow the aortic lumen
%                   rather than a stray paraspinal vessel branch.
%       R-CFA     = bottom-most mask slice, take the LEFT-half (lower X
%                   in image coordinates = patient's right side because
%                   of how we render).
%       L-CFA     = bottom-most slice, RIGHT-half centroid.
%
%   Returns a struct with fields:
%       .proximal       1×3 voxel coords [y x z]
%       .right_cfa      1×3 voxel coords
%       .left_cfa       1×3 voxel coords
%       .ok             logical — false if any seed could not be detected

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask  logical
        D     (1,1) struct
    end

    seeds = struct( ...
        'proximal',  [], ...
        'right_cfa', [], ...
        'left_cfa',  [], ...
        'ok',        false);

    if ~any(mask(:)); return; end

    sz = size(mask);
    % Z direction: head at z=1 (after doLoad flip), feet at z=N
    z_present = squeeze(any(any(mask, 1), 2));
    z_top = find(z_present, 1, 'first');   % most superior
    z_bot = find(z_present, 1, 'last');    % most inferior
    if isempty(z_top) || z_bot - z_top < 5; return; end

    % --- Proximal seed: largest CC on the most-superior slice -----
    slice_top = mask(:, :, z_top);
    cc = bwconncomp(slice_top, 8);
    if cc.NumObjects == 0; return; end
    sizes = cellfun(@numel, cc.PixelIdxList);
    [~, idx] = max(sizes);
    [yy, xx] = ind2sub(size(slice_top), cc.PixelIdxList{idx});
    seeds.proximal = [round(median(yy)), round(median(xx)), z_top];

    % --- CFA seeds: walk UP from the most-caudal slice until we find
    %     a slice that contains TWO connected components (the two
    %     iliacs/CFAs separated by the bifurcation). The most-caudal
    %     slice often contains only one CFA (asymmetric segmentation
    %     of left vs right), and a local median-split there produces
    %     two seeds inside the same blob — the original bug.
    %     We split by the GLOBAL volume midline col = sz(2)/2, so a
    %     single-CC slice can't yield two near-identical seeds.
    x_mid = sz(2) / 2;
    z_pair = [];   % Z slice where we successfully split iliacs
    pat_right_centroid = [];
    pat_left_centroid  = [];
    for z_try = z_bot:-1:max(z_top + 1, z_bot - 200)
        slZ = mask(:, :, z_try);
        if ~any(slZ(:)); continue; end
        cc = bwconncomp(slZ, 8);
        % Identify CCs by which side of the volume midline their
        % centroid lies on (patient-right = low col; patient-left = high col)
        right_idx = [];
        left_idx  = [];
        for ci = 1:cc.NumObjects
            [yi, xi] = ind2sub(size(slZ), cc.PixelIdxList{ci});
            cx = mean(xi);
            if cx < x_mid
                right_idx(end+1) = ci; %#ok<AGROW>
            else
                left_idx(end+1) = ci;  %#ok<AGROW>
            end
        end
        if isempty(right_idx) || isempty(left_idx); continue; end
        % Take the LARGEST CC on each side (the iliac, not a stray)
        [~, rk] = max(cellfun(@numel, cc.PixelIdxList(right_idx)));
        [~, lk] = max(cellfun(@numel, cc.PixelIdxList(left_idx)));
        rpx = cc.PixelIdxList{right_idx(rk)};
        lpx = cc.PixelIdxList{left_idx(lk)};
        [yr, xr] = ind2sub(size(slZ), rpx);
        [yl, xl] = ind2sub(size(slZ), lpx);
        pat_right_centroid = [round(median(yr)), round(median(xr))];
        pat_left_centroid  = [round(median(yl)), round(median(xl))];
        z_pair = z_try;
        break;
    end
    if isempty(z_pair)
        % Fallback: original logic using z_bot's local median (better
        % than nothing if there really is only one iliac).
        slice_bot = mask(:, :, z_bot);
        [yyb, xxb] = ind2sub(size(slice_bot), find(slice_bot));
        if numel(xxb) < 2; return; end
        x_med = median(xxb);
        is_pat_right = xxb < x_med;
        is_pat_left  = xxb > x_med;
        if any(is_pat_right)
            seeds.right_cfa = [round(median(yyb(is_pat_right))), ...
                               round(median(xxb(is_pat_right))), z_bot];
        end
        if any(is_pat_left)
            seeds.left_cfa = [round(median(yyb(is_pat_left))), ...
                              round(median(xxb(is_pat_left))), z_bot];
        end
    else
        seeds.right_cfa = [pat_right_centroid(1), pat_right_centroid(2), z_pair];
        seeds.left_cfa  = [pat_left_centroid(1),  pat_left_centroid(2),  z_pair];
    end

    seeds.ok = ~isempty(seeds.proximal) && ...
               ~isempty(seeds.right_cfa) && ~isempty(seeds.left_cfa);

    % suppress unused-D warning by referencing D.is_volume
    if isfield(D, 'is_volume'); seeds.is_volume = D.is_volume; end
end
