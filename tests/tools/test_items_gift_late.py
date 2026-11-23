"""Run the engine's host_track_proxies, host_push and late_report_of_gift (coop_items.cpp) over stubs: the giver's late report.

A player gives an item to another player; his last ItemState of it arrives after the gift and was refused as "not owner" with
a red line (an automatic error report) in builds 55-58. Within kGraceMs of the item leaving his character (g_left), or in the
very frame of the gift, it is dropped silently and counted. The deciding process is the co-op host or the map server of the
level (both receive ItemState); the rule has no mode check. COOP_TEST_OUT=<dir>: the work folder is <dir>/items_gift_late.
"""
import os
from pathlib import Path
import subprocess

import pytest

from test_weapon_brief_info import ROOT, definition


def _work():
    out = os.environ.get("COOP_TEST_OUT")
    return (Path(out) if out else ROOT / "temp") / "items_gift_late"


@pytest.fixture(scope="module")
def gift_runner():
    work = _work()
    work.mkdir(parents=True, exist_ok=True)
    items = ROOT / "engine/src/xrGame/coop/coop_items.cpp"
    parts = [definition(items, signature) for signature in
             ("bool late_report_of_gift(", "void host_push(", "void host_track_proxies(")]
    (work / "items_gift_late.inc").write_text("\n".join(parts), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/items_gift_late.cpp"
    runner = work / "items_gift_late.exe"
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.is_file(), "MSVC Build Tools required"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" "{fixture}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("scenario", [
    "giver-first", "recipient-first", "same-frame", "expired", "expired-recipient-first", "given-back",
])
def test_giver_report_after_a_gift(gift_runner, scenario):
    run = subprocess.run([str(gift_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
