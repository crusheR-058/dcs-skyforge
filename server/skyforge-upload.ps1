<#
.SYNOPSIS
    Push live server telemetry and Pretense campaign state to S3 for the
    SkyForge web board.

.DESCRIPTION
    Runs every 15 seconds while DCS is up. Uploads three small JSON files that
    the static web app reads directly from CloudFront:

        live.json      units, airbases, connected players   (~20-80 KB)
        campaign.json  Pretense zone ownership and supplies (~24 KB)
        pilots.json    player XP and ranks                  (~1-5 KB)
        status.json    is the server up, and when was that true

    There is deliberately NO API server in this design. The instance pushes,
    the browser pulls, and the only always-on components are S3 and CloudFront
    -- about $1/month rather than the cost of keeping a web backend running
    beside a server that is asleep most of the week.

    status.json is what makes an on-demand server presentable: the board reads
    its timestamp and shows "offline, last flown 2h ago" rather than a stale
    map pretending to be live.

.NOTES
    Uploads only when the content has actually changed (hash comparison), which
    keeps S3 PUT counts -- and therefore cost -- near zero when the server sits
    idle with nobody flying.
#>

[CmdletBinding()]
param(
    [string]$Bucket = 'skyforge-board-123456789012',
    [string]$StateDir = 'C:\dcs-state',
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server'
)

$ErrorActionPreference = 'Stop'

$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
if (-not (Test-Path $aws)) { throw 'AWS CLI not found on this instance.' }

$LogFile = Join-Path $StateDir 'skyforge-upload.log'
$HashFile = Join-Path $StateDir 'skyforge-hashes.json'

function Write-Log {
    param([string]$m)
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
        Move-Item -Force $LogFile "$LogFile.old"
    }
    Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

$token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
    -Uri 'http://169.254.169.254/latest/api/token' `
    -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
$region = Invoke-RestMethod -TimeoutSec 5 `
    -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
    -Headers @{ 'X-aws-ec2-metadata-token' = $token }

# --- What to publish -------------------------------------------------------

$dcs = Get-Process DCS_server -ErrorAction SilentlyContinue

$players = 0
$mission = 'unknown'
$fps = 0
$names = @()
try {
    $pj = Get-Content (Join-Path $StateDir 'players.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$pj.ts) -le 180) {
        $players = [int]$pj.players
        $mission = [string]$pj.mission
        $fps = [double]$pj.fps
        if ($pj.PSObject.Properties.Name -contains 'names' -and $pj.names) {
            $names = @($pj.names)
        }
    }
} catch { }

# Pretense writes these itself; we just relay them.
#
# MEASURED: they land in Missions\Saves\, not Missions\. Searching recursively
# rather than hardcoding either path, because this is exactly the assumption
# that silently produced an empty board the first time.
$missionDir = Join-Path $SavedGames 'Missions'

$uploads = @{}

$campaign = Get-ChildItem $missionDir -Recurse -Filter 'pretense*.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($campaign) { $uploads['campaign.json'] = (Get-Content $campaign.FullName -Raw -Encoding UTF8) }

$pilots = Get-ChildItem $missionDir -Recurse -Filter 'player_stats.json' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($pilots) { $uploads['pilots.json'] = (Get-Content $pilots.FullName -Raw -Encoding UTF8) }

# Zone balance is folded into status.json rather than left in campaign.json,
# because /dcs status must answer inside Discord's 3-second interaction window.
# One 200-byte fetch beats two, and campaign.json is 32 KB.
$zoneBlue = 0; $zoneRed = 0; $zoneTotal = 0
if ($uploads.ContainsKey('campaign.json')) {
    try {
        $campObj   = $uploads['campaign.json'] | ConvertFrom-Json
        $zoneList  = @($campObj.zones.PSObject.Properties | ForEach-Object { $_.Value })
        $zoneBlue  = @($zoneList | Where-Object { $_.side -eq 2 }).Count
        $zoneRed   = @($zoneList | Where-Object { $_.side -eq 1 }).Count
        $zoneTotal = $zoneList.Count
    } catch { }
}

$bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$bootTs  = [DateTimeOffset]::new($bootUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()

$uploads['status.json'] = [ordered]@{
    online   = [bool]$dcs
    players  = $players
    names    = $names
    mission  = $mission
    fps      = [math]::Round($fps, 1)
    address  = '203.0.113.10:10308'
    srs      = '203.0.113.10:5002'
    uptime   = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $bootTs)
    zones    = [ordered]@{ blue = $zoneBlue; red = $zoneRed; total = $zoneTotal }
    ts       = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
} | ConvertTo-Json -Compress -Depth 4

# --- Pilot presence --------------------------------------------------------
#
# The roster is already read every ~15s; nobody was keeping it. Recording it
# gives "joined" and "last seen" with no DCS mod and no extra polling.
#
# Flight time accrues only across CONTIGUOUS sightings. If the gap is large the
# server was asleep or the pilot logged off -- counting that would turn an
# overnight shutdown into eight hours of flying. A long gap starts a new
# session instead.
$SeenFile      = Join-Path $StateDir 'pilot-log.json'
$SessionGapSec = 900
$ContiguousSec = 180

$seen = @{}
if (Test-Path $SeenFile) {
    try {
        (Get-Content $SeenFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $seen[$_.Name] = @{
                first    = [int64]$_.Value.first
                last     = [int64]$_.Value.last
                sessions = [int]$_.Value.sessions
                minutes  = [double]$_.Value.minutes
            }
        }
    } catch { Write-Log 'pilot-log.json unreadable - starting fresh' }
}

$nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
foreach ($entry in @($names)) {
    $who = [string]$entry.n
    if (-not $who) { continue }

    if (-not $seen.ContainsKey($who)) {
        $seen[$who] = @{ first = $nowSec; last = 0; sessions = 0; minutes = 0.0 }
    }
    $e   = $seen[$who]
    $gap = $nowSec - $e.last

    if ($gap -gt $SessionGapSec) { $e.sessions = $e.sessions + 1 }
    elseif ($gap -gt 0 -and $gap -le $ContiguousSec) { $e.minutes = $e.minutes + ($gap / 60.0) }
    $e.last = $nowSec
}

if ($seen.Count) {
    $ordered = [ordered]@{}
    foreach ($k in ($seen.Keys | Sort-Object)) {
        $ordered[$k] = [ordered]@{
            first    = $seen[$k].first
            last     = $seen[$k].last
            sessions = $seen[$k].sessions
            minutes  = [math]::Round($seen[$k].minutes, 1)
        }
    }
    $seenJson = $ordered | ConvertTo-Json -Compress -Depth 3
    # UTF-8 *without* BOM: Set-Content -Encoding utf8 adds one on PS 5.1,
    # and a BOM makes the browser's response.json() throw.
    [IO.File]::WriteAllText($SeenFile, $seenJson, (New-Object Text.UTF8Encoding($false)))
    $uploads['pilots-seen.json'] = $seenJson
}

# live.json comes from the in-game export hook
$live = Join-Path $StateDir 'live.json'
if (Test-Path $live) {
    $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64](Get-Item $live).LastWriteTimeUtc.Subtract([datetime]'1970-01-01').TotalSeconds)
    if ($age -le 120) { $uploads['live.json'] = (Get-Content $live -Raw -Encoding UTF8) }
}

# --- Live unit positions from DCS-gRPC -------------------------------------
#
# Only runs when gRPC is actually listening, so this is a no-op on a server
# where it has been rolled back. The bridge writes C:\dcs-state\live.json,
# which the block further down uploads under the usual freshness rule.

$bridge = Join-Path $StateDir 'grpc-bridge.ps1'
if (Test-Path $bridge) {
    $grpcUp = @(Get-NetTCPConnection -LocalPort 50051 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
    if ($grpcUp) {
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $bridge | Out-Null
        } catch {
            Write-Log "grpc-bridge failed: $($_.Exception.Message)"
        }
    }
}

# --- gRPC event stream (kills, captures, traps, presence) ------------------
#
# Keeps the StreamEvents reader alive and folds new events into combat-events
# and the activity feed. Cheap when idle: it reads the spool by byte offset.

$events = Join-Path $StateDir 'grpc-events.ps1'
if ((Test-Path $events) -and (@(Get-NetTCPConnection -LocalPort 50051 -State Listen -ErrorAction SilentlyContinue).Count -gt 0)) {
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File $events | Out-Null }
    catch { Write-Log "grpc-events failed: $($_.Exception.Message)" }
}
foreach ($f in 'combat-events.json', 'events.json') {
    $fp = Join-Path $StateDir $f
    if (Test-Path $fp) { $uploads[$f] = (Get-Content $fp -Raw -Encoding UTF8) }
}

# --- Off-box campaign backup ----------------------------------------------
#
# Rate-limited to every 15 minutes inside the script itself, and it exits
# immediately if the save has not changed, so calling it on every pass costs
# essentially nothing. The campaign is the one thing here that cannot be
# rebuilt, and a daily EBS snapshot is not a fine enough grain for it.

$backupScript = Join-Path $StateDir 'campaign-backup.ps1'
if (Test-Path $backupScript) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $backupScript | Out-Null
    } catch {
        Write-Log "campaign-backup failed: $($_.Exception.Message)"
    }
}

# --- Per-pilot combat stats ------------------------------------------------
#
# Folded in here rather than given its own scheduled task: pilot-stats.ps1
# reads the DCS log incrementally by byte offset, so a pass with no new lines
# costs essentially nothing, and one integration point is one thing to debug.

$statsScript = Join-Path $StateDir 'pilot-stats.ps1'
if (Test-Path $statsScript) {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $statsScript | Out-Null
    } catch {
        Write-Log "pilot-stats failed: $($_.Exception.Message)"
    }
}

$combatFile = Join-Path $StateDir 'combat.json'
if (Test-Path $combatFile) { $uploads['combat.json'] = (Get-Content $combatFile -Raw -Encoding UTF8) }

# --- Campaign timeline -----------------------------------------------------
#
# The board's "front line over time" view needs history, and Pretense only ever
# writes the CURRENT state -- yesterday's is gone the moment it saves. So we
# sample it here.
#
# Stored as JSON Lines rather than a JSON array on purpose: PowerShell 5.1's
# ConvertTo-Json unwraps a single-element array into a bare object, so a
# freshly-created history file would serialise as {...} instead of [{...}] and
# the board's .map() would throw. Appending one compact object per line and
# joining with commas at upload time sidesteps that entirely.
#
# A point is written when the interval elapses OR the zone balance changes --
# a zone flipping is the whole point of the chart and must not be lost to
# sampling.

$HistoryFile        = Join-Path $StateDir 'campaign-history.jsonl'
$HistoryIntervalSec = 600
$HistoryMaxPoints   = 1500

if ($uploads.ContainsKey('campaign.json')) {
    try {
        $blue  = $zoneBlue
        $red   = $zoneRed

        $lines = @()
        if (Test-Path $HistoryFile) {
            $lines = @(Get-Content $HistoryFile -ErrorAction SilentlyContinue | Where-Object { $_ -like '{*' })
        }

        $last = $null
        if ($lines.Count) { try { $last = $lines[-1] | ConvertFrom-Json } catch { } }

        $nowTs   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $changed = (-not $last) -or ([int]$last.b -ne $blue) -or ([int]$last.r -ne $red)
        $aged    = (-not $last) -or (($nowTs - [int64]$last.t) -ge $HistoryIntervalSec)

        if ($changed -or $aged) {
            $line = '{{"t":{0},"b":{1},"r":{2},"n":{3},"p":{4}}}' -f `
                $nowTs, $blue, $red, $zoneTotal, $players
            Add-Content $HistoryFile $line -Encoding ascii
            $lines += $line

            if ($lines.Count -gt $HistoryMaxPoints) {
                $lines = $lines[($lines.Count - $HistoryMaxPoints)..($lines.Count - 1)]
                Set-Content $HistoryFile $lines -Encoding ascii
            }
        }

        if ($lines.Count) { $uploads['history.json'] = '[' + ($lines -join ',') + ']' }
    } catch {
        Write-Log "campaign history sampling failed: $($_.Exception.Message)"
    }
}

# --- Upload only what changed ---------------------------------------------

$hashes = @{}
if (Test-Path $HashFile) {
    try {
        (Get-Content $HashFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $hashes[$_.Name] = $_.Value }
    } catch { }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$changed = 0

foreach ($name in $uploads.Keys) {
    $content = $uploads[$name]
    if (-not $content) { continue }

    $hash = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($content)))

    # status.json always goes up -- its whole purpose is a fresh timestamp.
    if ($hashes[$name] -eq $hash -and $name -ne 'status.json') { continue }

    $tmp = Join-Path $env:TEMP $name
    [IO.File]::WriteAllText($tmp, $content)

    # Short max-age: the board polls, and stale data on a live map is worse
    # than an extra request. These files are tens of KB.
    & $aws s3 cp $tmp "s3://$Bucket/data/$name" --region $region `
        --content-type 'application/json' `
        --cache-control 'public, max-age=10' `
        --only-show-errors

    if ($LASTEXITCODE -eq 0) {
        $hashes[$name] = $hash
        $changed++
    } else {
        Write-Log "upload failed for $name (exit $LASTEXITCODE)"
    }

    [IO.File]::Delete($tmp)
}

[IO.File]::WriteAllText($HashFile, ($hashes | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
if ($changed -gt 0) { Write-Log "uploaded $changed file(s); players=$players fps=$fps" }
