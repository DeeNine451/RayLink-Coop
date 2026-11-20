# Dev 57 SS (A-S6J, S5 feed lines). Start a dedicated world and two players. The first takes a real level exit; the
# second, still on the start map, must log "went to <that map>". Then the second follows through the same exit; the
# first, already there, must log "came from <the start map>". The probe (coop_zz_feed.script) only moves; the engine
# writes the feed lines ("[srv] feed: '<nick>' went to <level> (level N)" / "came from").
# Co-op has no feed lines (the group moves together): no SC scenario.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27995,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepsTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
$common = Join-Path $PSScriptRoot '..\stand_common.ps1' # tools\stand\ once the lead moves it there
if (-not (Test-Path -LiteralPath $common)) { $common = Join-Path $PSScriptRoot '..\..\tools\stand_common.ps1' } # temp\stand\
. $common
$Stand = [System.IO.Path]::GetFullPath($Stand).TrimEnd('\')
foreach ($dir in @('E:\RayLinkGames\GAMMA\game', 'E:\Programs\RayLink', (Join-Path $env:APPDATA 'RayLink'))) {
    if ($Stand.Equals($dir, [StringComparison]::OrdinalIgnoreCase) -or
        $Stand.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'use a dedicated test stand' }
}
Assert-NoJunction -Dir $Stand
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }

$firstFs = Join-Path $Stand 'fsgame_t.ltx'
$secondFs = Join-Path $Stand 'fsgame_feed.ltx'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_feed.script'
$stageName = 'coop_feed_stage.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
foreach ($owned in @($probe, $stage, "$stage.used", $secondFs)) {
    if (Test-Path -LiteralPath $owned) { throw "scenario file already exists: $owned" }
}
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$secondBin = Join-Path $Stand 'bin_feed'
$secondExe = Join-Path $secondBin 'AnomalyCoopDX11AVX.exe'
$logLeaf = "logs\xray_$($env:USERNAME).log"
$serverLog = Join-Path $Stand "appdata_server\$logLeaf"
$firstLog = Join-Path $Stand "appdata_t\$logLeaf"
$secondLog = Join-Path $Stand "appdata_feed\$logLeaf"
$logs = @{ world = $serverLog; first = $firstLog; second = $secondLog }

function Wait-Line([string]$File, [string]$Pattern, [int]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        foreach ($proc in @($server, $first, $second)) {
            if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
        }
        foreach ($path in $logs.Values) {
            if (Test-Path -LiteralPath $path) {
                $bad = Select-String -LiteralPath $path -Pattern '\[feed\] FAIL:|FATAL ERROR|LUA error|stack traceback' | Select-Object -First 1
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

function Start-Player([string]$Exe, [string]$Fs, [string]$Role) {
    $p = Start-Process -FilePath $Exe -WorkingDirectory $Stand -WindowStyle Hidden -PassThru -ArgumentList `
        "-fsltx $Fs -coop_nick $Role -coop_probe $Role -coop_autochoose stalker -coop_connect 127.0.0.1:$Port"
    $null = $p.Handle
    return $p
}

$server = $first = $second = $null
$created = [System.Collections.Generic.List[string]]::new()
$runStarted = $false
try {
    $encoding = [System.Text.Encoding]::GetEncoding(1251)
    $text = [System.IO.File]::ReadAllText($firstFs, $encoding)
    $fsPattern = '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata_t\\'
    if ($text -notmatch $fsPattern) { throw 'fsgame_t.ltx does not reference appdata_t' }
    $created.Add($secondFs)
    Write-StandText -Path $secondFs -Text ($text -replace $fsPattern, '${1}appdata_feed\') -Encoding $encoding
    Copy-StandTree -From (Join-Path $Stand 'appdata_t') -To (Join-Path $Stand 'appdata_feed') `
        -ExcludeFiles @('coop_player.key', 'axr_options.ltx') -ExcludeDirs @('savedgames', 'logs', 'raylink', 'screenshots')

    # The game uses its executable directory to distinguish running instances.
    Get-ChildItem -LiteralPath (Join-Path $Stand 'bin') -File | ForEach-Object {
        Copy-StandFile -From $_.FullName -To (Join-Path $secondBin $_.Name)
    }

    foreach ($path in $logs.Values) { Remove-StandFile -Path $path }
    $runStarted = $true
    $created.Add($probe)
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_feed.script') -To $probe
    $created.Add($stage)
    $created.Add("$stage.used")
    Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = feed`n" -Encoding ([System.Text.Encoding]::ASCII)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Stand
    $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stageName -silent_error_mode -dbg"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $server = [System.Diagnostics.Process]::Start($psi)
    $null = Wait-Line $serverLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS
    $first = Start-Player $exe 'fsgame_t.ltx' 'feedfirst'
    $null = Wait-Line $firstLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $second = Start-Player $secondExe 'fsgame_feed.ltx' 'feedsecond'
    $null = Wait-Line $secondLog '\[coop\] phase loading-world -> live' $JoinTimeoutS

    # 1. The first leaves: the second, still on the start map, reads where he went.
    $firstMove = Wait-Line $firstLog '\[feed\] first arrived ([\w_]+) -> ([\w_]+)' $StepsTimeoutS
    $start = $firstMove.Groups[1].Value
    $there = $firstMove.Groups[2].Value
    $went = Wait-Line $secondLog "\[srv\] feed: 'feedfirst' went to ([\w_]+) \(level \d+\)" $StepsTimeoutS
    if ($went.Groups[1].Value -ne $there) { throw "the second read 'went to $($went.Groups[1].Value)', the first is on $there" }
    if (Select-String -LiteralPath $secondLog -Pattern "\[srv\] feed: 'feedfirst' came from" -Quiet) { throw 'the second read a came-from line of a map he is not on' }

    # 2. The second follows: the first, on that map, reads where he came from.
    $secondMove = Wait-Line $secondLog '\[feed\] second arrived ([\w_]+) -> ([\w_]+)' $StepsTimeoutS
    if ($secondMove.Groups[1].Value -ne $start -or $secondMove.Groups[2].Value -ne $there) {
        throw "the second went $($secondMove.Groups[1].Value) -> $($secondMove.Groups[2].Value), the first $start -> $there"
    }
    $came = Wait-Line $firstLog "\[srv\] feed: 'feedsecond' came from ([\w_]+) \(level \d+\)" $StepsTimeoutS
    if ($came.Groups[1].Value -ne $start) { throw "the first read 'came from $($came.Groups[1].Value)', the second left $start" }
    # A player's own move is no line of his own feed.
    foreach ($own in @(@{ log = $firstLog; nick = 'feedfirst' }, @{ log = $secondLog; nick = 'feedsecond' })) {
        if (Select-String -LiteralPath $own.log -Pattern "\[srv\] feed: '$($own.nick)'" -Quiet) { throw "$($own.nick) read a line of his own move" }
    }
    # The world server and its map servers have no feed (their actor is a ghost).
    if (Select-String -LiteralPath $serverLog -Pattern '\[srv\] feed:' -Quiet) { throw 'the world server wrote a feed line' }
    Write-Host ("feed: went to {0}, came from {1}" -f $there, $start)
}
catch {
    Write-Host ('feed: FAIL ({0})' -f (Hide-Hex "$_"))
    throw
}
finally {
    try {
        foreach ($proc in @($second, $first)) {
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
                    Copy-StandFile -From $logs[$name] -To (Join-Path $script:StandDir "${Tag}_feed_$name.log")
                }
            }
        }
    }
}
Write-Host 'feed: PASS'
