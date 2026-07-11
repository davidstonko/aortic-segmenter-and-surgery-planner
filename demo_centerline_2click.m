%% DEMO_CENTERLINE_2CLICK  Phase 3 centerline via 2-click + slice tracking.
%
%   This is the recommended Phase 3 workflow per the project plan: the
%   user identifies two voxels on the CT — one at the proximal end of
%   the desired centerline (typically the suprarenal aorta or the
%   aortic arch) and one at the distal end (typically an iliac
%   terminus). The tracker walks slice-by-slice between them, locking
%   onto the aorta cross-section using local thresholding +
%   roundness + continuity from the previous slice.
%
%   For 25 patients × 2 clicks ≈ 25 minutes of viewer time, this is
%   the cheapest reliable centerline approach short of installing
%   TotalSegmentator.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

clear; close all
this_dir = fileparts(mfilename('fullpath'));
cd(this_dir);

%% --- Load CT (cached) -------------------------------------------------
load('results/logs/ct_volume.mat', 'D_ct');
fprintf('CT loaded: %d × %d × %d at %.3f × %.3f × %.3f mm\n', ...
    size(D_ct.vol), D_ct.pixel_mm(1), D_ct.pixel_mm(2), D_ct.slice_spacing_mm);

%% --- USER SEEDS -------------------------------------------------------
% Two voxel coordinates [y, x, z] for the proximal and distal ends of
% the desired centerline. Two ways to set them:
%
%   1. Interactive: open the seed picker — opens a viewer at CTA
%      window/level, scroll axial slider, click to pick:
%
%         seeds = preprocess.seed_picker(D_ct);
%         seed_start = seeds(1, :);
%         seed_end   = seeds(2, :);
%
%   2. Hardcoded (faster for re-runs once you know the right slices).
%      Edit the values below.
USE_PICKER = false;     % set true to launch the click-based picker
if USE_PICKER
    seeds = preprocess.seed_picker(D_ct);
    seed_start = seeds(1, :);
    seed_end   = seeds(2, :);
else
    % Default seeds for the JohnDoe1 CT (volume now sorted descending z,
    % so slice 1 = head). Programmatic search at this descending-z
    % orientation found at slice 200 a clean aortic lumen at
    % (y=353, x=302) with HU 596, area 1298 voxels (≈10mm radius);
    % and at slice 120 an iliac at (367, 233) HU 417.
    seed_start = [353, 302,  200];  % suprarenal abdominal aorta (z=-1076)
    seed_end   = [367, 233, 1100];  % distal right iliac (z=-1526)
end

fprintf('\nSeeds:\n');
fprintf('  start (proximal): [y=%d, x=%d, z=%d]\n', seed_start);
fprintf('  end   (distal):   [y=%d, x=%d, z=%d]\n', seed_end);

%% --- Track aorta slice-by-slice ---------------------------------------
% Defaults tuned on the JohnDoe1 case (abdominal aorta + iliacs):
%   max_xy_jump_mm = 3   — true inter-slice centerline motion is < 1 mm
%                         on a clean trajectory; a 3 mm cap rejects
%                         component-swap excursions without truncating
%                         the iliac bifurcation kink.
%   min_radius_mm  = 2.0 — drops contrast-filled subcentimeter branches
%                         (mesenteric, renal) while still capturing the
%                         distal iliac (~3-5 mm radius).
opts = struct('HU_low', 200, 'HU_high', 450, ...
              'max_xy_jump_mm', 3, ...
              'max_radius_mm', 15, ...
              'min_radius_mm', 2.0, ...
              'roundness_min', 0.4);

[mask, centroids_vox, R_vox, info] = preprocess.track_aorta_2click( ...
    D_ct, seed_start, seed_end, opts);

fprintf('\n=== Tracker results ===\n');
fprintf('  Slices kept:    %d / %d\n', info.slices_kept, info.slices_total);
fprintf('  Z range:        %d to %d (slices)\n', info.first_z, info.last_z);
fprintf('  Time:           %.2f s\n', info.processing_time);

%% --- Convert to mm ----------------------------------------------------
[Pv_mm, R_mm] = preprocess.centerline_to_mm(centroids_vox, R_vox, D_ct);
arc = [0; cumsum(vecnorm(diff(Pv_mm,1,1), 2, 2))];
fprintf('  Arc length:     %.1f mm\n', arc(end));
fprintf('  Radius range:   [%.2f, %.2f] mm\n', min(R_mm), max(R_mm));
fprintf('  Median radius:  %.2f mm\n', median(R_mm));

%% --- Save artefacts ---------------------------------------------------
save('results/logs/centerline_2click.mat', 'mask', 'centroids_vox', ...
    'R_vox', 'Pv_mm', 'R_mm', 'arc', 'info', ...
    'seed_start', 'seed_end');
fprintf('Saved to results/logs/centerline_2click.mat\n');

%% --- QC figure --------------------------------------------------------
fig = figure('Name', 'Phase 3 — 2-click aortic centerline', ...
             'Color', 'w', 'Position', [40 40 1500 950]);
tl = tiledlayout(fig, 2, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
title(tl, sprintf('AINN/EVAR Phase 3 — 2-click centerline | %d slices kept | arc %.0f mm | median R %.1f mm', ...
    info.slices_kept, arc(end), median(R_mm)), 'FontWeight', 'bold');

% --- Use the TRACKED MASK as the "vessel-only" background -----------
% A simple HU threshold (200-500) would still capture cancellous bone
% from vertebrae (150-300 HU) and other ambiguous structures. The
% tracker's per-slice mask is already a clean aorta-only segmentation
% — use it directly as the "vessel-only" visualization.

% Coronal MIP — TRACKED AORTA MASK ONLY
nexttile(tl, 1);
co_mip_mask = squeeze(max(mask, [], 1)).';
% Soft gray body silhouette behind for context
silhouette = squeeze(max(D_ct.vol > -200, [], 1)).';
imagesc(2*silhouette + 5*co_mip_mask);
colormap(gca, [1 1 1; 0.92 0.92 0.94; 0.88 0.88 0.90; ...   % background + faint body
               1.0 0.55 0.20]);                              % vessel highlight
axis image off
hold on
plot(centroids_vox(:,2), centroids_vox(:,3), 'k-', 'LineWidth', 1.8);
plot(seed_start(2), seed_start(3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
plot(seed_end(2),   seed_end(3),   'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
title('Coronal — tracked aorta + body silhouette')

% Sagittal MIP — TRACKED AORTA MASK ONLY
nexttile(tl, 2);
sa_mip_mask = squeeze(max(mask, [], 2)).';
silhouette_sa = squeeze(max(D_ct.vol > -200, [], 2)).';
imagesc(2*silhouette_sa + 5*sa_mip_mask);
colormap(gca, [1 1 1; 0.92 0.92 0.94; 0.88 0.88 0.90; ...
               1.0 0.55 0.20]);
axis image off
hold on
plot(centroids_vox(:,1), centroids_vox(:,3), 'k-', 'LineWidth', 1.8);
plot(seed_start(1), seed_start(3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
plot(seed_end(1),   seed_end(3),   'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
title('Sagittal — tracked aorta + body silhouette')

% Mask coronal MIP
nexttile(tl, 3);
mask_co = squeeze(max(mask, [], 1)).';
imagesc(mask_co); colormap(gca, [0 0 0; 0.85 0.10 0.10]); axis image off
title('Tracked aorta mask (coronal MIP)')

% Radius profile
nexttile(tl, 4, [1 2]);
plot(arc, R_mm, '-', 'Color', [0.10 0.30 0.65], 'LineWidth', 1.6);
grid on; xlabel('arc length s (mm)'); ylabel('inscribed-sphere radius R (mm)')
title('Lumen radius along the tracked centerline')
ylim([0, max(R_mm)*1.05])

% 3D
nexttile(tl, 6);
plot3(Pv_mm(:,1), Pv_mm(:,2), Pv_mm(:,3), '-', ...
      'Color', [0.10 0.30 0.65], 'LineWidth', 2.0); hold on
plot3(Pv_mm(1,1), Pv_mm(1,2), Pv_mm(1,3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
plot3(Pv_mm(end,1), Pv_mm(end,2), Pv_mm(end,3), 'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
grid on; axis equal; view(45, 20)
xlabel('x (mm)'); ylabel('y (mm)'); zlabel('z (mm)')
title('Centerline in patient coords')

exportgraphics(fig, 'results/figures/centerline_2click_qc.png', 'Resolution', 200);
savefig(fig, 'results/figures/centerline_2click_qc.fig');
fprintf('Saved QC to results/figures/centerline_2click_qc.{fig,png}\n');
