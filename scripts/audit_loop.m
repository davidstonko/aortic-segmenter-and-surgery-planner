function audit_loop()
%AUDIT_LOOP  Two-stage audit driver:
%   STAGE 1 — code: parse + static analysis on every package file.
%   STAGE 2 — GUI: run the full workflow audit, then pixel-check the
%             screenshots and report findings.
%
%   Returns nothing; prints a clean pass/fail summary. Designed to be
%   called over and over until both stages report 0 findings.

    here = fileparts(mfilename('fullpath'));
    proj = fileparts(here);
    addpath(proj);

    fprintf('\n================ AUDIT LOOP ================\n');

    % --- Stage 1: code -----------------------------------------
    fprintf('\n[Stage 1] Code audit\n');
    n_code = 0;
    files = [...
        find_m(proj, '+app');         find_m(proj, '+autoseg'); ...
        find_m(proj, '+io');          find_m(proj, '+library'); ...
        find_m(proj, '+phantom');     find_m(proj, '+preprocess'); ...
        find_m(proj, '+setup');       find_m(proj, '+vmtk_centerline')];
    for k = 1:numel(files)
        issues = checkcode(files{k}, '-id');
        if ~isempty(issues)
            % Drop everything we consider acceptable noise:
            %   - stale %#ok pragma notes (cosmetic, no real bug)
            %   - "extra semicolon" cosmetics
            %   - "use ISMATRIX" / "isscalar" perf nudges
            %   - "Value assigned to variable might be unused"
            %     warnings on optional outputs of multi-return calls
            stale_msg = 'A Code Analyzer message was once suppressed here';
            keep = true(numel(issues), 1);
            for j = 1:numel(issues)
                m = issues(j).message;
                if contains(m, stale_msg) || ...
                   contains(m, 'Extra semicolon') || ...
                   contains(m, 'ISMATRIX') || ...
                   contains(m, 'isscalar') || ...
                   contains(m, 'use ''ismatrix''') || ...
                   contains(m, 'Value assigned to variable might be unused') || ...
                   contains(m, 'Input argument might be unused') || ...
                   contains(m, 'Use of brackets [] is unnecessary') || ...
                   contains(m, 'Function might be unused') || ...
                   contains(m, '{ A{I} }')
                    keep(j) = false;
                end
            end
            issues = issues(keep);
        end
        if ~isempty(issues)
            for j = 1:numel(issues)
                fprintf('  [%s:%d] %s\n', strip_proj(files{k}, proj), ...
                    issues(j).line, issues(j).message);
                n_code = n_code + 1;
            end
        end
    end
    fprintf('  → %d code finding(s) (cosmetic noise filtered)\n', n_code);

    % --- Stage 2: GUI workflow + pixel checks ------------------
    fprintf('\n[Stage 2] GUI workflow audit\n');
    try
        evalin('base', 'clear classes');
    catch
    end
    audit_full_workflow();
    n_gui = 0;
    findings = audit_pixel_checks();
    n_gui = numel(findings);

    % --- Summary ----------------------------------------------
    fprintf('\n================ SUMMARY ================\n');
    fprintf('  Stage 1 (code):  %d finding(s)\n', n_code);
    fprintf('  Stage 2 (GUI):   %d finding(s)\n', n_gui);
    if n_code == 0 && n_gui == 0
        fprintf('  ✓ APPROVED — both stages green.\n');
    else
        fprintf('  ✗ NOT APPROVED — fix and re-run.\n');
    end
    fprintf('==========================================\n\n');
end

% =========================================================================
function ms = find_m(proj, pkg)
    d = fullfile(proj, pkg);
    if exist(d, 'dir')
        f = dir(fullfile(d, '*.m'));
        ms = arrayfun(@(x) fullfile(x.folder, x.name), f, 'UniformOutput', false);
    else
        ms = {};
    end
end

function s = strip_proj(p, proj)
    if startsWith(p, proj)
        s = p(numel(proj)+2:end);
    else
        s = p;
    end
end
