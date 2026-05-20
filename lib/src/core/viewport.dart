import 'package:flutter/foundation.dart';

import 'coordinate_system.dart';

/// Mutable, listenable window into the data domain. Drives zoom and pan.
///
/// We notify listeners on any change but tag the change kind so the render
/// layer can choose between a cheap raster blit (translation only) or a full
/// repaint (scale change).
enum ChartViewportChange { pan, zoom, reset }

class ChartViewport extends ChangeNotifier implements ValueListenable<ChartViewport> {
  ChartViewport({
    required double xMin,
    required double xMax,
    required double yMin,
    required double yMax,
  })  : _xMin = xMin,
        _xMax = xMax,
        _yMin = yMin,
        _yMax = yMax,
        _initialXMin = xMin,
        _initialXMax = xMax,
        _initialYMin = yMin,
        _initialYMax = yMax;

  double _xMin, _xMax, _yMin, _yMax;
  final double _initialXMin, _initialXMax, _initialYMin, _initialYMax;
  ChartViewportChange _lastChange = ChartViewportChange.reset;

  double get xMin => _xMin;
  double get xMax => _xMax;
  double get yMin => _yMin;
  double get yMax => _yMax;
  double get xSpan => _xMax - _xMin;
  double get ySpan => _yMax - _yMin;
  ChartViewportChange get lastChange => _lastChange;

  @override
  ChartViewport get value => this;

  /// Translates the window by a fraction of its current size on each axis.
  /// `dxFrac = 0.1` shifts the view 10% to the right.
  void pan(double dxFrac, double dyFrac) {
    final dx = dxFrac * xSpan;
    final dy = dyFrac * ySpan;
    _xMin += dx;
    _xMax += dx;
    _yMin += dy;
    _yMax += dy;
    _lastChange = ChartViewportChange.pan;
    notifyListeners();
  }

  /// Scales the window around a normalized anchor (0..1 along each axis).
  void zoom(double factor, {double anchorX = 0.5, double anchorY = 0.5}) {
    final ax = _xMin + anchorX * xSpan;
    final ay = _yMin + anchorY * ySpan;
    _xMin = ax + (_xMin - ax) * factor;
    _xMax = ax + (_xMax - ax) * factor;
    _yMin = ay + (_yMin - ay) * factor;
    _yMax = ay + (_yMax - ay) * factor;
    _lastChange = ChartViewportChange.zoom;
    notifyListeners();
  }

  /// Independent zoom factors per axis. Used by pinch when the gesture is
  /// directional (mostly horizontal vs vertical).
  void zoomAxes(double fx, double fy,
      {double anchorX = 0.5, double anchorY = 0.5}) {
    final ax = _xMin + anchorX * xSpan;
    final ay = _yMin + anchorY * ySpan;
    _xMin = ax + (_xMin - ax) * fx;
    _xMax = ax + (_xMax - ax) * fx;
    _yMin = ay + (_yMin - ay) * fy;
    _yMax = ay + (_yMax - ay) * fy;
    _lastChange = ChartViewportChange.zoom;
    notifyListeners();
  }

  void reset() {
    _xMin = _initialXMin;
    _xMax = _initialXMax;
    _yMin = _initialYMin;
    _yMax = _initialYMax;
    _lastChange = ChartViewportChange.reset;
    notifyListeners();
  }

  void setWindow({double? xMin, double? xMax, double? yMin, double? yMax}) {
    _xMin = xMin ?? _xMin;
    _xMax = xMax ?? _xMax;
    _yMin = yMin ?? _yMin;
    _yMax = yMax ?? _yMax;
    _lastChange = ChartViewportChange.zoom;
    notifyListeners();
  }

  /// Builds a [LinearScale] pair matching the current window.
  ({LinearScale x, LinearScale y}) toScales() {
    return (x: LinearScale(_xMin, _xMax), y: LinearScale(_yMin, _yMax));
  }
}
