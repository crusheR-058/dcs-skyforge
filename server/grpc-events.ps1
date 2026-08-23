<#
.SYNOPSIS
    Consume the DCS-gRPC event stream: kills, base captures, carrier traps,
    connects, chat.

.DESCRIPTION
    The DCS log has no kill event -- its whole vocabulary is shot/hit/crash/
    pilot dead/eject. gRPC's StreamEvents does: KillEvent carries the killer,
    the victim and the weapon, so K/D here is recorded fact rather than a guess
    inferred from "a hit happened, then something died".

    TWO PROCESSES, ON PURPOSE

    grpcurl is left running as a detached writer, appending the stream to an
    ndjson-ish spool file. This script then reads that spool incrementally by
    byte offset -- the same pattern pilot-stats.ps1 uses on dcs.log, which has
    proven cheap and restart-safe.

    Parsing a live pipe from PowerShell would mean holding a child process open
    inside a scheduled task that must also finish promptly. Decoupling means a
    crashed grpcurl loses at most the events since the last respawn, and the
    parser never blocks.

    grpcurl pretty-prints each message, so objects are reassembled by tracking
    brace depth rather than assuming one JSON document per line.

.NOTES
    Only players are tallied. AI kills are counted separately and not attributed
    to anyone -- initiatorPilotName is the aircraft type for AI, and crediting a
    Shilka with air-to-air kills is exactly the sort of nonsense that makes a
    leaderboard worthless.
#>

[CmdletBinding()]
param(
    [string]$StateDir = 'C:\dcs-state',
    [string]$Tools    = 'C:\dcs-state\grpc-tools',
    [int]$MaxSpoolMB  = 48,
    [int]$FeedKeep    = 60,
    # StreamEvents is a firehose -- every AI shootingStart lands in the spool,
    # which grew 1.1 MB in minutes. Cap the catch-up window so one slow pass
    # can never run long enough to look like a hang (it did, and the watchdog
    # stopped the box underneath it).
    [int]$MaxCatchupMB = 8
)

$ErrorActionPreference = 'Continue'

$Spool     = Join-Path $StateDir 'grpc-events.ndjson'
$StateFile = Join-Path $StateDir 'grpc-events-state.json'
$CombatEx  = Join-Path $StateDir 'combat-events.json'
$FeedFile  = Join-Path $StateDir 'events.json'
$LogFile   = Join-Path $StateDir 'grpc-events.log'

function Write-Log {
    param([string]$m)
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 256KB) { Move-Item -Force $LogFile "$LogFile.old" }
    Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# ---------------------------------------------------------------------------
# 1. Keep the stream writer alive
# ---------------------------------------------------------------------------

$grpcUp = @(Get-NetTCPConnection -LocalPort 50051 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
if (-not $grpcUp) { exit 0 }   # gRPC rolled back or DCS down; nothing to do

$writer = Get-CimInstance Win32_Process -Filter "Name='grpcurl.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -like '*StreamEvents*' }

if (-not $writer) {
    # Rotate first: a stale multi-hundred-MB spool would be re-read from zero.
    if ((Test-Path $Spool) -and (Get-Item $Spool).Length -gt ($MaxSpoolMB * 1MB)) {
        Remove-Item $Spool -Force -ErrorAction SilentlyContinue
        Write-Log 'spool exceeded cap, truncated'
    }

    # Launched via Task Scheduler, NOT Start-Process.
    #
    # StreamEvents runs for hours. A child started with Start-Process stays in
    # the caller's process tree, and SSM Run Command waits on that whole tree --
    # so invoking this from a Run Command hung the command until it timed out.
    # Task Scheduler owns the process instead, so the caller returns at once.
    $cmdLine = ('& "{0}\grpcurl.exe" -plaintext -import-path "{0}\protos" ' +
                '-proto dcs/mission/v0/mission.proto -d "{{}}" -max-time 86400 ' +
                '127.0.0.1:50051 dcs.mission.v0.MissionService/StreamEvents ' +
                '*> "{1}"') -f $Tools, $Spool
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmdLine))

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName 'SkyForge-GrpcStream' -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName 'SkyForge-GrpcStream' `
        -Description 'Long-running DCS-gRPC StreamEvents reader; spools to grpc-events.ndjson' `
        -Action $action -Settings $settings -Principal $principal | Out-Null
    Start-ScheduledTask -TaskName 'SkyForge-GrpcStream'
    Write-Log 'started StreamEvents writer via scheduled task'
    Start-Sleep -Seconds 4
}

if (-not (Test-Path $Spool)) { exit 0 }

# ---------------------------------------------------------------------------
# 2. Resume
# ---------------------------------------------------------------------------

$state = @{ offset = 0; size = 0; kills = @{}; deaths = @{}; traps = @{}; feed = @(); aiKills = 0 }
if (Test-Path $StateFile) {
    try {
        $s = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.offset  = [int64]$s.offset
        $state.size    = [int64]$s.size
        $state.aiKills = [int]$s.aiKills
        foreach ($k in 'kills', 'deaths', 'traps') {
            $state[$k] = @{}
            if ($s.$k) { foreach ($p in $s.$k.PSObject.Properties) { $state[$k][$p.Name] = [int]$p.Value } }
        }
        # NOT `| ConvertFrom-Json` piping here -- on PS 5.1 that returns the whole
        # array as one object and @() nests it. Bit me on the airbase cache.
        if ($s.feed) { $state.feed = @($s.feed) }
    } catch { Write-Log 'state unreadable, starting fresh' }
}

$len = (Get-Item $Spool).Length
if ($len -lt $state.size) { $state.offset = 0; Write-Log 'spool restarted, reading from 0' }
if ($state.offset -gt $len) { $state.offset = 0 }
if (($len - $state.offset) -gt ($MaxCatchupMB * 1MB)) {
    $skip = $len - $state.offset - ($MaxCatchupMB * 1MB)
    Write-Log ("skipping {0:N1} MB of backlog to stay responsive" -f ($skip / 1MB))
    $state.offset = $len - ($MaxCatchupMB * 1MB)
}

# ---------------------------------------------------------------------------
# 3. Read and parse
# ---------------------------------------------------------------------------

# Who counts as a person. AI "pilot names" are aircraft type names.
$humans = @{}
try {
    $ps = Get-ChildItem 'C:\Users\Administrator\Saved Games\DCS.server\Missions' -Recurse `
          -Filter 'player_stats.json' -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    # -Encoding UTF8: same whitelist bug as pilot-stats.ps1 -- without it a
    # non-ASCII pilot's kills are misfiled as AI kills.
    foreach ($n in ((Get-Content $ps.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).stats.PSObject.Properties.Name)) { $humans[$n] = $true }
} catch { }

function Add-Feed {
    param([string]$kind, [string]$text)
    $state.feed = @(@([ordered]@{ k = $kind; t = $text; ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }) + $state.feed)
    if ($state.feed.Count -gt $FeedKeep) { $state.feed = @($state.feed[0..($FeedKeep - 1)]) }
}
function Bump { param([hashtable]$h, [string]$k) if ($k) { if (-not $h.ContainsKey($k)) { $h[$k] = 0 }; $h[$k]++ } }

$objects = 0
$matched = 0
try {
    $fs = [IO.File]::Open($Spool, 'Open', 'Read', 'ReadWrite')
    [void]$fs.Seek($state.offset, 'Begin')
    $sr = New-Object IO.StreamReader($fs)

    $buf = New-Object Text.StringBuilder
    $depth = 0; $started = $false

    # Only these five carry anything we record. Everything else in the stream --
    # shootingStart, shot, hit, birth, engine start, mark add -- is pure volume.
    $WANTED = @('"kill"', '"baseCapture"', '"landingQualityMark"', '"connect"', '"disconnect"')

    while ($null -ne ($line = $sr.ReadLine())) {
        # Brace counting without regex. [regex]::Matches twice per line was the
        # single biggest cost in this loop, on a file with tens of thousands of
        # lines per session.
        $opens  = $line.Length - $line.Replace('{', '').Length
        $closes = $line.Length - $line.Replace('}', '').Length
        if (-not $started -and $opens -eq 0) { continue }
        $started = $true
        [void]$buf.AppendLine($line)
        $depth += $opens - $closes
        if ($depth -gt 0) { continue }

        $json = $buf.ToString(); [void]$buf.Clear(); $started = $false; $depth = 0
        $objects++

        # Substring test before ConvertFrom-Json. Parsing every event was the
        # other half of the cost, and the overwhelming majority are noise.
        $interesting = $false
        foreach ($w in $WANTED) { if ($json.Contains($w)) { $interesting = $true; break } }
        if (-not $interesting) { continue }

        $matched++
        $ev = $null
        try { $ev = $json | ConvertFrom-Json } catch { continue }
        if (-not $ev) { continue }

        # --- kills -----------------------------------------------------------
        if ($ev.kill) {
            $by = $ev.kill.initiator.unit.playerName
            $vn = $ev.kill.target.unit.playerName
            $vt = $ev.kill.target.unit.type
            $wp = $ev.kill.weapon.type
            if ($by -and $humans.ContainsKey($by)) {
                Bump $state.kills $by
                Add-Feed 'kill' ("{0} destroyed {1}{2}" -f $by, ($(if ($vn) { $vn } else { $vt })), $(if ($wp) { " with $wp" } else { '' }))
            } else { $state.aiKills++ }
            if ($vn -and $humans.ContainsKey($vn)) { Bump $state.deaths $vn }
        }

        # --- base captures ----------------------------------------------------
        if ($ev.baseCapture) {
            $b = $ev.baseCapture.base.name
            $c = $ev.baseCapture.coalition
            if ($b) { Add-Feed 'capture' ("{0} captured by {1}" -f $b, ($c -replace 'COALITION_', '')) }
        }

        # --- carrier trap grades ----------------------------------------------
        if ($ev.landingQualityMark) {
            $who = $ev.landingQualityMark.initiator.unit.playerName
            $mk  = $ev.landingQualityMark.comment
            if ($who) { Bump $state.traps $who; Add-Feed 'trap' ("{0} trapped: {1}" -f $who, $mk) }
        }

        # --- presence ----------------------------------------------------------
        if ($ev.connect)    { Add-Feed 'join'  ("{0} connected" -f $ev.connect.name) }
        if ($ev.disconnect) { Add-Feed 'leave' ("{0} disconnected" -f $ev.disconnect.name) }
    }

    $state.offset = $fs.Position
    $sr.Close(); $fs.Close()
} catch {
    Write-Log "read failed: $($_.Exception.Message)"
    exit 1
}
$state.size = $len

# ---------------------------------------------------------------------------
# 4. Publish
# ---------------------------------------------------------------------------

$stateJson = @{ offset = $state.offset; size = $state.size; kills = $state.kills; deaths = $state.deaths
                traps = $state.traps; feed = $state.feed; aiKills = $state.aiKills } |
    ConvertTo-Json -Compress -Depth 6
[IO.File]::WriteAllText($StateFile, $stateJson, (New-Object Text.UTF8Encoding($false)))

$per = @{}
foreach ($n in @($state.kills.Keys) + @($state.deaths.Keys) + @($state.traps.Keys) | Sort-Object -Unique) {
    $per[$n] = [ordered]@{
        kills  = [int]$state.kills[$n]
        deaths = [int]$state.deaths[$n]
        traps  = [int]$state.traps[$n]
    }
}
$cbJson = @{ pilots = $per; aiKills = $state.aiKills; ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } |
    ConvertTo-Json -Compress -Depth 5
[IO.File]::WriteAllText($CombatEx, $cbJson, (New-Object Text.UTF8Encoding($false)))

$fdJson = @{ feed = $state.feed; ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } |
    ConvertTo-Json -Compress -Depth 5
[IO.File]::WriteAllText($FeedFile, $fdJson, (New-Object Text.UTF8Encoding($false)))

if ($objects -gt 0) {
    Write-Log ("scanned {0} event(s), {1} of interest; {2} pilot(s) with a record" -f $objects, $matched, $per.Count)
}
