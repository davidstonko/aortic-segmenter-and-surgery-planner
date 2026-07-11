function report = compare_ts_fast_vs_full(seg_fast, seg_full, classes_of_interest)
%COMPARE_TS_FAST_VS_FULL  Side-by-side audit of two TS multilabel
%   segmentation volumes (typically TS --fast vs TS native resolution).
%
%   REPORT = compare_ts_fast_vs_full(SEG_FAST, SEG_FULL)
%   REPORT = compare_ts_fast_vs_full(SEG_FAST, SEG_FULL, CLASSES_OF_INTEREST)
%
%   Inputs
%       SEG_FAST              Y×X×Z uint8/16 TS-fast multilabel volume
%       SEG_FULL              Y×X×Z TS-full multilabel volume (same shape)
%       CLASSES_OF_INTEREST   cellstr of TS class names to highlight in
%                             the summary. Default = the EVAR-relevant
%                             set (aorta, iliacs, renals, celiac, SMA,
%                             kidneys, liver).
%
%   Output struct
%       .all_classes          struct array: name, id, voxels_fast,
%                             voxels_full, ratio_full_over_fast
%       .gained_in_full       cellstr of classes present in full but
%                             absent (or < 100 vox) in fast
%       .lost_in_full         cellstr of classes lost from full vs fast
%       .summary              multi-line text suitable for logging

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        seg_fast            (:,:,:) {mustBeNumeric}
        seg_full            (:,:,:) {mustBeNumeric}
        classes_of_interest cell = {}
    end
    if isempty(classes_of_interest)
        classes_of_interest = {'aorta', ...
            'iliac_artery_left', 'iliac_artery_right', ...
            'common_iliac_artery_left', 'common_iliac_artery_right', ...
            'kidney_left', 'kidney_right', 'liver', ...
            'celiac_trunk', 'superior_mesenteric_artery', ...
            'renal_artery_left', 'renal_artery_right', ...
            'aorta_branch_celiac', 'aorta_branch_sma', ...
            'aorta_branch_renal_left', 'aorta_branch_renal_right'};
    end
    if ~isequal(size(seg_fast), size(seg_full))
        error('compare_ts_fast_vs_full:SizeMismatch', ...
            'seg_fast %s vs seg_full %s', mat2str(size(seg_fast)), mat2str(size(seg_full)));
    end

    n2i = autoseg.class_name_to_id();
    names_all = keys(n2i);
    ids_all   = cell2mat(values(n2i));

    % Per-class voxel counts
    all = struct('name', {}, 'id', {}, 'voxels_fast', {}, ...
                 'voxels_full', {}, 'ratio_full_over_fast', {});
    for k = 1:numel(names_all)
        cid = ids_all(k);
        n_f = nnz(seg_fast == cid);
        n_F = nnz(seg_full == cid);
        if n_f == 0 && n_F == 0; continue; end
        all(end+1) = struct( ...
            'name', names_all{k}, 'id', cid, ...
            'voxels_fast', n_f, 'voxels_full', n_F, ...
            'ratio_full_over_fast', n_F / max(n_f, 1)); %#ok<AGROW>
    end

    % Gained / lost
    THRESH = 100;
    gained = {};  lost = {};
    for k = 1:numel(all)
        if all(k).voxels_full >= THRESH && all(k).voxels_fast < THRESH
            gained{end+1} = all(k).name; %#ok<AGROW>
        elseif all(k).voxels_fast >= THRESH && all(k).voxels_full < THRESH
            lost{end+1} = all(k).name; %#ok<AGROW>
        end
    end

    % Summary text
    lines = {};
    lines{end+1} = sprintf('=== TS fast vs full comparison ===');
    lines{end+1} = sprintf('Total classes present (either): %d', numel(all));
    lines{end+1} = sprintf('Gained in full (>= %d vox in full but not fast): %d', THRESH, numel(gained));
    lines{end+1} = sprintf('Lost in full (>= %d vox in fast but not full):  %d', THRESH, numel(lost));
    lines{end+1} = '';
    lines{end+1} = sprintf('--- EVAR classes of interest ---');
    lines{end+1} = sprintf('  %-32s  %10s  %10s  %6s', 'class', 'fast vox', 'full vox', 'ratio');
    for k = 1:numel(classes_of_interest)
        nm = classes_of_interest{k};
        idx = find(strcmp({all.name}, nm), 1);
        if isempty(idx)
            lines{end+1} = sprintf('  %-32s  %10s  %10s  %6s', nm, '—', '—', '—'); %#ok<AGROW>
        else
            e = all(idx);
            lines{end+1} = sprintf('  %-32s  %10d  %10d  %6.2f', ...
                e.name, e.voxels_fast, e.voxels_full, e.ratio_full_over_fast); %#ok<AGROW>
        end
    end
    if ~isempty(gained)
        lines{end+1} = '';
        lines{end+1} = '--- Gained in full ---';
        for k = 1:numel(gained); lines{end+1} = sprintf('  + %s', gained{k}); end %#ok<AGROW>
    end
    if ~isempty(lost)
        lines{end+1} = '';
        lines{end+1} = '--- Lost in full ---';
        for k = 1:numel(lost); lines{end+1} = sprintf('  - %s', lost{k}); end %#ok<AGROW>
    end

    report = struct( ...
        'all_classes',     all, ...
        'gained_in_full',  {gained}, ...
        'lost_in_full',    {lost}, ...
        'summary',         strjoin(lines, newline));
end
