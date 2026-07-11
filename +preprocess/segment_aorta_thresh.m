function [mask, info] = segment_aorta_thresh(D, opts)
%SEGMENT_AORTA_THRESH  Threshold-based aorta + iliac segmentation.
%
%   [MASK, INFO] = SEGMENT_AORTA_THRESH(D) segments the contrast-
%   enhanced aorta and common iliac arteries from a CT volume D
%   produced by preprocess.dicom_load. Returns a logical mask the
%   same size as D.vol and an info struct describing the parameters
%   used and the connected-component analysis.
%
%   Pipeline
%       1. Window the CT to vessel HU range (default 150-600).
%       2. Largest connected component whose centroid sits in the
%          expected aorta location (anterior to spine, ~midline).
%       3. Morphological close + fill holes to recover the lumen.
%       4. Optional: dilate slightly to capture the wall.
%
%   This is the simplest possible pipeline that uses only MATLAB
%   built-ins (no TotalSegmentator, no VMTK). It is a starting point
%   for the Phase 3 smoke test on a single case; for the 25-case
%   cohort we should switch to TotalSegmentator output (saved as a
%   binary mask, then skeletonised the same way).
%
%   Inputs
%       D    : struct from preprocess.dicom_load (must be CT volume)
%       opts : struct with fields
%                  .HU_low      lower HU threshold (default 150)
%                  .HU_high     upper HU threshold (default 600)
%                  .min_voxels  minimum component size (default 1e5)
%                  .close_radius     morphological close ball
%                                    radius in voxels (default 2)
%                  .fill_holes_2d    fill holes per axial slice
%                                    (default true; true catches small
%                                    calcium voids better than 3D fill)
%
%   Outputs
%       mask : logical Ny×Nx×Nz mask
%       info : struct with .threshold_band, .n_components,
%                          .picked_component_size, .picked_centroid,
%                          .processing_time

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D    (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'HU_low');         opts.HU_low = 200;          end
    if ~isfield(opts, 'HU_high');        opts.HU_high = 400;         end
    if ~isfield(opts, 'min_voxels');     opts.min_voxels = 1e4;      end
    if ~isfield(opts, 'close_radius');   opts.close_radius = 1;      end
    if ~isfield(opts, 'erode_radius');   opts.erode_radius = 3;      end
    if ~isfield(opts, 'fill_holes_2d');  opts.fill_holes_2d = true;  end
    if ~isfield(opts, 'z_band');         opts.z_band = [];           end

    assert(isfield(D, 'is_volume') && D.is_volume, ...
        'segment_aorta_thresh:NotVolume', ...
        'Input must be a CT volume (D.is_volume must be true).');

    t0 = tic;

    % --- Step 1: window threshold ------------------------------------
    bw = (D.vol >= opts.HU_low) & (D.vol <= opts.HU_high);

    % Optional: restrict to an axial slab (abdomen + iliacs only)
    if ~isempty(opts.z_band)
        z_keep = false(size(bw, 3), 1);
        z_keep(opts.z_band(1):min(opts.z_band(2), end)) = true;
        bw(:, :, ~z_keep) = false;
    end

    % --- Step 2: erode to break thin connections to other organs ----
    % Aorta is ~10 mm = 13 voxels in diameter. Eroding by 3 voxels
    % keeps the aorta lumen connected (still ~7 voxel diameter) while
    % breaking off renal arteries (~3 voxels), mesenteric branches,
    % and small connections to spleen/liver.
    if opts.erode_radius > 0
        se_e = strel('sphere', opts.erode_radius);
        bw = imerode(bw, se_e);
    end
    if opts.close_radius > 0
        se = strel('sphere', opts.close_radius);
        bw = imclose(bw, se);
    end

    if opts.fill_holes_2d
        for k = 1:size(bw, 3)
            bw(:, :, k) = imfill(bw(:, :, k), 'holes');
        end
    end

    % --- Step 3: connected components, pick the aorta -----------------
    cc = bwconncomp(bw, 26);
    sizes = cellfun(@numel, cc.PixelIdxList);
    big = find(sizes >= opts.min_voxels);
    if isempty(big)
        warning('segment_aorta_thresh:NoLargeComponent', ...
            'No connected component with >= %d voxels.', opts.min_voxels);
        mask = false(size(D.vol));
        info = struct();
        return;
    end

    % Pick by "tubularity": the aorta + iliacs has a much larger
    % principal axis than its volume^(1/3) (it's long and thin),
    % whereas kidneys and the heart blood pool are roughly round
    % (extent ~ volume^(1/3)). Score = z_extent / volume^(1/3).
    Ny = size(D.vol, 1); Nx = size(D.vol, 2); Nz = size(D.vol, 3);
    centroids = zeros(numel(big), 3);
    tube_score = zeros(numel(big), 1);
    for i = 1:numel(big)
        idx = cc.PixelIdxList{big(i)};
        [yy, xx, zz] = ind2sub(size(D.vol), idx);
        centroids(i, :) = [mean(yy), mean(xx), mean(zz)];
        % z-extent in voxels; cube-root of volume in voxels
        z_ext = max(zz) - min(zz);
        tube_score(i) = z_ext / max(1, sizes(big(i))^(1/3));
    end
    [~, pick] = max(tube_score);
    pick_idx = big(pick);

    mask = false(size(D.vol));
    mask(cc.PixelIdxList{pick_idx}) = true;

    % --- Step 4: dilate back what erosion removed, then fill --------
    if opts.erode_radius > 0
        se_d = strel('sphere', opts.erode_radius);
        mask = imdilate(mask, se_d);
        % Constrain dilation to the original threshold band — we don't
        % want to grow beyond the contrast-enhanced lumen.
        mask = mask & (D.vol >= opts.HU_low) & (D.vol <= opts.HU_high);
    end
    if opts.fill_holes_2d
        for k = 1:size(mask, 3)
            mask(:, :, k) = imfill(mask(:, :, k), 'holes');
        end
    end

    info = struct();
    info.threshold_band       = [opts.HU_low, opts.HU_high];
    info.n_components         = numel(sizes);
    info.n_large_components   = numel(big);
    info.picked_component_size = sizes(pick_idx);
    info.picked_centroid      = centroids(pick, :);
    info.processing_time      = toc(t0);
end
