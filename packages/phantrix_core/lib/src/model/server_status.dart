/// Lifecycle of a server in the directory.
///
/// Deliberately explicit: the UI must never show "online" for a server the app
/// has only ever seen in a downloaded list.
enum ServerStatus {
  unknown,
  online,
  degraded,
  offline,
  withdrawn;

  String get label => switch (this) {
    ServerStatus.unknown => 'Unknown',
    ServerStatus.online => 'Online',
    ServerStatus.degraded => 'Degraded',
    ServerStatus.offline => 'Offline',
    ServerStatus.withdrawn => 'Withdrawn',
  };

  bool get isUsable =>
      this == ServerStatus.online || this == ServerStatus.degraded;
}
