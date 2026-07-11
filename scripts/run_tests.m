function rc = run_tests()
%RUN_TESTS  Run every test under <project>/tests/. Returns 0 if all
%   tests pass, 1 otherwise. Suitable for CI smoke runs and local
%   regression checks before pushing changes.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);
    cd(proj);

    fprintf('=== Running regression suite (%s) ===\n', proj);
    results = runtests(fullfile(proj, 'tests'));
    summary = table(results);
    disp(summary);
    n_pass = sum([results.Passed]);
    n_fail = sum([results.Failed]);
    fprintf('\nPassed: %d / %d\n', n_pass, n_pass + n_fail);

    rc = double(n_fail > 0);
    if nargout == 0 && rc ~= 0
        error('run_tests:Failed', '%d test(s) failed', n_fail);
    end
end
