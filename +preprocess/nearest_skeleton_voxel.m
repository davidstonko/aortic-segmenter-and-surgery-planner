function [idx, dist] = nearest_skeleton_voxel(seed_yxz, S)
%NEAREST_SKELETON_VOXEL  Find the closest skeleton voxel to a seed.
%
%   [IDX, DIST] = NEAREST_SKELETON_VOXEL(SEED_YXZ, S) returns the index
%   into S.voxels of the skeleton voxel closest (Euclidean in voxel
%   units) to SEED_YXZ, plus the Euclidean distance.
%
%   SEED_YXZ is a 1x3 row vector of voxel coordinates [y x z]. S is
%   the struct returned by preprocess.build_skeleton_graph.
%
%   Use this to map user-clicked seeds (which won't sit exactly on
%   skeleton voxels) onto the closest valid graph node.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        seed_yxz (1,3) double
        S        (1,1) struct
    end

    diffs = S.voxels - seed_yxz;
    d = sqrt(sum(diffs.^2, 2));
    [dist, idx] = min(d);
end
