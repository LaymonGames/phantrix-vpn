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
