"""Run the production story group's clock and sky receivers without xrGame.

Run with python -I tests/test_story_worldstate.py. Pass --source to test a
separate copy of coop_worldstate.cpp, for example a regression probe.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
COOP = ROOT / "engine/src/xrCoop"
SOURCE = ROOT / "engine/src/xrGame/coop/coop_worldstate.cpp"
FIXTURE = Path(__file__).with_name("test_story_worldstate.inc")


def definition(source, prefix):
    start = source.index("\n" + prefix) + 1
    # These top-level definitions start and end at column one.
    return source[start:source.index("\n}", start) + 2]


def build(work, source):
    types = (definition(source, "struct " + name) + ";"
             for name in ("TimeState", "EnvRef", "WeatherState", "State"))
    handlers = (definition(source, "void " + name + "(") for name in (
        "client_on_time_sync", "client_on_weather_sync", "client_on_thunderbolt"))
    cpp = work / "story_worldstate.cpp"
    cpp.write_text(FIXTURE.read_text(encoding="utf-8")
                   .replace("// WORLDSTATE_TYPES", "\n\n".join(types))
                   .replace("// WORLDSTATE_HANDLERS", "\n\n".join(handlers)), encoding="utf-8")
    wire = COOP / "coop_wire.cpp"
    if os.name == "nt":
        runner = work / "story_worldstate.exe"
        vcvars = os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /std:c++17 /EHsc /utf-8 /W4 /I"{ROOT / "tests"}" /I"{COOP}" '
            f'"{cpp}" "{wire}" /Fe:"{runner}"\nexit /b %ERRORLEVEL%\n', encoding="utf-8")
        compile_command = ["cmd", "/d", "/c", str(command)]
    else:
        runner = work / "story_worldstate"
        compiler = shutil.which("c++")
        if not compiler:
            raise RuntimeError("A C++17 compiler is required")
        compile_command = [compiler, "-std=c++17", "-Wall", "-Wextra", f"-I{ROOT / 'tests'}",
                           f"-I{COOP}", str(cpp), str(wire), "-o", str(runner)]
    subprocess.run(compile_command, cwd=work, check=True, timeout=120)
    return runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    args = parser.parse_args()
    # Inherit the workspace ACL on Windows, as the other native slices do.
    scratch = (ROOT / "temp" / f"A-S6-E-storyb-worldstate-{uuid4().hex}").resolve()
    if not scratch.is_relative_to(ROOT / "temp"):
        raise RuntimeError(f"Scratch directory is outside the workspace temp directory: {scratch}")
    scratch.mkdir(parents=True)
    try:
        runner = build(scratch, args.source.read_text(encoding="utf-8-sig"))
        return subprocess.run([str(runner)], cwd=scratch, timeout=30).returncode
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    raise SystemExit(main())
