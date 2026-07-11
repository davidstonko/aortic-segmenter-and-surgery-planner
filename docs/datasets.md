# External datasets for validation and calibration

This page catalogs the third-party datasets used in the project, what
each provides, what each does NOT provide, and how each is being used.
Datasets are listed in order of integration priority.

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

## 2. (Future) Wittek et al. 4D-CTA AAA dataset

[Wittek A, et al. *4D-CTA dataset of 19 AAA patients.* Data in Brief
(2020). arXiv:2505.17647.](https://arxiv.org/abs/2505.17647)

Pairs source CTAs with segmentation. Will pair with AAA-100 to cover
the DICOM-to-mesh half of validation. Status: not yet downloaded /
integrated.

---

## 3. (Future) Vascular Model Repository

~32 AAA cases with paired images and geometry. Useful supplement.
Status: not yet evaluated.

---

## Phase-3 case (JohnDoe1 EVAR)

Internal prospective-validation case (preop CTA + intraop XA). See
`STATUS.md` for end-to-end pipeline results.
