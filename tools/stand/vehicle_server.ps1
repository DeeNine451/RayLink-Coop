# Dev 57 F5-VEH-7, Server. The client's map server decides the seat and simulates the car.
# Run on the prepared stand through tools\stand_srv.ps1.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27999,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')

$ascii = [Text.Encoding]::ASCII
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_vehicle.script'
$stepFile = Join-Path $Stand 'zz_vehicle_step.txt'
$stageName = 'zz_vehicle_stage_' + [Guid]::NewGuid().ToString('N') + '.ltx'
$stage = Join-Path $Stand "appdata_server\$stageName"
$logName = "logs\xray_$($env:USERNAME).log"
$worldLog = Join-Path $Stand "appdata_server\$logName"
$clientLog = Join-Path $Stand "appdata_t\$logName"
$mapLogs = @(1..7 | ForEach-Object { Join-Path $Stand "appdata_ms$_\$logName" })
$logs = @($worldLog, $clientLog) + $mapLogs
$world = $client = $null
$installed = [Collections.Generic.List[string]]::new()
$started = $false
$scenario = 'vehicle_server'
$step = 'setup'
$mark = '\[vehicle-stand\] '
$badLine = "$($mark)FAIL\b"
$seatTable = '\[coop\]\s+vehicles: \d+ seated in \d+ car\(s\) \[car/seat=character:'

function Set-VehicleStep([string]$Instruction) {
    $script:step = ($Instruction -split ' ', 2)[0]
    Write-StandText -Path $stepFile -Text ($Instruction + [Environment]::NewLine) -Encoding $ascii
}

function Wait-VehicleLine([string[]]$Files, [string]$Pattern, [int]$Seconds, [int]$After = 0, [switch]$AfterQuit) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($world -and $world.HasExited) { throw "world server exited ($($world.ExitCode))" }
        if (-not $AfterQuit -and $client -and $client.HasExited) { throw "test client exited ($($client.ExitCode))" }
        foreach ($log in $logs) {
            if (Test-Path -LiteralPath $log -PathType Leaf) {
                $bad = Select-StandLogLine $log $badLine -Live | Select-Object -First 1
                if ($bad) { throw (Hide-Hex $bad.Line) }
            }
        }
        foreach ($file in $Files) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $hit = Select-String -LiteralPath $file -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
                if ($hit) { return $hit }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $($Files -join ', ')"
}

function Wait-VehicleSeatTable([string]$Label, [string]$Rows, [string]$Tail = '') {
    $marker = Wait-VehicleLine $authorityLog "$mark$Label status\s*$" 20
    $null = Wait-VehicleLine $authorityLog "$seatTable$Rows[^\]]*\]$Tail" 5 $marker.LineNumber
}

function Wait-VehicleGrant([int]$Seat, [string]$Label) {
    $asked = Wait-VehicleLine $clientLog "$($mark)client asked $Label seat=$Seat\s*$" 10
    $grant = Wait-VehicleLine $clientLog "\[coop\] vehicle: car $car seat $Seat granted\b" 5 $asked.LineNumber
    Wait-VehicleLine $clientLog "$($mark)client $Label seat=$Seat car=$car\s*$" 5 $grant.LineNumber
}

function Keep-VehicleLog([string]$File, [string]$Label) {
    if (Test-Path -LiteralPath $File -PathType Leaf) {
        Copy-StandFile -From $File -To (Join-Path $script:StandDir "$($Tag)_$($scenario)_$Label.log")
        Select-StandLogLine $File "$mark|\[coop\]\s+vehicles?:|$badLine" |
            ForEach-Object { Write-Host (Hide-Hex $_.Line) }
    }
}

try {
    try {
        if ($Stand -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
        Assert-NoJunction -Dir $Stand
        if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
        if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
        if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx') -PathType Leaf)) { throw 'no prepared fsgame_t.ltx' }
        foreach ($path in @($probe, $stepFile, $stage, "$stage.used")) {
            if (Test-Path -LiteralPath $path) { throw "scenario file already exists: $path" }
        }
        foreach ($log in $logs) { Remove-StandFile -Path $log }
        $installed.Add($probe)
        Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_vehicle.script') -To $probe
        $installed.Add($stepFile)
        Set-VehicleStep 'ready'
        $installed.Add($stage)
        $installed.Add("$stage.used")
        $stageText = @('[world]', 'faction = stalker', 'title = vehicle-stand', '') -join [Environment]::NewLine
        Write-StandText -Path $stage -Text $stageText -Encoding $ascii

        $step = 'world_start'
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $exe
        $psi.WorkingDirectory = $Stand
        $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stageName -coop_probe vehicle_world -silent_error_mode -dbg"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $world = [Diagnostics.Process]::Start($psi)
        $started = $true
        $null = Wait-VehicleLine $worldLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS

        $step = 'join'
        $clientArgs = "-fsltx fsgame_t.ltx -coop_nick vehicle_tester -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe vehicle_ag -silent_error_mode"
        $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
        $null = $client.Handle
        $null = Wait-VehicleLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
        $ready = Wait-VehicleLine $clientLog "$($mark)client ready map=([a-z0-9_]+)\s*$" 60
        $placed = Wait-VehicleLine $clientLog "$($mark)client placed pos=((-?\d+\.\d+ ){2}-?\d+\.\d+)\s*$" 5
        $map = [regex]::Escape($ready.Matches[0].Groups[1].Value)
        $authority = Wait-VehicleLine $mapLogs "$($mark)map ready map=$map\s*$" 60
        $authorityLog = $authority.Path

        Set-VehicleStep ('spawn ' + $placed.Matches[0].Groups[1].Value)
        $spawn = Wait-VehicleLine $authorityLog "$($mark)spawned car=(\d{1,5}) body=(\d{1,5}) distance=[\d.]+\s*$" 45
        $car = [int]$spawn.Matches[0].Groups[1].Value
        $body = [int]$spawn.Matches[0].Groups[2].Value
        if ($car -le 0 -or $car -ge 65535 -or $body -le 0 -or $body -ge 65535) { throw 'invalid fixture IDs' }
        $driverRow = "(?=[^\]]* $car/0=$body(?= |\]))"
        $passengerRow = "(?=[^\]]* $car/1=$body(?= |\]))"
        $noDriver = "(?![^\]]* $car/0=)"
        $noPassenger = "(?![^\]]* $car/1=)"
        $emptyCar = "(?![^\]]* $car/\d+=)"

        Set-VehicleStep "online $car"
        $null = Wait-VehicleLine $clientLog "$($mark)client online car=$car local=\d+\s*$" 30

        Set-VehicleStep 'driver'
        $driverSeat = Wait-VehicleGrant 0 'seated'
        Set-VehicleStep 'prepare'
        Wait-VehicleSeatTable 'driver' $driverRow

        Set-VehicleStep 'drive'
        $null = Wait-VehicleLine $clientLog '\[coop\] vehicle: drive 0x0001 for 3000 ms\s*$' 10 $driverSeat.LineNumber
        Start-Sleep -Milliseconds 3000
        Set-VehicleStep 'drive_sample'
        $null = Wait-VehicleLine $authorityLog "$($mark)drive moved=[\d.]+ pos=" 10
        Start-Sleep -Milliseconds 1000
        Set-VehicleStep 'replica_sample'
        $sample = Wait-VehicleLine $authorityLog "$($mark)authority pos=((-?\d+\.\d+ ){2}-?\d+\.\d+)\s*$" 10
        Set-VehicleStep ('replica ' + $sample.Matches[0].Groups[1].Value)
        $null = Wait-VehicleLine $clientLog "$($mark)replica pos=.* delta=[\d.]+\s*$" 10

        Set-VehicleStep 'driver_exit'
        $null = Wait-VehicleLine $clientLog "\[coop\] vehicle: out of car $car seat 0 \(exit\)" 10 $driverSeat.LineNumber
        $null = Wait-VehicleLine $clientLog "$($mark)client exited seat=0 distance=" 10
        Set-VehicleStep 'driver_clear'
        Wait-VehicleSeatTable 'driver exit' $emptyCar '.*\breleased 1 \(exit 1\)'

        Set-VehicleStep 'passenger_prepare'
        $null = Wait-VehicleLine $authorityLog "$($mark)map passenger ready car=$car\s*$" 10
        Wait-VehicleSeatTable 'empty' $emptyCar
        Set-VehicleStep 'passenger'
        $passengerSeat = Wait-VehicleGrant 1 'seated'
        Set-VehicleStep 'passenger_status'
        Wait-VehicleSeatTable 'passenger' ($noDriver + $passengerRow)

        Set-VehicleStep 'passenger_exit'
        $null = Wait-VehicleLine $clientLog "\[coop\] vehicle: out of seat 1 of car $car \(a passenger\)" 10 $passengerSeat.LineNumber
        $null = Wait-VehicleLine $clientLog "$($mark)client exited seat=1 distance=" 10
        Set-VehicleStep 'passenger_clear'
        Wait-VehicleSeatTable 'passenger exit' $noPassenger '.*\breleased 2 \(exit 2\)'

        Set-VehicleStep 'reboard'
        $quitSeat = Wait-VehicleGrant 1 'reboarded'
        Set-VehicleStep 'reboard_status'
        Wait-VehicleSeatTable 'reboard' $passengerRow

        Set-VehicleStep 'quit'
        $null = Wait-VehicleLine $clientLog "$($mark)client quit seat=1\s*$" 10 $quitSeat.LineNumber -AfterQuit
        if (-not $client.WaitForExit(15000)) { throw 'test client did not quit' }
        if ($client.ExitCode -ne 0) { throw "test client failed to quit cleanly ($($client.ExitCode))" }

        Set-VehicleStep 'disconnect'
        $marker = Wait-VehicleLine $authorityLog "$($mark)disconnect status\s*$" 30 -AfterQuit
        $released = Wait-VehicleLine $authorityLog "$seatTable$noPassenger[^\]]*\].*\breleased 3 \((?<reasons>[^)]+)\)" 20 $marker.LineNumber -AfterQuit
        $reasons = $released.Matches[0].Groups['reasons'].Value
        if ($reasons -notmatch '(?:^|, )disconnect 1(?:, |$)') {
            throw "expected disconnect 1 for the released seat, got '$reasons'"
        }
    }
    finally {
        try {
            if ($client -and -not $client.HasExited) {
                Stop-Process -Id $client.Id -Force
                if (-not $client.WaitForExit(5000)) { throw 'test client did not stop' }
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
                Keep-VehicleLog $worldLog 'world'
                Keep-VehicleLog $clientLog 'client'
                for ($i = 0; $i -lt $mapLogs.Count; $i++) { Keep-VehicleLog $mapLogs[$i] "ms$($i + 1)" }
            }
        }
    }
}
catch {
    Write-Host ('vehicle_server: FAIL {0} ({1})' -f $step, (Hide-Hex "$_"))
    throw
}
Write-Host 'vehicle_server: PASS'
