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
- **No DNS history in the app.** Phantrix does not record DNS queries.
	Resolver routing and DNS leak protection have not been verified; this is
	not a promise that DNS always travels through the tunnel.
- **No keys or credentials of yours.** The app has no account, no sign-in and
	never asks for a secret. The OpenVPN profiles it downloads from the public
	relay list carry the relay's own shared certificate, not anything of
	yours; they are cached locally (see §2) and are public information.
- **No advertising identifiers.** The app requests none.

## 2. What is stored, and where

Everything below is **local to your device**. There is no server-side
copy of any of it, because there is no server side.

| Data | What it is | Where it lives |
| --- | --- | --- |
| Settings (`AppSettings`, `settings/app_settings.dart`) | Kill-switch mode, DNS mode, IPv6 mode, favourites, theme, language (`en`/`ar`), onboarding flags | App-private local storage. Defaults: kill switch `automatic`, IPv6 `block`, diagnostics opt-in **false** |
| Cached server lists (`DirectoryCache`, `discovery/`) | Public server metadata from the last successful provider response, so the list can still render when the feed is unreachable | App-private local storage; versioned metadata cache |
| Recent connections (`recentServers`, `favoriteServers`) | Server ids, most-recent-first, local only | Settings storage |
| VPN Gate profile cache (`vpn-gate-profiles-cache.json`) | Base64 OpenVPN profiles published by VPN Gate, including any public shared client keys in those profiles | Separate, bounded file in app-private storage; profiles are untrusted and are parsed and security-validated again before every tunnel use. Base64 is not encryption |
| Connection log (`Logger`, `logging/logger.dart`) | A bounded ring buffer of what the app did, for the in-app viewer | Memory only (512 records); every line passes through `Redactor` |
| Windows OpenVPN logs | Raw engine diagnostics, which can include addresses, names, and connection metadata | Up to three archives, each holding 512 KiB of engine output plus a possible trim marker, beneath `%LOCALAPPDATA%\Phantrix\logs\`; not passed through the Dart redactor and not cleared by the in-app log action |
| Diagnostics results (`diagnostics/`) | The outcome of checks you ran on demand, including the public IP an external service saw | Memory, shown in the app; stored only if the host persists it (it does not today) |

`Redactor` runs over structured application log lines before display:
PEM blocks, credential assignments, full URLs
(collapsed to `scheme://host/…`) and IPv6 addresses (truncated to /48) are
removed. Tests assert the secret's *absence*, not just a marker's presence.
This filter does not cover raw native log archives and is not proof that all
possible metadata is removed. Review logs before sharing them.

## 3. The one unavoidable disclosure — the leak check

To compare the route before and after connection, the app asks external HTTPS
services what public IP they see. Each contacted service learns that address:
the normal-network address before the tunnel, and whatever route the request
actually takes afterwards. A successful tunnel should show the exit address,
but the check cannot assume that in advance.

- Defaults are `https://api.ipify.org?format=json` and
	`https://checkip.amazonaws.com/`, contacted in parallel. Tests and
	embedding code can inject another endpoint list.
- The pre-tunnel baseline waits up to three seconds. Post-handshake
	verification can make up to four rounds, with 1.5-second pauses when an
	address is unchanged or unavailable. Reconnects can run verification again.
	These are connection/diagnostic checks, not analytics uploads.
- Default probes measure IPv4, not DNS or IPv6 leak protection. HTTPS hides
	request content in transit, but the provider still sees the source address
	and ordinary connection metadata.

The app treats a failed probe as **no evidence, not as safety**: without a
changed address and a recent engine handshake the tunnel is never reported
as connected. That is the same principle stated the other way round — "could
not measure" is not "no leak".

## 4. Optional, opt-in diagnostics

`diagnosticsOptIn` defaults to **false**. When (and only when) you turn it
on, the intent is defined as: **minimal and anonymous** — error category
and machine-stable error codes (for example `permission.denied`), OS
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

## 6. Deleting your local data

All of it is on your device, and you can remove it:

- **Clear history / recent servers:** the settings holder has a
	clear-local-data action (`SettingsController.clearLocalData` in
	`lib/settings/settings_controller.dart`) that resets settings to
	defaults; `AppSettings.clearedHistoryAt` records when you last
	cleared history.
- **Clear the application connection log:** the `Logger` ring buffer is memory-only;
	it dies with the process (`Logger.clear()` empties it for the in-app
	viewer).
- **Windows native files:** the in-app clear action does not delete archived
	OpenVPN logs. After stopping the tunnel and closing the app, you can remove
	the app-owned `%LOCALAPPDATA%\Phantrix` directory to remove its local files.
	A portable app or an uninstaller may leave that directory behind.
- **Uninstall on Android:** removes the app sandbox (settings and caches).
	Do not assume the same cleanup behavior on desktop. A crash may also leave
	temporary native session files. Phantrix has no account or server-side
	database to delete; third-party relay/echo operators have their own policies.

## 7. Changes to this policy

This document describes the code in this repository as it is. If a future
release adds anything that transmits data off the device, this file will
be updated in the same commit, and the release notes will say so. A
change that quietly adds collection would violate the project's one
rule — never claim untested functionality — in the direction that
matters most.
