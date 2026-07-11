classdef test_measurement_reproducibility < matlab.unittest.TestCase
%TEST_MEASUREMENT_REPRODUCIBILITY  Covers the aneurysm-onset hysteresis in
%   evar_plan.measure_from_centerline and the evar_plan.
%   measurement_reproducibility band (GOALS #35 B-iii: sizing must be
%   reproducible under resample/rotation for the publication's repro claim).

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

        function hysteresis_rejects_single_spike(tc)
            % A synthetic aorta with a LONE spuriously-wide slice inside the
            % infrarenal neck, then a genuine SUSTAINED aneurysm further
            % distal. With hysteresis (default) the onset must land on the
            % sustained sac, not the spike — so the neck is long. With
            % hysteresis disabled (min_run_mm = 0) the spike captures the
            % onset and the neck is short. The gap between the two proves
            % the hysteresis is doing the work.
            pr = tc.spiked_aorta();

            def  = evar_plan.measure_from_centerline(pr);
            noh  = evar_plan.measure_from_centerline(pr, struct('aneurysm_min_run_mm', 0));

            tc.verifyTrue(def.aneurysm_detected, 'sustained aneurysm should be detected');
            tc.verifyTrue(noh.aneurysm_detected, 'spike alone should register without hysteresis');

            % Default (hysteresis) neck reaches the sustained sac (~z=105),
            % skipping the spike at z=60; no-hysteresis stops at the spike.
            tc.verifyGreaterThan(def.neck_length_mm, 40, ...
                'hysteresis neck should reach the sustained aneurysm onset');
            tc.verifyLessThan(noh.neck_length_mm, 30, ...
                'no-hysteresis neck should stop at the spike');
            tc.verifyGreaterThan(def.neck_length_mm - noh.neck_length_mm, 20, ...
                'hysteresis must move the onset well past the spike');
        end

        function band_is_tight_on_aaa_phantom(tc)
            pr  = tc.aaa_phantom_pr();
            rep = evar_plan.measurement_reproducibility(pr, ...
                struct('n_trials', 24, 'verbose', false));

            % Baseline in the band must equal a direct measurement.
            direct = evar_plan.measure_from_centerline(pr);
            tc.verifyEqual(rep.baseline.neck_diameter_mm, direct.neck_diameter_mm, ...
                'AbsTol', 1e-9);

            % Structure contract.
            tc.verifyEqual(numel(rep.fields), 8);
            tc.verifyEqual(height(rep.table), 8);
            tc.verifyEqual(rep.n_valid.neck_diameter_mm, 24, ...
                'no trial should have failed on a clean phantom');

            % Reproducibility band: diameters ~invariant, neck length (the
            % onset-sensitive quantity) tight thanks to the hysteresis.
            tc.verifyLessThan(rep.std.neck_diameter_mm, 1.0);
            tc.verifyLessThan(rep.std.neck_length_mm,   3.0);
            tc.verifyLessThan(rep.std.neck_angulation_beta_deg, 2.0);
        end

        function rotation_only_is_invariant(tc)
            % With no resampling jitter, only a rigid rotation is applied.
            % Every measurement is rotation-invariant, so the spread must
            % be numerical-noise small — a guard against an orientation bug
            % sneaking into the measurement path.
            pr  = tc.aaa_phantom_pr();
            rep = evar_plan.measurement_reproducibility(pr, struct( ...
                'n_trials', 12, 'resample_frac', 0, 'max_rot_deg', 8, ...
                'verbose', false));

            tc.verifyLessThan(rep.std.neck_diameter_mm,        0.20);
            tc.verifyLessThan(rep.std.iliac_R_diameter_mm,     0.20);
            tc.verifyLessThan(rep.std.aneurysm_max_diameter_mm, 0.50);
            tc.verifyLessThan(rep.std.neck_angulation_beta_deg, 1.0);
        end

    end

    methods (Access = private)

        function pr = aaa_phantom_pr(tc)
            S = load(fullfile(tc.project_root, 'library', 'PHANTOM_aaa_male.mat'));
            arclen = @(P) sum(vecnorm(diff(P, 1, 1), 2, 2));
            pr = struct('Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                        'Pv_mm_left',  S.Pv_mm_left,  'R_mm_left',  S.R_mm_left, ...
                        'arc_R_mm', arclen(S.Pv_mm_right), 'arc_L_mm', arclen(S.Pv_mm_left));
        end

        function pr = spiked_aorta(~)
            % Straight 1-mm-spaced aorta (proximal z=0 -> distal), then a
            % bifurcation into two short iliacs. Radius profile: wide
            % supraceliac, 5 mm infrarenal neck, ONE 20 mm spike at z=60,
            % neck resumes, then a sustained sac ramping past 14 mm from
            % ~z=105. Iliacs taper to 4.5 mm (keeps proximal end fattest so
            % measure_from_centerline does not reverse the polyline).
            z = (0:200).';
            R = 11 * ones(size(z));
            R(z >= 40 & z < 100) = 5;                       % infrarenal neck
            R(z == 60) = 20;                                % lone spike
            ramp = z >= 100;
            R(ramp) = min(20, 12 + (z(ramp) - 100) * 0.4);  % sustained sac
            trunk = [zeros(numel(z), 1), zeros(numel(z), 1), z];

            zil = (201:230).';
            rilR = [ linspace(0, 20, numel(zil)).', zeros(numel(zil), 1), zil];
            lilR = [ linspace(0, -20, numel(zil)).', zeros(numel(zil), 1), zil];
            Ril = 4.5 * ones(numel(zil), 1);

            pr = struct( ...
                'Pv_mm_right', [trunk; rilR], 'R_mm_right', [R; Ril], ...
                'Pv_mm_left',  [trunk; lilR], 'R_mm_left',  [R; Ril]);
        end

    end
end
