function out_path = make_gui_video()
%MAKE_GUI_VIDEO  Drive `app.AorticCenterlineApp` programmatically and
%   capture the LIVE UIFigure surface at each step. The video is the
%   actual GUI walking through Steps 1→2→3→4→5 with the segmentation
%   audit modal in between Steps 2 and 3, then the IFU verdict modal
%   at Step 5. Every frame is `getframe(app.UIFigure)` from the real
%   app window (the side panel updates per step, the step bar
%   highlights the active step, etc.).
%
%   Output: results/videos/evar_gui_walkthrough.mp4

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    cd(proj); addpath(proj);

    L  = load(fullfile(proj, 'results/logs/ct_volume.mat'), 'D_ct');
    D  = L.D_ct;
    Sv = load(fullfile(proj, 'results/logs/headless_v2/planner_result.mat'));

    out_dir = fullfile(proj, 'results', 'videos');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end
    out_path = fullfile(out_dir, 'evar_gui_walkthrough.mp4');
    if isfile(out_path); delete(out_path); end

    fprintf('Launching app...\n');
    a = app.AorticCenterlineApp();
    pause(1.5);   % banner + initial layout
    drawnow;

    vw = VideoWriter(out_path, 'MPEG-4');
    vw.FrameRate = 6;
    vw.Quality   = 80;
    open(vw);

    capture = @(seconds) cap_n(vw, a.UIFigure, seconds);
    write_overlay_caption = @(text_str, seconds) overlay_caption(vw, a.UIFigure, text_str, seconds);

    % --- Initial launch — banner dialog appears, step bar live ---
    write_overlay_caption('AorticCenterlineApp — launch (research-only banner)', 1.2);

    % --- Step 1: inject the cached CT, refresh ---
    fprintf('Step 1: injecting CT and switching to 3D-recon view...\n');
    a.injectCT(D);
    a.setStepPublic(1);
    pause(0.3); drawnow;
    write_overlay_caption('Step 1 — CT loaded (DICOM ingest)', 1.5);

    % --- Step 2: inject the TS+CFA-extended mask, set 3D recon view ---
    fprintf('Step 2: mask + segmentation, 3D-recon view...\n');
    a.injectMask(Sv.mask);
    a.setStepPublic(2);
    pause(0.3); drawnow;
    write_overlay_caption('Step 2 — Segmentation (3D recon, TS + CFA extension)', 2.0);

    % --- Audit gate (between Step 2 and Step 3) ---
    fprintf('Audit gate...\n');
    audit = autoseg.audit_segmentation(Sv.mask, [], D);
    show_audit_modal(a.UIFigure, audit);
    pause(0.3); drawnow;
    capture(2.5);
    close_topmost_dialog(a.UIFigure);
    pause(0.2);

    % --- Step 3: inject auto-seeds, advance ---
    fprintf('Step 3: auto-seeds...\n');
    a.injectSeeds(Sv.seeds.proximal, Sv.seeds.right_cfa, Sv.seeds.left_cfa);
    a.setStepPublic(3);
    pause(0.3); drawnow;
    write_overlay_caption('Step 3 — Auto-detected endpoints (zero clicks)', 1.8);

    % --- Step 4: inject centerlines + advance ---
    fprintf('Step 4: centerlines...\n');
    pix = D.pixel_mm;
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        z_to_vox = @(z) interp1(D.slice_z_mm, 1:numel(D.slice_z_mm), z, 'linear', 'extrap');
    else
        z_to_vox = @(z) z / D.slice_spacing_mm + 1;
    end
    pv_to_vox = @(P) [P(:,2)/pix(1) + 1, P(:,1)/pix(2) + 1, z_to_vox(P(:,3))];
    PvR_vox = pv_to_vox(Sv.Pv_mm_right);
    PvL_vox = pv_to_vox(Sv.Pv_mm_left);
    RR_vox  = Sv.R_mm_right / mean(pix);
    RL_vox  = Sv.R_mm_left  / mean(pix);
    bifurc_idx = round(size(PvR_vox,1) * 0.6);
    a.injectCenterlines(PvR_vox, RR_vox, PvL_vox, RL_vox, bifurc_idx);
    a.setStepPublic(4);
    pause(0.3); drawnow;
    write_overlay_caption(sprintf('Step 4 — Bifurcated centerline (arc R %.0f mm / L %.0f mm)', ...
        Sv.arc_R_mm, Sv.arc_L_mm), 2.0);

    % --- Step 5: analyze + IFU verdict ---
    fprintf('Step 5: analyze + IFU...\n');
    a.setStepPublic(5);
    pause(0.3); drawnow;
    write_overlay_caption('Step 5 — Sizing measurements + IFU device matching', 1.5);

    plan = evar_plan.generate_plan(Sv, struct('verbose', false, 'write_file', ''));
    show_ifu_modal(a.UIFigure, plan);
    pause(0.3); drawnow;
    capture(3.0);
    close_topmost_dialog(a.UIFigure);

    % --- End ---
    write_overlay_caption('RESEARCH USE ONLY — not for clinical decision-making', 1.8);

    close(vw);
    try; close(a.UIFigure); catch; end %#ok<NOSEM>
    d = dir(out_path);
    fprintf('Video: %s  (%.1f MB, %d s @ %d fps)\n', ...
        out_path, d.bytes/1e6, round(vw.FrameRate * 0), vw.FrameRate);
end

% =====================================================================
function cap_n(vw, fig, seconds)
%CAP_N  Capture `seconds`*fps frames of `fig` to `vw`.
    n = max(1, round(vw.FrameRate * seconds));
    for k = 1:n
        try
            fr = getframe(fig);
            writeVideo(vw, fr);
        catch
            % If the figure has a modal dialog up, getframe may fail —
            % skip and try the next tick.
        end
        drawnow;
    end
end

function overlay_caption(vw, fig, caption, seconds)
%OVERLAY_CAPTION  Capture `seconds` of `fig` with a caption banner
%   drawn on top of each captured frame. Doesn't modify the live
%   figure — instead composites each captured frame with the banner.
    n = max(1, round(vw.FrameRate * seconds));
    helper = figure('Visible', 'off', 'Color', 'w');
    for k = 1:n
        try
            fr = getframe(fig);
            img = fr.cdata;
            H = size(img, 1); W = size(img, 2);
            set(helper, 'Position', [50 50 W H]);
            clf(helper);
            ax = axes('Parent', helper, 'Position', [0 0 1 1]);
            imshow(img, 'Parent', ax); hold(ax, 'on');
            rectangle(ax, 'Position', [0, H-46, W, 46], ...
                'FaceColor', [0.07 0.10 0.18], 'EdgeColor', 'none');
            text(ax, W/2, H-23, caption, ...
                'Color', 'w', 'FontSize', 14, 'FontWeight', 'bold', ...
                'HorizontalAlignment', 'center');
            writeVideo(vw, getframe(helper));
        catch
        end
        drawnow;
    end
    close(helper);
end

function show_audit_modal(fig, audit)
%SHOW_AUDIT_MODAL  Open the segmentation-audit summary as a modal
%   over the live app figure (non-blocking — we display, capture, then
%   close from outside).
    if audit.passed
        uiconfirm(fig, audit.summary_text, ...
            'Segmentation audit', 'Options', {'Advance to Step 3'}, ...
            'Icon', 'info');
    else
        uialert(fig, audit.summary_text, ...
            'Segmentation audit FAILED', 'Icon', 'error');
    end
end

function show_ifu_modal(fig, plan)
    lines = { plan.rationale, '', 'Device library:' };
    for k = 1:numel(plan.ranked_devices)
        d = plan.ranked_devices(k); ec = d.eligibility;
        if ec.eligible
            verdict = sprintf('ELIGIBLE (margin %+0.1f)', ec.min_margin);
        else
            verdict = sprintf('OFF-IFU (binding %s, %+0.1f)', ec.binding, ec.min_margin);
        end
        lines{end+1} = sprintf('  %-14s %-15s %s', d.name, d.manufacturer, verdict); %#ok<AGROW>
    end
    lines{end+1} = '';
    lines{end+1} = ['[' plan.disclaimer ']'];
    uialert(fig, strjoin(lines, newline), ...
        'EVAR plan — IFU device match (research only)', ...
        'Icon', 'info', 'Interpreter', 'none');
end

function close_topmost_dialog(fig)
%CLOSE_TOPMOST_DIALOG  Find and close the most-recent uialert / uiconfirm
%   dialog under `fig`. uialert children are uifigure objects; we close
%   any that are not the main fig.
    drawnow;
    all_figs = findall(groot, 'Type', 'figure');
    for k = 1:numel(all_figs)
        if all_figs(k) ~= fig && isvalid(all_figs(k))
            try; close(all_figs(k)); catch; end %#ok<NOSEM>
        end
    end
end
