import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Tuning knobs for the force model.
class ForceParams {
  const ForceParams({
    this.repulsion = 1200,
    this.springLength = 60,
    this.springStrength = 0.05,
    this.gravity = 0.04,
    this.damping = 0.85,
    this.theta = 0.9,
    this.maxVelocity = 30,
  });

  /// Coulomb-like repulsion coefficient. Higher = nodes push apart harder.
  final double repulsion;

  /// Ideal edge rest length, in world units.
  final double springLength;

  /// Hooke stiffness. Higher = edges snap back faster.
  final double springStrength;

  /// Pull toward the origin per step. Keeps disconnected components on screen.
  final double gravity;

  /// Velocity decay each tick. `1.0` = no damping (oscillates forever).
  final double damping;

  /// Barnes-Hut tradeoff. `0` = exact (O(n²)); higher = more approximation.
  final double theta;

  final double maxVelocity;
}

/// One-shot force-directed layout: runs [iterations] integration steps and
/// returns. Use [ForceSimulation] for an interactive, ticking simulation.
class ForceDirectedLayout extends GraphLayout {
  const ForceDirectedLayout({
    this.iterations = 240,
    this.params = const ForceParams(),
    this.seedRandomly = true,
  });

  final int iterations;
  final ForceParams params;
  final bool seedRandomly;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final n = nodes.length;
    if (n == 0) return;

    if (seedRandomly) {
      final rng = math.Random(7);
      final spread = math.sqrt(n) * params.springLength;
      for (var i = 0; i < n; i++) {
        nodes.setXY(i, (rng.nextDouble() - 0.5) * spread,
            (rng.nextDouble() - 0.5) * spread);
      }
    }

    final velocities = Float32List(n * 2);
    final sim = ForceStepper(
        nodes: nodes,
        edges: edges,
        params: params,
        velocities: velocities);
    for (var i = 0; i < iterations; i++) {
      final alpha = math.max(0.05, 1.0 - i / iterations);
      sim.step(alpha);
    }
    nodes.revision++;
  }
}

/// Stateless-ish helper that runs a single integration step. Used by both
/// the one-shot layout and the live [ForceSimulation] controller.
///
/// Holds a pooled [_QuadTree] internally, so repeated [step] invocations
/// reuse the same backing [Float32List] instead of allocating one per frame.
class ForceStepper {
  ForceStepper({
    required this.nodes,
    required this.edges,
    required this.params,
    required this.velocities,
  });

  final NodeBuffer nodes;
  final EdgeBuffer edges;
  final ForceParams params;
  final Float32List velocities;
  final Set<int> pinned = <int>{};

  late final _QuadTree _tree = _QuadTree();
  late final Float32List _fx = Float32List(nodes.length);
  late final Float32List _fy = Float32List(nodes.length);

  void step(double alpha) {
    final n = nodes.length;
    if (n == 0) return;

    // Zero force accumulators (one tight memset-style loop).
    for (var i = 0; i < n; i++) {
      _fx[i] = 0;
      _fy[i] = 0;
    }

    // Repulsion: Barnes-Hut quadtree (rebuilt in place each frame).
    _tree.rebuild(nodes);
    for (var i = 0; i < n; i++) {
      _tree.force(i, nodes.x(i), nodes.y(i), params, _fx, _fy);
    }

    // Springs: Hooke's law between adjacent nodes.
    for (var e = 0; e < edges.length; e++) {
      final s = edges.src(e), t = edges.tgt(e);
      if (s == t) continue;
      final dx = nodes.x(t) - nodes.x(s);
      final dy = nodes.y(t) - nodes.y(s);
      final dist = math.sqrt(dx * dx + dy * dy) + 1e-6;
      final force = (dist - params.springLength) * params.springStrength;
      final ux = dx / dist * force;
      final uy = dy / dist * force;
      _fx[s] += ux;
      _fy[s] += uy;
      _fx[t] -= ux;
      _fy[t] -= uy;
    }

    // Gravity toward origin.
    for (var i = 0; i < n; i++) {
      _fx[i] -= nodes.x(i) * params.gravity;
      _fy[i] -= nodes.y(i) * params.gravity;
    }

    // Integrate (semi-implicit Euler) + damping + velocity clamp.
    for (var i = 0; i < n; i++) {
      if (pinned.contains(i)) {
        velocities[i * 2] = 0;
        velocities[i * 2 + 1] = 0;
        continue;
      }
      var vx = (velocities[i * 2] + _fx[i] * alpha) * params.damping;
      var vy = (velocities[i * 2 + 1] + _fy[i] * alpha) * params.damping;
      final speed = math.sqrt(vx * vx + vy * vy);
      if (speed > params.maxVelocity) {
        final k = params.maxVelocity / speed;
        vx *= k;
        vy *= k;
      }
      velocities[i * 2] = vx;
      velocities[i * 2 + 1] = vy;
      nodes.setXY(i, nodes.x(i) + vx, nodes.y(i) + vy);
    }
  }
}

/// Stateful, pool-friendly quadtree.
///
/// Slot layout (stride = 7 floats):
///   0..1: centre of mass X/Y
///   2:    total mass
///   3..5: bounds half-size, centre X, centre Y
///   6:    -1 = empty,
///         -(bodyIndex + 2) = leaf with single body,
///         base ≥ 0 = first child slot index
class _QuadTree {
  static const int _stride = 7;
  Float32List _buf = Float32List(8 * _stride);
  int _nextSlot = 1;

  void rebuild(NodeBuffer nodes) {
    final n = nodes.length;
    final required = math.max(8, n * 4);
    if (_buf.length < required * _stride) {
      _buf = Float32List(required * _stride);
    }

    // Reset only the portion we touched last time. Cheap when graphs stay
    // similar in size across frames (typical for live simulations).
    final used = math.min(_buf.length, _nextSlot * _stride);
    for (var i = 0; i < used; i++) {
      _buf[i] = 0;
    }
    _nextSlot = 1;

    final b = nodes.bounds();
    final cx = (b.xMin + b.xMax) * 0.5;
    final cy = (b.yMin + b.yMax) * 0.5;
    final half = math.max(b.xMax - b.xMin, b.yMax - b.yMin) * 0.5 + 1.0;
    _writeEmptyNode(0, half, cx, cy);

    for (var i = 0; i < n; i++) {
      _insert(0, i, nodes.x(i), nodes.y(i));
    }
  }

  void _writeEmptyNode(int slot, double half, double cx, double cy) {
    final o = slot * _stride;
    _buf[o] = 0;
    _buf[o + 1] = 0;
    _buf[o + 2] = 0;
    _buf[o + 3] = half;
    _buf[o + 4] = cx;
    _buf[o + 5] = cy;
    _buf[o + 6] = -1;
  }

  int _claimChildren() {
    // Grow if there's no room for 4 more slots.
    if ((_nextSlot + 4) * _stride > _buf.length) {
      final grown = Float32List(_buf.length * 2);
      grown.setRange(0, _buf.length, _buf);
      _buf = grown;
    }
    final base = _nextSlot;
    _nextSlot += 4;
    return base;
  }

  void _insert(int slot, int bodyIndex, double x, double y) {
    while (true) {
      final o = slot * _stride;
      final mass = _buf[o + 2];
      final cmX = _buf[o];
      final cmY = _buf[o + 1];
      final half = _buf[o + 3];
      final cx = _buf[o + 4];
      final cy = _buf[o + 5];
      final childBase = _buf[o + 6].toInt();

      // Empty leaf — store body directly.
      if (mass == 0 && childBase == -1) {
        _buf[o] = x;
        _buf[o + 1] = y;
        _buf[o + 2] = 1;
        _buf[o + 6] = (-(bodyIndex + 2)).toDouble();
        return;
      }

      // Leaf with a single body — split.
      if (childBase < -1) {
        final existing = -childBase - 2;
        final base = _claimChildren();
        final qh = half * 0.5;
        for (var k = 0; k < 4; k++) {
          final qx = cx + ((k & 1) == 0 ? -qh : qh);
          final qy = cy + ((k & 2) == 0 ? -qh : qh);
          _writeEmptyNode(base + k, qh, qx, qy);
        }
        _buf[o + 6] = base.toDouble();
        _buf[o + 2] = 0;
        _buf[o] = 0;
        _buf[o + 1] = 0;
        _insert(_childSlot(base, cx, cy, cmX, cmY), existing, cmX, cmY);
        _accumulateCm(slot, cmX, cmY);
        continue;
      }

      // Internal node — accumulate centre of mass and recurse.
      _accumulateCm(slot, x, y);
      slot = _childSlot(childBase, cx, cy, x, y);
    }
  }

  int _childSlot(int base, double cx, double cy, double x, double y) {
    final right = x >= cx ? 1 : 0;
    final bottom = y >= cy ? 2 : 0;
    return base + (right | bottom);
  }

  void _accumulateCm(int slot, double x, double y) {
    final o = slot * _stride;
    final m = _buf[o + 2];
    final total = m + 1;
    _buf[o] = (_buf[o] * m + x) / total;
    _buf[o + 1] = (_buf[o + 1] * m + y) / total;
    _buf[o + 2] = total;
  }

  /// Adds the repulsive contribution toward node [self] into [fxOut]/[fyOut].
  void force(int self, double x, double y, ForceParams p,
      Float32List fxOut, Float32List fyOut) {
    final stack = _stack;
    var stackLen = 0;
    stack[stackLen++] = 0;
    final thetaSq = p.theta * p.theta;
    while (stackLen > 0) {
      final slot = stack[--stackLen];
      final o = slot * _stride;
      final mass = _buf[o + 2];
      if (mass == 0) continue;
      final cmX = _buf[o];
      final cmY = _buf[o + 1];
      final half = _buf[o + 3];
      final childBase = _buf[o + 6].toInt();

      final dx = cmX - x;
      final dy = cmY - y;
      final distSq = dx * dx + dy * dy + 1e-6;

      if (childBase >= -1) {
        final size = half * 2;
        if (childBase == -1 || (size * size) / distSq < thetaSq) {
          final dist = math.sqrt(distSq);
          final repel = -p.repulsion * mass / distSq;
          fxOut[self] += dx / dist * repel;
          fyOut[self] += dy / dist * repel;
          continue;
        }
        // Grow stack if needed.
        if (stackLen + 4 > stack.length) {
          _stack = Int32List(stack.length * 2)..setRange(0, stack.length, stack);
        }
        _stack[stackLen++] = childBase;
        _stack[stackLen++] = childBase + 1;
        _stack[stackLen++] = childBase + 2;
        _stack[stackLen++] = childBase + 3;
      } else {
        final body = -childBase - 2;
        if (body == self) continue;
        final dist = math.sqrt(distSq);
        final repel = -p.repulsion / distSq;
        fxOut[self] += dx / dist * repel;
        fyOut[self] += dy / dist * repel;
      }
    }
  }

  Int32List _stack = Int32List(128);
}
