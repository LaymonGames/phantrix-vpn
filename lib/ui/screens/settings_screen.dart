import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:phantrix_core/phantrix_core.dart';
import 'package:phantrix_platform/phantrix_platform.dart';

import '../../settings/settings_controller.dart';
import '../../theme/tokens.dart';
import '../components/rows.dart';
import '../components/status_style.dart';
import '../components/surfaces.dart';
import '../shell.dart';

/// The settings screen.
///
/// A control the platform cannot honour is shown disabled with the reason
/// beside it, rather than hidden or silently ignored.
///
/// Grouped into labelled panels rather than one long list of cards: the
/// screen used to render each setting as its own `Card`, which made a list of
/// eighteen settings look like eighteen unrelated things. One panel per
/// concern — Connection, Privacy, Appearance, About — reads as four decisions
/// the user is making.
class SettingsScreen extends StatelessWidget {
	const SettingsScreen({
		required this.settings,
		required this.platform,
		required this.onManageConfigurations,
		required this.onOpenDiagnostics,
		required this.onOpenPrivacy,
		required this.onOpenLicenses,
		required this.onClearConfigurations,
		required this.onClearLocalData,
		required this.onOpenSystemVpnSettings,
		required this.systemLockdownActive,
		super.key,
	});

	final SettingsController settings;
	final PlatformCapabilities platform;

	/// Opens the configuration manager.
	final VoidCallback onManageConfigurations;

	/// Opens the diagnostics screen.
	///
	/// Diagnostics and Privacy are not in the phone bottom bar, because six
	/// labels do not survive a large text scale. They are linked from here
	/// instead, which is the screen a user is already in when they want them —
	/// so removing them from the bar costs one tap rather than the feature.
	final VoidCallback onOpenDiagnostics;

	/// Opens the privacy notice.
	final VoidCallback onOpenPrivacy;

	/// Opens the licences and credits page.
	final VoidCallback onOpenLicenses;

	/// Opens the operating system's own VPN settings.
	///
	/// Used by the system-lockdown row, which is the one control on this
	/// screen that the app cannot honour itself: enabling lockdown happens in
	/// the system settings, so the row links there instead of pretending a
	/// switch here could do it.
	final VoidCallback onOpenSystemVpnSettings;

	/// Reads whether the OS itself is currently blocking traffic outside a
	/// VPN, live rather than cached.
	final Future<bool> Function() systemLockdownActive;

	/// Deletes every imported configuration and its stored key.
	final Future<void> Function() onClearConfigurations;

	/// Resets every other local preference, keeping the onboarding flags.
	final VoidCallback onClearLocalData;

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final theme = Theme.of(context);
		return AnimatedBuilder(
			animation: settings,
			builder: (context, _) {
				final d = settings.data;
				// Capped like every other screen. A settings list stretched
				// across a 1440px window puts a toggle switch a metre away from
				// the label that explains it.
				return VgContentColumn(
					child: ListView(
						padding: const EdgeInsets.only(top: VgSpace.sm, bottom: VgSpace.xxl),
						children: [
							VgPanel(
								title: l10n.get('settingsConnection'),
								icon: Icons.shield_outlined,
								uppercase: true,
								padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
								child: Column(
									children: [
										VgChoiceRow(
											title: l10n.get('killSwitch'),
											value: switch (d.killSwitch) {
												KillSwitchMode.off => l10n.get('killSwitchOff'),
												KillSwitchMode.automatic =>
													l10n.get('killSwitchAutomatic'),
												KillSwitchMode.strict => l10n.get('killSwitchStrict'),
											},
											options: {
												l10n.get('killSwitchOff'): () => settings.update(
													(s) => s.copyWith(killSwitch: KillSwitchMode.off),
												),
												l10n.get('killSwitchAutomatic'): () => settings.update(
													(s) => s.copyWith(
														killSwitch: KillSwitchMode.automatic,
													),
												),
												l10n.get('killSwitchStrict'): () => settings.update(
													(s) => s.copyWith(killSwitch: KillSwitchMode.strict),
												),
											},
											note: platform.supportsKillSwitch
													? null
													: l10n.get('settingsKillSwitchUnsupported'),
										),
										if (platform.platformName.startsWith('android'))
											_SystemLockdownRow(
												systemLockdownActive: systemLockdownActive,
												onOpenSystemVpnSettings: onOpenSystemVpnSettings,
											),
										Divider(
											color: theme.colorScheme.outline,
											height: 1,
											indent: VgSpace.lg,
											endIndent: VgSpace.lg,
										),
										VgToggleRow(
											title: l10n.get('reconnect'),
											value: d.reconnectAutomatically,
											onChanged: (v) => settings.update(
												(s) => s.copyWith(reconnectAutomatically: v),
											),
										),
										Divider(
											color: theme.colorScheme.outline,
											height: 1,
											indent: VgSpace.lg,
											endIndent: VgSpace.lg,
										),
										VgToggleRow(
											title: l10n.get('startOnBoot'),
											value: d.startOnBoot,
											enabled: platform.supportsBootStart,
											disabledReason:
												'This platform cannot start the app on system boot.',
											onChanged: (v) =>
												settings.update((s) => s.copyWith(startOnBoot: v)),
										),
									],
								),
							),
							const SizedBox(height: VgSpace.lg),
							VgPanel(
								title: l10n.get('settingsPrivacy'),
								icon: Icons.lock_outline_rounded,
								uppercase: true,
								padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
								child: Column(
									children: [
										VgChoiceRow(
											title: l10n.get('dnsMode'),
											value: switch (d.dnsMode) {
												DnsMode.vpn => l10n.get('dnsVpn'),
												DnsMode.trusted => l10n.get('dnsTrusted'),
												DnsMode.custom => l10n.get('dnsCustom'),
											},
											options: {
												l10n.get('dnsVpn'): () =>
													settings.update((s) => s.copyWith(dnsMode: DnsMode.vpn)),
												l10n.get('dnsTrusted'): () => settings.update(
													(s) => s.copyWith(dnsMode: DnsMode.trusted),
												),
												l10n.get('dnsCustom'): () => settings.update(
													(s) => s.copyWith(dnsMode: DnsMode.custom),
												),
											},
											note: platform.supportsVpnProvidedDns
													? null
													: 'This platform cannot force a resolver while connected.',
										),
										Divider(
											color: theme.colorScheme.outline,
											height: 1,
											indent: VgSpace.lg,
											endIndent: VgSpace.lg,
										),
										VgChoiceRow(
											title: l10n.get('ipv6'),
											value: switch (d.ipv6) {
												Ipv6Mode.block => l10n.get('ipv6Block'),
												Ipv6Mode.preferTunnel => l10n.get('ipv6Prefer'),
												Ipv6Mode.allow => l10n.get('ipv6Allow'),
											},
											options: {
												l10n.get('ipv6Block'): () =>
													settings.update((s) => s.copyWith(ipv6: Ipv6Mode.block)),
												l10n.get('ipv6Prefer'): () => settings.update(
													(s) => s.copyWith(ipv6: Ipv6Mode.preferTunnel),
												),
												l10n.get('ipv6Allow'): () =>
													settings.update((s) => s.copyWith(ipv6: Ipv6Mode.allow)),
											},
											note: d.ipv6 == Ipv6Mode.allow
													? 'Allowing IPv6 without a route through the tunnel is a '
															'known leak. The setting is labelled "may leak" for that '
															'reason.'
													: null,
										),
										Divider(
											color: theme.colorScheme.outline,
											height: 1,
											indent: VgSpace.lg,
											endIndent: VgSpace.lg,
										),
										VgToggleRow(
											title: l10n.get('debugLogging'),
											subtitle: l10n.get('debugLoggingHint'),
											value: d.logVerbosity == LogVerbosity.debug,
											onChanged: (v) => settings.update(
												(s) => s.copyWith(
													logVerbosity: v
														? LogVerbosity.debug
														: LogVerbosity.normal,
												),
											),
										),
									],
								),
							),
							const SizedBox(height: VgSpace.lg),
							VgPanel(
								title: l10n.get('settingsAppearance'),
								icon: Icons.palette_outlined,
								uppercase: true,
								padding: const EdgeInsets.symmetric(vertical: VgSpace.sm),
								child: Column(
									children: [
										VgChoiceRow(
											title: l10n.get('theme'),
											value: switch (d.themeMode) {
												'light' => l10n.get('themeLight'),
												'dark' => l10n.get('themeDark'),
												_ => l10n.get('themeSystem'),
											},
											options: {
												l10n.get('themeLight'): () =>
													settings.update((s) => s.copyWith(themeMode: 'light')),
												l10n.get('themeDark'): () =>
													settings.update((s) => s.copyWith(themeMode: 'dark')),
												l10n.get('themeSystem'): () =>
													settings.update((s) => s.copyWith(themeMode: 'system')),
											},
										),
										Divider(
											color: theme.colorScheme.outline,
											height: 1,
											indent: VgSpace.lg,
											endIndent: VgSpace.lg,
										),
										VgChoiceRow(
											title: l10n.get('animation'),
											value: d.animationLevel,
											options: {
												'full': () => settings.update(
													(s) => s.copyWith(animationLevel: 'full'),
												),
												'reduced': () => settings.update(
													(s) => s.copyWith(animationLevel: 'reduced'),
												),
												'none': () => settings.update(
													(s) => s.copyWith(animationLevel: 'none'),
												),
											},
										),
										Divider(
											color: theme.colorScheme.outline,
											height: 1,
											indent: VgSpace.lg,
											endIndent: VgSpace.lg,
										),
										VgChoiceRow(
											title: l10n.get('language'),
											value: d.language == 'ar' ? 'العربية' : 'English',
											options: {
												'English': () =>
													settings.update((s) => s.copyWith(language: 'en')),
												'العربية': () =>
													settings.update((s) => s.copyWith(language: 'ar')),
											},
										),
									],
								),
							),
							const SizedBox(height: VgSpace.lg),
							// The screens that are not in the phone bottom bar.
							// Linked from here so that trimming the bar to three
							// labels does not make them unreachable on a phone.
							VgPanel(
								title: l10n.get('settingsAdvanced'),
								icon: Icons.tune_rounded,
								uppercase: true,
								padding: const EdgeInsets.symmetric(vertical: VgSpace.xs),
								child: Column(
									children: [
										VgListRow(
											leading: Icon(
												Icons.add_link_rounded,
												color: theme.colorScheme.onSurfaceVariant,
											),
											title: l10n.get('settingsConfigurations'),
											subtitle: l10n.get('settingsConfigurationsHint'),
											onTap: onManageConfigurations,
											showDivider: true,
										),
										VgListRow(
											leading: Icon(
												Icons.insights_outlined,
												color: theme.colorScheme.onSurfaceVariant,
											),
											title: l10n.get('settingsDiagnostics'),
											subtitle: l10n.get('settingsDiagnosticsHint'),
											onTap: onOpenDiagnostics,
											showDivider: true,
										),
										VgListRow(
											leading: Icon(
												Icons.lock_outline_rounded,
												color: theme.colorScheme.onSurfaceVariant,
											),
											title: l10n.get('settingsPrivacyNotice'),
											subtitle: l10n.get('settingsPrivacyNoticeHint'),
											onTap: onOpenPrivacy,
										),
									],
								),
							),
							const SizedBox(height: VgSpace.lg),
							VgSurface(
								child: Row(
									children: [
										Expanded(
											child: Column(
												crossAxisAlignment: CrossAxisAlignment.start,
												mainAxisSize: MainAxisSize.min,
												children: [
													Text(
														l10n.get('clearedata'),
														style: theme.textTheme.bodyLarge,
													),
													const SizedBox(height: 2),
													Text(
														l10n.get('clearedataHint'),
														style: theme.textTheme.bodySmall,
													),
												],
											),
										),
										const SizedBox(width: VgSpace.lg),
										OutlinedButton(
											onPressed: () {
												settings.clearLocalData();
												ScaffoldMessenger.of(context).showSnackBar(
													const SnackBar(
														content: Text('Local data cleared.'),
													),
												);
											},
											child: const Text('Clear'),
										),
									],
								),
							),
							const SizedBox(height: VgSpace.lg),
							VgPanel(
								title: l10n.get('settingsAbout'),
								icon: Icons.info_outline_rounded,
								uppercase: true,
								padding: const EdgeInsets.symmetric(vertical: VgSpace.xs),
								child: Column(
									children: [
										VgListRow(
											title: l10n.get('settingsLicenses'),
											subtitle: l10n.get('settingsLicensesHint'),
											onTap: onOpenLicenses,
											showDivider: true,
										),
										VgListRow(
											title: l10n.get('aboutPortfolio'),
											subtitle: 'laymongames.github.io/portfolio',
											onTap: () async {
												var opened = false;
												try {
													opened = await launchUrl(
														Uri.parse(
															'https://laymongames.github.io/portfolio/',
														),
													);
												} catch (_) {
													opened = false;
												}
												if (!opened && context.mounted) {
													ScaffoldMessenger.of(context)
														.showSnackBar(
														SnackBar(
															content: Text(
																l10n.get('portfolioOpenFailed'),
															),
														),
													);
												}
											},
											showDivider: true,
										),
										Padding(
											padding: const EdgeInsets.symmetric(
												horizontal: VgSpace.lg,
												vertical: VgSpace.md,
											),
											child: Row(
												children: [
													Expanded(
														child: Text(
															l10n.get('aboutCreator'),
															style: theme.textTheme.bodyLarge,
														),
													),
													Text('Laymon Games', style: theme.textTheme.bodyMedium),
												],
											),
										),
										Padding(
											padding: const EdgeInsets.symmetric(
												horizontal: VgSpace.lg,
												vertical: VgSpace.md,
											),
											child: Row(
												children: [
													Expanded(
														child: Text(
															l10n.get('aboutVersion'),
															style: theme.textTheme.bodyLarge,
														),
													),
													Text('1.0.0', style: theme.textTheme.bodyMedium),
												],
											),
										),
									],
								),
							),
							const SizedBox(height: VgSpace.md),
							Text(l10n.get('aboutDisclaimer'), style: theme.textTheme.bodySmall),
						],
					),
				);
			},
		);
	}
}

/// The operating system's own traffic-blocking state, read live.
///
/// This row exists because the app cannot block traffic itself: the only
/// genuine kill switch on stock Android is Always-on VPN with "Block
/// connections without VPN", and it lives in the system settings. So the row
/// reports what the system says and links there, rather than offering a
/// switch here that could not honour itself.
///
/// Shown only on Android. Every other platform has no equivalent reading, and
/// a row that always says "off" with nowhere to enable it would be noise.
class _SystemLockdownRow extends StatefulWidget {
	const _SystemLockdownRow({
		required this.systemLockdownActive,
		required this.onOpenSystemVpnSettings,
	});

	final Future<bool> Function() systemLockdownActive;
	final VoidCallback onOpenSystemVpnSettings;

	@override
	State<_SystemLockdownRow> createState() => _SystemLockdownRowState();
}

class _SystemLockdownRowState extends State<_SystemLockdownRow> {
	late final Future<bool> _active = widget.systemLockdownActive();

	@override
	Widget build(BuildContext context) {
		final l10n = context.l10n;
		final theme = Theme.of(context);
		// The future is created once in `initState`, not on every build: a
		// rebuild caused by an unrelated settings toggle must not flash the
		// row back to "off" while it re-reads. Returning to this screen
		// creates a new state and re-reads, so the value is still live per
		// visit rather than cached for the session.
		return FutureBuilder<bool>(
			future: _active,
			builder: (context, snapshot) {
				final active = snapshot.data ?? false;
				final tone = active ? VgTone.connected : VgTone.idle;
				return Padding(
					padding: const EdgeInsets.symmetric(
						horizontal: VgSpace.lg,
						vertical: VgSpace.md,
					),
					child: Column(
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Row(
								children: [
									Icon(
										active
												? Icons.verified_user_rounded
												: Icons.info_outline_rounded,
										size: VgIcon.sm,
										color: active
												? theme.colorScheme.primary
												: theme.colorScheme.onSurfaceVariant,
									),
									const SizedBox(width: VgSpace.sm),
									Expanded(
										child: Text(
											l10n.get('settingsSystemLockdown'),
											style: theme.textTheme.bodyLarge,
										),
									),
									const SizedBox(width: VgSpace.sm),
									Text(
										active
												? l10n.get('settingsSystemLockdownOn')
												: l10n.get('settingsSystemLockdownOff'),
										style: theme.textTheme.labelMedium?.copyWith(
											color: VgStatusColors.of(
												tone,
												theme.brightness,
											).accent,
											fontWeight: FontWeight.w700,
										),
									),
								],
							),
							const SizedBox(height: VgSpace.xs),
							Text(
								active
										? l10n.get('settingsSystemLockdownOnHint')
										: l10n.get('settingsSystemLockdownOffHint'),
								style: theme.textTheme.bodySmall,
							),
							// The future may still be in flight on first
							// build; the row shows the last-known state
							// (off) rather than a spinner, because a
							// spinner here would read as "protection is
							// being set up" when nothing of the sort is
							// happening.
							if (!active) ...[
								const SizedBox(height: VgSpace.sm),
								OutlinedButton.icon(
									onPressed: widget.onOpenSystemVpnSettings,
									icon: const Icon(Icons.open_in_new_rounded, size: VgIcon.sm),
									label: Text(l10n.get('settingsOpenVpnSettings')),
								),
							],
						],
					),
				);
			},
		);
	}
}