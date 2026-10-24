<#
.SYNOPSIS
    Archive and clear pilot statistics so the board and VIAF Ops start from zero.

.DESCRIPTION
    Stops DCS and the SkyForge publishers, then MOVES every statistics file into
    C:\dcs-state\archive\<Label>\. Nothing is deleted, so a reset is undone by
    moving the files back. DCS is left stopped; it starts again on the next boot
    (or Start-ScheduledTask DCS-Server).

    Cleared: dcs.log tallies, DCS-gRPC kill tallies and its spool, the event
    feed, campaign history samples, pilot presence, Pretense player_stats.json
    (XP and ranks), Tacview bookkeeping and local recordings, and the upload
    hash cache (so the next upload republishes everything).

    NOT touched: the Pretense campaign save (zone ownership), missions, config.

    dcs.log is archived too. pilot-stats.ps1 re-reads dcs.log from offset 0
    when its state is gone, and would otherwise re-tally the old session.

    The S3 side is separate: copy data/ to archive/<Label>/ first, and delete
    the statistics feeds only after the instance has stopped, or the uploader
    puts them straight back.

.EXAMPLE
    .\reset-stats.ps1 -Label test-mission-2026-10-24
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Label,
    [string]$StateDir   = 'C:\dcs-state',
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server'
)

$ErrorActionPreference = 'Stop'

$archive = Join-Path $StateDir "archive\$Label"
if (Test-Path $archive) { throw "Archive $archive already exists. Pick a new label; nothing was changed." }
New-Item -ItemType Directory -Force $archive | Out-Null

# Stop everything that writes these files, so nothing is rewritten mid-move.
foreach ($t in 'SkyForge-Upload', 'SkyForge-GrpcStream', 'DCS-Server') {
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
}
Get-Process DCS_server, grpcurl -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 5
if (Get-Process DCS_server -ErrorAction SilentlyContinue) { throw 'DCS is still running; nothing was moved.' }

# A list object, not an array: the function adds to it in place. ($script:moved
# pointed at the wrong scope when this runs inside a script block, e.g. via SSM.)
$moved = [System.Collections.Generic.List[string]]::new()
function Move-ToArchive([string]$Path, [string]$Name) {
    if (Test-Path $Path) {
        Move-Item -LiteralPath $Path -Destination (Join-Path $archive $Name)
        $moved.Add($Name)
    }
}

foreach ($f in 'pilot-stats-state.json', 'combat.json',
               'grpc-events-state.json', 'grpc-events.ndjson', 'combat-events.json', 'events.json',
               'campaign-history.jsonl', 'pilot-log.json',
               'tacview-seen.json', 'skyforge-hashes.json',
               'players.json', 'live.json') {
    Move-ToArchive (Join-Path $StateDir $f) $f
}

$i = 0
Get-ChildItem (Join-Path $SavedGames 'Missions') -Recurse -Filter 'player_stats.json' -ErrorAction SilentlyContinue |
    ForEach-Object { $i++; Move-ToArchive $_.FullName "player_stats.$i.json" }

Move-ToArchive (Join-Path $SavedGames 'Logs\dcs.log') 'dcs.log'
Move-ToArchive (Join-Path $StateDir 'tacview') 'tacview'

# Keep the recordings folder in place for the next session's Tacview output.
New-Item -ItemType Directory -Force (Join-Path $StateDir 'tacview') | Out-Null

"Archived to ${archive}:"
$moved
"DCS is stopped. It starts on the next boot, or: Start-ScheduledTask DCS-Server"
