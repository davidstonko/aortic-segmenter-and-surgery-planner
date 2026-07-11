classdef test_batch_summary_row < matlab.unittest.TestCase
%TEST_BATCH_SUMMARY_ROW  Covers evar_plan.batch_summary_row, the shared
%   run_batch cohort-CSV mapping. Pins the fix for the silent-NaN bug (the
%   old batch read out.plan.neck_dia_mm, which never exists — sizing lives
%   under out.plan.measurements.*) and the new qc_usable column.

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

        function maps_plan_measurements_not_nan(tc)
            out = tc.phantom_output(true);
            row = evar_plan.batch_summary_row(out);

            % The whole point: sizing columns are populated, not NaN.
            tc.verifyFalse(isnan(row.neck_dia_mm));
            tc.verifyEqual(row.neck_dia_mm, out.plan.measurements.neck_diameter_mm, 'AbsTol', 1e-9);
            tc.verifyEqual(row.iliac_R_dia_mm, out.plan.measurements.iliac_R_diameter_mm, 'AbsTol', 1e-9);
            tc.verifyGreaterThan(row.arc_R_mm, 0);
            tc.verifyGreaterThan(row.arc_L_mm, 0);
            tc.verifyNotEmpty(row.eligible_devices);
        end

        function carries_qc_usable_from_out_qc(tc)
            out = tc.phantom_output(false);   % qc marked NOT usable
            row = evar_plan.batch_summary_row(out);
            tc.verifyFalse(logical(row.qc_usable));
        end

        function falls_back_to_plan_qc_usable(tc)
            out = tc.phantom_output(true);
            out = rmfield(out, 'qc');          % no out.qc — only plan.qc_usable
            out.plan.qc_usable = false;
            row = evar_plan.batch_summary_row(out);
            tc.verifyFalse(logical(row.qc_usable));
        end

        function empty_output_leaves_nans(tc)
            row = evar_plan.batch_summary_row(struct());
            tc.verifyTrue(isnan(row.neck_dia_mm));
            tc.verifyTrue(isnan(row.qc_usable));
            tc.verifyTrue(isnan(row.arc_R_mm));
            tc.verifyEmpty(row.eligible_devices);
        end

    end

    methods (Access = private)

        function out = phantom_output(tc, qc_usable)
            S = load(fullfile(tc.project_root, 'library', 'PHANTOM_aaa_male.mat'));
            arclen = @(P) sum(vecnorm(diff(P, 1, 1), 2, 2));
            out = struct('Pv_mm_right', S.Pv_mm_right, 'R_mm_right', S.R_mm_right, ...
                         'Pv_mm_left',  S.Pv_mm_left,  'R_mm_left',  S.R_mm_left, ...
                         'arc_R_mm', arclen(S.Pv_mm_right), 'arc_L_mm', arclen(S.Pv_mm_left));
            out.qc = struct('centerline_implausible', ~qc_usable, ...
                            'segmentation_incomplete', false, 'orientation_suspect', false);
            [out.qc.usable, out.qc.summary] = autoseg.qc_summary(out.qc);
            out.plan = evar_plan.generate_plan(out, struct('verbose', false, 'write_file', ''));
        end

    end
end
