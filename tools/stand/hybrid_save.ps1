# 2026-11-18, step S0 of docs/plans/2026-11-18-two-modes.md: a world of the HYBRID mode of build 56 saved with the players on two
# levels, kept as tests\fixtures\saves\hybrid_b56\ for step S2 ("a world saved in the hybrid opens as a co-op world").
# Made from night_split.ps1 (players, logs, the go file) and carry_group.ps1 (a co-op host in a window, a new game).
# The hybrid: the host plays and leads his level, coop_split_levels 1, coop_world_server 0 (the old split levels), and
# coop_story_together 0 so that a client may walk to another level alone (its map server is started by the host, hidden).
#   powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script hybrid_save.ps1 -Out b56_hybrid.out
# The stand's exe must be build 56 (the script reads "RayLink Engine b56" in it; -AnyBuild skips that). Players: the host
# (h), client a (walks to the next level, drops one item there), with -Players 3 also client c (stays with the host).
# Steps: the host waits until a stands on the other level, then `save hybrid_b56`; the save files are copied with a README.
# The last line is "hybrid_save: PASS" or "hybrid_save: FAIL (<why>)".
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [int]$Port = 27987,
    [string]$Tag = 'b56',
    [string]$Save = 'hybrid_b56',
    [int]$Players = 2,
    [string]$Faction = 'stalker',
    [string]$Map = 'rookie_village',
    [switch]$AnyBuild,
    [int]$UpTimeoutS = 900,
    [int]$JoinTimeoutS = 600,
    [int]$StepsTimeoutS = 900
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link (TZ R21)
# Tracked in tools\stand (docs/MODES.md section 10): the probes come from this folder; logs and the stand's
# settings kept for the restore go to the repository's temp\stand (ignored: the run history).
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fixture = Join-Path $repo "tests\fixtures\saves\$Save"
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx'))) { throw 'no fsgame_t.ltx: run auto_world.ps1 once' }
$exeBytes = [System.IO.File]::ReadAllBytes($exe)
$label = [System.Text.Encoding]::ASCII.GetString($exeBytes)
$build = if ($label -match 'RayLink Engine (b\d+|dev)') { $Matches[1] } else { 'unknown' }
if ($build -ne 'b56' -and -not $AnyBuild) { throw "the stand's exe is build '$build', not b56 (the hybrid fixture is of build 56; -AnyBuild to go on)" }
$exeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ("stand exe: build {0}, SHA-256 {1}..." -f $build, $exeHash.Substring(0, 12))

# a second and a third game instance start from bin_b and bin_c (hard links to bin): one mutex per folder
function New-BinCopy([string]$name) {
    $dir = Join-Path $Stand $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $Stand 'bin') -File | ForEach-Object {
        $dst = Join-Path $dir $_.Name
        Remove-StandFile -Path $dst
        New-Item -ItemType HardLink -Path $dst -Target $_.FullName | Out-Null
    }
    return (Join-Path $dir 'AnomalyCoopDX11AVX.exe')
}
$exeB = New-BinCopy 'bin_b'
$exeC = if ($Players -ge 3) { New-BinCopy 'bin_c' } else { $null }

function New-Profile([string]$letter, [string]$nick, [hashtable]$cvars) {
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
    $all = @{ coop_nick = $nick }
    if ($cvars) { foreach ($k in $cvars.Keys) { $all[$k] = $cvars[$k] } }
    foreach ($k in $all.Keys) {
        $key = $k
        $idx = $lines.FindIndex([Predicate[string]] { param($l) $l -match ('^' + [regex]::Escape($key) + '\s') })
        if ($idx -ge 0) { $lines[$idx] = "$key $($all[$key])" } else { $lines.Add("$key $($all[$key])") }
    }
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
function Show-Lines([string]$file, [string]$pattern, [int]$most) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host "  no log $file"; return }
    Select-String -LiteralPath $file -Pattern $pattern | Select-Object -Last $most | ForEach-Object {
        $l = $_.Line -replace '[0-9a-fA-F]{32,}', '<hidden>'
        if ($l.Length -gt 520) { $l = $l.Substring(0, 520) }
        Write-Host "  $l"
    }
}
function Start-Client([string]$exePath, [string]$letter, [string]$nick, [string]$role, [string]$log) {
    Remove-StandFile -Path $log
    $p = Start-Process -FilePath $exePath -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_$letter.ltx -coop_nick $nick -coop_autochoose $Faction -coop_connect 127.0.0.1:$Port -coop_probe $role -zz_token $token -zz_save $Save -silent_error_mode"
    $null = $p.Handle
    Write-Host "player $nick pid $($p.Id), role $role"
    if (-not (Wait-Log $log '\[coop\] phase loading-world -> live' $JoinTimeoutS $p)) {
        if ($p.HasExited) { Write-Host ("the game of $nick ended by itself: exit code {0} (0x{0:X8})" -f $p.ExitCode) }
        throw "$nick did not get into the world"
    }
    Write-Host ("{0} is in the world ({1:HH:mm:ss})" -f $nick, (Get-Date))
    return $p
}

$token = 'hy' + (Get-Date -Format 'HHmmss')
$hybrid = @{ coop_split_levels = '1'; coop_world_server = '0'; coop_story_together = '0' }
$hostData = New-Profile 'h' 'hoster' $hybrid
$hostLog = Join-Path $hostData ('logs\xray_' + $env:USERNAME + '.log')
$logA = Join-Path $Stand ('appdata_t\logs\xray_' + $env:USERNAME + '.log')
$logC = $null
if ($Players -ge 3) { $null = New-Profile 'u' 'tester2' $null; $logC = Join-Path $Stand ('appdata_u\logs\xray_' + $env:USERNAME + '.log') }
Remove-StandFile -Path $hostLog
$hostSaves = Join-Path $hostData 'savedgames'
if (Test-Path -LiteralPath $hostSaves) { Get-ChildItem -LiteralPath $hostSaves -Filter "$Save*" | ForEach-Object { Remove-StandFile -Path $_.FullName } }
$scripts = Join-Path $Stand 'gamedata\scripts'
Get-ChildItem -LiteralPath $scripts -Filter 'coop_zz_*.script' | ForEach-Object { Remove-StandFile -Path $_.FullName }
Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_hybrid.script') -To (Join-Path $scripts 'coop_zz_hybrid.script')
Get-ChildItem -LiteralPath $Stand -Filter 'zz_hybrid_*.txt' | ForEach-Object { Remove-StandFile -Path $_.FullName }
Get-ChildItem -LiteralPath $Stand -Directory -Filter 'appdata_ms*' | ForEach-Object { Remove-StandFile -Path (Join-Path $_.FullName ('logs\xray_' + $env:USERNAME + '.log')) }

$opt = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$optKeep = Join-Path $OutDir 'axr_options.before_hybrid.ltx'
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

$gameHost = $null; $a = $null; $c = $null
$why = ''
$saveStart = Get-Date
try {
    $gameHost = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_h.ltx -coop_nick hoster -coop_host $Port -coop_probe h -zz_token $token -zz_save $Save -dbg -silent_error_mode -start server(all/single/alife/new) client(localhost)"
    $null = $gameHost.Handle
    Write-Host "host pid $($gameHost.Id)"
    $until = (Get-Date).AddSeconds($UpTimeoutS)
    $up = $false
    while ((Get-Date) -lt $until -and -not $gameHost.HasExited) {
        if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { $up = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $up) { throw 'the host did not open its session' }
    Write-Host ("the host's session is up ({0:HH:mm:ss})" -f (Get-Date))
    Start-Sleep -Seconds 10
    $a = Start-Client $exeB 't' 'tester' 'a' $logA
    if ($Players -ge 3) { $c = Start-Client $exeC 'u' 'tester2' 'c' $logC }
    if (-not (Wait-Log $logA '\[hy\] a arrived on' $StepsTimeoutS $a)) { throw 'client a did not reach another level' }
    Write-Host ("client a is on the other level ({0:HH:mm:ss})" -f (Get-Date))
    $saveStart = Get-Date
    if (-not (Wait-Log $hostLog '\[hy\] h saved' 180 $gameHost)) { throw 'the host did not save' }
    Start-Sleep -Seconds 20 # the save is written by the next frames
    $files = @()
    if (Test-Path -LiteralPath $hostSaves) { $files = @(Get-ChildItem -LiteralPath $hostSaves -File | Where-Object { $_.Name -like "$Save*" -or $_.LastWriteTime -ge $saveStart.AddSeconds(-5) }) }
    if (-not ($files | Where-Object { $_.Extension -eq '.scop' })) { throw "no $Save.scop in $hostSaves" }
    Write-Host "save files: $(@($files | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "alive: host $(-not $gameHost.HasExited), a $(-not $a.HasExited)$(if ($c) { ', c ' + (-not $c.HasExited) })"
    if ($gameHost.HasExited) { $why = 'the host died' }
    if (-not $why) {
        New-Item -ItemType Directory -Force -Path $fixture | Out-Null
        foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $fixture $f.Name) -Force }
        $levels = @()
        foreach ($pair in @(@($hostLog, 'host'), @($logA, 'a'))) {
            $m = Select-String -LiteralPath $pair[0] -Pattern '\[hy\] \w+ (the steps start on|arrived on) (\S+)' | Select-Object -Last 1
            if ($m) { $levels += "$($pair[1]): $($m.Matches[0].Groups[2].Value)" }
        }
        $readme = @(
            "# Hybrid world of build 56 ($Save)",
            '',
            "Made by temp/stand/hybrid_save.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm') with the stand exe of build $build",
            "(SHA-256 starts $($exeHash.Substring(0, 12)), the label 'RayLink Engine $build' inside the exe).",
            '',
            'Mode: the hybrid of build 56. The host plays and leads his level; coop_split_levels 1, coop_world_server 0,',
            'coop_story_together 0. The other level ran on a hidden map server started by the host.',
            "Players when saved: $Players (host hoster, client tester$(if ($Players -ge 3) { ', client tester2 with the host' })).",
            "Levels when saved: $($levels -join '; '). Client a dropped one item on his level before the save.",
            '',
            'Files: ' + (@($files | ForEach-Object { $_.Name }) -join ', ') + '.',
            '',
            'Use (docs/plans/2026-11-18-two-modes.md, step S2): load this world in the co-op of the new build; every player must be',
            'on the host level, every object once, no map server process.'
        )
        [System.IO.File]::WriteAllLines((Join-Path $fixture 'README.md'), $readme, [System.Text.UTF8Encoding]::new($false))
        Write-Host "copied $($files.Count) file(s) and README.md to $fixture"
    }
}
catch {
    $why = "$_"
    Write-Host "! $why"
}
finally {
    foreach ($p in @($c, $a, $gameHost)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    Start-Sleep -Seconds 3
    Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    foreach ($pair in @(@($hostLog, 'host'), @($logA, 'a'), @($logC, 'c'))) {
        if ($pair[0] -and (Test-Path -LiteralPath $pair[0])) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $OutDir "${Tag}_hybrid_$($pair[1]).log") -Force }
    }
    Get-ChildItem -LiteralPath $Stand -Directory -Filter 'appdata_ms*' | ForEach-Object {
        $l = Join-Path $_.FullName ('logs\xray_' + $env:USERNAME + '.log')
        if (Test-Path -LiteralPath $l) { Copy-Item -LiteralPath $l -Destination (Join-Path $OutDir ("${Tag}_hybrid_" + $_.Name + '.log')) -Force }
    }
    Get-ChildItem -LiteralPath $scripts -Filter 'coop_zz_*.script' | ForEach-Object { Remove-StandFile -Path $_.FullName }
    Get-ChildItem -LiteralPath $Stand -Filter 'zz_hybrid_*.txt' | ForEach-Object { Remove-StandFile -Path $_.FullName }
    Copy-StandFile -From $optKeep -To $opt
}
Get-ChildItem -LiteralPath $OutDir -Filter "${Tag}_hybrid_*.log" | Sort-Object Name | ForEach-Object {
    Write-Host "=== $($_.Name): the probe ==="
    Show-Lines $_.FullName '\[hy\]' 40
    Write-Host "=== $($_.Name): errors ==="
    Show-Lines $_.FullName 'FATAL ERROR|LUA error|SCRIPT ERROR|stack traceback|attempt to |! \[coop|! \[SCRIPT' 20
}
if ($why) { Write-Host "hybrid_save: FAIL ($why)" } else { Write-Host 'hybrid_save: PASS' }
