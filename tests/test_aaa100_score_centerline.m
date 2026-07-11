classdef test_aaa100_score_centerline < matlab.unittest.TestCase
%TEST_AAA100_SCORE_CENTERLINE  Pin the patient-vs-population scorer.
%   The scorer takes a single centerline and a vessel type, returns
%   the population percentile of arc length / tortuosity / κ_max /
%   |τ|_max / shape deviation in the AAA-100 cohort, and flags
%   outliers (any metric outside p5-p95).
%
%   Skips when the AAA-100 cache is not available locally.

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function median_case_is_not_an_outlier(tc)
            cache_root = library.aaa100.cache_root();
            mat_path = fullfile(cache_root, 'aaa100_centerlines.mat');
            tc.assumeTrue(isfile(mat_path), 'AAA-100 cache not available.');
            cal_path = fullfile(cache_root, 'aaa100_se3_calibration.mat');
            tc.assumeTrue(isfile(cal_path), 'AAA-100 SE(3) calibration not available.');

            cal = load(cal_path);
            [~, kmid] = min(abs(cal.per_vessel.aorta.tortuosity - median(cal.per_vessel.aorta.tortuosity)));
            ids = library.aaa100.list_cases();
            c = library.aaa100.load_case(ids{kmid});
            score = library.aaa100.score_centerline(c.aorta, 'aorta', struct('verbose', false));
            tc.verifyEqual(score.outlier, false, sprintf( ...
                'Median-tortuosity case %s should not be flagged as outlier (percentiles arc=%.0f tort=%.0f κ=%.0f τ=%.0f shape=%.0f)', ...
                ids{kmid}, score.arc_pct, score.tortuosity_pct, score.kappa_max_pct, ...
                score.tau_max_pct, score.shape_deviation_pct));
        end

        function most_tortuous_case_is_an_outlier(tc)
            cache_root = library.aaa100.cache_root();
            mat_path = fullfile(cache_root, 'aaa100_centerlines.mat');
            cal_path = fullfile(cache_root, 'aaa100_se3_calibration.mat');
            tc.assumeTrue(isfile(mat_path), 'AAA-100 cache not available.');
            tc.assumeTrue(isfile(cal_path), 'AAA-100 SE(3) calibration not available.');

            cal = load(cal_path);
            [~, kmax] = max(cal.per_vessel.aorta.tortuosity);
            ids = library.aaa100.list_cases();
            c = library.aaa100.load_case(ids{kmax});
            score = library.aaa100.score_centerline(c.aorta, 'aorta', struct('verbose', false));
            tc.verifyTrue(score.outlier, sprintf( ...
                'Most-tortuous case %s should be flagged as outlier', ids{kmax}));
            tc.verifyGreaterThanOrEqual(score.tortuosity_pct, 95, ...
                'Most-tortuous case should be in top 5% by tortuosity');
        end

        function short_centerline_returns_diagnostic_not_error(tc)
            P = [0 0 0; 1 1 1; 2 2 2];   % only 3 nodes
            score = library.aaa100.score_centerline(P, 'iliac_L', struct('verbose', false));
            tc.verifyTrue(contains(score.note, 'cannot score'), ...
                'Short centerline should set diagnostic note.');
            tc.verifyEqual(score.outlier, false, 'Cannot-score should default to outlier=false.');
        end
    end
end
