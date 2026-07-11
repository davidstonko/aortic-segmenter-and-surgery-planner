classdef AorticCenterlineApp < matlab.apps.AppBase
%AORTICCENTERLINEAPP  CT → aorta segmentation → 3 seeds → centerline → EVAR plan.
%
%   Six-step workflow (each step has a User-driven and an Automatic mode;
%   Step 2's Automatic panel also offers a one-click "Auto-run full
%   pipeline" that drives run_planner_headless end to end):
%     1. Load CT      — DICOM folder, NIfTI file, or cached .mat
%     2. Segment      — TotalSegmentator (auto) or click-to-grow (manual),
%                       aorta + iliacs + branches, CFA-capped distally
%     3. Endpoints    — proximal aorta + bilateral CFA seeds (auto or click)
%     4. Centerline   — bifurcated centerline (VMTK preferred; skeleton fallback)
%     5. Analyze      — EVAR sizing (neck/iliac/AAA) + IFU device match
%     6. Export       — centerline.mat, structured plan (.txt/.json)
%
%   To launch:
%       cd '/Users/.../Vascular Mathematical Modeling/phase-3-real-EVAR'
%       app.AorticCenterlineApp
%
%   The viewer shows axial / coronal / sagittal / 3D MIP / 3D volume / CPR
%   panes, switchable via the toolbar (or a 2x2 multi-pane view).
%
%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    properties (Access = public)
        UIFigure          matlab.ui.Figure
    end

    % ---------------------------------------------------------------
    % Programmatic driver — used by scripts/make_gui_video.m and
    % anything that wants to walk the GUI without mouse clicks.
    % Every method here ends in `Public` and is otherwise identical
    % to the corresponding callback flow.
    % ---------------------------------------------------------------
    methods (Access = public)
        function injectCT(app, D_struct)
            app.D = D_struct;
            sz = size(D_struct.vol);
            app.Mask = false(sz);
            app.PendingMask = false(sz);
            app.MaskLabel = zeros(sz, 'uint8');
            app.IdxAxial    = round(sz(3)/2);
            app.IdxCoronal  = round(sz(1)/2);
            app.IdxSagittal = round(sz(2)/2);
            % Clear ALL prior-case state so a newly loaded scan never
            % inherits the previous case's segmentation, seeds, centerline,
            % landmarks, or display masks. Several of these are sized to the
            % old volume; leaving them stale caused dimension mismatches and
            % wrong overlays when switching scans.
            app.DisplayExclusion = false(sz);
            app.TSLabelVolume    = [];
            app.SeedProximal = []; app.SeedRightCFA = []; app.SeedLeftCFA = [];
            app.SeedSeg = [];
            app.PolylineRight = []; app.R_vox_right = [];
            app.PolylineLeft  = []; app.R_vox_left  = [];
            app.Polyline = []; app.R_vox = []; app.BifurcNodeIdx = [];
            app.CPRImage = []; app.CPRMeta = struct();
            app.SegAuditReport = struct(); app.LastSE3Check = struct();
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                setappdata(app.UIFigure, 'landmarks', struct());
                setappdata(app.UIFigure, 'arm_landmark', '');
            end
            if ~isempty(app.MainImage) && isvalid(app.MainImage)
                delete(app.MainImage); app.MainImage = [];
            end
            if ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                delete(app.VolViewer); app.VolViewer = [];
            end
        end
        function injectMask(app, mask)
            app.Mask = logical(mask);
            app.DisplayExclusion = ~app.Mask;
            if ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                delete(app.VolViewer); app.VolViewer = [];
            end
        end
        function injectSeeds(app, prox, rcfa, lcfa)
            app.SeedProximal = prox;
            app.SeedRightCFA = rcfa;
            app.SeedLeftCFA  = lcfa;
        end
        function injectCenterlines(app, PvR_vox, RR_vox, PvL_vox, RL_vox, bifurc_idx_right)
            app.PolylineRight = PvR_vox; app.R_vox_right = RR_vox;
            app.PolylineLeft  = PvL_vox; app.R_vox_left  = RL_vox;
            app.Polyline      = PvR_vox; app.R_vox       = RR_vox;
            if nargin >= 6 && ~isempty(bifurc_idx_right)
                app.BifurcNodeIdx = bifurc_idx_right;
            end
        end
        function runAutoPipelinePublic(app); runAutoPipeline(app); end
        function setStepPublic(app, k); updateStep(app, k); end
        function setViewPublic(app, mode); setViewMode(app, mode); end
        function refreshPublic(app); refreshMain(app); end
        function resetCameraPublic(app); resetCamera(app); end
        function runFinishStep2Public(app); finishStep2(app); end

        % --- Manual-editor shims (tests + auto-propose→refine driver) ---
        function eraseAtVoxelPublic(app, voxel); eraseVesselAtVoxel(app, voxel); end
        function growAtVoxelPublic(app, voxel); onVesselSelectClick(app, voxel); end
        function setGrowTolPublic(app, hu); app.GrowTolHU = max(5, round(hu)); end
        function g = getGrowTolPublic(app); g = app.GrowTolHU; end
        function n = maskVoxelCountPublic(app); n = nnz(app.Mask); end
        function undoPublic(app); undoMask(app); end
        function redoPublic(app); redoMask(app); end
        function clearMaskPublic(app); clearMask(app); end

        function setStepModePublic(app, step_num, mode)
            % Programmatic toggle of a step's mode — used by tests and
            % the headless driver. step_num in 1..6, mode in {'user','auto'}.
            key = sprintf('step%d', step_num);
            app.StepModes.(key) = mode;
            persistStepModes(app);
        end

        function m = getStepModePublic(app, step_num)
            m = app.StepModes.(sprintf('step%d', step_num));
        end

        function buildHelpMenu(app)
            % Top-level Help menu — every entry opens a help modal from
            % the +ui_helpers/help_content.m registry. Add new entries
            % here when you add a new help key.
            m = uimenu(app.UIFigure, 'Text', 'Help');
            uimenu(m, 'Text', 'Pipeline overview', ...
                'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, 'app.overview'));
            uimenu(m, 'Text', 'User-driven vs Automatic mode', ...
                'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, 'app.mode_toggle'));
            uimenu(m, 'Text', 'Research-only disclaimer', ...
                'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, 'app.research_only'));
            m_steps = uimenu(m, 'Text', 'Per-step help', 'Separator', 'on');
            step_titles = { ...
                'Step 1 — Load CT',              'step1.overview';
                'Step 2 — Segment',              'step2.overview';
                'Step 3 — Pick endpoints',       'step3.overview';
                'Step 4 — Compute centerline',   'step4.overview';
                'Step 5 — Analyze (EVAR)',       'step5.overview';
                'Step 6 — Export',               'step6.overview'};
            for i = 1:size(step_titles, 1)
                uimenu(m_steps, 'Text', step_titles{i, 1}, ...
                    'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, step_titles{i, 2}));
            end
            uimenu(m, 'Text', 'Glossary of clinical terms', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, 'glossary.all'));
            uimenu(m, 'Text', 'Reference annotations + benchmark', ...
                'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, 'reference.overview'));
            uimenu(m, 'Text', 'Show first-launch tour', ...
                'MenuSelectedFcn', @(~,~) showFirstLaunchTour(app, true));
            uimenu(m, 'Text', 'About', 'Separator', 'on', ...
                'MenuSelectedFcn', @(~,~) ui_helpers.show_help_modal(app.UIFigure, 'app.overview'));
        end

        function showFirstLaunchTour(app, force)
            % Walk through the 8-page tour using uiconfirm so the user
            % advances one page at a time. Set prefs.tour_shown = true
            % when complete so future launches skip it.
            if nargin < 2; force = false; end
            prefs = ui_helpers.load_user_prefs();
            shown = isfield(prefs, 'tour_shown') && prefs.tour_shown;
            if shown && ~force; return; end
            pages = { ...
                'app.overview', ...
                'step1.overview', ...
                'step2.overview', ...
                'step3.overview', ...
                'step4.overview', ...
                'step5.overview', ...
                'step6.overview', ...
                'app.research_only'};
            for k = 1:numel(pages)
                entry = ui_helpers.help_content(pages{k});
                title = sprintf('Tour %d/%d — %s', k, numel(pages), entry.title);
                parts = {entry.body};
                if ~isempty(entry.when);  parts{end+1} = ''; parts{end+1} = ['When to use: ', entry.when]; end %#ok<AGROW>
                if ~isempty(entry.auto);  parts{end+1} = ''; parts{end+1} = ['Automatic mode: ', entry.auto]; end %#ok<AGROW>
                msg = strjoin(parts, newline);
                if k < numel(pages)
                    opts = {'Next', 'Skip tour'};
                else
                    opts = {'Finish'};
                end
                sel = uiconfirm(app.UIFigure, msg, title, ...
                    'Options', opts, 'DefaultOption', 1, ...
                    'Icon', 'info', 'Interpreter', 'none');
                if strcmp(sel, 'Skip tour'); break; end
            end
            prefs.tour_shown = true;
            ui_helpers.save_user_prefs(prefs);
        end
    end

    properties (Access = private)
        % --- Latest segmentation audit report (from autoseg.audit_segmentation).
        %     Stored so Step 3's side-panel can show the operator the
        %     blocks/findings while they pick endpoints.
        SegAuditReport struct = struct()

        % --- Latest SE(3) cross-vessel rule check (from autoseg.extend_to_cfa).
        %     Stored so Step 3/4 can offer a "Manual CFA click" path when
        %     the L or R iliac centerline fails an anatomic rule.
        LastSE3Check struct = struct()

        % --- Exact TotalSegmentator multilabel volume that produced the
        %     current segmentation (info.label_volume from autoseg.ts_run).
        %     Stored so branch detection + anatomic auto-seeds use THE seg
        %     for the loaded scan rather than guessing "the newest *_seg
        %     file in the cache dir" — which silently picked the wrong
        %     scan's labels (or dropped branches entirely) whenever more
        %     than one scan had been segmented this session.
        TSLabelVolume = []

        % --- Layout containers ---
        StepBar           matlab.ui.container.Panel
        StepLabels        cell
        ViewToolbar       matlab.ui.container.Panel
        BtnAxial          matlab.ui.control.StateButton
        BtnCoronal        matlab.ui.control.StateButton
        BtnSagittal       matlab.ui.control.StateButton
        Btn3D             matlab.ui.control.StateButton
        BtnCPR            matlab.ui.control.StateButton
        WLDropdown        matlab.ui.control.DropDown
        ImagePanel        matlab.ui.container.Panel
        SidePanel         matlab.ui.container.Panel

        % --- Image axes ---
        MainAxes          matlab.ui.control.UIAxes
        MainImage         matlab.graphics.primitive.Image
        SliceSlider       matlab.ui.control.Slider
        SliceLabel        matlab.ui.control.Label

        % --- Side panel ---
        SideStepLabel     matlab.ui.control.Label
        SideContent       matlab.ui.container.Panel

        % --- State ---
        Step              double = 1
        ViewMode          char   = 'axial'   % 'axial'|'coronal'|'sagittal'|'3d'
        D                 struct = struct()
        Mask              logical = false(0,0,0)
        % --- Per-click grow scrollback (TeraRecon-style) ---
        % Each click runs an unconstrained flood-fill, then we
        % compute geodesic distance from the seed within that
        % grow. The slider in the side panel thresholds that
        % distance — scrolling LEFT shrinks the visible region
        % (back to just the seed), scrolling RIGHT expands it
        % back to the full grow. PreviousMaskLabel snapshots the
        % MaskLabel before the latest click so the slider can
        % re-paint cleanly without re-running the grow.
        LastSeedDist      double  = []     % single-precision geodesic distance map
        LastSeedMaxDist   double  = 0
        LastSeedThreshold double  = 0
        LastSeedLabel     uint8   = uint8(0)
        PreviousMaskLabel uint8   = uint8([])
        % MaskLabel keeps a per-click record of which voxels each
        % shift-click contributed. Value k = the k-th click's
        % territory; 0 = unselected. Mask = MaskLabel > 0 (kept in
        % sync). LabelColors gives each click its own tint so the
        % user can see what each click added even though all labels
        % belong to one growing segmentation set.
        MaskLabel         uint8   = uint8([])
        NextSegLabel      double  = 1
        % Label palette ordered so the FIRST colors stand out
        % against the CTA recon's orange-red vessel colors. Orange
        % moved to the back of the rotation since "orange tint
        % over an orange vessel" is invisible.
        LabelColors       double  = [ ...
            1.00 0.20 0.85;   % magenta
            0.10 0.85 0.95;   % cyan
            0.40 1.00 0.30;   % lime
            1.00 0.95 0.20;   % yellow
            0.30 0.65 1.00;   % sky-blue
            1.00 0.55 0.75;   % pink
            0.50 1.00 0.80;   % mint
            0.75 0.60 1.00;   % lavender
            0.20 0.80 0.70;   % teal
            1.00 0.45 0.45;   % coral
            1.00 0.80 0.00;   % gold
            1.00 0.50 0.10 ]; % orange (last — least distinguishable from CTA)
        % --- Isolated-vessel render colors (Step 3+) -----------------
        % Default lighter red/orange that matches CTA contrast tone
        % rather than a saturated stop-sign red. User can change via
        % right-click context menu on the 3-D recon.
        IsolatedVesselColor  double  = [1.00 0.42 0.32]   % light coral-red
        % Bright blue tint applied while a region grow is actively
        % running (during runSegmentation). Reverts to
        % IsolatedVesselColor once the grow finishes.
        ActiveVesselColor    double  = [0.20 0.55 1.00]   % bright sky-blue
        IsActivelySegmenting logical = false
        % --- Live-grow state -----------------------------------------
        % LiveGrowActive: while true, the iterative grow loop keeps
        % expanding the seed-CC by one shell per iteration with a
        % redraw between each. The WindowButtonUpFcn flips this to
        % false the moment the user releases the mouse → user controls
        % final size by hold time. TeraRecon-style hold-to-grow UX.
        LiveGrowActive       logical = false
        % --- MIP-based Step 2 recon ---------------------------------
        % Replaces viewer3d for the segmentation step because
        % viewer3d's GPU canvas swallows mouse events. A regular
        % uiaxes hosts a max-intensity-projection image; clicks on
        % the axes are reliable. MIPArgmax stores per-pixel which
        % source-volume slice contributed the max value, so click →
        % voxel is a direct lookup, no ray-cast needed.
        MIPAxes              matlab.graphics.Graphics
        MIPImage             matlab.graphics.Graphics
        MIPArgmax            uint16     % per-pixel argmax along projection axis
        MIPViewKind          char       = 'AP'   % 'AP' | 'lat-R' | 'lat-L'
        % --- Guided 5-click landmark workflow -----------------------
        % Step the user serially through: aorta → R renal → L renal
        % → R CFA → L CFA. GuidedStep is 1..5 = current target,
        % 0 = inactive, 6 = done. Each click while guided runs the
        % click-and-grow with the target's anatomic label ID.
        GuidedStep           double  = 0
        Vesselness        single  = []
        SeedSeg           double  = []
        % --- Step 3 three-seed flow (preop EVAR planning) ----------
        % Proximal = suprarenal aorta (source). Right/Left CFA =
        % common femoral entry sites (targets). Polyline convention is
        % distal → proximal so node 1 = CFA and last node = suprarenal.
        SeedProximal      double  = []
        SeedRightCFA      double  = []
        SeedLeftCFA       double  = []
        % --- Step 4 dual-side centerlines -------------------------
        PolylineRight     double  = []   % distal-to-proximal, R-CFA → suprarenal
        R_vox_right       double  = []
        PolylineLeft      double  = []   % distal-to-proximal, L-CFA → bifurc node
        R_vox_left        double  = []
        BifurcNodeIdx     double  = []   % index on PolylineRight at the bifurcation
        CenterlineMethod  char    = 'auto'   % 'vmtk' | 'skeleton' | 'auto'
        % Max-centerline-distance guardrail. When ON, the centerline
        % is rejected if the straight-line seed-to-seed distance
        % multiplied by `MaxCenterlinePathFactor` is exceeded by the
        % computed arc length — that's the symptom of Dijkstra walking
        % through the spine instead of the aorta.
        MaxCenterlineGuard       logical = true
        MaxCenterlinePathFactor  double  = 2.0     % arc ≤ 2× chord
        % Back-compat aliases — Step 5/6/7 paths that still use the
        % singular .Polyline / .R_vox get the right side. Mirrored on
        % every assignment in runCenterline.
        Polyline          double  = []
        R_vox             double  = []
        ClickLog          struct
        WL                double  = [700, 150]
        IdxAxial          double  = 1
        IdxCoronal        double  = 1
        IdxSagittal       double  = 1
        VesselnessThresh  double  = 0.05

        % --- Step mode toggles (User-driven vs Automatic) ---
        % Per-step UI mode. One entry per step (Steps 1-6). 'user' shows
        % the granular controls (default); 'auto' replaces them with a
        % single "Run X automatically" button. Hydrated from
        % ~/.aortic_centerline_prefs.json on construction (via
        % ui_helpers.load_user_prefs) so the toggle persists across
        % sessions; mutations call ui_helpers.save_user_prefs.
        StepModes struct = struct( ...
            'step1', 'user', ...
            'step2', 'user', ...
            'step3', 'user', ...
            'step4', 'user', ...
            'step5', 'user', ...
            'step6', 'user')

        % --- Step 2 cleanup tools ---
        SeedSegList       cell    = {}        % multi-seed history
        Tool              char    = 'click'   % 'click'|'brush'|'erase'
        BrushRadiusVox    double  = 4         % voxels (in-plane)
        % HU half-window for the click-to-grow region grow. The grow
        % accepts voxels in [seed_HU - GrowTolHU, seed_HU + GrowTolHU];
        % a 2nd relaxed pass widens this by +25 HU. Exposed as the
        % "Grow tolerance ± HU" slider so the user can tighten the grow
        % when it leaks into adjacent bone, or loosen it when a weakly
        % opacified distal vessel won't fill. Default 75 reproduces the
        % previously hard-coded behavior.
        GrowTolHU         double  = 75
        IsPainting        logical = false
        UndoStack         cell    = {}        % mask snapshots
        UndoIndex         double  = 0

        % --- Step 2 seed-placement flow ----
        % SegSubStep is no longer used as a confirmation gate (clicks
        % run instant region grows now), but we keep the field so the
        % 3-view fallback can be re-enabled if needed.
        SegSubStep        double  = 0
        PendingSeed       double  = []        % candidate [y x z] before confirm

        % --- Fast region-grow tunables (TeraRecon-style click-add) ----
        HU_min            double  = 300       % HU floor — pure arterial contrast (peak enhancement). 300-450 with 6-connected flood-fill gives a clean aorta+iliacs without leaking into vertebral cancellous bone (HU ~200-300 same range)
        HU_max            double  = 450       % HU ceiling — drops calcified plaque and cortical bone

        % --- Display modifications (scalpel, bone strip) -------------
        % Voxels marked true here are HIDDEN from every display, AND
        % blocked from joining the segmentation. Reversible — clearing
        % the exclusion brings them back.
        DisplayExclusion  logical = false(0,0,0)
        ScalpelArmed      logical = false

        % --- Shift-chain selection ----------------------------------
        % When ShiftMode is on, clicks accumulate into PendingMask
        % (yellow preview). Pressing Select OR's it into Mask; Cancel
        % discards.
        ShiftMode         logical = false
        PendingMask       logical = false(0,0,0)

        % --- 3D rotatable volume viewer -----------------------------
        Btn3DVol          matlab.ui.control.StateButton
        VolPanel          matlab.ui.container.Panel
        VolViewer                                  % volshow / Volume handle
        VolStyle          char    = 'vessel'    % 'cta_recon'|'vessel'|'bone'|'mip'|'isosurface'
        VolStyleDropdown  matlab.ui.control.DropDown
        VolHudLabel       matlab.ui.control.Label   % overlay HUD on volshow panel
        % Persistent overlay tool buttons (live in ImagePanel — sibling
        % of MainAxes / VolPanel, visible across all view modes).
        PanToggleBtn      matlab.ui.control.StateButton
        WLToggleBtn       matlab.ui.control.StateButton
        SnapBtn           matlab.ui.control.Button
        ResetBtn          matlab.ui.control.Button
        CursorHULabel     matlab.ui.control.Label  % live HU readout under cursor
        OverlayTools      cell = {}                 % all overlay buttons (for uistack)
        % --- 2x2 multi-pane view (axial, sagittal, coronal, 3-D recon) ---
        Btn2x2            matlab.ui.control.StateButton
        MultiPanels       cell = {}                 % 4 uipanels
        MultiAxes         cell = {}                 % 4 uiaxes (pane 4 unused — volshow there)
        Multi3DViewer                                % volshow handle for pane 4
        % Measurement overlay volshows. viewer3d in R2025b only
        % accepts Volume children (no Line / Patch / Surface), but
        % it accepts MULTIPLE volshow children. We keep a second
        % volshow per pane that holds a sparse annotation volume —
        % zeros everywhere except along the measurement lines, where
        % it lights up with a bright yellow transfer function. The
        % composite gives a true 3-D measurement overlay aligned
        % automatically with the camera.
        Vol3DOverlay                                  % measurement-line overlay (single-view)
        Multi3DOverlay                                % measurement-line overlay (2x2 pane 4)
        VolLabel3DOverlay                             % colored mask-label overlay (single-view)
        MultiLabel3DOverlay                           % colored mask-label overlay (2x2 pane 4)
        % Armed "Pick vessel" mode. When on, a single left-click
        % anywhere on the 3-D recon volshow ray-casts to a seed
        % voxel and runs vessel-select. While armed we set the
        % viewer3d's Interactions to 'none' so the GPU layer
        % doesn't consume the click before our handler sees it.
        VesselPickArmed   logical = false
        ViewerInteractionsBeforeArm char = 'rotate'   % to restore on disarm
        VesselPickDownXY  double  = [0 0]    % position at mouse-down for click-vs-drag detection
        VesselPickDownTime double = 0
        VesselPickHasDown logical = false
        Disable3DOverlay  logical = false             % kill switch — set true if a renderer crash recovery left things wonky
        Overlay3DCap      double  = 96                % max dim of the annotation volume (memory + GPU stability)
        MultiPanToggleBtn matlab.ui.control.StateButton  % small Pan toggle inside pane 4
        MultiZoomInBtns   cell = {}                  % per-pane zoom in (4)
        MultiZoomOutBtns  cell = {}                  % per-pane zoom out (4)
        % Individual overlay button refs so visibility can be toggled
        ZoomInBtn         matlab.ui.control.Button
        ZoomOutBtn        matlab.ui.control.Button
        FitBtn            matlab.ui.control.Button
        % Drag-mode arming state. WL mode: drag horizontal = window
        % width, vertical = level. Pan-2D mode: drag pans XLim/YLim.
        WLArmed           logical = false
        IsWLDragging      logical = false
        WLDragStartXY     double  = [0 0]
        WLDragStartWL     double  = [700 150]
        PanArmed          logical = false
        IsPanning2D       logical = false
        Pan2DStartXY      double  = [0 0]
        Pan2DStartXLim    double  = [0 0]
        Pan2DStartYLim    double  = [0 0]
        % Home-button reset guard — viewer3d's Home click flips
        % CameraPositionMode to 'auto'; the listener catches that and
        % re-applies our AP preset. Guard prevents recursion.
        ApplyingAPReset   logical = false
        NeedFitOnRefresh  logical = true       % set on view-mode change / load
        % CPR (curved planar reformat) cache. Recomputed when the
        % centerline changes; cleared on case load.
        CPRImage          single  = []
        CPRMeta           struct
        % Orthogonal cross-section pane — visible when in CPR mode.
        XSecPanel         matlab.ui.container.Panel
        XSecAxes          matlab.ui.control.UIAxes
        XSecImage         matlab.graphics.primitive.Image
        XSecLabel         matlab.ui.control.Label
        XSecArcMm         double = 0   % current arc-length position (mm)
        % Right-click context menu for centerline editing.
        ClContextMenu     matlab.ui.container.ContextMenu
        ClCtxClickVoxel   double = []   % voxel under the cursor at right-click
        ClCtxClickSide    char   = 'right'   % 'right' or 'left' centerline
        % --- Measurement tools (linear distance + angle) ---
        % Tool row sits below the view toolbar. Measurements are
        % stored in voxel space so they project consistently across
        % axial / sagittal / coronal / 3-D MIP / 3-D recon. A
        % measurement that falls within a small tolerance of the
        % current slice plane is drawn solid; otherwise it's drawn
        % dashed and dimmer so the user always sees what they
        % measured but can still tell when they're looking at the
        % originating slice.
        ToolToolbar       matlab.ui.container.Panel   % row 1
        ToolToolbar2      matlab.ui.container.Panel   % row 2
        BtnMeasure        matlab.ui.control.StateButton
        BtnAngle          matlab.ui.control.StateButton
        BtnClearMeasure   matlab.ui.control.Button
        MeasureMode       char  = ''    % '' | 'measure' | 'angle'
        PendingPoints     cell  = {}    % partial points for current measurement
        Measurements      cell  = {}    % completed measurements
        % Slice-plane tolerance for "in-plane" classification (mm).
        % Anything closer than this on the perpendicular axis is
        % drawn solid; farther is drawn dashed.
        MeasureSliceTol_mm double = 5.0
        % --- Display options ---
        InvertDisplay     logical = false   % flip intensity polarity in 2-D views
        % --- Slab MIP ---
        % When > 0, axial / sagittal / coronal panes render a
        % thick-slab maximum-intensity projection over a slab
        % centered on the current slice. Thickness is in mm; 0
        % disables slab mode (single-slice MPR).
        SlabThickness_mm  double = 0
        BtnInvert         matlab.ui.control.StateButton
        BtnAutoWL         matlab.ui.control.Button
        BtnPlay           matlab.ui.control.StateButton
        BtnDicomTags      matlab.ui.control.Button
        SlabDropdown      matlab.ui.control.DropDown
        CineSpeedDropdown matlab.ui.control.DropDown
        CineTimer                            % timer object
        % --- Drawing tools ---
        BtnROIRect        matlab.ui.control.StateButton
        BtnROIEllipse     matlab.ui.control.StateButton
        BtnAnnotate       matlab.ui.control.StateButton
        BtnWirePath       matlab.ui.control.StateButton
        BtnFinishWire     matlab.ui.control.Button
        BtnSaveProject    matlab.ui.control.Button
        BtnLoadProject    matlab.ui.control.Button
        DrawMode          char = ''         % '' | 'roi_rect' | 'roi_ellipse' | 'annotate' | 'wire'
        ROIs              cell = {}         % each: struct(kind, view_origin, slice_idx, x_lo, x_hi, y_lo, y_hi[, label, stats])
        Annotations       cell = {}         % each: struct(view_origin, voxel, text)
        WirePath          double = []       % N x 3 voxel-space polyline (incremental)
        WireFinalized     logical = false
        % --- Linked crosshair (2x2 navigation) ---
        Crosshair         double = []        % 1x3 voxel point or [] if not set
        CrosshairLockBtn  matlab.ui.control.StateButton
        CrosshairLocked   logical = true
    end

    methods (Access = private)

        % --- Figure resize handler ----------------------------------
        function onFigureResized(app)
        % Repositions the top-level containers when the user resizes
        % the figure. Without this the absolute Position values from
        % construction time would leave the step bar / toolbars off
        % the new top edge and the side panel off the new right edge.
        % Children inside each container are NOT reflowed (they use
        % their own internal layouts), but their owning container's
        % outer Position is updated.
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure); return; end
            W = app.UIFigure.Position(3);
            H = app.UIFigure.Position(4);
            side_w = 410;
            % --- Step bar -----------------------------------------
            if ~isempty(app.StepBar) && isvalid(app.StepBar)
                app.StepBar.Position = [10 (H-52) (W-20) 32];
                % Re-grid the 6 labels across the new width
                barW = W - 30;
                segW = barW / 6;
                for k = 1:numel(app.StepLabels)
                    if ~isempty(app.StepLabels{k}) && isvalid(app.StepLabels{k})
                        app.StepLabels{k}.Position = [(k-1)*segW + 5, 4, segW - 10, 24];
                    end
                end
            end
            % --- View / tool toolbars -----------------------------
            % Toolbar width capped at the natural 900 so it doesn't
            % overlap the side panel at narrow window widths.
            margin_x = 30;
            bar_w = max(300, min(900, W - side_w - margin_x));
            if ~isempty(app.ViewToolbar) && isvalid(app.ViewToolbar)
                app.ViewToolbar.Position = [10 (H-90) bar_w 32];
            end
            if ~isempty(app.ToolToolbar) && isvalid(app.ToolToolbar)
                app.ToolToolbar.Position = [10 (H-126) bar_w 32];
            end
            if ~isempty(app.ToolToolbar2) && isvalid(app.ToolToolbar2)
                app.ToolToolbar2.Position = [10 (H-162) bar_w 32];
            end
            % --- Image panel --------------------------------------
            if ~isempty(app.ImagePanel) && isvalid(app.ImagePanel)
                x0 = 10; y0 = 80;
                img_w = max(400, W - x0 - side_w - 20);
                img_h = max(300, H - y0 - 102 - 72);
                app.ImagePanel.Position = [x0 y0 img_w img_h];
            end
            % --- Side panel ---------------------------------------
            if ~isempty(app.SidePanel) && isvalid(app.SidePanel)
                app.SidePanel.Position = [(W - side_w + 10) 26 400 max(200, H-76)];
                if ~isempty(app.SideStepLabel) && isvalid(app.SideStepLabel)
                    app.SideStepLabel.Position = ...
                        [12 (app.SidePanel.Position(4)-65) 376 28];
                end
                if ~isempty(app.SideContent) && isvalid(app.SideContent)
                    app.SideContent.Position = ...
                        [10 10 380 max(80, app.SidePanel.Position(4)-80)];
                end
            end
            % --- Key-hint bar (status line) -----------------------
            kh = findobj(app.UIFigure, 'Tag', 'key_hint_bar');
            if isempty(kh)
                kh = findobj(app.UIFigure, 'Type', 'uilabel');
                if ~isempty(kh); kh = kh(1); end
            end
            if ~isempty(kh) && isvalid(kh) && kh.Position(2) <= 20
                kh.Position = [10 2 max(200, W - 20) 18];
            end
        end

        % --- Gated-step placeholder ---------------------------------
        % Renders an informative "you can't enter this step yet" panel
        % instead of a bare red error. Shows what's blocking, what the
        % user must do first, and a preview of the controls that will
        % appear once the gate opens — plus a "Back to Step N" button.
        function render_gated_step_placeholder(app, step_num, blocker_text, prereq_list, preview_list, back_to_step)
            sc = app.SideContent;
            y = 720;
            % Blocker block (orange)
            uilabel(sc, 'Position', [10 y-50 360 50], ...
                'WordWrap', 'on', 'FontSize', 13, 'FontWeight', 'bold', ...
                'FontColor', [0.65 0.35 0.05], ...
                'Text', sprintf('Not ready — %s required first.', blocker_text));
            y = y - 50 - 8;
            % Prerequisite checklist
            uilabel(sc, 'Position', [10 y-22 360 22], ...
                'Text', 'You must complete:', 'FontSize', 12, 'FontWeight', 'bold');
            y = y - 22 - 4;
            for k = 1:numel(prereq_list)
                uilabel(sc, 'Position', [10 y-22 360 22], ...
                    'Text', sprintf('  • %s', prereq_list{k}), 'FontSize', 12);
                y = y - 22 - 2;
            end
            y = y - 12;
            % Preview list — what they get once ready
            uilabel(sc, 'Position', [10 y-22 360 22], ...
                'Text', sprintf('Once ready, Step %d gives you:', step_num), ...
                'FontSize', 12, 'FontWeight', 'bold');
            y = y - 22 - 4;
            for k = 1:numel(preview_list)
                uilabel(sc, 'Position', [10 y-36 360 36], ...
                    'Text', sprintf('  • %s', preview_list{k}), 'FontSize', 12, ...
                    'WordWrap', 'on', 'FontColor', [0.30 0.30 0.30]);
                y = y - 36 - 2;
            end
            y = y - 14;
            % Back button
            uibutton(sc, 'push', 'Position', [10 y-40 360 40], ...
                'Text', sprintf('← Back to Step %d', back_to_step), ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.92 0.97 1.0], ...
                'ButtonPushedFcn', @(~,~) setStepPublic(app, back_to_step));
        end

        % --- Keyboard shortcuts -------------------------------------
        function onKeyPress(app, evt)
            % Skip when typing in an edit field / text area so the
            % shortcuts don't eat user input.
            try
                co = app.UIFigure.CurrentObject;
                if ~isempty(co) && isvalid(co)
                    cls = class(co);
                    if contains(cls, 'EditField') || contains(cls, 'TextArea')
                        return;
                    end
                end
            catch
            end
            if ~isempty(evt.Modifier); return; end  % no Cmd/Ctrl combos
            switch evt.Key
                case '1'; setViewMode(app, 'axial');
                case '2'; setViewMode(app, 'coronal');
                case '3'; setViewMode(app, 'sagittal');
                case '4'; setViewMode(app, '3d');
                case '5'; setViewMode(app, '3dvol');
                case '6'; setViewMode(app, 'cpr');
                case 'f'; fitView(app);
                case 'r'; resetView(app);
                case 's'; saveSnapshot(app);
                case 'p'; togglePanMode(app);
                case 'w'; toggleWLMode(app);
                case {'add', 'equal'}; zoomBy(app, 0.7);
                case {'subtract', 'hyphen'}; zoomBy(app, 1/0.7);
            end
        end

        function resetCamera(app)
            % Reset the 3-D Volume camera to the default AP view.
            % Equivalent to triggering the 'AP' preset that
            % refreshVolViewer applies on first volshow creation.
            %
            % Patient orientation in volshow coords (after our z-flip
            % in doLoad): data-Y row = anterior-posterior (low row =
            % anterior); data-Z slice = inferior-superior (low slice =
            % superior / head end). So an AP view places the camera at
            % low row (anterior), looking toward high row (posterior),
            % with up = -Z so the head sits at the top of the screen.
            if ~strcmp(app.ViewMode, '3dvol'); return; end
            if isempty(app.VolViewer) || ~isvalid(app.VolViewer); return; end
            try
                v3d = app.VolViewer.Parent;
                Vn  = app.VolViewer.Data;
                sz  = size(Vn);
                % Center on the MASK centroid (or visible-volume centroid)
                % rather than the geometric volume center. When the mask
                % occupies only a fraction of the FOV (typical for a CT
                % with the vessel offset from the volume midline), the
                % vessel otherwise renders off-center.
                if ~isempty(app.Mask) && isequal(size(app.Mask), sz) && any(app.Mask(:))
                    [yy, xx, zz] = ind2sub(sz, find(app.Mask));
                    % Voxel-weighted centroid: the mean position of all
                    % mask voxels. This is the visual centre of the
                    % vessel tree (AAA + iliacs dominate the centroid
                    % because they have more voxels than the supraceliac
                    % trunk), so the recon renders centred regardless
                    % of patient anatomy / FOV extent. Earlier this
                    % function used (min+max)/2 (bbox midpoint) + per-
                    % patient empirical offsets; those were calibrated
                    % for the JohnDoe1 case (1219 slices, full chest+pelvis
                    % FOV) and rendered JohnDoe2 (868 slices) off-
                    % centre.
                    cy = mean(yy);
                    cx = mean(xx);
                    cz = mean(zz);
                    span = max([max(yy)-min(yy), max(xx)-min(xx), max(zz)-min(zz)]);
                else
                    cy = sz(1) / 2; cx = sz(2) / 2; cz = sz(3) / 2;
                    span = max(sz);
                end
                app.ApplyingAPReset = true;
                v3d.CameraTarget   = [cx, cy, cz];
                v3d.CameraPosition = [cx, cy - 3 * span, cz];
                v3d.CameraUpVector = [0, 0, 1];   % patient head at top of screen
                v3d.CameraZoom     = 1.4;
                drawnow;
                % Some MATLAB versions animate Home; re-apply once more
                % after the event loop has flushed so the AP view sticks.
                v3d.CameraTarget   = [cx, cy, cz];
                v3d.CameraPosition = [cx, cy - 3 * span, cz];
                v3d.CameraUpVector = [0, 0, 1];
                v3d.CameraZoom     = 1.4;
                app.ApplyingAPReset = false;
                updateVolHud(app);
            catch ME
                app.ApplyingAPReset = false;
                fprintf('[resetCamera] %s\n', ME.message);
            end
        end

        function onCameraModeChange(app)
            % Fires when viewer3d.CameraPositionMode changes. The
            % built-in Home toolbar button flips it from 'manual'
            % (which our AP preset leaves it in) to 'auto'. When
            % that happens, snap back to our AP preset — but defer
            % via a timer so the home button's own animation finishes
            % first; otherwise our AP camera gets stomped on by the
            % data-fit reset.
            if app.ApplyingAPReset; return; end
            if isempty(app.VolViewer) || ~isvalid(app.VolViewer); return; end
            try
                v3d = app.VolViewer.Parent;
                if strcmp(char(string(v3d.CameraPositionMode)), 'auto')
                    t = timer('StartDelay', 0.15, 'ExecutionMode', 'singleShot', ...
                        'TimerFcn', @(~,~) safeReset(app));
                    start(t);
                end
            catch
            end
        end

        function safeReset(app)
            try
                if ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                    resetCamera(app);
                end
            catch
            end
        end

        function repackOverlayTools(app)
            % Reflow visible overlay buttons into consecutive rows so
            % hidden ones don't leave gaps. + and − share a row at
            % half-width when both are visible; if one is hidden the
            % other expands to full width.
            if isempty(app.MainAxes) || ~isvalid(app.MainAxes); return; end
            ax_pos = app.MainAxes.Position;
            btn_w = 140; btn_h = 26;
            btn_x = ax_pos(1) + 8;
            top_y = ax_pos(2) + ax_pos(4) - btn_h - 6;
            half_w = (btn_w - 4) / 2;
            % Display order. A cell value means "pair on one row".
            seq = {app.PanToggleBtn, app.WLToggleBtn, app.SnapBtn, ...
                   app.ResetBtn, {app.ZoomInBtn, app.ZoomOutBtn}, app.FitBtn};
            row_idx = 0;
            for i = 1:numel(seq)
                item = seq{i};
                if iscell(item)
                    b1 = item{1}; b2 = item{2};
                    v1 = ~isempty(b1) && isvalid(b1) && strcmp(b1.Visible, 'on');
                    v2 = ~isempty(b2) && isvalid(b2) && strcmp(b2.Visible, 'on');
                    if ~v1 && ~v2; continue; end
                    row_idx = row_idx + 1;
                    y = top_y - (row_idx - 1) * (btn_h + 4);
                    if v1 && v2
                        b1.Position = [btn_x, y, half_w, btn_h];
                        b2.Position = [btn_x + half_w + 4, y, half_w, btn_h];
                    elseif v1
                        b1.Position = [btn_x, y, btn_w, btn_h];
                    else
                        b2.Position = [btn_x, y, btn_w, btn_h];
                    end
                else
                    b = item;
                    if isempty(b) || ~isvalid(b); continue; end
                    if ~strcmp(b.Visible, 'on'); continue; end
                    row_idx = row_idx + 1;
                    y = top_y - (row_idx - 1) * (btn_h + 4);
                    b.Position = [btn_x, y, btn_w, btn_h];
                end
            end
        end

        function updateOverlayVisibility(app)
            % Show / hide overlay buttons depending on the current
            % view. Plain 2-D views: no Pan toggle (rotate is a 3-D
            % concept). 3-D Volume: Pan toggle on. 2x2: hide Pan,
            % Snap, and Fit (Pan moves into the 3-D pane; Snap and
            % Fit are tucked away to keep the overlay compact).
            is_3dvol = strcmp(app.ViewMode, '3dvol');
            is_2x2   = strcmp(app.ViewMode, '2x2');
            % Pan toggle: only on 3-D Volume single view
            setVis(app.PanToggleBtn, is_3dvol);
            % Save snapshot: hide on 2x2
            setVis(app.SnapBtn,      ~is_2x2);
            % Fit: hide on 2x2
            setVis(app.FitBtn,       ~is_2x2);
            % W/L, Reset: visible everywhere
            setVis(app.WLToggleBtn,  true);
            setVis(app.ResetBtn,     true);
            % Overlay +/-: hidden in 2x2 (each pane has its own
            % +/- buttons in 2x2 mode so panes zoom independently).
            setVis(app.ZoomInBtn,    ~is_2x2);
            setVis(app.ZoomOutBtn,   ~is_2x2);
            % Pane-4 Pan toggle (inside the 3-D pane): only in 2x2
            setVis(app.MultiPanToggleBtn, is_2x2);
            % Per-pane zoom +/-: only in 2x2. Position them under
            % each pane's bottom-left corner (panes may have been
            % resized since the buttons were created).
            for kk = 1:numel(app.MultiZoomInBtns)
                in_b  = app.MultiZoomInBtns{kk};
                out_b = app.MultiZoomOutBtns{kk};
                setVis(in_b,  is_2x2);
                setVis(out_b, is_2x2);
                if is_2x2 && ~isempty(app.MultiPanels) && ...
                   numel(app.MultiPanels) >= kk && ...
                   ~isempty(app.MultiPanels{kk}) && ...
                   isvalid(app.MultiPanels{kk})
                    p_pos = app.MultiPanels{kk}.Position;
                    zb_w = 28; zb_h = 22;
                    bx = p_pos(1) + 4;
                    by = p_pos(2) + 4;
                    if ~isempty(in_b) && isvalid(in_b)
                        in_b.Position = [bx, by, zb_w, zb_h];
                    end
                    if ~isempty(out_b) && isvalid(out_b)
                        out_b.Position = [bx + zb_w + 2, by, zb_w, zb_h];
                    end
                end
            end
            % Reflow remaining visible buttons so there are no gaps
            % where hidden buttons used to live.
            repackOverlayTools(app);

            function setVis(h, on)
                if isempty(h) || ~isvalid(h); return; end
                if on; h.Visible = 'on'; else; h.Visible = 'off'; end
            end
        end

        function raiseOverlayTools(app)
            % Force the persistent overlay buttons to the top of the
            % render stack so the 3-D Volume's viewer3d GPU layer
            % can't bury them. Called on every view change.
            for k = 1:numel(app.OverlayTools)
                h = app.OverlayTools{k};
                if ~isempty(h) && isvalid(h)
                    try uistack(h, 'top'); catch; end
                end
            end
            if ~isempty(app.CursorHULabel) && isvalid(app.CursorHULabel)
                try uistack(app.CursorHULabel, 'top'); catch; end
            end
        end

        function resetView(app)
            % Unified reset: AP preset in 3-D Volume; fit-to-data in
            % every other view mode.
            if strcmp(app.ViewMode, '3dvol')
                resetCamera(app);
            else
                app.NeedFitOnRefresh = true;
                refreshMain(app);
            end
        end

        function toggleWLMode(app)
            % Arm/disarm the W/L click-drag tool. Mutually exclusive
            % with the Pan toggle.
            app.WLArmed = ~app.WLArmed;
            if app.WLArmed
                app.WLToggleBtn.Text = 'Drag: W / L  (ON)';
                app.WLToggleBtn.BackgroundColor = [0.95 0.85 0.55];
                % Disarm pan if it was on
                if ~isempty(app.PanToggleBtn) && app.PanToggleBtn.Value
                    app.PanToggleBtn.Value = false;
                    togglePanMode(app);
                end
                app.PanArmed = false;
            else
                app.WLToggleBtn.Text = 'Drag: W / L';
                app.WLToggleBtn.BackgroundColor = [0.92 0.92 0.96];
            end
        end

        % --- Window-level + 2D-pan drag handlers --------------------
        function inside = inImageArea(app, pt)
            % pt is figure-space pixels. ImagePanel + MainAxes
            % together define the click target.
            ip = app.ImagePanel.Position;
            inside = pt(1) >= ip(1) && pt(1) <= ip(1)+ip(3) && ...
                     pt(2) >= ip(2) && pt(2) <= ip(2)+ip(4);
        end

        function onMouseDownTool(app, ~)
            % WindowButtonDownFcn evt has no Button field. Use the
            % figure's SelectionType to filter:
            %   'normal' = left
            %   'alt'    = right or Ctrl+left
            %   'extend' = middle or Shift+left  ← vessel-select
            %   'open'   = double-click
            sel = app.UIFigure.SelectionType;
            pt  = app.UIFigure.CurrentPoint;
            fprintf('[DOWN] sel=%-7s pt=[%4.0f %4.0f]  view=%s  armed=%d\n', ...
                sel, pt(1), pt(2), app.ViewMode, app.VesselPickArmed);
            if ~inImageArea(app, pt)
                fprintf('  → click outside image area, ignoring\n');
                return;
            end

            % Armed "Pick vessel" mode: start LIVE GROW immediately
            % on mouse-down. Rotation is disabled while armed, so
            % left-click is unambiguous → ray-cast → start the
            % iterative dilation grow. The grow loop yields control
            % via drawnow each iteration; onMouseUpTool flips
            % LiveGrowActive=false → loop exits at user's chosen
            % extent. This is the TeraRecon hold-to-grow path.
            if app.VesselPickArmed && strcmp(sel, 'normal')
                in_volshow = false;
                which_view = '';
                if strcmp(app.ViewMode, '3dvol') && ...
                   ~isempty(app.VolPanel) && isvalid(app.VolPanel)
                    in_volshow = true;
                    which_view = 'single';
                elseif strcmp(app.ViewMode, '2x2') && ...
                       ~isempty(app.MultiPanels) && ...
                       numel(app.MultiPanels) >= 4 && ...
                       ~isempty(app.MultiPanels{4}) && ...
                       isvalid(app.MultiPanels{4})
                    p4 = app.MultiPanels{4};
                    abs_p4 = p4.Position;
                    abs_p4(1:2) = abs_p4(1:2) + app.ImagePanel.Position(1:2);
                    if pt(1) >= abs_p4(1) && pt(1) <= abs_p4(1)+abs_p4(3) && ...
                       pt(2) >= abs_p4(2) && pt(2) <= abs_p4(2)+abs_p4(4)
                        in_volshow = true;
                        which_view = 'multi';
                    end
                end
                if in_volshow
                    is_erase = strcmp(app.Tool, 'erase');
                    if is_erase
                        fprintf('  → ARMED click in volshow → ray-cast + ERASE\n');
                        flashSegStatus(app, 'Click registered — ray-casting (erase)…', ...
                            [0.70 0.30 0.00]);
                    else
                        fprintf('  → ARMED click in volshow → ray-cast + grow\n');
                        flashSegStatus(app, 'Click registered — ray-casting…', ...
                            [0.20 0.55 1.00]);
                    end
                    drawnow;
                    if is_erase
                        voxel = vol3DClickToVoxel(app, pt, which_view, 'surface');
                    else
                        voxel = vol3DClickToVoxel(app, pt, which_view);
                    end
                    if isempty(voxel)
                        fprintf('  → ray-cast hit nothing\n');
                        flashSegStatus(app, 'Ray cast hit nothing — rotate and try again', ...
                            [0.85 0.30 0.10]);
                    elseif is_erase
                        fprintf('  → ray-cast voxel=[%d %d %d] → erase\n', voxel);
                        eraseVesselAtVoxel(app, voxel);
                    else
                        fprintf('  → ray-cast voxel=[%d %d %d] HU=%d → segment\n', ...
                            voxel, int32(app.D.vol(voxel(1), voxel(2), voxel(3))));
                        % Run full atomic grow then animate reveal.
                        % Click-and-hold isn't reliable on trackpads, so
                        % we always do the full pipeline and play the
                        % geodesic-distance-ordered reveal as a 1.6 s
                        % expanding-shell animation (already built into
                        % runSegmentation).
                        flashSegStatus(app, sprintf('Picked HU=%d — segmenting…', ...
                            int32(app.D.vol(voxel(1), voxel(2), voxel(3)))), ...
                            [0.20 0.55 1.00]);
                        drawnow;
                        onVesselSelectClick(app, voxel);
                        flashSegStatus(app, sprintf('Done — %.1f mL', ...
                            sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                            app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000), ...
                            [0.10 0.55 0.10]);
                    end
                else
                    fprintf('  → click NOT in volshow panel\n');
                end
                return;
            end

            % Shift+left over the volshow panel = LIVE GROW.
            % TeraRecon-style: hold shift+click, watch the
            % segmentation expand from the seed in real time, and
            % release to commit at your chosen extent.
            if strcmp(sel, 'extend')
                if strcmp(app.ViewMode, '3dvol') && ...
                   ~isempty(app.VolPanel) && isvalid(app.VolPanel)
                    voxel = vol3DClickToVoxel(app, pt, 'single');
                    if ~isempty(voxel)
                        flashSegStatus(app, sprintf('Picked HU=%d — live growing (hold mouse)', ...
                            int32(app.D.vol(voxel(1), voxel(2), voxel(3)))), ...
                            [0.20 0.55 1.00]);
                        liveGrowFromSeed(app, voxel);
                    end
                    return;
                elseif strcmp(app.ViewMode, '2x2') && ...
                       ~isempty(app.MultiPanels) && ...
                       numel(app.MultiPanels) >= 4 && ...
                       ~isempty(app.MultiPanels{4}) && ...
                       isvalid(app.MultiPanels{4})
                    p4 = app.MultiPanels{4};
                    abs_p4 = p4.Position;
                    abs_p4(1:2) = abs_p4(1:2) + app.ImagePanel.Position(1:2);
                    if pt(1) >= abs_p4(1) && pt(1) <= abs_p4(1)+abs_p4(3) && ...
                       pt(2) >= abs_p4(2) && pt(2) <= abs_p4(2)+abs_p4(4)
                        voxel = vol3DClickToVoxel(app, pt, 'multi');
                        if ~isempty(voxel)
                            liveGrowFromSeed(app, voxel);
                        end
                        return;
                    end
                end
                return;
            end

            if ~strcmp(sel, 'normal'); return; end
            if app.WLArmed
                app.IsWLDragging   = true;
                app.WLDragStartXY  = pt;
                app.WLDragStartWL  = app.WL;
            elseif app.PanArmed && ~strcmp(app.ViewMode, '3dvol') && ...
                   ~isempty(app.MainAxes) && isvalid(app.MainAxes)
                % 2-D pan only — 3-D pan is handled by viewer3d itself
                app.IsPanning2D     = true;
                app.Pan2DStartXY    = pt;
                app.Pan2DStartXLim  = app.MainAxes.XLim;
                app.Pan2DStartYLim  = app.MainAxes.YLim;
            end
        end

        function onMouseMotionTool(app, ~)
            % Always update the live HU readout on hover. Cheap and
            % low-rate (matlab dispatches WindowButtonMotionFcn at
            % most every ~30 ms).
            updateCursorHU(app);
            if app.IsWLDragging
                pt = app.UIFigure.CurrentPoint;
                dx = pt(1) - app.WLDragStartXY(1);
                dy = pt(2) - app.WLDragStartXY(2);
                % 4 HU per pixel — feels right at typical CT W/L scales.
                new_w = max(1, app.WLDragStartWL(1) + dx * 4);
                new_l = app.WLDragStartWL(2) + dy * 4;
                setWL(app, [new_w, new_l]);
            elseif app.IsPanning2D
                pt = app.UIFigure.CurrentPoint;
                dx = pt(1) - app.Pan2DStartXY(1);
                dy = pt(2) - app.Pan2DStartXY(2);
                % Convert pixel delta to data-unit delta via current
                % axes scale (data per pixel).
                ax = app.MainAxes;
                if isempty(ax) || ~isvalid(ax); return; end
                axp = ax.Position;
                if axp(3) == 0 || axp(4) == 0; return; end
                xspan = app.Pan2DStartXLim(2) - app.Pan2DStartXLim(1);
                yspan = app.Pan2DStartYLim(2) - app.Pan2DStartYLim(1);
                ddx = -dx * xspan / axp(3);
                ddy =  dy * yspan / axp(4);
                ax.XLim = app.Pan2DStartXLim + ddx;
                ax.YLim = app.Pan2DStartYLim + ddy;
            end
        end

        function onMouseUpTool(app, ~)
            if app.IsWLDragging;  app.IsWLDragging  = false; end
            if app.IsPanning2D;   app.IsPanning2D   = false; end

            % Live grow stop signal — the iterative grow loop in
            % liveGrowFromSeed checks app.LiveGrowActive each
            % iteration via drawnow → this fires here → loop exits
            % at the user's chosen extent.
            if app.LiveGrowActive
                app.LiveGrowActive = false;
                fprintf('[liveGrow] mouse-up → stop signal sent\n');
            end

            % Live grow stop already handled at the top of this
            % function. Armed-mode handling is now mouse-DOWN
            % triggered (live grow starts on press, stops on
            % release) so there's nothing more to do here.
            pt_up = app.UIFigure.CurrentPoint; %#ok<NASGU>
            fprintf('[UP] (armed=%d, liveGrow done)\n', app.VesselPickArmed);
        end

        function setCursorHU(app, txt)
            % Set the cursor-HU readout text AND hide the label when empty,
            % so its dark background never shows as an empty black bar at
            % the bottom of the window. Visible is only touched on change to
            % avoid flicker during mouse-move.
            if isempty(app.CursorHULabel) || ~isvalid(app.CursorHULabel); return; end
            app.CursorHULabel.Text = txt;
            want = 'off'; if ~isempty(txt); want = 'on'; end
            if ~strcmp(char(app.CursorHULabel.Visible), want)
                app.CursorHULabel.Visible = want;
            end
        end

        function flashSegStatus(app, msg, color)
            % Update the side-panel seg_status label as immediate
            % visual feedback during the click → ray-cast → grow
            % flow. Updates SliceLabel too so the message is
            % visible whether the user is looking at the side
            % panel or the bottom of the recon.
            try
                stat = findobj(app.SideContent, 'Tag', 'seg_status');
                if ~isempty(stat) && isvalid(stat)
                    stat.Text = msg;
                    stat.FontColor = color;
                end
                if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                    app.SliceLabel.Text = msg;
                    app.SliceLabel.FontColor = color;
                end
            catch
            end
        end

        function updateCursorHU(app)
            % Update the cursor-HU label from the figure's current
            % mouse position. 2-D MPR + MIP supported; 3-D Volume
            % skipped (volshow doesn't expose a clean cursor → voxel
            % map).
            if isempty(app.CursorHULabel) || ~isvalid(app.CursorHULabel); return; end
            if isempty(app.D) || ~isfield(app.D, 'vol')
                setCursorHU(app, ''); return;
            end
            if strcmp(app.ViewMode, '3dvol') || strcmp(app.ViewMode, 'cpr')
                setCursorHU(app, ''); return;
            end
            if isempty(app.MainAxes) || ~isvalid(app.MainAxes)
                setCursorHU(app, ''); return;
            end
            pt   = app.UIFigure.CurrentPoint;
            ip   = app.ImagePanel.Position;
            ax_p = app.MainAxes.Position;
            abs_x = ip(1) + ax_p(1);
            abs_y = ip(2) + ax_p(2);
            rel_x = pt(1) - abs_x;
            rel_y = pt(2) - abs_y;
            if rel_x < 0 || rel_x > ax_p(3) || rel_y < 0 || rel_y > ax_p(4)
                setCursorHU(app, ''); return;
            end
            xl = app.MainAxes.XLim;
            yl = app.MainAxes.YLim;
            data_x = xl(1) + (rel_x / ax_p(3)) * (xl(2) - xl(1));
            % YDir = reverse for non-axial: figure-y up means data-y down
            if strcmp(app.MainAxes.YDir, 'reverse')
                data_y = yl(1) + (1 - rel_y / ax_p(4)) * (yl(2) - yl(1));
            else
                data_y = yl(1) + (rel_y / ax_p(4)) * (yl(2) - yl(1));
            end
            sz = size(app.D.vol);
            switch app.ViewMode
                case 'axial'
                    iy = round(data_y); ix = round(data_x); iz = app.IdxAxial;
                case 'coronal'
                    iy = app.IdxCoronal; ix = round(data_x); iz = round(data_y);
                case 'sagittal'
                    iy = round(data_x); ix = app.IdxSagittal; iz = round(data_y);
                case '3d'
                    ix = round(data_x); iz = round(data_y); iy = NaN;
                otherwise
                    return;
            end
            if iy < 1 || iy > sz(1) || ix < 1 || ix > sz(2) || ...
               iz < 1 || iz > sz(3)
                setCursorHU(app, ''); return;
            end
            if isnan(iy)
                hu = max(app.D.vol(:, ix, iz));
                setCursorHU(app, sprintf('  x=%d  z=%d  MIP HU=%4.0f  ', ...
                    ix, iz, double(hu)));
            else
                hu = app.D.vol(iy, ix, iz);
                % Voxel → mm location (voxel-1 origin at +Z = head)
                yy_mm = (iy - 1) * app.D.pixel_mm(1);
                xx_mm = (ix - 1) * app.D.pixel_mm(2);
                zz_mm = (iz - 1) * app.D.slice_spacing_mm;
                setCursorHU(app, sprintf( ...
                    '  [%d, %d, %d]  (%.0f, %.0f, %.0f mm)  HU=%4.0f  ', ...
                    iy, ix, iz, yy_mm, xx_mm, zz_mm, double(hu)));
            end
        end

        % --- Snapshot ------------------------------------------------
        function saveSnapshot(app)
            % Save a PNG of the current GUI state to results/snapshots/.
            % Uses exportapp (same path as captureMain) so UI controls
            % are included in the capture.
            here = fileparts(fileparts(which('app.AorticCenterlineApp')));
            snap_dir = fullfile(here, 'results', 'snapshots');
            if ~exist(snap_dir, 'dir'); mkdir(snap_dir); end
            ts = datestr(now, 'yyyymmdd_HHMMSS'); %#ok<DATST,TNOW1>
            fn = fullfile(snap_dir, sprintf('snap_%s.png', ts));
            try
                exportapp(app.UIFigure, fn);
                uialert(app.UIFigure, ...
                    sprintf('Saved: %s', fn), 'Snapshot saved', ...
                    'Icon', 'success');
            catch ME
                uialert(app.UIFigure, ME.message, 'Snapshot failed');
            end
        end

        % --- Recent-files cache --------------------------------------
        function path = recentFilesPath(~)
            here = fileparts(fileparts(which('app.AorticCenterlineApp')));
            log_dir = fullfile(here, 'results', 'logs');
            if ~exist(log_dir, 'dir'); mkdir(log_dir); end
            path = fullfile(log_dir, 'recent_files.json');
        end

        function entries = readRecentFiles(app)
            entries = struct('path', {}, 'kind', {}, 'label', {}, 'ts', {});
            p = recentFilesPath(app);
            if ~exist(p, 'file'); return; end
            try
                txt = fileread(p);
                raw = jsondecode(txt);
                if isstruct(raw); entries = raw(:); end
            catch ME
                fprintf('[recent] read failed: %s\n', ME.message);
            end
        end

        function pushRecentFile(app, file_path, kind, label)
            entries = readRecentFiles(app);
            % De-dupe by path
            keep = true(numel(entries), 1);
            for k = 1:numel(entries)
                if strcmp(entries(k).path, file_path); keep(k) = false; end
            end
            entries = entries(keep);
            new_e = struct('path', file_path, 'kind', kind, ...
                           'label', label, 'ts', datestr(now,'yyyy-mm-dd HH:MM:SS')); %#ok<DATST,TNOW1>
            entries = [new_e; entries(:)];
            % Cap to top 10
            if numel(entries) > 10; entries = entries(1:10); end
            try
                fid = fopen(recentFilesPath(app), 'w');
                fprintf(fid, '%s', jsonencode(entries));
                fclose(fid);
            catch ME
                fprintf('[recent] write failed: %s\n', ME.message);
            end
        end

        function openRecent(app)
            entries = readRecentFiles(app);
            if isempty(entries)
                uialert(app.UIFigure, 'No recent files.', 'Open recent');
                return;
            end
            choices = arrayfun(@(e) sprintf('%s — %s', e.label, e.ts), ...
                entries, 'UniformOutput', false);
            [idx, ok] = listdlg('PromptString', 'Open recent CT:', ...
                'ListString', choices, 'SelectionMode', 'single', ...
                'ListSize', [500 200]);
            if ~ok; return; end
            e = entries(idx);
            if ~exist(e.path, 'file') && ~exist(e.path, 'dir')
                uialert(app.UIFigure, ...
                    sprintf('File no longer exists:\n%s', e.path), ...
                    'Open recent');
                return;
            end
            switch e.kind
                case 'dicom';   doLoad(app, @() preprocess.dicom_load(e.path, true));
                case 'nifti';   doLoad(app, @() loadNifti(e.path));
                case 'cached';  doLoad(app, @() loadCached(e.path));
                case 'phantom'; doLoad(app, @() loadPhantom(e.path));
                otherwise; uialert(app.UIFigure, ...
                    sprintf('Unknown kind "%s"', e.kind), 'Open recent');
            end
        end

        % --- Volume HUD overlay --------------------------------------
        function updateVolHud(app)
            if isempty(app.VolHudLabel) || ~isvalid(app.VolHudLabel); return; end
            if isempty(app.VolViewer) || ~isvalid(app.VolViewer)
                app.VolHudLabel.Text = '';
                return;
            end
            try
                v3d = app.VolViewer.Parent;
                cz = v3d.CameraZoom;
                if isempty(app.D) || ~isfield(app.D, 'vol')
                    sz = [0 0 0];
                else
                    sz = size(app.D.vol);
                end
                % Show current viewer3d interaction mode (rotate vs pan)
                % so the user always knows what drag does.
                try mode_str = char(string(v3d.Interactions)); catch; mode_str = '?'; end
                app.VolHudLabel.Text = sprintf( ...
                    '  Zoom %.2f×    %d × %d × %d    drag = %s  (P toggles)    [F fit, R reset, S snap]', ...
                    cz, sz(1), sz(2), sz(3), upper(mode_str));
            catch
                app.VolHudLabel.Text = '';
            end
        end

        function startupFcn(app)
            createStepBar(app);
            createViewToolbar(app);
            createToolToolbar(app);     % measurement tools row
            createImagePanel(app);
            createOverlayTools(app);
            createSidePanel(app);
            createKeyHintBar(app);
            updateStep(app, 1);
            app.ClickLog = struct('time', {}, 'pane', {}, 'voxel', {}, 'step', {});
        end

        % --- Layout creation ----------------------------------------
        function createStepBar(app)
            app.StepBar = uipanel(app.UIFigure, ...
                'Position', [10 (app.UIFigure.Position(4)-52) (app.UIFigure.Position(3)-20) 32], ...
                'BackgroundColor', [0.95 0.95 0.97], 'BorderType', 'none', ...
                'AutoResizeChildren', 'off');
            steps = { '1. Load CT', '2. Segment aorta', ...
                      '3. Pick endpoints', '4. Compute centerline', ...
                      '5. Analyze (EVAR)', '6. Export' };
            app.StepLabels = cell(6, 1);
            barW = app.UIFigure.Position(3) - 30;
            segW = barW / 6;
            for k = 1:6
                app.StepLabels{k} = uilabel(app.StepBar, ...
                    'Position', [(k-1)*segW + 5, 4, segW - 10, 24], ...
                    'Text', steps{k}, ...
                    'FontSize', 13, 'HorizontalAlignment', 'center', ...
                    'BackgroundColor', [0.90 0.90 0.93], ...
                    'FontColor', [0.4 0.4 0.4]);
            end
        end

        function createViewToolbar(app)
            % View-selector + window/level + 3D-style dropdowns. Width
            % stretches to fill the main area (UIFigure width minus the
            % side panel + margins) so the rightmost dropdown is never
            % clipped.
            barY     = app.UIFigure.Position(4) - 90;
            side_w   = 410;
            margin_x = 30;
            % Toolbar width is the available main area, capped at 900
            % (the natural width needed for all buttons + dropdowns).
            % Using max(900, ...) caused the toolbar to OVERLAP the
            % side panel at narrow window widths (≤ 1340), clipping
            % the rightmost button (DICOM tags) behind the side panel.
            % If the window is too narrow to fit the full toolbar, the
            % rightmost buttons get clipped at the toolbar's own right
            % edge instead — which leaves a clean visible gap to the
            % side panel.
            bar_w    = min(900, app.UIFigure.Position(3) - side_w - margin_x);
            bar_w    = max(bar_w, 300);   % don't let it collapse to zero
            app.ViewToolbar = uipanel(app.UIFigure, ...
                'Position', [10 barY bar_w 32], ...
                'BackgroundColor', 'w', 'BorderType', 'none');
            % Color palette — view buttons are neutral by default; the
            % ACTIVE view is repainted a clear blue by applyViewButtonColors
            % (called at the end of this function and on every setViewMode),
            % so the current view is obvious at a glance.
            VIEW_BG = [0.95 0.96 0.98];
            % Compact button row — shorter labels + tighter spacing so
            % the W/L and 3D Style dropdowns at the right edge fit even
            % at the minimum 1100-px window width (toolbar = ~660 px in
            % that case).
            app.BtnAxial    = uibutton(app.ViewToolbar, 'state', ...
                'Position', [4   2 70 28], 'Text', 'Axial', ...
                'Value', true, 'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'ValueChangedFcn', @(b,~) setViewMode(app, 'axial'));
            app.BtnCoronal  = uibutton(app.ViewToolbar, 'state', ...
                'Position', [78  2 70 28], 'Text', 'Coronal', ...
                'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'ValueChangedFcn', @(b,~) setViewMode(app, 'coronal'));
            app.BtnSagittal = uibutton(app.ViewToolbar, 'state', ...
                'Position', [152 2 70 28], 'Text', 'Sagittal', ...
                'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'ValueChangedFcn', @(b,~) setViewMode(app, 'sagittal'));
            app.Btn3D       = uibutton(app.ViewToolbar, 'state', ...
                'Position', [226 2 70 28], 'Text', '3D MIP', ...
                'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'ValueChangedFcn', @(b,~) setViewMode(app, '3d'));
            app.Btn3DVol    = uibutton(app.ViewToolbar, 'state', ...
                'Position', [300 2 78 28], 'Text', '3D Volume', ...
                'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'ValueChangedFcn', @(b,~) setViewMode(app, '3dvol'));
            app.BtnCPR      = uibutton(app.ViewToolbar, 'state', ...
                'Position', [382 2 60 28], 'Text', 'CPR', ...
                'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'Tooltip', 'Curved Planar Reformat — straightened vessel view', ...
                'ValueChangedFcn', @(b,~) setViewMode(app, 'cpr'));

            % Zoom +/-/Fit are in the persistent overlay (under "Reset
            % view") so they're available on every tab — see
            % createOverlayTools. The freed-up toolbar slot here goes
            % to the 2x2 multi-pane view (axial + sagittal + coronal
            % + 3-D MIP simultaneously, the standard radiology
            % hanging).
            app.Btn2x2 = uibutton(app.ViewToolbar, 'state', ...
                'Position', [450 2 92 28], 'Text', '2×2 multi-pane', ...
                'FontSize', 11, ...
                'BackgroundColor', VIEW_BG, ...
                'Tooltip', ['Show axial + sagittal + coronal + 3-D MIP ' ...
                            'simultaneously in a 2×2 grid.'], ...
                'ValueChangedFcn', @(b,~) setViewMode(app, '2x2'));

            % Compact dropdowns — labels merged into items so we don't
            % need separate "Window:" / "3D Style:" uilabels eating
            % horizontal space. Both fit at the 900-px minimum toolbar
            % width with margin to spare.
            app.WLDropdown = uidropdown(app.ViewToolbar, ...
                'Position', [552 4 150 26], 'FontSize', 11, ...
                'Tooltip', 'Window/level preset', ...
                'Items', {'W: CTA Vessel', ...
                          'W: CTA Wide', ...
                          'W: CTA Bone', ...
                          'W: Abdomen', ...
                          'W: Bone', ...
                          'W: Lung'}, ...
                'ItemsData', {[700 150], [1000 200], [1500 350], [400 40], [1500 400], [1500 -600]}, ...
                'Value', [700 150], ...
                'ValueChangedFcn', @(d,~) setWL(app, d.Value));

            app.VolStyleDropdown = uidropdown(app.ViewToolbar, ...
                'Position', [710 4 175 26], 'FontSize', 11, ...
                'Tooltip', 'Volume rendering transfer function', ...
                'Items', {'3D: Vessels only', ...
                          '3D: CTA Recon', ...
                          '3D: Bone only', ...
                          '3D: MIP', ...
                          '3D: Isosurface'}, ...
                'ItemsData', {'vessel', 'cta_recon', 'bone', 'mip', 'isosurface'}, ...
                'Value', 'vessel', ...
                'ValueChangedFcn', @(d,~) setVolStyle(app, d.Value));

            applyViewButtonColors(app);   % highlight the initial active view
        end

        function createToolToolbar(app)
            % Two toolbar rows below the view toolbar. Row 1:
            % measurement + drawing tools. Row 2: view options +
            % project save / load.
            side_w   = 410;
            margin_x = 30;
            % Toolbar width is the available main area, capped at 900
            % (the natural width needed for all buttons + dropdowns).
            % Using max(900, ...) caused the toolbar to OVERLAP the
            % side panel at narrow window widths (≤ 1340), clipping
            % the rightmost button (DICOM tags) behind the side panel.
            % If the window is too narrow to fit the full toolbar, the
            % rightmost buttons get clipped at the toolbar's own right
            % edge instead — which leaves a clean visible gap to the
            % side panel.
            bar_w    = min(900, app.UIFigure.Position(3) - side_w - margin_x);
            bar_w    = max(bar_w, 300);   % don't let it collapse to zero
            barY1    = app.UIFigure.Position(4) - 90 - 36;
            barY2    = app.UIFigure.Position(4) - 90 - 72;

            app.ToolToolbar = uipanel(app.UIFigure, ...
                'Position', [10 barY1 bar_w 32], ...
                'BackgroundColor', 'w', 'BorderType', 'none');
            app.ToolToolbar2 = uipanel(app.UIFigure, ...
                'Position', [10 barY2 bar_w 32], ...
                'BackgroundColor', 'w', 'BorderType', 'none');

            % --- Color palette ----------------------------------
            % Calm, unified toolbar: tool buttons share one neutral tint
            % so the row reads as a quiet workspace rather than a rainbow.
            % Colour is reserved for SEMANTICS only — a warm tint marks the
            % single destructive action (Clear all). Functional grouping is
            % conveyed by order + the icon/label, not by clashing hues, and
            % the active tool/view shows via the button's pressed state.
            NEUTRAL_BG = [0.95 0.96 0.98];   % all non-destructive tools
            MEAS_BG  = NEUTRAL_BG;
            DRAW_BG  = NEUTRAL_BG;
            NAV_BG   = NEUTRAL_BG;
            DEL_BG   = [0.97 0.89 0.88];      % destructive (Clear all) — muted red
            DISP_BG  = NEUTRAL_BG;
            PROJ_BG  = NEUTRAL_BG;
            INFO_BG  = NEUTRAL_BG;

            % -------- Row 1: measurement + drawing --------------
            x = 4;
            app.BtnMeasure = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 80 28], 'Text', '📏 Measure', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', MEAS_BG, ...
                'Tooltip', ['Linear distance: click two points. ' ...
                            'Length in mm. Line projects onto ' ...
                            'every other view.'], ...
                'ValueChangedFcn', @(b,~) setMeasureMode(app, b, 'measure'));
            x = x + 84;
            app.BtnAngle = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 70 28], 'Text', '∠ Angle', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', MEAS_BG, ...
                'Tooltip', ['Angle: click vertex, then two arm ' ...
                            'endpoints.'], ...
                'ValueChangedFcn', @(b,~) setMeasureMode(app, b, 'angle'));
            x = x + 74;
            app.BtnROIRect = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 70 28], 'Text', '▭ ROI', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', DRAW_BG, ...
                'Tooltip', ['Rectangle ROI with HU statistics ' ...
                            '(mean ± SD, min, max, area).'], ...
                'ValueChangedFcn', @(b,~) setDrawMode(app, b, 'roi_rect'));
            x = x + 74;
            app.BtnROIEllipse = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 80 28], 'Text', '⬭ Ellipse', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', DRAW_BG, ...
                'Tooltip', 'Elliptical ROI with HU statistics.', ...
                'ValueChangedFcn', @(b,~) setDrawMode(app, b, 'roi_ellipse'));
            x = x + 84;
            app.BtnAnnotate = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 80 28], 'Text', 'T Annotate', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', DRAW_BG, ...
                'Tooltip', ['Place a typed text label at a click ' ...
                            'point. Visible across views.'], ...
                'ValueChangedFcn', @(b,~) setDrawMode(app, b, 'annotate'));
            x = x + 84;
            app.BtnWirePath = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 70 28], 'Text', '⤳ Wire', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', DRAW_BG, ...
                'Tooltip', ['Wire-path tool: click multiple points to ' ...
                            'trace a wire trajectory. Click "Finish" or ' ...
                            'press Esc to commit. For AINN State-2 ' ...
                            'ground-truth extraction.'], ...
                'ValueChangedFcn', @(b,~) setDrawMode(app, b, 'wire'));
            x = x + 74;
            app.BtnFinishWire = uibutton(app.ToolToolbar, 'push', ...
                'Position', [x 2 60 28], 'Text', 'Finish', ...
                'FontSize', 11, 'Enable', 'off', ...
                'BackgroundColor', DRAW_BG, ...
                'Tooltip', 'Finish the in-progress wire path.', ...
                'ButtonPushedFcn', @(~,~) finishWirePath(app));
            x = x + 64;
            app.BtnClearMeasure = uibutton(app.ToolToolbar, 'push', ...
                'Position', [x 2 70 28], 'Text', 'Clear all', ...
                'FontSize', 11, ...
                'BackgroundColor', DEL_BG, ...
                'Tooltip', 'Clear measurements, ROIs, annotations, wires.', ...
                'ButtonPushedFcn', @(~,~) clearAllAnnotations(app));
            x = x + 74;
            app.CrosshairLockBtn = uibutton(app.ToolToolbar, 'state', ...
                'Position', [x 2 80 28], 'Text', '✛ Crosshair', ...
                'FontSize', 11, 'Value', true, ...
                'BackgroundColor', NAV_BG, ...
                'Tooltip', ['Linked crosshair across 2x2 panes. ' ...
                            'When on (default), clicking in any pane ' ...
                            'jumps the other panes to that point.'], ...
                'ValueChangedFcn', @(b,~) setCrosshairLocked(app, b.Value));

            % -------- Row 2: view options + project --------------
            x = 4;
            app.BtnAutoWL = uibutton(app.ToolToolbar2, 'push', ...
                'Position', [x 2 80 28], 'Text', 'Auto W/L', ...
                'FontSize', 11, ...
                'BackgroundColor', DISP_BG, ...
                'Tooltip', ['Compute window/level from a robust ' ...
                            'percentile of the volume histogram.'], ...
                'ButtonPushedFcn', @(~,~) autoWL(app));
            x = x + 84;
            app.BtnInvert = uibutton(app.ToolToolbar2, 'state', ...
                'Position', [x 2 70 28], 'Text', '↹ Invert', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', DISP_BG, ...
                'Tooltip', ['Flip intensity polarity in 2-D views. ' ...
                            'Useful for soft-tissue inspection.'], ...
                'ValueChangedFcn', @(b,~) toggleInvert(app, b.Value));
            x = x + 74;
            app.SlabDropdown = uidropdown(app.ToolToolbar2, ...
                'Position', [x 4 130 26], 'FontSize', 11, ...
                'BackgroundColor', DISP_BG, ...
                'Tooltip', ['Slab MIP thickness for 2-D views ' ...
                            '(0 = single-slice MPR).'], ...
                'Items', {'Slab: 0 mm (off)', 'Slab: 5 mm', ...
                          'Slab: 10 mm', 'Slab: 20 mm', ...
                          'Slab: 30 mm', 'Slab: 50 mm'}, ...
                'ItemsData', {0, 5, 10, 20, 30, 50}, ...
                'Value', 0, ...
                'ValueChangedFcn', @(d,~) setSlabThickness(app, d.Value));
            x = x + 134;
            app.BtnPlay = uibutton(app.ToolToolbar2, 'state', ...
                'Position', [x 2 60 28], 'Text', '▶ Play', ...
                'FontSize', 11, 'Value', false, ...
                'BackgroundColor', DISP_BG, ...
                'Tooltip', 'Cine play through slices.', ...
                'ValueChangedFcn', @(b,~) toggleCinePlay(app, b.Value));
            x = x + 64;
            app.CineSpeedDropdown = uidropdown(app.ToolToolbar2, ...
                'Position', [x 4 100 26], 'FontSize', 11, ...
                'BackgroundColor', DISP_BG, ...
                'Tooltip', 'Cine playback speed.', ...
                'Items', {'Speed: slow', 'Speed: medium', 'Speed: fast'}, ...
                'ItemsData', {5, 12, 25}, ...   % fps
                'Value', 12);
            x = x + 104;
            app.BtnSaveProject = uibutton(app.ToolToolbar2, 'push', ...
                'Position', [x 2 90 28], 'Text', '💾 Save proj', ...
                'FontSize', 11, ...
                'BackgroundColor', PROJ_BG, ...
                'Tooltip', ['Save measurements, ROIs, annotations, ' ...
                            'wire path, W/L, view state to a .mat ' ...
                            'project file.'], ...
                'ButtonPushedFcn', @(~,~) saveProject(app));
            x = x + 94;
            app.BtnLoadProject = uibutton(app.ToolToolbar2, 'push', ...
                'Position', [x 2 90 28], 'Text', '📂 Load proj', ...
                'FontSize', 11, ...
                'BackgroundColor', PROJ_BG, ...
                'Tooltip', 'Load a project file from disk.', ...
                'ButtonPushedFcn', @(~,~) loadProject(app));
            x = x + 94;
            app.BtnDicomTags = uibutton(app.ToolToolbar2, 'push', ...
                'Position', [x 2 90 28], 'Text', 'DICOM tags', ...
                'FontSize', 11, ...
                'BackgroundColor', INFO_BG, ...
                'Tooltip', 'Read-only viewer of DICOM tags.', ...
                'ButtonPushedFcn', @(~,~) showDicomTags(app));
        end

        % --- Measurement tool wiring ----------------------------------
        function setMeasureMode(app, btn, mode_name)
            % Toggle a measurement tool. Mutually exclusive with the
            % other measurement tool. When armed, clicks in any 2-D
            % pane drop a point; when N points are collected the
            % measurement is committed and rendered.
            if btn.Value
                app.MeasureMode = mode_name;
                % Deactivate the sibling tool
                switch mode_name
                    case 'measure'
                        if ~isempty(app.BtnAngle) && isvalid(app.BtnAngle)
                            app.BtnAngle.Value = false;
                        end
                    case 'angle'
                        if ~isempty(app.BtnMeasure) && isvalid(app.BtnMeasure)
                            app.BtnMeasure.Value = false;
                        end
                end
                app.PendingPoints = {};
                % Disarm WL / Pan drag tools — they share clicks
                if app.WLArmed && ~isempty(app.WLToggleBtn)
                    app.WLToggleBtn.Value = false;
                    toggleWLMode(app);
                end
                if app.PanArmed && ~isempty(app.PanToggleBtn)
                    app.PanToggleBtn.Value = false;
                    togglePanMode(app);
                end
                hint_label(app, sprintf( ...
                    'Tool armed: %s — click %d point(s).', mode_name, ...
                    measurementPointsNeeded(app, mode_name)));
            else
                app.MeasureMode = '';
                app.PendingPoints = {};
                hint_label(app, '');
            end
            refreshMeasurementOverlay(app);
            refreshToolButtonColors(app);

            function hint_label(app, txt)
                if isempty(app.SliceLabel) || ~isvalid(app.SliceLabel); return; end
                if ~isempty(txt)
                    app.SliceLabel.Text = txt;
                end
            end
        end

        function n = measurementPointsNeeded(~, mode_name)
            switch mode_name
                case 'measure'; n = 2;
                case 'angle';   n = 3;
                otherwise;      n = 0;
            end
        end

        function clearMeasurements(app)
            app.Measurements  = {};
            app.PendingPoints = {};
            refreshMeasurementOverlay(app);
        end

        function img = extractSliceOrSlab(app, view_mode, idx)
            % Return a 2-D image for the given view at slice index
            % `idx`. If app.SlabThickness_mm > 0, take the
            % maximum-intensity projection over a slab of that
            % thickness (in mm) centered on idx. Otherwise return
            % the single slice. Image orientation matches
            % refreshMain: axial = vol(:,:,iz); coronal /
            % sagittal = transposed.
            vol = app.D.vol;
            sz = size(vol);
            T_mm = app.SlabThickness_mm;
            switch view_mode
                case 'axial'
                    if T_mm <= 0
                        img = vol(:, :, idx);
                    else
                        r = max(1, round((T_mm/2) / app.D.slice_spacing_mm));
                        z_lo = max(1, idx - r); z_hi = min(sz(3), idx + r);
                        img = max(vol(:, :, z_lo:z_hi), [], 3);
                    end
                case 'coronal'
                    if T_mm <= 0
                        img = squeeze(vol(idx, :, :)).';
                    else
                        r = max(1, round((T_mm/2) / app.D.pixel_mm(1)));
                        y_lo = max(1, idx - r); y_hi = min(sz(1), idx + r);
                        img = squeeze(max(vol(y_lo:y_hi, :, :), [], 1)).';
                    end
                case 'sagittal'
                    if T_mm <= 0
                        img = squeeze(vol(:, idx, :)).';
                    else
                        r = max(1, round((T_mm/2) / app.D.pixel_mm(2)));
                        x_lo = max(1, idx - r); x_hi = min(sz(2), idx + r);
                        img = squeeze(max(vol(:, x_lo:x_hi, :), [], 2)).';
                    end
                otherwise
                    img = [];
            end
        end

        function s = slabSuffix(app)
            if app.SlabThickness_mm > 0
                s = sprintf('   [slab MIP %.0f mm]', app.SlabThickness_mm);
            else
                s = '';
            end
        end

        function clearAllAnnotations(app)
            % Wipe everything user-drawn in one click — measurements,
            % ROIs, text annotations, and the in-progress wire path.
            app.Measurements  = {};
            app.PendingPoints = {};
            app.ROIs          = {};
            app.Annotations   = {};
            app.WirePath      = [];
            app.WireFinalized = false;
            if ~isempty(app.BtnFinishWire) && isvalid(app.BtnFinishWire)
                app.BtnFinishWire.Enable = 'off';
            end
            refreshMeasurementOverlay(app);
        end

        % --- Display option handlers ---------------------------------
        function toggleInvert(app, on)
            app.InvertDisplay = logical(on);
            redrawCurrentView(app);
        end

        function autoWL(app)
            % Robust percentile-based automatic window/level. Skips
            % the very lowest HU bin (air) which dominates the
            % histogram and blows out the level estimate.
            if isempty(app.D) || ~isfield(app.D, 'vol')
                uialert(app.UIFigure, 'Load a CT first.', 'Auto W/L');
                return;
            end
            v = app.D.vol(:);
            v = v(v > -990);   % drop air
            if isempty(v); return; end
            p1  = double(prctile(v, 1));
            p99 = double(prctile(v, 99));
            W = max(50, p99 - p1);
            L = (p1 + p99) / 2;
            setWL(app, [W L]);
            if ~isempty(app.WLDropdown) && isvalid(app.WLDropdown)
                % Drop the preset selection — Auto WL doesn't match a preset
                try; app.WLDropdown.Value = [W L]; catch; end
            end
            if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                app.SliceLabel.Text = sprintf( ...
                    'Auto W/L: W=%.0f  L=%.0f  (1–99 %%ile of HU)', W, L);
            end
        end

        function setSlabThickness(app, mm)
            app.SlabThickness_mm = mm;
            redrawCurrentView(app);
        end

        function toggleCinePlay(app, on)
            % Start / stop a uitimer that advances the current
            % view's slice index at the chosen frame rate. Wraps at
            % the ends rather than stopping (so the user gets a
            % continuous loop until they hit pause).
            if on
                fps = 12;
                if ~isempty(app.CineSpeedDropdown) && ...
                   isvalid(app.CineSpeedDropdown)
                    fps = double(app.CineSpeedDropdown.Value);
                end
                if isempty(app.CineTimer) || ~isvalid(app.CineTimer)
                    app.CineTimer = timer( ...
                        'Period', max(0.02, 1/fps), ...
                        'ExecutionMode', 'fixedRate', ...
                        'TimerFcn', @(~,~) cineStep(app));
                else
                    stop(app.CineTimer);
                    app.CineTimer.Period = max(0.02, 1/fps);
                end
                app.BtnPlay.Text = '⏸ Pause';
                start(app.CineTimer);
            else
                if ~isempty(app.CineTimer) && isvalid(app.CineTimer)
                    stop(app.CineTimer);
                end
                if ~isempty(app.BtnPlay) && isvalid(app.BtnPlay)
                    app.BtnPlay.Text = '▶ Play';
                end
            end
        end

        function cineStep(app)
            % One frame of cine: advance current view's slice
            % index, wrap at ends, refresh.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            sz = size(app.D.vol);
            switch app.ViewMode
                case 'axial'
                    app.IdxAxial = mod(app.IdxAxial, sz(3)) + 1;
                case 'coronal'
                    app.IdxCoronal = mod(app.IdxCoronal, sz(1)) + 1;
                case 'sagittal'
                    app.IdxSagittal = mod(app.IdxSagittal, sz(2)) + 1;
                case '2x2'
                    app.IdxAxial = mod(app.IdxAxial, sz(3)) + 1;
                otherwise
                    return;
            end
            redrawCurrentView(app);
        end

        function setCrosshairLocked(app, on)
            app.CrosshairLocked = logical(on);
            if ~on
                app.Crosshair = [];
            end
            refreshMeasurementOverlay(app);
        end

        function redrawCurrentView(app)
            % Single dispatch used by all "force a refresh" callers
            % (invert toggle, slab thickness, etc.) so we don't
            % have to know which path is active.
            if strcmp(app.ViewMode, '2x2')
                refreshMultiView(app);
            elseif strcmp(app.ViewMode, '3dvol')
                refreshVolViewer(app);
            else
                refreshMain(app);
            end
        end

        function setDrawMode(app, btn, mode_name)
            % Mutually exclusive arming for ROI / Annotate / Wire.
            % Disarms measurement tools and other drawing tools.
            if btn.Value
                app.DrawMode = mode_name;
                % Disarm peers
                disarmPeer(app.BtnROIRect,    mode_name, 'roi_rect');
                disarmPeer(app.BtnROIEllipse, mode_name, 'roi_ellipse');
                disarmPeer(app.BtnAnnotate,   mode_name, 'annotate');
                disarmPeer(app.BtnWirePath,   mode_name, 'wire');
                % Disarm measurement tools
                if ~isempty(app.BtnMeasure) && app.BtnMeasure.Value
                    app.BtnMeasure.Value = false;
                    setMeasureMode(app, app.BtnMeasure, 'measure');
                end
                if ~isempty(app.BtnAngle) && app.BtnAngle.Value
                    app.BtnAngle.Value = false;
                    setMeasureMode(app, app.BtnAngle, 'angle');
                end
                if app.WLArmed && ~isempty(app.WLToggleBtn)
                    app.WLToggleBtn.Value = false;
                    toggleWLMode(app);
                end
                if app.PanArmed && ~isempty(app.PanToggleBtn)
                    app.PanToggleBtn.Value = false;
                    togglePanMode(app);
                end
                if strcmp(mode_name, 'wire')
                    app.WirePath      = [];
                    app.WireFinalized = false;
                    if ~isempty(app.BtnFinishWire)
                        app.BtnFinishWire.Enable = 'on';
                    end
                end
                if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                    app.SliceLabel.Text = sprintf( ...
                        'Tool armed: %s', mode_name);
                end
            else
                app.DrawMode = '';
                if ~isempty(app.BtnFinishWire)
                    app.BtnFinishWire.Enable = 'off';
                end
            end
            refreshMeasurementOverlay(app);
            refreshToolButtonColors(app);

            function disarmPeer(b, active_mode, my_mode)
                if isempty(b) || ~isvalid(b); return; end
                if ~strcmp(active_mode, my_mode); b.Value = false; end
            end
        end

        function finishWirePath(app)
            % Commit the in-progress wire path. Subsequent clicks
            % won't extend it; user can clear or Save Project.
            if isempty(app.WirePath); return; end
            app.WireFinalized = true;
            if ~isempty(app.BtnFinishWire) && isvalid(app.BtnFinishWire)
                app.BtnFinishWire.Enable = 'off';
            end
            if ~isempty(app.BtnWirePath) && isvalid(app.BtnWirePath)
                app.BtnWirePath.Value = false;
                app.DrawMode = '';
            end
            refreshMeasurementOverlay(app);
        end

        function showDicomTags(app)
            % Pop a modal with the DICOM tag set captured at load
            % time. preprocess.dicom_load stores a few tags on the
            % D struct; we surface whatever is available.
            if isempty(app.D) || ~isfield(app.D, 'vol')
                uialert(app.UIFigure, 'Load a CT first.', 'DICOM tags');
                return;
            end
            f = uifigure('Name', 'DICOM tags', 'Position', [200 200 640 500]);
            tbl = uitable(f, 'Position', [10 10 620 480], ...
                'ColumnName', {'Tag', 'Value'}, ...
                'ColumnWidth', {220, 380});
            % Accumulate rows directly — anonymous-function closures
            % in MATLAB capture variables by value at definition
            % time, so a `push` lambda would not see the growing
            % cell array.
            rows = cell(0, 2);
            % Surface known top-level D fields. preprocess.dicom_load
            % uses snake_case here.
            top_fields = {'patient_id', 'study_date', 'study_time', ...
                'modality', 'manufacturer', 'manufacturer_model_name', ...
                'study_description', 'series_description', ...
                'series_number', 'rows', 'cols', 'n_frames', ...
                'pixel_mm', 'slice_spacing_mm'};
            for k = 1:numel(top_fields)
                n = top_fields{k};
                if isfield(app.D, n)
                    rows = [rows; {n, valueToString(app.D.(n))}]; %#ok<AGROW>
                end
            end
            % Then dump whatever is in D.info_first (original
            % dicominfo). Skip large byte blobs and nested structs.
            if isfield(app.D, 'info_first') && ...
               isstruct(app.D.info_first)
                info = app.D.info_first;
                fns = fieldnames(info);
                for k = 1:numel(fns)
                    n = fns{k};
                    v = info.(n);
                    if numel(v) > 64 && isnumeric(v); continue; end
                    if isstruct(v); continue; end
                    rows = [rows; {n, valueToString(v)}]; %#ok<AGROW>
                end
            end
            % Always show derived fields the app cares about
            sz = size(app.D.vol);
            rows = [rows; { ...
                '(derived) Volume size', ...
                sprintf('%d × %d × %d voxels', sz(2), sz(1), sz(3))}];
            rows = [rows; { ...
                '(derived) In-plane voxel', ...
                sprintf('%.3f × %.3f mm', ...
                    app.D.pixel_mm(2), app.D.pixel_mm(1))}];
            rows = [rows; { ...
                '(derived) Slice spacing', ...
                sprintf('%.3f mm', app.D.slice_spacing_mm)}];
            tbl.Data = rows;

            function s = valueToString(v)
                if ischar(v) || (isstring(v) && isscalar(v))
                    s = char(v);
                elseif isnumeric(v) && numel(v) <= 12
                    s = mat2str(v);
                elseif isnumeric(v)
                    s = sprintf('[%dx%d %s]', size(v,1), size(v,2), class(v));
                else
                    s = sprintf('<%s>', class(v));
                end
            end
        end

        function saveProject(app)
            % Persist all user-drawn state (measurements, ROIs,
            % annotations, wire path, W/L, view + slice indices,
            % invert + slab settings) to a .mat file. Volume data
            % itself is not stored — only the path and a hash so
            % the loader can reattach to the right CT.
            [fn, fp] = uiputfile({'*.mat', 'EVAR project (*.mat)'}, ...
                'Save project', 'evar_project.mat');
            if isequal(fn, 0); return; end
            P = struct();
            P.version          = 1;
            P.saved_at         = char(datetime('now'));
            P.WL               = app.WL;
            P.InvertDisplay    = app.InvertDisplay;
            P.SlabThickness_mm = app.SlabThickness_mm;
            P.IdxAxial         = app.IdxAxial;
            P.IdxCoronal       = app.IdxCoronal;
            P.IdxSagittal      = app.IdxSagittal;
            P.ViewMode         = app.ViewMode;
            P.Measurements     = app.Measurements;
            P.ROIs             = app.ROIs;
            P.Annotations      = app.Annotations;
            P.WirePath         = app.WirePath;
            P.WireFinalized    = app.WireFinalized;
            P.SeedSeg          = app.SeedSeg;
            P.SeedProximal     = app.SeedProximal;
            P.SeedRightCFA     = app.SeedRightCFA;
            P.SeedLeftCFA      = app.SeedLeftCFA;
            % Volume identification — store size + a fingerprint of
            % a few HU values so the loader can warn on mismatch.
            if ~isempty(app.D) && isfield(app.D, 'vol')
                P.vol_size = size(app.D.vol);
                v = double(app.D.vol);
                P.vol_fingerprint = [v(1) v(end) mean(v(:))];
                P.pixel_mm = app.D.pixel_mm;
                P.slice_spacing_mm = app.D.slice_spacing_mm;
            end
            try
                save(fullfile(fp, fn), '-struct', 'P');
                if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                    app.SliceLabel.Text = sprintf('Saved project to %s', fn);
                end
            catch ME
                uialert(app.UIFigure, ...
                    sprintf('Save failed: %s', ME.message), 'Save project');
            end
        end

        function loadProject(app)
            [fn, fp] = uigetfile({'*.mat', 'EVAR project (*.mat)'}, ...
                'Load project');
            if isequal(fn, 0); return; end
            try
                P = load(fullfile(fp, fn));
            catch ME
                uialert(app.UIFigure, ...
                    sprintf('Load failed: %s', ME.message), 'Load project');
                return;
            end
            % Volume sanity check
            if ~isempty(app.D) && isfield(app.D, 'vol') && ...
               isfield(P, 'vol_size')
                if ~isequal(size(app.D.vol), P.vol_size)
                    uialert(app.UIFigure, sprintf( ...
                        ['Project was saved with a different volume ' ...
                         '(saved %s, loaded %s). Loading anyway, ' ...
                         'but coordinates may not align.'], ...
                        mat2str(P.vol_size), mat2str(size(app.D.vol))), ...
                        'Load project — volume mismatch', 'Icon', 'warning');
                end
            end
            % Restore fields that exist
            assignIf(P, 'WL',               'WL');
            assignIf(P, 'InvertDisplay',    'InvertDisplay');
            assignIf(P, 'SlabThickness_mm', 'SlabThickness_mm');
            assignIf(P, 'IdxAxial',         'IdxAxial');
            assignIf(P, 'IdxCoronal',       'IdxCoronal');
            assignIf(P, 'IdxSagittal',      'IdxSagittal');
            assignIf(P, 'Measurements',     'Measurements');
            assignIf(P, 'ROIs',             'ROIs');
            assignIf(P, 'Annotations',      'Annotations');
            assignIf(P, 'WirePath',         'WirePath');
            assignIf(P, 'WireFinalized',    'WireFinalized');
            assignIf(P, 'SeedSeg',          'SeedSeg');
            assignIf(P, 'SeedProximal',     'SeedProximal');
            assignIf(P, 'SeedRightCFA',     'SeedRightCFA');
            assignIf(P, 'SeedLeftCFA',      'SeedLeftCFA');
            % Sync UI controls to restored state
            if ~isempty(app.BtnInvert) && isvalid(app.BtnInvert)
                app.BtnInvert.Value = app.InvertDisplay;
            end
            if ~isempty(app.SlabDropdown) && isvalid(app.SlabDropdown)
                try; app.SlabDropdown.Value = app.SlabThickness_mm; catch; end
            end
            % Re-render
            if isfield(P, 'ViewMode') && ~isempty(P.ViewMode)
                setView(app, P.ViewMode);
            else
                redrawCurrentView(app);
            end
            refreshMeasurementOverlay(app);
            if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                app.SliceLabel.Text = sprintf( ...
                    'Loaded project from %s', fn);
            end

            function assignIf(P, fld, prop)
                if isfield(P, fld)
                    app.(prop) = P.(fld);
                end
            end
        end

        function onMeasureClick(app, voxel)
            % Append a voxel-space point to the in-progress
            % measurement. When enough points are collected, commit
            % it to app.Measurements and re-render.
            if isempty(app.MeasureMode); return; end
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            sz = size(app.D.vol);
            voxel(1) = max(1, min(sz(1), voxel(1)));
            voxel(2) = max(1, min(sz(2), voxel(2)));
            voxel(3) = max(1, min(sz(3), voxel(3)));
            app.PendingPoints{end+1} = voxel(:).';
            n_needed = measurementPointsNeeded(app, app.MeasureMode);
            if numel(app.PendingPoints) >= n_needed
                m = struct();
                m.kind   = app.MeasureMode;
                m.points = vertcat(app.PendingPoints{:});  % N x 3 (iy,ix,iz)
                sx    = app.D.pixel_mm(2);
                sy    = app.D.pixel_mm(1);
                sz_mm = app.D.slice_spacing_mm;
                P_mm  = m.points .* [sy sx sz_mm];
                if strcmp(m.kind, 'measure')
                    d = norm(P_mm(2,:) - P_mm(1,:));
                    m.length_mm = d;
                    m.label     = sprintf('%.1f mm', d);
                else
                    v1 = P_mm(1,:) - P_mm(2,:);
                    v2 = P_mm(3,:) - P_mm(2,:);
                    ang = atan2d(norm(cross(v1, v2)), dot(v1, v2));
                    m.angle_deg = ang;
                    m.label     = sprintf('%.1f°', ang);
                end
                m.color = [1.00 0.85 0.20];   % radiology-yellow
                app.Measurements{end+1} = m;
                app.PendingPoints = {};
            end
            refreshMeasurementOverlay(app);
        end

        function refreshMeasurementOverlay(app)
            % Repaint measurements onto whichever 2-D axes are
            % currently visible AND onto whichever volshow viewer3d
            % is active. Underlying images aren't touched — we only
            % delete and redraw graphics tagged 'measurement_graphic'
            % on 2-D, and update a sparse annotation volshow on 3-D.
            if strcmp(app.ViewMode, '2x2')
                modes = {'axial', 'sagittal', 'coronal'};
                for k = 1:3
                    if numel(app.MultiAxes) >= k && ...
                       ~isempty(app.MultiAxes{k}) && ...
                       isvalid(app.MultiAxes{k})
                        renderMeasurementsOn(app, app.MultiAxes{k}, ...
                            modes{k});
                    end
                end
                % Pane 4: viewer3d annotation overlay
                refreshMeasurement3DOverlay(app, 'multi');
            else
                if ~isempty(app.MainAxes) && isvalid(app.MainAxes)
                    renderMeasurementsOn(app, app.MainAxes, app.ViewMode);
                end
                if strcmp(app.ViewMode, '3dvol')
                    refreshMeasurement3DOverlay(app, 'single');
                end
            end
        end

        function refreshMeasurement3DOverlay(app, which_view)
            % Rasterize every committed measurement segment into a
            % small uint8 annotation volume and composite it as a
            % SECOND volshow on the target viewer3d.
            %
            % R2025b's viewer3d rejects Line / Patch / Surface
            % primitives but accepts multiple Volume children. The
            % overlay volume is independently downsampled to a small
            % cap (Overlay3DCap, default 96 voxels max-dim) — much
            % more aggressive than the CT render's downsample —
            % because (a) the annotation is just a thin line and
            % loses nothing at low resolution, and (b) two large
            % volumes on the same viewer3d can crash MATLAB's GPU
            % renderer on integrated graphics. Anything that goes
            % wrong inside the volshow call is swallowed by a
            % try/catch + Disable3DOverlay kill switch so a renderer
            % failure can never take down the whole app.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            if app.Disable3DOverlay; return; end
            switch which_view
                case 'single'
                    src_viewer = app.VolViewer;
                case 'multi'
                    src_viewer = app.Multi3DViewer;
                otherwise
                    return;
            end
            if isempty(src_viewer) || ~isvalid(src_viewer); return; end
            v3d = src_viewer.Parent;
            if isempty(v3d) || ~isvalid(v3d); return; end

            % If we have no measurements, hide / remove any
            % existing overlay and bail.
            if isempty(app.Measurements)
                hideOverlay(app, which_view);
                return;
            end

            % Independent downsample for the overlay volume — keep
            % its largest dim <= Overlay3DCap. The overlay is just a
            % thin line, so over-downsampling costs nothing and
            % keeps the GPU pipeline safe.
            sz_orig = size(app.D.vol);
            ds = max(1, ceil(max(sz_orig) / app.Overlay3DCap));
            sz_v = floor(sz_orig / ds);
            sz_v = max(sz_v, 1);

            % Build the annotation volume. The overlay's coordinate
            % system is independent of the CT render's, but it
            % shares the viewer3d, so volshow places the volume at
            % world (1..sz_v(2), 1..sz_v(1), 1..sz_v(3)). The CT
            % volume has a different size — viewer3d composites by
            % world coordinate, so we scale our points so the line
            % lands in approximately the right place relative to
            % what the user sees.
            % Map orig voxel -> overlay voxel: scale by sz_v ./ sz_orig
            scale = sz_v ./ sz_orig;
            ann = zeros(sz_v, 'uint8');
            for k = 1:numel(app.Measurements)
                m = app.Measurements{k};
                P = m.points;
                P_v = round(P .* scale);
                P_v = max(1, min(repmat(sz_v, size(P,1), 1), P_v));
                % Apply the same Z-flip the CT render uses
                % (refreshVolViewer / refreshMulti3DPane do
                % flip(Vn,3) so head ends up at top of the panel).
                P_v(:, 3) = sz_v(3) - P_v(:, 3) + 1;
                P_v = max(1, min(repmat(sz_v, size(P_v,1), 1), P_v));

                if strcmp(m.kind, 'measure')
                    pairs = [1 2];
                else
                    pairs = [1 2; 2 3];
                end
                for p = 1:size(pairs, 1)
                    a_v = P_v(pairs(p, 1), :);
                    b_v = P_v(pairs(p, 2), :);
                    ann = rasterizeLineInto3DVol(app, ann, a_v, b_v);
                end
            end

            % Bright-yellow transfer function. Anything > 0 is
            % opaque yellow; the 0 background is fully transparent.
            cmap = repmat([1.0 0.92 0.20], 256, 1);
            amap = ones(256, 1);
            amap(1) = 0;

            try
                if strcmp(which_view, 'single')
                    if isempty(app.Vol3DOverlay) || ~isvalid(app.Vol3DOverlay)
                        app.Vol3DOverlay = volshow(ann, 'Parent', v3d, ...
                            'RenderingStyle', 'VolumeRendering', ...
                            'Colormap', cmap, 'Alphamap', amap);
                    else
                        app.Vol3DOverlay.Data     = ann;
                        app.Vol3DOverlay.Colormap = cmap;
                        app.Vol3DOverlay.Alphamap = amap;
                        app.Vol3DOverlay.Visible  = 'on';
                    end
                else  % 'multi'
                    if isempty(app.Multi3DOverlay) || ~isvalid(app.Multi3DOverlay)
                        app.Multi3DOverlay = volshow(ann, 'Parent', v3d, ...
                            'RenderingStyle', 'VolumeRendering', ...
                            'Colormap', cmap, 'Alphamap', amap);
                    else
                        app.Multi3DOverlay.Data     = ann;
                        app.Multi3DOverlay.Colormap = cmap;
                        app.Multi3DOverlay.Alphamap = amap;
                        app.Multi3DOverlay.Visible  = 'on';
                    end
                end
            catch ME
                fprintf(['[refreshMeasurement3DOverlay/%s] %s\n' ...
                         'Disabling 3-D overlay for this session ' ...
                         '(measurements still visible on 2-D MPR + ' ...
                         '3-D MIP). Re-enable with ' ...
                         'app.Disable3DOverlay = false;\n'], ...
                    which_view, ME.message);
                app.Disable3DOverlay = true;
            end

            function hideOverlay(app, wv)
                if strcmp(wv, 'single')
                    h = app.Vol3DOverlay;
                else
                    h = app.Multi3DOverlay;
                end
                if ~isempty(h) && isvalid(h)
                    try; h.Visible = 'off'; catch; end
                end
            end
        end

        function refreshMaskLabel3DOverlay(app, which_view)
            % Composite the colored MaskLabel volume on top of the
            % CT volshow as a SECOND volshow Volume child. Each
            % label k tints with LabelColors(k,:). Aggressive
            % downsampling (Overlay3DCap) keeps the multi-volume
            % render stable on integrated GPUs.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            if app.Disable3DOverlay; return; end
            switch which_view
                case 'single'
                    src_viewer = app.VolViewer;
                case 'multi'
                    src_viewer = app.Multi3DViewer;
                otherwise
                    return;
            end
            if isempty(src_viewer) || ~isvalid(src_viewer); return; end
            v3d = src_viewer.Parent;
            if isempty(v3d) || ~isvalid(v3d); return; end

            % Empty / no labels — hide existing overlay
            if isempty(app.MaskLabel) || ~any(app.MaskLabel(:))
                hideMaskLabelOverlay(app, which_view);
                return;
            end

            % Match the CT render's downsample so labels project
            % to the same world coordinates the CT volshow uses.
            sz_orig = size(app.D.vol);
            switch which_view
                case 'single'
                    ds = max(1, floor(max(sz_orig) / 512));
                case 'multi'
                    ds = max(1, floor(max(sz_orig) / 320));
            end
            sz_v = floor(sz_orig / ds);
            sz_v = max(sz_v, 1);

            % Build the downsampled label volume by nearest-neighbor
            % decimation. Keeps labels crisp (no averaging into 0).
            ann = zeros(sz_v, 'uint8');
            for k = 1:sz_v(3)
                src_k = min(sz_orig(3), max(1, round(k * ds)));
                src_slice = app.MaskLabel(:, :, src_k);
                ann(:, :, k) = src_slice(...
                    min(sz_orig(1), max(1, round((1:sz_v(1)) * ds))), ...
                    min(sz_orig(2), max(1, round((1:sz_v(2)) * ds))));
            end
            % Apply the same Z-flip the CT render uses
            ann = flip(ann, 3);

            % After Step 2 finishes (Step >= 3) the CT volshow is
            % already masked down to only segmented voxels and
            % rendered in its natural CTA color (the standard
            % isolated-vessel report look). The label overlay
            % would just paint over that natural color in
            % multi-color labels, which is NOT what the user wants
            % to see when reviewing the result. So skip the label
            % overlay entirely at Step >= 3 — let the natural
            % isolated render speak for itself.
            if app.Step > 2
                hideMaskLabelOverlay(app, which_view);
                return;
            end

            % During Step 2 (active segmentation), label colors
            % tell the user which click contributed which voxels.
            % Alpha 0.85 — color shift is unmistakable but the
            % underlying CT vessel structure stays partly visible
            % so the user can confirm what they actually selected.
            n_lut = size(app.LabelColors, 1);
            cmap = zeros(256, 3);
            amap = zeros(256, 1);
            for kk = 1:255
                col = app.LabelColors(mod(kk - 1, n_lut) + 1, :);
                cmap(kk + 1, :) = col;
                amap(kk + 1)    = 0.85;
            end

            try
                if strcmp(which_view, 'single')
                    if isempty(app.VolLabel3DOverlay) || ...
                       ~isvalid(app.VolLabel3DOverlay)
                        app.VolLabel3DOverlay = volshow(ann, 'Parent', v3d, ...
                            'RenderingStyle', 'VolumeRendering', ...
                            'Colormap', cmap, 'Alphamap', amap);
                    else
                        app.VolLabel3DOverlay.Data     = ann;
                        app.VolLabel3DOverlay.Colormap = cmap;
                        app.VolLabel3DOverlay.Alphamap = amap;
                        app.VolLabel3DOverlay.Visible  = 'on';
                    end
                else
                    if isempty(app.MultiLabel3DOverlay) || ...
                       ~isvalid(app.MultiLabel3DOverlay)
                        app.MultiLabel3DOverlay = volshow(ann, 'Parent', v3d, ...
                            'RenderingStyle', 'VolumeRendering', ...
                            'Colormap', cmap, 'Alphamap', amap);
                    else
                        app.MultiLabel3DOverlay.Data     = ann;
                        app.MultiLabel3DOverlay.Colormap = cmap;
                        app.MultiLabel3DOverlay.Alphamap = amap;
                        app.MultiLabel3DOverlay.Visible  = 'on';
                    end
                end
            catch ME
                fprintf(['[refreshMaskLabel3DOverlay/%s] %s\n' ...
                         'Disabling 3-D overlays for this session.\n'], ...
                    which_view, ME.message);
                app.Disable3DOverlay = true;
            end

            function hideMaskLabelOverlay(app, wv)
                if strcmp(wv, 'single')
                    h = app.VolLabel3DOverlay;
                else
                    h = app.MultiLabel3DOverlay;
                end
                if ~isempty(h) && isvalid(h)
                    try; h.Visible = 'off'; catch; end
                end
            end
        end

        function ann = rasterizeLineInto3DVol(~, ann, a_v, b_v)
            % Draw a thin 3-D line from a_v to b_v (both 1x3 voxel
            % indices in rendered Vn space) into the annotation
            % volume with value=255. The line is thickened to a
            % 3x3x3 cube around each rasterized point so the
            % volshow has enough opacity to actually show in the
            % composite render — single-voxel lines disappear at
            % typical alpha settings.
            sz_v = size(ann);
            d = b_v - a_v;
            n = max(1, max(abs(d)) * 2);   % oversample ×2 for smooth line
            for i = 0:n
                t = i / n;
                p = round(a_v + t * d);
                p = max(1, min(sz_v, p));
                yr = max(1, p(1)-1):min(sz_v(1), p(1)+1);
                xr = max(1, p(2)-1):min(sz_v(2), p(2)+1);
                zr = max(1, p(3)-1):min(sz_v(3), p(3)+1);
                ann(yr, xr, zr) = uint8(255);
            end
        end

        function renderMeasurementsOn(app, ax, view_mode)
            % Project every committed and pending measurement from
            % voxel space onto this view's image plane and draw it.
            % Solid line if the segment is within
            % MeasureSliceTol_mm of the current slice plane;
            % otherwise dashed and dimmer (so the user always sees
            % what they measured, with a clear in-plane / out-of-
            % plane visual cue).
            if isempty(ax) || ~isvalid(ax); return; end
            delete(findall(ax, 'Tag', 'measurement_graphic'));
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end

            sx    = app.D.pixel_mm(2);
            sy    = app.D.pixel_mm(1);
            sz_mm = app.D.slice_spacing_mm;
            switch view_mode
                case 'axial'
                    slice_idx = app.IdxAxial;
                    out_axis  = 3;  out_mm = sz_mm;
                case 'sagittal'
                    slice_idx = app.IdxSagittal;
                    out_axis  = 2;  out_mm = sx;
                case 'coronal'
                    slice_idx = app.IdxCoronal;
                    out_axis  = 1;  out_mm = sy;
                case '3d'
                    slice_idx = NaN;  out_axis = 1;  out_mm = 0;
                case 'cpr'
                    return;   % CPR is straightened; skip overlay
                otherwise
                    return;
            end

            % Build the list to draw: committed measurements + the
            % in-progress one (drawn dotted-orange so the user can
            % see partial progress while still clicking).
            all_meas = app.Measurements;
            partial  = [];
            if ~isempty(app.PendingPoints) && ~isempty(app.MeasureMode)
                partial = struct();
                partial.kind       = app.MeasureMode;
                partial.points     = vertcat(app.PendingPoints{:});
                partial.label      = '...';
                partial.color      = [1.0 0.55 0.10];
                partial.is_partial = true;
            end

            for i = 1:numel(all_meas) + ~isempty(partial)
                if i <= numel(all_meas)
                    m = all_meas{i};
                    is_partial = false;
                else
                    m = partial;
                    is_partial = true;
                end

                P = m.points;
                [X, Y] = projectToView(P, view_mode);

                % Out-of-plane test — measurement is "in-plane" if
                % its closest endpoint is within tolerance of the
                % current slice plane.
                if ~isnan(slice_idx)
                    d_oop = abs(P(:, out_axis) - slice_idx) * out_mm;
                    in_plane = min(d_oop) < app.MeasureSliceTol_mm;
                else
                    in_plane = true;
                end

                base_color = m.color;
                if is_partial
                    line_color = base_color; line_w = 1.5; line_style = ':';
                elseif in_plane
                    line_color = base_color; line_w = 2.0; line_style = '-';
                else
                    line_color = base_color * 0.65; line_w = 1.0; line_style = '--';
                end

                if strcmp(m.kind, 'measure')
                    if numel(X) >= 2
                        line(ax, [X(1) X(2)], [Y(1) Y(2)], ...
                             'Color', line_color, 'LineWidth', line_w, ...
                             'LineStyle', line_style, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                    if ~isempty(X)
                        line(ax, X, Y, 'Marker', 'o', ...
                             'LineStyle', 'none', ...
                             'MarkerFaceColor', line_color, ...
                             'MarkerEdgeColor', 'k', 'MarkerSize', 5, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                    if ~is_partial && numel(X) >= 2
                        text(ax, mean(X(1:2)), mean(Y(1:2)), ...
                             ['  ', m.label], 'Color', line_color, ...
                             'FontWeight', 'bold', 'FontSize', 10, ...
                             'BackgroundColor', [0 0 0 0.6], ...
                             'Margin', 1.2, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                else  % angle
                    if numel(X) >= 2
                        line(ax, [X(1) X(2)], [Y(1) Y(2)], ...
                             'Color', line_color, 'LineWidth', line_w, ...
                             'LineStyle', line_style, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                    if numel(X) >= 3
                        line(ax, [X(2) X(3)], [Y(2) Y(3)], ...
                             'Color', line_color, 'LineWidth', line_w, ...
                             'LineStyle', line_style, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                    if ~isempty(X)
                        line(ax, X, Y, 'Marker', 'o', ...
                             'LineStyle', 'none', ...
                             'MarkerFaceColor', line_color, ...
                             'MarkerEdgeColor', 'k', 'MarkerSize', 5, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                    if ~is_partial && numel(X) >= 3
                        text(ax, X(2), Y(2), ['  ', m.label], ...
                             'Color', line_color, ...
                             'FontWeight', 'bold', 'FontSize', 10, ...
                             'BackgroundColor', [0 0 0 0.6], ...
                             'Margin', 1.2, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                end
            end

            % --- ROIs ----------------------------------------------
            % Draw every committed ROI on its originating view as a
            % solid green outline; on other views, project the
            % bounding box and draw dashed (since the ROI lives in
            % a single slice). Stats label sits at the upper-left
            % corner.
            roi_partial_p1 = [];
            if ~isempty(app.PendingPoints) && ...
               (strcmp(app.DrawMode, 'roi_rect') || ...
                strcmp(app.DrawMode, 'roi_ellipse')) && ...
               ~isempty(app.PendingPoints{1})
                roi_partial_p1 = app.PendingPoints{1};
            end
            for i = 1:numel(app.ROIs)
                roi = app.ROIs{i};
                drawROI(roi, false);
            end
            if ~isempty(roi_partial_p1)
                % Draw the anchor as a lone marker so the user has
                % visual feedback while picking the second corner.
                Pa = roi_partial_p1;
                [Xa, Ya] = projectToView(Pa, view_mode);
                line(ax, Xa, Ya, 'Marker', 's', 'LineStyle', 'none', ...
                     'MarkerFaceColor', [0.20 0.85 0.30], ...
                     'MarkerEdgeColor', 'k', 'MarkerSize', 8, ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
            end

            % --- Wire path ----------------------------------------
            if ~isempty(app.WirePath)
                P = app.WirePath;
                [X, Y] = projectToView(P, view_mode);
                if ~isnan(slice_idx) && size(P,1) >= 1
                    d_oop = abs(P(:, out_axis) - slice_idx) * out_mm;
                    in_plane_v = d_oop < app.MeasureSliceTol_mm;
                else
                    in_plane_v = true(size(P,1),1);
                end
                wire_color = [1.00 0.30 0.85];   % magenta — distinct
                if app.WireFinalized
                    main_w = 2.4; main_style = '-';
                else
                    main_w = 1.6; main_style = ':';
                end
                if numel(X) >= 2
                    % Solid for in-plane segments, dashed otherwise.
                    for k = 1:size(P,1)-1
                        seg_in = in_plane_v(k) || in_plane_v(k+1);
                        if seg_in
                            ls = main_style; lw = main_w; col = wire_color;
                        else
                            ls = '--';  lw = 0.8; col = wire_color * 0.6;
                        end
                        line(ax, [X(k) X(k+1)], [Y(k) Y(k+1)], ...
                             'Color', col, 'LineWidth', lw, ...
                             'LineStyle', ls, ...
                             'Tag', 'measurement_graphic', ...
                             'PickableParts', 'none');
                    end
                end
                line(ax, X, Y, 'Marker', '.', 'LineStyle', 'none', ...
                     'MarkerEdgeColor', wire_color, 'MarkerSize', 12, ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
                if app.WireFinalized && numel(X) >= 1
                    text(ax, X(1), Y(1), '  wire', ...
                         'Color', wire_color, 'FontSize', 9, ...
                         'BackgroundColor', [0 0 0 0.5], 'Margin', 1, ...
                         'Tag', 'measurement_graphic', ...
                         'PickableParts', 'none');
                end
            end

            % --- Annotations -------------------------------------
            for i = 1:numel(app.Annotations)
                ann = app.Annotations{i};
                P = ann.voxel(:).';
                [X, Y] = projectToView(P, view_mode);
                if ~isnan(slice_idx)
                    d_oop = abs(P(:, out_axis) - slice_idx) * out_mm;
                    in_plane_a = d_oop < app.MeasureSliceTol_mm;
                else
                    in_plane_a = true;
                end
                if in_plane_a
                    col = ann.color; mk_sz = 7;
                else
                    col = ann.color * 0.55; mk_sz = 4;
                end
                line(ax, X, Y, 'Marker', 'o', 'LineStyle', 'none', ...
                     'MarkerFaceColor', col, 'MarkerEdgeColor', 'k', ...
                     'MarkerSize', mk_sz, ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
                text(ax, X, Y, ['  ', ann.text], ...
                     'Color', col, 'FontSize', 10, ...
                     'BackgroundColor', [0 0 0 0.55], 'Margin', 1.2, ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
            end

            % --- Linked crosshair --------------------------------
            if ~isempty(app.Crosshair) && app.CrosshairLocked && ...
               strcmp(app.ViewMode, '2x2')
                P = app.Crosshair(:).';
                [Xc, Yc] = projectToView(P, view_mode);
                xl = ax.XLim; yl = ax.YLim;
                col_c = [0.20 1.00 1.00];
                line(ax, [xl(1) xl(2)], [Yc Yc], 'Color', col_c, ...
                     'LineWidth', 0.7, 'LineStyle', ':', ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
                line(ax, [Xc Xc], [yl(1) yl(2)], 'Color', col_c, ...
                     'LineWidth', 0.7, 'LineStyle', ':', ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
                line(ax, Xc, Yc, 'Marker', '+', 'LineStyle', 'none', ...
                     'MarkerEdgeColor', col_c, 'MarkerSize', 10, ...
                     'LineWidth', 1.5, ...
                     'Tag', 'measurement_graphic', ...
                     'PickableParts', 'none');
            end

            function drawROI(roi, ~)
                % Project the ROI's two opposite corners and draw a
                % rectangle / ellipse outline. Solid green if its
                % originating view + slice match the current pane;
                % otherwise dashed.
                Pp = [roi.p1; roi.p2];
                [Xp, Yp] = projectToView(Pp, view_mode);
                same_view = strcmp(roi.view_origin, view_mode);
                if same_view
                    style = '-'; lw = 1.8; col = roi.color;
                else
                    style = '--'; lw = 0.9; col = roi.color * 0.6;
                end
                xL = min(Xp); xR = max(Xp);
                yL = min(Yp); yR = max(Yp);
                if strcmp(roi.kind, 'roi_rect')
                    line(ax, ...
                         [xL xR xR xL xL], [yL yL yR yR yL], ...
                         'Color', col, 'LineWidth', lw, ...
                         'LineStyle', style, ...
                         'Tag', 'measurement_graphic', ...
                         'PickableParts', 'none');
                else  % ellipse
                    th = linspace(0, 2*pi, 64);
                    cx_e = (xL+xR)/2; cy_e = (yL+yR)/2;
                    rx_e = max(0.5, (xR-xL)/2);
                    ry_e = max(0.5, (yR-yL)/2);
                    line(ax, ...
                         cx_e + rx_e*cos(th), cy_e + ry_e*sin(th), ...
                         'Color', col, 'LineWidth', lw, ...
                         'LineStyle', style, ...
                         'Tag', 'measurement_graphic', ...
                         'PickableParts', 'none');
                end
                if same_view && isfield(roi, 'stats') && ...
                   ~isnan(roi.stats.mean)
                    label = sprintf( ...
                        'μ=%.0f σ=%.0f  min=%.0f max=%.0f  %.2fcm²', ...
                        roi.stats.mean, roi.stats.sd, ...
                        roi.stats.min, roi.stats.max, ...
                        roi.stats.area_cm2);
                    text(ax, xL, yL, label, ...
                         'Color', col, 'FontSize', 9, ...
                         'VerticalAlignment', 'bottom', ...
                         'BackgroundColor', [0 0 0 0.6], 'Margin', 1, ...
                         'Tag', 'measurement_graphic', ...
                         'PickableParts', 'none');
                end
            end

            function [X, Y] = projectToView(P, vm)
                % P: N x 3 voxel-space [iy, ix, iz]. Mapping mirrors
                % how each view's image is built (see refreshMain
                % and refreshMultiView).
                n = size(P, 1);
                switch vm
                    case 'axial'
                        X = P(:,2);  Y = P(:,1);
                    case 'sagittal'
                        X = P(:,1);  Y = P(:,3);
                    case 'coronal'
                        X = P(:,2);  Y = P(:,3);
                    case '3d'
                        X = P(:,2);  Y = P(:,3);
                    otherwise
                        X = NaN(n,1); Y = NaN(n,1);
                end
            end
        end

        function onMultiPaneClick(app, evt, view_mode)
            % Click handler for the 2-D images in the 2x2 view.
            % Builds a voxel-space point from the click + the
            % current slice index and dispatches to whichever tool
            % is armed. Without an armed tool, the linked
            % crosshair (if enabled) re-centers all panes on the
            % click point.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            pt = evt.IntersectionPoint;
            ix = round(pt(1));
            iy = round(pt(2));
            switch view_mode
                case 'axial';    voxel = [iy, ix, app.IdxAxial];
                case 'coronal';  voxel = [app.IdxCoronal, ix, iy];
                case 'sagittal'; voxel = [ix, app.IdxSagittal, iy];
                otherwise; return;
            end
            sz = size(app.D.vol);
            voxel(1) = max(1, min(sz(1), voxel(1)));
            voxel(2) = max(1, min(sz(2), voxel(2)));
            voxel(3) = max(1, min(sz(3), voxel(3)));
            % --- Right-click → centerline edit context menu --------
            % Same gesture as single-view: if the click is near the
            % centerline polyline, snapshot the voxel + nearest side
            % and pop the existing Insert/Delete/Move menu. The
            % UIContextMenu on the line itself handles the case where
            % the user clicks ON the line; this branch covers
            % right-clicks on the image just off the line (near it).
            btn = 1;
            try; btn = evt.Button; catch; end
            if btn == 3 && ~isempty(app.PolylineRight)
                ensureCenterlineCtxMenu(app);
                dR = min(vecnorm(app.PolylineRight - voxel, 2, 2));
                if isempty(app.PolylineLeft)
                    side = 'right';
                else
                    dL = min(vecnorm(app.PolylineLeft - voxel, 2, 2));
                    if dL < dR; side = 'left'; else; side = 'right'; end
                end
                app.ClCtxClickVoxel = voxel;
                app.ClCtxClickSide  = side;
                fig_pt = app.UIFigure.CurrentPoint;
                open(app.ClContextMenu, fig_pt(1), fig_pt(2));
                return;
            end
            % Dispatch by armed tool
            if app.VesselPickArmed
                fprintf('[2x2 click] view=%s voxel=[%d %d %d] HU=%d → vessel-select\n', ...
                    view_mode, voxel, app.D.vol(voxel(1), voxel(2), voxel(3)));
                onVesselSelectClick(app, voxel);
                return;
            end
            if ~isempty(app.MeasureMode)
                onMeasureClick(app, voxel);
                return;
            end
            if ~isempty(app.DrawMode)
                onDrawClick(app, voxel, view_mode);
                return;
            end
            % No tool armed: linked crosshair (default in 2x2)
            if app.CrosshairLocked
                updateCrosshair(app, voxel);
            end
        end

        function onDrawClick(app, voxel, view_origin)
            % Route a click to whichever drawing tool is armed.
            switch app.DrawMode
                case {'roi_rect', 'roi_ellipse'}
                    onROIClick(app, voxel, view_origin);
                case 'annotate'
                    onAnnotateClick(app, voxel, view_origin);
                case 'wire'
                    onWireClick(app, voxel);
            end
        end

        function onROIClick(app, voxel, view_origin)
            % Two-click ROI: first click anchors a corner, second
            % click commits the opposite corner. The ROI is drawn
            % in the originating pane's image plane and stored in
            % voxel space so it projects to the other panes (as a
            % "ghost" rectangle when out-of-plane).
            kind = app.DrawMode;   % 'roi_rect' | 'roi_ellipse'
            if isempty(app.PendingPoints)
                app.PendingPoints = {voxel};
                refreshMeasurementOverlay(app);
                return;
            end
            % Second click — commit
            p1 = app.PendingPoints{1};
            p2 = voxel;
            roi = struct();
            roi.kind        = kind;
            roi.view_origin = view_origin;
            roi.p1          = p1;   % voxel
            roi.p2          = p2;   % voxel
            % Compute HU stats from the slice the ROI was drawn on
            roi.stats = computeROIStats(app, roi);
            roi.color = [0.20 0.85 0.30];   % ROI green
            app.ROIs{end+1}   = roi;
            app.PendingPoints = {};
            refreshMeasurementOverlay(app);
        end

        function stats = computeROIStats(app, roi)
            % Compute mean ± SD, min, max, area cm² of HU values
            % inside the ROI on the slice it was drawn on. The mask
            % shape (rect / ellipse) determines which pixels are
            % included.
            stats = struct('n', 0, 'mean', NaN, 'sd', NaN, ...
                           'min', NaN, 'max', NaN, 'area_cm2', NaN);
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            vol = app.D.vol;
            sx_mm = app.D.pixel_mm(2);
            sy_mm = app.D.pixel_mm(1);
            sz_mm = app.D.slice_spacing_mm;
            switch roi.view_origin
                case 'axial'
                    img = vol(:, :, roi.p1(3));
                    px_x_mm = sx_mm; px_y_mm = sy_mm;
                    p1_xy = [roi.p1(2) roi.p1(1)];   % (X=ix, Y=iy)
                    p2_xy = [roi.p2(2) roi.p2(1)];
                case 'coronal'
                    img = squeeze(vol(roi.p1(1), :, :)).';   % rows=z, cols=x
                    px_x_mm = sx_mm; px_y_mm = sz_mm;
                    p1_xy = [roi.p1(2) roi.p1(3)];
                    p2_xy = [roi.p2(2) roi.p2(3)];
                case 'sagittal'
                    img = squeeze(vol(:, roi.p1(2), :)).';
                    px_x_mm = sy_mm; px_y_mm = sz_mm;
                    p1_xy = [roi.p1(1) roi.p1(3)];
                    p2_xy = [roi.p2(1) roi.p2(3)];
                otherwise
                    return;
            end
            x_lo = max(1, min(size(img,2), min(p1_xy(1), p2_xy(1))));
            x_hi = max(1, min(size(img,2), max(p1_xy(1), p2_xy(1))));
            y_lo = max(1, min(size(img,1), min(p1_xy(2), p2_xy(2))));
            y_hi = max(1, min(size(img,1), max(p1_xy(2), p2_xy(2))));
            if x_hi <= x_lo || y_hi <= y_lo; return; end
            sub = double(img(y_lo:y_hi, x_lo:x_hi));
            if strcmp(roi.kind, 'roi_ellipse')
                [Xg, Yg] = meshgrid(x_lo:x_hi, y_lo:y_hi);
                cx_e = (x_lo + x_hi) / 2;
                cy_e = (y_lo + y_hi) / 2;
                rx_e = max(1, (x_hi - x_lo) / 2);
                ry_e = max(1, (y_hi - y_lo) / 2);
                inside = ((Xg - cx_e) / rx_e).^2 + ...
                         ((Yg - cy_e) / ry_e).^2 <= 1;
                vals = sub(inside);
                area_pix = sum(inside(:));
            else
                vals = sub(:);
                area_pix = numel(vals);
            end
            stats.n        = numel(vals);
            stats.mean     = mean(vals);
            stats.sd       = std(vals);
            stats.min      = min(vals);
            stats.max      = max(vals);
            stats.area_cm2 = area_pix * px_x_mm * px_y_mm / 100.0;
        end

        function onAnnotateClick(app, voxel, view_origin)
            % Pop a small input dialog to capture text, attach to
            % the voxel point in the originating view.
            txt = inputdlg({'Annotation text:'}, 'New annotation', ...
                [1 50], {''});
            if isempty(txt) || isempty(txt{1}); return; end
            ann = struct();
            ann.voxel       = voxel;
            ann.view_origin = view_origin;
            ann.text        = txt{1};
            ann.color       = [0.30 0.65 1.00];   % cyan
            app.Annotations{end+1} = ann;
            refreshMeasurementOverlay(app);
        end

        function onWireClick(app, voxel)
            % Append a vertex to the in-progress wire path. The
            % wire is committed when the user clicks "Finish" or
            % presses Esc.
            if app.WireFinalized; return; end
            if isempty(app.WirePath)
                app.WirePath = voxel(:).';
            else
                app.WirePath(end+1, :) = voxel(:).';
            end
            refreshMeasurementOverlay(app);
        end

        function updateCrosshair(app, voxel)
            % Re-center the other 2x2 panes on the clicked point
            % and store the crosshair location for cross-pane
            % rendering.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            sz = size(app.D.vol);
            voxel(1) = max(1, min(sz(1), round(voxel(1))));
            voxel(2) = max(1, min(sz(2), round(voxel(2))));
            voxel(3) = max(1, min(sz(3), round(voxel(3))));
            app.IdxAxial    = voxel(3);
            app.IdxCoronal  = voxel(1);
            app.IdxSagittal = voxel(2);
            app.Crosshair   = voxel(:).';
            % Re-render the multi-pane (slices changed)
            refreshMultiView(app);
        end

        function out = panelAspectData(app)
            % Panel aspect (W/H in pixels) mapped into data-unit
            % aspect using the current axes' DataAspectRatio. The
            % "magic" XLim/YLim ratio that makes the plot box fill
            % the panel exactly while respecting anatomic aspect.
            ax = app.MainAxes;
            ax_p = ax.Position;
            pp_aspect = ax_p(3) / max(1, ax_p(4));
            da = ax.DataAspectRatio;
            if strcmp(ax.DataAspectRatioMode, 'manual') && ...
               numel(da) >= 2 && da(1) > 0
                out = pp_aspect * (da(2) / da(1));
            else
                out = pp_aspect;
            end
        end

        function [full_w, full_h, cx, cy] = viewDataExtents(app)
            % Returns the data-unit extents of the active 2-D view.
            sz = size(app.D.vol);
            switch app.ViewMode
                case 'axial'
                    full_w = sz(2); full_h = sz(1);
                case 'coronal'
                    full_w = sz(2); full_h = sz(3);
                case 'sagittal'
                    full_w = sz(1); full_h = sz(3);
                case '3d'
                    full_w = sz(2); full_h = sz(3);
                otherwise
                    full_w = sz(2); full_h = sz(1);
            end
            cx = (full_w + 1) / 2;
            cy = (full_h + 1) / 2;
        end

        function smartZoom2D(app, ax, view_mode, factor)
            % Smart 2-D zoom on a specific axes: shrink visible AREA
            % by factor² and reshape XLim/YLim to the panel aspect
            % (in data units, computed from ax.DataAspectRatio) so
            % the plot box always fills the axes container while
            % anatomic X/Y ratio stays strictly enforced.
            if isempty(ax) || ~isvalid(ax); return; end
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            xl = ax.XLim; yl = ax.YLim;
            cx = mean(xl); cy = mean(yl);
            cur_w = xl(2) - xl(1);
            cur_h = yl(2) - yl(1);
            new_area = cur_w * cur_h * factor^2;
            ax_p = ax.Position;
            pp_aspect = ax_p(3) / max(1, ax_p(4));
            da = ax.DataAspectRatio;
            if strcmp(ax.DataAspectRatioMode, 'manual') && ...
               numel(da) >= 2 && da(1) > 0
                target = pp_aspect * (da(2) / da(1));
            else
                target = pp_aspect;
            end
            if ~isfinite(target) || target <= 0
                target = cur_w / max(cur_h, eps);
            end
            new_h = sqrt(new_area / target);
            new_w = new_area / new_h;
            % Data extents for this view
            sz = size(app.D.vol);
            switch view_mode
                case 'axial';    full_w = sz(2); full_h = sz(1);
                case 'coronal';  full_w = sz(2); full_h = sz(3);
                case 'sagittal'; full_w = sz(1); full_h = sz(3);
                case '3d';       full_w = sz(2); full_h = sz(3);
                case 'cpr'
                    if ~isempty(ax.Children) && isvalid(ax.Children(end))
                        try
                            cd_data = ax.Children(end).CData;
                            full_w = size(cd_data, 2);
                            full_h = size(cd_data, 1);
                        catch
                            full_w = max(round(cur_w), 1);
                            full_h = max(round(cur_h), 1);
                        end
                    else
                        full_w = max(round(cur_w), 1);
                        full_h = max(round(cur_h), 1);
                    end
                otherwise
                    full_w = sz(2); full_h = sz(1);
            end
            dcx = (full_w + 1) / 2; dcy = (full_h + 1) / 2;
            new_w = max(new_w, 4);
            new_h = max(new_h, 4);
            x_lo = cx - new_w/2; x_hi = cx + new_w/2;
            y_lo = cy - new_h/2; y_hi = cy + new_h/2;
            if new_w < full_w
                if x_lo < 0.5
                    x_hi = x_hi + (0.5 - x_lo); x_lo = 0.5;
                elseif x_hi > full_w + 0.5
                    x_lo = x_lo - (x_hi - full_w - 0.5);
                    x_hi = full_w + 0.5;
                end
            else
                x_lo = dcx - new_w/2; x_hi = dcx + new_w/2;
            end
            if new_h < full_h
                if y_lo < 0.5
                    y_hi = y_hi + (0.5 - y_lo); y_lo = 0.5;
                elseif y_hi > full_h + 0.5
                    y_lo = y_lo - (y_hi - full_h - 0.5);
                    y_hi = full_h + 0.5;
                end
            else
                y_lo = dcy - new_h/2; y_hi = dcy + new_h/2;
            end
            ax.XLim = [x_lo, x_hi];
            ax.YLim = [y_lo, y_hi];
        end

        function pane_idx = whichMultiPane(app)
            % Return 1-4 if cursor is over a 2x2 pane, else 0.
            pane_idx = 0;
            if ~strcmp(app.ViewMode, '2x2'); return; end
            if isempty(app.MultiPanels); return; end
            pt = app.UIFigure.CurrentPoint;
            ip = app.ImagePanel.Position;
            for k = 1:numel(app.MultiPanels)
                p = app.MultiPanels{k};
                if isempty(p) || ~isvalid(p); continue; end
                pp = p.Position;
                x_lo = ip(1) + pp(1); x_hi = x_lo + pp(3);
                y_lo = ip(2) + pp(2); y_hi = y_lo + pp(4);
                if pt(1) >= x_lo && pt(1) <= x_hi && ...
                   pt(2) >= y_lo && pt(2) <= y_hi
                    pane_idx = k;
                    return;
                end
            end
        end

        function zoomBy(app, factor)
            % factor < 1 = zoom in, factor > 1 = zoom out (matches the
            % +/- button wiring at the toolbar).
            % 2x2 multi-pane: zoom every pane uniformly. Panes 1-3
            % use smart 2-D zoom; pane 4 drives the volshow camera
            % zoom (no XLim/YLim there).
            if strcmp(app.ViewMode, '2x2')
                pane_modes = {'axial','sagittal','coronal','3d'};
                for k = 1:3
                    if ~isempty(app.MultiAxes{k}) && isvalid(app.MultiAxes{k})
                        smartZoom2D(app, app.MultiAxes{k}, pane_modes{k}, factor);
                    end
                end
                if ~isempty(app.Multi3DViewer) && isvalid(app.Multi3DViewer)
                    try
                        v3d = app.Multi3DViewer.Parent;
                        cz = v3d.CameraZoom; if isempty(cz) || ~isfinite(cz) || cz <= 0; cz = 1; end
                        v3d.CameraZoom = max(0.2, min(50, cz / factor));
                    catch
                    end
                end
                return;
            end
            if strcmp(app.ViewMode, '3dvol')
                % 3-D Volume mode renders inside a viewer3d that has its
                % own camera — MainAxes.XLim is decorative here. Drive
                % the viewer3d's CameraZoom directly so the +/- buttons
                % actually move the picture.
                if isempty(app.VolViewer) || ~isvalid(app.VolViewer); return; end
                try
                    parent = app.VolViewer.Parent;
                    if isa(parent, 'images.ui.graphics3d.Viewer3D')
                        cz = parent.CameraZoom;
                        if isempty(cz) || ~isfinite(cz) || cz <= 0
                            cz = 1;
                        end
                        % Zoom in (factor < 1) => larger CameraZoom.
                        % Clamp to a sensible range so trackpad pinch
                        % gestures can't drive the camera past the
                        % volume or absurdly close.
                        new_cz = cz / factor;
                        new_cz = max(0.2, min(50, new_cz));
                        parent.CameraZoom = new_cz;
                    end
                catch ME
                    fprintf('[zoomBy/3dvol] %s\n', ME.message);
                end
                updateVolHud(app);
                return;
            end
            if isempty(app.MainAxes) || ~isvalid(app.MainAxes); return; end
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            smartZoom2D(app, app.MainAxes, app.ViewMode, factor);
        end

        function fitView(app)
            % If we have a centerline, fit to its bounding box plus a
            % small margin. Otherwise, fit the full volume frame.
            if isempty(app.MainAxes) || ~isvalid(app.MainAxes); return; end
            sz = size(app.D.vol);
            xl_full = [0.5, sz(2)+0.5];
            yl_full = [0.5, sz(1)+0.5];
            P = app.PolylineRight;
            if isempty(P)
                app.MainAxes.XLim = xl_full;
                app.MainAxes.YLim = yl_full;
                return;
            end
            switch app.ViewMode
                case 'axial'
                    pad = 0.06 * max(sz(1:2));
                    app.MainAxes.XLim = [min(P(:,2))-pad, max(P(:,2))+pad];
                    app.MainAxes.YLim = [min(P(:,1))-pad, max(P(:,1))+pad];
                case 'coronal'
                    % Keep the full body width in X so the anatomy isn't
                    % horizontally squashed by the stretch-to-fill
                    % aspect; only crop Z (vertical) to the centerline.
                    pad_z = 0.05 * sz(3);
                    app.MainAxes.XLim = xl_full;
                    app.MainAxes.YLim = [min(P(:,3))-pad_z, max(P(:,3))+pad_z];
                case 'sagittal'
                    pad_z = 0.05 * sz(3);
                    app.MainAxes.XLim = [0.5, sz(1)+0.5];
                    app.MainAxes.YLim = [min(P(:,3))-pad_z, max(P(:,3))+pad_z];
                case '3d'
                    pad_z = 0.05 * sz(3);
                    app.MainAxes.XLim = xl_full;
                    app.MainAxes.YLim = [min(P(:,3))-pad_z, max(P(:,3))+pad_z];
                case '3dvol'
                    % volshow's viewer3d has its own camera; ask it
                    % to recenter on the data extent.
                    if ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                        try
                            % R2023a+: viewer3d has zoomToFit.
                            parent = app.VolViewer.Parent;
                            if isa(parent, 'images.ui.graphics3d.Viewer3D')
                                parent.zoomToFit();
                            end
                        catch
                        end
                    end
                case '2x2'
                    % Zoom each of the three 2-D panes to the
                    % centerline bounding box. The 4th pane (3-D
                    % MIP) has its own camera and is left alone.
                    if isempty(app.MultiAxes) || numel(app.MultiAxes) < 3
                        return;
                    end
                    Pa = [app.PolylineRight; app.PolylineLeft];
                    if isempty(Pa); return; end
                    % Slightly generous margin so the user sees a
                    % comfortable border around the vessels.
                    pad_xy = 0.10 * max(sz(1:2));
                    pad_z  = 0.06 * sz(3);
                    % Axial (k=1): X=col (P:,2), Y=row (P:,1)
                    setPaneLim(app.MultiAxes{1}, ...
                        [min(Pa(:,2))-pad_xy, max(Pa(:,2))+pad_xy], ...
                        [min(Pa(:,1))-pad_xy, max(Pa(:,1))+pad_xy]);
                    % Sagittal (k=2): X=row (P:,1), Y=z (P:,3)
                    setPaneLim(app.MultiAxes{2}, ...
                        [min(Pa(:,1))-pad_xy, max(Pa(:,1))+pad_xy], ...
                        [min(Pa(:,3))-pad_z,  max(Pa(:,3))+pad_z]);
                    % Coronal (k=3): X=col (P:,2), Y=z (P:,3)
                    setPaneLim(app.MultiAxes{3}, ...
                        [min(Pa(:,2))-pad_xy, max(Pa(:,2))+pad_xy], ...
                        [min(Pa(:,3))-pad_z,  max(Pa(:,3))+pad_z]);
            end
            function setPaneLim(ax, xl, yl)
                if isempty(ax) || ~isvalid(ax); return; end
                if all(isfinite(xl)) && xl(2) > xl(1)
                    ax.XLim = xl;
                end
                if all(isfinite(yl)) && yl(2) > yl(1)
                    ax.YLim = yl;
                end
            end
        end

        function centerSlicesOnCenterline(app)
            % Move IdxAxial/IdxSagittal/IdxCoronal to a slice that
            % actually intersects the centerline so the user lands
            % on anatomy, not on an empty slab above/below it. Uses
            % the right (primary) polyline centroid; the centerlines
            % share approximately the same bbox so this is a fair
            % proxy for both sides. No-op when no centerline yet.
            if isempty(app.PolylineRight) || isempty(app.D) || ~isfield(app.D,'vol')
                return;
            end
            P  = app.PolylineRight;
            sz = size(app.D.vol);
            % Use the midpoint of the polyline z-range — that's near
            % the bifurcation for a typical infrarenal anatomy and
            % keeps both iliacs in view on the MPR. For x/y we use
            % the mean column/row so the slice cut passes through the
            % aortic lumen.
            app.IdxAxial    = clampIdx(round(median(P(:,3))), sz(3));
            app.IdxCoronal  = clampIdx(round(median(P(:,1))), sz(1));
            app.IdxSagittal = clampIdx(round(median(P(:,2))), sz(2));
            function v = clampIdx(v, hi)
                v = max(1, min(hi, v));
            end
        end

        function createImagePanel(app)
            % Big image fills the left area between the view toolbar and the bottom
            x0 = 10;   y0 = 80;
            % Side panel takes the right ~410 px
            side_w = 410;
            w = app.UIFigure.Position(3) - x0 - side_w - 20;
            % Reserve space above the image for: step bar (32) + view
            % toolbar (32) + tool toolbar 1 (32) + tool toolbar 2 (32)
            % + gaps + 12 px top safety margin. Total reservation: 174.
            h = app.UIFigure.Position(4) - y0 - 102 - 72;
            % Dark viewport — the clinical-workstation convention (PACS /
            % TeraRecon). The CT sits on black anyway, so a dark canvas
            % focuses the eye on the image and makes the letterbox margins
            % + overlaid controls read as intentional rather than stranded
            % on white. Overlays live on the image, so their contrast is
            % unchanged; only labels that sit on this panel are lightened.
            VIEWPORT_BG = [0.12 0.12 0.14];
            app.ImagePanel = uipanel(app.UIFigure, ...
                'Position', [x0 y0 w h], ...
                'BackgroundColor', VIEWPORT_BG, 'BorderType', 'none');
            % Slider at the bottom of the image panel
            % Slice slider — hidden until a volume is loaded. The
            % placeholder `Limits [1 2]` and tick marks (1, 1.05, …, 2)
            % were confusing on the empty-canvas screen.
            app.SliceSlider = uislider(app.ImagePanel, ...
                'Position', [50 30 w-100 3], ...
                'Limits', [1 2], 'Value', 1, ...
                'Visible', 'off', ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(s,evt) sliderMoved(app, evt));
            app.SliceLabel = uilabel(app.ImagePanel, ...
                'Position', [50 50 w-100 22], ...
                'Text', 'Load a CT to begin — choose a source in the Step 1 panel on the right →', ...
                'HorizontalAlignment', 'center', 'FontSize', 12, ...
                'FontColor', [0.80 0.80 0.85]);   % light — sits on the dark viewport
            % Axes — leave room above for the slider
            app.MainAxes = uiaxes(app.ImagePanel, ...
                'Position', [10 80 w-20 h-110], ...
                'Color', VIEWPORT_BG);
            app.MainAxes.XColor = [0.7 0.7 0.7];
            app.MainAxes.YColor = [0.7 0.7 0.7];
            app.MainAxes.XTick  = [];
            app.MainAxes.YTick  = [];
            colormap(app.MainAxes, gray);
            % Scroll-wheel zoom
            app.UIFigure.WindowScrollWheelFcn = @(~,evt) onScroll(app, evt);
        end

        function onScroll(app, evt)
            % 2x2 multi-pane:
            %   plain scroll over a 2-D pane    = slice scroll for that pane's view
            %   Cmd/Ctrl + scroll on a 2-D pane = zoom that pane
            %   plain scroll on the 3-D pane    = camera zoom (no slice concept)
            % This matches every clinical DICOM viewer's convention.
            if strcmp(app.ViewMode, '2x2')
                pane_idx = whichMultiPane(app);
                if pane_idx == 0; return; end
                mods = app.UIFigure.CurrentModifier;
                is_zoom_mod = ~isempty(mods) && ...
                    (any(strcmp(mods,'command')) || any(strcmp(mods,'control')));
                if pane_idx == 4
                    % 3-D recon — always zoom (no slice index)
                    f = 1 + 0.15 * evt.VerticalScrollCount;
                    f = max(0.5, min(1.8, f));
                    if ~isempty(app.Multi3DViewer) && isvalid(app.Multi3DViewer)
                        try
                            v3d = app.Multi3DViewer.Parent;
                            cz = v3d.CameraZoom; if isempty(cz) || ~isfinite(cz) || cz <= 0; cz = 1; end
                            v3d.CameraZoom = max(0.2, min(50, cz / f));
                        catch
                        end
                    end
                    return;
                end
                if is_zoom_mod
                    f = 1 + 0.15 * evt.VerticalScrollCount;
                    f = max(0.5, min(1.8, f));
                    pane_modes = {'axial','sagittal','coronal'};
                    smartZoom2D(app, app.MultiAxes{pane_idx}, ...
                        pane_modes{pane_idx}, f);
                    return;
                end
                % Plain scroll on a 2-D pane = slice scroll for
                % that pane's view direction. Re-render the multi
                % view so the slab MIP / linked crosshair update too.
                if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
                d = sign(evt.VerticalScrollCount);
                if d == 0; d = evt.VerticalScrollCount; end
                sz = size(app.D.vol);
                switch pane_idx
                    case 1   % axial
                        app.IdxAxial    = max(1, min(sz(3), app.IdxAxial    + d));
                    case 2   % sagittal
                        app.IdxSagittal = max(1, min(sz(2), app.IdxSagittal + d));
                    case 3   % coronal
                        app.IdxCoronal  = max(1, min(sz(1), app.IdxCoronal  + d));
                end
                refreshMultiView(app);
                return;
            end
            % 3-D Volume: scroll always zooms (matches volshow norms).
            % 2-D MPR: scroll = slice scroll (matches every clinical
            % DICOM viewer). Cmd / Ctrl + scroll = zoom in 2-D.
            % MIP / CPR: no slice index, so scroll = zoom.
            if strcmp(app.ViewMode, '3dvol') || ...
               strcmp(app.ViewMode, '3d')   || ...
               strcmp(app.ViewMode, 'cpr')
                f = 1 + 0.15 * evt.VerticalScrollCount;
                f = max(0.5, min(1.8, f));
                zoomBy(app, f);
                return;
            end
            % 2-D MPR. Cmd / Ctrl modifier => zoom.
            mods = app.UIFigure.CurrentModifier;
            is_zoom_mod = ~isempty(mods) && ...
                (any(strcmp(mods,'command')) || any(strcmp(mods,'control')));
            if is_zoom_mod
                f = 1 + 0.15 * evt.VerticalScrollCount;
                f = max(0.5, min(1.8, f));
                zoomBy(app, f);
                return;
            end
            % Slice scroll. positive count = down = next slice.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            d = sign(evt.VerticalScrollCount);
            if d == 0; d = evt.VerticalScrollCount; end
            sz = size(app.D.vol);
            switch app.ViewMode
                case 'axial';    app.IdxAxial    = max(1, min(sz(3), app.IdxAxial    + d));
                case 'coronal';  app.IdxCoronal  = max(1, min(sz(1), app.IdxCoronal  + d));
                case 'sagittal'; app.IdxSagittal = max(1, min(sz(2), app.IdxSagittal + d));
            end
            refreshMain(app);
            updateSliderForView(app);
        end

        function panBy(app, dx_pix, dy_pix)
            % Pan the viewer3d camera by (dx_pix, dy_pix) figure-space
            % pixels. Move CameraTarget AND CameraPosition by the same
            % world vector so view direction is preserved. The world
            % delta is computed from the camera's right + up basis.
            % Sign: a rightward mouse drag should drag the anatomy
            % rightward, so CameraTarget moves LEFTWARD relative to
            % the data — i.e. delta = -dx*right + dy*up (figure y goes
            % up).
            if ~strcmp(app.ViewMode, '3dvol'); return; end
            if isempty(app.VolViewer) || ~isvalid(app.VolViewer); return; end
            try
                v3d = app.VolViewer.Parent;
                cp  = v3d.CameraPosition;
                ct  = v3d.CameraTarget;
                cu  = v3d.CameraUpVector;
                view_dir = ct - cp;
                if norm(view_dir) == 0; return; end
                view_dir = view_dir / norm(view_dir);
                right = cross(view_dir, cu);
                if norm(right) == 0; return; end
                right = right / norm(right);
                up    = cross(right, view_dir);
                up    = up / norm(up);
                % Pixel-to-world scale: choose so that dragging across
                % the whole volshow panel pans by ~one volume span.
                % (Approximate — viewer3d perspective makes this not
                % exact, but it feels right.)
                sz   = size(app.VolViewer.Data);
                pp   = app.VolPanel.Position;
                panel_extent = max(pp(3:4));
                world_per_pix = max(sz) / max(1, panel_extent);
                delta = right * (-dx_pix * world_per_pix) + ...
                        up    * ( dy_pix * world_per_pix);
                v3d.CameraPosition = cp + delta;
                v3d.CameraTarget   = ct + delta;
                updateVolHud(app);
            catch ME
                fprintf('[panBy] %s\n', ME.message);
            end
        end

        % --- Pan / rotate mode toggle (P key) -----------------------
        % viewer3d.Interactions is single-mode: 'all' (default = drag
        % rotates) or 'pan' (drag pans). Right-click can't be hijacked
        % because viewer3d eats it for its own "Display info / Scale
        % bar" popup. So we expose a toggle: press P to switch drag
        % from rotate -> pan, P again to switch back.
        function togglePanMode(app)
            % Toggle the Pan-on-drag mode. In 3-D Volume single view,
            % flip viewer3d.Interactions between 'rotate' and 'pan'.
            % In 2x2 mode, flip the same on the pane-4 viewer3d. The
            % 2-D panes (or 2-D single views) are not affected — they
            % use scroll-wheel zoom and click-pan via the W/L toggle's
            % sibling Pan handler.
            new_pan_on = ~app.PanArmed;
            app.PanArmed = new_pan_on;
            % Disarm W/L if pan is now on (mutually exclusive)
            if new_pan_on && app.WLArmed
                app.WLArmed = false;
                if ~isempty(app.WLToggleBtn) && isvalid(app.WLToggleBtn)
                    app.WLToggleBtn.Value = false;
                    app.WLToggleBtn.Text  = 'Drag: W / L';
                    app.WLToggleBtn.BackgroundColor = [0.92 0.92 0.96];
                end
            end
            % Drive the appropriate viewer3d
            if strcmp(app.ViewMode, '3dvol') && ...
               ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                try
                    v3d = app.VolViewer.Parent;
                    if new_pan_on; v3d.Interactions = 'pan';
                    else;          v3d.Interactions = 'rotate'; end
                catch ME
                    fprintf('[togglePanMode] %s\n', ME.message);
                end
            elseif strcmp(app.ViewMode, '2x2') && ...
                   ~isempty(app.Multi3DViewer) && isvalid(app.Multi3DViewer)
                try
                    v3d = app.Multi3DViewer.Parent;
                    if new_pan_on; v3d.Interactions = 'pan';
                    else;          v3d.Interactions = 'rotate'; end
                catch ME
                    fprintf('[togglePanMode/2x2] %s\n', ME.message);
                end
            end
            % Update both toggle button visuals (single-view + pane-4)
            if new_pan_on
                t = 'Drag: PAN'; c = [0.95 0.85 0.55];
            else
                t = 'Drag: ROTATE'; c = [0.92 0.92 0.96];
            end
            for h = {app.PanToggleBtn, app.MultiPanToggleBtn}
                btn = h{1};
                if ~isempty(btn) && isvalid(btn)
                    btn.Value = new_pan_on;
                    btn.Text = t;
                    btn.BackgroundColor = c;
                end
            end
            updateVolHud(app);
        end

        function createKeyHintBar(app)
            % Single-line shortcut listing across the very bottom of
            % the figure. Spans the full width (under both the image
            % panel and the side panel) so it's discoverable from any
            % step. Plain text — no markup.
            txt = ['Shortcuts:   ' ...
                   '1-6: view modes;   ' ...
                   'F: fit;   ' ...
                   'R: reset view;   ' ...
                   'S: save snapshot;   ' ...
                   'P: toggle pan;   ' ...
                   'W: toggle W/L drag;   ' ...
                   '+ / −: zoom;   ' ...
                   'scroll: slice scroll (2-D), zoom (3-D);   ' ...
                   'Cmd+scroll: zoom in 2-D;   ' ...
                   'no tool armed: drag rotates (3-D)'];
            uilabel(app.UIFigure, ...
                'Position', [10 2 (app.UIFigure.Position(3) - 20) 18], ...
                'Text', txt, 'FontSize', 10, ...
                'FontColor', [0.35 0.35 0.40], ...
                'HorizontalAlignment', 'left');
        end

        function createSidePanel(app)
            x0 = app.UIFigure.Position(3) - 410;
            y0 = 26;
            app.SidePanel = uipanel(app.UIFigure, ...
                'Position', [x0 y0 400 (app.UIFigure.Position(4) - 76)], ...
                'BackgroundColor', [0.97 0.97 0.99], ...
                'Title', 'Step controls', 'FontSize', 12);
            % Big step header
            app.SideStepLabel = uilabel(app.SidePanel, ...
                'Position', [12 (app.SidePanel.Position(4)-65) 376 28], ...
                'Text', '', 'FontSize', 16, 'FontWeight', 'bold');
            % Content area — generous, with auto-scroll if needed
            app.SideContent = uipanel(app.SidePanel, ...
                'Position', [10 10 380 (app.SidePanel.Position(4)-80)], ...
                'BackgroundColor', 'w', 'BorderType', 'none', ...
                'Scrollable', 'on');
        end

        % --- Step machine -------------------------------------------
        function updateStep(app, k)
            app.Step = k;
            for i = 1:6
                if i < k
                    app.StepLabels{i}.BackgroundColor = [0.85 0.95 0.85];
                    app.StepLabels{i}.FontColor       = [0.0 0.4 0.0];
                    app.StepLabels{i}.FontWeight      = 'normal';
                elseif i == k
                    app.StepLabels{i}.BackgroundColor = [0.20 0.40 0.75];
                    app.StepLabels{i}.FontColor       = [1 1 1];
                    app.StepLabels{i}.FontWeight      = 'bold';
                else
                    app.StepLabels{i}.BackgroundColor = [0.90 0.90 0.93];
                    app.StepLabels{i}.FontColor       = [0.5 0.5 0.5];
                    app.StepLabels{i}.FontWeight      = 'normal';
                end
            end
            switch k
                case 1; buildStep1(app);
                case 2; buildStep2(app);
                case 3; buildStep3(app);
                case 4; buildStep4(app);
                case 5; buildStep5_analyze(app);
                case 6; buildStep6_export(app);
            end
            % Step 2 (Segment) — TotalSegmentator-first workflow.
            % Auto-seg gives clean aorta + iliacs + renals + branches
            % in 1-2 min. The 3-D recon (viewer3d) is for visualization
            % only at this step; clicks for manual refinement go to
            % the 2-D MPR panes (which have reliable axes events).
            if k == 2 && ~isempty(app.D) && isfield(app.D, 'vol') && ...
               ~strcmp(app.ViewMode, '3dvol')
                setViewMode(app, '3dvol');
            end
        end

        function clearSideContent(app)
            delete(allchild(app.SideContent));
        end

        % --- View mode switching ------------------------------------
        function applyViewButtonColors(app)
            % Colour the view-selector so the ACTIVE view reads as a clear
            % blue and the rest are neutral (matching the tool rows). The
            % state-button pressed look alone was too subtle when every
            % button shared one pale tint.
            ACTIVE = [0.62 0.78 0.98];
            IDLE   = [0.95 0.96 0.98];
            m = app.ViewMode; if isempty(m); m = 'axial'; end
            pairs = { app.BtnAxial, 'axial'; app.BtnCoronal, 'coronal'; ...
                      app.BtnSagittal, 'sagittal'; app.Btn3D, '3d'; ...
                      app.Btn3DVol, '3dvol'; app.BtnCPR, 'cpr'; app.Btn2x2, '2x2' };
            for i = 1:size(pairs, 1)
                b = pairs{i, 1};
                if ~isempty(b) && isvalid(b)
                    if strcmp(m, pairs{i, 2})
                        b.BackgroundColor = ACTIVE;
                    else
                        b.BackgroundColor = IDLE;
                    end
                end
            end
        end

        function refreshToolButtonColors(app)
            % Highlight the armed input tool in the same blue as the active
            % view, so "what is armed" is always obvious. Mirrors
            % applyViewButtonColors; safe to call any time (guards each
            % handle). Only the mutually-exclusive measure/draw tools are
            % coloured here — the option toggles (Crosshair / Invert / Play)
            % and the viewport Pan/WL keep their own semantics.
            ACTIVE = [0.62 0.78 0.98];
            IDLE   = [0.95 0.96 0.98];
            btns = {app.BtnMeasure, app.BtnAngle, app.BtnROIRect, ...
                    app.BtnROIEllipse, app.BtnAnnotate, app.BtnWirePath};
            for i = 1:numel(btns)
                b = btns{i};
                if ~isempty(b) && isvalid(b) && isprop(b, 'Value')
                    if b.Value
                        b.BackgroundColor = ACTIVE;
                    else
                        b.BackgroundColor = IDLE;
                    end
                end
            end
        end

        function setViewMode(app, mode)
            % Flag a fit on the next refresh whenever the view
            % changes, so a zoomed-in coronal doesn't carry its
            % limits into sagittal / axial.
            if ~strcmp(app.ViewMode, mode)
                app.NeedFitOnRefresh = true;
                % Disarm Pick-vessel mode if it was on; otherwise the
                % old viewer3d would be left with Interactions='none'
                % and rotation would be broken when the user came
                % back. Safe no-op when not armed.
                if app.VesselPickArmed
                    toggleVesselPickArmed(app, false);
                end
            end
            app.ViewMode = mode;
            % Sync toggle button states (only the chosen one is on)
            app.BtnAxial.Value    = strcmp(mode, 'axial');
            app.BtnCoronal.Value  = strcmp(mode, 'coronal');
            app.BtnSagittal.Value = strcmp(mode, 'sagittal');
            app.Btn3D.Value       = strcmp(mode, '3d');
            if ~isempty(app.Btn3DVol) && isvalid(app.Btn3DVol)
                app.Btn3DVol.Value = strcmp(mode, '3dvol');
            end
            if ~isempty(app.BtnCPR) && isvalid(app.BtnCPR)
                app.BtnCPR.Value = strcmp(mode, 'cpr');
            end
            applyViewButtonColors(app);   % highlight the active view
            % Show/hide 2D axes vs 3D volume panel
            % Multi-pane: hide everything else, show the four mini
            % panes. The 2x2 button stays on; the 6 single-view
            % toggles go off.
            if strcmp(mode, '2x2')
                % Single-view chrome must be FULLY hidden here. Just
                % setting Visible='off' on MainAxes leaves the
                % MainImage child rendering into the figure buffer,
                % which leaks through the mid-pane gaps. Delete the
                % MainImage and clear the axes contents to be safe;
                % refreshMain will recreate them on the way back.
                if ~isempty(app.MainAxes) && isvalid(app.MainAxes)
                    app.MainAxes.Visible = 'off';
                    if ~isempty(app.MainImage) && isvalid(app.MainImage)
                        delete(app.MainImage);
                        % Don't assign [] — typed property rejects it on
                        % some MATLAB releases. The deleted handle is
                        % invalid, and subsequent isvalid() checks see
                        % that.
                        app.MainImage = matlab.graphics.primitive.Image.empty;
                    end
                    cla(app.MainAxes);
                end
                if ~isempty(app.VolPanel) && isvalid(app.VolPanel)
                    app.VolPanel.Visible = 'off';
                end
                if ~isempty(app.SliceSlider) && isvalid(app.SliceSlider)
                    app.SliceSlider.Visible = 'off';
                end
                if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                    app.SliceLabel.Visible = 'off';
                end
                if ~isempty(app.CursorHULabel) && isvalid(app.CursorHULabel)
                    app.CursorHULabel.Visible = 'off';
                end
                setMultiVisible(app, true);
                refreshMultiView(app);
                if ~isempty(app.Btn2x2) && isvalid(app.Btn2x2)
                    app.Btn2x2.Value = true;
                end
                updateOverlayVisibility(app);
                raiseOverlayTools(app);
                return;
            end
            % Any single-view mode hides the multi-pane and turns
            % the 2x2 toggle off. Restore the slice slider, label,
            % and cursor-HU readout that were hidden in 2x2.
            setMultiVisible(app, false);
            if ~isempty(app.Btn2x2) && isvalid(app.Btn2x2)
                app.Btn2x2.Value = false;
            end
            if ~isempty(app.SliceSlider) && isvalid(app.SliceSlider)
                app.SliceSlider.Visible = 'on';
            end
            if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                app.SliceLabel.Visible = 'on';
            end
            if ~isempty(app.CursorHULabel) && isvalid(app.CursorHULabel)
                % Only reveal the HU readout if it currently has content —
                % otherwise its dark background shows as an empty black bar.
                % updateCursorHU reveals it as the cursor enters the image.
                if isempty(char(app.CursorHULabel.Text))
                    app.CursorHULabel.Visible = 'off';
                else
                    app.CursorHULabel.Visible = 'on';
                end
            end
            if strcmp(mode, '3dvol')
                if ~isempty(app.MainAxes) && isvalid(app.MainAxes)
                    app.MainAxes.Visible = 'off';
                end
                ensureVolPanel(app);
                app.VolPanel.Visible = 'on';
                refreshVolViewer(app);
                updateOverlayVisibility(app);
                raiseOverlayTools(app);
            else
                if ~isempty(app.VolPanel) && isvalid(app.VolPanel)
                    app.VolPanel.Visible = 'off';
                end
                if ~isempty(app.MainAxes) && isvalid(app.MainAxes)
                    app.MainAxes.Visible = 'on';
                end
                updateOverlayVisibility(app);
                raiseOverlayTools(app);
                updateSliderForView(app);
                refreshMain(app);
                % If a centerline already exists, auto-fit to its ROI
                % so the user lands on the relevant anatomy, not on
                % the empty corners of the volume frame.
                if ~isempty(app.PolylineRight)
                    fitView(app);
                end
            end
            % Cross-section pane is only meaningful in CPR mode
            if strcmp(mode, 'cpr') && ~isempty(app.PolylineRight)
                ensureXSecPanel(app);
                app.XSecPanel.Visible = 'on';
                refreshXSec(app);
            else
                if ~isempty(app.XSecPanel) && isvalid(app.XSecPanel)
                    app.XSecPanel.Visible = 'off';
                end
            end
        end

        function ensureMultiPanels(app)
            % Lazy-create the 4 mini-panes used by the 2x2 view. Each
            % is a uipanel + uiaxes pair, parented to ImagePanel so
            % they sit under the persistent overlay tools.
            if ~isempty(app.MultiPanels) && all(cellfun(...
                @(h) ~isempty(h) && isvalid(h), app.MultiPanels))
                return;
            end
            ip_w = app.ImagePanel.Position(3);
            ip_h = app.ImagePanel.Position(4);
            % Leave room above the slider/label area for the panes.
            base_y = 100;
            top_pad = 10;
            mid_gap = 8;
            pane_w = floor((ip_w - 2*10 - mid_gap) / 2);
            pane_h = floor((ip_h - base_y - top_pad - mid_gap) / 2);
            % Quadrant positions (TL, TR, BL, BR)
            xL = 10;                xR = 10 + pane_w + mid_gap;
            yT = base_y + pane_h + mid_gap;  yB = base_y;
            poses  = {[xL yT pane_w pane_h], [xR yT pane_w pane_h], ...
                      [xL yB pane_w pane_h], [xR yB pane_w pane_h]};
            titles = {'Axial', 'Sagittal', 'Coronal', '3-D recon'};
            app.MultiPanels = cell(1, 4);
            app.MultiAxes   = cell(1, 4);
            for k = 1:4
                p = uipanel(app.ImagePanel, ...
                    'Position', poses{k}, ...
                    'BackgroundColor', 'k', ...
                    'BorderType', 'line', ...
                    'BorderColor', [0.3 0.3 0.4], ...
                    'Title', titles{k}, ...
                    'ForegroundColor', [0.85 0.85 0.95], ...
                    'FontSize', 11, ...
                    'Visible', 'off');
                if k == 4
                    % Pane 4 hosts a volshow viewer3d (created lazily
                    % in refreshMulti3DPane). Leave the panel empty
                    % for now.
                    app.MultiPanels{k} = p;
                    app.MultiAxes{k}   = [];
                else
                    ax = uiaxes(p, ...
                        'Position', [4 4 pane_w-12 pane_h-30], ...
                        'BackgroundColor', 'k', ...
                        'XColor', 'none', 'YColor', 'none');
                    colormap(ax, gray);
                    app.MultiPanels{k} = p;
                    app.MultiAxes{k}   = ax;
                end
            end
            % Small Drag-mode toggle inside pane 4. Sits at top-left
            % of the 3-D recon pane and drives the same togglePanMode
            % the single-view 3-D Volume tab uses (just on the pane-4
            % viewer3d). Sized small so it doesn't eat the panel.
            p4 = app.MultiPanels{4};
            if ~isempty(p4) && isvalid(p4)
                p4_pos = p4.Position;
                btn_w_p4 = 110; btn_h_p4 = 22;
                app.MultiPanToggleBtn = uibutton(app.ImagePanel, 'state', ...
                    'Position', [p4_pos(1)+6, p4_pos(2)+p4_pos(4)-btn_h_p4-22, ...
                                 btn_w_p4, btn_h_p4], ...
                    'Text', 'Drag: ROTATE', 'Value', false, ...
                    'FontSize', 10, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0.92 0.92 0.96], ...
                    'Tooltip', 'Toggle drag rotate / pan in the 3-D pane.', ...
                    'Visible', 'off', ...
                    'ValueChangedFcn', @(b,~) togglePanMode(app));
                if ~isempty(app.OverlayTools)
                    app.OverlayTools{end+1} = app.MultiPanToggleBtn;
                end
            end
            % Per-pane zoom +/- buttons in each pane's bottom-left.
            % Parented to ImagePanel (NOT the pane) so viewer3d's GPU
            % render in pane 4 can't bury them.
            app.MultiZoomInBtns  = cell(1, 4);
            app.MultiZoomOutBtns = cell(1, 4);
            zb_w = 28; zb_h = 22;
            for k = 1:4
                p_pos = app.MultiPanels{k}.Position;
                bx = p_pos(1) + 4;
                by = p_pos(2) + 4;
                in_btn = uibutton(app.ImagePanel, 'push', ...
                    'Position', [bx, by, zb_w, zb_h], ...
                    'Text', '+', 'FontSize', 13, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0.92 0.92 0.96], ...
                    'Tooltip', sprintf('Zoom in (pane %d only)', k), ...
                    'Visible', 'off', ...
                    'ButtonPushedFcn', @(~,~) zoomMultiPane(app, k, 0.7));
                out_btn = uibutton(app.ImagePanel, 'push', ...
                    'Position', [bx + zb_w + 2, by, zb_w, zb_h], ...
                    'Text', '−', 'FontSize', 13, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0.92 0.92 0.96], ...
                    'Tooltip', sprintf('Zoom out (pane %d only)', k), ...
                    'Visible', 'off', ...
                    'ButtonPushedFcn', @(~,~) zoomMultiPane(app, k, 1/0.7));
                app.MultiZoomInBtns{k}  = in_btn;
                app.MultiZoomOutBtns{k} = out_btn;
                if ~isempty(app.OverlayTools)
                    app.OverlayTools{end+1} = in_btn;
                    app.OverlayTools{end+1} = out_btn;
                end
            end
        end

        function zoomMultiPane(app, pane_idx, factor)
            % Zoom one specific pane in the 2x2 grid. Panes 1-3 use
            % smart 2-D zoom; pane 4 drives volshow CameraZoom.
            if pane_idx >= 1 && pane_idx <= 3
                ax = app.MultiAxes{pane_idx};
                if isempty(ax) || ~isvalid(ax); return; end
                modes = {'axial','sagittal','coronal'};
                smartZoom2D(app, ax, modes{pane_idx}, factor);
            elseif pane_idx == 4
                if isempty(app.Multi3DViewer) || ~isvalid(app.Multi3DViewer)
                    return;
                end
                try
                    v3d = app.Multi3DViewer.Parent;
                    cz = v3d.CameraZoom;
                    if isempty(cz) || ~isfinite(cz) || cz <= 0; cz = 1; end
                    v3d.CameraZoom = max(0.2, min(50, cz / factor));
                catch
                end
            end
        end

        function refreshMulti3DPane(app)
            % Set up (or refresh) the volshow viewer3d in pane 4 of
            % the 2x2 grid. Reuses the same masking + transfer-function
            % logic as refreshVolViewer but at lower data resolution
            % since it only fills a quarter of the screen.
            if isempty(app.MultiPanels) || numel(app.MultiPanels) < 4
                return;
            end
            p4 = app.MultiPanels{4};
            if isempty(p4) || ~isvalid(p4); return; end
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            % Build the display volume (mirror of refreshVolViewer)
            V = double(app.D.vol);
            if ~isempty(app.DisplayExclusion) && any(app.DisplayExclusion(:))
                V(app.DisplayExclusion) = -1000;
            end
            % Only mask down to segmented voxels AFTER Step 2 (so
            % during segmentation the user still sees the full body
            % with the segmented region tinted by the label overlay).
            if app.Step > 2 && ~isempty(app.Mask) && any(app.Mask(:))
                V(~app.Mask) = -1000;
            end
            sz = size(V);
            % More aggressive downsample for the small pane.
            ds = max(1, floor(max(sz) / 320));
            if ds > 1
                V = V(1:ds:end, 1:ds:end, 1:ds:end);
            end
            hu_lo = -1000; hu_hi = 2000;
            Vn = single((V - hu_lo) / (hu_hi - hu_lo));
            Vn = max(0, min(1, Vn));
            Vn = flip(Vn, 3);
            [cmap, amap] = preprocess.cta_transfer_function( ...
                app.VolStyle, hu_lo, hu_hi);
            try
                if isempty(app.Multi3DViewer) || ~isvalid(app.Multi3DViewer)
                    % Clear the panel except for the Pan toggle which
                    % is parented to ImagePanel, not p4
                    delete(allchild(p4));
                    v3d = viewer3d('Parent', p4, ...
                        'BackgroundColor',     [0.02 0.02 0.05], ...
                        'BackgroundGradient',  'on', ...
                        'GradientColor',       [0.10 0.12 0.18], ...
                        'CameraZoom',          1.4, ...
                        'Lighting',            'on', ...
                        'RenderingQuality',    'high', ...
                        'Denoising',           'on', ...
                        'OrientationAxes',     'off', ...
                        'Interactions',        'rotate');
                    try
                        v3d.ButtonDownFcn = @(src,evt) onViewer3DDown(app, src, evt, 'multi');
                        addlistener(v3d, 'ClickReleased', ...
                            @(~,~) onViewer3DUp(app));
                    catch
                    end
                    app.Multi3DViewer = volshow(Vn, ...
                        'Parent',         v3d, ...
                        'RenderingStyle', 'VolumeRendering', ...
                        'Colormap',       cmap, ...
                        'Alphamap',       amap);
                    sz_v = size(Vn);
                    cy = sz_v(1)/2; cx = sz_v(2)/2; cz = sz_v(3)/2;
                    span = max(sz_v);
                    try
                        v3d.CameraTarget   = [cx, cy, cz];
                        v3d.CameraPosition = [cx, cy - 3*span, cz];
                        v3d.CameraUpVector = [0, 0, 1];
                    catch
                    end
                else
                    app.Multi3DViewer.Data     = Vn;
                    app.Multi3DViewer.Colormap = cmap;
                    app.Multi3DViewer.Alphamap = amap;
                end
                % Re-attach the colored mask overlay each time the
                % pane-4 viewer3d is rebuilt — the volshow children
                % don't survive a CT volume rebuild.
                refreshMaskLabel3DOverlay(app, 'multi');
            catch ME
                fprintf('[refreshMulti3DPane] %s\n', ME.message);
            end
        end

        function setMultiVisible(app, on)
            ensureMultiPanels(app);
            for k = 1:numel(app.MultiPanels)
                if ~isempty(app.MultiPanels{k}) && isvalid(app.MultiPanels{k})
                    if on
                        app.MultiPanels{k}.Visible = 'on';
                    else
                        app.MultiPanels{k}.Visible = 'off';
                    end
                end
            end
        end

        function refreshMultiView(app)
            % Render axial / sagittal / coronal / 3-D MIP into the
            % four mini panes. Uses the current slice indices for the
            % MPR panes so the user sees the slice they were on
            % before switching to the 2x2 layout.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            ensureMultiPanels(app);
            sz = size(app.D.vol);
            sx = app.D.pixel_mm(2);
            sy = app.D.pixel_mm(1);
            sz_mm = app.D.slice_spacing_mm;
            apply_excl = ~isempty(app.DisplayExclusion) && ...
                         any(app.DisplayExclusion(:));
            vol = app.D.vol;  %#ok<NASGU>  % apply_excl path uses it
            % --- Axial (top-left) ---------------------------------
            img_a = extractSliceOrSlab(app, 'axial', app.IdxAxial);
            if apply_excl
                img_a(app.DisplayExclusion(:, :, app.IdxAxial)) = -1000;
            end
            L_a = labelSlice(app, app.IdxAxial, 'axial');
            % Axial: ydir='reverse' so anterior of patient (low data y) is
            % at TOP of the displayed pane — standard radiology
            % convention. With 'normal', the spine ended up at the
            % top of the panel and clicks landed on the spine when
            % the user thought they were clicking the aorta.
            renderPane(app.MultiAxes{1}, ...
                compositeView(img_a, [], [], app.WL, ...
                    app.InvertDisplay, L_a, app.LabelColors), ...
                [sx sy 1], 'reverse', 'axial');
            % --- Sagittal (top-right) -----------------------------
            img_s = extractSliceOrSlab(app, 'sagittal', app.IdxSagittal);
            if apply_excl
                img_s(squeeze(app.DisplayExclusion(:, app.IdxSagittal, :)).') = -1000;
            end
            L_s = labelSlice(app, app.IdxSagittal, 'sagittal');
            renderPane(app.MultiAxes{2}, ...
                compositeView(img_s, [], [], app.WL, ...
                    app.InvertDisplay, L_s, app.LabelColors), ...
                [sy sz_mm 1], 'reverse', 'sagittal');
            % --- Coronal (bottom-left) ----------------------------
            img_c = extractSliceOrSlab(app, 'coronal', app.IdxCoronal);
            if apply_excl
                img_c(squeeze(app.DisplayExclusion(app.IdxCoronal, :, :)).') = -1000;
            end
            L_c = labelSlice(app, app.IdxCoronal, 'coronal');
            renderPane(app.MultiAxes{3}, ...
                compositeView(img_c, [], [], app.WL, ...
                    app.InvertDisplay, L_c, app.LabelColors), ...
                [sx sz_mm 1], 'reverse', 'coronal');
            % --- 3-D recon (bottom-right) -------------------------
            refreshMulti3DPane(app);
            % --- Measurement overlay (all 2-D panes) -------------
            refreshMeasurementOverlay(app);
            % --- Centerline overlay (all 2-D panes, +3-D pane) ---
            drawCenterlineOverlayMulti(app);
            % --- Seed markers (proximal/R-CFA/L-CFA on each pane) ---
            drawSeedMarkersMulti(app);

            function renderPane(ax, img, daspect_v, ydir, vm)
                cla(ax);
                hImg = imagesc(ax, img);
                colormap(ax, gray); axis(ax, 'tight');
                ax.DataAspectRatio = daspect_v;
                ax.DataAspectRatioMode = 'manual';
                ax.PlotBoxAspectRatioMode = 'auto';
                ax.YDir = ydir;
                ax.XTick = []; ax.YTick = [];
                % Route clicks: in 2x2, the only consumer right
                % now is the measurement tool. Without an armed
                % tool, onMultiPaneClick is a no-op so this is
                % safe even when no measurement is in progress.
                hImg.HitTest       = 'on';
                hImg.PickableParts = 'all';
                hImg.ButtonDownFcn = @(~,evt) onMultiPaneClick(app, evt, vm);
            end
        end

        function ensureVolPanel(app)
            % Lazy-create the panel that holds the volshow render. We
            % match the MainAxes geometry so the user sees it occupy
            % the same screen real estate.
            if ~isempty(app.VolPanel) && isvalid(app.VolPanel); return; end
            ax_pos = app.MainAxes.Position;
            % VolPanel parents into ImagePanel; volshow is built lazily
            % in refreshVolViewer (so we don't pay the volshow startup
            % cost unless the user opens the 3-D Volume tab).
            app.VolPanel = uipanel(app.ImagePanel, ...
                'Position', ax_pos, ...
                'BackgroundColor', 'k', 'BorderType', 'none', ...
                'Visible', 'off', 'Tag', 'vol_panel');
            % HUD overlay across the bottom of the panel — shows zoom,
            % vol size, and the keyboard shortcuts hint. Top-left
            % position would overlap the orientation cube.
            app.VolHudLabel = uilabel(app.VolPanel, ...
                'Position', [4 2 ax_pos(3)-8 18], ...
                'Text', '', 'FontSize', 10, ...
                'FontColor', [0.85 0.85 0.85], ...
                'BackgroundColor', [0.02 0.02 0.05], ...
                'HorizontalAlignment', 'left');
        end

        function createOverlayTools(app)
            % Persistent overlay buttons that live ON TOP of the image
            % area in every view mode (axial, coronal, sagittal, 3D
            % MIP, 3D Volume, CPR). Stack vertically at the top-left.
            % Parented to ImagePanel so viewer3d (in VolPanel) can't
            % cover them.
            ax_pos = app.MainAxes.Position;
            btn_w = 140; btn_h = 26;
            btn_x = ax_pos(1) + 8;
            % Top-most button just under the top edge of the image area
            top_y = ax_pos(2) + ax_pos(4) - btn_h - 6;
            row = @(k) [btn_x, top_y - (k-1)*(btn_h + 4), btn_w, btn_h];

            app.PanToggleBtn = uibutton(app.ImagePanel, 'state', ...
                'Position', row(1), ...
                'Text', 'Drag: ROTATE', 'Value', false, ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.92 0.92 0.96], ...
                'Tooltip', ['Click to toggle drag between rotate and pan ' ...
                            '(rotate is 3-D only; pan works on 2-D too). ' ...
                            'P key also toggles.'], ...
                'ValueChangedFcn', @(b,~) togglePanMode(app));

            app.WLToggleBtn = uibutton(app.ImagePanel, 'state', ...
                'Position', row(2), ...
                'Text', 'Drag: W / L', 'Value', false, ...
                'FontSize', 11, ...
                'BackgroundColor', [0.92 0.92 0.96], ...
                'Tooltip', ['Click to enter Window/Level drag mode. ' ...
                            'Then drag in the image: horizontal = window ' ...
                            'width, vertical = level. Click again to exit.'], ...
                'ValueChangedFcn', @(b,~) toggleWLMode(app));

            app.SnapBtn = uibutton(app.ImagePanel, 'push', ...
                'Position', row(3), ...
                'Text', 'Save snapshot (S)', 'FontSize', 11, ...
                'Tooltip', 'Export current view as PNG into results/snapshots/', ...
                'ButtonPushedFcn', @(~,~) saveSnapshot(app));

            app.ResetBtn = uibutton(app.ImagePanel, 'push', ...
                'Position', row(4), ...
                'Text', 'Reset view (R)', 'FontSize', 11, ...
                'Tooltip', ['Reset the view: AP preset in 3-D Volume, ' ...
                            'fit-to-data in 2-D and MIP modes.'], ...
                'ButtonPushedFcn', @(~,~) resetView(app));

            % Zoom + / − side-by-side, then Fit full-width below.
            half_w = (btn_w - 4) / 2;
            r5 = row(5);
            app.ZoomInBtn = uibutton(app.ImagePanel, 'push', ...
                'Position', [r5(1), r5(2), half_w, btn_h], ...
                'Text', '+', 'FontSize', 14, 'FontWeight', 'bold', ...
                'Tooltip', 'Zoom in', ...
                'ButtonPushedFcn', @(~,~) zoomBy(app, 0.7));
            app.ZoomOutBtn = uibutton(app.ImagePanel, 'push', ...
                'Position', [r5(1) + half_w + 4, r5(2), half_w, btn_h], ...
                'Text', '−', 'FontSize', 14, 'FontWeight', 'bold', ...
                'Tooltip', 'Zoom out', ...
                'ButtonPushedFcn', @(~,~) zoomBy(app, 1/0.7));
            app.FitBtn = uibutton(app.ImagePanel, 'push', ...
                'Position', row(6), ...
                'Text', 'Fit', 'FontSize', 11, ...
                'Tooltip', 'Auto-fit: full volume in 2-D, zoom-to-fit in 3-D.', ...
                'ButtonPushedFcn', @(~,~) fitView(app));

            % Track all overlay buttons so we can uistack them to top
            % whenever the view changes (otherwise viewer3d's GPU
            % layer covers them on the 3-D Volume tab).
            app.OverlayTools = {app.PanToggleBtn, app.WLToggleBtn, ...
                                app.SnapBtn, app.ResetBtn, ...
                                app.ZoomInBtn, app.ZoomOutBtn, app.FitBtn};

            % Cursor HU readout — centered strip below the slice slider
            % and below the image. Parented to UIFigure (not ImagePanel)
            % so it sits in the band between the footer keybar and
            % the ImagePanel bottom edge, visible from any tab.
            fig_w = app.UIFigure.Position(3);
            side_w = 410;        % side panel width
            ip_left = 10;
            ip_right = fig_w - side_w - 10;
            cur_w = min(420, ip_right - ip_left - 20);
            cur_h = 22;
            cur_x = ip_left + ((ip_right - ip_left) - cur_w) / 2;
            cur_y = 26;          % above the footer (y=2-20), below ImagePanel (y=80)
            app.CursorHULabel = uilabel(app.UIFigure, ...
                'Position', [cur_x cur_y cur_w cur_h], ...
                'Text', '', 'FontSize', 11, ...
                'FontColor', [0.95 0.95 0.95], ...
                'BackgroundColor', [0.05 0.05 0.10], ...
                'HorizontalAlignment', 'center', ...
                'Visible', 'off');   % hidden until it has a readout (no empty black bar)
        end

        function refreshVolViewer(app)
            ensureVolPanel(app);
            % Empty-state — no volume loaded yet, show a visible
            % placeholder rather than a black void. Note: the
            % aorta-only mask path runs further down once a volume IS
            % loaded.
            if isempty(app.D) || ~isfield(app.D, 'vol')
                delete(allchild(app.VolPanel));
                pp = app.VolPanel.Position;
                ax = uiaxes(app.VolPanel, 'Position', [10 10 pp(3)-20 pp(4)-20]);
                ax.XColor = 'none'; ax.YColor = 'none';
                ax.Color = [0.05 0.05 0.08];
                ax.XLim = [0 1]; ax.YLim = [0 1];
                text(ax, 0.5, 0.55, '3-D Volume', ...
                    'FontSize', 22, 'Color', [0.85 0.85 0.90], ...
                    'HorizontalAlignment','center', 'FontWeight','bold');
                text(ax, 0.5, 0.45, 'Load a CT in Step 1 to see the recon here.', ...
                    'FontSize', 13, 'Color', [0.55 0.60 0.70], ...
                    'HorizontalAlignment','center');
                app.SliceLabel.Text = '3D Volume   (no volume loaded)';
                app.VolViewer = [];
                return;
            end
            style_label = struct('cta_recon','CTA recon (vessels + bone)', ...
                                  'vessel','vessels (bone suppressed)', ...
                                  'bone','bone only', ...
                                  'mip','MIP', ...
                                  'isosurface','isosurface — vessel');
            if isfield(style_label, app.VolStyle)
                lab = style_label.(app.VolStyle);
            else
                lab = app.VolStyle;
            end
            % If a segmentation mask is active the rendered volume is
            % already masked to vessel voxels (~Mask zeroed to -1000 HU
            % below). Reflect that in the panel title — the prior
            % "vessels + bone" wording was a lie under those conditions.
            mask_active = ~isempty(app.Mask) && any(app.Mask(:));
            if mask_active
                if app.Step == 2
                    n_clicks = max(0, app.NextSegLabel - 1);
                    app.SliceLabel.Text = sprintf( ...
                        '3D Volume   selecting vessels — %d click(s) so far', ...
                        n_clicks);
                else
                    app.SliceLabel.Text = '3D Volume   segmented aorta (isolated)';
                end
            else
                app.SliceLabel.Text = sprintf('3D Volume   %s', lab);
            end
            % Build a display volume that respects DisplayExclusion.
            % Downsample only when the source volume is too big for the
            % renderer to keep up — for typical CTA sizes (≤ ~512 in any
            % dimension) we render at native resolution. Downstream
            % centerline work is unaffected (this is display-only).
            V = double(app.D.vol);
            if ~isempty(app.DisplayExclusion) && any(app.DisplayExclusion(:))
                V(app.DisplayExclusion) = -1000;
            end
            % Aorta-only render — once Step 2 has produced a mask, we
            % render JUST the segmented aorta in the volshow scene
            % (zero everything else to air HU, which the CTA TF maps
            % to transparent). This is the TeraRecon convention: the
            % pre-segmentation recon shows the whole body, the
            % post-segmentation recon shows the aorta in isolation
            % so the user can rotate / inspect / place centerline
            % work without anatomy clutter.
            %
            % BUT only auto-mask AFTER Step 2 finishes. While the
            % user is still on Step 2 (actively segmenting), keep
            % the full body visible so they can see anatomy
            % surrounding their selection — the colored mask
            % overlay paints a subtle tint on segmented voxels to
            % show what's been picked.
            if app.Step > 2 && ~isempty(app.Mask) && any(app.Mask(:))
                V(~app.Mask) = -1000;
            end
            sz = size(V);
            % Cap the largest dimension at 512 voxels for the renderer.
            % Was 256, which forced a 2× downsample on a 512×512×~600 CT
            % and made the recon visibly grainy. 512 keeps native
            % resolution for typical CTAs and only kicks in for very
            % large volumes (e.g. 1024×1024 high-pitch CT).
            ds = max(1, floor(max(sz) / 512));
            if ds > 1
                V = V(1:ds:end, 1:ds:end, 1:ds:end);
            end

            % Normalise to a FIXED HU range so the transfer function is
            % anchored to absolute HU, not the per-image W/L.
            hu_lo = -1000; hu_hi = 2000;
            Vn = single((V - hu_lo) / (hu_hi - hu_lo));
            Vn = max(0, min(1, Vn));
            % volshow places voxel z=1 at world-Z=0 (bottom of viewer)
            % under its default Z-up camera, so without this flip the
            % anatomically-superior end of the volume drops to the
            % bottom of the screen — head-down. Flip along axis 3 so
            % the rendering matches every clinical viewer (head at
            % top, pelvis at bottom). This is display-only; the
            % source app.D.vol stays in its original orientation so
            % MPR slice indices, seeds, and centerline coordinates are
            % unchanged.
            Vn = flip(Vn, 3);

            % Resolve the rendering style + transfer function. The
            % isosurface mode falls back to volume rendering with a
            % near-binary alpha curve since true isosurface in volshow
            % requires a separate code path.
            switch app.VolStyle
                case 'isosurface'
                    rs = 'Isosurface';
                    [cmap, amap] = preprocess.cta_transfer_function('vessel', hu_lo, hu_hi);
                case 'mip'
                    rs = 'MaximumIntensityProjection';
                    [cmap, amap] = preprocess.cta_transfer_function('mip', hu_lo, hu_hi);
                otherwise
                    rs = 'VolumeRendering';
                    [cmap, amap] = preprocess.cta_transfer_function(app.VolStyle, hu_lo, hu_hi);
            end

            % Step 3+ "isolated vessel" override. Once the user has
            % committed a segmentation and stepped past Step 2, the
            % volume above (V(~Mask)=-1000) is just the masked CTA.
            % The default CTA transfer function makes lumen voxels
            % only mildly opaque and tints them per-HU, which leaves
            % the iliacs/branches washed out. Swap in a flat colored
            % colormap with a sqrt alpha ramp so the entire vessel
            % tree pops as a TeraRecon-style isolated render.
            %
            % Color choice:
            %   - while runSegmentation is actively growing: blue
            %     (IsActivelySegmenting flag) so the user sees an
            %     unambiguous "computing" state distinct from the
            %     final result.
            %   - otherwise: IsolatedVesselColor (light coral-red by
            %     default, user-changeable via right-click context
            %     menu on the 3-D recon).
            if app.Step > 2 && ~isempty(app.Mask) && any(app.Mask(:)) && ...
                    strcmp(rs, 'VolumeRendering')
                if app.IsActivelySegmenting
                    base_color = app.ActiveVesselColor;
                    cmap = repmat(base_color, 256, 1);
                    amap = linspace(0, 1, 256)' .^ 0.5;
                else
                    % Per-label coloring: each of the 9 anatomic labels
                    % gets its own ~28-bin band in the 256-entry
                    % colormap. Voxels with non-anatomic labels
                    % (200+ branch IDs) and unlabeled-but-in-mask
                    % voxels fall into the default coral-red band.
                    base_color = app.IsolatedVesselColor;
                    cmap = repmat(base_color, 256, 1);
                    amap = linspace(0, 1, 256)' .^ 0.5;
                    if ~isempty(app.MaskLabel) && ...
                            isequal(size(app.MaskLabel), size(app.D.vol))
                        ml_ds = app.MaskLabel;
                        if ds > 1
                            ml_ds = ml_ds(1:ds:end, 1:ds:end, 1:ds:end);
                        end
                        ml_ds = flip(ml_ds, 3);   % match Vn flip
                        % Pin 10 evenly-spaced "label bins" across the
                        % 256-entry colormap. Bin 1 = default coral
                        % red (already set). Bins 2-10 = anatomic
                        % labels 1-9.
                        N_BINS = 10;
                        bin_width = floor(256 / N_BINS);
                        anat_colors = [
                            1.00 0.42 0.32;   % 1 aorta — coral red
                            0.30 0.55 1.00;   % 2 iliac L — blue
                            0.10 0.85 0.95;   % 3 iliac R — cyan
                            0.40 1.00 0.30;   % 4 CFA L — lime
                            0.50 1.00 0.80;   % 5 CFA R — mint
                            1.00 0.95 0.20;   % 6 renal L — yellow
                            1.00 0.55 0.10;   % 7 renal R — orange
                            1.00 0.20 0.85;   % 8 celiac — magenta
                            0.75 0.60 1.00];  % 9 SMA — lavender
                        % For each anatomic label, recode Vn voxels with
                        % that label to a value in the label's bin
                        % range, and color that bin band in the cmap.
                        for lab_id = 1:size(anat_colors, 1)
                            voxels = (ml_ds == lab_id);
                            if ~any(voxels(:)); continue; end
                            bin_start = (lab_id) * bin_width;        % bins 11..20 for label 1, etc
                            bin_end   = min(256, bin_start + bin_width - 1);
                            bin_value = (bin_start + bin_end) / 2 / 255;
                            % Where this label is present, override Vn
                            % to the bin's center value (so it lands
                            % in the colored band of the colormap).
                            Vn(voxels) = single(bin_value);
                            cmap(bin_start:bin_end, :) = repmat(anat_colors(lab_id, :), ...
                                bin_end - bin_start + 1, 1);
                            amap(bin_start:bin_end) = 0.9;
                        end
                    end
                end
            end

            try
                if isempty(app.VolViewer) || ~isvalid(app.VolViewer)
                    delete(allchild(app.VolPanel));
                    has_viewer3d = exist('viewer3d', 'class') + ...
                                   exist('viewer3d', 'file') > 0;
                    if ~has_viewer3d
                        error('AorticCenterlineApp:NoViewer3D', ...
                            'viewer3d unavailable — falling back to static MIP.');
                    end
                    % Interactions = 'rotate' (instead of 'all') so the
                    % default drag is rotate. P toggles to 'pan'. This
                    % may also suppress the right-click "Display info /
                    % Scale bar" popup that 'all' enables.
                    v3d = viewer3d('Parent', app.VolPanel, ...
                        'BackgroundColor',     [0.02 0.02 0.05], ...
                        'BackgroundGradient',  'on', ...
                        'GradientColor',       [0.10 0.12 0.18], ...
                        'CameraZoom',          1.4, ...
                        'Lighting',            'on', ...
                        'RenderingQuality',    'high', ...
                        'Denoising',           'on', ...
                        'OrientationAxes',     'on', ...
                        'Interactions',        'rotate');
                    % CRITICAL: viewer3d's GPU canvas swallows mouse
                    % events from the figure WindowButtonDownFcn. We
                    % subscribe directly to viewer3d's own
                    % ButtonDownFcn + ClickReleased event so the
                    % click-to-grow workflow actually fires.
                    try
                        v3d.ButtonDownFcn = @(src,evt) onViewer3DDown(app, src, evt, 'single');
                        addlistener(v3d, 'ClickReleased', ...
                            @(~,~) onViewer3DUp(app));
                    catch ME
                        fprintf('[init] failed to wire viewer3d events: %s\n', ME.message);
                    end
                    app.VolViewer = volshow(Vn, ...
                        'Parent',         v3d, ...
                        'RenderingStyle', rs, ...
                        'Colormap',       cmap, ...
                        'Alphamap',       amap);
                    % Right-click context menu on the recon panel —
                    % gives the user "Change color / preset / clear
                    % / back to MPR" options. viewer3d's GPU canvas
                    % swallows mouse events at the panel level, so
                    % the ContextMenu binds to the parent uipanel
                    % which fires when the click lands at the
                    % panel's edge / chrome region. Right-click on
                    % the rendered volume itself may not always
                    % surface the menu (viewer3d limitation), but
                    % this is enough to expose the options.
                    try
                        cm = uicontextmenu(app.UIFigure);
                        uimenu(cm, 'Text', 'Change vessel color…', ...
                            'MenuSelectedFcn', @(~,~) pickIsolatedVesselColor(app));
                        m_pre = uimenu(cm, 'Text', 'Preset colors');
                        presets = { ...
                            'Light coral-red (default)', [1.00 0.42 0.32]; ...
                            'Bright red',                [0.90 0.15 0.15]; ...
                            'Orange',                    [1.00 0.55 0.10]; ...
                            'Pink',                      [1.00 0.55 0.75]; ...
                            'Bright blue',               [0.20 0.55 1.00]; ...
                            'Lime',                      [0.40 1.00 0.30]; ...
                            'Cyan',                      [0.10 0.85 0.95]; ...
                            'Yellow',                    [1.00 0.95 0.20]; ...
                            'White',                     [0.95 0.95 0.95]};
                        for kk = 1:size(presets, 1)
                            uimenu(m_pre, 'Text', presets{kk, 1}, ...
                                'MenuSelectedFcn', ...
                                @(~,~) setIsolatedVesselColor(app, presets{kk, 2}));
                        end
                        uimenu(cm, 'Text', 'Restore default color', ...
                            'Separator', 'on', ...
                            'MenuSelectedFcn', ...
                            @(~,~) setIsolatedVesselColor(app, [1.00 0.42 0.32]));
                        uimenu(cm, 'Text', 'Clear segmentation', ...
                            'Separator', 'on', ...
                            'MenuSelectedFcn', @(~,~) clearMask(app));
                        uimenu(cm, 'Text', 'Back to MPR (2x2 view)', ...
                            'MenuSelectedFcn', @(~,~) setView(app, '2x2'));
                        app.VolPanel.ContextMenu = cm;
                        v3d.ContextMenu = cm;
                    catch
                    end
                    % --- Default to AP (anteroposterior) view -------
                    % Patient anterior is at LOW data-Y (DICOM image
                    % convention with patient supine). Camera looks
                    % from -Y toward +Y, with +Z = patient superior
                    % (head). Up vector = +Z so the head is at the
                    % top of the screen. CENTER on the mask centroid
                    % rather than the volume center so the vessel
                    % fills the pane (offset masks otherwise render
                    % off to one side).
                    sz = size(Vn);
                    if ~isempty(app.Mask) && isequal(size(app.Mask), sz) && any(app.Mask(:))
                        [yy_m, xx_m, zz_m] = ind2sub(sz, find(app.Mask));
                        cy = (min(yy_m) + max(yy_m)) / 2;
                        cx = (min(xx_m) + max(xx_m)) / 2;
                        cz = (min(zz_m) + max(zz_m)) / 2;
                        span = max([max(yy_m)-min(yy_m), max(xx_m)-min(xx_m), max(zz_m)-min(zz_m)]);
                        % User-calibrated offsets — shift target UP
                        % toward the head so the vessel renders
                        % visually centered (see resetCamera).
                        cx = cx + (-0.023) * span;
                        cy = cy + (-0.033) * span;
                        cz = cz + (-0.557) * span;
                    else
                        cy = sz(1) / 2; cx = sz(2) / 2; cz = sz(3) / 2;
                        span = max(sz);
                    end
                    try
                        v3d.CameraTarget   = [cx, cy, cz];
                        v3d.CameraPosition = [cx, cy - 3 * span, cz];
                        v3d.CameraUpVector = [0, 0, 1];
                    catch
                        % Older releases may not allow direct camera set
                    end
                    if strcmp(rs, 'Isosurface')
                        % Iso-value at "bright contrast" HU ≈ 250
                        try
                            app.VolViewer.IsosurfaceValue = ...
                                (250 - hu_lo) / (hu_hi - hu_lo);
                        catch
                        end
                    end
                    % Home button override: viewer3d's built-in
                    % "house" icon resets CameraPositionMode to 'auto'
                    % (data-fit camera). Catch that and re-apply our
                    % AP preset instead. ApplyingAPReset guards
                    % against the recursion the listener would
                    % otherwise cause.
                    try
                        addlistener(v3d, 'CameraPositionMode', 'PostSet', ...
                            @(~,~) onCameraModeChange(app));
                    catch
                    end
                else
                    app.VolViewer.Data           = Vn;
                    app.VolViewer.Colormap       = cmap;
                    app.VolViewer.Alphamap       = amap;
                    app.VolViewer.RenderingStyle = rs;
                    if strcmp(rs, 'Isosurface')
                        try
                            app.VolViewer.IsosurfaceValue = ...
                                (250 - hu_lo) / (hu_hi - hu_lo);
                        catch
                        end
                    end
                end
                % --- 3-D overlays: seeds + centerlines on viewer3d --
                draw3DOverlays(app);
                updateVolHud(app);
                % Measurement overlay (yellow 3-D lines composited
                % as a second volshow on top of the CT volshow).
                refreshMeasurement3DOverlay(app, 'single');
                % Colored mask-label overlay (vessel segmentations).
                refreshMaskLabel3DOverlay(app, 'single');
            catch ME
                % Static MIP fallback when the volume-render chain
                % isn't available (older releases, headless GPU, etc.).
                delete(allchild(app.VolPanel));
                pp = app.VolPanel.Position;
                ax = uiaxes(app.VolPanel, 'Position', [10 10 pp(3)-20 pp(4)-20]);
                imagesc(ax, squeeze(max(Vn, [], 1)).');
                axis(ax, 'image'); colormap(ax, gray);
                ax.XTick = []; ax.YTick = [];
                title(ax, sprintf('volshow unavailable (%s) — static MIP', ...
                    ME.identifier), 'FontSize', 10);
            end
        end

        function setVolStyle(app, style)
            app.VolStyle = style;
            if strcmp(app.ViewMode, '3dvol')
                refreshVolViewer(app);
            end
        end

        function draw3DOverlays(app)
            % Plot the 3 seeds + the right/left centerlines as 3-D
            % graphics children of the viewer3d so they render in the
            % same scene as the volume. viewer3d hosts standard MATLAB
            % graphics — line, scatter, surface — so we use those.
            if isempty(app.VolViewer) || ~isvalid(app.VolViewer); return; end
            try
                v3d = app.VolViewer.Parent;
            catch
                return;
            end
            if ~isvalid(v3d); return; end

            % Volume data is downsampled when handed to volshow, but
            % viewer3d's coordinate system uses the data's intrinsic
            % grid. Scale seeds + centerlines to that grid.
            sz_full = size(app.D.vol);
            sz_view = size(app.VolViewer.Data);
            scale = sz_view ./ sz_full;
            % Account for the display flip along axis 3 (refreshVolViewer
            % flips Vn in axis 3 so head ends at the top of the viewer).
            flip_z = sz_view(3);

            map_to_vol = @(v) [...
                (v(2) - 0.5) * scale(2) + 0.5, ...   % data X
                (v(1) - 0.5) * scale(1) + 0.5, ...   % data Y
                flip_z - ((v(3) - 0.5) * scale(3) + 0.5) + 1];   % data Z (flipped)

            % Wipe previous overlays
            kids = v3d.Children;
            for k = 1:numel(kids)
                if isprop(kids(k), 'Tag') && startsWith(kids(k).Tag, 'cl3d_')
                    delete(kids(k));
                end
            end

            % Seeds
            seeds = struct();
            seeds.proximal  = app.SeedProximal;
            seeds.right_cfa = app.SeedRightCFA;
            seeds.left_cfa  = app.SeedLeftCFA;
            cols = struct('proximal',[0.10 0.85 0.10], ...
                          'right_cfa',[0.95 0.20 0.20], ...
                          'left_cfa',[0.20 0.45 0.95]);
            fns = fieldnames(seeds);
            for k = 1:numel(fns)
                v = seeds.(fns{k});
                if isempty(v); continue; end
                p = map_to_vol(v);
                try
                    line(v3d, p(1), p(2), p(3), ...
                        'Marker', 'o', 'MarkerSize', 14, ...
                        'MarkerFaceColor', cols.(fns{k}), ...
                        'MarkerEdgeColor', 'k', 'LineStyle', 'none', ...
                        'Tag', sprintf('cl3d_seed_%s', fns{k}));
                catch
                end
            end

            % Right centerline (red)
            if ~isempty(app.PolylineRight)
                P = arrayfun(@(k) map_to_vol(app.PolylineRight(k,:)), ...
                    1:size(app.PolylineRight,1), 'UniformOutput', false);
                P = vertcat(P{:});
                try
                    line(v3d, P(:,1), P(:,2), P(:,3), ...
                        '-', 'Color', [0.95 0.20 0.20], ...
                        'LineWidth', 2.0, 'Tag', 'cl3d_line_right');
                catch
                end
            end
            % Left centerline (blue)
            if ~isempty(app.PolylineLeft)
                P = arrayfun(@(k) map_to_vol(app.PolylineLeft(k,:)), ...
                    1:size(app.PolylineLeft,1), 'UniformOutput', false);
                P = vertcat(P{:});
                try
                    line(v3d, P(:,1), P(:,2), P(:,3), ...
                        '-', 'Color', [0.20 0.45 0.95], ...
                        'LineWidth', 2.0, 'Tag', 'cl3d_line_left');
                catch
                end
            end
            % Bifurcation magenta star
            if ~isempty(app.PolylineRight) && ~isempty(app.BifurcNodeIdx) && ...
                    app.BifurcNodeIdx >= 1 && app.BifurcNodeIdx <= size(app.PolylineRight, 1)
                B = map_to_vol(app.PolylineRight(app.BifurcNodeIdx, :));
                try
                    line(v3d, B(1), B(2), B(3), ...
                        'Marker', 'p', 'MarkerSize', 18, ...
                        'MarkerFaceColor', [0.95 0.10 0.95], ...
                        'MarkerEdgeColor', 'k', 'LineStyle', 'none', ...
                        'Tag', 'cl3d_bifurc');
                catch
                end
            end
        end

        function ensureCenterlineCtxMenu(app)
            % Build the right-click menu attached to the centerline
            % plots. TeraRecon-style options: insert node at the
            % click, delete the nearest node, or rebuild radii from
            % the segmentation mask.
            if ~isempty(app.ClContextMenu) && isvalid(app.ClContextMenu); return; end
            cm = uicontextmenu(app.UIFigure);
            uimenu(cm, 'Text', 'Insert node here', ...
                'MenuSelectedFcn', @(~,~) editCenterline(app, 'insert'));
            uimenu(cm, 'Text', 'Delete nearest node', ...
                'MenuSelectedFcn', @(~,~) editCenterline(app, 'delete'));
            uimenu(cm, 'Text', 'Move nearest node here', ...
                'MenuSelectedFcn', @(~,~) editCenterline(app, 'move'));
            uimenu(cm, 'Separator','on', 'Text', 'Recompute radii from mask', ...
                'MenuSelectedFcn', @(~,~) editCenterline(app, 'recompute_radii'));
            app.ClContextMenu = cm;
        end

        function editCenterline(app, mode)
            % Mutate the centerline based on the right-click context.
            % `app.ClCtxClickVoxel` holds the click voxel saved by the
            % main click handler when the user right-clicked on the
            % centerline plot.
            if isempty(app.ClCtxClickVoxel); return; end
            if isempty(app.PolylineRight); return; end
            click = app.ClCtxClickVoxel;
            % Clamp to the current volume's bounds — never accept a
            % click that would put a node outside the data, even from
            % a programmatic caller.
            sz = size(app.D.vol);
            click(1) = max(1, min(sz(1), click(1)));
            click(2) = max(1, min(sz(2), click(2)));
            click(3) = max(1, min(sz(3), click(3)));
            switch app.ClCtxClickSide
                case 'left'
                    P = app.PolylineLeft; R = app.R_vox_left;
                otherwise
                    P = app.PolylineRight; R = app.R_vox_right;
            end
            if isempty(P); return; end
            d = vecnorm(P - click, 2, 2);
            [~, k_near] = min(d);

            switch mode
                case 'insert'
                    P = [P(1:k_near, :); click; P(k_near+1:end, :)];
                    if numel(R) >= k_near
                        R = [R(1:k_near); R(k_near); R(k_near+1:end)];
                    else
                        R = [R; mean(R)];
                    end
                case 'delete'
                    if size(P, 1) <= 4
                        uialert(app.UIFigure, ...
                            'Need at least 4 nodes for the spline. Delete more carefully.', ...
                            'Centerline edit');
                        return;
                    end
                    P(k_near, :) = []; R(k_near) = [];
                case 'move'
                    P(k_near, :) = click;
                case 'recompute_radii'
                    if isempty(app.Mask) || ~any(app.Mask(:))
                        uialert(app.UIFigure, ...
                            'No segmentation mask — recompute radii needs Step 2 done first.', ...
                            'Centerline edit');
                        return;
                    end
                    Dt = bwdist(~logical(app.Mask));
                    sz = size(app.Mask);
                    R = zeros(size(P, 1), 1);
                    for k = 1:size(P, 1)
                        y = max(1, min(sz(1), round(P(k,1))));
                        x = max(1, min(sz(2), round(P(k,2))));
                        z = max(1, min(sz(3), round(P(k,3))));
                        R(k) = Dt(y, x, z);
                    end
            end

            % Write back
            switch app.ClCtxClickSide
                case 'left'
                    app.PolylineLeft = P; app.R_vox_left = R;
                otherwise
                    app.PolylineRight = P; app.R_vox_right = R;
                    app.Polyline = P; app.R_vox = R;   % keep aliases in sync
            end
            % Centerline changed — invalidate CPR cache.
            app.CPRImage = [];
            % Re-find bifurcation if both polylines exist
            if ~isempty(app.PolylineLeft) && ~isempty(app.PolylineRight)
                [bif, ~] = find_skeleton_bifurc(app.PolylineRight, app.PolylineLeft, 3.0);
                app.BifurcNodeIdx = bif;
            end
            refreshMain(app);
            if strcmp(app.ViewMode, 'cpr'); refreshXSec(app); end
        end

        function ensureXSecPanel(app)
            % Lazy-construct the orthogonal cross-section pane that
            % appears in CPR mode. It floats over the bottom-right of
            % the image panel so users can see the lumen at the current
            % arc-length scrub position without leaving the CPR view.
            if ~isempty(app.XSecPanel) && isvalid(app.XSecPanel); return; end
            ip = app.ImagePanel.Position;
            w = 260;  h = 280;
            x0 = ip(3) - w - 14;
            y0 = 90;   % above the slider
            app.XSecPanel = uipanel(app.ImagePanel, ...
                'Position', [x0 y0 w h], ...
                'BackgroundColor', [0.05 0.05 0.07], ...
                'BorderType', 'line', ...
                'HighlightColor', [0.30 0.30 0.40], ...
                'Title', 'Cross-section', ...
                'TitlePosition', 'centertop', ...
                'ForegroundColor', [0.85 0.85 0.92], ...
                'FontWeight', 'bold', ...
                'Visible', 'off', ...
                'Tag', 'xsec_panel');
            app.XSecAxes = uiaxes(app.XSecPanel, ...
                'Position', [10 38 w-20 h-78]);
            app.XSecAxes.XColor = 'none'; app.XSecAxes.YColor = 'none';
            app.XSecAxes.Color  = 'k';
            colormap(app.XSecAxes, gray);
            app.XSecLabel = uilabel(app.XSecPanel, ...
                'Position', [10 8 w-20 24], ...
                'Text', '(no centerline)', ...
                'FontColor', [0.95 0.85 0.30], 'FontSize', 11, ...
                'HorizontalAlignment','center');
        end

        function refreshXSec(app)
            % Recompute and draw the cross-section at the current
            % XSecArcMm position. Cheap (sub-100 ms even on the full
            % JohnDoe1 CT) so we just call this on every slider tick.
            ensureXSecPanel(app);
            if isempty(app.PolylineRight) || isempty(app.D) || ~isfield(app.D,'vol')
                app.XSecLabel.Text = '(centerline not yet computed)';
                return;
            end
            % Map arc mm → polyline node index
            sxy = mean(app.D.pixel_mm(1:2));
            arc_node = [0; cumsum(vecnorm( ...
                diff(app.PolylineRight,1,1) .* [sxy sxy app.D.slice_spacing_mm], ...
                2, 2))];
            target = max(0, min(arc_node(end), app.XSecArcMm));
            [~, k] = min(abs(arc_node - target));
            opts = struct( ...
                'pixel_mm',         app.D.pixel_mm, ...
                'slice_spacing_mm', app.D.slice_spacing_mm, ...
                'half_width_mm',    35, ...
                'step_mm',          0.4);
            try
                [img, info] = preprocess.orthogonal_slice( ...
                    app.D.vol, app.PolylineRight, k, opts);
            catch ME
                app.XSecLabel.Text = sprintf('error: %s', ME.message);
                return;
            end
            if isempty(app.XSecImage) || ~isvalid(app.XSecImage)
                app.XSecImage = imagesc(app.XSecAxes, ...
                    [-info.ext_mm info.ext_mm], [-info.ext_mm info.ext_mm], img);
                axis(app.XSecAxes, 'image'); axis(app.XSecAxes, 'off');
                hold(app.XSecAxes, 'on');
                % Plus-mark at lumen centre
                plot(app.XSecAxes, 0, 0, 'g+', 'MarkerSize', 14, ...
                    'LineWidth', 1.2, 'Tag', 'xsec_overlay');
            else
                app.XSecImage.CData = img;
            end
            W = app.WL(1); L = app.WL(2);
            clim(app.XSecAxes, [L - W/2, L + W/2]);
            % Status: arc + diameter
            if isnan(info.estimated_diameter_mm)
                d_txt = '—';
            else
                d_txt = sprintf('%.1f mm', info.estimated_diameter_mm);
            end
            app.XSecLabel.Text = sprintf('arc %.0f mm  ·  Ø %s', ...
                target, d_txt);
        end

        function onXSecScrub(app, evt)
            app.XSecArcMm = evt.Value;
            refreshXSec(app);
        end

        function ensureCPR(app)
            % Compute the CPR image lazily — reasonably fast (a few
            % hundred ms on the JohnDoe1 CT) but still worth caching so
            % toggling between CPR / MPR / Volume modes is instant.
            if ~isempty(app.CPRImage); return; end
            if isempty(app.PolylineRight); return; end
            opts = struct( ...
                'pixel_mm',         app.D.pixel_mm, ...
                'slice_spacing_mm', app.D.slice_spacing_mm, ...
                'lateral_mm',       40, ...
                'lateral_step_mm',  app.D.pixel_mm(2), ...
                'arc_step_mm',      app.D.slice_spacing_mm, ...
                'ray_dir',          [1 0 0]);
            try
                [img, meta] = preprocess.curved_planar_reformat( ...
                    app.D.vol, app.PolylineRight, opts);
                app.CPRImage = img;
                app.CPRMeta  = meta;
            catch ME
                warning('CPR generation failed: %s', ME.message);
                app.CPRImage = -1000 * ones(20, 20, 'single');
                app.CPRMeta  = struct();
            end
        end

        function updateSliderForView(app)
            if isempty(app.D) || ~isfield(app.D, 'vol')
                app.SliceSlider.Limits = [1 2];
                app.SliceSlider.Value  = 1;
                app.SliceSlider.Enable = 'off';
                return;
            end
            sz = size(app.D.vol);
            switch app.ViewMode
                case 'axial';    n = sz(3); v = app.IdxAxial;
                case 'coronal';  n = sz(1); v = app.IdxCoronal;
                case 'sagittal'; n = sz(2); v = app.IdxSagittal;
                case '3d';       n = 0;     v = 1;
                case 'cpr';      n = 0;     v = 1;
                otherwise;       n = 0;     v = 1;
            end
            if strcmp(app.ViewMode, '3d')
                app.SliceSlider.Enable = 'off';
                app.SliceSlider.Limits = [1 2];
                app.SliceSlider.Value  = 1;
                app.SliceSlider.ValueChangingFcn = @(s,evt) sliderMoved(app, evt);
            elseif strcmp(app.ViewMode, 'cpr')
                % Repurpose the slider as an arc-length scrubber. The
                % user drags it to walk through the vessel and the
                % cross-section pane updates live.
                if ~isempty(app.PolylineRight) && isfield(app.CPRMeta, 'arc_mm') && ~isempty(app.CPRMeta.arc_mm)
                    L = max(2, max(app.CPRMeta.arc_mm));
                    app.SliceSlider.Enable = 'on';
                    app.SliceSlider.Limits = [0 L];
                    app.SliceSlider.Value  = max(0, min(L, app.XSecArcMm));
                    app.SliceSlider.ValueChangingFcn = @(s,evt) onXSecScrub(app, evt);
                else
                    app.SliceSlider.Enable = 'off';
                    app.SliceSlider.Limits = [1 2];
                    app.SliceSlider.Value  = 1;
                    app.SliceSlider.ValueChangingFcn = @(s,evt) sliderMoved(app, evt);
                end
            else
                app.SliceSlider.Enable = 'on';
                app.SliceSlider.Limits = [1 max(2, n)];
                app.SliceSlider.Value  = max(1, min(n, v));
                app.SliceSlider.ValueChangingFcn = @(s,evt) sliderMoved(app, evt);
            end
        end

        function setWL(app, wl)
            app.WL = wl;
            refreshMain(app);
        end

        function sliderMoved(app, evt)
            v = round(evt.Value);
            switch app.ViewMode
                case 'axial';    app.IdxAxial    = v;
                case 'coronal';  app.IdxCoronal  = v;
                case 'sagittal'; app.IdxSagittal = v;
            end
            refreshMain(app);
        end

        % --- Main view rendering ------------------------------------
        function refreshMain(app)
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            if strcmp(app.ViewMode, '3dvol')
                refreshVolViewer(app);
                return;
            end
            if strcmp(app.ViewMode, '2x2')
                % 2x2 mode renders into MultiPanels, not MainAxes.
                % Calls into refreshMain (e.g. setWL) should redirect
                % to the multi-pane refresher.
                refreshMultiView(app);
                return;
            end
            sz = size(app.D.vol);
            % Build a display volume on demand: voxels in
            % DisplayExclusion are blanked to air HU so they vanish
            % from MPR slices and the MIP.
            vol = app.D.vol;
            apply_excl = ~isempty(app.DisplayExclusion) && ...
                         any(app.DisplayExclusion(:));

            switch app.ViewMode
                case 'axial'
                    img = extractSliceOrSlab(app, 'axial', app.IdxAxial);
                    if apply_excl
                        ex = app.DisplayExclusion(:, :, app.IdxAxial);
                        img(ex) = -1000;
                    end
                    m_act  = sliceMask(app.Mask,        app.IdxAxial, 'axial');
                    m_pend = sliceMask(app.PendingMask, app.IdxAxial, 'axial');
                    L_slice = labelSlice(app, app.IdxAxial, 'axial');
                    img_disp = compositeView(img, m_act, m_pend, app.WL, ...
                        app.InvertDisplay, L_slice, app.LabelColors);
                    app.SliceLabel.Text = sprintf('Axial   slice %d / %d%s', ...
                        app.IdxAxial, sz(3), slabSuffix(app));
                case 'coronal'
                    img = extractSliceOrSlab(app, 'coronal', app.IdxCoronal);
                    if apply_excl
                        ex = squeeze(app.DisplayExclusion(app.IdxCoronal, :, :)).';
                        img(ex) = -1000;
                    end
                    m_act  = sliceMask(app.Mask,        app.IdxCoronal, 'coronal');
                    m_pend = sliceMask(app.PendingMask, app.IdxCoronal, 'coronal');
                    L_slice = labelSlice(app, app.IdxCoronal, 'coronal');
                    img_disp = compositeView(img, m_act, m_pend, app.WL, ...
                        app.InvertDisplay, L_slice, app.LabelColors);
                    app.SliceLabel.Text = sprintf('Coronal   row %d / %d%s', ...
                        app.IdxCoronal, sz(1), slabSuffix(app));
                case 'sagittal'
                    img = extractSliceOrSlab(app, 'sagittal', app.IdxSagittal);
                    if apply_excl
                        ex = squeeze(app.DisplayExclusion(:, app.IdxSagittal, :)).';
                        img(ex) = -1000;
                    end
                    m_act  = sliceMask(app.Mask,        app.IdxSagittal, 'sagittal');
                    m_pend = sliceMask(app.PendingMask, app.IdxSagittal, 'sagittal');
                    L_slice = labelSlice(app, app.IdxSagittal, 'sagittal');
                    img_disp = compositeView(img, m_act, m_pend, app.WL, ...
                        app.InvertDisplay, L_slice, app.LabelColors);
                    app.SliceLabel.Text = sprintf('Sagittal   col %d / %d%s', ...
                        app.IdxSagittal, sz(2), slabSuffix(app));
                case '3d'
                    % Coronal MIP. Apply DisplayExclusion before the
                    % projection so excluded voxels don't dominate.
                    if apply_excl
                        v2 = vol; v2(app.DisplayExclusion) = -1000;
                        img = squeeze(max(v2, [], 1)).';
                    else
                        img = squeeze(max(vol, [], 1)).';
                    end
                    app.SliceLabel.Text = '3D MIP   coronal projection';
                    m_act = []; m_pend = [];
                    if any(app.Mask(:))
                        m_act = squeeze(max(app.Mask, [], 1)).';
                    end
                    if ~isempty(app.PendingMask) && any(app.PendingMask(:))
                        m_pend = squeeze(max(app.PendingMask, [], 1)).';
                    end
                    % Always go through compositeView so the WL drag
                    % drives the pixel display in MIP too — was a bug
                    % where MIP only used WL when a mask was present.
                    img_disp = compositeView(img, m_act, m_pend, app.WL, app.InvertDisplay);
                case 'cpr'
                    % Curved Planar Reformat — straightened vessel view.
                    % Cached on the app; recomputed only when the
                    % centerline changes. We TRANSPOSE for display so
                    % arc length runs along X (left → right) and the
                    % lateral axis is Y. This matches TeraRecon's
                    % straightened-view layout and fills wide panels.
                    if isempty(app.PolylineRight)
                        img_disp = compositeView( ...
                            -1000 * ones(20, 200, 'single'), [], [], app.WL, app.InvertDisplay);
                        app.SliceLabel.Text = 'CPR   (compute the centerline first — Step 4)';
                    else
                        ensureCPR(app);
                        % Apply current W/L to the cached CPR slab so
                        % the W/L drag controls the CPR display too.
                        img_disp = compositeView(app.CPRImage.', [], [], app.WL, app.InvertDisplay);
                        app.SliceLabel.Text = sprintf( ...
                            'CPR — straightened vessel (arc 0 → %.0f mm distal-to-proximal)', ...
                            max(app.CPRMeta.arc_mm));
                    end
            end

            if isempty(app.MainImage) || ~isvalid(app.MainImage)
                app.MainImage = imagesc(app.MainAxes, img_disp);
                app.MainAxes.XTick = []; app.MainAxes.YTick = [];
                app.MainImage.HitTest = 'on'; app.MainImage.PickableParts = 'all';
                app.MainImage.ButtonDownFcn = @(~,evt) onClick(app, evt);
            else
                app.MainImage.CData = img_disp;
            end
            % Image-aspect handling. Voxels in clinical CTA are
            % anisotropic (in-plane ~0.7 mm, slice ~0.5–1 mm) so
            % coronal / sagittal / coronal-MIP need an explicit
            % DataAspectRatio to keep anatomy in true proportion.
            % Aspect handling: keep anatomic aspect correct in EVERY
            % view via DataAspectRatio. The plot box mode is auto so
            % the box can grow to fill the panel as the user zooms.
            % zoomBy then reshapes XLim/YLim to the panel aspect (in
            % data units) so every zoom level has the visible region
            % filling the panel, with mm-per-pixel kept equal on X
            % and Y (so anatomy isn't distorted).
            sx = app.D.pixel_mm(2);                % column pixel size
            sy = app.D.pixel_mm(1);                % row pixel size
            sz_mm = app.D.slice_spacing_mm;        % slice spacing
            switch app.ViewMode
                case 'axial'
                    daspect(app.MainAxes, [sx sy 1]);
                case 'coronal'
                    daspect(app.MainAxes, [sx sz_mm 1]);
                    app.MainAxes.YDir = 'reverse';
                case 'sagittal'
                    daspect(app.MainAxes, [sy sz_mm 1]);
                    app.MainAxes.YDir = 'reverse';
                case '3d'
                    daspect(app.MainAxes, [sx sz_mm 1]);
                    app.MainAxes.YDir = 'reverse';
                case 'cpr'
                    daspect(app.MainAxes, [1 1 1]);
            end
            app.MainAxes.PlotBoxAspectRatioMode = 'auto';
            app.MainAxes.DataAspectRatioMode    = 'manual';
            % Initialize XLim/YLim to data extent only on the first
            % render of a view, on data load, or when the user
            % explicitly clicks Fit / Reset. Otherwise preserve the
            % user's manual zoom + pan state across slice scrolls.
            sz_img = size(img_disp);
            full_x = [0.5, sz_img(2) + 0.5];
            full_y = [0.5, sz_img(1) + 0.5];
            cur_x = app.MainAxes.XLim;
            cur_y = app.MainAxes.YLim;
            need_reset = app.NeedFitOnRefresh || ...
                         any(~isfinite(cur_x)) || any(~isfinite(cur_y));
            if need_reset
                app.MainAxes.XLim = full_x;
                app.MainAxes.YLim = full_y;
                app.NeedFitOnRefresh = false;
            end

            % CPR overlay — horizontal guide line at lat=0 (where the
            % lumen centerline sits) and arc-length tick marks every
            % 50 mm along the X axis.
            delete(findobj(app.MainAxes, 'Tag', 'cpr_overlay'));
            if strcmp(app.ViewMode, 'cpr') && ~isempty(app.CPRImage)
                hold(app.MainAxes, 'on');
                % After transpose: image is Nlat × Narc, displayed
                % with X = arc (cols) and Y = lat (rows).
                Narc = size(app.CPRImage, 1);     % was rows pre-transpose
                Nlat = size(app.CPRImage, 2);     % was cols pre-transpose
                cy = (Nlat + 1) / 2;              % row index of lat=0
                plot(app.MainAxes, [1 Narc], [cy cy], '-', ...
                    'Color', [0.20 0.95 0.20 0.7], 'LineWidth', 1.2, ...
                    'Tag', 'cpr_overlay');
                if isfield(app.CPRMeta, 'arc_mm') && ~isempty(app.CPRMeta.arc_mm)
                    arc = app.CPRMeta.arc_mm;
                    for s_mm = 0:50:max(arc)
                        [~, k] = min(abs(arc - s_mm));
                        plot(app.MainAxes, [k k], [Nlat-3 Nlat+1], '-', ...
                            'Color', [0.95 0.95 0.30], 'LineWidth', 1.5, ...
                            'Tag', 'cpr_overlay');
                        text(app.MainAxes, k, Nlat - 6, sprintf('%d', s_mm), ...
                            'Color', [0.95 0.95 0.30], 'FontSize', 9, ...
                            'HorizontalAlignment','center', ...
                            'Tag', 'cpr_overlay');
                    end
                    text(app.MainAxes, Narc, Nlat - 6, ' mm', ...
                        'Color', [0.95 0.95 0.30], 'FontSize', 9, ...
                        'HorizontalAlignment','left', 'Tag', 'cpr_overlay');
                end
                % Diameter overlay — shoot a ±r_max ray of inscribed
                % radius along the centerline (in mm) so users can see
                % stenoses / aneurysmal expansion at a glance.
                if ~isempty(app.R_vox_right) && isfield(app.CPRMeta, 'arc_mm')
                    arc_uniform = app.CPRMeta.arc_mm;
                    R_mm_path = preprocess.centerline_to_mm( ...
                        app.PolylineRight, app.R_vox_right, app.D);
                    arc_native = [0; cumsum(vecnorm(diff(R_mm_path,1,1),2,2))]; %#ok<NASGU>
                    % R_vox_right is per-node radius in voxel units;
                    % convert via mean in-plane spacing (matches the
                    % rest of the codebase).
                    sxy = mean(app.D.pixel_mm(1:2));
                    R_node_mm = app.R_vox_right * sxy;
                    arc_node  = [0; cumsum(vecnorm(diff(app.PolylineRight,1,1) .* [sxy sxy app.D.slice_spacing_mm], 2, 2))];
                    R_resamp  = interp1(arc_node, R_node_mm, arc_uniform, 'linear', 'extrap');
                    lat_step = mean(diff(app.CPRMeta.lat_mm));
                    R_pix = R_resamp / max(lat_step, eps);
                    lo = cy - R_pix;
                    hi = cy + R_pix;
                    plot(app.MainAxes, 1:Narc, lo, '-', ...
                        'Color', [1 0.4 0.2 0.9], 'LineWidth', 1.2, ...
                        'Tag', 'cpr_overlay');
                    plot(app.MainAxes, 1:Narc, hi, '-', ...
                        'Color', [1 0.4 0.2 0.9], 'LineWidth', 1.2, ...
                        'Tag', 'cpr_overlay');
                end
            end

            % Apply window/level. The user-selected WL applies to all
            % views including the MIP — pick "Wide MIP" from the Window
            % dropdown for the bone-tolerant version.
            if size(img_disp, 3) == 1
                W = app.WL(1); L = app.WL(2);
                clim(app.MainAxes, [L - W/2, L + W/2]);
            else
                clim(app.MainAxes, [0 1]);
            end

            drawSeedMarkersMain(app);
            drawCenterlineOverlay(app);
        end

        function drawSeedMarkersMain(app)
            delete(findobj(app.MainAxes, 'Tag', 'seed_marker'));
            % Color convention:
            %   green  = SeedProximal (suprarenal aorta — proximal seal)
            %   red    = SeedRightCFA (right common femoral artery)
            %   blue   = SeedLeftCFA  (left  common femoral artery)
            seed_specs = {
                app.PendingSeed,   [1.00 0.20 0.20], 14, 'o';
                app.SeedSeg,       [1.00 0.60 0.10],  9, 's';
                app.SeedProximal,  [0.10 0.85 0.10], 12, 'o';
                app.SeedRightCFA,  [0.95 0.20 0.20], 12, 'o';
                app.SeedLeftCFA,   [0.20 0.45 0.95], 12, 'o';
            };
            for s = 1:size(seed_specs, 1)
                seed = seed_specs{s, 1};
                col  = seed_specs{s, 2};
                msz  = seed_specs{s, 3};
                mkr  = seed_specs{s, 4};
                if isempty(seed); continue; end
                pt = projectSeed(app, seed);
                if isempty(pt); continue; end
                hold(app.MainAxes, 'on');
                plot(app.MainAxes, pt(1), pt(2), mkr, ...
                    'MarkerFaceColor', col, 'MarkerEdgeColor', 'k', ...
                    'MarkerSize', msz, 'Tag', 'seed_marker');
            end
            % Measurement overlay: draw any committed measurement
            % lines + the in-progress one onto this view. Solid
            % when in-plane, dashed when the segment is far from
            % the current slice plane.
            refreshMeasurementOverlay(app);
        end

        function pt = projectSeed(app, seed)
            % Returns 2D image-coords [x_img, y_img] of the seed in
            % the current view, or [] if the seed is not on the current
            % slice.
            pt = [];
            switch app.ViewMode
                case 'axial'
                    if abs(seed(3) - app.IdxAxial) < 1
                        pt = [seed(2), seed(1)];   % imagesc x=col, y=row
                    end
                case 'coronal'
                    if abs(seed(1) - app.IdxCoronal) < 1
                        pt = [seed(2), seed(3)];   % col, z (transposed)
                    end
                case 'sagittal'
                    if abs(seed(2) - app.IdxSagittal) < 1
                        pt = [seed(1), seed(3)];   % row, z
                    end
                case '3d'
                    pt = [seed(2), seed(3)];       % MIP — always show
            end
        end

        function drawCenterlineOverlay(app)
            delete(findobj(app.MainAxes, 'Tag', 'cl_line'));
            delete(findobj(app.MainAxes, 'Tag', 'cl_bifurc'));
            delete(findobj(app.MainAxes, 'Tag', 'cl_label'));
            % Plot the right (red) and left (blue) polylines together,
            % then a small magenta dot at the bifurcation node.
            specs = { ...
                app.PolylineRight, [0.95 0.20 0.20]; ...
                app.PolylineLeft,  [0.20 0.45 0.95]};
            for s = 1:size(specs, 1)
                P = specs{s, 1};
                col = specs{s, 2};
                if isempty(P); continue; end
                hold(app.MainAxes, 'on');
                switch app.ViewMode
                    case 'axial'
                        near = abs(P(:,3) - app.IdxAxial) < 2;
                        if any(near)
                            plot(app.MainAxes, P(near,2), P(near,1), '.', ...
                                'Color', col, 'MarkerSize', 8, ...
                                'Tag', 'cl_line');
                        end
                    case 'coronal'
                        plot(app.MainAxes, P(:,2), P(:,3), '-', ...
                            'Color', col, 'LineWidth', 1.5, 'Tag', 'cl_line');
                    case 'sagittal'
                        plot(app.MainAxes, P(:,1), P(:,3), '-', ...
                            'Color', col, 'LineWidth', 1.5, 'Tag', 'cl_line');
                    case '3d'
                        plot(app.MainAxes, P(:,2), P(:,3), '-', ...
                            'Color', col, 'LineWidth', 1.5, 'Tag', 'cl_line');
                end
            end
            % Bifurcation marker (right polyline, BifurcNodeIdx)
            if ~isempty(app.PolylineRight) && ~isempty(app.BifurcNodeIdx) && ...
                    app.BifurcNodeIdx >= 1 && app.BifurcNodeIdx <= size(app.PolylineRight, 1)
                B = app.PolylineRight(app.BifurcNodeIdx, :);
                hold(app.MainAxes, 'on');
                switch app.ViewMode
                    case 'axial'
                        if abs(B(3) - app.IdxAxial) < 2
                            plot(app.MainAxes, B(2), B(1), 'p', ...
                                'MarkerFaceColor', [0.95 0.10 0.95], ...
                                'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                                'Tag', 'cl_bifurc');
                        end
                    case 'coronal'
                        plot(app.MainAxes, B(2), B(3), 'p', ...
                            'MarkerFaceColor', [0.95 0.10 0.95], ...
                            'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                            'Tag', 'cl_bifurc');
                    case 'sagittal'
                        plot(app.MainAxes, B(1), B(3), 'p', ...
                            'MarkerFaceColor', [0.95 0.10 0.95], ...
                            'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                            'Tag', 'cl_bifurc');
                    case '3d'
                        plot(app.MainAxes, B(2), B(3), 'p', ...
                            'MarkerFaceColor', [0.95 0.10 0.95], ...
                            'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                            'Tag', 'cl_bifurc');
                end
            end

            % Anatomy text labels — show the named landmarks the user
            % has set in Step 5 so the centerline reads like a labelled
            % vascular roadmap (TeraRecon-style anatomy ID).
            lm = getappdata(app.UIFigure, 'landmarks');
            if isstruct(lm) && ~isempty(app.PolylineRight)
                pretty = struct( ...
                    'lowest_renal',     'lowest renal', ...
                    'aortic_bifurc',    'aortic bifurc', ...
                    'right_iliac',      'R iliac terminus', ...
                    'left_iliac',       'L iliac terminus', ...
                    'right_int_iliac',  'R IIA', ...
                    'left_int_iliac',   'L IIA', ...
                    'aneurysm_start',   'AAA proximal');
                fns = fieldnames(lm);
                for k = 1:numel(fns)
                    name = fns{k};
                    idx = lm.(name);
                    if isempty(idx) || any(isnan(idx)); continue; end
                    if startsWith(name, 'left_') && ~isempty(app.PolylineLeft) && ...
                            idx >= 1 && idx <= size(app.PolylineLeft, 1)
                        node = app.PolylineLeft(idx, :);
                    elseif idx >= 1 && idx <= size(app.PolylineRight, 1)
                        node = app.PolylineRight(idx, :);
                    else
                        continue;
                    end
                    if isfield(pretty, name); txt = pretty.(name);
                    else;                    txt = strrep(name, '_', ' ');
                    end
                    drawLabelOnView(app, node, txt);
                end
            end
        end

        function drawLabelOnView(app, node, txt)
            % Draw a small leader line + text label at the given
            % polyline node, in whichever 2D pane is active.
            switch app.ViewMode
                case 'axial'
                    if abs(node(3) - app.IdxAxial) < 2
                        plot(app.MainAxes, node(2)+10, node(1), 'o', ...
                            'MarkerSize', 4, 'MarkerFaceColor', [1 1 0.4], ...
                            'MarkerEdgeColor', 'k', 'Tag', 'cl_label');
                        text(app.MainAxes, node(2)+12, node(1), txt, ...
                            'Color', [1 1 0.4], 'FontSize', 9, ...
                            'BackgroundColor', [0 0 0 0.4], ...
                            'Margin', 1, 'Tag', 'cl_label');
                    end
                case {'coronal', '3d'}
                    text(app.MainAxes, node(2)+8, node(3), txt, ...
                        'Color', [1 1 0.4], 'FontSize', 9, ...
                        'BackgroundColor', [0 0 0 0.4], ...
                        'Margin', 1, 'Tag', 'cl_label');
                case 'sagittal'
                    text(app.MainAxes, node(1)+8, node(3), txt, ...
                        'Color', [1 1 0.4], 'FontSize', 9, ...
                        'BackgroundColor', [0 0 0 0.4], ...
                        'Margin', 1, 'Tag', 'cl_label');
            end
        end

        % --- 2x2 multi-pane centerline overlay --------------------
        function drawCenterlineOverlayMulti(app)
            % Mirror of drawCenterlineOverlay but drawing onto each
            % of the three 2-D panes in 2x2 mode. Each pane uses its
            % own slice-index window (axial filters by |z - IdxAxial|,
            % sagittal/coronal project the whole polyline since they
            % cut through the centerline naturally). The plotted lines
            % carry a ContextMenu hookup so right-click on a centerline
            % node opens the existing Insert/Delete/Move menu.
            if isempty(app.MultiAxes) || numel(app.MultiAxes) < 3; return; end
            ensureCenterlineCtxMenu(app);
            specs = { ...
                app.PolylineRight, [0.95 0.20 0.20], 'right'; ...
                app.PolylineLeft,  [0.20 0.45 0.95], 'left'};
            for k = 1:3
                ax = app.MultiAxes{k};
                if isempty(ax) || ~isvalid(ax); continue; end
                delete(findobj(ax, 'Tag', 'cl_line'));
                delete(findobj(ax, 'Tag', 'cl_bifurc'));
                delete(findobj(ax, 'Tag', 'cl_label'));
            end
            for s = 1:size(specs, 1)
                P    = specs{s, 1};
                col  = specs{s, 2};
                side = specs{s, 3};
                if isempty(P); continue; end
                % Axial pane (k=1): filter to slices near IdxAxial
                ax = app.MultiAxes{1};
                if ~isempty(ax) && isvalid(ax)
                    near = abs(P(:,3) - app.IdxAxial) < 3;
                    if any(near)
                        hold(ax, 'on');
                        h = plot(ax, P(near,2), P(near,1), '.', ...
                            'Color', col, 'MarkerSize', 9, ...
                            'Tag', 'cl_line', 'HitTest', 'on', ...
                            'PickableParts', 'all', ...
                            'UIContextMenu', app.ClContextMenu, ...
                            'ButtonDownFcn', @(src,evt) onCenterlinePick(app, evt, 'axial', side));
                        h.ContextMenu = app.ClContextMenu; %#ok<NASGU>
                    end
                end
                % Sagittal pane (k=2): X=row (P:,1), Y=z (P:,3)
                ax = app.MultiAxes{2};
                if ~isempty(ax) && isvalid(ax)
                    hold(ax, 'on');
                    h = plot(ax, P(:,1), P(:,3), '-', ...
                        'Color', col, 'LineWidth', 1.6, ...
                        'Tag', 'cl_line', 'HitTest', 'on', ...
                        'PickableParts', 'all', ...
                        'ButtonDownFcn', @(src,evt) onCenterlinePick(app, evt, 'sagittal', side));
                    h.ContextMenu = app.ClContextMenu;
                end
                % Coronal pane (k=3): X=col (P:,2), Y=z (P:,3)
                ax = app.MultiAxes{3};
                if ~isempty(ax) && isvalid(ax)
                    hold(ax, 'on');
                    h = plot(ax, P(:,2), P(:,3), '-', ...
                        'Color', col, 'LineWidth', 1.6, ...
                        'Tag', 'cl_line', 'HitTest', 'on', ...
                        'PickableParts', 'all', ...
                        'ButtonDownFcn', @(src,evt) onCenterlinePick(app, evt, 'coronal', side));
                    h.ContextMenu = app.ClContextMenu;
                end
            end
            % --- Bifurcation marker on each pane ------------------
            if ~isempty(app.PolylineRight) && ~isempty(app.BifurcNodeIdx) && ...
                    app.BifurcNodeIdx >= 1 && app.BifurcNodeIdx <= size(app.PolylineRight, 1)
                B = app.PolylineRight(app.BifurcNodeIdx, :);
                axA = app.MultiAxes{1};
                if ~isempty(axA) && isvalid(axA) && abs(B(3) - app.IdxAxial) < 3
                    hold(axA, 'on');
                    plot(axA, B(2), B(1), 'p', ...
                        'MarkerFaceColor', [0.95 0.10 0.95], ...
                        'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                        'Tag', 'cl_bifurc');
                end
                axS = app.MultiAxes{2};
                if ~isempty(axS) && isvalid(axS)
                    hold(axS, 'on');
                    plot(axS, B(1), B(3), 'p', ...
                        'MarkerFaceColor', [0.95 0.10 0.95], ...
                        'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                        'Tag', 'cl_bifurc');
                end
                axC = app.MultiAxes{3};
                if ~isempty(axC) && isvalid(axC)
                    hold(axC, 'on');
                    plot(axC, B(2), B(3), 'p', ...
                        'MarkerFaceColor', [0.95 0.10 0.95], ...
                        'MarkerEdgeColor', 'k', 'MarkerSize', 14, ...
                        'Tag', 'cl_bifurc');
                end
            end
        end

        function drawSeedMarkersMulti(app)
            % Show proximal/R-CFA/L-CFA seeds on each 2-D pane in 2x2.
            % Only on slices where the seed lives (axial filter); for
            % sagittal/coronal, draw if the seed's x/y is close to the
            % current slice index for that pane.
            if isempty(app.MultiAxes) || numel(app.MultiAxes) < 3; return; end
            specs = {
                app.SeedProximal,  [0.10 0.85 0.10];  % suprarenal — green
                app.SeedRightCFA,  [0.95 0.20 0.20];  % R-CFA     — red
                app.SeedLeftCFA,   [0.20 0.45 0.95];  % L-CFA     — blue
            };
            for k = 1:3
                ax = app.MultiAxes{k};
                if isempty(ax) || ~isvalid(ax); continue; end
                delete(findobj(ax, 'Tag', 'seed_marker'));
            end
            for s = 1:size(specs, 1)
                seed = specs{s, 1};
                col  = specs{s, 2};
                if isempty(seed); continue; end
                % Axial (k=1): show if seed z is on/near IdxAxial
                axA = app.MultiAxes{1};
                if ~isempty(axA) && isvalid(axA) && abs(seed(3) - app.IdxAxial) < 3
                    hold(axA, 'on');
                    plot(axA, seed(2), seed(1), 'o', ...
                        'MarkerFaceColor', col, 'MarkerEdgeColor', 'k', ...
                        'MarkerSize', 11, 'Tag', 'seed_marker');
                end
                % Sagittal (k=2): always show (sagittal sees the whole z)
                axS = app.MultiAxes{2};
                if ~isempty(axS) && isvalid(axS)
                    hold(axS, 'on');
                    plot(axS, seed(1), seed(3), 'o', ...
                        'MarkerFaceColor', col, 'MarkerEdgeColor', 'k', ...
                        'MarkerSize', 11, 'Tag', 'seed_marker');
                end
                % Coronal (k=3): always show
                axC = app.MultiAxes{3};
                if ~isempty(axC) && isvalid(axC)
                    hold(axC, 'on');
                    plot(axC, seed(2), seed(3), 'o', ...
                        'MarkerFaceColor', col, 'MarkerEdgeColor', 'k', ...
                        'MarkerSize', 11, 'Tag', 'seed_marker');
                end
            end
        end

        function onCenterlinePick(app, evt, pane_view, side)
            % Click on the centerline overlay in 2x2 mode. Left click:
            % treat as a normal MPR click (so linked crosshair etc.
            % still work). Right click: stash voxel + side and pop
            % the context menu — the UIContextMenu hookup gives the
            % right-click → menu mapping for free, but we still need
            % to capture the click voxel so editCenterline knows where
            % the user pointed.
            try; btn = evt.Button; catch; btn = 1; end
            try; ip = evt.IntersectionPoint; catch; ip = [0 0 0]; end
            ix = round(ip(1));
            iy = round(ip(2));
            switch pane_view
                case 'axial';    voxel = [iy, ix, app.IdxAxial];
                case 'coronal';  voxel = [app.IdxCoronal, ix, iy];
                case 'sagittal'; voxel = [ix, app.IdxSagittal, iy];
                otherwise; return;
            end
            sz = size(app.D.vol);
            voxel(1) = max(1, min(sz(1), voxel(1)));
            voxel(2) = max(1, min(sz(2), voxel(2)));
            voxel(3) = max(1, min(sz(3), voxel(3)));
            app.ClCtxClickVoxel = voxel;
            app.ClCtxClickSide  = side;
            if btn == 3
                % UIContextMenu fires automatically on right-click — no
                % need to call open() here. We just needed the voxel.
                return;
            end
            % Left click on the centerline → fall through to the
            % regular MPR-pane click pathway so linked crosshair still
            % works.
            onMultiPaneClick(app, evt, pane_view);
        end

        % --- Click dispatcher ---------------------------------------
        function onClick(app, evt)
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            % If a tool is armed (W/L drag, Pan drag), the
            % WindowButtonDown handler owns this click. Don't drop
            % seeds / landmarks while in tool mode.
            if app.WLArmed || app.PanArmed; return; end
            pt = evt.IntersectionPoint;
            ix = round(pt(1));
            iy = round(pt(2));
            switch app.ViewMode
                case 'axial';    voxel = [iy, ix, app.IdxAxial];
                case 'coronal';  voxel = [app.IdxCoronal, ix, iy];
                case 'sagittal'; voxel = [ix, app.IdxSagittal, iy];
                case 'cpr';      return;
                case '3d'
                    % Coronal-MIP click: pick the brightest voxel along
                    % the projection axis (Y) at the clicked column.
                    % Note `iy` here is actually the z-row of the MIP
                    % image (we transposed the projection), so we clamp
                    % it to the volume's z-range.
                    sz = size(app.D.vol);
                    [~, iy_best] = max(app.D.vol(:, ix, iy), [], 1);
                    voxel = [iy_best, ix, max(1, min(sz(3), iy))];
            end
            sz = size(app.D.vol);
            voxel(1) = max(1, min(sz(1), voxel(1)));
            voxel(2) = max(1, min(sz(2), voxel(2)));
            voxel(3) = max(1, min(sz(3), voxel(3)));

            % --- Vessel-pick mode → run region grow at this voxel
            % Same handling as 2x2 — single-view 2-D MPR (axial /
            % coronal / sagittal) clicks are reliable.
            if app.VesselPickArmed
                fprintf('[single-view click] view=%s voxel=[%d %d %d] HU=%d → vessel-select\n', ...
                    app.ViewMode, voxel, app.D.vol(voxel(1), voxel(2), voxel(3)));
                onVesselSelectClick(app, voxel);
                return;
            end
            % --- Measurement tool armed → drop a measurement point ---
            if ~isempty(app.MeasureMode)
                onMeasureClick(app, voxel);
                return;
            end
            % --- Drawing tool armed → drop / extend appropriately ---
            if ~isempty(app.DrawMode)
                onDrawClick(app, voxel, app.ViewMode);
                return;
            end

            % --- Right-click on the centerline → context menu --------
            % evt.Button: 1 = left, 2 = middle, 3 = right. The event
            % object isn't always a struct so we read defensively.
            btn = 1;
            try; btn = evt.Button; catch; end
            if btn == 3 && ~isempty(app.PolylineRight)
                ensureCenterlineCtxMenu(app);
                % Decide which side the click is closer to
                dR = min(vecnorm(app.PolylineRight - voxel, 2, 2));
                if isempty(app.PolylineLeft)
                    side = 'right';
                else
                    dL = min(vecnorm(app.PolylineLeft - voxel, 2, 2));
                    if dL < dR; side = 'left'; else; side = 'right'; end
                end
                app.ClCtxClickVoxel = voxel;
                app.ClCtxClickSide  = side;
                % Pop the context menu at the click position. uifigure
                % handles the menu via `open(menu, x, y)` at figure
                % pixel coordinates.
                fig_pt = app.UIFigure.CurrentPoint;
                open(app.ClContextMenu, fig_pt(1), fig_pt(2));
                return;
            end

            app.ClickLog(end+1) = struct('time', datetime('now'), ...
                'pane', app.ViewMode, 'voxel', voxel, 'step', app.Step);

            % Live shift modifier toggles shift-chain mode. The
            % side-panel toggle button is the sticky version; holding
            % Shift on click is the transient gesture (matches
            % TeraRecon).
            mods = app.UIFigure.CurrentModifier;
            shift_held = ~isempty(mods) && any(strcmp(mods, 'shift'));
            if shift_held && ~app.ShiftMode
                toggleShiftMode(app, true);
                btn = findobj(app.SideContent, 'Tag', 'shift_toggle');
                if ~isempty(btn) && isvalid(btn); btn.Value = true; end
            end

            switch app.Step
                case 2
                    if any(strcmp(app.Tool, {'brush', 'erase'}))
                        startPaintStroke(app, voxel);
                    else
                        onSegmentSeedClick(app, voxel);
                    end
                case 3
                    onEndpointClick(app, voxel);
                case 5
                    onLandmarkClick(app, voxel);
                otherwise
                    refreshMain(app);
            end
        end

        function onLandmarkClick(app, voxel)
            arm = getappdata(app.UIFigure, 'arm_landmark');
            if isempty(arm); return; end
            if isempty(app.PolylineRight); return; end
            % Snap the click to the nearest node on the relevant polyline.
            % Left-side landmarks (left_iliac, left_int_iliac) map to the
            % left polyline; everything else maps to the right (aorta).
            switch arm
                case {'left_iliac', 'left_int_iliac'}
                    P = app.PolylineLeft;
                otherwise
                    P = app.PolylineRight;
            end
            if isempty(P); return; end
            d = vecnorm(P - voxel, 2, 2);
            [~, idx] = min(d);
            lm = getappdata(app.UIFigure, 'landmarks');
            if ~isstruct(lm); lm = struct(); end
            lm.(arm) = idx;
            setappdata(app.UIFigure, 'landmarks', lm);
            setappdata(app.UIFigure, 'arm_landmark', '');

            stat = findobj(app.SideContent, 'Tag', 'arm_lm_status');
            if ~isempty(stat) && isvalid(stat); stat.Text = sprintf('  set %s at node %d', arm, idx); end

            ta = findobj(app.SideContent, 'Tag', 'meas_text');
            if ~isempty(ta) && isvalid(ta); ta.Value = evarMeasurementsText(app); end
            refreshMain(app);
        end

        % --- Step 1: Load CT ----------------------------------------
        function buildStep1(app)
            app.SideStepLabel.Text = 'Step 1 — Load CT';
            clearSideContent(app);

            % Mode toggle at the top.
            y = app.step_mode_toggle_render(1, 970);

            % Section header with ⓘ
            y = ui_helpers.section_header(app.SideContent, y, ...
                'Step 1 — Load CT', [0.20 0.20 0.55], ...
                'step1.overview', app.UIFigure);

            if strcmp(app.StepModes.step1, 'auto')
                buildStep1_auto(app, y);
            else
                buildStep1_user(app, y);
            end
        end

        function buildStep1_user(app, y_top)
            sc = app.SideContent;
            y = y_top;

            uilabel(sc, 'Position', [10 y-60 360 60], ...
                'WordWrap','on', ...
                'Text', ['Load a CT angiogram. Choose a folder of DICOM ' ...
                         'slices, a NIfTI file, a cached .mat, or a ' ...
                         'synthetic phantom from the library to practice on.'], ...
                'FontSize', 12);
            y = y - 60 - 10;

            uibutton(sc, 'push', ...
                'Position', [10 y-40 360 40], 'Text', 'Open DICOM folder…', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~,~) openDicomFolder(app));
            y = y - 40 - 8;
            uibutton(sc, 'push', ...
                'Position', [10 y-40 360 40], 'Text', 'Open NIfTI file…', ...
                'FontSize', 13, ...
                'ButtonPushedFcn', @(~,~) openNifti(app));
            y = y - 40 - 8;
            uibutton(sc, 'push', ...
                'Position', [10 y-40 360 40], 'Text', 'Open cached CT (.mat)…', ...
                'FontSize', 13, ...
                'ButtonPushedFcn', @(~,~) openCached(app));
            y = y - 40 - 8;
            % Phantom row: button + info
            uibutton(sc, 'push', ...
                'Position', [10 y-40 336 40], ...
                'Text', '🩻 Open phantom from library…', ...
                'FontSize', 13, ...
                'BackgroundColor', [0.92 0.97 1.0], ...
                'ButtonPushedFcn', @(~,~) openPhantom(app));
            ui_helpers.info_button(sc, [350 y-30 20 20], 'step1.phantom', app.UIFigure);
            y = y - 40 - 8;

            recents = readRecentFiles(app);
            if ~isempty(recents)
                uibutton(sc, 'push', ...
                    'Position', [10 y-32 336 32], ...
                    'Text', sprintf('Open recent (%d) …', numel(recents)), ...
                    'FontSize', 12, ...
                    'BackgroundColor', [0.96 0.96 0.99], ...
                    'ButtonPushedFcn', @(~,~) openRecent(app));
                ui_helpers.info_button(sc, [350 y-26 20 20], 'step1.recent', app.UIFigure);
                y = y - 32 - 8;
            end

            uilabel(sc, 'Position', [10 y-60 360 60], ...
                'Tag', 'load_status', 'Text', '(no volume loaded)', ...
                'FontColor', [0.4 0.4 0.4], 'WordWrap', 'on');
        end

        function buildStep1_auto(app, y_top)
            sc = app.SideContent;
            y = y_top;
            uilabel(sc, 'Position', [10 y-50 360 50], ...
                'WordWrap', 'on', ...
                'Text', ['Automatic mode reopens the most-recent case from your ' ...
                         'recent-files list. If no recents are available, falls ' ...
                         'back to the first phantom.'], ...
                'FontSize', 12);
            y = y - 50 - 10;
            uibutton(sc, 'push', ...
                'Position', [10 y-44 360 44], ...
                'Text', '⚡ Open most-recent case', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'ButtonPushedFcn', @(~,~) openMostRecentOrPhantom(app));
            y = y - 44 - 10;
            uilabel(sc, 'Position', [10 y-60 360 60], ...
                'Tag', 'load_status', 'Text', '(no volume loaded)', ...
                'FontColor', [0.4 0.4 0.4], 'WordWrap', 'on');
        end

        function openMostRecentOrPhantom(app)
            recents = readRecentFiles(app);
            if ~isempty(recents)
                r = recents(1);
                try
                    switch r.kind
                        case 'dicom';   doLoad(app, @() preprocess.dicom_load(r.path, true));
                        case 'nifti';   doLoad(app, @() loadNifti(r.path));
                        case 'cached';  doLoad(app, @() loadCached(r.path));
                        case 'phantom'; doLoad(app, @() loadPhantom(r.path));
                    end
                    return;
                catch ME
                    uialert(app.UIFigure, ...
                        sprintf('Could not reopen recent case (%s): %s', r.label, ME.message), ...
                        'Auto-load failed');
                end
            end
            % Fall back to first phantom
            here = fileparts(fileparts(which('app.AorticCenterlineApp')));
            files = dir(fullfile(here, 'library', 'PHANTOM_*.mat'));
            if isempty(files)
                uialert(app.UIFigure, ...
                    'No recent cases and no phantoms found. Switch to User-driven mode.', ...
                    'Nothing to auto-load');
                return;
            end
            full = fullfile(files(1).folder, files(1).name);
            doLoad(app, @() loadPhantom(full));
            pushRecentFile(app, full, 'phantom', files(1).name);
        end

        function y_below = step_mode_toggle_render(app, step_num, y_top)
            % Render the mode toggle for `step_num` and wire its callback
            % so changing the mode re-renders that step.
            key = sprintf('step%d', step_num);
            current = app.StepModes.(key);
            y_below = ui_helpers.step_mode_toggle( ...
                app.SideContent, y_top, current, ...
                @(new_mode) onStepModeChanged(app, step_num, new_mode), ...
                app.UIFigure);
        end

        function onStepModeChanged(app, step_num, new_mode)
            key = sprintf('step%d', step_num);
            app.StepModes.(key) = new_mode;
            persistStepModes(app);
            updateStep(app, step_num);
        end

        function persistStepModes(app)
            % Save the current StepModes struct to the per-user prefs
            % file. Merges with whatever else is in there (first-launch
            % flag, etc.) instead of clobbering.
            try
                prefs = ui_helpers.load_user_prefs();
                prefs.step_modes = app.StepModes;
                ui_helpers.save_user_prefs(prefs);
            catch ME
                fprintf('[persistStepModes] %s\n', ME.message);
            end
        end

        function hydrateStepModesFromDisk(app)
            % Load the persisted toggle state on app construction.
            % Falls back to defaults silently if the file is missing.
            try
                prefs = ui_helpers.load_user_prefs();
                if isfield(prefs, 'step_modes') && isstruct(prefs.step_modes)
                    sm = prefs.step_modes;
                    for k = 1:6
                        key = sprintf('step%d', k);
                        if isfield(sm, key) && any(strcmp(sm.(key), {'user', 'auto'}))
                            app.StepModes.(key) = sm.(key);
                        end
                    end
                end
            catch ME
                fprintf('[hydrateStepModesFromDisk] %s\n', ME.message);
            end
        end

        function openDicomFolder(app)
            folder = uigetdir(pwd, 'Select DICOM folder');
            if folder == 0; return; end
            [~, lab] = fileparts(folder);
            doLoad(app, @() preprocess.dicom_load(folder, true));
            pushRecentFile(app, folder, 'dicom', lab);
        end

        function openNifti(app)
            % Read a single .nii / .nii.gz volume via the built-in
            % niftiread + niftiinfo, then assemble a D struct that
            % matches preprocess.dicom_load's contract.
            [name, path] = uigetfile({'*.nii;*.nii.gz', 'NIfTI volume'}, ...
                'Select NIfTI volume');
            if name == 0; return; end
            full = fullfile(path, name);
            doLoad(app, @() loadNifti(full));
            pushRecentFile(app, full, 'nifti', name);
        end

        function openCached(app)
            [name, path] = uigetfile({'*.mat', 'Cached CT'}, 'Select cached .mat');
            if name == 0; return; end
            full = fullfile(path, name);
            doLoad(app, @() loadCached(full));
            pushRecentFile(app, full, 'cached', name);
        end

        function openPhantom(app)
            % List the phantoms baked into +library/
            here = fileparts(fileparts(which('app.AorticCenterlineApp')));
            lib_root = fullfile(here, 'library');
            files = dir(fullfile(lib_root, 'PHANTOM_*.mat'));
            if isempty(files)
                uialert(app.UIFigure, ...
                    sprintf(['No phantom .mat files found in:\n%s\n\n' ...
                            'Run phantom.build_normal_male / build_aaa_male ' ...
                            'to seed the library.'], lib_root), ...
                    'No phantoms');
                return;
            end
            choices = {files.name};
            [idx, ok] = listdlg('PromptString', ...
                {'Pick a phantom case to load.', ...
                 'Labels (mask/centerline/seeds) are stripped so you can', ...
                 'work it from scratch — open the original .mat to compare.'}, ...
                'ListString', choices, ...
                'SelectionMode', 'single', ...
                'ListSize', [380 160]);
            if ~ok; return; end
            full = fullfile(lib_root, choices{idx});
            doLoad(app, @() loadPhantom(full));
            pushRecentFile(app, full, 'phantom', choices{idx});
        end

        function doLoad(app, loader_fn)
            d = uiprogressdlg(app.UIFigure, 'Title', 'Loading…', 'Indeterminate', 'on');
            try
                D_loaded = loader_fn();
            catch ME
                close(d);
                uialert(app.UIFigure, ME.message, 'Load failed');
                return;
            end
            % Normalise Z orientation. The display convention is z=1 →
            % most superior slice (head end), so axial slice 1 shows
            % anatomy near the head and the 3-D rendering puts the
            % pelvis at the bottom of the screen. DICOM scanners often
            % save with z=1 at the inferior end (feet first); detect
            % via slice_z_mm direction and flip if so. Synthetic phantoms
            % set D.z_normalized = true to opt out.
            if isfield(D_loaded, 'is_volume') && D_loaded.is_volume && ...
               (~isfield(D_loaded, 'z_normalized') || ~D_loaded.z_normalized) && ...
               isfield(D_loaded, 'slice_z_mm') && numel(D_loaded.slice_z_mm) > 1 && ...
               D_loaded.slice_z_mm(1) < D_loaded.slice_z_mm(end)
                D_loaded.vol = flip(D_loaded.vol, 3);
                D_loaded.slice_z_mm = flipud(D_loaded.slice_z_mm(:));
                D_loaded.z_normalized = true;
            end
            app.D = D_loaded;
            % Reset every per-case working state so a re-load doesn't
            % carry the previous case's mask / seeds / centerlines.
            sz = size(app.D.vol);
            app.Mask              = false(sz);
            app.MaskLabel         = zeros(sz, 'uint8');
            app.NextSegLabel      = 1;
            app.PendingMask       = false(sz);
            app.DisplayExclusion  = false(sz);
            app.SeedSeg           = [];
            app.SeedSegList       = {};
            app.SeedProximal      = [];
            app.SeedRightCFA      = [];
            app.SeedLeftCFA       = [];
            app.PolylineRight     = [];
            app.R_vox_right       = [];
            app.PolylineLeft      = [];
            app.R_vox_left        = [];
            app.BifurcNodeIdx     = [];
            app.Polyline          = [];
            app.R_vox             = [];
            app.UndoStack         = {};
            app.UndoIndex         = 0;
            app.CPRImage          = [];
            app.CPRMeta           = struct();
            setappdata(app.UIFigure, 'landmarks', struct());
            setappdata(app.UIFigure, 'arm_seed', '');
            setappdata(app.UIFigure, 'arm_landmark', '');

            close(d);
            app.NeedFitOnRefresh = true;
            initVolumeView(app);
            stat = findobj(app.SideContent, 'Tag', 'load_status');
            if ~isempty(stat) && isvalid(stat)
                % Build a multi-line, clinically-useful summary instead
                % of "256 × 256 × 610 | Aorta 0.75 Br36 3". Skip PHI
                % (patient name / ID / DOB) — only show acquisition
                % geometry and series info.
                px = app.D.pixel_mm;
                if numel(px) < 2; px = [px(1) px(1)]; end
                fov_x = sz(2) * px(2) / 10;   % cm
                fov_y = sz(1) * px(1) / 10;
                lines = {
                    sprintf('Loaded: %d × %d × %d voxels', sz(1), sz(2), sz(3));
                    sprintf('Voxel: %.2f × %.2f mm in-plane,  %.2f mm slice', ...
                        px(1), px(2), app.D.slice_spacing_mm);
                    sprintf('FOV: %.1f × %.1f cm,  %.1f cm Z extent', ...
                        fov_y, fov_x, sz(3) * app.D.slice_spacing_mm / 10);
                };
                if isfield(app.D, 'series_description') && ...
                        ~isempty(app.D.series_description)
                    lines{end+1} = sprintf('Series: %s', app.D.series_description); %#ok<AGROW>
                end
                stat.Text = strjoin(lines, newline);
                stat.FontColor = [0 0.4 0];
                stat.Position(4) = 80;   % grow vertical room for 4 lines
            end

            % End of Step 1 (Load CT): show the 3-D recon in AP view of
            % the whole CT — no segmentation, no cropping, no step
            % advance. Step 2 (Segment vessels) is where the mask is
            % built; it keeps the same camera + colormap and only
            % excludes the non-vessel voxels.
        end

        function initVolumeView(app)
            sz = size(app.D.vol);
            app.IdxAxial    = round(sz(3)/2);
            app.IdxCoronal  = round(sz(1)/2);
            app.IdxSagittal = round(sz(2)/2);
            % Force re-create the image so the click handler binds
            if ~isempty(app.MainImage) && isvalid(app.MainImage)
                delete(app.MainImage);
                app.MainImage = matlab.graphics.primitive.Image.empty;
            end
            % Default to the 3D Volume render with the CTA Recon
            % transfer function — whole-body AP view, vessels in
            % red-orange and bone in yellow-white, exactly what
            % TeraRecon shows when you first open a CTA. Step 2
            % (Segment vessels) will keep this same camera and
            % colormap and just exclude the non-vessel voxels, so the
            % "before" and "after" views are visually consistent.
            app.VolStyle = 'cta_recon';
            if ~isempty(app.VolStyleDropdown) && isvalid(app.VolStyleDropdown)
                app.VolStyleDropdown.Value = 'cta_recon';
            end
            setViewMode(app, '3dvol');
        end

        % --- Step 2: Segment aorta ----------------------------------
        function buildStep2(app)
            app.SideStepLabel.Text = 'Step 2 — Segment aorta';
            clearSideContent(app);
            if strcmp(app.StepModes.step2, 'auto')
                buildStep2_auto(app);
            else
                renderClickToAddUI(app);
            end
        end

        function buildStep2_auto(app)
            sc = app.SideContent;
            y = app.step_mode_toggle_render(2, 970);
            y = ui_helpers.section_header(sc, y, ...
                'Step 2 — Segment aorta + iliacs + CFAs + branches', ...
                [0.20 0.40 0.75], 'step2.overview', app.UIFigure);

            uilabel(sc, 'Position', [10 y-90 360 90], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Automatic mode runs the full Step-2 pipeline in one click:', newline, ...
                         '  1. TotalSegmentator on aorta + bilateral iliacs', newline, ...
                         '  2. Branch extension (celiac, SMA, renals) with SMA + renal-L fallbacks', newline, ...
                         '  3. CFA extension — slice-by-slice walk to the FOV bottom on both sides', newline, ...
                         '  4. Supraceliac crop at 5 cm above the celiac', newline, ...
                         '  5. 6-block anatomic audit']);
            y = y - 90 - 10;

            ts_avail = autoseg.detect();

            % One-click full pipeline: CT -> segmentation+branches ->
            % seeds -> bifurcated centerline, via the proven headless
            % engine. This is the reliable path; the individual buttons
            % below remain for step-by-step control / refinement.
            uibutton(sc, 'push', 'Position', [10 y-54 336 54], ...
                'Text', '⚡  Auto-run full pipeline  (CT → centerline)', ...
                'FontSize', 14, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.10 0.45 0.85], 'FontColor', [1 1 1], ...
                'Enable', boolEnable(ts_avail.available), ...
                'ButtonPushedFcn', @(~,~) runAutoPipeline(app));
            y = y - 54 - 6;
            uilabel(sc, 'Position', [10 y-16 360 16], ...
                'Text', 'Segments, seeds, and computes the centerline in one step.', ...
                'FontSize', 10, 'FontColor', [0.35 0.35 0.35]);
            y = y - 16 - 12;

            uibutton(sc, 'push', 'Position', [10 y-48 336 48], ...
                'Text', 'Run segmentation only', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.30 0.65 1.00], 'FontColor', [1 1 1], ...
                'Enable', boolEnable(ts_avail.available), ...
                'ButtonPushedFcn', @(~,~) runAutoSeg(app));
            ui_helpers.info_button(sc, [350 y-38 20 20], 'step2.autoseg', app.UIFigure);
            y = y - 48 - 10;

            if ts_avail.available
                msg = '✓ TotalSegmentator ready';
                col = [0 0.4 0];
            else
                msg = 'TotalSegmentator not on PATH — switch to User-driven mode and use the guided 5-click flow, or see SETUP.md to install TS.';
                col = [0.55 0.30 0];
            end
            uilabel(sc, 'Position', [10 y-44 360 44], ...
                'Tag', 'ts_status', 'Text', msg, ...
                'FontSize', 11, 'FontColor', col, 'WordWrap', 'on');
            y = y - 44 - 18;

            if ~isempty(app.Mask) && isfield(app.D, 'pixel_mm')
                mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                     app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
                seg_text = sprintf('Segmented %.1f mL', mL);
            else
                seg_text = '(no segmentation yet)';
            end
            uilabel(sc, 'Position', [10 y-24 360 24], ...
                'Tag', 'seg_status', ...
                'Text', seg_text, ...
                'FontSize', 12, 'FontColor', [0 0.4 0], 'WordWrap', 'on');
            y = y - 24 - 12;

            uibutton(sc, 'push', 'Position', [10 y-44 360 44], ...
                'Text', '✓ Done — go to Step 3', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) finishStep2(app));
        end

        function renderClickToAddUI(app)
            % The Step 2 panel is organized top-down: shift-click
            % hint, Auto-segment (TotalSegmentator), Display tools,
            % Segment vessels (HU tuning), Manual edit
            % (brush/erase/undo). Scrollable so 13" screens can still
            % reach the Done button at the bottom.
            %
            % Layout convention used throughout this function:
            %   `top_y` = y-coordinate where the NEXT element's
            %   TOP should sit. After placing an element of height
            %   H, decrement `top_y` by (H + GAP_AFTER).  The
            %   internal `place` lambda hides this so the caller
            %   only writes the per-element height.
            sc  = app.SideContent;
            % CRITICAL: clear prior children before re-rendering, else
            % each call stacks new widgets on top of old ones and the
            % panel becomes an unreadable mess. (Used to leak when
            % guided flow re-rendered the panel after each click.)
            delete(allchild(sc));
            % Place content top-down starting at a large y so the
            % bottom-most element ends in positive y.
            top = 1000;
            GAP = 8;
            SECTION_GAP = 20;

            % Mode toggle at the very top so the user can flip to the
            % automatic one-button flow without leaving Step 2.
            top = app.step_mode_toggle_render(2, top);
            top = ui_helpers.section_header(sc, top, ...
                'Step 2 — Segment (User-driven)', [0.20 0.40 0.75], ...
                'step2.overview', app.UIFigure);
            top = top - GAP;

            % ---------- Section: Auto-segment (PRIMARY) -------------------
            ts_avail = autoseg.detect();
            top = sectionHdr(app, sc, top, '⚡ Auto-segment', ...
                [0.20 0.40 0.75], 'step2.autoseg');
            h = 44;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'WordWrap', 'on', 'FontSize', 11, ...
                'FontColor', [0.30 0.30 0.30], ...
                'Text', ['One-click TotalSegmentator. Runs in 1–2 min, ' ...
                         'gives aorta + iliacs cleanly. Refine with the ' ...
                         '5-click landmark flow or manual clicks below.']);
            top = top - h - GAP;
            h = 24;
            cb_aorta = uicheckbox(sc, 'Position', [10  top-h 180 h], ...
                'Text', 'aorta',       'Value', true,  'Tag', 'ts_target_aorta');
            cb_il_l  = uicheckbox(sc, 'Position', [200 top-h 180 h], ...
                'Text', 'iliac artery (L)', 'Value', true, ...
                'Tag', 'ts_target_iliac_artery_left');
            top = top - h - 4;
            cb_il_r  = uicheckbox(sc, 'Position', [10  top-h 180 h], ...
                'Text', 'iliac artery (R)', 'Value', true, ...
                'Tag', 'ts_target_iliac_artery_right');
            cb_il_v  = uicheckbox(sc, 'Position', [200 top-h 180 h], ...
                'Text', 'iliac vein (skip)', 'Value', false, ...
                'Tag', 'ts_target_iliac_vena');
            top = top - h - GAP;
            % Big primary auto-segment button
            h = 44;
            ts_btn = uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                'Text', '⚡ Run auto-segment (1–2 min)', ...
                'FontSize', 14, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.30 0.65 1.00], ...
                'FontColor', [1 1 1], ...
                'Enable', boolEnable(ts_avail.available), ...
                'ButtonPushedFcn', @(~,~) runAutoSeg(app));
            top = top - h - GAP;
            if ts_avail.available
                msg = '✓ TotalSegmentator ready';
                col = [0 0.4 0];
            else
                msg = 'TotalSegmentator not on PATH — see SETUP.md to install.';
                col = [0.55 0.30 0];
                ts_btn.Tooltip = ts_avail.error;
            end
            h = 20;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Tag', 'ts_status', 'Text', msg, 'FontSize', 11, ...
                'FontColor', col, 'WordWrap', 'on');
            top = top - h - SECTION_GAP;
            cb_aorta.Visible='on'; cb_il_l.Visible='on'; %#ok<NASGU>
            cb_il_r.Visible='on'; cb_il_v.Visible='on';  %#ok<NASGU>

            % ---------- Section: Guided 5-click workflow ---------------
            % Slim section: just a description + a Start button. The
            % step-by-step prompts pop up as a big banner overlay on
            % the recon (refreshGuidedBanner) so the user doesn't
            % have to read tiny side-panel text.
            top = sectionHdr(app, sc, top, ...
                'Confirm landmarks (5 clicks)', [0.55 0.30 0.55], ...
                'step2.guided');
            h = 32;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'WordWrap', 'on', 'FontSize', 11, ...
                'Text', ['Step through aorta → renals → CFAs. A big ' ...
                         'on-screen banner will tell you which to click.']);
            top = top - h - GAP;
            h = 40;
            if app.GuidedStep == 0
                uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                    'Text', '▶ Start guided segmentation (5 clicks)', ...
                    'FontSize', 13, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0.85 0.78 0.95], ...
                    'ButtonPushedFcn', @(~,~) startGuidedFlow(app));
            elseif app.GuidedStep == 6
                uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                    'Text', '✓ Restart guided flow', ...
                    'FontSize', 13, 'BackgroundColor', [0.80 0.95 0.80], ...
                    'ButtonPushedFcn', @(~,~) startGuidedFlow(app));
            else
                uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                    'Text', sprintf('In progress — step %d/5  (cancel via banner)', app.GuidedStep), ...
                    'FontSize', 12, 'FontWeight', 'bold', ...
                    'BackgroundColor', [0.94 0.94 0.97], ...
                    'FontColor', [0.30 0.30 0.55], ...
                    'Enable', 'off');
            end
            top = top - h - SECTION_GAP;

            % ---------- Section: Manual refinement (SECONDARY) ---------
            top = sectionHdr(app, sc, top, ...
                'Manual refine (click on 2-D MPR panes)', [0.50 0.40 0.20], ...
                'step2.manual_click');
            h = 36;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'WordWrap', 'on', 'FontSize', 11, ...
                'Text', ['Switch the toolbar to "2x2 multi-pane", click ' ...
                         '"🎯 Pick vessel mode" below, then click each ' ...
                         'vessel on the AXIAL/CORONAL/SAGITTAL panes — ' ...
                         'these have reliable click handling.']);
            top = top - h - 4;
            h = 32;
            tg = uibutton(sc, 'state', ...
                'Position', [10 top-h 360 h], ...
                'Text', '🎯 Pick vessel mode (manual refine)', ...
                'FontSize', 11, 'FontWeight', 'bold', ...
                'Value', app.VesselPickArmed, ...
                'BackgroundColor', [0.95 0.92 0.80], ...
                'ValueChangedFcn', @(b,~) toggleVesselPickArmed(app, b.Value));
            tg.Tag = 'pick_vessel_toggle'; %#ok<NASGU>
            top = top - h - SECTION_GAP;

            % ---------- Section: Display ------------------------------
            top = sectionHdr(app, sc, top, 'Display tools', [0.20 0.20 0.55], 'step2.display_tools');
            h = 32;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'WordWrap', 'on', 'FontSize', 11, ...
                'Text', ['Hide ribs / EKG leads / table from the recon. ' ...
                         'Removed voxels are blocked from segmentation.']);
            top = top - h - GAP;
            h = 30;
            uibutton(sc, 'push', 'Position', [10  top-h 175 h], ...
                'Text', '✂ Scalpel — draw region', 'FontSize', 11, ...
                'BackgroundColor', [0.95 0.92 0.80], ...
                'ButtonPushedFcn', @(~,~) armScalpel(app));
            uibutton(sc, 'push', 'Position', [195 top-h 175 h], ...
                'Text', 'Remove bone (HU>600)', 'FontSize', 11, ...
                'BackgroundColor', [0.95 0.92 0.80], ...
                'ButtonPushedFcn', @(~,~) removeBoneFromDisplay(app));
            top = top - h - GAP;
            h = 28;
            uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                'Text', 'Reset display (show all voxels)', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) resetDisplayExclusion(app));
            top = top - h - GAP;
            h = 20;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Tag', 'disp_status', 'Text', '', 'FontSize', 11, ...
                'WordWrap', 'on', 'FontColor', [0.4 0.4 0.4]);
            top = top - h - SECTION_GAP;

            % ---------- Section: Segment vessels (HU tuning) ----------
            top = sectionHdr(app, sc, top, 'Segment vessels', [0.10 0.45 0.20], 'step2.hu_sliders');
            h = 32;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'WordWrap', 'on', 'FontSize', 11, ...
                'Text', ['Tighten HU range if a click leaks into bone ' ...
                         'or veins; widen it if a contrast vessel ' ...
                         'doesn''t come through.']);
            top = top - h - GAP;
            h = 20;
            uilabel(sc, 'Position', [10 top-h 360 h], 'Tag', 'hu_label', ...
                'Text', sprintf('HU range: %d – %d', app.HU_min, app.HU_max), ...
                'FontSize', 11);
            top = top - h - 6;
            % Sliders are 3-px tall but visually need ~22 px of room
            sl_lo = uislider(sc, 'Position', [10 top-3 360 3], ...
                'Limits', [0 400], 'Value', app.HU_min, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(~,e) huMinChanged(app, e));
            sl_lo.Tag = 'hu_min_slider';
            top = top - 24;
            sl_hi = uislider(sc, 'Position', [10 top-3 360 3], ...
                'Limits', [200 1200], 'Value', app.HU_max, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(~,e) huMaxChanged(app, e));
            sl_hi.Tag = 'hu_max_slider';
            top = top - 24;
            % --- Grow size scrollback (TeraRecon-style) ---
            % After every click the grow runs unconstrained; this
            % slider thresholds geodesic distance from the seed,
            % shrinking (left) or expanding (right) the visible
            % grow without re-running anything.
            h = 20;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Text', 'Grow size — drag LEFT to shrink the last click', ...
                'FontSize', 11, 'FontWeight', 'bold');
            top = top - h - 4;
            sl_g = uislider(sc, 'Position', [10 top-3 360 3], ...
                'Limits', [0 1], 'Value', 1, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(~,e) setGrowSliderValue(app, e.Value));
            sl_g.Tag = 'grow_slider'; %#ok<NASGU>
            top = top - 24;
            % Undo last whole click + Cancel current click
            h = 30;
            uibutton(sc, 'push', 'Position', [10  top-h 175 h], ...
                'Text', '↶ Undo last click', 'FontSize', 11, ...
                'BackgroundColor', [0.97 0.92 0.85], ...
                'Tooltip', 'Roll back the most recent click entirely.', ...
                'ButtonPushedFcn', @(~,~) cancelLastClick(app));
            uibutton(sc, 'push', 'Position', [195 top-h 175 h], ...
                'Text', '🗑 Reset all', 'FontSize', 11, ...
                'BackgroundColor', [0.97 0.85 0.85], ...
                'Tooltip', 'Discard the entire segmentation.', ...
                'ButtonPushedFcn', @(~,~) clearMask(app));
            top = top - h - SECTION_GAP;

            % ---------- Section: Manual edit --------------------------
            top = sectionHdr(app, sc, top, 'Manual edit', [0.45 0.20 0.45], 'step2.brush');
            h = 36;
            grp = uibuttongroup(sc, 'Position', [10 top-h 360 h], ...
                'BorderType', 'none', 'BackgroundColor', 'w', ...
                'SelectionChangedFcn', @(g,e) toolChanged(app, e.NewValue.Text));
            uitogglebutton(grp, 'Position', [0   2 110 32], 'Text', 'Click', ...
                'Value', strcmp(app.Tool, 'click'), 'FontSize', 11);
            uitogglebutton(grp, 'Position', [120 2 110 32], 'Text', 'Brush', ...
                'Value', strcmp(app.Tool, 'brush'), 'FontSize', 11);
            uitogglebutton(grp, 'Position', [240 2 110 32], 'Text', 'Erase', ...
                'Value', strcmp(app.Tool, 'erase'), 'FontSize', 11);
            top = top - h - GAP;
            h = 20;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Tag', 'brush_label', ...
                'Text', sprintf('Brush radius: %d voxels', app.BrushRadiusVox), ...
                'FontSize', 11);
            top = top - h - 4;
            sb = uislider(sc, 'Position', [10 top-3 360 3], ...
                'Limits', [1 15], 'Value', app.BrushRadiusVox, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(~,e) brushSizeChanged(app, e));
            sb.Tag = 'brush_slider';
            top = top - 28;
            % Grow tolerance (± HU half-window for click-to-grow)
            h = 20;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Tag', 'growtol_label', ...
                'Text', sprintf('Grow tolerance: ± %d HU', app.GrowTolHU), ...
                'FontSize', 11);
            top = top - h - 4;
            gt = uislider(sc, 'Position', [10 top-3 360 3], ...
                'Limits', [20 250], 'Value', app.GrowTolHU, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(~,e) growTolChanged(app, e));
            gt.Tag = 'growtol_slider';
            top = top - 24;
            h = 30;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Text', ['Tip: in the 3-D view, arm “Pick vessel” then ', ...
                         'choose Erase to carve leaked bone/vein with a ', ...
                         'click (ball = brush radius). Click grows; ', ...
                         'Shift-drag live-grows.'], ...
                'FontSize', 10, 'FontColor', [0.40 0.40 0.45], 'WordWrap', 'on');
            top = top - h - 6;
            h = 28;
            uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                'Text', '🗑 Clear all segmentation', 'FontSize', 11, ...
                'BackgroundColor', [0.97 0.85 0.85], ...
                'ButtonPushedFcn', @(~,~) clearMask(app));
            top = top - h - 12;

            % ---------- Status + Done ---------------------------------
            % Compute mL only when we actually have a volume + mask,
            % otherwise emit a "load a CT first" hint. Without this
            % guard the user-driven Step 2 panel crashed on a fresh
            % launch when no volume had been loaded yet.
            have_vol = ~isempty(app.D) && isstruct(app.D) && ...
                isfield(app.D, 'pixel_mm') && ~isempty(app.Mask);
            if have_vol
                mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                     app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
                status_text = sprintf('Selected %.1f mL  (%d clicks)', ...
                    mL, numel(app.SeedSegList));
                status_color = [0 0.4 0];
            else
                status_text = '(load a CT in Step 1 first — no segmentation yet)';
                status_color = [0.55 0.30 0];
            end
            h = 24;
            uilabel(sc, 'Position', [10 top-h 360 h], ...
                'Tag', 'seg_status', ...
                'Text', status_text, ...
                'FontSize', 12, 'FontColor', status_color, 'WordWrap', 'on');
            top = top - h - GAP;
            h = 40;
            uibutton(sc, 'push', 'Position', [10 top-h 360 h], ...
                'Text', '✓ Done — go to Step 3', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) finishStep2(app));
            top = top - h - 12;
            % Spacer keeps the scroll height honest
            uilabel(sc, 'Position', [10 top 1 1], 'Text', '', ...
                'Tag', 'step2_bottom_pad'); %#ok<NASGU>

            % --- Shift the entire layout up so the lowest child
            % sits at y >= 10. MATLAB uipanel + Scrollable='on'
            % only auto-extends scroll for content ABOVE Position(4),
            % not below y=0, so we anchor the bottom to y≈10 and let
            % the top end up wherever it lands (which will be above
            % the visible window when content > Position(4)).
            kids = sc.Children;
            ys = arrayfun(@(h) h.Position(2), kids);
            min_y = min(ys);
            if min_y < 10
                shift = 10 - min_y;
                for i = 1:numel(kids)
                    kids(i).Position(2) = kids(i).Position(2) + shift;
                end
            end
            % Scroll the panel to show the TOP of the content first
            % (the hint banner) — otherwise MATLAB defaults to
            % showing y=0 which is the BOTTOM of our layout.
            try
                scroll(sc, 'top');
            catch
                % Older MATLAB: Position-shift fallback. Compute the
                % current top edge of content; set the panel's
                % scroll to that y minus visible height.
                try
                    top_y = max(arrayfun(@(h) h.Position(2) + h.Position(4), kids));
                    sc.ScrollableViewLocation = [0, max(0, top_y - sc.Position(4))];
                catch
                end
            end
        end

        function top = sectionHdr(app, sc, top, txt, color, help_key)
            % Place a section header with its TOP at `top` and
            % return the new top y for the next element. Generous
            % bottom margin so the next widget doesn't hug the title.
            % Optional HELP_KEY renders an ⓘ info button on the right.
            if nargin < 6; help_key = ''; end
            h = 26;
            label_w = 360 - 24 * ~isempty(help_key);
            uilabel(sc, 'Position', [10 top-h label_w h], ...
                'Text', txt, 'FontSize', 14, 'FontWeight', 'bold', ...
                'FontColor', color);
            if ~isempty(help_key)
                ui_helpers.info_button(sc, [10+label_w+4 top-h+3 20 20], ...
                    help_key, app.UIFigure);
            end
            top = top - h - 10;
        end

        function runAutoSeg(app)
            % Pull the user's target selection from the checkboxes —
            % each is keyed by Tag = ts_target_<roi_name>.
            cb_handles = findobj(app.SideContent, '-regexp', 'Tag', '^ts_target_');
            targets = {};
            for h = cb_handles(:).'
                if isvalid(h) && h.Value
                    nm = h.Tag(numel('ts_target_')+1:end);
                    if ~strcmp(nm, 'iliac_vena')   % vena flag is off-by-default
                        targets{end+1} = nm; %#ok<AGROW>
                    end
                end
            end
            if isempty(targets)
                % Automatic mode builds no ROI checkboxes (buildStep2_auto),
                % so findobj returns nothing — fall back to the canonical
                % EVAR target set instead of aborting with "Nothing
                % selected". This was the bug that made one-click
                % auto-segmentation silently do nothing.
                if ~isempty(cb_handles)
                    % User mode WITH checkboxes present but all unticked:
                    % that is a real "nothing selected" — honor it.
                    uialert(app.UIFigure, ...
                        'Pick at least one ROI (aorta and/or iliac arteries).', ...
                        'Nothing selected'); return;
                end
                targets = {'aorta', 'iliac_artery_left', 'iliac_artery_right'};
            end

            stat = findobj(app.SideContent, 'Tag', 'ts_status');
            d = uiprogressdlg(app.UIFigure, 'Title', 'TotalSegmentator…', ...
                'Message', sprintf('Segmenting: %s\n(uses MPS GPU on Apple Silicon, ~1 min)', ...
                    strjoin(targets, ', ')), ...
                'Indeterminate', 'on');
            try
                % Use the simpler runner (autoseg.ts_run) instead of the
                % cached wrapper. The cache layer was masking the
                % real error. This runs ~46s on JohnDoe1 CT with --fast +
                % MPS, and reads the multilabel NIfTI to extract the
                % requested classes by integer ID. Verbose log goes
                % to <work_dir>/log.txt for debugging.
                % return_label_volume=true makes ts_run hand back the
                % EXACT multilabel seg it used (info.label_volume), on both
                % the cache-hit and fresh-run paths. Use that directly for
                % branch detection + auto-seeds instead of re-reading "the
                % newest *_seg.nii.gz in the cache dir", which silently
                % grabbed another scan's labels once more than one case had
                % been segmented this session.
                ts_opts = struct('targets', {targets}, 'fast', true, ...
                                 'return_label_volume', true);
                [m_auto, info] = autoseg.ts_run(app.D, ts_opts);
                pushUndo(app);
                % Run post-TS branch + CFA detection. Reads the cached
                % multilabel NIfTI (TS output) and grows iliacs to CFA,
                % adds renals/SMA/celiac as separate labeled CCs.
                d.Message = 'Detecting branches (renals, SMA, celiac, CFA extension)…';
                drawnow;
                seg_loaded = uint8([]);
                if isfield(info, 'label_volume') && ~isempty(info.label_volume)
                    seg_loaded = uint8(info.label_volume);
                    app.TSLabelVolume = seg_loaded;   % deterministic handle for seeds/audit
                end
                if ~isempty(seg_loaded) && isequal(size(seg_loaded), size(app.D.vol))
                    try
                        [m_branch, label_branch, info_b] = autoseg.detect_branches_cached(app.D, seg_loaded);
                        app.Mask = app.Mask | m_branch;
                        % Propagate per-label anatomic assignments into
                        % app.MaskLabel so the Step 3 colored render
                        % can show each label in its own color.
                        ensureMaskLabel(app);
                        new_label_mask = label_branch > 0 & app.MaskLabel == 0;
                        app.MaskLabel(new_label_mask) = label_branch(new_label_mask);
                        info.branches = info_b.branches;
                        info.cfa_L_added_mL = info_b.cfa_L_added_mL;
                        info.cfa_R_added_mL = info_b.cfa_R_added_mL;
                    catch ME_b
                        fprintf('[runAutoSeg] branch detect failed: %s\n', ME_b.message);
                        app.Mask = app.Mask | m_auto;
                    end
                else
                    app.Mask = app.Mask | m_auto;
                end
                close(d);
                if ~isempty(stat) && isvalid(stat)
                    if info.from_cache
                        stat.Text = sprintf('Cached result: %d ROIs, %d voxels.', ...
                            numel(info.targets_found), sum(info.voxel_counts));
                    else
                        stat.Text = sprintf('TS done in %.1fs: %s', ...
                            info.processing_time, ...
                            strjoin(info.targets_found, ', '));
                    end
                    stat.FontColor = [0 0.4 0];
                end
                refreshMain(app);
            catch ME
                close(d);
                uialert(app.UIFigure, ME.message, 'Auto-segment failed');
                if ~isempty(stat) && isvalid(stat)
                    stat.Text = sprintf('Failed: %s', ME.message);
                    stat.FontColor = [0.6 0 0];
                end
            end
        end

        function runAutoPipeline(app)
            % ONE-CLICK CT -> centerline. Drives the proven, regression-
            % tested engine (run_planner_headless) on the already-loaded
            % volume and injects mask + branch labels + 3 seeds + the
            % bifurcated centerline for display. This deliberately bypasses
            % the per-step auto flow (and its modal prompts + "newest cache
            % file" guessing), so the user gets a deterministic result on
            % both JohnDoe1 and JohnDoe2 with a single action.
            if ~isfield(app.D, 'vol') || isempty(app.D.vol)
                uialert(app.UIFigure, 'Load a CT first (Step 1).', ...
                    'No volume loaded');
                return;
            end
            d = uiprogressdlg(app.UIFigure, 'Title', 'Auto-run full pipeline…', ...
                'Message', ['Segmentation → branches → CFA extension → ' ...
                    'supraceliac crop → auto-seeds → bifurcated centerline.', ...
                    newline, 'Segmentation is cached; the VMTK centerline ' ...
                    'computes fresh (~1 min on first run).'], ...
                'Indeterminate', 'on');
            try
                opts = struct();
                opts.D = app.D;                 % skip DICOM read, use loaded vol
                opts.centerline_backend = 'auto';
                opts.out_dir = fullfile(tempdir, sprintf('evar_autopipe_%s', ...
                    char(java.util.UUID.randomUUID)));
                out = run_planner_headless('', opts);

                % --- inject results (headless keeps the full, uncropped frame) ---
                % app.D stays the loaded volume: the engine runs on opts.D
                % (== app.D) and does not crop, so out.mask is already in
                % app.D's frame. We deliberately do NOT take out.D — the
                % result cache strips the volume from it to save ~600 MB.
                pushUndo(app);
                app.Mask = logical(out.mask);
                sz = size(app.Mask);
                if isfield(out, 'label_branch') && ~isempty(out.label_branch) ...
                        && isequal(size(out.label_branch), sz)
                    app.MaskLabel = uint8(out.label_branch);
                else
                    ensureMaskLabel(app);
                end
                app.DisplayExclusion = ~app.Mask;
                if isfield(out, 'ts_info') && isfield(out.ts_info, 'label_volume') ...
                        && ~isempty(out.ts_info.label_volume) ...
                        && isequal(size(out.ts_info.label_volume), sz)
                    app.TSLabelVolume = uint8(out.ts_info.label_volume);
                end

                % seeds (voxel [y x z])
                app.SeedProximal = out.seeds.proximal;
                app.SeedRightCFA = out.seeds.right_cfa;
                app.SeedLeftCFA  = out.seeds.left_cfa;

                % centerlines: headless returns mm; convert to voxel overlay
                Pv_R = mm_to_vox(out.Pv_mm_right, app.D);
                Pv_L = mm_to_vox(out.Pv_mm_left,  app.D);
                sxy  = mean(app.D.pixel_mm(1:2));
                app.PolylineRight = Pv_R; app.R_vox_right = out.R_mm_right / sxy;
                app.PolylineLeft  = Pv_L; app.R_vox_left  = out.R_mm_left  / sxy;
                app.Polyline = Pv_R;      app.R_vox = out.R_mm_right / sxy;
                bif = [];
                try
                    [bif, ~] = find_skeleton_bifurc(Pv_R, Pv_L);
                catch
                end
                app.BifurcNodeIdx = bif;
                app.CPRImage = [];
                % Landmark node-indices reference the OLD polyline; a fresh
                % centerline invalidates them. Clear so Step 5 re-derives.
                setappdata(app.UIFigure, 'landmarks', struct());
                setappdata(app.UIFigure, 'arm_landmark', '');
                if isfield(out, 'audit') && isstruct(out.audit)
                    app.SegAuditReport = out.audit;
                end
                if ischar(out.centerline_backend)
                    app.CenterlineMethod = out.centerline_backend;
                end

                % reset display indices + force rebuild of image/volume
                app.IdxAxial    = round(sz(3)/2);
                app.IdxCoronal  = round(sz(1)/2);
                app.IdxSagittal = round(sz(2)/2);
                if ~isempty(app.MainImage) && isvalid(app.MainImage)
                    delete(app.MainImage); app.MainImage = [];
                end
                if ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                    delete(app.VolViewer); app.VolViewer = [];
                end

                if isvalid(d); close(d); end

                mL = nnz(app.Mask) * app.D.pixel_mm(1) * app.D.pixel_mm(2) * ...
                     abs(app.D.slice_spacing_mm) / 1000;
                fprintf(['[runAutoPipeline] %.1f mL, R arc %.0f mm / L arc %.0f mm, ' ...
                    'backend=%s\n'], mL, out.arc_R_mm, out.arc_L_mm, out.centerline_backend);

                % Land on the centerline-review step.
                updateStep(app, 4);
                try
                    centerSlicesOnCenterline(app);
                    setViewMode(app, '2x2');
                    fitView(app);
                catch
                end
                refreshMain(app);
            catch ME
                if isvalid(d); close(d); end
                uialert(app.UIFigure, sprintf(['Auto pipeline failed:', newline, ...
                    '%s', newline, newline, ...
                    'You can still run the steps individually.'], ME.message), ...
                    'Auto pipeline failed');
            end
        end

        function yc = sectionHeader(app, yc, txt, color)
            uilabel(app.SideContent, 'Position', [10 yc 360 22], ...
                'Text', txt, 'FontSize', 13, 'FontWeight', 'bold', ...
                'FontColor', color);
            yc = yc - 26;
        end

        function huMinChanged(app, evt)
            app.HU_min = round(evt.Value);
            lbl = findobj(app.SideContent, 'Tag', 'hu_label');
            if ~isempty(lbl) && isvalid(lbl)
                lbl.Text = sprintf('HU range: %d – %d', app.HU_min, app.HU_max);
            end
        end

        function huMaxChanged(app, evt)
            app.HU_max = round(evt.Value);
            lbl = findobj(app.SideContent, 'Tag', 'hu_label');
            if ~isempty(lbl) && isvalid(lbl)
                lbl.Text = sprintf('HU range: %d – %d', app.HU_min, app.HU_max);
            end
        end

        function renderSeedFlowUI(app)
            % Top description / status block
            switch app.SegSubStep
                case 0
                    headline = 'Place seed — Axial view';
                    body     = ['Switch to the AXIAL view and click inside ' ...
                                'the aorta lumen. A red dot will mark your seed.'];
                    status   = '(no seed placed)';
                case 1
                    headline = 'Confirm axial seed';
                    body     = ['Red dot is on the axial slice. Click ' ...
                                'CONFIRM to verify it on the coronal view, ' ...
                                'or MOVE to click again and reposition.'];
                    status   = sprintf('Pending seed: %s  (axial)', seedStr(app.PendingSeed));
                case 2
                    headline = 'Confirm coronal projection';
                    body     = ['View has switched to CORONAL. Verify the ' ...
                                'red dot is still inside the aorta. Click ' ...
                                'in the coronal view to refine, then ' ...
                                'CONFIRM (or MOVE).'];
                    status   = sprintf('Pending seed: %s  (coronal)', seedStr(app.PendingSeed));
                case 3
                    headline = 'Confirm sagittal projection';
                    body     = ['View has switched to SAGITTAL. Verify the ' ...
                                'red dot is still inside the aorta. Click ' ...
                                'in the sagittal view to refine, then ' ...
                                'CONFIRM (or MOVE).'];
                    status   = sprintf('Pending seed: %s  (sagittal)', seedStr(app.PendingSeed));
                case 4
                    headline = 'Ready to segment';
                    body     = ['Seed confirmed in all three views. Click ' ...
                                'START SEGMENTATION to run fast-marching ' ...
                                'from this seed, or CANCEL to clear and ' ...
                                'start over.'];
                    status   = sprintf('Confirmed seed: %s', seedStr(app.PendingSeed));
            end

            % Layout — top-down, fixed gaps so nothing overlaps. We give
            % the slider a 30 px clearance below for its tick-label band.
            H  = panelInteriorHeight(app);   % usable height inside SideContent
            yc = H - 40;   % cursor we draw downward from

            uilabel(app.SideContent, 'Position', [10 yc 360 28], ...
                'Text', headline, 'FontSize', 14, 'FontWeight', 'bold', ...
                'FontColor', [0.10 0.20 0.55]);
            yc = yc - 95;
            uilabel(app.SideContent, 'Position', [10 yc 360 90], ...
                'WordWrap', 'on', 'FontSize', 12, 'Text', body);
            yc = yc - 30;
            uilabel(app.SideContent, 'Position', [10 yc 360 22], ...
                'Tag', 'seed_flow_status', 'Text', status, ...
                'FontSize', 11, 'FontColor', [0.25 0.25 0.25]);

            yc = yc - 28;
            uilabel(app.SideContent, 'Position', [10 yc 360 22], ...
                'Tag', 'vthresh_label', ...
                'Text', sprintf('Vesselness threshold: %.3f', app.VesselnessThresh), ...
                'FontSize', 12);
            yc = yc - 25;
            sl = uislider(app.SideContent, 'Position', [10 yc 360 3], ...
                'Limits', [0.01 0.15], 'Value', app.VesselnessThresh, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(s,e) thresholdSliderMoved(app, e));
            sl.Tag = 'vthresh_slider';

            % Slider tick-label band clearance (~30 px) before next row
            yc = yc - 60;

            % Action buttons depend on substep
            switch app.SegSubStep
                case 0
                    % nothing — they need to click in the image
                case {1, 2, 3}
                    uibutton(app.SideContent, 'push', ...
                        'Position', [10 yc-10 175 60], ...
                        'Text', 'Confirm', 'FontSize', 13, ...
                        'FontWeight', 'bold', ...
                        'BackgroundColor', [0.80 0.95 0.80], ...
                        'ButtonPushedFcn', @(~,~) confirmSeedSubstep(app));
                    uibutton(app.SideContent, 'push', ...
                        'Position', [195 yc-10 175 60], ...
                        'Text', 'Move', 'FontSize', 13, ...
                        'BackgroundColor', [0.95 0.92 0.80], ...
                        'ButtonPushedFcn', @(~,~) moveSeedSubstep(app));
                case 4
                    uibutton(app.SideContent, 'push', ...
                        'Position', [10 yc-10 360 60], ...
                        'Text', '▶ Start segmentation', 'FontSize', 14, ...
                        'FontWeight', 'bold', ...
                        'BackgroundColor', [0.80 0.95 0.80], ...
                        'ButtonPushedFcn', @(~,~) startSegmentationFlow(app));
            end
            yc = yc - 75;

            % Cancel always available (except substep 0 — nothing to cancel)
            if app.SegSubStep > 0
                uibutton(app.SideContent, 'push', ...
                    'Position', [10 yc 360 36], ...
                    'Text', 'Cancel — start over', 'FontSize', 11, ...
                    'BackgroundColor', [0.97 0.85 0.85], ...
                    'ButtonPushedFcn', @(~,~) cancelSeedFlow(app));
            end
        end

        function renderRefinementUI(app)
            H  = panelInteriorHeight(app);
            yc = H - 40;

            uilabel(app.SideContent, 'Position', [10 yc 360 28], ...
                'Text', 'Refine segmentation', 'FontSize', 14, ...
                'FontWeight', 'bold', 'FontColor', [0.10 0.45 0.20]);
            yc = yc - 70;
            uilabel(app.SideContent, 'Position', [10 yc 360 65], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Use Brush / Erase to fix leaks or gaps. To add ' ...
                         'another vessel territory (e.g. an iliac), click ' ...
                         '"Add seed" and run the 3-view confirmation again.']);

            yc = yc - 28;
            uilabel(app.SideContent, 'Position', [10 yc 360 22], ...
                'Tag', 'vthresh_label', ...
                'Text', sprintf('Vesselness threshold: %.3f', app.VesselnessThresh), ...
                'FontSize', 12);
            yc = yc - 25;
            sl = uislider(app.SideContent, 'Position', [10 yc 360 3], ...
                'Limits', [0.01 0.15], 'Value', app.VesselnessThresh, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(s,e) thresholdSliderMoved(app, e));
            sl.Tag = 'vthresh_slider';
            yc = yc - 50;

            uibutton(app.SideContent, 'push', ...
                'Position', [10 yc 175 32], ...
                'Text', 'Re-run last seed', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) rerunSegmentation(app));
            uibutton(app.SideContent, 'push', ...
                'Position', [195 yc 175 32], ...
                'Text', '+ Add seed (3-view)', 'FontSize', 11, ...
                'BackgroundColor', [0.85 0.92 1.00], ...
                'ButtonPushedFcn', @(~,~) cancelSeedFlow(app));

            % --- Tool selector ---
            yc = yc - 30;
            uilabel(app.SideContent, 'Position', [10 yc 360 20], ...
                'Text', 'Tool:', 'FontSize', 12, 'FontWeight', 'bold');
            yc = yc - 50;
            grp = uibuttongroup(app.SideContent, ...
                'Position', [10 yc 360 50], 'BorderType', 'none', ...
                'BackgroundColor', 'w', ...
                'SelectionChangedFcn', @(g,e) toolChanged(app, e.NewValue.Text));
            uitogglebutton(grp, 'Position', [0 0 110 40], 'Text', 'Click', ...
                'Value', strcmp(app.Tool, 'click'), 'FontSize', 11);
            uitogglebutton(grp, 'Position', [120 0 110 40], 'Text', 'Brush', ...
                'Value', strcmp(app.Tool, 'brush'), 'FontSize', 11);
            uitogglebutton(grp, 'Position', [240 0 110 40], 'Text', 'Erase', ...
                'Value', strcmp(app.Tool, 'erase'), 'FontSize', 11);

            % Brush radius
            yc = yc - 30;
            uilabel(app.SideContent, 'Position', [10 yc 360 20], ...
                'Tag', 'brush_label', ...
                'Text', sprintf('Brush radius: %d voxels', app.BrushRadiusVox), ...
                'FontSize', 11);
            yc = yc - 25;
            sb = uislider(app.SideContent, 'Position', [10 yc 360 3], ...
                'Limits', [1 15], 'Value', app.BrushRadiusVox, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(s,e) brushSizeChanged(app, e));
            sb.Tag = 'brush_slider';
            yc = yc - 40;

            % Grow tolerance (± HU half-window for click-to-grow)
            uilabel(app.SideContent, 'Position', [10 yc 360 20], ...
                'Tag', 'growtol_label', ...
                'Text', sprintf('Grow tolerance: ± %d HU', app.GrowTolHU), ...
                'FontSize', 11);
            yc = yc - 25;
            gt = uislider(app.SideContent, 'Position', [10 yc 360 3], ...
                'Limits', [20 250], 'Value', app.GrowTolHU, ...
                'MajorTicks', [], 'MinorTicks', [], ...
                'ValueChangingFcn', @(s,e) growTolChanged(app, e));
            gt.Tag = 'growtol_slider';
            yc = yc - 50;

            % Undo / redo
            uibutton(app.SideContent, 'push', ...
                'Position', [10 yc 175 32], 'Text', 'Undo', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) undoMask(app));
            uibutton(app.SideContent, 'push', ...
                'Position', [195 yc 175 32], 'Text', 'Redo', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) redoMask(app));
            yc = yc - 42;

            uibutton(app.SideContent, 'push', ...
                'Position', [10 yc 360 32], ...
                'Text', 'Clear segmentation', 'FontSize', 11, ...
                'BackgroundColor', [0.97 0.85 0.85], ...
                'ButtonPushedFcn', @(~,~) clearMask(app));
            yc = yc - 42;

            uilabel(app.SideContent, 'Position', [10 yc 360 30], ...
                'Tag', 'seg_status', ...
                'Text', sprintf('Segmented %.1f mL  (%d seeds)', ...
                    sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                    app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000, ...
                    numel(app.SeedSegList)), ...
                'FontColor', [0 0.4 0], 'WordWrap', 'on');

            uibutton(app.SideContent, 'push', ...
                'Position', [10 30 360 44], ...
                'Text', '✓ Done — go to Step 3', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) finishStep2(app));
        end

        function H = panelInteriorHeight(app)
            % Height usable for layout inside SideContent. Always defer
            % to the live Position so resizing or smaller screens give
            % us a coherent number.
            H = app.SideContent.Position(4);
        end

        function toolChanged(app, label)
            app.Tool = lower(label);
            % Wire WindowButtonMotion / Up for paint stroke if brush/erase
            if any(strcmp(app.Tool, {'brush', 'erase'}))
                app.UIFigure.WindowButtonUpFcn   = @(~,~) endPaintStroke(app);
            else
                app.UIFigure.WindowButtonMotionFcn = '';
                app.UIFigure.WindowButtonUpFcn     = '';
            end
        end

        function brushSizeChanged(app, evt)
            app.BrushRadiusVox = round(evt.Value);
            lbl = findobj(app.SideContent, 'Tag', 'brush_label');
            if ~isempty(lbl) && isvalid(lbl)
                lbl.Text = sprintf('Brush radius: %d voxels', app.BrushRadiusVox);
            end
        end

        function growTolChanged(app, evt)
            % "Grow tolerance ± HU" slider. Widens / narrows the HU
            % half-window used by the click-to-grow region grow
            % (runSegmentation + liveGrowFromSeed). Tighten it when the
            % grow leaks into adjacent bone; loosen it when a weakly
            % opacified distal vessel won't fill. Takes effect on the
            % NEXT click — existing segmentation is untouched.
            app.GrowTolHU = round(evt.Value);
            lbl = findobj(app.SideContent, 'Tag', 'growtol_label');
            if ~isempty(lbl) && isvalid(lbl)
                lbl.Text = sprintf('Grow tolerance: ± %d HU', app.GrowTolHU);
            end
        end

        function startPaintStroke(app, voxel)
            pushUndo(app);
            app.IsPainting = true;
            paintAt(app, voxel);
            app.UIFigure.WindowButtonMotionFcn = @(~,~) paintMotion(app);
        end

        function paintMotion(app)
            if ~app.IsPainting; return; end
            % Determine the voxel under the cursor in the current view
            voxel = cursorVoxel(app);
            if isempty(voxel); return; end
            paintAt(app, voxel);
        end

        function endPaintStroke(app)
            app.IsPainting = false;
            app.UIFigure.WindowButtonMotionFcn = '';
            refreshMain(app);
        end

        function paintAt(app, voxel)
            r = app.BrushRadiusVox;
            sz = size(app.D.vol);
            % Operate on the slice of the current view, with a small
            % out-of-plane thickness so a single drag affects ~3 slices.
            zthick = max(1, round(r/2));
            switch app.ViewMode
                case 'axial'
                    z_lo = max(1, voxel(3) - zthick);
                    z_hi = min(sz(3), voxel(3) + zthick);
                    [Y, X] = ndgrid(1:sz(1), 1:sz(2));
                    in_disk = (Y - voxel(1)).^2 + (X - voxel(2)).^2 <= r^2;
                    for z = z_lo:z_hi
                        slc = app.Mask(:, :, z);
                        if strcmp(app.Tool, 'brush')
                            slc(in_disk) = true;
                        else
                            slc(in_disk) = false;
                        end
                        app.Mask(:, :, z) = slc;
                    end
                case 'coronal'
                    y_lo = max(1, voxel(1) - zthick);
                    y_hi = min(sz(1), voxel(1) + zthick);
                    [X, Z] = ndgrid(1:sz(2), 1:sz(3));
                    in_disk = (X - voxel(2)).^2 + (Z - voxel(3)).^2 <= r^2;
                    for y = y_lo:y_hi
                        slab = squeeze(app.Mask(y, :, :));
                        if strcmp(app.Tool, 'brush')
                            slab(in_disk) = true;
                        else
                            slab(in_disk) = false;
                        end
                        app.Mask(y, :, :) = slab;
                    end
                case 'sagittal'
                    x_lo = max(1, voxel(2) - zthick);
                    x_hi = min(sz(2), voxel(2) + zthick);
                    [Y, Z] = ndgrid(1:sz(1), 1:sz(3));
                    in_disk = (Y - voxel(1)).^2 + (Z - voxel(3)).^2 <= r^2;
                    for x = x_lo:x_hi
                        slab = squeeze(app.Mask(:, x, :));
                        if strcmp(app.Tool, 'brush')
                            slab(in_disk) = true;
                        else
                            slab(in_disk) = false;
                        end
                        app.Mask(:, x, :) = slab;
                    end
                case '3d'
                    return;   % no painting on the MIP
            end
            refreshMain(app);
        end

        function voxel = cursorVoxel(app)
            voxel = [];
            cp = app.MainAxes.CurrentPoint;
            if isempty(cp); return; end
            ix = round(cp(1, 1)); iy = round(cp(1, 2));
            sz = size(app.D.vol);
            switch app.ViewMode
                case 'axial';    voxel = [iy, ix, app.IdxAxial];
                case 'coronal';  voxel = [app.IdxCoronal, ix, iy];
                case 'sagittal'; voxel = [ix, app.IdxSagittal, iy];
                case '3d';       return;
            end
            voxel(1) = max(1, min(sz(1), voxel(1)));
            voxel(2) = max(1, min(sz(2), voxel(2)));
            voxel(3) = max(1, min(sz(3), voxel(3)));
        end

        function pushUndo(app)
            % Trim redo branch
            if app.UndoIndex < numel(app.UndoStack)
                app.UndoStack = app.UndoStack(1:app.UndoIndex);
            end
            % Cap at 20 snapshots
            if numel(app.UndoStack) >= 20
                app.UndoStack = app.UndoStack(2:end);
                app.UndoIndex = app.UndoIndex - 1;
            end
            app.UndoStack{end+1} = app.Mask;
            app.UndoIndex = numel(app.UndoStack);
        end

        function undoMask(app)
            if app.UndoIndex < 1; return; end
            app.UndoIndex = max(1, app.UndoIndex - 1);
            app.Mask = app.UndoStack{app.UndoIndex};
            refreshMain(app);
        end

        function redoMask(app)
            if app.UndoIndex >= numel(app.UndoStack); return; end
            app.UndoIndex = app.UndoIndex + 1;
            app.Mask = app.UndoStack{app.UndoIndex};
            refreshMain(app);
        end

        function thresholdSliderMoved(app, evt)
            app.VesselnessThresh = evt.Value;
            lbl = findobj(app.SideContent, 'Tag', 'vthresh_label');
            if ~isempty(lbl) && isvalid(lbl)
                lbl.Text = sprintf('Vesselness threshold: %.3f', evt.Value);
            end
        end

        function onSegmentSeedClick(app, voxel)
            % TeraRecon-style click-to-add: run the fast region grow
            % from the click point. Result writes into MaskLabel
            % with a new label value (see runSegmentation).
            %
            % If the guided 5-click landmark workflow is active
            % (app.GuidedStep > 0), the resulting region gets the
            % anatomic label for the current target instead of the
            % rotating per-click label.
            app.SeedSeg = voxel;
            app.SeedSegList{end+1} = voxel;
            app.IdxAxial    = voxel(3);
            app.IdxCoronal  = voxel(1);
            app.IdxSagittal = voxel(2);
            if app.GuidedStep > 0 && app.GuidedStep <= 5
                runGuidedSegment(app, voxel);
            else
                runSegmentation(app);
            end
        end

        function targets = guidedTargets(~)
            % Anatomic targets for the 5-click guided workflow.
            % label_id matches the per-label coloring in initVolumeView
            % (1=aorta, 6=renal_L, 7=renal_R, 4=CFA_L, 5=CFA_R).
            targets = {
                struct('name', 'AORTA',      'label_id', 1, ...
                       'hint', 'Click the aorta lumen (any 2-D pane). Best at L1-L2 — bright round contrast.'); ...
                struct('name', 'RIGHT RENAL', 'label_id', 7, ...
                       'hint', 'Click the right renal artery lumen — branches laterally from the aorta at L1.'); ...
                struct('name', 'LEFT RENAL',  'label_id', 6, ...
                       'hint', 'Click the left renal artery lumen — branches laterally from the aorta at L1-L2.'); ...
                struct('name', 'RIGHT CFA',   'label_id', 5, ...
                       'hint', 'Click the right common femoral artery — below the inguinal ligament.'); ...
                struct('name', 'LEFT CFA',    'label_id', 4, ...
                       'hint', 'Click the left common femoral artery — below the inguinal ligament.') };
        end

        function startGuidedFlow(app)
            % Reset and arm the 5-click guided workflow.
            app.GuidedStep = 1;
            app.VesselPickArmed = true;
            try
                app.UIFigure.Pointer = 'crosshair';
            catch
            end
            refreshGuidedBanner(app);
            renderClickToAddUI(app);
        end

        function cancelGuidedFlow(app)
            app.GuidedStep = 0;
            app.VesselPickArmed = false;
            try; app.UIFigure.Pointer = 'arrow'; catch; end
            refreshGuidedBanner(app);
            renderClickToAddUI(app);
        end

        function refreshGuidedBanner(app)
            % Small floating instruction chip that hovers in the
            % middle-right of the recon area. Discreet but readable —
            % shows step number + target name + brief hint + cancel.
            % Hidden when GuidedStep == 0.
            try
                old = findall(app.UIFigure, 'Tag', 'guided_banner');
                for i = 1:numel(old)
                    if isvalid(old(i)); delete(old(i)); end
                end
            catch
            end
            if app.GuidedStep < 1
                return;
            end
            fig_pos = app.UIFigure.Position;
            fig_w = fig_pos(3); fig_h = fig_pos(4);
            % Compact chip (~240×140) docked to the right side of the
            % recon, vertically centered. Side panel is ~410 px wide,
            % so anchor 30 px to the LEFT of the side panel.
            side_panel_w = 410;
            chip_w = 250;
            chip_h = 140;
            chip_x = fig_w - side_panel_w - chip_w - 30;
            chip_y = round(fig_h / 2) - chip_h / 2;
            % State colors
            if app.GuidedStep >= 6
                bg_top = [0.20 0.55 0.25];
                bg_body = [0.92 0.98 0.92];
                fg_top = [1 1 1];
                fg_body = [0.10 0.40 0.10];
                txt_top = '✓ DONE';
                txt_sub = 'All 5 landmarks segmented. Advance to Step 3 for the isolated render.';
            else
                targets = guidedTargets(app);
                t = targets{app.GuidedStep};
                bg_top = [0.20 0.40 0.85];
                bg_body = [0.97 0.97 1.00];
                fg_top = [1 1 1];
                fg_body = [0.15 0.15 0.30];
                txt_top = sprintf('STEP %d / 5', app.GuidedStep);
                txt_sub = sprintf('Click the %s.\n%s', t.name, t.hint);
            end
            % Header strip (color, step number)
            uilabel(app.UIFigure, 'Tag', 'guided_banner', ...
                'Position', [chip_x, chip_y + chip_h - 28, chip_w, 28], ...
                'Text', txt_top, ...
                'FontSize', 14, 'FontWeight', 'bold', ...
                'FontColor', fg_top, 'BackgroundColor', bg_top, ...
                'HorizontalAlignment', 'center');
            % Body (instruction + cancel)
            uilabel(app.UIFigure, 'Tag', 'guided_banner', ...
                'Position', [chip_x, chip_y, chip_w, chip_h - 28], ...
                'Text', txt_sub, ...
                'FontSize', 11, 'FontColor', fg_body, ...
                'BackgroundColor', bg_body, ...
                'HorizontalAlignment', 'left', 'WordWrap', 'on');
            % Cancel X — top-right corner of the chip
            uibutton(app.UIFigure, 'push', 'Tag', 'guided_banner', ...
                'Position', [chip_x + chip_w - 22, chip_y + chip_h - 24, 18, 18], ...
                'Text', '×', 'FontSize', 14, 'FontWeight', 'bold', ...
                'BackgroundColor', bg_top, 'FontColor', fg_top, ...
                'Tooltip', 'Cancel guided flow', ...
                'ButtonPushedFcn', @(~,~) cancelGuidedFlow(app));
        end

        function runGuidedSegment(app, voxel)
            % Run click-and-grow then relabel the new region with the
            % current guided target's anatomic label ID.
            targets = guidedTargets(app);
            step = app.GuidedStep;
            if step < 1 || step > numel(targets); return; end
            target = targets{step};
            pre_label = app.MaskLabel;
            % Run the standard grow which writes a new uint8 label
            runSegmentation(app);
            % Re-label whatever's NEW (post-grow non-zero where pre was 0)
            new_mask = app.MaskLabel ~= 0 & pre_label == 0;
            % Replace the rotating click-label with the anatomic label
            app.MaskLabel(new_mask) = uint8(target.label_id);
            app.Mask = app.MaskLabel > 0;
            fprintf('[guided] step %d (%s, label=%d) — %d voxels assigned\n', ...
                step, target.name, target.label_id, nnz(new_mask));
            % Advance
            app.GuidedStep = app.GuidedStep + 1;
            if app.GuidedStep > 5
                app.GuidedStep = 6;   % done
                app.VesselPickArmed = false;
                try; app.UIFigure.Pointer = 'arrow'; catch; end
            end
            % Repaint the side panel + on-canvas banner so the next
            % target highlights
            try
                refreshGuidedBanner(app);
                renderClickToAddUI(app);
            catch ME
                fprintf('[guided] panel refresh err: %s\n', ME.message);
            end
            % Repaint the 3-D recon
            try
                if strcmp(app.ViewMode, '3dvol')
                    initVolumeView(app);
                end
                redrawCurrentView(app);
            catch
            end
        end

        function toggleVesselPickArmed(app, on)
            % Arm / disarm the "Pick vessel" mode.
            % We KEEP viewer3d Interactions='rotate' so plain clicks
            % still bubble up to the figure WindowButtonDownFcn
            % (setting Interactions='none' was killing the events).
            % Click-vs-drag distinguishes a click from a rotation.
            on = logical(on);
            if on
                try
                    app.UIFigure.Pointer = 'crosshair';
                catch
                end
                app.VesselPickArmed   = true;
                app.VesselPickHasDown = false;
                if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                    app.SliceLabel.Text = ['ARMED — click and HOLD on aorta ' ...
                        'to live-grow; release to commit. Drag to rotate.'];
                end
            else
                try
                    app.UIFigure.Pointer = 'arrow';
                catch
                end
                app.VesselPickArmed   = false;
                app.VesselPickHasDown = false;
                if ~isempty(app.SliceLabel) && isvalid(app.SliceLabel)
                    app.SliceLabel.Text = '';
                end
            end
            % Sync the side-panel toggle visual state
            tg = findobj(app.SideContent, 'Tag', 'pick_vessel_toggle');
            if ~isempty(tg) && isvalid(tg)
                tg.Value = app.VesselPickArmed;
                if app.VesselPickArmed
                    tg.Text = '✓ Pick vessel — ARMED (click to disarm)';
                    tg.BackgroundColor = [0.85 0.95 0.85];
                else
                    tg.Text = '🎯 Pick vessel mode (Shift+click and hold to grow)';
                    tg.BackgroundColor = [0.95 0.92 0.80];
                end
            end
        end

        function useMIPRecon(app)
            % Replace VolPanel's viewer3d with a uiaxes hosting a
            % max-intensity-projection of the current volume. Clicks
            % on the axes are reliable (regular axes ButtonDownFcn,
            % not GPU canvas). Called when entering Step 2.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            if isempty(app.VolPanel) || ~isvalid(app.VolPanel); return; end
            % Tear down prior children of VolPanel
            delete(allchild(app.VolPanel));
            app.VolViewer = images.ui.graphics.Volume.empty;
            % Create the host axes (full-panel, no decorations)
            ax = uiaxes('Parent', app.VolPanel, ...
                'Units', 'normalized', 'Position', [0 0 1 1], ...
                'Color', [0.02 0.02 0.05], ...
                'XColor', 'none', 'YColor', 'none', ...
                'XTick', [], 'YTick', [], 'Box', 'off');
            try; ax.Toolbar.Visible = 'off'; catch; end
            try; disableDefaultInteractivity(ax); catch; end
            ax.PickableParts = 'all';
            ax.HitTest = 'on';
            app.MIPAxes = ax;
            renderMIPView(app, app.MIPViewKind);
        end

        function renderMIPView(app, kind)
            % Compute MIP + per-pixel argmax for the chosen view,
            % display in app.MIPAxes. kind = 'AP' | 'lat-R' | 'lat-L'.
            % Stores app.MIPArgmax for click → voxel lookup.
            if isempty(app.MIPAxes) || ~isvalid(app.MIPAxes); return; end
            app.MIPViewKind = kind;
            % HU window choice is critical. Bone cortex (HU 800-1500)
            % is brighter than contrast lumen (HU 600-900), so a wide
            % window makes bone dominate the argmax → click on the
            % visible aorta lands on vertebra. Clip at HU 750 so bone
            % cortex saturates to the same value as bright lumen;
            % MATLAB's max() returns the FIRST tied index, which on
            % an AP ray is the anterior-most voxel = aorta (in front
            % of the spine). The visible MIP brightness still shows
            % both bone and vessel since both saturate at the same
            % normalized value.
            hu_lo = 200; hu_hi = 750;
            clipped = max(min(app.D.vol, hu_hi), hu_lo);
            switch kind
                case 'AP'
                    % Project along Y (anterior-posterior) → image is
                    % cols (X) × slices (Z), patient anterior on top
                    % of stack means ARGMAX of low-Y is "front-most".
                    [mip, am] = max(clipped, [], 1);
                    mip = squeeze(mip);    am = squeeze(am);
                    % Orient: image rows = -Z (head up), cols = X
                    img2d = flipud(permute(mip, [2 1]));
                    arg2d = flipud(permute(am,  [2 1]));
                case 'lat-R'
                    % Project along X (left-right) from patient right
                    [mip, am] = max(clipped, [], 2);
                    mip = squeeze(mip);    am = squeeze(am);
                    img2d = flipud(permute(mip, [2 1]));
                    arg2d = flipud(permute(am,  [2 1]));
                case 'lat-L'
                    % Project along X from patient left
                    flipped_clip = flip(clipped, 2);
                    [mip, am] = max(flipped_clip, [], 2);
                    mip = squeeze(mip);    am = squeeze(am);
                    am = size(app.D.vol, 2) - am + 1;
                    img2d = flipud(permute(mip, [2 1]));
                    arg2d = flipud(permute(am,  [2 1]));
                otherwise
                    return;
            end
            % Apply CTA red/orange palette + sqrt gamma
            n = double(img2d - hu_lo) / double(hu_hi - hu_lo);
            n = max(0, min(1, n)) .^ 0.5;
            rgb = zeros([size(n), 3], 'single');
            rgb(:,:,1) = single(n .* 1.00);
            rgb(:,:,2) = single(n .* 0.50);
            rgb(:,:,3) = single(n .* 0.40);
            app.MIPArgmax = uint16(arg2d);
            % Render
            ax = app.MIPAxes;
            cla(ax);
            ax.YDir = 'reverse';
            app.MIPImage = imagesc(ax, rgb);
            colormap(ax, gray(256));
            axis(ax, 'image');
            ax.XLim = [0.5, size(rgb, 2) + 0.5];
            ax.YLim = [0.5, size(rgb, 1) + 0.5];
            % Wire the click handler. Both axes and image get the
            % callback so clicks land regardless of where on the
            % axes/image the user picks.
            cb = @(~,evt) onMIPClick(app, evt);
            ax.ButtonDownFcn = cb;
            app.MIPImage.ButtonDownFcn = cb;
            app.MIPImage.PickableParts = 'all';
            app.MIPImage.HitTest = 'on';
            % Overlay current mask if any (using the argmax → voxel
            % map: tint a pixel if MaskLabel is non-zero at the
            % argmax voxel).
            redrawMIPMaskOverlay(app);
            drawnow;
            fprintf('[MIP] rendered %s view: %dx%d\n', kind, size(rgb,1), size(rgb,2));
        end

        function redrawMIPMaskOverlay(app)
            % Tint pixels whose argmax voxel falls inside MaskLabel>0.
            % Uses the LabelColors palette so each click's territory
            % shows in its own color on the MIP.
            if isempty(app.MIPAxes) || ~isvalid(app.MIPAxes); return; end
            if isempty(app.MaskLabel); return; end
            if isempty(app.MIPImage) || ~isvalid(app.MIPImage); return; end
            arg = app.MIPArgmax;
            sz = size(app.D.vol);
            kind = app.MIPViewKind;
            [H, W] = size(arg);
            label_at_pixel = zeros(H, W, 'uint8');
            % For each pixel, map (row, col, argmax) → (volume row, col, slice)
            switch kind
                case 'AP'
                    % img: row = (size3 - z + 1), col = x; argmax = y_row
                    [pi_r, pi_c] = ndgrid(1:H, 1:W);
                    z_idx = sz(3) - pi_r + 1;
                    y_idx = arg;
                    x_idx = pi_c;
                case 'lat-R'
                    [pi_r, pi_c] = ndgrid(1:H, 1:W);
                    z_idx = sz(3) - pi_r + 1;
                    y_idx = pi_c;
                    x_idx = arg;
                case 'lat-L'
                    [pi_r, pi_c] = ndgrid(1:H, 1:W);
                    z_idx = sz(3) - pi_r + 1;
                    y_idx = pi_c;
                    x_idx = arg;
                otherwise
                    return;
            end
            % Bounds check
            valid = z_idx >= 1 & z_idx <= sz(3) & ...
                    y_idx >= 1 & y_idx <= sz(1) & ...
                    x_idx >= 1 & x_idx <= sz(2);
            lin = sub2ind(sz, y_idx(valid), x_idx(valid), z_idx(valid));
            label_at_pixel(valid) = app.MaskLabel(lin);
            % Composite tint onto current image
            cdata = app.MIPImage.CData;
            for k = 1:max(double(label_at_pixel(:)))
                if k > size(app.LabelColors, 1); break; end
                col = app.LabelColors(k, :);
                m_k = (label_at_pixel == k);
                if ~any(m_k(:)); continue; end
                for ch = 1:3
                    layer = cdata(:,:,ch);
                    layer(m_k) = single(0.50) * layer(m_k) + single(0.50 * col(ch));
                    cdata(:,:,ch) = layer;
                end
            end
            app.MIPImage.CData = cdata;
        end

        function onMIPClick(app, evt)
            % Click on the MIP axes → look up the argmax voxel → seed
            % the segment grow. Reliable: regular axes events.
            try
                if isempty(app.MIPArgmax) || isempty(app.MIPAxes); return; end
                cp = app.MIPAxes.CurrentPoint;
                px = round(cp(1, 1));
                py = round(cp(1, 2));
                [H, W] = size(app.MIPArgmax);
                if px < 1 || px > W || py < 1 || py > H
                    fprintf('[MIP] click outside image: px=%d py=%d\n', px, py);
                    return;
                end
                arg = double(app.MIPArgmax(py, px));
                sz = size(app.D.vol);
                switch app.MIPViewKind
                    case 'AP'
                        z = sz(3) - py + 1;  y = arg;  x = px;
                    case 'lat-R'
                        z = sz(3) - py + 1;  y = px;  x = arg;
                    case 'lat-L'
                        z = sz(3) - py + 1;  y = px;  x = arg;
                    otherwise
                        return;
                end
                voxel = [y, x, z];
                voxel(1) = max(1, min(sz(1), voxel(1)));
                voxel(2) = max(1, min(sz(2), voxel(2)));
                voxel(3) = max(1, min(sz(3), voxel(3)));
                fprintf('[MIP-click] px=%d py=%d → voxel=[%d %d %d] HU=%d\n', ...
                    px, py, voxel, int32(app.D.vol(voxel(1), voxel(2), voxel(3))));
                flashSegStatus(app, sprintf('Click at HU=%d — segmenting…', ...
                    int32(app.D.vol(voxel(1), voxel(2), voxel(3)))), [0.20 0.55 1.00]);
                drawnow;
                onVesselSelectClick(app, voxel);
                redrawMIPMaskOverlay(app);
                flashSegStatus(app, sprintf('Done — %.1f mL total', ...
                    sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                    app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000), ...
                    [0.10 0.55 0.10]);
            catch ME
                fprintf('[MIP-click] err: %s\n', ME.message);
            end
        end

        function onViewer3DDown(app, ~, evt, which_view)
            % Direct hook into viewer3d's own ButtonDownFcn — bypasses
            % the figure WindowButtonDownFcn which the GPU canvas
            % swallows. Fires whenever the user presses left mouse
            % on the rendered volume (or holds shift-left, etc).
            try
                fprintf('[viewer3d-DOWN] view=%s\n', which_view);
                pt = app.UIFigure.CurrentPoint;
                % Run live grow only when armed OR shift held (extend)
                sel = app.UIFigure.SelectionType;
                allow = app.VesselPickArmed || strcmp(sel, 'extend');
                fprintf('  sel=%s armed=%d → allow=%d\n', ...
                    sel, app.VesselPickArmed, allow);
                if ~allow
                    return;
                end
                % Erase tool: ray-cast to the SURFACE hit and carve a
                % ball out of the mask (no live grow). Shift-held
                % (extend) always grows regardless of tool, so the
                % user keeps the TeraRecon hold-to-grow gesture even
                % while Erase is the armed-click default.
                is_erase = strcmp(app.Tool, 'erase') && ~strcmp(sel, 'extend');
                if is_erase
                    flashSegStatus(app, 'Click registered — ray-casting (erase)…', ...
                        [0.70 0.30 0.00]);
                    drawnow;
                    voxel = vol3DClickToVoxel(app, pt, which_view, 'surface');
                    if isempty(voxel)
                        fprintf('  → ray-cast hit nothing\n');
                        flashSegStatus(app, 'Ray cast hit nothing — rotate and try again', ...
                            [0.85 0.30 0.10]);
                        return;
                    end
                    fprintf('  → voxel=[%d %d %d] → erase\n', voxel);
                    eraseVesselAtVoxel(app, voxel);
                    return;
                end
                flashSegStatus(app, 'Click registered — ray-casting…', ...
                    [0.20 0.55 1.00]);
                drawnow;
                voxel = vol3DClickToVoxel(app, pt, which_view);
                if isempty(voxel)
                    fprintf('  → ray-cast hit nothing\n');
                    flashSegStatus(app, 'Ray cast hit nothing — rotate and try again', ...
                        [0.85 0.30 0.10]);
                    return;
                end
                fprintf('  → voxel=[%d %d %d] HU=%d\n', voxel, ...
                    int32(app.D.vol(voxel(1), voxel(2), voxel(3))));
                liveGrowFromSeed(app, voxel);
            catch ME
                fprintf('[onViewer3DDown] err: %s\n', ME.message);
            end
        end

        function onViewer3DUp(app)
            % Direct hook into viewer3d's ClickReleased event.
            % Stops the live grow loop at user's chosen extent.
            try
                if app.LiveGrowActive
                    fprintf('[viewer3d-UP] stop live grow\n');
                    app.LiveGrowActive = false;
                end
            catch
            end
        end

        function liveGrowFromSeed(app, seed)
            % TeraRecon-style live grow. User holds shift+click on
            % the recon → this method runs an iterative dilation
            % grow that yields control between iterations via
            % drawnow. The drawnow processes the WindowButtonUpFcn
            % event when the user releases the mouse, which flips
            % app.LiveGrowActive = false and causes this loop to
            % exit. The user controls final segmentation size by
            % how long they hold the mouse.
            %
            % Each iteration: dilate by sphere(2) within the HU
            % window (HU = seed_HU ± 75), restricted to a bbox
            % around the current mask + small margin (so we don't
            % do morph ops on the full 320M-voxel volume).
            % Convergence: when no new voxels are added the grow
            % auto-stops (already filled the connected vessel
            % within HU window).
            if isempty(seed) || isempty(app.D) || ~isfield(app.D, 'vol')
                return;
            end
            sz = size(app.D.vol);
            seed(1) = max(1, min(sz(1), round(seed(1))));
            seed(2) = max(1, min(sz(2), round(seed(2))));
            seed(3) = max(1, min(sz(3), round(seed(3))));
            seed_HU = double(app.D.vol(seed(1), seed(2), seed(3)));
            tol = max(5, app.GrowTolHU);
            hu_lo = max(0, seed_HU - tol);
            hu_hi = seed_HU + tol;

            fprintf('[liveGrow] seed=[%d %d %d] HU=%.0f range=[%.0f %.0f] tol=%.0f\n', ...
                seed, seed_HU, hu_lo, hu_hi, tol);

            % Set up state
            pushUndo(app);
            ensureMaskLabel(app);
            app.PreviousMaskLabel = app.MaskLabel;
            app.SeedSeg = seed;
            app.SeedSegList{end+1} = seed;
            label = uint8(min(255, app.NextSegLabel));
            app.LastSeedLabel = label;

            % HU window mask. Computing once over the full volume
            % is the slowest step (~1-2 s for a 320M-voxel volume).
            % The dilation iterations after this are fast.
            t_hu = tic;
            hu_ok = (app.D.vol >= hu_lo) & (app.D.vol <= hu_hi);
            fprintf('[liveGrow] HU mask in %.2fs (%d voxels in window)\n', ...
                toc(t_hu), nnz(hu_ok));

            % Initialize mask with seed voxel
            mask = false(sz);
            mask(seed(1), seed(2), seed(3)) = true;

            % Paint initial seed into the labeled mask
            paint = mask & (app.MaskLabel == 0);
            app.MaskLabel(paint) = label;
            app.Mask = app.MaskLabel > 0;

            % Activate live grow
            app.LiveGrowActive       = true;
            app.IsActivelySegmenting = true;
            flashSegStatus(app, 'Live growing — release mouse to stop', ...
                [0.20 0.55 1.00]);

            SE = strel('sphere', 2);   % 2-voxel shell per iteration
            margin = 6;
            iter = 0;
            MAX_ITER = 600;   % hard cap: enough to fill aorta + iliacs
            try
                while app.LiveGrowActive && isvalid(app.UIFigure) ...
                        && iter < MAX_ITER
                    iter = iter + 1;
                    % Bbox of current mask + margin
                    [rr, cc_, ss] = ind2sub(sz, find(mask));
                    if isempty(rr); break; end
                    r1 = max(1, min(rr) - margin);
                    r2 = min(sz(1), max(rr) + margin);
                    c1 = max(1, min(cc_) - margin);
                    c2 = min(sz(2), max(cc_) + margin);
                    s1 = max(1, min(ss) - margin);
                    s2 = min(sz(3), max(ss) + margin);
                    sub_m = mask(r1:r2, c1:c2, s1:s2);
                    sub_h = hu_ok(r1:r2, c1:c2, s1:s2);
                    sub_new = imdilate(sub_m, SE) & sub_h;
                    if isequal(sub_new, sub_m)
                        % converged — no further growth in HU window
                        fprintf('[liveGrow] converged at iter %d\n', iter);
                        break;
                    end
                    mask(r1:r2, c1:c2, s1:s2) = sub_new;

                    % Update labeled mask (don't overwrite earlier clicks)
                    new_paint = mask & (app.MaskLabel == 0);
                    if any(new_paint(:))
                        app.MaskLabel(new_paint) = label;
                        app.Mask = app.MaskLabel > 0;
                    end

                    % Refresh recon (only every other iter to save
                    % per-frame cost; visually still smooth)
                    if mod(iter, 1) == 0
                        if strcmp(app.ViewMode, '3dvol')
                            refreshMaskLabel3DOverlay(app, 'single');
                        elseif strcmp(app.ViewMode, '2x2')
                            refreshMaskLabel3DOverlay(app, 'multi');
                        end
                    end
                    % drawnow processes pending events including
                    % WindowButtonUpFcn → LiveGrowActive = false
                    drawnow;
                end
            catch ME
                fprintf('[liveGrow] error: %s\n', ME.message);
            end

            % Commit
            app.NextSegLabel = app.NextSegLabel + 1;
            app.IsActivelySegmenting = false;
            app.LiveGrowActive = false;

            % Final geodesic dist (so the slider can scrollback after)
            try
                if any(mask(:))
                    seed_idx = sub2ind(sz, seed(1), seed(2), seed(3));
                    Dgeo = bwdistgeodesic(mask, seed_idx);
                    Dgeo(~isfinite(Dgeo)) = -1;
                    app.LastSeedDist    = Dgeo;
                    app.LastSeedMaxDist = max(Dgeo(:));
                    app.LastSeedThreshold = app.LastSeedMaxDist;
                end
            catch
            end

            mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                 app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
            fprintf('[liveGrow] stopped at iter %d, final %.1f mL\n', iter, mL);
            flashSegStatus(app, sprintf('Done — %.1f mL (%d iter)', mL, iter), ...
                [0.10 0.55 0.10]);
            % Final clean redraw
            try
                if strcmp(app.ViewMode, '3dvol')
                    refreshMaskLabel3DOverlay(app, 'single');
                elseif strcmp(app.ViewMode, '2x2')
                    refreshMaskLabel3DOverlay(app, 'multi');
                end
                drawnow;
            catch
            end
        end

        function onVesselSelectClick(app, voxel)
            % Shift-click vessel-select gesture. Same effect as
            % onSegmentSeedClick (region grow → new label) but
            % independent of the workflow Step. Slice indices are
            % updated so the user can immediately see the result on
            % the MPR panes after switching to 2x2.
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            sz = size(app.D.vol);
            voxel(1) = max(1, min(sz(1), round(voxel(1))));
            voxel(2) = max(1, min(sz(2), round(voxel(2))));
            voxel(3) = max(1, min(sz(3), round(voxel(3))));
            app.SeedSeg = voxel;
            app.SeedSegList{end+1} = voxel;
            app.IdxAxial    = voxel(3);
            app.IdxCoronal  = voxel(1);
            app.IdxSagittal = voxel(2);
            runSegmentation(app);
        end

        function eraseVesselAtVoxel(app, voxel)
            % 3-D click-to-erase. The companion of the click-to-grow:
            % when the Erase tool is active, a click on the recon
            % ray-casts to the SURFACE voxel the user pointed at and
            % carves a physically-round ball out of both app.Mask and
            % app.MaskLabel. Radius = the same Brush radius slider, so
            % the user trims leaked bone / vein / table the same way
            % they'd paint in 2-D, but directly on the 3-D surface.
            %
            % Local + bounded by construction: a single click can only
            % remove voxels inside the ball, so it can never nuke the
            % whole connected tree (unlike a connected-component erase).
            % Repeated clicks carve progressively. Reversible — pushUndo
            % is taken before the edit so Undo restores the prior mask.
            if isempty(app.D) || ~isfield(app.D, 'vol') || isempty(app.Mask)
                return;
            end
            sz = size(app.D.vol);
            voxel = round(voxel(:).');
            voxel(1) = max(1, min(sz(1), voxel(1)));
            voxel(2) = max(1, min(sz(2), voxel(2)));
            voxel(3) = max(1, min(sz(3), voxel(3)));

            pushUndo(app);
            R  = max(1, app.BrushRadiusVox);
            % Z radius scaled for anisotropic spacing so the eraser is
            % physically round (slices are usually thicker than pixels).
            Rz = max(1, round(R * app.D.pixel_mm(1) / app.D.slice_spacing_mm));

            r1 = max(1, voxel(1)-R);  r2 = min(sz(1), voxel(1)+R);
            c1 = max(1, voxel(2)-R);  c2 = min(sz(2), voxel(2)+R);
            s1 = max(1, voxel(3)-Rz); s2 = min(sz(3), voxel(3)+Rz);
            [Yc, Xc, Zc] = ndgrid(r1:r2, c1:c2, s1:s2);
            ball = ((Yc - voxel(1))/R ).^2 + ...
                   ((Xc - voxel(2))/R ).^2 + ...
                   ((Zc - voxel(3))/max(Rz,1)).^2 <= 1;

            sub = app.Mask(r1:r2, c1:c2, s1:s2);
            n_removed = nnz(sub & ball);
            sub(ball) = false;
            app.Mask(r1:r2, c1:c2, s1:s2) = sub;
            if ~isempty(app.MaskLabel) && isequal(size(app.MaskLabel), sz)
                subL = app.MaskLabel(r1:r2, c1:c2, s1:s2);
                subL(ball) = 0;
                app.MaskLabel(r1:r2, c1:c2, s1:s2) = subL;
            end

            mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                 app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
            fprintf('[erase3D] voxel=[%d %d %d] R=%d Rz=%d removed=%d → %.1f mL\n', ...
                voxel, R, Rz, n_removed, mL);
            flashSegStatus(app, sprintf('Erased %d voxels — %.1f mL', ...
                n_removed, mL), [0.70 0.30 0.00]);

            redrawCurrentView(app);
            if strcmp(app.ViewMode, '3dvol')
                refreshMaskLabel3DOverlay(app, 'single');
            elseif strcmp(app.ViewMode, '2x2')
                refreshMaskLabel3DOverlay(app, 'multi');
            end
        end

        function voxel = vol3DClickToVoxel(app, fig_pt, which_view, pick_mode)
            % Map a figure-space click on the volshow panel
            % (single-view '3dvol' or 2x2 pane 4) to a voxel in the
            % source volume. Uses ray casting: build the ray from
            % the viewer3d camera basis, march through the volume
            % until we hit a contrast-HU voxel.
            %
            % Approximate: assumes orthographic projection (close
            % enough for AP view + small rotations). Returns [] if
            % the click misses the panel or no contrast voxel is
            % found along the ray.
            %
            % pick_mode (optional):
            %   'grow'    (default) — push 3 voxels into the interior
            %             and snap to the local HU max so the returned
            %             voxel lands in the lumen: the ideal grow seed.
            %   'surface' — return the surface voxel the ray first hit,
            %             with no interior push and no HU-max snap, so
            %             a 3-D erase carves exactly where the user
            %             pointed rather than recentering on a bright
            %             lumen elsewhere.
            if nargin < 4 || isempty(pick_mode); pick_mode = 'grow'; end
            voxel = [];
            if isempty(app.D) || ~isfield(app.D, 'vol'); return; end
            switch which_view
                case 'single'
                    panel = app.VolPanel;
                    src_viewer = app.VolViewer;
                case 'multi'
                    if isempty(app.MultiPanels) || numel(app.MultiPanels) < 4
                        return;
                    end
                    panel = app.MultiPanels{4};
                    src_viewer = app.Multi3DViewer;
                otherwise
                    return;
            end
            if isempty(panel) || ~isvalid(panel); return; end
            if isempty(src_viewer) || ~isvalid(src_viewer); return; end
            v3d = src_viewer.Parent;
            if isempty(v3d) || ~isvalid(v3d); return; end

            % Click position relative to the panel
            % VolPanel and MultiPanels{4} are children of ImagePanel
            % whose own coords are figure-relative. Walk up to get
            % an absolute panel rect.
            abs_pos = panel.Position;
            anc = panel.Parent;
            while ~isempty(anc) && isvalid(anc) && ...
                  isprop(anc, 'Position') && ~isa(anc, 'matlab.ui.Figure')
                abs_pos(1:2) = abs_pos(1:2) + anc.Position(1:2);
                anc = anc.Parent;
            end
            panel_x = fig_pt(1) - abs_pos(1);
            panel_y = fig_pt(2) - abs_pos(2);
            if panel_x < 0 || panel_x > abs_pos(3) || ...
               panel_y < 0 || panel_y > abs_pos(4); return; end

            % Camera basis in volshow's data-coordinate space.
            cp = v3d.CameraPosition; ct = v3d.CameraTarget;
            cu = v3d.CameraUpVector;
            forward = ct - cp;
            if norm(forward) == 0; return; end
            forward = forward / norm(forward);
            right = cross(forward, cu);
            if norm(right) == 0; return; end
            right = right / norm(right);
            up_o = cross(right, forward); up_o = up_o / norm(up_o);

            % Volshow places voxel (iy, ix, iz) at world (col=ix,
            % row=iy, slice=iz) AFTER a flip on axis 3 done by
            % refreshVolViewer / refreshMulti3DPane. The world
            % coordinate iz_world = sz_world(3) - iz_orig + 1.
            sz_world = size(src_viewer.Data);

            % Click point in NDC ([-0.5, 0.5] in each axis)
            ndc_x = panel_x / abs_pos(3) - 0.5;
            ndc_y = panel_y / abs_pos(4) - 0.5;
            % Half-extent in world coords. volshow with CameraZoom=1
            % approximately frames the longest axis. Tighter zooms
            % shrink the half-extent linearly.
            cz = v3d.CameraZoom;
            if isempty(cz) || ~isfinite(cz) || cz <= 0; cz = 1; end
            half_extent = max(sz_world) / (2 * cz);
            % Match panel aspect so X / Y use the right half-extents.
            aspect = abs_pos(3) / max(1, abs_pos(4));
            if aspect >= 1
                hx = half_extent;
                hy = half_extent / aspect;
            else
                hx = half_extent * aspect;
                hy = half_extent;
            end
            % Orthographic ray origin (offset from camera target)
            % and direction (always = forward).
            ray_origin = ct(:).' + 2 * ndc_x * hx * right + ...
                                   2 * ndc_y * hy * up_o;
            % Start the march on the camera side of the volume:
            % move backwards along the view direction by half the
            % volume's max dimension.
            ray_origin = ray_origin - max(sz_world) * forward;
            ray_dir = forward;

            % March through the volume using TeraRecon-style alpha
            % compositing. The volshow renderer accumulates alpha
            % along each ray; what the user "sees" at a screen
            % pixel is the front-most voxel where cumulative
            % opacity passes ~0.5. We replicate that by sampling
            % the same Alphamap the viewer is using and finding
            % the voxel where the running compositing fraction
            % first crosses a threshold.
            %
            % This handles the realistic case where a cortical
            % rib sits in front of the aorta: the rib is opaque,
            % stops the ray, and the user's click lands on the
            % rib surface (not the aorta). They rotate to a view
            % where the aorta is unobstructed and click again —
            % same UX as TeraRecon.
            sz_orig = size(app.D.vol);
            ds_y = sz_orig(1) / sz_world(1);
            ds_x = sz_orig(2) / sz_world(2);
            ds_z = sz_orig(3) / sz_world(3);

            % Pull the actual alpha map the renderer is using.
            % Index the alphamap by quantizing the [0,1]-normalized
            % HU value the renderer is rendering.
            try
                amap = src_viewer.Alphamap;
            catch
                amap = linspace(0, 1, 256)' .^ 1.5;
            end
            if isempty(amap); amap = linspace(0, 1, 256)' .^ 1.5; end
            n_amap = numel(amap);

            step = 1.0;
            n_steps = round(2 * max(sz_world));
            cum_alpha = 0;        % running compositing opacity
            ALPHA_HIT = 0.5;      % "user sees something here"
            % Adjust per-step alpha so a thick uniform structure
            % (~10 voxels) reaches ~95% opacity. With per-step
            % alpha = a, cumulative = 1 - (1-a)^N. For N=10 to
            % reach 0.95 we need a ≈ 0.26 per max-alpha voxel.
            ALPHA_GAIN = 0.30;

            best_k = -1;
            for k = 0:n_steps
                p = ray_origin + k * step * ray_dir;
                ix_w = round(p(1)); iy_w = round(p(2)); iz_w = round(p(3));
                if ix_w < 1 || ix_w > sz_world(2); continue; end
                if iy_w < 1 || iy_w > sz_world(1); continue; end
                if iz_w < 1 || iz_w > sz_world(3); continue; end
                v = src_viewer.Data(iy_w, ix_w, iz_w);
                % Quantize v ∈ [0,1] to alphamap index.
                idx = max(1, min(n_amap, 1 + floor(v * (n_amap - 1))));
                a_v = double(amap(idx)) * ALPHA_GAIN;
                if a_v <= 0; continue; end
                cum_alpha = cum_alpha + (1 - cum_alpha) * a_v;
                if cum_alpha >= ALPHA_HIT
                    best_k = k;
                    break;
                end
            end
            if best_k < 0
                fprintf('[ray-cast] no alpha-hit (cum=%.2f) — ray passed through transparent volume\n', cum_alpha);
                return;
            end

            % Step a few voxels deeper to land in the structure
            % interior (avoid the wall / surface boundary). For a
            % vessel this puts us in the lumen, which has the
            % highest local HU — perfect seed for the grow. In
            % 'surface' mode (erase) we keep the front-most hit so
            % the carve lands exactly where the user pointed.
            if strcmpi(pick_mode, 'surface')
                interior_push = 0;
            else
                interior_push = 3;
            end
            best_k = best_k + interior_push;
            p = ray_origin + best_k * step * ray_dir;
            ix_w = round(p(1)); iy_w = round(p(2)); iz_w = round(p(3));
            ix_w = max(1, min(sz_world(2), ix_w));
            iy_w = max(1, min(sz_world(1), iy_w));
            iz_w = max(1, min(sz_world(3), iz_w));

            % Map back to source-volume coords (reverse Z-flip).
            iy_o = max(1, min(sz_orig(1), round(iy_w * ds_y)));
            ix_o = max(1, min(sz_orig(2), round(ix_w * ds_x)));
            iz_o_flipped = round(iz_w * ds_z);
            iz_o = sz_orig(3) - iz_o_flipped + 1;
            iz_o = max(1, min(sz_orig(3), iz_o));

            if strcmpi(pick_mode, 'surface')
                % No HU-max snap: erase exactly where the ray hit.
                voxel = [iy_o, ix_o, iz_o];
                fprintf('[ray-cast/surface] alpha-hit k=%d (cum=%.2f) → orig(%d,%d,%d) HU=%d\n', ...
                    best_k, cum_alpha, iy_o, ix_o, iz_o, ...
                    int32(app.D.vol(voxel(1), voxel(2), voxel(3))));
                return;
            end

            % Snap to local 3-D HU max in a small ball (recenter
            % on lumen). 4-voxel radius ≈ 3 mm.
            R = 4;
            r1 = max(1, iy_o - R); r2 = min(sz_orig(1), iy_o + R);
            c1 = max(1, ix_o - R); c2 = min(sz_orig(2), ix_o + R);
            s1 = max(1, iz_o - R); s2 = min(sz_orig(3), iz_o + R);
            sub = app.D.vol(r1:r2, c1:c2, s1:s2);
            [~, lin] = max(sub(:));
            [dr, dc, dz] = ind2sub(size(sub), lin);
            voxel = [r1 + dr - 1, c1 + dc - 1, s1 + dz - 1];

            fprintf('[ray-cast] alpha-hit at k=%d (cum=%.2f) → orig(%d,%d,%d) → snap(%d,%d,%d) HU=%d\n', ...
                best_k, cum_alpha, iy_o, ix_o, iz_o, ...
                voxel(1), voxel(2), voxel(3), int32(app.D.vol(voxel(1), voxel(2), voxel(3))));
        end

        % --- Display modifications (scalpel, bone strip) -------------
        function ensureDisplayExclusion(app)
            sz = size(app.D.vol);
            if isempty(app.DisplayExclusion) || ~isequal(size(app.DisplayExclusion), sz)
                app.DisplayExclusion = false(sz);
            end
        end

        function ensurePendingMask(app)
            sz = size(app.D.vol);
            if isempty(app.PendingMask) || ~isequal(size(app.PendingMask), sz)
                app.PendingMask = false(sz);
            end
        end

        function paintMaskFromSliderThreshold(app)
            % Apply the current LastSeedThreshold to repaint the
            % MaskLabel for the most recent click. Anything in the
            % geodesic-distance map within threshold gets the
            % LastSeedLabel; voxels outside the threshold revert
            % to the previous mask state.
            if isempty(app.LastSeedDist) || isempty(app.PreviousMaskLabel)
                return;
            end
            % Reset to pre-click state
            app.MaskLabel = app.PreviousMaskLabel;
            % Mask of voxels included at this threshold
            within = app.LastSeedDist >= 0 & ...
                     app.LastSeedDist <= app.LastSeedThreshold;
            % Only paint voxels not already labeled by a prior click
            paint = within & (app.MaskLabel == 0);
            app.MaskLabel(paint) = app.LastSeedLabel;
            app.Mask = app.MaskLabel > 0;
            % Update the seg_status text with current grow extent
            mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                 app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
            stat = findobj(app.SideContent, 'Tag', 'seg_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = sprintf( ...
                    'Selected %.1f mL  (%d clicks)  •  grow size %.0f / %.0f', ...
                    mL, app.NextSegLabel - 1, ...
                    app.LastSeedThreshold, app.LastSeedMaxDist);
            end
            redrawCurrentView(app);
            if strcmp(app.ViewMode, '3dvol')
                refreshMaskLabel3DOverlay(app, 'single');
            elseif strcmp(app.ViewMode, '2x2')
                refreshMaskLabel3DOverlay(app, 'multi');
            end
        end

        function animateGrowReveal(app)
            % TeraRecon-style live grow spread.
            %
            % Precondition: LastSeedDist + LastSeedMaxDist + LastSeedLabel
            % + PreviousMaskLabel are all populated (called from the
            % end of runSegmentation, after the mask + geodesic
            % distance map have been computed).
            %
            % Plays a smooth animation of voxels appearing in
            % expanding-shell order from the seed. Frame budget is
            % bounded by ANIM_TARGET_SEC; per-frame redraw is the
            % bottleneck on viewer3d so we cap N_FRAMES.
            if isempty(app.LastSeedDist) || app.LastSeedMaxDist <= 0
                return;
            end
            % Don't animate while in 2x2 — the multi-pane redraw is
            % too slow for a smooth animation. Snap to final state.
            if ~strcmp(app.ViewMode, '3dvol')
                return;
            end
            ANIM_TARGET_SEC = 1.6;
            N_FRAMES = 18;
            t_per_frame = ANIM_TARGET_SEC / N_FRAMES;
            % Use a slightly easing curve so the late shells (where
            % each new shell adds many voxels) don't render too fast.
            % Frame i ∈ [0, 1] → distance threshold = max * i^0.7
            for i = 1:N_FRAMES
                t = i / N_FRAMES;
                eased = t ^ 0.8;
                app.LastSeedThreshold = eased * app.LastSeedMaxDist;
                paintMaskFromSliderThreshold(app);
                drawnow;
                pause(max(0, t_per_frame));
            end
        end

        function setGrowSliderValue(app, frac)
            % Slider callback. frac = 0..1 = fraction of full grow extent.
            if isempty(app.LastSeedDist); return; end
            app.LastSeedThreshold = max(0, frac) * app.LastSeedMaxDist;
            paintMaskFromSliderThreshold(app);
        end

        function cancelLastClick(app)
            % Revert the most recent click entirely. Also pops one
            % entry off the undo stack to undo the pushUndo done at
            % click start.
            if isempty(app.PreviousMaskLabel); return; end
            app.MaskLabel = app.PreviousMaskLabel;
            app.Mask = app.MaskLabel > 0;
            app.LastSeedDist = [];
            app.LastSeedMaxDist = 0;
            app.LastSeedThreshold = 0;
            if app.NextSegLabel > 1
                app.NextSegLabel = app.NextSegLabel - 1;
            end
            redrawCurrentView(app);
            if strcmp(app.ViewMode, '3dvol')
                refreshMaskLabel3DOverlay(app, 'single');
            elseif strcmp(app.ViewMode, '2x2')
                refreshMaskLabel3DOverlay(app, 'multi');
            end
            stat = findobj(app.SideContent, 'Tag', 'seg_status');
            if ~isempty(stat) && isvalid(stat)
                mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                     app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
                stat.Text = sprintf('Cancelled last click. Total %.1f mL', mL);
            end
        end

        function ensureMaskLabel(app)
            sz = size(app.D.vol);
            if isempty(app.MaskLabel) || ~isequal(size(app.MaskLabel), sz)
                app.MaskLabel    = zeros(sz, 'uint8');
                app.NextSegLabel = 1;
            end
        end

        function clearActiveSegmenting(app)
            % Cleared via onCleanup at the end of runSegmentation
            % (or on exception). Reverts the recon from the blue
            % "in progress" tint back to IsolatedVesselColor.
            if ~isvalid(app); return; end
            app.IsActivelySegmenting = false;
            try
                if app.Step > 2 && ~isempty(app.Mask) && any(app.Mask(:))
                    if strcmp(app.ViewMode, '3dvol')
                        initVolumeView(app);
                    end
                end
            catch
            end
        end

        function setIsolatedVesselColor(app, rgb)
            % Public setter for the right-click "Change color" menu.
            % rgb is a 1×3 double in [0, 1].
            if isnumeric(rgb) && numel(rgb) == 3
                app.IsolatedVesselColor = double(rgb(:).');
                if app.Step > 2 && strcmp(app.ViewMode, '3dvol') && ...
                        ~isempty(app.Mask) && any(app.Mask(:))
                    initVolumeView(app);
                end
            end
        end

        function pickIsolatedVesselColor(app)
            % Open uisetcolor and apply if the user picks one.
            try
                rgb = uisetcolor(app.IsolatedVesselColor, ...
                    'Choose vessel color');
                if isnumeric(rgb) && numel(rgb) == 3
                    setIsolatedVesselColor(app, rgb);
                end
            catch ME
                fprintf('pickIsolatedVesselColor failed: %s\n', ME.message);
            end
        end

        function showVesselContextMenu(app, ~, ~)
            % Right-click context menu attached to the 3-D recon
            % volshow / VolPanel. Offers: change color, restore
            % default color, clear segmentation, switch to MPR view.
            try
                if isempty(app.VolPanel) || ~isvalid(app.VolPanel)
                    return;
                end
                cm = uicontextmenu(app.UIFigure);
                uimenu(cm, 'Text', 'Change vessel color…', ...
                    'MenuSelectedFcn', @(~,~) pickIsolatedVesselColor(app));
                m_pre = uimenu(cm, 'Text', 'Preset colors');
                presets = { ...
                    'Light coral-red (default)', [1.00 0.42 0.32]; ...
                    'Bright red',                [0.90 0.15 0.15]; ...
                    'Orange',                    [1.00 0.55 0.10]; ...
                    'Pink',                      [1.00 0.55 0.75]; ...
                    'Bright blue',               [0.20 0.55 1.00]; ...
                    'Lime',                      [0.40 1.00 0.30]; ...
                    'Cyan',                      [0.10 0.85 0.95]; ...
                    'Yellow',                    [1.00 0.95 0.20]; ...
                    'White',                     [0.95 0.95 0.95]};
                for k = 1:size(presets, 1)
                    uimenu(m_pre, 'Text', presets{k, 1}, ...
                        'MenuSelectedFcn', @(~,~) setIsolatedVesselColor(app, presets{k, 2}));
                end
                uimenu(cm, 'Text', 'Restore default color', ...
                    'Separator', 'on', ...
                    'MenuSelectedFcn', @(~,~) setIsolatedVesselColor(app, [1.00 0.42 0.32]));
                uimenu(cm, 'Text', 'Clear segmentation', ...
                    'Separator', 'on', ...
                    'MenuSelectedFcn', @(~,~) clearMask(app));
                uimenu(cm, 'Text', 'Back to MPR (2x2 view)', ...
                    'MenuSelectedFcn', @(~,~) setViewMode(app, '2x2'));
                app.VolPanel.ContextMenu = cm;
                % open at current pointer location
                try
                    cm.Visible = 'on';
                catch
                end
            catch ME
                fprintf('showVesselContextMenu failed: %s\n', ME.message);
            end
        end

        function L = labelSlice(app, idx, view_mode)
            % Mirror sliceMask's orientation logic but for the
            % uint8 MaskLabel volume. Returns an empty array when
            % no label volume is set yet so compositeView's
            % `use_labels` check stays cheap.
            if isempty(app.MaskLabel) || ~any(app.MaskLabel(:))
                L = [];
                return;
            end
            switch view_mode
                case 'axial'
                    L = app.MaskLabel(:, :, idx);
                case 'coronal'
                    L = squeeze(app.MaskLabel(idx, :, :)).';
                case 'sagittal'
                    L = squeeze(app.MaskLabel(:, idx, :)).';
                otherwise
                    L = [];
            end
        end

        function armScalpel(app)
            if strcmp(app.ViewMode, '3dvol')
                uialert(app.UIFigure, ...
                    'Switch to a slice or MIP view to use the scalpel.', ...
                    'Scalpel');
                return;
            end
            app.ScalpelArmed = true;
            stat = findobj(app.SideContent, 'Tag', 'disp_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = ['Scalpel armed — draw a polygon on the ' ...
                             'image. Double-click to close.'];
                stat.FontColor = [0.6 0.30 0];
            end
            % Drive the polygon ROI in a separate call so the user can
            % cancel by hitting Escape or clicking off-axes.
            try
                roi = drawpolygon(app.MainAxes, 'Color', [1 0.4 0.1], ...
                                  'LineWidth', 2);
                if isempty(roi.Position) || size(roi.Position, 1) < 3
                    delete(roi); app.ScalpelArmed = false; return;
                end
                applyScalpel(app, roi.Position);
                delete(roi);
            catch
                % drawpolygon errors out if the user cancels — fine
            end
            app.ScalpelArmed = false;
            stat = findobj(app.SideContent, 'Tag', 'disp_status');
            if ~isempty(stat) && isvalid(stat)
                vol_ex = sum(app.DisplayExclusion(:)) * app.D.pixel_mm(1) * ...
                    app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
                stat.Text = sprintf('Hidden from display: %.0f mL', vol_ex);
                stat.FontColor = [0 0.4 0];
            end
        end

        function applyScalpel(app, poly_xy)
            % poly_xy: N×2 polygon vertices in image (column,row) coords
            % of the current view. We rasterize → 2D mask, then sweep
            % the orthogonal volume axis to set DisplayExclusion = true.
            ensureDisplayExclusion(app);
            sz = size(app.D.vol);
            % Convert polygon to a 2D mask matching the image we're on
            switch app.ViewMode
                case 'axial'
                    [Xg, Yg] = meshgrid(1:sz(2), 1:sz(1));
                    inpoly = inpolygon(Xg, Yg, poly_xy(:,1), poly_xy(:,2));
                    % Local to the current axial slice only — matches
                    % the user's intent of "remove what I see here"
                    app.DisplayExclusion(:, :, app.IdxAxial) = ...
                        app.DisplayExclusion(:, :, app.IdxAxial) | inpoly;
                case 'coronal'
                    % Image is X (cols) × Z (rows after transpose). We
                    % sweep through ALL Y values to strip a slab — this
                    % is the rib-strip gesture.
                    [Xg, Zg] = meshgrid(1:sz(2), 1:sz(3));
                    inpoly = inpolygon(Xg, Zg, poly_xy(:,1), poly_xy(:,2));
                    inpoly_xz = inpoly.';   % match the displayed orientation
                    for y = 1:sz(1)
                        slab = squeeze(app.DisplayExclusion(y, :, :));
                        app.DisplayExclusion(y, :, :) = slab | inpoly_xz;
                    end
                case 'sagittal'
                    % Image is Y (cols) × Z (rows after transpose).
                    % Sweep through ALL X to strip a slab.
                    [Yg, Zg] = meshgrid(1:sz(1), 1:sz(3));
                    inpoly = inpolygon(Yg, Zg, poly_xy(:,1), poly_xy(:,2));
                    inpoly_yz = inpoly.';
                    for x = 1:sz(2)
                        slab = squeeze(app.DisplayExclusion(:, x, :));
                        app.DisplayExclusion(:, x, :) = slab | inpoly_yz;
                    end
                case '3d'
                    % MIP coronal view: same as coronal slab strip but
                    % global (all Y).
                    [Xg, Zg] = meshgrid(1:sz(2), 1:sz(3));
                    inpoly = inpolygon(Xg, Zg, poly_xy(:,1), poly_xy(:,2));
                    inpoly_xz = inpoly.';
                    for y = 1:sz(1)
                        slab = squeeze(app.DisplayExclusion(y, :, :));
                        app.DisplayExclusion(y, :, :) = slab | inpoly_xz;
                    end
            end
            % Also remove these voxels from the Mask if they leaked there
            app.Mask = app.Mask & ~app.DisplayExclusion;
            if ~isempty(app.PendingMask)
                app.PendingMask = app.PendingMask & ~app.DisplayExclusion;
            end
            refreshMain(app);
        end

        function removeBoneFromDisplay(app)
            ensureDisplayExclusion(app);
            % Bone is reliably > 600 HU in CT. We OR into the existing
            % exclusion so chained scalpel + bone-strip work together.
            bone = app.D.vol > 600;
            app.DisplayExclusion = app.DisplayExclusion | bone;
            app.Mask = app.Mask & ~app.DisplayExclusion;
            refreshMain(app);
            stat = findobj(app.SideContent, 'Tag', 'disp_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = sprintf('Bone removed (%.0f mL hidden)', ...
                    sum(app.DisplayExclusion(:)) * app.D.pixel_mm(1) * ...
                    app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000);
                stat.FontColor = [0 0.4 0];
            end
        end

        function resetDisplayExclusion(app)
            sz = size(app.D.vol);
            app.DisplayExclusion = false(sz);
            refreshMain(app);
            stat = findobj(app.SideContent, 'Tag', 'disp_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = 'Display reset — all voxels visible.';
                stat.FontColor = [0.4 0.4 0.4];
            end
        end

        % --- Shift-chain selection -----------------------------------
        function toggleShiftMode(app, val)
            app.ShiftMode = logical(val);
            if app.ShiftMode
                ensurePendingMask(app);
            end
            % Update the side-panel status label if present
            stat = findobj(app.SideContent, 'Tag', 'shift_status');
            if ~isempty(stat) && isvalid(stat)
                if app.ShiftMode
                    stat.Text = ['Shift-chain ON — clicks build a yellow ' ...
                                 'preview; press Select to commit.'];
                    stat.FontColor = [0.55 0.30 0];
                else
                    stat.Text = '';
                end
            end
        end

        function commitPendingMask(app)
            if isempty(app.PendingMask) || ~any(app.PendingMask(:))
                uialert(app.UIFigure, ...
                    'Nothing to commit — click in shift-chain mode first.', ...
                    'Empty selection');
                return;
            end
            pushUndo(app);
            app.Mask = app.Mask | app.PendingMask;
            app.PendingMask = false(size(app.D.vol));
            % Auto-disable shift-mode so the next click goes straight
            % to Mask (matches TeraRecon — releasing Shift exits the
            % accumulator).
            app.ShiftMode = false;
            refreshMain(app);
            buildStep2(app);
        end

        function cancelPendingMask(app)
            app.PendingMask = false(size(app.D.vol));
            refreshMain(app);
            buildStep2(app);
        end

        function confirmSeedSubstep(app)
            switch app.SegSubStep
                case 1
                    app.SegSubStep = 2;
                    setViewMode(app, 'coronal');
                case 2
                    app.SegSubStep = 3;
                    setViewMode(app, 'sagittal');
                case 3
                    app.SegSubStep = 4;
                    % stay on sagittal so user can see what they confirmed
            end
            refreshMain(app);
            buildStep2(app);
        end

        function moveSeedSubstep(app)
            % "Move" is mostly instructional — clicking again will
            % automatically reposition the dot. We refresh the status
            % so the user knows to click again.
            stat = findobj(app.SideContent, 'Tag', 'seed_flow_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = 'Click again on the image to move the red dot.';
                stat.FontColor = [0.55 0.30 0];
            end
        end

        function cancelSeedFlow(app)
            % Reset to the start of the 3-view flow. Mask is preserved
            % (so the user can still refine an existing segmentation),
            % but the candidate seed and substep are wiped.
            app.PendingSeed = [];
            app.SegSubStep  = 0;
            setViewMode(app, 'axial');
            refreshMain(app);
            buildStep2(app);
        end

        function startSegmentationFlow(app)
            if isempty(app.PendingSeed) || app.SegSubStep < 4
                uialert(app.UIFigure, ...
                    'Confirm the seed in all three views first.', ...
                    'Seed not confirmed');
                return;
            end
            % Promote PendingSeed to the active seed and run.
            app.SeedSeg = app.PendingSeed;
            app.SeedSegList{end+1} = app.PendingSeed;
            app.PendingSeed = [];
            runSegmentation(app);
            % After segmentation, drop into refinement mode.
            app.SegSubStep = 5;
            buildStep2(app);
        end

        function rerunSegmentation(app)
            if isempty(app.SeedSeg)
                uialert(app.UIFigure, ...
                    'Click inside the aorta first to set a seed.', 'No seed');
                return;
            end
            runSegmentation(app);
        end

        function runSegmentation(app)
            % Mark this segmentation as actively in progress so the
            % 3-D recon (and 2-D overlays) tint blue while the grow
            % is computing. Cleared in the catch block and after the
            % final redraw so the recon reverts to the user's
            % default IsolatedVesselColor.
            app.IsActivelySegmenting = true;
            % Quick visual cue: refresh the recon NOW (before the
            % heavy compute) so the user sees the blue tint
            % indicating "I'm working on it."
            try
                if app.Step > 2 && ~isempty(app.Mask) && any(app.Mask(:))
                    if strcmp(app.ViewMode, '3dvol')
                        initVolumeView(app);
                    end
                end
            catch
            end
            cleanupActive = onCleanup(@() clearActiveSegmenting(app));
            % Fast path — HU threshold + connected component from seed.
            % Runs in <1 s on a typical CTA. Honors DisplayExclusion so
            % the region grow can't leak through hidden voxels (ribs,
            % EKG leads, table).
            %
            % Each click writes its territory into MaskLabel with a
            % new label value; voxels already claimed by a previous
            % click stay with their original label (so the user can
            % see what each click added, and earlier clicks aren't
            % overwritten). app.Mask is the union (MaskLabel > 0) and
            % stays in sync for backward compat with the rest of the
            % pipeline.
            try
                pushUndo(app);
                % Seed-adaptive HU. Trust the click — the user
                % knows their anatomy. No spatial corridor and no
                % bone exclusion: the grow goes wherever the
                % connectivity takes it. If it over-shoots, the
                % "Grow size" slider in the side panel scrolls it
                % back down toward the seed (TeraRecon-style).
                seed_HU = double(app.D.vol(app.SeedSeg(1), ...
                                           app.SeedSeg(2), ...
                                           app.SeedSeg(3)));
                tol = max(5, app.GrowTolHU);
                hu_lo = max(0, seed_HU - tol);
                hu_hi = seed_HU + tol;
                fprintf('[runSegmentation] seed=[%d %d %d]  HU=%.0f  range=[%.0f, %.0f]  tol=%.0f\n', ...
                    app.SeedSeg, seed_HU, hu_lo, hu_hi, tol);
                opts = struct('HU_min', hu_lo, ...
                              'HU_max', hu_hi, ...
                              'close_radius', 0, ...
                              'max_volume_mL', 5000, ...   % effectively no cap; slider tames it
                              'no_snap', true);
                [m, info] = preprocess.seg_aorta_fast(app.D, app.SeedSeg, opts);
                if ~isempty(app.DisplayExclusion) && any(app.DisplayExclusion(:))
                    m = m & ~app.DisplayExclusion;
                end

                % Two-pass HU + Z-zoned morph cleanup. The lumen at
                % the EIA/CFA can drop into HU 500-625 (still
                % contrast, just narrower lumen → less averaging
                % effect). A single pass at HU=seed±75 catches the
                % aorta and proximal iliacs but stops at one or
                % both EIAs. Solution: pass-1 cleans the high-HU
                % core; pass-2 grows from that core into adjacent
                % HU=seed±200 voxels (imreconstruct with marker=core,
                % mask=core|weak), then re-applies the Z-zoned
                % morphological cleanup so the relaxed HU doesn't
                % re-connect bone bridges. Validated on JohnDoe1 CT
                % 2026-05-09: 154 mL one-pass mask captured left
                % EIA only; two-pass = 183 mL captures BOTH iliacs
                % all the way down to the inguinal ligament.
                %
                % Z-zoning rationale: open(sphere(3)) above the
                % seed kills spine/rib bridges; open(sphere(1))
                % below the seed preserves narrow distal vessels
                % (pelvis bones overlap less of the CFA HU range
                % than vertebrae overlap aorta).
                if any(m(:))
                    % Crop to bbox-of-flood + margin for speed.
                    % Working at full 512×512×1219 makes morph ops
                    % take ~40s; cropping to the flood's bbox cuts
                    % that to ~5s. Volume HU values for the
                    % 2nd-pass weak-contrast mask are also cropped
                    % to the same window so we don't reach into
                    % unrelated anatomy.
                    sz_full = size(m);
                    [rr, cc_, ss] = ind2sub(sz_full, find(m));
                    margin = 8;
                    r1 = max(1, min(rr) - margin);  r2 = min(sz_full(1), max(rr) + margin);
                    c1 = max(1, min(cc_) - margin); c2 = min(sz_full(2), max(cc_) + margin);
                    s1 = max(1, min(ss) - margin);  s2 = min(sz_full(3), max(ss) + margin);
                    m_crop = m(r1:r2, c1:c2, s1:s2);
                    seed_local = [app.SeedSeg(1)-r1+1, ...
                                  app.SeedSeg(2)-c1+1, ...
                                  app.SeedSeg(3)-s1+1];
                    seed_z_local = seed_local(3);
                    seed_lin_local = sub2ind(size(m_crop), seed_local(1), ...
                                                          seed_local(2), ...
                                                          seed_local(3));

                    % --- Pass 1: clean core from tight HU flood
                    m1_above = imopen(m_crop, strel('sphere', 2));
                    m1_below = imopen(m_crop, strel('sphere', 1));
                    m1_zoned = false(size(m_crop));
                    m1_zoned(:,:,1:seed_z_local)     = m1_above(:,:,1:seed_z_local);
                    m1_zoned(:,:,seed_z_local+1:end) = m1_below(:,:,seed_z_local+1:end);
                    m1_zoned(seed_local(1), seed_local(2), seed_local(3)) = true;
                    cc1 = bwconncomp(m1_zoned, 6);
                    core = false(size(m_crop));
                    for ii = 1:cc1.NumObjects
                        if any(cc1.PixelIdxList{ii} == seed_lin_local)
                            core(cc1.PixelIdxList{ii}) = true;
                            break;
                        end
                    end
                    core = imdilate(core, strel('sphere', 2)) & m_crop;

                    % --- Pass 2: extend into the weak lumen. The
                    % relaxed window is the user tolerance + 25 HU so
                    % a tighter "Grow tolerance" also tightens pass 2.
                    relax_lo = max(0, seed_HU - (tol + 25));
                    relax_hi = seed_HU + (tol + 25);
                    vol_crop = app.D.vol(r1:r2, c1:c2, s1:s2);
                    weak = (vol_crop >= relax_lo) & (vol_crop <= relax_hi);
                    if ~isempty(app.DisplayExclusion) && any(app.DisplayExclusion(:))
                        excl_crop = app.DisplayExclusion(r1:r2, c1:c2, s1:s2);
                        weak = weak & ~excl_crop;
                    end
                    extend_pool = core | weak;
                    extended = imreconstruct(core, extend_pool, 6);

                    % Re-zone clean. Open more aggressively above
                    % the seed (sphere(3)) since the relaxed HU
                    % opens up wider bone bridges.
                    e_above = imopen(extended, strel('sphere', 3));
                    e_below = imopen(extended, strel('sphere', 1));
                    e_zoned = false(size(extended));
                    e_zoned(:,:,1:seed_z_local)     = e_above(:,:,1:seed_z_local);
                    e_zoned(:,:,seed_z_local+1:end) = e_below(:,:,seed_z_local+1:end);
                    e_zoned(seed_local(1), seed_local(2), seed_local(3)) = true;
                    cc2 = bwconncomp(e_zoned, 6);
                    keep_local = false(size(extended));
                    for ii = 1:cc2.NumObjects
                        if any(cc2.PixelIdxList{ii} == seed_lin_local)
                            keep_local(cc2.PixelIdxList{ii}) = true;
                            break;
                        end
                    end
                    keep_local = imdilate(keep_local, strel('sphere', 2)) & extended;

                    if any(keep_local(:))
                        % Re-embed back into full-volume coordinate frame
                        keep_full = false(sz_full);
                        keep_full(r1:r2, c1:c2, s1:s2) = keep_local;
                        nz_in = nnz(m); nz_out = nnz(keep_full);
                        m = keep_full;
                        fprintf('  2-pass clean: %d → core=%d → %d vox (%.1f mL)\n', ...
                            nz_in, nnz(core), nz_out, nz_out * app.D.pixel_mm(1) * ...
                            app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000);
                    end
                end

                ensureMaskLabel(app);
                % Snapshot the prior MaskLabel so the slider can
                % scroll the grow up and down without losing
                % previously committed clicks.
                app.PreviousMaskLabel = app.MaskLabel;

                % Compute geodesic distance from the seed within
                % the grow. Voxels closer to the seed (small dist)
                % are the "core" of the segment; far voxels are
                % the periphery / leak. The slider thresholds this.
                if any(m(:))
                    fprintf('  computing geodesic distance from seed...\n');
                    t_dist = tic;
                    seed_idx = sub2ind(size(m), app.SeedSeg(1), ...
                                                app.SeedSeg(2), ...
                                                app.SeedSeg(3));
                    Dgeo = bwdistgeodesic(m, seed_idx);
                    fprintf('  done in %.1fs\n', toc(t_dist));
                    Dgeo(~isfinite(Dgeo)) = -1;
                    app.LastSeedDist = Dgeo;
                    app.LastSeedMaxDist = max(Dgeo(:));
                    app.LastSeedLabel = uint8(min(255, app.NextSegLabel));
                    % --- TeraRecon-style ANIMATED reveal -----------------
                    % Now that the heavy compute is done, replay the
                    % geodesic-distance-ordered reveal as a 2s
                    % animation: voxels appear in expanding-shell
                    % order from the seed. Visually identical to
                    % watching a region-grow spread in real time
                    % (we precomputed the answer atomically; this
                    % is the playback). The slider can scrub
                    % through the same range manually after.
                    animateGrowReveal(app);
                    % Final state = full grow at max distance
                    app.LastSeedThreshold = app.LastSeedMaxDist;
                    paintMaskFromSliderThreshold(app);
                    app.NextSegLabel = app.NextSegLabel + 1;
                else
                    app.LastSeedDist    = [];
                    app.LastSeedMaxDist = 0;
                end

                stat = findobj(app.SideContent, 'Tag', 'seg_status');
                if ~isempty(stat) && isvalid(stat)
                    total_mL = sum(app.Mask(:)) * app.D.pixel_mm(1) * ...
                               app.D.pixel_mm(2) * app.D.slice_spacing_mm / 1000;
                    n_clicks = max(0, app.NextSegLabel - 1);
                    msg = sprintf( ...
                        'Selected %.1f mL  (%d clicks)  •  last +%.1f mL in %.2f s', ...
                        total_mL, n_clicks, ...
                        info.picked_volume_mL, info.processing_time);
                    if info.leaked
                        msg = [msg '  ⚠ leak — narrow HU range or undo'];
                        stat.FontColor = [0.7 0.30 0];
                    else
                        stat.FontColor = [0 0.4 0];
                    end
                    stat.Text = msg;
                end
                redrawCurrentView(app);
                % Repaint the colored mask onto whichever 3-D recon
                % is currently active (single-view 3D Volume or 2x2
                % pane 4) — the user expects to see the new region
                % immediately on the surface they just clicked.
                if strcmp(app.ViewMode, '3dvol')
                    refreshMaskLabel3DOverlay(app, 'single');
                elseif strcmp(app.ViewMode, '2x2')
                    refreshMaskLabel3DOverlay(app, 'multi');
                end
            catch ME
                uialert(app.UIFigure, ME.message, 'Segmentation failed');
            end
        end

        function clearMask(app)
            pushUndo(app);
            app.Mask = false(size(app.D.vol));
            app.MaskLabel = zeros(size(app.D.vol), 'uint8');
            app.NextSegLabel = 1;
            app.SeedSeg = [];
            app.SeedSegList = {};
            app.PendingSeed = [];
            app.SegSubStep = 0;
            redrawCurrentView(app);
            buildStep2(app);
        end

        function finishStep2(app)
            if ~any(app.Mask(:))
                uialert(app.UIFigure, ...
                    'Segment the aorta first by clicking inside it.', ...
                    'No segmentation');
                return;
            end
            % Stonko workflow spec, in order:
            %   1. tighten the segmentation mask to contrast-vessel HU
            %      (drop bone — common contamination from manual HU
            %      thresholding without TotalSegmentator),
            %   2. crop the FOV to that cleaned mask (visceral aorta →
            %      CFAs + 10 cm superior, ~3 cm inferior),
            %   3. hide all anatomy outside the vessel mask in the
            %      3-D recon (DisplayExclusion = ~mask). Original HU
            %      stays in app.D.vol so we never lose data, and the
            %      CTA Recon transfer function renders the visible
            %      voxels in the saturated red-orange contrast band.
            % Centerline is NOT auto-run here — Steps 3 and 4 still own
            % seed-picking + centerline. Get the visualization right
            % first, then run the pipeline.
            d = uiprogressdlg(app.UIFigure, 'Title', 'Preparing case…', ...
                'Message', 'Cleaning mask + cropping FOV', ...
                'Indeterminate', 'on');
            try
                % --- 1. tighten mask to contrast-vessel HU range ---
                % CTA contrast lumen is ~150–500 HU. Bone starts ~400
                % and bright cortical bone is ~1000+. The HU 500 cap
                % strips bone from a manually-thresholded mask while
                % keeping the vessel lumen. TotalSegmentator output is
                % already vessel-only so this is a no-op for it.
                vessel_hu_lo = 100;
                vessel_hu_hi = 500;
                vessel_only = app.Mask & ...
                    app.D.vol >= vessel_hu_lo & app.D.vol <= vessel_hu_hi;
                if any(vessel_only(:))
                    n_before = sum(app.Mask(:));
                    n_after  = sum(vessel_only(:));
                    fprintf('[finishStep2] mask cleaned: %d → %d voxels (%.0f%% kept)\n', ...
                        n_before, n_after, 100*n_after/max(n_before,1));
                    app.Mask = vessel_only;
                else
                    fprintf('[finishStep2] mask had no contrast-HU voxels — keeping original\n');
                end

                % --- 2. crop to mask ---
                [D2, mask2, info] = preprocess.auto_crop_to_mask(app.D, app.Mask);
                fprintf('[finishStep2] crop %s → %s (%.1f%% of vol)\n', ...
                    mat2str(info.original_size), mat2str(size(D2.vol)), ...
                    100 * info.reduction_pct);
                app.D    = D2;
                app.Mask = mask2;
                sz = size(D2.vol);
                app.PendingMask = false(sz);

                % --- 3. hide non-vessel anatomy in the 3-D recon ---
                app.DisplayExclusion = ~mask2;
                fprintf(['[finishStep2] DisplayExclusion: %d voxels hidden, ' ...
                         '%d voxels visible (mask), vol size %s\n'], ...
                    sum(app.DisplayExclusion(:)), sum(mask2(:)), ...
                    mat2str(size(app.D.vol)));

                % --- 4. extend each side's CFA terminus to the FOV
                % bottom or contrast dropout. TS --fast leaves the
                % iliac labels truncated above the inguinal ligament;
                % extend_and_detect_branches grows them by ~25 mm but
                % the user's goal explicitly requires the segmentation
                % to reach the common femoral arteries. This step
                % adds slice-by-slice extension constrained to each
                % side's x-band (anchored on the side's CFA terminus,
                % with a hard barrier at the midpoint between the two
                % termini so the L extension can never cross over to
                % the R side and vice versa).
                d.Message = 'Extending iliacs/CFAs to femoral level…';
                drawnow;
                try
                    if ~isempty(app.MaskLabel)
                        [app.Mask, app.MaskLabel, info_cfa] = autoseg.extend_to_cfa( ...
                            app.D, app.Mask, app.MaskLabel, struct('verbose', false));
                        app.DisplayExclusion = ~app.Mask;
                        if isfield(info_cfa, 'L') && isfield(info_cfa.L, 'last_z')
                            fprintf('[finishStep2] CFA extend: L start z=%s end z=%s (+%d slices); R start z=%s end z=%s (+%d slices)\n', ...
                                num2str(info_cfa.L.starting_z), num2str(info_cfa.L.last_z), info_cfa.L.added_slices, ...
                                num2str(info_cfa.R.starting_z), num2str(info_cfa.R.last_z), info_cfa.R.added_slices);
                        end
                        % Surface SE(3) cross-vessel rule findings. When
                        % the check returns passed=false (or any block
                        % FAIL), warn the user — the L or R centerline
                        % may have tracked the wrong vessel and a
                        % manual CFA click is recommended.
                        if isfield(info_cfa, 'se3_check')
                            app.LastSE3Check = info_cfa.se3_check;
                            fprintf('[finishStep2] %s\n', info_cfa.se3_check.summary_text);
                            if ~info_cfa.se3_check.passed
                                uialert(app.UIFigure, sprintf( ...
                                    ['The L/R iliac centerlines failed one or more anatomic ' ...
                                     'plausibility rules:\n\n%s\n\n' ...
                                     'One side may have tracked the wrong vessel (e.g. ' ...
                                     'hypogastric / gluteal branch instead of the EIA). ' ...
                                     'Review the 3-D recon and use the "Manual CFA click" ' ...
                                     'control on the centerline tab to re-anchor the ' ...
                                     'affected side.'], info_cfa.se3_check.summary_text), ...
                                    'SE(3) cross-vessel rule check failed', 'Icon', 'warning');
                            end
                        end
                        % Per-centerline SE(3) checks (one per side).
                        % At the coarse-centerline stage these are
                        % advisory only — the proper centerline solver
                        % downstream will re-run them with diagnostic
                        % thresholds. Log to console; don't pop a
                        % modal unless both sides FAIL.
                        if isfield(info_cfa, 'se3_per_L')
                            fprintf('[finishStep2] %s\n', info_cfa.se3_per_L.summary_text);
                        end
                        if isfield(info_cfa, 'se3_per_R')
                            fprintf('[finishStep2] %s\n', info_cfa.se3_per_R.summary_text);
                        end
                    end
                catch ME_e
                    fprintf('[finishStep2] CFA extension failed: %s\n', ME_e.message);
                end

                % --- 5. SUPRACELIAC CROP. EVAR planning only needs
                % the aorta to 5 cm above the celiac artery. Find
                % the celiac (label 8 in app.MaskLabel from
                % extend_and_detect_branches) and crop the mask above
                % z_celiac - 100 slices (50 mm cranial). Drops the
                % thoracic aorta + arch which would otherwise inflate
                % the centerline solver workload and add noise.
                d.Message = 'Cropping supraceliac region to 5 cm above celiac…';
                drawnow;
                try
                    if ~isempty(app.MaskLabel) && any(app.MaskLabel(:) == 8)
                        celiac_mask = (app.MaskLabel == 8);
                        zp_c = squeeze(any(any(celiac_mask, 1), 2));
                        celiac_top_z = find(zp_c, 1, 'first');
                        ssp = abs(app.D.slice_spacing_mm);
                        target_top_z = max(1, celiac_top_z - round(50 / ssp));
                        n_before = nnz(app.Mask);
                        app.Mask(:, :, 1:target_top_z-1) = false;
                        app.MaskLabel(:, :, 1:target_top_z-1) = 0;
                        app.DisplayExclusion = ~app.Mask;
                        n_after = nnz(app.Mask);
                        fprintf('[finishStep2] supraceliac crop: kept z>=%d (celiac at z=%d - 50 mm), dropped %d vox\n', ...
                            target_top_z, celiac_top_z, n_before - n_after);
                    else
                        fprintf('[finishStep2] celiac label not found — skipping supraceliac crop (audit will flag).\n');
                    end
                catch ME_c
                    fprintf('[finishStep2] supraceliac crop failed: %s\n', ME_c.message);
                end

                % --- 5. segmentation audit ---
                % Verify the mask is anatomically complete BEFORE
                % advancing to endpoint picking. Block advance on any
                % FAIL severity.
                d.Message = 'Auditing segmentation…';
                drawnow;
                try
                    % Pull TWO label volumes for the audit:
                    %   - ts_labels: the raw TS multilabel from cache —
                    %                used for the kidney anchor in the
                    %                proximal-extent check.
                    %   - branch_labels: app.MaskLabel — labels 1-9 from
                    %                autoseg.extend_and_detect_branches
                    %                (1=aorta, 2/3=iliacs, 4/5=CFAs,
                    %                6=renal_L, 7=renal_R, 8=celiac,
                    %                9=SMA). Used for both the required-
                    %                vessels and visceral-branches checks.
                    ts_labels = uint8([]);
                    if ~isempty(app.TSLabelVolume) && isequal(size(app.TSLabelVolume), size(app.D.vol))
                        ts_labels = app.TSLabelVolume;
                    else
                        cache_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), '.cache', 'autoseg');
                        if exist(cache_dir, 'dir')
                            dd = dir(fullfile(cache_dir, '*_seg.nii.gz'));
                            if ~isempty(dd)
                                [~, ix] = max([dd.datenum]);
                                tmp = niftiread(fullfile(dd(ix).folder, dd(ix).name));
                                if isequal(size(tmp), size(app.D.vol))
                                    ts_labels = uint8(tmp);
                                end
                            end
                        end
                    end
                    audit = autoseg.audit_segmentation(app.Mask, ...
                        struct('ts_labels', ts_labels, ...
                               'branch_labels', app.MaskLabel), ...
                        app.D);
                    app.SegAuditReport = audit;
                catch ME_a
                    audit = struct('passed', true, ...
                        'summary_text', sprintf('Audit failed: %s', ME_a.message));
                end

                % Reset display indices + force MainImage rebuild
                app.IdxAxial    = round(size(app.D.vol,3)/2);
                app.IdxCoronal  = round(size(app.D.vol,1)/2);
                app.IdxSagittal = round(size(app.D.vol,2)/2);
                if ~isempty(app.MainImage) && isvalid(app.MainImage)
                    delete(app.MainImage); app.MainImage = [];
                end
                if ~isempty(app.VolViewer) && isvalid(app.VolViewer)
                    delete(app.VolViewer); app.VolViewer = [];
                end
                close(d);
            catch ME
                close(d);
                uialert(app.UIFigure, ME.message, 'Step 2 failed');
                return;
            end

            % Show the audit summary in a modal. If any FAIL findings,
            % stay on Step 2 so the operator can refine. WARN-only is
            % allowed to advance (operator review encouraged).
            if isfield(audit, 'summary_text') && ~isempty(audit.summary_text)
                if audit.passed
                    sel = uiconfirm(app.UIFigure, audit.summary_text, ...
                        'Segmentation audit (WARN)', ...
                        'Options', {'Advance to Step 3', 'Refine on Step 2'}, ...
                        'DefaultOption', 'Advance to Step 3', 'CancelOption', 'Refine on Step 2', ...
                        'Icon', 'info');
                    if strcmp(sel, 'Refine on Step 2'); return; end
                else
                    uialert(app.UIFigure, audit.summary_text, ...
                        'Segmentation audit FAILED — refine first', 'Icon', 'error');
                    return;
                end
            end
            updateStep(app, 3);
        end

        % --- Step 3: Pick endpoints ---------------------------------
        function buildStep3(app)
            app.SideStepLabel.Text = 'Step 3 — Pick endpoints (3 seeds)';
            if strcmp(app.ViewMode, '3dvol')
                setViewMode(app, '3d');
            end
            clearSideContent(app);
            y = app.step_mode_toggle_render(3, 970);
            y = ui_helpers.section_header(app.SideContent, y, ...
                'Step 3 — Three endpoint seeds', [0.20 0.55 0.30], ...
                'step3.overview', app.UIFigure);

            if strcmp(app.StepModes.step3, 'auto')
                buildStep3_auto(app, y);
                return;
            end
            buildStep3_user(app, y);
        end

        function buildStep3_auto(app, y_top)
            sc = app.SideContent;
            y = y_top;
            uilabel(sc, 'Position', [10 y-90 360 90], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Automatic mode places all three seeds using preprocess.auto_seeds_anatomic:', newline, ...
                         '  • Proximal — celiac centroid (label 8) − 50 mm cranial', newline, ...
                         '  • R-CFA — most-caudal voxel of label 5 (post-extension)', newline, ...
                         '  • L-CFA — most-caudal voxel of label 4 (post-extension)']);
            y = y - 90 - 10;
            uibutton(sc, 'push', 'Position', [10 y-44 336 44], ...
                'Text', '⚡  Auto-place all 3 seeds', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'ButtonPushedFcn', @(~,~) autoPlaceAllSeeds(app));
            ui_helpers.info_button(sc, [350 y-34 20 20], 'step3.overview', app.UIFigure);
            y = y - 44 - 12;
            uilabel(sc, 'Position', [10 y-44 360 44], ...
                'Tag', 'seed_status', 'Text', seedSummaryText(app), ...
                'FontSize', 11, 'WordWrap', 'on', 'FontName', 'Menlo');
            y = y - 44 - 12;
            uibutton(sc, 'push', 'Position', [10 30 360 44], ...
                'Text', '✓ Done — go to Step 4', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) finishStep3(app));
            % Auto-run on entry if seeds are empty
            if isempty(app.SeedProximal) && isempty(app.SeedRightCFA) && ...
                    isempty(app.SeedLeftCFA) && any(app.Mask(:))
                autoPlaceAllSeeds(app);
            end
        end

        function autoPlaceAllSeeds(app)
            try
                s = autoSeedsBestAvailable(app);
                if s.ok
                    app.SeedProximal = s.proximal;
                    app.SeedRightCFA = s.right_cfa;
                    app.SeedLeftCFA  = s.left_cfa;
                    stat = findobj(app.SideContent, 'Tag', 'seed_status');
                    if ~isempty(stat) && isvalid(stat)
                        stat.Text = seedSummaryText(app);
                    end
                    refreshMain(app);
                else
                    uialert(app.UIFigure, 'Auto-seed failed to place all 3 seeds.', ...
                        'Auto-seed unavailable');
                end
            catch ME
                uialert(app.UIFigure, ME.message, 'Auto-seed failed');
            end
        end

        function buildStep3_user(app, y_top)
            % Auto-bootstrap if everything is empty — the user can re-arm
            % any seed by clicking its colored button.
            if isempty(app.SeedProximal) && isempty(app.SeedRightCFA) && ...
                    isempty(app.SeedLeftCFA) && any(app.Mask(:))
                try
                    s = autoSeedsBestAvailable(app);
                    if s.ok
                        app.SeedProximal = s.proximal;
                        app.SeedRightCFA = s.right_cfa;
                        app.SeedLeftCFA  = s.left_cfa;
                    end
                catch ME
                    fprintf('[buildStep3_user] auto-seed failed: %s\n', ME.message);
                end
            end

            % Persist the audit summary from Step 2 in a small scroll
            % box at the bottom of the side panel so the operator can
            % refer back to the audit findings while placing seeds.
            audit_lines = {};
            if isstruct(app.SegAuditReport) && isfield(app.SegAuditReport, 'blocks') && ...
                    ~isempty(app.SegAuditReport.blocks)
                for k = 1:numel(app.SegAuditReport.blocks)
                    bb = app.SegAuditReport.blocks{k};
                    sev = {'[OK]','[WARN]','[FAIL]'};
                    audit_lines{end+1} = sprintf('%s %s', sev{bb.severity+1}, bb.name); %#ok<AGROW>
                    for f = 1:numel(bb.findings)
                        audit_lines{end+1} = ['   ', bb.findings{f}]; %#ok<AGROW>
                    end
                end
            end
            uilabel(app.SideContent, 'Position', [10 770 360 16], ...
                'Text', 'Segmentation audit (from Step 2):', ...
                'FontWeight', 'bold', 'FontSize', 11);
            if isempty(audit_lines); audit_lines = {'(no audit report available)'}; end
            uitextarea(app.SideContent, 'Position', [10 600 360 165], ...
                'Editable', 'off', 'FontName', 'Menlo', 'FontSize', 9, ...
                'Value', audit_lines(:), 'Tag', 'audit_summary');

            uilabel(app.SideContent, 'Position', [10 480 360 110], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['EVAR planning needs three seeds: proximal aorta ' ...
                         '(suprarenal — green), right CFA (red), and left ' ...
                         'CFA (blue). The buttons arm in order — click each ' ...
                         'one, then click on the orange mask in any view. ' ...
                         'Re-arm any seed at any time to refine.']);

            uibutton(app.SideContent, 'push', ...
                'Position', [10 390 360 36], ...
                'Text', '● Set proximal aorta (suprarenal)', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.82 0.97 0.82], ...
                'ButtonPushedFcn', @(~,~) armSeed(app, 'proximal'));
            uibutton(app.SideContent, 'push', ...
                'Position', [10 348 360 36], ...
                'Text', '● Set right CFA', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.97 0.82 0.82], ...
                'ButtonPushedFcn', @(~,~) armSeed(app, 'right_cfa'));
            uibutton(app.SideContent, 'push', ...
                'Position', [10 306 360 36], ...
                'Text', '● Set left CFA', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.82 0.88 0.97], ...
                'ButtonPushedFcn', @(~,~) armSeed(app, 'left_cfa'));

            uilabel(app.SideContent, 'Position', [10 256 360 44], ...
                'Tag', 'seed_status', 'Text', seedSummaryText(app), ...
                'FontSize', 11, 'WordWrap', 'on', 'FontName', 'Menlo');
            uilabel(app.SideContent, 'Position', [10 220 360 30], ...
                'Tag', 'arm_status', 'Text', '', 'WordWrap', 'on');

            uibutton(app.SideContent, 'push', ...
                'Position', [10 30 360 44], ...
                'Text', '✓ Done — go to Step 4', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) finishStep3(app));

            % Auto-arm the first missing seed so the user can just start
            % clicking — proximal first, then right CFA, then left CFA.
            if isempty(app.SeedProximal)
                armSeed(app, 'proximal');
            elseif isempty(app.SeedRightCFA)
                armSeed(app, 'right_cfa');
            elseif isempty(app.SeedLeftCFA)
                armSeed(app, 'left_cfa');
            end
        end

        function s = autoSeedsBestAvailable(app)
            % Try the anatomic seed detector (needs the TS multilabel
            % NIfTI). If no cached label volume is available, fall back
            % to the binary-mask seed detector.
            s = struct('ok', false, 'method', '', 'proximal', [], ...
                       'right_cfa', [], 'left_cfa', []);
            % Prefer the exact seg volume captured at segmentation time
            % (app.TSLabelVolume). Only if that is unavailable (e.g. a mask
            % loaded from a saved project) fall back to the newest cached
            % *_seg.nii.gz, guarded by a size match.
            seg = uint8([]);
            if ~isempty(app.TSLabelVolume) && isequal(size(app.TSLabelVolume), size(app.D.vol))
                seg = app.TSLabelVolume;
            else
                cache_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                                     '.cache', 'autoseg');
                if exist(cache_dir, 'dir')
                    d = dir(fullfile(cache_dir, '*_seg.nii.gz'));
                    if ~isempty(d)
                        [~, idx] = max([d.datenum]);
                        try
                            tmp = niftiread(fullfile(d(idx).folder, d(idx).name));
                            if isequal(size(tmp), size(app.D.vol)); seg = uint8(tmp); end
                        catch
                        end
                    end
                end
            end
            if ~isempty(seg)
                try
                    if isequal(size(seg), size(app.D.vol))
                        % Pass app.MaskLabel as branch_labels so
                        % auto_seeds_anatomic can anchor the proximal
                        % seed on the ACTUAL celiac centroid (label 8)
                        % rather than the kidney_top proxy.
                        branch_lbl = uint8([]);
                        if ~isempty(app.MaskLabel) && isequal(size(app.MaskLabel), size(app.D.vol))
                            branch_lbl = app.MaskLabel;
                        end
                        a = preprocess.auto_seeds_anatomic(seg, app.D, struct(), branch_lbl);
                        if a.ok
                            s.ok = true; s.method = 'anatomic';
                            s.proximal  = a.proximal;
                            s.right_cfa = a.right_cfa;
                            s.left_cfa  = a.left_cfa;
                            if isfield(a, 'diagnostic') && isfield(a.diagnostic, 'anchor')
                                fprintf('[autoSeedsBestAvailable] proximal anchor: %s (z=%d)\n', ...
                                    a.diagnostic.anchor, a.proximal(3));
                            end
                            return;
                        end
                    end
                catch ME
                    fprintf('[autoSeedsBestAvailable] anatomic failed: %s\n', ME.message);
                end
            end
            b = preprocess.auto_seeds_from_mask(app.Mask, app.D);
            if b.ok
                s.ok = true; s.method = 'binary_mask';
                s.proximal  = b.proximal;
                s.right_cfa = b.right_cfa;
                s.left_cfa  = b.left_cfa;
            end
        end

        function armSeed(app, which)
            setappdata(app.UIFigure, 'arm_seed', which);
            stat = findobj(app.SideContent, 'Tag', 'arm_status');
            label_map = struct('proximal', 'PROXIMAL aorta (suprarenal, green)', ...
                               'right_cfa', 'RIGHT CFA (red)', ...
                               'left_cfa',  'LEFT CFA (blue)');
            if isfield(label_map, which) && ~isempty(stat) && isvalid(stat)
                stat.Text = sprintf('→ Now click the %s on the main view', label_map.(which));
                stat.FontColor = [0 0 0.6];
            end
        end

        function onEndpointClick(app, voxel)
            arm = getappdata(app.UIFigure, 'arm_seed');
            if isempty(arm); return; end
            switch arm
                case 'proximal';  app.SeedProximal = voxel;
                case 'right_cfa'; app.SeedRightCFA = voxel;
                case 'left_cfa';  app.SeedLeftCFA  = voxel;
            end
            setappdata(app.UIFigure, 'arm_seed', '');

            stat = findobj(app.SideContent, 'Tag', 'seed_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = seedSummaryText(app);
            end
            stat = findobj(app.SideContent, 'Tag', 'arm_status');
            if ~isempty(stat) && isvalid(stat); stat.Text = ''; end

            % Auto-advance the arming sequence: after placing one seed,
            % arm the next missing one. The user can click the explicit
            % buttons to override the order.
            if isempty(app.SeedProximal)
                armSeed(app, 'proximal');
            elseif isempty(app.SeedRightCFA)
                armSeed(app, 'right_cfa');
            elseif isempty(app.SeedLeftCFA)
                armSeed(app, 'left_cfa');
            end
            refreshMain(app);
        end

        function finishStep3(app)
            if isempty(app.SeedProximal) || isempty(app.SeedRightCFA) || isempty(app.SeedLeftCFA)
                missing = {};
                if isempty(app.SeedProximal); missing{end+1} = 'proximal aorta'; end %#ok<AGROW>
                if isempty(app.SeedRightCFA); missing{end+1} = 'right CFA'; end %#ok<AGROW>
                if isempty(app.SeedLeftCFA);  missing{end+1} = 'left CFA';  end %#ok<AGROW>
                uialert(app.UIFigure, ...
                    sprintf('Missing seed(s): %s.', strjoin(missing, ', ')), ...
                    'Need 3 seeds');
                return;
            end
            updateStep(app, 4);
        end

        % --- Step 4: Compute centerline -----------------------------
        function buildStep4(app)
            app.SideStepLabel.Text = 'Step 4 — Compute centerline';
            clearSideContent(app);

            % Algorithm toggle ------------------------------------------------
            vinfo = vmtk_centerline.detect();
            vmtk_ok = vinfo.available;
            if strcmp(app.CenterlineMethod, 'auto')
                if vmtk_ok; app.CenterlineMethod = 'vmtk';
                else;       app.CenterlineMethod = 'skeleton';
                end
            end

            % Mode toggle at the top
            y_below = app.step_mode_toggle_render(4, 970);
            y_below = ui_helpers.section_header(app.SideContent, y_below, ...
                'Step 4 — Bifurcated centerline', [0.20 0.45 0.55], ...
                'step4.overview', app.UIFigure);

            if strcmp(app.StepModes.step4, 'auto')
                buildStep4_auto(app, vmtk_ok, y_below);
                return;
            end
            % Fall through to the existing User-driven layout. Keep the
            % original fixed-y positions so the code below is unchanged
            % beyond adding info buttons.

            uilabel(app.SideContent, 'Position', [10 555 360 24], ...
                'Text', 'Algorithm', 'FontSize', 12, 'FontWeight', 'bold');
            ui_helpers.info_button(app.SideContent, [350 557 20 20], ...
                'step4.algorithm', app.UIFigure);
            grp = uibuttongroup(app.SideContent, ...
                'Position', [10 510 360 44], 'BorderType', 'line', ...
                'BackgroundColor', 'w', 'Tag', 'centerline_alg_grp', ...
                'SelectionChangedFcn', @(g,e) centerlineMethodChanged(app, e.NewValue.Tag));
            tb_vmtk = uitogglebutton(grp, 'Position', [2 2 178 38], ...
                'Text', sprintf('VMTK%s', vmtk_label(vmtk_ok)), ...
                'FontSize', 12, 'Tag', 'vmtk', ...
                'Enable', boolEnable(vmtk_ok), ...
                'Value', strcmp(app.CenterlineMethod, 'vmtk'));
            tb_skel = uitogglebutton(grp, 'Position', [180 2 178 38], ...
                'Text', 'Skeleton (built-in)', 'FontSize', 12, ...
                'Tag', 'skeleton', ...
                'Value', strcmp(app.CenterlineMethod, 'skeleton')); %#ok<NASGU>

            % Description --------------------------------------------------
            switch app.CenterlineMethod
                case 'vmtk'
                    body = ['VMTK (vmtkcenterlines) — surface meshing + ' ...
                            'one-source-two-targets walks the lumen as a ' ...
                            'bifurcating tree. Returns paired right/left ' ...
                            'polylines that share an exact bifurcation node.'];
                case 'skeleton'
                    body = ['Built-in skeleton — bwskel + Dijkstra on the ' ...
                            'medial axis, run twice (proximal → R-CFA, ' ...
                            'proximal → L-CFA). Bifurcation is found by ' ...
                            'matching the two polylines proximal-to-distal.'];
            end
            uilabel(app.SideContent, 'Position', [10 430 360 76], ...
                'WordWrap', 'on', 'FontSize', 12, 'Tag', 'cl_method_blurb', ...
                'Text', body);

            % --- Guardrail toggle ---------------------------------
            cb_guard = uicheckbox(app.SideContent, ...
                'Position', [10 320 250 22], ...
                'Text', sprintf('Reject if arc > %.1f × seed-to-seed chord', ...
                    app.MaxCenterlinePathFactor), ...
                'Value', app.MaxCenterlineGuard, ...
                'Tag', 'cl_guard_toggle', ...
                'ValueChangedFcn', @(c,~) toggleCenterlineGuard(app, c.Value));
            ui_helpers.info_button(app.SideContent, [350 318 20 20], ...
                'step4.guardrail', app.UIFigure);
            uilabel(app.SideContent, 'Position', [10 296 360 22], ...
                'Text', 'Guardrail (recommended): catches runaway paths.', ...
                'FontSize', 11, 'FontColor', [0.45 0.45 0.50]);
            cb_guard.Visible = 'on'; %#ok<NASGU>

            uibutton(app.SideContent, 'push', ...
                'Position', [10 380 360 44], ...
                'Text', '⚙ Compute centerlines', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'ButtonPushedFcn', @(~,~) runCenterline(app));
            uilabel(app.SideContent, 'Position', [10 320 360 56], ...
                'Tag', 'cl_status', 'Text', '(not yet computed)', ...
                'WordWrap', 'on', 'FontSize', 11);
            % Edit hint — only meaningful after the first compute, but
            % showing it pre-compute is fine (acts as advance notice).
            uilabel(app.SideContent, 'Position', [10 235 360 66], ...
                'WordWrap', 'on', 'FontSize', 11, ...
                'FontColor', [0.20 0.30 0.55], ...
                'Text', ['Edit the centerline directly on the 2x2 MPR ' ...
                         'view: right-click any node to insert / delete / ' ...
                         'move a point, or to recompute radii from the ' ...
                         'mask. The aortic side is red; the contralateral ' ...
                         'iliac is blue.']);

            uibutton(app.SideContent, 'push', ...
                'Position', [10 30 360 44], ...
                'Text', '✓ Done — go to Step 5 (Analyze)', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) updateStep(app, 5));

            tb_skel.Value = strcmp(app.CenterlineMethod, 'skeleton'); %#ok<NASGU>
            tb_vmtk.Value = strcmp(app.CenterlineMethod, 'vmtk'); %#ok<NASGU>
        end

        function buildStep4_auto(app, vmtk_ok, y_top)
            sc = app.SideContent;
            y = y_top;
            if vmtk_ok
                alg_msg = 'Algorithm: VMTK (detected, preferred).';
            else
                alg_msg = 'Algorithm: Skeleton (VMTK not installed).';
            end
            uilabel(sc, 'Position', [10 y-80 360 80], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Automatic mode picks the best available algorithm,', newline, ...
                         'computes both centerlines, applies the arc-length', newline, ...
                         'guardrail (4× chord), and centers the 2x2 MPR view', newline, ...
                         'on the result.', newline, newline, alg_msg]);
            y = y - 80 - 10;
            uibutton(sc, 'push', 'Position', [10 y-44 336 44], ...
                'Text', '⚡  Compute centerlines automatically', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'ButtonPushedFcn', @(~,~) runCenterline(app));
            ui_helpers.info_button(sc, [350 y-34 20 20], 'step4.overview', app.UIFigure);
            y = y - 44 - 12;
            uilabel(sc, 'Position', [10 y-60 360 60], ...
                'Tag', 'cl_status', 'Text', '(not yet computed)', ...
                'WordWrap', 'on', 'FontSize', 11);
            y = y - 60 - 12;
            uibutton(sc, 'push', 'Position', [10 30 360 44], ...
                'Text', '✓ Done — go to Step 5 (Analyze)', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) updateStep(app, 5));
        end

        function toggleCenterlineGuard(app, on)
            app.MaxCenterlineGuard = logical(on);
        end

        function centerlineMethodChanged(app, tag)
            app.CenterlineMethod = tag;
            blurb = findobj(app.SideContent, 'Tag', 'cl_method_blurb');
            if ~isempty(blurb) && isvalid(blurb)
                switch tag
                    case 'vmtk'
                        blurb.Text = ['VMTK (vmtkcenterlines) — surface meshing + ' ...
                            'one-source-two-targets walks the lumen as a ' ...
                            'bifurcating tree. Returns paired right/left ' ...
                            'polylines that share an exact bifurcation node.'];
                    case 'skeleton'
                        blurb.Text = ['Built-in skeleton — bwskel + Dijkstra on the ' ...
                            'medial axis, run twice (proximal → R-CFA, ' ...
                            'proximal → L-CFA). Bifurcation is found by ' ...
                            'matching the two polylines proximal-to-distal.'];
                end
            end
        end

        function runCenterline(app)
            % Validate seeds first — clearer than letting the engine fail
            if isempty(app.SeedProximal) || isempty(app.SeedRightCFA) || isempty(app.SeedLeftCFA)
                uialert(app.UIFigure, ...
                    'Place all three seeds in Step 3 first (proximal + R-CFA + L-CFA).', ...
                    'Need 3 seeds');
                return;
            end

            d = uiprogressdlg(app.UIFigure, ...
                'Title', sprintf('Computing centerlines (%s)…', app.CenterlineMethod), ...
                'Indeterminate', 'on');

            try
                switch app.CenterlineMethod
                    case 'vmtk'
                        vopts = struct('keep_work', false);
                        cl = vmtk_centerline.compute(app.Mask, ...
                            app.SeedProximal, app.SeedRightCFA, app.SeedLeftCFA, app.D, vopts);
                        % A thin (1–2 voxel) reconnection bridge can keep the
                        % mask one VOLUME component yet get pinched off the
                        % *decimated* surface mesh, so vmtkcenterlines returns
                        % a degenerate 2-node branch (arc ~0). Detect that and
                        % retry without decimation (reduce=0), which is
                        % radius-safe (no mask inflation). Mirrors the retry in
                        % run_planner_headless — JohnDoe2 needs it for a
                        % non-degenerate right centerline.
                        if vmtk_branch_degenerate_vox(cl, app.SeedProximal, ...
                                app.SeedRightCFA, app.SeedLeftCFA, app.D)
                            d.Message = 'Centerline branch collapsed — retrying without surface decimation…';
                            drawnow;
                            vopts.reduce = 0.0;
                            cl = vmtk_centerline.compute(app.Mask, ...
                                app.SeedProximal, app.SeedRightCFA, app.SeedLeftCFA, app.D, vopts);
                        end
                        % vmtk_centerline.compute returns mm coords, not voxel.
                        % Convert mm → voxel for overlay (display path uses voxels).
                        Pv_R = mm_to_vox(cl.Pv_mm_right, app.D);
                        Pv_L = mm_to_vox(cl.Pv_mm_left,  app.D);
                        % Radii: voxel radius is mm radius / mean in-plane spacing
                        sxy = mean(app.D.pixel_mm(1:2));
                        Rv_R = cl.R_mm_right / sxy;
                        Rv_L = cl.R_mm_left  / sxy;
                        bif  = cl.bifurc_node_right;
                        info_text = sprintf(['VMTK — R: %d nodes, L: %d nodes, ' ...
                            'bifurc @ R-node %d (%.1fs)'], ...
                            size(Pv_R,1), size(Pv_L,1), bif, cl.processing_time);
                    case 'skeleton'
                        % Run twice. Polyline convention is distal → proximal,
                        % so seed_a = CFA (distal), seed_b = proximal.
                        opts = struct('min_branch_length', 30, ...
                                      'radius_weight_pow', 2, ...
                                      'smooth_per_segment', 12);
                        [Pv_R, Rv_R, infoR] = preprocess.centerline_skeleton( ...
                            app.Mask, app.SeedRightCFA, app.SeedProximal, opts);
                        [Pv_L, Rv_L, infoL] = preprocess.centerline_skeleton( ...
                            app.Mask, app.SeedLeftCFA,  app.SeedProximal, opts);
                        % Find bifurc by walking from the proximal end of the
                        % left polyline (= last node) and matching to the right.
                        [bif, kL] = find_skeleton_bifurc(Pv_R, Pv_L);
                        % Trim left polyline above the bifurc — left runs
                        % L-CFA → bifurc only.
                        Pv_L = Pv_L(1:kL, :);
                        Rv_L = Rv_L(1:kL);
                        info_text = sprintf(['Skeleton — R: %d nodes (max %.1f vox), ' ...
                            'L: %d nodes (max %.1f vox), bifurc @ R-node %d'], ...
                            size(Pv_R,1), max(infoR.seed_distances), ...
                            size(Pv_L,1), max(infoL.seed_distances), bif);
                    otherwise
                        error('runCenterline:UnknownMethod', ...
                            'Unknown CenterlineMethod: %s', app.CenterlineMethod);
                end

                % --- Guardrail: arc length sanity check ---------------
                % If the centerline is unreasonably long compared to the
                % straight-line seed-to-seed distance, the Dijkstra path
                % almost certainly walked through wrong anatomy. Reject
                % and tell the user, unless they've turned the guard off.
                if app.MaxCenterlineGuard
                    chord_R = norm(app.SeedRightCFA - app.SeedProximal);
                    arc_R   = sum(vecnorm(diff(Pv_R, 1, 1), 2, 2));
                    chord_L = norm(app.SeedLeftCFA  - app.SeedProximal);
                    arc_L   = sum(vecnorm(diff(Pv_L, 1, 1), 2, 2));
                    bad_R = arc_R > app.MaxCenterlinePathFactor * chord_R;
                    bad_L = arc_L > app.MaxCenterlinePathFactor * chord_L;
                    if bad_R || bad_L
                        close(d);
                        which = '';
                        if bad_R; which = sprintf('right (arc %.0f vs chord %.0f mm-vox)', arc_R, chord_R); end
                        if bad_L
                            sep = ''; if ~isempty(which); sep = '; '; end
                            which = sprintf('%s%sleft (arc %.0f vs chord %.0f)', which, sep, arc_L, chord_L);
                        end
                        uialert(app.UIFigure, sprintf( ...
                            ['Centerline rejected by guardrail: %s.\n\n' ...
                             'The path is too long for the seed-to-seed distance — ' ...
                             'usually the segmentation mask is too inclusive ' ...
                             '(spine / bone leaks). Re-segment or turn off the ' ...
                             'guardrail in Step 4 to keep the result anyway.'], ...
                            which), 'Centerline guardrail');
                        return;
                    end
                end

                app.PolylineRight = Pv_R;
                app.R_vox_right   = Rv_R;
                app.PolylineLeft  = Pv_L;
                app.R_vox_left    = Rv_L;
                app.BifurcNodeIdx = bif;
                % A recomputed centerline invalidates any Step-5 landmark
                % node-indices (they pointed into the old polyline).
                setappdata(app.UIFigure, 'landmarks', struct());
                setappdata(app.UIFigure, 'arm_landmark', '');
                % Back-compat aliases — singular Polyline / R_vox always
                % point to the right (primary) side.
                app.Polyline = Pv_R;
                app.R_vox    = Rv_R;
                % --- Defensive clamp on polyline bbox -----------------
                % Even if centerline_skeleton has an edge-case where a
                % node escapes the seed envelope (e.g. user-tweaked
                % options, future regression), enforce that no node
                % sits outside the bounding box of the three seeds
                % expanded by 20 voxels. Anything beyond gets clamped
                % so the display can't spike off the volume frame.
                seeds = [app.SeedProximal; app.SeedRightCFA; app.SeedLeftCFA];
                lo = min(seeds, [], 1) - 20;
                hi = max(seeds, [], 1) + 20;
                Pv_R = clamp_poly(Pv_R, lo, hi);
                if ~isempty(Pv_L); Pv_L = clamp_poly(Pv_L, lo, hi); end

                % Centerline changed — invalidate cached CPR.
                app.CPRImage = [];

                close(d);
                stat = findobj(app.SideContent, 'Tag', 'cl_status');
                if ~isempty(stat) && isvalid(stat)
                    stat.Text     = info_text;
                    stat.FontColor = [0 0.4 0];
                end
                % Land on the 2x2 MPR view — that's where the user
                % actually inspects + edits a centerline. The 3-D
                % volume / MIP view is rendered but not interactive at
                % the per-node level, so don't strand them there.
                % Center each MPR slice on the centerline first so we
                % aren't looking at an empty slab above/below it.
                centerSlicesOnCenterline(app);
                setViewMode(app, '2x2');
                % Fit each 2-D pane's XLim/YLim to the centerline
                % bounding box (plus margin) so the lumen detail fills
                % the screen instead of being lost in dead space.
                fitView(app);
            catch ME
                close(d);
                uialert(app.UIFigure, ME.message, 'Centerline failed');
            end
        end

        % --- Step 5: Analyze (EVAR planning measurements) ------------
        function buildStep5_analyze(app)
            app.SideStepLabel.Text = 'Step 5 — Analyze (EVAR)';
            clearSideContent(app);

            % Mode toggle at the top
            y_below = app.step_mode_toggle_render(5, 970);
            y_below = ui_helpers.section_header(app.SideContent, y_below, ...
                'Step 5 — EVAR sizing + IFU match', [0.55 0.30 0.55], ...
                'step5.overview', app.UIFigure); %#ok<NASGU>

            if isempty(app.Polyline)
                render_gated_step_placeholder(app, 5, ...
                    'Step 4 — Compute centerline', ...
                    {'Mark proximal aorta + bilateral CFA endpoints (Step 3)', ...
                     'Compute the bifurcated centerline (Step 4)'}, ...
                    {'Lumen radius profile along the centerline', ...
                     'Proximal-neck Ø, length, angulation', ...
                     'Iliac landing-zone diameters', ...
                     'IFU device-match ranking with binding constraints'}, 4);
                return;
            end

            if strcmp(app.StepModes.step5, 'auto')
                buildStep5_auto(app);
                return;
            end
            uilabel(app.SideContent, 'Position', [10 580 360 100], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Mark anatomical landmarks on the centerline. ' ...
                         'Use the buttons below to arm a landmark, then ' ...
                         'click on the centerline polyline (red) in any ' ...
                         'view. Measurements update automatically.']);

            % Landmark buttons
            lm_specs = {
                'lowest_renal',     'Lowest renal artery',     [10  540];
                'aortic_bifurc',    'Aortic bifurcation',      [195 540];
                'right_iliac',      'Right iliac terminus',    [10  500];
                'left_iliac',       'Left iliac terminus',     [195 500];
                'right_int_iliac',  'Right internal iliac',    [10  460];
                'left_int_iliac',   'Left internal iliac',     [195 460];
            };
            for i = 1:size(lm_specs, 1)
                key  = lm_specs{i, 1};
                lbl  = lm_specs{i, 2};
                pos  = lm_specs{i, 3};
                uibutton(app.SideContent, 'push', ...
                    'Position', [pos(1) pos(2) 175 32], ...
                    'Text', lbl, 'FontSize', 11, ...
                    'ButtonPushedFcn', @(~,~) armLandmark(app, key, lbl));
            end

            uilabel(app.SideContent, 'Position', [10 420 360 26], ...
                'Tag', 'arm_lm_status', 'Text', '', 'WordWrap', 'on', ...
                'FontColor', [0 0 0.6]);

            % Auto-label — heuristic guess at lowest renal + aortic
            % bifurc from the radius profile + bifurc node.
            uibutton(app.SideContent, 'push', ...
                'Position', [10 700 336 32], ...
                'Text', '⚙ Auto-label landmarks (lowest renal + bifurc)', ...
                'FontSize', 11, 'BackgroundColor', [0.92 0.97 1.0], ...
                'ButtonPushedFcn', @(~,~) autoLabelLandmarks(app));
            ui_helpers.info_button(app.SideContent, [350 706 20 20], ...
                'step5.auto_label', app.UIFigure);

            % Measurement table area
            uilabel(app.SideContent, 'Position', [10 390 360 22], ...
                'Text', 'Measurements', 'FontWeight', 'bold', 'FontSize', 12);
            uitextarea(app.SideContent, 'Position', [10 130 360 250], ...
                'Tag', 'meas_text', 'Editable', 'off', ...
                'FontName', 'Menlo', 'FontSize', 11, ...
                'Value', evarMeasurementsText(app));

            uibutton(app.SideContent, 'push', ...
                'Position', [10 80 360 30], ...
                'Text', 'Plot radius profile + landmarks', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) plotRadiusProfile(app));

            % --- IFU device match (NEW) ---
            uibutton(app.SideContent, 'push', ...
                'Position', [10 45 336 30], ...
                'Text', '🩺  Run IFU device match (research only)', 'FontSize', 11, ...
                'BackgroundColor', [1.0 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) runIFUMatch(app));
            ui_helpers.info_button(app.SideContent, [350 50 20 20], ...
                'step5.ifu_match', app.UIFigure);

            uibutton(app.SideContent, 'push', ...
                'Position', [10 5 360 36], ...
                'Text', '✓ Done — go to Step 6 (Export)', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) updateStep(app, 6));
        end

        function buildStep5_auto(app)
            sc = app.SideContent;
            % After the toggle + section header, we have ~y=830 to work with.
            uilabel(sc, 'Position', [10 750 360 100], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Automatic mode runs the EVAR sizing pipeline in one click:', newline, ...
                         '  1. Auto-label lowest renal + aortic bifurcation', newline, ...
                         '  2. Derive neck Ø/length/angulation + iliac diameters', newline, ...
                         '  3. Match against the IFU library', newline, newline, ...
                         'Refine landmarks manually anytime via the User-driven mode.']);
            uibutton(sc, 'push', 'Position', [10 690 336 44], ...
                'Text', '⚡  Auto-analyze (sizing + IFU match)', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'ButtonPushedFcn', @(~,~) runFullAnalysisAuto(app));
            ui_helpers.info_button(sc, [350 700 20 20], 'step5.overview', app.UIFigure);

            uilabel(sc, 'Position', [10 660 360 22], ...
                'Text', 'Measurements', 'FontWeight', 'bold', 'FontSize', 12);
            uitextarea(sc, 'Position', [10 130 360 520], ...
                'Tag', 'meas_text', 'Editable', 'off', ...
                'FontName', 'Menlo', 'FontSize', 11, ...
                'Value', evarMeasurementsText(app));

            uibutton(sc, 'push', 'Position', [10 80 360 30], ...
                'Text', 'Plot radius profile + landmarks', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) plotRadiusProfile(app));
            uibutton(sc, 'push', 'Position', [10 45 336 30], ...
                'Text', '🩺  IFU device match (re-run)', ...
                'FontSize', 11, 'BackgroundColor', [1.0 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) runIFUMatch(app));
            ui_helpers.info_button(sc, [350 50 20 20], 'step5.ifu_match', app.UIFigure);
            uibutton(sc, 'push', 'Position', [10 5 360 36], ...
                'Text', '✓ Done — go to Step 6 (Export)', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) updateStep(app, 6));
        end

        function runFullAnalysisAuto(app)
            try
                autoLabelLandmarks(app);
                runIFUMatch(app);
            catch ME
                uialert(app.UIFigure, ME.message, 'Auto-analysis failed');
            end
        end

        function runIFUMatch(app)
        %RUNIFUMATCH  Compose evar_plan + ifu and surface the verdict.
            if isempty(app.PolylineRight) || isempty(app.PolylineLeft) || ...
               isempty(app.R_vox_right) || isempty(app.R_vox_left)
                uialert(app.UIFigure, 'Compute the bifurcated centerline first (Step 4).', ...
                    'IFU match unavailable');
                return;
            end
            try
                [PvR_mm, RR_mm] = preprocess.centerline_to_mm( ...
                    app.PolylineRight, app.R_vox_right, app.D);
                [PvL_mm, RL_mm] = preprocess.centerline_to_mm( ...
                    app.PolylineLeft,  app.R_vox_left,  app.D);
                pr = struct( ...
                    'Pv_mm_right', PvR_mm, 'R_mm_right', RR_mm, ...
                    'Pv_mm_left',  PvL_mm, 'R_mm_left',  RL_mm, ...
                    'arc_R_mm', sum(vecnorm(diff(PvR_mm,1,1),2,2)), ...
                    'arc_L_mm', sum(vecnorm(diff(PvL_mm,1,1),2,2)));
                plan = evar_plan.generate_plan(pr, struct('verbose', false, 'write_file', ''));
                % Format a verdict table
                lines = { plan.rationale, '', 'Device library used:' };
                for k = 1:numel(plan.ranked_devices)
                    d = plan.ranked_devices(k); ec = d.eligibility;
                    if ec.eligible
                        verdict = sprintf('ELIGIBLE  (margin %+.1f)', ec.min_margin);
                    else
                        verdict = sprintf('OFF-IFU  (binding %s, margin %+.1f)', ec.binding, ec.min_margin);
                    end
                    lines{end+1} = sprintf('  %-14s %-15s %s', d.name, d.manufacturer, verdict); %#ok<AGROW>
                end
                lines{end+1} = '';
                lines{end+1} = ['[' plan.disclaimer ']'];
                uialert(app.UIFigure, strjoin(lines, newline), ...
                    'EVAR plan — IFU device match (research only)', ...
                    'Icon', 'info', 'Interpreter', 'none');
            catch ME
                uialert(app.UIFigure, ME.message, 'IFU match failed');
            end
        end

        function autoLabelLandmarks(app)
            % Heuristic auto-label of the two most clinically important
            % landmarks for EVAR planning:
            %   - aortic bifurcation = the bifurcation node we already know
            %   - lowest renal       = the radius minimum in the upper
            %                          half of the right polyline (proximal
            %                          neck) just above the AAA peak
            if isempty(app.PolylineRight) || isempty(app.R_vox_right)
                uialert(app.UIFigure, 'Compute the centerline first.', 'Auto-label');
                return;
            end
            lm = getappdata(app.UIFigure, 'landmarks');
            if ~isstruct(lm); lm = struct(); end

            % Bifurc — already known
            if ~isempty(app.BifurcNodeIdx)
                lm.aortic_bifurc = app.BifurcNodeIdx;
            end

            % Lowest renal: convert radii to mm, find the radius minimum
            % in the *aortic* portion (above the bifurc) — this approximates
            % the renal level where the aorta is narrowest before it widens
            % into the AAA. Falls back to "5 nodes below the suprarenal end".
            [Pmm, Rmm] = preprocess.centerline_to_mm( ...
                app.PolylineRight, app.R_vox_right, app.D); %#ok<ASGLU>
            n = numel(Rmm);
            % Aortic portion = indices > bifurc (proximal half) — search a
            % window from 0.7 × n to 0.95 × n (avoiding the very tip).
            if ~isempty(app.BifurcNodeIdx)
                lo_search = app.BifurcNodeIdx + 1;
            else
                lo_search = round(0.5 * n);
            end
            lo_search = max(lo_search, round(0.7 * n));
            hi_search = max(lo_search + 5, round(0.95 * n));
            if hi_search > lo_search
                seg = Rmm(lo_search:hi_search);
                [~, k_rel] = min(seg);
                lm.lowest_renal = lo_search + k_rel - 1;
            end

            setappdata(app.UIFigure, 'landmarks', lm);
            stat = findobj(app.SideContent, 'Tag', 'arm_lm_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = sprintf('Auto-labelled: bifurc=node %d, renal=node %d', ...
                    field_or_nan(lm, 'aortic_bifurc'), ...
                    field_or_nan(lm, 'lowest_renal'));
                stat.FontColor = [0 0.4 0];
            end
            ta = findobj(app.SideContent, 'Tag', 'meas_text');
            if ~isempty(ta) && isvalid(ta); ta.Value = evarMeasurementsText(app); end
            refreshMain(app);
        end

        function armLandmark(app, key, lbl)
            setappdata(app.UIFigure, 'arm_landmark', key);
            stat = findobj(app.SideContent, 'Tag', 'arm_lm_status');
            if ~isempty(stat) && isvalid(stat)
                stat.Text = sprintf('Now click on the centerline near the %s', lower(lbl));
            end
        end

        function plotRadiusProfile(app)
            if isempty(app.PolylineRight); return; end
            [Pv_R, R_R] = preprocess.centerline_to_mm(app.PolylineRight, app.R_vox_right, app.D);
            arcR = [0; cumsum(vecnorm(diff(Pv_R,1,1), 2, 2))];

            f = figure('Name', 'EVAR — radius profile', 'Color', 'w', ...
                'Position', [200 200 1000 540]); %#ok<NASGU>
            % Right side (red)
            plot(arcR, 2*R_R, '-', 'Color', [0.85 0.10 0.10], ...
                'LineWidth', 1.8, 'DisplayName', 'Right (R-CFA → suprarenal)'); hold on
            % Left side (blue), arc-shifted so the bifurcation lines up
            % with the right polyline's bifurc_node arc length.
            if ~isempty(app.PolylineLeft)
                [Pv_L, R_L] = preprocess.centerline_to_mm( ...
                    app.PolylineLeft, app.R_vox_left, app.D);
                arcL = [0; cumsum(vecnorm(diff(Pv_L,1,1), 2, 2))];
                shift = 0;
                if ~isempty(app.BifurcNodeIdx) && ...
                        app.BifurcNodeIdx <= numel(arcR)
                    % Shift so left's bifurc end (= last node) aligns with
                    % right's bifurc arc-length.
                    shift = arcR(app.BifurcNodeIdx) - arcL(end);
                end
                plot(arcL + shift, 2*R_L, '-', 'Color', [0.10 0.30 0.85], ...
                    'LineWidth', 1.8, 'DisplayName', 'Left (L-CFA → bifurc)');
            end
            grid on
            xlabel('arc length s (mm) — right polyline frame');
            ylabel('lumen diameter D (mm)');
            title('Dual-side centerline diameter profile');
            legend('Location', 'best');

            % Mark right-polyline landmarks on the plot (renal, bifurc, etc.)
            lm_struct = getappdata(app.UIFigure, 'landmarks');
            if ~isempty(app.BifurcNodeIdx) && app.BifurcNodeIdx <= numel(arcR)
                xline(arcR(app.BifurcNodeIdx), '--m', 'aortic bifurcation', ...
                    'LabelVerticalAlignment', 'top');
            end
            if isstruct(lm_struct)
                fns = fieldnames(lm_struct);
                for i = 1:numel(fns)
                    idx = lm_struct.(fns{i});
                    if isempty(idx) || any(isnan(idx)); continue; end
                    if startsWith(fns{i}, 'left_')
                        % left landmarks live on the LEFT polyline; skip
                        % until we have a left arc shifted into place
                        continue;
                    end
                    if idx >= 1 && idx <= numel(arcR)
                        xline(arcR(idx), '--r', strrep(fns{i}, '_', ' '), ...
                            'LabelVerticalAlignment', 'top');
                    end
                end
            end
        end

        % --- Step 6: Export -----------------------------------------
        function buildStep6_export(app)
            app.SideStepLabel.Text = 'Step 6 — Export';
            clearSideContent(app);

            y_below = app.step_mode_toggle_render(6, 970);
            y_below = ui_helpers.section_header(app.SideContent, y_below, ...
                'Step 6 — Export', [0.20 0.45 0.20], ...
                'step6.overview', app.UIFigure); %#ok<NASGU>

            % Gate on a COMPLETE bifurcated centerline. Checking only the
            % singular app.Polyline (alias to the right branch) let a
            % right-only result through to export, where the plan path then
            % failed on the empty left branch.
            if isempty(app.PolylineRight) || isempty(app.PolylineLeft)
                render_gated_step_placeholder(app, 6, ...
                    'Step 4 — Compute centerline', ...
                    {'Mark proximal aorta + bilateral CFA endpoints (Step 3)', ...
                     'Compute the bifurcated centerline — both iliac branches (Step 4)', ...
                     'Optional: run Analyze (Step 5) to derive EVAR sizing'}, ...
                    {'Structured EVAR plan (.txt + .json) with device ranking', ...
                     'Centerline polyline (.csv) and lumen radius profile', ...
                     'Mesh export (.stl) for CFD / 3-D printing', ...
                     'Plan PDF with rationale and IFU citations'}, 4);
                return;
            end

            if strcmp(app.StepModes.step6, 'auto')
                buildStep6_auto(app);
                return;
            end

            [Pv_mm, R_mm] = preprocess.centerline_to_mm(app.Polyline, app.R_vox, app.D);
            arc_mm = [0; cumsum(vecnorm(diff(Pv_mm,1,1), 2, 2))];
            uilabel(app.SideContent, 'Position', [10 590 360 100], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', sprintf( ...
                    ['Centerline ready:\n' ...
                     '  • %d polyline nodes\n' ...
                     '  • Arc length: %.0f mm\n' ...
                     '  • Lumen radius: %.1f-%.1f mm (median %.1f mm)'], ...
                    size(Pv_mm, 1), arc_mm(end), ...
                    min(R_mm), max(R_mm), median(R_mm)));

            uibutton(app.SideContent, 'push', ...
                'Position', [10 530 116 44], 'Text', '💾 Centerline', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'Tooltip', 'Save centerline.mat', ...
                'ButtonPushedFcn', @(~,~) saveCenterline(app));

            uibutton(app.SideContent, 'push', ...
                'Position', [128 530 116 44], 'Text', '📋 EVAR plan', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [1.0 0.95 0.85], ...
                'Tooltip', 'Save EVAR plan (.txt + .json)', ...
                'ButtonPushedFcn', @(~,~) saveEvarPlan(app));

            uibutton(app.SideContent, 'push', ...
                'Position', [246 530 116 44], 'Text', '🧊 Mesh .stl', ...
                'FontSize', 12, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.90 0.90 0.98], ...
                'Tooltip', 'Marching-cubes the lumen mask to an STL (CFD / 3-D print)', ...
                'ButtonPushedFcn', @(~,~) saveMesh(app));

            % --- Library save ----------------------------------------
            uilabel(app.SideContent, 'Position', [10 480 360 22], ...
                'Text', 'Library (centerlined-aorta archive)', ...
                'FontWeight', 'bold', 'FontSize', 12);
            uibutton(app.SideContent, 'push', ...
                'Position', [10 430 360 44], ...
                'Text', '➕  Add this case to library', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 0.85], ...
                'ButtonPushedFcn', @(~,~) addToLibrary(app));
            uibutton(app.SideContent, 'push', ...
                'Position', [10 380 175 36], ...
                'Text', 'Open library folder', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) openLibraryFolder(app));
            uibutton(app.SideContent, 'push', ...
                'Position', [195 380 175 36], ...
                'Text', 'List cases', 'FontSize', 11, ...
                'ButtonPushedFcn', @(~,~) showLibraryCases(app));

            uilabel(app.SideContent, 'Position', [10 340 336 32], ...
                'Tag', 'lib_status', 'Text', '', ...
                'FontSize', 11, 'WordWrap', 'on', ...
                'FontColor', [0.10 0.45 0.20]);
            ui_helpers.info_button(app.SideContent, [350 348 20 20], ...
                'step6.library', app.UIFigure);
        end

        function buildStep6_auto(app)
            sc = app.SideContent;
            [Pv_mm, R_mm] = preprocess.centerline_to_mm( ...
                app.Polyline, app.R_vox, app.D);
            arc_mm = [0; cumsum(vecnorm(diff(Pv_mm,1,1), 2, 2))];
            uilabel(sc, 'Position', [10 750 360 100], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', sprintf( ...
                    ['Centerline ready:\n' ...
                     '  • %d polyline nodes\n' ...
                     '  • Arc length: %.0f mm\n' ...
                     '  • Lumen radius: %.1f-%.1f mm (median %.1f mm)'], ...
                    size(Pv_mm, 1), arc_mm(end), ...
                    min(R_mm), max(R_mm), median(R_mm)));
            uilabel(sc, 'Position', [10 670 360 60], ...
                'WordWrap', 'on', 'FontSize', 12, ...
                'Text', ['Automatic mode bundles every output into the ', ...
                         'default output directory:', newline, ...
                         '  centerline.mat + plan.txt + plan.json + lumen.stl']);
            uibutton(sc, 'push', 'Position', [10 620 336 44], ...
                'Text', '⚡  Export everything', ...
                'FontSize', 13, 'FontWeight', 'bold', ...
                'BackgroundColor', [0.85 0.95 1.0], ...
                'ButtonPushedFcn', @(~,~) exportEverythingAuto(app));
            ui_helpers.info_button(sc, [350 630 20 20], 'step6.overview', app.UIFigure);
            uilabel(sc, 'Position', [10 580 360 32], ...
                'Tag', 'lib_status', 'Text', '', ...
                'FontSize', 11, 'WordWrap', 'on', ...
                'FontColor', [0.10 0.45 0.20]);
        end

        function exportEverythingAuto(app)
            % Guard: the plan requires a complete bifurcated centerline.
            % Without this, centerline_to_mm on an empty left branch throws
            % mid-export (after centerline.mat is already written).
            if isempty(app.PolylineRight) || isempty(app.PolylineLeft) || ...
                    isempty(app.R_vox_right) || isempty(app.R_vox_left)
                uialert(app.UIFigure, ['Export needs a complete bifurcated ' ...
                    'centerline (both iliac branches). Compute it in Step 4 first.'], ...
                    'Centerline incomplete');
                return;
            end
            try
                out_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), ...
                    'results', 'logs', ...
                    sprintf('export_%s', datestr(now, 'yyyymmdd_HHMMSS'))); %#ok<DATST,TNOW1>
                if ~exist(out_dir, 'dir'); mkdir(out_dir); end
                cs = buildCaseStruct(app); %#ok<NASGU>
                save(fullfile(out_dir, 'centerline.mat'), '-struct', 'cs');
                % Compose plan via the same path runIFUMatch uses
                [PvR_mm, RR_mm] = preprocess.centerline_to_mm( ...
                    app.PolylineRight, app.R_vox_right, app.D);
                [PvL_mm, RL_mm] = preprocess.centerline_to_mm( ...
                    app.PolylineLeft, app.R_vox_left, app.D);
                pr = struct( ...
                    'Pv_mm_right', PvR_mm, 'R_mm_right', RR_mm, ...
                    'Pv_mm_left',  PvL_mm, 'R_mm_left',  RL_mm, ...
                    'arc_R_mm', sum(vecnorm(diff(PvR_mm,1,1),2,2)), ...
                    'arc_L_mm', sum(vecnorm(diff(PvL_mm,1,1),2,2)));
                evar_plan.generate_plan(pr, struct( ...
                    'verbose', false, ...
                    'write_file', fullfile(out_dir, 'plan')));
                % Also write the lumen STL mesh deliverable (non-fatal —
                % the plan + centerline are the primary outputs).
                if ~isempty(app.Mask) && any(app.Mask(:))
                    try
                        evar_plan.export_mesh(struct('mask', app.Mask), struct( ...
                            'out_path',         fullfile(out_dir, 'lumen.stl'), ...
                            'pixel_mm',         app.D.pixel_mm, ...
                            'slice_spacing_mm', app.D.slice_spacing_mm));
                    catch ME_mesh
                        fprintf('[export] mesh export skipped: %s\n', ME_mesh.message);
                    end
                end
                stat = findobj(app.SideContent, 'Tag', 'lib_status');
                if ~isempty(stat) && isvalid(stat)
                    stat.Text = sprintf('Exported to:\n  %s', out_dir);
                end
            catch ME
                uialert(app.UIFigure, ME.message, 'Auto-export failed');
            end
        end

        function out = buildCaseStruct(app)
            % Common payload for both ad-hoc save and library add. Schema:
            %   Pv_mm_right / R_mm_right  primary side, R-CFA → suprarenal
            %   Pv_mm_left  / R_mm_left   left side, L-CFA → bifurc
            %   bifurc_node_right         bifurcation index on the right
            %   seeds_vox = struct(proximal, right_cfa, left_cfa)
            %   Pv_mm / R_mm              singular aliases pointing to right
            %                             (back-compat with older readers)
            [Pv_R, R_R] = preprocess.centerline_to_mm( ...
                app.PolylineRight, app.R_vox_right, app.D);
            if ~isempty(app.PolylineLeft)
                [Pv_L, R_L] = preprocess.centerline_to_mm( ...
                    app.PolylineLeft, app.R_vox_left, app.D);
            else
                Pv_L = zeros(0, 3); R_L = zeros(0, 1);
            end
            out = struct();
            out.Pv_mm_right       = Pv_R;
            out.R_mm_right        = R_R;
            out.Pv_mm_left        = Pv_L;
            out.R_mm_left         = R_L;
            out.bifurc_node_right = app.BifurcNodeIdx;
            out.arc_mm_right      = [0; cumsum(vecnorm(diff(Pv_R,1,1), 2, 2))];
            if size(Pv_L,1) > 1
                out.arc_mm_left   = [0; cumsum(vecnorm(diff(Pv_L,1,1), 2, 2))];
            else
                out.arc_mm_left   = zeros(size(Pv_L,1), 1);
            end
            % Singular aliases — alias to the right (primary) side.
            out.Pv_mm  = Pv_R;
            out.R_mm   = R_R;
            out.arc_mm = out.arc_mm_right;
            % Seeds — three-seed flow
            out.seeds_vox = struct( ...
                'proximal',  app.SeedProximal, ...
                'right_cfa', app.SeedRightCFA, ...
                'left_cfa',  app.SeedLeftCFA);
            out.seg_seed  = app.SeedSeg;
            out.mask      = app.Mask;
            out.click_log = app.ClickLog;
            out.centerline_method = app.CenterlineMethod;
            % Display modifications — useful for reproducing the recon
            if ~isempty(app.DisplayExclusion) && any(app.DisplayExclusion(:))
                out.display_exclusion = app.DisplayExclusion;
            end
            % Pull landmarks from appdata (set by Step 5)
            lm = getappdata(app.UIFigure, 'landmarks');
            if isstruct(lm); out.landmarks = lm; end
            out.dicom_meta = struct('patient_id', app.D.patient_id, ...
                                    'study_date', app.D.study_date, ...
                                    'series',     app.D.series_description, ...
                                    'pixel_mm',   app.D.pixel_mm, ...
                                    'slice_spacing_mm', app.D.slice_spacing_mm);
            out.app_version = '1.1.0';   % bumped: dual-side schema
        end

        function saveCenterline(app)
            [name, path] = uiputfile({'*.mat', 'MAT-file'}, ...
                'Save centerline', 'centerline.mat');
            if name == 0; return; end
            out = buildCaseStruct(app); %#ok<NASGU>
            save(fullfile(path, name), '-struct', 'out');
            uialert(app.UIFigure, sprintf('Saved to %s', fullfile(path, name)), ...
                'Saved', 'Icon', 'success');
        end

        function saveEvarPlan(app)
        %SAVEEVARPLAN  Compose evar_plan.generate_plan and write the
        %   .txt + .json deliverables. Bridges the gap between the
        %   transient IFU modal at Step 5 and a persisted plan record.
            if isempty(app.PolylineRight) || isempty(app.PolylineLeft) || ...
               isempty(app.R_vox_right) || isempty(app.R_vox_left)
                uialert(app.UIFigure, ...
                    'Compute the bifurcated centerline first (Step 4).', ...
                    'Plan unavailable');
                return;
            end
            [stem, path] = uiputfile({'*', 'File stem (no extension)'}, ...
                'Save EVAR plan (writes .txt + .json)', 'evar_plan');
            if stem == 0; return; end
            [~, stem_no_ext, ~] = fileparts(stem);
            write_stem = fullfile(path, stem_no_ext);
            try
                [PvR_mm, RR_mm] = preprocess.centerline_to_mm( ...
                    app.PolylineRight, app.R_vox_right, app.D);
                [PvL_mm, RL_mm] = preprocess.centerline_to_mm( ...
                    app.PolylineLeft,  app.R_vox_left,  app.D);
                pr = struct( ...
                    'Pv_mm_right', PvR_mm, 'R_mm_right', RR_mm, ...
                    'Pv_mm_left',  PvL_mm, 'R_mm_left',  RL_mm, ...
                    'arc_R_mm', sum(vecnorm(diff(PvR_mm,1,1),2,2)), ...
                    'arc_L_mm', sum(vecnorm(diff(PvL_mm,1,1),2,2)), ...
                    'out_dir', path);
                evar_plan.generate_plan(pr, struct( ...
                    'verbose', false, 'write_file', write_stem));
                uialert(app.UIFigure, ...
                    sprintf('EVAR plan written:\n  %s.txt\n  %s.json', ...
                        write_stem, write_stem), ...
                    'Saved', 'Icon', 'success');
            catch ME
                uialert(app.UIFigure, ME.message, 'Plan export failed');
            end
        end

        function saveMesh(app)
        %SAVEMESH  Marching-cubes the lumen mask and write an STL — the
        %   ".stl for CFD / 3-D printing" deliverable Step 6 advertises.
        %   Uses the same `evar_plan.export_mesh` the headless path can
        %   call, with the loaded scan's real voxel spacing so the mesh
        %   is in patient millimetre coordinates.
            if isempty(app.Mask) || ~any(app.Mask(:))
                uialert(app.UIFigure, ...
                    'No segmentation mask to mesh. Run segmentation (Step 2) first.', ...
                    'Mesh unavailable');
                return;
            end
            [name, path] = uiputfile({'*.stl', 'STL mesh'}, ...
                'Save lumen mesh', 'lumen.stl');
            if isequal(name, 0); return; end
            try
                info = evar_plan.export_mesh(struct('mask', app.Mask), struct( ...
                    'out_path',         fullfile(path, name), ...
                    'pixel_mm',         app.D.pixel_mm, ...
                    'slice_spacing_mm', app.D.slice_spacing_mm));
                uialert(app.UIFigure, ...
                    sprintf('STL written (%d verts, %d faces):\n  %s', ...
                        info.n_vertices, info.n_faces, info.out_path), ...
                    'Saved', 'Icon', 'success');
            catch ME
                uialert(app.UIFigure, ME.message, 'Mesh export failed');
            end
        end

        function addToLibrary(app)
            try
                cs = buildCaseStruct(app);
                saved = library.save_case(cs);
                stat = findobj(app.SideContent, 'Tag', 'lib_status');
                if ~isempty(stat) && isvalid(stat)
                    [~, fname, ext] = fileparts(saved);
                    stat.Text = sprintf('Saved %s%s to library.', fname, ext);
                end
                uialert(app.UIFigure, ...
                    sprintf('Saved to library:\n%s', saved), ...
                    'Library updated', 'Icon', 'success');
            catch ME
                uialert(app.UIFigure, ME.message, 'Library save failed');
            end
        end

        function openLibraryFolder(app)
            here = fileparts(fileparts(which('app.AorticCenterlineApp')));
            lib_root = fullfile(here, 'library');
            if ~exist(lib_root, 'dir'); mkdir(lib_root); end
            if ispc
                winopen(lib_root);
            elseif ismac
                system(sprintf('open "%s"', lib_root));
            else
                system(sprintf('xdg-open "%s" &', lib_root));
            end
        end

        function showLibraryCases(app)
            T = library.list_cases();
            if isempty(T)
                uialert(app.UIFigure, ...
                    'Library is empty — add a case first.', ...
                    'No cases');
                return;
            end
            f = uifigure('Name', 'Centerlined-aorta library', ...
                'Position', [200 200 900 500], 'Color', 'w');
            uitable(f, 'Position', [10 10 880 480], 'Data', T);
        end
    end

    methods (Access = public)
        % --- Public test/automation drivers ----------------------------
        % These exist so we can walk the full workflow headlessly for
        % regression tests, screenshots, and documentation. They wrap
        % the same private code paths the buttons fire — no shortcuts,
        % so a green test means the real workflow works.

        function loadVolumeStruct(app, D)
            % Inject a D struct directly (skip the file picker). Same
            % side effects as openDicomFolder/openNifti/openCached.
            doLoad(app, @() D);
        end

        function placeSeed(app, which, voxel)
            % Programmatically place one of the three Step-3 seeds.
            switch which
                case 'proximal';  app.SeedProximal = voxel;
                case 'right_cfa'; app.SeedRightCFA = voxel;
                case 'left_cfa';  app.SeedLeftCFA  = voxel;
                otherwise
                    error('placeSeed:Unknown', ...
                        'which must be proximal | right_cfa | left_cfa');
            end
            refreshMain(app);
        end

        function setMask(app, mask)
            % Inject a segmentation mask (Step 2 oracle).
            assert(islogical(mask) && isequal(size(mask), size(app.D.vol)), ...
                'setMask: mask must be logical, same size as D.vol');
            app.Mask = mask;
            refreshMain(app);
            % Mask change → re-render the 3D Volume so it shows the
            % segmented aorta only (TeraRecon-style isolation).
            if strcmp(app.ViewMode, '3dvol')
                app.VolViewer = [];   % force rebuild
                refreshVolViewer(app);
            end
        end

        function segmentAt(app, voxel)
            % Public wrapper around the shift-click vessel-select
            % gesture. Same semantics as a shift+click on the 3-D
            % recon: run a region grow from the seed, write a new
            % label into MaskLabel where currently 0, leave prior
            % labels alone. Useful for headless tests, regression
            % suites, and scripted batch processing.
            onVesselSelectClick(app, voxel(:).');
        end

        function voxel = pickVesselAt(app, fig_pt, which_view)
            % Public wrapper around the 3-D ray-caster. Useful for
            % testing the click→voxel pipeline without simulating a
            % real mouse event. `which_view` is 'single' (3D Volume
            % single-view) or 'multi' (2x2 pane 4).
            if nargin < 3; which_view = 'single'; end
            voxel = vol3DClickToVoxel(app, fig_pt, which_view);
            if ~isempty(voxel)
                onVesselSelectClick(app, voxel);
            end
        end

        function computeCenterline(app)
            runCenterline(app);
        end

        function setLandmark(app, key, polyline_idx)
            lm = getappdata(app.UIFigure, 'landmarks');
            if ~isstruct(lm); lm = struct(); end
            lm.(key) = polyline_idx;
            setappdata(app.UIFigure, 'landmarks', lm);
        end

        function gotoStep(app, k)
            updateStep(app, k);
        end

        function out = currentCaseStruct(app)
            out = buildCaseStruct(app);
        end

        function captureMain(app, png_path)
            % exportapp captures UI controls; exportgraphics doesn't.
            exportapp(app.UIFigure, png_path);
        end

        function setView(app, mode)
            % Public driver — same code path the toolbar buttons use.
            setViewMode(app, mode);
        end

        function scrubCPRArc(app, arc_mm)
            % Public driver for the CPR cross-section scrubber.
            app.XSecArcMm = arc_mm;
            refreshXSec(app);
        end

        function finishSegmentation(app)
            % Public driver — runs the auto-crop step then advances to
            % Step 3. Same code path as clicking the Step-2 Done button.
            finishStep2(app);
        end

        function out = volSize(app)
            if isempty(app.D) || ~isfield(app.D, 'vol'); out = []; else; out = size(app.D.vol); end
        end

        function vox = polylineRightNodeVox(app, node_idx)
            % Public read of one polyline node's voxel coordinates.
            % Used by the audit instead of round-tripping through mm.
            if isempty(app.PolylineRight); vox = []; return; end
            node_idx = max(1, min(size(app.PolylineRight, 1), node_idx));
            vox = app.PolylineRight(node_idx, :);
        end

        function out = polylineRightInfo(app)
            % Public summary of the right polyline for the audit.
            if isempty(app.PolylineRight)
                out = struct('n', 0, 'min_z', NaN, 'max_z', NaN, ...
                    'min_y', NaN, 'max_y', NaN, 'min_x', NaN, 'max_x', NaN);
                return;
            end
            P = app.PolylineRight;
            out = struct( ...
                'n',     size(P, 1), ...
                'min_y', min(P(:,1)), 'max_y', max(P(:,1)), ...
                'min_x', min(P(:,2)), 'max_x', max(P(:,2)), ...
                'min_z', min(P(:,3)), 'max_z', max(P(:,3)));
        end

        function editCenterlineAt(app, mode, voxel, side)
            % Public driver — same logic as the right-click context
            % menu, callable headlessly from the audit script.
            if nargin < 4 || isempty(side); side = 'right'; end
            app.ClCtxClickVoxel = voxel;
            app.ClCtxClickSide  = side;
            editCenterline(app, mode);
        end

        function L = cprMaxArcMm(app)
            % Public read of the CPR arc-length range. Returns 0 when
            % no centerline / no CPR has been generated yet.
            if isstruct(app.CPRMeta) && isfield(app.CPRMeta, 'arc_mm') && ...
               ~isempty(app.CPRMeta.arc_mm)
                L = max(app.CPRMeta.arc_mm);
            else
                L = 0;
            end
        end

        % --- The actual constructor -----------------------------------
        function app = AorticCenterlineApp()
            % Adapt to whatever screen the user is on. We want to leave
            % the macOS menu bar (top ~25 px) and dock (~80 px) visible,
            % so we cap our height at screen height − 120 and width at
            % screen width − 40. Below 1300×800 we still place the
            % window inside the screen and let the side panel scroll.
            scr = get(groot, 'ScreenSize');   % [1 1 W H]
            % Cap higher (1800) so users on 24" / 27" / ultrawide
            % monitors get more pixels for the volume render. On a 13"
            % MacBook (1440 logical wide) the scr-40 floor still wins,
            % so the window stays inside the screen.
            target_w = min(1800, scr(3) - 40);
            target_h = min(1080, scr(4) - 120);
            target_w = max(target_w, 1100);
            target_h = max(target_h, 700);
            x0 = max(1, floor((scr(3) - target_w) / 2));
            y0 = max(1, floor((scr(4) - target_h) / 2));
            app.UIFigure = uifigure('Name', ['Aortic Centerline Builder ' ...
                '— RESEARCH USE ONLY (not a medical device)'], ...
                'Position', [x0 y0 target_w target_h], 'Color', 'w', ...
                'AutoResizeChildren', 'off', ...
                'SizeChangedFcn',        @(~,~) onFigureResized(app), ...
                'WindowKeyPressFcn',     @(~,evt) onKeyPress(app, evt), ...
                'WindowButtonDownFcn',   @(~,evt) onMouseDownTool(app, evt), ...
                'WindowButtonMotionFcn', @(~,evt) onMouseMotionTool(app, evt), ...
                'WindowButtonUpFcn',     @(~,evt) onMouseUpTool(app, evt));
            hydrateStepModesFromDisk(app);
            buildHelpMenu(app);
            % Adding a uimenu causes the OS to add a menubar to the
            % uifigure, which shrinks the drawable area. Force a
            % drawnow so app.UIFigure.Position(4) reflects the
            % post-menubar height before createStepBar / createViewToolbar
            % / etc. compute child positions. Without this, the step
            % bar was placed at y = (requested_h - 40) which sat
            % ~15 px above the actual top of the drawable area, clipping
            % the tab labels.
            drawnow;
            registerApp(app, app.UIFigure);
            startupFcn(app);
            % One-shot banner — never auto-suppress. Surfaced on every
            % launch because clinicians may rotate through workstations.
            uialert(app.UIFigure, ['This tool is for academic and ' ...
                'methods-development use only.' newline newline ...
                'Outputs (segmentation, centerline, sizing measurements, ' ...
                'device recommendations) have NOT been clinically validated ' ...
                'and MUST NOT be used to plan or guide a patient procedure.'], ...
                'Research use only', 'Icon', 'warning', 'Interpreter', 'none');
            if nargout == 0; clear app; end
        end
    end
end

% =========================================================================
% File-scope helpers
% =========================================================================
function D = loadCached(matfile)
    S = load(matfile);
    if isfield(S, 'D_ct'); D = S.D_ct;
    elseif isfield(S, 'D'); D = S.D;
    else; error('Cached .mat must contain D_ct or D.');
    end
end

function D = loadNifti(nii_path)
%LOADNIFTI  Read a NIfTI volume and shape it like preprocess.dicom_load.
%   Supports .nii and .nii.gz via the built-in niftiread/niftiinfo.
    info = niftiinfo(nii_path);
    vol  = niftiread(info);
    % NIfTI returns volumes in (X, Y, Z); the rest of the codebase uses
    % (Y, X, Z) (row-major image convention). Permute to match.
    vol = permute(vol, [2 1 3]);
    sz  = size(vol);
    if numel(sz) < 3 || sz(3) < 2
        error('loadNifti:NotVolume', ...
            'NIfTI file does not contain a 3-D volume (size = %s).', ...
            mat2str(sz));
    end
    pix = info.PixelDimensions(1:3);

    [~, base, ~] = fileparts(nii_path);
    if endsWith(base, '.nii'); base = extractBefore(base, '.nii'); end

    D = struct();
    D.vol              = single(vol);
    D.pixel_mm         = double(pix(1:2));    % [Y X] in plane
    D.slice_spacing_mm = double(pix(3));
    D.slice_z_mm       = ((1:sz(3)) - 1)' * double(pix(3));
    D.is_volume        = true;
    D.patient_id         = base;
    D.study_date         = '';
    D.series_description = sprintf('NIfTI: %s', base);
end

function D = loadPhantom(mat_path)
%LOADPHANTOM  Load a phantom .mat from library/ as a "raw" D struct.
%   Labels (mask, centerlines, seeds, landmarks) are intentionally
%   stripped so the user can work the case from scratch in the GUI.
    P = phantom.load_from_library(mat_path);
    D = phantom.to_D_struct(P, struct('strip_labels', true));
end

function m2d = sliceMask(mask3d, idx, view)
%SLICEMASK  Extract a 2D slice from a 3D mask in the given view.
%   Returns [] if the mask is empty.
    m2d = [];
    if isempty(mask3d) || ~any(mask3d(:)); return; end
    switch view
        case 'axial';    m2d = mask3d(:, :, idx);
        case 'coronal';  m2d = squeeze(mask3d(idx, :, :)).';
        case 'sagittal'; m2d = squeeze(mask3d(:, idx, :)).';
    end
end

function rgb = compositeView(ct_slice, mask_committed, mask_pending, WL, invert, label_slice, label_lut)
%COMPOSITEVIEW  Render a CT slice with optional committed mask, pending
%   preview, and multi-label overlays in one shot. Overlay is
%   intentionally subtle — TeraRecon uses a 15-25 % tint that PREVIEWS
%   where the mask is without drowning the CT signal underneath.
%
%   Args:
%     ct_slice       2-D HU image
%     mask_committed logical 2-D binary mask (legacy single-color path).
%                    Used when `label_slice` is empty.
%     mask_pending   logical 2-D — yellow preview tint
%     WL             [W, L] window/level
%     invert         flip intensity polarity AFTER windowing
%     label_slice    optional uint8 2-D label image (0 = background,
%                    k = the k-th click's territory). When non-empty,
%                    each label gets its own color from `label_lut` and
%                    `mask_committed` is IGNORED — labels are the
%                    multi-color replacement.
%     label_lut      Nx3 RGB palette indexed by label k.
    if nargin < 5; invert = false; end
    if nargin < 6; label_slice = []; end
    if nargin < 7; label_lut   = []; end
    W = WL(1); L = WL(2);
    lo = L - W/2; hi = L + W/2;
    g = (double(ct_slice) - lo) / (hi - lo);
    g = max(0, min(1, g));
    if invert
        g = 1 - g;
    end
    R = g; G = g; B = g;
    a_mask = 0.22;     % per-label opacity
    a_pend = 0.30;     % pending preview opacity
    use_labels = ~isempty(label_slice) && ~isempty(label_lut) && ...
                 any(label_slice(:) > 0);
    if use_labels
        % Multi-color path: one tint per label k. We loop over the
        % labels actually present in this slice rather than 1..N so
        % a slice with only labels 3 and 7 doesn't pay for the rest.
        present = unique(label_slice(label_slice > 0));
        n_lut = size(label_lut, 1);
        for ii = 1:numel(present)
            k = double(present(ii));
            col = label_lut(mod(k - 1, n_lut) + 1, :);
            sel = (label_slice == present(ii));
            R(sel) = (1 - a_mask) * R(sel) + a_mask * col(1);
            G(sel) = (1 - a_mask) * G(sel) + a_mask * col(2);
            B(sel) = (1 - a_mask) * B(sel) + a_mask * col(3);
        end
    elseif ~isempty(mask_committed) && any(mask_committed(:))
        % Legacy single-color path
        R(mask_committed) = (1-a_mask) * R(mask_committed) + a_mask * 1.00;
        G(mask_committed) = (1-a_mask) * G(mask_committed) + a_mask * 0.45;
        B(mask_committed) = (1-a_mask) * B(mask_committed) + a_mask * 0.20;
    end
    if ~isempty(mask_pending) && any(mask_pending(:))
        R(mask_pending) = (1-a_pend) * R(mask_pending) + a_pend * 1.00;
        G(mask_pending) = (1-a_pend) * G(mask_pending) + a_pend * 0.92;
        B(mask_pending) = (1-a_pend) * B(mask_pending) + a_pend * 0.10;
    end
    rgb = cat(3, R, G, B);
end

function s = seedStr(seed)
    if isempty(seed); s = '—';
    else; s = sprintf('[%d %d %d]', seed(1), seed(2), seed(3));
    end
end

function P_vox = mm_to_vox(P_mm, D)
%MM_TO_VOX  Inverse of preprocess.centerline_to_mm / vmtk_centerline's
%   remap_z_to_dicom — convert an N×3 [Y X Z] polyline in mm back to
%   [y x z] voxel indices.
%
%   CRITICAL: the centerline backends emit Z in the DICOM *patient-
%   position* frame (Z interpolated from D.slice_z_mm, which carries the
%   ImagePositionPatient Z offset — often a large negative number, e.g.
%   ~-1500 mm). Inverting Z as P_mm(:,3)/slice_spacing+1 (a zero-origin
%   assumption) lands the polyline thousands of voxels off the volume and
%   renders it upside-down under YDir='reverse'. Invert the slice_z_mm
%   remap instead so the centerline overlays the anatomy correctly.
    P_vox = zeros(size(P_mm));
    P_vox(:,1) = P_mm(:,1) / D.pixel_mm(1) + 1;
    P_vox(:,2) = P_mm(:,2) / D.pixel_mm(2) + 1;
    if isfield(D, 'slice_z_mm') && ~isempty(D.slice_z_mm)
        zsamp = D.slice_z_mm(:);
        nsl   = numel(zsamp);
        % interp1 needs strictly monotonic sample points; slice_z_mm is
        % monotonic by construction. Map patient-Z mm -> 1-based slice idx.
        z_idx = interp1(zsamp, 1:nsl, P_mm(:,3), 'linear', 'extrap');
        P_vox(:,3) = min(max(z_idx, 1), nsl);
    else
        % Synthetic/phantom volumes: the two frames coincide.
        P_vox(:,3) = P_mm(:,3) / D.slice_spacing_mm + 1;
    end
end

function bad = vmtk_branch_degenerate_vox(cl, prox_vox, rcfa_vox, lcfa_vox, D)
%VMTK_BRANCH_DEGENERATE_VOX  True if either VMTK branch collapsed to a
%   near-zero-length polyline (the thin-bridge surface-pinch failure where
%   decimation splits the surface mesh and vmtkcenterlines returns a 2-node
%   line on the CFA target). Mirrors run_planner_headless/vmtk_branch_-
%   degenerate but takes the seeds in voxel coordinates and converts to mm
%   in the same [y x z] frame as cl.Pv_mm_* (see mm_to_vox convention).
    sp = [D.pixel_mm(1), D.pixel_mm(2), D.slice_spacing_mm];
    prox_mm = (double(prox_vox(:)') - 1) .* sp;
    rcfa_mm = (double(rcfa_vox(:)') - 1) .* sp;
    lcfa_mm = (double(lcfa_vox(:)') - 1) .* sp;
    bad = one_branch_degenerate(cl.Pv_mm_right, prox_mm, rcfa_mm) ...
       || one_branch_degenerate(cl.Pv_mm_left,  prox_mm, lcfa_mm);
end

function b = one_branch_degenerate(Pv, prox_mm, cfa_mm)
    if isempty(Pv) || size(Pv, 1) < 5
        b = true; return;
    end
    arc      = sum(vecnorm(diff(Pv, 1, 1), 2, 2));
    straight = norm(prox_mm - cfa_mm);
    b = arc < 0.6 * straight;   % span_frac=0.6, matches the acceptance gate
end

function [k_right, k_left] = find_skeleton_bifurc(P_right, P_left, tol_vox)
%FIND_SKELETON_BIFURC  Locate the bifurcation node where the two
%   polylines diverge.
%
%   Polyline convention: distal=node 1, proximal=last node. When each
%   side is computed independently by Dijkstra on the same skeleton,
%   the proximal segment (suprarenal aorta down through the aortic
%   bifurcation) is shared between the right and left polylines, and
%   the iliac segments diverge below the bifurcation.
%
%   Strategy: walk the LEFT polyline from proximal (end) toward distal
%   (start) and find the first node that is NOT near any node on the
%   right polyline. The bifurcation is one node "above" that divergence
%   (i.e. the last node still shared with the right polyline).
    if nargin < 3; tol_vox = 3.0; end
    nL = size(P_left, 1);
    last_shared_kL = nL;
    last_shared_kR = NaN;
    for kL = nL:-1:1
        d = vecnorm(P_right - P_left(kL,:), 2, 2);
        [dmin, kR] = min(d);
        if dmin <= tol_vox
            last_shared_kL = kL;
            last_shared_kR = kR;
        else
            break;     % we've stepped onto the iliac branch — stop
        end
    end
    if isnan(last_shared_kR)
        % Fallback — globally closest pair (no shared segment found)
        d_best = inf;
        last_shared_kL = nL; last_shared_kR = size(P_right, 1);
        for kL = 1:nL
            d = vecnorm(P_right - P_left(kL,:), 2, 2);
            [dmin, kR] = min(d);
            if dmin < d_best
                d_best = dmin; last_shared_kL = kL; last_shared_kR = kR;
            end
        end
    end
    k_left  = last_shared_kL;
    k_right = last_shared_kR;
end

function s = vmtk_label(ok)
    if ok; s = '';
    else;  s = ' (unavailable)';
    end
end

function s = boolEnable(b)
    if b; s = 'on'; else; s = 'off'; end
end

function v = field_or_nan(s, name)
    if isfield(s, name) && ~isempty(s.(name)); v = s.(name);
    else;                                       v = NaN;
    end
end

function P = clamp_poly(P, lo, hi)
%CLAMP_POLY  Belt-and-suspenders: clip every polyline node to lie
%   inside the seed-bbox expanded by a buffer. A spike off the
%   volume frame is impossible after this no matter what upstream
%   centerline algorithm did.
    if isempty(P); return; end
    P(:, 1) = max(lo(1), min(hi(1), P(:, 1)));
    P(:, 2) = max(lo(2), min(hi(2), P(:, 2)));
    P(:, 3) = max(lo(3), min(hi(3), P(:, 3)));
end

function txt = seedSummaryText(app)
%SEEDSUMMARYTEXT  One-line / multi-line status of the three EVAR seeds.
    txt = sprintf('● proximal: %s\n● R-CFA:    %s\n● L-CFA:    %s', ...
        seedStr(app.SeedProximal), ...
        seedStr(app.SeedRightCFA), ...
        seedStr(app.SeedLeftCFA));
end

function lines = evarMeasurementsText(app)
%EVARMEASUREMENTSTEXT  Format current EVAR measurements as cellstr.
    if isempty(app.PolylineRight); lines = {'(no centerline yet)'}; return; end
    % Convert each side's polyline to mm
    [Pv_R, R_R] = preprocess.centerline_to_mm(app.PolylineRight, app.R_vox_right, app.D);
    if ~isempty(app.PolylineLeft)
        [Pv_L, R_L] = preprocess.centerline_to_mm(app.PolylineLeft, app.R_vox_left, app.D);
    else
        Pv_L = zeros(0, 3); R_L = zeros(0, 1);
    end

    lm_app = getappdata(app.UIFigure, 'landmarks');
    if ~isstruct(lm_app); lm_app = struct(); end
    landmarks = struct();
    map = {'lowest_renal',     'renal_index';
           'aortic_bifurc',    'bifurc_index';
           'right_iliac',      'right_iliac_index';
           'left_iliac',       'left_iliac_index';
           'right_int_iliac',  'right_internal_iliac';
           'left_int_iliac',   'left_internal_iliac'};
    for i = 1:size(map, 1)
        if isfield(lm_app, map{i,1})
            landmarks.(map{i,2}) = lm_app.(map{i,1});
        end
    end

    bifurc = app.BifurcNodeIdx;
    if isempty(bifurc); bifurc = NaN; end
    M = preprocess.evar_measurements(Pv_R, R_R, Pv_L, R_L, bifurc, landmarks);

    % Source the neck / aneurysm headline numbers from the SAME engine the
    % exported plan + IFU matching use (evar_plan.measure_from_centerline),
    % so what the operator reads here is exactly what gets exported — no
    % display-vs-export discrepancy. Falls back to the landmark-based M if
    % the auto engine can't run yet (e.g. no left branch).
    meas = [];
    if ~isempty(Pv_L)
        try
            pr_disp = struct('Pv_mm_right', Pv_R, 'R_mm_right', R_R, ...
                             'Pv_mm_left',  Pv_L, 'R_mm_left',  R_L);
            meas = evar_plan.measure_from_centerline(pr_disp);
        catch
            meas = [];
        end
    end

    L = {};
    if ~isempty(meas)
        L{end+1} = '─── Aortic neck (auto — matches export) ─';
        L{end+1} = sprintf('  Lumen Ø:       %s', mmStr(meas.neck_diameter_mm));
        L{end+1} = sprintf('  Length:        %s', neckLenStr(meas));
        L{end+1} = sprintf('  Angulation β:  %s  (neck→sac, IFU)', degStr(meas.neck_angulation_beta_deg));
        L{end+1} = sprintf('  Angulation α:  %s  (suprarenal→neck)', degStr(meas.neck_angulation_alpha_deg));
        L{end+1} = sprintf('  Conicity:      %s mm/cm', valStr(M.aortic_neck.conicity_mm_per_cm, 1));
        L{end+1} = '';
        L{end+1} = '─── Aneurysm sac ───────────────';
        L{end+1} = sprintf('  Max lumen Ø:   %s  (excl. thrombus)', mmStr(meas.aneurysm_max_diameter_mm));
        if isfield(meas, 'aneurysm_detected') && ~meas.aneurysm_detected
            L{end+1} = '  (no discrete aneurysm detected)';
        end
        L{end+1} = '';
    else
        L{end+1} = '─── Aortic neck ────────────────';
        L{end+1} = sprintf('  Length:        %s', mmStr(M.aortic_neck.length_mm));
        L{end+1} = sprintf('  Lumen Ø:       %s', mmStr(M.aortic_neck.diameter_mm));
        L{end+1} = sprintf('  Angulation:    %s', degStr(M.aortic_neck.angulation_deg));
        L{end+1} = sprintf('  Conicity:      %s mm/cm', valStr(M.aortic_neck.conicity_mm_per_cm, 1));
        L{end+1} = '';
        L{end+1} = '─── Aneurysm sac ───────────────';
        L{end+1} = sprintf('  Max lumen Ø:   %s', mmStr(M.aneurysm.max_diameter_mm));
        L{end+1} = sprintf('  Length:        %s', mmStr(M.aneurysm.length_mm));
        L{end+1} = '';
    end
    L{end+1} = '─── Right iliac ────────────────';
    L{end+1} = sprintf('  CIA lumen Ø:   %s', mmStr(M.iliac.right.cia_diameter_mm));
    L{end+1} = sprintf('  EIA lumen Ø:   %s', mmStr(M.iliac.right.eia_diameter_mm));
    L{end+1} = sprintf('  Length:        %s', mmStr(M.iliac.right.length_mm));
    L{end+1} = sprintf('  Tortuosity:    %s', valStr(M.iliac.right.tortuosity, 2));
    L{end+1} = '';
    L{end+1} = '─── Left iliac ─────────────────';
    L{end+1} = sprintf('  CIA lumen Ø:   %s', mmStr(M.iliac.left.cia_diameter_mm));
    L{end+1} = sprintf('  EIA lumen Ø:   %s', mmStr(M.iliac.left.eia_diameter_mm));
    L{end+1} = sprintf('  Length:        %s', mmStr(M.iliac.left.length_mm));
    L{end+1} = sprintf('  Tortuosity:    %s', valStr(M.iliac.left.tortuosity, 2));
    L{end+1} = '';
    L{end+1} = '─── Distances ──────────────────';
    L{end+1} = sprintf('  Renals → bifurc:   %s', mmStr(M.distances.renals_to_bifurc_mm));
    L{end+1} = sprintf('  Bifurc → R int:    %s', mmStr(M.distances.bifurc_to_int_iliac_mm.right));
    L{end+1} = sprintf('  Bifurc → L int:    %s', mmStr(M.distances.bifurc_to_int_iliac_mm.left));
    L{end+1} = '';
    L{end+1} = '─── Bifurcation ────────────────';
    if isfield(M, 'bifurcation_angle_deg')
        L{end+1} = sprintf('  Take-off angle:    %s', degStr(M.bifurcation_angle_deg));
    end
    lines = L;
end

function s = mmStr(v)
    if isnan(v); s = '—';
    else;        s = sprintf('%.1f mm', v);
    end
end
function s = neckLenStr(meas)
%NECKLENSTR  Neck length, or an explicit N/A when no aneurysm onset was
%   detected (the "neck" would otherwise run to the bifurcation).
    if isfield(meas, 'aneurysm_detected') && ~meas.aneurysm_detected
        s = 'N/A (no aneurysm)';
    elseif isnan(meas.neck_length_mm)
        s = 'N/A';
    else
        s = sprintf('%.1f mm', meas.neck_length_mm);
    end
end
function s = degStr(v)
    if isnan(v); s = '—';
    else;        s = sprintf('%.1f°', v);
    end
end
function s = valStr(v, dp)
    if isnan(v); s = '—';
    else;        s = sprintf(['%.', num2str(dp), 'f'], v);
    end
end
