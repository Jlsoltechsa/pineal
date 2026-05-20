import 'dart:math' as math;
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Places nodes on concentric circles, bucketed by a node-level metric.
///
/// Higher-metric nodes sit on inner rings; the metric defaults to node
/// degree, so hubs end up at the centre.
class ConcentricLayout extends GraphLayout {
  const ConcentricLayout({
    this.metric,
    this.rings = 4,
    this.ringSpacing = 90,
    this.innerRadius = 0,
  });

  /// Per-node weight. Higher values sit closer to the centre. If `null`,
  /// undirected node degree is used.
  final double Function(int nodeIndex, NodeBuffer nodes, EdgeBuffer edges)?
      metric;

  /// Number of concentric rings to spread nodes across.
  final int rings;

  /// Spacing between rings (in world units).
  final double ringSpacing;

  /// Radius of the innermost ring. `0` puts the highest-metric node at
  /// the origin when there's exactly one of them.
  final double innerRadius;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final n = nodes.length;
    if (n == 0 || rings <= 0) return;

    final values = List<double>.filled(n, 0);
    if (metric != null) {
      for (var i = 0; i < n; i++) {
        values[i] = metric!(i, nodes, edges);
      }
    } else {
      for (var i = 0; i < edges.length; i++) {
        final s = edges.src(i), t = edges.tgt(i);
        if (s == t) continue;
        values[s] += 1;
        values[t] += 1;
      }
    }

    var mn = double.infinity, mx = -double.infinity;
    for (final v in values) {
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    final span = mx - mn;

    final ringBuckets = List<List<int>>.generate(rings, (_) => <int>[]);
    for (var i = 0; i < n; i++) {
      final t = span <= 0 ? 0.5 : (values[i] - mn) / span;
      var bucket = ((1 - t) * (rings - 1)).round();
      if (bucket < 0) bucket = 0;
      if (bucket >= rings) bucket = rings - 1;
      ringBuckets[bucket].add(i);
    }

    for (var r = 0; r < rings; r++) {
      final ring = ringBuckets[r];
      if (ring.isEmpty) continue;
      final radius = innerRadius + r * ringSpacing;
      if (ring.length == 1 && r == 0 && innerRadius == 0) {
        nodes.setXY(ring[0], 0, 0);
        continue;
      }
      for (var k = 0; k < ring.length; k++) {
        final angle = k * 2 * math.pi / ring.length;
        nodes.setXY(
            ring[k], math.cos(angle) * radius, math.sin(angle) * radius);
      }
    }
    nodes.revision++;
  }
}
