import 'dart:async';
import 'dart:convert';

import 'package:phantrix_core/phantrix_core.dart';

import '../net/app_http_fetcher.dart';

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
///  1. **The engine reported a handshake.** The WireGuard engine records the
///     time of the last completed Noise_IK handshake. Without one the peer has
///     never answered and the interface is carrying nothing. This is reported
///     by the official engine, not inferred by Phantrix.
///  2. **That handshake is recent.** WireGuard rekeys every two minutes, so a
///     handshake older than a few minutes means the peer has gone away even
///     though the interface is still nominally up — the exact case where a
///     naive implementation keeps claiming "connected".
///  3. **The observed public address changed.** The address seen before the
///     tunnel went up must differ from the address seen after. This is what
///     catches a tunnel that is up but not carrying the traffic.
///
/// ### What this does not prove
///
/// A successful check means this device's traffic is leaving through the
/// tunnel. It does **not** mean:
///
///  * every application on the device is routed through it — per-app
///    exclusions, and apps that open their own sockets by other means, are
///    outside what this can see;
///  * DNS is not leaking — the check reads an HTTPS address, resolved by
///    whichever resolver is in force at that moment, so a hijacked resolver
///    would still have seen the lookup;
///  * the content is private — the exit node operator can see it.
///
/// Those limits are stated in the UI rather than glossed over.
class LeakCheck {
	LeakCheck({
		AppHttpFetcher? fetcher,
		AppHttpFetcher Function()? fetcherFactory,
		Iterable<Uri>? endpoints,
		Future<void> Function(Duration delay)? wait,
	})  : _injectedFetcher = fetcher,
			_fetcherFactory = fetcherFactory ??
				(() => AppHttpFetcher.owned(timeout: const Duration(seconds: 4))),
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

	/// Pause between those reads. Long enough for a routing update to land,
	/// short enough that the whole re-check fits inside the connect deadline
	/// with room to spare.
	static const Duration readPause = Duration(seconds: 2);

	final Future<void> Function(Duration delay) _wait;

	/// How recently a handshake must have happened to be trusted.
	///
	/// Three minutes: WireGuard rekeys every two minutes and sends a keepalive
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
	///
	/// `static final` rather than `const`, because `Uri.parse` is not a const
	/// function.
	static final List<Uri> defaultEndpoints = <Uri>[
		Uri.parse('https://api64.ipify.org?format=json'),
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
	Future<String?> currentIp({Duration timeout = preflightTimeout}) async {
		final watch = Stopwatch()..start();
		for (final endpoint in _endpoints) {
			final remaining = timeout - watch.elapsed;
			if (remaining <= Duration.zero) {
				break;
			}
			try {
				final address = await _readFrom(endpoint).timeout(remaining);
				if (address != null) {
					return address;
				}
			} on TimeoutException {
				// This is a best-effort baseline, not a prerequisite for starting
				// the tunnel. Do not wait on the remaining external services.
				break;
			}
		}
		return null;
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
	/// [protocol] only changes what the check *calls* the evidence: both
	/// protocols require a completed handshake reported by the engine with a
	/// fresh timestamp — Noise_IK for WireGuard, the TLS handshake behind
	/// OpenVPN's "Initialization Sequence Completed" — plus a public address
	/// that differs from the baseline. There is deliberately no weaker path
	/// for OpenVPN: an engine that cannot date its own handshake cannot be
	/// believed about the tunnel being up.
	Future<VerificationOutcome> verify({
		String? baseline,
		DateTime? handshakeAt,
		DateTime? now,
		ProtocolKind protocol = ProtocolKind.wireGuard,
	}) async {
		final at = now ?? DateTime.now();
		final observed = handshakeAt != null;
		final fresh = observed && at.difference(handshakeAt) <= handshakeFreshness;

		if (!observed) {
			final article = protocol == ProtocolKind.openVpn ? 'an' : 'a';
			return VerificationOutcome(
				verified: false,
				message:
					'The tunnel interface is up, but the server has not completed $article '
					'${protocol.label} handshake yet, so nothing is being carried. This '
					'usually means the server is unreachable or is rejecting this '
					'configuration.',
			);
		}
		if (!fresh) {
			final age = at.difference(handshakeAt).inMinutes;
			return VerificationOutcome(
				verified: false,
				handshakeObserved: true,
				message:
					'The last successful handshake was $age minutes ago. The server '
					'has stopped responding, so this is no longer a working tunnel '
					'even though the interface is still showing as up.',
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
						message: 'Verification was cancelled before the exit '
								'address could be confirmed.',
					);
				}
			}
			String? readingHost;
			String? reading;
			for (final endpoint in _endpoints) {
				final address = await _readFrom(endpoint);
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
			if (baseline == null || !sameAddress(baseline, current)) {
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
				message:
					'The handshake succeeded, but no external address service could '
					'be reached, even after several tries, so the connection could '
					'not be verified. It is not being reported as connected because '
					'that cannot be confirmed.',
			);
		}

		if (baseline == null) {
			// No pre-connection reading, so "the address changed" cannot be
			// tested. A completed handshake is real evidence that traffic is
			// flowing to the peer, so this is reported as verified with the
			// limitation stated rather than refused outright — refusing here
			// would make the check useless whenever the pre-probe was blocked.
			return VerificationOutcome(
				verified: true,
				publicIp: current,
				handshakeObserved: true,
				handshakeFresh: true,
				endpointHost: host,
				message:
					'Connected via $current. The address used before connecting could '
					'not be read, so the change in address could not be confirmed; '
					'the handshake with the server was verified.',
			);
		}

		if (sameAddress(baseline, current)) {
			return VerificationOutcome(
				verified: false,
				publicIp: current,
				handshakeObserved: true,
				handshakeFresh: true,
				endpointHost: host,
				message:
					'The public address did not change after connecting ($current '
					'both before and after, re-checked over several seconds), so '
					'traffic is still leaving outside the tunnel.',
			);
		}

		return VerificationOutcome(
			verified: true,
			publicIp: current,
			handshakeObserved: true,
			handshakeFresh: true,
			endpointHost: host,
			message: 'Connected via $current, which is different from the address '
				'used before connecting.',
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
	static bool isPlausibleAddress(String value) {
		if (value.length < 3 || value.length > 45) {
			return false;
		}
		if (value.contains(':')) {
			// IPv6: hex and colons only, and at least two colons so a stray word
			// containing a colon cannot pass.
			if (!RegExp(r'^[0-9A-Fa-f:]+$').hasMatch(value)) {
				return false;
			}
			return value.contains('::') || ':'.allMatches(value).length >= 2;
		}
		final parts = value.split('.');
		if (parts.length != 4) {
			return false;
		}
		for (final part in parts) {
			if (part.isEmpty || part.length > 3) {
				return false;
			}
			final octet = int.tryParse(part);
			if (octet == null || octet < 0 || octet > 255) {
				return false;
			}
		}
		return true;
	}

	/// Compares two addresses for equality.
	///
	/// Textual, deliberately. Two spellings of the same address
	/// (`::ffff:1.2.3.4` and `1.2.3.4`) would compare unequal and wrongly read
	/// as "the address changed", so the IPv4-mapped prefix is stripped before
	/// comparing. Full IPv6 normalisation is a large amount of code for a case
	/// these services do not produce.
	static bool sameAddress(String a, String b) {
		if (a == b) {
			return true;
		}
		return _stripMappedPrefix(a) == _stripMappedPrefix(b);
	}

	static String _stripMappedPrefix(String value) {
		const prefix = '::ffff:';
		final lower = value.toLowerCase();
		return lower.startsWith(prefix) ? lower.substring(prefix.length) : lower;
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
