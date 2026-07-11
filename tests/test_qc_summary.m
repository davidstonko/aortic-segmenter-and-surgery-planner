classdef test_qc_summary < matlab.unittest.TestCase
%TEST_QC_SUMMARY  Covers autoseg.qc_summary (the aggregate QC verdict) and
%   its surfacing in evar_plan.generate_plan — a degenerate result must be
%   emitted with an explicit "do not trust" banner instead of confident-
%   looking numbers (the honest-failure theme of GOALS #41).

    properties (Access = private)
        project_root
    end

    methods (TestClassSetup)
        function add_project_path(tc)
            tc.project_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(tc.project_root);
        end
    end

    methods (Test)

        function usable_when_no_flags_failed(tc)
            qc = struct('segmentation_incomplete', false, ...
                        'orientation_suspect', false, 'centerline_implausible', false);
            [usable, summary] = autoseg.qc_summary(qc);
            tc.verifyTrue(usable);
            tc.verifyTrue(contains(summary, 'QC OK'));
        end

        function unusable_when_centerline_implausible(tc)
            [usable, summary] = autoseg.qc_summary(struct('centerline_implausible', true));
            tc.verifyFalse(usable);
            tc.verifyTrue(contains(summary, 'QC FAILED'));
            tc.verifyTrue(contains(summary, 'centerline'));
        end

        function summary_lists_every_failed_check(tc)
            qc = struct('segmentation_incomplete', true, ...
                        'orientation_suspect', true, 'centerline_implausible', true);
            [usable, summary] = autoseg.qc_summary(qc);
            tc.verifyFalse(usable);
            tc.verifyTrue(contains(summary, 'segmentation'));
            tc.verifyTrue(contains(summary, 'orientation'));
            tc.verifyTrue(contains(summary, 'centerline'));
        end

        function missing_fields_are_treated_as_pass(tc)
            % A partial QC struct (only one flag present, and it is false)
            % must not error and must read as usable.
            [usable, ~] = autoseg.qc_summary(struct('centerline_implausible', false));
            tc.verifyTrue(usable);
        end

        function generate_plan_marks_unreliable_when_qc_fails(tc)
            pr = tc.aaa_phantom_pr();
            pr.qc = struct('centerline_implausible', true, ...
                           'segmentation_incomplete', false, 'orientation_suspect', false);
            [pr.qc.usable, pr.qc.summary] = autoseg.qc_summary(pr.qc);

            stem = tempname;
            plan = evar_plan.generate_plan(pr, struct('verbose', false, 'write_file', stem));
            c = onCleanup(@() tc.cleanup_files(stem));

            tc.verifyFalse(plan.qc_usable);
            tc.verifyTrue(contains(plan.rationale, 'QC FAILED'), ...
                'the rationale must carry a visible QC-failure banner');

            j = jsondecode(fileread([stem, '.json']));
            tc.verifyFalse(logical(j.qc_usable));
            tc.verifyTrue(contains(j.qc_summary, 'QC FAILED'));
        end

        function generate_plan_reliable_when_no_qc_attached(tc)
            % A bare centerline struct (no qc field) — the plan defaults to
            % usable and carries no failure banner.
            pr = tc.aaa_phantom_pr();
            plan = evar_plan.generate_plan(pr, struct('verbose', false, 'write_file', ''));
            tc.verifyTrue(plan.qc_usable);
            tc.verifyFalse(contains(plan.rationale, 'QC FAILED'));
        end

    end

    methods (Access = private)

        function pr = aaa_phantom_pr(tc)
            S = load(fullfile(tc.project_root, 'library', 'PHANTOM_aaa_male.mat'));
            arclen = @(P) sum(vecnorm(diff(P, 1, 1), 2, 2));
            pr = struct('Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                        'Pv_mm_left',  S.Pv_mm_left,  'R_mm_left',  S.R_mm_left, ...
                        'arc_R_mm', arclen(S.Pv_mm_right), 'arc_L_mm', arclen(S.Pv_mm_left));
        end

        function cleanup_files(~, stem)
            for ext = {'.txt', '.json'}
                p = [stem, ext{1}];
                if isfile(p); delete(p); end
            end
        end

    end
end
