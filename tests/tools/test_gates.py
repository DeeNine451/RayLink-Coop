"""tools/check_gates.py: which layers a change touches and which stand marks it needs (docs/MODES.md section 10).

Fake repositories: a temporary folder with `git init` (the mod) and engine/ inside it (its own repository), the
tools/ inputs of a tiny layer map, an exe file and marks written as the stand runners write them. The holes the
adversarial review found in the gate (temp/modes_review/attack_gates.py and gtrees/: rename, merge, relayer, marks;
srv headers that Ядро includes; server functions that Ядро calls without srv_entry.txt) are rebuilt here as commits,
and so are the second review's (temp/modes_review2/new_attacks.py N1-N4, N10-N14; quoted paths; the stand's tracked
scenarios and HEAD's gamedata: tools/stand/stand_head.py on a fake stand, no game is started) and the third's
(temp/modes_review3/review3.md: the release rule and tests.ok, C5-C12, the stand's leftovers, profiles and folder S1-S3;
engine-ci is a git worktree of the fake engine, its exe a few bytes). The classification tests judge a range with
--per-commit (the early warning); without it a range follows the release rule.
Run: python -m pytest tests\\tools\\test_gates.py -q
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

import check_gates as gates
from conftest import ROOT

LAYERS = """\
stock-list tools/stock_files.txt
stock engine/src/**
core engine/src/xrGame/coop/**
core engine/src/xrCoop/**
srv engine/src/xrGame/coop/coop_mapserver.cpp
srv engine/src/xrGame/coop/coop_levels_xfer.cpp
srv engine/src/xrGame/coop/coop_trunk.cpp
srv engine/src/xrGame/coop/coop_mapserver_stats.cpp
srv engine/src/xrGame/coop/coop_far.cpp
srv engine/src/xrCoop/coop_scope.h
srv engine/src/xrCoop/coop_scope_detail.h
hostplay engine/src/xrCoop/coop_local_link.h
srv engine/src/xrGame/coop/srv/**
srv engine/src/xrCoop/srv/**
dying engine/src/xrCoop/coop_soft_move.h
srv gamedata/scripts/coop_srv_*.script
hostplay gamedata/scripts/coop_hostplay_*.script
srv gamedata/scripts/coop_storyline.script
gate-core gamedata/scripts/coop_storyline.script
"""
ALLOW = """\
# ceiling: 1
L1|engine/src/xrGame/coop/coop_mapserver_mixed.cpp|if (is_map_server()) x();|1
"""
FILES = {
    "engine/src/xrGame/coop/coop_items.cpp": "int items() { return 1; }\n",
    "engine/src/xrGame/coop/coop_mapserver.cpp": "int ms() { return 2; }\n",
    "engine/src/xrGame/coop/coop_mapserver_mixed.cpp": "void f() { if (is_map_server()) x(); }\n",
    "engine/src/xrGame/coop/coop_levels_xfer.cpp": "namespace coop::levels {\nbool online_at_server(u16 id)\n{\n\treturn id != 0;\n}\n}\n",
    "engine/src/xrCoop/coop_local_link.h": "#pragma once\n",
    "engine/src/xrCoop/coop_protocol.h": "constexpr int kProtocolVersion = 32;\n",
    "engine/src/xrCoop/coop_soft_move.h": "#pragma once\n",
    "engine/src/xrGame/Level.cpp": "void CLevel::f() {}\n",
    # a srv header that an Ядро file includes, and one that it includes in turn (compiled into Ядро too)
    "engine/src/xrCoop/coop_scope.h": "#pragma once\n#include \"coop_scope_detail.h\"\ninline bool reaches() { return true; }\n",
    "engine/src/xrCoop/coop_scope_detail.h": "#pragma once\ninline int detail() { return 1; }\n",
    "engine/src/xrGame/coop/coop_router.cpp": "#include \"xrCoop/coop_scope.h\"\n#include \"xrCoop/coop_local_link.h\"\n"
                                              "int route() { return reaches() ? 1 : 0; }\n",
    # server code that runs in the co-op process although srv_entry.txt does not name it: mapserver::host_incoming
    # (the engine's coop_levels.cpp:505) and mapserver_stats_frame (coop_manager.cpp:910)
    "engine/src/xrGame/coop/coop_trunk.cpp": "namespace coop\n{\nnamespace mapserver\n{\nbool host_incoming(int from)\n{\n"
                                             "\treturn from != 0;\n}\n}\n}\n",
    "engine/src/xrGame/coop/coop_levels.cpp": "namespace coop::levels\n{\nbool incoming(int from)\n{\n"
                                              "\treturn mapserver::host_incoming(from);\n}\n}\n",
    "engine/src/xrGame/coop/coop_mapserver_stats.cpp": "namespace coop\n{\nvoid mapserver_stats_frame()\n{\n}\n}\n",
    "engine/src/xrGame/coop/coop_manager.cpp": "namespace coop\n{\nvoid frame()\n{\n\tmapserver_stats_frame();\n}\n}\n",
    # server code that nothing of Ядро reaches
    "engine/src/xrGame/coop/coop_far.cpp": "namespace coop::far\n{\nint far_only() { return 3; }\n}\n",
}
MOD_FILES = {
    "gamedata/scripts/coop_items.script": "function f() end\n",
    "gamedata/scripts/coop_srv_far.script": "function f() end\n",
    "gamedata/scripts/coop_hostplay_menu.script": "function f() end\n",
    "gamedata/scripts/coop_storyline.script": "function f() end\n",
    "gamedata/configs/coop_route_npc.ltx": "[route_scripts]\ncoop_npc_adapters = host\nxr_x = view\n",
    "docs/NOTES.md": "notes\n",
    "tests/test_items.cpp": "TEST(a)\n{\n}\nTEST(b)\n{\n}\n",
    "tests/lua/test_items.lua": "-- t\n",
}


def sh(cwd: Path, *args: str) -> str:
    done = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return done.stdout.strip()


def write(base: Path, rel: str, text: str) -> None:
    path = base / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def init(repo: Path) -> None:
    sh(repo, "init", "-q", "-b", "main")
    sh(repo, "config", "user.name", "t")
    sh(repo, "config", "user.email", "t@example.invalid")
    sh(repo, "config", "core.autocrlf", "false")
    sh(repo, "config", "core.quotePath", "true")  # git's default: a non-ASCII path is printed quoted (B11)


def commit(repo: Path, message: str) -> str:
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "--allow-empty", "-m", message)
    return sh(repo, "rev-parse", "HEAD")


@pytest.fixture
def repos(work):
    root = work / "mod"
    engine = root / "engine"
    engine.mkdir(parents=True)
    init(root)
    init(engine)
    write(root, ".gitignore", "engine/\nengine-ci/\ntemp/\n")
    write(root, "tools/layers.txt", LAYERS)
    write(root, "tools/layers_allow.txt", ALLOW)
    write(root, "tools/srv_entry.txt", "online_at_server\n")
    write(root, "tools/stock_files.txt", "engine/src/xrGame/Level.cpp\n")
    for rel, text in MOD_FILES.items():
        write(root, rel, text)
    for rel, text in FILES.items():
        write(engine, rel[len("engine/"):], text)
    commit(root, "base")
    commit(engine, "base")
    sh(root, "tag", "base")
    sh(engine, "tag", "base")
    stand = work / "stand"
    (stand / "gamedata").mkdir(parents=True)
    write(stand, ".raylink-stand.json", json.dumps({"format": 1, "entries": []}))
    exe = gates.stand_exe(stand)
    exe.parent.mkdir(parents=True)
    exe.write_bytes(b"MZ the stand exe")
    return root, engine, exe


def mark(root: Path, engine: Path, stand_exe: Path, which: str, drop: tuple[str, ...] = (), **override: str) -> None:
    exe = stand_exe
    values = {
        "mode": which,
        "mod_head": sh(root, "rev-parse", "HEAD"),
        "engine_head": sh(engine, "rev-parse", "HEAD"),
        "exe": str(exe),
        "exe_sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
        "time": "2026-11-18T14:00:00+05:00",
        "scenarios": ",".join(gates.SCENARIOS[which]),
        "dirty": "0",
        # what the runner deployed and ran: the scenario files and the gamedata of both HEADs (B12, B13)
        "scenarios_sha256": gates.scenarios_digest(root, "HEAD"),
        "gamedata_sha256": gates.gamedata_digest(root, engine, "HEAD", "HEAD"),
        # review 3: the exe is engine-ci's build of engine HEAD (C12), the stand and its profiles (S1-S3)
        "exe_source": sh(engine, "rev-parse", "HEAD"),
        "stand_fingerprint": gates.stand_fingerprint(exe.parent.parent),
        "stand_extra": "0",
        "stand_foreign": "",
        "profile_sha256": gates.profile_digest(root, "HEAD"),
    }
    values.update(override)
    write(root, f"temp/gates/{which}.ok", "".join(f"{k}={v}\n" for k, v in values.items() if k not in drop))


def write_tests_mark(root: Path, engine: Path, drop: tuple[str, ...] = (), **override: str) -> None:
    """temp/gates/tests.ok as tools/run_all_tests.cmd writes it after a clean green run of N and L."""
    values = {"mode": "tests", "mod_head": sh(root, "rev-parse", "HEAD"), "engine_head": sh(engine, "rev-parse", "HEAD"),
              "time": "2026-11-18T14:00:00+05:00", "dirty": "0", "native": "0", "lua": "0"}
    values.update(override)
    write(root, "temp/gates/tests.ok", "".join(f"{k}={v}\n" for k, v in values.items() if k not in drop))


def run(root: Path, exe: Path, capsys, *args: str) -> tuple[int, str]:
    code = gates.main(["--root", str(root), "--exe", str(exe), "--stand", str(exe.parent.parent), *args])
    return code, capsys.readouterr().out


def ci_sync(engine: Path, ci: Path, build: int = 0) -> None:
    """engine-ci as tools/ci_sync.py --committed leaves it: a worktree of the engine with the committed sources of
    engine HEAD copied over (never deleting) and the build number in its raylink_build.h."""
    if not ci.exists():
        sh(engine, "worktree", "add", "-q", "--detach", str(ci), "HEAD")
    for rel, _ in gates.tree_blobs(engine, "HEAD", ["src"]):
        data = subprocess.run(["git", "-C", str(engine), "show", f"HEAD:{rel}"], capture_output=True).stdout
        if rel == gates.CI_BUILD_HEADER:
            data = re.sub(rb"#define RAYLINK_BUILD \d+", b"#define RAYLINK_BUILD %d" % build, data)
        target = ci / rel
        if not target.is_file() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


def ci_exe(ci: Path, exe: Path, data: bytes = b"MZ the stand exe") -> None:
    """The build: engine-ci's exe written after its sources; the stand's exe is a copy of it."""
    built = ci.joinpath(*gates.CI_EXE)
    built.parent.mkdir(parents=True, exist_ok=True)
    built.write_bytes(data)
    exe.write_bytes(data)
    later = time.time() + 120
    os.utime(built, (later, later))


def ci_build(root: Path, engine: Path, exe: Path) -> Path:
    ci = root / "engine-ci"
    ci_sync(engine, ci)
    ci_exe(ci, exe)
    return ci


def required(out: str) -> str:
    return out.split("required:", 1)[1].splitlines()[0]


# --- classification ---------------------------------------------------------------------------------------------------

@pytest.mark.parametrize(("path", "layer", "why"), [
    ("engine/src/xrGame/coop/coop_items.cpp", "core", "core"),
    ("engine/src/xrGame/coop/coop_mapserver.cpp", "srv", "srv"),
    ("engine/src/xrCoop/coop_local_link.h", "hostplay", "hostplay"),
    ("engine/src/xrGame/Level.cpp", "core", "stock"),
    ("engine/src/xrGame/ui/UIRayPanel.cpp", "core", "core"),  # a new file of ours outside the coop folders
    ("engine/src/xrCoop/coop_soft_move.h", "core", "dying"),
    ("engine/src/xrCoop/coop_protocol.h", "core", "protocol"),
    ("engine/src/xrGame/coop/coop_mapserver_mixed.cpp", "core", "allow-list"),
    ("engine/src/xrGame/coop/coop_levels_xfer.cpp", "core", "entry point"),
    ("gamedata/scripts/coop_storyline.script", "core", "H4"),
    ("gamedata/scripts/coop_srv_far.script", "srv", "srv"),
    ("gamedata/scripts/coop_hostplay_menu.script", "hostplay", "hostplay"),
    ("gamedata/scripts/coop_items.script", "core", "core"),
    ("docs/NOTES.md", "none", "outside"),
    ("tests/test_items.cpp", "none", "outside"),
    ("tools/package.ps1", "none", "outside"),
    # the engine's product is its sources and its gamedata: README or CI edits need no stand
    ("engine/README.md", "none", "outside"),
    ("engine/.github/workflows/build.yml", "none", "outside"),
    ("engine/gamedata/scripts/axr_main.script", "core", "core"),
    # review 3, C5: the facade and its two layers decide in which process when_srv code runs
    ("gamedata/scripts/coop_mode.script", "core", "when_srv"),
    ("gamedata/scripts/coop_srv_mode.script", "core", "when_srv"),
    ("gamedata/scripts/coop_hostplay_mode.script", "core", "when_srv"),
    ("tools/run_all_tests.cmd", "core", "test runner"),
])
def test_classify(repos, path, layer, why):
    root, _, _ = repos
    layers = gates.read_layers(root / "tools/layers.txt")
    got = gates.classify(path, layers, gates.allow_paths(root / "tools/layers_allow.txt"),
                         gates.entry_files(root, ["online_at_server"]), lambda p: ("", ""))
    assert got[0] == layer and why in got[1], got


@pytest.mark.parametrize("name", ["tools/layers.txt", "tools/layers_allow.txt", "tools/srv_entry.txt",
                                  "tools/persisted_keys.txt", "tools/stock_files.txt", "tools/check_layers.py",
                                  "tools/check_gates.py", "tools/release.py", "tools/stand_common.ps1",
                                  "tools/stand_hostplay.ps1", "tools/stand_srv.ps1",
                                  # B10: the co-op test runners; B12: the stand's scenarios and probes
                                  "tools/test_lua.cmd", "tools/build_tests.cmd", "tests/lua/run_all.lua",
                                  "tools/ded_check.ps1", "tools/stand/carry_group.ps1", "tools/stand/run_guarded.ps1",
                                  "tools/stand/coop_zz_squads.script", "tools/stand/stand_head.py"])
def test_lists_and_checkers_are_core(repos, name):
    # item 3: a one-line list edit could turn an Ядро file into srv; the checkers decide what a change needs
    root, _, _ = repos
    got = gates.classify(name, gates.read_layers(root / "tools/layers.txt"), set(), set(), lambda p: ("", ""))
    assert got[0] == "core", got


ROUTE_BASE = "[route_callbacks_forced]\nsave_state = host\n[route_scripts]\ncoop_npc_adapters = host\nxr_x = view\n"


@pytest.mark.parametrize(("new", "neutral"), [
    (ROUTE_BASE.replace("coop_npc_adapters = host", "coop_npc_adapters = level"), True),   # a host <-> level swap
    (ROUTE_BASE.replace("xr_x = view", "xr_x = view ; a comment"), True),                    # the same data
    (ROUTE_BASE.replace("xr_x = view", "xr_x = owner"), False),                              # another value
    (ROUTE_BASE + "xr_y = level\n", False),                                                  # a key added
    # review 3, C10: the forced callback route removed and the key added under [route_scripts] as `level`: the lines
    # still pair host <-> level, but the key moved to another section
    ("[route_callbacks_forced]\n[route_scripts]\nsave_state = level\ncoop_npc_adapters = host\nxr_x = view\n", False),
    (ROUTE_BASE.replace("[route_scripts]", "[route_scripts]:base"), False),                   # a parent added
])
def test_route_table_is_read_as_data(new, neutral):
    assert gates.route_neutral(ROUTE_BASE, new) is neutral


# --- the working tree ---------------------------------------------------------------------------------------------------

def test_clean_tree_needs_nothing(repos, capsys):
    root, _, exe = repos
    code, out = run(root, exe, capsys)
    assert code == 0, out
    assert "required: nothing" in out


def test_docs_only_needs_nothing(repos, capsys):
    root, _, exe = repos
    write(root, "docs/NOTES.md", "more\n")
    code, out = run(root, exe, capsys)
    assert code == 0, out


def test_uncommitted_core_change_needs_both_marks_and_a_commit(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 2; }\n")
    mark(root, engine, exe, "hostplay")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys)
    assert code == 1, out
    assert "required: hostplay.ok, srv.ok" in out
    assert "uncommitted product file" in out


def test_staged_rename_of_core_to_srv_counts_the_old_path(repos, capsys):
    # item 1 in the working tree: git diff --no-renames lists the deleted Ядро path
    root, _, exe = repos
    sh(root, "mv", "gamedata/scripts/coop_items.script", "gamedata/scripts/coop_srv_items.script")
    code, out = run(root, exe, capsys)
    assert "core     gamedata/scripts/coop_items.script" in out, out
    assert required(out).startswith(" hostplay.ok, srv.ok"), out


# --- committed ranges and the marks -----------------------------------------------------------------------------------

def test_srv_commit_needs_the_server_mark(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "required: srv.ok, unchanged co-op tests" in out
    assert "srv.ok missing" in out
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    assert "srv.ok OK" in out and "co-op tests 3 -> 3 (unchanged)" in out


def test_mark_of_other_ids_or_other_exe_does_not_count(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv", engine_head="0" * 40)
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "engine 00000000 !=" in out, out
    mark(root, engine, exe, "srv")
    exe.write_bytes(b"MZ another build")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "exe " in out and "does not count" in out, out


@pytest.mark.parametrize(("drop", "override", "why"), [
    (("mode",), {}, "mode missing"),                                  # a mark without mode=
    ((), {"mode": "hostplay"}, "mode hostplay"),                      # the other runner's mark under this name
    ((), {"dirty": "7"}, "dirty=7"),                                  # the stand ran an exe of uncommitted code
    (("dirty",), {}, "dirty=missing"),
    ((), {"scenarios": "ded_check"}, "base_server, carry_server, taskboard_ws did not run"),  # a part of the stand
    (("scenarios",), {}, "did not run"),
    # B12: the scenario files that ran are HEAD's (tools/stand is tracked; a relaxed check is a change of HEAD)
    (("scenarios_sha256",), {}, "scenarios_sha256 missing"),
    ((), {"scenarios_sha256": "0" * 64}, "scenario files 00000000 !="),
    # B13: the stand ran HEAD's gamedata (the runner deploys it first)
    (("gamedata_sha256",), {}, "gamedata_sha256 missing"),
    ((), {"gamedata_sha256": "0" * 64}, "gamedata 00000000 !="),
    # review 3, C12: the stand's exe was shown to be engine-ci's build of engine HEAD
    (("exe_source",), {}, "exe_source=missing"),
    ((), {"exe_source": "none"}, "exe_source=none"),
    ((), {"exe_source": "0" * 40}, "exe_source=00000000"),
    # S1: no leftover of our layers on the stand
    (("stand_extra",), {}, "stand_extra=missing"),
    ((), {"stand_extra": "1"}, "stand_extra=1"),
    # S2: the profiles ran with HEAD's mode cvars
    (("profile_sha256",), {}, "profile_sha256 missing"),
    ((), {"profile_sha256": "0" * 64}, "profile cvars 00000000 !="),
    # S3: a run on another folder with the same exe, or a stand made again or changed since the run
    ((), {"exe": r"D:\some\other\stand\bin\AnomalyCoopDX11AVX.exe"}, "not the stand's"),
    ((), {"stand_fingerprint": "0" * 64}, "the stand changed since the run"),
    (("stand_fingerprint",), {}, "stand_fingerprint missing"),
])
def test_mark_without_mode_dirty_or_partial_does_not_count(repos, capsys, drop, override, why):
    # item 6
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv", drop, **override)
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "srv.ok does not count" in out and why in out, out


def test_stand_runners_list_the_scenarios_the_gate_demands():
    # the marks name the scenarios the runner ran; the gate demands every scenario of tools/stand_<mode>.ps1
    for mode, names in gates.SCENARIOS.items():
        text = (ROOT / "tools" / f"stand_{mode}.ps1").read_text(encoding="utf-8")
        assert tuple(re.findall(r"@\{ Name = '([^']+)'", text)) == names, mode


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
def test_stand_dirty_count_includes_untracked_product_files(work):
    # item 6: a new .script deployed to the stand but never committed makes the mark dirty
    root = work / "mod"
    (root / "tools").mkdir(parents=True)
    (root / "engine").mkdir()
    shutil.copy2(ROOT / "tools" / "stand_common.ps1", root / "tools" / "stand_common.ps1")
    for repo in (root, root / "engine"):
        init(repo)
    write(root, ".gitignore", "engine/\n")
    write(root, "gamedata/scripts/coop_items.script", "function f() end\n")
    write(root / "engine", "src/x.cpp", "int x;\n")
    commit(root, "base")
    commit(root / "engine", "base")
    write(root, "gamedata/scripts/coop_new.script", "function g() end\n")  # untracked
    write(root / "engine", "src/y.cpp", "int y;\n")                       # untracked
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                           f". '{root / 'tools' / 'stand_common.ps1'}'; Get-DirtyProductCount"],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    assert done.stdout.strip().splitlines()[-1] == "2", done.stdout + done.stderr


def test_core_commit_needs_both_marks(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/Level.cpp", "void CLevel::f() { coop::x(); }\n")  # a stock file
    commit(engine, "stock hook")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "hostplay.ok missing" in out
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out


def test_edit_in_an_allow_listed_srv_file_is_core(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver_mixed.cpp", "void f() { if (is_map_server()) y(); }\n")
    commit(engine, "under an allowed line")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "hostplay.ok missing" in out, out
    assert "has allow-list entries (H9)" in out


def test_hostplay_commit_needs_the_coop_mark(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    commit(root, "menu")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "required: hostplay.ok" in out and "srv.ok" not in required(out), out
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out


def test_one_commit_with_hostplay_and_srv_is_refused(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    commit(root, "both modes")
    mark(root, engine, exe, "hostplay")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "split the commit" in out


def test_srv_change_that_moves_the_coop_test_count_fails(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/test_items.cpp", "TEST(a)\n{\n}\n")  # a co-op test removed with a server change
    commit(root, "srv and a test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "co-op tests 3 -> 2" in out and "removed TEST(b)" in out


def test_srv_change_that_swaps_a_coop_test_fails(repos, capsys):
    # item 7: one co-op test removed and another added keeps the count; the set of names moved
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/test_items.cpp", "TEST(a)\n{\n}\nTEST(c)\n{\n}\n")
    commit(root, "srv and a swapped test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "co-op tests 3 -> 3" in out and "removed TEST(b)" in out and "added TEST(c)" in out
    # a server test of its own (test_srv_*) may come with a server change
    sh(root, "tag", "swap")
    sh(engine, "tag", "swap")
    write(root, "tests/test_srv_far.cpp", "TEST(far)\n{\n}\n")
    write(root, "gamedata/scripts/coop_srv_far.script", "function h() end\n")
    commit(root, "srv and its own test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "swap..HEAD", "--per-commit")
    assert code == 0, out


def test_route_swap_commit_is_srv_and_other_route_edit_is_core(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_scripts]\ncoop_npc_adapters = level\nxr_x = view\n")
    commit(root, "swap")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    sh(root, "tag", "swap")
    sh(engine, "tag", "swap")
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_scripts]\ncoop_npc_adapters = level\nxr_x = owner\n")
    commit(root, "owner")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "swap..HEAD", "--per-commit")
    assert code == 1 and "route table (H6)" in out and "hostplay.ok missing" in out, out


def test_output_hides_long_hex(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 5; }\n")
    commit(engine, "core")
    mark(root, engine, exe, "srv")
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    assert not re.search(r"[0-9a-f]{32}", out), out


def test_bad_range_is_exit_2(repos, capsys):
    root, _, exe = repos
    code, out = run(root, exe, capsys, "nosuchtag..HEAD")
    assert code == 2, out


def test_engine_snapshot_tag_uses_its_source_tree(repos, capsys):
    # the engine's release tag points to a public snapshot (its tree on the public main, "Source tree: <id>"), not to a
    # commit of the source branch: the range starts at that source id, not at the root of the history
    root, engine, exe = repos
    source = sh(engine, "rev-parse", "HEAD")
    tree = sh(engine, "rev-parse", "HEAD^{tree}")
    snapshot = sh(engine, "commit-tree", tree, "-m", "RayLink Engine dev 1\n\nSource tree: " + source)
    sh(engine, "tag", "rel", snapshot)
    sh(root, "tag", "rel")
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 4; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "rel..HEAD", "--per-commit")
    assert code == 0, out
    assert "1 commit(s)" in out and "coop_items.cpp" not in out


# --- the review's gate holes (temp/modes_review/attack_gates.py, gtrees/) --------------------------------------------

def test_rename_of_core_to_srv_is_core(repos, capsys):
    # item 1 (gtrees/rename): git mv coop_items.script coop_srv_items.script plus an edit was srv-only
    root, engine, exe = repos
    sh(root, "mv", "gamedata/scripts/coop_items.script", "gamedata/scripts/coop_srv_items.script")
    write(root, "gamedata/scripts/coop_srv_items.script", "function f() end\nfunction extra() end\n")
    commit(root, "rename")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "core     gamedata/scripts/coop_items.script" in out and "hostplay.ok missing" in out, out


def test_merge_that_edits_core_is_core(repos, capsys):
    # item 2 (gtrees/merge): the side branches touch srv only, the merge's own resolution edits Ядро. A merge counts
    # with its diff against its first parent (--diff-merges=first-parent)
    root, engine, exe = repos
    sh(root, "checkout", "-q", "-b", "side")
    write(root, "gamedata/scripts/coop_srv_a.script", "x = 1\n")
    commit(root, "side srv")
    sh(root, "checkout", "-q", "main")
    write(root, "gamedata/scripts/coop_srv_b.script", "y = 1\n")
    commit(root, "main srv")
    subprocess.run(["git", "merge", "--no-commit", "-q", "side"], cwd=root, capture_output=True)
    write(root, "gamedata/scripts/coop_items.script", "function f() return false end\n")
    commit(root, "merge side")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "(merge): core     gamedata/scripts/coop_items.script" in out and "hostplay.ok missing" in out, out


def test_merge_of_separate_hostplay_and_srv_commits_is_not_refused(repos, capsys):
    # a merge brings both layers at once against its first parent; its side commits are checked one by one
    root, engine, exe = repos
    sh(root, "checkout", "-q", "-b", "side")
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    commit(root, "srv")
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    commit(root, "hostplay")
    sh(root, "checkout", "-q", "main")
    write(root, "docs/NOTES.md", "main\n")
    commit(root, "docs")
    sh(root, "merge", "-q", "--no-edit", "side")
    mark(root, engine, exe, "srv")
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert "split the commit" not in out, out
    assert code == 0, out


def test_layers_txt_reclassification_is_core(repos, capsys):
    # item 3 (gtrees/relayer): a row `srv gamedata/scripts/coop_items.script` and an edit of it in one commit
    root, engine, exe = repos
    write(root, "tools/layers.txt", LAYERS + "srv gamedata/scripts/coop_items.script\n")
    write(root, "gamedata/scripts/coop_items.script", "function f() return false end\n")
    commit(root, "relayer")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "core     tools/layers.txt" in out and "hostplay.ok missing" in out, out


@pytest.mark.parametrize(("path", "text", "why"), [
    ("src/xrCoop/coop_scope.h", "#pragma once\n#include \"coop_scope_detail.h\"\ninline bool reaches() { return false; }\n",
     "included by engine/src/xrGame/coop/coop_router.cpp"),
    ("src/xrCoop/coop_scope_detail.h", "#pragma once\ninline int detail() { return 2; }\n",
     "included by engine/src/xrGame/coop/coop_router.cpp (through engine/src/xrCoop/coop_scope.h)"),
    ("src/xrCoop/coop_local_link.h", "#pragma once\n// changed\n", "included by engine/src/xrGame/coop/coop_router.cpp"),
])
def test_srv_or_hostplay_header_that_core_includes_is_core(repos, capsys, path, text, why):
    # item 4: its inline code and macros are compiled into Ядро
    root, engine, exe = repos
    write(engine, path, text)
    commit(engine, "header")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert why in out and "hostplay.ok missing" in out, out


@pytest.mark.parametrize(("path", "text", "why"), [
    ("src/xrGame/coop/coop_trunk.cpp", "namespace coop\n{\nnamespace mapserver\n{\nbool host_incoming(int from)\n{\n"
     "\treturn from > 1;\n}\n}\n}\n", "defines mapserver::host_incoming, called from engine/src/xrGame/coop/coop_levels.cpp:5"),
    ("src/xrGame/coop/coop_mapserver_stats.cpp", "namespace coop\n{\nvoid mapserver_stats_frame()\n{\n\tint n = 0;\n}\n}\n",
     "defines coop::mapserver_stats_frame, called from engine/src/xrGame/coop/coop_manager.cpp:5"),
])
def test_srv_function_called_from_core_is_core_without_srv_entry(repos, capsys, path, text, why):
    # item 5: srv_entry.txt does not name host_incoming or mapserver_stats_frame; the call index finds them
    root, engine, exe = repos
    write(engine, path, text)
    commit(engine, "srv code that runs in co-op")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert why in out and "hostplay.ok missing" in out, out


def test_srv_file_nothing_of_core_reaches_stays_srv(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_far.cpp", "namespace coop::far\n{\nint far_only() { return 4; }\n}\n")
    commit(engine, "far")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out
    assert "srv      engine/src/xrGame/coop/coop_far.cpp" in out


def test_real_srv_entry_names_the_two_co_op_paths():
    # item 5: the two server functions the review found running in the co-op process are listed
    names = gates.check_layers.parse_names((ROOT / "tools" / "srv_entry.txt").read_text(encoding="utf-8"))
    assert "mapserver::host_incoming" in names and "mapserver_stats_frame" in names


# --- the second review (temp/modes_review2): srv code that runs in the co-op process, tests, quoting, the stand -----

def setup_more(root: Path, engine: Path, mod_files: dict, engine_files: dict, stock: tuple[str, ...] = ()) -> None:
    """More files in both repositories, committed and tagged b2 (the base of the attack's later srv-only edit)."""
    for rel, text in mod_files.items():
        write(root, rel, text)
    for rel, text in engine_files.items():
        write(engine, rel[len("engine/"):], text)
    if stock:
        path = root / "tools" / "stock_files.txt"
        path.write_text(path.read_text(encoding="utf-8") + "".join(s + "\n" for s in stock), encoding="utf-8", newline="\n")
    commit(root, "setup")
    commit(engine, "setup")
    sh(root, "tag", "b2")
    sh(engine, "tag", "b2")


ALIFE = "engine/src/xrGame/alife_switch_manager.cpp"
KEEPER_XFER = ("#include \"xrCoop/srv/coop_keeper.h\"\nnamespace coop::levels {\nbool online_at_server(u16 id)\n{\n"
               "\treturn id != 0 && keeper_marked() != 0;\n}\n}\n")
POLICY_H = "#pragma once\nnamespace coop\n{\nstruct FarPolicy\n{\n\tbool keep_online(u16 id) const;\n};\nFarPolicy& far_policy();\n}\n"
POLICY_CPP = ("#include \"coop_far_policy.h\"\nnamespace coop\n{\nbool may_switch_offline(u16 id)\n{\n"
              "\treturn !far_policy().keep_online(id);\n}\n}\n")
POLICY_SRV = "#include \"../coop_far_policy.h\"\nnamespace coop\n{\nbool FarPolicy::keep_online(u16 id) const\n{\n\treturn false;\n}\n}\n"
HOOKS_H = "#pragma once\nnamespace coop::hooks\n{\nusing SkipFn = bool (*)(u16);\nvoid set_skip(SkipFn fn);\n}\n"
SKIP_SRV = ("#include \"../coop_hooks.h\"\nnamespace coop::srvfar\n{\nstatic bool far_skip(u16 id)\n{\n\treturn false;\n}\n"
            "static const bool registered = (coop::hooks::set_skip(&far_skip), true);\n}\n")
FARREAD = "extern bool g_far_world;\nnamespace coop::farread\n{\nbool may_give(u16 id)\n{\n\treturn !g_far_world && id;\n}\n}\n"
WORLD_SRV = "bool g_far_world = false;\nnamespace coop::srvworld\n{\nint n() { return 1; }\n}\n"
FARCALL = ("namespace coop::farcall\n{\nbool keep(lua_State* L)\n{\n\tlua_getglobal(L, \"coop_srv_far\");\n"
           "\treturn lua_toboolean(L, -1) != 0;\n}\n}\n")


@pytest.mark.parametrize(("case", "mod_files", "engine_files", "stock", "edit", "why"), [
    # N1 / B1: a srv header that only a REACHED srv .cpp includes (coop_levels_keeper.h under online_at_server, which
    # stock alife_switch_manager.cpp calls in the co-op host): the reach goes on from every reached srv file
    ("N1", {}, {"engine/src/xrCoop/srv/coop_keeper.h": "#pragma once\ninline int keeper_marked() { return 0; }\n",
                "engine/src/xrGame/coop/coop_levels_xfer.cpp": KEEPER_XFER,
                ALIFE: "void CALifeSwitchManager::f(u16 id)\n{\n\tif (coop::levels::online_at_server(id)) return;\n}\n"},
     (ALIFE,), ("engine/src/xrCoop/srv/coop_keeper.h", "#pragma once\ninline int keeper_marked() { return 1; }\n"),
     "included by the reached engine/src/xrGame/coop/coop_levels_xfer.cpp"),
    # N2 / B2: a srv file defines a member of a class only Ядро defines; Ядро calls it through an object
    ("N2", {}, {"engine/src/xrGame/coop/coop_far_policy.h": POLICY_H, "engine/src/xrGame/coop/coop_far_policy.cpp": POLICY_CPP,
                "engine/src/xrGame/coop/srv/coop_far_policy_srv.cpp": POLICY_SRV}, (),
     ("engine/src/xrGame/coop/srv/coop_far_policy_srv.cpp", POLICY_SRV.replace("return false;", "return id != 0;")),
     "a member of the Ядро class FarPolicy"),
    # N2 with a stock class (CLevel of a stock header without "coop" bytes)
    ("N2s", {}, {"engine/src/xrGame/Level.h": "#pragma once\nclass CLevel\n{\npublic:\n\tvoid frame();\n};\n",
                 "engine/src/xrGame/coop/srv/coop_level_far.cpp": "#include \"../Level.h\"\nvoid CLevel::far_frame()\n{\n}\n"},
     ("engine/src/xrGame/Level.h",),
     ("engine/src/xrGame/coop/srv/coop_level_far.cpp", "#include \"../Level.h\"\nvoid CLevel::far_frame()\n{\n\tint n = 1;\n}\n"),
     "a member of the Ядро class CLevel"),
    # N3 / B3: a static initializer in a srv file registers a hook into an Ядро registry in every process
    ("N3", {}, {"engine/src/xrGame/coop/coop_hooks.h": HOOKS_H, "engine/src/xrGame/coop/srv/coop_far_skip.cpp": SKIP_SRV}, (),
     ("engine/src/xrGame/coop/srv/coop_far_skip.cpp", SKIP_SRV.replace("return false;", "return id >= 0x9000;")),
     "a static initializer with a call"),
    # N4 / B4: Ядро reads `extern bool g_far_world`, a srv file defines it
    ("N4", {}, {"engine/src/xrGame/coop/coop_farread.cpp": FARREAD, "engine/src/xrGame/coop/srv/coop_srv_world.cpp": WORLD_SRV},
     (), ("engine/src/xrGame/coop/srv/coop_srv_world.cpp", WORLD_SRV.replace("= false", "= true")),
     "defines g_far_world, declared extern by engine/src/xrGame/coop/coop_farread.cpp"),
    # N10 / B7: Ядро C++ names a srv script in a string (lua_getglobal)
    ("N10", {}, {"engine/src/xrGame/coop/coop_farcall.cpp": FARCALL}, (),
     ("gamedata/scripts/coop_srv_far.script", "function keep(id) return id > 0 end\n"),
     "named in a string by engine/src/xrGame/coop/coop_farcall.cpp:5"),
    # N11 / B8: a dialog of the configs names a srv script's function
    ("N11", {"gamedata/configs/gameplay/dialogs_coop_far.xml":
             "<game_dialogs>\n<dialog id=\"far\">\n<precondition>coop_srv_far.can_trade</precondition>\n</dialog>\n</game_dialogs>\n"},
     {}, (), ("gamedata/scripts/coop_srv_far.script", "function can_trade() return false end\n"),
     "named by gamedata/configs/gameplay/dialogs_coop_far.xml:3"),
    ("N11ltx", {}, {"engine/gamedata/configs/scripts/far_logic.ltx": "[logic]\non_info = {=coop_srv_far.can_trade} far\n"},
     (), ("gamedata/scripts/coop_srv_far.script", "function can_trade() return false end\n"),
     "named by engine/gamedata/configs/scripts/far_logic.ltx:2"),
    # N12 / B9: a stock-patch script (engine/gamedata/scripts) calls a srv script
    ("N12", {"gamedata/scripts/coop_srv_boot.script": "function on_start() return end\n"},
     {"engine/gamedata/scripts/axr_main.script": "function on_game_start()\n\tif coop_srv_boot then coop_srv_boot.on_start() end\nend\n"},
     (), ("gamedata/scripts/coop_srv_boot.script", "function on_start() alife():set_switch_distance(150) end\n"),
     "named by engine/gamedata/scripts/axr_main.script:2"),
    ("N12g", {"gamedata/scripts/coop_srv_boot.script": "function on_start() return end\n",
              "gamedata_gamma/scripts/coop_menu_theme.script": "function apply()\n\tcoop_srv_boot.on_start()\nend\n"},
     {}, (), ("gamedata/scripts/coop_srv_boot.script", "function on_start() alife():set_switch_distance(150) end\n"),
     "named by gamedata_gamma/scripts/coop_menu_theme.script:2"),
])
def test_srv_code_the_co_op_process_runs_is_core(repos, capsys, case, mod_files, engine_files, stock, edit, why):
    # the review's N1-N4, N10-N12: a later srv-only edit of server code that runs in the co-op process needed srv.ok only
    root, engine, exe = repos
    setup_more(root, engine, mod_files, engine_files, stock)
    path, text = edit
    if path.startswith("engine/"):
        write(engine, path[len("engine/"):], text)
        commit(engine, f"{case}: a server fix")
    else:
        write(root, path, text)
        commit(root, f"{case}: a server fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 1, out
    assert f"core     {path}" in out and why in out and "hostplay.ok missing" in out, out


def test_srv_script_named_only_in_a_config_comment_stays_srv(repos, capsys):
    root, engine, exe = repos
    setup_more(root, engine, {"gamedata/configs/gameplay/dialogs_coop_far.xml":
                              "<game_dialogs>\n<!-- coop_srv_far.can_trade -->\n</game_dialogs>\n",
                              "gamedata/configs/far.ltx": "[x]\n; coop_srv_far.can_trade\n"}, {})
    write(root, "gamedata/scripts/coop_srv_far.script", "function can_trade() return false end\n")
    commit(root, "srv")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 0, out
    assert "srv      gamedata/scripts/coop_srv_far.script" in out, out


@pytest.mark.parametrize(("path", "text"), [
    ("tests/test_items.cpp", "TEST(a)\n{\n\t// CHECK_EQ(placement(), 1); flaky after the server fix\n}\nTEST(b)\n{\n}\n"),  # N13
    ("tests/lua/stub_coop.lua", "COOP_LUA_MODES = { \"srv\" }\n"),                                               # N14
])
def test_srv_change_that_edits_co_op_tests_fails(repos, capsys, path, text):
    # B10: the set of TEST names stays the same; the bodies or the Lua support of the co-op tests changed
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, path, text)
    commit(root, "srv and a co-op test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1, out
    assert "co-op tests 3 -> 3 (unchanged)" in out and "edited co-op tests or their runner" in out and path in out, out


def test_srv_change_that_edits_co_op_tests_in_the_working_tree_fails(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/test_items.lua", "-- weaker\n")
    code, out = run(root, exe, capsys)
    assert code == 1 and "edited co-op tests or their runner" in out and "tests/lua/test_items.lua" in out, out


def test_srv_change_with_its_own_srv_test_passes(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/test_srv_far.lua", "-- the server's own\n")
    commit(root, "srv and its test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0, out


def test_test_runner_edit_needs_both_marks(repos, capsys):
    # B10 / N14: tests/lua/run_all.lua, tools/test_lua.cmd and tools/build_tests.cmd decide which co-op tests run
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/run_all.lua", "COOP_LUA_MODES = { \"srv\" }\n")
    commit(root, "srv and the runner")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "core     tests/lua/run_all.lua" in out and "hostplay.ok missing" in out, out


def test_non_ascii_product_path_is_classified(repos, capsys):
    # B11: git quotes a non-ASCII path unless core.quotePath=false; a quoted path never matched PRODUCT
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_предметы.script", "function pick() return false end\n")
    write(root, "gamedata/scripts/coop_srv_x.script", "x = 1\n")
    commit(root, "cyrillic")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 1 and "core     gamedata/scripts/coop_предметы.script" in out, out
    assert required(out).startswith(" hostplay.ok, srv.ok"), out
    write(root, "gamedata/scripts/coop_предметы.script", "function pick() return true end\n")
    code, out = run(root, exe, capsys)
    assert "core     gamedata/scripts/coop_предметы.script" in out and required(out).startswith(" hostplay.ok, srv.ok"), out


def test_quoted_path_is_a_gate_error(repos):
    root, _, _ = repos
    with pytest.raises(gates.GateError, match="quoted"):
        gates.classify('"gamedata/scripts/coop_\\320\\277.script"', gates.read_layers(root / "tools/layers.txt"), set(),
                       set(), lambda p: "")


# --- the stand: tracked scenarios, HEAD's gamedata (B12, B13) ---------------------------------------------------------

STAND = ROOT / "tools" / "stand"


def test_stand_scenarios_and_probes_are_tracked_in_tools_stand():
    # B12: every scenario the runners name, the guard and every probe a scenario deploys live in tools/stand (tracked);
    # temp/stand (ignored) keeps the run history only
    for mode, names in gates.SCENARIOS.items():
        text = (ROOT / "tools" / f"stand_{mode}.ps1").read_text(encoding="utf-8")
        for script in re.findall(r"Script = '([^']+)'", text):
            assert (STAND / script).resolve().is_file(), (mode, script)
    for name in ("run_guarded.ps1", "hybrid_save.ps1", "stand_head.py"):
        assert (STAND / name).is_file(), name
    for scenario in STAND.glob("*.ps1"):
        text = scenario.read_text(encoding="utf-8", errors="replace")
        for probe in re.findall(r"(coop_zz_\w+\.script)'", text):
            if re.search(rf"Copy-Item -LiteralPath \(Join-Path \$PSScriptRoot '{probe}'\)", text) or \
                    re.search(rf"\$p in @\([^)]*'{probe}'", text):
                assert (STAND / probe).is_file(), (scenario.name, probe)
        assert "Join-Path $PSScriptRoot \"${Tag}" not in text, scenario.name  # logs go to temp\stand, not here
    common = (ROOT / "tools" / "stand_common.ps1").read_text(encoding="utf-8")
    assert "tools\\stand" in common and "stand_head.py" in common


def scenario_repo(work: Path) -> tuple[Path, Path]:
    """A fake mod repository (with engine/) holding the stand tooling: tools/check_gates.py, check_layers.py,
    stand_common.ps1, tools/stand/ (stand_head.py and one probe), gamedata in all three layers; and a fake stand."""
    root = work / "mod"
    engine = root / "engine"
    engine.mkdir(parents=True)
    init(root)
    init(engine)
    write(root, ".gitignore", "engine/\nengine-ci/\ntemp/\ngamedata/scripts/coop_local.script\n")
    (root / "tools" / "stand").mkdir(parents=True)
    for name in ("check_gates.py", "check_layers.py", "stand_common.ps1", "stand_hostplay.ps1", "stand_srv.ps1",
                 "ded_check.ps1"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    for path in STAND.iterdir():
        if path.is_file():
            shutil.copy2(path, root / "tools" / "stand" / path.name)
    write(root, "gamedata/scripts/coop_items.script", "function pick() return 1 end\n")
    write(root, "gamedata/configs/axr_options.ltx", "[x]\n")  # written by the game: never deployed
    write(root, "gamedata_gamma/scripts/coop_menu_theme.script", "function apply() end\n")
    write(engine, "gamedata/scripts/axr_main.script", "function on_game_start() end\n")
    write(engine, "gamedata/configs/mod_by_engine.ltx", "[engine]\n")
    write(engine, "gamedata/configs/mod_by_a_mod.ltx", "[engine]\n")
    write(engine, "src/x.cpp", "int x;\n")
    commit(root, "base")
    commit(engine, "base")
    write(root, "gamedata/scripts/coop_local.script", "-- ignored, never committed\n")
    stand = work / "stand"
    (stand / "gamedata" / "configs").mkdir(parents=True)
    (stand / "bin").mkdir()
    write(stand, "gamedata/scripts/coop_items.script", "function pick() return 0 end\n")      # an older Core file
    write(stand, "gamedata/configs/mod_by_engine.ltx", "[old engine]\n")                      # from the Engine layer
    write(stand, "gamedata/configs/mod_by_a_mod.ltx", "[a mod overrides it]\n")               # a mod wins over Engine
    write(stand, "gamedata/configs/axr_options.ltx", "[the player's]\n")
    entries = [{"rel": "gamedata/configs/mod_by_engine.ltx", "source": "B:\\dev-1\\Anomaly Coop - Engine/gamedata\\configs\\mod_by_engine.ltx"},
               {"rel": "gamedata/configs/mod_by_a_mod.ltx", "source": "B:\\mo2\\mods\\12- A mod\\gamedata\\configs\\mod_by_a_mod.ltx"},
               {"rel": "gamedata/scripts/coop_items.script", "source": "B:\\dev-1\\Anomaly Coop - Core/gamedata\\scripts\\coop_items.script"}]
    (stand / ".raylink-stand.json").write_text(json.dumps({"format": 1, "entries": entries}), encoding="utf-8")
    # engine-ci built from engine HEAD; the stand's exe is its copy (C12)
    ci_sync(engine, root / "engine-ci")
    ci_exe(root / "engine-ci", gates.stand_exe(stand), b"MZ stand exe")
    return root, stand


def add_manifest(stand: Path, *entries: dict) -> None:
    path = stand / ".raylink-stand.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["entries"] += list(entries)
    path.write_text(json.dumps(data), encoding="utf-8")


def stand_head(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(root / "tools" / "stand" / "stand_head.py"), *args],
                          capture_output=True, text=True, encoding="utf-8", errors="replace", cwd=root)


def values(out: str) -> dict:
    return dict(l.split("=", 1) for l in out.splitlines() if re.match(r"^[a-z_0-9]+=", l))


def test_stand_head_deploys_heads_gamedata_and_prints_the_digests(work):
    # B13: the stand runs HEAD's gamedata: Core and GAMMA always, the Engine layer where no mod overrides it
    root, stand = scenario_repo(work)
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout + done.stderr
    got = values(done.stdout)
    assert got["gamedata_sha256"] == gates.gamedata_digest(root, root / "engine", "HEAD", "HEAD")
    assert got["scenarios_sha256"] == gates.scenarios_digest(root, "HEAD")
    assert got["mod_head"] == sh(root, "rev-parse", "HEAD") and got["engine_head"] == sh(root / "engine", "rev-parse", "HEAD")
    read = lambda rel: (stand / rel).read_text(encoding="utf-8")  # noqa: E731
    assert read("gamedata/scripts/coop_items.script") == "function pick() return 1 end\n"
    assert read("gamedata/scripts/coop_menu_theme.script") == "function apply() end\n"         # GAMMA layer on top
    assert read("gamedata/configs/mod_by_engine.ltx") == "[engine]\n"                          # Engine layer, its file
    assert read("gamedata/configs/mod_by_a_mod.ltx") == "[a mod overrides it]\n"               # the mod still wins
    assert read("gamedata/scripts/axr_main.script") == "function on_game_start() end\n"        # new engine file
    assert read("gamedata/configs/axr_options.ltx") == "[the player's]\n"                      # never deployed
    assert not (stand / "gamedata/scripts/coop_local.script").exists()                         # not in HEAD
    assert (work / "backup" / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 0 end\n"
    check = stand_head(root, "check", "--stand", str(stand))
    assert check.returncode == 0 and values(check.stdout)["gamedata_sha256"] == got["gamedata_sha256"], check.stdout
    write(stand, "gamedata/scripts/coop_items.script", "function pick() return 2 end\n")  # changed during the run
    check = stand_head(root, "check", "--stand", str(stand))
    assert check.returncode == 1 and "coop_items.script" in check.stdout, check.stdout


@pytest.mark.parametrize(("rel", "text"), [
    ("gamedata/scripts/coop_items.script", "function pick() return 5 end\n"),   # a product change
    ("gamedata/scripts/coop_new.script", "x = 1\n"),                            # an untracked product file
    ("tools/stand/coop_zz_probe.script", "-- relaxed\n"),                       # a scenario file not at HEAD
    ("engine/gamedata/scripts/axr_main.script", "-- engine change\n"),
])
def test_stand_head_refuses_a_dirty_tree(work, rel, text):
    # B13: the runner refuses to start while the working tree has product (or scenario) changes
    root, stand = scenario_repo(work)
    write(root, rel, text)
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 1 and "refused" in done.stdout and rel.split("/")[-1] in done.stdout, done.stdout
    assert (stand / "gamedata/scripts/coop_items.script").read_text(encoding="utf-8") == "function pick() return 0 end\n"


@pytest.mark.skipif(shutil.which("powershell") is None, reason="Windows PowerShell is not here")
def test_stand_runner_deploys_first_and_writes_the_digests_into_the_mark(work):
    # B12/B13 through the runner's own functions (no game starts): Invoke-HeadDeploy, then Write-GateMark
    root, stand = scenario_repo(work)
    exe = stand / "bin" / "AnomalyCoopDX11AVX.exe"
    exe.write_bytes(b"MZ stand exe")
    script = (f". '{root / 'tools' / 'stand_common.ps1'}'; $h = Invoke-HeadDeploy -Stand '{stand}'; "
              f"Write-GateMark -Mode srv -Exe '{exe}' -Names @({','.join(repr(s) for s in gates.SCENARIOS['srv'])}) -Head $h")
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    ok, text = gates.check_mark("srv", root / "temp" / "gates", sh(root, "rev-parse", "HEAD"),
                                sh(root / "engine", "rev-parse", "HEAD"), hashlib.sha256(exe.read_bytes()).hexdigest(),
                                root, root / "engine", stand)
    assert ok, text
    written = gates.read_mark(root / "temp" / "gates" / "srv.ok")
    assert written["exe_source"] == sh(root / "engine", "rev-parse", "HEAD") and written["stand_extra"] == "0", written
    write(root, "gamedata/scripts/coop_items.script", "function pick() return 9 end\n")
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                           f". '{root / 'tools' / 'stand_common.ps1'}'; Invoke-HeadDeploy -Stand '{stand}'"],
                          capture_output=True, text=True)
    assert done.returncode != 0 and "refused" in (done.stdout + done.stderr), done.stdout + done.stderr


# --- review 3: the release rule and tests.ok ---------------------------------------------------------------------------

FAR_SRV = "namespace coop::far\n{\nint far_only() { return 4; }\n}\n"  # srv code nothing of Ядро reaches


def test_range_needs_both_stands_and_the_tests_for_any_product_change(repos, capsys):
    # the release rule: a srv-only commit is srv for the early warning, but the range needs everything
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_far.cpp", FAR_SRV)
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD", "--per-commit")
    assert code == 0 and required(out) == " srv.ok, unchanged co-op tests", out
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert required(out) == " hostplay.ok, srv.ok, tests.ok", out
    assert "release rule: a product file changed in the range" in out
    assert "hostplay.ok missing" in out and "tests.ok missing" in out
    mark(root, engine, exe, "hostplay")
    write_tests_mark(root, engine)
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out
    assert "tests.ok OK" in out
    assert not re.search(r"[0-9a-f]{32}", out), out


def test_range_without_a_product_change_needs_nothing_but_a_release_ships_the_exe(repos, capsys):
    root, engine, exe = repos
    write(root, "docs/NOTES.md", "more\n")
    commit(root, "docs")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0 and "required: nothing" in out, out
    ci = ci_build(root, engine, exe)
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 1 and required(out) == " hostplay.ok, srv.ok, tests.ok", out
    assert "the release ships the exe" in out
    for which in gates.MARKS:
        mark(root, engine, exe, which)
    write_tests_mark(root, engine)
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 0 and "engine-ci's build of engine" in out, out


@pytest.mark.parametrize(("drop", "override", "why"), [
    (("mode",), {}, "mode missing"),
    ((), {"dirty": "2"}, "dirty=2"),
    ((), {"native": "1"}, "build_tests.cmd did not pass"),
    (("lua",), {}, "lua=missing"),
    ((), {"engine_head": "0" * 40}, "engine 00000000 !="),
    ((), {"mod_head": "0" * 40}, "mod 00000000 !="),
])
def test_tests_mark_does_not_count_unless_clean_green_and_of_both_heads(repos, capsys, drop, override, why):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_items.script", "function f() return 1 end\n")
    commit(root, "core")
    for which in gates.MARKS:
        mark(root, engine, exe, which)
    write_tests_mark(root, engine, drop, **override)
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1 and "tests.ok does not count" in out and why in out, out


def test_tests_mark_is_written_only_after_a_clean_green_run_of_both_heads(repos, capsys):
    root, engine, _ = repos
    marks = root / "temp" / "gates"
    state = marks / "tests.state"

    def begin() -> int:
        code = gates.main(["--root", str(root), "--tests-mark", "begin"])
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(capsys.readouterr().out, encoding="utf-8")
        return code

    def finish(native: int, lua: int) -> tuple[int, str]:
        code = gates.main(["--root", str(root), "--tests-mark", "write", "--state", str(state), "--native", str(native),
                           "--lua", str(lua)])
        return code, capsys.readouterr().out

    write_tests_mark(root, engine)
    assert begin() == 0 and not (marks / "tests.ok").exists()  # an old mark never outlives a new run
    code, out = finish(0, 1)
    assert code == 1 and "test_lua.cmd failed" in out and not (marks / "tests.ok").exists(), out
    assert begin() == 0
    code, out = finish(0, 0)
    assert code == 0 and (marks / "tests.ok").exists(), out
    head_ids = (sh(root, "rev-parse", "HEAD"), sh(engine, "rev-parse", "HEAD"))
    assert gates.check_mark("tests", marks, *head_ids, None)[0]
    # a file the tests read changed during the run
    assert begin() == 0
    write(root, "tests/lua/test_items.lua", "-- weaker\n")
    code, out = finish(0, 0)
    assert code == 1 and "not clean" in out and not (marks / "tests.ok").exists(), out
    sh(root, "checkout", "--", "tests/lua/test_items.lua")
    # a HEAD moved during the run
    assert begin() == 0
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 3; }\n")
    commit(engine, "during the run")
    code, out = finish(0, 0)
    assert code == 1 and "engine_head moved" in out, out


@pytest.mark.skipif(shutil.which("cmd") is None, reason="cmd.exe is not here")
def test_run_all_tests_cmd_writes_tests_ok_only_when_both_suites_pass(repos):
    root, engine, _ = repos
    for name in ("check_gates.py", "check_layers.py", "run_all_tests.cmd"):
        shutil.copy2(ROOT / "tools" / name, root / "tools" / name)
    write(root, "tools/build_tests.cmd", "@exit /b 0\n")
    write(root, "tools/test_lua.cmd", "@exit /b %STUB_LUA%\n")
    commit(root, "the runners")
    env = dict(os.environ, PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ.get("PATH", ""))
    env.pop("COOP_SKIP_LAYERS", None)
    mark_path = root / "temp" / "gates" / "tests.ok"
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="0"))
    assert done.returncode == 0 and mark_path.is_file(), done.stdout + done.stderr
    assert gates.read_mark(mark_path)["engine_head"] == sh(engine, "rev-parse", "HEAD")
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="3"))
    assert done.returncode == 1 and not mark_path.exists(), done.stdout + done.stderr
    done = subprocess.run(["cmd", "/c", str(root / "tools" / "run_all_tests.cmd")], capture_output=True, text=True,
                          env=dict(env, STUB_LUA="0", COOP_SKIP_LAYERS="1"))
    assert done.returncode == 0 and not mark_path.exists() and "NO tests.ok" in done.stdout, done.stdout


# --- review 3, C12: the exe is engine-ci's build of engine HEAD ----------------------------------------------------------

def built_from_head(root: Path, engine: Path, exe: Path) -> Path:
    """engine HEAD moved on from the commit engine-ci was checked out at (a file added, one edited, one deleted, the
    build number header), then ci_sync and a build: the good state."""
    ci = root / "engine-ci"
    ci_sync(engine, ci)
    write(engine, "src/xrGame/coop/coop_new.cpp", "int fresh() { return 1; }\n")
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 7; }\n")
    write(engine, "src/xrCore/raylink_build.h", "#pragma once\n#define RAYLINK_BUILD 0\n")
    (engine / "src/xrGame/coop/coop_far.cpp").unlink()
    commit(engine, "work")
    ci_sync(engine, ci, build=57)
    (ci / "src/xrGame/coop/coop_far.cpp").unlink()  # gone from HEAD: the good state has no copy of it either
    ci_exe(ci, exe)
    return ci


def test_exe_source_is_engine_head_for_engine_cis_build_of_heads_sources(repos, capsys):
    root, engine, exe = repos
    ci = built_from_head(root, engine, exe)
    assert gates.exe_source(engine, exe, ci) == (sh(engine, "rev-parse", "HEAD"), [])
    assert gates.exe_source(engine, ci.joinpath(*gates.CI_EXE), ci)[1] == []
    code = gates.main(["--root", str(root), "--exe-source", "--exe", str(exe), "--ci", str(ci)])
    assert code == 0 and "exe_source=" + sh(engine, "rev-parse", "HEAD") in capsys.readouterr().out


@pytest.mark.parametrize(("case", "why"), [
    ("edited", "differs from engine HEAD in 1 file(s): src/xrGame/coop/coop_items.cpp"),
    ("lacks", "lacks 1 file(s) of engine HEAD: src/xrGame/coop/coop_new.cpp"),
    ("extra", "holds 1 source file(s) engine HEAD does not have: src/xrGame/coop/coop_far.cpp"),
    ("untracked_extra", "engine HEAD does not have: src/xrGame/coop/coop_stale.cpp"),
    ("synced_after", "changed after the exe was built: src/xrGame/coop/coop_items.cpp"),
    ("dirty", "engine/src has 1 uncommitted file(s)"),
    ("other_exe", "is not engine-ci's build"),
])
def test_exe_source_names_why_the_exe_is_not_heads_build(repos, case, why):
    root, engine, exe = repos
    ci = built_from_head(root, engine, exe)
    if case == "edited":
        write(ci, "src/xrGame/coop/coop_items.cpp", "int items() { return 8; }\n")
        ci_exe(ci, exe)
    elif case == "lacks":
        (ci / "src/xrGame/coop/coop_new.cpp").unlink()
        ci_exe(ci, exe)
    elif case == "extra":
        write(ci, "src/xrGame/coop/coop_far.cpp", "int far_only() { return 3; }\n")  # tracked in engine-ci's index
        ci_exe(ci, exe)
    elif case == "untracked_extra":
        write(ci, "src/xrGame/coop/coop_stale.cpp", "int stale() { return 1; }\n")
        ci_exe(ci, exe)
    elif case == "synced_after":
        target = ci / "src/xrGame/coop/coop_items.cpp"
        later = time.time() + 600
        os.utime(target, (later, later))
    elif case == "dirty":
        write(engine, "src/xrGame/coop/coop_wip.cpp", "int wip() { return 1; }\n")
    else:
        exe.write_bytes(b"MZ another build")
    source, problems = gates.exe_source(engine, exe, ci)
    assert source == "" and any(why in p for p in problems), problems


def test_release_mode_refuses_an_exe_not_built_from_engine_head(repos, capsys):
    root, engine, exe = repos
    ci = built_from_head(root, engine, exe)
    for which in gates.MARKS:
        mark(root, engine, exe, which)
    write_tests_mark(root, engine)
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 0 and "engine-ci's build of engine" in out, out
    write(ci, "src/xrGame/coop/coop_items.cpp", "int items() { return 9; }\n")  # an edit after the build
    code, out = run(root, exe, capsys, "base..HEAD", "--release", "--ci", str(ci))
    assert code == 1 and "the exe was not built from engine HEAD" in out and "coop_items.cpp" in out, out


# --- review 3: the gate's reach (C6-C9, C11) and the route table read as data (C10) ------------------------------------

HOOKS_REG_SRV = ("#include \"../coop_hooks.h\"\nnamespace coop::srvfar\n{\nstatic bool far_skip(u16 id)\n{\n\treturn false;\n}\n"
                 "struct Registrar\n{\n\tRegistrar() { coop::hooks::set_skip(&far_skip); }\n};\nstatic Registrar s_registrar;\n}\n")
LIMITS_H = ("#pragma once\nstruct FarLimits\n{\n\tstatic u32 squads_per_player;\n};\n"
            "inline u32 far_squads() { return FarLimits::squads_per_player; }\n")
LIMITS_SRV = "#include \"../coop_far_limits.h\"\nu32 FarLimits::squads_per_player = 4;\n"
SWITCH_CORE = ("namespace coop\n{\nbool may_switch(u16 id)\n{\n\treturn id != 0;\n}\nbool switch_ok(u16 id, const FarGroup& g)\n"
               "{\n\treturn may_switch(id) && may_switch(g);\n}\n}\n")
SWITCH_SRV = "namespace coop\n{\nbool may_switch(const FarGroup& g)\n{\n\treturn g.members > 1;\n}\n}\n"
BOOK_H = "#pragma once\nnamespace op\n{\nstruct Book\n{\n\tbool may_run(int line) const;\n};\n}\n"
BOOK_CORE = ("#include \"xrCoop/srv/coop_book.h\"\nnamespace coop\n{\nop::Book& operator_book()\n{\n\tstatic op::Book book;\n"
             "\treturn book;\n}\nbool run_line(int line)\n{\n\treturn operator_book().may_run(line);\n}\n}\n")
BOOK_SRV = ("#include \"../../../xrCoop/srv/coop_book.h\"\nnamespace op\n{\nbool Book::may_run(int line) const\n{\n"
            "\treturn line > 0;\n}\n}\n")


@pytest.mark.parametrize(("case", "mod_files", "engine_files", "edit", "why"), [
    # C6: a dispatch table of Ядро names the srv script in a plain string
    ("C6", {"gamedata/scripts/coop_price_hooks.script":
            "local HOOKS = { \"coop_items\", \"coop_srv_far\" }\nfunction factor(i) return rawget(_G, HOOKS[2]).f(i) end\n"},
     {}, ("gamedata/scripts/coop_srv_far.script", "function f(i) return 1.5 end\n"),
     "named by gamedata/scripts/coop_price_hooks.script:1"),
    # C7: a static object whose constructor registers a hook runs in every process
    ("C7", {}, {"engine/src/xrGame/coop/coop_hooks.h": HOOKS_H, "engine/src/xrGame/coop/srv/coop_far_reg.cpp": HOOKS_REG_SRV},
     ("engine/src/xrGame/coop/srv/coop_far_reg.cpp", HOOKS_REG_SRV.replace("return false;", "return id > 1;")),
     "a static initializer with a call"),
    # C8: a static member of an Ядро class defined in a srv file
    ("C8", {}, {"engine/src/xrGame/coop/coop_far_limits.h": LIMITS_H,
                "engine/src/xrGame/coop/srv/coop_far_limits_srv.cpp": LIMITS_SRV},
     ("engine/src/xrGame/coop/srv/coop_far_limits_srv.cpp", LIMITS_SRV.replace("= 4", "= 2")),
     "defines the static member FarLimits::squads_per_player"),
    # C9: an overload in a srv file of a function Ядро defines and calls
    ("C9", {}, {"engine/src/xrGame/coop/coop_far_switch.cpp": SWITCH_CORE,
                "engine/src/xrGame/coop/srv/coop_far_switch_srv.cpp": SWITCH_SRV},
     ("engine/src/xrGame/coop/srv/coop_far_switch_srv.cpp", SWITCH_SRV.replace("> 1", "< 2")),
     "defines coop::may_switch, called from engine/src/xrGame/coop/coop_far_switch.cpp"),
    # C11: a member of a class declared in a srv header Ядро includes
    ("C11", {}, {"engine/src/xrCoop/srv/coop_book.h": BOOK_H, "engine/src/xrGame/coop/coop_debug.cpp": BOOK_CORE,
                 "engine/src/xrGame/coop/srv/coop_book.cpp": BOOK_SRV},
     ("engine/src/xrGame/coop/srv/coop_book.cpp", BOOK_SRV.replace("line > 0", "line > 1")),
     "a member of the class Book declared in the reached engine/src/xrCoop/srv/coop_book.h"),
])
def test_review3_srv_code_the_co_op_process_runs_is_core(repos, capsys, case, mod_files, engine_files, edit, why):
    root, engine, exe = repos
    setup_more(root, engine, mod_files, engine_files)
    path, text = edit
    if path.startswith("engine/"):
        write(engine, path[len("engine/"):], text)
        commit(engine, f"{case}: a server fix")
    else:
        write(root, path, text)
        commit(root, f"{case}: a server fix")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 1, out
    assert f"core     {path}" in out and why in out and "hostplay.ok missing" in out, out


def test_route_key_moved_to_another_section_is_core(repos, capsys):
    # C10: save_state leaves the forced callbacks and comes back under [route_scripts] as `level`
    root, engine, exe = repos
    setup_more(root, engine, {"gamedata/configs/coop_route_npc.ltx":
                              "[route_callbacks_forced]\nsave_state = host\n[route_scripts]\ncoop_npc_adapters = host\n"}, {})
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_callbacks_forced]\n[route_scripts]\nsave_state = level\n"
                                                       "coop_npc_adapters = host\n")
    commit(root, "a server fix of the routes")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "b2..HEAD", "--per-commit")
    assert code == 1 and "route table (H6)" in out and "hostplay.ok missing" in out, out
    # the working tree reads the file on disk against HEAD the same way
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_callbacks_forced]\n[route_scripts]\nsave_state = level\n"
                                                       "coop_npc_adapters = level\n")
    code, out = run(root, exe, capsys)
    assert "srv      gamedata/configs/coop_route_npc.ltx (route table: only host <-> level)" in out, out


# --- review 3: the stand's leftovers, its profiles and its folder (S1-S3) ---------------------------------------------

def test_stand_head_moves_leftovers_of_our_layers_and_check_names_them(work):
    root, stand = scenario_repo(work)
    backup = work / "backup"
    add_manifest(stand, {"rel": "gamedata/scripts/coop_compat_old.script",
                         "source": "B:\\dev-1\\Anomaly Coop - Core/gamedata\\scripts\\coop_compat_old.script"},
                 {"rel": "gamedata/scripts/some_mod.script", "source": "B:\\mo2\\mods\\7- A mod\\gamedata\\scripts\\some_mod.script"})
    write(stand, "gamedata/scripts/coop_compat_old.script", "-- our Core layer of dev-1, gone from HEAD\n")
    write(stand, "gamedata/scripts/coop_handmade.script", "-- copied by hand, no manifest names it\n")
    write(stand, "gamedata/scripts/coop_zz_stale.script", "-- a probe no scenario has\n")
    write(stand, "gamedata/scripts/some_mod.script", "-- a GAMMA mod's own script\n")
    shutil.copy2(STAND / "coop_zz_squads.script", stand / "gamedata/scripts/coop_zz_squads.script")  # HEAD's probe
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(backup))
    assert done.returncode == 0, done.stdout + done.stderr
    got = values(done.stdout)
    assert got["removed"] == "3" and got["stand_extra"] == "0", done.stdout
    for name in ("coop_compat_old.script", "coop_handmade.script", "coop_zz_stale.script"):
        assert not (stand / "gamedata/scripts" / name).exists() and (backup / "removed/gamedata/scripts" / name).is_file()
    assert (stand / "gamedata/scripts/some_mod.script").is_file()
    assert (stand / "gamedata/scripts/coop_zz_squads.script").is_file()
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(backup))
    assert check.returncode == 0, check.stdout
    # a leftover that comes back: check names it and removes nothing
    write(stand, "gamedata/scripts/coop_compat_old.script", "-- back again\n")
    check = stand_head(root, "check", "--stand", str(stand), "--backup", str(backup))
    assert check.returncode == 1 and "coop_compat_old.script" in check.stdout and "HEAD does not have" in check.stdout
    assert (stand / "gamedata/scripts/coop_compat_old.script").is_file()


def test_stand_head_keeps_a_coop_script_a_mod_ships_names_it_and_binds_its_bytes(work):
    # the stand's coop_compat_alq.script comes from the GAMMA mod "Alife CENSORED", not from our layers
    root, stand = scenario_repo(work)
    add_manifest(stand, {"rel": "gamedata/scripts/coop_compat_alq.script",
                         "source": "B:\\mo2\\mods\\Alife CENSORED\\gamedata\\scripts\\coop_compat_alq.script"})
    write(stand, "gamedata/scripts/coop_compat_alq.script", "-- A-Life Quests: the RayLink co-op layer\n")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout
    got = values(done.stdout)
    assert got["stand_foreign"] == "gamedata/scripts/coop_compat_alq.script" and got["stand_extra"] == "0", done.stdout
    assert "kept gamedata/scripts/coop_compat_alq.script: a GAMMA mod ships it" in done.stdout
    assert (stand / "gamedata/scripts/coop_compat_alq.script").is_file()
    assert got["stand_fingerprint"] == gates.stand_fingerprint(stand)
    write(stand, "gamedata/scripts/coop_compat_alq.script", "-- edited on the stand\n")
    assert gates.stand_fingerprint(stand) != got["stand_fingerprint"]


def test_stand_head_profile_writes_the_mode_cvars_from_head(work):
    root, stand = scenario_repo(work)
    write(stand, "appdata_t/user.ltx", "bind jump kSPACE\r\ncoop_world_server 1\r\ncoop_split_levels 1\r\n"
                                       "coop_nick tester\r\ncoop_mapserver_linger 5\r\n")
    write(stand, "appdata_other/user.ltx", "coop_world_server 1\n")  # a folder the template does not name
    done = stand_head(root, "profile", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 0, done.stdout
    text = (stand / "appdata_t/user.ltx").read_bytes()
    assert b"coop_world_server 1" not in text and b"coop_world_server 0\r\n" in text, text
    assert b"coop_split_levels 0\r\n" in text and b"coop_mapserver_linger 600\r\n" in text and b"linger 5" not in text
    assert text.startswith(b"bind jump kSPACE\r\n") and b"coop_nick tester\r\n" in text
    assert (stand / "appdata_other/user.ltx").read_text(encoding="utf-8") == "coop_world_server 1\n"
    assert (work / "backup/profiles/appdata_t/user.ltx").read_bytes().count(b"coop_world_server 1") == 1
    assert values(done.stdout)["profile_sha256"] == gates.profile_digest(root, "HEAD")
    again = stand_head(root, "profile", "--stand", str(stand), "--backup", str(work / "backup"))
    assert again.returncode == 0 and (stand / "appdata_t/user.ltx").read_bytes() == text


def test_the_checkers_the_runner_imports_are_part_of_the_stand_digest(work):
    # S3: stand_head imports check_gates.py and check_layers.py (the dirty check, the digests)
    assert {"tools/check_gates.py", "tools/check_layers.py"} <= set(gates.SCENARIO_PATHS)
    root, stand = scenario_repo(work)
    path = root / "tools" / "check_layers.py"
    path.write_text(path.read_text(encoding="utf-8") + "\n# relaxed\n", encoding="utf-8", newline="\n")
    done = stand_head(root, "deploy", "--stand", str(stand), "--backup", str(work / "backup"))
    assert done.returncode == 1 and "check_layers.py" in done.stdout, done.stdout


def test_stand_profile_template_names_only_mode_cvars():
    text = (STAND / "stand_profile.ltx").read_text(encoding="utf-8")
    rows = [l.split(";", 1)[0].strip() for l in text.splitlines()]
    rows = [r for r in rows if r]
    assert rows[0] == "[appdata_t]" and "[appdata_server]" in rows
    for row in rows:
        assert row.startswith("[") or re.match(r"coop_(split_levels|world_server|story_together|soft_host_move|"
                                               r"max_map_servers|map_servers_rev|mapserver_\w+) ", row), row
