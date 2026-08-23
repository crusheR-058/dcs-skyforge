<#
.SYNOPSIS
    Turn DCS-gRPC into the live.json the web board already reads.

.DESCRIPTION
    The board has always been able to render a live map -- renderMap() consumes
    live.world.units / .bases and has since the first version. What never
    existed was anything producing that file, because the export hook that was
    supposed to crashed DCS twice.

    This is the replacement, and the important difference is where the work
    happens. The old hook walked the unit tree on the SIMULATION THREAD via
    net.dostring_in. This process talks to DCS-gRPC over loopback; DCS-gRPC
    does its serialisation in a Rust DLL off-thread and rate-limits the Lua it
    executes. Nothing here can block a frame.

    Three calls per cycle, which is why it is cheap:

        GetPlayerUnits(BLUE)   player aircraft, with lat/lon and pilot name
        GetPlayerUnits(RED)
        GetAirbases            cached; airfields do not move

    AI units are deliberately not fetched. On a Pretense map that is hundreds
    of objects nobody looks at, and the interesting question on a friends'
    server is always "where is everyone".

.NOTES
    grpcurl.exe and the .proto files ship inside the DCS-gRPC release, so this
    needs no Python, no grpcio and no generated stubs.
#>

[CmdletBinding()]
param(
    [string]$StateDir  = 'C:\dcs-state',
    [string]$GrpcHost  = '127.0.0.1',
    [int]$GrpcPort     = 50051,
    [int]$BasesEvery   = 20,
    [int]$TimeoutSec   = 5
)

$ErrorActionPreference = 'Continue'

$Tools    = Join-Path $StateDir 'grpc-tools'
$Grpcurl  = Join-Path $Tools 'grpcurl.exe'
$Protos   = Join-Path $Tools 'protos'
$LiveFile = Join-Path $StateDir 'live.json'
$CacheDir = Join-Path $StateDir 'grpc-cache'
$LogFile  = Join-Path $StateDir 'grpc-bridge.log'

function Write-Log {
    param([string]$m)
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
        Move-Item -Force $LogFile "$LogFile.old"
    }
    Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

if (-not (Test-Path $Grpcurl)) { Write-Log "grpcurl missing at $Grpcurl"; exit 1 }
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# ---------------------------------------------------------------------------

function Invoke-Grpc {
    <#
        One grpcurl call, returned as an object. Any failure returns $null --
        DCS being down, mid-restart or simply not listening yet is the normal
        case, not an error worth shouting about.
    #>
    param([string]$Method, [string]$Body = '{}', [string]$ProtoRel)

    # PowerShell 5.1 strips double quotes when handing an argument to a native
    # exe, so a body like {"position":{"lat":42}} arrives as {position:{lat:42}}
    # and grpcurl rejects it as malformed JSON. Escaping them survives the
    # round trip. '{}' has no quotes, which is why simple calls worked and
    # every parameterised one silently returned null.
    $wire = $Body -replace '"', '\"'

    $callArgs = @(
        '-plaintext',
        '-max-time', $TimeoutSec,
        '-import-path', $Protos,
        '-proto', $ProtoRel,
        '-d', $wire,
        "${GrpcHost}:${GrpcPort}",
        $Method
    )

    try {
        $raw = & $Grpcurl @callArgs 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($raw | Out-String | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Airbases: cached, because they never move and GetAirbases is the heaviest
# call here. The cache also survives a bridge restart.
# ---------------------------------------------------------------------------

$basesCache = Join-Path $CacheDir 'airbases.json'
$passFile   = Join-Path $CacheDir 'pass.txt'

$pass = 0
if (Test-Path $passFile) { $pass = [int](Get-Content $passFile -Raw) }
$pass++
Set-Content $passFile $pass -Encoding ascii

$bases = $null
$needBases = ($pass % $BasesEvery -eq 1) -or (-not (Test-Path $basesCache))

if ($needBases) {
    $ab = Invoke-Grpc -Method 'dcs.world.v0.WorldService/GetAirbases' `
                      -ProtoRel 'dcs/world/v0/world.proto'
    if ($ab -and $ab.airbases) {
        $bases = @($ab.airbases | Where-Object { $_.position } | ForEach-Object {
            [ordered]@{
                n   = [string]$_.name
                c   = switch ([string]$_.coalition) { 'COALITION_BLUE' { 2 } 'COALITION_RED' { 1 } default { 0 } }
                lat = [math]::Round([double]$_.position.lat, 5)
                lon = [math]::Round([double]$_.position.lon, 5)
                u   = [math]::Round([double]$_.position.u, 1)
                v   = [math]::Round([double]$_.position.v, 1)
            }
        })
        [IO.File]::WriteAllText($basesCache, ($bases | ConvertTo-Json -Compress -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Write-Log "refreshed $($bases.Count) airbases"
    }
}

if (-not $bases -and (Test-Path $basesCache)) {
    # NOT `Get-Content | ConvertFrom-Json`. On PowerShell 5.1 piping into
    # ConvertFrom-Json hands back the whole JSON array as ONE object, so @()
    # wraps it again and you get an array-of-array. The symptom is subtle and
    # nasty: live.json still looks well-formed, but every airbase collapses
    # into a single entry whose "n" is a list of 29 names. Called positionally
    # it enumerates correctly -- measured 1 vs 29 on this exact file.
    try   { $bases = @(ConvertFrom-Json (Get-Content $basesCache -Raw -Encoding UTF8)) }
    catch { $bases = @() }
}

# Cheap shape assertion: a base must have a scalar name. If the nesting bug
# ever comes back by another route, fail loudly here rather than publishing a
# malformed live.json the board renders as one giant airbase.
if ($bases.Count -gt 0 -and $bases[0].n -isnot [string]) {
    Write-Log "BAD SHAPE from cache (n is $($bases[0].n.GetType().Name)) - discarding and refetching next pass"
    Remove-Item $basesCache -Force -ErrorAction SilentlyContinue
    $bases = @()
}
if (-not $bases) { $bases = @() }

# The board no longer needs reference points: it carries the terrain's exact
# transverse Mercator constants in zones.json and converts metres itself. The
# three-point affine fit that used to live here spanned 500+ km of map and was
# wrong by ~95 km, which looked like a projection failure and was really just
# the wrong tool -- an affine approximation of a curved projection.
#
# What replaces it is a straight data-vs-data check, no maths: gRPC reports
# BOTH lat/lon and u/v for every airbase, so if the board's own conversion of
# (v, u) ever drifts from what DCS says, that offline test catches it exactly.
# Verified 2026-08-23 at 0.00 km against Anapa-Vityazevo.
#
# Axis order, settled empirically rather than from the proto comments:
#   v = north-south (DCS x, the NORTHING)
#   u = west-east   (DCS z, the EASTING)
# Reversing them mirrors the map into the Black Sea.
$refs = @()

# ---------------------------------------------------------------------------
# Player aircraft
# ---------------------------------------------------------------------------

$units = @()
foreach ($side in @(@{ n = 'COALITION_BLUE'; c = 2 }, @{ n = 'COALITION_RED'; c = 1 })) {
    $r = Invoke-Grpc -Method 'dcs.coalition.v0.CoalitionService/GetPlayerUnits' `
                     -Body ('{{"coalition":"{0}"}}' -f $side.n) `
                     -ProtoRel 'dcs/coalition/v0/coalition.proto'
    if ($r -and $r.units) {
        foreach ($u in $r.units) {
            if (-not $u.position) { continue }
            $units += [ordered]@{
                t   = [string]$u.type
                c   = $side.c
                lat = [math]::Round([double]$u.position.lat, 5)
                lon = [math]::Round([double]$u.position.lon, 5)
                alt = [int][double]$u.position.alt
                # GroupCategory: AIRPLANE=0, HELICOPTER=1 in the board's scheme.
                cat = if ([string]$u.group.category -eq 'GROUP_CATEGORY_HELICOPTER') { 1 } else { 0 }
                p   = [string]$u.player_name
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

$mission = 'unknown'
try {
    $pj = Get-Content (Join-Path $StateDir 'players.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $mission = [string]$pj.mission
    $names = @($pj.names)
} catch { $names = @() }

$players = @($names | ForEach-Object {
    [ordered]@{ name = [string]$_.n; side = [int]$_.s }
})

# ---------------------------------------------------------------------------
# Environment: mission clock, weather, SRS
# ---------------------------------------------------------------------------

$envBlock = $null
$abs  = Invoke-Grpc -Method 'dcs.timer.v0.TimerService/GetAbsoluteTime' -Body '{}' -ProtoRel 'dcs/timer/v0/timer.proto'
$tp   = Invoke-Grpc -Method 'dcs.atmosphere.v0.AtmosphereService/GetTemperatureAndPressure' `
                    -Body '{"position":{"lat":42.0,"lon":42.0,"alt":100}}' -ProtoRel 'dcs/atmosphere/v0/atmosphere.proto'
$wind = Invoke-Grpc -Method 'dcs.atmosphere.v0.AtmosphereService/GetWind' `
                    -Body '{"position":{"lat":42.0,"lon":42.0,"alt":2000}}' -ProtoRel 'dcs/atmosphere/v0/atmosphere.proto'
$srs  = Invoke-Grpc -Method 'dcs.srs.v0.SrsService/GetClients' -Body '{}' -ProtoRel 'dcs/srs/v0/srs.proto'

if ($abs -or $tp) {
    $secs = 0
    if ($abs -and $abs.time) { $secs = [int]$abs.time }
    $envBlock = [ordered]@{
        # Mission time of day, not wall clock. DCS reports seconds since
        # midnight of the mission date.
        hh   = [int][math]::Floor($secs / 3600) % 24
        mm   = [int][math]::Floor(($secs % 3600) / 60)
        day  = $(if ($abs) { [int]$abs.day }   else { 0 })
        mon  = $(if ($abs) { [int]$abs.month } else { 0 })
        yr   = $(if ($abs) { [int]$abs.year }  else { 0 })
        # Kelvin -> Celsius, Pascals -> hectopascals (QNH as pilots read it).
        tempC = $(if ($tp -and $tp.temperature) { [math]::Round([double]$tp.temperature - 273.15, 1) } else { $null })
        qnh   = $(if ($tp -and $tp.pressure)    { [math]::Round([double]$tp.pressure / 100.0, 0) }     else { $null })
        windDir = $(if ($wind -and $wind.heading) { [int]$wind.heading } else { 0 })
        windMs  = $(if ($wind -and $wind.speed)   { [math]::Round([double]$wind.speed, 1) } else { 0 })
        srs     = @($(if ($srs -and $srs.clients) { $srs.clients | ForEach-Object {
                       [ordered]@{ n = $_.name; f = $_.frequency } } } else { @() }))
    }
}

$live = [ordered]@{
    mission = $mission
    players = $players
    # --- environment ------------------------------------------------------
    #
    # Weather and the mission clock come only from gRPC -- nothing else on this
    # box knows them. Note proto3 omits zero-valued fields, so an absent wind
    # speed means calm, not "no data"; treat missing as 0 rather than null or
    # the board will show a blank where it should show "calm".
    env     = $envBlock
    world   = [ordered]@{
        units = $units
        bases = @($bases | ForEach-Object { [ordered]@{ n = $_.n; c = $_.c; lat = $_.lat; lon = $_.lon } })
        refs  = $refs
    }
    ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# Only write when we actually reached DCS. A stale live.json is worse than
# none: skyforge-upload.ps1 treats anything under 120s old as current, and the
# board would show aircraft frozen in mid-air.
if ($bases.Count -gt 0 -or $units.Count -gt 0) {
    [IO.File]::WriteAllText($LiveFile, ($live | ConvertTo-Json -Compress -Depth 6), (New-Object Text.UTF8Encoding($false)))
    if ($pass % $BasesEvery -eq 1) {
        Write-Log "wrote live.json: $($units.Count) player unit(s), $($bases.Count) airbase(s)"
    }
} else {
    Write-Log 'no data from gRPC this pass (DCS down, restarting, or gRPC not listening)'
}
