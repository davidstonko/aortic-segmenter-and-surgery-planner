function ranked = match_devices(meas, opts)
%IFU.MATCH_DEVICES  Rank all known stent grafts by IFU fit margin.
%
%   RANKED = ifu.match_devices(MEAS)
%   RANKED = ifu.match_devices(MEAS, OPTS)
%
%   Runs ifu.check_eligibility on every device returned by
%   ifu.devices() and returns a struct array sorted so eligible
%   devices come first (largest fit margin → smallest), followed by
%   ineligible devices (smallest violation → largest).
%
%   OPTS:
%       .devices       struct array to use (default: ifu.devices())
%       .only_eligible (false) — drop ineligible devices from output
%
%   The returned struct array has the device fields plus:
%       .eligibility   the full ifu.check_eligibility result

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        meas (1,1) struct
        opts (1,1) struct = struct()
    end
    if ~isfield(opts, 'devices');       opts.devices       = ifu.devices(); end
    if ~isfield(opts, 'only_eligible'); opts.only_eligible = false;          end

    n = numel(opts.devices);
    elig    = false(n, 1);
    margins = nan(n, 1);
    ranked  = repmat(addField(opts.devices(1), 'eligibility', struct()), n, 1);
    for k = 1:n
        dev = opts.devices(k);
        ec  = ifu.check_eligibility(meas, dev);
        ranked(k) = addField(dev, 'eligibility', ec);
        elig(k)    = ec.eligible;
        margins(k) = ec.min_margin;
    end

    if opts.only_eligible
        ranked  = ranked(elig);
        margins = margins(elig);
        elig    = elig(elig); %#ok<NASGU>
    end

    % Sort: eligibles first by largest margin (best fit), then
    % ineligibles by least-negative margin (closest to eligibility).
    if isempty(ranked); return; end
    [~, ix] = sortrows([~elig(:), -margins(:)]);  % eligible first, then by margin desc
    ranked = ranked(ix);
end

function s = addField(s, fname, val)
    s.(fname) = val;
end
