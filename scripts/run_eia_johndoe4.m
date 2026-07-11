function run_eia_johndoe4()
%RUN_EIA_JOHNDOE4  End-to-end EIA-mode validation on JohnDoe4.
    here = fileparts(fileparts(mfilename('fullpath'))); cd(here); addpath(here);
    diary('/tmp/eia_johndoe4.txt'); diary on;
    c = onCleanup(@() diary('off'));
    root = fullfile(fileparts(here), 'CTs and Angios');
    dcm = fullfile(root,'JohnDoe4','export','JohnDoe4','study','series');
    opts = struct('ts_mode','full','distal_target','external_iliac','verbose',true);
    t = tic;
    out = run_planner_headless(dcm, opts);
    fprintf('\n=== EIA RESULT (%.0fs) ===\n', toc(t));
    fprintf('arc_R=%.0f mm  arc_L=%.0f mm\n', out.arc_R_mm, out.arc_L_mm);
    fprintf('qc: implausible=%d (R=%d L=%d) thresh=%.0f target=%s\n', ...
        out.qc.centerline_implausible, out.qc.centerline_implausible_R, ...
        out.qc.centerline_implausible_L, out.qc.min_plausible_arc_mm, out.qc.distal_target);
    if isfield(out,'plan') && isfield(out.plan,'measurements')
        m = out.plan.measurements;
        f = @(n) (isfield(m,n))*0 + (isfield(m,n) && ~isempty(m.(n)))*1;
        gv = @(n) ternlocal(isfield(m,n), m, n);
        fprintf('plan: neck Ø=%.1f  neckL=%.1f  ∠β=%.0f  iliacR Ø=%.1f  iliacL Ø=%.1f\n', ...
            gv('neck_diameter_mm'), gv('neck_length_mm'), gv('neck_angulation_deg'), ...
            gv('iliac_R_diameter_mm'), gv('iliac_L_diameter_mm'));
    end
    if isfield(out.qc,'warnings') && ~isempty(out.qc.warnings)
        fprintf('warnings:\n'); for i=1:numel(out.qc.warnings), fprintf('  - %s\n', out.qc.warnings{i}); end
    end
    save('/tmp/out_eia_johndoe4.mat','out','-v7.3');
    fprintf('[saved /tmp/out_eia_johndoe4.mat]\n');
end
function v = ternlocal(tf, m, n)
    if tf && ~isempty(m.(n)), v = m.(n); else, v = NaN; end
end
