# Dev 57 F5-PRG-5, Server. The map server makes the corpse and reports facts to the world keeper.
# Run on the prepared stand through tools\stand_srv.ps1 after integration.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 28001,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
if ($Stand -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
Assert-NoJunction -Dir $Stand

$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_progress.script'
$stepFile = Join-Path $Stand 'zz_progress_step.txt'
$stageName = 'zz_progress_stage_' + [Guid]::NewGuid().ToString('N') + '.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
$logName = "logs\xray_$($env:USERNAME).log"
$worldLog = Join-Path $Stand "appdata_server\$logName"
$clientLog = Join-Path $Stand "appdata_t\$logName"
$mapLogs = @(1..7 | ForEach-Object { Join-Path $Stand "appdata_ms$_\$logName" })
$logs = @($worldLog, $clientLog) + $mapLogs
$world = $client = $null
$installed = [Collections.Generic.List[string]]::new()
$started = $false
$mark = '\[progress-stand\] '
$trust = '\[coop-trust\] (?:! )?progress_\w+\b.*(?:would refuse|would be refused: let through|\brefused\b)'
$badLine = "$($mark)FAIL\b"

function Set-ProgressStep([string]$Step) {
    Write-StandText -Path $stepFile -Text ($Step + [Environment]::NewLine) -Encoding ([Text.Encoding]::ASCII)
}

function Assert-ProgressHealthy {
    foreach ($proc in @($world, $client)) {
        if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
    }
    foreach ($log in $logs) {
        if (Test-Path -LiteralPath $log -PathType Leaf) {
            $bad = Select-StandLogLine $log $badLine -Live | Select-Object -First 1
            if ($bad) { throw (Hide-Hex $bad.Line) }
        }
    }
}

function Wait-ProgressLine([string[]]$Files, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-ProgressHealthy
        foreach ($file in $Files) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $hit = Select-String -LiteralPath $file -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
                if ($hit) { return $hit }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $($Files -join ', ')"
}

function Keep-ProgressLog([string]$File, [string]$Label) {
    if (Test-Path -LiteralPath $File -PathType Leaf) {
        Copy-StandFile -From $File -To (Join-Path $script:StandDir "$($Tag)_progress_server_$Label.log")
        Select-StandLogLine $File "$mark|$trust|$badLine" | ForEach-Object { Write-Host (Hide-Hex $_.Line) }
    }
}

try {
    if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
    if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
    if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx') -PathType Leaf)) { throw 'no prepared fsgame_t.ltx' }
    foreach ($path in @($probe, $stepFile, $stage, "$stage.used")) {
        if (Test-Path -LiteralPath $path) { throw "scenario file already exists: $path" }
    }
    foreach ($log in $logs) { Remove-StandFile -Path $log }
    $installed.Add($probe)
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_progress.script') -To $probe
    $installed.Add($stepFile)
    Set-ProgressStep 'ready'
    $installed.Add($stage)
    $installed.Add("$stage.used")
    $stageText = @('[world]', 'faction = stalker', 'title = own-progress', '') -join [Environment]::NewLine
    Write-StandText -Path $stage -Text $stageText -Encoding ([Text.Encoding]::ASCII)

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Stand
    $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stageName -coop_probe prg_world -silent_error_mode -dbg"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $world = [Diagnostics.Process]::Start($psi)
    $started = $true
    $null = Wait-ProgressLine $worldLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS
    $clientArgs = "-fsltx fsgame_t.ltx -coop_nick progress_tester -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe prg_client -silent_error_mode"
    $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
    $null = $client.Handle
    $null = Wait-ProgressLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $ready = Wait-ProgressLine $clientLog "$($mark)client ready map=(l01_escape|l05_bar)\s*$" 60
    $map = $ready.Matches[0].Groups[1].Value

    $keeper = Wait-ProgressLine $worldLog "$($mark)keeper ready peer=([1-9]\d{0,4}) character=([1-9]\d{0,4})\s*$" 60
    $peer = [int]$keeper.Matches[0].Groups[1].Value
    $character = [int]$keeper.Matches[0].Groups[2].Value
    if ($peer -ge 65535 -or $character -ge 65535) { throw 'invalid guest identity' }
    $guest = "peer=$peer character=$character"
    Set-ProgressStep 'walk'
    $null = Wait-ProgressLine $clientLog "$($mark)client walked 15 steps, 300\.0 m\s*$" 60
    Set-ProgressStep 'spawn'
    $body = Wait-ProgressLine $mapLogs "$($mark)corpse map=$map id=([1-9]\d{0,4})\s*$" 30
    $id = [int]$body.Matches[0].Groups[1].Value
    if ($id -ge 65535) { throw 'invalid corpse id' }
    Set-ProgressStep "search $id"
    $search = Wait-ProgressLine $clientLog "$($mark)client searched id=$id xp=(\d{1,10}\.\d{6}) delta=(\d{1,10}\.\d{6})\s*$" 45
    $xp = $search.Matches[0].Groups[1].Value
    $delta = [double]::Parse($search.Matches[0].Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($delta -le 25) { throw "search XP $delta fits the unconditional allowance" }
    $facts = Wait-ProgressLine $worldLog "$($mark)keeper facts $guest step_m=(\d{1,7}\.\d) corpse_search=[1-9]\d* rank=veteran\s*$" 60 $keeper.LineNumber
    $meters = [double]::Parse($facts.Matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($meters -le 0) { throw 'the keeper observed no movement' }
    $xpPattern = [regex]::Escape($xp)
    Set-ProgressStep "honest $xp"
    $honest = Wait-ProgressLine $worldLog "$($mark)honest accepted $guest xp=$xpPattern checked=[1-9]\d* failed=0 refused=0\s*$" 30 $facts.LineNumber
    $sent = Wait-ProgressLine $clientLog "$($mark)client honest report xp=$xpPattern\s*$" 5 $search.LineNumber

    Set-ProgressStep 'skills'
    $skills = Wait-ProgressLine $worldLog "$($mark)skills budget failed $guest delta=5000\s*$" 30 $honest.LineNumber
    $inflated = Wait-ProgressLine $clientLog "$($mark)client added 5000 scavenging XP and reported\s*$" 5 $sent.LineNumber
    $beforeRank = @(Get-Content -LiteralPath $worldLog).Count
    Set-ProgressStep 'rank'
    $rank = "\[coop-trust\] progress_rank would refuse: peer $peer, character ${character}: rank -?\d+ -> -?\d+ \(\+5000\), budget "
    $null = Wait-ProgressLine $worldLog $rank 30 $beforeRank
    $null = Wait-ProgressLine $clientLog "$($mark)client added 5000 rank\s*$" 5 $inflated.LineNumber
}
catch {
    Write-Host ('progress_server: FAIL ({0})' -f (Hide-Hex "$_"))
    throw
}
finally {
    try {
        if ($client -and -not $client.HasExited) {
            Stop-Process -Id $client.Id -Force
            $null = $client.WaitForExit(5000)
        }
        if ($world -and -not $world.HasExited) {
            $world.StandardInput.WriteLine('quit')
            $world.StandardInput.Flush()
            if (-not $world.WaitForExit(150000)) {
                $world.Kill()
                throw 'the world server did not quit'
            }
        }
    }
    finally {
        foreach ($path in $installed) { Remove-StandFile -Path $path }
        if ($started) {
            Keep-ProgressLog $worldLog 'world'
            Keep-ProgressLog $clientLog 'client'
            for ($i = 0; $i -lt $mapLogs.Count; $i++) { Keep-ProgressLog $mapLogs[$i] "ms$($i + 1)" }
        }
    }
}
Write-Host 'progress_server: PASS'
