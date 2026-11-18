"""Gate: which layers a change touches and which stand runs it needs before it ships (docs/MODES.md sections 3 and 10).

  python -I tools/check_gates.py [RANGE] [--engine-range RANGE] [--root DIR] [--marks DIR] [--exe PATH]

RANGE is a git range of this repository (`dev-57..HEAD`), --engine-range one of engine/ (its own repository; the
default is RANGE: release tags exist in both repositories; when the engine does not know them, pass --engine-range).
Without RANGE: the working tree against HEAD in both repositories (staged, unstaged and untracked files).
Renames count with both paths (git --no-renames): moving an Ядро file to a srv name is an Ядро change. A merge commit
counts with its diff against its first parent (git --diff-merges=first-parent): an edit made while merging is seen;
the side branch's own commits are in the range too. Every git call runs with core.quotePath=false (a non-ASCII path
comes raw); a quoted path is a GateError (exit 2), never "outside the product".

Layer of a changed file (tools/layers.txt through tools/check_layers.py), with these files counted as Ядро (core)
whatever their row says:
  - the lists and the tools that decide layers and gates: tools/layers.txt, layers_allow.txt, srv_entry.txt,
    persisted_keys.txt, stock_files.txt, check_layers.py, check_gates.py, release.py, stand_common.ps1,
    stand_hostplay.ps1, stand_srv.ps1 (a one-line list edit could otherwise turn an Ядро file into srv); the runners of
    the co-op tests tools/test_lua.cmd, tools/build_tests.cmd, tests/lua/run_all.lua; the stand's scenarios and probes
    (everything under tools/stand/, and tools/ded_check.ps1);
  - a file with entries in tools/layers_allow.txt (critique H9: an edit under an allowed line is an Ядро edit);
  - a stock engine file (rule 8) and a hybrid file of the `dying` layer (removing it changes co-op);
  - xrCoop/coop_protocol.h (one protocol for both modes);
  - a route table gamedata/configs/coop_route*.ltx, unless every changed line only turns `host` into `level` or back
    (both run on the co-op host: then srv) (critique H6);
  - a `gate-core` row of layers.txt (the 9 server scripts until step S4, critique H4);
  - the file that defines a function of tools/srv_entry.txt (critique H5);
  - a srv or hostplay file that Ядро, stock (also the stock-patch scripts of engine/gamedata/scripts and
    gamedata_gamma/scripts) or dying code reaches (tools/check_layers.core_reach, on the working tree): included by it
    (transitively: its code is compiled into Ядро), defining a function it calls (`ns::f`, `Class::f`, a bare call in
    its namespaces), a script it names (Lua, a C++ string like lua_getglobal(L, "coop_dedicated"), a config's
    `coop_x.fn`), defining a global it declares `extern`, defining a member of a class only it defines, or holding a
    static initializer that calls a function (that runs in every process). Then, to a fixed point, whatever such a
    reached file (or a gate-core / srv_entry file) includes, calls or names is reached too. That code runs in both
    modes, so an edit of it is an Ядро edit until the reference goes through mode() (step S4).
Paths outside the product (docs/, tests/, temp/, the other tools/, *.md, engine/README.md, engine/.github, ...) need no
gate: the product is gamedata/, gamedata_gamma/, engine/src/ and engine/gamedata/.

Gates: Ядро -> both stand marks; srv -> the server stand mark, an unchanged SET of co-op tests (the names of the
native TEST( in tests/*.cpp and the Lua files tests/lua/test_*.lua, both without test_srv_*) and no edit of any other
file under tests/ or of the test runners (only test_srv_* files may come with a srv-only change); hostplay -> the
co-op stand mark. One commit that touches hostplay and srv without Ядро is refused: split it (a merge is exempt: its
side commits are checked one by one). The marks are temp/gates/hostplay.ok and temp/gates/srv.ok, written by
tools/stand_hostplay.ps1 and tools/stand_srv.ps1 on success:
  mode=hostplay|srv  mod_head=<id>  engine_head=<id>  exe=<path>  exe_sha256=<hex>  time=<ISO time>  scenarios=<names>
  dirty=<uncommitted product files, tracked or not, when the stand ran>
  scenarios_sha256=<the scenario files that ran>  gamedata_sha256=<the gamedata the runner deployed from HEAD>
A mark counts only with its own mode, dirty=0, every scenario of its runner (SCENARIOS below), the same two HEAD ids
(the range's ends), the same exe (--exe, default the stand's exe), scenarios_sha256 equal to the digest of HEAD's
blobs of SCENARIO_PATHS and gamedata_sha256 equal to the digest of HEAD's deployable gamedata (gamedata,
gamedata_gamma, the engine's gamedata). Uncommitted product changes are never covered by a mark (the stand ran HEAD's
build; its runner refuses to start on a dirty tree).

Exit 0: every required mark is there. 1: a mark is missing or does not count, a commit is refused, or a srv-only
change moved or edited the co-op tests. 2: git or an input file failed, or git printed a quoted path.
"""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # -I leaves the script's folder out
import check_layers  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_EXE = pathlib.Path(r"E:\RayLinkGames\GAMMA\game-dev\bin\AnomalyCoopDX11AVX.exe")
PROTOCOL = "engine/src/xrCoop/coop_protocol.h"
ROUTE = re.compile(r"^gamedata/configs/coop_route[^/]*\.ltx$", re.I)
# the product: our gamedata layers and the engine's sources and gamedata (an engine README or CI edit needs no stand)
PRODUCT = re.compile(r"^(engine/(?:src|gamedata)/|gamedata/|gamedata_gamma/)", re.I)
MARKS = ("hostplay", "srv")
# the lists and tools that decide what a change is and what it needs, the runners of the co-op tests (B10) and the
# stand's scenarios (B12): an edit of them is an Ядро change
GATE_FILES = frozenset([f"tools/{name}" for name in (
    "layers.txt", "layers_allow.txt", "srv_entry.txt", "persisted_keys.txt", "stock_files.txt", "check_layers.py",
    "check_gates.py", "release.py", "stand_common.ps1", "stand_hostplay.ps1", "stand_srv.ps1", "ded_check.ps1",
    "test_lua.cmd", "build_tests.cmd")] + ["tests/lua/run_all.lua"])
GATE_DIRS = ("tools/stand/",)
# what a stand mark certifies: the scenario files that ran (tools/stand is tracked; temp/stand keeps the run history)
SCENARIO_PATHS = ("tools/stand", "tools/stand_common.ps1", "tools/stand_hostplay.ps1", "tools/stand_srv.ps1",
                  "tools/ded_check.ps1")
# the co-op tests and their runners: a srv-only change may add or edit only test_srv_* files there (B10)
TEST_PATHS = ("tests", "tools/test_lua.cmd", "tools/build_tests.cmd")
# what tools/stand/stand_head.py deploys to the stand: HEAD's gamedata of the three layers, without the files the game
# writes itself (axr_options.ltx) and without leftovers (as tools/stand_overlay.py)
GAMEDATA_SOURCES = (("mod", "gamedata"), ("mod", "gamedata_gamma"), ("engine", "gamedata"))
DEPLOY_SKIP_NAMES = frozenset({"axr_options.ltx", "cache_dbg.ltx"})
DEPLOY_SKIP_EXT = frozenset({".bak", ".tmp", ".log", ".orig"})
# every scenario of each stand runner (tools/stand_hostplay.ps1, tools/stand_srv.ps1; tests/tools/test_gates.py keeps
# the two in step): a mark of a part of the stand does not count
SCENARIOS = {
    "hostplay": ("carry_group", "base_group", "sil_group", "squads_group", "sp_smoke"),
    "srv": ("ded_check", "base_server", "carry_server", "taskboard_ws"),
}


class GateError(Exception):
    pass


# ---- the layer map (tools/check_layers.py reads the same files) ---------------------------------------------------

def read_layers(path: pathlib.Path) -> check_layers.LayerMap:
    try:
        return check_layers.parse_layers(path.read_text(encoding="utf-8"), path.resolve().parent.parent)
    except check_layers.InputError as error:
        raise GateError(str(error)) from None


def allow_paths(path: pathlib.Path) -> set[str]:
    paths = set()
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            if raw and not raw.startswith("#") and raw.count("|") >= 3:
                paths.add(raw.split("|", 2)[1].strip().lower())
    return paths


def entry_files(root: pathlib.Path, names: list[str]) -> set[str]:
    """Files under engine/src that define a function of srv_entry.txt (`ns::name` needs that namespace in the file)."""
    found: set[str] = set()
    engine = root / "engine" / "src"
    if not engine.is_dir() or not names:
        return found
    folders = [engine / "xrGame" / "coop", engine / "xrCoop", engine / "xrEngine"]
    for folder in folders:
        if not folder.is_dir():
            continue
        for path in sorted(folder.rglob("*.cpp")) + sorted(folder.rglob("*.h")):
            text = path.read_bytes().decode("utf-8", "replace")
            for name in names:
                ns, _, short = name.rpartition("::")
                if ns and not re.search(rf"\bnamespace\s+(?:[\w:]*::)?{re.escape(ns)}\b", text):
                    continue
                # a definition: at the start of a line, a return type, the name, a parameter list, no `;` before `{`
                if re.search(rf"(?m)^[A-Za-z_][\w:<>\s\*&]*\b{re.escape(short)}\s*\([^;{{]*\)\s*(?:const\s*)?\{{", text) or \
                        re.search(rf"(?m)^[A-Za-z_][\w:<>\s\*&]*\b{re.escape(short)}\s*\([^;{{]*\)\s*(?:const\s*)?\n\s*\{{", text):
                    found.add(path.relative_to(root).as_posix().lower())
    return found


# ---- git ----------------------------------------------------------------------------------------------------------

def git(repo: pathlib.Path, *args: str) -> str:
    # core.quotePath=false: a non-ASCII path comes as it is, not as "gamedata/\320\277..." that matches no row (B11)
    done = subprocess.run(["git", "-C", str(repo), "-c", "core.quotePath=false", *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if done.returncode != 0:
        raise GateError(f"git {' '.join(args)} in {repo}: {done.stderr.strip()[:300]}")
    return done.stdout


def tree_blobs(repo: pathlib.Path, ref: str, paths: Sequence[str], prefix: str = "") -> list[tuple[str, str]]:
    """(path, blob id) of every file under paths at ref (git ls-tree -r -z: raw paths)."""
    out = []
    for item in git(repo, "ls-tree", "-r", "-z", ref, "--", *paths).split("\0"):
        meta, _, path = item.partition("\t")
        parts = meta.split()
        if len(parts) == 3 and parts[1] == "blob":
            out.append((prefix + path, parts[2]))
    return out


def digest(entries: Sequence[tuple[str, str]]) -> str:
    """SHA-256 of the sorted `path<TAB>blob id` lines (the stand runner computes the same from what it deployed)."""
    return hashlib.sha256("".join(f"{p}\t{b}\n" for p, b in sorted(entries)).encode("utf-8")).hexdigest()


def deployable(path: str) -> bool:
    """A gamedata file the stand gets (tools/stand_overlay.py's rules)."""
    parts = path.split("/")
    name = parts[-1]
    return not (name in DEPLOY_SKIP_NAMES or pathlib.PurePosixPath(name).suffix.lower() in DEPLOY_SKIP_EXT
                or "temp" in parts[1:] or "__pycache__" in parts)


def gamedata_entries(root: pathlib.Path, engine: Optional[pathlib.Path], mod_ref: str,
                     engine_ref: Optional[str]) -> list[tuple[str, str]]:
    """(project path, blob id) of the gamedata the stand runs: gamedata and gamedata_gamma of the project at mod_ref, the
    engine's gamedata at engine_ref (as engine/gamedata/...)."""
    entries = []
    for repo_name, folder in GAMEDATA_SOURCES:
        if repo_name == "mod":
            entries += tree_blobs(root, mod_ref, [folder])
        elif engine is not None and engine_ref:
            entries += tree_blobs(engine, engine_ref, [folder], "engine/")
    return [(p, b) for p, b in entries if deployable(p)]


def gamedata_digest(root: pathlib.Path, engine: Optional[pathlib.Path], mod_ref: str, engine_ref: Optional[str]) -> str:
    return digest(gamedata_entries(root, engine, mod_ref, engine_ref))


def scenarios_digest(root: pathlib.Path, ref: str) -> str:
    """The scenario files of both stands at ref (tools/stand and the runners)."""
    return digest(tree_blobs(root, ref, list(SCENARIO_PATHS)))


def head(repo: pathlib.Path, ref: str = "HEAD") -> str:
    return git(repo, "rev-parse", "--verify", ref + "^{commit}").strip()


def worktree_files(repo: pathlib.Path) -> list[str]:
    files = set(git(repo, "diff", "--name-only", "--no-renames", "HEAD").splitlines())
    files |= set(git(repo, "ls-files", "--others", "--exclude-standard").splitlines())
    return sorted(f for f in files if f)


def range_files(repo: pathlib.Path, rng: str) -> list[tuple[str, list[str], bool]]:
    """(commit, files, is a merge) of every commit of the range, oldest first, in one git call. Both paths of a rename;
    a merge with its diff against its first parent."""
    out: list[tuple[str, list[str], bool]] = []
    for line in git(repo, "log", "--reverse", "--diff-merges=first-parent", "--no-renames", "--format=@@%H %P",
                    "--name-only", rng).splitlines():
        if line.startswith("@@"):
            ids = line[2:].split()
            out.append((ids[0], [], len(ids) > 2))
        elif line.strip() and out:
            out[-1][1].append(line.strip())
    return out


def engine_base(engine: pathlib.Path, base: str, end: str) -> str:
    """The engine's release tags point to a public snapshot commit (its tree on top of the public main, message
    "Source tree: <id>"), not to a commit of the source branch: use that source id when the tag is no ancestor of end."""
    sha = head(engine, base)
    done = subprocess.run(["git", "-C", str(engine), "merge-base", "--is-ancestor", sha, end], capture_output=True)
    if done.returncode == 0:
        return sha
    m = re.search(r"Source tree:\s*([0-9a-f]{40})", git(engine, "log", "-1", "--format=%B", sha))
    if not m:
        raise GateError(f"engine: {base} is not an ancestor of {end} and names no source tree; pass --engine-range")
    return m.group(1)


def route_neutral(diff: str) -> bool:
    """True when every changed line of a unified diff only swaps `host` and `level` (route domains)."""
    removed = [l[1:] for l in diff.splitlines() if l.startswith("-") and not l.startswith("---")]
    added = [l[1:] for l in diff.splitlines() if l.startswith("+") and not l.startswith("+++")]
    if not removed or len(removed) != len(added):
        return False
    swap = re.compile(r"\b(host|level)\b")
    for old, new in zip(removed, added):
        if old == new or swap.sub("D", old) != swap.sub("D", new):
            return False
    return True


# ---- classification -----------------------------------------------------------------------------------------------

@dataclass
class Unit:
    """One commit (or the working tree) and the layers of its files."""
    label: str
    files: dict[str, tuple[str, str]] = field(default_factory=dict)  # path -> (layer, why)
    merge: bool = False

    def layers(self) -> set[str]:
        return {layer for layer, _ in self.files.values() if layer != "none"}


def classify(path: str, layers: check_layers.LayerMap, allowed: set[str], entries: set[str],
             diff_of: Callable[[str], str], reach: Optional[dict[str, str]] = None) -> tuple[str, str]:
    if path.startswith('"'):
        raise GateError(f"a quoted path from git (core.quotePath): {path}; the gate reads raw paths only")
    low = path.lower()
    if low in GATE_FILES or low.startswith(GATE_DIRS):
        return "core", "decides layers and gates (a list, a checker, a test runner or a stand scenario)"
    if not PRODUCT.match(path):
        return "none", "outside the product"
    if ROUTE.match(path):
        return ("srv", "route table: only host <-> level") if route_neutral(diff_of(path)) else ("core", "route table (H6)")
    if low == PROTOCOL.lower():
        return "core", "protocol header"
    if low in allowed:
        return "core", "has allow-list entries (H9)"
    if low in entries:
        return "core", "defines a server entry point (H5)"
    if layers.gate_row(path) == "gate-core":
        return "core", "server script that still runs in co-op (H4)"
    layer = layers.layer_of(path)
    if layer == "stock":
        return "core", "stock engine file (rule 8)"
    if layer == "dying":
        return "core", "hybrid code (dying)"
    if reach and low in reach:
        return "core", f"runs in both modes: {reach[low]}"
    return layer, layer


def coop_tests(repo: pathlib.Path, ref: Optional[str]) -> Counter[str]:
    """The co-op tests: names of the native TEST( in tests/*.cpp and the Lua files tests/lua/test_*.lua, both without
    test_srv_*; at ref, or on disk."""
    def is_coop(name: str) -> bool:
        return not name.rsplit("/", 1)[-1].startswith("test_srv_")

    def native(text: str) -> list[str]:
        return [f"TEST({m.group(1).strip()})" for m in re.finditer(r"(?m)^\s*TEST\s*\(\s*([^)]*?)\s*\)", text)]

    names: Counter[str] = Counter()
    if ref is None:
        tests = repo / "tests"
        for path in sorted(tests.glob("*.cpp")) if tests.is_dir() else []:
            if is_coop(path.name):
                names.update(native(path.read_text(encoding="utf-8", errors="replace")))
        lua = tests / "lua"
        names.update(f"lua:{p.name}" for p in (lua.glob("test_*.lua") if lua.is_dir() else []) if is_coop(p.name))
        return names
    for name in git(repo, "ls-tree", "-r", "--name-only", ref, "--", "tests").splitlines():
        if re.fullmatch(r"tests/[^/]+\.cpp", name) and is_coop(name):
            names.update(native(git(repo, "show", f"{ref}:{name}")))
        elif re.fullmatch(r"tests/lua/test_[^/]+\.lua", name) and is_coop(name):
            names[f"lua:{name.rsplit('/', 1)[-1]}"] += 1
    return names


# ---- marks --------------------------------------------------------------------------------------------------------

def read_mark(path: pathlib.Path) -> Optional[dict[str, str]]:
    if not path.is_file():
        return None
    out = {}
    for raw in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        if "=" in raw:
            k, v = raw.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def sha256_of(path: pathlib.Path) -> Optional[str]:
    if not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def short(value: Optional[str]) -> str:
    return (value or "-")[:8]


def check_mark(mode: str, marks: pathlib.Path, mod_head: str, engine_head: str, exe_hash: Optional[str],
               root: Optional[pathlib.Path] = None, engine: Optional[pathlib.Path] = None) -> tuple[bool, str]:
    """A mark counts with its own mode, dirty=0, every scenario, both HEAD ids, the exe, and (with root) the scenario
    files and the gamedata of those HEADs: scenarios_sha256 and gamedata_sha256 recomputed from HEAD's blobs."""
    mark = read_mark(marks / f"{mode}.ok")
    if mark is None:
        return False, f"{mode}.ok missing (run tools\\stand_{mode}.ps1)"
    problems = []
    if root is not None:
        for key, what, want in (
                ("scenarios_sha256", "scenario files", lambda: scenarios_digest(root, mod_head)),
                ("gamedata_sha256", "gamedata", lambda: gamedata_digest(root, engine, mod_head, engine_head or None))):
            have = mark.get(key, "").lower()
            if not have:
                problems.append(f"{key} missing (a mark of an older runner)")
                continue
            try:
                expected = want()
            except GateError as error:
                problems.append(f"{what}: {error}")
                continue
            if have != expected:
                problems.append(f"{what} {short(have)} != HEAD's {short(expected)} (the stand ran other "
                                f"{'scenarios' if key.startswith('scen') else 'gamedata'} than HEAD's)")
    if mark.get("mode") != mode:
        problems.append(f"mode {mark.get('mode') or 'missing'}")
    if mark.get("dirty") != "0":
        problems.append(f"the stand ran a dirty tree (dirty={mark.get('dirty') or 'missing'}): its exe may hold "
                        "uncommitted code")
    ran = {s.strip() for s in mark.get("scenarios", "").split(",") if s.strip()}
    missing = [s for s in SCENARIOS[mode] if s not in ran]
    if missing:
        problems.append(f"a part of the stand: {', '.join(missing)} did not run")
    if mark.get("mod_head", "").lower() != mod_head.lower():
        problems.append(f"mod {short(mark.get('mod_head'))} != {short(mod_head)}")
    if mark.get("engine_head", "").lower() != engine_head.lower():
        problems.append(f"engine {short(mark.get('engine_head'))} != {short(engine_head)}")
    if exe_hash is None:
        problems.append("the exe to compare with is missing")
    elif mark.get("exe_sha256", "").lower() != exe_hash.lower():
        problems.append(f"exe {short(mark.get('exe_sha256'))} != {short(exe_hash)}")
    if problems:
        return False, f"{mode}.ok does not count: " + ", ".join(problems)
    return True, f"{mode}.ok OK (mod {short(mod_head)}, engine {short(engine_head)}, exe {short(exe_hash)}, {mark.get('time', '?')})"


# ---- main ---------------------------------------------------------------------------------------------------------

@dataclass
class Result:
    units: list[Unit]
    required: set[str]
    lines: list[str]
    failures: list[str]


def evaluate(root: pathlib.Path, rng: Optional[str], engine_rng: Optional[str], marks: pathlib.Path,
             exe: pathlib.Path) -> Result:
    tools = root / "tools"
    if not (tools / "layers.txt").is_file():
        raise GateError(f"missing input file layers.txt: {tools / 'layers.txt'}")
    layers = read_layers(tools / "layers.txt")
    allowed = allow_paths(tools / "layers_allow.txt")
    names = []
    if (tools / "srv_entry.txt").is_file():
        names = check_layers.parse_names((tools / "srv_entry.txt").read_text(encoding="utf-8"))
    entries = entry_files(root, names)
    model = check_layers.build(root, layers, names)
    # the files the gate counts as Ядро for another reason (gate-core rows, the files of srv_entry.txt) run in the co-op
    # process too: what they include, call or name is reached as well
    roots = sorted(entries | {s.path for s in model.sources if layers.gate_row(s.path) == "gate-core"})
    reach = check_layers.core_reach(model, roots)
    engine = root / "engine"
    has_engine = (engine / ".git").exists()

    def sort(path: str, diff_of: Callable[[str], str]) -> tuple[str, str]:
        return classify(path, layers, allowed, entries, diff_of, reach)

    units: list[Unit] = []
    lines: list[str] = []
    dirty_product: list[str] = []
    if rng is None:
        unit = Unit("working tree")
        for repo, prefix in [(root, "")] + ([(engine, "engine/")] if has_engine else []):
            for f in worktree_files(repo):
                path = prefix + f
                unit.files[path] = sort(path, lambda p, r=repo, pre=prefix: git(r, "diff", "-U0", "HEAD", "--", p[len(pre):]))
        units.append(unit)
        dirty_product = [p for p, (layer, _) in unit.files.items() if layer != "none"]
        mod_end = head(root)
        engine_end = head(engine) if has_engine else ""
        test_base, test_end = "HEAD", None
        lines.append(f"gates: working tree against HEAD (mod {short(mod_end)}, engine {short(engine_end)})")
    else:
        if ".." not in rng:
            raise GateError(f"a range is A..B, got {rng!r}")
        base, end = rng.split("..", 1)
        end = end or "HEAD"
        for sha, files, merge in range_files(root, rng):
            unit = Unit(f"mod {sha[:8]}" + (" (merge)" if merge else ""), merge=merge)
            for f in files:
                unit.files[f] = sort(f, lambda p, s=sha, m=merge: git(
                    root, "show", "-U0", "--format=", *(["--diff-merges=first-parent"] if m else []), s, "--", p))
            units.append(unit)
        mod_end = head(root, end)
        engine_end = ""
        if has_engine:
            erng = engine_rng or rng
            ebase, eend = erng.split("..", 1)
            eend = eend or "HEAD"
            erng = f"{engine_base(engine, ebase, eend)}..{eend}"
            for sha, files, merge in range_files(engine, erng):
                unit = Unit(f"engine {sha[:8]}" + (" (merge)" if merge else ""), merge=merge)
                for f in files:
                    path = "engine/" + f
                    unit.files[path] = sort(path, lambda p, s=sha, m=merge: git(
                        engine, "show", "-U0", "--format=", *(["--diff-merges=first-parent"] if m else []), s, "--",
                        p[7:]))
                units.append(unit)
            engine_end = head(engine, eend)
        test_base, test_end = base, end
        lines.append(f"gates: {rng} (mod {short(mod_end)}, engine {short(engine_end)}), {len(units)} commit(s)")

    failures: list[str] = []
    required: set[str] = set()
    counts = {"core": 0, "srv": 0, "hostplay": 0, "none": 0}
    for unit in units:
        for path, (layer, why) in sorted(unit.files.items()):
            counts[layer if layer in counts else "core"] += 1
        got = unit.layers()
        if "hostplay" in got and "srv" in got and "core" not in got and not unit.merge:
            failures.append(f"gates: {unit.label} touches hostplay and srv without Ядро: split the commit "
                            "(docs/MODES.md section 10)")
        if "core" in got:
            required |= {"hostplay", "srv"}
        if "srv" in got:
            required |= {"srv", "tests"}
        if "hostplay" in got:
            required.add("hostplay")
    if "hostplay" in required:
        required.discard("tests")  # the co-op stand covers co-op; the test rule is for a server-only change
    lines.append(f"gates: core {counts['core']} file(s), srv {counts['srv']}, hostplay {counts['hostplay']}, "
                 f"outside the product {counts['none']}")
    for unit in units:
        for path, (layer, why) in sorted(unit.files.items()):
            if layer != "none":
                lines.append(f"gates:   {unit.label}: {layer:8s} {path} ({why})")
    needs = []
    if "hostplay" in required or "srv" in required:
        needs = [m for m in MARKS if m in required]
        lines.append("gates: required: " + ", ".join(f"{m}.ok" for m in needs) +
                     (", unchanged co-op tests" if "tests" in required else ""))
    else:
        lines.append("gates: required: nothing (no product file changed)")
    exe_hash = sha256_of(exe) if needs else None
    for mode in needs:
        ok, text = check_mark(mode, marks, mod_end, engine_end, exe_hash, root, engine if has_engine else None)
        lines.append("gates: " + text)
        if not ok:
            failures.append("gates: " + text)
    if needs and dirty_product:
        failures.append(f"gates: {len(dirty_product)} uncommitted product file(s): a stand mark covers committed HEADs "
                        "only; commit, build, run the stand")
    if "tests" in required:
        before = coop_tests(root, test_base)
        after = coop_tests(root, test_end)
        gone = sorted((before - after).elements())
        new = sorted((after - before).elements())
        text = f"co-op tests {sum(before.values())} -> {sum(after.values())}"
        if gone or new:
            text += " (" + "; ".join(part for part in (
                "removed " + ", ".join(gone[:5]) + (" ..." if len(gone) > 5 else "") if gone else "",
                "added " + ", ".join(new[:5]) + (" ..." if len(new) > 5 else "") if new else "") if part) + ")"
        lines.append("gates: " + text + ("" if gone or new else " (unchanged)"))
        if gone or new:
            failures.append(f"gates: a srv-only change changed the co-op tests ({text}): the co-op stand and "
                            "both marks are needed")
        # the bodies and the support files of the co-op tests count too, not only their names (B10)
        edited = [p for p in changed_tests(root, test_base, test_end) if not p.rsplit("/", 1)[-1].startswith("test_srv_")]
        if edited:
            failures.append(f"gates: a srv-only change edited co-op tests or their runner ({', '.join(edited[:5])}"
                            f"{' ...' if len(edited) > 5 else ''}): the co-op stand and both marks are needed")
    return Result(units, required, lines, failures)


def changed_tests(repo: pathlib.Path, base: str, end: Optional[str]) -> list[str]:
    """Files of the co-op tests and their runners changed between base and end (end None: the working tree against
    base, untracked files too)."""
    if end is None:
        files = set(git(repo, "diff", "--name-only", "--no-renames", base, "--", *TEST_PATHS).splitlines())
        files |= set(git(repo, "ls-files", "--others", "--exclude-standard", "--", *TEST_PATHS).splitlines())
    else:
        files = set(git(repo, "diff", "--name-only", "--no-renames", base, end, "--", *TEST_PATHS).splitlines())
    return sorted(f for f in files if f)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("range", nargs="?", help="git range A..B of this repository (default: the working tree vs HEAD)")
    ap.add_argument("--engine-range", help="git range of engine/ (default: RANGE)")
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--marks", help="folder of the stand marks (default <root>/temp/gates)")
    ap.add_argument("--exe", default=str(DEFAULT_EXE), help="the exe the marks must name (default: the stand's)")
    args = ap.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    marks = pathlib.Path(args.marks) if args.marks else root / "temp" / "gates"
    try:
        result = evaluate(root, args.range, args.engine_range, marks, pathlib.Path(args.exe))
    except GateError as error:
        print(f"gates: {error}")
        return 2
    for line in result.lines:
        print(line)
    for line in result.failures:
        if line not in result.lines:
            print(line)
    if result.failures:
        print(f"gates: FAIL ({len(result.failures)})")
        return 1
    print("gates: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
