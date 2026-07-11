function y_below = section_header(parent, y_top, title, color, help_key, ui_figure)
%UI_HELPERS.SECTION_HEADER  Render a section title with an optional ⓘ button.
%
%   y_below = ui_helpers.section_header(PARENT, Y_TOP, TITLE, COLOR, HELP_KEY, UI_FIGURE)
%
%   Reuses the visual style the existing GUI already uses for section
%   headers (the in-app `sectionHdr` helper) but extends it with an
%   info-button on the right. Pass HELP_KEY = '' to skip the info button.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        parent
        y_top      (1,1) double
        title      (1,:) char
        color      (1,3) double = [0.20 0.20 0.55]
        help_key   (1,:) char   = ''
        ui_figure              = []
    end
    % Content width = 360 (panel is 380 with 10-px margins on each side).
    % Using PANEL_W=380 at x=10 here overflowed the panel right edge by
    % 10 px (visible in audit pass 2).
    CONTENT_W = 360;
    H = 24;
    y = y_top - H;
    has_info = ~isempty(help_key) && ~isempty(ui_figure);
    label_w = CONTENT_W - (has_info * 24);
    uilabel(parent, 'Position', [10 y label_w H], ...
        'Text', title, 'FontSize', 12, 'FontWeight', 'bold', ...
        'FontColor', color);
    if has_info
        ui_helpers.info_button(parent, [10 + CONTENT_W - 22 y+2 20 20], help_key, ui_figure);
    end
    y_below = y - 6;
end
