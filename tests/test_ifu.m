classdef test_ifu < matlab.unittest.TestCase
%TEST_IFU  Unit tests for the +ifu device library and matching logic.

    methods (TestClassSetup)
        function add_project_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function devices_have_required_fields(tc)
            db = ifu.devices();
            tc.verifyGreaterThanOrEqual(numel(db), 3, 'expected at least 3 catalogued devices');
            required = {'name','manufacturer','body_design', ...
                'neck_diameter_mm','neck_length_min_mm','neck_angulation_max_deg', ...
                'iliac_diameter_mm','iliac_length_min_mm', ...
                'iliac_bifurc_angle_max_deg', ...
                'source','last_verified','notes'};
            for k = 1:numel(db)
                for f = required
                    tc.verifyTrue(isfield(db(k), f{1}), ...
                        sprintf('device %d (%s) missing field %s', k, db(k).name, f{1}));
                end
                tc.verifyEqual(numel(db(k).neck_diameter_mm), 2, 'neck Ø range must be [min max]');
                tc.verifyLessThan(db(k).neck_diameter_mm(1), db(k).neck_diameter_mm(2));
                tc.verifyEqual(numel(db(k).iliac_diameter_mm), 2);
                tc.verifyLessThan(db(k).iliac_diameter_mm(1), db(k).iliac_diameter_mm(2));
                tc.verifyNotEmpty(db(k).source);
            end
        end

        function eligibility_marks_inside_range_as_eligible(tc)
            db = ifu.devices();
            for k = 1:numel(db)
                d = db(k);
                meas = struct( ...
                    'neck_diameter_mm', mean(d.neck_diameter_mm), ...
                    'neck_length_mm',   d.neck_length_min_mm + 5, ...
                    'neck_angulation_deg', d.neck_angulation_max_deg - 5, ...
                    'iliac_R_diameter_mm', mean(d.iliac_diameter_mm), ...
                    'iliac_L_diameter_mm', mean(d.iliac_diameter_mm), ...
                    'iliac_R_length_mm', d.iliac_length_min_mm + 5, ...
                    'iliac_L_length_mm', d.iliac_length_min_mm + 5);
                r = ifu.check_eligibility(meas, d);
                tc.verifyTrue(r.eligible, sprintf( ...
                    'Device %s should be eligible for mid-range measurements but failed: %s', ...
                    d.name, strjoin(r.fail_reasons, '; ')));
                tc.verifyGreaterThan(r.min_margin, 0);
            end
        end

        function eligibility_flags_each_violation_type(tc)
            db = ifu.devices();
            d = db(1);
            % Too-wide neck
            m = base_measurement(d);
            m.neck_diameter_mm = d.neck_diameter_mm(2) + 5;
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible);
            tc.verifyTrue(contains(strjoin(r.fail_reasons), 'neck Ø'));

            % Too-short neck
            m = base_measurement(d);
            m.neck_length_mm = d.neck_length_min_mm - 2;
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible);
            tc.verifyTrue(contains(strjoin(r.fail_reasons), 'neck length'));

            % Too-angled neck
            m = base_measurement(d);
            m.neck_angulation_deg = d.neck_angulation_max_deg + 10;
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible);
            tc.verifyTrue(contains(strjoin(r.fail_reasons), 'angulation'));

            % Too-small iliac
            m = base_measurement(d);
            m.iliac_L_diameter_mm = d.iliac_diameter_mm(1) - 2;
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible);
        end

        function nan_measurements_are_ignored(tc)
            d = ifu.devices();
            d = d(1);
            m = base_measurement(d);
            m.neck_angulation_deg = NaN;  % unmeasured
            r = ifu.check_eligibility(m, d);
            tc.verifyTrue(r.eligible, ...
                'NaN-measured criterion should be skipped, not failed');
            tc.verifyFalse(isfield(r.margins, 'neck_angulation_deg_unmeasured'));
        end

        function vacuous_eligibility_is_indeterminate_not_eligible(tc)
            % sizing-3: an all-NaN measurement set (failed centerline)
            % must NOT be reported eligible — that would be a confident
            % recommendation with no anatomic basis.
            d = ifu.devices(); d = d(1);
            m = struct('neck_diameter_mm', NaN, 'neck_length_mm', NaN, ...
                'neck_angulation_deg', NaN, 'iliac_R_diameter_mm', NaN, ...
                'iliac_L_diameter_mm', NaN, 'iliac_R_length_mm', NaN, ...
                'iliac_L_length_mm', NaN);
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible, 'all-NaN measurements must not be eligible');
            tc.verifyTrue(r.indeterminate);
            tc.verifyNotEmpty(r.missing_core);
            % match_devices with only_eligible must return none
            ranked = ifu.match_devices(m, struct('only_eligible', true));
            tc.verifyEmpty(ranked);
        end

        function missing_one_core_field_is_indeterminate(tc)
            % Dropping a single core diameter is enough to make a device
            % indeterminate (we can't establish the seal).
            d = ifu.devices(); d = d(1);
            m = base_measurement(d);
            m.iliac_R_diameter_mm = NaN;
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible);
            tc.verifyTrue(r.indeterminate);
            tc.verifyTrue(any(strcmp(r.missing_core, 'iliac_R_diameter_mm')));
        end

        function match_devices_sorts_eligible_first(tc)
            db = ifu.devices();
            % Pick a measurement on the very edge of one device's range
            d1 = db(1);
            m = base_measurement(d1);
            m.neck_diameter_mm = d1.neck_diameter_mm(2) - 0.5;  % small margin

            ranked = ifu.match_devices(m);
            tc.verifyEqual(numel(ranked), numel(db));
            % Margin should be monotonically non-increasing among eligible
            % devices (best fit first)
            elig = arrayfun(@(d) d.eligibility.eligible, ranked);
            elig_margins = arrayfun(@(d) d.eligibility.min_margin, ranked(elig));
            tc.verifyTrue(all(diff(elig_margins) <= 0), ...
                'Eligible devices not sorted by descending margin');
        end

        function only_eligible_filter_works(tc)
            % All devices ineligible -> empty
            m = struct('neck_diameter_mm', 5, 'neck_length_mm', 1, ...
                'neck_angulation_deg', 90, 'iliac_R_diameter_mm', 2, ...
                'iliac_L_diameter_mm', 2, 'iliac_R_length_mm', 1, 'iliac_L_length_mm', 1);
            ranked = ifu.match_devices(m, struct('only_eligible', true));
            tc.verifyEmpty(ranked);
        end

        function hostile_short_neck_prefers_ovation(tc)
            % Short-neck hostile case (8 mm) — only the Ovation iX
            % (≥ 7 mm threshold) should still be eligible. Every other
            % device requires ≥ 10-15 mm neck length.
            db = ifu.devices();
            m = struct( ...
                'neck_diameter_mm',  22, ...
                'neck_length_mm',     8, ...     % hostile short
                'neck_angulation_deg', 30, ...
                'iliac_R_diameter_mm', 12, ...
                'iliac_L_diameter_mm', 12, ...
                'iliac_R_length_mm', 50, ...
                'iliac_L_length_mm', 50);
            ranked = ifu.match_devices(m);
            elig_names = {};
            for k = 1:numel(ranked)
                if ranked(k).eligibility.eligible
                    elig_names{end+1} = ranked(k).name; %#ok<AGROW>
                end
            end
            tc.verifyTrue(any(strcmp(elig_names, 'Ovation iX')), ...
                sprintf('Ovation iX should be eligible at neck length 8 mm; eligible: %s', ...
                    strjoin(elig_names, ', ')));
            tc.verifyEqual(numel(elig_names), 1, ...
                'Only Ovation iX should pass at neck length 8 mm');
        end

        function severe_angulation_prefers_conformable(tc)
            % 80° neck angulation — only the Excluder Conformable (C3,
            % ≤ 90°) should pass. Standard Excluder and all others top
            % out at 60° in the library.
            m = struct( ...
                'neck_diameter_mm',  22, ...
                'neck_length_mm',    20, ...
                'neck_angulation_deg', 80, ...    % hostile angulation
                'iliac_R_diameter_mm', 12, ...
                'iliac_L_diameter_mm', 12, ...
                'iliac_R_length_mm', 50, ...
                'iliac_L_length_mm', 50);
            ranked = ifu.match_devices(m);
            elig_names = {};
            for k = 1:numel(ranked)
                if ranked(k).eligibility.eligible
                    elig_names{end+1} = ranked(k).name; %#ok<AGROW>
                end
            end
            tc.verifyTrue(any(contains(elig_names, 'Conformable')), ...
                sprintf('Excluder Conformable (C3) should be eligible at 80° angulation; eligible: %s', ...
                    strjoin(elig_names, ', ')));
        end

        function bifurc_angle_constraint_skipped_when_device_has_nan(tc)
            % All catalogued devices default to NaN for the bifurc-angle
            % slot. With a wildly wide patient bifurc angle (150°),
            % eligibility should still pass (constraint absent).
            db = ifu.devices();
            for k = 1:numel(db)
                d = db(k);
                m = base_measurement(d);
                m.bifurcation_angle_deg = 150;  % deliberately hostile
                r = ifu.check_eligibility(m, d);
                tc.verifyTrue(r.eligible, sprintf( ...
                    '%s should be eligible — its IFU has no bifurc-angle constraint (NaN)', d.name));
                tc.verifyFalse(isfield(r.margins, 'iliac_bifurc_angle_deg'), ...
                    'No margin should be reported when device constraint is NaN');
            end
        end

        function bifurc_angle_constraint_fires_when_device_populated(tc)
            % Synthesize a device with a 70° bifurc-angle ceiling and
            % verify a 90° patient angle fails on that constraint.
            db = ifu.devices();
            d = db(1);
            d.iliac_bifurc_angle_max_deg = 70;
            m = base_measurement(d);
            m.bifurcation_angle_deg = 90;
            r = ifu.check_eligibility(m, d);
            tc.verifyFalse(r.eligible, 'Expected fail: 90° > 70° device max');
            tc.verifyTrue(any(contains(r.fail_reasons, 'bifurc angle')), ...
                sprintf('Expected fail_reasons to mention bifurc angle; got: %s', ...
                    strjoin(r.fail_reasons, ' | ')));
            tc.verifyTrue(isfield(r.margins, 'iliac_bifurc_angle_deg'));
            tc.verifyEqual(r.margins.iliac_bifurc_angle_deg, -20, 'AbsTol', 1e-9);
            % Margin -20 should be the binding (smallest) margin
            tc.verifyEqual(r.binding, 'iliac_bifurc_angle_deg');
        end
    end
end

function m = base_measurement(d)
    m = struct( ...
        'neck_diameter_mm', mean(d.neck_diameter_mm), ...
        'neck_length_mm',   d.neck_length_min_mm + 5, ...
        'neck_angulation_deg', d.neck_angulation_max_deg - 5, ...
        'iliac_R_diameter_mm', mean(d.iliac_diameter_mm), ...
        'iliac_L_diameter_mm', mean(d.iliac_diameter_mm), ...
        'iliac_R_length_mm', d.iliac_length_min_mm + 5, ...
        'iliac_L_length_mm', d.iliac_length_min_mm + 5);
end
