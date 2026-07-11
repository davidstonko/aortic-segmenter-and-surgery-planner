# Phase 3 — One real EVAR case end-to-end

**Status — 2026-06-15 (latest): measurement-engine unification (B1–B3) + Step-6 mesh export + AortaSeg24 Phase-B scaffold.**
- **B1 — single measurement engine.** GUI and headless now derive all sizing measurements through the one code path `evar_plan.measure_from_centerline`, so on-screen numbers and the exported `.txt`/`.json` plan are computed identically (display == export).
- **B2 — neck angulation reported as α AND β.** Two angles are emitted: **α** = suprarenal-to-neck angle, and **β** = infrarenal-neck-to-sac angle. **β is the IFU-canonical value** and is the field carried as `neck_angulation_deg` (the number IFU eligibility checks against); α is reported alongside for context.
- **B3 — lumen-only diameters + N/A neck length.** Every diameter is lumen-based (labelled "excludes mural thrombus"); the outer-wall/ILT sac is not segmented (see goal #26 / B-iv). Proximal-neck **length is reported N/A when no aneurysm onset is detected** rather than fabricating a number off a fallback anchor.
- **Step 6 mesh export wired.** `evar_plan.export_mesh` is plumbed into the GUI (`saveMesh`) and the headless auto-export (`lumen.stl`). *(Note: still un-covered by an automated test — audit item A7/tests-4.)*
- **AortaSeg24 Phase-B scaffold.** `+autoseg/+aortaseg24/` (`detect`/`run`/`translate_labels`) is scaffolded against `nnUNetv2_predict`; it needs `nnunetv2>=2.5` + `AORTASEG24_MODEL_DIR` and there are no public weights. It segments **lumen + aortic zones, NOT wall/ILT**, so it does not by itself close the lumen-only ceiling (#26). The Phase-A error-gate test (`test_aortaseg24_backend`) is the one expected skip when the backend is absent.
- **Test suite (current).** Non-GUI: **110 passed / 1 expected-skip out of 111** (the skip is `test_aortaseg24_backend`, backend-absent). 26 test files / ~134 test methods total; GUI tests (e.g. `test_gui_mode_toggle`, `test_manual_editor`, `test_vmtk_centerline`) are filtered in headless `-batch` and run green in a desktop session.

Older dated blocks below are retained as history.

**Status (2026-06-06, latest): hardened the complete-segmentation gate's bifurcated-tree logic.** The arc-span test (arc ≥ span_frac·straight) now applies ONLY to the right (primary) branch — it *is* the full trunk to the proximal source, so the full proximal→CFA straight is the correct reference. The left branch is trimmed at the bifurcation by `vmtk_centerline.compute`, so it spans only bifurcation→CFA; measuring its arc against the full proximal→CFA straight was geometry-fragile (would false-fail a high-bifurcation / short-iliac case). The left branch is now gated solely on **reaching its CFA seed distally AND joining the trunk proximally** (`min_polyline_dist` to the right polyline) — principled, not a loosening: the trunk-join already rejects the degenerate CFA-collapse (a 2-node polyline that collapses onto the CFA target sits far from the trunk), so the redundant full-span arc test only added false-failure risk. New regression `left_branch_trimmed_at_bifurcation_passes` pins it (a short left branch, arc ~16 mm < span_frac·~35 mm straight, that joins the trunk and reaches its CFA must PASS); `test_check_complete_segmentation` now **7/7 green**. **Both scans still PASS** under the revised gate — reconfirmed against the saved planner results (JohnDoe1 & JohnDoe2: single 100% CC, R/L reach 0 mm, R/L CFA gap 1–2 mm) — since removing a constraint cannot regress an existing PASS. Next: surface the complete-segmentation gate inside the GUI as the auto-proposal acceptance signal.

**Status (2026-06-05, latest): the governing Phase-3 goal — *completely segment the aorta of both scans* — is met. `autoseg.check_complete_segmentation` now PASSES on JohnDoe1 AND JohnDoe2.** Each is a single 100% connected component from the proximal neck down both iliacs/CFAs to the FOV bottom (R/L reach gap **0 mm**), with the bifurcated centerline routing end-to-end to each CFA seed (R/L CFA gap **1–2 mm**). Two final blockers cleared, **bridge-free** (reconnection adds only genuine-HU voxels): **(1)** JohnDoe2's post-reconnection mask was one 26-CC reaching the FOV bottom yet VMTK returned a *degenerate* right centerline (2 nodes, arc 0 mm) — a thin reconnection bridge keeps the VOLUME connected but gets pinched off the *decimated* surface mesh. `run_planner_headless` step 7 now detects a collapsed branch (`vmtk_branch_degenerate`: arc < 0.6× straight proximal→CFA, or < 5 nodes) and retries VMTK with `reduce=0.0` (no decimation) — **radius-safe** (no surface inflation, unlike `imclose`, so `evar_measurements` diameters stay honest), paid only on cases that need it; JohnDoe2 right arc 0 → ~506 mm. **(2)** The gate mis-modeled the bifurcated tree: `vmtk_centerline.compute` trims the LEFT polyline at the bifurcation, so it ends ~170–210 mm distal of the proximal seed — the old gate wrongly required it to reach the proximal seed and false-failed both scans. Criterion (3) now requires the right/primary branch to reach the proximal SEED and the left branch to reach the TRUNK (closest approach to the right polyline; new `min_polyline_dist`), with `cl_prox_tol_mm`=20 mm for the proximal/trunk anchor and the tight 12 mm still on the distal CFA seeds. Regression **113 passed / 0 failed / 1 incomplete (of 114)** (incomplete = known aortaseg24 Phase-A `assumeTrue` skip; `test_vmtk_centerline` runs separately, needs a display); `test_check_complete_segmentation` 6/6 green. Next: surface the complete-segmentation gate inside the GUI as the auto-proposal acceptance signal.

**Status (2026-06-01, latest): hardened the manual segmentation editor — the refine core of the "auto-propose, then refine" (TeraRecon-style) workflow.** `AorticCenterlineApp` now has a **user-controllable grow tolerance** (`GrowTolHU`, ± HU half-window for click-to-grow, default 75 = prior behavior) wired into *both* grow paths (`runSegmentation` atomic flood + `liveGrowFromSeed` hold-to-grow) and surfaced as a "Grow tolerance: ± N HU" slider (Limits [20 250]) in the click-to-add and refinement panels. Click-to-erase (`eraseVesselAtVoxel`) carves a **bounded**, anisotropy-corrected round ball out of `Mask`+`MaskLabel` — local by construction so a click can never nuke the connected tree (no connected-component wipe) — and is **undoable** (`pushUndo` before every edit). Pinned by new `tests/test_manual_editor.m` (3 cases / 8 assertions: bounded erase, exact undo + repeatable re-erase on a clean stack, grow-tol round-trip, wider-tolerance-grows-strictly-larger), in the house GUI-test style (sandboxed `user.home`, synthetic graded vessel, figure deleted in teardown). The old function-style `scripts/test_manual_editor.m` was removed (path-name clash). **Suite: 95 passed / 0 failed / 10 filtered, of 105** — the new GUI test filters in headless `-batch` like `test_gui_mode_toggle` and passes 3/3 in a display session; `test_vmtk_centerline` confirmed 3/3 green in a desktop session (VTK needs a display, run separately). Next: wire the auto-proposal into the GUI so it pre-loads a proposed mask + 3 seeds ready to refine.

**Status (2026-06-01, later): the "doesn't look like a segmented aorta" defect was a *rendering* bug, not segmentation.** Hard checks on the saved masks: JohnDoe2 **676k vox / 1 CC / z 1..868 / zero empty slices**, JohnDoe1 **982k vox / 1 CC / z 451..1219 / zero gaps**, all six seeds inside-mask, isosurface a single watertight surface; MIP projections show textbook aortoiliac Y-trees. The fragmented "slabs" came from `render_demo_figure/build_isosurface` recovering the mm grid as `mm=(vox-1)·spacing` with a zero origin — wrong for DICOMs with a large z-origin (JohnDoe2 z≈−1500 mm), so the mask landed outside the centerline axis limits and got clipped. Fixed: `render_demo_figure` now recovers the pipeline's exact `voxel_to_mm` from the seed↔seed_mm correspondences (residual ~1e-13), uses mask-inclusive limits, and data-driven `ZDir`. Both headless demos now look like proper segmented aortas; GUI-driven equivalents via `scripts/gui_demo_from_mat.m` (app 3dvol masks CT to segmentation). **4 demo images delivered** (`results/figures/{demo,gui}_{johndoe1,johndoe2}_leakfix.png`). Known gap: JohnDoe1's **right** iliac centerline truncates ~5 cm short of the CFA (6b largest-CC filter drops the disconnected distal right iliac) — to fix without bridges (see task #58).

**Status (2026-06-01): fixed the adaptive follower flooding the pelvis on low-contrast scans.** The 2026-05-21 adaptive HU follower leaked catastrophically on JohnDoe2 (a low-contrast study, aorta bolus peak 376 HU): cancellous bone marrow (~200–400 HU) falls inside the per-patient window and is 26-connected to the iliac lumen through the iliac groove, so the `imreconstruct` flood filled both femoral heads, the iliac wings and the sacrum (walker 300 mL → follower 806 mL → FINAL 1387 mL, ≈5× the true vessel). Fix = two bridge-free guards: (1) `autoseg.drop_big_inplane_cc` drops over-vessel-calibre in-plane components (`opts.vessel_max_mm2`, default 400 mm²) from the grow candidates — wired into the follower **and** the `[3c]` HU-reconstruct; (2) **tube confinement** (`opts.tube_radius_mm`, default 5 mm, the decisive guard) intersects candidates with `imdilate(mask_in, sphere(r))` so the flood can only recover partial-volume edge voxels near the walker's already-tracked path, never reach distant pelvis. Result: JohnDoe2 FINAL **1387 → 258 mL**, a clean infrarenal AAA + bifurcation + both iliacs to the FOV bottom, single CC, zero leak; JohnDoe1 (well-contrasted) is a near-no-op (547 → 547 mL), no regression. `tests/test_follow_iliacs_adaptive.m` rewritten to the production contract (walker cores in, follower thickens) + a `tube_guard_rejects_offpath_contrast` leak test — 8/8 pass.

**Status (2026-05-20): VMTK is now the primary centerline backend** (Voronoi/fast-marching, matches TeraRecon's algorithm). `run_planner_headless.m` accepts `opts.centerline_backend ∈ {auto, vmtk, matlab}`; `auto` (default) prefers VMTK and falls back to the MATLAB skeleton-graph path on detection failure or runtime error. **77/77 runnable regression tests green** (added `tests/test_vmtk_centerline.m`, 3 cases, plus the new `planner_recovers_bifurcation_angle` test). Two real bugs in `+vmtk_centerline/compute.m` discovered and fixed: `extract_line` was comparing VMTK's `(X,Y,Z)` cl.points against `(Y,X,Z)` caller seeds, picking the same VMTK line for both R and L; `find_bifurc` walked from the proximal source downward and returned at the source instead of the divergence point. End-to-end JohnDoe1 VMTK output: Pv_R 1106 nodes / 725 mm arc, Pv_L 1169 nodes / 732 mm arc, bifurc found from both polylines within 1.3 mm, median R 5 mm, max R 19.7 mm (AAA sac).

**Status (2026-05-18, late): pipeline now runs end-to-end on TWO real EVAR cases — JohnDoe1 (in-cohort) and JohnDoe2 (first out-of-cohort). The JohnDoe2 test exposed three integration bugs: 19-CC mask fragmentation when TS splits the thoracic from the abdominal aorta, proximal seed landing in the thoracic fragment, and a documented-vs-actual mismatch in the default TS-targets list. All three fixed; both cases now produce a full bifurcated centerline + EVAR plan with no regression. JohnDoe2's neck-length measurement is anatomically off (90 mm vs clinically 15-30 mm) because TS-fast didn't detect the celiac/SMA on this case so the proximal anchor falls back to `kidney_top - 70 mm` which overshoots the diaphragm — known limitation, fix deferred.**

**Status (2026-05-18, earlier): pipeline runs end-to-end with zero clicks AND the GUI is the unified entry point. The segmentation now reaches the common femoral arteries on BOTH sides, the audit passes all 6 blocks (no WARNs), and the bifurcated centerline spans proximal aorta to each CFA.** DICOM → TS → extend_and_detect_branches (with SMA + renal-L fallbacks) → extend_to_cfa (slice-by-slice walk from each iliac/CFA terminus to FOV bottom, anatomically side-constrained around the aorta bifurcation x-midline, **patient-invariant topological CFA detector** ranks candidates by roundness × Gaussian lateral-position prior, **SE(3) cross-vessel + per-centerline rule check** flags anatomic plausibility violations) → supraceliac crop at z_celiac − 50 mm → 6-block audit → anatomic auto-seeds → bifurcated centerline → sizing measurements → IFU device matching → structured plan output.

## SE(3) quality-control rule suite (added 2026-05-18)

Two layered checks run post-walk and attach reports to `info`:
- **`+autoseg/se3_cross_vessel_check.m`** (7 blocks): z-extent ≥ 150 mm both sides, shared proximal bifurcation node, distal-endpoint symmetry across midline, z-monotonicity, bilateral curvature ratio ≤ 3×, bifurcation take-off angles ∈ [15°, 85°] over first 15 mm of arc, bilateral take-off-angle symmetry ≤ 15°.
- **`+autoseg/se3_per_centerline_check.m`** (5 blocks): κ_max ≤ 0.2 mm⁻¹ (R ≥ 5 mm), |τ|_max ≤ 0.1 mm⁻¹, adjacent-tangent angle ≤ 60°, arc/Euclidean tortuosity ≤ 1.4, |dR/ds| ≤ 1 mm/mm (skipped if radius profile not provided). Smoothing window 15 with edge-trim suppresses coarse-extraction noise.

Each block emits OK / WARN / FAIL with diagnostic text. `passed=true` only when no FAIL severity. The GUI surfaces FAIL via `uialert` and stores the report on `app.LastSE3Check` for downstream re-anchor workflows.

The JohnDoe1 case currently produces: **proximal seed at z=451** (5 cm above the celiac at z=551, anchor=celiac), **R-CFA seed at z=1217 (FOV bottom)** and **L-CFA seed at z=1219 (FOV bottom)**, bifurcated centerline R-arc **572 mm** / L-arc **570 mm**, with all four visceral branches captured: celiac 1,720 vox / 0.51 mL, SMA 8,863 vox / 2.63 mL, renal_L 8,494 vox / 2.52 mL, renal_R 4,781 vox / 1.42 mL. **All 6 audit blocks pass [OK]** — required vessels, visceral branches, sizes, proximal extent, per-side continuity (RIGHT 185 mm 100% / LEFT 185 mm 100% reaching FOV bottom), SE(3) deformation.

Test coverage: **95/95 runnable regression tests passing, 105 total** (in headless mode 9 GUI tests are filtered — 6 `test_gui_mode_toggle` + 3 `test_manual_editor`, all require a display; the 1 aortaseg24 Phase_A error-gate test is skipped via assumeTrue until a backend is detected; the 3 `test_vmtk_centerline` cases require a display for VTK and run green in a desktop session, separately from the headless `-batch` run) — audit, celiac-anchor, visceral-branch fallbacks, CFA extension, IFU, plan, phantom, tracker, TeraRecon-comparison harness, GUI mode toggle + info-button architecture, session features, reference annotations + benchmark loader, AAA-100 SE(3) rule pass-rate, SE(3) bilateral take-off-asymmetry block, AAA-100 patient-vs-population outlier scorer, manual CFA seed override, **`test_manual_editor` (3 cases)** pinning the hardened click-to-grow tolerance + bounded undoable 3-D click-to-erase, **`test_vmtk_centerline` (3 cases)** pinning the extract_line / find_bifurc fixes, **`planner_recovers_bifurcation_angle`** pinning the new iliac take-off angle measurement at the phantom's procedural 36°, and **IFU bifurc-angle slot tests (2 cases)** verifying the NaN-skip + populated-ceiling paths.

GUI: every step renders a **User-driven (default) / Automatic toggle** at the top of its side panel; every section + key control has an **ⓘ info button** that opens a context-specific help modal; a top-level **Help menu** exposes pipeline overview, mode help, glossary of clinical terms (AAA/EVAR/proximal-neck/supraceliac/CIA/EIA/CFA/IFU/etc.), reference-annotation workflow, and per-step help entries. The toggle state and first-launch-tour-shown flag persist across sessions via `~/.aortic_centerline_prefs.json`. Help text lives in one registry (`+ui_helpers/help_content.m`).

Performance: branch-label detection (`autoseg.extend_and_detect_branches`) is wrapped by `autoseg.detect_branches_cached`, which writes a `<hash>_branches.mat` next to the existing TS cache and key by `(seg shape, sum, pixel_mm, slice_spacing_mm)`. **60× speedup on re-runs (22.9 s → 0.39 s)**.

IFU library: 7 devices — Gore Excluder, Gore Excluder Conformable (C3, 90° angulation tolerance), Medtronic Endurant II, Cook Zenith Flex, Endologix AFX2, Endologix/Trivascular Ovation iX (short-neck-tolerant 7 mm), Terumo Treo.

Benchmark infrastructure: new `+reference` package + `scripts/run_benchmark.m` for the future TeraRecon comparison cohort. `reference.template('CASE', ref_dir)` writes a JSON skeleton with every measurement set to NaN; the annotator fills in measurements made in TeraRecon; `run_benchmark(cohort_root, ref_dir)` pairs each CT with its reference JSON, runs the planner, and emits a per-case delta CSV. Also `scripts/run_batch.m` for plain cohort runs without a reference.

This phase pulls a single de-identified EVAR case through the entire AINN pipeline: preop CT → segmentation → centerline → forward equilibrium → projection to 2D → comparison against intraop angio.

## Data

The first case is **JohnDoe1 EVAR**. Folder layout (under `/Vascular Mathematical Modeling/JohnDoe1 EVAR/`):

```
JohnDoe1 EVAR/
├── export-XA/   12 DICOM series, all XA (intraop angio + fluoro)
└── export-CT/    1 DICOM series, CT (CTA chest/abdomen/pelvis)
```

**Cataloged via `preprocess.dicom_series`:**

| Modality | n series | description | total frames | gantry views |
|---|---:|---|---:|---|
| CT | 1 | "Aorta 0.75 Br36 3" — preop CTA | 1219 slices | – |
| XA | 5 | "Fluoroscopy" cines (with wire) | 1–128 frames each | +10°/+10° and −2°/−20° |
| XA | 5 | "Abdomen Frontal 3fps" DSA runs | 17–29 frames each | mostly +10°/+10°, one −2°/−20° |
| XA | 1 | "Fluoroscopy" still | 1 frame | scattered |

The two dominant gantry poses are **AP-cranial (+10° primary, +9.5° secondary)** — the working-view group — and **RAO-caudal (−2° primary, −20° secondary)** — the iliac-bifurcation view group.

CT volume specs: 512×512×1219, 0.77 mm × 0.77 mm pixel, 0.5 mm slice spacing, 609 mm z-extent (chest + abdomen + pelvis), HU range [−1024, 3071].

## Modules implemented

```
phase-3-real-EVAR/
├── +app/                    AorticCenterlineApp — 6-step GUI (final product)
├── +autoseg/                TS shell, branch detection, CFA extension,
│                            topological CFA detector, SE(3) audit suite,
│                            segmentation audit
├── +evar_plan/              measurement extraction, plan generation,
│                            mesh export, TeraRecon-comparison harness
├── +ifu/                    7-device library + eligibility checker
├── +io/                     VTP surface writer + NIfTI helpers
├── +library/+aaa100/        Zenodo AAA-100 loader, shape model,
│                            measurement extractor, outlier scorer
├── +phantom/                4 synthetic AAA / normal-male phantoms
├── +preprocess/             DICOM ingest, viewer, anonymizer, auto-seeds,
│                            centerline (skeleton + seeded paths), tracker
├── +reference/              TeraRecon-reference JSON schema + loader
├── +setup/                  install verification
├── +ui_helpers/             modes, info buttons, help registry, prefs
├── +vmtk_centerline/        optional VMTK Voronoi-fast-marching path
├── scripts/                 run_tests, run_batch, run_benchmark,
│                            calibrate_se3_thresholds, etc.
├── tests/                   26 unittest classes (~134 test methods;
│                            non-GUI 110 pass / 1 expected-skip of 111)
├── docs/                    datasets.md, TEVAR_REVIEW.md
├── library/                 ground-truth phantom MAT files
├── run_planner_headless.m   zero-click DICOM → plan
├── run_app.m                launch GUI
└── *.md                     README, BUILD_PLAN, STATUS, GOALS,
                             CHANGELOG, HANDOFF, etc.
```

## How to use the viewer

```matlab
cd '/Users/.../Vascular Mathematical Modeling/phase-3-real-EVAR'

% Quick inventory:
S = preprocess.dicom_series('/Users/.../JohnDoe1 EVAR');
disp(S);

% View the CT (cached after first read):
preprocess.dicom_viewer('/Users/.../JohnDoe1 EVAR/export/.../CT-series/')

% View an angio cine — auto-plays with the ▶ Play button:
preprocess.dicom_viewer('/Users/.../JohnDoe1 EVAR/export/.../XA-cine/')
```

Controls:
- **Sliders** scrub through slices (CT) or frames (XA cine).
- **Right-click + drag** anywhere in an image pane to adjust window/level (drag right = wider window, drag down = brighter).
- **Window/level preset buttons** in the right panel for CT (Abdomen / Vessel / Bone / Lung).
- **▶ Play** button on cines, with adjustable fps (default 7.5).
- **Save snapshot…** writes the current view to PNG.

## Centerline pipeline status

Pipeline runs end-to-end on the JohnDoe1 CT and produces a smoothed polyline + radius profile + 6-panel QC figure. Current result with parameters `HU ∈ [200, 400], no erosion, z_band = bottom 60% of CT, skeleton-radius filter ≥ 4 voxels`:

| metric | value | clinical reference |
|---|---:|---|
| polyline | 207 nodes | – |
| arc length | 153 mm | aorta + bifurcation + iliacs ≈ 250–350 mm |
| lumen radius | 2.0–9.1 mm | iliac 4–7 mm, aorta 8–12 mm |
| median radius | 4.7 mm | – |

The radius profile traces a clear iliac → aorta → iliac U-shape (small → 9 mm peak → small) and the 3D plot shows an inverted-U through the lower abdomen — i.e. the pipeline has captured **the iliac bifurcation segment**, but not the aorta proximal to it. The radius-filter step (skeleton voxels with inscribed-sphere R ≥ 3 mm) cleanly removed mesenteric/renal branches but also broke the segment at the suprarenal aorta where the wall + boundary are tighter against neighbouring contrast-filled tissue.

### Two paths to a fully aortic centerline

**Path A (long-term robust): TotalSegmentator + bwskel.** One shell-out to TotalSegmentator (`TotalSegmentator -i CT_dir -o seg_dir --roi_subset aorta iliac_artery_left iliac_artery_right`) gives clean aorta-only masks. Feed the binary mask straight into `preprocess.centerline_skel` — the threshold step disappears. Estimated effort: ~2 hours of integration.

**Path B (built this session, ~150 lines of pure MATLAB): manual seeds + skeleton-graph shortest path.**

`+preprocess/build_skeleton_graph.m` builds a connected-graph representation of the skeleton voxels of any mask, with optional radius-filter pruning. `+preprocess/centerline_seeds.m` walks the shortest path through that graph between an ordered list of user-supplied landmark voxels (e.g. proximal aorta → iliac bifurcation → iliac terminus). `+preprocess/nearest_skeleton_voxel.m` maps a free-form click to the nearest valid graph node.

Demo: `demo_centerline_seeded.m` runs the seeded pipeline on the JohnDoe1 CT with three landmarks (suprarenal aorta, bifurcation, distal iliac) and produces a **769 mm centerline** spanning the entire aorta + iliac trajectory. Saves to `results/logs/centerline_seeded.mat` and a 6-panel QC at `results/figures/centerline_seeded_qc.png`.

Status: end-to-end works; radius profile is noisier than ideal (median ~0.7 mm because the skeleton threads through small contrast-filled branches between the user landmarks). With cleaner segmentation (Path A) or by adding explicit radius weighting to the graph edges (preferring fat-tube paths), the radius profile will smooth out. The trajectory itself is clinically reasonable.

See `CENTERLINE_METHODS.md` for the full method survey and references.

## Validation cohort — AAA-100 (Zenodo 10932957) — INTEGRATED 2026-05-18

External dataset used as a geometry / centerline benchmark before
prospective validation on local EVAR cases. **All 100 cases + meshes
+ centerlines are loaded; SE(3) thresholds are now calibrated against
the empirical 99th percentile of real anatomy.**

- **AAA-100** by Rygiel, Alblas, Brune, Smorenburg, Yeung, Wolterink (Twente + Amsterdam UMC, 2024).
  DOI: [10.5281/zenodo.10932957](https://zenodo.org/records/10932957), CC BY-NC 4.0.
- **Contents**: 100 triangular surface meshes (`.stl`, lumen-only, ~780 MB) + 100 centerlines (`.vtp` VTK PolyData, ~1 MB) covering aorta + L iliac + R iliac + L renal + R renal per case. **Source CTAs are NOT released**.
- **Anatomic extent**: aorta from T12 down to iliac bifurcation; iliacs extend ~5 cm distal to bifurcation (does NOT reach CFA); renals ~3 cm distal to ostium.
- **Cohort**: 100 EVAR-treated patients from Amsterdam UMC (2017-2021), pure infrarenal AAA. EVAR-eligibility selection bias toward larger aneurysms; no diameter / age / sex distribution disclosed.

**Role in this project** (revised after research):

1. **Geometry benchmark, not a training set.** Without DICOM images, AAA-100 cannot be used to train or tune the DICOM-ingest, contrast-handling, or TS-segmentation steps. It IS the best available public ground truth for: max-diameter extraction along a centerline, neck identification, iliac-diameter measurement, and the SE(3) per-centerline rule thresholds (κ, τ, tortuosity).
2. **Calibrate the SE(3) rule thresholds.** Run `autoseg.se3_per_centerline_check` over all 100 reference centerlines; the empirical κ_max / |τ|_max / tortuosity distributions tell us where the FAIL thresholds should sit so that real anatomy passes.
3. **Derive "TeraRecon-style" measurements on ~20 cases** from the meshes manually (max AAA diameter, neck length, neck angulation, iliac diameter) — treat those as the gold standard for tuning measurement code.
4. **License-aware**: CC BY-NC means non-commercial only. The planner can remain freely usable for research / clinical research; commercial redistribution of any derived weights or measurements would require relicensing.

**Integration plan**:
- `+library/aaa100/` package with a loader `load_case(case_id)` returning the mesh + 5 centerlines as structs.
- `scripts/calibrate_se3_thresholds.m` walks the cohort and prints empirical 95th/99th percentiles of κ, τ, tortuosity per anatomic segment.
- `tests/test_aaa100_loader.m` regression test pinning the loader behavior.
- See `docs/datasets.md` for the detailed catalog.

**Known limitations**:
- Iliacs truncated at 5 cm — too short for distal CFA landing-zone planning. Pair with another cohort (e.g. Wittek 2020, or our own EVAR cases) for full pelvic-to-femoral coverage.
- No source CTAs, so cannot validate any segmentation step against this dataset.
- No clinical ground-truth measurements (neck length, AAA diameter, sac volume) — must be derived from the meshes ourselves.

## Phase 3 success criteria (from the implementation plan)

The plan defined three gates for Phase 3:
1. **2D wire-path Hausdorff distance below ~5 mm** on the angio frame — *not yet measured.*
2. **Predicted ostium displacements have the right sign and magnitude** — *not yet measured.*
3. **Sensitivity sanity** — setting `T_axial = 0` collapses the prediction to State 1 — *can be tested as soon as the centerline is good.*

## Next steps

See `GOALS.md` for the live prioritised list. Current top items:

- **#5 [P1]** Quantitative accuracy benchmark vs. TeraRecon on the JohnDoe1 case — _blocked on the vascular specialist filling in `library/reference/*.ref.json`._
- **#18 [P1, ✅ 2026-05-20]** VMTK Voronoi-fast-marching swap **completed**. Debug closed (axis-order bug in `extract_line`, proximal-walk bug in `find_bifurc`). Now wired as the primary centerline path in `run_planner_headless.m` via `opts.centerline_backend ∈ {auto, vmtk, matlab}`. Verified on JohnDoe1 (R 725 mm / L 732 mm bifurcating centerline, bifurc match 1.3 mm). Suite **77/77 green** including new `tests/test_vmtk_centerline.m` (3 cases) and `planner_recovers_bifurcation_angle`.
- **#26 [P2]** AortaSeg24-based multi-class seg (lumen + ILT + branches) — TS does not give wall/thrombus.
- **#9 [P2]** P1 viewer gaps: slab MIP with thickness slider, cine play through MPR slices, inverted display toggle.
- **#10 [P2]** P2 viewer + EVAR-tool gaps: linked crosshair, side-by-side pre/post compare, bifurcation angle auto-calc, virtual stent sizing.
- **#25 [P2]** CT→fluoroscopy 2D/3D registration via DiffDRR.
- **#8 [P2]** CT-to-C-arm rigid registration via vertebral bodies + iliac crests.
- **#27 [P3]** Jerman enhancement filter A/B vs current Frangi gate.
- **#32 [P1]** GUI walkthrough video — held pending pipeline verification (close to releasable now).

Completed P0/P1 (last session): auto-seed step, IFU library, EVAR plan output, smoothing pass, multi-component iliac branching, regression test suite (14/14 green).

## References

See `CENTERLINE_METHODS.md` for the literature survey behind the recommendations above.
