# Dev 57 F5-COV-4, Co-op. The playing host runs the clock and judges the client's body on Cordon.
# Run on the prepared stand through tools\stand_hostplay.ps1 after integration.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27996,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 900,
    [int]$JoinTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\tools\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
if ($Stand -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
Assert-NoJunction -Dir $Stand

$encoding = [Text.Encoding]::GetEncoding(1251)
$ascii = [Text.Encoding]::ASCII
$exeName = 'AnomalyCoopDX11AVX.exe'
$exe = Join-Path $Stand "bin\$exeName"
$clientExe = Join-Path $Stand "bin_b\$exeName"
$options = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$optionsBackup = Join-Path $script:StandDir "cover_options_$PID.ltx"
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_cover.script'
$stepFile = Join-Path $Stand 'zz_cover_step.txt'
$hostFs = Join-Path $Stand 'fsgame_cover_h.ltx'
$hostData = Join-Path $Stand 'appdata_cover_h'
$logName = "logs\xray_$($env:USERNAME).log"
$hostLog = Join-Path $hostData $logName
$clientLog = Join-Path $Stand "appdata_t\$logName"
$logs = @($hostLog, $clientLog)
$hostGame = $client = $null
$installedProbe = $installedStep = $backedUpOptions = $started = $false
$mark = '\[cover-stand\] '
$outside = "$($mark)env_cover: cover_tester open\s*$"
$static = "$($mark)env_cover: cover_tester covered \(static\)\s*$"
$trust = '\[coop-trust\] (?:! )?env_cover\b(?=.*\bcover_tester\b).*(?:would refuse|would be refused: let through)'
$badLine = "$($mark)FAIL\b|FATAL ERROR|LUA error|(?-i:stack traceback)|\[coop\] emission: cover_tester .*kill sent"

function Set-CoverStep([string]$Step) {
    Write-StandText -Path $stepFile -Text ($Step + [Environment]::NewLine) -Encoding $ascii
}

function Wait-CoverLine([string]$File, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        foreach ($proc in @($hostGame, $client)) {
            if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
        }
        foreach ($log in $logs) {
            if (Test-Path -LiteralPath $log -PathType Leaf) {
                $bad = Select-String -LiteralPath $log -Pattern $badLine | Select-Object -First 1
                if ($bad) { throw (Hide-Hex $bad.Line) }
            }
        }
        if (Test-Path -LiteralPath $File -PathType Leaf) {
            $hit = Select-String -LiteralPath $File -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $File"
}

# The carry_group new-game setup uses the faction's free kit and starting money.
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
    foreach ($path in @($probe, $stepFile, $optionsBackup)) {
        if (Test-Path -LiteralPath $path) { throw "scenario file already exists: $path" }
    }

    Copy-StandTree -From (Join-Path $Stand 'bin') -To (Join-Path $Stand 'bin_b')
    $fsText = [IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $encoding)
    $fsPattern = '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\'
    if ($fsText -notmatch $fsPattern) { throw 'fsgame.ltx format unexpected' }
    $replacement = '$' + '{1}appdata_cover_h\'
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
        'new_game_story_mode = true', 'new_game_character_name = CoverHost', 'new_game_faction = stalker',
        "new_game_loadout = $($kit.Items)", 'new_game_map = rookie_village'
    )
    if ($kit.Money) { $creation += "new_game_money = $($kit.Money)" }
    Write-StandLines -Path $options -Lines (@($prefix, '') + $creation) -Encoding $encoding
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_cover.script') -To $probe
    $installedProbe = $true
    Set-CoverStep 'ready'
    $installedStep = $true

    $hostArgs = "-fsltx fsgame_cover_h.ltx -coop_nick cover_host -coop_host $Port -coop_probe coverhost -dbg -silent_error_mode -start server(all/single/alife/new) client(localhost)"
    $hostGame = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $hostArgs
    $null = $hostGame.Handle
    $started = $true
    $until = [DateTime]::UtcNow.AddSeconds($UpTimeoutS)
    while (-not (Get-NetUDPEndpoint -LocalPort $Port -OwningProcess $hostGame.Id -ErrorAction SilentlyContinue)) {
        if ($hostGame.HasExited -or [DateTime]::UtcNow -ge $until) { throw 'the host did not open its session' }
        Start-Sleep -Seconds 1
    }
    $clientArgs = "-fsltx fsgame_t.ltx -coop_nick cover_tester -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe coverclient -silent_error_mode"
    $client = Start-Process -FilePath $clientExe -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
    $null = $client.Handle
    $null = Wait-CoverLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $null = Wait-CoverLine $clientLog "$($mark)client ready map=l01_escape shelter=esc_\w+\s*$" 60
    $null = Wait-CoverLine $hostLog "$($mark)host ready map=l01_escape\s*$" 60

    Set-CoverStep 'start'
    $start = Wait-CoverLine $hostLog "$($mark)host started\s*$" 30
    $open = Wait-CoverLine $hostLog $outside 30 $start.LineNumber
    Set-CoverStep 'inside'
    $covered = Wait-CoverLine $hostLog $static 30 $open.LineNumber
    Set-CoverStep 'outside'
    $openAgain = Wait-CoverLine $hostLog $outside 30 $covered.LineNumber
    Set-CoverStep 'claim'
    $null = Wait-CoverLine $clientLog "$($mark)client sent cover claim\s*$" 30
    $refusal = Wait-CoverLine $hostLog $trust 30 $openAgain.LineNumber
    $null = Wait-CoverLine $hostLog "$($mark)env_cover: cover_tester covered \(report\)\s*$" 30 $refusal.LineNumber
    Set-CoverStep 'kill'
    $null = Wait-CoverLine $hostLog "$($mark)host kill checked\s*$" 30
    Set-CoverStep 'check'
    $null = Wait-CoverLine $clientLog "$($mark)client alive after wave\s*$" 15
    Set-CoverStep 'skip'
    $null = Wait-CoverLine $hostLog "$($mark)host skipped\s*$" 30
    $null = Wait-CoverLine $clientLog "$($mark)client done\s*$" 30
}
catch {
    Write-Host ('cover_group: FAIL ({0})' -f (Hide-Hex "$_"))
    throw
}
finally {
    try {
        foreach ($proc in @($client, $hostGame)) {
            if ($proc -and -not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force
                $null = $proc.WaitForExit(5000)
            }
        }
        if ($started) {
            foreach ($pair in @(@($hostLog, 'host'), @($clientLog, 'client'))) {
                if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
                    Copy-StandFile -From $pair[0] -To (Join-Path $script:StandDir "$($Tag)_cover_group_$($pair[1]).log")
                    Select-String -LiteralPath $pair[0] -Pattern "$mark|$trust|$badLine" |
                        ForEach-Object { Write-Host (Hide-Hex $_.Line) }
                }
            }
        }
    }
    finally {
        if ($installedStep) { Remove-StandFile -Path $stepFile }
        if ($installedProbe) { Remove-StandFile -Path $probe }
        if ($backedUpOptions) {
            Copy-StandFile -From $optionsBackup -To $options
            Remove-StandFile -Path $optionsBackup
        }
    }
}
Write-Host 'cover_group: PASS'
