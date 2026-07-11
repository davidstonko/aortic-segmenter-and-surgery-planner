function render_pipeline_demo()
%RENDER_PIPELINE_DEMO  Build a 4-panel summary figure of the AAA phantom
%   driven through the full EVAR-planner pipeline. Used for the README
%   and for the audit/handoff snapshot — proves the pipeline works
%   end-to-end without launching the GUI.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    P     = phantom.load_from_library('PHANTOM_aaa_male');
    D_raw = phantom.to_D_struct(P, struct('strip_labels', true));
    mask  = logical(P.mask);
    seeds = P.seeds_vox;

    opts = struct('min_branch_length', 30, ...
                  'radius_weight_pow', 2, ...
                  'smooth_per_segment', 5);
    [Pv_R, Rv_R] = preprocess.centerline_skeleton(mask, seeds.right_cfa, seeds.proximal, opts);
    [Pv_L, Rv_L] = preprocess.centerline_skeleton(mask, seeds.left_cfa,  seeds.proximal, opts);

    [kR, kL] = bifurc(Pv_R, Pv_L, 3.0);
    Pv_L = Pv_L(1:kL, :); Rv_L = Rv_L(1:kL);

    [Pmm_R, Rmm_R] = preprocess.centerline_to_mm(Pv_R, Rv_R, D_raw);
    [Pmm_L, Rmm_L] = preprocess.centerline_to_mm(Pv_L, Rv_L, D_raw);

    n_R = size(Pmm_R, 1);
    lm  = struct('renal_index', n_R - round(0.03 * n_R), 'bifurc_index', kR);
    M   = preprocess.evar_measurements(Pmm_R, Rmm_R, Pmm_L, Rmm_L, kR, lm);

    fig = figure('Visible','off', 'Color','w', 'Position',[100 100 1600 900]);

    % --- Left: coronal MIP + centerlines ---
    subplot('Position', [0.03 0.06 0.32 0.86]);
    mip = squeeze(max(D_raw.vol, [], 1)).';
    imagesc(mip); colormap gray; axis image; axis off; clim([-200 700]); hold on;
    plot(Pv_R(:,2), Pv_R(:,3), '-', 'Color',[0.95 0.20 0.20], 'LineWidth',2);
    plot(Pv_L(:,2), Pv_L(:,3), '-', 'Color',[0.20 0.45 0.95], 'LineWidth',2);
    plot(Pv_R(kR,2), Pv_R(kR,3), 'p', 'MarkerFaceColor',[0.95 0.10 0.95], 'MarkerEdgeColor','k', 'MarkerSize',16);
    plot(seeds.proximal(2),  seeds.proximal(3),  'o', 'MarkerFaceColor',[0.10 0.85 0.10], 'MarkerEdgeColor','k', 'MarkerSize',12);
    plot(seeds.right_cfa(2), seeds.right_cfa(3), 'o', 'MarkerFaceColor',[0.95 0.20 0.20], 'MarkerEdgeColor','k', 'MarkerSize',12);
    plot(seeds.left_cfa(2),  seeds.left_cfa(3),  'o', 'MarkerFaceColor',[0.20 0.45 0.95], 'MarkerEdgeColor','k', 'MarkerSize',12);
    title('Step 2-4: dual centerlines + 3 seeds + bifurc', 'FontSize',13, 'FontWeight','bold');

    % --- Middle top: diameter profile ---
    subplot('Position', [0.40 0.55 0.27 0.4]);
    arcR = [0; cumsum(vecnorm(diff(Pmm_R,1,1), 2, 2))];
    arcL = [0; cumsum(vecnorm(diff(Pmm_L,1,1), 2, 2))];
    plot(arcR, 2*Rmm_R, '-', 'Color',[0.85 0.10 0.10], 'LineWidth',1.8); hold on;
    plot(arcL + (arcR(kR) - arcL(end)), 2*Rmm_L, '-', 'Color',[0.10 0.30 0.85], 'LineWidth',1.8);
    xline(arcR(kR), '--m', 'aortic bifurc', 'LabelVerticalAlignment','top');
    xline(arcR(lm.renal_index), '--', 'renal', 'Color',[0.4 0.4 0.4], 'LabelVerticalAlignment','top');
    grid on; xlabel('arc s (mm)'); ylabel('diameter (mm)');
    title('Step 5: dual diameter profile', 'FontSize',13, 'FontWeight','bold');
    legend({'right CL','left CL'}, 'Location','best', 'FontSize',9);

    % --- Middle bottom: measurements ---
    subplot('Position', [0.40 0.06 0.27 0.45]); axis off;
    txt = { ...
        '─── Aortic neck ──────────────'; ...
        sprintf('  length:       %s', mmStr(M.aortic_neck.length_mm)); ...
        sprintf('  diameter:     %s', mmStr(M.aortic_neck.diameter_mm)); ...
        sprintf('  angulation:   %s', degStr(M.aortic_neck.angulation_deg)); ...
        sprintf('  conicity:     %s mm/cm', vStr(M.aortic_neck.conicity_mm_per_cm, 2)); ...
        ''; ...
        '─── Aneurysm sac ─────────────'; ...
        sprintf('  max diameter: %s', mmStr(M.aneurysm.max_diameter_mm)); ...
        sprintf('  length:       %s', mmStr(M.aneurysm.length_mm)); ...
        ''; ...
        '─── Right iliac ──────────────'; ...
        sprintf('  CIA diameter: %s', mmStr(M.iliac.right.cia_diameter_mm)); ...
        sprintf('  EIA diameter: %s', mmStr(M.iliac.right.eia_diameter_mm)); ...
        sprintf('  length:       %s', mmStr(M.iliac.right.length_mm)); ...
        sprintf('  tortuosity:   %s', vStr(M.iliac.right.tortuosity, 3)); ...
        ''; ...
        '─── Left iliac ───────────────'; ...
        sprintf('  CIA diameter: %s', mmStr(M.iliac.left.cia_diameter_mm)); ...
        sprintf('  EIA diameter: %s', mmStr(M.iliac.left.eia_diameter_mm)); ...
        sprintf('  length:       %s', mmStr(M.iliac.left.length_mm)); ...
        sprintf('  tortuosity:   %s', vStr(M.iliac.left.tortuosity, 3))};
    text(0, 0.5, txt, 'FontName','Menlo', 'FontSize',11, 'VerticalAlignment','middle');
    title('Step 5 measurements (AAA phantom)', 'FontSize',13, 'FontWeight','bold');

    % --- Right: 3D centerlines ---
    ax3d = subplot('Position', [0.71 0.06 0.27 0.86]);
    plot3(Pmm_R(:,2), Pmm_R(:,1), Pmm_R(:,3), '-', 'Color',[0.85 0.10 0.10], 'LineWidth',1.8); hold on;
    plot3(Pmm_L(:,2), Pmm_L(:,1), Pmm_L(:,3), '-', 'Color',[0.10 0.30 0.85], 'LineWidth',1.8);
    plot3(Pmm_R(kR,2), Pmm_R(kR,1), Pmm_R(kR,3), 'p', 'MarkerFaceColor',[0.95 0.10 0.95], 'MarkerEdgeColor','k', 'MarkerSize',14);
    grid on; box on; axis equal;
    xlabel('x (mm)'); ylabel('y (mm)'); zlabel('z (mm)');
    view(135, 25); set(ax3d, 'ZDir','reverse');
    title('3-D centerlines + bifurcation', 'FontSize',13, 'FontWeight','bold');

    sgtitle('EVAR Planner — end-to-end pipeline (AAA phantom, skeleton method)', ...
        'FontSize',16, 'FontWeight','bold');

    out_dir = fullfile(proj, 'results', 'figures');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end
    out = fullfile(out_dir, 'pipeline_aaa_demo.png');
    exportgraphics(fig, out, 'Resolution', 150);
    fprintf('Wrote %s\n', out);
    close(fig);
end

% =========================================================================
function [kR, kL] = bifurc(P_right, P_left, tol)
    nL = size(P_left, 1);
    last_kL = nL; last_kR = NaN;
    for kk = nL:-1:1
        d = vecnorm(P_right - P_left(kk,:), 2, 2);
        [dmin, kR_] = min(d);
        if dmin <= tol
            last_kL = kk; last_kR = kR_;
        else
            break;
        end
    end
    kL = last_kL; kR = last_kR;
end

function s = mmStr(v); if isnan(v); s='—'; else; s=sprintf('%.1f mm', v); end; end
function s = degStr(v); if isnan(v); s='—'; else; s=sprintf('%.1f°', v); end; end
function s = vStr(v, d); if isnan(v); s='—'; else; s=sprintf(['%.', num2str(d), 'f'], v); end; end
