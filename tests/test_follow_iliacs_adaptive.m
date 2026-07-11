classdef test_follow_iliacs_adaptive < matlab.unittest.TestCase
%TEST_FOLLOW_ILIACS_ADAPTIVE  Regression for the patient-adaptive
%   HU iliac follower (autoseg.follow_iliacs_adaptive).
%
%   The function takes a labeled aorta+iliac mask and a CT volume,
%   samples the aorta's HU distribution to derive a per-patient
%   bolus-anchored window, and region-grows the iliacs through pelvis
%   contrast voxels matching that window.
%
%   PRODUCTION CONTRACT (important): the follower runs AFTER the
%   slice-by-slice walker (autoseg.extend_to_cfa), so the mask it
%   receives ALREADY contains the iliac path tracked to the CFA. The
%   follower's job is a BOUNDED refinement — recover partial-volume
%   edge voxels in the immediate vicinity of that path — NOT long-range
%   extension from an aorta-only seed. The grow is therefore confined to
%   a tube of radius opts.tube_radius_mm around the input mask, which is
%   what stops the HU flood from leaking into pelvic bone marrow on
%   low-contrast scans (arterial bolus and cancellous marrow share the
%   200-400 HU window). The synthetic phantom below mirrors that
%   contract: mask_in carries thin iliac cores (the walker's output),
%   and the follower must thicken them without leaking off-path.
%
%   Tests verify:
%     - Returns the documented info struct shape (bolus_peak,
%       hu_window, R_z_extent, L_z_extent, etc.).
%     - Does not paint voxels outside the adaptive HU window (no
%       synthetic bridges through tissue).
%     - The output mask is a strict superset of the input mask (mask
%       only grows, never shrinks).
%     - The follower thickens the thin iliac cores (real refinement).
%     - The iliacs still reach the FOV bottom (reach preserved).
%     - The tube guard rejects in-window contrast that lies more than
%       tube_radius_mm off the tracked path (leak guard), even when it
%       is 26-connected to the vessel.
%     - Gracefully handles a missing aorta label.

    methods (TestClassSetup)
        function add_paths(tc) %#ok<MANU>
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
        end
    end

    methods (Test)
        function info_struct_has_documented_fields(tc)
            [D, mask_in, label_in] = synth_aorta_iliac();
            [~, info] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, struct('verbose', false));
            required = {'bolus_peak_hu', 'bolus_std_hu', 'hu_window', ...
                'z_bifurc', 'seed_voxels', 'grown_voxels', ...
                'R_z_extent', 'L_z_extent', 'vessel_max_mm2', 'reason'};
            for k = 1:numel(required)
                tc.verifyTrue(isfield(info, required{k}), ...
                    sprintf('info missing field: %s', required{k}));
            end
            tc.verifyEqual(numel(info.hu_window), 2);
            tc.verifyLessThan(info.hu_window(1), info.hu_window(2));
        end

        function mask_only_grows(tc)
            [D, mask_in, label_in] = synth_aorta_iliac();
            [mask_out, ~] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, struct('verbose', false));
            % Output must be a superset of the input
            tc.verifyTrue(all(mask_out(mask_in)), ...
                'output mask must be a strict superset of input');
            tc.verifyGreaterThanOrEqual(nnz(mask_out), nnz(mask_in), ...
                'output mask should not shrink');
        end

        function no_voxels_outside_hu_window(tc)
            [D, mask_in, label_in] = synth_aorta_iliac();
            [mask_out, info] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, struct('verbose', false));
            % Voxels ADDED by the function must all fall within the
            % adaptive HU window (anti-bridge invariant). The input
            % mask may have voxels outside the window — that's fine,
            % the function doesn't remove anything.
            new_voxels = mask_out & ~mask_in;
            if any(new_voxels(:))
                hus = double(D.vol(new_voxels));
                tc.verifyGreaterThanOrEqual(min(hus), info.hu_window(1), ...
                    'newly painted voxels must respect the adaptive HU lower bound (no painting through tissue)');
                tc.verifyLessThanOrEqual(max(hus), info.hu_window(2), ...
                    'newly painted voxels must respect the adaptive HU upper bound');
            end
        end

        function thickens_thin_iliac_cores(tc)
            % The walker leaves thin (partial-volume) iliac cores; the
            % follower's real job is to thicken them out to the true
            % contrast cross-section. Expect a meaningful voxel gain.
            [D, mask_in, label_in] = synth_aorta_iliac();
            [mask_out, ~] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, struct('verbose', false));
            gained = nnz(mask_out) - nnz(mask_in);
            tc.verifyGreaterThan(gained, 200, ...
                sprintf('follower should thicken the iliac cores (gained only %d vox)', gained));
        end

        function bolus_peak_within_aorta_range(tc)
            [D, mask_in, label_in] = synth_aorta_iliac();
            [~, info] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, struct('verbose', false));
            aorta_vox = double(D.vol(label_in == 1));
            tc.verifyGreaterThanOrEqual(info.bolus_peak_hu, prctile(aorta_vox, 1), ...
                'bolus peak should be in the aorta HU range');
            tc.verifyLessThanOrEqual(info.bolus_peak_hu, prctile(aorta_vox, 99), ...
                'bolus peak should be in the aorta HU range');
        end

        function reach_to_fov_bottom_is_preserved(tc)
            % The walker's iliac cores already reach the FOV bottom; the
            % follower must not erode that reach.
            [D, mask_in, label_in] = synth_aorta_iliac();
            [~, info] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, struct('verbose', false));
            sz = size(D.vol);
            tc.verifyGreaterThan(info.R_z_extent(2), sz(3) - 3, ...
                sprintf('R iliac should reach FOV bottom (got z=%d / %d)', ...
                    info.R_z_extent(2), sz(3)));
            tc.verifyGreaterThan(info.L_z_extent(2), sz(3) - 3, ...
                sprintf('L iliac should reach FOV bottom (got z=%d / %d)', ...
                    info.L_z_extent(2), sz(3)));
        end

        function tube_guard_rejects_offpath_contrast(tc)
            % Build a phantom with a "bone-marrow" slab in the adaptive
            % HU window that is 26-connected to the iliac contrast but
            % extends far (> tube_radius_mm) laterally off the tracked
            % path. Without the tube confinement an imreconstruct flood
            % would swallow the whole slab; with it, voxels beyond the
            % tube must stay OUT of the mask.
            [D, mask_in, label_in, probe_far, probe_near] = synth_aorta_iliac(true);
            [mask_out, ~] = autoseg.follow_iliacs_adaptive(D, mask_in, label_in, ...
                struct('verbose', false, 'tube_radius_mm', 5));
            tc.verifyFalse(mask_out(probe_far(1), probe_far(2), probe_far(3)), ...
                'off-path marrow voxel (> tube radius) must be rejected by the tube guard');
            % Sanity: a voxel ON the iliac path should be retained.
            tc.verifyTrue(mask_out(probe_near(1), probe_near(2), probe_near(3)), ...
                'on-path iliac voxel must be retained');
        end

        function gracefully_handles_no_aorta_label(tc)
            [D, mask_in, ~] = synth_aorta_iliac();
            label_empty = zeros(size(mask_in), 'uint8');   % no aorta label
            [mask_out, info] = autoseg.follow_iliacs_adaptive(D, mask_in, label_empty, struct('verbose', false));
            tc.verifyEqual(mask_out, mask_in, 'mask should be unchanged when no aorta label');
            tc.verifyTrue(isfield(info, 'skipped') || isfield(info, 'reason'), ...
                'info should carry a skip/reason');
        end
    end
end

% =========================================================================
function [D, mask, label, probe_far, probe_near] = synth_aorta_iliac(add_marrow)
%SYNTH_AORTA_ILIAC  Build a tiny synthetic CT + labeled aorta+iliac
%   mask that mirrors the production contract: the input mask carries
%   the walker's output — the aorta (radius 5, z=1..60) PLUS thin iliac
%   cores (radius ~1) tracked to the FOV bottom (z=60..120). The CT
%   contains the full-calibre iliac contrast (radius 3), so the
%   follower's job is to thicken the cores. With ADD_MARROW true, a
%   lateral in-window "bone-marrow" slab is attached to the right iliac
%   to exercise the tube leak guard.
    if nargin < 1; add_marrow = false; end
    sz = [60, 60, 120];
    pix_mm = [0.7, 0.7];
    slc_mm = 0.7;
    rng(7);                                       % deterministic
    vol = -200 + 50 * randn(sz, 'single');        % soft-tissue baseline ~-200 HU

    [yy, xx, zz] = ndgrid(1:sz(1), 1:sz(2), 1:sz(3));
    % Aorta cylinder z=1..60 at (30, 30) radius 5
    aorta_cyl = (yy - 30).^2 + (xx - 30).^2 < 25 & zz <= 60;
    % R iliac z=60..120: centroid moves from (30,30) at z=60 to (40,15) at z=120
    R_cy = 30 + (zz - 60) / 60 * 10;
    R_cx = 30 + (zz - 60) / 60 * (-15);
    R_full = (yy - R_cy).^2 + (xx - R_cx).^2 < 9 & zz >= 60 & zz <= 120;   % radius 3 contrast
    R_core = (yy - R_cy).^2 + (xx - R_cx).^2 < 2 & zz >= 60 & zz <= 120;   % thin core
    % L iliac similarly
    L_cy = 30 + (zz - 60) / 60 * 10;
    L_cx = 30 + (zz - 60) / 60 * 15;
    L_full = (yy - L_cy).^2 + (xx - L_cx).^2 < 9 & zz >= 60 & zz <= 120;
    L_core = (yy - L_cy).^2 + (xx - L_cx).^2 < 2 & zz >= 60 & zz <= 120;

    contrast_voxels = aorta_cyl | R_full | L_full;

    probe_far = [1 1 1]; probe_near = [1 1 1];
    if add_marrow
        % A lateral slab in the SAME HU window, 26-connected to the R
        % iliac at a mid-iliac z-band, extending ~20 voxels laterally
        % (well beyond the 5 mm ≈ 7-voxel tube radius).
        zband = zz >= 88 & zz <= 92;
        % from the R iliac core (x≈22 at z≈90) sweeping to x≈2
        marrow = (xx <= 24) & (xx >= 2) & abs(yy - 35) <= 3 & zband;
        contrast_voxels = contrast_voxels | marrow;
        probe_far  = [35, 4, 90];     % deep in the slab, ~18 vox off-path
        probe_near = [35, 22, 90];    % on the R iliac core
    end

    vol(contrast_voxels) = 400 + 30 * randn(nnz(contrast_voxels), 1, 'single');  % bolus ~400 HU

    D = struct();
    D.vol = int16(vol);
    D.pixel_mm = pix_mm;
    D.slice_spacing_mm = slc_mm;
    D.slice_z_mm = (0:sz(3)-1) * slc_mm;
    D.is_volume = true;

    % Input mask = walker output: aorta (label 1) + thin iliac cores
    % (labels 2/3). The full iliac contrast is left for the follower to
    % thicken into. The marrow slab is NOT seeded.
    mask = aorta_cyl | R_core | L_core;
    label = zeros(sz, 'uint8');
    label(aorta_cyl) = 1;
    label(R_core)    = 2;
    label(L_core)    = 3;
end
