function [mask_out, info] = reconnect_via_vesselness_path(D, mask_in, opts)
%AUTOSEG.RECONNECT_VIA_VESSELNESS_PATH  Reconnect arterial fragments that
%   TS/the walker severed from the main (aorta) component by routing a
%   MINIMUM-COST PATH through a vesselness+intensity cost image and adding
%   the genuine contrast along it. Unlike the iterative shell flood in
%   autoseg.reconnect_vessel_fragments (which leaks on lower-contrast
%   scans because it is a region GROW), this finds the single best curve
%   between two endpoints, so it crosses a TS label gap by following the
%   real opacified lumen without flooding neighbouring veins/bowel.
%
%   [MASK_OUT, INFO] = autoseg.reconnect_via_vesselness_path(D, MASK_IN, OPTS)
%
%   WHY (2026-06-19, external-iliac reframe / GOALS #41):
%       On JohnDoe4 TS leaves the aorta and each iliac as
%       SEPARATE 3-D components (disconnected at/below the bifurcation),
%       so the centerline cannot span aorta->external-iliac even though
%       the contrast vessel is physically present. A vesselness minimal
%       path from the aortic bifurcation to the iliac fragment rides the
%       real lumen (POC: median 423 HU, 77% of nodes >=150 HU), curving
%       like a vessel (209 mm arc vs 136 mm straight). This promotes that
%       POC into a guarded, production reconnect.
%
%   BRIDGE-FREE / NO STRAIGHT TUBES (honours the operator's rule):
%       - The path is the MINIMUM-COST curve through a vesselness cost, not
%         a straight segment — it bends to stay on contrast.
%       - A path is ACCEPTED only if it actually rides contrast
%         (opts.min_cover fraction of nodes >= opts.hu_lo AND median HU
%         >= opts.hu_lo). A route that has to cross tissue to reach a
%         fragment fails the gate and that fragment is left disconnected
%         (reported), rather than forging a tube through soft tissue.
%       - Voxels added are the path corridor INTERSECTED with genuine
%         contrast (HU >= opts.hu_soft), plus the 1-voxel path thread
%         itself to guarantee 26-connectivity across the few unavoidable
%         partial-volume nodes on an accepted (vessel-riding) path.
%
%   OPTS:
%     .anchor_seed   [r c z] voxel that must lie in the main component
%                    (e.g. the proximal aorta seed). Default: largest CC.
%     .z_lo          lowest z-slice to reconnect within (pelvis floor).
%                    Default 1. Fragments fully above z_lo are ignored.
%     .min_frag_vox  ignore fragments smaller than this (default 800).
%     .hu_lo         arterial contrast floor for the quality gate (150).
%     .hu_hi         contrast ceiling (1400).
%     .hu_soft       soft floor for corridor voxels actually added (90) —
%                    captures partial-volume lumen on an accepted path.
%     .min_cover     min fraction of path nodes >= hu_lo to ACCEPT (0.6).
%     .corridor_vox  corridor radius in voxels around the path (1).
%     .max_path_mm   reject paths longer than this (default 350) — a
%                    runaway route is a leak, not an iliac.
%     .verbose       default true.
%
%   OUTPUT:
%     MASK_OUT  logical, superset of MASK_IN (fragments merged where a
%               vessel-riding path was found).
%     INFO      struct: .cc_before/.cc_after, .added_voxels, and a
%               per-fragment .paths array (accepted flag, coverage, arc,
%               median HU, added voxels, reason).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D       (1,1) struct
        mask_in logical
        opts    (1,1) struct = struct()
    end
    if ~isfield(opts,'z_lo');         opts.z_lo = 1;          end
    if ~isfield(opts,'min_frag_vox'); opts.min_frag_vox = 800; end
    if ~isfield(opts,'hu_lo');        opts.hu_lo = 150;       end
    if ~isfield(opts,'hu_hi');        opts.hu_hi = 1400;      end
    if ~isfield(opts,'hu_soft');      opts.hu_soft = 90;      end
    if ~isfield(opts,'min_cover');    opts.min_cover = 0.6;   end
    if ~isfield(opts,'corridor_vox'); opts.corridor_vox = 1;  end
    if ~isfield(opts,'max_path_mm');  opts.max_path_mm = 350; end
    if ~isfield(opts,'verbose');      opts.verbose = true;    end
    if ~isfield(opts,'anchor_seed');  opts.anchor_seed = [];  end

    sz = size(mask_in); if numel(sz)<3, sz(3)=1; end
    V  = double(D.vol);
    vox = [abs(D.pixel_mm(1)) abs(D.pixel_mm(1)) abs(D.slice_spacing_mm)];

    cc = bwconncomp(mask_in, 26);
    info = struct('cc_before', cc.NumObjects, 'cc_after', cc.NumObjects, ...
                  'added_voxels', 0, 'paths', struct([]), 'reason', '');
    if cc.NumObjects <= 1
        mask_out = mask_in; info.reason = 'single component — nothing to reconnect';
        if opts.verbose, fprintf('[recon_vpath] %s\n', info.reason); end
        return;
    end

    np = cellfun(@numel, cc.PixelIdxList);
    % anchor component
    if ~isempty(opts.anchor_seed)
        s = round(opts.anchor_seed(:)');
        anchor = pointCC(cc, sz, s);
        if isempty(anchor), [~,anchor] = max(np); end
    else
        [~,anchor] = max(np);
    end

    mask_out = mask_in;
    addedTot = 0;
    pathsOut = struct('frag',{},'accepted',{},'cover',{},'arc_mm',{}, ...
                      'med_hu',{},'added',{},'reason',{});

    for f = 1:cc.NumObjects
        if f == anchor, continue; end
        if np(f) < opts.min_frag_vox, continue; end
        [fr,fc,fz] = ind2sub(sz, cc.PixelIdxList{f});
        if max(fz) < opts.z_lo, continue; end   % fragment is cranial to pelvis floor

        % ROI bounding both anchor (caudal part) and fragment
        anchorIdx = cc.PixelIdxList{anchor};
        [ar,ac,az] = ind2sub(sz, anchorIdx);
        % restrict anchor to within reach of the fragment (caudal 80 mm band
        % toward the fragment) for cost/speed
        zf = round(mean(fz));
        keepA = abs(az - zf) <= round(120/vox(3));
        if ~any(keepA), keepA = true(size(az)); end
        ar=ar(keepA); ac=ac(keepA); az=az(keepA);
        pad = [25 25 5];
        r0=max(1,min([ar;fr])-pad(1)); r1=min(sz(1),max([ar;fr])+pad(1));
        c0=max(1,min([ac;fc])-pad(2)); c1=min(sz(2),max([ac;fc])+pad(2));
        z0=max(1,min([az;fz])-pad(3)); z1=min(sz(3),max([az;fz])+pad(3));
        sub = V(r0:r1, c0:c1, z0:z1);
        szs = size(sub);

        % cost: low on bright + tubular
        I = sub; I(I<100)=100; I(I>400)=400; spI=(I-100)/300;
        win = sub; win(win<0)=0; win(win>500)=500; win=win/500;
        try
            vn = fibermetric(win,[3 5 7],'ObjectPolarity','bright','StructureSensitivity',0.04);
            vn = vn/(max(vn(:))+eps);
        catch
            vn = spI;
        end
        speed = max(0.15*spI, 0.6*vn + 0.4*spI);
        cost  = 1 ./ max(speed,1e-3);

        % seed = anchor voxels in ROI; target = fragment voxels in ROI
        seedmask = false(szs);
        seedmask(sub2ind(szs, ar-r0+1, ac-c0+1, az-z0+1)) = true;
        Dg = graydist(cost, seedmask, 'quasi-euclidean');
        fl = sub2ind(szs, fr-r0+1, fc-c0+1, fz-z0+1);
        [~,mk] = min(Dg(fl));
        [tr,tc,tz] = ind2sub(szs, fl(mk));
        % backtrace target->seed
        path = tracePath(Dg, [tr tc tz]);
        if size(path,1) < 2
            pathsOut(end+1) = mkrow(f,false,0,0,0,0,'no path'); %#ok<AGROW>
            continue;
        end
        % HU + arc along path (in ROI coords)
        hus = arrayfun(@(k) sub(path(k,1),path(k,2),path(k,3)), 1:size(path,1))';
        pg = path + [r0 c0 z0] - 1;                    % back to global
        arc = sum(vecnorm(diff(pg.*vox,1,1),2,2));
        cover = mean(hus >= opts.hu_lo);
        medhu = median(hus);

        accept = cover >= opts.min_cover && medhu >= opts.hu_lo && arc <= opts.max_path_mm;
        if ~accept
            pathsOut(end+1) = mkrow(f,false,cover,arc,medhu,0, ...
                sprintf('gate fail (cover=%.2f med=%.0f arc=%.0f)',cover,medhu,arc)); %#ok<AGROW>
            if opts.verbose
                fprintf('[recon_vpath] frag %d REJECT cover=%.2f med=%.0f arc=%.0fmm\n',f,cover,medhu,arc);
            end
            continue;
        end

        % add: 1-vox path thread (guarantees connectivity) + corridor∩contrast
        addmask = false(size(sub));
        for k=1:size(path,1), addmask(path(k,1),path(k,2),path(k,3))=true; end
        if opts.corridor_vox >= 1
            corr = imdilate(addmask, strel('sphere', opts.corridor_vox));
            contrast = (sub >= opts.hu_soft) & (sub <= opts.hu_hi);
            addmask = addmask | (corr & contrast);
        end
        nb = nnz(mask_out(r0:r1,c0:c1,z0:z1));
        blk = mask_out(r0:r1,c0:c1,z0:z1) | addmask;
        mask_out(r0:r1,c0:c1,z0:z1) = blk;
        added = nnz(blk) - nb;
        addedTot = addedTot + added;
        pathsOut(end+1) = mkrow(f,true,cover,arc,medhu,added,'accepted'); %#ok<AGROW>
        if opts.verbose
            fprintf('[recon_vpath] frag %d ACCEPT cover=%.2f med=%.0f arc=%.0fmm +%d vox\n',f,cover,medhu,arc,added);
        end
    end

    info.cc_after = bwconncomp(mask_out,26).NumObjects;
    info.added_voxels = addedTot;
    info.paths = pathsOut;
    info.reason = sprintf('vesselness-path reconnect: %d->%d CCs, +%d vox', ...
        info.cc_before, info.cc_after, addedTot);
    if opts.verbose, fprintf('[recon_vpath] %s\n', info.reason); end
end

% ---- helpers ----------------------------------------------------------
function k = pointCC(cc, sz, s)
    k = [];
    if any(s<1) || any(s(:)'>sz), return; end
    li = sub2ind(sz, s(1), s(2), s(3));
    for i=1:cc.NumObjects
        if any(cc.PixelIdxList{i}==li), k=i; return; end
    end
end
function p = tracePath(Dmap, startp)
    sz = size(Dmap); p0 = startp; path = p0;
    [ox,oy,oz]=ndgrid(-1:1,-1:1,-1:1); off=[ox(:) oy(:) oz(:)]; off(all(off==0,2),:)=[];
    p = p0;
    for it=1:50000
        nb = p + off;
        ok = all(nb>=1,2) & nb(:,1)<=sz(1) & nb(:,2)<=sz(2) & nb(:,3)<=sz(3);
        nb = nb(ok,:);
        vals = arrayfun(@(i) Dmap(nb(i,1),nb(i,2),nb(i,3)), 1:size(nb,1));
        [mv,mi]=min(vals);
        if ~isfinite(mv) || mv >= Dmap(p(1),p(2),p(3)), break; end
        p = nb(mi,:); path(end+1,:)=p; %#ok<AGROW>
    end
    p = path;
end
function row = mkrow(frag,accepted,cover,arc,medhu,added,reason)
    row = struct('frag',frag,'accepted',accepted,'cover',cover,'arc_mm',arc, ...
                 'med_hu',medhu,'added',added,'reason',reason);
end
