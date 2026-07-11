function status = check_dependencies()
%SETUP.CHECK_DEPENDENCIES  Probe all external tools the EVAR planner can
%   optionally use. Returns a struct the GUI feeds into status pills.
%
%   STATUS = setup.check_dependencies()
%       .totalsegmentator  struct from autoseg.detect()
%       .vmtk              struct from vmtk_centerline.detect()
%       .matlab_toolboxes  struct of required MATLAB toolboxes:
%                          .image_processing  (niftiread/write, imclose,
%                                              imreconstruct, fibermetric)
%                          .computer_vision   (optional: 3D reduction)
%
%   The status struct is intentionally simple — every field can be
%   passed to a label/pill widget that just reads `available` and
%   `error`. Cache it on the app once at startup.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    status = struct();
    status.totalsegmentator = autoseg.detect();
    status.vmtk             = vmtk_centerline.detect();

    % MATLAB toolbox presence
    v = ver;
    have = @(n) any(strcmpi({v.Name}, n));
    status.matlab_toolboxes = struct( ...
        'image_processing',     have('Image Processing Toolbox'), ...
        'computer_vision',      have('Computer Vision Toolbox'), ...
        'parallel_computing',   have('Parallel Computing Toolbox'));

    % When called without an output target, print a clean human-readable
    % summary instead of dumping the raw struct. This is the standard
    % MATLAB pattern: `setup.check_dependencies` shows the table,
    % `s = setup.check_dependencies()` is silent.
    if nargout == 0
        ok = @(b) ternary_str(b, '✓', '✗');
        fprintf('\n  EVAR Planner — dependency check\n');
        fprintf('  ───────────────────────────────────────────────\n');
        fprintf('  External CLIs (optional but recommended):\n');
        fprintf('    %s  TotalSegmentator   %s\n', ok(status.totalsegmentator.available), ...
            ternary_str(status.totalsegmentator.available, ...
                       status.totalsegmentator.version, ...
                       status.totalsegmentator.error));
        fprintf('    %s  VMTK               %s\n', ok(status.vmtk.available), ...
            ternary_str(status.vmtk.available, status.vmtk.path_centerlines, ...
                        sprintf('%s', status.vmtk.error)));
        fprintf('\n  MATLAB toolboxes:\n');
        fprintf('    %s  Image Processing Toolbox    (required)\n', ...
            ok(status.matlab_toolboxes.image_processing));
        fprintf('    %s  Computer Vision Toolbox     (optional)\n', ...
            ok(status.matlab_toolboxes.computer_vision));
        fprintf('    %s  Parallel Computing Toolbox  (optional)\n', ...
            ok(status.matlab_toolboxes.parallel_computing));
        fprintf('\n');
        if ~status.matlab_toolboxes.image_processing
            fprintf('  WARNING: Image Processing Toolbox is required.\n\n');
        end
        clear status;   % don't dump the struct after the table
    end
end

function s = ternary_str(b, a, c)
    if b; s = a; else; s = c; end
end
