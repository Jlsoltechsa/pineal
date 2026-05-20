import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/viewport.dart';

/// Wraps a child with pan + pinch zoom that drive a [ChartViewport].
///
/// On pan-end, kicks off a [FrictionSimulation] so the chart glides to a
/// stop instead of snapping. The simulation only runs on the X axis (the
/// common case for time-series scrolling); Y inertia tends to feel wrong.
class GestureHandler extends StatefulWidget {
  const GestureHandler({
    super.key,
    required this.viewport,
    required this.child,
    this.allowYPan = false,
    this.allowZoom = true,
    this.inertiaFriction = 0.015,
  });

  final ChartViewport viewport;
  final Widget child;
  final bool allowYPan;
  final bool allowZoom;
  final double inertiaFriction;

  @override
  State<GestureHandler> createState() => _GestureHandlerState();
}

class _GestureHandlerState extends State<GestureHandler>
    with SingleTickerProviderStateMixin {
  // Initialised eagerly in initState — a `late final` initializer would
  // otherwise fire for the first time inside dispose() if the user never
  // triggered an inertial pan, and `createTicker` is illegal during the
  // tree-finalization phase ("looking up a deactivated widget's ancestor").
  late final Ticker _ticker;
  FrictionSimulation? _xSim;
  Duration? _simStart;

  Offset? _lastFocal;
  double _startScale = 1.0;
  Size _size = Size.zero;

  double _frozenXMin = 0;
  double _frozenXMax = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final sim = _xSim;
    if (sim == null) return;
    _simStart ??= elapsed;
    final t = (elapsed - _simStart!).inMicroseconds / 1e6;
    if (sim.isDone(t)) {
      _ticker.stop();
      _xSim = null;
      _simStart = null;
      return;
    }
    final double pos = sim.x(t);
    final double span = _frozenXMax - _frozenXMin;
    final double dxData = -pos / _size.width * span;
    widget.viewport.setWindow(
      xMin: _frozenXMin + dxData,
      xMax: _frozenXMax + dxData,
    );
  }

  void _onScaleStart(ScaleStartDetails d) {
    _ticker.stop();
    _xSim = null;
    _simStart = null;
    _lastFocal = d.focalPoint;
    _startScale = 1.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_size == Size.zero) return;
    final v = widget.viewport;
    final last = _lastFocal ?? d.focalPoint;

    final double dxPx = d.focalPoint.dx - last.dx;
    final double dyPx = d.focalPoint.dy - last.dy;
    final double dxFrac = -dxPx / _size.width;
    final double dyFrac = widget.allowYPan ? (dyPx / _size.height) : 0.0;
    if (dxFrac != 0 || dyFrac != 0) {
      v.pan(dxFrac, dyFrac);
    }

    if (widget.allowZoom && d.scale != _startScale && d.scale > 0) {
      final double factor = _startScale / d.scale;
      final anchor = d.focalPoint;
      final double ax = (anchor.dx / _size.width).clamp(0.0, 1.0);
      final double ay = (1.0 - anchor.dy / _size.height).clamp(0.0, 1.0);
      v.zoom(factor, anchorX: ax, anchorY: ay);
      _startScale = d.scale;
    }
    _lastFocal = d.focalPoint;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final double vx = d.velocity.pixelsPerSecond.dx;
    if (vx.abs() < 80 || _size.width == 0) return;
    _frozenXMin = widget.viewport.xMin;
    _frozenXMax = widget.viewport.xMax;
    _xSim = FrictionSimulation(widget.inertiaFriction, 0, vx);
    _simStart = null;
    _ticker.start();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        _size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: widget.child,
        );
      },
    );
  }
}
