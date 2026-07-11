function score = score_centerline(Pv_mm, vessel_type, opts)
%LIBRARY.AAA100.SCORE_CENTERLINE  Compare one centerline to the AAA-100
%   population distribution. Returns a per-metric population percentile
%   for arc length / tortuosity / κ_max / |τ|_max plus a Mahalanobis-
%   style shape-deviation score against the Procrustes mean.
%
%   score = library.aaa100.score_centerline(Pv_mm, vessel_type)
%   score = library.aaa100.score_centerline(Pv_mm, vessel_type, opts)
%
%   Pv_mm        (:,3) double, [X_mm, Y_mm, Z_mm], proximal → distal
%   vessel_type  char: 'aorta' | 'iliac_L' | 'iliac_R' | 'renal_L' | 'renal_R'
%   opts.verbose default true — print a per-metric summary
%
%   Returns a struct:
%       .vessel_type
%       .arc_mm                  arc length of the input centerline
%       .arc_pct                 percentile in AAA-100 cohort (0-100)
%       .tortuosity              arc / Euclidean
%       .tortuosity_pct          ...
%       .kappa_max_per_mm
%       .kappa_max_pct
%       .tau_max_per_mm
%       .tau_max_pct
%       .shape_deviation_mm      RMS per-node distance to Procrustes-
%                                aligned cohort mean shape (mm)
%       .shape_deviation_pct     ...
%       .outlier                 logical true if ANY of arc, tortuosity,
%                                κ_max, |τ|_max, shape is in the bottom
%                                or top 5% of the cohort
%       .note                    diagnostic text
%
%   Use as a sanity gate: after the centerline solver produces a result,
%   run this scorer on each vessel; flag patients whose anatomy lies
%   outside the population for human review.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        Pv_mm       (:,3) double
        vessel_type (1,:) char {mustBeMember(vessel_type, ...
            {'aorta', 'iliac_L', 'iliac_R', 'renal_L', 'renal_R'})}
        opts        (1,1) struct = struct()
    end
    if ~isfield(opts, 'verbose'); opts.verbose = true; end

    score = struct('vessel_type', vessel_type, 'outlier', false, ...
        'arc_mm', NaN, 'arc_pct', NaN, ...
        'tortuosity', NaN, 'tortuosity_pct', NaN, ...
        'kappa_max_per_mm', NaN, 'kappa_max_pct', NaN, ...
        'tau_max_per_mm', NaN, 'tau_max_pct', NaN, ...
        'shape_deviation_mm', NaN, 'shape_deviation_pct', NaN, ...
        'note', '');

    if size(Pv_mm, 1) < 4
        score.note = sprintf('Centerline has only %d nodes; cannot score.', size(Pv_mm, 1));
        return;
    end

    % Per-vessel metrics on the input
    geom = compute_geom(Pv_mm);
    score.arc_mm           = geom.arc;
    score.tortuosity       = geom.tortuosity;
    score.kappa_max_per_mm = geom.kappa_max;
    score.tau_max_per_mm   = geom.tau_max;

    % Reference cohort distributions
    cohort_path = fullfile(library.aaa100.cache_root(), 'aaa100_se3_calibration.mat');
    if ~isfile(cohort_path)
        score.note = sprintf( ...
            ['AAA-100 calibration cache not found at %s. Run ' ...
             'scripts/calibrate_se3_thresholds() once to build it.'], cohort_path);
        return;
    end
    cal = load(cohort_path);
    vstats = cal.per_vessel.(vessel_type);

    score.arc_pct        = percentile_of(geom.arc, vstats.arc_mm);
    score.tortuosity_pct = percentile_of(geom.tortuosity, vstats.tortuosity);
    score.kappa_max_pct  = percentile_of(geom.kappa_max, vstats.kappa_max);
    score.tau_max_pct    = percentile_of(geom.tau_max, vstats.tau_max);

    % Shape deviation from the Procrustes-aligned cohort mean.
    shape_path = fullfile(library.aaa100.cache_root(), 'aaa100_shape_model.mat');
    if isfile(shape_path)
        sm = load(shape_path);
        if isfield(sm, vessel_type) && ~isempty(sm.(vessel_type).mean)
            mean_shape = sm.(vessel_type).mean;       % (N, 3)
            scale_med  = sm.(vessel_type).scale_median;
            N = size(mean_shape, 1);
            Pr = resample_polyline(Pv_mm, N);
            % Centre + normalise scale to match the model's normalisation
            ctr = mean(Pr, 1);
            Pn = (Pr - ctr) / max(norm(Pr(end, :) - Pr(1, :)), 1e-9);
            Mn = mean_shape / scale_med;              % bring mean back to unit scale
            % Procrustes-align Pn to Mn
            R = procrustes_rotation(Pn, Mn);
            Pa = Pn * R;
            % RMS per-node distance, in mm (multiply by scale_med to restore mm)
            d_mm = vecnorm(Pa - Mn, 2, 2) * scale_med;
            score.shape_deviation_mm = sqrt(mean(d_mm .^ 2));
            % Per-node std as the "expected" deviation under the cohort
            % (so the percentile reflects "how many σ off the mean")
            std_per_node_mm = vecnorm(sm.(vessel_type).std, 2, 2);
            expected_dev_mm = sqrt(mean(std_per_node_mm .^ 2));
            % Convert to a 0-100 percentile assuming a chi-squared-like
            % distribution where 1σ ≈ 68th, 2σ ≈ 95th, 3σ ≈ 99.7th
            z = score.shape_deviation_mm / max(expected_dev_mm, 1e-9);
            score.shape_deviation_pct = 100 * (1 - exp(-z^2 / 2));
        end
    end

    % Outlier detection: any metric in the bottom or top 5% is flagged.
    pcts = [score.arc_pct, score.tortuosity_pct, score.kappa_max_pct, ...
            score.tau_max_pct, score.shape_deviation_pct];
    pcts = pcts(~isnan(pcts));
    score.outlier = any(pcts < 5 | pcts > 95);

    if opts.verbose
        fprintf('[score_centerline] %s\n', vessel_type);
        fprintf('  arc           %6.1f mm     (population p%2.0f)\n', geom.arc, score.arc_pct);
        fprintf('  tortuosity    %6.2f        (population p%2.0f)\n', geom.tortuosity, score.tortuosity_pct);
        fprintf('  kappa_max     %6.3f mm⁻¹   (population p%2.0f)\n', geom.kappa_max, score.kappa_max_pct);
        fprintf('  tau_max       %6.3f mm⁻¹   (population p%2.0f)\n', geom.tau_max, score.tau_max_pct);
        if ~isnan(score.shape_deviation_mm)
            fprintf('  shape_dev_RMS %6.1f mm     (population p%2.0f)\n', ...
                score.shape_deviation_mm, score.shape_deviation_pct);
        end
        if score.outlier
            fprintf('  ** OUTLIER ** (at least one metric outside cohort p5-p95 band)\n');
        end
    end
end

function out = compute_geom(P)
% κ_max, |τ|_max, arc length, tortuosity on a polyline.
    n = size(P, 1);
    d1 = diff(P, 1, 1);
    ds = vecnorm(d1, 2, 2);
    ds(ds < 1e-9) = 1e-9;
    arc = sum(ds);
    eucl = norm(P(end, :) - P(1, :));
    out.arc = arc;
    out.tortuosity = arc / max(eucl, 1e-9);
    kappa = zeros(max(0, n-2), 1);
    for i = 1:n-2
        a = d1(i, :);   b = d1(i+1, :);
        na = norm(a);   nb = norm(b);
        if na < 1e-9 || nb < 1e-9; continue; end
        kappa(i) = norm(cross(a, b)) / (na * nb) / ((na + nb) / 2);
    end
    out.kappa_max = max(kappa);
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
end

function p = percentile_of(value, cohort_values)
% Return the percentile of `value` in `cohort_values` (0-100).
    v = sort(cohort_values(~isnan(cohort_values)));
    if isempty(v); p = NaN; return; end
    p = 100 * sum(v <= value) / numel(v);
end

function Q = resample_polyline(P, N)
    d = vecnorm(diff(P), 2, 2);
    s = [0; cumsum(d)];
    if s(end) < 1e-9
        Q = repmat(P(1, :), N, 1); return;
    end
    s_new = linspace(0, s(end), N)';
    Q = interp1(s, P, s_new, 'pchip');
end

function R = procrustes_rotation(A, B)
% Orthogonal Procrustes: find R such that A*R ≈ B (no scale, no translation).
    M = A' * B;
    [U, ~, V] = svd(M);
    R = U * V';
    if det(R) < 0
        V(:, end) = -V(:, end);
        R = U * V';
    end
end
