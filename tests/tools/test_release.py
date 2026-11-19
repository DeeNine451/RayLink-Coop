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

PUBLISHES = re.compile(r"\bgh\s+release\s+(?:create|edit|upload|delete)\b|\bgh\s+api\b[^\n]*(?:-X|--method)\s*(?:POST|PATCH|"
                       r"PUT|DELETE)\b|\bgit\b[^\n]*\bpush\b", re.I)
TEXT_SUFFIXES = {".sh", ".ps1", ".py", ".cmd", ".bat", ".js", ".mjs", ".lua"}
GATED_PUBLISHER = {"tools/release.py"}
# Not the layer guard's file (the lead's): it publishes b<N> and pushes main of both public repositories with no gate.
# The lead removes it or turns it into a refusal like publish_dev.sh; then this entry goes (the test fails while stale).
NOT_YET_GATED = {"tools/publish_github.sh"}


def publishing_tools() -> set[str]:
    found = set()
    for path in sorted((ROOT / "tools").rglob("*")):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES or "__pycache__" in path.parts:
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            code = line.lstrip()
            if code.startswith(("#", "rem ", "REM ", "::", "--")):
                continue
            if PUBLISHES.search(code):
                found.add(path.relative_to(ROOT).as_posix())
                break
    return found


def test_only_release_py_publishes():
    found = publishing_tools()
    assert found - GATED_PUBLISHER - NOT_YET_GATED == set(), (
        "these tools publish around release.py (no gate): make them refuse and name `python -I tools/release.py "
        "--channel <dev|stable> --build <N> verify|draft|publish`")
    assert NOT_YET_GATED <= found, "NOT_YET_GATED names a file that no longer publishes: drop it from the list"


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
