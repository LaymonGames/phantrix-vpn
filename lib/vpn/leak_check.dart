import 'dart:async';
import 'dart:convert';

import 'package:phantrix_core/phantrix_core.dart';

import '../net/app_http_fetcher.dart';
import '../l10n/strings.dart';

/// The result of a verification pass.
class VerificationOutcome {
  const VerificationOutcome({
    required this.verified,
    required this.message,
    this.publicIp,
    this.handshakeObserved = false,
    this.handshakeFresh = false,
    this.endpointHost,
  });

  /// True only when every check below passed.
  final bool verified;

  final String message;

  /// The address the exit node presented, when one could be read.
  final String? publicIp;

  /// True when the engine reported at least one completed handshake.
  final bool handshakeObserved;

  /// True when that handshake is recent enough to trust.
  final bool handshakeFresh;

  /// Which service answered, so the user can be told what was contacted.
  final String? endpointHost;
}

/// Decides whether a tunnel can honestly be called connected.
///
/// Three independent pieces of evidence are required, and the order matters
/// because each is cheaper and more definitive than the next:
///
///  1. **The engine reported a handshake.** The engine records the time of
///     the last completed handshake — for OpenVPN, the TLS handshake behind
///     "Initialization Sequence Completed". Without one the peer has never
///     answered and the interface is carrying nothing. This is reported by
///     the engine, not inferred by Phantrix.
///  2. **That handshake is recent.** A handshake older than a few minutes
///     means the peer has gone away even though the interface is still
///     nominally up — the exact case where a naive implementation keeps
///     claiming "connected".
///  3. **The observed public address changed.** The address seen before the
///     tunnel went up must differ from the address seen after. This is what
///     catches a tunnel that is up but not carrying the traffic.
///
/// ### What this does not prove
///
/// A successful check confirms a changed public address for the probed IP
/// family, alongside the engine's handshake. It does **not** mean:
///
///  * every application on the device is routed through it — per-app
///    exclusions, and apps that open their own sockets by other means, are
///    outside what this can see;
///  * DNS is not leaking — the check reads an HTTPS address, resolved by
///    whichever resolver is in force at that moment, so a hijacked resolver
///    would still have seen the lookup;
///  * the other IP family is protected — the default probes use IPv4;
///  * the content is private — the exit node operator can see it.
///
/// Those limits are stated in the UI rather than glossed over.
class LeakCheck {
  LeakCheck({
    AppHttpFetcher? fetcher,
    AppHttpFetcher Function()? fetcherFactory,
    Iterable<Uri>? endpoints,
    Future<void> Function(Duration delay)? wait,
  }) : _injectedFetcher = fetcher,
       _fetcherFactory =
           fetcherFactory ??
           (() => AppHttpFetcher.owned(
             timeout: const Duration(seconds: 4),
             maxBodyBytes: 4096,
           )),
       _endpoints = List.unmodifiable(endpoints ?? defaultEndpoints),
       _wait = wait ?? Future<void>.delayed;

  /// Hard upper bound for the best-effort pre-tunnel public-IP probe.
  ///
  /// The baseline is useful for detecting a changed exit address, but must
  /// never delay starting the tunnel while three public services each wait
  /// through their full network timeout. If it expires, verification uses the
  /// existing explicit baseline-unavailable path.
  static const Duration preflightTimeout = Duration(seconds: 3);

  /// How many times the exit address is read before the evidence is judged.
  ///
  /// The first read races the routing update: the engine reports the
  /// handshake the moment TLS completes, but the routes that carry traffic
  /// through the tunnel land just after. A live run read the pre-tunnel
  /// address in that window and refused a working tunnel — the same relay,
  /// attempted again seconds later, verified and carried traffic. Re-reading
  /// a few times turns "the address was unchanged once, possibly before the
  /// routes existed" into "the address was unchanged across several seconds
  /// of trying", which is the difference between a race and a real leak.
  /// A *changed* address is accepted on the first read and never retried:
  /// nothing that proves the tunnel works needs a second opinion.
  static const int maxReads = 4;

  /// The whole budget one read attempt may spend across every endpoint.
  ///
  /// A provider that is down tends to be *slow*, not just failing: without a
  /// cap, one unreachable first endpoint ate a full network timeout per
  /// attempt, four attempts in a row, and verification was judged long
  /// after the connect deadline — the exact delay the read loop exists to
  /// avoid. Two seconds is three times a healthy provider's answer.
  static const Duration readAttemptBudget = Duration(seconds: 2);

  /// Pause between those reads. Long enough for a routing update to land,
  /// short enough that the whole re-check fits inside the connect deadline
  /// with room to spare.
  ///
  /// Four readings spaced 1.5s apart still measure the address across more
  /// than four seconds, which is the "over several seconds" the verdict
  /// copy promises. The pauses were 2s until a live walk spent some of its
  /// earliest seconds inside them without buying certainty a shorter
  /// spacing loses: route installation is measured in hundreds of
  /// milliseconds, and the address services answer inside one.
  static const Duration readPause = Duration(milliseconds: 1500);

  final Future<void> Function(Duration delay) _wait;

  /// How recently a handshake must have happened to be trusted.
  ///
  /// Three minutes: OpenVPN rekeys on its own schedule and sends keepalives
  /// no more often than that, so this allows one missed exchange plus
  /// scheduling slack before a healthy tunnel is called stale. Verification
  /// runs immediately after OpenVPN's "Initialization Sequence Completed",
  /// so an OpenVPN timestamp older than this window means the engine is
  /// reporting a session established long ago — which is exactly the case
  /// that must not be reported as connected.
  static const Duration handshakeFreshness = Duration(minutes: 3);

  /// The services used to read the public address.
  ///
  /// Every one of them necessarily learns the address being checked. That is
  /// stated in the privacy screen and in the diagnostics copy rather than
  /// hidden: a check that claims to be invisible is not a useful check. The
  /// list is tried in order and the first success wins, so one provider being
  /// down does not make verification impossible.
  /// IPv4-only endpoints keep a change of address family from being mistaken
  /// for a change of route. IPv6 protection needs a separate check.
  ///
  /// `static final` rather than `const`, because `Uri.parse` is not a const
  /// function.
  static final List<Uri> defaultEndpoints = <Uri>[
    Uri.parse('https://api.ipify.org?format=json'),
    Uri.parse('https://checkip.amazonaws.com/'),
  ];

  /// An injected fetcher, used for every read as-is.
  ///
  /// Tests supply one so they can drive the check with a canned response.
  /// When it is null, reads go through [_fetcherFactory] instead, which is
  /// what production does.
  final AppHttpFetcher? _injectedFetcher;

  /// Builds a fetcher whose client has no pooled connections.
  ///
  /// See [_readFrom] for why production must not reuse a client here.
  final AppHttpFetcher Function() _fetcherFactory;
  final List<Uri> _endpoints;

  bool _closed = false;

  /// The public address right now, or null when nothing could be measured.
  ///
  /// Returns null rather than a guess: "could not measure" is not "no leak",
  /// and treating the two as the same is how a broken check silently passes.
  ///
  /// The endpoints are asked together rather than one after another. The
  /// baseline caps the wait at [preflightTimeout] regardless, so the old
  /// sequential walk could spend a full network timeout on a dead first
  /// provider and then refuse to start a tunnel over the seconds it had
  /// already spent — the check exists to *prove* the tunnel works, and the
  /// probe delaying the tunnel by its whole budget is the check making the
  /// problem it diagnoses more likely. Asked together, one healthy provider
  /// answers in a round trip, and the worst case still stops at the cap.
  Future<String?> currentIp({Duration timeout = preflightTimeout}) async {
    final readings = await _readAll(timeout);
    for (final address in readings) {
      if (address != null) {
        return address;
      }
    }
    return null;
  }

  /// Asks every endpoint at once and returns the readings in endpoint
  /// order, null where a provider answered nothing usable.
  ///
  /// `_readFrom` swallows its own errors, so the list completes when every
  /// ask has finished or [timeout] passes, whichever is first.
  Future<List<String?>> _readAll(Duration timeout) {
    return Future.wait(
      _endpoints.map((endpoint) async {
        try {
          return await _readFrom(endpoint).timeout(timeout);
        } on TimeoutException {
          return null;
        }
      }),
    ).timeout(
      timeout,
      onTimeout: () {
        // A provider that neither answered nor errored within the budget
        // reads as unavailable — the ask was made, but no answer arrived.
        return List.filled(_endpoints.length, null);
      },
    );
  }

  Future<String?> _readFrom(Uri endpoint) async {
    if (_closed) {
      return null;
    }
    // Each read uses a fetcher whose client is freshly built, never a
    // pooled one. The default `http.Client` (and every wrapper around it)
    // keeps idle keep-alive connections open for ~15s and reuses them for
    // the same host. A baseline read therefore opens a socket over the
    // *real* route, and the first post-tunnel read — landing well inside
    // that window — would transparently reuse it, reporting the pre-tunnel
    // address no matter how healthy the tunnel is. That single reused
    // socket is enough to make the check fail on a perfectly working relay,
    // and it also defeats the re-read loop below, because every retry would
    // ride the same stale connection and never observe routing settle.
    // Building a new client per read forces a new connection, so the read
    // always follows whatever route is in force at that instant.
    final fetcher = _injectedFetcher ?? _fetcherFactory();
    try {
      return extractAddress(await fetcher.get(endpoint));
    } catch (error) {
      // A single provider being unreachable is not a reason to declare
      // the tunnel leaky, so the next one is tried.
      return null;
    } finally {
      if (_injectedFetcher == null) {
        // The client built for this read is single-use; close it so its
        // connection cannot linger into the next read.
        fetcher.close();
      }
    }
  }

  /// Runs the full verification.
  ///
  /// [handshakeAt] is the engine's last-handshake time, or null when no
  /// handshake has happened. [baseline] is the address observed before the
  /// tunnel went up, or null when the pre-connection probe failed.
  ///
  /// [protocol] only changes what the check *calls* the evidence: a
  /// completed handshake reported by the engine with a fresh timestamp — the
  /// TLS handshake behind OpenVPN's "Initialization Sequence Completed" —
  /// plus a public address that differs from the baseline. There is
  /// deliberately no weaker path: an engine that cannot date its own
  /// handshake cannot be believed about the tunnel being up.
  Future<VerificationOutcome> verify({
    String? baseline,
    DateTime? handshakeAt,
    DateTime? now,
    ProtocolKind protocol = ProtocolKind.openVpn,
    L10n l10n = L10n.en,
  }) async {
    final at = now ?? DateTime.now();
    final observed = handshakeAt != null;
    final age = handshakeAt == null ? null : at.difference(handshakeAt);
    final fresh = age != null && !age.isNegative && age <= handshakeFreshness;

    if (!observed) {
      final article = protocol == ProtocolKind.openVpn ? 'an' : 'a';
      return VerificationOutcome(
        verified: false,
        message: l10n.get('flowHandshakeMissing', {
          'article': article,
          'protocol': protocol.label,
        }),
      );
    }
    if (age!.isNegative) {
      return VerificationOutcome(
        verified: false,
        handshakeObserved: true,
        message: l10n.get('flowHandshakeFuture'),
      );
    }
    if (!fresh) {
      return VerificationOutcome(
        verified: false,
        handshakeObserved: true,
        message: l10n.get('flowHandshakeStale', {
          'minutes': '${age.inMinutes}',
        }),
      );
    }

    // The read loop. A changed address wins immediately; an unchanged one
    // or an unreachable service is retried until [maxReads] (see the
    // constant for why), and the last reading is what the judgement below
    // is based on. Baseline-less runs stop at the first reading that
    // exists, because there is nothing to compare against and waiting
    // buys no evidence.
    String? host;
    String? current;
    for (var attempt = 0; attempt < maxReads; attempt++) {
      if (attempt > 0) {
        await _wait(readPause);
        if (_closed) {
          return VerificationOutcome(
            verified: false,
            handshakeObserved: true,
            handshakeFresh: true,
            message: l10n.get('flowVerifyCancelled'),
          );
        }
      }
      String? readingHost;
      String? reading;
      final watch = Stopwatch()..start();
      for (final endpoint in _endpoints) {
        // Failover stays sequential because the endpoints are ordered
        // evidence — the first one that answers is the confirmation — but a
        // dead provider no longer gets a whole network timeout to itself:
        // each attempt carries a budget, and a provider that has not
        // answered inside it is left behind for the pause-and-retry loop,
        // which is the retried thing here by design.
        final remaining = readAttemptBudget - watch.elapsed;
        if (remaining <= Duration.zero) {
          break;
        }
        String? address;
        try {
          address = await _readFrom(endpoint).timeout(remaining);
        } on TimeoutException {
          address = null;
        }
        if (address != null) {
          readingHost = endpoint.host;
          reading = address;
          break;
        }
      }
      host = readingHost;
      current = reading;
      if (current == null) {
        // Nothing read: retry, because an unreachable service is not
        // evidence of anything.
        continue;
      }
      if (baseline == null ||
          (_sameFamily(baseline, current) && !sameAddress(baseline, current))) {
        // Either changed (the tunnel works — no reason to keep
        // probing) or no baseline to compare against (the first
        // reading is all the evidence there will be).
        break;
      }
    }

    if (current == null) {
      return VerificationOutcome(
        verified: false,
        handshakeObserved: true,
        handshakeFresh: true,
        message: l10n.get('flowVerifyUnreachable'),
      );
    }

    if (baseline == null) {
      // A handshake proves contact with the VPN server, not that ordinary
      // traffic took its route. Missing evidence must not become success.
      return VerificationOutcome(
        verified: false,
        publicIp: current,
        handshakeObserved: true,
        handshakeFresh: true,
        endpointHost: host,
        message: l10n.get('flowBaselineUnavailable'),
      );
    }

    if (!_sameFamily(baseline, current)) {
      return VerificationOutcome(
        verified: false,
        publicIp: current,
        handshakeObserved: true,
        handshakeFresh: true,
        endpointHost: host,
        message: l10n.get('flowAddressFamilyChanged'),
      );
    }

    if (sameAddress(baseline, current)) {
      return VerificationOutcome(
        verified: false,
        publicIp: current,
        handshakeObserved: true,
        handshakeFresh: true,
        endpointHost: host,
        message: l10n.get('flowExitUnchanged', {'ip': current}),
      );
    }

    return VerificationOutcome(
      verified: true,
      publicIp: current,
      handshakeObserved: true,
      handshakeFresh: true,
      endpointHost: host,
      message: l10n.get('flowConnectedVia', {'ip': current}),
    );
  }

  /// Pulls an address out of an echo response.
  ///
  /// Tolerant of the two shapes these services use — a JSON object and a bare
  /// line of text — but strict about the value itself. Anything that is not a
  /// plausible IPv4 or IPv6 address is rejected, because a garbage or
  /// captive-portal response that happens to differ from the baseline would
  /// otherwise read as "the address changed" and wrongly pass the check.
  static String? extractAddress(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final candidate = _fromJson(trimmed) ?? _firstLine(trimmed);
    if (candidate == null) {
      return null;
    }
    return isPlausibleAddress(candidate) ? candidate : null;
  }

  static String? _fromJson(String body) {
    if (!body.startsWith('{')) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      for (final key in const <String>['ip', 'ip_addr', 'query', 'address']) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// The first line only: a stray banner or footer must not be mistaken for
  /// the address.
  static String? _firstLine(String body) {
    final line = body.split('\n').first.trim();
    return line.isEmpty ? null : line;
  }

  /// Rejects anything that cannot be an address.
  static bool isPlausibleAddress(String value) =>
      AddressCidr.isIpv4(value) || AddressCidr.isIpv6(value);

  /// Compares address bytes, including compressed and IPv4-mapped IPv6.
  static bool sameAddress(String a, String b) {
    final left = _addressBytes(a);
    final right = _addressBytes(b);
    if (left == null || right == null || left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _sameFamily(String a, String b) {
    final left = _addressBytes(a);
    final right = _addressBytes(b);
    return left != null && right != null && left.length == right.length;
  }

  static List<int>? _addressBytes(String value) {
    if (AddressCidr.isIpv4(value)) {
      return Uri.parseIPv4Address(value);
    }
    if (!AddressCidr.isIpv6(value)) {
      return null;
    }
    final bytes = Uri.parseIPv6Address(value);
    if (bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return bytes.sublist(12);
    }
    return bytes;
  }

  Future<void> close() {
    _closed = true;
    // Only an injected fetcher is owned long-term enough to need closing
    // here. Production fetchers are built per read and already closed
    // there.
    _injectedFetcher?.close();
    return Future<void>.value();
  }
}
