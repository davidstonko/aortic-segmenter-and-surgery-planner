function [usable, summary] = qc_summary(qc)
%AUTOSEG.QC_SUMMARY  Aggregate the per-check QC flags on a planner result
%   into a single usability verdict + a one-line human-readable summary.
%
%   [USABLE, SUMMARY] = autoseg.qc_summary(QC)
%
%   USABLE is false when ANY hard check failed — segmentation incomplete,
%   orientation suspect (femorals not caudal), or an implausibly short
%   centerline (segmentation did not connect aorta to the iliacs). In that
%   state the auto sizing must NOT be trusted, and downstream code (the
%   plan text, a batch summary, the GUI) should say so rather than present
%   confident-looking numbers derived from a degenerate centerline.
%
%   Missing flags are treated as "did not fail", so this is safe to call on
%   a partial QC struct. Unknown extra fields are ignored.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        qc (1,1) struct
    end

    checks = { ...
        'segmentation_incomplete', 'segmentation incomplete (a mask-extension step failed)'; ...
        'orientation_suspect',     'orientation suspect (femorals not caudal to the proximal seed)'; ...
        'centerline_implausible',  'centerline implausibly short (aorta not connected to the iliacs)'};

    failed = {};
    for i = 1:size(checks, 1)
        f = checks{i, 1};
        if isfield(qc, f) && ~isempty(qc.(f)) && qc.(f)
            failed{end + 1} = checks{i, 2}; %#ok<AGROW>
        end
    end

    usable = isempty(failed);
    if usable
        summary = 'QC OK — segmentation and centerline checks passed.';
    else
        summary = sprintf('QC FAILED — %s. Auto sizing must not be trusted.', ...
            strjoin(failed, '; '));
    end
end
