function diag_iliac_extent()
%DIAG_ILIAC_EXTENT  Measure how far caudally TS's iliac_artery label reaches.
%
%   Tests the operator's reframe (2026-06-19): instead of tracking the
%   low-contrast iliac->CFA gap (which no model/heuristic closes), make the
%   EXTERNAL ILIAC the distal target. The external iliac is the EVAR distal
%   seal/landing zone (the CFA is access, not seal). This is only viable if
%   TS's iliac_artery label actually reaches the external iliac on the
%   FAILING cases. Measures that directly.
%
%   For each case + side, reports:
%     - iliac label voxel count, z-extent (slices + mm), # connected comps
%     - caudal-most iliac z vs. femoral-head TOP z (external-iliac runs
%       alongside/above the femoral head; reaching it => EIA territory)
%     - whether iliac is ONE connected component per side down to that level

    here = fileparts(fileparts(mfilename('fullpath')));  % phase-3-real-EVAR
    cd(here);

    root = fullfile(fileparts(here), 'CTs and Angios');
    % De-identified case paths (placeholder folder names). Point these at
    % your local de-identified DICOM series dirs.
    cases = {
        'JohnDoe4 FAIL', fullfile(root, 'JohnDoe4', 'export', 'JohnDoe4', 'study', 'series');
        'JohnDoe5 FAIL', fullfile(root, 'JohnDoe5', 'export', 'JohnDoe5', 'study', 'series');
        'JohnDoe2 WORK', fullfile(root, 'JohnDoe2', 'export', 'JohnDoe2', 'study', 'series');
    };

    name2id = autoseg.class_name_to_id();
    AO = name2id('aorta'); ILL = name2id('iliac_artery_left'); ILR = name2id('iliac_artery_right');
    FEML = name2id('femur_left'); FEMR = name2id('femur_right');
    HIPL = name2id('hip_left'); HIPR = name2id('hip_right');

    for ci = 1:size(cases,1)
        tag = cases{ci,1}; dcm = cases{ci,2};
        fprintf('\n================ %s ================\n', tag);
        fprintf('series: %s\n', dcm);
        if ~exist(dcm, 'dir'); fprintf('  !! dir missing, skip\n'); continue; end
        try
            D = preprocess.dicom_load(char(dcm));
        catch ME
            fprintf('  !! dicom_load failed: %s\n', ME.message); continue;
        end
        sz = size(D.vol);
        dz = D.slice_spacing_mm; dx = D.pixel_mm(1);
        fprintf('  vol %dx%dx%d  pixel %.2f mm  slice %.2f mm  cc_known=%d\n', ...
            sz(1),sz(2),sz(3), dx, dz, isfield(D,'craniocaudal_known') && D.craniocaudal_known);

        % cache HIT expected (full mode previously run); return label volume
        opts = struct('ts_mode','full','return_label_volume',true, ...
                      'targets',{{'aorta','iliac_artery_left','iliac_artery_right'}});
        try
            [~, info] = autoseg.ts_run(D, opts);
        catch ME
            fprintf('  !! ts_run failed: %s\n', ME.message); continue;
        end
        if ~isfield(info,'label_volume') || isempty(info.label_volume)
            fprintf('  !! no label_volume returned\n'); continue;
        end
        L = info.label_volume;

        % Determine caudal direction: aorta is cranial, iliac caudal.
        zc_aorta = mean_z(L==AO);
        zc_il    = mean_z((L==ILL)|(L==ILR));
        caudal_is_high = zc_il > zc_aorta;   % true if higher z index = caudal
        fprintf('  aorta z-centroid=%.0f  iliac z-centroid=%.0f  => caudal = %s z\n', ...
            zc_aorta, zc_il, ternary(caudal_is_high,'HIGH','LOW'));

        % Femoral-head / hip caudal reference (external iliac runs to ~ femoral head top)
        femhip = (L==FEML)|(L==FEMR)|(L==HIPL)|(L==HIPR);
        [fem_lo, fem_hi] = z_range(femhip);
        if isempty(fem_lo)
            fprintf('  (no femur/hip label in FOV)\n'); fem_cranial = NaN;
        else
            % cranial-most femur/hip slice = where the external iliac would terminate
            fem_cranial = pick_cranial(fem_lo, fem_hi, caudal_is_high);
            fprintf('  femur/hip z-range [%d..%d]  (cranial end z=%d)\n', fem_lo, fem_hi, fem_cranial);
        end

        for side = {'L', ILL; 'R', ILR}'
            sname = side{1}; sid = side{2};
            report_side(sname, L==sid, caudal_is_high, fem_cranial, dz, sz);
        end

        % FOV bottom (most-caudal slice index) for context
        if caudal_is_high, fov_caudal = sz(3); else, fov_caudal = 1; end
        fprintf('  FOV caudal slice = %d\n', fov_caudal);
    end
    fprintf('\n[done]\n');
end

function report_side(name, M, caudal_is_high, fem_cranial, dz, sz) %#ok<INUSD>
    n = nnz(M);
    if n == 0
        fprintf('  iliac_%s: EMPTY\n', name); return;
    end
    [zlo, zhi] = z_range(M);
    caudal_z = pick_caudal(zlo, zhi, caudal_is_high);
    % connected components (26-conn)
    cc = bwconncomp(M, 26);
    ncc = cc.NumObjects;
    sizes = sort(cellfun(@numel, cc.PixelIdxList), 'descend');
    top = sizes(1:min(3,numel(sizes)));
    % gap to femoral head (mm), signed: + means iliac stops short of fem head
    if isnan(fem_cranial)
        gapmm = NaN; reach = '?';
    else
        gap_slices = abs(caudal_z - fem_cranial);
        gapmm = gap_slices * dz;
        % did iliac reach to/below the cranial femoral-head level?
        if caudal_is_high
            reached = caudal_z >= fem_cranial;
        else
            reached = caudal_z <= fem_cranial;
        end
        reach = ternary(reached, 'REACHES EIA/femhead level', sprintf('STOPS %.0f mm short', gapmm));
    end
    fprintf('  iliac_%s: vox=%d  z[%d..%d] caudal_z=%d  CCs=%d top=[%s]  => %s\n', ...
        name, n, zlo, zhi, caudal_z, ncc, num2str(top), reach);
end

function z = mean_z(M)
    [~,~,zz] = ind2sub(size(M), find(M));
    if isempty(zz), z = NaN; else, z = mean(zz); end
end
function [lo,hi] = z_range(M)
    [~,~,zz] = ind2sub(size(M), find(M));
    if isempty(zz), lo=[]; hi=[]; else, lo=min(zz); hi=max(zz); end
end
function z = pick_caudal(lo,hi,caudal_is_high)
    if caudal_is_high, z=hi; else, z=lo; end
end
function z = pick_cranial(lo,hi,caudal_is_high)
    if caudal_is_high, z=lo; else, z=hi; end
end
function o = ternary(c,a,b), if c, o=a; else, o=b; end, end
