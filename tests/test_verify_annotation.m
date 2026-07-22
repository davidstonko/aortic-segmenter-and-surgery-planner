classdef test_verify_annotation < matlab.unittest.TestCase
%TEST_VERIFY_ANNOTATION  Covers the annotation QC gate
%   (intake.verify_annotation) + the Slicer color-table generator
%   (intake.write_slicer_color_table). Builds a synthetic Set-A paint-ID
%   mask (a connected Y in the SOP paint scheme), translates it via
%   data/setA_class_map.json, and checks that the gate accepts a clean
%   mask and rejects the failure modes it exists to catch. Synthetic data
%   only.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    properties (Access = private)
        project_root
        tmp
        class_map
    end

    methods (TestClassSetup)
        function add_path(tc)
            tc.project_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(tc.project_root);
            tc.class_map = fullfile(tc.project_root, 'data', 'setA_class_map.json');
        end
    end

    methods (TestMethodSetup)
        function mk_tmp(tc)
            tc.tmp = tempname; mkdir(tc.tmp);
        end
    end

    methods (TestMethodTeardown)
        function rm_tmp(tc)
            if ~isempty(tc.tmp) && isfolder(tc.tmp); rmdir(tc.tmp, 's'); end
        end
    end

    methods (Test)

        function clean_mask_passes(tc)
            [f, sz] = tc.write_paint_mask(true);
            rep = intake.verify_annotation(f, struct('class_map', tc.class_map, ...
                'ct', sz, 'verbose', false));
            tc.verifyTrue(rep.ok, sprintf('errors: %s', strjoin(rep.errors, ' | ')));
            tc.verifyEmpty(rep.errors);
            % pipeline labels present: aorta 1, iliacs 2/3, CFAs 4/5, celiac 8, SMA 9
            got = sort([rep.labels.pipeline_label]);
            tc.verifyEqual(got, [1 2 3 4 5 8 9]);
            tc.verifyEqual(rep.grid_ok, true);
        end

        function missing_cfa_is_an_error(tc)
            % Drop the right CFA (paint id 25) -> no R seed.
            [f, ~] = tc.write_paint_mask(true, 25);
            rep = intake.verify_annotation(f, struct('class_map', tc.class_map, ...
                'verbose', false));
            tc.verifyFalse(rep.ok);
            tc.verifyTrue(any(contains(rep.errors, 'label 5')));
        end

        function grid_mismatch_is_an_error(tc)
            [f, sz] = tc.write_paint_mask(true);
            rep = intake.verify_annotation(f, struct('class_map', tc.class_map, ...
                'ct', sz + [0 0 5], 'verbose', false));   % wrong slice count
            tc.verifyFalse(rep.ok);
            tc.verifyTrue(any(contains(rep.errors, 'grid mismatch')));
        end

        function disconnected_cfa_is_an_error(tc)
            % A CFA leg that never touches the aorta -> continuity broken.
            [f, ~] = tc.write_paint_mask(false);
            rep = intake.verify_annotation(f, struct('class_map', tc.class_map, ...
                'verbose', false));
            tc.verifyFalse(rep.ok);
            tc.verifyTrue(any(contains(rep.errors, 'not connected')));
        end

        function untranslated_paint_mask_errors_without_class_map(tc)
            % Paint ids 24/25 are outside the pipeline scheme -> hint to
            % pass the class map.
            [f, ~] = tc.write_paint_mask(true);
            tc.verifyError(@() intake.verify_annotation(f, struct('verbose', false)), ...
                'intake:verify_annotation:UntranslatedLabels');
        end

        function color_table_covers_every_class(tc)
            out = fullfile(tc.tmp, 'colors.ctbl');
            intake.write_slicer_color_table(out, tc.class_map);
            tc.verifyTrue(isfile(out));
            lines = splitlines(strtrim(fileread(out)));
            body  = lines(~startsWith(lines, '#'));
            % background + 13 structures = 14 rows
            tc.verifyEqual(numel(body), 14);
            tc.verifyTrue(any(contains(body, 'abdominal_aorta_lumen')));
            tc.verifyTrue(any(startsWith(body, '24 left_common_femoral')));
        end

    end

    methods (Access = private)
        function [f, sz] = write_paint_mask(tc, connected, drop_id)
        % Connected Y in SOP PAINT ids: aorta(1) → celiac(4)/SMA(5) stubs →
        % L/R common iliac(8/9) → external iliac(10/11) → common femoral
        % (24/25). If connected=false, the femoral legs are detached from
        % the aorta (continuity failure). drop_id removes one paint label.
            if nargin < 3; drop_id = []; end
            sz  = [64 64 120];
            lab = zeros(sz, 'uint8');
            cx  = 32;
            for z = 1:72; lab(30:34, cx-2:cx+2, z) = 1; end   % aorta
            lab(31:33, cx+3:cx+9, 38:41) = 4;                 % celiac
            lab(31:33, cx+3:cx+8, 46:49) = 5;                 % SMA
            gap = 0; if ~connected; gap = 3; end              % detach the legs
            for z = (71 + gap):120
                t  = (z - 71) / (120 - 71);
                xr = round(cx - 2 - 8 * t);
                xl = round(cx + 2 + 8 * t);
                if z <= 82
                    rl = 9;  ll = 8;              % common iliac
                elseif z <= 100
                    rl = 11; ll = 10;             % external iliac
                else
                    rl = 25; ll = 24;             % common femoral
                end
                lab(30:33, xr-1:xr+1, z) = rl;
                lab(30:33, xl-1:xl+1, z) = ll;
            end
            if ~isempty(drop_id); lab(lab == drop_id) = 0; end
            f = fullfile(tc.tmp, 'segA.nii');
            niftiwrite(lab, f);
        end
    end
end
