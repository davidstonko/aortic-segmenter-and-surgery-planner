function [cpr_img, cpr_meta] = curved_planar_reformat(vol, polyline_vox, opts)
%PREPROCESS.CURVED_PLANAR_REFORMAT  Build a TeraRecon-style straightened
%   vessel view from a CT volume + a centerline polyline.
%
%   [CPR_IMG, META] = preprocess.curved_planar_reformat(VOL, POLYLINE_VOX)
%   [CPR_IMG, META] = preprocess.curved_planar_reformat(..., OPTS)
%
%   Produces a 2-D image where ROWS index along the centerline (arc
%   length) and COLUMNS index laterally across a sampling plane that's
%   perpendicular to the centerline at each row. The result reads like
%   a "longitudinal section" of the vessel — straightening any aortic
%   tortuosity so the lumen sits as a clean column down the middle.
%
%   This is the canonical CPR; TeraRecon's "Straightened View" / "sMPR"
%   is the same idea. We project along a single in-plane direction
%   (default: AP / coronal) which gives the readiest "coronal-like"
%   straightened image. For multi-angle CPR (rotating the sampling
%   plane around the centerline) call this function repeatedly.
%
%   Inputs
%       VOL            Y × X × Z CT volume (HU, single or double).
%       POLYLINE_VOX   N × 3 centerline in voxel coordinates [y x z].
%                      Convention is distal → proximal, but the
%                      function works either way.
%       OPTS           struct with optional fields:
%           .lateral_mm        half-width of the sampling plane (mm)
%                              default 30 (so cpr image is 60 mm wide)
%           .lateral_step_mm   sampling resolution laterally (mm)
%                              default 0.5
%           .arc_step_mm       sampling resolution along arc (mm)
%                              default 0.5
%           .pixel_mm          [dy dx] in-plane spacing of VOL
%                              default [1 1] (assumes already in mm)
%           .slice_spacing_mm  z spacing of VOL
%                              default 1
%           .ray_dir           in-plane direction of the projection
%                              ray. Default [1 0 0] = patient X (AP).
%
%   Output
%       CPR_IMG        Narc × Nlat single — the straightened image.
%       META.arc_mm    Narc × 1 cumulative arc length at each row.
%       META.lat_mm    1 × Nlat lateral offset at each column.
%       META.frame     Narc × 3 × 3 — local frame at each centerline
%                      sample {tangent, normal, binormal}, useful for
%                      back-mapping CPR clicks to volume coordinates.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        vol           {mustBeNumeric}
        polyline_vox  (:,3) double
        opts          (1,1) struct = struct()
    end

    if ~isfield(opts, 'lateral_mm');       opts.lateral_mm       = 30;  end
    if ~isfield(opts, 'lateral_step_mm');  opts.lateral_step_mm  = 0.5; end
    if ~isfield(opts, 'arc_step_mm');      opts.arc_step_mm      = 0.5; end
    if ~isfield(opts, 'pixel_mm');         opts.pixel_mm         = [1 1]; end
    if ~isfield(opts, 'slice_spacing_mm'); opts.slice_spacing_mm = 1;   end
    if ~isfield(opts, 'ray_dir');          opts.ray_dir          = [1 0 0]; end

    % Convert centerline to mm so arc length and tangents are isotropic.
    P_mm = [polyline_vox(:,1) * opts.pixel_mm(1), ...
            polyline_vox(:,2) * opts.pixel_mm(2), ...
            polyline_vox(:,3) * opts.slice_spacing_mm];

    % Resample the centerline at a uniform mm step along arc length so
    % the CPR image rows correspond to evenly-spaced anatomy.
    arc_raw = [0; cumsum(vecnorm(diff(P_mm, 1, 1), 2, 2))];
    L = arc_raw(end);
    arc_uniform = (0:opts.arc_step_mm:L)';
    if numel(arc_uniform) < 2
        cpr_img = zeros(2, 2, 'single');
        cpr_meta = struct('arc_mm', arc_uniform, 'lat_mm', 0, 'frame', []);
        return;
    end
    P_uniform = [interp1(arc_raw, P_mm(:,1), arc_uniform, 'linear', 'extrap'), ...
                 interp1(arc_raw, P_mm(:,2), arc_uniform, 'linear', 'extrap'), ...
                 interp1(arc_raw, P_mm(:,3), arc_uniform, 'linear', 'extrap')];

    % Tangents via centered differences in mm.
    T = zeros(size(P_uniform));
    T(1:end-1, :) = diff(P_uniform, 1, 1);
    T(end, :) = T(end-1, :);
    T = T ./ max(vecnorm(T, 2, 2), eps);

    % Build a parallel-transport frame so the lateral ray direction
    % drifts smoothly along the centerline (no Frenet-frame flips at
    % straight segments).
    ray_dir = opts.ray_dir(:)' / max(norm(opts.ray_dir), eps);
    N0 = ray_dir - (ray_dir * T(1,:)') * T(1,:);
    N0 = N0 / max(norm(N0), eps);
    N = zeros(size(P_uniform));
    N(1, :) = N0;
    for k = 2:size(P_uniform, 1)
        prev = N(k-1, :);
        % Reproject onto plane perpendicular to current tangent
        proj = prev - (prev * T(k,:)') * T(k,:);
        if norm(proj) < 1e-6
            % degenerate — fall back to ray_dir
            proj = ray_dir - (ray_dir * T(k,:)') * T(k,:);
        end
        N(k, :) = proj / max(norm(proj), eps);
    end

    % Lateral sample positions in mm.
    lat_mm = (-opts.lateral_mm : opts.lateral_step_mm : opts.lateral_mm);
    Nlat = numel(lat_mm);
    Narc = size(P_uniform, 1);

    % Build the 3-D sampling grid in mm coordinates.
    %   sample(k, j) = P_uniform(k) + lat_mm(j) * N(k)
    Y_mm = P_uniform(:,1) + N(:,1) * lat_mm;     % Narc × Nlat
    X_mm = P_uniform(:,2) + N(:,2) * lat_mm;
    Z_mm = P_uniform(:,3) + N(:,3) * lat_mm;

    % Convert mm sample positions back to voxel index space (interp3
    % expects the volume's intrinsic grid).
    %   y_vox = y_mm / pixel_mm(1)    (recall vol axis 1 is Y/row)
    Yv = Y_mm / opts.pixel_mm(1) + 1;
    Xv = X_mm / opts.pixel_mm(2) + 1;
    Zv = Z_mm / opts.slice_spacing_mm + 1;

    % interp3 wants meshgrid order (X, Y, Z) for the grid AND query
    % points; vol(:,:,k) is (Y, X) so we use F = vol with default axis
    % interpretation, and pass query Xq, Yq, Zq matching that axis order.
    cpr_img = single(interp3(single(vol), Xv, Yv, Zv, 'linear', single(-1000)));

    cpr_meta = struct();
    cpr_meta.arc_mm = arc_uniform;
    cpr_meta.lat_mm = lat_mm;
    cpr_meta.frame  = cat(3, T, N, cross(T, N, 2));
    cpr_meta.P_uniform_mm = P_uniform;
end
