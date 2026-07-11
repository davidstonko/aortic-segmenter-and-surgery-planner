function render_demo_leakfix()
%RENDER_DEMO_LEAKFIX  Regenerate the two headless demo figures (3D recon +
%   bifurcated centerline) for JohnDoe1 and JohnDoe2 using the leak-fixed
%   pipeline (tube-confined adaptive follower + vessel-area leak guard).
%   Runs run_planner_headless end-to-end (mask + VMTK centerline) for each
%   case, saves planner_result.mat, and writes demo_<case>.png.

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(proj));
    figdir = fullfile(proj, 'results', 'figures');
    if ~exist(figdir, 'dir'); mkdir(figdir); end
    parent = fileparts(proj);

    cases = struct( ...
        'name', {'JohnDoe1', 'JohnDoe2'}, ...
        'dir',  { fullfile(parent, 'JohnDoe1 EVAR', 'export', ...
                           'JohnDoe1', 'series'), ...
                  fullfile(parent, 'CTs and Angios', 'JohnDoe2', ...
                           'export', 'JohnDoe2', 'series') });

    for ci = 1:numel(cases)
        nm = cases(ci).name;
        droot = cases(ci).dir;
        fprintf('\n===== %s =====\n', nm);
        if ~isfolder(droot)
            fprintf('  SKIP — DICOM dir not found: %s\n', droot);
            continue;
        end
        opts = struct();
        opts.out_dir = fullfile(proj, 'results', 'logs', ...
            sprintf('%s_leakfix', lower(nm)));
        opts.verbose = true;
        try
            t0 = tic;
            pr = run_planner_headless(string(droot), opts);
            fprintf('  planner done in %.1f s\n', toc(t0));
            png = fullfile(figdir, sprintf('demo_%s_leakfix.png', lower(nm)));
            render_demo_figure(pr, nm, png);
            fprintf('  SAVED -> %s\n', png);
        catch ME
            fprintf('  ERROR on %s: %s\n', nm, ME.message);
            for k = 1:numel(ME.stack)
                fprintf('     %s line %d\n', ME.stack(k).name, ME.stack(k).line);
            end
        end
    end
    fprintf('\n=== render_demo_leakfix DONE ===\n');
end
