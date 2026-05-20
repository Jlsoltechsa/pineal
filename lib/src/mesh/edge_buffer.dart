import 'dart:typed_data';

/// Edge list packed as `[src0, tgt0, src1, tgt1, …]`. One [Int32List]
/// instead of `List<({int s, int t})>` keeps the topology hot in cache
/// during force-simulation springs and during the line-batch render.
class EdgeBuffer {
  EdgeBuffer._(this._data, this.length);

  factory EdgeBuffer.fromPairs(List<(int, int)> pairs) {
    final data = Int32List(pairs.length * 2);
    for (var i = 0; i < pairs.length; i++) {
      data[i * 2] = pairs[i].$1;
      data[i * 2 + 1] = pairs[i].$2;
    }
    return EdgeBuffer._(data, pairs.length);
  }

  factory EdgeBuffer.fromInterleaved(Int32List interleaved) {
    assert(interleaved.length.isEven);
    return EdgeBuffer._(interleaved, interleaved.length >> 1);
  }

  /// Wraps an existing pair-buffer. Used by the isolate worker which
  /// receives the raw [Int32List] across the port boundary.
  factory EdgeBuffer.wrap(Int32List raw, int length) {
    assert(raw.length >= length * 2, 'raw buffer too small');
    return EdgeBuffer._(raw, length);
  }

  final Int32List _data;
  final int length;
  int revision = 0;

  Int32List get raw => _data;

  int src(int i) => _data[i * 2];
  int tgt(int i) => _data[i * 2 + 1];

  /// Builds an adjacency list view. O(n + m) construction; useful for
  /// algorithms that walk the graph topology (tree layout, traversal).
  List<List<int>> adjacency(int nodeCount) {
    final adj = List<List<int>>.generate(nodeCount, (_) => <int>[]);
    for (var i = 0; i < length; i++) {
      final s = src(i);
      final t = tgt(i);
      adj[s].add(t);
      adj[t].add(s);
    }
    return adj;
  }
}
