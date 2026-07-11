%REGENERATE_PHANTOMS  Build all four phantom .mat files in library/.
%
%   Run this when the phantom builders change, or after deleting the
%   library to start clean. Output:
%
%       library/PHANTOM_normal_male.mat        (labeled, ~0.2 MB)
%       library/PHANTOM_normal_male_raw.mat    (raw,    ~12 MB)
%       library/PHANTOM_aaa_male.mat           (labeled)
%       library/PHANTOM_aaa_male_raw.mat       (raw)
%
%   Labeled = mask + centerlines + seeds + landmarks (no .vol — the
%             synthetic CT is rehydrated on load via synth_ct_from_mask).
%   Raw     = synthetic CT volume + spatial metadata only. The CT is
%             stored as int16 + HDF5 deflate to keep files ~12 MB.
%
%   The "raw" companion is what the GUI's "Open phantom" button loads;
%   it represents the case AS A USER WOULD ENCOUNTER IT (no labels).
%   The labeled file is the answer key — load it directly to compare
%   your work against the ground-truth segmentation and centerline.

%   Project: AINN/EVAR (Phase 3)

here = fileparts(mfilename('fullpath'));
proj = fileparts(here);
addpath(proj);
lib = fullfile(proj, 'library');
if ~exist(lib, 'dir'); mkdir(lib); end

% --- Step 1/4: build normal-anatomy phantom + save labeled ---------
fprintf('Step 1/4 — building PHANTOM_normal_male (labeled)…\n');
P_norm = phantom.build_normal_male();
% Strip .vol (rehydrated on load from .mask) — keeps the labeled file
% compact (~0.2 MB instead of ~80 MB).
P_norm = rmfield(P_norm, 'vol');
save(fullfile(lib, 'PHANTOM_normal_male.mat'), '-struct', 'P_norm', '-v7.3');

fprintf('Step 2/4 — building PHANTOM_aaa_male (labeled)…\n');
P_aaa = phantom.build_aaa_male();
P_aaa = rmfield(P_aaa, 'vol');
save(fullfile(lib, 'PHANTOM_aaa_male.mat'), '-struct', 'P_aaa', '-v7.3');

% --- Steps 3-4: raw companions ------------------------------------
fprintf('Step 3/4 — saving raw companion of normal male…\n');
phantom.save_raw_companion('PHANTOM_normal_male');

fprintf('Step 4/4 — saving raw companion of AAA male…\n');
phantom.save_raw_companion('PHANTOM_aaa_male');

fprintf('\nDone. Library now contains:\n');
files = dir(fullfile(lib, 'PHANTOM_*.mat'));
for k = 1:numel(files)
    fprintf('  %-44s  %5.1f MB\n', files(k).name, files(k).bytes/1024/1024);
end
