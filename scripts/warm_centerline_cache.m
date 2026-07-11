function warm_centerline_cache()
%WARM_CENTERLINE_CACHE  Precompute + disk-cache the VMTK centerline AND the
%   whole planner result for the two real cases (JohnDoe1, JohnDoe2) so an
%   interactive run_planner_headless / GUI runAutoPipeline on either scan is
%   instant. Safe to run on a parallel worker (batch).
proj = '/Users/davidstonko/Documents/Claude/Projects/Vascular Mathematical Modeling/phase-3-real-EVAR';
cd(proj);
addpath(proj); addpath(fullfile(proj, 'scripts'));
cases = { fullfile(proj, 'results','logs','ct_volume.mat'),    'D_ct';   % JohnDoe1
          fullfile(proj, 'results','logs','johndoe2_ct.mat'), 'D'    }; % JohnDoe2
for i = 1:size(cases, 1)
    L = load(cases{i, 1});
    D = L.(cases{i, 2});
    opts = struct('D', D, 'centerline_backend', 'auto', ...
        'out_dir', fullfile(tempdir, sprintf('warm_cl_%d', i)));
    fprintf('=== warming case %d (%s) ===\n', i, cases{i, 1});
    run_planner_headless('', opts);
end
fprintf('=== warm_centerline_cache DONE ===\n');
end
