import 'dart:async';

import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';

import '../ui/screens/locations_screen.dart';
import 'discovery_controller.dart';

/// Subscribes to [DiscoveryController] and shows the live country list.
///
/// This is the only place that knows a snapshot arrives asynchronously. The
/// screen below stays a pure function of the snapshot it is handed, so it can
/// be rendered in a test without any networking.
///
/// The first refresh is triggered once, on mount, and never again: a
/// countries screen that re-fetches on every rebuild would hammer the
/// sources and would make the refresh impossible to reason about.
class DiscoveryGate extends StatefulWidget {
  const DiscoveryGate({
    required this.controller,
    this.selectedCountryCode = 'AUTO',
    required this.onCountrySelected,
    required this.openVpnSupported,
    this.refreshOnMount = true,
    super.key,
  });

  final DiscoveryController controller;
  final String selectedCountryCode;
  final void Function(String countryCode) onCountrySelected;

  /// Whether this build can start an OpenVPN tunnel itself; passed
  /// through to the screen's notice, which must not tell a capable build
  /// that it cannot use the servers it is looking at.
  ///
  /// Read fresh from the connection controller's capabilities at every
  /// screen entry, because destinations are built when selected: the
  /// value has finished loading long before any tab can be opened.
  final bool openVpnSupported;

  /// Disabled in tests that supply their own snapshot.
  final bool refreshOnMount;

  @override
  State<DiscoveryGate> createState() => _DiscoveryGateState();
}

class _DiscoveryGateState extends State<DiscoveryGate> {
  late StreamSubscription<DirectorySnapshot> _subscription;
  late DirectorySnapshot _snapshot;
  late bool _refreshing;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.controller.snapshot;
    _refreshing = widget.controller.isRefreshing;
    _subscription = widget.controller.snapshots.listen((next) {
      if (mounted) {
        setState(() {
          _snapshot = next;
          _refreshing = widget.controller.isRefreshing;
        });
      }
    });
    if (widget.refreshOnMount) {
      // Deliberately not awaited in initState: the first paint should show
      // the "no list yet" state immediately, and the stream will deliver
      // the real data when it arrives.
      unawaited(widget.controller.refresh());
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LocationsScreen(
    snapshot: _snapshot,
    isRefreshing: _refreshing,
    selectedCountryCode: widget.selectedCountryCode,
    openVpnSupported: widget.openVpnSupported,
    onCountrySelected: widget.onCountrySelected,
    onRefresh: () => widget.controller.refresh(force: true),
  );
}
