"""Overlay this repository's top layers (Core gamedata\\, GAMMA gamedata_gamma\\) and the CI exe on a launcher-made
stand (a materialized game root with one merged gamedata\\), keeping everything it replaces.

    python -I tools/stand_overlay.py <stand> <backup dir> [--dry] [--no-exe]

- A file is copied only when the stand has none or its bytes differ.
- What is replaced goes to <backup dir>\\<relative path> first (never overwritten by a later run: the first backup is
  the stand's original). Files the stand did not have are listed in <backup dir>\\new_files.txt.
- The Engine layer (engine\\gamedata, the lowest priority in MO2) is NOT overlaid: on a merged root it would replace
  files that mods override. Deploy it by hand when engine\\gamedata changes.
- Revert: copy <backup dir> back over the stand and delete the files of new_files.txt.
- Hard links (TZ.md R21): the launcher's stand is hard links to the mods' own files. A stand file is never written in
  place: its old name is deleted first (read-only-safe) and a new file takes the name (tools/mo2_stand.py replace_file),
  so the mod keeps its bytes and its read-only attribute. A junction or symlink folder on the way to a file is refused
  before anything is written: a write through it would land in another folder, a mod's (review 5 of the layer guard).
- This copies the WORKING tree, untracked files included: the stand then runs code no commit has. The stand's own
  record (.raylink-head-deploy.json, tools/mo2_stand.py remember_on_stand; review 5, B3/B4) names every gamedata file
  this added and every mod file it replaced, before the first write; tools/stand/stand_head.py deploy (the first step of
  tools/stand_hostplay.ps1 and stand_srv.ps1) moves away what HEAD does not have and puts the mods' files back, so no
  stand mark ever certifies an overlay.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I leaves the script's folder out
import mo2_stand  # noqa: E402  (replace_file: never write into a hard-linked stand file)
SKIP_NAMES = {"axr_options.ltx", "cache_dbg.ltx"}
SKIP_EXT = {".bak", ".tmp", ".log", ".orig"}
OURS = ("Anomaly Coop - Engine/", "Anomaly Coop - Core/", "Anomaly Coop - GAMMA/")  # our layers, as the launcher names them


def mod_sources(stand: Path) -> dict:
    """Lower-case stand path -> the mod file the launcher placed there (our own layers left out); {} without a
    manifest."""
    manifest = stand / ".raylink-stand.json"
    if not manifest.is_file():
        return {}
    out = {}
    for entry in json.loads(manifest.read_text(encoding="utf-8")).get("entries", []):
        source = (entry.get("source") or "").replace("\\", "/")
        if entry.get("rel") and source and not any(layer in source for layer in OURS):
            out[entry["rel"].replace("\\", "/").lower()] = source
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    dry = "--dry" in sys.argv
    stand, backup = Path(args[0]), Path(args[1])
    if not (stand / "gamedata").is_dir() or not (stand / "bin").is_dir():
        sys.exit(f"not a game root: {stand}")
    jobs = []
    for layer in ("gamedata", "gamedata_gamma"):  # the later layer wins
        base = ROOT / layer
        if not base.is_dir():
            continue
        for src in sorted(base.rglob("*")):
            if not src.is_file() or src.name in SKIP_NAMES or src.suffix.lower() in SKIP_EXT:
                continue
            rel = src.relative_to(base)
            if "temp" in rel.parts or "__pycache__" in rel.parts:
                continue
            jobs.append((src, Path("gamedata") / rel))
    if "--no-exe" not in sys.argv:
        jobs.append((ROOT / "engine-ci/_build/_game/bin_dbg/AnomalyDX11AVX.exe", Path("bin/AnomalyCoopDX11AVX.exe")))
    latest = {}
    for src, rel in jobs:
        latest[rel] = src  # a GAMMA-layer file replaces the Core one of the same path
    through = sorted({f for f in (mo2_stand.link_folder(stand, rel.as_posix()) for rel in latest) if f})
    if through:
        sys.exit(f"refusing: {len(through)} junction or symlink folder(s) in the stand ({', '.join(through[:10])}): a "
                 "write through one lands in another folder (a mod's); the launcher builds real folders")
    mods = mod_sources(stand)
    todo, copied, added = [], [], []
    for rel, src in latest.items():
        dst = stand / rel
        data = src.read_bytes()
        if dst.is_file() and dst.read_bytes() == data:
            continue
        (copied if dst.is_file() else added).append(rel)
        todo.append((rel, data))
    if not dry and todo:
        # the stand's record first (review 5, B4): a deploy from any worktree finds what this put there
        mo2_stand.remember_on_stand(
            stand, new_files=[r.as_posix() for r in added if r.parts[0] == "gamedata"],
            replaced_files=[r.as_posix() for r in copied if r.parts[0] == "gamedata" and r.as_posix().lower() in mods])
    for rel, data in todo:
        dst = stand / rel
        if dst.is_file():
            keep = backup / rel
            if not keep.exists() and not dry:
                keep.parent.mkdir(parents=True, exist_ok=True)
                keep.write_bytes(dst.read_bytes())  # a copy of our own (copy2 would carry a mod's read-only bit)
        if not dry:
            mo2_stand.refuse_link_on_path(dst)  # guard round 8 (R3): before mkdir, which would make a folder in a mod
            dst.parent.mkdir(parents=True, exist_ok=True)
            mo2_stand.replace_file(dst, data)
    if added and not dry:
        backup.mkdir(parents=True, exist_ok=True)
        listed = backup / "new_files.txt"
        known = set(listed.read_text(encoding="utf-8").splitlines()) if listed.exists() else set()
        listed.write_text("\n".join(sorted(known | {r.as_posix() for r in added})) + "\n", encoding="utf-8")
    print(f"{'would replace' if dry else 'replaced'} {len(copied)}, {'would add' if dry else 'added'} {len(added)}")
    for rel in copied:
        print("  ~", rel.as_posix())
    for rel in added:
        print("  +", rel.as_posix())
    if todo and not dry:
        print("stand_overlay: the stand runs this WORKING tree now (untracked files too); tools\\stand_hostplay.ps1 and "
              "stand_srv.ps1 deploy HEAD first and move this overlay's extra files away")


if __name__ == "__main__":
    main()
