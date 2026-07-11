function saved_path = save_case(case_struct, lib_root)
%LIBRARY.SAVE_CASE  Append a centerlined-aorta case to the local library.
%
%   PATH = library.save_case(CASE_STRUCT)
%   PATH = library.save_case(CASE_STRUCT, LIB_ROOT)
%
%   Saves a struct of EVAR centerline data into the local library
%   folder. The library is just a flat directory of .mat files plus a
%   summary index (`index.csv`) so you can browse cases in MATLAB or
%   Excel without loading every file.
%
%   File naming convention
%       <patient_id>_<study_date>_<HHMMSS>.mat
%   where HHMMSS is the time the case was added to the library, so
%   re-segmenting the same scan does not overwrite the previous entry.
%
%   Required fields on CASE_STRUCT
%       Pv_mm       N x 3 centerline polyline (mm)
%       R_mm        N x 1 inscribed-sphere radius (mm)
%       mask        Y x X x Z logical aorta mask (optional but useful)
%       dicom_meta  struct with .patient_id, .study_date, .pixel_mm,
%                   .slice_spacing_mm, .series (optional)
%
%   Optional fields are saved verbatim (e.g. seeds, click_log,
%   landmarks, EVAR measurements). The library entry also stamps
%   a `saved_at` ISO datetime.
%
%   The index is rebuilt from scratch on every save so deleted cases
%   drop out automatically.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        case_struct (1,1) struct
        lib_root    (1,:) char  = ''
    end

    if isempty(lib_root)
        % Default: <project root>/library/, where project root is
        % wherever +library lives (i.e. one level up from this file).
        here = fileparts(mfilename('fullpath'));
        lib_root = fullfile(fileparts(here), 'library');
    end
    if ~exist(lib_root, 'dir'); mkdir(lib_root); end

    % --- Validate minimum payload ----
    must = {'Pv_mm', 'R_mm'};
    for k = 1:numel(must)
        if ~isfield(case_struct, must{k})
            error('library:save_case:Missing', ...
                'case_struct.%s is required.', must{k});
        end
    end

    % --- Build a stable filename ----
    if isfield(case_struct, 'dicom_meta') && isstruct(case_struct.dicom_meta)
        meta = case_struct.dicom_meta;
        pid  = sanitize(field_or(meta, 'patient_id', 'ANON'));
        sd   = sanitize(field_or(meta, 'study_date', 'no-date'));
    else
        pid = 'ANON'; sd = 'no-date';
    end
    stamp = datestr(now, 'HHMMSS'); %#ok<DATST,TNOW1>
    fname = sprintf('%s_%s_%s.mat', pid, sd, stamp);
    saved_path = fullfile(lib_root, fname);

    % --- Stamp + save ----
    case_struct.saved_at      = datestr(now, 'yyyy-mm-ddTHH:MM:SS'); %#ok<DATST,TNOW1>
    case_struct.library_entry = fname;

    save(saved_path, '-struct', 'case_struct');

    % --- Rebuild the index from scratch -----
    library.rebuild_index(lib_root);
end

% =========================================================================
function s = sanitize(v)
    if isempty(v); s = 'unknown'; return; end
    if isnumeric(v); v = num2str(v); end
    s = regexprep(char(v), '[^A-Za-z0-9._-]', '_');
    if isempty(s); s = 'unknown'; end
end

function v = field_or(s, name, default)
    if isfield(s, name) && ~isempty(s.(name)); v = s.(name);
    else; v = default;
    end
end
