function out = run_planner_headless(dicom_dir, opts)
%RUN_PLANNER_HEADLESS  End-to-end EVAR planner, no clicks.
%
%   OUT = run_planner_headless(DICOM_DIR)
%   OUT = run_planner_headless(DICOM_DIR, OPTS)
%
%   Takes a directory containing a single CT series (raw DICOM), and
%   runs the EVAR planning pipeline with zero user interaction:
%       1. DICOM ingest         — preprocess.dicom_load
%       2. Segmentation         — autoseg.ts_run (aorta + iliacs +
%                                  kidneys + liver, all needed for the
%                                  anatomic seed step)
%       3. Auto-seed detection  — preprocess.auto_seeds_anatomic
%                                  (proximal ≈ 5 cm above celiac via
%                                  kidney_top - 70 mm; CFAs at iliac
%                                  termini)
%       4. Bifurcated centerline — shortest path from proximal to each
%                                  CFA over the skeleton of the TS mask.
%       5. Save artefacts        — centerlines + QC figure.
%
%   This is the open-source EVAR-planner entry point. The accompanying
%   AorticCenterlineApp wraps the same steps in a GUI; this function
%   skips the GUI entirely.
%
%   OPTS (struct), optional:
%       .out_dir         where to write results (default
%                        results/logs/headless_<dt>/)
%       .fast            pass --fast to TS (default true; 3 mm model)
%       .targets         TS targets (default aorta+iliacs+kidneys+liver)
%       .min_radius_vox  skeleton radius filter (default 1.0 voxels —
%                        small enough to let the centerline pass through
%                        the slice-by-slice CFA extension where the
%                        bridge tubes have local Dt = 1-2 voxels)
%
%   Returns OUT struct with:
%       .seeds              from preprocess.auto_seeds_anatomic
%       .seeds_mm           same in patient coordinates
%       .mask               binary aorta+iliac mask from TS
%       .Pv_mm_right        Nx3 polyline, proximal → R-CFA, mm
%       .Pv_mm_left         Mx3 polyline, proximal → L-CFA, mm
%       .R_mm_right         radius profile of right branch
%       .R_mm_left          radius profile of left branch
%       .timing             per-stage seconds
%       .out_dir            where artefacts were saved

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        dicom_dir (1,1) string
        opts      (1,1) struct = struct()
    end
    % Segmentation backend resolution. New preferred field is
    % `opts.ts_mode` ∈ {'fast', 'full'}. Legacy `opts.fast` is still
    % honored. 'fast' = TS --fast (3 mm model, ~30 s, may miss
    % minor branches). 'full' = native 1.5 mm model (~5-15 min,
    % cleaner branch separation; may obviate `extend_and_detect_branches`
    % fallback on some cases).
    if isfield(opts, 'ts_mode')
        switch lower(opts.ts_mode)
            case 'fast'; opts.fast = true;
            case 'full'; opts.fast = false;
            otherwise
                error('run_planner_headless:BadMode', ...
                    'opts.ts_mode must be ''fast'' or ''full'' (got ''%s'')', opts.ts_mode);
        end
    end
    if ~isfield(opts, 'fast');            opts.fast = true;           end
    if ~isfield(opts, 'targets')
        % Include kidneys + liver so auto_seeds_anatomic can use the
        % kidney_top anchor (needed when celiac/SMA aren't detected).
        % Docstring promises "aorta+iliacs+kidneys+liver" — the
        % previous default was just aorta+iliacs which contradicted
        % the docstring and quietly broke the kidney fallback on cases
        % where TS-fast didn't otherwise include the kidney label in
        % the binary mask.
        opts.targets = {'aorta', 'iliac_artery_left', 'iliac_artery_right', ...
                        'kidney_left', 'kidney_right', 'liver'};
    end
    if ~isfield(opts, 'min_radius_vox');  opts.min_radius_vox = 1.0;  end
    if ~isfield(opts, 'verbose');         opts.verbose = true;        end
    % Centerline backend: 'auto' picks VMTK when available, MATLAB skeleton-
    % graph otherwise. 'vmtk' forces VMTK (errors if unavailable). 'matlab'
    % forces the skeleton-graph path. The VMTK path produces a smoother
    % Voronoi/fast-marching centerline that matches TeraRecon's algorithm;
    % the MATLAB path is a pure-MATLAB fallback with no external deps.
    if ~isfield(opts, 'centerline_backend'); opts.centerline_backend = 'auto'; end
    if ~isfield(opts, 'out_dir')
        opts.out_dir = fullfile('results', 'logs', ...
            sprintf('headless_%s', datestr(now, 'yyyymmdd_HHMMSS'))); %#ok<DATST,TNOW1>
    end
    if ~exist(opts.out_dir, 'dir'); mkdir(opts.out_dir); end

    timing = struct();
    fprintf('=== run_planner_headless ===\n');
    fprintf('DICOM dir: %s\n', dicom_dir);
    fprintf('Output:    %s\n', opts.out_dir);

    % --- Step 1: load CT ----
    % A GUI caller that already has the volume loaded can pass it via
    % opts.D to skip the DICOM read (dicom_dir may then be '' / a label).
    t0 = tic;
    if isfield(opts, 'D') && ~isempty(opts.D) && isstruct(opts.D) ...
            && isfield(opts.D, 'vol') && ~isempty(opts.D.vol)
        D = opts.D;
        fprintf('[1] Using preloaded volume from opts.D (skipping DICOM read)\n');
    else
        D = preprocess.dicom_load(char(dicom_dir));
    end
    timing.dicom_load = toc(t0);
    assert(D.is_volume, 'run_planner_headless:NotVolume', ...
        'Input directory must contain a CT volume series.');
    fprintf('[1] CT loaded: %d×%d×%d  (%.2fs)\n', size(D.vol), timing.dicom_load);

    % --- Whole-result disk cache ---------------------------------------
    % Keyed on the input volume + options, this returns the entire planned
    % result (mask, branch labels, seeds, centerline, plan) without re-
    % running the ~1-min pipeline. The decisive win for an interactive
    % caller: re-opening a planned scan in the GUI (runAutoPipeline) is
    % near-instant. The key checksums the full volume, so a different scan
    % (or different targets/backend) never collides.
    if ~isfield(opts, 'result_cache'); opts.result_cache = true; end
    % Resolve CFA-cap options here too so they can key the result cache
    % (a different cap changes the whole downstream result).
    if ~isfield(opts, 'cap_cfa_at_inguinal'); opts.cap_cfa_at_inguinal = true; end
    if ~isfield(opts, 'cfa_distal_margin_mm'); opts.cfa_distal_margin_mm = 30; end
    % Hoisted ahead of the result-cache key so they can key the cache —
    % both mutate the final mask/labels/plan, so a cache computed with a
    % different value must NOT be reused (perf-2). Their behavioural use
    % is still gated below at first reference.
    if ~isfield(opts, 'use_adaptive_hu_follower'); opts.use_adaptive_hu_follower = true; end
    if ~isfield(opts, 'reconnect_iliac_fragments'); opts.reconnect_iliac_fragments = true; end
    % Distal landing-zone target (2026-06-19, external-iliac reframe / #41).
    %   'cfa'           — legacy: chase the iliac through the thigh to the
    %                     common femoral artery (access vessel). Default for
    %                     backward compatibility; all regression baselines
    %                     are pinned under this mode.
    %   'external_iliac'— clinically-correct EVAR distal SEAL zone. Stops at
    %                     the TS external-iliac terminus (no low-contrast
    %                     thigh chase) and enables the vesselness-path
    %                     reconnect so a TS-fragmented aorta↔iliac still
    %                     yields a spanning centerline.
    if ~isfield(opts, 'distal_target'); opts.distal_target = 'cfa'; end
    opts.distal_target = char(lower(string(opts.distal_target)));
    if ~ismember(opts.distal_target, {'cfa', 'external_iliac'})
        error('run_planner_headless:BadDistalTarget', ...
            'opts.distal_target must be ''cfa'' or ''external_iliac'' (got ''%s'')', opts.distal_target);
    end
    is_eia_target = strcmp(opts.distal_target, 'external_iliac');
    % Vesselness-path reconnect (autoseg.reconnect_via_vesselness_path):
    % defaults ON in external-iliac mode, OFF in legacy mode (regression-safe).
    if ~isfield(opts, 'reconnect_vesselness_path')
        opts.reconnect_vesselness_path = is_eia_target;
    end
    % Segmentation QC accumulator (code-1 / A4). A caught branch- or
    % CFA-extension failure must leave a MACHINE-READABLE signal on the
    % result — not just an stdout line nobody sees in a headless/batch
    % run — so downstream callers and the plan can flag that the iliac/
    % CFA reach was never extended and the sizing rests on a truncated
    % mask.
    seg_qc_warnings = {};
    seg_incomplete  = false;
    result_cache_file = '';
    if opts.result_cache
        rc_dir = fullfile(fileparts(mfilename('fullpath')), '.cache', 'planner_result');
        if ~exist(rc_dir, 'dir'); mkdir(rc_dir); end
        rc_key = struct('sz', size(D.vol), ...
            'chk', mod(sum(double(D.vol(1:97:end))), 2^53 - 1), ...
            'sum', mod(sum(double(D.vol(:))), 2^53 - 1), ...
            'pix', D.pixel_mm(:)', 'ssp', D.slice_spacing_mm, ...
            'targets', {opts.targets}, 'fast', opts.fast, ...
            'backend', opts.centerline_backend, ...
            'cap_cfa', opts.cap_cfa_at_inguinal, ...
            'cfa_margin', opts.cfa_distal_margin_mm, ...
            'adaptive_hu', opts.use_adaptive_hu_follower, ...
            'reconnect', opts.reconnect_iliac_fragments, ...
            'distal_target', opts.distal_target, ...
            'recon_vpath', opts.reconnect_vesselness_path);
        md0 = java.security.MessageDigest.getInstance('MD5');
        hb0 = typecast(md0.digest(uint8(jsonencode(rc_key))), 'uint8');
        rc_hash = lower(reshape(dec2hex(hb0, 2)', 1, []));
        result_cache_file = fullfile(rc_dir, [rc_hash, '_result.mat']);
        if exist(result_cache_file, 'file')
            try
                S_rc = load(result_cache_file);
                out = S_rc.out;
                fprintf('[*] planner result cache HIT: %s\n', result_cache_file);
                return;
            catch ME_rc
                fprintf('[*] planner result cache read failed (%s) — recomputing\n', ME_rc.message);
            end
        end
    end

    % --- Step 2: TotalSegmentator ----
    % We need the FULL multilabel volume for anatomic seed detection
    % (kidney_top anchor), not just the binary aorta+iliac mask.
    t0 = tic;
    ts_opts = struct('targets', {opts.targets}, ...
                     'fast', opts.fast, ...
                     'return_label_volume', true);
    [mask, info] = autoseg.ts_run(D, ts_opts);
    timing.totalseg = toc(t0);
    assert(any(mask(:)), 'run_planner_headless:EmptyMask', ...
        'TS returned an empty mask — aorta/iliac classes missing.');
    fprintf('[2] TS done in %.1fs (cached=%d): %s\n', ...
        timing.totalseg, info.from_cache, strjoin(info.targets_found, ', '));

    % --- Step 3: branch extension (iliacs → CFAs + visceral branches) ----
    t0 = tic;
    seg_uint8 = uint8(info.label_volume);
    label_branch = uint8([]);
    try
        % Use the disk-cached wrapper so a re-run on the same case skips
        % the ~25 s imreconstruct stack. Pass force=true to bypass the
        % cache if you've tuned extend_and_detect_branches and want to
        % see the new output on an already-cached case.
        [m_branch, label_branch, info_b] = autoseg.detect_branches_cached(D, seg_uint8); %#ok<ASGLU>
        mask = mask | m_branch;
    catch ME_b
        fprintf('[3] branch extension failed (%s) — proceeding with raw TS mask\n', ME_b.message);
        seg_qc_warnings{end+1} = sprintf('branch extension failed: %s', ME_b.message); %#ok<AGROW>
        seg_incomplete = true;
    end
    timing.extend = toc(t0);
    fprintf('[3] Iliac/CFA + visceral-branch detection (%.1fs): combined mask %.1f mL\n', ...
        timing.extend, nnz(mask) * D.pixel_mm(1) * D.pixel_mm(2) * D.slice_spacing_mm / 1000);

    % --- Step 3b: extend each side's CFA terminus down to the femoral
    %     level. extend_and_detect_branches truncates at the iliac/CFA
    %     transition because its HU 400-1000 imreconstruct stops on
    %     contrast dropout; slice-by-slice tracking with re-acquire and
    %     a wider HU window reaches the inguinal ligament and beyond.
    t0 = tic;
    if ~isempty(label_branch) && ~is_eia_target
        try
            [mask, label_branch, info_cfa] = autoseg.extend_to_cfa(D, mask, label_branch, struct('verbose', false));
            % Best-effort progress log. The extension itself already
            % succeeded above; a missing/renamed info field here must NOT
            % be mistaken for an extension failure (that previously set
            % seg_incomplete spuriously on a `starting_z` field error).
            try
                fprintf('[3b] CFA extend: L end z=%s (+%d sl); R end z=%s (+%d sl)\n', ...
                    num2str(info_cfa.L.last_z), info_cfa.L.added_slices, ...
                    num2str(info_cfa.R.last_z), info_cfa.R.added_slices);
            catch
                fprintf('[3b] CFA extend: done (some log fields unavailable)\n');
            end
        catch ME_e
            fprintf('[3b] CFA extension failed: %s\n', ME_e.message);
            seg_qc_warnings{end+1} = sprintf('CFA extension failed: %s', ME_e.message); %#ok<AGROW>
            seg_incomplete = true;
        end
    elseif is_eia_target
        fprintf('[3b] external-iliac mode — skipping CFA thigh extension (distal target = ext-iliac seal zone)\n');
    end
    timing.cfa_extend = toc(t0);

    % --- Step 3b': adaptive HU iliac follower ------------------------
    % Use the aorta's own bolus contrast as a per-patient HU reference
    % to grow the iliacs through real pelvis contrast. This catches
    % real iliac voxels that the slice-by-slice walker misses when the
    % contrast cross-section is partially-volumed with adjacent vein /
    % calcium (the walker's roundness + size criteria reject those
    % merged CCs even though they contain the arterial bolus).
    %
    % Strictly bridge-free: only paints voxels that ALREADY have
    % bolus-grade HU in the source CT. No synthetic tubes through
    % tissue. Region-grow restricted to the pelvis (z >= bifurc - 30 mm).
    if ~isfield(opts, 'use_adaptive_hu_follower'); opts.use_adaptive_hu_follower = true; end
    if opts.use_adaptive_hu_follower && ~isempty(label_branch)
        t0 = tic;
        try
            [mask, info_adaptive] = autoseg.follow_iliacs_adaptive(D, mask, label_branch, ...
                struct('verbose', false));
            if isfield(info_adaptive, 'hu_window') && opts.verbose
                fprintf('[3b''] Adaptive HU follower: window [%.0f, %.0f] HU (bolus %.0f ± %.0f), grew to %d voxels (R z=%d..%d, L z=%d..%d)\n', ...
                    info_adaptive.hu_window(1), info_adaptive.hu_window(2), ...
                    info_adaptive.bolus_peak_hu, info_adaptive.bolus_std_hu, ...
                    nnz(mask), info_adaptive.R_z_extent(1), info_adaptive.R_z_extent(2), ...
                    info_adaptive.L_z_extent(1), info_adaptive.L_z_extent(2));
            end
        catch ME_a
            fprintf('[3b''] Adaptive HU follower failed: %s\n', ME_a.message);
        end
        timing.adaptive_hu_follower = toc(t0);
    end

    % --- Step 3c: HU-based connectivity restore (no bridges) --------
    %     On well-opacified arterial-phase CTA, the aorta + iliacs +
    %     CFAs form a continuous contrast tube. TS sometimes labels
    %     these segments as separate 3D-CCs because its lumen
    %     segmentation has small inter-label gaps at the bifurcation
    %     or at branch points. Earlier we tried to paint synthetic
    %     "bridges" between disconnected CCs — that produced
    %     anatomically impossible straight tubes through tissue, so
    %     it's banned.
    %
    %     Instead: GROW the existing TS-derived mask through actual
    %     CT contrast voxels (HU 150-1400), constrained to a thin
    %     shell around the TS labels (5 mm) so the grow can't leak
    %     into kidneys / liver / IVC. `imreconstruct` only includes
    %     voxels that are 26-connected to the seed mask through the
    %     contrast — no synthetic voxels are introduced. If the
    %     contrast IS continuous through the bifurcation (the normal
    %     case on a CTA), the aorta-CC and iliac-CC naturally merge.
    %     If the contrast actually has a gap, the mask stays
    %     disconnected and the downstream centerline step will flag
    %     it — no phantom anatomy is invented.
    t0 = tic;
    if ~isempty(D) && isfield(D, 'vol') && ~isempty(D.vol) && any(mask(:))
        % Grow the TS-derived mask through actual CT contrast within a
        % 5-mm shell (HU 150-1400, in-plane size-capped so it can't leak
        % into cancellous marrow / IVC / bowel). The helper crops the work
        % to the mask's bounding box + shell radius, so the several
        % full-resolution boolean volumes are only allocated over the
        % sub-volume the vessels occupy — bit-identical output, far less
        % memory on large-FOV / runoff CTA (GOALS #39). No synthetic voxels
        % are added; the new voxels stay label 0 (interior to existing
        % labeled regions, so the SE(3) audit + side-stamping still work).
        pix_mm = abs(D.pixel_mm(1));
        [grown, hr_info] = autoseg.hu_reconstruct_shell(mask, D.vol, ...
            struct('pix_mm', pix_mm));
        n_added = hr_info.n_added;
        mask = grown;
        if opts.verbose
            cc_after = bwconncomp(grown, 26);
            fprintf(['[3c] HU-reconstruct: +%d vox (shell %d vox = %.1f mm; ' ...
                     'crop %.0f%% of FOV); %d 3D-CCs\n'], ...
                n_added, hr_info.shell_r, hr_info.shell_r * pix_mm, ...
                100 * hr_info.crop_frac, cc_after.NumObjects);
        end
    end
    timing.hu_reconstruct = toc(t0);

    % --- Step 3c': reconnect fragmented iliac / CFA segments -----------
    %     The single-pass HU-reconstruct above only reaches ~one shell
    %     radius beyond the existing mask, so a DISTAL iliac/CFA that TS +
    %     the walker labelled as a string of in-plane-staggered fragments
    %     (each present on its own slice but not 26-connected to its
    %     neighbours — no z-gap, pure in-plane offset) stays split, and
    %     step 6b's keep-largest-CC then drops the whole distal string.
    %     This was the JohnDoe1 right-CFA truncation: the centerline stopped
    %     87 mm short of the FOV bottom. Iterating the shell flood — i.e.
    %     rebuilding the tube around the GROWING mask each pass — lets the
    %     grow crawl fragment-to-fragment along the genuine contrast that
    %     already bridges them, while the per-slice vessel-area cap + shell
    %     confinement + pelvis z-restriction keep it bridge-free and
    %     leak-safe (only adds voxels that already carry bolus-grade HU).
    t0 = tic;
    if ~isfield(opts, 'reconnect_iliac_fragments'); opts.reconnect_iliac_fragments = true; end
    if opts.reconnect_iliac_fragments && isfield(D, 'vol') && ~isempty(D.vol) && any(mask(:))
        % Pelvis floor: 40 mm cranial of the iliac-label top (labels 2-5 =
        % iliacs + CFA extension). Falls back to the lower half of the
        % volume if the branch labels are unavailable.
        z_lo = round(size(D.vol, 3) / 2);
        if exist('label_branch', 'var') && ~isempty(label_branch)
            iliac_top = find(squeeze(any(any(ismember(label_branch, [2 3 4 5]), 1), 2)), 1, 'first');
            if ~isempty(iliac_top)
                z_lo = max(1, iliac_top - round(40 / abs(D.slice_spacing_mm)));
            end
        end
        try
            % The function logs its own reason line when verbose; capture
            % info for the timing/telemetry struct but no duplicate print.
            % NOTE: extending the reconnect reach (max_iters/shell) or
            % loosening its HU floor was investigated for the JohnDoe4
            % aorta→iliac gap and does NOT help — the gap is a genuine
            % low-contrast (~100-150 HU) break, so a wider/looser crawl
            % either still can't cross it (HU≥150) or leaks into veins
            % and destroys the centerline (HU≥100). The robust fix is a
            % learned vessel segmentation (GOALS #26), not param tuning,
            % so the defaults are kept.
            [mask, info_recon] = autoseg.reconnect_vessel_fragments(D, mask, ...
                struct('z_lo', z_lo, 'verbose', opts.verbose));
            timing.reconnect_info = info_recon;
        catch ME_rc
            fprintf('[3c''] iliac reconnection failed: %s\n', ME_rc.message);
        end
    end
    timing.reconnect_fragments = toc(t0);

    % --- Step 3c'': vesselness-path reconnect (external-iliac mode) -----
    %     The shell flood (3c') only reaches ~one shell radius and CANNOT
    %     cross the aorta↔iliac break TS leaves on harder cases (JohnDoe4):
    %     a HU≥150 crawl misses the partial-volume span, HU≥100 leaks into
    %     veins and collapses the centerline. Instead, route the MINIMUM-
    %     COST path through a vesselness+intensity cost between the aorta CC
    %     and each iliac fragment, and add only the genuine contrast along
    %     it (median ~290 HU, ~86% ≥150 HU on JohnDoe4). A path that cannot
    %     ride contrast fails the quality gate and the fragment is left
    %     disconnected (reported) — no tube is forced through tissue, so
    %     the operator's no-bridge rule holds. Off in legacy 'cfa' mode.
    t0 = tic;
    if opts.reconnect_vesselness_path && isfield(D, 'vol') && ~isempty(D.vol) && any(mask(:))
        z_lo_vp = round(size(D.vol, 3) / 2);
        if exist('label_branch', 'var') && ~isempty(label_branch)
            iliac_top_vp = find(squeeze(any(any(ismember(label_branch, [2 3 4 5]), 1), 2)), 1, 'first');
            if ~isempty(iliac_top_vp)
                z_lo_vp = max(1, iliac_top_vp - round(40 / abs(D.slice_spacing_mm)));
            end
        end
        try
            [mask, info_vpath] = autoseg.reconnect_via_vesselness_path(D, mask, ...
                struct('z_lo', z_lo_vp, 'verbose', opts.verbose));
            timing.reconnect_vpath_info = info_vpath;
            n_acc = 0; if ~isempty(info_vpath.paths), n_acc = nnz([info_vpath.paths.accepted]); end
            if ~any([info_vpath.paths.accepted]) && info_vpath.cc_before > 1
                seg_qc_warnings{end+1} = sprintf(['vesselness-path reconnect found ' ...
                    'no vessel-riding path for %d fragment(s)'], info_vpath.cc_before - 1); %#ok<AGROW>
            end
            if opts.verbose
                fprintf('[3c''''] vesselness-path reconnect: %d CCs→%d, %d path(s) accepted, +%d vox\n', ...
                    info_vpath.cc_before, info_vpath.cc_after, n_acc, info_vpath.added_voxels);
            end
        catch ME_vp
            fprintf('[3c''''] vesselness-path reconnect failed: %s\n', ME_vp.message);
            seg_qc_warnings{end+1} = sprintf('vesselness-path reconnect failed: %s', ME_vp.message); %#ok<AGROW>
        end
    end
    timing.reconnect_vpath = toc(t0);

    % --- Step 4: supraceliac crop — keep mask only from 5 cm above the
    %     celiac trunk downward. EVAR planning doesn't need the thoracic
    %     aorta or arch.
    t0 = tic;
    if ~isempty(label_branch) && any(label_branch(:) == 8)
        celiac_top_z = find(squeeze(any(any(label_branch == 8, 1), 2)), 1, 'first');
        target_top_z = max(1, celiac_top_z - round(50 / D.slice_spacing_mm));
        n_before = nnz(mask);
        mask(:, :, 1:target_top_z-1) = false;
        if ~isempty(label_branch)
            label_branch(:, :, 1:target_top_z-1) = 0;
        end
        fprintf('[4] Supraceliac crop: kept z>=%d (celiac top z=%d), dropped %d vox\n', ...
            target_top_z, celiac_top_z, n_before - nnz(mask));
    else
        fprintf('[4] No celiac label — skipping supraceliac crop\n');
    end
    timing.supraceliac_crop = toc(t0);

    % --- Step 4b: distal CFA cap (stop at the common femoral artery) --
    %     extend_to_cfa + the adaptive follower deliberately walk the
    %     iliac/CFA mask all the way to the FOV bottom, which overshoots
    %     the CFA into the SFA / profunda (deep femoral). For EVAR the
    %     distal landing zone is the COMMON femoral, so cap the mask at
    %     ~3 cm below the inguinal ligament (mid-CFA). The inguinal
    %     ligament ≈ the caudal terminus of the TS external-iliac label
    %     (iliac_artery_left=65 / iliac_artery_right=66). TS can lose one
    %     side early (asymmetric, undersegmented), so we take the DEEPER
    %     (more caudal) confident terminus as the bilateral inguinal level
    %     rather than a per-side terminus — a 6 cm L/R asymmetry is a TS
    %     artefact, not anatomy. Capping the mask here makes the auto-seed
    %     CFA endpoints (most-caudal labeled slice) land at the CFA and
    %     the centerline terminate there. Trims SFA/profunda from both.
    if ~isfield(opts, 'cap_cfa_at_inguinal'); opts.cap_cfa_at_inguinal = true; end
    if ~isfield(opts, 'cfa_distal_margin_mm'); opts.cfa_distal_margin_mm = 30; end
    t0 = tic;
    if opts.cap_cfa_at_inguinal
        ssp_cfa = abs(D.slice_spacing_mm);
        il_l = squeeze(sum(sum(seg_uint8 == 65, 1), 2));
        il_r = squeeze(sum(sum(seg_uint8 == 66, 1), 2));
        zL = find(il_l >= 15, 1, 'last');
        zR = find(il_r >= 15, 1, 'last');
        inguinal_z = max([zL; zR]);   % deeper confident terminus
        % In external-iliac mode the distal SEAL zone IS the ext-iliac
        % terminus — cap there with only a small margin (don't extend the
        % extra ~3 cm into the common femoral, which is access, not seal).
        eff_cap_margin_mm = opts.cfa_distal_margin_mm;
        if is_eia_target, eff_cap_margin_mm = min(eff_cap_margin_mm, 5); end
        if ~isempty(inguinal_z)
            cfa_z = min(size(mask, 3), inguinal_z + round(eff_cap_margin_mm / ssp_cfa));
            n_before = nnz(mask);
            mask(:, :, cfa_z+1:end) = false;
            if ~isempty(label_branch)
                label_branch(:, :, cfa_z+1:end) = 0;
            end
            fprintf(['[4b] distal cap (%s): ext-iliac terminus z=%d, ' ...
                'kept z<=%d (+%.0f mm), trimmed %d distal vox\n'], ...
                opts.distal_target, inguinal_z, cfa_z, eff_cap_margin_mm, n_before - nnz(mask));
        else
            fprintf('[4b] CFA cap: no TS external-iliac terminus found — skipping\n');
        end
    end
    timing.cfa_cap = toc(t0);

    % --- Step 5: audit segmentation before centerline ---
    t0 = tic;
    audit = autoseg.audit_segmentation(mask, ...
        struct('ts_labels', seg_uint8, 'branch_labels', label_branch), D);
    timing.audit = toc(t0);
    fprintf('[5] Segmentation audit (%.1fs): passed=%d\n', timing.audit, audit.passed);
    for k = 1:numel(audit.blocks)
        bb = audit.blocks{k};
        tag = {'[OK]', '[WARN]', '[FAIL]'};
        fprintf('     %s %s\n', tag{bb.severity+1}, bb.name);
    end
    if ~audit.passed
        warning('run_planner_headless:AuditFailed', ...
            'Segmentation audit FAILED — proceeding anyway in headless mode but plan output should not be trusted.');
    end

    % --- Step 6: anatomic auto-seeds (uses celiac anchor) ---
    t0 = tic;
    seeds = preprocess.auto_seeds_anatomic(seg_uint8, D, struct(), label_branch);
    timing.autoseed = toc(t0);
    if ~seeds.ok
        ME = MException('run_planner_headless:SeedFailed', ...
            'Auto-seed detection failed: %s', jsonencode(seeds.diagnostic));
        throw(ME);
    end
    fprintf('[6] Auto-seeds (%.2fs):\n', timing.autoseed);
    fprintf('    proximal  [y x z] = %s   (anchor: %s)\n', ...
        mat2str(seeds.proximal), seeds.diagnostic.anchor);
    fprintf('    right_cfa [y x z] = %s\n', mat2str(seeds.right_cfa));
    fprintf('    left_cfa  [y x z] = %s\n', mat2str(seeds.left_cfa));

    % --- Step 6b: keep only the largest 3D-CC of the mask and snap
    %     the proximal seed onto it. On some patients (e.g. JohnDoe2),
    %     TS labels the thoracic aorta as its own 3D-CC, disconnected
    %     from the abdominal aorta + iliacs + CFA extensions. The
    %     auto-seeds fallback (kidney_top − 70 mm) then placed the
    %     proximal seed inside the THORACIC fragment, and the skeleton
    %     graph had no path to the CFAs in the abdominal CC. Keeping
    %     only the largest CC drops the floating fragments, and
    %     snap_seed_to_largest_cc walks the proximal seed down to the
    %     cranial-most voxel of the largest CC if it lands outside.
    t0 = tic;
    % HU filter — ONLY applied to TS aorta voxels (label 1). TS-fast
    % over-segments the aortic wall + perivascular tissue (30% of
    % label-1 voxels had HU < 50 on JohnDoe2). Drop those without
    % touching the iliac (labels 2-3), CFA extension (labels 4-5),
    % or other branch labels: those went through downstream HU-
    % checked steps (the walker rejects low-HU voxels, the bridge is
    % HU-gated). Applying the filter to ALL labels was too aggressive
    % — on JohnDoe1 it shortened the R iliac landing zone from 306 mm
    % to 142 mm by trimming partial-volume edges in the CFA
    % extension where the walker had legitimately painted at edge HU.
    n_before_hu = nnz(mask);
    if isfield(D, 'vol') && ~isempty(D.vol) && exist('label_branch', 'var') ...
            && ~isempty(label_branch)
        is_aorta = (label_branch == 1);
        bad_aorta = is_aorta & (D.vol < 100);
        mask = mask & ~bad_aorta;
    end
    if opts.verbose
        fprintf('[6b] HU>=100 filter on TS aorta only: %d → %d vox (dropped %d soft-tissue voxels)\n', ...
            n_before_hu, nnz(mask), n_before_hu - nnz(mask));
    end
    cc_full = bwconncomp(mask, 26);
    sizes_cc = cellfun(@numel, cc_full.PixelIdxList);
    [~, k_big] = max(sizes_cc);
    if cc_full.NumObjects > 1
        % Keep the largest CC AND any CC that carries a target-vessel
        % branch label (iliac 2/3, CFA 4/5). This step exists to drop a
        % floating THORACIC-aorta fragment (label 1 / unlabeled — the
        % JohnDoe2 case), which by construction has no iliac/CFA label and
        % is still dropped. But it must NOT discard a real, segmented
        % iliac/CFA fragment the reconnect step couldn't merge: on JohnDoe4
        % the caudal right iliac/CFA (labeled down to z≈597) was a separate
        % CC and got silently dropped, truncating the mask at z≈315 and
        % collapsing the centerline. A retained-but-disconnected vessel is
        % strictly better than a discarded one — the centerline_implausible
        % QC still flags a non-spanning result, but we never throw real
        % anatomy away (and a downstream reconnect/centerline pass can use
        % it). No synthetic voxels are added here.
        keep = false(cc_full.NumObjects, 1);
        keep(k_big) = true;
        if exist('label_branch', 'var') && ~isempty(label_branch)
            vessel_lbl = ismember(label_branch, [2 3 4 5]);
            for c = 1:cc_full.NumObjects
                if ~keep(c) && any(vessel_lbl(cc_full.PixelIdxList{c}))
                    keep(c) = true;
                end
            end
        end
        mask_keep = false(size(mask));
        for c = find(keep)'
            mask_keep(cc_full.PixelIdxList{c}) = true;
        end
        n_drop = nnz(mask) - nnz(mask_keep);
        if opts.verbose
            fprintf(['[6b] Mask had %d 3D-CCs; kept largest + %d vessel-labeled ' ...
                     'fragment(s) (%d vox), dropped %d vox in %d fragment(s)\n'], ...
                cc_full.NumObjects, sum(keep) - 1, nnz(mask_keep), n_drop, ...
                cc_full.NumObjects - sum(keep));
        end
        mask = mask_keep;
    end
    [seeds.proximal, snapped_prox]   = snap_seed_to_largest_cc(seeds.proximal, mask);
    [seeds.right_cfa, snapped_R_cfa] = snap_seed_to_largest_cc(seeds.right_cfa, mask);
    [seeds.left_cfa, snapped_L_cfa]  = snap_seed_to_largest_cc(seeds.left_cfa, mask);
    if opts.verbose && (snapped_prox || snapped_R_cfa || snapped_L_cfa)
        fprintf('[6b] Seeds snapped to largest CC: proximal=%d R_CFA=%d L_CFA=%d (%.2fs)\n', ...
            snapped_prox, snapped_R_cfa, snapped_L_cfa, toc(t0));
    end

    % --- Orientation guard (#36): femorals must be at the bottom -------
    % The femoral (CFA) endpoints must be caudal to the proximal seed in
    % the cranial-first volume. If not, the series is flipped (and the
    % visceral-band detection — which assumes cranial-first — would be
    % silently wrong). Flag it machine-readably rather than mis-segment.
    cc_known = ~isfield(D, 'craniocaudal_known') || D.craniocaudal_known;
    [orientation_suspect, orient_msg] = autoseg.orientation_is_suspect(seeds, cc_known);
    if orientation_suspect
        fprintf('[QC] %s\n', orient_msg);
        seg_qc_warnings{end+1} = orient_msg; %#ok<AGROW>
    end

    % --- Step 7: bifurcated centerline ----
    % VMTK (Voronoi/fast-marching) is preferred — matches TeraRecon's
    % algorithm. Falls back to the MATLAB skeleton-graph path when VMTK
    % is unavailable or the call fails.
    centerline_used = '';
    Pv_mm_right = []; R_mm_right = []; Pv_mm_left = []; R_mm_left = [];
    use_vmtk = false;
    switch opts.centerline_backend
        case 'auto'
            vinfo = vmtk_centerline.detect();
            use_vmtk = vinfo.available;
        case 'vmtk'
            use_vmtk = true;   % errors below if unavailable
        case 'matlab'
            use_vmtk = false;
        otherwise
            error('run_planner_headless:bad_backend', ...
                  'opts.centerline_backend must be ''auto'', ''vmtk'', or ''matlab''.');
    end

    % Patient-mm seeds: needed both for the saved output and (below) for
    % the VMTK degeneracy retry test.
    seeds_mm = struct();
    seeds_mm.proximal  = voxel_to_mm(seeds.proximal,  D);
    seeds_mm.right_cfa = voxel_to_mm(seeds.right_cfa, D);
    seeds_mm.left_cfa  = voxel_to_mm(seeds.left_cfa,  D);

    % --- Optional centerline disk cache --------------------------------
    % VMTK's Voronoi/fast-marching pass is the slow step (~1 min). Cache
    % the resulting polylines keyed by (mask geometry, seeds, backend) so
    % a re-run on the same case — e.g. the GUI re-opening a planned scan,
    % or the one-click runAutoPipeline — is instant. The key includes
    % nnz(mask) + a voxel checksum, so ANY change to the segmentation
    % invalidates the cache (no stale centerline on an edited mask).
    if ~isfield(opts, 'centerline_cache'); opts.centerline_cache = true; end
    cl_cache_hit  = false;
    cl_cache_file = '';
    if opts.centerline_cache
        cl_cache_dir = fullfile(fileparts(mfilename('fullpath')), '.cache', 'centerline');
        if ~exist(cl_cache_dir, 'dir'); mkdir(cl_cache_dir); end
        idx_lin = find(mask);
        cl_key = struct('sz', size(mask), 'nnz', numel(idx_lin), ...
            'chk', mod(sum(idx_lin), 2^53 - 1), ...
            'sp', seeds.proximal(:)', 'sr', seeds.right_cfa(:)', ...
            'sl', seeds.left_cfa(:)', 'backend', opts.centerline_backend);
        md = java.security.MessageDigest.getInstance('MD5');
        hb = typecast(md.digest(uint8(jsonencode(cl_key))), 'uint8');
        cl_hash = lower(reshape(dec2hex(hb, 2)', 1, []));
        cl_cache_file = fullfile(cl_cache_dir, [cl_hash, '_cl.mat']);
        if exist(cl_cache_file, 'file')
            try
                C = load(cl_cache_file);
                Pv_mm_right = C.Pv_mm_right; R_mm_right = C.R_mm_right;
                Pv_mm_left  = C.Pv_mm_left;  R_mm_left  = C.R_mm_left;
                centerline_used = C.centerline_used;
                timing.centerline = 0;
                cl_cache_hit = true;
                fprintf('[7] centerline cache HIT (%s): %s\n', centerline_used, cl_cache_file);
            catch ME_clc
                fprintf('[7] centerline cache read failed (%s) — recomputing\n', ME_clc.message);
            end
        end
    end

    if ~cl_cache_hit && use_vmtk
        t0 = tic;
        try
            vopts = struct('keep_work', false);
            cl = vmtk_centerline.compute(mask, seeds.proximal, ...
                seeds.right_cfa, seeds.left_cfa, D, vopts);
            % A thin (1–2 voxel) reconnection bridge can keep the mask a
            % single VOLUME 26-CC yet get pinched off the *decimated*
            % SURFACE mesh, splitting it so vmtkcenterlines can't route
            % source→distal target — one branch collapses to a degenerate
            % 2-node polyline (arc 0 mm). Detect that and retry WITHOUT
            % decimation (reduce=0): the bridge survives mesh generation.
            % reduce=0 is radius-safe (no mask inflation, unlike imclose),
            % so the clinical diameters in evar_measurements stay honest —
            % it is only slower, which is fine for a one-shot planner run.
            if vmtk_branch_degenerate(cl, seeds_mm)
                fprintf(['[7] VMTK centerline degenerate at reduce=0.5 ' ...
                    '(thin-bridge surface pinch) — retrying reduce=0.0.\n']);
                vopts.reduce = 0.0;
                cl = vmtk_centerline.compute(mask, seeds.proximal, ...
                    seeds.right_cfa, seeds.left_cfa, D, vopts);
            end
            Pv_mm_right = cl.Pv_mm_right;  R_mm_right = cl.R_mm_right;
            Pv_mm_left  = cl.Pv_mm_left;   R_mm_left  = cl.R_mm_left;
            timing.centerline = toc(t0);
            centerline_used = 'vmtk';
            fprintf('[7] VMTK centerline (%.1fs):\n', timing.centerline);
        catch ME_vmtk
            if strcmp(opts.centerline_backend, 'vmtk')
                rethrow(ME_vmtk);
            end
            fprintf('[7] VMTK failed (%s) — falling back to MATLAB skeleton.\n', ME_vmtk.message);
            use_vmtk = false;
        end
    end
    if ~cl_cache_hit && ~use_vmtk
        t0 = tic;
        S = preprocess.build_skeleton_graph(mask, ...
            struct('min_branch_length', 20, ...
                   'min_radius_vox', opts.min_radius_vox, ...
                   'radius_weight_pow', 2));
        fprintf('[7] Skeleton: %d voxels, %d edges (%.1fs)\n', ...
            size(S.voxels, 1), numedges(S.graph), toc(t0));
        timing.skeleton = toc(t0);

        t0 = tic;
        [Pv_right_vox, R_right_vox, info_R] = preprocess.centerline_seeds( ...
            S, [seeds.proximal; seeds.right_cfa]); %#ok<ASGLU>
        [Pv_left_vox,  R_left_vox,  info_L] = preprocess.centerline_seeds( ...
            S, [seeds.proximal; seeds.left_cfa]);  %#ok<ASGLU>
        timing.centerline = toc(t0);

        [Pv_mm_right, R_mm_right] = preprocess.centerline_to_mm(Pv_right_vox, R_right_vox, D);
        [Pv_mm_left,  R_mm_left]  = preprocess.centerline_to_mm(Pv_left_vox,  R_left_vox,  D);
        centerline_used = 'matlab';
    end

    % Persist the freshly computed centerline so the next run on this exact
    % mask + seeds is instant.
    if opts.centerline_cache && ~cl_cache_hit && ~isempty(cl_cache_file) ...
            && ~isempty(Pv_mm_right)
        try
            save(cl_cache_file, 'Pv_mm_right', 'R_mm_right', ...
                'Pv_mm_left', 'R_mm_left', 'centerline_used');
            fprintf('[7] centerline cached → %s\n', cl_cache_file);
        catch ME_clw
            fprintf('[7] centerline cache write failed: %s\n', ME_clw.message);
        end
    end

    arc_R = sum(vecnorm(diff(Pv_mm_right, 1, 1), 2, 2));
    arc_L = sum(vecnorm(diff(Pv_mm_left,  1, 1), 2, 2));
    fprintf('[4] Centerlines (%s, %.1fs):\n', centerline_used, timing.centerline);
    fprintf('    right branch: %d nodes, arc %.1f mm, R median %.1f mm\n', ...
        size(Pv_mm_right,1), arc_R, median(R_mm_right));
    fprintf('    left  branch: %d nodes, arc %.1f mm, R median %.1f mm\n', ...
        size(Pv_mm_left,1),  arc_L, median(R_mm_left));

    % --- Save artefacts (seeds_mm computed above, before the VMTK call) ---
    out = struct('seeds', seeds, 'seeds_mm', seeds_mm, ...
                 'mask', mask, ...
                 'Pv_mm_right', Pv_mm_right, 'R_mm_right', R_mm_right, ...
                 'Pv_mm_left',  Pv_mm_left,  'R_mm_left',  R_mm_left, ...
                 'arc_R_mm', arc_R, 'arc_L_mm', arc_L, ...
                 'centerline_backend', centerline_used, ...
                 'timing', timing, ...
                 'out_dir', opts.out_dir, ...
                 'ts_info', info);
    % Branch label volume (1=aorta, 2/3=iliacs, 4/5=CFAs, 6/7=renals,
    % 8=celiac, 9=SMA) — needed by the GUI to render each branch in its
    % own color and to anchor auto-seeds. Carried out so a GUI caller
    % that passed opts.D gets a self-contained, displayable result.
    if exist('label_branch', 'var'); out.label_branch = label_branch; end
    out.D = D;
    if exist('audit', 'var'); out.audit = audit; end
    % Centerline plausibility QC. A real proximal-aorta → CFA centerline
    % spans several hundred mm per side; a sub-threshold arc means the
    % segmentation never connected aorta → CFA (mask fragmentation or a
    % collapsed VMTK path), so the "completed" plan rests on a stub and
    % every measurement is unreliable. Caught on the JohnDoe4/JohnDoe5
    % cases where arcs came out 0-77 mm instead of ~600 mm.
    % Threshold is target-aware: a CFA span runs aorta→groin (~350-600 mm),
    % an external-iliac span stops at the inguinal level (~250-380 mm), so
    % the EIA floor is lower to avoid false-flagging a valid, shorter span.
    if is_eia_target, min_plausible_arc_mm = 150; else, min_plausible_arc_mm = 200; end
    % Per-side QC: an EIA-mode result can legitimately succeed on one side
    % and fail on the other (TS under-segmented one iliac). Flag each side
    % so a downstream caller can trust the good side rather than discarding
    % the whole plan. The overall flag stays = ANY side implausible (legacy
    % contract), but per-side detail is carried on out.qc.
    implausible_R = arc_R < min_plausible_arc_mm;
    implausible_L = arc_L < min_plausible_arc_mm;
    centerline_implausible = implausible_R || implausible_L;
    if centerline_implausible
        if is_eia_target && (implausible_R ~= implausible_L)
            bad = 'L'; good_arc = arc_R; bad_arc = arc_L;
            if implausible_R, bad = 'R'; good_arc = arc_L; bad_arc = arc_R; end
            msg = sprintf(['centerline spans on one side only (good arc %.0f mm; ' ...
                '%s side %.0f mm < %.0f) — TS likely under-segmented the %s iliac; ' ...
                'the good side is usable, the %s landing zone is not.'], ...
                good_arc, bad, bad_arc, min_plausible_arc_mm, bad, bad);
        else
            msg = sprintf(['centerline implausibly short (R %.0f / L %.0f mm; ' ...
                'expected several hundred mm) — segmentation likely did not connect ' ...
                'aorta to the iliacs; measurements are unreliable.'], arc_R, arc_L);
        end
        fprintf('[QC] WARNING: %s\n', msg);
        seg_qc_warnings{end+1} = msg; %#ok<AGROW>
    end

    % Segmentation QC (code-1 / A4): machine-readable signal that an
    % extension step was caught, the orientation is suspect, or the
    % centerline is implausibly short — the plan must not be trusted.
    out.qc = struct('segmentation_incomplete', seg_incomplete, ...
                    'orientation_suspect', orientation_suspect, ...
                    'centerline_implausible', centerline_implausible, ...
                    'centerline_implausible_R', implausible_R, ...
                    'centerline_implausible_L', implausible_L, ...
                    'min_plausible_arc_mm', min_plausible_arc_mm, ...
                    'distal_target', opts.distal_target, ...
                    'warnings', {seg_qc_warnings});
    % Single aggregate verdict: usable=false if ANY hard check failed, so
    % callers (plan text, batch CSV, GUI) can gate on one field instead of
    % re-deriving the logic. The plan generator surfaces this as an explicit
    % "do not trust" banner (see evar_plan.generate_plan).
    [out.qc.usable, out.qc.summary] = autoseg.qc_summary(out.qc);
    if seg_incomplete
        fprintf(['[QC] WARNING: segmentation incomplete (%d extension failure(s)); ' ...
                 'sizing rests on a truncated mask.\n'], numel(seg_qc_warnings));
    end

    % --- Step 8: derive EVAR sizing + IFU match -------------------------
    % Compose the structured plan so callers (benchmark runner, batch
    % runner, downstream UI) get the same measurements + device verdict
    % the GUI's IFU button would produce.
    try
        plan = evar_plan.generate_plan(out, struct( ...
            'verbose', false, ...
            'write_file', fullfile(opts.out_dir, 'plan')));
        out.plan = plan;
        fprintf('[8] EVAR plan: neck lumen Ø %.1f mm / L %.1f mm / ∠β %.0f°; iliac lumen R Ø %.1f mm, L Ø %.1f mm\n', ...
            field_or_nan(plan.measurements, 'neck_diameter_mm'), ...
            field_or_nan(plan.measurements, 'neck_length_mm'), ...
            field_or_nan(plan.measurements, 'neck_angulation_deg'), ...
            field_or_nan(plan.measurements, 'iliac_R_diameter_mm'), ...
            field_or_nan(plan.measurements, 'iliac_L_diameter_mm'));
    catch ME_plan
        fprintf('[8] EVAR plan generation failed: %s\n', ME_plan.message);
    end

    save(fullfile(opts.out_dir, 'planner_result.mat'), '-struct', 'out', '-v7.3');
    fprintf('[5] Saved planner_result.mat\n');

    % Populate the whole-result cache so the next run on this exact scan
    % (e.g. the GUI re-opening it) returns instantly.
    if opts.result_cache && ~isempty(result_cache_file)
        try
            % Drop the full CT volume from the ON-DISK copy only — it is
            % ~600 MB and every cache-hit caller already has the volume
            % (the GUI holds app.D; an opts.D caller passed it; the cache
            % key is derived from it). The returned `out` is left intact.
            out_disk = out; %#ok<NASGU>
            if isfield(out_disk, 'D') && isstruct(out_disk.D) && isfield(out_disk.D, 'vol')
                out_disk.D.vol = [];
            end
            sv = struct('out', out_disk);
            save(result_cache_file, '-struct', 'sv', '-v7.3');
            fprintf('[*] planner result cached → %s\n', result_cache_file);
        catch ME_rcw
            fprintf('[*] planner result cache write failed: %s\n', ME_rcw.message);
        end
    end

    % --- QC figure ----
    fig = figure('Visible', 'off', 'Color', 'w', 'Position', [50 50 1400 900]);
    tl = tiledlayout(fig, 2, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
    title(tl, sprintf('Headless EVAR planner — arc_R %.0f mm, arc_L %.0f mm', ...
        arc_R, arc_L), 'FontWeight', 'bold');

    silhouette = squeeze(max(D.vol > -200, [], 1)).';
    co_mip     = squeeze(max(mask, [], 1)).';
    nexttile(tl, 1);
    imagesc(silhouette * 0.3 + double(co_mip) * 0.7);
    colormap(gca, [1 1 1; 0.90 0.90 0.92; 0.55 0.55 0.65; 1.0 0.55 0.20]);
    axis image off; hold on;
    plot(seeds.proximal(2),  seeds.proximal(3),  'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
    plot(seeds.right_cfa(2), seeds.right_cfa(3), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
    plot(seeds.left_cfa(2),  seeds.left_cfa(3),  'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 8);
    % Voxel-space polylines only exist on the MATLAB skeleton-graph
    % backend; the VMTK backend (default) returns mm polylines only. Guard
    % the overlay so the QC figure renders on both paths.
    have_vox = exist('Pv_right_vox', 'var') && exist('Pv_left_vox', 'var') ...
        && ~isempty(Pv_right_vox) && ~isempty(Pv_left_vox);
    if have_vox
        plot(Pv_right_vox(:,2), Pv_right_vox(:,3), 'r-', 'LineWidth', 1.4);
        plot(Pv_left_vox(:,2),  Pv_left_vox(:,3),  'b-', 'LineWidth', 1.4);
    end
    title('Coronal — auto seeds + bifurcated centerline');

    silhouette_sa = squeeze(max(D.vol > -200, [], 2)).';
    sa_mip = squeeze(max(mask, [], 2)).';
    nexttile(tl, 2);
    imagesc(silhouette_sa * 0.3 + double(sa_mip) * 0.7);
    colormap(gca, [1 1 1; 0.90 0.90 0.92; 0.55 0.55 0.65; 1.0 0.55 0.20]);
    axis image off; hold on;
    plot(seeds.proximal(1),  seeds.proximal(3),  'go', 'MarkerFaceColor', 'g', 'MarkerSize', 8);
    plot(seeds.right_cfa(1), seeds.right_cfa(3), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 8);
    plot(seeds.left_cfa(1),  seeds.left_cfa(3),  'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 8);
    if have_vox
        plot(Pv_right_vox(:,1), Pv_right_vox(:,3), 'r-', 'LineWidth', 1.4);
        plot(Pv_left_vox(:,1),  Pv_left_vox(:,3),  'b-', 'LineWidth', 1.4);
    end
    title('Sagittal');

    nexttile(tl, 3);
    arc_r = [0; cumsum(vecnorm(diff(Pv_mm_right,1,1),2,2))];
    arc_l = [0; cumsum(vecnorm(diff(Pv_mm_left,1,1),2,2))];
    plot(arc_r, R_mm_right, 'r-', 'LineWidth', 1.4); hold on;
    plot(arc_l, R_mm_left,  'b-', 'LineWidth', 1.4);
    grid on; xlabel('arc s (mm)'); ylabel('R (mm)');
    legend('right branch', 'left branch', 'Location', 'best');
    title('Lumen radius vs arc length');

    nexttile(tl, [1 3]);
    plot3(Pv_mm_right(:,1), Pv_mm_right(:,2), Pv_mm_right(:,3), 'r-', 'LineWidth', 1.8); hold on;
    plot3(Pv_mm_left(:,1),  Pv_mm_left(:,2),  Pv_mm_left(:,3),  'b-', 'LineWidth', 1.8);
    plot3(seeds_mm.proximal(1),  seeds_mm.proximal(2),  seeds_mm.proximal(3),  'go', 'MarkerFaceColor', 'g', 'MarkerSize', 10);
    plot3(seeds_mm.right_cfa(1), seeds_mm.right_cfa(2), seeds_mm.right_cfa(3), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 10);
    plot3(seeds_mm.left_cfa(1),  seeds_mm.left_cfa(2),  seeds_mm.left_cfa(3),  'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 10);
    grid on; axis equal; view(45, 20);
    xlabel('x (mm)'); ylabel('y (mm)'); zlabel('z (mm)');
    title('Bifurcated centerline (patient coords)');

    fig_path = fullfile(opts.out_dir, 'planner_qc.png');
    exportgraphics(fig, fig_path, 'Resolution', 180);
    close(fig);
    fprintf('[6] QC figure saved to %s\n', fig_path);
    fprintf('=== done ===\n');
end

function v = field_or_nan(s, f)
    if isfield(s, f) && ~isempty(s.(f)) && isnumeric(s.(f)); v = s.(f);
    else; v = NaN; end
end

function p_mm = voxel_to_mm(p_vox, D)
    p_mm = zeros(1, 3);
    p_mm(1) = p_vox(2) * D.pixel_mm(2);
    p_mm(2) = p_vox(1) * D.pixel_mm(1);
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        z_idx = min(max(p_vox(3), 1), numel(D.slice_z_mm));
        p_mm(3) = interp1(1:numel(D.slice_z_mm), D.slice_z_mm, z_idx, 'linear');
    else
        p_mm(3) = (p_vox(3) - 1) * D.slice_spacing_mm;
    end
end

function bad = vmtk_branch_degenerate(cl, seeds_mm)
%VMTK_BRANCH_DEGENERATE  True if either VMTK branch collapsed to a
%   near-zero-length polyline — the thin-bridge surface-pinch failure
%   where decimation splits the surface mesh and vmtkcenterlines returns a
%   2-node line sitting on the CFA target (arc ~0 mm) with no traversal.
%
%   We compare each branch's arc length against the straight-line
%   proximal→CFA separation. A genuine geodesic is always >= the straight
%   distance; a pinched/degenerate branch is a small fraction of it. Arc
%   length is invariant to the x↔y frame transpose between Pv_mm ([y x z])
%   and seeds_mm ([x y z]), and `straight` is computed purely within the
%   seeds_mm frame, so this test is coordinate-frame robust.
    bad = branch_degenerate(cl.Pv_mm_right, seeds_mm.proximal, seeds_mm.right_cfa) ...
       || branch_degenerate(cl.Pv_mm_left,  seeds_mm.proximal, seeds_mm.left_cfa);
end

function b = branch_degenerate(Pv, prox_mm, cfa_mm)
    if isempty(Pv) || size(Pv, 1) < 5
        b = true; return;
    end
    arc      = sum(vecnorm(diff(Pv, 1, 1), 2, 2));
    straight = norm(prox_mm(:)' - cfa_mm(:)');
    b = arc < 0.6 * straight;   % span_frac=0.6, matches the acceptance gate
end

function [seed_out, was_snapped] = snap_seed_to_largest_cc(seed, mask)
%SNAP_SEED_TO_LARGEST_CC  If `seed` doesn't lie inside `mask`, move it to
%   the nearest mask voxel. Since the label-aware Step-6b keep, `mask` may
%   hold MORE than one 3D-CC (the largest plus any vessel-labeled
%   fragment), so "nearest voxel" resolves to the nearest KEPT component —
%   i.e. a CFA seed snaps onto the iliac/CFA fragment it belongs to even
%   when that fragment is not the largest CC. Returns the (possibly
%   relocated) seed and a flag indicating whether it was moved. (Name kept
%   for call-site stability; it no longer targets only the largest CC.)
    seed_out = seed;
    was_snapped = false;
    if all(seed >= 1) && all(seed(:)' <= size(mask)) ...
            && mask(seed(1), seed(2), seed(3))
        return;
    end
    % Find nearest mask voxel
    [yy, xx, zz] = ind2sub(size(mask), find(mask));
    d2 = (yy - seed(1)).^2 + (xx - seed(2)).^2 + (zz - seed(3)).^2;
    [~, k] = min(d2);
    seed_out = [yy(k), xx(k), zz(k)];
    was_snapped = true;
end
