function out_png = render_recon_isosurface(result_mat_path, out_png_path, view_label)
% RENDER_RECON_ISOSURFACE  Off-screen 3-D recon via isosurface + patch.
% Faster + GPU-independent vs viewer3d/volshow. Renders the vessel mask
% as a single isosurface mesh in physical (mm) coords, with dramatic
% Phong lighting against a dark background.

if nargin < 3 || isempty(view_label); view_label = 'iso'; end

S = load(result_mat_path);
if isfield(S, 'out'); S = S.out; end
mask = logical(S.mask);
assert(any(mask(:)), 'render_recon_isosurface: empty mask');

% Derive pixel_mm from seeds (vox vs mm).
pix_mm = [1 1 1];
if isfield(S, 'seeds') && isfield(S, 'seeds_mm')
    fns = intersect(fieldnames(S.seeds), fieldnames(S.seeds_mm));
    ratios = nan(numel(fns), 3);
    for k = 1:numel(fns)
        sv = S.seeds.(fns{k})(:);
        sm = S.seeds_mm.(fns{k})(:);
        if numel(sv) >= 3 && numel(sm) >= 3 && all(sv(1:3) ~= 0)
            ratios(k,:) = abs(sm(1:3) ./ sv(1:3))';
        end
    end
    ratios(any(~isfinite(ratios), 2), :) = [];
    if ~isempty(ratios)
        pm = median(ratios, 1);
        if all(pm > 0.2) && all(pm < 3); pix_mm = pm; end
    end
end

% Downsample to keep mesh manageable: aim for ~0.6mm isotropic.
target_mm = 0.6;
ds = max([1 1 1], round([pix_mm(1) pix_mm(2) pix_mm(3)] ./ target_mm) .* 0);
% pick block factor so resulting voxel size >= target_mm
bf = max(1, round(target_mm ./ pix_mm));
if any(bf > 1)
    mask_ds = mask(1:bf(1):end, 1:bf(2):end, 1:bf(3):end);
    eff_mm  = pix_mm .* bf;
else
    mask_ds = mask;
    eff_mm  = pix_mm;
end
fprintf('Mask %dx%dx%d (%d vox) -> downsampled %dx%dx%d (eff_mm=[%.2f %.2f %.2f])\n', ...
        size(mask,1), size(mask,2), size(mask,3), nnz(mask), ...
        size(mask_ds,1), size(mask_ds,2), size(mask_ds,3), eff_mm);

% Build physical-coord grids (y=row, x=col, z=slice).
[ny, nx, nz] = size(mask_ds);
[Xg, Yg, Zg] = meshgrid((0:nx-1)*eff_mm(2), (0:ny-1)*eff_mm(1), (0:nz-1)*eff_mm(3));

fprintf('Running isosurface...\n'); t0 = tic;
FV = isosurface(Xg, Yg, Zg, single(mask_ds), 0.5);
fprintf('  isosurface: %d faces in %.1fs\n', size(FV.faces,1), toc(t0));

% Set up figure
f = figure('Visible','off', 'Color',[0.04 0.04 0.06], ...
           'Position',[100 100 1100 1400], ...
           'InvertHardcopy','off');
cleanupFig = onCleanup(@() close(f));
ax = axes('Parent',f, 'Color',[0.04 0.04 0.06], ...
          'XColor','none','YColor','none','ZColor','none', ...
          'Position',[0 0 1 1]);
hold(ax,'on');
p = patch(ax, FV, ...
          'FaceColor', [0.82 0.12 0.12], ...
          'EdgeColor','none', ...
          'FaceLighting','gouraud', ...
          'SpecularStrength',0.35, ...
          'AmbientStrength',0.30, ...
          'DiffuseStrength',0.85);
isonormals(Xg, Yg, Zg, single(mask_ds), p);

axis(ax,'equal','off','vis3d');
daspect(ax, [1 1 1]);

% Camera — voxel-weighted centroid in mm, distance scaled to bbox.
[yy, xx, zz] = ind2sub(size(mask_ds), find(mask_ds));
cx = mean(xx)*eff_mm(2); cy = mean(yy)*eff_mm(1); cz = mean(zz)*eff_mm(3);
sx = range(xx)*eff_mm(2); sy = range(yy)*eff_mm(1); sz = range(zz)*eff_mm(3);
span_mm = max([sx sy sz]);
target = [cx cy cz];
dist = span_mm * 1.25;

switch lower(view_label)
    case 'iso';       dir = [ 0.55 -0.55  0.35];
    case 'anterior';  dir = [ 0    -1     0   ];
    case 'lateral';   dir = [ 1     0     0.05];
    case 'posterior'; dir = [ 0     1     0   ];
    otherwise;        dir = [ 0.55 -0.55  0.35];
end
dir = dir / norm(dir);

set(ax, 'CameraPosition', target + dist*dir, ...
        'CameraTarget',   target, ...
        'CameraUpVector', [0 0 -1], ...
        'CameraViewAngle', 12);
% Two lights for some shape modeling
camlight(ax, 'headlight');
l2 = light(ax); l2.Position = target + dist*([0 1 -0.5]);
l2.Color = [0.55 0.55 0.65];

drawnow;
exportgraphics(f, out_png_path, 'Resolution', 150, ...
               'BackgroundColor',[0.04 0.04 0.06]);
out_png = out_png_path;
fprintf('Wrote %s\n', out_png);
end
