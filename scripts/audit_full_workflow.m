function audit_full_workflow()
%AUDIT_FULL_WORKFLOW  Drive the GUI through every step on the JohnDoe1
%   EVAR case, capturing screenshots at each step and reporting any
%   bug that fires. Use this as the regression test for the whole UI.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    out_dir = fullfile(proj, 'results', 'figures', 'audit');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end

    fprintf('=== FULL WORKFLOW AUDIT — JohnDoe1 EVAR ===\n\n');

    % --- 0. Load JohnDoe1 CT (cached .mat) and downsample for audit speed
    cache = fullfile(proj, 'results', 'logs', 'ct_volume.mat');
    if exist(cache, 'file')
        fprintf('Loading cached JohnDoe1 CT from %s …\n', cache);
        S = load(cache);
        if isfield(S, 'D_ct'); D = S.D_ct;
        elseif isfield(S, 'D'); D = S.D;
        else
            fns = fieldnames(S);
            for k = 1:numel(fns)
                if isstruct(S.(fns{k})) && isfield(S.(fns{k}), 'vol')
                    D = S.(fns{k}); break;
                end
            end
        end
    else
        % Resolve the JohnDoe1 DICOM path: prefer the JOHNDOE1_DICOM env var,
        % fall back to the sibling directory of the project root
        % (where JohnDoe1 EVAR/ lives alongside phase-3-real-EVAR/).
        johndoe1 = getenv('JOHNDOE1_DICOM');
        if isempty(johndoe1)
            parent = fileparts(proj);
            johndoe1 = fullfile(parent, 'JohnDoe1 EVAR', 'export');
        end
        if ~isfolder(johndoe1)
            error('audit_full_workflow:no_johndoe1', ...
                ['JohnDoe1 CT cache not found at %s, and the raw DICOM ' ...
                 'directory does not exist at %s. Set the JOHNDOE1_DICOM ' ...
                 'environment variable to point at the DICOM folder.'], ...
                cache, johndoe1);
        end
        fprintf('Loading raw JohnDoe1 DICOM from %s …\n', johndoe1);
        D = preprocess.dicom_load(johndoe1, true);
    end
    fprintf('  raw vol size: %s, pixel %s, slice %.2f mm\n', ...
        mat2str(size(D.vol)), mat2str(D.pixel_mm), D.slice_spacing_mm);
    % Downsample 2× along all axes to keep the audit interactive.
    D.vol = D.vol(1:2:end, 1:2:end, 1:2:end);
    if isfield(D, 'slice_z_mm')
        D.slice_z_mm = D.slice_z_mm(1:2:end);
    end
    D.pixel_mm = D.pixel_mm * 2;
    D.slice_spacing_mm = D.slice_spacing_mm * 2;
    fprintf('  audit vol size (2× downsampled): %s\n\n', mat2str(size(D.vol)));

    % --- 1. Construct the app -------------------------------------
    fprintf('Step 1 — construct app + capture empty state…\n');
    a = app.AorticCenterlineApp();
    cleanup = onCleanup(@() delete(a));
    drawnow; pause(0.4);
    a.captureMain(fullfile(out_dir, '01_empty_state.png'));

    % --- 1b. Load the volume programmatically ---------------------
    fprintf('Step 1b — load JohnDoe1 CT into the app…\n');
    a.loadVolumeStruct(D);
    drawnow; pause(1.0);
    a.captureMain(fullfile(out_dir, '02_after_load.png'));

    % --- 2. Auto-segment + crop now happens DURING doLoad. Just
    %         verify the post-load state has a mask applied.
    fprintf('Step 2 — verify auto-segment-on-load fired…\n');
    sz_after = a.volSize();
    if ~isequal(sz_after, [256 256 610])
        fprintf('  ✓ vol auto-cropped: %s (was 256×256×610)\n', ...
            mat2str(sz_after));
    else
        fprintf('  ✗ vol NOT cropped — auto-segment-on-load failed\n');
    end
    drawnow; pause(0.3);
    a.captureMain(fullfile(out_dir, '03_after_segment.png'));
    % Capture in BOTH 3D MIP and 3D Volume modes so we can verify the
    % vessel-only display works in each render.
    a.setView('3d');     drawnow; pause(0.5);
    a.captureMain(fullfile(out_dir, '03b_after_autocrop_3dmip.png'));
    a.setView('3dvol');  drawnow; pause(0.8);
    a.captureMain(fullfile(out_dir, '03c_after_autocrop_3dvol.png'));
    a.setView('3d');     drawnow; pause(0.3);

    % --- 3. Step 3 auto-fills seeds from the cropped mask ------
    fprintf('Step 3 — auto-seeds populated by buildStep3…\n');
    drawnow; pause(0.3);
    a.captureMain(fullfile(out_dir, '04_after_seeds.png'));

    % --- 4. Compute centerline ------------------------------------
    fprintf('Step 4 — compute centerlines (skeleton method)…\n');
    a.gotoStep(4);
    drawnow; pause(0.3);
    try
        a.computeCenterline();
        fprintf('  centerline OK\n');
    catch ME
        fprintf('  centerline FAILED: %s\n', ME.message);
    end
    drawnow; pause(0.5);
    a.captureMain(fullfile(out_dir, '05_after_centerline.png'));

    % --- 4b. Switch to CPR view + scrub cross-section ------------
    fprintf('Step 4b — switch to CPR view + scrub cross-section…\n');
    try
        a.setView('cpr');
        drawnow; pause(0.8);
        a.captureMain(fullfile(out_dir, '05b_cpr.png'));
        % Scrub to ~70% along arc (typically inside the aorta) and
        % capture the cross-section pane.
        L = a.cprMaxArcMm();
        if L > 0
            a.scrubCPRArc(L * 0.7);
        end
        drawnow; pause(0.5);
        a.captureMain(fullfile(out_dir, '05b2_cpr_xsec.png'));
        fprintf('  CPR + cross-section captured\n');
    catch ME
        fprintf('  CPR view failed: %s\n', ME.message);
    end
    % --- 4b2. Right-click centerline edit (insert / delete / move) ---
    fprintf('Step 4b2 — exercise right-click centerline edit…\n');
    cs = a.currentCaseStruct();
    Pv = cs.Pv_mm_right;
    n_R = size(Pv, 1);
    if n_R > 100
        % Read the voxel coords of a midpoint node directly via the
        % public API — no mm round-trip required.
        click_vox = a.polylineRightNodeVox(round(n_R/2)) + [3 2 0];
        try
            n_before = n_R;
            a.editCenterlineAt('insert', click_vox, 'right');
            cs1 = a.currentCaseStruct(); n1 = size(cs1.Pv_mm_right, 1);
            a.editCenterlineAt('delete', click_vox, 'right');
            cs2 = a.currentCaseStruct(); n2 = size(cs2.Pv_mm_right, 1);
            a.editCenterlineAt('move',   click_vox, 'right');
            cs3 = a.currentCaseStruct(); n3 = size(cs3.Pv_mm_right, 1);
            fprintf('  insert: %d → %d, delete: %d → %d, move: %d → %d\n', ...
                n_before, n1, n1, n2, n2, n3);
            assert(n1 == n_before + 1, 'insert: bad node count');
            assert(n2 == n_before,     'delete: bad node count');
            assert(n3 == n_before,     'move: bad node count');
            fprintf('  centerline edit ops verified\n');
        catch ME
            fprintf('  centerline edit failed: %s\n', ME.message);
        end
    end

    % --- 4c. Back to 3D Volume (the default landing view) ---
    try
        a.setView('3dvol');
        drawnow; pause(0.5);
        a.captureMain(fullfile(out_dir, '05c_3dvol_with_centerline.png'));
    catch
    end
    % Switch back to 3D MIP for Step 5 work
    a.setView('3d'); drawnow; pause(0.3);

    % --- 5. Set landmarks + view measurements ---------------------
    fprintf('Step 5 — set landmarks + measurements…\n');
    a.gotoStep(5);
    drawnow; pause(0.3);
    cs = a.currentCaseStruct();
    n_R = size(cs.Pv_mm_right, 1);
    if n_R > 10
        a.setLandmark('lowest_renal',  n_R - max(2, round(0.05 * n_R)));
        a.setLandmark('aortic_bifurc', cs.bifurc_node_right);
    end
    drawnow; pause(0.3);
    % Make sure labels are visible — back to 3D MIP
    a.setView('3d');
    drawnow; pause(0.4);
    a.captureMain(fullfile(out_dir, '06_after_landmarks.png'));
    fprintf('  landmarks set: lowest_renal=%d, aortic_bifurc=%d\n', ...
        n_R - max(2, round(0.05 * n_R)), cs.bifurc_node_right);

    % --- 6. Export step ------------------------------------------
    fprintf('Step 6 — capture export panel…\n');
    a.gotoStep(6);
    drawnow; pause(0.3);
    a.captureMain(fullfile(out_dir, '07_export_panel.png'));

    % --- VISUAL AUDIT PHASE ---------------------------------------
    fprintf('\n=== VISUAL AUDIT ===\n');
    fails = {};
    info = a.polylineRightInfo();
    if info.n > 0
        sz = a.volSize();
        % 1. Centerline must stay inside the (cropped) volume bounds.
        if info.min_y < 0.5 || info.max_y > sz(1) + 0.5 || ...
           info.min_x < 0.5 || info.max_x > sz(2) + 0.5 || ...
           info.min_z < 0.5 || info.max_z > sz(3) + 0.5
            fails{end+1} = sprintf( ...
                'centerline out of vol bounds: y[%.0f, %.0f] x[%.0f, %.0f] z[%.0f, %.0f] vs vol %s', ...
                info.min_y, info.max_y, info.min_x, info.max_x, ...
                info.min_z, info.max_z, mat2str(sz)); %#ok<AGROW>
        else
            fprintf('  ✓ centerline stays inside vol bounds (y=%g-%g, x=%g-%g, z=%g-%g)\n', ...
                info.min_y, info.max_y, info.min_x, info.max_x, info.min_z, info.max_z);
        end
        % 2. The CPR image must have non-trivial content (body tissue,
        %    not all air). On a good CPR most pixels are mid-grey to
        %    bright; on a bad one (centerline went off into air) most
        %    pixels are near-black.
        try
            cpr_png = fullfile(out_dir, '05b_cpr.png');
            if exist(cpr_png, 'file')
                cpr_rgb = imread(cpr_png);
                cpr_gs  = double(mean(cpr_rgb, 3));
                m_cpr   = mean(cpr_gs(:));
                if m_cpr > 60
                    fprintf('  ✓ CPR has body tissue content (mean intensity %.0f)\n', m_cpr);
                else
                    fails{end+1} = sprintf( ...
                        'CPR mostly air — mean intensity %.0f < 60', m_cpr); %#ok<AGROW>
                end
            end
        catch ME
            fprintf('  ! CPR content check failed: %s\n', ME.message);
        end

        % 3. The right polyline radii (distance-transform values at
        %    each node) should mostly be > 1 — i.e. the centerline
        %    actually walked through the segmentation. Many nodes at
        %    R = 0 means the line escaped the mask.
        if isfield(cs, 'R_mm') && ~isempty(cs.R_mm)
            r_zero_frac = mean(cs.R_mm < 1.0);
            if r_zero_frac < 0.10
                fprintf('  ✓ centerline stayed inside mask (%.1f%% nodes at R<1mm)\n', ...
                    100 * r_zero_frac);
            else
                fails{end+1} = sprintf( ...
                    'centerline escapes mask: %.1f%% of nodes have R<1mm', ...
                    100 * r_zero_frac); %#ok<AGROW>
            end
        end
    end

    if isempty(fails)
        fprintf('=== ALL VISUAL CHECKS PASS ===\n');
    else
        fprintf('=== VISUAL AUDIT FAILED ===\n');
        for k = 1:numel(fails); fprintf('  ✗ %s\n', fails{k}); end
    end

    fprintf('\n=== AUDIT COMPLETE ===\n');
    fprintf('Screenshots in: %s\n', out_dir);
end

% =========================================================================
function [pP, pR, pL] = pick_seeds_from_mask(~, ~, ~)
%PICK_SEEDS_FROM_MASK  Stub for future use; not currently relied on.
    pP = []; pR = []; pL = [];
end

function [pP, pR, pL] = pick_seeds_geometry(D, mask)
%PICK_SEEDS_GEOMETRY  Pick seeds from the geometry of the mask:
%   - proximal:  voxel closest to z=top of mask, near medial sagittal plane
%   - right CFA: voxel at z=bottom of mask, x < center (patient's right)
%   - left CFA:  voxel at z=bottom of mask, x > center (patient's left)
    sz = size(mask);
    [yy, xx, zz] = ndgrid(1:sz(1), 1:sz(2), 1:sz(3));
    keep = mask;
    z_min_top    = min(zz(keep));   % proximal end of segmented region
    z_max_bottom = max(zz(keep));

    % Proximal: top 5 % of z, sample nearest the (y,x) centroid of those voxels
    z_band_p = zz >= z_min_top & zz < z_min_top + max(3, round(0.05*sz(3)));
    band = keep & z_band_p;
    if any(band(:))
        ys = yy(band); xs = xx(band); zs = zz(band);
        cy = round(median(ys)); cx = round(median(xs)); cz = round(median(zs));
        pP = [cy, cx, cz];
    else
        pP = [];
    end

    % CFA seeds: bottom 5 % of z, separate left vs right by x relative to median
    z_band_d = zz <= z_max_bottom & zz > z_max_bottom - max(3, round(0.05*sz(3)));
    band = keep & z_band_d;
    if any(band(:))
        ys = yy(band); xs = xx(band); zs = zz(band);
        x_med = median(xs);
        is_R = xs < x_med;
        is_L = xs > x_med;
        if any(is_R)
            pR = [round(median(ys(is_R))), round(median(xs(is_R))), round(median(zs(is_R)))];
        else
            pR = [];
        end
        if any(is_L)
            pL = [round(median(ys(is_L))), round(median(xs(is_L))), round(median(zs(is_L)))];
        else
            pL = [];
        end
    else
        pR = []; pL = [];
    end
end
