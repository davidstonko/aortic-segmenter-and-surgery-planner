function out_path = make_pipeline_video()
%MAKE_PIPELINE_VIDEO  Render the EVAR-planner pipeline as an MP4
%   walkthrough using the cached JohnDoe1-case outputs. Stages:
%     1. Title card
%     2. CT axial / coronal / sagittal MIPs
%     3. TotalSegmentator aorta+iliac segmentation
%     4. Branch-extended mask
%     5. Auto-detected seeds (kidney-anchor proximal, iliac termini)
%     6. Bifurcated centerline overlaid on the body silhouette
%     7. Rotating 3D centerline view
%     8. Sizing measurements callout
%     9. IFU eligibility verdict
%    10. End card with disclaimer
%
%   The video is built deterministically from the cached planner result
%   at results/logs/headless_20260516_133442/planner_result.mat.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    cd(proj);
    addpath(proj);

    % Prefer the CFA-extended v2 result if it exists.
    if isfile(fullfile(proj, 'results', 'logs', 'headless_v2', 'planner_result.mat'))
        S = load(fullfile(proj, 'results', 'logs', 'headless_v2', 'planner_result.mat'));
    else
        S = load(fullfile(proj, 'results', 'logs', 'headless_20260516_133442', 'planner_result.mat'));
    end
    L  = load('results/logs/ct_volume.mat', 'D_ct');
    D  = L.D_ct;

    % Build the EVAR plan with measurements + IFU ranking
    plan = evar_plan.generate_plan(S, struct('verbose', false, 'write_file', ''));
    meas = plan.measurements;
    ranked = plan.ranked_devices;

    out_path = fullfile(proj, 'results', 'videos', 'evar_pipeline.mp4');
    if isfile(out_path); delete(out_path); end
    vw = VideoWriter(out_path, 'MPEG-4');
    vw.FrameRate = 12;
    vw.Quality   = 90;
    open(vw);

    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [50 50 1280 720]);

    % --- Pre-compute MIPs (expensive on 1219-slice volume) ----
    fprintf('Pre-computing MIPs...\n');
    body_silhouette = D.vol > -200;
    co_silhouette = squeeze(max(body_silhouette, [], 1)).';
    sa_silhouette = squeeze(max(body_silhouette, [], 2)).';
    co_mask       = squeeze(max(S.mask,         [], 1)).';
    sa_mask       = squeeze(max(S.mask,         [], 2)).';

    % --- 1. Title card ----
    write_text_frame(vw, fig, ...
        {'\bf{EVAR Planner}', '\rm{}Open-source automated pre-op planning', '', ...
         'JohnDoe1 CT angiogram — 512×512×1219 voxels, 0.77 mm in-plane, 0.5 mm slice'}, ...
        2.5);

    % --- 2. DICOM ingest ----
    write_section_card(vw, fig, '1. DICOM ingest', 1.0);
    plot_two_mips(vw, fig, co_silhouette, sa_silhouette, [], [], [], ...
        'CT volume loaded (de-identified)', 1.5);

    % --- 3. Segmentation ----
    write_section_card(vw, fig, '2. TotalSegmentator', 1.0);
    plot_two_mips(vw, fig, co_silhouette, sa_silhouette, co_mask, sa_mask, [], ...
        'Aorta + iliac mask (TS multilabel)', 2.0);

    % --- 4. Branch + CFA extension ----
    write_section_card(vw, fig, '3. Iliac + CFA extension to FOV bottom', 1.0);
    plot_two_mips(vw, fig, co_silhouette, sa_silhouette, co_mask, sa_mask, [], ...
        sprintf('Mask now extends to z=%d (true CFA, R-side reaches FOV bottom)', ...
            find(squeeze(any(any(S.mask,1),2)), 1, 'last')), 2.0);

    % --- 5. Auto seeds ----
    write_section_card(vw, fig, '4. Auto-detected endpoints (zero clicks)', 1.0);
    plot_two_mips(vw, fig, co_silhouette, sa_silhouette, co_mask, sa_mask, S.seeds, ...
        sprintf('Proximal z=%d (~5 cm above celiac) | R-CFA z=%d | L-CFA z=%d (L drops out where contrast bolus does)', ...
            S.seeds.proximal(3), S.seeds.right_cfa(3), S.seeds.left_cfa(3)), 2.5);

    % --- 6. Centerline overlay (coronal) ----
    write_section_card(vw, fig, '5. Bifurcated centerline', 1.0);
    plot_centerline_overlay(vw, fig, co_silhouette, co_mask, ...
        S.Pv_mm_right, S.Pv_mm_left, D, S.seeds, ...
        sprintf('Arc R = %.0f mm, Arc L = %.0f mm', S.arc_R_mm, S.arc_L_mm), 2.0);

    % --- 7. Rotating 3D centerline ----
    write_section_card(vw, fig, '6. 3D bifurcated centerline', 1.0);
    plot_rotating_3d(vw, fig, S.Pv_mm_right, S.Pv_mm_left, S.seeds_mm, ...
        S.R_mm_right, S.R_mm_left);

    % --- 8. Sizing measurements ----
    write_section_card(vw, fig, '7. Auto-measurements', 1.0);
    plot_sizing(vw, fig, S.Pv_mm_right, S.R_mm_right, meas, 3.0);

    % --- 9. IFU verdict ----
    write_section_card(vw, fig, '8. IFU device matching', 1.0);
    plot_ifu(vw, fig, meas, ranked, plan.recommendation, 5.0);

    % --- 10. End card ----
    write_text_frame(vw, fig, ...
        {'\bf{RESEARCH USE ONLY}', '', ...
         'This pipeline has NOT been clinically validated.', ...
         'IFU criteria from Chaikof 2018 SVS + AbuRahma 2018 JACS', ...
         '(NOT current vendor IFUs). Do not use for clinical decisions.'}, ...
        3.5);

    close(vw); close(fig);
    fprintf('Video written: %s\n', out_path);
end

% =========================================================================
function n = fps_seconds(vw, seconds)
    n = max(1, round(vw.FrameRate * seconds));
end

function write_text_frame(vw, fig, text_lines, seconds)
    clf(fig);
    ax = axes('Parent', fig, 'Position', [0 0 1 1], 'Color', 'w');
    axis(ax, 'off');
    n = numel(text_lines);
    fs_top = 36; fs_body = 22;
    for k = 1:n
        if k == 1
            text(ax, 0.5, 0.7 - 0.06*(k-1), text_lines{k}, ...
                'HorizontalAlignment', 'center', 'FontSize', fs_top, ...
                'FontWeight', 'bold', 'Interpreter', 'tex');
        else
            text(ax, 0.5, 0.7 - 0.07*(k-1), text_lines{k}, ...
                'HorizontalAlignment', 'center', 'FontSize', fs_body, ...
                'Interpreter', 'tex');
        end
    end
    nf = fps_seconds(vw, seconds);
    fr = getframe(fig);
    for i = 1:nf; writeVideo(vw, fr); end
end

function write_section_card(vw, fig, title_text, seconds)
    clf(fig);
    ax = axes('Parent', fig, 'Position', [0 0 1 1], 'Color', [0.07 0.1 0.18]);
    axis(ax, 'off');
    text(ax, 0.5, 0.5, title_text, 'HorizontalAlignment', 'center', ...
        'FontSize', 42, 'FontWeight', 'bold', 'Color', 'w', ...
        'Interpreter', 'none');
    nf = fps_seconds(vw, seconds);
    fr = getframe(fig);
    for i = 1:nf; writeVideo(vw, fr); end
end

function plot_two_mips(vw, fig, co_sil, sa_sil, co_mask, sa_mask, seeds, caption, seconds)
    clf(fig);
    tl = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    title(tl, caption, 'FontWeight', 'bold', 'FontSize', 18);

    % Coronal
    ax1 = nexttile(tl, 1);
    if ~isempty(co_mask)
        composite = 2 * double(co_sil) + 5 * double(co_mask);
        imagesc(composite); colormap(ax1, [1 1 1; 0.92 0.92 0.94; 0.55 0.55 0.65; 1.0 0.55 0.20]);
    else
        imagesc(co_sil); colormap(ax1, [1 1 1; 0.55 0.55 0.65]);
    end
    axis(ax1, 'image', 'off'); hold(ax1, 'on');
    if ~isempty(seeds)
        plot(ax1, seeds.proximal(2),  seeds.proximal(3),  'go', 'MarkerFaceColor', 'g', 'MarkerSize', 14);
        plot(ax1, seeds.right_cfa(2), seeds.right_cfa(3), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 14);
        plot(ax1, seeds.left_cfa(2),  seeds.left_cfa(3),  'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 14);
    end
    title(ax1, 'Coronal MIP', 'FontSize', 14);

    % Sagittal
    ax2 = nexttile(tl, 2);
    if ~isempty(sa_mask)
        composite = 2 * double(sa_sil) + 5 * double(sa_mask);
        imagesc(composite); colormap(ax2, [1 1 1; 0.92 0.92 0.94; 0.55 0.55 0.65; 1.0 0.55 0.20]);
    else
        imagesc(sa_sil); colormap(ax2, [1 1 1; 0.55 0.55 0.65]);
    end
    axis(ax2, 'image', 'off'); hold(ax2, 'on');
    if ~isempty(seeds)
        plot(ax2, seeds.proximal(1),  seeds.proximal(3),  'go', 'MarkerFaceColor', 'g', 'MarkerSize', 14);
        plot(ax2, seeds.right_cfa(1), seeds.right_cfa(3), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 14);
        plot(ax2, seeds.left_cfa(1),  seeds.left_cfa(3),  'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 14);
    end
    title(ax2, 'Sagittal MIP', 'FontSize', 14);

    nf = fps_seconds(vw, seconds);
    fr = getframe(fig);
    for i = 1:nf; writeVideo(vw, fr); end
end

function plot_centerline_overlay(vw, fig, co_sil, co_mask, PvR, PvL, D, seeds, caption, seconds)
    clf(fig);
    ax = axes('Parent', fig);
    composite = 2 * double(co_sil) + 5 * double(co_mask);
    imagesc(composite); colormap(ax, [1 1 1; 0.92 0.92 0.94; 0.55 0.55 0.65; 1.0 0.55 0.20]);
    axis(ax, 'image', 'off'); hold(ax, 'on');
    % Pv_mm is in [y x z] mm — convert to coronal-MIP pixel coords (x col, z row)
    x_pix_R = PvR(:, 1) / D.pixel_mm(2);   % x_mm / pix_mm = column index
    z_pix_R = PvR(:, 3);                   % z_mm directly indexes the MIP row (mm-spaced)
    % z_mm needs to be mapped through D.slice_z_mm — use the lookup
    z_pix_R = mm_to_slice(PvR(:, 3), D);
    x_pix_L = PvL(:, 1) / D.pixel_mm(2);
    z_pix_L = mm_to_slice(PvL(:, 3), D);
    plot(ax, x_pix_R, z_pix_R, '-', 'Color', [0.85 0.15 0.15], 'LineWidth', 2.5);
    plot(ax, x_pix_L, z_pix_L, '-', 'Color', [0.15 0.35 0.85], 'LineWidth', 2.5);
    plot(ax, seeds.proximal(2),  seeds.proximal(3),  'go', 'MarkerFaceColor', 'g', 'MarkerSize', 14);
    plot(ax, seeds.right_cfa(2), seeds.right_cfa(3), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 14);
    plot(ax, seeds.left_cfa(2),  seeds.left_cfa(3),  'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 14);
    title(ax, caption, 'FontSize', 18, 'FontWeight', 'bold');

    nf = fps_seconds(vw, seconds);
    fr = getframe(fig);
    for i = 1:nf; writeVideo(vw, fr); end
end

function z_slice = mm_to_slice(z_mm, D)
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        % Inverse lookup: find slice index whose mm coord matches each z_mm
        z_slice = interp1(D.slice_z_mm, 1:numel(D.slice_z_mm), z_mm, 'linear', 'extrap');
    else
        z_slice = z_mm / D.slice_spacing_mm + 1;
    end
end

function plot_rotating_3d(vw, fig, PvR, PvL, seeds_mm, RR, RL)
    clf(fig);
    ax = axes('Parent', fig, 'Color', 'w');
    plot3(ax, PvR(:,1), PvR(:,2), PvR(:,3), '-', 'Color', [0.85 0.15 0.15], 'LineWidth', 2.5);
    hold(ax, 'on');
    plot3(ax, PvL(:,1), PvL(:,2), PvL(:,3), '-', 'Color', [0.15 0.35 0.85], 'LineWidth', 2.5);
    plot3(ax, seeds_mm.proximal(1),  seeds_mm.proximal(2),  seeds_mm.proximal(3), ...
        'go', 'MarkerFaceColor', 'g', 'MarkerSize', 14);
    plot3(ax, seeds_mm.right_cfa(1), seeds_mm.right_cfa(2), seeds_mm.right_cfa(3), ...
        'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 14);
    plot3(ax, seeds_mm.left_cfa(1),  seeds_mm.left_cfa(2),  seeds_mm.left_cfa(3), ...
        'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 14);
    grid(ax, 'on');
    axis(ax, 'equal');
    xlabel(ax, 'x (mm)'); ylabel(ax, 'y (mm)'); zlabel(ax, 'z (mm)');
    title(ax, sprintf('R branch: R median %.1f mm | L branch: R median %.1f mm', ...
        median(RR), median(RL)), 'FontSize', 16, 'FontWeight', 'bold');
    set(ax, 'ZDir', 'reverse');   % head at top

    n_frames = 36;   % 3 seconds at 12 fps
    for k = 0:n_frames-1
        view(ax, 45 + 360 * k / n_frames, 20);
        writeVideo(vw, getframe(fig));
    end
end

function plot_sizing(vw, fig, Pv, R, meas, seconds)
    clf(fig);
    tl = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');

    % Left: radius profile with shaded neck + aneurysm bands
    ax1 = nexttile(tl, 1);
    arc = [0; cumsum(vecnorm(diff(Pv,1,1),2,2))];
    plot(ax1, arc, R, '-', 'Color', [0.1 0.3 0.65], 'LineWidth', 2); hold(ax1, 'on');
    yline(ax1, meas.diagnostic.neck_baseline_R_mm, '--', 'neck R baseline');
    x_seal = meas.diagnostic.seal_start_arc_mm;
    x_aneur = meas.diagnostic.aneurysm_start_arc_mm;
    yl = ylim(ax1);
    patch(ax1, [x_seal x_aneur x_aneur x_seal], [yl(1) yl(1) yl(2) yl(2)], ...
        [0.6 1 0.6], 'FaceAlpha', 0.18, 'EdgeColor', 'none');
    text(ax1, (x_seal+x_aneur)/2, yl(2)*0.85, 'NECK', ...
        'HorizontalAlignment', 'center', 'Color', [0 0.4 0], 'FontWeight', 'bold');
    grid(ax1, 'on');
    xlabel(ax1, 'arc s (mm)'); ylabel(ax1, 'R (mm)');
    title(ax1, 'Right-branch radius profile', 'FontSize', 13);

    % Right: text table of measurements
    ax2 = nexttile(tl, 2);
    axis(ax2, 'off');
    lines = {
        sprintf('Proximal neck')
        sprintf('  Ø: %.1f mm', meas.neck_diameter_mm)
        sprintf('  length: %.1f mm', meas.neck_length_mm)
        sprintf('  angulation: %.1f°', meas.neck_angulation_deg)
        ''
        sprintf('Iliacs (common iliac landing zone)')
        sprintf('  R Ø: %.1f mm  length: %.1f mm', meas.iliac_R_diameter_mm, meas.iliac_R_length_mm)
        sprintf('  L Ø: %.1f mm  length: %.1f mm', meas.iliac_L_diameter_mm, meas.iliac_L_length_mm)
        ''
        sprintf('Peak aneurysm Ø')
        sprintf('  %.1f mm', 2*meas.max_aneurysm_R_mm)
    };
    text(ax2, 0.05, 0.95, strjoin(lines, newline), ...
        'VerticalAlignment', 'top', 'FontSize', 20, 'FontName', 'Menlo');

    nf = fps_seconds(vw, seconds);
    fr = getframe(fig);
    for i = 1:nf; writeVideo(vw, fr); end
end

function plot_ifu(vw, fig, meas, ranked, recommendation, seconds)
    clf(fig);
    ax = axes('Parent', fig, 'Position', [0.04 0.04 0.92 0.86]);
    axis(ax, 'off');

    % Header
    if isempty(recommendation)
        header = 'NO ON-LABEL DEVICE (this case is off-IFU for every catalogued graft)';
        header_col = [0.7 0.0 0.0];
    else
        header = sprintf('Recommended: %s — fits all IFU criteria', recommendation);
        header_col = [0 0.5 0];
    end
    text(ax, 0.02, 1.00, header, 'FontSize', 18, 'FontWeight', 'bold', ...
        'Color', header_col, 'VerticalAlignment', 'top', 'Units', 'normalized');

    % Column headers
    y0 = 0.88;
    text(ax, 0.02, y0, 'Device',          'FontSize', 14, 'FontWeight', 'bold', 'Units', 'normalized');
    text(ax, 0.20, y0, 'Manufacturer',    'FontSize', 14, 'FontWeight', 'bold', 'Units', 'normalized');
    text(ax, 0.40, y0, 'Verdict',         'FontSize', 14, 'FontWeight', 'bold', 'Units', 'normalized');
    text(ax, 0.55, y0, 'Binding constraint', 'FontSize', 14, 'FontWeight', 'bold', 'Units', 'normalized');
    text(ax, 0.90, y0, 'Margin', 'FontSize', 14, 'FontWeight', 'bold', 'Units', 'normalized');

    row_h = 0.10;
    for k = 1:numel(ranked)
        d = ranked(k); ec = d.eligibility;
        y = y0 - 0.05 - row_h * k;
        col = [0 0.4 0]; verdict = '✓ ELIGIBLE';
        if ~ec.eligible
            col = [0.7 0 0]; verdict = '✗ OFF-IFU';
        end
        text(ax, 0.02, y, d.name,                'FontSize', 13, 'Units', 'normalized');
        text(ax, 0.20, y, d.manufacturer,        'FontSize', 13, 'Units', 'normalized');
        text(ax, 0.40, y, verdict,               'FontSize', 13, 'Color', col, ...
            'FontWeight', 'bold', 'Units', 'normalized');
        text(ax, 0.55, y, ec.binding,            'FontSize', 12, 'Units', 'normalized', ...
            'Interpreter', 'none');
        text(ax, 0.90, y, sprintf('%+.1f', ec.min_margin), 'FontSize', 13, ...
            'Color', col, 'FontWeight', 'bold', 'Units', 'normalized');
    end

    % Footer
    text(ax, 0.02, 0.02, sprintf( ...
        'Measurements: neck Ø %.1f mm / length %.1f mm / angulation %.1f° | iliac R Ø %.1f mm | iliac L Ø %.1f mm', ...
        meas.neck_diameter_mm, meas.neck_length_mm, meas.neck_angulation_deg, ...
        meas.iliac_R_diameter_mm, meas.iliac_L_diameter_mm), ...
        'FontSize', 11, 'Color', [0.3 0.3 0.3], 'Units', 'normalized', ...
        'VerticalAlignment', 'bottom');

    nf = fps_seconds(vw, seconds);
    fr = getframe(fig);
    for i = 1:nf; writeVideo(vw, fr); end
end
