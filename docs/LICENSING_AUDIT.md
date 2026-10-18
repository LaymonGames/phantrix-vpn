# Phantrix licensing audit

Last updated: 16 October 2026. This is an engineering compliance review, not
legal advice. It reviews this checkout and its public licence notices, not the
copyright ownership or private agreements of every contributor.

## Verdict

**Phantrix can be published under GPL-3.0-only.** The Android OpenVPN engine
(ics-openvpn, vendored as a Mysterium-repackaged AAR) was the only component
that could not be combined with GPL-3.0 code. It has been removed, together
with the bridge code that used its `de.blinkt.openvpn` classes, its local Maven
repository, and the licence files that described it.

Why it had to go: ics-openvpn's licence file says it is "distributed under the
GPL license version 2". The words "or any later version" appear only in a generic
boilerplate paragraph, the AAR's own embedded notice says GPL version 2, and
F-Droid lists GPL-2.0-only. GPL-2.0-only and GPL-3.0 cannot be combined in one
distributed work, and the upstream licence states that using any part of the
`de.blinkt.openvpn` class hierarchy creates a derivative work.

## Consequences

- **Android has no engine at all.** There is no OpenVPN engine on Android, and
  the WireGuard engine that briefly took its place was removed on 16 October
  2026 when the app became OpenVPN-only. The built-in VPN Gate list is
  OpenVPN-only, so those relays cannot be connected on Android; the app declines
  every one of them with an explanation instead of pretending otherwise.
  Windows keeps its OpenVPN backend.
- Do not re-add ics-openvpn, or any other GPL-2.0-only code, to a build that is
  distributed as GPL-3.0.
- `test/licenses_test.dart` asserts that no OpenVPN engine entry appears in the
  generated notices, so re-introducing the dependency fails the test suite
  rather than passing silently.

## LICENSE file check

`LICENSE` was compared against a reference copy of the GNU GPL v3 text on
13 October 2026. It is the standard text; the only differences are the
`https://` form of the FSF URLs, which is how the FSF publishes it today. It
should stay unedited. The project-specific copyright notice lives in
`COPYRIGHT`, not in `LICENSE`.

## Dependency / platform summary

| Area | Licence | Conclusion |
| --- | --- | --- |
| Phantrix original code | GPL-3.0-only | Publishable, provided every contributor's rights are in order (see below) |
| Flutter / Dart SDK and most Dart packages | BSD / MIT / Apache-2.0 | Compatible with GPL-3.0; keep upstream texts |
| `com.wireguard.android:tunnel` (removed 2026-10-16) | Apache-2.0 | Was compatible with GPL-3.0, but is no longer a dependency: the Android WireGuard backend was removed when the app became OpenVPN-only |
| wireguard-apple source snapshot (not a build target) | MIT | Keep its licence file; no Apple target is enabled |
| `openvpn_dart`-derived glue (Windows backend) | MIT (BlockDev AG) | Keep the original MIT copyright and licence text. The Android glue it also covered was removed with the Android OpenVPN engine. The Windows C++ sources carry no per-file attribution, so confirm the scope of the notice before release |
| Windows OpenVPN 2 binaries | GPL-2.0 | Separate process, never linked into the app — a mere aggregation, not a combined work. Ship its licence and offer its source |
| Windows wintun DLL | WireGuard LLC prebuilt-binaries licence | Ship unchanged and paired with the OpenVPN process that consumes its permitted API. OpenVPN, not Phantrix's Dart code, is the runtime consumer |
| Linux `wg-quick` / kernel WireGuard | GPL-2.0 | Separate processes, not linked, not bundled |
| WireGuard for Windows (`wireguard.exe`) | Not checked here | Never bundled, linked or run by this build. The Windows backend drives OpenVPN |

The Wintun redistribution exception depends on the DLL being shipped alongside
software that uses it only through the permitted API, so keep the two paired as
described. The Windows notice generator reads the actual `openvpn/LICENSE.txt`
from the fetched bundle when present, and `tools/fetch_openvpn_bundle.ps1` pins
and verifies the downloaded archive and every extracted file by SHA-256, so the
notice reflects the bytes that ship rather than a checked-in placeholder.

## Before you publish

1. Confirm you own, or may redistribute, `assets/icon.png` and the launcher
   icons derived from it.
2. Confirm every contributor agreed to the GPL-3.0-only licence.
3. Put the real copyright holder's name in `COPYRIGHT` (and regenerate the
   in-app notices) if you want more than "Laymon Games". Do not edit the
   `LICENSE` text itself.
4. If you ship Windows binaries, include `openvpn/LICENSE.txt` from the fetched
   bundle and provide, or point to, the matching OpenVPN source.
5. Check the final APK and Windows package contents, not only Git. The Windows
   bundle is fetched by script and is not committed, so check the files actually
   fetched for that release, and make sure the in-app notices screen and
   `THIRD_PARTY_LICENSES.md` match what is in the package you are publishing.

## References

- ics-openvpn `doc/LICENSE.txt` (the reason the Android engine was removed):
  https://github.com/schwabe/ics-openvpn/blob/master/doc/LICENSE.txt
- F-Droid OpenVPN for Android metadata: https://f-droid.org/en/packages/de.blinkt.openvpn/
- GNU GPL FAQ on version compatibility: https://www.gnu.org/licenses/gpl-faq.html#v2v3Compatibility
- Wintun prebuilt binaries licence: https://www.wintun.net/
