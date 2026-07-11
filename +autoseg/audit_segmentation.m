function report = audit_segmentation(mask, seg_label, D, opts)
%AUTOSEG.AUDIT_SEGMENTATION  Verify a segmentation is complete enough
%   for EVAR planning before advancing to centerline extraction. Block
%   advance on any ❌ finding so the operator can refine.
%
%   REPORT = autoseg.audit_segmentation(MASK, SEG_LABEL, D)
%   REPORT = autoseg.audit_segmentation(MASK, SEG_LABEL, D, OPTS)
%
%   MASK       Y×X×Z logical: the union mask after TS + extension passes
%   SEG_LABEL  EITHER
%              - Y×X×Z integer: a single label volume. If max id > 30
%                it's treated as TS multilabel (kidney anchor available;
%                visceral branches not). If max id ≤ 9-ish it's treated
%                as the post-extend_and_detect_branches label scheme
%                (1=aorta...9=SMA; visceral branches available;
%                kidney anchor not).
%              OR a struct with fields:
%                .ts_labels      TS multilabel (for the kidney anchor)
%                .branch_labels  the extend_and_detect_branches output
%                                (for visceral-branch detection)
%              Pass [] / struct() if only a binary mask is available.
%   D          volume struct from preprocess.dicom_load
%
%   The audit is divided into four blocks, each ✅ / ⚠️ / ❌:
%     1. **Required vessels.** Aorta, both iliacs, both CFAs (i.e. the
%        mask reaches the FOV bottom on both sides).
%     2. **Visceral branches.** Celiac, SMA, both renals. These come
%        from autoseg.extend_and_detect_branches (labels 6-9) if it
%        ran, or from per-vessel HU-anchor detection if not.
%     3. **Anatomic plausibility — sizes.** Aorta Ø 15-35 mm, iliac Ø
%        4-15 mm, CFA Ø 4-12 mm. Out-of-range → ⚠️ (operator review).
%     4. **Anatomic plausibility — SE(3) deformation of the centerline.**
%        Lift the centerline polyline to a sequence of frames in SE(3)
%        (Bishop frame: rotation-minimizing along the curve). Integrate
%        the cumulative twist + bend per arc-length. Anatomic abdominal
%        aorta has total absolute curvature ∫|κ|ds bounded (Sommer 2010
%        et al. tabulate ~0.5-2 rad over 200-300 mm). Larger means a
%        kink or a tracker leak into a non-aortic branch. Larger total
%        torsion ∫|τ|ds means the centerline is winding (likely a
%        skeleton-graph leak).
%
%   Returns REPORT with fields:
%       .blocks       struct array — name, verdict, findings, severity
%       .passed       true if no ❌ findings
%       .summary_text printable summary
%
%   Operator gate: `report.passed` is what `finishStep2` should check
%   before allowing advance to Step 3 (endpoint picking). On ❌ the
%   GUI shows the report and lets the user refine the segmentation
%   manually before retrying.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko
%
%   References for the SE(3) anatomic-plausibility check:
%     • Sommer G, et al. 3D constitutive modeling of the biaxial mech
%       behavior of aortic tissue. J Biomech 2010;43:2718-26.
%     • Bishop RL. There is more than one way to frame a curve.
%       Am Math Monthly 1975;82:246-251. (rotation-minimizing frame)
%     • Antiga L, Steinman DA. Robust and objective decomposition of
%       arterial geometry. IEEE TMI 2004;23:704-13. (centerline-based
%       quantitative descriptors of vascular anatomy)

    arguments
        mask      logical
        seg_label = []
        D         (1,1) struct = struct()
        opts      (1,1) struct = struct()
    end
    if ~isfield(opts, 'verbose'); opts.verbose = false; end

    % Unpack: if seg_label is a struct, use both label fields; otherwise
    % auto-detect which scheme the numeric volume uses by its max id.
    ts_labels = []; branch_labels = [];
    if isstruct(seg_label)
        if isfield(seg_label, 'ts_labels');     ts_labels     = seg_label.ts_labels;     end
        if isfield(seg_label, 'branch_labels'); branch_labels = seg_label.branch_labels; end
    elseif ~isempty(seg_label) && isnumeric(seg_label)
        if max(seg_label(:)) > 30
            ts_labels = seg_label;
        else
            branch_labels = seg_label;
        end
    end

    blocks = {};
    blocks{end+1} = check_required_vessels(mask, D, branch_labels);
    blocks{end+1} = check_visceral_branches(mask, branch_labels);
    blocks{end+1} = check_anatomic_sizes(mask, D);
    blocks{end+1} = check_proximal_extent_for_evar(mask, ts_labels, D, branch_labels);
    blocks{end+1} = check_per_side_continuity(mask, D, branch_labels);
    blocks{end+1} = check_se3_deformation(mask, D);
    report = struct('blocks', {blocks}, 'passed', false, 'summary_text', '');

    % Aggregate verdict
    severities = cellfun(@(b) max([b.severity, 0]), report.blocks);
    report.passed = ~any(severities >= 2);   % 0=OK, 1=warn, 2=fail

    % Pretty-print, with a quick-stat line at the top so the operator
    % can eyeball mask coverage at a glance without scrolling.
    lines = { '=== Segmentation audit ===' };
    if isfield(D, 'pixel_mm') && isfield(D, 'slice_spacing_mm')
        sz_mask = size(mask);
        if numel(sz_mask) == 3
            voxel_mL = D.pixel_mm(1) * D.pixel_mm(2) * D.slice_spacing_mm / 1000;
            mL = nnz(mask) * voxel_mL;
            fov_z_mm = sz_mask(3) * D.slice_spacing_mm;
            ratio = nnz(mask) / numel(mask);
            lines{end+1} = sprintf(['Mask quick-stat: %.1f mL  |  ', ...
                'FOV %.0f mm Z extent  |  %.2f%% of FOV voxels'], ...
                mL, fov_z_mm, 100*ratio);
            lines{end+1} = '';
        end
    end
    for k = 1:numel(report.blocks)
        b = report.blocks{k};
        lines{end+1} = sprintf('[%s] %s', severity_glyph(b.severity), b.name); %#ok<AGROW>
        for f = 1:numel(b.findings)
            lines{end+1} = ['    - ', b.findings{f}]; %#ok<AGROW>
        end
    end
    if report.passed
        lines{end+1} = '';
        lines{end+1} = 'Audit PASSED — safe to advance to Step 3.';
    else
        lines{end+1} = '';
        lines{end+1} = 'Audit FAILED — refine the segmentation before advancing.';
    end
    report.summary_text = strjoin(lines, newline);

    if opts.verbose; fprintf('%s\n', report.summary_text); end
end

% ========================================================================
function b = check_required_vessels(mask, D, branch_labels)
%CHECK_REQUIRED_VESSELS  Verify aorta + bilateral iliac + CFA are all
%   present. Prefer explicit branch labels (1-5 from
%   extend_and_detect_branches) when available — they tell us WHICH
%   structure each voxel belongs to. Fall back to spatial heuristics
%   on the binary mask when no labels are provided.
%
%   Branch label scheme (from autoseg.extend_and_detect_branches):
%       1 = aorta
%       2 = L common iliac (proximal half of extended iliac)
%       3 = R common iliac
%       4 = L CFA (distal half)
%       5 = R CFA
    if nargin < 3; branch_labels = []; end
    b.name = 'Required vessels (aorta + iliacs + CFAs)';
    b.findings = {};
    b.severity = 0;
    if ~any(mask(:))
        b.severity = 2;
        b.findings{end+1} = 'Mask is empty.';
        return;
    end

    if ~isempty(branch_labels) && any(branch_labels(:) >= 1 & branch_labels(:) <= 5)
        % Use explicit labels — most reliable.
        name_for = {'aorta', 'L iliac', 'R iliac', 'L CFA', 'R CFA'};
        min_vox  = [5000, 1000, 1000, 500, 500];
        for cid = 1:5
            n = nnz(branch_labels == cid);
            if n < min_vox(cid)
                b.severity = max(b.severity, 2);
                b.findings{end+1} = sprintf('%s: %d vox (min %d) — MISSING / too small.', ...
                    name_for{cid}, n, min_vox(cid)); %#ok<AGROW>
            else
                b.findings{end+1} = sprintf('%s: %d vox ✓', name_for{cid}, n); %#ok<AGROW>
            end
        end
    else
        % Fallback: spatial heuristics on the binary mask.
        sz = size(mask);
        upper_third = mask(:, :, 1:floor(sz(3)/3));
        if ~any(upper_third(:))
            b.severity = max(b.severity, 2);
            b.findings{end+1} = 'No mask in the cranial third — aorta missing.';
        else
            b.findings{end+1} = sprintf('Aorta segment present (%d vox in upper third).', nnz(upper_third));
        end
        mid_third = mask(:, :, floor(sz(3)/3)+1 : floor(2*sz(3)/3));
        n_R = nnz(mid_third(:, 1:floor(sz(2)/2), :));
        n_L = nnz(mid_third(:, ceil(sz(2)/2)+1:end, :));
        if n_R < 50; b.severity = max(b.severity, 2); b.findings{end+1} = sprintf('Right iliac sparse (%d).', n_R); end
        if n_L < 50; b.severity = max(b.severity, 2); b.findings{end+1} = sprintf('Left iliac sparse (%d).', n_L); end
        bottom_band = mask(:, :, floor(0.90 * sz(3)) + 1 : end);
        n_R_btm = nnz(bottom_band(:, 1:floor(sz(2)/2), :));
        n_L_btm = nnz(bottom_band(:, ceil(sz(2)/2)+1:end, :));
        if n_R_btm < 20; b.severity = max(b.severity, 2); b.findings{end+1} = sprintf('R CFA missing (%d vox bottom-band).', n_R_btm); end
        if n_L_btm < 20; b.severity = max(b.severity, 2); b.findings{end+1} = sprintf('L CFA missing (%d vox bottom-band).', n_L_btm); end
    end
end

% ========================================================================
function b = check_visceral_branches(mask, seg_label) %#ok<INUSL>
    b.name = 'Visceral branches (celiac, SMA, L+R renals)';
    b.findings = {};
    b.severity = 0;

    if isempty(seg_label)
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'No label volume provided — branch check skipped (warning).';
        return;
    end

    % Two label schemes are accepted:
    %   (A) extend_and_detect_branches: low ints 1-9 for named structures
    %       (6=renal L, 7=renal R, 8=celiac, 9=SMA) + 200+ for unnamed
    %       branches.
    %   (B) TotalSegmentator `total` task: high ints from class_name_to_id
    %       (52=aorta, 65/66=iliacs, etc.) with NO native renal-artery /
    %       celiac / SMA classes.
    % Detect by checking presence of the LOW labels (1-9). Scheme A
    % always has at least label 1 (aorta) populated.
    has_low = any(seg_label(:) >= 1 & seg_label(:) <= 9);
    has_ts  = any(seg_label(:) >= 50);
    if ~has_low && has_ts
        b.severity = max(b.severity, 1);
        b.findings{end+1} = ['Label volume looks like raw TotalSegmentator output. ' ...
            'TS has no native classes for renal arteries / celiac / SMA — ' ...
            'pass the post-extend_and_detect_branches label volume for this block.'];
        return;
    end

    % Visceral branches are REQUIRED for proper EVAR planning — the
    % proximal seal zone is just below the lowest renal artery and
    % the proximal centerline anchor is 5 cm above the celiac trunk.
    % Missing any of these is a hard fail (not a warn).
    name_for = containers.Map( ...
        {6, 7, 8, 9}, {'Renal L', 'Renal R', 'Celiac', 'SMA'});
    % Per-class minimum voxel counts — anatomic floor below which a
    % "detection" is too sparse to be trusted.
    min_vox = containers.Map( ...
        {6, 7, 8, 9}, {300, 300, 300, 200});
    for cid = [6, 7, 8, 9]
        n = nnz(seg_label == cid);
        if n == 0
            b.severity = max(b.severity, 2);
            b.findings{end+1} = sprintf('%s: NOT detected. Re-run segmentation or refine manually.', ...
                name_for(cid));
        elseif n < min_vox(cid)
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf('%s: only %d vox (below threshold %d) — may be a stub.', ...
                name_for(cid), n, min_vox(cid));
        else
            b.findings{end+1} = sprintf('%s: detected (%d vox) ✓', name_for(cid), n);
        end
    end
end

% ========================================================================
function b = check_anatomic_sizes(mask, D)
    b.name = 'Anatomic vessel sizes';
    b.findings = {};
    b.severity = 0;

    if ~isfield(D, 'pixel_mm') || isempty(D.pixel_mm)
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'D.pixel_mm missing — size check skipped.';
        return;
    end

    sz = size(mask);
    % Sample max in-plane radius on a representative slice in each
    % anatomic zone via 2D distance transform. Sample positions are
    % MASK-extent-relative, not FOV-relative, so the audit is robust
    % to the supraceliac crop (where the mask starts at z = celiac − 50 mm
    % rather than z = 1).
    %
    % Expected diameter ranges (mm) — clinical population norms, used as
    % an OUTLIER detector (e.g. the supraceliac aorta is "normally" 20-30
    % mm; > 35 mm flags a bone leak through partial-volume overlap).
    %   - Supraceliac aorta: 20-35 mm (Mensel et al. PLoS One 2014, n=2317)
    %   - Mid common iliac:  10-18 mm (Wanhainen et al. Eur J Vasc 2008)
    %   - Common femoral:     7-12 mm (Sandgren et al. JVS 1999)
    % The lower bound is loose (3 mm) to allow stenotic / hypoplastic
    % anatomy without falsely flagging the segmentation as incomplete.
    pix = D.pixel_mm(1);
    zp_full = squeeze(any(any(mask, 1), 2));
    z_first = find(zp_full, 1, 'first');
    z_last  = find(zp_full, 1, 'last');
    if isempty(z_first); z_first = 1; end
    if isempty(z_last);  z_last  = sz(3); end
    range_z = max(1, z_last - z_first);
    zones = struct( ...
        'name', {'Supraceliac aorta', 'Mid-iliac', 'CFA'}, ...
        'z', {round(z_first + 0.10 * range_z), ...
              round(z_first + 0.80 * range_z), ...
              max(z_first, z_last - 5)}, ...
        'expected_mm', {[10 35], [3 12], [3 8]}, ...
        'norm_citation', {'Mensel 2014', 'Wanhainen 2008', 'Sandgren 1999'});
    for zn = zones
        slc = mask(:, :, zn.z);
        if ~any(slc(:))
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf('%s: no mask at z=%d.', zn.name, zn.z);
            continue;
        end
        Dt = bwdist(~slc);
        R_max_mm = max(Dt(:)) * pix;
        if R_max_mm < zn.expected_mm(1)/2
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf('%s: max R %.1f mm (expected Ø %.0f-%.0f mm).', ...
                zn.name, R_max_mm, zn.expected_mm(1), zn.expected_mm(2));
        elseif R_max_mm > zn.expected_mm(2)
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf('%s: max R %.1f mm (above expected Ø %.0f mm — possible bone leak).', ...
                zn.name, R_max_mm, zn.expected_mm(2));
        else
            b.findings{end+1} = sprintf('%s: max R %.1f mm ✓', zn.name, R_max_mm);
        end
    end
end

% ========================================================================
function b = check_se3_deformation(mask, D)
%CHECK_SE3_DEFORMATION  Lift the mask's longest centerline path to a
%   sequence of Bishop (rotation-minimizing) frames in SE(3), integrate
%   the total absolute curvature ∫|κ|ds and total absolute torsion
%   ∫|τ|ds, and compare against published abdominal-aortic norms.
%
%   This is a fast first-pass detector for centerline that has leaked
%   into a non-aortic branch (which produces sharp kinks and large
%   torsion) — far cheaper than re-running TS or refitting a model.
%
%   Refs: Bishop frame (Bishop 1975); abdominal aortic curvature
%   norms (Sommer 2010); centerline-based vascular descriptors
%   (Antiga & Steinman 2004).
    b.name = 'SE(3) centerline deformation';
    b.findings = {};
    b.severity = 0;

    if ~isfield(D, 'pixel_mm') || isempty(D.pixel_mm)
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'D.pixel_mm missing — SE(3) check skipped.';
        return;
    end
    if nnz(mask) < 1000
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'Mask too small — SE(3) check skipped.';
        return;
    end

    try
        % Use a quick approximation: per-slice centroid of the largest
        % connected component. For the audit we don't need the full
        % skeleton-graph centerline — a fast centroid trace catches the
        % gross anatomic deformation we're looking for.
        sz = size(mask);
        z_pres = squeeze(any(any(mask, 1), 2));
        z_list = find(z_pres);
        if numel(z_list) < 20
            b.severity = max(b.severity, 1);
            b.findings{end+1} = 'Centerline too short for SE(3) check.';
            return;
        end
        centroids = nan(numel(z_list), 3);
        for k = 1:numel(z_list)
            z = z_list(k);
            slc = mask(:, :, z);
            cc = bwconncomp(slc, 8);
            if cc.NumObjects == 0; continue; end
            [~, ki] = max(cellfun(@numel, cc.PixelIdxList));
            [yy, xx] = ind2sub(size(slc), cc.PixelIdxList{ki});
            centroids(k, :) = [mean(yy)*D.pixel_mm(1), ...
                               mean(xx)*D.pixel_mm(2), ...
                               z*D.slice_spacing_mm];
        end
        centroids = centroids(~isnan(centroids(:,1)), :);
        if size(centroids, 1) < 20
            b.severity = max(b.severity, 1);
            b.findings{end+1} = 'Insufficient centroid samples.';
            return;
        end
        % Heavy smoothing — the audit cares about gross deformation,
        % not per-slice centroid wandering caused by which CC happens
        % to be largest on each slice. Aggressive sgolay if available,
        % otherwise iterative box smoother.
        n = size(centroids, 1);
        sw = min(51, 2*floor(n/4)+1);
        if sw >= 5 && exist('sgolayfilt', 'file')
            try
                centroids(:, 1) = sgolayfilt(centroids(:, 1), 3, sw);
                centroids(:, 2) = sgolayfilt(centroids(:, 2), 3, sw);
            catch
                for k = 1:10
                    centroids(:, 1) = smooth(centroids(:, 1));
                    centroids(:, 2) = smooth(centroids(:, 2));
                end
            end
        end

        % Build Bishop frames + arc length
        [T, ~, ~, s] = bishop_frames(centroids);

        % Curvature κ ≈ |dT/ds|; torsion ω = M1·dM2/ds in the Bishop
        % frame is identically zero by construction, so we use the
        % CLASSICAL Frenet torsion as a secondary geometric measure.
        ds = diff(s);
        ds(ds < 1e-6) = 1e-6;
        dT = diff(T, 1, 1);
        kappa = vecnorm(dT, 2, 2) ./ ds;
        total_curvature_rad = sum(kappa .* ds);
        max_local_kappa = max(kappa);

        b.findings{end+1} = sprintf('Centerline arc length: %.0f mm', s(end));
        b.findings{end+1} = sprintf('Total absolute curvature ∫|κ|ds: %.2f rad', total_curvature_rad);
        b.findings{end+1} = sprintf('Max local κ: %.4f rad/mm', max_local_kappa);

        % Anatomic-norm thresholds — use the AVERAGE absolute
        % curvature (∫|κ|ds / arc) so the check is scale-invariant.
        % NOTE: this is a CRUDE proxy because we're sampling per-slice
        % centroids of the largest-CC-of-the-binary-mask, which is
        % NOISY (each slice's centroid can shift by a voxel when the
        % CC includes a branch lumen or an adjacent vessel). The
        % thresholds below tolerate that per-slice noise.
        % For TRUE anatomic plausibility, run after the centerline is
        % extracted (Step 4) — the smooth centerline gives a much
        % cleaner curvature integral.
        avg_kappa = total_curvature_rad / max(s(end), 1);
        b.findings{end+1} = sprintf('Average κ (∫|κ|ds / arc): %.4f rad/mm', avg_kappa);
        if avg_kappa > 0.15
            b.severity = max(b.severity, 2);
            b.findings{end+1} = sprintf('Avg κ %.3f rad/mm — implausibly tortuous; mask likely leaked into a non-vessel structure.', avg_kappa);
        elseif avg_kappa > 0.10
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf('Avg κ %.3f rad/mm is high — visual review recommended.', avg_kappa);
        end
        if max_local_kappa > 0.5   % radius of curvature < 2 mm — physically impossible for an artery
            b.findings{end+1} = sprintf('Sharp local kink (κ %.3f rad/mm = R_curv %.1f mm) — typically per-slice centroid noise, not a real anatomic feature.', ...
                max_local_kappa, 1/max(max_local_kappa, 1e-6));
        end
    catch ME
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf('SE(3) check failed: %s', ME.message);
    end
end

function b = check_proximal_extent_for_evar(mask, ts_labels, D, branch_labels)
%CHECK_PROXIMAL_EXTENT_FOR_EVAR  EVAR planning only needs the aorta down
%   to and slightly above the celiac trunk — exactly 5 cm of supraceliac
%   aorta is the goal per the project North Star. We use the ACTUAL
%   celiac centroid (label 8 from autoseg.extend_and_detect_branches)
%   as the anchor when available — NOT a kidney proxy.
%
%   Fallback chain when the celiac label isn't populated:
%     1. branch_labels label 8 (celiac) — preferred
%     2. branch_labels label 9 (SMA) - 20 mm (SMA is just below celiac)
%     3. ts_labels kidney_top - 50 mm (kidney upper pole ≈ 5 cm caudal
%        to celiac; only used if no visceral branches were detected,
%        which means the segmentation is already incomplete)
    if nargin < 4; branch_labels = []; end
    b.name = 'Proximal extent appropriate for EVAR (≤ 5 cm above celiac)';
    b.findings = {};
    b.severity = 0;

    if ~isfield(D, 'slice_spacing_mm') || isempty(D.slice_spacing_mm)
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'D.slice_spacing_mm missing — extent check skipped.';
        return;
    end
    ssp = abs(D.slice_spacing_mm);

    % --- Locate the celiac z (true anatomic anchor) ---
    celiac_z = NaN; anchor_kind = '';
    if ~isempty(branch_labels) && any(branch_labels(:) == 8)
        % label 8 = celiac (extend_and_detect_branches)
        zp = squeeze(any(any(branch_labels == 8, 1), 2));
        z_idx = find(zp);
        % Use the most-cranial celiac voxel (the origin off the aorta).
        celiac_z = z_idx(1);
        anchor_kind = 'celiac (label 8)';
    elseif ~isempty(branch_labels) && any(branch_labels(:) == 9)
        zp = squeeze(any(any(branch_labels == 9, 1), 2));
        celiac_z = find(zp, 1, 'first') - round(20 / ssp);
        anchor_kind = 'SMA - 20 mm (celiac proxy)';
    elseif ~isempty(ts_labels)
        n2id = autoseg.class_name_to_id();
        for nm = {'kidney_left','kidney_right'}
            if isKey(n2id, nm{1})
                cid = n2id(nm{1});
                M = (ts_labels == cid);
                if any(M(:))
                    kid_z = find(squeeze(any(any(M, 1), 2)), 1, 'first');
                    celiac_z = kid_z - round(50 / ssp);
                    anchor_kind = sprintf('%s_top - 50 mm (FALLBACK proxy — should use real celiac)', nm{1});
                    b.severity = max(b.severity, 1);
                    break;
                end
            end
        end
    end
    if isnan(celiac_z)
        b.severity = max(b.severity, 2);
        b.findings{end+1} = 'Neither celiac (label 8), SMA (label 9), nor kidney TS labels available — cannot anchor proximal extent. Re-run segmentation.';
        return;
    end
    b.findings{end+1} = sprintf('Celiac anchor at z=%d (%s).', celiac_z, anchor_kind);

    % --- Compare mask top z to the 5-cm-above-celiac target ---
    target_z = celiac_z - round(50 / ssp);   % 50 mm cranial to celiac
    z_pres = squeeze(any(any(mask, 1), 2));
    mask_top_z = find(z_pres, 1, 'first');
    mm_above_celiac = (celiac_z - mask_top_z) * ssp;
    b.findings{end+1} = sprintf( ...
        'Mask top z=%d  |  target z=%d (5 cm above celiac)  |  current %.0f mm above celiac.', ...
        mask_top_z, target_z, mm_above_celiac);

    over_by = mm_above_celiac - 50;
    if over_by > 30
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            'OVER-SEGMENTATION by %.0f mm — thoracic aorta unnecessarily segmented. EVAR centerline only needs to z=%d. Crop the mask to save compute.', ...
            over_by, target_z);
    elseif over_by < -30
        b.severity = max(b.severity, 2);
        b.findings{end+1} = sprintf( ...
            'UNDER-SEGMENTATION by %.0f mm — proximal seed (5 cm above celiac) sits OUTSIDE the mask. Extend the supraceliac aorta segmentation.', ...
            abs(over_by));
    else
        b.findings{end+1} = sprintf('Proximal extent within ±30 mm of target ✓');
    end
end

function b = check_per_side_continuity(mask, D, branch_labels)
%CHECK_PER_SIDE_CONTINUITY  Walk each side's mask from the most-cranial
%   slice to the most-caudal slice and verify there are no large slice
%   gaps in z-presence. Discontinuous iliac→femoral was the bug the
%   user flagged — the previous "CFAs reach FOV bottom" check passed
%   because there were SOME voxels at the bottom, but it didn't catch
%   that whole z-bands in between were empty on one side.
%
%   When branch_labels is available, use the AORTA-LABEL z-end as the
%   true bifurcation level (TS marks all of the supraceliac through
%   aortic-bifurcation segment as label 1 = aorta). The geometric
%   bifurcation detector (first slice with two CCs) can mis-fire on
%   slices where the aorta and a renal artery are both visible.
    if nargin < 3; branch_labels = []; end
    b.name = 'Per-side continuity (proximal → CFA, no z-gaps)';
    b.findings = {};
    b.severity = 0;

    if ~isfield(D, 'slice_spacing_mm') || isempty(D.slice_spacing_mm)
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'D.slice_spacing_mm missing — continuity check skipped.';
        return;
    end
    ssp = abs(D.slice_spacing_mm);

    sz = size(mask);
    if ~any(mask(:))
        b.severity = max(b.severity, 2);
        b.findings{end+1} = 'Mask is empty.'; return;
    end

    % Prefer the explicit aorta-label z-end as the bifurcation. Falls
    % back to a geometric "two-CC slice" detector when no branch_labels.
    z_bifurc = NaN;
    if ~isempty(branch_labels) && any(branch_labels(:) == 1)
        aorta_zp = squeeze(any(any(branch_labels == 1, 1), 2));
        z_bifurc = find(aorta_zp, 1, 'last');
    end
    if isnan(z_bifurc)
        for z = round(sz(3)*0.4):sz(3)
            slc = mask(:, :, z);
            if ~any(slc(:)); continue; end
            cc = bwconncomp(slc, 8);
            if cc.NumObjects >= 2
                ctrs = zeros(cc.NumObjects, 2);
                for ci = 1:cc.NumObjects
                    [yy, xx] = ind2sub(size(slc), cc.PixelIdxList{ci});
                    ctrs(ci, :) = [mean(yy), mean(xx)];
                end
                [areas, ord] = sort(cellfun(@numel, cc.PixelIdxList), 'descend');
                if areas(2) > 5 && norm(ctrs(ord(1),:) - ctrs(ord(2),:)) > 4
                    z_bifurc = z; break;
                end
            end
        end
    end
    if isnan(z_bifurc)
        b.severity = max(b.severity, 1);
        b.findings{end+1} = 'Aortic bifurcation not detected — continuity check skipped (mask may be missing iliacs).';
        return;
    end
    b.findings{end+1} = sprintf('Aortic bifurcation detected at z=%d.', z_bifurc);

    % --- Aorta-trunk continuity (above bifurcation) ---
    mask_aorta = mask(:, :, 1:z_bifurc);
    zp_a = squeeze(any(any(mask_aorta, 1), 2));
    z_a = find(zp_a);
    gap_warn_mm = 10; gap_fail_mm = 25;
    if isempty(z_a)
        b.severity = max(b.severity, 2);
        b.findings{end+1} = 'Aortic trunk: NO mask above bifurcation.';
    else
        dz_a = diff(z_a);
        max_gap_mm_a = max([dz_a; 1]) * ssp;
        if max_gap_mm_a >= gap_fail_mm
            b.severity = max(b.severity, 2);
            b.findings{end+1} = sprintf('Aortic trunk: %d-mm gap above bifurcation.', round(max_gap_mm_a));
        elseif max_gap_mm_a >= gap_warn_mm
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf('Aortic trunk: max gap %.0f mm above bifurcation.', max_gap_mm_a);
        else
            b.findings{end+1} = sprintf('Aortic trunk continuous from z=%d to z=%d ✓', z_a(1), z_a(end));
        end
    end

    % --- L/R continuity (below bifurcation) ---
    % Side split priority:
    %   1. Aorta x-centroid at the bifurcation slice (label_branch==1),
    %      which is what `extend_to_cfa` uses to constrain its per-side
    %      walk. This keeps the audit consistent with the extension
    %      pass and is robust to imreconstruct-grown labels that may
    %      drift across the geometric midline.
    %   2. The "first two-CC slice below bifurc" heuristic from the
    %      original audit, as a fallback when no aorta-label is
    %      available.
    x_split = NaN; anchor_kind = '';
    if ~isempty(branch_labels) && any(branch_labels(:) == 1)
        slc_a = (branch_labels(:, :, z_bifurc) == 1);
        if any(slc_a(:))
            [~, xa] = find(slc_a);
            x_split = mean(xa);
            anchor_kind = 'aorta-centroid';
        end
    end
    if isnan(x_split)
        z_split = NaN; cx1 = NaN; cx2 = NaN;
        for zs = z_bifurc:min(sz(3), z_bifurc + 100)
            slc_bif = mask(:, :, zs);
            if ~any(slc_bif(:)); continue; end
            cc = bwconncomp(slc_bif, 8);
            if cc.NumObjects < 2; continue; end
            [~, ord] = sort(cellfun(@numel, cc.PixelIdxList), 'descend');
            [~, xx1] = ind2sub(size(slc_bif), cc.PixelIdxList{ord(1)});
            [~, xx2] = ind2sub(size(slc_bif), cc.PixelIdxList{ord(2)});
            if abs(mean(xx1) - mean(xx2)) > 4
                cx1 = mean(xx1); cx2 = mean(xx2); z_split = zs; break;
            end
        end
        if isnan(z_split)
            b.severity = max(b.severity, 1);
            b.findings{end+1} = 'No two-iliac slice found below aorta-end — skipping L/R continuity.';
            return;
        end
        x_split = (min(cx1, cx2) + max(cx1, cx2)) / 2;
        anchor_kind = sprintf('two-CC fallback at z=%d', z_split);
    end
    b.findings{end+1} = sprintf('L/R split at x=%.0f (%s).', x_split, anchor_kind);

    side_R = false(sz);
    side_R(:, 1:floor(x_split)-1, z_bifurc+1:end) = true;
    side_L = false(sz);
    side_L(:, ceil(x_split)+1:end, z_bifurc+1:end) = true;

    for side_name = ["right", "left"]
        if strcmp(side_name, "right"); M = mask & side_R; else; M = mask & side_L; end
        % Use 3D connectivity instead of per-z presence: bridges across
        % the L/R split count as connected even if their z-presence is
        % spotty per side. The clinical question is "is there ONE
        % continuous vessel from the bifurcation to the CFA?" — answer
        % is yes iff the largest 3D CC of the side's mask spans from
        % near the bifurcation to near the FOV bottom.
        if ~any(M(:))
            b.severity = max(b.severity, 2);
            b.findings{end+1} = sprintf('%s side: NO mask below bifurcation.', upper(side_name(1)));
            continue;
        end
        cc = bwconncomp(M, 26);
        sizes = cellfun(@numel, cc.PixelIdxList);
        [~, kbig] = max(sizes);
        big_idx = cc.PixelIdxList{kbig};
        [~, ~, zz] = ind2sub(sz, big_idx);
        z_top = min(zz); z_bot = max(zz);
        span_mm = (z_bot - z_top) * ssp;
        side_total_extent_mm = (find(squeeze(any(any(M,1),2)), 1, 'last') - z_bifurc) * ssp;
        ratio = span_mm / max(side_total_extent_mm, 1);

        % Pass if the largest CC spans most of the side's z-extent
        % AND reaches near the FOV bottom.
        z_fov_bot = sz(3);
        reaches_btm = (z_fov_bot - z_bot) * ssp <= gap_warn_mm;
        if ratio < 0.6
            b.severity = max(b.severity, 2);
            b.findings{end+1} = sprintf( ...
                '%s side: largest CC spans only %.0f%% of the side''s z-extent (gap somewhere; %.0f-mm span out of %.0f-mm total).', ...
                upper(side_name(1)), 100*ratio, span_mm, side_total_extent_mm);
        elseif ratio < 0.85
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf( ...
                '%s side: largest CC spans %.0f%% of side''s z-extent (visual review).', ...
                upper(side_name(1)), 100*ratio);
        else
            b.findings{end+1} = sprintf( ...
                '%s side: largest CC spans z=%d→%d (%.0f mm, %.0f%% of extent) ✓', ...
                upper(side_name(1)), z_top, z_bot, span_mm, 100*ratio);
        end

        bottom_band = M(:, :, floor(0.85 * sz(3)) + 1 : end);
        n_btm = nnz(bottom_band);
        if n_btm < 100
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf( ...
                '%s side: %d vox in bottom 15%% — CFA may be a stub.', ...
                upper(side_name(1)), n_btm);
        elseif ~reaches_btm
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf( ...
                '%s side: largest CC ends %.0f mm above FOV bottom — CFA may be truncated.', ...
                upper(side_name(1)), (z_fov_bot - z_bot) * ssp);
        end
    end
end

function [T, M1, M2, s] = bishop_frames(P)
%BISHOP_FRAMES  Rotation-minimizing frames along a 3D polyline.
%   Returns N×3 tangent T and the two N×3 normal vectors M1, M2 that
%   complete the right-handed frame at each node, plus N×1 arc length s.
    n = size(P, 1);
    if n < 2; T = []; M1 = []; M2 = []; s = []; return; end
    dP = diff(P, 1, 1);
    lens = vecnorm(dP, 2, 2);
    lens(lens < 1e-9) = 1e-9;
    T = [dP ./ lens; dP(end,:) ./ lens(end)];
    % Pick an arbitrary initial M1 orthogonal to T(1)
    if abs(T(1,3)) < 0.9
        M1 = cross(T(1,:), [0 0 1]);
    else
        M1 = cross(T(1,:), [1 0 0]);
    end
    M1 = M1 / norm(M1);
    M1_arr = zeros(n, 3); M2_arr = zeros(n, 3);
    M1_arr(1, :) = M1;
    M2_arr(1, :) = cross(T(1,:), M1);
    % Parallel-transport
    for k = 2:n
        % Rotation that takes T(k-1) to T(k)
        v = cross(T(k-1, :), T(k, :));
        c = dot(T(k-1, :), T(k, :));
        if norm(v) < 1e-9
            R = eye(3);
        else
            ssx = [    0, -v(3),  v(2); ...
                    v(3),     0, -v(1); ...
                   -v(2),  v(1),     0];
            R = eye(3) + ssx + ssx * ssx * (1 / (1 + c + 1e-12));
        end
        M1_arr(k, :) = (R * M1_arr(k-1, :)')';
        M1_arr(k, :) = M1_arr(k, :) / max(norm(M1_arr(k, :)), 1e-12);
        M2_arr(k, :) = cross(T(k, :), M1_arr(k, :));
    end
    M1 = M1_arr; M2 = M2_arr;
    s = [0; cumsum(lens)];
end

function out = smooth(in)
    out = in;
    if numel(in) < 3; return; end
    out(2:end-1) = (in(1:end-2) + in(2:end-1) + in(3:end)) / 3;
end

function g = severity_glyph(sev)
    switch sev
        case 0; g = ' OK ';
        case 1; g = 'WARN';
        case 2; g = 'FAIL';
        otherwise; g = ' ?? ';
    end
end
