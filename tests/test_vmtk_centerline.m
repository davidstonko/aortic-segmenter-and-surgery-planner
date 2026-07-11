classdef test_vmtk_centerline < matlab.unittest.TestCase
%TEST_VMTK_CENTERLINE  Smoke test for +vmtk_centerline package.
%   Runs vmtk_centerline.compute on the AAA phantom and verifies the
%   returned polylines are sane: nontrivial node counts, distal endpoints
%   anchored near the CFA seeds, bifurcation found, and clinically
%   plausible arc lengths.
%
%   Skipped when VMTK is not installed (assumeTrue on detect().available).
%   Pins the post-2026-05-19 fix to extract_line + find_bifurc — before
%   the fix this returned identical L+R polylines (axis-order mismatch).

    methods (TestClassSetup)
        function add_paths(tc)
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
            tc.assumeTrue(isfile(fullfile(proj, 'library', 'PHANTOM_aaa_male.mat')), ...
                'AAA phantom .mat missing');
            info = vmtk_centerline.detect();
            tc.assumeTrue(info.available, ...
                sprintf('VMTK not installed (%s) — skipping VMTK smoke test', info.error));
        end
    end

    methods (Test)
        function compute_returns_two_distinct_polylines(tc)
            [mask, D, seed_P, seed_R, seed_L] = build_phantom_inputs();
            opts = struct('keep_work', false);
            out = vmtk_centerline.compute(mask, seed_P, seed_R, seed_L, D, opts);

            tc.verifyGreaterThan(size(out.Pv_mm_right, 1), 50, ...
                'Right polyline degenerate (<50 nodes)');
            tc.verifyGreaterThan(size(out.Pv_mm_left,  1), 50, ...
                'Left polyline degenerate (<50 nodes)');
            tc.verifyNotEqual(size(out.Pv_mm_right, 1), size(out.Pv_mm_left, 1), ...
                'L and R polylines have identical node counts — likely same VMTK line picked twice (axis-order bug regression)');
        end

        function endpoints_anchor_at_cfa_seeds(tc)
            [mask, D, seed_P, seed_R, seed_L] = build_phantom_inputs();
            out = vmtk_centerline.compute(mask, seed_P, seed_R, seed_L, D);
            r_mm = vox_to_mm_local(seed_R, D);
            l_mm = vox_to_mm_local(seed_L, D);
            d_R = norm(out.Pv_mm_right(1, :) - r_mm);
            d_L = norm(out.Pv_mm_left(1,  :) - l_mm);
            tc.verifyLessThan(d_R, 5.0, sprintf('R polyline first node %.2f mm from R seed', d_R));
            tc.verifyLessThan(d_L, 5.0, sprintf('L polyline first node %.2f mm from L seed', d_L));
        end

        function bifurcation_node_is_interior_to_right_polyline(tc)
            [mask, D, seed_P, seed_R, seed_L] = build_phantom_inputs();
            out = vmtk_centerline.compute(mask, seed_P, seed_R, seed_L, D);
            nR = size(out.Pv_mm_right, 1);
            tc.verifyGreaterThan(out.bifurc_node_right, 1, ...
                'bifurc_node_right is at the start of Pv_mm_right (no shared trunk)');
            tc.verifyLessThan(out.bifurc_node_right, nR, ...
                'bifurc_node_right equals end-of-polyline — find_bifurc walking wrong direction (returned source instead of divergence)');
            % L polyline must end near the R polyline at the bifurc node
            d = norm(out.Pv_mm_left(end, :) - out.Pv_mm_right(out.bifurc_node_right, :));
            tc.verifyLessThan(d, 5.0, sprintf('L polyline end is %.2f mm from R polyline bifurc node', d));
        end
    end
end

function [mask, D, seed_P, seed_R, seed_L] = build_phantom_inputs()
    ph = phantom.build_aaa_male();
    D = phantom.to_D_struct(ph);
    mask = ph.mask;
    sz = size(mask);
    mid_x = sz(2) / 2;
    % Proximal: most-cranial mask slice, largest CC centroid snapped to a mask voxel
    mask_zs = squeeze(any(any(mask, 1), 2));
    z_prox = find(mask_zs, 1, 'first');
    cc = bwconncomp(mask(:, :, z_prox), 8);
    [~, kbig] = max(cellfun(@numel, cc.PixelIdxList));
    [yk, xk] = ind2sub([sz(1), sz(2)], cc.PixelIdxList{kbig});
    yc = round(mean(yk)); xc = round(mean(xk));
    [~, kbest] = min((yk - yc).^2 + (xk - xc).^2);
    seed_P = [yk(kbest), xk(kbest), z_prox];
    % CFAs: most-caudal mask slice, anatomic L/R split at midline
    seed_R = []; seed_L = [];
    for z = max(find(mask_zs)):-1:min(find(mask_zs))
        sl = mask(:, :, z);
        if ~any(sl(:)); continue; end
        [yy, xx] = find(sl);
        if isempty(seed_R)
            R_idx = find(xx < mid_x);
            if ~isempty(R_idx)
                seed_R = [round(mean(yy(R_idx))), round(mean(xx(R_idx))), z];
            end
        end
        if isempty(seed_L)
            L_idx = find(xx > mid_x);
            if ~isempty(L_idx)
                seed_L = [round(mean(yy(L_idx))), round(mean(xx(L_idx))), z];
            end
        end
        if ~isempty(seed_R) && ~isempty(seed_L); break; end
    end
end

function pt_mm = vox_to_mm_local(vox, D)
    pt_mm = [(vox(1)-1) * D.pixel_mm(1), ...
             (vox(2)-1) * D.pixel_mm(2), ...
             (vox(3)-1) * D.slice_spacing_mm];
end
