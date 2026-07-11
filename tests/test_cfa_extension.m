classdef test_cfa_extension < matlab.unittest.TestCase
%TEST_CFA_EXTENSION  Pin the autoseg.extend_to_cfa behavior the user
%   demanded: segmentation reaches the common femoral arteries on BOTH
%   sides of the patient, each side is a single connected component
%   from the aortic bifurcation to the FOV bottom, and the extension
%   never crosses the midline.

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function johndoe1_both_sides_reach_fov_bottom(tc)
            % Load JohnDoe1 cache. If absent, skip — the test isn't meant
            % to run without the case present.
            proj = fileparts(fileparts(mfilename('fullpath')));
            ct_mat = fullfile(proj, 'results', 'logs', 'ct_volume.mat');
            cache  = fullfile(proj, 'results', 'logs', 'johndoe1_branch_labels.mat');
            tc.assumeTrue(isfile(ct_mat), 'JohnDoe1 CT cache not available');
            tc.assumeTrue(isfile(cache),  'JohnDoe1 branch-label cache not available');
            L = load(ct_mat, 'D_ct'); D = L.D_ct;
            S = load(cache);

            % If the cache already includes the CFA extension (newer
            % runs), labels 4 and 5 should reach near the FOV bottom.
            % If it's an older cache (pre-extension), run extend_to_cfa
            % here.
            label = S.label_branch; mask = S.m_branch;
            sz = size(label);
            ssp = abs(D.slice_spacing_mm);
            need_extend = true;
            zp4 = squeeze(any(any(label == 4, 1), 2));
            zp5 = squeeze(any(any(label == 5, 1), 2));
            if any(zp4) && any(zp5)
                last4 = find(zp4, 1, 'last');
                last5 = find(zp5, 1, 'last');
                % Within 25 mm of the FOV bottom on both sides → already
                % extended.
                if (sz(3) - last4) * ssp < 25 && (sz(3) - last5) * ssp < 25
                    need_extend = false;
                end
            end
            if need_extend
                [mask, label, ~] = autoseg.extend_to_cfa(D, mask, label, ...
                    struct('verbose', false));
            end

            % Both sides must reach the FOV bottom (within 25 mm).
            zp4 = squeeze(any(any(label == 4, 1), 2));
            zp5 = squeeze(any(any(label == 5, 1), 2));
            tc.assertTrue(any(zp4), 'No L-CFA voxels after extension');
            tc.assertTrue(any(zp5), 'No R-CFA voxels after extension');
            d4 = (sz(3) - find(zp4, 1, 'last')) * ssp;
            d5 = (sz(3) - find(zp5, 1, 'last')) * ssp;
            tc.verifyLessThan(d4, 25, ...
                sprintf('L CFA ends %.0f mm above FOV bottom — extension regressed', d4));
            tc.verifyLessThan(d5, 25, ...
                sprintf('R CFA ends %.0f mm above FOV bottom — extension regressed', d5));
        end

        function per_side_chain_is_one_connected_component(tc)
            proj = fileparts(fileparts(mfilename('fullpath')));
            cache  = fullfile(proj, 'results', 'logs', 'johndoe1_branch_labels.mat');
            ct_mat = fullfile(proj, 'results', 'logs', 'ct_volume.mat');
            tc.assumeTrue(isfile(cache),  'JohnDoe1 branch-label cache not available');
            tc.assumeTrue(isfile(ct_mat), 'JohnDoe1 CT cache not available');
            S = load(cache);
            L = load(ct_mat, 'D_ct'); D = L.D_ct;
            label = S.label_branch; mask = S.m_branch;
            sz = size(label);

            % Find aortic bifurcation + midline
            aorta_zp = squeeze(any(any(label == 1, 1), 2));
            z_bif = find(aorta_zp, 1, 'last');
            slc = (label(:,:,z_bif) == 1);
            [~, xa] = find(slc);
            x_a = mean(xa);

            % Patient-LEFT physical side
            side_L = false(sz);
            side_L(:, ceil(x_a)+1:end, z_bif+1:end) = true;
            m_L = mask & side_L;
            cc_L = bwconncomp(m_L, 26);
            tc.assertGreaterThanOrEqual(cc_L.NumObjects, 1, 'No L-side mask below bifurcation');
            sz_L = cellfun(@numel, cc_L.PixelIdxList);
            ratio_L = max(sz_L) / sum(sz_L);
            tc.verifyGreaterThan(ratio_L, 0.95, sprintf( ...
                'L side largest CC is only %.0f%% of total — fragmented', 100*ratio_L));

            % Patient-RIGHT physical side
            side_R = false(sz);
            side_R(:, 1:floor(x_a)-1, z_bif+1:end) = true;
            m_R = mask & side_R;
            cc_R = bwconncomp(m_R, 26);
            tc.assertGreaterThanOrEqual(cc_R.NumObjects, 1, 'No R-side mask below bifurcation');
            sz_R = cellfun(@numel, cc_R.PixelIdxList);
            ratio_R = max(sz_R) / sum(sz_R);
            tc.verifyGreaterThan(ratio_R, 0.95, sprintf( ...
                'R side largest CC is only %.0f%% of total — fragmented', 100*ratio_R));
        end

        function no_midline_crossing(tc)
            % Synthetic test: build a mask + label with a single
            % patient-LEFT iliac. Confirm extend_to_cfa never paints
            % voxels on the patient-RIGHT side.
            sz = [60 60 220];
            mask = false(sz); label = zeros(sz, 'uint8');
            % Aorta down the midline (x=30) to z=120, then L iliac
            % diverges to x=45 and continues to z=150
            mask(28:32, 28:32, 10:120) = true;
            label(28:32, 28:32, 10:120) = 1;
            mask(28:32, 43:47, 110:150) = true;
            label(28:32, 43:47, 110:150) = 4;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true);
            D.vol = int16(zeros(sz));
            D.vol(28:32, 43:47, 110:200) = 600;   % bright lumen below
            D.vol(28:32, 13:17, 110:200) = 600;   % a bright DECOY on the OTHER side

            [mask2, label2, info] = autoseg.extend_to_cfa(D, mask, label, ...
                struct('verbose', false));

            % All new L-CFA voxels must be on x > x_aorta = 30
            new_L = (label2 == 4) & ~(label == 4);
            [~, xL, ~] = ind2sub(sz, find(new_L));
            tc.verifyEmpty(xL(xL <= info.x_aorta), ...
                'L-CFA extension placed voxels on the patient-RIGHT side');
            tc.verifyGreaterThan(numel(xL), 50, ...
                'L-CFA extension added too few voxels');
        end
    end
end
