function out = read_vtp_polyline(path_in)
%IO.READ_VTP_POLYLINE  Read a VMTK centerline VTP into MATLAB structures.
%
%   OUT = io.read_vtp_polyline(PATH) parses the .vtp file written by
%   vmtkcenterlines and returns a struct:
%       out.points     N×3 vertex coordinates in mm
%       out.lines      cell array, each entry is a 1×K vector of
%                      0-based vertex indices defining one polyline
%       out.radii      N×1 maximum-inscribed-sphere radius at each
%                      vertex (the MaximumInscribedSphereRadius point
%                      data array). NaN for vertices missing the field.
%
%   We hand-parse the XML rather than depend on external readers — VMTK
%   centerlines are small (kilobytes) and the format is stable.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    if ~exist(path_in, 'file')
        error('io:read_vtp_polyline:NotFound', 'File not found: %s', path_in);
    end
    txt = fileread(path_in);

    out = struct('points', zeros(0,3), 'lines', {{}}, 'radii', zeros(0,1));

    % --- <Points> Float32 NumberOfComponents="3" ---------------------
    pts = parse_data_array(txt, 'Points');
    if isempty(pts)
        error('io:read_vtp_polyline:NoPoints', 'No <Points> block found.');
    end
    out.points = reshape(pts, 3, []).';

    % --- <Lines> connectivity + offsets ------------------------------
    [conn, offs] = parse_lines(txt);
    if ~isempty(conn) && ~isempty(offs)
        out.lines = cell(numel(offs), 1);
        cursor = 1;
        for i = 1:numel(offs)
            out.lines{i} = conn(cursor : offs(i)).';   % 0-based indices
            cursor = offs(i) + 1;
        end
    end

    % --- <PointData> MaximumInscribedSphereRadius --------------------
    r = parse_named_array(txt, 'MaximumInscribedSphereRadius');
    if isempty(r)
        out.radii = nan(size(out.points, 1), 1);
    else
        out.radii = r(:);
    end
end

% =========================================================================
function v = parse_data_array(txt, section_name)
%PARSE_DATA_ARRAY  Extract the first <DataArray> inside a named section.
    pat = sprintf('<%s>(.*?)</%s>', section_name, section_name);
    tok = regexp(txt, pat, 'tokens', 'once');
    v = [];
    if isempty(tok); return; end
    inner = tok{1};
    arr = regexp(inner, '<DataArray[^>]*>(.*?)</DataArray>', 'tokens', 'once');
    if isempty(arr); return; end
    v = sscanf(arr{1}, '%f');
end

function [conn, offs] = parse_lines(txt)
    conn = []; offs = [];
    sec = regexp(txt, '<Lines>(.*?)</Lines>', 'tokens', 'once');
    if isempty(sec); return; end
    inner = sec{1};
    c = regexp(inner, '<DataArray[^>]*Name="connectivity"[^>]*>(.*?)</DataArray>', ...
               'tokens', 'once');
    o = regexp(inner, '<DataArray[^>]*Name="offsets"[^>]*>(.*?)</DataArray>', ...
               'tokens', 'once');
    if ~isempty(c); conn = sscanf(c{1}, '%d'); end
    if ~isempty(o); offs = sscanf(o{1}, '%d'); end
end

function v = parse_named_array(txt, name)
    pat = sprintf('<DataArray[^>]*Name="%s"[^>]*>(.*?)</DataArray>', name);
    tok = regexp(txt, pat, 'tokens', 'once');
    v = [];
    if isempty(tok); return; end
    v = sscanf(tok{1}, '%f');
end
