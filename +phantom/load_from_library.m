function out = load_from_library(path_or_name)
%PHANTOM.LOAD_FROM_LIBRARY  Load a saved phantom case file and rehydrate
%   the synthetic CT volume.
%
%   OUT = phantom.load_from_library(PATH_OR_NAME)
%
%   Library phantoms ship without the `vol` field to keep the repo
%   small (a 256×256×320 single CT is ~80 MB; the mask + centerlines
%   are ~1–3 MB after compression). This loader re-runs
%   phantom.synth_ct_from_mask on the saved mask to recreate the
%   synthetic CT, and returns a struct in the same shape that
%   phantom.build_normal_male() / build_aaa_male() return.
%
%   PATH_OR_NAME can be:
%       - An absolute or relative path to a .mat file
%       - A bare phantom name like 'PHANTOM_aaa_male' (we look it up
%         in <project>/library/)

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        path_or_name (1,:) char
    end

    % Resolve to a file path
    p = path_or_name;
    if ~exist(p, 'file')
        % Try library/ relative to this package
        here = fileparts(mfilename('fullpath'));
        lib  = fullfile(fileparts(here), 'library');
        if ~endsWith(lower(path_or_name), '.mat')
            p = fullfile(lib, [path_or_name '.mat']);
        else
            p = fullfile(lib, path_or_name);
        end
    end
    if ~exist(p, 'file')
        error('phantom:load_from_library:NotFound', ...
            'Could not find phantom: %s', path_or_name);
    end

    out = load(p);
    % A "raw" phantom companion (suffix _raw.mat) intentionally has NO
    % mask — it carries the synthetic CT and spatial metadata only, so
    % the user can work the case from scratch. Labeled phantoms ship
    % without .vol (rehydrated here from .mask) to keep the repo small.
    is_raw = isfield(out, 'raw_phantom') && out.raw_phantom;
    if is_raw
        if ~isfield(out, 'vol') || isempty(out.vol)
            error('phantom:load_from_library:BadRawFile', ...
                'Raw phantom %s has no .vol field.', p);
        end
        % Raw phantoms ship as int16 to halve file size; the rest of
        % the codebase expects single-precision so the receiver doesn't
        % have to know the storage format.
        if ~isa(out.vol, 'single')
            out.vol = single(out.vol);
        end
    else
        if ~isfield(out, 'mask')
            error('phantom:load_from_library:BadFile', ...
                'Phantom file missing "mask" field: %s', p);
        end
        % Re-hydrate the synthetic CT if not stored
        if ~isfield(out, 'vol') || isempty(out.vol)
            out.vol = phantom.synth_ct_from_mask(logical(out.mask));
        end
    end
    out.is_volume = true;
end
