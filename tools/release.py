"""One versioned release tool for both channels (replaces the per-build copies temp/b56/release.py, prepare_release.py,
audit_package.py and temp/dev-42.1/{verify,publish,finish}.py).

  python -I tools/release.py --channel dev --build 57 prepare
  python -I tools/release.py --channel dev --build 57 verify [--since dev-42.1 [--since-override]] [--exe PATH]
  python -I tools/release.py --channel dev --build 57 draft   [--dry-run]
  python -I tools/release.py --channel dev --build 57 publish [--dry-run]

Channels (the owner's words: a new build goes to Dev first, to Stable only on a separate word; every build ships only on
the owner's word for that build, CLAUDE.md):
  stable  tag b<N>, version 0.<N>.0, asset anomaly-coop-0.<N>.0.zip; main of both public repositories moves to the
          release; the release becomes "latest". Only a project commit that went out as dev-<N> (or dev-<N>.x) first
  dev     tag dev-<N>, version 0.<N>.0-dev (dev-42.1: 0.42.1-dev), asset anomaly-coop-<version>.zip; a GitHub prerelease;
          only the new immutable tag is pushed, main stays; Stable's "latest" must stay where it was (compared with
          the one draft saved, before and after the edit). The launcher picks Dev as the newest published prerelease
          whose tag starts with "dev-".

prepare  makes the work folder temp/<tag>/ with release.json (names, tags, titles) and empty notes files to write.
verify   gates from the last release tag of the channel (the newest local b* or dev-* tag by build number; another
         --since only with --since-override, only an ancestor of that tag (it widens the range, never narrows it), and
         printed and recorded): `tools/check_gates.py <since>..HEAD --release --layers` with the exe being released,
         one process and one model: tools/check_layers.py passes on the tree, then the release rule (review 3): both
         stand marks and tests.ok of both HEADs whatever the changed files' layers (the stand marks name both HEADs,
         that exe and the stand's own folder), and the exe is engine-ci's build of engine HEAD (check_gates.exe_source);
         then both working trees clean (no tracked change; no untracked product file), the exe's label, the package
         (entries, layers byte for byte with the working files AND with HEAD's blobs: only committed files ship;
         release.txt, fomod version), the public diff free of secret-like text, the notes free of the lines the owner
         forbade. Writes temp/<tag>/verified.json with the notes' SHA-256. Talks to no network. The exe is copied into
         temp/<tag>/ first: the gate, the label, the hash, the package comparison and draft's upload all use that one
         copy, and verify refuses when it changed while verify ran (review 6, residual a).
draft    (GitHub) refuses unless verified.json is of this tag and channel, both HEADs are the verified ones, the notes
         are the verified ones, the --since tag is the last published release of the channel on GitHub (an override:
         an ancestor of it) (stable: and dev-<N> is published on the same project commit); then pushes the tag (and
         main for stable), creates draft
         releases with one asset each and checks them, and saves where Stable's "latest" points.
publish  (GitHub) refuses unless the same holds and both drafts are still drafts of this channel with the verified
         digests (dev: prereleases, and Stable's latest is still the one draft saved); undrafts them, checks "latest"
         again and tags the release in the local repositories (the next verify starts there).
draft and publish need `gh` signed in; --dry-run prints the commands and runs only local git reads. No token is read,
stored or printed by this tool (gh keeps its own); any text it prints passes through scrub().
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import asdict, dataclass
from typing import Callable, Optional, Sequence

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORG = "stormie-labs"
COOP_REPO, ENGINE_REPO = "RayLink-Coop", "RayLink-Engine"
EXE_NAME = "AnomalyCoopDX11AVX.exe"
DEFAULT_EXE = ROOT / "engine-ci" / "_build" / "_game" / "bin_dbg" / "AnomalyDX11AVX.exe"
PROTOCOL_HEADER = ROOT / "engine" / "src" / "xrCoop" / "coop_protocol.h"
SECRET_PATTERNS = [rb"gh[pousr]_[A-Za-z0-9]{30,}", rb"github_pat_[A-Za-z0-9_]{40,}",
                   rb"sk-(?:proj-)?[A-Za-z0-9_-]{40,}", rb"-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----"]
# (prefix in the package, folder in the project, (repository, path of that folder in it))
LAYER_DIRS = [("Anomaly Coop - Core/gamedata/", "gamedata"), ("Anomaly Coop - Engine/gamedata/", "engine/gamedata"),
              ("Anomaly Coop - GAMMA/gamedata/", "gamedata_gamma")]
NOTES = ("notes-coop.md", "notes-engine.md")
TAG_RX = {"dev": re.compile(r"dev-(\d+)(?:\.(\d+))?"), "stable": re.compile(r"b(\d+)(?:\.(\d+))?(?:-r(\d+))?")}

# The owner's rules for the public release text (2026-11-07 and later): no line about checks or about what was not seen in
# the game ("Проверки: ... В самой игре ещё не проверялось"), nothing internal about tests, no slogans. Each line is read
# without its markdown first (`**Проверки:**`, `## Проверки`, `> Проверки: ok`, `- Проверки` are the same line).
NOTES_FORBIDDEN = [
    (re.compile(r"^(?:Провер\w*|Протестир\w*|Оттестир\w*|Тест\w*|Checks?|Checked|Tests?|Tested|Testing|Verified|"
                r"Verification)\b", re.I), "a line about checks"),
    (re.compile(r"не\s+проверял|не\s+проверен|ещё\s+не\s+проверял|еще\s+не\s+проверял|игров\w*\s+прогон|в\s+самой\s+игре|"
                r"пока\s+не\s+(?:смотрел|проверял|видел|запускал|пробовал)|в\s+живой\s+игре|\bна\s+стенде\b|"
                r"not\s+(?:yet\s+)?(?:tested|checked|verified)|\bon\s+the\s+stand\b", re.I),
     "what was or was not checked in the game"),
    (re.compile(r"целев\w+\s+проверк|юнит|unit[- ]?test|pytest|\bLua\s+\d|\bC\+\+\s+\d|\b\d+\s*/\s*\d+\s+(тест|проверок|checks)|"
                r"\b\d+\s+из\s+\d+\b|прошл\w+\s+\d+|прогна\w*\s+(?:\d|тест|провер)|\b\d+\s+(?:тест\w*|проверок|проверк\w*|checks?|tests?)\b",
                re.I), "test numbers"),
    (re.compile(r"!(?=\s|$)"), "a slogan (an exclamation)"),
    (re.compile(r"приятной игры|удачи в зоне|ещё лучше|еще лучше|лучше, чем когда-либо|встречайте|долгожданн|"
                r"enjoy|have fun|stay tuned|game[- ]changer|\U0001F389|\U0001F680|\U0001F525", re.I), "a slogan"),
    (re.compile(r"Это выпуск для проверки игроками", re.I), "a slogan"),
]
MARKDOWN_LEAD = re.compile(r"^(?:[\s>#*_+\-]|\d+[.)]\s)+")
MARKDOWN_INLINE = re.compile(r"[*_`~]+")

_SECRET_TEXT = re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|[0-9a-fA-F]{32,}")
_URL_CREDENTIALS = re.compile(r"(\b[A-Za-z][A-Za-z0-9+.-]*://)[^/\s@]+@")


def scrub(text: str) -> str:
    """Text safe to print: tokens, credentials inside URLs (https://user:secret@host) and any 32+ hex string hidden."""
    return _SECRET_TEXT.sub("<hidden>", _URL_CREDENTIALS.sub(r"\1<hidden>@", text))


class Refused(Exception):
    pass


# ---- names -------------------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Names:
    channel: str
    build: str            # "57" or "42.1"
    tag: str              # b57 / dev-57
    version: str          # 0.57.0 / 0.57.0-dev
    asset: str            # anomaly-coop-<version>.zip
    exe_asset: str
    exe_labels: tuple[str, ...]
    prerelease: bool
    moves_main: bool
    coop_title: str
    engine_title: str
    work: str             # temp/<tag>


def names_for(channel: str, build: str, title: Optional[str] = None) -> Names:
    if channel not in ("stable", "dev"):
        raise Refused(f"unknown channel {channel!r}: stable or dev")
    if not re.fullmatch(r"\d{1,3}(\.\d{1,2})?", build):
        raise Refused(f"build {build!r}: a number like 57 or 42.1")
    major, _, minor = build.partition(".")
    version = f"0.{int(major)}.{int(minor or 0)}"
    if channel == "dev":
        tag, version = f"dev-{build}", version + "-dev"
        labels = ("RayLink Engine dev", f"RayLink Engine b{major}")
        coop_title = f"Dev {build}" + (f" — {title}" if title else "")
        engine_title = f"RayLink Engine — Dev {build}"
    else:
        if minor:
            raise Refused("a Stable build is a whole number (b57)")
        tag = f"b{build}"
        labels = (f"RayLink Engine b{build}",)
        coop_title = f"Сборка {build}" + (f" — {title}" if title else "")
        engine_title = f"RayLink Engine — сборка {build}"
    return Names(channel, build, tag, version, f"anomaly-coop-{version}.zip", EXE_NAME, labels, channel == "dev",
                 channel == "stable", coop_title, engine_title, f"temp/{tag}")


# ---- release tags --------------------------------------------------------------------------------------------------------

def tag_key(channel: str, tag: str) -> Optional[tuple[int, ...]]:
    m = TAG_RX[channel].fullmatch(tag)
    return tuple(int(g or 0) for g in m.groups()) if m else None


def last_release_tag(tags: Sequence[str], channel: str, exclude: str) -> Optional[str]:
    """The newest release tag of the channel by build number (b56 > b42 > b41.9; dev-57 > dev-42.1)."""
    ranked = [(tag_key(channel, t), t) for t in tags if t != exclude and tag_key(channel, t) is not None]
    return max(ranked)[1] if ranked else None


def remote_tags(run: Runner, root: pathlib.Path, repo: str) -> dict[str, str]:
    """tag -> commit of the public repository (git ls-remote; an annotated tag by its peeled commit)."""
    out: dict[str, str] = {}
    for line in must(run, ["git", "ls-remote", "--tags", f"https://github.com/{ORG}/{repo}.git"], root).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].startswith("refs/tags/"):
            name = parts[1][len("refs/tags/"):]
            if name.endswith("^{}"):
                out[name[:-3]] = parts[0]
            else:
                out.setdefault(name, parts[0])
    return out


def dev_tags_of(n: Names, tags: Sequence[str]) -> list[str]:
    """dev-<N> and dev-<N>.x of a Stable build N."""
    return [t for t in tags if re.fullmatch(rf"dev-{re.escape(n.build)}(?:\.\d+)?", t)]


# ---- notes ---------------------------------------------------------------------------------------------------------------

def notes_problems(text: str) -> list[str]:
    """Why a release text may not go public (empty: it may)."""
    problems = []
    if not text.strip():
        return ["the notes are empty"]
    for number, line in enumerate(text.splitlines(), 1):
        plain = MARKDOWN_INLINE.sub("", MARKDOWN_LEAD.sub("", line)).strip()
        for rx, why in NOTES_FORBIDDEN:
            if rx.search(plain) or rx.search(line):
                problems.append(f"line {number}: {why}: {line.strip()[:120]}")
                break
    if _SECRET_TEXT.search(text) and re.search(r"gh[pousr]_|github_pat_", text):
        problems.append("a token-like string")
    return problems


def notes_digests(work: pathlib.Path) -> dict[str, str]:
    return {name: sha256((work / name).read_bytes()) for name in NOTES if (work / name).is_file()}


def check_notes(n: Names, work: pathlib.Path, verified: dict) -> None:
    """The notes are the ones verify passed (byte for byte) and still pass the rules."""
    wanted = verified.get("notes_sha256") or {}
    for name in NOTES:
        path = work / name
        if not path.is_file():
            raise Refused(f"{n.work}/{name} missing")
        if name not in wanted:
            raise Refused(f"verified.json holds no SHA-256 of {name}: run verify again")
        if sha256(path.read_bytes()) != wanted[name]:
            raise Refused(f"{n.work}/{name} changed after verify: run verify again")
        problems = notes_problems(path.read_text(encoding="utf-8"))
        if problems:
            raise Refused(f"{n.work}/{name}: " + "; ".join(problems))


# ---- running things ----------------------------------------------------------------------------------------------------

Runner = Callable[[list[str], pathlib.Path], subprocess.CompletedProcess]


def default_runner(args: list[str], cwd: pathlib.Path) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")


def must(run: Runner, args: list[str], cwd: pathlib.Path) -> str:
    done = run(args, cwd)
    if done.returncode != 0:
        raise Refused(f"{args[0]} {' '.join(args[1:3])}... failed ({done.returncode}): "
                      f"{scrub((done.stdout or '')[-600:] + (done.stderr or '')[-600:])}")
    return (done.stdout or "").strip()


# ---- verify ------------------------------------------------------------------------------------------------------------

OWNER_WAIVER = re.compile(r"^[РR]\d{1,3}$")


def check_waiver(root: pathlib.Path, waiver: str) -> None:
    """An owner's waiver names a decision row of TZ.md (`| Р24 | ...`): the owner's words, in the project's own record."""
    if not OWNER_WAIVER.match(waiver):
        raise Refused(f"--owner-waiver {waiver!r}: the waiver is a decision row of TZ.md, like Р24")
    tz = root / "TZ.md"
    rows = tz.read_text(encoding="utf-8").splitlines() if tz.is_file() else []
    if not any(line.startswith(f"| {waiver} |") for line in rows):
        raise Refused(f"--owner-waiver {waiver}: no row {waiver} in TZ.md (the owner's decision is recorded there first)")


def gate_checks(run: Runner, root: pathlib.Path, since: str, exe: pathlib.Path,
                waiver: Optional[str] = None) -> tuple[list[str], str]:
    """check_layers and check_gates, first, in one process (check_gates --layers builds the layer model once and runs
    check_layers on it before the gate; exit 3: the layer check failed): the lines to show, and what an owner's waiver
    waived. Raises Refused when either fails. --release: the release rule (both stand marks and tests.ok whatever the
    files' layers) and the exe built from engine HEAD.
    An owner's waiver (TZ.md Р24, 2026-11-21: Dev 57 after a stand round whose marks did not match HEAD) waives the
    marks only: the layers still decide, and the exe must still be engine-ci's build of engine HEAD (--exe-source)."""
    gates = run([sys.executable, "-I", str(root / "tools" / "check_gates.py"), f"{since}..HEAD", "--release", "--layers",
                 "--root", str(root), "--exe", str(exe)], root)
    out = gates.stdout or ""
    layer_lines = [l for l in out.splitlines() if l.startswith("check_layers:")]
    shown = [scrub(layer_lines[-1])] if layer_lines else []
    if gates.returncode == 3:
        raise Refused("check_layers failed: " + scrub(out[-1500:]))
    shown += [scrub(l) for l in out.splitlines()
              if l.startswith("gates: required") or (l.startswith("gates:") and "ok" in l.lower())]
    if gates.returncode != 0:
        if not waiver:
            raise Refused("check_gates refused (stand marks temp/gates/*.ok or tests.ok missing or stale, the exe not "
                          "engine-ci's build of engine HEAD, or a commit to split): " + scrub(out[-1500:]))
        source = run([sys.executable, "-I", str(root / "tools" / "check_gates.py"), "--exe-source", "--exe", str(exe)], root)
        if source.returncode != 0:
            raise Refused(f"--owner-waiver {waiver} waives the stand and tests marks only, and the exe is not engine-ci's "
                          "build of engine HEAD: " + scrub((source.stdout or "")[-800:]))
        waived = "\n".join(scrub(l) for l in out.splitlines() if l.startswith("gates:") and "required" not in l)
        shown.append(f"gates: WAIVED by the owner (TZ.md {waiver}): " + "; ".join(waived.splitlines()))
        return shown, waived
    return shown, ""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob_id(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def protocol_version(root: pathlib.Path) -> Optional[int]:
    path = root / "engine" / "src" / "xrCoop" / "coop_protocol.h"
    if not path.is_file():
        return None
    m = re.search(r"kProtocolVersion\s*=\s*(\d+)", path.read_text(encoding="utf-8", errors="replace"))
    return int(m.group(1)) if m else None


def head_blobs(run: Runner, root: pathlib.Path, source: str) -> dict[str, str]:
    """path under the project -> blob id at HEAD of the repository that holds source (engine/gamedata: the engine's)."""
    repo, inside = (root / "engine", source[len("engine/"):]) if source.startswith("engine/") else (root, source)
    prefix = "engine/" if source.startswith("engine/") else ""
    out: dict[str, str] = {}
    for item in must(run, ["git", "ls-tree", "-r", "-z", "HEAD", "--", inside], repo).split("\0"):
        meta, _, path = item.partition("\t")
        parts = meta.split()
        if len(parts) == 3 and parts[1] == "blob":
            out[prefix + path] = parts[2]
    return out


def check_package(root: pathlib.Path, n: Names, archive: pathlib.Path, exe_hash: str, project: str, engine: str,
                  protocol: Optional[int], run: Optional[Runner] = None) -> dict:
    """The package against the sources (from audit_package.py and the verify of b56 / dev-42.1). With a runner, every
    layer entry must also be HEAD's blob of that file: only committed (and so gated) files ship."""
    compared = 0
    blobs = {source: head_blobs(run, root, source) for _, source in LAYER_DIRS} if run else {}
    with zipfile.ZipFile(archive) as package:
        if package.testzip() is not None:
            raise Refused("the package has a broken entry")
        names = package.namelist()
        if len(names) != len(set(names)):
            raise Refused("duplicate entries in the package")
        if any("\\" in x or x.startswith("/") or ".." in x.split("/") for x in names):
            raise Refused("an entry path is not relative")
        if sha256(package.read(f"Anomaly Coop - Engine/bin/{EXE_NAME}")) != exe_hash:
            raise Refused("the package's exe is not the exe being released")
        text = package.read("anomaly-coop-release.txt").decode("utf-8-sig")
        wanted = [f"Anomaly Coop {n.version}", project[:7], engine[:7], exe_hash]
        if protocol is not None:
            wanted.append(f"protocol      {protocol}")
        for value in wanted:
            if value not in text:
                raise Refused(f"anomaly-coop-release.txt lacks {scrub(value)!r}")
        if not any(label in text for label in n.exe_labels):
            raise Refused("anomaly-coop-release.txt names no engine label of this build")
        version = ET.fromstring(package.read("fomod/info.xml")).find("Version")
        if version is None or version.text != n.version:
            raise Refused(f"fomod/info.xml version is not {n.version}")
        ET.fromstring(package.read("fomod/ModuleConfig.xml"))
        for name in names:
            if name.endswith("/"):
                continue
            if any(part in name for part in ("/temp/", "__pycache__")) or name.endswith((".pdb", ".log", ".pyc", ".env")):
                raise Refused(f"a file that must not ship: {name}")
            for prefix, source in LAYER_DIRS:
                if name.startswith(prefix):
                    data = package.read(name)
                    rel = source + "/" + name[len(prefix):]
                    if data != (root / rel).read_bytes():
                        raise Refused(f"differs from the source: {name}")
                    if run:
                        blob = blobs[source].get(rel)
                        if blob is None:
                            raise Refused(f"not committed (no blob at HEAD): {name}")
                        if blob not in (git_blob_id(data), git_blob_id(data.replace(b"\r\n", b"\n"))):
                            raise Refused(f"differs from HEAD's blob (an uncommitted change): {name}")
                    compared += 1
    return {"entries": len(names), "compared": compared}


def is_ancestor(run: Runner, root: pathlib.Path, older: str, newer: str) -> bool:
    """git merge-base --is-ancestor: older is newer or one of its ancestors (exit 0); 1: it is not; else refused."""
    done = run(["git", "merge-base", "--is-ancestor", older, newer], root)
    if done.returncode not in (0, 1):
        raise Refused(f"git merge-base --is-ancestor {older} {newer} failed ({done.returncode}): "
                      f"{scrub((done.stderr or '')[-300:])}")
    return done.returncode == 0


def choose_since(n: Names, run: Runner, root: pathlib.Path, since: Optional[str], override: bool) -> tuple[str, str]:
    """(the tag verify gates from, the last release tag of the channel). Another --since only widens the gated range
    (review 2, B14): with --since-override, and only an ancestor of the last release."""
    tags = must(run, ["git", "tag", "--list"], root).split()
    last = last_release_tag(tags, n.channel, n.tag)
    if since is None:
        if last is None:
            raise Refused(f"no earlier {n.channel} release tag here: fetch the tags (git fetch --tags) and run verify "
                          "again")
        return last, last
    if since != last:
        if not override:
            raise Refused(f"--since {since} is not the last {n.channel} release {last or '(none here)'}: verify gates "
                          "from the last release of the channel (a later start would leave commits ungated)")
        if last is not None and not is_ancestor(run, root, since, last):
            raise Refused(f"--since {since} is not an ancestor of the last {n.channel} release {last}: an override may "
                          "only widen the gated range, never narrow it")
        print(f"verify: --since-override: gating from {since}, not from the last {n.channel} release "
              f"{last or '(none here)'}")
    return since, last or ""


def verify(n: Names, root: pathlib.Path, since: Optional[str], exe: pathlib.Path, run: Runner = default_runner,
           archive: Optional[pathlib.Path] = None, since_override: bool = False, waiver: Optional[str] = None) -> dict:
    work = root / n.work
    if waiver:
        check_waiver(root, waiver)
    since, last = choose_since(n, run, root, since, since_override)
    # review 6, residual (a): one copy of the exe in temp/<tag>/ is what the gate judges, what the label, the hash and
    # the package are checked against, and what draft uploads; it may not change while verify runs
    asset = work / EXE_NAME  # the engine release's one asset, under the name players install
    judged = exe
    if exe.is_file():
        work.mkdir(parents=True, exist_ok=True)
        if asset.resolve() != exe.resolve():
            shutil.copy2(exe, asset)
        judged = asset
    before = sha256(judged.read_bytes()) if judged.is_file() else None
    shown, waived = gate_checks(run, root, since, judged, waiver)
    for line in shown:
        print("verify:", line)
    engine = root / "engine"
    for repo in (root, engine):
        if must(run, ["git", "status", "--porcelain", "--untracked-files=no"], repo):
            raise Refused(f"uncommitted changes in {repo.name}")
    # an untracked product file is in no HEAD and in no mark (the engine's: the exe may hold it; review 3, C12)
    for repo, paths in ((root, ["gamedata", "gamedata_gamma"]), (engine, ["src", "gamedata"])):
        untracked = must(run, ["git", "status", "--porcelain", "--untracked-files=all", "--", *paths], repo)
        if untracked:
            raise Refused(f"untracked product files in {repo.name}: "
                          + "; ".join(l.strip() for l in untracked.splitlines()[:5]) + ": commit or remove them")
    project = must(run, ["git", "rev-parse", "HEAD"], root)
    engine_sha = must(run, ["git", "rev-parse", "HEAD"], engine)
    if n.channel == "stable":
        tags = must(run, ["git", "tag", "--list", "--points-at", project], root).split()
        if not dev_tags_of(n, tags):
            raise Refused(f"Stable {n.tag} ships only what went out to Dev first: no dev-{n.build} tag on {project[:8]}")
    if not judged.is_file():
        raise Refused(f"no exe {exe}")
    data = judged.read_bytes()
    exe_hash = sha256(data)
    if exe_hash != before:
        raise Refused(f"the exe {judged} changed while verify ran (the gate judged other bytes): run verify again")
    if not any(label.encode() + b"\0" in data or label.encode() in data for label in n.exe_labels):
        raise Refused(f"the exe carries none of the labels {n.exe_labels}")
    archive = archive or root / "releases" / n.asset
    if not archive.is_file():
        raise Refused(f"no package {archive} (tools/package.ps1 makes it)")
    package = check_package(root, n, archive, exe_hash, project, engine_sha, protocol_version(root), run)
    for repo in (root, engine):
        diff = run(["git", "diff", since, "HEAD", "--"], repo)
        if diff.returncode != 0:
            raise Refused(f"git diff {since}..HEAD failed in {repo.name}")
        if any(re.search(p, (diff.stdout or "").encode("utf-8", "replace")) for p in SECRET_PATTERNS):
            raise Refused(f"secret-like content in the public diff of {repo.name}")
    for notes in NOTES:
        path = work / notes
        problems = notes_problems(path.read_text(encoding="utf-8")) if path.is_file() else [f"{notes} missing"]
        if problems:
            raise Refused(f"{n.work}/{notes}: " + "; ".join(problems))
    work.mkdir(parents=True, exist_ok=True)
    if sha256(asset.read_bytes()) != exe_hash:
        raise Refused(f"the exe {asset} changed while verify ran: run verify again")
    result = dict(asdict(n), project=project, engine=engine_sha, archive=str(archive), zip_sha256=sha256(archive.read_bytes()),
                  exe=str(asset), exe_source=str(exe), exe_built_from=engine_sha, exe_sha256=exe_hash, since=since,
                  since_override=since != last, owner_waiver=waiver or None, waived=waived,
                  last_release=last, notes_sha256=notes_digests(work), **package)
    (work / "verified.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"verify: OK, {package['entries']} entries, {package['compared']} compared, exe {exe_hash[:8]}")
    return result


# ---- draft and publish (GitHub) ----------------------------------------------------------------------------------------

@dataclass
class Step:
    args: list[str]
    cwd: str
    network: bool  # talks to GitHub

    def text(self) -> str:
        return scrub(" ".join(self.args))


def draft_plan(n: Names, verified: dict, snapshot: str, root: pathlib.Path) -> list[Step]:
    """The commands of `draft`, in order. The engine's public tree is a snapshot commit (`snapshot`) of the source tree on top
    of the public main; the co-op repository publishes the project's HEAD itself."""
    work = root / n.work
    engine = root / "engine"
    steps: list[Step] = []
    targets = [(ENGINE_REPO, engine, snapshot, work / EXE_NAME, work / "notes-engine.md", n.engine_title),
               (COOP_REPO, root, verified["project"], pathlib.Path(verified["archive"]), work / "notes-coop.md", n.coop_title)]
    for repo, cwd, sha, *_ in targets:
        url = f"https://github.com/{ORG}/{repo}.git"
        refs = [f"{sha}:refs/tags/{n.tag}"] + ([f"{sha}:refs/heads/main"] if n.moves_main else [])
        steps.append(Step(["git", "push", "--dry-run", "--atomic", url, *refs], str(cwd), True))
    for repo, cwd, sha, *_ in targets:
        url = f"https://github.com/{ORG}/{repo}.git"
        refs = [f"{sha}:refs/tags/{n.tag}"] + ([f"{sha}:refs/heads/main"] if n.moves_main else [])
        steps.append(Step(["git", "push", "--atomic", url, *refs], str(cwd), True))
    for repo, cwd, sha, asset, notes, title in targets:
        create = ["gh", "release", "create", n.tag, str(asset), "--repo", f"{ORG}/{repo}", "--verify-tag", "--draft",
                  "--latest=false", "--title", title, "--notes-file", str(notes)]
        if n.prerelease:
            create.insert(create.index("--draft") + 1, "--prerelease")
        steps.append(Step(create, str(root), True))
    return steps


def publish_plan(n: Names, root: pathlib.Path) -> list[Step]:
    steps = []
    for repo in (ENGINE_REPO, COOP_REPO):
        edit = ["gh", "release", "edit", n.tag, "--repo", f"{ORG}/{repo}", "--draft=false"]
        edit += ["--prerelease", "--latest=false"] if n.prerelease else ["--prerelease=false", "--latest=true"]
        steps.append(Step(edit, str(root), True))
    return steps


def gh_json(run: Runner, root: pathlib.Path, path: str) -> dict:
    return json.loads(must(run, ["gh", "api", path], root))


def load_verified(n: Names, root: pathlib.Path, run: Runner) -> dict:
    """verified.json of this tag and channel, both HEADs as verified, the notes as verified."""
    work = root / n.work
    path = work / "verified.json"
    if not path.is_file():
        raise Refused(f"no {n.work}/verified.json: run verify first")
    verified = json.loads(path.read_text(encoding="utf-8"))
    if verified.get("tag") != n.tag or verified.get("channel") != n.channel:
        raise Refused(f"verified.json is of {verified.get('tag')} / {verified.get('channel')}, not {n.tag} / {n.channel}")
    for local, key in ((root, "project"), (root / "engine", "engine")):
        if must(run, ["git", "rev-parse", "HEAD"], local) != verified.get(key):
            raise Refused(f"{local.name} HEAD moved since verify (verified {str(verified.get(key))[:8]}): run verify again")
    check_notes(n, work, verified)
    return verified


def check_published_since(n: Names, verified: dict, run: Runner, root: pathlib.Path) -> None:
    """The gated range starts at the last published release of the channel; Stable went out as dev-<N> first."""
    published = remote_tags(run, root, COOP_REPO)
    last = last_release_tag(list(published), n.channel, n.tag)
    since = verified.get("since")
    if since != last:
        if not verified.get("since_override"):
            raise Refused(f"verify gated from {since}, but the last published {n.channel} release is {last}: "
                          f"fetch the tags (git fetch --tags) and run verify again")
        if last is not None and not is_ancestor(run, root, str(since), published[last]):
            raise Refused(f"verify gated from {since}, which is not an ancestor of the last published {n.channel} "
                          f"release {last}: an override may only widen the gated range, never narrow it")
        print(f"draft: --since-override: gated from {since}; the last published {n.channel} release is {last}")
    if n.channel == "stable":
        dev = [t for t in dev_tags_of(n, list(published)) if published[t] == verified["project"]]
        if not dev:
            raise Refused(f"Stable {n.tag}: no published dev-{n.build} tag on the project commit "
                          f"{verified['project'][:8]}: a build goes to Dev first")


def check_drafts(n: Names, verified: dict, run: Runner, root: pathlib.Path) -> None:
    for repo, key in ((ENGINE_REPO, "exe_sha256"), (COOP_REPO, "zip_sha256")):
        data = gh_json(run, root, f"repos/{ORG}/{repo}/releases/tags/{n.tag}")
        assets = data.get("assets", [])
        if not data.get("draft") or bool(data.get("prerelease")) != n.prerelease or len(assets) != 1:
            raise Refused(f"{repo}: the draft is not as made (draft {data.get('draft')}, prerelease "
                          f"{data.get('prerelease')}, {len(assets)} asset(s))")
        if assets[0].get("digest") != "sha256:" + verified[key]:
            raise Refused(f"{repo}: the uploaded asset's digest differs from verified.json")


def draft(n: Names, root: pathlib.Path, run: Runner, dry_run: bool) -> list[Step]:
    work = root / n.work
    verified = load_verified(n, root, run)
    engine = root / "engine"
    if dry_run:
        snapshot = "<snapshot of the engine tree on the public main>"
        print(f"would check: {n.channel} release tags of {COOP_REPO} (the gated range starts at the last published one"
              + ("; dev-" + n.build + " published on the project commit" if n.channel == "stable" else "") + ")")
    else:
        check_published_since(n, verified, run, root)
        for repo in (COOP_REPO, ENGINE_REPO):
            if must(run, ["git", "ls-remote", f"https://github.com/{ORG}/{repo}.git", f"refs/tags/{n.tag}"], root):
                raise Refused(f"{repo} already has the tag {n.tag}")
            latest = gh_json(run, root, f"repos/{ORG}/{repo}/releases/latest")
            (work / f"{repo}-stable-before.json").write_text(json.dumps(latest, ensure_ascii=False, indent=2), encoding="utf-8")
        public_main = must(run, ["git", "ls-remote", f"https://github.com/{ORG}/{ENGINE_REPO}.git", "refs/heads/main"], root).split()[0]
        tree = must(run, ["git", "rev-parse", "HEAD^{tree}"], engine)
        message = work / "engine-source.txt"
        message.write_text(f"{n.engine_title}\n\nSource tree: {verified['engine']}\n", encoding="utf-8")
        snapshot = must(run, ["git", "commit-tree", tree, "-p", public_main, "-F", str(message)], engine)
        (work / "source-targets.json").write_text(json.dumps({ENGINE_REPO: snapshot, COOP_REPO: verified["project"]}, indent=2),
                                                  encoding="utf-8")
    steps = draft_plan(n, verified, snapshot, root)
    for step in steps:
        print(("would run: " if dry_run else "run: ") + step.text())
        if not dry_run:
            must(run, step.args, pathlib.Path(step.cwd))
    if not dry_run:
        check_drafts(n, verified, run, root)
        print("draft: both drafts made; download them and check their SHA-256 against verified.json before publish")
    return steps


def publish(n: Names, root: pathlib.Path, run: Runner, dry_run: bool) -> list[Step]:
    work = root / n.work
    verified = load_verified(n, root, run)
    steps = publish_plan(n, root)
    saved: dict[str, dict] = {}
    if dry_run:
        print("would check: both drafts (draft, " + ("prerelease" if n.prerelease else "not a prerelease")
              + ", the verified digests)" + ("; Stable's latest is the one draft saved" if n.prerelease else ""))
    else:
        check_drafts(n, verified, run, root)
        for repo in (ENGINE_REPO, COOP_REPO):
            path = work / f"{repo}-stable-before.json"
            if not path.is_file():
                raise Refused(f"no {n.work}/{path.name}: draft saves where Stable's latest points; run draft")
            saved[repo] = json.loads(path.read_text(encoding="utf-8"))
            if n.prerelease:
                now = gh_json(run, root, f"repos/{ORG}/{repo}/releases/latest")
                if now.get("id") != saved[repo].get("id"):
                    raise Refused(f"{repo}: Stable's latest is {now.get('tag_name')}, not {saved[repo].get('tag_name')} "
                                  "as at draft: find out who moved it before publishing")
    for step in steps:
        print(("would run: " if dry_run else "run: ") + step.text())
        if not dry_run:
            must(run, step.args, pathlib.Path(step.cwd))
    if not dry_run:
        for repo in (ENGINE_REPO, COOP_REPO):
            latest = gh_json(run, root, f"repos/{ORG}/{repo}/releases/latest")
            if n.prerelease and latest.get("id") != saved[repo].get("id"):
                raise Refused(f"{repo}: Stable's latest moved; it must stay {saved[repo].get('tag_name')}")
            if not n.prerelease and latest.get("tag_name") != n.tag:
                raise Refused(f"{repo}: latest is {latest.get('tag_name')}, not {n.tag}")
        targets = json.loads((work / "source-targets.json").read_text(encoding="utf-8")) \
            if (work / "source-targets.json").is_file() else {}
        for local, sha in ((root, verified["project"]), (root / "engine", targets.get(ENGINE_REPO))):
            if sha and not must(run, ["git", "tag", "--list", n.tag], local):
                must(run, ["git", "tag", n.tag, sha], local)  # the next verify gates from here
        print("publish: done; download the public assets and compare their SHA-256 with verified.json")
    return steps


def prepare(n: Names, root: pathlib.Path) -> pathlib.Path:
    work = root / n.work
    work.mkdir(parents=True, exist_ok=True)
    (work / "release.json").write_text(json.dumps(asdict(n), ensure_ascii=False, indent=2), encoding="utf-8")
    for notes in NOTES:
        path = work / notes
        if not path.exists():
            path.write_text("", encoding="utf-8")
    print(f"prepare: {n.work}/release.json; write {n.work}/notes-coop.md and notes-engine.md (what the player sees, "
          f"no line about checks, no slogans); then tools/package.ps1, then verify")
    return work


def main(argv: Optional[Sequence[str]] = None, run: Runner = default_runner, root: pathlib.Path = ROOT) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--channel", required=True, choices=["stable", "dev"])
    ap.add_argument("--build", required=True, help="57, or 42.1 for a dev point build")
    ap.add_argument("--title", help="the release's title after the build name")
    ap.add_argument("--since", help="the previous release tag (default: the last release tag of the channel)")
    ap.add_argument("--since-override", action="store_true",
                    help="gate from an older --since than the last release tag of the channel: widens the gated range "
                         "(an ancestor of that tag only; printed, recorded)")
    ap.add_argument("--exe", default=str(DEFAULT_EXE), help="the exe being released")
    ap.add_argument("--owner-waiver", metavar="ROW",
                    help="verify: the owner's decision row of TZ.md (Р24) that waives the stand and tests marks; the "
                         "layers and the exe built from engine HEAD still decide (printed, recorded in verified.json)")
    ap.add_argument("--archive", help="the package (default releases/anomaly-coop-<version>.zip)")
    ap.add_argument("--dry-run", action="store_true", help="draft/publish: print the commands, run only local git reads")
    ap.add_argument("command", choices=["prepare", "verify", "draft", "publish"])
    args = ap.parse_args(argv)
    try:
        n = names_for(args.channel, args.build, args.title)
        if args.since_override and not args.since:
            raise Refused("--since-override needs --since")
        if args.command == "prepare":
            prepare(n, root)
        elif args.command == "verify":
            verify(n, root, args.since, pathlib.Path(args.exe), run, pathlib.Path(args.archive) if args.archive else None,
                   args.since_override, args.owner_waiver)
        elif args.command == "draft":
            draft(n, root, run, args.dry_run)
        else:
            publish(n, root, run, args.dry_run)
    except Refused as error:
        print(f"release: refused: {scrub(str(error))}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
