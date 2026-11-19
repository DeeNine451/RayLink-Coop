@echo off
rem Anomaly Coop: N and L of docs/MODES.md section 10 in one run, and the gate mark temp\gates\tests.ok when both pass.
rem   tools\run_all_tests.cmd          (no arguments: always the full suites)
rem 1. python -I tools\check_gates.py --tests-mark begin: drops the old tests.ok, records both HEAD ids and how many
rem    uncommitted files the tests read (product, tests\, the runners) into temp\gates\tests.state
rem 2. tools\build_tests.cmd (the native tests) and tools\test_lua.cmd (the Lua tests); both start with
rem    tools\check_layers.py
rem 3. python -I tools\check_gates.py --tests-mark write: tests.ok (mode=tests, both HEAD ids, dirty=0, native=0, lua=0)
rem    only when both exit 0, the tree was clean before and after, neither HEAD moved, and the Lua runner
rem    temp\lua\runlua.exe holds the stamp of the sources now (review 4, B5: when tools\test_lua.cmd cannot rebuild it,
rem    it runs the old runner and still exits 0). tools\check_gates.py demands tests.ok of the same HEADs for a release
rem    (the release rule).
rem COOP_SKIP_LAYERS=1 (the lead's emergency, see build_tests.cmd) runs the tests but writes no tests.ok.
rem Exit code: 0 when both suites passed (and the mark was written, or refused with its reason printed), else 1;
rem 2 when the HEADs could not be read.
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "GATES=%ROOT%\temp\gates"
set "STATE=%GATES%\tests.state"
if not exist "%GATES%" mkdir "%GATES%"

python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --tests-mark begin > "%STATE%"
if errorlevel 1 (
	type "%STATE%"
	echo [run_all_tests] cannot read the HEAD ids: no run
	exit /b 2
)
type "%STATE%"

call "%ROOT%\tools\build_tests.cmd"
set "NRC=%ERRORLEVEL%"
call "%ROOT%\tools\test_lua.cmd"
set "LRC=%ERRORLEVEL%"
echo [run_all_tests] native tests: exit %NRC%; Lua tests: exit %LRC%

if /i "%COOP_SKIP_LAYERS%"=="1" (
	echo [run_all_tests] ******************************************************************************************
	echo [run_all_tests] COOP_SKIP_LAYERS=1: the layer check was skipped, so this run writes NO tests.ok
	echo [run_all_tests] ******************************************************************************************
	goto done
)
python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --tests-mark write --state "%STATE%" --native %NRC% --lua %LRC%

:done
if not "%NRC%"=="0" exit /b 1
if not "%LRC%"=="0" exit /b 1
exit /b 0
