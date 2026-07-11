function verify_step1_only()
%VERIFY_STEP1_ONLY  Load JohnDoe1 CT, capture the 3-D recon AP view at
%   end of Step 1. No auto-segment, no auto-crop, no Step advance.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    out_dir = fullfile(proj, 'results', 'figures', 'audit');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end

    cache = fullfile(proj, 'results', 'logs', 'ct_volume.mat');
    fprintf('Loading cached JohnDoe1 CT…\n');
    S = load(cache);
    if isfield(S, 'D_ct'); D = S.D_ct;
    elseif isfield(S, 'D'); D = S.D;
    else
        fns = fieldnames(S);
        for k = 1:numel(fns)
            if isstruct(S.(fns{k})) && isfield(S.(fns{k}), 'vol')
                D = S.(fns{k}); break;
            end
        end
    end
    % 2× downsample for audit speed
    D.vol = D.vol(1:2:end, 1:2:end, 1:2:end);
    if isfield(D, 'slice_z_mm')
        D.slice_z_mm = D.slice_z_mm(1:2:end);
    end
    D.pixel_mm = D.pixel_mm * 2;
    D.slice_spacing_mm = D.slice_spacing_mm * 2;
    fprintf('  vol size: %s\n', mat2str(size(D.vol)));

    a = app.AorticCenterlineApp();
    cleanup = onCleanup(@() delete(a));
    drawnow; pause(0.4);

    fprintf('Loading volume — should land on 3-D recon AP view, Step 1.\n');
    a.loadVolumeStruct(D);
    drawnow; pause(0.5);
    % volshow + viewer3d need a beat to initialize on a fresh instance.
    % Spin drawnow over several seconds to let GPU init complete.
    for k = 1:8
        drawnow; pause(0.5);
    end

    out_png = fullfile(out_dir, 'step1_3d_recon_AP.png');
    a.captureMain(out_png);
    fprintf('Captured Step-1 AP view → %s\n', out_png);

    % Sanity prints — none of these should indicate auto-segment fired.
    cs = a.currentCaseStruct();
    fprintf('  mask voxels = %d (expect 0)\n', sum(cs.mask(:)));
    fprintf('  vol size after load = %s (expect %s — no crop)\n', ...
        mat2str(a.volSize()), mat2str(size(D.vol)));
end
