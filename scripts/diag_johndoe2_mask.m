function diag_johndoe2_mask()
%DIAG_JOHNDOE2_MASK  Regenerate the JohnDoe2 planner result with the
%   adaptive HU follower and dump mask-quality diagnostics so we can see
%   WHY the 3D recon looks fragmented (sheets) instead of a tube.

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(proj);
    droot = fullfile(fileparts(proj), 'CTs and Angios', 'JohnDoe2', ...
        'export', 'JohnDoe2', 'series');
    assert(isfolder(droot), 'JohnDoe2 DICOM dir not found: %s', droot);

    opts = struct('verbose', true, 'centerline_backend', 'auto', ...
                  'use_adaptive_hu_follower', true, ...
                  'out_dir', fullfile(proj, 'results', 'logs', 'johndoe2_diag_adaptive'));
    fprintf('=== Running headless planner on JohnDoe2 ===\n');
    pr = run_planner_headless(string(droot), opts);

    m = pr.mask;
    sz = size(m);
    fprintf('\n=== MASK DIAGNOSTICS ===\n');
    fprintf('size       : %d x %d x %d\n', sz(1), sz(2), sz(3));
    fprintf('nnz        : %d voxels\n', nnz(m));

    % 3D connectivity
    cc = bwconncomp(m, 26);
    s = sort(cellfun(@numel, cc.PixelIdxList), 'descend');
    fprintf('3D-CCs(26) : %d   top sizes: %s\n', cc.NumObjects, ...
        mat2str(s(1:min(8, numel(s)))));

    % Per-slice voxel-count profile along z (axial slices)
    perz = squeeze(sum(sum(m, 1), 2));
    zsl = find(perz > 0);
    fprintf('z-extent   : slices %d..%d (of %d)\n', min(zsl), max(zsl), sz(3));
    % How many z-slices are EMPTY between min and max (gaps that break a tube)
    span = min(zsl):max(zsl);
    gaps = span(perz(span) == 0);
    fprintf('empty z-slices inside span: %d  (%s%s)\n', numel(gaps), ...
        mat2str(gaps(1:min(20, numel(gaps)))), ...
        ternary(numel(gaps) > 20, ' ...', ''));
    % Distribution of per-slice areas
    pa = perz(zsl);
    fprintf('per-slice area: min=%d  median=%d  mean=%.0f  max=%d\n', ...
        min(pa), median(pa), mean(pa), max(pa));
    % thin slices (likely sheet edges)
    fprintf('slices with area<=3 vox: %d / %d\n', nnz(pa <= 3), numel(pa));

    % In-plane vs axial thickness: for each z, count #connected comps in-plane
    nblob = zeros(numel(zsl), 1);
    for i = 1:numel(zsl)
        cc2 = bwconncomp(m(:, :, zsl(i)), 8);
        nblob(i) = cc2.NumObjects;
    end
    fprintf('in-plane blobs/slice: median=%d  max=%d  (>=2 on %d slices)\n', ...
        median(nblob), max(nblob), nnz(nblob >= 2));

    % How thick is the mask in z at the aorta column? Sample the centroid
    % column over the aorta band and report run-lengths.
    % (Quick proxy: at the in-plane centroid of the densest slice, walk z.)
    [~, zc] = max(perz);
    sl = m(:, :, zc);
    [yy, xx] = find(sl);
    cy = round(mean(yy)); cx = round(mean(xx));
    col = squeeze(m(cy, cx, :));
    fprintf('z-column @ densest centroid (%d,%d): %d/%d voxels ON, longest run=%d\n', ...
        cy, cx, nnz(col), numel(col), longest_run(col));

    % Save for re-render iteration
    outmat = fullfile(proj, 'results', 'logs', 'johndoe2_diag_adaptive', 'planner_result.mat');
    save(outmat, 'pr', '-v7.3');
    fprintf('\nsaved -> %s\n', outmat);

    % Also dump just the raw mask isosurface (NO render conditioning) so
    % we can see the true mask shape vs the beautified one.
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [50 50 1400 700]);
    tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
    ax1 = nexttile;
    fv = isosurface(single(m), 0.5);
    patch(ax1, fv, 'FaceColor', [0.85 0.3 0.25], 'EdgeColor', 'none');
    daspect(ax1, [1 1 abs(pr_zscale(pr))]); view(ax1, -35, 18);
    camlight(ax1, 'headlight'); lighting(ax1, 'gouraud'); set(ax1, 'ZDir', 'reverse');
    title(ax1, sprintf('RAW mask isosurface (nnz=%d, %d CCs)', nnz(m), cc.NumObjects));
    ax2 = nexttile;
    plot(ax2, zsl, perz(zsl), '-o', 'MarkerSize', 3); grid(ax2, 'on');
    xlabel(ax2, 'z slice'); ylabel(ax2, 'voxels in slice');
    title(ax2, 'per-axial-slice voxel area');
    outpng = fullfile(proj, 'results', 'figures', 'diag_johndoe2_rawmask.png');
    exportgraphics(fig, outpng, 'Resolution', 150);
    close(fig);
    fprintf('saved -> %s\n', outpng);
end

function r = longest_run(v)
    v = v(:)'; r = 0; c = 0;
    for k = 1:numel(v)
        if v(k); c = c + 1; r = max(r, c); else; c = 0; end
    end
end

function s = pr_zscale(pr)
    s = 1;
    if isfield(pr, 'seeds') && isfield(pr, 'seeds_mm')
        dz = (pr.seeds_mm.proximal(3)) / max(pr.seeds.proximal(3) - 1, 1);
        dy = (pr.seeds_mm.proximal(1)) / max(pr.seeds.proximal(1) - 1, 1);
        if dy ~= 0; s = abs(dz / dy); end
    end
end

function o = ternary(c, a, b)
    if c; o = a; else; o = b; end
end
