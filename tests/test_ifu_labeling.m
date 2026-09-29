classdef test_ifu_labeling < matlab.unittest.TestCase
%TEST_IFU_LABELING  Pins the device catalog to the manufacturer / FDA
%   labeling verified on 2026-09-29 (sources in ifu.devices), and the
%   eligibility rules that labeling requires: suprarenal angle limits, the
%   Ovation short-neck angle rule, the AFX2 iliac angle, mm-only margin
%   ranking, and the lumen-vs-outer-wall caution.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    methods (TestClassSetup)
        function add_path(tc) %#ok<MANU>
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end

    methods (Test)

        function catalog_matches_verified_labeling(tc)
            d = dev('Excluder');
            tc.verifyEqual(d.neck_diameter_mm, [19 32]);
            tc.verifyEqual(d.iliac_diameter_mm, [8 25]);
            d = dev('Excluder Conformable');
            tc.verifyEqual(d.neck_diameter_mm, [16 32]);
            tc.verifyEqual(d.neck_length_min_mm, 10);
            tc.verifyEqual(d.neck_angulation_max_deg, 90);
            d = dev('AFX2');
            tc.verifyEqual(d.neck_diameter_mm, [18 32]);
            tc.verifyEqual(d.iliac_bifurc_angle_max_deg, 90);
            tc.verifyEqual(d.access_min_mm, 6.5);
            d = dev('Treo');
            tc.verifyEqual(d.neck_length_min_mm, 15);
            tc.verifyEqual(d.iliac_diameter_mm, [8 20]);
            tc.verifyEqual(d.suprarenal_angulation_max_deg, 45);
            d = dev('Ovation iX');
            tc.verifyEqual(d.iliac_diameter_mm, [8 20]);
            tc.verifyEqual(d.short_neck_angle_rule, [10 45]);
            d = dev('Zenith Flex');
            tc.verifyEqual(d.suprarenal_angulation_max_deg, 45);
            tc.verifyEqual(d.diameter_basis, 'outer');
            db = ifu.devices();
            tc.verifyFalse(any(contains({db.name}, 'C3')), ...
                'C3 is the Excluder delivery system, not a device name');
        end

        function treo_rejects_12mm_neck(tc)
            m = good_meas(); m.neck_length_mm = 12;
            r = ifu.check_eligibility(m, dev('Treo'));
            tc.verifyFalse(r.eligible);
            tc.verifyTrue(any(contains(r.fail_reasons, 'neck length')));
        end

        function ovation_short_neck_tightens_angle(tc)
            m = good_meas(); m.neck_length_mm = 8; m.neck_angulation_deg = 50;
            r = ifu.check_eligibility(m, dev('Ovation iX'));
            tc.verifyFalse(r.eligible, '8 mm neck at 50° exceeds Ovation''s 45° short-neck limit');
            m.neck_length_mm = 12;             % long enough: 60° limit applies
            r = ifu.check_eligibility(m, dev('Ovation iX'));
            tc.verifyTrue(r.eligible);
        end

        function suprarenal_angle_is_checked_where_labeled(tc)
            m = good_meas(); m.neck_angulation_alpha_deg = 50;
            tc.verifyFalse(ifu.check_eligibility(m, dev('Zenith Flex')).eligible);
            tc.verifyFalse(ifu.check_eligibility(m, dev('Treo')).eligible);
            tc.verifyTrue(ifu.check_eligibility(m, dev('Endurant II')).eligible, ...
                'Endurant has no suprarenal limit — alpha must not rule it out');
        end

        function afx2_iliac_angle_is_checked(tc)
            m = good_meas(); m.bifurcation_angle_deg = 100;
            tc.verifyFalse(ifu.check_eligibility(m, dev('AFX2')).eligible);
        end

        function margin_is_mm_only(tc)
            % An angle with a small (but passing) margin must not become the
            % "binding" constraint or shrink the mm ranking margin.
            m = good_meas(); m.neck_angulation_deg = 58;   % 2° inside a 60° limit
            r = ifu.check_eligibility(m, dev('Endurant II'));
            tc.verifyTrue(r.eligible);
            tc.verifyFalse(contains(r.binding, 'angul'));
            tc.verifyGreaterThan(r.min_margin, 2);
        end

        function outer_wall_basis_raises_caution(tc)
            m = good_meas(); m.neck_diameter_mm = 30;      % lumen, near Zenith 32 outer max
            r = ifu.check_eligibility(m, dev('Zenith Flex'));
            tc.verifyTrue(r.eligible);
            tc.verifyNotEmpty(r.cautions);
            r2 = ifu.check_eligibility(good_meas(), dev('Zenith Flex'));
            tc.verifyEmpty(r2.cautions);
        end

    end
end

% =========================================================================
function d = dev(name)
    db = ifu.devices();
    d = db(strcmp({db.name}, name));
    assert(numel(d) == 1, 'device %s not found', name);
end

function m = good_meas()
% Comfortably on-label for every device in the catalog.
    m = struct('neck_diameter_mm', 24, 'neck_length_mm', 25, ...
        'neck_angulation_deg', 20, 'neck_angulation_alpha_deg', 15, ...
        'iliac_R_diameter_mm', 12, 'iliac_L_diameter_mm', 12, ...
        'iliac_R_seal_length_mm', NaN, 'iliac_L_seal_length_mm', NaN, ...
        'bifurcation_angle_deg', 40, 'aneurysm_detected', true);
end
