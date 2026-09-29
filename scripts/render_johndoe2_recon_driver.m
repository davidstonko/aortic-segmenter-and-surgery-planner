% Driver: render JohnDoe2 3-D segmentation recon (iso view).
%
% Requires PRIVATE case data: planner_result.mat files from earlier local
% runs, stored in the git-ignored results/ folder (never distributed). Edit
% CASE_RESULTS_DIR below to point at your own planner outputs.
cd(fileparts(fileparts(mfilename('fullpath'))));   % repo root
% --- EDIT: folder holding local planner_result.mat outputs (private) ---
CASE_RESULTS_DIR = fullfile(pwd, 'results', 'logs');
addpath(pwd); addpath(fullfile(pwd, 'scripts'));
out_dir = fullfile(pwd, 'results', 'figures', 'segmentation_recon');
if ~exist(out_dir, 'dir'); mkdir(out_dir); end
result_mat = fullfile(CASE_RESULTS_DIR, 'johndoe2_pass1', 'planner_result.mat');
render_segmentation_recon(result_mat, fullfile(out_dir, 'johndoe2_recon_iso.png'), 'iso');
disp('=== iso done ===');
