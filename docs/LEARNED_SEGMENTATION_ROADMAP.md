# Learned Segmentation Roadmap — from IRB CTAs to a model that generalizes

**Status:** planning (2026-07-11). IRB approved; real CTAs now collectable.
**Goal:** replace HU-threshold segmentation with a *learned* vessel
segmentation so the planner works on **any** contrast CTA — not just the two
tuned cases — and, later, segments **wall + thrombus** for true sac sizing.

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

## Phase 0 — Data governance & de-identification (blocking, do first)

The IRB approval permits collection; it does **not** relax PHI handling. Get
this airtight before any image leaves the scanner archive.

- **De-identify at intake.** Run every study through a DICOM de-id profile
  (DICOM PS3.15 Basic Application Level Confidentiality) — strip PatientName,
  PatientID/MRN, DOB, AccessionNumber, StudyDate/Time (or jitter dates
  consistently per patient), InstitutionName, ReferringPhysician, device
  serials, and private tags. Tools: `pydicom` + `dicognito`/`dicom-anonymizer`,
  or RSNA CTP for batch. **CTAs are abdomen/pelvis, so facial defacing is not
  needed**, but verify FOV never includes the face.
- **Codename scheme.** Reuse the `JohnDoeN` convention. The codename↔real-ID
  key is IRB-controlled: keep it **offline / in the regulated store**, never
  in the repo or the working tree. (The repo's `.gitignore` already blocks
  `data/`, `*.dcm`, `*.nii`, non-phantom `*.mat`.)
- **Provenance manifest.** A de-identified CSV: codename, scanner/protocol,
  contrast phase, slice thickness, FOV, pathology label, split assignment.
- **Storage.** Raw de-id DICOM + NIfTI conversions in the IRB-approved
  location; only derived, non-PHI artifacts (metrics, figures, model configs)
  ever go near the repo.

**Deliverable:** a `deidentify_intake` script + the provenance manifest.

## Phase 1 — Cohort design

Aim for **60–100 CTAs** to start (nnU-Net trains well on 40–80 quality
annotations; more helps the tail). Design for *coverage of failure modes*,
not just typical anatomy:

- Normal infrarenal aorta (baseline).
- Infrarenal AAA, **thrombus-laden** (needed for the wall/ILT labelset).
- Post-EVAR (endograft artifact — a distinct appearance).
- **Deliberately hard cases**: low iliac contrast, fragmented/ tortuous
  iliacs, large-FOV runoff (747–1063 slice), poor bolus timing — the exact
  cases the heuristic pipeline fails on. These are the point.
- Patient-level **train/val/test split** ~70/15/15, stratified by pathology.
  No same-patient leakage across splits.

**Deliverable:** the manifest's `split` + `pathology` columns populated.

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
  1. TotalSegmentator auto-prelabel (cheap first pass).
  2. Manual correction in **3D Slicer** (or ITK-SNAP/MITK) — this is the
     operator learning to segment. The app's own brush/scalpel editor can do
     touch-ups, but Slicer is better for full volumes.
  3. Second-reader QC on a sample; track inter-rater **Dice ≥ 0.9** on lumen.
- **Protocol SOP** (extend the TeraRecon guide style): define each class,
  boundary rules (lumen vs wall, CIA/EIA/CFA transition at the internal-iliac
  takeoff and inguinal ligament), and the thrombus/wall convention.

**Deliverable:** `docs/SEGMENTATION_ANNOTATION_SOP.md` + labeled NIfTI masks.

## Phase 3 — Model training (nnU-Net v2)

- **Framework:** nnU-Net v2 — field standard, self-configuring, and already
  the target of the `+aortaseg24` backend (`nnUNetv2_predict`). The
  AortaSeg24 public *training* code (Apache-2.0 nnU-Net recipe) bootstraps
  the config.
- **Strategy:** two models — Set A (lumen+branches, all cases) and Set B
  (wall+ILT, AAA subset). Fine-tune from TotalSegmentator/AortaSeg24 weights
  where licensing allows; else train from scratch (feasible at this N).
- **Compute:** one modern GPU (≥24 GB, e.g. RTX 4090/A100). nnU-Net 3d_fullres
  ≈ hours-to-1-day per fold; 5-fold CV. Cloud A100 if no local GPU.
- **Loss/eval:** nnU-Net defaults (Dice+CE); 5-fold CV; report per-class Dice.

**Deliverable:** an `nnUNet_results` checkpoint dir + training config, and the
verified class map.

## Phase 4 — Integration (mostly already wired)

- Point `+autoseg/+aortaseg24/detect.m` at the checkpoint
  (`AORTASEG24_MODEL_DIR` / `nnUNet_results/Dataset…`). `run.m` →
  NIfTI → `nnUNetv2_predict` → `translate_labels` → pipeline mask. **No MATLAB
  changes** beyond the class-map verification (GOALS #26 B1).
- Add `opts.seg_backend ∈ {totalsegmentator, learned, auto}` to
  `run_planner_headless` + the GUI Step-2 mode (mirror the centerline-backend
  selector). The learned mask flows into the **same** centerline →
  measurement → IFU path, so the whole planner benefits with one swap.

**Deliverable:** backend selector + a learned-seg run on a held-out case.

## Phase 5 — Validation & closing the open goals

- **Segmentation:** Dice / HD95 per class on the held-out test set.
- **Generalization (#41):** re-run the previously-failing cases → target
  **N/N centerlines** that span aorta→CFA, `qc.usable` true. This is the
  headline success metric.
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

1. **How many cases / who annotates?** Sets the timeline. Even 40 well-
   labeled cases beat 100 noisy ones.
2. **Wall/ILT now or later?** #37 deferred it to "the very end." Recommend
   annotating Set A first (closes generalization, the bigger win) and Set B
   on the AAA subset in parallel if annotation bandwidth allows.
3. **Compute:** local GPU vs cloud. Determines cost and iteration speed.
4. **Annotation tool:** 3D Slicer (recommended) vs extending the app's editor.

---
*RESEARCH USE ONLY. This roadmap governs a research pipeline, not a
regulated device. All patient-data handling is subject to the approved IRB
protocol.*
