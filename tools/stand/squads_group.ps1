# 2026-11-18, step S0 of docs/plans/2026-11-18-two-modes.md: regression R1 of build 52 (issue 1293). An ORDINARY co-op world
# (its host plays, no split levels): the client walks 100-180 m away from the host, the host makes two squads 15-30 m from the
# CLIENT, and the client must stay alive and see their members (coop_zz_squads.script, roles h and ag). Builds 52-54 crashed
# every such client (CSE_ALifeOnlineOfflineGroup::switch_online, R_ASSERT(!m_bOnline)). Made from carry_group.ps1.
#   powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script squads_group.ps1 -Out b57_squads.out -ScriptArgs '-Tag b57'
# The last line is "squads: PASS" or "squads: FAIL (<why>)".
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [int]$Port = 27986,
    [string]$Tag = 'b57',
    [string]$Faction = 'stalker',
    [string]$Map = 'rookie_village',
    [int]$UpTimeoutS = 900,
    [int]$JoinTimeoutS = 600,
    [int]$StepsTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link (TZ R21)
# Tracked in tools\stand (docs/MODES.md section 10): the probes come from this folder; logs and the stand's
# settings kept for the restore go to the repository's temp\stand (ignored: the run history).
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
# a second game instance starts from bin_b (hard links to bin, made again on every run): one mutex per folder
$binB = Join-Path $Stand 'bin_b'
New-Item -ItemType Directory -Force -Path $binB | Out-Null
Get-ChildItem -LiteralPath (Join-Path $Stand 'bin') -File | ForEach-Object {
    $dst = Join-Path $binB $_.Name
    Remove-StandFile -Path $dst
    New-Item -ItemType HardLink -Path $dst -Target $_.FullName | Out-Null
}
$exeB = Join-Path $binB 'AnomalyCoopDX11AVX.exe'
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx'))) { throw 'no fsgame_t.ltx: run auto_world.ps1 once' }

function New-Profile([string]$letter, [string]$nick) {
    $name = "appdata_$letter"
    $text = [System.IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $cp1251) -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$name\"
    if ($text -notmatch [regex]::Escape("$name\")) { throw 'fsgame.ltx format unexpected' }
    Write-StandText -Path (Join-Path $Stand "fsgame_$letter.ltx") -Text $text -Encoding $cp1251
    $appdata = Join-Path $Stand $name
    New-Item -ItemType Directory -Force -Path $appdata | Out-Null
    Copy-StandTree -From (Join-Path $Stand 'appdata_t') -To $appdata -ExcludeFiles @('coop_player.key', 'axr_options.ltx') -ExcludeDirs @('savedgames', 'logs', 'raylink', 'screenshots')
    $global:LASTEXITCODE = 0
    $user = Join-Path $appdata 'user.ltx'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]][System.IO.File]::ReadAllLines($user, $cp1251))
    $idx = $lines.FindIndex([Predicate[string]] { param($l) $l -match '^coop_nick\s' })
    if ($idx -ge 0) { $lines[$idx] = "coop_nick $nick" } else { $lines.Add("coop_nick $nick") }
    Write-StandLines -Path $user -Lines $lines -Encoding $cp1251
    return $appdata
}

function Get-StartKit([string]$Ltx, [string]$Fac) {
    $own = @{}; $parents = @{}; $cur = $null
    foreach ($raw in [System.IO.File]::ReadAllLines($Ltx, $cp1251)) {
        $l = ($raw -replace ';.*$', '').Trim()
        if (-not $l) { continue }
        if ($l -match '^\[([^\]]+)\]\s*(?::\s*(.+))?$') {
            $cur = $Matches[1]
            $own[$cur] = [ordered]@{}
            $parents[$cur] = if ($Matches[2]) { @($Matches[2].Split(',') | ForEach-Object { $_.Trim() }) } else { @() }
            continue
        }
        if ($cur -and $l -match '^([^=\s]+)\s*=\s*(.*)$') { $own[$cur][$Matches[1]] = $Matches[2].Trim() }
    }
    $resolve = {
        param($s)
        $r = [ordered]@{}
        foreach ($p in $parents[$s]) { foreach ($kv in (& $resolve $p).GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
        if ($own.Contains($s)) { foreach ($kv in $own[$s].GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
        $r
    }
    $kit = [System.Collections.Generic.List[string]]::new()
    foreach ($kv in (& $resolve "$($Fac)_loadout").GetEnumerator()) {
        $v = $kv.Value.Split(',')
        if ($v[0].Trim() -eq 'false') { for ($i = 0; $i -lt [int]$v[1]; $i++) { $kit.Add($kv.Key) } }
    }
    [pscustomobject]@{ Loadout = ($kit -join ','); Money = (& $resolve "$($Fac)_money")['money'] }
}

function Wait-Log([string]$file, [string]$pattern, [int]$seconds, $proc) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        if ((Test-Path -LiteralPath $file) -and (Select-String -LiteralPath $file -Pattern $pattern -Quiet)) { return $true }
        if ($proc -and $proc.HasExited) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}
function Show-Lines([string]$file, [string]$pattern, [int]$most, [int]$after = 0) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host "  no log $file"; return }
    Select-String -LiteralPath $file -Pattern $pattern -Context 0, $after | Select-Object -Last $most | ForEach-Object {
        foreach ($l in @($_.Line) + @($_.Context.PostContext)) {
            $l = $l -replace '[0-9a-fA-F]{32,}', '<hidden>'
            if ($l.Length -gt 420) { $l = $l.Substring(0, 420) }
            Write-Host "  $l"
        }
    }
}

$token = 'sq' + (Get-Date -Format 'HHmmss')
$hostData = New-Profile 'h' 'hoster'
$hostLog = Join-Path $hostData ('logs\xray_' + $env:USERNAME + '.log')
$clientLog = Join-Path $Stand ('appdata_t\logs\xray_' + $env:USERNAME + '.log')
foreach ($f in @($hostLog, $clientLog)) { Remove-StandFile -Path $f }
$scripts = Join-Path $Stand 'gamedata\scripts'
Get-ChildItem -LiteralPath $scripts -Filter 'coop_zz_*.script' | ForEach-Object { Remove-StandFile -Path $_.FullName }
Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_squads.script') -To (Join-Path $scripts 'coop_zz_squads.script')
Get-ChildItem -LiteralPath $Stand -Filter 'zz_squads_*.txt' | ForEach-Object { Remove-StandFile -Path $_.FullName }

# the new game's choice, as the stock screen writes it ([character_creation] of the stand's axr_options.ltx)
$opt = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$optKeep = Join-Path $OutDir 'axr_options.before_squads.ltx'
if (-not (Test-Path -LiteralPath $optKeep)) { Copy-Item -LiteralPath $opt -Destination $optKeep }
$kit = Get-StartKit (Join-Path $Stand 'gamedata\configs\items\settings\new_game_loadouts.ltx') $Faction
if (-not $kit.Loadout) { throw "no free kit for faction '$Faction'" }
$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([string[]][System.IO.File]::ReadAllLines($opt, $cp1251))
$start = $lines.FindIndex([Predicate[string]] { param($l) $l -match '^\[character_creation\]' })
if ($start -ge 0) {
    $end = $lines.FindIndex($start + 1, [Predicate[string]] { param($l) $l -match '^\[' })
    if ($end -lt 0) { $end = $lines.Count }
    $lines.RemoveRange($start, $end - $start)
}
$lines.Add('[character_creation]')
$lines.Add('new_game_difficulty = 1')
$lines.Add('new_game_economy = 1')
$lines.Add('new_game_economy_treasure = 1')
$lines.Add('new_game_story_mode = true')
$lines.Add('new_game_character_name = Hoster')
$lines.Add("new_game_faction = $Faction")
$lines.Add("new_game_loadout = $($kit.Loadout)")
$lines.Add("new_game_map = $Map")
if ($kit.Money) { $lines.Add("new_game_money = $($kit.Money)") }
Write-StandLines -Path $opt -Lines $lines -Encoding $cp1251
Write-Host "new game: $Faction at $Map, $($kit.Money) RU"

$gameHost = $null; $client = $null
$why = ''
try {
    $gameHost = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_h.ltx -coop_nick hoster -coop_host $Port -coop_probe h -zz_token $token -dbg -silent_error_mode -start server(all/single/alife/new) client(localhost)"
    $null = $gameHost.Handle
    Write-Host "host pid $($gameHost.Id)"
    $until = (Get-Date).AddSeconds($UpTimeoutS)
    $up = $false
    while ((Get-Date) -lt $until -and -not $gameHost.HasExited) {
        if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { $up = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $up) {
        if ($gameHost.HasExited) { Write-Host ("the host's process ended by itself: exit code {0} (0x{0:X8})" -f $gameHost.ExitCode) }
        throw 'the host did not open its session'
    }
    Write-Host ("the host's session is up ({0:HH:mm:ss})" -f (Get-Date))
    Start-Sleep -Seconds 10
    $client = Start-Process -FilePath $exeB -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_t.ltx -coop_nick tester -coop_autochoose $Faction -coop_connect 127.0.0.1:$Port -coop_probe ag -zz_token $token -silent_error_mode"
    $null = $client.Handle
    Write-Host "client pid $($client.Id)"
    if (-not (Wait-Log $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS $client)) {
        if ($client.HasExited) { Write-Host ("the client's process ended by itself: exit code {0} (0x{0:X8})" -f $client.ExitCode) }
        throw 'the client did not get into the world'
    }
    Write-Host ("the client is in the world ({0:HH:mm:ss})" -f (Get-Date))
    $doneClient = Wait-Log $clientLog '\[squads\] ag done' $StepsTimeoutS $client
    $doneHost = Wait-Log $hostLog '\[squads\] h done' 120 $gameHost
    $hostAlive = -not $gameHost.HasExited
    $clientAlive = -not $client.HasExited
    if (-not $clientAlive) { Write-Host ("the client's process ended: exit code {0} (0x{0:X8})" -f $client.ExitCode) }
    Write-Host "steps done: host $doneHost, client $doneClient; host alive $hostAlive, client alive $clientAlive"
    $pass = (Test-Path -LiteralPath $clientLog) -and (Select-String -LiteralPath $clientLog -Pattern '\[squads\] ag PASS' -Quiet)
    if (-not $clientAlive) { $why = 'the client died' }
    elseif (-not $hostAlive) { $why = 'the host died' }
    elseif (-not $doneClient) { $why = 'the client steps did not end' }
    elseif (-not $pass) { $why = 'a squad has no member live on the client' }
}
catch {
    $why = "$_"
    Write-Host "! $why"
}
finally {
    foreach ($p in @($client, $gameHost)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    # a game of 10+ GB takes longer than a few seconds to go after Stop-Process: wait for it, not a fixed pause
    foreach ($p in @($client, $gameHost)) { if ($p) { [void]$p.WaitForExit(30000) } }
    Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    foreach ($pair in @(@($clientLog, 'client'), @($hostLog, 'host'))) {
        if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $OutDir "${Tag}_squads_$($pair[1]).log") -Force }
    }
    Get-ChildItem -LiteralPath $scripts -Filter 'coop_zz_*.script' | ForEach-Object { Remove-StandFile -Path $_.FullName }
    Get-ChildItem -LiteralPath $Stand -Filter 'zz_squads_*.txt' | ForEach-Object { Remove-StandFile -Path $_.FullName }
    Copy-StandFile -From $optKeep -To $opt
}
foreach ($pair in @(@($hostLog, 'host'), @($clientLog, 'client'))) {
    Write-Host "--- $($pair[1]): the probe ---"
    Show-Lines $pair[0] '\[squads\]' 60
    Write-Host "--- $($pair[1]): squads through the mirror ---"
    Show-Lines $pair[0] '\[coop\] mirror: .*(squad|comes online now)|switch_online|m_bOnline' 30
    Write-Host "--- $($pair[1]): errors ---"
    Show-StandLogLines $pair[0] 'SCRIPT ERROR|attempt to |! \[SCRIPT|xr_conditions fail|xr_effects fail' 30
}
if ($why) { Write-Host "squads: FAIL ($why)" } else { Write-Host 'squads: PASS' }
