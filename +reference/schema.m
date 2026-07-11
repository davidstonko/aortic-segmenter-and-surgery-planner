function s = schema()
%REFERENCE.SCHEMA  Authoritative shape of a reference-annotation JSON.
%
%   S = reference.schema()
%
%   Returns a struct describing the JSON files this project consumes for
%   the TeraRecon-comparison benchmark (goal #5). One JSON per case; each
%   file pairs a CT case with the sizing measurements an expert made in
%   the reference tool (TeraRecon Aquarius / iNtuition typically).
%
%   The schema is versioned so future additions don't silently break old
%   files. Loaders should verify `schema_version` before reading.
%
%   Fields:
%     .schema_version   "1.0"
%     .case_name        sub-directory basename of the CT case
%     .reference_tool   free-text identifier (e.g. "TeraRecon Aquarius iNtuition")
%     .annotator        initials / name of the person who made the measurements
%     .annotation_date  ISO date "YYYY-MM-DD"
%     .measurements     struct with the scalars below (mm, deg)
%         .neck_diameter_mm
%         .neck_length_mm
%         .neck_angulation_deg          infrarenal neck-to-sac angle
%                                       (beta) — the canonical angle used
%                                       for device eligibility
%         .neck_angulation_alpha_deg    suprarenal-to-neck angle (alpha;
%                                       optional, may be NaN)
%         .neck_angulation_beta_deg     infrarenal neck-to-sac angle
%                                       (beta; optional — equals
%                                       neck_angulation_deg)
%         .iliac_R_diameter_mm
%         .iliac_R_length_mm
%         .iliac_L_diameter_mm
%         .iliac_L_length_mm
%         .aneurysm_max_diameter_mm
%         .distance_lowest_renal_to_bifurcation_mm
%         .bifurcation_angle_deg                     (added 2026-05-20)
%     .notes            free text — caveats, image quality, second-look concerns
%     .uncertainty_mm   estimated 1-sigma measurement uncertainty (default 1 mm)
%
%   Any measurement field may be NaN if the case didn't have that anatomy
%   (e.g. no aneurysm) or the annotator couldn't measure it confidently.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    s = struct();
    s.schema_version = '1.0';
    s.required_fields = { ...
        'schema_version', 'case_name', 'reference_tool', 'annotator', ...
        'annotation_date', 'measurements'};
    s.measurement_fields = { ...
        'neck_diameter_mm', ...
        'neck_length_mm', ...
        'neck_angulation_deg', ...
        'iliac_R_diameter_mm', ...
        'iliac_R_length_mm', ...
        'iliac_L_diameter_mm', ...
        'iliac_L_length_mm', ...
        'aneurysm_max_diameter_mm', ...
        'distance_lowest_renal_to_bifurcation_mm', ...
        'bifurcation_angle_deg'};
end
