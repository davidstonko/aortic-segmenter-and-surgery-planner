# Dependencies

## Required

- **MATLAB R2022b or newer** (R2022b introduced the `viewer3d` /
  `volshow` API used by the 3-D volume render; on older releases the
  GUI falls back to a 2-D MIP).
- **Image Processing Toolbox** — `bwskel`, `fibermetric`, `imsegfmm`,
  `bwdist`, `imerode`/`imdilate`, `regionprops3`.
- **Image Processing Toolbox: 3D Image Volume Viewer** (only for the 3D
  Volume button; everything else works without it).

## Optional but recommended

These are external command-line tools called over `system()`. The GUI
detects them at startup and greys out the dependent buttons when they
are missing.

| Tool                                              | Purpose                                         | Used by                                  |
|---------------------------------------------------|-------------------------------------------------|------------------------------------------|
| [TotalSegmentator](https://github.com/wasserth/TotalSegmentator) | Auto-segmentation of aorta + iliac arteries     | `+autoseg/`, Step 2 *Auto-segment* button |
| [VMTK](http://www.vmtk.org)                       | Surface meshing + bifurcating centerlines       | `+vmtk_centerline/`, Step 4 VMTK option   |
| AortaSeg24 nnU-Net (optional, Phase B)            | Multi-class lumen + aortic-zone segmentation    | `+autoseg/+aortaseg24/` (scaffold)        |

## AortaSeg24 backend (optional, Phase B)

The `+autoseg/+aortaseg24/` scaffold runs an [AortaSeg24](https://aortaseg24.grand-challenge.org/)-trained
nnU-Net for multi-class lumen + aortic-zone segmentation. It is a
scaffold: there are **no public weights**, and it segments lumen + zones
**NOT** the aortic wall / intraluminal thrombus.

```bash
pip install "nnunetv2>=2.5"
export AORTASEG24_MODEL_DIR=/path/to/nnunet/config_dir   # checkpoint dir
```

`autoseg.aortaseg24.detect` finds the backend when both `nnunetv2>=2.5`
is importable in a Python env AND `AORTASEG24_MODEL_DIR` points at a
valid checkpoint directory. See [`docs/AORTASEG24_LABEL_MAP.md`](docs/AORTASEG24_LABEL_MAP.md)
for the label → anatomy mapping used by `translate_labels`.

## AAA-100 dataset support (optional)

To use the [AAA-100](https://zenodo.org/records/10932957) reference
cohort for SE(3) threshold calibration, statistical shape models, and
measurement-code validation, install the following Python packages
(any active Python 3 environment is fine — the loader shells out to
`python3`):

```
pip install vtk scipy numpy
```

`vtk` reads the `.vtp` PolyData files; `scipy.io.savemat` writes the
MAT cache that the MATLAB loader reads. See `docs/datasets.md` for
download instructions and `+library/+aaa100/` for the package contents.

Without these tools the manual workflow still works: click-to-add
segmentation in Step 2 and the built-in skeleton-based centerline
algorithm in Step 4.

## Hardware

- A **GPU** is strongly recommended for TotalSegmentator. The `--fast`
  flag gives 3 mm-resolution output that is good enough for centerline
  seeding without a GPU.
- 8 GB RAM is enough for typical CTA volumes (≤512 × 512 × 1500); 16 GB
  is more comfortable when running TotalSegmentator alongside the GUI.

## Citing the external tools

- **TotalSegmentator:** Wasserthal J, Breit H-C, Meyer MT, et al.
  *Radiology: Artificial Intelligence* 2023;5(5):e230024.
- **VMTK:** Antiga L, Piccinelli M, Botti L, et al.
  *Medical & Biological Engineering & Computing* 2008;46(11):1097–112.
