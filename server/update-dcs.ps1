<#
.SYNOPSIS
    Patch the DCS dedicated server and bring it back up.

.DESCRIPTION
    Patch day is the one failure that locks the whole group out at once. DCS
    refuses a client whose build differs from the server's, so the morning
    after an Eagle Dynamics release nobody can join until the server updates --
    and the symptom players report is a bare "connection failed", which looks
    nothing like "the server needs patching".

    Three ways this runs:

        weekly    EventBridge starts the instance, the maintenance Lambda calls
                  this, the idle watchdog stops the box afterwards
        /dcs update   someone in Discord, for a mid-week hotfix
        manual    over SSM

    It always stops DCS, updates, and starts it again. There is deliberately no
    "check first, skip if current" path: the updater is the only authority on
    whether an update exists, and the restart costs ~90 seconds on a server
    that is empty by precondition anyway.

.NOTES
    REFUSES while anyone is connected unless -Force. Updating takes DCS down
    for several minutes and there is no version of that which is acceptable to
    do to someone on final approach.

    The updater writes autoupdate_log.txt in the install root. If an update
    ever fails, that file -- not this script's log -- is the thing to read.
#>

[CmdletBinding()]
param(
    [string]$DcsPath      = 'C:\DCS_server',
    [string]$StateDir     = 'C:\dcs-state',
    [string]$WebhookParam = '/dcs/discord-webhook',
    [string]$Reason       = 'manual',
    [switch]$Force,
    [int]$TimeoutMinutes  = 45
)

$ErrorActionPreference = 'Continue'

$LogFile     = Join-Path $StateDir 'update-dcs.log'
$PlayersFile = Join-Path $StateDir 'players.json'
$Updater     = Join-Path $DcsPath 'bin\DCS_updater.exe'
$VersionFile = Join-Path $DcsPath 'autoupdate.cfg'

function Write-Log {
    param([string]$Message)
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
        Move-Item -Force $LogFile "$LogFile.old"
    }
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content $LogFile $line
    Write-Output $line
}

function Get-Region {
    $token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
        -Uri 'http://169.254.169.254/latest/api/token' `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
    return Invoke-RestMethod -TimeoutSec 5 `
        -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
        -Headers @{ 'X-aws-ec2-metadata-token' = $token }
}

function Send-Discord {
    # Best effort. A patch must never fail because a chat message did not send.
    param([string]$Message)
    try {
        $aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
        $url = (& $aws ssm get-parameter --name $WebhookParam --with-decryption `
                    --region (Get-Region) --query Parameter.Value --output text).Trim()
        if (-not $url) { return }
        $body = @{ content = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 | Out-Null
    } catch {
        Write-Log "discord notify failed: $($_.Exception.Message)"
    }
}

function Get-DcsVersion {
    # autoupdate.cfg is JSON and carries the installed build. Comparing it
    # across the update is the only reliable way to tell whether anything
    # actually changed -- the updater exits 0 either way.
    try {
        if (Test-Path $VersionFile) {
            $cfg = Get-Content $VersionFile -Raw | ConvertFrom-Json
            if ($cfg.version) { return [string]$cfg.version }
        }
    } catch { }
    try {
        $exe = Join-Path $DcsPath 'bin\DCS_server.exe'
        if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.FileVersion }
    } catch { }
    return 'unknown'
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Write-Log "=== update requested (reason=$Reason force=$Force) ==="

if (-not (Test-Path $Updater)) {
    Write-Log "FATAL: DCS_updater.exe not found at $Updater"
    Send-Discord ":x: **DCS update failed** - updater not found at ``$Updater``."
    exit 1
}

# --- Refuse to patch on top of live players --------------------------------

$players = 0
try {
    $pj  = Get-Content $PlayersFile -Raw | ConvertFrom-Json
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$pj.ts
    if ($age -le 180) { $players = [int]$pj.players }
} catch { }

if ($players -gt 0 -and -not $Force) {
    Write-Log "ABORT: $players player(s) connected"
    Send-Discord ":warning: **DCS update skipped** - $players pilot(s) still flying. It will retry at the next maintenance window."
    exit 0
}

$before = Get-DcsVersion
Write-Log "installed version before: $before"
Send-Discord ":tools: **Patching the DCS server** (build ``$before``). Back in a few minutes."

# --- Stop DCS --------------------------------------------------------------

Stop-ScheduledTask -TaskName 'DCS-Server' -ErrorAction SilentlyContinue
$proc = Get-Process DCS_server -ErrorAction SilentlyContinue
if ($proc) {
    Write-Log "stopping DCS_server PID $($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    $waited = 0
    while ((Get-Process DCS_server -ErrorAction SilentlyContinue) -and $waited -lt 60) {
        Start-Sleep -Seconds 2; $waited += 2
    }
    Write-Log "DCS exited after ${waited}s"
} else {
    Write-Log 'DCS was not running'
}
Start-Sleep -Seconds 5

# --- Update ----------------------------------------------------------------

Write-Log "running: $Updater --quiet update"
$exit = -1
try {
    $p = Start-Process -FilePath $Updater -ArgumentList '--quiet', 'update' `
        -WorkingDirectory $DcsPath -PassThru -NoNewWindow
    if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        Write-Log "TIMEOUT after $TimeoutMinutes min - killing updater"
        try { $p.Kill() } catch { }
        Send-Discord ":x: **DCS update timed out** after $TimeoutMinutes minutes. Server is being restarted on the old build."
    } else {
        $exit = $p.ExitCode
        Write-Log "updater exit code: $exit"
    }
} catch {
    Write-Log "updater failed to launch: $($_.Exception.Message)"
}

$after = Get-DcsVersion
Write-Log "installed version after: $after"

# --- Restart ---------------------------------------------------------------

Write-Log 'starting DCS again'
Start-ScheduledTask -TaskName 'DCS-Server'

$waited = 0
$up = $false
while ($waited -lt 300 -and -not $up) {
    Start-Sleep -Seconds 15
    $waited += 15
    if (Get-Process DCS_server -ErrorAction SilentlyContinue) {
        try {
            $pj = Get-Content $PlayersFile -Raw | ConvertFrom-Json
            if (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$pj.ts) -le 60) { $up = $true }
        } catch { }
    }
}
Write-Log ("server back up: {0} (after {1}s)" -f $up, $waited)

# --- Report ----------------------------------------------------------------

if ($after -ne $before) {
    $msg = ":white_check_mark: **DCS server updated** - ``$before`` to ``$after``.`n" +
           "**Everyone must update their own DCS to the same build before they can join.**"
} elseif ($exit -eq 0) {
    $msg = ":white_check_mark: **DCS server checked for updates** - already on ``$after``, nothing to do."
} else {
    $msg = ":x: **DCS update did not complete** (exit ``$exit``, still on ``$after``). See ``autoupdate_log.txt`` on the server."
}

if (-not $up) {
    $msg += "`n:rotating_light: **The server did not come back within 5 minutes.** Someone needs to look at it."
}

Send-Discord $msg
Write-Log '=== update finished ==='
