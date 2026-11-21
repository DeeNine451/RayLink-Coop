# Dev 57, Server (K-61). Run on the prepared stand from tools\stand\run_guarded.ps1.
# The map servers prove the recruit and arrival. The restarted world checks load_state.
# -DryRun checks the log parsing without opening a profile or starting a process.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1, 65535)][int]$Port = 27991,
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Tag = 'b57',
    [ValidateRange(1, 3600)][int]$UpTimeoutS = 900,
    [ValidateRange(1, 3600)][int]$JoinTimeoutS = 600,
    [ValidateRange(1, 3600)][int]$StepsTimeoutS = 600,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$readyPattern = '\[cmp-srv\] ready squad=(?<s>\d{1,5}) npc=(?<n>\d{1,5}) owner=(?<o>\d{1,5}) map=(?<map>[a-z0-9_]+)\s*$'
$savePattern = '\[coop\] autosave (?<name>coop_auto_[\w-]+) \(end of the session\) written in \d+ ms\s*$'

function Read-Fixture([string]$Line) {
    $match = [regex]::Match($Line, $readyPattern)
    if (-not $match.Success) { throw 'source map did not name its fixture' }
    $fixture = [pscustomobject]@{
        Squad = [int]$match.Groups['s'].Value
        Npc = [int]$match.Groups['n'].Value
        Owner = [int]$match.Groups['o'].Value
        Map = $match.Groups['map'].Value
    }
    if (@($fixture.Squad, $fixture.Npc, $fixture.Owner) | Where-Object { $_ -lt 1 -or $_ -ge 65535 }) {
        throw 'fixture ID outside the engine range'
    }
    return $fixture
}

function Get-ArrivalPattern($Fixture, [string]$Destination) {
    if ($Destination -eq $Fixture.Map) { throw 'client is still on the source map' }
    $map = [regex]::Escape($Destination)
    return "\[cmp-srv\] adopted squad=$($Fixture.Squad) npc=$($Fixture.Npc) owner=$($Fixture.Owner) map=$map distance=(?<distance>\d+(?:\.\d+)?)\s*$"
}

function Test-Arrival([string]$Line, [string]$Pattern) {
    $match = [regex]::Match($Line, $Pattern)
    if (-not $match.Success) { return $false }
    return [double]::Parse($match.Groups['distance'].Value, [Globalization.CultureInfo]::InvariantCulture) -le 5
}

if ($DryRun) {
    $fixture = Read-Fixture '[cmp-srv] ready squad=301 npc=401 owner=501 map=l01_escape'
    if ($fixture.Squad -ne 301 -or $fixture.Npc -ne 401 -or $fixture.Owner -ne 501 -or $fixture.Map -ne 'l01_escape') { throw 'fixture parse failed' }
    $rejected = $false
    try { $null = Read-Fixture '[cmp-srv] ready squad=65535 npc=401 owner=501 map=l01_escape' } catch { $rejected = $true }
    if (-not $rejected) { throw 'reserved ID accepted' }
    $pattern = Get-ArrivalPattern $fixture 'l02_garbage'
    $arrival = '[cmp-srv] adopted squad=301 npc=401 owner=501 map=l02_garbage distance=5.000'
    if (-not (Test-Arrival $arrival $pattern)) { throw '5 m boundary rejected' }
    if (Test-Arrival ($arrival -replace '5.000$', '5.001') $pattern) { throw 'out-of-range companion accepted' }
    if (Test-Arrival ($arrival -replace 'owner=501', 'owner=502') $pattern) { throw 'wrong owner accepted' }
    if (Test-Arrival ($arrival -replace 'squad=301', 'squad=302') $pattern) { throw 'wrong squad accepted' }
    if (Test-Arrival ($arrival -replace 'map=l02_garbage', 'map=l01_escape') $pattern) { throw 'source map accepted as arrival' }
    if ('[coop] autosave coop_auto_57-abcd_4 (end of the session) written in 172 ms' -notmatch $savePattern -or
        '[coop] autosave coop_auto_57-abcd_4 (a map server starts or stops) written in 172 ms' -match $savePattern) { throw 'wrong save evidence' }
    Write-Host 'companions_server dry run: 8 passed, 0 failed'
    return
}

. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
foreach ($path in @('E:\RayLinkGames\GAMMA\game', 'E:\Programs\RayLink', (Join-Path $env:APPDATA 'RayLink'))) {
    if (($Stand + '\').StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'use the game-dev stand' }
}
Assert-NoJunction -Dir $Stand
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_companions_srv.script'
$instruction = Join-Path $Stand 'zz_companions_srv.txt'
$stageName = 'zz_cmp_srv_' + [Guid]::NewGuid().ToString('N').Substring(0, 12) + '.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
$logName = 'logs\xray_' + $env:USERNAME + '.log'
$serverLog = Join-Path $Stand "appdata_server\$logName"
$clientLog = Join-Path $Stand "appdata_t\$logName"
$mapLogs = @(1..7 | ForEach-Object { Join-Path $Stand "appdata_ms$_\$logName" })
$logs = @($serverLog, $clientLog) + $mapLogs
$ascii = [Text.Encoding]::ASCII
$server = $null
$client = $null
$installed = $false
$restarting = $false

function Find-Line([string[]]$Paths, [string]$Pattern, [switch]$Errors) {
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $line = if ($Errors) { Select-StandLogLine $path $Pattern -Live | Select-Object -Last 1 }
            else { Select-String -LiteralPath $path -Pattern $Pattern | Select-Object -Last 1 }
            if ($line) { return $line }
        }
    }
}

function Wait-Evidence([string[]]$Paths, [string]$Pattern, [DateTime]$Deadline) {
    do {
        foreach ($process in @($server, $client)) {
            if ($process -and $process.HasExited) { throw "process $($process.Id) exited before '$Pattern' ($($process.ExitCode))" }
        }
        $failed = Find-Line $logs '\[cmp-srv\] FAIL\b' -Errors
        if ($failed) { throw (Hide-Hex $failed.Line) }
        $hit = Find-Line $Paths $Pattern
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $Deadline)
    throw "timed out waiting for '$Pattern'"
}

function Start-World([string]$WorldArgs) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Stand
    $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port $WorldArgs -silent_error_mode -dbg"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    return [Diagnostics.Process]::Start($psi)
}

function Stop-World([Diagnostics.Process]$World) {
    if ($World -and -not $World.HasExited) {
        $stdin = [IO.StreamWriter]::new($World.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false))
        $stdin.NewLine = "`n"
        try { $stdin.WriteLine('quit') } finally { $stdin.Dispose() }
        if (-not $World.WaitForExit(150000)) { throw 'world server did not shut down in 150 s' }
    }
    if ($World -and $World.ExitCode -ne 0) { throw "world server exited with $($World.ExitCode)" }
}

function Keep-Log([string]$Path, [string]$Role) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-StandFile -From $Path -To (Join-Path $script:StandDir "${Tag}_companions_server_$Role.log")
        Select-StandLogLine $Path '\[cmp-srv\]' -Last 12 | ForEach-Object { Write-Host (Hide-Hex $_.Line) }
    }
}

try {
    if (Get-Process -Name 'AnomalyCoop*', 'AnomalyDX*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
    if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
    foreach ($file in @($exe, (Join-Path $Stand 'fsgame_server.ltx'), (Join-Path $Stand 'fsgame_t.ltx'))) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "missing prepared stand file $file" }
    }
    if ((Test-Path -LiteralPath $probe) -or (Test-Path -LiteralPath $instruction)) { throw 'the companions probe is already installed' }
    foreach ($file in $logs) { Remove-StandFile -Path $file }
    $installed = $true
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_companions_srv.script') -To $probe
    Write-StandText -Path $instruction -Text "spawn`n" -Encoding $ascii
    Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = companions`n" -Encoding $ascii

    $server = Start-World "-coop_new -coop_stage $stageName"
    $up = '\[coop\] dedicated: the session is up on port ' + $Port + '\b'
    $null = Wait-Evidence $serverLog $up ([DateTime]::UtcNow.AddSeconds($UpTimeoutS))
    $clientArgs = "-fsltx fsgame_t.ltx -coop_nick cmp_srv -coop_autochoose stalker -coop_probe cmp_srv -coop_connect 127.0.0.1:$Port -silent_error_mode"
    $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -ArgumentList $clientArgs -PassThru -WindowStyle Hidden
    $null = $client.Handle
    $null = Wait-Evidence $clientLog '\[coop\] phase loading-world -> live' ([DateTime]::UtcNow.AddSeconds($JoinTimeoutS))
    $steps = [DateTime]::UtcNow.AddSeconds($StepsTimeoutS)
    $ready = Wait-Evidence $mapLogs $readyPattern $steps
    $fixture = Read-Fixture $ready.Line
    $identity = "squad=$($fixture.Squad) npc=$($fixture.Npc) owner=$($fixture.Owner)"
    $from = $fixture.Map
    $inputIds = "$($fixture.Squad) $($fixture.Npc) $($fixture.Owner) $from"
    Write-StandText -Path $instruction -Text "travel $inputIds`n" -Encoding $ascii

    $null = Wait-Evidence $mapLogs "\[cmp-srv\] talk npc=$($fixture.Npc) owner=$($fixture.Owner) map=$from\s*$" $steps
    $null = Wait-Evidence $mapLogs "\[cmp-srv\] recruited $identity map=$from\s*$" $steps
    $null = Wait-Evidence $clientLog "\[cmp-srv\] entered exit map=$from\s*$" $steps
    $arrived = Wait-Evidence $clientLog '\[cmp-srv\] client arrived map=(?<map>[a-z0-9_]+)\s*$' $steps
    $to = $arrived.Matches[0].Groups['map'].Value
    $arrivalDeadline = [DateTime]::UtcNow.AddSeconds(90)
    $pattern = Get-ArrivalPattern $fixture $to
    $adopted = Wait-Evidence $mapLogs $pattern $arrivalDeadline
    if (-not (Test-Arrival $adopted.Line $pattern)) { throw 'adopted squad was farther than 5 m' }
    $null = Wait-Evidence $clientLog "\[cmp-srv\] client sees npc=$($fixture.Npc) map=$to\s*$" $arrivalDeadline

    # An exact save written by this process. A stale 'last' cannot satisfy the restart.
    Stop-World $server
    $saved = Find-Line $serverLog $savePattern
    if (-not $saved) { throw 'world server did not write its shutdown save' }
    $save = $saved.Matches[0].Groups['name'].Value
    if (-not (Test-Path -LiteralPath (Join-Path $Stand "appdata_server\savedgames\$save.scop") -PathType Leaf)) {
        throw "no companion world sidecar for $save"
    }
    if (-not $client.HasExited) { Stop-Process -Id $client.Id -Force }
    $client = $null
    Keep-Log $serverLog 'world_before'
    Remove-StandFile -Path $serverLog
    $restarting = $true
    Write-StandText -Path $instruction -Text "reload $inputIds $to`n" -Encoding $ascii
    $server = Start-World "-coop_load $save"
    $upDeadline = [DateTime]::UtcNow.AddSeconds($UpTimeoutS)
    $null = Wait-Evidence $serverLog $up $upDeadline
    $null = Wait-Evidence $serverLog "\[cmp-srv\] loaded $identity\s*$" $upDeadline
    Stop-World $server
} catch {
    Write-Host ("companions_server: FAIL ({0})" -f (Hide-Hex "$_"))
    throw
} finally {
    if ($installed) {
        try {
            if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
            if ($server -and -not $server.HasExited) {
                try { Stop-World $server } catch { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
            }
            Keep-Log $serverLog $(if ($restarting) { 'world_after' } else { 'world_before' })
            Keep-Log $clientLog 'client'
            for ($i = 0; $i -lt $mapLogs.Count; $i++) { Keep-Log $mapLogs[$i] "ms$($i + 1)" }
        } finally {
            foreach ($file in @($probe, $instruction, $stage, "$stage.used")) { Remove-StandFile -Path $file }
        }
    }
}
Write-Host 'companions_server: PASS'
