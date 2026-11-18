@echo off
rem Anomaly Coop: the layer border check of docs/MODES.md section 5 (tools\check_layers.py), on its own.
rem   tools\check_all.cmd            check_layers only (seconds; exit 1 on a new mode check in Core or a cross-layer reference)
rem   tools\check_all.cmd gates      check_layers and tools\check_gates.py on the working tree in one process (one model:
rem                                  check_gates --layers; exit 3 = the layer check failed, 1 = a stand mark is missing)
rem tools\build_tests.cmd and tools\test_lua.cmd run check_layers as their first step (COOP_SKIP_LAYERS=1 skips it: the
rem lead's emergency only).
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if /i not "%~1"=="gates" goto layers
python -I "%ROOT%\tools\check_gates.py" --layers --root "%ROOT%"
exit /b %ERRORLEVEL%

:layers
python -I "%ROOT%\tools\check_layers.py" --root "%ROOT%"
exit /b %ERRORLEVEL%
