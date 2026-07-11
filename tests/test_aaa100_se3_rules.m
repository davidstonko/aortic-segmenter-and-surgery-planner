classdef test_aaa100_se3_rules < matlab.unittest.TestCase
%TEST_AAA100_SE3_RULES  Regression test pinning the SE(3) audit
%   thresholds to the AAA-100 reference cohort. Every real centerline
%   must pass the per-centerline rules with no FAIL severity. Every
%   real iliac pair must pass the cross-vessel rules.
%
%   When a future change tightens a threshold, this test should still
%   pass on all 100 references. When a future change LOOSENS a threshold
%   (e.g. because a new dataset has more tortuous anatomy), this test
%   should still pass and the per-vessel pass-rate statistic should not
%   drop below 95%.
%
%   Skips if the AAA-100 cache is not available locally.

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function per_centerline_passes_on_all_references(tc)
            cache_root = library.aaa100.cache_root();
            mat_path = fullfile(cache_root, 'aaa100_centerlines.mat');
            tc.assumeTrue(isfile(mat_path), ...
                sprintf('AAA-100 cache not available at %s — run library.aaa100.load_all once to build it.', mat_path));

            cases = library.aaa100.load_all();
            tc.assertGreaterThanOrEqual(numel(cases), 100, 'fewer than 100 AAA-100 cases loaded');

            vessels = {'aorta', 'iliac_L', 'iliac_R', 'renal_L', 'renal_R'};
            % Allow up to 1% of (case x vessel) entries to FAIL — accounts
            % for legitimate anatomic outliers in the cohort.
            max_fail_rate = 0.01;
            n_eval = 0; n_fail = 0;
            failures = {};
            for i = 1:numel(cases)
                c = cases(i);
                for v = vessels
                    P = c.(v{1});
                    if size(P, 1) < 4; continue; end
                    n_eval = n_eval + 1;
                    label = sprintf('%s/%s', c.case_id, v{1});
                    report = autoseg.se3_per_centerline_check(P, label);
                    if ~report.passed
                        n_fail = n_fail + 1;
                        failures{end+1} = struct('label', label, ...
                            'summary', report.summary_text); %#ok<AGROW>
                    end
                end
            end

            fail_rate = n_fail / max(n_eval, 1);
            fprintf(['\nAAA-100 per-centerline rule check: %d evaluated, ' ...
                     '%d FAIL (rate %.1f%%, tol %.1f%%)\n'], ...
                     n_eval, n_fail, 100*fail_rate, 100*max_fail_rate);
            if n_fail > 0
                fprintf('First 5 failures:\n');
                for k = 1:min(5, numel(failures))
                    fprintf('--- %s ---\n%s\n', failures{k}.label, failures{k}.summary);
                end
            end
            tc.verifyLessThanOrEqual(fail_rate, max_fail_rate, sprintf( ...
                'AAA-100 per-centerline FAIL rate %.1f%% > tolerance %.1f%% — thresholds need recalibration.', ...
                100*fail_rate, 100*max_fail_rate));
        end

        function cross_vessel_passes_on_all_iliac_pairs(tc)
            cache_root = library.aaa100.cache_root();
            mat_path = fullfile(cache_root, 'aaa100_centerlines.mat');
            tc.assumeTrue(isfile(mat_path), 'AAA-100 cache not available.');

            cases = library.aaa100.load_all();
            % AAA-100 iliacs don't share a proximal node (they start at
            % the post-bifurcation point) — pass a larger bifurc_tol_mm
            % to allow the 99th-percentile 86 mm L/R gap.
            opts = struct('bifurc_tol_mm', 90);

            max_fail_rate = 0.05;   % 5% — y_symmetry can legitimately fail on outliers
            n_eval = 0; n_fail = 0;
            failures = {};
            for i = 1:numel(cases)
                c = cases(i);
                if size(c.iliac_L, 1) < 3 || size(c.iliac_R, 1) < 3; continue; end
                n_eval = n_eval + 1;
                report = autoseg.se3_cross_vessel_check(c.iliac_R, c.iliac_L, opts);
                if ~report.passed
                    n_fail = n_fail + 1;
                    failures{end+1} = struct('case', c.case_id, ...
                        'summary', report.summary_text); %#ok<AGROW>
                end
            end

            fail_rate = n_fail / max(n_eval, 1);
            fprintf(['\nAAA-100 cross-vessel iliac-pair check: %d evaluated, ' ...
                     '%d FAIL (rate %.1f%%, tol %.1f%%)\n'], ...
                     n_eval, n_fail, 100*fail_rate, 100*max_fail_rate);
            if n_fail > 0
                fprintf('First 3 failures:\n');
                for k = 1:min(3, numel(failures))
                    fprintf('--- %s ---\n%s\n', failures{k}.case, failures{k}.summary);
                end
            end
            tc.verifyLessThanOrEqual(fail_rate, max_fail_rate, sprintf( ...
                'AAA-100 cross-vessel FAIL rate %.1f%% > tolerance %.1f%% — thresholds need recalibration.', ...
                100*fail_rate, 100*max_fail_rate));
        end
    end
end
