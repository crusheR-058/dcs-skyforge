<#
.SYNOPSIS
    Announce in Discord when the DCS server becomes joinable.

.DESCRIPTION
    An on-demand server has one recurring social problem: nobody knows it is
    up. Whoever ran /dcs start knows, and everyone else finds out by asking.
    Scheduled game nights make that worse -- the server boots itself at 19:45
    and sits there empty because no human was involved to tell anyone.

    So this posts once per boot, when DCS is actually joinable rather than when
    the instance started. Those are three to five minutes apart, and announcing
    the wrong one trains people to ignore the message.

    "Once per boot" is enforced with a marker file stamped with the OS boot
    time. A marker keyed to anything else -- a date, a fixed filename -- either
    goes stale across a stop/start on the same day or survives a reboot it
    should not have.

.NOTES
    Runs from the SkyForge-Announce scheduled task at startup. Exits quietly
    and often: most invocations happen while DCS is still loading.
#>

[CmdletBinding()]
param(
    [string]$StateDir     = 'C:\dcs-state',
    [string]$WebhookParam = '/dcs/discord-webhook',
    [string]$BoardUrl     = 'https://d111111abcdef8.cloudfront.net',
    [int]$WaitMinutes     = 12
)

$ErrorActionPreference = 'Continue'

$LogFile     = Join-Path $StateDir 'announce.log'
$PlayersFile = Join-Path $StateDir 'players.json'

function Write-Log {
    param([string]$Message)
    Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
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
    param([string]$Message)
    try {
        $aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
        $url = (& $aws ssm get-parameter --name $WebhookParam --with-decryption `
                    --region (Get-Region) --query Parameter.Value --output text).Trim()
        if (-not $url) { Write-Log 'no webhook configured'; return $false }
        $body = @{ content = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 | Out-Null
        return $true
    } catch {
        Write-Log "discord post failed: $($_.Exception.Message)"
        return $false
    }
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$boot   = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$marker = Join-Path $StateDir ("announced-{0}.marker" -f $boot.ToString('yyyyMMddHHmmss'))

if (Test-Path $marker) { exit 0 }

# --- Wait for DCS to be genuinely joinable ---------------------------------

$deadline = (Get-Date).AddMinutes($WaitMinutes)
$mission  = $null

while ((Get-Date) -lt $deadline) {
    if (Get-Process DCS_server -ErrorAction SilentlyContinue) {
        try {
            $pj  = Get-Content $PlayersFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$pj.ts
            # A fresh players.json means the mission is loaded and the hook is
            # running -- the process existing on its own proves neither.
            if ($age -le 60) { $mission = [string]$pj.mission; break }
        } catch { }
    }
    Start-Sleep -Seconds 20
}

if (-not $mission) {
    Write-Log "DCS not joinable within $WaitMinutes min - not announcing"
    exit 0
}

# Listening on the game port is the last thing that has to be true.
$listening = @(Get-NetTCPConnection -LocalPort 10308 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
if (-not $listening) {
    Write-Log 'DCS reporting but not listening on 10308 - not announcing'
    exit 0
}

$address = '203.0.113.10:10308'
$srs     = '203.0.113.10:5002'

$message = @"
:green_circle: **SkyForge is up.**
**Connect** ``$address``  (password in the pinned message)
**SRS** ``$srs``
**Mission** *$mission*
Live board: <$BoardUrl>
"@

if (Send-Discord $message) {
    Set-Content $marker (Get-Date -Format 'o') -Encoding ascii
    Write-Log "announced: $mission"

    # One marker per boot, but the folder should not accumulate them forever.
    Get-ChildItem (Join-Path $StateDir 'announced-*.marker') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
