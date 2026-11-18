"""tools/check_gates.py: which layers a change touches and which stand marks it needs (docs/MODES.md section 10).

Fake repositories: a temporary folder with `git init` (the mod) and engine/ inside it (its own repository), the
tools/ inputs of a tiny layer map, an exe file and marks written as the stand runners write them. The holes the
adversarial review found in the gate (temp/modes_review/attack_gates.py and gtrees/: rename, merge, relayer, marks;
srv headers that Ядро includes; server functions that Ядро calls without srv_entry.txt) are rebuilt here as commits,
and so are the second review's (temp/modes_review2/new_attacks.py N1-N4, N10-N14; quoted paths; the stand's tracked
scenarios and HEAD's gamedata: tools/stand/stand_head.py on a fake stand, no game is started).
Run: python -m pytest tests\\tools\\test_gates.py -q
"""
import hashlib
import json
import re
import shutil
import subprocess
import sys
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
    write(root, ".gitignore", "engine/\ntemp/\n")
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
    exe = work / "game.exe"
    exe.write_bytes(b"MZ the stand exe")
    return root, engine, exe


def mark(root: Path, engine: Path, exe: Path, which: str, drop: tuple[str, ...] = (), **override: str) -> None:
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
    }
    values.update(override)
    write(root, f"temp/gates/{which}.ok", "".join(f"{k}={v}\n" for k, v in values.items() if k not in drop))


def run(root: Path, exe: Path, capsys, *args: str) -> tuple[int, str]:
    code = gates.main(["--root", str(root), "--exe", str(exe), *args])
    return code, capsys.readouterr().out


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
])
def test_classify(repos, path, layer, why):
    root, _, _ = repos
    layers = gates.read_layers(root / "tools/layers.txt")
    got = gates.classify(path, layers, gates.allow_paths(root / "tools/layers_allow.txt"),
                         gates.entry_files(root, ["online_at_server"]), lambda p: "")
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
    got = gates.classify(name, gates.read_layers(root / "tools/layers.txt"), set(), set(), lambda p: "")
    assert got[0] == "core", got


def test_route_table_host_level_swap_is_srv_anything_else_core():
    swap = "@@ -2 +2 @@\n-coop_npc_adapters = host\n+coop_npc_adapters = level\n"
    other = "@@ -3 +3 @@\n-xr_x = view\n+xr_x = owner\n"
    added = "@@ -3,0 +4 @@\n+xr_y = level\n"
    assert gates.route_neutral(swap)
    assert not gates.route_neutral(other)
    assert not gates.route_neutral(added)


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
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert "required: srv.ok, unchanged co-op tests" in out
    assert "srv.ok missing" in out
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out
    assert "srv.ok OK" in out and "co-op tests 3 -> 3 (unchanged)" in out


def test_mark_of_other_ids_or_other_exe_does_not_count(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv", engine_head="0" * 40)
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1 and "engine 00000000 !=" in out, out
    mark(root, engine, exe, "srv")
    exe.write_bytes(b"MZ another build")
    code, out = run(root, exe, capsys, "base..HEAD")
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
])
def test_mark_without_mode_dirty_or_partial_does_not_count(repos, capsys, drop, override, why):
    # item 6
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver.cpp", "int ms() { return 3; }\n")
    commit(engine, "srv fix")
    mark(root, engine, exe, "srv", drop, **override)
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert "hostplay.ok missing" in out
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out


def test_edit_in_an_allow_listed_srv_file_is_core(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_mapserver_mixed.cpp", "void f() { if (is_map_server()) y(); }\n")
    commit(engine, "under an allowed line")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1 and "hostplay.ok missing" in out, out
    assert "has allow-list entries (H9)" in out


def test_hostplay_commit_needs_the_coop_mark(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    commit(root, "menu")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1 and "required: hostplay.ok" in out and "srv.ok" not in required(out), out
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out


def test_one_commit_with_hostplay_and_srv_is_refused(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_hostplay_menu.script", "function g() end\n")
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    commit(root, "both modes")
    mark(root, engine, exe, "hostplay")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert "split the commit" in out


def test_srv_change_that_moves_the_coop_test_count_fails(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/test_items.cpp", "TEST(a)\n{\n}\n")  # a co-op test removed with a server change
    commit(root, "srv and a test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert "co-op tests 3 -> 2" in out and "removed TEST(b)" in out


def test_srv_change_that_swaps_a_coop_test_fails(repos, capsys):
    # item 7: one co-op test removed and another added keeps the count; the set of names moved
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/test_items.cpp", "TEST(a)\n{\n}\nTEST(c)\n{\n}\n")
    commit(root, "srv and a swapped test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert "co-op tests 3 -> 3" in out and "removed TEST(b)" in out and "added TEST(c)" in out
    # a server test of its own (test_srv_*) may come with a server change
    sh(root, "tag", "swap")
    sh(engine, "tag", "swap")
    write(root, "tests/test_srv_far.cpp", "TEST(far)\n{\n}\n")
    write(root, "gamedata/scripts/coop_srv_far.script", "function h() end\n")
    commit(root, "srv and its own test")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "swap..HEAD")
    assert code == 0, out


def test_route_swap_commit_is_srv_and_other_route_edit_is_core(repos, capsys):
    root, engine, exe = repos
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_scripts]\ncoop_npc_adapters = level\nxr_x = view\n")
    commit(root, "swap")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out
    sh(root, "tag", "swap")
    sh(engine, "tag", "swap")
    write(root, "gamedata/configs/coop_route_npc.ltx", "[route_scripts]\ncoop_npc_adapters = level\nxr_x = owner\n")
    commit(root, "owner")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "swap..HEAD")
    assert code == 1 and "route table (H6)" in out and "hostplay.ok missing" in out, out


def test_output_hides_long_hex(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_items.cpp", "int items() { return 5; }\n")
    commit(engine, "core")
    mark(root, engine, exe, "srv")
    mark(root, engine, exe, "hostplay")
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "rel..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
    assert "split the commit" not in out, out
    assert code == 0, out


def test_layers_txt_reclassification_is_core(repos, capsys):
    # item 3 (gtrees/relayer): a row `srv gamedata/scripts/coop_items.script` and an edit of it in one commit
    root, engine, exe = repos
    write(root, "tools/layers.txt", LAYERS + "srv gamedata/scripts/coop_items.script\n")
    write(root, "gamedata/scripts/coop_items.script", "function f() return false end\n")
    commit(root, "relayer")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1, out
    assert why in out and "hostplay.ok missing" in out, out


def test_srv_file_nothing_of_core_reaches_stays_srv(repos, capsys):
    root, engine, exe = repos
    write(engine, "src/xrGame/coop/coop_far.cpp", "namespace coop::far\n{\nint far_only() { return 4; }\n}\n")
    commit(engine, "far")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "b2..HEAD")
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
    code, out = run(root, exe, capsys, "b2..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
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
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 0, out


def test_test_runner_edit_needs_both_marks(repos, capsys):
    # B10 / N14: tests/lua/run_all.lua, tools/test_lua.cmd and tools/build_tests.cmd decide which co-op tests run
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_srv_far.script", "function g() end\n")
    write(root, "tests/lua/run_all.lua", "COOP_LUA_MODES = { \"srv\" }\n")
    commit(root, "srv and the runner")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
    assert code == 1 and "core     tests/lua/run_all.lua" in out and "hostplay.ok missing" in out, out


def test_non_ascii_product_path_is_classified(repos, capsys):
    # B11: git quotes a non-ASCII path unless core.quotePath=false; a quoted path never matched PRODUCT
    root, engine, exe = repos
    write(root, "gamedata/scripts/coop_предметы.script", "function pick() return false end\n")
    write(root, "gamedata/scripts/coop_srv_x.script", "x = 1\n")
    commit(root, "cyrillic")
    mark(root, engine, exe, "srv")
    code, out = run(root, exe, capsys, "base..HEAD")
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
    write(root, ".gitignore", "engine/\ntemp/\ngamedata/scripts/coop_local.script\n")
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
    return root, stand


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
                                root, root / "engine")
    assert ok, text
    write(root, "gamedata/scripts/coop_items.script", "function pick() return 9 end\n")
    done = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                           f". '{root / 'tools' / 'stand_common.ps1'}'; Invoke-HeadDeploy -Stand '{stand}'"],
                          capture_output=True, text=True)
    assert done.returncode != 0 and "refused" in (done.stdout + done.stderr), done.stdout + done.stderr
