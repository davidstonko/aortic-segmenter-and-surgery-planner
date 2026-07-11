function model = build_shape_model(opts)
%LIBRARY.AAA100.BUILD_SHAPE_MODEL  Procrustes-aligned statistical shape
%   model of the AAA-100 reference centerlines.
%
%   model = library.aaa100.build_shape_model()
%   model = library.aaa100.build_shape_model(opts)
%
%   Each vessel is resampled to a fixed number of nodes (uniform in
%   arc length), Procrustes-aligned across cases (translation + rotation
%   + isotropic scale), and reduced to a mean ± std shape. Useful as
%   an anatomic prior (regularizer for centerline solvers, sanity
%   bound for new cases).
%
%   Returns a struct:
%       model.aorta.mean         (N,3) mean aortic centerline, mm-scale
%       model.aorta.std          (N,3) per-node std
%       model.aorta.scale_median median scale factor that aligned each
%                                case to the cohort mean (mm/unit)
%       (same fields for iliac_L, iliac_R, renal_L, renal_R)
%
%       model.bifurcation_xy_mm  per-case L iliac proximal - R iliac
%                                proximal vector (cohort-level bifurcation
%                                spread)
%       model.takeoff_angle_deg  Nx2 (R, L) take-off angles at the iliac
%                                proximal end
%       model.opts               opts used to build the model
%       model.n_cases            number of contributing cases
%
%   OPTS:
%       .n_resample              default 50 — nodes per resampled vessel
%       .vessels                 default all 5
%       .save_path               default <cache_root>/aaa100_shape_model.mat

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'n_resample'); opts.n_resample = 50; end
    if ~isfield(opts, 'vessels');    opts.vessels = ...
        {'aorta', 'iliac_L', 'iliac_R', 'renal_L', 'renal_R'}; end
    if ~isfield(opts, 'save_path');  opts.save_path = ...
        fullfile(library.aaa100.cache_root(), 'aaa100_shape_model.mat'); end

    cases = library.aaa100.load_all();
    N = opts.n_resample;
    model = struct('opts', opts, 'n_cases', numel(cases));

    for v = opts.vessels
        vname = v{1};
        all_curves = zeros(N, 3, 0);
        scales = [];
        for i = 1:numel(cases)
            P = cases(i).(vname);
            if size(P, 1) < 4; continue; end
            Pr = resample_polyline(P, N);
            % Centre at centroid
            ctr = mean(Pr, 1);
            Pc = Pr - ctr;
            % Normalize scale (median pairwise distance set to 1)
            s = norm(Pc(end, :) - Pc(1, :));
            if s < 1e-9; continue; end
            scales(end+1, 1) = s; %#ok<AGROW>
            Pn = Pc / s;
            % Procrustes-align to the first contributed curve
            if isempty(all_curves)
                R = eye(3);
            else
                ref = all_curves(:, :, 1);
                R = procrustes_rotation(Pn, ref);
            end
            all_curves(:, :, end+1) = Pn * R; %#ok<AGROW>
        end
        if isempty(all_curves)
            model.(vname) = struct('mean', [], 'std', [], 'scale_median', NaN, 'n', 0);
            continue;
        end
        % After first-curve alignment, refine to the cohort mean over
        % a few iterations (generalized Procrustes).
        for it = 1:5
            mean_curve = mean(all_curves, 3);
            for k = 1:size(all_curves, 3)
                R = procrustes_rotation(all_curves(:, :, k), mean_curve);
                all_curves(:, :, k) = all_curves(:, :, k) * R;
            end
        end
        mean_norm = mean(all_curves, 3);
        std_norm  = std(all_curves, 0, 3);
        scale_med = median(scales);
        model.(vname) = struct( ...
            'mean', mean_norm * scale_med, ...
            'std',  std_norm * scale_med, ...
            'scale_median', scale_med, ...
            'n', size(all_curves, 3));
    end

    % Bifurcation spread + take-off angles (uses raw, not aligned curves)
    bif_xy = []; takeoff = [];
    for i = 1:numel(cases)
        L = cases(i).iliac_L;
        R = cases(i).iliac_R;
        if size(L, 1) < 3 || size(R, 1) < 3; continue; end
        bif_xy(end+1, :) = L(1, :) - R(1, :); %#ok<AGROW>
        [thR, thL] = takeoff_angles(R, L);
        takeoff(end+1, :) = [thR, thL]; %#ok<AGROW>
    end
    model.bifurcation_xy_mm = bif_xy;
    model.takeoff_angle_deg = takeoff;

    save(opts.save_path, '-struct', 'model');
    fprintf('Saved %s\n', opts.save_path);
end

function Q = resample_polyline(P, N)
% Uniform-arc-length resample to N nodes.
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
    % Reflect-fix to keep det(R) = +1
    if det(R) < 0
        V(:, end) = -V(:, end);
        R = U * V';
    end
end

function [thR, thL] = takeoff_angles(R, L)
    base = 15;
    tR = tangent_baseline(R, base);
    tL = tangent_baseline(L, base);
    if norm(tR) < 1e-9 || norm(tL) < 1e-9
        thR = NaN; thL = NaN; return;
    end
    tR = tR / norm(tR);
    tL = tL / norm(tL);
    ax = -(tR + tL); if norm(ax) < 1e-9; ax = [0,0,-1]; else; ax = ax/norm(ax); end
    thR = acosd(max(min(dot(tR, -ax), 1), -1));
    thL = acosd(max(min(dot(tL, -ax), 1), -1));
end

function t = tangent_baseline(P, baseline)
    d = vecnorm(diff(P), 2, 2);
    c = cumsum(d);
    last = find(c <= baseline, 1, 'last');
    if isempty(last); last = min(1, size(d, 1)); end
    t = P(last + 1, :) - P(1, :);
end
