function [Pv_mm, R_mm] = centerline_to_mm(polyline_voxels, R_voxels, D)
%CENTERLINE_TO_MM  Convert a voxel-coord centerline to patient mm.
%
%   [PV_MM, R_MM] = CENTERLINE_TO_MM(POLYLINE_VOXELS, R_VOXELS, D)
%   converts an N×3 polyline given in (y, x, z) voxel coordinates and
%   an N×1 radius given in voxel units to the patient coordinate
%   system in mm, using the spacing fields in D.
%
%   The conversion assumes the conventional DICOM axes:
%       voxel (y, x, z) → patient ([x_mm = x*pixel_mm(2),
%                                   y_mm = y*pixel_mm(1),
%                                   z_mm = z_slice_z_mm(z)])
%
%   For radius, we use the geometric mean of the in-plane spacings to
%   give an isotropic radius scalar (the inscribed sphere is anisotropic
%   under non-cubic voxels; for our 0.77 × 0.77 × 0.5 mm voxels this is
%   a small adjustment).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        polyline_voxels (:,3) double
        R_voxels        (:,1) double
        D               (1,1) struct
    end

    assert(D.is_volume, 'centerline_to_mm:NotVolume', 'D must be a CT volume.');

    Pv_mm = zeros(size(polyline_voxels));
    Pv_mm(:, 1) = polyline_voxels(:, 2) * D.pixel_mm(2);                 % x
    Pv_mm(:, 2) = polyline_voxels(:, 1) * D.pixel_mm(1);                 % y
    % z: prefer the per-slice mm table from the DICOM loader (handles
    % non-uniform slice locations); fall back to slice_spacing_mm × (z-1)
    % for phantoms / synthetic volumes that don't carry the table.
    z_idx = polyline_voxels(:, 3);
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        z_idx_clamped = min(max(z_idx, 1), numel(D.slice_z_mm));
        Pv_mm(:, 3) = interp1(1:numel(D.slice_z_mm), D.slice_z_mm, ...
                              z_idx_clamped, 'linear');
    else
        Pv_mm(:, 3) = (z_idx - 1) * D.slice_spacing_mm;
    end

    % Geometric-mean voxel size as an isotropic radius scaling
    voxel_geom_mean = (D.pixel_mm(1) * D.pixel_mm(2) * D.slice_spacing_mm)^(1/3);
    R_mm = R_voxels * voxel_geom_mean;
end
