#!/usr/bin/env pwsh
#
# Downloads the official sing-box Windows release, verifies its SHA-256 against
# a pinned value, and installs `sing-box.exe` into the Windows plugin's
# `bundle/sing-box/` directory.
#
# ## Why sing-box
#
# Split tunnelling on Windows needs something that decides, per application,
# whether a connection uses the tunnel. An own kernel driver can only be loaded
# on ordinary PCs once Microsoft has signed it. sing-box does the routing in
# user mode through a Wintun adapter, and Wintun is already Microsoft-signed, so
# nothing this project builds runs in the kernel.
#
# sing-box is GPL-3.0-or-later (https://github.com/SagerNet/sing-box). It runs
# as a separate process the helper starts; Phantrix is itself GPL-3.0, so the
# licences are compatible either way. The release's LICENSE carries an extra
# request that derivative works not use its name; Phantrix ships the unmodified
# binary and does not brand anything with it.
#
# ## Why the hash is pinned in this file
#
# Same reason as `fetch_openvpn_bundle.ps1`: the binary that ships must be the
# binary that was chosen. The pinned value was checked against the digest
# GitHub publishes for the release asset.
#
# ## Usage
#
#     pwsh -File tools/fetch_singbox_bundle.ps1
#     pwsh -File tools/fetch_singbox_bundle.ps1 -Force   # re-download
#     pwsh -File tools/fetch_singbox_bundle.ps1 -VerifyOnly
#
# Exit codes: 0 = present and verified, 1 = verification or extraction failed.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$VerifyOnly,
    [string]$StagingPath = (Join-Path $env:TEMP 'phantrix-singbox-bundle')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pluginRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'packages\phantrix_platform\windows'
$bundleDir = Join-Path $pluginRoot 'bundle\sing-box'

$version = '1.14.4'
$zipName = "sing-box-$version-windows-amd64.zip"
$zipUrl = "https://github.com/SagerNet/sing-box/releases/download/v$version/$zipName"
# SHA-256 of the downloaded archive (matches GitHub's published asset digest).
$zipHash = '99185D75D314A07DBBA4A130C8AD986CBEB629A07927975636B341CA61F991DF'
# SHA-256 of the extracted executable, checked independently after install.
$exeHash = '8F30682EE198855440D2A7FE070D5D3653793B2D01BB8C85EEA88F93BBE7C8B9'

function Test-Installed {
    $exe = Join-Path $bundleDir 'sing-box.exe'
    $license = Join-Path $bundleDir 'LICENSE'
    if (-not (Test-Path $exe) -or -not (Test-Path $license)) {
        return $false
    }
    return (Get-FileHash -Algorithm SHA256 $exe).Hash -eq $exeHash
}

if ($VerifyOnly) {
    if (Test-Installed) {
        Write-Host "sing-box $version bundle verified."
        exit 0
    }
    Write-Error "sing-box bundle missing or does not match the pinned hash."
    exit 1
}

if (-not $Force -and (Test-Installed)) {
    Write-Host "sing-box $version already present and verified."
    exit 0
}

New-Item -ItemType Directory -Force -Path $StagingPath | Out-Null
$zipPath = Join-Path $StagingPath $zipName
Write-Host "Downloading $zipUrl"
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 $zipPath).Hash
if ($actual -ne $zipHash) {
    Remove-Item -Force $zipPath
    Write-Error "sing-box archive hash mismatch. Expected $zipHash, got $actual."
    exit 1
}

$extractDir = Join-Path $StagingPath 'extract'
if (Test-Path $extractDir) {
    Remove-Item -Recurse -Force $extractDir
}
Expand-Archive -Path $zipPath -DestinationPath $extractDir
$inner = Join-Path $extractDir "sing-box-$version-windows-amd64"

New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
# Only the executable and its licence. `libcronet.dll` serves an outbound type
# this app never configures, so it is not shipped.
Copy-Item -Force (Join-Path $inner 'sing-box.exe') (Join-Path $bundleDir 'sing-box.exe')
Copy-Item -Force (Join-Path $inner 'LICENSE') (Join-Path $bundleDir 'LICENSE')

if (-not (Test-Installed)) {
    Write-Error "Installed sing-box.exe does not match the pinned hash."
    exit 1
}
Write-Host "sing-box $version installed to $bundleDir"
exit 0
