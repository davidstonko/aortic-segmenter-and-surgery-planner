function [skel, polyline, R_lumen] = centerline_skel(mask, opts)
%CENTERLINE_SKEL  Skeletonise a vessel mask and fit a smooth polyline.
%
%   [SKEL, POLYLINE, R_LUMEN] = CENTERLINE_SKEL(MASK) computes the 3D
%   medial-axis skeleton of MASK using `bwskel`, walks the longest
%   simple path through the skeleton (handling bifurcations by
%   choosing the longest branch), and returns:
%
%       SKEL     : logical Ny×Nx×Nz, the raw skeleton voxels
%       POLYLINE : N×3 ordered (y,x,z) voxel coordinates along the path
%       R_LUMEN  : N×1 inscribed-sphere radius (in voxels) at each
%                  polyline point, computed from the Euclidean
%                  distance transform of MASK
%
%   This function returns voxel coordinates; convert to mm by
%   multiplying y, x by D.pixel_mm and z by D.slice_spacing_mm
%   downstream (see preprocess.centerline_polyline_mm).
%
%   Inputs
%       mask : logical 3D vessel mask
%       opts : struct with
%                  .min_branch_length    bwskel pruning length, voxels
%                                        (default 30)
%                  .smooth_window        Savitzky-Golay window size on
%                                        the polyline, in points
%                                        (default 25; 0 disables)
%
%   The current implementation walks the longest simple path through
%   the skeleton graph. For vessels with a Y-bifurcation (aorta + two
%   common iliacs) this returns a single branch; the caller can re-run
%   on a masked-out copy of the skeleton to get the second branch, or
%   walk the graph manually for proper bifurcation handling. We will
%   add a multi-branch walker once we have one working single branch.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask (:,:,:) logical
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'min_branch_length'); opts.min_branch_length = 30; end
    if ~isfield(opts, 'smooth_window');     opts.smooth_window     = 25; end

    % --- Step 1: 3D thinning ------------------------------------------
    skel = bwskel(mask, 'MinBranchLength', opts.min_branch_length);

    % --- Step 1b: filter skeleton by inscribed-sphere radius ---------
    % Compute distance from boundary at every interior voxel; keep only
    % skeleton voxels where the distance is at least min_radius_vox
    % (default 4 voxels ≈ 3 mm at 0.77 mm pixel). This removes
    % skeleton voxels in thin vessels (renals, mesenterics, bowel
    % branches) and keeps only the aorta + iliac main tree.
    if ~isfield(opts, 'min_radius_vox'); opts.min_radius_vox = 4; end
    if opts.min_radius_vox > 0
        Dt_pre = bwdist(~mask);
        skel = skel & (Dt_pre >= opts.min_radius_vox);
        fprintf('  Skeleton filtered to R >= %d voxels: %d voxels remain\n', ...
            opts.min_radius_vox, sum(skel(:)));
    end

    % --- Step 2: find endpoints (skeleton voxels with exactly 1 26-neighbour)
    [yy, xx, zz] = ind2sub(size(skel), find(skel));
    voxels = [yy, xx, zz];
    nvox = size(voxels, 1);

    if nvox < 2
        polyline = voxels;
        R_lumen  = zeros(size(voxels, 1), 1);
        return;
    end

    % Compute neighbour counts per voxel via 3x3x3 box convolution
    neighbour_count = imfilter(double(skel), ones(3,3,3)) - double(skel);
    nc_at_voxels = arrayfun(@(i) neighbour_count(yy(i), xx(i), zz(i)), 1:nvox).';
    endpoints = find(nc_at_voxels == 1);

    % --- Step 3: build skeleton graph (vectorised) -------------------
    % For each of the 26 neighbour offsets, shift the linear-index
    % grid and intersect with the skeleton voxel set. Avoids the
    % per-voxel loop that was O(N*26*sub2ind+find).
    fprintf('  Building skeleton graph (%d voxels)...\n', nvox);
    sz = size(skel);
    vox_idx = sub2ind(sz, yy, xx, zz);
    % Map: for each linear index in the volume, give its position in
    % the skeleton voxel list. 0 means not on the skeleton.
    pos_in_skel = zeros(prod(sz), 1, 'uint32');
    pos_in_skel(vox_idx) = uint32(1:nvox);

    edge_i_all = []; edge_j_all = []; edge_w_all = [];
    offsets = [];
    for dy = -1:1, for dx = -1:1, for dz = -1:1 %#ok<*ALIGN>
        if dy == 0 && dx == 0 && dz == 0; continue; end
        offsets(end+1, :) = [dy dx dz]; %#ok<AGROW>
    end, end, end

    for o = 1:size(offsets, 1)
        dy = offsets(o, 1); dx = offsets(o, 2); dz = offsets(o, 3);
        ny = yy + dy; nx = xx + dx; nz = zz + dz;
        valid = (ny >= 1 & ny <= sz(1)) & ...
                (nx >= 1 & nx <= sz(2)) & ...
                (nz >= 1 & nz <= sz(3));
        if ~any(valid); continue; end
        nb_lin = sub2ind(sz, ny(valid), nx(valid), nz(valid));
        nb_pos = pos_in_skel(nb_lin);
        is_edge = nb_pos > 0;
        if ~any(is_edge); continue; end

        src = find(valid);
        src = src(is_edge);
        dst = double(nb_pos(is_edge));
        % Keep each edge once (undirected): only store src < dst
        keep = src < dst;
        if ~any(keep); continue; end
        edge_i_all = [edge_i_all; src(keep)];               %#ok<AGROW>
        edge_j_all = [edge_j_all; dst(keep)];               %#ok<AGROW>
        edge_w_all = [edge_w_all; ...
            repmat(sqrt(dy^2 + dx^2 + dz^2), sum(keep), 1)]; %#ok<AGROW>
    end
    G = graph(edge_i_all, edge_j_all, edge_w_all, nvox);
    fprintf('  Graph built: %d edges\n', numedges(G));

    % Restrict to the largest connected component — the aorta + iliacs
    % skeleton typically sits in one big component, with smaller
    % islands from spurious mask fragments.
    cc_id = conncomp(G);
    biggest_cc = mode(cc_id);
    in_big = (cc_id == biggest_cc);
    big_nodes = find(in_big);
    fprintf('  Largest component: %d / %d voxels\n', numel(big_nodes), nvox);

    % Endpoints within the largest component
    ep_in_big = endpoints(in_big(endpoints));
    if numel(ep_in_big) >= 2
        % Two-pass farthest-point: from any endpoint, find farthest;
        % from there, find the next farthest.
        d1 = distances(G, ep_in_big(1), ep_in_big);
        d1(isinf(d1)) = -1;
        [~, far1] = max(d1);
        seed_a = ep_in_big(far1);
        d2 = distances(G, seed_a, ep_in_big);
        d2(isinf(d2)) = -1;
        [~, far2] = max(d2);
        seed_b = ep_in_big(far2);
    else
        % Fallback: pick the two voxels in the big component with
        % extreme z-positions.
        zz_big = zz(big_nodes);
        [~, lo] = min(zz_big); [~, hi] = max(zz_big);
        seed_a = big_nodes(lo);
        seed_b = big_nodes(hi);
    end

    path_nodes = shortestpath(G, seed_a, seed_b);
    if isempty(path_nodes)
        warning('centerline_skel:NoPath', ...
            'shortestpath returned empty; falling back to BFS endpoints.');
        polyline = voxels(big_nodes, :);
    else
        polyline = voxels(path_nodes, :);
    end

    % --- Step 4: optional Savitzky-Golay smoothing along arc length ---
    if opts.smooth_window > 0 && size(polyline, 1) > opts.smooth_window
        sw = opts.smooth_window;
        polyline = sgolayfilt(polyline, 3, sw);
    end

    % --- Step 5: inscribed-sphere radius at each polyline point -----
    % Distance transform of the COMPLEMENT of the mask gives, at each
    % interior voxel, the distance to the nearest mask boundary —
    % i.e. the inscribed sphere radius.
    Dt = bwdist(~mask);
    n = size(polyline, 1);
    R_lumen = zeros(n, 1);
    for k = 1:n
        y = round(polyline(k, 1)); x = round(polyline(k, 2)); z = round(polyline(k, 3));
        y = min(max(y, 1), size(mask,1));
        x = min(max(x, 1), size(mask,2));
        z = min(max(z, 1), size(mask,3));
        R_lumen(k) = Dt(y, x, z);
    end
end
