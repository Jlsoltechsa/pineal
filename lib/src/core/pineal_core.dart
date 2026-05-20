import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../series/series.dart';
import 'coordinate_system.dart';
import 'viewport.dart';

/// Declarative description of one Y axis. Multiple of these enable
/// independent scales (e.g. price + volume on the same chart).
@immutable
class YAxisSpec {
  const YAxisSpec({
    required this.id,
    required this.min,
    required this.max,
    this.side = YAxisSide.left,
    this.label,
    this.scaleKind = ScaleKind.linear,
  });

  final String id;
  final double min;
  final double max;
  final YAxisSide side;
  final String? label;
  final ScaleKind scaleKind;
}

enum YAxisSide { left, right }

enum ScaleKind { linear, log, time }

/// Orchestrator that owns the viewport, the y-axis windows, and the series
/// list. The widget layer wires this up; series and painters read from it.
class PinealCore extends ChangeNotifier {
  PinealCore({
    required ChartViewport xViewport,
    required List<YAxisSpec> yAxes,
    required List<Series> series,
  })  : _xViewport = xViewport,
        _yAxes = List.unmodifiable(yAxes),
        _series = List.unmodifiable(series),
        _yWindows = {
          for (final a in yAxes) a.id: _YWindow(a.min, a.max),
        } {
    _xViewport.addListener(_forward);
  }

  ChartViewport _xViewport;
  final List<YAxisSpec> _yAxes;
  final List<Series> _series;
  final Map<String, _YWindow> _yWindows;

  ChartViewport get xViewport => _xViewport;
  List<YAxisSpec> get yAxes => _yAxes;
  List<Series> get series => _series;

  void _forward() => notifyListeners();

  /// Replaces the X viewport. Used when the widget rebuilds with new bounds.
  void replaceXViewport(ChartViewport v) {
    if (identical(v, _xViewport)) return;
    _xViewport.removeListener(_forward);
    _xViewport = v;
    _xViewport.addListener(_forward);
    notifyListeners();
  }

  ({double min, double max}) yWindow(String axisId) {
    final w = _yWindows[axisId];
    if (w == null) {
      throw StateError('Unknown y axis: $axisId');
    }
    return (min: w.min, max: w.max);
  }

  void setYWindow(String axisId, double min, double max) {
    final w = _yWindows[axisId];
    if (w == null) return;
    w.min = min;
    w.max = max;
    notifyListeners();
  }

  /// Builds a [CoordinateSystem] for a given series, picking the right Y axis.
  CoordinateSystem coordsFor(Series s, Rect plot) =>
      coordsForAxis(s.yAxisId, plot);

  /// Builds a [CoordinateSystem] keyed only by a Y-axis id. Used by overlays
  /// that aren't backed by a [Series].
  CoordinateSystem coordsForAxis(String yAxisId, Rect plot) {
    final yw = _yWindows[yAxisId] ?? _yWindows[_yAxes.first.id]!;
    final axisSpec = _yAxes.firstWhere(
      (a) => a.id == yAxisId,
      orElse: () => _yAxes.first,
    );
    final yScale = _buildScale(axisSpec.scaleKind, yw.min, yw.max);
    final xScale = LinearScale(_xViewport.xMin, _xViewport.xMax);
    return CoordinateSystem(x: xScale, y: yScale, plot: plot);
  }

  Scale _buildScale(ScaleKind kind, double min, double max) {
    switch (kind) {
      case ScaleKind.linear:
        return LinearScale(min, max);
      case ScaleKind.log:
        return LogScale(min, max);
      case ScaleKind.time:
        return TimeScale(min, max);
    }
  }

  @override
  void dispose() {
    _xViewport.removeListener(_forward);
    super.dispose();
  }
}

class _YWindow {
  _YWindow(this.min, this.max);
  double min;
  double max;
}
