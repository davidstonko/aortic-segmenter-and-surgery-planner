classdef test_reconnect_vesselness_path < matlab.unittest.TestCase
%TEST_RECONNECT_VESSELNESS_PATH  Covers autoseg.reconnect_via_vesselness_path
%   (the Step-3c'' external-iliac reconnect) — previously untested. Also
%   guards the per-ROI double-cast: the function reads the CT only through
%   small ROIs, so it must never materialise double(D.vol) over the whole
%   FOV (GOALS #39). These tests exercise the ROI-read path end to end.

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

        function reconnects_two_fragments_via_contrast_bridge(tc)
            % Anchor CC + a disconnected fragment, joined by a genuine
            % bright-contrast bridge running through the mask gap. The
            % vesselness path should ride the bridge and fuse the two into
            % one component, adding only voxels (never removing).
            [D, mask] = tc.two_fragment_case();

            [mask_out, info] = autoseg.reconnect_via_vesselness_path( ...
                D, mask, struct('z_lo', 1, 'verbose', false));

            tc.verifyEqual(info.cc_before, 2);
            tc.verifyLessThan(info.cc_after, info.cc_before, ...
                'the contrast bridge should fuse the fragment to the anchor');
            tc.verifyGreaterThan(info.added_voxels, 0);
            tc.verifyTrue(all(mask_out(mask)), 'reconnect must never remove mask voxels');
            tc.verifyEqual(info.added_voxels, nnz(mask_out) - nnz(mask));
        end

        function single_component_is_a_noop(tc)
            [D, mask] = tc.two_fragment_case();
            % Fill the gap so the mask is already one component.
            mask(23:26, 23:26, 21:34) = true;

            [mask_out, info] = autoseg.reconnect_via_vesselness_path( ...
                D, mask, struct('z_lo', 1, 'verbose', false));

            tc.verifyEqual(info.cc_before, 1);
            tc.verifyEqual(info.added_voxels, 0);
            tc.verifyEqual(mask_out, mask, 'single-component input must be returned unchanged');
            tc.verifyTrue(contains(info.reason, 'single component'));
        end

    end

    methods (Access = private)

        function [D, mask] = two_fragment_case(~)
            sz  = [50 50 60];
            vol = zeros(sz, 'int16');
            mask = false(sz);

            % Anchor (large CC) and a disconnected caudal fragment, both an
            % 8x8 column so each clears min_frag_vox (800).
            mask(21:28, 21:28, 35:59) = true;   % anchor  (8*8*25 = 1600)
            mask(21:28, 21:28, 5:20)  = true;   % fragment (8*8*16 = 1024)
            vol(21:28, 21:28, 35:59)  = 300;
            vol(21:28, 21:28, 5:20)   = 300;

            % Bright contrast bridge across the mask gap (z 21..34) — NOT in
            % the mask, only in the image, so it is a genuine gap the path
            % must discover from CT evidence.
            vol(23:26, 23:26, 21:34) = 300;

            D = struct('vol', vol, 'pixel_mm', [1 1], 'slice_spacing_mm', 1);
        end

    end
end
