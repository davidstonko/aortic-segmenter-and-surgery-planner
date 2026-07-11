function [D_out, mask_out, info] = auto_crop_to_mask(D, mask, opts)
%PREPROCESS.AUTO_CROP_TO_MASK  Crop a CT volume + mask to the bounding
%   box of the segmented vessels, with a clinically-meaningful margin.
%
%   For EVAR planning the user wants to see the visceral aorta down to
%   the bilateral CFAs — roughly "10 cm above the AAA top to the
%   inguinal ligament". This routine implements that as: bbox of the
%   mask, plus a 100 mm margin on the superior end (to capture the
%   visceral aorta cleanly) and a 30 mm margin on the inferior end (to
%   leave the CFAs visible without hiding the femoral bifurcation).
%
%   [D_OUT, MASK_OUT, INFO] = preprocess.auto_crop_to_mask(D, MASK)
%   [D_OUT, MASK_OUT, INFO] = preprocess.auto_crop_to_mask(D, MASK, OPTS)
%
%   OPTS struct fields (all optional):
%       .margin_lateral_mm    in-plane margin (default 25)
%       .margin_superior_mm   margin above mask top (default 100)
%       .margin_inferior_mm   margin below mask bottom (default 30)
%
%   Outputs
%       D_OUT       new D struct with cropped vol + adjusted spatial
%                   metadata. Same schema as preprocess.dicom_load.
%       MASK_OUT    cropped mask of the same shape as D_OUT.vol.
%       INFO struct
%           .crop_y, .crop_x, .crop_z   1×2 [first last] index ranges in the
%                                       ORIGINAL volume coordinates.
%           .original_size              size of the input vol
%           .reduction_pct              e.g. 0.45 means the cropped
%                                       volume has 45% the voxel count.
%
%   The function preserves D.z_normalized so downstream display flips
%   are consistent.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D     (1,1) struct
        mask  logical
        opts  (1,1) struct = struct()
    end

    if ~isequal(size(D.vol), size(mask))
        error('preprocess:auto_crop_to_mask:SizeMismatch', ...
            'mask and D.vol must be the same size; got %s vs %s.', ...
            mat2str(size(mask)), mat2str(size(D.vol)));
    end
    if ~any(mask(:))
        error('preprocess:auto_crop_to_mask:EmptyMask', ...
            'mask is empty — nothing to crop to.');
    end

    if ~isfield(opts, 'margin_lateral_mm');  opts.margin_lateral_mm  = 25; end
    if ~isfield(opts, 'margin_superior_mm'); opts.margin_superior_mm = 100; end
    if ~isfield(opts, 'margin_inferior_mm'); opts.margin_inferior_mm = 30; end

    sz = size(D.vol);
    [yy, xx, zz] = ndgrid(1:sz(1), 1:sz(2), 1:sz(3));
    y_lo = min(yy(mask)); y_hi = max(yy(mask));
    x_lo = min(xx(mask)); x_hi = max(xx(mask));
    z_lo = min(zz(mask)); z_hi = max(zz(mask));

    % Convert mm margins to voxel margins
    pad_y = round(opts.margin_lateral_mm / D.pixel_mm(1));
    pad_x = round(opts.margin_lateral_mm / D.pixel_mm(2));

    % Z direction: the volume is in head-at-z=1 / feet-at-z=N convention
    % after the doLoad flip (z_normalized=true). So "superior" margin
    % grows the LOW end, "inferior" margin grows the HIGH end.
    z_normalised = isfield(D, 'z_normalized') && D.z_normalized;
    pad_sup_vox = round(opts.margin_superior_mm / D.slice_spacing_mm);
    pad_inf_vox = round(opts.margin_inferior_mm / D.slice_spacing_mm);
    if z_normalised
        z_lo_padded = max(1,     z_lo - pad_sup_vox);
        z_hi_padded = min(sz(3), z_hi + pad_inf_vox);
    else
        z_lo_padded = max(1,     z_lo - pad_inf_vox);
        z_hi_padded = min(sz(3), z_hi + pad_sup_vox);
    end

    y_lo_padded = max(1,     y_lo - pad_y);
    y_hi_padded = min(sz(1), y_hi + pad_y);
    x_lo_padded = max(1,     x_lo - pad_x);
    x_hi_padded = min(sz(2), x_hi + pad_x);

    yr = y_lo_padded:y_hi_padded;
    xr = x_lo_padded:x_hi_padded;
    zr = z_lo_padded:z_hi_padded;

    D_out      = D;
    D_out.vol  = D.vol(yr, xr, zr);
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        D_out.slice_z_mm = D.slice_z_mm(zr);
    end
    if isfield(D, 'rows');     D_out.rows     = numel(yr); end
    if isfield(D, 'cols');     D_out.cols     = numel(xr); end
    if isfield(D, 'n_frames'); D_out.n_frames = numel(zr); end

    mask_out = mask(yr, xr, zr);

    info = struct();
    info.crop_y = [y_lo_padded, y_hi_padded];
    info.crop_x = [x_lo_padded, x_hi_padded];
    info.crop_z = [z_lo_padded, z_hi_padded];
    info.original_size = sz;
    info.reduction_pct = numel(yr) * numel(xr) * numel(zr) / prod(sz);
end
