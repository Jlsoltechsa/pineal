import 'dart:math' as math;
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Seeds nodes at random positions in a square of side `spread × spread`.
///
/// Useful as a deterministic warm-start for [ForceDirectedLayout] —
/// `apply` is `O(n)` and runs in microseconds even on 10K node graphs.
class RandomLayout extends GraphLayout {
  const RandomLayout({this.seed = 7, this.spread = 600});

  final int seed;
  final double spread;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final rng = math.Random(seed);
    final half = spread * 0.5;
    for (var i = 0; i < nodes.length; i++) {
      nodes.setXY(i, rng.nextDouble() * spread - half,
          rng.nextDouble() * spread - half);
    }
    nodes.revision++;
  }
}
