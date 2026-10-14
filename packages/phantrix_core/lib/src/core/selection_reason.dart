/// Labels that describe why a server was (or was not) selected.
///
/// Displayed verbatim to the user so that automatic decisions are never
/// opaque.
enum SelectionReason {
	fastest,
	nearest,
	random,
	recommended,
	healthiest,
	favorite,
	recent,
	manual,
	fallbackSameCountry,
	fallbackNearbyCountry,
	imported,
	specificServer,
}

extension SelectionReasonText on SelectionReason {
	String get label => switch (this) {
		SelectionReason.fastest => 'Fastest measured',
		SelectionReason.nearest => 'Nearest by latency',
		SelectionReason.random => 'Random among eligible servers',
		SelectionReason.recommended => 'Recommended for reliability',
		SelectionReason.healthiest => 'Best recent health',
		SelectionReason.favorite => 'Your favorite',
		SelectionReason.recent => 'Recently used',
		SelectionReason.manual => 'Selected by you',
		SelectionReason.fallbackSameCountry =>
			'Another server in the same country',
		SelectionReason.fallbackNearbyCountry =>
			'Another server in a nearby country',
		SelectionReason.imported => 'Imported configuration',
		SelectionReason.specificServer => 'Specific server',
	};
}
