function frames = capture_gui_frames()
%CAPTURE_GUI_FRAMES  Open the AorticCenterlineApp, step through 1→5,
%   getframe(UIFigure) ONCE per step. Returns a cell array of frame
%   structs. Lean enough to fit inside the MCP 60s budget.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    cd(proj); addpath(proj);

    L  = load(fullfile(proj, 'results/logs/ct_volume.mat'), 'D_ct');
    D  = L.D_ct;
    Sv = load(fullfile(proj, 'results/logs/headless_v2/planner_result.mat'));

    frames = {};

    a = app.AorticCenterlineApp();
    pause(2.0);   % banner + initial layout
    drawnow;
    frames{end+1} = struct('caption', '1. Launch — research-only banner', 'img', getframe(a.UIFigure).cdata);

    % Step 1
    a.injectCT(D);
    a.setStepPublic(1);
    pause(1.0); drawnow; pause(0.5);
    frames{end+1} = struct('caption', '1. CT loaded (DICOM ingest)', 'img', getframe(a.UIFigure).cdata);

    % Step 2: inject mask + advance, capture after volshow renders
    a.injectMask(Sv.mask);
    a.setStepPublic(2);
    pause(3.0); drawnow; pause(1.0);   % volshow 3D recon needs time
    frames{end+1} = struct('caption', '2. Segmentation (3D recon)', 'img', getframe(a.UIFigure).cdata);

    % Step 3: auto seeds
    a.injectSeeds(Sv.seeds.proximal, Sv.seeds.right_cfa, Sv.seeds.left_cfa);
    a.setStepPublic(3);
    pause(1.0); drawnow; pause(0.5);
    frames{end+1} = struct('caption', '3. Auto-detected endpoints', 'img', getframe(a.UIFigure).cdata);

    % Step 4: centerlines
    pix = D.pixel_mm;
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        z_to_vox = @(z) interp1(D.slice_z_mm, 1:numel(D.slice_z_mm), z, 'linear', 'extrap');
    else
        z_to_vox = @(z) z / D.slice_spacing_mm + 1;
    end
    pv_to_vox = @(P) [P(:,2)/pix(1) + 1, P(:,1)/pix(2) + 1, z_to_vox(P(:,3))];
    PvR_vox = pv_to_vox(Sv.Pv_mm_right);
    PvL_vox = pv_to_vox(Sv.Pv_mm_left);
    a.injectCenterlines(PvR_vox, Sv.R_mm_right/mean(pix), PvL_vox, Sv.R_mm_left/mean(pix), ...
        round(size(PvR_vox,1) * 0.6));
    a.setStepPublic(4);
    pause(1.5); drawnow; pause(0.5);
    frames{end+1} = struct('caption', '4. Bifurcated centerline', 'img', getframe(a.UIFigure).cdata);

    % Step 5: analyze
    a.setStepPublic(5);
    pause(1.0); drawnow; pause(0.5);
    frames{end+1} = struct('caption', '5. Analyze + IFU device match', 'img', getframe(a.UIFigure).cdata);

    save(fullfile(proj, 'results', 'videos', 'gui_frames.mat'), 'frames', '-v7.3');
    try; close(a.UIFigure); catch; end %#ok<NOSEM>
    fprintf('Captured %d frames.\n', numel(frames));
end
