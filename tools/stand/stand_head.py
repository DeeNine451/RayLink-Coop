"""The stand runs HEAD (docs/MODES.md section 10; the second and third reviews of the layer guard, B12, B13, S1-S3, C12).

  python -I tools/stand/stand_head.py deploy  --stand DIR [--backup DIR] [--ci DIR]
  python -I tools/stand/stand_head.py check   --stand DIR [--ci DIR]
  python -I tools/stand/stand_head.py profile --stand DIR [--backup DIR]

deploy  refuses while the working tree of either repository has a product change (gamedata, gamedata_gamma, the
        engine's src and gamedata; staged, unstaged or untracked) or a stand scenario differs from HEAD (tools/stand, the
        runners and the two checkers: check_gates.SCENARIO_PATHS). Then it deploys HEAD's gamedata to the stand, from
        `git archive HEAD` of both repositories (never the working files): the Engine layer (engine/gamedata) first, Core
        (gamedata) on top, GAMMA (gamedata_gamma) on top of that, as tools/stand_overlay.py layers them. On a
        launcher-made stand (.raylink-stand.json) an Engine file whose path a mod owns there is left alone: in MO2 the mod
        wins over the Engine layer. Files the game writes itself (axr_options.ltx) are never deployed. What it replaces
        goes to --backup first (default temp/stand/head_backup; the first backup of a file is kept: the stand's
        original). Every deployed file is read back and compared with HEAD's blob.
        Leftovers (S1): a file of our layers that HEAD does not have any more stays on the stand otherwise, and
        axr_main runs every script it finds. deploy moves to <backup>/removed every stand file under gamedata that is no
        file of HEAD and that the manifest gives to one of our layers, that the manifest does not list and that is a
        coop_*.script, or that an earlier deploy added (<backup>/new_files.txt); a probe of tools/stand
        (coop_zz_*.script) stays when it is HEAD's. A coop_*.script that a GAMMA mod ships (the manifest names the mod)
        is no leftover of ours: it stays, is named (stand_foreign=) and its bytes are part of stand_fingerprint.
        Then it writes the mode cvars of HEAD into the stand's profiles (profile, below).
check   the stand still holds HEAD's gamedata and no leftover (the runner calls it after the scenarios), and the tree is
        still clean. It never removes anything: it names what it finds and fails.
profile (S2) the mode of a stand process comes from its profile too (user.ltx: coop_split_levels, coop_world_server ...,
        which every earlier run wrote back). For every profile folder tools/stand/stand_profile.ltx names, it removes
        every mode cvar line from <stand>/<folder>/user.ltx and writes the template's lines instead (the first original
        is kept under <backup>/profiles). The runner calls it before every scenario.

deploy and check print the values a stand mark names, one per line: mod_head=, engine_head=, scenarios_sha256= (the
scenario files on disk, as git blob ids), gamedata_sha256= (HEAD's deployed gamedata; tools/check_gates.py recomputes
both from HEAD and refuses a mark that differs), exe_sha256= (the stand's exe), exe_source= (the engine HEAD that exe is
engine-ci's build of, check_gates.exe_source; none when it is not), stand_fingerprint=, stand_extra= (leftovers),
stand_foreign=, profile_sha256=; then deployed=, replaced=, added=, removed=, kept_by_mods=. Exit 0, or 1 with a line
"stand_head: refused: ..." / "stand_head: the stand's <file> is not HEAD's" / "stand_head: the stand holds ...".
Talks to no network, starts no game.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import pathlib
import re
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
PROBE = re.compile(r"^gamedata/scripts/coop_zz_[^/]*\.script$", re.I)
# the console variables that decide a process's mode (docs/MODES.md section 1); the template may set only these
MODE_CVAR = re.compile(rb"^[ \t]*(?:coop_split_levels|coop_world_server|coop_story_together|coop_soft_host_move"
                       rb"|coop_max_map_servers|coop_map_servers_rev|coop_mapserver_\w+)\b")


class Refused(Exception):
    pass


def git_bytes(repo: pathlib.Path, *args: str) -> bytes:
    done = subprocess.run(["git", "-C", str(repo), "-c", "core.quotePath=false", *args], capture_output=True,
                          env=check_gates.GIT_ENV)
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
    lines = check_gates.dirty_lines(root, ["gamedata", "gamedata_gamma", *check_gates.SCENARIO_PATHS])
    if engine is not None:
        lines += ["engine: " + l for l in check_gates.dirty_lines(engine, ["src", "gamedata"])]
    return lines


def on_disk_digest(root: pathlib.Path, paths: list[str]) -> str:
    """digest() of the files under paths on disk (tracked or not), as git blob ids through git's own clean filter."""
    files = [p for p in check_gates.git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                                        *paths).split("\0") if p and (root / p).is_file()]
    if not files:
        return check_gates.digest([])
    done = subprocess.run(["git", "-C", str(root), "hash-object", "--stdin-paths"], input="\n".join(files) + "\n",
                          capture_output=True, text=True, encoding="utf-8", env=check_gates.GIT_ENV)
    if done.returncode != 0:
        raise Refused(f"git hash-object: {done.stderr.strip()[:300]}")
    return check_gates.digest(list(zip(files, done.stdout.split())))


def scenarios_on_disk(root: pathlib.Path) -> str:
    """scenarios_sha256 of the scenario files on disk."""
    return on_disk_digest(root, list(check_gates.SCENARIO_PATHS))


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


def manifest_sources(stand: pathlib.Path) -> Optional[dict[str, str]]:
    """Lower-case stand path -> the source the launcher copied it from (forward slashes); None without a manifest."""
    manifest = stand / ".raylink-stand.json"
    if not manifest.is_file():
        return None
    out = {}
    for entry in json.loads(manifest.read_text(encoding="utf-8")).get("entries", []):
        if entry.get("rel"):
            out[entry["rel"].replace("\\", "/").lower()] = (entry.get("source") or "").replace("\\", "/")
    return out


def is_ours(source: str) -> bool:
    return any(layer in source for layer in OURS)


def stand_rel(path: str) -> str:
    for layer in LAYER_ORDER:
        if path.startswith(layer):
            return "gamedata/" + path[len(layer):]
    raise ValueError(path)


def plan(root: pathlib.Path, engine: Optional[pathlib.Path], stand: pathlib.Path) -> tuple[
        dict[str, str], dict[str, str], int, str, str, Optional[dict[str, str]]]:
    """(stand path -> winning project path, project path -> blob, kept by mods, mod HEAD, engine HEAD, manifest)."""
    mod_head = check_gates.head(root)
    engine_head = check_gates.head(engine) if engine is not None else ""
    entries = dict(check_gates.gamedata_entries(root, engine, mod_head, engine_head or None))
    sources = manifest_sources(stand)
    winner: dict[str, str] = {}
    kept = 0
    for layer in LAYER_ORDER:
        for path in sorted(p for p in entries if p.startswith(layer)):
            rel = stand_rel(path)
            if layer == "engine/gamedata/" and sources is not None and rel.lower() in sources \
                    and not is_ours(sources[rel.lower()]):
                kept += 1  # a mod overrides this Engine file on the stand (MO2: the mod wins)
                continue
            winner[rel] = path
    return winner, entries, kept, mod_head, engine_head, sources


def leftovers(root: pathlib.Path, stand: pathlib.Path, winner: dict[str, str], sources: Optional[dict[str, str]],
              backup: Optional[pathlib.Path]) -> tuple[list[str], list[str]]:
    """(ours: stand files HEAD does not have that our layers or an earlier deploy put there, foreign: coop_*.script a
    GAMMA mod ships). Stand paths, lower case."""
    winners = {rel.lower() for rel in winner}
    probes = {blob for _, blob in check_gates.tree_blobs(root, "HEAD", ["tools/stand"])}
    candidates: set[str] = set()
    if sources:
        candidates |= {rel for rel, source in sources.items() if is_ours(source)}
    scripts = stand / "gamedata" / "scripts"
    if scripts.is_dir():
        candidates |= {f"gamedata/scripts/{p.name.lower()}" for p in scripts.glob("coop_*.script")}
    listed = backup / "new_files.txt" if backup is not None else None
    if listed is not None and listed.is_file():
        candidates |= {l.strip().lower() for l in listed.read_text(encoding="utf-8").splitlines() if l.strip()}
    ours, foreign = [], []
    for rel in sorted(candidates):
        if not rel.startswith("gamedata/") or rel in winners or not check_gates.deployable(rel):
            continue
        path = stand / rel
        if not path.is_file():
            continue
        if PROBE.match(rel) and any(same_blob(path.read_bytes(), b) for b in probes):
            continue  # a probe of tools/stand at HEAD: the scenarios copy and remove it
        source = sources.get(rel) if sources else None
        if source and not is_ours(source):
            foreign.append(rel)
        else:
            ours.append(rel)
    return ours, foreign


def verify(stand: pathlib.Path, winner: dict[str, str], entries: dict[str, str]) -> list[str]:
    bad = []
    for rel, path in sorted(winner.items()):
        target = stand / rel
        if not target.is_file() or not same_blob(target.read_bytes(), entries[path]):
            bad.append(rel)
    return bad


def values(root: pathlib.Path, engine: Optional[pathlib.Path], stand: pathlib.Path, ci: pathlib.Path, mod_head: str,
           engine_head: str, entries: dict[str, str], extra: list[str], foreign: list[str]) -> list[str]:
    exe = check_gates.stand_exe(stand)
    source, why = check_gates.exe_source(engine, exe, ci)
    lines = [f"mod_head={mod_head}", f"engine_head={engine_head}", f"scenarios_sha256={scenarios_on_disk(root)}",
             f"gamedata_sha256={check_gates.digest(list(entries.items()))}",
             f"exe_sha256={check_gates.sha256_of(exe) or 'none'}", f"exe_source={source or 'none'}",
             f"stand_fingerprint={check_gates.stand_fingerprint(stand)}", f"stand_extra={len(extra)}",
             f"stand_foreign={','.join(foreign)}", f"profile_sha256={on_disk_digest(root, [check_gates.PROFILE])}"]
    lines += [f"stand_head: exe_source: {w}" for w in why]
    lines += [f"stand_head: kept {rel}: a GAMMA mod ships it, not our HEAD (it runs in every process; "
              "stand_fingerprint binds its bytes)" for rel in foreign]
    return lines


def keep_copy(backup: pathlib.Path, rel: str, data: bytes) -> None:
    keep = backup / rel
    if not keep.exists():
        keep.parent.mkdir(parents=True, exist_ok=True)
        keep.write_bytes(data)


def profile(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path) -> list[str]:
    """Write the mode cvars of tools/stand/stand_profile.ltx into the stand's profiles (S2)."""
    template = root / check_gates.PROFILE
    sections: dict[str, list[bytes]] = {}
    if template.is_file():
        current: Optional[str] = None
        for number, raw in enumerate(template.read_bytes().splitlines(), 1):
            line = raw.split(b";", 1)[0].strip()
            if not line:
                continue
            m = re.fullmatch(rb"\[([A-Za-z0-9_.\-]+)\]", line)
            if m:
                current = m.group(1).decode("ascii")
                sections.setdefault(current, [])
            elif current is None or not MODE_CVAR.match(line):
                raise Refused(f"{check_gates.PROFILE}:{number}: only [profile folder] rows and mode cvars belong there")
            else:
                sections[current].append(line)
    written = 0
    for folder, cvars in sorted(sections.items()):
        user = stand / folder / "user.ltx"
        if not user.is_file():
            continue
        data = user.read_bytes()
        newline = b"\r\n" if b"\r\n" in data else b"\n"
        kept = [l for l in data.splitlines() if not MODE_CVAR.match(l)]
        new = newline.join(kept + cvars) + newline
        if new != data:
            keep_copy(backup / "profiles", f"{folder}/user.ltx", data)
            user.write_bytes(new)
        written += 1
    return [f"profile_sha256={on_disk_digest(root, [check_gates.PROFILE])}", f"profiles={written}"]


def deploy(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path, ci: pathlib.Path) -> list[str]:
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    left = dirty(root, engine)
    if left:
        raise Refused(f"{len(left)} uncommitted product or scenario file(s): the stand runs HEAD only, commit first: "
                      + "; ".join(l.strip() for l in left[:10]) + (" ..." if len(left) > 10 else ""))
    if not (stand / "gamedata").is_dir() or not (stand / "bin").is_dir():
        raise Refused(f"not a game root: {stand}")
    winner, entries, kept, mod_head, engine_head, sources = plan(root, engine, stand)
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
            keep_copy(backup, rel, target.read_bytes())
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
    # S1: leftovers of our layers leave the stand (into the backup), before any scenario runs
    ours, foreign = leftovers(root, stand, winner, sources, backup)
    for rel in ours:
        source = stand / rel
        keep_copy(backup / "removed", rel, source.read_bytes())
        source.unlink()
    if ours:
        listed = backup / "removed_files.txt"
        known = set(listed.read_text(encoding="utf-8").splitlines()) if listed.exists() else set()
        listed.write_text("\n".join(sorted(known | set(ours))) + "\n", encoding="utf-8")
    bad = verify(stand, winner, entries)
    if bad:
        raise Refused(f"the stand's {bad[0]} is not HEAD's after the deploy ({len(bad)} file(s))")
    left_over, foreign = leftovers(root, stand, winner, sources, backup)
    if left_over:
        raise Refused(f"the stand still holds {len(left_over)} file(s) HEAD does not have: " + ", ".join(left_over[:10]))
    prof = profile(root, stand, backup)
    return values(root, engine, stand, ci, mod_head, engine_head, entries, left_over, foreign) + [
        f"deployed={len(winner)}", f"replaced={len(replaced)}", f"added={len(added)}", f"removed={len(ours)}",
        f"kept_by_mods={kept}"] + [l for l in prof if l.startswith("profiles=")] + \
        [f"stand_head: moved {rel} to the backup: HEAD does not have it" for rel in ours]


def check(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path, ci: pathlib.Path) -> list[str]:
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    left = dirty(root, engine)
    if left:
        raise Refused(f"{len(left)} uncommitted product or scenario file(s) appeared during the run: "
                      + "; ".join(l.strip() for l in left[:10]))
    winner, entries, kept, mod_head, engine_head, sources = plan(root, engine, stand)
    bad = verify(stand, winner, entries)
    if bad:
        print(f"stand_head: the stand's {bad[0]} is not HEAD's ({len(bad)} file(s)): "
              + ", ".join(bad[:10]))
        raise SystemExit(1)
    ours, foreign = leftovers(root, stand, winner, sources, backup)
    if ours:
        print(f"stand_head: the stand holds {len(ours)} file(s) HEAD does not have (deploy moves them to the backup): "
              + ", ".join(ours[:10]) + (" ..." if len(ours) > 10 else ""))
        for rel in foreign:
            print(f"stand_head: kept {rel}: a GAMMA mod ships it, not our HEAD")
        raise SystemExit(1)
    return values(root, engine, stand, ci, mod_head, engine_head, entries, ours, foreign) + [
        f"deployed={len(winner)}", f"kept_by_mods={kept}"]


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("command", choices=["deploy", "check", "profile"])
    ap.add_argument("--stand", required=True, help="the stand's game root (E:\\RayLinkGames\\GAMMA\\game-dev)")
    ap.add_argument("--backup", help="where replaced and removed files go (default temp/stand/head_backup)")
    ap.add_argument("--root", default=str(ROOT), help="repository root (default: this repository)")
    ap.add_argument("--ci", help="the engine-ci worktree the stand's exe comes from (default <root>/engine-ci)")
    args = ap.parse_args(argv)
    root = pathlib.Path(args.root).resolve()
    stand = pathlib.Path(args.stand)
    backup = pathlib.Path(args.backup) if args.backup else root / "temp" / "stand" / "head_backup"
    ci = pathlib.Path(args.ci) if args.ci else root / "engine-ci"
    try:
        if args.command == "deploy":
            lines = deploy(root, stand, backup, ci)
        elif args.command == "check":
            lines = check(root, stand, backup, ci)
        else:
            lines = profile(root, stand, backup)
    except (Refused, check_gates.GateError) as error:
        print(f"stand_head: refused: {error}")
        return 1
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
