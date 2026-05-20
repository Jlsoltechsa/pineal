import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'edge_buffer.dart';
import 'graph_simulation.dart';
import 'layouts/force_directed_layout.dart';
import 'node_buffer.dart';

/// Live, ticking force-directed simulation that runs on the UI thread.
///
/// Wraps a [ForceStepper] in a Ticker so the layout converges over real
/// frames instead of one synchronous burst. Lets the user drag nodes (which
/// pin them temporarily) and watch the rest of the graph reorganize.
///
/// For graphs above ~1500 nodes prefer [IsolateForceSimulation] so the UI
/// thread keeps its frame budget free for rendering.
class ForceSimulation extends GraphSimulation {
  ForceSimulation({
    required this.nodes,
    required this.edges,
    required TickerProvider vsync,
    ForceParams params = const ForceParams(),
    bool autoStart = true,
  }) : _params = params {
    _velocities = Float32List(nodes.length * 2);
    _stepper = ForceStepper(
      nodes: nodes,
      edges: edges,
      params: params,
      velocities: _velocities,
    );
    _ticker = vsync.createTicker(_onTick);
    if (autoStart) start();
  }

  final NodeBuffer nodes;
  final EdgeBuffer edges;
  final ForceParams _params;
  late final ForceStepper _stepper;
  late final Ticker _ticker;
  late final Float32List _velocities;

  double _alpha = 1.0;
  final double _alphaTarget = 0.02;
  final double _alphaDecay = 0.012;

  @override
  void pin(int index) {
    _stepper.pinned.add(index);
    reheat();
  }

  @override
  void unpin(int index) {
    _stepper.pinned.remove(index);
    reheat();
  }

  void unpinAll() => _stepper.pinned.clear();

  @override
  void movePinned(int index, double x, double y) {
    nodes.setXY(index, x, y);
    _velocities[index * 2] = 0;
    _velocities[index * 2 + 1] = 0;
    notifyListeners();
  }

  ForceParams get params => _params;

  @override
  void reheat({double alpha = 0.6}) {
    _alpha = alpha;
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void start() {
    if (!_ticker.isActive) _ticker.start();
  }

  @override
  void stop() {
    if (_ticker.isActive) _ticker.stop();
  }

  void _onTick(Duration _) {
    if (_alpha < _alphaTarget && _stepper.pinned.isEmpty) {
      _ticker.stop();
      return;
    }
    _stepper.step(_alpha);
    _alpha += (_alphaTarget - _alpha) * _alphaDecay;
    nodes.revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
