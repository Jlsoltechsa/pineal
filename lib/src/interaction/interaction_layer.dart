import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/coordinate_system.dart';
import '../core/pineal_core.dart';
import '../painters/text_cache.dart';
import '../series/series.dart';

/// Visual style of the crosshair + tooltip overlay.
class InteractionStyle {
  const InteractionStyle({
    this.crosshairColor = const Color(0x88333333),
    this.crosshairWidth = 1.0,
    this.tooltipBackground = const Color(0xEE222222),
    this.tooltipText = const Color(0xFFFFFFFF),
    this.tooltipPadding = const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    this.fontSize = 12.0,
    this.markerRadius = 4.0,
  });

  final Color crosshairColor;
  final double crosshairWidth;
  final Color tooltipBackground;
  final Color tooltipText;
  final EdgeInsets tooltipPadding;
  final double fontSize;
  final double markerRadius;
}

/// Holds the cursor position. Sits behind its own [RepaintBoundary] so cursor
/// motion never repaints the static chart.
class InteractionLayer extends StatefulWidget {
  const InteractionLayer({
    super.key,
    required this.core,
    required this.padding,
    this.style = const InteractionStyle(),
    this.xFormatter = _defaultX,
    this.yFormatter = _defaultY,
  });

  final PinealCore core;
  final EdgeInsets padding;
  final InteractionStyle style;
  final String Function(double, Scale) xFormatter;
  final String Function(double, Scale) yFormatter;

  static String _defaultX(double v, Scale s) {
    if (s is TimeScale) {
      final dt =
          DateTime.fromMillisecondsSinceEpoch(v.round(), isUtc: false);
      return dt.toIso8601String();
    }
    return v.toStringAsFixed(2);
  }

  static String _defaultY(double v, Scale s) => v.toStringAsFixed(2);

  @override
  State<InteractionLayer> createState() => _InteractionLayerState();
}

class _InteractionLayerState extends State<InteractionLayer> {
  final ValueNotifier<Offset?> _cursor = ValueNotifier<Offset?>(null);
  final TextCache _cache = TextCache(maxEntries: 64);

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (e) => _cursor.value = e.localPosition,
      onExit: (_) => _cursor.value = null,
      child: Listener(
        onPointerDown: (e) => _cursor.value = e.localPosition,
        onPointerMove: (e) => _cursor.value = e.localPosition,
        onPointerUp: (_) => _cursor.value = null,
        behavior: HitTestBehavior.translucent,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _InteractionPainter(
              core: widget.core,
              cursor: _cursor,
              padding: widget.padding,
              style: widget.style,
              cache: _cache,
              xFormatter: widget.xFormatter,
              yFormatter: widget.yFormatter,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _InteractionPainter extends CustomPainter {
  _InteractionPainter({
    required this.core,
    required this.cursor,
    required this.padding,
    required this.style,
    required this.cache,
    required this.xFormatter,
    required this.yFormatter,
  }) : super(repaint: cursor);

  final PinealCore core;
  final ValueListenable<Offset?> cursor;
  final EdgeInsets padding;
  final InteractionStyle style;
  final TextCache cache;
  final String Function(double, Scale) xFormatter;
  final String Function(double, Scale) yFormatter;

  @override
  void paint(Canvas canvas, Size size) {
    final pos = cursor.value;
    if (pos == null) return;

    final plot = Rect.fromLTWH(
      padding.left,
      padding.top,
      (size.width - padding.horizontal).clamp(1.0, double.infinity),
      (size.height - padding.vertical).clamp(1.0, double.infinity),
    );
    if (!plot.contains(pos)) return;
    if (core.series.isEmpty) return;

    final crosshair = Paint()
      ..color = style.crosshairColor
      ..strokeWidth = style.crosshairWidth;
    canvas.drawLine(
      Offset(pos.dx, plot.top),
      Offset(pos.dx, plot.bottom),
      crosshair,
    );
    canvas.drawLine(
      Offset(plot.left, pos.dy),
      Offset(plot.right, pos.dy),
      crosshair,
    );

    // Nearest sample per series at the cursor's x.
    final lines = <String>[];
    Offset? markerPos;
    Series? topSeries;
    for (final s in core.series) {
      final coords = core.coordsFor(s, plot);
      final idx = s.hitTest(pos, coords);
      if (idx < 0) continue;
      final x = s.data.xAt(idx);
      final y = s.data.yAt(idx);
      final p = coords.project(x, y);
      lines.add('${s.id}: ${yFormatter(y, coords.y)}');
      if (topSeries == null) {
        topSeries = s;
        markerPos = p;
        lines.insert(0, xFormatter(x, coords.x));
      }
    }

    if (markerPos != null) {
      final markerPaint = Paint()..color = const Color(0xFFFFFFFF);
      final ring = Paint()
        ..color = const Color(0xFF222222)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(markerPos, style.markerRadius, markerPaint);
      canvas.drawCircle(markerPos, style.markerRadius, ring);
    }

    _drawTooltip(canvas, plot, pos, lines);
  }

  void _drawTooltip(Canvas canvas, Rect plot, Offset cursor, List<String> lines) {
    if (lines.isEmpty) return;
    final paragraphs = lines
        .map((l) => cache.paragraph(
              l,
              fontSize: style.fontSize,
              color: style.tooltipText,
            ))
        .toList();

    var width = 0.0;
    var height = 0.0;
    for (final p in paragraphs) {
      if (p.maxIntrinsicWidth > width) width = p.maxIntrinsicWidth;
      height += p.height;
    }
    width += style.tooltipPadding.horizontal;
    height += style.tooltipPadding.vertical;

    var tx = cursor.dx + 12;
    var ty = cursor.dy + 12;
    if (tx + width > plot.right) tx = cursor.dx - 12 - width;
    if (ty + height > plot.bottom) ty = cursor.dy - 12 - height;

    final bgRect = Rect.fromLTWH(tx, ty, width, height);
    final bgPaint = Paint()..color = style.tooltipBackground;
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(4)),
      bgPaint,
    );

    var y = ty + style.tooltipPadding.top;
    for (final p in paragraphs) {
      canvas.drawParagraph(p, Offset(tx + style.tooltipPadding.left, y));
      y += p.height;
    }
  }

  @override
  bool shouldRepaint(covariant _InteractionPainter old) {
    return old.core != core || old.padding != padding;
  }
}
