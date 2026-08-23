<#
.SYNOPSIS
    Install a DCS aircraft mod onto the dedicated server from the S3 transfer
    bucket.

.DESCRIPTION
    Aircraft mods are far too large for Discord's attachment limit (10-25 MB)
    and have no business passing through a Lambda, so they travel via S3:

        laptop  --aws s3 sync-->  S3  --Read-S3Object-->  server

    The S3-to-server leg is same-region, so it is fast and costs nothing.

    NOTE: the AWS CLI is NOT installed on this AMI. Everything here goes through
    AWS Tools for PowerShell, which the Amazon Windows image does ship.

.PARAMETER ModName
    Folder name to create under Saved Games\DCS.server\Mods\aircraft\. This
    must match what the mod expects, because Entry.lua resolves everything
    relative to current_mod_path.

.EXAMPLE
    .\install-mod.ps1 -Prefix su30/ -ModName "Su-30_EFM_V2.8.06b BASE PACKAGE"
#>

[CmdletBinding()]
param(
    [string]$Bucket = 'dcs-skyforge-transfer-123456789012',
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$ModName,
    [string]$SavedGames = 'C:\Users\Administrator\Saved Games\DCS.server'
)

$ErrorActionPreference = 'Stop'

$LogFile = 'C:\dcs-state\install-mod.log'
function Write-Log { param([string]$m) Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m); Write-Output $m }

New-Item -ItemType Directory -Force -Path 'C:\dcs-state' | Out-Null
Write-Log "=== installing $ModName from s3://$Bucket/$Prefix ==="

# Prefer the CLI: `aws s3 sync` is parallel and resumable, which matters for a
# ~900-file aircraft mod. Read-S3Object is the fallback if the CLI is absent.
$awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
$useCli = Test-Path $awsExe

if (-not $useCli) {
    foreach ($m in 'AWS.Tools.S3', 'AWSPowerShell.NetCore', 'AWSPowerShell') {
        try { Import-Module $m -ErrorAction Stop; Write-Log "using module $m"; break } catch { }
    }
    if (-not (Get-Command Read-S3Object -ErrorAction SilentlyContinue)) {
        throw 'No AWS CLI and no AWS Tools for PowerShell - cannot reach S3.'
    }
}
Write-Log ("transfer method: {0}" -f $(if ($useCli) { 'aws s3 sync' } else { 'Read-S3Object' }))

# Region from IMDS rather than hardcoded, so this keeps working if the server
# is ever rebuilt in another region.
$token = Invoke-RestMethod -Method Put -TimeoutSec 5 `
    -Uri 'http://169.254.169.254/latest/api/token' `
    -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
$region = Invoke-RestMethod -TimeoutSec 5 `
    -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
    -Headers @{ 'X-aws-ec2-metadata-token' = $token }

$expected = Get-S3Object -BucketName $Bucket -KeyPrefix $Prefix -Region $region
$expectedBytes = ($expected | Measure-Object Size -Sum).Sum
Write-Log ("S3 holds {0:N0} objects, {1:N1} MB" -f $expected.Count, ($expectedBytes / 1MB))

if ($expected.Count -eq 0) { throw "nothing found under s3://$Bucket/$Prefix" }

$free = (Get-Volume -DriveLetter C).SizeRemaining
if ($free -lt ($expectedBytes * 1.2)) {
    throw ("need ~{0:N1} GB free, have {1:N1} GB - grow the volume first" -f ($expectedBytes * 1.2 / 1GB), ($free / 1GB))
}

$target = Join-Path $SavedGames "Mods\aircraft\$ModName"
New-Item -ItemType Directory -Force -Path $target | Out-Null

Write-Log "downloading to $target"
if ($useCli) {
    & $awsExe s3 sync "s3://$Bucket/$Prefix" $target --region $region --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed with exit code $LASTEXITCODE" }
} else {
    Read-S3Object -BucketName $Bucket -KeyPrefix $Prefix -Folder $target -Region $region | Out-Null
}

$got = Get-ChildItem $target -Recurse -File
$gotBytes = ($got | Measure-Object Length -Sum).Sum
Write-Log ("downloaded {0:N0} files, {1:N1} MB" -f $got.Count, ($gotBytes / 1MB))

if ($got.Count -lt $expected.Count) {
    Write-Log "WARN: file count mismatch - expected $($expected.Count), got $($got.Count)"
}

# Entry.lua is what DCS loads; without it at the mod root the mod is invisible.
$entry = Join-Path $target 'Entry.lua'
if (-not (Test-Path $entry)) {
    Write-Log "WARN: Entry.lua not at mod root. Contents:"
    Get-ChildItem $target | ForEach-Object { Write-Log "  $($_.Name)" }
    throw 'Entry.lua missing at the mod root - check the S3 prefix layout.'
}

Write-Log 'Entry.lua present at mod root'
Write-Log '=== install complete - restart DCS to load it ==='
