<#
.SYNOPSIS
    Sample DCS server performance into a rolling CSV.

.DESCRIPTION
    Runs every minute as SYSTEM. Exists to answer one specific question with
    data rather than feel: is the server limited by ONE saturated core, or by
    all of them?

    That distinction decides whether upgrading from 4 cores to 8 (+$20/month)
    would help at all. DCS's simulation loop is single-threaded, so if one core
    pins at 100% while the others idle, more cores buy nothing -- and there is
    no faster per-core instance available in either Indian region.

    Columns: timestamp, per-core %, total %, DCS process %, RAM GB, sim FPS,
    players.
#>

[CmdletBinding()]
param(
    [string]$CsvPath = 'C:\dcs-state\perf.csv',
    [int]$MaxRows = 20160   # ~14 days at one sample/minute
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $CsvPath) | Out-Null

# Only sample while DCS is actually running -- rows from a bare Windows box
# would dilute the averages and tell us nothing.
$dcs = Get-Process DCS_server -ErrorAction SilentlyContinue
if (-not $dcs) { return }

$cores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors

# Per-core utilisation. The _Total instance is reported alongside the numbered
# cores, so it is separated out rather than treated as another core.
# MEASURED: '% Processor Time' is a RATE, so the first sample is always 0 --
# the counter needs two readings to compute a delta. Take two and use the
# second, or every row logs zeros and the whole exercise is worthless.
$samples = (Get-Counter '\Processor(*)\% Processor Time' -MaxSamples 2 -SampleInterval 1 -ErrorAction SilentlyContinue |
    Select-Object -Last 1).CounterSamples
$perCore = @{}
$total = 0
foreach ($s in $samples) {
    if ($s.InstanceName -eq '_total') { $total = [math]::Round($s.CookedValue, 1) }
    elseif ($s.InstanceName -match '^\d+$') { $perCore[[int]$s.InstanceName] = [math]::Round($s.CookedValue, 1) }
}

# DCS's own CPU share, normalised to one core: 100 means it is saturating a
# single core, which on a 4-core box is only 25% of "total CPU".
$dcsCpu = 0
try {
    $c = (Get-Counter "\Process(DCS_server)\% Processor Time" -MaxSamples 2 -SampleInterval 1 -ErrorAction SilentlyContinue |
        Select-Object -Last 1).CounterSamples[0].CookedValue
    $dcsCpu = [math]::Round($c, 1)
} catch { }

$os = Get-CimInstance Win32_OperatingSystem
$ramGb = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB), 2)

# FPS and player count come from the in-game hook; treat stale data as unknown.
$fps = ''
$players = ''
try {
    $j = Get-Content 'C:\dcs-state\players.json' -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    if (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$j.ts) -le 180) {
        $fps = $j.fps
        $players = $j.players
    }
} catch { }

$row = [ordered]@{
    ts      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    total   = $total
    dcs_cpu = $dcsCpu
    ram_gb  = $ramGb
    fps     = $fps
    players = $players
}
for ($i = 0; $i -lt $cores; $i++) { $row["core$i"] = if ($perCore.ContainsKey($i)) { $perCore[$i] } else { 0 } }

if (-not (Test-Path $CsvPath)) {
    ($row.Keys -join ',') | Set-Content -Path $CsvPath -Encoding utf8
}
($row.Values -join ',') | Add-Content -Path $CsvPath -Encoding utf8

# Trim from the front so the file stays bounded without losing the header.
$lines = @(Get-Content $CsvPath)
if ($lines.Count -gt ($MaxRows + 1)) {
    $keep = @($lines[0]) + $lines[($lines.Count - $MaxRows)..($lines.Count - 1)]
    Set-Content -Path $CsvPath -Value $keep -Encoding utf8
}
