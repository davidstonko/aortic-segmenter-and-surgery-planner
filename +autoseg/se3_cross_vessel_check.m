function report = se3_cross_vessel_check(Pv_R_mm, Pv_L_mm, opts, Pv_aorta_mm)
%AUTOSEG.SE3_CROSS_VESSEL_CHECK  Anatomic plausibility rules over a
%   PAIR of iliac centerlines, lifted to SE(3) via Bishop frames.
%
%   report = autoseg.se3_cross_vessel_check(Pv_R_mm, Pv_L_mm)
%   report = autoseg.se3_cross_vessel_check(Pv_R_mm, Pv_L_mm, opts)
%   report = autoseg.se3_cross_vessel_check(Pv_R_mm, Pv_L_mm, opts, Pv_aorta_mm)
%
%   When `Pv_aorta_mm` is supplied (the aorta centerline ending at the
%   bifurcation), the take-off angles are computed against the aortic
%   tangent at the bifurcation node — this is the only way to detect
%   bilateral take-off ASYMMETRY (the default `-(t_R + t_L)` axis is
%   symmetric in L and R by construction, so the asymmetry block
%   reports 0° regardless of input). For QC purposes the asymmetry
%   block is therefore only diagnostic when an aorta centerline is
%   provided.
%
%   The L and R iliacs share a proximal trunk at the aortic bifurcation
%   and diverge inferiorly into the femoral triangle. Their relationship
%   in SE(3) follows several anatomic rules that hold across patients.
%   When the centerlines violate these rules, the segmentation almost
%   certainly tracked the wrong vessel on one side (typically a
%   hypogastric / gluteal branch instead of the EIA).
%
%   Rules checked (each becomes a block in report.blocks{}, severity
%   0=OK, 1=WARN, 2=FAIL):
%     1. Both centerlines have a proximal-end (low z) in the abdominal
%        aorta range, and a distal-end (high z) in the femoral triangle
%        range. Z-extent > 150 mm (full pelvis traverse).
%     2. The R and L proximal endpoints are within `bifurc_tol_mm` mm
%        of each other (they share the bifurcation node).
%     3. The R and L distal endpoints are SYMMETRIC about the patient
%        midline (= midpoint of proximal endpoints): |y_R - y_L| < 25
%        mm AND |x_R - x_aorta| ≈ |x_L - x_aorta| within 30%.
%     4. Z-MONOTONICITY: both centerlines must be monotonically z-
%        increasing from proximal to distal. A real iliac doesn't loop
%        back upward. Violation strongly suggests a wrong vessel.
%     5. CURVATURE COMPATIBILITY: total absolute curvature ∫|κ|ds of
%        the two iliacs should be within a factor of 3 of each other.
%        Real iliacs are usually similar; a 5x difference flags one as
%        anomalous (e.g. one is the EIA, the other is a tortuous
%        hypogastric trajectory).
%
%   Additional rules (blocks 6-7):
%     6. BIFURCATION TAKE-OFF ANGLE: at the shared proximal node, each
%        iliac tangent makes an angle of 15-60° with the aortic long
%        axis. Below 15° means the centerline never actually left the
%        aorta (segmentation didn't cross the bifurcation); above 60°
%        is anatomically rare.
%     7. BILATERAL TAKE-OFF SYMMETRY: the L and R take-off angles
%        should agree within `takeoff_symmetry_deg`. Asymmetric splits
%        indicate one side is on a side branch (e.g. one walker went
%        down the hypogastric while the other took the EIA).
%
%   OPTS (struct, optional). Defaults calibrated against AAA-100 99th
%   percentile of real anatomy (see scripts/calibrate_se3_thresholds.m):
%       .bifurc_tol_mm        default 15  — max distance between proximal
%                                           endpoints (when both centerlines
%                                           share a prepended anchor node).
%                                           For raw post-bif iliacs pass 90.
%       .symmetry_y_mm        default 50  — max |y_R - y_L| at distal end
%       .symmetry_x_ratio     default 0.30 — max lateral-asymmetry ratio
%       .curvature_ratio      default 2.5 — max ratio of ∫|κ|ds between sides
%       .takeoff_angle_min_deg  default 5   — AAA-100 1st percentile = 4°
%       .takeoff_angle_max_deg  default 85  — AAA-100 99th percentile = 82°
%       .takeoff_symmetry_deg   default 25  — max L-R take-off-angle
%                                             disagreement (diagnostic only
%                                             when Pv_aorta_mm is provided)
%
%   When report.passed = false, the GUI should surface the failing
%   block and offer the user a "click the CFA" path to re-anchor that
%   side's centerline.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        Pv_R_mm     (:,3) double
        Pv_L_mm     (:,3) double
        opts        (1,1) struct = struct()
        Pv_aorta_mm (:,3) double = zeros(0, 3)
    end
    % Thresholds calibrated from AAA-100 reference cohort
    % (scripts/calibrate_se3_thresholds.m, 100 real iliac pairs).
    % - bifurc_tol_mm:  applies when both centerlines share an explicit
    %                   proximal anchor node (the caller prepends the
    %                   aortic bifurcation centroid). For raw L+R iliacs
    %                   without a shared anchor, the AAA-100 cohort
    %                   shows a median 55 mm / 99th 86 mm gap — caller
    %                   should pass bifurc_tol_mm=90 in that case.
    % - takeoff_angle_min_deg = 5 (AAA-100 1st percentile = 4°)
    % - takeoff_angle_max_deg = 85 (AAA-100 99th percentile = 82°)
    % - curvature_ratio = 2.5 (AAA-100 max = 2.18×, leave margin)
    if ~isfield(opts, 'bifurc_tol_mm');       opts.bifurc_tol_mm = 15;        end
    if ~isfield(opts, 'symmetry_y_mm');       opts.symmetry_y_mm = 50;        end
    if ~isfield(opts, 'symmetry_x_ratio');    opts.symmetry_x_ratio = 0.30;   end
    if ~isfield(opts, 'curvature_ratio');     opts.curvature_ratio = 2.5;     end
    if ~isfield(opts, 'takeoff_angle_min_deg'); opts.takeoff_angle_min_deg = 5;  end
    if ~isfield(opts, 'takeoff_angle_max_deg'); opts.takeoff_angle_max_deg = 85; end
    if ~isfield(opts, 'takeoff_symmetry_deg');  opts.takeoff_symmetry_deg = 25;  end

    report = struct('blocks', {{}}, 'passed', true, 'summary_text', '');

    if size(Pv_R_mm, 1) < 3 || size(Pv_L_mm, 1) < 3
        b.name = 'Centerlines present';
        b.severity = 2;
        b.findings = {'One or both centerlines have < 3 nodes.'};
        report.blocks{end+1} = b;
        report = finalize(report);
        return;
    end

    % Convention: lift expects (X, Y, Z) coords in mm. Centerlines are
    % stored as [y x z] (image-axes) on this project — we just feed the
    % raw columns into the rules below (consistency matters more than
    % absolute mapping).

    % Determine which end is proximal vs distal. The proximal end is
    % closer to the other branch's proximal end (they share the
    % bifurcation). Test both end-pairings.
    [p_R, p_L, d_R, d_L] = pair_proximal_ends(Pv_R_mm, Pv_L_mm);

    % --- Block 1: z-extent --------------------------------------------
    b.name = 'Z-extent (full pelvic traverse)';
    b.findings = {}; b.severity = 0;
    z_extent_R = abs(d_R(3) - p_R(3));
    z_extent_L = abs(d_L(3) - p_L(3));
    b.findings{end+1} = sprintf('R extent %.0f mm, L extent %.0f mm', ...
        z_extent_R, z_extent_L);
    if min(z_extent_R, z_extent_L) < 150
        b.severity = 1;
        b.findings{end+1} = sprintf( ...
            'One iliac z-extent < 150 mm — segmentation may be incomplete.');
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 2: bifurcation co-location ----------------------------
    b.name = 'Shared bifurcation';
    b.findings = {}; b.severity = 0;
    d_bif = norm(p_R - p_L);
    b.findings{end+1} = sprintf('Distance between proximal endpoints: %.1f mm.', d_bif);
    if d_bif > opts.bifurc_tol_mm
        b.severity = 2;
        b.findings{end+1} = sprintf( ...
            'Proximal endpoints are %.1f mm apart (> %.0f mm tol) — the two centerlines do not share a bifurcation. One was likely tracked into the wrong branch.', ...
            d_bif, opts.bifurc_tol_mm);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 3: distal-endpoint symmetry ---------------------------
    b.name = 'Distal-endpoint symmetry across midline';
    b.findings = {}; b.severity = 0;
    % Use the midpoint of proximal endpoints as the patient midline
    midline_x = (p_R(1) + p_L(1)) / 2;
    y_asymmetry = abs(d_R(2) - d_L(2));
    x_R_offset = abs(d_R(1) - midline_x);
    x_L_offset = abs(d_L(1) - midline_x);
    if max(x_R_offset, x_L_offset) > 0
        x_ratio = abs(x_R_offset - x_L_offset) / max(x_R_offset, x_L_offset);
    else
        x_ratio = 0;
    end
    b.findings{end+1} = sprintf('|Δy| at CFA = %.1f mm (tol %.0f); x offsets R=%.0f L=%.0f mm, asymmetry %.0f%% (tol %.0f%%).', ...
        y_asymmetry, opts.symmetry_y_mm, x_R_offset, x_L_offset, ...
        100*x_ratio, 100*opts.symmetry_x_ratio);
    if y_asymmetry > opts.symmetry_y_mm
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            '|Δy| %.1f mm exceeds %.0f mm — one CFA endpoint sits much more anterior/posterior than the other, suggesting one centerline ended on a non-CFA vessel.', ...
            y_asymmetry, opts.symmetry_y_mm);
    end
    if x_ratio > opts.symmetry_x_ratio
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            'Lateral asymmetry %.0f%% exceeds %.0f%% — one CFA endpoint sits closer to the midline than the other.', ...
            100*x_ratio, 100*opts.symmetry_x_ratio);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 4: z-monotonicity -------------------------------------
    b.name = 'Z-monotonicity (no loop-back)';
    b.findings = {}; b.severity = 0;
    n_back_R = count_z_reversals(Pv_R_mm(:, 3));
    n_back_L = count_z_reversals(Pv_L_mm(:, 3));
    n_R_total = size(Pv_R_mm, 1);
    n_L_total = size(Pv_L_mm, 1);
    b.findings{end+1} = sprintf('R: %d / %d nodes reverse z; L: %d / %d.', ...
        n_back_R, n_R_total, n_back_L, n_L_total);
    if n_back_R / n_R_total > 0.05 || n_back_L / n_L_total > 0.05
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            'A centerline reverses z direction on > 5%% of nodes — anatomic iliacs don''t loop back. Likely tracked into a recurrent / hypogastric branch.');
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 5: curvature ratio ------------------------------------
    b.name = 'Bilateral curvature compatibility';
    b.findings = {}; b.severity = 0;
    kappa_R = total_abs_curvature(Pv_R_mm);
    kappa_L = total_abs_curvature(Pv_L_mm);
    if min(kappa_R, kappa_L) > 0
        ratio = max(kappa_R, kappa_L) / min(kappa_R, kappa_L);
    else
        ratio = Inf;
    end
    b.findings{end+1} = sprintf('∫|κ|ds = %.2f rad (R), %.2f rad (L); ratio %.1f× (tol %.1f×).', ...
        kappa_R, kappa_L, ratio, opts.curvature_ratio);
    if ratio > opts.curvature_ratio
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            'Curvature ratio %.1f× exceeds %.1f× — one iliac is much more tortuous than the other; review the more-tortuous side for hypogastric / gluteal contamination.', ...
            ratio, opts.curvature_ratio);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 6: bifurcation take-off angles ------------------------
    % At the shared proximal node the aortic long axis points cranially
    % (away from the iliacs). Each iliac take-off tangent should diverge
    % from that axis by 15-60°. Below 15° the side "iliac" is still
    % running parallel to the aorta — segmentation never actually
    % crossed the bifurcation. Above 60° is extreme tortuosity.
    b.name = 'Bifurcation take-off angles';
    b.findings = {}; b.severity = 0;
    [theta_R_deg, theta_L_deg, asym_axis_source] = ...
        takeoff_angles_deg(Pv_R_mm, Pv_L_mm, p_R, p_L, Pv_aorta_mm);
    b.findings{end+1} = sprintf('R take-off %.1f°, L take-off %.1f° (tol [%.0f°, %.0f°]).', ...
        theta_R_deg, theta_L_deg, opts.takeoff_angle_min_deg, opts.takeoff_angle_max_deg);
    if theta_R_deg < opts.takeoff_angle_min_deg
        b.severity = 2;
        b.findings{end+1} = sprintf( ...
            'R take-off %.1f° < %.0f° — the R centerline never diverged from the aortic axis. Segmentation did not cross the bifurcation on the R side.', ...
            theta_R_deg, opts.takeoff_angle_min_deg);
    end
    if theta_L_deg < opts.takeoff_angle_min_deg
        b.severity = 2;
        b.findings{end+1} = sprintf( ...
            'L take-off %.1f° < %.0f° — the L centerline never diverged from the aortic axis. Segmentation did not cross the bifurcation on the L side.', ...
            theta_L_deg, opts.takeoff_angle_min_deg);
    end
    if theta_R_deg > opts.takeoff_angle_max_deg || theta_L_deg > opts.takeoff_angle_max_deg
        b.severity = max(b.severity, 1);
        b.findings{end+1} = sprintf( ...
            'One take-off angle > %.0f° — extreme iliac angulation; verify the proximal landing-zone measurements.', ...
            opts.takeoff_angle_max_deg);
    end
    report.blocks{end+1} = b; clear b;

    % --- Block 7: bilateral take-off symmetry ------------------------
    % Diagnostic only when an aorta centerline was supplied (Pv_aorta_mm).
    % Without it, the aortic axis is derived as -(t_R + t_L), which is
    % symmetric in L and R by construction, so the asymmetry is always
    % zero and the block carries no information. In that case the block
    % is reported as OK with a note.
    b.name = 'Bilateral take-off-angle symmetry';
    b.findings = {}; b.severity = 0;
    dtheta = abs(theta_R_deg - theta_L_deg);
    if strcmp(asym_axis_source, 'aorta')
        b.findings{end+1} = sprintf('|θ_R - θ_L| = %.1f° (tol %.0f°, aortic axis from aorta centerline).', ...
            dtheta, opts.takeoff_symmetry_deg);
        if dtheta > opts.takeoff_symmetry_deg
            b.severity = max(b.severity, 1);
            b.findings{end+1} = sprintf( ...
                'Take-off-angle asymmetry %.1f° exceeds %.0f° — one side likely entered a side branch (e.g. hypogastric) rather than the iliac trunk. The more-angulated side is the one to review.', ...
                dtheta, opts.takeoff_symmetry_deg);
        end
    else
        b.findings{end+1} = sprintf( ...
            ['|θ_R - θ_L| = %.1f° (always 0 when no aorta centerline is supplied — the ' ...
             'fallback axis is symmetric in L and R by construction; pass Pv_aorta_mm as ' ...
             'the 4th argument to get a real measurement).'], dtheta);
    end
    report.blocks{end+1} = b;

    report = finalize(report);
end

function [theta_R_deg, theta_L_deg, axis_source] = takeoff_angles_deg( ...
        Pv_R, Pv_L, p_R, p_L, Pv_aorta)
% Take-off angles between each iliac mean tangent and the aortic long
% axis at the bifurcation. Returns angles in degrees (0-180) and the
% axis source: 'aorta' if the aortic axis came from Pv_aorta, 'iliac'
% if it was reconstructed from -(t_R + t_L) (the symmetric fallback).
%
% The mean iliac tangent is computed over the first ~15 mm of arc from
% the proximal end so a single noisy first node can't dominate.
    if nargin < 5 || isempty(Pv_aorta); Pv_aorta = zeros(0, 3); end
    baseline_mm = 15;
    t_R = mean_tangent_from_end(Pv_R, p_R, baseline_mm);
    t_L = mean_tangent_from_end(Pv_L, p_L, baseline_mm);
    if isempty(t_R) || isempty(t_L) || norm(t_R) < 1e-9 || norm(t_L) < 1e-9
        theta_R_deg = 0; theta_L_deg = 0; axis_source = 'iliac'; return;
    end
    t_R = t_R / norm(t_R);
    t_L = t_L / norm(t_L);

    % Prefer the aortic axis derived from the aorta centerline itself:
    % use the tangent over the last 15 mm of arc approaching the
    % bifurcation. That tangent points DISTALLY (toward the iliacs),
    % so its negative is the cranial aortic axis.
    if size(Pv_aorta, 1) >= 3
        bif = (p_R + p_L) / 2;
        t_aorta = aorta_distal_tangent(Pv_aorta, bif, baseline_mm);
        if ~isempty(t_aorta) && norm(t_aorta) > 1e-9
            aortic_axis = -t_aorta / norm(t_aorta);   % cranial direction
            axis_source = 'aorta';
        else
            aortic_axis = -(t_R + t_L);
            if norm(aortic_axis) < 1e-9
                aortic_axis = [0, 0, -1];
            else
                aortic_axis = aortic_axis / norm(aortic_axis);
            end
            axis_source = 'iliac';
        end
    else
        aortic_axis = -(t_R + t_L);
        if norm(aortic_axis) < 1e-9
            aortic_axis = [0, 0, -1];
        else
            aortic_axis = aortic_axis / norm(aortic_axis);
        end
        axis_source = 'iliac';
    end

    % Iliac take-off direction is "down the aorta then out" — measure
    % the angle from -aortic_axis (= caudal direction).
    cos_R = max(min(dot(t_R, -aortic_axis), 1), -1);
    cos_L = max(min(dot(t_L, -aortic_axis), 1), -1);
    theta_R_deg = acosd(cos_R);
    theta_L_deg = acosd(cos_L);
end

function t = aorta_distal_tangent(Pv_aorta, bif_xyz, baseline_mm)
% Mean tangent of the aorta centerline over the `baseline_mm` of arc
% immediately proximal to the bifurcation node. Returns a 1x3 (mm)
% direction vector pointing distally (toward the iliac bifurcation).
    n = size(Pv_aorta, 1);
    if n < 3; t = []; return; end
    % Identify the distal end (closest to the bifurcation).
    if norm(Pv_aorta(end, :) - bif_xyz) <= norm(Pv_aorta(1, :) - bif_xyz)
        Q = Pv_aorta;                         % distal-last
    else
        Q = Pv_aorta(end:-1:1, :);            % flip so distal is last
    end
    d1 = diff(Q, 1, 1);
    ds = vecnorm(d1, 2, 2);
    cum = cumsum(ds, 'reverse');              % arc length remaining
    first = find(cum <= baseline_mm, 1, 'first');
    if isempty(first); first = max(1, size(Q, 1) - 1); end
    t = Q(end, :) - Q(first, :);              % distal-pointing
end

function t = mean_tangent_from_end(Pv, p_anchor, baseline_mm)
% Mean tangent over the first `baseline_mm` of arc from whichever end
% of Pv is closer to p_anchor. Returns a 1x3 row vector (unnormalized).
    n = size(Pv, 1);
    if n < 2; t = []; return; end
    % Identify proximal end (closer to anchor)
    if norm(Pv(1, :) - p_anchor) <= norm(Pv(end, :) - p_anchor)
        Q = Pv;                              % already proximal-first
    else
        Q = Pv(end:-1:1, :);                 % reverse so node 1 is proximal
    end
    d1 = diff(Q, 1, 1);
    ds = vecnorm(d1, 2, 2);
    cum = cumsum(ds);
    last = find(cum <= baseline_mm, 1, 'last');
    if isempty(last) || last < 1
        last = min(1, size(d1, 1));
    end
    t = Q(last + 1, :) - Q(1, :);
end

function [p_R, p_L, d_R, d_L] = pair_proximal_ends(R, L)
% Choose which end of each centerline is the proximal one.
% Test all 4 end-pairings; the proximal-proximal pair is the one
% with smallest 3D distance (they share the bifurcation).
    candidates = {
        R(1, :)   L(1, :)   R(end, :) L(end, :);
        R(1, :)   L(end, :) R(end, :) L(1, :);
        R(end, :) L(1, :)   R(1, :)   L(end, :);
        R(end, :) L(end, :) R(1, :)   L(1, :)};
    best_d = Inf; best_k = 1;
    for k = 1:size(candidates, 1)
        d = norm(candidates{k, 1} - candidates{k, 2});
        if d < best_d; best_d = d; best_k = k; end
    end
    p_R = candidates{best_k, 1};
    p_L = candidates{best_k, 2};
    d_R = candidates{best_k, 3};
    d_L = candidates{best_k, 4};
end

function n = count_z_reversals(z)
% Count how many nodes have a z-step in the opposite direction from
% the overall trend (proximal→distal). The overall direction is the
% sign of (z(end) - z(1)).
    dz = diff(z);
    overall = sign(z(end) - z(1));
    if overall == 0; n = 0; return; end
    n = sum(sign(dz) ~= overall & sign(dz) ~= 0);
end

function k = total_abs_curvature(P)
% Total absolute curvature ∫|κ|ds along a polyline. Uses simple
% second-derivative magnitude / first-derivative magnitude estimate.
    if size(P, 1) < 3; k = 0; return; end
    d1 = diff(P, 1, 1);
    d2 = diff(P, 2, 1);
    ds = vecnorm(d1, 2, 2);
    ds(ds < 1e-9) = 1e-9;
    % κ ≈ |T'(s)| where T(s) = d1/|d1|. Approximate with cross-product
    % method for stability:
    n = size(d2, 1);
    kappa = zeros(n, 1);
    for i = 1:n
        a = d1(i, :);   b = d1(i+1, :);
        na = norm(a);   nb = norm(b);
        if na < 1e-9 || nb < 1e-9; continue; end
        c = cross(a, b);
        sin_th = norm(c) / (na * nb);
        kappa(i) = sin_th / ((na + nb) / 2);   % per unit arc
    end
    k = sum(kappa .* ((ds(1:end-1) + ds(2:end)) / 2));
end

function report = finalize(report)
    sev = cellfun(@(b) b.severity, report.blocks);
    report.passed = ~any(sev >= 2);
    glyph = {'OK', 'WARN', 'FAIL'};
    lines = {'=== SE(3) cross-vessel rule check ==='};
    for k = 1:numel(report.blocks)
        b = report.blocks{k};
        lines{end+1} = sprintf('[%s] %s', glyph{b.severity+1}, b.name); %#ok<AGROW>
        for f = 1:numel(b.findings)
            lines{end+1} = ['    - ' b.findings{f}]; %#ok<AGROW>
        end
    end
    report.summary_text = strjoin(lines, newline);
end
