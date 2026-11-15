# Decisions

## 2026-11-15 Split tunneling: sing-box instead of own kernel driver
Windows refuses kernel drivers not signed by Microsoft (Secure Boot / no test-signing). User
chose bundling sing-box (GPL-3.0-or-later, compatible with Phantrix GPL-3) over buying
attestation signing, reusing Mullvad's driver, or a self-written packet relay.
sing-box TUN uses embedded Wintun (Microsoft-signed), so no own driver. Pinned v1.14.4,
zip sha256 99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df (matches GitHub digest).
Do not reintroduce an own kernel driver unless it is attestation-signed.
Per-app DNS impossible on Windows (dnscache multiplexes); DNS goes via tunnel.

## 2026-11-15 Kill switch semantics (user-approved)
automatic + strict, strict shows a warning. Filters are user-mode WFP (no driver), persistent so
they survive helper exit when they must. See PLAN.md step 3.

## 2026-11-15 Stop kills the engine after 250 ms
User wants disconnect/switch instant. OpenVPN's polite exit (explicit-exit-notify) took seconds. Killing is safe: wintun adapter, its routes and DNS vanish with the process. Do not raise the grace back.

## 2026-11-15 Split router: IPv6 only when both paths have it
sing-box tun always has an IPv6 address, so apps assumed IPv6 works. Without IPv6 on tunnel and physical, DNS is ipv4_only and IPv6 destinations are rejected before accept (pre-match), so browsers fall back to IPv4.

## 2026-11-15 Kill switch stays on with split tunneling
Earlier the helper disabled it while split was active. Reverted: direct-routed traffic leaves as sing-box.exe (permitted), so there is no conflict, and the user expects strict to block. Strict mode also engages immediately when chosen while disconnected (elevated `--engage-firewall`).
