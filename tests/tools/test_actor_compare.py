"""tools/check_actor_compare.py: no new `== Actor()` / `!= Actor()` in the monsters' C++ (they mean "the host's actor")."""
import subprocess
import sys
from pathlib import Path

import pytest

import check_actor_compare as check
from conftest import ROOT

MONSTERS = ROOT / "engine" / "src" / "xrGame" / "ai" / "monsters"
SCRIPT = ROOT / "tools" / "check_actor_compare.py"

OFFENDING = "if (enemy == Actor())"
SOURCE = "void f()\n{\n\t" + OFFENDING + "\n\t\tg();\n}\n"


def tree(base: Path, files: dict[str, str]) -> Path:
    """A monsters-like folder with the given files (path -> text) under base/src."""
    root = base / "src"
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="")
    return root


def allow(base: Path, *lines: str) -> Path:
    path = base / "allow.txt"
    path.write_text("".join(line + "\n" for line in lines), encoding="utf-8", newline="")
    return path


def run(root: Path, allow_file: Path, capsys: pytest.CaptureFixture[str]) -> tuple[int, str]:
    code = check.main(["--root", str(root), "--allow", str(allow_file)])
    return code, capsys.readouterr().out


# --- the real tree ---------------------------------------------------------------------------------------------------

@pytest.mark.skipif(not MONSTERS.is_dir(), reason="engine sources are not checked out")
def test_real_tree_has_no_new_comparison(capsys):
    code = check.main([])
    out = capsys.readouterr().out
    assert code == 0, "a new `== Actor()` in ai/monsters (use coop::npc_ai::is_player):\n" + out


@pytest.mark.skipif(not MONSTERS.is_dir(), reason="engine sources are not checked out")
def test_real_tree_check_runs_as_a_script():
    done = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True, cwd=ROOT)
    assert done.returncode == 0, done.stdout + done.stderr
    assert done.stdout.strip().startswith(("ok:", "warning:"))


def test_allow_list_is_sorted_and_well_formed():
    lines = [l for l in check.DEFAULT_ALLOW.read_text(encoding="utf-8").splitlines() if l and not l.startswith("#")]
    assert lines, "the allow list is empty (is it deleted, or are all comparisons fixed? then delete this test)"
    assert lines == sorted(lines)
    allowed = check.parse_allow("\n".join(lines))
    assert len(allowed) == len(lines), "duplicate path|code entries"
    assert all(count > 0 for count in allowed.values())


# --- a new offender fails, with file:line ----------------------------------------------------------------------------

def test_new_comparison_fails_with_file_and_line(work, capsys):
    root = tree(work, {"burer/new_state.h": SOURCE, "dog/clean.cpp": "void g() {}\n"})
    code, out = run(root, allow(work), capsys)
    assert code == 1
    assert "burer/new_state.h:3:" in out
    assert "dog/clean.cpp" not in out


@pytest.mark.parametrize("text", [
    "if (e == Actor()) f();",
    "if (e != Actor()) f();",
    "if (Actor() == e) f();",
    "if (Actor() != e) f();",
    "if (e==Actor()) f();",
    "if (e == ::Actor ( )) f();",
    "bool b = (e ==\n\t\tActor());",
    "bool b = (e == Actor()->ID());",
])
def test_every_spelling_is_found(work, capsys, text):
    root = tree(work, {"x.cpp": "\n\n" + text + "\n"})
    code, out = run(root, allow(work), capsys)
    assert code == 1 and "x.cpp:3:" in out, out


def test_every_source_suffix_is_scanned_and_others_are_not(work, capsys):
    root = tree(work, {"a/one.cpp": SOURCE, "a/b/two.h": SOURCE, "c/three.inl": SOURCE, "c/notes.txt": SOURCE, "d/x.py": SOURCE})
    code, out = run(root, allow(work), capsys)
    assert code == 1
    assert "a/one.cpp:3:" in out and "a/b/two.h:3:" in out and "c/three.inl:3:" in out
    assert "notes.txt" not in out and "x.py" not in out


@pytest.mark.parametrize("text", [
    "// if (e == Actor())",
    "f(); // not e != Actor() here",
    "/* e == Actor() */",
    "/* a\n   b == Actor()\n   c */ f();",
    'Msg("e == Actor()");',
    "if (e == other_actor()) f();",
    "if (e == MyActor()) f();",
])
def test_comments_strings_and_other_names_are_not_comparisons(work, capsys, text):
    root = tree(work, {"x.cpp": text + "\n"})
    code, out = run(root, allow(work), capsys)
    assert code == 0, out


def test_crlf_files_report_the_same_lines(work, capsys):
    root = tree(work, {"x.cpp": SOURCE.replace("\n", "\r\n")})
    code, out = run(root, allow(work), capsys)
    assert code == 1 and "x.cpp:3:" in out


# --- an allowed line passes ------------------------------------------------------------------------------------------

def test_allowed_line_passes(work, capsys):
    root = tree(work, {"burer/state.h": SOURCE})
    code, out = run(root, allow(work, f"burer/state.h|{OFFENDING}|1"), capsys)
    assert code == 0, out
    assert "warning" not in out


def test_allowed_line_survives_edits_elsewhere_in_the_file(work, capsys):
    allowed = allow(work, f"burer/state.h|{OFFENDING}|1")
    root = tree(work, {"burer/state.h": SOURCE})
    assert run(root, allowed, capsys)[0] == 0
    tree(work, {"burer/state.h": "// a new header comment\n#include <x>\n\n" + SOURCE + "void more() {}\n"})
    assert run(root, allowed, capsys)[0] == 0


def test_allowed_line_ignores_comment_and_spacing_changes(work, capsys):
    allowed = allow(work, f"burer/state.h|{OFFENDING}|1")
    root = tree(work, {"burer/state.h": "void f()\n{\n    if (enemy  ==  Actor())  // Anomaly Coop: reworded\n    g();\n}\n"})
    code, out = run(root, allowed, capsys)
    assert code == 0, out


def test_allow_entry_is_per_file_and_per_text(work, capsys):
    allowed = allow(work, f"burer/state.h|{OFFENDING}|1")
    root = tree(work, {"burer/state.h": SOURCE, "dog/state.h": SOURCE, "burer/other.h": "if (who != Actor()) f();\n"})
    code, out = run(root, allowed, capsys)
    assert code == 1
    assert "dog/state.h:3:" in out and "burer/other.h:1:" in out
    assert "burer/state.h:3:" not in out


def test_count_limits_the_number_of_copies(work, capsys):
    allowed = allow(work, f"x.cpp|{OFFENDING}|1")
    root = tree(work, {"x.cpp": SOURCE + SOURCE})
    code, out = run(root, allowed, capsys)
    assert code == 1
    assert "x.cpp:3:" in out and "x.cpp:8:" in out and "2 found, 1 allowed" in out
    assert run(root, allow(work, f"x.cpp|{OFFENDING}|2"), capsys)[0] == 0


def test_marker_in_the_comment_allows_a_line(work, capsys):
    root = tree(work, {"x.cpp": "if (e == Actor()) f(); // actor-compare-ok: the host's reload only, by design\n"})
    code, out = run(root, allow(work), capsys)
    assert code == 0, out


# --- a stale entry warns, it does not fail ---------------------------------------------------------------------------

def test_stale_entry_is_a_warning(work, capsys):
    root = tree(work, {"x.cpp": "if (coop::npc_ai::is_player(e)) f();\n"})
    code, out = run(root, allow(work, f"x.cpp|{OFFENDING}|1", "gone.cpp|if (a == Actor())|2"), capsys)
    assert code == 0
    assert out.count("warning: stale allow entry") == 2
    assert "x.cpp" in out and "gone.cpp" in out


def test_fewer_copies_than_allowed_is_stale(work, capsys):
    root = tree(work, {"x.cpp": SOURCE})
    code, out = run(root, allow(work, f"x.cpp|{OFFENDING}|3"), capsys)
    assert code == 0
    assert "stale" in out and "allowed 3, found 1" in out


# --- the tool itself -------------------------------------------------------------------------------------------------

def test_write_allow_makes_the_tree_pass(work, capsys):
    root = tree(work, {"a.cpp": SOURCE + SOURCE, "b/c.h": "bool x = Actor() != who || y == Actor();\n"})
    allowed = work / "generated.txt"
    assert check.main(["--root", str(root), "--allow", str(allowed), "--write-allow"]) == 0
    capsys.readouterr()
    entries = [l for l in allowed.read_text(encoding="utf-8").splitlines() if not l.startswith("#")]
    assert entries == sorted(entries)
    assert f"a.cpp|{OFFENDING}|2" in entries
    assert "b/c.h|bool x = Actor() != who || y == Actor();|2" in entries  # '|' inside the code is kept
    code, out = run(root, allowed, capsys)
    assert code == 0, out


def test_missing_folder_and_bad_allow_file_exit_2(work, capsys):
    assert run(work / "nope", allow(work), capsys)[0] == 2
    root = tree(work, {"x.cpp": "int x;\n"})
    code, out = run(root, allow(work, "this is not an entry"), capsys)
    assert code == 2 and "allow list" in out
