import 'data_buffer.dart';

/// Spatial lookups over a [DataBuffer].
///
/// When `xSorted` is true (the common case for time series and indexed
/// values) we run a binary search in O(log n). Otherwise we fall back to a
/// linear scan only when callers explicitly ask for `nearestUnsorted`.
class SpatialIndex {
  const SpatialIndex(this.buffer);
  final DataBuffer buffer;

  /// Returns the index of the first sample whose x is `>= target`. Result is
  /// in the range `[0, buffer.length]`.
  int lowerBound(double target) {
    assert(buffer.xSorted, 'lowerBound requires xSorted=true');
    var lo = 0;
    var hi = buffer.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (buffer.xAt(mid) < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Returns the sample whose x is closest to [target]. -1 if buffer is empty.
  int nearest(double target) {
    final n = buffer.length;
    if (n == 0) return -1;
    final i = lowerBound(target);
    if (i == 0) return 0;
    if (i >= n) return n - 1;
    final dPrev = (target - buffer.xAt(i - 1)).abs();
    final dCurr = (buffer.xAt(i) - target).abs();
    return dPrev <= dCurr ? i - 1 : i;
  }

  /// Indices `[start, end)` inside `[xMin, xMax]`. End is exclusive.
  ({int start, int end}) rangeIndices(double xMin, double xMax) {
    final start = lowerBound(xMin);
    final end = lowerBound(xMax);
    return (start: start, end: end < buffer.length ? end + 1 : buffer.length);
  }

  /// Linear fallback for unsorted data — only call if you know the buffer is
  /// small or unsorted.
  int nearestUnsorted(double tx, double ty) {
    final n = buffer.length;
    if (n == 0) return -1;
    var bestIdx = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < n; i++) {
      final dx = buffer.xAt(i) - tx;
      final dy = buffer.yAt(i) - ty;
      final d = dx * dx + dy * dy;
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }
}
