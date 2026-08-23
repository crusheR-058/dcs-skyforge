<#
.SYNOPSIS
    Launch the DCS dedicated server, applying any queued mission first.

.DESCRIPTION
    This is the action behind the DCS-Server scheduled task. It exists because
    of one awkward fact: DCS rewrites serverSettings.lua from memory when it
    exits. Editing that file while the server is running -- which is exactly
    when a mission upload arrives -- means the edit is silently discarded on the
    very restart that was supposed to apply it.

    So add-mission.ps1 only drops a marker file naming the .miz, and this script
    consumes the marker in the window when DCS is definitely not running:
    after it has exited, before it starts again. That covers both paths
    uniformly -- /dcs restart and a cold boot.
#>

[CmdletBinding()]
param(
    [string]$DcsExe = 'C:\DCS_server\bin\DCS_server.exe',
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server'
)

$ErrorActionPreference = 'Continue'

$StateDir  = 'C:\dcs-state'
$QueueFile = Join-Path $StateDir 'queued-mission.txt'
$Settings  = Join-Path $SavedGames 'Config\serverSettings.lua'
$LogFile   = Join-Path $StateDir 'start-dcs.log'

function Write-Log { param([string]$m) Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
Write-Log '--- start-dcs ---'

# --- Apply a queued mission, if there is one -------------------------------

if (Test-Path $QueueFile) {
    try {
        $miz = (Get-Content $QueueFile -Raw).Trim()

        if ($miz -and (Test-Path $miz)) {
            $lua = Get-Content $Settings -Raw -Encoding UTF8

            # Keep a copy of the working config: if a queued mission ever wedges
            # the server, the previous settings are one file-copy away.
            Copy-Item $Settings "$Settings.bak" -Force

            # DCS accepts forward slashes and they need no Lua escaping, which
            # avoids a whole class of backslash-quoting bugs here.
            $path = $miz -replace '\\', '/'
            $replacement = '["missionList"] =' + "`n    {`n        [1] = `"$path`",`n    }"

            $updated = [regex]::Replace($lua, '\["missionList"\]\s*=\s*\{.*?\}', $replacement, 'Singleline')

            if ($updated -eq $lua) {
                Write-Log "WARN: missionList not found in serverSettings.lua - leaving config alone"
            } else {
                [IO.File]::WriteAllText($Settings, $updated)
                Write-Log "applied queued mission: $miz"
            }
        } else {
            Write-Log "queued file missing on disk: $miz"
        }
    } catch {
        Write-Log "failed to apply queued mission: $($_.Exception.Message)"
    } finally {
        # Consume the marker either way. A queued mission that cannot be applied
        # should not be retried on every boot forever.
        [IO.File]::Delete($QueueFile)
    }
} else {
    Write-Log 'no mission queued'
}

# --- Launch ----------------------------------------------------------------

Write-Log "launching $DcsExe"
Start-Process -FilePath $DcsExe `
    -ArgumentList '--server', '--norender', '-w', 'DCS.server' `
    -WorkingDirectory (Split-Path -Parent $DcsExe)
