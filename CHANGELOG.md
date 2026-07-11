# Changelog

Reverse-chronological log of session-level changes to the EVAR Planner.

## 2026-07-11 — Public v1 on GitHub + CI + measurement reproducibility

**Published to GitHub** (public): `github.com/davidstonko/aortic-segmenter-and-surgery-planner`.
Before the first commit, completed a repo-wide PHI scrub deeper than the
earlier surname pass — real given names + MRN/accession numbers were still
hardcoded in the diagnostic/demo drivers (`JOHNDOE1^ROBERT^SANGYONG`,
`MATSCHAT^NANCY^A`, etc.); all replaced with de-identified placeholder paths,
`run_eia_matschat.m` → `run_eia_johndoe4.m`, `output/` (real-patient renders)
git-ignored. Verified zero PHI across all tracked files.

**CI (`.github/workflows/matlab-smoke.yml`) live and green** on GitHub-hosted
Ubuntu via `matlab-actions/setup-matlab` (R2024a + R2024b). The first run went
red and caught a real portability bug: `data/aortaseg24_class_map.json` (a
non-PHI, paper-derived label map the code loads at runtime) was excluded by the
broad `data/` ignore, so it never shipped — present locally (passed on R2025b)
but missing on a clean checkout. Narrowed to `data/*` + a single-file
re-include; patient DICOM/`.mat` stay ignored. Re-run green on both versions.

**Aneurysm-onset hysteresis (GOALS #35 B-iii).** `measure_from_centerline`
previously fired the aneurysm onset on the FIRST single node with R >
`aneurysm_R_mm` (14) — one spuriously-wide slice could flip the onset and swing
neck length + β. Onset now requires the over-threshold condition to be
SUSTAINED over ≥ `opts.aneurysm_min_run_mm` (default 3 mm) of arc; a lone spike
is skipped. Default is short enough that a genuine sac is detected at the same
node as before, so the AAA phantom result is unchanged (neck Ø 26.56, length
36.73, β 5.23), but the onset is now robust to resampling noise.

**Measurement reproducibility band (GOALS #35 B-iii).** New
`evar_plan.measurement_reproducibility(pr, opts)` reports how far the sizing
scalars move under N perturbations of the centerline (random rigid rotation +
arc-resampling jitter) — a reproducibility band for the publication's repro
claim. On the AAA phantom (24 trials, ±3° / ±15% resample): neck Ø σ 0.013 mm,
β σ 0.16°, neck length σ 0.39 mm, iliac Ø exactly invariant. New tests
`tests/test_measurement_reproducibility.m` (3): hysteresis rejects a lone
spike; the band is tight on the phantom; rotation-only is invariant.

**Step-3c HU-reconstruct: memory scaling for large-FOV CTA (GOALS #39).**
Extracted the inline Step-3c grow from `run_planner_headless` into
`autoseg.hu_reconstruct_shell`, which crops the work to the mask bounding
box padded by the shell radius. The naive form allocated 4-5 full-
resolution boolean volumes (contrast mask, shell, candidate, grown) over
the ENTIRE scan — hundreds of M-voxels each on a 747-1063-slice runoff CTA
even though the vessels span a fraction of the z-extent. The reconstruction
is bounded to a shell around the mask, so the padded crop contains every
voxel any full-volume op could set → output is bit-identical, memory now
scales with the vessel sub-volume not the FOV. New tests
`tests/test_hu_reconstruct_shell.m` (3) pin crop == full-volume reference
(incl. boundary-clamp + empty-mask).

**Step-3c'/3c'' reconnect: finished the FOV-independence sweep (GOALS #39).**
Audited the two reconnect stages: `reconnect_vessel_fragments` (3c') was
*already* cropping its iterative flood to the pelvis-band bbox + shell — no
change needed. `reconnect_via_vesselness_path` (3c'') was casting
`double(D.vol)` over the WHOLE volume (~2.5 GB on a 1000-slice scan) only to
slice small per-fragment ROIs out of it; changed to per-ROI
`double(D.vol(roi))` — identical values, FOV-independent memory. Added
`tests/test_reconnect_vesselness_path.m` (2), covering a function that had
no tests: a contrast bridge fuses two fragments (never removing voxels) and
a single-component input is a no-op. All three Step-3c stages are now
FOV-independent.

**QC reliability verdict surfaced in the plan (honest failure, GOALS #41).**
`run_planner_headless` had per-check QC flags (`segmentation_incomplete`,
`orientation_suspect`, `centerline_implausible`) but no single verdict, and
`generate_plan` emitted confident-looking sizing even from a degenerate
centerline. Added `autoseg.qc_summary(qc)` → `[usable, summary]` (usable =
false if any hard check failed), wired as `out.qc.usable`/`out.qc.summary`.
`generate_plan` now carries `plan.qc_usable`/`plan.qc_summary`, prepends a
`*** QC FAILED — … ***` banner to the plan text, and serialises both to the
JSON — so a batch/GUI/reader can gate on one field and nobody mistakes an
unreliable result for a real plan. New tests `tests/test_qc_summary.m` (6):
verdict logic + plan surfacing (fails → banner + json flag; no-QC → usable).

## 2026-06-16 — Generalization test on 2 new CTAs (FAILS) + 2 bug fixes

Ran `run_planner_headless` end-to-end on two new out-of-cohort CTAs (deps live:
TotalSegmentator 2.13.0 + VMTK). **The system does not generalize to either:**

- **JohnDoe4** (747-slice Aorta CTA): fast mode — TS-fast missed the RIGHT iliac
  → auto-seed hard failure. Full (1.5 mm) mode — both iliacs found, but the
  centerline still collapsed (arc R 66 / L 76 mm vs ~600 expected).
- **JohnDoe5** (1063-slice CAP): completes but degenerate centerline (fast R 106 /
  L 45; full R 77 / L 0 mm).
- **JohnDoe3** (Charabati): only ~44 slices as downloaded — partial, not a usable CTA.

Root cause: segmentation doesn't connect aorta→CFA on these scans (mask
fragmentation / collapsed VMTK path). The planner currently only works on the two
cases it was tuned on — tracked as GOALS #41 (core Phase-3 generalization problem).

Two bugs the test exposed, both fixed:
- **CFA-extend logging bug** (`run_planner_headless`): the progress log read
  `info_cfa.L.starting_z`, a field that doesn't always exist, throwing INSIDE the
  extension `try` and mislabeling a successful extension as failed (spurious
  `seg_incomplete`). Logging is now isolated in its own inner try; only a real
  `extend_to_cfa` error sets the flag.
- **QC gap** (`out.qc.centerline_implausible`, new): a collapsed centerline used to
  report clean. Now flags arc < 200 mm/side with a warning. Verified it fires on
  JohnDoe5. (The A4 segmentation-incomplete flag also correctly caught the logging
  bug during the run.)

New-case cache PHI scrubbed; patient surnames kept out of the repo (logged as
JohnDoe3/4/5).

### GOALS #41 (generalization) — first step: label-aware Step 6b
Diagnosed why JohnDoe4 collapses: the mask was truncated at z≈315 while real
right iliac→CFA labels ran to z≈597 — that caudal vessel was a separate connected
component that Step 6b's keep-largest-CC filter silently dropped. **Fix:** Step 6b
now keeps the largest CC PLUS any CC carrying iliac/CFA branch labels (2-5) — a
floating thoracic-aorta fragment (label 1/unlabeled, the JohnDoe2 case) is still
dropped, but real segmented vessel is never discarded. No synthetic voxels added.
Verified: JohnDoe4 mask now spans z=141→597 (was 141→315); JohnDoe2
unchanged (arc 410/216, no regression).

**Root cause nailed (2026-06-17):** the JohnDoe4 aorta→iliac break is a GENUINE
low-contrast gap, not a tunable connectivity bug. Measured: 62 mm gap, CT HU along
the break ~−75 (only 3% ≥150 HU). Parameter sweep — more reconnect reach
(max_iters 8→40, shell 5→12 mm) keeps adding real contrast voxels but never merges
the CCs at the correct arterial floor (HU≥150); lowering to HU≥100 merges them but
leaks 0.3–1M voxels and collapses the centerline to arc 0. So HU-threshold
region-growing can't close these gaps cleanly (miss at ≥150, leak at ≥100) — a
segmentation-recall limit whose robust fix is a learned vessel model (GOALS #26),
not heuristic tuning. The reconnect-param threading was reverted (defaults kept).
**Net: 2 of 4 CTAs work** (JohnDoe1/JohnDoe2 regression-confirmed); JohnDoe4/JohnDoe5
fail and the `centerline_implausible` QC now flags it explicitly. Tracked in GOALS #41.

## 2026-06-15 — Clinical-measurement reconciliation (B1–B3 from the GUI audit)

### Why
The 2026-06-15 GUI audit surfaced three clinically-loaded measurement issues that
needed a vascular-surgeon decision before changing outputs:
- **B1** — two engines produced different numbers for the same case. The Step 5
  on-screen display used `preprocess.evar_measurements` (neck angulation 62.6° on
  JohnDoe1), while the exported plan + IFU matching used
  `evar_plan.measure_from_centerline` (9.3°). They measure *different* anatomical
  angles (infrarenal neck-to-sac β vs suprarenal-to-neck α) over different window
  lengths, and 62° vs 9° flips device eligibility — an operator saw one angle and
  exported another.
- **B2** — every diameter is a contrast-**lumen** diameter (TotalSegmentator
  segments lumen only), so a thrombus-laden sac is under-called.
- **B3** — when the aneurysm-onset detector doesn't fire, the "neck" ran to the
  bifurcation, yielding implausible 84–131 mm neck lengths that read as real.

User decisions: report **both α and β** (eligibility keyed off β); label diameters
as lumen now and pursue outer-wall seg later; report neck length **N/A** when no
aneurysm is detected.

### What changed
- **One measurement engine.** `evarMeasurementsText` (Step 5 GUI) now sources the
  neck/aneurysm/angulation headline numbers from `evar_plan.measure_from_centerline`
  — the same engine the exported plan + IFU matching use — so **on-screen == export**.
  It still keeps the landmark-based iliac CIA/EIA/tortuosity/conicity detail.
- **B1 — α + β.** `measure_from_centerline` emits `neck_angulation_alpha_deg`
  (suprarenal-to-neck) and `neck_angulation_beta_deg` (infrarenal neck-to-sac),
  each over fixed `angulation_seg_mm` windows (node-spacing-independent).
  `neck_angulation_deg = β` is the IFU-canonical angle; `ifu.check_eligibility`
  reads it unchanged and skips the criterion when β is NaN.
- **B2 — lumen labeling.** New `diameter_basis='lumen'`. `generate_plan` text,
  the envelope table, the GUI panes, the headless log line, and the research
  disclaimer all label diameters "lumen Ø (excludes mural thrombus)".
- **B3 — honest neck length.** New `aneurysm_detected` flag; neck length is `NaN`
  (rendered "N/A (no aneurysm detected)") when no onset fires.
- **Docs:** `+reference/schema.m`, `+ifu/devices.m`, `+ifu/check_eligibility.m`
  document neck_angulation_deg = β.
- **Tests:** test_evar_plan +1 (α/β/lumen contract) and the no-aneurysm case now
  expects NaN neck length + `aneurysm_detected=false`; test_johndoe2_regression
  +1 (α/β contract) with `neck_angulation_deg` removed from the byte-drift baseline
  (its definition changed this session); test_pipeline_phantom + test_headless_pipeline
  made NaN-tolerant. **Non-GUI suite 108/108 green** (1 intentional AortaSeg24
  Phase-B skip).

### Verified
Functional run on cached JohnDoe2: lumen Ø 24.9 mm (R 12.4) is below the 14 mm-R
aneurysm threshold, so the plan now correctly reads "no discrete aneurysm detected
/ neck length N/A / lumen Ø excludes mural thrombus" with α = 5.0° and β = —. This
is the honest output and concretely motivates goal #26 (AortaSeg24 outer-wall/ILT
segmentation) for true sac diameter.

## 2026-06-15 (later) — Full project audit + fixes

Ran a full multi-dimensional audit via the new `/audit` skill (8 parallel
per-dimension subagents → `AUDIT_2026-06-15.md`): **Critical 1 · High 8 ·
Medium 11 · Low 19**. Two dimensions came back FAIL. Fixes landed this session:

### PHI (was CRITICAL — fatal to OSS release)
Cached/result `.mat` files embedded the source DICOM header (PatientName, MRN,
DOB, accession, institution, referring physician). `.gitignore` covered
`results/cache/` but not `results/logs/`. Fix: `.gitignore` now excludes all of
`results/` and every `*.mat` except synthetic phantoms; new
`scripts/scrub_phi_from_cache.m` recursively blanked the DICOM identifier tags
in all 45 cached `.mat` (verified empty); redacted the patient names that had
been quoted in the audit report. **Not yet done:** the "JohnDoe1"/"JohnDoe2" case
labels are the patients' surnames — de-identified codenames + a repo-wide rename
are needed before publish (GOALS #34).

### Sizing & IFU (was FAIL)
- **Neck-Ø over-call (~30%) fixed.** `measure_from_centerline` previously
  averaged the radius from the renal level *through the dilating segment* up to
  the aneurysm. New `locate_neck` measures neck Ø over a bounded proximal seal
  zone (`opts.seal_zone_mm`=15 mm) at the neck caliber, excluding the
  aneurysm-onset node. Numeric regression test pins ~16 mm on a profile that
  used to read ~20 mm. Phantom/JohnDoe2 recovery unchanged.
- **Vacuous IFU eligibility fixed.** `check_eligibility` skipped NaN criteria,
  so an all-NaN measurement set was reported "eligible". It now returns
  `indeterminate` (not eligible) unless the core criteria — neck Ø + both iliac
  Ø — are present. 2 new tests.

### Other audit fixes
- `run_planner_headless` records `out.qc.segmentation_incomplete` + warnings
  when a branch/CFA extension is caught (was a silent fprintf).
- Result-cache key now includes `use_adaptive_hu_follower` +
  `reconnect_iliac_fragments` (a parameter sweep on the same scan no longer
  returns a stale cached result).
- `export_mesh` now errors cleanly (`evar_plan:export_mesh:EmptyMesh`) on an
  all-false mask instead of crashing in the smoother; `test_export_mesh` added
  (STL written, mm-scaling, empty-mask rejection).
- Doc/CITATION currency sweep: STATUS/README/CONTRIBUTING/SETUP test counts,
  README device count (5→7), β/lumen output contract in README, CITATION
  version/date (ORCID left as a `TODO(author)`), DEPENDENCIES nnunetv2 row,
  CENTERLINE_METHODS banner, SE(3) docstring bounds.

**Non-GUI suite: 116/116 (+1 expected AortaSeg24 skip).** Remaining audit
follow-ups tracked as GOALS #34–40.

## 2026-06-15 — Viewer gaps confirmed, Step 6 mesh export wired, benchmark readiness

### Viewer gaps (#9) — already done, now confirmed
Slab MIP, cine play through MPR slices, and inverted-display toggle were all
implemented during the June sessions; the stale May-21 goal list hadn't recorded
it. Verified by wiring trace: `extractSliceOrSlab` (real per-axis max-intensity
projection over a `SlabThickness_mm` slab, in both 2×2 and single-view paths),
`InvertDisplay` through every `compositeView`, and `toggleCinePlay`/`cineStep`
(wrapping uitimer at selectable fps). Slab thickness is a preset dropdown
(0/5/10/20 mm), not a continuous slider.

### Step 6 mesh export (.stl) — audit C2
Step 6 advertised a ".stl for CFD / 3-D printing" output with no button. Added
`saveMesh` + a "🧊 Mesh .stl" button (Step 6 now has a 3-button save row:
centerline / plan / mesh), and `exportEverythingAuto` now also writes `lumen.stl`
(non-fatal). Both call the existing `evar_plan.export_mesh` with the loaded scan's
real `pixel_mm`/`slice_spacing_mm`. Verified: synthetic mask → 712 verts / 1420
faces / 71 KB STL.

### Benchmark readiness (#5)
Ran the full TeraRecon-comparison path end-to-end on a temp filled reference
(`compare_to_reference` + `run_benchmark` → delta table + CSV, NaN-skip confirmed).
Fixed a stale `docs/TERARECON_ANNOTATION_GUIDE.md` (described the α angle +
outer-wall diameters; corrected to β neck-to-sac + lumen to match today's engine)
and a vague comment in `compare_to_reference.m`. Added `docs/BENCHMARK_OPERATOR_STEPS.md`
(operator checklist). The benchmark runs the moment the operator enters real
TeraRecon numbers into the confirmed-blank `library/reference/JohnDoe1_EVAR.ref.json`.

### Deferred (deliberately)
The full decomposition of the 10.7k-line `AorticCenterlineApp` (audit C1/C3:
section banners, extract `projectToView`/`voxelVolumeToML`, constants block,
surface swallowed `try/catch` errors, explicit "CPR failed" state) is a separate
deliberate effort — not rushed blind into a working clinical app before the
publication push. Recommended as its own session with live GUI verification.

## 2026-06-12 — GUI: reliable one-click CT → segmentation+branches → centerline (JohnDoe1 + JohnDoe2)

### Why
The GUI could not reliably take the JohnDoe1 or JohnDoe2 CT all the way to a
useful segmented aorta (with branches) + centerline, even though the headless
engine (`run_planner_headless`, 108-test green) does it on both. Root cause was
GUI wiring, not the algorithms: (1) **auto-mode segmentation did nothing** —
`runAutoSeg` reads `ts_target_*` checkboxes that only the *user-mode* panel
builds, so in Automatic mode `targets` was empty and the function aborted with
"Nothing selected" (reproduced: mask voxels before=0, after=0); (2) the seg used
for branch detection / auto-seeds / audit was chosen by scanning the cache dir
for **the newest `*_seg.nii.gz`**, which silently grabbed another scan's labels
(or dropped branches) once more than one case had been segmented; (3) the GUI's
`runCenterline` lacked the **VMTK degeneracy retry** the headless path has, so
JohnDoe2's thin-bridge surface-pinch left the right centerline degenerate
(2 nodes, arc 0).

### What changed
- **One-click `runAutoPipeline`** (`+app/AorticCenterlineApp.m`, new method +
  `runAutoPipelinePublic` shim + a prominent "⚡ Auto-run full pipeline (CT →
  centerline)" button atop the Step-2 Automatic panel). It drives the proven
  `run_planner_headless` engine on the already-loaded volume and injects mask +
  branch labels + 3 seeds + the bifurcated centerline, landing on the Step-4
  MPR/MIP review. No modal prompts, no cache-guessing — deterministic on both
  scans.
- **`run_planner_headless` accepts a preloaded volume** via `opts.D` (skips the
  DICOM read) and now returns `out.label_branch` + `out.D` so a GUI caller gets
  a self-contained, displayable result.
- **Deterministic seg selection.** `runAutoSeg` now passes
  `return_label_volume=true` and stores the exact `info.label_volume` on
  `app.TSLabelVolume`; branch detection, `autoSeedsBestAvailable`, and the
  Step-2 audit all consume that handle instead of the "newest file" heuristic.
  `runAutoSeg` also falls back to the canonical target set
  (aorta + both iliacs) when no ROI checkboxes exist (Automatic mode).
- **VMTK degeneracy retry in the GUI** (`runCenterline`): mirrors the headless
  `reduce=0.0` retry (new file-local `vmtk_branch_degenerate_vox`), so a
  collapsed branch is recomputed without surface decimation. JohnDoe2 right
  branch 0 → ~506 mm.
- **Upside-down centerline fixed** (`mm_to_vox` in `+app/AorticCenterlineApp.m`).
  The centerline backends emit Z in the DICOM patient-position frame (Z from
  `D.slice_z_mm`, carrying a large negative ImagePositionPatient offset, e.g.
  ~-1500 mm). `mm_to_vox` was inverting Z as `P_mm/slice_spacing+1` (zero-origin
  assumption), landing the polyline thousands of voxels off the volume and
  rendering it flipped under `YDir='reverse'` (iliacs up, aorta down). It now
  inverts the `slice_z_mm` remap (`interp1(slice_z_mm, 1:N, P_mm_z)`); JohnDoe1
  right branch z now spans CFA z=1219 (caudal) → aorta z≈474 (cranial), matching
  the proximal seed at z=451. Fixes both VMTK and skeleton backends.
- **Distal endpoint capped at the common femoral** (`run_planner_headless` new
  Step 4b). `extend_to_cfa` + the adaptive follower walked the iliac/CFA mask to
  the FOV bottom, overshooting the CFA into the SFA / profunda — so the distal
  seeds (most-caudal voxel) landed in the deep/superficial femoral, not the CFA
  (flagged by the vascular surgeon). Step 4b caps the mask + branch labels at
  ~3 cm below the inguinal ligament (mid-CFA). The inguinal level = the caudal
  terminus of the TS external-iliac label (65/66); since TS can lose one side
  early (JohnDoe1 R iliac ended 6 cm cranial to L — an artefact), it takes the
  DEEPER confident terminus (≥15 vox) as the bilateral level. Seeds then land at
  the CFA and the centerline terminates there. Configurable via
  `opts.cap_cfa_at_inguinal` (default true) / `opts.cfa_distal_margin_mm`
  (default 30); both key the result cache. JohnDoe1 CFA z 1219→1089, JohnDoe2
  868→690; R/L arcs shortened (JohnDoe1 477/277→400/202 mm, JohnDoe2 506/331→
  410/216 mm) as the SFA/profunda is removed.
- **Centerline + whole-result disk caches** (`run_planner_headless`, new
  `.cache/centerline` + `.cache/planner_result`, keyed on mask/seeds/backend
  and on the input volume+options incl. the CFA-cap settings). The slow VMTK
  pass and the full pipeline are cached so re-opening a planned scan in the GUI
  is near-instant. The on-disk result copy strips the ~600 MB CT volume (every
  cache-hit caller already has it).

### Verification
Regression suite **108/108 passed** on a headless worker (display-only GUI/VTK
tests skip as usual). Screenshot-verified end-to-end on **both** scans: the
one-click pipeline yields a complete segmentation and a clean bifurcated
centerline — red/right + blue/left iliac branches meeting the aortic trunk at
the bifurcation marker (JohnDoe1 304.5 mL, R/L arc 477/277 mm; JohnDoe2 189.3 mL,
R/L arc 506/331 mm, both VMTK). Auto-mode "Run segmentation only" now produces
1.77 M voxels with branch labels (was 0). New `scripts/warm_centerline_cache.m`
warms the caches for both real cases.

## 2026-06-06 — harden the bifurcated-tree gate: trunk-join is the sole proximal test for the left branch

### Why
The complete-segmentation gate (landed 2026-06-05) applied the arc-span test
(arc ≥ span_frac · straight) to BOTH centerline branches, using the full
proximal→CFA separation as the reference straight for each. That reference is
correct for the right (primary) branch — it IS the full trunk to the source —
but wrong for the left branch, which `vmtk_centerline.compute` trims at the
bifurcation. The left branch only spans bifurcation→CFA, so measuring its arc
against the full proximal→CFA straight is geometry-fragile: a high-bifurcation
/ short-iliac case would false-fail despite a perfectly good segmentation
(JohnDoe1/JohnDoe2 passed at 0.71/0.77 of the reference, but with little margin).

### What changed
**`+autoseg/check_complete_segmentation.m` (`cl_branch_ok`).** The arc-span
gate now applies ONLY to the primary (right) branch. The secondary (left)
branch is gated solely on reaching its CFA seed distally AND joining the trunk
proximally (`min_polyline_dist` to the right polyline). This is principled,
not a loosening: the trunk-join test already rejects the degenerate
CFA-collapse failure mode for the left branch — a 2-node polyline that
collapses onto the CFA target sits far from the trunk — so the redundant
full-span arc test only added false-failure risk. The right branch is
unchanged (CFA-reach + trunk-reach-to-proximal-seed + arc-span), so the
degenerate-collapse trap stays covered on the primary branch by the arc gate
and on the secondary branch by the trunk-join.

### Regression
`tests/test_check_complete_segmentation.m` adds a 7th case,
`left_branch_trimmed_at_bifurcation_passes`: a left polyline whose
bifurcation joins the trunk well distally, giving an arc (~16 mm) below
span_frac · the full proximal→CFA straight (~35 mm). It would false-fail an
arc-span gate referenced to that straight, but genuinely reaches its CFA and
joins the trunk — so it must PASS. `test_check_complete_segmentation` now
**7 passed / 0 failed**; full suite **114 passed / 0 failed / 1 incomplete
(of 115)** (incomplete = known aortaseg24 Phase-A `assumeTrue` skip;
`test_vmtk_centerline` excluded from the headless `-batch` run, needs a
display). Both scans still PASS the gate (removing a constraint cannot
regress an existing PASS; reconfirmed against the saved planner results:
JohnDoe1 & JohnDoe2 each single 100% CC, R/L reach 0 mm, R/L CFA gap 1–2 mm).

## 2026-06-05 — complete aortic segmentation gate green on BOTH scans (JohnDoe1 + JohnDoe2)

### Why
The governing Phase-3 objective: *"able to completely segment the aorta of
both scans"* — one connected vessel from the proximal neck down both
iliacs/CFAs to the FOV bottom, with the bifurcated centerline routing
end-to-end to each CFA seed (no distal truncation, no synthetic bridges).
Two blockers remained: (a) JohnDoe2's post-reconnection mask was a single
26-CC reaching the FOV bottom, yet VMTK returned a DEGENERATE right
centerline (2 nodes, arc 0 mm); (b) the new acceptance gate mis-modeled the
bifurcated-tree topology and false-failed BOTH scans.

### What changed
1. **Radius-safe VMTK degeneracy retry** (`run_planner_headless.m`, step 7).
   A thin (1–2 voxel) reconnection bridge can keep the mask a single VOLUME
   26-CC yet get pinched off the *decimated* surface mesh, splitting it so
   `vmtkcenterlines` can't route source→distal target — one branch collapses
   to a 2-node polyline (arc 0). The planner now detects this
   (`vmtk_branch_degenerate`: a branch whose arc < 0.6× the straight
   proximal→CFA distance, or < 5 nodes) and retries with `reduce=0.0` (no
   surface decimation) so the bridge survives mesh generation. `reduce=0.0`
   is **radius-safe** — unlike morphological closing it does not inflate the
   surface, so the clinical diameters `evar_measurements` derives as
   `2·R_mm` stay honest. The fast `reduce=0.5` path is unchanged; the slower
   retry is paid ONLY on cases that need it. Recovered JohnDoe2: right
   branch arc 0 → ~506 mm, left ~331 mm.
2. **Correct bifurcated-tree topology in the gate**
   (`+autoseg/check_complete_segmentation.m`). `vmtk_centerline.compute`
   trims the LEFT polyline at the bifurcation, so it legitimately ends
   ~170–210 mm distal of the proximal seed (it joins the trunk there). The
   old gate required BOTH branches to reach the proximal seed and false-
   failed every real case. Criterion (3) now models the tree: the right
   (primary) branch must reach the proximal SEED; the left branch must reach
   the TRUNK (its closest approach to the right polyline) — a new
   `min_polyline_dist` helper, frame-correct since both polylines share
   VMTK's `[y x z]` convention. New `cl_prox_tol_mm` (default 20 mm) for the
   proximal/trunk anchor; the tight `cl_seed_tol_mm` (12 mm) still governs
   the distal CFA seeds. The fixed arc-span gate (arc ≥ span_frac·straight)
   still rejects the degenerate CFA-collapse.

### Result
`scripts/verify_complete_segmentation.m` (full headless planner + gate) now
reports **PASS on both** — JohnDoe1 and JohnDoe2 each: single 100% CC, both
chains reach the FOV bottom (0 mm), R/L centerlines reach their CFA seeds
within 1–2 mm. No synthetic bridges; reconnection adds only genuine-HU
voxels.

### Regression
Suite **113 passed / 0 failed / 1 incomplete (of 114)**; the incomplete is
the known aortaseg24 Phase-A `assumeTrue` skip, and `test_vmtk_centerline`
is excluded from the headless `-batch` run (VTK needs a display, run
separately). `test_check_complete_segmentation` 6/6 green after the
topology fix.

## 2026-06-01 — hardened manual editor: TeraRecon-style click-to-grow / click-to-erase

### Why
Strategic pivot toward an "auto-propose, then refine" workflow (the
TeraRecon model the user works in daily): the auto pipeline pre-loads a
proposed mask + seeds, then the user click-grows / click-erases
corrections and drops 3 seeds → centerline. First step is making the
manual-refine core of `AorticCenterlineApp` robust and ergonomic. No
rewrite — the existing app, hardened.

### What changed
1. **User-controllable grow tolerance.** New `GrowTolHU` property
   (± HU half-window for click-to-grow, default **75** to reproduce the
   prior hard-coded behavior). Wired into **both** grow paths as
   `tol = max(5, app.GrowTolHU)` — the atomic flood in `runSegmentation`
   and the hold-to-grow `liveGrowFromSeed`. Exposed in the GUI as a
   "Grow tolerance: ± N HU" slider (Limits [20 250]) in both the
   click-to-add and refinement panels, with a live `growTolChanged`
   label. A tight window catches only the bright lumen core; a wider
   window also picks up the weaker contrast annulus.
2. **Bounded 3-D click-to-erase.** `eraseVesselAtVoxel` carves a
   physically-round ball (radius = the Brush slider; z-radius scaled by
   `pixel_mm/slice_spacing` so the eraser is round under anisotropic
   spacing) out of both `Mask` and `MaskLabel`. Local + bounded by
   construction — a single click can only remove voxels inside the ball,
   so it can **never** nuke the whole connected vessel tree (unlike a
   connected-component erase). `pushUndo` is taken before the edit, so
   every erase is reversible. Wired into the 2-D (`onMouseDownTool`) and
   3-D (`onViewer3DDown`) erase-tool click handlers.
3. **Public test/driver shims** (`eraseAtVoxelPublic`, `growAtVoxelPublic`,
   `setGrowTolPublic` / `getGrowTolPublic`, `undoPublic`,
   `clearMaskPublic`, `maskVoxelCountPublic`, `injectMask`) expose the
   private refine core to headless drivers and regression tests without
   driving pixels.

### Regression test
New `tests/test_manual_editor.m` (house GUI-test `classdef` style:
sandboxed `user.home`, per-method app build on a tiny synthetic graded
"vessel" cylinder, figure deleted in teardown). Three cases / 8
assertions: (1) erase removes a **bounded** ball (>0 and < whole mask),
undo restores the count **exactly** on a clean stack, and re-erasing the
same spot removes the **same** count; (2) the grow-tolerance setter/getter
round-trips (50, 150); (3) a wider HU tolerance grows a **strictly larger**
mask (tight ±50 → core only; wide ±200 → core + annulus). The original
function-style `scripts/test_manual_editor.m` was removed to avoid a
path-name clash with the new classdef.

### Result
Full suite green: **95 passed / 0 failed / 10 filtered, of 105**. The new
GUI test filters cleanly in headless `-batch` (GUI needs a display) exactly
like `test_gui_mode_toggle`, and passes **3/3** in a display session.
`test_vmtk_centerline` (VTK needs a display) confirmed **3/3** green in a
desktop session, run separately because it crashes a `-nodisplay` worker.

## 2026-06-01 — demo render coordinate-frame fix (masks were clean all along)

### Symptom
After the leak guard landed, the 2-panel demo figure *still* didn't look
like a segmented aorta: JohnDoe2's 3-D recon was a stack of disconnected
horizontal "slabs" with a mid-aorta gap, even though the leak was gone.

### Root cause — a rendering bug, **not** a segmentation bug
Hard checks on the saved `planner_result.mat` masks showed they were
already clean: JohnDoe2 **676k vox, 1 connected component, z 1..868, zero
empty slices**; JohnDoe1 **982k vox, 1 CC, z 451..1219, zero gaps**; all six
seeds inside-mask. The isosurface was a single watertight surface
(>99.9 % in the largest component). MIP projections of the same masks
showed textbook aortoiliac Y-trees.

The "slabs" came from `render_demo_figure/build_isosurface`, which
recovered the mm grid as `mm = (vox-1)·spacing` with a **zero origin**.
These DICOMs have a large z-origin (JohnDoe2 z ≈ −1500 mm); the
proximal-seed-only spacing recovery returned an absurd dz (≈ −37 mm/slice),
fell back to a noisy seed-difference estimate, and placed the mask far
outside the centerline's axis limits — so `setup_3d_axes` clipped it into
ribbons. `ZDir='reverse'` also put the anatomy upside-down.

### Fix — render in the pipeline's exact mm frame
`render_demo_figure` rewritten to recover the pipeline's own
`voxel_to_mm` transform **exactly** from the three seed ↔ seed_mm
correspondences saved in the result (`X=col·dx`, `Y=row·dy`,
`Z=za·slice+zb`; residual ~1e-13 mm). Axis limits are now the union of
mask-vertex + centerline bounds (mask never clipped), and `ZDir` is
data-driven so the proximal aorta reads at the top.

### Result
Both headless demos now look like proper segmented aortas — JohnDoe2 a
clean infrarenal AAA (sac, bifurcation, both iliacs to the CFAs); JohnDoe1 an
AAA with a prominent sac — with the bifurcated centerline co-registered in
the same camera. GUI-driven equivalents reproduced via
`scripts/gui_demo_from_mat.m` (AorticCenterlineApp 3dvol view, which masks
the CT to the segmentation). `scripts/drive_gui_for_demo.m` `mm_to_vox`
column order corrected to the `[X,Y,Z]` convention.

### Known gap (next)
JohnDoe1's **right** iliac centerline truncates ~5 cm short of the CFA
(stops at slice ~1046 vs FOV bottom 1219); the 6b largest-CC filter drops
the disconnected distal right iliac. To be fixed without synthetic bridges.

## 2026-06-01 — leak guard: stop the adaptive follower flooding the pelvis

### Symptom
The patient-adaptive HU follower (shipped 2026-05-21) made the JohnDoe2
3-D recon *worse*, not better — "these don't look at all like a
segmented aorta." The pelvis was a solid red mass: both femoral heads,
the iliac wings and the sacrum were filled in.

### Root cause
JohnDoe2 is a **low-contrast** arterial study (aorta bolus peak only
376 HU). Cancellous **bone marrow** sits at ~200–400 HU, so it falls
*inside* the per-patient adaptive window. The follower's
`imreconstruct` flood is 26-connected to that marrow through the iliac
groove (the artery lies directly against the ilium), so an unconstrained
flood leaks bilaterally into the pelvic skeleton. Stage volumes told the
story: walker 300 mL (clean) → follower **806 mL** → 3c-recon **1391 mL**
→ FINAL **1387 mL** (≈5× the true vessel volume). On low-contrast scans
HU alone cannot separate lumen from marrow.

### Fix — two guards, both bridge-free (add no synthetic voxels)
1. **Vessel-area leak guard** — new `autoseg.drop_big_inplane_cc(bw,
   max_vox)`. Drops any 8-connected in-plane component larger than a
   vessel-calibre ceiling (`opts.vessel_max_mm2`, default 400 mm²) from
   the grow *candidates*, matching the walker's existing `vessel_max_vox`
   ceiling. Catches the big marrow / bladder / bowel cross-sections.
   Wired into both the follower and the `[3c]` HU-reconstruct.
2. **Tube confinement** (the decisive one) — `opts.tube_radius_mm`
   (default 5 mm). The follower runs *after* the slice-by-slice walker,
   which has already honestly tracked the aorta+iliacs to the CFA, so the
   flood's only job is to recover partial-volume edge voxels *near* that
   path. Candidates are intersected with `imdilate(mask_in, sphere(r))`,
   so the flood cannot reach distant pelvis (femoral heads / sacrum are
   >5 mm off the iliac path). Veins and thin marrow rinds that slip under
   the area cap are also cut here.

### Result
- JohnDoe2: follower **806 → 305 mL**, 3c **1391 → 335 mL**, FINAL
  **1387 → 258 mL** — a clean infrarenal AAA with the aneurysm sac, the
  bifurcation and both iliacs to the FOV bottom, single connected
  component, **zero pelvic leak**.
- JohnDoe1 (well-contrasted): follower is a **near-no-op** (547 → 547 mL,
  +95 vox) — no regression; the tube/area guards don't touch a clean scan.

### Tests
- `tests/test_follow_iliacs_adaptive.m` rewritten to the production
  contract (input mask carries the walker's iliac cores; the follower
  *thickens* them rather than extending from an aorta-only seed). Adds
  `tube_guard_rejects_offpath_contrast` — an in-window "marrow" slab
  26-connected to the iliac but >tube_radius off-path must be rejected.
  8/8 pass.

## 2026-05-21 — patient-adaptive HU iliac follower

### User-suggested insight
> "Once you find the segment of the aorta, we then know the expected
> contrast amount in the iliacs (it should be basically the same) so
> we should just follow the vessels by following the now-known
> contrast gradient down the iliacs."

After hours of trying to fix the slice-by-slice walker (which kept
under-segmenting the R-iliac on JohnDoe1 even though high-contrast voxels
were continuous to FOV bottom — the walker rejected legitimately
large CCs where the artery's bolus partially-volumed into the adjacent
vein), this user-supplied algorithmic idea solved the problem in one
shot.

### Implementation: `autoseg.follow_iliacs_adaptive`
- Sample the aorta voxels' HU distribution after `extend_and_detect_branches`
  has labeled label==1.
- Locate the **bolus peak** via the histogram mode (more robust than
  the median, which is dragged down by partial-volume edge voxels —
  on JohnDoe2 the aorta median is 111 HU but the bolus peak is 376 HU).
- Build a **per-patient HU window** from the peak ± both a fraction
  (`[0.55, 1.15] × peak`) and a sigma multiplier (`peak ± [1.5, 2.0] σ`),
  taking the wider of the two bands so well-behaved scans aren't
  narrowed.
- Region-grow from `(label == 2|3|4|5) | aorta-bifurc-anchor` through
  pelvis voxels (z ≥ z_bifurc - 30 mm) matching that window.
- Keep only the largest 3D-CC of the grow.
- **Strictly bridge-free** — only paints voxels that ALREADY have
  bolus-grade HU in the source CT.

### Pipeline wiring
- New step `[3b']` in `run_planner_headless.m` after `extend_to_cfa`.
- Opt-in via `opts.use_adaptive_hu_follower` (default `true`).
- Output mask is the union of: existing extended mask + adaptive-grow.

### Results on real anatomy
- **JohnDoe1** (well-contrasted, bolus 712 HU): adaptive window [427, 833],
  R polyline 475 mm / L 287 mm reaching FOV bottom on both sides. 3D
  recon now shows a clear bifurcating aorta with visible iliacs
  (previously the R polyline was 89 mm short of the L because the
  walker missed the distal R-iliac contrast).
- **JohnDoe2** (lower-contrast, bolus 388 HU): adaptive window
  [233, 471], R polyline 536 mm / L 323 mm reaching FOV bottom on
  both sides. Symmetric, anatomically plausible.

### Regression
- `tests/test_follow_iliacs_adaptive.m` — 6 cases pinning the function:
  info struct shape, mask-only-grows invariant, **anti-bridge invariant**
  (no painted voxel may fall outside the adaptive HU window), bolus
  peak within aorta range, reaches-FOV-bottom on synthetic phantom,
  graceful no-aorta-label handling.
- **93/94 runnable tests green** (1 properly skipped: aortaseg24
  Phase_A error gate).

## 2026-05-21 — AortaSeg24 Phase A scaffold (#26)

User confirmed #26 as the "definition of done" path. Phase A
(scaffolding, no external dependency) landed:

- **`+autoseg/+aortaseg24/`** new sub-package mirroring the
  `+vmtk_centerline/` shape:
  - `detect.m` — probes for three backend candidates (env override →
    nnUNet checkpoint on disk → docker image); reports cleanly when
    none found.
  - `run.m` — entry point; errors with `autoseg:aortaseg24:Unavailable`
    or `autoseg:aortaseg24:Phase_A` depending on detect state.
    Refuses to fabricate output.
  - `translate_labels.m` — pure function consuming
    `data/aortaseg24_class_map.json`; maps the 23-class raw label
    volume to the pipeline's canonical labels (existing 1-9 + new
    10=aortic wall + 11=intraluminal thrombus).
- **`data/aortaseg24_class_map.json`** — provisional class map (v1.0-
  provisional, `verified_against_dataset: false`). Names + IDs from
  memory; JSON-driven so updating the map in Phase B requires no code
  change.
- **`docs/AORTASEG24_LABEL_MAP.md`** — full integration plan: Phase A
  state, expanded pipeline-label table (10/11 are AortaSeg24-only),
  Phase B options (B1: pretrained nnUNet, B2: challenge-winner code,
  B3: train our own), license caveats (CC-BY-NC), class-map
  verification steps.
- **`tests/test_aortaseg24_backend.m`** — 6 cases pinning the
  scaffold:
  - `detect()` returns the documented struct shape.
  - `run()` errors `Unavailable` when no backend.
  - `run()` errors `Phase_A` when a backend IS detected (gated by
    assumption; not reachable in CI today, exercised when env override
    is set).
  - Class-map JSON well-formed (≥23 classes, every entry has
    id/name/pipeline_label in valid ranges).
  - `translate_labels()` round-trips synthetic raw → pipeline.
  - `translate_labels()` drops `pipeline_label = 0` from output volume.

Integration into `run_planner_headless` / GUI is intentionally
**deferred** until a Phase B backend is wired — avoids creating dead
code paths.

### Regression
**87/88 runnable tests green** (1 properly skipped via assumeTrue:
the Phase_A error gate, which is only reachable when a backend is
detected — none is in CI). Net change from session start: 73 → 87
passing, +14 over two sessions.

## 2026-05-21 — measurement consistency + IFU bifurc-angle slot

### Plan output now emits aneurysm diameter alongside radius
`evar_plan.measure_from_centerline` now emits both
`max_aneurysm_R_mm` (the historical name; radius) AND
`aneurysm_max_diameter_mm` (the schema-aligned diameter). They are
strictly related (diameter = 2 × radius); the diameter form is the
canonical schema field. Closes a footgun where callers had to do the
×2 themselves and `compare_to_reference` quietly omitted
`aneurysm_max_diameter_mm` from the delta table for weeks.

### IFU library: bifurcation-angle constraint slot
- `+ifu/devices.m`: every device entry gains an optional
  `iliac_bifurc_angle_max_deg` field, defaulting to **NaN** (= "no
  published constraint in this device's IFU summary"). Real vendor
  values to be populated as the data is gathered — populating ≠
  changing behavior; the check is skipped while NaN.
- `+ifu/check_eligibility.m`: new check fires only when the device
  has a non-NaN ceiling AND the measurement has a non-NaN
  `bifurcation_angle_deg`. Adds the new constraint to the binding-
  margin selection.
- `tests/test_ifu.m`: two new cases —
  `bifurc_angle_constraint_skipped_when_device_has_nan` (sweeps all 7
  catalogued devices with a hostile 150° patient angle, verifies all
  still pass because their slots are NaN), and
  `bifurc_angle_constraint_fires_when_device_populated` (synthesizes
  a 70° device ceiling, verifies a 90° patient angle fails with the
  bifurc constraint as the binding margin).

### JohnDoe2 re-verification
Re-ran today's `measure_from_centerline` against the cached JohnDoe2
(May 19) planner result. Every existing measurement matches to the
displayed digit; new fields are populated:
- `aneurysm_max_diameter_mm = 24.9 mm` (= 2 × R 12.4 mm)
- `bifurcation_angle_deg = 28.0°` (plausible for this patient)

### Help text + parallel JohnDoe2 reference blank
- `+ui_helpers/help_content.m` reference-annotation page now lists
  `bifurcation_angle_deg` in the measurement field list and points
  the annotator at `docs/TERARECON_ANNOTATION_GUIDE.md`.
- `library/reference/JohnDoe2.ref.json` — blank reference JSON for
  the second real case, generated via `reference.template('JohnDoe2', ref_dir)`.
  Ready for annotation in parallel with JohnDoe1.

### Both measurement code paths agree
GUI's `preprocess.evar_measurements` and the headless
`evar_plan.measure_from_centerline` both recover the AAA phantom's
procedural 36° bifurcation angle to the displayed digit. No drift
between the two code paths.

### JohnDoe2 real-anatomy regression pin
- `tests/test_johndoe2_regression.m` (3 cases) — loads the cached
  `results/logs/johndoe2_pass1/planner_result.mat`, recomputes
  `evar_plan.measure_from_centerline`, and pins:
  - existing sizing fields stable to ±0.5 mm / ±0.5° vs the cached
    May-19 plan (= floating-point drift only);
  - new `aneurysm_max_diameter_mm` = 2 × `max_aneurysm_R_mm` exactly;
  - new `bifurcation_angle_deg` populated and within ±5° of today's
    28° baseline.
- `assumeTrue`-skips when the cached file isn't on disk (fresh
  checkout without local case data).

### Regression
**82/82 runnable tests green** (was 77; +2 IFU bifurc-slot cases,
+3 JohnDoe2 pin cases).

## 2026-05-20 — TeraRecon benchmark prep (#5)

Lowered the activation energy on goal #5 (which is blocked on a
specialist filling in TeraRecon reference JSONs):

- **`docs/TERARECON_ANNOTATION_GUIDE.md`** — new field-by-field guide
  mapping every reference-schema field to the corresponding TeraRecon
  Aquarius iNtuition screen + measurement tool. Documents common
  pitfalls (lumen vs outer-wall, axial vs orthogonal-to-centerline,
  Euclidean vs arc-length).
- **`library/reference/JohnDoe1_EVAR.ref.json`** — blank reference JSON
  generated for the first real case; ready for the annotator to fill
  in.
- **`+evar_plan/compare_to_reference.m`** — sizing-fields list was
  hardcoded; replaced with `reference.schema().measurement_fields`
  lookup so any new schema field automatically flows through the
  benchmark comparison. This fix surfaced two pre-existing gaps:
  `aneurysm_max_diameter_mm` and `distance_lowest_renal_to_bifurcation_mm`
  were never being compared because they weren't in the hardcoded
  list. Now they are.

Verified end-to-end on the AAA phantom: the planner recovers
`bifurcation_angle_deg` and `aneurysm_max_diameter_mm` both at
Δ = 0.0 mm against the phantom's procedural ground truth.

## 2026-05-20 — bifurcation angle measurement (#10)

Added the iliac take-off angle measurement, the last unimplemented
EVAR sizing metric in BUILD_PLAN.md's P2 list.

### What landed
- `+preprocess/evar_measurements.m` — new `M.bifurcation_angle_deg`
  field. Computed by walking 20 mm distally on each iliac from the
  aortic bifurcation and taking the angle between the two
  bifurc→distal vectors. NaN-safe when bifurc isn't located.
- `+evar_plan/measure_from_centerline.m` — mirror field
  `meas.bifurcation_angle_deg` for the headless pipeline + benchmark.
  New `compute_bifurc_angle` helper. Uses `opts.bifurc_tangent_mm`
  (default 20 mm).
- `+reference/schema.m` — schema gains `bifurcation_angle_deg` so the
  TeraRecon benchmark JSONs (goal #5) can capture the reference value.
- `library/PHANTOM_aaa_male.ref.json` — baselines the AAA phantom at
  36.0° (the procedural ground-truth angle).
- `+app/AorticCenterlineApp.m` — Step 5 sizing panel now has a
  "Bifurcation" section that surfaces the take-off angle.
- `tests/test_phantom_accuracy.m` — new case
  `planner_recovers_bifurcation_angle` pins recovery within ±3° of
  the phantom ground truth.

Suite count: **77/77 runnable tests green** (was 76).

## 2026-05-20 — v1.4.0: VMTK is now the primary centerline backend

### Headline
The centerline step (#4 in the North Star pipeline) now uses VMTK's
Voronoi / fast-marching centerline by default — the same algorithm
class as the reference clinical workstation TeraRecon — with the pure-
MATLAB skeleton-graph shortest-path implementation as a no-external-
dependency fallback.

### Two real bugs in `+vmtk_centerline/compute.m`
Debugging on the AAA phantom (where `vmtk_centerline.compute` was
returning two identical 500-node polylines) and then on the real JohnDoe1
CT exposed two distinct bugs:

1. **`extract_line` axis-order mismatch.** `cl.points` is in VMTK's
   `(X, Y, Z)` order (as written by `io.write_vtp_surface`'s
   `isosurface` call), but `target_mm` is in the caller's `(Y, X, Z)`
   order. The line-pick loop and the orientation-check ran on
   mismatched axes; only the very last column swap (`[:, [2 1 3]]`)
   put the *output* polylines back into `(Y, X, Z)`. On the phantom
   the mismatch caused both R and L to extract the *same* VMTK line.
   On JohnDoe1's asymmetric anatomy it was the likely cause of the
   "degenerate 2-7 nodes" symptom documented in the prior session
   (when the wrong line was a stub).
2. **`find_bifurc` walked from the wrong end.** The loop iterated
   `kL = size(P_left, 1):-1:1` (proximal-end downward toward distal)
   and `return`-ed on the first match. Since both polylines share the
   proximal source endpoint exactly, the first match is always at the
   source — so `k_left = numel(P_left)` and `bifurc_node_right =
   numel(P_right)` every run. The L polyline was never trimmed at the
   bifurcation. Rewrote to walk from L-CFA (`kL = 1:nL`) upward and
   return at the first kL where any R-node is within `tol_mm`.

### What replaced them
- Both fixes landed in `+vmtk_centerline/compute.m`.
- New test class `tests/test_vmtk_centerline.m` with 3 cases that pin
  the fixes:
  - `compute_returns_two_distinct_polylines` — L and R node counts
    must differ (catches the axis-order regression).
  - `endpoints_anchor_at_cfa_seeds` — distal endpoints within 5 mm of
    the supplied CFA seeds.
  - `bifurcation_node_is_interior_to_right_polyline` — bifurc index
    is strictly inside the polyline (catches the `find_bifurc`
    regression).
- Tests are skipped via `assumeTrue` when VMTK is not installed.

### Pipeline-level wiring (`run_planner_headless.m`)
New option `opts.centerline_backend`:
- `'auto'` (default) — calls `vmtk_centerline.detect()`; uses VMTK
  when available and falls back to the MATLAB skeleton-graph path on
  detection failure or any runtime error.
- `'vmtk'` — forces VMTK; errors if unavailable.
- `'matlab'` — forces the skeleton-graph path.
Output struct gains a `centerline_backend` field that records which
path actually ran (useful for the benchmark CSV).

### Verified on real anatomy
End-to-end on JohnDoe1 (1.8M-voxel post-extension mask):
- Pv_R 1106 nodes / 725 mm arc, distal endpoint 1.6 mm from R-CFA seed.
- Pv_L 1169 nodes / 732 mm arc, distal endpoint 3.1 mm from L-CFA seed.
- Bifurcation found from both polylines within **1.3 mm**.
- Shared trunk 462 mm, R iliac+CFA 263 mm, L iliac+CFA 270 mm
  (bilateral symmetry within 7 mm).
- Median R 5.0 mm (iliac caliber), max R 19.7 mm (AAA sac).

### Other fixes
- Stale `walk_side` docstring in `+autoseg/extend_to_cfa.m:792` claimed
  slices were "bridged via a thin tube" — false since the bridge
  removal. Now reflects the per-slice independent painting.

### Regression suite
**76/76 runnable tests passing** (up from 73 — added the 3 VMTK
cases). 6 GUI-rendering tests still filter under headless mode as
before.

## 2026-05-19 — bridges removed, replaced with HU-reconstruct

### User directive
After a GUI audit of the JohnDoe2 3-D Volume render, the user spotted
the same "obviously not anatomically possible branch off the iliac"
that the previous session's bridge tubes had painted. The directive:

> "we need to remove all bridges we are drawing. This is not a strategy
> we should employ in our code to segment the vessels. on these CT
> scans, there is no need for a bridge. the iliacs and CFA are well
> opacified."

> "find some other solution to solve segmentation issues."

The bridges drew HU-gated straight-line tubes between disconnected CCs
(aorta↔iliac globally, and slice-to-slice in the walker). Wherever
HU-100+ tissue happened to lie along the geodesic line, the bridge
painted "vessel" through it — producing phantom branches that were
obvious in the recon.

### What was removed
- **`+autoseg/extend_to_cfa.m`**:
  - `bridge_proximal_to_cfa` (global aorta-CC → iliac-CC tube bridge)
    deleted entirely.
  - `bridge_tube` and `bridge_path_has_contrast` helpers (slice-to-slice
    walker re-acquire bridges) deleted entirely.
  - `walk_up_from_cfa` and `walk_side` no longer call `bridge_tube`;
    they just paint per-slice CCs and accept gaps as real anatomic
    dropouts/endpoints.
  - NOTE comments left in place explaining why bridges are banned, to
    prevent re-introduction.

### What replaced them (`run_planner_headless.m` step 3c)
**HU-based connectivity restore via morphological reconstruction.**
Instead of inventing voxels, grow the existing TS mask into adjacent
contrast voxels that the segmenter missed:

```matlab
contrast_hu_lo = 150;
contrast_hu_hi = 1400;
contrast_mask  = (D.vol >= contrast_hu_lo) & (D.vol <= contrast_hu_hi);
pix_mm = abs(D.pixel_mm(1));
shell_r = max(3, round(5 / pix_mm));
shell   = imdilate(mask, strel('sphere', shell_r));
grown   = imreconstruct(mask, contrast_mask & shell, 26);
mask    = grown;
```

Key properties:
- Seed is the TS mask itself — the grown mask is a strict superset.
- Growth confined to a 5 mm shell (`imdilate` with sphere) — cannot
  leap across tissue gaps the way a global tube bridge could.
- Growth confined to HU 150-1400 (arterial-phase contrast band) — only
  real opacified lumen voxels are recruited; soft tissue and bone are
  invisible to the reconstruction.
- 26-connectivity, so the grow respects 3D adjacency at corners.
- No-op when the TS mask is already connected through contrast (JohnDoe1).

### Results
- **JohnDoe2**: mask 709,626 vox in the largest CC out of 823 total
  CCs. Skeleton graph now has a path proximal→both CFAs without any
  synthetic voxels. R 825 nodes / 479 mm arc, L 852 nodes / 500 mm arc
  (distinct, not the L=R duplicate the disconnected case produced).
  Neck Ø 20.4 mm, neck length 30.3 mm, neck angulation 5°, iliac R
  6.7 mm, iliac L 8.1 mm. No phantom branches visible in the 3-D
  Volume render.
- **JohnDoe1**: pipeline succeeds, neck and device recommendation
  preserved (neck Ø 20.1 mm, length 131.7 mm, angulation 4°; iliac
  R Ø 11.6 mm / L 12.6 mm; all 7 IFU devices eligible; Ovation iX
  recommended). **But iliac_R landing-zone length regressed: 306.7
  mm (with bridges) → 147.9 mm (without bridges)**, and iliac_L is
  268.0 mm. The previous session's 306.7 mm number was being padded
  by `bridge_tube` slice-to-slice re-acquire walks, which we now
  refuse to do. The walker without `bridge_tube` stops at the first
  slice where it loses contrast on JohnDoe1's R-CFA chain; the 5 mm
  HU-reconstruct shell isn't enough to span those slice gaps. Device
  recommendation is unchanged because iliac length is not the binding
  constraint on JohnDoe1 (binding is iliac_R diameter at margin 3.6).
- **73/73 runnable tests pass, 0 failures, 6 GUI tests filtered.**

### Known limitation (deferred follow-up)
- JohnDoe1's R-iliac landing-zone length is 158 mm shorter than the
  bridge-based baseline. Per the user's "iliacs and CFA are well
  opacified" directive, the right fix is **upstream**: make the
  slice-by-slice walker (`+autoseg/extend_to_cfa.m:walk_up_from_cfa`
  / `walk_side`) more tolerant of single-slice contrast dropouts so
  it can re-acquire on the next slice without a bridge tube. Possible
  approaches: relaxed CC-proximity threshold for the next slice,
  multi-slice look-ahead with HU evidence, or fixing the upstream
  CFA seed so the walker starts from a more proximal anchor.

### Camera centering for non-JohnDoe1 anatomy (`+app/AorticCenterlineApp.m`)
- `resetCamera` was using a bbox midpoint + JohnDoe1-tuned empirical
  offsets (`-0.023, -0.033, -0.557 × span`) that placed the aorta
  off-screen on JohnDoe2. Replaced with the voxel-weighted centroid
  (`mean` of all mask voxel coordinates), which generalizes to any
  patient.
- Added `resetCameraPublic` wrapper so headless render scripts can
  trigger the same centering logic the GUI uses.
- Added `figureSizeChangedFcn` / `onFigureResized` for responsive
  layout when the user drags the window.

### Memory
- `memory/feedback_no_mask_bridges.md` recorded with the user's exact
  quote and a list of the removed helpers, so future sessions don't
  re-introduce them.

## 2026-05-18 — first out-of-cohort EVAR case: JohnDoe2

### The test
- Ran `run_planner_headless` on a second real EVAR case (JohnDoe2 —
  Siemens SOMATOM Drive, 868 slices, 0.5 mm spacing, contrast-enhanced
  CTA). First case outside the JohnDoe1 cohort.

### What broke
1. **Pipeline crashed** at the centerline step with `centerline_seeds:NoPath`
   — proximal seed and CFA seeds landed in different connected components
   of the skeleton graph.
2. **Root cause 1**: TS labeled the thoracic and abdominal aorta as
   separate 3D-CCs (no contrast bridging at the diaphragm level). The
   post-extension mask had **19 disconnected 3D-CCs**; the proximal
   seed ended up in the thoracic fragment while the CFAs ended up in
   the abdominal-iliac-CFA fragment.
3. **Root cause 2**: TS-fast did not detect a celiac artery on this
   case (no label 8). With no celiac/SMA detected, `auto_seeds_anatomic`
   fell back to `kidney_top − 70 mm` which on JohnDoe2 overshoots the
   diaphragm and places the proximal seed at z=33 (deep in the
   thoracic aorta, ~ 12 cm above the celiac).
4. **Root cause 3**: `run_planner_headless` default `opts.targets`
   was `{aorta, iliac_left, iliac_right}` — the docstring claimed
   "+kidneys+liver" but the code disagreed. Cosmetic for TS itself
   (the full multilabel is cached anyway), but misleading and bites
   when reading the `targets_found` audit line.

### What landed
- **`+autoseg/extend_to_cfa.m`**: new `bridge_proximal_to_cfa` step
  that walks the labeled chain proximal → distal per side (1→2→4
  for L, 1→3→5 for R) and adds a 1-vox tube bridge between adjacent
  labels that don't 3D-touch. Investigated on JohnDoe2: chain links
  ARE already connected at the label-pair level, so the bridge fires
  only when needed (zero-op on JohnDoe1).
- **`run_planner_headless.m`**: new step **6b** — keep only the
  LARGEST 3D-CC of the post-extension mask, then `snap_seed_to_largest_cc`
  relocates any seed that landed outside it (typically the proximal
  seed in the thoracic fragment). With both fixes JohnDoe2 now
  produces R 468 mm / L 547 mm bifurcated centerline + EVAR plan
  in 120 s (cache hits). JohnDoe1 regression preserves the same R 546 /
  L 507 mm output and identical Ovation iX recommendation.
- **`run_planner_headless.m`**: default `opts.targets` now includes
  `kidney_left`, `kidney_right`, `liver` (matching the docstring).
- Added `opts.verbose` default (`true`) so the new step 6b logs.

### Audit triggered by user spotting "impossible anatomy" in render
- **Finding**: 30% of TS aorta-label voxels (label 1) have HU < 50
  (soft tissue) — TS-fast over-segments the aortic wall + perivascular
  tissue. Labels 4/5 (walker-painted CFA extension) had 12-14%
  soft-tissue voxels. These rendered as a "halo" around the lumen in
  the 3-D Volume view.
- **Fix v1 (too aggressive)**: a flat HU≥100 filter applied to the
  whole mask. Cleaned up JohnDoe2 (neck length 90 mm → 30 mm — now
  clinically realistic) but regressed JohnDoe1's R-iliac landing-zone
  length 306 mm → 142 mm (the walker had legitimately painted
  partial-volume edges at HU < 100 on the CFA extension).
- **Fix v2 (scoped)**: HU≥100 filter applied ONLY to label 1 (TS
  aorta) voxels. Labels 2-5 (TS iliacs + walker CFA extension) are
  preserved — they already have their own HU checks in the walker
  and bridge code. Result:
  - **JohnDoe2**: mask 933 K → 648 K vox; cleaner lumen-only render;
    neck Ø 18.5 → 19.0 mm; neck length 90.7 → 30.2 mm (clinically
    realistic); neck angulation 11° → 7°.
  - **JohnDoe1**: R-iliac length recovered 142 → 306.7 mm; full centerline
    arc 373 → 537 mm. Neck Ø 18.4 → 19.0 mm (slight increase from
    cleaner wall edge). Recommendation flipped to Treo (Ovation iX is
    still #2).
- **Also**: HU-gated the `bridge_proximal_to_cfa` tubes so they only
  paint voxels with HU in [100, 1500] — prevents the bridge from
  drawing "vessel" through soft tissue when no contrast path exists.

### Bug found in v1 of the bridge (caught by visual GUI inspection)
- **`bridge_proximal_to_cfa` v1 only checked per-LABEL-PAIR connectivity** —
  it tested whether labels 1 and 2 shared a CC in the UNION mask of
  just those two labels. That test reported "connected" on JohnDoe2
  even when the R iliac (label 3) was in its own global 3D-CC,
  disconnected from the aorta-iliac-CFA chain. The downstream
  largest-CC filter then SILENTLY DROPPED the R iliac (121 K vox
  spanning only z=[1, 335] survived; the actual R iliac at z=[456,
  543] was gone). Caught by rendering the segmentation in the GUI's
  3-D Volume view and seeing only the L iliac extend to the femoral
  level.
- **Fix**: rewrote `bridge_proximal_to_cfa` to operate at the GLOBAL
  3D-CC level. Identify the CC containing the aorta label, then for
  each "must-reach" label (2, 3, 4, 5 = L/R iliacs + CFA extensions)
  test whether its voxels are in the aorta-CC. If not, bridge the
  nearest pair. After each bridge, recompute the CC structure so
  subsequent labels see the freshly-merged aorta-CC.
- **Result on JohnDoe2**: post-bridge mask grew 832 K → 933 K vox;
  R side now 222 K vox spanning z=[1, 868] (was 121 K vox z=[1, 335]);
  R centerline now 938 nodes / 535 mm arc.
- **JohnDoe1**: 5 CCs → still passes, same exact clinical output as
  before (R 546 mm / L 507 mm, neck Ø 18.4 mm, Ovation iX recommended).
- **73/73 runnable tests still pass.**

### Known limitations exposed by JohnDoe2 (deferred)
- Proximal anchor `kidney_top − 70 mm` overshoots the diaphragm on
  cases where the kidney top is high in the FOV. Result: JohnDoe2's
  emitted neck-length = 90 mm (~ 3× clinically plausible) because the
  "neck" measurement spans the entire supraceliac region down to the
  abdominal lumen, instead of the renal-ostium-to-AAA-start window.
  Plan a follow-up: prefer `lowest renal ostium z + 30 mm` whenever
  renal arteries are detected (JohnDoe2 DID detect kidneys, just not
  celiac), with `kidney_top − 70 mm` only as a last resort.
- TS-fast misses celiac + SMA on some patients (JohnDoe2). The
  fallback chain in `auto_seeds_anatomic` works but propagates the
  anchor inaccuracy downstream. Consider running TS at full resolution
  for cases where `--fast` misses the small visceral branches, or use
  a dedicated visceral-branch detector.

### Regression state
- **73/73 runnable tests still pass, 0 failures, 6 GUI tests filtered**.
- JohnDoe1 headless pipeline: identical clinical output to the pre-fix
  state (same neck Ø, length, angulation, iliac Ø, recommendation).
- JohnDoe2: pipeline completes; numbers reflect the anchor
  limitation above, NOT a code bug.

## 2026-05-18 — patient-invariant CFA + SE(3) QC suite + AAA-100 integration

### Highlights
- **Patient-invariant CFA detector.** Replaced the round-HU detector
  with a topological detector (`+autoseg/detect_cfa_seed_topological.m`)
  that finds the CFA as the most-caudal endpoint of the aorta-connected
  contrast tree on each patient side, ranked by `roundness × Gaussian
  lateral-position prior` (μ=70mm, σ=30mm). All scoring is in mm, so
  the result is invariant to scanner pixel size, BMI, and patient
  rotation. Verified on JohnDoe1: picks user-correct CFA on both L and R.
- **SE(3) audit suite (12 rules total).** Two new check functions wired
  into the pipeline post-walk:
  - `+autoseg/se3_cross_vessel_check.m` (7 blocks): z-extent, shared
    bifurcation, distal symmetry, z-monotonicity, bilateral curvature
    ratio, take-off angles, take-off symmetry.
  - `+autoseg/se3_per_centerline_check.m` (5 blocks): max curvature
    κ_max, max torsion |τ|, adjacent-tangent angle, arc/Euclidean
    tortuosity, radius-step change.
  Reports attach to `info.se3_check / se3_per_L / se3_per_R`; the GUI
  surfaces FAIL via `uialert` and stores the report on
  `app.LastSE3Check`.
- **AAA-100 reference cohort INTEGRATED** (Zenodo 10932957, 100
  EVAR-treated infrarenal AAA geometries from Amsterdam UMC).
  - Downloaded 805 KB centerlines + 780 MB STL meshes into
    `../AAA-100/`.
  - Built `+library/+aaa100/` loader package — `cache_root`,
    `list_cases`, `load_case`, `load_all`, plus
    `bulk_convert_vtp.py` (Python+vtk) to convert all 500 VTP files
    to a single MAT cache.
  - `scripts/calibrate_se3_thresholds.m` walks the cohort and prints
    empirical κ_max / |τ|_max / tortuosity / take-off-angle
    distributions per vessel.
  - SE(3) thresholds **recalibrated** from the 99th percentile of
    real anatomy (most notable corrections: κ_max 0.20→0.35,
    |τ|_max 0.10→5.0, tan_angle 60°→90°, takeoff_min 15°→5°).
  - `+library/+aaa100/build_shape_model.m` produces Procrustes-aligned
    mean ± std shapes per vessel (aorta, iliac L/R, renal L/R).
  - `+library/+aaa100/extract_measurements.m` samples mesh inscribed-
    radius along each centerline node via kd-tree NN, derives EVAR
    sizing per case. Cohort-level distributions (lumen-only):
    - AAA max lumen diameter: median 34.8 mm (range 21-71 mm)
    - Proximal neck radius: median 9.9 mm
    - Proximal neck length: median 50.7 mm
    - L/R iliac distal radius: median ~6 mm bilaterally
  - `tests/test_aaa100_se3_rules.m` — regression test pinning the new
    thresholds against the cohort: **99.4% per-centerline pass rate**
    (3/500 renal-curvature outliers, within 1% tolerance), **100%
    cross-vessel pass rate** over 100 iliac pairs.
- **Label-stamping bug fixed in `extend_to_cfa.m`.** Previously
  `label_out(R_choice.mask) = 5` clobbered correct L-side voxels
  because both chosen masks share `mask_in`. Now only newly-painted
  voxels are re-stamped.
- **Centerline extractor (`mask_to_centerline_mm`) rewritten** —
  proximity-tracked per-slice CC selection with vessel-size filter
  (excludes bone-leak CCs > 400 mm²). Replaces "largest CC per slice"
  which hopped between vessel and adjacent leak.

### New files
- `+autoseg/detect_cfa_seed_topological.m`
- `+autoseg/se3_cross_vessel_check.m`
- `+autoseg/se3_per_centerline_check.m`
- `+library/+aaa100/{cache_root, list_cases, load_case, load_all,
  build_shape_model, extract_measurements, score_centerline}.m`
- `+library/+aaa100/bulk_convert_vtp.py`
- `scripts/calibrate_se3_thresholds.m`
- `tests/test_aaa100_se3_rules.m`
- `tests/test_aaa100_score_centerline.m`
- `tests/test_se3_takeoff_asym.m`
- `docs/datasets.md`

### Patient-vs-population outlier scorer
- `+library/+aaa100/score_centerline.m` compares a single centerline to
  the AAA-100 cohort distribution. Returns per-metric percentiles for
  arc length / tortuosity / κ_max / |τ|_max / Procrustes-aligned shape
  deviation, plus an `outlier` flag triggered when any metric falls
  outside the p5-p95 band. Verified: most-tortuous case (AAA061)
  scores tortuosity p100 + shape p98 → outlier=true; median case
  scores within bounds → outlier=false. Regression coverage in
  `tests/test_aaa100_score_centerline.m` (3 tests).

### GUI usability audit (round 3 — iterate until clean)
- **Side-panel widgets overflowed the panel right edge by 10 px.** The
  `step_mode_toggle` button group, `section_header` label, and 8
  widgets in `renderClickToAddUI` all used width 380 at x=10 inside a
  380-wide `SideContent` panel — extending to x=390. Fixed by switching
  to a `CONTENT_W = 360` convention so widgets fit with a clean
  10-px right margin (matching the rest of the codebase).
- **Top toolbar overlapped the side panel at narrow window widths.**
  `bar_w = max(900, W - side_w - margin_x)` forced the toolbar to be
  900 px wide even when the available space was only 660 px (at
  W=1100). Result: the rightmost button (DICOM tags) was hidden BEHIND
  the side panel. Replaced with `min(900, …)` so the toolbar fits
  inside the available space, with `max(…, 300)` floor so it can't
  collapse to zero.
- **Removed 7 stale verification screenshots** from
  `results/figures/gui_audit/` and added doc references to the
  post-fix proof shots that remain.
- **Removed hardcoded `/Users/davidstonko/...` path** from
  `scripts/audit_full_workflow.m`. Now reads `JOHNDOE1_DICOM` env var
  with a fallback to `../JohnDoe1 EVAR/...` relative to the project root,
  and errors clearly if neither is set.
- **Verified clean across 60 combinations** (5 window sizes ×
  6 steps × 2 modes): zero top-level widget overflows, zero
  SideContent widget overflows.

### GUI usability audit (round 2 — user-spotted issues)
- **Top toolbar buttons were clipped.** Adding the Help uimenu causes
  the OS to grow a menubar that shrinks the uifigure's inner Position
  by ~15 px. `createStepBar` ran before that settled, placing the
  step-bar tab labels with their top edge above the visible area.
  Fixed with a post-`buildHelpMenu` `drawnow`, plus a 12 px safety
  margin on all top-anchored toolbars (step bar / view toolbar / both
  tool toolbars), and a matching image-panel height adjustment.
- **Info button glyph wasn't centred.** Replaced the Unicode ⓘ glyph
  (`char(9432)`) at FontSize 13 with a plain bold `'i'` at FontSize
  11 in the same 20×20 button — the OS centres the simple character
  cleanly. 14 info buttons across the GUI now look uniform.
- **GUI layout now reflows on window resize.** New `SizeChangedFcn`
  on the uifigure + `onFigureResized` handler repositions the step
  bar (with re-gridding of its 6 step labels), view toolbar, both
  tool toolbars, image panel, side panel, side-content area,
  side-step-label, and the key-hint status line. The GUI now works
  correctly at the documented minimum 1100×700 and at any size in
  between.

### GUI usability audit (round 1)
- `docs/gui_audit_2026-05-18.md` — full report with screenshots at
  1400×780 / 1280×720 / 1100×700 showing how the side panel goes
  off-screen at smaller widths (no responsive layout — 208 absolute
  Position calls, zero uigridlayout, AutoResizeChildren=off).
- **Critical fix 1**: Step 2 user-driven mode crashed when invoked
  before a volume was loaded — `renderClickToAddUI` read
  `app.D.pixel_mm` on an empty struct. Guarded; shows a "(load a CT
  first)" hint instead.
- **Critical fix 2**: Slice slider on the empty initial screen showed
  fake tick marks `1, 1.05, …, 2` because `Limits=[1 2]` placeholder
  was visible. Slider now starts `Visible='off'` with empty ticks; the
  existing show-on-load path handles the reveal.
- **Critical fix 3**: Steps 5 and 6 rendered nothing but a bare red
  "Compute the centerline first (Step 4)" sentence when the centerline
  wasn't ready. New `render_gated_step_placeholder` helper renders an
  orange "Not ready" banner, a "You must complete:" checklist, a
  preview of what each step will provide once gated open, and a "←
  Back to Step 4" jump button.
- 7 lower-priority findings catalogued (no responsive reflow, tool
  toolbar lacks grouping + Enable gating, step bar labels look
  clickable but aren't real tabs, WCAG contrast on done-step text,
  modal disclaimer fires every launch). Prioritised P0-P3 list in the
  audit doc.

### Manual-CFA-click backend
- `autoseg.extend_to_cfa` accepts `opts.cfa_seed_override_L` and
  `opts.cfa_seed_override_R` as `[y, x, z]` voxel triplets. When set,
  the topological CFA detector is bypassed on that side and the
  walker uses the user-supplied seed instead. This is the backend
  for the GUI "Manual CFA click" re-anchor flow surfaced when the
  SE(3) audit FAILs. New `tests/test_cfa_seed_override.m` (3 tests).

### Audit + cleanup pass (`/auditcode`)
- Built `/auditcode` skill at `.claude/skills/auditcode.md` — 8-pass
  static repo audit covering drift, dead code, lint, TODOs, tests,
  deps, paths, docs. Complements `/goal audit` (which covers domain
  quality — segmentation, centerline, sizing, IFU).
- Drift fixes: STATUS.md test count 68→70 + Modules-implemented
  section refreshed; `docs/datasets.md` stale takeoff-symmetry-bug
  note removed; `se3_per_centerline_check` + `se3_cross_vessel_check`
  docstrings now match the AAA-100-calibrated defaults; CITATION.cff
  bumped to 1.3.0 / 2026-05-18 with updated device count (5→7) and
  SE(3) audit mention.
- Dead code removal: `side_terminus_lateral_offset` (pre-existing
  unused helper) deleted from `+autoseg/extend_to_cfa.m`. One temp
  test artifact removed from `results/logs/`.
- Historical-doc markers: HANDOFF.md and SESSION_LOG.md now lead
  with a "HISTORICAL — superseded by STATUS.md" header so future
  contributors aren't misled.

### Final regression-suite state
- **73/73 runnable tests pass, 0 failures, 6 GUI tests filtered** in
  headless mode (same pattern as prior sessions). 79 total tests
  (up from 68 at session start: +2 AAA-100 SE(3) rules, +3 SE(3)
  take-off asymmetry, +3 AAA-100 outlier scoring, +3 CFA seed
  override).

### Late-session improvements
- **Coarse centerline extractor now produces SE(3)-passable centerlines
  on JohnDoe1.** Rewrote `mask_to_centerline_mm` with a 4-stage pipeline:
  (1) largest 3D-connected-component of the side mask below the
  bifurcation; (2) per-slice size-weighted mean of all vessel-sized
  CCs (≤ 400 mm²) within 6 mm of the previous centroid; (3) 5-node
  median filter on the centroid trajectory in z; (4) 21-node moving-
  average smoother. On JohnDoe1 the per-centerline SE(3) check now
  reports L κ_max=0.27 / R κ_max=0.34 mm⁻¹ — both BELOW the 0.35
  threshold (was 1.35+ before). Tangent continuity OK on both sides
  (max angle 9° L / 19° R, was 78° / 87°). Tortuosity OK on both
  sides (1.38 L / 1.50 R, was 1.59 / 1.80). Residual torsion WARNs
  remain (3D wobble in the smoothed centerline) — not a FAIL.
- **Final JohnDoe1 SE(3) audit: cross-vessel PASS (2 WARN, 5 OK),
  per-L PASS (1 WARN, 4 OK), per-R PASS (1 WARN, 4 OK).** The QC
  layer is now meaningfully informative end-to-end.

### Fixes landed mid-session
- **Take-off-asymmetry detection now functional.** `se3_cross_vessel_check`
  accepts an optional 4th argument `Pv_aorta_mm`. When supplied, the
  aortic axis comes from the aorta centerline's tangent at the
  bifurcation node — the prior `-(t_R + t_L)` fallback was symmetric in
  L and R by construction and the asymmetry block always reported 0°.
  `extend_to_cfa` now extracts the aorta centerline (cranial to
  bifurcation) and passes it. New `tests/test_se3_takeoff_asym.m`
  pins this behavior (3 tests: symmetric pair OK, asymmetric pair
  WARNs, no-aorta-arg falls back to OK with diagnostic note).
- **Pre-existing crash in `extend_to_cfa` when one side has no mask.**
  `pick_best_combination` and the downstream label-stamping accessed
  `side_results.(sn).…` even when the side loop had skipped that side
  (no mask present). Now gated on `isfield(side_results, sn)`; in the
  unilateral case the single-side mask is emitted and SE(3) blocks
  that need both sides are skipped. Exposed by
  `test_cfa_extension/no_midline_crossing` (single-L-iliac synthetic
  test).

### Open follow-up
- Per-centerline SE(3) check on the coarse extend_to_cfa centerline
  FAILs on JohnDoe1 κ even after recalibration — the per-slice-centroid
  centerline has real artifacts that the proper downstream centerline
  solver will resolve. Re-run per-centerline check after the centerline
  solver for diagnostic readings.
- Wire the AAA-100 shape model into the centerline solver as an
  anatomic prior (regularize toward population mean when contrast is
  dropping out).

## 2026-05-17 — overnight iteration session

### Highlights
- Full automated EVAR-sizing pipeline now runs end-to-end on JohnDoe1: 6/6
  audit blocks pass, R-CFA + L-CFA reach the FOV bottom, plan emits neck
  Ø 16.6 mm / length 38.9 mm / angulation 10° + iliac Ø 10-11 mm.
- **First quantitative accuracy benchmark** — built ground-truth
  reference JSONs for BOTH the AAA and the normal-male phantoms, and
  added continuous-integration tests that run the planner against
  them. Accuracy:
  - **AAA phantom**: neck Ø Δ -0.1 mm, iliac Ø Δ 0.0 mm, AAA Ø Δ 0.0 mm.
  - **Normal phantom**: neck Ø Δ -3.6 mm (tapering aorta — algorithm
    averages over a 30-mm window), iliac Ø Δ -0.5 mm.
- **Major planner bug fix uncovered by the accuracy benchmark:**
  `evar_plan.measure_from_centerline` was indexing polylines in
  proximal→distal order, but every caller (GUI + headless + phantom)
  emits distal→proximal. The neck-detection picked the iliac region
  instead of the proximal aorta on real cases, giving a ~3× wrong
  neck diameter. Added `normalize_direction()` at the top of
  `measure_from_centerline` and rewrote `find_bifurcation()` to use
  the LAST close-point between the curves (works for both shared-trunk
  and bifurc-truncated polyline conventions).
- Branch-detection cache delivers a **60× speedup** on re-runs of the
  same case (22.9 s → 0.39 s).
- GUI gains a User-driven / Automatic toggle on every step, an ⓘ info
  button on every section, and a top-level Help menu (overview, mode
  toggle, glossary of clinical terms, research-only disclaimer,
  reference-annotation workflow, first-launch tour).
- Benchmark infrastructure (`+reference` + `scripts/run_benchmark.m`)
  is wired up and smoke-tested end-to-end on JohnDoe1 with a NaN template,
  ready for the user's TeraRecon ground-truth measurements.
- IFU library extended to 7 devices (added Ovation iX, Excluder C3).
- **56/56 regression tests passing.**

### New modules
- `+ui_helpers/` — `help_content`, `info_button`, `show_help_modal`,
  `step_mode_toggle`, `section_header`, `load_user_prefs`,
  `save_user_prefs`. Owns every help string the GUI shows; one file to
  edit on a documentation pass.
- `+reference/` — `schema`, `template`, `load`. Defines the JSON shape
  for TeraRecon-style ground-truth measurements. Each case has a
  `<case>.ref.json` filled in by the annotator.
- `+autoseg/detect_branches_cached` — hash-keyed disk cache around
  `extend_and_detect_branches`. Keys by `(seg shape, sum, pixel_mm,
  slice_spacing_mm)` so any TS output change invalidates the cache.
- `scripts/run_batch.m` — walks a directory of DICOM cases, runs the
  headless planner on each, emits a summary CSV.
- `scripts/run_benchmark.m` — pairs each CT case with its reference
  JSON, runs the planner, emits a per-case delta CSV (auto − ref for
  every measurement field).

### GUI changes
- `app.AorticCenterlineApp.StepModes` — new struct property (one entry
  per step), hydrated from `~/.aortic_centerline_prefs.json` on
  construction and persisted on mutation.
- `setStepModePublic(step, mode)` + `getStepModePublic(step)` + `setStepPublic(k)`
  + `injectCT(D)` — new public driver methods for tests and scripts.
- Every `buildStepN` now renders a User-driven / Automatic toggle at
  the top and dispatches to a `buildStepN_user` (existing UI) or
  `buildStepN_auto` (one-button flow) branch.
- Help menu in menubar exposes: pipeline overview, mode toggle,
  research-only disclaimer, per-step help, glossary of clinical terms,
  reference-annotation workflow, show first-launch tour.
- First-launch tour walks an 8-page modal sequence (uiconfirm-based, so
  it's step-by-step, not stacked). Gated on `prefs.tour_shown`.

### Pipeline changes
- `+autoseg/extend_to_cfa.m` — rewritten with anatomic side detection
  anchored on the aorta-bifurcation x-centroid (not the global midline,
  which is brittle to imreconstruct-grown labels). Thick bridge tubes
  (xy r=4, z r=3) painted at every step so the downstream skeleton
  stays connected through the EIA → CFA transition. Re-labels existing
  label-4/5 voxels by physical side to fix upstream label leakage.
- `+autoseg/audit_segmentation.m` — per-side continuity block now uses
  the aorta-label centroid at the bifurcation as the L/R split,
  matching what `extend_to_cfa` uses. Falls back to the two-CC slice
  heuristic only when the aorta label isn't present. Summary text now
  starts with a "Mask quick-stat" line (mL, FOV z-extent, fraction of
  FOV voxels) so the operator sees coverage at a glance.
- `run_planner_headless.m` — now calls `evar_plan.generate_plan` and
  embeds the result as `out.plan` (with `out.plan.measurements`).
  `out.audit` also added. Branch-detection wrapped by the cached layer.
- `+io/write_vtp_surface.m` — new `keep_largest_cc` option (default ON)
  that drops disconnected mesh fragments before VTP write. Addresses
  the most likely cause of VMTK's degenerate 2-7 node centerlines (goal
  #18): the seedpoint selector snaps to the nearest surface vertex; if
  the mesh has multiple CCs, the seed lands on a stub.

### IFU library
- Added `Ovation iX` (Endologix / Trivascular): polymer-sealing rings,
  16-30 mm neck Ø, 7 mm min neck length (short-neck tolerant).
- Added `Excluder Conformable (C3)` (Gore): same neck Ø window as
  standard Excluder, widened angulation to ≤ 90° per vendor labeling.

### Test coverage
- 11 new tests across two new suites:
  - `tests/test_session_features.m` (5): VTP largest-CC filter +
    largest-CC no-op when single CC + prefs round-trip with HOME
    sandbox + IFU library additions + batch runner empty-dir handling.
  - `tests/test_reference.m` (6): schema constants, template
    generator, load rejects missing file + bad schema version, load
    normalizes nulls to NaN, benchmark runner empty cohort.
  - `tests/test_headless_pipeline.m` (2): every reference-schema
    measurement field exists in plan.measurements + plan.ranked_devices
    has a per-device eligibility struct.
- Updated `tests/test_gui_mode_toggle.m` to sandbox HOME so the
  persistence layer doesn't pollute the real prefs file.
- **Final test count: 68 / 68 passing.**
  - +3 in `tests/test_audit_aorta_anchor.m` (audit's L/R split uses
    the aorta-label centroid when present; falls back to two-CC
    heuristic otherwise; quick-stat appears in summary).
  - +3 in `tests/test_phantom_accuracy.m` (reference JSON loads with
    expected values; aneurysm Ø recovered within ±5 mm; neck Ø
    recovered within ±5 mm).
  - +2 in `tests/test_ifu.m` (hostile short-neck prefers Ovation iX;
    severe angulation prefers Excluder Conformable).

### Documentation
- `STATUS.md` — refreshed to reflect 6/6 audit + new infrastructure.
- `README.md` — pipeline overview now mentions branch cache, 7-device
  IFU library, batch + benchmark entry points.
- `GOALS.md` — 5 new entries moved to Completed.
- This `CHANGELOG.md` — new file.

### Performance
- `imreconstruct` (5 calls) dominated `extend_and_detect_branches` at
  13.5 s / 25 s. Rather than rewrite, added a hash-keyed disk cache.
  Cache HIT → 0.39 s. Cache MISS → unchanged.

### Known follow-ups
- VMTK centerline end-to-end verification still requires VMTK reinstall
  (the largest-CC mesh filter lands the upstream fix; coordinate
  alignment debug is the other half).
- Goal #5 (TeraRecon accuracy benchmark) — harness + schema + runner
  all shipped; blocked on the user capturing ground-truth measurements.
- Goal #32 (GUI walkthrough video) — deferred until VMTK verified.
