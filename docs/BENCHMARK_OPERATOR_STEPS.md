# Benchmark operator steps — goal #5 (TeraRecon accuracy table)

**Audience:** the vascular specialist who enters real TeraRecon measurements.
**Outcome:** one command produces the accuracy table (auto-planner vs. TeraRecon
delta CSV).

Everything around your measurements is already wired and smoke-tested. The
benchmark is blocked on exactly one thing: real numbers in the reference JSON.
Once you save them, the runner does the rest.

For the full screen-by-screen reading instructions, see
[TERARECON_ANNOTATION_GUIDE.md](TERARECON_ANNOTATION_GUIDE.md). This file is the
short checklist.

---

## Step 1 — Open the blank reference JSON for the case

A blank, NaN-filled template already exists for the JohnDoe1 case:

```
library/reference/JohnDoe1_EVAR.ref.json
```

Every measurement is `null` (loads as `NaN`). You fill in only what you measure;
leave anything you can't measure confidently as `null`.

(For a new case, generate a fresh blank with
`reference.template('CASE_NAME', 'library/reference')`.)

## Step 2 — Take these measurements in TeraRecon and enter them

Open the case in TeraRecon Aquarius iNtuition, run the standard AAA workflow
(Vessel Analysis → Aorta → automatic centerline), then read each value below and
type it into the matching JSON field under `"measurements"`.

| # | JSON field | What to measure | Units / convention |
|---|---|---|---|
| 1 | `neck_diameter_mm` | Proximal-neck diameter, slice just below the lowest renal ostium | mm; **lumen** (inner contrast), perpendicular to centerline; average two perpendicular axes |
| 2 | `neck_length_mm` | Lowest renal ostium → aneurysm-start landmark | mm; **centerline arc length** (not straight-line) |
| 3 | `neck_angulation_deg` | **β (beta) angle: infrarenal neck-to-sac** angulation | deg; two-vector angle, neck centerline vs. sac axis, ~30 mm segments. **Enter β, NOT the suprarenal-to-neck α angle.** |
| 4 | `iliac_R_diameter_mm` | Right common iliac (CIA) diameter, ~20 mm distal to aortic bifurcation | mm; **lumen**, perpendicular to centerline; CIA landing zone, not CFA |
| 5 | `iliac_R_length_mm` | Aortic bifurcation → right iliac terminus | mm; **centerline arc length** |
| 6 | `iliac_L_diameter_mm` | Left common iliac diameter (same as #4, left) | mm; **lumen**, perpendicular to centerline |
| 7 | `iliac_L_length_mm` | Aortic bifurcation → left iliac terminus | mm; **centerline arc length** |
| 8 | `aneurysm_max_diameter_mm` | Peak AAA diameter across the whole aneurysm | mm; **lumen**, perpendicular to centerline. `null` if no aneurysm. **This is the field the benchmark scores for sac sizing.** |
| 9 | `distance_lowest_renal_to_bifurcation_mm` | Lowest renal ostium → aortic bifurcation | mm; **centerline arc length** (not straight-line) |
| 10 | `bifurcation_angle_deg` | Iliac take-off angle, ~20 mm distal on each iliac | deg; included angle in [0°, 180°] |

**Three conventions that matter (these match what the planner reports):**

- **Lumen, not outer wall.** The planner segments the contrast-opacified lumen.
  Measuring outer wall adds a systematic 1–3 mm offset (thrombus). Switch
  TeraRecon to lumen-only if it defaults to outer wall.
- **Diameters perpendicular to the centerline.** Use the orthogonal
  cross-section view, not axial slices — axial overestimates on angulated
  vessels.
- **Lengths/distances are centerline arc length, not Euclidean.** Straight-line
  underestimates by 5–15% on tortuous anatomy.

> **β vs. α — the one easy mistake.** `neck_angulation_deg` is the **infrarenal
> neck-to-sac (β)** angle. Do NOT enter the suprarenal-to-neck (α) angle there.
> If you measured α as well, it has its own optional field
> (`neck_angulation_alpha_deg`); the benchmark ignores it and compares only β.

## Step 3 — Fill in the metadata and save

Set `"annotator"` to your initials and update `"annotation_date"` if needed.
Optionally add `"notes"` (image quality, caveats) and adjust `"uncertainty_mm"`
(default 1 mm). Save the file in place — keep the `<case>.ref.json` name.

## Step 4 — Run the benchmark (one command)

From MATLAB, at the project root:

```matlab
addpath(pwd); addpath('scripts');
run_benchmark('<COHORT_ROOT>', 'library/reference');
```

- `<COHORT_ROOT>` is the folder containing one sub-directory per CT case (the
  same layout the planner/GUI loads). The runner finds the DICOM series under
  each case and pairs it with the matching `<case>.ref.json` in
  `library/reference`.
- The runner runs the automated planner headless on each case, computes
  per-field `auto − ref` deltas, prints a summary, and writes a CSV.

**Output (the accuracy table):**

```
results/logs/benchmark_<timestamp>/benchmark.csv
```

Each row is one case with `<field>_auto`, `<field>_ref`, `<field>_delta` columns
for all ten measurements, plus `abs_max_delta_mm`. The console also prints
mean and max `|Δ|` per measurement across cases. Fields you left as `null` are
skipped automatically (blank delta) — the comparison still runs over everything
you did measure.

---

## Notes

- You only need to fill the fields you can measure. NaN/`null` fields are skipped
  cleanly; they don't break the run.
- Field names in the JSON are the single source of truth in
  [`+reference/schema.m`](../+reference/schema.m). If that list changes, this
  checklist and the annotation guide should be updated to match.
- This path has been smoke-tested end-to-end (template → fill → load →
  `run_benchmark` → delta CSV) against a cached planner result; the only missing
  input is your real TeraRecon numbers.
