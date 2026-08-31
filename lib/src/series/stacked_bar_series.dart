import 'dart:ui';

import '../core/coordinate_system.dart';
import '../data/data_buffer.dart';
import 'series.dart';

/// Vertical bars where each category position carries multiple stacked
/// values. Useful for part-of-whole comparisons across categories
/// (e.g. status breakdowns per cohort).
///
/// The underlying [DataBuffer] stores the per-row total so that
/// autorange (`yMin..yMax = ymax of totals`) works out of the box. The
/// per-stack values live in [stacks].
class StackedBarSeries extends Series {
  StackedBarSeries({
    required super.id,
    required List<double> xs,
    required this.stacks,
    required this.colors,
    super.yAxisId,
    this.widthFactor = 0.7,
    this.cornerRadius = 0.0,
  })  : assert(stacks.isNotEmpty, 'StackedBarSeries needs at least one stack'),
        assert(colors.isNotEmpty, 'StackedBarSeries needs at least one color'),
        super(data: _sumBuffer(xs, stacks));

  /// One list per stack, each list aligned to the parallel `xs` passed in
  /// the constructor (same length).
  final List<List<double>> stacks;

  /// One color per stack. Wraps modulo length if shorter than [stacks].
  final List<Color> colors;

  /// Bar width as a fraction of the spacing between consecutive
  /// categories. Capped at 64 px.
  final double widthFactor;

  /// Rounds the top corners of the highest stack. Inner stacks stay
  /// square so they line up flush.
  final double cornerRadius;

  static DataBuffer _sumBuffer(List<double> xs, List<List<double>> stacks) {
    final ys = List<double>.filled(xs.length, 0);
    for (final stack in stacks) {
      assert(stack.length == xs.length,
          'every stack must have the same length as xs');
      for (var i = 0; i < ys.length; i++) {
        ys[i] += stack[i];
      }
    }
    // `xSorted: true` (the default), not false. `paint` culls through
    // `index.rangeIndices`, which binary-searches and asserts `xSorted` — so
    // declaring the buffer unsorted made every paint throw in debug while the
    // release build silently binary-searched anyway. This series *requires*
    // ascending x (it draws one bar per category slot), so the honest fix is to
    // state that requirement and check it.
    assert(_ascending(xs), 'StackedBarSeries requires ascending xs');
    return DataBuffer.fromXY(xs, ys);
  }

  static bool _ascending(List<double> xs) {
    for (var i = 1; i < xs.length; i++) {
      if (xs[i] < xs[i - 1]) return false;
    }
    return true;
  }

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    if (data.length == 0 || stacks.isEmpty) return;
    final range = index.rangeIndices(coords.x.domainMin, coords.x.domainMax);
    if (range.end - range.start == 0) return;

    final pxPerUnitX =
        coords.plot.width / (coords.x.domainMax - coords.x.domainMin);
    final spacing = (data.length > 1)
        ? (data.xAt(1) - data.xAt(0)).abs()
        : 1.0;
    final barWidthPx = (spacing * pxPerUnitX * widthFactor).clamp(1.0, 64.0);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = mode == RenderMode.uiRich;

    final lastStack = stacks.length - 1;

    for (var i = range.start; i < range.end; i++) {
      final cx = coords.project(data.xAt(i), 0).dx;
      var cumulative = 0.0;
      for (var s = 0; s < stacks.length; s++) {
        final v = stacks[s][i];
        if (v == 0) continue;
        final yBottom = coords.project(0, cumulative).dy;
        cumulative += v;
        final yTop = coords.project(0, cumulative).dy;
        paint.color = colors[s % colors.length];
        final rect = Rect.fromLTRB(
          cx - barWidthPx * 0.5,
          yTop < yBottom ? yTop : yBottom,
          cx + barWidthPx * 0.5,
          yTop < yBottom ? yBottom : yTop,
        );
        if (cornerRadius > 0 && s == lastStack) {
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              rect,
              topLeft: Radius.circular(cornerRadius),
              topRight: Radius.circular(cornerRadius),
            ),
            paint,
          );
        } else {
          canvas.drawRect(rect, paint);
        }
      }
    }
  }
}
