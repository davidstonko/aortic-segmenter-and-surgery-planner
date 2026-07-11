classdef test_hu_reconstruct_shell < matlab.unittest.TestCase
%TEST_HU_RECONSTRUCT_SHELL  The Step-3c HU-reconstruct was extracted from
%   run_planner_headless into autoseg.hu_reconstruct_shell, which crops the
%   work to the mask bounding box + shell radius for memory (GOALS #39).
%   These tests pin that the cropped result is BIT-IDENTICAL to a
%   full-volume reference — the whole point of the optimisation.

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

        function crop_matches_full_volume_reference(tc)
            % Vessels occupy a small offset sub-volume of a large FOV, with
            % a contrast halo (grows), a large in-plane contrast plate that
            % must be size-capped away, and a far-away bright blob outside
            % the shell that must be excluded by both paths.
            [vol, mask] = tc.synthetic_case();

            [grown, info] = autoseg.hu_reconstruct_shell(mask, vol, struct('pix_mm', 1));
            ref = tc.full_volume_reference(mask, vol, 1);

            tc.verifyEqual(grown, ref, ...
                'cropped reconstruct must be bit-identical to the full-volume result');
            tc.verifyGreaterThan(info.n_added, 0, 'the contrast halo should grow the mask');
            tc.verifyLessThan(info.crop_frac, 0.5, ...
                'the crop must be a real fraction of the FOV or the test is not exercising it');
            tc.verifyEqual(info.n_added, nnz(ref) - nnz(mask));
        end

        function matches_reference_when_mask_touches_boundary(tc)
            % Mask hugging the z-origin: the padded crop must clamp to the
            % volume bounds without changing the result.
            sz = [60 60 40];
            vol = zeros(sz, 'int16');
            mask = false(sz);
            mask(28:32, 28:32, 1:4) = true;           % touches z = 1
            vol(24:36, 24:36, 1:8) = 300;             % contrast halo

            grown = autoseg.hu_reconstruct_shell(mask, vol, struct('pix_mm', 1));
            ref   = tc.full_volume_reference(mask, vol, 1);
            tc.verifyEqual(grown, ref);
        end

        function empty_mask_is_returned_unchanged(tc)
            sz = [20 20 20];
            vol = 300 * ones(sz, 'int16');
            mask = false(sz);
            [grown, info] = autoseg.hu_reconstruct_shell(mask, vol, struct('pix_mm', 1));
            tc.verifyFalse(any(grown(:)));
            tc.verifyEqual(info.n_added, 0);
        end

    end

    methods (Access = private)

        function [vol, mask] = synthetic_case(~)
            sz  = [100 100 160];
            vol = zeros(sz, 'int16');
            mask = false(sz);

            % Vessel column in an offset corner (small bbox -> real crop).
            mask(20:24, 20:24, 30:50) = true;
            vol(16:28, 16:28, 26:54)  = 300;          % contrast halo (grows)

            % Big in-plane bright plate near the mask -> its in-plane CC of
            % (contrast & shell) exceeds the cap and must be dropped.
            mask(20:44, 20:44, 40) = true;
            vol(12:52, 12:52, 40)  = 300;

            % Far bright blob outside the shell -> excluded by both paths.
            vol(80:90, 80:90, 120:130) = 500;
        end

        function g = full_volume_reference(~, mask, vol, pix_mm)
            % The original inline Step-3c logic, computed over the WHOLE
            % volume (no crop) — the ground truth the helper must match.
            shell_r  = max(3, round(5 / pix_mm));
            contrast = (vol >= 150) & (vol <= 1400);
            shell    = imdilate(mask, strel('sphere', shell_r));
            cand     = autoseg.drop_big_inplane_cc(contrast & shell, round(400 / pix_mm^2));
            g        = imreconstruct(mask, mask | cand, 26);
        end

    end
end
