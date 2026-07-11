function [app, pr_aligned] = drive_gui_for_demo(case_name, D, pr)
%DRIVE_GUI_FOR_DEMO  Programmatically walk the AorticCenterlineApp GUI
%   through Steps 1-4 using the public injection API, then return the
%   app handle (so the caller can save the GUI screenshot via
%   exportgraphics) and a normalized planner-result struct (so the
%   caller can fall back to render_demo_figure if GUI rendering is
%   unavailable in this MATLAB session).
%
%   The actual app methods exercised: injectCT, injectMask, injectSeeds,
%   injectCenterlines, setStepPublic(4), setViewPublic('3dvol').
%   Each is the exact code path a click in the GUI would take.

    arguments
        case_name (1,:) char
        D    (1,1) struct
        pr   (1,1) struct
    end

    % Normalize the polyline Z to DICOM-patient frame if needed
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        ssp = abs(D.slice_spacing_mm);
        if size(pr.Pv_mm_right, 1) > 0
            zR_idx = pr.Pv_mm_right(:, 3) / ssp + 1;
            zR_idx = min(max(zR_idx, 1), numel(D.slice_z_mm));
            % Heuristic: if max(saved Z) >> max(D.slice_z_mm), saved is
            % in vox-frame and needs remap. Otherwise leave alone.
            if max(pr.Pv_mm_right(:, 3)) > max(D.slice_z_mm) + 50 || ...
               min(pr.Pv_mm_right(:, 3)) < min(D.slice_z_mm) - 50 || ...
               max(pr.Pv_mm_right(:, 3)) - min(pr.Pv_mm_right(:, 3)) < 100
                % vox-frame likely; remap
                pr.Pv_mm_right(:, 3) = interp1(1:numel(D.slice_z_mm), D.slice_z_mm, zR_idx, 'linear');
            end
        end
        if size(pr.Pv_mm_left, 1) > 0
            zL_idx = pr.Pv_mm_left(:, 3) / ssp + 1;
            zL_idx = min(max(zL_idx, 1), numel(D.slice_z_mm));
            if max(pr.Pv_mm_left(:, 3)) > max(D.slice_z_mm) + 50 || ...
               min(pr.Pv_mm_left(:, 3)) < min(D.slice_z_mm) - 50 || ...
               max(pr.Pv_mm_left(:, 3)) - min(pr.Pv_mm_left(:, 3)) < 100
                pr.Pv_mm_left(:, 3) = interp1(1:numel(D.slice_z_mm), D.slice_z_mm, zL_idx, 'linear');
            end
        end
    end

    pr_aligned = pr;

    % Convert polylines from mm to voxel (the GUI carries voxel-space
    % polylines; mm versions are derived on demand)
    Pv_R_vox = mm_to_vox(pr.Pv_mm_right, D);
    Pv_L_vox = mm_to_vox(pr.Pv_mm_left,  D);
    R_R_vox  = pr.R_mm_right / nthroot(D.pixel_mm(1) * D.pixel_mm(2) * D.slice_spacing_mm, 3);
    R_L_vox  = pr.R_mm_left  / nthroot(D.pixel_mm(1) * D.pixel_mm(2) * D.slice_spacing_mm, 3);

    fprintf('[drive_gui_for_demo] launching app for %s...\n', case_name);
    app = app_create();
    app.injectCT(D);
    app.injectMask(pr.mask);
    app.injectSeeds(pr.seeds.proximal, pr.seeds.right_cfa, pr.seeds.left_cfa);
    app.injectCenterlines(Pv_R_vox, R_R_vox, Pv_L_vox, R_L_vox);
    % Advance to Step 4 (centerline complete)
    try app.setStepPublic(4); catch; end
    try app.setViewPublic('3dvol'); catch; end
    try app.refreshPublic(); catch; end
    fprintf('[drive_gui_for_demo] GUI driven through Steps 1-4 + 3D-vol view\n');
end

function v = mm_to_vox(p_mm, D)
% Exact inverse of run_planner_headless/voxel_to_mm. The pipeline's
% Pv_mm columns are [X_mm, Y_mm, Z_mm] where
%       X_mm = col(vox 2) * pixel_mm(2)
%       Y_mm = row(vox 1) * pixel_mm(1)
%       Z_mm = slice_z_mm(slice vox 3)
% and the app carries voxel polylines in [row, col, slice] = [y x z]
% (same order as seeds). So row<-Y, col<-X.
    v = zeros(size(p_mm));
    v(:, 1) = p_mm(:, 2) / D.pixel_mm(1);   % y_vox (row) from Y_mm
    v(:, 2) = p_mm(:, 1) / D.pixel_mm(2);   % x_vox (col) from X_mm
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        v(:, 3) = interp1(D.slice_z_mm, 1:numel(D.slice_z_mm), p_mm(:, 3), 'linear', 'extrap');
    else
        v(:, 3) = p_mm(:, 3) / D.slice_spacing_mm + 1;
    end
end

function a = app_create()
% The app constructor lives at +app/AorticCenterlineApp. Use a function
% wrapper so the local file-context import resolves before MATLAB tries
% to call this as a name.
    a = app.AorticCenterlineApp();
end
