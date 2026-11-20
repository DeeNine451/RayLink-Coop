"""The stand runs HEAD (docs/MODES.md section 10; the second and third reviews of the layer guard, B12, B13, S1-S3, C12).

  python -I tools/stand/stand_head.py deploy  --stand DIR [--backup DIR] [--ci DIR]
  python -I tools/stand/stand_head.py check   --stand DIR [--ci DIR]
  python -I tools/stand/stand_head.py profile --stand DIR [--backup DIR]
  python -I tools/stand/stand_head.py links   --stand DIR [--backup DIR]

Hard links (TZ.md R21, round 5 of the layer guard): the launcher builds the stand from hard links to the mods' own
files (E:\\RayLinkGames\\GAMMA\\mo2\\mods: about 60,700 of 61,800 stand files). No command here ever writes into an existing
stand file: deploy, profile and the leftover and restore steps delete the old name first (read-only-safe, the mod's
read-only attribute stays) and a new file takes the name (tools/mo2_stand.py replace_file / remove_file). Before its
first write deploy checks that every name it will delete can be deleted now (a running game holds its files): if one
cannot, it refuses and writes nothing. It prints replaced_links= (how many files it replaced were hard links).
links   the same plan without writing anything: would_replace=, would_replace_links=, would_add=, would_restore=,
        would_remove=, head_files_linked= (HEAD's files on the stand that are hard links now), blocked=; exit 1 when a
        name cannot be deleted now.

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
        A HEAD file already on the stand that the manifest does not list (tools/stand_overlay.py put it) goes into
        new_files.txt too (review 4, B2), so the deploy after HEAD drops it finds it.
        Mod overrides (review 4, B3): a file a deploy replaced over a mod's own file (or over a file the stand had
        before our first deploy) is listed in replaced_files; when HEAD no longer has it, deploy puts the mod's file
        back (its bytes from the file the manifest names, else from the first backup), and check fails while the stand
        still holds our dropped override.
        Review 5 (B3, B4): the record of what our tools put on the stand (new_files, replaced_files) lives in the stand
        itself, <stand>/.raylink-head-deploy.json (tools/mo2_stand.py remember_on_stand; tools/stand_overlay.py writes it
        too), written before the first write; <backup>/new_files.txt and replaced_files.txt stay as this worktree's
        history and count too. Without any record, on a launcher-made stand: every file under gamedata that the
        manifest does not list and HEAD does not have is a leftover (except the game's own localization.ltx and names
        the game never reads, *.bak *.tmp *.log *.orig); a linked mod file (copy=false) whose folder entry no longer
        has the manifest's size and time, whose name is no hard link any more and whose bytes are not the mod's comes
        back from the mod; a copied mod file (copy=true) comes back when its bytes are a blob of our repositories (the
        game rewrites some copied files: those bytes are no blob of ours and stay).
        A junction or symlink folder under gamedata (or a profile folder that is one): deploy refuses before it
        writes, check fails, links counts it as blocked (a write through it would land in a mod's folder).
        Then it writes the mode cvars of HEAD into the stand's profiles (profile, below).
check   the stand still holds HEAD's gamedata and no leftover (the runner calls it after the scenarios), and the tree is
        still clean. It never removes anything: it names what it finds and fails.
profile (S2) the mode of a stand process comes from its profile too (user.ltx: coop_max_map_servers ..., which every
        earlier run wrote back). For every profile folder tools/stand/stand_profile.ltx names, it removes every mode
        cvar line from <stand>/<folder>/user.ltx (the four step S2 took out of the engine too: coop_split_levels,
        coop_world_server, coop_story_together, coop_soft_host_move) and writes the template's lines instead (the first
        original is kept under <backup>/profiles); a template row of a removed cvar is refused. The runner calls it
        before every scenario.

deploy and check print the values a stand mark names, one per line: mod_head=, engine_head=, scenarios_sha256= (the
scenario files on disk, as git blob ids), gamedata_sha256= (HEAD's deployed gamedata; tools/check_gates.py recomputes
both from HEAD and refuses a mark that differs), exe_sha256= (the stand's exe), exe_source= (the engine HEAD that exe is
engine-ci's build of, check_gates.exe_source; none when it is not), stand_fingerprint=, stand_extra= (leftovers),
stand_foreign=, profile_sha256=; then deployed=, replaced=, replaced_links=, added=, listed=, removed=, restored=,
kept_by_mods=. Exit 0, or 1 with a line
"stand_head: refused: ..." / "stand_head: the stand's <file> is not HEAD's" / "stand_head: the stand holds ...".
Talks to no network, starts no game.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import tarfile
from dataclasses import dataclass
from typing import Optional

TOOLS = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))  # -I leaves the script's folders out
import check_gates  # noqa: E402
import mo2_stand  # noqa: E402  (replace_file / remove_file: the stand's files are hard links to the mods', TZ R21)

ROOT = TOOLS.parent
LAYER_ORDER = ("engine/gamedata/", "gamedata/", "gamedata_gamma/")  # the later layer wins
OURS = ("Anomaly Coop - Engine/", "Anomaly Coop - Core/", "Anomaly Coop - GAMMA/")
PROBE = re.compile(r"^gamedata/scripts/coop_zz_[^/]*\.script$", re.I)
# the console variables that decide a process's mode (docs/MODES.md section 1): profile removes each of these lines from
# a stand profile, then writes the template's. Step S2 (docs/plans/2026-11-18-two-modes.md) removed four of them from the
# engine (REMOVED_CVAR): a profile line of theirs still goes, and the template may not write one. The engine saves the
# map-server settings under their srv_* names only (review A-REV-E-1 finding 7, srv/coop_srv_console.cpp): those lines go
# too, so the template's coop_* lines are the profile's only mode lines.
MODE_CVAR = re.compile(rb"^[ \t]*(?:coop_split_levels|coop_world_server|coop_story_together|coop_soft_host_move"
                       rb"|coop_max_map_servers|coop_map_servers_rev|coop_mapserver_\w+"
                       rb"|srv_max_map_servers|srv_map_servers_rev|srv_mapserver_\w+)\b")
REMOVED_CVAR = re.compile(rb"^[ \t]*(?:coop_split_levels|coop_world_server|coop_story_together|coop_soft_host_move)\b")


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


@dataclass(frozen=True)
class Entry:
    """One file of the launcher's manifest: where it came from, linked (copy=False) or copied, its size and time then."""
    source: str
    copy: Optional[bool]
    size: Optional[int]
    modified: Optional[int]


_MANIFESTS: dict[tuple[str, int, int], dict[str, Entry]] = {}


def manifest_entries(stand: pathlib.Path) -> Optional[dict[str, Entry]]:
    """Lower-case stand path -> its manifest entry (source with forward slashes); None without a manifest. The real one
    is 18 MB: read once per process."""
    manifest = stand / ".raylink-stand.json"
    if not manifest.is_file():
        return None
    st = manifest.stat()
    key = (str(manifest.resolve()), st.st_size, st.st_mtime_ns)
    if key not in _MANIFESTS:
        out: dict[str, Entry] = {}
        for entry in json.loads(manifest.read_text(encoding="utf-8")).get("entries", []):
            if entry.get("rel"):
                copy, size, modified = entry.get("copy"), entry.get("size"), entry.get("modified")
                out[entry["rel"].replace("\\", "/").lower()] = Entry(
                    (entry.get("source") or "").replace("\\", "/"), copy if isinstance(copy, bool) else None,
                    size if isinstance(size, int) and not isinstance(size, bool) else None,
                    modified if isinstance(modified, int) and not isinstance(modified, bool) else None)
        _MANIFESTS.clear()
        _MANIFESTS[key] = out
    return _MANIFESTS[key]


def manifest_sources(stand: pathlib.Path) -> Optional[dict[str, str]]:
    """Lower-case stand path -> the source the launcher copied it from (forward slashes); None without a manifest."""
    entries = manifest_entries(stand)
    return None if entries is None else {rel: e.source for rel, e in entries.items()}


StandFiles = dict[str, tuple[str, int, int]]  # lower-case stand path -> (path as on disk, size, mtime_ns)


def stand_files(stand: pathlib.Path) -> tuple[StandFiles, list[str]]:
    """(every file under the stand's gamedata, from the folder entries: no file is opened; the junctions and symlinks
    found there). A junction or symlink is never walked into: a write through it would land in another folder (a mod's;
    review 5, S14), so deploy and check refuse while there is one. The launcher makes none."""
    files: StandFiles = {}
    links: list[str] = []
    base = stand / "gamedata"
    if os.path.islink(base) or os.path.isjunction(base):
        return files, ["gamedata"]
    if not base.is_dir():
        return files, links
    todo = [(str(base), "gamedata")]
    while todo:
        folder, rel_dir = todo.pop()
        with os.scandir(folder) as it:
            for item in it:
                rel = f"{rel_dir}/{item.name}"
                if item.is_symlink() or item.is_junction():
                    links.append(rel)
                elif item.is_dir(follow_symlinks=False):
                    todo.append((item.path, rel))
                elif item.is_file(follow_symlinks=False):
                    st = item.stat(follow_symlinks=False)
                    files[rel.lower()] = (rel, st.st_size, st.st_mtime_ns)
    return files, sorted(links)


def link_refusal(links: list[str]) -> str:
    return (f"{len(links)} junction or symlink folder(s) in the stand: " + ", ".join(links[:10]) +
            ": a write through one lands in another folder (a mod's); the launcher builds real folders, remove them")


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


NEW_LIST = "new_files.txt"            # stand paths our deploys put there (no original): removed when HEAD drops them
REPLACED_LIST = "replaced_files.txt"  # stand paths whose own file (a mod's) a deploy replaced: restored when dropped
REMOVED_LIST = "removed_files.txt"


def read_list(backup: Optional[pathlib.Path], name: str) -> list[str]:
    """The stand paths of one list in the backup folder (as written, forward slashes; only paths under gamedata/)."""
    path = backup / name if backup is not None else None
    if path is None or not path.is_file():
        return []
    rels = (mo2_stand.memory_rel(l) for l in path.read_text(encoding="utf-8").splitlines() if l.strip())
    return [r for r in rels if r]


def add_to_list(backup: pathlib.Path, name: str, items: list[str]) -> None:
    """Adds stand paths to a list of the backup folder (the backup is ours: never a stand file)."""
    known = read_list(backup, name)
    have = {k.lower() for k in known}
    new = sorted({i for i in items if i.lower() not in have})
    if not new:
        return
    backup.mkdir(parents=True, exist_ok=True)
    (backup / name).write_text("\n".join(sorted(known + new)) + "\n", encoding="utf-8")


def stand_memory(stand: pathlib.Path) -> dict[str, list[str]]:
    try:
        return mo2_stand.read_stand_memory(stand)
    except (OSError, ValueError) as error:
        raise Refused(f"the stand's {mo2_stand.STAND_MEMORY} cannot be read ({error}): move it away; deploy then "
                      "works from the manifest and HEAD alone") from None


def remembered(stand: pathlib.Path, backup: Optional[pathlib.Path], name: str) -> list[str]:
    """One list of what our tools put on the stand: the stand's own record (review 5, B4: it travels with the stand)
    and the backup folder's (the run history of this worktree), together."""
    out, seen = [], set()
    for rel in stand_memory(stand)[name[:-len(".txt")]] + read_list(backup, name):
        if rel.lower() not in seen:
            seen.add(rel.lower())
            out.append(rel)
    return out


def remember(stand: pathlib.Path, backup: pathlib.Path, name: str, items: list[str]) -> None:
    """Into the stand's record (a new file each time, never written into) and the backup's list."""
    if items:
        try:
            mo2_stand.remember_on_stand(stand, **{name[:-len(".txt")]: items})
        except (OSError, ValueError) as error:
            raise Refused(f"cannot write the stand's {mo2_stand.STAND_MEMORY}: {error}") from None
        add_to_list(backup, name, items)


# The game writes this one into gamedata\configs itself (the language): no mod and no HEAD has it (review 5, B3).
RUNTIME_UNLISTED = frozenset({"gamedata/configs/localization.ltx"})


def never_read(rel: str) -> bool:
    """A name the game never loads: a backup or log a tool left (*.bak, *.tmp, *.log, *.orig) or a file the game itself
    writes (axr_options.ltx, cache_dbg.ltx)."""
    name = rel.rsplit("/", 1)[-1].lower()
    return name in check_gates.DEPLOY_SKIP_NAMES or pathlib.PurePosixPath(name).suffix in check_gates.DEPLOY_SKIP_EXT


def known_blobs(root: pathlib.Path, ids: set[str]) -> set[str]:
    """The ids among ids that are objects of our repositories (the project's or the engine's, any commit)."""
    found: set[str] = set()
    if not ids:
        return found
    for repo in (root, root / "engine"):
        if not (repo / ".git").exists():
            continue
        done = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch-check"], input="\n".join(sorted(ids)) + "\n",
                              capture_output=True, text=True, encoding="utf-8", env=check_gates.GIT_ENV)
        if done.returncode != 0:
            raise Refused(f"git cat-file in {repo.name}: {done.stderr.strip()[:300]}")
        found |= {line.split()[0] for line in done.stdout.splitlines() if line.endswith(" blob") or " blob " in line}
    return found


def dropped_overrides(root: pathlib.Path, stand: pathlib.Path, winner: dict[str, str],
                      entries: Optional[dict[str, Entry]], backup: Optional[pathlib.Path],
                      files: Optional[StandFiles] = None) -> list[tuple[str, Optional[bytes], str]]:
    """(stand path, the bytes it must hold, where they come from) of every stand file we replaced over a file of its own
    (a mod's: the launcher's hard link or copy, or a file the stand had before our first deploy) that HEAD does not
    have any more (review 4, B3): the stand shows the mod's file again, as at the players'.
    From the record (replaced_files: the stand's and the backup's): the bytes come from the mod's file the manifest
    names, else from the first backup of the stand's original; None when neither is there.
    Without any record (review 5, B4), from the manifest and the stand's folder entries: a file the launcher linked
    (copy=false) whose size or time is no longer the manifest's, whose name is no hard link any more and whose bytes are
    not the mod's (a deploy replaced the link); a file the launcher copied (copy=true) whose bytes are not the mod's and
    are a blob of our repositories (the game rewrites some copied files itself: those bytes are no blob of ours)."""
    winners = {rel.lower() for rel in winner}
    out: list[tuple[str, Optional[bytes], str]] = []
    seen: set[str] = set()
    for rel in remembered(stand, backup, REPLACED_LIST):
        if rel.lower() in winners:
            continue
        seen.add(rel.lower())
        entry = entries.get(rel.lower()) if entries else None
        source = entry.source if entry else None
        if source and not is_ours(source) and pathlib.Path(source).is_file():
            out.append((rel, pathlib.Path(source).read_bytes(), "the mod's file"))
        elif backup is not None and (backup / rel).is_file():
            out.append((rel, (backup / rel).read_bytes(), "the stand's original in the backup"))
        else:
            out.append((rel, None, "no original left"))
    if not entries or files is None:
        return out
    copies: list[tuple[str, bytes, bytes]] = []
    for low, (rel, size, mtime) in sorted(files.items()):
        entry = entries.get(low)
        if entry is None or entry.copy is None or low in winners or low in seen or not entry.source \
                or is_ours(entry.source) or not check_gates.deployable(low):
            continue
        if entry.copy is False and (entry.size, entry.modified) == (size, mtime):
            continue  # the launcher's link as it made it (the folder entry of the name it made)
        source = pathlib.Path(entry.source)
        if not source.is_file():
            continue  # the mod is gone: the launcher's business, not a file of ours
        if entry.copy is False and mo2_stand.link_count(stand / rel) > 1:
            continue  # still the link (the mod's file changed since): the mod's own bytes
        data, wanted = (stand / rel).read_bytes(), source.read_bytes()
        if data == wanted:
            continue
        if entry.copy is False:
            out.append((rel, wanted, "the mod's file: the stand's hard link to it had been replaced"))
        else:
            copies.append((rel, data, wanted))
    if copies:
        ours = known_blobs(root, {i for _, data, _ in copies for i in (blob_id(data), blob_id(data.replace(b"\r\n", b"\n")))})
        for rel, data, wanted in copies:
            if blob_id(data) in ours or blob_id(data.replace(b"\r\n", b"\n")) in ours:
                out.append((rel, wanted, "the mod's file: the stand held a file of our repositories over it"))
    return out


def leftovers(root: pathlib.Path, stand: pathlib.Path, winner: dict[str, str], sources: Optional[dict[str, str]],
              backup: Optional[pathlib.Path], files: Optional[StandFiles] = None) -> tuple[list[str], list[str]]:
    """(ours: stand files HEAD does not have that our layers or our tools put there, foreign: coop_*.script a GAMMA mod
    ships). Stand paths, lower case. A file a deploy replaced over a mod's (replaced_files) is no leftover: deploy
    restores it (dropped_overrides). On a launcher-made stand (review 5, B3) every file under gamedata that the manifest
    does not list and HEAD does not have is a leftover too, whoever put it there (tools/stand_overlay.py copies the
    working tree, untracked files included), except the game's own (RUNTIME_UNLISTED) and names the game never reads."""
    winners = {rel.lower() for rel in winner}
    restored = {rel.lower() for rel in remembered(stand, backup, REPLACED_LIST)}
    probes = {blob for _, blob in check_gates.tree_blobs(root, "HEAD", ["tools/stand"])}
    candidates: set[str] = set()
    if sources:
        candidates |= {rel for rel, source in sources.items() if is_ours(source)}
    scripts = stand / "gamedata" / "scripts"
    if scripts.is_dir():
        candidates |= {f"gamedata/scripts/{p.name.lower()}" for p in scripts.glob("coop_*.script")}
    candidates |= {rel.lower() for rel in remembered(stand, backup, NEW_LIST)}
    unlisted: set[str] = set()
    if sources is not None and files is not None:
        unlisted = {rel for rel in files if rel not in sources and rel not in RUNTIME_UNLISTED and not never_read(rel)}
        candidates |= unlisted
    ours, foreign = [], []
    for rel in sorted(candidates):
        if not rel.startswith("gamedata/") or rel in winners or rel in restored:
            continue
        if rel not in unlisted and not check_gates.deployable(rel):
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
    """The first original of a stand file, into the backup (never a stand file)."""
    keep = backup / rel
    if not keep.exists():
        keep.parent.mkdir(parents=True, exist_ok=True)
        keep.write_bytes(data)


def put(stand: pathlib.Path, rel: str, data: bytes) -> int:
    """data at stand/rel as a new file (mo2_stand.replace_file: the old name is deleted first, never written into: it
    may be the launcher's hard link to a mod's own file, TZ R21). Returns the old name's link count."""
    target = stand / rel
    try:
        # guard round 8 (R3): the junction check before the folder is made, or mkdir makes it in the mod behind one
        mo2_stand.refuse_link_on_path(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        return mo2_stand.replace_file(target, data)
    except OSError as error:
        raise Refused(f"cannot replace the stand's {rel} without writing through it: {error}") from None


def take_away(stand: pathlib.Path, rel: str) -> None:
    """Delete one name of a stand file (read-only-safe: another link keeps its data and its attribute)."""
    try:
        mo2_stand.remove_file(stand / rel)
    except OSError as error:
        raise Refused(f"cannot remove the stand's {rel}: {error}") from None


def profile_folders(root: pathlib.Path) -> list[str]:
    """The profile folders tools/stand/stand_profile.ltx names ([appdata_t] ...)."""
    template = root / check_gates.PROFILE
    if not template.is_file():
        return []
    return re.findall(r"(?m)^[ \t]*\[([A-Za-z0-9_.\-]+)\]", template.read_text(encoding="utf-8", errors="replace"))


def profile(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path) -> list[str]:
    """Write the mode cvars of tools/stand/stand_profile.ltx into the stand's profiles (S2). A user.ltx is replaced
    by a new file, never written into (R21)."""
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
            elif current is not None and REMOVED_CVAR.match(line):
                raise Refused(f"{check_gates.PROFILE}:{number}: {line.split()[0].decode('ascii', 'replace')}: step S2 "
                              "removed this cvar from the engine (docs/plans/2026-11-18-two-modes.md); the template "
                              "may not write it")
            elif current is None or not MODE_CVAR.match(line):
                raise Refused(f"{check_gates.PROFILE}:{number}: only [profile folder] rows and mode cvars belong there")
            else:
                sections[current].append(line)
    for folder in sorted(sections):
        if mo2_stand.link_folder(stand, f"{folder}/user.ltx"):
            raise Refused(link_refusal([folder]))
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
            put(stand, f"{folder}/user.ltx", new)
        written += 1
    return [f"profile_sha256={on_disk_digest(root, [check_gates.PROFILE])}", f"profiles={written}"]


class Steps:
    """What a deploy does to the stand, worked out before it writes anything."""

    def __init__(self, root: pathlib.Path, engine: Optional[pathlib.Path], stand: pathlib.Path,
                 backup: pathlib.Path) -> None:
        self.winner, self.entries, self.kept, self.mod_head, self.engine_head, self.sources = plan(root, engine, stand)
        files = head_files(root, ["gamedata", "gamedata_gamma"], "")
        if engine is not None:
            files.update(head_files(engine, ["gamedata"], "engine/"))
        self.manifest = manifest_entries(stand)
        self.files, self.link_dirs = stand_files(stand)
        self.writes: list[tuple[str, bytes]] = []
        for rel, path in sorted(self.winner.items()):
            target = stand / rel
            if not (target.is_file() and target.read_bytes() == files[path]):
                self.writes.append((rel, files[path]))
        self.restores = [(rel, data, whence) for rel, data, whence in dropped_overrides(root, stand, self.winner,
                                                                                          self.manifest, backup,
                                                                                          self.files)
                         if not ((stand / rel).is_file() and data is not None and (stand / rel).read_bytes() == data)
                         and not (data is None and not (stand / rel).exists())]
        self.ours, self.foreign = leftovers(root, stand, self.winner, self.sources, backup, self.files)

    def touched(self, stand: pathlib.Path) -> list[str]:
        """Existing stand files this deploy deletes a name of (to replace or to remove)."""
        rels = [rel for rel, _ in self.writes] + [rel for rel, _, _ in self.restores] + list(self.ours)
        return [rel for rel in rels if os.path.lexists(stand / rel)]

    def blocked(self, stand: pathlib.Path, root: Optional[pathlib.Path] = None) -> list[str]:
        """'<rel>: why' for every existing stand file whose name this deploy could not delete now (a running game
        holds it), the profiles' user.ltx too, and every junction or symlink folder on the way: the deploy refuses
        before it writes anything, never writing into the file (or through the folder) instead."""
        out = [f"{rel} (a junction or symlink folder: a write through it lands in another folder)"
               for rel in self.link_dirs]
        rels = self.touched(stand)
        if root is not None:
            folders = profile_folders(root)
            out += [f"{folder} (a junction or symlink folder: a write through it lands in another folder)"
                    for folder in folders if mo2_stand.link_folder(stand, f"{folder}/user.ltx")]
            rels += [f"{folder}/user.ltx" for folder in folders if os.path.lexists(stand / folder / "user.ltx")]
        for rel in rels:
            why = mo2_stand.delete_blocker(stand / rel)
            if why:
                out.append(f"{rel} ({why})")
        return out


def links(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path) -> list[str]:
    """What a deploy would do now, and how many of the files it replaces are hard links; writes nothing (R21)."""
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    if not (stand / "gamedata").is_dir():
        raise Refused(f"not a game root: {stand}")
    steps = Steps(root, engine, stand, backup)
    replace = [rel for rel, _ in steps.writes if (stand / rel).is_file()]
    linked = [rel for rel in replace if mo2_stand.link_count(stand / rel) > 1]
    on_stand = [rel for rel in steps.winner if (stand / rel).is_file()]
    blocked = steps.blocked(stand, root)
    lines = [f"would_replace={len(replace)}", f"would_replace_links={len(linked)}",
             f"would_add={len(steps.writes) - len(replace)}", f"would_restore={len(steps.restores)}",
             f"would_remove={len(steps.ours)}",
             f"head_files_linked={sum(1 for rel in on_stand if mo2_stand.link_count(stand / rel) > 1)}",
             f"blocked={len(blocked)}"]
    lines += [f"stand_head: replaces a hard link (a new file takes the name; the mod keeps its file): {rel}"
              for rel in linked[:20]]
    lines += [f"stand_head: would move to the backup (HEAD does not have it): {rel}" for rel in steps.ours[:40]]
    lines += [f"stand_head: would restore {rel} ({whence})" for rel, _, whence in steps.restores[:40]]
    lines += [f"stand_head: cannot replace {b}" for b in blocked[:20]]
    if blocked:
        print("\n".join(lines))
        raise SystemExit(1)
    return lines


def deploy(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path, ci: pathlib.Path) -> list[str]:
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    left = dirty(root, engine)
    if left:
        raise Refused(f"{len(left)} uncommitted product or scenario file(s): the stand runs HEAD only, commit first: "
                      + "; ".join(l.strip() for l in left[:10]) + (" ..." if len(left) > 10 else ""))
    if not (stand / "gamedata").is_dir() or not (stand / "bin").is_dir():
        raise Refused(f"not a game root: {stand}")
    steps = Steps(root, engine, stand, backup)
    winner, sources = steps.winner, steps.sources
    if steps.link_dirs:
        raise Refused(link_refusal(steps.link_dirs))
    # R21: every name this deploy deletes must be deletable now; otherwise refuse before the first write
    blocked = steps.blocked(stand, root)
    if blocked:
        raise Refused(f"{len(blocked)} stand file(s) cannot be replaced without writing through them (is a game "
                      "running from the stand?): " + ", ".join(blocked[:10]))
    ours_by_manifest = {rel for rel, source in (sources or {}).items() if is_ours(source)}
    new_listed = {rel.lower() for rel in remembered(stand, backup, NEW_LIST)}
    created = [rel for rel, _ in steps.writes if not (stand / rel).is_file()]
    was_replaced = {rel for rel, _ in steps.writes if (stand / rel).is_file()}
    own_original, listed_new = [], []
    for rel in winner:
        low = rel.lower()
        if low in new_listed or low in ours_by_manifest or rel in created:
            continue
        if sources is not None and low not in sources:
            # B2: no mod has this path, so it is ours even when its bytes were already there (tools/stand_overlay.py
            # put it, maybe an older version): listed, so the deploy after HEAD drops it finds it
            listed_new.append(rel)
        elif rel in was_replaced or (backup / rel).is_file():
            # B3: a mod's own file (or, on a stand without a manifest, the stand's own file) was there first: when HEAD
            # drops our override it comes back (an older deploy's replacement counts by its backup)
            own_original.append(rel)
    # review 5, B4: the record goes into the stand itself, and before the first write (a deploy cut short still left
    # its record: the next one finds what it added)
    remember(stand, backup, NEW_LIST, created + listed_new)
    remember(stand, backup, REPLACED_LIST, own_original)
    replaced, linked = [], []
    for rel, data in steps.writes:
        target = stand / rel
        if target.is_file():
            if rel.lower() not in new_listed:
                keep_copy(backup, rel, target.read_bytes())  # the stand's first original (ours or a mod's)
            replaced.append(rel)
        if put(stand, rel, data) > 1:
            linked.append(rel)
    # B3: HEAD dropped our replacement of a mod's file: the stand shows the mod's file again
    restored, removed_originals = [], []
    for rel, data, whence in steps.restores:
        if data is None:
            if (stand / rel).is_file():
                keep_copy(backup / "removed", rel, (stand / rel).read_bytes())
                take_away(stand, rel)
                removed_originals.append(rel)
            continue
        if (stand / rel).is_file():
            keep_copy(backup / "removed", rel, (stand / rel).read_bytes())
        put(stand, rel, data)
        restored.append(f"{rel} ({whence})")
    # S1: leftovers of our layers leave the stand (into the backup), before any scenario runs
    ours = steps.ours
    for rel in ours:
        keep_copy(backup / "removed", rel, (stand / rel).read_bytes())
        take_away(stand, rel)
    add_to_list(backup, REMOVED_LIST, list(ours) + removed_originals)
    bad = verify(stand, winner, steps.entries)
    if bad:
        raise Refused(f"the stand's {bad[0]} is not HEAD's after the deploy ({len(bad)} file(s))")
    files_now, links_now = stand_files(stand)
    if links_now:
        raise Refused(link_refusal(links_now))
    left_over, foreign = leftovers(root, stand, winner, sources, backup, files_now)
    if left_over:
        raise Refused(f"the stand still holds {len(left_over)} file(s) HEAD does not have: " + ", ".join(left_over[:10]))
    still = not_restored(root, stand, winner, steps.manifest, backup, files_now)
    if still:
        raise Refused(f"the stand still holds {len(still)} dropped override(s) of a mod's file: " + ", ".join(still[:10]))
    prof = profile(root, stand, backup)
    return values(root, engine, stand, ci, steps.mod_head, steps.engine_head, steps.entries, left_over, foreign) + [
        f"deployed={len(winner)}", f"replaced={len(replaced)}", f"replaced_links={len(linked)}",
        f"added={len(created)}", f"listed={len(listed_new)}", f"removed={len(ours)}",
        f"restored={len(restored)}", f"kept_by_mods={steps.kept}"] + \
        [l for l in prof if l.startswith("profiles=")] + \
        [f"stand_head: replaced a hard link: {rel} (a new file took the name; the other links keep their file)"
         for rel in linked[:20]] + \
        [f"stand_head: restored {r}: HEAD does not override it any more" for r in restored] + \
        [f"stand_head: moved {rel} to the backup: HEAD does not have it" for rel in ours + removed_originals]


def not_restored(root: pathlib.Path, stand: pathlib.Path, winner: dict[str, str], manifest: Optional[dict[str, Entry]],
                 backup: pathlib.Path, files: Optional[StandFiles]) -> list[str]:
    """Stand files we replaced over a mod's file that HEAD dropped and that do not hold the mod's file again."""
    out = []
    for rel, data, _ in dropped_overrides(root, stand, winner, manifest, backup, files):
        target = stand / rel
        if data is None:
            if target.exists():
                out.append(rel)
        elif not target.is_file() or target.read_bytes() != data:
            out.append(rel)
    return out


def check(root: pathlib.Path, stand: pathlib.Path, backup: pathlib.Path, ci: pathlib.Path) -> list[str]:
    engine = root / "engine" if (root / "engine" / ".git").exists() else None
    left = dirty(root, engine)
    if left:
        raise Refused(f"{len(left)} uncommitted product or scenario file(s) appeared during the run: "
                      + "; ".join(l.strip() for l in left[:10]))
    winner, entries, kept, mod_head, engine_head, sources = plan(root, engine, stand)
    files, link_dirs = stand_files(stand)
    if link_dirs:
        print(f"stand_head: {link_refusal(link_dirs)}")
        raise SystemExit(1)
    bad = verify(stand, winner, entries)
    if bad:
        print(f"stand_head: the stand's {bad[0]} is not HEAD's ({len(bad)} file(s)): "
              + ", ".join(bad[:10]))
        raise SystemExit(1)
    ours, foreign = leftovers(root, stand, winner, sources, backup, files)
    if ours:
        print(f"stand_head: the stand holds {len(ours)} file(s) HEAD does not have (deploy moves them to the backup): "
              + ", ".join(ours[:10]) + (" ..." if len(ours) > 10 else ""))
        for rel in foreign:
            print(f"stand_head: kept {rel}: a GAMMA mod ships it, not our HEAD")
        raise SystemExit(1)
    still = not_restored(root, stand, winner, manifest_entries(stand), backup, files)
    if still:
        print(f"stand_head: the stand holds {len(still)} dropped override(s) of a mod's file, not the mod's file "
              "(deploy restores them): " + ", ".join(still[:10]))
        raise SystemExit(1)
    return values(root, engine, stand, ci, mod_head, engine_head, entries, ours, foreign) + [
        f"deployed={len(winner)}", f"kept_by_mods={kept}"]


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("command", choices=["deploy", "check", "profile", "links"])
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
        elif args.command == "links":
            lines = links(root, stand, backup)
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
