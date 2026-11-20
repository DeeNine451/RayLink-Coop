"""B-REV F7 (FIX-NIMBLE): the world server's production relay of script events, coop_script.cpp server_on_script_event.

A map server's event to everybody (target -1) reaches the players only (each his own copy, as its own flush_outbox sends
them), never another map server, which would take the copy (origin 0) as the world's word (mods.nim_held). The function is
compiled from the engine's source with its helpers; only the session and the transport are stubbed
(tests/tools/fixtures/script_relay_slice.cpp).
"""
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4

import pytest

from test_client_ammo_reload import ROOT, definition

SOURCE = ROOT / "engine/src/xrGame/coop/coop_script.cpp"
TYPES = ("struct Incoming", "struct Stats")
METHODS = (
    "bool log_allowed(", "bool valid_name(", "void write_event(", "void deliver_later(",
    "void host_relay(", "bool read_event(", "void server_on_script_event(",
)
SCENARIOS = (
    "bridge-broadcast", "bridge-broadcast-no-players", "bridge-reserved-broadcast", "bridge-to-player",
    "bridge-to-world", "bridge-to-bridge", "player-broadcast", "coop-host-broadcast", "coop-guest-broadcast",
)


def build_runner(work: Path, source: str) -> Path:
    """Compiles the fixture with the relay functions taken from `source` (the text of coop_script.cpp)."""
    (work / "script_relay_types.inc").write_text(
        "\n".join(definition(source, signature) + ";" for signature in TYPES), encoding="utf-8")
    (work / "script_relay_methods.inc").write_text(
        "\n".join(definition(source, signature) for signature in METHODS), encoding="utf-8")
    fixture = Path(__file__).with_name("fixtures") / "script_relay_slice.cpp"
    engine = ROOT / "engine/src"
    wire = engine / "xrCoop/coop_wire.cpp"
    runner = work / ("script_relay_slice.exe" if os.name == "nt" else "script_relay_slice")
    if os.name == "nt":
        vcvars = Path(os.environ.get(
            "VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
        assert vcvars.exists(), "MSVC Build Tools are required"
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" /I"{engine}" '
            f'"{fixture}" "{wire}" /Fe"{runner}"\nexit /b %ERRORLEVEL%\n', encoding="utf-8")
        build = ["cmd", "/d", "/c", str(command)]
    else:
        compiler = shutil.which("c++")
        assert compiler, "A C++17 compiler is required"
        build = [compiler, "-std=c++17", "-pthread", f"-I{work}", f"-I{engine}", str(fixture), str(wire), "-o", str(runner)]
    result = subprocess.run(build, cwd=work, capture_output=True, text=True, errors="replace", timeout=180)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.fixture(scope="module")
def relay_runner():
    work = (ROOT / "temp" / f"script_relay_slice_{uuid4().hex}").resolve()
    assert work.is_relative_to(ROOT)
    work.mkdir(parents=True)
    try:
        yield build_runner(work, SOURCE.read_text(encoding="utf-8-sig"))
    finally:
        shutil.rmtree(work, ignore_errors=True)


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_script_relay_slice(relay_runner, scenario):
    result = subprocess.run([str(relay_runner), scenario], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, f"{scenario} exited {result.returncode}\n{result.stdout}{result.stderr}"
