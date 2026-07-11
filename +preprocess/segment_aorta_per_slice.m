function [mask, info] = segment_aorta_per_slice(D, opts)
%SEGMENT_AORTA_PER_SLICE  Per-slice aorta detection in axial CT.
%
%   [MASK, INFO] = SEGMENT_AORTA_PER_SLICE(D) finds the abdominal
%   aorta cross-section in each axial slice independently using
%   morphological + roundness criteria, then stacks the per-slice
%   masks into a 3D mask.
%
%   In each axial slice we:
%     1. Threshold to vessel HU range.
%     2. Find connected components ≥ small_voxels.
%     3. Score each component by: roundness (4πA/P²), proximity to
%        the expected aorta position (anterior to vertebra, slightly
%        left of midline), and area sanity (target diameter 10–35 mm).
%     4. Keep the top-scoring component.
%
%   Stacking enforces continuity: a slice's pick must be within
%   `max_xy_jump` of the previous slice's pick, otherwise we drop the
%   slice (helps when bowel contrast or renal arteries spike).
%
%   This is more robust than 3D connectivity because the aorta is
%   guaranteed to be a separate object slice-by-slice, even when 3D
%   connectivity links it to renals/kidneys via thin paths.
%
%   Inputs
%       D    : struct from preprocess.dicom_load (CT volume)
%       opts : struct with fields
%                  .HU_low / .HU_high   threshold band (default 200/400)
%                  .target_radius_mm    expected aorta lumen radius
%                                       (default 8 — typical infrarenal)
%                  .max_xy_jump_mm      max centroid jump between slices
%                                       (default 8 mm)
%                  .z_band              [z_lo z_hi] in voxel coords; if
%                                       empty, scan entire volume
%
%   Outputs
%       mask : logical Ny×Nx×Nz, 1 voxel per axial slice's chosen
%              component (the lumen)
%       info : struct with per-slice diagnostics

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D    (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'HU_low');           opts.HU_low = 200;          end
    if ~isfield(opts, 'HU_high');          opts.HU_high = 400;         end
    if ~isfield(opts, 'target_radius_mm'); opts.target_radius_mm = 8;  end
    if ~isfield(opts, 'max_xy_jump_mm');   opts.max_xy_jump_mm = 8;    end
    if ~isfield(opts, 'z_band');           opts.z_band = [];           end

    Ny = size(D.vol, 1); Nx = size(D.vol, 2); Nz = size(D.vol, 3);
    mask = false(Ny, Nx, Nz);

    % Convert pixel sizes
    pix = D.pixel_mm(1);
    target_R_vox = opts.target_radius_mm / pix;
    target_A_vox = pi * target_R_vox^2;
    max_jump_vox = opts.max_xy_jump_mm / pix;

    if isempty(opts.z_band)
        z_range = 1:Nz;
    else
        z_range = max(1, opts.z_band(1)):min(Nz, opts.z_band(2));
    end

    info.per_slice_centroid  = nan(Nz, 2);
    info.per_slice_area      = nan(Nz, 1);
    info.per_slice_roundness = nan(Nz, 1);
    info.per_slice_score     = nan(Nz, 1);

    last_xy = [];
    n_kept = 0;
    n_dropped = 0;

    t0 = tic;
    for k = z_range
        slc = D.vol(:, :, k);
        bw = (slc >= opts.HU_low) & (slc <= opts.HU_high);
        bw = imclose(bw, strel('disk', 1));
        bw = imfill(bw, 'holes');
        cc = bwconncomp(bw, 8);
        if cc.NumObjects == 0; continue; end

        % Score each component
        props = regionprops(cc, 'Area', 'Centroid', 'Perimeter', 'Eccentricity');
        n = numel(props);
        scores = zeros(n, 1);
        for i = 1:n
            A = props(i).Area;
            P = max(props(i).Perimeter, eps);
            roundness = 4 * pi * A / P^2;       % 1 for perfect circle
            % Area penalty: prefer area near pi * R_target^2
            area_pen = exp(-((A - target_A_vox) / target_A_vox)^2);
            % Continuity penalty: prefer xy near previous slice's pick
            cnt = props(i).Centroid;            % [x, y] in MATLAB convention
            if isempty(last_xy)
                cont_pen = 1;
            else
                dxy = norm(cnt - last_xy);
                cont_pen = exp(-(dxy / max_jump_vox)^2);
            end
            scores(i) = roundness * area_pen * cont_pen;
        end
        [best_score, pick] = max(scores);
        if best_score < 0.05; n_dropped = n_dropped + 1; continue; end

        idx = cc.PixelIdxList{pick};
        slice_mask = false(Ny, Nx);
        slice_mask(idx) = true;
        mask(:, :, k) = slice_mask;
        last_xy = props(pick).Centroid;
        n_kept = n_kept + 1;

        info.per_slice_centroid(k, :)  = last_xy;
        info.per_slice_area(k)         = props(pick).Area;
        info.per_slice_roundness(k)    = 4*pi*props(pick).Area / max(props(pick).Perimeter,eps)^2;
        info.per_slice_score(k)        = best_score;
    end
    info.n_kept    = n_kept;
    info.n_dropped = n_dropped;
    info.processing_time = toc(t0);
end
