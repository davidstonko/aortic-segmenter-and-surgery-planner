function report = verify_annotation(label_nifti, opts)
%INTAKE.VERIFY_ANNOTATION  QC gate for a finished Set-A annotation mask
%   before it enters the training cohort. Catches the silent mistakes that
%   would otherwise only surface as a `SeedFailed` planner run (or worse, a
%   wrong plan) many cases later.
%
%   REPORT = intake.verify_annotation(LABEL_NIFTI)
%   REPORT = intake.verify_annotation(LABEL_NIFTI, OPTS)
%
%   Loads a label NIfTI, translates it to the pipeline scheme (Set-A masks
%   are painted in SOP paint-IDs and MUST be translated — see
%   data/setA_class_map.json), and checks everything the planner depends on:
%
%   ERRORS (block the case — the planner would fail or mis-seed):
%     * empty mask
%     * missing aorta (pipeline label 1)   — no proximal seed
%     * missing L CFA (4) or R CFA (5)      — CFA seed -> SeedFailed
%     * grid mismatch vs the CT (opts.ct)   — mask off the CT voxel grid
%     * labels outside the known scheme     — likely an untranslated paint
%                                             mask; pass opts.class_map
%     * aorta not connected to a CFA        — per-side continuity broken;
%                                             keep-largest-CC would drop a leg
%
%   WARNINGS (allowed, but flagged):
%     * no celiac (8) AND no SMA (9) — proximal seed falls back to
%       aorta-top, less accurate than the 5-cm-above-celiac target
%     * missing renals (6/7) or iliacs (2/3)
%     * a label present with a suspiciously small voxel count
%
%   OPTS (all optional):
%     .class_map   class-map JSON to translate the NIfTI into the pipeline
%                  scheme (e.g. data/setA_class_map.json). If omitted, the
%                  mask is assumed already in pipeline labels; a mask
%                  carrying out-of-scheme ids errors with a hint to pass it.
%     .ct          grid reference: a `preprocess.dicom_load` D-struct, a CT
%                  NIfTI path, or a 1x3 size vector. Skipped (with a
%                  warning) if omitted.
%     .min_voxels  per-label small-count warning threshold (default 10).
%     .verbose     print a readable summary (default true).
%
%   REPORT:
%     .ok            true iff there are no ERRORS.
%     .errors        cellstr of blocking problems.
%     .warnings      cellstr of non-blocking flags.
%     .labels        struct array: .pipeline_label .name .voxels (present).
%     .n_components  number of 26-connected components in the mask.
%     .grid_ok       logical (true if checked and matching; NaN if skipped).
%
%   RESEARCH USE ONLY. Governed by the approved IRB protocol.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        label_nifti (1,:) char
        opts        (1,1) struct = struct()
    end
    if ~isfield(opts, 'class_map');  opts.class_map  = '';   end
    if ~isfield(opts, 'ct');         opts.ct         = [];   end
    if ~isfield(opts, 'min_voxels'); opts.min_voxels = 10;   end
    if ~isfield(opts, 'verbose');    opts.verbose    = true; end

    PIPE_NAMES = containers.Map( ...
        {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}, ...
        {'aorta', 'L iliac', 'R iliac', 'L CFA', 'R CFA', 'L renal', ...
         'R renal', 'celiac', 'SMA', 'aortic wall', 'ILT'});
    PIPE_VALID = [0 1 2 3 4 5 6 7 8 9 10 11];

    report = struct('ok', false, 'errors', {{}}, 'warnings', {{}}, ...
        'labels', struct('pipeline_label', {}, 'name', {}, 'voxels', {}), ...
        'n_components', 0, 'grid_ok', NaN);

    if ~exist(label_nifti, 'file')
        error('intake:verify_annotation:NotFound', ...
            'Label NIfTI not found: %s', label_nifti);
    end

    raw = uint8(niftiread(label_nifti));

    % --- resolve to the pipeline scheme --------------------------------
    if ~isempty(opts.class_map)
        lab = uint8(autoseg.aortaseg24.translate_labels(raw, opts.class_map));
    else
        present_raw = unique(raw(:)).';
        stray = setdiff(double(present_raw), PIPE_VALID);
        if ~isempty(stray)
            error('intake:verify_annotation:UntranslatedLabels', ...
                ['Labels [%s] are outside the pipeline scheme — this looks ' ...
                 'like an untranslated Set-A paint mask. Pass ' ...
                 'opts.class_map (e.g. data/setA_class_map.json).'], ...
                num2str(stray));
        end
        lab = raw;
    end

    mask = lab > 0;

    % --- grid check ----------------------------------------------------
    ct_sz = resolve_ct_size(opts.ct);
    if isempty(ct_sz)
        report.warnings{end+1} = ['grid not checked (opts.ct not supplied) — ' ...
            'confirm the mask was exported on the CT voxel grid'];
    else
        report.grid_ok = isequal(size(lab), ct_sz(:).');
        if ~report.grid_ok
            report.errors{end+1} = sprintf( ...
                'grid mismatch: mask [%s] != CT [%s] — re-export on the CT grid', ...
                num2str(size(lab)), num2str(ct_sz(:).'));
        end
    end

    % --- empty mask ----------------------------------------------------
    if ~any(mask(:))
        report.errors{end+1} = 'empty mask (no labelled voxels)';
        report = finish(report, opts, PIPE_NAMES);
        return;
    end

    % --- per-label voxel inventory -------------------------------------
    present = double(unique(lab(lab > 0)).');
    for id = present
        nm = 'unknown';
        if isKey(PIPE_NAMES, id); nm = PIPE_NAMES(id); end
        v = nnz(lab == id);
        report.labels(end+1) = struct('pipeline_label', id, 'name', nm, 'voxels', v);
        if v < opts.min_voxels
            report.warnings{end+1} = sprintf( ...
                'label %d (%s) has only %d voxels — likely a stray speck', id, nm, v);
        end
    end

    % --- required labels ----------------------------------------------
    req = struct('id', {1, 4, 5}, 'why', ...
        {'aorta — proximal seed', 'L CFA (4) — left seed', 'R CFA (5) — right seed'});
    for r = req
        if ~any(present == r.id)
            report.errors{end+1} = sprintf('missing pipeline label %d (%s)', r.id, r.why);
        end
    end

    % --- proximal-anchor advisory -------------------------------------
    if ~any(present == 8) && ~any(present == 9)
        report.warnings{end+1} = ['no celiac (8) or SMA (9) — proximal seed ' ...
            'will fall back to aorta-top, less accurate than 5 cm above celiac'];
    end
    for pair = {{2, 3, 'iliacs'}, {6, 7, 'renals'}}
        p = pair{1};
        if ~any(present == p{1}) && ~any(present == p{2})
            report.warnings{end+1} = sprintf('no %s (labels %d/%d)', p{3}, p{1}, p{2});
        end
    end

    % --- connectivity: aorta must reach each CFA -----------------------
    cc = bwlabeln(mask, 26);
    report.n_components = max(cc(:));
    aorta_ccs = unique(cc(lab == 1));
    aorta_ccs = aorta_ccs(aorta_ccs > 0);
    for cfa = [4 5]
        if ~any(present == cfa); continue; end
        cfa_ccs = unique(cc(lab == cfa));
        cfa_ccs = cfa_ccs(cfa_ccs > 0);
        if isempty(intersect(aorta_ccs, cfa_ccs))
            report.errors{end+1} = sprintf( ...
                'aorta (1) not connected to CFA %d — per-side continuity broken', cfa);
        end
    end

    report = finish(report, opts, PIPE_NAMES);
end

% =========================================================================
function report = finish(report, opts, ~)
    report.ok = isempty(report.errors);
    if opts.verbose
        if report.ok
            fprintf('[verify_annotation] PASS');
        else
            fprintf('[verify_annotation] FAIL');
        end
        fprintf(' — %d label(s), %d component(s)\n', ...
            numel(report.labels), report.n_components);
        for e = report.errors;   fprintf('   [ERROR] %s\n', e{1}); end
        for w = report.warnings; fprintf('   [warn ] %s\n', w{1}); end
    end
end

function sz = resolve_ct_size(ct)
    sz = [];
    if isempty(ct); return; end
    if isstruct(ct) && isfield(ct, 'vol') && ~isempty(ct.vol)
        sz = size(ct.vol);
    elseif isnumeric(ct) && numel(ct) == 3
        sz = double(ct(:).');
    elseif (ischar(ct) || isstring(ct)) && exist(char(ct), 'file')
        info = niftiinfo(char(ct));
        sz = info.ImageSize;
    end
end
