# Centerline extraction — methods survey for Phase 3 (AINN/EVAR)

> **Note:** Method survey from project bootstrap; the production pipeline now uses TotalSegmentator + VMTK (primary) — see STATUS.md / README.md. The survey below is retained for reference.

This document summarises the algorithmic options for extracting an aorta + iliac centerline from a contrast-enhanced CT (the "Aorta 0.75 Br36 3" series of the JohnDoe1 dataset, 1219 slices at 0.77 mm × 0.5 mm spacing). The centerline is the input to the AINN forward physics simulator (it defines $g_v(s)$ in §4.1 of the manuscript), so its accuracy directly bounds downstream prediction quality. Industry-standard accuracy on the Rotterdam coronary-centerline benchmark is sub-millimetre mean distance to the consensus reference; our application is the abdominal aorta (much larger lumen, less branching), so the bar is ~1 mm at the iliacs and ~2 mm at the aorta.

## The five families

### 1. Voronoi-based (VMTK, gold standard)

[VMTK](http://www.vmtk.org/) (Vascular Modeling Toolkit) computes the centerline as a *weighted shortest path on the Voronoi diagram* of the segmented vessel surface. Concretely:

1. Tetrahedralise the vessel-surface mesh (Delaunay).
2. Compute the dual Voronoi diagram. The Voronoi vertices are exactly the centers of the maximal inscribed spheres — i.e. the medial axis.
3. Define a cost function $c = 1/R$ where $R$ is the radius of the inscribed sphere at each Voronoi vertex.
4. Apply the fast-marching algorithm to find the optimal path between two user-supplied seed points (typically the proximal aorta and one iliac terminus).

**Pros.** Sub-millimetre accuracy; handles bifurcations natively (run multiple seed pairs and merge); produces a *radius* array along the centerline as a free byproduct (we need this for $R_{\text{lumen}}(s)$ in the energy functional). Industry standard, used by the [3D Slicer VMTK extension](https://github.com/vmtk/SlicerExtension-VMTK), the Rotterdam benchmark winners, and most published EVAR planning workflows.

**Cons.** Implemented in C++/Python (VTK). Calling from MATLAB requires either (a) installing 3D Slicer + VMTK extension and shelling out, (b) calling Python's VMTK bindings via `pyrun`, or (c) re-implementing the Voronoi-diagram computation in MATLAB (non-trivial: ~500 lines).

**Verdict.** Long-term: **yes, integrate VMTK** (probably via 3D Slicer headless mode or a Python shell-out from MATLAB). Short-term: too much setup overhead for a single-case smoke test.

---

### 2. Neural-network segmentation + skeletonisation (TotalSegmentator + bwskel)

[TotalSegmentator](https://github.com/wasserth/TotalSegmentator) is an nnU-Net-based segmenter that outputs binary masks for 100+ anatomical structures, including aorta, common iliac arteries, and external iliacs (added in the [TotalSegmentator-2.0 cardiovascular update](https://www.ejradiology.com/article/S0720-048X(25)00092-0/fulltext)). Once we have a binary aorta+iliac mask, we apply MATLAB's built-in [`bwskel`](https://www.mathworks.com/help/images/ref/bwskel.html) (3D medial-axis thinning) to reduce the mask to a 1-voxel-wide skeleton, then connect the skeleton voxels into a polyline.

**Pros.** TotalSegmentator is robust on contrast-enhanced CTs (Dice 0.94 in the original paper). Output mask is in standard NIfTI which MATLAB reads via `niftiread`. `bwskel` is built into the Image Processing Toolbox with a `MinBranchLength` parameter for pruning. End-to-end pipeline is ~200 lines of MATLAB if TotalSegmentator output is already on disk.

**Cons.** TotalSegmentator runs in Python (PyTorch). We'd shell out from MATLAB. Inference takes ~30 s/case on a GPU and ~5 min on a CPU. The skeleton can have spurious branches at the iliac bifurcation that need pruning. The medial-axis from a binary mask is voxel-aligned and zigzags — needs spline-fitting to get a smooth continuous polyline.

**Verdict.** **Best practical option for the Phase 3 smoke test.** TotalSegmentator is one shell-out away from a usable mask, and `bwskel` is one MATLAB call away from a usable centerline. Spline-smoothing fixes the zigzag.

---

### 3. Frangi vesselness + ridge tracking

[Frangi's vesselness filter](https://www.mathworks.com/help/images/ref/fibermetric.html) is a multiscale Hessian-based filter that gives every voxel a "tubular-likelihood" score from the eigenvalues of the local Hessian: a voxel scores high if two eigenvalues are large and negative (sheet-like cross-section) and one is small (axial direction). MATLAB's [`fibermetric`](https://www.mathworks.com/help/images/ref/fibermetric.html) implements it for 2D and 3D.

The centerline is then the *ridge* of the vesselness response — the locus where the response is locally maximal in the cross-section perpendicular to the dominant Hessian eigenvector. Track the ridge from a seed point along the principal direction.

**Pros.** Handles vessels of varying diameter (multi-scale). Doesn't need a separate segmentation step. Works on the raw CT directly. Pure MATLAB.

**Cons.** Sensitive to parameter tuning (scale range $\sigma$, Frangi $\alpha, \beta, c$). Ridge tracking can drift into adjacent vessels at the bifurcation. For the 1219-slice JohnDoe1 CT, multi-scale Frangi takes ~5 minutes on CPU; faster with the [vectorized GPU implementation](https://www.mathworks.com/matlabcentral/fileexchange/127564-vectorized-3d-frangi-filter) (~6 s on a 240³ volume).

**Verdict.** **Useful as preprocessing** to enhance vessel contrast before segmentation (e.g. for the threshold step in option 5 below), but as a standalone centerline extractor it's fragile at branchings. Keep it in the pipeline but not as the primary method.

---

### 4. Fast-marching minimum-action paths (Cohen-Kimmel)

The classic [Cohen-Kimmel framework](https://link.springer.com/article/10.1007/s11263-010-0331-0): given two seed points, define a cost-of-traversal field over the volume (typically 1/vesselness or 1/distance-from-boundary), then solve the Eikonal equation $|\nabla T| = 1/c$ via fast marching from one seed. The optimal path between the seeds is the gradient descent of $T$ from the second seed back to the first.

**Pros.** Globally optimal between seeds (under the cost). Handles tubular structures of any shape. ITK has [reference implementations](https://github.com/InsightSoftwareConsortium/ITKMinimalPathExtraction). MATLAB has fast-marching solvers in the File Exchange.

**Cons.** Need two well-chosen seeds per branch (the user clicks them, or an automatic landmark detector finds them). The cost field still needs to be computed (Frangi or distance transform). For a multi-branch tree like aorta + 2 iliacs, you run pairwise fast-marching three times.

**Verdict.** **This is what VMTK actually uses internally.** If we re-implement VMTK in MATLAB, this is the engine. For a quick start, simpler skeletonisation suffices; if accuracy needs to improve, switch to fast-marching.

---

### 5. Threshold + connectivity + skeletonise (the "no-dependencies" option)

The simplest possible pipeline that uses only MATLAB built-ins:

1. **Window the CT** to vessel HU range. Contrast-enhanced aorta typically lights up at 200–400 HU. A window of [150, 600] keeps lumen and excludes calcium (which is much brighter) and surrounding tissue (much darker).
2. **Largest connected component.** `bwconncomp` then pick the volume whose centroid is in the expected aorta location (anterior to vertebral bodies, midline).
3. **Morphological cleanup.** `imfill('holes')` fills small calcification voids; `imopen` removes thin spurious connections; `imclose` smooths the surface.
4. **Skeletonise.** `bwskel` (with `MinBranchLength` ≈ 20 voxels to prune leaves).
5. **Polyline fitting.** Walk the skeleton voxels in order from a seed (e.g. most-superior voxel = aortic origin) using 26-connectivity, then spline-smooth.

**Pros.** Zero external dependencies. ~150 lines of pure MATLAB. Runs in seconds, not minutes. Diagnoses problems easily (you can see at every step what went wrong).

**Cons.** Threshold selection is dataset-dependent — bone fragments, IV contrast in adjacent veins, and metallic stents can all show up bright and confuse the connectivity step. Doesn't handle bifurcations cleanly; the skeleton at the iliac bifurcation will fork and need branch-pruning. Doesn't give us the radius array as a byproduct (need a separate distance-transform step).

**Verdict.** **Right starting point for our Phase 3 smoke test.** It's simple, debuggable, and good enough for a single case. We'll graduate to TotalSegmentator + `bwskel` once we want robustness across the full 25-case cohort.

## Recommended pipeline for Phase 3 (this week)

```
preop CT (1219 slices, 512×512)
    │
    ▼  preprocess.segment_aorta_thresh
binary mask (aorta + common + external iliacs)
    │
    ▼  preprocess.centerline_skel   (bwskel + branch pruning)
voxel skeleton (1-voxel-wide)
    │
    ▼  preprocess.centerline_polyline   (graph walk + spline smooth)
smooth centerline P_v(s) ∈ R^3, plus
inscribed-sphere radius R_lumen(s) at each node
    │
    ▼  preprocess.centerline_qc   (overlay on CT, sanity check)
.fig + .png QC artifact → human review
    │
    ▼  drop into demo_phase2 architecture as Pv1
forward equilibrium → projected to angio → W2² loss
```

## Recommended pipeline for full cohort (Phase 4)

```
preop CT
    │
    ▼  TotalSegmentator (Python shell-out, CT-mode, structures: aorta + iliac_artery_*)
NIfTI mask
    │
    ▼  preprocess.centerline_skel
    ▼  preprocess.centerline_polyline
    ▼  optionally: VMTK shell-out for Voronoi-based polishing if iliacs are noisy
P_v(s), R_lumen(s)
```

## References

- **VMTK**: [Vascular Modeling Toolkit homepage](http://www.vmtk.org/) · [Centerlines tutorial](http://www.vmtk.org/tutorials/Centerlines.html) · [DeepWiki algorithm summary](https://deepwiki.com/vmtk/vmtk/3.2-centerline-extraction) · [3D Slicer extension](https://github.com/vmtk/SlicerExtension-VMTK)
- **TotalSegmentator**: [GitHub repo](https://github.com/wasserth/TotalSegmentator) · [Wasserthal et al. 2023, *Radiology: AI*](https://pubs.rsna.org/doi/10.1148/ryai.230024) · [Cardiovascular update 2025](https://www.ejradiology.com/article/S0720-048X(25)00092-0/fulltext) · [AortaExplorer 2026](https://link.springer.com/article/10.1007/s11517-026-03535-x)
- **Frangi vesselness**: [`fibermetric` MATLAB docs](https://www.mathworks.com/help/images/ref/fibermetric.html) · [Vectorized 3D Frangi filter](https://www.mathworks.com/matlabcentral/fileexchange/127564-vectorized-3d-frangi-filter) · [Jerman enhancement filter](https://www.mathworks.com/matlabcentral/fileexchange/63171-jerman-enhancement-filter)
- **Fast-marching minimum-path**: [ITK MinimalPathExtraction](https://github.com/InsightSoftwareConsortium/ITKMinimalPathExtraction) · [Tubular Structure Segmentation Based on Minimal Path Method](https://link.springer.com/article/10.1007/s11263-010-0331-0)
- **bwskel**: [MATLAB docs](https://www.mathworks.com/help/images/ref/bwskel.html) · [Skeleton3D File Exchange](https://www.mathworks.com/matlabcentral/fileexchange/43400-skeleton3d) · [GPU thinning File Exchange](https://www.mathworks.com/matlabcentral/fileexchange/71766-gpu-centerline-extraction-skeletonization-in-2d-or-3d)
- **Benchmarks**: [Schaap et al. 2009 Rotterdam coronary centerline benchmark](https://pmc.ncbi.nlm.nih.gov/articles/PMC3843509/)

