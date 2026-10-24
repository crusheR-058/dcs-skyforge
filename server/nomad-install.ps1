<#
.SYNOPSIS
    Install (or update, or remove) Nomad, the voice AI on SRS 251.0 AM, from
    the S3 transfer bucket.

.DESCRIPTION
    Nomad lives in its own project (dcs-bob). It reaches this server like an
    aircraft mod does:

        laptop  --aws s3 sync-->  s3://<transfer>/nomad/  --this script-->  C:\Nomad

    and then runs as the 'Nomad' scheduled task, as SYSTEM, from boot. It needs
    no interactive session: it talks to DCS through DCS-gRPC on loopback, and
    DCS-gRPC does the text-to-speech inside DCS. Pilots' speech is transcribed
    by Amazon Transcribe, so Nomad takes almost no CPU from DCS.

    Prerequisites, each done once:
      * infra/nomad.tf applied (Bedrock + Transcribe for the instance role);
      * grpc-activate.ps1 -Eval run with DCS STOPPED, then DCS restarted:
        every Nomad tool is a fixed Lua snippet run through DCS-gRPC's Eval.

    Rollback: nomad-install.ps1 -Remove, then grpc-activate.ps1 (no -Eval)
    with DCS stopped to switch Eval back off.

.NOTES
    uv's Python and cache are pinned under C:\Nomad. Run via SSM, this script
    is SYSTEM, and uv would otherwise put Python in SYSTEM's profile.

    The bundle carries its own uv.exe, so nothing is fetched from a script URL;
    uv downloads Python 3.12 and the wheels pinned in uv.lock.
#>

[CmdletBinding()]
param(
    [string]$Bucket   = 'dcs-skyforge-transfer-123456789012',
    [string]$Prefix   = 'nomad/',
    [string]$Target   = 'C:\Nomad',
    [string]$StateDir = 'C:\dcs-state',
    [string]$DcsPath  = 'C:\DCS_server',
    [switch]$NoStart,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $StateDir 'nomad-install.log'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
function Write-Log { param([string]$m) Add-Content $LogFile ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m); Write-Output $m }

if ($Remove) {
    Write-Log '=== removing the Nomad task ==='
    Stop-ScheduledTask -TaskName 'Nomad' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'Nomad' -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
        Where-Object { $_.CommandLine -like '*nomad.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Log "  stopped python pid $($_.ProcessId)" }
    Write-Log "  task removed; files left in $Target. Switch Eval off with grpc-activate.ps1 (DCS stopped)."
    exit 0
}

Write-Log "=== installing Nomad from s3://$Bucket/$Prefix ==="

# --- 1. files ---------------------------------------------------------------

foreach ($m in 'AWS.Tools.S3', 'AWSPowerShell.NetCore', 'AWSPowerShell') {
    try { Import-Module $m -ErrorAction Stop; break } catch { }
}
$token = Invoke-RestMethod -Method Put -TimeoutSec 5 -Uri 'http://169.254.169.254/latest/api/token' `
    -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '300' }
$region = Invoke-RestMethod -TimeoutSec 5 -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
    -Headers @{ 'X-aws-ec2-metadata-token' = $token }

# An update must not run over a live Nomad: stop it, replace the files, start it again.
Stop-ScheduledTask -TaskName 'Nomad' -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like '*nomad.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

New-Item -ItemType Directory -Force -Path $Target | Out-Null
$awsExe = 'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
if (Test-Path $awsExe) {
    & $awsExe s3 sync "s3://$Bucket/$Prefix" $Target --region $region --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "aws s3 sync failed with exit code $LASTEXITCODE" }
} else {
    Read-S3Object -BucketName $Bucket -KeyPrefix $Prefix -Folder $Target -Region $region | Out-Null
}
foreach ($f in 'nomad.py', 'uv.exe', 'uv.lock', 'config.server.toml', 'gen') {
    if (-not (Test-Path (Join-Path $Target $f))) { throw "bundle is missing $f - re-run the upload from the laptop" }
}
Copy-Item (Join-Path $Target 'config.server.toml') (Join-Path $Target 'config.toml') -Force
Write-Log "  files in $Target; config.server.toml is now config.toml"

# --- 2. Python environment --------------------------------------------------

$env:UV_PYTHON_INSTALL_DIR = Join-Path $Target 'python'
$env:UV_CACHE_DIR          = Join-Path $Target '.uv-cache'
Push-Location $Target
try {
    # --no-default-groups skips the 2 GB CUDA group: there is no GPU here.
    # uv reports progress on stderr, which 5.1 turns into a terminating
    # NativeCommandError under 'Stop' -- so judge it by exit code instead.
    $ErrorActionPreference = 'Continue'
    & (Join-Path $Target 'uv.exe') sync --frozen --no-default-groups 2>&1 | ForEach-Object { Write-Log "  uv: $_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { throw "uv sync failed with exit code $code" }
} finally { Pop-Location }
$python = Join-Path $Target '.venv\Scripts\python.exe'

# --- 3. checks that would otherwise only show up as a silent Nomad ----------

$payloads = @(Get-ChildItem "$DcsPath\MissionEditor\data\scripts\UnitPayloads\*.lua", "$DcsPath\CoreMods\aircraft\*\UnitPayloads\*.lua" -ErrorAction SilentlyContinue).Count
Write-Log "  aircraft loadout files in this DCS install: $payloads$(if ($payloads -eq 0) { '  <-- WARN: spawned aircraft would be unarmed or unknown' })"

# DCS-gRPC speaks with Windows' WinRT voices; tts_voice must name one of them.
[Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime] | Out-Null
$voices = @([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | ForEach-Object DisplayName)
Write-Log "  WinRT voices: $($voices -join ', ')"
$want = (Select-String -Path (Join-Path $Target 'config.toml') -Pattern '^tts_voice\s*=\s*"([^"]*)"').Matches.Groups[1].Value
if (-not ($voices | Where-Object { $_ -like "*$want*" })) { Write-Log "  WARN: tts_voice '$want' is not among them - set one of the above in config.server.toml" }

$grpcCfg = 'C:\Users\Administrator\Saved Games\DCS.server\Config\dcs-grpc.lua'
if (-not (Select-String -Path $grpcCfg -Pattern '^evalEnabled = true' -Quiet -ErrorAction SilentlyContinue)) {
    Write-Log '  WARN: DCS-gRPC Eval is off - Nomad will hear calls but every tool will fail. Run grpc-activate.ps1 -Eval with DCS stopped.'
}

# --- 4. the scheduled task --------------------------------------------------

# A runner script rather than python.exe directly: Task Scheduler drops stdout,
# and Nomad's console output is the only record of what it heard and did.
# It also restarts Nomad itself: the task's restart setting only covers a
# task that fails to launch, not a process that exits later.
# Not *>> : on 5.1 that writes UTF-16 and wraps every stderr line in a
# NativeCommandError record. Start-Process redirection keeps Python's UTF-8 as-is.
$runner = Join-Path $Target 'run-nomad.ps1'
[IO.File]::WriteAllText($runner, @"
`$log = '$StateDir\nomad.log'
`$env:PYTHONIOENCODING = 'utf-8'
while (`$true) {
    foreach (`$f in `$log, "`$log.err") { if (Test-Path `$f) { Move-Item -Force `$f "`$f.old" } }  # keep the previous run
    `$p = Start-Process -FilePath '$python' -ArgumentList '-u', 'nomad.py' -WorkingDirectory '$Target' ``
        -RedirectStandardOutput `$log -RedirectStandardError "`$log.err" -NoNewWindow -Wait -PassThru
    [IO.File]::AppendAllText(`$log, "`r`n`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Nomad exited (`$(`$p.ExitCode)), restarting in 30 s`r`n")
    Start-Sleep -Seconds 30
}
"@, (New-Object Text.UTF8Encoding($false)))

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runner`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
                 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Unregister-ScheduledTask -TaskName 'Nomad' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'Nomad' -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Nomad voice AI on SRS 251.0 AM (dcs-bob). Log: C:\dcs-state\nomad.log' | Out-Null
Write-Log '  registered task Nomad (SYSTEM, at startup, restarts on failure)'

if (-not $NoStart) {
    Start-ScheduledTask -TaskName 'Nomad'
    Write-Log "  started. Watch it: Get-Content $StateDir\nomad.log -Tail 30 -Wait"
}
Write-Log '=== done ==='
