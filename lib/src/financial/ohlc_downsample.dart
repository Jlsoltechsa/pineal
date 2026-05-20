import 'dart:typed_data';

import 'ohlc_buffer.dart';

/// Volatility-preserving OHLC aggregation.
///
/// Buckets bars by *time interval* (not index) so irregular data — gaps,
/// holidays, weekends — doesn't merge into a single oversized candle. For
/// each bucket we compute:
///
/// - `open`  = first bar's open
/// - `close` = last bar's close
/// - `high`  = max(high) across the bucket
/// - `low`   = min(low) across the bucket
/// - `volume`= sum
///
/// Empty buckets are dropped, so the output length is `≤ target`.
class OhlcDownsample {
  /// Aggregates `[start, end)` of [src] into at most [target] candles,
  /// bucketed uniformly over the time span. Returns a fresh [OhlcBuffer].
  static OhlcBuffer aggregate(
    OhlcBuffer src,
    int start,
    int end, {
    required int target,
  }) {
    final visible = end - start;
    if (visible <= 0) {
      return OhlcBuffer.fromInterleaved(Float32List(0));
    }
    if (visible <= target) {
      final slice = Float32List(visible * 6);
      slice.setRange(0, visible * 6, src.raw, start * 6);
      return OhlcBuffer.fromInterleaved(slice);
    }

    final tStart = src.t(start);
    final tEnd = src.t(end - 1);
    final span = tEnd - tStart;
    if (span <= 0) {
      // Degenerate (all bars at the same timestamp): index fallback.
      return _aggregateByIndex(src, start, end, target);
    }
    final bucketDur = span / target;
    if (bucketDur <= 0) {
      return _aggregateByIndex(src, start, end, target);
    }

    final out = Float32List(target * 6);
    var writeIdx = 0;

    var currentBucket = -1;
    var bOpen = 0.0, bClose = 0.0, bHigh = 0.0, bLow = 0.0, bVol = 0.0;
    var bStartT = 0.0, bEndT = 0.0;

    void flush() {
      if (currentBucket < 0) return;
      final o = writeIdx * 6;
      out[o] = (bStartT + bEndT) * 0.5;
      out[o + 1] = bOpen;
      out[o + 2] = bHigh;
      out[o + 3] = bLow;
      out[o + 4] = bClose;
      out[o + 5] = bVol;
      writeIdx++;
    }

    for (var i = start; i < end; i++) {
      final t = src.t(i);
      var bucket = ((t - tStart) / bucketDur).floor();
      if (bucket >= target) bucket = target - 1;
      if (bucket != currentBucket) {
        flush();
        currentBucket = bucket;
        bOpen = src.open(i);
        bHigh = src.high(i);
        bLow = src.low(i);
        bClose = src.close(i);
        bVol = src.volume(i);
        bStartT = t;
        bEndT = t;
      } else {
        final h = src.high(i);
        final l = src.low(i);
        if (h > bHigh) bHigh = h;
        if (l < bLow) bLow = l;
        bClose = src.close(i);
        bVol += src.volume(i);
        bEndT = t;
      }
    }
    flush();

    if (writeIdx == target) {
      return OhlcBuffer.fromInterleaved(out);
    }
    // Trim trailing unused slots (empty buckets).
    final trimmed = Float32List(writeIdx * 6);
    trimmed.setRange(0, writeIdx * 6, out);
    return OhlcBuffer.fromInterleaved(trimmed);
  }

  /// Fallback used when timestamps are non-monotonic or collapsed; matches
  /// the original index-based aggregation.
  static OhlcBuffer _aggregateByIndex(
      OhlcBuffer src, int start, int end, int target) {
    final visible = end - start;
    final bucketSize = visible / target;
    final out = Float32List(target * 6);
    for (var b = 0; b < target; b++) {
      final s = start + (b * bucketSize).floor();
      final e = b == target - 1 ? end : start + ((b + 1) * bucketSize).floor();
      if (e <= s) continue;
      var hi = src.high(s);
      var lo = src.low(s);
      var vol = src.volume(s);
      for (var i = s + 1; i < e; i++) {
        final h = src.high(i);
        final l = src.low(i);
        if (h > hi) hi = h;
        if (l < lo) lo = l;
        vol += src.volume(i);
      }
      final o = b * 6;
      out[o] = (src.t(s) + src.t(e - 1)) * 0.5;
      out[o + 1] = src.open(s);
      out[o + 2] = hi;
      out[o + 3] = lo;
      out[o + 4] = src.close(e - 1);
      out[o + 5] = vol;
    }
    return OhlcBuffer.fromInterleaved(out);
  }
}
