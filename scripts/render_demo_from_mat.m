function render_demo_from_mat()
%RENDER_DEMO_FROM_MAT  Render the 2-panel demo figure (3D recon +
%   bifurcated centerline) for JohnDoe1 and JohnDoe2 from the already-saved
%   planner_result.mat files (results/logs/<case>_leakfix/). Used when the
%   end-to-end driver saved the result but a downstream QC step errored.

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(proj));
    figdir = fullfile(proj, 'results', 'figures');
    if ~exist(figdir, 'dir'); mkdir(figdir); end

    cases = {'JohnDoe1', 'JohnDoe2'};
    for ci = 1:numel(cases)
        nm = cases{ci};
        matf = fullfile(proj, 'results', 'logs', ...
            sprintf('%s_leakfix', lower(nm)), 'planner_result.mat');
        fprintf('\n===== %s =====\n', nm);
        if ~isfile(matf)
            fprintf('  SKIP — no planner_result.mat at %s\n', matf);
            continue;
        end
        S = load(matf);
        % run_planner_headless saves with '-struct', so fields are at top level.
        pr = S;
        png = fullfile(figdir, sprintf('demo_%s_leakfix.png', lower(nm)));
        try
            render_demo_figure(pr, nm, png);
            fprintf('  SAVED -> %s\n', png);
        catch ME
            fprintf('  ERROR rendering %s: %s\n', nm, ME.message);
            for k = 1:numel(ME.stack)
                fprintf('     %s line %d\n', ME.stack(k).name, ME.stack(k).line);
            end
        end
    end
    fprintf('\n=== render_demo_from_mat DONE ===\n');
end
