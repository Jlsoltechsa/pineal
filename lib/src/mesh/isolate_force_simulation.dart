import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'edge_buffer.dart';
import 'graph_simulation.dart';
import 'layouts/force_directed_layout.dart';
import 'node_buffer.dart';

/// Force simulation that runs in a long-lived [Isolate].
///
/// The UI thread keeps a [NodeBuffer] for rendering and ships an initial
/// copy of the data to the worker. The worker integrates the physics on
/// its own timer and streams [Float32List] snapshots back via a [SendPort];
/// the UI thread copies them into its NodeBuffer and notifies listeners.
///
/// Commands (pin / unpin / move) are fire-and-forget messages going the
/// other direction. Drag operations also write the new position into the
/// local NodeBuffer immediately, so the cursor never lags behind.
class IsolateForceSimulation extends GraphSimulation {
  IsolateForceSimulation({
    required this.nodes,
    required this.edges,
    ForceParams params = const ForceParams(),
    Duration tickInterval = const Duration(milliseconds: 16),
  }) {
    _bootstrap(params, tickInterval);
  }

  final NodeBuffer nodes;
  final EdgeBuffer edges;

  Isolate? _isolate;
  SendPort? _toIsolate;
  final ReceivePort _fromIsolate = ReceivePort();

  Future<void> _bootstrap(
      ForceParams params, Duration tickInterval) async {
    _fromIsolate.listen(_onMessage);
    final init = _IsolateInit(
      sendPort: _fromIsolate.sendPort,
      nodesRaw: Float32List.fromList(nodes.raw),
      edgesRaw: Int32List.fromList(edges.raw),
      nodeCount: nodes.length,
      edgeCount: edges.length,
      repulsion: params.repulsion,
      springLength: params.springLength,
      springStrength: params.springStrength,
      gravity: params.gravity,
      damping: params.damping,
      theta: params.theta,
      maxVelocity: params.maxVelocity,
      tickIntervalUs: tickInterval.inMicroseconds,
    );
    _isolate = await Isolate.spawn(_isolateEntry, init,
        debugName: 'pineal.force');
  }

  void _onMessage(Object? msg) {
    if (msg is SendPort) {
      _toIsolate = msg;
    } else if (msg is Float32List) {
      // Snapshot of node positions. Same length as nodes.raw.
      if (msg.length == nodes.raw.length) {
        nodes.raw.setAll(0, msg);
        nodes.revision++;
        notifyListeners();
      }
    }
  }

  @override
  void pin(int index) =>
      _toIsolate?.send(<String, Object>{'op': 'pin', 'i': index});

  @override
  void unpin(int index) =>
      _toIsolate?.send(<String, Object>{'op': 'unpin', 'i': index});

  @override
  void movePinned(int index, double x, double y) {
    // Update local buffer immediately for cursor-tight feedback.
    nodes.setXY(index, x, y);
    nodes.revision++;
    notifyListeners();
    _toIsolate?.send(<String, Object>{'op': 'move', 'i': index, 'x': x, 'y': y});
  }

  @override
  void reheat({double alpha = 0.6}) =>
      _toIsolate?.send(<String, Object>{'op': 'reheat', 'a': alpha});

  @override
  void start() => _toIsolate?.send(<String, Object>{'op': 'start'});

  @override
  void stop() => _toIsolate?.send(<String, Object>{'op': 'stop'});

  @override
  void dispose() {
    _toIsolate?.send(<String, Object>{'op': 'dispose'});
    _fromIsolate.close();
    _isolate?.kill(priority: Isolate.immediate);
    super.dispose();
  }
}

/// Bootstrap payload sent to the worker. Only contains primitives /
/// TypedData so it crosses the isolate boundary without surprises.
class _IsolateInit {
  _IsolateInit({
    required this.sendPort,
    required this.nodesRaw,
    required this.edgesRaw,
    required this.nodeCount,
    required this.edgeCount,
    required this.repulsion,
    required this.springLength,
    required this.springStrength,
    required this.gravity,
    required this.damping,
    required this.theta,
    required this.maxVelocity,
    required this.tickIntervalUs,
  });

  final SendPort sendPort;
  final Float32List nodesRaw;
  final Int32List edgesRaw;
  final int nodeCount;
  final int edgeCount;
  final double repulsion;
  final double springLength;
  final double springStrength;
  final double gravity;
  final double damping;
  final double theta;
  final double maxVelocity;
  final int tickIntervalUs;
}

void _isolateEntry(_IsolateInit init) {
  final params = ForceParams(
    repulsion: init.repulsion,
    springLength: init.springLength,
    springStrength: init.springStrength,
    gravity: init.gravity,
    damping: init.damping,
    theta: init.theta,
    maxVelocity: init.maxVelocity,
  );

  final nodes = NodeBuffer.wrap(init.nodesRaw, init.nodeCount);
  final edges = EdgeBuffer.wrap(init.edgesRaw, init.edgeCount);
  final velocities = Float32List(nodes.length * 2);
  final stepper = ForceStepper(
    nodes: nodes,
    edges: edges,
    params: params,
    velocities: velocities,
  );

  final inbox = ReceivePort();
  init.sendPort.send(inbox.sendPort);

  var alpha = 1.0;
  const alphaTarget = 0.02;
  const alphaDecay = 0.012;
  var running = true;
  var disposed = false;

  inbox.listen((Object? msg) {
    if (msg is! Map) return;
    final op = msg['op'] as String?;
    switch (op) {
      case 'pin':
        stepper.pinned.add(msg['i'] as int);
        alpha = 0.6;
        break;
      case 'unpin':
        stepper.pinned.remove(msg['i'] as int);
        alpha = 0.4;
        break;
      case 'move':
        final i = msg['i'] as int;
        nodes.setXY(i, msg['x'] as double, msg['y'] as double);
        velocities[i * 2] = 0;
        velocities[i * 2 + 1] = 0;
        break;
      case 'reheat':
        alpha = (msg['a'] as double).clamp(0.0, 1.0);
        break;
      case 'start':
        running = true;
        break;
      case 'stop':
        running = false;
        break;
      case 'dispose':
        disposed = true;
        inbox.close();
        Isolate.current.kill();
        break;
    }
  });

  Timer.periodic(Duration(microseconds: init.tickIntervalUs), (timer) {
    if (disposed) {
      timer.cancel();
      return;
    }
    if (!running) return;
    if (alpha < alphaTarget && stepper.pinned.isEmpty) return;
    stepper.step(alpha);
    alpha += (alphaTarget - alpha) * alphaDecay;
    // Send a fresh snapshot. Copy so the UI thread isn't reading a buffer
    // we're about to mutate on the next tick.
    init.sendPort.send(Float32List.fromList(nodes.raw));
  });
}
