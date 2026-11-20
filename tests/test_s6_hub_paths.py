"""Compile the hub's production functions against native per-process fixtures."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
SOURCE = ENGINE / "src/xrGame/coop"
COOP = ENGINE / "src/xrCoop"
FIXTURE = Path(__file__).with_suffix(".inc")


def definitions(source, *prefixes, optional=()):
    parts = []
    for prefix in prefixes:
        match = re.search(r"^" + re.escape(prefix), source, re.MULTILINE)
        if match is None and prefix in optional:
            continue
        assert match is not None, prefix
        start = match.start()
        first_end = source.index("\n", start)
        if source[first_end - 1] != "}":
            assert source.startswith("\n{", first_end), prefix
            end = source.index("\n}", first_end) + 2
            if source[end:end + 1] == ";":
                end += 1
        else:
            end = first_end
        parts.append(source[start:end])
    return "\n\n".join(parts)


def fixture(read, head):
    syncapi = read("coop_sync_api.cpp")
    script = read("coop_script.cpp")
    parts = {
        "NET": definitions(
            (SOURCE / "coop_net.cpp").read_text(encoding="utf-8-sig"),
            "bool live()", "bool host()", "bool client()",
        ),
        "SYNC": definitions(read("coop_sync.cpp"), "bool alife_frozen("),
        "SYNCAPI_TYPES": definitions(syncapi, "struct Out\n", "struct Stats\n"),
        "SYNCAPI": definitions(
            syncapi, "bool log_allowed(", "bool decides_sync_store(", "bool client(", "bool in_world(",
            "void push_out(", "void out_to(", "void cast_to(", "void level_flush(", "void host_flush(",
            optional=("bool decides_sync_store(",),
        ),
        "SCRIPT_TYPES": definitions(script, "struct Outgoing\n", "struct Incoming\n", "struct Stats\n"),
        "SCRIPT": definitions(
            script, "bool log_allowed(", "bool valid_name(", "bool decides_world()", "bool lua_ready()",
            "void write_event(", "void deliver_later(", "void host_relay(", "bool read_event(",
            "void server_on_script_event(", "void client_on_script_event(", "void flush_outbox(",
            "bool host_seat_plays(", "PeerInfo self_row(", "int fail2(lua_State* L, const char* why)\n",
            "int l_operator_command(", "int send_fail(", "int l_send_event(",
            optional=("bool decides_world()",),
        ),
    }
    code = FIXTURE.read_text(encoding="utf-8")
    for name, body in parts.items():
        marker = "// PRODUCTION_" + name + "\n"
        assert code.count(marker) == 1, marker
        code = code.replace(marker, body + "\n")
    return ("#define COOP_HUB_BASELINE\n" if head else "") + code


def build(work, code):
    cpp = work / "hub_paths.cpp"
    cpp.write_text(code, encoding="utf-8")
    wire = COOP / "coop_wire.cpp"
    runner = work / "hub_paths.exe"
    vcvars = os.environ.get(
        "VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
    )
    (work / "compile.cmd").write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /std:c++17 /EHsc /utf-8 /W4 /I"{ROOT / "tests"}" /I"{COOP}" '
        f'"{cpp}" "{wire}" /Fe:"{runner}"\nexit /b %ERRORLEVEL%\n', encoding="utf-8",
    )
    env = os.environ | {"TEMP": str(work), "TMP": str(work)}
    subprocess.run(["cmd", "/d", "/c", "compile.cmd"], cwd=work, env=env, check=True, timeout=180)
    return runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--head", action="store_true", help="run behavioral tests on engine HEAD")
    args = parser.parse_args()

    def read(name):
        if args.head:
            path = f"src/xrGame/coop/{name}"
            data = subprocess.check_output(["git", "-C", str(ENGINE), "show", f"HEAD:{path}"])
            return data.decode("utf-8-sig").replace("\r\n", "\n")
        return (SOURCE / name).read_text(encoding="utf-8-sig")

    code = fixture(read, args.head)
    temp_root = (ROOT / "temp").resolve()
    work = (temp_root / f"A-S6-E-hub-paths-{uuid4().hex}").resolve()
    if work.parent != temp_root:
        raise RuntimeError(f"Scratch directory is outside the workspace temp directory: {work}")
    work.mkdir()
    try:
        runner = build(work, code)
        return subprocess.run([str(runner)], cwd=work, timeout=30).returncode
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
