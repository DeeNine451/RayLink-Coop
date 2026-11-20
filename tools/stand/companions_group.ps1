# Dev 57 / K-61, co-op. Run through tools\stand_hostplay.ps1 after integrating the scenario.
# -DryRun exercises the log verdict without touching the stand or starting a game.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [int]$Port = 27986,
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 900,
    [int]$JoinTimeoutS = 600,
    [int]$StepsTimeoutS = 600,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Test-CompanionTranscript([string[]]$HostLines, [string[]]$ClientLines, [int]$Npc, [int]$Peer) {
    $identity = "npc=$Npc peer=$Peer"
    $info = "npc=$Npc l=$Peer"
    return ($HostLines -match "\[companions\] h talk lock $identity\s*$") -and
           ($HostLines -match '\[companions\] h follow after 20 s level=l01_escape ') -and
           ($HostLines -match '\[companions\] h arrival level=l02_garbage ') -and
           ($HostLines -match "\[companions\] h PASS $identity\s*$") -and
           ($ClientLines -match "\[companions\] ag npc\.comp_info level=l01_escape $info\s*$") -and
           ($ClientLines -match '\[companions\] ag moved [0-9.]+ m after follow\s*$') -and
           ($ClientLines -match "\[companions\] ag npc\.comp_info level=l02_garbage $info\s*$") -and
           ($ClientLines -match "\[companions\] ag PASS $identity\s*$") -and
           -not (($HostLines + $ClientLines) -match '\[companions\] (h|ag) FAIL\b')
}

if ($DryRun) {
    $okHost = @(
        '[companions] h talk lock npc=201 peer=1',
        '[companions] h follow after 20 s level=l01_escape commander=(1,2,3) client=(4,5,6) distance=5.20',
        '[companions] h arrival level=l02_garbage commander=(1,2,3) client=(4,5,6) distance=5.20',
        '[companions] h PASS npc=201 peer=1'
    )
    $okClient = @(
        '[companions] ag npc.comp_info level=l01_escape npc=201 l=1',
        '[companions] ag moved 30.00 m after follow',
        '[companions] ag npc.comp_info level=l02_garbage npc=201 l=1',
        '[companions] ag PASS npc=201 peer=1'
    )
    if (-not (Test-CompanionTranscript $okHost $okClient 201 1)) { throw 'valid trajectory rejected' }
    if (Test-CompanionTranscript $okHost[1..3] $okClient 201 1) { throw 'absent talk lock accepted' }
    if (Test-CompanionTranscript $okHost $okClient[0,1,3] 201 1) { throw 'absent arrival ownership accepted' }
    if (Test-CompanionTranscript $okHost[0,2,3] $okClient 201 1) { throw 'absent follow measurement accepted' }
    $wrongLeader = @($okClient[0], $okClient[1], ($okClient[2] -replace 'l=1$', 'l=0'), $okClient[3])
    if (Test-CompanionTranscript $okHost $wrongLeader 201 1) { throw 'wrong leader accepted' }
    if (Test-CompanionTranscript ($okHost + '[companions] h FAIL too far') $okClient 201 1) { throw 'failure accepted' }
    Write-Host 'companions_group dry run: 6 passed, 0 failed'
    return
}

. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = Get-StandFullPath $Stand
Assert-NoJunction -Dir $Stand
$outDir = Join-Path $script:Root 'temp\stand'
$cp1251 = [Text.Encoding]::GetEncoding(1251)
$ascii = [Text.Encoding]::ASCII
$exeName = 'AnomalyCoopDX11AVX.exe'
$exe = Join-Path $Stand "bin\$exeName"
$exeB = Join-Path $Stand "bin_b\$exeName"
$token = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$fixture = Join-Path $Stand "zz_companions_$token.txt"
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_companions.script'
$options = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$backup = Join-Path $outDir "cmp_options_$token.ltx"
$gameHost = $null
$client = $null
$hostLog = $null
$clientLog = $null
$restoreOptions = $false
$installedProbe = $false

function New-CompanionProfile([string]$Suffix, [string]$Nick) {
    $profile = "appdata_$Suffix"
    $replacement = '$' + '{1}' + "$profile\"
    $text = [IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $cp1251) -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', $replacement
    if ($text -notmatch [regex]::Escape("$profile\")) { throw 'fsgame.ltx format unexpected' }
    Write-StandText -Path (Join-Path $Stand "fsgame_$Suffix.ltx") -Text $text -Encoding $cp1251
    $data = Join-Path $Stand $profile
    $copy = @{
        From = (Join-Path $Stand 'appdata_t')
        To = $data
        ExcludeFiles = @('coop_player.key', 'axr_options.ltx')
        ExcludeDirs = @('savedgames', 'logs', 'raylink', 'screenshots')
    }
    Copy-StandTree @copy
    $user = Join-Path $data 'user.ltx'
    $lines = @([IO.File]::ReadAllLines($user, $cp1251) | Where-Object { $_ -notmatch '^coop_nick\s' })
    Write-StandLines -Path $user -Lines ($lines + "coop_nick $Nick") -Encoding $cp1251
    return (Join-Path $data ('logs\xray_' + $env:USERNAME + '.log'))
}

# The same free items and faction money as carry_group's new stalker game.
function Get-StartKit([string]$Path) {
    $sections = @{}
    $section = $null
    foreach ($raw in [IO.File]::ReadAllLines($Path, $cp1251)) {
        $line = ($raw -replace ';.*$', '').Trim()
        if ($line -match '^\[([^\]]+)\]\s*(?::\s*(.+))?$') {
            $section = @{ Values = [ordered]@{}; Parents = @() }
            $sections[$Matches[1]] = $section
            if ($Matches[2]) { $section.Parents = @($Matches[2].Split(',') | ForEach-Object { $_.Trim() }) }
        } elseif ($section -and $line -match '^([^=\s]+)\s*=\s*(.*)$') {
            $section.Values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $resolve = {
        param($name)
        $result = [ordered]@{}
        if ($sections.ContainsKey($name)) {
            foreach ($parent in $sections[$name].Parents) {
                foreach ($pair in (& $resolve $parent).GetEnumerator()) { $result[$pair.Key] = $pair.Value }
            }
            foreach ($pair in $sections[$name].Values.GetEnumerator()) { $result[$pair.Key] = $pair.Value }
        }
        $result
    }
    $items = foreach ($pair in (& $resolve 'stalker_loadout').GetEnumerator()) {
        $parts = $pair.Value.Split(',')
        if ($parts[0].Trim() -eq 'false') {
            for ($i = 0; $i -lt [int]$parts[1]; $i++) { $pair.Key }
        }
    }
    [pscustomobject]@{ Items = $items -join ','; Money = (& $resolve 'stalker_money')['money'] }
}

function Get-CompanionLog([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { Get-Content -LiteralPath $Path }
}

function Wait-CompanionLine([string]$Path, [string]$Pattern, [int]$Seconds) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        foreach ($process in @($gameHost, $client)) {
            if ($process -and $process.HasExited) { throw "game process $($process.Id) exited ($($process.ExitCode))" }
        }
        foreach ($log in @($hostLog, $clientLog)) {
            if ($log -and (Test-Path -LiteralPath $log -PathType Leaf)) {
                $failure = Select-StandLogLine $log '\[companions\] (h|ag) FAIL\b' | Select-Object -First 1
                if ($failure) { throw (Hide-Hex $failure.Line) }
            }
        }
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            $hit = Select-String -LiteralPath $Path -Pattern $Pattern | Select-Object -Last 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Seconds 1
    }
    throw "timed out waiting for $Pattern"
}

try {
    if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
    if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
    if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx') -PathType Leaf)) { throw 'no prepared stand profile fsgame_t.ltx' }
    if (Test-Path -LiteralPath $probe) { throw 'the companions probe is already installed' }
    Copy-StandTree -From (Join-Path $Stand 'bin') -To (Join-Path $Stand 'bin_b')
    $hostLog = New-CompanionProfile 'cmph' 'cmp_host'
    $clientLog = New-CompanionProfile 'cmpag' 'cmp_client'
    foreach ($log in @($hostLog, $clientLog)) { Remove-StandFile -Path $log }
    Copy-StandFile -From $options -To $backup
    $kit = Get-StartKit (Join-Path $Stand 'gamedata\configs\items\settings\new_game_loadouts.ltx')
    if (-not $kit.Items) { throw 'no free kit for stalker' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]][IO.File]::ReadAllLines($options, $cp1251))
    $start = $lines.FindIndex([Predicate[string]] { param($l) $l -match '^\[character_creation\]' })
    if ($start -ge 0) {
        $end = $lines.FindIndex($start + 1, [Predicate[string]] { param($l) $l -match '^\[' })
        if ($end -lt 0) { $end = $lines.Count }
        $lines.RemoveRange($start, $end - $start)
    }
    $lines.AddRange([string[]]@(
        '[character_creation]', 'new_game_difficulty = 1', 'new_game_economy = 1', 'new_game_economy_treasure = 1',
        'new_game_story_mode = true', 'new_game_character_name = CmpHost', 'new_game_faction = stalker',
        "new_game_loadout = $($kit.Items)", 'new_game_map = rookie_village'
    ))
    if ($kit.Money) { $lines.Add("new_game_money = $($kit.Money)") }
    $restoreOptions = $true
    Write-StandLines -Path $options -Lines $lines -Encoding $cp1251
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_companions.script') -To $probe
    $installedProbe = $true
    $hostArgs = "-fsltx fsgame_cmph.ltx -coop_nick cmp_host -coop_host $Port -coop_probe h -zz_cmp_token $token -dbg -silent_error_mode -start server(all/single/alife/new) client(localhost)"
    $gameHost = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $hostArgs
    $null = $gameHost.Handle
    $until = (Get-Date).AddSeconds($UpTimeoutS)
    while (-not (Get-NetUDPEndpoint -LocalPort $Port -OwningProcess $gameHost.Id -ErrorAction SilentlyContinue)) {
        if ($gameHost.HasExited -or (Get-Date) -ge $until) { throw 'the host did not open its session' }
        Start-Sleep -Seconds 2
    }
    $clientArgs = "-fsltx fsgame_cmpag.ltx -coop_nick cmp_client -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe ag -zz_cmp_token $token -silent_error_mode"
    $client = Start-Process -FilePath $exeB -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
    $null = $client.Handle
    $null = Wait-CompanionLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $ready = Wait-CompanionLine $hostLog '\[companions\] h ready npc=([0-9]{1,5}) peer=([0-9]{1,2})\s*$' $StepsTimeoutS
    $npc = [int]$ready.Matches[0].Groups[1].Value
    $peer = [int]$ready.Matches[0].Groups[2].Value
    if ($npc -lt 1 -or $npc -ge 65535 -or $peer -lt 1 -or $peer -gt 15) { throw 'invalid stand fixture ids' }
    Write-StandText -Path $fixture -Text ([string]$npc) -Encoding $ascii
    $null = Wait-CompanionLine $hostLog '\[companions\] h PASS\b' $StepsTimeoutS
    $null = Wait-CompanionLine $clientLog '\[companions\] ag PASS\b' 90
    $hostLines = @(Get-CompanionLog $hostLog)
    $clientLines = @(Get-CompanionLog $clientLog)
    if (-not (Test-CompanionTranscript $hostLines $clientLines $npc $peer)) { throw 'companion ownership or talk evidence missing' }
    if ($gameHost.HasExited -or $client.HasExited) { throw 'a game process exited before the verdict' }
}
catch {
    Write-Host ("companions_group: FAIL ({0})" -f (Hide-Hex "$_"))
    throw
}
finally {
    try {
        foreach ($process in @($client, $gameHost)) {
            if ($process -and -not $process.HasExited) {
                Stop-Process -Id $process.Id -Force
                $null = $process.WaitForExit(5000)
            }
        }
        foreach ($pair in @(@($hostLog, 'host'), @($clientLog, 'client'))) {
            if ($pair[0] -and (Test-Path -LiteralPath $pair[0])) {
                Copy-StandFile -From $pair[0] -To (Join-Path $outDir "$($Tag)_companions_$($pair[1]).log")
                Select-StandLogLine $pair[0] '\[companions\]' | ForEach-Object { Write-Host (Hide-Hex $_.Line) }
            }
        }
    }
    finally {
        if ($restoreOptions) { Copy-StandFile -From $backup -To $options }
        Remove-StandFile -Path $backup
        if ($installedProbe) { Remove-StandFile -Path $probe }
        Remove-StandFile -Path $fixture
    }
}
Write-Host 'companions_group: PASS'
