import 'dart:math' as math;
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Distributes nodes around concentric circles. If [centerIndex] is given,
/// rings are seeded by BFS distance from that node; otherwise every node
/// shares the same ring (single circle).
class RadialLayout extends GraphLayout {
  const RadialLayout({
    this.centerIndex,
    this.ringSpacing = 80,
    this.firstRingRadius = 80,
  });

  final int? centerIndex;
  final double ringSpacing;
  final double firstRingRadius;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final n = nodes.length;
    if (n == 0) return;

    if (centerIndex == null) {
      // Single ring.
      final radius = firstRingRadius + ringSpacing * (n / 20);
      for (var i = 0; i < n; i++) {
        final a = i * 2 * math.pi / n;
        nodes.setXY(i, math.cos(a) * radius, math.sin(a) * radius);
      }
      nodes.revision++;
      return;
    }

    // BFS rings.
    final depth = List<int>.filled(n, -1);
    depth[centerIndex!] = 0;
    final adj = edges.adjacency(n);
    final queue = <int>[centerIndex!];
    var head = 0;
    while (head < queue.length) {
      final u = queue[head++];
      for (final v in adj[u]) {
        if (depth[v] < 0) {
          depth[v] = depth[u] + 1;
          queue.add(v);
        }
      }
    }

    // Group nodes per ring.
    final ringBuckets = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      final d = depth[i] < 0 ? 1 : depth[i]; // disconnected → outer ring
      (ringBuckets[d] ??= <int>[]).add(i);
    }

    nodes.setXY(centerIndex!, 0, 0);
    for (final entry in ringBuckets.entries) {
      final d = entry.key;
      if (d == 0) continue;
      final ring = entry.value;
      final radius = firstRingRadius + ringSpacing * (d - 1);
      for (var k = 0; k < ring.length; k++) {
        final a = k * 2 * math.pi / ring.length;
        nodes.setXY(ring[k], math.cos(a) * radius, math.sin(a) * radius);
      }
    }
    nodes.revision++;
  }
}
