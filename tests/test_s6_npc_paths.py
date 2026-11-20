"""Compile the NPC production paths with a local xrGame fixture.

Run with python -I tests/test_s6_npc_paths.py. Use --head to check behavioral
parity against engine HEAD, or --source-dir for a copy with probe edits.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
SOURCE = ENGINE / "src/xrGame/coop"
COOP = ENGINE / "src/xrCoop"
FIXTURE = Path(__file__).with_suffix(".inc")


def definitions(source, *prefixes, indent=""):
    bodies = []
    for prefix in prefixes:
        start = source.index(f"\n{indent}{prefix}") + 1
        first_line_end = source.index("\n", start)
        if source[first_line_end - 1] == "}":
            end = first_line_end
        else:
            assert source.startswith(f"\n{indent}{{", first_line_end), prefix
            end = source.index(f"\n{indent}}}", first_line_end) + len(indent) + 2
            if source[end:end + 1] == ";":
                end += 1
        bodies.append(source[start:end])
    return "\n\n".join(bodies)


def fixture(source):
    entities = source("coop_entities.cpp")
    events = source("coop_events.cpp")
    level_mode = source("srv/coop_srv_mode.cpp")
    dispatch = definitions(level_mode, "void level_entity_up(", indent="\t")
    xfer = source("srv/coop_levels_xfer.cpp")
    parts = {
        "OBSERVER": definitions(source("coop_alife.cpp"), "float observer_distance("),
        "APPLY": definitions(entities, "struct ApplyGuard", "bool client_applying("),
        "SPAWN": definitions(entities, "bool online_here(", "bool read_packet(", "void read_placement(",
                             "void client_on_spawn("),
        "ENTITY_HOOKS": definitions(entities, "bool host_records(", "void host_on_entity_registered(",
                                    "void host_on_entity_released("),
        "EVENT_HOOKS": definitions(events, "void host_on_parent_changed(", "void host_on_death("),
        "UP_RECORD": definitions(xfer, "struct Up", indent="\t"),
        "UP_HOOKS": definitions(xfer, "void up_spawned(", "void xfer_on_released(", "void up_parent(", "void up_died("),
        "LEVEL_DISPATCH": dispatch,
    }
    cpp = FIXTURE.read_text(encoding="utf-8")
    for name, body in parts.items():
        marker = f"// PRODUCTION_{name}"
        assert cpp.count(marker) == 1, marker
        cpp = cpp.replace(marker, body)
    return cpp


def build(work, code):
    cpp = work / "npc_paths.cpp"
    cpp.write_text(code, encoding="utf-8")
    wire = COOP / "coop_wire.cpp"
    if os.name == "nt":
        runner = work / "npc_paths.exe"
        vcvars = os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
        (work / "compile.cmd").write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /std:c++17 /EHsc /utf-8 /W4 /I"{ROOT / "tests"}" /I"{COOP}" '
            f'"{cpp}" "{wire}" /Fe:"{runner}"\nexit /b %ERRORLEVEL%\n', encoding="utf-8")
        command = ["cmd", "/d", "/c", "compile.cmd"]
    else:
        runner = work / "npc_paths"
        command = ["c++", "-std=c++17", "-Wall", "-Wextra", f"-I{ROOT / 'tests'}", f"-I{COOP}",
                   str(cpp), str(wire), "-o", str(runner)]
    subprocess.run(command, cwd=work, check=True, timeout=120)
    return runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--head", action="store_true")
    sources.add_argument("--source-dir", type=Path, default=SOURCE)
    args = parser.parse_args()

    def source(name):
        if args.head:
            path = f"src/xrGame/coop/{name}"
            data = subprocess.check_output(["git", "-C", str(ENGINE), "show", f"HEAD:{path}"])
            return data.decode("utf-8-sig").replace("\r\n", "\n")
        return (args.source_dir / name).read_text(encoding="utf-8-sig")

    code = fixture(source)
    temp = ROOT / "temp"
    work = (temp / f"A-S6-E-npcb-paths-{uuid4().hex}").resolve()
    if not work.is_relative_to(temp):
        raise RuntimeError(f"Scratch directory is outside the workspace temp directory: {work}")
    work.mkdir(parents=True)
    try:
        runner = build(work, code)
        return subprocess.run([str(runner)], cwd=work, timeout=30).returncode
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
