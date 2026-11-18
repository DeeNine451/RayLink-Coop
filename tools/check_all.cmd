@echo off
rem Anomaly Coop: the layer border check of docs/MODES.md section 5 (tools\check_layers.py), on its own.
rem   tools\check_all.cmd            check_layers only (seconds; exit 1 on a new mode check in Core or a cross-layer reference)
rem   tools\check_all.cmd gates      also tools\check_gates.py on the working tree (which stand marks the change needs)
rem It is not yet called by tools\build_tests.cmd and tools\test_lua.cmd: the lead wires it in when the work in progress
rem of the other engineers is committed and the ceiling of tools\layers_allow.txt is regenerated
rem (python -I tools\check_layers.py --write-allow --reset-ceiling).
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
python -I "%ROOT%\tools\check_layers.py"
if errorlevel 1 exit /b %ERRORLEVEL%
if /i "%~1"=="gates" (
	python -I "%ROOT%\tools\check_gates.py"
	exit /b %ERRORLEVEL%
)
exit /b 0
