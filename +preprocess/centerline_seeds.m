function [polyline_vox, R_vox, info] = centerline_seeds(S, seeds, opts)
%CENTERLINE_SEEDS  Centerline polyline through user-supplied seeds.
%
%   [POLYLINE_VOX, R_VOX, INFO] = CENTERLINE_SEEDS(S, SEEDS) walks the
%   shortest path through the skeleton graph S from seed to seed in
%   order. SEEDS is a K x 3 matrix of voxel coordinates [y x z]; the
%   returned polyline visits each seed in order, threading along the
%   skeleton between them.
%
%   This is "Path B" of the Phase 3 plan: instead of relying on
%   automatic longest-path heuristics, the user picks explicit
%   landmarks (e.g. proximal aorta, iliac bifurcation, iliac terminus)
%   and the function returns the centerline that passes through them.
%
%   Inputs
%       S        : skeleton-graph struct from preprocess.build_skeleton_graph
%       seeds    : K x 3 voxel coordinates [y x z], in path order
%       opts     : struct with
%                    .smooth_window   Savitzky-Golay window (default 25)
%
%   Outputs
%       polyline_vox : N x 3 voxel coordinates along the centerline
%       R_vox        : N x 1 inscribed-sphere radius (voxels) per node
%       info         : struct with .seed_distances (distance from each
%                                  user seed to its mapped skeleton vox)
%                                  .segment_lengths (mm units would
%                                  require pixel size; here voxel)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        S     (1,1) struct
        seeds       double
        opts  (1,1) struct = struct()
    end
    assert(size(seeds, 2) == 3, 'seeds must be K x 3 [y x z]');
    if ~isfield(opts, 'smooth_window'); opts.smooth_window = 25; end

    K = size(seeds, 1);
    seed_idx = zeros(K, 1);
    seed_dist = zeros(K, 1);
    for k = 1:K
        [seed_idx(k), seed_dist(k)] = preprocess.nearest_skeleton_voxel(seeds(k, :), S);
    end

    % Walk shortest paths between consecutive seeds, then concatenate
    polyline_vox = [];
    seg_lengths = zeros(K - 1, 1);
    for k = 1:K-1
        path_nodes = shortestpath(S.graph, seed_idx(k), seed_idx(k+1));
        if isempty(path_nodes)
            error('centerline_seeds:NoPath', ...
                'No path on skeleton graph between seed %d and seed %d. The two seeds may be in different connected components.', ...
                k, k+1);
        end
        seg_pts = S.voxels(path_nodes, :);
        if k > 1
            seg_pts = seg_pts(2:end, :);   % avoid duplicating shared seed
        end
        polyline_vox = [polyline_vox; seg_pts]; %#ok<AGROW>
        seg_lengths(k) = sum(vecnorm(diff(S.voxels(path_nodes, :), 1, 1), 2, 2));
    end

    % Smooth via Savitzky-Golay (only if long enough)
    if opts.smooth_window > 0 && size(polyline_vox, 1) > opts.smooth_window
        polyline_vox = sgolayfilt(polyline_vox, 3, opts.smooth_window);
    end

    % Inscribed-sphere radius at each node from the distance transform
    n = size(polyline_vox, 1);
    R_vox = zeros(n, 1);
    sz = size(S.skel);
    for k = 1:n
        y = max(1, min(sz(1), round(polyline_vox(k, 1))));
        x = max(1, min(sz(2), round(polyline_vox(k, 2))));
        z = max(1, min(sz(3), round(polyline_vox(k, 3))));
        R_vox(k) = S.Dt(y, x, z);
    end

    info.seed_distances = seed_dist;
    info.segment_lengths_vox = seg_lengths;
end
