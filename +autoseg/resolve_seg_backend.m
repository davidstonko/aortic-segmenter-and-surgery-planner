function [backend, info] = resolve_seg_backend(requested)
%AUTOSEG.RESOLVE_SEG_BACKEND  Pick the concrete segmentation backend for a
%   planner run — the segmentation-side analogue of the centerline-backend
%   selector.
%
%   [BACKEND, INFO] = autoseg.resolve_seg_backend(REQUESTED)
%
%   REQUESTED (case-insensitive; aliases accepted):
%     'auto'                          — learned nnU-Net if weights are
%                                       present, else TotalSegmentator.
%     'totalsegmentator' | 'ts'       — the heuristic TS pipeline (default).
%     'learned' | 'aortaseg24' | 'nnunet'
%                                     — the aortaseg24 nnU-Net backend
%                                       (errors cleanly without weights).
%     'external' | 'precomputed' | 'byo' | 'mask'
%                                     — adopt a caller-supplied pipeline-
%                                       scheme label NIfTI (e.g. a Set-A
%                                       annotation mask); no model needed.
%
%   Returns BACKEND ∈ {'totalsegmentator','learned','external'} (never
%   'auto' — it is resolved here) and INFO:
%     .requested          the normalized request string
%     .canonical          canonical form before auto-resolution
%     .backend            the resolved backend (== BACKEND)
%     .learned_available  logical — is the learned nnU-Net runnable now?
%     .learned_reason     human-readable availability reason
%
%   Probing learned availability never throws — `auto` degrades to TS if
%   the aortaseg24 backend can't be interrogated.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        requested (1,:) char = 'totalsegmentator'
    end

    req = lower(strtrim(requested));
    switch req
        case {'ts', 'totalseg', 'totalsegmentator'}
            canon = 'totalsegmentator';
        case {'learned', 'aortaseg24', 'nnunet'}
            canon = 'learned';
        case {'external', 'precomputed', 'byo', 'mask'}
            canon = 'external';
        case 'auto'
            canon = 'auto';
        otherwise
            error('autoseg:resolve_seg_backend:BadBackend', ...
                ['seg_backend must be ''auto'', ''totalsegmentator'', ' ...
                 '''learned'', or ''external''; got ''%s''.'], requested);
    end

    info = struct('requested', req, 'canonical', canon, ...
                  'backend', '', 'learned_available', false, ...
                  'learned_reason', '');

    % Best-effort probe of the learned backend (honest about weights).
    try
        d = autoseg.aortaseg24.detect();
        info.learned_available = logical(d.available);
        if d.available
            info.learned_reason = 'ready';
        elseif isfield(d, 'error') && ~isempty(d.error)
            info.learned_reason = d.error;
        else
            info.learned_reason = 'unavailable';
        end
    catch ME
        info.learned_reason = ME.message;
    end

    if strcmp(canon, 'auto')
        if info.learned_available
            backend = 'learned';
        else
            backend = 'totalsegmentator';
        end
    else
        backend = canon;
    end
    info.backend = backend;
end
