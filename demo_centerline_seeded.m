%% DEMO_CENTERLINE_SEEDED  Phase 3 centerline with user-picked seeds.
%
%   Path B of the centerline plan: the user picks landmark voxels
%   (e.g. proximal aorta, iliac bifurcation, iliac terminus), and the
%   function walks the shortest path through the radius-filtered
%   skeleton between those landmarks in order.
%
%   This is more robust than the longest-path heuristic in
%   demo_centerline.m: it gives the user control over which centerline
%   gets returned, and works correctly even when the segmentation
%   pulls in extraneous structures.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

clear; close all
this_dir = fileparts(mfilename('fullpath'));
cd(this_dir);

%% --- Load CT + reuse the cached mask from demo_centerline ------------
log_path  = 'results/logs/ct_volume.mat';
seg_path  = 'results/logs/centerline.mat';
if ~exist(log_path, 'file');  error('Run demo_centerline first.'); end
if ~exist(seg_path, 'file');  error('Run demo_centerline first.'); end
load(log_path, 'D_ct');
load(seg_path, 'mask');

fprintf('Building skeleton graph...\n');
t0 = tic;
% Permissive skeleton (no radius filter) so the graph stays connected
% from aorta through iliacs, but with VMTK-style radius weighting on
% edges (1/R^2) so the shortest path prefers fat-tube routes (aorta)
% over thin-branch detours.
S = preprocess.build_skeleton_graph(mask, ...
        struct('min_branch_length', 30, 'min_radius_vox', 0, ...
               'radius_weight_pow', 2));
fprintf('  Skeleton: %d voxels, %d edges (%.1f s)\n', ...
    size(S.voxels, 1), numedges(S.graph), toc(t0));

%% --- Define landmark seeds -------------------------------------------
% Voxel coordinates [y, x, z] of three landmarks. These are illustrative
% values for the JohnDoe1 CT; the user can iterate by clicking on the
% viewer and reading off coordinates from the metadata panel.
%
% For this demo we use the approximate location of:
%   1. Suprarenal abdominal aorta: above the kidneys, anterior-midline
%   2. Iliac bifurcation: where the aorta splits
%   3. Right external iliac terminus: pelvic floor
seeds = [
    220, 250,  650;        % suprarenal aorta (slice ~650 of 1219)
    270, 250,  900;        % aortic bifurcation (slice ~900)
    320, 200, 1100;        % right iliac, distal
];
fprintf('\n%d landmark seeds (voxel coords [y x z]):\n', size(seeds, 1));
disp(seeds);

%% --- Walk the centerline through the seeds ---------------------------
fprintf('Walking shortest path through skeleton graph...\n');
try
    [polyline_vox, R_vox, info] = preprocess.centerline_seeds(S, seeds, ...
        struct('smooth_window', 25));
    fprintf('  Polyline:           %d nodes\n', size(polyline_vox, 1));
    fprintf('  Seed→skel distance: %.1f voxels (max), %.1f (mean)\n', ...
        max(info.seed_distances), mean(info.seed_distances));
    if max(info.seed_distances) > 30
        warning('demo_centerline_seeded:FarSeeds', ...
            'Some seeds are far from any skeleton voxel — adjust seeds or loosen min_radius_vox.');
    end
catch ME
    fprintf('  FAILED: %s\n', ME.message);
    fprintf('  → Likely cause: seeds in different connected components.\n');
    fprintf('  → Try seeds along a known continuous segment, or loosen min_radius_vox.\n');
    return;
end

%% --- Convert to mm + summary -----------------------------------------
[Pv_mm, R_mm] = preprocess.centerline_to_mm(polyline_vox, R_vox, D_ct);
arc = [0; cumsum(vecnorm(diff(Pv_mm,1,1), 2, 2))];
fprintf('\nArc length:     %.1f mm\n', arc(end));
fprintf('Radius range:   [%.2f, %.2f] mm\n', min(R_mm), max(R_mm));
fprintf('Median radius:  %.2f mm\n', median(R_mm));

%% --- Save + QC figure -------------------------------------------------
save('results/logs/centerline_seeded.mat', 'polyline_vox', 'R_vox', ...
    'Pv_mm', 'R_mm', 'arc', 'info', 'seeds');
fprintf('Saved seeded centerline to results/logs/centerline_seeded.mat\n');

fig = figure('Name', 'Phase 3 centerline (seeded)', 'Color', 'w', ...
             'Position', [40 40 1500 950]);
tl = tiledlayout(fig, 2, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
title(tl, sprintf('Phase 3 seeded centerline | %d nodes | arc %.0f mm | median R %.1f mm', ...
    size(Pv_mm,1), arc(end), median(R_mm)), 'FontWeight', 'bold');

% Coronal MIP with centerline + seeds
nexttile(tl, 1);
co_mip = squeeze(max(D_ct.vol, [], 1)).';
imagesc(co_mip); colormap(gca, gray); axis image off
clim([100 900]); hold on
plot(polyline_vox(:,2), polyline_vox(:,3), 'r-', 'LineWidth', 1.6);
plot(seeds(:,2), seeds(:,3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
title('Coronal MIP with seeded centerline')

% Sagittal MIP with centerline
nexttile(tl, 2);
sa_mip = squeeze(max(D_ct.vol, [], 2)).';
imagesc(sa_mip); colormap(gca, gray); axis image off
clim([100 900]); hold on
plot(polyline_vox(:,1), polyline_vox(:,3), 'r-', 'LineWidth', 1.6);
plot(seeds(:,1), seeds(:,3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
title('Sagittal MIP with seeded centerline')

% Skeleton extent
nexttile(tl, 3);
sk_co = squeeze(max(S.skel, [], 1)).';
imagesc(sk_co); colormap(gca, [0 0 0; 0.85 0.10 0.10]); axis image off
title(sprintf('Filtered skeleton (R ≥ %d vox), coronal MIP', S.opts.min_radius_vox))

% Radius profile
nexttile(tl, 4, [1 2]);
plot(arc, R_mm, '-', 'Color', [0.10 0.30 0.65], 'LineWidth', 1.6); hold on
grid on; xlabel('arc length s (mm)'); ylabel('inscribed-sphere radius R (mm)')
title('Lumen radius along the centerline')
ylim([0, max(R_mm)*1.05])

% 3D
nexttile(tl, 6);
plot3(Pv_mm(:,1), Pv_mm(:,2), Pv_mm(:,3), '-', ...
      'Color', [0.10 0.30 0.65], 'LineWidth', 2.0); hold on
plot3(Pv_mm(1,1), Pv_mm(1,2), Pv_mm(1,3), 'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
plot3(Pv_mm(end,1), Pv_mm(end,2), Pv_mm(end,3), 'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
grid on; axis equal; view(45, 20)
xlabel('x (mm)'); ylabel('y (mm)'); zlabel('z (mm)')
title('Seeded centerline in patient coords')

exportgraphics(fig, 'results/figures/centerline_seeded_qc.png', 'Resolution', 200);
savefig(fig, 'results/figures/centerline_seeded_qc.fig');
fprintf('Saved QC to results/figures/centerline_seeded_qc.{fig,png}\n');
