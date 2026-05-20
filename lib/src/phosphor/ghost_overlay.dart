import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/widgets.dart';

import 'ghost_snapshot.dart';

/// Visual style for a [GhostOverlay].
class GhostStyle {
  const GhostStyle({
    this.color = const Color(0x66FFCA28),
    this.lineWidth = 1.0,
  });
  final Color color;
  final double lineWidth;
}

/// Renders a [GhostSnapshot] on top of (or under) a live stream, so users
/// can compare current behaviour against a captured baseline.
///
/// Stack one of these in front of (or behind, depending on order) a
/// [PinealStream] / [PhosphorStream] with the same `yMin` / `yMax` and
/// padding; the X normalisation matches automatically because both
/// consume the same [coords] layout.
class GhostOverlay extends StatelessWidget {
  const GhostOverlay({
    super.key,
    required this.snapshot,
    required this.yMin,
    required this.yMax,
    this.style = const GhostStyle(),
    this.padding = const EdgeInsets.all(8),
  });

  final GhostSnapshot snapshot;
  final double yMin;
  final double yMax;
  final GhostStyle style;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Padding(
        padding: padding,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _GhostPainter(
              snapshot: snapshot,
              yMin: yMin,
              yMax: yMax,
              style: style,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _GhostPainter extends CustomPainter {
  _GhostPainter({
    required this.snapshot,
    required this.yMin,
    required this.yMax,
    required this.style,
  });

  final GhostSnapshot snapshot;
  final double yMin;
  final double yMax;
  final GhostStyle style;

  /// Matrix allocated once per painter instance (i.e. per widget build),
  /// not per frame. `paint()` only overwrites the four cells that vary.
  final Float64List _matrix = Float64List(16)
    ..[10] = 1
    ..[15] = 1;

  @override
  void paint(Canvas canvas, Size size) {
    final ySpan = yMax - yMin;
    if (ySpan <= 0 || size.width <= 0 || size.height <= 0) return;
    final scaleY = -size.height / ySpan;
    final ty = size.height + yMin * (size.height / ySpan);

    canvas.save();
    _matrix[0] = size.width;
    _matrix[5] = scaleY;
    _matrix[12] = 0;
    _matrix[13] = ty;
    canvas.transform(_matrix);

    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.lineWidth
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final head = snapshot.head;
    final capacity = snapshot.capacity;

    // Same two-segment split as the live painter so the ghost line up
    // bit-for-bit with the trace it was captured from.
    if (head >= 2) {
      final view = Float32List.sublistView(snapshot.coords, 0, head * 2);
      canvas.drawRawPoints(PointMode.polygon, view, paint);
    }
    if (capacity - head >= 2) {
      final view =
          Float32List.sublistView(snapshot.coords, head * 2, capacity * 2);
      canvas.drawRawPoints(PointMode.polygon, view, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GhostPainter old) =>
      old.snapshot != snapshot ||
      old.yMin != yMin ||
      old.yMax != yMax ||
      old.style != style;
}
