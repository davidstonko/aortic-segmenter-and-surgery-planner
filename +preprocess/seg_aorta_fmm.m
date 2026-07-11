function [mask, info] = seg_aorta_fmm(D, seed_vox, opts)
%SEG_AORTA_FMM  Click-driven aortic segmentation using fast marching.
%
%   [MASK, INFO] = SEG_AORTA_FMM(D, SEED_VOX) takes a CT volume struct
%   and one voxel coordinate inside the aorta lumen, and returns a
%   3D binary mask of the connected contrast-enhanced vasculature.
%
%   Pipeline
%       1. fibermetric (multi-scale Frangi vesselness) on the CT
%          → tubularity score in [0,1] at every voxel. Tubes light
%          up; round structures (kidneys, heart) are dim.
%       2. imsegfmm — built-in fast-marching segmentation, takes the
%          vesselness map as the cost field and the user click as
%          the seed. Returns voxels reachable within a threshold
%          along ridges of high vesselness.
%       3. Morphological cleanup: imclose to fill micro-gaps,
%          imfill('holes') to close the lumen interior, then keep
%          only the connected component containing the seed.
%
%   Inputs
%       D        : struct from preprocess.dicom_load (CT volume)
%       seed_vox : 1x3 voxel coords [y x z] inside the aorta lumen
%       opts     : struct with
%                    .scales         vessel-radius scales for
%                                    fibermetric (voxels)
%                                    default [3 5 8 12]
%                    .threshold      imsegfmm cutoff in [0,1]
%                                    default 0.5 (lower = more lenient)
%                    .HU_min         absolute HU floor before
%                                    vesselness, removes air/fat.
%                                    default 100
%                    .close_radius   morphological close radius
%                                    in voxels, default 1
%                    .vesselness     pre-computed vesselness map (3D
%                                    [0,1]), if you already ran
%                                    fibermetric — saves time on
%                                    re-runs after the user moves
%                                    the threshold slider.
%
%   Outputs
%       mask     : Ny×Nx×Nz logical, the segmented aorta + iliacs
%       info     : struct with
%                    .vesselness     the fibermetric output (so the
%                                    GUI can cache and re-run with
%                                    different thresholds)
%                    .raw_mask       imsegfmm output before cleanup
%                    .picked_volume_mL  mask volume in mL
%                    .processing_time   total seconds

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D        (1,1) struct
        seed_vox (1,3) double
        opts     (1,1) struct = struct()
    end

    if ~isfield(opts, 'scales');       opts.scales       = [3 5 8 12]; end
    % imsegfmm 'thresh' is the geodesic-time cutoff (normalized).
    % Empirically, ~0.05 gives a clean aortic lumen on a CTA;
    % 0.02 = very tight, 0.1 = starts leaking into renal/visceral
    % branches.
    if ~isfield(opts, 'threshold');    opts.threshold    = 0.05;       end
    if ~isfield(opts, 'HU_min');       opts.HU_min       = 100;        end
    if ~isfield(opts, 'close_radius'); opts.close_radius = 1;          end
    if ~isfield(opts, 'vesselness');   opts.vesselness   = [];         end

    assert(D.is_volume, 'seg_aorta_fmm:NotVolume', 'D must be a CT volume.');

    t0 = tic;

    % --- Step 1: vesselness preprocessing -----------------------------
    % fibermetric scales the input so any HU range works, but masking
    % out air/fat (HU < 100) before the filter sharpens the response
    % at the vessel wall.
    if isempty(opts.vesselness)
        prep = D.vol;
        prep(prep < opts.HU_min) = opts.HU_min;
        % fibermetric expects single, returns single in [0,1]
        V = fibermetric(single(prep), opts.scales, ...
            'StructureSensitivity', 0.5, 'ObjectPolarity', 'bright');
    else
        V = opts.vesselness;
    end

    % --- Step 2: imsegfmm from the user seed --------------------------
    % imsegfmm needs the seed as a logical volume of the same size
    % as the cost field. Cost field is 1 - vesselness so the path
    % "flows" along high-vesselness ridges. Threshold is applied to
    % the geodesic-time map.
    seed_mask = false(size(D.vol));
    sy = max(1, min(size(D.vol,1), round(seed_vox(1))));
    sx = max(1, min(size(D.vol,2), round(seed_vox(2))));
    sz = max(1, min(size(D.vol,3), round(seed_vox(3))));
    seed_mask(sy, sx, sz) = true;

    % imsegfmm handles cost > 0; vesselness is already in [0,1] but
    % can have zeros. Add a small floor so propagation never stalls
    % in low-vesselness gaps but is still strongly preferred along
    % vessels.
    cost = max(V, 0.05);
    [raw_mask, ~] = imsegfmm(cost, seed_mask, opts.threshold);

    % --- Step 3: morphological cleanup --------------------------------
    if opts.close_radius > 0
        raw_mask = imclose(raw_mask, strel('sphere', opts.close_radius));
    end
    raw_mask = imfill(raw_mask, 'holes');

    % Keep only the connected component containing the seed
    cc = bwconncomp(raw_mask, 26);
    pick = 0;
    for i = 1:cc.NumObjects
        if any(cc.PixelIdxList{i} == sub2ind(size(D.vol), sy, sx, sz))
            pick = i; break;
        end
    end
    mask = false(size(D.vol));
    if pick > 0
        mask(cc.PixelIdxList{pick}) = true;
    else
        % seed didn't survive cleanup; return the raw mask
        mask = raw_mask;
    end

    % --- Diagnostics --------------------------------------------------
    info = struct();
    info.vesselness        = V;
    info.raw_mask          = raw_mask;
    info.picked_volume_mL  = sum(mask(:)) * D.pixel_mm(1) * D.pixel_mm(2) * ...
                             D.slice_spacing_mm / 1000;
    info.processing_time   = toc(t0);
end
