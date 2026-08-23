<#
.SYNOPSIS
    Render a DCS server performance chart and post it to a Discord webhook.

.DESCRIPTION
    Reads the CSV written by perf-collector.ps1, renders a PNG with .NET's
    charting assembly (present on Windows Server, so no external dependency),
    and posts it to Discord with a short verdict.

    The verdict is the whole point. It answers "would 8 cores help?" by
    comparing the busiest core against the average of the others:

      one core pinned, others idle -> single-thread bound; MORE CORES WON'T HELP
      all cores busy               -> genuinely parallel; more cores would help

    DCS's sim loop is single-threaded, so the first case is the common one --
    and there is no faster per-core instance in either Indian region, which
    makes this the difference between spending $20/month and saving it.

.PARAMETER Hours
    How far back to plot. Default 6.
#>

[CmdletBinding()]
param(
    [int]$Hours = 6,
    [string]$CsvPath = 'C:\dcs-state\perf.csv',
    [string]$WebhookParam = '/dcs/discord-webhook'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms.DataVisualization

$png = Join-Path $env:TEMP ("dcs-perf-{0}.png" -f [guid]::NewGuid().ToString('N'))

function Get-Webhook {
    # Kept in SSM Parameter Store, never in this file -- a webhook URL is a
    # credential: anyone holding it can post into your channel.
    $aws = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
    $token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
        -Uri 'http://169.254.169.254/latest/api/token' `
        -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
    $region = Invoke-RestMethod -TimeoutSec 5 `
        -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
        -Headers @{ 'X-aws-ec2-metadata-token' = $token }
    $v = & $aws ssm get-parameter --name $WebhookParam --with-decryption --region $region --query Parameter.Value --output text
    return $v.Trim()
}

if (-not (Test-Path $CsvPath)) { throw "No performance data yet at $CsvPath" }

$cutoff = (Get-Date).AddHours(-$Hours)
$rows = @(Import-Csv $CsvPath | Where-Object { [datetime]$_.ts -ge $cutoff })
if ($rows.Count -lt 2) {
    throw "Only $($rows.Count) samples in the last $Hours h. The collector runs only while DCS is up."
}

$coreCols = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -match '^core\d+$' } | Sort-Object)

# --- Chart -----------------------------------------------------------------

$chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart.Width = 1000
$chart.Height = 750
$chart.BackColor = [System.Drawing.Color]::FromArgb(43, 45, 49)

$fg = [System.Drawing.Color]::FromArgb(220, 221, 222)
$grid = [System.Drawing.Color]::FromArgb(65, 68, 73)

function New-Area {
    param([string]$Name, [int]$Top, [int]$Height, [string]$Title, [double]$Max)

    $a = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea $Name
    $a.BackColor = [System.Drawing.Color]::FromArgb(43, 45, 49)
    $a.Position.X = 6
    $a.Position.Y = $Top
    $a.Position.Width = 92
    $a.Position.Height = $Height
    $a.AxisX.LabelStyle.Format = 'HH:mm'

    foreach ($ax in @($a.AxisX, $a.AxisY)) {
        $ax.LineColor = $grid
        $ax.MajorGrid.LineColor = $grid
        $ax.LabelStyle.ForeColor = $fg
        $ax.TitleForeColor = $fg
    }

    $a.AxisY.Title = $Title
    if ($Max -gt 0) { $a.AxisY.Maximum = $Max; $a.AxisY.Minimum = 0 }
    return $a
}

$chart.ChartAreas.Add((New-Area 'cpu' 6 40 'CPU %' 105)) | Out-Null
$chart.ChartAreas.Add((New-Area 'fps' 50 22 'sim FPS' 0)) | Out-Null
$chart.ChartAreas.Add((New-Area 'plr' 76 20 'players' 0)) | Out-Null

$legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
$legend.BackColor = [System.Drawing.Color]::Transparent
$legend.ForeColor = $fg
$legend.Docking = 'Top'
$chart.Legends.Add($legend) | Out-Null

$palette = @(
    [System.Drawing.Color]::FromArgb(88, 166, 255),
    [System.Drawing.Color]::FromArgb(63, 185, 80),
    [System.Drawing.Color]::FromArgb(255, 166, 87),
    [System.Drawing.Color]::FromArgb(219, 109, 255),
    [System.Drawing.Color]::FromArgb(255, 123, 114),
    [System.Drawing.Color]::FromArgb(121, 192, 255),
    [System.Drawing.Color]::FromArgb(210, 168, 255),
    [System.Drawing.Color]::FromArgb(255, 212, 102)
)

function Add-Series {
    param([string]$Name, [string]$Area, [string]$Col, $Color, [int]$Width = 2)

    $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series $Name
    $s.ChartType = 'Line'
    $s.ChartArea = $Area
    $s.BorderWidth = $Width
    $s.Color = $Color
    $s.XValueType = 'DateTime'

    foreach ($r in $rows) {
        $v = $r.$Col
        if ($v -ne '' -and $null -ne $v) { [void]$s.Points.AddXY([datetime]$r.ts, [double]$v) }
    }

    if ($s.Points.Count -gt 0) { $chart.Series.Add($s) | Out-Null }
}

for ($i = 0; $i -lt $coreCols.Count; $i++) {
    Add-Series -Name $coreCols[$i] -Area 'cpu' -Col $coreCols[$i] -Color $palette[$i % $palette.Count]
}

# Normalised so 100 means "saturating one core" -- on a 4-core box that is only
# 25% of total CPU, which is exactly why total CPU hides a DCS bottleneck.
Add-Series -Name 'DCS (1 core = 100)' -Area 'cpu' -Col 'dcs_cpu' -Color ([System.Drawing.Color]::White) -Width 3
Add-Series -Name 'sim FPS' -Area 'fps' -Col 'fps' -Color ([System.Drawing.Color]::FromArgb(63, 185, 80)) -Width 3
Add-Series -Name 'players' -Area 'plr' -Col 'players' -Color ([System.Drawing.Color]::FromArgb(255, 166, 87)) -Width 3

$chart.SaveImage($png, 'Png')

# --- Verdict ---------------------------------------------------------------

$coreAvgs = @{}
foreach ($c in $coreCols) {
    $vals = @($rows | ForEach-Object { [double]$_.$c })
    $coreAvgs[$c] = ($vals | Measure-Object -Average).Average
}

$busiest = $coreAvgs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
$others = @($coreAvgs.GetEnumerator() | Where-Object { $_.Key -ne $busiest.Key } | ForEach-Object { $_.Value })
$otherAvg = if ($others.Count) { ($others | Measure-Object -Average).Average } else { 0 }

$fpsVals = @($rows | Where-Object { $_.fps -ne '' } | ForEach-Object { [double]$_.fps })
$fpsMin = if ($fpsVals.Count) { [math]::Round(($fpsVals | Measure-Object -Minimum).Minimum, 1) } else { 0 }
$fpsAvg = if ($fpsVals.Count) { [math]::Round(($fpsVals | Measure-Object -Average).Average, 1) } else { 0 }

$plrVals = @($rows | Where-Object { $_.players -ne '' } | ForEach-Object { [int]$_.players })
$plrMax = if ($plrVals.Count) { ($plrVals | Measure-Object -Maximum).Maximum } else { 0 }

$bz = [math]::Round($busiest.Value, 1)
$oz = [math]::Round($otherAvg, 1)
$skew = if ($otherAvg -gt 1) { $busiest.Value / $otherAvg } else { 99 }

if ($skew -ge 2 -and $busiest.Value -gt 55) {
    $verdict = "**Single-thread bound.** $($busiest.Key) averages $bz% while the others average $oz%. More cores would NOT help, and no faster per-core instance exists in either Indian region. Reduce AI or script load instead."
} elseif ($busiest.Value -lt 40) {
    $verdict = "**Plenty of headroom.** Busiest core only $bz%. No upgrade needed."
} else {
    $verdict = "**Broadly parallel load** (busiest $bz%, others $oz%). This is the case where 8 cores would genuinely help."
}

$nl = [char]10
$msg = "**DCS SkyForge - last $Hours h**" + $nl +
       "sim FPS avg **$fpsAvg**, min **$fpsMin**  |  peak players **$plrMax**  |  samples $($rows.Count)" + $nl +
       $verdict

# --- Post to Discord -------------------------------------------------------

Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$form = New-Object System.Net.Http.MultipartFormDataContent
$form.Add((New-Object System.Net.Http.StringContent($msg)), 'content')

$bytes = [IO.File]::ReadAllBytes($png)
$fileContent = New-Object System.Net.Http.ByteArrayContent($bytes, 0, $bytes.Length)
$fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('image/png')
$form.Add($fileContent, 'file', 'dcs-perf.png')

$resp = $client.PostAsync((Get-Webhook), $form).Result
Write-Output "discord: $([int]$resp.StatusCode) $($resp.StatusCode)"

[IO.File]::Delete($png)
