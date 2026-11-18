"""The stand runs HEAD (docs/MODES.md section 10; the second review of the layer guard, B12 and B13).

  python -I tools/stand/stand_head.py deploy --stand DIR [--backup DIR]
  python -I tools/stand/stand_head.py check --stand DIR

deploy  refuses while the working tree of either repository has a product change (gamedata, gamedata_gamma, the
        engine's src and gamedata; staged, unstaged or untracked) or a stand scenario differs from HEAD (tools/stand and
        the runners: check_gates.SCENARIO_PATHS). Then it deploys HEAD's gamedata to the stand, from `git archive HEAD`
        of both repositories (never the working files): the Engine layer (engine/gamedata) first, Core (gamedata) on
        top, GAMMA (gamedata_gamma) on top of that, as tools/stand_overlay.py layers them. On a launcher-made stand
        (.raylink-stand.json) an Engine file whose path a mod owns there is left alone: in MO2 the mod wins over the
        Engine layer. Files the game writes itself (axr_options.ltx) are never deployed. What it replaces goes to
        --backup first (default temp/stand/head_backup; the first backup of a file is kept: the stand's original).
        Every deployed file is read back and compared with HEAD's blob.
check   the stand still holds HEAD's gamedata (the runner calls it after the scenarios) and the tree is still clean.

Both print the values a stand mark names, one per line: mod_head=, engine_head=, scenarios_sha256= (the scenario
files on disk, as git blob ids), gamedata_sha256= (HEAD's deployed gamedata; tools/check_gates.py recomputes both from
HEAD and refuses a mark that differs), then deployed=, replaced=, added=, kept_by_mods=. Exit 0, or 1 with a line
"stand_head: refused: ..." / "stand_head: the stand's <file> is not HEAD's". Talks to no network, starts no game.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import pathlib
import subprocess
import sys
import tarfile
from typing import Optional

TOOLS = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))  # -I leaves the script's folders out
import check_gates  # noqa: E402

ROOT = TOOLS.parent
LAYER_ORDER = ("engine/gamedata/", "gamedata/", "gamedata_gamma/")  # the later layer wins
OURS = ("Anomaly Coop - Engine/", "Anomaly Coop - Core/", "Anomaly Coop - GAMMA/")


class Refused(Exception):
    pass


def git_bytes(repo: pathlib.Path, *args: str) -> bytes:
    done = subprocess.run(["git", "-C", str(repo), "-c", "core.quotePath=false", *args], capture_output=True)
    if done.returncode != 0:
        raise Refused(f"git {' '.join(args[:3])} in {repo.name}: {done.stderr.decode('utf-8', 'replace').strip()[:300]}")
    return done.stdout


def blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def same_blob(data: bytes, blob: str) -> bool:
    """The bytes are HEAD's blob, as committed or as checked out with CRLF (core.autocrlf)."""
    return blob in (blob_id(data), blob_id(data.replace(b"\r\n", b"\n")))


def dirty(root: pathlib.Path, engine: Optional[pathlib.Path]) -> list[str]:
    """Uncommitted product files and scenario files that differ from HEAD (tracked or not)."""
    lines = check_gates.git(root, "status", "--porcelain", "--untracked-files=all", "--", "gamedata", "gamedata_gamma",
                            *check_gates.SCENARIO_PATHS).splitlines()
    if engine is not None:
        lines += ["engine: " + l for l in check_gates.git(engine, "status", "--porcelain", "--untracked-files=all", "--",
                                                          "src", "gamedata").splitlines()]
    return [l for l in lines if l.strip()]


def scenarios_on_disk(root: pathlib.Path) -> str:
    """scenarios_sha256 of the scenario files on disk (their blob ids through git's own clean filter)."""
    paths = [p for p in check_gates.git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                                        *check_gates.SCENARIO_PATHS).split("\0") if p and (root / p).is_file()]
    if not paths:
        return check_gates.digest([])
    done = subprocess.run(["git", "-C", str(root), "hash-object", "--stdin-paths"], input="\n".join(paths) + "\n",
                          capture_output=True, text=True, encoding="utf-8")
    if done.returncode != 0:
        raise Refused(f"git hash-object: {done.stderr.strip()[:300]}")
    return check_gates.digest(list(zip(paths, done.stdout.split())))


def head_files(repo: pathlib.Path, folders: list[str], prefix: str) -> dict[str, bytes]:
    """project path -> bytes of HEAD's files under folders (git archive: the checked-out form)."""
    present = [f for f in folders if check_gates.tree_blobs(repo, "HEAD", [f])]
    if not present:
        return {}
    data = git_bytes(repo, "archive", "--format=tar", "HEAD", "--", *present)
    out = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for member in tar.getmembers():
            if member.isfile():
                handle = tar.extractfile(member)
                if handle is not None:
                    out[prefix + member.name] = handle.read()
    return out


def mod_owned(stand: pathlib.Path) -> Optional[set[str]]:
    """Lower-case stand paths a mod (not one of our layers) owns on a launcher-made stand; None without a manifest."""
    manifest = stand / ".raylink-stand.json"
    if not manifest.is_file():
        return None
    entries = json.loads(manifest.read_text(encoding="utf-8")).get("entries", [])
    owned = set()
    for entry in entries:
        source = (entry.get("source") or "").replace("\\", "/")
        if entry.get("rel") and not any(layer in source for layer in OURS):
            owned.add(entry["rel"].replace("\\", "/").lower())
    return owned


def stand_rel(path: str) -> str:
    for layer in LAYER_ORDER:
        if path.startswith(layer):
            return "gamedata/" + path[len(layer):]
    raise ValueError(path)


def plan(root: pathlib.Path, engine: Optional[pathlib.Path], stand: pathlib.Path) -> tuple[
        dict[str, str], dict[str, str], int, str, str]:
    """(stand path -> winning project path, project path -> blob, kept by mods, mod HEAD, engine HEAD)."""
    mod_head = check_gates.head(root)
    engine_head = check_gates.head(engine) if engine is not None else ""
    entries = dict(check_gates.gamedata_entries(root, engine, mod_head, engine_head or None))
    owned = mod_owned(stand)
    winner: dict[str, str] = {}
    kept = 0
    for layer in LAYER_ORDER:
        for path in sorted(p for p in entries if p.startswith(layer)):
            rel = stand_rel(path)
            if layer == "engine/gamedata/" and owned is not None and rel.lower() in owned:
                kept += 1  # a mod overrides this Engine file on the stand (MO2: the mod wins)
                continue
            winner[rel] = path
    return winner, entries, kept, mod_head, engine_head


def verify(stand: pathlib.Path, winner: dict[str, str], entries: dict[str, str]) -> list[str]:
    bad = []
    for rel, path in sorted(winner.items()):
        target = stand / rel
        if not target.is_file() or not same_blob(target.read_bytes(), entries[path]):
            bad.append(rel)
    return bad


def values(root: pathlib.Path, engine: Optional[pathlib.Path], mod_head: str, engine_head: str,
           entries: dict[str, str]) -> list[str]:
    return [f"mod_head={mod_head}", f"engine_head={engine_head}", f"scenarios_sha256={scenarios_on_disk(root)}",
            f"gamedata_sha256={check_gates.digest(list(entries.items()))}"]


def deploy(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path) -> list[str]:
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    left = dirty(root, engine)
    if left:
        raise Refused(f"{len(left)} uncommitted product or scenario file(s): the stand runs HEAD only, commit first: "
                      + "; ".join(l.strip() for l in left[:10]) + (" ..." if len(left) > 10 else ""))
    if not (stand / "gamedata").is_dir() or not (stand / "bin").is_dir():
        raise Refused(f"not a game root: {stand}")
    winner, entries, kept, mod_head, engine_head = plan(root, engine, stand)
    files = head_files(root, ["gamedata", "gamedata_gamma"], "")
    if engine is not None:
        files.update(head_files(engine, ["gamedata"], "engine/"))
    replaced, added = [], []
    for rel, path in sorted(winner.items()):
        data = files[path]
        target = stand / rel
        if target.is_file() and target.read_bytes() == data:
            continue
        if target.is_file():
            keep = backup / rel
            if not keep.exists():
                keep.parent.mkdir(parents=True, exist_ok=True)
                keep.write_bytes(target.read_bytes())
            replaced.append(rel)
        else:
            added.append(rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    if added:
        backup.mkdir(parents=True, exist_ok=True)
        listed = backup / "new_files.txt"
        known = set(listed.read_text(encoding="utf-8").splitlines()) if listed.exists() else set()
        listed.write_text("\n".join(sorted(known | set(added))) + "\n", encoding="utf-8")
    bad = verify(stand, winner, entries)
    if bad:
        raise Refused(f"the stand's {bad[0]} is not HEAD's after the deploy ({len(bad)} file(s))")
    return values(root, engine, mod_head, engine_head, entries) + [
        f"deployed={len(winner)}", f"replaced={len(replaced)}", f"added={len(added)}", f"kept_by_mods={kept}"]


def check(root: pathlib.Path, stand: pathlib.Path) -> list[str]:
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    left = dirty(root, engine)
    if left:
        raise Refused(f"{len(left)} uncommitted product or scenario file(s) appeared during the run: "
                      + "; ".join(l.strip() for l in left[:10]))
    winner, entries, kept, mod_head, engine_head = plan(root, engine, stand)
    bad = verify(stand, winner, entries)
    if bad:
        print(f"stand_head: the stand's {bad[0]} is not HEAD's ({len(bad)} file(s)): "
              + ", ".join(bad[:10]))
        raise SystemExit(1)
    return values(root, engine, mod_head, engine_head, entries) + [f"deployed={len(winner)}", f"kept_by_mods={kept}"]


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("command", choices=["deploy", "check"])
    ap.add_argument("--stand", required=True, help="the stand's game root (E:\\RayLinkGames\\GAMMA\\game-dev)")
    ap.add_argument("--backup", help="where replaced files go (default temp/stand/head_backup)")
    ap.add_argument("--root", default=str(ROOT), help="repository root (default: this repository)")
    args = ap.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    stand = pathlib.Path(args.stand)
    backup = pathlib.Path(args.backup) if args.backup else root / "temp" / "stand" / "head_backup"
    try:
        lines = deploy(root, stand, backup) if args.command == "deploy" else check(root, stand)
    except (Refused, check_gates.GateError) as error:
        print(f"stand_head: refused: {error}")
        return 1
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
