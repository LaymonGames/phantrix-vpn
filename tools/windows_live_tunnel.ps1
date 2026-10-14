<#
.SYNOPSIS
	Live end-to-end verification of the Windows OpenVPN tunnel, scripted.

.DESCRIPTION
	Runs the bundled engine the way the elevated helper runs it —

	  openvpn.exe --config <profile> --windows-driver wintun --dev-node Phantrix --log <file>

	— against each `.ovpn` profile given, and while the tunnel is up polls
	every two seconds for: the Wintun adapter, the tunnel address, and the
	exit address from two independent services. Then it stops the engine and
	reverses every leftover against a baseline taken before the first attempt
	(routes, adapters, per-interface DNS, exit address), retrying the exit
	address read because the resolver needs a moment after the tunnel
	interface disappears.

	Exit codes:
	  0 - `Initialization Sequence Completed`, the exit address changed, and
	      the machine is back at its baseline (this is a pass).
	  1 - no relay completed a handshake.
	  3 - the tunnel came up but the exit address did not change, or teardown
	      left differences (each is listed in the log).
	  2 - could not run (not elevated, engine missing, or no profiles).

	Elevated rights are required: the engine creates a Wintun adapter, which
	needs Administrator. Launched unelevated through
	`Start-Process -Verb RunAs`, the user's single UAC consent is what starts
	it; everything it did is in the log it names.

	Three things this script exists to do correctly, each learned from a run
	on 2026-10-13 (see docs/EVIDENCE.md, addendum of that date):

	  * The adapter probe (tools/windows/phantrix_adapter_probe.cpp with
	    --run) cannot be used for an exit-address check: wintun removes an
	    adapter when its creating handle closes, the probe creates the
	    adapter, and so a tunnel driven through the probe collapses exactly
	    when the probe returns. When the engine creates the adapter itself —
	    which is also what the helper's launch does — the tunnel lasts until
	    the engine is stopped.
	  * GenerateConsoleCtrlEvent(CTRL_C, 0) after AttachConsole reaches the
	    sending script as well as the engine (0xC000013A killed a run
	    mid-verdict). The engine is force-stopped here, and the baseline diff
	    does the restoring.
	  * Every poll iteration is logged, failures included: a silent poll loop
	    gave no clue why an earlier run captured nothing.

.EXAMPLE
	# From an Administrator PowerShell, with profiles emitted by
	# `dart run tools/diagnose_windows.dart --emit <dir>`:
	tools\windows_live_tunnel.ps1 -Profiles "$env:TEMP\opencode\vpn483423733.ovpn"

.NOTES
	Pairs with procedure C in docs/evidence/openvpn/WINDOWS_LIVE_VERIFICATION.md.
#>
[CmdletBinding()]
param(
	# `.ovpn` files to try, in order. Each is attempted only if the previous
	# one did not both complete and change the exit address.
	[string[]]$Profiles = @(),
	# The built Windows bundle that holds openvpn.exe and wintun.dll.
	[string]$BundlePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\windows\x64\runner\Release'),
	# Where the full transcript is written.
	[string]$LogFile = (Join-Path $env:TEMP 'phantrix-live-tunnel.log'),
	# Seconds to keep trying one relay before moving on.
	[int]$WindowSeconds = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$logPath = $LogFile
function Say([string]$message) {
	# Retried because a sharing violation on the log must not silently lose
	# the line (two were lost this way on 2026-10-13).
	$line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $message
	for ($attempt = 1; $attempt -le 3; $attempt++) {
		try {
			[System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine)
			return
		} catch {
			if ($attempt -eq 3) {
				try {
					[System.IO.File]::AppendAllText($logPath,
						('SAY-FAILED: {0} -- for message: {1}' -f $_.Exception.Message, $line) +
						[Environment]::NewLine)
				} catch { }
				return
			}
			Start-Sleep -Milliseconds 250
		}
	}
}

function Get-ExitIp([string]$service) {
	try { return (Invoke-RestMethod $service -TimeoutSec 8).ToString().Trim() }
	catch { return 'unreachable' }
}
function Get-WintunAdapters {
	@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like '*Wintun*' })
}
function Stop-Engine {
	$procs = @(Get-Process openvpn -ErrorAction SilentlyContinue)
	foreach ($proc in $procs) {
		Say ('force-stopping openvpn pid {0}' -f $proc.Id)
		try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Say ("stop failed: {0}" -f $_.Exception.Message) }
	}
	if ($procs.Count -gt 0) { Start-Sleep -Seconds 2 }
}

$engine = Join-Path $BundlePath 'openvpn.exe'
$code = 3
$haveBaseline = $false
$restoredAll = $false
$passed = $false
$usedProfile = $null
$liveIp = $null
$liveTunnelIp = $null
$baselineExit = 'unreachable'
$baselineRoutes = @()
$baselineDns = @{}
try {
	$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	Say ('elevated={0} user={1} engine={2}' -f $isAdmin, $env:USERNAME, $engine)
	if (-not $isAdmin) { Say 'FAIL: not elevated - re-run from an Administrator prompt'; $code = 2 }
	elseif (-not (Test-Path -LiteralPath $engine)) { Say "FAIL: engine missing: $engine"; $code = 2 }
	elseif ($Profiles.Count -eq 0) { Say 'FAIL: pass at least one .ovpn with -Profiles'; $code = 2 }
	else {
		Stop-Engine
		$baselineExit = Get-ExitIp 'https://api.ipify.org'
		foreach ($r in Get-NetRoute -ErrorAction SilentlyContinue) {
			$baselineRoutes += ('{0}|{1}|{2}' -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceIndex)
		}
		foreach ($d in Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
			$baselineDns[$d.InterfaceIndex] = @($d.ServerAddresses) -join ','
		}
		Say ('baseline: exit ip={0} routes={1} wintun adapters={2}' -f $baselineExit, $baselineRoutes.Count, (Get-WintunAdapters).Count)
		$haveBaseline = $true

		foreach ($p in $Profiles) {
			if (-not (Test-Path -LiteralPath $p)) { Say "profile missing: $p"; continue }
			$name = Split-Path $p -Leaf
			$engineLog = "$p.engine.log"
			Remove-Item -LiteralPath $engineLog -Force -ErrorAction SilentlyContinue
			Say ("--- launching engine: {0} ---" -f $name)
			$argumentList = @(
				'--config', "`"$p`"",
				'--windows-driver', 'wintun',
				'--dev-node', 'Phantrix',
				'--log', "`"$engineLog`""
			)
			$proc = Start-Process -FilePath $engine -ArgumentList $argumentList -PassThru -WindowStyle Hidden
			$started = Get-Date
			$completed = $false
			$seenTunnel = $false
			while (-not $proc.HasExited -and ((Get-Date) - $started).TotalSeconds -lt $WindowSeconds) {
				Start-Sleep -Seconds 2
				$ads = Get-WintunAdapters
				$names = @($ads | ForEach-Object { $_.Name })
				$tunnelIp = ''
				if ($names.Count -gt 0) {
					$ips = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $names -ErrorAction SilentlyContinue)
					$tunnelIp = @($ips | ForEach-Object { $_.IPAddress }) -join ','
					if ($tunnelIp) { $seenTunnel = $true; $liveTunnelIp = $tunnelIp }
				}
				$ip1 = Get-ExitIp 'https://api.ipify.org'
				$ip2 = Get-ExitIp 'https://ifconfig.me/ip'
				$elapsed = [int]((Get-Date) - $started).TotalSeconds
				Say ("poll t+{0}s adapters={1} tunnel={2} ipify={3} ifconfig={4}" -f `
					$elapsed, $ads.Count, $tunnelIp, $ip1, $ip2)
				foreach ($ip in @($ip1, $ip2)) {
					if ($ip -ne 'unreachable' -and $ip -ne $baselineExit) { $liveIp = $ip }
				}
				if (-not $completed) {
					try {
						$raw = Get-Content -LiteralPath $engineLog -Raw -ErrorAction Stop
						if ($raw -match 'Initialization Sequence Completed') { $completed = $true; Say 'engine log: Initialization Sequence Completed' }
					} catch { }
				}
				if ($completed -and $liveIp -and $seenTunnel) { break }
			}
			if (Test-Path -LiteralPath $engineLog) {
				Say '--- engine log tail ---'
				foreach ($line in (Get-Content -LiteralPath $engineLog -Tail 8)) { Say $line }
			}
			Stop-Engine
			if ($completed) {
				$passed = $true
				$usedProfile = $p
				if ($liveIp) { break } else { Say 'completed but the exit address never changed; trying the next relay' }
			} else {
				Say 'no Initialization Sequence Completed; trying the next relay'
			}
		}

		if ($passed) { Say ('TUNNEL UP with {0}' -f (Split-Path $usedProfile -Leaf)) }
		else { Say 'NO TUNNEL: no relay completed a handshake' }
	}
} finally {
	# Teardown and verification run whenever a baseline was taken, and never
	# otherwise: without one, every existing route would look like a leftover.
	if ($haveBaseline) {
		Stop-Engine
		$restoredAll = $true
		$extra = 0
		foreach ($r in Get-NetRoute -ErrorAction SilentlyContinue) {
			$key = '{0}|{1}|{2}' -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceIndex
			if ($baselineRoutes -notcontains $key) {
				$restoredAll = $false
				$extra++
				Say ("removing leftover route {0} via {1} (if {2})" -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceIndex)
				Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -NextHop $r.NextHop -InterfaceIndex $r.InterfaceIndex -Confirm:$false -ErrorAction SilentlyContinue
			}
		}
		foreach ($a in Get-WintunAdapters) {
			$restoredAll = $false
			Say ("removing leftover adapter {0} ({1})" -f $a.Name, $a.Status)
			Remove-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
		}
		foreach ($d in Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue) {
			$now = @($d.ServerAddresses) -join ','
			$was = ''
			if ($baselineDns.ContainsKey($d.InterfaceIndex)) { $was = $baselineDns[$d.InterfaceIndex] }
			if ($now -ne $was) {
				$restoredAll = $false
				Say ("restoring DNS on if {0}: '{1}' -> '{2}'" -f $d.InterfaceIndex, $now, $was)
				if ($was -eq '') {
					Set-DnsClientServerAddress -InterfaceIndex $d.InterfaceIndex -ResetServerAddresses -ErrorAction SilentlyContinue
				} else {
					Set-DnsClientServerAddress -InterfaceIndex $d.InterfaceIndex -ServerAddresses ($was -split ',') -ErrorAction SilentlyContinue
				}
			}
		}
		Start-Sleep -Seconds 2

		$finalExit = 'unreachable'
		for ($i = 1; $i -le 4 -and $finalExit -eq 'unreachable'; $i++) {
			$finalExit = Get-ExitIp 'https://api.ipify.org'
			if ($finalExit -eq 'unreachable') { Start-Sleep -Seconds 2 }
		}
		$finalAdapters = (Get-WintunAdapters).Count
		$finalTunnelRoutes = @((Get-NetRoute -DestinationPrefix '0.0.0.0/1', '128.0.0.0/1' -ErrorAction SilentlyContinue)).Count
		$finalOpenvpn = @((Get-Process openvpn -ErrorAction SilentlyContinue)).Count
		Say ('final: exit ip={0} baseline={1} wintun={2} tunnel routes={3} extra routes={4} engines={5}' -f `
			$finalExit, $baselineExit, $finalAdapters, $finalTunnelRoutes, $extra, $finalOpenvpn)

		$exitChanged = ($liveIp -ne $null -and $liveIp -ne $baselineExit)
		$machineClean = ($finalExit -eq $baselineExit -and $finalAdapters -eq 0 -and
			$finalTunnelRoutes -eq 0 -and $finalOpenvpn -eq 0 -and $extra -eq 0 -and $restoredAll)
		if (-not $passed) { $code = 1 }
		elseif ($exitChanged -and $machineClean) {
			$code = 0
			Say ('RESULT: PASS - tunnel up (exit {0} -> {1}), tunnel address {2}, machine restored to baseline' -f `
				$baselineExit, $liveIp, $liveTunnelIp)
		} elseif ($exitChanged) {
			$code = 3
			Say 'RESULT: PARTIAL - tunnel and changed exit address observed, but teardown left differences (see above)'
		} else {
			$code = 3
			Say ('RESULT: PARTIAL - tunnel completed but the exit address never changed (live ip={0}, baseline={1})' -f $liveIp, $baselineExit)
		}
	} else {
		Say ('RESULT: FAIL - could not run (code {0})' -f $code)
	}
}
Write-Host "log: $logPath"
exit $code
