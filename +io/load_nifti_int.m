function vol = load_nifti_int(path_in, target_size)
%IO.LOAD_NIFTI_INT  Read a NIfTI label volume as integer array.
%
%   VOL = io.load_nifti_int(PATH) reads PATH (.nii or .nii.gz) and
%   returns the underlying integer label volume (uint8 / uint16 /
%   int16 — whatever niftiread returns).
%
%   VOL = io.load_nifti_int(PATH, TARGET_SIZE) verifies the volume
%   matches TARGET_SIZE (= size(D.vol)) and errors if not. Used for
%   TotalSegmentator multilabel outputs (`-ml` flag) where each
%   voxel's value is the class id (1..117 for the 'total' task).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        path_in     (1,:) char
        target_size double = []
    end

    if ~exist(path_in, 'file')
        error('io:load_nifti_int:NotFound', 'File not found: %s', path_in);
    end

    vol = niftiread(path_in);

    if ~isempty(target_size)
        if ~isequal(size(vol), target_size(:).')
            error('io:load_nifti_int:SizeMismatch', ...
                'NIfTI size [%s] does not match target [%s]', ...
                num2str(size(vol)), num2str(target_size));
        end
    end
end
