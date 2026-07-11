classdef test_orientation_guard < matlab.unittest.TestCase
%TEST_ORIENTATION_GUARD  autoseg.orientation_is_suspect (#36). In the
%   cranial-first volume the femoral (CFA) endpoints must be caudal —
%   a HIGHER slice index than the proximal seed — so they render at the
%   bottom of the screen. A flipped series violates this.

    methods (TestClassSetup)
        function add_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function correct_orientation_not_suspect(tc)
            % Femorals (z=400/405) caudal to the proximal seed (z=80).
            seeds = struct('proximal', [256 256 80], ...
                'right_cfa', [300 200 400], 'left_cfa', [300 312 405]);
            [suspect, msg] = autoseg.orientation_is_suspect(seeds, true);
            tc.verifyFalse(suspect);
            tc.verifyEmpty(msg);
        end

        function flipped_series_is_suspect(tc)
            % Femorals (z=40/45) ABOVE the proximal seed (z=400) — flipped.
            seeds = struct('proximal', [256 256 400], ...
                'right_cfa', [300 200 40], 'left_cfa', [300 312 45]);
            [suspect, msg] = autoseg.orientation_is_suspect(seeds, true);
            tc.verifyTrue(suspect);
            tc.verifyNotEmpty(msg);
            tc.verifyTrue(contains(msg, 'bottom'));
        end

        function unknown_craniocaudal_annotates_message(tc)
            % When the loader couldn't orient from position tags, the
            % message says so (a suspect result is then a likely flip).
            seeds = struct('proximal', [256 256 400], ...
                'right_cfa', [300 200 40], 'left_cfa', [300 312 45]);
            [~, msg] = autoseg.orientation_is_suspect(seeds, false);
            tc.verifyTrue(contains(msg, 'not verifiable'));
        end
    end
end
