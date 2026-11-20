# Dev 57 A-S7, Server. The staged creator makes ten personal map transitions; the other player stays live.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27993,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepTimeoutS = 600
)
. (Join-Path $PSScriptRoot 'ms_crash_server.ps1') -DefinitionsOnly -Stand $Stand -Port $Port -Tag $Tag `
    -UpTimeoutS $UpTimeoutS -JoinTimeoutS $JoinTimeoutS -StepTimeoutS $StepTimeoutS

Invoke-S7Scenario 'creator10_server' {
    param($ctx)
    Start-S7World $ctx
    $creator = Start-S7Client $ctx 's7move'
    Assert-S7Creator $ctx $creator
    $observer = Start-S7Observer $ctx
    $observerLevel = Get-S7PlayerLevel (Get-S7Status $ctx) $observer $s7From
    # Hold the vacated map warm for the return trips, subject to the engine's memory policy.
    Send-S7World $ctx 'srv_mapserver_linger 600'
    $worldId = $ctx.World.Id
    $firstLine = Get-S7LineCount $ctx.Logs.world
    for ($i = 1; $i -le 10; $i++) {
        $goal = if ($creator.Map -eq $s7From) { $s7To } else { $s7From }
        $creator = Complete-S7Trip $ctx $creator (Start-S7Trip $ctx $creator $goal)
        $seq = Set-S7Step $ctx 's7stay' 'sample'
        Assert-S7Player (Read-S7Sample $ctx $observer $seq) $observer $s7From `
            -ExpectedLevel $observerLevel -RequireAlive -SamePeer
        Assert-S7NoLoad $ctx $observer
        Write-Host "creator trip ${i}/10 arrived on $($creator.Map); observer stayed live on $s7From"
    }
    $moves = @(Select-String -LiteralPath $ctx.Logs.world -Pattern "\[coop\] 's7move' leaves for level '($s7From|$s7To)' \(a trip\), the world stays\s*$" |
        Where-Object LineNumber -gt $firstLine)
    if ($moves.Count -ne 10 -or $creator.Map -ne $s7From -or $ctx.World.Id -ne $worldId) {
        throw 'the world did not accept exactly ten round-trip map transitions in one session'
    }
    Assert-S7NoLoad $ctx $observer
    Write-Host '10 creator transitions, 0 observer loads'
}
