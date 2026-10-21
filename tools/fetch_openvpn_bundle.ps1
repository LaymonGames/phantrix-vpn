#!/usr/bin/env pwsh
#
# Downloads the official OpenVPN 2.6 community binaries and the wintun driver,
# verifies their SHA-256 against a pinned value, and installs them into the
# Windows plugin's `bundle/openvpn/` directory.
#
# ## Why the hashes are pinned in this file
#
# The engine is the one part of the tunnel this repository does not build, so
# the thing that has to be established is that the binary that ships is the
# binary that was chosen. A URL is not that: a compromised mirror, a hijacked
# CDN or a future maintainer pointing at a different build would all be
# invisible. A pinned SHA-256 is checked before anything is extracted, so a
# binary that is not the expected one fails the download rather than reaching a
# user's machine.
#
# ## Where the files come from
#
#   * OpenVPN 2.6.17 — `https://swupdate.openvpn.org/community/releases/`, the
#     project's own release host. OpenVPN 2.x community is GPLv2; the engine is
#     a separate process this app launches, so this is aggregation, not linking,
#     and no part of this repository's own source is affected by the licence.
#   * wintun 0.14.1 — `https://www.wintun.net/builds/`, WireGuard LLC's
#     prebuilt distribution of their own driver. Its licence permits
#     redistribution only when distributed alongside software that uses the
#     DLL exclusively through the permitted API in `wintun.h`. The Phantrix
#     app does not call the DLL itself; the bundled OpenVPN process is the API
#     consumer. Keep the unmodified DLL paired with OpenVPN and do not ship it
#     as a standalone download. Confirm this exception against the exact bundle
#     before release.
#
# ## What it does not do
#
# It does not run the MSI installer. `msiexec /a` extracts the package's files
# into a directory without registering anything, installing a service, adding a
# route or touching the registry, and it needs no elevation. Nothing in this
# script changes the machine it runs on.
#
# ## Usage
#
#     pwsh -File tools/fetch_openvpn_bundle.ps1
#     pwsh -File tools/fetch_openvpn_bundle.ps1 -Force   # re-download
#     pwsh -File tools/fetch_openvpn_bundle.ps1 -VerifyOnly
#
# Exit codes: 0 = present and verified, 1 = verification or extraction failed.

[CmdletBinding()]
param(
    # Re-download even when the bundle is already present and intact.
    [switch]$Force,
    # Check the bundle that is already there and exit. Downloads nothing.
    [switch]$VerifyOnly,
    # The staging directory for downloads. Defaults to the system temp folder.
    [string]$StagingPath = (Join-Path $env:TEMP 'phantrix-openvpn-bundle')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The plugin's own Windows directory. Resolved from the script's location rather
# than from the current directory, so this works from any working directory.
$pluginRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'packages\phantrix_platform\windows'
$bundleDir = Join-Path $pluginRoot 'bundle\openvpn'

# ---------------------------------------------------------------------------
# Pinned artifacts
# ---------------------------------------------------------------------------

# Every file the bundle needs, in one table.
#
# `Hash` is the SHA-256 of the *downloaded archive*, not of the extracted file:
# that is the only value that can be checked before anything is trusted. The
# extracted files are then installed with a second, independent hash check in
# `Invoke-VerifyBundle` so a partial or stale extraction cannot pass by.
$openVpnMsiName = 'OpenVPN-2.6.17-I001-amd64.msi'
$openVpnMsiUrl = "https://swupdate.openvpn.org/community/releases/$openVpnMsiName"
$openVpnMsiHash = '961E38B4872F022CC63160BD1490AF74E3ADC88EC1F2E366964F1BBFAFF6FCE8'
$openVpnLicenseUrl = 'https://openvpn.net/community/'

$wintunZipName = 'wintun-0.14.1.zip'
$wintunZipUrl = "https://www.wintun.net/builds/$wintunZipName"
$wintunZipHash = '07C256185D6EE3652E09FA55C0B673E2624B565E02C4B9091C79CA7D2F24EF51'
$wintunLicenseUrl = 'https://www.wintun.net/'

# The files that must exist in the finished bundle, and the hashes of the
# extracted contents.
#
# `Libs` is deliberately not "everything in the bin directory". The MSI ships an
# OpenVPN GUI, a PLAP login provider and TAP helpers that this backend never
# starts; shipping them would put a large amount of unexamined executable into
# every user's install directory.
$requiredFiles = [ordered]@{
    'openvpn.exe' = 'CDD4A0141DDCFCAB2CA7705C860FC0830C14C73C71A18BEDC8A8941FC15DE6A4'
    'libcrypto-3-x64.dll' = 'F470C0F1D33D9FF4760AC2BE04DF7F5BE45A0D3EDB3667BFADD85C9ED741C0A9'
    'libssl-3-x64.dll' = '6213D117F23CA3204EB75AAA9E1DC48D620450D0401D0F1B3D73F7DE49377702'
    'libpkcs11-helper-1.dll' = '5D09F737B244838BCF0ACD48E30A02641595B867FE65113F9D91838D22B53D9A'
    'vcruntime140.dll' = 'C51C64DFB7C445ECF0001F69C27E13299DDCFBA0780EFA72B866A7487B7491C7'
    'wintun.dll' = 'E5DA8447DC2C320EDC0FC52FA01885C103DE8C118481F683643CACC3220DAFCE'
    'LICENSE.txt' = 'BDC79E56CDA498DC959E20F91620836A65C4EEFF329D00DE1BA2AB146BAF087F'
}

function Write-Step {
    param([string]$Message)
    Write-Host "  $Message"
}

function Get-FileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-Download {
    param(
        [string]$Url,
        [string]$DestinationPath,
        [string]$ExpectedHash
    )
    if (Test-Path -LiteralPath $DestinationPath) {
        $existing = Get-FileSha256 -Path $DestinationPath
        if ($existing -eq $ExpectedHash) {
            Write-Step "already downloaded: $(Split-Path -Leaf $DestinationPath)"
            return $true
        }
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    }
    Write-Step "downloading: $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -TimeoutSec 600 -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        Write-Warning "download failed: $Url`n$($_.Exception.Message)"
        return $false
    }
    $actual = Get-FileSha256 -Path $DestinationPath
    if ($actual -ne $ExpectedHash) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        Write-Warning ("SHA-256 mismatch for $(Split-Path -Leaf $DestinationPath)`n" +
                       "  expected $ExpectedHash`n  actual   $actual`n" +
                       "The download is not the pinned build and has been deleted.")
        return $false
    }
    Write-Step "verified $(Split-Path -Leaf $DestinationPath) ($([math]::Round((Get-Item -LiteralPath $DestinationPath).Length / 1MB, 1)) MB)"
    return $true
}

function Invoke-VerifyBundle {
    <#
    .SYNOPSIS
        Returns true when every required file is present with its pinned hash.

    .NOTES
        This is the check that fails a build rather than a download: the pinned
        hashes are of the extracted contents, so an archive that was verified but
        extracted wrongly cannot pass.
    #>
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($name in $requiredFiles.Keys) {
        $path = Join-Path $bundleDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            $problems.Add("$name is missing")
            continue
        }
        $actual = Get-FileSha256 -Path $path
        if ($actual -ne $requiredFiles[$name]) {
            $problems.Add("$name has the wrong hash (expected $($requiredFiles[$name]), found $actual)")
        }
    }
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Warning "bundle check: $problem"
        }
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Phantrix Windows OpenVPN bundle'
Write-Host ''

if ((Test-Path -LiteralPath $bundleDir) -and -not $Force) {
    if (Invoke-VerifyBundle) {
        Write-Step 'the bundle is already present and every file matches its pinned hash'
        if ($VerifyOnly) {
            exit 0
        }
        Write-Step 'nothing to do. Use -Force to re-download.'
        exit 0
    }
    if ($VerifyOnly) {
        exit 1
    }
    Write-Step 'the bundle is incomplete or has the wrong contents; re-fetching'
}

if ($VerifyOnly) {
    Write-Error "no bundle at $bundleDir. Run without -VerifyOnly to fetch it."
    exit 1
}

New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null

# --- OpenVPN ---
$msiPath = Join-Path $StagingPath $openVpnMsiName
if (-not (Invoke-Download -Url $openVpnMsiUrl -DestinationPath $msiPath -ExpectedHash $openVpnMsiHash)) {
    exit 1
}

# `msiexec /a` is an administrative *install*: it extracts the package's files
# into a directory. It does not register anything, install a service, or need
# an administrator token, and it is the documented way to read an MSI's
# contents. The extracted files are then copied into the bundle by hand.
$extractDir = Join-Path $StagingPath 'openvpn-extract'
if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

Write-Step 'extracting the installer'
$logPath = Join-Path $StagingPath 'msiexec.log'
$process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @(
    '/a', "`"$msiPath`"",
    '/qn', '/norestart',
    "TARGETDIR=`"$extractDir`"",
    '/lv', "`"$logPath`""
) -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -ne 0) {
    Write-Error "msiexec exited with $($process.ExitCode); see $logPath"
    exit 1
}

$extractedBin = Join-Path $extractDir 'OpenVPN\bin'
if (-not (Test-Path -LiteralPath $extractedBin)) {
    Write-Error "the installer did not contain OpenVPN\bin; check $logPath"
    exit 1
}

# Files copied out of the extracted package.
$openVpnSources = @('openvpn.exe', 'libcrypto-3-x64.dll', 'libssl-3-x64.dll', 'libpkcs11-helper-1.dll', 'vcruntime140.dll')
foreach ($name in $openVpnSources) {
    $source = Join-Path $extractedBin $name
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Error "the installer did not contain $name"
        exit 1
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $bundleDir $name) -Force
}
Write-Step "copied the engine from the verified installer"

# --- wintun ---
$wintunPath = Join-Path $StagingPath $wintunZipName
if (-not (Invoke-Download -Url $wintunZipUrl -DestinationPath $wintunPath -ExpectedHash $wintunZipHash)) {
    exit 1
}

Write-Step 'extracting the wintun driver'
$wintunExtractDir = Join-Path $StagingPath 'wintun-extract'
if (Test-Path -LiteralPath $wintunExtractDir) {
    Remove-Item -LiteralPath $wintunExtractDir -Recurse -Force -ErrorAction SilentlyContinue
}
try {
    Expand-Archive -LiteralPath $wintunPath -DestinationPath $wintunExtractDir -Force
} catch {
    Write-Error "could not extract $wintunZipName`: $($_.Exception.Message)"
    exit 1
}

# The driver for the architecture this build targets. x64 is the only
# architecture `flutter build windows` produces here, and a driver for the
# wrong architecture would fail to load rather than run.
$wintunDll = Join-Path $wintunExtractDir 'wintun\bin\amd64\wintun.dll'
if (-not (Test-Path -LiteralPath $wintunDll)) {
    Write-Error "the wintun package did not contain bin\amd64\wintun.dll"
    exit 1
}
Copy-Item -LiteralPath $wintunDll -Destination (Join-Path $bundleDir 'wintun.dll') -Force

# The licence the engine ships, kept beside the binary it describes.

$licenseDestination = Join-Path $bundleDir 'LICENSE.txt'
$licenseSource = Join-Path $extractedBin '..\license.txt'
if (Test-Path -LiteralPath $licenseSource) {
    Copy-Item -LiteralPath $licenseSource -Destination $licenseDestination -Force
    Write-Step 'copied the GPLv2 licence text beside the engine'
} else {
    # Not fatal: the licence is a documentation requirement, not a build input,
    # and the third-party notices document is where it actually belongs.
    Write-Step 'the installer carried no license.txt; the notice is still in THIRD_PARTY_LICENSES.md'
}

# --- Final verification ---
Write-Host ''
Write-Step 'verifying the bundle'
if (-not (Invoke-VerifyBundle)) {
    Write-Error 'the bundle did not verify; do not use it for a release'
    exit 1
}

$files = Get-ChildItem -LiteralPath $bundleDir -File | Sort-Object Name
Write-Host ''
Write-Host 'Bundle installed at:'
Write-Host "  $bundleDir"
foreach ($file in $files) {
    Write-Host ("    {0,-22} {1,8:N0} bytes" -f $file.Name, $file.Length)
}
Write-Host ''
Write-Host 'Third-party provenance:'
Write-Host "  OpenVPN 2.6.17 community  $openVpnMsiUrl"
Write-Host "    SHA-256 $openVpnMsiHash"
Write-Host "    GPLv2, $openVpnLicenseUrl"
Write-Host "  wintun 0.14.1             $wintunZipUrl"
Write-Host "    SHA-256 $wintunZipHash"
Write-Host "    WireGuard LLC prebuilt binaries licence, $wintunLicenseUrl"
Write-Host ''
Write-Host 'The bundle contents are not committed: .gitignore keeps them out of'
Write-Host 'the repository, and this script is how they are restored on a new'
Write-Host 'machine or a clean checkout.'
Write-Host ''
exit 0
