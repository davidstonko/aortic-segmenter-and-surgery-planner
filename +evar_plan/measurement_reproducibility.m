function rep = measurement_reproducibility(planner_result, opts)
%EVAR_PLAN.MEASUREMENT_REPRODUCIBILITY  Quantify how stable the EVAR sizing
%   measurements are under small geometric perturbations of the input
%   centerline, and report a reproducibility band.
%
%   REP = evar_plan.measurement_reproducibility(PLANNER_RESULT)
%   REP = evar_plan.measurement_reproducibility(PLANNER_RESULT, OPTS)
%
%   For each trial the centerline (both iliac polylines + their radius
%   profiles) is perturbed by (i) a random rigid rotation about a random
%   axis and (ii) arc-resampling at a jittered node spacing — the two
%   nuisance transforms a real re-acquisition / re-slicing introduces.
%   Diameters and angles are rotation-invariant, so any spread they show
%   is pure numerical noise; neck LENGTH and beta are the quantities the
%   onset detector makes sensitive to resampling, so their band is the
%   headline reproducibility number (and what the aneurysm-onset
%   hysteresis in measure_from_centerline is designed to tighten).
%
%   OPTS (all optional):
%     .n_trials       number of perturbed re-measurements   (default 24)
%     .max_rot_deg    max |rotation| about a random axis, deg (default 3)
%     .resample_frac  fractional node-spacing jitter; spacing scaled by
%                     1 ± this per trial                     (default 0.15)
%     .seed           RNG seed, so the band is deterministic (default 20260711)
%     .measure_opts   opts struct forwarded to measure_from_centerline
%     .verbose        print the summary table               (default true)
%
%   REP fields:
%     .fields    cellstr of the scalar measurements tracked
%     .baseline  struct name->value on the UNPERTURBED input
%     .mean/.std/.range/.cv  struct name->stat across trials (NaNs, e.g.
%               neck_length when no aneurysm, are excluded before the stat)
%     .n_valid   struct name->count of finite trial values
%     .n_trials, .params
%     .table     summary table (measurement, baseline, mean, std, range)
%
%   RESEARCH USE ONLY — a methods-reproducibility diagnostic, not a
%   clinical tolerance.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        planner_result (1,1) struct
        opts           (1,1) struct = struct()
    end
    if ~isfield(opts, 'n_trials');      opts.n_trials      = 24;        end
    if ~isfield(opts, 'max_rot_deg');   opts.max_rot_deg   = 3;         end
    if ~isfield(opts, 'resample_frac'); opts.resample_frac = 0.15;      end
    if ~isfield(opts, 'seed');          opts.seed          = 20260711;  end
    if ~isfield(opts, 'measure_opts');  opts.measure_opts  = struct();  end
    if ~isfield(opts, 'verbose');       opts.verbose       = true;      end

    FIELDS = {'neck_diameter_mm', 'neck_length_mm', ...
              'neck_angulation_alpha_deg', 'neck_angulation_beta_deg', ...
              'neck_angulation_deg', 'iliac_R_diameter_mm', ...
              'iliac_L_diameter_mm', 'aneurysm_max_diameter_mm'};

    % --- Baseline (unperturbed) -------------------------------------
    base = evar_plan.measure_from_centerline(planner_result, opts.measure_opts);
    baseline = struct();
    for k = 1:numel(FIELDS); baseline.(FIELDS{k}) = getf(base, FIELDS{k}); end

    % --- Perturbed trials (deterministic under opts.seed) -----------
    rng(opts.seed, 'twister');
    vals = nan(opts.n_trials, numel(FIELDS));
    for t = 1:opts.n_trials
        prp = perturb_centerline(planner_result, opts.max_rot_deg, opts.resample_frac);
        try
            mt = evar_plan.measure_from_centerline(prp, opts.measure_opts);
            for k = 1:numel(FIELDS); vals(t, k) = getf(mt, FIELDS{k}); end
        catch
            % A degenerate perturbation leaves the row NaN; excluded below.
        end
    end

    % --- Assemble band ----------------------------------------------
    rep = struct();
    rep.fields   = FIELDS;
    rep.baseline = baseline;
    rep.n_trials = opts.n_trials;
    rep.params   = struct('max_rot_deg', opts.max_rot_deg, ...
                          'resample_frac', opts.resample_frac, 'seed', opts.seed);
    for k = 1:numel(FIELDS)
        f   = FIELDS{k};
        col = vals(:, k); col = col(~isnan(col));
        rep.mean.(f)    = safe(@mean, col);
        rep.std.(f)     = safe(@std,  col);
        rep.range.(f)   = safe(@(x) max(x) - min(x), col);
        rep.n_valid.(f) = numel(col);
        b = baseline.(f);
        if ~isempty(col) && isfinite(b) && abs(b) > eps
            rep.cv.(f) = std(col) / abs(b);
        else
            rep.cv.(f) = NaN;
        end
    end

    names = FIELDS(:);
    bcol = cellfun(@(f) baseline.(f),  FIELDS).';
    mcol = cellfun(@(f) rep.mean.(f),  FIELDS).';
    scol = cellfun(@(f) rep.std.(f),   FIELDS).';
    rcol = cellfun(@(f) rep.range.(f), FIELDS).';
    rep.table = table(names, bcol, mcol, scol, rcol, ...
        'VariableNames', {'measurement', 'baseline', 'mean', 'std', 'range'});

    if opts.verbose
        fprintf(['\nMeasurement reproducibility (%d trials, ' ...
                 '+/-%.0f deg rot, +/-%.0f%% resample):\n'], ...
                opts.n_trials, opts.max_rot_deg, 100 * opts.resample_frac);
        disp(rep.table);
    end
end

% ====================================================================

function prp = perturb_centerline(pr, max_rot_deg, resample_frac)
%PERTURB_CENTERLINE  Rigidly rotate BOTH branches by a common random
%   rotation about a random axis, then arc-resample each at a jittered
%   node spacing. The two branches share the rotation + centroid so the
%   bifurcation geometry stays self-consistent.
    ax = randn(1, 3); ax = ax / norm(ax);
    ang = (2 * rand - 1) * deg2rad(max_rot_deg);
    Rm  = rot_matrix(ax, ang);
    C   = mean([pr.Pv_mm_right; pr.Pv_mm_left], 1);
    jitter = 1 + (2 * rand - 1) * resample_frac;   % node-spacing scale

    prp = pr;
    [prp.Pv_mm_right, prp.R_mm_right] = xform_branch(pr.Pv_mm_right, pr.R_mm_right, Rm, C, jitter);
    [prp.Pv_mm_left,  prp.R_mm_left ] = xform_branch(pr.Pv_mm_left,  pr.R_mm_left,  Rm, C, jitter);
    if isfield(prp, 'arc_R_mm'); prp.arc_R_mm = arclen(prp.Pv_mm_right); end
    if isfield(prp, 'arc_L_mm'); prp.arc_L_mm = arclen(prp.Pv_mm_left);  end
end

function [Pv2, R2] = xform_branch(Pv, R, Rm, C, jitter)
    R   = R(:);
    Pvr = (Pv - C) * Rm.' + C;                       % rotate row-point cloud
    % drop near-zero-length segments so the arc parameter is monotone
    s = [0; cumsum(vecnorm(diff(Pvr, 1, 1), 2, 2))];
    keep = [true; diff(s) > 1e-9];
    s = s(keep); Pvr = Pvr(keep, :); R = R(keep);
    if numel(s) < 2 || s(end) <= 0; Pv2 = Pvr; R2 = R; return; end
    ds = median(diff(s));
    if ~isfinite(ds) || ds <= 0; ds = s(end) / (numel(s) - 1); end
    dsn = ds * jitter;
    sn = (0:dsn:s(end)).';
    if sn(end) < s(end) - 1e-9; sn = [sn; s(end)]; end
    Pv2 = interp1(s, Pvr, sn, 'pchip');
    R2  = interp1(s, R,   sn, 'pchip');
end

function L = arclen(Pv)
    if size(Pv, 1) < 2; L = 0; else; L = sum(vecnorm(diff(Pv, 1, 1), 2, 2)); end
end

function Rm = rot_matrix(ax, ang)
%ROT_MATRIX  Rodrigues rotation matrix for unit axis AX and angle ANG.
    x = ax(1); y = ax(2); z = ax(3);
    c = cos(ang); s = sin(ang); C = 1 - c;
    Rm = [c + x*x*C,   x*y*C - z*s, x*z*C + y*s; ...
          y*x*C + z*s, c + y*y*C,   y*z*C - x*s; ...
          z*x*C - y*s, z*y*C + x*s, c + z*z*C];
end

function v = getf(s, f)
%GETF  Scalar numeric field value, or NaN when absent / non-scalar.
    if isfield(s, f) && isscalar(s.(f)) && isnumeric(s.(f)); v = double(s.(f)); else; v = NaN; end
end

function v = safe(fn, col)
    if isempty(col); v = NaN; else; v = fn(col); end
end
