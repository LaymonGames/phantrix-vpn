# Privacy

Phantrix is free-first and account-free. This policy describes what the
app does **not** do with your data, what stays on your device, and how to
delete it. It describes the code in this repository; where something is
not yet implemented, it says so.

## 1. What Phantrix does not collect

- **No account.** There is no registration, login, profile or user ID.
	Nothing in the app can associate you with a device across sessions.
- **No analytics and no telemetry by default.** There is no analytics
	SDK, no crash reporter, no usage ping in `pubspec.yaml` of either
	package. `AppSettings.diagnosticsOptIn` defaults to **false**.
- **No browsing history.** The app never sees which sites you visit: it
	moves packets; it does not proxy, inspect or log them.
- **No DNS history.** DNS queries travel through the tunnel to the
	resolver you selected (`DnsMode.vpn` is the default). Nothing is
	recorded.
- **No keys or credentials uploaded.** Imported configurations stay on your
	device and are never transmitted anywhere except to the platform tunnel
	at connect time. They **are** written to local storage — see §2 — in
	plain text, protected only by file permissions. The previous claim that
	keys are never stored dated from before configuration import existed;
	keeping it would be the worst kind of privacy statement, one that was
	true once and is not true now.
- **No advertising identifiers.** The app requests none.

## 2. What is stored, and where

Everything below is **local to your device**. There is no server-side
copy of any of it, because there is no server side.

| Data | What it is | Where it lives |
| --- | --- | --- |
| Settings (`AppSettings`, `settings/app_settings.dart`) | Kill-switch mode, DNS mode, IPv6 mode, auto-connect policy, favourites, theme, language (`en`/`ar`), onboarding flags | App-private local storage. Defaults: kill switch `automatic`, IPv6 `block`, diagnostics opt-in **false** |
| Cached server lists (`DirectoryCache`, `discovery/`) | Public server metadata from the last successful provider response, so the list can still render when the feed is unreachable | App-private local storage; versioned metadata cache |
| Imported configurations (`ConfigurationRepository`, `lib/config/`) | The WireGuard text you pasted, **including its private key, in plain text**, plus its label. At most 64 KiB per import, names truncated to 120 characters, at most 64 stored | App-private local storage (`filesDir` on Android, `%LOCALAPPDATA%\Phantrix` on Windows, `$XDG_CONFIG_HOME/phantrix` on Linux); file `0600` / directory `0700` on POSIX, explicit user+SYSTEM DACL on Windows. Never uploaded. See SECURITY.md §4.0 for exactly what that does and does not protect |
| Recent connections (`recentServers`, `favoriteServers`) | Server ids, most-recent-first, local only | Settings storage |
| VPN Gate profile cache (`vpn-gate-profiles-cache.json`) | Base64 OpenVPN profile payloads published by VPN Gate, so previously listed relays can still be attempted during a feed outage | Separate, bounded file in app-private storage; profiles are untrusted and are parsed and security-validated again before every tunnel use. User-imported configurations are not written here; the file is not encrypted by Phantrix itself |
| Connection log (`Logger`, `logging/logger.dart`) | A bounded ring buffer of what the app did, for the in-app viewer | Memory only (512 records); every line passes through `Redactor` |
| Diagnostics results (`diagnostics/`) | The outcome of checks you ran on demand, including the public IP an external service saw | Memory, shown in the app; stored only if the host persists it (it does not today) |

`Redactor` runs over every log line before it is kept or displayed:
WireGuard keys, PEM blocks, credential assignments, full URLs
(collapsed to `scheme://host/…`) and IPv6 addresses (truncated to /48) are
removed. A log line is never a way for a key to escape — and because that
claim once failed silently (see SECURITY.md §6, "The redactor once leaked"),
the tests assert the secret's *absence*, not just the marker's presence.

## 3. The one unavoidable disclosure — the leak check (design, not yet live)

To answer "is my tunnel actually working?", the app must ask an external
service what IP address it sees, and compare it to the address seen
before connecting. That single request necessarily reveals your current
public IP address (which, while connected, is the VPN server's address —
not yours) to that one service. That is the only unavoidable disclosure
in a leak check, and it is the only one the design permits.

- The intended endpoint is a well-known echo service (the design sketch
	uses `https://api.ipify.org`) and is **configurable** so you can point
	it at a service you trust.
- It is one request, with no path and no query string, made when you
	connect and when you ask the diagnostics screen to run it — never in
	the background, never on a timer.
- The diagnostics model says so in its own field documentation: "This is
	the only honest way to check whether an IP is exposed, and it does leak
	the IP to that one service, which the UI states."

Honest status: `LeakCheck.currentIp()` in
`lib/vpn/connection_controller.dart` is currently a stub that returns
`null` — deliberately, on the principle that "could not measure" is not
"no leak". Until the probe is implemented the leak check cannot pass, so
the app cannot claim a verified tunnel. The endpoint, the configurability
and the disclosure wording above describe the design that the
implementation must meet; no request is made by the code today.

## 4. Optional, opt-in diagnostics

`diagnosticsOptIn` defaults to **false**. When (and only when) you turn it
on, the intent is defined as: **minimal and anonymous** — error category
and machine-stable error codes (for example `wg.handshake_timeout`), OS
and app version, and never personal data, keys, URLs with paths, IP
addresses or server identifiers that could single you out. Anything
collected is aggregated to answer "does the app work for people", not
"who are you".

Honest status: the *setting* exists in `AppSettings`; no submission
pipeline is implemented in this repository yet, so today opting in
changes nothing that leaves your device. When one is added it must satisfy
the constraints in this paragraph and the redaction rules in
`SECURITY.md`, or the setting will not be wired to it.

## 5. Free public servers mean unknown operators

The VPN Gate relay list is run by volunteers Phantrix has no relationship
with. Connecting to one means its operator — an unknown third party —
can observe every request that exits through their server: the sites you
visit, your login traffic at those sites, and anything unencrypted. The
app labels every such server `publicRelay` ("Operated by an unknown
volunteer. They can see your traffic.") and shows the operator's own
stated logging policy alongside the server. A free, account-free client
that lists volunteer relays cannot also promise you confidentiality from
those volunteers; the only honest thing to do is say so, everywhere, and
make trust labels impossible to miss.

Imported configurations are the same story with the extra step that you
chose the file: "You supplied this configuration. Nothing about it has
been verified."

## 6. Deleting your local data

All of it is on your device, and you can remove it:

- **Clear history / recent servers:** the settings holder has a
	clear-local-data action (`SettingsController.clearLocalData` in
	`lib/settings/settings_controller.dart`) that resets settings to
	defaults; `AppSettings.clearedHistoryAt` records when you last
	cleared history.
- **Remove imports:** delete a configuration in the import list
	(`ConfigurationRepository.remove`) — the text, the label and the derived
	fingerprint leave device storage. Removal rolls back if the write fails,
	so the list never shows an entry the disk still holds.
- **Clear the connection log:** the `Logger` ring buffer is memory-only;
	it dies with the process (`Logger.clear()` empties it for the in-app
	viewer).
- **Nuclear option:** uninstalling the app removes its entire private
	storage directory (settings, cached lists, imports). Verified on Android
	14 by uninstalling and confirming the package directory is gone, not
	merely inaccessible. Expected on the other platforms by OS convention
	but not verified there. There is nothing on any server to delete, and no
	account to close, because no account ever existed.

## 7. Changes to this policy

This document describes the code in this repository as it is. If a future
release adds anything that transmits data off the device, this file will
be updated in the same commit, and the release notes will say so. A
change that quietly adds collection would violate the project's one
rule — never claim untested functionality — in the direction that
matters most.
