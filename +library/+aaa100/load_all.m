function cases = load_all()
%LIBRARY.AAA100.LOAD_ALL  Load all 100 AAA-100 reference centerlines.
%
%   cases = library.aaa100.load_all()
%
%   Returns a 1x100 struct array, one entry per AAA case, with fields:
%       .case_id                 'AAA001' .. 'AAA100'
%       .aorta, .iliac_L,        (:,3) double, mm scanner coords [X, Y, Z],
%       .iliac_R, .renal_L,      proximal → distal node ordering
%       .renal_R
%       .aorta_radius, ...       (:,1) double radius per node (0 if not in VTP)
%
%   Reads `aaa100_centerlines.mat` from `library.aaa100.cache_root()`. If
%   the cache does not exist, calls the Python bulk converter
%   (+library/+aaa100/bulk_convert_vtp.py) to build it from the
%   centerlines/AAAxxx/*.vtp tree. Requires `vtk` and `scipy` Python
%   packages.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    root = library.aaa100.cache_root();
    mat_path = fullfile(root, 'aaa100_centerlines.mat');
    if ~isfile(mat_path)
        ensure_cache_from_vtp(root, mat_path);
    end
    S = load(mat_path, 'cases');
    % scipy.io.savemat writes cell-of-struct rather than struct array;
    % convert to a struct array for the rest of the codebase.
    if iscell(S.cases)
        cases = [S.cases{:}];
    else
        cases = S.cases;
    end
end

function ensure_cache_from_vtp(root, mat_path)
% Build the centerline MAT cache from VTP files. Requires Python+vtk+scipy.
    vtp_dir = fullfile(root, 'centerlines');
    if ~isfolder(vtp_dir)
        zip_path = fullfile(root, 'centerlines.zip');
        if ~isfile(zip_path)
            error('library:aaa100:missing_data', ...
                ['No centerlines found under %s. Download centerlines.zip from ' ...
                 'https://zenodo.org/records/10932957 into %s, or run the ' ...
                 'project''s data-download script.'], vtp_dir, root);
        end
        unzip(zip_path, root);
    end
    here = fileparts(mfilename('fullpath'));
    py_script = fullfile(here, 'bulk_convert_vtp.py');
    if ~isfile(py_script)
        error('library:aaa100:missing_converter', ...
            'Python converter not found at %s.', py_script);
    end
    cmd = sprintf('python3 "%s" "%s" "%s"', py_script, vtp_dir, mat_path);
    [status, out] = system(cmd);
    if status ~= 0
        error('library:aaa100:converter_failed', ...
            'bulk_convert_vtp.py failed (status %d):\n%s', status, out);
    end
    if ~isfile(mat_path)
        error('library:aaa100:converter_no_output', ...
            'Converter ran without error but %s was not created. Output:\n%s', ...
            mat_path, out);
    end
end
