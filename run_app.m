%% RUN_APP  Launcher for the Aortic Centerline Builder.
%
%   Usage:
%       cd '/Users/.../Vascular Mathematical Modeling/phase-3-real-EVAR'
%       run_app
%
%   The app opens with six steps along the top:
%       1. Load CT     — DICOM folder, NIfTI file, cached .mat, or phantom
%       2. Segment     — TotalSegmentator (auto) or click inside the lumen
%       3. Endpoints   — proximal aorta + both common femoral arteries
%       4. Compute     — bifurcated centerline (VMTK or skeleton backend)
%       5. Analyze     — EVAR sizing + IFU device match
%       6. Export      — save centerline.mat + the EVAR plan (.txt/.json)
%
%   Every step has a User-driven / Automatic toggle; Step 2's "Auto-run
%   full pipeline" drives the whole CT → centerline flow in one click.
%   To try it without data, use Step 1 → "Open phantom from library…".

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

cd(fileparts(mfilename('fullpath')));
app.AorticCenterlineApp;
