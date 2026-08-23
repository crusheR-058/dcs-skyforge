<#
.SYNOPSIS
    Validate and queue a mission uploaded through Discord.

.DESCRIPTION
    Invoked on the instance by the Discord bot via SSM. Downloads the .miz
    straight from Discord's CDN (the file never passes through the Lambda),
    validates it, and stages it to load on the next server start.

    It deliberately does NOT restart DCS. Queueing is harmless, so uploading can
    stay open to everyone while the disruptive step stays behind /dcs restart.

    Every outcome -- success or failure -- is published to the SSM parameter
    /dcs/queued-mission so that /dcs status can report it back in Discord. The
    uploader gets no synchronous answer otherwise, because SSM SendCommand is
    fire-and-forget and Discord hangs up after 3 seconds.

.NOTES
    The queue is a marker file, NOT an edit to serverSettings.lua. DCS rewrites
    serverSettings.lua from memory when it exits, so an edit made while the
    server is running would be silently discarded on the very restart meant to
    apply it. start-dcs.ps1 consumes the marker before launching DCS instead.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$FileName,
    [string]$UploadedBy = 'someone',
    [int]$MaxBytes = 52428800  # 50 MB
)

$ErrorActionPreference = 'Stop'

$StateDir    = 'C:\dcs-state'
$MissionDir  = 'C:\Users\Administrator\Saved Games\DCS.server\Missions\uploaded'
$QueueFile   = Join-Path $StateDir 'queued-mission.txt'
$LogFile     = Join-Path $StateDir 'add-mission.log'
$Sandbox     = 'C:\DCS_server\Scripts\MissionScripting.lua'
$TerrainRoot = 'C:\DCS_server\Mods\terrains'
$ParamName   = '/dcs/queued-mission'

function Write-Log { param([string]$m) Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

function Publish-Result {
    <# Report the outcome so /dcs status can surface it in Discord. #>
    param([bool]$Ok, [string]$Message, [string]$Mission = '', [string]$Theatre = '')

    $payload = @{
        ok      = $Ok
        message = $Message
        mission = $Mission
        theatre = $Theatre
        by      = $UploadedBy
        ts      = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress

    try {
        $token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
            -Uri 'http://169.254.169.254/latest/api/token' `
            -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
        $region = Invoke-RestMethod -TimeoutSec 5 `
            -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
            -Headers @{ 'X-aws-ec2-metadata-token' = $token }

        # MEASURED: the AWS CLI is NOT installed on this AMI, so aws.exe alone
        # silently publishes nothing and /dcs status can never report an upload.
        # The Amazon Windows image does ship AWS Tools for PowerShell, so fall
        # back to that -- the same chain the watchdog uses.
        $published = $false

        $awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
        if (Test-Path $awsExe) {
            & $awsExe ssm put-parameter --name $ParamName --value $payload `
                --type String --overwrite --region $region 2>&1 | Out-Null
            $published = ($LASTEXITCODE -eq 0)
        }

        if (-not $published) {
            foreach ($module in 'AWS.Tools.SimpleSystemsManagement', 'AWSPowerShell.NetCore', 'AWSPowerShell') {
                try { Import-Module $module -ErrorAction Stop; break } catch { }
            }

            if (Get-Command Write-SSMParameter -ErrorAction SilentlyContinue) {
                Write-SSMParameter -Name $ParamName -Value $payload -Type String `
                    -Overwrite $true -Region $region | Out-Null
                $published = $true
            }
        }

        if (-not $published) { Write-Log 'WARN: no working SSM client - result not published' }
    } catch {
        Write-Log "could not publish result: $($_.Exception.Message)"
    }

    Write-Log "result ok=$Ok $Message"
}

New-Item -ItemType Directory -Force -Path $StateDir, $MissionDir | Out-Null
Write-Log "upload from $UploadedBy : $FileName"

# --- Interlock: refuse if the Lua sandbox has been removed -----------------
# DCS sanitizes os/io/lfs and nils require/loadlib/package so mission Lua cannot
# touch the filesystem or network. MOOSE, DCT and Liberation all instruct users
# to remove that -- and the moment someone does, accepting uploads from Discord
# becomes remote code execution for anyone in the guild. Fail closed instead of
# quietly becoming a backdoor.
try {
    $sandboxText = Get-Content $Sandbox -Raw -ErrorAction Stop
} catch {
    Publish-Result -Ok $false -Message "Cannot read MissionScripting.lua - refusing uploads."
    exit 1
}

$sanitized = @('os', 'io', 'lfs') | ForEach-Object { $sandboxText -match "sanitizeModule\('$_'\)" }
$nilled = ($sandboxText -match "_G\['require'\]\s*=\s*nil")

if ($sanitized -contains $false -or -not $nilled) {
    Publish-Result -Ok $false -Message "REFUSED: the DCS Lua sandbox has been de-sanitized on this server. Uploaded missions could run arbitrary code. Re-sanitize MissionScripting.lua or disable mission uploads."
    exit 1
}

# --- Download --------------------------------------------------------------

if ($FileName -notmatch '\.miz$') {
    Publish-Result -Ok $false -Message "'$FileName' is not a .miz file."
    exit 1
}

# Strip anything path-like out of the Discord-supplied filename.
$safeName = [IO.Path]::GetFileName($FileName) -replace '[^A-Za-z0-9._-]', '_'
$staged = Join-Path $env:TEMP ("upload_{0}.miz" -f [guid]::NewGuid().ToString('N'))

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $staged -UseBasicParsing -TimeoutSec 120
} catch {
    Publish-Result -Ok $false -Message "Download failed: $($_.Exception.Message)"
    exit 1
}

$size = (Get-Item $staged).Length
if ($size -gt $MaxBytes) {
    [IO.File]::Delete($staged)
    Publish-Result -Ok $false -Message ("File is {0:N1} MB, limit is {1:N0} MB." -f ($size / 1MB), ($MaxBytes / 1MB))
    exit 1
}
Write-Log ("downloaded {0:N1} MB" -f ($size / 1MB))

# --- Validate: is it really a .miz, and which terrain does it need? --------

Add-Type -AssemblyName System.IO.Compression.FileSystem

$theatre = $null
try {
    $zip = [IO.Compression.ZipFile]::OpenRead($staged)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'mission' } | Select-Object -First 1
        if (-not $entry) { throw "no 'mission' entry - not a valid .miz" }

        $reader = New-Object IO.StreamReader($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Close() }

        # MEASURED: DCS emits BOTH quoting styles depending on the version that
        # saved the mission -- ["theatre"] = "Caucasus" and ['theatre']="Caucasus".
        # Matching only the double-quoted form rejected a perfectly valid
        # Pretense mission with "could not find a theatre".
        if ($text -match '\[[''"]theatre[''"]\]\s*=\s*[''"]([^''"]+)[''"]') { $theatre = $Matches[1] }
        else { throw "could not find a theatre in the mission" }
    } finally {
        $zip.Dispose()
    }
} catch {
    [IO.File]::Delete($staged)
    Publish-Result -Ok $false -Message "Not a readable mission file: $($_.Exception.Message)"
    exit 1
}

$installed = Get-ChildItem $TerrainRoot -Directory -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name

if ($installed -notcontains $theatre) {
    [IO.File]::Delete($staged)
    Publish-Result -Ok $false -Theatre $theatre -Message (
        "This mission needs the '$theatre' terrain, which is not installed. Server has: " + ($installed -join ', ') + ".")
    exit 1
}

# --- Stage it --------------------------------------------------------------
# Never overwrite: keep every upload so a bad one can be backed out by hand.

$target = Join-Path $MissionDir $safeName
if (Test-Path $target) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $MissionDir ("{0}-{1}" -f $stamp, $safeName)
}

Move-Item -Path $staged -Destination $target -Force
[IO.File]::WriteAllText($QueueFile, $target)

Write-Log "queued $target (theatre=$theatre)"
Publish-Result -Ok $true -Mission ([IO.Path]::GetFileName($target)) -Theatre $theatre `
    -Message "Queued. Loads on the next /dcs restart."
