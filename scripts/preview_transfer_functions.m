function preview_transfer_functions()
%PREVIEW_TRANSFER_FUNCTIONS  Render the 4 CTA transfer functions side
%   by side as a sanity check, plus the LUTs themselves as ramps. Used
%   to verify the colormaps before exercising the GUI.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    P  = phantom.load_from_library('PHANTOM_aaa_male_raw');
    V  = double(P.vol);

    styles = {'cta_recon','vessel','bone','mip'};
    titles = {'CTA Recon (vessels + bone)', ...
              'Vessels only (bone suppressed)', ...
              'Bone only', ...
              'MIP (grayscale)'};

    fig = figure('Visible','off', 'Color','k', 'Position',[100 100 1600 900]);
    for k = 1:4
        [cmap, amap] = preprocess.cta_transfer_function(styles{k});

        % Apply the TF to a simple coronal MIP — emulates what volshow
        % would produce in essence (alpha-weighted accumulated colour).
        % This is for preview only; the real volshow does GPU ray-marching.
        hu_lo = -1000; hu_hi = 2000;
        Vn = single((V - hu_lo) / (hu_hi - hu_lo));
        Vn = max(0, min(1, Vn));
        sz = size(Vn);
        if strcmp(styles{k}, 'mip')
            % MIP — pick the brightest voxel along axis 1 and look up
            mip_idx = squeeze(max(Vn, [], 1)).';
            Lidx = round(mip_idx * 255) + 1;
            Lidx = max(1, min(256, Lidx));
            R = reshape(cmap(Lidx, 1), size(mip_idx));
            G = reshape(cmap(Lidx, 2), size(mip_idx));
            B = reshape(cmap(Lidx, 3), size(mip_idx));
            rgb = cat(3, R, G, B);
        else
            % Front-to-back compositing along axis 1 (coronal direction)
            R = zeros(sz(3), sz(2)); G = R; B = R; A = R;
            for y = 1:sz(1)
                slc = squeeze(Vn(y, :, :)).';
                Lidx = round(slc * 255) + 1;
                Lidx = max(1, min(256, Lidx));
                cR = reshape(cmap(Lidx, 1), size(slc));
                cG = reshape(cmap(Lidx, 2), size(slc));
                cB = reshape(cmap(Lidx, 3), size(slc));
                aV = reshape(amap(Lidx),    size(slc));
                R = R + (1 - A) .* aV .* cR;
                G = G + (1 - A) .* aV .* cG;
                B = B + (1 - A) .* aV .* cB;
                A = A + (1 - A) .* aV;
                if all(A(:) > 0.999); break; end
            end
            rgb = cat(3, R, G, B);
        end
        rgb = max(0, min(1, rgb));

        ax = subplot(2, 2, k);
        imshow(rgb, 'Parent', ax);
        title(titles{k}, 'Color','w', 'FontSize',13, 'FontWeight','bold');
        ax.Color = 'k';
    end
    sgtitle('AAA phantom — 3D Style preview (synthetic ray-cast preview, real volshow rendering will be smoother)', ...
        'Color','w', 'FontSize',14, 'FontWeight','bold');

    out_dir = fullfile(proj, 'results', 'figures');
    if ~exist(out_dir, 'dir'); mkdir(out_dir); end
    out = fullfile(out_dir, 'transfer_function_preview.png');
    exportgraphics(fig, out, 'Resolution', 150, 'BackgroundColor','k');
    fprintf('Wrote %s\n', out);
    close(fig);
end
