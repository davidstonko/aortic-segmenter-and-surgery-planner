# Learned Segmentation Roadmap — from IRB CTAs to a model that generalizes

**Status:** planning; strategy refined 2026-07-15 (was 2026-07-11). IRB
approved; real CTAs now collectable.
**Goal:** replace HU-threshold segmentation with a *learned* vessel
segmentation so the planner works on **any** contrast CTA — not just the two
tuned cases — and, later, segments **wall + thrombus** for true sac sizing.

## Guiding principles (the strategy, in five decisions)

These are settled and drive every phase below.

1. **Transfer learning, not from scratch.** Warm-start from an existing
   aorta-aware model (TotalSegmentator / nnU-Net) and fine-tune. A cold
   nnU-Net can ultimately win on a well-defined task, but transfer de-risks
   us and gets a working model with *far less* annotation. From-scratch is
   the fallback if licensing blocks the warm start (feasible at our N).
2. **Match the imaging *distribution*, not the file container.** DICOM vs
   NIfTI is irrelevant once loaded — the network learns from normalized voxel
   intensities, and nnU-Net's preprocessing (HU windowing, normalization,
   resampling) harmonizes across sources. What actually matters: **contrast
   phase (arterial CTA), resolution / slice thickness, scanner, and pathology
   appearance** (thrombus, calcification, endograft). CT is forgiving here
   because HU is physically standardized.
3. **Own institutional CTAs are the *foundation*.** Bootstrap labels on our
   own historical archive (TotalSegmentator / nnInteractive prelabel → expert
   correct → fine-tune). Our archive is a perfect distribution match *by
   construction* — same scanners, protocols, contrast timing, patient
   population. This is the cleanest answer to "don't learn from dissimilar
   source data."
4. **Public data is supplementary / external validation, *not* the
   foundation.** If used for training at all, filter strictly to
   contrast-enhanced aneurysm CTA. Its primary job is **distribution-shift
   assessment** on a held-out external set. Candidates and their fit are
   catalogued in [`datasets.md`](datasets.md).
5. **Label-space consistency is mandatory when combining sources.** Whole-
   aorta vs 23-zone schemas are *not* interchangeable. Harmonize everything
   to one scheme (or relabel via TotalSegmentator) **before** mixing — the
   `aortaseg24_class_map.json` + `translate_labels` path is exactly this
   harmonization layer.

## Why this is the next phase

The heuristic pipeline works on 2 of 4 real CTAs (GOALS #41). The root cause
is settled: on low-contrast arterial breaks, HU-threshold region-growing
either misses the vessel (HU ≥ 150) or leaks into veins/soft tissue
(HU ≥ 100) — it cannot both bridge the gap and stay vessel-confined. No
amount of parameter tuning closes this; the robust fix is a model that has
*learned* what a vessel looks like. Two capabilities we need:

1. **Robust lumen + branch segmentation** → closes the generalization gap
   (#41): aorta→CFA connected on every case.
2. **Aortic wall + intraluminal thrombus (ILT)** → true outer-wall sac
   sizing (#37 / audit B2), which lumen-only segmentation under-calls.

TotalSegmentator gives neither reliably on hard cases (it is a generic
104-structure model, not tuned for contrast-vessel continuity), and
AortaSeg24 has **no public checkpoint** and segments lumen+branches only
(no wall/ILT). So we must build our own labeled cohort and train.

## What already exists (build on, don't rebuild)

- **`+autoseg/+aortaseg24/{detect,run,translate_labels}.m`** — a
  weights-agnostic nnU-Net v2 backend, already wired to `nnUNetv2_predict`
  and the pipeline label scheme. It errors cleanly (`Phase_B_needs_weights`)
  until a checkpoint exists. **Integration is a no-op once we have weights.**
- **`data/aortaseg24_class_map.json`** — provisional class→pipeline-label
  map (lumen + branches + aortic zones; NOT wall/ILT). IDs must be verified
  against real ground-truth NIfTI values before use.
- **`+reference/` + `docs/TERARECON_ANNOTATION_GUIDE.md`** — a JSON schema,
  blank-template generator, and an annotation SOP. The annotation-protocol
  scaffold for *measurements*; we extend the same discipline to *voxel
  labels*.
- **AAA-100 reference cohort** (`+library/+aaa100/`) — 100 EVAR AAAs with
  meshes + centerlines (geometry only; **no source CTAs**). Good for
  centerline/measurement validation and SE(3) threshold calibration, NOT for
  training segmentation (no images).
- **`scripts/run_benchmark.m` + fixed cohort CSV** (`batch_summary_row`) —
  ready to produce the accuracy table once reference measurements are entered.

## Locked configuration (decided 2026-07-15)

| Decision | Choice | Consequence |
|---|---|---|
| **First label schema** | **Set A only** (lumen + branches + zones) | Closes generalization (#41) fastest; Set B (wall/ILT) deferred to a later pass. |
| **Case scope** | **Pre-op only**, + a small **post-EVAR** set held out as a labelled shift probe | Cleanest first model; no endograft artifact in the training distribution. |
| **Annotator** | **Solo, part-time** (surgeon) | Highest label quality; smaller active-learning batches; inter-rater QC done by **re-annotating a held-out subset** (intra-rater Dice) since there's no second reader yet. |
| **Compute** | **Apple Silicon (Mac M1) GPU** | Fine for annotation, prelabel inference, and the MATLAB planner — but **nnU-Net *training* wants CUDA**; see the compute reality-check in Phase 3. |

## Phase 0 — Data governance & de-identification (blocking, do first)

The IRB approval permits collection; it does **not** relax PHI handling. Get
this airtight before any image leaves the scanner archive.

**Status: BUILT** — the `+intake/` package (`intake.deidentify_intake`,
`intake.verify_deid`, `intake.append_manifest`) implements this phase, with
`tests/test_deidentify_intake.m` proving it on synthetic DICOM (6/6 green).
Run it on real patient DICOM **only inside the regulated environment**; the
repo and its tests use synthetic DICOM exclusively.

- **De-identify at intake.** `intake.deidentify_intake(SRC, 'JohnDoeN')` copies
  the study (never mutating the source), scrubs PHI on the copy, and re-maps
  identifiers to the codename. Two scrub engines:
  - **`dicomanon` (default)** — MATLAB-native (Image Processing Toolbox,
    DICOM PS3.15 Basic Confidentiality Profile), **no Python**, so it is
    portable and CI-testable. It generates consistent new Study/Series/SOP
    UIDs so the volume still loads as one series, and (a gap the profile
    leaves open) explicitly blanks Study/Series/Acquisition **dates + times**,
    which `dicomanon` otherwise keeps — a residual `StudyDate` is a
    re-identification vector.
  - **`dicognito`** — via the existing `preprocess.anonymize_dicom_dir` wrapper,
    for **cohort-consistent UID re-mapping** across many studies. Reserve for
    when cross-study UID relationships must be preserved.
  **CTAs are abdomen/pelvis, so facial defacing is not needed**, but verify FOV
  never includes the face.
- **Independent verification is the gate.** `intake.verify_deid` re-reads the
  *output* headers and, using the originals held **in memory only** (never
  written), proves every direct-identifier tag is gone or changed — it does not
  trust the tool that did the scrub. Any residual PHI **quarantines** the output
  (`*__QUARANTINE_FAILED`) and aborts; nothing reaches the manifest.
- **Codename scheme.** Reuse the `JohnDoeN` convention — enforced by regex, so a
  real name passed by mistake is rejected at the door. The codename↔real-ID key
  is IRB-controlled: it is **never produced or written** by the tool; keep it
  offline / in the regulated store. (The repo's `.gitignore` already blocks
  `data/`, `*.dcm`, `*.nii`, non-phantom `*.mat`.)
- **Provenance manifest.** `intake.append_manifest` writes a de-identified CSV
  (codename, modality, manufacturer/model, series description, geometry
  [rows/cols/slices/pixel spacing/slice thickness/FOV], contrast phase,
  pathology, phase, split, engine, n_files, UTC stamp). A field *named* like a
  patient identifier is refused, so the manifest is de-identified by
  construction. One row per study, appended.
- **Storage.** Point `opts.out_root` at the IRB-approved location. Raw de-id
  DICOM (and NIfTI conversions — see below) live there; only derived, non-PHI
  artifacts (metrics, figures, model configs) ever go near the repo.

**Deliverable:** ✅ `intake.deidentify_intake` + `verify_deid` +
`append_manifest` + tests. **Follow-up:** a `dcm2niix` conversion hook so
intake also emits the training-ready NIfTI (the `+library/+aortaseg24` loader
already ingests NIfTI once produced).

## Phase 1 — Cohort design

The cohort is **our own institutional CTAs** (principle 3). Aim for **60–100**
to start (nnU-Net trains well on 40–80 quality annotations; more helps the
tail). Design for *coverage of failure modes*, not just typical anatomy:

- Normal infrarenal aorta (baseline).
- Infrarenal AAA, **thrombus-laden** (needed for the wall/ILT labelset).
- **Deliberately hard cases**: low iliac contrast, fragmented / tortuous
  iliacs, large-FOV runoff (747–1063 slice), poor bolus timing — the exact
  cases the heuristic pipeline fails on. These are the point.
- Patient-level **train/val/test split** ~70/15/15, stratified by pathology.
  No same-patient leakage across splits.

**Pre-op vs post-op — scope pre-op first (recommended).** Stent-graft /
post-EVAR CTAs have a *very* different appearance (endograft metal, beam-
hardening, endoleak). Mixing them into the initial training set adds a hard
sub-distribution and dilutes the label budget. **Recommendation:** scope the
first model to **pre-op contrast CTA**; collect a small post-EVAR set but
hold it out as a labelled distribution-shift probe, and only train a
dedicated post-EVAR variant later if the planner needs surveillance sizing.
(This is an open decision — see the list at the end.)

**External validation set.** Reserve one public contrast-CTA cohort
(e.g. AortaSeg-60) *untouched* by training, purely to measure distribution
shift in Phase 5. See [`datasets.md`](datasets.md).

**Deliverable:** the manifest's `split` + `pathology` + `phase (pre/post-op)`
columns populated.

## Phase 2 — Annotation (the "learn to read/segment" core)

This is where reading skill is built and encoded.

- **Label schema, two label sets:**
  - *Set A (generalization):* lumen + celiac + SMA + both renals + both
    common/external iliacs + CFAs + aortic zones. Align IDs with
    `aortaseg24_class_map.json` and **verify them against the actual
    ground-truth NIfTI values** (the map flags this as unverified).
  - *Set B (sac sizing):* aortic **outer wall** + **ILT/thrombus** — the
    classes no public dataset provides. Annotate on the AAA subset.
- **Workflow (prelabel → correct → QC):**
  1. TotalSegmentator (or **nnInteractive** in 3D Slicer) auto-prelabel —
     cheap first pass.
  2. Manual correction in **3D Slicer** (or ITK-SNAP/MITK) — this is the
     operator learning to segment. The app's own brush/scalpel editor can do
     touch-ups, but Slicer is better for full volumes.
  3. Second-reader QC on a sample; track inter-rater **Dice ≥ 0.9** on lumen.
- **Active-learning order (which cases to correct first).** Don't annotate in
  arbitrary order — spend the budget where the model is weakest:
  1. Seed with ~15–20 *typical* cases (fast, high-quality) to fine-tune a v0.
  2. Run v0 over the un-annotated pool; **prioritise the cases where v0 is
     least confident / most disagrees with the TotalSegmentator prelabel**
     (high-entropy, high surface-distance). These are the failure modes.
  3. Correct that batch, re-fine-tune, repeat. This front-loads the hard
     iliac / low-contrast cases the heuristic pipeline already fails on and
     reaches reliable generalization with fewer total corrections than
     labelling everything blindly.
- **Protocol SOP — BUILT.** [`docs/SEGMENTATION_ANNOTATION_SOP.md`](SEGMENTATION_ANNOTATION_SOP.md)
  defines each Set-A class, the lumen-only rule (no wall/ILT/mural calcium), the
  aorta↔CIA↔EIA↔CFA transitions (internal-iliac takeoff, inferior-epigastric /
  inguinal-ligament landmark), the Slicer prelabel→correct workflow, the
  round-trip check, and intra-rater QC. Its machine-readable label spec is
  [`data/setA_class_map.json`](../data/setA_class_map.json) — paint IDs 4–13
  equal the AortaSeg24 raw IDs (shared label space), + aorta(1) and CFAs(24/25);
  verified to round-trip through `translate_labels` into the pipeline scheme.

**Deliverable:** ✅ `docs/SEGMENTATION_ANNOTATION_SOP.md` + `setA_class_map.json`;
labeled NIfTI masks pending real cases.

## Phase 3 — Model training (nnU-Net v2)

- **Framework:** nnU-Net v2 — field standard, self-configuring, and already
  the target of the `+aortaseg24` backend (`nnUNetv2_predict`). The
  AortaSeg24 public *training* code (Apache-2.0 nnU-Net recipe) bootstraps
  the config.
- **Strategy:** **transfer-learning-first** (principle 1) — warm-start from
  TotalSegmentator / nnU-Net aorta weights and fine-tune on our labelled
  cohort. Two models: Set A (lumen+branches, all cases) and Set B (wall+ILT,
  AAA subset). Train from scratch only if licensing blocks the warm start
  (feasible at this N).
- **Compute — reality-check for the Mac M1 (locked config).** nnU-Net and
  TotalSegmentator are built for **CUDA**. On Apple Silicon they run through
  the **MPS** backend, but MPS is under-optimized and some 3D ops fall back to
  CPU, so **3d_fullres *training* on an M1 is impractically slow** (and bounded
  by unified memory). Split the work by where each piece actually runs well:
  - **On the M1 (local):** 3D Slicer annotation (runs great), **prelabel
    inference** with TotalSegmentator / nnInteractive (slow but fine for a
    handful of cases), the whole **MATLAB planner**, and *inference* of the
    finished model (slow-but-workable, or push to cloud).
  - **In the cloud (CUDA), rented per run:** the actual **nnU-Net training**
    — a single A100/4090 does 3d_fullres in hours-to-1-day per fold. Only
    **de-identified NIfTI** leaves the regulated store (Phase 0 is the gate).
  This keeps PHI-adjacent work and iteration local, and rents GPU only for the
  short, compute-bound training step.
- **Loss/eval:** nnU-Net defaults (Dice+CE); 5-fold CV; report per-class Dice
  **and NSD** (normalized surface Dice — boundary-sensitive, which matters
  more for sizing than volumetric overlap).
- **MATLAB↔Python handoff.** Segmentation lives in Python (nnU-Net); the
  planner is MATLAB. The contract is a **NIfTI mask on disk** — Python writes
  the label volume, `+autoseg/+aortaseg24/run.m` reads it back via
  `translate_labels`. No in-process bridge; the file is the interface, which
  keeps the two ecosystems cleanly decoupled and reproducible.

**Deliverable:** an `nnUNet_results` checkpoint dir + training config, and the
verified class map.

## Phase 4 — Integration (selector BUILT; weights are the only gap)

- **`opts.seg_backend` selector — BUILT.** `run_planner_headless` now takes
  `opts.seg_backend ∈ {auto, totalsegmentator, learned, external}` via
  [`autoseg.resolve_seg_backend`](../+autoseg/resolve_seg_backend.m) (mirrors
  `centerline_backend`). Default `totalsegmentator` — **zero behaviour change**
  for existing callers. The learned/external mask flows into the **same**
  seeds → centerline → measurement → IFU path (the six TS-specific
  build/repair steps are skipped; the provided segmentation is trusted).
  `auto` uses the learned nnU-Net when weights are present, else TS.
- **`external` backend — usable TODAY, no model needed.** Point
  `opts.seg_label_nifti` at a pipeline-scheme label NIfTI (with
  `opts.seg_class_map = data/setA_class_map.json` if it is an SOP-painted
  Set-A mask) and the **full planner runs on a hand-annotated segmentation**.
  This means the annotation cohort can be planned and measured *before* any
  model is trained — and it is the exact code path a learned nnU-Net will use
  (it writes the same NIfTI). Covered by `tests/test_seg_backend.m` (7/7,
  synthetic).
- **`learned` backend** — `run.m` → NIfTI → `nnUNetv2_predict` →
  `translate_labels` → pipeline mask, adopted directly. Errors cleanly
  (`Phase_B_needs_weights`) until a checkpoint exists; point
  `AORTASEG24_MODEL_DIR` at it and `auto`/`learned` execute end-to-end with
  **no further MATLAB changes** (GOALS #26 B1).
- **GUI Step-2 "Source" dropdown — BUILT.** `AorticCenterlineApp`'s
  ⚡ Auto-segment section now has a segmentation-source dropdown
  (TotalSegmentator / Learned nnU-Net / External mask (NIfTI)…). Picking
  *External mask* prompts for the label NIfTI and asks whether it is painted in
  Set-A paint IDs (auto-selects `setA_class_map.json`) or already in pipeline
  labels. The Run button and status line reflect whether the chosen source is
  actually usable — TS not on PATH, no nnU-Net checkpoint, or no mask picked —
  and the TS ROI checkboxes grey out for non-TS sources. Both GUI run paths
  (step-by-step *Run segmentation only* and one-click *Auto-run*) honour the
  selection.
- Small enabling fix: `preprocess.auto_seeds_anatomic` now falls back to the
  pipeline aorta label (1) when the label volume isn't in TS ids — so
  learned/external label volumes seed correctly. TS path unchanged.

**Remaining:** a learned-seg run on a held-out case once weights exist.

**Deliverable:** ✅ backend selector (headless + GUI) + external-mask path,
tested; learned run pending weights.

## Phase 5 — Validation & closing the open goals

Evaluate on **two axes**: voxel-overlap metrics *and* the clinically
meaningful endpoints — overlap alone does not guarantee correct sizing.

- **Segmentation (overlap):** Dice / HD95 **/ NSD** per class on the held-out
  own-institution test set.
- **Clinical endpoints (the ones that matter):** **max aortic diameter
  error, neck length error, sac volume error** vs the TeraRecon reference —
  reported in mm/mL, not just Dice. A model can score high Dice and still
  miss a landing-zone diameter by a clinically relevant margin; these are the
  real acceptance criteria.
- **Generalization (#41):** re-run the previously-failing cases → target
  **N/N centerlines** that span aorta→CFA, `qc.usable` true. This is the
  headline success metric.
- **Distribution shift:** run the *untouched external* public set (Phase 1)
  and report the Dice/endpoint drop vs the internal test set — an honest
  measure of how far the model travels beyond our scanners.
- **Sac sizing (#37 / B2):** with Set B, measure **outer-wall** sac Ø and
  validate lumen-vs-wall against TeraRecon (measure wall in TeraRecon too).
- **Measurement accuracy (#5):** enter TeraRecon reference measurements into
  `library/reference/*.ref.json`; `run_benchmark` → the accuracy table (the
  cohort CSV now populates correctly). Report the
  `evar_plan.measurement_reproducibility` band on real cases.

## Dependencies & sequencing

```
Phase 0 (de-id)  ──►  Phase 1 (cohort)  ──►  Phase 2 (annotate)  ──►  Phase 3 (train)
                                                     │                      │
                                                     └── SOP + class-map ───┘
                                                                            ▼
                                              Phase 4 (integrate, ~no-op) ──► Phase 5 (validate)
```

Critical path is **de-id → annotation**; annotation is the long pole
(operator time). Training is compute-bound but short once labels exist.
Integration is nearly free (scaffold done). Start Phase 0 now; it blocks
everything and is pure engineering.

## Key decisions to make up front

1. **Label schema / granularity.** Binary lumen vs multi-class
   (lumen / ILT / wall / calcium) vs branch+zone — driven by intended
   clinical use. *Recommendation:* Set A = lumen + branches + zones first
   (closes generalization, the bigger win); add Set B = wall + ILT (+ mural
   calcium if cheap) on the AAA subset. Calcium is a near-free extra class on
   CT (it's a HU threshold inside the wall band) worth grabbing during Set B.
2. **How many cases / who annotates?** Sets the timeline. Even 40 well-
   labeled cases beat 100 noisy ones. Pair with the active-learning order in
   Phase 2 so the budget lands on the hard cases.
3. **Pre-op vs post-op scope.** *Recommendation:* pre-op first; hold a small
   post-EVAR set out as a shift probe (Phase 1).
4. **Wall/ILT now or later?** #37 deferred it to "the very end." Recommend
   annotating Set A first and Set B on the AAA subset in parallel if
   annotation bandwidth allows.
5. **Compute:** local GPU vs cloud. Determines cost and iteration speed.
6. **Annotation tool:** 3D Slicer (recommended) vs extending the app's editor.
7. **Evaluation contract.** Overlap (Dice/NSD/HD95) **+** clinical endpoints
   (max Ø, neck length, sac volume in mm/mL). Agreed as the acceptance bar
   (Phase 5).

---
*RESEARCH USE ONLY. This roadmap governs a research pipeline, not a
regulated device. All patient-data handling is subject to the approved IRB
protocol.*
