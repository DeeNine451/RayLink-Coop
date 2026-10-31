"""Guard: no NEW `== Actor()` / `!= Actor()` comparison in the monsters' C++ (engine/src/xrGame/ai/monsters).

`Actor()` is the HOST's actor. A monster decision written as `enemy == Actor()` means "the host" and silently treats
a remote co-op client as something else (temp/enemy_audit.md F3: monsters that fled clients but never the host, dogs
that warned the host only, a burer shield that dropped for the host's reload only). The fix is always the same:
ask `coop::npc_ai::is_player(enemy)` (any player) or `is_remote_player(enemy)` (a client).

Scanned: every .cpp / .h / .inl under the folder, recursively. Comments and the inside of string / char literals are
ignored. A comparison is `== Actor()`, `!= Actor()`, `Actor() ==` or `Actor() !=` (spaces and line breaks allowed).

Allowed, in order of preference:
  1. a line that no longer compares with Actor() (use is_player / is_remote_player);
  2. a line whose comment carries the marker `actor-compare-ok` (the comparison is deliberate: say why in the comment);
  3. an entry of tools/actor_compare_allow.txt, today's occurrences: `path|code of the line|count`. The path is
     relative to the scanned folder, the code is the line without comments and with white space collapsed, the count
     is how many comparisons that line text holds in the file. No line numbers: edits elsewhere in a file do not
     break an entry, and fixing an occurrence only needs its entry removed.

  python -I tools/check_actor_compare.py [--root DIR] [--allow FILE] [--write-allow]

Exit 0: no new comparison (a stale allow entry is only a warning). Exit 1: new comparisons, listed as file:line.
Exit 2: the folder or the allow file is missing or unreadable. --write-allow rewrites the allow file from the tree
as it is (review the diff: every added entry is a comparison nobody has fixed).
"""
import argparse
import pathlib
import re
import sys
from typing import NamedTuple, Optional, Sequence

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SCAN = ROOT / "engine" / "src" / "xrGame" / "ai" / "monsters"
DEFAULT_ALLOW = ROOT / "tools" / "actor_compare_allow.txt"
SUFFIXES = frozenset({".cpp", ".h", ".inl"})
MARKER = "actor-compare-ok"
COMPARE = re.compile(r"(?:==|!=)\s*(?:::\s*)?Actor\s*\(\s*\)|\bActor\s*\(\s*\)\s*(?:==|!=)")
HEADER = (
    "# Today's `== Actor()` / `!= Actor()` comparisons in engine/src/xrGame/ai/monsters (tools/check_actor_compare.py).\n"
    "# One per line: path (relative to that folder) | code of the line, comments dropped, white space collapsed | count.\n"
    "# Fixing an occurrence (is_player / is_remote_player) means deleting its entry; the checker warns about stale ones.\n"
)

Key = tuple[str, str]  # (path relative to the scanned folder, normalised code of the line)


class Offender(NamedTuple):
    path: str
    line: int
    text: str
    found: int
    allowed: int


class Stale(NamedTuple):
    path: str
    text: str
    found: int
    allowed: int


def code_of(text: str) -> str:
    """The text with comments removed and string / char literal contents emptied. Line breaks are kept, so line
    numbers stay valid."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_block = False
    while i < n:
        c = text[i]
        if in_block:
            if text.startswith("*/", i):
                in_block = False
                i += 2
                out.append(" ")
            else:
                if c == "\n":
                    out.append("\n")
                i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            in_block = True
            i += 2
        elif c in "\"'":
            out.append(c)
            i += 1
            while i < n and text[i] != c and text[i] != "\n":
                i += 2 if text[i] == "\\" and i + 1 < n and text[i + 1] != "\n" else 1
            if i < n and text[i] == c:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def comparisons(text: str) -> list[tuple[int, str]]:
    """(line, normalised code of that line) of every comparison with Actor() in a source text. The line is the one
    the comparison starts on. A line with the marker in its comment is skipped."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    code = code_of(text)
    raw_lines = text.split("\n")
    code_lines = code.split("\n")
    found: list[tuple[int, str]] = []
    for m in COMPARE.finditer(code):
        line = code.count("\n", 0, m.start()) + 1
        if MARKER in raw_lines[line - 1]:
            continue
        found.append((line, " ".join(code_lines[line - 1].split())))
    return found


def scan(root: pathlib.Path) -> dict[Key, list[int]]:
    """Every comparison under root: {(relative path, line code): [line numbers]}."""
    found: dict[Key, list[int]] = {}
    for path in sorted(root.rglob("*")):
        if path.suffix not in SUFFIXES or not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        text = path.read_bytes().decode("cp1251", "replace")  # Latin-1 / cp1251 comments are not our business
        for line, code in comparisons(text):
            found.setdefault((rel, code), []).append(line)
    return found


def parse_allow(text: str) -> dict[Key, int]:
    """`path|code|count` lines. The code may hold '|' (`||`), so the path is cut at the first bar, the count at the last."""
    allowed: dict[Key, int] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            path, rest = line.split("|", 1)
            code, count = rest.rsplit("|", 1)
            allowed[(path.strip(), code.strip())] = int(count)
        except ValueError:
            raise ValueError(f"allow list line {number}: expected path|code|count, got: {raw!r}") from None
    return allowed


def format_allow(found: dict[Key, list[int]]) -> str:
    entries = sorted(f"{path}|{code}|{len(lines)}" for (path, code), lines in found.items())  # the order the test checks
    return HEADER + "".join(entry + "\n" for entry in entries)


def compare(found: dict[Key, list[int]], allowed: dict[Key, int]) -> tuple[list[Offender], list[Stale]]:
    """Offenders: every line of a (file, code) pair found more often than allowed. Stale: allowed more than found."""
    offenders: list[Offender] = []
    stale: list[Stale] = []
    for (path, code), lines in sorted(found.items()):
        allow = allowed.get((path, code), 0)
        if len(lines) > allow:
            offenders += [Offender(path, line, code, len(lines), allow) for line in lines]
    offenders.sort(key=lambda o: (o.path, o.line))
    for (path, code), allow in sorted(allowed.items()):
        have = len(found.get((path, code), []))
        if have < allow:
            stale.append(Stale(path, code, have, allow))
    return offenders, stale


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(DEFAULT_SCAN), help="the folder to scan (default: the monsters' sources)")
    ap.add_argument("--allow", default=str(DEFAULT_ALLOW), help="the allow list file")
    ap.add_argument("--write-allow", action="store_true", help="rewrite the allow list from the tree as it is")
    args = ap.parse_args(argv)

    root = pathlib.Path(args.root)
    allow_file = pathlib.Path(args.allow)
    if not root.is_dir():
        print(f"missing folder: {root}")
        return 2
    found = scan(root)
    if args.write_allow:
        allow_file.write_text(format_allow(found), encoding="utf-8", newline="\n")
        print(f"{allow_file}: {len(found)} entries, {sum(len(v) for v in found.values())} comparisons")
        return 0
    try:
        allowed = parse_allow(allow_file.read_text(encoding="utf-8")) if allow_file.is_file() else {}
    except (OSError, ValueError) as error:
        print(f"allow list unreadable: {error}")
        return 2

    offenders, stale = compare(found, allowed)
    prefix = root.as_posix()
    for s in stale:
        print(f"warning: stale allow entry (allowed {s.allowed}, found {s.found}): {s.path}|{s.text}")
    for o in offenders:
        extra = f"  [{o.found} found, {o.allowed} allowed]" if o.allowed else ""
        print(f"{prefix}/{o.path}:{o.line}: {o.text}{extra}")
    if offenders:
        print(f"{len(offenders)} comparison(s) with the host's Actor(): use coop::npc_ai::is_player / is_remote_player,\n"
              f"or mark a deliberate one with `// {MARKER}: why` (see tools/check_actor_compare.py)")
        return 1
    print(f"ok: {sum(len(v) for v in found.values())} allowed comparison(s), {len(stale)} stale allow entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
