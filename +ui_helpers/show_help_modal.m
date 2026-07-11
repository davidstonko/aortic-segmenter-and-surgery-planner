function show_help_modal(ui_figure, help_key)
%UI_HELPERS.SHOW_HELP_MODAL  Open a modal dialog showing a help entry.
%
%   ui_helpers.show_help_modal(UI_FIGURE, HELP_KEY)
%
%   Pulls the entry from +ui_helpers/help_content.m and renders title + body +
%   optional "When to use" + "What Automatic mode does" sections in a
%   resizable modal anchored on UI_FIGURE.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        ui_figure
        help_key (1,:) char
    end
    entry = ui_helpers.help_content(help_key);
    if isempty(entry.title) && isempty(entry.body)
        uialert(ui_figure, ...
            sprintf('No help available for "%s".', help_key), ...
            'Help missing', 'Icon', 'warning');
        return;
    end

    % Compose the full body text. uialert wraps and scrolls long content.
    parts = {entry.body};
    if ~isempty(entry.when)
        parts{end+1} = '';
        parts{end+1} = ['When to use: ', entry.when];
    end
    if ~isempty(entry.auto)
        parts{end+1} = '';
        parts{end+1} = ['Automatic mode: ', entry.auto];
    end
    msg = strjoin(parts, newline);

    if isempty(entry.title)
        title = 'Help';
    else
        title = entry.title;
    end
    uialert(ui_figure, msg, title, ...
        'Icon', 'info', ...
        'Interpreter', 'none', ...
        'Modal', true);
end
