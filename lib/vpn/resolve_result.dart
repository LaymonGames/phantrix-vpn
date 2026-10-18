import 'package:phantrix_core/phantrix_core.dart';

/// What a resolve produced: a usable target, or a reason there is none.
///
/// These are the shapes that cross the boundary between choosing a server and
/// connecting to it. [ResolveFailure] in particular exists so the caller can
/// tell "there is nothing to connect to" apart from "the fetch failed",
/// because the two need different words in front of the user.

/// A server that was chosen, plus the configuration that can actually be
/// used to reach it.
///
/// The pair travels together because the second half is not implied by the
/// first: a provider can publish metadata for a server and still be unable
/// to hand over a working configuration. Connecting with a server and no
/// config is exactly the bug this type makes impossible.
class ResolvedTarget {
  const ResolvedTarget({
    required this.server,
    required this.config,
    required this.selection,
    required this.provider,
  });

  final VpnServer server;

  /// Already parsed and security-validated by the provider.
  final VpnConfiguration config;

  /// Why this server, including whether the request was honoured.
  final Selection selection;

  /// The source the configuration came from.
  final ServerProvider provider;

  bool get fellBack => selection.fellBack;

  /// A line the UI can show verbatim. Never says "connected" — nothing has
  /// been connected at this point.
  String get explanation => selection.explanation;
}

/// Why a connection could not even be attempted.
///
/// These are distinct cases because each one needs a different action from the
/// user, and collapsing them into "connection failed" is what makes a VPN app
/// frustrating.
enum ResolveFailure {
  /// The directory has never been loaded, or the last refresh found nothing.
  noServers,

  /// A country was asked for but the list has no entry for it at all.
  unknownCountry,

  /// The country has servers but none passed the health and trust rules.
  noEligibleServer,

  /// A server was chosen but the provider that published it is gone.
  providerUnavailable,

  /// The provider declined to hand over a configuration for this server.
  /// This is a normal outcome for a metadata-only source, not a bug.
  noConfiguration,

  /// Fetching the configuration failed.
  fetchFailed,
}

/// The outcome of a resolve attempt.
sealed class ResolveResult {
  const ResolveResult();
}

/// A server and configuration are ready to hand to the tunnel.
class ResolveSuccess extends ResolveResult {
  const ResolveSuccess(this.target, {this.notice});

  final ResolvedTarget target;

  /// Set when the request was substituted — for example the chosen country
  /// had nothing usable and another was used. The UI must show this; a
  /// silent substitution is the failure mode this whole class exists to
  /// prevent.
  final String? notice;
}

/// No connection could be attempted. [message] is safe to show a user.
class ResolveFailureResult extends ResolveResult {
  const ResolveFailureResult(this.reason, this.message);

  final ResolveFailure reason;
  final String message;
}
