function rebuild_index(lib_root)
%LIBRARY.REBUILD_INDEX  Refresh the human-readable index.csv next to the cases.
%
%   library.rebuild_index() walks the default library folder and
%   writes index.csv with one row per case (patient_id, study_date,
%   arc length, median lumen radius, etc.). The CSV is regenerated
%   from scratch so deletions/renames stay consistent.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        lib_root (1,:) char = ''
    end

    if isempty(lib_root)
        here = fileparts(mfilename('fullpath'));
        lib_root = fullfile(fileparts(here), 'library');
    end
    T = library.list_cases(lib_root);
    out = fullfile(lib_root, 'index.csv');
    if isempty(T)
        if exist(out, 'file'); delete(out); end
        return;
    end
    writetable(T, out);
end
