# Phase 3 GUI — final architecture proposal

This supersedes the earlier scoping document. Decisions below are based on parallel research into (a) interactive aortic segmentation in MATLAB, (b) centerline extraction algorithms, (c) MATLAB GUI patterns for clinical imaging apps, and (d) existing MATLAB-native vascular tools we could reuse.

## Headline findings

**1. There is no end-to-end MATLAB tool we can adapt.** The vascular ecosystem is fragmented: 3D Slicer + VMTK is the gold standard but Python/C++; published academic centerline code lives in ITK/VTK; MATLAB Central has scattered building blocks but no integrated "click-CT-get-centerline" app. Building this app is the right call.

**2. MATLAB ships with everything we need.** Image Processing Toolbox (R2025b) has all four pillars built in:
- `fibermetric` — multi-scale Frangi vesselness (the modern replacement for hand-rolled Frangi)
- `imsegfmm` — interactive fast-marching segmentation, takes seed indices and returns mask
- `bwskel` — 3D medial-axis thinning with branch pruning
- `shortestpath` on `graph` — Dijkstra on the skeleton graph
- `drawfreehand` (R2024b+) — built-in interactive ROI for paint cleanup
- `volumeSegmenter` / `imageSegmenter` apps — for reference patterns
- `niftiread` / `niftiwrite` — for TotalSegmentator output later if we choose to integrate

**3. GraphCut in MATLAB is GUI-only.** Boykov–Jolly graph cuts are *inside* `imageSegmenter` and `volumeSegmenter` but not exposed as a callable function. So if we want graph-cut, we'd have to roll our own (~400 lines) or pick a different segmentation primitive. **Recommendation: use `imsegfmm` (fast marching from seeds) as the primary segmentation engine — it's a callable function, takes a click as input, and is purpose-built for the connected-tubular-structure problem we have.**

**4. Centerline winner: `bwskel` + `shortestpath` + Catmull-Rom smoothing.** All native, sub-second on a 512×512×1219 volume, no external dependencies. Catmull-Rom (not Savitzky-Golay) for the smoothing because it gives clean C¹ curves that the Cosserat-rod model wants.

**5. GUI framework: App Designer (`.mlapp`).** Visual layout editor handles the 3-pane viewer cleanly; class-based state encapsulation makes the 5-step state machine explicit; MATLAB Compiler ships it as a standalone `.app`/`.exe` with zero glue.

## Final architecture

### State machine

The app is a single `.mlapp` class with 5 explicit states, gated by prerequisites. Forward buttons disabled until prerequisites met. Backward navigation always allowed.

```
   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
   │ 1. LOAD  │ -> │ 2. SEG   │ -> │ 3. SEEDS │ -> │ 4. COMPUTE │ -> │ 5. EXPORT│
   │ CT/NIfTI │    │  AORTA   │    │  2 CLICKS│    │ CENTERLINE │    │   .mat   │
   └──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
        │              │                │               │                 │
        ▼              ▼                ▼               ▼                 ▼
   uialert: OK   live preview     overlaid on 3D    polyline +       file dialog
                  + paint/erase   segmentation       radius QC        with default
                                                    figure              filename
```

### UI layout

```
┌────────────────────────────────────────────────────────────────────────────┐
│ AINN/EVAR — Aortic Centerline Builder                                      │
├──────────────────────────────────────────────────────────────────────────-─┤
│ [step 1 ✓ Load CT]  [step 2 → Segment]  [step 3 ─ Seeds]  ...              │
├────────────────────────────────────────────────────────────────────────────┤
│  ┌────────┐  ┌────────┐  ┌────────┐    │  ┌──────────────────────────┐    │
│  │        │  │        │  │        │    │  │ Step 2: Segment aorta   │     │
│  │ Axial  │  │Coronal │  │Sagital │    │  │                          │    │
│  │  pane  │  │  pane  │  │  pane  │    │  │ Click on the aorta in    │    │
│  │        │  │        │  │        │    │  │ any pane.                │    │
│  └────────┘  └────────┘  └────────┘    │  │                          │    │
│  ───────    ───────    ───────         │  │ Live preview:            │    │
│                                        │  │  • Vesselness threshold  │    │
│  ┌──────────────────────────┐          │  │  • [ slider ]            │    │
│  │   3D rendering of seg    │          │  │                          │    │
│  └──────────────────────────┘          │  │ Tools:                   │    │
│                                        │  │  [ Brush ]  [ Eraser ]   │    │
│ Window: [ Vessel ▾ ]  W=700 L=150      │  │  [ Undo ] [ Redo ]       │    │
│                                        │  │                          │    │
│                                        │  │  [ ✓ Done — go to step 3]│    │
│                                        │  └──────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────────┘
```

### Segmentation engine (Step 2)

**Pipeline.** Per the research synthesis:

```
  CT volume D.vol  (HU)
      │
      ▼  fibermetric(D.vol, [3 5 8 12], 'StructureSensitivity', 0.5,
      │                   'ObjectPolarity','bright')
  vesselness map V (3D, [0,1])
      │
      ▼  user clicks aorta lumen at voxel s_seed
      │
      ▼  imsegfmm(V, s_seed_y, s_seed_x, s_seed_z, threshold)
  raw aorta mask M0
      │
      ▼  imclose(M0, strel('sphere', 1))  // fill micro-gaps
      ▼  imfill(_, 'holes')               // close lumen
      ▼  bwconncomp + largest CC          // remove leaks
  cleaned mask M
      │
      ▼  optional: paint/erase user cleanup
      │
      ▼  M_final
```

**Why `imsegfmm`.** It's the IPT-built-in fast-marching segmentation function. Inputs: cost field (we use vesselness), seed point, threshold. Output: binary mask. It's exactly the click-to-mask primitive we need, and it inherently respects vessel-tube structure because the cost field is vesselness. Handles the "bleed-through into kidneys" problem because the renal artery has lower vesselness than the aorta lumen.

**Why fibermetric preprocessing.** Multi-scale Frangi enhances tubular structures and suppresses round organs (kidneys appear blob-like, low vesselness; aorta appears tube-like, high vesselness). This is the published recipe for vessel segmentation and what 3D Slicer's "Vessels" extension uses internally.

**Brush/eraser (paint cleanup).** Use `drawfreehand` (R2024b+) for the interactive brush stroke; convert the freehand ROI to a binary mask and OR it (brush) or AND-NOT it (eraser) into M. Maintain an undo stack as a cell array of mask snapshots (capped at 20 levels — about 250 MB at peak for our 512×512×1219 volume, acceptable).

### Centerline engine (Step 4)

**Pipeline.** Per the research synthesis:

```
  Mask M  +  seed1 (proximal)  +  seed2 (distal)
      │
      ▼  bwskel(M, 'MinBranchLength', 30)
  Skeleton skel
      │
      ▼  build skeleton-voxel graph (26-connected, Euclidean weights)
      ▼  optional: weight by 1/R^2 (VMTK-style; pulls path into fat tubes)
  graph G
      │
      ▼  map each user seed to nearest graph node
      ▼  shortestpath(G, node_a, node_b)
  raw voxel polyline
      │
      ▼  Catmull-Rom interpolation, 15 points per segment
  smooth polyline
      │
      ▼  for each polyline node: R_vox = D(round(node)) where D = bwdist(~M)
  inscribed-sphere radius array
      │
      ▼  centerline_to_mm(polyline, R_vox, D_ct)
  Pv_mm, R_mm
```

**Why bwskel + shortestpath, not VMTK or fast-marching.** Sub-second runtime, no external dependencies, robust failure modes (the user can see the skeleton overlaid on the segmentation if the path goes weird; we just expand the local ROI and re-run). VMTK's Voronoi-diagram approach is more elegant in 2D but no native 3D MATLAB implementation; fast-marching with 1/R cost gives nearly identical results to bwskel-shortest-path for healthy aortas (the Cohen–Kimmel theorem: medial axis = ridge of distance transform), but requires writing or finding a fast-march solver. Stick with native.

**Catmull-Rom over Savitzky-Golay.** Catmull-Rom is C¹ continuous and passes through every control point — preserves the user's segmentation. Savitzky-Golay is a low-pass filter that *does not pass through control points* and can drift. Cosserat-rod model wants smooth tangents → Catmull-Rom.

### Output schema (Step 5)

```matlab
out.Pv_mm           % N x 3 polyline in patient mm coordinates
out.R_mm            % N x 1 inscribed-sphere radius (mm)
out.arc_mm          % N x 1 cumulative arc length (mm)
out.mask            % uint8 sparse representation of the segmentation
out.seeds_vox       % 2 x 3 [start; end] voxel coords
out.frames_bishop   % struct from frames.bishop applied to Pv_mm
                    %   (ready to drop into demo_phase2 as Pv1)
out.dicom_meta      % patient_id (anon), study_date, pixel_mm, slice_spacing_mm
out.app_version     % '1.0.0' tag for reproducibility
out.click_log       % all user clicks (for re-running deterministically)
```

## File layout

```
phase-3-real-EVAR/
├── AorticCenterlineApp.mlapp          NEW: the App Designer file
├── +preprocess/
│   ├── dicom_load.m                   reused
│   ├── nifti_load.m                   NEW: niftiread wrapper for TotalSegmentator
│   ├── seg_aorta_fmm.m                NEW: fibermetric + imsegfmm + cleanup
│   ├── centerline_skeleton.m          NEW: bwskel + shortest path + Catmull-Rom
│   └── centerline_to_mm.m             reused
├── demo_phase3_app.m                  NEW: launches the app
├── results/
└── STANDALONE_GUI_PLAN.md             this document
```

Old files we keep for reference but the app does not depend on:
- `track_aorta_2click.m`, `seed_picker.m`, `centerline_seeds.m`, `build_skeleton_graph.m`, `segment_aorta_thresh.m`, `segment_aorta_per_slice.m`

## Implementation plan

**Stage 1 (MVP, ~1 day):**
1. Create the `.mlapp` shell with 5 steps and the 3-pane viewer.
2. Implement Step 1 (Load CT) by calling existing `dicom_load.m`.
3. Implement Step 2 (Segment) using `fibermetric` + `imsegfmm` from a single seed click. No paint/erase yet.
4. Implement Step 3 (Click endpoints).
5. Implement Step 4 (Centerline) by calling new `centerline_skeleton.m`.
6. Implement Step 5 (Export) as a `uiputfile` save.

**Stage 2 (polish, ~1 day):**
- Paint/erase brush with `drawfreehand` and undo stack
- Step 1 NIfTI option for TotalSegmentator outputs
- Better window/level controls + presets
- Skeleton overlay on the 3D rendering during Step 4

**Stage 3 (deploy):**
- MATLAB Compiler packaging as `.app`
- Test on 5 of the 25 cases

## Open decisions to confirm before coding

- **Q1**: App Designer (recommended) vs programmatic uifigure (more flexible)? *Default: App Designer.*
- **Q2**: Include the 3D rendering pane or just the 3 orthogonal slices? *Default: orthogonal only for MVP, add 3D as Stage 2.*
- **Q3**: Hand-build paint/erase, or use `imageSegmenter` as the cleanup interface (call out to it for cleanup, return mask)? *Default: hand-build using `drawfreehand`, controlled UX.*
- **Q4**: Default segmentation parameters fixed, or expose a "vesselness threshold" slider? *Default: expose the slider.*
- **Q5**: Save / re-open partial work (resume after closing the app)? *Default: no — every session starts fresh, but the click-log is saved with the export so a re-run is deterministic.*

If you confirm Q1–Q5, I'll start Stage 1 immediately.

## Sources

Research synthesized from four parallel agent reports stored in MATLAB documentation links and File Exchange entries cited in the agents' outputs:
- MATLAB R2025b Image Processing Toolbox: `fibermetric`, `imsegfmm`, `bwskel`, `bwdist`, `graph`/`shortestpath`, `drawfreehand`, `imageSegmenter`, `volumeSegmenter`
- Frangi et al. 1998 (multiscale vessel enhancement)
- Cohen-Kimmel framework (minimal-path centerlines)
- Mortensen-Barrett 1995 (live wire — researched but rejected for MVP)
- VMTK approach (Voronoi-based — researched but external dependency)
