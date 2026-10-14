# Windows OpenVPN connection failure — root cause

## What was established, and how

### Proven correct (direct testing, this PC)

| Layer | Evidence |
| --- | --- |
| Engine binary runs | `openvpn.exe --version` → 2.6.17, OpenSSL 3.6.0, LZO 2.10, DCO |
| Engine dependencies present | `openvpn.exe`, `libcrypto-3-x64.dll`, `libssl-3-x64.dll`, `libpkcs11-helper-1.dll`, `vcruntime140.dll`, `wintun.dll`, `phantrix_ovpn_helper.exe`, `phantrix_platform_plugin.dll` all in `build\windows\x64\runner\Release` |
| Profile is valid | The app's own serializer output for the top-ranked relay completed **full TLS**: `VERIFY OK: depth=0, CN=opengw.net`, `Control Channel: TLSv1.3 TLS_AES_256_GCM_SHA384`, `Peer Connection Initiated`, `PUSH_REQUEST` → `PUSH_REPLY` |
| Argument vector is correct | Reproduced the helper's exact argv (`--config … --windows-driver wintun [--dev-node …] --status … 1 --log …`) with the same working directory; the engine starts, negotiates, and reaches `open_tun` |
| Discovery works | 97 relays fetched and ranked from the live VPN Gate feed |
| Helper pipe protocol | Purpose-built harness drives the **real** helper over the **real** named pipe: token auth, start, deny-list, exit classification, teardown — all correct |
| Driver is installable | `wintun.sys` is in the driver store on this PC (`FileRepository\wintun.inf_amd64_8ed20477a29aa8f7`), so `DriverInstall` succeeded at least once here |

### The failure

```
2026-10-10 22:22:23 open_tun
2026-10-10 22:22:23 There are no TAP-Windows, Wintun or ovpn-dco adapters on this system.
2026-10-10 22:22:23 Exiting due to fatal error
```

The engine builds no tunnel, OpenVPN exits 1, and the app reports
`ovpn.engine_exited` (this PC) or `tunnel.timeout` (when the relay is also dead,
which hides the adapter failure behind a timeout).

### Why the adapter is invisible to OpenVPN

`src/openvpn/tun.c` (v2.6.17) decides which adapters exist in two steps:

1. `get_tap_reg()` enumerates every subkey of
   `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}`
   and keeps only those whose `ComponentId` value equals, case-insensitively,
   `tap0901` / `root\tap0901` / `wintun` / `ovpn-dco`. It reads
   `NetCfgInstanceId` from the same subkey.
2. `tun_open_device()` then calls `at_least_one_tap_win(tap_reg)`, which raises
   `M_FATAL: "There are no TAP-Windows, Wintun or ovpn-dco adapters on this
   system."` **before** the `--dev-node` name lookup happens.

The Wintun INF does not author `ComponentId`. The copy installed on this very
PC (`C:\Windows\INF\oem81.inf`, sha of contents shown in
`docs/evidence/openvpn/`) contains no `ComponentId` write at all:

```ini
[Wintun.Install]
Characteristics = 0x1 ; NCF_VIRTUAL
AddReg = Wintun.Ndi          ; writes Ndi\Service, Ndi\Interfaces\* to the HW key
AddProperty = Wintun.Properties
...
[Wintun.Ndi]
HKR, Ndi, Service, 0, wintun
HKR, Ndi\Interfaces, UpperRange, , "ndis5"
HKR, Ndi\Interfaces, LowerRange, , "nolower"
```

`HKR` in a `DDInstall` section is the device's **hardware** key, not the
network-class key OpenVPN reads. TAP-Windows gets its `ComponentId` the same way
it gets everything else — its INF explicitly writes
`HKR,,ComponentId,0x00010000,"tap0901"`. Wintun's INF has no equivalent line, so
a Wintun adapter created through the Wintun API carries no `ComponentId`, and
OpenVPN's adapter list is empty even though the adapter exists and the handshake
completed.

Registry confirmation on this PC (15 Net-class entries, none Wintun):

| Index | DriverDesc | ComponentId |
| --- | --- | --- |
| 0000 | Microsoft Kernel Debug Network Adapter | `root\kdnic` |
| 0001–0008 | WAN Miniport (…) | `ms_sstpminiport`, `ms_agilevpnminiport`, … |
| 0009 | Hyper-V Virtual Switch Extension Adapter | `vms_vsmp` |
| 0010 | Bluetooth Device (Personal Area Network) | `BTH\MS_BTHPAN` |
| 0011 | Intel Wi-Fi 6E AX211 | `PCI\VEN_8086&DEV_51F1&…` |
| 0012–0014 | Wi-Fi Direct Virtual / Remote NDIS / RNDIS | … |

No entry exists with `ComponentId == "wintun"`, and `Enum\SWD\WINTUN` is empty
because the adapter is created and removed inside one connection.

### Why this hits both Windows PCs and Android works

* It is a **shared software defect**: the same bundled `phantrix_ovpn_helper.exe`
  plus the same bundled `wintun.dll` produce the same undiscoverable adapter on
  every PC. Nothing machine-specific is required.
* Android is unaffected: ics-openvpn builds its `tun` through Android's
  `VpnService`, which needs no registry adapter and no `--dev-node` at all.

### Secondary finding: losing the real cause

`REPORT` (already partly fixed in commit c068380): OpenVPN appends
`Exiting due to fatal error` after **every** fatal, so the last captured error
line is the generic terminator, which is why the user's screenshot said only
"Exiting due to fatal error". The fallback that reports `recentLines_` must
survive; without it the fix below would be invisible.

---

## The bug that actually blocked a *verified* connection (2026-10-11, later)

The adapter-discovery defect above was fixed first. Once the tunnel came up and
handshaked, a second, independent bug kept the app from ever reporting
`Connected` — and it was in Phantrix's own verifier, not the engine or the relay.

### Symptom

A relay would reach `Initialization Sequence Completed` with `def1` routes
installed, but the verifier returned `leak.unverified`: *"The public address did
not change after connecting (203.0.113.5 both before and after)."* Every
relay behaved this way, which looked like "no VPN Gate relay forwards traffic."

### Root cause: pooled HTTP connections defeat the exit-address check

`LeakCheck` read the public address through one long-lived `http.Client`
(`AppHttpFetcher.owned`). That client keeps idle keep-alive TCP connections open
(~15s) and reuses them for the same host. The sequence:

1. The **baseline** read (before the tunnel) opens a socket over the real route,
   reads `203.0.113.5`, and the socket drops into the idle pool.
2. The tunnel launches (handshake takes seconds).
3. The **post-tunnel** reads hit the same host *inside* the pooling window and
   transparently **reuse that pre-tunnel socket**. The request rides the old
   connection and returns the pre-tunnel address no matter how healthy the
   tunnel is.

So the check always saw "unchanged" → always `leak.unverified`, on working
relays too. The re-read loop (`maxReads`/`readPause`) was also defeated: all
reads reused the first socket, so it could never observe routing settle.

The same artifact poisoned the external PowerShell sweeps
(`Invoke-RestMethod` pools via `ServicePoint`), which is why they also
reported "no relay forwards." The relays *were* forwarding; the measurement
was lying.

### Fix

`lib/vpn/leak_check.dart`: each read builds a **fresh** `http.Client` (via an
injected `fetcherFactory` in production), so every read opens a new socket that
follows whatever route is in force at that instant. Tests that inject a
`MockClient` are unaffected. Verified: `leak_check_test.dart` (30) plus
`connection_state_test.dart` + `connection_walk_test.dart` (31) all pass.

### Verified end state

Honest measurement (fresh-process `curl.exe` per read, which cannot pool) plus
the rebuilt app produced a stable, forwarding tunnel:

- `20:43:03` — `Initialization Sequence Completed`; adapter 44 `Phantrix` Up;
  `10.211.1.37`; `0.0.0.0/1` + `128.0.0.0/1` → `10.211.1.38`
- `20:43:09` — exit IP `203.0.113.5` → **`59.130.24.201`** (the relay's own
  address; changed, which is the criterion)
- Held connected through `20:49:35+` (6.5+ min) with the exit IP still
  `59.130.24.201`, confirmed independently by the watcher and by a direct
  `curl` read of `59.130.24.201` while the adapter was Up.

Capture: `docs/evidence/openvpn/live-capture-2026-10-11-honest.log`.
