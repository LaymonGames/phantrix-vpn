import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// A lightweight abstract world map.
///
/// Markers are real server positions, not decoration. When the directory has
/// no server in a place there is no marker there, so the map is a projection of
/// the same data the list uses and never implies coverage that does not exist.
///
/// The landmass is drawn from a coarse equirectangular projection rather than a
/// full vector atlas, because a large map asset costs mobile start-up time for
/// something that is only ever a backdrop.
class GlobeMap extends StatelessWidget {
  const GlobeMap({required this.servers, this.animate = true, super.key});

  final List<MapServer> servers;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(VgRadius.lg),
      child: CustomPaint(
        painter: _MapPainter(
          servers: servers,
          gridColor: theme.colorScheme.outline,
          landColor: theme.colorScheme.surfaceContainerHigh,
          // The connected colour, not a literal: a marker means "there
          // is a server here", and that is the same claim the rest of
          // the app makes in this hue.
          markerColor: theme.brightness == Brightness.dark
              ? VgColors.connected
              : VgColors.lightConnected,
          // Driven by the wall clock rather than an
          // `AnimationController`: a controller here would repeat
          // forever, which never lets the frame scheduler idle and
          // makes any test that waits for the UI to settle time out.
          pulse: animate
              ? (DateTime.now().millisecondsSinceEpoch %
                        VgMotion.orbit.inMilliseconds) /
                    VgMotion.orbit.inMilliseconds
              : 1,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// A server to plot.
class MapServer {
  const MapServer({
    required this.latitude,
    required this.longitude,
    required this.label,
    this.countryCode,
  });

  final double latitude;
  final double longitude;
  final String label;
  final String? countryCode;
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.servers,
    required this.gridColor,
    required this.landColor,
    required this.markerColor,
    required this.pulse,
  });

  final List<MapServer> servers;
  final Color gridColor;
  final Color landColor;
  final Color markerColor;
  final double pulse;

  /// Very coarse outlines, normalised to 0..1.
  ///
  /// A production map would ship a vector asset; this is intentionally crude
  /// so the file stays small and the projection is obvious.
  static const List<List<Offset>> _land = [
    [
      Offset(0.46, 0.30),
      Offset(0.56, 0.28),
      Offset(0.60, 0.40),
      Offset(0.56, 0.72),
      Offset(0.50, 0.76),
      Offset(0.46, 0.58),
      Offset(0.44, 0.38),
    ],
    [
      Offset(0.56, 0.18),
      Offset(0.80, 0.16),
      Offset(0.84, 0.40),
      Offset(0.72, 0.44),
      Offset(0.60, 0.34),
    ],
    [
      Offset(0.12, 0.16),
      Offset(0.26, 0.14),
      Offset(0.30, 0.46),
      Offset(0.24, 0.72),
      Offset(0.18, 0.68),
      Offset(0.22, 0.40),
    ],
    [
      Offset(0.78, 0.66),
      Offset(0.90, 0.64),
      Offset(0.90, 0.74),
      Offset(0.78, 0.74),
    ],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 1; i < 6; i++) {
      final y = size.height * (i / 6);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 12; i++) {
      final x = size.width * (i / 12);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    final land = Paint()..color = landColor;
    for (final polygon in _land) {
      final path = Path()
        ..moveTo(polygon.first.dx * size.width, polygon.first.dy * size.height);
      for (final point in polygon.skip(1)) {
        path.lineTo(point.dx * size.width, point.dy * size.height);
      }
      path.close();
      canvas.drawPath(path, land);
    }

    final ring = Paint()
      ..color = markerColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final dot = Paint()..color = markerColor;

    for (final server in servers) {
      final x = ((server.longitude + 180) / 360 * size.width).clamp(
        4.0,
        size.width - 4,
      );
      final y = ((90 - server.latitude) / 180 * size.height).clamp(
        4.0,
        size.height - 4,
      );
      final center = Offset(x, y);
      canvas.drawCircle(center, 3, dot);
      canvas.drawCircle(center, 4 + pulse * 10, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.pulse != pulse || !_same(old.servers, servers);

  static bool _same(List<MapServer> a, List<MapServer> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
