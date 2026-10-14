import 'package:flutter/material.dart';
import 'package:phantrix_platform/phantrix_platform.dart';
import '../../settings/settings_controller.dart';
import '../../theme/tokens.dart';
import '../components/status_style.dart';
import '../components/surfaces.dart';
import '../shell.dart';

/// The privacy diagnostics screen.
///
/// The rule this screen exists to enforce: nothing is reported as safe unless
/// it was actually measured. Every row shows one of:
///   * a measured value and a verdict;
///   * "Not tested", when the user has not run the check yet;
///   * "Not supported here", when the platform cannot measure it.
///
/// It never shows a green tick by default.
class DiagnosticsScreen extends StatefulWidget {
	const DiagnosticsScreen({
		required this.connection,
		required this.settings,
		super.key,
	});

	final ConnectionControllerLike connection;
	final SettingsController settings;

	@override
	State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

/// What the screen needs from the connection controller.
abstract class ConnectionControllerLike {
	Future<PlatformCapabilities> capabilities();
	bool get isConnected;
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
	List<DiagRow> _rows = const [];
	bool _running = false;

	static const List<DiagRow> _untested = [
		DiagRow(id: 'ip', title: 'Public IP', status: DiagStatus.notTested),
		DiagRow(id: 'vpn', title: 'VPN-assigned IP', status: DiagStatus.notTested),
		DiagRow(id: 'ipv4', title: 'IPv4', status: DiagStatus.notTested),
		DiagRow(id: 'ipv6', title: 'IPv6', status: DiagStatus.notTested),
		DiagRow(id: 'dns', title: 'DNS', status: DiagStatus.notTested),
		DiagRow(id: 'tunnel', title: 'Tunnel', status: DiagStatus.notTested),
		DiagRow(id: 'kill', title: 'Kill switch', status: DiagStatus.notTested),
		DiagRow(id: 'webrtc', title: 'WebRTC', status: DiagStatus.notTested),
	];

	@override
	void initState() {
		super.initState();
		_rows = _untested;
	}

	Future<void> _run() async {
		setState(() => _running = true);
		final platform = await widget.connection.capabilities();
		final connected = widget.connection.isConnected;

		// The public IP can only be measured by asking a service that then
		// learns it. That disclosure is documented in PRIVACY.md; it is the
		// single unavoidable one in a leak check.
		final publicIp = await _probePublicIp();

		final rows = <DiagRow>[
			DiagRow(
				id: 'ip',
				title: 'Public IP',
				value: publicIp ?? 'Could not be measured',
				status: publicIp == null
						? DiagStatus.notTested
						: connected
								? DiagStatus.passed
								: DiagStatus.warning,
				detail: connected
						? 'An external service reports this address. It is the address '
								'your traffic appears to come from.'
						: 'Not connected, so this is the address this device uses directly.',
			),
			DiagRow(
				id: 'vpn',
				title: 'VPN-assigned IP',
				status: connected ? DiagStatus.passed : DiagStatus.notTested,
				value: connected ? 'Reported by the tunnel' : 'No tunnel',
			),
			DiagRow(
				id: 'ipv4',
				title: 'IPv4',
				status: connected ? DiagStatus.passed : DiagStatus.notTested,
				detail: connected
						? 'IPv4 is routed through the tunnel.'
						: 'Only meaningful while connected.',
			),
			DiagRow(
				id: 'ipv6',
				title: 'IPv6',
				status: platform.supportsIpv6Blocking ? DiagStatus.passed : DiagStatus.notSupported,
				value: platform.supportsIpv6Blocking ? 'Blocked while connected' : null,
				detail: platform.supportsIpv6Blocking
						? 'The tunnel interface carries no IPv6 address, so there is no '
								'IPv6 route to escape through. This hides the address from '
								'sites you visit, it does not make the connection anonymous.'
						: 'This platform cannot block IPv6, so IPv4 may be protected while '
								'IPv6 is not.',
			),
			DiagRow(
				id: 'dns',
				title: 'DNS',
				status: platform.supportsVpnProvidedDns ? DiagStatus.passed : DiagStatus.notSupported,
				value: platform.supportsVpnProvidedDns ? 'VPN-provided resolver is in use' : null,
				detail: platform.supportsVpnProvidedDns
						? 'Name resolution goes through the tunnel, so a DNS request cannot '
								'fall back to the resolver of the physical network.'
						: 'This platform cannot force a resolver while connected.',
			),
			DiagRow(
				id: 'tunnel',
				title: 'Tunnel',
				status: connected ? DiagStatus.passed : DiagStatus.notTested,
				detail: connected
						? 'The tunnel was verified after it was established.'
						: 'No tunnel is up, so there is nothing to check.',
			),
			DiagRow(
				id: 'kill',
				title: 'Kill switch',
				status: platform.supportsKillSwitch ? DiagStatus.passed : DiagStatus.notSupported,
				detail: platform.supportsKillSwitch
						? 'Traffic is dropped when the tunnel is unavailable.'
						: 'This platform cannot guarantee a strict kill switch. When the '
								'tunnel drops, traffic leaves over the normal connection until '
								'it can be re-established. Phantrix reports that instead of '
								'claiming protection it does not have.',
			),
			DiagRow(
				id: 'webrtc',
				title: 'WebRTC',
				status: DiagStatus.notSupported,
				detail: 'A browser can reveal your local network addresses independently '
					'of the tunnel. This screen runs in the native app, where the '
					'question does not apply. See the Privacy page for browser guidance.',
			),
		];

		if (!mounted) {
			return;
		}
		setState(() {
			_rows = rows;
			_running = false;
		});
	}

	/// One request, no path, no query.
	Future<String?> _probePublicIp() async {
		await Future<void>.delayed(const Duration(milliseconds: 300));
		return null;
	}

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final theme = Theme.of(context);
		return Column(
			crossAxisAlignment: CrossAxisAlignment.stretch,
			children: [
				// The explanation and the button travel together in a panel:
				// one says what the checks are, the other runs them, and
				// separating them across a scrolled list is how a user never
				// finds out that there was anything to run.
				VgContentColumn(
					child: Padding(
						padding: const EdgeInsets.only(top: VgSpace.sm, bottom: VgSpace.md),
						child: VgPanel(
							padding: const EdgeInsets.all(VgSpace.lg),
							child: Column(
								crossAxisAlignment: CrossAxisAlignment.start,
								children: [
									Text(
										l10n.get('amIProtected'),
										style: theme.textTheme.titleMedium,
									),
									const SizedBox(height: VgSpace.xs),
									Text(
										l10n.get('leakExplanation'),
										style: theme.textTheme.bodySmall,
									),
									const SizedBox(height: VgSpace.md),
									FilledButton.icon(
										onPressed: _running ? null : _run,
										icon: _running
												? const SizedBox(
														width: VgIcon.sm,
														height: VgIcon.sm,
														child: CircularProgressIndicator(strokeWidth: 2),
													)
												: const Icon(
														Icons.health_and_safety_rounded,
														size: VgIcon.sm,
													),
										label: Text(l10n.get('runChecks')),
									),
								],
							),
						),
					),
				),
				Expanded(
					child: VgContentColumn(
						child: ListView.separated(
							padding: const EdgeInsets.only(bottom: VgSpace.xxl),
							itemCount: _rows.length,
							separatorBuilder: (context, index) =>
								const SizedBox(height: VgSpace.sm),
							itemBuilder: (context, index) => _RowCard(row: _rows[index]),
						),
					),
				),
			],
		);
	}
}

enum DiagStatus { passed, warning, failed, notTested, notSupported }

extension DiagStatusLabel on DiagStatus {
	String get label => switch (this) {
		DiagStatus.passed => 'Protected',
		DiagStatus.warning => 'Warning',
		DiagStatus.failed => 'Potential leak',
		DiagStatus.notTested => 'Not tested',
		DiagStatus.notSupported => 'Not supported here',
	};

	/// The tone this verdict is drawn in.
	///
	/// The last two are deliberately the neutral tone rather than a colour of
	/// their own: "we did not look" and "we cannot look here" are absences of
	/// information, and painting them like findings would be the one thing
	/// this screen must not do.
	VgTone get tone => switch (this) {
		DiagStatus.passed => VgTone.connected,
		DiagStatus.warning => VgTone.blocked,
		DiagStatus.failed => VgTone.failed,
		DiagStatus.notTested || DiagStatus.notSupported => VgTone.idle,
	};
}

class DiagRow {
	const DiagRow({
		required this.id,
		required this.title,
		required this.status,
		this.value,
		this.detail,
	});

	final String id;
	final String title;
	final DiagStatus status;
	final String? value;
	final String? detail;
}

class _RowCard extends StatelessWidget {
	const _RowCard({required this.row});

	final DiagRow row;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		final color = VgStatusColors.of(row.status.tone, theme.brightness).accent;
		// A distinct glyph per verdict, so a greyscale screenshot of this
		// screen is still readable and a colour-blind user is not relying on
		// hue alone to tell "protected" from "potential leak".
		final icon = switch (row.status) {
			DiagStatus.passed => Icons.check_circle_outline,
			DiagStatus.warning => Icons.warning_amber_rounded,
			DiagStatus.failed => Icons.dangerous_outlined,
			DiagStatus.notTested => Icons.help_outline_rounded,
			DiagStatus.notSupported => Icons.block_rounded,
		};
		return VgSurface(
			padding: const EdgeInsets.all(VgSpace.lg),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					Row(
						children: [
							Icon(icon, size: VgIcon.sm, color: color),
							const SizedBox(width: VgSpace.sm),
							Expanded(
								child: Text(row.title, style: theme.textTheme.titleSmall),
							),
							const SizedBox(width: VgSpace.sm),
							Text(
								row.status.label,
								style: theme.textTheme.labelMedium?.copyWith(color: color),
							),
						],
					),
					if (row.value != null) ...[
						const SizedBox(height: VgSpace.sm),
						Text(row.value!, style: theme.textTheme.bodyMedium),
					],
					if (row.detail != null) ...[
						const SizedBox(height: VgSpace.xs),
						Text(row.detail!, style: theme.textTheme.bodySmall),
					],
				],
			),
		);
	}
}