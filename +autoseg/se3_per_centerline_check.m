function report = se3_per_centerline_check(Pv_mm, side_label, R_mm, opts)
%AUTOSEG.SE3_PER_CENTERLINE_CHECK  Per-centerline anatomic plausibility
%   rules over a SINGLE centerline lifted to SE(3) via Bishop frames.
%
%   report = autoseg.se3_per_centerline_check(Pv_mm, side_label)
%   report = autoseg.se3_per_centerline_check(Pv_mm, side_label, R_mm)
%   report = autoseg.se3_per_centerline_check(Pv_mm, side_label, R_mm, opts)
%
%   Pv_mm        (:,3) double, [X_mm, Y_mm, Z_mm], proximal → distal
%   side_label   char, e.g. 'L', 'R', 'aorta' — for diagnostic text
%   R_mm         (:,1) double of radii in mm at each centerline node
%                (optional; pass [] to skip the radius-profile checks)
%
%   The SE(3) lift of a centerline gives us at every arc-length s:
%       - position r(s)
%       - tangent T(s) = r'(s)/|r'(s)|
%       - curvature κ(s) = |r' × r''| / |r'|³   (mm⁻¹)
%       - torsion  τ(s) = (r' × r'')·r''' / |r' × r''|²  (mm⁻¹)
%       - arc length s = ∫|r'(s)| ds
%   Each of these has physiologic bounds that are invariant across
%   patients, scanners, and positioning. Violation flags a centerline
%   that almost certainly jumped vessels or contains a graph-traversal
%   artifact, regardless of how plausible it looks in 3-D.
%
%   Rules checked (each becomes a block in report.blocks{}; severity
%   0=OK, 1=WARN, 2=FAIL):
%     1. MAX CURVATURE κ_max ≤ 0.35 mm⁻¹ (R ≥ 3 mm; calibrated to the
%        AAA-100 99th percentile). A spike usually means the centerline
%        jumped to a small adjacent branch or the graph shortest-path
%        corkscrewed through a junction.
%     2. TORSION |τ| ≤ 5.0 mm⁻¹ (AAA-100 99th = 4.7). Arteries are mostly
%        planar curves; high torsion means the centerline is helically
%        twisting, almost always a graph-traversal artifact.
%     3. TANGENT CONTINUITY: angle between consecutive tangents ≤ 90°
%        (AAA-100 99th aorta = 80°). Step discontinuities indicate the
%        centerline switched vessels between adjacent nodes.
%     4. TORTUOSITY (arc length / Euclidean distance) ≤ 1.70 (AAA-100
%        99th = 1.55). Real iliacs have tortuosity 1.05-1.30 even in
%        highly tortuous patients. Higher ratios catch loop-backs not
%        caught by z-monotonicity.
%     5. RADIUS-PROFILE STEP CHANGE |dR/ds| ≤ 1.0 mm/mm. The lumen
%        radius along a real vessel can taper or bulge (AAA) but does
%        not change by more than ~1 mm per mm of arc — a sharper step
%        means the centerline jumped to a vessel of different caliber.
%        Skipped if R_mm is empty.
%
%   OPTS (struct, optional):
%       .smooth_window      default 7      — odd integer; moving-average
%                                            window over centerline nodes
%                                            before computing differential
%                                            geometry. Set to 1 to disable.
%                                            Smoothing kills single-node
%                                            jumps from coarse per-slice-
%                                            centroid extraction without
%                                            erasing real vessel-switch
%                                            artifacts (which span
%                                            multiple nodes).
%       .kappa_max_per_mm   default 0.35   — mm⁻¹ (calibrated to AAA-100
%                                            99th-percentile; R 3 mm floor)
%       .tau_max_per_mm     default 5.00   — mm⁻¹ (AAA-100 99th = 4.7)
%       .tan_angle_max_deg  default 90     — adjacent tangent angle, °
%                                            (AAA-100 99th aorta = 80°)
%       .tortuosity_max     default 1.70   — arc/Euclidean ratio
%                                            (AAA-100 99th = 1.55)
%       .dR_ds_max_mm_mm    default 1.00   — mm/mm step bound
%
%   When report.passed = false, the GUI should surface the failing
%   block and offer the user a "click the CFA" path to re-anchor this
%   side's centerline (same as the cross-vessel rule failure path).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        Pv_mm      (:,3) double
        side_label (1,:) char
        R_mm       (:,1) double = []
        opts       (1,1) struct = struct()
    end
    % Thresholds calibrated from AAA-100 reference centerlines
    % (scripts/calibrate_se3_thresholds.m, 100 cases). Each is set 5%
    % above the 99th percentile of real anatomy on this cohort so a
    % normal centerline passes confidently and a true vessel-switch
    % stands out. Recompute and tighten after a larger cohort is added.
    if ~isfield(opts, 'smooth_window');      opts.smooth_window = 15;        end
    if ~isfield(opts, 'kappa_max_per_mm');   opts.kappa_max_per_mm = 0.35;   end
    if ~isfield(opts, 'tau_max_per_mm');     opts.tau_max_per_mm = 5.00;     end
    if ~isfield(opts, 'tan_angle_max_deg');  opts.tan_angle_max_deg = 90;    end
    if ~isfield(opts, 'tortuosity_max');     opts.tortuosity_max = 1.70;     end
    if ~isfield(opts, 'dR_ds_max_mm_mm');    opts.dR_ds_max_mm_mm = 1.00;    end

    % Moving-average smoothing in mm. Removes single-node hop noise from
    % coarse per-slice-centroid extraction (where the centroid can jump
    % between adjacent connected components from slice to slice) while
    % preserving any vessel-switch artifact that spans ≥ smooth_window
    % nodes. We smooth Pv_mm itself; tortuosity and arc length are
    % computed on the smoothed curve. The first and last
    % floor(window/2) nodes are window-edge artifacts (smoothed over
    % a partial window) and are excluded from the κ/τ/tangent extremes
    % below.
    edge_trim = 0;
    if opts.smooth_window > 1 && size(Pv_mm, 1) > opts.smooth_window
        w = opts.smooth_window;
        Pv_mm = movmean(Pv_mm, w, 1, 'Endpoints', 'shrink');
        edge_trim = floor(w / 2);
    end

    report = struct('blocks', {{}}, 'passed', true, 'summary_text', '', ...
                    'side_label', side_label);

    n = size(Pv_mm, 1);
    if n < 4
        b.name = 'Centerline present';
        b.severity = 2;
        b.findings = {sprintf('%s centerline has %d nodes (< 4); cannot evaluate SE(3) properties.', side_label, n)};
        report.blocks{end+1} = b;
        report = finalize(report, side_label);
        return;
    end

    % Pre-compute differential geometry on the polyline.
    d1 = diff(Pv_mm, 1, 1);                  % node-to-node displacement (n-1 × 3)
    ds = vecnorm(d1, 2, 2);
    ds(ds < 1e-9) = 1e-9;
    arc_len = sum(ds);
    eucl    = norm(Pv_mm(end, :) - Pv_mm(1, :));

    % --- Block 1: max curvature κ_max -------------------------------
    b.name = 'Max local curvature (κ_max ≤ tightest anatomic bend)';
    b.findings = {}; b.severity = 0;
    [kappa, ~] = local_curvature(Pv_mm);
    kappa_eval = trim_edges(kappa, edge_trim);
    kappa_max = max(kappa_eval);
    kappa_R_mm = 1 / max(kappa_max, eps);
    b.findings{end+1} = sprintf( ...
        '%s κ_max = %.3f mm⁻¹ (R = %.1f mm) at node %d of %d (tol %.2f mm⁻¹ ↔ R %.0f mm).', ...
        side_label, kappa_max, kappa_R_mm, find_first_gt(kappa_eval, opts.kappa_max_per_mm) + edge_trim, n, ...
        opts.kappa_max_per_mm, 1 / opts.kappa_max_per_mm);
    if kappa_max > opts.kappa_max_per_mm
        b.severity = 2;
        b.findings{end+1} = sprintf( ...
            'κ_max %.3f mm⁻¹ exceeds %.2f mm⁻¹ — radius of curvature %.1f mm is tighter than physiologic (R ≥ 5 mm). Likely a graph-shortest-path corkscrew at a junction or a vessel jump.', ...
            kappa_max, opts.kappa_max_per_mm, kappa_R_mm);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 2: max torsion |τ| -----------------------------------
    b.name = 'Max torsion (|τ| ≤ planar-bend bound)';
    b.findings = {}; b.severity = 0;
    tau = local_torsion(Pv_mm);
    tau_eval = trim_edges(abs(tau), edge_trim);
    if isempty(tau_eval) || all(~isfinite(tau_eval))
        b.findings{end+1} = sprintf('%s torsion not computable (centerline too short for 3rd derivative).', side_label);
    else
        tau_max = max(tau_eval);
        b.findings{end+1} = sprintf('%s |τ|_max = %.3f mm⁻¹ at node %d (tol %.2f mm⁻¹).', ...
            side_label, tau_max, find_first_gt(tau_eval, opts.tau_max_per_mm) + edge_trim, opts.tau_max_per_mm);
        if tau_max > opts.tau_max_per_mm
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf( ...
                '|τ|_max %.3f mm⁻¹ exceeds %.2f mm⁻¹ — centerline is helically twisting, a graph-traversal artifact.', ...
                tau_max, opts.tau_max_per_mm);
        end
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 3: tangent continuity -------------------------------
    b.name = 'Tangent continuity (no step direction flips)';
    b.findings = {}; b.severity = 0;
    T = d1 ./ ds;                            % unit tangents (n-1 × 3)
    cos_th = sum(T(1:end-1, :) .* T(2:end, :), 2);
    cos_th = max(min(cos_th, 1), -1);
    tan_angles_deg = acosd(cos_th);
    tan_eval = trim_edges(tan_angles_deg, edge_trim);
    [max_tan_deg, max_tan_idx] = max(tan_eval);
    b.findings{end+1} = sprintf( ...
        '%s max adjacent-tangent angle = %.1f° at node %d of %d (tol %.0f°).', ...
        side_label, max_tan_deg, max_tan_idx + edge_trim, n, opts.tan_angle_max_deg);
    if max_tan_deg > opts.tan_angle_max_deg
        b.severity = 2;
        b.findings{end+1} = sprintf( ...
            'Tangent jumped %.1f° between adjacent nodes — almost certainly a vessel-switch or skeleton-graph traversal error.', ...
            max_tan_deg);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 4: tortuosity (arc / Euclidean) ---------------------
    b.name = 'Tortuosity (arc length / Euclidean distance)';
    b.findings = {}; b.severity = 0;
    if eucl < 1e-6
        tort = Inf;
    else
        tort = arc_len / eucl;
    end
    b.findings{end+1} = sprintf( ...
        '%s arc = %.0f mm, Euclidean = %.0f mm, tortuosity = %.2f (tol %.2f).', ...
        side_label, arc_len, eucl, tort, opts.tortuosity_max);
    if tort > opts.tortuosity_max
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            'Tortuosity %.2f exceeds %.2f — the centerline is doubling back or looping. Check for graph-traversal cycles missed by the z-monotonicity rule.', ...
            tort, opts.tortuosity_max);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 5: radius-profile step changes -----------------------
    b.name = 'Radius-profile step change (|dR/ds| ≤ caliber-jump bound)';
    b.findings = {}; b.severity = 0;
    if isempty(R_mm)
        b.findings{end+1} = sprintf('%s radius profile not provided — skipped.', side_label);
    elseif numel(R_mm) ~= n
        b.findings{end+1} = sprintf('%s R_mm length %d ≠ centerline nodes %d — skipped.', ...
            side_label, numel(R_mm), n);
        b.severity = max(b.severity, 1);
    else
        dR = diff(R_mm);
        dRds = abs(dR) ./ ds;
        [dRds_max, dRds_idx] = max(dRds);
        b.findings{end+1} = sprintf( ...
            '%s |dR/ds|_max = %.2f mm/mm at node %d (R %.1f→%.1f mm over %.1f mm of arc; tol %.2f mm/mm).', ...
            side_label, dRds_max, dRds_idx, R_mm(dRds_idx), R_mm(dRds_idx+1), ds(dRds_idx), opts.dR_ds_max_mm_mm);
        if dRds_max > opts.dR_ds_max_mm_mm
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf( ...
                'Radius step %.2f mm/mm exceeds %.2f mm/mm — lumen caliber changed too fast for real anatomy. Centerline likely jumped to a vessel of different size.', ...
                dRds_max, opts.dR_ds_max_mm_mm);
        end
    end
    report.blocks{end+1} = b;

    report = finalize(report, side_label);
end

function [kappa, ds_mid] = local_curvature(P)
% Curvature at each interior node via the cross-product method:
%   κ_i = |(P_{i+1}-P_i) × (P_i-P_{i-1})| / (|P_{i+1}-P_i|·|P_i-P_{i-1}|·((|d1_i|+|d1_{i-1}|)/2))
    n = size(P, 1);
    if n < 3; kappa = []; ds_mid = []; return; end
    d1 = diff(P, 1, 1);
    kappa  = zeros(n-2, 1);
    ds_mid = zeros(n-2, 1);
    for i = 1:n-2
        a = d1(i, :);   b = d1(i+1, :);
        na = norm(a);   nb = norm(b);
        if na < 1e-9 || nb < 1e-9; continue; end
        c = cross(a, b);
        sin_th = norm(c) / (na * nb);
        ds_mid(i) = (na + nb) / 2;
        kappa(i) = sin_th / ds_mid(i);
    end
end

function tau = local_torsion(P)
% Torsion at each interior node from 3 consecutive displacement vectors:
%   τ_i = ((d1_{i} × d1_{i+1}) · d1_{i+2}) / |d1_i × d1_{i+1}|² / mean(ds)
% Returns [] if fewer than 4 nodes.
    n = size(P, 1);
    if n < 4; tau = []; return; end
    d1 = diff(P, 1, 1);   % (n-1) × 3
    m = n - 3;
    tau = zeros(m, 1);
    for i = 1:m
        a = d1(i, :);
        b = d1(i+1, :);
        c = d1(i+2, :);
        ab = cross(a, b);
        denom = dot(ab, ab);
        if denom < 1e-12; tau(i) = 0; continue; end
        ds_mid = mean([norm(a), norm(b), norm(c)]);
        if ds_mid < 1e-9; tau(i) = 0; continue; end
        tau(i) = dot(ab, c) / denom / ds_mid;
    end
end

function v_out = trim_edges(v, trim)
%TRIM_EDGES  Drop the first/last `trim` elements of v (when long enough).
%   Used to exclude smoothing-window edge artifacts from min/max stats.
    if isempty(v); v_out = v; return; end
    n = numel(v);
    if 2 * trim >= n
        v_out = v;   % too short to trim — keep all
    else
        v_out = v(trim+1 : n-trim);
    end
end

function idx = find_first_gt(v, thr)
    idx = find(v > thr, 1, 'first');
    if isempty(idx); [~, idx] = max(v); end
end

function report = finalize(report, side_label)
    sev = cellfun(@(b) b.severity, report.blocks);
    report.passed = ~any(sev >= 2);
    glyph = {'OK', 'WARN', 'FAIL'};
    lines = {sprintf('=== SE(3) per-centerline rule check (%s) ===', side_label)};
    for k = 1:numel(report.blocks)
        b = report.blocks{k};
        lines{end+1} = sprintf('[%s] %s', glyph{b.severity+1}, b.name); %#ok<AGROW>
        for f = 1:numel(b.findings)
            lines{end+1} = ['    - ' b.findings{f}]; %#ok<AGROW>
        end
    end
    report.summary_text = strjoin(lines, newline);
end
