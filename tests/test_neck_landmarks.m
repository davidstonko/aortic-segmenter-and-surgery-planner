classdef test_neck_landmarks < matlab.unittest.TestCase
%TEST_NECK_LANDMARKS  Pins the anatomic neck definition and the honest
%   IFU handling added in the 2026-09-29 audit:
%     * neck starts at the lower margin of the LOWEST renal ostium (from
%       branch labels 6/7), not a fixed arc offset below the seed;
%     * neck ends at the first sustained 10% dilation over the reference
%       neck caliber (or the absolute aneurysm threshold, if earlier);
%     * a juxtarenal aneurysm yields neck length ~0;
%     * without renal labels the heuristic is used AND flagged;
%     * iliac seal length is reported as not assessed (never passed off a
%       bifurcation-to-terminus path length);
%     * neck length is a core criterion when an aneurysm is present;
%     * no device is recommended when planner QC fails.
%   Synthetic geometry only.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    methods (TestClassSetup)
        function add_path(tc) %#ok<MANU>
            addpath(fileparts(fileparts(mfilename('fullpath'))));
        end
    end

    methods (Test)

        function lowest_renal_level_picks_more_caudal_side(tc)
            pr = build_case(struct());
            lr = evar_plan.lowest_renal_level(pr.label_branch, pr.D);
            tc.verifyTrue(lr.found);
            tc.verifyEqual(lr.side, 'R');                 % R renal is lower
            tc.verifyGreaterThanOrEqual(lr.z_idx, 46);    % R renal band z 45-48
            tc.verifyLessThanOrEqual(lr.z_idx, 48);
        end

        function renal_gates_reject_mislabelled_vessels(tc)
            % Mirrors a real case: the auto branch detector labelled a
            % short stub over the spine and a vessel below the kidney as
            % "renals". With kidney extents supplied (auto-detected labels)
            % both must be rejected; without them (hand annotation) they
            % are trusted.
            pr = build_case(struct());
            L = pr.label_branch;
            L(L == 6 | L == 7) = 0;
            L(31:33, 35:37, 38:41) = 6;          % L "renal": 3 px stub (~2 mm reach)
            L(31:33, 5:29, 95:98) = 7;           % R "renal": long, but at z 95-98
            kid = struct('L', [30 70], 'R', [32 72]);
            lr = evar_plan.lowest_renal_level(L, pr.D, struct('kidney_z', kid));
            tc.verifyFalse(lr.found);
            tc.verifyTrue(contains(lr.note, 'stub'));
            tc.verifyTrue(contains(lr.note, 'outside its kidney'));
            lr_trust = evar_plan.lowest_renal_level(L, pr.D);   % no gating
            tc.verifyTrue(lr_trust.found);
            % A genuine renal at kidney level with real lateral reach passes.
            lr_ok = evar_plan.lowest_renal_level(pr.label_branch, pr.D, ...
                struct('kidney_z', kid));
            tc.verifyTrue(lr_ok.found);
            tc.verifyEqual(lr_ok.side, 'R');
        end

        function neck_is_anchored_on_lowest_renal(tc)
            pr = build_case(struct());
            m = evar_plan.measure_from_centerline(pr);
            tc.verifyEqual(m.neck_landmark, 'lowest_renal');
            tc.verifyTrue(m.aneurysm_detected);
            % Neck = renal lower margin (~z 47) to 10%-growth point (~z 70.6)
            tc.verifyGreaterThan(m.neck_length_mm, 18);
            tc.verifyLessThan(m.neck_length_mm, 30);
            tc.verifyEqual(m.neck_diameter_mm, 22, 'AbsTol', 0.6);
            % The heuristic (no labels) on the same centerline starts the
            % neck ~40 mm below the seed — it must be flagged as such.
            pr_h = rmfield(pr, 'label_branch');
            mh = evar_plan.measure_from_centerline(pr_h);
            tc.verifyEqual(mh.neck_landmark, 'heuristic');
        end

        function juxtarenal_aneurysm_has_no_neck(tc)
            pr = build_case(struct('juxtarenal', true));
            m = evar_plan.measure_from_centerline(pr);
            tc.verifyEqual(m.neck_landmark, 'lowest_renal');
            tc.verifyLessThan(m.neck_length_mm, 5);
            devs = ifu.match_devices(m);
            tc.verifyFalse(any(arrayfun(@(d) d.eligibility.eligible, devs)), ...
                'a juxtarenal aneurysm must not be on-label for any standard EVAR device');
        end

        function iliac_seal_length_is_not_assessed(tc)
            pr = build_case(struct());
            m = evar_plan.measure_from_centerline(pr);
            tc.verifyTrue(isnan(m.iliac_R_seal_length_mm));
            tc.verifyGreaterThan(m.iliac_R_length_mm, 0);   % path length still reported
            devs = ifu.match_devices(m);
            na = devs(1).eligibility.not_assessed;
            tc.verifyTrue(any(contains(na, 'iliac R seal length')));
            tc.verifyTrue(any(contains(na, 'iliac L seal length')));
        end

        function neck_length_is_core_when_aneurysm_present(tc)
            pr = build_case(struct());
            m = evar_plan.measure_from_centerline(pr);
            m.neck_length_mm = NaN;
            devs = ifu.match_devices(m);
            tc.verifyTrue(all(arrayfun(@(d) d.eligibility.indeterminate, devs)));
            tc.verifyFalse(any(arrayfun(@(d) d.eligibility.eligible, devs)));
        end

        function no_recommendation_when_qc_fails(tc)
            pr = build_case(struct());
            pr.qc = struct('usable', false, 'summary', 'DO NOT TRUST — synthetic QC failure');
            plan = evar_plan.generate_plan(pr, struct('verbose', false, 'write_file', ''));
            tc.verifyEqual(plan.recommendation, '');
            tc.verifyTrue(contains(plan.rationale, 'NO RECOMMENDATION'));
        end

    end
end

% =========================================================================
function pr = build_case(o)
%BUILD_CASE  Straight aorta along z (1 mm isotropic, head at z=1) with a
%   22 mm infrarenal neck, a 50 mm sac, and a bifurcation at z=130. Renal
%   arteries: L at z 38-41, R at z 45-48 (R is the lowest). Celiac z 20.
    if ~isfield(o, 'juxtarenal'); o.juxtarenal = false; end
    Z = 150; sz = [64 64 Z];
    lab = zeros(sz, 'uint8');
    lab(30:34, 30:34, 1:130) = 1;                 % aortic lumen (label volume)
    lab(31:33, 35:60, 38:41) = 6;                 % L renal, ~26 mm lateral (+x)
    lab(31:33, 4:29, 45:48)  = 7;                 % R renal, ~26 mm lateral (-x)
    lab(35:40, 31:33, 20:22) = 8;                 % celiac, anterior

    z = (0:Z-1).';                                % z_mm == z_idx - 1
    R = zeros(Z, 1);
    R(z < 40)             = 12;                   % suprarenal 24 mm
    R(z >= 40 & z < 70)   = 11;                   % neck 22 mm
    up = z >= 70 & z < 90;
    R(up)                 = 11 + (z(up) - 69) * (14 / 21);   % dilating
    R(z >= 90 & z < 120)  = 25;                   % 50 mm sac
    R(z >= 120)           = 6;                    % distal aorta/iliac
    if o.juxtarenal
        % Sac begins right at the renal level: no infrarenal neck.
        R(z >= 46 & z < 120) = 25;
    end

    Pv_R = [32 + max(0, z - 129) * 0.8, 32 * ones(Z, 1), z];
    Pv_L = [32 - max(0, z - 129) * 0.8, 32 * ones(Z, 1), z];
    RL = R;

    D = struct('pixel_mm', [1 1], 'slice_spacing_mm', 1, ...
        'slice_z_mm', z, 'is_volume', true);
    pr = struct('Pv_mm_right', Pv_R, 'R_mm_right', R, ...
                'Pv_mm_left',  Pv_L, 'R_mm_left',  RL, ...
                'arc_R_mm', Z - 1, 'arc_L_mm', Z - 1, ...
                'label_branch', lab, 'D', D);
end
