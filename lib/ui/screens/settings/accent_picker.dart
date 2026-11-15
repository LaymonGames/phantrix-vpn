import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../../theme/tokens.dart';
import '../../shell.dart';

/// The accent colour setting: a row of swatches and a custom hue.
///
/// Swatches rather than a full colour wheel: every preset is checked for
/// contrast in both themes by `test/contrast_test.dart`, and a custom pick
/// only chooses a hue — the app still derives each theme's readable tone of
/// it, so no choice can make the interface unreadable.
class AccentPicker extends StatelessWidget {
  const AccentPicker({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// The current accent as 0xAARRGGBB.
  final int value;
  final ValueChanged<int> onChanged;

  bool get _isPreset =>
      VgAccent.presets.any((p) => p.color.toARGB32() == value);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: VgSpace.md),
      child: Column(
        // Stretched so the picker spans the row like every other setting
        // instead of shrinking to its swatches and centring.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.get('accentColor'), style: theme.textTheme.bodyLarge),
          const SizedBox(height: VgSpace.xxs),
          Text(l10n.get('accentHint'), style: theme.textTheme.bodySmall),
          const SizedBox(height: VgSpace.md),
          Wrap(
            alignment: WrapAlignment.start,
            spacing: VgSpace.xs,
            runSpacing: VgSpace.xs,
            children: [
              for (final preset in VgAccent.presets)
                _Swatch(
                  color: preset.color,
                  label: l10n.get('accent.${preset.id}'),
                  selected: preset.color.toARGB32() == value,
                  onTap: () => onChanged(preset.color.toARGB32()),
                ),
              _Swatch(
                color: _isPreset ? null : Color(value),
                label: l10n.get('accent.custom'),
                selected: !_isPreset,
                onTap: () => _pickCustom(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    final start = HSLColor.fromColor(Color(value)).hue;
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => _CustomAccentDialog(initialHue: start),
    );
    if (picked != null) {
      onChanged(picked);
    }
  }
}

/// One round swatch. The hit area is 44 px even though the colour is 32.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  /// Null draws the rainbow "custom" swatch.
  final Color? color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = color == null
        ? null
        : (Theme.of(context).brightness == Brightness.dark
              ? VgAccent.forDark(color!, scheme.surfaceContainerLow)
              : VgAccent.forLight(color!, against: scheme.surface));
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: AnimatedContainer(
                duration: VgMotion.fast,
                curve: VgMotion.standard,
                width: 34,
                height: 34,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? (display ?? scheme.primary)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: display,
                    gradient: display == null
                        ? const SweepGradient(
                            colors: [
                              Color(0xFFF87171),
                              Color(0xFFFBBF24),
                              Color(0xFF4ADE80),
                              Color(0xFF38BDF8),
                              Color(0xFFA78BFA),
                              Color(0xFFF472B6),
                              Color(0xFFF87171),
                            ],
                          )
                        : null,
                  ),
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: display == null
                              ? Colors.white
                              : VgAccent.onAccent(display),
                        )
                      : (display == null
                            ? const Icon(
                                Icons.add_rounded,
                                size: 16,
                                color: Colors.white,
                              )
                            : null),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomAccentDialog extends StatefulWidget {
  const _CustomAccentDialog({required this.initialHue});

  final double initialHue;

  @override
  State<_CustomAccentDialog> createState() => _CustomAccentDialogState();
}

class _CustomAccentDialogState extends State<_CustomAccentDialog> {
  late double _hue = widget.initialHue;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final raw = VgAccent.fromHue(_hue);
    final preview = theme.brightness == Brightness.dark
        ? VgAccent.forDark(raw, scheme.surfaceContainerLow)
        : VgAccent.forLight(raw, against: scheme.surface);
    return AlertDialog(
      title: Text(l10n.get('accentCustomTitle')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: preview,
                borderRadius: BorderRadius.circular(VgRadius.md),
              ),
              alignment: Alignment.center,
              child: Text(
                l10n.get('connect'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: VgAccent.onAccent(preview),
                ),
              ),
            ),
            const SizedBox(height: VgSpace.lg),
            Text(l10n.get('accentHue'), style: theme.textTheme.labelMedium),
            const SizedBox(height: VgSpace.xs),
            SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    left: 12,
                    right: 12,
                    child: Center(
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: LinearGradient(
                            colors: [
                              for (var h = 0; h <= 360; h += 30)
                                VgAccent.fromHue(h.toDouble()),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.transparent,
                      inactiveTrackColor: Colors.transparent,
                      thumbColor: preview,
                      overlayColor: preview.withValues(alpha: 0.16),
                    ),
                    child: Slider(
                      value: _hue,
                      max: 360,
                      label: '${_hue.round()}°',
                      semanticFormatterCallback: (v) => '${v.round()}°',
                      onChanged: (v) => setState(() => _hue = v),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(VgAccent.phantrixGreen.toARGB32()),
          child: Text(l10n.get('accentReset')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(raw.toARGB32()),
          child: Text(l10n.get('accentUse')),
        ),
      ],
    );
  }
}
