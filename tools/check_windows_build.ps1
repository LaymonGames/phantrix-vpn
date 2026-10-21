#!/usr/bin/env pwsh
#
# Inspects a built Windows bundle and asserts the properties this project
# depends on.
#
# ## Why this inspects the binary and not the source
#
# Every check here has been a real bug in this repository, and in each case the
# source looked fine:
#
#   * The backend once concatenated a shell command, so a configuration value
#     could have reached a command interpreter. Reading the source shows the
#     intent; reading the binary shows what shipped.
#   * The registrant export is what makes the plugin load at all. A rename
#     breaks it silently at run time and not at link time on every toolchain.
#
# A comment saying "do not do this" is not a check. This is the check.
#
# ## Usage
#
#     tools/check_windows_build.ps1 [-BundlePath <path>] [-RequireOpenVpn]
#
# Exits 0 when every check passes and 1 when any fails, listing all failures
# rather than stopping at the first — a run that reports one problem at a time
# turns a five-minute fix into five runs.

[CmdletBinding()]
param(
	[string]$BundlePath = 'build/windows/x64/runner/Release',
	[switch]$RequireOpenVpn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
	param(
		[string]$What,
		[bool]$Condition,
		[string]$Why
	)
	if ($Condition) {
		Write-Host "  ok    $What"
	} else {
		Write-Host "  FAIL  $What"
		Write-Host "        $Why"
		$script:failures.Add("$What - $Why")
	}
}

# Reads a file as both ASCII and UTF-16. The backend's literals are wide
# (`L"openvpn.exe"`), so an ASCII-only scan would miss exactly the strings
# most worth checking.
function Get-TextViews {
	param([string]$Path)
	$bytes = [System.IO.File]::ReadAllBytes($Path)
	return @(
		[System.Text.Encoding]::ASCII.GetString($bytes),
		[System.Text.Encoding]::Unicode.GetString($bytes)
	)
}

# The sections a compiler may place a string literal in, as both ASCII and
# UTF-16. The absence checks below use this instead of Get-TextViews,
# because a whole-file scan reads metadata as text too: in the build of
# 2026-10-13 the only `||` anywhere in phantrix_platform_plugin.dll was two
# low bytes of adjacent `.pdata` unwind-table RVAs — addresses, not a string
# — and "no command chaining" failed against a pattern no literal in the
# binary contained. Machine code, the function table and relocations hold no
# literals, so skipping them removes that class of false positive without
# loosening anything: a real command string lives in .rdata and is still
# seen. A file whose PE section table cannot be walked is scanned whole,
# because over-detection is the safe direction — it can fail a clean binary
# but never pass a dirty one.
function Get-StringChunks {
	param([string]$Path)
	$bytes = [System.IO.File]::ReadAllBytes($Path)
	$chunks = $null
	if ($bytes.Length -ge 0x40 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) {
		$peOff = [BitConverter]::ToInt32($bytes, 0x3C)
		if ($peOff -ge 0x40 -and $peOff + 24 -le $bytes.Length -and
			[BitConverter]::ToUInt32($bytes, $peOff) -eq 0x00004550) {
			$numSections = [BitConverter]::ToUInt16($bytes, $peOff + 6)
			$optSize = [BitConverter]::ToUInt16($bytes, $peOff + 20)
			$secStart = $peOff + 24 + $optSize
			$stringSections = @('.rdata', '.data', '.rsrc', '.idata', '.didat')
			$found = @()
			for ($i = 0; $i -lt $numSections; $i++) {
				$off = $secStart + 40 * $i
				if ($off + 40 -gt $bytes.Length) { break }
				$name = [System.Text.Encoding]::ASCII.GetString($bytes, $off, 8).Trim([char]0)
				if ($stringSections -notcontains $name) { continue }
				$rawPtr = [BitConverter]::ToUInt32($bytes, $off + 20)
				$rawSize = [BitConverter]::ToUInt32($bytes, $off + 16)
				if ($rawSize -eq 0 -or $rawPtr -gt $bytes.Length -or
					$rawPtr + $rawSize -gt $bytes.Length) { continue }
				$chunk = New-Object byte[] ([int]$rawSize)
				[Array]::Copy($bytes, [int]$rawPtr, $chunk, 0, [int]$rawSize)
				$found += ,$chunk
			}
			if ($found.Count -gt 0) { $chunks = $found }
		}
	}
	if ($null -eq $chunks) { return , $bytes }
	return $chunks
}

# True when the needle appears in bytes a string literal could be made of,
# in either encoding. Used only where the assertion is that something is
# ABSENT: a check that wants to find a string still reads every byte of the
# file, because finding it is the pass condition.
function Test-StringDataContains {
	param(
		[string]$Path,
		[string]$Needle
	)
	foreach ($chunk in (Get-StringChunks $Path)) {
		if ([System.Text.Encoding]::ASCII.GetString($chunk).Contains($Needle)) { return $true }
		if ([System.Text.Encoding]::Unicode.GetString($chunk).Contains($Needle)) { return $true }
	}
	return $false
}

if (-not (Test-Path -LiteralPath $BundlePath)) {
	Write-Error "No bundle at '$BundlePath'. Run 'flutter build windows --release' first."
	exit 1
}

$exe = Join-Path $BundlePath 'phantrix.exe'
$dll = Join-Path $BundlePath 'phantrix_platform_plugin.dll'
$engine = Join-Path $BundlePath 'flutter_windows.dll'

Write-Host "Inspecting $BundlePath"
Write-Host ''
Write-Host 'Files'

Assert-True 'the executable exists' (Test-Path -LiteralPath $exe) "expected $exe"
Assert-True 'the plugin library exists' (Test-Path -LiteralPath $dll) "expected $dll"
Assert-True 'the Flutter engine is present' (Test-Path -LiteralPath $engine) "expected $engine"
Assert-True 'the data directory is present' (Test-Path -LiteralPath (Join-Path $BundlePath 'data')) `
	'the app cannot start without data/'

if (-not (Test-Path -LiteralPath $dll)) {
	Write-Host ''
	Write-Host 'Cannot continue without the plugin library.'
	exit 1
}

Write-Host ''
Write-Host 'Plugin registration'

$views = Get-TextViews $dll
$all = $views -join "`n"

Assert-True 'the engine is linked in' `
	($all.Contains('flutter_windows.dll') -or (Test-Path -LiteralPath $engine)) `
	'the release executable must be launched with the engine beside it'

# This export has to survive linking for Flutter to register the plugin.
# Method-name literals do not: MSVC can implement a short string comparison
# with immediate integers, so absence of "capabilities" is not evidence of a
# missing handler. Bridge behavior is tested separately; this is a linkage
# smoke check, not a proof of the method-channel implementation.
Assert-True 'the plugin registration export is present' `
	$views[0].Contains('PhantrixPluginRegisterWithRegistrar') `
	'the generated Flutter registrant must be able to load the plugin'

Write-Host ''
Write-Host 'No command interpreter'

# The strongest single assertion in this file. `CreateProcessW` is how a
# process is started without a shell; `cmd.exe` or `powershell.exe` as a
# literal is how one is started with one. A backend that builds an argv array
# and calls CreateProcessW cannot be made to run a command by the contents of a
# configuration file.
foreach ($shell in @('cmd.exe', 'cmd /c', 'powershell.exe', 'powershell -', 'wscript', 'cscript')) {
	Assert-True "no reference to '$shell'" `
		(-not (Test-StringDataContains $dll $shell)) `
		'the backend must spawn processes with an argument array, never through a shell'
}

# Concatenation is the other half of shell injection. Present on its own it is
# harmless punctuation, but together with the checks above it is the signature
# of the bug this project once had.
foreach ($joiner in @('&&', '||', '2>&1', '| tee')) {
	Assert-True "no command chaining via '$joiner'" `
		(-not (Test-StringDataContains $dll $joiner)) `
		'argument arrays do not need shell metacharacters'
}

Write-Host ''
Write-Host 'The profile and the private directory'

Assert-True 'the per-user data directory is used' `
	$views[1].Contains('LOCALAPPDATA') `
	'a profile holds what the server sent and must not live beside the executable'

# The fail-closed message from the profile writer. Its presence proves the
# binary refuses to leave a profile behind when the restrictive DACL cannot
# be applied, rather than connecting anyway with unknown permissions. A
# future edit that deleted the hardening but kept the directory would still
# pass the check above and fail this one.
Assert-True 'an unsecurable profile is refused, not left behind' `
	($all.Contains('could not be secured')) `
	'the backend must delete a profile it cannot restrict'

Assert-True 'no private key is embedded in the binary' `
	(-not (Test-StringDataContains $dll 'BEGIN PRIVATE KEY')) `
	'a shipped private key would be a key for everybody who downloads the app'

Write-Host ''
Write-Host 'OpenVPN helper'

# The helper is a separate target, but the invariants that matter here are the
# same ones, and the check reads the same built binary.
#
# 1. It must ask for administrator rights, and it must ask in the binary rather
#    than in a comment. A manifest that lives only in the source tree is a
#    manifest that can be forgotten at link time, and the failure then looks like
#    a tunnel that simply will not start.
$helper = Join-Path $BundlePath 'phantrix_ovpn_helper.exe'
Assert-True 'the elevated helper is installed' (Test-Path -LiteralPath $helper) `
	"expected $helper"

# The helper's own copy of the "no interpreter" rule. The plugin launches the
# helper by path with a fixed argument list; if either ever shells out, the
# whole privilege story changes.
if (Test-Path -LiteralPath $helper) {
	$helperViews = Get-TextViews $helper
	$helperAll = $helperViews -join "`n"

	Assert-True 'the helper asks for administrator rights' `
		$helperViews[0].Contains('requireAdministrator') `
		'the engine creates a TUN adapter and installs routes; asInvoker would make that impossible'

	foreach ($argument in @('openvpn.exe', '--windows-driver wintun', '--config', '--status')) {
		Assert-True "the helper passes '$argument'" `
			$helperViews[1].Contains($argument) `
			'the engine must be started with this argument or it is not driven'
	}

	# The helper can pass --auth-user-pass with the path of its restricted
	# phantrix.auth file. That file contains only VPN Gate's public "vpn"/"vpn"
	# pair, not user credentials. A visible path is not a password disclosure.
	# External credential directives and prompts from the profile must still be
	# refused. This marker is a smoke check; the native support tests exercise
	# both rejection paths instead of inferring behavior from string presence.
	Assert-True 'a profile asking for credentials is refused, not passed through' `
		$helperViews[0].Contains('ovpn.credentials_missing') `
		'a server that needs credentials must be reported as one this build cannot use'

	# The profile arrives as a file, so nothing the server chose can end an
	# argument. This is the marker of that contract in the plugin binary.
	Assert-True 'the profile reaches the engine as a file, not as arguments' `
		$all.Contains('ovpnConfig') `
		'the serialized profile must be written to disk and referenced by path'

	# The engine must not be handed a signal that detaches it from the helper.
	# A daemonised openvpn.exe is not a child, cannot be sent a console control
	# event, and would outlive the app that asked for the tunnel.
	#
	# The needle is `--daemon`, not the bare word: `daemon` is in this binary
	# on purpose, as the key of the unsupported-directive table that REFUSES a
	# profile containing it ("detaches the engine, so the helper could no
	# longer monitor it"). Scanning for the word would fail the exact build
	# that does the refusing; what must be absent is the flag on a command
	# line, and that is the form openvpn.exe would be started with.
	Assert-True 'the helper does not daemonise the engine' `
		(-not (Test-StringDataContains $helper '--daemon')) `
		'a detached engine cannot be monitored, cannot be reaped, and would survive the app'

	# The helper is the elevated process, so the "no interpreter" rule applies to
	# it too, and more strongly: this is where a shell would be able to run the
	# configuration the app handed it.
	foreach ($shell in @('cmd.exe', 'cmd /c', 'powershell.exe', 'powershell -', 'wscript', 'cscript')) {
		Assert-True "the helper has no reference to '$shell'" `
			(-not (Test-StringDataContains $helper $shell)) `
			'the engine is started with an argument array, never through a shell'
	}

	# The Medium mandatory label on the pipe. Without it the DACL is the only
	# boundary, and a low-integrity process on the same session could inject
	# states into a running tunnel. The descriptor is built as a wide string in
	# the plugin's binary, so the wide view is the one that has to carry it.
	Assert-True 'the pipe carries a Medium integrity label' `
		($views[1].Contains('S:(ML;;NW;;;') -and $views[1].Contains('S-1-16-8192')) `
		'the descriptor must name Medium explicitly rather than relying on the default'
}

# The engine binaries must be there too: the plugin resolves them beside
# itself, accepting two layouts: an `openvpn\` subdirectory (the shape the
# engine is fetched in), and the flat copy next to the executable that
# `flutter build windows` actually produces (the generated-plugin rule
# installs bundled libraries flat). An earlier version of this check knew
# only the subdirectory and skipped the whole block whenever the build did
# not have one — which is how a build whose engine the plugin could not
# locate passed every check while claiming the engine was merely "not
# fetched".
$nestedEngineDir = Join-Path $BundlePath 'openvpn'
$nestedEngine = Join-Path $nestedEngineDir 'openvpn.exe'
$flatEngine = Join-Path $BundlePath 'openvpn.exe'
if (Test-Path -LiteralPath $nestedEngine) {
	$engineDir = $nestedEngineDir
	$engineExe = $nestedEngine
} elseif (Test-Path -LiteralPath $flatEngine) {
	$engineDir = $BundlePath
	$engineExe = $flatEngine
} else {
	$engineDir = $null
	$engineExe = $null
}
$engineWintun = if ($engineDir) { Join-Path $engineDir 'wintun.dll' } else { $null }

if ($engineExe) {
	Assert-True 'the OpenVPN engine is installed beside the plugin' `
		($true) `
		"engine at $engineExe"
	Assert-True 'the wintun driver is installed with the engine' `
		(Test-Path -LiteralPath $engineWintun) `
		"expected $engineWintun; the engine cannot create an adapter without it"

	# The engine is asked to print its version and say what it is.
	#
	# This is the only check in this file that runs something, and it is here
	# because the failure it catches is invisible in every other form: an
	# incomplete import closure makes `openvpn.exe` exit with 0xC0000135, write
	# no log and produce no output, which reads exactly like a server that is
	# not answering. The bundle's own pinned hashes cannot catch it either,
	# because the files that arrive are exactly the files that were asked for.
	# `--version` needs no adapter, no route, no administrator and no network.
	$versionOutput = & $engineExe --version 2>&1 | Out-String
	Assert-True 'the engine actually loads and runs' `
		($versionOutput -match 'OpenVPN 2\.') `
		('the engine did not print its version: ' + $versionOutput.Trim())
	Assert-True 'the engine reports the SSL library it was built with' `
		($versionOutput -match 'SSL \(OpenSSL\)') `
		'an engine built without SSL cannot make a control channel at all'
} else {
	if ($RequireOpenVpn) {
		Assert-True 'the required OpenVPN engine is installed beside the app' `
			$false `
			"no openvpn.exe reached $BundlePath; run tools/fetch_openvpn_bundle.ps1 before building"
	} else {
		# Distinguish "not fetched" from "fetched and never installed": if the
		# source tree holds the engine, something between the fetch and the
		# bundle dropped it, and the plugin would refuse every OpenVPN session.
		$sourceEngine = Join-Path $PSScriptRoot `
			'..\packages\phantrix_platform\windows\bundle\openvpn\openvpn.exe'
		Assert-True 'the fetched engine was installed beside the plugin' `
			(-not (Test-Path -LiteralPath $sourceEngine)) `
			"the engine is fetched at $sourceEngine but no openvpn.exe reached $BundlePath"
		Write-Host '  skip  the OpenVPN engine is not installed (run tools/fetch_openvpn_bundle.ps1)'
	}
}

Write-Host ''
if ($failures.Count -gt 0) {
	Write-Host "$($failures.Count) check(s) failed:" -ForegroundColor Red
	foreach ($failure in $failures) {
		Write-Host "  - $failure" -ForegroundColor Red
	}
	exit 1
}

Write-Host 'All checks passed.' -ForegroundColor Green
Write-Host ''
Write-Host 'These are binary-content smoke checks, not a proof of behavior.'
Write-Host 'They do not prove a tunnel can be created: that'
Write-Host 'needs an administrator token and a reachable server.'
Write-Host 'See docs/BUILDING.md.'
exit 0
