function verify_ap_view_only()
%VERIFY_AP_VIEW_ONLY  Load JohnDoe1 CT, let auto-segment + auto-crop fire,
%   capture ONLY the 3-D Volume AP view of the segmented aorta. No
%   centerline, no CPR, no landmarks. Stops where the user told us to
%   stop: at the 3-D recon view of the CT scan.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    out_dir = fullfile(proj, 'results', 'figures', 'audit');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end

    cache = fullfile(proj, 'results', 'logs', 'ct_volume.mat');
    fprintf('Loading cached JohnDoe1 CT from %s …\n', cache);
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
    % 2× downsample for audit speed (matches audit_full_workflow.m)
    D.vol = D.vol(1:2:end, 1:2:end, 1:2:end);
    if isfield(D, 'slice_z_mm')
        D.slice_z_mm = D.slice_z_mm(1:2:end);
    end
    D.pixel_mm = D.pixel_mm * 2;
    D.slice_spacing_mm = D.slice_spacing_mm * 2;
    fprintf('  audit vol size (2× downsampled): %s\n', mat2str(size(D.vol)));

    a = app.AorticCenterlineApp();
    cleanup = onCleanup(@() delete(a));
    drawnow; pause(0.4);

    fprintf('Loading volume — auto-segment + auto-crop fires inside doLoad…\n');
    a.loadVolumeStruct(D);
    drawnow; pause(1.0);

    % Force the 3-D Volume mode (the AP-view recon). buildStep3 may
    % have flipped to 3-D MIP; flip back here.
    a.setView('3dvol');
    drawnow; pause(1.2);
    out_png = fullfile(out_dir, 'AP_view_3dvol_after_load.png');
    a.captureMain(out_png);
    fprintf('Captured AP view → %s\n', out_png);
    fprintf('STOP. No centerline, no CPR, no landmarks per user.\n');
end
