<#
.SYNOPSIS
    Post-install configuration for the DCS dedicated server on EC2.

.DESCRIPTION
    Run this ONCE over RDP, as Administrator, AFTER installing DCS World
    Dedicated Server. Terraform's user_data handles the OS-level prep; this
    handles everything that depends on DCS actually being installed.

    It will:
      1. Add Windows Defender exclusions for the DCS directories
      2. Install the player-count hook into Saved Games
      3. Register "DCS-Server"   -- starts DCS at boot, so /dcs start works
      4. Register "DCS-Watchdog" -- stops the instance when nobody is playing

.PARAMETER RunAsUser
    Account the DCS task runs as. This matters more than it looks: DCS reads its
    config from that account's "Saved Games" folder. Running as SYSTEM would
    read C:\Windows\System32\config\systemprofile\Saved Games\DCS.server and
    silently ignore everything you configured as Administrator.

.NOTES
    MEASURED ON THE LIVE SERVER (2026-08-20): DCS_server.exe will NOT run
    headlessly in session 0. Started as SYSTEM with an -AtStartup trigger it
    reaches ~222 MB, writes 10 log lines, and hangs forever -- it is blocked on
    a "DCS Login" dialog (a plain Win32 #32770) that has no session to draw in.
    UI Automation cannot even see the window from session 0.

    The working arrangement, which this script now configures, is:
      * autologon enabled for RunAsUser, so an interactive session always exists
      * DCS-Server registered -AtLogOn as that user, LogonType Interactive
      * a one-time login is driven into the dialog; DCS then writes its own
        token to Config\autologin.cfg and never prompts again

    A hand-written autologin.cfg does NOT work -- DCS ignores it. The file must
    be produced by DCS itself after a real login with "Save password" and
    "Auto login" ticked.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -DcsPath 'D:\DCS World Server' -IdleMinutes 30
#>

[CmdletBinding()]
param(
    [string]$DcsPath = 'C:\Program Files\Eagle Dynamics\DCS World Server',
    [string]$RunAsUser = 'Administrator',
    [int]$IdleMinutes = 20,
    [int]$FirstJoinGraceMinutes = 45,
    [switch]$SkipDefender
)

$ErrorActionPreference = 'Stop'

$StateDir   = 'C:\dcs-state'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SavedGames = Join-Path $env:USERPROFILE 'Saved Games\DCS.server'

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [!!] $Message" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------

Write-Step 'Validating the DCS installation'

$dcsExe = Join-Path $DcsPath 'bin\DCS_server.exe'
if (-not (Test-Path $dcsExe)) {
    # Newer builds ship the multithreaded binary under bin-mt.
    $dcsExeMt = Join-Path $DcsPath 'bin-mt\DCS_server.exe'
    if (Test-Path $dcsExeMt) {
        $dcsExe = $dcsExeMt
    } else {
        throw "DCS_server.exe not found under '$DcsPath'. Install DCS first, or pass -DcsPath."
    }
}
Write-Ok "found $dcsExe"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $SavedGames 'Scripts\Hooks') | Out-Null

# ---------------------------------------------------------------------------

if (-not $SkipDefender) {
    Write-Step 'Adding Defender exclusions'

    # Real-time scanning of the DCS tree costs measurable frame time on mission
    # load and during terrain streaming. The box has no inbound admin ports and
    # runs exactly one application, so this is a reasonable trade.
    foreach ($path in @($DcsPath, $SavedGames, $StateDir)) {
        try {
            Add-MpPreference -ExclusionPath $path
            Write-Ok "excluded $path"
        } catch {
            Write-Warn "could not exclude ${path}: $($_.Exception.Message)"
        }
    }

    try {
        Add-MpPreference -ExclusionProcess 'DCS_server.exe'
        Write-Ok 'excluded process DCS_server.exe'
    } catch {
        Write-Warn "could not exclude process: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------

Write-Step 'Installing the player-count hook'

$hookSource = Join-Path $ScriptRoot 'Hooks\playercount.lua'
$hookTarget = Join-Path $SavedGames 'Scripts\Hooks\playercount.lua'

if (-not (Test-Path $hookSource)) {
    throw "Hook script not found at $hookSource"
}

Copy-Item -Path $hookSource -Destination $hookTarget -Force
Write-Ok "installed $hookTarget"

# ---------------------------------------------------------------------------

Write-Step 'Installing the watchdog'

$watchdogSource = Join-Path $ScriptRoot 'watchdog.ps1'
$watchdogTarget = Join-Path $StateDir 'watchdog.ps1'

if (-not (Test-Path $watchdogSource)) {
    throw "Watchdog script not found at $watchdogSource"
}

Copy-Item -Path $watchdogSource -Destination $watchdogTarget -Force
Write-Ok "installed $watchdogTarget"

# ---------------------------------------------------------------------------

Write-Step "Registering scheduled task 'DCS-Server' (start DCS at boot)"

Write-Host @"
    DCS will run as '$RunAsUser' so it reads:
      $SavedGames

    Enter that account's password. On a fresh EC2 Windows instance, retrieve it
    with:
      aws ec2 get-password-data --instance-id <id> --priv-launch-key <key>.pem
"@ -ForegroundColor Gray

$credential = Get-Credential -UserName $RunAsUser -Message "Password for $RunAsUser (runs DCS at boot)"

# Launch through start-dcs.ps1 rather than DCS_server.exe directly. That
# wrapper applies any mission queued by /dcs add-mission in the one safe window
# -- after DCS has exited, before it starts again. Editing serverSettings.lua
# while DCS is running does not work: DCS rewrites it from memory on exit and
# silently discards the change.
$launcher = Join-Path $StateDir 'start-dcs.ps1'
Copy-Item -Path (Join-Path $ScriptRoot 'start-dcs.ps1') -Destination $launcher -Force
Copy-Item -Path (Join-Path $ScriptRoot 'add-mission.ps1') -Destination (Join-Path $StateDir 'add-mission.ps1') -Force

$dcsAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$launcher`" " +
               "-DcsExe `"$dcsExe`" -SavedGames `"$SavedGames`"") `
    -WorkingDirectory (Split-Path -Parent $dcsExe)

# -AtLogOn, not -AtStartup: DCS needs an interactive session (see .NOTES).
# Pair this with autologon so a session exists without anyone touching RDP.
$dcsTrigger = New-ScheduledTaskTrigger -AtLogOn -User $RunAsUser

$dcsSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# 0 is highest, 7 is the default for scheduled tasks. DCS is the only thing
# this machine does; let it win any contention with background Windows work.
$dcsSettings.Priority = 4

Unregister-ScheduledTask -TaskName 'DCS-Server' -Confirm:$false -ErrorAction SilentlyContinue

$dcsPrincipal = New-ScheduledTaskPrincipal -UserId $RunAsUser `
    -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName 'DCS-Server' `
    -Description 'Starts the DCS dedicated server at logon' `
    -Action $dcsAction `
    -Trigger $dcsTrigger `
    -Settings $dcsSettings `
    -Principal $dcsPrincipal | Out-Null

Write-Ok 'DCS-Server registered (at logon, interactive)'

# ---------------------------------------------------------------------------

Write-Step 'Enabling autologon'

# Without an interactive session DCS hangs on an invisible login dialog. The
# password lives in the registry, which is why this box must never expose RDP
# to the internet -- it does not: 3389 is closed and admin is via SSM only.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name 'DefaultUserName' -Value $RunAsUser -Type String
Set-ItemProperty -Path $winlogon -Name 'DefaultPassword' `
    -Value $credential.GetNetworkCredential().Password -Type String
Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '1' -Type String
Set-ItemProperty -Path $winlogon -Name 'DefaultDomainName' -Value '.' -Type String

Write-Ok "autologon enabled for $RunAsUser"

# ---------------------------------------------------------------------------

Write-Step "Registering scheduled task 'DCS-Watchdog' (idle shutdown)"

$watchdogAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$watchdogTarget`" " +
               "-IdleMinutes $IdleMinutes -FirstJoinGraceMinutes $FirstJoinGraceMinutes")

$watchdogTrigger = New-ScheduledTaskTrigger -AtStartup
$watchdogTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition

$watchdogSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName 'DCS-Watchdog' -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName 'DCS-Watchdog' `
    -Description 'Stops the EC2 instance when the DCS server sits empty' `
    -Action $watchdogAction `
    -Trigger $watchdogTrigger `
    -Settings $watchdogSettings `
    -Principal $watchdogPrincipal | Out-Null

Write-Ok "DCS-Watchdog registered (every 5 min, ${IdleMinutes}min idle threshold)"

# ---------------------------------------------------------------------------

Write-Step "Registering scheduled task 'SkyForge-Upload' (web board publisher)"

# Task Scheduler stores the argument string verbatim, and a -Command payload
# containing nested quotes is where this WILL bite you: a subtly mis-escaped
# `-Command "..."` makes powershell.exe exit 0 without running anything, so the
# task reports Success forever while doing precisely nothing. That failure --
# a board frozen for a whole day while every health check said "result=0" --
# is why the payload is base64-encoded instead. -EncodedCommand takes a single
# token with no quoting for the scheduler to mangle.
#
# The inner loop runs the publisher 4x per firing, 14s apart, because Task
# Scheduler's minimum repetition interval is 1 minute and the board wants ~15s
# freshness. Errors are appended to the log rather than swallowed.

$uploadScript = Join-Path $StateDir 'skyforge-upload.ps1'
$uploadLog    = Join-Path $StateDir 'skyforge-upload.log'

$inner = "1..4 | ForEach-Object { try { & '$uploadScript' } catch { Add-Content '$uploadLog' " +
         "((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' TASK ERROR: ' + `$_.Exception.Message) }; " +
         "Start-Sleep -Seconds 14 }"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

$uploadAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"

$uploadTrigger = New-ScheduledTaskTrigger -AtStartup
$uploadTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition

$uploadSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -MultipleInstances IgnoreNew

$uploadPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
    -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName 'SkyForge-Upload' -Confirm:$false -ErrorAction SilentlyContinue

Register-ScheduledTask -TaskName 'SkyForge-Upload' `
    -Description 'Publishes server status and Pretense campaign state to S3 for the web board' `
    -Action $uploadAction `
    -Trigger $uploadTrigger `
    -Settings $uploadSettings `
    -Principal $uploadPrincipal | Out-Null

Write-Ok 'SkyForge-Upload registered (4x per minute, ~15s board freshness)'

# VERIFY IT ACTUALLY RUNS. A task that reports Success is not evidence of work;
# only the log growing on its own is.
Start-Sleep -Seconds 2
$sizeBefore = if (Test-Path $uploadLog) { (Get-Item $uploadLog).Length } else { 0 }
Start-ScheduledTask -TaskName 'SkyForge-Upload'
Start-Sleep -Seconds 20
$sizeAfter = if (Test-Path $uploadLog) { (Get-Item $uploadLog).Length } else { 0 }
if ($sizeAfter -gt $sizeBefore) {
    Write-Ok "SkyForge-Upload verified writing ($sizeBefore -> $sizeAfter bytes)"
} else {
    Write-Warn "SkyForge-Upload did not write to $uploadLog within 20s - the board will be stale. Check the task action."
}

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------

Write-Step "Registering scheduled task 'SkyForge-Announce' (Discord boot notice)"

# An on-demand server has a recurring social failure: nobody knows it is up.
# Whoever ran /dcs start knows; everybody else finds out by asking. Scheduled
# game nights make it worse, because no human is involved at all.
#
# announce.ps1 waits for DCS to be genuinely joinable -- process up, hook
# writing, port 10308 listening -- rather than firing when the instance
# starts. Those are 3-5 minutes apart and announcing the wrong one teaches
# people to ignore the message.

foreach ($helper in 'announce.ps1', 'update-dcs.ps1') {
    $src = Join-Path $ScriptRoot $helper
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $StateDir $helper) -Force
        Write-Ok "installed $(Join-Path $StateDir $helper)"
    } else {
        Write-Warn "$helper not found at $src - skipping"
    }
}

$announceTarget = Join-Path $StateDir 'announce.ps1'

if (Test-Path $announceTarget) {
    # -File, not -Command: no nested quoting for Task Scheduler to mangle.
    $announceAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$announceTarget`""

    # Fires once per boot. The script self-limits with a boot-stamped marker,
    # so a manual re-run cannot double-post.
    $announceTrigger = New-ScheduledTaskTrigger -AtStartup

    $announceSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
        -MultipleInstances IgnoreNew

    $announcePrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName 'SkyForge-Announce' -Confirm:$false -ErrorAction SilentlyContinue

    Register-ScheduledTask -TaskName 'SkyForge-Announce' `
        -Description 'Posts to Discord once the DCS server is joinable' `
        -Action $announceAction `
        -Trigger $announceTrigger `
        -Settings $announceSettings `
        -Principal $announcePrincipal | Out-Null

    Write-Ok 'SkyForge-Announce registered (at startup, posts when joinable)'
} else {
    Write-Warn 'announce.ps1 missing - no Discord boot notice will be posted'
}

# ---------------------------------------------------------------------------

Write-Step 'Configuration check'

$settingsFile = Join-Path $SavedGames 'Config\serverSettings.lua'
if (Test-Path $settingsFile) {
    $content = Get-Content $settingsFile -Raw
    if ($content -match '\["password"\]\s*=\s*""') {
        Write-Warn 'serverSettings.lua has no password - your server will be joinable by strangers'
    }
    Write-Ok "serverSettings.lua present at $settingsFile"
} else {
    Write-Warn "serverSettings.lua not found. Start DCS once to generate it, or copy the template from this repo."
}

# ---------------------------------------------------------------------------

Write-Host @"

Setup complete.

VERIFY BEFORE YOU TRUST IT
  1. Start DCS now:        Start-ScheduledTask -TaskName 'DCS-Server'
  2. Load a mission, then confirm the hook is writing:
                           Get-Content C:\dcs-state\players.json
  3. Dry-run the watchdog: & C:\dcs-state\watchdog.ps1 -WhatIf -Verbose
  4. Watch its decisions:  Get-Content C:\dcs-state\watchdog.log -Tail 20 -Wait

  5. FIRST LOGIN (one time only). DCS will sit at a login dialog it cannot
     show you. Drive it once with dcs-login-uia.ps1, or RDP in over the SSM
     tunnel and log in by hand, ticking BOTH "Save password" and "Auto login".
     DCS then writes Config\autologin.cfg itself and never prompts again.
     Confirm with:  Select-String dcs.log -Pattern 'Login success|authorization'

  6. THE IMPORTANT TEST -- leave the server empty and confirm the instance
     reaches 'stopped' on its own within $FirstJoinGraceMinutes minutes. Do not skip this.

  7. Reboot and confirm DCS comes back up with nobody touching it. This is what
     makes remote start work: autologon creates the session, DCS-Server fires
     at logon, and the saved token logs in silently.

"@ -ForegroundColor Cyan
