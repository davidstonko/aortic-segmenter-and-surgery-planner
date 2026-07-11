function out_png = render_segmentation_recon(result_mat_path, out_png_path, view_label)
% RENDER_SEGMENTATION_RECON  Clean headless 3-D recon of the vessel mask.
%
% Loads planner_result.mat (saved as struct `out` with field `mask`,
% plus `seeds` (vox) and `seeds_mm` so we can recover pixel_mm), then
% renders the vessel mask as a viewer3d isosurface centered on its
% voxel-weighted centroid. No CT background, no GUI chrome.
%
% view_label: 'iso' (default), 'anterior', 'lateral', 'posterior'

if nargin < 3 || isempty(view_label); view_label = 'iso'; end

S = load(result_mat_path);
if isfield(S, 'out'); S = S.out; end

mask = logical(S.mask);
assert(any(mask(:)), 'render_segmentation_recon: empty mask');

% Derive pixel_mm from seeds (in voxels) vs seeds_mm.
pix_mm = [1 1 1];
if isfield(S, 'seeds') && isfield(S, 'seeds_mm')
    fns = intersect(fieldnames(S.seeds), fieldnames(S.seeds_mm));
    ratios = nan(numel(fns), 3);
    for k = 1:numel(fns)
        sv = S.seeds.(fns{k})(:);
        sm = S.seeds_mm.(fns{k})(:);
        if numel(sv) >= 3 && numel(sm) >= 3 && all(sv(:) ~= 0)
            % seeds_mm = (R_mm = R * (sv - origin)) — we can't recover
            % the affine, but |sm./sv| approximates pixel size when origin
            % is small. Use median across seeds as a robust estimate.
            ratios(k,:) = abs(sm(1:3) ./ sv(1:3))';
        end
    end
    ratios(any(~isfinite(ratios), 2), :) = [];
    if ~isempty(ratios)
        pm = median(ratios, 1);
        % Sanity: typical CT is 0.3-2 mm
        if all(pm > 0.2) && all(pm < 3)
            pix_mm = pm;
        end
    end
end

[yy, xx, zz] = ind2sub(size(mask), find(mask));
cx_vox = mean(xx); cy_vox = mean(yy); cz_vox = mean(zz);
sx = (max(xx)-min(xx)) * pix_mm(2);
sy = (max(yy)-min(yy)) * pix_mm(1);
sz = (max(zz)-min(zz)) * pix_mm(3);
span_mm = max([sx sy sz]);

f = uifigure('Visible','off','Position',[100 100 1100 1400], ...
             'Color',[0.04 0.04 0.06]);
cleanupFig = onCleanup(@() close(f, 'force'));

% Fill the figure with the viewer
V = viewer3d('Parent', f, ...
             'BackgroundColor',[0.04 0.04 0.06], ...
             'BackgroundGradient',false, ...
             'Lighting','on', ...
             'Box','off', ...
             'OrientationAxes','off');
try
    V.Position = [0 0 1 1];
catch
end

volshow(uint8(mask)*255, 'Parent',V, ...
        'RenderingStyle','Isosurface', ...
        'IsosurfaceValue',0.5, ...
        'Colormap',[0.82 0.12 0.12], ...
        'Alphamap',1, ...
        'Transformation', makehgtform('scale',[pix_mm(2) pix_mm(1) pix_mm(3)]));

target = [cx_vox*pix_mm(2), cy_vox*pix_mm(1), cz_vox*pix_mm(3)];
dist   = span_mm * 1.4;  % tight framing

switch lower(view_label)
    case 'iso'
        dir = [0.55 -0.55 0.35];
    case 'anterior'
        dir = [0 -1 0];
    case 'lateral'
        dir = [1 0 0.05];
    case 'posterior'
        dir = [0 1 0];
    otherwise
        dir = [0.55 -0.55 0.35];
end
dir = dir / norm(dir);

V.CameraPosition = target + dist * dir;
V.CameraTarget   = target;
V.CameraUpVector = [0 0 -1];

drawnow; pause(3); drawnow;
exportapp(f, out_png_path);
out_png = out_png_path;
fprintf('Wrote %s (%d vox, span %.0f mm, pixel_mm=[%.2f %.2f %.2f])\n', ...
        out_png, nnz(mask), span_mm, pix_mm);
end
