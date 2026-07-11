function M = evar_measurements(Pv_mm_right, R_mm_right, Pv_mm_left, R_mm_left, bifurc_node, landmarks)
%EVAR_MEASUREMENTS  Standard EVAR preop planning measurements from
%   paired right/left centerlines + a bifurcation node.
%
%   M = EVAR_MEASUREMENTS(PV_R, R_R, PV_L, R_L, BIFURC_NODE, LANDMARKS)
%
%   Aortic measurements are taken on the RIGHT polyline (the "primary"
%   side that runs CFA → suprarenal). Iliac measurements are taken on
%   their respective polylines below the bifurcation.
%
%   Polyline convention: distal=node 1, proximal=last node.
%
%   Outputs (NaN where landmarks are missing or arc not defined)
%       M.aortic_neck.length_mm           lowest renal → aneurysm start
%       M.aortic_neck.diameter_mm         lumen diameter at lowest renal
%       M.aortic_neck.angulation_deg      angle between neck axis and
%                                         aneurysm long axis
%       M.aortic_neck.conicity_mm_per_cm  diameter change rate
%
%       M.aneurysm.max_diameter_mm        peak lumen diameter in sac
%       M.aneurysm.length_mm              along centerline
%       M.aneurysm.location_arc_mm        arc-length position of peak
%
%       M.iliac.right.cia_diameter_mm     proximal third = common iliac
%       M.iliac.right.eia_diameter_mm     distal third = external iliac
%       M.iliac.right.tortuosity          arc / chord ratio
%       M.iliac.right.length_mm           bifurc → CFA terminus
%       M.iliac.left.*                    same on left polyline
%
%       M.distances.renals_to_bifurc_mm   arc length on the right
%       M.distances.bifurc_to_int_iliac_mm.right
%       M.distances.bifurc_to_int_iliac_mm.left
%       M.bifurcation_angle_deg           iliac take-off angle (added
%                                          2026-05-20) — angle ∈ [0, 180]
%                                          between the two iliac trunks
%                                          measured 20 mm distal to the
%                                          aortic bifurcation
%
%   Inputs
%       Pv_mm_right, R_mm_right
%           Right polyline + radii in mm; runs R-CFA → suprarenal
%       Pv_mm_left, R_mm_left
%           Left  polyline + radii in mm; runs L-CFA → bifurc node
%       bifurc_node
%           Index on Pv_mm_right of the aortic bifurcation
%       landmarks (struct, optional) — node indices:
%           .renal_index            (index on the right polyline)
%           .bifurc_index           (index on right polyline; defaults
%                                    to bifurc_node)
%           .aneurysm_start         (index on right polyline; auto-
%                                    detected if absent)
%           .right_iliac_index      (index on right polyline; defaults
%                                    to 1 = R-CFA seed)
%           .left_iliac_index       (index on the LEFT polyline;
%                                    defaults to 1 = L-CFA seed)
%           .right_internal_iliac   (optional, on the right polyline)
%           .left_internal_iliac    (optional, on the left polyline)
%
%   For an MVP, missing landmarks → corresponding measurements = NaN.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        Pv_mm_right (:,3) double
        R_mm_right  (:,1) double
        Pv_mm_left  (:,3) double
        R_mm_left   (:,1) double
        bifurc_node (1,1) double
        landmarks   (1,1) struct = struct()
    end

    nR = size(Pv_mm_right, 1);
    nL = size(Pv_mm_left,  1);
    arcR  = [0; cumsum(vecnorm(diff(Pv_mm_right, 1, 1), 2, 2))];
    arcL  = [0; cumsum(vecnorm(diff(Pv_mm_left,  1, 1), 2, 2))];
    DiamR = 2 * R_mm_right;
    DiamL = 2 * R_mm_left;

    % --- Helper: get a landmark index, default NaN -------------------
    function idx = lm(name)
        if isfield(landmarks, name) && ~isempty(landmarks.(name))
            idx = landmarks.(name);
        else
            idx = NaN;
        end
    end

    M = struct();

    % --- Aortic neck (right polyline, above the bifurc) --------------
    M.aortic_neck = struct();
    i_renal  = lm('renal_index');
    i_bifurc = lm('bifurc_index');
    if isnan(i_bifurc) && ~isempty(bifurc_node) && ~isnan(bifurc_node)
        i_bifurc = bifurc_node;
    end

    % Aneurysm start: by default, find the first node distal to the
    % renals where the diameter exceeds 1.5 × the diameter at the renals.
    i_aneur_start = lm('aneurysm_start');
    if isnan(i_aneur_start) && ~isnan(i_renal) && ~isnan(i_bifurc)
        D_renal = DiamR(i_renal);
        % Polyline order: distal→proximal, so from the bifurc up to the
        % renals, the aneurysm sits between bifurc and renal.
        lo = min(i_bifurc, i_renal); hi = max(i_bifurc, i_renal);
        searchD = DiamR(lo:hi);
        rel = find(searchD >= 1.5 * D_renal, 1, 'first');
        if ~isempty(rel)
            i_aneur_start = lo + rel - 1;
        end
    end

    if ~isnan(i_renal) && ~isnan(i_aneur_start)
        M.aortic_neck.length_mm = abs(arcR(i_aneur_start) - arcR(i_renal));
    else
        M.aortic_neck.length_mm = NaN;
    end
    if ~isnan(i_renal); M.aortic_neck.diameter_mm = DiamR(i_renal);
    else;               M.aortic_neck.diameter_mm = NaN;
    end

    % Neck angulation: angle between the tangent at the renals and the
    % tangent at the aneurysm-start node.
    if ~isnan(i_renal) && ~isnan(i_aneur_start) && ...
       i_renal > 1 && i_aneur_start < nR
        t_renal = (Pv_mm_right(min(nR, i_renal+5),:) - Pv_mm_right(max(1, i_renal-5),:));
        t_aneur = (Pv_mm_right(min(nR, i_aneur_start+5),:) - Pv_mm_right(max(1, i_aneur_start-5),:));
        t_renal = t_renal / max(norm(t_renal), eps);
        t_aneur = t_aneur / max(norm(t_aneur), eps);
        M.aortic_neck.angulation_deg = acosd(max(-1, min(1, dot(t_renal, t_aneur))));
    else
        M.aortic_neck.angulation_deg = NaN;
    end

    % Conicity: linear fit of D vs arc length within the neck
    if ~isnan(i_renal) && ~isnan(i_aneur_start) && abs(i_aneur_start - i_renal) > 2
        lo = min(i_renal, i_aneur_start); hi = max(i_renal, i_aneur_start);
        seg_arc = arcR(lo:hi) - arcR(lo);
        seg_D   = DiamR(lo:hi);
        p = polyfit(seg_arc, seg_D, 1);   % slope mm-diameter / mm-arc
        M.aortic_neck.conicity_mm_per_cm = p(1) * 10;
    else
        M.aortic_neck.conicity_mm_per_cm = NaN;
    end

    % --- Aneurysm sac (right polyline, between aneur_start and bifurc)
    M.aneurysm = struct();
    if ~isnan(i_aneur_start) && ~isnan(i_bifurc) && i_aneur_start ~= i_bifurc
        lo = min(i_aneur_start, i_bifurc); hi = max(i_aneur_start, i_bifurc);
        sac_D   = DiamR(lo:hi);
        sac_arc = arcR(lo:hi);
        [Dmax, rel] = max(sac_D);
        M.aneurysm.max_diameter_mm = Dmax;
        M.aneurysm.length_mm       = sac_arc(end) - sac_arc(1);
        M.aneurysm.location_arc_mm = sac_arc(rel) - sac_arc(1);
    else
        M.aneurysm.max_diameter_mm = NaN;
        M.aneurysm.length_mm       = NaN;
        M.aneurysm.location_arc_mm = NaN;
    end

    % --- Iliacs (per side, on their own polyline) -------------------
    % Right: nodes 1..bifurc_node on the right polyline (distal→proximal)
    % Left : nodes 1..end          on the left polyline  (already trimmed at bifurc)
    if isnan(i_bifurc) && ~isnan(bifurc_node); i_bifurc = bifurc_node; end
    i_right_term = lm('right_iliac_index');
    if isnan(i_right_term); i_right_term = 1; end       % default: R-CFA seed
    i_left_term  = lm('left_iliac_index');
    if isnan(i_left_term);  i_left_term  = 1; end       % default: L-CFA seed

    M.iliac = struct();
    M.iliac.right = iliac_meas(Pv_mm_right, arcR, DiamR, ...
        i_bifurc, i_right_term, lm('right_internal_iliac'));
    M.iliac.left  = iliac_meas(Pv_mm_left,  arcL, DiamL, ...
        nL,        i_left_term,  lm('left_internal_iliac'));

    % --- Distances ---------------------------------------------------
    M.distances = struct();
    if ~isnan(i_renal) && ~isnan(i_bifurc)
        M.distances.renals_to_bifurc_mm = abs(arcR(i_bifurc) - arcR(i_renal));
    else
        M.distances.renals_to_bifurc_mm = NaN;
    end
    M.distances.bifurc_to_int_iliac_mm = struct('right', NaN, 'left', NaN);
    if ~isnan(i_bifurc) && ~isnan(lm('right_internal_iliac'))
        M.distances.bifurc_to_int_iliac_mm.right = ...
            abs(arcR(lm('right_internal_iliac')) - arcR(i_bifurc));
    end
    if ~isnan(lm('left_internal_iliac'))
        M.distances.bifurc_to_int_iliac_mm.left = ...
            abs(arcL(lm('left_internal_iliac')) - arcL(end));
    end

    % --- Bifurcation (iliac take-off) angle -------------------------
    % Angle between the two iliac trunks measured 20 mm distal to the
    % aortic bifurcation. The right polyline runs distal→proximal, so
    % the bifurc-to-distal direction along the right is achieved by
    % indexing decreasing arc length from i_bifurc. The left polyline
    % runs L-CFA → bifurc, so its bifurc is at the END.
    tangent_mm = 20;
    M.bifurcation_angle_deg = NaN;
    if ~isnan(i_bifurc) && i_bifurc > 1 && size(Pv_mm_right, 1) >= 3 && size(Pv_mm_left, 1) >= 3
        % Right: walk 20 mm distally from the bifurc along Pv_mm_right
        % (distal direction is decreasing index since the polyline is
        % distal→proximal).
        target_arc_R = arcR(i_bifurc) - tangent_mm;
        iR_tan = find(arcR <= target_arc_R, 1, 'last');
        if isempty(iR_tan); iR_tan = 1; end
        % Left: walk 20 mm proximal-from-distal from the bifurc-end of
        % Pv_mm_left (the left polyline ends at the bifurc). I.e. step
        % BACK from the end by 20 mm of arc.
        target_arc_L = arcL(end) - tangent_mm;
        iL_tan = find(arcL <= target_arc_L, 1, 'last');
        if isempty(iL_tan); iL_tan = 1; end
        if iR_tan < i_bifurc && iL_tan < numel(arcL)
            % Vectors point FROM bifurc TOWARD distal CFA on each side.
            vR = Pv_mm_right(iR_tan, :) - Pv_mm_right(i_bifurc, :);
            vL = Pv_mm_left (iL_tan, :) - Pv_mm_left (end,      :);
            if norm(vR) > 1e-6 && norm(vL) > 1e-6
                M.bifurcation_angle_deg = acosd(max(-1, min(1, ...
                    dot(vR, vL) / (norm(vR) * norm(vL)))));
            end
        end
    end

    % --- Echo back the inputs and derived quantities ----------------
    M.landmarks      = landmarks;
    M.bifurc_node    = bifurc_node;
    M.arc_right      = arcR;
    M.arc_left       = arcL;
    M.diameter_right = DiamR;
    M.diameter_left  = DiamL;
end

% =========================================================================
function out = iliac_meas(Pv_mm, arc, Diam, i_bifurc, i_terminus, i_int)
%ILIAC_MEAS  Measurements over the segment between i_bifurc and
%   i_terminus on a single polyline. The polyline runs distal→proximal,
%   so for the LEFT side, i_bifurc = end-of-polyline (proximal), and
%   i_terminus = 1 (CFA). For the RIGHT side, i_bifurc may be in the
%   middle; we slice between min and max indices.
    out = struct('cia_diameter_mm', NaN, 'eia_diameter_mm', NaN, ...
                 'tortuosity', NaN, 'length_mm', NaN);
    if any(isnan([i_bifurc, i_terminus])); return; end
    lo = min(i_bifurc, i_terminus); hi = max(i_bifurc, i_terminus);
    if hi - lo < 2; return; end

    seg_arc = arc(lo:hi);
    seg_D   = Diam(lo:hi);
    seg_P   = Pv_mm(lo:hi, :);

    % Common iliac (CIA) = proximal third (closer to bifurc) of the
    % iliac arc — this is the proximal sealing zone for an iliac limb.
    % External iliac (EIA) = distal third (closer to CFA).
    % Polyline distal→proximal means proximal-third is at the END of
    % the slice when i_bifurc > i_terminus, START when i_bifurc < i_term.
    n_seg = numel(seg_D);
    third = max(1, round(0.30 * n_seg));
    if i_bifurc > i_terminus
        cia = seg_D(end-third+1:end);   % near i_bifurc → proximal
        eia = seg_D(1:third);           % near i_terminus → distal
    else
        cia = seg_D(1:third);
        eia = seg_D(end-third+1:end);
    end
    out.cia_diameter_mm = mean(cia);
    out.eia_diameter_mm = mean(eia);

    % Tortuosity = arc / chord
    chord  = norm(seg_P(end, :) - seg_P(1, :));
    arclen = seg_arc(end) - seg_arc(1);
    out.length_mm  = arclen;
    out.tortuosity = arclen / max(chord, eps);

    if ~isnan(i_int) && i_int >= lo && i_int <= hi
        out.bifurc_to_int_arc_mm = abs(arc(i_int) - arc(i_bifurc));
    end
end
