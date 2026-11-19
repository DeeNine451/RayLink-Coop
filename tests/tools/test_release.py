"""tools/release.py: names and tags of both channels, the notes rules, the refusals of verify, draft and publish, and
the GitHub steps (nothing here talks to the network: a fake runner answers git and gh, and a dry run fails the test if
it calls anything but a local git read). The release holes of the adversarial review (temp/modes_review/
attack_release.py and review:guard release_holes) are rebuilt here.
Run: python -m pytest tests\\tools\\test_release.py -q
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest

import release
from conftest import ROOT

PROJECT, ENGINE = "1" * 40, "2" * 40
EXE_SHA, ZIP_SHA = "3" * 64, "4" * 64


def done(args, out="", code=0):
    return subprocess.CompletedProcess(args, code, out, "")


class Fake:
    """A runner that answers check_layers / check_gates, local git and (unless network=False) git ls-remote and gh, and
    records every call. Anything else fails the test."""

    def __init__(self, root=None, layers=0, gates=0, out="", tags=("b42", "b41.9", "dev-42.1"), points_at=(),
                 heads=(PROJECT, ENGINE), remote=None, releases=None, latest=None, network=True, ancestors=(),
                 untracked=""):
        self.root = Path(root) if root else None
        self.ancestors = set(ancestors)            # (a, b): a is an ancestor of b (git merge-base --is-ancestor)
        self.untracked = untracked                 # git status --untracked-files=all -- <product folders>
        self.calls = []
        self.layers, self.gates, self.out = layers, gates, out
        self.tags, self.points_at, self.heads = list(tags), list(points_at), heads
        self.remote = dict(remote or {})            # tag -> commit on GitHub (the co-op repository)
        self.releases = dict(releases or {})        # repo -> release json of the tag
        self.latest = dict(latest or {})            # repo -> latest release json
        self.network = network
        self.made_tags = []

    def __call__(self, args, cwd):
        args = [str(a) for a in args]
        self.calls.append(args)
        joined = " ".join(args)
        layers = "check_layers: " + ("OK (1 files, ceiling 0, used 0)" if self.layers == 0 else "FAIL (1)") + "\n" + \
            self.out
        if "check_layers.py" in joined:
            return done(args, layers, self.layers)
        if "check_gates.py" in joined:
            # --layers: the layer check runs first on the same model; exit 3 when it fails (the gate does not run)
            first = layers if "--layers" in args else ""
            if "--layers" in args and self.layers:
                return done(args, first + "gates: tools/check_layers.py failed on the tree (above): fix it first\n", 3)
            return done(args, first + "gates: required: hostplay.ok, srv.ok, tests.ok\n" + (
                "gates: OK\n" if self.gates == 0 else "gates: hostplay.ok missing (run tools\\stand_hostplay.ps1)\ngates: FAIL (1)\n"),
                self.gates)
        if args[:3] == ["git", "tag", "--list"]:
            if "--points-at" in args:
                return done(args, "\n".join(self.points_at))
            if len(args) == 4:
                return done(args, args[3] if args[3] in self.tags else "")
            return done(args, "\n".join(self.tags))
        if args[:2] == ["git", "tag"] and len(args) == 4:
            self.made_tags.append((args[2], args[3], str(cwd)))
            return done(args)
        if args[:3] == ["git", "rev-parse", "HEAD"]:
            engine = self.root is not None and Path(cwd) == self.root / "engine"
            return done(args, self.heads[1] if engine else self.heads[0])
        if args[:2] == ["git", "status"]:
            return done(args, self.untracked if "--untracked-files=all" in args else "")  # clean trees
        if args[:3] == ["git", "merge-base", "--is-ancestor"]:
            return done(args, "", 0 if args[3] == args[4] or (args[3], args[4]) in self.ancestors else 1)
        network = args[:2] in (["git", "ls-remote"], ["git", "push"], ["gh", "api"], ["gh", "release"]) \
            or args[:2] == ["git", "commit-tree"]
        if network and not self.network:
            raise AssertionError(f"ran {args[:3]} in a dry run")
        if args[:3] == ["git", "ls-remote", "--tags"]:
            return done(args, "\n".join(f"{sha}\trefs/tags/{t}" for t, sha in self.remote.items()))
        if args[:2] == ["git", "ls-remote"] and args[-1].startswith("refs/tags/"):
            return done(args, "")
        if args[:2] == ["git", "ls-remote"] and args[-1] == "refs/heads/main":
            return done(args, "5" * 40 + "\trefs/heads/main")
        if args[:3] == ["git", "rev-parse", "HEAD^{tree}"]:
            return done(args, "6" * 40)
        if args[:2] == ["git", "commit-tree"]:
            return done(args, "7" * 40)
        if args[:2] == ["git", "push"] or args[:3] == ["gh", "release", "create"]:
            return done(args)
        if args[:3] == ["gh", "release", "edit"]:
            return done(args)
        if args[:2] == ["gh", "api"]:
            path = args[2]
            repo = path.split("/")[2]
            if path.endswith("/releases/latest"):
                return done(args, json.dumps(self.latest.get(repo, {"id": 1, "tag_name": "b56"})))
            return done(args, json.dumps(self.releases.get(repo, {})))
        raise AssertionError(f"unexpected call {args[:4]}")


def edits(fake):
    return [c for c in fake.calls if c[:3] == ["gh", "release", "edit"]]


# --- names -----------------------------------------------------------------------------------------------------------

def test_dev_names():
    n = release.names_for("dev", "57")
    assert (n.tag, n.version, n.asset) == ("dev-57", "0.57.0-dev", "anomaly-coop-0.57.0-dev.zip")
    assert n.prerelease and not n.moves_main
    assert "RayLink Engine dev" in n.exe_labels and n.work == "temp/dev-57"


def test_dev_point_build_matches_dev_42_1():
    n = release.names_for("dev", "42.1")
    assert (n.tag, n.version, n.asset) == ("dev-42.1", "0.42.1-dev", "anomaly-coop-0.42.1-dev.zip")


def test_stable_names():
    n = release.names_for("stable", "57", "отдых на базе")
    assert (n.tag, n.version, n.asset) == ("b57", "0.57.0", "anomaly-coop-0.57.0.zip")
    assert not n.prerelease and n.moves_main
    assert n.exe_labels == ("RayLink Engine b57",)
    assert n.coop_title == "Сборка 57 — отдых на базе"


@pytest.mark.parametrize(("channel", "build"), [("stable", "57.1"), ("dev", "57a"), ("beta", "57"), ("dev", "")])
def test_bad_names_are_refused(channel, build):
    with pytest.raises(release.Refused):
        release.names_for(channel, build)


def test_last_release_tag_is_by_build_number_per_channel():
    tags = ["b41.9", "b42", "b56", "b9", "dev-42.1", "dev-9", "dev-57", "v1", "b56-r2"]
    assert release.last_release_tag(tags, "stable", "b57") == "b56-r2"
    assert release.last_release_tag(tags, "dev", "dev-57") == "dev-42.1"
    assert release.last_release_tag(["b42"], "dev", "dev-57") is None


# --- notes -----------------------------------------------------------------------------------------------------------

def test_published_b56_notes_pass():
    for name in ("notes-coop.md", "notes-engine.md"):
        path = ROOT / "temp" / "b56" / name
        if not path.is_file():
            pytest.skip("temp/b56 notes are not here")
        assert release.notes_problems(path.read_text(encoding="utf-8")) == [], name


@pytest.mark.parametrize("line", [
    "Проверки: C++ 1423 из 1423, Lua 205 файлов. В самой игре ещё не проверялось.",
    "Пройдены целевые проверки репутации; полноценный игровой прогон этой сборки ещё не проводился.",
    "Это выпуск для проверки игроками.",
    "Приятной игры!",
    "Тесты: 1738/1738",
    "Stay tuned for more",
    # the review's lines that passed (attack_release.py): markdown around the word, no colon, mid-line slogans
    "**Проверки:** стенд обоих режимов",
    "## Проверки",
    "Проверка: всё прошло",
    "Tested on the stand of both modes",
    "Протестировано в игре на стенде",
    "В игре пока не смотрели",
    "Ещё не проверено в живой игре",
    "Отлично! Теперь сервер быстрее",
    "Мы прогнали 240 тестов",
    "Проверки - пройдены",
    "> Проверки: ok",
    "- Проверки: стенд",
    "1. Проверено на стенде",
])
def test_forbidden_note_lines(line):
    text = "Что нового.\n\n- Глушители больше не пропадают.\n" + line + "\n"
    problems = release.notes_problems(text)
    assert problems and "line 4" in problems[0], problems


def test_plain_notes_pass_and_empty_ones_do_not():
    assert release.notes_problems("Исправления.\n\n- Отряды у клиента больше не роняют игру.\n\nПротокол 32.\n") == []
    assert release.notes_problems("## Исправления\n\n- **Сервер:** карта больше не теряет отряды (x != y).\n") == []
    assert release.notes_problems("- Сталкеры прогоняют мутантов от лагеря; Checkpoints keep their place.\n") == []
    assert release.notes_problems("  \n") == ["the notes are empty"]


def test_scrub():
    assert release.scrub("token ghp_" + "a" * 36 + " sha " + "f" * 40) == "token <hidden> sha <hidden>"


def test_scrub_hides_credentials_inside_urls():
    # the review: https://x-access-token:...@github.com/... was printed as is (git and gh errors echo remote URLs)
    text = release.scrub("fatal: https://x-access-token:v1.abcdefabcdef0123@github.com/o/r.git and "
                         "https://user:pass@example.invalid/x")
    assert "abcdef" not in text and "pass@" not in text and "x-access-token" not in text, text
    assert "https://<hidden>@github.com/o/r.git" in text


# --- verify: the range, the gates first --------------------------------------------------------------------------------

def test_verify_refuses_when_check_layers_fails(tmp_path):
    fake = Fake(layers=1)
    with pytest.raises(release.Refused, match="check_layers failed"):
        release.verify(release.names_for("dev", "57"), tmp_path, "dev-42.1", tmp_path / "x.exe", fake)
    assert [c[:3] for c in fake.calls][0] == ["git", "tag", "--list"]
    assert "check_gates.py" in " ".join(fake.calls[1]) and "--layers" in fake.calls[1] and len(fake.calls) == 2


def test_verify_refuses_without_the_stand_marks(tmp_path):
    fake = Fake(gates=1)
    with pytest.raises(release.Refused, match="stand marks"):
        release.verify(release.names_for("dev", "57"), tmp_path, "dev-42.1", tmp_path / "x.exe", fake)
    assert "check_gates.py" in " ".join(fake.calls[1]) and "dev-42.1..HEAD" in fake.calls[1]
    assert any(str(tmp_path / "x.exe") == str(a) for a in fake.calls[1])


def test_verify_runs_the_release_rule_on_one_model(tmp_path, capsys):
    # item 1 of round 4: --release (both stands and tests.ok whatever the layers, the exe built from engine HEAD);
    # item 6: --layers runs check_layers on the gate's own model, so no second model build in another process
    with pytest.raises(release.Refused, match="tests.ok"):
        release.verify(release.names_for("dev", "57"), tmp_path, "dev-42.1", tmp_path / "x.exe", Fake(gates=1))
    fake = Fake()
    (tmp_path / "x.exe").write_bytes(b"MZ no label")
    with pytest.raises(release.Refused, match="labels"):  # past both checks: the next one is the exe's label
        release.verify(release.names_for("dev", "57"), tmp_path, "dev-42.1", tmp_path / "x.exe", fake)
    python = [c for c in fake.calls if "check_gates.py" in " ".join(c) or "check_layers.py" in " ".join(c)]
    assert len(python) == 1 and "--release" in python[0] and "--layers" in python[0], fake.calls
    out = capsys.readouterr().out
    assert "verify: check_layers: OK" in out and "verify: gates: required: hostplay.ok, srv.ok, tests.ok" in out, out


def test_verify_refuses_untracked_product_files(tmp_path):
    # C12: an untracked engine source is in no commit, no mark and no tests.ok, but the exe may hold it
    fake = Fake(untracked="?? src/xrGame/coop/coop_wip.cpp")
    with pytest.raises(release.Refused, match="untracked product files in .*coop_wip.cpp"):
        release.verify(release.names_for("dev", "57"), tmp_path, "dev-42.1", tmp_path / "x.exe", fake)


def test_verify_gates_from_the_last_release_of_the_channel(tmp_path):
    # item 12: without --since the range starts at the newest dev-* tag; a later tag narrows the gate and is refused
    fake = Fake(gates=1, tags=("b42", "b56", "dev-42.1", "dev-50"))
    with pytest.raises(release.Refused, match="stand marks"):
        release.verify(release.names_for("dev", "57"), tmp_path, None, tmp_path / "x.exe", fake)
    assert "dev-50..HEAD" in fake.calls[1]
    fake = Fake(tags=("b42", "b56", "dev-42.1", "dev-50"))
    with pytest.raises(release.Refused, match="not the last dev release dev-50") as refused:
        release.verify(release.names_for("dev", "57"), tmp_path, "HEAD~1", tmp_path / "x.exe", fake)
    assert "--since-override" not in str(refused.value)  # B14: the refusal does not hand out the way around it
    assert len(fake.calls) == 1  # nothing ran past the refusal
    with pytest.raises(release.Refused) as refused:
        release.verify(release.names_for("dev", "57"), tmp_path, None, tmp_path / "x.exe", Fake(tags=("b42",)))
    assert "no earlier dev release tag" in str(refused.value) and "--since-override" not in str(refused.value)


def test_since_override_only_widens_the_range(tmp_path, capsys):
    # B14: --since-override with a tag older than the last release widens the gated range (printed, recorded) ...
    fake = Fake(gates=1, tags=("dev-41", "dev-42.1"), ancestors={("dev-41", "dev-42.1")})
    with pytest.raises(release.Refused, match="stand marks"):
        release.verify(release.names_for("dev", "57"), tmp_path, "dev-41", tmp_path / "x.exe", fake, since_override=True)
    assert "--since-override: gating from dev-41, not from the last dev release dev-42.1" in capsys.readouterr().out
    assert "dev-41..HEAD" in fake.calls[2]
    # ... a newer one would narrow it (the commits before it would need nothing): refused before any gate runs
    fake = Fake(gates=1)
    with pytest.raises(release.Refused, match="only widen") as refused:
        release.verify(release.names_for("dev", "57"), tmp_path, "HEAD~1", tmp_path / "x.exe", fake, since_override=True)
    assert "--since-override" not in str(refused.value)
    assert not any("check_gates.py" in " ".join(c) for c in fake.calls)
    assert release.main(["--channel", "dev", "--build", "57", "--since-override", "verify"], Fake(), tmp_path) == 1
    assert "--since-override needs --since" in capsys.readouterr().out


def test_stable_verify_needs_the_same_commit_out_as_dev_first(tmp_path):
    fake = Fake(tags=("b56", "dev-57"), points_at=())
    with pytest.raises(release.Refused, match="Dev first: no dev-57 tag"):
        release.verify(release.names_for("stable", "57"), tmp_path, None, tmp_path / "x.exe", fake)
    assert "b56..HEAD" in fake.calls[1]
    fake = Fake(tags=("b56", "dev-57"), points_at=("dev-57",))
    with pytest.raises(release.Refused, match="labels"):  # past the Dev rule: the next check is the exe's label
        (tmp_path / "x.exe").write_bytes(b"MZ no label")
        release.verify(release.names_for("stable", "57"), tmp_path, None, tmp_path / "x.exe", fake)


def test_main_verify_exit_1_and_no_token_printed(tmp_path, capsys):
    token = "ghp_" + "A" * 36
    code = release.main(["--channel", "dev", "--build", "57", "--since", "dev-42.1", "verify"], Fake(layers=1, out=token),
                        tmp_path)
    out = capsys.readouterr().out
    assert code == 1 and "refused" in out
    assert token not in out and "<hidden>" in out


# --- the package: only committed files ship ----------------------------------------------------------------------------

def blob(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class Tree:
    """git ls-tree -r -z HEAD -- <folder> of the two repositories."""

    def __init__(self, mod=None, engine=None):
        self.mod, self.engine = mod or {}, engine or {}

    def __call__(self, args, cwd):
        assert args[:4] == ["git", "ls-tree", "-r", "-z"], args
        tree = self.engine if Path(cwd).name == "engine" else self.mod
        return done(args, "".join(f"100644 blob {sha}\t{path}\0" for path, sha in tree.items()))


def package(tmp_path, files: dict) -> tuple[Path, release.Names, str]:
    n = release.names_for("dev", "57")
    exe = b"MZ RayLink Engine dev"
    exe_hash = hashlib.sha256(exe).hexdigest()
    archive = tmp_path / n.asset
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr(f"Anomaly Coop - Engine/bin/{release.EXE_NAME}", exe)
        z.writestr("anomaly-coop-release.txt", f"Anomaly Coop {n.version}\n{PROJECT[:7]} {ENGINE[:7]}\n{exe_hash}\n"
                                               "RayLink Engine dev\n")
        z.writestr("fomod/info.xml", f"<fomod><Version>{n.version}</Version></fomod>")
        z.writestr("fomod/ModuleConfig.xml", "<config/>")
        for name, data in files.items():
            z.writestr(name, data)
    return archive, n, exe_hash


def test_package_entries_must_be_heads_blobs(tmp_path):
    # item 12: an untracked or changed-but-uncommitted file that is in the package (and on disk) was shipped
    script = b"function f() end\r\n"
    (tmp_path / "gamedata/scripts").mkdir(parents=True)
    (tmp_path / "gamedata/scripts/coop_items.script").write_bytes(script)
    (tmp_path / "gamedata/scripts/coop_new.script").write_bytes(b"x = 1\n")
    archive, n, exe_hash = package(tmp_path, {"Anomaly Coop - Core/gamedata/scripts/coop_items.script": script})
    committed = Tree(mod={"gamedata/scripts/coop_items.script": blob(script.replace(b"\r\n", b"\n"))})  # autocrlf
    got = release.check_package(tmp_path, n, archive, exe_hash, PROJECT, ENGINE, None, committed)
    assert got["compared"] == 1
    with pytest.raises(release.Refused, match="not committed"):
        archive, n, exe_hash = package(tmp_path, {"Anomaly Coop - Core/gamedata/scripts/coop_new.script": b"x = 1\n"})
        release.check_package(tmp_path, n, archive, exe_hash, PROJECT, ENGINE, None, committed)
    with pytest.raises(release.Refused, match="differs from HEAD's blob"):
        archive, n, exe_hash = package(tmp_path, {"Anomaly Coop - Core/gamedata/scripts/coop_items.script": script})
        release.check_package(tmp_path, n, archive, exe_hash, PROJECT, ENGINE, None,
                              Tree(mod={"gamedata/scripts/coop_items.script": blob(b"function f() return 1 end\n")}))


def test_engine_gamedata_entries_are_the_engine_repositorys_blobs(tmp_path):
    data = b"-- axr\n"
    (tmp_path / "engine/gamedata/scripts").mkdir(parents=True)
    (tmp_path / "engine/gamedata/scripts/axr_main.script").write_bytes(data)
    archive, n, exe_hash = package(tmp_path, {"Anomaly Coop - Engine/gamedata/scripts/axr_main.script": data})
    got = release.check_package(tmp_path, n, archive, exe_hash, PROJECT, ENGINE, None,
                                Tree(engine={"gamedata/scripts/axr_main.script": blob(data)}))
    assert got["compared"] == 1



# --- review 6 (round 7), residual (a): the exe the gate judged is the exe that ships -------------------------------------
# verify used to hand check_gates the exe's own path and then read that path again for the label, the hash, the package
# comparison and verified.json: an exe swapped in between went out unjudged (temp/modes_review6 attacks6 A1, a fake
# runner: the gate saw ae2f31a4..., verified.json recorded 59da3222...). Now the exe is copied into temp/<tag>/ first;
# the gate, the label, the hash and the package all judge that copy, and a copy that changed during verify is refused.

class SwapFake(Fake):
    """Fake, plus the reads a whole verify makes (git ls-tree, git diff), and a gate that writes `swap` over a file:
    "original" (the exe verify was given) or "given" (whatever path the gate was handed)."""

    def __init__(self, original: Path, swap: bytes, target: str, **kw):
        super().__init__(**kw)
        self.original, self.swap, self.target, self.gate_exe = original, swap, target, None

    def __call__(self, args, cwd):
        args = [str(a) for a in args]
        if args[:2] == ["git", "ls-tree"] or args[:2] == ["git", "diff"]:
            self.calls.append(args)
            return done(args, "")
        if "check_gates.py" in " ".join(args):
            self.gate_exe = Path(args[args.index("--exe") + 1])
            seen = self.gate_exe.read_bytes()
            (self.original if self.target == "original" else self.gate_exe).write_bytes(self.swap)
            self.gate_saw = seen
        return super().__call__(args, cwd)


def whole_verify(tmp_path, exe: bytes, packaged: bytes, swap: bytes, target: str):
    n = release.names_for("dev", "57")
    original = tmp_path / "engine-ci" / "AnomalyDX11AVX.exe"
    original.parent.mkdir(parents=True)
    original.write_bytes(exe)
    work = tmp_path / n.work
    work.mkdir(parents=True)
    for name in release.NOTES:
        (work / name).write_text("Что нового: торговля у костра.\n", encoding="utf-8")
    archive = tmp_path / "releases" / n.asset
    archive.parent.mkdir()
    packaged_hash = hashlib.sha256(packaged).hexdigest()
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr(f"Anomaly Coop - Engine/bin/{release.EXE_NAME}", packaged)
        z.writestr("anomaly-coop-release.txt", f"Anomaly Coop {n.version}\n{PROJECT[:7]} {ENGINE[:7]}\n{packaged_hash}\n"
                                               "RayLink Engine dev\n")
        z.writestr("fomod/info.xml", f"<fomod><Version>{n.version}</Version></fomod>")
        z.writestr("fomod/ModuleConfig.xml", "<config/>")
    fake = SwapFake(original, swap, target, root=tmp_path)
    return n, original, fake, lambda: release.verify(n, tmp_path, "dev-42.1", original, fake)


def test_verify_judges_one_copy_of_the_exe(tmp_path, capsys):
    exe = b"MZ RayLink Engine dev: the build"
    n, original, fake, run = whole_verify(tmp_path, exe, exe, exe, "original")
    result = run()
    copy = tmp_path / n.work / release.EXE_NAME
    assert fake.gate_exe == copy and fake.gate_saw == exe  # the gate was handed the copy
    assert result["exe_sha256"] == hashlib.sha256(exe).hexdigest() and result["exe"] == str(copy)
    assert result["exe_source"] == str(original)
    capsys.readouterr()


def test_verify_never_ships_an_exe_swapped_in_after_the_gate(tmp_path, capsys):
    # attacks6 A1: the package already holds the swapped-in exe; the gate judged the one before it
    judged, swapped = b"MZ RayLink Engine dev: judged", b"MZ RayLink Engine dev: swapped in"
    n, original, fake, run = whole_verify(tmp_path, judged, swapped, swapped, "original")
    with pytest.raises(release.Refused, match="the package's exe is not the exe being released"):
        run()
    assert fake.gate_saw == judged
    assert not (tmp_path / n.work / "verified.json").exists()
    capsys.readouterr()


def test_verify_refuses_a_copy_that_changed_during_the_gate(tmp_path, capsys):
    exe, other = b"MZ RayLink Engine dev: judged", b"MZ RayLink Engine dev: changed"
    n, original, fake, run = whole_verify(tmp_path, exe, other, other, "given")
    with pytest.raises(release.Refused, match="changed while verify ran"):
        run()
    assert not (tmp_path / n.work / "verified.json").exists()
    capsys.readouterr()


# --- draft and publish -------------------------------------------------------------------------------------------------

def verified(tmp_path, n, **extra):
    work = tmp_path / n.work
    work.mkdir(parents=True, exist_ok=True)
    digests = {}
    for notes in release.NOTES:
        (work / notes).write_text("Исправления.\n", encoding="utf-8")
        digests[notes] = hashlib.sha256((work / notes).read_bytes()).hexdigest()
    data = dict(tag=n.tag, channel=n.channel, project=PROJECT, engine=ENGINE, exe=str(tmp_path / "game.exe"),
                archive=str(tmp_path / n.asset), exe_sha256=EXE_SHA, zip_sha256=ZIP_SHA, since="dev-42.1",
                since_override=False, last_release="dev-42.1", notes_sha256=digests)
    data.update(extra)
    (work / "verified.json").write_text(json.dumps(data), encoding="utf-8")
    return data


def drafts(n, prerelease=None, digest_engine=EXE_SHA, digest_coop=ZIP_SHA, draft=True):
    pre = n.prerelease if prerelease is None else prerelease
    return {release.ENGINE_REPO: {"draft": draft, "prerelease": pre, "assets": [{"digest": "sha256:" + digest_engine}]},
            release.COOP_REPO: {"draft": draft, "prerelease": pre, "assets": [{"digest": "sha256:" + digest_coop}]}}


def stable_before(tmp_path, n, latest=None):
    for repo in (release.ENGINE_REPO, release.COOP_REPO):
        (tmp_path / n.work / f"{repo}-stable-before.json").write_text(
            json.dumps(latest or {"id": 1, "tag_name": "b56"}), encoding="utf-8")


def test_dev_draft_dry_run_runs_nothing_and_keeps_main(tmp_path, capsys):
    n = release.names_for("dev", "57")
    verified(tmp_path, n)
    steps = release.draft(n, tmp_path, Fake(tmp_path, network=False), dry_run=True)
    out = capsys.readouterr().out
    assert all(line.startswith(("would run: ", "would check: ")) for line in out.strip().splitlines())
    pushes = [s.args for s in steps if s.args[:2] == ["git", "push"]]
    assert len(pushes) == 4 and all("refs/tags/dev-57" in " ".join(p) for p in pushes)
    assert not any("refs/heads/main" in " ".join(p) for p in pushes)
    creates = [s.args for s in steps if s.args[:3] == ["gh", "release", "create"]]
    assert len(creates) == 2
    for c in creates:
        assert "--draft" in c and "--prerelease" in c and "--latest=false" in c and c[3] == "dev-57"
    assert any(n.asset in " ".join(c) for c in creates) and any(release.EXE_NAME in " ".join(c) for c in creates)
    assert PROJECT not in out  # ids are hidden in printed commands


def test_stable_draft_moves_main_and_is_not_a_prerelease(tmp_path, capsys):
    n = release.names_for("stable", "57")
    verified(tmp_path, n, since="b56", last_release="b56")
    steps = release.draft(n, tmp_path, Fake(tmp_path, network=False), dry_run=True)
    capsys.readouterr()
    pushes = [" ".join(s.args) for s in steps if s.args[:2] == ["git", "push"]]
    assert all("refs/heads/main" in p and "refs/tags/b57" in p for p in pushes)
    creates = [s.args for s in steps if s.args[:3] == ["gh", "release", "create"]]
    assert all("--prerelease" not in c for c in creates)


def test_publish_dry_run_dev_keeps_stable_latest_and_stable_takes_it(tmp_path, capsys):
    dev = release.names_for("dev", "57")
    verified(tmp_path, dev)
    steps = release.publish(dev, tmp_path, Fake(tmp_path, network=False), dry_run=True)
    for s in steps:
        assert "--prerelease" in s.args and "--latest=false" in s.args and "--draft=false" in s.args
    stable = release.names_for("stable", "57")
    verified(tmp_path, stable)
    steps = release.publish(stable, tmp_path, Fake(tmp_path, network=False), dry_run=True)
    for s in steps:
        assert "--prerelease=false" in s.args and "--latest=true" in s.args
    capsys.readouterr()


def test_draft_refuses_without_verify_or_for_another_tag(tmp_path, capsys):
    n = release.names_for("dev", "57")
    assert release.main(["--channel", "dev", "--build", "57", "--dry-run", "draft"], Fake(tmp_path, network=False),
                        tmp_path) == 1
    assert "run verify first" in capsys.readouterr().out
    data = verified(tmp_path, n)
    data["tag"] = "dev-56"
    (tmp_path / n.work / "verified.json").write_text(json.dumps(data), encoding="utf-8")
    assert release.main(["--channel", "dev", "--build", "57", "--dry-run", "draft"], Fake(tmp_path, network=False),
                        tmp_path) == 1
    assert "not dev-57" in capsys.readouterr().out


@pytest.mark.parametrize("command", ["draft", "publish"])
def test_draft_and_publish_refuse_when_a_head_moved_or_the_notes_changed(tmp_path, capsys, command):
    # item 12: verified.json must still match both HEADs; the notes are the ones verify passed
    n = release.names_for("dev", "57")
    verified(tmp_path, n)
    args = ["--channel", "dev", "--build", "57", "--dry-run", command]
    assert release.main(args, Fake(tmp_path, network=False, heads=(PROJECT, "9" * 40)), tmp_path) == 1
    assert "engine HEAD moved since verify" in capsys.readouterr().out
    assert release.main(args, Fake(tmp_path, network=False, heads=("8" * 40, ENGINE)), tmp_path) == 1
    assert "HEAD moved since verify" in capsys.readouterr().out
    (tmp_path / n.work / "notes-coop.md").write_text("Исправления.\n\nПроверки: стенд обоих режимов\n", encoding="utf-8")
    assert release.main(args, Fake(tmp_path, network=False), tmp_path) == 1
    assert "notes-coop.md changed after verify" in capsys.readouterr().out
    verified(tmp_path, n, notes_sha256={})
    assert release.main(args, Fake(tmp_path, network=False), tmp_path) == 1
    assert "no SHA-256 of notes-coop.md" in capsys.readouterr().out


def test_draft_refuses_a_range_that_does_not_start_at_the_last_published_release(tmp_path, capsys):
    # item 12: verify gated from dev-42.1, but dev-50 went out since
    n = release.names_for("dev", "57")
    verified(tmp_path, n)
    fake = Fake(tmp_path, remote={"dev-42.1": "a" * 40, "dev-50": "b" * 40, "b56": "c" * 40})
    with pytest.raises(release.Refused, match="last published dev release is dev-50"):
        release.draft(n, tmp_path, fake, dry_run=False)
    assert not any(c[:2] == ["git", "push"] for c in fake.calls)
    verified(tmp_path, n, since_override=True)
    fake = Fake(tmp_path, remote={"dev-42.1": "a" * 40, "dev-50": "b" * 40}, releases=drafts(n),
                ancestors={("dev-42.1", "b" * 40)})
    release.draft(n, tmp_path, fake, dry_run=False)
    assert "--since-override: gated from dev-42.1" in capsys.readouterr().out


def test_draft_refuses_an_override_that_narrowed_the_range(tmp_path, capsys):
    # B14: verify gated from a commit after the last published release; the override may only widen the range
    n = release.names_for("dev", "57")
    verified(tmp_path, n, since="c" * 40, since_override=True)
    fake = Fake(tmp_path, remote={"dev-42.1": "a" * 40, "dev-50": "b" * 40}, releases=drafts(n))
    with pytest.raises(release.Refused, match="only widen") as refused:
        release.draft(n, tmp_path, fake, dry_run=False)
    assert "--since-override" not in str(refused.value)
    assert not any(c[:2] == ["git", "push"] for c in fake.calls)


def test_stable_draft_needs_a_published_dev_tag_on_the_project_commit(tmp_path, capsys):
    n = release.names_for("stable", "57")
    verified(tmp_path, n, since="b56", last_release="b56")
    fake = Fake(tmp_path, remote={"b56": "c" * 40, "dev-57": "d" * 40})
    with pytest.raises(release.Refused, match="no published dev-57 tag on the project commit"):
        release.draft(n, tmp_path, fake, dry_run=False)
    fake = Fake(tmp_path, remote={"b56": "c" * 40, "dev-57": PROJECT}, releases=drafts(n))
    release.draft(n, tmp_path, fake, dry_run=False)
    assert any(c[:2] == ["git", "push"] for c in fake.calls)
    capsys.readouterr()


@pytest.mark.parametrize(("why", "fake_kw", "message"), [
    ("a digest differs", {"releases": "digest"}, "digest differs from verified.json"),
    ("not a prerelease any more", {"releases": "stable"}, "the draft is not as made"),
    ("not a draft any more", {"releases": "published"}, "the draft is not as made"),
    ("Stable's latest moved since draft", {"latest": {"id": 2, "tag_name": "b57"}}, "Stable's latest is b57, not b56"),
])
def test_dev_publish_refuses_before_any_edit(tmp_path, capsys, why, fake_kw, message):
    # item 12: publish checked only that verified.json exists; now the drafts and Stable's latest are checked first
    n = release.names_for("dev", "57")
    verified(tmp_path, n)
    stable_before(tmp_path, n)
    kw = dict(fake_kw)
    if kw.get("releases") == "digest":
        kw["releases"] = drafts(n, digest_coop="f" * 64)
    elif kw.get("releases") == "stable":
        kw["releases"] = drafts(n, prerelease=False)
    elif kw.get("releases") == "published":
        kw["releases"] = drafts(n, draft=False)
    else:
        kw["releases"] = drafts(n)
    if "latest" in kw:
        kw["latest"] = {release.ENGINE_REPO: kw["latest"], release.COOP_REPO: kw["latest"]}
    fake = Fake(tmp_path, **kw)
    with pytest.raises(release.Refused, match=message):
        release.publish(n, tmp_path, fake, dry_run=False)
    assert edits(fake) == [], why


def test_dev_publish_edits_then_tags_locally(tmp_path, capsys):
    n = release.names_for("dev", "57")
    verified(tmp_path, n)
    stable_before(tmp_path, n)
    (tmp_path / n.work / "source-targets.json").write_text(json.dumps({release.ENGINE_REPO: "7" * 40}), encoding="utf-8")
    fake = Fake(tmp_path, releases=drafts(n))
    release.publish(n, tmp_path, fake, dry_run=False)
    assert len(edits(fake)) == 2 and all("--latest=false" in e for e in edits(fake))
    assert ("dev-57", PROJECT, str(tmp_path)) in fake.made_tags
    assert ("dev-57", "7" * 40, str(tmp_path / "engine")) in fake.made_tags
    assert "publish: done" in capsys.readouterr().out


def test_stable_publish_refuses_a_prerelease_draft(tmp_path, capsys):
    n = release.names_for("stable", "57")
    verified(tmp_path, n)
    stable_before(tmp_path, n)
    fake = Fake(tmp_path, releases=drafts(n, prerelease=True))
    with pytest.raises(release.Refused, match="the draft is not as made"):
        release.publish(n, tmp_path, fake, dry_run=False)
    assert edits(fake) == []


def test_prepare_writes_the_plan(tmp_path, capsys):
    assert release.main(["--channel", "dev", "--build", "57", "prepare"], Fake(network=False), tmp_path) == 0
    plan = json.loads((tmp_path / "temp/dev-57/release.json").read_text(encoding="utf-8"))
    assert plan["tag"] == "dev-57" and plan["prerelease"] is True
    assert (tmp_path / "temp/dev-57/notes-coop.md").exists()
    capsys.readouterr()


# --- review 5, B2: no way to publish around release.py ----------------------------------------------------------------
# tools/publish_dev.sh and publish_dev_engine.sh ran `gh release create dev-<N>.<M> --prerelease` on any zip or exe: no
# gate, no mark, no clean tree, no HEAD (temp/modes_review5b/a3_publish_dev.txt). The launcher serves the newest dev-*
# prerelease, so that was a Dev build with no check at all. Every publishing command in tools/ must be release.py's,
# whose draft and publish refuse without the verify of this tag (and verify runs check_gates --release --layers).

# Round 7 (review 6, residual e): also the list form of Python and JS (["gh", "release", "create", ...]), gh api with
# a field (-f / -F / --field / --raw-field / --input: an implicit POST), curl / wget / Invoke-RestMethod / Invoke-WebRequest
# that send (a method other than GET, a body, an upload), and a command split over lines (\ ` ^ at the end of a line).
Q = r"[\"']"
PUBLISHES = re.compile(
    r"\bgh\s+release\s+(?:create|edit|upload|delete)\b|"
    r"\bgh\s+api\b[^\n]*(?:(?:-X|--method)\s*=?\s*(?:POST|PATCH|PUT|DELETE)\b|\s(?:-f|-F|--field|--raw-field|--input)\b)|"
    r"\bgit\b[^\n]*\bpush\b|"
    rf"{Q}gh{Q}\s*,\s*{Q}release{Q}\s*,\s*{Q}(?:create|edit|upload|delete){Q}|"
    rf"{Q}gh{Q}\s*,\s*{Q}api{Q}[^\]\n]*{Q}(?:-X|--method|-f|-F|--field|--raw-field|--input){Q}|"
    rf"{Q}git{Q}\s*,[^\]\n]*{Q}push{Q}|"
    r"\b(?:curl|wget)\b[^\n]*(?:\s(?:-X|--request)\s*=?\s*(?:POST|PATCH|PUT|DELETE)\b|\s(?:-d|--data\S*|-F|--form|-T|"
    r"--upload-file|--post-data|--post-file)\b)|"
    r"\bInvoke-(?:RestMethod|WebRequest)\b[^\n]*-Method\s+(?:Post|Patch|Put|Delete)\b|"
    r"\bInvoke-(?:RestMethod|WebRequest)\b[^\n]*\s-(?:Body|InFile)\b", re.I)
TEXT_SUFFIXES = {".sh", ".bash", ".zsh", ".ps1", ".psm1", ".py", ".pyw", ".cmd", ".bat", ".js", ".mjs", ".cjs", ".ts",
                 ".mts", ".cts", ".lua"}  # and a file without a suffix (round 8, R4)
CONTINUED = re.compile(r"(?:\\|`|\^)\s*$")


def logical_lines(text: str) -> list[str]:
    """The lines of a tool with a command split over lines (\\ ` ^ at the end) joined into one."""
    out, acc = [], ""
    for line in text.splitlines():
        if CONTINUED.search(line):
            acc += CONTINUED.sub(" ", line)
            continue
        out.append(acc + line)
        acc = ""
    if acc:
        out.append(acc)
    return out
GATED_PUBLISHER = {"tools/release.py"}
# Tools that publish only after `release.py --channel <channel> verify` passed, and whose coop and engine release is
# release.py's own draft and publish (round 7, review 6): the first network command of the file comes after the verify
# line (test below), and a refused verify ends the run before any network command (test_publish_github_*).
VERIFY_FIRST = {"tools/publish_github.sh": "stable"}
# A tool that still publishes around release.py would be named here with its owner, and the test fails while a name is
# stale. Empty since round 7: tools/publish_github.sh (the Stable publish) went through release.py.
NOT_YET_GATED: set[str] = set()


# Guard round 8 (the review of round 7, R4): gh repo changes (visibility, create, delete), a PowerShell argument array
# (`& gh @('release', 'create', ...)`, also kept in a variable), Python and JS HTTP sends (requests / httpx, urllib with
# a body or a method, http.client, fetch with a method), a list split one item per line (bracket_lines), and a tool
# file without a suffix (a shebang script).
PUBLISHES_MORE = re.compile(
    r"\bgh\s+repo\s+(?:create|edit|delete|rename|archive|unarchive|fork|sync)\b|"
    rf"{Q}gh{Q}\s*,\s*{Q}repo{Q}\s*,\s*{Q}(?:create|edit|delete|rename|archive|unarchive|fork|sync){Q}|"
    rf"@\(\s*{Q}(?:release|repo){Q}\s*,\s*{Q}(?:create|edit|upload|delete|rename|archive){Q}|"
    rf"@\(\s*{Q}api{Q}\s*,[^)\n]*{Q}(?:-X|--method|-f|-F|--field|--raw-field|--input){Q}|"
    r"\b(?:requests|httpx|aiohttp|session)\s*\.\s*(?:post|put|patch|delete)\s*\(|"
    rf"\.\s*request\s*\(\s*{Q}(?:POST|PUT|PATCH|DELETE){Q}|"
    rf"\bRequest\s*\([^\n]*(?:\bdata\s*=|\bmethod\s*=\s*{Q}(?:POST|PUT|PATCH|DELETE){Q})|"
    r"\burlopen\s*\([^\n]*\bdata\s*=|"
    rf"\bfetch\s*\([^\n]*\bmethod\s*:\s*{Q}(?:POST|PUT|PATCH|DELETE){Q}", re.I)
COMMENT_STARTS = ("#", "rem ", "REM ", "::", "--", "//")
MAX_JOINED = 40  # lines a bracket may hold open before the join gives up (a stray bracket in a string)


def bracket_delta(code: str) -> int:
    """How many brackets a line leaves open (strings and an inline `# comment` left out)."""
    depth, quote, i = 0, None, 0
    while i < len(code):
        c = code[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or code[i - 1] in " \t"):
            break
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        i += 1
    return depth


def bracket_lines(text: str) -> list[str]:
    """The lines of a tool with a bracketed list or call over several lines joined into one."""
    out, acc, depth, held = [], "", 0, 0
    for line in text.splitlines():
        code = "" if line.lstrip().startswith(COMMENT_STARTS) else line
        acc += " " + code
        depth = max(0, depth + bracket_delta(code))
        held = held + 1 if depth else 0
        if depth == 0 or held >= MAX_JOINED:
            out.append(acc.strip())
            acc, depth, held = "", 0, 0
    if acc.strip():
        out.append(acc.strip())
    return out


def publishes(text: str) -> bool:
    """Any line (a logical line, or a bracket joined over lines) of a tool's text sends a release, a push or a body."""
    for line in logical_lines(text) + bracket_lines(text):
        code = line.lstrip()
        if code and not code.startswith(COMMENT_STARTS) and (PUBLISHES.search(code) or PUBLISHES_MORE.search(code)):
            return True
    return False


def publishing_tools(tools: Path = ROOT / "tools") -> set[str]:
    found = set()
    for path in sorted(tools.rglob("*")):
        if not path.is_file() or "__pycache__" in path.parts:
            continue
        if path.suffix.lower() not in TEXT_SUFFIXES and path.suffix:
            continue
        if publishes(path.read_text(encoding="utf-8", errors="replace")):
            found.add(path.relative_to(tools.parent).as_posix())
    return found


def test_only_release_py_publishes():
    found = publishing_tools()
    assert found - GATED_PUBLISHER - set(VERIFY_FIRST) - NOT_YET_GATED == set(), (
        "these tools publish around release.py (no gate): make them refuse and name `python -I tools/release.py "
        "--channel <dev|stable> --build <N> verify|draft|publish`")
    assert NOT_YET_GATED <= found, "NOT_YET_GATED names a file that no longer publishes: drop it from the list"
    assert "tools/publish_github.sh" not in NOT_YET_GATED


@pytest.mark.parametrize(("text", "sends"), [
    ('subprocess.run(["gh", "release", "create", tag])', True),
    ("run(['gh', 'api', path, '-X', 'POST'])", True),
    ("['git', '-C', d, 'push', url]", True),
    ("gh api repos/o/r/releases -f tag_name=b57", True),
    ("curl -X POST https://api.github.com/repos/o/r/releases", True),
    ("curl --data-binary @a.zip https://uploads.github.com/x", True),
    ("Invoke-RestMethod -Uri $u -Method Post -Body $b", True),
    ("Invoke-WebRequest $u -InFile $zip", True),
    ("gh release \\\n  create b57 a.zip", True),
    ("git -C $root `\n  push $url HEAD:refs/heads/main", True),
    ("gh api repos/o/r/releases/latest", False),
    ('["gh", "api", path]', False),
    ("curl -s https://example.invalid", False),
    ("git fetch -q $url main", False),
    ("gh repo view o/r", False),
])
def test_the_publish_detector_sees_every_form(text, sends):
    # review 6, residual (e): the list form, gh api with a field, curl / Invoke-RestMethod sends, split lines
    assert any(PUBLISHES.search(line) for line in logical_lines(text)) == sends


# Guard round 8 (the review of round 7, R4): forms the detector did not see
@pytest.mark.parametrize(("text", "sends"), [
    ('subprocess.run(\n    [\n        "gh",\n        "release",\n        "create",\n        tag,\n    ]\n)', True),
    ("run([\n    'git',\n    '-C', d,  # the public copy\n    'push', url,\n])", True),
    ("& gh @('release', 'create', $tag, $zip)", True),
    ("$a = @('release', 'create', $tag)\n& gh @a", True),
    ("requests.post(url, json=body)", True),
    ("httpx.put(url, content=data)", True),
    ("urllib.request.urlopen(urllib.request.Request(url, data=payload))", True),
    ("req = Request(url, method='PATCH')", True),
    ("conn.request('POST', '/repos/o/r/releases', body)", True),
    ("await fetch(url, { method: 'POST', body })", True),
    ("gh repo edit o/r --visibility public", True),
    ("gh repo create o/r --public", True),
    ('subprocess.run(\n    ["gh", "release", "view", tag]\n)', False),
    ("requests.get(url)", False),
    ("urllib.request.urlopen(url)", False),
    ("& gh @('release', 'view', $tag)", False),
])
def test_round8_the_publish_detector_sees_more_forms(text, sends):
    assert publishes(text) == sends


def test_round8_a_tool_without_a_suffix_is_read(tmp_path):
    tools = tmp_path / "tools"
    (tools / "sub").mkdir(parents=True)
    (tools / "publish").write_text("#!/bin/sh\ngh release create b57 a.zip\n", encoding="utf-8")
    (tools / "sub" / "push.bash").write_text("git push origin main\n", encoding="utf-8")
    (tools / "notes").write_text("nothing here sends\n", encoding="utf-8")
    assert publishing_tools(tools) == {"tools/publish", "tools/sub/push.bash"}


# any command that talks to GitHub or publishes: gh, git push / fetch / ls-remote, release.py draft / publish
NETWORK = re.compile(r"(?<![\w$-])gh\s|\bgit\b[^\n]*\s(?:push|fetch|ls-remote)\b|release\.py[^\n]*\s(?:draft|publish)\b|"
                     r"\bcurl\b|\bwget\b|Invoke-(?:RestMethod|WebRequest)")


@pytest.mark.parametrize("rel", sorted(VERIFY_FIRST))
def test_verify_first_tools_run_release_py_verify_before_any_network_command(rel):
    channel = VERIFY_FIRST[rel]
    lines = (ROOT / rel).read_text(encoding="utf-8").splitlines()
    gate = re.compile(rf'^\s*if ! python -I "\$ROOT/tools/release\.py" --channel {channel} --build "\$BUILD" verify; then$')
    at = [number for number, line in enumerate(lines) if gate.match(line)]
    assert len(at) == 1, f'{rel}: one `if ! python -I "$ROOT/tools/release.py" --channel {channel} ... verify; then`'
    assert re.match(r"^\s*(?:refuse|exit)\b", lines[at[0] + 1]), f"{rel}: a refused verify must end the run"
    early = [f"{rel}:{number + 1}: {line.strip()}" for number, line in enumerate(lines[:at[0]])
             if not line.lstrip().startswith("#") and NETWORK.search(line)]
    assert not early, "a network command before release.py verify:\n" + "\n".join(early)
    later = [line.strip() for line in lines[at[0]:] if not line.lstrip().startswith("#")]
    for command in ("draft", "publish"):
        wanted = rf'^python -I "\$ROOT/tools/release\.py" --channel {channel} --build "\$BUILD" {command}$'
        assert any(re.match(wanted, line) for line in later), f"{rel}: its release goes through release.py {command}"
    assert not [line for line in later if re.search(r"(?<![\w$-])gh\s+(?:release|api)\b", line)], \
        f"{rel}: the release itself is release.py's (no gh release / gh api of its own)"


def git_bash():
    """Git for Windows' bash (never System32's WSL launcher), or None."""
    import shutil
    found = [shutil.which("bash")]
    exec_path = subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip()
    if exec_path:
        found.append(str(Path(exec_path).parents[2] / "bin" / "bash.exe"))
    for path in found:
        if path and Path(path).is_file() and "system32" not in path.lower():
            return path
    return None


@pytest.mark.parametrize(("script", "asset"), [("publish_dev.sh", "anomaly-coop-0.57.0-dev.zip"),
                                               ("publish_dev_engine.sh", "AnomalyCoopDX11AVX.exe")])
def test_publish_dev_scripts_refuse_and_name_release_py(tmp_path, script, asset):
    text = (ROOT / "tools" / script).read_text(encoding="utf-8")
    assert "tools/release.py" in text
    assert not any(PUBLISHES.search(l) for l in text.splitlines() if not l.lstrip().startswith("#")), text
    bash = git_bash()
    if bash is None:
        pytest.skip("no Git bash here: the text checks above ran")
    # a fake gh first on PATH: it leaves a file when anything calls it
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    called = tmp_path / "gh_called"
    (fake_bin / "gh").write_text(f"#!/usr/bin/env bash\necho \"$@\" > '{called.as_posix()}'\nexit 0\n", encoding="utf-8",
                                 newline="\n")
    (tmp_path / asset).write_bytes(b"MZ a build")
    (tmp_path / "notes.md").write_text("Что нового\n", encoding="utf-8")
    env = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ.get("PATH", ""))
    done = subprocess.run([bash, str(ROOT / "tools" / script), "57.0", str(tmp_path / asset), str(tmp_path / "notes.md")],
                          capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, cwd=tmp_path,
                          timeout=60)
    assert done.returncode != 0, done.stdout + done.stderr
    assert not called.exists(), "gh was called: " + called.read_text(encoding="utf-8")
    assert "tools/release.py --channel dev --build" in done.stdout + done.stderr, done.stdout + done.stderr


# --- review 6 (round 7): the Stable publish, tools/publish_github.sh, goes through release.py -------------------------
# It used to create b<N> as Latest and push main of both public repositories with no gate at all. Now it runs
# `release.py --channel stable --build <N> verify` first (exit 2 and nothing on the network when refused) and its coop
# and engine release is release.py's own draft and publish. Run in a fake project: python, gh and git on PATH are fakes
# that write down every call; the copy of the script finds its ROOT next to itself.

FAKE_TOOL = """#!/usr/bin/env bash
echo "{name} $*" >> '{calls}'
if [ "{name}" = python ]; then
  case " $* " in *" verify "*) exit "${{FAKE_VERIFY:-0}}";; esac
fi
if [ "{name}" = git ]; then
  case " $* " in
    *" ls-remote "*) [ -n "${{FAKE_MAIN:-}}" ] && printf '%s\\trefs/heads/main\\n' "$FAKE_MAIN";;
    *" rev-parse "*) [ -n "${{FAKE_PUBLISH:-}}" ] && echo "$FAKE_PUBLISH";;
    *" merge-base "*) exit "${{FAKE_ANCESTOR:-1}}";;
  esac
fi
exit 0
"""


def publish_github(tmp_path, **env):
    """Runs a copy of tools/publish_github.sh in a fake project; (exit code, output, the calls in order)."""
    bash = git_bash()
    if bash is None:
        pytest.skip("no Git bash here")
    project = tmp_path / "proj"
    (project / "tools").mkdir(parents=True)
    shutil.copy2(ROOT / "tools" / "publish_github.sh", project / "tools" / "publish_github.sh")
    # what the old script read before it published: the protocol header, the package, the launcher's folder
    (project / "engine" / "src" / "xrCoop").mkdir(parents=True)
    (project / "engine" / "src" / "xrCoop" / "coop_protocol.h").write_text(
        "    constexpr uint32_t kProtocolVersion = 33;\n", encoding="utf-8")
    (project / "releases").mkdir()
    (project / "releases" / "anomaly-coop-0.57.0.zip").write_bytes(b"PK a build")
    (tmp_path / "raylink-launcher").mkdir(parents=True)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir(parents=True)
    calls = tmp_path / "calls.txt"
    for name in ("python", "gh", "git", "npm", "powershell.exe"):
        (fake_bin / name).write_text(FAKE_TOOL.format(name=name, calls=calls.as_posix()), encoding="utf-8",
                                     newline="\n")
    run_env = {k: v for k, v in os.environ.items() if k not in ("BUILD", "OWNER", "VISIBILITY", "SKIP_LAUNCHER")}
    # 2026-11-20: Git Bash puts its own /mingw64/bin and /usr/bin in front of a PATH it gets from Windows, so the fakes
    # lost to the real git and gh; tmp_path lies inside this repository, so the real git fetched into its .git. Now the
    # fakes go first INSIDE bash, the script runs only after bash proves git, gh and python are the fakes (exit 97 =
    # refused, the test fails), and every real tool is cut off from the network and from this repository anyway.
    posix_bin = fake_bin.as_posix()
    if re.match(r"^[A-Za-z]:/", posix_bin):
        posix_bin = "/" + posix_bin[0].lower() + posix_bin[2:]
    script = (project / "tools" / "publish_github.sh").as_posix()
    if re.match(r"^[A-Za-z]:/", script):
        script = "/" + script[0].lower() + script[2:]
    (tmp_path / "ghcfg").mkdir(exist_ok=True)
    run_env.update(PATH=str(fake_bin) + os.pathsep + os.environ.get("PATH", ""), SKIP_LAUNCHER="1",
                   GIT_ALLOW_PROTOCOL="file", GIT_CEILING_DIRECTORIES=str(tmp_path), GIT_TERMINAL_PROMPT="0",
                   GH_HOST="github.invalid", GH_TOKEN="invalid", GITHUB_TOKEN="invalid",
                   GH_CONFIG_DIR=str(tmp_path / "ghcfg"), **env)
    guard = (f'export PATH="{posix_bin}:$PATH"; hash -r; '
             f'for t in git gh python; do case "$(command -v "$t")" in "{posix_bin}/"*) ;; '
             f'*) echo "FAKE-NOT-FIRST $t $(command -v "$t")"; exit 97;; esac; done; exec bash "$1"')
    done = subprocess.run([bash, "-c", guard, "guard", script], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", env=run_env, cwd=tmp_path, timeout=120)
    if done.returncode == 97:
        pytest.fail("the fake git/gh/python are not first on PATH inside bash: refused to run the publish script\n"
                    + done.stdout + done.stderr)
    lines = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
    return done.returncode, done.stdout + done.stderr, lines


def release_calls(lines):
    """The release.py commands among the calls, as (channel, build, command)."""
    out = []
    for line in lines:
        m = re.match(r'^python -I .*tools/release\.py --channel (\w+) --build (\S+) (\w+)$', line)
        if m:
            out.append(m.groups())
        elif line.startswith("python "):
            out.append(("?", "?", line))
    return out


def test_publish_github_refuses_when_release_py_verify_refuses(tmp_path):
    code, out, calls = publish_github(tmp_path, BUILD="57", FAKE_VERIFY="1")
    assert code == 2, out
    assert release_calls(calls) == [("stable", "57", "verify")], calls
    assert calls == [c for c in calls if c.startswith("python ")], f"ran something besides verify: {calls}"
    assert "Nothing was published" in out and "release.py --channel stable --build 57 prepare" in out, out


def test_publish_github_publishes_only_through_release_py_after_verify(tmp_path):
    code, out, calls = publish_github(tmp_path, BUILD="57")
    assert code == 0, out
    assert release_calls(calls) == [("stable", "57", "verify"), ("stable", "57", "draft"), ("stable", "57", "publish")]
    assert calls[0].startswith("python "), calls  # the gate before anything else
    assert not [c for c in calls if re.match(r"^gh (?:release|api)\b", c) or re.match(r"^git\b.*\bpush\b", c)], calls


def test_publish_github_refuses_a_public_engine_main_made_elsewhere(tmp_path):
    # the snapshot of engine\ goes on top of the public main: a commit made on GitHub would be undone by it
    code, out, calls = publish_github(tmp_path, BUILD="57", FAKE_MAIN="a" * 40, FAKE_PUBLISH="b" * 40)
    assert code == 4, out
    assert release_calls(calls) == [("stable", "57", "verify")], calls
    assert "Nothing was published" in out, out
    code, out, calls = publish_github(tmp_path / "again", BUILD="57", FAKE_MAIN="a" * 40, FAKE_PUBLISH="a" * 40)
    assert code == 0 and [c for _, _, c in release_calls(calls)] == ["verify", "draft", "publish"], out + str(calls)
    code, out, calls = publish_github(tmp_path / "ancestor", BUILD="57", FAKE_MAIN="a" * 40, FAKE_ANCESTOR="0")
    assert code == 0 and [c for _, _, c in release_calls(calls)] == ["verify", "draft", "publish"], out + str(calls)


@pytest.mark.parametrize("env", [{}, {"BUILD": "57.1"}, {"BUILD": "57; echo x"}, {"BUILD": "b57"},
                                 {"BUILD": "57", "OWNER": "somebody"}, {"BUILD": "57", "VISIBILITY": "internal"}],
                         ids=["no-build", "point-build", "injection", "tag", "owner", "visibility"])
def test_publish_github_refuses_bad_input_before_anything_runs(tmp_path, env):
    code, out, calls = publish_github(tmp_path, **env)
    assert code == 2 and calls == [], out + str(calls)
    assert "Nothing was published" in out, out


def test_round8_publish_github_says_why_a_point_build_is_no_stable_build(tmp_path):
    # the review of round 7, R5: the refusal of BUILD=57.1 pointed only to Dev. release.py itself refuses a Stable
    # point build (names_for: "a Stable build is a whole number"), so the script says that rule and the Dev command
    with pytest.raises(release.Refused, match="whole number"):
        release.names_for("stable", "57.1")
    assert release.names_for("dev", "57.1").tag == "dev-57.1"
    code, out, calls = publish_github(tmp_path, BUILD="57.1")
    assert code == 2 and calls == [], out + str(calls)
    assert "whole number" in out and "release.py --channel dev --build 57.1" in out, out
