function ids = list_cases()
%LIBRARY.AAA100.LIST_CASES  Return the case IDs available in the cache.
%
%   ids = library.aaa100.list_cases()
%
%   Returns a cellstr of 'AAA001' .. 'AAA100' for cases present in the
%   loaded MAT. Convenient for iterating over the cohort:
%
%       for c = library.aaa100.list_cases()
%           x = library.aaa100.load_case(c{1});
%           ...
%       end

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    cases = library.aaa100.load_all();
    ids = {cases.case_id};
end
