function report = compare_to_reference(auto, ref, opts)
%EVAR_PLAN.COMPARE_TO_REFERENCE  Quantitative comparison harness for goal #5.
%
%   REPORT = evar_plan.compare_to_reference(AUTO, REF)
%   REPORT = evar_plan.compare_to_reference(AUTO, REF, OPTS)
%
%   Compares the auto-planner output against a reference (typically a
%   TeraRecon plan exported case-by-case). The harness is ready BEFORE
%   the reference data is in hand; once a TeraRecon export is available,
%   wire it into the AUTO/REF schema below and the comparison runs.
%
%   AUTO and REF structs share this schema (any field may be NaN if
%   unmeasured; the report only scores the fields that are present
%   on BOTH sides):
%
%     .mask                Y×X×Z logical (lumen segmentation) — optional
%     .Pv_mm_right         N×3 right centerline polyline (mm)        — optional
%     .Pv_mm_left          N×3 left centerline polyline (mm)         — optional
%     .R_mm_right          N×1 inscribed-sphere radius (mm)          — optional
%     .R_mm_left           N×1                                       — optional
%     .neck_diameter_mm    proximal neck Ø                           — optional
%     .neck_length_mm      proximal neck length                      — optional
%     .neck_angulation_deg infrarenal neck-to-sac angle (beta)        — optional
%     .iliac_R_diameter_mm                                           — optional
%     .iliac_L_diameter_mm                                           — optional
%     .iliac_R_length_mm                                             — optional
%     .iliac_L_length_mm                                             — optional
%
%   OPTS:
%     .label  string to include in the report title (e.g. case ID)
%
%   REPORT struct fields:
%     .segmentation.dice       NaN if either mask missing
%     .segmentation.iou        NaN if either mask missing
%     .centerline.{R,L}.hausdorff_mm   directed-Hausdorff distance
%     .centerline.{R,L}.arc_delta_mm   abs(arc_auto - arc_ref)
%     .sizing                  struct of |auto − ref| per scalar field
%     .summary                 multi-line text suitable for logging

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        auto (1,1) struct
        ref  (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'label'); opts.label = '(unlabeled)'; end

    report = struct('segmentation', struct('dice', NaN, 'iou', NaN), ...
                    'centerline', struct(), 'sizing', struct());

    % --- Segmentation ----
    if isfield(auto, 'mask') && isfield(ref, 'mask') && ...
            ~isempty(auto.mask) && ~isempty(ref.mask) && ...
            isequal(size(auto.mask), size(ref.mask))
        a = logical(auto.mask); b = logical(ref.mask);
        inter = nnz(a & b);
        s_a = nnz(a); s_b = nnz(b);
        report.segmentation.dice = 2 * inter / max(1, s_a + s_b);
        report.segmentation.iou  = inter / max(1, nnz(a | b));
    end

    % --- Centerlines ----
    for side = ["right","left"]
        f_pv = sprintf('Pv_mm_%s', side);
        a_pv = get_or_empty(auto, f_pv);
        r_pv = get_or_empty(ref,  f_pv);
        if ~isempty(a_pv) && ~isempty(r_pv)
            report.centerline.(side).hausdorff_mm = ...
                max(directed_hausdorff(a_pv, r_pv), directed_hausdorff(r_pv, a_pv));
            arc_a = sum(vecnorm(diff(a_pv,1,1),2,2));
            arc_r = sum(vecnorm(diff(r_pv,1,1),2,2));
            report.centerline.(side).arc_auto_mm  = arc_a;
            report.centerline.(side).arc_ref_mm   = arc_r;
            report.centerline.(side).arc_delta_mm = abs(arc_a - arc_r);
        end
    end

    % --- Sizing scalars ----
    % Pull the field list from the reference schema so any new
    % measurement field (e.g. `bifurcation_angle_deg` added 2026-05-20)
    % automatically participates in the comparison without touching
    % this code.
    try
        sch = reference.schema();
        sizing_fields = sch.measurement_fields;
    catch
        % Defensive fallback if schema isn't on the path for some
        % reason; keep the previously-hardcoded list as a floor.
        sizing_fields = {'neck_diameter_mm', 'neck_length_mm', ...
                         'neck_angulation_deg', 'iliac_R_diameter_mm', ...
                         'iliac_L_diameter_mm', 'iliac_R_length_mm', ...
                         'iliac_L_length_mm', 'aneurysm_max_diameter_mm', ...
                         'distance_lowest_renal_to_bifurcation_mm', ...
                         'bifurcation_angle_deg'};
    end
    for k = 1:numel(sizing_fields)
        f = sizing_fields{k};
        if isfield(auto, f) && isfield(ref, f) && ...
                ~isnan(auto.(f)) && ~isnan(ref.(f))
            report.sizing.(f).auto = auto.(f);
            report.sizing.(f).ref  = ref.(f);
            report.sizing.(f).abs_delta = abs(auto.(f) - ref.(f));
        end
    end

    % --- Summary text ----
    lines = { sprintf('Comparison: %s', opts.label) };
    if ~isnan(report.segmentation.dice)
        lines{end+1} = sprintf('  Segmentation:  Dice %.3f  IoU %.3f', ...
            report.segmentation.dice, report.segmentation.iou); %#ok<AGROW>
    end
    for side = ["right","left"]
        if isfield(report.centerline, side)
            c = report.centerline.(side);
            lines{end+1} = sprintf('  Centerline %s: Hausdorff %.1f mm, arc Δ %.1f mm (auto %.0f vs ref %.0f)', ...
                upper(side(1)), c.hausdorff_mm, c.arc_delta_mm, c.arc_auto_mm, c.arc_ref_mm); %#ok<AGROW>
        end
    end
    sz_names = fieldnames(report.sizing);
    for k = 1:numel(sz_names)
        f = sz_names{k}; v = report.sizing.(f);
        lines{end+1} = sprintf('  %-22s auto %.1f  ref %.1f  Δ %.1f', ...
            f, v.auto, v.ref, v.abs_delta); %#ok<AGROW>
    end
    report.summary = strjoin(lines, newline);
end

function v = get_or_empty(s, f)
    if isfield(s, f); v = s.(f); else; v = []; end
end

function h = directed_hausdorff(A, B)
    h = 0;
    for k = 1:size(A, 1)
        d = min(vecnorm(B - A(k, :), 2, 2));
        if d > h; h = d; end
    end
end
