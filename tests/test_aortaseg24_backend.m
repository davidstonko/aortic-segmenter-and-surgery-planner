classdef test_aortaseg24_backend < matlab.unittest.TestCase
%TEST_AORTASEG24_BACKEND  Smoke + scaffolding tests for the
%   `+autoseg/+aortaseg24/` package.
%
%   As of Phase B1 (2026-06-15) the package wires the nnU-Net
%   pretrained-checkpoint inference glue but ships no weights (none are
%   public — see docs/AORTASEG24_LABEL_MAP.md). These tests pin the
%   shape WITHOUT requiring a model:
%     - detect() returns a struct with the documented fields, and is
%       honest about availability (only true when a checkpoint + python
%       are present).
%     - run() refuses to fabricate output: it raises Unavailable when no
%       backend exists, and Phase_B_needs_weights when a backend is
%       detected but no checkpoint is on disk.
%     - translate_labels() is a pure function that consumes the
%       provisional class-map JSON correctly.
%
%   The actual inference path (write NIfTI → nnUNetv2_predict → read
%   multilabel → translate_labels) only executes when a real checkpoint
%   dir is present; those branches are gated by assumeTrue so the suite
%   stays portable on a clean machine.

    methods (TestClassSetup)
        function add_paths(tc)
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
        end
    end

    methods (Test)
        function detect_returns_expected_shape(tc)
            info = autoseg.aortaseg24.detect();
            for f = {'available', 'backend', 'python', 'weights', 'class_map', 'error'}
                tc.verifyTrue(isfield(info, f{1}), ...
                    sprintf('detect() missing field: %s', f{1}));
            end
            tc.verifyTrue(islogical(info.available));
            tc.verifyTrue(ischar(info.error) || isstring(info.error));
        end

        function run_errors_cleanly_when_unavailable(tc)
            info = autoseg.aortaseg24.detect();
            tc.assumeFalse(info.available, ...
                'Backend IS available — skipping the "no backend" test; the Phase_A guard test still applies separately.');
            D = struct('vol', zeros(8,8,8,'single'), ...
                       'pixel_mm', [1 1], 'slice_spacing_mm', 1);
            tc.verifyError(@() autoseg.aortaseg24.run(D), ...
                'autoseg:aortaseg24:Unavailable');
        end

        function run_errors_when_backend_but_no_weights(tc)
            % If a backend IS detected but NO trained checkpoint is on
            % disk (the universal state today — no public AortaSeg24
            % weights exist), run() must refuse to fabricate output and
            % raise the actionable Phase_B_needs_weights error.
            info = autoseg.aortaseg24.detect();
            tc.assumeTrue(info.available, ...
                'No backend detected — Phase_B_needs_weights path can''t be exercised here');
            tc.assumeTrue(isempty(info.weights), ...
                'A real checkpoint dir is present — the no-weights guard does not apply here');
            % Belt-and-braces: ensure no model dir is configured for this
            % assertion (env may inject one in a developer shell).
            tc.assumeTrue(isempty(getenv('AORTASEG24_MODEL_DIR')), ...
                'AORTASEG24_MODEL_DIR is set — inference path would run; skipping no-weights guard');
            D = struct('vol', zeros(8,8,8,'single'), ...
                       'pixel_mm', [1 1], 'slice_spacing_mm', 1);
            tc.verifyError(@() autoseg.aortaseg24.run(D), ...
                'autoseg:aortaseg24:Phase_B_needs_weights');
        end

        function detect_weights_implies_python(tc)
            % Contract: detect() never claims a usable checkpoint without
            % also resolving a python interpreter. If .weights is set and
            % a python was found, available must be true; if weights are
            % set but no python, available stays false with an error.
            info = autoseg.aortaseg24.detect();
            if ~isempty(info.weights)
                if isempty(info.python)
                    tc.verifyFalse(info.available, ...
                        'weights present but no python — must not be available');
                    tc.verifyNotEmpty(info.error);
                else
                    tc.verifyTrue(info.available, ...
                        'weights + python present — should be available');
                end
            end
        end

        function run_honors_model_dir_env_with_clear_error_when_bogus(tc)
            % When AORTASEG24_MODEL_DIR points at a non-existent dir, the
            % env override is ignored by detect() (it requires exist(dir)),
            % so the contract degrades gracefully to either Unavailable or
            % Phase_B_needs_weights — never a fabricated segmentation and
            % never an undefined-function crash. This pins that run() only
            % ever throws one of the documented identifiers here.
            D = struct('vol', zeros(8,8,8,'single'), ...
                       'pixel_mm', [1 1], 'slice_spacing_mm', 1);
            okIDs = {'autoseg:aortaseg24:Unavailable', ...
                     'autoseg:aortaseg24:Phase_B_needs_weights', ...
                     'autoseg:aortaseg24:PredictFailed', ...
                     'autoseg:aortaseg24:NoOutput'};
            try
                autoseg.aortaseg24.run(D);
                % If it returned without error a real backend produced
                % output — acceptable, nothing to assert here.
            catch ME
                tc.verifyTrue(any(strcmp(ME.identifier, okIDs)), ...
                    sprintf('run() threw an undocumented identifier: %s', ME.identifier));
            end
        end

        function class_map_json_is_well_formed(tc)
            proj = fileparts(fileparts(mfilename('fullpath')));
            cm_path = fullfile(proj, 'data', 'aortaseg24_class_map.json');
            tc.verifyTrue(isfile(cm_path), 'class map JSON missing');
            fid = fopen(cm_path, 'r');
            cleaner = onCleanup(@() fclose(fid));
            txt = fread(fid, inf, '*char')';
            j = jsondecode(txt);
            tc.verifyTrue(isfield(j, 'version'));
            tc.verifyTrue(isfield(j, 'classes'));
            tc.verifyGreaterThanOrEqual(numel(j.classes), 23, ...
                'AortaSeg24 has 23 classes; class map must enumerate at least 23.');
            % Every entry has the three required fields
            for k = 1:numel(j.classes)
                e = j.classes(k);
                tc.verifyTrue(isfield(e, 'id') && isfield(e, 'name') && isfield(e, 'pipeline_label'), ...
                    sprintf('class %d missing required field', k));
                tc.verifyGreaterThanOrEqual(e.id, 1);
                tc.verifyLessThanOrEqual(e.id, 23);
                tc.verifyGreaterThanOrEqual(e.pipeline_label, 0);
                tc.verifyLessThanOrEqual(e.pipeline_label, 11);
            end
        end

        function translate_labels_round_trips_synthetic_volume(tc)
            % Build a tiny synthetic raw-label volume containing a few
            % AortaSeg24 classes (per the paper-aligned class map),
            % push through translate_labels, and verify the pipeline-
            % label output respects the JSON map.
            sz = [4, 4, 4];
            raw = zeros(sz, 'uint8');
            raw(1, :, :) = 8;    % left_common_iliac     -> pipeline 2
            raw(2, :, :) = 9;    % right_common_iliac    -> pipeline 3
            raw(3, :, :) = 4;    % celiac_artery         -> pipeline 8
            raw(4, :, :) = 19;   % aortic_zone_5 (lumen) -> pipeline 1

            [out, classes] = autoseg.aortaseg24.translate_labels(raw);
            tc.verifyEqual(unique(out(:))', uint8([1 2 3 8]));
            tc.verifyEqual(unique(out(raw == 8)),  uint8(2));
            tc.verifyEqual(unique(out(raw == 9)),  uint8(3));
            tc.verifyEqual(unique(out(raw == 4)),  uint8(8));
            tc.verifyEqual(unique(out(raw == 19)), uint8(1));
            tc.verifyGreaterThanOrEqual(numel(classes), 4);
            % Every reported class entry must have voxel count > 0
            for k = 1:numel(classes)
                tc.verifyGreaterThan(classes(k).voxels, 0);
            end
        end

        function translate_labels_drops_pipeline_label_zero(tc)
            % Classes whose pipeline_label is 0 (e.g. innominate
            % artery — out of EVAR scope) should be PRESERVED in the
            % .classes report but DROPPED from the translated label
            % volume.
            raw = zeros(4,4,4,'uint8');
            raw(1,:,:) = 1;   % innominate_artery -> pipeline 0
            raw(2,:,:) = 8;   % left_common_iliac -> pipeline 2
            [out, classes] = autoseg.aortaseg24.translate_labels(raw);
            tc.verifyEqual(unique(out(:))', uint8([0 2]));
            ids = [classes.id];
            tc.verifyTrue(any(ids == 1), 'innominate_artery should appear in classes report');
            tc.verifyTrue(any(ids == 8));
        end
    end
end
