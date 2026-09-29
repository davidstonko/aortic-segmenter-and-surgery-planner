function warm_centerline_cache()
%WARM_CENTERLINE_CACHE  Precompute + disk-cache the VMTK centerline AND the
%   whole planner result for the two real cases (JohnDoe1, JohnDoe2) so an
%   interactive run_planner_headless / GUI runAutoPipeline on either scan is
%   instant. Safe to run on a parallel worker (batch).
%
%   Requires PRIVATE case data: cached CT volumes for the two development
%   cases in the git-ignored results/logs/ folder (never distributed). Edit
%   CASE_CACHE_DIR below if your cached volumes live elsewhere.
proj = fileparts(fileparts(mfilename('fullpath')));   % repo root
% --- EDIT: folder holding the locally cached CT volumes (.mat, private) ---
CASE_CACHE_DIR = fullfile(proj, 'results', 'logs');
cd(proj);
addpath(proj); addpath(fullfile(proj, 'scripts'));
cases = { fullfile(CASE_CACHE_DIR, 'ct_volume.mat'),   'D_ct';   % JohnDoe1
          fullfile(CASE_CACHE_DIR, 'johndoe2_ct.mat'), 'D'    }; % JohnDoe2
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
