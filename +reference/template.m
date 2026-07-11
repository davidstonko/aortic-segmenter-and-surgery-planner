function out_path = template(case_name, out_dir, opts)
%REFERENCE.TEMPLATE  Write a blank reference-annotation JSON template.
%
%   PATH = reference.template(CASE_NAME, OUT_DIR)
%   PATH = reference.template(CASE_NAME, OUT_DIR, OPTS)
%
%   OPTS:
%       .reference_tool   default 'TeraRecon Aquarius iNtuition'
%       .annotator        default '' (fill in before submitting)
%       .uncertainty_mm   default 1.0
%
%   Produces a pretty-printed JSON with every measurement field set to
%   `null` (=> NaN on load) so the annotator can fill in only the
%   measurements they have without breaking the schema check.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        case_name (1,:) char
        out_dir   (1,:) char
        opts      (1,1) struct = struct()
    end
    if ~isfield(opts, 'reference_tool'); opts.reference_tool = 'TeraRecon Aquarius iNtuition'; end
    if ~isfield(opts, 'annotator');      opts.annotator = ''; end
    if ~isfield(opts, 'uncertainty_mm'); opts.uncertainty_mm = 1.0; end

    if ~exist(out_dir, 'dir'); mkdir(out_dir); end
    sch = reference.schema();
    payload = struct();
    payload.schema_version = sch.schema_version;
    payload.case_name      = case_name;
    payload.reference_tool = opts.reference_tool;
    payload.annotator      = opts.annotator;
    payload.annotation_date = datestr(now, 'yyyy-mm-dd'); %#ok<DATST,TNOW1>
    payload.measurements   = struct();
    for k = 1:numel(sch.measurement_fields)
        payload.measurements.(sch.measurement_fields{k}) = NaN;
    end
    payload.notes          = '';
    payload.uncertainty_mm = opts.uncertainty_mm;

    out_path = fullfile(out_dir, sprintf('%s.ref.json', case_name));
    fid = fopen(out_path, 'w');
    cleanup = onCleanup(@() fclose(fid));
    fprintf(fid, '%s', jsonencode(payload, 'PrettyPrint', true));
end
