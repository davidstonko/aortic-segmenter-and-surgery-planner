function out = build_aaa_male()
%PHANTOM.BUILD_AAA_MALE  Generate a programmatic AAA phantom that meets
%   standard EVAR-device IFU criteria.
%
%   OUT = phantom.build_aaa_male()  returns a complete case struct
%   ready for library.save_case() (same schema as build_normal_male).
%
%   Geometry summary
%       FOV:             256 × 256 × 320 voxels @ 0.7 mm = 18 × 18 × 22.4 cm
%       Suprarenal aorta:        26 mm diameter (radius 13)
%       Infrarenal NECK:         27 mm diameter, 25 mm length, 20°
%                                angulation (coronal plane)
%       Aneurysm SAC:            60 mm max diameter, fusiform, 80 mm long
%       Distal neck:             22 mm diameter just above bifurcation
%       Common iliacs:           9 mm diameter, 60 mm long
%       External iliacs:         8 mm diameter
%       All first-order branches present (celiac, SMA, both renals, IMA),
%       hypogastrics off the iliacs.
%
%   IFU envelope (deliberately comfortable, not edge-of-indication):
%       Neck length:  25 mm   (≥ 10 mm minimum, ≥ 20 mm spec request)
%       Neck angul.:  20°     (< 30°)
%       CIA diameter: 9 mm    (within 7.5–21 mm sealing range)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    rng(20260507, 'twister');

    sz     = [256 256 320];
    pix_mm = [0.7 0.7];
    ssp_mm = 0.7;

    Y_aorta = 144;
    yc_mm = (Y_aorta - 1) * pix_mm(1);
    xc0   = (128 - 1)    * pix_mm(2);   % suprarenal aortic axis at midline-ish

    % --- Aortic centerline (parametric) -----------------------------
    % We assemble the aortic centerline as four contiguous Z bands
    % with prescribed radii and X displacement (coronal-plane kink at
    % the proximal neck → 20° tilt through the sac → returns toward
    % midline at the distal neck for the bifurcation):
    %
    %   suprarenal     Z 5–50 mm    R 13.0  X = xc0
    %   neck (20° kink) Z 50–80 mm   R 13.5  tilts +20° in X over the band
    %   sac            Z 80–145 mm  R 13.5→30→11 (peak at midpoint)
    %   distal neck    Z 145–155 mm R 11    returns toward midline
    %
    % The aneurysm sac's long axis is the tilted line from end-of-neck
    % to start-of-distal-neck, which is what clinical "aneurysm long
    % axis" measures against the suprarenal axis (= 20°).

    % Z anatomical levels (mm). FOV is 224 mm tall (320 × 0.7 mm); we
    % squeeze the visceral aorta up top and reserve plenty of room
    % below the bifurcation for CIAs + EIAs + CFAs out to the femoral
    % heads.
    Z_top         = 5;     % diaphragm
    Z_celiac      = 12;
    Z_sma         = 30;
    Z_renals      = 50;    % renal artery origins
    Z_neck_top    = 53;    % infrarenal neck begins
    Z_neck_bot    = 78;    % neck ends, sac begins (25 mm of neck)
    Z_sac_peak    = 118;   % sac peaks here
    Z_sac_bot     = 158;   % sac ends, distal neck begins
    Z_dneck_bot   = 168;   % aortic bifurcation level
    Z_aorta = (Z_top:1:Z_dneck_bot).';

    % X(Z) profile — coronal kink that reaches +20° at Z=Z_neck_top,
    % stays at 20° through the sac, then unwinds back toward midline
    % between Z_sac_bot and Z_dneck_bot.
    X_aorta = nan(size(Z_aorta));
    R_aorta = nan(size(Z_aorta));
    angle_rad = deg2rad(20);
    for i = 1:numel(Z_aorta)
        z = Z_aorta(i);
        if z < Z_neck_top
            X_aorta(i) = xc0;
        elseif z <= Z_sac_bot
            % Tilted segment: linear in (z - Z_neck_top)
            X_aorta(i) = xc0 + (z - Z_neck_top) * tan(angle_rad);
        else
            % Unwind toward midline over the distal-neck band
            x_at_sac_bot = xc0 + (Z_sac_bot - Z_neck_top) * tan(angle_rad);
            t = (z - Z_sac_bot) / (Z_dneck_bot - Z_sac_bot);
            X_aorta(i) = (1-t) * x_at_sac_bot + t * (xc0 + 4);
            % Bifurcation lands a couple mm off-midline — realistic
        end

        if z < Z_renals
            R_aorta(i) = 13.0;                                   % suprarenal
        elseif z <= Z_neck_top
            t = (z - Z_renals) / (Z_neck_top - Z_renals);
            R_aorta(i) = 13.0 * (1-t) + 13.5 * t;                % renal→neck taper
        elseif z <= Z_neck_bot
            R_aorta(i) = 13.5;                                   % neck (constant 27 mm dia)
        elseif z <= Z_sac_peak
            t = (z - Z_neck_bot) / (Z_sac_peak - Z_neck_bot);
            R_aorta(i) = 13.5 * (1-t) + 30.0 * t;                % sac up
        elseif z <= Z_sac_bot
            t = (z - Z_sac_peak) / (Z_sac_bot - Z_sac_peak);
            R_aorta(i) = 30.0 * (1-t) + 11.0 * t;                % sac down
        else
            R_aorta(i) = 11.0;                                   % distal neck (22 mm dia)
        end
    end
    P_aorta = [repmat(yc_mm, numel(Z_aorta), 1), X_aorta, Z_aorta];

    % --- Iliacs + femorals (full pelvic anatomy) --------------------
    % Anatomical levels (mm from top of FOV):
    %   z =  168   aortic bifurcation     (CIA origin)
    %   z =  225   iliac bifurcation       (CIA → EIA + IIA)
    %   z =  265   inguinal ligament       (EIA → CFA)
    %   z =  310   femoral bifurc level   (CFA terminus, end of FOV)
    Z_iliac_bifurc = 225;
    Z_inguinal     = 265;
    Z_cfa_term     = 310;
    splay_deg      = 18;
    seg = phantom.segments();

    [P_RCIA, R_RCIA] = seg.iliac(P_aorta(end,:), Z_dneck_bot, Z_iliac_bifurc, -1, ...
        4.5, 4.5, splay_deg);                 % CIA 9 mm diameter, ~57 mm long
    [P_LCIA, R_LCIA] = seg.iliac(P_aorta(end,:), Z_dneck_bot, Z_iliac_bifurc, +1, ...
        4.5, 4.5, splay_deg);

    [P_REIA, R_REIA] = seg.eia(P_RCIA(end,:), Z_iliac_bifurc, Z_inguinal, -1, ...
        4.0, 4.0);                            % EIA 8 mm, ~40 mm long
    [P_LEIA, R_LEIA] = seg.eia(P_LCIA(end,:), Z_iliac_bifurc, Z_inguinal, +1, ...
        4.0, 4.0);

    [P_RCFA, R_RCFA] = seg.cfa(P_REIA(end,:), Z_inguinal, Z_cfa_term, -1, ...
        4.0, 4.5);                            % CFA 8 → 9 mm, the access vessel
    [P_LCFA, R_LCFA] = seg.cfa(P_LEIA(end,:), Z_inguinal, Z_cfa_term, +1, ...
        4.0, 4.5);

    [P_RIIA, R_RIIA] = seg.hypogastric(P_RCIA(end,:), -1, 2.5);
    [P_LIIA, R_LIIA] = seg.hypogastric(P_LCIA(end,:), +1, 2.5);

    % --- Visceral branches off the (suprarenal) aorta ---------------
    [P_celiac, R_celiac] = seg.branch( ...
        seg_point_at_z(P_aorta, Z_celiac), [-1 0 0],   30, 3.0);
    [P_sma,    R_sma]    = seg.branch( ...
        seg_point_at_z(P_aorta, Z_sma),    [-1 0 0.3], 50, 3.5);
    [P_renalR, R_renalR] = seg.branch( ...
        seg_point_at_z(P_aorta, Z_renals), [0 -1 0],   40, 2.5);
    [P_renalL, R_renalL] = seg.branch( ...
        seg_point_at_z(P_aorta, Z_renals - 2), [0 +1 0], 40, 2.5);
    % IMA: stenotic-ish (1 mm radius — realistic for AAA where the
    % IMA is often partially occluded) but still visible.
    [P_ima,    R_ima]    = seg.branch( ...
        seg_point_at_z(P_aorta, 95),       [-1 0 0.4], 25, 1.0);

    % --- Rasterize ---------------------------------------------------
    mask = false(sz);
    segments = { ...
        P_aorta,  R_aorta,  ...
        P_RCIA,   R_RCIA,   ...
        P_LCIA,   R_LCIA,   ...
        P_REIA,   R_REIA,   ...
        P_LEIA,   R_LEIA,   ...
        P_RCFA,   R_RCFA,   ...
        P_LCFA,   R_LCFA,   ...
        P_RIIA,   R_RIIA,   ...
        P_LIIA,   R_LIIA,   ...
        P_celiac, R_celiac, ...
        P_sma,    R_sma,    ...
        P_renalR, R_renalR, ...
        P_renalL, R_renalL, ...
        P_ima,    R_ima};
    for k = 1:2:numel(segments)
        mask = phantom.sweep_tube(sz, pix_mm, ssp_mm, ...
            segments{k}, segments{k+1}, mask);
    end

    vol = phantom.synth_ct_from_mask(mask);

    % --- Distal-up centerlines --------------------------------------
    % Convention: distal=node 1, proximal=last. Right side runs CFA →
    % EIA → CIA → aorta → suprarenal so the seed point sits on a real
    % CFA node. Left side runs CFA → EIA → CIA → bifurc.
    Pv_mm_right_distalup = [flipud(P_RCFA); flipud(P_REIA); flipud(P_RCIA); flipud(P_aorta)];
    R_mm_right_distalup  = [flipud(R_RCFA); flipud(R_REIA); flipud(R_RCIA); flipud(R_aorta)];
    Pv_mm_left_distalup  = [flipud(P_LCFA); flipud(P_LEIA); flipud(P_LCIA)];
    R_mm_left_distalup   = [flipud(R_LCFA); flipud(R_LEIA); flipud(R_LCIA)];
    bifurc_node_right = size(P_RCFA, 1) + size(P_REIA, 1) + size(P_RCIA, 1) + 1;

    % --- Landmarks (indices on Pv_mm_right) -------------------------
    aortic_z = Pv_mm_right_distalup(bifurc_node_right:end, 3);
    [~, k_renals]  = min(abs(aortic_z - Z_renals));
    [~, k_bifurc]  = min(abs(aortic_z - Z_dneck_bot));
    landmarks = struct( ...
        'lowest_renal',         bifurc_node_right + k_renals - 1, ...
        'aortic_bifurc',        bifurc_node_right + k_bifurc - 1, ...
        'right_iliac',          1, ...
        'left_iliac',           1, ...
        'right_internal_iliac', size(P_RCFA, 1) + size(P_REIA, 1), ...
        'left_internal_iliac',  size(P_LCFA, 1) + size(P_LEIA, 1), ...
        'aneurysm_start',       bifurc_node_right + ...
                                find_idx_at_z(aortic_z, Z_neck_bot) - 1);

    seeds_vox = struct( ...
        'proximal',  mm_to_vox(Pv_mm_right_distalup(end,:),  pix_mm, ssp_mm), ...
        'right_cfa', mm_to_vox(Pv_mm_right_distalup(1,:),    pix_mm, ssp_mm), ...
        'left_cfa',  mm_to_vox(Pv_mm_left_distalup(1,:),     pix_mm, ssp_mm));

    out = struct();
    out.vol               = vol;
    out.mask              = mask;
    out.Pv_mm_right       = Pv_mm_right_distalup;
    out.R_mm_right        = R_mm_right_distalup;
    out.Pv_mm_left        = Pv_mm_left_distalup;
    out.R_mm_left         = R_mm_left_distalup;
    out.bifurc_node_right = bifurc_node_right;
    out.seeds_vox         = seeds_vox;
    out.landmarks         = landmarks;
    out.pixel_mm          = pix_mm;
    out.slice_spacing_mm  = ssp_mm;
    out.is_volume         = true;
    out.dicom_meta = struct( ...
        'patient_id',        'PHANTOM_AAA_MALE', ...
        'study_date',        '2026-05-07', ...
        'series',            'Synthetic phantom — 6 cm AAA, IFU compliant', ...
        'pixel_mm',          pix_mm, ...
        'slice_spacing_mm',  ssp_mm);
    out.app_version       = '1.1.0-phantom';
    out.Pv_mm  = out.Pv_mm_right;
    out.R_mm   = out.R_mm_right;
    out.arc_mm = [0; cumsum(vecnorm(diff(out.Pv_mm,1,1), 2, 2))];
end

% =========================================================================
function pt_mm = seg_point_at_z(P, z_target)
    [~, k] = min(abs(P(:,3) - z_target));
    pt_mm = P(k, :);
end

function vox = mm_to_vox(pt_mm, pix_mm, ssp_mm)
    vox = [round(pt_mm(1) / pix_mm(1)) + 1, ...
           round(pt_mm(2) / pix_mm(2)) + 1, ...
           round(pt_mm(3) / ssp_mm)    + 1];
end

function k = find_idx_at_z(zs, z_target)
    [~, k] = min(abs(zs - z_target));
end
