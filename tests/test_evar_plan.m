classdef test_evar_plan < matlab.unittest.TestCase
%TEST_EVAR_PLAN  Unit tests for +evar_plan/measure_from_centerline and
%   +evar_plan/generate_plan (the sizing + IFU-matching + plan-writing
%   composition).

    methods (TestClassSetup)
        function add_project_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function find_bifurcation_locates_divergence_point(tc)
            % Two synthetic centerlines that share the first 50 mm of
            % arc then diverge at the bifurcation.
            n_shared = 50;
            shared = [zeros(n_shared,1), zeros(n_shared,1), (0:n_shared-1).'];
            right = [shared; [linspace(0, 30, 30).', linspace(0, -20, 30).', (n_shared:n_shared+29).']];
            left  = [shared; [linspace(0, 30, 30).', linspace(0,  20, 30).', (n_shared:n_shared+29).']];

            pr = struct('Pv_mm_right', right, 'R_mm_right', ones(size(right,1),1) * 5, ...
                        'Pv_mm_left',  left,  'R_mm_left',  ones(size(left,1),1)  * 5, ...
                        'arc_R_mm', n_shared + 30, 'arc_L_mm', n_shared + 30);
            meas = evar_plan.measure_from_centerline(pr);

            % Bifurcation detection finds the first arc where the two
            % polylines are > 5 mm apart, so for branches that diverge
            % at z = 50 mm at a rate of ~1 mm/slice the detector lands
            % around arc 55-60 mm. Allow a 15 mm window.
            tc.verifyGreaterThan(meas.diagnostic.bifurcation_arc_R_mm, 40);
            tc.verifyLessThan(meas.diagnostic.bifurcation_arc_R_mm, 65);
            tc.verifyGreaterThan(meas.diagnostic.bifurcation_arc_L_mm, 40);
            tc.verifyLessThan(meas.diagnostic.bifurcation_arc_L_mm, 65);
        end

        function measure_handles_no_aneurysm_centerline(tc)
            % Constant-radius centerline (no aneurysmal segment). The
            % function should not crash; with no aneurysm onset it must
            % flag aneurysm_detected=false and report neck length as NaN
            % (B3) — a length-to-bifurcation number would read as a real
            % infrarenal neck. The neck-to-sac angle (beta) is also NaN
            % (there is no sac to measure against).
            n = 200;
            Pv = [zeros(n,1), zeros(n,1), (0:n-1).' * 1];   % 200 mm vertical
            R  = ones(n, 1) * 5;                             % normal Ø 10 mm
            pr = struct('Pv_mm_right', Pv, 'R_mm_right', R, ...
                        'Pv_mm_left', Pv, 'R_mm_left', R, ...
                        'arc_R_mm', 200, 'arc_L_mm', 200);
            meas = evar_plan.measure_from_centerline(pr);
            tc.verifyFalse(meas.aneurysm_detected);
            tc.verifyTrue(isnan(meas.neck_length_mm));
            tc.verifyTrue(isnan(meas.neck_angulation_beta_deg));
            tc.verifyEqual(meas.max_aneurysm_R_mm, 5);
        end

        function measure_emits_alpha_beta_and_lumen_basis(tc)
            % An aneurysmal centerline must emit BOTH neck angles (alpha
            % suprarenal-to-neck + beta neck-to-sac), flag the aneurysm,
            % set neck_angulation_deg = beta (the IFU-canonical angle),
            % a finite neck length, and tag every diameter as lumen-based
            % (B1/B2/B3).
            n = 200;
            Pv = [zeros(n,1), zeros(n,1), (0:n-1).'];
            R = 11 * ones(n,1);
            R(30:60) = 8;                       % infrarenal neck
            R(60:120) = linspace(8, 18, 61);    % grows past 14 mm R = sac
            R(120:180) = 18;
            R(180:end) = linspace(18, 6, n-180+1).';
            pr = struct('Pv_mm_right', Pv, 'R_mm_right', R, ...
                        'Pv_mm_left',  Pv, 'R_mm_left',  R, ...
                        'arc_R_mm', 200, 'arc_L_mm', 200);
            meas = evar_plan.measure_from_centerline(pr);
            tc.verifyTrue(meas.aneurysm_detected);
            tc.verifyTrue(isfield(meas, 'neck_angulation_alpha_deg'));
            tc.verifyTrue(isfield(meas, 'neck_angulation_beta_deg'));
            tc.verifyEqual(meas.neck_angulation_deg, meas.neck_angulation_beta_deg);
            tc.verifyEqual(meas.diameter_basis, 'lumen');
            tc.verifyGreaterThanOrEqual(meas.neck_length_mm, 0);
        end

        function measure_neck_diameter_uses_seal_zone_not_dilating_span(tc)
            % Regression for the sizing-1/2 over-call: on a clean 16 mm
            % infrarenal neck (R=8) that ramps into an aneurysm, the
            % reported neck diameter must reflect the proximal SEAL ZONE
            % (~16 mm) — not an average taken through the dilating segment
            % up to the aneurysm onset (the old code over-called ~20 mm).
            n = 200;
            Pv = [zeros(n,1), zeros(n,1), (0:n-1).'];
            R = 11 * ones(n,1);
            R(30:60)   = 8;                      % 16 mm infrarenal neck
            R(60:120)  = linspace(8, 18, 61);    % dilates into the sac
            R(120:180) = 18;
            R(180:end) = linspace(18, 6, n-180+1).';
            pr = struct('Pv_mm_right', Pv, 'R_mm_right', R, ...
                        'Pv_mm_left',  Pv, 'R_mm_left',  R, ...
                        'arc_R_mm', 200, 'arc_L_mm', 200);
            meas = evar_plan.measure_from_centerline(pr);
            tc.verifyTrue(meas.aneurysm_detected);
            % True neck Ø = 16 mm; small tolerance for the seal-window mean.
            tc.verifyEqual(meas.neck_diameter_mm, 16, 'AbsTol', 1.5, ...
                sprintf('neck Ø %.1f mm should reflect the 16 mm seal zone, not the dilating span', ...
                    meas.neck_diameter_mm));
            % Explicitly guard against the old over-call (>= ~20 mm).
            tc.verifyLessThan(meas.neck_diameter_mm, 18, ...
                'neck Ø must not be inflated by averaging through the aneurysm');
        end

        function generate_plan_writes_txt_and_json(tc)
            % Use a generic eligible-for-all-devices measurement so the
            % plan recommends something; verify the .txt and .json
            % files exist and the JSON parses with the expected keys.
            n = 200;
            Pv = [zeros(n,1), zeros(n,1), (0:n-1).'];
            % Build R profile: supraceliac 11mm, neck 8mm, aneurysm 15mm
            R = 11 * ones(n,1);
            R(30:60) = 8;        % neck
            R(60:120) = linspace(8, 15, 61);  % aneurysm growing
            R(120:180) = 15;
            R(180:end) = linspace(15, 5, n-180+1).';
            pr = struct('Pv_mm_right', Pv, 'R_mm_right', R, ...
                        'Pv_mm_left',  Pv, 'R_mm_left',  R, ...
                        'arc_R_mm', 200, 'arc_L_mm', 200);

            tmp_stem = fullfile(tempname);
            plan = evar_plan.generate_plan(pr, struct( ...
                'verbose', false, 'write_file', tmp_stem));

            txt_path = [tmp_stem, '.txt'];
            json_path = [tmp_stem, '.json'];
            tc.verifyTrue(isfile(txt_path));
            tc.verifyTrue(isfile(json_path));

            % JSON parses
            j = jsondecode(fileread(json_path));
            tc.verifyTrue(isfield(j, 'measurements'));
            tc.verifyTrue(isfield(j, 'recommendation'));
            tc.verifyTrue(isfield(j, 'devices'));
            tc.verifyTrue(isfield(j, 'disclaimer'));
            tc.verifyTrue(contains(lower(j.disclaimer), 'research'));

            % .txt contains the device library used
            txt = fileread(txt_path);
            tc.verifyTrue(contains(txt, 'IFU sources cited'));

            % Clean up temp files
            delete(txt_path);
            delete(json_path);
        end

        function generate_plan_handles_no_eligible_device(tc)
            % Very narrow neck — under every device's IFU minimum. Plan
            % should run, recommendation should be empty, rationale
            % should list closest-to-eligible devices.
            n = 200;
            Pv = [zeros(n,1), zeros(n,1), (0:n-1).'];
            R = 5 * ones(n, 1);   % 10mm everywhere, no aneurysm
            R(30:60) = 4;          % tiny neck (8mm Ø)
            R(60:120) = linspace(4, 8, 61);
            R(120:end) = 8;
            pr = struct('Pv_mm_right', Pv, 'R_mm_right', R, ...
                        'Pv_mm_left',  Pv, 'R_mm_left',  R, ...
                        'arc_R_mm', 200, 'arc_L_mm', 200);
            plan = evar_plan.generate_plan(pr, struct( ...
                'verbose', false, 'write_file', ''));
            tc.verifyEqual(plan.recommendation, '');
            tc.verifyTrue(contains(plan.rationale, 'NO ON-LABEL'));
        end
    end
end
