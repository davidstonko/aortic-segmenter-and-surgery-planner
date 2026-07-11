function out_path = render_demo_figure(planner_result, case_name, out_path, opts)
%RENDER_DEMO_FIGURE  Single-image showpiece: 3D recon of the segmented
%   aorta + iliacs paired with the bifurcated centerline.
%
%   render_demo_figure(PR, CASE_NAME)
%   render_demo_figure(PR, CASE_NAME, OUT_PATH)
%   render_demo_figure(PR, CASE_NAME, OUT_PATH, OPTS)
%
%   PR is the struct emitted by run_planner_headless. Two-panel
%   figure, both panels use the SAME patient-mm camera:
%     left  panel — marching-cubes 3D recon of the segmentation mask,
%                   shaded
%     right panel — bifurcated centerline (red = right, blue = left)
%                   with proximal + CFA seed markers
%
%   Coordinate frame (mm) is the pipeline's own voxel_to_mm transform,
%   recovered EXACTLY from the seed <-> seed_mm correspondences saved in
%   PR (residual ~1e-13 mm):
%       X_mm = col   * dx        (lateral)
%       Y_mm = row   * dy        (antero-posterior)
%       Z_mm = za*slice + zb     (cranio-caudal; large DICOM origin)
%   Rendering the mask in this exact frame is what keeps the 3D recon
%   co-registered with the centerline. The previous implementation
%   assumed mm=(vox-1)*spacing with a zero origin, which for DICOMs with
%   a large z-origin (e.g. JohnDoe2, z ~ -1500 mm) placed the mask far
%   outside the centerline's axis limits -- so it got clipped into
%   disconnected "slabs" that did not look like a segmented aorta.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        planner_result (1,1) struct
        case_name      (1,:) char
        out_path       (1,:) char = ''
        opts           (1,1) struct = struct()
    end
    if ~isfield(opts, 'figure_size'); opts.figure_size = [1800 900]; end
    if ~isfield(opts, 'view_az');     opts.view_az = -35;  end   % oblique from patient-right
    if ~isfield(opts, 'view_el');     opts.view_el = 18;   end
    if isempty(out_path)
        proj = fileparts(fileparts(mfilename('fullpath')));
        out_path = fullfile(proj, 'results', 'figures', ...
            sprintf('demo_%s.png', case_name));
    end
    [outdir, ~, ~] = fileparts(out_path);
    if ~isempty(outdir) && ~exist(outdir, 'dir'); mkdir(outdir); end

    pr = planner_result;

    % --- Resolve seed mm coords + arcs ----
    % The polyline endpoints are the de-facto seed positions in the
    % centerline coordinate frame. Orientation differs between backends:
    %   VMTK: distal->proximal (Pv(1)=CFA, Pv(end)=source)
    %   MATLAB skeleton-graph: proximal->distal (Pv(1)=source, Pv(end)=CFA)
    % Detect via the radius profile: proximal aorta is FATTER than the
    % CFA, so the larger-R end is the proximal source.
    [p_prox, p_R] = pick_endpoints(pr.Pv_mm_right, pr.R_mm_right);
    [~,      p_L] = pick_endpoints(pr.Pv_mm_left,  pr.R_mm_left);
    arc_R = pr.arc_R_mm; if isnan(arc_R); arc_R = sum(vecnorm(diff(pr.Pv_mm_right),2,2)); end
    arc_L = pr.arc_L_mm; if isnan(arc_L); arc_L = sum(vecnorm(diff(pr.Pv_mm_left), 2,2)); end

    % --- Mask isosurface in the pipeline's exact mm frame ----
    fv = build_isosurface(pr.mask, pr);

    % Camera/limit bounds = union of mask verts + centerline + seeds, so
    % the mask is never clipped.
    bnd = [pr.Pv_mm_right; pr.Pv_mm_left];
    if ~isempty(fv.vertices); bnd = [bnd; fv.vertices]; end

    fig = figure('Visible', 'off', 'Color', 'w', ...
        'Position', [50 50 opts.figure_size(1) opts.figure_size(2)]);
    tl = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    title(tl, sprintf('%s — bifurcated EVAR centerline (R %.0f mm / L %.0f mm)', ...
        strrep(case_name,'_','\_'), arc_R, arc_L), ...
        'FontWeight', 'bold', 'FontSize', 16);

    % --- Tile 1: 3D segmentation recon ----
    ax1 = nexttile(tl, 1);
    patch(ax1, fv, 'FaceColor', [0.85 0.30 0.25], ...
        'EdgeColor', 'none', 'FaceAlpha', 1.0, ...
        'AmbientStrength', 0.3, 'DiffuseStrength', 0.7, ...
        'SpecularStrength', 0.4, 'SpecularExponent', 30);
    setup_3d_axes(ax1, pr, opts, bnd);
    title(ax1, 'Segmentation 3D reconstruction', 'FontSize', 13);

    % --- Tile 2: bifurcated centerline (same camera) ----
    ax2 = nexttile(tl, 2);
    hold(ax2, 'on');
    % Both polylines share the proximal trunk, so draw the longer one
    % first then the shorter one with a small lateral (X) offset so both
    % are visible through the shared segment.
    nR = size(pr.Pv_mm_right, 1);
    nL = size(pr.Pv_mm_left,  1);
    if nL >= nR
        long_pv = pr.Pv_mm_left;  long_clr = [0.20 0.40 0.85];
        short_pv = pr.Pv_mm_right; short_clr = [0.85 0.20 0.20];
    else
        long_pv = pr.Pv_mm_right; long_clr = [0.85 0.20 0.20];
        short_pv = pr.Pv_mm_left;  short_clr = [0.20 0.40 0.85];
    end
    plot3(ax2, long_pv(:,1),  long_pv(:,2),  long_pv(:,3), ...
        '-', 'Color', long_clr, 'LineWidth', 3.5);
    offset_mm = 2.5;
    if isequal(short_clr, [0.85 0.20 0.20]); ox = -offset_mm; else; ox = offset_mm; end
    plot3(ax2, short_pv(:,1) + ox, short_pv(:,2), short_pv(:,3), ...
        '-', 'Color', short_clr, 'LineWidth', 2.5);
    if ~isempty(p_prox)
        plot3(ax2, p_prox(1), p_prox(2), p_prox(3), ...
            'o', 'MarkerFaceColor', [0.15 0.65 0.20], 'MarkerEdgeColor', 'k', ...
            'MarkerSize', 12, 'LineWidth', 1.2);
        plot3(ax2, p_R(1), p_R(2), p_R(3), ...
            'o', 'MarkerFaceColor', [0.85 0.20 0.20], 'MarkerEdgeColor', 'k', ...
            'MarkerSize', 12, 'LineWidth', 1.2);
        plot3(ax2, p_L(1), p_L(2), p_L(3), ...
            'o', 'MarkerFaceColor', [0.20 0.40 0.85], 'MarkerEdgeColor', 'k', ...
            'MarkerSize', 12, 'LineWidth', 1.2);
    end
    setup_3d_axes(ax2, pr, opts, bnd);
    title(ax2, 'Bifurcated centerline (red = R, blue = L)', 'FontSize', 13);
    legend(ax2, {'R polyline', 'L polyline', 'proximal seed', 'R-CFA seed', 'L-CFA seed'}, ...
        'Location', 'northeast', 'FontSize', 10, 'AutoUpdate', 'off');

    exportgraphics(fig, out_path, 'Resolution', 200);
    fprintf('[render_demo_figure] %s -> %s\n', case_name, out_path);
    close(fig);
end

% ====================================================================
function [p_prox, p_distal] = pick_endpoints(Pv, R)
% Return (proximal-source, distal-CFA) endpoints. The proximal aorta is
% FATTER than the CFA, so the larger-R end is the proximal source.
    if numel(R) < 2 || all(R == R(1))
        p_prox = Pv(1, :); p_distal = Pv(end, :); return;
    end
    k = min(15, max(2, floor(numel(R) / 10)));
    if mean(R(1:k)) >= mean(R(end-k+1:end))
        p_prox = Pv(1, :); p_distal = Pv(end, :);
    else
        p_prox = Pv(end, :); p_distal = Pv(1, :);
    end
end

% ====================================================================
function [dx, dy, za, zb] = recover_xform(pr)
% Recover the pipeline's exact voxel_to_mm transform from the three
% seed <-> seed_mm correspondences saved in the planner_result. Matches
% run_planner_headless/voxel_to_mm:
%     mm(1) X = vox(2) col   * pixel_mm(2)
%     mm(2) Y = vox(1) row   * pixel_mm(1)
%     mm(3) Z = slice_z_mm(vox(3))   (~linear in slice)
    sv = [pr.seeds.proximal(:).'; pr.seeds.right_cfa(:).'; pr.seeds.left_cfa(:).'];
    sm = [pr.seeds_mm.proximal(:).'; pr.seeds_mm.right_cfa(:).'; pr.seeds_mm.left_cfa(:).'];
    dx = median(sm(:,1) ./ sv(:,2));
    dy = median(sm(:,2) ./ sv(:,1));
    if numel(unique(sv(:,3))) >= 2
        p = polyfit(sv(:,3), sm(:,3), 1); za = p(1); zb = p(2);
    else
        za = 1; zb = 0;
    end
    if ~isfinite(dx) || dx == 0; dx = 1; end
    if ~isfinite(dy) || dy == 0; dy = 1; end
end

% ====================================================================
function setup_3d_axes(ax, pr, opts, bnd)
% Common axis configuration so both panels share the same 3D camera.
% Limits come from BND (mask verts + centerline + seeds) so the mask is
% never clipped. ZDir is data-driven so the proximal aorta is on top.
    daspect(ax, [1 1 1]);
    grid(ax, 'on'); box(ax, 'off');
    % Proximal aorta should read at the top of the figure. If the
    % proximal seed has a LARGER z_mm than the CFAs, cranial = +Z, so
    % ZDir normal puts it up; otherwise reverse.
    z_prox = pr.seeds_mm.proximal(3);
    z_cfa  = 0.5 * (pr.seeds_mm.right_cfa(3) + pr.seeds_mm.left_cfa(3));
    if z_prox >= z_cfa; set(ax, 'ZDir', 'normal'); else; set(ax, 'ZDir', 'reverse'); end
    view(ax, opts.view_az, opts.view_el);
    camlight(ax, 'headlight'); camlight(ax, 'right');
    lighting(ax, 'gouraud');
    pad = 8;
    xlim(ax, [min(bnd(:,1))-pad, max(bnd(:,1))+pad]);
    ylim(ax, [min(bnd(:,2))-pad, max(bnd(:,2))+pad]);
    zlim(ax, [min(bnd(:,3))-pad, max(bnd(:,3))+pad]);
    xlabel(ax, 'X (mm, lat)');
    ylabel(ax, 'Y (mm, AP)');
    zlabel(ax, 'Z (mm, cran-caud)');
end

% ====================================================================
function fv = build_isosurface(mask, pr)
% Build an mm-coord isosurface from the binary mask using the pipeline's
% exact transform. Display-only conditioning: dilate 1 vox + morph-close
% to give thin lumen walls visible thickness and bridge 1-vox slice
% gaps, then a mild anisotropic Gaussian so the 0.5 isosurface is a
% continuous tube rather than per-slice slabs.
    sz = size(mask);
    [dx, dy, za, zb] = recover_xform(pr);

    m_bin = imdilate(mask, strel('sphere', 1));
    m_bin = imclose(m_bin, strel('cube', 3));
    m = imgaussfilt3(single(m_bin), [1.2 1.2 2.5]);

    ds = 1;
    if numel(m) > 5e8
        ds = ceil((numel(m) / 5e8) ^ (1/3));
        sz_d = ceil(sz ./ ds);
        m2 = false(sz_d);
        for ay = 1:ds; for axx = 1:ds; for az = 1:ds
            yi = ay:ds:sz(1); xi = axx:ds:sz(2); zi = az:ds:sz(3);
            m2(1:numel(yi), 1:numel(xi), 1:numel(zi)) = ...
                m2(1:numel(yi), 1:numel(xi), 1:numel(zi)) | (m(yi, xi, zi) > 0.5);
        end; end; end
        m = single(m2);
    end

    % mm grids. Voxel index i maps to mm = i*spacing (no -1, matching
    % voxel_to_mm). After downsampling by ds, downsampled index j covers
    % original index (j-1)*ds+1.
    nrow = size(m,1); ncol = size(m,2); nslc = size(m,3);
    orig_col = ((0:ncol-1) * ds) + 1;
    orig_row = ((0:nrow-1) * ds) + 1;
    orig_slc = ((0:nslc-1) * ds) + 1;
    Xc = orig_col * dx;            % X varies along columns (dim 2)
    Yc = orig_row * dy;            % Y varies along rows    (dim 1)
    Zc = za * orig_slc + zb;       % Z varies along slices  (dim 3)
    [Xmm, Ymm, Zmm] = meshgrid(Xc, Yc, Zc);
    fv = isosurface(Xmm, Ymm, Zmm, single(m), 0.5);
    if ~isempty(fv.vertices)
        fv = drop_small_components(fv);
    end
end

% ====================================================================
function fv = drop_small_components(fv)
% Drop only tiny isolated specks (<1% of the largest surface component).
    V = fv.vertices; F = fv.faces; nV = size(V, 1);
    if nV < 100; return; end
    E = [F(:, [1 2]); F(:, [2 3]); F(:, [3 1])];
    A = sparse([E(:,1); E(:,2)], [E(:,2); E(:,1)], 1, nV, nV);
    bins = conncomp(graph(A));
    if max(bins) < 2; return; end
    sizes = accumarray(bins(:), 1);
    [sorted, ord] = sort(sizes, 'descend');
    cutoff = 0.01 * sorted(1);
    keep_bin = ord(sorted >= cutoff);
    keep_vert = ismember(bins(:), keep_bin);
    keep_face = all(keep_vert(F), 2);
    F = F(keep_face, :);
    [used, ~, ic] = unique(F(:));
    V = V(used, :);
    F = reshape(ic, size(F));
    fv.vertices = V; fv.faces = F;
end
