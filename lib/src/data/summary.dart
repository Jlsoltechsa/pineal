import 'package:flutter/foundation.dart';

import 'data_buffer.dart';
import 'lttb.dart';

/// Policy that decides when raw rendering flips to LTTB-summarized rendering
/// and how large the summary may grow.
///
/// Defaults match the spec: summary engages above 2 visible samples per
/// logical pixel, and the output is capped at `width * 3` vertices.
class SummaryPolicy {
  const SummaryPolicy({
    this.activationDensity = 2.0,
    this.outputVerticesPerPixel = 3,
  });

  /// `density = visibleSamples / pixelWidth`. Above this we summarize.
  final double activationDensity;

  /// Hard cap on summary length, scaled by viewport pixel width.
  final int outputVerticesPerPixel;

  /// Decides what to draw given a visible range and a viewport width.
  ///
  /// Returns either `null` (use raw indices `[start, end)`) or an [Int32List]
  /// of indices into the source buffer (already shifted by `start`).
  Int32List? maybeSummarize(
    DataBuffer src,
    int rangeStart,
    int rangeEnd,
    double pixelWidth,
  ) {
    final visible = rangeEnd - rangeStart;
    if (visible <= 0 || pixelWidth <= 0) return null;

    final density = visible / pixelWidth;
    if (density <= activationDensity) return null;

    final target = (pixelWidth * outputVerticesPerPixel).floor();
    if (target >= visible || target < 3) return null;

    return LTTB.indicesInRange(src, rangeStart, rangeEnd, target);
  }
}

/// Single-shot summary used by the async/isolate path. Operates on a flat
/// interleaved `[x0, y0, x1, y1, …]` payload because that's all we can pass
/// across an isolate boundary cheaply.
Float32List summarizeInterleaved(
  Float32List interleaved,
  int targetSamples,
) {
  final n = interleaved.length >> 1;
  if (targetSamples >= n || targetSamples < 3) return interleaved;

  final src = DataBuffer.fromInterleaved(interleaved);
  final idx = LTTB.indices(src, targetSamples);
  final out = Float32List(idx.length * 2);
  for (var k = 0; k < idx.length; k++) {
    final i = idx[k];
    out[k * 2] = src.xAt(i);
    out[k * 2 + 1] = src.yAt(i);
  }
  return out;
}

/// Runs LTTB on a worker isolate so the UI thread can paint its first frame
/// before the summary completes. Use when the dataset is >100K points or the
/// caller wants to keep the main loop ≤16ms during data ingestion.
Future<Float32List> summarizeInIsolate(
  Float32List interleaved,
  int targetSamples,
) {
  return compute(
    _summarizeEntry,
    _SummarizeArgs(interleaved, targetSamples),
  );
}

class _SummarizeArgs {
  const _SummarizeArgs(this.src, this.target);
  final Float32List src;
  final int target;
}

Float32List _summarizeEntry(_SummarizeArgs args) =>
    summarizeInterleaved(args.src, args.target);
