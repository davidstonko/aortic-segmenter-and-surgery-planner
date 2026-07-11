%% DEMO_CENTERLINE  Phase 3 centerline pipeline on the JohnDoe1 CT.
%
%   1. Load the cached CT (from demo_phase3_ct.m / dicom_load).
%   2. Threshold-segment the contrast-enhanced aorta + iliacs.
%   3. Skeletonise (3D thinning, branch pruning).
%   4. Walk the longest skeleton path -> ordered polyline.
%   5. Convert voxel coords to mm.
%   6. Produce a QC figure: orthogonal MIPs with the polyline overlaid.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

clear; close all
this_dir = fileparts(mfilename('fullpath'));
cd(this_dir);

%% --- Load CT (cached) -------------------------------------------------
log_path = 'results/logs/ct_volume.mat';
if ~exist(log_path, 'file')
    error('demo_centerline:NoCT', ...
        'Cached CT not found. Run preprocess.dicom_load on the CT folder first.');
end
fprintf('Loading cached CT volume...\n');
load(log_path, 'D_ct');
fprintf('  Loaded %d × %d × %d at %.3f × %.3f × %.3f mm\n', ...
    size(D_ct.vol), D_ct.pixel_mm(1), D_ct.pixel_mm(2), D_ct.slice_spacing_mm);

%% --- Step 1: segment the aorta ---------------------------------------
fprintf('\n=== Step 1: threshold segmentation ===\n');
% Tight HU band for arterial blood pool. We DON'T erode — the iliacs
% are only ~5-6 mm radius (≈8-10 voxels diameter), and 3-voxel erosion
% breaks them. Instead we use the z_band to restrict to the abdomen +
% pelvis (cropping out heart and chest), so the largest component
% inside that slab is the aorta + iliacs without the heart pulling
% it elsewhere.
%
% Slice z values run from -1585 (last slice, pelvis floor) to -976
% (first slice, mid-chest). Abdominal aorta + iliacs live roughly in
% the bottom 50-60% of the volume.
N_slices = size(D_ct.vol, 3);
seg_opts = struct('HU_low', 200, 'HU_high', 400, ...
                  'min_voxels', 5e4, ...
                  'close_radius', 1, 'erode_radius', 0, ...
                  'fill_holes_2d', true, ...
                  'z_band', [round(0.40 * N_slices), N_slices]);
[mask, seg_info] = preprocess.segment_aorta_thresh(D_ct, seg_opts);
mL = sum(mask(:)) * D_ct.pixel_mm(1) * D_ct.pixel_mm(2) * D_ct.slice_spacing_mm / 1000;
fprintf('  Picked component:   %d voxels (%.1f mL)\n', ...
    seg_info.picked_component_size, mL);
fprintf('  Time:               %.1f s\n', seg_info.processing_time);

%% --- Step 2: skeletonise + walk path --------------------------------
fprintf('\n=== Step 2: skeletonise + walk longest path ===\n');
t0 = tic;
[skel, polyline_vox, R_vox] = preprocess.centerline_skel(mask, ...
    struct('min_branch_length', 50, 'smooth_window', 25, ...
           'min_radius_vox', 3));
fprintf('  Skeleton voxels:    %d\n', sum(skel(:)));
fprintf('  Path length:        %d nodes\n', size(polyline_vox, 1));
fprintf('  Time:               %.1f s\n', toc(t0));

%% --- Step 3: convert to mm -------------------------------------------
[Pv_mm, R_mm] = preprocess.centerline_to_mm(polyline_vox, R_vox, D_ct);
arc = [0; cumsum(vecnorm(diff(Pv_mm,1,1), 2, 2))];
fprintf('\n=== Step 3: arc length & radius diagnostics ===\n');
fprintf('  Total arc length:   %.1f mm\n', arc(end));
fprintf('  Lumen radius range: [%.2f, %.2f] mm\n', min(R_mm), max(R_mm));
fprintf('  Median radius:      %.2f mm\n', median(R_mm));

%% --- Save artefacts --------------------------------------------------
save('results/logs/centerline.mat', 'mask', 'skel', 'polyline_vox', ...
    'R_vox', 'Pv_mm', 'R_mm', 'arc', 'seg_info', 'seg_opts');
fprintf('\nSaved centerline to results/logs/centerline.mat\n');

%% --- QC figure: orthogonal MIPs with polyline overlay ----------------
fprintf('\nBuilding QC figure...\n');
fig = figure('Name', 'Phase 3: aorta + iliac centerline QC', ...
             'Color', 'w', 'Position', [40 40 1500 950]);
tl = tiledlayout(fig, 2, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
title(tl, sprintf('AINN/EVAR Phase 3 — centerline QC  |  %d-node polyline, total arc %.0f mm, median R = %.1f mm', ...
    size(Pv_mm,1), arc(end), median(R_mm)), 'FontWeight', 'bold');

% Axial MIP
nexttile(tl, 1);
ax_mip = squeeze(max(D_ct.vol, [], 3));
imagesc(ax_mip); colormap(gca, gray); axis image off
clim([-200 500]);   % CTA W=700 L=150
title('Axial MIP (full vol)')

% Coronal MIP + centerline overlay
nexttile(tl, 2);
co_mip = squeeze(max(D_ct.vol, [], 1)).';
imagesc(co_mip); colormap(gca, gray); axis image off
clim([-100 900]);   % MIP-appropriate window
hold on
% project centerline onto coronal (y collapsed) -> show (x_vox, z_vox)
plot(polyline_vox(:,2), polyline_vox(:,3), 'r-', 'LineWidth', 1.6);
plot(polyline_vox(1,2), polyline_vox(1,3), 'ro', 'MarkerFaceColor', 'r');
plot(polyline_vox(end,2), polyline_vox(end,3), 'rs', 'MarkerFaceColor', 'r');
title('Coronal MIP with centerline (red)')

% Sagittal MIP + centerline overlay
nexttile(tl, 3);
sa_mip = squeeze(max(D_ct.vol, [], 2)).';
imagesc(sa_mip); colormap(gca, gray); axis image off
clim([-100 900]);   % MIP-appropriate window
hold on
plot(polyline_vox(:,1), polyline_vox(:,3), 'r-', 'LineWidth', 1.6);
plot(polyline_vox(1,1), polyline_vox(1,3), 'ro', 'MarkerFaceColor', 'r');
plot(polyline_vox(end,1), polyline_vox(end,3), 'rs', 'MarkerFaceColor', 'r');
title('Sagittal MIP with centerline (red)')

% Mask MIP coronal
nexttile(tl, 4);
mask_co = squeeze(max(mask, [], 1)).';
imagesc(mask_co); colormap(gca, [0 0 0; 0.85 0.10 0.10]);
axis image off
title('Segmentation mask, coronal MIP')

% Radius along arc length
nexttile(tl, 5);
plot(arc, R_mm, '-', 'Color', [0.10 0.30 0.65], 'LineWidth', 1.6);
grid on
xlabel('arc length s (mm)'); ylabel('inscribed-sphere radius R (mm)')
title('Lumen radius profile')
ylim_pad = max(0, min(R_mm) - 1);
ylim([ylim_pad, max(R_mm)*1.05])

% 3D centerline view
nexttile(tl, 6);
plot3(Pv_mm(:,1), Pv_mm(:,2), Pv_mm(:,3), '-', ...
      'Color', [0.10 0.30 0.65], 'LineWidth', 2.0); hold on
plot3(Pv_mm(1,1), Pv_mm(1,2), Pv_mm(1,3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
plot3(Pv_mm(end,1), Pv_mm(end,2), Pv_mm(end,3), 'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
grid on; axis equal; view(45, 20)
xlabel('x (mm)'); ylabel('y (mm)'); zlabel('z (mm)')
title('Centerline in patient coords')

exportgraphics(fig, 'results/figures/centerline_qc.png', 'Resolution', 200);
savefig(fig, 'results/figures/centerline_qc.fig');
fprintf('Saved QC figure to results/figures/centerline_qc.{fig,png}\n');
