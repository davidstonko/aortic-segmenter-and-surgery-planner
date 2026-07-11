classdef test_manual_editor < matlab.unittest.TestCase
%TEST_MANUAL_EDITOR  Regression for the hardened 3-D click-to-grow /
%   click-to-erase manual segmentation editor in AorticCenterlineApp.
%
%   This pins the manual-refine core of the TeraRecon-style
%   "auto-propose, then refine" workflow. Exercised via the public test
%   shims (eraseAtVoxelPublic / growAtVoxelPublic / setGrowTolPublic /
%   undoPublic / clearMaskPublic / injectMask / maskVoxelCountPublic):
%
%     1. Click-to-erase removes a BOUNDED ball of voxels — it must never
%        nuke the whole connected vessel tree.
%     2. Undo restores exactly what erase removed, and re-erasing the
%        same spot removes the same count — verified on a CLEAN undo
%        stack (injectMask sets the mask without touching the stack, so
%        the first erase's undo is exact).
%     3. The user-controllable grow tolerance (± HU half-window) round-
%        trips through its public setter/getter.
%     4. Click-to-grow respects that tolerance: a wider HU window
%        produces a STRICTLY larger mask on a graded synthetic vessel
%        (tight window catches the bright core only; wide window also
%        catches the weak annulus).
%
%   Builds a tiny synthetic graded "vessel" cylinder so it runs in a
%   couple seconds with no DICOM, and deletes the app window in teardown
%   (no stale GUI windows left behind).

    properties (Access = private)
        a            % app handle (named 'a' so it never shadows +app)
        sz           % synthetic volume size
        seed         % [row col slice] inside the bright core
        full_mask    % full vessel mask (for the erase/undo tests)
        prev_home    % saved user.home, restored in teardown
        tmp_home     % sandbox tempdir for the app's persistence layer
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
            % Sandbox user.home so the app's persistence layer doesn't
            % touch (or get polluted by) the real prefs file.
            tc.prev_home = char(java.lang.System.getProperty('user.home'));
            tc.tmp_home  = tempname();
            mkdir(tc.tmp_home);
            java.lang.System.setProperty('user.home', tc.tmp_home);

            [D, tc.sz, tc.seed, tc.full_mask] = synth_vessel();
            tc.a = app.AorticCenterlineApp();
            pause(0.2);
            tc.a.injectCT(D);
            tc.a.setViewPublic('axial');   % stay 2-D so no viewer3d needed
            pause(0.1);
        end
    end

    methods (TestMethodTeardown)
        function close_app(tc)
            if ~isempty(tc.a) && isvalid(tc.a)
                delete(tc.a);                       % close GUI window
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
        function erase_undo_reerase_on_clean_stack(tc)
            % injectMask sets the mask WITHOUT touching the undo stack, so
            % the erase below is the first edit -> its undo is exact.
            tc.a.injectMask(tc.full_mask);
            before = tc.a.maskVoxelCountPublic();

            erase_vox = tc.seed;
            tc.a.eraseAtVoxelPublic(erase_vox);
            removed1 = before - tc.a.maskVoxelCountPublic();
            tc.verifyGreaterThan(removed1, 0, ...
                'erase must remove at least one voxel');
            tc.verifyLessThan(removed1, before, ...
                'erase must be bounded — it must not nuke the whole mask');

            tc.a.undoPublic();
            tc.verifyEqual(tc.a.maskVoxelCountPublic(), before, ...
                'undo must restore the mask exactly to its pre-erase state');

            tc.a.eraseAtVoxelPublic(erase_vox);
            removed2 = before - tc.a.maskVoxelCountPublic();
            tc.verifyEqual(removed2, removed1, ...
                're-erasing the same spot must remove the same voxel count');
        end

        function grow_tol_setter_round_trips(tc)
            tc.a.setGrowTolPublic(50);
            tc.verifyEqual(tc.a.getGrowTolPublic(), 50, ...
                'grow-tolerance setter/getter must round-trip (50)');
            tc.a.setGrowTolPublic(150);
            tc.verifyEqual(tc.a.getGrowTolPublic(), 150, ...
                'grow-tolerance setter/getter must round-trip (150)');
        end

        function wider_tolerance_grows_strictly_larger(tc)
            % Tight (±50 -> [270,370]): bright core only. Wide (±200 ->
            % [120,520]): core + weak annulus -> strictly larger mask.
            tc.a.clearMaskPublic();
            tc.a.setGrowTolPublic(50);
            tc.a.growAtVoxelPublic(tc.seed);
            n_tight = tc.a.maskVoxelCountPublic();

            tc.a.clearMaskPublic();
            tc.a.setGrowTolPublic(200);
            tc.a.growAtVoxelPublic(tc.seed);
            n_wide = tc.a.maskVoxelCountPublic();

            tc.verifyGreaterThan(n_tight, 0, ...
                'tight-tolerance grow must be non-empty');
            tc.verifyGreaterThan(n_wide, n_tight, ...
                'a wider HU tolerance must grow a strictly larger mask');
        end
    end
end

% =========================================================================
function [D, sz, seed, full_mask] = synth_vessel()
%SYNTH_VESSEL  Tiny graded "vessel" cylinder in air (no DICOM).
%   Vertical cylinder (axis along z) centered at (30,30):
%     core    r <= 6  : HU 320  (bright lumen)
%     annulus 6<r<=9  : HU 180  (weak lumen — only a wide tolerance
%                                window picks it up)
    sz  = [60 60 40];
    vol = -1000 * ones(sz, 'int16');
    [Y, X] = ndgrid(1:sz(1), 1:sz(2));
    rr = sqrt((Y-30).^2 + (X-30).^2);
    core_disk    = rr <= 6;
    annulus_disk = rr > 6 & rr <= 9;
    vessel_disk  = rr <= 9;
    for z = 6:35
        sl = -1000 * ones(sz(1), sz(2), 'int16');
        sl(core_disk)    = 320;
        sl(annulus_disk) = 180;
        vol(:, :, z) = sl;
    end

    D = struct();
    D.vol              = vol;
    D.pixel_mm         = [0.8 0.8];
    D.slice_spacing_mm = 1.5;
    D.slice_z_mm       = (0:sz(3)-1) * D.slice_spacing_mm;
    D.is_volume        = true;   % required by preprocess.seg_aorta_fast

    seed = [30 30 20];   % [row col slice] inside the bright core

    full_mask = false(sz);
    full_mask(repmat(vessel_disk, [1 1 sz(3)]) & vol > -500) = true;
end
