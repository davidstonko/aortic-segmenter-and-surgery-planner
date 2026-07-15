classdef test_deidentify_intake < matlab.unittest.TestCase
%TEST_DEIDENTIFY_INTAKE  Covers the Phase-0 PHI intake pipeline
%   (intake.deidentify_intake / verify_deid / append_manifest). Builds a
%   synthetic multi-slice CT study carrying deliberate PHI, runs the
%   MATLAB-native `dicomanon` engine (no Python), and asserts:
%     * every PHI tag is gone from the output,
%     * none of the planted PHI strings survive anywhere,
%     * the source study is left untouched,
%     * the de-identified volume still loads as one series,
%     * the manifest gets a de-identified row and no PHI,
%     * the codename<->PHI key is never written,
%     * the guard rails reject real names / PHI-named manifest fields.
%   Synthetic DICOM only — no patient data is used.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    properties (Access = private)
        project_root
        tmp
        src_dir
        n_slices = 6
        % Planted PHI (fake) — must NOT survive de-identification.
        phi = struct('name', 'DOE^REALPATIENT', 'mrn', 'MRN00123', ...
                     'acc', 'ACC98765', 'inst', 'SECRET HOSPITAL', ...
                     'ref', 'REFDOC^SMITH', 'dob', '19500101', ...
                     'serial', 'DEV-SERIAL-42')
    end

    methods (TestClassSetup)
        function add_path(tc)
            tc.project_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(tc.project_root);
        end
    end

    methods (TestMethodSetup)
        function make_study(tc)
            tc.tmp = tempname; mkdir(tc.tmp);
            tc.src_dir = fullfile(tc.tmp, 'raw_study');
            mkdir(tc.src_dir);

            % 'copy' mode derives the IOD from SOPClassUID but warns the
            % param is redundant — cosmetic, silence it for clean logs.
            ws = warning('off', 'all'); cw = onCleanup(@() warning(ws));

            series_uid = dicomuid();
            study_uid  = dicomuid();
            for_uid    = dicomuid();
            for s = 1:tc.n_slices
                img = int16(zeros(32, 32));
                img(8:24, 8:24) = int16(200 + 10 * s);   % a "vessel" blob
                meta = struct();
                meta.PatientName            = tc.phi.name;
                meta.PatientID              = tc.phi.mrn;
                meta.AccessionNumber        = tc.phi.acc;
                meta.InstitutionName        = tc.phi.inst;
                meta.ReferringPhysicianName = tc.phi.ref;
                meta.PatientBirthDate       = tc.phi.dob;
                meta.DeviceSerialNumber     = tc.phi.serial;
                meta.StudyDate              = '20240115';
                meta.Modality               = 'CT';
                meta.Manufacturer           = 'ACME';
                meta.ManufacturerModelName  = 'ScanMax 3000';
                meta.SeriesDescription      = 'CTA ABD RUNOFF';
                meta.SOPClassUID            = '1.2.840.10008.5.1.4.1.1.2'; % CT Image Storage
                meta.SOPInstanceUID         = dicomuid();
                meta.StudyInstanceUID       = study_uid;
                meta.SeriesInstanceUID      = series_uid;
                meta.FrameOfReferenceUID    = for_uid;
                meta.SliceThickness         = 1.25;
                meta.PixelSpacing           = [0.7; 0.7];
                meta.ImagePositionPatient   = [0; 0; (s - 1) * 1.25];
                meta.ImageOrientationPatient = [1;0;0;0;1;0];
                meta.SliceLocation          = (s - 1) * 1.25;
                meta.PatientPosition        = 'HFS';
                fn = fullfile(tc.src_dir, sprintf('slice_%02d.dcm', s));
                dicomwrite(img, fn, meta, 'CreateMode', 'copy');
            end
        end
    end

    methods (TestMethodTeardown)
        function cleanup(tc)
            if ~isempty(tc.tmp) && isfolder(tc.tmp); rmdir(tc.tmp, 's'); end
        end
    end

    methods (Test)

        function full_intake_is_clean_and_manifested(tc)
            out_root = fullfile(tc.tmp, 'store', 'JohnDoe9_deid');
            man      = fullfile(tc.tmp, 'store', 'cohort_manifest.csv');
            info = intake.deidentify_intake(tc.src_dir, 'JohnDoe9', struct( ...
                'out_root', out_root, 'manifest_path', man, ...
                'engine', 'dicomanon', 'pathology', 'AAA', ...
                'phase', 'pre-op', 'split', 'train', 'contrast_phase', 'arterial'));

            tc.verifyTrue(info.ok);
            tc.verifyTrue(info.verify.ok);
            tc.verifyEmpty(info.verify.residual);
            tc.verifyEqual(info.verify.n_files, tc.n_slices);

            % --- output headers carry no PHI --------------------------
            outFiles = dir(fullfile(out_root, '**', '*.dcm'));
            tc.verifyEqual(numel(outFiles), tc.n_slices);
            planted = struct2cell(tc.phi);
            for i = 1:numel(outFiles)
                h = dicominfo(fullfile(outFiles(i).folder, outFiles(i).name));
                blob = lower(jsonencode(h));
                for p = 1:numel(planted)
                    tc.verifyFalse(contains(blob, lower(planted{p})), ...
                        sprintf('planted PHI "%s" survived in output header', planted{p}));
                end
                tc.verifyFalse(isfield(h, 'AccessionNumber') && ~isempty(h.AccessionNumber));
                tc.verifyFalse(isfield(h, 'InstitutionName') && ~isempty(h.InstitutionName));
            end

            % --- de-identified volume still loads as one series -------
            D = preprocess.dicom_load(out_root, true);
            tc.verifyEqual(D.n_frames, tc.n_slices);
            tc.verifyEqual(D.pixel_mm, [0.7 0.7], 'AbsTol', 1e-6);

            % --- manifest: one de-identified row, no PHI --------------
            tc.verifyTrue(isfile(man));
            txt = fileread(man);
            lines = splitlines(strtrim(txt));
            tc.verifyEqual(numel(lines), 2);                 % header + 1 row
            tc.verifyTrue(contains(lines{1}, 'codename'));
            tc.verifyTrue(contains(lines{2}, 'JohnDoe9'));
            tc.verifyTrue(contains(lines{2}, 'AAA'));
            tc.verifyTrue(contains(lines{2}, 'pre-op'));
            for p = 1:numel(planted)
                tc.verifyFalse(contains(lower(txt), lower(planted{p})), ...
                    sprintf('planted PHI "%s" leaked into the manifest', planted{p}));
            end
        end

        function source_study_is_untouched(tc)
            out_root = fullfile(tc.tmp, 'store2', 'JohnDoe9_deid');
            intake.deidentify_intake(tc.src_dir, 'JohnDoe9', struct( ...
                'out_root', out_root, ...
                'manifest_path', fullfile(tc.tmp, 'store2', 'm.csv'), ...
                'engine', 'dicomanon'));
            h = dicominfo(fullfile(tc.src_dir, 'slice_01.dcm'));
            got = h.PatientName;
            if isstruct(got)
                got = strjoin(struct2cell(got), '^');   % Family^Given^...
            end
            tc.verifyTrue(contains(char(string(got)), 'REALPATIENT'), ...
                'source DICOM must be left untouched');
        end

        function manifest_appends_across_studies(tc)
            man = fullfile(tc.tmp, 'store3', 'cohort_manifest.csv');
            intake.deidentify_intake(tc.src_dir, 'JohnDoe1', struct( ...
                'out_root', fullfile(tc.tmp, 'store3', 'JohnDoe1_deid'), ...
                'manifest_path', man, 'engine', 'dicomanon'));
            intake.deidentify_intake(tc.src_dir, 'JohnDoe2', struct( ...
                'out_root', fullfile(tc.tmp, 'store3', 'JohnDoe2_deid'), ...
                'manifest_path', man, 'engine', 'dicomanon'));
            lines = splitlines(strtrim(fileread(man)));
            tc.verifyEqual(numel(lines), 3);                 % header + 2 rows
        end

        function bad_codename_is_rejected(tc)
            tc.verifyError(@() intake.deidentify_intake(tc.src_dir, 'RealName', ...
                struct('out_root', fullfile(tc.tmp, 'x'))), ...
                'intake:deidentify_intake:BadCodename');
        end

        function manifest_rejects_phi_field(tc)
            man = fullfile(tc.tmp, 'guard', 'm.csv');
            tc.verifyError(@() intake.append_manifest( ...
                struct('codename', 'JohnDoe9', 'PatientName', 'DOE^REAL'), man), ...
                'intake:append_manifest:PHIField');
            tc.verifyError(@() intake.append_manifest( ...
                struct('codename', 'NotACodename'), man), ...
                'intake:append_manifest:BadCodename');
        end

        function to_nifti_degrades_gracefully_without_dcm2niix(tc)
            % With dcm2niix pointed at a bogus path, the intake must still
            % succeed: de-id + verify + manifest are the deliverable; NIfTI
            % is a non-fatal extra (expected warning is suppressed).
            ws = warning('off', 'intake:deidentify_intake:NoDcm2niix');
            restore = onCleanup(@() warning(ws));
            man = fullfile(tc.tmp, 'store4', 'm.csv');
            info = intake.deidentify_intake(tc.src_dir, 'JohnDoe9', struct( ...
                'out_root', fullfile(tc.tmp, 'store4', 'JohnDoe9_deid'), ...
                'manifest_path', man, 'engine', 'dicomanon', ...
                'to_nifti', true, 'dcm2niix', '/nonexistent/dcm2niix'));
            tc.verifyTrue(info.ok);
            tc.verifyEmpty(info.nifti_paths);
            tc.verifyTrue(isfile(man));
        end

        function verify_flags_a_dirty_folder(tc)
            % Point verify at the RAW (un-scrubbed) study -> must fail.
            rep = intake.verify_deid(tc.src_dir, struct('codename', 'JohnDoe9'));
            tc.verifyFalse(rep.ok);
            tc.verifyNotEmpty(rep.residual);
        end

    end
end
