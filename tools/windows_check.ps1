<#
.SYNOPSIS
    Checks whether Phantrix's Windows tunnel can run, without changing anything.

.DESCRIPTION
    Reports three facts and exits:

      1. Is WireGuard for Windows installed, and where?
      2. Can `wireguard.exe` be reached and what does it report about itself?
      3. Is this session an elevated Administrator?

    Nothing in this script installs, uninstalls, starts, stops or
    reconfigures anything. It does not write to the registry, does not
    create or remove a tunnel, and does not modify a route or the
    firewall. It only reads installed-file locations, queries a
    service, and asks Windows whether the current token is a member of
    the Administrators group.

    The distinction matters: a VPN client that "helpfully" installed a
    tunnel service or added a firewall rule would be changing the
    user's system as a side effect of being asked a question. This
    script answers the question and stops.

.EXAMPLE
    pwsh -NoProfile -File tools\windows_check.ps1

    Installed   : True
    Binary      : C:\Program Files\WireGuard\wireguard.exe
    Version     : 0.5.3
    Service     : None
    Elevated    : False
    Verdict     : Not ready — run from an Administrator prompt.

.NOTES
    Exit codes: 0 = ready, 1 = not ready, 2 = could not determine.
#>
[CmdletBinding()]
param(
    # Report the verdict but always exit 0. Useful in a wrapper that
    # must not fail on a machine that simply is not set up for a VPN.
    [switch]$AlwaysSucceed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        True when this token is a member of the Administrators group.

    .NOTES
        Checked with `whoami /groups` fallback because
        `[Security.Principal.WindowsPrincipal]` reports the group
        membership of the *process* token, which is a filtered
        preview token when UAC remote-desktop or token filtering is
        in effect. Asking `whoami` consults the effective access,
        which is what actually decides whether a service can be
        installed.
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return $true
        }
    } catch {
        # Fall through to the command, which is the authoritative answer.
    }
    try {
        # S-1-16-12288 is the High Mandatory Level: the token is elevated.
        # Matching the Administrators group SID (S-1-5-32-544) instead would be
        # wrong, because a filtered token still lists that group — marked
        # "deny only". On such a token the group grants nothing and the
        # process cannot install a service, so reporting it as elevated would
        # send the user down a path that cannot work.
        $groups = & whoami /groups 2>&1 | Out-String
        return ($groups -match 'S-1-16-12288')
    } catch {
        return $false
    }
}

function Get-KnownInstallPaths {
    <#
    .SYNOPSIS
        The two per-machine locations WireGuard for Windows installs to.

    .NOTES
        The registry is checked rather than assumed, because a
        per-user or relocated install would otherwise be reported
        as missing while the product is in fact present.
    #>
    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($registryPath in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )) {
        try {
            Get-ItemProperty $registryPath -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'WireGuard*' } |
                ForEach-Object {
                    if ($_.InstallLocation) {
                        $candidate = Join-Path $_.InstallLocation 'wireguard.exe'
                        if (Test-Path -LiteralPath $candidate) {
                            $paths.Add($candidate)
                        }
                    }
                }
        } catch {
            # A registry read failure is not a reason to stop; the
            # well-known paths below still get checked.
        }
    }

    $paths.Add('C:\Program Files\WireGuard\wireguard.exe')
    $paths.Add('C:\Program Files (x86)\WireGuard\wireguard.exe')
    return $paths | Select-Object -Unique
}

$installedAt = $null
foreach ($candidate in (Get-KnownInstallPaths)) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $installedAt = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}

$binaryVersion = $null
if ($installedAt) {
    try {
        $binaryVersion = (Get-Item -LiteralPath $installedAt).VersionInfo.FileVersion
    } catch {
        $binaryVersion = $null
    }
}

$serviceName = $null
try {
    $service = Get-Service -Name 'WireGuard*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($service) {
        $serviceName = '{0} ({1})' -f $service.Name, $service.Status
    }
} catch {
    # `Get-Service` requires the service control manager, which is not
    # present on every edition. A tunnel service that cannot be
    # enumerated is reported below as unknown rather than as absent.
}

$elevated = Test-IsAdministrator

# `??` is deliberately not used here: this script must parse on Windows
# PowerShell 5.1, which is what a user gets when they open "PowerShell" on a
# stock machine, and 5.1 has no null-coalescing operator. A diagnostic that
# only runs on PowerShell 7 is a diagnostic most users cannot run.
$serviceDisplay = if ($serviceName) { $serviceName } else { 'None' }
$binaryDisplay = if ($installedAt) { $installedAt } else { $null }
[pscustomobject]@{
    Installed = [bool]$installedAt
    Binary    = $binaryDisplay
    Version   = $binaryVersion
    Service   = $serviceDisplay
    Elevated  = $elevated
} | Format-List

<#
.REASONING
    Installing a tunnel service is what `wireguard.exe
    /installtunnelservice` does, and it needs CAP_NET_ADMIN. Without
    it the app can still build the configuration file and reach the
    point of trying, which is exactly enough for a useful report.
#>
$reasons = New-Object System.Collections.Generic.List[string]

# Each message is built in a variable before the Add call. Splitting a
# method call's arguments across lines does not parse on Windows PowerShell
# 5.1, and this script must run there — see the note above about `??`.
if (-not $installedAt) {
    $missingBinary = 'WireGuard for Windows is not installed. Install it from ' +
        'https://www.wireguard.com/install/ (the official installer, which ' +
        'also installs the Wintun driver the tunnel needs).'
    $reasons.Add($missingBinary)
    # Without the binary there is nothing further to ask about it.
} else {
    if (-not $elevated) {
        $notElevated = 'This session is not an Administrator. Starting a tunnel ' +
            'installs a Windows service, which requires elevation. Re-run ' +
            'Phantrix from an elevated prompt.'
        $reasons.Add($notElevated)
    }
    if (-not $serviceName) {
        $noService = 'No tunnel service is installed yet. That is normal before ' +
            'the first connection; Phantrix creates it then. If a tunnel was ' +
            'previously connected and no service exists, the installation ' +
            'may have been removed.'
        $reasons.Add($noService)
    }
    if (-not $binaryVersion) {
        $noVersion = 'The WireGuard binary version could not be read. The tunnel ' +
            'may still work; this is reported so it is visible rather than ' +
            'silently assumed.'
        $reasons.Add($noVersion)
    }
}

if ($reasons.Count -eq 0) {
    $verdict = 'Ready — WireGuard is installed and this session can elevate.'
    $exitCode = 0
} else {
    $verdict = "Not ready:`n" + (($reasons | ForEach-Object { "  - $_" }) -join "`n")
    $exitCode = 1
}

Write-Output ''
Write-Output ('Verdict   : {0}' -f ($verdict -replace "`n", "`n            "))

exit $(if ($AlwaysSucceed) { 0 } else { $exitCode })
