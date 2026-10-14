# Windows live verification (procedure B, repeatable on either PC)

Everything below runs **on the Windows machine that fails**. It is written so a
second PC produces the same report, and so the answers separate a shared
software defect from a machine-specific prerequisite.

There are two paths:

* **A — one interactive UAC click.** The complete end-to-end verification: the
  real app, the real helper, a real tunnel, a verified exit address.
* **B — no UAC, no app.** The native layers only: the bundled engine, a real
  Wintun adapter, and whether OpenVPN can reach it. This is what proves or
  disproves the root-cause fix without depending on the Flutter UI.
* **C — scripted end-to-end, one UAC consent.** The engine run exactly the way
  the helper runs it, with the adapter, tunnel address and exit address polled
  while the tunnel is up, and the machine restored and verified afterwards.
  See `tools/windows_live_tunnel.ps1`.

Run **B first** whenever the failure is "cannot connect at all", because B is
where the answer is and it takes under a minute.

---

## B — native layers, no elevation clicks

From an **Administrator** PowerShell prompt (required: Wintun creates the
adapter, which needs Administrator):

```powershell
$repo   = 'C:\Users\<you>\Documents\VPN'          # your Phantrix checkout
$bundle = Join-Path $repo 'build\windows\x64\runner\Release'
$probe  = Join-Path $probe  # phantrix_adapter_probe.exe, built by B below
```

### Build the tools (once)

The repository now ships the two diagnostic binaries as source. They build
against nothing but the Windows SDK:

```powershell
cmd /c "$env:TEMP\opencode\build_harness.bat"   # if you built them here
```

Or from a Visual Studio *Developer* command prompt:

```powershell
cl /std:c++17 /EHsc /W3 /DWIN32 /D_WINDOWS /SUBSYSTEM:CONSOLE ^
   /Fe:phantrix_helper_harness.exe ^
   "C:\Users\<you>\Documents\VPN\tools\windows\phantrix_helper_harness.cpp" ^
   advapi32.lib shell32.lib

cl /std:c++17 /EHsc /W3 /DWIN32 /D_WINDOWS /SUBSYSTEM:CONSOLE ^
   /Fe:phantrix_adapter_probe.exe ^
   "C:\Users\<you>\Documents\VPN\tools\windows\phantrix_adapter_probe.cpp" ^
   advapi32.lib shell32.lib iphlpapi.lib ole32.lib
```

### Run the adapter probe

```powershell
.\phantrix_adapter_probe.exe `
  "$bundle\wintun.dll" `
  "$bundle" `
  "$env:TEMP\opencode\vg-vpn768481862.ovpn" `
  --run
```

(Any valid `.ovpn` works; the profile only needs to be parseable. The last
argument `--run` is optional and additionally launches the bundled
`openvpn.exe` against the live relay.)

**What it prints, and what each line means**

| Output | Meaning |
| --- | --- |
| `adapter created` | `WintunCreateAdapter` succeeded — the driver is installed and usable |
| `NetCfgInstanceId = {…}` | the adapter's unique instance id, used to find its class subkey |
| `class subkey = …\{4D36E972-…}\NNNN` | Windows populated the Net-class entry |
| `ComponentId before: (absent)` | **the root cause**, if followed by the failure below |
| `ComponentId = wintun` entries | how many adapters OpenVPN's `get_tap_reg` can see |
| `openvpn.exe exit code = 0` and `Initialization Sequence Completed` | the engine opened the adapter and finished: the fix works on this PC |
| `restored ComponentId = …` / `removed the ComponentId this session added` | the machine is left exactly as found |
| `openvpn.exe exit code = 1` with `There are no TAP-Windows, Wintun or ovpn-dco adapters on this system` | the adapter was still not discoverable — report the `ComponentId before` value |

### Run the helper over the real pipe

```powershell
.\phantrix_helper_harness.exe `
  "$bundle\phantrix_ovpn_helper.exe" `
  "$env:TEMP\opencode\vg-vpn768481862.ovpn" `
  --expect-reject ovpn.credentials_missing
```

This drives the **real helper** over the **real named pipe**: launch it, wait for
the connection, echo the session token, send the start request with three paths
inside the session directory, and read every message until the teardown. It
needs no UAC because this helper build is compiled without the
`requireAdministrator` manifest; a profile that asks for credentials is refused
exactly as it should be.

To generate a profile from the live feed:

```powershell
dart run tools\diagnose_windows.dart
```

which prints the server id, country, endpoint, protocol, whether the profile
validated, and whether the Windows native side would accept it.

---

## C — scripted end-to-end with an exit-address check (one UAC consent)

`tools/windows_live_tunnel.ps1` runs the engine the way the helper runs it
(`openvpn.exe --config … --windows-driver wintun --dev-node Phantrix
--log …`) against each `.ovpn` given, polls the Wintun adapter, the tunnel
address and the exit address from two services every two seconds while the
tunnel is up, then stops the engine and reverses every leftover against a
baseline taken before the first attempt. From an **Administrator** prompt,
with profiles emitted as above:

```powershell
tools\windows_live_tunnel.ps1 -Profiles "$env:TEMP\opencode\vpn483423733.ovpn"
```

Exit 0 means: `Initialization Sequence Completed`, a changed exit address,
and the machine restored to its baseline — each also written to the log the
script names. Launched unelevated through `Start-Process -Verb RunAs`, the
single UAC consent is what starts it.

Two details that are the reason the script exists in this shape (both from
the 2026-10-13 runs, recorded in `docs/EVIDENCE.md`):

* The adapter probe with `--run` cannot back an exit-address claim: wintun
  removes an adapter when its creating handle closes, the probe creates the
  adapter, and the tunnel therefore collapses exactly when the probe
  returns — its `Initialization Sequence Completed` is still real evidence,
  but nothing can be sampled afterwards.
* `GenerateConsoleCtrlEvent(CTRL_C, 0)` after `AttachConsole` reaches the
  sending script as well as the engine (`0xC000013A`); the script
  force-stops the engine and relies on the baseline diff instead.

---

## A — one UAC click, the real app

```powershell
flutter build windows
cd build\windows\x64\runner\Release
.\phantrix.exe
```

1. Wait for the server list (Locations shows a country count).
2. Pick a location, press Connect.
3. Approve the UAC prompt for `phantrix_ovpn_helper.exe`.
4. Watch the status line: it must pass `Tunnel interface is up…` and reach
   connected **only after** the exit address changed.

**Evidence to capture**

```powershell
# The engine's own words for the attempt:
Get-Content "$env:LOCALAPPDATA\Phantrix\openvpn\session-*\openvpn.log" -Tail 40

# The adapter, while connected:
Get-NetAdapter | Where-Object InterfaceDescription -like '*Wintun*'

# The tunnel address, while connected:
(Get-NetIPAddress -InterfaceAlias 'Phantrix' -AddressFamily IPv4).IPAddress

# Exit address, while connected, from two independent services:
Invoke-RestMethod https://api.ipify.org
Invoke-RestMethod https://ifconfig.me/ip

# After Disconnect — must be empty (nothing left running):
Get-NetAdapter | Where-Object InterfaceDescription -like '*Wintun*'
Get-ChildItem "$env:LOCALAPPDATA\Phantrix\openvpn\session-*" -ErrorAction SilentlyContinue
```

A pass is: `Initialization Sequence Completed` in the log, a Wintun adapter
named `Phantrix` with the pushed `10.211.1.x` address while connected, an exit
address that differs from the pre-connection one, and both of the last checks
empty after Disconnect.

---

## What each result means for the second PC

| Result | Conclusion |
| --- | --- |
| B: `Initialization Sequence Completed` | The Windows backend works on this PC too. If the app still fails, the defect is above the native layer (profile handoff, capabilities, state machine) and is **shared** |
| B: `There are no TAP-Windows…` after registration | The registration is not sufficient on this PC; capture the `ComponentId before` value |
| B: `adapter could not be created (error 5)` | The shell was not Administrator — re-run elevated |
| B: engine exits before `open_tun`, no TLS | The relay is dead from this network; try another server (this is the walk case, not the engine) |
| A: `leak.unverified` | The tunnel came up but the exit address did not change — a routing or relay problem, not an adapter one |
