classdef test_seg_backend < matlab.unittest.TestCase
%TEST_SEG_BACKEND  Covers the segmentation-backend selector
%   (autoseg.resolve_seg_backend) and its wiring into
%   run_planner_headless: the 'external' backend that runs the full
%   planner on a caller-supplied pipeline-scheme label NIfTI (a
%   hand-annotated Set-A mask or a learned nnU-Net output), and the
%   'learned' backend's clean failure without weights.
%
%   The end-to-end external test builds a synthetic connected Y-shaped
%   vessel LABEL volume (aorta + celiac/SMA + iliacs + CFAs in the
%   pipeline scheme), writes it as NIfTI, and runs the planner through
%   segmentation → seeds (skip_centerline) — proving the learned/manual
%   mask flows into the same downstream path with TS bypassed. Synthetic
%   data only; no TotalSegmentator, no patient data.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    properties (Access = private)
        project_root
        tmp
    end

    methods (TestClassSetup)
        function add_path(tc)
            tc.project_root = fileparts(fileparts(mfilename('fullpath')));
            addpath(tc.project_root);
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

        % ---- resolver ----------------------------------------------------

        function resolver_maps_names_and_aliases(tc)
            tc.verifyEqual(autoseg.resolve_seg_backend('totalsegmentator'), 'totalsegmentator');
            tc.verifyEqual(autoseg.resolve_seg_backend('ts'), 'totalsegmentator');
            tc.verifyEqual(autoseg.resolve_seg_backend('learned'), 'learned');
            tc.verifyEqual(autoseg.resolve_seg_backend('aortaseg24'), 'learned');
            tc.verifyEqual(autoseg.resolve_seg_backend('external'), 'external');
            tc.verifyEqual(autoseg.resolve_seg_backend('MASK'), 'external');
        end

        function resolver_auto_falls_back_to_ts_without_weights(tc)
            % No AortaSeg24 checkpoint on the test machine → auto = TS.
            [backend, info] = autoseg.resolve_seg_backend('auto');
            tc.verifyEqual(backend, 'totalsegmentator');
            tc.verifyFalse(info.learned_available);
            tc.verifyNotEmpty(info.learned_reason);
        end

        function resolver_rejects_unknown(tc)
            tc.verifyError(@() autoseg.resolve_seg_backend('bogus'), ...
                'autoseg:resolve_seg_backend:BadBackend');
        end

        % ---- run_planner_headless wiring ---------------------------------

        function external_requires_a_label_nifti(tc)
            tc.verifyError(@() run_planner_headless("", struct('seg_backend', 'external')), ...
                'run_planner_headless:NoExternalSeg');
        end

        function learned_without_weights_surfaces_clean_error(tc)
            % No checkpoint → aortaseg24.run refuses to fabricate a mask.
            D = tc.make_labeled_case();
            f = @() run_planner_headless("", struct('D', D.D, ...
                'seg_backend', 'learned', 'skip_centerline', true, ...
                'out_dir', fullfile(tc.tmp, 'lrn')));
            caught = '';
            try
                f();
            catch ME
                caught = ME.identifier;
            end
            tc.verifyTrue(startsWith(caught, 'autoseg:aortaseg24:'), ...
                sprintf('expected an autoseg:aortaseg24:* error, got "%s"', caught));
        end

        function external_backend_flows_through_pipeline(tc)
            C = tc.make_labeled_case();
            nifti = fullfile(tc.tmp, 'segA_pipeline.nii');
            niftiwrite(C.label, nifti);   % already in pipeline scheme

            out = run_planner_headless("", struct('D', C.D, ...
                'seg_backend', 'external', 'seg_label_nifti', nifti, ...
                'skip_centerline', true, 'verbose', false, ...
                'out_dir', fullfile(tc.tmp, 'ext')));

            tc.verifyEqual(out.seg_backend, 'external');
            % Mask adopted from the NIfTI (TS bypassed): every planned mask
            % voxel is a labeled voxel (keep-largest-CC may drop strays, so
            % subset, not equality).
            tc.verifyTrue(all(C.label(out.mask) > 0), ...
                'planned mask contains voxels absent from the external label');
            tc.verifyGreaterThan(nnz(out.mask), 0);
            % Seeds located from the pipeline-scheme labels (celiac + CFAs).
            tc.verifyTrue(out.seeds.ok, 'external-seg seeds not all located');
            tc.verifyTrue(isfield(out, 'label_branch') && any(out.label_branch(:) == 8));
        end

        function gui_dropdown_selects_and_reflects_backend(tc)
            % Step-2 "Source" dropdown: renders, defaults to TS, switching to
            % a source with no backend installed disables Run with an honest
            % message, and the TS ROI checkboxes follow the selection.
            tc.assumeTrue(usejava('desktop') || feature('ShowFigureWindows'), ...
                'GUI test requires a display');
            prev_home = char(java.lang.System.getProperty('user.home'));
            tmp_home  = tempname(); mkdir(tmp_home);
            java.lang.System.setProperty('user.home', tmp_home);
            a = app.AorticCenterlineApp();
            restore = onCleanup(@() cleanup_gui(a, prev_home, tmp_home));
            pause(0.4);

            sz = [60 60 120];
            D = struct('vol', int16(zeros(sz)), 'pixel_mm', [1 1], ...
                'slice_spacing_mm', 1.0, 'is_volume', true, ...
                'z_normalized', true, 'series_description', 'test', ...
                'slice_z_mm', (1:sz(3))');
            a.injectCT(D); pause(0.2);
            a.setStepPublic(2); pause(0.2);
            a.setStepModePublic(2, 'auto'); pause(0.4);

            dd = findobj(a.UIFigure, 'Tag', 'seg_backend_dd');
            st = findobj(a.UIFigure, 'Tag', 'ts_status');
            bt = findobj(a.UIFigure, 'Tag', 'ts_run_btn');
            tc.assertNotEmpty(dd, 'segmentation-source dropdown not rendered');
            tc.verifyNotEmpty(st); tc.verifyNotEmpty(bt);
            tc.verifyEqual(dd(1).ItemsData, ...
                {'totalsegmentator', 'learned', 'external'});
            tc.verifyEqual(dd(1).Value, 'totalsegmentator');   % default unchanged

            % Switch to the learned backend (no checkpoint in the test env).
            dd(1).Value = 'learned';
            feval(dd(1).ValueChangedFcn, dd(1), []); pause(0.2);
            % .Enable is a matlab.lang.OnOffSwitchState — compare as char.
            tc.verifyEqual(char(bt(1).Enable), 'off', ...
                'Run must be disabled when the learned model has no weights');
            tc.verifyTrue(contains(lower(st(1).Text), 'unavailable'));
            cbs = findobj(a.UIFigure, '-regexp', 'Tag', '^ts_target_');
            if ~isempty(cbs)
                tc.verifyEqual(char(cbs(1).Enable), 'off', ...
                    'TS ROI checkboxes should be inert for a non-TS source');
            end

            % Back to TotalSegmentator restores the ROI checkboxes.
            dd(1).Value = 'totalsegmentator';
            feval(dd(1).ValueChangedFcn, dd(1), []); pause(0.2);
            if ~isempty(cbs)
                tc.verifyEqual(char(cbs(1).Enable), 'on');
            end
        end

        function external_empty_mask_errors(tc)
            C = tc.make_labeled_case();
            nifti = fullfile(tc.tmp, 'empty.nii');
            niftiwrite(zeros(size(C.label), 'uint8'), nifti);
            tc.verifyError(@() run_planner_headless("", struct('D', C.D, ...
                'seg_backend', 'external', 'seg_label_nifti', nifti, ...
                'skip_centerline', true, 'out_dir', fullfile(tc.tmp, 'mt'))), ...
                'run_planner_headless:EmptyExternalSeg');
        end

    end

    methods (Access = private)
        function C = make_labeled_case(tc) %#ok<MANU>
        % A connected Y in the pipeline label scheme (head at z=1):
        %   aorta(1) column → bifurcation → R leg [iliac 3 → CFA 5] (lower x,
        %   patient-right) + L leg [iliac 2 → CFA 4] (higher x); celiac(8)
        %   and SMA(9) stubs above the renals. Femorals are caudal (high z).
            sz  = [64 64 120];
            lab = zeros(sz, 'uint8');
            cx  = 32;
            % aorta lumen, z 1..72
            for z = 1:72
                lab(30:34, cx-2:cx+2, z) = 1;
            end
            % celiac + SMA stubs (give the proximal-seed anchor)
            lab(31:33, cx+3:cx+9, 38:41) = 8;   % celiac
            lab(31:33, cx+3:cx+8, 46:49) = 9;   % SMA
            % legs, z 71..120 — start at the aorta and diverge so the whole
            % tree is one 26-connected component.
            for z = 71:120
                t   = (z - 71) / (120 - 71);         % 0..1 down the leg
                xr  = round(cx - 2 - 8 * t);         % right drifts to low x
                xl  = round(cx + 2 + 8 * t);         % left drifts to high x
                if z <= 88; rl = 3; else; rl = 5; end   % R iliac → R CFA
                if z <= 88; ll = 2; else; ll = 4; end   % L iliac → L CFA
                lab(30:33, xr-1:xr+1, z) = rl;
                lab(30:33, xl-1:xl+1, z) = ll;
            end
            D = struct();
            D.vol              = int16(lab > 0) * 300;   % contrast in-lumen
            D.pixel_mm         = [1 1];
            D.slice_spacing_mm = 1.5;
            D.slice_z_mm       = ((1:sz(3)) - 1).' * 1.5;
            D.is_volume        = true;
            D.z_normalized     = true;
            D.patient_id       = 'SYNTH';
            D.study_date        = '';
            D.series_description = 'synthetic labeled case';
            C = struct('label', lab, 'D', D);
        end
    end
end

% =========================================================================
function cleanup_gui(a, prev_home, tmp_home)
%CLEANUP_GUI  Always close the uifigure and restore the sandboxed home, so a
%   failed assertion never leaves a stale GUI window behind.
    try
        if isvalid(a) && isvalid(a.UIFigure); delete(a.UIFigure); end
    catch
    end
    if ~isempty(prev_home)
        java.lang.System.setProperty('user.home', prev_home);
    end
    if ~isempty(tmp_home) && exist(tmp_home, 'dir')
        rmdir(tmp_home, 's');
    end
end
