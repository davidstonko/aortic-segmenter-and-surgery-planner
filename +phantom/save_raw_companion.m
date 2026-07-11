function out_path = save_raw_companion(name_or_path, lib_root)
%PHANTOM.SAVE_RAW_COMPANION  Write a label-stripped "_raw" companion of
%   a phantom case file. The raw file contains the synthetic CT and the
%   spatial metadata only — no mask, no centerlines, no seeds, no
%   landmarks. Pair it with the original file so a user can:
%
%     1. Open the raw phantom in the GUI (Step 1 → "Open phantom") and
%        work the case from scratch (segment / seed / centerline /
%        analyze).
%     2. Compare their answer against the labeled answer-key by loading
%        the original .mat directly.
%
%   OUT_PATH = phantom.save_raw_companion(NAME)
%   OUT_PATH = phantom.save_raw_companion(NAME, LIB_ROOT)
%
%   NAME may be a bare phantom name like 'PHANTOM_aaa_male', or a full
%   path to the labeled .mat. The companion file is written next to it
%   with the suffix '_raw.mat'.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        name_or_path (1,:) char
        lib_root     (1,:) char = ''
    end

    % --- Resolve the input path -----------------------------
    P = phantom.load_from_library(name_or_path);
    in_path = which_phantom_file(name_or_path, lib_root);

    % --- Strip labels --------------------------------------
    raw = struct();
    must_keep = {'pixel_mm', 'slice_spacing_mm'};
    for k = 1:numel(must_keep)
        if isfield(P, must_keep{k}); raw.(must_keep{k}) = P.(must_keep{k}); end
    end
    if isfield(P, 'is_volume'); raw.is_volume = P.is_volume; end
    if isfield(P, 'dicom_meta'); raw.dicom_meta = P.dicom_meta; end
    % vol is INTENTIONALLY NOT stored — phantom.load_from_library
    % rehydrates it from the mask. But the raw companion has no mask
    % (that's the whole point). So we DO need to write the volume.
    if isfield(P, 'vol') && ~isempty(P.vol)
        vol = P.vol;
    elseif isfield(P, 'mask')
        vol = phantom.synth_ct_from_mask(logical(P.mask));
    else
        error('phantom:save_raw_companion:NoVol', ...
            'Source phantom has neither .vol nor .mask — cannot build raw.');
    end
    % Synthetic CT HU range comfortably fits int16 — store at half the
    % byte cost of single, with -v7.3's HDF5 deflate giving ~6× more
    % compression (256³ single ≈ 80 MB; int16+deflate ≈ 8–12 MB).
    raw.vol         = int16(round(vol));
    raw.vol_dtype   = 'int16';
    raw.app_version = '1.1.0';
    raw.raw_phantom = true;
    raw.source_file = in_path;

    % --- Build output path --------------------------------
    [folder, base, ~] = fileparts(in_path);
    if endsWith(base, '_raw')
        error('phantom:save_raw_companion:AlreadyRaw', ...
            'Input %s already looks like a raw companion.', in_path);
    end
    out_path = fullfile(folder, [base, '_raw.mat']);

    save(out_path, '-struct', 'raw', '-v7.3');
end

% =========================================================================
function p = which_phantom_file(name_or_path, lib_root)
    if exist(name_or_path, 'file')
        p = name_or_path; return;
    end
    if isempty(lib_root)
        here = fileparts(mfilename('fullpath'));
        lib_root = fullfile(fileparts(here), 'library');
    end
    if endsWith(lower(name_or_path), '.mat')
        p = fullfile(lib_root, name_or_path);
    else
        p = fullfile(lib_root, [name_or_path '.mat']);
    end
    if ~exist(p, 'file')
        error('phantom:save_raw_companion:NotFound', ...
            'Could not find phantom file: %s', name_or_path);
    end
end
