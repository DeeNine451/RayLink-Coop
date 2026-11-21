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
$stepFile = Join-Path $Stand 'zz_feed_step.txt' # the probe's first leaves only once it says "go"
$stageName = 'coop_feed_stage.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
foreach ($owned in @($probe, $stage, "$stage.used", $secondFs, $stepFile)) {
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
# The world server starts the map servers (appdata_ms<slot>): their logs are kept too (b57i: a later scenario overwrote them).
$mapLogs = @(1..7 | ForEach-Object { Join-Path $Stand "appdata_ms$_\$logLeaf" })

function Wait-Line([string]$File, [string]$Pattern, [int]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        foreach ($entry in @(@{ p = $server; name = 'the world server' }, @{ p = $first; name = 'the first (feedfirst)' },
                @{ p = $second; name = 'the second (feedsecond)' })) {
            $proc = $entry.p
            # b57i: "stand process 17240 exited (-1073740940)" named neither the process nor 0xC0000374
            if ($proc -and $proc.HasExited) {
                throw ("{0}: stand process {1} exited ({2}, 0x{2:X8})" -f $entry.name, $proc.Id, $proc.ExitCode)
            }
        }
        foreach ($path in $logs.Values) {
            if (Test-Path -LiteralPath $path) {
                $bad = Select-StandLogLine $path '\[feed\] FAIL:' -Live | Select-Object -First 1
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
        "-fsltx $Fs -coop_nick $Role -coop_probe $Role -coop_autochoose dolg -coop_connect 127.0.0.1:$Port"
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

    foreach ($path in @($logs.Values) + $mapLogs) { Remove-StandFile -Path $path }
    $runStarted = $true
    $created.Add($probe)
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_feed.script') -To $probe
    $created.Add($stage)
    $created.Add("$stage.used")
    # Two players must start on one map: a Server world starts a new character at a random start of its faction
    # (b57 stand: stalker gave k00_marsh and l01_escape). Duty has one start, the Bar.
    Write-StandText -Path $stage -Text "[world]`nfaction = dolg`ntitle = feed`n" -Encoding ([System.Text.Encoding]::ASCII)

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
    # b57f-b57i: the world places the second's character on the start map while his machine still loads, and a first who saw
    # him "here" left then: the second's feed first saw him on the other map (a first sight makes no line) and no "went to"
    # came. The probe's first goes only on this word, written once the second is live and his world is up: his feed watch
    # compares only then (srv/coop_srv_join.cpp feed_frame), and "join complete" comes right after "world is up again".
    $null = Wait-Line $secondLog '\[coop\] join complete, live sync on' $JoinTimeoutS
    $created.Add($stepFile)
    Write-StandText -Path $stepFile -Text "go`n" -Encoding ([System.Text.Encoding]::ASCII)

    # 1. The first leaves: the second, still on the start map, reads where he went.
    $firstMove = Wait-Line $firstLog '\[feed\] first arrived ([\w_]+) -> ([\w_]+)' $StepsTimeoutS
    $start = $firstMove.Groups[1].Value
    $there = $firstMove.Groups[2].Value
    # A Server world starts each new character at any start of its faction: a first who joined on another map went once to
    # the second's map before (the probe's setup trip) and left it from there. The second may have read where he came from.
    $setupFrom = $null
    $gather = Select-String -LiteralPath $firstLog -Pattern '\[feed\] first joins the second on ([\w_]+) \(start ([\w_]+)\)' | Select-Object -Last 1
    if ($gather) {
        $joined = $gather.Matches[0].Groups
        if ($joined[1].Value -ne $start) { throw "the first joined the second on $($joined[1].Value), then left $start" }
        $setupFrom = $joined[2].Value
    }
    $went = Wait-Line $secondLog "\[srv\] feed: 'feedfirst' went to ([\w_]+) \(level \d+\)" $StepsTimeoutS
    if ($went.Groups[1].Value -ne $there) { throw "the second read 'went to $($went.Groups[1].Value)', the first is on $there" }
    foreach ($hit in @(Select-String -LiteralPath $secondLog -Pattern "\[srv\] feed: 'feedfirst' came from ([\w_]+)")) {
        # Only the setup trip brought the first onto the second's map.
        if (-not $setupFrom -or $hit.Matches[0].Groups[1].Value -ne $setupFrom) { throw 'the second read a came-from line of a map he is not on' }
    }

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
            for ($i = 0; $i -lt $mapLogs.Count; $i++) {
                if (Test-Path -LiteralPath $mapLogs[$i]) {
                    Copy-StandFile -From $mapLogs[$i] -To (Join-Path $script:StandDir "${Tag}_feed_ms$($i + 1).log")
                }
            }
        }
    }
}
Write-Host 'feed: PASS'
