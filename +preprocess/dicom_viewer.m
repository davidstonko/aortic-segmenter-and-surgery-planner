function dicom_viewer(src, varargin)
%DICOM_VIEWER  Stand-alone aortic / iliac DICOM viewer.
%
%   DICOM_VIEWER(SRC) opens an interactive viewer that adapts to the
%   data type:
%
%     CT volumes   →  three orthogonal panes (axial, coronal, sagittal),
%                     each with its own slice slider; window/level
%                     presets for abdomen/lung/bone/vessel; an MIP
%                     mode toggle that swaps the panes for slab MIPs.
%     XA cine      →  single image pane with frame slider, play/pause
%                     button, frame-rate readout, and C-arm pose tags.
%     XA still     →  single image pane with metadata.
%
%   SRC may be:
%       - a path to a folder containing DICOM slices/frames,
%       - a path to a single DICOM file,
%       - a struct returned by preprocess.dicom_load.
%
%   Optional name-value arguments
%       'Title'        : figure title (default: from modality + ID)
%       'WindowLevel'  : initial [W L] (default: auto-estimate)
%       'Anonymize'    : true/false (default: true)
%       'CinePlayback' : true/false (default: true for XA)
%
%   The viewer is the Phase 3 Module 1 deliverable — a stand-alone
%   tool for inspecting any DICOM input the project will encounter
%   without having to leave MATLAB.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    p = inputParser;
    p.addRequired('src');
    p.addParameter('Title',        '');
    p.addParameter('WindowLevel',  []);
    p.addParameter('Anonymize',    true);
    p.addParameter('CinePlayback', true);
    p.parse(src, varargin{:});
    opts = p.Results;

    if isstruct(src)
        D = src;
    else
        D = preprocess.dicom_load(src, opts.Anonymize);
    end

    if D.is_volume
        viewer_volume(D, opts);
    else
        viewer_cine(D, opts);
    end
end

% =========================================================================
% Volume viewer — three orthogonal panes with sliders
% =========================================================================
function viewer_volume(D, opts)
    fig = figure('Name', figure_title(D, opts.Title), ...
                 'Color', 'w', ...
                 'Position', [40 40 1500 950], ...
                 'Toolbar', 'figure', 'Menubar', 'none');

    % Standard clinical W/L presets. CTA window comes from
    % Radiopaedia and 3D Slicer's vascular preset (W=700, L=150) —
    % gives bright contrast lumen with visible soft-tissue context.
    presets = {
        'CTA / Vessel',  [700,   150];   % bright contrast lumen
        'Abdomen',       [400,    40];
        'Bone',          [1500,  400];
        'Lung',          [1500, -600];
        'Soft tissue',   [400,    40];
    };
    if isempty(opts.WindowLevel)
        % Auto-detect: if SeriesDescription contains aorta / CTA /
        % angio / vascular keywords, start at the Vessel preset.
        % Otherwise fall back to Abdomen for plain CTs.
        descr_low = lower(D.series_description);
        if contains(descr_low, ["aorta", "cta", "angio", "vasc", "iliac"])
            WL = presets{1, 2};   % Vessel
        else
            WL = presets{2, 2};   % Abdomen
        end
    else
        WL = opts.WindowLevel;
    end

    [Ny, Nx, Nz] = size(D.vol);
    state = struct();
    state.D       = D;
    state.WL      = WL;
    state.idx_ax  = round(Nz/2);
    state.idx_co  = round(Ny/2);
    state.idx_sa  = round(Nx/2);
    state.fig     = fig;
    state.presets = presets;

    % Layout: three orthogonal panes at left, metadata + controls at right
    % Tile rectangle is [left bottom width height], normalized.
    tl = uipanel(fig, 'Units', 'normalized', 'Position', [0 0 0.74 1], ...
        'BackgroundColor', 'w', 'BorderType', 'none');

    % --- Axial pane (top-left) ---
    state.ax_axial = axes('Parent', tl, 'Position', [0.04 0.55 0.43 0.42]);
    state.h_axial  = imagesc(state.ax_axial, D.vol(:,:,state.idx_ax));
    colormap(state.ax_axial, gray); axis(state.ax_axial, 'image', 'off');
    title(state.ax_axial, sprintf('Axial  z = %.1f mm', D.slice_z_mm(state.idx_ax)));
    state.sl_axial = uicontrol(fig, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.04 0.51 0.32 0.025], ...
        'Min', 1, 'Max', Nz, 'Value', state.idx_ax, ...
        'SliderStep', [1, 20] / max(1, Nz-1), ...
        'Callback', @(s,~) update_axial(s.Value));

    % --- Coronal pane (top-right) ---
    state.ax_coronal = axes('Parent', tl, 'Position', [0.51 0.55 0.43 0.42]);
    state.h_coronal  = imagesc(state.ax_coronal, ...
        squeeze(D.vol(state.idx_co,:,:)).');
    colormap(state.ax_coronal, gray); axis(state.ax_coronal, 'image', 'off');
    % imagesc default YDir='reverse' puts row 1 of the image at the
    % top of the display. Since dicom_load now sorts slices descending
    % in z, slice 1 of the volume is the head end → displayed at top.
    title(state.ax_coronal, sprintf('Coronal  y row %d', state.idx_co));
    state.sl_coronal = uicontrol(fig, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.51 0.51 0.32 0.025], ...
        'Min', 1, 'Max', Ny, 'Value', state.idx_co, ...
        'SliderStep', [1, 20] / max(1, Ny-1), ...
        'Callback', @(s,~) update_coronal(s.Value));

    % --- Sagittal pane (bottom-left) ---
    state.ax_sagittal = axes('Parent', tl, 'Position', [0.04 0.05 0.43 0.42]);
    state.h_sagittal  = imagesc(state.ax_sagittal, ...
        squeeze(D.vol(:,state.idx_sa,:)).');
    colormap(state.ax_sagittal, gray); axis(state.ax_sagittal, 'image', 'off');
    title(state.ax_sagittal, sprintf('Sagittal  x col %d', state.idx_sa));
    state.sl_sagittal = uicontrol(fig, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.04 0.01 0.32 0.025], ...
        'Min', 1, 'Max', Nx, 'Value', state.idx_sa, ...
        'SliderStep', [1, 20] / max(1, Nx-1), ...
        'Callback', @(s,~) update_sagittal(s.Value));

    % --- Histogram pane (bottom-right): show window/level on histogram --
    state.ax_hist = axes('Parent', tl, 'Position', [0.51 0.07 0.43 0.40]);
    sample = D.vol(:,:,round(linspace(1, Nz, min(20, Nz))));
    histogram(state.ax_hist, sample(:), 200, ...
        'FaceColor', [0.3 0.3 0.4], 'EdgeColor', 'none');
    set(state.ax_hist, 'YScale', 'log');
    xlabel(state.ax_hist, 'HU'); ylabel(state.ax_hist, 'count (log)');
    title(state.ax_hist, 'Sample histogram (axial slices)');
    grid(state.ax_hist, 'on');
    yl = ylim(state.ax_hist);
    state.hist_lo_line = line(state.ax_hist, [0 0], yl, 'Color', 'r', 'LineStyle', '--');
    state.hist_hi_line = line(state.ax_hist, [0 0], yl, 'Color', 'r', 'LineStyle', '--');

    % --- Right-side panel: metadata + controls ---
    panel = uipanel(fig, 'Units', 'normalized', 'Position', [0.75 0 0.25 1], ...
        'BackgroundColor', 'w', 'Title', 'DICOM metadata + controls', ...
        'FontSize', 10);
    uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.55 0.9 0.42], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontName', 'Menlo', ...
        'HorizontalAlignment', 'left', 'String', metadata_string(D));

    % Window-level preset buttons
    uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.50 0.9 0.04], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'String', 'Window/level presets', ...
        'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    for i = 1:size(presets, 1)
        uicontrol(panel, 'Style', 'pushbutton', 'Units', 'normalized', ...
            'Position', [0.05 0.45 - 0.05*(i-1) 0.40 0.04], ...
            'String', sprintf('%s (W=%.0f, L=%.0f)', presets{i,1}, presets{i,2}(1), presets{i,2}(2)), ...
            'FontSize', 9, ...
            'Callback', @(~,~) set_WL(presets{i, 2}));
    end

    % Save snapshot button
    uicontrol(panel, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.05 0.20 0.9 0.05], ...
        'String', 'Save snapshot…', ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'Callback', @(~,~) save_snapshot());

    % Window/level live readout
    state.txt_WL = uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.13 0.9 0.05], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontName', 'Menlo', ...
        'HorizontalAlignment', 'left', 'String', '');

    % Help text at bottom
    uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.02 0.9 0.10], 'BackgroundColor', 'w', ...
        'FontSize', 9, 'FontAngle', 'italic', ...
        'HorizontalAlignment', 'left', ...
        'String', 'Right-click + drag any pane to adjust W/L. Click presets above. Sliders below each pane scrub through slices.');

    % Right-click drag handler (W/L on the active pane)
    set(fig, 'WindowButtonDownFcn', @(~,~) on_button_down());

    apply_view();
    fig.UserData = state;

    % --- Nested updaters ---
    function update_axial(v)
        state.idx_ax = round(v);
        state.sl_axial.Value = state.idx_ax;
        state.h_axial.CData = state.D.vol(:, :, state.idx_ax);
        title(state.ax_axial, sprintf('Axial  z = %.1f mm  (slice %d/%d)', ...
            state.D.slice_z_mm(state.idx_ax), state.idx_ax, Nz));
        fig.UserData = state;
    end
    function update_coronal(v)
        state.idx_co = round(v);
        state.sl_coronal.Value = state.idx_co;
        state.h_coronal.CData = squeeze(state.D.vol(state.idx_co,:,:)).';
        title(state.ax_coronal, sprintf('Coronal  y row %d/%d', state.idx_co, Ny));
        fig.UserData = state;
    end
    function update_sagittal(v)
        state.idx_sa = round(v);
        state.sl_sagittal.Value = state.idx_sa;
        state.h_sagittal.CData = squeeze(state.D.vol(:,state.idx_sa,:)).';
        title(state.ax_sagittal, sprintf('Sagittal  x col %d/%d', state.idx_sa, Nx));
        fig.UserData = state;
    end
    function set_WL(WL_new)
        state.WL = WL_new;
        apply_view();
        fig.UserData = state;
    end
    function apply_view()
        W = state.WL(1); L = state.WL(2);
        clim_lo = L - W/2; clim_hi = L + W/2;
        clim(state.ax_axial,    [clim_lo clim_hi]);
        clim(state.ax_coronal,  [clim_lo clim_hi]);
        clim(state.ax_sagittal, [clim_lo clim_hi]);
        % Update histogram bands
        yl = ylim(state.ax_hist);
        state.hist_lo_line.XData = [clim_lo clim_lo];
        state.hist_lo_line.YData = yl;
        state.hist_hi_line.XData = [clim_hi clim_hi];
        state.hist_hi_line.YData = yl;
        if isfield(state, 'txt_WL') && isvalid(state.txt_WL)
            state.txt_WL.String = sprintf('W = %.0f, L = %.0f', W, L);
        end
    end
    function on_button_down()
        if strcmp(get(fig, 'SelectionType'), 'alt')
            set(fig, 'WindowButtonMotionFcn', @(~,~) on_drag());
            set(fig, 'WindowButtonUpFcn',     @(~,~) on_release());
            state.drag_start = get(fig, 'CurrentPoint');
            state.WL_start   = state.WL;
            fig.UserData = state;
        end
    end
    function on_drag()
        cur = get(fig, 'CurrentPoint');
        delta = cur - state.drag_start;
        state.WL(1) = max(1, state.WL_start(1) + delta(1) * 4);
        state.WL(2) =        state.WL_start(2) - delta(2) * 2;
        apply_view();
        fig.UserData = state;
    end
    function on_release()
        set(fig, 'WindowButtonMotionFcn', '');
        set(fig, 'WindowButtonUpFcn',     '');
    end
    function save_snapshot()
        [name, path] = uiputfile('snapshot.png', 'Save snapshot');
        if name == 0; return; end
        exportgraphics(fig, fullfile(path, name), 'Resolution', 200);
    end
end

% =========================================================================
% Cine viewer — single pane with frame slider + play/pause
% =========================================================================
function viewer_cine(D, opts)
    fig = figure('Name', figure_title(D, opts.Title), ...
                 'Color', 'w', ...
                 'Position', [40 40 1300 900], ...
                 'Toolbar', 'figure', 'Menubar', 'none');

    if isempty(opts.WindowLevel)
        mid = D.vol(:, :, max(1, round(size(D.vol, 3) / 2)));
        lo  = double(prctile(mid(:),  1));
        hi  = double(prctile(mid(:), 99));
        WL  = [hi - lo, 0.5 * (lo + hi)];
        if WL(1) <= 0; WL = [400, 40]; end
    else
        WL = opts.WindowLevel;
    end

    state = struct();
    state.D       = D;
    state.WL      = WL;
    state.idx     = 1;
    state.fig     = fig;
    state.playing = false;
    state.fps     = 7.5;     % default cine playback rate

    % --- Image pane ---
    state.ax_img = axes(fig, 'Position', [0.04 0.18 0.66 0.78]);
    state.h_img  = imagesc(state.ax_img, D.vol(:,:,1));
    colormap(state.ax_img, gray);
    axis(state.ax_img, 'image', 'off');

    % --- Frame slider ---
    state.sl = uicontrol(fig, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.04 0.10 0.66 0.04], ...
        'Min', 1, 'Max', max(2, D.n_frames), 'Value', 1, ...
        'SliderStep', [1, 5] / max(1, D.n_frames - 1), ...
        'Callback', @(s,~) on_slider(s));
    state.txt_idx = uicontrol(fig, 'Style', 'text', ...
        'Units', 'normalized', 'Position', [0.04 0.05 0.66 0.04], ...
        'BackgroundColor', 'w', 'FontSize', 11, ...
        'String', '', 'HorizontalAlignment', 'center');

    % --- Play/pause + fps ---
    state.btn_play = uicontrol(fig, 'Style', 'togglebutton', ...
        'Units', 'normalized', 'Position', [0.04 0.005 0.10 0.04], ...
        'String', '▶ Play', 'FontSize', 11, ...
        'Callback', @(b,~) on_play(b));
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.16 0.005 0.06 0.04], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'String', 'fps:');
    state.edit_fps = uicontrol(fig, 'Style', 'edit', ...
        'Units', 'normalized', 'Position', [0.22 0.005 0.06 0.04], ...
        'String', sprintf('%.1f', state.fps), 'FontSize', 11, ...
        'Callback', @(e,~) on_fps(e));

    % --- Save snapshot ---
    uicontrol(fig, 'Style', 'pushbutton', ...
        'Units', 'normalized', 'Position', [0.55 0.005 0.15 0.04], ...
        'String', 'Save snapshot…', 'FontSize', 10, ...
        'Callback', @(~,~) save_snapshot());

    % --- Right-side metadata panel ---
    panel = uipanel(fig, 'Units', 'normalized', 'Position', [0.72 0.04 0.26 0.93], ...
        'BackgroundColor', 'w', 'Title', 'DICOM metadata', 'FontSize', 10);
    uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.04 0.04 0.92 0.92], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontName', 'Menlo', ...
        'HorizontalAlignment', 'left', 'String', metadata_string(D));

    set(fig, 'WindowButtonDownFcn', @(~,~) on_button_down());

    apply_view();
    fig.UserData = state;

    % --- Nested callbacks ---
    function on_slider(s)
        state.idx = round(s.Value);
        s.Value = state.idx;
        apply_view();
        fig.UserData = state;
    end
    function apply_view()
        state.h_img.CData = state.D.vol(:, :, state.idx);
        W = state.WL(1); L = state.WL(2);
        clim(state.ax_img, [L - W/2, L + W/2]);
        state.txt_idx.String = sprintf('Frame %d / %d   (W=%.0f, L=%.0f)', ...
            state.idx, state.D.n_frames, W, L);
    end
    function on_play(b)
        state.playing = b.Value;
        if b.Value
            b.String = '⏸ Pause';
            t = tic;
            while state.playing && isvalid(fig)
                state.idx = mod(state.idx, state.D.n_frames) + 1;
                state.sl.Value = state.idx;
                apply_view();
                pause(1 / max(1, state.fps));
                if ~isgraphics(b) || ~b.Value; break; end
            end
            if isgraphics(b); b.String = '▶ Play'; end
        else
            b.String = '▶ Play';
        end
        if isvalid(fig); fig.UserData = state; end
    end
    function on_fps(e)
        v = str2double(e.String);
        if ~isnan(v) && v > 0; state.fps = v; end
        fig.UserData = state;
    end
    function on_button_down()
        if strcmp(get(fig, 'SelectionType'), 'alt')
            set(fig, 'WindowButtonMotionFcn', @(~,~) on_drag());
            set(fig, 'WindowButtonUpFcn',     @(~,~) on_release());
            state.drag_start = get(fig, 'CurrentPoint');
            state.WL_start   = state.WL;
            fig.UserData = state;
        end
    end
    function on_drag()
        cur = get(fig, 'CurrentPoint');
        delta = cur - state.drag_start;
        state.WL(1) = max(1, state.WL_start(1) + delta(1) * 4);
        state.WL(2) =        state.WL_start(2) - delta(2) * 2;
        apply_view();
        fig.UserData = state;
    end
    function on_release()
        set(fig, 'WindowButtonMotionFcn', '');
        set(fig, 'WindowButtonUpFcn',     '');
    end
    function save_snapshot()
        [name, path] = uiputfile('snapshot.png', 'Save snapshot');
        if name == 0; return; end
        exportgraphics(fig, fullfile(path, name), 'Resolution', 200);
    end
end

% =========================================================================
% Helpers
% =========================================================================
function s = figure_title(D, override)
    if ~isempty(override); s = override; return; end
    s = sprintf('%s — %s — %s', D.modality, D.patient_id, D.series_description);
end

function s = metadata_string(D)
    L = {};
    L{end+1} = sprintf('Modality:    %s',         D.modality);
    L{end+1} = sprintf('Patient ID:  %s',         D.patient_id);
    L{end+1} = sprintf('Study date:  %s',         D.study_date);
    L{end+1} = sprintf('Series:      %s',         D.series_description);
    L{end+1} = sprintf('Image:       %d × %d',    D.rows, D.cols);
    L{end+1} = sprintf('Frames:      %d',         D.n_frames);
    L{end+1} = sprintf('Pixel:       %.3f × %.3f mm', D.pixel_mm(1), D.pixel_mm(2));
    if D.is_volume
        L{end+1} = sprintf('Slice spc:   %.3f mm', D.slice_spacing_mm);
        L{end+1} = sprintf('Z-extent:    %.0f mm', D.slice_z_mm(end) - D.slice_z_mm(1));
        L{end+1} = sprintf('HU range:    [%.0f, %.0f]', min(D.vol(:)), max(D.vol(:)));
    end
    if ~isempty(D.carm_pose)
        L{end+1} = '';
        L{end+1} = '─── C-arm pose ───';
        cp = D.carm_pose;
        L{end+1} = sprintf('Primary:     %+.1f°', cp.primary_angle);
        L{end+1} = sprintf('Secondary:   %+.1f°', cp.secondary_angle);
        L{end+1} = sprintf('SID:         %.0f mm', cp.SID);
        L{end+1} = sprintf('SOD:         %.0f mm', cp.SOD);
    end
    s = strjoin(L, newline);
end
