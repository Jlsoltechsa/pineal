import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'graph_camera.dart';
import 'graph_simulation.dart';
import 'node_buffer.dart';
import 'spatial_hash.dart';

/// Pan / pinch / drag handler for [PinealGraph]. Routes:
///
/// * Empty-space drag → translate the [GraphCamera].
/// * Pinch → zoom the camera around the focal point.
/// * Drag started on a node → pin the node in [simulation] (if provided)
///   and follow the pointer until release.
/// * Pan release with velocity → friction-based glide on the camera.
class GraphGestureHandler extends StatefulWidget {
  const GraphGestureHandler({
    super.key,
    required this.camera,
    required this.nodes,
    required this.child,
    this.simulation,
    this.spatialHashBuilder,
    this.onNodeTap,
    this.onNodeDoubleTap,
    this.inertiaFriction = 0.015,
    this.wheelZoomSensitivity = 0.0015,
  });

  final GraphCamera camera;
  final NodeBuffer nodes;
  final Widget child;
  final GraphSimulation? simulation;

  /// Caller can supply a hash that's already up-to-date; we rebuild lazily
  /// otherwise.
  final SpatialHash Function()? spatialHashBuilder;

  final void Function(int nodeIndex)? onNodeTap;
  final void Function(int nodeIndex)? onNodeDoubleTap;
  final double inertiaFriction;

  /// How much one wheel notch zooms in/out. Larger = snappier; smaller =
  /// smoother. Trackpad scrolls are dominated by their own delta so this
  /// stays subtle.
  final double wheelZoomSensitivity;

  @override
  State<GraphGestureHandler> createState() => _GraphGestureHandlerState();
}

class _GraphGestureHandlerState extends State<GraphGestureHandler>
    with SingleTickerProviderStateMixin {
  // Initialised eagerly in initState — a `late final` initializer would
  // otherwise fire for the first time inside dispose() if the user never
  // triggered an inertial pan, and `createTicker` is illegal during the
  // tree-finalization phase ("looking up a deactivated widget's ancestor").
  late final Ticker _ticker;
  FrictionSimulation? _frictionX;
  FrictionSimulation? _frictionY;
  Duration? _simStart;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  Offset? _lastFocal;
  double _startScale = 1.0;
  Size _size = Size.zero;

  int _draggedNode = -1;

  void _onTick(Duration elapsed) {
    final fx = _frictionX, fy = _frictionY;
    if (fx == null || fy == null) return;
    _simStart ??= elapsed;
    final t = (elapsed - _simStart!).inMicroseconds / 1e6;
    if (fx.isDone(t) && fy.isDone(t)) {
      _ticker.stop();
      _frictionX = null;
      _frictionY = null;
      _simStart = null;
      return;
    }
    final dx = fx.dx(t);
    final dy = fy.dx(t);
    widget.camera.translate(dx / 60.0, dy / 60.0);
  }

  SpatialHash _hash() {
    return widget.spatialHashBuilder?.call() ??
        SpatialHash.build(widget.nodes, cellSize: 64);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _ticker.stop();
    _frictionX = null;
    _frictionY = null;
    _lastFocal = d.focalPoint;
    _startScale = 1.0;

    final world = widget.camera.toWorld(d.localFocalPoint);
    final hit = _hash().hitTest(widget.nodes, world.dx, world.dy);
    if (hit >= 0) {
      _draggedNode = hit;
      widget.simulation?.pin(hit);
    } else {
      _draggedNode = -1;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_size == Size.zero) return;

    if (_draggedNode >= 0) {
      final world = widget.camera.toWorld(d.localFocalPoint);
      final sim = widget.simulation;
      if (sim != null) {
        sim.movePinned(_draggedNode, world.dx, world.dy);
      } else {
        widget.nodes.setXY(_draggedNode, world.dx, world.dy);
        widget.nodes.revision++;
      }
      _lastFocal = d.focalPoint;
      return;
    }

    final last = _lastFocal ?? d.focalPoint;
    final dx = d.focalPoint.dx - last.dx;
    final dy = d.focalPoint.dy - last.dy;
    widget.camera.translate(dx, dy);

    if (d.scale != _startScale && d.scale > 0) {
      final factor = d.scale / _startScale;
      widget.camera.zoomAt(factor, d.localFocalPoint);
      _startScale = d.scale;
    }
    _lastFocal = d.focalPoint;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_draggedNode >= 0) {
      widget.simulation?.unpin(_draggedNode);
      _draggedNode = -1;
      return;
    }
    final v = d.velocity.pixelsPerSecond;
    if (v.distance < 80) return;
    _frictionX = FrictionSimulation(widget.inertiaFriction, 0, v.dx);
    _frictionY = FrictionSimulation(widget.inertiaFriction, 0, v.dy);
    _simStart = null;
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTap(TapUpDetails d) {
    final world = widget.camera.toWorld(d.localPosition);
    final hit = _hash().hitTest(widget.nodes, world.dx, world.dy);
    if (hit >= 0) widget.onNodeTap?.call(hit);
  }

  void _onDoubleTap(TapDownDetails d) {
    final world = widget.camera.toWorld(d.localPosition);
    final hit = _hash().hitTest(widget.nodes, world.dx, world.dy);
    if (hit >= 0) widget.onNodeDoubleTap?.call(hit);
  }

  TapDownDetails? _lastDoubleTapDetails;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Standard exponential zoom: each notch multiplies scale by `e^k`,
    // anchored at the cursor so the world point under the pointer stays
    // put across the zoom.
    final factor = math.exp(-event.scrollDelta.dy * widget.wheelZoomSensitivity);
    widget.camera.zoomAt(factor, event.localPosition);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        _size = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerSignal: _onPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onTapUp: _onTap,
            onDoubleTapDown: (d) => _lastDoubleTapDetails = d,
            onDoubleTap: () {
              final d = _lastDoubleTapDetails;
              if (d != null) _onDoubleTap(d);
            },
            child: widget.child,
          ),
        );
      },
    );
  }
}
