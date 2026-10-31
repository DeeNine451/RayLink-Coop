"""tools/parity_diff.py: two coop_parity dumps are compared row by row (gamedata\\scripts\\coop_parity.script writes them)."""
import subprocess
import sys

import pytest

from conftest import ROOT

import parity_diff

TOOL = ROOT / "tools" / "parity_diff.py"


def meta(role, tag="t1"):
    return {"format": ["1"], "host_game_s": ["1000"], "level": ["l01_escape"], "role": [role], "tag": [tag]}


def world():
    return {
        "objects": {"00000": ["@player", "65535", "1", "1", "1"], "00700": ["stalker_a", "65535", "1", "1", "1"]},
        "positions": {"00000": ["1.00", "2.00", "3.00", "1"], "00900": ["9.00", "9.00", "9.00", "0"]},
        "health": {"00700": ["0.73"]},
        "inventories": {"00700": ["00800:wpn_ak74:0.95:30:0", "00801:bandage:1.00:-:2"]},
        "money": {"0": ["1000"], "1": ["2500"]},
        "time": {"factor": ["12.50"], "game_s": ["63504000000"], "pause": ["0"]},
        "infos": {"story_a": ["1"]},
    }


def text(sections, role):
    out = []
    for kind, rows in {"meta": meta(role) if "meta" not in sections else {}, **sections}.items():
        lines = sorted("\t".join([kind, key, *fields]) for key, fields in rows.items())
        out += lines
        out.append("\t".join([kind, "DIGEST", parity_diff.digest(l.encode("latin-1") for l in lines), str(len(lines))]))
    return "\n".join(out) + "\n"


@pytest.fixture
def run(work, capsys):
    def go(host, client, *args):
        a, b = work / "host.tsv", work / "client.tsv"
        a.write_bytes(host.encode("latin-1") if isinstance(host, str) else host)
        b.write_bytes(client.encode("latin-1") if isinstance(client, str) else client)
        code = parity_diff.main([str(a), str(b), *args])
        return code, capsys.readouterr().out

    return go


def pair(change=None):
    client = world()
    if change:
        change(client)
    return text(world(), "host"), text(client, "client")


def test_fnv_vectors():
    assert parity_diff.fnv1a(b"") == 0x811C9DC5
    assert parity_diff.fnv1a(b"a") == 0xE40C292C
    assert parity_diff.fnv1a(b"foobar") == 0xBF9CF968


def test_digest_is_the_scripts_digest():
    """The same value is pinned in tests\\lua\\test_parity.lua."""
    assert parity_diff.digest([b"objects\t00001\tx"]) == "eb67192a"


def test_equal_files_exit_zero(run):
    code, out = run(*pair())
    assert code == 0
    assert "objects" in out and "positions" in out


def test_missing_row(run):
    code, out = run(*pair(lambda w: w["objects"].pop("00700")))
    assert code == 1
    assert "missing" in out and "00700" in out


def test_extra_row(run):
    code, out = run(*pair(lambda w: w["infos"].update({"story_b": ["1"]})))
    assert code == 1
    assert "extra" in out and "story_b" in out


def test_differing_row_names_the_column(run):
    def change(w):
        w["objects"]["00700"][2] = "0"

    code, out = run(*pair(change))
    assert code == 1
    assert "00700" in out and "online 1/0" in out


def test_each_section_counts(run):
    def change(w):
        w["objects"]["00700"][2] = "0"
        w["infos"].pop("story_a")
        w["infos"]["story_b"] = ["1"]

    assert run(*pair(change))[0] == 3


def test_inventory_shows_the_items_that_differ(run):
    def change(w):
        w["inventories"]["00700"] = ["00800:wpn_ak74:0.95:29:0", "00801:bandage:1.00:-:2"]

    code, out = run(*pair(change))
    assert code == 1
    assert "00800:wpn_ak74:0.95:30:0" in out and "00800:wpn_ak74:0.95:29:0" in out
    assert "bandage" not in out


def test_position_within_tolerance(run):
    def change(w):
        w["positions"]["00000"] = ["1.00", "2.00", "4.40", "1"]

    code, out = run(*pair(change))
    assert code == 0
    assert "1 within" in out


def test_position_beyond_tolerance(run):
    def change(w):
        w["positions"]["00000"] = ["1.00", "2.00", "4.60", "1"]

    code, out = run(*pair(change))
    assert code == 1
    assert "00000" in out and "1.60 m" in out


def test_tolerance_option(run):
    def change(w):
        w["positions"]["00000"] = ["1.00", "2.00", "4.60", "1"]

    assert run(*pair(change), "--tolerance", "2")[0] == 0


def test_offline_on_both_sides_is_drift_not_a_mismatch(run):
    def change(w):
        w["positions"]["00900"] = ["50.00", "9.00", "9.00", "0"]

    code, out = run(*pair(change))
    assert code == 0
    assert "1 offline" in out
    assert run(*pair(change), "--count-offline")[0] == 1


def test_online_on_one_side_counts_as_a_move(run):
    def change(w):
        w["positions"]["00900"] = ["50.00", "9.00", "9.00", "1"]

    assert run(*pair(change))[0] == 1


def test_health_tolerance(run):
    def small(w):
        w["health"]["00700"] = ["0.74"]

    def big(w):
        w["health"]["00700"] = ["0.50"]

    assert run(*pair(small))[0] == 0
    assert run(*pair(big))[0] == 1


def test_time_tolerance_and_exact_rows(run):
    def near(w):
        w["time"]["game_s"] = ["63504000020"]

    def far(w):
        w["time"]["game_s"] = ["63504000100"]

    def factor(w):
        w["time"]["factor"] = ["10.00"]

    assert run(*pair(near))[0] == 0
    assert run(*pair(far))[0] == 1
    assert run(*pair(factor))[0] == 1


def test_a_client_knows_only_its_own_money(run):
    code, _ = run(*pair(lambda w: w["money"].pop("0")))
    assert code == 0


def test_money_differs(run):
    def change(w):
        w["money"]["1"] = ["2400"]

    code, out = run(*pair(change))
    assert code == 1
    assert "2500/2400" in out


def test_meta_is_never_compared(run):
    code, _ = run(*pair(lambda w: w.update({"meta": {**meta("client"), "level": ["other"]}})))
    assert code == 0


def test_digest_mismatch(run):
    host, client = pair()
    lines = client.splitlines()
    i = next(n for n, line in enumerate(lines) if line.startswith("objects\tDIGEST"))
    lines[i] = "objects\tDIGEST\t00000000\t2"
    code, out = run(host, "\n".join(lines) + "\n")
    assert code == 1
    assert "digest" in out and "client" in out


def test_digest_of_a_tolerated_section_may_differ(run):
    def change(w):
        w["positions"]["00000"] = ["1.10", "2.00", "3.00", "1"]

    code, out = run(*pair(change))
    assert code == 0
    assert "!=" in out


def test_no_digest_row_means_the_dump_was_cut(run):
    host, client = pair()
    lines = [line for line in client.splitlines() if not line.startswith("infos\tDIGEST")]
    code, out = run(host, "\n".join(lines) + "\n")
    assert code == 1
    assert "no DIGEST" in out


def test_error_row_counts(run):
    code, out = run(*pair(lambda w: w["infos"].update({"!error1": ["no simulator"]})))
    assert code == 1
    assert "no simulator" in out


def test_error_rows_on_both_sides_prove_nothing(run):
    both = world()
    both["infos"]["!error1"] = ["no simulator"]
    code, _ = run(text(both, "host"), text(both, "client"))
    assert code == 2


def test_missing_section(run):
    code, out = run(*pair(lambda w: w.pop("objects")))
    assert code == 1
    assert "objects" in out and "client" in out


def test_different_tags_are_not_a_pair(run):
    client = text({**world(), "meta": meta("client", "t2")}, "client")
    code, out = run(text(world(), "host"), client)
    assert code == 1
    assert "t1" in out and "t2" in out


def test_section_filter(run):
    def change(w):
        w["objects"]["00700"][2] = "0"
        w["infos"]["story_b"] = ["1"]

    host, client = pair(change)
    code, out = run(host, client, "--section", "infos")
    assert code == 1
    assert "story_b" in out and "stalker" not in out and "objects" not in out
    assert run(host, client, "--section", "health")[0] == 0
    assert run(host, client, "--section", "infos", "--section", "objects")[0] == 2


def test_exit_code_is_capped(run):
    def change(w):
        w["infos"].update({f"story_{n}": ["1"] for n in range(300)})

    code, out = run(*pair(change))
    assert code == 255
    assert "more" in out  # the listing stays short


def test_limit(run):
    def change(w):
        w["infos"].update({f"story_{n}": ["1"] for n in range(9)})

    _, out = run(*pair(change), "--limit", "2")
    assert out.count("extra") == 2 and "7 more" in out


def test_section_name_bytes_survive(run):
    def change(w):
        w["objects"]["00700"][0] = "stalker\xe0"

    assert run(*pair(change))[0] == 1
    client = world()
    client["objects"]["00700"][0] = "stalker\xe0"
    assert run(text(client, "host"), text(client, "client"))[0] == 0


def test_unreadable_file(work, capsys):
    code = parity_diff.main([str(work / "nope.tsv"), str(work / "nope2.tsv")])
    assert code == 255
    assert "nope.tsv" in capsys.readouterr().out


def test_runs_isolated_on_the_standard_library(work):
    host, client = pair()
    a, b = work / "host.tsv", work / "client.tsv"
    a.write_bytes(host.encode("latin-1"))
    b.write_bytes(client.encode("latin-1"))
    done = subprocess.run([sys.executable, "-I", str(TOOL), str(a), str(b)], capture_output=True, text=True)
    assert done.returncode == 0, done.stdout + done.stderr
    client2 = client.replace("story_a", "story_z")
    b.write_bytes(client2.encode("latin-1"))
    done = subprocess.run([sys.executable, "-I", str(TOOL), str(a), str(b)], capture_output=True, text=True)
    assert done.returncode == 3, done.stdout + done.stderr  # missing + extra + the file's digest
