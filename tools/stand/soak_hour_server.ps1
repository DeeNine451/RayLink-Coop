# Dev 57 A-S7, Server. Long GAMMA batch on the prepared stand, separate from the short Server gate.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27992,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepTimeoutS = 600,
    [ValidateRange(10,60)][int]$SampleEveryS = 30,
    [ValidateRange(1024,8192)][int]$MapWorkingSetMiB = 1536
)
. (Join-Path $PSScriptRoot 'ms_crash_server.ps1') -DefinitionsOnly -Stand $Stand -Port $Port -Tag $Tag `
    -UpTimeoutS $UpTimeoutS -JoinTimeoutS $JoinTimeoutS -StepTimeoutS $StepTimeoutS

function Get-S7MemoryRow([Diagnostics.Process]$Process, [string]$Role, [string]$Map, [double]$Elapsed) {
    $Process.Refresh()
    if ($Process.HasExited) { throw "soak $Role process $($Process.Id) exited" }
    return [pscustomobject]@{
        ElapsedS = [int][Math]::Floor($Elapsed)
        UTC = [DateTime]::UtcNow.ToString('o')
        Role = $Role
        Map = $Map
        ProcessId = $Process.Id
        WorkingSetMiB = [Math]::Round($Process.WorkingSet64 / 1MB, 2)
        PrivateMiB = [Math]::Round($Process.PrivateMemorySize64 / 1MB, 2)
    }
}

function Write-S7MemoryRanges($Rows, [string[]]$Maps) {
    foreach ($map in $Maps) {
        $samples = @($Rows | Where-Object { $_.Role -eq 'map' -and $_.Map -eq $map })
        if (-not $samples.Count) { throw "no memory samples for $map" }
        $working = $samples | Measure-Object WorkingSetMiB -Minimum -Maximum
        $private = $samples | Measure-Object PrivateMiB -Minimum -Maximum
        $toGB = 1MB / 1e9
        Write-Host ('{0}: working set {1:F2}-{2:F2} MiB ({3:F3}-{4:F3} GB); private {5:F2}-{6:F2} MiB; target 1.1-1.5 GB working set' -f
            $map, $working.Minimum, $working.Maximum, ($working.Minimum * $toGB), ($working.Maximum * $toGB),
            $private.Minimum, $private.Maximum)
    }
}

Invoke-S7Scenario 'soak_hour_server' {
    param($ctx)
    $memory = [Collections.Generic.List[object]]::new()
    try {
        Start-S7World $ctx
        $mover = Start-S7Client $ctx 's7move'
        Assert-S7Creator $ctx $mover
        $observer = Start-S7Observer $ctx
        $mover = Complete-S7Trip $ctx $mover (Start-S7Trip $ctx $mover $s7To)
        $initial = Get-S7Status $ctx
        $expected = @{
            s7stay = Get-S7PlayerLevel $initial $observer $s7From
            s7move = Get-S7PlayerLevel $initial $mover $s7To
        }
        Assert-S7Player $observer $observer $s7From -ExpectedLevel $expected.s7stay -RequireAlive
        $mapA = Get-S7MapProcess $ctx $observer
        $mapB = Get-S7MapProcess $ctx $mover
        if ($mapA.Process.Id -eq $mapB.Process.Id) { throw 'both maps have the same process' }
        $null = Assert-S7Audit $ctx @($expected.Values)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $samples = 0
        $nextSample = 0
        do {
            Assert-S7Running $ctx
            $seq = Set-S7Step $ctx 'all' 'sample'
            $state = Get-S7Status $ctx
            foreach ($player in @($observer, $mover)) {
                if ((Get-S7PlayerLevel $state $player $player.Map) -ne $expected[$player.Role]) {
                    throw "the world moved $($player.Role) off the expected level ID"
                }
                Assert-S7Player (Read-S7Sample $ctx $player $seq) $player $player.Map `
                    -ExpectedLevel $expected[$player.Role] -RequireAlive -SamePeer
                Assert-S7NoLoad $ctx $player
            }
            $elapsed = $clock.Elapsed.TotalSeconds
            $memory.Add((Get-S7MemoryRow $ctx.World 'world' '-' $elapsed))
            foreach ($entry in @(@{ Map = $s7From; Process = $mapA.Process }, @{ Map = $s7To; Process = $mapB.Process })) {
                $row = Get-S7MemoryRow $entry.Process 'map' $entry.Map $elapsed
                $memory.Add($row)
                if ($row.WorkingSetMiB -gt $MapWorkingSetMiB) {
                    throw "$($row.Map) working set $($row.WorkingSetMiB) MiB exceeds $MapWorkingSetMiB MiB"
                }
            }
            $samples++
            if ($elapsed -ge 3600) { break }
            $nextSample = [Math]::Min(3600, $nextSample + $SampleEveryS)
            if ($elapsed -gt $nextSample + $SampleEveryS) { throw 'missed a scheduled memory sample' }
            while ($clock.Elapsed.TotalSeconds -lt $nextSample) {
                if ($mapA.Process.HasExited -or $mapB.Process.HasExited -or $ctx.World.HasExited) { throw 'a soak server exited' }
                Start-Sleep -Milliseconds 500
            }
        } while ($true)
        $null = Assert-S7Audit $ctx @($expected.Values)
        Assert-S7NoLoad $ctx $observer
        Assert-S7NoLoad $ctx $mover
        Write-Host "3600 s across two maps, $samples samples per process"
        Write-S7MemoryRanges $memory @($s7From, $s7To)
    } finally {
        if ($memory.Count) {
            $out = Join-Path $script:StandDir "${Tag}_soak_hour_server_memory.csv"
            Write-StandLines -Path $out -Lines ($memory | ConvertTo-Csv -NoTypeInformation) -Encoding ([Text.Encoding]::UTF8)
        }
    }
}
