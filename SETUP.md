# Setup

> ⚠️ **RESEARCH USE ONLY** — outputs of this pipeline have NOT been
> clinically validated. Do not use for patient care.

## 1. MATLAB-only path (manual workflow)

Requires MATLAB R2024a or newer (CI tests R2024a and R2024b; development
is on R2025b) with the Image Processing Toolbox. CI additionally
provisions the Signal Processing and Statistics & Machine Learning
Toolboxes. No external tools are required for this path.

```matlab
cd '/path/to/aortic-segmenter-and-surgery-planner'
setup.check_dependencies        % prints a diagnostic table
app.AorticCenterlineApp         % launch GUI (banner appears)
```

The auto-segment button and the VMTK toggle in Step 4 will be greyed
out. Every step still has a manual path (click-to-add / brush
segmentation, MATLAB skeleton centerline), but fully automatic planning
from raw DICOM needs TotalSegmentator (or a mask supplied through the
`external` segmentation backend).

## 2. Adding TotalSegmentator (auto-segmentation)

TotalSegmentator runs in its own Python environment.

```bash
conda env create -f environment.yml      # pinned: TotalSegmentator==2.13.0
conda activate evar-tools
```

Verify:

```bash
TotalSegmentator --version    # should print 2.13.0
```

When `TotalSegmentator` is on `PATH`, the GUI's *Auto-segment* button
lights up. The first run on a given machine downloads model
weights (~5 GB).

## 3. Adding VMTK (bifurcating centerlines)

```bash
# Intel macOS / Linux / Windows
conda env create -f environment-vmtk.yml
conda activate vmtk

# Apple Silicon (M1/M2/M3) — VMTK has no native arm64 build, use Rosetta:
CONDA_SUBDIR=osx-64 conda env create -f environment-vmtk.yml
conda activate vmtk
```

Verify:

```bash
~/miniforge3/envs/vmtk/bin/python -c "import vmtk; print('ok')"
ls ~/miniforge3/envs/vmtk/bin/vmtkcenterlines
```

`vmtk_centerline.detect()` from MATLAB will find the env automatically
(it scans `~/miniforge3/envs/`, `~/miniconda3/envs/`, etc.) and pick
up the env's `python` so the VMTK scripts' `#!/usr/bin/env python`
shebang resolves correctly.

With VMTK installed, `opts.centerline_backend = 'auto'` (the default)
uses the VMTK Voronoi/fast-marching centerline; the MATLAB skeleton-graph
centerline is the fallback when VMTK is absent.

## 4. Running the headless planner

```bash
conda activate evar-tools         # TotalSegmentator on PATH
matlab &
```

```matlab
out  = run_planner_headless('/path/to/DICOM-folder');
plan = evar_plan.generate_plan(out);   % writes evar_plan.{txt,json}
```

## 5. Anonymizing real DICOM cases

**Never commit identifiable DICOM into the repo.** Keep real studies in
a directory outside the repository. `preprocess.dicom_load` strips
patient identifiers from the in-memory struct (`patient_id = 'ANON'`)
but does NOT rewrite the source DICOM files.

The built-in route is the Phase-0 intake gate, which copies the study,
scrubs the copy, independently verifies the result (quarantining any
failure) and records a de-identified manifest row:

```matlab
info = intake.deidentify_intake('/path/to/raw-study', 'JohnDoe7', ...
    struct('out_root', '/path/to/regulated-store/JohnDoe7_deid'));
```

Alternatively, anonymize at ingest using one of:

- **[dicognito](https://github.com/blairconrad/dicognito)** (MIT) — the
  recommended cohort-aware anonymizer. Re-maps UIDs consistently across
  a study and shifts dates by a constant offset.

  ```bash
  pip install dicognito
  dicognito --in-place /path/to/dicom-folder
  ```

- **[pydicom](https://pydicom.github.io/) + custom script** — for
  finer-grained control.

- **RSNA CTP** — production-grade, Java/heavier.

After anonymization, run a quick PHI check before adding to the local
case library:

```bash
grep -r -I "PatientName\|PatientID" /path/to/dicom-folder | head
```

The library save path strips PII at save time too, but anonymizing the
source files is safer.

## 6. Verifying the pipeline

```matlab
cd '/path/to/aortic-segmenter-and-surgery-planner'
setup.check_dependencies

% Run the full regression suite. Tests that need external tools or
% private case data skip automatically; GUI tests need a display.
addpath('scripts'); rc = run_tests();
assert(rc == 0, 'regression suite failed')
```

If `rc == 0`, your install is good.

## 7. Versions verified together

| Tool                | Version  | How pinned |
|---------------------|----------|------------|
| MATLAB              | R2025b (dev); R2024a / R2024b (CI) | (host) |
| TotalSegmentator    | 2.13.0   | environment.yml |
| VMTK                | 1.5.0    | environment-vmtk.yml |
| VTK                 | 9.2.x    | conda-forge with vtk>=9,<10 |
| Python (TS env)     | 3.11     | environment.yml |
| Python (VMTK env)   | 3.9      | environment-vmtk.yml |
| Platform tested     | macOS 25.4 (arm64 + Rosetta) | – |
