# Report RL-58GQ-G96T (2026-11-13, build 48): a world server died with "pure virtual function call" right after a player took
# Fanatic's stash trial. A world server this script owns, a test player on Cordon, and his game asks the host for the same
# effect his dialog asks for (coop_zz_fanat.script). Does the server live, and what does its log say?
#   powershell -ExecutionPolicy Bypass -File tools\stand\fanat_task.ps1 [-Port 27982] [-Tag b49]
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [int]$Port = 27982,
    [string]$Tag = 'tb',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$AfterS = 12
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link (TZ R21)
# Tracked in tools\stand (docs/MODES.md section 10): the probes come from this folder; logs and the stand's
# settings kept for the restore go to the repository's temp\stand (ignored: the run history).
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
if (Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx'))) { throw 'no fsgame_t.ltx: run auto_world.ps1 once' }
$serverLog = Join-Path $Stand ('appdata_server\logs\xray_' + $env:USERNAME + '.log')
$clientLog = Join-Path $Stand ('appdata_t\logs\xray_' + $env:USERNAME + '.log')
$msLog = Join-Path $Stand ('appdata_ms1\logs\xray_' + $env:USERNAME + '.log')
$scripts = Join-Path $Stand 'gamedata\scripts'
$probe = Join-Path $scripts 'coop_zz_tb.script'
foreach ($stale in @('coop_zz_npcprobe.script', 'coop_zz_lone.script')) { $p = Join-Path $scripts $stale; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p } }
foreach ($f in @($serverLog, $clientLog)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f } }
Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_tb.script') -To $probe

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
            if ($l.Length -gt 240) { $l = $l.Substring(0, 240) }
            Write-Host "  $l"
        }
    }
}

$stage = Join-Path $Stand 'appdata_server\coop_new_world.ltx'
Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = taskboard`n" -Encoding ([System.Text.Encoding]::ASCII)
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exe
$psi.WorkingDirectory = $Stand
$psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stage -silent_error_mode -dbg"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$server = [System.Diagnostics.Process]::Start($psi)
$in = [System.IO.StreamWriter]::new($server.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
$in.AutoFlush = $true
$in.NewLine = "`n"
Write-Host "server pid $($server.Id)"
$client = $null
try {
    if (-not (Wait-Log $serverLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS $server)) { throw 'the server did not come up' }
    Write-Host 'the session is up'
    $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_t.ltx -coop_nick tester -coop_autochoose stalker -coop_probe tb -coop_connect 127.0.0.1:$Port"
    $null = $client.Handle
    Write-Host "client pid $($client.Id)"
    if (-not (Wait-Log $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS $client)) {
        if ($client.HasExited) { Write-Host ("the client's process ended by itself: exit code {0} (0x{0:X8})" -f $client.ExitCode) }
        throw 'the client did not get into the world'
    }
    Write-Host 'the client is in the world'
    if (-not (Wait-Log $clientLog '\[tb\] available tasks' 200 $client)) { Write-Host '! the board answer did not come in 200 s' }
    $until = (Get-Date).AddSeconds($AfterS)
    while ((Get-Date) -lt $until -and -not $server.HasExited) { Start-Sleep -Seconds 2 }
    Write-Host ("server alive {0} s after the request: {1}{2}" -f $AfterS, (-not $server.HasExited), $(if ($server.HasExited) { ', exit code ' + $server.ExitCode + (' (0x{0:X8})' -f $server.ExitCode) } else { '' }))
    if (-not $server.HasExited) {
        # the server's own console: its offer counters
        foreach ($line in @('coop_debug on', 'coop_dbg lua coop_quests_offer.print_status()')) { $in.WriteLine($line); Start-Sleep -Seconds 4 }
    }
}
finally {
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
    if (-not $server.HasExited) {
        Start-Sleep -Seconds 4
        try { $in.WriteLine('quit'); $in.Close() } catch { }
        if (-not $server.WaitForExit(150000)) { Write-Host '! the server did not quit in 150 s: stopped by force'; Stop-Process -Id $server.Id -Force }
    }
    Start-Sleep -Seconds 2
    Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    Write-Host ("server exit code: {0}" -f $(if ($server.HasExited) { $server.ExitCode } else { 'still running' }))
    foreach ($pair in @(@($clientLog, 'client'), @($serverLog, 'server'), @($msLog, 'ms1'))) {
        if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $OutDir "${Tag}_board_$($pair[1]).log") -Force }
    }
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe }
}
Write-Host '--- client ---'
Show-Lines $clientLog '\[tb\]|host refused the offer|\[coop-quests\]\[offer\]|context: role|FATAL ERROR' 60
Write-Host '--- world server ---'
Show-Lines $serverLog '\[tb\]|\[coop-quests\]\[offer\]|far: |generate for|context: role|FATAL ERROR' 60
Write-Host '--- map server 1 ---'
Show-Lines $msLog '\[tb\]|\[coop-quests\]\[offer\]|context: role|FATAL ERROR' 30
