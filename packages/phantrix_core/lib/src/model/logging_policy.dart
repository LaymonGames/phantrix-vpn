/// The logging policy an operator claims to follow, when they tell us.
enum LoggingPolicy {
	unknown('Unknown'),
	noneClaimed('Claims no logging'),
	twoWeeks('Logs for two weeks'),
	thirtyDays('Logs for 30 days'),
	other('Other');

	const LoggingPolicy(this.label);

	final String label;

	static LoggingPolicy fromVpnGate(String? raw) => switch (raw?.toLowerCase()) {
		'2weeks' || '2 weeks' || '2weekssince' => LoggingPolicy.twoWeeks,
		'30days' || '30 days' || '1month' => LoggingPolicy.thirtyDays,
		'none' || 'nologs' || 'no logs' => LoggingPolicy.noneClaimed,
		null || '' => LoggingPolicy.unknown,
		_ => LoggingPolicy.other,
	};
}
