import 'dart:io';

/// The cheapest honest question there is about a TCP relay: does anything
/// answer on that port?
///
/// Volunteer relay lists are full of entries that do not, and finding that out
/// here costs a few seconds where handing the relay to the engine costs a whole
/// attempt budget. Only a failed connect or a timeout counts as "no"; it says
/// nothing about whether the relay would complete a TLS handshake, so a "yes"
/// is a reason to try it, not a promise.

/// Answers whether a relay's TCP port accepts a connection at all.
///
/// Injected so tests never open a socket; the app passes [tcpRelayProbe].
typedef RelayProbe = Future<bool> Function(
  String host,
  int port,
  Duration timeout,
);

/// A real TCP connect, closed immediately.
Future<bool> tcpRelayProbe(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}
