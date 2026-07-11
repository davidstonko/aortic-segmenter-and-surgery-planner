classdef test_reference < matlab.unittest.TestCase
%TEST_REFERENCE  Pin the reference-annotation schema + loader + template
%   utilities that goal #5 (TeraRecon benchmark) depends on. The actual
%   `run_benchmark.m` integration runs against synthetic CTs because the
%   real cohort isn't available yet; these tests are deliberately small.

    properties (Access = private)
        tmp_dir
    end

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
            addpath(fullfile(fileparts(here), 'scripts'));
        end
    end

    methods (TestMethodSetup)
        function make_tmp(tc)
            tc.tmp_dir = tempname();
            mkdir(tc.tmp_dir);
        end
    end

    methods (TestMethodTeardown)
        function clean_tmp(tc)
            if ~isempty(tc.tmp_dir) && exist(tc.tmp_dir, 'dir')
                rmdir(tc.tmp_dir, 's');
            end
        end
    end

    methods (Test)
        function schema_lists_known_fields(tc)
            sch = reference.schema();
            tc.verifyEqual(sch.schema_version, '1.0');
            tc.verifyTrue(any(strcmp(sch.measurement_fields, 'neck_diameter_mm')));
            tc.verifyTrue(any(strcmp(sch.measurement_fields, ...
                'distance_lowest_renal_to_bifurcation_mm')));
        end

        function template_writes_full_skeleton(tc)
            p = reference.template('TEST-CASE-1', tc.tmp_dir);
            tc.verifyTrue(isfile(p));
            ref = reference.load(p);
            tc.verifyEqual(ref.case_name, 'TEST-CASE-1');
            tc.verifyEqual(ref.schema_version, '1.0');
            sch = reference.schema();
            for k = 1:numel(sch.measurement_fields)
                tc.verifyTrue(isnan(ref.measurements.(sch.measurement_fields{k})), ...
                    sprintf('Template should leave %s as NaN', sch.measurement_fields{k}));
            end
        end

        function load_rejects_missing_file(tc)
            tc.verifyError(@() reference.load(fullfile(tc.tmp_dir, 'nope.json')), ...
                'reference:load:Missing');
        end

        function load_rejects_bad_version(tc)
            payload = struct('schema_version', '999.0', ...
                'case_name', 'X', 'reference_tool', 'Y', ...
                'annotator', 'Z', 'annotation_date', '2026-01-01', ...
                'measurements', struct());
            p = fullfile(tc.tmp_dir, 'bad.json');
            fid = fopen(p, 'w'); fprintf(fid, '%s', jsonencode(payload)); fclose(fid);
            tc.verifyError(@() reference.load(p), ...
                'reference:load:UnsupportedVersion');
        end

        function load_normalizes_missing_measurements_to_nan(tc)
            payload = struct('schema_version', '1.0', ...
                'case_name', 'PARTIAL', 'reference_tool', 'TeraRecon', ...
                'annotator', 'DPS', 'annotation_date', '2026-05-17', ...
                'measurements', struct('neck_diameter_mm', 22));
            p = fullfile(tc.tmp_dir, 'partial.json');
            fid = fopen(p, 'w'); fprintf(fid, '%s', jsonencode(payload)); fclose(fid);
            ref = reference.load(p);
            tc.verifyEqual(ref.measurements.neck_diameter_mm, 22);
            tc.verifyTrue(isnan(ref.measurements.neck_length_mm));
            tc.verifyTrue(isnan(ref.measurements.distance_lowest_renal_to_bifurcation_mm));
        end

        function benchmark_runner_handles_empty_cohort(tc)
            tmp_root = fullfile(tc.tmp_dir, 'cohort');
            tmp_ref  = fullfile(tc.tmp_dir, 'refs');
            mkdir(tmp_root); mkdir(tmp_ref);
            evalc('results = run_benchmark(tmp_root, tmp_ref);');
            tc.verifyTrue(true, 'run_benchmark returned without errors on empty cohort');
        end
    end
end
