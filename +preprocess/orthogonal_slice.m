function [slice_img, info] = orthogonal_slice(vol, polyline_vox, node_idx, opts)
%PREPROCESS.ORTHOGONAL_SLICE  Cross-section through the volume at one
%   centerline node, orthogonal to the local tangent. The lumen
%   appears as a roughly circular bright spot at the centre of the
%   image — same view TeraRecon shows when the user scrubs through a
%   straightened CPR.
%
%   [SLICE_IMG, INFO] = preprocess.orthogonal_slice(VOL, POLYLINE_VOX, NODE_IDX)
%   [SLICE_IMG, INFO] = preprocess.orthogonal_slice(..., OPTS)
%
%   Inputs
%       VOL           Y × X × Z CT volume.
%       POLYLINE_VOX  N × 3 centerline in voxel coordinates [y x z].
%       NODE_IDX      index 1..N of the centerline node to slice at.
%       OPTS          struct with optional fields:
%           .half_width_mm    half-extent of the slice in mm
%                             default 35 (=> 70 mm × 70 mm field)
%           .step_mm          sampling resolution (mm)
%                             default 0.4
%           .pixel_mm         in-plane spacing of VOL [dy dx]
%                             default [1 1]
%           .slice_spacing_mm z spacing of VOL
%                             default 1
%           .frame_up         (1×3) tells the function which world
%                             direction should be "up" in the image.
%                             Default [0 0 1] (patient superior).
%
%   Output
%       SLICE_IMG     M × M single — sampled HU.
%       INFO struct
%           .ext_mm   half-extent (so axes go from -ext_mm to +ext_mm)
%           .tangent  1 × 3 tangent direction at the node
%           .right_dir 1 × 3 in-plane "right" axis (image X)
%           .up_dir    1 × 3 in-plane "up"    axis (image Y)
%           .center_mm 1 × 3 mm coordinates of the node
%           .estimated_diameter_mm  rough 2× distance from center to
%                             the first low-HU voxel along 8 rays.
%                             NaN if no clear lumen edge.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        vol           {mustBeNumeric}
        polyline_vox  (:,3) double
        node_idx      (1,1) double {mustBeInteger, mustBePositive}
        opts          (1,1) struct = struct()
    end

    if ~isfield(opts, 'half_width_mm');    opts.half_width_mm    = 35; end
    if ~isfield(opts, 'step_mm');          opts.step_mm          = 0.4; end
    if ~isfield(opts, 'pixel_mm');         opts.pixel_mm         = [1 1]; end
    if ~isfield(opts, 'slice_spacing_mm'); opts.slice_spacing_mm = 1;   end
    if ~isfield(opts, 'frame_up');         opts.frame_up         = [0 0 1]; end

    n = size(polyline_vox, 1);
    node_idx = max(1, min(n, node_idx));

    % Centerline in mm
    P_mm = [polyline_vox(:,1) * opts.pixel_mm(1), ...
            polyline_vox(:,2) * opts.pixel_mm(2), ...
            polyline_vox(:,3) * opts.slice_spacing_mm];
    center_mm = P_mm(node_idx, :);

    % Tangent — central difference; clamp at endpoints.
    if n < 2
        tangent = [0 0 1];
    else
        i_lo = max(1, node_idx - 2);
        i_hi = min(n, node_idx + 2);
        tangent = P_mm(i_hi, :) - P_mm(i_lo, :);
    end
    tangent = tangent / max(norm(tangent), eps);

    % Build a stable in-plane frame (right, up) perpendicular to tangent
    up_request = opts.frame_up(:)' / max(norm(opts.frame_up), eps);
    right_dir = cross(tangent, up_request);
    if norm(right_dir) < 1e-3
        % Tangent is parallel to up_request — pick a different frame
        up_request = [1 0 0];
        right_dir  = cross(tangent, up_request);
    end
    right_dir = right_dir / max(norm(right_dir), eps);
    up_dir    = cross(right_dir, tangent);
    up_dir    = up_dir / max(norm(up_dir), eps);

    % Sample grid in mm
    h = opts.half_width_mm;
    s = opts.step_mm;
    g = (-h:s:h);
    [GX, GY] = meshgrid(g, g);   % image col=X (right), row=Y (up)

    % World-mm sample positions
    sample_mm = center_mm + ...
        GX(:) * right_dir + ...
        GY(:) * up_dir;

    % mm → voxel index
    Yv = sample_mm(:, 1) / opts.pixel_mm(1) + 1;
    Xv = sample_mm(:, 2) / opts.pixel_mm(2) + 1;
    Zv = sample_mm(:, 3) / opts.slice_spacing_mm + 1;

    slice_img = single(interp3(single(vol), ...
        reshape(Xv, size(GX)), reshape(Yv, size(GX)), reshape(Zv, size(GX)), ...
        'linear', single(-1000)));

    info = struct();
    info.ext_mm     = h;
    info.tangent    = tangent;
    info.right_dir  = right_dir;
    info.up_dir     = up_dir;
    info.center_mm  = center_mm;
    info.estimated_diameter_mm = estimate_diameter(slice_img, s);
end

% =========================================================================
function d = estimate_diameter(img, step_mm)
%ESTIMATE_DIAMETER  Rough lumen diameter from the orthogonal slice.
%   Walks 8 rays out from the centre and picks the first voxel below a
%   contrast threshold. Returns the median over the 8 rays × 2 = average
%   diameter in mm. NaN if no clear edge (CT artefact, off-vessel).
    sz = size(img);
    cy = (sz(1) + 1) / 2;  cx = (sz(2) + 1) / 2;
    if img(round(cy), round(cx)) < 100
        d = NaN; return;          % centre is not contrast-enhanced
    end
    R_max_pix = floor(min(sz)/2 - 1);
    angles = linspace(0, 2*pi, 9); angles(end) = [];
    half_lengths = zeros(numel(angles), 1);
    for a = 1:numel(angles)
        for r = 1:R_max_pix
            yy = round(cy + r * sin(angles(a)));
            xx = round(cx + r * cos(angles(a)));
            if yy < 1 || yy > sz(1) || xx < 1 || xx > sz(2); break; end
            if img(yy, xx) < 100
                half_lengths(a) = r;
                break;
            end
        end
    end
    half_lengths = half_lengths(half_lengths > 0);
    if numel(half_lengths) < 4; d = NaN; return; end
    d = 2 * median(half_lengths) * step_mm;
end
