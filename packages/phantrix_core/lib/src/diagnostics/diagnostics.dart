import '../core/app_error.dart';

/// The result of one privacy check.
///
/// [CheckStatus.notTested] exists on purpose: the app must never display
/// a green tick for a check it did not perform.
enum CheckStatus {
	passed('passed'),
	warning('warning'),
	failed('failed'),
	notTested('notTested'),
	notSupported('notSupported');

	const CheckStatus(this.label);

	final String label;
}

/// One line of the privacy check page.
class CheckResult {
	const CheckResult({
		required this.id,
		required this.title,
		required this.status,
		this.value,
		this.detail,
	});

	final String id;
	final String title;
	final CheckStatus status;

	/// The measured value, e.g. `203.0.113.9` or `10.7.0.2`.
	final String? value;

	/// What the app actually observed, in one sentence.
	final String? detail;

	static const CheckResult notTested = CheckResult(
		id: 'unknown',
		title: 'Not tested',
		status: CheckStatus.notTested,
	);
}

/// Everything the privacy page knows.
class DiagnosticsReport {
	const DiagnosticsReport({
		required this.checks,
		required this.takenAt,
		this.publicIp,
		this.vpnServerIp,
		this.dnsServers = const [],
		this.webrtcExposure,
		this.overall,
	});

	final List<CheckResult> checks;
	final DateTime takenAt;

	/// The address an external service saw. This is the only honest way to
	/// check whether an IP is exposed, and it does leak the IP to that one
	/// service, which the UI states.
	final String? publicIp;

	/// The address the exit server reports, when known.
	final String? vpnServerIp;

	final List<String> dnsServers;

	/// What the browser reported about local-address exposure, or null when
	/// this is not a browser.
	final String? webrtcExposure;

	/// The single worst status across all checks.
	final CheckStatus? overall;

	bool get hasRealData => checks.any((c) => c.status != CheckStatus.notTested);
}

/// Which checks the user can run.
enum DiagnosticCheck {
	/// Ask an external service what IP it sees.
	publicIp('publicIp'),

	/// Resolve a name and compare the resolver to the VPN DNS.
	dnsLeak('dnsLeak'),

	/// Whether IPv6 has an address that can leave outside the tunnel.
	ipv6Leak('ipv6Leak'),

	/// Whether the tunnel address is actually set.
	tunnelAddress('tunnelAddress'),

	/// Whether the browser can see local addresses.
	webrtc('webrtc'),

	/// Whether the tunnel still carries traffic.
	tunnelHealth('tunnelHealth'),

	/// Whether the kill switch is armed.
	killSwitch('killSwitch');

	const DiagnosticCheck(this.id);

	final String id;
}

/// Describes a check in language the user can act on, without hardcoding it
/// into the UI layer.
abstract class DiagnosticsDescriptions {
	static String title(DiagnosticCheck check) => switch (check) {
		DiagnosticCheck.publicIp => 'Public IP',
		DiagnosticCheck.dnsLeak => 'DNS',
		DiagnosticCheck.ipv6Leak => 'IPv6',
		DiagnosticCheck.tunnelAddress => 'Tunnel address',
		DiagnosticCheck.webrtc => 'WebRTC',
		DiagnosticCheck.tunnelHealth => 'Tunnel',
		DiagnosticCheck.killSwitch => 'Kill switch',
	};

	static String explanation(DiagnosticCheck check) => switch (check) {
		DiagnosticCheck.publicIp =>
			'Compares what this device sees with what an external service sees.',
		DiagnosticCheck.dnsLeak =>
			'Checks which resolver answered, so a DNS request cannot fall back '
				'to your own network.',
		DiagnosticCheck.ipv6Leak =>
			'Checks whether an IPv6 address can leave outside the tunnel.',
		DiagnosticCheck.tunnelAddress =>
			'Confirms the tunnel actually assigned an address to this device.',
		DiagnosticCheck.webrtc =>
			'Browsers can reveal local network addresses independently of the '
				'tunnel.',
		DiagnosticCheck.tunnelHealth => 'Confirms traffic still flows through the tunnel.',
		DiagnosticCheck.killSwitch =>
			'Confirms the block is armed so traffic cannot escape when the tunnel '
				'drops.',
	};
}

/// What a privacy probe found.
class ProbeResult {
	const ProbeResult({required this.ok, this.status, this.error});

	final bool ok;
	final int? status;
	final AppError? error;

	static const ProbeResult unreachable = ProbeResult(ok: false);
}
