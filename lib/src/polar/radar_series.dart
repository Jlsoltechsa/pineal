import 'dart:math' as math;
import 'dart:ui';

import 'polar_coordinates.dart';

/// Single radar polygon. Each value is plotted along a radial axis evenly
/// distributed around the circle.
class RadarSeries {
  RadarSeries({
    required this.values,
    required this.maxValue,
    this.fillColor = const Color(0x441E88E5),
    this.strokeColor = const Color(0xFF1E88E5),
    this.strokeWidth = 1.5,
    this.dotRadius = 3.0,
  });

  /// One value per axis.
  final List<double> values;

  /// Domain upper bound — values are divided by this to land in `[0, 1]`.
  /// Pass the max across multiple radar layers so they share scale.
  final double maxValue;

  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;
  final double dotRadius;

  void paint(Canvas canvas, PolarCoordinates coords) {
    final n = values.length;
    if (n < 3) return;
    final step = 2 * math.pi / n;
    final path = Path();
    for (var i = 0; i < n; i++) {
      final normalized = (values[i] / maxValue).clamp(0.0, 1.0);
      final p = coords.project(i * step, normalized);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas
      ..drawPath(path, Paint()..color = fillColor..isAntiAlias = true)
      ..drawPath(
          path,
          Paint()
            ..color = strokeColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..isAntiAlias = true);

    if (dotRadius > 0) {
      final dotPaint = Paint()..color = strokeColor;
      for (var i = 0; i < n; i++) {
        final normalized = (values[i] / maxValue).clamp(0.0, 1.0);
        final p = coords.project(i * step, normalized);
        canvas.drawCircle(p, dotRadius, dotPaint);
      }
    }
  }

  /// Paints the radar's web (concentric rings + radial spokes) once for all
  /// series sharing the same axes. [rings] is the number of concentric
  /// gridlines (excluding the outer boundary which is always drawn).
  static void paintGrid(
    Canvas canvas,
    PolarCoordinates coords, {
    required int axisCount,
    int rings = 4,
    Color color = const Color(0x33889AAB),
    List<String>? labels,
    double labelFontSize = 10,
    Color labelColor = const Color(0xFF9AA4AD),
  }) {
    if (axisCount < 3) return;
    final step = 2 * math.pi / axisCount;
    final gridPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..isAntiAlias = true;

    // Concentric polygons.
    for (var r = 1; r <= rings; r++) {
      final t = r / rings;
      final ringPath = Path();
      for (var i = 0; i < axisCount; i++) {
        final p = coords.project(i * step, t);
        if (i == 0) {
          ringPath.moveTo(p.dx, p.dy);
        } else {
          ringPath.lineTo(p.dx, p.dy);
        }
      }
      ringPath.close();
      canvas.drawPath(ringPath, gridPaint);
    }

    // Radial spokes.
    for (var i = 0; i < axisCount; i++) {
      final outer = coords.project(i * step, 1.0);
      canvas.drawLine(coords.center, outer, gridPaint);
    }

    if (labels != null) {
      for (var i = 0; i < axisCount && i < labels.length; i++) {
        final p = coords.project(i * step, 1.1);
        final pb = ParagraphBuilder(ParagraphStyle(
          fontSize: labelFontSize,
          textAlign: TextAlign.center,
        ))
          ..pushStyle(TextStyle(color: labelColor, fontSize: labelFontSize))
          ..addText(labels[i]);
        final paragraph = pb.build()
          ..layout(const ParagraphConstraints(width: 80));
        canvas.drawParagraph(
            paragraph, Offset(p.dx - 40, p.dy - paragraph.height / 2));
      }
    }
  }
}
