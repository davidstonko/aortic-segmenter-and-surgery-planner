function diag_johndoe1_fragment()
%DIAG_JOHNDOE1_FRAGMENT  Replay the JohnDoe1 mask assembly up to step 6b using
%   cached TS + branch detection, and report the CC structure / per-side
%   reach BEFORE and AFTER step 3c (HU-reconstruct) and step 6b
%   (keep-largest-CC). Saves the pre-6b mask + label to disk so the
%   reconnection fix can be developed without re-running TS.

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(proj); cd(proj);

    % --- Load the JohnDoe1 CT (cached .mat) ---
    S = load(fullfile(proj,'results','logs','ct_volume.mat'));   % var D_ct
    D = S.D_ct; clear S;
    pix_mm = abs(D.pixel_mm(1));
    sz = size(D.vol);
    mid = 289;   % right/left split column (between CFA seeds 201 / 376)

    reach = @(M) deal( ...
        find(squeeze(any(any(M(:,1:mid,:),1),2)),1,'last'), ...
        find(squeeze(any(any(M(:,mid+1:end,:),1),2)),1,'last'));
    ccrep = @(M) sprintf('CCs=%d largest=%.1f%% nnz=%d', ...
        getfield(bwconncomp(M,26),'NumObjects'), ...
        100*max(cellfun(@numel,bwconncomp(M,26).PixelIdxList))/max(1,nnz(M)), nnz(M));

    % --- Step 2: TS (cached) ---
    ts_opts = struct('targets', {{'aorta','iliac_artery_left','iliac_artery_right', ...
        'kidney_left','kidney_right','liver'}}, 'fast', true, 'return_label_volume', true);
    [mask, info] = autoseg.ts_run(D, ts_opts);
    fprintf('[2] TS cached=%d  %s\n', info.from_cache, ccrep(mask));

    % --- Step 3: branch detection (cached) ---
    seg_uint8 = uint8(info.label_volume);
    [m_branch, label_branch] = autoseg.detect_branches_cached(D, seg_uint8);
    mask = mask | m_branch;
    [r,l]=reach(mask); fprintf('[3] +branches  R=%d L=%d  %s\n', r,l, ccrep(mask));

    % --- Step 3b: walker ---
    [mask, label_branch] = autoseg.extend_to_cfa(D, mask, label_branch, struct('verbose',false));
    [r,l]=reach(mask); fprintf('[3b] +walker   R=%d L=%d  %s\n', r,l, ccrep(mask));

    % --- Step 3b'': adaptive follower ---
    mask = autoseg.follow_iliacs_adaptive(D, mask, label_branch, struct('verbose',false));
    [r,l]=reach(mask); fprintf('[3b''] +follower R=%d L=%d  %s\n', r,l, ccrep(mask));

    % Per-CC reach: how far down does EACH disconnected CC go on the right?
    cc = bwconncomp(mask,26); nv = cellfun(@numel,cc.PixelIdxList);
    [~,ord] = sort(nv,'descend');
    fprintf('   --- CC breakdown (pre-3c), top 6 by size ---\n');
    for ii = 1:min(6,numel(ord))
        k = ord(ii); pil = cc.PixelIdxList{k};
        [yy,xx,zz] = ind2sub(sz,pil);
        side = 'R'; if mean(xx)>mid, side='L'; end
        fprintf('   CC#%d size=%d side=%s z=%d..%d  col=%d..%d\n', ...
            ii, numel(pil), side, min(zz),max(zz), min(xx),max(xx));
    end

    mask_pre3c = mask;

    % --- Step 3c: HU-reconstruct (single-pass 5mm shell) ---
    contrast_mask = (D.vol>=150)&(D.vol<=1400);
    shell_r = max(3, round(5/pix_mm));
    shell = imdilate(mask, strel('sphere',shell_r));
    cand  = autoseg.drop_big_inplane_cc(contrast_mask & shell, round(400/pix_mm^2));
    grown = imreconstruct(mask, mask | cand, 26);
    mask = grown;
    [r,l]=reach(mask); fprintf('[3c] +HUrecon  R=%d L=%d  %s (shell_r=%d)\n', r,l, ccrep(mask), shell_r);

    % --- Step 6b: keep largest CC ---
    cc = bwconncomp(mask,26); nvv = cellfun(@numel,cc.PixelIdxList);
    [~,kb]=max(nvv); ml=false(sz); ml(cc.PixelIdxList{kb})=true; mask6b=ml;
    [r,l]=reach(mask6b); fprintf('[6b] keep-big R=%d L=%d  %s\n', r,l, ccrep(mask6b));

    % --- Save pre-6b artifacts for fix development ---
    outp = fullfile(proj,'results','logs','johndoe1_fragment_diag.mat');
    save(outp, 'mask_pre3c', 'label_branch', '-v7.3');
    fprintf('Saved pre-3c mask + label to %s\n', outp);
end
