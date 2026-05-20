import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Sugiyama-style layered layout for DAGs (and tree subsets).
///
/// Three phases:
/// 1. Layer assignment via longest-path-from-source.
/// 2. Within-layer order via barycenter heuristic, looped until the
///    edge-crossing count stops improving (or [maxIterations] is hit).
/// 3. X coordinates by equispacing inside each layer.
///
/// Cycles are detected and broken by reversing back-edges during phase 1.
/// On typical DAGs the loop converges in 4–8 iterations.
class HierarchicalLayout extends GraphLayout {
  const HierarchicalLayout({
    this.layerSpacing = 120,
    this.nodeSpacing = 80,
    this.horizontal = false,
    this.maxIterations = 24,
  });

  final double layerSpacing;
  final double nodeSpacing;

  /// If true, layers flow left-to-right instead of top-to-bottom.
  final bool horizontal;

  /// Upper bound on barycenter iterations. The actual loop stops as soon as
  /// crossings stabilise.
  final int maxIterations;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final n = nodes.length;
    if (n == 0) return;

    // Phase 0 — cycle removal. Walk the graph DFS-style, dropping any edge
    // pointing back to an ancestor on the current stack. The result is a
    // DAG over the same nodes, which is what Kahn's algorithm needs to
    // produce a proper layering.
    final naiveOut = List<List<int>>.generate(n, (_) => <int>[]);
    for (var i = 0; i < edges.length; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      if (s != t) naiveOut[s].add(t);
    }

    const int unvisited = 0, onStack = 1, done = 2;
    final state = List<int>.filled(n, unvisited);
    final outAdj = List<List<int>>.generate(n, (_) => <int>[]);
    final inAdj = List<List<int>>.generate(n, (_) => <int>[]);
    final stack = <int>[];
    final iter = List<int>.filled(n, 0);
    for (var root = 0; root < n; root++) {
      if (state[root] != unvisited) continue;
      stack.add(root);
      state[root] = onStack;
      iter[root] = 0;
      while (stack.isNotEmpty) {
        final u = stack.last;
        if (iter[u] < naiveOut[u].length) {
          final v = naiveOut[u][iter[u]];
          iter[u]++;
          if (state[v] == onStack) continue; // back-edge: drop
          outAdj[u].add(v);
          inAdj[v].add(u);
          if (state[v] == unvisited) {
            state[v] = onStack;
            iter[v] = 0;
            stack.add(v);
          }
        } else {
          state[u] = done;
          stack.removeLast();
        }
      }
    }

    // Phase 1 — longest-path layer assignment via Kahn over the DAG.
    final layer = List<int>.filled(n, 0);
    final inDeg = List<int>.generate(n, (i) => inAdj[i].length);
    final ready = <int>[];
    for (var i = 0; i < n; i++) {
      if (inDeg[i] == 0) ready.add(i);
    }
    var head = 0;
    while (head < ready.length) {
      final u = ready[head++];
      for (final v in outAdj[u]) {
        if (layer[v] < layer[u] + 1) layer[v] = layer[u] + 1;
        if (--inDeg[v] == 0) ready.add(v);
      }
    }

    // Group by layer.
    var maxLayer = 0;
    for (final l in layer) {
      if (l > maxLayer) maxLayer = l;
    }
    final layers =
        List<List<int>>.generate(maxLayer + 1, (_) => <int>[]);
    for (var i = 0; i < n; i++) {
      layers[layer[i]].add(i);
    }

    // Barycenter ordering: alternate down/up passes until the crossing
    // count plateaus. Each pair of passes typically halves crossings on the
    // first 2–3 rounds and then settles.
    var prevCrossings = _crossings(layers, outAdj);
    for (var it = 0; it < maxIterations; it++) {
      _barycenterPass(layers, outAdj, downward: it.isEven);
      final crossings = _crossings(layers, outAdj);
      if (crossings >= prevCrossings) break;
      prevCrossings = crossings;
    }

    // Assign coordinates.
    for (var l = 0; l < layers.length; l++) {
      final row = layers[l];
      for (var i = 0; i < row.length; i++) {
        final a = (i - (row.length - 1) / 2) * nodeSpacing;
        final b = l * layerSpacing;
        if (horizontal) {
          nodes.setXY(row[i], b, a);
        } else {
          nodes.setXY(row[i], a, b);
        }
      }
    }
    nodes.revision++;
  }

  void _barycenterPass(
    List<List<int>> layers,
    List<List<int>> outAdj, {
    required bool downward,
  }) {
    final pos = <int, int>{};
    for (final row in layers) {
      for (var i = 0; i < row.length; i++) {
        pos[row[i]] = i;
      }
    }

    if (downward) {
      for (var l = 1; l < layers.length; l++) {
        layers[l].sort((a, b) => _barycenter(a, layers[l - 1], outAdj, pos)
            .compareTo(_barycenter(b, layers[l - 1], outAdj, pos)));
        for (var i = 0; i < layers[l].length; i++) {
          pos[layers[l][i]] = i;
        }
      }
    } else {
      for (var l = layers.length - 2; l >= 0; l--) {
        layers[l].sort((a, b) => _barycenter(a, layers[l + 1], outAdj, pos)
            .compareTo(_barycenter(b, layers[l + 1], outAdj, pos)));
        for (var i = 0; i < layers[l].length; i++) {
          pos[layers[l][i]] = i;
        }
      }
    }
  }

  double _barycenter(int node, List<int> referenceLayer,
      List<List<int>> outAdj, Map<int, int> pos) {
    var sum = 0.0;
    var count = 0;
    for (final neighbor in outAdj[node]) {
      final p = pos[neighbor];
      if (p == null) continue;
      sum += p;
      count++;
    }
    for (final other in referenceLayer) {
      if (outAdj[other].contains(node)) {
        sum += pos[other] ?? 0;
        count++;
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  /// Counts edge crossings between every adjacent pair of layers. O(E²)
  /// worst case; cheaper than running yet another barycenter pass that
  /// won't improve the result.
  int _crossings(List<List<int>> layers, List<List<int>> outAdj) {
    final pos = <int, int>{};
    for (final row in layers) {
      for (var i = 0; i < row.length; i++) {
        pos[row[i]] = i;
      }
    }
    var total = 0;
    for (var l = 0; l < layers.length - 1; l++) {
      final upper = layers[l];
      final pairs = <List<int>>[];
      for (final u in upper) {
        for (final v in outAdj[u]) {
          final pv = pos[v];
          if (pv == null) continue;
          pairs.add([pos[u]!, pv]);
        }
      }
      for (var i = 0; i < pairs.length; i++) {
        final a = pairs[i];
        for (var j = i + 1; j < pairs.length; j++) {
          final b = pairs[j];
          if ((a[0] < b[0] && a[1] > b[1]) ||
              (a[0] > b[0] && a[1] < b[1])) {
            total++;
          }
        }
      }
    }
    return total;
  }
}
