function prefs = load_user_prefs()
%UI_HELPERS.LOAD_USER_PREFS  Read the user's per-machine preferences.
%
%   PREFS = ui_helpers.load_user_prefs()
%
%   Returns a struct loaded from ~/.aortic_centerline_prefs.json (or an
%   empty struct if the file is missing/unreadable). Used by the GUI to
%   persist the User-driven / Automatic toggle state, the Help menu's
%   first-launch flag, and any future per-user settings.
%
%   No PHI / patient data ever lives in this file — only UI preferences.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    prefs = struct();
    path = prefs_path();
    if ~isfile(path); return; end
    try
        txt = fileread(path);
        if isempty(strtrim(txt)); return; end
        raw = jsondecode(txt);
        if isstruct(raw); prefs = raw; end
    catch ME
        warning('ui_helpers:load_user_prefs:Read', ...
            'Could not read %s (%s) — starting with empty prefs.', ...
            path, ME.message);
    end
end

function p = prefs_path()
    home = char(java.lang.System.getProperty('user.home'));
    p = fullfile(home, '.aortic_centerline_prefs.json');
end
