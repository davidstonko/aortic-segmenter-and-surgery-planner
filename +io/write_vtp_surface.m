function path_out = write_vtp_surface(mask, path_out, opts)
%IO.WRITE_VTP_SURFACE  Run marching cubes on a logical mask and write
%   the resulting triangulated surface as a .vtp file (the input format
%   VMTK's vmtkcenterlines expects).
%
%   PATH = io.write_vtp_surface(MASK, PATH)
%   PATH = io.write_vtp_surface(MASK, PATH, opts)
%
%   opts:
%       .pixel_mm           [dy dx]  scale row+col by these (default [1 1])
%       .slice_spacing_mm   scalar    scale z by this (default 1)
%       .smooth_iters       int       Laplacian smoothing passes
%                                     (default 5; 0 to skip)
%       .reduce             scalar    decimation fraction in [0,1]
%                                     (default 0; e.g. 0.5 keeps half)
%       .keep_largest_cc    logical   keep only the largest mesh CC of
%                                     the marching-cubes output (default
%                                     true). VMTK's seedpoint selector
%                                     snaps to the nearest surface vertex
%                                     — if the mesh has disconnected
%                                     fragments (small bone leaks, distal
%                                     vessel stubs), the seed can land on
%                                     a fragment and yield a degenerate
%                                     centerline.
%
%   The output VTP is in *millimeter* coordinates (so VMTK distances
%   come back in mm directly). We use MATLAB's built-in `isosurface`
%   for marching cubes, optional smoothing via `smoothpatch`-equivalent
%   Laplacian relaxation, and optional decimation via `reducepatch`.
%
%   This avoids any Python dependency on the MATLAB side.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        mask     logical
        path_out (1,:) char
        opts     (1,1) struct = struct()
    end

    if ~isfield(opts, 'pixel_mm');         opts.pixel_mm = [1 1]; end
    if ~isfield(opts, 'slice_spacing_mm'); opts.slice_spacing_mm = 1; end
    if ~isfield(opts, 'smooth_iters');     opts.smooth_iters = 5; end
    if ~isfield(opts, 'reduce');           opts.reduce = 0; end
    if ~isfield(opts, 'keep_largest_cc');  opts.keep_largest_cc = true; end

    % --- Marching cubes ----------------------------------------------
    % isosurface expects (X,Y,Z) grids; mask is (Y,X,Z). We give it
    % coordinate grids in millimeters so the output is in mm directly.
    sz = size(mask);
    [Xmm, Ymm, Zmm] = meshgrid( ...
        (0:sz(2)-1) * opts.pixel_mm(2), ...
        (0:sz(1)-1) * opts.pixel_mm(1), ...
        (0:sz(3)-1) * opts.slice_spacing_mm);
    fv = isosurface(Xmm, Ymm, Zmm, single(mask), 0.5);

    % --- Keep largest mesh CC (default ON) ---------------------------
    if opts.keep_largest_cc && ~isempty(fv.vertices)
        fv = keep_largest_mesh_cc(fv);
    end

    % --- Optional decimation -----------------------------------------
    if opts.reduce > 0 && opts.reduce < 1
        fv = reducepatch(fv, opts.reduce);
    end

    % --- Optional Laplacian smoothing --------------------------------
    if opts.smooth_iters > 0
        fv = laplacian_smooth(fv, opts.smooth_iters);
    end

    % --- Write VTP ----------------------------------------------------
    [p, ~, ~] = fileparts(path_out);
    if ~isempty(p) && ~exist(p, 'dir'); mkdir(p); end
    fid = fopen(path_out, 'w');
    if fid < 0
        error('io:write_vtp_surface:Open', 'Cannot open %s for writing', path_out);
    end
    cleanup = onCleanup(@() fclose(fid));

    nP = size(fv.vertices, 1);
    nC = size(fv.faces, 1);

    fprintf(fid, '<?xml version="1.0"?>\n');
    fprintf(fid, '<VTKFile type="PolyData" version="0.1" byte_order="LittleEndian">\n');
    fprintf(fid, '  <PolyData>\n');
    fprintf(fid, '    <Piece NumberOfPoints="%d" NumberOfVerts="0" ', nP);
    fprintf(fid, 'NumberOfLines="0" NumberOfStrips="0" NumberOfPolys="%d">\n', nC);
    % Points
    fprintf(fid, '      <Points>\n');
    fprintf(fid, '        <DataArray type="Float32" NumberOfComponents="3" format="ascii">\n');
    fprintf(fid, '          %.4f %.4f %.4f\n', fv.vertices.');
    fprintf(fid, '        </DataArray>\n');
    fprintf(fid, '      </Points>\n');
    % Polys (triangles)
    conn = fv.faces.' - 1;     % VTK is 0-indexed
    fprintf(fid, '      <Polys>\n');
    fprintf(fid, '        <DataArray type="Int32" Name="connectivity" format="ascii">\n');
    fprintf(fid, '          %d %d %d\n', conn);
    fprintf(fid, '        </DataArray>\n');
    fprintf(fid, '        <DataArray type="Int32" Name="offsets" format="ascii">\n');
    fprintf(fid, '          %d\n', (3:3:3*nC).');
    fprintf(fid, '        </DataArray>\n');
    fprintf(fid, '      </Polys>\n');
    fprintf(fid, '    </Piece>\n');
    fprintf(fid, '  </PolyData>\n');
    fprintf(fid, '</VTKFile>\n');
end

% =========================================================================
function fv = keep_largest_mesh_cc(fv)
%KEEP_LARGEST_MESH_CC  Drop every triangle that isn't in the largest
%   connected component of the mesh edge graph. Stops VMTK's seedpoint
%   selector from snapping to a tiny disconnected fragment of the
%   marching-cubes output (a known cause of degenerate centerlines —
%   see goal #18 in GOALS.md).
    V = fv.vertices;
    F = fv.faces;
    nV = size(V, 1);
    if nV == 0; return; end
    E = [F(:, [1 2]); F(:, [2 3]); F(:, [3 1])];
    A = sparse([E(:,1); E(:,2)], [E(:,2); E(:,1)], 1, nV, nV);
    G = graph(A);
    bins = conncomp(G);
    if max(bins) < 2; return; end       % single CC already
    sizes = accumarray(bins(:), 1);
    [~, kbig] = max(sizes);
    keep_vert = bins == kbig;
    keep_face = all(keep_vert(F), 2);
    F = F(keep_face, :);
    % Compact vertex indexing
    [used, ~, ic] = unique(F(:));
    V = V(used, :);
    F = reshape(ic, size(F));
    fv.vertices = V;
    fv.faces = F;
end

% =========================================================================
function fv = laplacian_smooth(fv, iters)
%LAPLACIAN_SMOOTH  Uniform-weight Laplacian relaxation. Each vertex is
%   replaced by the mean of its neighbors (across the mesh edge graph)
%   per iteration. Preserves topology, slightly shrinks the mesh.
    V = double(fv.vertices);
    F = double(fv.faces);
    nV = size(V, 1);
    % Build sparse adjacency from edges of the triangle mesh
    E = [F(:, [1 2]); F(:, [2 3]); F(:, [3 1])];
    E = unique(sort(E, 2), 'rows');
    A = sparse([E(:,1); E(:,2)], [E(:,2); E(:,1)], 1, nV, nV);
    deg = max(sum(A, 2), 1);
    for k = 1:iters
        V = (A * V) ./ deg;
    end
    fv.vertices = V;
end
