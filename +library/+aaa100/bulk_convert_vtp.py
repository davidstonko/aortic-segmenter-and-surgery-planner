"""Bulk-convert AAA-100 VTP centerlines to a single MAT file.

Walks <root>/centerlines/AAAxxx/{abdominal_aorta,iliac_left,iliac_right,
renal_left,renal_right}.vtp and writes one MAT with a struct array:

    cases(i).case_id        = 'AAA001' .. 'AAA100'
    cases(i).aorta          = (N, 3) double, points in mm (X, Y, Z scanner coords)
    cases(i).iliac_L        = (N, 3) double
    cases(i).iliac_R        = (N, 3) double
    cases(i).renal_L        = (N, 3) double
    cases(i).renal_R        = (N, 3) double
    cases(i).aorta_radius   = (N, 1) double  (0 if not in file)
    cases(i).iliac_L_radius = (N, 1)
    ...

Points are returned in the order they appear in the VTP file, which is
proximal → distal for SIRE-tracked centerlines on this dataset.

Usage:
    python3 bulk_convert_vtp.py <centerlines_dir> <out.mat>

Requires:
    pip install vtk scipy
"""
import os
import sys

import numpy as np
import vtk
from scipy.io import savemat
from vtk.util.numpy_support import vtk_to_numpy


VESSEL_FILES = {
    "aorta":   "abdominal_aorta.vtp",
    "iliac_L": "iliac_left.vtp",
    "iliac_R": "iliac_right.vtp",
    "renal_L": "renal_left.vtp",
    "renal_R": "renal_right.vtp",
}


def read_vtp_polyline(path):
    """Return (points_Nx3, radius_N) from a VTP file. Points in file order."""
    reader = vtk.vtkXMLPolyDataReader()
    reader.SetFileName(path)
    reader.Update()
    poly = reader.GetOutput()

    points = poly.GetPoints()
    if points is None or points.GetNumberOfPoints() == 0:
        return np.zeros((0, 3), dtype=np.float64), np.zeros((0,), dtype=np.float64)

    pts = vtk_to_numpy(points.GetData()).astype(np.float64)  # N x 3

    pd = poly.GetPointData()
    radius = None
    for k in range(pd.GetNumberOfArrays()):
        name = pd.GetArrayName(k)
        if name and "radius" in name.lower():
            radius = vtk_to_numpy(pd.GetArray(k)).astype(np.float64)
            break
    if radius is None:
        radius = np.zeros(pts.shape[0], dtype=np.float64)
    return pts, radius


def main():
    if len(sys.argv) != 3:
        print("usage: python3 bulk_convert_vtp.py <centerlines_dir> <out.mat>",
              file=sys.stderr)
        sys.exit(2)
    root, out_path = sys.argv[1], sys.argv[2]

    case_ids = sorted(d for d in os.listdir(root)
                      if d.startswith("AAA") and os.path.isdir(os.path.join(root, d)))
    if not case_ids:
        print(f"no AAA-named subdirectories found under {root}", file=sys.stderr)
        sys.exit(1)

    cases = []
    n_missing = 0
    for cid in case_ids:
        entry = {"case_id": cid}
        for vessel, filename in VESSEL_FILES.items():
            path = os.path.join(root, cid, filename)
            if not os.path.isfile(path):
                entry[vessel] = np.zeros((0, 3), dtype=np.float64)
                entry[f"{vessel}_radius"] = np.zeros((0,), dtype=np.float64)
                n_missing += 1
                continue
            pts, radius = read_vtp_polyline(path)
            entry[vessel] = pts
            entry[f"{vessel}_radius"] = radius
        cases.append(entry)
        if len(cases) % 10 == 0:
            print(f"  processed {len(cases)}/{len(case_ids)} cases", flush=True)

    savemat(out_path, {"cases": cases}, do_compression=True)
    print(f"wrote {out_path}: {len(cases)} cases, {n_missing} missing VTP files")


if __name__ == "__main__":
    main()
