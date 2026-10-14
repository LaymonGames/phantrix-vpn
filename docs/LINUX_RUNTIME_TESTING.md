# Linux runtime verification

The Linux backend builds in CI, but a **compile is not a running
tunnel**. This document is the exact procedure to exercise the real
packet path, and it is deliberately written so it can be run without
committing a credential anywhere.

## What has been verified, and what has not

| | State |
| --- | --- |
| Plugin C++ compiles and links | **Verified in CI** (`.github/workflows/linux.yml`) |
| Plugin registers with Flutter | **Verified in CI** — the generated registrant calls `phantrix_plugin_register_with_registrar`, and the built `libphantrix_platform_plugin.so` exports it |
| Privileged commands use an argument vector, not a shell | **Verified in CI** — the workflow fails if `std::system` reappears |
| `wg` / `wg-quick` detection and kernel-support probing | Implemented; not executed against a live system here |
| Tunnel brought up, handshake completed | **Not verified** — needs a reachable peer and an authorised host |
| DNS, IPv4/IPv6 routing and leak behaviour | **Not verified** |

## Why CI does not run the tunnel

`wg-quick up` needs `CAP_NET_ADMIN`. A CI runner does not have it, and
a runner that *could* obtain it would be a privileged machine that
every pull request could use to alter the host's networking. That is
the opposite of least privilege, so no CI job here ever runs `pkexec`,
`wg-quick`, writes to `/etc/wireguard`, or changes a route.

Runtime verification belongs on a machine the operator controls. The
procedure below is that procedure.

## Prerequisites

```bash
sudo apt install wireguard-tools   # provides wg and wg-quick
sudo modprobe wireguard            # or use a kernel >= 5.6 with it built in
grep -qw wireguard /proc/crypto && echo "kernel support present"
polkit --version                   # pkexec comes from policykit-1
```

If `grep -qw wireguard /proc/crypto` finds nothing and
`/sys/module/wireguard/` does not exist, the backend will report
`backend.no_kernel_support` and refuse to start. That is correct
behaviour, not a defect: it is the backend saying the kernel cannot
do what is being asked.

## Supplying a peer without committing a secret

The app reads its configuration from the server directory, which is
populated by discovery. To connect to a peer of your own:

1. Put the configuration in an environment variable, never in a file
   that is committed and never in a shell history:

   ```bash
   read -rs PHANTRIX_TEST_CONFIG && export PHANTRIX_TEST_CONFIG
   # paste a wg-quick(5) config, then Ctrl-D
   ```

2. Write it where the app expects it, with permissions that keep it
   private. The Linux backend stages the config itself and installs
   it as `root:root 0600`, so the file on disk is only the last step:

   ```bash
   sudo install -m 600 <(printf '%s\n' "$PHANTRIX_TEST_CONFIG") \
       /etc/wireguard/phantrix0.conf
   unset PHANTRIX_TEST_CONFIG
   ```

3. Start the tunnel by hand **first**, to prove the peer works before
   blaming the app for a failure the peer caused:

   ```bash
   sudo wg-quick up phantrix0
   sudo wg show phantrix0          # look for 'latest handshake'
   curl -s https://api.ipify.org  # the address should now be the peer's
   sudo wg-quick down phantrix0
   sudo rm /etc/wireguard/phantrix0.conf
   ```

   If `wg show` reports no handshake, the problem is the peer or the
   path to it, and the app is not the thing to debug.

## Then exercise the app

```bash
flutter run -d linux
```

Connect, and check each claim separately — a tunnel that passes one
can fail the next:

| Claim | How to observe it |
| --- | --- |
| Interface is up | `ip addr show phantrix0` |
| A handshake completed | `sudo wg show phantrix0` → `latest handshake` |
| The exit address changed | `curl -s https://api.ipify.org` differs from the pre-connect value |
| IPv4 is tunnelled | `ip route get 1.1.1.1` → dev `phantrix0` |
| IPv6 follows policy | `ip -6 route get 2606:4700:4700::1111` → `phantrix0` when allowed, or `unreachable` when blocked |
| DNS is the tunnel's | `resolvectl status phantrix0` (systemd-resolved) |
| Disconnect restores the original | `ip route` and `resolvectl status` match their pre-connect state |
| Failure is honest | Point the app at 192.0.2.1 (RFC 5737, unroutable) and confirm it reports `tunnel.failed`, never `connected` |

## The companion instrumentation

The Android on-device suite
(`packages/phantrix_platform/android/src/androidTest/.../WireGuardEngineRuntimeTest.kt`)
proves the three parts that are platform-independent and that a
black-holed peer confirms: the engine loads, a mapped configuration
satisfies the engine's own validator, and an unreachable endpoint
raises the interface while reporting **no handshake**. The last one is
the assertion that stops a configured-looking tunnel from being
reported as connected, and it holds on Linux for the same reason:
`wg-quick up` succeeding is not a handshake.
