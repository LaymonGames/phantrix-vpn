import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notices/generated_third_party_notices.dart';
import '../../notices/third_party_notices.dart';
import '../../theme/tokens.dart';
import '../components/rows.dart';
import '../components/surfaces.dart';
import '../shell.dart';

/// The licences and credits page.
///
/// Everything on this screen is either a string from the localisation map or
/// a line from the generated inventory — nothing is fetched, so the page is
/// fully functional offline. Where the generator could not read a licence
/// from local data, the row says so instead of showing a plausible guess.
///
/// ## Why the inventory is not written here
///
/// The list is [thirdPartyNotices], generated from this repository's
/// lockfiles, Gradle files and bundled-binary notices by
/// `tools/generate_third_party_notices.dart` and checked for freshness in CI.
/// A hand-kept list on this screen would be a second inventory that silently
/// drifts from the dependencies the build actually resolves, which is the one
/// failure a credits page cannot have.
///
/// ## What the page owes the user
///
/// GPL-3.0's "Appropriate Legal Notices" for an interactive program are the
/// copyright notice, a statement that there is no warranty, and a way to view
/// the licence. All three are on this screen: the licence identifier and
/// copyright are read from the inventory, the no-warranty sentence is in
/// [licensesIntro], and the complete text of every licence is one tap away —
/// including the GPL-3.0 text of this application itself.
class LicensesScreen extends StatefulWidget {
  const LicensesScreen({
    this.notices = thirdPartyNotices,
    this.reducedMotion = false,
    super.key,
  });

  /// The inventory to render.
  ///
  /// Defaults to the generated one. Overridable so a test can drive the paths
  /// a fixed inventory cannot reach — an entry the generator could not read a
  /// licence for, or one whose caveats have no sentence — without editing a
  /// generated file to create a case that does not exist.
  final List<ThirdPartyNoticeData> notices;

  /// Suppresses the chevron rotation.
  final bool reducedMotion;

  @override
  State<LicensesScreen> createState() => _LicensesScreenState();
}

class _LicensesScreenState extends State<LicensesScreen> {
  final TextEditingController _search = TextEditingController();

  /// The identities of the entries the user has opened.
  ///
  /// Held here rather than inside each card so that typing in the search
  /// field, which rebuilds and reorders the list, cannot leave one
  /// component's expanded licence attached to another component's header.
  final Set<String> _open = <String>{};

  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  void _toggle(String identity) {
    setState(() {
      if (!_open.remove(identity)) {
        _open.add(identity);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final searching = _query.trim().isNotEmpty;
    // Filtered, then grouped by the order the inventory declares. Searching
    // narrows the list; it never reorders it.
    final matches = ThirdPartyNotices.search(widget.notices, _query);
    final app = ThirdPartyNotices.app(matches);
    final rows = matches
        .where((notice) => notice.component != 'app')
        .toList(growable: false);

    return VgContentColumn(
      child: ListView(
        padding: const EdgeInsets.only(top: VgSpace.xs, bottom: VgSpace.xxl),
        children: [
          VgSectionHeader(l10n.get('licensesTitle')),
          Text(l10n.get('licensesIntro'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: VgSpace.md),
          VgNote(
            message: l10n.get('licensesGeneratedNote'),
            icon: Icons.auto_awesome_outlined,
          ),
          const SizedBox(height: VgSpace.lg),
          VgPanel(
            padding: const EdgeInsets.all(VgSpace.md),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.get('licensesSearchHint'),
                prefixIcon: const Icon(Icons.search_rounded, size: VgIcon.md),
                suffixIcon: searching
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: l10n.get('licensesSearchClear'),
                        onPressed: _clearSearch,
                      )
                    : null,
              ),
            ),
          ),
          const SizedBox(height: VgSpace.lg),
          if (app != null) ...[
            _AppLicencePanel(notice: app, reducedMotion: widget.reducedMotion),
            const SizedBox(height: VgSpace.md),
          ],
          // The standing prose is about this build rather than about one
          // component, so a search for a package name hides it and leaves
          // the results on their own.
          if (!searching) ...[
            _FrameworkRow(notice: app),
            const SizedBox(height: VgSpace.md),
            const _VpnGateCredit(),
            const SizedBox(height: VgSpace.md),
          ],
          ..._sections(rows),
          if (searching && matches.isEmpty)
            VgEmptyState(
              icon: Icons.search_off_rounded,
              title: l10n.get('licensesEmptyTitle'),
              message: l10n.get('licensesEmptyBody', {'query': _query.trim()}),
              actionLabel: l10n.get('licensesSearchClear'),
              onAction: _clearSearch,
            ),
        ],
      ),
    );
  }

  /// One heading and its rows per inventory component, in the order
  /// [ThirdPartyNotices.componentOrder] declares.
  List<Widget> _sections(List<ThirdPartyNoticeData> rows) {
    final widgets = <Widget>[];
    for (final component in ThirdPartyNotices.componentOrder) {
      if (component == 'app') {
        continue;
      }
      final notices = rows
          .where((notice) => notice.component == component)
          .toList(growable: false);
      if (notices.isEmpty) {
        continue;
      }
      widgets
        ..add(VgSectionHeader(_sectionTitle(component)))
        ..addAll([
          for (final notice in notices)
            _NoticeCard(
              notice: notice,
              open: _open.contains(notice.identity),
              onToggle: () => _toggle(notice.identity),
              reducedMotion: widget.reducedMotion,
            ),
        ]);
    }
    if (widgets.isEmpty) {
      return const <Widget>[];
    }
    return <Widget>[const SizedBox(height: VgSpace.md), ...widgets];
  }

  String _sectionTitle(String component) {
    final l10n = context.l10n;
    return switch (component) {
      'dart' => l10n.get('licensesSectionDart'),
      'android' => l10n.get('licensesSectionAndroid'),
      'windows' => l10n.get('licensesSectionWindows'),
      'attribution' => l10n.get('licensesSectionAttribution'),
      _ => component,
    };
  }
}

/// The application's own licence, kept at the top and always open.
///
/// Deliberately not collapsed: the licence of the program the user is running
/// is the one notice that must not sit behind an interaction.
class _AppLicencePanel extends StatelessWidget {
  const _AppLicencePanel({required this.notice, required this.reducedMotion});

  final ThirdPartyNoticeData notice;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = _textFor(notice);
    return VgPanel(
      title: l10n.get('licensesAppHeading'),
      icon: Icons.gavel_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${notice.name} ${notice.version ?? ''}'.trim(),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: VgSpace.sm),
          _DataLine(
            label: l10n.get('licensesAppLicense'),
            value: notice.licenseId,
          ),
          if (notice.copyright != null)
            _DataLine(
              label: l10n.get('licensesCopyright'),
              value: notice.copyright!,
            ),
          if (notice.sourceUrl != null)
            _DataLine(
              label: l10n.get('licensesRepository'),
              value: notice.sourceUrl!,
              copyable: true,
              onOpen: () => _openLink(context, notice.sourceUrl!),
            ),
          if (notice.licenseSource != null)
            _DataLine(
              label: l10n.get('licensesProvenance'),
              value: notice.licenseSource!,
            ),
          for (final key in ThirdPartyNotices.noteKeys(notice))
            _Note(text: l10n.get(key)),
          if (text == null)
            const _NoLicenseText()
          else
            _LicenceTextBlock(text: text),
        ],
      ),
    );
  }
}

/// The one row that cannot come from the inventory.
///
/// The Flutter engine and framework ship their own aggregated notices with
/// the engine binary, and Flutter exposes them through `LicenseRegistry`.
/// That registry is the authoritative list for the SDK, so the page links to
/// Flutter's own renderer of it rather than copying those notices into a
/// generated file that would then need regenerating on every SDK bump.
class _FrameworkRow extends StatelessWidget {
  const _FrameworkRow({this.notice});

  /// The application entry, whose version and pseudonym Flutter's own licence
  /// page repeats in its header. Null only in a test that supplies an
  /// inventory without one.
  final ThirdPartyNoticeData? notice;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return VgSurface(
      padding: EdgeInsets.zero,
      child: VgListRow(
        leading: const Icon(Icons.widgets_outlined),
        title: l10n.get('licensesFrameworkTitle'),
        subtitle: l10n.get('licensesFrameworkHint'),
        onTap: () => showLicensePage(
          context: context,
          applicationName: l10n.get('appTitle'),
          applicationVersion: notice?.version,
          applicationLegalese: notice?.copyright,
        ),
      ),
    );
  }
}

/// The voluntary relay credit.
///
/// This is a credit rather than a licence obligation, and it is written in
/// the user's own language for that reason: it asks them to remember that the
/// free servers are other people's machines.
class _VpnGateCredit extends StatelessWidget {
  const _VpnGateCredit();

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
  const _NoticeCard({
    required this.notice,
    required this.open,
    required this.onToggle,
    required this.reducedMotion,
  });

  final ThirdPartyNoticeData notice;
  final bool open;
  final VoidCallback onToggle;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = _textFor(notice);
    return _ExpandableCard(
      open: open,
      onToggle: onToggle,
      reducedMotion: reducedMotion,
      title: Text(
        notice.name,
        style: theme.textTheme.bodyLarge,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      // The version and the licence identifier on one line: the two facts a
      // reader scans a credits list for.
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
            copyable: true,
            onOpen: () => _openLink(context, notice.sourceUrl!),
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
          _Note(text: l10n.get(key)),
        if (text == null)
          const _NoLicenseText()
        else
          _LicenceTextBlock(text: text),
      ],
    );
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
class _ExpandableCard extends StatelessWidget {
  const _ExpandableCard({
    required this.title,
    required this.children,
    required this.open,
    required this.onToggle,
    required this.reducedMotion,
    this.subtitle,
  });

  final Widget title;
  final Widget? subtitle;
  final List<Widget> children;
  final bool open;
  final VoidCallback onToggle;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = reducedMotion ? Duration.zero : VgMotion.fast;
    return Padding(
      padding: const EdgeInsets.only(bottom: VgSpace.sm),
      child: VgSurface(
        padding: EdgeInsets.zero,
        onTap: onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The header carries the expanded state in its semantics as well
            // as in the chevron, so a screen reader hears whether the row is
            // open rather than only that it is a button.
            Semantics(
              button: true,
              expanded: open,
              child: Padding(
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
                          title,
                          if (subtitle != null) ...[
                            const SizedBox(height: VgSpace.xxs),
                            subtitle!,
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: VgSpace.md),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: duration,
                      curve: VgMotion.standard,
                      child: Icon(
                        Icons.expand_more_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // The reveal itself is not animated. An `AnimatedSize` here
            // asserts ("a RenderAnimatedSize was mutated in its own
            // performLayout") because the revealed subtree contains a bounded
            // scroll region whose height is only known during layout; the
            // chevron rotation carries the state change instead, which is a
            // transform and cannot perturb layout.
            if (open)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(color: theme.colorScheme.outline, height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      VgSpace.lg,
                      VgSpace.md,
                      VgSpace.lg,
                      VgSpace.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: children,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// A labelled fact, optionally with a link to where it came from.
class _DataLine extends StatelessWidget {
  const _DataLine({
    required this.label,
    required this.value,
    this.copyable = false,
    this.onOpen,
  });

  final String label;
  final String value;

  /// Renders the value as selectable text, for a URL or a path a reader may
  /// want to copy rather than retype.
  final bool copyable;

  /// Opens [value] in the browser. An explicit button rather than a tap on
  /// the whole line, so the text stays selectable and the row does not turn
  /// into a link the user did not ask for.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.bodySmall;
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: copyable
                    ? SelectableText(value, style: valueStyle)
                    : Text(value, style: valueStyle),
              ),
              if (onOpen != null)
                IconButton(
                  icon: const Icon(Icons.open_in_new_rounded, size: VgIcon.sm),
                  tooltip: context.l10n.get('licensesOpenLink'),
                  visualDensity: VisualDensity.compact,
                  onPressed: onOpen,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bounded so a 35 KB licence does not grow without limit inside the page.
class _LicenceTextBlock extends StatelessWidget {
  const _LicenceTextBlock({required this.text});

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

/// One of the inventory's machine-readable caveats, as a real sentence.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: VgSpace.sm),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
      ),
    );
  }
}

/// Shown instead of a licence when the generator could not read one. A row
/// that looks like it has a licence when none was read is the one failure
/// mode this page must not have.
class _NoLicenseText extends StatelessWidget {
  const _NoLicenseText();

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

/// The licence text [notice] points at, or null when the generator found none.
String? _textFor(ThirdPartyNoticeData notice) {
  final key = notice.licenseKey;
  return key == null ? null : licenseTexts[key];
}

/// Opens [url] in the user's browser, saying so when it could not be opened.
///
/// A credits page whose links fail silently is worse than one with no links:
/// the reader is left thinking they saw everything there is.
Future<void> _openLink(BuildContext context, String url) async {
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    opened = false;
  }
  if (opened || !context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(context.l10n.get('licensesOpenFailed'))),
  );
}
