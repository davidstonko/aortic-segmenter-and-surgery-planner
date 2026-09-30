# Contributing to the EVAR Planner

Thanks for your interest. This is a research project working toward an
open-source, fully-automated EVAR planner. We welcome contributors in
the vascular-surgery, medical-imaging, and open-source communities.

## Important — research use only

The EVAR planner is **NOT a regulated medical device**. Do NOT use any
output for clinical decision-making. The IFU catalog in `+ifu/` cites
its sources per device (see `+ifu/devices.m`) and may lag the current
vendor labeling. The sizing measurements in `+evar_plan/` are
auto-derived, contrast-lumen-only, and have NOT yet been validated
against a reference workstation (TeraRecon benchmark planned).

If you submit a PR that loosens or removes any "research only"
disclaimer, please open an issue first to discuss.

## Setup

See `SETUP.md` for the full install. In short:

```bash
# Native macOS / Linux
conda env create -f environment.yml          # TotalSegmentator
conda env create -f environment-vmtk.yml     # VMTK (osx-64 on Apple Silicon)
# Open MATLAB R2024a or newer; launch the GUI with run_app
```

## Running the regression suite

Before submitting a PR:

```matlab
cd aortic-segmenter-and-surgery-planner
addpath('scripts'); rc = run_tests();
% rc == 0 means the whole suite passed. Tests that need external tools
% or private case data skip automatically; GUI tests need a display.
```

CI runs the smoke test and the regression suite on MATLAB R2024a and
R2024b on every push (`.github/workflows/matlab-smoke.yml`).

## Coding conventions

- **MATLAB version:** code must run on R2024a or newer (the oldest
  release CI tests).
- **Argument validation:** declare positional arguments in an
  `arguments` block (don't fall back to `nargin`/`varargin`). Options
  are passed as a single `opts` struct whose fields default via
  `if ~isfield(opts, 'x'); opts.x = ...; end` guards, so callers can
  override fields piecemeal. See `run_planner_headless.m` for the
  pattern.
- **Package layout:** every function lives in a `+package/` folder.
  No loose top-level helpers except entry points (e.g. `run_planner_headless.m`).
- **Docstrings:** every public function has a header docstring that
  states purpose, inputs (types, units), outputs, and any caveats.
  See `+preprocess/auto_seeds_anatomic.m` for the style baseline.
- **No comments restating code.** Comments explain *why*, never *what*.
- **No PHI in commits.** Real DICOM stays in directories outside the
  repo and enters the project only through the `+intake`
  de-identification gate, under `JohnDoeN` codenames. Never commit
  `results/`, `output/`, `.cache/`, cached `.mat` volumes, or renders of
  real scans (all are git-ignored; keep it that way).
- **No absolute personal paths.** Build paths from
  `fileparts(mfilename('fullpath'))`; scripts that need private data
  expose the location as a clearly named variable at the top.
- **Clinical claims need evidence.** Don't add language like "validated"
  or "matches TeraRecon" without numerical evidence in a test or
  acceptance result.

## When in doubt — open an issue first

The project's aim is an open-source, fully automated EVAR planner
benchmarked against a reference clinical workstation. The current
priority is generalizing segmentation to new scans
(`docs/LEARNED_SEGMENTATION_ROADMAP.md`). Please open an issue to
discuss significant new features before sending a PR.

## Package layout (current)

- `+app/` — `AorticCenterlineApp.m`, the GUI entry point. Six-step flow,
  every step has a User-driven (default) / Automatic toggle and ⓘ info
  buttons.
- `+ui_helpers/` — `help_content`, `info_button`, `show_help_modal`,
  `step_mode_toggle`, `section_header`, `load_user_prefs`,
  `save_user_prefs`. All help text + UI affordances. Keep help strings
  in `help_content.m` — never inline in the app.
- `+autoseg/` — segmentation pipeline: TS wrapper, branch detection
  (`extend_and_detect_branches`, `detect_branches_cached`), CFA
  extension (`extend_to_cfa`), audit (`audit_segmentation`).
- `+preprocess/` — DICOM ingest, auto-seeds, centerlines, tracker,
  display helpers.
- `+evar_plan/` — `measure_from_centerline`, `generate_plan`,
  `compare_to_reference`, mesh export.
- `+ifu/` — device library, eligibility logic, ranking. Citations
  required on every entry.
- `+reference/` — schema + loader + template for TeraRecon-style
  ground-truth annotation JSONs.
- `+io/` — file format wrappers (`write_vtp_surface`, `save_nifti`).
- `scripts/` — entry points: `run_tests.m`, `run_batch.m`,
  `run_benchmark.m`, `aortic-centerline-cli.sh`.
- `+intake/` — DICOM de-identification intake, provenance manifest,
  annotation verification.
- `+library/`, `+phantom/`, `+setup/`, `+vmtk_centerline/` — case
  archive and dataset loaders, synthetic phantoms, dependency checks,
  VMTK wrapper.
- `tests/` — the `matlab.unittest` regression suite; run it with
  `run_tests` (above).

## Areas where help is especially welcome

- **Generalization to new scans.** The main open problem; see
  `docs/LEARNED_SEGMENTATION_ROADMAP.md` for the learned-segmentation
  plan and `docs/SEGMENTATION_ANNOTATION_SOP.md` for the annotation
  protocol.
- **Reference-workstation benchmark.** Infrastructure exists
  (`+reference/` schema, `scripts/run_benchmark.m`); the per-case
  reference JSONs still need expert measurements.
- **Aortic wall + thrombus segmentation.** Current diameters are
  contrast-lumen only. Outer-wall / thrombus segmentation would enable
  sizing against outer-wall IFU ranges.
- **GUI walkthrough video.** See `scripts/make_gui_video.m` for the
  framework.
- **More phantom cases.** Currently only `PHANTOM_normal_male` and
  `PHANTOM_aaa_male` (in `library/`). A hostile-neck case (short neck,
  severe angulation) would exercise the IFU off-label paths.

## License

The project is MIT-licensed. By contributing you agree your work is
licensed the same way.
