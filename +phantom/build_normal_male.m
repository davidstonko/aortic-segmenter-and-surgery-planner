function out = build_normal_male()
%PHANTOM.BUILD_NORMAL_MALE  Generate a programmatic phantom of normal
%   adult male abdominal aortic anatomy with all first-order branches.
%
%   OUT = phantom.build_normal_male()  returns a complete case struct
%   ready for library.save_case():
%
%       .vol               synthetic CT (HU)
%       .mask              vessel mask (logical)
%       .Pv_mm_right       right centerline (R-CFA → suprarenal aorta)
%       .R_mm_right        per-node radius (mm)
%       .Pv_mm_left        left centerline (L-CFA → joins right at bifurc)
%       .R_mm_left         per-node radius (mm)
%       .bifurc_node_right index on Pv_mm_right where L-CFA joins
%       .seeds_vox         struct with proximal / right_cfa / left_cfa
%       .landmarks         pre-set indices for renals, bifurc, iliacs, etc.
%       .dicom_meta        synthetic metadata (patient_id = 'PHANTOM_NORMAL_MALE')
%       .pixel_mm, .slice_spacing_mm
%
%   Geometry summary
%       FOV:                256 × 256 × 320 voxels @ 0.7 mm/voxel
%                           = 17.9 × 17.9 × 22.4 cm
%       Z = 1 corresponds to the diaphragm; Z = 320 to mid-thigh.
%       Aorta runs centrally along the Z axis with mild physiologic
%       lordosis. All first-order visceral branches included:
%       celiac, SMA, both renals, IMA. Iliacs split into hypogastric
%       (IIA) and external iliac (EIA → CFA).
%
%   The output is deterministic — same inputs, same phantom, every
%   call. Random fluctuations (HU noise) use a fixed seed.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    rng(20260506, 'twister');   % deterministic noise

    sz     = [256 256 320];
    pix_mm = [0.7 0.7];
    ssp_mm = 0.7;

    % --- Aorta centerline (suprarenal → bifurcation) -----------------
    % Position: centered (X=128) and slightly posterior (Y=144) of the
    % body ellipse center.
    Y_aorta = 144;   X_aorta = 128;
    yc_mm = (Y_aorta - 1) * pix_mm(1);
    xc_mm = (X_aorta - 1) * pix_mm(2);

    % Z waypoints (in mm) along the aorta. We sample at 2 mm.
    Z_top_mm    = 5;     % just below diaphragm
    Z_celiac    = 10;    % T12-L1, anterior origin
    Z_sma       = 30;    % L1, anterior, just below celiac
    Z_renals    = 50;    % L1-L2, lateral
    Z_ima       = 95;    % L3, anterior
    Z_bifurc    = 135;   % L4-L5, aortic bifurcation
    Z_aorta = (Z_top_mm:2:Z_bifurc).';

    % Radius profile: 12.5 mm suprarenal, taper to 10 mm just below
    % renals, then 10 → 9 mm down to the bifurcation.
    R_aorta = nan(size(Z_aorta));
    for i = 1:numel(Z_aorta)
        z = Z_aorta(i);
        if z < Z_renals
            R_aorta(i) = 12.5;
        elseif z < Z_renals + 8
            % Smooth taper across 8 mm
            t = (z - Z_renals) / 8;
            R_aorta(i) = 12.5 * (1-t) + 10 * t;
        else
            t = min(1, (z - (Z_renals+8)) / (Z_bifurc - (Z_renals+8)));
            R_aorta(i) = 10 * (1-t) + 9 * t;
        end
    end

    P_aorta = [repmat(yc_mm, numel(Z_aorta), 1), ...
               repmat(xc_mm, numel(Z_aorta), 1), ...
               Z_aorta];

    % --- Iliacs + femorals (full pelvic anatomy) ---------------------
    % Anatomical levels (mm from top of FOV):
    %   z = 135   aortic bifurcation     (CIA origin)
    %   z = 195   iliac bifurcation       (CIA → EIA + IIA)
    %   z = 245   inguinal ligament       (EIA → CFA)
    %   z = 310   CFA terminus            (femoral bifurcation, end of FOV)
    Z_iliac_bifurc = 195;
    Z_inguinal     = 245;
    Z_cfa_term     = 310;
    splay_deg      = 18;
    seg = phantom.segments();

    [P_RCIA, R_RCIA] = seg.iliac(P_aorta(end,:), Z_bifurc, Z_iliac_bifurc, -1, ...
        6.0, 5.5, splay_deg);                % CIA 12 mm diameter
    [P_LCIA, R_LCIA] = seg.iliac(P_aorta(end,:), Z_bifurc, Z_iliac_bifurc, +1, ...
        6.0, 5.5, splay_deg);

    [P_REIA, R_REIA] = seg.eia(P_RCIA(end,:), Z_iliac_bifurc, Z_inguinal, -1, ...
        4.0, 4.0);                            % EIA 8 mm
    [P_LEIA, R_LEIA] = seg.eia(P_LCIA(end,:), Z_iliac_bifurc, Z_inguinal, +1, ...
        4.0, 4.0);

    [P_RCFA, R_RCFA] = seg.cfa(P_REIA(end,:), Z_inguinal, Z_cfa_term, -1, ...
        4.0, 4.5);                            % CFA 8 → 9 mm
    [P_LCFA, R_LCFA] = seg.cfa(P_LEIA(end,:), Z_inguinal, Z_cfa_term, +1, ...
        4.0, 4.5);

    [P_RIIA, R_RIIA] = seg.hypogastric(P_RCIA(end,:), -1, 2.5);
    [P_LIIA, R_LIIA] = seg.hypogastric(P_LCIA(end,:), +1, 2.5);

    % --- Visceral branches off the aorta -----------------------------
    [P_celiac, R_celiac] = seg.branch( ...
        seg_point_at_z(P_aorta, Z_celiac), [-1 0 0],   30, 3.0);
    [P_sma,    R_sma]    = seg.branch( ...
        seg_point_at_z(P_aorta, Z_sma),    [-1 0 0.3], 50, 3.5);
    [P_renalR, R_renalR] = seg.branch( ...
        seg_point_at_z(P_aorta, Z_renals), [0 -1 0],   40, 2.5);
    [P_renalL, R_renalL] = seg.branch( ...
        seg_point_at_z(P_aorta, Z_renals - 2), [0 +1 0], 40, 2.5);
    [P_ima,    R_ima]    = seg.branch( ...
        seg_point_at_z(P_aorta, Z_ima),    [-1 0 0.4], 30, 1.5);

    % --- Rasterize into a single mask --------------------------------
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

    % --- Synthetic CT volume -----------------------------------------
    % Built on demand here so callers can use it directly. Note: the
    % saved-to-disk phantom strips this field for size, and recreates
    % it via phantom.synth_ct_from_mask(mask) when loaded.
    vol = phantom.synth_ct_from_mask(mask);

    % --- Build the dual centerline output -----------------------------
    % Convention: each polyline reads distal → proximal, so the FIRST
    % node is the CFA (where the user clicked) and the LAST is the
    % suprarenal aorta. We need to flip every segment that was built
    % proximal → distal.
    Pv_mm_right_distalup = [flipud(P_RCFA); flipud(P_REIA); flipud(P_RCIA); flipud(P_aorta)];
    R_mm_right_distalup  = [flipud(R_RCFA); flipud(R_REIA); flipud(R_RCIA); flipud(R_aorta)];
    Pv_mm_left_distalup  = [flipud(P_LCFA); flipud(P_LEIA); flipud(P_LCIA)];
    R_mm_left_distalup   = [flipud(R_LCFA); flipud(R_LEIA); flipud(R_LCIA)];

    % Bifurc on right polyline = first aortic node, i.e. CFA + EIA + CIA
    % nodes lie below it.
    bifurc_node_right = size(P_RCFA, 1) + size(P_REIA, 1) + size(P_RCIA, 1) + 1;

    % --- Pre-set landmark indices on right centerline ----------------
    % Use seg_point_at_z on the aortic-portion of the right centerline
    % to find the renal level, etc.
    aortic_portion = Pv_mm_right_distalup(bifurc_node_right:end, :);
    aortic_z       = aortic_portion(:, 3);
    [~, k_renals] = min(abs(aortic_z - Z_renals));
    [~, k_bifurc] = min(abs(aortic_z - Z_bifurc));
    landmarks = struct( ...
        'lowest_renal',     bifurc_node_right + k_renals - 1, ...
        'aortic_bifurc',    bifurc_node_right + k_bifurc - 1, ...
        'right_iliac',      1, ...                                    % R-CFA = node 1
        'left_iliac',       1, ...                                    % L-CFA = node 1 on left
        'right_internal_iliac', size(P_RCFA,1) + size(P_REIA,1), ...  % iliac bifurc on right
        'left_internal_iliac',  size(P_LCFA,1) + size(P_LEIA,1));     % iliac bifurc on left

    % --- Voxel coordinates of the three seeds ------------------------
    seeds_vox = struct( ...
        'proximal',  mm_to_vox(Pv_mm_right_distalup(end,:),  pix_mm, ssp_mm), ...
        'right_cfa', mm_to_vox(Pv_mm_right_distalup(1,:),    pix_mm, ssp_mm), ...
        'left_cfa',  mm_to_vox(Pv_mm_left_distalup(1,:),     pix_mm, ssp_mm));

    % --- Pack -------------------------------------------------------
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
        'patient_id',        'PHANTOM_NORMAL_MALE', ...
        'study_date',        '2026-05-06', ...
        'series',            'Synthetic phantom — normal male anatomy', ...
        'pixel_mm',          pix_mm, ...
        'slice_spacing_mm',  ssp_mm);
    out.app_version       = '1.1.0-phantom';
    % Singular aliases for back-compat with single-centerline consumers
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
