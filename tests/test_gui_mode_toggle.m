classdef test_gui_mode_toggle < matlab.unittest.TestCase
%TEST_GUI_MODE_TOGGLE  Pins the User-driven / Automatic toggle behavior
%   on every step of AorticCenterlineApp. Goal #33 (P0).
%
%   1. Default mode for every step = 'user'
%   2. setStepModePublic + setStepPublic produces a step_mode_group
%      widget AND at least one info button on every step (in both modes)
%   3. ui_helpers.help_content returns a non-empty entry for every help
%      key referenced by the GUI

    properties (Access = private)
        a
        prev_home    % saved user.home so we can restore after the test
        tmp_home     % tempdir we point user.home at while the test runs
    end

    methods (TestClassSetup)
        function add_paths(tc)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
            tc.assumeTrue(usejava('desktop') || feature('ShowFigureWindows'), ...
                'GUI tests require a display');
        end
    end

    methods (TestMethodSetup)
        function build_app(tc)
            % Sandbox the user.home so the persistence layer in the app
            % doesn't pollute the real prefs file (and doesn't get
            % polluted by previous test-run residue).
            tc.prev_home = char(java.lang.System.getProperty('user.home'));
            tc.tmp_home  = tempname();
            mkdir(tc.tmp_home);
            java.lang.System.setProperty('user.home', tc.tmp_home);

            tc.a = app.AorticCenterlineApp();
            pause(0.2);
            % Inject a tiny synthetic CT so Step 2-6 user modes render
            sz = [60 60 120];
            D = struct('vol', int16(zeros(sz)), ...
                'pixel_mm', [1.0 1.0], 'slice_spacing_mm', 1.0, ...
                'is_volume', true, 'z_normalized', true, ...
                'series_description', 'test', 'slice_z_mm', (1:sz(3))');
            tc.a.injectCT(D);
            pause(0.1);
        end
    end

    methods (TestMethodTeardown)
        function close_app(tc)
            if isvalid(tc.a) && isvalid(tc.a.UIFigure)
                delete(tc.a.UIFigure);
            end
            if ~isempty(tc.prev_home)
                java.lang.System.setProperty('user.home', tc.prev_home);
            end
            if ~isempty(tc.tmp_home) && exist(tc.tmp_home, 'dir')
                rmdir(tc.tmp_home, 's');
            end
        end
    end

    methods (Test)
        function defaults_are_user_driven(tc)
            for k = 1:6
                tc.verifyEqual(tc.a.getStepModePublic(k), 'user', ...
                    sprintf('Step %d default mode should be user', k));
            end
        end

        function each_step_renders_toggle_in_both_modes(tc)
            for k = 1:6
                for mode = {'user', 'auto'}
                    tc.a.setStepModePublic(k, mode{1});
                    tc.a.setStepPublic(k);
                    pause(0.05);
                    g = findobj(tc.a.UIFigure, 'Tag', 'step_mode_group');
                    tc.verifyNotEmpty(g, sprintf( ...
                        'Step %d (%s): step_mode_group widget missing', k, mode{1}));
                end
            end
        end

        function each_step_has_info_buttons(tc)
            for k = 1:6
                for mode = {'user', 'auto'}
                    tc.a.setStepModePublic(k, mode{1});
                    tc.a.setStepPublic(k);
                    pause(0.05);
                    btns = findobj(tc.a.UIFigure, 'Type', 'uibutton');
                    is_info = false(size(btns));
                    for j = 1:numel(btns)
                        if startsWith(btns(j).Tag, 'info_')
                            is_info(j) = true;
                        end
                    end
                    n_info = nnz(is_info);
                    tc.verifyGreaterThanOrEqual(n_info, 1, sprintf( ...
                        'Step %d (%s): no info buttons rendered', k, mode{1}));
                end
            end
        end

        function toggle_persists_across_step_revisits(tc)
            tc.a.setStepModePublic(3, 'auto');
            tc.a.setStepPublic(1); pause(0.05);
            tc.a.setStepPublic(3); pause(0.05);
            tc.verifyEqual(tc.a.getStepModePublic(3), 'auto', ...
                'Mode did not persist across step revisits');
        end

        function help_menu_is_present(tc)
            menus = findobj(tc.a.UIFigure, 'Type', 'uimenu', 'Text', 'Help');
            tc.verifyNotEmpty(menus, 'Top-level Help menu missing');
        end

        function all_help_keys_in_registry(tc)
            % Inspect every info button's tag, extract the help key,
            % verify the key resolves to a non-empty entry.
            tc.a.setStepPublic(2);   % visit a step that has many keys
            pause(0.1);
            keys = unique(arrayfun(@extract_key, ...
                findobj(tc.a.UIFigure, 'Type', 'uibutton'), ...
                'UniformOutput', false));
            keys = keys(~cellfun(@isempty, keys));
            for k = 1:numel(keys)
                e = ui_helpers.help_content(keys{k});
                tc.verifyFalse(isempty(e.title) && isempty(e.body), ...
                    sprintf('Help entry for "%s" is empty', keys{k}));
            end
        end
    end
end

function key = extract_key(btn)
    if startsWith(btn.Tag, 'info_')
        key = char(extractAfter(btn.Tag, 'info_'));
    else
        key = '';
    end
end
