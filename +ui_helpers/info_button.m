function btn = info_button(parent, position, help_key, ui_figure)
%UI_HELPERS.INFO_BUTTON  Render the small ⓘ button that opens a help modal.
%
%   btn = ui_helpers.info_button(PARENT, [X Y W H], HELP_KEY, UI_FIGURE)
%
%   PARENT      target container (typically app.SideContent)
%   POSITION    [x, y, w, h] in container coords. For consistency with
%               the rest of the GUI, width and height are usually 20×20.
%   HELP_KEY    string key into +ui_helpers/help_content.m's registry.
%   UI_FIGURE   the app's top-level uifigure (so the modal anchors to it).
%
%   Returns the uibutton handle so the caller can adjust tooltip, tag,
%   etc. if it needs to.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        parent
        position    (1,4) double
        help_key    (1,:) char
        ui_figure
    end
    % Plain lowercase "i" with bold weight on a circular-looking blue
    % background. Unicode ⓘ (char 9432) at 13pt in a 20-px button
    % was visibly off-centre because the glyph's intrinsic centroid
    % isn't aligned with its bounding-box centre on most fonts. A
    % bare "i" rendered by the OS hits the geometric centre of the
    % button reliably.
    btn = uibutton(parent, 'push', ...
        'Position', position, ...
        'Text', 'i', ...
        'FontSize', 11, ...
        'FontWeight', 'bold', ...
        'BackgroundColor', [0.93 0.95 1.00], ...
        'FontColor', [0.20 0.35 0.65], ...
        'Tooltip', 'Click for help', ...
        'Tag', ['info_' help_key], ...
        'ButtonPushedFcn', @(~,~) ui_helpers.show_help_modal(ui_figure, help_key));
end
