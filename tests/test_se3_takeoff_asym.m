classdef test_se3_takeoff_asym < matlab.unittest.TestCase
%TEST_SE3_TAKEOFF_ASYM  Pin the cross-vessel take-off-asymmetry block.
%   The bilateral take-off-asymmetry check requires the aorta
%   centerline as the 4th argument; without it the angles always
%   collapse to 0 (the fallback axis is symmetric in L and R by
%   construction). These tests verify both branches.

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function symmetric_iliac_pair_passes(tc)
            % Equal take-off angles on both sides — asymmetry block OK.
            Pv_aorta = [zeros(20, 1), zeros(20, 1), (0:5:95)'];
            ts = (0:5:50)';
            Pv_R = [0, 0, 95] + ts .* [ sind(30), 0, cosd(30)];
            Pv_L = [0, 0, 95] + ts .* [-sind(30), 0, cosd(30)];
            r = autoseg.se3_cross_vessel_check(Pv_R, Pv_L, struct(), Pv_aorta);
            b6 = r.blocks{6};   % take-off angles
            b7 = r.blocks{7};   % take-off asymmetry
            tc.verifyEqual(b6.severity, 0, 'Symmetric pair should pass take-off-angle range check.');
            tc.verifyEqual(b7.severity, 0, 'Symmetric pair should pass take-off-asymmetry check.');
        end

        function asymmetric_pair_warns_with_aorta(tc)
            % R 30°, L 60° — asymmetry 30° (above default 25° tol).
            Pv_aorta = [zeros(20, 1), zeros(20, 1), (0:5:95)'];
            ts = (0:5:50)';
            Pv_R = [0, 0, 95] + ts .* [ sind(30), 0, cosd(30)];
            Pv_L = [0, 0, 95] + ts .* [-sind(60), 0, cosd(60)];
            r = autoseg.se3_cross_vessel_check(Pv_R, Pv_L, struct(), Pv_aorta);
            b7 = r.blocks{7};
            tc.verifyGreaterThanOrEqual(b7.severity, 1, ...
                'Asymmetric pair should trigger WARN on take-off-asymmetry block.');
            tc.verifyTrue(contains(b7.findings{1}, 'aortic axis from aorta centerline'), ...
                'Diagnostic text should note the aorta centerline was used.');
        end

        function without_aorta_centerline_no_asymmetry_signal(tc)
            % Without Pv_aorta, the fallback axis is symmetric and the
            % block cannot measure asymmetry — but should NOT FAIL spuriously.
            ts = (0:5:50)';
            Pv_R = [0, 0, 95] + ts .* [ sind(30), 0, cosd(30)];
            Pv_L = [0, 0, 95] + ts .* [-sind(60), 0, cosd(60)];
            r = autoseg.se3_cross_vessel_check(Pv_R, Pv_L);
            b7 = r.blocks{7};
            tc.verifyEqual(b7.severity, 0, ...
                'Without aorta centerline the block should report OK (cannot measure).');
            tc.verifyTrue(contains(b7.findings{1}, 'fallback axis is symmetric'), ...
                'Diagnostic text should explain why no measurement is reported.');
        end
    end
end
