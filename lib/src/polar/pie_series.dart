import 'dart:math' as math;
import 'dart:ui';

import 'polar_coordinates.dart';

/// Pie or donut series. One value per slice; angles are derived from each
/// value's share of the total.
class PieSeries {
  PieSeries({
    required this.values,
    this.colors,
    this.innerRadius = 0.0,
    this.outerRadius = 1.0,
    this.padAngle = 0.0,
    this.labelOf,
  });

  /// One double per slice. Negative values are clamped to zero.
  final List<double> values;

  /// Per-slice fill colors. If shorter than [values], wraps modulo length.
  final List<Color>? colors;

  /// 0..1, fraction of outer radius. 0 = full pie, >0 = donut.
  final double innerRadius;

  /// 0..1, normally 1. Useful to leave room for labels outside.
  final double outerRadius;

  /// Gap between slices in radians.
  final double padAngle;

  final String Function(int sliceIndex, double value)? labelOf;

  static const _defaultPalette = <Color>[
    Color(0xFF42A5F5),
    Color(0xFFEF5350),
    Color(0xFF66BB6A),
    Color(0xFFFFCA28),
    Color(0xFFAB47BC),
    Color(0xFF26A69A),
    Color(0xFFFF7043),
    Color(0xFF8D6E63),
  ];

  void paint(Canvas canvas, PolarCoordinates coords) {
    final total = values.fold<double>(
        0, (a, b) => a + (b.isFinite && b > 0 ? b : 0));
    if (total <= 0 || values.isEmpty) return;

    final palette = colors ?? _defaultPalette;
    final r = coords.maxRadius;
    final innerR = innerRadius * r;
    final outerR = outerRadius * r;

    var angle = 0.0;
    for (var i = 0; i < values.length; i++) {
      final v = values[i] > 0 ? values[i] : 0;
      final sweep = (v / total) * 2 * math.pi - padAngle;
      if (sweep <= 0) {
        angle += (v / total) * 2 * math.pi;
        continue;
      }

      final path = Path();
      final a0 = coords.clockwise
          ? coords.startAngle + angle
          : coords.startAngle - angle;
      final a1 = coords.clockwise
          ? coords.startAngle + angle + sweep
          : coords.startAngle - angle - sweep;

      // Outer arc.
      final startOuter = Offset(
          coords.center.dx + math.cos(a0) * outerR,
          coords.center.dy + math.sin(a0) * outerR);
      path.moveTo(startOuter.dx, startOuter.dy);
      path.arcTo(
        Rect.fromCircle(center: coords.center, radius: outerR),
        a0,
        coords.clockwise ? sweep : -sweep,
        false,
      );
      // Inner arc (reverse) or line back to center.
      if (innerR > 0) {
        path.lineTo(
          coords.center.dx + math.cos(a1) * innerR,
          coords.center.dy + math.sin(a1) * innerR,
        );
        path.arcTo(
          Rect.fromCircle(center: coords.center, radius: innerR),
          a1,
          coords.clockwise ? -sweep : sweep,
          false,
        );
      } else {
        path.lineTo(coords.center.dx, coords.center.dy);
      }
      path.close();

      final paint = Paint()
        ..color = palette[i % palette.length]
        ..isAntiAlias = true;
      canvas.drawPath(path, paint);

      angle += (v / total) * 2 * math.pi;
    }
  }

  /// Returns the slice index under [pixel] or -1.
  int hitTest(Offset pixel, PolarCoordinates coords) {
    final total = values.fold<double>(
        0, (a, b) => a + (b.isFinite && b > 0 ? b : 0));
    if (total <= 0) return -1;
    var angle = 0.0;
    for (var i = 0; i < values.length; i++) {
      final v = values[i] > 0 ? values[i] : 0;
      final sweep = (v / total) * 2 * math.pi;
      if (coords.hitSector(pixel, angle, angle + sweep, innerRadius,
          outerRadius)) {
        return i;
      }
      angle += sweep;
    }
    return -1;
  }
}
