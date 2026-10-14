# Test-peer setup for a real WireGuard handshake

## Status

No reachable WireGuard peer exists in the development or CI environments, so
**no handshake has ever been observed on any platform**. Everything this
procedure verifies is currently open. Do not report a connection as working
until this procedure has been run end to end and each check below has a
recorded result.

This document states exactly what is needed, what to run, and what each step
proves — so that whoever has a machine and a network can close the gap in one
sitting, without inventing anything along the way.

## What you need

1. **A Linux host you control** to act as the server (a VPS, a second machine
   on the LAN, or a VM with bridged networking). It needs:
   - a kernel with WireGuard (any kernel ≥ 5.6, or the `wireguard-dkms`
     module on older ones),
   - `wireguard-tools` (`wg`, `wg-quick`),
   - UDP port 51820 reachable from the test device (firewall rule, security
     group, or same LAN),
   - a public IPv4 address, or an IPv6 address, that differs from the test
     device's own egress address — otherwise the before/after comparison in
     step 5 proves nothing.
2. **The test device**: an Android emulator or phone, a Windows machine with
   WireGuard for Windows and an Administrator prompt, or a Linux machine with
   `sudo`. One device per run; do not test two platforms against one peer at
   the same time, because the server log will then show two handshakes and
   you will not know which one you are looking at.
3. **Nothing in this repository needs to change.** The client configuration
   below is imported through the app's Configs screen, exactly as a user
   would do it. If any step requires a code change, stop: the procedure is
   wrong, not the code.

## Server setup (run once)

On the Linux host, as root. Replace `SERVER_PUBLIC_IP` with the host's real
address. Every secret below is generated fresh for the test and destroyed
afterwards — never reuse a production key for this.

```bash
# 1. Generate both keypairs. The private keys never leave their own machine.
umask 077
wg genkey | tee /etc/wireguard/test-server.key | wg pubkey > /etc/wireguard/test-server.pub
wg genkey | tee /tmp/test-client.key | wg pubkey > /tmp/test-client.pub
chmod 600 /etc/wireguard/test-server.key /tmp/test-client.key

SERVER_PRIV=$(cat /etc/wireguard/test-server.key)
CLIENT_PUB=$(cat /tmp/test-client.pub)

# 2. Write the server configuration. 10.44.0.0/24 is the tunnel subnet;
#    it must not collide with either endpoint's LAN.
cat > /etc/wireguard/vg-test.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.44.0.1/24
ListenPort = 51820

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.44.0.2/32
EOF
chmod 600 /etc/wireguard/vg-test.conf

# 3. Allow the port, then bring it up. The FORWARD/MASQUERADE rules are what
#    let the client reach the internet through the server; without them the
#    handshake succeeds and every packet after it dies, which looks exactly
#    like a client bug.
iptables -A INPUT -p udp --dport 51820 -j ACCEPT
iptables -A FORWARD -i vg-test -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.44.0.0/24 -o eth0 -j MASQUERADE
sysctl -w net.ipv4.ip_forward=1
wg-quick up vg-test
wg show vg-test
```

`wg show` must list the interface with no peers yet. If `wg-quick` fails
here, the problem is the server host, not the client — fix it before
touching the app.

Record the server's public egress address now; it is the expected value in
step 5:

```bash
curl -4 -s https://api.ipify.org; echo
```

## Client configuration (import into the app)

```ini
[Interface]
PrivateKey = <contents of /tmp/test-client.key>
Address = 10.44.0.2/32
DNS = 10.44.0.1

[Peer]
PublicKey = <contents of /etc/wireguard/test-server.pub>
Endpoint = SERVER_PUBLIC_IP:51820
AllowedIPs = 0.0.0.0/0
```

Notes that matter:

- `AllowedIPs = 0.0.0.0/0` is deliberate: this run tests the full-tunnel
  path, which is the only path the client will establish. A split-tunnel
  test is a different run with a different expectation.
- No IPv6 in this first run. IPv6 behaviour is step 7, with its own
  configuration, because mixing the two makes a failure uninterpretable.
- Transport the client key to the test device any way that does not store
  it anywhere else (QR code, USB file deleted afterwards, pasted over an
  encrypted channel). It is a test credential with the lifetime of this
  procedure.

## The run

### 1. Baseline (tunnel down)

On the test device, with the app installed but disconnected, record:

```bash
curl -4 -s https://api.ipify.org; echo        # the device's own egress
nslookup example.com                           # the device's normal resolver
```

Both values are the "before". If the egress already equals the server's
egress (the device is behind the same NAT as the server, or already on a
VPN), the comparison in step 5 is meaningless — move one of them.

### 2. Import

Paste the client configuration into the app's Configs screen. Expected: the
entry validates and appears with the server's address as its name. If it is
refused, the refusal names the field — record the code, fix the
configuration, and do not proceed until it imports cleanly.

### 3. Connect and confirm the handshake — on the server

Tap Connect in the app, then immediately, **on the server**:

```bash
wg show vg-test latest-handshakes
```

Expected: a timestamp within the last few seconds for the client's public
key. **This is the handshake evidence.** It is recorded on the peer, not
claimed by the client, which is what makes it evidence rather than a UI
string. If no handshake appears within 30 seconds, the run stops here: record
the app's reported state, the server log, and whether the app shows anything
other than connecting/failed. A client that shows "connected" with no server
handshake is a release-blocking bug — file it before continuing.

### 4. Confirm traffic exits through the server

On the test device, with the app showing connected:

```bash
curl -4 -s https://api.ipify.org; echo
```

Expected: the server's egress address from the setup step, not the baseline.
This is the step a byte counter cannot replace: counters prove the interface
moved packets, not where they went.

### 5. Compare before and after

| Reading | Before | After | Pass condition |
| --- | --- | --- | --- |
| Public IPv4 | device egress | server egress | different, and "after" equals the server's own address |

If "after" equals "before", the tunnel is up but traffic is bypassing it:
the run fails, even if the app says connected.

### 6. DNS

```bash
nslookup example.com
```

Expected: answered by 10.44.0.1 (or whatever the test DNS is observed to be
at the server — run `tcpdump -i vg-test port 53` on the server during the
lookup to confirm the query arrived through the tunnel). Then the leak check:
with the tunnel up, `tcpdump -i eth0 port 53` on the **client's LAN** (or the
emulator host) must show no DNS queries from the device. A query on the
physical interface while the tunnel claims to carry DNS is a leak; record it
as one.

### 7. IPv6

With the IPv4 run green, repeat with `Address = 10.44.0.2/32, fd44::2/128`
and `AllowedIPs = 0.0.0.0/0, ::/0` (server needs the matching `Address` and
`AllowedIPs` entries), and check `curl -6 https://api64.ipify.org`. Then set
the app's IPv6 policy to Block and confirm no IPv6 route exists on the device
while IPv4 still tunnels. Each of the three policies (block / tunnel / allow)
is a separate run with a separate expectation — do not change the policy
mid-run and call it coverage.

### 8. Failure and recovery

With the tunnel connected, in this order, recording the app's displayed state
at each point:

1. `wg-quick down vg-test` on the server (peer vanishes). Expected: the app
   leaves "connected" within its handshake-timeout window and shows a failure
   with a retry — never a silent return to "disconnected" with traffic
   flowing outside, unless system lockdown is armed (Android), in which case
   traffic must stop entirely.
2. `wg-quick up vg-test` again. Expected: reconnect, fresh server-side
   handshake, egress address correct again.
3. Disconnect from the app. Expected: the device's own egress returns, DNS
   returns to normal, and no interface, route, or configuration file from the
   run remains on the device.
4. Airplane-mode (or interface down/up) mid-connection on mobile. Expected:
   reconnect or honest failure — never a stuck "connecting" and never an
   unreported bypass.

### 9. Teardown

```bash
wg-quick down vg-test
rm /etc/wireguard/vg-test.conf /etc/wireguard/test-server.key /etc/wireguard/test-server.pub /tmp/test-client.key /tmp/test-client.pub
iptables -D INPUT -p udp --dport 51820 -j ACCEPT
iptables -D FORWARD -i vg-test -j ACCEPT
iptables -t nat -D POSTROUTING -s 10.44.0.0/24 -o eth0 -j MASQUERADE
```

Remove the configuration from the app (Configs → delete). Confirm the test
keys exist nowhere: not in the app, not on the server, not in a shell
history file on either machine (`HISTIGNORE` the key-handling commands, or
clear history afterwards — secrets in `~/.bash_history` are the most common
way a "temporary" test credential becomes permanent).

## Recording the result

For each run, record: date, client platform and OS version, app version, the
configuration used (redacted — public key and endpoint only, never the
private key), each step's observed outcome, and any deviation from the
expected values above. A step that was skipped is recorded as skipped, with
the reason — a skipped step is not a passed step.
