classdef test_aortaseg24_loader < matlab.unittest.TestCase
%TEST_AORTASEG24_LOADER  Covers library.aortaseg24.load_case / list_cases,
%   the ingest for public AortaSeg CT+segmentation cases. Uses synthetic
%   NIfTI (no dataset needed) so it runs in CI. Verifies the raw class ids
%   translate to the pipeline label scheme, the arterial mask is built, and
%   CT/label pairs are discovered.

    properties (Access = private)
        project_root
        tmp
    end

    methods (TestClassSetup)
        function add_project_path(tc)
            tc.project_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(tc.project_root);
        end
    end

    methods (TestMethodSetup)
        function make_synthetic_case(tc)
            tc.tmp = fullfile(tempname); mkdir(tc.tmp);
            sz = [24 24 40];
            vol = zeros(sz, 'int16'); lab = zeros(sz, 'uint8');
            % aorta (raw 19 -> pipeline 1), L/R common iliac (raw 8/9 -> 2/3),
            % celiac (raw 4 -> 8) — a branch that must NOT enter the arterial mask.
            vol(10:14, 10:14, 4:24) = 300; lab(10:14, 10:14, 4:24) = 19;
            vol(10:14, 6:9,  24:38) = 300; lab(10:14, 6:9,  24:38) = 8;
            vol(10:14, 15:18, 24:38) = 300; lab(10:14, 15:18, 24:38) = 9;
            vol(15:16, 11:13, 8:10)  = 300; lab(15:16, 11:13, 8:10)  = 4;
            niftiwrite(vol, fullfile(tc.tmp, 'caseA'));       % caseA.nii
            niftiwrite(lab, fullfile(tc.tmp, 'caseA_seg'));   % caseA_seg.nii
        end
    end

    methods (TestMethodTeardown)
        function cleanup(tc)
            if ~isempty(tc.tmp) && isfolder(tc.tmp); rmdir(tc.tmp, 's'); end
        end
    end

    methods (Test)

        function load_case_translates_and_builds_D(tc)
            C = library.aortaseg24.load_case( ...
                fullfile(tc.tmp, 'caseA.nii'), fullfile(tc.tmp, 'caseA_seg.nii'));

            % D-struct is dicom_load-shaped
            tc.verifyEqual(size(C.D.vol), [24 24 40]);
            tc.verifyEqual(numel(C.D.pixel_mm), 2);
            tc.verifyTrue(C.D.is_volume);
            tc.verifyEqual(numel(C.D.slice_z_mm), 40);

            % raw ids 19/8/9/4 -> pipeline 1/2/3/8
            present = double(unique(C.label_branch(C.label_branch > 0)).');
            tc.verifyEqual(sort(present), [1 2 3 8]);

            % arterial mask = aorta + iliacs; celiac (8) excluded by default
            tc.verifyEqual(nnz(C.mask), nnz(ismember(C.label_branch, [1 2 3])));
            tc.verifyEqual(nnz(C.mask & C.label_branch == 8), 0);
            tc.verifyGreaterThan(nnz(C.label_branch == 1), 0);  % aorta present
        end

        function arterial_labels_option_is_respected(tc)
            % Include the celiac (pipeline 8) in the mask on request.
            C = library.aortaseg24.load_case( ...
                fullfile(tc.tmp, 'caseA.nii'), fullfile(tc.tmp, 'caseA_seg.nii'), ...
                struct('arterial_labels', [1 2 3 8]));
            tc.verifyGreaterThan(nnz(C.mask & C.label_branch == 8), 0);
        end

        function list_cases_pairs_ct_and_label(tc)
            cases = library.aortaseg24.list_cases(tc.tmp);
            tc.verifyEqual(numel(cases), 1);
            tc.verifyTrue(isfile(cases(1).ct_path));
            tc.verifyTrue(isfile(cases(1).label_path));
            tc.verifyTrue(contains(lower(cases(1).label_path), 'seg'));
            tc.verifyFalse(contains(lower(cases(1).ct_path), 'seg'));
        end

        function missing_files_error_clearly(tc)
            tc.verifyError(@() library.aortaseg24.load_case('/no/ct.nii', '/no/seg.nii'), ...
                'library:aortaseg24:load_case:NoCT');
        end

    end
end
