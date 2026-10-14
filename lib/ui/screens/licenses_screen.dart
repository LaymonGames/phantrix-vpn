import 'package:flutter/material.dart';

import '../../notices/generated_third_party_notices.dart';
import '../../notices/third_party_notices.dart';
import '../../theme/tokens.dart';
import '../components/surfaces.dart';
import '../shell.dart';

/// The licences and credits page.
///
/// Everything on this screen is either a string from the localisation map or
/// a line from the generated inventory — nothing is fetched, so the page is
/// fully functional offline. Where the generator could not read a licence
/// from local data, the row says so instead of showing a plausible guess.
class LicensesScreen extends StatelessWidget {
  const LicensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final notices = ThirdPartyNotices.sorted(thirdPartyNotices)
        .toList(growable: false);
    final app = notices
        .where((n) => n.component == 'app')
        .toList(growable: false);

    return VgContentColumn(
      padding: const EdgeInsets.only(top: VgSpace.sm, bottom: VgSpace.xxl),
      child: ListView(
        children: [
          VgSectionHeader(l10n.get('licensesTitle')),
          if (app.isNotEmpty) _AboutCard(notice: app.first),
          const SizedBox(height: VgSpace.md),
          _AttributionCard(),
          for (final component in ThirdPartyNotices.componentOrder)
            if (component != 'app') ..._componentSections(context, component),
          const SizedBox(height: VgSpace.lg),
          Text(
            l10n.get('licensesGeneratedNote'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  List<Widget> _componentSections(BuildContext context, String component) {
    final notices = ThirdPartyNotices.sorted(
      thirdPartyNotices
          .where((n) => n.component == component)
          .toList(growable: false),
    );
    if (notices.isEmpty) {
      return const <Widget>[];
    }
    final title = switch (component) {
      'dart' => context.l10n.get('licensesSectionDart'),
      'android' => context.l10n.get('licensesSectionAndroid'),
      'windows' => context.l10n.get('licensesSectionWindows'),
      'attribution' => context.l10n.get('licensesSectionAttribution'),
      _ => component,
    };
    return <Widget>[
      const SizedBox(height: VgSpace.md),
      VgSectionHeader(title),
      for (final notice in notices) _NoticeCard(notice: notice),
    ];
  }
}

/// A compact, consistently-aligned expandable used for every licence row.
///
/// Built rather than [ExpansionTile] so the header, the chevron and the
/// expanded content share one alignment system: the header is a 16-inset row
/// with the chevron at the trailing edge, the expanded content is separated by
/// a divider and inset by the same 16, and everything is stretched to the same
/// width so nothing drifts toward the leading edge. The chevron is at the
/// trailing side in every direction — it flips with RTL because it is the last
/// child of the row, not a hard-coded position — and the whole header is a
/// comfortable touch target.
class _ExpandableCard extends StatefulWidget {
  const _ExpandableCard({
    required this.title,
    this.subtitle,
    required this.children,
    this.margin = EdgeInsets.zero,
  });

  final Widget title;
  final Widget? subtitle;
  final List<Widget> children;
  final EdgeInsetsGeometry margin;

  @override
  State<_ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<_ExpandableCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: widget.margin,
      child: VgSurface(
        padding: EdgeInsets.zero,
        onTap: () => setState(() => _open = !_open),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VgSpace.lg,
                vertical: VgSpace.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        widget.title,
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: VgSpace.xxs),
                          widget.subtitle!,
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: VgSpace.md),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: VgMotion.fast,
                    curve: VgMotion.standard,
                    child: Icon(
                      Icons.expand_more_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: VgMotion.fast,
              curve: VgMotion.standard,
              alignment: Alignment.topCenter,
              child: _open
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            VgSpace.lg,
                            VgSpace.md,
                            VgSpace.lg,
                            VgSpace.lg,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: widget.children,
                          ),
                        ),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// The top card: what this app is, where it lives, and under which licence.
class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.notice});

  final ThirdPartyNoticeData notice;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = notice.licenseKey == null
        ? null
        : licenseTexts[notice.licenseKey];
    return _ExpandableCard(
      title: Text(
        '${notice.name} ${notice.version ?? ''}'.trim(),
        style: theme.textTheme.titleMedium,
      ),
      subtitle: Text(notice.licenseId, style: theme.textTheme.bodySmall),
      children: [
        if (notice.sourceUrl != null)
          _DataLine(
            label: l10n.get('licensesRepository'),
            value: notice.sourceUrl!,
            selectable: true,
          ),
        _DataLine(
          label: l10n.get('licensesAppLicense'),
          value: notice.licenseId,
        ),
        if (notice.copyright != null)
          _DataLine(
            label: l10n.get('licensesCopyright'),
            value: notice.copyright!,
          ),
        if (text == null)
          _NoLicenseText()
        else
          _LicenceTextBlock(title: notice.licenseId, text: text),
      ],
    );
  }
}

/// The voluntary relay attribution, which is a credit rather than a licence
/// and is stated in the user's own language for that reason.
class _AttributionCard extends StatelessWidget {
  const _AttributionCard();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return VgPanel(
      icon: Icons.volunteer_activism_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.get('licensesVpnGateTitle'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: VgSpace.xs),
          Text(
            l10n.get('licensesVpnGateBody'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// One inventory line, expandable to its full licence text.
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});

  final ThirdPartyNoticeData notice;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = notice.licenseKey == null
        ? null
        : licenseTexts[notice.licenseKey];
    return _ExpandableCard(
      margin: const EdgeInsets.only(bottom: VgSpace.sm),
      title: Text(
        notice.name,
        style: theme.textTheme.bodyLarge,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (notice.version != null) notice.version!,
          notice.licenseId,
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      children: [
        if (notice.sourceUrl != null)
          _DataLine(
            label: l10n.get('licensesSource'),
            value: notice.sourceUrl!,
            selectable: true,
          ),
        if (notice.licenseSource != null)
          _DataLine(
            label: l10n.get('licensesProvenance'),
            value: notice.licenseSource!,
          ),
        if (notice.copyright != null)
          _DataLine(
            label: l10n.get('licensesCopyright'),
            value: notice.copyright!,
          ),
        for (final key in ThirdPartyNotices.noteKeys(notice))
          Padding(
            padding: const EdgeInsets.only(top: VgSpace.sm),
            child: Text(
              l10n.get(key),
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        if (text == null)
          _NoLicenseText()
        else
          _LicenceTextBlock(title: notice.licenseId, text: text),
      ],
    );
  }
}

class _DataLine extends StatelessWidget {
  const _DataLine({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: VgSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: VgSpace.xxs),
          selectable
              ? SelectableText(value, style: theme.textTheme.bodySmall)
              : Text(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Bounded so a 35 KB licence does not grow without limit inside the page.
class _LicenceTextBlock extends StatelessWidget {
  const _LicenceTextBlock({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: VgSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.get('licensesFullText'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: VgSpace.xs),
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            width: double.infinity,
            padding: const EdgeInsets.all(VgSpace.sm),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(VgRadius.sm),
            ),
            child: SingleChildScrollView(
              child: SelectableText.rich(
                TextSpan(
                  text: text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of a licence when the generator could not read one. A row
/// that looks like it has a licence when none was read is the one failure
/// mode this page must not have.
class _NoLicenseText extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: VgSpace.sm),
      child: Text(
        context.l10n.get('licensesMissingText'),
        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
      ),
    );
  }
}
