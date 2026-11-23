"""Execute the engine's admitted_move and player_move (R32 WP18 P4, section 8a A21 E-3).

The two functions are cut out of engine/src/xrGame/coop/coop_requests.cpp (as test_trade_delivery.py cuts apply_move)
and compiled with fixtures/move_admission_wiring.cpp over the real pure header engine/src/xrCoop/coop_move_admission.h.
They run where a move is decided: the Coop host, and in the Server mode the map server of the player's level (and the
world server for its own script moves); the rule itself has no mode check.

  COOP_TEST_OUT=<dir>      the work folder is <dir>/move_admission_wiring (default: temp/move_admission_wiring)
  COOP_REQUESTS_CPP=<file> cut the functions out of this copy of coop_requests.cpp instead (mutation checks)
"""
import os
from pathlib import Path
import subprocess

import pytest

from test_weapon_brief_info import ROOT, definition

SCENARIOS = [
    "ground-from-box", "ground-from-player",
    "player-refuse-text", "player-refuse-default", "host-actor-refuse", "inside-player-refuse",
    "player-admit", "player-no-rule", "host-actor-no-rule", "player-failed", "player-apply-fails",
    "container-admit", "container-refuse-text", "container-refuse-default", "container-no-rule",
    "container-failed", "container-apply-fails",
]


def _work():
    out = os.environ.get("COOP_TEST_OUT")
    return (Path(out) if out else ROOT / "temp") / "move_admission_wiring"


@pytest.fixture(scope="module")
def wiring_runner():
    work = _work()
    work.mkdir(parents=True, exist_ok=True)
    requests = Path(os.environ.get("COOP_REQUESTS_CPP") or ROOT / "engine/src/xrGame/coop/coop_requests.cpp")
    source = requests.read_text(encoding="utf-8-sig")
    # player_move only when the source has it (an older admitted_move without it must still compile, and fail).
    signatures = [s for s in ("Reason player_move(", "Reason admitted_move(") if s in source]
    assert signatures[-1] == "Reason admitted_move(", "admitted_move not found in " + str(requests)
    (work / "admitted_move.inc").write_text("\n".join(definition(requests, s) for s in signatures), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/move_admission_wiring.cpp"
    runner = work / "move_admission_wiring.exe"
    if runner.exists():
        runner.unlink()
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.is_file(), "MSVC Build Tools required"
    command = work / "compile.cmd"
    # C4715 (a path without a return) is an error: a dropped `return Reason::NotAllowed` must not pass as garbage.
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /W4 /we4715 /I"{work}" /I"{ROOT / "engine/src/xrCoop"}" '
        f'"{fixture}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=180)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_admitted_move_asks_a_player_destination_without_the_book(wiring_runner, scenario):
    run = subprocess.run([str(wiring_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
