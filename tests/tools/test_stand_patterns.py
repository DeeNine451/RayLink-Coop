"""Exercise the stand's log classifier in Windows PowerShell without starting a stand."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell")
pytestmark = pytest.mark.skipif(POWERSHELL is None, reason="Windows PowerShell required")

GAMMA_REPORTS = (
    r"! [19:10:45.210]  [SCRIPT ERROR]: .../gamma/game-dev\gamedata\scripts\a_faction_prices.script:16: attempt to index global 'faction_stocks' (a nil value)",
    r"! [19:10:50.834]  [SCRIPT ERROR]: ...ames/gamma/game-dev\gamedata\scripts\mags_patches.script:4: attempt to index global 'magazine_binder' (a nil value)",
    r"! [19:10:53.410]  [SCRIPT ERROR]: ...amedata\scripts\zz_ui_inventory_better_stats_bars.script:41: attempt to index global 'better_stats_bars_mcm' (a nil value)",
    r"! [19:10:53.418]  [SCRIPT ERROR]: ...e-dev\gamedata\scripts\zzz_mspizza_godis_zoomcalc.script:113: unexpected symbol near '/'",
)

CASES = (
    ("fatal", "FATAL ERROR", True),
    (
        "G1-exception",
        "! [19:24:55.654]  crash: exception 0xC0000005 at AnomalyCoopDX11AVX.exe+0x14674F",
        True,
    ),
    (
        "G1-access-violation",
        "! [19:24:55.654]  crash: access violation: read of the address 0x0000000000000027",
        True,
    ),
    ("G2-engine-timestamp", "! [19:33:45.038]  [coop] coop.send_event refused: not in a co-op world", True),
    ("G2-lua-timestamp", "! [19:35:48.146] [coop] unexpected failure", True),
    ("G2-server", "! [coop] unexpected failure", True),
    ("G3-missions", "[coop-quests][missions] ! prepare guide: _g.script:2062: attempt to compare number with function", True),
    ("G3-tasks", "[coop-tasks] ! request give: attempt to index a nil value", True),
    ("G3-settings", "[coop-game] ! on_option_change after the late switch-on: attempt to index a nil value", True),
    ("G3-route", "[coop-route] ! lua error in callback: attempt to call a nil value", True),
    ("G3-phantom", "[coop-npc:compat] ! native phantom_xcv_fix (#1): cannot resolve private XCV spawn settings", True),
    ("G4-lua-error", "! [19:35:48.146]  LUA error: attempt to call a nil value", True),
    ("G4-survived", "[coop] lua errors: coop_lua_errors 1 (survive, in a session now), survived 0 at 0 place(s)", False),
    ("G4-plain-counter", "lua errors 0", False),
    ("G4-plain-caught", "lua errors caught 0", False),
    ("G4-counter", "[coop-lua] lua errors 0, missing handlers 0, chat lines shown 0 | queued: out 0, in 0, chat 0", False),
    ("G4-caught", "[coop-route] routed in place 20, not routed 0, lua errors caught 0", False),
    ("G5-lua-traceback", "stack traceback:", True),
    ("G5-coop-frame", "\t... coop_tasks.script (line: 81) in function 'give_task'", True),
    ("G5-route-frame", "\t... coop_route.script (line: 81) in function 'wrap'", False),
    ("G5-probe-frame", "\t... coop_zz_probe.script (line: 81) in function 'probe'", False),
    ("G5-stack-fdda", "~ [19:24:03.039]  STACK TRACEBACK:", False),
    ("G5-frame-fdda", "\t... liz_fdda_redone_consumables_ssfx_dof.script (line: 44) in function 'on_game_start'", False),
    ("G5-stack-mosin", "~ [19:24:03.170]  STACK TRACEBACK:", False),
    ("G5-frame-mosin", "\t... mosin_carbine_reload_script.script (line: 178) in function 'on_game_start'", False),
    ("G5-stack-dotmarks", "~ [19:24:03.199]  STACK TRACEBACK:", False),
    ("G5-frame-dotmarks", "\t... ui_hud_dotmarks.script (line: 6536) in function 'on_game_start'", False),
    ("G5-stack-alq", "~ [19:24:51.723]  STACK TRACEBACK:", False),
    ("G5-frame-alq", "\t... alq_core.script (line: 445) in function 'is_eligible'", False),
    # The sim_board block occurs in b57_carry_host.log.
    ("G5-stack-sim-board", "~ [19:11:38.053]  STACK TRACEBACK:", False),
    ("G5-frame-sim-board", "\t... sim_board.script (line: 139) in function 'smr_handle_spawn'", False),
    ("G5-alq-id", "! [19:24:51.723] ALIFE OBJECT ID IS 65535!", False),
    ("G5-missing-callback", "! [19:24:03.039] [axr_main callback_set] callback on_fddar_consumable_anim_start doesn't exist!", False),
    ("G6-runtime", "! [LUA] SCRIPT RUNTIME ERROR", True),
    ("G6-syntax", "! [19:10:53.418]  [LUA] SCRIPT SYNTAX ERROR", True),
    ("G6-report", "! [SCRIPT ERROR]: coop_game_settings.script:41: attempt to index a nil value", True),
    ("G6-other-line", GAMMA_REPORTS[0].replace(":16:", ":160:"), True),
    *((f"G6-gamma-{n}", report, False) for n, report in enumerate(GAMMA_REPORTS, 1)),
    ("rejected-level-exit", "! [coop] 'guest' asks to leave through level exit 42 from 10.0 m away: ignored", False),
    ("low-memory", "! [coop] map servers: this PC has 200 MB of 1000 MB physical memory free (under 500 MB): an empty map server does not linger, it stops at once", False),
    ("precache-timeout", "! [03:39:41.383]  [coop] the host's level is still precaching after 20 s (window without focus?): joins go on", False),
    ("host-wait", "! [12:41:22.293]  [coop] the host does not answer (2014 ms): the game waits for it, out after 30 s", False),
    ("settings-fallback", "[03:35:57.303] [coop-game] ! the record was not read at the world start: switched on late, scripts that cached an option keep the machine's", False),
)


def run_powershell(command: str, lines: tuple[str, ...] = ()) -> list[str]:
    result = subprocess.run(
        [
            POWERSHELL, "-NoProfile", "-Command",
            "$ErrorActionPreference = 'Stop'; . .\\tools\\stand_common.ps1; " + command,
        ],
        input=json.dumps(lines),
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.splitlines()


@pytest.fixture(scope="module")
def classifications() -> dict[str, bool]:
    output = run_powershell(
        "foreach ($line in (ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()))) { "
        "Test-StandErrorLine $line }",
        tuple(line for _, line, _ in CASES),
    )
    assert len(output) == len(CASES) and set(output) <= {"True", "False"}, output
    return {case[0]: matched == "True" for case, matched in zip(CASES, output, strict=True)}


@pytest.mark.parametrize(("name", "line", "expected"), CASES, ids=[case[0] for case in CASES])
def test_stand_error_line(classifications: dict[str, bool], name: str, line: str, expected: bool):
    assert classifications[name] is expected, line


@pytest.mark.parametrize("timestamped", [True, False], ids=["coop-host", "world-server"])
def test_stand_log_classifies_debug_blocks_and_keeps_scenario_mark(tmp_path: Path, timestamped: bool):
    log = tmp_path / "game.log"
    report = GAMMA_REPORTS[0]
    frame = "! [19:10:45.210]  [LUA]  0 : [C  ] __index"
    header = "! [19:10:45.210]  [LUA] SCRIPT RUNTIME ERROR"
    truncated = "! [19:10:53.418]  [LUA] SCRIPT SYNTAX ERROR"
    real_report = report.replace("a_faction_prices", "coop_tasks")
    unrelated_header = header.replace("19:10:45.210", "19:10:45.211")
    mismatched_header = header.replace("19:10:45.210", "19:10:45.212")
    detail = report.replace("[SCRIPT ERROR]:", "[LUA]")
    syntax_report = GAMMA_REPORTS[3]
    marker = "[cmp-srv] FAIL: NPC not here"
    expected = [unrelated_header, mismatched_header, header, real_report, marker, truncated]
    lines = [
        header, *([frame] * 3), detail, *([frame] * 3), report,
        truncated, frame, syntax_report.replace("[SCRIPT ERROR]:", "[LUA]"), syntax_report,
        unrelated_header, frame, report,
        mismatched_header, frame, detail, GAMMA_REPORTS[1],
        header, frame, real_report, marker, truncated,
    ]
    if not timestamped:
        stamp = re.compile(r"\[\d{2}:\d{2}:\d{2}\.\d{3}\] +")
        lines = [stamp.sub("", line) for line in lines]
        expected = [stamp.sub("", line) for line in expected]
    log.write_text("\n".join(lines), encoding="ascii")
    path = str(log).replace("'", "''")
    command = rf"Select-StandLogLine '{path}' '\[cmp-srv\] FAIL\b|attempt to '"
    output = run_powershell(command + " | ForEach-Object Line")
    assert output == expected
    assert run_powershell(command + " -Last 1 | ForEach-Object Line") == expected[:-2] + expected[-1:]
