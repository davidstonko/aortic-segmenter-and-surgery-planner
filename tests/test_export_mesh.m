classdef test_export_mesh < matlab.unittest.TestCase
%TEST_EXPORT_MESH  Coverage for evar_plan.export_mesh — the Step 6 /
%   GUI saveMesh + headless lumen.stl deliverable (audit tests-4 / A7).
%   Verifies an STL is written with non-empty geometry, that an empty
%   mask is rejected, and that the mesh is in patient millimetre
%   coordinates (the pixel_mm / slice_spacing_mm scaling is applied) —
%   the unit-scaling regression the one-off manual check would miss.

    methods (TestClassSetup)
        function add_path(~)
            here = fileparts(mfilename('fullpath'));
            addpath(fileparts(here));
        end
    end

    methods (Test)
        function writes_nonempty_stl(tc)
            mask = make_blob();
            tmp = [tempname '.stl'];
            cl = onCleanup(@() delete_if(tmp));
            info = evar_plan.export_mesh(struct('mask', mask), struct( ...
                'out_path', tmp, 'pixel_mm', [1 1], 'slice_spacing_mm', 1));
            tc.verifyTrue(isfile(tmp));
            tc.verifyGreaterThan(info.n_vertices, 0);
            tc.verifyGreaterThan(info.n_faces, 0);
            tc.verifyGreaterThan(info.bytes_written, 0);
        end

        function empty_mask_is_rejected(tc)
            % An all-false mask (no foreground) must fail cleanly with a
            % meaningful error, not crash in the mesh smoother.
            tc.verifyError(@() evar_plan.export_mesh( ...
                struct('mask', false(10,10,10)), ...
                struct('out_path', [tempname '.stl'])), ...
                'evar_plan:export_mesh:EmptyMesh');
        end

        function mesh_is_in_patient_mm(tc)
            % 4x the pixel spacing must give 4x the mesh extent — proves
            % the mesh carries patient-mm scaling, not raw voxel indices.
            tc.assumeTrue(exist('stlread', 'file') == 2, ...
                'stlread unavailable — skipping mm-scaling check');
            mask = make_blob();
            w_half = mesh_extent(mask, [0.5 0.5]);
            w_two  = mesh_extent(mask, [2 2]);
            tc.verifyEqual(w_two(1) / w_half(1), 4, 'RelTol', 0.1, ...
                'mesh x-extent must scale with pixel_mm (patient-mm coords)');
        end
    end
end

% =========================================================================
function mask = make_blob()
    mask = false(40, 40, 30);
    [xx, yy, zz] = ndgrid(1:40, 1:40, 1:30);
    mask((xx-20).^2 + (yy-20).^2 + ((zz-15)*1.5).^2 < 100) = true;
end

function w = mesh_extent(mask, pixel_mm)
    tmp = [tempname '.stl'];
    cl = onCleanup(@() delete_if(tmp)); %#ok<NASGU>
    evar_plan.export_mesh(struct('mask', mask), struct( ...
        'out_path', tmp, 'pixel_mm', pixel_mm, 'slice_spacing_mm', 1, ...
        'reduce', 0, 'smooth_iters', 0));
    TR = stlread(tmp);
    V = TR.Points;
    w = max(V, [], 1) - min(V, [], 1);
end

function delete_if(p)
    if isfile(p); delete(p); end
end
