function out = segments()
%PHANTOM.SEGMENTS  Returns a struct of function handles for building the
%   parametric vessel segments shared by the normal and AAA phantoms.
%
%   USAGE
%       seg = phantom.segments();
%       [P, R] = seg.iliac(p0_mm, z_bifurc, z_term, side, r_prox, r_dist, splay_deg);
%       [P, R] = seg.eia  (p0_mm, z_start, z_end, side, r0, r1);
%       [P, R] = seg.hypogastric(p0_mm, side, r_const);
%       [P, R] = seg.branch(origin_mm, dir_unit, len_mm, r_const);
%
%   Conventions
%       All polylines are in millimeter coordinates [Y X Z].
%       SIDE = -1 → patient's right, +1 → patient's left.
%       Polylines are returned proximal → distal (the caller flips
%       them to distal → proximal when assembling a centerline that
%       starts at the CFA).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    out.iliac        = @make_iliac_segment;
    out.eia          = @make_eia_segment;
    out.cfa          = @make_cfa_segment;
    out.hypogastric  = @make_hypogastric;
    out.branch       = @make_branch;
end

% =========================================================================
function [P, R] = make_iliac_segment(p0_mm, z_bifurc, z_term, side, ...
                                     r_proximal, r_distal, splay_deg)
% Common iliac artery: from p0_mm at z_bifurc to a splayed terminus
% at z_term. Splay angle sets the X drift per mm of Z.
    n_steps = 30;
    t = linspace(0, 1, n_steps).';
    z_seg = z_bifurc * (1-t) + z_term * t;
    dx = (z_term - z_bifurc) * tan(deg2rad(splay_deg));
    x_seg = p0_mm(2) + side * dx * t;
    y_seg = repmat(p0_mm(1), n_steps, 1);
    P = [y_seg, x_seg, z_seg];
    R = r_proximal * (1-t) + r_distal * t;
end

function [P, R] = make_eia_segment(p0_mm, z_start, z_end, side, r0, r1)
% External iliac: from CIA terminus continuing to inguinal level.
% Slight outward drift (half the CIA splay rate, simplified).
    n_steps = 30;
    t = linspace(0, 1, n_steps).';
    z_seg = z_start * (1-t) + z_end * t;
    half_outward = 5;     % mm of additional lateral drift over the EIA
    x_seg = p0_mm(2) + side * half_outward * t;
    y_seg = repmat(p0_mm(1), n_steps, 1);
    P = [y_seg, x_seg, z_seg];
    R = r0 * (1-t) + r1 * t;
end

function [P, R] = make_hypogastric(p0_mm, side, r_const)
% Hypogastric (IIA): short branch off the iliac bifurcation, angled
% lateral-posterior-inferior so it actually projects clear of the
% aorta in coronal MIP (a purely-medial trajectory disappears behind
% the EIA on a coronal projection).
    n_steps = 20;
    t = linspace(0, 1, n_steps).';
    len_mm = 45;
    dir = [+0.6, side*0.25, +0.7];   % +Y post, slight LATERAL, inferior
    dir = dir / norm(dir);
    P = p0_mm + (len_mm * t) * dir;
    R = repmat(r_const, n_steps, 1);
end

function [P, R] = make_cfa_segment(p0_mm, z_start, z_end, side, r0, r1)
% Common femoral artery: continues the EIA below the inguinal ligament
% straight down to the femoral-bifurcation level. CFA is what the
% interventionalist accesses for EVAR — it's the thing the seed point
% sits on, so it has to be present in the phantom.
    n_steps = 30;
    t = linspace(0, 1, n_steps).';
    z_seg = z_start * (1-t) + z_end * t;
    % CFA tracks slightly more lateral than the EIA — the femoral
    % triangle anatomy.
    extra_lat = 3;     % mm
    x_seg = p0_mm(2) + side * extra_lat * t;
    y_seg = repmat(p0_mm(1), n_steps, 1);
    P = [y_seg, x_seg, z_seg];
    R = r0 * (1-t) + r1 * t;
end

function [P, R] = make_branch(origin_mm, dir_unit, len_mm, r_const)
% Generic visceral branch: straight tube from origin along a direction.
    dir_unit = dir_unit / norm(dir_unit);
    n_steps = max(20, ceil(len_mm / 2));
    t = linspace(0, 1, n_steps).';
    P = origin_mm + (len_mm * t) * dir_unit;
    R = repmat(r_const, n_steps, 1);
end
