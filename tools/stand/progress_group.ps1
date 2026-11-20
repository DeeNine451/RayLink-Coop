# Dev 57 F5-PRG-5, Co-op. The playing host owns the map, corpse and checked progress.
# Run on the prepared stand through tools\stand_hostplay.ps1 after integration.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 28000,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 900,
    [int]$JoinTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
if ($Stand -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
Assert-NoJunction -Dir $Stand

$encoding = [Text.Encoding]::GetEncoding(1251)
$exeName = 'AnomalyCoopDX11AVX.exe'
$exe = Join-Path $Stand "bin\$exeName"
$clientExe = Join-Path $Stand "bin_b\$exeName"
$options = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$optionsBackup = Join-Path $script:StandDir "progress_options_$PID.ltx"
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_progress.script'
$stepFile = Join-Path $Stand 'zz_progress_step.txt'
$hostFs = Join-Path $Stand 'fsgame_progress_h.ltx'
$hostData = Join-Path $Stand 'appdata_progress_h'
$logName = "logs\xray_$($env:USERNAME).log"
$hostLog = Join-Path $hostData $logName
$clientLog = Join-Path $Stand "appdata_t\$logName"
$logs = @($hostLog, $clientLog)
$hostGame = $client = $null
$installed = [Collections.Generic.List[string]]::new()
$backedUpOptions = $started = $false
$mark = '\[progress-stand\] '
$trust = '\[coop-trust\] (?:! )?progress_\w+\b.*(?:would refuse|would be refused: let through|\brefused\b)'
$badLine = "$($mark)FAIL\b|FATAL ERROR|LUA error|(?-i:stack traceback)"

function Set-ProgressStep([string]$Step) {
    Write-StandText -Path $stepFile -Text ($Step + [Environment]::NewLine) -Encoding ([Text.Encoding]::ASCII)
}

function Assert-ProgressHealthy {
    foreach ($proc in @($hostGame, $client)) {
        if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
    }
    foreach ($log in $logs) {
        if (Test-Path -LiteralPath $log -PathType Leaf) {
            $bad = Select-String -LiteralPath $log -Pattern $badLine | Select-Object -First 1
            if ($bad) { throw (Hide-Hex $bad.Line) }
        }
    }
}

function Wait-ProgressLine([string]$File, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-ProgressHealthy
        if (Test-Path -LiteralPath $File -PathType Leaf) {
            $hit = Select-String -LiteralPath $File -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $File"
}

# Match the prepared carry_group/cover_group character creation, including inherited free kit entries.
function Get-StalkerKit([string]$File) {
    $sections = @{}
    $section = $null
    foreach ($raw in [IO.File]::ReadAllLines($File, $encoding)) {
        $line = ($raw -replace ';.*$', '').Trim()
        if ($line -match '^\[([^\]]+)\]\s*(?::\s*(.+))?$') {
            $section = @{ Values = [ordered]@{}; Parents = @() }
            $sections[$Matches[1]] = $section
            if ($Matches[2]) { $section.Parents = @($Matches[2].Split(',') | ForEach-Object { $_.Trim() }) }
        } elseif ($section -and $line -match '^([^=\s]+)\s*=\s*(.*)$') {
            $section.Values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $resolve = {
        param($name)
        $result = [ordered]@{}
        foreach ($parent in $sections[$name].Parents) {
            foreach ($entry in (& $resolve $parent).GetEnumerator()) { $result[$entry.Key] = $entry.Value }
        }
        foreach ($entry in $sections[$name].Values.GetEnumerator()) { $result[$entry.Key] = $entry.Value }
        $result
    }
    $items = foreach ($entry in (& $resolve 'stalker_loadout').GetEnumerator()) {
        $parts = $entry.Value.Split(',')
        if ($parts[0].Trim() -eq 'false') {
            for ($i = 0; $i -lt [int]$parts[1]; $i++) { $entry.Key }
        }
    }
    if (-not $items) { throw 'no free kit for stalker' }
    return @{ Items = $items -join ','; Money = (& $resolve 'stalker_money')['money'] }
}

try {
    if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
    if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
    if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx') -PathType Leaf)) { throw 'no prepared fsgame_t.ltx' }
    foreach ($path in @($probe, $stepFile, $optionsBackup, $hostFs)) {
        if (Test-Path -LiteralPath $path) { throw "scenario file already exists: $path" }
    }

    Copy-StandTree -From (Join-Path $Stand 'bin') -To (Join-Path $Stand 'bin_b')
    $fsText = [IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $encoding)
    $fsPattern = '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\'
    if ($fsText -notmatch $fsPattern) { throw 'fsgame.ltx format unexpected' }
    $replacement = '$' + '{1}appdata_progress_h\'
    $installed.Add($hostFs)
    Write-StandText -Path $hostFs -Text ($fsText -replace $fsPattern, $replacement) -Encoding $encoding
    $profile = @{
        From = Join-Path $Stand 'appdata_t'
        To = $hostData
        ExcludeFiles = @('coop_player.key', 'axr_options.ltx')
        ExcludeDirs = @('savedgames', 'logs', 'raylink', 'screenshots')
    }
    Copy-StandTree @profile
    foreach ($log in $logs) { Remove-StandFile -Path $log }

    $kit = Get-StalkerKit (Join-Path $Stand 'gamedata\configs\items\settings\new_game_loadouts.ltx')
    Copy-StandFile -From $options -To $optionsBackup
    $backedUpOptions = $true
    $optionsText = [IO.File]::ReadAllText($optionsBackup, $encoding)
    $prefix = [regex]::Replace($optionsText, '(?ms)^\[character_creation\][^\r\n]*(?:\r?\n|\z).*?(?=^\[|\z)', '').TrimEnd()
    $creation = @(
        '[character_creation]', 'new_game_difficulty = 1', 'new_game_economy = 1', 'new_game_economy_treasure = 1',
        'new_game_story_mode = true', 'new_game_character_name = ProgressHost', 'new_game_faction = stalker',
        "new_game_loadout = $($kit.Items)", 'new_game_map = rookie_village'
    )
    if ($kit.Money) { $creation += "new_game_money = $($kit.Money)" }
    Write-StandLines -Path $options -Lines (@($prefix, '') + $creation) -Encoding $encoding
    $installed.Add($probe)
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_progress.script') -To $probe
    $installed.Add($stepFile)
    Set-ProgressStep 'ready'

    $hostArgs = "-fsltx fsgame_progress_h.ltx -coop_nick progress_host -coop_host $Port -coop_probe prg_host -dbg -silent_error_mode -start server(all/single/alife/new) client(localhost)"
    $hostGame = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $hostArgs
    $null = $hostGame.Handle
    $started = $true
    $until = [DateTime]::UtcNow.AddSeconds($UpTimeoutS)
    while (-not (Get-NetUDPEndpoint -LocalPort $Port -OwningProcess $hostGame.Id -ErrorAction SilentlyContinue)) {
        Assert-ProgressHealthy
        if ([DateTime]::UtcNow -ge $until) { throw 'the host did not open its session' }
        Start-Sleep -Seconds 1
    }
    $clientArgs = "-fsltx fsgame_t.ltx -coop_nick progress_tester -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe prg_client -silent_error_mode"
    $client = Start-Process -FilePath $clientExe -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
    $null = $client.Handle
    $null = Wait-ProgressLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $null = Wait-ProgressLine $clientLog "$($mark)client ready map=l01_escape\s*$" 60

    $keeper = Wait-ProgressLine $hostLog "$($mark)keeper ready peer=([1-9]\d{0,4}) character=([1-9]\d{0,4})\s*$" 60
    $peer = [int]$keeper.Matches[0].Groups[1].Value
    $character = [int]$keeper.Matches[0].Groups[2].Value
    if ($peer -ge 65535 -or $character -ge 65535) { throw 'invalid guest identity' }
    $guest = "peer=$peer character=$character"
    Set-ProgressStep 'walk'
    $null = Wait-ProgressLine $clientLog "$($mark)client walked 15 steps, 300\.0 m\s*$" 60
    Set-ProgressStep 'spawn'
    $body = Wait-ProgressLine $hostLog "$($mark)corpse map=l01_escape id=([1-9]\d{0,4})\s*$" 30
    $id = [int]$body.Matches[0].Groups[1].Value
    if ($id -ge 65535) { throw 'invalid corpse id' }
    Set-ProgressStep "search $id"
    $search = Wait-ProgressLine $clientLog "$($mark)client searched id=$id xp=(\d{1,10}\.\d{6}) delta=(\d{1,10}\.\d{6})\s*$" 45
    $xp = $search.Matches[0].Groups[1].Value
    $delta = [double]::Parse($search.Matches[0].Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($delta -le 25) { throw "search XP $delta fits the unconditional allowance" }
    $facts = Wait-ProgressLine $hostLog "$($mark)keeper facts $guest step_m=(\d{1,7}\.\d) corpse_search=[1-9]\d* rank=veteran\s*$" 60 $keeper.LineNumber
    $meters = [double]::Parse($facts.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($meters -le 0) { throw 'the keeper observed no movement' }
    $xpPattern = [regex]::Escape($xp)
    Set-ProgressStep "honest $xp"
    $honest = Wait-ProgressLine $hostLog "$($mark)honest accepted $guest xp=$xpPattern checked=[1-9]\d* failed=0 refused=0\s*$" 30 $facts.LineNumber
    $sent = Wait-ProgressLine $clientLog "$($mark)client honest report xp=$xpPattern\s*$" 5 $search.LineNumber

    Set-ProgressStep 'skills'
    $skills = Wait-ProgressLine $hostLog "$($mark)skills budget failed $guest delta=5000\s*$" 30 $honest.LineNumber
    $inflated = Wait-ProgressLine $clientLog "$($mark)client added 5000 scavenging XP and reported\s*$" 5 $sent.LineNumber
    $beforeRank = @(Get-Content -LiteralPath $hostLog).Count
    Set-ProgressStep 'rank'
    $rank = "\[coop-trust\] progress_rank would refuse: peer $peer, character ${character}: rank -?\d+ -> -?\d+ \(\+5000\), budget "
    $null = Wait-ProgressLine $hostLog $rank 30 $beforeRank
    $null = Wait-ProgressLine $clientLog "$($mark)client added 5000 rank\s*$" 5 $inflated.LineNumber
}
catch {
    Write-Host ('progress_group: FAIL ({0})' -f (Hide-Hex "$_"))
    throw
}
finally {
    try {
        foreach ($proc in @($client, $hostGame)) {
            if ($proc -and -not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force
                if (-not $proc.WaitForExit(5000)) { throw "stand process $($proc.Id) did not stop" }
            }
        }
        if ($started) {
            foreach ($pair in @(@($hostLog, 'host'), @($clientLog, 'client'))) {
                if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
                    Copy-StandFile -From $pair[0] -To (Join-Path $script:StandDir "$($Tag)_progress_group_$($pair[1]).log")
                    Select-String -LiteralPath $pair[0] -Pattern "$mark|$trust|$badLine" | ForEach-Object { Write-Host (Hide-Hex $_.Line) }
                }
            }
        }
    }
    finally {
        foreach ($path in $installed) { Remove-StandFile -Path $path }
        if ($backedUpOptions) {
            Copy-StandFile -From $optionsBackup -To $options
            Remove-StandFile -Path $optionsBackup
        }
    }
}
Write-Host 'progress_group: PASS'
