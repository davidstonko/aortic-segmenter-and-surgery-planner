function mask = sweep_tube(sz, pix_mm, ssp_mm, centerline_mm, radius_mm, mask)
%PHANTOM.SWEEP_TUBE  Rasterize a tube (variable-radius sphere sweep)
%   along a centerline polyline into a 3-D logical mask.
%
%   MASK = phantom.sweep_tube(SZ, PIX_MM, SSP_MM, CENTERLINE_MM, ...
%                             RADIUS_MM)
%   MASK = phantom.sweep_tube(..., MASK)   accumulate into existing mask
%
%   Inputs
%       SZ            [Y X Z] size of the output volume in voxels
%       PIX_MM        [dy dx] pixel spacing in mm
%       SSP_MM        slice spacing in mm
%       CENTERLINE_MM N×3 polyline [y x z] in MILLIMETERS (anatomic
%                     coords, not voxels — we convert internally)
%       RADIUS_MM     N×1 radius in mm at each centerline node
%       MASK          (optional) existing logical mask of size SZ to OR
%                     this tube into. Lets you build complex anatomies
%                     by accumulating segments.
%
%   Output
%       MASK          SZ logical, with voxels inside the swept tube set
%                     to true.
%
%   Algorithm
%       For each centerline segment, we step along it in arc-length
%       increments smaller than the smaller of the radius and the
%       voxel diagonal. At each step, we mark every voxel inside a
%       sphere of radius r(s) at the current point. To keep the cost
%       sane on a 256³ grid, the sphere stamping operates only on the
%       bounding box around the sphere center.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        sz             (1,3) double
        pix_mm         (1,2) double
        ssp_mm         (1,1) double
        centerline_mm  (:,3) double
        radius_mm      (:,1) double
        mask           logical = false(sz)
    end

    if isempty(mask) || ~isequal(size(mask), sz)
        mask = false(sz);
    end
    if size(centerline_mm, 1) < 2; return; end

    nN = size(centerline_mm, 1);
    if numel(radius_mm) == 1
        radius_mm = repmat(radius_mm, nN, 1);
    end
    assert(numel(radius_mm) == nN, ...
        'phantom:sweep_tube:RadiusSize', 'radius_mm must match centerline length');

    voxel_diag_mm = sqrt(pix_mm(1)^2 + pix_mm(2)^2 + ssp_mm^2);

    % Iterate over segments, sub-sampling each to fine enough resolution
    for k = 1:nN-1
        p0 = centerline_mm(k, :);   r0 = radius_mm(k);
        p1 = centerline_mm(k+1, :); r1 = radius_mm(k+1);
        seg_len = norm(p1 - p0);
        if seg_len == 0; continue; end
        % Step at ~1/3 the smaller radius (fine enough to not miss voxels)
        step_mm = min([r0 r1 voxel_diag_mm]) / 3;
        n_steps = max(2, ceil(seg_len / step_mm));
        ts = linspace(0, 1, n_steps);
        for t = ts
            p = p0 * (1 - t) + p1 * t;
            r = r0 * (1 - t) + r1 * t;
            mask = stamp_sphere(mask, sz, pix_mm, ssp_mm, p, r);
        end
    end
end

% =========================================================================
function mask = stamp_sphere(mask, sz, pix_mm, ssp_mm, center_mm, r_mm)
%STAMP_SPHERE  Set all voxels within r_mm of center_mm to true. Operates
%   only on the bounding box around the sphere to avoid scanning the
%   whole volume.
    cy_mm = center_mm(1); cx_mm = center_mm(2); cz_mm = center_mm(3);

    % Voxel ranges (1-based) covered by the sphere bounding box
    iy_lo = max(1, floor((cy_mm - r_mm) / pix_mm(1)) + 1);
    iy_hi = min(sz(1), ceil((cy_mm + r_mm) / pix_mm(1)) + 1);
    ix_lo = max(1, floor((cx_mm - r_mm) / pix_mm(2)) + 1);
    ix_hi = min(sz(2), ceil((cx_mm + r_mm) / pix_mm(2)) + 1);
    iz_lo = max(1, floor((cz_mm - r_mm) / ssp_mm) + 1);
    iz_hi = min(sz(3), ceil((cz_mm + r_mm) / ssp_mm) + 1);
    if iy_lo > iy_hi || ix_lo > ix_hi || iz_lo > iz_hi; return; end

    [Yg, Xg, Zg] = ndgrid( ...
        ((iy_lo:iy_hi) - 1) * pix_mm(1), ...
        ((ix_lo:ix_hi) - 1) * pix_mm(2), ...
        ((iz_lo:iz_hi) - 1) * ssp_mm);
    inside = (Yg - cy_mm).^2 + (Xg - cx_mm).^2 + (Zg - cz_mm).^2 <= r_mm^2;
    sub = mask(iy_lo:iy_hi, ix_lo:ix_hi, iz_lo:iz_hi);
    sub = sub | inside;
    mask(iy_lo:iy_hi, ix_lo:ix_hi, iz_lo:iz_hi) = sub;
end
