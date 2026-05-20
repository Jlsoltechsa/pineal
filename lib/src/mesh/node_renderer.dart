import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'node_buffer.dart';

class NodeStyle {
  const NodeStyle({
    this.fill = const Color(0xFFFFFFFF),
    this.stroke = const Color(0xFF222222),
    this.strokeWidth = 1.0,
    this.batchThreshold = 256,
    this.colorOf,
    this.radiusOf,
  });

  final Color fill;
  final Color stroke;
  final double strokeWidth;

  /// Above this count the renderer batches circles via [Vertices.raw]
  /// (triangle fan per node) instead of `drawCircle` per item.
  final int batchThreshold;

  /// Per-node color override. `null` means "use [fill]".
  final Color Function(int index)? colorOf;

  /// Per-node radius override. `null` means "use the radius stored in
  /// [NodeBuffer]".
  final double Function(int index)? radiusOf;
}

class NodeRenderer {
  NodeRenderer({required this.style});

  NodeStyle style;

  /// Indices that should NOT be drawn as primitives because a custom widget
  /// is going to render over them (container nodes). The painter still
  /// draws their stroke ring so the widget has a frame to sit in.
  Set<int> widgetBackedIndices = const <int>{};

  void paint(Canvas canvas, NodeBuffer nodes) {
    if (nodes.length == 0) return;
    final bigBatch = nodes.length >= style.batchThreshold &&
        style.colorOf == null &&
        widgetBackedIndices.isEmpty;
    if (bigBatch) {
      _paintBatched(canvas, nodes);
    } else {
      _paintPerNode(canvas, nodes);
    }
  }

  void _paintPerNode(Canvas canvas, NodeBuffer nodes) {
    final fillPaint = Paint()..isAntiAlias = true;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.strokeWidth
      ..color = style.stroke
      ..isAntiAlias = true;

    for (var i = 0; i < nodes.length; i++) {
      final center = Offset(nodes.x(i), nodes.y(i));
      final r = style.radiusOf?.call(i) ?? nodes.r(i);
      final isWidget = widgetBackedIndices.contains(i);
      if (!isWidget) {
        fillPaint.color = style.colorOf?.call(i) ?? style.fill;
        canvas.drawCircle(center, r, fillPaint);
      }
      if (style.strokeWidth > 0) {
        canvas.drawCircle(center, r, strokePaint);
      }
    }
  }

  /// Single `drawVertices` call for all node fills (no per-node stroke in
  /// this path — stroke runs as a second pass via stroked vertices).
  void _paintBatched(Canvas canvas, NodeBuffer nodes) {
    const int segments = 16;
    const fanSize = segments + 2; // center + ring
    final verts = Float32List(nodes.length * fanSize * 2);
    final indices = Uint16List(nodes.length * segments * 3);

    var vWrite = 0;
    var iWrite = 0;
    for (var n = 0; n < nodes.length; n++) {
      final cx = nodes.x(n);
      final cy = nodes.y(n);
      final r = style.radiusOf?.call(n) ?? nodes.r(n);
      final baseVertex = n * fanSize;
      verts[vWrite++] = cx;
      verts[vWrite++] = cy;
      for (var s = 0; s <= segments; s++) {
        final a = s * 2 * math.pi / segments;
        verts[vWrite++] = cx + math.cos(a) * r;
        verts[vWrite++] = cy + math.sin(a) * r;
      }
      for (var s = 0; s < segments; s++) {
        indices[iWrite++] = baseVertex;
        indices[iWrite++] = baseVertex + 1 + s;
        indices[iWrite++] = baseVertex + 2 + s;
      }
    }

    final vertices = Vertices.raw(
      VertexMode.triangles,
      verts,
      indices: indices,
    );
    final paint = Paint()..color = style.fill;
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
    vertices.dispose();

    if (style.strokeWidth > 0) {
      final stroke = Paint()
        ..color = style.stroke
        ..strokeWidth = style.strokeWidth
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      for (var n = 0; n < nodes.length; n++) {
        final r = style.radiusOf?.call(n) ?? nodes.r(n);
        canvas.drawCircle(Offset(nodes.x(n), nodes.y(n)), r, stroke);
      }
    }
  }
}
