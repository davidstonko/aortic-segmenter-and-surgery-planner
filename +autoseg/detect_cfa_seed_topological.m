function seed = detect_cfa_seed_topological(D, side, aorta_mask, x_aorta)
%AUTOSEG.DETECT_CFA_SEED_TOPOLOGICAL  Anatomy-invariant CFA detector.
%
%   seed = autoseg.detect_cfa_seed_topological(D, side, aorta_mask, x_aorta)
%
%   Identifies the CFA seed using only properties of the contrast tree
%   that are invariant across patients, scanners, and positioning:
%
%     1. HU INVARIANT. The CFA is contrast-filled (HU 150-1400) on an
%        arterial-phase CTA, like every other artery in the pelvis.
%     2. CONNECTIVITY INVARIANT. The CFA is contrast-connected to the
%        aortic lumen through a continuous tree (aorta → CIA → EIA →
%        CFA). Bone leaks may be in this tree (partial-volume HU
%        through cortex), but they shortcut through nearby tree
%        voxels — their geodesic distance from the aorta is short.
%     3. GEODESIC INVARIANT. Among the endpoints of the aorta-connected
%        tree, the CFA is the FARTHEST from the aorta along the tree
%        itself. The aorta-to-CFA path is ~25-30 cm of real vessel
%        regardless of patient size; the aorta-to-bone-leak path is
%        much shorter because bone leaks are partial-volume bleeds
%        right next to existing tree voxels.
%     4. CAUDAL INVARIANT. The CFA is in the proximal thigh on a
%        typical aorto-iliac CTA — i.e. in the bottom ~30% of the FOV.
%        Bone leaks above the femoral level can have long geodesic
%        distance too, so we restrict the search to the caudal FOV.
%     5. VESSEL-SIZE INVARIANT. The CFA on a 0.7-1.0 mm pixel CT has
%        cross-section 5-200 voxels. Bone-leak pockets are either
%        much larger (1000+ vox) or much smaller (< 5 vox).
%
%   This is independent of:
%     - patient BMI (obesity shifts position but not topology)
%     - patient rotation / scanner tilt (connectivity is preserved)
%     - scanner make / pixel size (voxel-count thresholds are scaled
%       by pixel_mm; HU is calibrated)
%     - left/right anatomy (each side has its own aorta-connected tree)
%
%   Returns the same struct as autoseg.detect_cfa_seed:
%       .ok          true on confident detection
%       .voxel       [y, x, z] CFA centroid at the most-caudal slice
%       .reason      diagnostic text
%       .candidates  vessel-sized CCs at the chosen slice, ranked by
%                    geodesic distance (best first); useful for GUI
%                    to surface the top few when detection is uncertain

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D          (1,1) struct
        side       (1,:) char {mustBeMember(side, {'L','R'})}
        aorta_mask logical
        x_aorta    (1,1) double
    end
    sz  = size(D.vol);
    pix = D.pixel_mm(1);
    if ~isequal(size(aorta_mask), sz)
        error('aorta_mask size mismatch');
    end

    % Vessel-size window in mm² (then converted to voxels — patient-
    % invariant across scanners with different pixel sizes). CFA at the
    % inguinal level: diameter 4-12 mm → area 12-113 mm². Bone-leak
    % pockets in the femoral head / greater trochanter are typically
    % > 200 mm² (they fill entire bone-marrow channels).
    cfa_area_min_mm2 = 8;     % 3.2 mm diameter floor (small distal vessels)
    cfa_area_max_mm2 = 200;   % 16 mm diameter ceiling (rejects bone-marrow pockets)
    vessel_min_vox = max(5, round(cfa_area_min_mm2 / pix^2));
    vessel_max_vox = round(cfa_area_max_mm2 / pix^2);

    % Anatomic prior on lateral distance of CFA from midline (mm).
    % CFA sits 5-10 cm lateral of the patient midline in the inguinal
    % region across virtually all adult anatomies. Bone leaks via the
    % greater trochanter are 10-15 cm lateral; venous structures sit
    % medial to the artery. A Gaussian prior centered at 70 mm with
    % sigma 30 mm prefers the anatomically correct band.
    cfa_lat_mu_mm = 70;
    cfa_lat_sigma_mm = 30;

    % HU contrast band — arterial phase
    contrast = (D.vol >= 150) & (D.vol <= 1400);

    % Side band, with a small midline buffer so the bifurcation is
    % reachable by traversal even if the aorta straddles the midline.
    on_side_xy = false(sz(1), sz(2));
    midline_buf_vox = round(2 / pix);
    if strcmp(side, 'L')
        on_side_xy(:, max(1, ceil(x_aorta) - midline_buf_vox):end) = true;
    else
        on_side_xy(:, 1:min(sz(2), floor(x_aorta) + midline_buf_vox)) = true;
    end
    contrast_side = contrast & repmat(on_side_xy, [1, 1, sz(3)]);
    aorta_in_band = aorta_mask & repmat(on_side_xy, [1, 1, sz(3)]);

    % Grow the aorta voxels through the contrast mask to obtain the
    % full aorta-connected contrast tree on this side.
    seed_mask = aorta_in_band | contrast_side;
    reachable = imreconstruct(aorta_in_band, seed_mask, 26);

    cc = bwconncomp(reachable, 26);
    if cc.NumObjects == 0
        seed = struct('ok', false, 'voxel', [], 'candidates', [], ...
            'reason', sprintf('No aorta-connected contrast on the %s side.', side));
        return;
    end
    sizes_cc = cellfun(@numel, cc.PixelIdxList);
    [~, kbig] = max(sizes_cc);
    aorta_tree = false(sz);
    aorta_tree(cc.PixelIdxList{kbig}) = true;

    % Geodesic distance from the aorta voxels (seeds) to every voxel
    % in the tree. Real CFA endpoints are ~250+ mm of tree-path away
    % from the aorta; bone-leak pockets shortcut through nearby tree
    % voxels and end up much closer.
    seeds_in_tree = aorta_in_band & aorta_tree;
    if ~any(seeds_in_tree(:))
        seed = struct('ok', false, 'voxel', [], 'candidates', [], ...
            'reason', 'Aorta seeds and connected tree do not intersect.');
        return;
    end
    gd_vox = bwdistgeodesic(aorta_tree, seeds_in_tree, 'quasi-euclidean');
    % Convert to mm (use in-plane pixel; tree path is mostly axial-ish
    % in iliacs, so using pix is a slight underestimate when z-spacing
    % differs — fine for ranking).
    gd_mm = gd_vox * pix;

    % Walk upward from the FOV bottom to find the most-caudal slice
    % of the aorta-connected tree that contains a vessel-sized CC.
    % This skips slices that are entirely bone leak.
    zp = squeeze(any(any(aorta_tree, 1), 2));
    z_search_hi = find(zp, 1, 'last');
    z_search_lo = max(1, round(0.5 * sz(3)));   % don't look above mid-FOV
    if isempty(z_search_hi)
        seed = struct('ok', false, 'voxel', [], 'candidates', [], ...
            'reason', 'Aorta-connected tree has no slice presence.');
        return;
    end

    z_cfa = [];
    cands_at_slice = [];
    for z_try = z_search_hi:-1:z_search_lo
        sl = aorta_tree(:, :, z_try);
        if ~any(sl(:)); continue; end
        cc_sl = bwconncomp(sl, 8);
        slice_cands = [];
        rp = regionprops(cc_sl, 'Area', 'Perimeter', 'Centroid');
        for k = 1:cc_sl.NumObjects
            idx = cc_sl.PixelIdxList{k};
            n = numel(idx);
            if n < vessel_min_vox || n > vessel_max_vox; continue; end
            % geodesic distance: take the MAX over the CC (the endpoint
            % of the tree-path through this CC).
            [yy, xx] = ind2sub(size(sl), idx);
            lin = sub2ind(sz, yy, xx, repmat(z_try, size(yy)));
            gd_here = gd_mm(lin);
            gd_here = gd_here(isfinite(gd_here));
            if isempty(gd_here); continue; end
            % Roundness: 4πA / P². Real CFA cross-section is ~circular
            % (roundness > 0.6); bone-leak pockets are irregular.
            A = rp(k).Area;
            P = max(rp(k).Perimeter, eps);
            rnd = 4 * pi * A / P^2;
            lateral_mm = abs(mean(xx) - x_aorta) * pix;
            lat_prior = exp( -((lateral_mm - cfa_lat_mu_mm) / cfa_lat_sigma_mm)^2 );
            % Score: roundness × lateral-position prior. Both are
            % anatomically invariant (no patient-size dependence).
            % Geodesic distance is used only as a hard filter below
            % because it doesn't discriminate among neighboring
            % terminals (which cluster within ~10% of each other).
            score = rnd * lat_prior;
            % Use .y/.x/.z so the caller (extend_to_cfa) can read
            % candidates with the same field names as detect_cfa_seed.
            cnd = struct( ...
                'y', mean(yy), ...
                'x', mean(xx), ...
                'z', z_try, ...
                'cc_index', k, ...
                'n', n, ...
                'roundness', rnd, ...
                'lateral_mm', lateral_mm, ...
                'lat_prior', lat_prior, ...
                'gd_max_mm', max(gd_here), ...
                'gd_mean_mm', mean(gd_here), ...
                'score', score);
            if isempty(slice_cands)
                slice_cands = cnd;
            else
                slice_cands(end+1) = cnd; %#ok<AGROW>
            end
        end
        if ~isempty(slice_cands)
            z_cfa = z_try;
            cands_at_slice = slice_cands;
            break;
        end
    end

    if isempty(z_cfa)
        seed = struct('ok', false, 'voxel', [], 'candidates', [], ...
            'reason', sprintf( ...
                'No vessel-sized CC (%d..%d vox) found in the aorta-connected tree below mid-FOV on the %s side. Likely all bone leak, or the scan does not extend to the femoral level.', ...
                vessel_min_vox, vessel_max_vox, side));
        return;
    end

    % Rank by score (roundness × lateral-position prior). The CFA is
    % the round, anterolateral vessel at the inguinal level.
    [~, ord] = sort([cands_at_slice.score], 'descend');
    cands_at_slice = cands_at_slice(ord);
    best = cands_at_slice(1);

    cy = best.y; cx = best.x;
    n_cfa = best.n;
    z_frac = z_cfa / sz(3);

    % Confidence: must be in the caudal portion of the FOV and the
    % geodesic distance must be plausibly aorta-to-CFA (anatomically
    % > 150 mm for any human).
    if z_frac < 0.65
        seed = struct('ok', false, ...
            'voxel', [round(cy), round(cx), z_cfa], ...
            'candidates', cands_at_slice, ...
            'reason', sprintf( ...
                'Aorta-connected tree on %s side terminates at z=%d (only %.0f%% down the FOV). Scan may not reach the femoral level; prompt the user to confirm the CFA.', ...
                side, z_cfa, 100*z_frac));
        return;
    end
    if best.gd_max_mm < 150
        seed = struct('ok', false, ...
            'voxel', [round(cy), round(cx), z_cfa], ...
            'candidates', cands_at_slice, ...
            'reason', sprintf( ...
                'Best %s CFA candidate is only %.0f mm of tree-path from the aorta (< 150 mm expected for any anatomy). The tree may be broken at the bifurcation, or the candidate is a bone leak masquerading as a vessel — prompt user.', ...
                side, best.gd_max_mm));
        return;
    end

    % Tie-detection: if the runner-up has > 85% of the best geodesic
    % distance and sits > 8 mm away from the best candidate at the
    % same slice, we can't confidently distinguish them. (This
    % happens when two real branches both reach the caudal slice with
    % similar tree-path lengths — e.g. a deep femoral that runs
    % parallel to the CFA at this z. Surface both and ask the user.)
    if numel(cands_at_slice) > 1
        c2 = cands_at_slice(2);
        d_mm = norm([c2.y - cy, c2.x - cx]) * pix;
        ratio = c2.score / max(best.score, eps);
        if d_mm > 8 && ratio > 0.90
            seed = struct('ok', false, ...
                'voxel', [round(cy), round(cx), z_cfa], ...
                'candidates', cands_at_slice, ...
                'reason', sprintf( ...
                    'Two %s candidates within 90%% score, %.0f mm apart: best (y=%.0f x=%.0f, score=%.2f, lat=%.0fmm) vs runner-up (y=%.0f x=%.0f, score=%.2f, lat=%.0fmm). Likely CFA + profunda femoris or similar — prompt user.', ...
                    side, d_mm, cy, cx, best.score, best.lateral_mm, ...
                    c2.y, c2.x, c2.score, c2.lateral_mm));
            return;
        end
    end

    seed = struct( ...
        'ok', true, ...
        'voxel', [round(cy), round(cx), z_cfa], ...
        'candidates', cands_at_slice, ...
        'reason', sprintf( ...
            'CFA seed (topological): %s side (y=%d x=%d z=%d), %d vox, roundness %.2f; %.0f mm lateral of midline, geodesic %.0f mm from aorta, z at %.0f%% of FOV.', ...
            side, round(cy), round(cx), z_cfa, n_cfa, best.roundness, ...
            best.lateral_mm, best.gd_max_mm, 100*z_frac));
end
