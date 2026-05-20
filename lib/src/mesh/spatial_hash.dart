import 'node_buffer.dart';

/// Uniform spatial hash grid over a [NodeBuffer].
///
/// Built on demand (caller rebuilds after layout/simulation steps). Lookups
/// for "node nearest to point (x,y)" are O(1) amortized because we only
/// scan the bucket the query falls into plus its 8 neighbours.
class SpatialHash {
  SpatialHash._(this.cellSize, this._cells, this._minX, this._minY);

  /// Rebuilds an index over [nodes]. [cellSize] should be ≈ 2× the average
  /// node radius — that keeps the per-bucket population low.
  factory SpatialHash.build(NodeBuffer nodes, {required double cellSize}) {
    if (nodes.length == 0) {
      return SpatialHash._(cellSize, <int, List<int>>{}, 0, 0);
    }
    final b = nodes.bounds();
    final cells = <int, List<int>>{};
    for (var i = 0; i < nodes.length; i++) {
      final cx = ((nodes.x(i) - b.xMin) / cellSize).floor();
      final cy = ((nodes.y(i) - b.yMin) / cellSize).floor();
      final key = _key(cx, cy);
      (cells[key] ??= <int>[]).add(i);
    }
    return SpatialHash._(cellSize, cells, b.xMin, b.yMin);
  }

  final double cellSize;
  final Map<int, List<int>> _cells;
  final double _minX;
  final double _minY;

  static int _key(int cx, int cy) {
    // Cantor pairing collapses two ints into one; cheap and unique enough
    // for grid keys that fit in a Dart 64-bit int.
    final a = cx >= 0 ? 2 * cx : -2 * cx - 1;
    final b = cy >= 0 ? 2 * cy : -2 * cy - 1;
    final sum = a + b;
    return (sum * (sum + 1)) ~/ 2 + b;
  }

  /// Nearest node to `(wx, wy)` in world coordinates within [maxRadius].
  /// Returns -1 if no node is within range.
  int nearest(NodeBuffer nodes, double wx, double wy,
      {double maxRadius = double.infinity}) {
    final cx = ((wx - _minX) / cellSize).floor();
    final cy = ((wy - _minY) / cellSize).floor();
    var best = -1;
    var bestDist = maxRadius * maxRadius;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final bucket = _cells[_key(cx + dx, cy + dy)];
        if (bucket == null) continue;
        for (final i in bucket) {
          final ex = nodes.x(i) - wx;
          final ey = nodes.y(i) - wy;
          final d = ex * ex + ey * ey;
          if (d < bestDist) {
            bestDist = d;
            best = i;
          }
        }
      }
    }
    return best;
  }

  /// Pixel-perfect hit-test: returns the first node whose radius contains
  /// `(wx, wy)`. Slower than [nearest] only by a single distance comparison.
  int hitTest(NodeBuffer nodes, double wx, double wy) {
    final cx = ((wx - _minX) / cellSize).floor();
    final cy = ((wy - _minY) / cellSize).floor();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final bucket = _cells[_key(cx + dx, cy + dy)];
        if (bucket == null) continue;
        for (final i in bucket) {
          final ex = nodes.x(i) - wx;
          final ey = nodes.y(i) - wy;
          final r = nodes.r(i);
          if (ex * ex + ey * ey <= r * r) return i;
        }
      }
    }
    return -1;
  }
}
