classdef test_pipeline_phantom < matlab.unittest.TestCase
%TEST_PIPELINE_PHANTOM  Regression tests on the phantom library.
%
%   Each test case loads a synthetic phantom (with known ground truth
%   mask, centerline, and landmarks) and runs the auto-seed-detection
%   → skeleton → centerline pipeline. Tolerances are loose enough to
%   catch regressions but tight enough that anatomy-crossing bugs fail
%   loudly.
%
%   Note on phantom data:
%     The `Pv_mm_*` ground-truth centerlines in the shipped phantoms
%     extend past the mask FOV (last point at z = 310 mm but mask only
%     covers 0-224 mm). The auto pipeline operates on the mask voxels
%     only, so the CFA seeds it finds are at the mask's caudal edge,
%     NOT at the GT-centerline endpoint. Tests therefore verify
%     position WITHIN the mask, anatomic left/right consistency, and
%     clinical-plausibility ranges — not exact GT-centerline alignment.
%
%   Run via:
%     >> results = runtests('tests/test_pipeline_phantom.m')
%   or  >> runtests('tests')   to pick up every test under tests/

    properties (TestParameter)
        phantom_name = {'PHANTOM_normal_male', 'PHANTOM_aaa_male'};
    end

    properties (Access = private)
        project_root
    end

    methods (TestClassSetup)
        function add_project_path(tc)
            tc.project_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(tc.project_root);
        end
    end

    methods (Test)
        function auto_seeds_are_in_mask_and_LR_correct(tc, phantom_name)
            ph = load_phantom(tc, phantom_name);
            seeds = preprocess.auto_seeds_from_mask(ph.mask, ph.D);
            tc.verifyTrue(seeds.ok, ...
                'auto_seeds_from_mask did not produce all three seeds');

            % All three seeds must be inside (or within 2 voxels of) a
            % mask voxel — anatomically the seed sits in the lumen
            for f = ["proximal", "right_cfa", "left_cfa"]
                v = seeds.(f);
                in_mask = ph.mask(v(1), v(2), v(3));
                if ~in_mask
                    [yy,xx,zz] = ind2sub(size(ph.mask), find(ph.mask));
                    d = min(vecnorm([yy,xx,zz] - v, 2, 2));
                    tc.verifyLessThan(d, 2, sprintf( ...
                        '%s seed not in mask and %.1f voxels from nearest mask vox', f, d));
                end
            end

            % Proximal must be at the cranial half (top) of the mask
            z_pres = find(squeeze(any(any(ph.mask,1),2)));
            mid_z  = (z_pres(1) + z_pres(end)) / 2;
            tc.verifyLessThan(seeds.proximal(3), mid_z, ...
                'proximal seed should be in the cranial half of the mask');

            % CFA seeds must be in the caudal half
            tc.verifyGreaterThan(seeds.right_cfa(3), mid_z);
            tc.verifyGreaterThan(seeds.left_cfa(3),  mid_z);

            % Left/right convention: patient-right has LOWER x-column
            % index. The auto detector splits CCs at the volume midline.
            x_mid = size(ph.mask, 2) / 2;
            tc.verifyLessThanOrEqual(seeds.right_cfa(2), x_mid + 2, ...
                'right_cfa should be at lower x (patient-right side)');
            tc.verifyGreaterThanOrEqual(seeds.left_cfa(2), x_mid - 2, ...
                'left_cfa should be at higher x (patient-left side)');
        end

        function bifurcated_centerline_arc_is_clinical_ballpark(tc, phantom_name)
            ph = load_phantom(tc, phantom_name);
            seeds = preprocess.auto_seeds_from_mask(ph.mask, ph.D);
            tc.assumeTrue(seeds.ok);

            S = preprocess.build_skeleton_graph(ph.mask, ...
                struct('min_branch_length', 10, 'min_radius_vox', 0, ...
                       'radius_weight_pow', 2));
            [PvR_vox, RR_vox, ~] = preprocess.centerline_seeds( ...
                S, [seeds.proximal; seeds.right_cfa]);
            [PvL_vox, RL_vox, ~] = preprocess.centerline_seeds( ...
                S, [seeds.proximal; seeds.left_cfa]);
            [PvR_mm, RR_mm] = preprocess.centerline_to_mm(PvR_vox, RR_vox, ph.D);
            [PvL_mm, RL_mm] = preprocess.centerline_to_mm(PvL_vox, RL_vox, ph.D);
            arc_R = sum(vecnorm(diff(PvR_mm,1,1),2,2));
            arc_L = sum(vecnorm(diff(PvL_mm,1,1),2,2));

            % Both arcs should span the major axis of the phantom
            mask_z_mm = size(ph.mask,3) * ph.slice_spacing_mm;
            tc.verifyGreaterThan(arc_R, mask_z_mm * 0.5, ...
                'right arc < half of mask z-extent');
            tc.verifyLessThan(arc_R, mask_z_mm * 2.0, ...
                'right arc > 2x mask z-extent (centerline wandering)');
            tc.verifyGreaterThan(arc_L, mask_z_mm * 0.5);
            tc.verifyLessThan(arc_L, mask_z_mm * 2.0);

            % Radius median should be in vessel range
            tc.verifyGreaterThan(median(RR_mm), 1.5);
            tc.verifyLessThan(median(RR_mm), 15);
        end

        function centerline_stays_inside_the_mask(tc, phantom_name)
            ph = load_phantom(tc, phantom_name);
            seeds = preprocess.auto_seeds_from_mask(ph.mask, ph.D);
            tc.assumeTrue(seeds.ok);

            S = preprocess.build_skeleton_graph(ph.mask, ...
                struct('min_branch_length', 10, 'min_radius_vox', 0, ...
                       'radius_weight_pow', 2));
            [PvR_vox, ~, ~] = preprocess.centerline_seeds( ...
                S, [seeds.proximal; seeds.right_cfa]);

            % Every centerline node should be inside the mask or within
            % 2 voxels of it (the skeleton can be 1 voxel off the
            % boundary by construction).
            n_out = 0;
            for k = 1:size(PvR_vox,1)
                v = round(PvR_vox(k, :));
                v(1) = max(1, min(size(ph.mask,1), v(1)));
                v(2) = max(1, min(size(ph.mask,2), v(2)));
                v(3) = max(1, min(size(ph.mask,3), v(3)));
                if ~ph.mask(v(1), v(2), v(3))
                    n_out = n_out + 1;
                end
            end
            tc.verifyLessThan(n_out / size(PvR_vox,1), 0.05, sprintf( ...
                '%.0f%% of right-branch centerline nodes outside mask on %s', ...
                100 * n_out / size(PvR_vox,1), phantom_name));
        end

        function ifu_matching_runs_on_phantom_measurements(tc, phantom_name)
            ph = load_phantom(tc, phantom_name);
            seeds = preprocess.auto_seeds_from_mask(ph.mask, ph.D);
            tc.assumeTrue(seeds.ok);

            S = preprocess.build_skeleton_graph(ph.mask, ...
                struct('min_branch_length', 10, 'min_radius_vox', 0, ...
                       'radius_weight_pow', 2));
            [PvR_vox, RR_vox, ~] = preprocess.centerline_seeds( ...
                S, [seeds.proximal; seeds.right_cfa]);
            [PvL_vox, RL_vox, ~] = preprocess.centerline_seeds( ...
                S, [seeds.proximal; seeds.left_cfa]);
            [PvR_mm, RR_mm] = preprocess.centerline_to_mm(PvR_vox, RR_vox, ph.D);
            [PvL_mm, RL_mm] = preprocess.centerline_to_mm(PvL_vox, RL_vox, ph.D);
            planner_result = struct( ...
                'Pv_mm_right', PvR_mm, 'R_mm_right', RR_mm, ...
                'Pv_mm_left',  PvL_mm, 'R_mm_left',  RL_mm, ...
                'arc_R_mm',    sum(vecnorm(diff(PvR_mm,1,1),2,2)), ...
                'arc_L_mm',    sum(vecnorm(diff(PvL_mm,1,1),2,2)), ...
                'seeds', seeds);
            meas = evar_plan.measure_from_centerline(planner_result);

            % Neck diameter: clinically plausible aorta range
            tc.verifyGreaterThan(meas.neck_diameter_mm, 5);
            tc.verifyLessThan(meas.neck_diameter_mm, 50);
            % Neck length is >= 0 when an aneurysm is present, or NaN
            % (B3) on the non-aneurysmal normal phantom.
            tc.verifyTrue(isnan(meas.neck_length_mm) || meas.neck_length_mm >= 0);

            ranked = ifu.match_devices(meas);
            tc.verifyEqual(numel(ranked), numel(ifu.devices()));
            tc.verifyTrue(all(arrayfun(@(d) isfield(d, 'eligibility') && ...
                isfield(d.eligibility, 'eligible'), ranked)));
        end
    end
end

function ph = load_phantom(tc, name)
    path = fullfile(tc.project_root, 'library', [name, '.mat']);
    tc.assumeTrue(isfile(path), sprintf('phantom not found: %s', path));
    ph = load(path);
    ph.D = struct('pixel_mm', ph.pixel_mm, ...
                  'slice_spacing_mm', ph.slice_spacing_mm, ...
                  'is_volume', ph.is_volume);
end
