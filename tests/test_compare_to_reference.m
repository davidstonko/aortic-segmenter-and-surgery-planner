classdef test_compare_to_reference < matlab.unittest.TestCase
%TEST_COMPARE_TO_REFERENCE  Sanity tests for the goal #5 comparison harness.

    methods (TestClassSetup)
        function add_project_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function identical_inputs_give_zero_deltas(tc)
            n = 50;
            Pv = [zeros(n,1), zeros(n,1), (0:n-1).'];
            auto = struct( ...
                'Pv_mm_right', Pv, 'Pv_mm_left', Pv, ...
                'neck_diameter_mm', 22, 'neck_length_mm', 18, ...
                'neck_angulation_deg', 30, ...
                'iliac_R_diameter_mm', 12, 'iliac_L_diameter_mm', 11, ...
                'iliac_R_length_mm', 22, 'iliac_L_length_mm', 22);
            r = evar_plan.compare_to_reference(auto, auto, struct('label','self'));
            tc.verifyEqual(r.centerline.right.hausdorff_mm, 0);
            tc.verifyEqual(r.centerline.left.hausdorff_mm,  0);
            tc.verifyEqual(r.sizing.neck_diameter_mm.abs_delta, 0);
            tc.verifyEqual(r.sizing.iliac_R_diameter_mm.abs_delta, 0);
        end

        function known_offset_centerline(tc)
            n = 50;
            Pv1 = [zeros(n,1), zeros(n,1), (0:n-1).'];
            Pv2 = Pv1; Pv2(:, 1) = Pv2(:, 1) + 3;   % shift x by 3 mm
            auto = struct('Pv_mm_right', Pv1, 'Pv_mm_left', Pv1);
            ref  = struct('Pv_mm_right', Pv2, 'Pv_mm_left', Pv2);
            r = evar_plan.compare_to_reference(auto, ref);
            tc.verifyEqual(r.centerline.right.hausdorff_mm, 3, 'AbsTol', 1e-6);
            tc.verifyEqual(r.centerline.left.hausdorff_mm,  3, 'AbsTol', 1e-6);
            tc.verifyEqual(r.centerline.right.arc_delta_mm, 0, 'AbsTol', 1e-6);
        end

        function dice_iou_on_overlapping_masks(tc)
            m1 = false(20, 20, 20); m1(5:15, 5:15, 5:15) = true;
            m2 = false(20, 20, 20); m2(7:17, 7:17, 7:17) = true;
            r = evar_plan.compare_to_reference(struct('mask', m1), struct('mask', m2));
            tc.verifyGreaterThan(r.segmentation.dice, 0);
            tc.verifyLessThan(r.segmentation.dice, 1);
            tc.verifyLessThanOrEqual(r.segmentation.iou, r.segmentation.dice);
        end

        function nan_fields_are_skipped(tc)
            % If neck_length_mm is NaN on either side, the field is not
            % reported as a delta (rather than counted as zero).
            auto = struct('neck_diameter_mm', 22, 'neck_length_mm', NaN);
            ref  = struct('neck_diameter_mm', 22, 'neck_length_mm', 15);
            r = evar_plan.compare_to_reference(auto, ref);
            tc.verifyTrue(isfield(r.sizing, 'neck_diameter_mm'));
            tc.verifyFalse(isfield(r.sizing, 'neck_length_mm'));
        end
    end
end
