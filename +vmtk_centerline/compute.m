function out = compute(mask, seed_proximal, seed_right, seed_left, D, opts)
%VMTK_CENTERLINE.COMPUTE  Compute paired EVAR centerlines via VMTK.
%
%   OUT = vmtk_centerline.compute(MASK, SEED_PROX, SEED_R, SEED_L, D)
%   OUT = vmtk_centerline.compute(..., opts)
%
%   Calls the external tool:
%       Antiga L, Piccinelli M, Botti L, et al. An image-based modeling
%       framework for patient-specific computational hemodynamics.
%       Med Biol Eng Comput 2008;46(11):1097–112.
%       http://www.vmtk.org   (BSD-3-Clause)
%
%   Internals: writes the binary mask to a NIfTI, surface-meshes it
%   via vmtkmarchingcubes, runs vmtkcenterlines with one source
%   (proximal aorta) and two targets (right + left CFA) to produce a
%   bifurcating tree, parses the resulting VTP, and projects the two
%   centerlines back into the same voxel grid as MASK.
%
%   Inputs
%       MASK            Y×X×Z logical aortic + iliac segmentation
%       SEED_PROXIMAL   1×3 voxel coords [y x z]
%       SEED_RIGHT      1×3 voxel coords  (right CFA)
%       SEED_LEFT       1×3 voxel coords  (left CFA)
%       D               struct from preprocess.dicom_load (for spacing)
%       opts            struct, optional:
%           .smooth_iters     surface Laplacian smoothing (default 10)
%           .reduce           surface decimation fraction (default 0.5)
%           .timeout_s        CLI hard timeout (default 120)
%           .work_dir         temp folder (default a tempname)
%           .keep_work        retain temp files for debugging (default false)
%
%   Output struct
%       OUT.Pv_mm_right       N1×3 polyline distal→proximal in mm
%       OUT.R_mm_right        N1×1 maximum-inscribed-sphere radius in mm
%       OUT.Pv_mm_left        N2×3 left polyline; ends at the bifurc
%                             (where it joins the right polyline)
%       OUT.R_mm_left         N2×1
%       OUT.bifurc_node_right index on Pv_mm_right at the bifurc node
%       OUT.processing_time   seconds
%       OUT.invocation        cellstr of the exact commands run
%       OUT.from_cache        false (no caching at this layer; call
%                             site can wrap if desired)
%
%   Errors
%       'vmtk_centerline:compute:Unavailable' — VMTK CLI missing
%       'vmtk_centerline:compute:Failed'      — runtime error

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask          logical
        seed_proximal (1,3) double
        seed_right    (1,3) double
        seed_left     (1,3) double
        D             (1,1) struct
        opts          (1,1) struct = struct()
    end
    if ~isfield(opts, 'smooth_iters'); opts.smooth_iters = 10;  end
    if ~isfield(opts, 'reduce');       opts.reduce       = 0.5; end
    if ~isfield(opts, 'timeout_s');    opts.timeout_s    = 120; end
    if ~isfield(opts, 'keep_work');    opts.keep_work    = false; end
    if ~isfield(opts, 'work_dir');     opts.work_dir     = tempname; end

    avail = vmtk_centerline.detect();
    if ~avail.available
        ME = MException('vmtk_centerline:compute:Unavailable', ...
            'VMTK CLI not found. %s', avail.error);
        throw(ME);
    end

    if ~exist(opts.work_dir, 'dir'); mkdir(opts.work_dir); end
    cleanup = onCleanup(@() cleanup_work(opts));

    surf_path = fullfile(opts.work_dir, 'surf.vtp');
    cl_path   = fullfile(opts.work_dir, 'cl.vtp');

    invocation = {};
    t0 = tic;

    % --- Step 1: build the surface from the mask --------------------
    % We use our own marching cubes (io.write_vtp_surface) rather than
    % vmtkmarchingcubes — it avoids a NIfTI write/read for the mask,
    % handles mm scaling cleanly, and Laplacian-smooths in MATLAB.
    io.write_vtp_surface(mask, surf_path, ...
        struct('pixel_mm', D.pixel_mm, ...
               'slice_spacing_mm', D.slice_spacing_mm, ...
               'smooth_iters', opts.smooth_iters, ...
               'reduce', opts.reduce));

    % --- Step 2: convert seeds (voxel coords) → millimeter coords --
    p_mm = vox_to_mm(seed_proximal, D);
    r_mm = vox_to_mm(seed_right,    D);
    l_mm = vox_to_mm(seed_left,     D);

    % --- Step 3: vmtkcenterlines with one source, two targets ------
    % source = proximal aorta; targets = R-CFA, L-CFA.
    % vmtkcenterlines outputs centerlines from EACH target back to
    % the source, sharing the upstream segment. The output VTP holds
    % both polylines as separate <Lines>.
    % Use avail.invocation rather than path_centerlines directly: VMTK
    % scripts have `#!/usr/bin/env python` shebangs that resolve to the
    % first python on PATH, which may not have the vmtk module. The
    % invocation prefix pins the right interpreter.
    cmd_parts = { ...
        avail.invocation, ...
        '-ifile', escape(surf_path), ...
        '-seedselector pointlist', ...
        sprintf('-sourcepoints %.3f %.3f %.3f', p_mm(2), p_mm(1), p_mm(3)), ...
        sprintf('-targetpoints %.3f %.3f %.3f %.3f %.3f %.3f', ...
                r_mm(2), r_mm(1), r_mm(3), ...
                l_mm(2), l_mm(1), l_mm(3)), ...
        '-ofile', escape(cl_path)};
    cmd = strjoin(cmd_parts, ' ');
    invocation{end+1} = cmd;
    [rc, output] = system(cmd);
    if rc ~= 0
        ME = MException('vmtk_centerline:compute:Failed', ...
            ['vmtkcenterlines failed (rc=%d).\n\nCommand:\n  %s\n\n' ...
             'Output:\n%s'], rc, cmd, output);
        throw(ME);
    end

    % --- Step 4: parse the VTP into two polylines ------------------
    % VMTK 1.5 writes binary, zlib-compressed VTP by default, which
    % the simple ASCII parser in io.read_vtp_polyline can't decode.
    % We shell out to a small Python helper (vmtk_centerline/vtp_to_csv.py)
    % that loads the VTP via VTK's reader and writes plain CSVs.
    helper_py = fullfile(fileparts(mfilename('fullpath')), 'vtp_to_csv.py');
    csv_stem  = fullfile(opts.work_dir, 'cl');
    cmd_cvt = sprintf('%s %s %s %s', avail.python, escape(helper_py), ...
                      escape(cl_path), escape(csv_stem));
    invocation{end+1} = cmd_cvt;
    [rc, output] = system(cmd_cvt);
    if rc ~= 0
        ME = MException('vmtk_centerline:compute:CSVFailed', ...
            'vtp_to_csv.py failed (rc=%d):\n  %s\n%s', rc, cmd_cvt, output);
        throw(ME);
    end
    cl = read_vmtk_csv(csv_stem);
    if numel(cl.lines) < 2
        ME = MException('vmtk_centerline:compute:Topology', ...
            ['vmtkcenterlines returned %d centerline(s); expected 2 ' ...
             '(R-CFA + L-CFA targets).'], numel(cl.lines));
        throw(ME);
    end

    [P_right_distalup, R_right_distalup] = extract_line(cl, r_mm, 1);
    [P_left_distalup,  R_left_distalup]  = extract_line(cl, l_mm, 2);

    % --- Step 5: find the bifurcation node on the right polyline ---
    % Walk from L-CFA up the left polyline; the first node that lies
    % on the right polyline (within a small mm tolerance) is the
    % bifurcation. If VMTK already shares those upstream nodes the
    % match is exact; otherwise we snap.
    [bifurc_idx_right, bifurc_idx_left] = find_bifurc( ...
        P_right_distalup, P_left_distalup);

    % Trim left polyline at the bifurcation so it ends exactly there
    P_left_distalup = P_left_distalup(1:bifurc_idx_left, :);
    R_left_distalup = R_left_distalup(1:bifurc_idx_left);

    % --- Step 6: remap Z from voxel-frame to DICOM-patient-frame -----
    % Internally VMTK works in vox*spacing coordinates (origin at
    % 0,0,0). External callers (the planner, the GUI, evar_plan) expect
    % polylines in the same frame as `preprocess.centerline_to_mm` —
    % i.e. with Z interpolated from `D.slice_z_mm` so it carries the
    % DICOM image-position-patient Z offset. Apply that remap here so
    % VMTK output is drop-in compatible with the MATLAB-skeleton path.
    P_right_distalup = remap_z_to_dicom(P_right_distalup, D);
    P_left_distalup  = remap_z_to_dicom(P_left_distalup,  D);

    out = struct();
    out.Pv_mm_right       = P_right_distalup;
    out.R_mm_right        = R_right_distalup;
    out.Pv_mm_left        = P_left_distalup;
    out.R_mm_left         = R_left_distalup;
    out.bifurc_node_right = bifurc_idx_right;
    out.processing_time   = toc(t0);
    out.invocation        = invocation;
    out.from_cache        = false;
end

% =========================================================================
function P_out = remap_z_to_dicom(P, D)
% Remap the Z column of an (N×3 [Y, X, Z]) polyline from VMTK's
% vox*spacing frame to the DICOM patient-position frame (matches
% preprocess.centerline_to_mm). When D.slice_z_mm is absent (synthetic
% phantoms), the two frames coincide and this is a no-op.
    P_out = P;
    if ~isfield(D, 'slice_z_mm') || isempty(D.slice_z_mm)
        return;
    end
    % VMTK Z values are (z_idx - 1) * D.slice_spacing_mm (0-based).
    % Recover z_idx (1-based), then look up the DICOM-frame mm.
    ssp = abs(D.slice_spacing_mm);
    if ssp < eps; return; end
    z_idx = P(:, 3) / ssp + 1;
    z_idx_clamped = min(max(z_idx, 1), numel(D.slice_z_mm));
    P_out(:, 3) = interp1(1:numel(D.slice_z_mm), D.slice_z_mm, ...
                          z_idx_clamped, 'linear');
end

% =========================================================================
function pt_mm = vox_to_mm(vox, D)
    pt_mm = [(vox(1)-1) * D.pixel_mm(1), ...
             (vox(2)-1) * D.pixel_mm(2), ...
             (vox(3)-1) * D.slice_spacing_mm];
end

function s = escape(p)
    s = ['"', strrep(p, '"', '\"'), '"'];
end

function cleanup_work(opts)
    if ~opts.keep_work && exist(opts.work_dir, 'dir')
        rmdir(opts.work_dir, 's');
    end
end

function cl = read_vmtk_csv(stem)
%READ_VMTK_CSV  Parse the CSVs written by vtp_to_csv.py into the same
%   struct shape the rest of compute.m expects:
%       cl.points  N×3 mm coordinates
%       cl.radii   N×1 inscribed-sphere radius
%       cl.lines   cell array of 0-based index lists into cl.points
    pts_path = [stem, '_points.csv'];
    lns_path = [stem, '_lines.csv'];
    if ~isfile(pts_path) || ~isfile(lns_path)
        error('read_vmtk_csv:Missing', ...
            'Expected %s and %s after vtp_to_csv.py', pts_path, lns_path);
    end
    T = readtable(pts_path);
    cl.points = [T.x, T.y, T.z];
    cl.radii  = T.radius;

    fid = fopen(lns_path, 'r');
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fgetl(fid);   % skip header
    cl.lines = {};
    while true
        line = fgetl(fid);
        if ~ischar(line); break; end
        parts = split(line, ',');
        if numel(parts) < 3; continue; end
        ids = sscanf(parts{3}, '%d');   % space-separated indices
        cl.lines{end+1} = ids; %#ok<AGROW>
    end
end

function [P, R] = extract_line(cl, target_mm, idx_hint)
%EXTRACT_LINE  Pull one polyline out of a multi-line VTP, oriented so
%   the first node is closest to TARGET_MM (= the distal CFA seed).
%
%   Coordinate convention: cl.points is in VMTK's (X, Y, Z) order (what
%   write_vtp_surface wrote — isosurface returns [X Y Z] vertices).
%   target_mm is in our (Y, X, Z) caller convention. Swap target_mm to
%   (X, Y, Z) for all distance comparisons against cl.points, then swap
%   the final output back to (Y, X, Z).
    if idx_hint > numel(cl.lines)
        idx_hint = numel(cl.lines);
    end
    target_xyz = [target_mm(2), target_mm(1), target_mm(3)];
    % If the hinted line is farther from target than another line is,
    % swap. (VMTK's output ordering is stable but defensive coding.)
    best_d = inf; best_k = idx_hint;
    for k = 1:numel(cl.lines)
        endpoints = cl.points(cl.lines{k}([1 end]) + 1, :);
        d = min(vecnorm(endpoints - target_xyz, 2, 2));
        if d < best_d; best_d = d; best_k = k; end
    end
    line_idx = best_k;
    idx0 = cl.lines{line_idx} + 1;   % 0-based → 1-based
    P_mm = cl.points(idx0, :);
    R_mm = cl.radii(idx0);
    % Orient distal→proximal
    if norm(P_mm(1,:) - target_xyz) > norm(P_mm(end,:) - target_xyz)
        P_mm = flipud(P_mm);
        R_mm = flipud(R_mm);
    end
    % Convert (X, Y, Z) from VMTK to our [Y, X, Z] caller convention.
    P = [P_mm(:,2), P_mm(:,1), P_mm(:,3)];
    R = R_mm;
end

function [k_right, k_left] = find_bifurc(P_right, P_left, tol_mm)
%FIND_BIFURC  Locate the bifurcation node on each polyline.
%
%   Both P_right and P_left are oriented DISTAL → PROXIMAL (first row =
%   CFA seed, last row = shared proximal source). The polylines diverge
%   distally (in the iliacs / CFAs) and merge proximally (shared aortic
%   trunk). The bifurcation is where they first come within `tol_mm` of
%   each other as we walk from the L-CFA toward the source.
%
%   Returns the indices into each polyline at that join.
    if nargin < 3; tol_mm = 1.5; end
    nL = size(P_left, 1);
    nR = size(P_right, 1);
    k_left = nL;   % default: whole left polyline (i.e. no divergence found)
    k_right = nR;
    for kL = 1:nL
        d = vecnorm(P_right - P_left(kL,:), 2, 2);
        [dmin, kR] = min(d);
        if dmin < tol_mm
            k_left = kL;
            k_right = kR;
            return;
        end
    end
    % Fallback — no point pair within tol_mm; pick the globally closest.
    d_all = inf;
    for kL = 1:nL
        d = vecnorm(P_right - P_left(kL,:), 2, 2);
        [dmin, kR] = min(d);
        if dmin < d_all
            d_all = dmin; k_left = kL; k_right = kR;
        end
    end
end
