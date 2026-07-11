function row = batch_summary_row(out)
%EVAR_PLAN.BATCH_SUMMARY_ROW  Map a run_planner_headless output struct to the
%   per-case summary fields used by run_batch's cohort CSV.
%
%   ROW = evar_plan.batch_summary_row(OUT)
%
%   Kept as a package function (not a run_batch local) so it is unit-
%   testable. It reads the sizing scalars from OUT.plan.MEASUREMENTS (the
%   generate_plan struct nests them there — a bare `out.plan.neck_dia_mm`
%   does NOT exist, which is why the old batch CSV silently wrote NaN for
%   every sizing column) and the reliability verdict from OUT.qc.usable
%   (falling back to OUT.plan.qc_usable).
%
%   ROW fields: audit_passed, qc_usable, neck_dia_mm, neck_len_mm,
%   neck_ang_deg, iliac_R_dia_mm, iliac_L_dia_mm, arc_R_mm, arc_L_mm,
%   eligible_devices (cellstr). Missing inputs leave the field NaN / {}.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        out (1,1) struct
    end

    row = struct('audit_passed', NaN, 'qc_usable', NaN, ...
        'neck_dia_mm', NaN, 'neck_len_mm', NaN, 'neck_ang_deg', NaN, ...
        'iliac_R_dia_mm', NaN, 'iliac_L_dia_mm', NaN, ...
        'arc_R_mm', NaN, 'arc_L_mm', NaN, 'eligible_devices', {{}});

    if isfield(out, 'audit') && isstruct(out.audit) && isfield(out.audit, 'passed')
        row.audit_passed = out.audit.passed;
    end
    if isfield(out, 'qc') && isstruct(out.qc) ...
            && isfield(out.qc, 'usable') && ~isempty(out.qc.usable)
        row.qc_usable = logical(out.qc.usable);
    end

    if isfield(out, 'plan') && isstruct(out.plan)
        p = out.plan;
        if isfield(p, 'measurements') && isstruct(p.measurements)
            m = p.measurements;
            row.neck_dia_mm    = getf(m, 'neck_diameter_mm');
            row.neck_len_mm    = getf(m, 'neck_length_mm');
            row.neck_ang_deg   = getf(m, 'neck_angulation_deg');
            row.iliac_R_dia_mm = getf(m, 'iliac_R_diameter_mm');
            row.iliac_L_dia_mm = getf(m, 'iliac_L_diameter_mm');
        end
        if isnan(row.qc_usable) && isfield(p, 'qc_usable') && ~isempty(p.qc_usable)
            row.qc_usable = logical(p.qc_usable);
        end
        if isfield(p, 'ranked_devices')
            elig = {};
            for k = 1:numel(p.ranked_devices)
                d = p.ranked_devices(k);
                if isfield(d, 'eligibility') && d.eligibility.eligible
                    elig{end + 1} = d.name; %#ok<AGROW>
                end
            end
            row.eligible_devices = elig;
        end
    end

    if isfield(out, 'Pv_mm_right'); row.arc_R_mm = arclen(out.Pv_mm_right); end
    if isfield(out, 'Pv_mm_left');  row.arc_L_mm = arclen(out.Pv_mm_left);  end
end

function v = getf(s, f)
    if isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f)); v = double(s.(f)); else; v = NaN; end
end

function a = arclen(P)
    if size(P, 1) < 2; a = NaN; else; a = sum(vecnorm(diff(P, 1, 1), 2, 2)); end
end
