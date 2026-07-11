function pos_below = step_mode_toggle(parent, y_top, current_mode, on_change, ui_figure)
%UI_HELPERS.STEP_MODE_TOGGLE  Render the User-driven / Automatic toggle that
%   sits at the top of every step's side panel.
%
%   y_below = ui_helpers.step_mode_toggle(PARENT, Y_TOP, CURRENT_MODE, ON_CHANGE, UI_FIGURE)
%
%   PARENT        target container (app.SideContent)
%   Y_TOP         y-coordinate of the TOP of this widget; the function
%                 lays itself out downward.
%   CURRENT_MODE  'user' (default) or 'auto' — sets the initial selection.
%   ON_CHANGE     callback fired when the user picks the other mode.
%                 Signature: @(new_mode) ...   where new_mode is 'user'
%                 or 'auto'. Use this to re-render the rest of the
%                 panel.
%   UI_FIGURE     the top-level uifigure (needed so the ⓘ button can
%                 anchor its help modal).
%
%   Returns Y_BELOW, the y-coordinate just below the rendered widget,
%   so the caller can keep placing content underneath.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        parent
        y_top        (1,1) double
        current_mode (1,:) char {mustBeMember(current_mode, {'user', 'auto'})} = 'user'
        on_change    (1,1) function_handle = @(~) []
        ui_figure                          = []
    end

    % Layout convention used throughout this side panel:
    %   - x=10 left margin
    %   - content width = 360 (so x+w = 370 ≤ 380-px panel width with
    %     a 10-px right margin)
    %   - info button at x=10+CONTENT_W-22 = 348 (right-aligned in the
    %     content area, NOT past the panel edge).
    CONTENT_W = 360;
    HEADER_H  = 22;
    BUTTON_H  = 32;
    LBL_H     = 18;
    GAP       = 6;

    y = y_top - HEADER_H;
    % Heading + info button on the same line
    uilabel(parent, 'Position', [10 y CONTENT_W-26 HEADER_H], ...
        'Text', 'Mode', 'FontSize', 12, 'FontWeight', 'bold', ...
        'FontColor', [0.20 0.20 0.20]);
    if ~isempty(ui_figure)
        ui_helpers.info_button(parent, [10 + CONTENT_W - 22 y 20 20], ...
            'app.mode_toggle', ui_figure);
    end
    y = y - GAP - BUTTON_H;

    % Two big toggle buttons, side by side
    grp = uibuttongroup(parent, ...
        'Position', [10 y CONTENT_W BUTTON_H + 4], ...
        'BorderType', 'line', ...
        'BorderColor', [0.75 0.78 0.85], ...
        'BackgroundColor', [0.98 0.98 0.99], ...
        'Tag', 'step_mode_group', ...
        'SelectionChangedFcn', @(g,e) on_change(e.NewValue.Tag));

    tb_user = uitogglebutton(grp, ...
        'Position', [2 2 (CONTENT_W-4)/2 BUTTON_H], ...
        'Text', '👤  User-driven', ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'Tag', 'user', ...
        'Value', strcmp(current_mode, 'user')); %#ok<NASGU>
    tb_auto = uitogglebutton(grp, ...
        'Position', [(CONTENT_W-4)/2 + 2 2 (CONTENT_W-4)/2 BUTTON_H], ...
        'Text', '⚡  Automatic', ...
        'FontSize', 12, 'FontWeight', 'bold', ...
        'Tag', 'auto', ...
        'Value', strcmp(current_mode, 'auto')); %#ok<NASGU>

    y = y - GAP - LBL_H;
    if strcmp(current_mode, 'user')
        hint = 'You drive every control. Hover for tooltips, click ⓘ for details.';
    else
        hint = 'One button runs the whole step end-to-end with defaults.';
    end
    uilabel(parent, 'Position', [10 y CONTENT_W LBL_H], ...
        'Tag', 'step_mode_hint', ...
        'Text', hint, 'FontSize', 11, 'FontColor', [0.40 0.40 0.45]);

    y = y - 12;   % final padding under the widget
    pos_below = y;
end
