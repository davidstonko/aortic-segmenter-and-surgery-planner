function [mask_out, label_out, info] = extend_to_cfa(D, mask_in, label_in, opts)
%AUTOSEG.EXTEND_TO_CFA  Extend each PHYSICAL side's iliac/CFA chain
%   inferiorly through the external iliac → common femoral artery, slice
%   by slice, until the FOV bottom, contrast dropout, or a wandering
%   trajectory.
%
%   [MASK_OUT, LABEL_OUT, INFO] = autoseg.extend_to_cfa(D, MASK_IN, LABEL_IN)
%   [MASK_OUT, LABEL_OUT, INFO] = autoseg.extend_to_cfa(D, MASK_IN, LABEL_IN, OPTS)
%
%   Sides are detected ANATOMICALLY from the aorta bifurcation, not from
%   the iliac/CFA labels — `extend_and_detect_branches` can leave the
%   "L iliac" label scattered across both physical sides when the TS
%   seed had label leakage near the bifurcation. To get a clean per-side
%   continuous chain that reaches the femoral level we:
%
%     1. Find the aortic bifurcation z = last slice with label 1.
%     2. Take the aorta XY centroid at that slice → x_aorta defines the
%        L/R split for everything below.
%     3. For each side (L: x > x_aorta, R: x < x_aorta):
%          a. Restrict the existing mask below z_bifurc to that side.
%          b. Walk from the most-caudal slice of that side down to the
%             FOV bottom, slice by slice.
%          c. The walker stays strictly on its own side of x_aorta — no
%             bridge can paint voxels across the midline.
%          d. New voxels are assigned label 4 (L) or 5 (R).
%     4. Optionally re-label all label-4/5 voxels above by their actual
%        physical side, so the labels match anatomy downstream.
%
%   OPTS:
%       .hu_lo               default 150
%       .hu_hi               default 1000
%       .max_jump_mm         default 5
%       .min_R_mm            default 1.5
%       .max_R_mm            default 10
%       .roundness_min       default 0.30
%       .k_dropout           default 10
%       .max_reacquire       default 6
%       .relabel_existing    default true — re-assign existing label 4/5
%                            voxels to the correct side based on x_aorta
%       .verbose             default true

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D       (1,1) struct
        mask_in logical
        label_in uint8
        opts    (1,1) struct = struct()
    end
    if ~isfield(opts, 'hu_lo');             opts.hu_lo = 150;             end
    % Widen the upper HU bound so peak arterial contrast (HU 1000-1500
    % in the L CFA on JohnDoe1 due to bright iodinated bolus + small lumen)
    % isn't excluded as bone. Cortical bone is ≥ 1500 HU in this scan,
    % so a 1400 cap still rejects bone while keeping all real lumen.
    if ~isfield(opts, 'hu_hi');             opts.hu_hi = 1400;            end
    % The walker's strict-mode jump cap is `max_jump_mm * 4` (in voxels).
    % 8 mm/slice → 32-vox cap, which covers the L iliac's natural lateral
    % drift between the bifurcation and the inguinal region (15-25 mm of
    % XY shift in 5-10 mm of z). Still tight enough to reject EIA →
    % hypogastric jumps (> 40 mm of lateral offset).
    if ~isfield(opts, 'max_jump_mm');       opts.max_jump_mm = 8;         end
    % Faint contrast in distal EIA / CFA can be R = 1.0-1.5 vox (a few
    % voxels at HU 250 in arterial phase, especially in older patients
    % with slow flow). Drop the minimum so the walker tracks them.
    if ~isfield(opts, 'min_R_mm');          opts.min_R_mm = 0.8;          end
    if ~isfield(opts, 'max_R_mm');          opts.max_R_mm = 10;           end
    % Faint contrast CCs are often non-circular due to partial-volume
    % effects; loosen the roundness threshold.
    if ~isfield(opts, 'roundness_min');     opts.roundness_min = 0.20;    end
    if ~isfield(opts, 'k_dropout');         opts.k_dropout = 14;          end
    if ~isfield(opts, 'max_reacquire');     opts.max_reacquire = 8;       end
    if ~isfield(opts, 'relabel_existing');  opts.relabel_existing = true; end
    if ~isfield(opts, 'verbose');           opts.verbose = true;          end
    % CFA seed overrides — when set to a [y, x, z] voxel triplet, the
    % topological CFA detector is bypassed for that side and the
    % walker uses the user-supplied seed instead. Use this from the
    % GUI after an SE(3) FAIL: surface the FAIL, ask the user to click
    % the correct CFA on the affected side, then re-run extend_to_cfa
    % with the click forwarded here.
    if ~isfield(opts, 'cfa_seed_override_L'); opts.cfa_seed_override_L = []; end
    if ~isfield(opts, 'cfa_seed_override_R'); opts.cfa_seed_override_R = []; end

    sz = size(D.vol);
    if ~isequal(size(mask_in), sz);  error('mask_in size mismatch'); end
    if ~isequal(size(label_in), sz); error('label_in size mismatch'); end

    mask_out  = mask_in;
    label_out = label_in;

    pix = D.pixel_mm(1);
    max_jump_vox = opts.max_jump_mm / pix;
    min_R_vox    = opts.min_R_mm / pix;
    max_R_vox    = opts.max_R_mm / pix;

    % --- Anatomic side split from aorta bifurcation -------------------
    aorta = (label_in == 1);
    if ~any(aorta(:))
        info = struct('skipped', 'no aorta label'); return;
    end
    aorta_zp = squeeze(any(any(aorta, 1), 2));
    z_bifurc = find(aorta_zp, 1, 'last');
    slc_a = aorta(:, :, z_bifurc);
    [~, xa] = find(slc_a);
    x_aorta = mean(xa);
    if opts.verbose
        fprintf('[extend_to_cfa] aorta bifurcation z=%d, midline x=%.0f\n', z_bifurc, x_aorta);
    end

    % --- Optionally re-label existing 4/5 voxels by physical side -----
    if opts.relabel_existing
        [yy, xx, zz] = ind2sub(sz, find(label_out == 4 | label_out == 5));
        if ~isempty(yy)
            new_lbl = uint8(zeros(size(yy)));
            new_lbl(xx > x_aorta) = 4;   % patient-LEFT = high x
            new_lbl(xx < x_aorta) = 5;   % patient-RIGHT = low x
            % Voxels right on x_aorta keep their existing label
            old_lbl = label_out(sub2ind(sz, yy, xx, zz));
            on_mid  = new_lbl == 0;
            new_lbl(on_mid) = old_lbl(on_mid);
            label_out(sub2ind(sz, yy, xx, zz)) = new_lbl;
        end
        % Also re-label iliacs (2, 3) below the bifurcation
        [yy, xx, zz] = ind2sub(sz, find((label_out == 2 | label_out == 3) & ...
            permute(repmat(reshape(1:sz(3), 1, 1, []) > z_bifurc, [sz(1), sz(2), 1]), [1 2 3])));
        if ~isempty(yy)
            new_lbl = uint8(zeros(size(yy)));
            new_lbl(xx > x_aorta) = 2;   % L iliac = high x
            new_lbl(xx < x_aorta) = 3;   % R iliac = low x
            old_lbl = label_out(sub2ind(sz, yy, xx, zz));
            on_mid = new_lbl == 0;
            new_lbl(on_mid) = old_lbl(on_mid);
            label_out(sub2ind(sz, yy, xx, zz)) = new_lbl;
        end
    end

    info = struct('z_bifurc', z_bifurc, 'x_aorta', x_aorta, ...
                  'L', struct(), 'R', struct());

    % --- Per-side walk -----------------------------------------------
    % Patient-LEFT: x > x_aorta (high x). Patient-RIGHT: x < x_aorta.
    sides = struct( ...
        'L', struct('cfa_label', 4, 'sign', +1), ...
        'R', struct('cfa_label', 5, 'sign', -1));

    % Compute BOTH walker variants per side, then pick the (L-path, R-path)
    % combination that minimizes cross-vessel asymmetry (SE(3) rules).
    side_results = struct();

    for side_name = {'L', 'R'}
        sn = side_name{1};
        spec = sides.(sn);

        % Build this side's allowed XY mask: strictly on this side
        % of x_aorta (with a 1-vox no-mans-land at midline).
        on_side_xy = false(sz(1), sz(2));
        if spec.sign > 0
            xb_lo = max(1, ceil(x_aorta) + 1);
            xb_hi = sz(2);
        else
            xb_lo = 1;
            xb_hi = max(1, floor(x_aorta) - 1);
        end
        on_side_xy(:, xb_lo:xb_hi) = true;

        % Find this side's most-caudal mask voxel BELOW the bifurcation
        side_mask = mask_out & repmat(on_side_xy, [1, 1, sz(3)]);
        side_mask(:, :, 1:z_bifurc) = false;
        side_zp = squeeze(any(any(side_mask, 1), 2));
        z_bot = find(side_zp, 1, 'last');
        if isempty(z_bot)
            info.(sn) = struct('side', sn, 'starting_z', NaN, 'last_z', NaN, ...
                'added_slices', 0, 'added_voxels', 0, 'reacquired_at', [], ...
                'x_band', [xb_lo, xb_hi], 'note', 'no mask on this side');
            if opts.verbose
                fprintf('[extend_to_cfa] %s side: no mask present — skipping\n', sn);
            end
            continue;
        end

        % --- CFA-first anchor with fallback to down-walk ----------------
        % Preferred: detect the CFA at the FOV bottom and walk UP through
        % CFA → EIA → CIA → aortic bifurcation. Walking up is anatomically
        % unambiguous because the CFA has no proximal branches that could
        % steer the walker into a wrong vessel.
        %
        % Fallback: if the CFA detector flags low confidence (e.g. on
        % patients where the CFA + femoral vein both light up brightly
        % and are indistinguishable on roundness/HU), do BOTH walks
        % (CFA-up + legacy iliac-terminus-down) and keep the one whose
        % distal endpoint sits more LATERALLY from the patient midline.
        % Lateral position is the most reliable CFA anatomic discriminator
        % (the artery sits more lateral than the femoral vein in the
        % femoral triangle).
        % User-supplied CFA seed (set via opts.cfa_seed_override_L/_R
        % from the GUI's manual-click flow). Bypasses the topological
        % detector and the round-HU fallback. The override voxel is
        % treated as a high-confidence candidate.
        override_field = sprintf('cfa_seed_override_%s', sn);
        override_voxel = opts.(override_field);
        if ~isempty(override_voxel)
            if numel(override_voxel) ~= 3
                error('extend_to_cfa:bad_override', ...
                    '%s must be a [y, x, z] triplet (got %d elements).', ...
                    override_field, numel(override_voxel));
            end
            ov = round(override_voxel(:)');
            cfa_seed = struct( ...
                'ok', true, ...
                'voxel', ov, ...
                'candidates', struct('y', ov(1), 'x', ov(2), 'z', ov(3)), ...
                'reason', sprintf('User-supplied %s CFA seed (manual click): (y=%d x=%d z=%d).', ...
                    sn, ov(1), ov(2), ov(3)));
        else
            % Primary detector: patient-invariant topological. Anchors on
            % the most-caudal endpoint of the aorta-connected contrast tree,
            % ranked by geodesic distance — robust to BMI, rotation, and
            % scanner differences.
            aorta_mask_lbl = (label_in == 1);
            cfa_seed = autoseg.detect_cfa_seed_topological( ...
                D, sn, aorta_mask_lbl, x_aorta);
            % Fallback: if the topological detector fails (e.g. no aorta-
            % connected tree, or no vessel-sized CC), fall back to the
            % round-HU detector for this side.
            if ~cfa_seed.ok && isempty(cfa_seed.candidates)
                cfa_seed = autoseg.detect_cfa_seed(D, sn, x_aorta);
            end
        end

        % Always try the CFA-up walk if a seed was found (even if flagged
        % as ambiguous — the SE(3) cross-vessel checker decides afterwards)
        m_a = mask_out; L_a = label_out; info_a = struct('skipped', true);
        m_b = mask_out; L_b = label_out; info_b = struct('skipped', true);
        if ~isempty(cfa_seed.candidates) && cfa_seed.candidates(1).z > z_bifurc
            cand = cfa_seed.candidates(1);
            seed_vox_a = [round(cand.y), round(cand.x), cand.z];
            [m_a, L_a, info_a] = walk_up_from_cfa( ...
                D, mask_out, label_out, spec.cfa_label, on_side_xy, ...
                seed_vox_a, z_bifurc + 2, ...
                max_jump_vox, min_R_vox, max_R_vox, opts, sn);
            info_a.cfa_seed = seed_vox_a;
        end
        % Legacy iliac-terminus downward walk
        [m_b, L_b, info_b] = walk_side(D, mask_out, label_out, ...
            spec.cfa_label, on_side_xy, z_bot, ...
            max_jump_vox, min_R_vox, max_R_vox, opts, sn);
        info_b.cfa_seed = [];

        % Store both candidates for cross-vessel arbitration after both
        % sides are computed.
        side_results.(sn) = struct( ...
            'up',   struct('mask', m_a, 'label', L_a, 'info', info_a), ...
            'down', struct('mask', m_b, 'label', L_b, 'info', info_b), ...
            'cfa_seed_reason', cfa_seed.reason, ...
            'on_side_xy', on_side_xy);
        % Provisional pick (will be overwritten by cross-vessel arbitration)
        side_info = info_b;
        side_info.cfa_seed_reason = cfa_seed.reason;
        side_info.manual_click_needed = ~cfa_seed.ok;
        side_info.x_band = [xb_lo, xb_hi];
        info.(sn) = side_info;
    end

    % --- Cross-vessel arbitration ----------------------------------
    % Try all 4 (L-path, R-path) combinations; pick the one with the
    % best bilateral symmetry per the SE(3) cross-vessel rules. The
    % artery sits in a bilaterally-symmetric anatomic position — when
    % both walkers find the artery, the distal endpoints are roughly
    % mirror-images. When one walker drifts into a hypogastric / gluteal
    % branch, the asymmetry score blows up.
    %
    % If one side has no mask at all (e.g. unilateral synthetic test, or
    % a real case where the segmentation found one iliac only), the
    % loop above will have set info.(sn) but never populated
    % side_results.(sn). In that case skip cross-vessel arbitration and
    % just emit whatever single-side mask exists.
    have_L = isfield(side_results, 'L');
    have_R = isfield(side_results, 'R');
    if have_L && have_R
        [best_combo, best_diag] = pick_best_combination(side_results, ...
            x_aorta, abs(D.pixel_mm(1)));
        L_choice = side_results.L.(best_combo{1});
        R_choice = side_results.R.(best_combo{2});
    elseif have_L
        % Single-side L: prefer the up-walker (CFA-anchored) when it
        % actually ran; fall back to the down-walker otherwise.
        if isfield(side_results.L, 'up') && ~walker_skipped(side_results.L.up)
            L_choice = side_results.L.up;
            best_combo = {'up', 'down'};
        else
            L_choice = side_results.L.down;
            best_combo = {'down', 'down'};
        end
        R_choice = struct('mask', false(sz), 'label', label_out, ...
                          'info', struct('skipped', true, 'side', 'R'));
        best_diag = struct('combo_idx', 0, 'asymmetry_penalty', NaN, ...
                           'dy_mm', NaN, 'L_lat', NaN, 'R_lat', NaN, ...
                           'lat_asym', NaN);
    elseif have_R
        if isfield(side_results.R, 'up') && ~walker_skipped(side_results.R.up)
            R_choice = side_results.R.up;
            best_combo = {'down', 'up'};
        else
            R_choice = side_results.R.down;
            best_combo = {'down', 'down'};
        end
        L_choice = struct('mask', false(sz), 'label', label_out, ...
                          'info', struct('skipped', true, 'side', 'L'));
        best_diag = struct('combo_idx', 0, 'asymmetry_penalty', NaN, ...
                           'dy_mm', NaN, 'L_lat', NaN, 'R_lat', NaN, ...
                           'lat_asym', NaN);
    else
        % No mask on either side — nothing to do.
        return;
    end
    % Voxels newly painted by each walker (relative to the input mask).
    % We stamp ONLY the new voxels with the side label; the existing
    % mask was already relabeled per physical side above, so stamping
    % the full L_choice.mask / R_choice.mask would clobber that pass
    % because the two chosen masks share their input voxels.
    new_L = L_choice.mask & ~mask_in;
    new_R = R_choice.mask & ~mask_in;
    mask_out = mask_out | L_choice.mask | R_choice.mask;
    label_out(new_L) = 4;
    label_out(new_R) = 5;

    % NOTE: A previous version of this function drew straight-line
    % "bridges" between disconnected CCs (e.g. aorta-CC to iliac-CC)
    % to ensure the downstream centerline graph could path proximal →
    % CFA. That strategy is REMOVED: on a contrast-enhanced arterial-
    % phase CTA the aorta and iliacs are well opacified — there's no
    % need to bridge through tissue. The bridges drew anatomically
    % impossible straight tubes that rendered as obvious artifacts.
    % If the segmentation produces disconnected CCs, the right
    % response is to grow the mask through the actual contrast HU
    % (see HU-based reconnect upstream of TS in subsequent passes),
    % not to forge a connection.

    info.L = L_choice.info;
    info.L.chosen_path = best_combo{1};
    if have_L
        info.L.cfa_seed_reason = side_results.L.cfa_seed_reason;
    end
    info.L.cross_vessel_score = best_diag.L_lat - best_diag.asymmetry_penalty;
    info.R = R_choice.info;
    info.R.chosen_path = best_combo{2};
    if have_R
        info.R.cfa_seed_reason = side_results.R.cfa_seed_reason;
    end
    info.R.cross_vessel_score = best_diag.R_lat - best_diag.asymmetry_penalty;

    if opts.verbose
        fprintf('[extend_to_cfa] cross-vessel arbitration: L=%s, R=%s (asymmetry=%.0f%%, picked combo %d/4)\n', ...
            best_combo{1}, best_combo{2}, 100*best_diag.asymmetry_penalty, best_diag.combo_idx);
    end

    % --- SE(3) cross-vessel rule check on the chosen pair -------------
    % Extracts a coarse per-slice-centroid centerline for each chosen
    % side mask and runs the anatomic plausibility rules. The report
    % is attached to info so the GUI can surface failures (and offer a
    % user-click CFA path to re-anchor a side whose rules are violated).
    Pv_L = mask_to_centerline_mm(label_out == 4 | label_out == 2, z_bifurc, D);
    Pv_R = mask_to_centerline_mm(label_out == 5 | label_out == 3, z_bifurc, D);
    % Prepend the aortic bifurcation centroid to BOTH centerlines as
    % their shared proximal node. Without this, the L iliac and R iliac
    % proximal-most centroids are 30-50 mm apart (natural post-bifurcation
    % divergence) — the SE(3) "shared bifurcation" rule would flag this
    % as a failure even when both walkers are anatomically correct.
    pix_mm = abs(D.pixel_mm(1));
    ssp_mm = abs(D.slice_spacing_mm);
    [yy_bif, ~] = find(aorta(:, :, z_bifurc));
    if isempty(yy_bif); yy_bif = sz(1) / 2; end
    aorta_bif_xyz_mm = [x_aorta * pix_mm, mean(yy_bif) * pix_mm, z_bifurc * ssp_mm];
    if size(Pv_L, 1) >= 3 && size(Pv_R, 1) >= 3
        Pv_L_xv = [aorta_bif_xyz_mm; Pv_L];
        Pv_R_xv = [aorta_bif_xyz_mm; Pv_R];
        % Aorta centerline ending at the bifurcation — feed it to the
        % cross-vessel check so the bilateral take-off-asymmetry block
        % uses the actual aortic tangent (rather than the symmetric
        % -(t_R + t_L) fallback that always reports zero asymmetry).
        Pv_aorta_mm = aorta_mask_to_centerline_mm(aorta, z_bifurc, D);
        info.se3_check = autoseg.se3_cross_vessel_check( ...
            Pv_R_xv, Pv_L_xv, struct(), Pv_aorta_mm);
        % Per-centerline SE(3) audit (one report per side). Catches
        % artifacts that the cross-vessel symmetry rules miss: tight
        % κ spikes from graph-shortest-path corkscrews, helical torsion,
        % step-discontinuous tangents, doubling-back, and lumen-caliber
        % jumps where the centerline switched vessels.
        %
        % NOTE: this check operates on the coarse per-slice-centroid
        % centerline, which can hop between connected components when
        % the mask has bone-leak contamination next to the real vessel.
        % The smoothing inside se3_per_centerline_check suppresses
        % isolated single-slice hops, but a noisy mask will still
        % produce WARNs. Treat WARN here as advisory; FAIL means the
        % centerline has structural problems that even the smoothing
        % can't hide. The same check should be re-run on the post-
        % centerline-solver output, where its thresholds are diagnostic.
        info.se3_per_L = autoseg.se3_per_centerline_check(Pv_L, 'L');
        info.se3_per_R = autoseg.se3_per_centerline_check(Pv_R, 'R');
        if opts.verbose
            fprintf('[extend_to_cfa] SE(3) cross-vessel: %s | per-side L: %s, R: %s\n', ...
                ternary(info.se3_check.passed, 'PASS', 'FAIL'), ...
                ternary(info.se3_per_L.passed, 'PASS', 'FAIL'), ...
                ternary(info.se3_per_R.passed, 'PASS', 'FAIL'));
            if ~info.se3_check.passed
                fprintf('%s\n', info.se3_check.summary_text);
            end
            if ~info.se3_per_L.passed
                fprintf('%s\n', info.se3_per_L.summary_text);
            end
            if ~info.se3_per_R.passed
                fprintf('%s\n', info.se3_per_R.summary_text);
            end
        end
    else
        info.se3_check = struct('passed', false, 'blocks', {{}}, ...
            'summary_text', 'SE(3) check skipped — one or both chosen masks have < 3 axial slices.');
        info.se3_per_L = info.se3_check;
        info.se3_per_R = info.se3_check;
    end
end

function P_mm = mask_to_centerline_mm(mask3d, z_bif, D)
%MASK_TO_CENTERLINE_MM  Coarse centerline as per-slice centroid, after
%   isolating the LARGEST 3D-connected-component of the side mask.
%   Restricted to slices below the aortic bifurcation (z > z_bif).
%   Returns (:,3) of [X_mm, Y_mm, Z_mm] in patient coords (lateral,
%   anterior-posterior, axial), proximal-first.
%
%   Pipeline:
%     1. Take the largest 3D-CC of `mask3d` below the bifurcation.
%        This drops disconnected fragments (bone leaks, accidentally-
%        relabeled venous CCs, label flicker between artery/vein)
%        before centroid extraction. The single 3D-CC of a continuous
%        vessel chain is exactly what we want to skeletonize.
%     2. For each slice, take the size-weighted mean of all vessel-
%        sized CCs (≤ 400 mm²) within `merge_radius_mm` of the
%        previous slice's centroid. This smooths the centroid when
%        the vessel cross-section briefly splits into two adjacent
%        CCs (e.g. label leakage at the bifurcation).
%     3. Reject slices whose merged centroid is > `max_hop_mm` from
%        the previous slice's centroid (catastrophic dropout).
    sz = size(mask3d);

    % --- Step 1: largest 3D-CC below the bifurcation ----------------
    % Drop everything above z_bif and isolate the single largest
    % 26-connected component. This makes the centroid extractor
    % robust to slice-by-slice label flicker (where a small
    % disconnected vessel-vein-pair fragment briefly outweighs the
    % real iliac in a single slice).
    mask_below = mask3d;
    mask_below(:, :, 1:z_bif) = false;
    if any(mask_below(:))
        cc3 = bwconncomp(mask_below, 26);
        if cc3.NumObjects > 1
            sz3 = cellfun(@numel, cc3.PixelIdxList);
            [~, kbig] = max(sz3);
            mask_below = false(sz);
            mask_below(cc3.PixelIdxList{kbig}) = true;
        end
    end
    % Use the isolated 3D-CC mask for centroid extraction.
    mask3d = mask_below;
    pix_mm = abs(D.pixel_mm(1));
    ssp_mm = abs(D.slice_spacing_mm);
    pix_mm_y = pix_mm;
    z_lo = z_bif;
    z_hi = sz(3);
    ys = []; xs = []; zs = [];
    prev_xy = [];
    max_hop_mm = 20;                % generous slice-to-slice cap
    merge_radius_mm = 6;            % merge CCs within 6 mm of each other
    vessel_max_vox = round(400 / pix_mm^2);   % ≤ ~400 mm² (rejects bone leaks)
    for z = z_lo:z_hi
        sl = mask3d(:, :, z);
        if ~any(sl(:)); continue; end
        cc = bwconncomp(sl, 8);
        if cc.NumObjects == 0; continue; end
        % Filter out bone-leak-sized CCs (> 400 mm² is not a normal
        % iliac/CFA cross-section).
        sizes_cc = cellfun(@numel, cc.PixelIdxList);
        keep = find(sizes_cc <= vessel_max_vox);
        if isempty(keep); continue; end
        n_keep = numel(keep);
        cents = zeros(n_keep, 2);
        for ki = 1:n_keep
            [yy_k, xx_k] = ind2sub(size(sl), cc.PixelIdxList{keep(ki)});
            cents(ki, :) = [mean(yy_k), mean(xx_k)];
        end
        sizes_keep = sizes_cc(keep)';        % column
        if isempty(prev_xy)
            % First slice: anchor on the largest vessel-sized CC.
            [~, kpick] = max(sizes_keep);
            anchor_xy = cents(kpick, :);
        else
            anchor_xy = prev_xy;
        end
        % Take a SIZE-WEIGHTED MEAN of all vessel-sized CCs whose
        % centroid sits within merge_radius_mm of the anchor. This
        % suppresses the centroid alternation that happens when a
        % single vessel cross-section is split across two adjacent
        % CCs (a common artifact of label leakage near the bifurcation
        % and in the femoral-vein-adjacent region). When only one CC
        % is within range, the weighted mean reduces to that centroid.
        d_mm = vecnorm(cents - anchor_xy, 2, 2) * pix_mm_y;
        within = d_mm <= merge_radius_mm;
        if ~any(within)
            % Fall back to the nearest single CC if nothing is within
            % the merge radius.
            [d_min, kpick] = min(d_mm);
            if d_min > max_hop_mm
                continue;
            end
            within = false(n_keep, 1);
            within(kpick) = true;
        end
        wsum = sum(sizes_keep(within));
        merged_xy = sum(cents(within, :) .* sizes_keep(within), 1) / wsum;
        % Cap hop relative to previous centroid (after merging).
        if ~isempty(prev_xy)
            hop_mm = norm(merged_xy - prev_xy) * pix_mm_y;
            if hop_mm > max_hop_mm
                continue;
            end
        end
        prev_xy = merged_xy;
        ys(end+1) = merged_xy(1); %#ok<AGROW>
        xs(end+1) = merged_xy(2); %#ok<AGROW>
        zs(end+1) = z;            %#ok<AGROW>
    end
    if isempty(zs)
        P_mm = zeros(0, 3);
    else
        % Temporal median filter on the centroid trajectory in z.
        % Suppresses single-node and few-node spikes that survive the
        % weighted-merge step (when the upstream label mask has slice-
        % by-slice flicker between two adjacent anatomic structures,
        % the per-slice centroid still alternates even after merging).
        % Window = 5 nodes (~2.5 mm of arc at 0.5 mm slice spacing) is
        % short enough to preserve real iliac curvature and long
        % enough to kill the flicker.
        if numel(ys) >= 5
            % Two-stage smoothing: median filter kills isolated spikes,
            % then a small moving average smooths the residual noise.
            ys = medfilt1(ys, 5, 'truncate');
            xs = medfilt1(xs, 5, 'truncate');
            if numel(ys) >= 21
                ys = movmean(ys, 21, 'Endpoints', 'shrink');
                xs = movmean(xs, 21, 'Endpoints', 'shrink');
            end
        end
        % Columns: X=lateral (image-x), Y=AP (image-y), Z=axial
        P_mm = [xs(:)*pix_mm, ys(:)*pix_mm, zs(:)*ssp_mm];
    end
end

function out = ternary(cond, a, b)
    if cond; out = a; else; out = b; end
end

function skipped = walker_skipped(side_result)
%WALKER_SKIPPED  Defensive check for whether a walker actually ran.
%   The walker's initial info struct sets `skipped=true`; if the
%   walker runs successfully, it returns a fresh info struct that may
%   omit that field. Treat "field missing" as "ran successfully".
    if isfield(side_result.info, 'skipped')
        skipped = side_result.info.skipped;
    else
        skipped = false;
    end
end

function P_mm = aorta_mask_to_centerline_mm(aorta_mask, z_bif, D)
%AORTA_MASK_TO_CENTERLINE_MM  Per-slice centroid of the aorta label
%   from cranial-most slice down to the bifurcation. Returns (:,3) of
%   [X_mm, Y_mm, Z_mm], proximal → distal (low z → z_bif). Used by
%   se3_cross_vessel_check to obtain the aortic tangent at the
%   bifurcation node.
    sz = size(aorta_mask);
    pix_mm = abs(D.pixel_mm(1));
    ssp_mm = abs(D.slice_spacing_mm);
    ys = []; xs = []; zs = [];
    for z = 1:z_bif
        sl = aorta_mask(:, :, z);
        if ~any(sl(:)); continue; end
        [yy, xx] = find(sl);
        ys(end+1) = mean(yy); %#ok<AGROW>
        xs(end+1) = mean(xx); %#ok<AGROW>
        zs(end+1) = z;        %#ok<AGROW>
    end
    if isempty(zs)
        P_mm = zeros(0, 3);
    else
        P_mm = [xs(:) * pix_mm, ys(:) * pix_mm, zs(:) * ssp_mm];
    end
end

function [best_combo, best_diag] = pick_best_combination(side_results, x_aorta, pix_mm)
%PICK_BEST_COMBINATION  For each (L-path, R-path) in {up, down}², score
%   the bilateral symmetry of the distal endpoints and pick the lowest-
%   asymmetry combination.
    paths = {'up', 'down'};
    best_score = Inf; best_combo = {'up', 'up'}; best_diag = struct();
    idx = 0;
    for li = 1:2
        for ri = 1:2
            idx = idx + 1;
            L = side_results.L.(paths{li});
            R = side_results.R.(paths{ri});
            % Get distal endpoints (most-caudal slice centroid)
            L_xy = terminus_xy(L.mask, side_results.L.on_side_xy);
            R_xy = terminus_xy(R.mask, side_results.R.on_side_xy);
            if isempty(L_xy) || isempty(R_xy); continue; end
            % Asymmetry score: weight LATERAL asymmetry strongly (the
            % bilateral CFAs should be near mirror-images across the
            % aortic midline — their lateral distances from midline
            % should match within a few percent). Y-asymmetry is much
            % more forgiving because patient rotation, gantry tilt, or
            % anatomic variants can shift one CFA more anterior than
            % the other by 20-30 mm without indicating a wrong vessel.
            dy_mm = abs(L_xy(1) - R_xy(1)) * pix_mm;
            L_lat = abs(L_xy(2) - x_aorta);
            R_lat = abs(R_xy(2) - x_aorta);
            lat_asym = abs(L_lat - R_lat) / max(max(L_lat, R_lat), eps);
            penalty = dy_mm / 60 + lat_asym * 5;
            if penalty < best_score
                best_score = penalty;
                best_combo = {paths{li}, paths{ri}};
                best_diag = struct( ...
                    'combo_idx', idx, ...
                    'asymmetry_penalty', penalty, ...
                    'dy_mm', dy_mm, ...
                    'L_lat', L_lat, 'R_lat', R_lat, ...
                    'lat_asym', lat_asym);
            end
        end
    end
end

function xy = terminus_xy(mask, on_side_xy)
% Centroid of the most-caudal mask slice on the given side
    sz = size(mask);
    m = mask & repmat(on_side_xy, [1, 1, sz(3)]);
    zp = squeeze(any(any(m, 1), 2));
    z_end = find(zp, 1, 'last');
    if isempty(z_end); xy = []; return; end
    sl = m(:, :, z_end);
    [yy, xx] = find(sl);
    if isempty(yy); xy = []; return; end
    xy = [mean(yy), mean(xx)];
end

function [mask_out, label_out, side_info] = walk_up_from_cfa(D, mask, label, ...
        cfa_label, on_side_xy, cfa_voxel, z_stop, ...
        max_jump_vox, min_R_vox, max_R_vox, opts, side_name)
%WALK_UP_FROM_CFA  Walk SUPERIORLY from a detected CFA seed at the FOV
%   bottom up through the CFA → EIA → CIA chain. Anatomically robust:
%   the CFA has no posterior branches that could lure the walker into
%   the gluteal / hypogastric territory. Stops at z = z_stop (typically
%   2 slices below the aortic bifurcation), where the iliac trunk
%   merges into the shared aorta.
    [Ny, Nx, Nz] = size(D.vol);
    mask_out  = mask;
    label_out = label;

    side_info = struct('side', side_name, 'starting_z', cfa_voxel(3), ...
        'last_z', cfa_voxel(3), 'added_slices', 0, 'added_voxels', 0, ...
        'reacquired_at', [], 'direction', 'up');

    % Paint the CFA seed itself first
    cy0 = cfa_voxel(1); cx0 = cfa_voxel(2); cz0 = cfa_voxel(3);
    slc_hu = D.vol(:, :, cz0);
    bw = (slc_hu >= opts.hu_lo) & (slc_hu <= opts.hu_hi) & on_side_xy;
    bw(label_out(:, :, cz0) > 0) = false;
    % Pick the CC containing the seed
    lbl_cc = bwlabel(bw, 8);
    seed_cc_id = lbl_cc(cy0, cx0);
    if seed_cc_id == 0
        % Seed voxel not in any CC — force-paint a small disk
        for dy = -3:3; for dx = -3:3
            yy = cy0 + dy; xx = cx0 + dx;
            if yy < 1 || yy > Ny || xx < 1 || xx > Nx; continue; end
            if on_side_xy(yy, xx); mask_out(yy, xx, cz0) = true; label_out(yy, xx, cz0) = cfa_label; end
        end; end
    else
        idx = find(lbl_cc == seed_cc_id);
        [py, px] = ind2sub([Ny, Nx], idx);
        vol_idx = sub2ind([Ny, Nx, Nz], py, px, cz0 * ones(size(py)));
        mask_out(vol_idx) = true;
        label_out(vol_idx) = cfa_label;
        side_info.added_voxels = side_info.added_voxels + numel(vol_idx);
    end

    last_xy = [cy0, cx0];
    last_kept_z = cz0;
    last_kept_xy = last_xy;
    win = round(max(opts.max_jump_mm * 4 / D.pixel_mm(1), 25));
    consecutive_drops = 0;
    reacquire_attempts = 0;
    in_reacquire = false;

    % Walk z DECREASING toward z_stop
    z_stop_clamped = max(1, z_stop);
    for z = (cz0 - 1):-1:z_stop_clamped
        slc_hu = D.vol(:, :, z);
        bw_full = (slc_hu >= opts.hu_lo) & (slc_hu <= opts.hu_hi);
        bw_full(label_out(:, :, z) > 0) = false;
        bw_full = bw_full & on_side_xy;
        if ~in_reacquire
            y0 = max(1, round(last_xy(1)) - win); y1 = min(Ny, round(last_xy(1)) + win);
            x0 = max(1, round(last_xy(2)) - win); x1 = min(Nx, round(last_xy(2)) + win);
            bw_local = false(Ny, Nx);
            bw_local(y0:y1, x0:x1) = bw_full(y0:y1, x0:x1);
        else
            bw_local = bw_full;
        end
        cc = bwconncomp(bw_local, 8);
        if cc.NumObjects == 0
            consecutive_drops = consecutive_drops + 1;
            if consecutive_drops >= opts.k_dropout
                if reacquire_attempts < opts.max_reacquire && ~in_reacquire
                    in_reacquire = true; reacquire_attempts = reacquire_attempts + 1;
                    consecutive_drops = 0; continue;
                else; break; end
            end
            continue;
        end
        props = regionprops(cc, 'Area', 'Centroid', 'Perimeter', 'PixelIdxList');
        scores = zeros(numel(props), 1);
        for i = 1:numel(props)
            A = props(i).Area; Pm = max(props(i).Perimeter, eps);
            rnd = 4 * pi * A / Pm^2; R = sqrt(A / pi);
            if rnd < opts.roundness_min; continue; end
            if R < min_R_vox || R > max_R_vox; continue; end
            cx = props(i).Centroid(1); cy = props(i).Centroid(2);
            if ~on_side_xy(round(cy), round(cx)); continue; end
            if in_reacquire
                if R > 0.65 * max_R_vox; continue; end
                anterior_bias = exp(-((cy) / Ny)^2 * 4);
                scores(i) = rnd * anterior_bias;
            else
                dxy = norm(props(i).Centroid - [last_xy(2), last_xy(1)]);
                if dxy > max_jump_vox * 4; continue; end
                scores(i) = rnd * exp(-(dxy / max_jump_vox)^2);
            end
        end
        if max(scores) <= 0
            consecutive_drops = consecutive_drops + 1;
            if consecutive_drops >= opts.k_dropout
                if reacquire_attempts < opts.max_reacquire && ~in_reacquire
                    in_reacquire = true; reacquire_attempts = reacquire_attempts + 1;
                    consecutive_drops = 0; continue;
                else; break; end
            end
            continue;
        end
        [~, pick] = max(scores);
        pix_idx = props(pick).PixelIdxList;
        [py, px] = ind2sub([Ny, Nx], pix_idx);
        vol_idx = sub2ind([Ny, Nx, Nz], py, px, z * ones(size(py)));
        mask_out(vol_idx) = true;
        label_out(vol_idx) = cfa_label;
        side_info.added_voxels = side_info.added_voxels + numel(vol_idx);
        c_xy = props(pick).Centroid;
        new_xy = [c_xy(2), c_xy(1)];
        % NOTE: previous version called `bridge_tube` here to paint a
        % HU-gated tube between last_kept slice and the current slice
        % when the walker had skipped slices. That strategy is REMOVED
        % — for contrast-enhanced arterial-phase CTAs the well-opacified
        % iliac/CFA segment slice-to-slice naturally, so 3D-connectivity
        % is preserved by simply painting each slice's contrast CC. If
        % the walker hits a slice with no contrast, that's a real
        % anatomic endpoint (or a real contrast dropout) — accept it,
        % don't forge a connection.
        if in_reacquire
            side_info.reacquired_at(end+1) = z; %#ok<AGROW>
            in_reacquire = false;
        end
        last_xy = new_xy; last_kept_xy = new_xy; last_kept_z = z;
        consecutive_drops = 0;
        side_info.added_slices = side_info.added_slices + 1;
    end
    side_info.last_z = last_kept_z;
end

function [mask_out, label_out, side_info] = walk_side(D, mask, label, ...
        cfa_label, on_side_xy, z_bot, ...
        max_jump_vox, min_R_vox, max_R_vox, opts, side_name)
%WALK_SIDE  Walk inferiorly from this side's mask terminus, slice by slice.
%   All new voxels added stay strictly on `on_side_xy`. Slices are
%   painted independently — no inter-slice bridge tubes (see the bridge-
%   removal note at the end of this file).
    [Ny, Nx, Nz] = size(D.vol);
    mask_out  = mask;
    label_out = label;
    side_info = struct('side', side_name, 'starting_z', z_bot, 'last_z', z_bot, ...
                       'added_slices', 0, 'added_voxels', 0, ...
                       'reacquired_at', []);

    % Get the starting centroid: the largest CC on this side at z_bot
    slc = mask_out(:, :, z_bot) & on_side_xy;
    cc  = bwconncomp(slc, 8);
    if cc.NumObjects == 0; return; end
    sizes = cellfun(@numel, cc.PixelIdxList);
    [~, kpick] = max(sizes);
    [yy, xx] = ind2sub([Ny, Nx], cc.PixelIdxList{kpick});
    last_xy = [mean(yy), mean(xx)];

    win = round(max(opts.max_jump_mm * 4 / D.pixel_mm(1), 25));
    consecutive_drops    = 0;
    last_kept_z          = z_bot;
    last_kept_xy         = last_xy;
    in_reacquire         = false;
    reacquire_attempts   = 0;

    for z = (z_bot + 1):Nz
        slc_hu  = D.vol(:, :, z);
        bw_full = (slc_hu >= opts.hu_lo) & (slc_hu <= opts.hu_hi);
        bw_full(label_out(:, :, z) > 0) = false;
        bw_full = bw_full & on_side_xy;

        if ~in_reacquire
            y0 = max(1, round(last_xy(1)) - win); y1 = min(Ny, round(last_xy(1)) + win);
            x0 = max(1, round(last_xy(2)) - win); x1 = min(Nx, round(last_xy(2)) + win);
            bw_local = false(Ny, Nx);
            bw_local(y0:y1, x0:x1) = bw_full(y0:y1, x0:x1);
        else
            bw_local = bw_full;
        end

        cc = bwconncomp(bw_local, 8);
        if cc.NumObjects == 0
            consecutive_drops = consecutive_drops + 1;
            if consecutive_drops >= opts.k_dropout
                if reacquire_attempts < opts.max_reacquire && ~in_reacquire
                    in_reacquire = true;
                    reacquire_attempts = reacquire_attempts + 1;
                    consecutive_drops = 0;
                    continue;
                else
                    break;
                end
            end
            continue;
        end

        props = regionprops(cc, 'Area', 'Centroid', 'Perimeter', 'PixelIdxList');
        scores = zeros(numel(props), 1);
        for i = 1:numel(props)
            A = props(i).Area;
            P = max(props(i).Perimeter, eps);
            rnd = 4 * pi * A / P^2;
            R_est = sqrt(A / pi);
            if rnd < opts.roundness_min; continue; end
            if R_est < min_R_vox || R_est > max_R_vox; continue; end
            cx = props(i).Centroid(1);
            cy = props(i).Centroid(2);
            if ~on_side_xy(round(cy), round(cx))
                continue;
            end
            if in_reacquire
                if R_est > 0.65 * max_R_vox; continue; end
                anterior_bias = exp(-((cy) / Ny)^2 * 4);
                scores(i) = rnd * anterior_bias;
            else
                dxy = norm(props(i).Centroid - [last_xy(2), last_xy(1)]);
                if dxy > max_jump_vox * 4; continue; end
                scores(i) = rnd * exp(-(dxy / max_jump_vox)^2);
            end
        end
        if max(scores) <= 0
            consecutive_drops = consecutive_drops + 1;
            if consecutive_drops >= opts.k_dropout
                if reacquire_attempts < opts.max_reacquire && ~in_reacquire
                    in_reacquire = true;
                    reacquire_attempts = reacquire_attempts + 1;
                    consecutive_drops = 0;
                    continue;
                else
                    break;
                end
            end
            continue;
        end

        [~, pick] = max(scores);
        pix_idx   = props(pick).PixelIdxList;
        [py, px]  = ind2sub([Ny, Nx], pix_idx);
        vol_idx   = sub2ind([Ny, Nx, Nz], py, px, z * ones(size(py)));
        mask_out(vol_idx)  = true;
        label_out(vol_idx) = cfa_label;
        side_info.added_voxels = side_info.added_voxels + numel(vol_idx);

        c_xy   = props(pick).Centroid;
        new_xy = [c_xy(2), c_xy(1)];

        % NOTE: previous version called `bridge_tube` here to paint a
        % HU-gated tube between last_kept slice and the current slice
        % when the walker had skipped slices during contrast dropout.
        % That strategy is REMOVED — see the matching note in
        % walk_up_from_cfa above. Just clear the reacquire state.
        if z > last_kept_z && in_reacquire
            side_info.reacquired_at(end+1) = z; %#ok<AGROW>
            in_reacquire = false;
        end

        last_xy           = new_xy;
        last_kept_xy      = new_xy;
        last_kept_z       = z;
        consecutive_drops = 0;
        side_info.added_slices = side_info.added_slices + 1;
    end
    side_info.last_z = last_kept_z;
end

% NOTE: previous versions of this file included `bridge_path_has_contrast`
% and `bridge_tube` helpers that painted HU-gated tubes between slices
% during walker reacquire. Both helpers REMOVED — for contrast-enhanced
% arterial-phase CTA, the iliac/CFA segment slice-to-slice naturally;
% drawing bridges between gaps created anatomically impossible
% segmentation artifacts visible in the 3-D recon.
