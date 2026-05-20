import 'dart:typed_data';
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Subtree-width tree layout.
///
/// Builds a parent → children rooted tree by BFS from [rootIndex] over the
/// undirected adjacency (so the edge direction doesn't matter), measures
/// each subtree's horizontal footprint bottom-up, then places nodes
/// top-down giving every subtree the horizontal slot its width earned.
/// Result: non-overlapping branches even when subtree shapes differ wildly,
/// at `O(n)` time per pass.
class TreeLayout extends GraphLayout {
  const TreeLayout({
    this.rootIndex,
    this.layerSpacing = 110,
    this.siblingSpacing = 60,
    this.leafWidth = 60,
    this.horizontal = false,
  });

  /// Root node. If null, falls back to node 0.
  final int? rootIndex;
  final double layerSpacing;
  final double siblingSpacing;

  /// Horizontal footprint reserved for every leaf. Internal subtree
  /// widths are derived from their leaves.
  final double leafWidth;

  /// Flow left-to-right instead of top-to-bottom.
  final bool horizontal;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final n = nodes.length;
    if (n == 0) return;

    final root = (rootIndex ?? 0).clamp(0, n - 1);

    final adj = List<List<int>>.generate(n, (_) => <int>[]);
    for (var i = 0; i < edges.length; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      if (s == t) continue;
      adj[s].add(t);
      adj[t].add(s);
    }

    // BFS to build child lists + depth array rooted at [root].
    final children = List<List<int>>.generate(n, (_) => <int>[]);
    final depth = Int32List(n);
    final visited = List<bool>.filled(n, false);
    visited[root] = true;
    final queue = <int>[root];
    var head = 0;
    while (head < queue.length) {
      final u = queue[head++];
      for (final v in adj[u]) {
        if (visited[v]) continue;
        visited[v] = true;
        depth[v] = depth[u] + 1;
        children[u].add(v);
        queue.add(v);
      }
    }

    // Subtree widths, bottom-up via post-order over the BFS tree. Use an
    // explicit stack to avoid recursive blow-up on deep graphs.
    final width = Float32List(n);
    final stack = <int>[];
    final iterIdx = List<int>.filled(n, 0);
    stack.add(root);
    while (stack.isNotEmpty) {
      final u = stack.last;
      final c = children[u];
      if (iterIdx[u] < c.length) {
        final v = c[iterIdx[u]];
        iterIdx[u]++;
        stack.add(v);
      } else {
        if (c.isEmpty) {
          width[u] = leafWidth;
        } else {
          var total = 0.0;
          for (var i = 0; i < c.length; i++) {
            if (i > 0) total += siblingSpacing;
            total += width[c[i]];
          }
          width[u] = total < leafWidth ? leafWidth : total;
        }
        stack.removeLast();
      }
    }

    // Place top-down. Track each subtree's left edge as we descend.
    final placeStack = <int>[];
    final leftX = Float32List(n);
    placeStack.add(root);
    leftX[root] = -width[root] * 0.5; // centre the whole tree on origin
    while (placeStack.isNotEmpty) {
      final u = placeStack.removeLast();
      final c = children[u];
      final left = leftX[u];
      final layerCoord = depth[u] * layerSpacing;

      if (c.isEmpty) {
        final mid = left + width[u] * 0.5;
        if (horizontal) {
          nodes.setXY(u, layerCoord, mid);
        } else {
          nodes.setXY(u, mid, layerCoord);
        }
      } else {
        // Assign each child its left edge based on accumulated width.
        var cursor = left;
        for (final cc in c) {
          leftX[cc] = cursor;
          placeStack.add(cc);
          cursor += width[cc] + siblingSpacing;
        }
        // Centre over children's bounding box.
        final firstCenter = left + width[c.first] * 0.5;
        final lastCenter =
            left + (width[u] - width[c.last] * 0.5);
        final mid = (firstCenter + lastCenter) * 0.5;
        if (horizontal) {
          nodes.setXY(u, layerCoord, mid);
        } else {
          nodes.setXY(u, mid, layerCoord);
        }
      }
    }
    nodes.revision++;
  }
}
