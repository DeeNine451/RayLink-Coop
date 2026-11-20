# The server stand (SS of docs/MODES.md section 10): HEAD's gamedata deployed first (tools\stand\stand_head.py; refused
# while a working tree has product changes), then the server scenarios of tools\stand (tracked; ded_check is
# tools\ded_check.ps1) through tools\stand\run_guarded.ps1 on the stand E:\RayLinkGames\GAMMA\game-dev, each scenario's
# output judged (its pass lines present; no FATAL ERROR / LUA error / stack traceback / "! [coop" line outside the
# allow-list of tools\stand_common.ps1). All passed: the mark temp\gates\srv.ok (both HEAD ids, the exe's SHA-256, the
# time, the digests of the scenario files and of the deployed gamedata) that tools\check_gates.py demands for server /
# Core changes.
#   powershell -ExecutionPolicy Bypass -File tools\stand_srv.ps1 [-Tag b57] [-Only ded_check,base_server] [-NoMark]
# -Only runs a part and never writes the mark. Exit code 0 = PASS. About 20-30 minutes.
param(
    [string]$Tag = 'b57',
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [string[]]$Only,
    [switch]$NoMark
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stand_common.ps1')

$alive = 'server alive \d+ s after the request: True'
$scenarios = @(
    @{ Name = 'ded_check'; Script = '..\ded_check.ps1'; Args = '-World new'; TagArg = $false; StandArg = '-GameDir'; Pass = @('(?m)^PASS\s*$'); Bad = @() },
    @{ Name = 'base_server'; Script = 'base_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('the client is in the world', $alive); Bad = @("^! the client's steps did not end", '^! the server did not quit') },
    @{ Name = 'carry_server'; Script = 'carry_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('the client is in the world', $alive); Bad = @("^! the client's steps did not end", '^! the server did not quit') },
    @{ Name = 'taskboard_ws'; Script = 'taskboard_ws.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('the client is in the world', $alive, '(?m)^taskboard_ws: PASS$'); Bad = @('^! the board answer did not come', '^! the server did not quit') },
    @{ Name = 'phantoms_server'; Script = 'phantoms_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('the client is in the world', $alive, 'phantoms: PASS'); Bad = @("^! the client's steps did not end", '^! the server did not quit', 'phantoms: FAIL') },
    @{ Name = 'allymark_server'; Script = 'allymark_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('(?m)^allymark: PASS$'); Bad = @('^allymark: FAIL\b') },
    @{ Name = 'companions_server'; Script = 'companions_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('(?m)^companions_server: PASS$'); Bad = @('^companions_server: FAIL\b') },
    @{ Name = 'weather_server'; Script = 'weather_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('(?m)^weather_server: PASS$'); Bad = @('^weather_server: FAIL\b') },
    @{ Name = 'cover_server'; Script = 'cover_server.ps1'; Args = ''; TagArg = $true; StandArg = '-Stand'; Pass = @('(?m)^cover_server: PASS$'); Bad = @('^cover_server: FAIL\b') }
)
$code = Invoke-Stand -Mode 'srv' -Scenarios $scenarios -Tag $Tag -Stand $Stand -Only $Only -NoMark:$NoMark
exit $code
