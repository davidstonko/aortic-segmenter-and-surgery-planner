# External datasets for validation and calibration

This page catalogs the third-party datasets used in the project, what
each provides, what each does NOT provide, and how each is being used.
Datasets are listed in order of integration priority.

> **Role of public data in the learned-segmentation phase.** Per the
> [strategy](LEARNED_SEGMENTATION_ROADMAP.md#guiding-principles-the-strategy-in-five-decisions),
> our **own institutional CTAs are the training foundation**; public data is
> **supplementary / external validation, not the foundation**. If a public
> set is used for training at all, filter strictly to **contrast-enhanced
> aneurysm CTA**, and harmonize its labels to one scheme first (whole-aorta
> vs 23-zone are not interchangeable). Its primary value is a held-out,
> distribution-shift test of a model trained on our data.

---

## 1. AAA-100 (Twente + Amsterdam UMC, 2024)

**Citation**: Rygiel P, Alblas D, Brune C, Smorenburg S, Yeung KK,
Wolterink JM. *AAA-100: A Curated Dataset of 3D Watertight Abdominal
Aortic Aneurysm Models.* Zenodo (2024). DOI:
[10.5281/zenodo.10932957](https://doi.org/10.5281/zenodo.10932957).

**License**: CC BY-NC 4.0 (Attribution-NonCommercial). Commercial use
prohibited without relicensing.

### Contents (789.5 MB total)

| File | Size | Format | Per case |
|---|---:|---|---|
| `meshes.zip` | 780 MB | `.stl` triangle mesh | 1 watertight lumen surface |
| `centerlines.zip` | 825 KB | `.vtp` (VTK PolyData) | 5 centerlines: aorta, L iliac, R iliac, L renal, R renal |
| `description.pdf` | 8.5 MB | PDF | Methodology + per-case notes |

Cases are named `AAA001` … `AAA100`.

### What it provides

- 100 watertight lumen-only AAA geometries in scanner world coordinates (mm).
- Centerlines as polylines (point ordering proximal-to-distal documented in the description PDF).
- Coverage: aorta from approximately T12 down to the iliac bifurcation; iliacs ~5 cm distal to bifurcation; renals ~3 cm distal to ostium.
- Topological validation: per-case Betti numbers (b₀=1, b₁=0, b₂=1) confirmed in description.

### What it does NOT provide

- **No source CTAs.** Image data is not released.
- **No segmentation masks, no DICOM, no NIfTI.**
- **No outer wall, no intraluminal thrombus.** Lumen-only meshes.
- **No clinical measurements** (max diameter, neck length, neck angulation, iliac diameter) — must be derived from the meshes ourselves.
- **No demographics** (age, sex, AAA diameter distribution).
- Iliacs truncated at ~5 cm — insufficient for distal CFA landing-zone planning.

### Cohort selection

- 100 patients treated with EVAR at Amsterdam UMC, January 2017 – December 2021.
- Pure infrarenal AAA cohort (no TAAA).
- EVAR-eligibility selection bias toward larger aneurysms relative to a typical AAA screening cohort.

### Image specs (per description, source CTAs not included)

- In-plane resolution 0.6–1.0 mm.
- Slice thickness 0.5–2.0 mm.
- Volume size 512 × 512 × 172–1897 slices in Z.
- Scanner manufacturers not disclosed.

### Methodology references

- Rygiel et al. (2024) *Global Control for Local SO(3)-Equivariant Vessel Segmentation.* [arXiv:2403.15314](https://arxiv.org/abs/2403.15314).
- Alblas et al. (2023) *SIRE: scale-invariant, rotation-equivariant centerline tracking.* [arXiv:2311.05400](https://arxiv.org/abs/2311.05400).
- Alblas et al. (2022) *Implicit neural shape representation for AAA*, STACOM.

### Role in this project

1. **Geometry / centerline benchmark.** Validate `+autoseg` mask post-processing, `+preprocess` centerline extraction, and the `+evar_plan` measurement code against ground-truth meshes and centerlines. Compute Hausdorff and centerline-correspondence errors per case.
2. **Calibrate SE(3) rule thresholds.** Run `autoseg.se3_per_centerline_check` over all 100 reference centerlines. Use the empirical 95th/99th percentile of κ_max, |τ|_max, and tortuosity per anatomic segment to set the FAIL thresholds so that real anatomy passes.
3. **Derive "TeraRecon-style" gold-standard measurements** on ~20 cases manually from the meshes (max AAA diameter along centerline, neck length cranial to bifurcation, neck angulation, iliac diameter at fixed distance below bifurcation). Use these as the gold standard for tuning measurement extraction.
4. **NOT a DICOM training set.** Without images the dataset cannot tune any step before centerline extraction (DICOM ingest, contrast handling, TS-segmentation post-processing).

### Integration status (built 2026-05-18)

| Component | Path | Status |
|---|---|---|
| Bulk VTP→MAT converter | `+library/+aaa100/bulk_convert_vtp.py` | done — reads all 500 VTP files via `vtk`, writes `aaa100_centerlines.mat` |
| Loader | `+library/+aaa100/load_all.m`, `load_case.m`, `list_cases.m`, `cache_root.m` | done — auto-builds the MAT cache if missing |
| Calibration | `scripts/calibrate_se3_thresholds.m` | done — empirical κ_max / |τ|_max / tortuosity / take-off distributions; writes `aaa100_se3_calibration.mat` |
| Regression test | `tests/test_aaa100_se3_rules.m` | done — 99.4% per-centerline pass rate (3/500 renal-artery curvature outliers), 100% cross-vessel pass |
| Shape model | `+library/+aaa100/build_shape_model.m` | done — Procrustes-aligned mean ± std for each vessel; bifurcation spread + take-off angle distributions |
| Measurement extraction | `+library/+aaa100/extract_measurements.m` | done — per-case radius profile + AAA max diameter, proximal-neck radius, neck length, distal iliac radius |

### Cohort-derived measurements (2026-05-18)

Running `extract_measurements()` on all 100 cases yields the following
distributions of EVAR sizing parameters (lumen-only, derived from mesh
inscribed-radius along the reference centerline):

| Measurement | Median | IQR | Range |
|---|---:|---:|---:|
| AAA max lumen diameter | 34.8 mm | 31.2 – 45.2 | 21.2 – 71.0 |
| Proximal neck radius | 9.9 mm | 9.0 – 10.8 | 5.9 – 18.3 |
| Proximal neck length (lowest renal → AAA start at R > 1.5× neck) | 50.7 mm | 35.6 – 93.2 | 14.9 – 150.9 |
| L iliac distal radius | 5.8 mm | 5.0 – 7.2 | 2.7 – 11.3 |
| R iliac distal radius | 6.0 mm | 4.8 – 7.1 | 2.6 – 11.8 |

These are LUMEN measurements (the meshes are lumen-only, no thrombus).
For outer-wall measurements we still need either a paired-image cohort
or manual annotation.

### Recalibrated SE(3) thresholds

The hand-picked thresholds were replaced with values derived from the
99th percentile of the AAA-100 cohort (with a small margin):

| Threshold | Old | New | AAA-100 99th percentile |
|---|---:|---:|---:|
| `kappa_max_per_mm` | 0.20 | 0.35 | 0.31 (iliac) |
| `tau_max_per_mm` | 0.10 | 5.00 | 4.7 (iliac), 10.2 (renal) |
| `tan_angle_max_deg` | 60 | 90 | 80 (aorta), 110 (renal) |
| `tortuosity_max` | 1.40 | 1.70 | 1.55 |
| `takeoff_angle_min_deg` | 15 | 5 | 4 (1st percentile) |
| `takeoff_angle_max_deg` | 60 | 85 | 82 |
| `symmetry_y_mm` | 25 | 50 | 42 |
| `takeoff_symmetry_deg` | 15 | 25 | now uses aorta centerline; verified asymmetric pair flags WARN |
| `curvature_ratio` | 3.0 | 2.5 | 2.2 |

### Storage layout (actual)

```
Vascular Mathematical Modeling/AAA-100/
├── centerlines.zip                       805 KB original archive
├── centerlines/                          unzipped
│   ├── AAA001/
│   │   ├── abdominal_aorta.vtp
│   │   ├── iliac_left.vtp
│   │   ├── iliac_right.vtp
│   │   ├── renal_left.vtp
│   │   └── renal_right.vtp
│   └── ... (AAA002 .. AAA100)
├── meshes.zip                            780 MB original archive
├── meshes/                               unzipped
│   ├── AAA001.stl
│   └── ... (AAA002 .. AAA100)
├── aaa100_centerlines.mat                derived: all centerlines as struct array
├── aaa100_se3_calibration.mat            derived: SE(3) threshold distributions
├── aaa100_shape_model.mat                derived: Procrustes-aligned mean shapes
└── aaa100_measurements.mat               derived: per-case radius profiles + EVAR sizing
```

The cache root is set by `library.aaa100.cache_root()` (defaults to the
sibling of the project root, alongside the JohnDoe1 EVAR folder). Override
with the `AAA100_CACHE_ROOT` environment variable.

### Known prior usage

- SIRE centerline tracking work (Alblas et al.).
- SO(3)-equivariant segmentation work (Rygiel et al.).
- Geometric deep-learning AAA growth prediction ([arXiv:2506.08729](https://arxiv.org/abs/2506.08729)).

---

## 2. AortaSeg24 (MICCAI 2024 challenge) — CT + multi-class segmentation

**Citation**: Imran M, et al. *AortaSeg24: Multi-class Segmentation of Aorta
and Great Vessels in CTA* (MICCAI 2024). Challenge:
[aortaseg24.grand-challenge.org](https://aortaseg24.grand-challenge.org/).
Class table: Table 2 of arXiv:2502.05330.

**License**: CC BY-NC 4.0 (Attribution-NonCommercial). **Never redistributed
with this repo** — the MIT license covers source only. Download it yourself
after accepting the grand-challenge data-use agreement.

### Contents

- ~100 CTAs, each with a voxelwise label of **23 classes**: 13 anatomic
  branches (arch vessels, celiac, SMA, both renals, both common + external +
  internal iliacs) and 10 aortic zones (Ishimaru-style 0–9).
- **Provides:** the CT image + a dense arterial-tree segmentation.
- **Does NOT provide:** aortic wall or intraluminal thrombus (lumen +
  branches only), and — importantly — **no CFA / femoral labels**: the
  iliacs stop at the external iliac (there is no zone below the iliac
  bifurcation). Plan the distal centerline target at the external-iliac
  terminus, not the CFA.

### Role in this project

1. **Real reference cases in the GUI/pipeline** — a licensed replacement for
   the synthetic phantoms when you want real anatomy (the phantoms stay as
   the shippable, deterministic test fixtures).
2. **Supplementary training / external validation** for the learned-
   segmentation phase (per the refined strategy, public data is *not* the
   foundation — our own CTAs are). Its branch/zone labels + AAA/dissection
   variability make it a good **distribution-shift probe**, and a source for
   pre-training label harmonization. The class map + `+autoseg/+aortaseg24/`
   nnU-Net backend are already scaffolded.

### Integration (built 2026-07-11)

| Component | Path | Purpose |
|---|---|---|
| Data root | `+library/+aortaseg24/data_root.m` | locate the downloaded cohort; override with `AORTASEG24_DATA_ROOT` |
| Case discovery | `+library/+aortaseg24/list_cases.m` | pair CT + seg NIfTIs (tolerant of naming variants) |
| Loader | `+library/+aortaseg24/load_case.m` | CT + label NIfTI → app D-struct + arterial mask + pipeline labels (via `autoseg.aortaseg24.translate_labels` + the class map) |
| Class map | `data/aortaseg24_class_map.json` | raw 23-class id → pipeline label (1=aorta, 2/3=iliacs, 4/5=CFAs[absent here], 6/7=renals, 8=celiac, 9=SMA, 11=ILT) |
| Test | `tests/test_aortaseg24_loader.m` | synthetic-NIfTI round-trip (no dataset needed) |

**Usage** (once downloaded and `AORTASEG24_DATA_ROOT` is set):

```matlab
cases = library.aortaseg24.list_cases();          % discover CT/label pairs
C = library.aortaseg24.load_case(cases(1).ct_path, cases(1).label_path);
app.AorticCenterlineApp;                          % (or reuse a running app)
% inject the real case exactly like a phantom:
%   app.injectCT(C.D); app.injectMask(C.mask);
```

**Caveats.**
- **NIfTI only** (`niftiread`/`niftiinfo`). AortaSeg24 ships NRRD — convert to
  `.nii.gz` first (3D Slicer, or `SimpleITK`).
- **Orientation.** The loader assumes the NIfTI array maps to the app's
  `[Y X Z]` cranial-first frame. If a case loads flipped/rotated, pass
  `opts.permute` / `opts.flip` to `load_case`; the app's orientation guard
  (femorals must be caudal) will flag a bad guess.
- **HU.** Assumes the CT is stored in Hounsfield units (standard for CTA).

*(A comparable "aortaseg60"-style cohort, if it turns out to exist, loads
through the same code — pass its own class-map JSON via
`opts.class_map_path`.)*

---

## 3. (Candidate) AortaSeg-60 — external validation

A ~60-case aorta CT segmentation set (referenced alongside AortaSeg24;
reported as **CC0 / public domain**, which — if confirmed — makes it usable
without the NC restriction that blocks AAA-100 and AortaSeg24). Emphasis on
**pathological variability**. 

**Intended role:** the **untouched external-validation cohort** for Phase 5
distribution-shift assessment — a model trained on our own CTAs is scored
here to measure how far it travels beyond our scanners. Loads through the
**same `+library/+aortaseg24` code** by passing its own class-map JSON via
`opts.class_map_path`. Status: not yet downloaded; **verify the license and
that cases are contrast-enhanced arterial CTA before use.**

---

## 4. (Candidate) AVT — Aortic Vessel Tree (Radl et al.)

Whole aortic vessel-tree CT segmentations across multiple centers, **mostly
healthy / non-aneurysmal** anatomy. Useful for **branch-continuity and
centerline topology** validation (the full tree is labelled), and as extra
pre-training signal after label harmonization. **Weakness for our task:**
little aneurysm / thrombus pathology, so it does *not* substitute for
AAA-specific data. Filter to contrast-enhanced series if training. Status:
not yet evaluated.

---

## 5. (Candidate) AAA-specific lumen + ILT cohorts (literature)

Several published AAA cohorts pair CTA with **lumen + intraluminal thrombus**
labels — the Set B classes no branch/zone dataset provides. These are the
most relevant external source for the **wall/ILT sac-sizing** model
(#37 / Set B) if own-institution ILT annotation bandwidth is short. Access
is per-paper (data-use agreements vary); catalogue specific cohorts +
licenses here as they are identified. Status: to be sourced.

---

## 6. (Future) Wittek et al. 4D-CTA AAA dataset

[Wittek A, et al. *4D-CTA dataset of 19 AAA patients.* Data in Brief
(2020). arXiv:2505.17647.](https://arxiv.org/abs/2505.17647)

Pairs source CTAs with segmentation. Will pair with AAA-100 to cover
the DICOM-to-mesh half of validation. Status: not yet downloaded /
integrated.

---

## 7. (Future) Vascular Model Repository

~32 AAA cases with paired images and geometry. Useful supplement.
Status: not yet evaluated.

---

## Phase-3 case (JohnDoe1 EVAR)

Internal prospective-validation case (preop CTA + intraop XA). See
`STATUS.md` for end-to-end pipeline results.
