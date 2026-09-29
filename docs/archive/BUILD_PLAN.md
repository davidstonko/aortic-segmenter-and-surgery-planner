# EVAR Planner — Build Plan

A running record of features that belong in this DICOM viewer / EVAR planner.
Status legend: `[have]`, `[partial]`, `[missing]`. Priority: P1 = needed before
the segmentation-onward workflow ships; P2 = needed once centerline is solid;
P3 = polish / nice-to-have.

## Pre-segmentation viewer must-haves (P1)

These are needed BEFORE the user reaches Step 2 — they're how a clinician
inspects a CTA, confirms contrast quality, and finds the aorta.

- [x] **Zoom that fills the window in 2-D views.** Smart 2-D zoom: shrink
      visible AREA by `factor²`, then reshape XLim/YLim to the panel
      aspect (computed from `axes.Position` × `DataAspectRatio`). Anatomic
      X/Y ratio is strictly enforced (`DataAspectRatioMode = 'manual'`),
      so when you zoom in, top/bottom (or sides) get cropped to make the
      plot box fill the panel without distorting anatomy.
- [x] **Live cursor HU + voxel-coord readout** — bottom-center strip
      under the slice slider; visible from every tab. Shows
      `[y, x, z]  (mm coords)  HU=NNN`.
- [x] **Mouse-wheel = slice scroll** in 2-D MPR views. `Cmd + wheel`
      zooms in 2-D. 3-D Volume / MIP / CPR scroll still zooms (no
      slice index there).
- [x] **W/L click-and-drag** (`Drag: W/L` toggle + `W` key). Drag
      horizontal → window width, vertical → level. Works in axial,
      coronal, sagittal, 3-D MIP, CPR. (Not in 3-D Volume — see P2.)
- [x] **Pan / rotate toggle** (`Drag: ROTATE` ↔ `Drag: PAN`,
      `P` key). 3-D Volume drives `viewer3d.Interactions`; 2-D drives
      a my-own click-drag pan handler.
- [x] **Persistent overlay tools** on every view: Pan toggle, W/L
      toggle, Save snapshot, Reset view. Not bound to Step 1.
- [x] **Reset view** (`Reset view (R)` button + `R` key). AP preset in
      3-D Volume; fit-to-data in 2-D.
- [x] **Home button override** — `viewer3d`'s built-in house icon now
      snaps back to my AP preset (listener on `CameraPositionMode`).
- [x] **Snapshot PNG export** (`Save snapshot (S)` button + `S` key).
      Writes to `results/snapshots/snap_TIMESTAMP.png`.
- [x] **Footer keyboard-shortcut listing** across the bottom.

Still open in P1:

- [x] **Linear distance / caliper tool** (`Measure` toolbar
      button). Click two points in any 2-D pane (single-view or
      2x2) → length in mm. The line stores its endpoints in voxel
      space and projects onto every other 2-D MPR view: solid line
      when an endpoint is within 5 mm of the current slice plane,
      dashed and dimmed when the segment is out-of-plane. The 3-D
      recon (volshow viewer3d) renders the segment as a true 3-D
      bright-yellow line on top of the CT volume. R2025b's
      viewer3d rejects Line / Surface / Patch as children, but it
      accepts MULTIPLE Volume children — so the overlay is built
      as a sparse uint8 annotation volume (same downsampled grid
      as the rendered CT, with the measurement line rasterized
      into it), wrapped in a second volshow that uses a yellow
      transfer function with α=0 at value=0. The composite gives
      a real 3-D line that tracks rotation / pan / zoom for free
      because both volumes share the viewer3d camera.
- [x] **Angle tool** (`∠ Angle` toolbar button). Three-click flow:
      arm 1 endpoint → vertex → arm 2 endpoint. Degrees computed
      in mm-space (anisotropic voxels handled). Same cross-pane
      projection rules as the caliper.
- [x] **Clear measurements** button. Wipes both committed and
      in-progress measurements.
- [ ] Slab MIP with thickness slider (5 / 10 / 20 / 30 / 50 mm). Full-
      volume MIP is unhelpful for finding lesion-relevant detail.
- [ ] Cine play through axial / coronal / sagittal slices (autoplay +
      speed control).
- [ ] Inverted display toggle (negate intensity for soft-tissue
      inspection).

## Post-centerline radiology features (P2)

Things the viewer should have once the centerline pipeline is reliable.

- [ ] **W/L click-drag in 3-D Volume.** `viewer3d` uses a fixed
      transfer function — would need to remap the alpha/colour map
      from `app.WL` on every drag.
- [x] **Multi-pane 2×2 layout (v2)**: axial + sagittal + coronal +
      3-D recon (full `volshow`) visible simultaneously. Toggle
      button in toolbar. Each 2-D pane respects `DataAspectRatio`
      for anatomic accuracy and uses the current W/L; the 3-D pane
      uses a separate `volshow` viewer3d.
- [x] **Per-pane smart zoom in 2×2** — scroll over a pane zooms
      that pane only (smart zoom for 2-D panes; CameraZoom for the
      3-D pane). Each pane also has its own `+` / `−` buttons in
      its bottom-left corner so explicit clicks zoom one pane only.
      The overlay `+` / `−` hide in 2×2 mode (they would zoom all
      panes uniformly, which contradicts independent zoom).
- [x] **Per-pane Pan toggle inside the 3-D pane in 2×2** — drives
      the pane-4 `viewer3d.Interactions` independently from the
      single-view Pan toggle.
- [x] **Visibility cleanup**: Pan toggle hides on all 2-D views
      (rotate is a 3-D concept); Save snapshot + Fit hide in 2×2.
- [ ] **Per-pane slice scroll in 2×2**: plain scroll currently
      zooms; would prefer scroll = slice scroll, Cmd+scroll = zoom
      to match single-view conventions.
- [ ] **Linked crosshair** across panes — scroll axial, the others
      jump to the matching point.
- [ ] **Click-pan inside individual 2×2 panes** with the W/L /
      Pan toggles applying per-pane.
- [ ] **Preset clinical 3-D views**: AP, RAO 30°, LAO 30°, Lateral,
      Cranial, Caudal. One-click camera presets in addition to the
      existing Reset = AP.
- [ ] **Angle measurement** (3 clicks → degrees). Aortic-neck
      angulation, iliac tortuosity.
- [ ] **ROI tools** (rectangle / ellipse / freeform) with HU
      statistics (mean ± SD, min, max, area cm²) — for plaque
      density / sac density.
- [ ] **Auto W/L from histogram** (one-click optimal CTA window).
- [ ] **Mirror / flip image** in 2-D views.
- [ ] **Side-by-side compare** (pre- vs post-EVAR study) with
      synchronized scrolling. Single biggest workflow gap.
- [ ] **DICOM tag viewer** (read-only key/value list).
- [ ] **Annotations**: text labels, arrows, numbered markers; save /
      load to a project file.

## EVAR-specific tools (P2)

- [ ] Bifurcation angle (auto from polylines).
- [ ] Iliac tortuosity index (centerline arc / chord).
- [ ] Stent sizing tool — virtual stent landed against a centerline
      segment with diameter + length labels, snaps to lowest renal /
      hypogastric.
- [ ] Aortic-neck length and angulation auto-summary.

## Export / persistence (P2 / P3)

- [ ] DICOM export (DICOM-SR for measurements, DICOM-SEG for
      segmentation).
- [ ] Cine MP4 / GIF export (3-D rotation, slice-through).
- [ ] Save / load full project state: study + segmentation +
      centerline + landmarks + measurements in one file.
- [x] Snapshot PNG.

## Image enhancement (P3)

- [ ] Smoothing / sharpening / edge enhancement.
- [ ] Histogram equalization.
- [ ] MinIP (airways / dissection-flap inspection).
- [ ] Average IP.

## Performance / UX polish (P3)

- [ ] Drag-and-drop DICOM folder onto the window. R2025b doesn't
      expose a file-drop API on `matlab.ui.Figure`; revisit when
      MATLAB ships it.
- [ ] Streaming for very large studies (> 2 GB).
- [ ] Hanging protocols (auto-arrange views per modality).
- [ ] Multi-phase / multi-series picker (arterial vs venous vs
      delayed).

## Already in place (full list)

- [x] Axial / coronal / sagittal MPR.
- [x] 3-D MIP (coronal projection).
- [x] 3-D Volume render (volshow + viewer3d, denoising on, rendering
      quality high, downsample cap = 512).
- [x] CPR (curved planar reformat) with diameter envelope.
- [x] Multiple transfer functions (cta_recon / vessel / bone / mip /
      iso) selectable from a toolbar dropdown.
- [x] Window/Level presets dropdown (CTA Vessel, CTA Wide, CTA Bone,
      Abdomen, Bone, Lung).
- [x] Window/Level click-drag tool (`Drag: W/L` toggle + `W` key)
      working in axial / coronal / sagittal / 3-D MIP / CPR.
- [x] Pan toggle (3-D Volume + 2-D views).
- [x] Smart 2-D zoom that crops to panel aspect while preserving
      anatomic ratio.
- [x] Zoom buttons + scroll/pinch zoom + clamp + 3-D camera-zoom.
- [x] Mouse-wheel = slice scroll in 2-D.
- [x] Live cursor HU + voxel-coord readout (bottom-center).
- [x] Reset view (AP preset in 3-D, fit-to-data in 2-D, Home-button
      override).
- [x] Snapshot PNG export.
- [x] Recent-files cache + button.
- [x] Multi-line load status (no PHI).
- [x] Step bar + side-panel workflow (1-Load → 6-Export).
- [x] Centerline computation (skeleton + Dijkstra) + edit ops.
- [x] Right-click polyline edit (insert / delete / move / recompute).
- [x] Anatomy auto-labels (lowest renal, aortic bifurcation).
- [x] Bone-removal scalpel.
- [x] HU + connected-component fallback segmentation; TotalSegmentator
      hook.
- [x] Phantom library (normal + AAA) for offline practice.
- [x] Footer keyboard-shortcut listing across the bottom of the
      figure.
- [x] Persistent overlay buttons (Pan / W/L / Snap / Reset / + / − /
      Fit) on every view tab, kept on top of the volshow GPU layer
      via `uistack` on every view change.
- [x] +/-/Fit moved out of the toolbar into the persistent overlay
      under Reset view; toolbar slot freed for the 2x2 multi-pane
      button.
- [x] 2×2 multi-pane view button in the toolbar with axial /
      sagittal / coronal / 3-D MIP visible simultaneously.
- [x] HUD overlay on the 3-D Volume panel (zoom level, vol size,
      drag mode).
- [x] Step 1 = 3-D recon AP view of whole CT (no auto-segment / auto-
      crop / auto-advance).

## Bugs fixed this session

- `viewer3d.Interactions = 'all'` enabled the right-click "Display
  info / Scale bar" popup. Restricting to `'rotate'` keeps the popup
  off and makes drag-rotate the default.
- `WindowButtonDownFcn`'s `evt` has no `Button` field — was throwing
  silently and breaking the W/L drag. Switched to
  `app.UIFigure.SelectionType == 'normal'` for left-click detection.
- 3-D MIP and CPR were skipping `compositeView` when no segmentation
  mask was set, so the W/L value wasn't being applied to the rendered
  pixels in those tabs. Both now always go through `compositeView`.
- Side-panel layout overlap: Snap and Reset buttons were colliding
  with the load buttons. Moved them out of `buildStep1` into the
  persistent overlay; freed up the side-panel layout.
- 3-D Volume render ignored `DisplayExclusion` properly only after
  `finishStep2`; pre-segment full-body view now works without the
  overlay tools fighting volshow's GPU layer.
- Toggle button hidden behind volshow GPU layer. Reparented from
  `VolPanel` to `ImagePanel` (sibling of `VolPanel`) and `uistack`'d
  to top.
- Zoom-in `+` button did nothing in 3-D Volume mode (only manipulated
  `MainAxes.XLim`). Added a `'3dvol'` branch driving
  `viewer3d.CameraZoom`.
- Volshow render started at 256-vox max-dim cap which produced a
  visibly grainy recon. Bumped to 512 + `RenderingQuality = 'high'`
  + `Denoising = 'on'`.

## Notes

- `viewer3d` in R2025b: `Interactions` is single-mode (`rotate` /
  `pan` / `zoom` / etc.), not multi-mode. Toggle button or `P` key
  flips it.
- `viewer3d`'s right-click context menu (`Display info`, `Scale
  bar`) is hard-coded — `ContextMenu` property is empty. Cannot
  suppress directly. `Interactions = 'rotate'` (instead of `'all'`)
  appears to mute it in practice.
- `matlab.ui.Figure` in R2025b has no `AcceptFiles` / drop
  properties, so drag-and-drop is on hold.
- 13" MacBook (1440 × 900 logical) is the target small screen — every
  layout change must keep working there. Constructor caps `target_w`
  at `min(1800, scr(3) - 40)` = 1400 on 13" Macs.
- MIP / coronal / sagittal aspect ratio uses `DataAspectRatio =
  [pixel_mm  slice_spacing_mm  1]` to keep anatomy in real proportion.
- `WindowButtonDownFcn` evt fields are `Source / EventName / Point /
  IntersectionPoint / HitObject / HitPrimitive` — there's no
  `Button`. Use `app.UIFigure.SelectionType` for click-button checks.
- `setWL(app, wl)` calls `refreshMain`; in 3-D Volume, `refreshMain`
  delegates to `refreshVolViewer` which uses a fixed-HU transfer
  function and doesn't read `app.WL`.
