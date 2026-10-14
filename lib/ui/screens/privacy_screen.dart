import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../components/surfaces.dart';

/// The privacy explanation page.
///
/// Written in plain language and deliberately unflattering where it needs to
/// be: a "no logs!" claim is exactly what a trustworthy VPN client must not be
/// able to make about somebody else's servers.
///
/// Each claim is its own panel rather than a run of headings and paragraphs.
/// A wall of six headings reads as a policy document; six titled panels read
/// as six things the app is telling you, which is what this is.
class PrivacyScreen extends StatelessWidget {
	const PrivacyScreen({super.key});

	static const List<(String, String)> _claims = [
		(
			'What a VPN protects',
			'Traffic between this device and the VPN server is encrypted. On a '
				'public Wi-Fi network, whoever runs that network cannot read it. '
				'The sites you visit see the VPN server address instead of yours.',
		),
		(
			'What it does not protect',
			'It does not make you anonymous. It does not hide what you did if '
				'you signed in to a service, and it does not stop that service '
				'remembering you. It does not protect you from malware or from '
				'trackers, and it does not protect anything you choose to upload.',
		),
		(
			'Who can see your traffic',
			'Your internet provider can see that you are connected to a VPN '
				'server and which one. The VPN operator can see everything that '
				'leaves their server. Websites see the address of the VPN server.',
		),
		(
			'Why free servers have trust limits',
			'Free public VPN servers are operated by third parties. Your '
				'traffic exits through the selected server, so the operator may '
				'be able to observe it. Use a server you trust for sensitive '
				'activity.',
		),
		(
			'A VPN does not make you anonymous',
			'Anyone who says otherwise is selling something. Correlating a VPN '
				'connection with the site it went to, timing traffic, or simply '
				'asking the operator are all ways a VPN can be defeated. What this '
				'app does is narrow who can casually observe you.',
		),
		(
			'A browser proxy is not a device VPN',
			"A browser extension can only route the browser's own traffic, and "
				'it cannot protect any other application. The web interface '
				'browses servers, generates configurations and runs diagnostics; '
				'it does not make this device private.',
		),
	];

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return VgContentColumn(
			child: ListView(
				padding: const EdgeInsets.only(bottom: VgSpace.xxl),
				children: [
					for (final (title, body) in _claims) ...[
						VgPanel(
							title: title,
							icon: Icons.shield_outlined,
							padding: const EdgeInsets.all(VgSpace.lg),
							child: Text(body, style: theme.textTheme.bodyMedium),
						),
						const SizedBox(height: VgSpace.md),
					],
					VgNote(
						message:
							'You remain responsible for complying with applicable laws, '
							'network policies, and the terms of the networks and services '
							'you use.',
						icon: Icons.gavel_rounded,
					),
				],
			),
		);
	}
}