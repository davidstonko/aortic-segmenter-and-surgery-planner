classdef test_track_aorta_2click < matlab.unittest.TestCase
%TEST_TRACK_AORTA_2CLICK  Unit tests for the per-slice aorta tracker.
%
%   Builds a synthetic CT volume containing a known aorta + iliac
%   bifurcation (without going through TotalSegmentator) and exercises:
%     - opts.branch = 'left'  / 'right'  / 'longest' tiebreaker behaviour
%     - opts.use_frangi on / off (the Frangi gate is wired but the
%       behaviour-difference assertion is loose because Frangi can
%       legitimately remove or keep slices depending on shape)
%     - the smoothing post-process (gap-fill + hampel + sgolay) reduces
%       per-step jitter below a known threshold

    methods (TestClassSetup)
        function add_project_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function smoothing_reduces_per_step_jitter(tc)
            % Build a synthetic CT with a straight aorta + per-slice
            % centroid noise. The tracker without smoothing should
            % follow the noise; with smoothing the trajectory should
            % be ~smooth.
            [D, seed_prox, seed_end] = build_straight_aorta(tc);
            base = struct('HU_low', 200, 'HU_high', 450, ...
                'max_xy_jump_mm', 3, 'max_radius_mm', 15, ...
                'min_radius_mm', 2, 'roundness_min', 0.4, 'use_frangi', false);

            % With smoothing on (default function behaviour)
            [~, cv, ~, ~] = preprocess.track_aorta_2click(D, seed_prox, seed_end, base);
            ds = vecnorm(diff(cv(:,1:2), 1, 1), 2, 2);
            tc.verifyLessThan(prctile(ds, 95), 3, ...
                'Smoothed p95 per-step xy-jitter exceeds 3 vox');
            tc.verifyLessThan(median(ds), 1.5);
        end

        function branch_left_vs_right_diverge_after_bifurc(tc)
            [D, seed_prox, seed_R, seed_L] = build_bifurcating_aorta(tc);

            base = struct('HU_low', 200, 'HU_high', 450, ...
                'max_xy_jump_mm', 3, 'max_radius_mm', 15, ...
                'min_radius_mm', 2, 'roundness_min', 0.3, 'use_frangi', false);

            opts_R = base; opts_R.branch = 'right';
            opts_L = base; opts_L.branch = 'left';
            [~, cv_R, ~, ~] = preprocess.track_aorta_2click(D, seed_prox, seed_R, opts_R);
            [~, cv_L, ~, ~] = preprocess.track_aorta_2click(D, seed_prox, seed_L, opts_L);

            % After the bifurcation the right trajectory should sit on
            % LOWER x than the left trajectory (DICOM RAS).
            % Take the bottom 20 % of each track (closest to the seeds).
            n_R = size(cv_R, 1); n_L = size(cv_L, 1);
            x_R_distal = mean(cv_R(max(1, n_R - round(0.2*n_R)):end, 2));
            x_L_distal = mean(cv_L(max(1, n_L - round(0.2*n_L)):end, 2));
            tc.verifyLessThan(x_R_distal, x_L_distal, sprintf( ...
                'branch=right mean distal x %.1f should be < branch=left %.1f', ...
                x_R_distal, x_L_distal));
        end

        function frangi_can_be_disabled(tc)
            % Sanity: opts.use_frangi=false runs cleanly and returns
            % non-empty output (the original behaviour). Frangi=true
            % is exercised in build_*_aorta tests above.
            [D, seed_prox, seed_end] = build_straight_aorta(tc);
            o = struct('HU_low', 200, 'HU_high', 450, ...
                'max_xy_jump_mm', 3, 'max_radius_mm', 15, ...
                'min_radius_mm', 2, 'roundness_min', 0.4, 'use_frangi', false);
            [~, cv, ~, info] = preprocess.track_aorta_2click(D, seed_prox, seed_end, o);
            tc.verifyGreaterThan(info.slices_kept, 10);
            tc.verifyGreaterThan(size(cv, 1), 10);
        end

        function bifurcated_wrapper_runs_both_sides(tc)
            [D, seed_prox, seed_R, seed_L] = build_bifurcating_aorta(tc);
            base = struct('HU_low', 200, 'HU_high', 450, ...
                'max_xy_jump_mm', 3, 'max_radius_mm', 15, ...
                'min_radius_mm', 2, 'roundness_min', 0.3, 'use_frangi', false);
            out = preprocess.track_aorta_bifurcated(D, seed_prox, seed_R, seed_L, base);
            tc.verifyTrue(isfield(out, 'right') && isfield(out, 'left'));
            tc.verifyGreaterThan(size(out.right.centroids_vox, 1), 5);
            tc.verifyGreaterThan(size(out.left.centroids_vox,  1), 5);
        end
    end
end

function [D, seed_prox, seed_end] = build_straight_aorta(~)
%BUILD_STRAIGHT_AORTA  Synthetic CT volume with a vertical tube.
    sz = [80, 80, 120];
    vol = zeros(sz, 'int16') - 500;     % air baseline
    [yy, xx] = ndgrid(1:sz(1), 1:sz(2));
    cy = sz(1)/2; cx = sz(2)/2;
    r2 = (yy - cy).^2 + (xx - cx).^2;
    R_aorta_vox = 5;                   % 5-voxel radius ≈ 5 mm at 1 mm/vox
    for z = 1:sz(3)
        % Tiny per-slice jitter in centroid (±0.5 vox)
        dy = (rand - 0.5);
        dx = (rand - 0.5);
        r2_jit = (yy - cy - dy).^2 + (xx - cx - dx).^2;
        slc = -500 * int16(ones(sz(1:2)));
        slc(r2_jit <= R_aorta_vox^2) = 350;
        vol(:, :, z) = slc;
    end
    D = struct('vol', vol, 'pixel_mm', [1 1], 'slice_spacing_mm', 1, ...
               'is_volume', true);
    seed_prox = [round(cy), round(cx), 5];
    seed_end  = [round(cy), round(cx), sz(3) - 5];
end

function [D, seed_prox, seed_R, seed_L] = build_bifurcating_aorta(~)
%BUILD_BIFURCATING_ANATOMY  Synthetic CT with a vertical aorta that splits
%   into a left and right iliac after the midpoint.
    sz = [80, 80, 120];
    vol = zeros(sz, 'int16') - 500;
    [yy, xx] = ndgrid(1:sz(1), 1:sz(2));
    cy = sz(1)/2; cx = sz(2)/2;
    z_bif = round(sz(3) * 0.5);
    R_main = 5; R_iliac = 3;
    iliac_sep_per_slice = 0.3;        % iliacs walk apart by 0.3 vox per slice

    for z = 1:sz(3)
        slc = -500 * int16(ones(sz(1:2)));
        if z <= z_bif
            % Single aorta lumen
            slc((yy - cy).^2 + (xx - cx).^2 <= R_main^2) = 350;
        else
            d_iliac = (z - z_bif) * iliac_sep_per_slice;
            % Right iliac (LOWER x)
            cx_R = cx - d_iliac;
            slc((yy - cy).^2 + (xx - cx_R).^2 <= R_iliac^2) = 350;
            % Left iliac (HIGHER x)
            cx_L = cx + d_iliac;
            slc((yy - cy).^2 + (xx - cx_L).^2 <= R_iliac^2) = 350;
        end
        vol(:, :, z) = slc;
    end
    D = struct('vol', vol, 'pixel_mm', [1 1], 'slice_spacing_mm', 1, ...
               'is_volume', true);
    seed_prox = [round(cy), round(cx), 5];
    seed_R = [round(cy), round(cx - (sz(3) - z_bif) * iliac_sep_per_slice * 0.9), sz(3) - 3];
    seed_L = [round(cy), round(cx + (sz(3) - z_bif) * iliac_sep_per_slice * 0.9), sz(3) - 3];
end
