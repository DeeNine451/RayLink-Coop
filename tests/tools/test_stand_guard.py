"""The stand's guard: which running game counts as one outside the stand (tools\\stand_common.ps1 Get-StandForeignGame).

The owner's game must stop a stand run at once. A stand game that is closing has no readable path for a moment: the b57
Server stand (2026-11-21) had four scenarios stopped with "GUARD: a game outside the stand started" and no foreign game
on the machine. A game whose path cannot be read is foreign only while it still runs and the system names no path under
the stand for it; whatever cannot be decided counts as foreign (the owner's game first).
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell")
pytestmark = pytest.mark.skipif(POWERSHELL is None, reason="Windows PowerShell required")
STAND = r"E:\RayLinkGames\GAMMA\game-dev"

# name, game (Id, Path, HasExited or "throw"), the system's path for it, still alive by id, expected foreign
CASES = (
    ("stand-bin", {"Id": 1, "Path": STAND + r"\bin\AnomalyCoopDX11AVX.exe", "HasExited": False}, None, True, False),
    ("stand-run-dir", {"Id": 2, "Path": STAND + r"\zz_s7_ab\bin\AnomalyCoopDX11AVX.exe", "HasExited": False}, None, True, False),
    ("owner-game", {"Id": 3, "Path": r"E:\RayLinkGames\GAMMA\game\bin\AnomalyCoopDX11AVX.exe", "HasExited": False}, None, True, True),
    ("prefix-not-folder", {"Id": 4, "Path": STAND + r"-old\bin\AnomalyCoopDX11AVX.exe", "HasExited": False}, None, True, True),
    ("closing-no-path", {"Id": 5, "Path": None, "HasExited": True}, None, False, False),
    ("no-path-system-names-stand", {"Id": 6, "Path": None, "HasExited": False}, STAND + r"\bin_b\AnomalyCoopDX11AVX.exe", True, False),
    ("no-path-system-names-other", {"Id": 7, "Path": None, "HasExited": False}, r"E:\Other\AnomalyDX11.exe", True, True),
    ("no-path-gone-meanwhile", {"Id": 8, "Path": None, "HasExited": False}, None, False, False),
    ("no-path-unreadable-alive", {"Id": 9, "Path": None, "HasExited": False}, None, True, True),
    ("access-denied-alive", {"Id": 10, "Path": None, "HasExited": "throw"}, None, True, True),
)


def classify(case) -> bool:
    _, game, system_path, alive, _ = case
    script = (
        "$ErrorActionPreference = 'Stop'; . .\\tools\\stand_common.ps1; "
        "$c = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()); "
        "$g = New-Object PSObject -Property @{ Id = $c.game.Id; Path = $c.game.Path }; "
        "if ($c.game.HasExited -eq 'throw') { $g | Add-Member ScriptProperty HasExited { throw 'Access is denied' } } "
        "else { $g | Add-Member NoteProperty HasExited ([bool]$c.game.HasExited) }; "
        "$found = @(Get-StandForeignGame -Games @($g) -Stand $c.stand "
        "-PathOf { param($id) $c.system } -IsAlive { param($id) [bool]$c.alive }); "
        "Write-Output ($found.Count -eq 1)"
    )
    done = subprocess.run([POWERSHELL, "-NoProfile", "-Command", script], cwd=ROOT, text=True, capture_output=True,
                          input=json.dumps({"game": game, "system": system_path, "alive": alive, "stand": STAND}),
                          timeout=60, check=False)
    assert done.returncode == 0, done.stderr
    return done.stdout.strip().splitlines()[-1] == "True"


@pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
def test_foreign_game(case):
    assert classify(case) is case[4]


def test_run_guarded_names_the_game_it_stopped_for():
    text = (ROOT / "tools" / "stand" / "run_guarded.ps1").read_text(encoding="utf-8")
    assert "Get-StandForeignGame" in text
    assert "GUARD: a game outside the stand started" in text and "$($foreign" in text
