function [mask, centroids_vox, R_vox, info] = track_aorta_2click(D, seed_start, seed_end, opts)
%TRACK_AORTA_2CLICK  Slice-by-slice aorta tracker between two user seeds.
%
%   [MASK, CENTROIDS_VOX, R_VOX] = TRACK_AORTA_2CLICK(D, SEED_START,
%   SEED_END) extracts the aortic lumen between two user-specified voxel
%   seeds. The function walks axially from SEED_START.z to SEED_END.z,
%   one slice at a time, finding the aorta cross-section in each slice
%   by combining:
%
%     1. Local HU threshold around the expected aorta position.
%     2. Connected-component analysis with continuity from the
%        previous slice's centroid (the lumen position rarely jumps
%        more than a few mm between adjacent slices).
%     3. Roundness scoring (the aorta is approximately circular in
%        cross-section).
%
%   This is the recommended Phase 3 centerline approach for the 25-case
%   cohort: the user only has to identify two voxels (the proximal end
%   and the distal end) and the tracker handles the rest. With 25
%   patients × 2 clicks × ~30 s of viewer time, the manual cost is
%   ~25 minutes total — far less than installing TotalSegmentator
%   end-to-end.
%
%   Inputs
%       D          : struct from preprocess.dicom_load (CT volume)
%       seed_start : 1x3 voxel coords [y x z] at the proximal end
%                    (e.g. suprarenal aorta or aortic arch)
%       seed_end   : 1x3 voxel coords [y x z] at the distal end
%                    (e.g. external iliac terminus)
%       opts       : struct with
%                      .HU_low / .HU_high   threshold band (default 200/450)
%                      .max_xy_jump_mm      max centroid jump per slice
%                                           (default 5 mm)
%                      .max_radius_mm       cap on inscribed-sphere
%                                           radius — discards slices
%                                           where lumen suddenly
%                                           explodes into kidney/etc.
%                                           (default 15 mm)
%                      .min_radius_mm       drop slices smaller than
%                                           this (default 1 mm)
%                      .roundness_min       minimum roundness score
%                                           (default 0.4)
%                      .branch              'left' / 'right' / 'longest'
%                                           — at the iliac bifurcation,
%                                           which side to follow when
%                                           two components are present.
%                                           Default 'longest'. 'left' /
%                                           'right' use a side-of-midline
%                                           tiebreaker: 'left' = patient
%                                           left = HIGHER x column, 'right'
%                                           = LOWER x column (DICOM RAS).
%                      .use_frangi          logical; gate the HU-threshold
%                                           mask through `fibermetric`
%                                           (multi-scale tubular vesselness)
%                                           to enhance round vessel cross-
%                                           sections and reject elongated
%                                           bone/vein structures. Default
%                                           true.
%                      .frangi_widths_vox   row vector of tube widths
%                                           (voxels) for fibermetric.
%                                           Default 3:2:15 (covers iliacs
%                                           ~3 mm to aorta ~15 mm at
%                                           0.7-1 mm voxel spacing).
%                      .frangi_thresh       vesselness threshold in [0,1].
%                                           Default 0.15 — mild boost; we
%                                           keep most threshold-passing
%                                           voxels and only drop ones the
%                                           filter actively rejects.
%
%   Outputs
%       mask          : Ny×Nx×Nz logical, the per-slice lumen
%       centroids_vox : N×3 [y x z] voxel coords of the lumen centroid
%                       at each tracked slice (the centerline)
%       R_vox         : N×1 inscribed-sphere radius (voxels) per node
%       info          : struct with .slices_kept, .first_z, .last_z,
%                       .reason_dropped (cell), .processing_time

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D          (1,1) struct
        seed_start (1,3) double
        seed_end   (1,3) double
        opts       (1,1) struct = struct()
    end

    if ~isfield(opts, 'HU_low');         opts.HU_low = 200;        end
    if ~isfield(opts, 'HU_high');        opts.HU_high = 450;       end
    if ~isfield(opts, 'max_xy_jump_mm'); opts.max_xy_jump_mm = 5;  end
    if ~isfield(opts, 'max_radius_mm');  opts.max_radius_mm = 15;  end
    if ~isfield(opts, 'min_radius_mm');  opts.min_radius_mm = 1;   end
    if ~isfield(opts, 'roundness_min');  opts.roundness_min = 0.4; end
    if ~isfield(opts, 'branch');         opts.branch = 'longest';  end
    if ~isfield(opts, 'use_frangi');     opts.use_frangi = true;   end
    if ~isfield(opts, 'frangi_widths_vox'); opts.frangi_widths_vox = 3:2:15; end
    if ~isfield(opts, 'frangi_thresh');  opts.frangi_thresh = 0.15; end

    Ny = size(D.vol, 1); Nx = size(D.vol, 2); Nz = size(D.vol, 3);
    mask = false(Ny, Nx, Nz);

    pix = D.pixel_mm(1);
    max_jump_vox  = opts.max_xy_jump_mm / pix;
    max_R_vox     = opts.max_radius_mm  / pix;
    min_R_vox     = opts.min_radius_mm  / pix;

    z_start = round(seed_start(3));
    z_end   = round(seed_end(3));
    direction = sign(z_end - z_start);
    if direction == 0; direction = 1; end
    z_seq = z_start:direction:z_end;
    n_slices = numel(z_seq);

    centroids_vox = nan(n_slices, 3);
    R_vox = nan(n_slices, 1);
    reason_dropped = repmat({''}, n_slices, 1);
    n_kept = 0;

    % Initial centroid = the user's start seed (in the start slice)
    last_xy = seed_start(1:2);

    t0 = tic;
    % HU normalisation window for fibermetric (used per slice when
    % opts.use_frangi). A wider band than the threshold so vessel
    % cores (~300-500 HU) don't saturate at 1.0.
    frangi_lo = opts.HU_low - 50;
    frangi_hi = opts.HU_high + 100;

    for si = 1:n_slices
        z = z_seq(si);
        slc = D.vol(:, :, z);

        % Search window around last_xy. Window radius = 4x max
        % jump plus 30 voxels (≈ 23 mm) — wide enough that the iliac
        % bifurcation, where one component splits into two, stays
        % inside the window for both branches.
        win = round(max(opts.max_xy_jump_mm * 4 / pix, 30));
        y0 = max(1, round(last_xy(1)) - win); y1 = min(Ny, round(last_xy(1)) + win);
        x0 = max(1, round(last_xy(2)) - win); x1 = min(Nx, round(last_xy(2)) + win);

        % Threshold + clean — windowed for speed (fibermetric on a
        % 60x60 patch is ~50x faster than on a 512x512 slice).
        slc_win = slc(y0:y1, x0:x1);
        bw_win = (slc_win >= opts.HU_low) & (slc_win <= opts.HU_high);

        % Vesselness gate (Frangi-style via `fibermetric`). Drops
        % bone/vein voxels that pass the HU window but aren't part of
        % a circular tube of the expected vessel radii. The HU mask
        % alone admits cancellous bone (~150-300 HU) at vertebral
        % bodies and the iliac crests; fibermetric kills these because
        % they aren't round tubes at the requested widths.
        if opts.use_frangi
            slc_norm_win = (double(slc_win) - frangi_lo) / max(frangi_hi - frangi_lo, 1);
            slc_norm_win = max(0, min(1, slc_norm_win));
            v_win = fibermetric(slc_norm_win, opts.frangi_widths_vox, ...
                'ObjectPolarity', 'bright', 'StructureSensitivity', 0.01);
            bw_win = bw_win & (v_win >= opts.frangi_thresh);
        end

        bw_win = imclose(bw_win, strel('disk', 1));
        bw_win = imfill(bw_win, 'holes');

        bw_local = false(Ny, Nx);
        bw_local(y0:y1, x0:x1) = bw_win;

        cc = bwconncomp(bw_local, 8);
        if cc.NumObjects == 0
            reason_dropped{si} = 'no components in window';
            continue;
        end

        props = regionprops(cc, 'Area', 'Centroid', 'Perimeter', 'PixelIdxList');
        n = numel(props);

        % Score each component
        scores = zeros(n, 1);
        for i = 1:n
            A = props(i).Area;
            P = max(props(i).Perimeter, eps);
            roundness = 4 * pi * A / P^2;
            if roundness < opts.roundness_min
                scores(i) = 0; continue;
            end
            R_est = sqrt(A / pi);
            if R_est < min_R_vox || R_est > max_R_vox
                scores(i) = 0; continue;
            end
            % Continuity penalty
            dxy = norm(props(i).Centroid - [last_xy(2), last_xy(1)]);
            if dxy > max_jump_vox * 4
                scores(i) = 0; continue;
            end
            cont_pen = exp(-(dxy / max_jump_vox)^2);
            score = roundness * cont_pen;

            % Branch-side bias. At/below the iliac bifurcation, two
            % candidate components appear. opts.branch lets the caller
            % steer the tracker to one side. We multiply the score by
            % a side-affinity factor based on the component centroid's
            % distance from the slice midline (positive on the wanted
            % side, negative on the wrong side, smoothly).
            if any(strcmp(opts.branch, {'left','right'}))
                cx = props(i).Centroid(1);
                dx_mid = (cx - Nx/2) / max(1, Nx/4);   % normalized: ±1 at ¼ from midline
                if strcmp(opts.branch, 'left')
                    side_bias = 1 + max(0, dx_mid);   % HIGHER x preferred
                else
                    side_bias = 1 + max(0, -dx_mid);  % LOWER x preferred
                end
                score = score * side_bias;
            end
            scores(i) = score;
        end

        if max(scores) <= 0
            reason_dropped{si} = 'no component passed scoring';
            continue;
        end

        % Pick the highest-scoring component
        [~, pick] = max(scores);
        idx = props(pick).PixelIdxList;
        slice_mask = false(Ny, Nx);
        slice_mask(idx) = true;
        mask(:, :, z) = slice_mask;

        % Inscribed-sphere radius via 2D distance transform of THIS
        % slice's mask (geometric approximation for the 3D radius)
        Dt2 = bwdist(~slice_mask);
        c_xy = props(pick).Centroid;            % [x y]
        c_y  = c_xy(2); c_x = c_xy(1);
        c_y_int = max(1, min(Ny, round(c_y)));
        c_x_int = max(1, min(Nx, round(c_x)));
        R_here = Dt2(c_y_int, c_x_int);

        centroids_vox(si, :) = [c_y, c_x, z];
        R_vox(si) = R_here;
        last_xy = [c_y, c_x];
        n_kept = n_kept + 1;
    end

    keep_mask = ~isnan(centroids_vox(:, 1));
    centroids_vox = centroids_vox(keep_mask, :);
    R_vox = R_vox(keep_mask);

    % --- Post-process: gap-fill, outlier-reject, smooth ----
    % Three sources of arc-length inflation in the raw tracker output:
    %   (1) per-slice (x,y) centroid jitter of 1-3 voxels even when
    %       locked on the aorta (the threshold-binary boundary is
    %       discrete, so any one slice can shift the centroid).
    %   (2) dropped slices: when the tracker fails to find a valid
    %       component on a slice, the next kept slice's centroid is
    %       compared directly to the last kept one, producing a
    %       diagonal "jump" that adds spurious arc length.
    %   (3) structural outliers: occasional slices where the tracker
    %       grabbed a neighboring vessel branch, producing a 10-20
    %       voxel excursion. Linear smoothing can't reject these —
    %       a one-slice outlier of 20 vox shifts a 25-wide sgolay
    %       window by ~1 vox in the smoothed output.
    % Fixes:
    %   a) build a regular slice-index grid covering [first_z, last_z]
    %   b) linearly interpolate (y, x) and R_vox onto that grid
    %   c) hampel filter to replace outliers with the local median
    %      (Signal Processing Toolbox)
    %   d) Savitzky-Golay smoother on (y, x); window-median on R
    %   e) return the dense, smoothed trajectory as the centerline
    n = size(centroids_vox, 1);
    if n > 5
        z_kept = centroids_vox(:, 3);
        z_grid = (min(z_kept):direction:max(z_kept)).';
        if isempty(z_grid) || numel(z_grid) < 5
            z_grid = z_kept;
        end
        y_grid = interp1(z_kept, centroids_vox(:, 1), z_grid, 'linear', 'extrap');
        x_grid = interp1(z_kept, centroids_vox(:, 2), z_grid, 'linear', 'extrap');
        R_grid = interp1(z_kept, R_vox,               z_grid, 'linear', 'extrap');

        % Hampel: window ~10 mm, threshold 3 sigma. Replaces points
        % > 3*MAD from the local median with the local median —
        % robust to single-slice excursions into neighboring vessels.
        slice_mm = abs(D.slice_spacing_mm);
        hw = max(5, round(5 / max(slice_mm, 0.1)));   % half-window in samples
        if numel(z_grid) > 2*hw + 1
            y_grid = hampel(y_grid, hw, 3);
            x_grid = hampel(x_grid, hw, 3);
            R_grid = hampel(R_grid, hw, 3);
        end

        % Savitzky-Golay over a ~15 mm window (cubic). With 0.5 mm
        % slice spacing that's ~30 slices; clamp to odd and length-1.
        sw_target = max(9, 2 * round(7.5 / max(slice_mm, 0.1)) + 1);
        sw = min(sw_target, numel(z_grid) - 1);
        if mod(sw, 2) == 0; sw = sw - 1; end
        sw = max(sw, 5);
        if numel(z_grid) > sw
            y_grid = sgolayfilt(y_grid, 3, sw);
            x_grid = sgolayfilt(x_grid, 3, sw);
            R_grid = movmedian(R_grid, sw);
        end

        centroids_vox = [y_grid, x_grid, z_grid];
        R_vox = R_grid;
    end

    info = struct();
    info.slices_kept    = n_kept;
    info.slices_total   = n_slices;
    info.first_z        = z_start;
    info.last_z         = z_end;
    info.reason_dropped = reason_dropped;
    info.processing_time = toc(t0);
end
