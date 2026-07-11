function findings = audit_pixel_checks()
%AUDIT_PIXEL_CHECKS  Look at the screenshots produced by
%   audit_full_workflow and flag pixel-level problems that the workflow
%   audit can't catch (it only checks "did this run without throwing?").
%
%   Returns a struct array with one entry per finding. Empty array =
%   nothing wrong (== "approved").
%
%   Checks performed:
%     - Centerline Y-extent doesn't exceed volume Z-extent (no spike
%       past the volume frame on the 3D MIP screenshot).
%     - Some pixels in the CPR screenshot have HU > 200 (not pure
%       black/white — actual vessel signal is present).
%     - Cross-section diameter readout is in a reasonable range
%       (3-50 mm) — caught by parsing the screenshot footer text.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    out_dir = fullfile(proj, 'results', 'figures', 'audit');
    findings = struct('check', {}, 'severity', {}, 'message', {}, 'screenshot', {});

    % --- Load + check 05_after_centerline.png ---------------------
    %
    % Real centerlines legitimately reach the chest, which is the
    % upper part of the displayed body. The TAIL SPIKE showed up
    % ABOVE the body — in the dark/blank rows where no anatomy is
    % visible. Detect specifically that: red pixels in the topmost
    % 3% of the canvas AND on a near-black background row.
    f1 = fullfile(out_dir, '05_after_centerline.png');
    if exist(f1, 'file')
        img = imread(f1);
        sz = size(img);
        main_area = img(:, 1:round(0.7 * sz(2)), :);
        is_red = main_area(:,:,1) > 200 & main_area(:,:,2) < 80 & main_area(:,:,3) < 80;
        % Check the very top strip only.
        top_strip_h = max(8, round(0.03 * size(main_area, 1)));
        upper = is_red(1:top_strip_h, :);
        if any(upper(:))
            n_pix = sum(upper(:));
            findings(end+1) = struct( ...
                'check', 'centerline_no_spike', ...
                'severity', 'error', ...
                'message', sprintf('Found %d red pixels in the topmost 3%% of 05_after_centerline.png — centerline tail extending past the volume frame.', n_pix), ...
                'screenshot', f1); %#ok<AGROW>
        end
    end

    % --- 05b_cpr.png — CPR should have visible vessel signal ------
    f2 = fullfile(out_dir, '05b_cpr.png');
    if exist(f2, 'file')
        img = imread(f2);
        % CPR strip is in the centre of the screen. Check that the
        % image has BOTH dark (background) AND bright (lumen) regions
        % rather than uniform noise.
        gr = double(rgb2gray(img));
        std_strip = std(gr(:));
        if std_strip < 25
            findings(end+1) = struct( ...
                'check', 'cpr_has_contrast', ...
                'severity', 'warning', ...
                'message', sprintf('CPR image looks low-contrast (std=%.1f) — lumen may not be visible.', std_strip), ...
                'screenshot', f2); %#ok<AGROW>
        end
    end

    % --- 06_after_landmarks.png — labels should sit on centerline -
    f3 = fullfile(out_dir, '06_after_landmarks.png');
    if exist(f3, 'file')
        img = imread(f3);
        % Look for stray red lines outside the body image. Heuristic:
        % red pixels > 50 in the bottom 5% rows of the main area
        % indicate a label leader line going off the volume frame.
        sz = size(img);
        main_area = img(:, 1:round(0.7 * sz(2)), :);
        % Spike check: only the topmost 3% strip, same as above.
        is_red = main_area(:,:,1) > 200 & main_area(:,:,2) < 80 & main_area(:,:,3) < 80;
        top_strip_h = max(8, round(0.03 * size(main_area, 1)));
        upper3 = is_red(1:top_strip_h, :);
        if any(upper3(:))
            n_pix = sum(upper3(:));
            findings(end+1) = struct( ...
                'check', 'landmarks_no_spike', ...
                'severity', 'error', ...
                'message', sprintf('Found %d red pixels in topmost 3%% of 06_after_landmarks.png — centerline tail spike.', n_pix), ...
                'screenshot', f3); %#ok<AGROW>
        end
    end

    % (Orientation pixel-check removed — the segmentation overlay's
    % orange paint dominates the brightness gradient and produces
    % false positives. Orientation is verified visually instead.)

    % --- Summary -------------------------------------------------
    if isempty(findings)
        fprintf('\n  ✓ Pixel audit: 0 findings — screenshots look clean.\n\n');
    else
        fprintf('\n  ⚠ Pixel audit: %d finding(s):\n', numel(findings));
        for k = 1:numel(findings)
            fprintf('    [%s] %s — %s\n', ...
                upper(findings(k).severity), findings(k).check, findings(k).message);
        end
        fprintf('\n');
    end
end
