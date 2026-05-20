import 'dart:math' as math;
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Pin every node onto a uniform grid. Useful for deterministic snapshots
/// and as a starting state for force-directed simulations.
class GridLayout extends GraphLayout {
  const GridLayout({this.cols, this.spacing = 60});

  /// Columns. If `null`, defaults to `ceil(sqrt(n))` — a square-ish grid.
  final int? cols;
  final double spacing;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    if (nodes.length == 0) return;
    final c = cols ?? math.sqrt(nodes.length).ceil();
    for (var i = 0; i < nodes.length; i++) {
      final row = i ~/ c;
      final col = i % c;
      nodes.setXY(i, col * spacing, row * spacing);
    }
    nodes.revision++;
  }
}
