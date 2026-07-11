function result = check_eligibility(meas, device)
%IFU.CHECK_ELIGIBILITY  Check a single device against patient measurements.
%
%   R = ifu.check_eligibility(MEAS, DEVICE)
%
%   Compares a measurement struct against a device's IFU criteria
%   (from ifu.devices) and returns a struct describing fit.
%
%   MEAS fields (all in mm or degrees; NaN for unmeasured):
%       .neck_diameter_mm     proximal aortic neck Ø
%       .neck_length_mm       non-aneurysmal neck length
%       .neck_angulation_deg  infrarenal neck-to-sac angle (beta) — the
%                             angle most vendor IFUs limit on. NaN when no
%                             aneurysm is present, in which case the angle
%                             criterion is skipped.
%       .iliac_R_diameter_mm  right iliac landing-zone Ø
%       .iliac_L_diameter_mm  left iliac landing-zone Ø
%       .iliac_R_length_mm    right iliac landing-zone length
%       .iliac_L_length_mm    left iliac landing-zone length
%       .bifurcation_angle_deg  iliac take-off angle (added 2026-05-21;
%                              checked only when the device entry has
%                              a non-NaN iliac_bifurc_angle_max_deg)
%
%   DEVICE is one entry from ifu.devices().
%
%   Returns R with fields:
%       .eligible        true if every applicable IFU criterion passed
%                        AND the core criteria (neck Ø + both iliac Ø)
%                        were actually measurable (see .indeterminate)
%       .indeterminate   true when a core measurement is NaN/missing, so
%                        eligibility could not be established (guards
%                        against a confident recommendation from an
%                        all-NaN / degenerate measurement set)
%       .missing_core    cellstr of the missing core measurement fields
%       .n_criteria_evaluated  count of criteria actually checked
%       .fail_reasons    cellstr of failed-criterion descriptions
%       .margins         struct of dimensional margins (mm/deg);
%                        negative = how much outside IFU, positive =
%                        how much inside. Smallest margin determines
%                        the binding constraint.
%       .binding         name of the binding constraint (smallest margin)
%       .source          device.source (so callers can cite)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        meas   (1,1) struct
        device (1,1) struct
    end

    fail = {};
    margins = struct();

    % --- Neck diameter (must be inside [min, max]) ----
    if isfield(meas, 'neck_diameter_mm') && ~isnan(meas.neck_diameter_mm)
        d = meas.neck_diameter_mm;
        lo = device.neck_diameter_mm(1);
        hi = device.neck_diameter_mm(2);
        margin = min(d - lo, hi - d);
        margins.neck_diameter_mm = margin;
        if d < lo
            fail{end+1} = sprintf('neck Ø %.1f mm < %s min %.1f mm', d, device.name, lo); %#ok<AGROW>
        elseif d > hi
            fail{end+1} = sprintf('neck Ø %.1f mm > %s max %.1f mm', d, device.name, hi); %#ok<AGROW>
        end
    end

    % --- Neck length (≥ device min) ----
    if isfield(meas, 'neck_length_mm') && ~isnan(meas.neck_length_mm)
        L = meas.neck_length_mm;
        Lmin = device.neck_length_min_mm;
        margins.neck_length_mm = L - Lmin;
        if L < Lmin
            fail{end+1} = sprintf('neck length %.1f mm < %s min %.1f mm', L, device.name, Lmin); %#ok<AGROW>
        end
    end

    % --- Neck angulation (≤ device max) ----
    % neck_angulation_deg is the infrarenal neck-to-sac (beta) angle; it
    % is NaN when no aneurysm was detected, so this criterion is then
    % skipped rather than ruling a device in or out on a missing angle.
    if isfield(meas, 'neck_angulation_deg') && ~isnan(meas.neck_angulation_deg)
        a = meas.neck_angulation_deg;
        amax = device.neck_angulation_max_deg;
        margins.neck_angulation_deg = amax - a;
        if a > amax
            fail{end+1} = sprintf('neck angulation %.0f° > %s max %.0f°', a, device.name, amax); %#ok<AGROW>
        end
    end

    % --- Iliac diameters (each side inside [min, max]) ----
    for side = ["R", "L"]
        f = sprintf('iliac_%s_diameter_mm', side);
        if isfield(meas, f) && ~isnan(meas.(f))
            d = meas.(f);
            lo = device.iliac_diameter_mm(1);
            hi = device.iliac_diameter_mm(2);
            margin = min(d - lo, hi - d);
            margins.(f) = margin;
            if d < lo
                fail{end+1} = sprintf('iliac %s Ø %.1f mm < %s min %.1f mm', side, d, device.name, lo); %#ok<AGROW>
            elseif d > hi
                fail{end+1} = sprintf('iliac %s Ø %.1f mm > %s max %.1f mm', side, d, device.name, hi); %#ok<AGROW>
            end
        end
    end

    % --- Iliac lengths (≥ device min) ----
    for side = ["R", "L"]
        f = sprintf('iliac_%s_length_mm', side);
        if isfield(meas, f) && ~isnan(meas.(f))
            L = meas.(f);
            Lmin = device.iliac_length_min_mm;
            margins.(f) = L - Lmin;
            if L < Lmin
                fail{end+1} = sprintf('iliac %s length %.1f mm < %s min %.1f mm', side, L, device.name, Lmin); %#ok<AGROW>
            end
        end
    end

    % --- Iliac bifurcation (take-off) angle (≤ device max) ----
    % Optional. The device entry's `iliac_bifurc_angle_max_deg` is NaN
    % when the IFU doesn't publish a constraint — in that case we skip
    % the check (no margin, no fail). When a value IS specified, treat
    % it like neck angulation: angle must be ≤ device max.
    if isfield(meas, 'bifurcation_angle_deg') && ~isnan(meas.bifurcation_angle_deg) && ...
            isfield(device, 'iliac_bifurc_angle_max_deg') && ~isnan(device.iliac_bifurc_angle_max_deg)
        a = meas.bifurcation_angle_deg;
        amax = device.iliac_bifurc_angle_max_deg;
        margins.iliac_bifurc_angle_deg = amax - a;
        if a > amax
            fail{end+1} = sprintf('iliac bifurc angle %.0f° > %s max %.0f°', a, device.name, amax); %#ok<AGROW>
        end
    end

    % --- Find the binding (smallest-margin) constraint ----
    mnames = fieldnames(margins);
    mvals  = structfun(@(v) v, margins);
    if isempty(mvals)
        binding = '';
        min_margin = NaN;
    else
        [min_margin, bi] = min(mvals);
        binding = mnames{bi};
    end

    % --- Guard against VACUOUS eligibility (sizing-3) ----------------
    % Every criterion above is skipped when its measurement is NaN. A
    % degenerate measurement set (failed centerline, short polyline) with
    % all-NaN fields would therefore accrue zero fail reasons and be
    % reported "eligible" with no anatomic basis — a confident bogus
    % recommendation. Require the CORE sizing criteria (proximal neck Ø
    % and BOTH iliac landing-zone Ø) to be present before a device can be
    % called eligible; otherwise it is INDETERMINATE (neither eligible
    % nor strictly off-label — we simply couldn't evaluate it).
    core_fields = {'neck_diameter_mm', 'iliac_R_diameter_mm', 'iliac_L_diameter_mm'};
    missing = core_fields(cellfun( ...
        @(f) ~isfield(meas, f) || isnan(meas.(f)), core_fields));
    indeterminate = ~isempty(missing);
    if indeterminate
        fail{end+1} = sprintf('INDETERMINATE — missing core measurement(s): %s', ...
            strjoin(missing, ', ')); %#ok<AGROW>
    end

    result = struct( ...
        'eligible',              isempty(fail) && ~indeterminate, ...
        'indeterminate',         indeterminate, ...
        'missing_core',          {missing}, ...
        'n_criteria_evaluated',  numel(mnames), ...
        'fail_reasons',          {fail}, ...
        'margins',               margins, ...
        'binding',               binding, ...
        'min_margin',            min_margin, ...
        'source',                device.source);
end
