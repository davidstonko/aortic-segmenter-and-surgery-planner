function [mask_out, info] = follow_iliacs_adaptive(D, mask_in, label_in, opts)
%AUTOSEG.FOLLOW_ILIACS_ADAPTIVE  Extend the iliacs to the CFAs using
%   the aorta's own HU profile as a per-patient contrast reference —
%   no bridges, no fixed HU thresholds.
%
%   [MASK_OUT, INFO] = autoseg.follow_iliacs_adaptive(D, MASK_IN, LABEL_IN, OPTS)
%
%   The insight: once we've segmented the aorta, we know the
%   bolus-contrast HU profile for THIS patient. The iliacs branch from
%   the aorta and contain the same bolus, so their HU is similar.
%   Rather than relying on a broad fixed window like [150, 1400] (the
%   default in `extend_to_cfa`'s slice-by-slice walker — which both
%   misses real iliacs at partial-volume edges AND picks up bone-marrow
%   bleeds at the upper end), this function derives an adaptive window
%   from the aorta voxels and uses it to region-grow the iliacs through
%   pelvic contrast voxels.
%
%   The approach is bridge-free by construction: the only voxels that
%   get added to the mask are voxels that ALREADY have aorta-grade
%   contrast HU in the source CT. No synthetic voxels are painted. No
%   tubes through tissue.
%
%   INPUT
%       D          struct from preprocess.dicom_load (with .vol +
%                  .pixel_mm + .slice_spacing_mm).
%       MASK_IN    logical Y×X×Z aorta+iliac mask from
%                  extend_and_detect_branches.
%       LABEL_IN   uint8 Y×X×Z label volume (1=aorta, 2/3=iliacs,
%                  4/5=CFA-extension, 6/7=renals, 8=celiac, 9=SMA).
%       OPTS       struct, optional:
%           .hu_lo_sigma_below   multiplier on aorta std for the lower
%                                bound (default 1.5). Window lower =
%                                aorta_median - hu_lo_sigma_below*std.
%           .hu_hi_sigma_above   multiplier on aorta std for the upper
%                                bound (default 2.0). Window upper =
%                                aorta_median + hu_hi_sigma_above*std.
%           .hu_hi_cap_above_p99 mm offset above aorta p99 to cap the
%                                upper bound (default 50 HU). Stops
%                                bone-marrow / calcium from entering.
%           .hu_lo_floor         absolute minimum for the lower bound
%                                (default 200 HU). Soft-tissue floor.
%           .anchor_band_mm      aorta-bifurcation anchor band length
%                                in mm cranial of z_bifurc (default 50
%                                mm). The region grow uses voxels from
%                                this band + any existing iliac labels
%                                as the seed.
%           .pelvis_lo_offset_mm grow restriction in mm cranial of
%                                z_bifurc (default 30 mm). Voxels above
%                                z_bifurc - this can't be grown.
%           .keep_largest_cc     keep only the largest 3D-CC of the
%                                final mask (default true).
%           .vessel_max_mm2      per-slice in-plane area ceiling (mm^2,
%                                default 400) for the leak guard. Any
%                                axial component larger than this is
%                                dropped from the contrast grow
%                                candidates so the flood can't leak into
%                                bone marrow / bladder / bowel / veins.
%           .morph_clean_radius_vox  morphological open+close radius in
%                                voxels for de-spiking (default 1 vox
%                                = cube-3 structuring element). Use 0
%                                to skip the morphological cleanup.
%           .verbose             default true.
%
%   OUTPUT
%       MASK_OUT   logical Y×X×Z — input mask UNION grown iliac voxels
%                  (post-cleanup, single largest CC).
%       INFO       struct with diagnostics:
%           .aorta_hu_median, .aorta_hu_std, .aorta_hu_p99
%           .hu_window         [lo, hi] used for the grow
%           .z_bifurc          aorta-bifurcation slice index
%           .seed_voxels       voxel count in the grow seed
%           .grown_voxels      voxel count after region-grow + cleanup
%           .R_z_extent        [min, max] R-side z-slices reached
%           .L_z_extent        [min, max] L-side z-slices reached
%           .reason            text summary

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D        (1,1) struct
        mask_in  logical
        label_in uint8
        opts     (1,1) struct = struct()
    end

    % --- Defaults ---
    % Bolus-fraction approach: the iliac HU is expected to be within
    % a band scaled to the bolus peak. Empirical default: [0.55, 1.15]
    % × bolus_peak. Captures bolus dynamics (contrast at distal vessels
    % is typically 60-90% of proximal aorta) while excluding bone (which
    % is > 1.2× any bolus) and soft tissue (< 0.4× any reasonable bolus).
    % The legacy sigma_below / sigma_above are still honored — the
    % function takes the WIDER of the two bands so we don't accidentally
    % narrow a well-behaved scan.
    if ~isfield(opts, 'hu_lo_bolus_frac');    opts.hu_lo_bolus_frac = 0.55;  end
    if ~isfield(opts, 'hu_hi_bolus_frac');    opts.hu_hi_bolus_frac = 1.15;  end
    if ~isfield(opts, 'hu_lo_sigma_below');   opts.hu_lo_sigma_below = 1.5;  end
    if ~isfield(opts, 'hu_hi_sigma_above');   opts.hu_hi_sigma_above = 2.0;  end
    if ~isfield(opts, 'hu_hi_cap_above_p99'); opts.hu_hi_cap_above_p99 = 50; end
    % Soft-tissue floor — even on very low-contrast scans, the iliac
    % bolus should be > 100 HU (well above muscle ~50 HU, fat <0 HU).
    if ~isfield(opts, 'hu_lo_floor');         opts.hu_lo_floor = 150;        end
    if ~isfield(opts, 'anchor_band_mm');      opts.anchor_band_mm = 50;      end
    if ~isfield(opts, 'pelvis_lo_offset_mm'); opts.pelvis_lo_offset_mm = 30; end
    if ~isfield(opts, 'keep_largest_cc');     opts.keep_largest_cc = true;   end
    % Vessel-size leak guard. The pelvis is full of structures that
    % share the iliac bolus HU window — cancellous BONE MARROW (iliac
    % wings, sacrum, femoral heads ~200-400 HU), an opacified BLADDER,
    % contrast-filled BOWEL, and iliac VEIN pools. An unguarded 3-D
    % flood leaks into all of them (observed on the low-contrast
    % JohnDoe2 case: the pelvis ballooned 300 -> 806 mL, the clean
    % bifurcated tube buried under bilateral bone-marrow fill). Iliac
    % and CFA lumen cross-sections are small, so any in-plane component
    % larger than this physical area ceiling is dropped from the grow's
    % CANDIDATE set before region-growing. Matches the walker's
    % `vessel_max_vox = 400 mm^2` ceiling in extend_to_cfa. This adds
    % no synthetic voxels; it only removes non-vessel candidates, so the
    % no-bridges invariant holds.
    if ~isfield(opts, 'vessel_max_mm2');      opts.vessel_max_mm2 = 400;     end
    % Spatial confinement of the flood to a tube around the already-tracked
    % vessel path (mask_in). On a LOW-CONTRAST scan the arterial bolus and
    % cancellous bone marrow HU windows overlap (JohnDoe2 bolus peak 376 HU
    % vs iliac-wing marrow 200-400 HU), so a HU flood that is unconstrained
    % in SPACE leaks bilaterally into the iliac wings, sacrum and femoral
    % heads regardless of any per-slice area cap (veins and thin marrow rinds
    % are vessel-calibre and slip under the cap). The walker has already
    % honestly tracked the aorta+iliacs per-slice; the flood's only job is to
    % RECOVER partial-volume edge voxels in the immediate vicinity of that
    % path. Restricting the grow candidates to within TUBE_RADIUS_MM of the
    % tracked vessel removes the distant-pelvis leak while still thickening
    % genuinely thin iliac segments. The seed (mask_in itself) is always
    % included in the reconstruct, so no real vessel is lost — the tube only
    % bounds NEW additions. Adds no synthetic voxels (no-bridges invariant).
    if ~isfield(opts, 'tube_radius_mm');      opts.tube_radius_mm = 5;       end
    % Morphological opening default disabled — would erode thin iliacs.
    % Enable from the caller (radius=1) only when post-grow has obvious
    % isolated-voxel noise to clean up.
    if ~isfield(opts, 'morph_clean_radius_vox'); opts.morph_clean_radius_vox = 0; end
    if ~isfield(opts, 'verbose');             opts.verbose = true;           end

    sz = size(D.vol);
    if ~isequal(size(mask_in), sz);  error('mask_in size mismatch'); end
    if ~isequal(size(label_in), sz); error('label_in size mismatch'); end

    % --- 1. Sample aorta HU distribution + locate the BOLUS peak ---
    % The aorta segmentation includes partial-volume edge voxels with
    % HU well below the bolus peak (typically 30-150 HU). Using the
    % aorta voxels' OVERALL median to anchor the adaptive window
    % under-estimates the bolus on lower-contrast scans (e.g. JohnDoe2
    % aorta median = 111 HU despite bolus peak at 376 HU). Use the
    % HISTOGRAM MODE as the bolus reference, and estimate spread from
    % voxels within ±100 HU of that mode (the bolus core).
    aorta = (label_in == 1);
    if ~any(aorta(:))
        info = struct('skipped', 'no aorta label', 'reason', 'No aorta label to anchor on');
        mask_out = mask_in;
        return;
    end
    aorta_vox = double(D.vol(aorta));
    aorta_med = median(aorta_vox);
    aorta_p99 = prctile(aorta_vox, 99);

    % Bolus mode = peak of HU histogram. Use 25-HU bins.
    [h, edges] = histcounts(aorta_vox, 'BinWidth', 25);
    [~, k_peak] = max(h);
    bolus_peak = (edges(k_peak) + edges(k_peak + 1)) / 2;
    % Bolus std = std of voxels within ±100 HU of the peak
    bolus_band = aorta_vox(abs(aorta_vox - bolus_peak) < 100);
    if numel(bolus_band) < 100; bolus_band = aorta_vox; end
    bolus_std = std(bolus_band);

    % Lower: max(floor, MIN of sigma-based and bolus-fraction lower bounds)
    %         so a well-defined sigma never WIDENS into noise.
    % Upper: min(p99+cap, MAX of sigma-based and bolus-fraction upper bounds)
    %         so a tight sigma never narrows out a real wider bolus distribution.
    hu_lo_sigma  = bolus_peak - opts.hu_lo_sigma_below * bolus_std;
    hu_lo_frac   = opts.hu_lo_bolus_frac * bolus_peak;
    hu_lo        = max(opts.hu_lo_floor, min(hu_lo_sigma, hu_lo_frac));
    hu_hi_sigma  = bolus_peak + opts.hu_hi_sigma_above * bolus_std;
    hu_hi_frac   = opts.hu_hi_bolus_frac * bolus_peak;
    hu_hi        = min(aorta_p99 + opts.hu_hi_cap_above_p99, max(hu_hi_sigma, hu_hi_frac));

    if opts.verbose
        fprintf('[follow_iliacs_adaptive] Aorta HU: median=%.0f, p99=%.0f, bolus_peak=%.0f (std around peak=%.0f)\n', ...
            aorta_med, aorta_p99, bolus_peak, bolus_std);
        fprintf('[follow_iliacs_adaptive] Adaptive window: [%.0f, %.0f]\n', hu_lo, hu_hi);
    end

    % --- 2. Identify z_bifurc (most-caudal aorta slice) ---
    aorta_zp = squeeze(any(any(aorta, 1), 2));
    z_bifurc = find(aorta_zp, 1, 'last');
    if isempty(z_bifurc)
        info = struct('skipped', 'no aorta slices');
        mask_out = mask_in;
        return;
    end
    if opts.verbose
        fprintf('[follow_iliacs_adaptive] z_bifurc = %d\n', z_bifurc);
    end

    % --- 3. Build contrast mask restricted to pelvis ---
    ssp = abs(D.slice_spacing_mm);
    anchor_band_vox  = round(opts.anchor_band_mm  / ssp);
    pelvis_lo_offset = round(opts.pelvis_lo_offset_mm / ssp);

    contrast = (D.vol >= hu_lo) & (D.vol <= hu_hi);
    z_pelvis_lo = max(1, z_bifurc - pelvis_lo_offset);
    contrast_pelvis = contrast;
    contrast_pelvis(:, :, 1:z_pelvis_lo - 1) = false;

    % --- 3b. Vessel-size leak guard on the candidate contrast --------
    % Drop bone-marrow / bladder / bowel / vein blobs (all far larger in
    % axial cross-section than an iliac lumen) so the flood below can
    % only propagate through vessel-calibre contrast. The existing iliac
    % labels (seed_mask, built next) are NOT capped — they go in whole —
    % so a genuinely aneurysmal iliac already captured by TS/the walker
    % is preserved; the cap only constrains NEW growth.
    pix_mm = abs(D.pixel_mm(1));
    vessel_max_vox = round(opts.vessel_max_mm2 / pix_mm^2);
    n_cand_before = nnz(contrast_pelvis);
    contrast_pelvis = autoseg.drop_big_inplane_cc(contrast_pelvis, vessel_max_vox);
    if opts.verbose
        fprintf(['[follow_iliacs_adaptive] Leak guard: vessel ceiling ' ...
            '%.0f mm^2 (%d vox); contrast candidates %d -> %d\n'], ...
            opts.vessel_max_mm2, vessel_max_vox, n_cand_before, nnz(contrast_pelvis));
    end

    % --- 3c. Spatial confinement: keep only candidates within a tube of
    % radius tube_radius_mm around the already-tracked vessel path. This is
    % the primary leak guard on low-contrast scans where HU alone cannot
    % separate arterial lumen from adjacent cancellous marrow.
    if opts.tube_radius_mm > 0
        tube_r = max(2, round(opts.tube_radius_mm / pix_mm));
        tube = imdilate(mask_in, strel('sphere', tube_r));
        n_cand_tube = nnz(contrast_pelvis);
        contrast_pelvis = contrast_pelvis & tube;
        if opts.verbose
            fprintf(['[follow_iliacs_adaptive] Tube confine: r=%.0f mm ' ...
                '(%d vox); candidates %d -> %d\n'], opts.tube_radius_mm, ...
                tube_r, n_cand_tube, nnz(contrast_pelvis));
        end
    end

    % --- 4. Build seed: existing iliac/CFA labels + aorta bifurcation anchor band ---
    seed_mask = (label_in == 2) | (label_in == 3) | (label_in == 4) | (label_in == 5);
    z_anchor_lo = max(1, z_bifurc - anchor_band_vox);
    anchor_zs = false(1, 1, sz(3));
    anchor_zs(1, 1, z_anchor_lo:z_bifurc) = true;
    aorta_anchor = aorta & repmat(anchor_zs, [sz(1), sz(2), 1]);
    seed_mask = seed_mask | aorta_anchor;

    if ~any(seed_mask(:))
        info = struct('skipped', 'no seed voxels');
        mask_out = mask_in;
        return;
    end

    n_seed = nnz(seed_mask);
    if opts.verbose
        fprintf('[follow_iliacs_adaptive] Seed voxels: %d\n', n_seed);
    end

    % --- 5. Region grow ---
    grown = imreconstruct(seed_mask, seed_mask | contrast_pelvis, 26);

    % --- 6. Morphological cleanup ---
    % Opening: drop tiny isolated voxels (sub-vessel noise) — safe.
    % Closing: NOT applied here. The classical opening+closing pattern
    % would fill in small concavities with NEW voxels that may not have
    % bolus-grade HU — that's a soft bridge through tissue (HU<<window),
    % which violates the no-bridges invariant. If smoothing is needed
    % for visualization, the render layer does it independently on a
    % copy of the mask.
    if opts.morph_clean_radius_vox > 0
        se = strel('cube', 2 * opts.morph_clean_radius_vox + 1);
        grown = imopen(grown, se);
    end

    % --- 7. Largest 3D-CC ---
    if opts.keep_largest_cc
        cc = bwconncomp(grown, 26);
        if cc.NumObjects > 1
            sizes_cc = cellfun(@numel, cc.PixelIdxList);
            [~, kbig] = max(sizes_cc);
            grown_big = false(sz);
            grown_big(cc.PixelIdxList{kbig}) = true;
            grown = grown_big;
        end
    end

    % --- 8. Merge: aorta (above z_bifurc) + grown pelvis (below + anchor) ---
    % This preserves the aorta even where it doesn't meet the adaptive
    % HU window (e.g. proximal aorta where the bolus has different
    % attenuation than at the bifurcation).
    mask_out = (label_in == 1) | mask_in | grown;

    % --- 9. Diagnostics ---
    mid_x = NaN;
    slc_a = aorta(:, :, z_bifurc);
    if any(slc_a(:))
        [~, xa] = find(slc_a);
        mid_x = round(mean(xa));
    end
    R_zs = []; L_zs = [];
    if ~isnan(mid_x)
        on_R = false(sz); on_R(:, 1:mid_x, :) = true;
        on_L = false(sz); on_L(:, mid_x+1:end, :) = true;
        R_zs = find(squeeze(any(any(mask_out & on_R, 1), 2)));
        L_zs = find(squeeze(any(any(mask_out & on_L, 1), 2)));
    end

    info = struct( ...
        'aorta_hu_median', aorta_med, ...
        'aorta_hu_p99',    aorta_p99, ...
        'bolus_peak_hu',   bolus_peak, ...
        'bolus_std_hu',    bolus_std, ...
        'hu_window',       [hu_lo, hu_hi], ...
        'z_bifurc',        z_bifurc, ...
        'vessel_max_mm2',  opts.vessel_max_mm2, ...
        'vessel_max_vox',  vessel_max_vox, ...
        'seed_voxels',     n_seed, ...
        'grown_voxels',    nnz(grown), ...
        'R_z_extent',      [min(R_zs), max(R_zs)], ...
        'L_z_extent',      [min(L_zs), max(L_zs)], ...
        'reason',          sprintf( ...
            'Aorta-adaptive HU window [%.0f, %.0f] (bolus peak %.0f ± %.0f). Pelvis grow %d -> %d voxels.', ...
            hu_lo, hu_hi, bolus_peak, bolus_std, n_seed, nnz(grown)));

    if opts.verbose
        if ~isempty(R_zs)
            fprintf('[follow_iliacs_adaptive] R reach: z=%d..%d\n', min(R_zs), max(R_zs));
        end
        if ~isempty(L_zs)
            fprintf('[follow_iliacs_adaptive] L reach: z=%d..%d\n', min(L_zs), max(L_zs));
        end
    end
end
