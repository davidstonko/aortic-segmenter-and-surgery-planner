function out = track_aorta_bifurcated(D, seed_proximal, seed_right_cfa, seed_left_cfa, opts)
%PREPROCESS.TRACK_AORTA_BIFURCATED  Two-tail aorta tracker.
%
%   OUT = preprocess.track_aorta_bifurcated(D, SEED_PROX, SEED_R, SEED_L)
%   OUT = preprocess.track_aorta_bifurcated(D, SEED_PROX, SEED_R, SEED_L, OPTS)
%
%   Runs preprocess.track_aorta_2click twice: once with opts.branch =
%   'right' (proximal → right CFA), once with 'left' (proximal → left
%   CFA). Returns a struct with both trajectories. The shared trunk
%   from the proximal seed down to the aortic bifurcation appears in
%   both trajectories.
%
%   This is the 2-click-tracker counterpart to the skeleton-shortest-
%   path bifurcated centerline in run_planner_headless. Use this
%   tracker when the input mask is too fragmented for a robust 3D
%   skeleton (e.g. raw HU-threshold mask without TS), or when you
%   want per-slice resolution along each iliac.
%
%   OPTS are forwarded to track_aorta_2click. opts.branch is
%   overridden per-call ('right' for the right tail, 'left' for the
%   left tail).
%
%   OUT struct:
%       .right   struct with .mask, .centroids_vox, .R_vox, .info
%                (proximal → right CFA, branch='right')
%       .left    same shape for the left side, branch='left'

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D              (1,1) struct
        seed_proximal  (1,3) double
        seed_right_cfa (1,3) double
        seed_left_cfa  (1,3) double
        opts           (1,1) struct = struct()
    end

    opts_R = opts; opts_R.branch = 'right';
    opts_L = opts; opts_L.branch = 'left';

    [mR, cR, RR, iR] = preprocess.track_aorta_2click( ...
        D, seed_proximal, seed_right_cfa, opts_R);
    [mL, cL, RL, iL] = preprocess.track_aorta_2click( ...
        D, seed_proximal, seed_left_cfa,  opts_L);

    out = struct( ...
        'right', struct('mask', mR, 'centroids_vox', cR, ...
                        'R_vox', RR, 'info', iR), ...
        'left',  struct('mask', mL, 'centroids_vox', cL, ...
                        'R_vox', RL, 'info', iL));
end
