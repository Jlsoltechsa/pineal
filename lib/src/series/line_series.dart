import 'dart:typed_data';
import 'dart:ui';

import '../core/coordinate_system.dart';
import '../data/summary.dart';
import 'series.dart';

/// Stroked polyline. Routes through the high-density GPU path when point
/// density exceeds [SummaryPolicy.activationDensity], otherwise renders the
/// same vertices with anti-aliasing and optional markers.
class LineSeries extends Series {
  LineSeries({
    required super.id,
    required super.data,
    super.yAxisId,
    this.color = const Color(0xFF1E88E5),
    this.strokeWidth = 1.5,
    this.drawMarkers = false,
    this.markerRadius = 3.0,
    this.summary = const SummaryPolicy(),
  });

  final Color color;
  final double strokeWidth;
  final bool drawMarkers;
  final double markerRadius;
  final SummaryPolicy summary;

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    if (data.length < 2) return;

    final range = index.rangeIndices(coords.x.domainMin, coords.x.domainMax);
    final visible = range.end - range.start;
    if (visible < 2) return;

    final sampledIdx =
        summary.maybeSummarize(data, range.start, range.end, coords.plot.width);
    final count = sampledIdx?.length ?? visible;

    final pts = Float32List(count * 2);
    if (sampledIdx == null) {
      var w = 0;
      for (var i = range.start; i < range.end; i++) {
        final o = coords.project(data.xAt(i), data.yAt(i));
        pts[w++] = o.dx;
        pts[w++] = o.dy;
      }
    } else {
      for (var k = 0; k < count; k++) {
        final i = sampledIdx[k];
        final o = coords.project(data.xAt(i), data.yAt(i));
        pts[k * 2] = o.dx;
        pts[k * 2 + 1] = o.dy;
      }
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = mode == RenderMode.uiRich;

    canvas.drawRawPoints(PointMode.polygon, pts, paint);

    if (mode == RenderMode.uiRich && drawMarkers && count <= 512) {
      final markerPaint = Paint()..color = color;
      for (var k = 0; k < count; k++) {
        canvas.drawCircle(
          Offset(pts[k * 2], pts[k * 2 + 1]),
          markerRadius,
          markerPaint,
        );
      }
    }
  }
}
