import 'dart:math' as math;
import 'dart:typed_data';

/// Bulk-loaded R-tree backed by `Float32List`s.
///
/// Constructed with the Sort-Tile-Recursive (STR) algorithm: sort by x,
/// slice into vertical strips, sort each strip by y, then group into
/// nodes of [nodeSize]. The result is a near-balanced tree with very
/// good packing and predictable query cost (`O(log n + k)` where `k` is
/// the result count).
///
/// We deliberately avoid an `Object` per node — each tree level is two
/// parallel buffers, `_bounds` (4 floats per node: `xMin,yMin,xMax,yMax`)
/// and `_children` (range of child indices into the level below). Queries
/// run as plain index arithmetic, which is what makes this affordable to
/// re-query on every pointer move.
///
/// Used by Geo (point-in-AABB to narrow the polygon hit-test) and Gantt
/// (bar intersection with the time/lane viewport).
class RTree {
  RTree._(this._levels, this.itemCount);

  final List<_Level> _levels;
  final int itemCount;

  /// Bulk-loads a tree over [count] AABBs. The caller supplies the boxes
  /// as four parallel slices into one [boxes] buffer (`xMin, yMin, xMax,
  /// yMax` interleaved, length `count * 4`); each leaf carries the
  /// corresponding integer ID from [ids].
  factory RTree.bulkLoad({
    required Float32List boxes,
    required Int32List ids,
    int nodeSize = 16,
  }) {
    assert(boxes.length == ids.length * 4, 'boxes and ids size mismatch');
    final n = ids.length;
    if (n == 0) return RTree._([_Level(Float32List(0), Int32List(0), Int32List(0))], 0);

    // Leaf level: each leaf holds one item; `childStart`/`childEnd` reference
    // [ids] directly.
    final leafBoxes = Float32List(n * 4);
    final leafIds = Int32List(n);
    final leafIdx = List<int>.generate(n, (i) => i, growable: false);

    // STR: sort by x-center, slice into ⌈√(n/nodeSize)⌉ strips, sort each
    // by y-center, then chunk into leaves of [nodeSize].
    final stripCount =
        math.max(1, (math.sqrt(n / nodeSize)).ceil());
    final perStrip = (n / stripCount).ceil();

    leafIdx.sort((a, b) {
      final ax = (boxes[a * 4] + boxes[a * 4 + 2]);
      final bx = (boxes[b * 4] + boxes[b * 4 + 2]);
      return ax.compareTo(bx);
    });

    for (var s = 0; s < stripCount; s++) {
      final from = s * perStrip;
      final to = math.min(n, from + perStrip);
      final slice = leafIdx.sublist(from, to)
        ..sort((a, b) {
          final ay = (boxes[a * 4 + 1] + boxes[a * 4 + 3]);
          final by = (boxes[b * 4 + 1] + boxes[b * 4 + 3]);
          return ay.compareTo(by);
        });
      for (var k = 0; k < slice.length; k++) {
        leafIdx[from + k] = slice[k];
      }
    }

    for (var i = 0; i < n; i++) {
      final src = leafIdx[i] * 4;
      leafBoxes[i * 4] = boxes[src];
      leafBoxes[i * 4 + 1] = boxes[src + 1];
      leafBoxes[i * 4 + 2] = boxes[src + 2];
      leafBoxes[i * 4 + 3] = boxes[src + 3];
      leafIds[i] = ids[leafIdx[i]];
    }

    final levels = <_Level>[
      // For the leaf level the "child" of node `i` is just item `i`; we
      // encode that as `start=i, end=i+1` so `query` doesn't need a
      // special-case.
      _Level(
        leafBoxes,
        Int32List.fromList(List<int>.generate(n, (i) => i)),
        Int32List.fromList(List<int>.generate(n + 1, (i) => i)),
      ),
    ];

    // Build internal levels bottom-up by chunking pairs of nodes into
    // parents of [nodeSize].
    while (levels.last.nodeCount > 1) {
      final below = levels.last;
      final parentCount = (below.nodeCount / nodeSize).ceil();
      final pBoxes = Float32List(parentCount * 4);
      final pStarts = Int32List(parentCount + 1);
      for (var p = 0; p < parentCount; p++) {
        final from = p * nodeSize;
        final to = math.min(below.nodeCount, from + nodeSize);
        var xMin = double.infinity,
            yMin = double.infinity,
            xMax = -double.infinity,
            yMax = -double.infinity;
        for (var c = from; c < to; c++) {
          final b = c * 4;
          if (below._bounds[b] < xMin) xMin = below._bounds[b];
          if (below._bounds[b + 1] < yMin) yMin = below._bounds[b + 1];
          if (below._bounds[b + 2] > xMax) xMax = below._bounds[b + 2];
          if (below._bounds[b + 3] > yMax) yMax = below._bounds[b + 3];
        }
        pBoxes[p * 4] = xMin;
        pBoxes[p * 4 + 1] = yMin;
        pBoxes[p * 4 + 2] = xMax;
        pBoxes[p * 4 + 3] = yMax;
        pStarts[p] = from;
      }
      pStarts[parentCount] = below.nodeCount;
      levels.add(_Level(pBoxes, Int32List(0), pStarts));
    }
    return RTree._(levels, n);
  }

  /// Appends every item ID whose AABB intersects `(xMin..xMax, yMin..yMax)`
  /// to [out]. Caller owns [out]; we don't allocate a fresh list per call so
  /// pointer-move query loops stay GC-quiet.
  void query(double xMin, double yMin, double xMax, double yMax, List<int> out) {
    if (itemCount == 0) return;
    // Walk top-down. Each entry in [stack] is `(level, node)`.
    final stack = <int>[_levels.length - 1, 0];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      final level = stack.removeLast();
      final lvl = _levels[level];
      final b = node * 4;
      if (lvl._bounds[b + 2] < xMin) continue;
      if (lvl._bounds[b] > xMax) continue;
      if (lvl._bounds[b + 3] < yMin) continue;
      if (lvl._bounds[b + 1] > yMax) continue;

      if (level == 0) {
        // Leaf: emit the item ID.
        out.add(lvl._ids[node]);
      } else {
        final start = lvl._childStart[node];
        final end = lvl._childStart[node + 1];
        for (var c = start; c < end; c++) {
          stack
            ..add(level - 1)
            ..add(c);
        }
      }
    }
  }
}

class _Level {
  _Level(this._bounds, this._ids, this._childStart);

  /// 4 floats per node — `xMin, yMin, xMax, yMax`.
  final Float32List _bounds;

  /// Only meaningful at the leaf level; otherwise empty.
  final Int32List _ids;

  /// `_childStart[i]..._childStart[i+1]` is the child range of node `i` in
  /// the level below. At the leaf level this is `[i, i+1)` (the item itself).
  final Int32List _childStart;

  int get nodeCount => _bounds.length ~/ 4;
}
