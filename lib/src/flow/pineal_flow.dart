import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/widgets.dart' hide TextStyle;

import 'flow_data.dart';
import 'flow_layout.dart';

class FlowStyle {
  const FlowStyle({
    this.nodeColor = const Color(0xFF263138),
    this.linkOpacity = 0.5,
    this.nodeLabelColor = const Color(0xFFCBD2D8),
    this.labelFontSize = 11,
    this.useVerticesForLinks = true,
    this.ribbonSegments = 24,
  });

  final Color nodeColor;

  /// Multiplier applied on top of the link's own color. Hot tip: keep low
  /// (0.3–0.6) so overlapping ribbons additively brighten instead of
  /// painting over each other.
  final double linkOpacity;

  final Color nodeLabelColor;
  final double labelFontSize;

  /// When true the painter emits one `drawVertices` call per ribbon (≈ 24
  /// triangles each). Faster than per-ribbon paths once you have a few
  /// hundred links.
  final bool useVerticesForLinks;

  /// Subdivision count along the ribbon's horizontal span. Higher = smoother
  /// curve but more triangles.
  final int ribbonSegments;
}

/// Sankey / alluvial widget.
class PinealFlow extends StatelessWidget {
  const PinealFlow({
    super.key,
    required this.nodes,
    required this.links,
    this.style = const FlowStyle(),
    this.layout = const FlowLayout(),
    this.padding = const EdgeInsets.fromLTRB(8, 8, 8, 8),
    this.onNodeTap,
  });

  final List<FlowNode> nodes;
  final List<FlowLink> links;
  final FlowStyle style;
  final FlowLayout layout;
  final EdgeInsets padding;
  final void Function(FlowNode node)? onNodeTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final size = constraints.biggest;
      final bounds = Rect.fromLTRB(
        padding.left,
        padding.top,
        size.width - padding.right,
        size.height - padding.bottom,
      );
      final result = layout.compute(nodes, links, bounds);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: onNodeTap == null
            ? null
            : (d) {
                for (final r in result.nodeRects.values) {
                  if (r.rect.contains(d.localPosition)) {
                    onNodeTap!(r.node);
                    return;
                  }
                }
              },
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _FlowPainter(result: result, style: style),
            size: Size.infinite,
          ),
        ),
      );
    });
  }
}

class _FlowPainter extends CustomPainter {
  _FlowPainter({required this.result, required this.style});
  final FlowLayoutResult result;
  final FlowStyle style;

  static const _palette = <Color>[
    Color(0xFF42A5F5),
    Color(0xFFEF5350),
    Color(0xFF66BB6A),
    Color(0xFFFFCA28),
    Color(0xFFAB47BC),
    Color(0xFF26A69A),
    Color(0xFFFF7043),
    Color(0xFF8D6E63),
    Color(0xFF5C6BC0),
    Color(0xFF26C6DA),
  ];

  Color _nodeColor(FlowNode n) {
    if (n.color is Color) return n.color! as Color;
    return _palette[n.id.hashCode.abs() % _palette.length];
  }

  Color _linkColor(FlowLayoutResult res, FlowLink l) {
    if (l.color is Color) {
      final c = l.color! as Color;
      return Color.fromRGBO(
          (c.r * 255).round(),
          (c.g * 255).round(),
          (c.b * 255).round(),
          style.linkOpacity);
    }
    final src = res.nodeRects[l.source]?.node;
    final base = src == null ? const Color(0xFF889AAB) : _nodeColor(src);
    return Color.fromRGBO(
        (base.r * 255).round(),
        (base.g * 255).round(),
        (base.b * 255).round(),
        style.linkOpacity);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Links first so nodes sit on top.
    for (final l in result.linkLayouts) {
      final color = _linkColor(result, l.link);
      if (style.useVerticesForLinks) {
        _paintRibbonVertices(canvas, l, color);
      } else {
        _paintRibbonPath(canvas, l, color);
      }
    }

    // Nodes.
    final nodePaint = Paint();
    for (final r in result.nodeRects.values) {
      nodePaint.color = _nodeColor(r.node);
      canvas.drawRect(r.rect, nodePaint);
      _drawLabel(canvas, r);
    }
  }

  void _paintRibbonPath(Canvas canvas, FlowLinkLayout l, Color color) {
    final cpX = (l.sourceX + l.targetX) * 0.5;
    final path = Path()
      ..moveTo(l.sourceX, l.sourceTop)
      ..cubicTo(cpX, l.sourceTop, cpX, l.targetTop, l.targetX, l.targetTop)
      ..lineTo(l.targetX, l.targetBottom)
      ..cubicTo(cpX, l.targetBottom, cpX, l.sourceBottom, l.sourceX,
          l.sourceBottom)
      ..close();
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  void _paintRibbonVertices(Canvas canvas, FlowLinkLayout l, Color color) {
    final n = style.ribbonSegments;
    final cpX = (l.sourceX + l.targetX) * 0.5;
    final verts = Float32List((n + 1) * 4);
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      final x = _cubic(t, l.sourceX, cpX, cpX, l.targetX);
      final yTop = _cubic(t, l.sourceTop, l.sourceTop, l.targetTop, l.targetTop);
      final yBot = _cubic(
          t, l.sourceBottom, l.sourceBottom, l.targetBottom, l.targetBottom);
      verts[i * 4] = x;
      verts[i * 4 + 1] = yTop;
      verts[i * 4 + 2] = x;
      verts[i * 4 + 3] = yBot;
    }
    final v = Vertices.raw(VertexMode.triangleStrip, verts);
    final paint = Paint()..color = color;
    canvas.drawVertices(v, BlendMode.srcOver, paint);
    v.dispose();
  }

  double _cubic(double t, double a, double b, double c, double d) {
    final mt = 1 - t;
    return mt * mt * mt * a +
        3 * mt * mt * t * b +
        3 * mt * t * t * c +
        t * t * t * d;
  }

  void _drawLabel(Canvas canvas, FlowNodeRect r) {
    if (r.node.label.isEmpty || r.rect.height < 12) return;
    final pb = ParagraphBuilder(ParagraphStyle(
      fontSize: style.labelFontSize,
      maxLines: 1,
      ellipsis: '…',
    ))
      ..pushStyle(TextStyle(
        color: style.nodeLabelColor,
        fontSize: style.labelFontSize,
      ))
      ..addText(r.node.label);
    final p = pb.build()..layout(const ParagraphConstraints(width: 140));
    canvas.drawParagraph(
        p, Offset(r.rect.right + 6, r.rect.center.dy - p.height / 2));
  }

  @override
  bool shouldRepaint(covariant _FlowPainter old) {
    return old.result != result || old.style != style;
  }
}
