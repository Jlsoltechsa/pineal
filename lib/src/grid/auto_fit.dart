import 'dart:math' as math;
import 'dart:ui';

import '../painters/text_cache.dart';
import 'column.dart';
import 'data_source.dart';

/// Resolves auto-fit column widths in three layers:
///
///  1. [measureViewport] — synchronous, scans only the rows the painter is
///     about to draw plus headers. Called on every layout so first paint
///     never blocks.
///  2. [measureSampled] / [measureSampledAsync] — reservoir-sampled across
///     the whole dataset. The async variant yields to the event loop every
///     [chunkSize] rows so it doesn't block frames on million-row sources.
///     Text layout still happens on the UI isolate (Flutter's `Paragraph`
///     can't safely cross isolates with font fallback in play), so the
///     async path is a cooperative-scheduling fix, not true parallelism.
///  3. [measureExhaustive] — scans every row. Linear in `rowCount`; intended
///     for offline export, not interactive layout.
///
/// All measurements share a [TextCache] so repeated strings (status flags,
/// enum-like values) only pay the layout cost once.
class AutoFitMeasurer {
  AutoFitMeasurer({
    required this.textCache,
    required this.fontSize,
    required this.fontFamily,
    required this.cellPaddingH,
    this.sampleSize = 2048,
    this.chunkSize = 256,
  });

  final TextCache textCache;
  final double fontSize;
  final String? fontFamily;
  final double cellPaddingH;
  final int sampleSize;

  /// How many rows the async measurer processes before yielding to the
  /// event loop. Lower → smoother frames, slower total. 256 ≈ 1ms of text
  /// layout on typical desktop hardware, well under one frame's budget.
  final int chunkSize;

  /// Width that fits [text] under the configured font. Includes horizontal
  /// padding so the caller can use the result directly as a column width.
  double measureText(String text) {
    if (text.isEmpty) return cellPaddingH * 2;
    final p = textCache.paragraph(
      text,
      fontSize: fontSize,
      color: const Color(0xFFFFFFFF),
      fontFamily: fontFamily,
    );
    return p.maxIntrinsicWidth + cellPaddingH * 2;
  }

  /// Pass 1 — measure the on-screen window. Cheap enough to run every frame.
  double measureViewport({
    required GridColumn column,
    required GridDataSource source,
    required int firstRow,
    required int lastRow,
  }) {
    var w = measureText(column.header);
    final lo = math.max(0, firstRow);
    final hi = math.min(source.rowCount - 1, lastRow);
    for (var r = lo; r <= hi; r++) {
      final s = column.format(source.valueAt(r, column.id));
      final candidate = measureText(s);
      if (candidate > w) w = candidate;
    }
    return w.clamp(column.minWidth, column.maxWidth);
  }

  /// Pass 2 — reservoir-style sampling across the full dataset.
  ///
  /// Uses a deterministic stride so two paints with the same `rowCount`
  /// produce the same width (avoids flicker when the sampler is rerun).
  /// We intentionally skip the first 200 rows along with the rest of the
  /// stride: in practice long strings cluster in description/notes columns
  /// that live deep in the dataset, so sampling only the head biases low.
  double measureSampled({
    required GridColumn column,
    required GridDataSource source,
  }) {
    final n = source.rowCount;
    if (n == 0) return measureText(column.header).clamp(column.minWidth, column.maxWidth);

    final samples = math.min(sampleSize, n);
    final stride = math.max(1, n ~/ samples);

    var w = measureText(column.header);
    for (var r = 0; r < n; r += stride) {
      final s = column.format(source.valueAt(r, column.id));
      final candidate = measureText(s);
      if (candidate > w) w = candidate;
    }
    return w.clamp(column.minWidth, column.maxWidth);
  }

  /// Async variant of [measureSampled]. Yields to the event loop every
  /// [chunkSize] rows so the autofit pass doesn't stall paint.
  Future<double> measureSampledAsync({
    required GridColumn column,
    required GridDataSource source,
  }) async {
    final n = source.rowCount;
    if (n == 0) {
      return measureText(column.header).clamp(column.minWidth, column.maxWidth);
    }
    final samples = math.min(sampleSize, n);
    final stride = math.max(1, n ~/ samples);
    var w = measureText(column.header);
    var processed = 0;
    for (var r = 0; r < n; r += stride) {
      final s = column.format(source.valueAt(r, column.id));
      final candidate = measureText(s);
      if (candidate > w) w = candidate;
      processed++;
      if (processed >= chunkSize) {
        processed = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    return w.clamp(column.minWidth, column.maxWidth);
  }

  /// Pass 3 — full scan. Only call from background work (export pipelines).
  double measureExhaustive({
    required GridColumn column,
    required GridDataSource source,
  }) {
    final n = source.rowCount;
    var w = measureText(column.header);
    for (var r = 0; r < n; r++) {
      final s = column.format(source.valueAt(r, column.id));
      final candidate = measureText(s);
      if (candidate > w) w = candidate;
    }
    return w.clamp(column.minWidth, column.maxWidth);
  }
}
