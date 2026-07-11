function ref = load(json_path)
%REFERENCE.LOAD  Read a reference-annotation JSON and validate the schema.
%
%   REF = reference.load(JSON_PATH)
%
%   On success, returns a struct with the fields described in
%   `reference.schema`. Throws an error if the file is missing, the JSON
%   is malformed, or the schema_version field is not supported. `null`
%   entries in `measurements` are converted to NaN.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        json_path (1,:) char
    end
    if ~isfile(json_path)
        error('reference:load:Missing', 'Reference JSON not found: %s', json_path);
    end
    txt = fileread(json_path);
    try
        raw = jsondecode(txt);
    catch ME
        error('reference:load:BadJSON', 'Could not parse %s: %s', json_path, ME.message);
    end
    sch = reference.schema();
    for k = 1:numel(sch.required_fields)
        f = sch.required_fields{k};
        if ~isfield(raw, f)
            error('reference:load:MissingField', ...
                'Required field "%s" missing from %s', f, json_path);
        end
    end
    if ~strcmp(raw.schema_version, sch.schema_version)
        error('reference:load:UnsupportedVersion', ...
            'Schema version %s in %s; loader expects %s', ...
            raw.schema_version, json_path, sch.schema_version);
    end

    % Normalize measurement struct: nulls (= empty) → NaN, ensure every
    % field exists so downstream code can assume the shape.
    m = raw.measurements;
    if ~isstruct(m); m = struct(); end
    for k = 1:numel(sch.measurement_fields)
        f = sch.measurement_fields{k};
        if ~isfield(m, f) || isempty(m.(f))
            m.(f) = NaN;
        end
    end
    raw.measurements = m;
    if ~isfield(raw, 'notes');          raw.notes = ''; end
    if ~isfield(raw, 'uncertainty_mm'); raw.uncertainty_mm = 1.0; end
    ref = raw;
end
