function path_out = save_nifti(D, path_out, opts)
%IO.SAVE_NIFTI  Write a CT volume struct (or any 3-D array) as a .nii.gz.
%
%   PATH = io.save_nifti(D, PATH) writes the volume D.vol to a NIfTI
%   file at PATH using D.pixel_mm and D.slice_spacing_mm for voxel
%   sizes. The orientation is set to LPS (DICOM-standard) which is
%   what TotalSegmentator and VMTK expect.
%
%   PATH = io.save_nifti(VOL, PATH, opts) writes a bare 3-D array. opts:
%       .pixel_mm           [dy dx]  default [1 1]
%       .slice_spacing_mm   scalar   default 1
%       .datatype           'single'|'int16'|'uint8'  default infer from VOL
%
%   We always emit a voxel-aligned identity-affine image. The downstream
%   tools (TotalSegmentator, vmtkmarchingcubes, etc.) re-discover the
%   geometry from the header. Round-tripping the mask back into MATLAB
%   reuses the same identity grid, so voxel indices line up exactly.
%
%   This avoids the patient-coordinate complexity entirely: we work in
%   voxel space inside MATLAB and let the NIfTI header carry the
%   spacing only. If you ever need true patient-coordinate alignment
%   (e.g., for fusion with another modality), add an Affine override.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D
        path_out (1,:) char
        opts (1,1) struct = struct()
    end

    % --- Resolve volume + spacing from struct or array input ---------
    if isstruct(D)
        vol = D.vol;
        if isfield(D, 'pixel_mm');         pix = D.pixel_mm;
        else;                              pix = [1 1];        end
        if isfield(D, 'slice_spacing_mm'); ssp = D.slice_spacing_mm;
        else;                              ssp = 1;            end
    else
        vol = D;
        if isfield(opts, 'pixel_mm');         pix = opts.pixel_mm;
        else;                                 pix = [1 1];     end
        if isfield(opts, 'slice_spacing_mm'); ssp = opts.slice_spacing_mm;
        else;                                 ssp = 1;         end
    end
    if isfield(opts, 'datatype'); dt = opts.datatype;
    else; dt = '';
    end

    % --- Cast to a NIfTI-friendly type --------------------------------
    if isempty(dt)
        switch class(vol)
            case 'logical';                   dt = 'uint8';
            case {'single','double'};         dt = 'single';
            case {'int8','int16','int32'};    dt = 'int16';
            case {'uint8','uint16','uint32'}; dt = 'uint8';
            otherwise;                        dt = 'single';
        end
    end
    vol_out = cast(vol, dt);
    if islogical(vol);   vol_out = uint8(vol);   end

    % --- Ensure path has the right extension --------------------------
    [p, f, e] = fileparts(path_out);
    if isempty(e) || strcmpi(e, '.gz')
        if ~strcmpi(e, '.gz') && ~endsWith(f, '.nii')
            path_out = fullfile(p, [f '.nii.gz']);
        end
    end
    if ~isempty(p) && ~exist(p, 'dir'); mkdir(p); end

    % --- Write ------------------------------------------------------
    % niftiwrite in modern MATLAB requires a complete Info struct OR
    % none at all. We write with default Info first (which infers
    % ImageSize, Datatype, etc. from the array), then patch in the
    % spacing via niftiinfo + rewrite. This is the most robust path
    % across releases (R2017b+ all support it).
    base = path_out;
    if endsWith(lower(path_out), '.nii.gz')
        base = path_out(1:end-3);   % niftiwrite wants .nii in the name
    end
    if endsWith(lower(base), '.nii')
        base = base(1:end-4);       % niftiwrite appends .nii itself
    end

    % First pass — uncompressed scratch write so we can pull a valid
    % Info struct off the file.
    niftiwrite(vol_out, base);
    info = niftiinfo([base '.nii']);
    % VoxelSize is [dx dy dz] in NIfTI convention; our pix is [dy dx].
    info.PixelDimensions = [pix(2), pix(1), ssp];
    info.SpaceUnits      = 'Millimeter';
    info.TimeUnits       = 'None';
    info.Description     = sprintf('AINN/EVAR phase 3 (%s)', ...
                                   datestr(now, 'yyyy-mm-ddTHH:MM:SS')); %#ok<DATST,TNOW1>
    % Final write — recompresses if requested
    if endsWith(lower(path_out), '.nii.gz')
        niftiwrite(vol_out, base, info, 'Compressed', true);
        if exist([base '.nii'], 'file'); delete([base '.nii']); end
    else
        niftiwrite(vol_out, base, info);
    end
end
