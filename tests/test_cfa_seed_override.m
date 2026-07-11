classdef test_cfa_seed_override < matlab.unittest.TestCase
%TEST_CFA_SEED_OVERRIDE  Pin the manual-CFA-click backend.
%   `autoseg.extend_to_cfa` accepts `opts.cfa_seed_override_L` and
%   `opts.cfa_seed_override_R` as [y, x, z] voxel triplets. When set,
%   the topological detector is bypassed for that side and the walker
%   uses the user-supplied seed. This is the backend behind the GUI
%   "Manual CFA click" re-anchor flow.

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function override_voxel_propagates_to_info_cfa_seed(tc)
            % Synthetic: aorta down the midline, both iliacs, bright
            % CFA-like contrast on both sides at the FOV bottom.
            sz = [60, 60, 220];
            mask = false(sz); label = zeros(sz, 'uint8');
            mask(28:32, 28:32, 10:120) = true;
            label(28:32, 28:32, 10:120) = 1;                  % aorta
            mask(28:32, 43:47, 110:150) = true;
            label(28:32, 43:47, 110:150) = 4;                 % L iliac stub
            mask(28:32, 13:17, 110:150) = true;
            label(28:32, 13:17, 110:150) = 5;                 % R iliac stub
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true);
            D.vol = int16(zeros(sz));
            D.vol(28:32, 43:47, 110:200) = 600;               % L lumen
            D.vol(28:32, 13:17, 110:200) = 600;               % R lumen

            % Force the L walker to start from a specific override voxel.
            override_L = [30, 45, 195];
            [~, ~, info] = autoseg.extend_to_cfa(D, mask, label, struct( ...
                'verbose', false, ...
                'cfa_seed_override_L', override_L));

            tc.assertTrue(isfield(info, 'L'), 'info.L missing');
            tc.assertTrue(isfield(info.L, 'cfa_seed'), 'info.L.cfa_seed missing');
            % The walker may round / shift slightly, but the seed should
            % land near the override voxel.
            d = norm(double(info.L.cfa_seed(:)') - double(override_L));
            tc.verifyLessThanOrEqual(d, 3, sprintf( ...
                'L CFA seed (%s) drifted > 3 vox from override (%s)', ...
                mat2str(info.L.cfa_seed), mat2str(override_L)));
        end

        function override_seed_reason_is_diagnostic(tc)
            sz = [60, 60, 220];
            mask = false(sz); label = zeros(sz, 'uint8');
            mask(28:32, 28:32, 10:120) = true;
            label(28:32, 28:32, 10:120) = 1;
            mask(28:32, 43:47, 110:150) = true;
            label(28:32, 43:47, 110:150) = 4;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true);
            D.vol = int16(zeros(sz));
            D.vol(28:32, 43:47, 110:200) = 600;

            override_L = [30, 45, 195];
            [~, ~, info] = autoseg.extend_to_cfa(D, mask, label, struct( ...
                'verbose', false, 'cfa_seed_override_L', override_L));
            tc.verifyTrue(contains(info.L.cfa_seed_reason, 'User-supplied') || ...
                contains(info.L.cfa_seed_reason, 'manual click'), sprintf( ...
                'Reason text should note the manual click: "%s"', info.L.cfa_seed_reason));
        end

        function malformed_override_errors_clearly(tc)
            sz = [60, 60, 220];
            mask = false(sz); label = zeros(sz, 'uint8');
            mask(28:32, 28:32, 10:120) = true;
            label(28:32, 28:32, 10:120) = 1;
            mask(28:32, 43:47, 110:150) = true;
            label(28:32, 43:47, 110:150) = 4;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true);
            D.vol = int16(zeros(sz));
            tc.verifyError( ...
                @() autoseg.extend_to_cfa(D, mask, label, struct( ...
                    'verbose', false, 'cfa_seed_override_L', [10, 20])), ...
                'extend_to_cfa:bad_override');
        end
    end
end
