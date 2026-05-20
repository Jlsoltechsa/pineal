import 'dart:typed_data';
import 'dart:ui';

import '../core/coordinate_system.dart';
import 'series.dart';

/// Vertical bars anchored at a baseline. Visible-range culling keeps the
/// cost proportional to what's on screen, not to the size of the buffer.
class BarSeries extends Series {
  BarSeries({
    required super.id,
    required super.data,
    super.yAxisId,
    this.color = const Color(0xFF26A69A),
    this.baseline = 0.0,
    this.widthFactor = 0.7,
  });

  final Color color;
  final double baseline;

  /// Bar width as a fraction of the spacing between consecutive samples.
  final double widthFactor;

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    if (data.length == 0) return;
    final range = index.rangeIndices(coords.x.domainMin, coords.x.domainMax);
    final visible = range.end - range.start;
    if (visible == 0) return;

    final pxPerUnit = coords.plot.width / (coords.x.domainMax - coords.x.domainMin);
    final spacing = (visible > 1)
        ? (data.xAt(range.start + 1) - data.xAt(range.start)).abs()
        : 1.0;
    final barWidthPx = (spacing * pxPerUnit * widthFactor).clamp(1.0, 64.0);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = mode == RenderMode.uiRich;

    if (visible > 4096) {
      // Batch-fill via raw triangles for very dense bar charts.
      final tris = Float32List(visible * 12);
      var w = 0;
      final baseY = coords.project(coords.x.domainMin, baseline).dy;
      for (var i = range.start; i < range.end; i++) {
        final top = coords.project(data.xAt(i), data.yAt(i));
        final l = top.dx - barWidthPx * 0.5;
        final r = top.dx + barWidthPx * 0.5;
        tris[w++] = l;       tris[w++] = top.dy;
        tris[w++] = r;       tris[w++] = top.dy;
        tris[w++] = l;       tris[w++] = baseY;
        tris[w++] = r;       tris[w++] = top.dy;
        tris[w++] = r;       tris[w++] = baseY;
        tris[w++] = l;       tris[w++] = baseY;
      }
      final verts = Vertices.raw(VertexMode.triangles, tris);
      canvas.drawVertices(verts, BlendMode.srcOver, paint);
      verts.dispose();
      return;
    }

    final baseY = coords.project(coords.x.domainMin, baseline).dy;
    for (var i = range.start; i < range.end; i++) {
      final top = coords.project(data.xAt(i), data.yAt(i));
      canvas.drawRect(
        Rect.fromLTRB(
          top.dx - barWidthPx * 0.5,
          top.dy < baseY ? top.dy : baseY,
          top.dx + barWidthPx * 0.5,
          top.dy < baseY ? baseY : top.dy,
        ),
        paint,
      );
    }
  }
}
