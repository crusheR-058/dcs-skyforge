<#
.SYNOPSIS
    Push the Pretense campaign save off the box, on a timer.

.DESCRIPTION
    The campaign save is the only genuinely irreplaceable thing on this server.
    The DCS install, the mods, the config -- all of that can be rebuilt in a
    day. Hours of a group's progress cannot, and Pretense rewrites the file
    roughly every 60 seconds, so a daily EBS snapshot is not a good enough
    answer on its own.

    This keeps a dated local copy and mirrors it to S3. Both are tiny: the save
    is ~33 KB, so a copy every 15 minutes is about 3 MB a day.

    Rate-limited internally rather than given its own scheduled task -- it is
    invoked from skyforge-upload.ps1, which already runs four times a minute,
    and returns immediately unless the interval has elapsed. One integration
    point is one thing to debug.

.PARAMETER IntervalMinutes
    Minimum gap between backups. The caller may run far more often than this.

.PARAMETER KeepLocalDays
    Local dated folders older than this are pruned. S3 copies are left alone --
    they cost fractions of a cent and are the off-box copy that matters.
#>

[CmdletBinding()]
param(
    [string]$StateDir   = 'C:\dcs-state',
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server',
    [string]$Bucket     = 'dcs-skyforge-transfer-123456789012',
    [int]$IntervalMinutes = 15,
    [int]$KeepLocalDays   = 7,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$MarkerFile = Join-Path $StateDir 'campaign-backup.marker'
$LogFile    = Join-Path $StateDir 'campaign-backup.log'
$BackupRoot = Join-Path $StateDir 'campaign-backup'

function Write-Log {
    param([string]$m)
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 256KB) {
        Move-Item -Force $LogFile "$LogFile.old"
    }
    Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

# --- rate limit ------------------------------------------------------------

if (-not $Force -and (Test-Path $MarkerFile)) {
    $age = (Get-Date) - (Get-Item $MarkerFile).LastWriteTime
    if ($age.TotalMinutes -lt $IntervalMinutes) { exit 0 }
}

$aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
if (-not (Test-Path $aws)) { Write-Log 'AWS CLI missing'; exit 1 }

# --- find the saves --------------------------------------------------------

$saves = Get-ChildItem (Join-Path $SavedGames 'Missions') -Recurse `
    -Include 'pretense*.json', 'player_stats.json' -File -ErrorAction SilentlyContinue
if (-not $saves) { Write-Log 'no save files found'; exit 0 }

# Nothing to do if the campaign has not moved since the last backup. Cheap
# guard that keeps an idle server from writing a folder every 15 minutes.
$sig = ($saves | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Length):$($_.LastWriteTimeUtc.Ticks)" }) -join '|'
$sigFile = Join-Path $StateDir 'campaign-backup.sig'
if (-not $Force -and (Test-Path $sigFile)) {
    if ((Get-Content $sigFile -Raw -ErrorAction SilentlyContinue).Trim() -eq $sig) {
        # Touch the marker so we do not rescan every single pass.
        # (No ?. operator here: the server is Windows PowerShell 5.1.)
        if (Test-Path $MarkerFile) {
            (Get-Item $MarkerFile).LastWriteTime = Get-Date
        } else {
            Set-Content $MarkerFile 'unchanged' -Encoding ascii
        }
        exit 0
    }
}

# --- copy ------------------------------------------------------------------

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dest  = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$saves | Copy-Item -Destination $dest -Force

$region = 'ap-south-2'
try {
    $token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
        -Uri 'http://169.254.169.254/latest/api/token' `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
    $region = Invoke-RestMethod -TimeoutSec 5 `
        -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
        -Headers @{ 'X-aws-ec2-metadata-token' = $token }
} catch { }

& $aws s3 sync $dest "s3://$Bucket/campaign-backups/$stamp/" --region $region --only-show-errors
$ok = ($LASTEXITCODE -eq 0)

if ($ok) {
    Set-Content $sigFile $sig -Encoding ascii
    Set-Content $MarkerFile $stamp -Encoding ascii
    $bytes = ($saves | Measure-Object Length -Sum).Sum
    Write-Log ("backed up {0} file(s), {1:N0} bytes -> s3://{2}/campaign-backups/{3}/" -f $saves.Count, $bytes, $Bucket, $stamp)
} else {
    # Deliberately do NOT advance the marker: a failed upload should be retried
    # on the next pass, not silently skipped for another 15 minutes.
    Write-Log "S3 sync FAILED (exit $LASTEXITCODE) - local copy kept at $dest"
}

# --- prune local copies ----------------------------------------------------

$cutoff = (Get-Date).AddDays(-$KeepLocalDays)
Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff } |
    ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "pruned local $($_.Name)"
    }
