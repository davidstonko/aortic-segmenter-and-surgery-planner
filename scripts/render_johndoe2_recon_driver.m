% Driver: render JohnDoe2 3-D segmentation recon (iso view).
cd('/Users/davidstonko/Documents/Claude/Projects/Vascular Mathematical Modeling/phase-3-real-EVAR');
out_dir = fullfile(pwd, 'results', 'figures', 'segmentation_recon');
if ~exist(out_dir, 'dir'); mkdir(out_dir); end
result_mat = fullfile(pwd, 'results', 'logs', 'johndoe2_pass1', 'planner_result.mat');
render_segmentation_recon(result_mat, fullfile(out_dir, 'johndoe2_recon_iso.png'), 'iso');
disp('=== iso done ===');
