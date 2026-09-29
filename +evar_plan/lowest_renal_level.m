function lr = lowest_renal_level(label_branch, D, opts)
%EVAR_PLAN.LOWEST_RENAL_LEVEL  Locate the lower margin of the lowest renal
%   artery ostium — the anatomic proximal boundary of the infrarenal neck.
%
%   LR = evar_plan.lowest_renal_level(LABEL_BRANCH, D)
%   LR = evar_plan.lowest_renal_level(LABEL_BRANCH, D, OPTS)
%
%   LABEL_BRANCH is the pipeline-scheme label volume (Y×X×Z, head at z=1):
%   1 = aorta, 6/7 = L/R renal. For each renal label, the OSTIAL voxels are
%   the renal voxels lying within OPTS.ostium_mm (in-plane) of the aortic
%   lumen on the same slice. The renal's lower margin is a high percentile
%   of those voxels' slice index (caudal = larger index), and the lowest
%   renal is the more caudal of the two sides.
%
%   OPTS (optional):
%     .ostium_mm   in-plane distance from the aorta that counts as ostial
%                  (default 5 mm)
%     .z_pct       percentile of ostial slice indices taken as the lower
%                  margin (default 90 — robust to a stray caudal voxel)
%     .kidney_z    struct .L/.R = [top bottom] kidney slice ranges. When
%                  given (auto-detected labels), two plausibility gates
%                  run per side: the ostium must lie at kidney level
%                  (.kidney_below_mm / .kidney_above_mm tolerance) and the
%                  label must reach >= .min_reach_mm (20) laterally from the
%                  aorta. A side failing either is rejected (see .note).
%                  Omit for hand-annotated masks (no gating).
%
%   Returns LR:
%     .found       logical — at least one renal ostium located
%     .z_idx       slice index (head at 1) of the lowest renal's lower
%                  margin; NaN if not found
%     .z_mm        the same level in the centerline Z frame
%                  (D.slice_z_mm(z_idx), or (z_idx-1)*slice_spacing_mm)
%     .side        'L' | 'R' | ''
%     .z_idx_L, .z_idx_R   per-side lower margins (NaN if absent)
%     .note        human-readable reason when not found
%
%   Research use only.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        label_branch
        D            (1,1) struct
        opts         (1,1) struct = struct()
    end
    if ~isfield(opts, 'ostium_mm'); opts.ostium_mm = 5;  end
    if ~isfield(opts, 'z_pct');     opts.z_pct     = 90; end
    % Anatomic plausibility gate: a renal artery arises at the level of its
    % kidney — never below the lower pole or far above the upper pole.
    % opts.kidney_z.L / .R = [z_top z_bottom] slice range (head at 1), NaN
    % when that kidney wasn't segmented. A branch-labelled "renal" outside
    % the gate (e.g. a lumbar or gonadal vessel mislabelled by the branch
    % detector — seen on a real case) is rejected instead of anchoring the
    % neck on the wrong level. Omit kidney_z to skip the gate (e.g. hand-
    % annotated masks, whose renal labels are trusted).
    if ~isfield(opts, 'kidney_z');        opts.kidney_z        = struct(); end
    if ~isfield(opts, 'kidney_below_mm'); opts.kidney_below_mm = 10; end
    if ~isfield(opts, 'kidney_above_mm'); opts.kidney_above_mm = 20; end
    % Second gate (same condition — auto-detected labels only): a renal
    % artery runs LATERALLY toward the kidney, so its label must reach at
    % least this far (in-plane) from the aortic lumen. Real auto-detected
    % renals reached 32-62 mm on a real case; a mislabelled stub reached
    % 1.5 mm. Not applied to hand-annotated masks, which by SOP paint only
    % the proximal 1-2 cm of each renal.
    if ~isfield(opts, 'min_reach_mm');    opts.min_reach_mm    = 20; end
    gated = isstruct(opts.kidney_z) && ~isempty(fieldnames(opts.kidney_z));

    lr = struct('found', false, 'z_idx', NaN, 'z_mm', NaN, 'side', '', ...
                'z_idx_L', NaN, 'z_idx_R', NaN, 'note', '');

    if isempty(label_branch) || ndims(label_branch) ~= 3
        lr.note = 'no branch label volume';
        return;
    end
    aorta = label_branch == 1;
    if ~any(aorta(:))
        lr.note = 'no aorta label (1)';
        return;
    end
    px = mean(abs(double(D.pixel_mm(1:2))));
    if ~(px > 0); px = 1; end

    sides = {'L', 6; 'R', 7};
    rejected = {};
    for s = 1:2
        lab = sides{s, 2};
        ren = label_branch == lab;
        if ~any(ren(:)); continue; end
        zs = find(squeeze(any(any(ren, 1), 2))).';
        ost_z = [];
        reach = 0;
        for z = zs
            a2 = aorta(:, :, z);
            if ~any(a2(:)); continue; end
            d2 = bwdist(a2) * px;                    % in-plane mm to aortic lumen
            r2 = ren(:, :, z);
            hit = r2 & d2 <= opts.ostium_mm;
            if any(hit(:)); ost_z(end+1) = z; end %#ok<AGROW>
            reach = max(reach, max(d2(r2)));
        end
        if isempty(ost_z); continue; end
        if gated && reach < opts.min_reach_mm
            rejected{end+1} = sprintf('%s renal label reaches only %.1f mm from the aorta (stub, not a renal artery)', ...
                sides{s, 1}, reach); %#ok<AGROW>
            continue;
        end
        zlow = prctile(ost_z, opts.z_pct);
        kz = kidney_range(opts.kidney_z, sides{s, 1});
        if gated && ~any(isnan(kz))
            ssp = abs(D.slice_spacing_mm); if ~(ssp > 0); ssp = 1; end
            if zlow > kz(2) + opts.kidney_below_mm / ssp || ...
                    min(ost_z) < kz(1) - opts.kidney_above_mm / ssp
                rejected{end+1} = sprintf('%s renal label at slice %d is outside its kidney (%d-%d)', ...
                    sides{s, 1}, round(zlow), kz(1), kz(2)); %#ok<AGROW>
                continue;
            end
        end
        lr.(['z_idx_' sides{s, 1}]) = round(zlow);
    end

    zL = lr.z_idx_L; zR = lr.z_idx_R;
    if isnan(zL) && isnan(zR)
        if ~isempty(rejected)
            lr.note = ['renal labels failed plausibility checks: ' strjoin(rejected, '; ')];
        else
            lr.note = 'no renal ostium adjacent to the aortic lumen (labels 6/7 absent or detached)';
        end
        return;
    end
    if ~isempty(rejected); lr.note = strjoin(rejected, '; '); end
    % Lowest renal = the MORE CAUDAL ostium (larger index, head at z=1).
    if isnan(zR) || (~isnan(zL) && zL >= zR)
        lr.z_idx = zL; lr.side = 'L';
    else
        lr.z_idx = zR; lr.side = 'R';
    end
    lr.found = true;

    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm) && ...
            lr.z_idx >= 1 && lr.z_idx <= numel(D.slice_z_mm)
        lr.z_mm = D.slice_z_mm(lr.z_idx);
    else
        lr.z_mm = (lr.z_idx - 1) * abs(D.slice_spacing_mm);
    end
end

function kz = kidney_range(K, side)
%KIDNEY_RANGE  [top bottom] slice range for the kidney on SIDE; falls back
%   to the union of whatever kidneys exist (nephrectomy / missed kidney);
%   [NaN NaN] when no kidney information was supplied.
    kz = [NaN NaN];
    if ~isstruct(K) || isempty(fieldnames(K)); return; end
    if isfield(K, side) && numel(K.(side)) == 2 && ~any(isnan(K.(side)))
        kz = K.(side); return;
    end
    all_z = [];
    for f = {'L', 'R'}
        if isfield(K, f{1}) && numel(K.(f{1})) == 2 && ~any(isnan(K.(f{1})))
            all_z = [all_z, K.(f{1})]; %#ok<AGROW>
        end
    end
    if ~isempty(all_z); kz = [min(all_z) max(all_z)]; end
end
