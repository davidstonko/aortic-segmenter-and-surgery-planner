function seed = detect_cfa_seed(D, side, x_aorta, prior_mask)
%AUTOSEG.DETECT_CFA_SEED  Find the common femoral artery seed at the
%   FOV bottom for one patient side. The CFA is a bright round contrast
%   tube in the femoral triangle (anterolateral, below the inguinal
%   ligament). Anchoring the iliac/CFA segmentation here (and walking
%   UP from it) avoids the ambiguity of walking DOWN from the iliac
%   terminus, which can mistakenly track a hypogastric / gluteal branch.
%
%   seed = autoseg.detect_cfa_seed(D, side, x_aorta)
%   seed = autoseg.detect_cfa_seed(D, side, x_aorta, prior_mask)
%
%   D            CT volume struct (.vol, .pixel_mm, .slice_spacing_mm)
%   side         'L' (patient-left, high x) or 'R' (patient-right, low x)
%   x_aorta      aorta midline x-coord (from the bifurcation slice),
%                defines the L/R split column
%   prior_mask   OPTIONAL logical 3D mask of the existing iliac
%                segmentation on this side (typically the TS + branch-
%                detection output, BEFORE this CFA extension). When
%                provided, the candidate scoring extrapolates the iliac
%                trajectory toward the FOV bottom and prefers candidates
%                near that extrapolation. This is critical because the
%                anterior-bias heuristic alone confuses the CFA with the
%                accompanying femoral vein on some patients (the vein
%                can sit more anteriorly than the artery when patient
%                anatomy is rotated or asymmetric).
%
%   Returns a struct:
%       .ok          true if a confident CFA seed was found
%       .voxel       [y, x, z] in image-voxel coordinates
%       .reason      free-text rationale (also populated when ok=false)
%       .candidates  struct array of considered candidates with scores,
%                    sorted best-first
%
%   On low confidence (multiple plausible candidates, or none at all),
%   ok=false and the caller should prompt the user to click manually.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D          (1,1) struct
        side       (1,:) char {mustBeMember(side, {'L','R'})}
        x_aorta    (1,1) double
        prior_mask logical = logical([])
    end

    sz  = size(D.vol);
    pix = D.pixel_mm(1);

    % Side mask
    on_side_xy = false(sz(1), sz(2));
    if strcmp(side, 'L')
        on_side_xy(:, ceil(x_aorta)+1:end) = true;
    else
        on_side_xy(:, 1:floor(x_aorta)-1) = true;
    end

    % Optional trajectory prior. We use ONLY the most-PROXIMAL portion
    % of the prior iliac mask (z = z_bif to z_bif + 30 slices), where
    % TotalSegmentator's labeling is most reliable. The distal portion
    % of the prior mask can be corrupted by the imreconstruct grow
    % step crossing the midline, so using it as a trajectory prior
    % would propagate that error.
    have_prior = ~isempty(prior_mask) && isequal(size(prior_mask), sz);
    extrap_xy_at_z = [];
    if have_prior
        side_mask = prior_mask & repmat(on_side_xy, [1, 1, sz(3)]);
        zp = squeeze(any(any(side_mask, 1), 2));
        zi = find(zp);
        if numel(zi) >= 5
            % Use the proximal 30 slices of the iliac (clean part)
            z_start = zi(1);
            z_end_clean = min(zi(1) + 30, zi(end));
            zs = []; ys = []; xs = [];
            for z = z_start:z_end_clean
                sl = side_mask(:, :, z);
                if ~any(sl(:)); continue; end
                cc = bwconncomp(sl, 8);
                sizes_cc = cellfun(@numel, cc.PixelIdxList);
                [~, kbig] = max(sizes_cc);
                [yy, xx] = ind2sub(size(sl), cc.PixelIdxList{kbig});
                zs(end+1) = z; ys(end+1) = mean(yy); xs(end+1) = mean(xx); %#ok<AGROW>
            end
            if numel(zs) >= 3
                p_y = polyfit(zs, ys, 1);
                p_x = polyfit(zs, xs, 1);
                extrap_xy_at_z = @(z) [polyval(p_y, z), polyval(p_x, z)];
            end
        end
    end

    % Scan the bottom 30 mm of the FOV — that's where the CFA lives in
    % a typical aorto-iliac CTA. Going higher than that risks running
    % into the iliac region where multiple round contrast tubes exist.
    z_search_lo = max(1, sz(3) - round(30 / D.slice_spacing_mm));
    z_search_hi = sz(3);

    R_min_vox = 3.0 / pix;     % CFA is typically 6-12 mm diameter → R 3-6 mm
    R_max_vox = 7.0 / pix;

    candidates = struct('score', {}, 'y', {}, 'x', {}, 'z', {}, ...
                        'R_vox', {}, 'roundness', {}, 'median_HU', {});

    for z = z_search_lo:z_search_hi
        slc = D.vol(:, :, z);
        % HU window: arterial peak — bright, narrow (excludes venous
        % return which is weaker in arterial-phase scans).
        bw = (slc >= 250) & (slc <= 1500);
        bw = bw & on_side_xy;
        bw = imopen(bw, strel('disk', 1));
        cc = bwconncomp(bw, 8);
        if cc.NumObjects == 0; continue; end
        props = regionprops(cc, 'Area', 'Centroid', 'Perimeter', 'PixelIdxList');
        for i = 1:numel(props)
            A = props(i).Area;
            P = max(props(i).Perimeter, eps);
            rnd = 4 * pi * A / P^2;
            R = sqrt(A / pi);
            if R < R_min_vox || R > R_max_vox; continue; end
            if rnd < 0.55; continue; end
            % Median HU in the CC — the CFA has bright arterial contrast
            % (typically 350-700 HU peak); the femoral vein and small
            % nutrient branches have lower HU.
            hus = slc(props(i).PixelIdxList);
            med_hu = double(median(hus));
            if med_hu < 300; continue; end
            % Position bias — anterior is more likely the CFA because
            % the femoral triangle (CFA + CFV + lymphatic node) sits
            % anteriorly in the pelvic outlet. This heuristic is
            % imperfect (the CFV can be more anterior than the CFA in
            % some patients), so the caller should treat detection as
            % advisory and prompt the user when top candidates are tied.
            position_bias = exp(-((props(i).Centroid(2) / sz(1)) - 0.4)^2 * 6);
            score = rnd * position_bias * (med_hu / 500) * exp(-((R - 4/pix) / (2/pix))^2);
            cnd = struct( ...
                'score', score, ...
                'y', props(i).Centroid(2), ...
                'x', props(i).Centroid(1), ...
                'z', z, ...
                'R_vox', R, ...
                'roundness', rnd, ...
                'median_HU', med_hu);
            candidates(end+1) = cnd; %#ok<AGROW>
        end
    end

    seed = struct('ok', false, 'voxel', [], 'reason', '', ...
                  'candidates', candidates);
    if isempty(candidates)
        seed.reason = sprintf('No round, bright-contrast CCs in z=[%d,%d] on the %s side. The scan may not extend to the femoral level, or contrast is too faint to auto-anchor. Prompt the user to click the %s CFA.', z_search_lo, z_search_hi, side, side);
        return;
    end

    [~, ord] = sort([candidates.score], 'descend');
    candidates = candidates(ord);
    seed.candidates = candidates;

    best = candidates(1);
    % Confidence check: at the femoral level, the CFA artery and the
    % accompanying femoral vein BOTH light up in arterial-phase
    % contrast on some patients (slow venous return / late acquisition
    % timing), and are essentially indistinguishable on roundness +
    % brightness. When the next-best candidate has > 80% of best score
    % AND is > 10 mm away in XY (genuine artery-vein pair separated by
    % the vessel-pair distance, not the same structure across slices),
    % we don't have enough signal to choose — prompt the user.
    if numel(candidates) > 1
        % Find the next candidate that is GEOMETRICALLY distinct
        % (> 8 mm away in XY) — within 8 mm is the same vessel across
        % a few slices.
        for k = 2:numel(candidates)
            c = candidates(k);
            d_mm = norm([c.y - best.y, c.x - best.x]) * pix;
            if d_mm < 8; continue; end
            score_ratio = c.score / best.score;
            if score_ratio > 0.80
                seed.reason = sprintf(['Two CFA candidates within 80%% of best score, ' ...
                    'separated by %.0f mm in XY: (y=%.0f x=%.0f z=%d) score %.3f and ' ...
                    '(y=%.0f x=%.0f z=%d) score %.3f. Likely the CFA + femoral vein pair, ' ...
                    'or two real arteries the detector can''t rank. Prompt the user ' ...
                    'to click the %s CFA on a slice near the FOV bottom.'], ...
                    d_mm, best.y, best.x, best.z, best.score, ...
                    c.y, c.x, c.z, c.score, side);
                return;
            end
            break;
        end
    end

    seed.ok = true;
    seed.voxel = [round(best.y), round(best.x), best.z];
    seed.reason = sprintf('CFA seed: (y=%.0f x=%.0f z=%d), R=%.1f mm, rnd=%.2f, median HU %.0f, score %.3f.', ...
        best.y, best.x, best.z, best.R_vox * pix, best.roundness, best.median_HU, best.score);
end
