function diag_stage_masks(case_name, droot)
%DIAG_STAGE_MASKS  Build the vessel mask stage-by-stage (TS -> walker ->
%   adaptive follower -> 3c reconstruct -> largest CC) and report volume
%   + per-slice area + 3D-CC count at each stage, plus a 3-up render, so
%   we can see exactly which grow stage leaks. Centerline is skipped.
%
%   diag_stage_masks('JohnDoe2', '/path/to/dicom/dir')

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(proj);
    figdir = fullfile(proj, 'results', 'figures');

    fprintf('=== [%s] load CT ===\n', case_name);
    D = preprocess.dicom_load(string(droot));
    pix = abs(D.pixel_mm(1)); ssp = abs(D.slice_spacing_mm);
    fprintf('  pix=%.3f mm  slice=%.3f mm  size=%s\n', pix, ssp, mat2str(size(D.vol)));

    targets = {'aorta','iliac_artery_left','iliac_artery_right','kidney_left','kidney_right','liver'};
    [~, tsinfo] = autoseg.ts_run(D, struct('fast', true, 'targets', {targets}, ...
        'return_label_volume', true));
    seg_uint8 = uint8(tsinfo.label_volume);
    [m_branch, label_branch, ~] = autoseg.detect_branches_cached(D, seg_uint8); %#ok<ASGLU>
    mask = m_branch;
    stage_report('TS+branches', mask, D);

    [mask, label_branch, ~] = autoseg.extend_to_cfa(D, mask, label_branch, struct('verbose', false));
    stage_report('walker', mask, D);
    mask_walker = mask;

    [mask, ~] = autoseg.follow_iliacs_adaptive(D, mask, label_branch, struct('verbose', false));
    stage_report('follower', mask, D);
    mask_follower = mask;

    contrast_mask = (D.vol >= 150) & (D.vol <= 1400);
    shell_r = max(3, round(5 / pix));
    shell = imdilate(mask, strel('sphere', shell_r));
    cand = autoseg.drop_big_inplane_cc(contrast_mask & shell, round(400 / pix^2));
    mask = imreconstruct(mask, mask | cand, 26);
    stage_report('3c-recon', mask, D);

    cc = bwconncomp(mask, 26); sz = size(mask);
    if cc.NumObjects > 1
        s = cellfun(@numel, cc.PixelIdxList); [~, k] = max(s);
        ml = false(sz); ml(cc.PixelIdxList{k}) = true; mask = ml;
    end
    stage_report('FINAL', mask, D);

    render_3up(mask_walker, mask_follower, mask, D, ...
        fullfile(figdir, sprintf('diag_%s_stages.png', lower(case_name))));
    fprintf('DONE %s\n', case_name);
end

function stage_report(name, m, D)
    cc = bwconncomp(m, 26);
    s = sort(cellfun(@numel, cc.PixelIdxList), 'descend');
    perz = squeeze(sum(sum(m, 1), 2)); zsl = find(perz > 0); pa = perz(zsl);
    pix = abs(D.pixel_mm(1)); ssp = abs(D.slice_spacing_mm);
    vol_ml = nnz(m) * pix * pix * ssp / 1000;
    fprintf('  [%-11s] %7d vox (%4.0f mL)  CCs=%-4d top=%-8d z=%d..%d  area med=%d max=%d\n', ...
        name, nnz(m), vol_ml, cc.NumObjects, s(1), min(zsl), max(zsl), ...
        round(median(pa)), max(pa));
end

function render_3up(mw, mf, mfin, D, outpng)
    zr = abs(D.slice_spacing_mm / D.pixel_mm(1));
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [40 40 1700 600]);
    tiledlayout(fig, 1, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
    P = {mw, 'after walker', mf, 'after follower', mfin, 'FINAL largest-CC'};
    for i = 1:3
        ax = nexttile; m = P{2*i-1};
        fv = isosurface(single(m), 0.5);
        patch(ax, fv, 'FaceColor', [0.85 0.3 0.25], 'EdgeColor', 'none');
        daspect(ax, [1 1 zr]); view(ax, -35, 12);
        camlight(ax, 'headlight'); camlight(ax,'right'); lighting(ax, 'gouraud');
        set(ax, 'ZDir', 'reverse'); axis(ax, 'tight'); grid(ax, 'on');
        title(ax, sprintf('%s (%d vox)', P{2*i}, nnz(m)));
    end
    exportgraphics(fig, outpng, 'Resolution', 130);
    close(fig);
    fprintf('saved -> %s\n', outpng);
end
