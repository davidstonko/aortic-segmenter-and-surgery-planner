function smoke_test_cpr()
%SMOKE_TEST_CPR  Generate a CPR image from the JohnDoe1 CT, save the
%   result so we can eyeball whether the algorithm produces something
%   resembling a straightened aorta.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    % Load JohnDoe1 CT and downsample 2× for an interactive smoke test
    S = load(fullfile(proj, 'results', 'logs', 'ct_volume.mat'));
    D = S.D_ct;
    D.vol = D.vol(1:2:end, 1:2:end, 1:2:end);
    D.pixel_mm = D.pixel_mm * 2;
    D.slice_spacing_mm = D.slice_spacing_mm * 2;
    if isfield(D, 'slice_z_mm'); D.slice_z_mm = D.slice_z_mm(1:2:end); end

    % HU-threshold mask + skeleton centerline (audit pipeline mirror).
    fprintf('Building centerline on JohnDoe1 CT…\n');
    mask = D.vol > 150 & D.vol < 600;
    cc = bwconncomp(mask, 26);
    sizes = cellfun(@numel, cc.PixelIdxList);
    [~, idx] = max(sizes);
    m_largest = false(size(mask));
    m_largest(cc.PixelIdxList{idx}) = true;
    mask = m_largest;

    % Pick reasonable seeds from mask geometry
    sz = size(mask);
    [yy, xx, zz] = ndgrid(1:sz(1), 1:sz(2), 1:sz(3));
    z_top = min(zz(mask)); z_bot = max(zz(mask));
    band_top = mask & zz < z_top + 5;
    band_bot = mask & zz > z_bot - 5;
    seed_prox = [round(median(yy(band_top))), round(median(xx(band_top))), round(median(zz(band_top)))];
    xs_bot = xx(band_bot); ys_bot = yy(band_bot); zs_bot = zz(band_bot);
    x_med = median(xs_bot);
    is_R = xs_bot < x_med;
    seed_R   = [round(median(ys_bot(is_R))), round(median(xs_bot(is_R))), round(median(zs_bot(is_R)))];

    fprintf('  seeds: prox=%s  R-CFA=%s\n', mat2str(seed_prox), mat2str(seed_R));
    fprintf('Running skeleton centerline (right side only for the CPR demo)…\n');
    [Pv, ~] = preprocess.centerline_skeleton(mask, seed_R, seed_prox, ...
        struct('min_branch_length', 30, 'radius_weight_pow', 2, 'smooth_per_segment', 12));

    fprintf('Centerline: %d nodes, generating CPR…\n', size(Pv,1));
    opts = struct( ...
        'pixel_mm',          D.pixel_mm, ...
        'slice_spacing_mm',  D.slice_spacing_mm, ...
        'lateral_mm',        40, ...
        'lateral_step_mm',   0.5, ...
        'arc_step_mm',       0.5, ...
        'ray_dir',           [1 0 0]);   % patient-AP direction
    [cpr, meta] = preprocess.curved_planar_reformat(D.vol, Pv, opts);
    fprintf('CPR image: %s\n', mat2str(size(cpr)));

    out_dir = fullfile(proj, 'results', 'figures');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end
    fig = figure('Visible','off', 'Color','k', 'Position', [100 100 600 1100]);
    ax = axes('Parent', fig, 'Position', [0.05 0.05 0.9 0.9], 'Color','k');
    imagesc(meta.lat_mm, meta.arc_mm, cpr); colormap(gray);
    clim([-200 700]); axis tight;
    set(ax, 'YDir', 'reverse', 'XColor','w', 'YColor','w');
    xlabel(ax, 'lateral (mm)'); ylabel(ax, 'arc length s (mm)');
    title(ax, 'CPR — JohnDoe1 aorta straightened (AP ray)', 'Color','w');
    out = fullfile(out_dir, 'smoke_cpr_johndoe1.png');
    exportgraphics(fig, out, 'Resolution', 150, 'BackgroundColor','k');
    close(fig);
    fprintf('Wrote %s\n', out);
end
