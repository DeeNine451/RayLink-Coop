# Dev 57 A-S7, Server. Reload the exact save committed while the native transfer ledger was busy.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27991,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepTimeoutS = 600
)
. (Join-Path $PSScriptRoot 'ms_crash_server.ps1') -DefinitionsOnly -Stand $Stand -Port $Port -Tag $Tag `
    -UpTimeoutS $UpTimeoutS -JoinTimeoutS $JoinTimeoutS -StepTimeoutS $StepTimeoutS

function Find-S7Handover([string[]]$Lines, $Trip, [int]$After = $Trip.WorldLine) {
    $begin = "\[s7\] save begin seq=$($Trip.Sequence) from=$($Trip.SourceLevel) to=$($Trip.GoalLevel) peer=$($Trip.Peer)\s*$"
    $end = "\[s7\] save end seq=$($Trip.Sequence)\s*$"
    $state = 'idle'
    $sample = $null
    $objects = @{}
    for ($i = $After; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line -match '\[s7\] save begin\b') {
            $state = if ($line -match $begin) { 'open' } else { 'idle' }
            $sample = $null
            $objects = @{}
        } elseif ($state -eq 'open' -and $line -match $end) {
            $state = 'closed'
        } elseif ($state -eq 'open' -and $line -match $s7Counter) {
            $sample = Read-S7Counters $line
        } elseif ($line -match '\bGame (?<file>\S+) is successfully saved to file ') {
            $state = if ($state -eq 'closed' -and $Matches['file'] -eq 'coop_auto_tmp.scop') { 'written' } else { 'idle' }
        } elseif ($line -match '\[coop\] autosave (?<save>coop_auto_(?:[a-z0-9_-]+_)?[1-9]\d{0,8}) \((?<reason>[^)]+)\) written in \d+ ms\s*$') {
            if ($state -eq 'written' -and $objects.Count -gt 0 -and $sample -and $sample.Pending -gt 0 -and $sample.Violations -eq 0 -and
                $Matches['reason'] -in @('manual', 'a map server starts or stops')) {
                return @{ Name = $Matches['save']; Pending = $sample.Pending; Line = $i + 1
                    SourceLevel = $Trip.SourceLevel; GoalLevel = $Trip.GoalLevel; Objects = $objects }
            }
            $state = 'idle'
        } elseif ($line -match 'autosave .* (?:failed|skipped|dropped)\b') {
            $state = 'idle'
        } elseif ($state -eq 'open') {
            Add-S7Object $objects $line
        }
    }
}

function Initialize-S7SaveReader {
    if ('RayLinkStand.S7Save' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

namespace RayLinkStand {
    public sealed class S7Save {
        private const int SaveLimit = 256 * 1024 * 1024;
        private const int JournalLimit = 256 * 1024;
        private readonly byte[] source, output;
        private int input = 12, written;

        private S7Save(byte[] source, int size) {
            this.source = source;
            output = new byte[size];
        }

        private int Next() {
            if (input >= source.Length) throw new InvalidDataException("Truncated LZO stream");
            return source[input++];
        }

        private int Word() { return Next() | (Next() << 8); }

        private int Extended(int length) {
            int b;
            while ((b = Next()) == 0) {
                length += 255;
                if (length > output.Length) throw new InvalidDataException("Oversized LZO run");
            }
            return length + b;
        }

        private void Literals(int count) {
            if (count > source.Length - input || count > output.Length - written)
                throw new InvalidDataException("LZO literal run exceeds the save bounds");
            Buffer.BlockCopy(source, input, output, written, count);
            input += count;
            written += count;
        }

        private void Copy(int distance, int count) {
            if (distance <= 0 || distance > written || count > output.Length - written)
                throw new InvalidDataException("LZO match exceeds the save bounds");
            for (int i = 0; i < count; i++, written++) output[written] = output[written - distance];
        }

        // LZO1X framing from xrCore's rt_lzo1x_d.ch. The three entry points below distinguish
        // a new literal run, a match after a long literal run, and a match after a short tail.
        private void Decode() {
            int token = Next(), length, distance, tail, offset;
            if (token > 17) {
                length = token - 17;
                Literals(length);
                token = Next();
                if (length < 4) goto Match;
                goto AfterLiteral;
            }
        Run:
            if (token >= 16) goto Match;
            Literals((token == 0 ? Extended(15) : token) + 3);
            token = Next();
        AfterLiteral:
            if (token >= 16) goto Match;
            Copy(2049 + (token >> 2) + (Next() << 2), 3);
            tail = token & 3;
            goto Trailing;
        Match:
            if (token >= 64) {
                distance = 1 + ((token >> 2) & 7) + (Next() << 3);
                length = (token >> 5) + 1;
                tail = token & 3;
            } else if (token >= 32) {
                length = token & 31;
                if (length == 0) length = Extended(31);
                offset = Word();
                distance = 1 + (offset >> 2);
                tail = offset & 3;
                length += 2;
            } else if (token >= 16) {
                length = token & 7;
                if (length == 0) length = Extended(7);
                offset = Word();
                distance = ((token & 8) << 11) + (offset >> 2);
                if (distance == 0) {
                    if (token != 17 || offset != 0 || input != source.Length || written != output.Length)
                        throw new InvalidDataException("Invalid LZO end marker or save length");
                    return;
                }
                distance += 16384;
                tail = offset & 3;
                length += 2;
            } else {
                distance = 1 + (token >> 2) + (Next() << 2);
                length = 2;
                tail = token & 3;
            }
            Copy(distance, length);
        Trailing:
            Literals(tail);
            token = Next();
            if (tail == 0) goto Run;
            goto Match;
        }

        public static string Journal(string path) {
            long length = new FileInfo(path).Length;
            if (length < 15 || length > SaveLimit) throw new InvalidDataException("Invalid SCOP file length");
            byte[] data = File.ReadAllBytes(path);
            int size = BitConverter.ToInt32(data, 8);
            if (BitConverter.ToUInt32(data, 0) != UInt32.MaxValue || size < 8 || size > SaveLimit)
                throw new InvalidDataException("Invalid SCOP header");
            S7Save save = new S7Save(data, size);
            save.Decode();
            string journal = null;
            for (int at = 0; at < size;) {
                if (size - at < 8) throw new InvalidDataException("Truncated ALife chunk header");
                uint id = BitConverter.ToUInt32(save.output, at);
                int count = BitConverter.ToInt32(save.output, at + 4);
                at += 8;
                if (count < 0 || count > size - at) throw new InvalidDataException("Invalid ALife chunk length");
                if (id == 0xc0c0) {
                    if (journal != null || count == 0 || count > JournalLimit)
                        throw new InvalidDataException("Invalid transfer journal chunk");
                    journal = Encoding.ASCII.GetString(save.output, at, count);
                }
                at += count;
            }
            return journal;
        }
    }
}
'@
}

function Read-S7Journal([string]$Path) {
    Initialize-S7SaveReader
    $text = [RayLinkStand.S7Save]::Journal($Path)
    if ($null -eq $text) { return }
    $lines = $text.TrimEnd("`n") -split "`n"
    if ($lines.Count -lt 5 -or $lines[0] -cne '[coop_xfer]' -or $lines[1] -cne 'v = 1' -or
        $lines[2] -cnotmatch '^gen = \d{1,10}$' -or $lines[3] -cnotmatch '^peer = [1-9]\d{0,9}$' -or
        $lines[4] -cnotmatch '^n = (\d{1,2})$') { throw 'invalid transfer journal header' }
    $count = [int]$Matches[1]
    if ($count -gt 64 -or $lines.Count -ne $count + 5) { throw 'invalid transfer journal row count' }
    $ids = @{}
    for ($i = 0; $i -lt $count; $i++) {
        if ($lines[$i + 5] -cnotmatch "^x$i = ([GAR]),([1-9]\d{0,4}),[1-9]\d{0,9},\d{1,10},\d{1,10},[A-Za-z0-9+/=]*$") {
            throw "invalid transfer journal row $i"
        }
        $id = [int]$Matches[2]
        if ($id -gt 65534 -or $ids.ContainsKey($id)) { throw "invalid or duplicate transfer journal ID $id" }
        $ids[$id] = $true
        @{ Kind = $Matches[1]; Id = $id }
    }
}

function Get-S7SavedFixtures($Save, [hashtable]$Before, [object[]]$Journal) {
    if ($Journal.Count -ne $Save.Pending) { return }
    $fixtures = @{}
    foreach ($row in $Journal) {
        if ($row.Kind -ne 'R') { return }
        if (-not $Before.ContainsKey($row.Id)) { continue }
        $old = $Before[$row.Id]
        $atSave = $Save.Objects[$row.Id]
        if ($atSave -and $old.Name -eq $atSave.Name -and $old.Level -eq $Save.SourceLevel -and
            $old.Owner -eq $Save.SourceLevel -and $atSave.Level -eq $Save.SourceLevel -and
            $atSave.Owner -in @(-1, $Save.SourceLevel)) {
            # On restart the journal returns the releases to the world before a map server starts.
            $fixtures[$row.Id] = @{ Name = $atSave.Name; Level = $atSave.Level; Owner = -1 }
        }
    }
    if ($fixtures.Count) { return $fixtures }
}

function Assert-S7JournalResume($Status, [object[]]$Journal) {
    $completed = @($Journal | Where-Object Kind -eq 'R').Count
    if ($Journal.Count -eq 0 -or $Status.Completed -ne $completed -or $Status.RolledBack -ne $Journal.Count - $completed -or
        $Status.Pending -ne 0 -or $Status.Violations -ne 0 -or $Status.Bridges.Count -ne 0) {
        throw 'restarted world did not resolve the captured transfer journal before any map server started'
    }
}

function Get-S7SaveHashes($Context, [string]$Name) {
    foreach ($extension in @('scop','scoc')) {
        $path = Join-Path $Context.Run "world\savedgames\$Name.$extension"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 12) {
            throw "no complete $extension file for $Name"
        }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}

Invoke-S7Scenario 'save_handover_server' {
    param($ctx)
    Start-S7World $ctx
    $mover = Start-S7Client $ctx 's7move'
    Assert-S7Creator $ctx $mover
    Send-S7World $ctx 'srv_mapserver_linger 0'
    Send-S7World $ctx 'coop_autosave_interval 0'
    Send-S7World $ctx 'coop_autosave_count 30'

    $save = $null
    for ($attempt = 1; $attempt -le 4 -and -not $save; $attempt++) {
        $goal = if ($mover.Map -eq $s7From) { $s7To } else { $s7From }
        $before = (Assert-S7Audit $ctx @($mover.Level) -SelectFixtures).Objects
        if (-not $before.Count) { throw "no owned fixture objects on $($mover.Map)" }
        $trip = Start-S7Trip $ctx $mover $goal -SaveFixtures @($before.Keys)
        $until = [DateTime]::UtcNow.AddSeconds($StepTimeoutS)
        $askAt = [DateTime]::MinValue
        $settleBy = [DateTime]::MaxValue
        $requests = 0
        $cursor = $trip.WorldLine
        do {
            Assert-S7Running $ctx
            $worldLines = @(Get-Content -LiteralPath $ctx.Logs.world)
            while ($candidate = Find-S7Handover $worldLines $trip -After $cursor) {
                $cursor = $candidate.Line
                $hashes = @(Get-S7SaveHashes $ctx $candidate.Name)
                $journal = @(Read-S7Journal (Join-Path $ctx.Run "world\savedgames\$($candidate.Name).scop"))
                $fixtures = Get-S7SavedFixtures $candidate $before $journal
                if ($fixtures) {
                    $save = $candidate
                    break
                }
            }
            if ($save) { break }
            $now = [DateTime]::UtcNow
            if ($settleBy -eq [DateTime]::MaxValue -and
                (Find-S7Line $ctx.Logs.s7move "\[s7\] arrival seq=$($trip.Sequence) $s7Player" $trip.ClientLine)) {
                $settleBy = $now.AddSeconds(20)  # a last chance for transfers out of the emptied map
            }
            if ($now -ge $askAt -and $requests -lt 25) {
                Send-S7World $ctx 'coop_autosave_now'
                $askAt = $now.AddSeconds(1)
                $requests++
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $until -and [DateTime]::UtcNow -lt $settleBy)
        Send-S7World $ctx 'run_string coop_zz_s7.disarm_save()'
        $mover = Complete-S7Trip $ctx $mover $trip
    }
    if (-not $save) { throw 'no release-only committed save contained a source fixture release on four map handovers' }
    if ($mover.Level -ne $save.GoalLevel) { throw 'the mover did not complete the captured handover' }
    Write-Host "captured $($save.Name), handover $($save.SourceLevel) -> $($save.GoalLevel), $($save.Pending) journal transfers"

    Stop-S7Clients $ctx
    Stop-S7World $ctx
    if ((@(Get-S7SaveHashes $ctx $save.Name) -join ',') -ne ($hashes -join ',')) {
        throw 'shutdown changed the captured save'
    }
    Save-S7Logs $ctx '_before_reload'
    Clear-S7Logs $ctx
    $null = Set-S7Step $ctx 'all' 'sample'
    Start-S7World $ctx $save.Name
    $resumeBy = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $resumed = Get-S7Status $ctx -FixtureIds @($fixtures.Keys)
        if ($resumed.Completed + $resumed.RolledBack -gt 0) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $resumeBy)
    Assert-S7JournalResume $resumed $journal
    Assert-S7Fixtures $fixtures $resumed.Objects
    $restored = Start-S7Client $ctx 's7move'
    $level = Get-S7PlayerLevel (Get-S7Status $ctx) $restored $mover.Map
    Assert-S7Player $restored $mover $mover.Map -ExpectedLevel $save.GoalLevel -RequireAlive
    if ($level -ne $save.GoalLevel) { throw 'the world did not restore the creator to the saved destination' }
    if (Find-S7Line $ctx.Logs.world "transfer journal .* damaged|'s7move' chose \w+: character \d+ made before the world|is the operator and the world's creator") {
        throw 'save reload rejected the journal or recreated the returning character'
    }
    $settled = Assert-S7Audit $ctx @($level) -FixtureIds @($fixtures.Keys)
    Assert-S7Fixtures $fixtures $settled.Objects
    Write-Host "reloaded $($save.Name); resolved $($journal.Count) journal entries and preserved $($fixtures.Count) released fixtures: $($fixtures.Keys -join ',')"
    Write-Host "character $($restored.Character) has one marker item on $($restored.Map) after ownership audit round $($settled.AuditRound)"
}
