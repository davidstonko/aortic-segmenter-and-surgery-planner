function results = run_batch(input_root, opts)
%RUN_BATCH  Walk a directory tree of DICOM cases and run the headless EVAR
%   planner on each. Emits a per-case summary CSV that's convenient to
%   tabulate when comparing the planner against a reference cohort.
%
%   results = run_batch(INPUT_ROOT)
%   results = run_batch(INPUT_ROOT, OPTS)
%
%   INPUT_ROOT  directory containing one sub-directory per case. Each
%               case sub-directory either:
%                 - IS a single CT DICOM series (auto-detected), or
%                 - contains a sub-tree whose deepest directory holds the
%                   CT DICOM series.
%   OPTS:
%       .out_dir          where to write the summary CSV + per-case logs
%                         (default `results/logs/batch_<timestamp>/`)
%       .stop_on_error    abort the batch if any case fails (default false)
%       .planner_opts     struct passed to run_planner_headless
%       .case_pattern     regexp filter on the case dir name (default '.*')
%
%   Returns a struct array with one entry per case:
%       .case_name      sub-directory basename
%       .dicom_dir      resolved DICOM directory
%       .status         'ok' | 'failed' | 'skipped'
%       .audit_passed   logical (NaN if status ~= 'ok')
%       .neck_dia_mm
%       .neck_len_mm
%       .neck_ang_deg
%       .iliac_R_dia_mm
%       .iliac_L_dia_mm
%       .arc_R_mm
%       .arc_L_mm
%       .eligible_devices  cellstr of devices that passed IFU
%       .runtime_s
%       .error_message  on failure
%
%   The CSV mirrors these fields with one row per case. A summary table
%   is printed at the end.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        input_root (1,:) char
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'out_dir')
        opts.out_dir = fullfile('results', 'logs', ...
            sprintf('batch_%s', datestr(now, 'yyyymmdd_HHMMSS'))); %#ok<DATST,TNOW1>
    end
    if ~isfield(opts, 'stop_on_error'); opts.stop_on_error = false; end
    if ~isfield(opts, 'planner_opts');  opts.planner_opts = struct(); end
    if ~isfield(opts, 'case_pattern');  opts.case_pattern = '.*'; end
    if ~exist(opts.out_dir, 'dir'); mkdir(opts.out_dir); end

    cases = list_cases(input_root, opts.case_pattern);
    if isempty(cases)
        warning('run_batch:NoCases', 'No cases found under %s', input_root);
        results = [];
        return;
    end

    fprintf('=== run_batch ===\n');
    fprintf('Input root:  %s\n', input_root);
    fprintf('Output dir:  %s\n', opts.out_dir);
    fprintf('Cases found: %d\n', numel(cases));

    results = empty_result_struct(numel(cases));
    for k = 1:numel(cases)
        c = cases(k);
        fprintf('\n[%d/%d] %s\n', k, numel(cases), c.name);
        results(k).case_name = c.name;
        results(k).dicom_dir = c.dir;
        t0 = tic;
        case_log = fullfile(opts.out_dir, sprintf('%s.log', sanitize(c.name)));
        try
            planner_opts = opts.planner_opts;
            planner_opts.out_dir = fullfile(opts.out_dir, sanitize(c.name));
            diary(case_log); diary on;
            cleanup = onCleanup(@() diary('off'));
            out = run_planner_headless(c.dir, planner_opts);
            clear cleanup;
            results(k) = populate_from_output(results(k), out);
            results(k).status = 'ok';
        catch ME
            try; diary off; catch; end %#ok<*TRYNC>
            results(k).status = 'failed';
            results(k).error_message = ME.message;
            fprintf('  FAILED: %s\n', ME.message);
            if opts.stop_on_error; rethrow(ME); end
        end
        results(k).runtime_s = toc(t0);
    end

    csv_path = fullfile(opts.out_dir, 'summary.csv');
    write_summary_csv(results, csv_path);
    print_summary(results);
    fprintf('\nSummary CSV: %s\n', csv_path);
end

function cases = list_cases(root, pattern)
    cases = struct('name', {}, 'dir', {});
    d = dir(root);
    d = d([d.isdir] & ~startsWith({d.name}, '.'));
    for k = 1:numel(d)
        if isempty(regexp(d(k).name, pattern, 'once')); continue; end
        case_dir = fullfile(d(k).folder, d(k).name);
        dcm = find_dicom_subdir(case_dir);
        if isempty(dcm); continue; end
        cases(end+1) = struct('name', d(k).name, 'dir', dcm); %#ok<AGROW>
    end
end

function dcm = find_dicom_subdir(root)
    dcm = '';
    if has_dicom_files(root); dcm = root; return; end
    sub = dir(root);
    sub = sub([sub.isdir] & ~startsWith({sub.name}, '.'));
    for k = 1:numel(sub)
        p = fullfile(sub(k).folder, sub(k).name);
        d = find_dicom_subdir(p);
        if ~isempty(d); dcm = d; return; end
    end
end

function tf = has_dicom_files(d)
    f = dir(fullfile(d, '*.dcm'));
    tf = numel(f) >= 10;
end

function s = empty_result_struct(n)
    s = repmat(struct( ...
        'case_name', '', 'dicom_dir', '', 'status', 'pending', ...
        'audit_passed', NaN, 'qc_usable', NaN, ...
        'neck_dia_mm', NaN, 'neck_len_mm', NaN, 'neck_ang_deg', NaN, ...
        'iliac_R_dia_mm', NaN, 'iliac_L_dia_mm', NaN, ...
        'arc_R_mm', NaN, 'arc_L_mm', NaN, ...
        'eligible_devices', {{}}, 'runtime_s', NaN, ...
        'error_message', ''), 1, n);
end

function r = populate_from_output(r, out)
    % Derive the summary scalars via the shared, unit-tested mapping
    % (reads out.plan.measurements.* — a bare out.plan.neck_dia_mm does not
    % exist, which is why this column used to be NaN for every case).
    row = evar_plan.batch_summary_row(out);
    r.audit_passed    = row.audit_passed;
    r.qc_usable       = row.qc_usable;
    r.neck_dia_mm     = row.neck_dia_mm;
    r.neck_len_mm     = row.neck_len_mm;
    r.neck_ang_deg    = row.neck_ang_deg;
    r.iliac_R_dia_mm  = row.iliac_R_dia_mm;
    r.iliac_L_dia_mm  = row.iliac_L_dia_mm;
    r.arc_R_mm        = row.arc_R_mm;
    r.arc_L_mm        = row.arc_L_mm;
    r.eligible_devices = row.eligible_devices;
end

function s = sanitize(s)
    s = regexprep(s, '[^A-Za-z0-9._-]', '_');
end

function write_summary_csv(results, path)
    fid = fopen(path, 'w');
    if fid < 0
        warning('run_batch:WriteCSV', 'Cannot open %s for writing.', path);
        return;
    end
    cleanup = onCleanup(@() fclose(fid));
    fprintf(fid, ['case_name,status,audit_passed,qc_usable,runtime_s,', ...
                  'neck_dia_mm,neck_len_mm,neck_ang_deg,', ...
                  'iliac_R_dia_mm,iliac_L_dia_mm,arc_R_mm,arc_L_mm,', ...
                  'eligible_devices,error_message\n']);
    for k = 1:numel(results)
        r = results(k);
        elig = strjoin(r.eligible_devices, '|');
        err  = strrep(r.error_message, ',', ';');
        fprintf(fid, '%s,%s,%s,%s,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.0f,%.0f,%s,%s\n', ...
            r.case_name, r.status, num2str_safe(r.audit_passed), ...
            num2str_safe(r.qc_usable), ...
            r.runtime_s, r.neck_dia_mm, r.neck_len_mm, r.neck_ang_deg, ...
            r.iliac_R_dia_mm, r.iliac_L_dia_mm, r.arc_R_mm, r.arc_L_mm, ...
            elig, err);
    end
end

function s = num2str_safe(v)
    if islogical(v); s = num2str(double(v));
    elseif isnan(v); s = '';
    else;            s = num2str(v);
    end
end

function print_summary(results)
    n_ok      = nnz(strcmp({results.status}, 'ok'));
    n_failed  = nnz(strcmp({results.status}, 'failed'));
    n_passed  = nnz(arrayfun(@(r) isequal(r.audit_passed, true), results));
    n_total_t = sum(arrayfun(@(r) max(r.runtime_s, 0), results));
    fprintf('\n========= run_batch summary =========\n');
    fprintf('  Cases attempted: %d\n', numel(results));
    fprintf('  Status OK:       %d\n', n_ok);
    fprintf('  Status FAILED:   %d\n', n_failed);
    fprintf('  Audit passed:    %d / %d\n', n_passed, n_ok);
    fprintf('  Total runtime:   %.1fs\n', n_total_t);
end
