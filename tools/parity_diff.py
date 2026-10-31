"""Compares two parity dumps of one moment: tools/parity_diff.py host.tsv client.tsv

The console command coop_parity (gamedata\\scripts\\coop_parity.script, whose header describes the rows) makes the host and
every client write one file. Rows are joined by key per section. Exit code: the number of mismatches, capped at 255 (an
unreadable file is 255 too), so 0 means this client saw what the host saw.

A mismatch is: a row one side lacks, a row that differs, an error row (a failed read proves nothing, on either side), a
digest that does not match its own rows or is not there (a dump that was cut short), a section one file lacks, two files
of different tags.
Compared with a tolerance, their digests are only shown: positions (--tolerance metres; offline on both sides is the host's
ALife moving what a client's frozen copy does not, audit D17: shown, counted only with --count-offline), health, time.game_s
(--time-tolerance game seconds). money: a client knows only its own, so the keys both have. meta is not compared.
Run with python -I, standard library only.
"""
import argparse
import math
import sys
from pathlib import Path

FNV_OFFSET = 0x811C9DC5
FNV_PRIME = 16777619

POSITION_TOLERANCE_M = 1.5
TIME_TOLERANCE_S = 30.0  # game seconds: one second of a TimeSync period at a time factor of 30
HEALTH_TOLERANCE = 0.05  # a snapshot carries health in a byte, and the two dumps are a latency apart
LIST_LIMIT = 12

NOT_COMPARED = {"meta"}
SHARED_KEYS_ONLY = {"money"}
TOLERATED = {"positions", "health", "time"}
COLUMNS = {
    "objects": ("section", "parent", "online", "live", "alive"),
}


def fnv1a(data: bytes, h: int = FNV_OFFSET) -> int:
    for byte in data:
        h = ((h ^ byte) * FNV_PRIME) & 0xFFFFFFFF
    return h


def digest(rows) -> str:
    """FNV-1a 32 over rows (bytes, in the file's order, which is sorted), each with its newline."""
    h = FNV_OFFSET
    for row in rows:
        h = fnv1a(row + b"\n", h)
    return f"{h:08x}"


class Section:
    def __init__(self):
        self.rows: dict[str, list[str]] = {}
        self.errors: list[str] = []
        self.raw: list[bytes] = []
        self.digest: str | None = None

    def problems(self, side: str) -> list[str]:
        out = [f"{side}: {text}" for text in self.errors]
        if self.digest is None:
            out.append(f"{side}: no DIGEST row, the dump was cut short")
        elif self.digest != digest(self.raw):
            out.append(f"{side}: digest {self.digest} is not the digest of its rows ({digest(self.raw)})")
        return out


def load(path: Path) -> dict[str, Section]:
    sections: dict[str, Section] = {}
    for line in path.read_bytes().split(b"\n"):
        if not line:
            continue
        kind, _, rest = line.decode("latin-1").partition("\t")
        key, *fields = rest.split("\t")
        sec = sections.setdefault(kind, Section())
        if key == "DIGEST":
            sec.digest = fields[0] if fields else ""
            continue
        sec.raw.append(line)
        if key.startswith("!error"):
            sec.errors.append(" ".join([key, *fields]))
        else:
            sec.rows[key] = fields
    return sections


def describe(section: str, a: list[str], b: list[str]) -> str:
    """The columns that differ, or the fields only one side has (an inventory)."""
    columns = COLUMNS.get(section)
    if columns and len(a) == len(columns) and len(b) == len(columns):
        return ", ".join(f"{name} {x}/{y}" for name, x, y in zip(columns, a, b) if x != y)
    if len(a) == 1 and len(b) == 1:
        return f"{a[0]}/{b[0]}"
    only_a = [f for f in a if f not in b]
    only_b = [f for f in b if f not in a]
    return f"host {' '.join(only_a) or '-'} | client {' '.join(only_b) or '-'}"


def distance(a: list[str], b: list[str]) -> float:
    return math.dist(map(float, a[:3]), map(float, b[:3]))


class Result:
    def __init__(self):
        self.lines: list[str] = []
        self.mismatches = 0
        self.notes: list[str] = []

    def add(self, line: str):
        self.lines.append(line)
        self.mismatches += 1


def compare_rows(section: str, host: Section, client: Section, opts: argparse.Namespace, out: Result):
    shared_only = section in SHARED_KEYS_ONLY
    within = offline = 0
    for key in sorted(host.rows.keys() | client.rows.keys()):
        a, b = host.rows.get(key), client.rows.get(key)
        if a is None or b is None:
            if not shared_only:
                out.add(f"{'extra  ' if a is None else 'missing'} {key} {' '.join(a or b)}")
        elif a == b:
            continue
        elif section == "positions":
            gap = distance(a, b)
            if gap <= opts.tolerance:
                within += 1
            elif a[3] == "0" and b[3] == "0" and not opts.count_offline:
                offline += 1
            else:
                out.add(f"moved   {key} {gap:.2f} m, host {' '.join(a)} | client {' '.join(b)}")
        elif section == "health" and abs(float(a[0]) - float(b[0])) <= HEALTH_TOLERANCE:
            within += 1
        elif section == "time" and key == "game_s" and abs(float(a[0]) - float(b[0])) <= opts.time_tolerance:
            within += 1
        else:
            out.add(f"differ  {key} {describe(section, a, b)}")
    if within:
        out.notes.append(f"{within} within tolerance")
    if offline:
        out.notes.append(f"{offline} offline moved, not counted")


def compare_section(section: str, host: Section | None, client: Section | None, opts: argparse.Namespace) -> Result:
    out = Result()
    if host is None or client is None:
        out.add(f"section missing in {'host' if host is None else 'client'}")
        return out
    for problem in host.problems("host") + client.problems("client"):
        out.add(problem)
    compare_rows(section, host, client, opts, out)
    return out


def header(host: dict[str, Section], client: dict[str, Section]) -> tuple[list[str], int]:
    a = host["meta"].rows if "meta" in host else {}
    b = client["meta"].rows if "meta" in client else {}

    def pair(key: str) -> tuple[str, str]:
        return " ".join(a.get(key, ["?"])), " ".join(b.get(key, ["?"]))

    tags, roles, levels = pair("tag"), pair("role"), pair("level")
    lines = [f"tag {tags[0]} | {roles[0]} peer {pair('peer')[0]} / {roles[1]} peer {pair('peer')[1]} | level {levels[0]} / {levels[1]}"]
    if tags[0] != tags[1]:
        lines.append(f"! different tags: {tags[0]} / {tags[1]}, these files are not one moment")
        return lines, 1
    return lines, 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compare two coop_parity dumps; exit code = mismatches, capped at 255.")
    parser.add_argument("host", type=Path)
    parser.add_argument("client", type=Path)
    parser.add_argument("--section", action="append", help="only this section (repeatable)")
    parser.add_argument("--tolerance", type=float, default=POSITION_TOLERANCE_M, help="metres, default %(default)s")
    parser.add_argument("--time-tolerance", type=float, default=TIME_TOLERANCE_S, help="game seconds, default %(default)s")
    parser.add_argument("--count-offline", action="store_true", help="count an entity offline on both sides that moved")
    parser.add_argument("--limit", type=int, default=LIST_LIMIT, help="rows listed per section, default %(default)s")
    opts = parser.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")

    try:
        host, client = load(opts.host), load(opts.client)
    except OSError as e:
        print(f"cannot read: {e}")
        return 255

    lines, total = header(host, client)
    print("\n".join(lines))
    names = list(host) + [name for name in client if name not in host]
    for name in opts.section or [name for name in names if name not in NOT_COMPARED]:
        a, b = host.get(name), client.get(name)
        result = compare_section(name, a, b, opts)
        total += result.mismatches
        rows_a, rows_b = len(a.rows) if a else 0, len(b.rows) if b else 0
        da, db = a.digest if a else None, b.digest if b else None
        same = "=" if da == db else "!="
        state = f"{result.mismatches} MISMATCH" if result.mismatches else "ok"
        notes = "".join(f", {note}" for note in result.notes)
        print(f"{name:<12} {rows_a:>6}/{rows_b:<6} digest {da} {same} {db}  {state}{notes}")
        for line in result.lines[: opts.limit]:
            print(f"  {line}")
        hidden = len(result.lines) - opts.limit
        if hidden > 0:
            print(f"  ... {hidden} more")
    return min(total, 255)


if __name__ == "__main__":
    sys.exit(main())
