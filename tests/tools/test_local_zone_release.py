"""Run the engine's local_zone_release (personal map zones of a client) over stubs: report #859.

The function is cut out of engine/src/xrGame/coop/coop_requests.cpp; the zone book and the lease pool are the real headers.
A client only: the zones are personal (xrCoop/coop_local_zones.h), in both modes. COOP_TEST_OUT=<dir>: the work folder is
<dir>/local_zone_release (default: temp/local_zone_release).
"""
import os
from pathlib import Path
import subprocess

import pytest

from test_weapon_brief_info import ROOT, definition


def _work():
    out = os.environ.get("COOP_TEST_OUT")
    return (Path(out) if out else ROOT / "temp") / "local_zone_release"


@pytest.fixture(scope="module")
def zone_runner():
    work = _work()
    work.mkdir(parents=True, exist_ok=True)
    requests = ROOT / "engine/src/xrGame/coop/coop_requests.cpp"
    (work / "local_zone_release.inc").write_text(
        definition(requests, "bool local_zone_release("), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/local_zone_release.cpp"
    runner = work / "local_zone_release.exe"
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.is_file(), "MSVC Build Tools required"
    coop = ROOT / "engine/src/xrCoop"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" /I"{coop}" "{fixture}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("scenario", [
    "ready-ours", "ready-online", "not-ours", "world-going", "world-going-gone", "world-going-not-ours",
])
def test_personal_zone_release(zone_runner, scenario):
    run = subprocess.run([str(zone_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
