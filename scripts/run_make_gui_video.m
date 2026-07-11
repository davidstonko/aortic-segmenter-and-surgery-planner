close all force
clear classes
proj = fileparts(fileparts(mfilename('fullpath')));
addpath(proj);
addpath(fullfile(proj, 'scripts'));
out_path = make_gui_video();
fprintf('OK: %s\n', out_path);
