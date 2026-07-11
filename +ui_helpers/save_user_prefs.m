function save_user_prefs(prefs)
%UI_HELPERS.SAVE_USER_PREFS  Persist UI-only preferences to disk.
%
%   ui_helpers.save_user_prefs(PREFS)
%
%   Writes PREFS (a struct) to ~/.aortic_centerline_prefs.json. Used to
%   carry the User-driven / Automatic toggle state and the first-launch
%   tour-shown flag between sessions. No PHI or patient data — only UI
%   preferences belong here.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        prefs (1,1) struct
    end
    path = prefs_path();
    try
        fid = fopen(path, 'w');
        if fid < 0
            warning('ui_helpers:save_user_prefs:Open', ...
                'Cannot open %s for writing.', path);
            return;
        end
        cleanup = onCleanup(@() fclose(fid));
        fprintf(fid, '%s', jsonencode(prefs, 'PrettyPrint', true));
    catch ME
        warning('ui_helpers:save_user_prefs:Write', ...
            'Failed to write prefs (%s).', ME.message);
    end
end

function p = prefs_path()
    home = char(java.lang.System.getProperty('user.home'));
    p = fullfile(home, '.aortic_centerline_prefs.json');
end
