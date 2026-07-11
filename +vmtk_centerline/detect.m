function info = detect()
%VMTK_CENTERLINE.DETECT  Locate the VMTK CLI on PATH or in conda envs.
%
%   INFO = vmtk_centerline.detect()  returns:
%       INFO.available        logical
%       INFO.python           string — python interpreter that imports vmtk
%       INFO.path_centerlines string — path to the vmtkcenterlines script
%       INFO.path_marching    string — path to vmtkmarchingcubes
%       INFO.path_branchsections string — path to vmtkbranchsections
%       INFO.invocation       string — "<python> <vmtkcenterlines>" prefix
%                                      (use this to launch any VMTK script
%                                      so the shebang's `env python` does
%                                      not resolve to a python without VMTK)
%       INFO.version          string
%       INFO.error            string — reason if unavailable

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    info = struct('available', false, 'python', '', ...
                  'path_centerlines', '', 'path_marching', '', ...
                  'path_branchsections', '', ...
                  'invocation', '', 'version', '', 'error', '');

    % Build a candidate list of (python, bin_dir) pairs to probe. First
    % whatever's on PATH; then common conda env locations.
    home = char(java.lang.System.getProperty('user.home'));
    conda_roots = {fullfile(home, 'miniforge3'), ...
                   fullfile(home, 'miniconda3'), ...
                   fullfile(home, 'anaconda3'), ...
                   fullfile(home, 'mambaforge')};
    env_names = {'vmtk', 'vmtk-env', 'vascular'};

    candidates = {struct('python', 'python', ...
                         'bin_dir', '', ...
                         'desc', 'PATH')};
    for ri = 1:numel(conda_roots)
        for ei = 1:numel(env_names)
            env_bin = fullfile(conda_roots{ri}, 'envs', env_names{ei}, 'bin');
            py = fullfile(env_bin, 'python');
            if isfile(py)
                candidates{end+1} = struct( ...
                    'python',  py, ...
                    'bin_dir', env_bin, ...
                    'desc',    sprintf('conda env %s', env_names{ei})); %#ok<AGROW>
            end
        end
    end

    for k = 1:numel(candidates)
        c = candidates{k};
        if isempty(c.bin_dir)
            % Need to resolve binaries via PATH
            [rc1, w1] = system(sprintf('command -v vmtkcenterlines 2>/dev/null'));
            [rc2, w2] = system(sprintf('command -v vmtkmarchingcubes 2>/dev/null'));
            [rc3, w3] = system(sprintf('command -v vmtkbranchsections 2>/dev/null'));
            if rc1 ~= 0 || rc2 ~= 0
                continue;
            end
            cl_path = strtrim(w1); mc_path = strtrim(w2);
            bs_path = strtrim(w3);
        else
            cl_path = fullfile(c.bin_dir, 'vmtkcenterlines');
            mc_path = fullfile(c.bin_dir, 'vmtkmarchingcubes');
            bs_path = fullfile(c.bin_dir, 'vmtkbranchsections');
            if ~isfile(cl_path) || ~isfile(mc_path); continue; end
        end

        % Probe — does this python import vmtk?
        [rc, ~] = system(sprintf( ...
            '%s -c "from vmtk import pypeserver" 2>&1', c.python));
        if rc ~= 0; continue; end

        info.available           = true;
        info.python              = c.python;
        info.path_centerlines    = cl_path;
        info.path_marching       = mc_path;
        info.path_branchsections = bs_path;
        info.invocation          = sprintf('%s %s', c.python, cl_path);
        info.version             = sprintf('%s (%s)', c.desc, cl_path);
        return;
    end

    info.error = sprintf(['VMTK CLI tools not found. Install via:\n' ...
        '  CONDA_SUBDIR=osx-64 conda create -n vmtk -c vmtk -c conda-forge vmtk python=3.9\n' ...
        '  (on Apple Silicon the osx-64 build is needed because there is no\n' ...
        '   native arm64 build as of VMTK 1.5).']);
end
