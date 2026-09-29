function meas = measure_from_centerline(planner_result, opts)
%EVAR_PLAN.MEASURE_FROM_CENTERLINE  Derive EVAR sizing measurements from
%   the auto-planner centerline result.
%
%   MEAS = evar_plan.measure_from_centerline(PLANNER_RESULT)
%   MEAS = evar_plan.measure_from_centerline(PLANNER_RESULT, OPTS)
%
%   OPTS fields (all optional, sensible defaults):
%       .aneurysm_R_mm        14   — R > this is considered aneurysmal
%       .iliac_window_mm      10   — distal averaging window for iliac Ø
%       .angulation_seg_mm    30   — length of each tangent-sample segment
%       .bifurc_threshold_mm   5   — R/L divergence threshold (mm) used
%                                    to locate the aortic bifurcation
%       .cia_offset_mm        20   — distance distal to the bifurcation
%                                    where iliac Ø is measured (common
%                                    iliac landing zone, not the CFA)
%       .supraceliac_skip_mm  40   — skip the first N mm of arc when
%                                    searching for the infrarenal neck
%       .neck_search_mm       150  — search-window length for the neck
%       .neck_grow_frac       0.20 — fractional R rise that defines the
%                                    aneurysm start / proximal neck edge
%
%   Takes the struct returned by run_planner_headless and extracts:
%       .neck_diameter_mm        proximal aortic neck lumen Ø — measured
%                                over the proximal opts.seal_zone_mm of
%                                the infrarenal neck (the graft's proximal
%                                landing zone), at the neck caliber.
%                                Deliberately NOT averaged through the
%                                dilating segment up to the aneurysm.
%       .neck_length_mm          non-aneurysmal infrarenal neck length:
%                                from the lower margin of the lowest renal
%                                ostium to the first sustained point where
%                                the lumen exceeds the reference neck
%                                caliber by opts.neck_length_growth_frac
%                                (10%) or crosses opts.aneurysm_R_mm,
%                                whichever is first. NaN when no aneurysm
%                                onset is detected (see .aneurysm_detected).
%       .neck_landmark           'lowest_renal' (anatomic, from renal
%                                labels 6/7) or 'heuristic' (fallback when
%                                no renal labels: fixed supraceliac skip +
%                                narrowing — can start above the celiac and
%                                over-call neck length; verify on CT).
%       .lowest_renal_side       'L' | 'R' | '' — side of the lowest renal.
%       .bifurcation_source      'iliac_labels' (first slice with both iliac
%                                labels — the anatomic bifurcation) or
%                                'centerline_divergence' (fallback; in an
%                                aneurysm sac the two centerlines diverge
%                                ABOVE the true bifurcation).
%       .aneurysm_detected       logical — true when an aneurysm onset
%                                (R > opts.aneurysm_R_mm) was found in the
%                                proximal-aorta search window.
%       .diameter_basis          'lumen' — every diameter here is a
%                                contrast-lumen diameter (TS segments
%                                lumen only); it EXCLUDES mural thrombus /
%                                outer wall and is not the true sac Ø.
%       .neck_angulation_alpha_deg  suprarenal-to-neck angle (alpha):
%                                suprarenal aortic axis vs infrarenal neck
%                                axis, over fixed-mm windows.
%       .neck_angulation_beta_deg   infrarenal neck-to-sac angle (beta):
%                                infrarenal neck axis vs aneurysm-sac
%                                axis. NaN when no aneurysm. This is what
%                                most vendor IFUs limit on.
%       .neck_angulation_deg     = neck_angulation_beta_deg (the
%                                canonical angle for IFU eligibility)
%       .iliac_R_diameter_mm     R-CFA terminus diameter (mean of last
%                                opts.iliac_window_mm of arc)
%       .iliac_L_diameter_mm     L-CFA terminus diameter
%       .iliac_R_length_mm       R path length, bifurcation → centerline
%                                terminus (CIA+EIA+CFA). NOT a seal length.
%       .iliac_L_length_mm       L path length (same caveat)
%       .iliac_R/L_seal_length_mm  common-iliac seal length — NaN: the
%                                pipeline labels don't separate CIA/EIA, so
%                                the IFU iliac-seal criterion is reported
%                                as not assessed.
%       .max_aneurysm_R_mm       peak lumen R along the centerline
%       .aneurysm_max_diameter_mm  schema-aligned diameter = 2 ×
%                                  max_aneurysm_R_mm (both emitted)
%       .bifurcation_angle_deg   angle ∈ [0, 180] between the two iliac
%                                trunks measured 20 mm distal to the
%                                aortic bifurcation (iliac take-off
%                                angle — wide values can compromise
%                                stent-graft seating)
%
%   ALL measurements are RESEARCH-ONLY estimates derived from the auto-
%   detected centerline. They should NOT be used for clinical decision
%   making without operator review against the source CT.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        planner_result (1,1) struct
        opts           (1,1) struct = struct()
    end
    if ~isfield(opts, 'aneurysm_R_mm');     opts.aneurysm_R_mm     = 14;   end
    if ~isfield(opts, 'iliac_window_mm');   opts.iliac_window_mm   = 10;   end
    if ~isfield(opts, 'angulation_seg_mm'); opts.angulation_seg_mm = 30;   end

    pr = planner_result;

    % NORMALIZE polyline direction. Callers may pass either:
    %   (a) PROXIMAL → DISTAL  (first node = suprarenal aorta)
    %   (b) DISTAL  → PROXIMAL (first node = CFA — GUI + headless convention)
    % The rest of this function assumes (a). Detect direction from the
    % radius profile (the proximal aorta is the FATTEST end) and reverse
    % the polyline + radius if the first node has a smaller radius than
    % the last. Without this normalization, the neck-detection logic
    % searches in the iliac region and reports an iliac diameter as the
    % proximal neck (off by 3-4×).
    pr = normalize_direction(pr);

    % Find the bifurcation GEOMETRICALLY from the two centerlines —
    % they share the same proximal trunk and diverge at the aortic
    % bifurcation. Walking from the proximal end, the first arc-length
    % index where the two points are > opts.bifurc_threshold_mm apart
    % is the bifurcation.
    if ~isfield(opts, 'bifurc_threshold_mm'); opts.bifurc_threshold_mm = 5; end
    [bifurc_arc_R, bifurc_arc_L] = find_bifurcation( ...
        pr.Pv_mm_right, pr.Pv_mm_left, opts.bifurc_threshold_mm);
    % Prefer the ANATOMIC bifurcation from the iliac labels. In an
    % aneurysm sac the two VMTK centerlines (one per CFA) diverge INSIDE
    % the sac, well above the flow divider, so the centerline-divergence
    % point can sit tens of mm too high — mis-placing the iliac-diameter
    % sampling point and the aorta's distal end. (Found on a real case:
    % divergence at slice ~383 vs iliac origin at ~456, 0.5 mm slices.)
    meas.bifurcation_source = 'centerline_divergence';
    [bR, bL] = anatomic_bifurcation_arcs(pr);
    if ~isnan(bR) && ~isnan(bL)
        bifurc_arc_R = bR; bifurc_arc_L = bL;
        meas.bifurcation_source = 'iliac_labels';
    end

    [meas.iliac_R_diameter_mm, meas.iliac_R_length_mm, arc_R] = ...
        side_measurements(pr.Pv_mm_right, pr.R_mm_right, bifurc_arc_R, opts);
    [meas.iliac_L_diameter_mm, meas.iliac_L_length_mm, ~] = ...
        side_measurements(pr.Pv_mm_left,  pr.R_mm_left,  bifurc_arc_L, opts);
    % iliac_*_length_mm is the bifurcation-to-terminus PATH length (CIA +
    % EIA + CFA, typically 150-250 mm) — NOT a seal-zone length. The IFU
    % iliac seal criterion needs the common-iliac length (bifurcation to
    % internal-iliac origin), and the pipeline labels do not separate
    % CIA from EIA, so it is reported as not measurable (NaN) rather than
    % letting a 200 mm path length pass a 10-15 mm seal minimum vacuously.
    meas.iliac_R_seal_length_mm = NaN;
    meas.iliac_L_seal_length_mm = NaN;

    % Use the right branch for neck measurements (left branch shares the
    % same proximal segment). Find the aneurysm start: first arc where
    % R > aneurysm_R_mm.
    Pv = pr.Pv_mm_right;
    R  = pr.R_mm_right;
    arc = arc_R;

    % --- Identify the infrarenal neck and the aneurysm ----
    % Strategy: the proximal seed is ~5 cm above the celiac. The first
    % 40-50 mm of arc is supraceliac (where the aorta can run wide). The
    % infrarenal NECK is the narrowest non-aneurysmal segment below the
    % renals and above the aneurysm. We:
    %   (a) skip the first opts.supraceliac_skip_mm of arc;
    %   (b) find the global minimum of R over the next opts.neck_search_mm —
    %       this is the neck baseline R;
    %   (c) walk distally from there until R rises by opts.neck_grow_frac —
    %       that's the start of the aneurysm;
    %   (d) walk proximally from the min until R rises by opts.neck_grow_frac —
    %       that's the renal-level (proximal-end-of-neck).
    %
    % The neck length = arc between (d) and (c).
    if ~isfield(opts, 'supraceliac_skip_mm'); opts.supraceliac_skip_mm = 40; end
    if ~isfield(opts, 'neck_search_mm');     opts.neck_search_mm     = 150; end
    if ~isfield(opts, 'neck_grow_frac');     opts.neck_grow_frac     = 0.20; end
    % Proximal sealing-zone length over which the neck diameter is
    % measured (graft proximal landing zone, just infrarenal). The neck
    % Ø is the lumen Ø at this seal zone — NOT an average taken through
    % the dilating segment up to the aneurysm (which over-calls it).
    if ~isfield(opts, 'seal_zone_mm');       opts.seal_zone_mm       = 15; end
    % Aneurysm-onset hysteresis: R must exceed opts.aneurysm_R_mm and STAY
    % above it over at least this many mm of arc for onset to fire, so a
    % single spuriously-wide slice (partial-volume / segmentation noise)
    % cannot flip the onset location. Default 3 mm is short enough that a
    % genuine sac (a sustained dilation) is detected at the same node as a
    % bare first-crossing, but long enough to reject lone spikes — this is
    % what makes neck length + beta reproducible under resampling.
    if ~isfield(opts, 'aneurysm_min_run_mm'); opts.aneurysm_min_run_mm = 3; end

    % Aneurysm START detection: walking from the proximal end, the
    % first arc-length where R exceeds opts.aneurysm_R_mm marks where
    % the lumen starts dilating into the sac. The NECK is the segment
    % IMMEDIATELY PROXIMAL to that — bounded distally by the aneurysm
    % start and proximally by either the supraceliac transition or the
    % polyline start.
    %
    % This is more robust than searching for the global R-minimum
    % between supraceliac_skip and search_end (the previous strategy),
    % which can pick the DISTAL neck (just above the bifurcation) on a
    % case where the distal neck is narrower than the proximal one.
    % Neck length ends where the lumen exceeds the reference neck caliber
    % (measured just below the lowest renal) by this fraction — the
    % "length within 10% of the infrarenal diameter" convention — or at the
    % absolute aneurysm threshold, whichever comes first.
    if ~isfield(opts, 'neck_length_growth_frac'); opts.neck_length_growth_frac = 0.10; end
    if ~isfield(opts, 'neck_ref_mm');             opts.neck_ref_mm             = 5;    end

    % --- ANATOMIC path: anchor the neck on the lowest renal ostium ------
    % When the planner result carries branch labels with renal arteries
    % (6/7), the proximal neck boundary is the lower margin of the lowest
    % renal ostium — not a radius heuristic. The heuristic below (fixed
    % supraceliac skip + narrowing) is kept only as a flagged fallback: it
    % can start the neck above the celiac and over-call neck length.
    [renal_idx, lr] = renal_anchor(pr, Pv, arc, bifurc_arc_R);
    meas.neck_landmark = 'heuristic';
    meas.lowest_renal_side = '';
    if ~isempty(renal_idx)
        meas.neck_landmark = 'lowest_renal';
        meas.lowest_renal_side = lr.side;
        [seal_start_idx, aneurysm_idx, neck_end_idx, aneurysm_detected, ...
            neck_dia_mm, R_neck] = renal_anchored_neck(arc, R, renal_idx, ...
            bifurc_arc_R, opts);
        if aneurysm_detected
            meas.neck_length_mm = max(0, arc(neck_end_idx) - arc(seal_start_idx));
        else
            meas.neck_length_mm = NaN;
        end
    else
    idx_search_start = find(arc >= opts.supraceliac_skip_mm, 1, 'first');
    if isempty(idx_search_start); idx_search_start = 1; end
    idx_search_end = find(arc >= arc(idx_search_start) + opts.neck_search_mm, 1, 'first');
    if isempty(idx_search_end); idx_search_end = numel(R); end

    % Aneurysm onset in [search_start, search_end], WITH hysteresis: the
    % first node that begins a run of R > threshold spanning at least
    % opts.aneurysm_min_run_mm of arc. A lone over-threshold spike is
    % skipped; the reported onset is the first sustained dilation.
    seg_over = R(idx_search_start:idx_search_end) > opts.aneurysm_R_mm;
    seg_arc  = arc(idx_search_start:idx_search_end);
    aneurysm_rel = first_sustained_run(seg_over, seg_arc, opts.aneurysm_min_run_mm);
    aneurysm_detected = ~isempty(aneurysm_rel);
    if isempty(aneurysm_rel)
        % No aneurysm in the proximal aorta. We still need to return a
        % sensible "neck" diameter — clinically this is the proximal
        % aortic diameter at the candidate seal zone. Constrain the
        % search to the PROXIMAL-aorta portion of the polyline (above
        % the bifurcation) so we don't accidentally measure the iliac
        % diameter. Use the bifurc arc length as the upper bound; if
        % find_bifurcation didn't return one, fall back to the first
        % half of the polyline.
        if ~isnan(bifurc_arc_R) && bifurc_arc_R > 0
            idx_aorta_end = find(arc >= bifurc_arc_R - 5, 1, 'first');
        else
            idx_aorta_end = round(numel(R) / 2);
        end
        if isempty(idx_aorta_end) || idx_aorta_end <= idx_search_start
            idx_aorta_end = min(numel(R), idx_search_start + 10);
        end
        % Seal-zone = first ~30 mm of proximal aorta below the search
        % start. Diameter = mean R in that window. This is the right
        % answer for a non-aneurysmal proximal aorta — the planner is
        % reporting "the diameter of the candidate seal zone if you
        % deployed a device here", not the diameter of an aneurysm.
        seal_start_idx = idx_search_start;
        seal_window_end = find(arc >= arc(idx_search_start) + 30, 1, 'first');
        if isempty(seal_window_end) || seal_window_end > idx_aorta_end
            seal_window_end = idx_aorta_end;
        end
        aneurysm_idx = seal_window_end;
        R_neck = mean(R(seal_start_idx:aneurysm_idx));
        % Candidate seal-zone diameter for the non-aneurysmal proximal
        % aorta (the 30 mm window above is already a clean seal zone).
        neck_dia_mm = 2 * R_neck;
    else
        aneurysm_idx = idx_search_start + aneurysm_rel - 1;
        % --- Locate the infrarenal neck (sizing-1 / sizing-2 fix) -------
        % The neck is the non-aneurysmal infrarenal segment proximal to
        % the aneurysm onset. The neck DIAMETER that governs graft sizing
        % is the lumen Ø at the proximal sealing zone — NOT an average
        % taken from the renal level THROUGH the dilating segment up to
        % the aneurysm (the old code did the latter, over-calling neck Ø
        % by ~30% and over-reporting neck length). locate_neck finds the
        % proximal neck boundary (where the juxtarenal aorta narrows to
        % neck caliber), measures the diameter over the proximal
        % opts.seal_zone_mm of the neck, and EXCLUDES the aneurysm-onset
        % node (which is by definition already dilated).
        neck_lo = idx_search_start;
        neck_hi = max(idx_search_start, aneurysm_idx - 1);   % exclude onset node
        [seal_start_idx, neck_dia_mm, R_neck] = locate_neck( ...
            arc, R, neck_lo, neck_hi, opts.seal_zone_mm, opts.neck_grow_frac);
    end

    if aneurysm_detected
        meas.neck_length_mm = max(0, arc(aneurysm_idx) - arc(seal_start_idx));
    else
        % B3: no discrete aneurysm onset fired, so the "neck" would run
        % all the way to the bifurcation — an implausible length that
        % reads as a real infrarenal neck. Report N/A instead. The
        % aneurysm_detected flag lets callers say "no aneurysm detected".
        meas.neck_length_mm = NaN;
    end
    neck_end_idx = aneurysm_idx;
    end   % heuristic fallback
    meas.neck_diameter_mm  = neck_dia_mm;   % seal-zone lumen Ø (sizing-1/2 fix)
    meas.aneurysm_detected = aneurysm_detected;

    % B2: TotalSegmentator segments the contrast LUMEN only, so every
    % diameter emitted here excludes mural thrombus / outer wall. Tag the
    % struct so downstream display + plan text label it as a lumen
    % diameter and it is never mistaken for the true (outer-wall) sac Ø.
    meas.diameter_basis = 'lumen';

    % --- Neck angulation: report BOTH clinical angles (B1) -----------
    % alpha (suprarenal-to-neck): suprarenal aortic axis vs infrarenal
    %   neck axis. beta (infrarenal neck-to-sac): infrarenal neck axis vs
    %   aneurysm-sac axis — the angle most vendor IFUs limit on, so it is
    %   the canonical `neck_angulation_deg` used for device eligibility.
    %   Both axes are sampled over fixed opts.angulation_seg_mm windows
    %   (mm), so the result is independent of centerline node spacing.
    seg_mm     = opts.angulation_seg_mm;
    supra_axis = axis_vec(Pv, arc, 1, seg_mm);
    % The neck axis must stay INSIDE the neck: on a neck shorter than the
    % sampling window a fixed 30 mm segment runs into the sac and biases
    % beta low. Cap it at the neck length (10 mm floor for stability).
    neck_seg_mm = seg_mm;
    if aneurysm_detected
        neck_seg_mm = min(seg_mm, max(10, arc(neck_end_idx) - arc(seal_start_idx)));
    end
    neck_axis  = axis_vec(Pv, arc, seal_start_idx, neck_seg_mm);
    meas.neck_angulation_alpha_deg = angle_between(supra_axis, neck_axis);
    if aneurysm_detected
        sac_axis = axis_vec(Pv, arc, aneurysm_idx, seg_mm);
        meas.neck_angulation_beta_deg = angle_between(neck_axis, sac_axis);
    else
        % No sac to measure the neck against.
        meas.neck_angulation_beta_deg = NaN;
    end
    % Canonical angulation for IFU eligibility = beta (infrarenal
    % neck-to-sac). NaN when no aneurysm is present, in which case
    % ifu.check_eligibility skips the angle criterion rather than
    % inventing a number.
    meas.neck_angulation_deg = meas.neck_angulation_beta_deg;

    meas.max_aneurysm_R_mm = max([pr.R_mm_right; pr.R_mm_left]);
    % Schema-aligned diameter alias: the reference schema + benchmark
    % comparison both speak in diameter (`aneurysm_max_diameter_mm`).
    % Emit both so callers don't have to ×2 manually (the old footgun
    % that hid `aneurysm_max_diameter_mm` from compare_to_reference for
    % weeks). Strictly redundant; the diameter form is the canonical
    % schema field.
    meas.aneurysm_max_diameter_mm = 2 * meas.max_aneurysm_R_mm;

    % Bifurcation angle: angle between the two iliac trunks measured
    % opts.bifurc_tangent_mm distal to the bifurcation. Clinically the
    % "iliac take-off angle" — wide angles can compromise main-body
    % seating and limb gating. Reported in degrees ∈ [0, 180].
    %
    % We do NOT use the R/L tangent immediately at the bifurc node
    % (those vectors are noisy because the polyline is changing
    % direction sharply at exactly that index); we walk
    % opts.bifurc_tangent_mm distally on each side and use the
    % bifurc → distal-node vector.
    if ~isfield(opts, 'bifurc_tangent_mm'); opts.bifurc_tangent_mm = 20; end
    meas.bifurcation_angle_deg = compute_bifurc_angle( ...
        pr.Pv_mm_right, pr.Pv_mm_left, bifurc_arc_R, bifurc_arc_L, ...
        opts.bifurc_tangent_mm);

    % Always-defined diagnostic — R_neck only exists in the no-aneurysm
    % branch; recompute a sensible value for both paths.
    if exist('R_neck', 'var') && ~isempty(R_neck)
        baseline_R = R_neck;
    else
        baseline_R = mean(R(seal_start_idx:aneurysm_idx));
    end
    meas.diagnostic = struct( ...
        'seal_start_arc_mm', arc(seal_start_idx), ...
        'neck_end_arc_mm', arc(neck_end_idx), ...
        'aneurysm_start_arc_mm', arc(aneurysm_idx), ...
        'neck_baseline_R_mm', baseline_R, ...
        'bifurcation_arc_R_mm', bifurc_arc_R, ...
        'bifurcation_arc_L_mm', bifurc_arc_L, ...
        'neck_landmark', meas.neck_landmark, ...
        'bifurcation_source', meas.bifurcation_source, ...
        'renal_note', lr.note);
end

function [idx, lr] = renal_anchor(pr, Pv, arc, bifurc_arc)
%RENAL_ANCHOR  Centerline node at the lower margin of the lowest renal
%   ostium, or [] when the planner result can't support the landmark (no
%   branch labels / renals, or an implausible level). Z-only matching: both
%   centerline backends emit Z in the D.slice_z_mm frame, so this needs no
%   in-plane axis convention.
    idx = [];
    lr = struct('found', false, 'side', '', 'z_idx', NaN, 'note', '');
    if ~isfield(pr, 'label_branch') || isempty(pr.label_branch) || ...
            ~isfield(pr, 'D') || ~isstruct(pr.D) || ~isfield(pr.D, 'pixel_mm')
        lr.note = 'planner result has no branch labels';
        return;
    end
    try
        lr = evar_plan.lowest_renal_level(pr.label_branch, pr.D, ...
            struct('kidney_z', kidney_extents(pr)));
    catch ME
        lr.note = sprintf('renal detection failed: %s', ME.message);
        return;
    end
    if ~lr.found; return; end
    zi = node_slice_index(Pv(:, 3), pr.D);
    cand = find(zi >= lr.z_idx, 1, 'first');
    if isempty(cand)
        lr.note = 'centerline never reaches the renal level';
    elseif cand == 1
        lr.note = 'centerline starts below the renal level';
    elseif ~isnan(bifurc_arc) && arc(cand) >= bifurc_arc - 10
        lr.note = 'renal level at/below the bifurcation — implausible';
    else
        idx = cand;
        return;
    end
    lr.found = false;
end

function K = kidney_extents(pr)
%KIDNEY_EXTENTS  Per-side kidney slice ranges from the TotalSegmentator
%   label volume (pr.ts_info.label_volume), for the renal plausibility
%   gate. Empty struct when unavailable (external/hand-annotated masks):
%   the gate is then skipped and the renal labels are trusted.
    K = struct();
    if ~isfield(pr, 'ts_info') || ~isstruct(pr.ts_info) || ...
            ~isfield(pr.ts_info, 'label_volume') || isempty(pr.ts_info.label_volume) || ...
            (isfield(pr, 'label_branch') && ~isequal(size(pr.ts_info.label_volume), size(pr.label_branch)))
        return;
    end
    T = pr.ts_info.label_volume;
    n2id = autoseg.class_name_to_id();
    sides = {'L', 'kidney_left'; 'R', 'kidney_right'};
    for s = 1:2
        z = find(squeeze(any(any(T == n2id(sides{s, 2}), 1), 2)));
        if isempty(z); K.(sides{s, 1}) = [NaN NaN];
        else;           K.(sides{s, 1}) = [z(1) z(end)];
        end
    end
end

function [arcR, arcL] = anatomic_bifurcation_arcs(pr)
%ANATOMIC_BIFURCATION_ARCS  Arc length on each (proximal→distal) polyline
%   at the anatomic aortic bifurcation: the first slice where BOTH iliac
%   labels (2 and 3) are present. NaN when labels or geometry are missing
%   or a polyline never reaches that level.
    arcR = NaN; arcL = NaN;
    if ~isfield(pr, 'label_branch') || isempty(pr.label_branch) || ...
            ~isfield(pr, 'D') || ~isstruct(pr.D) || ndims(pr.label_branch) ~= 3
        return;
    end
    L = pr.label_branch;
    z2 = find(squeeze(any(any(L == 2, 1), 2)), 1, 'first');
    z3 = find(squeeze(any(any(L == 3, 1), 2)), 1, 'first');
    if isempty(z2) || isempty(z3); return; end
    zb = max(z2, z3);
    arcR = arc_at_slice(pr.Pv_mm_right, pr.D, zb);
    arcL = arc_at_slice(pr.Pv_mm_left,  pr.D, zb);
end

function a = arc_at_slice(Pv, D, zb)
    a = NaN;
    if size(Pv, 1) < 2; return; end
    arc = [0; cumsum(vecnorm(diff(Pv, 1, 1), 2, 2))];
    zi = node_slice_index(Pv(:, 3), D);
    k = find(zi >= zb, 1, 'first');
    if ~isempty(k) && k > 1; a = arc(k); end
end

function zi = node_slice_index(z_mm, D)
%NODE_SLICE_INDEX  Fractional slice index (head at 1) of centerline Z values.
    if isfield(D, 'slice_z_mm') && numel(D.slice_z_mm) >= 2
        [zs, ia] = unique(double(D.slice_z_mm(:)));
        zi = interp1(zs, ia, double(z_mm), 'linear', 'extrap');
    else
        zi = double(z_mm) / abs(D.slice_spacing_mm) + 1;
    end
end

function [seal_idx, onset_idx, neck_end_idx, detected, dia_mm, R_ref] = ...
        renal_anchored_neck(arc, R, seal_idx, bifurc_arc, opts)
%RENAL_ANCHORED_NECK  Neck measurements starting at the lowest renal.
%   Aneurysm onset = first sustained run of R > opts.aneurysm_R_mm between
%   the renal level and the bifurcation. Neck end = the earlier of that
%   onset and the first sustained run exceeding the reference neck caliber
%   by opts.neck_length_growth_frac. A juxtarenal aneurysm (onset at the
%   renal node) correctly yields neck length 0.
    n = numel(R);
    if ~isnan(bifurc_arc)
        aorta_end = find(arc >= bifurc_arc - 5, 1, 'first');
    else
        aorta_end = n;
    end
    if isempty(aorta_end) || aorta_end <= seal_idx; aorta_end = n; end

    seg_R   = R(seal_idx:aorta_end);
    seg_arc = arc(seal_idx:aorta_end);
    run_mm  = opts.aneurysm_min_run_mm;

    abs_rel = first_sustained_run(seg_R > opts.aneurysm_R_mm, seg_arc, run_mm);
    detected = ~isempty(abs_rel);

    ref_hi = find(seg_arc >= seg_arc(1) + opts.neck_ref_mm, 1, 'first');
    if isempty(ref_hi); ref_hi = numel(seg_R); end
    R_ref = median(seg_R(1:ref_hi));
    grow_rel = first_sustained_run(seg_R > (1 + opts.neck_length_growth_frac) * R_ref, ...
        seg_arc, run_mm);

    if detected
        onset_idx = seal_idx + abs_rel - 1;
        end_rel = abs_rel;
        if ~isempty(grow_rel); end_rel = min(end_rel, grow_rel); end
        neck_end_idx = seal_idx + end_rel - 1;
    else
        % No aneurysm: report the candidate seal-zone diameter only; the
        % "onset" index is just the end of the seal window (used for the
        % diagnostic + beta, which is NaN in this case anyway).
        win = find(seg_arc >= seg_arc(1) + 30, 1, 'first');
        if isempty(win); win = numel(seg_R); end
        onset_idx = seal_idx + win - 1;
        neck_end_idx = onset_idx;
    end

    % Seal-zone diameter over the proximal opts.seal_zone_mm of the neck,
    % never extending into the dilating segment.
    hi_rel = find(seg_arc >= seg_arc(1) + opts.seal_zone_mm, 1, 'first');
    if isempty(hi_rel); hi_rel = numel(seg_R); end
    if detected
        hi_rel = min(hi_rel, max(1, (neck_end_idx - seal_idx + 1) - 1));
    end
    dia_mm = 2 * mean(seg_R(1:max(1, hi_rel)));
end

function [prox_idx, dia_mm, R_caliber] = locate_neck(arc, R, lo, hi, seal_zone_mm, grow_frac)
%LOCATE_NECK  Find the infrarenal neck within the non-aneurysmal window
%   [lo,hi] and measure the seal-zone diameter.
%
%   The neck runs roughly constant at its caliber between the renal level
%   and the aneurysm onset. We take the neck caliber as the MINIMUM
%   radius in the window (robust to where exactly the renals sit), find
%   the proximal neck boundary as the first node — walking proximal→
%   distal — at or below caliber*(1+grow_frac) (i.e. where the wider
%   juxtarenal aorta has narrowed into the neck), and measure the
%   diameter as the mean lumen Ø over the proximal seal_zone_mm of the
%   neck (the graft's proximal landing zone). Returns the proximal-
%   boundary index, the seal-zone diameter (mm), and the neck caliber R.
    lo = max(1, round(lo));
    hi = max(lo, round(hi));
    seg = R(lo:hi);
    R_caliber = min(seg);
    rel = find(seg <= R_caliber * (1 + grow_frac), 1, 'first');
    if isempty(rel); rel = 1; end
    prox_idx = lo + rel - 1;
    seal_hi = find(arc >= arc(prox_idx) + seal_zone_mm, 1, 'first');
    if isempty(seal_hi) || seal_hi > hi; seal_hi = hi; end
    dia_mm = 2 * mean(R(prox_idx:seal_hi));
end

function idx0 = first_sustained_run(over, arc_seg, min_run_mm)
%FIRST_SUSTAINED_RUN  Index of the first element that begins a run of
%   TRUE values in OVER whose arc span (from ARC_SEG) is >= MIN_RUN_MM.
%   Returns [] if no such run exists. A lone TRUE (span 0) is rejected
%   whenever MIN_RUN_MM > 0, giving the onset detector its hysteresis.
    idx0 = [];
    n = numel(over);
    i = 1;
    while i <= n
        if over(i)
            j = i;
            while j < n && over(j + 1); j = j + 1; end
            if (arc_seg(j) - arc_seg(i)) >= min_run_mm
                idx0 = i; return;
            end
            i = j + 1;
        else
            i = i + 1;
        end
    end
end

function v = axis_vec(Pv, arc, idxA, seg_mm)
%AXIS_VEC  Direction vector from node idxA walking seg_mm of arc length
%   distally (toward larger arc). Returns [] if the segment is
%   degenerate (idxB at or before idxA, or near-zero length).
    idxB = find(arc >= arc(idxA) + seg_mm, 1, 'first');
    if isempty(idxB); idxB = numel(arc); end
    if idxB <= idxA; v = []; return; end
    v = Pv(idxB, :) - Pv(idxA, :);
    if norm(v) < 1e-6; v = []; end
end

function ang = angle_between(a, b)
%ANGLE_BETWEEN  Angle in degrees [0,180] between two vectors. NaN if
%   either vector is empty / degenerate.
    if isempty(a) || isempty(b); ang = NaN; return; end
    ang = acosd(max(-1, min(1, dot(a, b) / (norm(a) * norm(b)))));
end

function pr = normalize_direction(pr)
%NORMALIZE_DIRECTION  Force PROXIMAL→DISTAL order on both branches.
%   The RIGHT polyline is the long one (spans CFA → bifurcation →
%   proximal aorta). Its radius profile reliably distinguishes the
%   ends — the proximal aorta is several mm wider than the CFA. If
%   R(1) < R(end), the polyline runs distal → proximal and we flip.
%
%   The LEFT polyline can be either CFA→bifurc (truncated at the
%   bifurcation, no radius signal — phantom convention) or full
%   CFA→proximal (GUI convention). We always flip the left the SAME
%   direction as the right since both are emitted by the same caller.
    if isfield(pr, 'R_mm_right') && isfield(pr, 'Pv_mm_right') && ...
            numel(pr.R_mm_right) > 4
        if pr.R_mm_right(1) < pr.R_mm_right(end)
            pr.Pv_mm_right = flipud(pr.Pv_mm_right);
            pr.R_mm_right  = flipud(pr.R_mm_right);
            if isfield(pr, 'R_mm_left') && isfield(pr, 'Pv_mm_left')
                pr.Pv_mm_left = flipud(pr.Pv_mm_left);
                pr.R_mm_left  = flipud(pr.R_mm_left);
            end
        end
    end
end

function ang_deg = compute_bifurc_angle(Pv_right, Pv_left, bifurc_arc_R, bifurc_arc_L, tangent_mm)
%COMPUTE_BIFURC_ANGLE  Angle between the two iliac take-offs.
%
%   Returns the angle in degrees [0, 180] between the bifurc→distal
%   vectors measured `tangent_mm` distally on each side. Returns NaN
%   when either polyline doesn't have a bifurc arc or doesn't have
%   enough downstream arc to support the tangent measurement.
    if any(isnan([bifurc_arc_R, bifurc_arc_L])) || ...
            size(Pv_right, 1) < 3 || size(Pv_left, 1) < 3
        ang_deg = NaN; return;
    end
    arc_R = [0; cumsum(vecnorm(diff(Pv_right,1,1), 2, 2))];
    arc_L = [0; cumsum(vecnorm(diff(Pv_left, 1,1), 2, 2))];
    % Find the bifurc index on each polyline (proximal-most index past
    % the bifurc arc length)
    iR_bif = find(arc_R >= bifurc_arc_R, 1, 'first');
    iL_bif = find(arc_L >= bifurc_arc_L, 1, 'first');
    if isempty(iR_bif); iR_bif = numel(arc_R); end
    if isempty(iL_bif); iL_bif = numel(arc_L); end
    % Walk tangent_mm distally
    iR_tan = find(arc_R >= arc_R(iR_bif) + tangent_mm, 1, 'first');
    iL_tan = find(arc_L >= arc_L(iL_bif) + tangent_mm, 1, 'first');
    if isempty(iR_tan); iR_tan = numel(arc_R); end
    if isempty(iL_tan); iL_tan = numel(arc_L); end
    % If we can't actually walk forward (bifurc is at the end of either
    % polyline), the angle is undefined.
    if iR_tan <= iR_bif || iL_tan <= iL_bif
        ang_deg = NaN; return;
    end
    vR = Pv_right(iR_tan, :) - Pv_right(iR_bif, :);
    vL = Pv_left (iL_tan, :) - Pv_left (iL_bif, :);
    if norm(vR) < 1e-6 || norm(vL) < 1e-6
        ang_deg = NaN; return;
    end
    ang_deg = acosd(max(-1, min(1, dot(vR, vL) / (norm(vR) * norm(vL)))));
end

function [arc_R, arc_L] = find_bifurcation(Pv_right, Pv_left, threshold_mm)
% FIND_BIFURCATION  Find the aortic bifurcation by detecting the
%   POINT-OF-MINIMUM-DISTANCE between the two centerlines.
%
%   After normalize_direction(), both polylines run proximal → distal
%   (the right covers proximal aorta → CFA, the left covers bifurc → CFA
%   in the phantom convention, or proximal → CFA in the GUI convention).
%   The two curves are CLOSEST to each other at the bifurcation: above
%   the bifurcation the left polyline may not exist; below it the curves
%   physically separate into the two iliacs.
%
%   Returns the arc length on each polyline at the bifurcation point.
    arc_r_full = [0; cumsum(vecnorm(diff(Pv_right,1,1), 2, 2))];
    arc_l_full = [0; cumsum(vecnorm(diff(Pv_left, 1,1), 2, 2))];
    arc_R = NaN; arc_L = NaN;

    nR = size(Pv_right, 1);
    nL = size(Pv_left,  1);

    % Right branch: minimum distance to the L curve at each point
    d_R = inf(nR, 1);
    k_min_on_L = zeros(nR, 1);
    for k = 1:nR
        d = vecnorm(Pv_left - Pv_right(k,:), 2, 2);
        [d_R(k), k_min_on_L(k)] = min(d);
    end
    % The bifurcation is the LAST right-curve index where the right and
    % left curves are still close (d_R < threshold_mm). For polylines
    % that share a proximal trunk: d_R is small for the shared portion
    % and grows after the bifurcation. For polylines that DON'T share a
    % trunk (phantom convention: left starts at the bifurc, right at the
    % proximal aorta): d_R is large at proximal aorta, drops to ~0 at the
    % bifurc, then grows again into the iliacs. Either way, the LAST
    % index where d_R is at threshold marks the bifurc.
    close_mask = d_R < threshold_mm;
    if any(close_mask)
        kR_bif = find(close_mask, 1, 'last');
    else
        % Curves never come close — degenerate input. Fall back to the
        % CLOSEST single point so callers still get a non-NaN answer.
        [~, kR_bif] = min(d_R);
    end
    arc_R = arc_r_full(kR_bif);
    arc_L = arc_l_full(k_min_on_L(kR_bif));
end

function [dia_mm, length_mm, arc] = side_measurements(Pv, R, bifurc_arc, opts)
    arc = [0; cumsum(vecnorm(diff(Pv,1,1), 2, 2))];
    if isempty(arc) || arc(end) < opts.iliac_window_mm || isnan(bifurc_arc)
        dia_mm = NaN; length_mm = NaN; return;
    end
    length_mm  = arc(end) - bifurc_arc;
    % EVAR iliac landing zone is in the COMMON iliac — proximal to the
    % internal iliac branch, distal to the aortic bifurcation. Measure
    % diameter ~20 mm distal to the bifurcation (typical mid-CIA), with
    % an opts.iliac_window_mm-wide averaging window. This avoids the
    % small external iliac at the very distal end of the centerline.
    if ~isfield(opts, 'cia_offset_mm'); opts.cia_offset_mm = 20; end
    cia_arc_target = bifurc_arc + opts.cia_offset_mm;
    if cia_arc_target > arc(end) - opts.iliac_window_mm
        % iliac too short to give a clear common-iliac window — fall back
        % to the largest-radius segment past the bifurcation
        idx_distal = find(arc >= bifurc_arc, 1, 'first');
        [~, rel] = max(R(idx_distal:end));
        cia_idx = idx_distal + rel - 1;
    else
        cia_idx = find(arc >= cia_arc_target, 1, 'first');
    end
    win_lo = find(arc >= arc(cia_idx) - opts.iliac_window_mm/2, 1, 'first');
    win_hi = find(arc >= arc(cia_idx) + opts.iliac_window_mm/2, 1, 'first');
    if isempty(win_hi); win_hi = numel(arc); end
    dia_mm = 2 * mean(R(win_lo:win_hi));
end

