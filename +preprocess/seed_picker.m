function seeds = seed_picker(D, varargin)
%SEED_PICKER  Interactive 2-click seed picker for aortic centerline.
%
%   SEEDS = SEED_PICKER(D) opens an interactive figure showing the CT
%   volume with axial scrolling, lets the user navigate to two
%   different slices and click on the aorta in each, and returns a
%   2x3 array of voxel coordinates [y x z; y x z] for use with
%   preprocess.track_aorta_2click.
%
%   The viewer opens at the **CTA / Vessel** window/level (W=600,
%   L=200) so contrast-enhanced vessels are immediately visible.
%   Slice 1 of the volume is the **head** (with the descending-z sort
%   in dicom_load) so head is at the top of coronal/sagittal MIPs.
%
%   Usage flow:
%       1. Scroll the axial slider to a slice in the proximal aorta
%          (typically just below the celiac, where the aorta is a
%          single round bright lumen anterior to the spine).
%       2. Click "Pick proximal seed" → click on the aorta lumen.
%       3. Scroll to a distal slice (iliac terminus, pelvic floor).
%       4. Click "Pick distal seed" → click on the iliac lumen.
%       5. Click "Done" → seeds are returned as a 2×3 array.
%
%   Optional name-value:
%       'WindowLevel' : initial [W L] (default [600 200] for CTA)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    p = inputParser;
    p.addRequired('D');
    p.addParameter('WindowLevel', [700, 150]);   % CTA / Vessel preset
    p.parse(D, varargin{:});
    opts = p.Results;

    if ischar(D) || isstring(D)
        D = preprocess.dicom_load(D, true);
    end
    assert(D.is_volume, 'seed_picker:NotVolume', 'D must be a CT volume.');

    [Ny, Nx, Nz] = size(D.vol);

    state = struct();
    state.D       = D;
    state.WL      = opts.WindowLevel;
    state.idx     = round(Nz / 2);
    state.proximal = [];
    state.distal   = [];
    state.next_pick = '';   % 'proximal' or 'distal' or ''

    fig = figure('Name', 'Aortic seed picker', 'Color', 'w', ...
                 'Position', [40 40 1200 900], 'Toolbar', 'figure', ...
                 'Menubar', 'none', 'CloseRequestFcn', @(~,~) on_close());

    % Axial pane
    state.ax = axes(fig, 'Position', [0.04 0.18 0.66 0.78]);
    state.h_img = imagesc(state.ax, D.vol(:, :, state.idx));
    colormap(state.ax, gray);
    axis(state.ax, 'image', 'off');
    title(state.ax, sprintf('Axial slice %d / %d   (CTA window)', state.idx, Nz));
    set(state.ax, 'YDir', 'reverse');   % anterior at top of axial

    % Slice slider
    state.sl = uicontrol(fig, 'Style', 'slider', ...
        'Units', 'normalized', 'Position', [0.04 0.10 0.66 0.04], ...
        'Min', 1, 'Max', Nz, 'Value', state.idx, ...
        'SliderStep', [1, 20] / max(1, Nz - 1), ...
        'Callback', @(s,~) on_slider(s.Value));
    state.txt_idx = uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.04 0.06 0.66 0.04], 'BackgroundColor', 'w', ...
        'FontSize', 11, 'String', '');

    % Right panel: pick buttons + status + done
    panel = uipanel(fig, 'Units', 'normalized', 'Position', [0.72 0.04 0.26 0.93], ...
        'BackgroundColor', 'w', 'Title', 'Seed picker', 'FontSize', 11);

    uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.04 0.85 0.92 0.10], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontAngle', 'italic', ...
        'HorizontalAlignment', 'left', ...
        'String', sprintf(['Scroll to a proximal slice (suprarenal aorta), click "Pick proximal seed", then click on the aorta lumen.\n\n' ...
                           'Scroll to a distal slice (iliac terminus), click "Pick distal seed", then click again.']));

    state.btn_prox = uicontrol(panel, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.05 0.72 0.9 0.08], 'String', 'Pick proximal seed', ...
        'FontSize', 11, 'FontWeight', 'bold', ...
        'Callback', @(~,~) arm_pick('proximal'));
    state.txt_prox = uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.66 0.9 0.05], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontName', 'Menlo', 'HorizontalAlignment', 'left', ...
        'String', '  proximal: <not picked>');

    state.btn_dist = uicontrol(panel, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.05 0.55 0.9 0.08], 'String', 'Pick distal seed', ...
        'FontSize', 11, 'FontWeight', 'bold', ...
        'Callback', @(~,~) arm_pick('distal'));
    state.txt_dist = uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.49 0.9 0.05], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontName', 'Menlo', 'HorizontalAlignment', 'left', ...
        'String', '  distal:    <not picked>');

    % Window/level presets
    uicontrol(panel, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.05 0.40 0.9 0.04], 'BackgroundColor', 'w', ...
        'FontSize', 10, 'FontWeight', 'bold', ...
        'String', 'Window/level presets', 'HorizontalAlignment', 'left');
    presets = {'CTA',[700 150]; 'Abdomen',[400 40]; 'Bone',[1500 400]};
    for i = 1:size(presets,1)
        uicontrol(panel, 'Style', 'pushbutton', 'Units', 'normalized', ...
            'Position', [0.05 0.36 - 0.05*(i-1) 0.4 0.04], ...
            'String', presets{i,1}, 'FontSize', 9, ...
            'Callback', @(~,~) set_WL(presets{i,2}));
    end

    state.btn_done = uicontrol(panel, 'Style', 'pushbutton', 'Units', 'normalized', ...
        'Position', [0.05 0.06 0.9 0.10], 'String', 'Done — return seeds', ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'BackgroundColor', [0.85 1 0.85], ...
        'Callback', @(~,~) on_done());

    % Image click handler
    set(state.h_img, 'ButtonDownFcn', @(~, evt) on_image_click(evt));

    apply_view();
    fig.UserData = state;

    % Block until user clicks Done
    uiwait(fig);
    if isvalid(fig); s = fig.UserData; else; s = state; end
    seeds = [s.proximal; s.distal];
    if isvalid(fig); delete(fig); end

    % --- nested callbacks ---
    function on_slider(v)
        state.idx = round(v);
        state.sl.Value = state.idx;
        apply_view();
        fig.UserData = state;
    end
    function set_WL(WL_new)
        state.WL = WL_new;
        apply_view();
        fig.UserData = state;
    end
    function arm_pick(which)
        state.next_pick = which;
        title(state.ax, sprintf('CLICK on the aorta to set %s seed (slice %d)', which, state.idx));
        fig.UserData = state;
    end
    function on_image_click(evt)
        if isempty(state.next_pick); return; end
        pt = evt.IntersectionPoint;
        x = round(pt(1)); y = round(pt(2));
        if x < 1 || x > Nx || y < 1 || y > Ny; return; end
        coord = [y, x, state.idx];
        if strcmp(state.next_pick, 'proximal')
            state.proximal = coord;
            state.txt_prox.String = sprintf('  proximal: [y=%d, x=%d, z=%d]', coord);
        else
            state.distal = coord;
            state.txt_dist.String = sprintf('  distal:    [y=%d, x=%d, z=%d]', coord);
        end
        state.next_pick = '';
        apply_view();
        fig.UserData = state;
    end
    function apply_view()
        state.h_img.CData = state.D.vol(:, :, state.idx);
        W = state.WL(1); L = state.WL(2);
        clim(state.ax, [L - W/2, L + W/2]);
        title(state.ax, sprintf('Axial slice %d / %d   W=%.0f L=%.0f', ...
            state.idx, Nz, W, L));
        state.txt_idx.String = sprintf('Slice %d / %d  (z = %.1f mm)', ...
            state.idx, Nz, state.D.slice_z_mm(state.idx));
        % Overlay any picked seeds that are on the current slice
        delete(findobj(state.ax, 'Tag', 'seed_overlay'));
        if ~isempty(state.proximal) && state.proximal(3) == state.idx
            hold(state.ax, 'on');
            plot(state.ax, state.proximal(2), state.proximal(1), 'go', ...
                 'MarkerFaceColor', 'g', 'MarkerSize', 12, ...
                 'Tag', 'seed_overlay');
        end
        if ~isempty(state.distal) && state.distal(3) == state.idx
            hold(state.ax, 'on');
            plot(state.ax, state.distal(2), state.distal(1), 'rs', ...
                 'MarkerFaceColor', 'r', 'MarkerSize', 12, ...
                 'Tag', 'seed_overlay');
        end
    end
    function on_done()
        uiresume(fig);
    end
    function on_close()
        uiresume(fig);
    end
end
