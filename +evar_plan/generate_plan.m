function plan = generate_plan(planner_result, opts)
%EVAR_PLAN.GENERATE_PLAN  Produce a structured EVAR plan from an
%   auto-planner centerline run + IFU device library.
%
%   PLAN = evar_plan.generate_plan(PLANNER_RESULT)
%   PLAN = evar_plan.generate_plan(PLANNER_RESULT, OPTS)
%
%   Composes:
%     1. evar_plan.measure_from_centerline  — derive sizing measurements
%     2. ifu.match_devices                  — rank eligible stent grafts
%     3. Plain-text rationale + recommendation
%
%   Returns a struct PLAN with fields:
%       .measurements      from measure_from_centerline
%       .ranked_devices    from ifu.match_devices
%       .recommendation    name of top-ranked eligible device, or
%                          '' if none eligible
%       .rationale         multi-line text summary
%       .disclaimer        research-use disclaimer string
%       .timestamp         ISO datetime the plan was generated
%
%   OPTS:
%       .write_file        path to write a JSON / TXT summary (default:
%                          <planner.out_dir>/evar_plan.{json,txt})
%       .verbose           print rationale to stdout (default true)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        planner_result (1,1) struct
        opts           (1,1) struct = struct()
    end
    if ~isfield(opts, 'verbose'); opts.verbose = true; end
    if ~isfield(opts, 'write_file')
        if isfield(planner_result, 'out_dir') && ~isempty(planner_result.out_dir)
            opts.write_file = fullfile(planner_result.out_dir, 'evar_plan');
        else
            opts.write_file = '';
        end
    end

    plan.measurements   = evar_plan.measure_from_centerline(planner_result);
    plan.ranked_devices = ifu.match_devices(plan.measurements);

    % QC reliability verdict. When the planner flagged the result as
    % unusable (degenerate centerline / incomplete segmentation / suspect
    % orientation) the numbers below are still emitted for inspection but
    % MUST be marked untrustworthy so nobody reads them as a real plan.
    [plan.qc_usable, plan.qc_summary] = plan_qc_verdict(planner_result);

    elig_mask = arrayfun(@(d) d.eligibility.eligible, plan.ranked_devices);
    elig = plan.ranked_devices(elig_mask);
    if isempty(elig)
        plan.recommendation = '';
        rec_line = 'NO ON-LABEL DEVICE — every catalogued stent graft has at least one IFU criterion outside its labeled range.';
        binding_lines = arrayfun(@(d) sprintf('    %s — binding: %s (margin %.1f)', ...
            d.name, d.eligibility.binding, d.eligibility.min_margin), ...
            plan.ranked_devices, 'UniformOutput', false);
        rec_line = sprintf('%s\n  Closest-to-eligible (smallest violation first):\n%s', ...
            rec_line, strjoin(binding_lines, newline));
    else
        plan.recommendation = elig(1).name;
        rec_line = sprintf('Recommended device: %s by %s (%s body)', ...
            elig(1).name, elig(1).manufacturer, elig(1).body_design);
        if numel(elig) > 1
            alts = arrayfun(@(d) sprintf('%s (margin %.1f)', d.name, d.eligibility.min_margin), ...
                elig(2:end), 'UniformOutput', false);
            rec_line = sprintf('%s\n  Alternatives: %s', rec_line, strjoin(alts, ', '));
        end
    end

    m = plan.measurements;
    % All diameters are contrast-LUMEN diameters (TS segments lumen only)
    % — they exclude mural thrombus / outer wall. Label them so the
    % aneurysm Ø is never read as the true outer-wall sac diameter.
    aneurysm_detected = ~isfield(m, 'aneurysm_detected') || m.aneurysm_detected;
    meas_lines = {
        sprintf('  Proximal neck:   lumen Ø %.1f mm, length %s, angulation (β neck-to-sac) %s', ...
            m.neck_diameter_mm, neck_len_str(m), ang_str(m, 'neck_angulation_deg'))
        sprintf('                   (α suprarenal-to-neck %s)', ...
            ang_str(m, 'neck_angulation_alpha_deg'))
        sprintf('  Right iliac:     lumen Ø %.1f mm, landing-zone length %.1f mm', ...
            m.iliac_R_diameter_mm, m.iliac_R_length_mm)
        sprintf('  Left iliac:      lumen Ø %.1f mm, landing-zone length %.1f mm', ...
            m.iliac_L_diameter_mm, m.iliac_L_length_mm)
        sprintf('  Peak aneurysm:   lumen Ø %.1f mm (R %.1f mm) — excludes mural thrombus%s', ...
            2*m.max_aneurysm_R_mm, m.max_aneurysm_R_mm, no_aneurysm_note(aneurysm_detected))
    };

    plan.disclaimer = ['RESEARCH USE ONLY. Sizing values were auto-derived ' ...
        'from a TotalSegmentator-driven centerline and have NOT been ' ...
        'verified against the source CT or by an operator. All diameters ' ...
        'are CONTRAST-LUMEN diameters and exclude mural thrombus / outer ' ...
        'wall, so the aneurysm Ø may under-call the true outer-wall sac. ' ...
        'Device IFU criteria are from peer-reviewed published summaries ' ...
        'and may not reflect the current vendor IFU. Do not use for ' ...
        'clinical decision-making.'];

    plan.timestamp = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<DATST,TNOW1>
    qc_banner = '';
    if ~plan.qc_usable
        qc_banner = sprintf('\n\n*** %s ***', plan.qc_summary);
    end
    plan.rationale = sprintf( ...
        'AUTO EVAR PLAN — generated %s\n%s%s\n\nAuto-measurements (from centerline + radius profile):\n%s\n\n%s\n', ...
        plan.timestamp, ...
        repmat('=', 1, 72), ...
        qc_banner, ...
        strjoin(meas_lines, newline), ...
        rec_line);

    if opts.verbose
        fprintf('%s\n', plan.rationale);
        fprintf('\n[%s]\n', plan.disclaimer);
    end

    % --- Write to disk ----
    if ~isempty(opts.write_file)
        out_txt = [opts.write_file, '.txt'];
        out_json = [opts.write_file, '.json'];
        write_text(out_txt, plan);
        write_json(out_json, plan);
        if opts.verbose
            fprintf('\nPlan saved to:\n  %s\n  %s\n', out_txt, out_json);
        end
    end
end

function write_text(path, plan)
    fid = fopen(path, 'w');
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s', plan.rationale);

    % Device eligibility table — eligible first (best fit), then
    % off-label with the binding reason.
    fprintf(fid, '\nDevice library used:\n');
    for k = 1:numel(plan.ranked_devices)
        d = plan.ranked_devices(k);
        ec = d.eligibility;
        if ec.eligible
            verdict = sprintf('ELIGIBLE  (margin %.1f)', ec.min_margin);
        else
            verdict = sprintf('OFF-LABEL (%s)', strjoin(ec.fail_reasons, '; '));
        end
        fprintf(fid, '  %-30s %-22s %s\n', d.name, d.manufacturer, verdict);
    end

    % Side-by-side measurement vs library-envelope summary so the
    % operator can see at a glance which criterion is on the edge.
    fprintf(fid, '\nMeasurement vs library envelope (mm, deg):\n');
    fprintf(fid, '  %-32s %-12s %-16s\n', 'criterion', 'measured', 'library range');
    m = plan.measurements;
    rows = {
        'neck lumen Ø',           m.neck_diameter_mm,        envelope_neck_dia(plan);
        'neck length (≥ min)',    m.neck_length_mm,          envelope_neck_len_min(plan);
        'neck angulation β (≤ max)', m.neck_angulation_deg,  envelope_neck_ang_max(plan);
        'iliac lumen Ø R',        m.iliac_R_diameter_mm,     envelope_iliac_dia(plan);
        'iliac lumen Ø L',        m.iliac_L_diameter_mm,     envelope_iliac_dia(plan);
        'iliac length R',         m.iliac_R_length_mm,       envelope_iliac_len_min(plan);
        'iliac length L',         m.iliac_L_length_mm,       envelope_iliac_len_min(plan)};
    for ri = 1:size(rows, 1)
        fprintf(fid, '  %-32s %-12.1f %s\n', rows{ri, 1}, rows{ri, 2}, rows{ri, 3});
    end

    fprintf(fid, '\nIFU sources cited:\n');
    sources = unique({plan.ranked_devices.source});
    for s = 1:numel(sources); fprintf(fid, '  - %s\n', sources{s}); end
    fprintf(fid, '\n[%s]\n', plan.disclaimer);
end

function [usable, summary] = plan_qc_verdict(planner_result)
%PLAN_QC_VERDICT  Reliability verdict for the plan from the planner's QC
%   struct. Prefers a precomputed qc.usable/qc.summary; else derives it via
%   autoseg.qc_summary. No QC attached => usable (the caller's own concern,
%   e.g. the unit tests that feed a bare centerline struct).
    if isfield(planner_result, 'qc') && isstruct(planner_result.qc)
        qc = planner_result.qc;
        if isfield(qc, 'usable') && ~isempty(qc.usable)
            usable = logical(qc.usable);
            if isfield(qc, 'summary') && ~isempty(qc.summary)
                summary = qc.summary;
            else
                [~, summary] = autoseg.qc_summary(qc);
            end
        else
            [usable, summary] = autoseg.qc_summary(qc);
        end
    else
        usable  = true;
        summary = '';
    end
end

function s = neck_len_str(m)
%NECK_LEN_STR  Neck length, or an explicit N/A when no aneurysm onset
%   was detected (length to the bifurcation is not a real neck).
    if isfield(m, 'aneurysm_detected') && ~m.aneurysm_detected
        s = 'N/A (no aneurysm detected)';
    elseif isnan(m.neck_length_mm)
        s = 'N/A';
    else
        s = sprintf('%.1f mm', m.neck_length_mm);
    end
end

function s = ang_str(m, field)
%ANG_STR  Angle in degrees or '—' when unmeasured (NaN).
    if ~isfield(m, field) || isnan(m.(field))
        s = '—';
    else
        s = sprintf('%.1f°', m.(field));
    end
end

function s = no_aneurysm_note(aneurysm_detected)
    if aneurysm_detected
        s = '';
    else
        s = '  [no discrete aneurysm detected]';
    end
end

function s = envelope_neck_dia(plan)
    lo = min(arrayfun(@(d) d.neck_diameter_mm(1), plan.ranked_devices));
    hi = max(arrayfun(@(d) d.neck_diameter_mm(2), plan.ranked_devices));
    s = sprintf('%.0f–%.0f mm', lo, hi);
end
function s = envelope_neck_len_min(plan)
    lo = min(arrayfun(@(d) d.neck_length_min_mm, plan.ranked_devices));
    s = sprintf('≥ %.0f mm (best)', lo);
end
function s = envelope_neck_ang_max(plan)
    hi = max(arrayfun(@(d) d.neck_angulation_max_deg, plan.ranked_devices));
    s = sprintf('≤ %.0f° (best)', hi);
end
function s = envelope_iliac_dia(plan)
    lo = min(arrayfun(@(d) d.iliac_diameter_mm(1), plan.ranked_devices));
    hi = max(arrayfun(@(d) d.iliac_diameter_mm(2), plan.ranked_devices));
    s = sprintf('%.0f–%.0f mm', lo, hi);
end
function s = envelope_iliac_len_min(plan)
    lo = min(arrayfun(@(d) d.iliac_length_min_mm, plan.ranked_devices));
    s = sprintf('≥ %.0f mm (best)', lo);
end

function write_json(path, plan)
    % Build a flat struct safe for jsonencode (no nested function handles).
    out.timestamp      = plan.timestamp;
    out.disclaimer     = plan.disclaimer;
    out.qc_usable      = plan.qc_usable;
    out.qc_summary     = plan.qc_summary;
    out.measurements   = plan.measurements;
    out.recommendation = plan.recommendation;
    out.devices        = [];
    for k = 1:numel(plan.ranked_devices)
        d = plan.ranked_devices(k);
        e = struct( ...
            'name',         d.name, ...
            'manufacturer', d.manufacturer, ...
            'eligible',     d.eligibility.eligible, ...
            'min_margin',   d.eligibility.min_margin, ...
            'binding',      d.eligibility.binding, ...
            'fail_reasons', {d.eligibility.fail_reasons}, ...
            'source',       d.source);
        if isempty(out.devices); out.devices = e; else, out.devices(end+1) = e; end %#ok<AGROW>
    end
    fid = fopen(path, 'w');
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s\n', jsonencode(out, 'PrettyPrint', true));
end
