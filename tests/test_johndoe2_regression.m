classdef test_johndoe2_regression < matlab.unittest.TestCase
%TEST_JOHNDOE2_REGRESSION  Lock in the JohnDoe2 case as a real-anatomy
%   regression gate.
%
%   The JohnDoe2 EVAR case is the first out-of-cohort real CT the
%   planner runs on (Siemens SOMATOM Drive, 868 slices, contrast-
%   enhanced; closed 2026-05-18-late). The previous session saved the
%   end-to-end planner result to
%   `results/logs/johndoe2_pass1/planner_result.mat`. This test loads
%   that cached result and re-runs `evar_plan.measure_from_centerline`
%   on the polylines + radii. Verifies:
%     - existing sizing measurements match the cached plan to ±0.5 mm
%       / ±0.5° tolerance (= floating-point drift only; any larger
%       delta would indicate a real change in measure_from_centerline);
%     - the new `aneurysm_max_diameter_mm` field is populated and
%       equals 2 × `max_aneurysm_R_mm` exactly;
%     - the new `bifurcation_angle_deg` field is in [0, 180] and not NaN.
%
%   Skipped via assumeTrue when the cached planner result isn't on
%   disk (e.g. fresh checkout without local case data).

    properties (Access = private)
        proj
        pr
        saved_plan
    end

    methods (TestClassSetup)
        function load_fixture(tc)
            here = fileparts(mfilename('fullpath'));
            tc.proj = fileparts(here);
            addpath(tc.proj);
            cached = fullfile(tc.proj, 'results', 'logs', ...
                'johndoe2_pass1', 'planner_result.mat');
            tc.assumeTrue(isfile(cached), ...
                'JohnDoe2 planner_result.mat not present — skipping case-level regression');
            S = load(cached);
            tc.assumeTrue(isfield(S, 'out'), 'Cached file does not wrap planner result in `out`');
            tc.pr = S.out;
            tc.assumeTrue(isfield(tc.pr, 'Pv_mm_right') && isfield(tc.pr, 'plan'), ...
                'Cached planner_result missing polylines or plan');
            tc.saved_plan = tc.pr.plan.measurements;
        end
    end

    methods (Test)
        function existing_measurements_stable_to_drift_tolerance(tc)
            % Recompute measurements with today's code and compare to
            % the cached plan. We're allowing ±0.5 mm / ±0.5° drift —
            % any larger delta is a real algorithmic change, not
            % floating-point noise.
            meas = evar_plan.measure_from_centerline(tc.pr, struct());
            cached = tc.saved_plan;
            % NOTE: neck_angulation_deg is intentionally excluded from the
            % byte-drift comparison — its DEFINITION changed this session
            % from the suprarenal-to-neck angle (alpha) to the infrarenal
            % neck-to-sac angle (beta) per the B1 decision, so the cached
            % baseline (alpha) is no longer the right reference. The new
            % alpha/beta contract is checked in neck_angulation_alpha_beta_contract
            % below; test_evar_plan covers the field semantics directly.
            fields = {'neck_diameter_mm', 'neck_length_mm', ...
                      'iliac_R_diameter_mm', ...
                      'iliac_R_length_mm', 'iliac_L_diameter_mm', ...
                      'iliac_L_length_mm', 'max_aneurysm_R_mm'};
            for k = 1:numel(fields)
                f = fields{k};
                if ~isfield(cached, f) || ~isfield(meas, f); continue; end
                if isnan(cached.(f)) || isnan(meas.(f)); continue; end
                tc.verifyEqual(meas.(f), cached.(f), 'AbsTol', 0.5, ...
                    sprintf('JohnDoe2 %s drifted: cached %.3f, today %.3f', ...
                        f, cached.(f), meas.(f)));
            end
        end

        function neck_angulation_alpha_beta_contract(tc)
            % B1: the engine now emits BOTH neck angles. neck_angulation_deg
            % is the canonical IFU angle and must equal the beta
            % (neck-to-sac) field. On JohnDoe2 an aneurysm is present, so
            % both angles should be finite and in [0,180].
            meas = evar_plan.measure_from_centerline(tc.pr, struct());
            tc.verifyTrue(isfield(meas, 'neck_angulation_alpha_deg'), ...
                'must emit neck_angulation_alpha_deg');
            tc.verifyTrue(isfield(meas, 'neck_angulation_beta_deg'), ...
                'must emit neck_angulation_beta_deg');
            tc.verifyEqual(meas.neck_angulation_deg, meas.neck_angulation_beta_deg, ...
                'neck_angulation_deg must equal the beta (neck-to-sac) angle');
            if meas.aneurysm_detected
                tc.verifyFalse(isnan(meas.neck_angulation_beta_deg));
                tc.verifyGreaterThanOrEqual(meas.neck_angulation_beta_deg, 0);
                tc.verifyLessThanOrEqual(meas.neck_angulation_beta_deg, 180);
            end
            tc.verifyEqual(meas.diameter_basis, 'lumen');
        end

        function new_aneurysm_max_diameter_field_consistent(tc)
            meas = evar_plan.measure_from_centerline(tc.pr, struct());
            tc.verifyTrue(isfield(meas, 'aneurysm_max_diameter_mm'), ...
                'measure_from_centerline must emit aneurysm_max_diameter_mm');
            tc.verifyFalse(isnan(meas.aneurysm_max_diameter_mm), ...
                'aneurysm_max_diameter_mm is NaN on JohnDoe2');
            tc.verifyEqual(meas.aneurysm_max_diameter_mm, ...
                2 * meas.max_aneurysm_R_mm, 'AbsTol', 1e-9, ...
                'aneurysm_max_diameter_mm must equal 2 × max_aneurysm_R_mm');
        end

        function bifurcation_angle_populated_and_in_range(tc)
            meas = evar_plan.measure_from_centerline(tc.pr, struct());
            tc.verifyTrue(isfield(meas, 'bifurcation_angle_deg'), ...
                'measure_from_centerline must emit bifurcation_angle_deg');
            tc.verifyFalse(isnan(meas.bifurcation_angle_deg), ...
                'bifurcation_angle_deg is NaN on JohnDoe2');
            tc.verifyGreaterThanOrEqual(meas.bifurcation_angle_deg, 0);
            tc.verifyLessThanOrEqual(meas.bifurcation_angle_deg, 180);
            % As of 2026-05-21 JohnDoe2 reads 28.0°. We allow ±5°
            % tolerance — anything larger flags a real algorithmic
            % change worth investigating.
            tc.verifyEqual(meas.bifurcation_angle_deg, 28.0, 'AbsTol', 5, ...
                sprintf('JohnDoe2 bifurc angle drifted: today %.2f° vs baseline 28°', ...
                    meas.bifurcation_angle_deg));
        end
    end
end
