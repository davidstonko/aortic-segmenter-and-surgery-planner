function results = run_benchmark(cohort_root, ref_dir, opts)
%RUN_BENCHMARK  Compare the automated planner against a directory of
%   reference annotations. The big use case is goal #5 (TeraRecon
%   accuracy benchmark) — pair each CT case with a `<case>.ref.json` and
%   run this script to get a per-case delta table.
%
%   results = run_benchmark(COHORT_ROOT, REF_DIR)
%   results = run_benchmark(COHORT_ROOT, REF_DIR, OPTS)
%
%   COHORT_ROOT  directory containing one sub-directory per case (same
%                layout as `scripts/run_batch.m`).
%   REF_DIR      directory containing `<case>.ref.json` files (one per case).
%   OPTS:
%       .out_dir            where to write the delta CSV (default
%                           `results/logs/benchmark_<timestamp>/`)
%       .planner_opts       struct passed to run_planner_headless
%       .skip_missing_ref   if true, cases without a REF JSON are skipped
%                           silently (default true). If false, they're
%                           reported as 'no_reference' in the table.
%
%   Returns a struct array with one entry per case:
%       .case_name
%       .status            'ok' | 'planner_failed' | 'no_reference'
%       .ref_loaded        logical
%       .auto              measurements struct from the planner
%       .ref               measurements struct from the reference JSON
%       .deltas            per-field auto − ref (NaN where either side has NaN)
%       .abs_max_delta_mm
%       .runtime_s

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        cohort_root (1,:) char
        ref_dir     (1,:) char
        opts        (1,1) struct = struct()
    end
    if ~isfield(opts, 'out_dir')
        opts.out_dir = fullfile('results', 'logs', ...
            sprintf('benchmark_%s', datestr(now, 'yyyymmdd_HHMMSS'))); %#ok<DATST,TNOW1>
    end
    if ~isfield(opts, 'planner_opts');     opts.planner_opts = struct(); end
    if ~isfield(opts, 'skip_missing_ref'); opts.skip_missing_ref = true; end
    if ~exist(opts.out_dir, 'dir'); mkdir(opts.out_dir); end

    cases = list_cases(cohort_root);
    if isempty(cases)
        warning('run_benchmark:NoCases', 'No cases found in %s', cohort_root);
        results = [];
        return;
    end

    sch = reference.schema();
    results = repmat(empty_result(sch), 1, numel(cases));
    for k = 1:numel(cases)
        c = cases(k);
        results(k).case_name = c.name;
        ref_path = fullfile(ref_dir, [c.name '.ref.json']);
        if ~isfile(ref_path)
            if opts.skip_missing_ref
                results(k).status = 'no_reference';
                fprintf('[%d/%d] %s: SKIP (no reference)\n', k, numel(cases), c.name);
                continue;
            else
                results(k).status = 'no_reference';
            end
        else
            try
                results(k).ref = reference.load(ref_path);
                results(k).ref_loaded = true;
            catch ME
                fprintf('[%d/%d] %s: reference load failed: %s\n', ...
                    k, numel(cases), c.name, ME.message);
                results(k).status = 'no_reference';
                continue;
            end
        end

        % Run the planner
        t0 = tic;
        try
            po = opts.planner_opts;
            po.out_dir = fullfile(opts.out_dir, c.name);
            out = run_planner_headless(c.dir, po);
            results(k).auto = derive_auto_measurements(out);
            results(k).status = 'ok';
        catch ME
            fprintf('[%d/%d] %s: planner failed: %s\n', ...
                k, numel(cases), c.name, ME.message);
            results(k).status = 'planner_failed';
            results(k).runtime_s = toc(t0);
            continue;
        end
        results(k).runtime_s = toc(t0);

        if strcmp(results(k).status, 'ok') && results(k).ref_loaded
            results(k).deltas = compute_deltas( ...
                results(k).auto, results(k).ref.measurements, sch);
            results(k).abs_max_delta_mm = ...
                max(abs(struct2array(results(k).deltas)), [], 'omitnan');
            fprintf('[%d/%d] %s: OK  max|Δ| = %.1f mm\n', ...
                k, numel(cases), c.name, results(k).abs_max_delta_mm);
        end
    end

    csv_path = fullfile(opts.out_dir, 'benchmark.csv');
    write_csv(results, sch, csv_path);
    print_summary(results, sch);
    fprintf('\nDelta CSV: %s\n', csv_path);
end

function cases = list_cases(root)
    cases = struct('name', {}, 'dir', {});
    d = dir(root);
    d = d([d.isdir] & ~startsWith({d.name}, '.'));
    for k = 1:numel(d)
        case_dir = fullfile(d(k).folder, d(k).name);
        dcm = find_dicom_subdir(case_dir);
        if isempty(dcm); continue; end
        cases(end+1) = struct('name', d(k).name, 'dir', dcm); %#ok<AGROW>
    end
end

function dcm = find_dicom_subdir(root)
    dcm = '';
    f = dir(fullfile(root, '*.dcm'));
    if numel(f) >= 10; dcm = root; return; end
    sub = dir(root);
    sub = sub([sub.isdir] & ~startsWith({sub.name}, '.'));
    for k = 1:numel(sub)
        p = fullfile(sub(k).folder, sub(k).name);
        d = find_dicom_subdir(p);
        if ~isempty(d); dcm = d; return; end
    end
end

function s = empty_result(sch)
    s = struct( ...
        'case_name', '', 'status', 'pending', ...
        'ref_loaded', false, 'auto', empty_meas(sch), 'ref', struct(), ...
        'deltas', empty_meas(sch), 'abs_max_delta_mm', NaN, 'runtime_s', NaN);
end

function m = empty_meas(sch)
    m = struct();
    for k = 1:numel(sch.measurement_fields)
        m.(sch.measurement_fields{k}) = NaN;
    end
end

function m = derive_auto_measurements(out)
    % run_planner_headless emits out.plan via evar_plan.generate_plan; the
    % per-measurement fields live under out.plan.measurements with the
    % same schema names the reference JSON uses, so most fields map 1:1.
    sch = reference.schema();
    m = empty_meas_from_schema(sch);
    if ~(isfield(out, 'plan') && isstruct(out.plan) && ...
            isfield(out.plan, 'measurements'))
        return;
    end
    src = out.plan.measurements;
    for k = 1:numel(sch.measurement_fields)
        f = sch.measurement_fields{k};
        if isfield(src, f) && ~isempty(src.(f)) && isnumeric(src.(f))
            m.(f) = src.(f);
        end
    end
    % evar_plan.measure_from_centerline uses `max_aneurysm_R_mm` for the
    % aneurysm radius. Convert R → diameter for the reference schema.
    if isnan(m.aneurysm_max_diameter_mm) && isfield(src, 'max_aneurysm_R_mm') && ...
            ~isempty(src.max_aneurysm_R_mm) && isnumeric(src.max_aneurysm_R_mm)
        m.aneurysm_max_diameter_mm = 2 * src.max_aneurysm_R_mm;
    end
end

function v = field_or_nan(s, f)
    if isfield(s, f) && ~isempty(s.(f)); v = s.(f); else; v = NaN; end
end

function m = empty_meas_from_schema(sch)
    m = struct();
    for k = 1:numel(sch.measurement_fields)
        m.(sch.measurement_fields{k}) = NaN;
    end
end

function d = compute_deltas(auto, ref, sch)
    d = struct();
    for k = 1:numel(sch.measurement_fields)
        f = sch.measurement_fields{k};
        a = field_or_nan(auto, f);
        r = field_or_nan(ref,  f);
        if isnan(a) || isnan(r)
            d.(f) = NaN;
        else
            d.(f) = a - r;
        end
    end
end

function write_csv(results, sch, path)
    fid = fopen(path, 'w');
    if fid < 0
        warning('run_benchmark:WriteCSV', 'Cannot open %s', path); return;
    end
    cleanup = onCleanup(@() fclose(fid));
    header = ['case_name,status,runtime_s,abs_max_delta_mm'];
    for k = 1:numel(sch.measurement_fields)
        header = [header sprintf(',%s_auto,%s_ref,%s_delta', ...
            sch.measurement_fields{k}, sch.measurement_fields{k}, ...
            sch.measurement_fields{k})];
    end
    fprintf(fid, '%s\n', header);
    for k = 1:numel(results)
        r = results(k);
        line = sprintf('%s,%s,%.1f,%s', ...
            r.case_name, r.status, r.runtime_s, num2str_safe(r.abs_max_delta_mm));
        for j = 1:numel(sch.measurement_fields)
            f = sch.measurement_fields{j};
            a = field_or_nan(r.auto, f);
            ref = NaN;
            if isfield(r.ref, 'measurements')
                ref = field_or_nan(r.ref.measurements, f);
            end
            de = field_or_nan(r.deltas, f);
            line = [line sprintf(',%s,%s,%s', ...
                num2str_safe(a), num2str_safe(ref), num2str_safe(de))]; %#ok<AGROW>
        end
        fprintf(fid, '%s\n', line);
    end
end

function s = num2str_safe(v)
    if isempty(v) || (isnumeric(v) && isnan(v)); s = '';
    elseif islogical(v); s = num2str(double(v));
    else; s = num2str(v);
    end
end

function print_summary(results, sch)
    fprintf('\n========= benchmark summary =========\n');
    fprintf('  Cases attempted:      %d\n', numel(results));
    n_ok = nnz(strcmp({results.status}, 'ok'));
    fprintf('  Planner OK:           %d\n', n_ok);
    fprintf('  Planner failed:       %d\n', nnz(strcmp({results.status}, 'planner_failed')));
    fprintf('  No reference:         %d\n', nnz(strcmp({results.status}, 'no_reference')));
    if n_ok == 0; return; end
    % Per-measurement mean abs delta
    fprintf('\n  Mean |Δ| per measurement (cases with both auto + ref):\n');
    for k = 1:numel(sch.measurement_fields)
        f = sch.measurement_fields{k};
        deltas = arrayfun(@(r) field_or_nan(r.deltas, f), results);
        deltas = deltas(~isnan(deltas));
        if isempty(deltas)
            fprintf('    %-42s n=0\n', f);
        else
            fprintf('    %-42s n=%d  mean|Δ|=%.2f  max|Δ|=%.2f\n', f, ...
                numel(deltas), mean(abs(deltas)), max(abs(deltas)));
        end
    end
end
