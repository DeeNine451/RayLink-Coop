# Shared part of tools\stand_hostplay.ps1 and tools\stand_srv.ps1 (dot-sourced): deploy HEAD's gamedata to the stand
# (tools\stand\stand_head.py: refused while either working tree has a product change or a scenario differs from HEAD;
# leftovers of our layers HEAD does not have leave the stand; the mode cvars of tools\stand\stand_profile.ltx go into
# the stand's profiles), run the scenarios of tools\stand (tracked) through tools\stand\run_guarded.ps1 (the profiles'
# mode cvars are written again before each one), judge each scenario's output (the outputs go to temp\stand, the run
# history), check that the stand still holds HEAD's gamedata, no leftover, and that nothing moved, and write the gate
# mark temp\gates\<mode>.ok on success.
# A mark: mode, mod_head, engine_head (the HEAD ids of both repositories), exe and exe_sha256 (the stand's exe), time,
# scenarios, dirty (product files changed or untracked, not committed, when the stand ran), scenarios_sha256 (the
# scenario files that ran), gamedata_sha256 (the gamedata deployed), exe_source (the engine HEAD the exe is engine-ci's
# build of, or none), stand_fingerprint (the stand's manifest and its coop scripts), stand_extra (leftovers: 0),
# stand_foreign (coop scripts a GAMMA mod ships) and profile_sha256 (the profile template). tools\check_gates.py reads it
# and counts a mark only with dirty=0, every scenario of the runner (check_gates.SCENARIOS), exe_source = engine HEAD,
# the stand's own exe path and fingerprint, and the digests equal to HEAD's.
# PowerShell 5.1, ASCII only.

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:StandDir = Join-Path $script:Root 'temp\stand'
$script:ScenarioDir = Join-Path $script:Root 'tools\stand'
$script:HeadTool = Join-Path $script:ScenarioDir 'stand_head.py'
$script:MarkDir = Join-Path $script:Root 'temp\gates'

$script:ErrorPattern = @(
    'FATAL ERROR'
    '(?-i:LUA error)'
    '(?-i:stack traceback)'
    'crash: (exception 0x|access violation)'
    '! (\[[0-9:.]+\] +)?\[coop'
    '\[coop[^\]]*\](\[[^\]]*\])* +! '
    '\bcoop_(?!route\b|zz_)\w+\.script \(line: \d+\)'
    'SCRIPT RUNTIME ERROR|SCRIPT SYNTAX ERROR|\[SCRIPT ERROR\]'
) -join '|'

# Engine diagnostics use one space on the world server and add a timestamp elsewhere.
$script:StandBang = '^\s*! (?:\[[0-9:.]+\] +)?'
$script:StandLuaHeader = $script:StandBang + '\[LUA\] SCRIPT (?:RUNTIME|SYNTAX) ERROR\s*$'
$script:StandLuaFrame = $script:StandBang + '\[LUA\] +\d+ : '
$script:StandGammaSource = '(?<source>(?:(?:[A-Z]:)?[^:\r\n]*[\\/])?(?:' + (@(
    'a_faction_prices\.script:16: attempt to index global ''faction_stocks'' \(a nil value\)' # G.A.M.M.A. UI
    'mags_patches\.script:4: attempt to index global ''magazine_binder'' \(a nil value\)' # 433- UDP-9 Carbine
    'zz_ui_inventory_better_stats_bars\.script:41: attempt to index global ''better_stats_bars_mcm'' \(a nil value\)' # G.A.M.M.A. Keybinds fixes
    'zzz_mspizza_godis_zoomcalc\.script:113: unexpected symbol near ''/''' # 410- 3DSS for GAMMA
) -join '|') + '))\s*$'
$script:StandGammaDetail = $script:StandBang + '\[LUA\] ' + $script:StandGammaSource
$script:StandGammaReport = $script:StandBang + '\[SCRIPT ERROR\]: ' + $script:StandGammaSource

$script:StandNoise = @(
    $script:StandGammaDetail # debug Lua detail from the four GAMMA sources above
    $script:StandGammaReport # engine summary from the same four sources
    ($script:StandBang + '\[coop\] .* asks to leave through level exit .* ignored\s*$') # srv/coop_srv_join.cpp: rejects out-of-range requests
    ($script:StandBang + '\[coop\] map servers: this PC has .* free \(under .*\): an empty map server does not linger(?:, it stops at once)?\s*$') # srv/coop_mapserver.cpp: low-memory policy
    ($script:StandBang + '\[coop\] the host''s level is still precaching after \d+ s \(window without focus\?\): joins go on\s*$') # coop_join.cpp: lets joins proceed
    ($script:StandBang + '\[coop\] the host does not answer \(\d+ ms\): the game waits for it, out after \d+ s\s*$') # coop_manager.cpp: warns at the start of a recoverable wait
    ($script:StandBang + '\[coop\] stalker \[[^\]]*\] visual(?: \[[^\]]*(?:\](?:: the torso motion of its active item is not in the visual \(\d+ so far\), the no-item motion plays)?)?)?\s*$') # stalker_animation_manager_update.cpp play_torso (b51, RL-4BXZ-R24J): a GAMMA weapon's motion the NPC visual lacks; stock crashed here, rate-limited. Also the line cut after "visual" or inside its [visual] by a game stopped while writing it
    '^\s*(?:\[[0-9:.]+\] +)?\[coop-game\] ! the record was not read at the world start: switched on late, scripts that cached an option keep the machine''s\s*$' # coop_game_settings.script: save callback loaded the record
) -join '|'

function Test-StandErrorLine([string]$Line) {
    return ($Line -match $script:ErrorPattern -and $Line -notmatch $script:StandNoise)
}

function Test-StandLogNoise([Microsoft.PowerShell.Commands.MatchInfo]$Hit) {
    if ($Hit.Line -match $script:StandNoise) { return $true }
    if ($Hit.Line -notmatch $script:StandLuaHeader) { return $false }
    # CScriptStorage prints the error detail, then repeats it in the [SCRIPT ERROR] report.
    # Suppress the bare header only when both lines identify the same known load error.
    $detail = $null
    foreach ($line in $Hit.Context.PostContext) {
        if ($line -match $script:StandLuaFrame) { continue }
        if (-not $detail -and $line -match $script:StandGammaDetail) {
            $detail = $Matches.source
            continue
        }
        return ($detail -and $line -match $script:StandGammaReport -and $Matches.source -eq $detail)
    }
    return $false
}

function Select-StandLogLine([string]$Path, [string]$Pattern = '', [int]$Last = 0) {
    $patterns = @($script:ErrorPattern)
    if ($Pattern) { $patterns += $Pattern }
    $select = {
        # The debug header in b56/b57 has up to seven [LUA] lines before its [SCRIPT ERROR] report.
        Select-String -LiteralPath $Path -Pattern $patterns -Context 0, 8 |
            Where-Object { -not (Test-StandLogNoise $_) }
    }
    if ($Last -le 0) { & $select; return }
    $hits = @(& $select)
    if ($hits.Count -le $Last) { $hits; return }
    # Keep the normal excerpt size without dropping an earlier error.
    $first = $hits[$hits.Count - $Last].LineNumber
    $hits | Where-Object { $_.LineNumber -ge $first -or (Test-StandErrorLine $_.Line) }
}

function Show-StandLogLines([string]$Path, [string]$Pattern, [int]$Last) {
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host "  no log $Path"; return }
    Select-StandLogLine $Path $Pattern -Last $Last | ForEach-Object { Write-Host ('  ' + (Hide-Hex $_.Line)) }
}

function Hide-Hex([string]$text) { return ($text -replace '[0-9a-fA-F]{32,}', '<hidden>') }

# A path outside the stand folder (or none).
function Test-StandForeignPath([string]$Path, [string]$Stand) {
    $root = [IO.Path]::GetFullPath($Stand).TrimEnd('\', '/') + '\'
    return (-not $Path -or -not [IO.Path]::GetFullPath($Path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase))
}

# The games of $Games that run outside the stand: the owner's game stops a stand run at once (tools\stand\run_guarded.ps1).
# A stand game that is closing has no readable path for a moment (the b57 Server stand, 2026-11-21: four scenarios stopped
# with no foreign game on the machine). A game without a path counts only while it still runs and the system names no
# path under the stand for it; what cannot be decided counts (the owner's game first). -PathOf / -IsAlive: for tests.
function Get-StandForeignGame {
    param([object[]]$Games, [Parameter(Mandatory = $true)][string]$Stand,
        [scriptblock]$PathOf = { param($id) (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue).ExecutablePath },
        [scriptblock]$IsAlive = { param($id) [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) })
    foreach ($g in @($Games)) {
        if (-not $g) { continue }
        $path = $g.Path
        if (-not $path) {
            $gone = $false
            try { $gone = [bool]$g.HasExited } catch { $gone = $false } # no access: maybe the owner's game, decide below
            if ($gone) { continue }
            $path = & $PathOf $g.Id
            if (-not $path -and -not (& $IsAlive $g.Id)) { continue }
        }
        if (Test-StandForeignPath $path $Stand) { $g }
    }
}

# ---- writing into a stand (TZ.md R21) -----------------------------------------------------------------------------------
# The launcher builds the stand (E:\RayLinkGames\GAMMA\game-dev) from hard links to the mods' own files
# (E:\RayLinkGames\GAMMA\mo2\mods, about 60,700 of 61,800 files). Copy-Item -Force, [IO.File]::WriteAll*, Set-Content,
# Out-File and robocopy write INTO an existing file: through a link that changes the mod's file for everything that
# links it. Remove-Item -Force clears a read-only attribute, which every link shares. So every write into a stand
# (the scenarios of tools\stand, the runners, tools\deploy.ps1, tools\launch.ps1) goes through these helpers: the bytes
# go to a fresh file next to the target, the old name is deleted (FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE: the
# attribute stays as it is for the other links), the fresh file takes the name. tools\mo2_stand.py replace_file does
# the same in Python.
function Initialize-StandFiles {
    if ('RayLinkStand.Files' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace RayLinkStand {
public static class Files {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition,
                                             uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, ref uint info, uint size);
    // one name of the file: DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE (Windows 10 1809+, NTFS)
    public static void Delete(string path) {
        using (SafeFileHandle h = CreateFileW(path, 0x00010000, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
            if (h.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error(), "cannot delete " + path); }
            uint flags = 0x1 | 0x2 | 0x10;
            if (!SetFileInformationByHandle(h, 21, ref flags, 4)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "cannot delete " + path);
            }
        }
    }
}
}
'@
}

function Get-StandFullPath([string]$Path) {
    # relative to PowerShell's location, `..` collapsed (Get-ChildItem names files by their normalized path)
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Remove-StandFile {
    # deletes one name of a stand file; another hard link keeps its data and its read-only attribute. Refused (even
    # for a missing file) when any folder on the way is a junction: the name inside it is the mod's own file
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-StandFullPath $Path
    Assert-NoJunction -Dir ([System.IO.Path]::GetDirectoryName($full))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    Initialize-StandFiles
    try { [RayLinkStand.Files]::Delete($full) }
    catch [System.ComponentModel.Win32Exception] {
        # 87: the volume does not know the flags (not NTFS): a plain delete, never by clearing the attribute
        if ($_.Exception.NativeErrorCode -ne 87) { throw }
        if ((Get-Item -LiteralPath $full -Force).Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            throw "cannot delete the read-only $full without changing the attribute its links share"
        }
        [System.IO.File]::Delete($full)
    }
}

function Assert-NoJunction {
    # review 5 (S14): a stand folder that is a junction or symlink into a mod's folder; a write through it would delete
    # the mod's own file and put ours into the mod's folder. Review 6 (B1, round 7): not only $Dir itself but every
    # folder on the way, from the volume root down to $Dir: the game root, the folders above it and every folder below
    # it (the stand's gamedata as a junction into a mod's gamedata took Write-StandText on gamedata\configs\
    # axr_options.ltx into the mod). The helpers do not know the game root, so the whole path is checked
    # (tools\mo2_stand.py link_on_path walks the same way). The walk ends at the first name that does not exist:
    # nothing below it can be a link yet.
    param([Parameter(Mandatory = $true)][string]$Dir)
    $chain = [System.Collections.Generic.List[string]]::new()
    $cur = Get-StandFullPath $Dir
    while ($cur) { $chain.Insert(0, $cur); $cur = [System.IO.Path]::GetDirectoryName($cur) }
    foreach ($folder in $chain) {
        try { $attr = [System.IO.File]::GetAttributes($folder) }  # the link's own attributes, never its target's
        catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return }
        if ($attr -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "refusing to write through a junction or symlink folder: $folder (on the way to $Dir; the launcher builds real folders)"
        }
    }
}

function Set-StandFile {
    # $Write fills a fresh file next to $Path (its argument: that file's path); then the old name goes and the fresh
    # file takes it. The stand's file is never opened for writing, and never through a junction folder anywhere on
    # its path (Assert-NoJunction walks from the volume root down; review 6, B1).
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][scriptblock]$Write)
    $full = Get-StandFullPath $Path
    $dir = [System.IO.Path]::GetDirectoryName($full)
    Assert-NoJunction -Dir $dir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ('.' + [System.IO.Path]::GetFileName($full) + '.' + $PID + '.new')
    Remove-StandFile -Path $tmp
    try {
        & $Write $tmp
        $attr = [System.IO.File]::GetAttributes($tmp)
        if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
            [System.IO.File]::SetAttributes($tmp, $attr -bxor [System.IO.FileAttributes]::ReadOnly)  # our own new file
        }
        Remove-StandFile -Path $full
        [System.IO.File]::Move($tmp, $full)
    }
    catch { Remove-StandFile -Path $tmp; throw }
}

function Write-StandBytes {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][byte[]]$Bytes)
    Set-StandFile -Path $Path -Write { param($t) [System.IO.File]::WriteAllBytes($t, $Bytes) }.GetNewClosure()
}

function Write-StandText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding)
    Set-StandFile -Path $Path -Write { param($t) [System.IO.File]::WriteAllText($t, $Text, $Encoding) }.GetNewClosure()
}

function Write-StandLines {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][System.Text.Encoding]$Encoding)
    Set-StandFile -Path $Path -Write { param($t) [System.IO.File]::WriteAllLines($t, $Lines, $Encoding) }.GetNewClosure()
}

function Copy-StandFile {
    # a copy of $From at $To (its time kept, never read-only), as a new file
    param([Parameter(Mandatory = $true)][string]$From, [Parameter(Mandatory = $true)][string]$To)
    $src = Get-StandFullPath $From
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "no file to copy: $src" }
    Set-StandFile -Path $To -Write { param($t) [System.IO.File]::Copy($src, $t, $false) }.GetNewClosure()
}

function Copy-StandTree {
    # robocopy $From $To /E /XF <ExcludeFiles> /XD <ExcludeDirs> without writing into an existing file: a file whose
    # size and time match is left alone (robocopy's "same"), any other goes through Copy-StandFile. Junctions are skipped.
    # -Mirror (robocopy /MIR): files under $To that $From does not have go too (Remove-StandFile; excluded names stay).
    param([Parameter(Mandatory = $true)][string]$From, [Parameter(Mandatory = $true)][string]$To,
        [string[]]$ExcludeFiles = @(), [string[]]$ExcludeDirs = @(), [switch]$Mirror)
    Assert-NoJunction -Dir $To  # every folder down to $To, before the mirror deletes anything (review 6, B1)
    if ($Mirror -and (Test-Path -LiteralPath $To -PathType Container)) {
        $srcRoot = (Get-StandFullPath $From).TrimEnd('\')
        $dstTop = (Get-StandFullPath $To).TrimEnd('\')
        $gone = [System.Collections.Generic.Stack[string]]::new()
        $gone.Push($dstTop)
        while ($gone.Count -gt 0) {
            $dir = $gone.Pop()
            foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force)) {
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }  # never through a junction
                $rel = $item.FullName.Substring($dstTop.Length + 1)
                if ($item.PSIsContainer) {
                    if (@($ExcludeDirs | Where-Object { $item.Name -like $_ }).Count -eq 0) { $gone.Push($item.FullName) }
                    continue
                }
                if (@($ExcludeFiles | Where-Object { $item.Name -like $_ }).Count -gt 0) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $srcRoot $rel) -PathType Leaf)) { Remove-StandFile -Path $item.FullName }
            }
        }
    }
    $src = (Get-StandFullPath $From).TrimEnd('\')
    $dstRoot = Get-StandFullPath $To
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { throw "no folder to copy: $src" }
    Assert-NoJunction -Dir $dstRoot
    New-Item -ItemType Directory -Force -Path $dstRoot | Out-Null
    $todo = [System.Collections.Generic.Stack[string]]::new()
    $todo.Push($src)
    while ($todo.Count -gt 0) {
        $dir = $todo.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force)) {
            $dst = Join-Path $dstRoot $item.FullName.Substring($src.Length + 1)
            if ($item.PSIsContainer) {
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if (@($ExcludeDirs | Where-Object { $item.Name -like $_ }).Count -gt 0) { continue }
                Assert-NoJunction -Dir $dst  # a folder of the stand on the way: never through a junction
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                $todo.Push($item.FullName)
                continue
            }
            if (@($ExcludeFiles | Where-Object { $item.Name -like $_ }).Count -gt 0) { continue }
            if (Test-Path -LiteralPath $dst -PathType Leaf) {
                $have = Get-Item -LiteralPath $dst -Force
                if ($have.Length -eq $item.Length -and $have.LastWriteTimeUtc -eq $item.LastWriteTimeUtc) { continue }
            }
            Copy-StandFile -From $item.FullName -To $dst
        }
    }
}

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
    # the mode of every stand process comes from HEAD: the profiles' mode cvars, which the last run wrote back (S2)
    Invoke-HeadProfile -Stand $Stand
    $guard = Join-Path $script:ScenarioDir 'run_guarded.ps1'
    $problems = [System.Collections.Generic.List[string]]::new()
    # review 4, B1: only this run's output is judged. The tag stays the same all cycle, so the output of an older run
    # of the same tag goes first; if it cannot (an orphaned scenario still holds it), this run is not judged at all.
    $errPath = $outPath + '.err'
    foreach ($old in @($outPath, $errPath)) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -ErrorAction SilentlyContinue }
    }
    foreach ($old in @($outPath, $errPath)) {
        if (Test-Path -LiteralPath $old) { $problems.Add("the output of an older run could not be removed: $old (is an older scenario still running?)") }
    }
    if ($problems.Count -gt 0) {
        Write-Host "  FAIL $name"; foreach ($p in $problems) { Write-Host "    $p" }
        return [pscustomobject]@{ Name = $name; Ok = $false; Problems = $problems; Out = $outPath }
    }
    $guardArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guard, '-Script', $Scenario.Script, '-Out', $out,
        '-Stand', $Stand, '-OutDir', $script:StandDir)
    if ($scArgs.Trim()) { $guardArgs += @('-ScriptArgs', $scArgs.Trim()) }  # an empty argument would vanish on the way
    $guardOut = @(& powershell.exe @guardArgs)
    $guardCode = $LASTEXITCODE
    if ($guardCode -ne 0) { $problems.Add("run_guarded.ps1 failed (exit $guardCode)") }
    $guardStop = $guardOut | Where-Object { $_ -match '^GUARD:' } | Select-Object -First 1
    if ($guardStop) { $problems.Add($guardStop) }
    if (-not ($guardOut | Where-Object { $_ -eq 'run finished' })) { $problems.Add("run_guarded.ps1 did not report 'run finished'") }
    $codeLine = $guardOut | Where-Object { $_ -match '^scenario exit code: (-?\d+)$' } | Select-Object -First 1
    if (-not $codeLine) { $problems.Add('run_guarded.ps1 did not report the scenario exit code') }
    elseif ($codeLine -ne 'scenario exit code: 0') { $problems.Add($codeLine) }
    if (-not (Test-Path -LiteralPath $outPath)) {
        $problems.Add('no output file')
        Write-Host "  FAIL $name"; foreach ($p in $problems) { Write-Host "    $p" }
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
        if (Test-StandErrorLine $l) { $problems.Add('error line: ' + (Hide-Hex $l.Trim())) }
    }
    $err = $errPath
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
    foreach ($k in $script:MarkKeys) {
        if (-not $values.ContainsKey($k)) { throw "stand_head $Command printed no $k" }
    }
    return $values
}

# what stand_head deploy / check print and the mark carries; none may change between the deploy and the check
$script:MarkKeys = @('mod_head', 'engine_head', 'scenarios_sha256', 'gamedata_sha256', 'exe_sha256', 'exe_source',
    'stand_fingerprint', 'stand_extra', 'stand_foreign', 'profile_sha256')

function Invoke-HeadProfile {
    # the mode cvars of tools\stand\stand_profile.ltx into the stand's profiles; a refusal throws
    param([Parameter(Mandatory = $true)][string]$Stand)
    $out = @(& python -I $script:HeadTool 'profile' '--stand' $Stand '--root' $script:Root '--backup' (Join-Path $script:StandDir 'head_backup'))
    if ($LASTEXITCODE -ne 0) { throw "stand_head profile refused: $($out -join ' ')" }
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
        "gamedata_sha256=$($Head['gamedata_sha256'])",
        "exe_source=$($Head['exe_source'])",
        "stand_fingerprint=$($Head['stand_fingerprint'])",
        "stand_extra=$($Head['stand_extra'])",
        "stand_foreign=$($Head['stand_foreign'])",
        "profile_sha256=$($Head['profile_sha256'])"
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
    if ($head['exe_source'] -eq 'none') {
        Write-Host '*****************************************************************************************************'
        Write-Host "stand_${Mode}: the stand's exe is not shown to be engine-ci's build of engine HEAD (lines above):"
        Write-Host '  a mark of this run will NOT count (python tools\ci_sync.py --committed, build, copy the exe, run again)'
        Write-Host '*****************************************************************************************************'
    }
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
    # nothing moved during the run: both HEADs, the scenario files, the stand's gamedata, its exe, its leftovers and
    # mod scripts, the profile template
    $after = Invoke-HeadCheck -Stand $Stand
    foreach ($k in $script:MarkKeys) {
        if ($after[$k] -ne $head[$k]) {
            Write-Host "stand_${Mode}: FAIL ($k changed during the run: no mark written)"
            return 1
        }
    }
    Write-GateMark -Mode $Mode -Exe $exe -Names @($results | ForEach-Object { $_.Name }) -Head $head
    Write-Host "stand_${Mode}: PASS ($($results.Count) scenarios)"
    return 0
}
