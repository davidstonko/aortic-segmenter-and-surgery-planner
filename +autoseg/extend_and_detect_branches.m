function [mask_out, label_out, info] = extend_and_detect_branches(D, seg, opts)
%AUTOSEG.EXTEND_AND_DETECT_BRANCHES  Post-TS branch + CFA recovery.
%
%   [MASK, LABEL_VOL, INFO] = autoseg.extend_and_detect_branches(D, SEG, OPTS)
%
%   D     CT volume struct (with .vol, .pixel_mm, .slice_spacing_mm)
%   SEG   uint8 multilabel volume from TotalSegmentator (-ml output).
%         Label IDs follow autoseg.class_name_to_id().
%
%   What this does (in order):
%     1. Extracts TS aorta (52), iliac_artery_left (65), iliac_artery_right (66).
%     2. CFA extension — for each iliac, finds the most-caudal voxels
%        and flood-fills distally in HU 400-1000 with a 6-connectivity
%        region grow, geodesic-bounded so it doesn't run past the
%        common femoral level. Captures the EIA + CFA continuation
%        that TS misses (or, on the JohnDoe1 CT, the entire R iliac
%        which TS shortchanged in --fast mode).
%     3. Branch detection — for the aorta, finds connected components
%        of HU 500-1000 voxels that touch the aorta surface but aren't
%        in the TS mask. These are renal arteries (lateral), SMA
%        (anterior at L1), celiac (anterior at T12), and any other
%        contrast-filled branch. Each component above MIN_BRANCH_VOX
%        gets its own label.
%
%   OPTS fields (all optional):
%     .hu_lo_extend       400      lumen floor for CFA extension
%     .hu_hi_extend       1000
%     .hu_lo_branch       500
%     .hu_hi_branch       1000
%     .min_branch_vox     50       smallest CC kept as a branch
%     .geodesic_extend    300      voxels — how far CFA grow walks
%     .verbose            true
%
%   Returns:
%     MASK         logical Y×X×Z, union of TS labels + extensions + branches
%     LABEL_VOL    uint8 Y×X×Z, per-label-id territory (TS ids preserved
%                  where TS had them; new branches get fresh ids 200+)
%     INFO         struct with per-step voxel counts and detected branch
%                  centroids/sizes (for downstream landmark labeling)

    arguments
        D    (1,1) struct
        seg  uint8
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'hu_lo_extend'),    opts.hu_lo_extend    = 400;  end
    if ~isfield(opts, 'hu_hi_extend'),    opts.hu_hi_extend    = 1000; end
    % Branch HU window — tighter than extend so we don't leak into
    % cortical bone. Peak arterial contrast is ~700; bone cortex
    % starts near 800-900 and goes up. Window [600, 850] keeps the
    % lumen + some calcium without much bone.
    if ~isfield(opts, 'hu_lo_branch'),    opts.hu_lo_branch    = 600;  end
    if ~isfield(opts, 'hu_hi_branch'),    opts.hu_hi_branch    = 850;  end
    if ~isfield(opts, 'min_branch_vox'),  opts.min_branch_vox  = 100;  end
    % Drop branches bigger than this — almost certainly bone leak
    % through a partial-volume bridge. Renals/SMA/celiac top out
    % around 10 mL each.
    if ~isfield(opts, 'max_branch_mL'),   opts.max_branch_mL   = 30;   end
    if ~isfield(opts, 'geodesic_extend'), opts.geodesic_extend = 300;  end
    if ~isfield(opts, 'branch_grow_max'), opts.branch_grow_max = 80;   end
    if ~isfield(opts, 'verbose'),         opts.verbose         = true; end

    sz = size(D.vol);
    name2id = autoseg.class_name_to_id();
    AORTA   = name2id('aorta');
    ILIAC_L = name2id('iliac_artery_left');
    ILIAC_R = name2id('iliac_artery_right');
    KIDNEY_L = name2id('kidney_left');
    KIDNEY_R = name2id('kidney_right');

    voxel_mL = D.pixel_mm(1) * D.pixel_mm(2) * D.slice_spacing_mm / 1000;

    % Output label scheme (mirrors GUI palette indexing):
    %   1 = aorta
    %   2 = common iliac L (proximal half of extended iliac)
    %   3 = common iliac R
    %   4 = CFA L (distal half)
    %   5 = CFA R
    %   6 = renal artery L
    %   7 = renal artery R
    %   8 = celiac (anterior abdominal branch, upper)
    %   9 = SMA   (anterior abdominal branch, just below celiac)
    %   200+ = other branches detected
    label_out = zeros(sz, 'uint8');
    label_out(seg == AORTA)   = 1;
    label_out(seg == ILIAC_L) = 2;
    label_out(seg == ILIAC_R) = 3;

    info = struct();
    info.aorta_mL          = nnz(label_out == 1) * voxel_mL;
    info.iliac_L_mL_pre    = nnz(label_out == 2) * voxel_mL;
    info.iliac_R_mL_pre    = nnz(label_out == 3) * voxel_mL;
    info.branches          = struct('id', {}, 'name', {}, 'mL', {}, 'centroid', {});
    info.cfa_L_added_mL    = 0;
    info.cfa_R_added_mL    = 0;

    % --- Step 1: extend iliacs distally to CFA --------------------------
    extend_pool_full = (D.vol >= opts.hu_lo_extend) & ...
                       (D.vol <= opts.hu_hi_extend);
    for side = {'L', 'R'}
        side = side{1};
        if strcmp(side, 'L'), iliac_id = 2; else, iliac_id = 3; end
        seed_mask = (label_out == iliac_id);
        if ~any(seed_mask(:)); continue; end
        [rr, cc_, ss] = ind2sub(sz, find(seed_mask));
        margin = 8;
        max_s = min(sz(3), max(ss) + opts.geodesic_extend);
        r1 = max(1, min(rr) - margin);
        r2 = min(sz(1), max(rr) + margin);
        c1 = max(1, min(cc_) - margin);
        c2 = min(sz(2), max(cc_) + margin);
        s1 = max(1, min(ss) - margin);
        s2 = min(sz(3), max_s + margin);
        sub_seed = seed_mask(r1:r2, c1:c2, s1:s2);
        sub_pool = extend_pool_full(r1:r2, c1:c2, s1:s2);
        sub_block = label_out(r1:r2, c1:c2, s1:s2) ~= 0 & ...
                    label_out(r1:r2, c1:c2, s1:s2) ~= iliac_id;
        sub_pool = sub_pool & ~sub_block;
        sub_grown = imreconstruct(sub_seed, sub_pool | sub_seed, 6);
        added_local = sub_grown & ~sub_seed;
        if any(added_local(:))
            keep_full = false(sz);
            keep_full(r1:r2, c1:c2, s1:s2) = added_local;
            label_out(keep_full & label_out == 0) = iliac_id;
            added_mL = nnz(keep_full) * voxel_mL;
            if strcmp(side, 'L'), info.cfa_L_added_mL = added_mL;
            else,                 info.cfa_R_added_mL = added_mL; end
            if opts.verbose
                fprintf('[branches] %s iliac extended +%.1f mL\n', side, added_mL);
            end
        end
    end

    % --- Step 1b: split common iliac vs CFA -----------------------------
    % The extended iliac runs from the aortic bifurcation (proximal,
    % low Z) to the inguinal ligament / CFA (distal, high Z). Split at
    % the midpoint Z of each side's extended mask: voxels in the
    % proximal half = common iliac, voxels in the distal half = CFA.
    % This is anatomically approximate (the true iliac/CFA boundary is
    % at the inguinal ligament) but good enough for landmark labels;
    % the user can refine via right-click in the GUI.
    cfa_targets = struct('L', struct('iliac_id', 2, 'cfa_id', 4), ...
                         'R', struct('iliac_id', 3, 'cfa_id', 5));
    for side_name = fieldnames(cfa_targets).'
        sn = side_name{1};
        spec = cfa_targets.(sn);
        side_mask = (label_out == spec.iliac_id);
        if ~any(side_mask(:)); continue; end
        [~, ~, ss] = ind2sub(sz, find(side_mask));
        z_lo = min(ss); z_hi = max(ss);
        z_split = round(z_lo + 0.55 * (z_hi - z_lo));   % 55% caudal = CFA
        cfa_idx = side_mask;
        cfa_idx(:,:,1:z_split) = false;
        label_out(cfa_idx) = spec.cfa_id;
        if opts.verbose
            fprintf('[branches] %s common iliac/CFA split at Z=%d (range %d-%d)\n', ...
                sn, z_split, z_lo, z_hi);
        end
    end

    info.iliac_L_mL_post = nnz(label_out == 2) * voxel_mL;
    info.iliac_R_mL_post = nnz(label_out == 3) * voxel_mL;
    info.cfa_L_mL = nnz(label_out == 4) * voxel_mL;
    info.cfa_R_mL = nnz(label_out == 5) * voxel_mL;

    % --- Step 1c: bilateral renal artery detection ----------------------
    % Find renal arteries by searching laterally from the aorta at
    % the renal Z level. Doesn't depend on TS kidney classes (TS
    % --fast mode often misses one kidney, as on JohnDoe1 CT). Strategy:
    %   1. Use TS kidney centroids if available, else use aorta-axis
    %      heuristic: renal level ≈ 30-40% caudal from aorta cranial end
    %   2. At that Z band, find aorta centroid → search laterally
    %      (left and right) for HU 500-1000 voxels touching aorta
    %   3. Each side's largest such CC = the main renal artery
    aorta_now = (label_out == 1);
    if any(aorta_now(:))
        [arr_a, ~, ass_a] = ind2sub(sz, find(aorta_now));
        z_aorta_min = min(ass_a); z_aorta_max = max(ass_a);
        % Anatomic Z fractions (caudal from aorta cranial end):
        %   ~60% celiac (T12-L1, just below diaphragm)
        %   ~65% SMA    (L1)
        %   ~72% renals (L1-L2)
        %   ~85% IMA    (L3)
        %  100% bifurcation
        % Volume orientation assumes Z=1 is cranial (DICOM axial), so
        % higher Z = more caudal. For JohnDoe1 CT (aorta 77→848), the
        % renal level lands at Z ≈ 617.
        z_renal_center = round(z_aorta_min + 0.72 * (z_aorta_max - z_aorta_min));
        z_band_lo = max(1, z_renal_center - 50);
        z_band_hi = min(sz(3), z_renal_center + 50);

        % Use TS kidney centroid if present, else mirror contralateral
        % kidney (TS --fast occasionally drops one kidney; mirroring
        % about the aorta midline gives a usable anchor for the
        % renal-corridor search).
        kidney_centroids = struct();
        aorta_band_tmp = aorta_now;
        aorta_band_tmp(:,:,1:z_band_lo-1) = false;
        aorta_band_tmp(:,:,z_band_hi+1:end) = false;
        if any(aorta_band_tmp(:))
            [arr_t, acc_t, ass_t] = ind2sub(sz, find(aorta_band_tmp));
            aorta_mid_col = mean(acc_t);
        else
            aorta_mid_col = sz(2) / 2;
        end
        for renal_side = {'L', 'R'}
            sn = renal_side{1};
            if strcmp(sn, 'L'), kidney_id = KIDNEY_L; else, kidney_id = KIDNEY_R; end
            kidney = (seg == kidney_id);
            if any(kidney(:))
                [krr, kcc, kss] = ind2sub(sz, find(kidney));
                kidney_centroids.(sn) = [mean(krr), mean(kcc), mean(kss)];
            else
                kidney_centroids.(sn) = [];
            end
        end
        % Mirror missing side
        if isempty(kidney_centroids.L) && ~isempty(kidney_centroids.R)
            kr = kidney_centroids.R;
            kidney_centroids.L = [kr(1), 2*aorta_mid_col - kr(2), kr(3)];
            if opts.verbose
                fprintf('[branches] L kidney mirrored from R (TS missed L)\n');
            end
        elseif isempty(kidney_centroids.R) && ~isempty(kidney_centroids.L)
            kl = kidney_centroids.L;
            kidney_centroids.R = [kl(1), 2*aorta_mid_col - kl(2), kl(3)];
            if opts.verbose
                fprintf('[branches] R kidney mirrored from L (TS missed R)\n');
            end
        end

        for renal_side = {'L', 'R'}
            sn = renal_side{1};
            if strcmp(sn, 'L'), renal_label = 6; else, renal_label = 7; end
            kc = kidney_centroids.(sn);
            if isempty(kc); continue; end

            % Aorta band at the renal Z level
            aorta_band = aorta_now;
            aorta_band(:,:,1:z_band_lo-1) = false;
            aorta_band(:,:,z_band_hi+1:end) = false;
            if ~any(aorta_band(:)); continue; end
            [arr_b, acc_b, ass_b] = ind2sub(sz, find(aorta_band));
            aorta_centroid = [mean(arr_b), mean(acc_b), mean(ass_b)];

            % Corridor: capsule from aorta to kidney, dilated.
            % Build in a tight bbox to keep imdilate fast (full-volume
            % imdilate on a 320M-voxel grid takes minutes; bbox is ~1s).
            r_min = max(1, round(min([aorta_centroid(1), kc(1)])) - 24);
            r_max = min(sz(1), round(max([aorta_centroid(1), kc(1)])) + 24);
            c_min = max(1, round(min([aorta_centroid(2), kc(2)])) - 24);
            c_max = min(sz(2), round(max([aorta_centroid(2), kc(2)])) + 24);
            s_min = max(1, z_band_lo - 4);
            s_max = min(sz(3), z_band_hi + 4);
            sub_sz = [r_max - r_min + 1, c_max - c_min + 1, s_max - s_min + 1];
            sub_corridor = false(sub_sz);
            n_steps = 80;
            for tstep = 0:n_steps
                p = aorta_centroid + (kc - aorta_centroid) * (tstep / n_steps);
                pr = round(p(1)) - r_min + 1;
                pc = round(p(2)) - c_min + 1;
                ps = round(p(3)) - s_min + 1;
                if pr<1||pr>sub_sz(1)||pc<1||pc>sub_sz(2)||ps<1||ps>sub_sz(3); continue; end
                sub_corridor(pr, pc, ps) = true;
            end
            sub_corridor = imdilate(sub_corridor, strel('sphere', 20));
            corridor = false(sz);
            corridor(r_min:r_max, c_min:c_max, s_min:s_max) = sub_corridor;
            corridor(:,:,1:z_band_lo-1) = false;
            corridor(:,:,z_band_hi+1:end) = false;

            % Lower HU floor for aneurysmal cases where renal lumen
            % can drop to 350 due to slower flow / mural thrombus.
            renal_pool = (D.vol >= 350) & (D.vol <= 1000) & ...
                         label_out == 0 & corridor;
            if ~any(renal_pool(:))
                if opts.verbose
                    fprintf('[branches] %s renal: no candidate voxels in corridor\n', sn);
                end
                continue;
            end

            % BBox-crop the aorta neighborhood compute (full-volume
            % imdilate is too slow). Use the same corridor bbox.
            aorta_sub = aorta_now(r_min:r_max, c_min:c_max, s_min:s_max);
            nbhd_sub = imdilate(aorta_sub, strel('sphere', 4)) & ~aorta_sub;
            aorta_nbhd = false(sz);
            aorta_nbhd(r_min:r_max, c_min:c_max, s_min:s_max) = nbhd_sub;
            renal_seeds = renal_pool & aorta_nbhd;
            if ~any(renal_seeds(:))
                if opts.verbose
                    fprintf('[branches] %s renal: no seed at aorta surface\n', sn);
                end
                continue;
            end

            renal_grown = imreconstruct(renal_seeds, renal_pool | renal_seeds, 6);
            cc_r = bwconncomp(renal_grown, 6);
            if cc_r.NumObjects == 0; continue; end
            sizes_r = cellfun(@numel, cc_r.PixelIdxList);
            [~, idx_r] = max(sizes_r);
            renal_mask = false(sz);
            renal_mask(cc_r.PixelIdxList{idx_r}) = true;
            label_out(renal_mask & label_out == 0) = renal_label;
            n_renal = nnz(label_out == renal_label);
            if opts.verbose
                fprintf('[branches] %s renal artery: %d voxels (%.2f mL)\n', ...
                    sn, n_renal, n_renal * voxel_mL);
            end
        end
    end
    info.renal_L_mL = nnz(label_out == 6) * voxel_mL;
    info.renal_R_mL = nnz(label_out == 7) * voxel_mL;
    % Save centroids for the post-Step-2 anatomic reclassification.
    aorta_for_geom = aorta_now;

    % --- Step 2: detect branch vessels off the aorta --------------------
    aorta = (label_out == 1);
    if any(aorta(:))
        % BBox-crop the heavy morph ops to the aorta + margin (sphere(6)
        % imdilate on the full 320M-voxel volume took 3+ minutes and
        % made the run unusable; bbox brings it to a few seconds).
        [arr_full, acc_full, ass_full] = ind2sub(sz, find(aorta));
        margin_b = 16;
        rb1 = max(1, min(arr_full) - margin_b);
        rb2 = min(sz(1), max(arr_full) + margin_b);
        cb1 = max(1, min(acc_full) - margin_b);
        cb2 = min(sz(2), max(acc_full) + margin_b);
        sb1 = max(1, min(ass_full) - margin_b);
        sb2 = min(sz(3), max(ass_full) + margin_b);
        aorta_b = aorta(rb1:rb2, cb1:cb2, sb1:sb2);
        aorta_nbhd_b = imdilate(aorta_b, strel('sphere', 6)) & ~aorta_b;
        vol_b = D.vol(rb1:rb2, cb1:cb2, sb1:sb2);
        label_b = label_out(rb1:rb2, cb1:cb2, sb1:sb2);
        branch_pool_b = (vol_b >= opts.hu_lo_branch) & ...
                        (vol_b <= opts.hu_hi_branch) & ...
                        label_b == 0;
        branch_seeds_b = branch_pool_b & aorta_nbhd_b;
        if any(branch_seeds_b(:))
            branch_pool_open_b = imopen(branch_pool_b, strel('sphere', 1));
            seed_or_pool_b = branch_pool_open_b | branch_seeds_b;
            grown_b = imreconstruct(branch_seeds_b, seed_or_pool_b, 6);
            grown = false(sz);
            grown(rb1:rb2, cb1:cb2, sb1:sb2) = grown_b;

            % Per-component bounded grow: limit each CC to a sphere of
            % radius branch_grow_max (in voxels) from its centroid so a
            % single bone-leak doesn't claim half the volume.
            cc = bwconncomp(grown, 6);
            sizes = cellfun(@numel, cc.PixelIdxList);
            [sorted, idx] = sort(sizes, 'descend');
            next_id = 200;
            max_branch_vox = opts.max_branch_mL / voxel_mL;
            for k = 1:numel(sorted)
                if sorted(k) < opts.min_branch_vox; break; end
                if sorted(k) > max_branch_vox
                    % Almost certainly bone leak — skip but log
                    if opts.verbose
                        fprintf('[branches] CC #%d skipped (%.0f mL > %.0f mL — bone leak)\n', ...
                            k, sorted(k) * voxel_mL, opts.max_branch_mL);
                    end
                    continue;
                end
                px = cc.PixelIdxList{idx(k)};
                label_out(px) = next_id;
                [crr, ccc_, css] = ind2sub(sz, px);
                centroid = [mean(crr), mean(ccc_), mean(css)];
                info.branches(end+1) = struct( ...
                    'id', next_id, ...
                    'name', sprintf('branch_%d', next_id - 199), ...
                    'mL', sorted(k) * voxel_mL, ...
                    'centroid', centroid); %#ok<AGROW>
                if opts.verbose
                    fprintf('[branches] CC #%d → label %d (%.1f mL) centroid [%d %d %d]\n', ...
                        k, next_id, sorted(k) * voxel_mL, ...
                        round(centroid(1)), round(centroid(2)), round(centroid(3)));
                end
                next_id = next_id + 1;
                if next_id > 250; break; end
            end
        end
    end

    % --- Step 3: anatomic reclassification of detected branches ---------
    % Walk the detected branches list and assign anatomic labels:
    %   - Renal L: largest branch centroid in patient-LEFT (col >
    %     aorta_col + 15) of the abdominal aorta Z band, > 1 mL
    %   - Renal R: largest branch centroid in patient-RIGHT (col <
    %     aorta_col - 15) of the abdominal aorta Z band, > 1 mL
    %   - Celiac:  anterior branch (row < aorta_row), upper abdominal
    %   - SMA:     anterior branch, just below celiac
    if any(aorta_for_geom(:)) && ~isempty(info.branches)
        [arr_a, acc_a, ass_a] = ind2sub(sz, find(aorta_for_geom));
        z_aorta_min = min(ass_a); z_aorta_max = max(ass_a);
        % Anatomic Z bands (caudal fractions of aorta from cranial end):
        %   celiac: 55-65% caudal (T12-L1)
        %   SMA:    60-70%       (L1)
        %   renal:  65-80%       (L1-L2)
        z_renal_lo  = z_aorta_min + 0.65 * (z_aorta_max - z_aorta_min);
        z_renal_hi  = z_aorta_min + 0.80 * (z_aorta_max - z_aorta_min);
        z_celiac_lo = z_aorta_min + 0.55 * (z_aorta_max - z_aorta_min);
        z_celiac_hi = z_aorta_min + 0.65 * (z_aorta_max - z_aorta_min);
        z_sma_lo    = z_aorta_min + 0.60 * (z_aorta_max - z_aorta_min);
        z_sma_hi    = z_aorta_min + 0.70 * (z_aorta_max - z_aorta_min);

        renal_L_cand = []; renal_L_size = 0;
        renal_R_cand = []; renal_R_size = 0;
        celiac_cand  = []; celiac_size  = 0;
        sma_cand     = []; sma_size     = 0;
        for bi = 1:numel(info.branches)
            b = info.branches(bi);
            cz = b.centroid(3);
            cr = b.centroid(1);
            cc_b = b.centroid(2);
            % Aorta center at this Z slice
            sl_aorta = aorta_for_geom(:,:,round(cz));
            if ~any(sl_aorta(:)); continue; end
            [rrA, ccA] = find(sl_aorta);
            aorta_r_z = mean(rrA);
            aorta_c_z = mean(ccA);

            % Lateral classification (renals)
            if cz >= z_renal_lo && cz <= z_renal_hi && b.mL >= 1.0
                lateral_offset = cc_b - aorta_c_z;  % +ve = patient-left, -ve = patient-right
                if lateral_offset > 15 && b.mL > renal_L_size
                    renal_L_cand = b; renal_L_size = b.mL;
                elseif lateral_offset < -15 && b.mL > renal_R_size
                    renal_R_cand = b; renal_R_size = b.mL;
                end
            end
            % Anterior classification (celiac/SMA)
            antoff = aorta_r_z - cr;  % +ve = anterior of aorta
            if antoff > 15 && b.mL >= 0.5
                if cz >= z_celiac_lo && cz <= z_celiac_hi && b.mL > celiac_size
                    celiac_cand = b; celiac_size = b.mL;
                end
                if cz >= z_sma_lo && cz <= z_sma_hi && b.mL > sma_size && ...
                        (isempty(celiac_cand) || cz > celiac_cand.centroid(3) + 10)
                    sma_cand = b; sma_size = b.mL;
                end
            end
        end

        if ~isempty(renal_L_cand)
            label_out(label_out == renal_L_cand.id) = 6;
            if opts.verbose
                fprintf('[anatomic] renal L = branch_%d (%.1f mL)\n', ...
                    renal_L_cand.id - 199, renal_L_cand.mL);
            end
        end
        if ~isempty(renal_R_cand)
            label_out(label_out == renal_R_cand.id) = 7;
            if opts.verbose
                fprintf('[anatomic] renal R = branch_%d (%.1f mL)\n', ...
                    renal_R_cand.id - 199, renal_R_cand.mL);
            end
        end
        if ~isempty(celiac_cand)
            label_out(label_out == celiac_cand.id) = 8;
            if opts.verbose
                fprintf('[anatomic] celiac = branch_%d (%.1f mL)\n', ...
                    celiac_cand.id - 199, celiac_cand.mL);
            end
        end
        if ~isempty(sma_cand) && (isempty(celiac_cand) || sma_cand.id ~= celiac_cand.id)
            label_out(label_out == sma_cand.id) = 9;
            if opts.verbose
                fprintf('[anatomic] SMA = branch_%d (%.1f mL)\n', ...
                    sma_cand.id - 199, sma_cand.mL);
            end
        end
        info.renal_L_mL = nnz(label_out == 6) * voxel_mL;
        info.renal_R_mL = nnz(label_out == 7) * voxel_mL;
        info.celiac_mL  = nnz(label_out == 8) * voxel_mL;
        info.sma_mL     = nnz(label_out == 9) * voxel_mL;

        % --- Renal fallback: when the corridor-walk initial detection
        % is very short (< 500 vox), do a targeted lateral scan in
        % the renal z-band. The renal arteries arise laterally from
        % the aorta at L1-L2 (~70% caudal in the aorta) — find HU
        % 250-800 voxels touching the aorta surface on each side.
        renal_min_target = 500;   % vox threshold below which we retry
        % Compute renal z-band from aorta extent
        z_aorta_min = NaN; z_aorta_max = NaN;
        zp_a = squeeze(any(any(label_out == 1, 1), 2));
        if any(zp_a)
            z_idx = find(zp_a);
            z_aorta_min = z_idx(1); z_aorta_max = z_idx(end);
            z_renal_lo_fb = round(z_aorta_min + 0.62 * (z_aorta_max - z_aorta_min));
            z_renal_hi_fb = round(z_aorta_min + 0.82 * (z_aorta_max - z_aorta_min));
        else
            z_renal_lo_fb = NaN; z_renal_hi_fb = NaN;
        end
        for renal_side_fb = {'L', 'R'}
            sn_fb = renal_side_fb{1};
            cur_label = 6 + double(strcmp(sn_fb, 'R'));    % L=6, R=7
            n_cur = nnz(label_out == cur_label);
            if n_cur >= renal_min_target || isnan(z_renal_lo_fb); continue; end
            if opts.verbose
                fprintf('[anatomic] renal %s only %d vox — running lateral fallback\n', sn_fb, n_cur);
            end
            cand = false(sz);
            aorta_now2 = (label_out == 1);
            % Build a thin aorta-surface neighborhood. Renal candidates
            % MUST touch this neighborhood to be a real off-aorta vessel.
            % The full-volume imdilate is expensive — restrict to the
            % renal z-band slab.
            slab_lo = max(1, z_renal_lo_fb - 5);
            slab_hi = min(sz(3), z_renal_hi_fb + 5);
            aorta_slab = aorta_now2(:, :, slab_lo:slab_hi);
            aorta_nbhd_slab = imdilate(aorta_slab, strel('sphere', 3)) & ~aorta_slab;
            aorta_nbhd = false(sz);
            aorta_nbhd(:, :, slab_lo:slab_hi) = aorta_nbhd_slab;
            for z = z_renal_lo_fb:z_renal_hi_fb
                if ~any(aorta_now2(:, :, z), 'all'); continue; end
                slc_hu = D.vol(:, :, z);
                [rrA, ccA] = find(aorta_now2(:, :, z));
                aorta_r_z = mean(rrA);
                aorta_c_z = mean(ccA);
                bw = (slc_hu >= 300) & (slc_hu <= 900);
                bw(aorta_now2(:, :, z)) = false;
                bw(label_out(:, :, z) > 0) = false;
                [yy, xx] = ndgrid(1:sz(1), 1:sz(2));
                lateral_off = xx - aorta_c_z;
                if strcmp(sn_fb, 'L')
                    side_mask = lateral_off > 8;
                else
                    side_mask = lateral_off < -8;
                end
                % Stay close to aorta vertical level; renals project
                % laterally with only a few-mm anteroposterior offset.
                in_band = abs(yy - aorta_r_z) < 18;
                bw = bw & side_mask & in_band;
                cand(:, :, z) = bw;
            end
            % Keep only CCs that TOUCH the aorta surface neighborhood
            cc_r = bwconncomp(cand, 26);
            keep_idx = [];
            sizes_r = [];
            for ci = 1:cc_r.NumObjects
                idxs = cc_r.PixelIdxList{ci};
                if any(aorta_nbhd(idxs))
                    keep_idx(end+1) = ci; %#ok<AGROW>
                    sizes_r(end+1) = numel(idxs); %#ok<AGROW>
                end
            end
            if isempty(keep_idx); continue; end
            [~, ksub] = max(sizes_r);
            kk = keep_idx(ksub);
            % Clamp upper bound — anatomic renal artery is 1-4 mL.
            % Anything >10 mL on a CTA at HU 300+ is a vessel mass
            % (kidney parenchyma + arteries fused). Reject and keep
            % the original 387-vox short stub.
            if sizes_r(ksub) >= 200 && sizes_r(ksub) > n_cur && ...
                    sizes_r(ksub) * voxel_mL <= 15
                label_out(label_out == cur_label) = 0;
                label_out(cc_r.PixelIdxList{kk}) = cur_label;
                if opts.verbose
                    fprintf('[anatomic] renal %s fallback: %d vox (%.2f mL)\n', ...
                        sn_fb, sizes_r(ksub), sizes_r(ksub) * voxel_mL);
                end
            elseif sizes_r(ksub) * voxel_mL > 15
                if opts.verbose
                    fprintf('[anatomic] renal %s fallback rejected (%.1f mL > 15 mL — likely fused with kidney)\n', ...
                        sn_fb, sizes_r(ksub) * voxel_mL);
                end
            end
        end

        % --- SMA fallback: when the primary branch-loop misses the SMA
        % (typical when it's small or fused with the aorta in --fast
        % mode), do a targeted HU scan in the band immediately below
        % the detected celiac. Picks up SMA candidates the main loop
        % rejected because they had mL < 0.5 or got fused.
        if info.sma_mL < 0.1 && info.celiac_mL > 0
            celiac_z = NaN;
            zp_c = squeeze(any(any(label_out == 8, 1), 2));
            if any(zp_c)
                z_c = find(zp_c);
                celiac_z = max(z_c);   % the most-caudal celiac slice
            end
            if ~isnan(celiac_z)
                z_search_lo = celiac_z + round(5 / D.slice_spacing_mm);
                z_search_hi = celiac_z + round(40 / D.slice_spacing_mm);
                z_search_hi = min(z_search_hi, sz(3));
                aorta_now = (label_out == 1);
                % Look for HU 200-800 voxels anterior to the aorta in this z-band
                cand = false(sz);
                for z = z_search_lo:z_search_hi
                    if ~any(aorta_now(:, :, z), 'all'); continue; end
                    slc_hu = D.vol(:, :, z);
                    [rrA, ccA] = find(aorta_now(:, :, z));
                    aorta_r_z = mean(rrA);
                    aorta_c_z = mean(ccA);
                    bw = (slc_hu >= 200) & (slc_hu <= 800);
                    bw(aorta_now(:, :, z)) = false;   % don't re-detect aorta
                    bw(label_out(:, :, z) > 0) = false; % skip already-labeled
                    % anterior + central laterally
                    [yy, xx] = ndgrid(1:sz(1), 1:sz(2));
                    anterior = yy < aorta_r_z - 5;
                    central  = abs(xx - aorta_c_z) < 30;
                    bw = bw & anterior & central;
                    cand(:, :, z) = bw;
                end
                cc_s = bwconncomp(cand, 26);
                if cc_s.NumObjects > 0
                    sizes_s = cellfun(@numel, cc_s.PixelIdxList);
                    [~, ks] = max(sizes_s);
                    if sizes_s(ks) >= 50   % at least 50 vox
                        label_out(cc_s.PixelIdxList{ks}) = 9;
                        info.sma_mL = sizes_s(ks) * voxel_mL;
                        if opts.verbose
                            fprintf('[anatomic] SMA fallback found %d vox (%.2f mL) below celiac.\n', ...
                                sizes_s(ks), info.sma_mL);
                        end
                    end
                end
            end
        end
    end

    mask_out = label_out > 0;
    info.total_mL = nnz(mask_out) * voxel_mL;
end
