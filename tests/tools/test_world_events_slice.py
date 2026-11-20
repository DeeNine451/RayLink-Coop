"""Exercise the production world-event relay, Lua registration, and session cleanup."""
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4

import pytest

from test_client_ammo_reload import ROOT, definition


def build_runner(work: Path, source: str) -> Path:
    # Keep the relay, parsing, and queueing code together. Only their engine boundaries are stubbed.
    types = (definition(source, signature) + ";" for signature in ("struct Incoming", "struct Stats"))
    methods = (definition(source, signature) for signature in (
        "bool log_allowed(", "bool valid_name(", "void write_event(", "void deliver_later(",
        "void host_relay(", "bool read_event(", "void server_on_script_event(",
        "int l_reserve_world_event(", "void on_session_end(",
    ))
    (work / "world_events_types.inc").write_text("\n".join(types), encoding="utf-8")
    (work / "world_events_methods.inc").write_text("\n".join(methods), encoding="utf-8")

    fixture = Path(__file__).with_name("fixtures") / "world_events_slice.cpp"
    engine = ROOT / "engine/src"
    wire = engine / "xrCoop/coop_wire.cpp"
    runner = work / ("world_events_slice.exe" if os.name == "nt" else "world_events_slice")
    if os.name == "nt":
        vcvars = Path(os.environ.get(
            "VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
        ))
        assert vcvars.exists(), "MSVC Build Tools are required"
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" /I"{engine}" '
            f'"{fixture}" "{wire}" /Fe"{runner}"\nexit /b %ERRORLEVEL%\n', encoding="utf-8"
        )
        build = ["cmd", "/d", "/c", str(command)]
    else:
        compiler = shutil.which("c++")
        assert compiler, "A C++17 compiler is required"
        build = [compiler, "-std=c++17", "-pthread", f"-I{work}", f"-I{engine}",
                 str(fixture), str(wire), "-o", str(runner)]
    result = subprocess.run(build, cwd=work, capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.fixture(scope="module")
def world_events_runner():
    # Match the tools' work fixture: inherit the workspace ACL on Windows.
    work = (ROOT / "temp" / f"world_events_slice_{uuid4().hex}").resolve()
    assert work.is_relative_to(ROOT)
    work.mkdir()
    source = ROOT / "engine/src/xrGame/coop/coop_script.cpp"
    try:
        yield build_runner(work, source.read_text(encoding="utf-8-sig"))
    finally:
        shutil.rmtree(work)


@pytest.mark.parametrize("scenario", [
    "reserved-broadcast", "reserved-player", "reserved-world", "ordinary-bridge",
    "coop-guest", "coop-host", "lua-registration", "session-end", "session-end-after-refusal",
])
def test_world_events_slice(world_events_runner, scenario):
    result = subprocess.run([str(world_events_runner), scenario], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, f"{scenario} exited {result.returncode}\n{result.stdout}{result.stderr}"
