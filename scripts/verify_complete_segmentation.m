function verify_complete_segmentation()
%VERIFY_COMPLETE_SEGMENTATION  Run the full headless planner on JohnDoe1 and
%   JohnDoe2 and gate each result with autoseg.check_complete_segmentation.
%   Writes a plain-text verdict to results/logs/complete_seg_check.txt and a
%   .mat with the two reports, so a long VMTK run can be polled from disk.

    proj = fileparts(fileparts(mfilename('fullpath')));
    addpath(genpath(proj));
    parent = fileparts(proj);
    logdir = fullfile(proj, 'results', 'logs');
    if ~exist(logdir, 'dir'); mkdir(logdir); end
    txt = fullfile(logdir, 'complete_seg_check.txt');
    fid = fopen(txt, 'w');
    cleaner = onCleanup(@() fclose(fid));

    cases = struct( ...
        'name', {'JohnDoe1', 'JohnDoe2'}, ...
        'dir',  { fullfile(parent, 'JohnDoe1 EVAR', 'export', ...
                           'JohnDoe1', 'series'), ...
                  fullfile(parent, 'CTs and Angios', 'JohnDoe2', ...
                           'export', 'JohnDoe2', 'series') });

    reports = struct('name', {}, 'rep', {}, 'ok', {});
    for ci = 1:numel(cases)
        nm = cases(ci).name; droot = cases(ci).dir;
        logf(fid, '\n===== %s =====\n', nm);
        if ~isfolder(droot)
            logf(fid, '  SKIP — DICOM dir not found: %s\n', droot);
            continue;
        end
        try
            t0 = tic;
            opts = struct();
            opts.out_dir = fullfile(logdir, sprintf('%s_completecheck', lower(nm)));
            opts.verbose = true;
            pr = run_planner_headless(string(droot), opts);
            logf(fid, '  planner done in %.1f s\n', toc(t0));

            D = load_ct_for(nm, proj);
            rep = autoseg.check_complete_segmentation(pr, D, struct('verbose', true));

            logf(fid, '  VERDICT: %s\n', tern(rep.pass, 'PASS', 'FAIL'));
            logf(fid, '    single CC=%d (%.2f%% largest, %d CCs)\n', rep.single_cc, ...
                100*rep.largest_frac, rep.n_cc);
            logf(fid, '    R reach gap=%.0f mm  L reach gap=%.0f mm\n', rep.right_gap_mm, rep.left_gap_mm);
            logf(fid, '    R cl gap=%.0f mm     L cl gap=%.0f mm\n', rep.right_cl_gap_mm, rep.left_cl_gap_mm);
            for k = 1:numel(rep.reasons)
                logf(fid, '    - %s\n', rep.reasons{k});
            end
            reports(end+1) = struct('name', nm, 'rep', rep, 'ok', rep.pass); %#ok<AGROW>
        catch ME
            logf(fid, '  ERROR on %s: %s\n', nm, ME.message);
            for k = 1:numel(ME.stack)
                logf(fid, '     %s line %d\n', ME.stack(k).name, ME.stack(k).line);
            end
        end
    end

    logf(fid, '\n===== SUMMARY =====\n');
    for ci = 1:numel(reports)
        logf(fid, '  %-10s %s\n', reports(ci).name, tern(reports(ci).ok, 'PASS', 'FAIL'));
    end
    save(fullfile(logdir, 'complete_seg_check.mat'), 'reports', '-v7.3');
    logf(fid, '\nDONE. Reports -> complete_seg_check.mat\n');
end

function logf(fid, fmt, varargin)
%LOGF  Echo a formatted line to both the command window and the log file.
    fprintf(1, fmt, varargin{:});
    fprintf(fid, fmt, varargin{:});
end

function D = load_ct_for(nm, proj)
    logdir = fullfile(proj, 'results', 'logs');
    switch lower(nm)
        case 'johndoe1'
            S = load(fullfile(logdir, 'ct_volume.mat'));    % var D_ct
            D = S.D_ct;
        case 'johndoe2'
            S = load(fullfile(logdir, 'johndoe2_ct.mat')); % var D
            D = S.D;
        otherwise
            error('no CT cache mapping for %s', nm);
    end
end

function s = tern(c, a, b)
    if c; s = a; else; s = b; end
end
