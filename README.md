# EVAR Planner

> ⚠️ **RESEARCH USE ONLY** — this tool is for academic and methods-development
> work. It is **not** a regulated medical device and must not be used for
> clinical decision-making.

An open-source automated **endovascular aneurysm repair (EVAR) planner**
from a contrast-enhanced CT angiogram. The pipeline:

1. Loads raw DICOM and ingests it as a uniform volume struct.
2. Auto-segments the aorta + iliacs via `TotalSegmentator`, then runs a
   branch-detection pass (celiac, SMA, both renals, both CFAs) with
   anatomic fallback scans, slice-by-slice **CFA extension** to the FOV
   bottom, supraceliac crop at 5 cm above celiac, and a 6-block audit
   (required vessels, visceral branches, sizes, proximal extent,
   per-side continuity, SE(3) curvature). Branch labels are
   disk-cached: a re-run on the same volume is **60× faster**.
3. Auto-detects three EVAR endpoints (supraceliac aorta ≈ 5 cm above the
   celiac, anchored on the celiac centroid not a kidney proxy; R-CFA and
   L-CFA at the post-extension distal termini, reaching the inguinal
   ligament).
4. Builds a bifurcated centerline. **VMTK's Voronoi/fast-marching
   centerline is the primary backend** (same algorithm class as the
   reference clinical workstation TeraRecon) with a pure-MATLAB
   skeleton-graph shortest-path implementation as a fallback when VMTK
   is not installed. Select the backend explicitly via
   `opts.centerline_backend ∈ {auto, vmtk, matlab}` to
   `run_planner_headless`.
5. Derives sizing measurements: proximal-neck Ø/length/angulation,
   per-side iliac Ø/length, peak aneurysm radius, iliac take-off
   (bifurcation) angle. Neck angulation is reported as **two angles** —
   α (suprarenal-to-neck) and β (infrarenal-neck-to-sac); β is the
   IFU-canonical value (`neck_angulation_deg`) that eligibility checks
   against. All diameters are **lumen-only** (exclude mural thrombus).
   Proximal-neck **length is N/A when no aneurysm onset is detected**.
6. Ranks 7 catalogued stent grafts (Gore Excluder, Gore Excluder
   Conformable C3, Medtronic Endurant II, Cook Zenith Flex, Endologix
   AFX2, Endologix/Trivascular Ovation iX, Terumo Treo) against the
   measurements using IFU criteria taken from Chaikof 2018 SVS and
   AbuRahma 2018 JACS (NOT vendor IFUs — see disclaimer in `+ifu`).
7. Emits a structured EVAR plan (.txt + .json) with rationale.

Three entry points:

```matlab
% GUI workflow — every step has a User-driven (default) / Automatic
% toggle and an ⓘ info button on every section. Help menu in the
% menubar exposes pipeline overview, glossary, and a first-launch tour.
app.AorticCenterlineApp

% Headless — zero clicks, raw DICOM → centerline + plan
out  = run_planner_headless('/path/to/DICOM-folder');
plan = evar_plan.generate_plan(out);

% Batch — walks a directory tree of DICOM cases, runs the headless
% pipeline on each, writes a summary CSV. Convenient for cohort runs.
results = run_batch('/path/to/cohort-root');
```

Heavy lifting (segmentation, centerline) is delegated to external
open-source tools (`TotalSegmentator` for segmentation; `VMTK` for the
Voronoi/fast-marching centerline). **Pure-MATLAB fallback paths
always work** when those tools are not installed — the planner
auto-detects what's available.

## Six-step workflow

1. **Load CT** — DICOM folder, single multi-frame DICOM, NIfTI, or cached `.mat`.
2. **Segment aorta** — One-click *auto-segment* with TotalSegmentator (when the
   CLI is on `PATH`), then manual click-to-add / brush / scalpel refinement
   with HU-range gating and shift-chain preview.
3. **Pick endpoints** — Three seeds: proximal aorta (suprarenal, green), right
   CFA (red), left CFA (blue). The arming sequence auto-advances.
4. **Compute centerline** — Toggle between **VMTK** (bifurcating tree, exact
   shared bifurcation node) and the built-in **Skeleton** algorithm
   (`bwskel` + Dijkstra, run twice and merged). Polylines are oriented
   distal → proximal so node 1 is the CFA and the last node is the
   suprarenal aorta.
5. **Analyze (EVAR)** — Click on the centerline to drop landmarks (lowest
   renal, aortic bifurcation, iliac termini, internal iliacs). Measurements
   update live; a separate window shows the radius profile with landmarks
   overlaid.
6. **Export** — Save as `centerline.mat` or push to the local case library.

## Quick start

```matlab
cd '/path/to/phase-3-real-EVAR'

% --- Headless (no clicks) ----------------------------------------
out  = run_planner_headless('/path/to/DICOM-folder');
plan = evar_plan.generate_plan(out);     % writes evar_plan.{txt,json}

% --- GUI workflow ------------------------------------------------
app.AorticCenterlineApp                  % auto-seeds Step 3 from
                                          % cached TS multilabel when
                                          % available; otherwise three
                                          % clicks

% --- Run the regression suite -----------------------------------
addpath('scripts'); run_tests            % non-GUI 110 pass / 1
                                          % expected-skip of 111; GUI
                                          % tests need a display. See
                                          % STATUS.md for the live count.
```

## Repository layout

```
phase-3-real-EVAR/
├── +app/                    The MATLAB GUI (AorticCenterlineApp.m)
├── +autoseg/                TotalSegmentator wrapper (detect + run + branch extension)
│   └── +aortaseg24/         AortaSeg24 nnU-Net backend scaffold (Phase B, optional)
├── +evar_plan/              measure_from_centerline + generate_plan
│                            (composes centerline + +ifu into a plan)
├── +ifu/                    Stent-graft IFU library + eligibility checker +
│                            device ranking (7 devices; Chaikof 2018 + AbuRahma 2018)
├── +io/                     NIfTI + VTP read/write helpers
├── +library/                Local case archive (save/load/index/list)
├── +phantom/                Synthetic CT phantoms (normal + AAA male)
├── +preprocess/             DICOM load + auto_seeds_anatomic +
│                            track_aorta_2click + skeleton-graph centerline
├── +setup/                  Dependency check + install help
├── +vmtk_centerline/        VMTK CLI wrapper (detect + compute + vtp_to_csv.py)
├── library/                 Case archive (4 PHANTOM_*.mat files ship
│                            with the repo; real cases are git-ignored)
├── scripts/                 run_tests.m, audit_*, render_pipeline_demo, …
├── tests/                   unit + regression tests (test_ifu, test_pipeline_phantom)
├── run_planner_headless.m   end-to-end DICOM → centerline + plan, zero clicks
├── README.md                (this file)
├── STATUS.md                Phase 3 progress / data inventory
├── HANDOFF.md               Latest-session change summary
├── DEPENDENCIES.md          External-tool requirements
├── SETUP.md                 Step-by-step install
├── LICENSE                  MIT
├── CITATION.cff             How to cite
├── environment.yml          conda env for TotalSegmentator (evar-tools)
├── environment-vmtk.yml     conda env for VMTK (osx-64 / Rosetta on Apple Silicon)
└── .github/workflows/       CI: MATLAB-only smoke test
```

## Phantom library

The repo ships **four** phantom `.mat` files in `library/`:

| File                                | Role          | Contents                                        |
|-------------------------------------|---------------|-------------------------------------------------|
| `PHANTOM_normal_male.mat`           | Answer key    | mask + paired centerlines + seeds + landmarks   |
| `PHANTOM_normal_male_raw.mat`       | Practice case | synthetic CT only (no labels)                   |
| `PHANTOM_aaa_male.mat`              | Answer key    | mask + paired centerlines + seeds + landmarks   |
| `PHANTOM_aaa_male_raw.mat`          | Practice case | synthetic CT only (no labels)                   |

The intended workflow:

1. Open a `_raw.mat` file from Step 1 → "Open phantom" and work the
   case from scratch (segment / seed / centerline / analyze / export).
2. To compare against the ground-truth answer, load the corresponding
   labeled file directly (`load library/PHANTOM_aaa_male.mat`) — its
   `Pv_mm_right`, `Pv_mm_left`, `bifurc_node_right`, and `landmarks`
   fields are the canonical answer.

To rebuild the four files from scratch (e.g. after the phantom
builders change), run `scripts/regenerate_phantoms.m`.

## External reference datasets

The planner supports the [AAA-100](https://zenodo.org/records/10932957)
public cohort (Rygiel, Alblas, Brune, Smorenburg, Yeung, Wolterink,
2024) as a geometry / centerline benchmark and SE(3)-threshold
calibration source — 100 EVAR-treated infrarenal AAA cases with
watertight lumen meshes + 5 centerlines per case (aorta, L/R iliac,
L/R renal). Note: source CTAs are not released, so this cohort
validates centerline + measurement code but not segmentation.

See `docs/datasets.md` for the full catalog, integration plan, and
download instructions. Integration components live in
`+library/+aaa100/` and require Python with `vtk` + `scipy`.

License of the AAA-100 dataset is CC BY-NC 4.0 (non-commercial only).

## Citing

If you use this tool in academic work, please cite the repository and the two
external tools we depend on:

- **TotalSegmentator:** Wasserthal J et al. *Radiology AI* 2023;5(5):e230024.
- **VMTK:** Antiga L et al. *Med Biol Eng Comput* 2008;46(11):1097–112.

See `CITATION.cff` for a machine-readable citation entry.

## License

[MIT](LICENSE) — Copyright (c) 2026 David P. Stonko.

The MIT license covers **this repository's source code only**. It does
**not** cover the external CC-BY-NC reference datasets (AAA-100 /
AortaSeg24), which are non-commercial and are **never redistributed
here** — install them yourself from their respective sources under
their own licenses.
