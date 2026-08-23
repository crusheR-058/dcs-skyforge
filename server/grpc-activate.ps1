<#
.SYNOPSIS
    Activate (or roll back) DCS-gRPC on the dedicated server.

.DESCRIPTION
    DCS-gRPC is staged to C:\dcs-state\grpc-staging by design -- OUTSIDE every
    path DCS searches. That is deliberate: dropping a 17 MB native DLL into
    Saved Games would mean the next unattended boot (the Wednesday game-night
    schedule) loads it with nobody watching, and a Hooks script is what crashed
    this server twice already.

    This script is the supervised step that moves it into place. It does NOT
    restart DCS -- the caller decides when, because the change only takes
    effect on the next start and the field should be empty for the first one.

    -Deactivate reverses everything, which is the rollback path if the 0.8.1
    binary turns out to be incompatible with the installed DCS build.

.NOTES
    Why this is expected to be safe where the old export hook was not: the
    export hook ran everything on the simulation thread via net.dostring_in.
    DCS-gRPC does its networking and serialisation in a Rust DLL off-thread,
    and rate-limits the Lua side (throughputLimit).

    Still unproven here: release 0.8.1 is from Nov 2024 and this server runs a
    much newer DCS. Watch the first restart.
#>

[CmdletBinding()]
param(
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server',
    [string]$DcsPath    = 'C:\DCS_server',
    [string]$StateDir   = 'C:\dcs-state',
    [switch]$Deactivate,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$Stage    = Join-Path $StateDir 'grpc-staging\unpacked'
$LogFile  = Join-Path $StateDir 'grpc-activate.log'
$MsPath   = Join-Path $DcsPath 'Scripts\MissionScripting.lua'
$MsBackup = Join-Path $StateDir 'MissionScripting.lua.pre-grpc'
$GrpcLine = 'dofile(lfs.writedir()..[[Scripts\DCS-gRPC\grpc-mission.lua]])'
$Anchor   = "dofile('Scripts/ScriptingSystem.lua')"

function Write-Log {
    param([string]$m)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content $LogFile $line
    Write-Output $line
}

# --- never do this to people who are flying --------------------------------

$players = 0
try {
    $pj = Get-Content (Join-Path $StateDir 'players.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$pj.ts) -le 180) {
        $players = [int]$pj.players
    }
} catch { }

if ($players -gt 0 -and -not $Force) {
    Write-Log "ABORT: $players pilot(s) connected. This needs a restart to take effect; do it on an empty server."
    exit 1
}

# ---------------------------------------------------------------------------
# Deactivate
# ---------------------------------------------------------------------------

if ($Deactivate) {
    Write-Log '=== DEACTIVATING DCS-gRPC ==='

    foreach ($p in @(
        (Join-Path $SavedGames 'Scripts\Hooks\DCS-gRPC.lua'),
        (Join-Path $SavedGames 'Scripts\DCS-gRPC'),
        (Join-Path $SavedGames 'Mods\tech\DCS-gRPC'),
        (Join-Path $SavedGames 'Config\dcs-grpc.lua')
    )) {
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "  removed $p"
        }
    }

    if (Test-Path $MsBackup) {
        Copy-Item $MsBackup $MsPath -Force
        Write-Log "  restored MissionScripting.lua from $MsBackup"
    } else {
        # No backup: strip the line we added rather than leave a dangling dofile.
        $t = Get-Content $MsPath -Raw -Encoding UTF8
        if ($t -like "*grpc-mission.lua*") {
            # WriteAllText ASCII, never Set-Content -Encoding UTF8: that emits
            # a BOM on PS 5.1, and a BOM at the top of MissionScripting.lua
            # would break DCS's own scripting bootstrap -- the exact failure
            # dcs-grpc.lua had. A broken ROLLBACK path is the worst place
            # for that landmine.
            $stripped = ($t -split "`r?`n" | Where-Object { $_ -notlike '*grpc-mission.lua*' }) -join "`r`n"
            [IO.File]::WriteAllText($MsPath, $stripped, [Text.Encoding]::ASCII)
            Write-Log '  stripped the grpc dofile line from MissionScripting.lua'
        }
    }

    Write-Log '=== deactivated. Restart DCS to complete rollback. ==='
    exit 0
}

# ---------------------------------------------------------------------------
# Activate
# ---------------------------------------------------------------------------

Write-Log '=== ACTIVATING DCS-gRPC ==='

if (-not (Test-Path $Stage)) {
    Write-Log "FATAL: nothing staged at $Stage"
    exit 1
}

# 1. files into DCS's paths
$pairs = @(
    @{ From = 'Scripts\DCS-gRPC';            To = 'Scripts\DCS-gRPC' },
    @{ From = 'Mods\tech\DCS-gRPC';          To = 'Mods\tech\DCS-gRPC' },
    @{ From = 'Scripts\Hooks\DCS-gRPC.lua';  To = 'Scripts\Hooks\DCS-gRPC.lua' }
)

foreach ($p in $pairs) {
    $src = Join-Path $Stage $p.From
    $dst = Join-Path $SavedGames $p.To
    if (-not (Test-Path $src)) { Write-Log "  MISSING in staging: $($p.From)"; exit 1 }

    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item $src $dst -Recurse -Force
    Write-Log "  installed $($p.To)"
}

# 2. MissionScripting.lua -- the one file that can break Pretense
if (-not (Test-Path $MsBackup)) {
    Copy-Item $MsPath $MsBackup -Force
    Write-Log "  backed up MissionScripting.lua -> $MsBackup"
}

$ms = Get-Content $MsPath -Raw
if ($ms -like '*grpc-mission.lua*') {
    Write-Log '  MissionScripting.lua already patched'
} elseif ($ms -notlike "*$Anchor*") {
    Write-Log "  FATAL: anchor not found in MissionScripting.lua -- refusing to guess where to insert"
    exit 1
} else {
    $patched = $ms -replace [regex]::Escape($Anchor), ($Anchor + "`r`n" + $GrpcLine)

    # The sanitize block is deliberately modified on this server: io and lfs
    # are commented out so Pretense can persist campaign state. Losing that
    # silently would wipe progress, so assert it survived the edit.
    $ioOk  = $patched -match '--\s*sanitizeModule\(''io''\)'
    $lfsOk = $patched -match '--\s*sanitizeModule\(''lfs''\)'
    if (-not ($ioOk -and $lfsOk)) {
        Write-Log "  FATAL: Pretense de-sanitisation missing after patch (io=$ioOk lfs=$lfsOk) -- aborting"
        exit 1
    }

    [IO.File]::WriteAllText($MsPath, $patched)
    Write-Log '  patched MissionScripting.lua (grpc dofile added before sanitisation)'
}

# 3. config
$cfgDir = Join-Path $SavedGames 'Config'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }

$cfgBody = @'
-- DCS-gRPC configuration, written by grpc-activate.ps1.
--
-- host is deliberately loopback: the only client is the bridge running on this
-- same box, so there is nothing to expose and no security-group change needed.
-- Binding 0.0.0.0 here would put an unauthenticated RPC server that can spawn
-- units and run Lua onto the public internet.
autostart = true
host = "127.0.0.1"
port = 50051

-- Eval executes arbitrary Lua inside the mission environment. Nothing here
-- needs it, and this server's Lua sandbox is already de-sanitised for Pretense.
evalEnabled = false

debug = false
throughputLimit = 600
'@

# ASCII, NOT Set-Content -Encoding UTF8. On PowerShell 5.1 that emits a BOM,
# and DCS-gRPC's hook loadstring()s this file and dies on it with
# "unexpected symbol near". Cost a restart to find on 2026-08-23.
#
# Also note DCS holds this file OPEN while running, so it can only be written
# with the server stopped -- a write attempt against a live server fails with
# "being used by another process", silently if you do not check.
[IO.File]::WriteAllText((Join-Path $cfgDir 'dcs-grpc.lua'), $cfgBody, [Text.Encoding]::ASCII)
Write-Log '  wrote Config\dcs-grpc.lua (autostart, loopback only, eval off)'

# 4. report
Write-Log '=== installed. Verify after the next DCS start: ==='
Write-Log '  Get-NetTCPConnection -LocalPort 50051 -State Listen'
Write-Log '  Select-String dcs.log -Pattern "GRPC"'
Write-Log '  rollback: grpc-activate.ps1 -Deactivate, then restart'
