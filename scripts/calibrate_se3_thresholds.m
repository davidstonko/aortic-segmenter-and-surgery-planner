function out = calibrate_se3_thresholds()
%CALIBRATE_SE3_THRESHOLDS  Empirical SE(3) rule-threshold distributions
%   over the AAA-100 reference cohort.
%
%   out = calibrate_se3_thresholds()
%
%   Walks every reference centerline (aorta + iliac_L/R + renal_L/R) in
%   the AAA-100 dataset and computes, for each:
%
%       arc_length_mm
%       tortuosity         arc / Euclidean
%       kappa_max          1/mm  (max local curvature)
%       tau_max            1/mm  (max abs torsion)
%       max_tan_deg        adjacent-tangent angle, degrees
%
%   Per-vessel summary statistics (median / 95th / 99th percentile) are
%   printed so the project can set FAIL thresholds at, e.g., the 99th
%   percentile of real anatomy. Returns a struct with the raw arrays
%   for downstream analysis.
%
%   Cross-vessel statistics over the iliac pair (one pair per case):
%       d_bifurc_mm        L/R proximal endpoint distance
%       takeoff_R_deg / takeoff_L_deg  (over 15 mm of arc)
%       takeoff_asym_deg   |θ_R - θ_L|
%       y_asym_mm          |y_R - y_L| at distal CFA-end of iliac
%       kappa_ratio        max/min of integrated absolute curvature

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    here = fileparts(fileparts(mfilename('fullpath')));
    addpath(here);

    cases = library.aaa100.load_all();
    n = numel(cases);
    fprintf('AAA-100 SE(3) threshold calibration over %d cases.\n\n', n);

    vessels = {'aorta', 'iliac_L', 'iliac_R', 'renal_L', 'renal_R'};
    stats = struct();
    for v = vessels
        stats.(v{1}) = init_stats();
    end
    cross = init_cross_stats();

    for i = 1:n
        c = cases(i);
        % Per-vessel diff-geometry
        for v = vessels
            P = c.(v{1});
            if size(P, 1) < 4; continue; end
            s = compute_geom_stats(P);
            stats.(v{1}) = push_stats(stats.(v{1}), s);
        end
        % Cross-vessel iliac stats
        if size(c.iliac_L, 1) >= 3 && size(c.iliac_R, 1) >= 3
            cs = compute_cross_stats(c.iliac_R, c.iliac_L);
            cross = push_cross(cross, cs);
        end
        if mod(i, 20) == 0
            fprintf('  processed %d / %d cases\n', i, n);
        end
    end

    out = struct('per_vessel', stats, 'cross_iliac', cross);

    fprintf('\n--- Per-vessel distributions (median, 95th, 99th, max) ---\n');
    for v = vessels
        vname = v{1};
        s = stats.(vname);
        fprintf('\n[%s] N=%d\n', vname, numel(s.arc_mm));
        report_percentiles('arc_mm',       s.arc_mm,       'mm',     '%6.0f');
        report_percentiles('tortuosity',   s.tortuosity,   '',       '%6.3f');
        report_percentiles('kappa_max',    s.kappa_max,    'mm^-1',  '%6.4f');
        report_percentiles('tau_max',      s.tau_max,      'mm^-1',  '%6.4f');
        report_percentiles('max_tan_deg',  s.max_tan_deg,  'deg',    '%6.1f');
    end

    fprintf('\n--- Cross-vessel iliac-pair distributions ---\n');
    fprintf('N=%d cases with both iliacs\n', numel(cross.d_bifurc_mm));
    report_percentiles('d_bifurc_mm',     cross.d_bifurc_mm,     'mm',  '%6.1f');
    report_percentiles('takeoff_R_deg',   cross.takeoff_R_deg,   'deg', '%6.1f');
    report_percentiles('takeoff_L_deg',   cross.takeoff_L_deg,   'deg', '%6.1f');
    report_percentiles('takeoff_asym_deg', cross.takeoff_asym_deg, 'deg', '%6.1f');
    report_percentiles('y_asym_mm',       cross.y_asym_mm,       'mm',  '%6.1f');
    report_percentiles('kappa_ratio',     cross.kappa_ratio,     'x',   '%6.2f');

    % Save raw arrays for downstream analysis / plotting
    out_path = fullfile(library.aaa100.cache_root(), 'aaa100_se3_calibration.mat');
    save(out_path, '-struct', 'out');
    fprintf('\nSaved %s\n', out_path);

    fprintf('\nRecommended thresholds (set FAIL at 99th percentile of real anatomy):\n');
    fprintf('  kappa_max_per_mm  = %.3f (aorta 99th: %.3f, iliacs 99th: max %.3f)\n', ...
        max([pctile(stats.aorta.kappa_max, 99), pctile(stats.iliac_L.kappa_max, 99), ...
             pctile(stats.iliac_R.kappa_max, 99)]), ...
        pctile(stats.aorta.kappa_max, 99), ...
        max(pctile(stats.iliac_L.kappa_max, 99), pctile(stats.iliac_R.kappa_max, 99)));
    fprintf('  tau_max_per_mm    = %.3f\n', ...
        max([pctile(stats.aorta.tau_max, 99), pctile(stats.iliac_L.tau_max, 99), ...
             pctile(stats.iliac_R.tau_max, 99)]));
    fprintf('  tan_angle_max_deg = %.1f\n', ...
        max([pctile(stats.aorta.max_tan_deg, 99), pctile(stats.iliac_L.max_tan_deg, 99), ...
             pctile(stats.iliac_R.max_tan_deg, 99)]));
    fprintf('  tortuosity_max    = %.2f\n', ...
        max([pctile(stats.aorta.tortuosity, 99), pctile(stats.iliac_L.tortuosity, 99), ...
             pctile(stats.iliac_R.tortuosity, 99)]));
    fprintf('  bifurc_tol_mm     = %.1f (cross 99th)\n', ...
        pctile(cross.d_bifurc_mm, 99));
    fprintf('  takeoff_angle range [%.0f, %.0f] deg (cross 1st-99th)\n', ...
        min(pctile(cross.takeoff_R_deg, 1), pctile(cross.takeoff_L_deg, 1)), ...
        max(pctile(cross.takeoff_R_deg, 99), pctile(cross.takeoff_L_deg, 99)));
    fprintf('  takeoff_symmetry_deg = %.1f (99th)\n', ...
        pctile(cross.takeoff_asym_deg, 99));
end

function s = init_stats()
    s = struct('arc_mm', [], 'tortuosity', [], ...
               'kappa_max', [], 'tau_max', [], 'max_tan_deg', []);
end

function s = push_stats(s, n)
    s.arc_mm(end+1, 1)      = n.arc_mm;
    s.tortuosity(end+1, 1)  = n.tortuosity;
    s.kappa_max(end+1, 1)   = n.kappa_max;
    s.tau_max(end+1, 1)     = n.tau_max;
    s.max_tan_deg(end+1, 1) = n.max_tan_deg;
end

function out = compute_geom_stats(P)
% Differential-geometry stats on a polyline P (Nx3 mm, proximal→distal).
    d1 = diff(P, 1, 1);
    ds = vecnorm(d1, 2, 2);
    ds(ds < 1e-9) = 1e-9;
    arc = sum(ds);
    eucl = norm(P(end, :) - P(1, :));
    out.arc_mm     = arc;
    out.tortuosity = arc / max(eucl, 1e-9);
    % κ via cross-product
    n = size(P, 1);
    kappa = zeros(n-2, 1);
    for i = 1:n-2
        a = d1(i, :);   b = d1(i+1, :);
        na = norm(a);   nb = norm(b);
        if na < 1e-9 || nb < 1e-9; continue; end
        kappa(i) = norm(cross(a, b)) / (na * nb) / ((na + nb) / 2);
    end
    out.kappa_max = max(kappa);
    % τ via triple product
    tau = zeros(max(0, n-3), 1);
    for i = 1:n-3
        a = d1(i, :); b = d1(i+1, :); c = d1(i+2, :);
        ab = cross(a, b);
        den = dot(ab, ab);
        if den < 1e-12; continue; end
        ds_mid = mean([norm(a), norm(b), norm(c)]);
        if ds_mid < 1e-9; continue; end
        tau(i) = dot(ab, c) / den / ds_mid;
    end
    out.tau_max = max(abs(tau));
    % Adjacent-tangent angle
    T = d1 ./ ds;
    cth = sum(T(1:end-1, :) .* T(2:end, :), 2);
    cth = max(min(cth, 1), -1);
    out.max_tan_deg = max(acosd(cth));
end

function c = init_cross_stats()
    c = struct('d_bifurc_mm', [], 'takeoff_R_deg', [], 'takeoff_L_deg', [], ...
               'takeoff_asym_deg', [], 'y_asym_mm', [], 'kappa_ratio', []);
end

function cross = push_cross(cross, cs)
    cross.d_bifurc_mm(end+1, 1)      = cs.d_bifurc_mm;
    cross.takeoff_R_deg(end+1, 1)    = cs.takeoff_R_deg;
    cross.takeoff_L_deg(end+1, 1)    = cs.takeoff_L_deg;
    cross.takeoff_asym_deg(end+1, 1) = cs.takeoff_asym_deg;
    cross.y_asym_mm(end+1, 1)        = cs.y_asym_mm;
    cross.kappa_ratio(end+1, 1)      = cs.kappa_ratio;
end

function out = compute_cross_stats(R, L)
% Bilateral cross-vessel stats over the iliac pair (proximal→distal).
%   Proximal end of each = node 1 (we trust the dataset ordering).
    p_R = R(1, :); p_L = L(1, :);
    d_R = R(end, :); d_L = L(end, :);
    out.d_bifurc_mm = norm(p_R - p_L);
    out.y_asym_mm   = abs(d_R(2) - d_L(2));
    [thR, thL] = takeoff_angles(R, L, p_R, p_L);
    out.takeoff_R_deg = thR;
    out.takeoff_L_deg = thL;
    out.takeoff_asym_deg = abs(thR - thL);
    kR = abs_curvature(R);
    kL = abs_curvature(L);
    if min(kR, kL) > 0
        out.kappa_ratio = max(kR, kL) / min(kR, kL);
    else
        out.kappa_ratio = NaN;
    end
end

function k = abs_curvature(P)
% ∫|κ|ds over a polyline.
    n = size(P, 1);
    if n < 3; k = 0; return; end
    d1 = diff(P, 1, 1);
    ds = vecnorm(d1, 2, 2);
    ds(ds < 1e-9) = 1e-9;
    kappa = zeros(n-2, 1);
    for i = 1:n-2
        a = d1(i, :);   b = d1(i+1, :);
        na = norm(a);   nb = norm(b);
        if na < 1e-9 || nb < 1e-9; continue; end
        sin_th = norm(cross(a, b)) / (na * nb);
        kappa(i) = sin_th / ((na + nb) / 2);
    end
    k = sum(kappa .* ((ds(1:end-1) + ds(2:end)) / 2));
end

function [thR, thL] = takeoff_angles(R, L, p_R, p_L)
    baseline = 15;
    t_R = mean_tangent(R, p_R, baseline);
    t_L = mean_tangent(L, p_L, baseline);
    if norm(t_R) < 1e-9 || norm(t_L) < 1e-9
        thR = NaN; thL = NaN; return;
    end
    t_R = t_R / norm(t_R);  t_L = t_L / norm(t_L);
    ax = -(t_R + t_L);
    if norm(ax) < 1e-9; ax = [0, 0, -1]; else; ax = ax / norm(ax); end
    thR = acosd(max(min(dot(t_R, -ax), 1), -1));
    thL = acosd(max(min(dot(t_L, -ax), 1), -1));
end

function t = mean_tangent(Pv, p_anchor, baseline_mm)
    if norm(Pv(1, :) - p_anchor) <= norm(Pv(end, :) - p_anchor)
        Q = Pv;
    else
        Q = Pv(end:-1:1, :);
    end
    d1 = diff(Q, 1, 1);
    ds = vecnorm(d1, 2, 2);
    cum = cumsum(ds);
    last = find(cum <= baseline_mm, 1, 'last');
    if isempty(last); last = min(1, size(d1, 1)); end
    t = Q(last + 1, :) - Q(1, :);
end

function report_percentiles(name, v, unit, fmt)
    v = v(~isnan(v));
    if isempty(v)
        fprintf('  %-15s  (no data)\n', name);
        return;
    end
    f = ['  %-15s  median ' fmt '  p95 ' fmt '  p99 ' fmt '  max ' fmt '  %s\n'];
    fprintf(f, name, median(v), pctile(v, 95), pctile(v, 99), max(v), unit);
end

function p = pctile(v, q)
    v = sort(v(~isnan(v)));
    if isempty(v); p = NaN; return; end
    p = v(max(1, min(numel(v), round(q/100 * numel(v)))));
end
