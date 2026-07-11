% Driver: render JohnDoe2 + JohnDoe1 via isosurface + patch (GPU-free, fast).
cd('/Users/davidstonko/Documents/Claude/Projects/Vascular Mathematical Modeling/phase-3-real-EVAR');
addpath(genpath(pwd));

out_dir = fullfile(pwd, 'results', 'figures', 'segmentation_recon');
if ~exist(out_dir, 'dir'); mkdir(out_dir); end

cases = struct( ...
    'name', {'johndoe2', 'johndoe1'}, ...
    'mat',  {fullfile(pwd,'results','logs','johndoe2_pass1','planner_result.mat'), ...
             fullfile(pwd,'results','logs','johndoe1_post_johndoe2_fix','planner_result.mat')});

views = {'iso','anterior','lateral'};

for ci = 1:numel(cases)
    for vi = 1:numel(views)
        try
            fname = sprintf('%s_iso_%s.png', cases(ci).name, views{vi});
            out_png = fullfile(out_dir, fname);
            fprintf('=> %s (%s)\n', cases(ci).name, views{vi});
            t0 = tic;
            render_recon_isosurface(cases(ci).mat, out_png, views{vi});
            fprintf('   done in %.1fs\n', toc(t0));
        catch ME
            fprintf('ERROR on %s/%s: %s\n', cases(ci).name, views{vi}, ME.message);
            for k = 1:numel(ME.stack)
                fprintf('   %s line %d\n', ME.stack(k).name, ME.stack(k).line);
            end
        end
    end
end
disp('=== ALL DONE ===');
