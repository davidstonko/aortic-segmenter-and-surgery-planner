function root = cache_root()
%LIBRARY.AAA100.CACHE_ROOT  Path to the local AAA-100 cache.
%
%   root = library.aaa100.cache_root()
%
%   Returns the absolute path to the folder containing centerlines.zip /
%   meshes.zip / aaa100_centerlines.mat. The default is sibling to the
%   project root (alongside the JohnDoe1 EVAR folder), matching the layout
%   the user already has for other DICOM datasets.
%
%   Override with the environment variable AAA100_CACHE_ROOT for
%   alternate disks or shared caches.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    env_val = getenv('AAA100_CACHE_ROOT');
    if ~isempty(env_val)
        root = env_val;
        return;
    end
    proj_root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    parent = fileparts(proj_root);  % /Vascular Mathematical Modeling
    root = fullfile(parent, 'AAA-100');
end
