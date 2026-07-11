function S = build_skeleton_graph(mask, opts)
%BUILD_SKELETON_GRAPH  Skeletonise a vessel mask and return the full graph.
%
%   S = BUILD_SKELETON_GRAPH(MASK, OPTS) builds a graph over the
%   skeleton voxels of MASK and returns it. Unlike centerline_skel,
%   this function does NOT pick a single longest path — it gives the
%   caller everything needed to run their own shortest-path queries
%   between user-supplied seed voxels.
%
%   Returns a struct S with fields:
%       skel        : logical 3D, the skeleton (post radius-filter)
%       voxels      : N x 3 [y x z] voxel coordinates of skeleton points
%       graph       : MATLAB graph over the N voxels (Euclidean weights)
%       Dt          : 3D distance-from-mask-boundary array (used for
%                     filtering and for the radius profile downstream)
%       opts        : echo of the options actually used
%
%   The caller can then do:
%       s_a = preprocess.nearest_skeleton_voxel(seed_voxel_a, S);
%       s_b = preprocess.nearest_skeleton_voxel(seed_voxel_b, S);
%       path_nodes = shortestpath(S.graph, s_a, s_b);
%       polyline = S.voxels(path_nodes, :);

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask (:,:,:) logical
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'min_branch_length'); opts.min_branch_length = 30; end
    if ~isfield(opts, 'min_radius_vox');    opts.min_radius_vox    = 3;  end
    if ~isfield(opts, 'radius_weight_pow'); opts.radius_weight_pow = 0;  end

    % --- 3D thinning ------------------------------------------------
    skel = bwskel(mask, 'MinBranchLength', opts.min_branch_length);

    % --- Filter by inscribed-sphere radius --------------------------
    Dt = bwdist(~mask);
    if opts.min_radius_vox > 0
        skel = skel & (Dt >= opts.min_radius_vox);
    end

    % --- Coordinates and indices ------------------------------------
    [yy, xx, zz] = ind2sub(size(skel), find(skel));
    voxels = [yy, xx, zz];
    nvox = size(voxels, 1);
    if nvox < 2
        S = struct('skel', skel, 'voxels', voxels, 'graph', [], ...
                   'Dt', Dt, 'opts', opts);
        return;
    end

    sz = size(skel);
    vox_idx = sub2ind(sz, yy, xx, zz);
    pos_in_skel = zeros(prod(sz), 1, 'uint32');
    pos_in_skel(vox_idx) = uint32(1:nvox);

    edge_i = []; edge_j = []; edge_w = [];
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
        src = find(valid); src = src(is_edge);
        dst = double(nb_pos(is_edge));
        keep = src < dst;
        if ~any(keep); continue; end
        edge_i = [edge_i; src(keep)];                                %#ok<AGROW>
        edge_j = [edge_j; dst(keep)];                                %#ok<AGROW>
        edge_w = [edge_w; repmat(sqrt(dy^2 + dx^2 + dz^2), sum(keep), 1)]; %#ok<AGROW>
    end

    % Optional VMTK-style weighting: multiply each edge weight by
    % 1/R^p where R is the average inscribed-sphere radius at the
    % edge's two endpoints. With p > 0 the shortest-path solver
    % prefers fat-tube paths (aorta) over thin-tube paths (mesenteric
    % branches). p = 0 is unweighted (default; equal weighting is the
    % old behaviour). p ~ 1-2 is typical.
    if opts.radius_weight_pow > 0
        % Inscribed-sphere radius at each skeleton voxel
        R_vox_node = arrayfun(@(k) Dt(yy(k), xx(k), zz(k)), 1:nvox).';
        R_edge = 0.5 * (R_vox_node(edge_i) + R_vox_node(edge_j));
        R_edge = max(R_edge, 0.5);   % avoid div-by-zero
        edge_w = edge_w .* (1 ./ R_edge).^opts.radius_weight_pow;
    end

    G = graph(edge_i, edge_j, edge_w, nvox);

    S = struct('skel', skel, 'voxels', voxels, 'graph', G, ...
               'Dt', Dt, 'opts', opts);
end
