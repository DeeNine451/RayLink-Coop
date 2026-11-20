# Dev 57 F5-COV-4, Server. The world runs the clock and the player's map server judges cover.
# Run on the prepared stand through tools\stand_srv.ps1 after integration.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27997,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\tools\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
if ($Stand -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
Assert-NoJunction -Dir $Stand

$ascii = [Text.Encoding]::ASCII
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_cover.script'
$stepFile = Join-Path $Stand 'zz_cover_step.txt'
$stageName = 'zz_cover_stage_' + [Guid]::NewGuid().ToString('N') + '.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
$logName = "logs\xray_$($env:USERNAME).log"
$worldLog = Join-Path $Stand "appdata_server\$logName"
$clientLog = Join-Path $Stand "appdata_t\$logName"
$mapLogs = @(1..7 | ForEach-Object { Join-Path $Stand "appdata_ms$_\$logName" })
$logs = @($worldLog, $clientLog) + $mapLogs
$world = $client = $null
$installed = [Collections.Generic.List[string]]::new()
$started = $false
$mark = '\[cover-stand\] '
$outside = "$($mark)env_cover: cover_tester open\s*$"
$static = "$($mark)env_cover: cover_tester covered \(static\)\s*$"
$trust = '\[coop-trust\] (?:! )?env_cover\b(?=.*\bcover_tester\b).*(?:would refuse|would be refused: let through)'
# The probe deliberately claims cover while the level sees none in log-only mode.
$expectedTrust = '^\s*(?:\[[0-9:.]+\] +)?\[coop-trust\] ! env_cover: cover_tester claims cover, the level sees none \([^()]*, score -?\d+\.\d+\) \(would be refused: let through, \d+ of \d+ failed\)\s*$'
$badLine = "$($mark)FAIL\b|\[coop\] emission: cover_tester .*kill sent"

function Set-CoverStep([string]$Step) {
    Write-StandText -Path $stepFile -Text ($Step + [Environment]::NewLine) -Encoding $ascii
}

function Wait-CoverLine([string[]]$Files, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        foreach ($proc in @($world, $client)) {
            if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
        }
        foreach ($log in $logs) {
            if (Test-Path -LiteralPath $log -PathType Leaf) {
                $bad = Select-StandLogLine $log $badLine | Where-Object Line -NotMatch $expectedTrust | Select-Object -First 1
                if ($bad) { throw (Hide-Hex $bad.Line) }
            }
        }
        foreach ($file in $Files) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $hit = Select-String -LiteralPath $file -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
                if ($hit) { return $hit }
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $($Files -join ', ')"
}

function Keep-CoverLog([string]$File, [string]$Label) {
    if (Test-Path -LiteralPath $File -PathType Leaf) {
        Copy-StandFile -From $File -To (Join-Path $script:StandDir "$($Tag)_cover_server_$Label.log")
        Select-StandLogLine $File "$mark|$trust|$badLine" | ForEach-Object {
            $line = $_.Line
            if ($line -match $expectedTrust) { $line = $line -replace '\[coop-trust\] ! ', '[coop-trust] ' }
            Write-Host (Hide-Hex $line)
        }
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
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_cover.script') -To $probe
    $installed.Add($stepFile)
    Set-CoverStep 'ready'
    $installed.Add($stage)
    $installed.Add("$stage.used")
    $stageText = @('[world]', 'faction = stalker', 'title = emission-cover', '') -join [Environment]::NewLine
    Write-StandText -Path $stage -Text $stageText -Encoding $ascii

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Stand
    $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stageName -coop_probe coverworld -silent_error_mode -dbg"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $world = [Diagnostics.Process]::Start($psi)
    $started = $true
    $null = Wait-CoverLine $worldLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS

    $clientArgs = "-fsltx fsgame_t.ltx -coop_nick cover_tester -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe coverclient -silent_error_mode"
    $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
    $null = $client.Handle
    $null = Wait-CoverLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $ready = Wait-CoverLine $clientLog "$($mark)client ready map=(l01_escape|l05_bar) shelter=(?:esc|bar)_\w+\s*$" 60
    $map = $ready.Matches[0].Groups[1].Value
    $authority = Wait-CoverLine $mapLogs "$($mark)map ready map=$map\s*$" 60
    $mapLog = $authority.Path

    $world.StandardInput.WriteLine('run_string coop_zz_cover.start_emission()')
    $world.StandardInput.Flush()
    $null = Wait-CoverLine $worldLog "$($mark)world started\s*$" 30
    $open = Wait-CoverLine $mapLog $outside 30 $authority.LineNumber
    Set-CoverStep 'inside'
    $covered = Wait-CoverLine $mapLog $static 30 $open.LineNumber
    Set-CoverStep 'outside'
    $openAgain = Wait-CoverLine $mapLog $outside 30 $covered.LineNumber
    Set-CoverStep 'claim'
    $null = Wait-CoverLine $clientLog "$($mark)client sent cover claim\s*$" 30
    $refusal = Wait-CoverLine $mapLog $trust 30 $openAgain.LineNumber
    $null = Wait-CoverLine $mapLog "$($mark)env_cover: cover_tester covered \(report\)\s*$" 30 $refusal.LineNumber
    Set-CoverStep 'kill'
    $null = Wait-CoverLine $mapLog "$($mark)map kill checked\s*$" 30
    Set-CoverStep 'check'
    $null = Wait-CoverLine $clientLog "$($mark)client alive after wave\s*$" 15
    Set-CoverStep 'skip'
    $world.StandardInput.WriteLine('run_string coop_zz_cover.skip_emission()')
    $world.StandardInput.Flush()
    $null = Wait-CoverLine $worldLog "$($mark)world skipped\s*$" 30
    $null = Wait-CoverLine $clientLog "$($mark)client done\s*$" 30
}
catch {
    Write-Host ('cover_server: FAIL ({0})' -f (Hide-Hex "$_"))
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
            Keep-CoverLog $worldLog 'world'
            Keep-CoverLog $clientLog 'client'
            for ($i = 0; $i -lt $mapLogs.Count; $i++) { Keep-CoverLog $mapLogs[$i] "ms$($i + 1)" }
        }
    }
}
Write-Host 'cover_server: PASS'
