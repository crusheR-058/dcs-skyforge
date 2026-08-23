<#
.SYNOPSIS
    Stops the EC2 instance once the DCS server has sat empty long enough.

.DESCRIPTION
    Runs every 5 minutes as SYSTEM via Task Scheduler (registered by setup.ps1).

    This is the script that makes on-demand hosting economically real. Without
    it, one forgotten game night turns a ~$48/month server into ~$547/month.

    Occupancy is decided from two independent signals:

      1. C:\dcs-state\players.json, written by the in-game hook script. This is
         authoritative whenever it is fresh.

      2. Network egress rate, used only when (1) is stale or missing. If DCS has
         crashed or the hook was never installed, a genuinely occupied server
         still pushes tens of kbps upstream; an empty one does not. This stops a
         broken hook from kicking players off mid-sortie.

    When neither signal says "occupied", an idle timer runs. Two thresholds:

      -IdleMinutes             (default 20) once somebody has joined this boot
      -FirstJoinGraceMinutes   (default 45) if nobody has joined yet

    The longer grace exists because someone typically starts the server before
    the group assembles. The shorter one applies afterwards, when an empty
    server means everyone has gone to bed.

    This is one of three independent stop mechanisms. The others are the nightly
    EventBridge force-stop and the AWS budget alarm. Do not rely on any one.

.PARAMETER WhatIf
    Log the decision but never actually shut down. Use this to watch it make
    correct calls for a session before trusting it.
#>

[CmdletBinding()]
param(
    [int]$IdleMinutes = 20,
    [int]$FirstJoinGraceMinutes = 45,
    [int]$PlayerDataMaxAgeSeconds = 180,

    # ~20 kbps. A single DCS client costs well over this; an idle Windows box
    # (telemetry, updates polling) sits well under it.
    [int]$OccupiedBytesPerSecond = 2500,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$StateDir    = 'C:\dcs-state'
$PlayersFile = Join-Path $StateDir 'players.json'
$StateFile   = Join-Path $StateDir 'watchdog-state.json'
$LogFile     = Join-Path $StateDir 'watchdog.log'
$ParamName   = '/dcs/playercount'

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Write-Log {
    param([string]$Message)

    # Keep the log bounded; this runs 288 times a day forever.
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
        Move-Item -Force $LogFile "$LogFile.old"
    }

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line
    Write-Verbose $line
}

function Get-InstanceMetadata {
    param([string]$Path)

    try {
        $token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
            -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }

        return Invoke-RestMethod -TimeoutSec 5 `
            -Uri "http://169.254.169.254/latest/meta-data/$Path" `
            -Headers @{ 'X-aws-ec2-metadata-token' = $token }
    } catch {
        return $null
    }
}

function Publish-PlayerCount {
    <#
        Best effort only. /dcs status is nicer when this works, but the shutdown
        decision never depends on it -- so a failure here is logged and ignored.
    #>
    param([string]$Json, [string]$Region)

    if (-not $Region) { return $false }

    $awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    if (Test-Path $awsExe) {
        & $awsExe ssm put-parameter --name $ParamName --value $Json `
            --type String --overwrite --region $Region 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    }

    foreach ($module in 'AWS.Tools.SimpleSystemsManagement', 'AWSPowerShell.NetCore', 'AWSPowerShell') {
        try { Import-Module $module -ErrorAction Stop; break } catch { }
    }

    if (Get-Command Write-SSMParameter -ErrorAction SilentlyContinue) {
        try {
            Write-SSMParameter -Name $ParamName -Value $Json -Type String `
                -Overwrite $true -Region $Region | Out-Null
            return $true
        } catch { }
    }

    return $false
}

# ---------------------------------------------------------------------------

$now      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')

# --- Load state, resetting on a new boot -----------------------------------

$state = @{
    bootTime      = $bootTime
    idleSince     = $null
    everOccupied  = $false
    lastBytesSent = $null
    lastCheck     = $null
}

if (Test-Path $StateFile) {
    try {
        $loaded = Get-Content $StateFile -Raw | ConvertFrom-Json
        if ($loaded.bootTime -eq $bootTime) {
            foreach ($property in $loaded.PSObject.Properties) {
                $state[$property.Name] = $property.Value
            }
        } else {
            Write-Log 'New boot detected - idle timer reset'
        }
    } catch {
        Write-Log "State file unreadable, starting fresh: $($_.Exception.Message)"
    }
}

# --- Signal 1: the in-game hook --------------------------------------------

$players     = 0
$mission     = 'unknown'
$names       = @()
$playersFresh = $false

if (Test-Path $PlayersFile) {
    try {
        $data = Get-Content $PlayersFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $age  = $now - [int64]$data.ts

        if ($age -le $PlayerDataMaxAgeSeconds) {
            $players      = [int]$data.players
            $mission      = [string]$data.mission
            $playersFresh = $true

            # Roster is for /dcs status only. Never let a malformed names array
            # take down the shutdown logic that protects the bill.
            try {
                if ($data.PSObject.Properties.Name -contains 'names' -and $data.names) {
                    $names = @($data.names)
                }
            } catch { }
        } else {
            Write-Log "players.json is stale (${age}s old) - falling back to network heuristic"
        }
    } catch {
        Write-Log "players.json unreadable: $($_.Exception.Message)"
    }
} else {
    Write-Log 'players.json missing - is the hook script installed?'
}

# --- Signal 2: network egress ----------------------------------------------

$bytesSent = (Get-NetAdapterStatistics | Measure-Object -Property SentBytes -Sum).Sum

if ($playersFresh) {
    $occupied = $players -gt 0
    $reason   = "hook reports $players player(s)"
} elseif ($null -ne $state.lastBytesSent -and $null -ne $state.lastCheck) {
    $elapsed = $now - [int64]$state.lastCheck

    if ($elapsed -gt 0) {
        $rate     = [math]::Max(0, ($bytesSent - [int64]$state.lastBytesSent)) / $elapsed
        $occupied = $rate -ge $OccupiedBytesPerSecond
        $reason   = 'no fresh hook data; egress {0:N0} B/s vs {1:N0} threshold' -f $rate, $OccupiedBytesPerSecond
    } else {
        $occupied = $true
        $reason   = 'no elapsed time to measure'
    }
} else {
    # First run after boot: no baseline to compare against. Assume occupied for
    # this tick rather than risk shutting down a server that just came up.
    $occupied = $true
    $reason   = 'establishing network baseline'
}

$state.lastBytesSent = $bytesSent
$state.lastCheck     = $now

# --- Idle accounting -------------------------------------------------------

if ($occupied) {
    if (-not $state.everOccupied -and $playersFresh -and $players -gt 0) {
        Write-Log 'First player joined this boot - switching to the short idle threshold'
        $state.everOccupied = $true
    }
    $state.idleSince = $null
} elseif ($null -eq $state.idleSince) {
    $state.idleSince = $now
}

$thresholdMinutes = if ($state.everOccupied) { $IdleMinutes } else { $FirstJoinGraceMinutes }

$idleMinutes = 0
if ($null -ne $state.idleSince) {
    $idleMinutes = [math]::Floor(($now - [int64]$state.idleSince) / 60)
}

Write-Log ("occupied={0} ({1}) idle={2}/{3}min everOccupied={4}" -f `
    $occupied, $reason, $idleMinutes, $thresholdMinutes, $state.everOccupied)

# --- Publish for /dcs status ----------------------------------------------

$region = Get-InstanceMetadata -Path 'placement/region'
$payload = @{
    players = $players
    mission = $mission
    names   = $names
    ts      = $now
} | ConvertTo-Json -Compress -Depth 4

Publish-PlayerCount -Json $payload -Region $region | Out-Null

# --- Decide ----------------------------------------------------------------

$state | ConvertTo-Json -Compress | Set-Content -Path $StateFile -Encoding utf8

if ($null -ne $state.idleSince -and $idleMinutes -ge $thresholdMinutes) {
    if ($WhatIf) {
        Write-Log "WHATIF: would stop the instance now (idle ${idleMinutes}min)"
        return
    }

    Write-Log "Idle for ${idleMinutes}min - stopping the instance"

    # Post the session's performance chart before shutting down, to the same
    # Discord webhook /dcs perf uses.
    #
    # Gated on everOccupied deliberately: without it, every idle timeout on a
    # server nobody joined would post a flat, meaningless chart. Only sessions
    # somebody actually flew are worth reporting.
    if ($state.everOccupied) {
        try {
            $upMinutes = [int](((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes)
            $sessionHours = [math]::Max(1, [math]::Ceiling($upMinutes / 60))
            Write-Log "posting session report covering ${sessionHours}h"
            & 'C:\dcs-state\perf-report.ps1' -Hours $sessionHours
        } catch {
            # Never let a reporting failure block the shutdown -- the whole
            # point of this script is that the instance stops billing.
            Write-Log "session report failed: $($_.Exception.Message)"
        }
    }

    # instance_initiated_shutdown_behavior = "stop" turns this into an EC2 stop
    # rather than a terminate. If that is ever set to "terminate", this line
    # destroys the DCS install.
    Stop-Computer -Force
}
