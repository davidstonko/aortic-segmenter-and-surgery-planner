classdef test_check_complete_segmentation < matlab.unittest.TestCase
%TEST_CHECK_COMPLETE_SEGMENTATION  Regression for
%   autoseg.check_complete_segmentation — the acceptance gate that decides
%   whether a planner result is a COMPLETE aortic segmentation: one
%   connected vessel from the proximal neck down both iliacs/CFAs to the
%   FOV bottom, with the bifurcated centerline routing end-to-end to each
%   CFA seed (the JohnDoe1 truncation must register as a FAIL).

    methods (TestClassSetup)
        function add_paths(tc) %#ok<MANU>
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
        end
    end

    methods (Test)
        function good_segmentation_passes(tc)
            [out, D] = synth_complete_case();
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            tc.verifyTrue(rep.pass, 'a complete, end-to-end case must PASS');
            tc.verifyTrue(rep.single_cc);
            tc.verifyTrue(rep.right_reach_ok && rep.left_reach_ok);
            tc.verifyTrue(rep.right_cl_ok && rep.left_cl_ok);
        end

        function truncated_distal_chain_fails(tc)
            % The JohnDoe1 failure mode: the right chain is dropped below
            % mid-vessel, so its distal mask stops far above the FOV bottom.
            [out, D] = synth_complete_case();
            out.mask(:, 1:20, 31:end) = false;     % erase right leg distally
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            tc.verifyFalse(rep.pass, 'a truncated distal chain must FAIL');
            tc.verifyFalse(rep.right_reach_ok, 'right reach gap must be flagged');
            tc.verifyTrue(rep.left_reach_ok, 'left chain is intact');
        end

        function short_centerline_fails(tc)
            % Mask is complete but the centerline stops short of the CFA
            % seed (degenerate VMTK polyline) — must FAIL.
            [out, D] = synth_complete_case();
            out.Pv_mm_right = out.Pv_mm_right(1:round(end/2), :);
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            tc.verifyFalse(rep.pass, 'a short centerline must FAIL');
            tc.verifyFalse(rep.right_cl_ok);
        end

        function degenerate_centerline_at_cfa_fails(tc)
            % The exact JohnDoe2 post-reconnection failure: a degenerate
            % VMTK polyline collapses to TWO identical nodes sitting on the
            % CFA seed. CFA gap is ~0, but there is no traversal — it must
            % FAIL on the proximal-reach + arc-span gates.
            [out, D] = synth_complete_case();
            cfa = out.seeds_mm.right_cfa;
            out.Pv_mm_right = [cfa([2 1 3]); cfa([2 1 3])];  % 2 coincident nodes
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            tc.verifyTrue(rep.right_cl_gap_mm <= 12, 'CFA gap is small (the trap)');
            tc.verifyFalse(rep.right_cl_ok, 'but no traversal -> branch must fail');
            tc.verifyFalse(rep.pass);
        end

        function left_branch_trimmed_at_bifurcation_passes(tc)
            % Topology lock-in: vmtk_centerline.compute TRIMS the left
            % polyline at the bifurcation, so the left branch spans only
            % bifurcation->CFA — legitimately SHORT and NOT reaching the
            % proximal seed. Here the left branch joins the trunk well
            % distally (node 16 of the right polyline) so its arc (~16 mm)
            % is below span_frac * the full proximal->CFA straight (~35 mm).
            % An arc-span gate referenced to that full straight would
            % false-fail it; the hardened gate applies the span test ONLY to
            % the primary (right) branch and gates the left on the
            % trunk-join, so this legitimate short-left case must PASS.
            [out, D] = synth_complete_case();
            bif = out.Pv_mm_right(16, :);          % distal bifurcation on the trunk
            out.Pv_mm_left = linterp(bif, out.seeds_mm.left_cfa, 20);
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            tc.verifyTrue(rep.pass, ...
                'short left branch joining the trunk + reaching its CFA must PASS');
            tc.verifyTrue(rep.left_cl_ok, 'left branch gated on trunk-join, not full-span arc');
            tc.verifyTrue(rep.right_cl_ok);
        end

        function fragmented_mask_fails(tc)
            % A second floating component drags the largest-CC fraction
            % below the single-component threshold.
            [out, D] = synth_complete_case();
            out.mask(2:4, 2:4, 2:4) = true;        % off-vessel floating blob
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            tc.verifyFalse(rep.single_cc, 'two components must trip single_cc');
            tc.verifyFalse(rep.pass);
        end

        function report_has_documented_fields(tc)
            [out, D] = synth_complete_case();
            rep = autoseg.check_complete_segmentation(out, D, struct('verbose', false));
            req = {'pass', 'single_cc', 'n_cc', 'largest_frac', ...
                'right_reach_ok', 'left_reach_ok', 'right_gap_mm', 'left_gap_mm', ...
                'right_cl_ok', 'left_cl_ok', 'right_cl_gap_mm', 'left_cl_gap_mm', ...
                'reasons'};
            for k = 1:numel(req)
                tc.verifyTrue(isfield(rep, req{k}), ...
                    sprintf('report missing field: %s', req{k}));
            end
        end
    end
end

% =========================================================================
function [out, D] = synth_complete_case()
%SYNTH_COMPLETE_CASE  A single-component aorta that branches into two
%   iliac/CFA legs reaching the last image slice, with two centerlines
%   that terminate exactly at their CFA seeds.
    sz = [40, 40, 60];
    mask = false(sz);
    % Wide aorta block (cols 14-26) spanning both leg columns, z=1..30.
    for z = 1:30
        mask(18:22, 14:26, z) = true;
    end
    % Two legs z=31..60: right at cols 12-16, left at cols 24-28; both
    % overlap the aorta block in-plane so the whole thing is one 26-CC.
    for z = 31:60
        mask(18:22, 12:16, z) = true;   % right leg (cols < mid)
        mask(18:22, 24:28, z) = true;   % left  leg (cols > mid)
    end

    seeds = struct('proximal', [20, 20, 2], ...
                   'right_cfa', [20, 14, 60], ...
                   'left_cfa',  [20, 26, 60]);
    % mm frame: identity-ish [x y z]; only relative distances matter here.
    seeds_mm = struct('proximal',  [20, 20, 2], ...
                      'right_cfa', [14, 20, 60], ...
                      'left_cfa',  [26, 20, 60]);

    Pv_mm_right = linterp(seeds_mm.proximal, seeds_mm.right_cfa, 20);
    Pv_mm_left  = linterp(seeds_mm.proximal, seeds_mm.left_cfa,  20);

    out = struct('mask', mask, 'seeds', seeds, 'seeds_mm', seeds_mm, ...
                 'Pv_mm_right', Pv_mm_right, 'R_mm_right', 3 * ones(20, 1), ...
                 'Pv_mm_left',  Pv_mm_left,  'R_mm_left',  3 * ones(20, 1));

    D = struct('vol', zeros(sz, 'int16'), 'pixel_mm', [1 1], ...
               'slice_spacing_mm', 1, 'slice_z_mm', (0:sz(3)-1), 'is_volume', true);
end

function P = linterp(a, b, n)
    t = linspace(0, 1, n)';
    P = (1 - t) .* a(:)' + t .* b(:)';
end
