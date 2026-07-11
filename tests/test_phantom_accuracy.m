classdef test_phantom_accuracy < matlab.unittest.TestCase
%TEST_PHANTOM_ACCURACY  Continuous-integration accuracy benchmark.
%   The AAA phantom (`+phantom/build_aaa_male.m`) is a procedurally-built
%   synthetic CT with EXACT ground-truth dimensions baked into the
%   builder. We ship `library/PHANTOM_aaa_male.ref.json` with those
%   values; this test runs the planner on the phantom and verifies the
%   recovered measurements match within a tolerance.
%
%   This is the first "real" accuracy test for goal #5 — it doesn't
%   require any TeraRecon data; the phantom IS the ground truth.

    methods (TestClassSetup)
        function add_paths(tc)
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
            addpath(fullfile(proj, 'scripts'));
            ref_path = fullfile(proj, 'library', 'PHANTOM_aaa_male.ref.json');
            tc.assumeTrue(isfile(ref_path), 'Phantom reference JSON missing');
            tc.assumeTrue(isfile(fullfile(proj, 'library', 'PHANTOM_aaa_male.mat')), ...
                'AAA phantom .mat missing');
        end
    end

    methods (Test)
        function reference_json_loads_with_expected_values(tc)
            proj = fileparts(fileparts(mfilename('fullpath')));
            ref = reference.load(fullfile(proj, 'library', 'PHANTOM_aaa_male.ref.json'));
            tc.verifyEqual(ref.case_name, 'PHANTOM_aaa_male');
            tc.verifyEqual(ref.measurements.neck_diameter_mm, 27.0);
            tc.verifyEqual(ref.measurements.neck_length_mm, 25.0);
            tc.verifyEqual(ref.measurements.neck_angulation_deg, 20.0);
            tc.verifyEqual(ref.measurements.iliac_R_diameter_mm, 9.0);
            tc.verifyEqual(ref.measurements.aneurysm_max_diameter_mm, 60.0);
            tc.verifyEqual(ref.measurements.bifurcation_angle_deg, 36.0);
        end

        function planner_recovers_bifurcation_angle(tc)
            % Verify the new bifurcation_angle_deg measurement recovers
            % the procedurally-baked 36° from the AAA phantom.
            proj = fileparts(fileparts(mfilename('fullpath')));
            S = load(fullfile(proj, 'library', 'PHANTOM_aaa_male.mat'));
            tc.assumeTrue(isfield(S, 'Pv_mm_right') && isfield(S, 'R_mm_right'), ...
                'Phantom mat missing centerline');
            planner_result = struct( ...
                'Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                'Pv_mm_left',  S.Pv_mm_left,  'R_mm_left',  S.R_mm_left, ...
                'arc_R_mm', sum(vecnorm(diff(S.Pv_mm_right,1,1),2,2)), ...
                'arc_L_mm', sum(vecnorm(diff(S.Pv_mm_left, 1,1),2,2)));
            meas = evar_plan.measure_from_centerline(planner_result, struct());
            tc.verifyTrue(isfield(meas, 'bifurcation_angle_deg'), ...
                'measure_from_centerline must emit bifurcation_angle_deg');
            tc.verifyFalse(isnan(meas.bifurcation_angle_deg), ...
                'bifurcation_angle_deg is NaN on phantom');
            tc.verifyGreaterThanOrEqual(meas.bifurcation_angle_deg, 0);
            tc.verifyLessThanOrEqual(meas.bifurcation_angle_deg, 180);
            % Tolerance ±3° — the phantom's iliac trunks come off the
            % bifurc at exactly 18° each side (= 36° total), but the
            % discrete polyline tangent at 20 mm distal can drift a
            % degree or two.
            tc.verifyEqual(meas.bifurcation_angle_deg, 36.0, 'AbsTol', 3, ...
                sprintf('Recovered bifurc angle = %.2f°, ground truth = 36° (tol ±3°)', ...
                    meas.bifurcation_angle_deg));
        end

        function planner_recovers_aneurysm_diameter_within_tolerance(tc)
            % Load the phantom + its ground-truth mask + centerline, run
            % the sizing pass, and verify the peak aneurysm radius is
            % within a few mm of the 30 mm built-in value. This is the
            % easiest measurement to verify because the phantom's
            % aneurysm is a clean parametric bulge.
            proj = fileparts(fileparts(mfilename('fullpath')));
            S = load(fullfile(proj, 'library', 'PHANTOM_aaa_male.mat'));
            % The phantom .mat has Pv_mm_right, R_mm_right etc. directly.
            tc.assumeTrue(isfield(S, 'Pv_mm_right') && isfield(S, 'R_mm_right'), ...
                'Phantom mat missing centerline');

            planner_result = struct( ...
                'Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                'Pv_mm_left',  S.Pv_mm_left,  'R_mm_left',  S.R_mm_left, ...
                'arc_R_mm', sum(vecnorm(diff(S.Pv_mm_right,1,1),2,2)), ...
                'arc_L_mm', sum(vecnorm(diff(S.Pv_mm_left, 1,1),2,2)));
            plan = evar_plan.generate_plan(planner_result, ...
                struct('verbose', false, 'write_file', ''));

            ref = reference.load(fullfile(proj, 'library', 'PHANTOM_aaa_male.ref.json'));
            ref_aneurysm_R = ref.measurements.aneurysm_max_diameter_mm / 2;

            % Tolerance ±5 mm — the per-slice radius profile peaks at the
            % built-in 30 mm, but the centerline node spacing + radius
            % smoother can push the recovered value a few mm off.
            tc.verifyEqual(plan.measurements.max_aneurysm_R_mm, ...
                ref_aneurysm_R, 'AbsTol', 5, ...
                sprintf('Recovered aneurysm R = %.1f mm, ground-truth = %.1f mm (tolerance ±5 mm)', ...
                    plan.measurements.max_aneurysm_R_mm, ref_aneurysm_R));
        end

        function normal_phantom_neck_diameter_in_aorta_not_iliac(tc)
            % The normal-male phantom has no aneurysm; the proximal
            % aorta is 25 mm Ø tapering to 18 mm Ø at the bifurcation.
            % The planner's no-aneurysm fallback should report a neck
            % diameter in the aortic range (~20-25 mm) — NOT the iliac
            % diameter (~12 mm). Loose ±5 mm tolerance because the
            % algorithm averages over a 30-mm window that includes the
            % tapering segment.
            proj = fileparts(fileparts(mfilename('fullpath')));
            mat_path = fullfile(proj, 'library', 'PHANTOM_normal_male.mat');
            tc.assumeTrue(isfile(mat_path), 'Normal phantom not present');
            S = load(mat_path);
            pr = struct('Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                'Pv_mm_left', S.Pv_mm_left, 'R_mm_left', S.R_mm_left);
            plan = evar_plan.generate_plan(pr, struct('verbose', false, 'write_file', ''));
            tc.verifyGreaterThan(plan.measurements.neck_diameter_mm, 17, ...
                sprintf('Normal-phantom neck Ø = %.1f mm; should be in the aortic range (≥ 17 mm), not iliac', ...
                    plan.measurements.neck_diameter_mm));
            tc.verifyLessThan(plan.measurements.neck_diameter_mm, 28);
        end

        function normal_phantom_recovers_iliac_diameter(tc)
            % The normal-male phantom has no aneurysm. Verify the iliac
            % diameter is recovered within ±3 mm of the ground truth
            % (12 mm). Use ±3 because the planner's CIA sampling window
            % can drift a couple mm into the smaller EIA on the normal
            % phantom (CIAs aren't drastically narrower than EIAs there).
            proj = fileparts(fileparts(mfilename('fullpath')));
            ref_path = fullfile(proj, 'library', 'PHANTOM_normal_male.ref.json');
            mat_path = fullfile(proj, 'library', 'PHANTOM_normal_male.mat');
            tc.assumeTrue(isfile(ref_path) && isfile(mat_path), ...
                'Normal phantom + reference JSON not present');
            S = load(mat_path);
            ref = reference.load(ref_path);
            pr = struct('Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                'Pv_mm_left', S.Pv_mm_left, 'R_mm_left', S.R_mm_left, ...
                'arc_R_mm', sum(vecnorm(diff(S.Pv_mm_right,1,1),2,2)), ...
                'arc_L_mm', sum(vecnorm(diff(S.Pv_mm_left, 1,1),2,2)));
            plan = evar_plan.generate_plan(pr, struct('verbose', false, 'write_file', ''));
            tc.verifyEqual(plan.measurements.iliac_R_diameter_mm, ...
                ref.measurements.iliac_R_diameter_mm, 'AbsTol', 3);
            tc.verifyEqual(plan.measurements.iliac_L_diameter_mm, ...
                ref.measurements.iliac_L_diameter_mm, 'AbsTol', 3);
        end

        function planner_recovers_neck_diameter_within_tolerance(tc)
            proj = fileparts(fileparts(mfilename('fullpath')));
            S = load(fullfile(proj, 'library', 'PHANTOM_aaa_male.mat'));
            planner_result = struct( ...
                'Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                'Pv_mm_left',  S.Pv_mm_left,  'R_mm_left',  S.R_mm_left, ...
                'arc_R_mm', sum(vecnorm(diff(S.Pv_mm_right,1,1),2,2)), ...
                'arc_L_mm', sum(vecnorm(diff(S.Pv_mm_left, 1,1),2,2)));
            plan = evar_plan.generate_plan(planner_result, ...
                struct('verbose', false, 'write_file', ''));

            ref = reference.load(fullfile(proj, 'library', 'PHANTOM_aaa_male.ref.json'));
            % ±5 mm tolerance on neck diameter — the proximal-neck
            % detection looks at the radius minimum in the upper portion
            % of the centerline, which can land slightly above or below
            % the geometric "neck" depending on how the centerline
            % samples the contour transition.
            tc.verifyEqual(plan.measurements.neck_diameter_mm, ...
                ref.measurements.neck_diameter_mm, 'AbsTol', 5, ...
                sprintf('Recovered neck Ø = %.1f mm, ground-truth = %.1f mm', ...
                    plan.measurements.neck_diameter_mm, ref.measurements.neck_diameter_mm));
        end
    end
end
