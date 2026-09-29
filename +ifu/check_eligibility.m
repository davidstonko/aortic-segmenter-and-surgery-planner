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
%       .iliac_R_seal_length_mm  right common-iliac seal length (NaN when
%                             the CIA/EIA boundary isn't segmented — the
%                             criterion is then reported in .not_assessed)
%       .iliac_L_seal_length_mm  left common-iliac seal length
%       .aneurysm_detected    when true, neck_length_mm becomes a core
%                             criterion (NaN → indeterminate)
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
%       .not_assessed    cellstr of IFU criteria that could not be
%                        evaluated from the available measurements (e.g.
%                        iliac seal length) — shown so "eligible" is never
%                        read as "every criterion was checked"
%       .n_criteria_evaluated  count of criteria actually checked
%       .fail_reasons    cellstr of failed-criterion descriptions
%       .margins         struct of per-criterion margins (mm for diameters
%                        and lengths, degrees for angles); negative = how
%                        far outside the IFU, positive = how far inside.
%       .min_margin      smallest DIMENSIONAL margin, in mm (angles are
%                        excluded — mm and degrees aren't comparable);
%                        used to rank devices
%       .binding         binding constraint: the smallest mm margin, or a
%                        violated angle when no mm criterion fails
%       .cautions        cellstr of non-blocking warnings (e.g. a lumen
%                        neck Ø close to an OUTER-wall IFU maximum)
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
        % Some IFUs tighten the angle limit on short necks (Ovation: ≤45°
        % when the neck is under 10 mm).
        rule = field_or(device, 'short_neck_angle_rule', []);
        if numel(rule) == 2 && isfield(meas, 'neck_length_mm') && ...
                ~isnan(meas.neck_length_mm) && meas.neck_length_mm < rule(1)
            amax = min(amax, rule(2));
        end
        margins.neck_angulation_deg = amax - a;
        if a > amax
            fail{end+1} = sprintf('neck angulation %.0f° > %s max %.0f°', a, device.name, amax); %#ok<AGROW>
        end
    end

    % --- Suprarenal angulation alpha (≤ device max, when labeled) ----
    samax = field_or(device, 'suprarenal_angulation_max_deg', NaN);
    if ~isnan(samax) && isfield(meas, 'neck_angulation_alpha_deg') && ...
            ~isnan(meas.neck_angulation_alpha_deg)
        a = meas.neck_angulation_alpha_deg;
        margins.suprarenal_angulation_deg = samax - a;
        if a > samax
            fail{end+1} = sprintf('suprarenal angulation %.0f° > %s max %.0f°', a, device.name, samax); %#ok<AGROW>
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

    % --- Iliac SEAL lengths (≥ device min) ----
    % Uses the common-iliac seal length, NOT iliac_*_length_mm (that is the
    % bifurcation-to-terminus path length, ~150-250 mm, which would pass
    % every 10-15 mm minimum vacuously). The seal length needs a CIA/EIA
    % boundary the pipeline doesn't segment yet, so it is usually NaN and
    % the criterion is listed under .not_assessed instead of passing.
    not_assessed = {};
    for side = ["R", "L"]
        f = sprintf('iliac_%s_seal_length_mm', side);
        if isfield(meas, f) && ~isnan(meas.(f))
            L = meas.(f);
            Lmin = device.iliac_length_min_mm;
            margins.(f) = L - Lmin;
            if L < Lmin
                fail{end+1} = sprintf('iliac %s seal length %.1f mm < %s min %.1f mm', side, L, device.name, Lmin); %#ok<AGROW>
            end
        else
            not_assessed{end+1} = sprintf('iliac %s seal length (min %.0f mm)', ...
                side, device.iliac_length_min_mm); %#ok<AGROW>
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
    % Margins mix mm (diameters, lengths) and degrees (angles), which are
    % not comparable — "5 mm" and "5°" are not the same closeness to a
    % limit. The ranking margin (min_margin, in mm) therefore uses the
    % dimensional criteria only; an angle is the binding constraint only
    % when it is actually violated.
    mnames = fieldnames(margins);
    mvals  = structfun(@(v) v, margins);
    is_ang = contains(mnames, 'angul') | contains(mnames, 'angle');
    min_margin = NaN; binding = '';
    if any(~is_ang)
        [min_margin, bi] = min(mvals(~is_ang));
        nm = mnames(~is_ang); binding = nm{bi};
    end
    if any(is_ang)
        [amin, ai] = min(mvals(is_ang));
        if amin < 0 && ~(min_margin < 0)
            an = mnames(is_ang); binding = an{ai};
        end
    end

    % --- Diameter-basis caution (lumen vs outer wall) ----------------
    % The planner measures CONTRAST-LUMEN diameters. Where an IFU defines
    % diameters outer-wall to outer-wall, the true value is LARGER by the
    % wall + any thrombus, so a lumen value near the device's upper bound
    % may really be off-label. Flag it rather than silently passing.
    cautions = {};
    if strcmp(field_or(device, 'diameter_basis', 'unspecified'), 'outer') && ...
            isfield(meas, 'neck_diameter_mm') && ~isnan(meas.neck_diameter_mm) && ...
            meas.neck_diameter_mm > device.neck_diameter_mm(2) - 4
        cautions{end+1} = sprintf(['neck lumen Ø %.1f mm is within 4 mm of %s''s ' ...
            'OUTER-wall maximum (%.0f mm); outer-wall Ø may exceed it'], ...
            meas.neck_diameter_mm, device.name, device.neck_diameter_mm(2));
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
    % When an aneurysm IS present, neck length is core too: a NaN length
    % would otherwise silently skip the length criterion and let a device
    % through on diameter alone.
    if isfield(meas, 'aneurysm_detected') && isequal(meas.aneurysm_detected, true)
        core_fields{end+1} = 'neck_length_mm';
    end
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
        'not_assessed',          {not_assessed}, ...
        'cautions',              {cautions}, ...
        'n_criteria_evaluated',  numel(mnames), ...
        'fail_reasons',          {fail}, ...
        'margins',               margins, ...
        'binding',               binding, ...
        'min_margin',            min_margin, ...
        'source',                device.source);
end

function v = field_or(s, f, default)
    if isfield(s, f) && ~isempty(s.(f)); v = s.(f); else; v = default; end
end
