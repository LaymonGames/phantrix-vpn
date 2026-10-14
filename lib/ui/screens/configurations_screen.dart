import 'package:flutter/material.dart';
import 'package:phantrix_core/phantrix_core.dart';

import '../../config/configuration_repository.dart';
import '../../theme/tokens.dart';
import '../components/status_style.dart';
import '../components/surfaces.dart';

/// Manage imported WireGuard configurations.
///
/// ## Why this screen exists
///
/// The only server feed this build ships with publishes **OpenVPN** servers,
/// and every native backend here drives **WireGuard**. Without importing a
/// WireGuard configuration there is nothing for the app to connect to — so
/// this is not a convenience, it is the provisioning path the product needs.
///
/// It therefore has to be genuinely usable: paste or type the text, see
/// exactly why something was refused, and connect without leaving the screen.
class ConfigurationsScreen extends StatelessWidget {
	const ConfigurationsScreen({
		required this.configurations,
		required this.onConnect,
		super.key,
	});

	final ConfigurationRepository configurations;
	final Future<void> Function(ImportedConfiguration) onConnect;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		return AnimatedBuilder(
			// The repository is a Listenable, so an import redraws the screen the
			// moment it lands rather than on the next navigation.
			animation: configurations,
			builder: (context, _) {
				final all = configurations.all;
				return VgContentColumn(
					child: Column(
						crossAxisAlignment: CrossAxisAlignment.stretch,
						children: [
							const SizedBox(height: VgSpace.sm),
							Text('Configurations', style: theme.textTheme.headlineSmall),
							const SizedBox(height: VgSpace.xs),
							Text(
								'Paste a WireGuard configuration to connect to it. '
								'The text is validated and stored on this device only.',
								style: theme.textTheme.bodyMedium,
							),
							const SizedBox(height: VgSpace.lg),
							Align(
								alignment: AlignmentDirectional.centerStart,
								child: FilledButton.icon(
									onPressed: () => _openImport(context),
									icon: const Icon(Icons.add_rounded, size: VgIcon.sm),
									label: const Text('Import a configuration'),
								),
							),
							const SizedBox(height: VgSpace.lg),
							// The list scrolls in both states. It used to be an
							// `Expanded` around the empty state and a bare
							// column in the other branch, which meant a user
							// with five configurations got an overflow and no
							// way to reach the fifth.
							Expanded(
								child: all.isEmpty
										? const VgEmptyState(
												icon: Icons.add_link_rounded,
												title: 'No configurations yet',
												message:
													'Import a .conf file from your WireGuard '
													'provider, or paste the text here. Nothing is '
													'uploaded and nothing leaves this device.',
												actionLabel: null,
											)
										: ListView.separated(
												padding: const EdgeInsets.only(
													bottom: VgSpace.xxl,
												),
												itemCount: all.length,
												separatorBuilder: (context, index) =>
													const SizedBox(height: VgSpace.md),
												itemBuilder: (context, index) {
													final configuration = all[index];
													return _ConfigurationTile(
														configuration: configuration,
														onConnect: () => onConnect(configuration),
														onRemove: () =>
																_confirmRemove(context, configuration),
													);
												},
											),
							),
						],
					),
				);
			},
		);
	}

	Future<void> _openImport(BuildContext context) async {
		await showModalBottomSheet<void>(
			context: context,
			isScrollControlled: true,
			useSafeArea: true,
			showDragHandle: true,
			builder: (sheetContext) => _ImportSheet(configurations: configurations),
		);
	}

	Future<void> _confirmRemove(
		BuildContext context,
		ImportedConfiguration configuration,
	) async {
		final messenger = ScaffoldMessenger.of(context);
		final confirmed = await showDialog<bool>(
			context: context,
			builder: (dialogContext) => AlertDialog(
				title: const Text('Remove this configuration?'),
				// Naming the entry, because "are you sure?" without a subject
				// makes it impossible to tell two confirmations apart.
				content: Text(
					'“${configuration.name}” and its private key will be deleted from '
					'this device. This cannot be undone.',
				),
				actions: [
					TextButton(
						onPressed: () => Navigator.of(dialogContext).pop(false),
						child: const Text('Keep it'),
					),
					FilledButton(
						onPressed: () => Navigator.of(dialogContext).pop(true),
						child: const Text('Remove'),
					),
				],
			),
		);
		if (confirmed ?? false) {
			await configurations.remove(configuration.id);
		}
		messenger.hideCurrentSnackBar();
	}
}

class _ConfigurationTile extends StatelessWidget {
	const _ConfigurationTile({
		required this.configuration,
		required this.onConnect,
		required this.onRemove,
	});

	final ImportedConfiguration configuration;
	final VoidCallback onConnect;
	final VoidCallback onRemove;

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		// Re-validated on every build rather than trusting the stored verdict.
		// A configuration that no longer passes is shown as unusable instead
		// of being offered a Connect button that will fail.
		final verdict = configuration.build();
		final validated = verdict is Ok<VpnConfiguration>;
		final positive = VgStatusColors.of(
			VgTone.connected,
			theme.brightness,
		).accent;

		return VgPanel(
			// The verdict is the headline of this card, so it is a hairline on
			// the leading edge rather than a chip buried under the name.
			accent: validated ? positive : theme.colorScheme.error,
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.stretch,
				children: [
					Row(
						children: [
							Container(
								width: 38,
								height: 38,
								alignment: Alignment.center,
								decoration: BoxDecoration(
									color: (validated ? positive : theme.colorScheme.error)
										.withValues(alpha: 0.12),
									borderRadius: BorderRadius.circular(VgRadius.sm),
								),
								child: Icon(
									validated
											? Icons.vpn_key_rounded
											: Icons.report_gmailerrorred_rounded,
									size: VgIcon.md,
									color: validated ? positive : theme.colorScheme.error,
								),
							),
							const SizedBox(width: VgSpace.md),
							Expanded(
								child: Column(
									crossAxisAlignment: CrossAxisAlignment.start,
									mainAxisSize: MainAxisSize.min,
									children: [
										Text(
											configuration.name,
											maxLines: 1,
											overflow: TextOverflow.ellipsis,
											style: theme.textTheme.titleMedium,
										),
										const SizedBox(height: 2),
										Text(
											_endpointSummary(configuration),
											maxLines: 1,
											overflow: TextOverflow.ellipsis,
											style: theme.textTheme.bodySmall?.copyWith(
												fontFamily: 'monospace',
											),
										),
									],
								),
							),
							IconButton(
								onPressed: onRemove,
								icon: const Icon(
									Icons.delete_outline_rounded,
									size: VgIcon.md,
								),
								tooltip: 'Remove ${configuration.name}',
							),
						],
					),
					const SizedBox(height: VgSpace.md),
					Wrap(
						spacing: VgSpace.sm,
						runSpacing: VgSpace.xs,
						children: [
							VgChip(
								label: validated ? 'Validated' : 'Unusable',
								color: validated ? positive : theme.colorScheme.error,
								icon: validated
										? Icons.check_circle_outline_rounded
										: Icons.error_outline_rounded,
							),
							VgChip(
								label:
										'${configuration.endpointCount} peer${configuration.endpointCount == 1 ? '' : 's'}',
								color: theme.colorScheme.onSurfaceVariant,
							),
							VgChip(
								label: configuration.usesIpv6 ? 'IPv6 capable' : 'IPv4 only',
								color: theme.colorScheme.onSurfaceVariant,
							),
						],
					),
					if (verdict is Err<VpnConfiguration>) ...[
						const SizedBox(height: VgSpace.md),
						VgNote(
							icon: Icons.error_outline_rounded,
							color: theme.colorScheme.error,
							message: verdict.error.message,
						),
					],
					const SizedBox(height: VgSpace.md),
					FilledButton.icon(
						// Reachable while another attempt is running: connecting
						// to a configuration is a change of destination, and it
						// cancels whatever is in flight before it starts.
						onPressed: validated ? onConnect : null,
						icon: const Icon(Icons.play_arrow_rounded, size: VgIcon.sm),
						label: const Text('Connect'),
					),
				],
			),
		);
	}

	/// A short description of where the traffic goes.
	///
	/// Built from the real endpoint hosts. When the configuration has no
	/// endpoint at all the text says so rather than showing an empty pill.
	static String _endpointSummary(ImportedConfiguration configuration) {
		final verdict = configuration.build();
		if (verdict is! Ok<VpnConfiguration>) {
			return 'Could not be read';
		}
		final hosts = <String>{};
		for (final peer in verdict.value.wireGuard?.peers ?? const []) {
			final host = peer.endpoint?.host;
			if (host != null && host.isNotEmpty) {
				hosts.add(host);
			}
		}
		if (hosts.isEmpty) {
			return 'No endpoint in this configuration';
		}
		final sorted = hosts.toList()..sort();
		if (sorted.length == 1) {
			return sorted.first;
		}
		if (sorted.length == 2) {
			return '${sorted[0]} and ${sorted[1]}';
		}
		return '${sorted[0]} and ${sorted.length - 1} others';
	}
}

/// The import sheet.
///
/// Validation happens on the way *in*, so the error appears while the user is
/// still looking at the text they pasted, not after a round trip to a list they
/// have navigated away from.
class _ImportSheet extends StatefulWidget {
	const _ImportSheet({required this.configurations});

	final ConfigurationRepository configurations;

	@override
	State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
	final TextEditingController _text = TextEditingController();
	final TextEditingController _name = TextEditingController();
	String? _error;
	bool _busy = false;

	@override
	void dispose() {
		_text.dispose();
		_name.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final theme = Theme.of(context);
		// Lifted above the keyboard, so the button and the error are reachable
		// while typing rather than hidden behind it.
		final viewInsets = MediaQuery.viewInsetsOf(context);
		return Padding(
			padding: EdgeInsets.fromLTRB(
				VgSpace.lg,
				0,
				VgSpace.lg,
				VgSpace.lg + viewInsets.bottom,
			),
			child: SingleChildScrollView(
				child: Column(
					mainAxisSize: MainAxisSize.min,
					crossAxisAlignment: CrossAxisAlignment.stretch,
					children: [
						Text('Import a configuration', style: theme.textTheme.titleLarge),
						const SizedBox(height: VgSpace.xs),
						Text(
							'Paste the text between the [Interface] and [Peer] sections, '
							'or the whole .conf file.',
							style: theme.textTheme.bodyMedium,
						),
						const SizedBox(height: VgSpace.lg),
						TextField(
							controller: _name,
							textInputAction: TextInputAction.next,
							decoration: const InputDecoration(
								labelText: 'Name (optional)',
								hintText: 'Defaults to the server address',
							),
						),
						const SizedBox(height: VgSpace.md),
						TextField(
							controller: _text,
							maxLines: 8,
							minLines: 5,
							autocorrect: false,
							enableSuggestions: false,
							// Base64 keys and CIDR ranges must not be altered by
							// a keyboard that "helpfully" capitalises or inserts a
							// smart quote. A mangled key is a silent failure.
							smartDashesType: SmartDashesType.disabled,
							smartQuotesType: SmartQuotesType.disabled,
							style: TextStyle(
								fontFamily: 'monospace',
								fontSize: theme.textTheme.bodyMedium?.fontSize,
							),
							decoration: const InputDecoration(
								labelText: 'Configuration text',
								alignLabelWithHint: true,
								hintText: '[Interface]\nPrivateKey = …\nAddress = 10.0.0.2/32\n'
									'DNS = 10.0.0.1\n\n[Peer]\nPublicKey = …\n'
									'Endpoint = vpn.example.com:51820\nAllowedIPs = 0.0.0.0/0',
							),
						),
						if (_error != null) ...[
							const SizedBox(height: VgSpace.md),
							VgNote(
								icon: Icons.error_outline_rounded,
								color: theme.colorScheme.error,
								message: _error!,
							),
						],
						const SizedBox(height: VgSpace.lg),
						FilledButton(
							onPressed: _busy ? null : _submit,
							child: Text(_busy ? 'Checking…' : 'Validate and save'),
						),
						const SizedBox(height: VgSpace.sm),
						TextButton(
							onPressed: _busy ? null : () => Navigator.of(context).pop(),
							child: const Text('Cancel'),
						),
					],
				),
			),
		);
	}

	Future<void> _submit() async {
		final messenger = ScaffoldMessenger.of(context);
		final navigator = Navigator.of(context);
		setState(() {
			_busy = true;
			_error = null;
		});
		final result = await widget.configurations.import(
			_text.text,
			name: _name.text.trim().isEmpty ? null : _name.text.trim(),
		);
		if (!mounted) {
			return;
		}
		switch (result) {
			case Ok(:final value):
				// The configuration now exists; the user connects from the list
				// rather than here, so connecting immediately would hide which
				// of several entries was used.
				navigator.pop();
				messenger.showSnackBar(
					SnackBar(
						content: Text('Imported “${value.name}”. Connect to it from the list.'),
					),
				);
			case Err(:final error):
				setState(() {
					_busy = false;
					_error = error.message;
				});
		}
	}
}