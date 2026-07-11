classdef test_reconnect_vessel_fragments < matlab.unittest.TestCase
%TEST_RECONNECT_VESSEL_FRAGMENTS  Regression for
%   autoseg.reconnect_vessel_fragments — the iterative shell-confined
%   contrast grow that fuses distal iliac/CFA fragments which TS + the
%   slice-by-slice walker left IN-PLANE-STAGGERED (present on every slice
%   but not 26-connected to their neighbours), so step 6b's keep-largest
%   no longer drops the distal string and truncates the centerline.
%
%   The phantom mirrors the JohnDoe1 failure mode: a vessel that is present
%   on every z-slice but whose mask cores jump > 1 voxel in-plane between
%   consecutive slices (so they are separate 3-D components), surrounded
%   by a CONTINUOUS contrast lumen. The function must crawl through that
%   genuine contrast and fuse the chain into one component reaching the
%   FOV bottom — without painting any voxel that isn't already contrast,
%   and without swallowing an off-path marrow slab.

    methods (TestClassSetup)
        function add_paths(tc) %#ok<MANU>
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
        end
    end

    methods (Test)
        function reconnects_staggered_fragments_into_one_cc(tc)
            [D, mask_in] = synth_fragmented_vessel();
            n_cc_in = bwconncomp(mask_in, 26).NumObjects;
            tc.verifyGreaterThan(n_cc_in, 10, ...
                'phantom should start badly fragmented');
            [mask_out, info] = autoseg.reconnect_vessel_fragments(D, mask_in, ...
                struct('verbose', false));
            tc.verifyLessThan(info.cc_after, info.cc_before, ...
                'reconnection should reduce the number of 3-D components');
            % The single largest CC should now span the whole vessel.
            cc = bwconncomp(mask_out, 26);
            sizes = cellfun(@numel, cc.PixelIdxList);
            [~, kb] = max(sizes);
            big = false(size(mask_out)); big(cc.PixelIdxList{kb}) = true;
            zspan = squeeze(any(any(big, 1), 2));
            tc.verifyLessThanOrEqual(find(zspan, 1, 'first'), 5, ...
                'largest CC should start near the top of the vessel');
            tc.verifyGreaterThanOrEqual(find(zspan, 1, 'last'), size(D.vol, 3) - 4, ...
                'largest CC should reach the FOV bottom (centerline can route end-to-end)');
        end

        function output_is_superset_of_input(tc)
            [D, mask_in] = synth_fragmented_vessel();
            mask_out = autoseg.reconnect_vessel_fragments(D, mask_in, struct('verbose', false));
            tc.verifyTrue(all(mask_out(mask_in)), 'must not drop any input voxel');
            tc.verifyGreaterThanOrEqual(nnz(mask_out), nnz(mask_in));
        end

        function only_adds_in_window_voxels(tc)
            % Anti-bridge invariant: every painted voxel already carries
            % contrast-grade HU in the source CT.
            [D, mask_in] = synth_fragmented_vessel();
            opts = struct('verbose', false, 'hu_lo', 150, 'hu_hi', 1400);
            mask_out = autoseg.reconnect_vessel_fragments(D, mask_in, opts);
            added = mask_out & ~mask_in;
            if any(added(:))
                hus = double(D.vol(added));
                tc.verifyGreaterThanOrEqual(min(hus), opts.hu_lo, ...
                    'no painting below the contrast window (no bridge through tissue)');
                tc.verifyLessThanOrEqual(max(hus), opts.hu_hi, ...
                    'no painting above the contrast window');
            end
        end

        function area_cap_rejects_offpath_marrow_blob(tc)
            % A large in-window slab (cross-section > vessel_max_mm2),
            % 26-connected to the vessel contrast, must be dropped by the
            % per-slice vessel-area cap and stay OUT of the mask — even
            % across iterations.
            [D, mask_in, probe_marrow, probe_vessel] = synth_fragmented_vessel(true);
            mask_out = autoseg.reconnect_vessel_fragments(D, mask_in, ...
                struct('verbose', false, 'vessel_max_mm2', 200));
            tc.verifyFalse(mask_out(probe_marrow(1), probe_marrow(2), probe_marrow(3)), ...
                'off-path marrow voxel (over-size cross-section) must be rejected');
            tc.verifyTrue(mask_out(probe_vessel(1), probe_vessel(2), probe_vessel(3)), ...
                'on-path vessel voxel must be retained');
        end

        function info_struct_has_documented_fields(tc)
            [D, mask_in] = synth_fragmented_vessel();
            [~, info] = autoseg.reconnect_vessel_fragments(D, mask_in, struct('verbose', false));
            req = {'added_voxels', 'iters_used', 'cc_before', 'cc_after', ...
                'converged', 'reason'};
            for k = 1:numel(req)
                tc.verifyTrue(isfield(info, req{k}), ...
                    sprintf('info missing field: %s', req{k}));
            end
        end

        function empty_mask_is_a_safe_noop(tc)
            [D, ~] = synth_fragmented_vessel();
            empty = false(size(D.vol));
            [mask_out, info] = autoseg.reconnect_vessel_fragments(D, empty, struct('verbose', false));
            tc.verifyEqual(nnz(mask_out), 0);
            tc.verifyEqual(info.added_voxels, 0);
        end
    end
end

% =========================================================================
function [D, mask, probe_marrow, probe_vessel] = synth_fragmented_vessel(add_marrow)
%SYNTH_FRAGMENTED_VESSEL  A contrast vessel that is present on every slice
%   but whose mask cores stagger > 1 voxel in-plane between consecutive
%   slices, so they are disconnected 3-D components. The CT carries a
%   continuous radius-3 contrast lumen around them.
    if nargin < 1; add_marrow = false; end
    sz = [60, 60, 120];
    rng(11);
    vol = -150 + 40 * randn(sz, 'single');     % soft-tissue baseline

    [yy, xx, zz] = ndgrid(1:sz(1), 1:sz(2), 1:sz(3));
    % Lumen centre drifts gently down the volume; radius 3 (continuous).
    cy = 30 + round((zz - 1) / (sz(3) - 1) * 8);
    cx = 28 + round((zz - 1) / (sz(3) - 1) * 6);
    lumen = (yy - cy).^2 + (xx - cx).^2 <= 9;   % radius 3
    vol(lumen) = 400 + 25 * randn(nnz(lumen), 1, 'single');

    % Mask cores: ONE voxel per slice, alternately offset ±2 columns from
    % the lumen centre so consecutive cores are Chebyshev-distance >= 2
    % apart (not 26-connected) — present on every slice, yet fragmented.
    mask = false(sz);
    for z = 1:sz(3)
        off = 2 * mod(z, 2) - 1;          % -1 or +1
        col = round(28 + (z - 1) / (sz(3) - 1) * 6) + 2 * off;  % +/- 2
        row = round(30 + (z - 1) / (sz(3) - 1) * 8);
        mask(row, col, z) = true;
    end

    probe_marrow = [1 1 1]; probe_vessel = [1 1 1];
    if add_marrow
        % A wide in-window slab (cross-section well over the cap),
        % in-plane-fused with the lumen across a short mid-vessel z-band
        % so that WITHOUT the area cap an imreconstruct flood would
        % swallow it. With the cap, the over-size fused component is
        % dropped from the candidate contrast on those slices.
        zb = zz >= 59 & zz <= 61;
        slab = (xx >= 5) & (xx <= 42) & (abs(yy - 38) <= 9) & zb;  % ~38x19 per slice
        vol(slab) = 350 + 20 * randn(nnz(slab), 1, 'single');
        probe_marrow = [42, 8, 60];        % deep in the slab, far off-path
        % Vessel probe on a CLEAN slice far from the slab: the lumen
        % centre, which the per-core flood thickens into.
        zc = 80;
        probe_vessel = [round(30 + (zc - 1) / (sz(3) - 1) * 8), ...
                        round(28 + (zc - 1) / (sz(3) - 1) * 6), zc];
    end

    D = struct();
    D.vol = int16(vol);
    D.pixel_mm = [0.7, 0.7];
    D.slice_spacing_mm = 0.7;
    D.slice_z_mm = (0:sz(3)-1) * 0.7;
    D.is_volume = true;
end
