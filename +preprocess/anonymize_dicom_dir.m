function info = anonymize_dicom_dir(src, opts)
%PREPROCESS.ANONYMIZE_DICOM_DIR  Wrap `dicognito` to re-write DICOM files
%   in place with PHI removed and UIDs re-mapped consistently across a
%   cohort.
%
%   INFO = preprocess.anonymize_dicom_dir(SRC)
%   INFO = preprocess.anonymize_dicom_dir(SRC, OPTS)
%
%   Differs from the `anonymize=true` flag on `preprocess.dicom_load` —
%   that only blanks PHI in the in-memory struct, the source DICOM
%   files on disk are untouched. This function uses
%   `dicognito` (https://github.com/blairconrad/dicognito, MIT) to
%   rewrite the FILES so the cohort can be safely shared or committed.
%
%   Run BEFORE moving real cases into the local case library.
%
%   Inputs
%       SRC     path to a folder of DICOM files (modified in place)
%       OPTS    struct with optional fields:
%           .python      python interpreter that has dicognito installed
%                        (default: auto-detect via `which dicognito`)
%           .salt        seed for dicognito's UID re-mapping (default '')
%           .dry_run     true to print the command without running it
%
%   Returns INFO struct with .invocation (the command run), .ok, .stderr.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        src  (1,:) char
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'dry_run'); opts.dry_run = false; end
    if ~isfield(opts, 'salt');    opts.salt    = '';    end

    info = struct('invocation', '', 'ok', false, 'stderr', '');

    if ~isfolder(src)
        error('preprocess:anonymize_dicom_dir:NotFolder', ...
              'Not a directory: %s', src);
    end

    % Locate dicognito. If opts.python is set, use that interpreter's
    % installed dicognito; otherwise fall back to `which dicognito`.
    if isfield(opts, 'python') && ~isempty(opts.python)
        [rc, w] = system(sprintf('%s -m pip show dicognito 2>&1', opts.python));
        if rc ~= 0
            error('preprocess:anonymize_dicom_dir:NotInstalled', ...
                ['dicognito not installed in %s.\n' ...
                 'Install with: %s -m pip install dicognito'], ...
                opts.python, opts.python);
        end
        cli = sprintf('%s -m dicognito', opts.python);
    else
        [rc, w] = system('which dicognito 2>/dev/null');
        if rc ~= 0 || isempty(strtrim(w))
            error('preprocess:anonymize_dicom_dir:NotInstalled', ...
                ['dicognito not found on PATH. Install with:\n' ...
                 '  pip install dicognito']);
        end
        cli = strtrim(w);
    end

    parts = {cli, '--in-place'};
    if ~isempty(opts.salt)
        parts{end+1} = '--seed'; parts{end+1} = ['"', opts.salt, '"'];
    end
    parts{end+1} = ['"', src, '"'];
    cmd = strjoin(parts, ' ');
    info.invocation = cmd;

    if opts.dry_run
        fprintf('[anonymize_dicom_dir] DRY RUN: would invoke:\n  %s\n', cmd);
        info.ok = true;
        return;
    end

    fprintf('[anonymize_dicom_dir] %s\n', cmd);
    [rc, out] = system(cmd);
    info.stderr = out;
    info.ok = (rc == 0);
    if ~info.ok
        error('preprocess:anonymize_dicom_dir:Failed', ...
              'dicognito failed (rc=%d):\n%s', rc, out);
    end
end
