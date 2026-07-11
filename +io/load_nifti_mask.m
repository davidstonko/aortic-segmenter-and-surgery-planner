function mask = load_nifti_mask(path_in, target_size, label)
%IO.LOAD_NIFTI_MASK  Read a NIfTI segmentation back into a logical mask.
%
%   MASK = io.load_nifti_mask(PATH) reads PATH (.nii or .nii.gz) and
%   returns a logical mask. Multi-label NIfTIs are reduced with > 0;
%   pass LABEL to extract a specific integer label.
%
%   MASK = io.load_nifti_mask(PATH, TARGET_SIZE) verifies the volume
%   matches TARGET_SIZE (= size(D.vol)) and errors if not. We keep the
%   identity-affine convention so this should always pass when the
%   file came from io.save_nifti.
%
%   MASK = io.load_nifti_mask(PATH, TARGET_SIZE, LABEL) keeps only
%   voxels equal to LABEL. Used for TotalSegmentator outputs that have
%   one integer per organ in a single label volume.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        path_in     (1,:) char
        target_size double = []
        label       double = []
    end

    if ~exist(path_in, 'file')
        error('io:load_nifti_mask:NotFound', 'File not found: %s', path_in);
    end

    vol = niftiread(path_in);

    if isempty(label)
        mask = vol > 0;
    else
        mask = vol == label;
    end

    if ~isempty(target_size)
        if ~isequal(size(mask), target_size(:).')
            error('io:load_nifti_mask:SizeMismatch', ...
                'NIfTI size [%s] does not match target [%s]', ...
                num2str(size(mask)), num2str(target_size));
        end
    end

    mask = logical(mask);
end
