function [suspect, msg] = orientation_is_suspect(seeds, craniocaudal_known)
%ORIENTATION_IS_SUSPECT  Femorals-at-bottom orientation invariant (#36).
%
%   [SUSPECT, MSG] = autoseg.orientation_is_suspect(SEEDS)
%   [SUSPECT, MSG] = autoseg.orientation_is_suspect(SEEDS, CRANIOCAUDAL_KNOWN)
%
%   The pipeline stores the volume cranial-first (slice 1 = patient head,
%   increasing slice index = caudal), so the femoral / common-femoral
%   (CFA) endpoints MUST sit at a HIGHER slice index than the suprarenal
%   proximal seed — the femorals belong at the BOTTOM of the screen. If
%   they don't, the slice order is flipped (e.g. an InstanceNumber-only
%   series the loader could not orient from DICOM position tags), and the
%   femorals would render at the top. This is the silent failure mode
%   behind the visceral-band mis-detection on tag-less real series.
%
%   SEEDS is the struct from preprocess.auto_seeds_anatomic with fields
%   .proximal, .right_cfa, .left_cfa, each a [y x z] voxel coordinate.
%   CRANIOCAUDAL_KNOWN (default true) is D.craniocaudal_known — when
%   false the message notes the direction couldn't be verified from
%   metadata, which makes a suspect result much more likely to be a real
%   flip than a borderline anatomy.
%
%   Returns SUSPECT (logical) and a human-readable MSG ('' when not
%   suspect).

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        seeds (1,1) struct
        craniocaudal_known (1,1) logical = true
    end

    prox_z = seeds.proximal(3);
    cfa_z  = max(seeds.right_cfa(3), seeds.left_cfa(3));
    suspect = cfa_z <= prox_z;

    if suspect
        extra = '';
        if ~craniocaudal_known
            extra = ' (craniocaudal direction not verifiable from DICOM position tags)';
        end
        msg = sprintf(['orientation suspect: femoral seeds (z=%d) are not caudal to ' ...
            'the proximal seed (z=%d); the femorals should be at the bottom of the ' ...
            'screen. Series may be flipped%s.'], cfa_z, prox_z, extra);
    else
        msg = '';
    end
end
