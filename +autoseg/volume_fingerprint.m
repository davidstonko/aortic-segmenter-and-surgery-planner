function fp = volume_fingerprint(D)
%AUTOSEG.VOLUME_FINGERPRINT  Content fingerprint of a CT volume, for
%   disk-cache keys.
%
%   FP = autoseg.volume_fingerprint(D)
%
%   Returns a 32-char hex MD5 over the volume's size, voxel spacing, and
%   three content checksums (full sum, strided sum, and a position-weighted
%   strided sum — so a flipped/permuted volume with the same values still
%   differs). Every per-scan cache (TotalSegmentator labels, branch
%   detection) must include this: keying on size + spacing alone lets two
%   different scans acquired on the same protocol share a cached
%   segmentation, and everything downstream then runs on the wrong
%   anatomy.
%
%   Cost: one pass over the volume (sum in double without copying it).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        D (1,1) struct
    end
    v  = D.vol;
    n  = numel(v);
    s1 = mod(sum(v(:), 'double'), 2^53 - 1);
    s2 = mod(sum(v(1:97:end), 'double'), 2^53 - 1);
    idx = (1:9973:n).';
    s3 = mod(sum(double(v(idx)) .* double(mod(idx, 65521))), 2^53 - 1);
    key = struct('sz', size(v), 's1', s1, 's2', s2, 's3', s3, ...
        'pix', double(D.pixel_mm(:)'), 'ssp', double(D.slice_spacing_mm));
    md = java.security.MessageDigest.getInstance('MD5');
    hb = typecast(md.digest(uint8(jsonencode(key))), 'uint8');
    fp = lower(reshape(dec2hex(hb, 2)', 1, []));
end
