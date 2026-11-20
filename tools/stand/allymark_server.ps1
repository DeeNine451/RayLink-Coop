# Dev 57 SS. Start a dedicated world and two mirrors. One goes through a real
# level changer, the other checks the resulting PDA spot without following.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27994,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepsTimeoutS = 480
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = [System.IO.Path]::GetFullPath($Stand).TrimEnd('\')
foreach ($dir in @('E:\RayLinkGames\GAMMA\game', 'E:\Programs\RayLink', (Join-Path $env:APPDATA 'RayLink'))) {
    if ($Stand.Equals($dir, [StringComparison]::OrdinalIgnoreCase) -or
        $Stand.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'use a dedicated test stand' }
}
Assert-NoJunction -Dir $Stand
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }

$observerFs = Join-Path $Stand 'fsgame_t.ltx'
$moverFs = Join-Path $Stand 'fsgame_allymark.ltx'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_allymark.script'
$stageName = 'coop_allymark_stage.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
foreach ($owned in @($probe, $stage, "$stage.used", $moverFs)) {
    if (Test-Path -LiteralPath $owned) { throw "scenario file already exists: $owned" }
}
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$moverBin = Join-Path $Stand 'bin_allymark'
$moverExe = Join-Path $moverBin 'AnomalyCoopDX11AVX.exe'
$logLeaf = "logs\xray_$($env:USERNAME).log"
$serverLog = Join-Path $Stand "appdata_server\$logLeaf"
$observerLog = Join-Path $Stand "appdata_t\$logLeaf"
$moverLog = Join-Path $Stand "appdata_allymark\$logLeaf"
$logs = @{ world = $serverLog; observer = $observerLog; mover = $moverLog }

function Wait-Line([string]$File, [string]$Pattern, [int]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        foreach ($proc in @($server, $observer, $mover)) {
            if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
        }
        foreach ($path in $logs.Values) {
            if (Test-Path -LiteralPath $path) {
                $bad = Select-String -LiteralPath $path -Pattern '\[allymark\] FAIL:|FATAL ERROR|LUA error|(?-i:stack traceback)' | Select-Object -First 1
                if ($bad) { throw (Hide-Hex $bad.Line) }
            }
        }
        if (Test-Path -LiteralPath $File) {
            $line = Select-String -LiteralPath $File -Pattern $Pattern | Select-Object -Last 1
            if ($line) { return $line.Matches[0] }
        }
        Start-Sleep -Seconds 2
    }
    throw "timed out waiting for '$Pattern' in $File"
}

function Start-Mirror([string]$Exe, [string]$Fs, [string]$Role) {
    $p = Start-Process -FilePath $Exe -WorkingDirectory $Stand -WindowStyle Hidden -PassThru -ArgumentList `
        "-fsltx $Fs -coop_nick $Role -coop_probe $Role -coop_autochoose stalker -coop_connect 127.0.0.1:$Port"
    $null = $p.Handle
    return $p
}

$server = $observer = $mover = $null
$created = [System.Collections.Generic.List[string]]::new()
$runStarted = $false
try {
    $encoding = [System.Text.Encoding]::GetEncoding(1251)
    $text = [System.IO.File]::ReadAllText($observerFs, $encoding)
    $fsPattern = '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata_t\\'
    if ($text -notmatch $fsPattern) { throw 'fsgame_t.ltx does not reference appdata_t' }
    $created.Add($moverFs)
    Write-StandText -Path $moverFs -Text ($text -replace $fsPattern, '${1}appdata_allymark\') -Encoding $encoding
    Copy-StandTree -From (Join-Path $Stand 'appdata_t') -To (Join-Path $Stand 'appdata_allymark') `
        -ExcludeFiles @('coop_player.key', 'axr_options.ltx') -ExcludeDirs @('savedgames', 'logs', 'raylink', 'screenshots')

    # The game uses its executable directory to distinguish running instances.
    Get-ChildItem -LiteralPath (Join-Path $Stand 'bin') -File | ForEach-Object {
        Copy-StandFile -From $_.FullName -To (Join-Path $moverBin $_.Name)
    }

    foreach ($path in $logs.Values) { Remove-StandFile -Path $path }
    $runStarted = $true
    $created.Add($probe)
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_allymark.script') -To $probe
    $created.Add($stage)
    $created.Add("$stage.used")
    Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = allymark`n" -Encoding ([System.Text.Encoding]::ASCII)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Stand
    $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stageName -silent_error_mode -dbg"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $server = [System.Diagnostics.Process]::Start($psi)
    $null = Wait-Line $serverLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS
    $observer = Start-Mirror $exe 'fsgame_t.ltx' 'allyobserver'
    $null = Wait-Line $observerLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $mover = Start-Mirror $moverExe 'fsgame_allymark.ltx' 'allymover'
    $null = Wait-Line $moverLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $together = Wait-Line $observerLog '\[allymark\] both players on ([\w_]+)' $StepsTimeoutS
    $arrival = Wait-Line $moverLog '\[allymark\] mover arrived ([\w_]+) -> ([\w_]+)' $StepsTimeoutS
    $spot = Wait-Line $observerLog '\[allymark\] PDA spot confirmed: observer=([\w_]+) friend=([\w_]+) id=\d+' $StepsTimeoutS
    if ($together.Groups[1].Value -ne $arrival.Groups[1].Value -or
        $together.Groups[1].Value -ne $spot.Groups[1].Value -or
        $arrival.Groups[2].Value -ne $spot.Groups[2].Value -or
        $spot.Groups[1].Value -eq $spot.Groups[2].Value) { throw 'the mover and PDA spot disagree on the level change' }
    Write-Host $spot.Value
}
catch {
    Write-Host ('allymark: FAIL ({0})' -f (Hide-Hex "$_"))
    throw
}
finally {
    try {
        foreach ($proc in @($mover, $observer)) {
            if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
        }
        if ($server -and -not $server.HasExited) {
            $server.StandardInput.WriteLine('quit')
            $server.StandardInput.Flush()
            if (-not $server.WaitForExit(150000)) {
                $server.Kill()
                throw 'the world server did not quit'
            }
        }
    }
    finally {
        foreach ($path in $created) { Remove-StandFile -Path $path }
        if ($runStarted) {
            foreach ($name in $logs.Keys) {
                if (Test-Path -LiteralPath $logs[$name]) {
                    Copy-StandFile -From $logs[$name] -To (Join-Path $script:StandDir "${Tag}_allymark_$name.log")
                }
            }
        }
    }
}
Write-Host 'allymark: PASS'
