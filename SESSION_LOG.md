# Phase 3 session log — what got built while you were away

> **⚠️ HISTORICAL — superseded by [STATUS.md](STATUS.md) and
> [CHANGELOG.md](CHANGELOG.md) as of 2026-05-18.** This is the original
> Phase 3 bootstrap session log from May 5, 2026. The "Done" /
> "Partway" / "To fill in" lists reflect the state at that point and
> are no longer accurate. For the live state, read `STATUS.md`.

## Summary

Phase 3 directory bootstrapped with a working JohnDoe1 EVAR data pipeline. Three pieces are done and ready to use; one piece (full-aorta centerline) is partway and has a clear path forward.

## Done

### 1. DICOM viewer — `+preprocess/dicom_viewer.m`

A standalone, dual-mode interactive viewer that adapts to the input data type:

- **CT volumes** open in a 3-pane layout: axial / coronal / sagittal, each with its own slider; window/level presets for Abdomen / Vessel / Bone / Lung; right-side panel with full DICOM metadata; sample-histogram pane with live W/L bands; right-click + drag for free W/L adjustment; "Save snapshot…" button.
- **XA cines** open in a single pane: frame slider; ▶ Play / ⏸ Pause toggle with adjustable fps; full DICOM metadata panel (modality, dimensions, series description, **C-arm primary/secondary angles, SID, SOD**); right-click W/L; save snapshot.

Use it interactively from MATLAB:

```matlab
cd '/Users/.../Vascular Mathematical Modeling/phase-3-real-EVAR'
preprocess.dicom_viewer('/Users/.../JohnDoe1 EVAR/.../CT-series/')   % CT
preprocess.dicom_viewer('/Users/.../JohnDoe1 EVAR/.../XA-cine/')   % XA cine
```

Or feed a struct from a previous load (much faster — no re-read):
```matlab
load('results/logs/ct_volume.mat')
preprocess.dicom_viewer(D_ct)
```

### 2. DICOM cataloging — `+preprocess/dicom_list.m`, `+preprocess/dicom_series.m`

Recursively scans a folder, reads every DICOM header, groups by SeriesInstanceUID. One row per series with modality, frame count, descriptions, gantry pose. The JohnDoe1 archive cataloged into 12 series (1 CT + 11 XA), saved to `results/logs/series_catalog.mat`.

The JohnDoe1 XA inventory (run `disp(S)` to see it):
- **5 fluoroscopy cines** at two gantry views (+10°/+10° and −2°/−20°), 1–128 frames each
- **5 "Abdomen Frontal 3fps" DSA runs** at the same two views, 17–29 frames each, with the iliac vasculature opacified
- **2 stills**

Contact-sheet of all 11 XA series saved to `results/figures/xa_contact_sheet.png`.

### 3. Centerline survey + partial implementation — `CENTERLINE_METHODS.md`, `+preprocess/segment_aorta_thresh.m`, `+preprocess/centerline_skel.m`, `+preprocess/centerline_to_mm.m`, `demo_centerline.m`

Comprehensive literature survey of five centerline-extraction families:
1. **VMTK** (Voronoi-based, gold standard for vessels — used in 3D Slicer)
2. **TotalSegmentator + bwskel** (NN segmentation + morphological thinning)
3. **Frangi vesselness + ridge tracking** (`fibermetric` in MATLAB)
4. **Cohen-Kimmel fast-marching minimum paths** (what VMTK uses internally)
5. **Threshold + connectivity + skeletonise** (zero dependencies, what we implemented)

End-to-end pipeline runs on the JohnDoe1 CT in ~60 seconds and produces:

| metric | value |
|---|---:|
| polyline | 207 nodes |
| arc length | 153 mm |
| radius range | 2.0–9.1 mm |
| median radius | 4.7 mm |

QC figure at `results/figures/centerline_qc.png` shows the centerline is **iliac bifurcation only** — the radius profile cleanly traces 2 mm → 9 mm peak → 2 mm (one iliac → aorta-iliac junction → other iliac), but doesn't continue up the aorta. This is the expected limitation of threshold-based segmentation on a contrast-rich abdominal CTA where the aorta connects to kidneys/heart/visceral arteries through the renal/celiac/SMA hila. The radius filter cleanly removes those branches but also fragments the aorta proximal to the bifurcation.

## Two paths to a fully aortic centerline

**Path B is now built and working** in this session (see "4. Seed-based centerline" below). **Path A** is the long-term robust path for the 25-case cohort.

### Path A: TotalSegmentator integration (recommended for cohort)

```bash
# Outside MATLAB, install once:
pip install TotalSegmentator

# Per case, on the CT folder:
TotalSegmentator -i /Users/.../JohnDoe1\ EVAR/.../CT-series/ \
                 -o phase-3-real-EVAR/data/JohnDoe1_seg/ \
                 --roi_subset aorta iliac_artery_left iliac_artery_right
# Output: aorta.nii.gz, iliac_artery_left.nii.gz, iliac_artery_right.nii.gz
```

Then in MATLAB:
```matlab
mask = niftiread('data/JohnDoe1_seg/aorta.nii.gz') > 0;
mask_left  = niftiread('data/JohnDoe1_seg/iliac_artery_left.nii.gz') > 0;
mask_right = niftiread('data/JohnDoe1_seg/iliac_artery_right.nii.gz') > 0;
mask_all = mask | mask_left | mask_right;
[skel, polyline_vox, R_vox] = preprocess.centerline_skel(mask_all, ...
    struct('min_branch_length', 30, 'smooth_window', 25, 'min_radius_vox', 0));
```

The threshold-segmentation step disappears entirely. Estimated effort: ~2 hours (mostly conda-environment plumbing).

### 4. Seed-based centerline — `+preprocess/build_skeleton_graph.m`, `+preprocess/centerline_seeds.m` (built this session)

End-to-end flow that lets you specify landmark seeds (proximal aorta, bifurcation, iliac terminus) and get the centerline that visits them in order via shortest path on the skeleton graph. Demo `demo_centerline_seeded.m` produces a **909 mm centerline** spanning the entire aorta-to-iliac trajectory on the JohnDoe1 CT, with the inscribed-sphere radius peaking at 7.8 mm in the abdominal aortic segment (consistent with anatomy). QC: `results/figures/centerline_seeded_qc.png`.

Three new modules:
- `build_skeleton_graph` — bwskel + radius-filter + 26-connected graph with optional VMTK-style 1/R^p edge weighting (defaults to p=2 so paths prefer fat tubes).
- `nearest_skeleton_voxel` — maps an arbitrary voxel coord to its closest skeleton-graph node.
- `centerline_seeds` — walks `shortestpath(G, s_k, s_{k+1})` for consecutive seeds and concatenates.

Usage:
```matlab
S = preprocess.build_skeleton_graph(mask, ...
        struct('min_branch_length', 30, 'radius_weight_pow', 2));
seeds = [220 250 650; 270 250 900; 320 200 1100];   % [y x z] voxels
[poly_vox, R_vox] = preprocess.centerline_seeds(S, seeds);
[Pv_mm, R_mm] = preprocess.centerline_to_mm(poly_vox, R_vox, D_ct);
```

The user can read seed voxel coordinates off the DICOM viewer's slice/frame label (e.g. "Slice 650 / 1219"), or wire up a small `figure` + `ginput` GUI later.

## Other Phase 3 stubs to fill in

(From the implementation plan, in priority order:)

1. **CT-to-C-arm registration** (`+preprocess/register_ct_to_carm.m`) — rigid alignment via shared bony landmarks. The plan flagged this as the largest single source of systematic error; needs a unit test against a synthetic phantom.
2. **Wire extraction from the angio** (`+preprocess/extract_wire.m`) — Frangi vesselness on a 2D fluoro frame → skeletonise → polyline-fit → 2D measure $\nu_{\text{wire}}$ for the Wasserstein loss.
3. **Landmark GUI** (`+preprocess/landmark_gui.m`) — semi-auto: prompt user to click the lowest renal ostium and the aortic bifurcation on a chosen DSA frame. Output: 2D landmark measure.
4. **End-to-end driver** (`+sim/run_case.m`) — preop CT + parameters → centerline + frames → forward equilibrium (from Phase 2) → projection through DICOM-derived $T_C$ → 2D Wasserstein loss vs. observed angiogram.

## Files created this session

```
phase-3-real-EVAR/
├── CENTERLINE_METHODS.md            # method survey
├── README.md                        # status + how-to-use
├── SESSION_LOG.md                   # this file
├── demo_centerline.m                # end-to-end pipeline demo
└── +preprocess/
    ├── dicom_list.m
    ├── dicom_series.m
    ├── dicom_load.m
    ├── dicom_viewer.m
    ├── segment_aorta_thresh.m
    ├── segment_aorta_per_slice.m    # work-in-progress, not used
    ├── centerline_skel.m
    └── centerline_to_mm.m

results/
├── figures/
│   ├── dicom_viewer_ct_test.png      # original 1-pane test
│   ├── dicom_viewer_ct_3pane.png     # polished 3-orth-pane CT
│   ├── dicom_viewer_xa_cine.png      # cine viewer screenshot
│   ├── xa_contact_sheet.png          # all 11 XA series at a glance
│   └── centerline_qc.{fig,png}       # iliac-bifurcation centerline + radius profile
└── logs/
    ├── ct_volume.mat                 # cached CT (1.3 GB, faster reload)
    ├── series_catalog.mat            # all 12 series
    └── centerline.mat                # current centerline + mask + skeleton
```

## What I'd want to see when you're back

- Pick which path (A or B) you want to take to get the full aorta. If A, install TotalSegmentator first; if B, I'll write the MATLAB code for the seed picker + fast marching.
- Also: any opinions on whether the per-slice approach (`segment_aorta_per_slice.m`) is worth debugging — it has a buggy mask-assignment step but the algorithm idea (axial-slice roundness scoring + continuity tracking) is sound and would give a clean aorta-only mask without any external dependencies.
