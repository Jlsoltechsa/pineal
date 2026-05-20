import 'dart:math' as math;
import 'dart:ui';

import '../core/coordinate_system.dart';
import 'text_cache.dart';

/// Visual description of an axis. The painter consumes this; widgets build it
/// declaratively when they assemble the chart.
class AxisStyle {
  const AxisStyle({
    this.color = const Color(0xFF666666),
    this.gridColor = const Color(0x22000000),
    this.labelColor = const Color(0xFF333333),
    this.labelFontSize = 11.0,
    this.tickLength = 4.0,
    this.showGrid = true,
    this.showLine = true,
    this.minLabelSpacing = 48.0,
  });

  final Color color;
  final Color gridColor;
  final Color labelColor;
  final double labelFontSize;
  final double tickLength;
  final bool showGrid;
  final bool showLine;

  /// Minimum pixel gap kept between rendered label edges. Ticks themselves
  /// always draw; only the text gets decimated when crowding hits this floor.
  final double minLabelSpacing;
}

/// Side an axis is drawn on. Y axes can stack on left or right; X axes go
/// bottom (top variant left out of v1).
enum AxisPosition { left, right, bottom }

/// Renders an axis (line, ticks, labels, grid).
///
/// The painter caches label layouts in [TextCache]. Tick generation uses the
/// Wilkinson "nice numbers" heuristic so labels land on round values even
/// during zoom.
class AxisPainter {
  AxisPainter({required this.textCache, required this.formatter});

  final TextCache textCache;
  final String Function(double value, Scale scale) formatter;

  void paint(
    Canvas canvas,
    CoordinateSystem coords,
    AxisPosition position,
    AxisStyle style, {
    int targetTicks = 6,
  }) {
    switch (position) {
      case AxisPosition.left:
      case AxisPosition.right:
        _paintY(canvas, coords, position, style, targetTicks);
        break;
      case AxisPosition.bottom:
        _paintX(canvas, coords, style, targetTicks);
        break;
    }
  }

  void _paintX(Canvas canvas, CoordinateSystem coords, AxisStyle style,
      int targetTicks) {
    final plot = coords.plot;
    final ticks = _niceTicks(coords.x.domainMin, coords.x.domainMax, targetTicks);

    final linePaint = Paint()
      ..color = style.color
      ..strokeWidth = 1.0;
    if (style.showLine) {
      canvas.drawLine(
        Offset(plot.left, plot.bottom),
        Offset(plot.right, plot.bottom),
        linePaint,
      );
    }

    final gridPaint = Paint()
      ..color = style.gridColor
      ..strokeWidth = 1.0;

    double? lastLabelRight;
    for (final t in ticks) {
      final px = coords.project(t, coords.y.domainMin).dx;
      if (style.showGrid) {
        canvas.drawLine(
          Offset(px, plot.top),
          Offset(px, plot.bottom),
          gridPaint,
        );
      }
      canvas.drawLine(
        Offset(px, plot.bottom),
        Offset(px, plot.bottom + style.tickLength),
        linePaint,
      );
      final p = textCache.paragraph(
        formatter(t, coords.x),
        fontSize: style.labelFontSize,
        color: style.labelColor,
      );
      final labelLeft = px - p.maxIntrinsicWidth / 2;
      final labelRight = labelLeft + p.maxIntrinsicWidth;
      if (lastLabelRight != null &&
          labelLeft - lastLabelRight < style.minLabelSpacing) {
        continue;
      }
      canvas.drawParagraph(
        p,
        Offset(labelLeft, plot.bottom + style.tickLength + 2),
      );
      lastLabelRight = labelRight;
    }
  }

  void _paintY(Canvas canvas, CoordinateSystem coords, AxisPosition pos,
      AxisStyle style, int targetTicks) {
    final plot = coords.plot;
    final ticks = _niceTicks(coords.y.domainMin, coords.y.domainMax, targetTicks);

    final isLeft = pos == AxisPosition.left;
    final axisX = isLeft ? plot.left : plot.right;

    final linePaint = Paint()
      ..color = style.color
      ..strokeWidth = 1.0;
    if (style.showLine) {
      canvas.drawLine(
        Offset(axisX, plot.top),
        Offset(axisX, plot.bottom),
        linePaint,
      );
    }

    final gridPaint = Paint()
      ..color = style.gridColor
      ..strokeWidth = 1.0;

    // Ticks ascend in data order but pixels descend (yInverted), so we
    // track the previous label's top edge and skip ones that would crowd it
    // from below.
    double? lastLabelTop;
    for (final t in ticks) {
      final py = coords.project(coords.x.domainMin, t).dy;
      if (style.showGrid) {
        canvas.drawLine(
          Offset(plot.left, py),
          Offset(plot.right, py),
          gridPaint,
        );
      }
      canvas.drawLine(
        Offset(axisX - (isLeft ? style.tickLength : -style.tickLength), py),
        Offset(axisX, py),
        linePaint,
      );
      final p = textCache.paragraph(
        formatter(t, coords.y),
        fontSize: style.labelFontSize,
        color: style.labelColor,
      );
      final lx = isLeft
          ? axisX - style.tickLength - 2 - p.maxIntrinsicWidth
          : axisX + style.tickLength + 2;
      final labelTop = py - p.height / 2;
      final labelBottom = labelTop + p.height;
      if (lastLabelTop != null &&
          lastLabelTop - labelBottom < style.minLabelSpacing) {
        continue;
      }
      canvas.drawParagraph(p, Offset(lx, labelTop));
      lastLabelTop = labelTop;
    }
  }

  static List<double> _niceTicks(double min, double max, int target) {
    if (min == max) return [min];
    final span = (max - min).abs();
    final step = _niceStep(span / target);
    final first = (min / step).floor() * step;
    final ticks = <double>[];
    for (var v = first; v <= max + step * 0.5; v += step) {
      if (v >= min - step * 0.5) ticks.add(v);
      if (ticks.length > target * 4) break;
    }
    return ticks;
  }

  static double _niceStep(double raw) {
    final exp = (math.log(raw) / math.ln10).floor();
    final pow10 = math.pow(10, exp).toDouble();
    final frac = raw / pow10;
    final niceFrac = frac < 1.5
        ? 1.0
        : frac < 3.0
            ? 2.0
            : frac < 7.0
                ? 5.0
                : 10.0;
    return niceFrac * pow10;
  }
}

/// Default numeric formatter. Pulls out trailing zeros and uses scientific
/// notation outside a sane range so labels don't overflow the gutter.
String defaultFormatter(double v, Scale scale) {
  if (scale is TimeScale) {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(v.round(), isUtc: false);
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }
  final abs = v.abs();
  if (abs != 0 && (abs < 1e-3 || abs >= 1e6)) {
    return v.toStringAsExponential(2);
  }
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2);
}
