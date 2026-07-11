"""Convert a VMTK centerline VTP (binary or ASCII) to CSV files.

VMTK 1.5 writes binary+zlib-compressed VTP by default, which is awkward
to parse from MATLAB. This helper reads the file with VTK's reader and
exports two CSV files:
    <out_stem>_points.csv  -- one row per centerline point: line_id, x, y, z, radius
    <out_stem>_lines.csv   -- one row per centerline line:  line_id, point_indices (space-separated)

Run as:
    python vtp_to_csv.py <in.vtp> <out_stem>

This file is intended to be invoked from MATLAB inside the +vmtk_centerline
package; it has no extra dependencies beyond VTK (already pulled in by
VMTK).
"""
import sys

import vtk
from vtk.util.numpy_support import vtk_to_numpy


def main():
    if len(sys.argv) != 3:
        print("usage: python vtp_to_csv.py <in.vtp> <out_stem>", file=sys.stderr)
        sys.exit(2)

    in_path, out_stem = sys.argv[1], sys.argv[2]

    reader = vtk.vtkXMLPolyDataReader()
    reader.SetFileName(in_path)
    reader.Update()
    poly = reader.GetOutput()

    points = poly.GetPoints()
    n_pts = points.GetNumberOfPoints()
    pts_array = vtk_to_numpy(points.GetData())  # n_pts x 3

    # Radius array name varies; vmtkcenterlines uses "MaximumInscribedSphereRadius"
    pd = poly.GetPointData()
    radius = None
    for k in range(pd.GetNumberOfArrays()):
        name = pd.GetArrayName(k)
        if name and "radius" in name.lower():
            radius = vtk_to_numpy(pd.GetArray(k))
            break
    if radius is None:
        radius = [0.0] * n_pts

    lines = poly.GetLines()
    lines.InitTraversal()
    id_list = vtk.vtkIdList()
    line_records = []
    line_id = 0
    while lines.GetNextCell(id_list):
        ids = [id_list.GetId(i) for i in range(id_list.GetNumberOfIds())]
        line_records.append((line_id, ids))
        line_id += 1

    with open(f"{out_stem}_points.csv", "w") as f:
        f.write("line_id,point_idx,x,y,z,radius\n")
        for lid, ids in line_records:
            for local_idx, gi in enumerate(ids):
                p = pts_array[gi]
                f.write(f"{lid},{gi},{p[0]:.6f},{p[1]:.6f},{p[2]:.6f},{float(radius[gi]):.6f}\n")

    with open(f"{out_stem}_lines.csv", "w") as f:
        f.write("line_id,n_points,point_indices\n")
        for lid, ids in line_records:
            ids_str = " ".join(str(i) for i in ids)
            f.write(f"{lid},{len(ids)},{ids_str}\n")

    print(f"wrote {out_stem}_points.csv ({n_pts} points) and {out_stem}_lines.csv ({len(line_records)} lines)")


if __name__ == "__main__":
    main()
