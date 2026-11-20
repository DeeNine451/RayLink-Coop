# The co-op stand (SC of docs/MODES.md section 10): HEAD's gamedata deployed first (tools\stand\stand_head.py; refused
# while a working tree has product changes), then every co-op scenario of tools\stand (tracked) through
# tools\stand\run_guarded.ps1 on the stand E:\RayLinkGames\GAMMA\game-dev, each scenario's output judged (its pass lines
# present; no FATAL ERROR / LUA error / lower-case Lua stack traceback / "! [coop" line outside the allow-list of tools\stand_common.ps1).
# All passed: the mark temp\gates\hostplay.ok (both HEAD ids, the exe's SHA-256, the time, the digests of the scenario
# files and of the deployed gamedata) that tools\check_gates.py demands for co-op and Core changes.
#   powershell -ExecutionPolicy Bypass -File tools\stand_hostplay.ps1 [-Tag b57] [-Only carry_group,squads_group] [-NoMark]
# -Only runs a part and never writes the mark. Exit code 0 = PASS. The owner's game is never touched: run_guarded.ps1 stops
# the stand at once if a game outside the stand starts. About 20-30 minutes.
param(
    [string]$Tag = 'b57',
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [string[]]$Only,
    [switch]$NoMark
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stand_common.ps1')

$group = 'steps done: host True, client True; host alive True, client alive True'
$scenarios = @(
    @{ Name = 'carry_group'; Script = 'carry_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @($group); Bad = @('^! ') },
    @{ Name = 'base_group'; Script = 'base_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @($group); Bad = @('^! ') },
    @{ Name = 'sil_group'; Script = 'sil_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @($group); Bad = @('^! ') },
    @{ Name = 'squads_group'; Script = 'squads_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @($group, '\[squads\] ag PASS', 'squads: PASS'); Bad = @('squads: FAIL') },
    @{ Name = 'sp_smoke'; Script = 'sp_smoke.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('sp_smoke: PASS'); Bad = @('sp_smoke: FAIL') },
    @{ Name = 'companions_group'; Script = 'companions_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('companions_group: PASS'); Bad = @('companions_group: FAIL') },
    @{ Name = 'cover_group'; Script = 'cover_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('(?m)^cover_group: PASS$'); Bad = @('^cover_group: FAIL\b') },
    @{ Name = 'vehicle_group'; Script = 'vehicle_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('(?m)^vehicle_group: PASS$'); Bad = @('^vehicle_group: FAIL\b') },
    @{ Name = 'progress_group'; Script = 'progress_group.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Bad = @('^progress_group: FAIL\b'); Pass = @(
        '\[progress-stand\] client walked 15 steps, 300\.0 m', '\[progress-stand\] client searched id=\d+ xp=',
        '\[progress-stand\] keeper facts .*step_m=(?:[1-9]\d*\.\d|0\.[1-9]) corpse_search=[1-9]\d* rank=veteran', '(?m)^progress_group: PASS$'
    ) }
)
$code = Invoke-Stand -Mode 'hostplay' -Scenarios $scenarios -Tag $Tag -Stand $Stand -Only $Only -NoMark:$NoMark
exit $code
