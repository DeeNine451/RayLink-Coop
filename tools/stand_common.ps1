# Shared part of tools\stand_hostplay.ps1 and tools\stand_srv.ps1 (dot-sourced): deploy HEAD's gamedata to the stand
# (tools\stand\stand_head.py: refused while either working tree has a product change or a scenario differs from HEAD),
# run the scenarios of tools\stand (tracked) through tools\stand\run_guarded.ps1, judge each scenario's output (the
# outputs go to temp\stand, the run history), check that the stand still holds HEAD's gamedata and nothing moved, and
# write the gate mark temp\gates\<mode>.ok on success.
# A mark: mode, mod_head, engine_head (the HEAD ids of both repositories), exe and exe_sha256 (the stand's exe), time,
# scenarios, dirty (product files changed or untracked, not committed, when the stand ran), scenarios_sha256 (the
# scenario files that ran) and gamedata_sha256 (the gamedata deployed). tools\check_gates.py reads it and counts a mark
# only with dirty=0, every scenario of the runner (check_gates.SCENARIOS) and both digests equal to HEAD's.
# PowerShell 5.1, ASCII only.

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:StandDir = Join-Path $script:Root 'temp\stand'
$script:ScenarioDir = Join-Path $script:Root 'tools\stand'
$script:HeadTool = Join-Path $script:ScenarioDir 'stand_head.py'
$script:MarkDir = Join-Path $script:Root 'temp\gates'

# error lines a scenario may print that are known and harmless (anything else fails the scenario)
$script:AllowedErrors = @(
    'asks to leave through level exit .* ignored',
    'map servers: this PC has .* free \(under .*\): an empty map server does not linger'
)
$script:ErrorPattern = 'FATAL ERROR|LUA error|stack traceback|! \[coop'

function Hide-Hex([string]$text) { return ($text -replace '[0-9a-fA-F]{32,}', '<hidden>') }

function Invoke-Scenario {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Scenario,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Stand
    )
    $name = $Scenario.Name
    $out = "${Tag}_stand_$name.out"
    $outPath = Join-Path $script:StandDir $out
    $scArgs = $Scenario.Args
    if ($Scenario.TagArg) { $scArgs = "$scArgs -Tag $Tag" }
    if ($Scenario.StandArg) { $scArgs = "$scArgs $($Scenario.StandArg) `"$Stand`"" }
    Write-Host ("=== {0} ({1:HH:mm:ss}): {2} {3}" -f $name, (Get-Date), $Scenario.Script, $scArgs)
    $guard = Join-Path $script:ScenarioDir 'run_guarded.ps1'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard -Script $Scenario.Script -Out $out -ScriptArgs $scArgs -Stand $Stand -OutDir $script:StandDir
    $problems = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $outPath)) {
        $problems.Add('no output file')
        return [pscustomobject]@{ Name = $name; Ok = $false; Problems = $problems; Out = $outPath }
    }
    $lines = @(Get-Content -LiteralPath $outPath -Encoding UTF8)
    $text = $lines -join "`n"
    foreach ($p in $Scenario.Pass) {
        if ($text -notmatch $p) { $problems.Add("pass line missing: $p") }
    }
    foreach ($p in $Scenario.Bad) {
        $hit = $lines | Where-Object { $_ -match $p } | Select-Object -First 1
        if ($hit) { $problems.Add('bad line: ' + (Hide-Hex $hit.Trim())) }
    }
    foreach ($l in $lines) {
        if ($l -match $script:ErrorPattern) {
            $allowed = $false
            foreach ($a in $script:AllowedErrors) { if ($l -match $a) { $allowed = $true; break } }
            if (-not $allowed) { $problems.Add('error line: ' + (Hide-Hex $l.Trim())) }
        }
    }
    $err = $outPath + '.err'
    if ((Test-Path -LiteralPath $err) -and (Get-Item -LiteralPath $err).Length -gt 0) {
        $first = Get-Content -LiteralPath $err | Select-Object -First 1
        $problems.Add('stderr: ' + (Hide-Hex "$first"))
    }
    $guardLine = $lines | Where-Object { $_ -match '^GUARD:' } | Select-Object -First 1
    if ($guardLine) { $problems.Add($guardLine) }
    $ok = $problems.Count -eq 0
    if ($ok) { Write-Host "  PASS $name" } else { Write-Host "  FAIL $name"; foreach ($p in $problems) { Write-Host "    $p" } }
    return [pscustomobject]@{ Name = $name; Ok = $ok; Problems = $problems; Out = $outPath }
}

function Get-DirtyProductCount {
    $n = 0
    foreach ($pair in @(@($script:Root, @('gamedata', 'gamedata_gamma')), @((Join-Path $script:Root 'engine'), @('src', 'gamedata')))) {
        $repo = $pair[0]
        $paths = $pair[1]
        # untracked files count too: a new script deployed to the stand but never committed is not in HEAD's build
        $lines = & git -C $repo -c core.quotePath=false status --porcelain --untracked-files=all -- $paths 2>$null
        $n += @($lines | Where-Object { $_ }).Count
    }
    return $n
}

function Invoke-HeadTool {
    # tools\stand\stand_head.py deploy|check: its key=value lines as a hashtable; a refusal throws
    param([string]$Command, [string]$Stand, [string]$Backup)
    $toolArgs = @('-I', $script:HeadTool, $Command, '--stand', $Stand, '--root', $script:Root)
    if ($Backup) { $toolArgs += @('--backup', $Backup) }
    $out = @(& python @toolArgs)
    $code = $LASTEXITCODE
    foreach ($l in $out) { Write-Host "  $l" }
    if ($code -ne 0) { throw "stand_head $Command refused (exit $code): $(($out | Where-Object { $_ -match 'stand_head' }) -join ' ')" }
    $values = @{}
    foreach ($l in $out) { if ($l -match '^([a-z_0-9]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] } }
    foreach ($k in @('mod_head', 'engine_head', 'scenarios_sha256', 'gamedata_sha256')) {
        if (-not $values.ContainsKey($k)) { throw "stand_head $Command printed no $k" }
    }
    return $values
}

function Invoke-HeadDeploy {
    # refuses a dirty tree (product or scenario files); deploys HEAD's gamedata to the stand before any scenario
    param([Parameter(Mandatory = $true)][string]$Stand, [string]$Backup = (Join-Path $script:StandDir 'head_backup'))
    return Invoke-HeadTool -Command 'deploy' -Stand $Stand -Backup $Backup
}

function Invoke-HeadCheck {
    # after the scenarios: the stand still holds HEAD's gamedata and the tree is still clean
    param([Parameter(Mandatory = $true)][string]$Stand)
    return Invoke-HeadTool -Command 'check' -Stand $Stand
}

function Write-GateMark {
    # $Head: what Invoke-HeadDeploy deployed (both HEAD ids and the two digests)
    param([string]$Mode, [string]$Exe, [string[]]$Names, [Parameter(Mandatory = $true)][hashtable]$Head)
    New-Item -ItemType Directory -Force -Path $script:MarkDir | Out-Null
    $mark = Join-Path $script:MarkDir "$Mode.ok"
    $lines = @(
        "mode=$Mode",
        "mod_head=$($Head['mod_head'])",
        "engine_head=$($Head['engine_head'])",
        "exe=$Exe",
        "exe_sha256=$((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant())",
        "time=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))",
        "scenarios=$($Names -join ',')",
        "dirty=$(Get-DirtyProductCount)",
        "scenarios_sha256=$($Head['scenarios_sha256'])",
        "gamedata_sha256=$($Head['gamedata_sha256'])"
    )
    [System.IO.File]::WriteAllLines($mark, $lines, [System.Text.Encoding]::ASCII)
    Write-Host "mark written: $mark"
}

function Invoke-Stand {
    param([string]$Mode, [object[]]$Scenarios, [string]$Tag, [string]$Stand, [string[]]$Only, [switch]$NoMark)
    $exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "no stand exe: $exe" }
    $mark = Join-Path $script:MarkDir "$Mode.ok"
    if (Test-Path -LiteralPath $mark) { Remove-Item -LiteralPath $mark -Force } # an old mark never outlives a new run
    $picked = @($Scenarios | Where-Object { -not $Only -or $Only -contains $_.Name })
    if ($picked.Count -eq 0) { throw "no scenario picked (-Only $($Only -join ','))" }
    # the stand runs HEAD: refused while either working tree has a product change or a scenario differs from HEAD
    Write-Host "=== deploy HEAD's gamedata to $Stand"
    $head = Invoke-HeadDeploy -Stand $Stand
    $results = @()
    foreach ($s in $picked) { $results += Invoke-Scenario -Scenario $s -Tag $Tag -Stand $Stand }
    $failed = @($results | Where-Object { -not $_.Ok })
    Write-Host ''
    foreach ($r in $results) { Write-Host ("{0,-14} {1}" -f $r.Name, $(if ($r.Ok) { 'PASS' } else { 'FAIL' })) }
    if ($failed.Count -gt 0) {
        Write-Host "stand_${Mode}: FAIL ($($failed.Count) of $($results.Count))"
        return 1
    }
    if ($Only -or $NoMark) {
        Write-Host "stand_${Mode}: PASS (part of the stand: no mark written)"
        return 0
    }
    # nothing moved during the run: both HEADs, the scenario files, the stand's gamedata
    $after = Invoke-HeadCheck -Stand $Stand
    foreach ($k in @('mod_head', 'engine_head', 'scenarios_sha256', 'gamedata_sha256')) {
        if ($after[$k] -ne $head[$k]) {
            Write-Host "stand_${Mode}: FAIL ($k changed during the run: no mark written)"
            return 1
        }
    }
    Write-GateMark -Mode $Mode -Exe $exe -Names @($results | ForEach-Object { $_.Name }) -Head $head
    Write-Host "stand_${Mode}: PASS ($($results.Count) scenarios)"
    return 0
}
