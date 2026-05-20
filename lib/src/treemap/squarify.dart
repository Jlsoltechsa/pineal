import 'dart:math' as math;
import 'dart:ui';

import 'treemap_data.dart';

/// Output of [squarify]: a flat list of laid-out rectangles, one per node
/// in the tree (internal + leaves), in depth-first order.
class TreemapTile {
  TreemapTile({
    required this.node,
    required this.rect,
    required this.depth,
    required this.categoryId,
  });
  final TreemapNode node;
  final Rect rect;
  final int depth;

  /// Id of the depth-1 ancestor (the top-level "category"). For a depth-0
  /// or depth-1 tile this is the tile's own id. Used by the painter to give
  /// every leaf within a category a coherent color family.
  final String categoryId;
}

/// Squarified treemap (Bruls/Huijsen/van Wijk, 2000), using the
/// d3-hierarchy formulation: greedy rows of children placed along the
/// short side of the remaining rectangle, with the row break decided by
/// when adding the next value would worsen the worst aspect ratio.
List<TreemapTile> squarify(TreemapNode root, Rect bounds) {
  final out = <TreemapTile>[];
  _layout(root, bounds, 0, root.id, out);
  return out;
}

void _layout(TreemapNode node, Rect rect, int depth, String categoryId,
    List<TreemapTile> out) {
  out.add(TreemapTile(
      node: node, rect: rect, depth: depth, categoryId: categoryId));
  if (node.isLeaf || rect.width <= 0 || rect.height <= 0) return;

  // Sort children descending by value — squarify expects largest first.
  final children = [...node.children]
    ..sort((a, b) => b.totalValue.compareTo(a.totalValue));
  final values = children.map((c) => c.totalValue).toList();
  final totalValue = values.fold<double>(0, (a, b) => a + b);
  if (totalValue <= 0) return;

  // Normalise values so they sum to the area of the rect — keeps the
  // ratio comparison numerically stable.
  final scale = (rect.width * rect.height) / totalValue;
  for (var i = 0; i < values.length; i++) {
    values[i] *= scale;
  }
  var remainingValue = values.fold<double>(0, (a, b) => a + b);

  var x0 = rect.left, y0 = rect.top, x1 = rect.right, y1 = rect.bottom;
  var i0 = 0;
  while (i0 < values.length) {
    final dx = x1 - x0;
    final dy = y1 - y0;
    if (dx <= 0 || dy <= 0 || remainingValue <= 0) break;
    final horizontal = dx >= dy;
    final shortSide = horizontal ? dy : dx;

    // Grow a row, stopping when adding the next value worsens the worst
    // aspect ratio of the current row.
    var sum = values[i0];
    var minV = values[i0];
    var maxV = values[i0];
    var i1 = i0 + 1;
    var bestWorst = _worst(shortSide, sum, minV, maxV);
    while (i1 < values.length) {
      final v = values[i1];
      final newSum = sum + v;
      final newMin = math.min(minV, v);
      final newMax = math.max(maxV, v);
      final candidate = _worst(shortSide, newSum, newMin, newMax);
      if (candidate > bestWorst) break;
      sum = newSum;
      minV = newMin;
      maxV = newMax;
      bestWorst = candidate;
      i1++;
    }

    // Place the row.
    final stripThickness = sum / shortSide;
    if (horizontal) {
      var ny = y0;
      for (var i = i0; i < i1; i++) {
        final h = values[i] / stripThickness;
        final childCategory = depth == 0 ? children[i].id : categoryId;
        _layout(children[i],
            Rect.fromLTRB(x0, ny, x0 + stripThickness, ny + h),
            depth + 1, childCategory, out);
        ny += h;
      }
      x0 += stripThickness;
    } else {
      var nx = x0;
      for (var i = i0; i < i1; i++) {
        final w = values[i] / stripThickness;
        final childCategory = depth == 0 ? children[i].id : categoryId;
        _layout(children[i],
            Rect.fromLTRB(nx, y0, nx + w, y0 + stripThickness),
            depth + 1, childCategory, out);
        nx += w;
      }
      y0 += stripThickness;
    }

    remainingValue -= sum;
    i0 = i1;
  }
}

/// Worst aspect ratio (≥ 1) for a row of values along [shortSide]. Same
/// formula d3-hierarchy uses: tiles in the row have area `values[i]` and
/// the row itself has thickness `sum / shortSide` along the long side.
double _worst(double shortSide, double sum, double minV, double maxV) {
  if (sum <= 0 || shortSide <= 0) return double.infinity;
  final shortSq = shortSide * shortSide;
  final sumSq = sum * sum;
  final a = (shortSq * maxV) / sumSq;
  final b = sumSq / (shortSq * minV);
  return a > b ? a : b;
}
