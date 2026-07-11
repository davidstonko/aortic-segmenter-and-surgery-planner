# TEVAR architectural review (goal #14)

_Phase 5 forward-look. NOT a refactor plan — this is the punch list of
EVAR-specific assumptions baked into the codebase today that would have
to be addressed before a clean TEVAR (thoracic) extension._

The North Star explicitly calls for TEVAR as a Phase-5 expansion, but
asks that current-phase decisions "not preclude" it. This doc is the
state-of-the-codebase audit against that bar, as of 2026-05-16.

## Hard-coded assumptions to revisit

### 1. Proximal endpoint = "5 cm above the celiac"

`+preprocess/auto_seeds_anatomic.m` anchors the proximal seed to
`kidney_top_z - 70 mm`. For TEVAR the proximal landing zone is in the
thoracic aorta (zones 0–4 in the Ishimaru classification: ascending
through descending thoracic), and the relevant landmarks are the
left subclavian artery, the brachiocephalic trunk, the celiac trunk
(for distal landing in the chest), and the arch curvature itself.

**Decision required:** different `proximal_target` modes —
- `evar_supraceliac` (current): `kidney_top - 70 mm`
- `tevar_zone2_lsa`: requires identifying the left subclavian; TS does
  segment `subclavian_artery_left` (class 56) so the anchor exists.
- `tevar_zone3_proximal_descending`: anchor on left subclavian + 20 mm distal.

`auto_seeds_anatomic` should accept an `opts.target` enum and dispatch
to the right anchor function.

### 2. CFA-only distal endpoints

`auto_seeds_anatomic` returns `right_cfa` and `left_cfa`. TEVAR
distally landing zones are typically the visceral / juxtarenal aorta
(for a thoracic graft that ends above the celiac), or, for hybrid
arch repairs, the brachiocephalic or supraaortic vessels.

**Decision required:** generalise the seed struct to N targets, with a
typed enum: `{cfa_right, cfa_left, brachiocephalic, lsa, supraceliac, …}`
plus a method-specific consumer in `+evar_plan`.

### 3. IFU library is abdominal-only

`+ifu/devices.m` catalogues five abdominal-aortic stent grafts. None
of the thoracic devices (Gore TAG / cTAG, Medtronic Valiant Captivia,
Cook Zenith TX2, Terumo Aortic Relay) are encoded. Their IFU criteria
are different in kind: thoracic neck length, arch angulation,
proximal landing zone diameter range (20-46 mm for Valiant Captivia
vs 17-32 mm for an Endurant II), and stent oversizing rules.

**Decision required:** split `+ifu/devices.m` into `+ifu/devices_abd.m`
and `+ifu/devices_thoracic.m`; `+ifu/match_devices` takes an
`opts.indication = {'evar','tevar','hybrid'}` parameter.

### 4. Sizing measurements assume infrarenal anatomy

`+evar_plan/measure_from_centerline.m` measures:
- Proximal neck Ø/length/angulation (infrarenal definition: from the
  lowest renal to the start of the aneurysm)
- Iliac landing zone Ø

For TEVAR we need:
- Proximal landing zone Ø/length (at the LSA or arch)
- Aortic arch angulation / radius of curvature
- Inner vs outer curvature dimensions (for graft conformability)
- Distance from LSA to celiac (graft length selection)

**Decision required:** factor `measure_from_centerline` into
`measure_proximal_landing` and `measure_distal_landing` with anatomy-
specific implementations, dispatched by `opts.indication`.

### 5. App workflow is wired for 3 seeds

`AorticCenterlineApp` Step 3 has explicit `SeedProximal`, `SeedRightCFA`,
`SeedLeftCFA` properties and three buttons. Adding more seeds for
TEVAR (e.g., LSA + visceral segment) would require generalising the
seed list to a struct array.

**Decision required:** schema migration — `app.Seeds` becomes a struct
array with `name`, `position_vox`, `color`, `target_role` per entry.

### 6. Centerline endpoints come from a single source / two targets

Both `+vmtk_centerline/compute.m` and `+preprocess/centerline_seeds.m`
assume one source (proximal) and two targets (CFAs). TEVAR may need
N targets (LSA, brachio, celiac, …). VMTK's `vmtkcenterlines` natively
supports N targets — the wrapper just needs the seed list generalised.

**Decision required:** parameterise `vmtk_centerline.compute(mask,
source_seed, target_seeds, D, opts)` where `target_seeds` is K×3.

### 7. Phantoms are abdominal-only

`+phantom/build_normal_male.m` and `+phantom/build_aaa_male.m` model
the abdominal aorta + iliacs. A TEVAR test set needs an arch phantom
(zones 0–4) and a thoracic-aneurysm variant.

**Decision required:** add `+phantom/build_arch.m` and a tevar-AAA
variant with realistic Ishimaru-zone radii.

## What's already TEVAR-friendly

These would survive the TEVAR extension without changes:

- DICOM ingest (`preprocess.dicom_load`) — agnostic to body region.
- TS pipeline (`autoseg.ts_run`) — runs identically; the model
  segments thoracic aorta when present.
- Skeleton-graph centerline (`preprocess.build_skeleton_graph` +
  `centerline_seeds`) — agnostic to N seeds.
- `+ifu/check_eligibility` — uses the device's catalogued ranges, no
  abdominal-specific logic.
- Smoothing pass (`track_aorta_2click` post-process) — generic.
- `evar_plan.generate_plan` rationale generator — could template the
  output around any device list.
- Tests harness (`scripts/run_tests.m` + `tests/`) — extension only.

## Migration sketch (when Phase 5 starts)

1. Add `opts.indication = {'evar','tevar','hybrid'}` to the public
   entry points (`run_planner_headless`, `evar_plan.generate_plan`).
2. Generalise `auto_seeds_anatomic` to N seeds via an enum-driven
   anchor table.
3. Add `+ifu/devices_thoracic.m`; `ifu.match_devices` accepts an
   `opts.indication` filter.
4. Refactor `measure_from_centerline` into indication-specific
   landing-zone measurement helpers.
5. Migrate `AorticCenterlineApp` Step 3 to a generic seed-array model.
6. Add thoracic phantoms + a TEVAR regression test class.

Estimated effort: 2 person-weeks for a working TEVAR demo on a single
case, 4–6 weeks for a clean unified EVAR + TEVAR pipeline with full
test coverage.

## What NOT to do

- Don't refactor speculatively now. The audit above is forward-looking;
  the EVAR pipeline is the current focus and each refactor risks
  regressions on the EVAR path without a TEVAR case to validate
  against.
- Don't add TEVAR-specific code paths that can't be exercised — they
  rot. Wait for at least one anonymised TEVAR CT to be in hand.
