import 'dart:typed_data';

import 'data_buffer.dart';

/// Largest-Triangle-Three-Buckets downsampling.
///
/// Reduces a series to `threshold` points while preserving the visual
/// silhouette (peaks, valleys, slope changes). The algorithm is O(n) with a
/// single pass and no allocations beyond the output buffer.
class LTTB {
  /// Returns indices into [src] that approximate it with [threshold] samples.
  /// The result indices are relative to [src] (i.e. `0..src.length-1`).
  static Int32List indices(DataBuffer src, int threshold) {
    return _indices(src.length, src.xAt, src.yAt, threshold);
  }

  /// Range-aware variant. Operates over `[start, end)` of [src] and returns
  /// indices relative to [src] (already shifted by `start`).
  static Int32List indicesInRange(
      DataBuffer src, int start, int end, int threshold) {
    final n = end - start;
    final local = _indices(
      n,
      (i) => src.xAt(start + i),
      (i) => src.yAt(start + i),
      threshold,
    );
    for (var i = 0; i < local.length; i++) {
      local[i] += start;
    }
    return local;
  }

  static Int32List _indices(
    int n,
    double Function(int) xAt,
    double Function(int) yAt,
    int threshold,
  ) {
    if (threshold >= n || threshold < 3) {
      final out = Int32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = i;
      }
      return out;
    }

    final sampled = Int32List(threshold);
    sampled[0] = 0;
    var sampledIdx = 1;

    final bucketSize = (n - 2) / (threshold - 2);
    var a = 0;

    for (var i = 0; i < threshold - 2; i++) {
      final rangeStart = (i * bucketSize).floor() + 1;
      final rangeEnd = ((i + 1) * bucketSize).floor() + 1;
      final clampedEnd = rangeEnd < n ? rangeEnd : n;

      final nextStart = ((i + 1) * bucketSize).floor() + 1;
      final nextEnd = ((i + 2) * bucketSize).floor() + 1;
      final clampedNextStart = nextStart < n ? nextStart : n;
      final clampedNextEnd = nextEnd < n ? nextEnd : n;
      final nextLen = clampedNextEnd - clampedNextStart;

      var avgX = 0.0;
      var avgY = 0.0;
      if (nextLen > 0) {
        for (var k = clampedNextStart; k < clampedNextEnd; k++) {
          avgX += xAt(k);
          avgY += yAt(k);
        }
        avgX /= nextLen;
        avgY /= nextLen;
      } else {
        avgX = xAt(n - 1);
        avgY = yAt(n - 1);
      }

      final ax = xAt(a);
      final ay = yAt(a);

      var maxArea = -1.0;
      var maxIdx = rangeStart;
      for (var j = rangeStart; j < clampedEnd; j++) {
        final px = xAt(j);
        final py = yAt(j);
        final area =
            ((ax - avgX) * (py - ay) - (ax - px) * (avgY - ay)).abs() * 0.5;
        if (area > maxArea) {
          maxArea = area;
          maxIdx = j;
        }
      }
      sampled[sampledIdx++] = maxIdx;
      a = maxIdx;
    }

    sampled[sampledIdx] = n - 1;
    return sampled;
  }
}
