import 'dart:async';

import 'package:flutter/material.dart';

import 'phantrix_app.dart';

Future<void> main() async {
	WidgetsFlutterBinding.ensureInitialized();

	// Everything the first frame needs is prepared before the app is shown,
	// rather than in a loading state: the stored settings decide the theme and
	// whether the privacy notice appears, and both of those flashing from a
	// default to the real value is worse than a moment of startup.
	//
	// `bootstrap` never throws. A platform that cannot report a private
	// directory, or a store that cannot be read, degrades to defaults rather
	// than refusing to start — losing a setting is recoverable, an app that
	// will not launch is not.
	final scope = await AppScope.bootstrap();

	// Configurations are read after the scope exists but before the first
	// frame for the same reason: the home screen says whether anything is
	// imported, and it must not briefly say "none" and then change.
	await scope.configurations.load();

	// Restore public server metadata synchronously so Locations can paint
	// immediately on repeat launches. The network refresh below replaces this
	// stale cache in the background. VPN Gate's public relay profiles are kept
	// in a separate private cache for connection attempts during feed outages;
	// user-imported configurations and private WireGuard keys are not included.
	scope.discovery.restoreFromCache();

	// Warm the directory before the user opens Locations or Connects. The
	// operation is shared with later refresh/connect calls, so it is fetched
	// once rather than once per screen.
	unawaited(scope.discovery.refresh());

	runApp(PhantrixApp(scope: scope));
}
