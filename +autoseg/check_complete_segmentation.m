function rep = check_complete_segmentation(out, D, opts)
%AUTOSEG.CHECK_COMPLETE_SEGMENTATION  Acceptance gate for a "complete"
%   aortic segmentation: one connected vessel from the proximal neck down
%   through BOTH iliacs/CFAs, with the bifurcated centerline routing
%   end-to-end to each CFA seed (no distal truncation).
%
%   REP = autoseg.check_complete_segmentation(OUT, D, OPTS)
%
%   This is the objective the planner must clear on every case ("able to
%   completely segment the aorta"). It was written to catch the JohnDoe1
%   failure mode where the distal right iliac/CFA — present on every slice
%   but fragmented into in-plane-staggered 3-D components — got dropped by
%   step 6b's keep-largest-CC, truncating the right centerline 87 mm short
%   of the FOV bottom while the genuine contrast ran all the way down.
%
%   INPUT
%       OUT   planner_result struct from run_planner_headless, with fields
%             .mask        logical Y×X×Z kept-largest vessel mask
%             .seeds       voxel seeds .proximal/.right_cfa/.left_cfa
%             .seeds_mm    same in patient mm
%             .Pv_mm_right Nx3 centerline proximal→R-CFA (mm)
%             .Pv_mm_left  Mx3 centerline proximal→L-CFA (mm)
%       D     dicom_load struct (.vol, .slice_spacing_mm) for geometry.
%       OPTS  struct, optional:
%             .fov_tol_mm   how close each chain's distal mask must get to
%                           the FOV bottom slice (default 20 mm).
%             .cl_seed_tol_mm  how close each branch must terminate to its
%                           DISTAL CFA seed (default 12 mm).
%             .cl_prox_tol_mm  how close the PROXIMAL side of each branch
%                           must reach its anchor — the proximal seed for
%                           the right/primary branch, or the trunk (right
%                           polyline) for the bifurcation-trimmed left
%                           branch (default 20 mm).
%             .min_largest_frac  largest 26-CC must hold this fraction of
%                           all mask voxels (default 0.999 — one component).
%             .verbose      default true.
%
%   OUTPUT
%       REP   struct: .pass (logical) plus per-criterion booleans/metrics
%             (.single_cc, .right_reach_ok, .left_reach_ok,
%             .right_cl_ok, .left_cl_ok, .n_cc, .largest_frac,
%             .right_gap_mm, .left_gap_mm, .right_cl_gap_mm,
%             .left_cl_gap_mm, .reasons cellstr).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        out  (1,1) struct
        D    (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'fov_tol_mm');       opts.fov_tol_mm = 20;       end
    if ~isfield(opts, 'cl_seed_tol_mm');   opts.cl_seed_tol_mm = 12;   end
    if ~isfield(opts, 'cl_prox_tol_mm');   opts.cl_prox_tol_mm = 20;   end
    if ~isfield(opts, 'min_largest_frac'); opts.min_largest_frac = 0.999; end
    if ~isfield(opts, 'span_frac');        opts.span_frac = 0.6;       end
    if ~isfield(opts, 'verbose');          opts.verbose = true;        end

    mask = out.mask;
    sz   = size(mask);
    if numel(sz) < 3; sz(3) = 1; end
    dz   = abs(D.slice_spacing_mm);

    reasons = {};

    % --- (1) One connected vessel -------------------------------------
    cc = bwconncomp(mask, 26);
    n_cc = cc.NumObjects;
    if n_cc == 0
        largest_frac = 0;
    else
        largest_frac = max(cellfun(@numel, cc.PixelIdxList)) / max(1, nnz(mask));
    end
    single_cc = (largest_frac >= opts.min_largest_frac);
    if ~single_cc
        reasons{end+1} = sprintf('mask is not one component (%d CCs, largest %.1f%%)', ...
            n_cc, 100 * largest_frac);
    end

    % --- (2) Both chains reach the FOV bottom -------------------------
    % Split the mask at the proximal seed column (between the two CFAs)
    % and measure how far each side's distal-most voxel sits above the
    % last image slice. A truncated distal iliac/CFA shows up as a large
    % gap on its side.
    mid = round(out.seeds.proximal(2));
    if isfield(out.seeds, 'right_cfa') && isfield(out.seeds, 'left_cfa')
        mid = round((out.seeds.right_cfa(2) + out.seeds.left_cfa(2)) / 2);
    end
    mid = min(max(mid, 1), sz(2));

    rightM = mask; rightM(:, mid+1:end, :) = false;
    leftM  = mask; leftM(:, 1:mid, :)      = false;

    right_zlast = last_z(rightM);
    left_zlast  = last_z(leftM);

    right_gap_mm = (sz(3) - right_zlast) * dz;
    left_gap_mm  = (sz(3) - left_zlast)  * dz;

    right_reach_ok = ~isempty(right_zlast) && right_gap_mm <= opts.fov_tol_mm;
    left_reach_ok  = ~isempty(left_zlast)  && left_gap_mm  <= opts.fov_tol_mm;
    if ~right_reach_ok
        reasons{end+1} = sprintf('right chain stops %.0f mm above FOV bottom (tol %.0f)', ...
            right_gap_mm, opts.fov_tol_mm);
    end
    if ~left_reach_ok
        reasons{end+1} = sprintf('left chain stops %.0f mm above FOV bottom (tol %.0f)', ...
            left_gap_mm, opts.fov_tol_mm);
    end

    % --- (3) Centerline routes end-to-end along the bifurcated tree ---
    % The two stored polylines model a TREE, not two independent legs:
    %   right (primary): R-CFA distal --> proximal SOURCE (the full trunk)
    %   left           : L-CFA distal --> BIFURCATION (joins the right
    %                    polyline; vmtk_centerline.compute trims it there)
    % So a complete branch must (a) reach its CFA seed distally, (b) reach
    % its PROXIMAL anchor — the proximal seed for the right branch, or the
    % trunk (right polyline) for the bifurcation-trimmed left branch — and
    % (c) have an arc length >= span_frac of the straight proximal->CFA
    % separation. (a) alone is NOT enough: a degenerate VMTK polyline can
    % collapse to the target point and sit 0 mm from the CFA seed while
    % never traversing the vessel (the JohnDoe2 post-reconnection failure:
    % right branch = 2 nodes, arc 0 mm). The proximal-anchor + arc-span
    % gates reject it. Requiring the LEFT branch to reach the proximal SEED
    % would be wrong — it legitimately ends ~170-210 mm distal of it, at
    % the bifurcation — so the left branch's proximal anchor is the trunk.
    [right_cl_ok, right_cl_gap_mm, right_cl] = cl_branch_ok(out.Pv_mm_right, ...
        out.seeds_mm.right_cfa, out.seeds_mm.proximal, [], ...
        opts.cl_seed_tol_mm, opts.cl_prox_tol_mm, opts.span_frac);
    [left_cl_ok,  left_cl_gap_mm,  left_cl]  = cl_branch_ok(out.Pv_mm_left, ...
        out.seeds_mm.left_cfa,  out.seeds_mm.proximal, out.Pv_mm_right, ...
        opts.cl_seed_tol_mm, opts.cl_prox_tol_mm, opts.span_frac);
    if ~right_cl_ok
        reasons{end+1} = sprintf(['right centerline not end-to-end ' ...
            '(CFA gap %.0f, prox gap %.0f mm, arc %.0f/%.0f mm)'], ...
            right_cl.cfa_gap, right_cl.prox_gap, right_cl.arc, right_cl.straight);
    end
    if ~left_cl_ok
        reasons{end+1} = sprintf(['left centerline not end-to-end ' ...
            '(CFA gap %.0f, prox gap %.0f mm, arc %.0f/%.0f mm)'], ...
            left_cl.cfa_gap, left_cl.prox_gap, left_cl.arc, left_cl.straight);
    end

    pass = single_cc && right_reach_ok && left_reach_ok && right_cl_ok && left_cl_ok;

    rep = struct( ...
        'pass',           pass, ...
        'single_cc',      single_cc, ...
        'n_cc',           n_cc, ...
        'largest_frac',   largest_frac, ...
        'right_reach_ok', right_reach_ok, ...
        'left_reach_ok',  left_reach_ok, ...
        'right_gap_mm',   right_gap_mm, ...
        'left_gap_mm',    left_gap_mm, ...
        'right_cl_ok',    right_cl_ok, ...
        'left_cl_ok',     left_cl_ok, ...
        'right_cl_gap_mm', right_cl_gap_mm, ...
        'left_cl_gap_mm', left_cl_gap_mm, ...
        'reasons',        {reasons});

    if opts.verbose
        fprintf('[check_complete_segmentation] %s\n', ternary(pass, 'PASS', 'FAIL'));
        fprintf('    single component : %s (%d CCs, largest %.2f%%)\n', ...
            tf(single_cc), n_cc, 100 * largest_frac);
        fprintf('    right reach      : %s (%.0f mm above FOV bottom)\n', ...
            tf(right_reach_ok), right_gap_mm);
        fprintf('    left  reach      : %s (%.0f mm above FOV bottom)\n', ...
            tf(left_reach_ok), left_gap_mm);
        fprintf('    right centerline : %s (CFA %.0f / prox %.0f mm, arc %.0f/%.0f mm)\n', ...
            tf(right_cl_ok), right_cl.cfa_gap, right_cl.prox_gap, right_cl.arc, right_cl.straight);
        fprintf('    left  centerline : %s (CFA %.0f / prox %.0f mm, arc %.0f/%.0f mm)\n', ...
            tf(left_cl_ok), left_cl.cfa_gap, left_cl.prox_gap, left_cl.arc, left_cl.straight);
        for k = 1:numel(reasons)
            fprintf('    - %s\n', reasons{k});
        end
    end
end

% -------------------------------------------------------------------------
function z = last_z(M)
%LAST_Z  Index of the distal-most (largest-index) slice holding any voxel.
    zspan = squeeze(any(any(M, 1), 2));
    z = find(zspan, 1, 'last');
end

function [ok, cfa_gap, m] = cl_branch_ok(Pv, cfa_mm, prox_mm, trunk_Pv, ...
        cfa_tol_mm, prox_tol_mm, span_frac)
%CL_BRANCH_OK  True if one branch of the bifurcated tree is a genuine
%   end-to-end traversal.
%
%   DISTAL  : must come within CFA_TOL_MM of its CFA seed.
%   PROXIMAL: must come within PROX_TOL_MM of its proximal anchor —
%             * TRUNK_PV empty  -> the proximal SEED (right/primary branch
%               is the full trunk to the source);
%             * TRUNK_PV given  -> the trunk itself, i.e. the branch's
%               closest approach to the right polyline (the left branch is
%               trimmed at the bifurcation and joins the trunk there, so it
%               must NOT be required to reach the proximal seed).
%   SPAN    : (PRIMARY/right branch only) arc length >= SPAN_FRAC of the
%             straight proximal->CFA distance. This FIXED anatomic reference
%             (independent of the polyline) rejects a degenerate polyline
%             that collapses onto the CFA target (0 mm CFA gap but ~0 mm arc,
%             no traversal). The span gate is NOT applied to the secondary
%             (left) branch: it spans only bifurcation->CFA, so a full
%             proximal->CFA reference would be geometry-fragile (it would
%             false-fail a high-bifurcation / short-iliac case). The
%             trunk-join PROXIMAL gate already rejects the degenerate
%             CFA-collapse for the left branch (a 2-node collapse sits far
%             from the trunk), so the span gate is redundant there.
    m = struct('cfa_gap', inf, 'prox_gap', inf, 'arc', 0, 'straight', 0);
    m.straight = node_dist(cfa_mm(:)', prox_mm(:)');
    if isempty(Pv) || size(Pv, 1) < 2
        ok = false; cfa_gap = inf; return;
    end
    m.cfa_gap = min(seed_node_dist(Pv, cfa_mm));
    is_primary = isempty(trunk_Pv);
    if is_primary
        m.prox_gap = min(seed_node_dist(Pv, prox_mm));   % reach proximal seed
    else
        m.prox_gap = min_polyline_dist(Pv, trunk_Pv);    % join the trunk
    end
    m.arc   = sum(vecnorm(diff(Pv), 2, 2));
    cfa_gap = m.cfa_gap;
    reach_ok = (m.cfa_gap <= cfa_tol_mm) && (m.prox_gap <= prox_tol_mm);
    if is_primary
        ok = reach_ok && (m.arc >= span_frac * m.straight);  % + span gate
    else
        ok = reach_ok;                                       % trunk-join only
    end
end

function d = min_polyline_dist(A, B)
%MIN_POLYLINE_DIST  Minimum Euclidean distance between any node of A and
%   any node of B. Both polylines are VMTK output in the SAME [y x z]
%   frame, so (unlike seed comparisons) no x<->y swap is needed.
    d = inf;
    for i = 1:size(A, 1)
        dd = min(vecnorm(B - A(i, :), 2, 2));
        if dd < d; d = dd; end
    end
end

function d = seed_node_dist(Pv, seed_mm)
%SEED_NODE_DIST  Per-node distance from Pv to seed_mm, robust to the
%   in-plane (x,y) ordering convention: the VMTK backend emits Pv_mm as
%   [y_mm, x_mm, z] while seeds_mm (and the MATLAB-skeleton backend) use
%   [x_mm, y_mm, z]. The z axis is shared. We take the smaller of the two
%   in-plane orderings (identity vs x<->y swap) per node — a genuinely
%   truncated centerline is far under BOTH orderings, so this cannot
%   manufacture a false pass, while the <=1-voxel zero/one-based offset is
%   well inside TOL_MM.
    s  = seed_mm(:)';
    dz = (Pv(:, 3) - s(3)).^2;
    d_id   = sqrt((Pv(:, 1) - s(1)).^2 + (Pv(:, 2) - s(2)).^2 + dz);  % [x y z]
    d_swap = sqrt((Pv(:, 1) - s(2)).^2 + (Pv(:, 2) - s(1)).^2 + dz);  % [y x z]
    d = min(d_id, d_swap);
end

function d = node_dist(a, b)
    d = sqrt(sum((a - b).^2));
end

function s = tf(b)
    if b; s = 'OK '; else; s = 'XX '; end
end

function s = ternary(c, a, b)
    if c; s = a; else; s = b; end
end
