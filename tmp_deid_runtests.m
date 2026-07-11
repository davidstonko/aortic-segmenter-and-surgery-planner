% TMP_DEID_RUNTESTS  Temp script: run non-GUI regression suite, write summary.
projRoot = '/Users/davidstonko/Documents/Claude/Projects/Vascular Mathematical Modeling/phase-3-real-EVAR';
cd(projRoot); addpath(projRoot);
summaryFile = '/private/tmp/deid_summary.txt';
flagFile    = '/private/tmp/deid_run_done.flag';
if isfile(flagFile), delete(flagFile); end
if isfile(summaryFile), delete(summaryFile); end

suite = matlab.unittest.TestSuite.fromFolder(fullfile(projRoot,'tests'));
names = {suite.Name};
keep = ~contains(names,'test_gui_mode_toggle') & ~contains(names,'test_session_features');
suite = suite(keep);

results = run(suite);

nTot  = numel(results);
nPass = sum([results.Passed]);
nFail = sum([results.Failed]);
nInc  = sum([results.Incomplete]);

fid = fopen(summaryFile,'w');
fprintf(fid,'TOTAL %d PASSED %d FAILED %d INCOMPLETE %d\n', nTot, nPass, nFail, nInc);
failNames = {results([results.Failed]).Name};
fprintf(fid,'FAILED_LIST: %s\n', strjoin(failNames, ' | '));
incNames = {results([results.Incomplete]).Name};
fprintf(fid,'INCOMPLETE_LIST: %s\n', strjoin(incNames, ' | '));
reg = results(contains({results.Name},'test_johndoe2_regression'));
fprintf(fid,'REGRESSION %d pass %d fail %d inc %d\n', numel(reg), sum([reg.Passed]), sum([reg.Failed]), sum([reg.Incomplete]));
fclose(fid);

f2 = fopen(flagFile,'w'); fprintf(f2,'done'); fclose(f2);
fprintf('TOTAL %d PASSED %d FAILED %d INCOMPLETE %d\n', nTot, nPass, nFail, nInc);
