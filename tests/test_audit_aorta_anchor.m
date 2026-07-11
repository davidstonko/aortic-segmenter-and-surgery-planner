classdef test_audit_aorta_anchor < matlab.unittest.TestCase
%TEST_AUDIT_AORTA_ANCHOR  Pin the audit's per-side-continuity behavior
%   after the 2026-05-17 refactor that prefers the aorta-label centroid
%   over the brittle "first two-CC slice" heuristic.
%
%   Why this matters: when extend_and_detect_branches' imreconstruct
%   grows the L iliac territory across the midline, the geometric
%   bifurcation split (mean of two-CC centroids) misclassifies which
%   physical side the extension belongs to. Using the aorta centroid
%   matches what `extend_to_cfa` does and keeps the audit consistent.

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function uses_aorta_centroid_when_label_present(tc)
            % Synthetic mask: aorta at x≈30 down to z=100; iliacs diverge
            % to x=25 and x=35 below. Label volume marks the aorta tube.
            sz = [60 60 200];
            mask = false(sz); label = zeros(sz, 'uint8');
            % Aortic trunk (x=28-32) z=10..100
            mask(28:32, 28:32, 10:100) = true;
            label(28:32, 28:32, 10:100) = 1;
            % R iliac (lower x): x=20-24, z=101..180
            mask(28:32, 20:24, 101:180) = true;
            % L iliac (higher x): x=36-40, z=101..180
            mask(28:32, 36:40, 101:180) = true;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, ...
                       'is_volume', true, 'vol', zeros(sz, 'int16'));

            audit = autoseg.audit_segmentation(mask, ...
                struct('ts_labels', uint8([]), 'branch_labels', label), D);
            blk = find_block(audit, 'Per-side continuity');
            tc.assertNotEmpty(blk, 'per-side block missing');
            anchor_line = strjoin(blk.findings, '|');
            tc.verifyTrue(contains(anchor_line, 'aorta-centroid'), ...
                sprintf('Expected aorta-centroid anchor, got: %s', anchor_line));
        end

        function falls_back_to_two_cc_split_without_aorta_label(tc)
            % Same mask but no branch_labels — audit must use the
            % fallback heuristic.
            sz = [60 60 200];
            mask = false(sz);
            mask(28:32, 28:32, 10:100) = true;
            mask(28:32, 20:24, 101:180) = true;
            mask(28:32, 36:40, 101:180) = true;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, ...
                       'is_volume', true, 'vol', zeros(sz, 'int16'));

            audit = autoseg.audit_segmentation(mask, ...
                struct('ts_labels', uint8([]), 'branch_labels', uint8([])), D);
            blk = find_block(audit, 'Per-side continuity');
            tc.assertNotEmpty(blk);
            anchor_line = strjoin(blk.findings, '|');
            tc.verifyTrue(contains(anchor_line, 'two-CC fallback') || ...
                contains(anchor_line, 'No two-iliac'), ...
                sprintf('Expected two-CC fallback, got: %s', anchor_line));
        end

        function quick_stat_appears_in_summary(tc)
            sz = [60 60 200];
            mask = false(sz);
            mask(28:32, 28:32, 10:180) = true;
            D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, ...
                       'is_volume', true, 'vol', zeros(sz, 'int16'));
            audit = autoseg.audit_segmentation(mask, ...
                struct('ts_labels', uint8([]), 'branch_labels', uint8([])), D, ...
                struct('verbose', false));
            tc.verifyTrue(contains(audit.summary_text, 'Mask quick-stat:'), ...
                'Mask quick-stat line missing from audit summary');
            tc.verifyTrue(contains(audit.summary_text, 'FOV'), ...
                'FOV extent missing from quick-stat');
        end
    end
end

function blk = find_block(audit, name_substr)
    blk = [];
    for k = 1:numel(audit.blocks)
        b = audit.blocks{k};
        if contains(b.name, name_substr); blk = b; return; end
    end
end
