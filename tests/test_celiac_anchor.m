classdef test_celiac_anchor < matlab.unittest.TestCase
%TEST_CELIAC_ANCHOR  Verify that the audit + auto_seeds use the actual
%   celiac centroid (label 8) as the proximal anchor — NOT a kidney
%   proxy. Anchors the user's "celiac, not kidney" requirement in tests
%   so it can't silently regress.

    methods (TestClassSetup)
        function add_project_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function audit_uses_celiac_anchor_when_present(tc)
            % Synthetic mask with a celiac at z=100 and aorta z=10..200.
            sz = [60 60 220];
            mask = false(sz);
            mask(28:32, 28:32, 10:200) = true;     % aorta tube
            label = zeros(sz, 'uint8');
            label(28:32, 28:32, 10:200) = 1;      % aorta = label 1
            label(26:30, 32:36, 95:105) = 8;      % celiac at z=95-105
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true, ...
                       'vol', zeros(sz, 'int16'));

            r = autoseg.audit_segmentation(mask, ...
                struct('ts_labels', uint8([]), 'branch_labels', label), D);
            % Find the proximal-extent block
            blk = [];
            for k = 1:numel(r.blocks)
                if contains(r.blocks{k}.name, 'Proximal extent')
                    blk = r.blocks{k}; break;
                end
            end
            tc.verifyNotEmpty(blk, 'No proximal-extent block found');
            % Anchor should be 'celiac (label 8)', NOT kidney
            anchor_line = join(string(blk.findings), '\n');
            tc.verifyTrue(contains(anchor_line, 'celiac'), ...
                sprintf('Expected celiac anchor in findings, got: %s', anchor_line));
            tc.verifyFalse(contains(lower(anchor_line), 'kidney') && ...
                contains(lower(anchor_line), 'fallback'), ...
                'Audit fell back to kidney even though celiac was present');
        end

        function auto_seeds_uses_celiac_for_proximal_z(tc)
            sz = [60 60 220];
            seg = zeros(sz, 'uint8');
            n2id = autoseg.class_name_to_id();
            seg(28:32, 28:32, 10:200) = n2id('aorta');
            seg(:,:,200) = 0;   % drop the very bottom
            seg(20:30, 20:30, 180:200) = n2id('iliac_artery_left');
            seg(20:30, 32:40, 180:200) = n2id('iliac_artery_right');
            label_branch = zeros(sz, 'uint8');
            label_branch(28:32, 28:32, 10:200) = 1;     % aorta
            label_branch(26:30, 32:36, 95:105) = 8;      % celiac top at z=95
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true);

            seeds = preprocess.auto_seeds_anatomic(seg, D, struct(), label_branch);
            tc.verifyTrue(seeds.ok);
            % Proximal z should be celiac_top - 50 mm = 95 - 50 = 45
            tc.verifyEqual(seeds.diagnostic.anchor, 'celiac');
            tc.verifyEqual(seeds.proximal(3), 45, 'AbsTol', 5);
        end

        function audit_fails_if_no_celiac_and_only_kidney(tc)
            % Mask + TS labels but NO branch labels — audit should fall
            % back to kidney proxy AND mark the proximal-extent block
            % as WARN (severity 1) to signal that the segmentation is
            % incomplete.
            sz = [60 60 220];
            mask = false(sz);
            mask(28:32, 28:32, 10:200) = true;
            n2id = autoseg.class_name_to_id();
            ts = zeros(sz, 'uint8');
            ts(20:35, 20:35, 130:180) = n2id('kidney_left');
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, 'is_volume', true, ...
                       'vol', zeros(sz, 'int16'));

            r = autoseg.audit_segmentation(mask, ...
                struct('ts_labels', ts, 'branch_labels', uint8([])), D);
            blk = [];
            for k = 1:numel(r.blocks)
                if contains(r.blocks{k}.name, 'Proximal extent')
                    blk = r.blocks{k}; break;
                end
            end
            tc.verifyNotEmpty(blk);
            % Should mark a fallback severity (≥ 1) since celiac wasn't found
            tc.verifyGreaterThanOrEqual(blk.severity, 1, ...
                'Audit should WARN when forced to use kidney proxy');
            anchor_line = join(string(blk.findings), '\n');
            tc.verifyTrue(contains(lower(anchor_line), 'kidney'), ...
                'Expected kidney fallback in findings');
        end
    end
end
