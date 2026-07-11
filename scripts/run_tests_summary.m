function run_tests_summary(varargin)
%RUN_TESTS_SUMMARY  Run the regression suite and write a compact per-test
%   pass/fail summary (plus any failure diagnostics) to
%   results/logs/regression_summary.log. Keeps the console flood of
%   headless-graphics warnings out of the summary so results are legible.
%
%   run_tests_summary()                  run every tests/*.m file
%   run_tests_summary('exclude', {...})  skip the named test files
%                                        (basenames, no extension), e.g.
%                                        {'test_vmtk_centerline'} which is
%                                        display-dependent (VTK) and crashes
%                                        a -nodisplay -batch worker.
%
%   Runs ONE FILE AT A TIME and appends to the log after each file, so a
%   crash or hang on a single file leaves the prior results intact on disk
%   (runtests over a whole folder loses everything if one file segfaults).

    p = inputParser;
    p.addParameter('exclude', {}, @(c) iscellstr(c) || isstring(c));
    p.parse(varargin{:});
    exclude = cellstr(p.Results.exclude);

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj); cd(proj);

    logf = fullfile(proj, 'results', 'logs', 'regression_summary.log');
    if ~exist(fileparts(logf), 'dir'); mkdir(fileparts(logf)); end

    % Header (truncate the log to start fresh).
    fid = fopen(logf, 'w');
    fprintf(fid, '=== regression suite %s ===\n', char(datetime('now')));
    if ~isempty(exclude)
        fprintf(fid, '    (excluded: %s)\n', strjoin(exclude, ', '));
    end
    fclose(fid);

    files = dir(fullfile(proj, 'tests', 'test_*.m'));
    names = sort({files.name});

    n_pass = 0; n_fail = 0; n_incomplete = 0; n_total = 0;
    for fi = 1:numel(names)
        [~, base] = fileparts(names{fi});
        if any(strcmp(base, exclude))
            fid = fopen(logf, 'a');
            fprintf(fid, '  %-10s %-55s   (skipped by request)\n', 'EXCLUDED', base);
            fclose(fid);
            continue;
        end

        results = runtests(fullfile(proj, 'tests', names{fi}));

        fid = fopen(logf, 'a');   % append + flush per file -> crash-safe
        for k = 1:numel(results)
            r = results(k);
            if r.Passed
                tag = 'PASS'; n_pass = n_pass + 1;
            elseif r.Failed
                tag = 'FAIL'; n_fail = n_fail + 1;
            else
                tag = 'INCOMPLETE'; n_incomplete = n_incomplete + 1;
            end
            n_total = n_total + 1;
            fprintf(fid, '  %-10s %-55s %7.2fs\n', tag, r.Name, r.Duration);
        end
        fclose(fid);
    end

    fid = fopen(logf, 'a');
    fprintf(fid, '--- %d passed, %d failed, %d incomplete (of %d) ---\n', ...
        n_pass, n_fail, n_incomplete, n_total);
    fclose(fid);

    fprintf('\n=== %d passed, %d failed, %d incomplete (of %d) — see %s ===\n', ...
        n_pass, n_fail, n_incomplete, n_total, logf);
end
