# Prepares the dedicated host's own instance on a launcher-made stand, as tools\deploy.ps1 does for its stands:
# fsgame_server.ltx (the stand's fsgame.ltx with appdata_server\) and appdata_server\ with a user.ltx and the files the
# mods keep in appdata\. Safe to re-run: an existing user.ltx is kept.
#   powershell -ExecutionPolicy Bypass -File tools/stand_server.ps1 -Stand E:\RayLinkGames\GAMMA\game-dev
# Hard links (TZ.md R21; review 5 of the layer guard, B1): the launcher builds the stand from hard links to the mods' own
# files, so nothing here writes into an existing stand file. Write-StandText / Write-StandLines / Copy-StandTree of
# tools\stand_common.ps1 put the bytes into a new file and give it the name (the old name is deleted, read-only-safe);
# the mod keeps its file and its attribute. tests\tools\test_gates.py runs this on a stand of real hard links.
param([string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'stand_common.ps1')
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)
$fsgame = Join-Path $Stand 'fsgame.ltx'
if (-not (Test-Path -LiteralPath $fsgame)) { throw "no fsgame.ltx in $Stand" }
$name = 'appdata_server'
$text = [System.IO.File]::ReadAllText($fsgame, $cp1251) -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$name\"
if ($text -notmatch [regex]::Escape("$name\")) { throw 'fsgame.ltx format unexpected: app_data_root not rewritten' }
$server = Join-Path $Stand 'fsgame_server.ltx'
$want = $cp1251.GetBytes($text)
$have = if (Test-Path -LiteralPath $server -PathType Leaf) { [System.IO.File]::ReadAllBytes($server) } else { $null }
if ($null -eq $have -or [Convert]::ToBase64String($have) -ne [Convert]::ToBase64String($want)) {
    Write-StandText -Path $server -Text $text -Encoding $cp1251
}
$appdata = Join-Path $Stand $name
New-Item -ItemType Directory -Force -Path $appdata | Out-Null
$user = Join-Path $appdata 'user.ltx'
if (-not (Test-Path -LiteralPath $user)) {
    Write-StandLines -Path $user -Lines ([string[]]@('rs_screenmode windowed', 'vid_mode 1280x720', 'g_always_active on', 'coop_nick server')) -Encoding $cp1251
}
$mods = Join-Path $Stand 'appdata'
if (Test-Path -LiteralPath $mods) {
    # robocopy $mods $appdata /E /XF user.ltx, without writing into an existing file
    Copy-StandTree -From $mods -To $appdata -ExcludeFiles @('user.ltx')
}
Write-Host "server instance: $server, $appdata"
Select-String -LiteralPath $server -Pattern 'app_data_root' | Select-Object -First 1 | ForEach-Object { $_.Line }
