import 'dart:ui';

import '../core/coordinate_system.dart';
import 'series.dart';

/// Horizontal bars anchored at a baseline along the x-axis.
///
/// Data convention: each row's `x` is the **value** (length of the bar)
/// and `y` is the **category index** (0, 1, 2, …). The chart's x-axis
/// represents magnitude; the y-axis represents categories.
///
/// Set the y axis to span `[-0.5, n - 0.5]` and pass a `yFormatter` that
/// maps category indices to labels:
///
/// ```dart
/// PinealChart(
///   xRange: (min: 0, max: maxValue),
///   yAxes: [YAxisSpec(id: 'y', min: -0.5, max: labels.length - 0.5)],
///   series: [HorizontalBarSeries(id: 'h', data: buf)],
///   yFormatter: (v, _) => labels[v.round().clamp(0, labels.length - 1)],
/// )
/// ```
class HorizontalBarSeries extends Series {
  HorizontalBarSeries({
    required super.id,
    required super.data,
    super.yAxisId,
    this.color = const Color(0xFF26A69A),
    this.baseline = 0.0,
    this.heightFactor = 0.7,
    this.cornerRadius = 0.0,
  });

  final Color color;
  final double baseline;

  /// Bar height as a fraction of the spacing between consecutive
  /// categories on the y-axis. Capped at 64 px.
  final double heightFactor;

  /// Rounds the value-side corners (right side for positive bars, left
  /// side for negative).
  final double cornerRadius;

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    if (data.length == 0) return;

    final pxPerUnitY =
        coords.plot.height / (coords.y.domainMax - coords.y.domainMin);
    final spacing = (data.length > 1)
        ? (data.yAt(1) - data.yAt(0)).abs()
        : 1.0;
    final barHeightPx = (spacing * pxPerUnitY * heightFactor).clamp(1.0, 64.0);

    final baseX = coords.project(baseline, 0).dx;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color
      ..isAntiAlias = mode == RenderMode.uiRich;

    for (var i = 0; i < data.length; i++) {
      final cat = data.yAt(i);
      if (cat < coords.y.domainMin || cat > coords.y.domainMax) continue;

      final value = data.xAt(i);
      final valuePx = coords.project(value, cat).dx;
      final categoryPy = coords.project(0, cat).dy;
      final left = valuePx < baseX ? valuePx : baseX;
      final right = valuePx < baseX ? baseX : valuePx;
      final rect = Rect.fromLTRB(
        left,
        categoryPy - barHeightPx * 0.5,
        right,
        categoryPy + barHeightPx * 0.5,
      );

      if (cornerRadius > 0) {
        final isPositive = value >= baseline;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft:
                isPositive ? Radius.zero : Radius.circular(cornerRadius),
            bottomLeft:
                isPositive ? Radius.zero : Radius.circular(cornerRadius),
            topRight:
                isPositive ? Radius.circular(cornerRadius) : Radius.zero,
            bottomRight:
                isPositive ? Radius.circular(cornerRadius) : Radius.zero,
          ),
          paint,
        );
      } else {
        canvas.drawRect(rect, paint);
      }
    }
  }
}
