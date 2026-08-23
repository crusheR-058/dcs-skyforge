<#
.SYNOPSIS
    Tally per-pilot combat statistics from the DCS log.

.DESCRIPTION
    Pretense records XP, a 'cmd' counter and a survival bonus -- nothing about
    what a pilot actually did. The DCS log does, in lines like:

        event:type=takeoff,initiatorPilotName=Happieee,...
        event:...,initiatorPilotName=Happieee,targetPilotName=...,type=hit,...

    So this walks the log and counts. Deliberately NOT counted: kills. DCS
    emits no kill event -- the vocabulary is shot/hit/crash/pilot dead/eject
    and nothing else. A "kill" could only be inferred by matching a hit to a
    later death on the same object id, which misattributes assists, splash
    damage and shared targets. Four exact numbers beat one arguable one.

    WHO COUNTS AS A HUMAN
    initiatorPilotName is the AIRCRAFT TYPE for AI units ("MiG-29A", "M-1
    Abrams"), so a naive tally credits kills to a Shilka. The whitelist is the
    key set of Pretense's own player_stats.json, which only ever contains
    people who have actually flown here.

.NOTES
    Reads incrementally by byte offset, so it costs nothing to run often on an
    8 MB and growing file. Detects rotation (DCS renames dcs.log on restart) by
    watching for the file shrinking, and re-reads from the start when it does.
#>

[CmdletBinding()]
param(
    [string]$StateDir   = 'C:\dcs-state',
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server',
    [int]$MaxBytes      = 40MB
)

$ErrorActionPreference = 'Continue'

$LogFile   = Join-Path $SavedGames 'Logs\dcs.log'
$StateFile = Join-Path $StateDir 'pilot-stats-state.json'
$OutFile   = Join-Path $StateDir 'combat.json'
$OwnLog    = Join-Path $StateDir 'pilot-stats.log'

function Write-Log {
    param([string]$m)
    if ((Test-Path $OwnLog) -and (Get-Item $OwnLog).Length -gt 256KB) {
        Move-Item -Force $OwnLog "$OwnLog.old"
    }
    Add-Content $OwnLog ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

if (-not (Test-Path $LogFile)) { Write-Log 'no dcs.log'; exit 0 }

# --- who is a person -------------------------------------------------------

$humans = @{}
try {
    $ps = Get-ChildItem (Join-Path $SavedGames 'Missions') -Recurse -Filter 'player_stats.json' -ErrorAction Stop |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    # -Encoding UTF8 is load-bearing: player_stats.json is UTF-8 without a
    # BOM, and PS 5.1 decodes BOM-less files as ANSI. That mojibakes any
    # non-ASCII name, the whitelist never matches the log, and that pilot's
    # entire combat record is silently dropped. It happened.
    $pj = Get-Content $ps.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($n in $pj.stats.PSObject.Properties.Name) { $humans[$n] = $true }
} catch {
    Write-Log "could not read player_stats.json: $($_.Exception.Message)"
}
if ($humans.Count -eq 0) { Write-Log 'no known players yet'; exit 0 }

# --- resume where we left off ----------------------------------------------

$state = @{ offset = 0; size = 0; tallies = @{} }
if (Test-Path $StateFile) {
    try {
        $s = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.offset = [int64]$s.offset
        $state.size   = [int64]$s.size
        foreach ($p in $s.tallies.PSObject.Properties) {
            $state.tallies[$p.Name] = @{
                sorties = [int]$p.Value.sorties; landings = [int]$p.Value.landings
                deaths  = [int]$p.Value.deaths;  hits     = [int]$p.Value.hits
                shots   = [int]$p.Value.shots;   ejects   = [int]$p.Value.ejects
            }
        }
    } catch { Write-Log 'state unreadable, starting fresh' }
}

$len = (Get-Item $LogFile).Length
if ($len -lt $state.size) {
    # DCS rotated the log on restart. Old counts stay; re-read the new file.
    Write-Log "log rotated ($($state.size) -> $len), resuming from 0"
    $state.offset = 0
}
if ($state.offset -gt $len) { $state.offset = 0 }

# A first run against a huge log would stall; cap the catch-up window.
if (($len - $state.offset) -gt $MaxBytes) {
    Write-Log ("skipping {0:N0} MB of backlog" -f (($len - $state.offset - $MaxBytes) / 1MB))
    $state.offset = $len - $MaxBytes
}

# --- read the new slice ----------------------------------------------------

$read = 0
try {
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
    [void]$fs.Seek($state.offset, 'Begin')
    $sr = New-Object IO.StreamReader($fs)

    function Bump {
        param([string]$who, [string]$field)
        if (-not $state.tallies.ContainsKey($who)) {
            $state.tallies[$who] = @{ sorties=0; landings=0; deaths=0; hits=0; shots=0; ejects=0 }
        }
        $state.tallies[$who][$field]++
    }

    while ($null -ne ($line = $sr.ReadLine())) {
        $read++
        if ($line -notlike '*initiatorPilotName=*') { continue }

        if ($line -notmatch 'initiatorPilotName=([^,]+)') { continue }
        $who = $Matches[1]
        if (-not $humans.ContainsKey($who)) { continue }   # AI type name

        # Combat lines carry 'type='; lifecycle lines carry 'event:type='.
        if ($line -match 'event:type=([^,]+)') {
            switch ($Matches[1]) {
                'takeoff'     { Bump $who 'sorties' }
                'land'        { Bump $who 'landings' }
                'pilot dead'  { Bump $who 'deaths' }
                'crash'       { Bump $who 'deaths' }
                'eject'       { Bump $who 'ejects' }
            }
        } elseif ($line -match ',type=([a-z_]+)') {
            switch ($Matches[1]) {
                'hit'  { Bump $who 'hits' }
                'shot' { Bump $who 'shots' }
            }
        }
    }

    $state.offset = $fs.Position
    $sr.Close(); $fs.Close()
} catch {
    Write-Log "read failed: $($_.Exception.Message)"
    exit 1
}
$state.size = $len

# --- persist and publish ---------------------------------------------------

$state.tallies | ForEach-Object { }   # no-op; keeps PS5.1 from unrolling below

$stateJson = @{ offset = $state.offset; size = $state.size; tallies = $state.tallies } |
    ConvertTo-Json -Compress -Depth 5
[IO.File]::WriteAllText($StateFile, $stateJson, (New-Object Text.UTF8Encoding($false)))

# Emit the board's copy separately so the internal offset never leaks into it.
$pub = @{}
foreach ($k in $state.tallies.Keys) {
    $t = $state.tallies[$k]
    # A pilot with no activity at all adds noise to the card; skip them.
    if (($t.sorties + $t.landings + $t.deaths + $t.hits + $t.shots + $t.ejects) -eq 0) { continue }
    $pub[$k] = $t
}
$outJson = @{ pilots = $pub; ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } |
    ConvertTo-Json -Compress -Depth 5
[IO.File]::WriteAllText($OutFile, $outJson, (New-Object Text.UTF8Encoding($false)))

Write-Log ("read {0:N0} lines, {1} pilots tracked" -f $read, $pub.Count)
