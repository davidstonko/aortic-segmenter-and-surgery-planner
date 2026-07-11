function [mask_out, info] = reconnect_vessel_fragments(D, mask_in, opts)
%AUTOSEG.RECONNECT_VESSEL_FRAGMENTS  Reconnect vessel fragments that a
%   per-slice walker / TS labelling severed from the main vessel mask by
%   small IN-PLANE connectivity breaks, by iterating a shell-confined,
%   HU-gated, vessel-area-capped region grow through GENUINE contrast.
%
%   [MASK_OUT, INFO] = autoseg.reconnect_vessel_fragments(D, MASK_IN, OPTS)
%
%   WHY THIS EXISTS
%       On a well-opacified arterial-phase CTA the aorta + iliacs + CFAs
%       form one continuous contrast tube, but TS + the slice-by-slice
%       walker sometimes label the distal iliac / CFA as a string of
%       small 3-D components that are each present on their own z-slices
%       yet are offset enough in-plane from slice to slice that they are
%       NOT 26-connected to one another (no z-gap — the mask is non-empty
%       on every slice — purely an in-plane stagger). Step 6b's
%       keep-largest-CC then drops the whole distal string, truncating the
%       centerline (observed on the JohnDoe1 case: right CFA chain z=1047..1219
%       dropped, centerline stopped 87 mm short of the FOV bottom).
%
%   WHY A SINGLE imreconstruct IS NOT ENOUGH
%       A one-shot shell flood (run_planner_headless step 3c) only reaches
%       ~one shell radius beyond the existing mask, so a chain of offset
%       fragments stays split. Rebuilding the shell around the GROWING
%       mask each pass lets the flood crawl from fragment to fragment along
%       the genuine contrast that already bridges them, fusing the chain.
%
%   BRIDGE-FREE BY CONSTRUCTION
%       The only voxels added are voxels that ALREADY carry bolus-grade HU
%       in the source CT (opts.hu_lo..hu_hi), are 26-connected to the
%       existing mask, and lie within opts.shell_radius_mm of it. No
%       synthetic voxels are painted; no straight tubes through tissue.
%       Three leak guards bound the grow on lower-contrast scans:
%         (1) per-slice vessel-area cap (opts.vessel_max_mm2) drops bowel /
%             bladder / large marrow blobs from the candidate contrast,
%         (2) shell confinement keeps the flood within a thin tube of the
%             tracked vessel, and
%         (3) opts.max_iters bounds the total crawl distance, so a thin
%             in-window structure touching the vessel cannot be followed
%             indefinitely.
%       The grow is also restricted to z >= opts.z_lo (the pelvis) so it
%       can never wander into the chest.
%
%   INPUT
%       D        struct from preprocess.dicom_load (.vol, .pixel_mm,
%                .slice_spacing_mm).
%       MASK_IN  logical Y×X×Z vessel mask (pre keep-largest-CC).
%       OPTS     struct, optional:
%         .hu_lo            contrast lower bound (default 150 HU).
%         .hu_hi            contrast upper bound (default 1400 HU).
%         .shell_radius_mm  tube radius around the growing mask (default 5).
%         .vessel_max_mm2   per-slice in-plane area cap (default 400).
%         .max_iters        max grow passes (default 8).
%         .z_lo             lowest z-slice to allow growth from/into
%                           (default 1 = whole volume; callers pass the
%                           pelvis floor for speed + safety).
%         .verbose          default true.
%
%   OUTPUT
%       MASK_OUT  logical — MASK_IN union the reconnected contrast voxels
%                 (always a superset of MASK_IN).
%       INFO      struct: .added_voxels, .iters_used, .cc_before,
%                 .cc_after, .converged, .reason.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D       (1,1) struct
        mask_in logical
        opts    (1,1) struct = struct()
    end

    if ~isfield(opts, 'hu_lo');           opts.hu_lo = 150;            end
    if ~isfield(opts, 'hu_hi');           opts.hu_hi = 1400;           end
    if ~isfield(opts, 'shell_radius_mm'); opts.shell_radius_mm = 5;    end
    if ~isfield(opts, 'vessel_max_mm2');  opts.vessel_max_mm2 = 400;   end
    if ~isfield(opts, 'max_iters');       opts.max_iters = 8;          end
    if ~isfield(opts, 'z_lo');            opts.z_lo = 1;               end
    if ~isfield(opts, 'verbose');         opts.verbose = true;         end

    sz = size(mask_in);
    if numel(sz) < 3; sz(3) = 1; end
    if ~isequal(size(D.vol), sz)
        error('reconnect_vessel_fragments:SizeMismatch', ...
            'mask_in size %s != D.vol size %s', mat2str(sz), mat2str(size(D.vol)));
    end

    cc_before = numel(bwconncomp(mask_in, 26).PixelIdxList);
    n_in = nnz(mask_in);

    if ~any(mask_in(:))
        mask_out = mask_in;
        info = struct('added_voxels', 0, 'iters_used', 0, ...
            'cc_before', 0, 'cc_after', 0, 'converged', true, ...
            'reason', 'empty input mask');
        return;
    end

    pix_mm  = abs(D.pixel_mm(1));
    shell_r = max(2, round(opts.shell_radius_mm / pix_mm));
    vmax    = round(opts.vessel_max_mm2 / pix_mm^2);
    se      = strel('sphere', shell_r);

    % --- Restrict the working volume to the pelvis z-band for speed +
    %     safety. The aorta above z_lo is left untouched. Then tighten to
    %     the in-plane bounding box of the mask in that band (padded by
    %     the shell radius so the dilation has room) — the iterative
    %     dilate/reconstruct is the cost driver and the pelvis mask only
    %     occupies a fraction of the 512×512 field. ---
    z_lo = max(1, round(opts.z_lo));
    z_hi = sz(3);

    band = false(sz); band(:, :, z_lo:z_hi) = mask_in(:, :, z_lo:z_hi);
    if ~any(band(:))
        mask_out = mask_in;
        info = struct('added_voxels', 0, 'iters_used', 0, ...
            'cc_before', cc_before, 'cc_after', cc_before, ...
            'converged', true, 'z_band', [z_lo, z_hi], ...
            'shell_r_vox', shell_r, ...
            'reason', 'no mask voxels in pelvis band — nothing to reconnect');
        if opts.verbose
            fprintf('[reconnect_vessel_fragments] %s\n', info.reason);
        end
        return;
    end
    pad = shell_r + 1;
    [ri, ci, zi] = ind2sub(sz, find(band));
    r0 = max(1, min(ri) - pad);  r1 = min(sz(1), max(ri) + pad);
    c0 = max(1, min(ci) - pad);  c1 = min(sz(2), max(ci) + pad);
    z0 = max(1, min(zi) - pad);  z1 = min(sz(3), max(zi) + pad);
    rc = r0:r1;  cc_ = c0:c1;  zc = z0:z1;

    vol_c  = D.vol(rc, cc_, zc);
    mask_c = mask_in(rc, cc_, zc);

    % Candidate contrast in the cropped band, vessel-area-capped per slice
    % so the flood can only travel through vessel-calibre contrast.
    contrast = (vol_c >= opts.hu_lo) & (vol_c <= opts.hu_hi);
    contrast = autoseg.drop_big_inplane_cc(contrast, vmax);

    % --- Iterative shell-confined region grow ---
    grown = mask_c;
    prev  = -1;
    iters_used = 0;
    converged  = false;
    for it = 1:opts.max_iters
        shell = imdilate(grown, se);
        grown = imreconstruct(grown, grown | (contrast & shell), 26);
        iters_used = it;
        n = nnz(grown);
        if n == prev
            converged = true;
            break;
        end
        prev = n;
    end

    mask_out = mask_in;
    mask_out(rc, cc_, zc) = grown;

    added = nnz(mask_out) - n_in;
    cc_after = numel(bwconncomp(mask_out, 26).PixelIdxList);

    info = struct( ...
        'added_voxels', added, ...
        'iters_used',   iters_used, ...
        'cc_before',    cc_before, ...
        'cc_after',     cc_after, ...
        'converged',    converged, ...
        'z_band',       [z_lo, z_hi], ...
        'shell_r_vox',  shell_r, ...
        'reason', sprintf(['Iterative shell-confined HU[%g,%g] grow ' ...
            '(shell %.0f mm, cap %.0f mm^2, %d/%d passes%s): +%d vox, ' ...
            '%d -> %d 3D-CCs.'], opts.hu_lo, opts.hu_hi, ...
            opts.shell_radius_mm, opts.vessel_max_mm2, iters_used, ...
            opts.max_iters, ternary(converged, ' converged', ''), ...
            added, cc_before, cc_after));

    if opts.verbose
        fprintf('[reconnect_vessel_fragments] %s\n', info.reason);
    end
end

function s = ternary(cond, a, b)
    if cond; s = a; else; s = b; end
end
