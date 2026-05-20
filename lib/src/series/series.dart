import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../core/coordinate_system.dart';
import '../data/data_buffer.dart';
import '../data/spatial_index.dart';

/// Decides between the cheap GPU-only path and the decorated UI-rich path.
///
/// The render box picks this based on visible point density; series can
/// override by inspecting the mode in [paint].
enum RenderMode { highDensity, uiRich }

/// Base class for every plottable series.
///
/// A series owns its [DataBuffer] and an optional pre-computed
/// [SpatialIndex]. It exposes [paint] for drawing and [hitTest] for tooltip
/// lookups. The chart pipeline gives it a fresh [CoordinateSystem] per frame
/// so projection costs stay localized here.
abstract class Series {
  Series({
    required this.id,
    required this.data,
    this.yAxisId = 'y',
  }) : index = SpatialIndex(data);

  final String id;
  final DataBuffer data;
  final SpatialIndex index;

  /// Which Y axis this series is plotted against. Multi-axis charts route
  /// series with different `yAxisId` values to independent scales.
  final String yAxisId;

  /// Optional listenable that triggers a chart repaint when it fires. Used
  /// by animated/streaming series; returns `null` for static data.
  Listenable? get repaintTrigger => null;

  void paint(Canvas canvas, CoordinateSystem coords, RenderMode mode);

  /// Returns the data-index nearest to [pixel], or -1 if out of bounds.
  int hitTest(Offset pixel, CoordinateSystem coords) {
    final p = coords.unproject(pixel);
    return index.nearest(p.x);
  }
}
