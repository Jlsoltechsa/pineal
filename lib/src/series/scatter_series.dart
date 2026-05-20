import 'dart:typed_data';
import 'dart:ui';

import '../core/coordinate_system.dart';
import 'series.dart';

/// Scatter plot — an unordered cloud of points with optional per-point
/// color and radius. Unlike [LineSeries] with `drawMarkers: true`, no
/// polyline connects the points.
///
/// Two render paths:
///
/// 1. **Uniform** (default) — when [colorOf] and [radiusOf] are null the
///    visible points are batched into a single `drawRawPoints` call with
///    `strokeWidth = radius * 2`. Cost is proportional to point count
///    and stays under one draw call.
/// 2. **Per-point styling** — when either callback is provided the
///    painter falls back to one `drawCircle` per visible point. Use this
///    when the visual encodes a third channel (size for magnitude,
///    color for category, etc.).
class ScatterSeries extends Series {
  ScatterSeries({
    required super.id,
    required super.data,
    super.yAxisId,
    this.color = const Color(0xFF1E88E5),
    this.radius = 3.0,
    this.colorOf,
    this.radiusOf,
  });

  /// Uniform fill color, used when [colorOf] is null.
  final Color color;

  /// Uniform radius in pixels, used when [radiusOf] is null.
  final double radius;

  /// Per-point color. Receives the data index, returns a color (or null
  /// to fall back to [color]).
  final Color? Function(int index)? colorOf;

  /// Per-point radius. Receives the data index, returns a radius in
  /// pixels (or null to fall back to [radius]).
  final double? Function(int index)? radiusOf;

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    if (data.length == 0) return;

    // Spatial index is x-sorted; for scatter we still cull by x so
    // off-screen points don't reach the canvas.
    final range = index.rangeIndices(coords.x.domainMin, coords.x.domainMax);
    final count = range.end - range.start;
    if (count == 0) return;

    final aa = mode == RenderMode.uiRich;

    if (colorOf == null && radiusOf == null) {
      // Fast path — one drawRawPoints call.
      final pts = Float32List(count * 2);
      var w = 0;
      for (var i = range.start; i < range.end; i++) {
        final o = coords.project(data.xAt(i), data.yAt(i));
        pts[w++] = o.dx;
        pts[w++] = o.dy;
      }
      final paint = Paint()
        ..color = color
        ..strokeCap = StrokeCap.round
        ..strokeWidth = radius * 2
        ..isAntiAlias = aa;
      canvas.drawRawPoints(PointMode.points, pts, paint);
      return;
    }

    // Slow path — per-point styling.
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = aa;
    for (var i = range.start; i < range.end; i++) {
      final o = coords.project(data.xAt(i), data.yAt(i));
      paint.color = colorOf?.call(i) ?? color;
      final r = radiusOf?.call(i) ?? radius;
      canvas.drawCircle(o, r, paint);
    }
  }
}
