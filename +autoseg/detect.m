function info = detect()
%AUTOSEG.DETECT  Locate the TotalSegmentator CLI on PATH.
%
%   INFO = autoseg.detect()  returns:
%       INFO.available  logical — true if the CLI was found and runs
%       INFO.path       string  — absolute path to the executable
%       INFO.version    string  — reported version (or '' if probe failed)
%       INFO.error      string  — reason if .available is false
%
%   We probe by running `TotalSegmentator -v`. If that fails we
%   fall back to `python -m totalsegmentator -v` so users who
%   pip-installed into an active conda env are picked up too.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    info = struct('available', false, 'path', '', 'version', '', ...
                  'error', '', 'invocation', '');

    % TotalSegmentator's argparse uses -v for "verbose" (not version), so
    % `TotalSegmentator -v` errors with "required: -i, -o". The long-form
    % --version flag prints the version cleanly and exits 0.
    %
    % Build candidates: first PATH (works if user activated the env
    % before launching MATLAB), then absolute paths for common conda
    % env layouts (miniforge3 / miniconda3 / anaconda3, env names
    % evar-tools / totalseg / total / base) so we find a pip-installed
    % TS even when MATLAB inherits a vanilla shell.
    home = char(java.lang.System.getProperty('user.home'));
    abs_candidates = {};
    conda_roots = {fullfile(home, 'miniforge3'), ...
                   fullfile(home, 'miniconda3'), ...
                   fullfile(home, 'anaconda3'), ...
                   fullfile(home, 'mambaforge')};
    env_names = {'evar-tools', 'totalseg', 'total', 'tsenv'};
    for ri = 1:numel(conda_roots)
        % bin in env root (base env)
        abs_candidates{end+1} = fullfile(conda_roots{ri}, 'bin', 'TotalSegmentator'); %#ok<AGROW>
        for ei = 1:numel(env_names)
            abs_candidates{end+1} = fullfile(conda_roots{ri}, ...
                'envs', env_names{ei}, 'bin', 'TotalSegmentator'); %#ok<AGROW>
        end
    end
    % Also wildcard-glob any envs to catch user-named envs
    for ri = 1:numel(conda_roots)
        envs_dir = fullfile(conda_roots{ri}, 'envs');
        if isfolder(envs_dir)
            d = dir(envs_dir);
            for i = 1:numel(d)
                if d(i).isdir && ~ismember(d(i).name, {'.', '..'})
                    abs_candidates{end+1} = fullfile(envs_dir, d(i).name, ...
                        'bin', 'TotalSegmentator'); %#ok<AGROW>
                end
            end
        end
    end

    candidates = { ...
        'TotalSegmentator --version', ...
        'totalsegmentator --version', ...
        'python -m totalsegmentator --version', ...
        'python3 -m totalsegmentator --version'};
    for ai = 1:numel(abs_candidates)
        if isfile(abs_candidates{ai})
            candidates{end+1} = sprintf('%s --version', abs_candidates{ai}); %#ok<AGROW>
        end
    end

    for k = 1:numel(candidates)
        cmd = candidates{k};
        [rc, out] = system(cmd);
        if rc == 0
            info.available  = true;
            info.invocation = strrep(cmd, ' --version', '');
            info.version    = strtrim(out);
            % Extract the executable path for diagnostics
            [~, w] = system(sprintf('which %s 2>/dev/null', strtok(cmd)));
            info.path = strtrim(w);
            if isempty(info.path) && isfile(strtok(cmd))
                info.path = strtok(cmd);
            end
            return;
        end
    end
    info.error = 'TotalSegmentator not found on PATH or in conda envs.';
end
