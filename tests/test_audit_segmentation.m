classdef test_audit_segmentation < matlab.unittest.TestCase
%TEST_AUDIT_SEGMENTATION  Unit tests for the segmentation audit gate.

    methods (TestClassSetup)
        function add_project_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function empty_mask_fails(tc)
            sz = [80 80 120];
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true, ...
                       'vol', zeros(sz, 'int16'));
            mask = false(sz);
            r = autoseg.audit_segmentation(mask, [], D);
            tc.verifyFalse(r.passed);
            tc.verifyTrue(contains(r.summary_text, 'FAIL'));
        end

        function aorta_only_mask_fails_for_missing_cfas(tc)
            % Synthetic aorta with no iliacs / CFAs — should fail the
            % "required vessels" block.
            sz = [80 80 120];
            mask = false(sz);
            mask(35:45, 35:45, 1:40) = true;   % top-third tube only
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true, ...
                       'vol', zeros(sz, 'int16'));
            r = autoseg.audit_segmentation(mask, [], D);
            tc.verifyFalse(r.passed);
            tc.verifyTrue(any(contains([cellfun(@(b) b.name, r.blocks, 'UniformOutput', false)], 'Required')));
        end

        function synthetic_bifurcation_passes_vessel_block(tc)
            % Aorta + bifurcation + two iliacs reaching FOV bottom.
            sz = [80 80 120];
            mask = false(sz);
            % Aorta — slices 1-60, midline
            mask(36:44, 36:44, 1:60) = true;
            % R iliac — slices 60-120, lower x
            for z = 60:sz(3)
                mask(36:44, 30 - round((z-60)/30):34 - round((z-60)/30), z) = true;
            end
            % L iliac — slices 60-120, higher x
            for z = 60:sz(3)
                mask(36:44, 46 + round((z-60)/30):50 + round((z-60)/30), z) = true;
            end
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true, ...
                       'vol', zeros(sz, 'int16'));
            r = autoseg.audit_segmentation(mask, [], D);
            % Required-vessels block should be OK
            req_block = r.blocks{1};
            tc.verifyEqual(req_block.severity, 0, sprintf( ...
                'Required-vessels block expected severity 0 but got %d', ...
                req_block.severity));
        end

        function report_summary_text_lists_each_block(tc)
            sz = [80 80 120];
            mask = false(sz);
            mask(36:44, 36:44, 1:60) = true;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true, ...
                       'vol', zeros(sz, 'int16'));
            r = autoseg.audit_segmentation(mask, [], D);
            tc.verifyTrue(contains(r.summary_text, 'Required vessels'));
            tc.verifyTrue(contains(r.summary_text, 'Visceral branches'));
            tc.verifyTrue(contains(r.summary_text, 'Anatomic vessel sizes'));
            tc.verifyTrue(contains(r.summary_text, 'SE(3)'));
        end
    end
end
