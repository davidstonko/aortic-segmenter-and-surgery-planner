function diag_johndoe2_maskonly()
%DIAG_JOHNDOE2_MASKONLY  Build the JohnDoe2 vessel mask exactly as
%   run_planner_headless does (through the largest-CC step) but STOP
%   before the centerline, so we can inspect WHERE the mask leaks. Dumps
%   the mask after each grow stage + renders raw isosurfaces.

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(proj);
    droot = fullfile(fileparts(proj), 'CTs and Angios', 'JohnDoe2', ...
        'export', 'JohnDoe2', 'series');
    outdir = fullfile(proj, 'results', 'logs', 'johndoe2_diag_adaptive');
    if ~isfolder(outdir); mkdir(outdir); end

    fprintf('=== load CT ===\n');
    D = preprocess.dicom_load(string(droot));

    fprintf('=== TS (cached) ===\n');
    targets = {'aorta','iliac_artery_left','iliac_artery_right','kidney_left','kidney_right','liver'};
    [~, tsinfo] = autoseg.ts_run(D, struct('fast', true, 'targets', {targets}, ...
        'return_label_volume', true));
    seg_uint8 = uint8(tsinfo.label_volume);

    fprintf('=== branch detect (cached) ===\n');
    [m_branch, label_branch, ~] = autoseg.detect_branches_cached(D, seg_uint8); %#ok<ASGLU>
    mask = m_branch;
    stage_report('after TS + branches', mask, D);

    fprintf('=== extend_to_cfa ===\n');
    [mask, label_branch, ~] = autoseg.extend_to_cfa(D, mask, label_branch, struct('verbose', false));
    stage_report('after extend_to_cfa (walker)', mask, D);
    mask_walker = mask;

    fprintf('=== adaptive follower ===\n');
    [mask, fol_info] = autoseg.follow_iliacs_adaptive(D, mask, label_branch, struct('verbose', true));
    stage_report('after adaptive follower', mask, D);
    mask_follower = mask;

    fprintf('=== 3c HU-reconstruct (fixed 150-1400, 5mm shell) ===\n');
    contrast_mask = (D.vol >= 150) & (D.vol <= 1400);
    pix_mm = abs(D.pixel_mm(1));
    shell_r = max(3, round(5 / pix_mm));
    shell = imdilate(mask, strel('sphere', shell_r));
    mask = imreconstruct(mask, contrast_mask & shell, 26);
    stage_report('after 3c HU-reconstruct', mask, D);

    fprintf('=== largest 3D-CC ===\n');
    cc = bwconncomp(mask, 26);
    sz = size(mask);
    if cc.NumObjects > 1
        s = cellfun(@numel, cc.PixelIdxList);
        [~, k] = max(s);
        mlarge = false(sz); mlarge(cc.PixelIdxList{k}) = true;
        mask = mlarge;
    end
    stage_report('FINAL (largest CC)', mask, D);

    % Save the stage masks small (logical) for re-inspection
    save(fullfile(outdir, 'stage_masks.mat'), 'mask_walker', 'mask_follower', ...
        'mask', 'fol_info', 'D', '-v7.3');

    % --- Render: 4-up raw isosurfaces of each stage ---
    render_4up(mask_walker, mask_follower, mask, D, ...
        fullfile(proj, 'results', 'figures', 'diag_johndoe2_stages.png'));
    fprintf('DONE\n');
end

function stage_report(name, m, D)
    sz = size(m);
    cc = bwconncomp(m, 26);
    s = sort(cellfun(@numel, cc.PixelIdxList), 'descend');
    perz = squeeze(sum(sum(m, 1), 2));
    zsl = find(perz > 0);
    pa = perz(zsl);
    pix_mm = abs(D.pixel_mm(1)); ssp = abs(D.slice_spacing_mm);
    vol_ml = nnz(m) * pix_mm * pix_mm * ssp / 1000;
    fprintf('  [%s] nnz=%d (%.0f mL)  CCs=%d top=%s  z=%d..%d  per-slice area med=%d max=%d (>800vox on %d slices)\n', ...
        name, nnz(m), vol_ml, cc.NumObjects, mat2str(s(1:min(4,numel(s)))), ...
        min(zsl), max(zsl), round(median(pa)), max(pa), nnz(pa > 800));
end

function render_4up(mw, mf, mfin, D, outpng)
    ssp = abs(D.slice_spacing_mm); pix = abs(D.pixel_mm(1));
    zr = abs(ssp / pix);
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [40 40 1700 600]);
    tiledlayout(fig, 1, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
    panels = {mw, 'after walker', mf, 'after follower', mfin, 'FINAL largest-CC'};
    for i = 1:3
        ax = nexttile;
        m = panels{2*i-1};
        fv = isosurface(single(m), 0.5);
        patch(ax, fv, 'FaceColor', [0.85 0.3 0.25], 'EdgeColor', 'none');
        daspect(ax, [1 1 zr]); view(ax, -35, 12);
        camlight(ax, 'headlight'); camlight(ax,'right'); lighting(ax, 'gouraud');
        set(ax, 'ZDir', 'reverse'); axis(ax, 'tight'); grid(ax, 'on');
        title(ax, sprintf('%s (%d vox)', panels{2*i}, nnz(m)));
        xlabel(ax,'x'); ylabel(ax,'y'); zlabel(ax,'z');
    end
    exportgraphics(fig, outpng, 'Resolution', 130);
    close(fig);
    fprintf('saved -> %s\n', outpng);
end
