%% RUN_APP  Launcher for the Aortic Centerline Builder.
%
%   Usage:
%       cd '/Users/.../Vascular Mathematical Modeling/phase-3-real-EVAR'
%       run_app
%
%   The app opens with five steps along the top:
%       1. Load CT     — DICOM folder, NIfTI file, or cached .mat
%       2. Segment     — click inside the aorta lumen
%       3. Endpoints   — click the proximal and distal centerline ends
%       4. Compute     — run the centerline algorithm
%       5. Export      — save centerline.mat for downstream use
%
%   The cached CT for the JohnDoe1 case is at
%       results/logs/ct_volume.mat
%   so you can use the "Open cached CT" button in Step 1 for instant load.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

cd(fileparts(mfilename('fullpath')));
app.AorticCenterlineApp;
