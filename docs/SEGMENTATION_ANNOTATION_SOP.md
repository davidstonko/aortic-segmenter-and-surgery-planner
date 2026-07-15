# Set-A Segmentation Annotation SOP — lumen + branches for EVAR

**Status:** draft 2026-07-15. Governs Phase-2 annotation in the
[learned-segmentation roadmap](LEARNED_SEGMENTATION_ROADMAP.md).
**Scope:** **Set A only** — arterial **lumen + branches** on **pre-op**
contrast CTA. This is the label set that closes the generalization gap
(GOAL #41: aorta→CFA connected on every case). Aortic **wall + intraluminal
thrombus** are **Set B** (GOAL #37, true sac sizing) and are **NOT** annotated
here — deferred to a later pass.
**Annotator:** solo, part-time (surgeon). QC is intra-rater (§6).
**RESEARCH USE ONLY.** All data handling is under the approved IRB protocol;
annotate only de-identified studies produced by
[`intake.deidentify_intake`](../+intake/deidentify_intake.m).

This SOP is the voxel-label analogue of the measurement protocol in
[`TERARECON_ANNOTATION_GUIDE.md`](TERARECON_ANNOTATION_GUIDE.md): it defines
each class, the exact anatomic boundaries between classes, and the
prelabel→correct→QC workflow, so labels are reproducible.

---

## 1. The Set-A label scheme

Paint in the IDs below (the machine-readable spec is
[`data/setA_class_map.json`](../data/setA_class_map.json); it round-trips
through `autoseg.aortaseg24.translate_labels` into the pipeline scheme).
Paint IDs **4–13 deliberately equal the AortaSeg24 raw IDs** for the abdominal
branches, so our own annotations and the public dataset share **one label
space** (roadmap principle 5) — a model can pretrain on one and fine-tune on
the other without a relabel.

| Paint ID | Structure | → pipeline label | AortaSeg24 raw |
|---:|---|---:|:---:|
| **1**  | Abdominal aorta **lumen** | 1 | (zones 19–23) |
| **4**  | Celiac trunk | 8 | 4 |
| **5**  | SMA | 9 | 5 |
| **6**  | Left renal artery | 6 | 6 |
| **7**  | Right renal artery | 7 | 7 |
| **8**  | Left common iliac | 2 | 8 |
| **9**  | Right common iliac | 3 | 9 |
| **10** | Left external iliac | 2 | 10 |
| **11** | Right external iliac | 3 | 11 |
| **12** | Left internal iliac (hypogastric) | 0¹ | 12 |
| **13** | Right internal iliac | 0¹ | 13 |
| **24** | Left common femoral (CFA) | 4 | — (new) |
| **25** | Right common femoral (CFA) | 5 | — (new) |

¹ Internal iliacs are painted for completeness and future use but currently
map to pipeline label 0 (ignored). They become labels 12/13 if/when the
pipeline adds them — annotating now avoids a re-do later.

**Why aorta is one label, not zones.** AortaSeg24 encodes the aorta as
Ishimaru-style zones (raw 19–23). For EVAR we paint the abdominal aorta lumen
as a **single** label (1); aortic zones are a *derived* landmark layer, not a
Set-A painting task (deferred). This keeps the annotation tractable and is
sufficient for the generalization fix and for diameter/neck/length morphometry.

---

## 2. What counts as "lumen" (the one rule that matters most)

Set A is **contrast lumen only.** On arterial-phase CTA the opacified lumen is
bright (≈ +200 to +500 HU); paint that.

- **Exclude the aortic wall.** The wall is the thin soft-tissue rim outside the
  contrast column. Not Set A.
- **Exclude intraluminal thrombus (ILT).** In an AAA the sac's *lumen* is the
  bright channel; the **crescent of thrombus** between lumen and outer wall is
  darker (≈ 20–60 HU) and is **NOT painted** in Set A. (This is exactly what
  lumen-only segmentation under-calls for sac sizing — Set B fixes it later.
  Do not compensate by over-painting into thrombus.)
- **Exclude mural calcium.** Calcified plaque in the wall blooms bright but is
  *outside* the lumen — do not include it. Where heavy calcium abuts the lumen,
  follow the contrast edge, not the calcium bloom.
- **Include the whole opacified cross-section**, wall-to-wall of the *contrast
  column*, on every slice — no lumen holes from noise.

---

## 3. Class boundaries (where one label stops and the next starts)

Paint on axial slices; **confirm every transition on coronal/sagittal
reformats** — the transitions are defined by branch-point landmarks that read
best off-axial.

- **Aorta — superior extent.** Start ~2 cm above the **celiac origin** (or the
  diaphragmatic hiatus if that is lower in the FOV). This captures the
  suprarenal segment and the renal/visceral context the planner needs.
- **Aorta — inferior extent / aorta↔CIA.** At the **aortic bifurcation**: the
  last slice with a single aortic lumen is aorta (1); at and below the split,
  each limb is a common iliac (8/9).
- **CIA↔EIA.** At the **internal iliac (hypogastric) origin.** Proximal to the
  IIA takeoff = common iliac (8/9); distal = external iliac (10/11). Paint the
  IIA itself (12/13) to its first division only.
- **EIA↔CFA.** At the **inferior epigastric artery origin** (≈ the inguinal
  ligament / femoral-head level) — the conventional EIA→CFA landmark. Below it
  is common femoral (24/25).
- **CFA — inferior extent.** Stop at the **femoral bifurcation** (into SFA and
  profunda femoris). The CFA is the EVAR access/seal segment; SFA/profunda are
  out of scope.
- **Renal arteries (6/7).** Include the **ostium + ~1–2 cm** of proximal
  vessel; stop before hilar branching. The renal ostia define the infrarenal
  neck — get the ostium level right.
- **Celiac (4) / SMA (5).** Proximal trunk only (~2–3 cm from origin) — enough
  to fix the origin level (SMA origin is the lower reference for the visceral
  segment). Do not chase distal mesenteric branches.

---

## 4. Prelabel → correct workflow (3D Slicer)

1. **Prelabel (cheap first pass).** Run TotalSegmentator on the de-identified
   NIfTI (`TotalSegmentator -i <codename>.nii.gz -o ts_out`), or use
   **nnInteractive** inside Slicer. Import the aorta/iliac/branch masks as a
   Segmentation. This is a *starting point*, not the answer — TS misses the
   low-contrast iliac breaks that are the whole point of this cohort.
2. **Correct (Segment Editor).** This is where the reading skill is encoded.
   - **Threshold** effect windowed to the arterial lumen (start ≈ 150–500 HU;
     tune per bolus) painted *within* a masked region so it can't leak.
   - **Islands** to remove disconnected specks; **Scissors** to cut veins /
     adjacent bowel; **Paint/Erase** (2–3 px) for the fine corrections.
   - Assign each segment to its **Set-A paint ID** (§1) via a saved color
     table so IDs are consistent across cases.
   - Fix every §3 transition on the reformats.
3. **The app's editor** can do touch-ups on a loaded case, but Slicer is better
   for painting full volumes end-to-end.

---

## 5. Export & round-trip check (do this on case #1, before scaling)

- Export the segmentation as a **NIfTI label volume on the CT grid**:
  `<codename>_segA.nii.gz` (same geometry/affine as the CT — Slicer's
  "Export to file" with the master volume as reference).
- **Verify the IDs round-trip** before trusting the scheme:

  ```matlab
  C = library.aortaseg24.load_case('<codename>.nii.gz', '<codename>_segA.nii.gz', ...
        struct('class_map_path', fullfile('data','setA_class_map.json')));
  % Inspect C.label_branch (pipeline scheme) + C.mask in the GUI:
  autoseg.aortaseg24.translate_labels(...)   % under the hood
  ```

  Confirm aorta=1, iliacs=2/3, CFAs=4/5, renals=6/7, celiac=8, SMA=9, and that
  the arterial mask spans aorta→CFA. Eyeball it in `AorticCenterlineApp`.
- **Run the full planner on your annotation — no model needed.** The
  `external` segmentation backend feeds a labelled NIfTI straight into the
  centerline → measurement → IFU pipeline:

  ```matlab
  out = run_planner_headless('', struct( ...
      'D', preprocess.dicom_load('<codename>_dicom_dir'), ...   % or pass the CT
      'seg_backend',    'external', ...
      'seg_label_nifti','<codename>_segA.nii.gz', ...
      'seg_class_map',  fullfile('data','setA_class_map.json')));  % SOP paint-IDs → pipeline
  ```

  So every annotated case can be planned and measured *now*, before any model
  exists — and this is the exact path the trained nnU-Net will use.
- Keep `<codename>_segA.nii.gz` in the **regulated store**, never the repo
  (`.gitignore` blocks `*.nii`).

---

## 6. QC — intra-rater reproducibility (solo annotator)

With one reader there is no inter-rater check, so reproducibility stands in:

- **Re-annotate a held-out 10–15% subset** ≥ 2 weeks after the first pass,
  blind to the original.
- Compute **Dice** (and NSD) first-vs-second. Targets: **≥ 0.90 lumen (aorta +
  iliacs)**, **≥ 0.80 branches** (renals/celiac/SMA — thinner, so lower).
- A class that misses target → **tighten its §3 boundary rule** in this SOP and
  re-do. The SOP is living: every ambiguity you resolve gets written down here.

---

## 7. Annotation order — active learning (spend the budget on hard cases)

Do **not** annotate in arbitrary order (roadmap Phase 2):

1. **Seed:** ~15–20 *typical* cases, fast and clean → fine-tune a **v0**.
2. **Rank the pool:** run v0 over the un-annotated cases; prioritise the ones
   where v0 is **least confident / most disagrees with the TS prelabel**
   (high entropy, high surface distance) — these are the low-contrast /
   fragmented-iliac failure modes.
3. **Correct that batch → re-fine-tune → repeat.** This reaches reliable
   generalization with fewer total corrections than labelling everything
   blindly, and front-loads exactly the cases the heuristic pipeline fails on.

---

## 8. Checklist per case

- [ ] Study de-identified via `intake.deidentify_intake` (codename only).
- [ ] Prelabel imported (TotalSegmentator / nnInteractive).
- [ ] Lumen only — no wall, no thrombus, no mural calcium (§2).
- [ ] Every §3 transition set on the reformats (aorta↔CIA↔EIA↔CFA, IIA, renals,
      celiac/SMA).
- [ ] Segments assigned to Set-A paint IDs via the saved color table (§1).
- [ ] Exported `<codename>_segA.nii.gz` on the CT grid, in the regulated store.
- [ ] (case #1) Round-trip verified through `setA_class_map.json` (§5).
- [ ] Row noted in the cohort manifest (pathology / phase / split already set
      at intake).

---
*This SOP governs a research annotation protocol, not a regulated device.*
