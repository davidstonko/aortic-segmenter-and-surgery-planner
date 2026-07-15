function root = data_root()
%LIBRARY.AORTASEG24.DATA_ROOT  Path to the locally-downloaded AortaSeg cohort.
%
%   root = library.aortaseg24.data_root()
%
%   Returns the folder that holds the downloaded AortaSeg24 (or compatible
%   "aortaseg*") cases. The dataset is CC-BY-NC and is NEVER redistributed
%   with this repo — you download it yourself (grand-challenge.org data-use
%   agreement) and point this at it.
%
%   Expected layout under the root (one sub-folder per case; the loader is
%   tolerant of the common AortaSeg naming variants):
%       <root>/
%         subS0001/  subS0001_CTA.nrrd|.nii.gz   subS0001.seg.nrrd|_label.nii.gz
%         subS0002/  ...
%   or a flat pair of NIfTIs per case. `library.aortaseg24.list_cases`
%   discovers whatever pairs it finds.
%
%   Override with the AORTASEG24_DATA_ROOT environment variable (for an
%   alternate disk or a shared cache). Default is a sibling of the project
%   root, matching the AAA-100 layout.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    env_val = getenv('AORTASEG24_DATA_ROOT');
    if ~isempty(env_val)
        root = env_val;
        return;
    end
    proj_root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    parent = fileparts(proj_root);   % /Vascular Mathematical Modeling
    root = fullfile(parent, 'AortaSeg24');
end
