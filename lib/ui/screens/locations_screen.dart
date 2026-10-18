library;

import 'package:flutter/material.dart';

import 'package:phantrix_core/phantrix_core.dart';

import '../shell.dart';
import '../../theme/tokens.dart';
import '../components/rows.dart';
import '../components/surfaces.dart';
import 'country_directory.dart';
import 'directory_banner.dart';
import 'location_cards.dart';

part 'locations_state.dart';
part 'locations_empty_state.dart';
part 'locations_filter_chip.dart';

/// The country browser.
///
/// The list is built from the live server inventory. Before the first
/// refresh, and after a refresh that found nothing, the screen says which of
/// those it is — it never falls back to a built-in list of countries with
/// invented server counts and latencies.
///
/// The search field and the filters sit in a panel above the list rather than
/// loose on the background, so the controls read as one thing you operate
/// rather than three things you happened to scroll past.
class LocationsScreen extends StatefulWidget {
  const LocationsScreen({
    required this.onCountrySelected,
    required this.snapshot,
    this.selectedCountryCode = 'AUTO',
    this.openVpnSupported = false,
    this.onRefresh,
    this.isRefreshing = false,
    super.key,
  });

  final void Function(String countryCode) onCountrySelected;

  /// The current directory state. Supplied by the caller so the screen stays
  /// a pure function of its inputs and needs no provider plumbing of its own.
  final DirectorySnapshot snapshot;
  final String selectedCountryCode;

  /// Whether this build can start an OpenVPN tunnel itself.
  ///
  /// The notice below may appear only while the servers on screen speak
  /// OpenVPN and this build cannot start one. Defaults to false, so an
  /// unread capability counts as unsupported — the same conservative
  /// reading the connection resolver applies to a server it cannot prove
  /// this build can start.
  final bool openVpnSupported;

  final Future<void> Function()? onRefresh;

  final bool isRefreshing;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}
