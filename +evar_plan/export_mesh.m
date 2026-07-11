function info = export_mesh(planner_result, opts)
%EVAR_PLAN.EXPORT_MESH  Export the lumen mask as an STL for downstream
%   CFD / 3D-printing use.
%
%   INFO = evar_plan.export_mesh(PLANNER_RESULT)
%   INFO = evar_plan.export_mesh(PLANNER_RESULT, OPTS)
%
%   Marching-cubes the mask in PLANNER_RESULT and writes a triangulated
%   STL alongside the rest of the planner output. The mesh is in
%   patient millimeter coordinates.
%
%   For CFD-grade tetrahedral meshing, downstream users should convert
%   the STL with `pyvista` / `meshio` (no MATLAB dependency on
%   either tool). The PyVista path is goal #28 future work.
%
%   OPTS:
%       .out_path        STL file path (default
%                        <planner.out_dir>/lumen.stl)
%       .pixel_mm        override the spacing (default uses
%                        planner_result.D if present, else [1 1])
%       .slice_spacing_mm same
%       .reduce          decimation fraction (default 0.5)
%       .smooth_iters    Laplacian smoothing iterations (default 5)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        planner_result (1,1) struct
        opts           (1,1) struct = struct()
    end
    if ~isfield(opts, 'reduce');       opts.reduce       = 0.5; end
    if ~isfield(opts, 'smooth_iters'); opts.smooth_iters = 5;   end

    if ~isfield(planner_result, 'mask') || isempty(planner_result.mask)
        error('evar_plan:export_mesh:NoMask', ...
              'planner_result.mask is required for mesh export.');
    end
    mask = logical(planner_result.mask);

    if ~isfield(opts, 'out_path')
        if isfield(planner_result, 'out_dir') && ~isempty(planner_result.out_dir)
            opts.out_path = fullfile(planner_result.out_dir, 'lumen.stl');
        else
            error('evar_plan:export_mesh:NoOutPath', ...
                  'opts.out_path required when planner_result.out_dir is missing.');
        end
    end
    if ~isfield(opts, 'pixel_mm');         opts.pixel_mm = [1 1];       end
    if ~isfield(opts, 'slice_spacing_mm'); opts.slice_spacing_mm = 1;   end

    sz = size(mask);
    [Xmm, Ymm, Zmm] = meshgrid( ...
        (0:sz(2)-1) * opts.pixel_mm(2), ...
        (0:sz(1)-1) * opts.pixel_mm(1), ...
        (0:sz(3)-1) * opts.slice_spacing_mm);
    fv = isosurface(Xmm, Ymm, Zmm, single(mask), 0.5);

    % A non-empty but all-false (or single-voxel) mask yields no surface;
    % fail cleanly here rather than crashing downstream in the smoother.
    if isempty(fv.faces) || isempty(fv.vertices)
        error('evar_plan:export_mesh:EmptyMesh', ...
              'Mask has no surface to mesh (no foreground voxels).');
    end

    if opts.reduce > 0 && opts.reduce < 1
        fv = reducepatch(fv, opts.reduce);
    end
    if opts.smooth_iters > 0
        fv = laplacian_smooth(fv, opts.smooth_iters);
    end

    TR = triangulation(double(fv.faces), double(fv.vertices));
    stlwrite(TR, opts.out_path);

    info = struct( ...
        'out_path',      opts.out_path, ...
        'n_vertices',    size(fv.vertices, 1), ...
        'n_faces',       size(fv.faces, 1), ...
        'bytes_written', dir(opts.out_path).bytes);

    fprintf('[export_mesh] STL: %d verts, %d faces -> %s\n', ...
        info.n_vertices, info.n_faces, info.out_path);
end

function fv = laplacian_smooth(fv, iters)
    V = double(fv.vertices);
    F = double(fv.faces);
    nV = size(V, 1);
    E = [F(:, [1 2]); F(:, [2 3]); F(:, [3 1])];
    E = unique(sort(E, 2), 'rows');
    A = sparse([E(:,1); E(:,2)], [E(:,2); E(:,1)], 1, nV, nV);
    deg = max(sum(A, 2), 1);
    for k = 1:iters
        V = (A * V) ./ deg;
    end
    fv.vertices = V;
end
