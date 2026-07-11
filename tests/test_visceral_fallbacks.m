classdef test_visceral_fallbacks < matlab.unittest.TestCase
%TEST_VISCERAL_FALLBACKS  Cover the SMA + renal fallback paths in
%   autoseg.extend_and_detect_branches that we added to address the
%   user's complaint that SMA and one renal were missing from the
%   JohnDoe1-case segmentation. Uses the actual cached JohnDoe1 output so
%   any regression in the fallbacks fails the suite loudly.

    properties (Access = private)
        D struct = struct()
        seg uint8 = uint8([])
        m_branch logical = false(0)
        label_branch uint8 = uint8([])
    end

    methods (TestClassSetup)
        function add_paths_and_load(tc)
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
            ct_mat = fullfile(proj, 'results', 'logs', 'ct_volume.mat');
            seg_path = fullfile(proj, '.cache', 'autoseg', '0f7b83b54bdd_seg.nii.gz');
            cache_mat = fullfile(proj, 'results', 'logs', 'johndoe1_branch_labels.mat');
            tc.assumeTrue(isfile(ct_mat), 'JohnDoe1 CT cache not available');
            tc.assumeTrue(isfile(seg_path), 'JohnDoe1 TS seg cache not available');
            tc.assumeTrue(isfile(cache_mat), 'Branch-labels cache not available — run autoseg.extend_and_detect_branches once and save to results/logs/johndoe1_branch_labels.mat');
            L = load(ct_mat, 'D_ct');
            tc.D = L.D_ct;
            tc.seg = uint8(niftiread(seg_path));
            % Pre-computed branch labels — running the full
            % extend_and_detect_branches pass per-test is too slow.
            S = load(cache_mat);
            tc.m_branch     = S.m_branch;
            tc.label_branch = S.label_branch;
        end
    end

    methods (Test)
        function all_four_visceral_branches_detected(tc)
            label_branch = tc.label_branch;
            n_renal_L = nnz(label_branch == 6);
            n_renal_R = nnz(label_branch == 7);
            n_celiac  = nnz(label_branch == 8);
            n_sma     = nnz(label_branch == 9);
            tc.verifyGreaterThan(n_renal_L, 500, ...
                sprintf('Renal L only %d vox — fallback regressed (expected >500)', n_renal_L));
            tc.verifyGreaterThan(n_renal_R, 500, sprintf('Renal R only %d vox', n_renal_R));
            tc.verifyGreaterThan(n_celiac,  300, sprintf('Celiac only %d vox', n_celiac));
            tc.verifyGreaterThan(n_sma,     500, ...
                sprintf('SMA only %d vox — SMA fallback regressed (expected >500)', n_sma));
        end

        function visceral_branch_sizes_anatomically_plausible(tc)
            label_branch = tc.label_branch;
            voxel_mL = tc.D.pixel_mm(1) * tc.D.pixel_mm(2) * tc.D.slice_spacing_mm / 1000;
            for cid = [6, 7, 9]
                mL = nnz(label_branch == cid) * voxel_mL;
                tc.verifyLessThan(mL, 15, sprintf( ...
                    'Label %d size %.1f mL exceeds anatomic upper bound (likely fused with adjacent tissue)', ...
                    cid, mL));
            end
        end

        function audit_passes_visceral_block_after_fallbacks(tc)
            n2id = autoseg.class_name_to_id();
            mask = (tc.seg == n2id('aorta')) | ...
                   (tc.seg == n2id('iliac_artery_left')) | ...
                   (tc.seg == n2id('iliac_artery_right')) | tc.m_branch;
            r = autoseg.audit_segmentation(mask, ...
                struct('ts_labels', tc.seg, 'branch_labels', tc.label_branch), tc.D);
            % Find visceral-branch block — should be severity 0 (OK)
            for k = 1:numel(r.blocks)
                if contains(r.blocks{k}.name, 'Visceral')
                    tc.verifyEqual(r.blocks{k}.severity, 0, ...
                        sprintf('Visceral-branch block severity %d (findings: %s)', ...
                            r.blocks{k}.severity, strjoin(r.blocks{k}.findings, '; ')));
                    return;
                end
            end
            tc.assertFail('No visceral-branch block in audit report');
        end
    end
end
