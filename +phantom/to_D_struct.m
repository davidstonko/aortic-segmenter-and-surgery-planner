function D = to_D_struct(P, opts)
%PHANTOM.TO_D_STRUCT  Convert a phantom case-struct into the same shape
%   that preprocess.dicom_load returns, so the GUI can ingest a phantom
%   the same way it ingests a real CT.
%
%   D = phantom.to_D_struct(P)
%   D = phantom.to_D_struct(P, opts)
%
%   Inputs
%       P     phantom struct (from phantom.load_from_library or one of
%             the phantom.build_* builders). Must contain at least
%             .vol, .pixel_mm, .slice_spacing_mm.
%       opts  optional struct:
%           .strip_labels   true (default) → drop centerline / mask /
%                           seeds / landmarks. Use this when the user
%                           wants the GUI to work the case from
%                           scratch as if the phantom were unlabeled.
%
%   Output D mirrors preprocess.dicom_load:
%       .vol, .pixel_mm, .slice_spacing_mm, .slice_z_mm,
%       .is_volume, .patient_id, .study_date, .series_description.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        P    (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'strip_labels'); opts.strip_labels = true; end

    must = {'vol', 'pixel_mm', 'slice_spacing_mm'};
    for k = 1:numel(must)
        if ~isfield(P, must{k})
            error('phantom:to_D_struct:Missing', ...
                'Phantom struct missing required field "%s".', must{k});
        end
    end

    sz = size(P.vol);
    D = struct();
    D.vol              = P.vol;
    D.pixel_mm         = P.pixel_mm;
    D.slice_spacing_mm = P.slice_spacing_mm;
    D.slice_z_mm       = ((1:sz(3)) - 1)' * P.slice_spacing_mm;
    D.is_volume        = true;
    % Phantom builders use the convention voxel z=1 = most superior
    % slice already, so the GUI's auto-flip path should leave this
    % alone. The flag tells doLoad: do not flip me.
    D.z_normalized     = true;

    % Pull DICOM-style metadata from the embedded .dicom_meta if present
    if isfield(P, 'dicom_meta') && isstruct(P.dicom_meta)
        meta = P.dicom_meta;
        D.patient_id         = field_or(meta, 'patient_id',  'PHANTOM');
        D.study_date         = field_or(meta, 'study_date',  '2026-01-01');
        D.series_description = field_or(meta, 'series',      'phantom-CT');
    else
        D.patient_id         = 'PHANTOM';
        D.study_date         = '2026-01-01';
        D.series_description = 'phantom-CT';
    end

    % Stripping labels gives a "raw" phantom — what the GUI sees when
    % the user wants to work the case from scratch. Keeping them is
    % only useful for diagnostic/loading workflows that compare against
    % the answer key.
    if ~opts.strip_labels
        for fn = {'mask','Pv_mm','R_mm','Pv_mm_right','R_mm_right', ...
                  'Pv_mm_left','R_mm_left','bifurc_node_right', ...
                  'seeds_vox','landmarks'}
            f = fn{1};
            if isfield(P, f); D.(f) = P.(f); end
        end
    end
end

% =========================================================================
function v = field_or(s, name, default)
    if isfield(s, name) && ~isempty(s.(name)); v = s.(name);
    else;                                        v = default;
    end
end
