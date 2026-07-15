function seeds = auto_seeds_anatomic(label_vol, D, opts, branch_labels)
%PREPROCESS.AUTO_SEEDS_ANATOMIC  Auto-detect EVAR endpoint seeds using
%   TotalSegmentator label volume + anatomic context.
%
%   SEEDS = preprocess.auto_seeds_anatomic(LABEL_VOL, D)
%   SEEDS = preprocess.auto_seeds_anatomic(LABEL_VOL, D, OPTS)
%
%   LABEL_VOL is a 3-D integer volume (Y×X×Z, head at z=1 in our
%   convention) whose voxel values are TotalSegmentator class IDs
%   from the `total` task (see autoseg.class_name_to_id).
%
%   Three endpoints are returned, in voxel coordinates [y x z]:
%       seeds.proximal   suprarenal aorta, ~5 cm above the celiac
%                        artery level (computed from anatomic landmarks)
%       seeds.right_cfa  patient-right common femoral terminus (most
%                        caudal slice of iliac_artery_right)
%       seeds.left_cfa   patient-left CFA terminus
%       seeds.ok         logical, true if all three were located
%       seeds.diagnostic struct with intermediate landmark z's,
%                        useful for QC and debugging
%
%   Proximal endpoint logic — prefer the ACTUAL celiac centroid from
%   `+autoseg/extend_and_detect_branches` (label 8) when available.
%   That gives the true celiac z-position rather than estimating from
%   surrounding anatomy.
%
%   Anchor priority (highest to lowest):
%     1. branch_labels label 8 (celiac) — use the most-cranial celiac
%        voxel z, then go 50 mm proximal.
%     2. branch_labels label 9 (SMA) — SMA origin is ~20 mm below the
%        celiac, so 5 cm above celiac = SMA_top - 70 mm.
%     3. kidney_top - 70 mm (FALLBACK, indicates the segmentation is
%        incomplete because we couldn't find the celiac).
%   In all cases, clip to the aorta's actual z range.
%
%   Options (struct):
%       .proximal_offset_mm   default 70   — distance cranial to the
%                                            kidney upper pole.
%       .liver_offset_mm      default 10   — distance cranial to the
%                                            liver dome (fallback).
%       .min_aorta_margin     default 10   — slices below aorta_top
%                                            (so we don't sit on the
%                                            very first labeled slice).
%       .iliac_terminus       default 'bottom_slice' — how to pick
%                                            the CFA endpoints.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        label_vol               {mustBeNumeric, mustBeReal}
        D            (1,1) struct
        opts         (1,1) struct = struct()
        branch_labels = []
    end
    if ~isfield(opts, 'proximal_offset_mm'); opts.proximal_offset_mm = 70;  end
    if ~isfield(opts, 'liver_offset_mm');    opts.liver_offset_mm    = 10;  end
    if ~isfield(opts, 'min_aorta_margin');   opts.min_aorta_margin   = 10;  end
    if ~isfield(opts, 'celiac_to_seed_mm');  opts.celiac_to_seed_mm  = 50;  end

    seeds = struct('proximal', [], 'right_cfa', [], 'left_cfa', [], ...
                   'ok', false, 'diagnostic', struct());

    n2id = autoseg.class_name_to_id();
    cid_aorta = n2id('aorta');
    cid_il_l  = n2id('iliac_artery_left');
    cid_il_r  = n2id('iliac_artery_right');
    cid_kl    = n2id('kidney_left');
    cid_kr    = n2id('kidney_right');
    cid_liver = n2id('liver');

    M_aorta = (label_vol == cid_aorta);
    if ~any(M_aorta(:)) && ~isempty(branch_labels)
        % Pipeline-scheme caller (learned / external segmentation backend):
        % label_vol carries pipeline ids, not TS class ids, so the aorta is
        % label 1. TS callers still match cid_aorta above and never reach
        % this fallback.
        M_aorta = (branch_labels == 1);
    end
    if ~any(M_aorta(:)); return; end

    slice_spacing = abs(D.slice_spacing_mm);
    if slice_spacing < 1e-3; slice_spacing = 1; end

    % --- Find proximal seed -----
    aorta_top_z = first_z_with(M_aorta);
    aorta_bot_z = last_z_with(M_aorta);

    M_kl = (label_vol == cid_kl);
    M_kr = (label_vol == cid_kr);
    M_kidney = M_kl | M_kr;
    M_liver  = (label_vol == cid_liver);

    % --- Anchor priority: real celiac > SMA - 20 mm > kidney - 70 mm > liver
    z_target = NaN; anchor = '';
    if ~isempty(branch_labels) && any(branch_labels(:) == 8)
        % Celiac (label 8) is the GOLD STANDARD anchor — the actual
        % vessel origin. Use the most-cranial celiac voxel.
        M_celiac = (branch_labels == 8);
        celiac_top_z = first_z_with(M_celiac);
        z_target = celiac_top_z - round(opts.celiac_to_seed_mm / slice_spacing);
        anchor = 'celiac';
    elseif ~isempty(branch_labels) && any(branch_labels(:) == 9)
        M_sma = (branch_labels == 9);
        sma_top_z = first_z_with(M_sma);
        % SMA arises ~20 mm caudal to celiac, so 5 cm above celiac =
        % SMA_top - 70 mm.
        z_target = sma_top_z - round((opts.celiac_to_seed_mm + 20) / slice_spacing);
        anchor = 'SMA - 20mm';
    elseif any(M_kidney(:))
        kid_top_z = first_z_with(M_kidney);
        z_target = kid_top_z - round(opts.proximal_offset_mm / slice_spacing);
        anchor   = 'kidney (fallback)';
    elseif any(M_liver(:))
        liver_top_z = first_z_with(M_liver);
        z_target = liver_top_z - round(opts.liver_offset_mm / slice_spacing);
        anchor   = 'liver (fallback)';
    else
        z_target = aorta_top_z + opts.min_aorta_margin;
        anchor   = 'aorta_top (last resort)';
    end

    z_prox = max(z_target, aorta_top_z + opts.min_aorta_margin);
    z_prox = min(z_prox, aorta_bot_z - 1);
    aorta_slice = M_aorta(:, :, z_prox);
    if any(aorta_slice(:))
        % Largest CC on that slice — guard against stray paraspinal voxels
        cc = bwconncomp(aorta_slice, 8);
        szs = cellfun(@numel, cc.PixelIdxList);
        [~, idx] = max(szs);
        [yy, xx] = ind2sub(size(aorta_slice), cc.PixelIdxList{idx});
        seeds.proximal = [round(mean(yy)), round(mean(xx)), z_prox];
    end

    % --- Find CFA seeds -----
    % Prefer the post-extension branch labels (4 = patient-LEFT CFA,
    % 5 = patient-RIGHT CFA, applied anatomically by extend_to_cfa) over
    % the raw TS iliac labels, which stop at the iliac/EIA boundary —
    % well above the actual common femoral artery. Falling back to the
    % TS labels lets this function still produce seeds when the CFA
    % extension hasn't been run yet.
    if ~isempty(branch_labels) && any(branch_labels(:) == 5)
        seeds.right_cfa = cfa_endpoint(branch_labels, 5);
    else
        seeds.right_cfa = cfa_endpoint(label_vol, cid_il_r);
    end
    if ~isempty(branch_labels) && any(branch_labels(:) == 4)
        seeds.left_cfa = cfa_endpoint(branch_labels, 4);
    else
        seeds.left_cfa = cfa_endpoint(label_vol, cid_il_l);
    end

    seeds.diagnostic = struct( ...
        'aorta_top_z', aorta_top_z, ...
        'aorta_bot_z', aorta_bot_z, ...
        'z_proximal',  z_prox, ...
        'anchor',      anchor, ...
        'kidney_present', any(M_kidney(:)), ...
        'liver_present',  any(M_liver(:)), ...
        'iliac_right_present', any(label_vol(:) == cid_il_r), ...
        'iliac_left_present',  any(label_vol(:) == cid_il_l));

    seeds.ok = ~isempty(seeds.proximal) && ...
               ~isempty(seeds.right_cfa) && ...
               ~isempty(seeds.left_cfa);
end

function z = first_z_with(M)
    pres = squeeze(any(any(M, 1), 2));
    z = find(pres, 1, 'first');
end

function z = last_z_with(M)
    pres = squeeze(any(any(M, 1), 2));
    z = find(pres, 1, 'last');
end

function p = cfa_endpoint(label_vol, cid)
%CFA_ENDPOINT  Pick a seed at the most-caudal labeled slice of an iliac.
%   Returns [y x z] of the largest connected component's centroid on
%   that slice, or [] if the iliac wasn't segmented.
    p = [];
    M = (label_vol == cid);
    if ~any(M(:)); return; end
    z_bot = last_z_with(M);
    slc = M(:, :, z_bot);
    cc = bwconncomp(slc, 8);
    if cc.NumObjects == 0; return; end
    szs = cellfun(@numel, cc.PixelIdxList);
    [~, idx] = max(szs);
    [yy, xx] = ind2sub(size(slc), cc.PixelIdxList{idx});
    p = [round(mean(yy)), round(mean(xx)), z_bot];
end
