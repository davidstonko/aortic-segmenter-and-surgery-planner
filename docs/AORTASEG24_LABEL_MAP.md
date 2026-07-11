# AortaSeg24 multi-class segmentation — integration plan

**Goal #26.** Integrate AortaSeg24 — a multi-class aortic segmentation
network — as an optional alternate `+autoseg` backend. Trained on the
AortaSeg24 challenge dataset (Imran et al. 2024, 100 CTAs, 23 classes,
[grand-challenge.org/aortaseg24/](https://aortaseg24.grand-challenge.org/),
[arXiv:2502.05330](https://arxiv.org/abs/2502.05330)).

## What AortaSeg24 actually provides

**13 anatomic branches** (innominate, L common carotid, L subclavian,
celiac, SMA, L+R renal, L+R common iliac, L+R external iliac, L+R
internal iliac) **+ 10 aortic zones** (Zone 0 - Zone 9, anatomic
regions of the aorta defined by landmark vessels — likely
Ishimaru-like zoning, not yet verified from the proceedings).

**Important corrections (made 2026-05-21):** A previous draft of this
doc claimed AortaSeg24 segments the aortic wall and intraluminal
thrombus. **It does not.** AortaSeg24 is a lumen-only multi-class
segmenter — finer-grained than TotalSegmentator but does not unlock
wall / ILT measurements. If aortic-wall + thrombus segmentation is
required for outer-wall sizing, a different dataset/model is needed
(e.g. SegA challenge for wall+lumen, or a custom-trained variant).

## What AortaSeg24 adds over current TotalSegmentator-based pipeline

| Capability                                | TS (current) | AortaSeg24 |
|-------------------------------------------|:------------:|:----------:|
| Abdominal aorta (lumen)                   |      ✓       |     ✓      |
| Common iliac arteries                     |      ✓       |     ✓      |
| External iliac arteries (separate label)  |              |     ✓      |
| Internal iliac arteries (separate label)  |              |     ✓      |
| Renal arteries                            |      ✓ (post-process) |  ✓     |
| Celiac trunk                              |      ✓ (post-process) |  ✓     |
| SMA                                       |      ✓ (post-process) |  ✓     |
| Anatomic aortic zones (Ishimaru-style)    |              |     ✓      |
| Aortic wall                               |              |  **✗** (not in dataset) |
| Intraluminal thrombus                     |              |  **✗** (not in dataset) |

The net improvement: cleaner branch separation (no `extend_and_detect_branches`
fallback needed for renals/celiac/SMA), explicit internal/external
iliac labels, and zone-based clinical naming. Wall + ILT remain a
gap — pursued separately if needed.

## Phase A — scaffold (landed 2026-05-21)

The `+autoseg/+aortaseg24/` package skeleton is in place:

```
+autoseg/+aortaseg24/
├── detect.m            # locate a usable backend (honest about weights)
├── run.m               # B1 nnUNetv2_predict inference glue; errors
│                       #   Phase_B_needs_weights until a checkpoint exists
└── translate_labels.m  # 23-class → pipeline-label translator (JSON-driven)
data/
└── aortaseg24_class_map.json   # paper-aligned class map (v1.1-paper-aligned;
                                # still needs ground-truth-dataset verification)
```

`detect()` looks for candidate backends in priority order
(`AORTASEG24_MODEL_DIR` → nnUNet_results dataset dirs → env_override →
docker). **As of Phase B1 (2026-06-15)** `run()` implements the full
nnU-Net inference path and only errors (`Phase_B_needs_weights`) when no
checkpoint is on disk — see the Phase B section below.

## Pipeline-label scheme

Existing pipeline labels [1, 9]; AortaSeg24 contributes 1, 2, 3, 6,
7, 8, 9 (all already in the scheme).

| Pipeline label | Anatomy                          | Source backend                    |
|:--------------:|----------------------------------|-----------------------------------|
| 1              | Abdominal aorta (lumen)          | TS, or AortaSeg24 Zones 5-9       |
| 2              | Left common+external iliac       | TS, or AortaSeg24 classes 8 + 10  |
| 3              | Right common+external iliac      | TS, or AortaSeg24 classes 9 + 11  |
| 4              | Left CFA                         | `extend_to_cfa` (downstream)      |
| 5              | Right CFA                        | `extend_to_cfa` (downstream)      |
| 6              | Left renal artery                | TS, or AortaSeg24 class 6         |
| 7              | Right renal artery               | TS, or AortaSeg24 class 7         |
| 8              | Celiac trunk                     | TS, or AortaSeg24 class 4         |
| 9              | SMA                              | TS, or AortaSeg24 class 5         |
| 12, 13         | L/R internal iliac (future)      | AortaSeg24 only (12, 13)          |

Internal iliacs are not in the current pipeline scheme. If we ever
want explicit hypogastric labels for IFU iliac-length checks, they'd
fill labels 12-13.

## Phase B — backend integration

Realistic options after surveying the public state of the challenge
on 2026-05-21, **re-audited 2026-06-15 for the B1 inference-glue work**:

### B1 — Pretrained nnUNet checkpoint
**Status: STILL not publicly available (re-verified 2026-06-15).** No
public AortaSeg24 checkpoint exists. The proceedings paper does not link
a checkpoint; no Zenodo / HuggingFace mirror found.

- [github.com/PengchengShi1220/AortaSeg24](https://github.com/PengchengShi1220/AortaSeg24)
  (Apache-2.0) — the hierarchical / cbDice winning-line code. Ships an
  `nnUNet_hierarchical_cbdc_nnUNet_v2.5.zip` containing the **nnU-Net
  v2.5 trainer + plans/config code only**. Its README instructs you to
  **train from scratch**: first the low-res binary crop model
  (`Dataset825_AortaSeg24_CTA_bin_50`), then the full-res 24-class model
  (`Dataset824_AortaSeg24_CTA_50`). No `.pth` weights are bundled or
  released.
- [github.com/ImranNust/AortaSeg24](https://github.com/ImranNust/AortaSeg24)
  (MIT) — organizer's repo; SwinUNETR baseline **training** code, no
  trained weights.
- [arXiv:2511.14187 — "Hierarchical Semantic Learning for Multi-Class
  Aorta Segmentation"](https://arxiv.org/abs/2511.14187) (Springer LNCS
  proceedings of the challenge): nnU-Net V2 based, but releases code
  (fractal-softmax / cbDice), **not** a downloadable checkpoint.

Each challenge submission was a Docker container, but those containers
are **not** in any public registry.

**Decision: B1 cannot be closed today** without weights. There is no
URL to download a checkpoint from. B1 is only viable if (a) a challenge
team is contacted to share trained weights, or (b) the proceedings later
unlock download links. **Recommended path is B3** (train the public code
on the dataset — see below), which then *feeds* this same B1 inference
glue.

#### B1 inference glue — wired 2026-06-15 (weights-agnostic)

`+autoseg/+aortaseg24/run.m` now implements the full inference path so
that the day a checkpoint exists, it runs end-to-end with **zero further
MATLAB changes**:

1. `detect()` resolves a checkpoint via, in priority order:
   `AORTASEG24_MODEL_DIR` → `$nnUNet_results/Dataset824_AortaSeg24_CTA_50`
   → `~/nnUNet_results/Dataset824_AortaSeg24_CTA_50` (or the legacy
   `Dataset400_AortaSeg24`). It reports `available=true` only when a
   checkpoint **and** a python with `nnunetv2` importable are both found.
2. `run()` writes `D.vol` to a NIfTI in nnU-Net's `<case>_0000.nii.gz`
   layout (via `io.save_nifti`), shells out to `nnUNetv2_predict`, reads
   the multilabel NIfTI back (via `io.load_nifti_int`), and calls
   `translate_labels` to map raw → pipeline labels.
3. Until a checkpoint is on disk, `run()` raises
   `autoseg:aortaseg24:Phase_B_needs_weights` with exact instructions —
   it never fabricates a segmentation.

**To actually run B1 once you have weights:**

```bash
# 1. A python env with nnU-Net v2 (the public code targets v2.5):
pip install "nnunetv2>=2.5"

# 2. Lay out the trained model as a standard nnU-Net config dir, i.e. a
#    folder containing plans.json + dataset.json + fold_*/checkpoint_final.pth
#    (this is exactly what `nnUNetv2_train ...` produces under
#    $nnUNet_results/Dataset824_AortaSeg24_CTA_50/<trainer>__<plans>__3d_fullres/).

# 3. Point the planner at it (either form works):
export AORTASEG24_MODEL_DIR=/abs/path/to/Dataset824_AortaSeg24_CTA_50/nnUNetTrainer__nnUNetPlans__3d_fullres
#   …or rely on the nnUNet_results layout:
export nnUNet_results=/abs/path/to/nnUNet_results
```

```matlab
% 4. In MATLAB:
D   = preprocess.dicom_load(series_dir);
out = autoseg.aortaseg24.run(D);     % runs nnUNetv2_predict, returns pipeline labels
%   out.label      — Y×X×Z uint8 pipeline-canonical labels
%   out.label_raw  — raw AortaSeg24 multilabel
%   out.classes    — per-class report (id/name/pipeline_label/voxels)
```

Useful `opts` overrides: `.dataset` (default
`Dataset824_AortaSeg24_CTA_50`, or env `AORTASEG24_DATASET`),
`.configuration` (default `3d_fullres`), `.folds` (default `all`),
`.trainer_plans` (`'<trainer>__<plans>'`), `.work_dir`, `.keep_work`.

> **Note — two-stage models.** The winning hierarchical pipeline is
> *two-stage* (low-res binary localizer → full-res 24-class). The glue
> here invokes a **single** `nnUNetv2_predict` configuration, which is
> correct for the full-res model when run on an already-cropped volume,
> or for any single-stage checkpoint. If you train the full two-stage
> cascade, add the localizer/crop step ahead of step 2 (a follow-up;
> the single-stage path is sufficient to validate the wiring + label
> translation).

> **Label-ID caveat (unchanged).** `data/aortaseg24_class_map.json` IDs
> are still **inferred**, not verified against ground-truth NIfTI label
> values. Before trusting any downstream measurement, re-verify the
> integer IDs against the trained model's `dataset.json` `labels` block.

### B2 — Wrap a winner's published code + retrain
Both public repos (2nd-place + organizer) are permissively licensed
and have functional training pipelines. We could:
- Vendor `extern/aortaseg24_2nd_place/` (Apache-2.0, custom nnU-Net 2.5),
- Or `extern/aortaseg24_baseline/` (MIT, SwinUNETR),
- Apply the published preprocessing,
- Train ourselves.

This collapses into Phase B3 in practice — still need the dataset and
GPU time. The only saved effort is preprocessing-code authorship.

### B3 — Download AortaSeg24 + train from scratch
Concrete prerequisites:
1. **Dataset access.** AortaSeg24 isn't a direct download —
   registration on the grand-challenge.org platform + signing the
   Data Agreement Form + organizer approval is required. Timeline:
   days-to-weeks.
2. **Compute.** Your M1 MacBook Pro has Apple Silicon with MPS
   support. nnU-Net v2.x has experimental MPS support but training
   nnU-Net on M1 is meaningfully slower than CUDA (typical reports:
   10-30× slower than an A100). For a 100-CTA dataset with the
   standard nnU-Net 1000-epoch schedule, this is several days to a
   week on M1, vs ~12-24 h on A100.
3. **Dataset license.** AortaSeg24 license is not explicitly stated
   on the main grand-challenge page nor in the arXiv preprint — must
   be confirmed via the DAF. The challenge is hosted by an academic
   organization so academic use is almost certainly fine; commercial
   redistribution of derived weights is the open question.

### B-extra: SubstituteAortaSeg24 with full-resolution TotalSegmentator
TotalSegmentator's `--fast` mode (3 mm) is the current pipeline. The
**full-resolution mode** (1.5 mm, ~10× slower) segments more vessels
and at higher precision. It's already installed and licensed Apache
2.0 — *zero* new dependencies. May get us 80% of the AortaSeg24
benefit (finer branch separation) without any of the dataset / GPU
overhead.

This is worth A/B-testing **before** committing to AortaSeg24.

## Recommendation (Phase B selection)

Given the audit above, the realistic ordering is:

1. **First: try the B-extra path.** Switch our `autoseg.ts_run` from
   `--fast` to full-resolution TS, see whether the branch quality is
   already sufficient. Zero new license risk, zero new training. ~1
   day of work + a regression-test re-baseline.
2. **If TS-full isn't enough:** pursue B3 (dataset access + train),
   then run the trained model through the **B1 inference glue that is
   now wired** (set `AORTASEG24_MODEL_DIR`, see above). You'd need to
   register on grand-challenge.org, sign the DAF, and ideally find
   non-M1 GPU access (a single cloud-GPU run for ~$15-30 of compute
   would be much faster than training on M1).

**B1 cannot be closed standalone today** — no checkpoint is publicly
distributed. The B1 *code path* is wired and tested; it just needs
weights, which in practice means doing B3 first.

> ### ⚠️ Critical scope mismatch with the wall/ILT motivation
> The driver for goal #26 Phase B is **true outer-wall sac sizing on
> thrombus-laden AAAs** (the JohnDoe2 case: lumen Ø 24.9 mm read as "no
> aneurysm"). **AortaSeg24 does NOT segment aortic wall or intraluminal
> thrombus** — it is lumen + branches + zones only (re-confirmed
> 2026-06-15). Wiring AortaSeg24 therefore gives finer branch separation
> and zone naming, but **does not, by itself, unlock outer-wall
> measurement.** Pipeline labels 10 (wall) / 11 (ILT) remain reserved
> but unpopulated by this backend — `translate_labels` will never emit
> them from AortaSeg24 output.
>
> If outer-wall/ILT sizing is the real goal, a **different
> dataset/model is required** — e.g. the SegA challenge (wall+lumen),
> or a custom wall/thrombus model. That should be tracked as a separate
> backend, not as AortaSeg24 Phase B. Recommend raising this with the
> user before investing B3 GPU time in AortaSeg24 for a wall-sizing
> objective it cannot meet.

## Regression coverage (Phase A + B1)

- `tests/test_aortaseg24_backend.m` — 8 cases, all weights-free:
  detect-shape, run-errors-unavailable, **run-errors-needs-weights
  (gated on a backend being detected)**, **detect-weights-implies-python
  contract**, **run-only-throws-documented-IDs**, class-map JSON
  well-formedness, translate-labels round-trip,
  translate-labels-drops-pipeline-0.

  On a clean machine (no backend) the suite is **7 passed + 1
  assumption-skipped** (the needs-weights guard, which requires a
  detected backend to exercise). Setting `AORTASEG24_BACKEND=1` flips
  that case in and confirms `run()` raises
  `autoseg:aortaseg24:Phase_B_needs_weights` rather than fabricating
  output.

## License caveat for the eventual release

If/when AortaSeg24-derived weights ship in this repo:
- Project license stays **MIT** for the planner source.
- AortaSeg24-trained weights inherit whatever license the dataset
  carries — needs to be confirmed during dataset access. If
  non-commercial, add `LICENSE-AORTASEG24-WEIGHTS.txt` and surface
  in README.
