function vol = synth_ct_from_mask(mask, opts)
%PHANTOM.SYNTH_CT_FROM_MASK  Generate a synthetic CT volume from a
%   vessel mask, with body soft tissue around it.
%
%   VOL = phantom.synth_ct_from_mask(MASK)
%   VOL = phantom.synth_ct_from_mask(MASK, opts)
%
%   The synthetic CT layers HU values to look plausibly like a CTA
%   when displayed in the GUI:
%       Inside MASK         350 HU   (contrast-enhanced lumen)
%       Inside body ellipse -100 HU  (soft tissue / fat)
%       Outside body        -1000 HU (air)
%   With a small Gaussian noise (~10 HU) on the soft-tissue band so
%   slice MIPs and windowed slice views look natural rather than flat.
%
%   opts:
%       .lumen_HU         default 350
%       .tissue_HU        default -100
%       .air_HU           default -1000
%       .noise_sigma      default 10  (Gaussian sigma in HU on tissue)
%       .body_margin      voxels of body around the mask bounding box
%                         (default 25). Set to 0 for tight body.
%       .body_axes        [a b] semi-axes of an axial elliptical body
%                         outline as fractions of (Y, X) extent
%                         (default [0.42, 0.45] — roughly torso-shaped)
%
%   The body outline is an axial ellipse extruded through Z, sized to
%   surround the vessel mask. Anatomically simplified (no organs); the
%   point is to have a plausible HU background for the GUI's slice
%   views and MIP, not to be a tissue-accurate phantom.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask logical
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'lumen_HU');     opts.lumen_HU    = 350;    end
    if ~isfield(opts, 'tissue_HU');    opts.tissue_HU   = -100;   end
    if ~isfield(opts, 'air_HU');       opts.air_HU      = -1000;  end
    if ~isfield(opts, 'noise_sigma');  opts.noise_sigma = 10;     end
    if ~isfield(opts, 'body_margin');  opts.body_margin = 25;     end
    if ~isfield(opts, 'body_axes');    opts.body_axes   = [0.42 0.45]; end

    sz = size(mask);
    vol = single(zeros(sz)) + opts.air_HU;

    % --- Body ellipse around the vessel bounding box ----------------
    [yi, xi, ~] = ind2sub(sz, find(mask));
    if ~isempty(yi)
        cy = mean(yi); cx = mean(xi);
    else
        cy = sz(1)/2; cx = sz(2)/2;
    end
    a = opts.body_axes(1) * sz(1);
    b = opts.body_axes(2) * sz(2);
    [Yg, Xg] = ndgrid(1:sz(1), 1:sz(2));
    body_axial = ((Yg - cy)/a).^2 + ((Xg - cx)/b).^2 <= 1;
    body_axial = body_axial | imdilate(squeeze(any(mask, 3)), ...
                                       strel('disk', opts.body_margin));
    body_3d = repmat(body_axial, [1 1 sz(3)]);

    % --- Soft tissue band -------------------------------------------
    tissue = body_3d & ~mask;
    noise  = single(opts.noise_sigma) * randn(sz, 'single');
    vol(tissue) = opts.tissue_HU + noise(tissue);

    % --- Lumen --------------------------------------------------
    vol(mask) = opts.lumen_HU + 0.3 * single(opts.noise_sigma) * randn(sum(mask(:)), 1, 'single');
end
