part of 'locations_screen.dart';

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => VgSegment(
    label: label,
    selected: selected,
    onTap: onSelected,
    // No tick: a sort filter has no value to assert. It is marked by its
    // fill and its border, which is enough to read at a glance and leaves
    // the tick to mean "this is the value" wherever a value exists.
    selectedIcon: null,
  );
}
