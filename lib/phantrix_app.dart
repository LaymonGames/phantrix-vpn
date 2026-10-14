import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import 'config/configuration_repository.dart';
import 'settings/settings_controller.dart';
import 'settings/settings_persistence.dart';
import 'storage/app_store.dart';

import 'discovery/discovery_controller.dart';
import 'discovery/file_directory_cache.dart';
import 'discovery/file_vpn_gate_profile_cache.dart';
import 'discovery/discovery_gate.dart';
import 'l10n/strings.dart';
import 'net/app_http_fetcher.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'ui/components/brand.dart';
import 'ui/components/navigation.dart';
import 'ui/components/status_style.dart';
import 'ui/components/surfaces.dart';
import 'ui/screens/configurations_screen.dart';
import 'ui/screens/diagnostics_screen.dart';
import 'ui/screens/home_screen.dart';
import 'ui/screens/privacy_screen.dart';
import 'ui/screens/licenses_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/shell.dart';
import 'vpn/connection_controller.dart';
import 'vpn/connection_resolver.dart';

/// Wiring for the whole app, created once above [MaterialApp] so no widget
/// rebuilds a controller.
///
/// [bootstrap] builds the real scope and is the only thing that touches the
/// disk or a platform channel. Everything else — including every widget test —
/// uses [AppScope.inMemory], which is why the app's own test suite needs no
/// device and no temporary directories.
class AppScope {
	/// Builds a scope with no persistence and no platform storage.
	///
	/// The store is in-memory, so a test can run the whole app repeatedly with
	/// no leftovers between runs.
	factory AppScope.inMemory({
		SettingsController? settings,
		List<ServerProvider>? providers,
		HttpFetcher? fetcher,
	}) {
		return AppScope._(
			store: MemoryAppStore(),
			settings: settings,
			providers: providers,
			fetcher: fetcher,
			initialSettings: settings?.data,
		);
	}

	AppScope._({
		required AppStore store,
		required List<ServerProvider>? providers,
		required HttpFetcher? fetcher,
		required AppSettings? initialSettings,
		SettingsController? settings,
		DirectoryCache? directoryCache,
		VpnGateProfileCache? profileCache,
	}) {
		_ownsFetcher = fetcher == null;
		_fetcher = fetcher ?? AppHttpFetcher.owned();
		_platform = PhantrixPlatform();
		// When the caller supplies a controller, that controller is used
		// unchanged — a test's controller is the one under test, and replacing
		// it would quietly discard the settings the test set up.
		_settings =
				settings ?? PersistentSettingsController(initialSettings ?? AppSettings.defaults, store);
		discovery = DiscoveryController(
			providers: providers ??
					buildProviders(
						enabled: const {ProviderId.vpnGate},
						fetcher: _fetcher,
						profileCache: profileCache,
					),
			cache: directoryCache,
		);
		configurations = ConfigurationRepository(store);
		connection = ConnectionController(
			platform: _platform,
			settings: _settings,
		);
		resolver = ConnectionResolver(
			discovery: discovery,
			relayProbe: tcpRelayProbe,
		);
		// A retry after "there was nothing to connect to" can only be fixed
		// by selecting again, and only this scope knows how to do that — the
		// resolver and the discovery controller live here. Handing the
		// controller the method keeps `retry` honest: it re-selects when
		// nothing was ever attempted, and replays the recorded attempt when
		// something was.
		connection.retrySelection = connect;
	}

	/// Builds the real scope: opens the platform's private directory, reads the
	/// stored settings and configurations, and prepares everything the UI needs
	/// before the first frame.
	///
	/// A failure here is deliberately not fatal. An app that cannot read its
	/// store still runs with defaults, because "your settings did not load" is
	/// a worse experience than "your settings went back to how they were".
	static Future<AppScope> bootstrap({
		List<ServerProvider>? providers,
		HttpFetcher? fetcher,
		PhantrixPlatform? platform,
	}) async {
		final bridge = platform ?? PhantrixPlatform();
		final directory = await _privateDirectory(bridge);
		final store = await openDefaultStore(directory);
		final settings = await PersistentSettingsController.loadFrom(store);
		return AppScope._(
			store: store,
			providers: providers,
			fetcher: fetcher,
			initialSettings: settings,
			directoryCache: directory == null ? null : FileDirectoryCache.inDirectory(directory),
			profileCache: directory == null ? null : FileVpnGateProfileCache.inDirectory(directory),
		);
	}

	/// Asks the platform where private files live, with one retry.
	///
	/// Returns null when the platform cannot say, which the caller turns into
	/// the in-memory store. A lookup that never answers must degrade rather
	/// than hang the launch on a blank splash screen, so each attempt is
	/// bounded — but a single slow answer must not cost the user their
	/// settings either, so a first timeout retries once before giving up.
	/// Five seconds is an eternity for a local directory lookup and still
	/// short enough that a user watching a splash does not conclude the app
	/// is dead.
	///
	/// Every fallback is reported, not silent: a launch that quietly forgot
	/// the user's configurations would be indistinguishable from data loss.
	/// The one exception is a prompt null or empty answer, which is how a
	/// platform without private storage (the web) legitimately responds.
	static Future<String?> _privateDirectory(PhantrixPlatform bridge) async {
		for (var attempt = 0; attempt < 2; attempt++) {
			try {
				final directory = await bridge
						.appDataDirectory()
						.timeout(const Duration(seconds: 5));
				// A prompt null or empty answer is a legitimate "there is
				// nowhere to persist" (the web), not a failure: silent.
				if (directory == null || directory.isEmpty) {
					return null;
				}
				return directory;
			} on TimeoutException {
				// A first timeout may be transient slowness on a cold device
				// rather than absence; only the second attempt is trusted.
				if (attempt == 0) {
					await Future<void>.delayed(const Duration(seconds: 1));
					continue;
				}
			} on Object catch (error, stack) {
				FlutterError.reportError(
					FlutterErrorDetails(
						exception: error,
						stack: stack,
						library: 'phantrix.storage',
						context: ErrorDescription('reading the private application directory'),
					),
				);
				return null;
			}
		}
		FlutterError.reportError(
			FlutterErrorDetails(
				exception: StateError(
					'The platform did not report a private directory, so settings '
					'and configurations will not persist this launch.',
				),
				library: 'phantrix.storage',
				context: ErrorDescription('reading the private application directory'),
			),
		);
		return null;
	}

	late final PhantrixPlatform _platform;
	late final SettingsController _settings;
	late final HttpFetcher _fetcher;

	/// True when this scope created the fetcher and so owns its socket.
	late final bool _ownsFetcher;
	late final DiscoveryController discovery;
	late final ConnectionController connection;
	late final ConnectionResolver resolver;

	/// The user's imported WireGuard configurations.
	late final ConfigurationRepository configurations;

	SettingsController get settingsController => _settings;

	/// Connects using the user's saved settings and no country constraint.
	///
	/// This is the path the Connect button takes. It goes through the resolver
	/// rather than calling [ConnectionController.connect] directly, because a
	/// connection needs a *selected server plus its configuration*, and only
	/// the resolver knows how to obtain the second.
	Future<void> connect() async {
		// If a saved directory exists for the selected country, attempt it
		// immediately. A background feed refresh must not block VPN startup,
		// and cached public profiles can still be re-validated and tried.
		final remembered = _settings.data.selectedCountryCode;
		final countryCode = remembered == 'AUTO' ? null : remembered;
		if (discovery.snapshot.servers.isEmpty) {
			// With no saved candidates there is nothing to dial yet, so let the
			// initial load finish. Once any directory is available, selection
			// proceeds immediately without waiting for a live refresh.
			await discovery.ensureLoaded();
		}
		if (discovery.snapshot.servers.isEmpty) {
			connection.reportSelectionFailure(
				'No server list is available yet. Check your internet connection and retry, '
				'or import a VPN configuration to connect without the public server feed.',
			);
			return;
		}
		// Preserve the user's location preference exactly. If it is temporarily
		// absent from the public feed, the resolver reports that instead of
		// silently sending the user to a different country.
		await resolver.resolveAndConnect(
			SelectionRequest(
				mode: SelectionMode.recommended,
				countryCode: countryCode,
				favorites: _settings.data.favoriteServers,
				recents: _settings.data.recentServers,
			),
			connection: connection,
		);
	}

	/// Remembers the country immediately (even if its current server is down),
	/// then attempts that exact country from the current directory. A refresh
	/// is awaited only when no saved directory exists at all.
	Future<void> connectToCountry(String countryCode) async {
		// Choosing somewhere else abandons what is running now — a live tunnel
		// or an attempt still negotiating — at whatever point it had reached.
		// Done here rather than after the new server is resolved, so the old
		// tunnel is not still carrying traffic to a place the user just left
		// while the next one is looked up, and so a new country that turns out
		// to be unusable leaves the user disconnected with a reason instead of
		// silently still on the old one.
		await connection.cancel();
		final suppliedCode = countryCode.toUpperCase();
		final code = GeoDatabase.byIso3(suppliedCode)?.iso2 ?? suppliedCode;
		_settings.update((settings) => settings.copyWith(selectedCountryCode: code));
		if (code == 'AUTO') {
			await connect();
			return;
		}
		if (discovery.snapshot.servers.isEmpty) {
			await discovery.ensureLoaded();
		}
		if (discovery.snapshot.servers.isEmpty) {
			connection.reportSelectionFailure(
				'No server list is available yet. Check your internet connection and retry, '
				'or import a VPN configuration to connect without the public server feed.',
			);
			return;
		}
		await resolver.resolveAndConnect(
			SelectionRequest(
				mode: SelectionMode.recommended,
				countryCode: code,
				favorites: _settings.data.favoriteServers,
				recents: _settings.data.recentServers,
			),
			connection: connection,
		);
	}

	/// Connects using an imported configuration.
	///
	/// The configuration is re-validated here rather than trusted from the
	/// stored copy: it was checked when it was imported, but the validator may
	/// have been tightened since, and a tunnel is the last thing that should be
	/// started from a cached "this was fine yesterday".
	Future<void> connectToConfiguration(ImportedConfiguration configuration) async {
		// Switching to a different configuration is a change of destination
		// too, so it cancels the current one first. See [connectToCountry].
		await connection.cancel();
		final validated = configuration.build();
		if (validated case Err(:final error)) {
			// Surfaced the same way any other connection failure is: through the
			// state machine, so the UI shows one consistent error surface.
			connection.reportFailure(error);
			return;
		}
		final config = (validated as Ok<VpnConfiguration>).value;
		final wireGuard = config.wireGuard;
		final endpoint = wireGuard?.primaryEndpoint;

		_settings.noteUsed(configuration.id);
		await connection.connect(
			server: VpnServer(
				id: configuration.id,
				hostname: configuration.name,
				hostAddress: endpoint?.host,
				port: endpoint?.port,
				protocol: ProtocolKind.wireGuard,
				// An imported configuration is one the user supplied. It is
				// validated above, so nothing about its *contents* is unknown —
				// but nothing about its *operator* is either, and
				// `TrustLevel.imported` is the honest label for that. It carries
				// the "they can see your traffic" warning, which is exactly
				// right for a server whose operator we cannot name.
				trustLevel: TrustLevel.imported,
				countryCode: '',
				providerId: ProviderId.imported.wireName,
			),
			config: config,
			countryLabel: configuration.name,
		);
	}

	Future<void> dispose() async {
		await discovery.dispose();
		connection.dispose();
		_settings.dispose();
		if (_ownsFetcher) {
			(_fetcher as AppHttpFetcher).close();
		}
	}
}

/// The first-run flow.
///
/// There is no account step, no email step, and no phone step, because there
/// is no account. The privacy notice is not optional, because a user has a
/// right to be told what a public relay can see before they trust one.
///
/// One column on a phone, two on a desktop window: the promise and the notice
/// side by side, because on a wide screen stacking them leaves a column of text
/// in the middle of an empty window.
class OnboardingScreen extends StatelessWidget {
	const OnboardingScreen({required this.onDone, super.key});

	final VoidCallback onDone;

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final theme = Theme.of(context);
		final wide = MediaQuery.sizeOf(context).width >= VgBreakpoints.twoColumn;

		final mark = Center(
			child: VgLogo(size: wide ? 76 : 64),
		);
		final heading = Column(
			mainAxisSize: MainAxisSize.min,
			children: [
				Text(
					l10n.get('welcomeTitle'),
					style: wide
							? theme.textTheme.displaySmall
							: theme.textTheme.headlineMedium,
					textAlign: wide ? TextAlign.start : TextAlign.center,
				),
				const SizedBox(height: VgSpace.md),
				Text(
					l10n.get('welcomeBody'),
					style: theme.textTheme.bodyLarge?.copyWith(
						color: theme.colorScheme.onSurfaceVariant,
					),
					textAlign: wide ? TextAlign.start : TextAlign.center,
				),
			],
		);
		final notice = VgPanel(
			title: l10n.get('privacyNoticeTitle'),
			icon: Icons.lock_outline_rounded,
			elevated: true,
			padding: const EdgeInsets.all(VgSpace.lg),
			child: Text(l10n.get('privacyNoticeBody'), style: theme.textTheme.bodyMedium),
		);
		final action = SizedBox(
			// Full width on a narrow window so the only action on the screen is
			// easy to hit with a thumb; its natural width on a wide one, so it
			// does not stretch into a bar.
			width: wide ? null : double.infinity,
			child: FilledButton(
				onPressed: onDone,
				child: Text(l10n.get('privacyNoticeAccept')),
			),
		);

		return Scaffold(
			body: SafeArea(
				child: Padding(
					padding: const EdgeInsets.all(VgSpace.xl),
					child: Center(
						child: ConstrainedBox(
							constraints: const BoxConstraints(maxWidth: 880),
							child: wide
									? Column(
											mainAxisSize: MainAxisSize.min,
											crossAxisAlignment: CrossAxisAlignment.start,
											children: [
												mark,
												const SizedBox(height: VgSpace.xxl),
												heading,
												const SizedBox(height: VgSpace.xxxl),
												Row(
													crossAxisAlignment: CrossAxisAlignment.start,
													children: [
														Expanded(child: notice),
														const SizedBox(width: VgSpace.columnGap),
														SizedBox(width: 240, child: action),
													],
												),
											],
										)
									: Column(
											mainAxisAlignment: MainAxisAlignment.center,
											crossAxisAlignment: CrossAxisAlignment.stretch,
											children: [
												const Spacer(),
												mark,
												const SizedBox(height: VgSpace.xxl),
												heading,
												const Spacer(),
												notice,
												const SizedBox(height: VgSpace.xl),
												action,
											],
										),
						),
					),
				),
			),
		);
	}
}

class PhantrixApp extends StatelessWidget {
	const PhantrixApp({required this.scope, super.key});

	final AppScope scope;

	@override
	Widget build(BuildContext context) {
		return AnimatedBuilder(
			animation: scope.settingsController,
			builder: (context, _) {
				final d = scope.settingsController.data;
				if (!d.privacyNoticeAccepted) {
					return MaterialApp(
						title: 'Phantrix',
						debugShowCheckedModeBanner: false,
						theme: AppTheme.light(animationLevel: d.animationLevel),
						darkTheme: AppTheme.dark(animationLevel: d.animationLevel),
						themeMode: _mode(d.themeMode),
						locale: Locale(d.language),
						supportedLocales: L10n.supportedLocales,
						localizationsDelegates: const [
							GlobalMaterialLocalizations.delegate,
							GlobalCupertinoLocalizations.delegate,
							GlobalWidgetsLocalizations.delegate,
							_L10nDelegate(),
						],
						home: OnboardingScreen(
							onDone: () => scope.settingsController.update(
								(s) => s.copyWith(
									privacyNoticeAccepted: true,
									onboardingComplete: true,
								),
							),
						),
					);
				}
				return MaterialApp(
					title: 'Phantrix',
					debugShowCheckedModeBanner: false,
					theme: AppTheme.light(animationLevel: d.animationLevel),
					darkTheme: AppTheme.dark(animationLevel: d.animationLevel),
					themeMode: _mode(d.themeMode),
					locale: Locale(d.language),
					supportedLocales: L10n.supportedLocales,
					localizationsDelegates: const [
						GlobalMaterialLocalizations.delegate,
						GlobalCupertinoLocalizations.delegate,
						GlobalWidgetsLocalizations.delegate,
						_L10nDelegate(),
					],
					builder: (context, child) => _ScaleCap(child: child ?? const SizedBox.shrink()),
					home: _ShellWithNavigation(
						scope: scope,
						reducedMotion: d.animationLevel == 'none',
					),
				);
			},
		);
	}

	static ThemeMode _mode(String mode) => switch (mode) {
		'light' => ThemeMode.light,
		'dark' => ThemeMode.dark,
		_ => ThemeMode.system,
	};
}

class _L10nDelegate extends LocalizationsDelegate<L10n> {
	const _L10nDelegate();

	@override
	bool isSupported(Locale locale) =>
			L10n.supportedLocales.any((l) => l.languageCode == locale.languageCode);

	@override
	Future<L10n> load(Locale locale) async => L10n(locale.languageCode);

	@override
	bool shouldReload(covariant Object old) => false;
}

/// Caps text scale so a large accessibility setting does not break the layout.
class _ScaleCap extends StatelessWidget {
	const _ScaleCap({required this.child});

	final Widget child;

	@override
	Widget build(BuildContext context) {
		final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
		return MediaQuery(
			data: MediaQuery.of(context).copyWith(textScaler: scale),
			child: child,
		);
	}
}

/// Which screen the shell is showing.
///
/// Held as a [ChangeNotifier] above the shell rather than as state inside it,
/// because screens need to be able to send the user somewhere: the home
/// screen's "Choose a location" has to move the shell, and a screen that
/// cannot do that is how a button ends up wired to an empty callback.
class AppNavigation extends ChangeNotifier implements AppNavigationLike {
	int _index = 0;

	@override
	int get index => _index;

	/// The current destination's id.
	@override
	String? get currentId => _ids.isEmpty ? null : _ids[_index];

	/// Registers the destination ids in order.
	///
	/// Called by the shell once, when it builds. Kept separate from [go] so
	/// that a request naming an unknown id is ignored rather than landing the
	/// user on a screen that does not exist.
	void register(List<String> ids) => _ids = ids;

	/// Moves to the destination with [id], if there is one.
	bool go(String id) {
		final target = _ids.indexOf(id);
		if (target < 0 || target == index) {
			return false;
		}
		select(target);
		return true;
	}

	@override
	void Function(int) get select => _select;

	void _select(int value) {
		if (value == _index || value < 0 || value >= _ids.length) {
			return;
		}
		_index = value;
		notifyListeners();
	}

	List<String> _ids = const [];
}

List<Destination> _destinations(
	AppScope scope,
	AppNavigation navigation,
	bool reducedMotion,
) =>
		[
			Destination(
				id: 'home',
				label: 'Home',
				icon: Icons.shield_outlined,
				selectedIcon: Icons.shield_rounded,
				builder: (context) => AnimatedBuilder(
					// Rebuilds when configurations change, so the home screen's
					// "import a configuration" affordance appears the moment
					// one exists rather than on the next navigation.
					animation: scope.configurations,
					builder: (context, _) => HomeScreen(
						connection: scope.connection,
						configurations: scope.configurations,
						reducedMotion: reducedMotion,
						selectedCountryCode: scope.settingsController.data.selectedCountryCode,
						hasImportedConfigurations: scope.configurations.all.isNotEmpty,
						onQuickConnect: scope.connect,
						onChooseLocation: () => navigation.go('locations'),
						onManageConfigurations: () => navigation.go('configurations'),
						onConnectToConfiguration: scope.connectToConfiguration,
					),
				),
			),
			Destination(
				id: 'locations',
				label: 'Servers',
				icon: Icons.public_outlined,
				selectedIcon: Icons.public,
				builder: (context) => DiscoveryGate(
					controller: scope.discovery,
					selectedCountryCode: scope.settingsController.data.selectedCountryCode,
					onCountrySelected: scope.connectToCountry,
					hasImportedConfigurations: scope.configurations.all.isNotEmpty,
					openVpnSupported: scope.connection.capabilities.openVpn,
					onManageConfigurations: () => navigation.go('configurations'),
				),
			),
			Destination(
				id: 'configurations',
				label: 'Configurations',
				icon: Icons.add_link_outlined,
				selectedIcon: Icons.add_link_rounded,
				// Secondary, not a tab. Configuration import is opened over the
				// three tabs from Home ("Import") or from Settings, so it stays
				// reachable without a fourth entry crowding the bottom bar. Its
				// parent is Home, so opening it highlights the Home tab.
				parentId: 'home',
				builder: (context) => ConfigurationsScreen(
					configurations: scope.configurations,
					onConnect: scope.connectToConfiguration,
				),
			),
			Destination(
				id: 'diagnostics',
				label: 'Diagnostics',
				icon: Icons.insights_outlined,
				selectedIcon: Icons.insights,
				// Secondary like configs: opened from Settings rather than a tab,
				// so it stays reachable without crowding the bottom bar. Its
				// parent is the Settings tab it is opened from.
				parentId: 'settings',
				builder: (context) => DiagnosticsScreen(
					connection: _ConnectionGateway(scope.connection),
					settings: scope.settingsController,
				),
			),
			Destination(
				id: 'privacy',
				label: 'Privacy',
				icon: Icons.lock_outline_rounded,
				selectedIcon: Icons.lock_rounded,
				parentId: 'settings',
				builder: (context) => const PrivacyScreen(),
			),
			Destination(
				id: 'licenses',
				label: 'Licenses',
				icon: Icons.info_outline_rounded,
				selectedIcon: Icons.info_rounded,
				// Secondary like Privacy and Diagnostics; opened from Settings'
				// about area instead, where a user who wants it is already
				// looking.
				parentId: 'settings',
				builder: (context) => const LicensesScreen(),
			),
			Destination(
				id: 'settings',
				label: 'Settings',
				icon: Icons.settings_outlined,
				selectedIcon: Icons.settings_rounded,
				builder: (context) => SettingsScreen(
					settings: scope.settingsController,
					platform: scope.connection.capabilities,
					onManageConfigurations: () => navigation.go('configurations'),
					onOpenDiagnostics: () => navigation.go('diagnostics'),
					onOpenPrivacy: () => navigation.go('privacy'),
					onOpenLicenses: () => navigation.go('licenses'),
					onOpenSystemVpnSettings: () => unawaited(
						scope.connection.openSystemVpnSettings(),
					),
					systemLockdownActive: scope.connection.systemLockdownActive,
					onClearConfigurations: scope.configurations.clear,
					onClearLocalData: scope.settingsController.clearLocalData,
				),
			),
		];

/// Whether animations are suppressed.
///
/// Read at build time from the settings, so changing the setting takes effect
/// immediately rather than at the next launch.
/// Builds the destination list for the current settings.
///
/// [reducedMotion] is a parameter rather than something read from a global, so
/// that changing the setting takes effect on the next build and no state can
/// survive a settings change or outlive a scope.
/// Owns the navigation and keeps it in step with the destination list.
///
/// The navigation object is created once and passed to the shell, which is what
/// lets a screen move the user somewhere. Rebuilding the list on a settings
/// change is safe because the shell remembers its index by destination *id*
/// rather than by position, so adding or removing a destination cannot leave
/// the user on a different screen than they were on.
class _ShellWithNavigation extends StatefulWidget {
	const _ShellWithNavigation({required this.scope, required this.reducedMotion});

	final AppScope scope;
	final bool reducedMotion;

	@override
	State<_ShellWithNavigation> createState() => _ShellWithNavigationState();
}

class _ShellWithNavigationState extends State<_ShellWithNavigation> {
	final AppNavigation _navigation = AppNavigation();

	@override
	void dispose() {
		_navigation.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final destinations = buildDestinations(
			widget.scope,
			_navigation,
			reducedMotion: widget.reducedMotion,
		);
		// Registered during build rather than in initState, because the list is
		// rebuilt whenever settings change and may then contain a new
		// destination.
		_navigation.register(destinations.map((d) => d.id).toList());
		return AppShell(
			destinations: destinations,
			navigation: _navigation,
			statusFooter: _SidebarStatus(controller: widget.scope.connection),
		);
	}
}

List<Destination> buildDestinations(
	AppScope scope,
	AppNavigation navigation, {
	bool reducedMotion = false,
}) =>
		_destinations(scope, navigation, reducedMotion);

/// The connection summary in the sidebar's footer.
///
/// Reads the controller rather than being handed a string, so the state on
/// every screen is the state the state machine is actually in — there is no
/// second copy to fall out of date. No timer runs here: the elapsed session
/// time is on the dashboard, and rebuilding the sidebar once a second for a
/// figure nobody is reading would spend battery to say nothing.
class _SidebarStatus extends StatelessWidget {
	const _SidebarStatus({required this.controller});

	final ConnectionController controller;

	@override
	Widget build(BuildContext context) {
		return StreamBuilder<ConnectionView>(
			initialData: controller.currentView,
			stream: controller.views,
			builder: (context, snapshot) {
				final view = snapshot.data ?? controller.currentView;
				final tone = toneOf(view.state);
				final detail = switch (tone) {
					VgTone.connected => view.selectedLabel ?? 'Tunnel established',
					VgTone.working => 'Negotiating a tunnel',
					VgTone.failed => view.canRetry ? 'Tap to try again' : null,
					VgTone.blocked => 'Needs your attention',
					VgTone.idle => 'Not protected',
				};
				return VgConnectionSummary(
					tone: tone,
					label: view.statusMessage,
					detail: detail,
				);
			},
		);
	}
}

/// Adapts [ConnectionController] to what the diagnostics screen needs.
class _ConnectionGateway implements ConnectionControllerLike {
	_ConnectionGateway(this._controller);

	final ConnectionController _controller;

	@override
	Future<PlatformCapabilities> capabilities() async => _controller.capabilities;

	@override
	bool get isConnected => _controller.currentView.isConnected;
}
