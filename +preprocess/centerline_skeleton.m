function [polyline_vox, R_vox, info] = centerline_skeleton(mask, seed_a, seed_b, opts)
%CENTERLINE_SKELETON  Centerline polyline through two seeds on a mask.
%
%   Given a 3D binary vessel mask and two voxel seeds, this function
%   computes the centerline polyline that passes through both seeds.
%   The pipeline:
%
%       1. bwskel(mask) → 1-voxel-thick medial axis
%       2. Build a 26-connected weighted graph over skeleton voxels.
%          Edge weights = Euclidean distance / R^2, where R is the
%          inscribed-sphere radius. The 1/R^2 weighting biases the
%          shortest-path solver toward fat-tube routes (aorta) over
%          thin-branch detours.
%       3. Map each user seed to its nearest skeleton voxel.
%       4. Dijkstra (shortestpath) to get the raw voxel polyline.
%       5. Catmull-Rom spline interpolation to get a smooth C¹ curve
%          that passes through every control point — the property
%          the Cosserat-rod forward model wants.
%       6. Inscribed-sphere radius along the smooth polyline from the
%          distance transform of the original mask.
%
%   Inputs
%       mask    : Ny×Nx×Nz logical vessel mask
%       seed_a  : 1×3 voxel coords [y x z], proximal end
%       seed_b  : 1×3 voxel coords [y x z], distal end
%       opts    : struct with
%                   .min_branch_length    bwskel pruning, voxels
%                                         default 30
%                   .radius_weight_pow    p in 1/R^p edge weighting
%                                         default 2 (VMTK-style)
%                   .smooth_per_segment   Catmull-Rom oversampling
%                                         default 5 (5 points per
%                                         skeleton segment)
%
%   Outputs
%       polyline_vox : N × 3 [y x z] voxel coords of the smooth
%                      centerline
%       R_vox        : N × 1 inscribed-sphere radius (voxels)
%       info         : struct with .skeleton_voxels, .seed_distances
%                                  (voxels from each user seed to its
%                                   mapped skeleton node — high values
%                                   mean the seed wasn't on the
%                                   skeleton, useful diagnostic),
%                                  .processing_time

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask     (:,:,:) logical
        seed_a   (1,3) double
        seed_b   (1,3) double
        opts     (1,1) struct = struct()
    end

    if ~isfield(opts, 'min_branch_length'); opts.min_branch_length = 30; end
    if ~isfield(opts, 'radius_weight_pow'); opts.radius_weight_pow = 2;  end
    if ~isfield(opts, 'smooth_per_segment');opts.smooth_per_segment = 5; end

    t0 = tic;

    % --- Distance transform & skeleton --------------------------------
    Dt   = bwdist(~mask);                     % Euclidean distance to boundary
    skel = bwskel(mask, 'MinBranchLength', opts.min_branch_length);

    % Coordinates of skeleton voxels
    [yy, xx, zz] = ind2sub(size(skel), find(skel));
    voxels = [yy, xx, zz];
    nvox   = size(voxels, 1);
    if nvox < 2
        error('centerline_skeleton:TinySkeleton', ...
            'Skeleton has fewer than 2 voxels — segmentation likely too small.');
    end

    % --- Build skeleton graph (vectorised over 26 neighbour offsets) -
    sz_vol  = size(skel);
    vox_idx = sub2ind(sz_vol, yy, xx, zz);
    pos_in_skel = zeros(prod(sz_vol), 1, 'uint32');
    pos_in_skel(vox_idx) = uint32(1:nvox);

    % R at each skeleton voxel for the edge weighting
    R_skel = arrayfun(@(k) Dt(yy(k), xx(k), zz(k)), 1:nvox).';

    % Generate 26-neighbour offsets
    offs = [];
    for dy = -1:1, for dx = -1:1, for dz = -1:1 %#ok<*ALIGN>
        if dy == 0 && dx == 0 && dz == 0; continue; end
        offs(end+1, :) = [dy dx dz]; %#ok<AGROW>
    end, end, end

    edge_i = []; edge_j = []; edge_w = [];
    for o = 1:size(offs, 1)
        dy = offs(o, 1); dx = offs(o, 2); dz = offs(o, 3);
        ny = yy + dy; nx = xx + dx; nz = zz + dz;
        valid = (ny >= 1 & ny <= sz_vol(1)) & ...
                (nx >= 1 & nx <= sz_vol(2)) & ...
                (nz >= 1 & nz <= sz_vol(3));
        if ~any(valid); continue; end
        nb_lin = sub2ind(sz_vol, ny(valid), nx(valid), nz(valid));
        nb_pos = pos_in_skel(nb_lin);
        is_e   = nb_pos > 0;
        if ~any(is_e); continue; end
        src = find(valid); src = src(is_e);
        dst = double(nb_pos(is_e));
        keep = src < dst;
        if ~any(keep); continue; end
        seg_len = sqrt(dy^2 + dx^2 + dz^2);
        % Mean inscribed-sphere radius across the edge
        Rs = 0.5 * (R_skel(src(keep)) + R_skel(dst(keep)));
        Rs = max(Rs, 0.5);
        w  = seg_len ./ Rs.^opts.radius_weight_pow;
        edge_i = [edge_i; src(keep)];   %#ok<AGROW>
        edge_j = [edge_j; dst(keep)];   %#ok<AGROW>
        edge_w = [edge_w; w];           %#ok<AGROW>
    end
    G = graph(edge_i, edge_j, edge_w, nvox);

    % --- Map each user seed to nearest skeleton voxel -----------------
    [node_a, da] = nearest_node(seed_a, voxels);
    [node_b, db] = nearest_node(seed_b, voxels);

    % --- Shortest path on the skeleton graph --------------------------
    path_nodes = shortestpath(G, node_a, node_b);
    if isempty(path_nodes)
        error('centerline_skeleton:NoPath', ...
            ['No path between the two seeds on the skeleton. The mask is likely ' ...
             'fragmented (one seed on aorta, the other on a disconnected piece). ' ...
             'Re-segment with a more permissive threshold or pick seeds in the ' ...
             'same connected component.']);
    end
    raw_polyline = voxels(path_nodes, :);

    % --- Pre-smooth the Dijkstra path -------------------------------
    % Skeleton voxels are 26-connected medial-axis points; the path
    % through them zig-zags by ~1 voxel per step in straight regions.
    % Gaussian moving-average removes that grid noise before the
    % Catmull-Rom spline so the spline doesn't faithfully reproduce
    % it. Window of 7 nodes ≈ ~5 mm of aortic axis at 0.7 mm voxels.
    if size(raw_polyline, 1) > 7
        raw_polyline = smoothdata(raw_polyline, 1, 'gaussian', 7);
    end

    % --- Truncate the polyline at the user's actual seeds -----------
    % nearest_node() can map a seed to a skeleton voxel that's far
    % from the click — on a leaky mask, the nearest skeleton voxel to
    % the proximal seed might be up the spine. Dijkstra then walks
    % past the seed all the way to that wrong skeleton node, so the
    % polyline has many nodes "beyond" where the user clicked.
    %
    % Find the polyline node closest to each seed and KEEP only the
    % portion between them. Then snap the endpoints exactly. This
    % fully truncates the runaway tail.
    if size(raw_polyline, 1) > 4
        [~, k_a] = min(vecnorm(raw_polyline - seed_a, 2, 2));
        [~, k_b] = min(vecnorm(raw_polyline - seed_b, 2, 2));
        if k_a < k_b
            raw_polyline = raw_polyline(k_a:k_b, :);
        else
            raw_polyline = flipud(raw_polyline(k_b:k_a, :));
        end
    end
    raw_polyline(1, :)   = seed_a;
    raw_polyline(end, :) = seed_b;

    % --- Catmull-Rom smoothing ----------------------------------------
    polyline_vox = catmull_rom(raw_polyline, opts.smooth_per_segment);

    % --- Hard clamp to volume bounds (cosmetic backstop) -----------
    polyline_vox(:, 1) = max(1, min(sz_vol(1), polyline_vox(:, 1)));
    polyline_vox(:, 2) = max(1, min(sz_vol(2), polyline_vox(:, 2)));
    polyline_vox(:, 3) = max(1, min(sz_vol(3), polyline_vox(:, 3)));

    % --- Anti-spike: drop polyline nodes that wandered outside the
    %     bounding box of the two seeds (with a generous 25% margin).
    %     The visible "tail" off the proximal end is caused by
    %     nearest_node mapping a seed to a far skeleton voxel, the
    %     Dijkstra walk extending past it, and the spline interpolating
    %     through that runaway. Truncating by bbox after the spline is
    %     a cosmetic backstop that always works.
    bb_lo = min(seed_a, seed_b);
    bb_hi = max(seed_a, seed_b);
    span  = max(bb_hi - bb_lo, 5);
    margin = 0.25 * span;
    in_bbox = polyline_vox(:,1) >= bb_lo(1) - margin(1) & ...
              polyline_vox(:,1) <= bb_hi(1) + margin(1) & ...
              polyline_vox(:,2) >= bb_lo(2) - margin(2) & ...
              polyline_vox(:,2) <= bb_hi(2) + margin(2) & ...
              polyline_vox(:,3) >= bb_lo(3) - margin(3) & ...
              polyline_vox(:,3) <= bb_hi(3) + margin(3);
    if any(in_bbox)
        polyline_vox = polyline_vox(in_bbox, :);
    end
    % Force exact seed endpoints
    if size(polyline_vox, 1) >= 2
        polyline_vox(1, :)   = seed_a;
        polyline_vox(end, :) = seed_b;
    end

    % --- Radius profile via the distance transform --------------------
    n = size(polyline_vox, 1);
    R_vox = zeros(n, 1);
    for k = 1:n
        y = max(1, min(sz_vol(1), round(polyline_vox(k, 1))));
        x = max(1, min(sz_vol(2), round(polyline_vox(k, 2))));
        z = max(1, min(sz_vol(3), round(polyline_vox(k, 3))));
        R_vox(k) = Dt(y, x, z);
    end

    info = struct();
    info.skeleton_voxels = nvox;
    info.seed_distances  = [da; db];
    info.processing_time = toc(t0);
end

% =========================================================================
function [idx, d] = nearest_node(seed, voxels)
    diffs = voxels - seed;
    dists = sqrt(sum(diffs.^2, 2));
    [d, idx] = min(dists);
end

function P = catmull_rom(P_ctrl, oversample)
% Catmull-Rom spline through every control point. Returns a polyline
% with `oversample` points between each pair of input points.
    n = size(P_ctrl, 1);
    if n < 4 || oversample <= 1
        P = P_ctrl;
        return;
    end
    % Pad endpoints by replication so the first and last segments
    % have valid Catmull-Rom tangents
    Pad = [P_ctrl(1,:); P_ctrl; P_ctrl(end,:)];
    P_out = [];
    t = linspace(0, 1, oversample + 1).';   t = t(1:end-1);
    for i = 2:size(Pad, 1) - 2
        P0 = Pad(i-1, :); P1 = Pad(i, :);
        P2 = Pad(i+1, :); P3 = Pad(i+2, :);
        % Catmull-Rom basis (uniform)
        seg = 0.5 * ( ...
            (2*P1) + ...
            (-P0 + P2) .* t + ...
            (2*P0 - 5*P1 + 4*P2 - P3) .* t.^2 + ...
            (-P0 + 3*P1 - 3*P2 + P3) .* t.^3 );
        P_out = [P_out; seg]; %#ok<AGROW>
    end
    P_out = [P_out; P_ctrl(end, :)];
    P = P_out;
end
