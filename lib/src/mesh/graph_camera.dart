import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// 2D camera over a graph: uniform scale + translation.
///
/// Internally just three doubles. A [Float64List] for the 4×4 matrix is
/// synthesized on demand for [canvas.transform], so we never pay for full
/// matrix math during a hit-test.
class GraphCamera extends ChangeNotifier {
  GraphCamera({
    double scale = 1.0,
    Offset translation = Offset.zero,
    this.minScale = 0.05,
    this.maxScale = 50,
  })  : _scale = scale,
        _tx = translation.dx,
        _ty = translation.dy;

  double _scale;
  double _tx, _ty;
  final double minScale;
  final double maxScale;

  double get scale => _scale;
  Offset get translation => Offset(_tx, _ty);

  /// 4×4 column-major matrix ready for `canvas.transform(...)`.
  Float64List get matrixStorage {
    final m = Float64List(16);
    m[0] = _scale;
    m[5] = _scale;
    m[10] = 1;
    m[15] = 1;
    m[12] = _tx;
    m[13] = _ty;
    return m;
  }

  Offset toWorld(Offset screen) {
    return Offset((screen.dx - _tx) / _scale, (screen.dy - _ty) / _scale);
  }

  Offset toScreen(Offset world) {
    return Offset(world.dx * _scale + _tx, world.dy * _scale + _ty);
  }

  void translate(double dx, double dy) {
    _tx += dx;
    _ty += dy;
    notifyListeners();
  }

  /// Zooms around a screen-space pixel anchor. The world point under the
  /// anchor stays fixed across the zoom.
  void zoomAt(double factor, Offset screenAnchor) {
    final newScale = (_scale * factor).clamp(minScale, maxScale);
    final actualFactor = newScale / _scale;
    _tx = screenAnchor.dx - (screenAnchor.dx - _tx) * actualFactor;
    _ty = screenAnchor.dy - (screenAnchor.dy - _ty) * actualFactor;
    _scale = newScale;
    notifyListeners();
  }

  void set(double scale, Offset translation) {
    _scale = scale.clamp(minScale, maxScale);
    _tx = translation.dx;
    _ty = translation.dy;
    notifyListeners();
  }

  /// Frames a world-space [Rect] inside [viewport] (screen size), leaving
  /// [padding] pixels around it.
  void fitTo(Rect worldRect, Size viewport, {double padding = 32}) {
    if (worldRect.width <= 0 || worldRect.height <= 0) return;
    final availW = viewport.width - padding * 2;
    final availH = viewport.height - padding * 2;
    final sx = availW / worldRect.width;
    final sy = availH / worldRect.height;
    final newScale = (sx < sy ? sx : sy).clamp(minScale, maxScale);
    final centerW = worldRect.center;
    _scale = newScale;
    _tx = viewport.width * 0.5 - centerW.dx * newScale;
    _ty = viewport.height * 0.5 - centerW.dy * newScale;
    notifyListeners();
  }
}

/// Camera animation controller. Tweens between camera snapshots with a
/// configurable curve — used by "enter a node" effects.
class GraphCameraController {
  GraphCameraController({
    required this.camera,
    required TickerProvider vsync,
    Duration duration = const Duration(milliseconds: 450),
    Curve curve = Curves.easeInOutCubic,
  })  : _ctrl = AnimationController(vsync: vsync, duration: duration),
        _curve = curve {
    _ctrl.addListener(_onTick);
  }

  final GraphCamera camera;
  final AnimationController _ctrl;
  Curve _curve;

  double _fromScale = 1, _toScale = 1;
  double _fromTx = 0, _toTx = 0;
  double _fromTy = 0, _toTy = 0;

  void animateTo({
    required double scale,
    required Offset translation,
    Duration? duration,
    Curve? curve,
  }) {
    _fromScale = camera.scale;
    _fromTx = camera.translation.dx;
    _fromTy = camera.translation.dy;
    _toScale = scale;
    _toTx = translation.dx;
    _toTy = translation.dy;
    if (duration != null) _ctrl.duration = duration;
    if (curve != null) _curve = curve;
    _ctrl
      ..stop()
      ..value = 0
      ..forward();
  }

  /// Smoothly frames [worldRect] inside [viewport].
  void animateFit(Rect worldRect, Size viewport,
      {double padding = 32, Duration? duration, Curve? curve}) {
    if (worldRect.width <= 0 || worldRect.height <= 0) return;
    final availW = viewport.width - padding * 2;
    final availH = viewport.height - padding * 2;
    final sx = availW / worldRect.width;
    final sy = availH / worldRect.height;
    final newScale =
        (sx < sy ? sx : sy).clamp(camera.minScale, camera.maxScale);
    final center = worldRect.center;
    final tx = viewport.width * 0.5 - center.dx * newScale;
    final ty = viewport.height * 0.5 - center.dy * newScale;
    animateTo(
      scale: newScale,
      translation: Offset(tx, ty),
      duration: duration,
      curve: curve,
    );
  }

  void _onTick() {
    final t = _curve.transform(_ctrl.value);
    camera.set(
      _fromScale + (_toScale - _fromScale) * t,
      Offset(
        _fromTx + (_toTx - _fromTx) * t,
        _fromTy + (_toTy - _fromTy) * t,
      ),
    );
  }

  void dispose() {
    _ctrl.removeListener(_onTick);
    _ctrl.dispose();
  }
}
