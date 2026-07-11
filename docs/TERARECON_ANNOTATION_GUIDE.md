# TeraRecon reference-annotation guide

**Purpose.** This document tells a vascular specialist how to fill in the
per-case reference JSONs that gate **goal #5** — the TeraRecon vs. open-
source-planner accuracy benchmark. Once the JSONs are populated,
`scripts/run_benchmark.m` automatically pairs each CT with its
reference and emits a per-case delta CSV.

Each measurement below maps a JSON field to where it lives in
TeraRecon Aquarius iNtuition (the reference workstation). All values
are in millimeters or degrees.

## Workflow at a glance

1. From a shell, generate a blank reference JSON for one case:
   ```matlab
   addpath('/path/to/phase-3-real-EVAR')
   reference.template('CASE_NAME', '/path/to/case_dir')
   ```
   This writes `CASE_NAME.ref.json` populated with `NaN` for every
   measurement.

2. Open the case in TeraRecon. Run TeraRecon's standard AAA workflow
   (Vessel Analysis → Aorta → automatic centerline) so the centerline,
   stretched-curved view, and orthogonal cross-section tools are
   available.

3. Read each value from the screens listed below and write it into the
   JSON. Use `NaN` for measurements the case doesn't have (e.g. no
   aneurysm — leave `aneurysm_max_diameter_mm = NaN`).

4. Save the file. Re-run `scripts/run_benchmark.m`.

## Field-by-field guide

### Proximal-neck measurements

| JSON field | TeraRecon screen | How to read it |
|---|---|---|
| `neck_diameter_mm` | Vessel Analysis → orthogonal cross-section at the lowest renal | **Lumen** diameter (inner contrast-opacified lumen, NOT outer wall — see pitfalls) at the slice **immediately below the lowest renal ostium**, before the lumen begins dilating. Average two perpendicular axes (the workstation usually shows both). |
| `neck_length_mm` | Stretched curved view (centerline view) | Arc length **along the centerline** from the lowest renal ostium to the most-proximal node where the lumen starts widening (aneurysm-start landmark). |
| `neck_angulation_deg` | Centerline 3D view, multi-segment angle tool | **The β (beta) angle: the infrarenal neck-to-sac angulation.** Two-vector angle between (a) the infrarenal neck centerline and (b) the centerline axis of the aneurysm sac. This is the canonical angle used for device eligibility. **Do NOT enter the suprarenal-to-neck (α/alpha) angle here** — that is a different angle. Use ~30 mm segments on each side of the neck-to-sac inflection. If you measured α separately, it has its own optional field (`neck_angulation_alpha_deg`); the benchmark compares only `neck_angulation_deg` = β. |

### Iliac measurements

| JSON field | TeraRecon screen | How to read it |
|---|---|---|
| `iliac_R_diameter_mm` | Orthogonal cross-section in the **common iliac**, ~20 mm distal to the aortic bifurcation | Lumen diameter on the **right** common iliac. NOT the CFA — the planner reports the CIA landing zone. |
| `iliac_R_length_mm` | Stretched curved view, right iliac | Arc length from the aortic bifurcation to the R-CFA terminus (where the workstation centerline ends). |
| `iliac_L_diameter_mm` | Same as R, left side | |
| `iliac_L_length_mm` | Same as R, left side | |

### Aneurysm sac

| JSON field | TeraRecon screen | How to read it |
|---|---|---|
| `aneurysm_max_diameter_mm` | Orthogonal cross-section at peak lumen | Peak **lumen** diameter (inner contrast-opacified lumen, NOT outer wall — see pitfalls) across the entire AAA. This is the field the benchmark compares against the planner's aneurysm sizing. Set to `NaN` when the case has no aneurysm (proximal-aorta diameter < ~30 mm and no fusiform dilation). |

### Distances

| JSON field | TeraRecon screen | How to read it |
|---|---|---|
| `distance_lowest_renal_to_bifurcation_mm` | Stretched curved view, distance measurement tool | **Centerline arc length** from the lowest renal ostium to the aortic bifurcation (where the centerline splits into R + L iliacs). NOT the straight-line distance. |

### Bifurcation angle (added 2026-05-20)

| JSON field | TeraRecon screen | How to read it |
|---|---|---|
| `bifurcation_angle_deg` | Centerline 3D view, two-vector angle tool | The **iliac take-off angle** — the angle between the two iliac trunks measured ~20 mm distal to the aortic bifurcation. Procedure: place vector endpoints at the bifurcation node and at 20 mm distal on each iliac; the tool reports the included angle in [0°, 180°]. Wide angles (> ~70°) can compromise stent-graft seating. |

## Common pitfalls

- **Use the lumen, not the outer wall, for the planner-comparison
  fields.** The planner segments contrast-opacified lumen via
  TotalSegmentator. Measuring outer wall in TeraRecon introduces a
  systematic offset of 1-3 mm depending on thrombus thickness. If the
  workstation defaults to outer-wall, switch to **lumen-only**.
- **Diameters must be perpendicular to the centerline.** Axial-only
  diameters overestimate the true vessel diameter when the vessel
  is angulated (e.g. the iliacs at the bifurcation). Use TeraRecon's
  orthogonal-to-centerline cross-section view.
- **Distances along the centerline, not Euclidean.** The planner
  reports arc length. A straight-line measurement from the renals
  to the bifurcation will underestimate the true centerline length
  by 5-15% on tortuous aortas.
- **`neck_angulation_deg` is the β (neck-to-sac) angle, not α.**
  As of the current measurement convention, `neck_angulation_deg`
  means the **infrarenal neck-to-sac (β) angulation** — the angle
  between the infrarenal neck centerline and the aneurysm sac axis.
  It is NOT the suprarenal-to-neck (α) angle. The planner reports β,
  so the benchmark compares β to β. If you enter α here the delta
  will be meaningless. (α has its own optional field
  `neck_angulation_alpha_deg`, which the benchmark ignores.)
- **Neck-angulation segment length matters.** Both the planner and
  TeraRecon report angulation as a two-vector angle, but the
  segment length the vectors span affects the value. The planner
  uses 30 mm segments by default (`opts.angulation_seg_mm`); use
  the same in TeraRecon for the closest match.

## What if a measurement is missing from TeraRecon?

The schema accepts `NaN` for any field. The benchmark runner skips
NaN fields when computing the delta. So if you can't measure the
bifurcation angle confidently on a given case (e.g. severe
calcification obscures the centerline geometry), leave it as `NaN`
and the comparison still runs over the remaining measurements.

## Once you're done

After all JSONs are populated for a cohort:

```matlab
cd /path/to/phase-3-real-EVAR
addpath('scripts')
run_benchmark('/path/to/cohort_root', '/path/to/ref_jsons')
```

The runner writes per-case delta rows to a CSV — that's the
`accuracy table` for goal #5.

## Schema source of truth

The authoritative list of fields lives in
[+reference/schema.m](../+reference/schema.m). If a future commit
adds or removes a measurement field, this guide should be updated to
match.
