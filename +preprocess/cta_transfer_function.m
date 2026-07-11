function [cmap, amap] = cta_transfer_function(style, hu_lo, hu_hi, n)
%PREPROCESS.CTA_TRANSFER_FUNCTION  Build colour + opacity LUTs for
%   volshow that give CTA volumes a TeraRecon-style look — contrast
%   vessels saturated red/orange, bone white-yellow, soft tissue
%   suppressed.
%
%   [CMAP, AMAP] = preprocess.cta_transfer_function(STYLE, HU_LO, HU_HI, N)
%
%   STYLE   one of:
%       'cta_recon'   default — vessels + bone, TeraRecon-like.
%       'vessel'      narrow contrast window, bone faded out.
%       'bone'        bone only; soft tissue + vessels suppressed.
%       'mip'         flat grayscale ramp for plain MIP rendering.
%
%   HU_LO,HU_HI   the HU range the volume was normalised to before
%                 being passed to volshow ([-1000, 2000] is sensible).
%   N             number of LUT entries (default 256).
%
%   Outputs are aligned with the volshow .Colormap / .Alphamap
%   contract: CMAP is N×3 in [0,1], AMAP is N×1 in [0,1], both indexed
%   linearly across the normalised data range.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        style (1,:) char  = 'cta_recon'
        hu_lo (1,1) double = -1000
        hu_hi (1,1) double =  2000
        n     (1,1) double = 256
    end

    % Piecewise-linear control points: each row is [HU, R, G, B, alpha].
    switch lower(style)
        case 'cta_recon'
            cp = [
                -1000   0.00 0.00 0.00   0.00;     % air — invisible
                 -200   0.00 0.00 0.00   0.00;     % lung — invisible
                    0   0.20 0.10 0.06   0.00;     % soft tissue — invisible
                   80   0.45 0.20 0.12   0.00;     % muscle — invisible
                  120   0.80 0.20 0.12   0.10;     % contrast onset
                  200   0.95 0.30 0.18   0.45;     % contrast — red
                  400   1.00 0.55 0.22   0.85;     % bright contrast — orange
                  600   1.00 0.85 0.55   0.92;     % spongy bone / dense contrast
                 1000   1.00 1.00 0.90   1.00;     % cortical bone — white-yellow
                 2000   1.00 1.00 1.00   1.00];    % saturate
        case 'vessel'
            % Aggressive bone suppression: alpha → 0 above HU 500 so
            % cortical bone (HU 700+) is invisible and only contrast-
            % enhanced lumen (HU 150–450) is rendered. Useful as the
            % default "vessels only" pre-segmentation view — what
            % TeraRecon shows when you first open a CTA.
            cp = [
                -1000   0.00 0.00 0.00   0.00;
                  100   0.00 0.00 0.00   0.00;
                  150   0.85 0.20 0.10   0.25;     % vessel onset
                  300   1.00 0.40 0.15   0.90;     % vessel peak
                  450   1.00 0.55 0.25   0.55;     % begin sharp decay
                  500   0.80 0.40 0.20   0.10;     % bone edge — almost gone
                  600   0.30 0.15 0.05   0.00;     % bone — invisible
                 2000   0.30 0.15 0.05   0.00];
        case 'bone'
            cp = [
                -1000   0.00 0.00 0.00   0.00;
                  299   0.00 0.00 0.00   0.00;
                  300   0.92 0.85 0.75   0.20;     % spongy bone
                  600   1.00 0.95 0.85   0.85;
                 1000   1.00 1.00 1.00   1.00;     % cortical bone
                 2000   1.00 1.00 1.00   1.00];
        case 'mip'
            cp = [
                -1000   0.00 0.00 0.00   0.00;
                 -300   0.00 0.00 0.00   0.00;     % suppress air
                    0   0.25 0.25 0.25   0.20;
                  500   0.85 0.85 0.85   0.85;
                 1500   1.00 1.00 1.00   1.00;
                 2000   1.00 1.00 1.00   1.00];
        otherwise
            error('app:cta_transfer_function:UnknownStyle', ...
                'Unknown style "%s". Use cta_recon | vessel | bone | mip.', style);
    end

    % Resample the control points to the LUT — linear interpolation
    % across the volume's normalised [0,1] index space.
    idx_norm = (cp(:,1) - hu_lo) / (hu_hi - hu_lo);
    idx_norm = max(0, min(1, idx_norm));
    % Drop duplicates that can appear at the edges
    [idx_norm, iu] = unique(idx_norm, 'stable');
    cp = cp(iu, :);

    grid = linspace(0, 1, n)';
    cmap = [interp1(idx_norm, cp(:,2), grid, 'linear', cp(end,2)), ...
            interp1(idx_norm, cp(:,3), grid, 'linear', cp(end,3)), ...
            interp1(idx_norm, cp(:,4), grid, 'linear', cp(end,4))];
    amap =  interp1(idx_norm, cp(:,5), grid, 'linear', cp(end,5));
    cmap = max(0, min(1, cmap));
    amap = max(0, min(1, amap));
end
