# Builds the Linux release inside WSL Ubuntu.
#
# Run this after Windows has restarted once with the WSL features enabled.
# The first run downloads Ubuntu, the Flutter SDK and the Linux build
# packages; later runs reuse them and only rebuild the app.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_linux_wsl.ps1
#
# The finished bundle is copied to build\linux\x64\release\bundle in this
# repository, the layout `flutter build linux --release` leaves on Linux.

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$distro = 'Ubuntu'
$guestRepo = '/root/phantrix'
$bundle = 'build/linux/x64/release/bundle'

function Invoke-Wsl {
    param([string[]]$Command)
    & wsl.exe -d $distro -u root -- @Command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $($Command -join ' ')"
    }
}

function ConvertTo-WslPath {
    param([string]$Path)
    $full = ($Path -replace '\\', '/')
    return "/mnt/$($full.Substring(0, 1).ToLower())$($full.Substring(2))"
}

Write-Host 'Checking WSL...'
& wsl.exe -l -q *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'WSL is not ready. Restart Windows once, then run this script again.'
}

$distros = (& wsl.exe -l -q) | ForEach-Object { $_.Trim() -replace "`0", '' } | Where-Object { $_ }
if ($distros -notcontains $distro) {
    Write-Host "Installing $distro (first run only)..."
    & wsl.exe --install -d $distro --no-launch
    if ($LASTEXITCODE -ne 0) {
        throw "Ubuntu could not be installed. Run 'wsl --install -d Ubuntu' once, then run this script again."
    }
}

Write-Host 'Installing build packages inside Ubuntu...'
Invoke-Wsl @(
    'bash', '-lc',
    'set -e; export DEBIAN_FRONTEND=noninteractive; ' +
    'apt-get update -qq; ' +
    'apt-get install -y --no-install-recommends ' +
    'curl git unzip xz-utils zip ca-certificates ' +
    'clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev ' +
    'libstdc++-12-dev libglu1-mesa'
)

Write-Host 'Installing the Flutter SDK inside Ubuntu (first run only)...'
Invoke-Wsl @(
    'bash', '-lc',
    'set -e; ' +
    'if [ ! -d /opt/flutter ]; then ' +
    'git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter; ' +
    'fi; ' +
    'git config --global --add safe.directory /opt/flutter; ' +
    '/opt/flutter/bin/flutter config --no-analytics >/dev/null; ' +
    '/opt/flutter/bin/flutter --version'
)

Write-Host 'Copying the repository into the WSL filesystem...'
# Built from the Linux filesystem: builds over /mnt/c are much slower and the
# Windows file times upset the build tools.
$archive = Join-Path $env:TEMP 'phantrix-linux-src.tar.gz'
if (Test-Path $archive) { Remove-Item $archive -Force }
& tar.exe -czf $archive `
    --exclude=build `
    --exclude=.dart_tool `
    --exclude=.git `
    --exclude=packages/phantrix_platform/build `
    -C $repo .
if ($LASTEXITCODE -ne 0) { throw 'The source archive could not be created.' }

Invoke-Wsl @('bash', '-lc', "rm -rf $guestRepo && mkdir -p $guestRepo")
Invoke-Wsl @('bash', '-lc', "tar -xzf $(ConvertTo-WslPath $archive) -C $guestRepo")

Write-Host 'Building the Linux release...'
# --release only: a debug bundle is ~10x larger and carries the observatory,
# so the script never builds one.
Invoke-Wsl @(
    'bash', '-lc',
    "set -e; cd $guestRepo; /opt/flutter/bin/flutter pub get; /opt/flutter/bin/flutter build linux --release"
)
Invoke-Wsl @(
    'bash', '-lc',
    "set -e; test -x $guestRepo/$bundle/phantrix || " +
    "{ echo 'release bundle is missing the phantrix binary'; exit 1; }; " +
    "test ! -d $guestRepo/$bundle/data/flutter_assets/observatory || " +
    "{ echo 'this is a debug bundle, not a release one'; exit 1; }"
)

Write-Host 'Copying the bundle back to Windows...'
$target = Join-Path $repo 'build\linux\x64\release\bundle'
if (Test-Path $target) { Remove-Item $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Invoke-Wsl @('bash', '-lc', "cp -r $guestRepo/$bundle/. '$(ConvertTo-WslPath $target)/'")

Write-Host ''
Write-Host "Linux release ready: $target"
