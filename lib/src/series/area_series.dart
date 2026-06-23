import 'dart:typed_data';
import 'dart:ui';

import '../core/coordinate_system.dart';
import '../data/summary.dart';
import 'series.dart';

/// Filled area between a polyline and a baseline.
///
/// Per the spec, fill, gradients and glow are derived only from the
/// summarized vertices — never from the raw buffer — so post-processing
/// remains cheap regardless of source size.
///
/// When [useVertices] is true the area is emitted as a triangle strip via
/// [Vertices.raw] instead of a [Path]. That trades a slight precision loss
/// for a single Skia draw call and is the right pick when an attached
/// [shader] expects barycentric-friendly geometry.
class AreaSeries extends Series {
  AreaSeries({
    required super.id,
    required super.data,
    super.yAxisId,
    this.fillColor = const Color(0x331E88E5),
    this.strokeColor = const Color(0xFF1E88E5),
    this.strokeWidth = 1.5,
    this.baseline = 0.0,
    this.shader,
    this.glow,
    this.useVertices = false,
    this.summary = const SummaryPolicy(),
  });

  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;
  final double baseline;

  /// Optional shader applied to the filled area. When set, [fillColor] is
  /// ignored. Accepts gradients (`ui.Gradient.linear`/`radial`) or a
  /// `FragmentShader` from a compiled `.frag` program.
  final Shader? shader;

  /// Optional outer glow. Rendered as a blurred copy of the summarized line
  /// underneath the area. `null` disables the effect.
  final GlowEffect? glow;

  /// Emit the area as a triangle strip via [Vertices.raw] (one draw call)
  /// instead of a closed [Path]. Recommended when [shader] is set.
  final bool useVertices;

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
    for (var k = 0; k < count; k++) {
      final i = sampledIdx?[k] ?? (range.start + k);
      final o = coords.project(data.xAt(i), data.yAt(i));
      pts[k * 2] = o.dx;
      pts[k * 2 + 1] = o.dy;
    }
    final baseY = coords.project(coords.x.domainMin, baseline).dy;

    if (glow != null) {
      _paintGlow(canvas, pts, count);
    }

    if (useVertices) {
      _paintVertices(canvas, pts, count, baseY, mode);
    } else {
      _paintPath(canvas, pts, count, baseY, mode);
    }

    if (strokeWidth > 0) {
      final stroke = Paint()
        ..color = strokeColor
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = mode == RenderMode.uiRich;
      canvas.drawRawPoints(PointMode.polygon, pts, stroke);
    }
  }

  void _paintPath(
      Canvas canvas, Float32List pts, int count, double baseY, RenderMode m) {
    final path = Path()..moveTo(pts[0], baseY)..lineTo(pts[0], pts[1]);
    for (var k = 1; k < count; k++) {
      path.lineTo(pts[k * 2], pts[k * 2 + 1]);
    }
    path.lineTo(pts[(count - 1) * 2], baseY);
    path.close();

    final fillPaint = Paint()..isAntiAlias = m == RenderMode.uiRich;
    if (shader != null) {
      fillPaint.shader = shader;
    } else {
      fillPaint.color = fillColor;
    }
    canvas.drawPath(path, fillPaint);
  }

  void _paintVertices(
      Canvas canvas, Float32List pts, int count, double baseY, RenderMode m) {
    // Triangle strip alternating between line vertex and its baseline
    // projection: (P0, B0, P1, B1, ...). One draw, no path simplification.
    final strip = Float32List(count * 4);
    for (var k = 0; k < count; k++) {
      strip[k * 4] = pts[k * 2];
      strip[k * 4 + 1] = pts[k * 2 + 1];
      strip[k * 4 + 2] = pts[k * 2];
      strip[k * 4 + 3] = baseY;
    }
    final verts = Vertices.raw(VertexMode.triangleStrip, strip);
    final paint = Paint()..isAntiAlias = m == RenderMode.uiRich;
    if (shader != null) {
      paint.shader = shader;
    } else {
      paint.color = fillColor;
    }
    canvas.drawVertices(verts, BlendMode.srcOver, paint);
    verts.dispose();
  }

  void _paintGlow(Canvas canvas, Float32List pts, int count) {
    final g = glow!;
    final paint = Paint()
      ..color = g.color
      ..strokeWidth = g.thickness
      ..style = PaintingStyle.stroke
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.summa);
    canvas.drawRawPoints(PointMode.polygon, pts, paint);
  }
}

/// Outer-glow descriptor. Applied to the summarized polyline before the fill.
class GlowEffect {
  const GlowEffect({
    this.color = const Color(0x661E88E5),
    this.summa = 6.0,
    this.thickness = 3.0,
  });

  final Color color;
  final double summa;
  final double thickness;
}
