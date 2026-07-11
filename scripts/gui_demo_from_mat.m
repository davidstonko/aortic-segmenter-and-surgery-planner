function gui_demo_from_mat()
%GUI_DEMO_FROM_MAT  Produce the GUI-driven half of the 4-image demo.
%   For JohnDoe1 and JohnDoe2: load the DICOM (for the app's CT volume),
%   load the leak-fixed planner_result.mat, drive AorticCenterlineApp
%   through Steps 1-4 + the 3D-volume view via the public injection API
%   (drive_gui_for_demo), then screenshot the live app to
%   results/figures/gui_<case>_leakfix.png. The app's 3dvol view masks
%   the CT to the segmentation (V(~mask)=-1000) so the render shows the
%   segmented aorta + iliacs with the bifurcated centerline overlaid.
%
%   The app window is deleted after each case (no stale GUI windows).

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(proj));
    figdir = fullfile(proj, 'results', 'figures');
    if ~exist(figdir, 'dir'); mkdir(figdir); end

    base = fileparts(proj);   % .../Vascular Mathematical Modeling
    % De-identified case paths (placeholder folder names).
    cases = {
        'JohnDoe1',     fullfile(base, 'JohnDoe1 EVAR', 'export', 'JohnDoe1', 'series')
        'JohnDoe2', fullfile(base, 'CTs and Angios', 'JohnDoe2', 'export', 'JohnDoe2', 'series')
    };

    for ci = 1:size(cases, 1)
        nm  = cases{ci, 1};
        dcm = cases{ci, 2};
        fprintf('\n===== %s =====\n', nm);
        matf = fullfile(proj, 'results', 'logs', ...
            sprintf('%s_leakfix', lower(nm)), 'planner_result.mat');
        if ~isfile(matf)
            fprintf('  SKIP — no planner_result.mat at %s\n', matf); continue;
        end
        pr = load(matf);

        app = [];
        try
            fprintf('  loading DICOM for CT volume...\n');
            D = preprocess.dicom_load(dcm);
            [app, ~] = drive_gui_for_demo(nm, D, pr);
            try app.setViewPublic('3dvol'); catch; end
            try app.refreshPublic();        catch; end
            drawnow; pause(4);   % let viewer3d ray-cast settle
            png = fullfile(figdir, sprintf('gui_%s_leakfix.png', lower(nm)));
            exportapp(app.UIFigure, png);
            fprintf('  SAVED -> %s\n', png);
        catch ME
            fprintf('  ERROR on %s: %s\n', nm, ME.message);
            for k = 1:numel(ME.stack)
                fprintf('     %s line %d\n', ME.stack(k).name, ME.stack(k).line);
            end
        end
        if ~isempty(app) && isvalid(app); delete(app); end
    end
    fprintf('\n=== gui_demo_from_mat DONE ===\n');
end
