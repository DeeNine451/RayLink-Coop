@echo off
rem RayLink: builds the engine's own LuaJIT (engine\src\3rd party\luajit-2\src, the same sources and defines as
rem luajit.vcxproj, with its generated lj_vm.obj and headers) and runs the tests of tests\luajit\*.c against it.
rem   tools\test_luajit.cmd [test-name-substring]
rem Output: anomaly-coop\temp\tests_luajit (COOP_TEST_OUT=<dir> moves it). Exit code: 2 = setup, else build error,
rem else the number of failed test programs.
setlocal EnableDelayedExpansion

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "LJ=%ROOT%\engine\src\3rd party\luajit-2\src"
set "TESTS=%ROOT%\tests\luajit"
set "OUT=%ROOT%\temp\tests_luajit"
if defined COOP_TEST_OUT for %%I in ("%COOP_TEST_OUT%") do set "OUT=%%~fI"

if not exist "%LJ%\lj_vm.obj" (
	echo [test_luajit] "%LJ%\lj_vm.obj" is missing: run "%LJ%\gen_luajit_artifacts.bat" x64 once ^(the engine build does it^)
	exit /b 2
)
if not exist "%LJ%\lj_bcdef.h" (
	echo [test_luajit] generated LuaJIT headers are missing: run "%LJ%\gen_luajit_artifacts.bat" x64 once
	exit /b 2
)

if not defined VCVARS set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
	echo [test_luajit] vcvars64.bat not found: "%VCVARS%" ^(set VCVARS to override^)
	exit /b 2
)
call "%VCVARS%" >nul
if errorlevel 1 (
	echo [test_luajit] vcvars64.bat failed
	exit /b 2
)

if not exist "%OUT%\obj" mkdir "%OUT%\obj"
pushd "%OUT%\obj"
set "SRCS="
for %%F in ("%LJ%\lj_*.c" "%LJ%\lib_*.c" "%LJ%\xr_alloc.c") do set "SRCS=!SRCS! "%%~fF""
rem luajit.vcxproj, Release: WIN32;NDEBUG;_CRT_SECURE_NO_DEPRECATE, /O2. The upstream warnings are not ours to fix.
cl /nologo /c /O2 /MD /W1 /DWIN32 /DNDEBUG /D_CRT_SECURE_NO_DEPRECATE /I"%LJ%" %SRCS% >"%OUT%\luajit_build.log" 2>&1
if errorlevel 1 (
	type "%OUT%\luajit_build.log"
	popd
	echo [test_luajit] the LuaJIT sources did not compile
	exit /b 3
)
lib /nologo /out:"%OUT%\lua51_test.lib" *.obj "%LJ%\lj_vm.obj" >>"%OUT%\luajit_build.log" 2>&1
if errorlevel 1 (
	type "%OUT%\luajit_build.log"
	popd
	echo [test_luajit] lib failed
	exit /b 3
)
popd

set /a FAILED=0
set /a RAN=0
for %%T in ("%TESTS%\test_*.c") do (
	set "NAME=%%~nT"
	set "TAKE=1"
	if not "%~1"=="" (
		echo !NAME! | findstr /i /c:"%~1" >nul || set "TAKE=0"
	)
	if "!TAKE!"=="1" (
		pushd "%OUT%"
		cl /nologo /O2 /MD /W3 /DWIN32 /DNDEBUG /D_CRT_SECURE_NO_DEPRECATE /I"%LJ%" "%%~fT" /Fe"%OUT%\!NAME!.exe" ^
			/Fo"%OUT%\!NAME!.obj" /link "%OUT%\lua51_test.lib" >"%OUT%\!NAME!.build.log" 2>&1
		if errorlevel 1 (
			type "%OUT%\!NAME!.build.log"
			echo [test_luajit] !NAME!: build failed
			set /a FAILED+=1
		) else (
			echo [test_luajit] === !NAME!
			"%OUT%\!NAME!.exe"
			if errorlevel 1 (
				echo [test_luajit] !NAME!: FAIL
				set /a FAILED+=1
			) else (
				echo [test_luajit] !NAME!: PASS
			)
		)
		popd
		set /a RAN+=1
	)
)
echo [test_luajit] %RAN% test program^(s^), %FAILED% failed
exit /b %FAILED%
