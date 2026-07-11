function poc_vesselness_path()
%POC_VESSELNESS_PATH  Proof-of-concept: minimal-cost path from the aortic
%   bifurcation to the external-iliac terminus through a vesselness+intensity
%   cost image, on JohnDoe4 where TS leaves the iliac fragmented
%   and disconnected from the aorta. Tests whether an IMAGE-EVIDENCE path
%   (not a straight-tube bridge, not HU region-grow) tracks the opacified
%   lumen across the TS label gap. Writes a diary + an overlay PNG.

    diary('/tmp/poc_path.txt'); diary on;
    cleanup = onCleanup(@() diary('off'));
    S = load('/tmp/L_johndoe4.mat','L'); L = S.L;
    Dd = load('/tmp/D_johndoe4.mat','D'); D = Dd.D; V = double(D.vol);
    vox = [D.pixel_mm(1) D.pixel_mm(1) abs(D.slice_spacing_mm)];

    % --- endpoints (voxel [row col z]) -------------------------------
    % source: aorta centroid at its 3 most-caudal slices (the bifurcation)
    [ar,ac,az] = ind2sub(size(L), find(L==52));
    zc = max(az); sel = az >= zc-2;
    src = round([mean(ar(sel)) mean(ac(sel)) mean(az(sel))]);
    % target: caudal end of the largest non-aorta arterial CC (right EIA)
    art = ismember(L,[52 65 66]); cc = bwconncomp(art,26);
    np = cellfun(@numel,cc.PixelIdxList);
    isa_aorta = cellfun(@(idx) any(L(idx)==52), cc.PixelIdxList);
    cand = find(~isa_aorta); [~,bi] = max(np(cand)); ilCC = cc.PixelIdxList{cand(bi)};
    [ir,ic,iz] = ind2sub(size(L), ilCC);
    zt = max(iz); selt = iz >= zt-2;
    tgt = round([mean(ir(selt)) mean(ic(selt)) mean(iz(selt))]);
    fprintf('src(aorta bifurc) = %s   tgt(EIA terminus) = %s\n', mat2str(src), mat2str(tgt));
    fprintf('straight-line dist = %.1f mm\n', sqrt(sum(((src-tgt).*vox).^2)));

    % --- ROI sub-volume around both endpoints ------------------------
    pad = [40 40 8];
    r0=max(1,min(src(1),tgt(1))-pad(1)); r1=min(size(V,1),max(src(1),tgt(1))+pad(1));
    c0=max(1,min(src(2),tgt(2))-pad(2)); c1=min(size(V,2),max(src(2),tgt(2))+pad(2));
    z0=max(1,min(src(3),tgt(3))-pad(3)); z1=min(size(V,3),max(src(3),tgt(3))+pad(3));
    sub = V(r0:r1, c0:c1, z0:z1);
    fprintf('ROI rows[%d..%d] cols[%d..%d] z[%d..%d] size=%s\n', r0,r1,c0,c1,z0,z1, mat2str(size(sub)));
    s_l = src-[r0 c0 z0]+1;  t_l = tgt-[r0 c0 z0]+1;

    % --- cost image: low on bright + tubular -------------------------
    % intensity speed: HU 100..400 -> 0..1 (contrast lumen is bright)
    I = sub; I(I<100)=100; I(I>400)=400; speed_I = (I-100)/300;
    % vesselness (Frangi-like) via fibermetric on a contrast-windowed image
    win = sub; win(win<0)=0; win(win>500)=500; win = win/500;
    try
        vness = fibermetric(win, [3 5 7], 'ObjectPolarity','bright','StructureSensitivity',0.04);
        vness = vness / max(vness(:)+eps);
    catch ME
        fprintf('fibermetric failed (%s) — intensity-only cost\n', ME.message); vness = speed_I;
    end
    speed = max(0.15*speed_I, 0.6*vness + 0.4*speed_I);   % prefer tubular, keep bright floor
    speed = max(speed, 1e-3);
    cost = 1 ./ speed;                                     % low cost where vessel-likely

    % --- minimal-cost geodesic via graydist, then steepest-descent path
    seedmask = false(size(cost)); seedmask(s_l(1),s_l(2),s_l(3)) = true;
    Dsrc = graydist(cost, seedmask, 'quasi-euclidean');
    fprintf('geodesic cost to target = %.1f\n', Dsrc(t_l(1),t_l(2),t_l(3)));
    path = trace_path(Dsrc, t_l, s_l);                    % from target back to src
    fprintf('path nodes = %d\n', size(path,1));

    % --- HU profile along the path -----------------------------------
    hus = zeros(size(path,1),1);
    for k=1:size(path,1), p=path(k,:); hus(k)=sub(p(1),p(2),p(3)); end
    arc = sum(vecnorm(diff(path.*vox,1,1),2,2));
    fprintf('path arc length = %.1f mm\n', arc);
    fprintf('HU along path: min=%.0f  median=%.0f  frac>=150HU=%.0f%%  frac>=100=%.0f%%\n', ...
        min(hus), median(hus), 100*mean(hus>=150), 100*mean(hus>=100));
    qs = quantile(hus,[0 .1 .25 .5 .75 .9 1]);
    fprintf('HU quantiles [0 10 25 50 75 90 100] = %s\n', mat2str(round(qs)));

    % --- overlay: coronal MIP of ROI + path --------------------------
    mip = squeeze(max(sub,[],1)); mipd=mip; mipd(mipd<120)=120; mipd(mipd>420)=420; mipd=(mipd-120)/300;
    rgb = repmat(mipd,1,1,3);
    for k=1:size(path,1)
        cc2 = path(k,2); zz2 = path(k,3);
        rgb(cc2, zz2, 1)=1; rgb(cc2, zz2, 2)=0.2; rgb(cc2, zz2, 3)=0.2;
    end
    rgb = permute(rgb,[2 1 3]); rgb=imresize(rgb,2,'nearest');
    imwrite(rgb,'/tmp/poc_path_overlay.png');
    fprintf('wrote /tmp/poc_path_overlay.png\n');
end

function path = trace_path(Dmap, startp, endp)
    % steepest-descent on geodesic distance from startp(target) to endp(src)
    sz = size(Dmap); p = startp; path = p;
    [ox,oy,oz] = ndgrid(-1:1,-1:1,-1:1); off=[ox(:) oy(:) oz(:)]; off(all(off==0,2),:)=[];
    for it=1:20000
        if isequal(p,endp), break; end
        nb = p + off;
        ok = all(nb>=1,2) & nb(:,1)<=sz(1) & nb(:,2)<=sz(2) & nb(:,3)<=sz(3);
        nb = nb(ok,:);
        vals = arrayfun(@(i) Dmap(nb(i,1),nb(i,2),nb(i,3)), 1:size(nb,1));
        [mv,mi] = min(vals);
        if ~isfinite(mv) || mv >= Dmap(p(1),p(2),p(3)), break; end
        p = nb(mi,:); path(end+1,:) = p; %#ok<AGROW>
    end
end
