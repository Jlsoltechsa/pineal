import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../core/coordinate_system.dart';
import '../data/data_animator.dart';
import '../data/data_buffer.dart';
import 'series.dart';

/// Polyline driven by a [DataAnimator]. Vertices are already summarized — we
/// just lerp and project, skipping LTTB entirely on the hot path.
///
/// Pair this with [DataAnimator.transitionTo] to morph between datasets at
/// 120 FPS without re-running the reducer every frame.
class AnimatedLineSeries extends Series {
  AnimatedLineSeries({
    required super.id,
    required this.animator,
    super.yAxisId,
    this.color = const Color(0xFF1E88E5),
    this.strokeWidth = 1.5,
  }) : super(data: DataBuffer.fromInterleaved(animator.current));

  final DataAnimator animator;
  final Color color;
  final double strokeWidth;

  @override
  Listenable get repaintTrigger => animator;

  @override
  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode) {
    final src = animator.current;
    final n = src.length >> 1;
    if (n < 2) return;

    final pts = Float32List(n * 2);
    for (var k = 0; k < n; k++) {
      final o = coords.project(src[k * 2], src[k * 2 + 1]);
      pts[k * 2] = o.dx;
      pts[k * 2 + 1] = o.dy;
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = mode == RenderMode.uiRich;
    canvas.drawRawPoints(PointMode.polygon, pts, paint);
  }

  @override
  int hitTest(Offset pixel, CoordinateSystem coords) {
    // SpatialIndex was built from the *initial* snapshot. During an animation
    // the values shift, so we fall back to the snapshot the animator just
    // produced and run a linear unproject-distance scan on it.
    final src = animator.current;
    final n = src.length >> 1;
    if (n == 0) return -1;
    final p = coords.unproject(pixel);
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < n; i++) {
      final dx = src[i * 2] - p.x;
      final d = dx.abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }
}
