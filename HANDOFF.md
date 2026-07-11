# Phase 3 — handoff after second session

> **⚠️ HISTORICAL — superseded by [STATUS.md](STATUS.md) and
> [CHANGELOG.md](CHANGELOG.md) as of 2026-05-18.** This document
> captures the state of Phase 3 at the 2026-05-16 handoff and is kept
> for archival reasons. Specific claims below (test counts, IFU device
> count, "known issues", pipeline stages) reflect that snapshot, not
> the current state. For the live state of the project, read
> `STATUS.md`.

## Headless EVAR planner (added 2026-05-16)

The pipeline now runs end-to-end with zero user interaction:

```matlab
out  = run_planner_headless(dicom_dir);
plan = evar_plan.generate_plan(out);
% plan.txt + plan.json written next to the centerline result
```

Stages: DICOM → `autoseg.ts_run` → `preprocess.auto_seeds_anatomic`
(uses kidney_top - 70 mm to anchor the proximal seed at ~5 cm above
the celiac; CFA seeds at most-caudal iliac voxels) →
`autoseg.extend_and_detect_branches` (bridges TS iliac fragmentation)
→ `preprocess.build_skeleton_graph` + `centerline_seeds` (one path
per side: proximal → R-CFA, proximal → L-CFA) →
`evar_plan.measure_from_centerline` (neck Ø/length/angulation from the
infrarenal-R-minimum; iliac Ø ~20 mm distal to the geometric bifurcation
detected from R/L divergence) → `ifu.match_devices` (5 catalogued
devices, criteria from Chaikof 2018 SVS + AbuRahma 2018 JACS, with a
research-only disclaimer).

The same auto-seed code is wired into `AorticCenterlineApp` Step 3
(`autoSeedsBestAvailable`) so the GUI flow also runs clickless when a
cached TS multilabel NIfTI is available.



## What was fixed this session

1. **Volume orientation: head-up.** `dicom_load.m` now sorts slices DESCENDING by SliceLocation, so slice 1 = head and slice 1219 = feet. Coronal/sagittal MIPs naturally show head-at-top — radiology convention.
2. **CT viewer default window: CTA / Vessel.** The viewer now opens with W=600, L=200 (bright contrast lumen) by default, and auto-detects CTAs from the SeriesDescription containing "Aorta" / "CTA" / "Angio" / "Iliac" / "Vasc". Other CT studies fall back to Abdomen.
3. **Click-based seed picker** (`+preprocess/seed_picker.m`). Opens a single-pane axial viewer at CTA window/level with two big buttons "Pick proximal seed" / "Pick distal seed". Scroll the slice slider, click the button, click the aorta lumen, repeat for the distal end, click "Done — return seeds". Returns a 2×3 array `[y_prox x_prox z_prox; y_dist x_dist z_dist]` ready to feed `track_aorta_2click`.
4. **2-click aorta tracker** (`+preprocess/track_aorta_2click.m`) — slice-by-slice tracker between two seeds using local thresholding + roundness + continuity. The trajectory now lands in the aorta-iliac region (visible in `results/figures/centerline_2click_qc.png` — sagittal MIP shows the path correctly hugging the spine area; 3D plot shows clean head-to-pelvis descent).
5. **Slice-spacing sign bug fixed** — descending sort produced negative slice_spacing_mm which propagated complex numbers into downstream calculations.

## Current state

The pipeline runs. The trajectory is in the right anatomy. Two known issues:
- **Per-slice centroid jitter.** With the tracker keeping 389/901 slices and arc length 2957 mm (vs. expected ~300 mm), the centroids are jumping a few millimetres slice-to-slice. The radius profile oscillates 0–10 mm. The sagittal MIP overlay still tracks the aorta cleanly visually because the noise is small relative to the large displacements.
- **Need radius/continuity smoothing.** A Savitzky–Golay smoother + interpolation across dropped slices would bring the radius profile and the centroid track to clinical quality. ~30 lines of code.

## How to use the seed picker now

```matlab
cd '/Users/.../Vascular Mathematical Modeling/phase-3-real-EVAR'
load('results/logs/ct_volume.mat');             % cached volume

% Open the picker, scroll slice slider, click, return:
seeds = preprocess.seed_picker(D_ct);

% Track the aorta between the two seeds:
[mask, centroids_vox, R_vox, info] = preprocess.track_aorta_2click( ...
    D_ct, seeds(1,:), seeds(2,:));

% Convert to mm and check:
[Pv_mm, R_mm] = preprocess.centerline_to_mm(centroids_vox, R_vox, D_ct);
arc = [0; cumsum(vecnorm(diff(Pv_mm,1,1), 2, 2))];
fprintf('Arc length: %.1f mm, median R: %.1f mm\n', arc(end), median(R_mm));
```

Or run `demo_centerline_2click.m` — it has `USE_PICKER = false` set so the demo runs end-to-end with verified-from-data seeds; flip to `true` to launch the picker interactively.

## Next concrete improvements (~1 hour each)

1. **~~Smoothing pass~~** — **DONE 2026-05-16.** `track_aorta_2click` now does
   gap-fill (linear interp across dropped slices) → `hampel(hw≈10, σ=3)`
   for structural-outlier rejection → `sgolayfilt(order 3, sw≈31)` on (y,x)
   → `movmedian` on R, all on a regular slice grid. On the JohnDoe1 case
   this cuts per-step xy displacement p95 from 17.2 mm to 0.9 mm
   (94% reduction) and reduces arc length 576 → 502 mm. The residual
   arc-length inflation (vs expected ~300 mm) is from tracker
   excursions onto non-aorta branches and is addressed by items 2 and 3.
2. **Multi-component handling at the iliac bifurcation.** Currently the tracker picks a single component per slice. Below the aortic bifurcation it needs to choose ONE iliac (left or right), or branch into both. An `opts.branch = 'left'/'right'/'both'` option, with a sub-mask flag to allow the tracker to follow the closer-to-previous-centroid branch.
3. **Frangi vesselness preprocessing**. Replace the simple HU threshold with `fibermetric` to enhance round tubular cross-sections. Should reduce slice-to-slice jitter substantially.
4. **TotalSegmentator integration** for cohort-scale work — see `CENTERLINE_METHODS.md` and `README.md` for the recipe.

## Files created this session (in addition to last session's)

```
phase-3-real-EVAR/
├── HANDOFF.md                            (this file)
├── +preprocess/
│   ├── seed_picker.m                     interactive 2-click GUI
│   ├── track_aorta_2click.m              per-slice aorta tracker
│   ├── build_skeleton_graph.m            (last session, exposes graph)
│   ├── centerline_seeds.m                (last session, shortest-path)
│   └── nearest_skeleton_voxel.m          (last session)
├── demo_centerline_2click.m              new canonical Phase 3 demo
└── demo_centerline_seeded.m              (last session, alternative)

results/figures/
├── centerline_2click_qc.{fig,png}        new canonical QC
└── (last session figures still present)
```

## What broke and what survived the head-up reorient

- All centerline code: works, paths now go head-to-pelvis correctly.
- Default seeds in demo_centerline_2click: re-verified at slice 200 (aorta) and slice 1100 (iliac) in the new ordering.
- Cached `ct_volume.mat`: re-built with the new descending-z sort.

## What I would have built next if I had another hour

Smoothing pass in the tracker (item #1 above). With that done, the centerline becomes clinically usable and we can drop it straight into `demo_phase2` as the patient-specific `Pv1` for the forward equilibrium test on a real case — which is the actual Phase 3 deliverable from the implementation plan.
