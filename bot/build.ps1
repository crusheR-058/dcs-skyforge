# Vendors the Lambda's one dependency (PyNaCl, for Ed25519 verification) into
# bot\build\, which Terraform then zips.
#
# PyNaCl ships compiled C extensions, so a plain `pip install` on Windows would
# produce Windows binaries that cannot load in the Lambda runtime. The platform
# flags below fetch the Linux x86_64 wheels instead -- this works fine from a
# Windows machine and needs no Docker.
#
# Must match aws_lambda_function.bot: runtime python3.12, architecture x86_64.
#
# Run this before `terraform apply`, and again any time handler.py changes.

$ErrorActionPreference = 'Stop'

$here  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$build = Join-Path $here 'build'

if (Test-Path $build) {
    Remove-Item -Recurse -Force $build
}
New-Item -ItemType Directory -Force -Path $build | Out-Null

Write-Host 'Vendoring PyNaCl for linux/x86_64 + cpython 3.12 ...'

# Windows PowerShell 5.1 wraps ANY native-command stderr in a NativeCommandError
# and, under $ErrorActionPreference='Stop', treats it as fatal. pip writes its
# routine "a new release of pip is available" notice to stderr, so a perfectly
# successful install would otherwise abort this script. Judge pip by its exit
# code, which is the only thing that actually means anything here.
$prior = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

pip install `
    --platform manylinux2014_x86_64 `
    --implementation cp `
    --python-version 3.12 `
    --only-binary=:all: `
    --upgrade `
    --target $build `
    PyNaCl 2>&1 | ForEach-Object { "$_" }

$pipExit = $LASTEXITCODE
$ErrorActionPreference = $prior

if ($pipExit -ne 0) {
    throw "pip install failed with exit code $pipExit"
}

Copy-Item -Path (Join-Path $here 'handler.py') -Destination $build -Force

# boto3 is provided by the Lambda runtime; shipping our own copy would only
# bloat the package and risk drifting from the runtime's botocore.
$nacl = Join-Path $build 'nacl'
if (-not (Test-Path $nacl)) {
    throw "PyNaCl did not land in $build -- check the pip output above."
}

$size = '{0:N1} MB' -f ((Get-ChildItem -Recurse $build | Measure-Object -Property Length -Sum).Sum / 1MB)
Write-Host "Build ready at $build ($size)"
Write-Host 'Next: cd ..\infra; terraform apply'
