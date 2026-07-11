function bw = drop_big_inplane_cc(bw, max_vox)
%AUTOSEG.DROP_BIG_INPLANE_CC  Vessel-size leak guard for region-growing.
%
%   BW = autoseg.drop_big_inplane_cc(BW, MAX_VOX)
%
%   Zeroes out any 8-connected in-plane connected component, on every
%   axial slice of the logical volume BW, whose voxel count exceeds
%   MAX_VOX. Used to keep a contrast-driven region grow from leaking
%   into non-vessel structures that share the arterial-bolus HU window:
%   cancellous BONE MARROW (iliac wings, sacrum, femoral heads ~200-400
%   HU), an opacified BLADDER, contrast-filled BOWEL, and large VEIN
%   pools. All of these present far larger axial cross-sections than an
%   iliac / CFA lumen, so an area ceiling removes them as grow
%   CANDIDATES.
%
%   This adds no synthetic voxels — it only restricts which real voxels
%   a downstream `imreconstruct` can reach. Every voxel that survives
%   still carries its original CT intensity, so the no-bridges invariant
%   (never paint anatomy that isn't there) is preserved.
%
%   INPUT
%       BW       logical Y×X×Z volume of candidate (in-window) voxels.
%       MAX_VOX  scalar voxel-count ceiling per in-plane component.
%                Convert from a physical area with
%                   max_vox = round(area_mm2 / pixel_mm^2).
%
%   OUTPUT
%       BW       same size, with over-size in-plane components removed.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        bw      logical
        max_vox (1,1) double {mustBePositive}
    end

    sz = size(bw);
    nz = sz(3);
    for z = 1:nz
        sl = bw(:, :, z);
        if ~any(sl(:)); continue; end
        cc = bwconncomp(sl, 8);
        np = cellfun(@numel, cc.PixelIdxList);
        big = find(np > max_vox);
        if isempty(big); continue; end
        for i = 1:numel(big)
            sl(cc.PixelIdxList{big(i)}) = false;
        end
        bw(:, :, z) = sl;
    end
end
