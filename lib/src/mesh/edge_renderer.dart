import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'edge_buffer.dart';
import 'node_buffer.dart';

enum EdgeCurve { straight, bezier, bundled, elbow }

class EdgeStyle {
  const EdgeStyle({
    this.color = const Color(0x66556699),
    this.width = 1.0,
    this.curve = EdgeCurve.straight,
    this.bundlingStrength = 0.7,
    this.bundlingIterations = 4,
    this.bezierTension = 0.35,
  });

  final Color color;
  final double width;
  final EdgeCurve curve;

  /// 0..1 — how strongly bundled edges pull each other's control points.
  final double bundlingStrength;

  /// Number of relaxation iterations when [curve] is [EdgeCurve.bundled].
  /// Each iteration uses a smaller step than the previous, giving the
  /// effect of Holten's annealed FDEB without the polyline overhead.
  final int bundlingIterations;

  /// 0..1 — bezier control point offset from edge midpoint, relative to
  /// edge length, normal to the edge direction.
  final double bezierTension;
}

/// Draws every edge with a single Skia call when possible.
///
/// * `straight` → one `drawRawPoints(PointMode.lines)` for the whole set.
/// * `bezier` → builds one [Path] then `drawPath`. Tens of thousands of
///   curves stay in a single draw call.
/// * `bundled` → midpoint clustering passes inflect the bezier control
///   points so edges sharing direction visually merge.
class EdgeRenderer {
  EdgeRenderer({required this.style});

  EdgeStyle style;

  /// Optional per-edge control point cache for `bundled`. Rebuilt lazily.
  Float32List? _bundlingCps;
  int _bundlingRevision = -1;

  void paint(Canvas canvas, NodeBuffer nodes, EdgeBuffer edges) {
    if (edges.length == 0) return;
    switch (style.curve) {
      case EdgeCurve.straight:
        _paintStraight(canvas, nodes, edges);
        break;
      case EdgeCurve.bezier:
        _paintBezier(canvas, nodes, edges, null);
        break;
      case EdgeCurve.bundled:
        final cps = _computeBundling(nodes, edges);
        _paintBezier(canvas, nodes, edges, cps);
        break;
      case EdgeCurve.elbow:
        _paintElbow(canvas, nodes, edges);
        break;
    }
  }

  /// Conectores ortogonales tipo organigrama: tramo vertical desde el origen
  /// hasta el punto medio en Y, tramo horizontal hasta la X del destino y
  /// tramo vertical hasta el destino (vertical + esquina + horizontal +
  /// esquina + vertical). Un único `drawPath` para todo el set.
  void _paintElbow(Canvas canvas, NodeBuffer nodes, EdgeBuffer edges) {
    final path = Path();
    for (var i = 0; i < edges.length; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      if (s == t) continue;
      final sx = nodes.x(s), sy = nodes.y(s);
      final tx = nodes.x(t), ty = nodes.y(t);
      final midY = (sy + ty) * 0.5;
      path
        ..moveTo(sx, sy)
        ..lineTo(sx, midY)
        ..lineTo(tx, midY)
        ..lineTo(tx, ty);
    }
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.width
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.miter
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  void _paintStraight(Canvas canvas, NodeBuffer nodes, EdgeBuffer edges) {
    final pts = Float32List(edges.length * 4);
    var w = 0;
    for (var i = 0; i < edges.length; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      if (s == t) continue;
      pts[w++] = nodes.x(s);
      pts[w++] = nodes.y(s);
      pts[w++] = nodes.x(t);
      pts[w++] = nodes.y(t);
    }
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.width
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    canvas.drawRawPoints(PointMode.lines, pts, paint);
  }

  void _paintBezier(Canvas canvas, NodeBuffer nodes, EdgeBuffer edges,
      Float32List? controlPoints) {
    final path = Path();
    for (var i = 0; i < edges.length; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      if (s == t) continue;
      final sx = nodes.x(s), sy = nodes.y(s);
      final tx = nodes.x(t), ty = nodes.y(t);

      final double cpx, cpy;
      if (controlPoints != null) {
        cpx = controlPoints[i * 2];
        cpy = controlPoints[i * 2 + 1];
      } else {
        final mx = (sx + tx) * 0.5;
        final my = (sy + ty) * 0.5;
        final dx = tx - sx, dy = ty - sy;
        final len = (dx * dx + dy * dy);
        if (len <= 1e-6) {
          cpx = mx;
          cpy = my;
        } else {
          final invLen = 1.0 / _sqrt(len);
          final nxn = -dy * invLen;
          final nyn = dx * invLen;
          final offset = _sqrt(len) * style.bezierTension;
          cpx = mx + nxn * offset;
          cpy = my + nyn * offset;
        }
      }
      path
        ..moveTo(sx, sy)
        ..quadraticBezierTo(cpx, cpy, tx, ty);
    }
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.width
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
  }

  /// Iterative edge bundling (annealed FDEB).
  ///
  /// Each iteration relaxes each edge's control point toward the average of
  /// its directionally-compatible neighbours' control points, with the step
  /// halving each round. Convergence in 3–4 iterations is typical.
  Float32List _computeBundling(NodeBuffer nodes, EdgeBuffer edges) {
    final revKey = nodes.revision ^ (edges.revision << 16) ^ edges.length;
    if (_bundlingCps != null && _bundlingRevision == revKey) {
      return _bundlingCps!;
    }

    final n = edges.length;
    final cps = Float32List(n * 2);
    final midX = Float32List(n);
    final midY = Float32List(n);
    final dirX = Float32List(n);
    final dirY = Float32List(n);
    final lens = Float32List(n);
    var maxLen = 0.0;
    for (var i = 0; i < n; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      final ex = nodes.x(t) - nodes.x(s);
      final ey = nodes.y(t) - nodes.y(s);
      midX[i] = (nodes.x(s) + nodes.x(t)) * 0.5;
      midY[i] = (nodes.y(s) + nodes.y(t)) * 0.5;
      final l = _sqrt(ex * ex + ey * ey);
      lens[i] = l;
      if (l > 1e-6) {
        dirX[i] = ex / l;
        dirY[i] = ey / l;
      }
      cps[i * 2] = midX[i]; // seed each control point at the midpoint.
      cps[i * 2 + 1] = midY[i];
      if (l > maxLen) maxLen = l;
    }

    final cell = (maxLen * 0.5).clamp(40.0, 800.0);
    final strength = style.bundlingStrength.clamp(0.0, 1.0);
    final iterations = style.bundlingIterations.clamp(1, 16);

    // Pre-bucket edges by midpoint cell. Buckets are rebuilt each iteration
    // because control points migrate — but the midpoints don't, so the key
    // set stays constant. We update bucket centroids in place.
    final cellKey = Int32List(n);
    final buckets = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      final cx = (midX[i] / cell).floor();
      final cy = (midY[i] / cell).floor();
      final key = ((cx & 0xFFFF) << 16) ^ (cy & 0xFFFF);
      cellKey[i] = key;
      (buckets[key] ??= <int>[]).add(i);
    }

    final next = Float32List(n * 2);
    for (var it = 0; it < iterations; it++) {
      final stepScale = strength / (1 << it); // halve each round.
      for (var i = 0; i < n; i++) {
        if (lens[i] <= 1e-6) {
          next[i * 2] = cps[i * 2];
          next[i * 2 + 1] = cps[i * 2 + 1];
          continue;
        }
        var sumX = 0.0, sumY = 0.0;
        var weight = 0.0;
        final ki = cellKey[i];
        // Check own bucket + 8 neighbours.
        for (var ox = -1; ox <= 1; ox++) {
          for (var oy = -1; oy <= 1; oy++) {
            final cx = ((ki >> 16) & 0xFFFF).toSigned(16) + ox;
            final cy = (ki & 0xFFFF).toSigned(16) + oy;
            final probe = ((cx & 0xFFFF) << 16) ^ (cy & 0xFFFF);
            final bucket = buckets[probe];
            if (bucket == null) continue;
            for (final j in bucket) {
              if (j == i || lens[j] <= 1e-6) continue;
              // Compatibility: |cos(angle between edges)|.
              final compat =
                  (dirX[i] * dirX[j] + dirY[i] * dirY[j]).abs();
              if (compat < 0.5) continue;
              final w = compat;
              sumX += cps[j * 2] * w;
              sumY += cps[j * 2 + 1] * w;
              weight += w;
            }
          }
        }
        if (weight == 0) {
          next[i * 2] = cps[i * 2];
          next[i * 2 + 1] = cps[i * 2 + 1];
        } else {
          final targetX = sumX / weight;
          final targetY = sumY / weight;
          next[i * 2] = cps[i * 2] + (targetX - cps[i * 2]) * stepScale;
          next[i * 2 + 1] =
              cps[i * 2 + 1] + (targetY - cps[i * 2 + 1]) * stepScale;
        }
      }
      cps.setAll(0, next);
    }

    _bundlingCps = cps;
    _bundlingRevision = revKey;
    return cps;
  }

  static double _sqrt(double v) => v > 0 ? math.sqrt(v).toDouble() : 0;
}
