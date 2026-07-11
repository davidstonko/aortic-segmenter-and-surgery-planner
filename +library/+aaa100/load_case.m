function c = load_case(case_id)
%LIBRARY.AAA100.LOAD_CASE  Load a single AAA-100 case by ID.
%
%   c = library.aaa100.load_case('AAA001')
%
%   Returns the struct described in library.aaa100.load_all for the
%   single requested case_id. Errors if the case_id is not in the
%   cohort.

%   Project: AINN/EVAR (Phase 3)
%   Author : David P. Stonko

    arguments
        case_id (1,:) char
    end
    cases = library.aaa100.load_all();
    ids = {cases.case_id};
    k = find(strcmp(ids, case_id));
    if isempty(k)
        error('library:aaa100:unknown_case', ...
            'Case "%s" not found among %d AAA-100 cases.', case_id, numel(cases));
    end
    c = cases(k);
end
