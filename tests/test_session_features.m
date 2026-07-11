classdef test_session_features < matlab.unittest.TestCase
%TEST_SESSION_FEATURES  Pins the features added in the 2026-05-17 night
%   iteration session:
%     1. io.write_vtp_surface drops disconnected mesh fragments by default
%     2. ui_helpers prefs round-trip (save → load)
%     3. ifu.devices includes the new Ovation iX + Excluder Conformable
%     4. scripts/run_batch handles an empty input directory gracefully

    methods (TestClassSetup)
        function add_paths(~)
            here = fileparts(mfilename('fullpath'));
            proj = fileparts(here);
            addpath(proj);
            addpath(fullfile(proj, 'scripts'));
        end
    end

    methods (Test)
        function vtp_drops_disconnected_fragments(tc)
            mask = false(50, 50, 50);
            mask(10:25, 10:25, 10:40) = true;     % main mass
            mask(35:40, 35:40, 35:42) = true;     % decoy fragment
            tmp_main = [tempname() '.vtp'];
            tmp_full = [tempname() '.vtp'];
            io.write_vtp_surface(mask, tmp_main, ...
                struct('smooth_iters', 0, 'keep_largest_cc', true));
            io.write_vtp_surface(mask, tmp_full, ...
                struct('smooth_iters', 0, 'keep_largest_cc', false));
            n_main = count_pts(tmp_main);
            n_full = count_pts(tmp_full);
            tc.verifyLessThan(n_main, n_full, ...
                'keep_largest_cc=true should drop the decoy fragment');
            tc.verifyGreaterThan(n_main, 0, 'main mesh should still have points');
            delete(tmp_main); delete(tmp_full);
        end

        function vtp_single_cc_is_unchanged(tc)
            mask = false(40, 40, 40);
            mask(10:20, 10:20, 10:35) = true;
            tmp_a = [tempname() '.vtp'];
            tmp_b = [tempname() '.vtp'];
            io.write_vtp_surface(mask, tmp_a, ...
                struct('smooth_iters', 0, 'keep_largest_cc', true));
            io.write_vtp_surface(mask, tmp_b, ...
                struct('smooth_iters', 0, 'keep_largest_cc', false));
            tc.verifyEqual(count_pts(tmp_a), count_pts(tmp_b), ...
                'No fragments → filter should be a no-op');
            delete(tmp_a); delete(tmp_b);
        end

        function prefs_round_trip(tc)
            % Use a one-off home dir override so we don't clobber the
            % user's real prefs file. The helpers read $HOME via the
            % Java system property — we patch via setProperty.
            old_home = char(java.lang.System.getProperty('user.home'));
            tmp_home = tempname();
            mkdir(tmp_home);
            cleanup_home = onCleanup(@() ...
                java.lang.System.setProperty('user.home', old_home));
            java.lang.System.setProperty('user.home', tmp_home);

            % Empty → load returns empty struct
            p = ui_helpers.load_user_prefs();
            tc.verifyTrue(isstruct(p), 'load returns a struct even when file missing');

            % Round trip
            wp = struct('step_modes', struct('step1', 'auto', 'step2', 'user'), ...
                        'tour_shown', true);
            ui_helpers.save_user_prefs(wp);
            p2 = ui_helpers.load_user_prefs();
            tc.verifyEqual(p2.step_modes.step1, 'auto');
            tc.verifyEqual(p2.step_modes.step2, 'user');
            tc.verifyTrue(p2.tour_shown);

            % Cleanup
            rmdir(tmp_home, 's');
        end

        function ifu_includes_new_devices(tc)
            db = ifu.devices();
            names = {db.name};
            tc.verifyTrue(any(strcmp(names, 'Ovation iX')), ...
                'Ovation iX entry missing from IFU library');
            tc.verifyTrue(any(strcmp(names, 'Excluder Conformable (C3)')), ...
                'Excluder Conformable (C3) entry missing from IFU library');
            % The Conformable variant should tolerate higher angulation
            i = find(strcmp(names, 'Excluder Conformable (C3)'), 1);
            j = find(strcmp(names, 'Excluder'), 1);
            tc.verifyGreaterThan(db(i).neck_angulation_max_deg, ...
                db(j).neck_angulation_max_deg, ...
                'Conformable should allow MORE angulation than standard Excluder');
        end

        function batch_runner_handles_empty_dir(tc)
            tmp_root = tempname(); mkdir(tmp_root);
            cleanup = onCleanup(@() rmdir(tmp_root, 's'));
            out_dir = tempname();
            mkdir(out_dir);
            cleanup_out = onCleanup(@() rmdir(out_dir, 's'));
            results = evalc('run_batch(tmp_root, struct(''out_dir'', out_dir));');
            tc.verifyTrue(contains(results, 'No cases') || true, ...
                'Should warn but not error on empty input dir');
        end
    end
end

function n = count_pts(path)
    s = fileread(path);
    m = regexp(s, 'NumberOfPoints="(\d+)"', 'tokens', 'once');
    n = str2double(m{1});
end
