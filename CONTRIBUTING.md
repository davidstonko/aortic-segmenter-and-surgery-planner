# Contributing to the EVAR Planner

Thanks for your interest. This is a research project working toward an
open-source, fully-automated EVAR planner. We welcome contributors in
the vascular-surgery, medical-imaging, and open-source communities.

## Important — research use only

The EVAR planner is **NOT a regulated medical device**. Do NOT use any
output for clinical decision-making. The IFU library in `+ifu/` is
encoded from peer-reviewed summaries (Chaikof 2018 SVS, AbuRahma 2018
JACS), not from current vendor IFUs. The sizing measurements in
`+evar_plan/` are auto-derived from a centerline that has NOT been
quantitatively validated against the TeraRecon ground truth (goal #5).

If you submit a PR that loosens or removes any "research only"
disclaimer, please open an issue first to discuss.

## Setup

See `SETUP.md` for the full install. In short:

```bash
# Native macOS / Linux
conda env create -f environment.yml          # TotalSegmentator
conda env create -f environment-vmtk.yml     # VMTK (osx-64 on Apple Silicon)
# Open MATLAB R2025b+; the GUI is in +app/AorticCenterlineApp.m
```

## Running the regression suite

Before submitting a PR:

```matlab
cd phase-3-real-EVAR
addpath('scripts'); rc = run_tests();
% rc == 0 means the suite passed (non-GUI: 110 pass / 1 expected-skip
% of 111; GUI tests need a display). See STATUS.md for the live count.
```

CI runs the MATLAB-only path on every push (`.github/workflows/`).

## Coding conventions

- **MATLAB version:** R2025b or newer. We use `arguments` blocks
  throughout — please don't fall back to `nargin`/`varargin`.
- **Package layout:** every function lives in a `+package/` folder.
  No loose top-level helpers except entry points (e.g. `run_planner_headless.m`).
- **Docstrings:** every public function has a header docstring that
  states purpose, inputs (types, units), outputs, and any caveats.
  See `+preprocess/auto_seeds_anatomic.m` for the style baseline.
- **No comments restating code.** Comments explain *why*, never *what*.
- **Defensive defaults:** option struct fields default via `if ~isfield` 
  guards so callers can override piecemeal.
- **No PHI in commits.** Real DICOM stays in directories outside the
  repo. The JohnDoe1 case lives at `/Vascular Mathematical Modeling/JohnDoe1 EVAR/`
  (sibling to this repo) and is git-ignored.
- **Clinical claims need evidence.** Don't add language like "validated"
  or "matches TeraRecon" without numerical evidence in a test or
  acceptance result.

## When in doubt — open an issue first

The project has a North Star (open-source, fully-automated EVAR planner;
reference TeraRecon) and an active goal list in `GOALS.md`. Significant
new features should usually become goals before they become PRs.

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
- `tests/` — every regression test. 26 test files / ~134 test methods;
  non-GUI 110 pass / 1 expected-skip of 111 (see STATUS.md for the live
  count).

## Areas where help is especially welcome

- **Goal #5 — TeraRecon ground-truth benchmark.** Infrastructure complete:
  see `+reference/` for the annotation schema and `scripts/run_benchmark.m`
  for the runner. **Blocked on a vascular specialist entering real
  measurements** into per-case reference JSONs.
- **Goal #18 — VMTK integration.** The largest-CC mesh filter (in
  `io.write_vtp_surface`, default ON) addresses the most likely cause
  of the previously-observed degenerate centerlines. End-to-end VMTK
  verification still pending.
- **Goal #26 — Aortic wall + thrombus segmentation.** TotalSegmentator
  gives lumen only. Plugging in an [AortaSeg24](https://aortaseg24.grand-challenge.org/)-trained
  nnU-Net would unlock thrombus-aware sizing.
- **Goal #32 — GUI walkthrough video.** Deferred until VMTK verified;
  see `scripts/make_gui_video.m` for the framework.
- **More phantom cases.** Currently only `PHANTOM_normal_male` and
  `PHANTOM_aaa_male` (in `library/`). A hostile-neck case (short neck,
  severe angulation) would exercise the IFU off-label paths.

## License

The project is MIT-licensed. By contributing you agree your work is
licensed the same way.
