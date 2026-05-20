import 'package:flutter/widgets.dart';

import '../mesh/edge_buffer.dart';
import '../mesh/edge_renderer.dart';
import '../mesh/force_simulation.dart';
import '../mesh/graph_camera.dart';
import '../mesh/graph_gestures.dart';
import '../mesh/graph_painter.dart';
import '../mesh/graph_simulation.dart';
import '../mesh/layouts/graph_layout.dart';
import '../mesh/node_buffer.dart';
import '../mesh/node_renderer.dart';
import '../mesh/spatial_hash.dart';

/// Declarative entry point for the mesh module. Mirrors [PinealChart] in
/// spirit — declarative outside, imperative engine inside.
class PinealGraph extends StatefulWidget {
  const PinealGraph({
    super.key,
    required this.nodes,
    required this.edges,
    this.layout,
    this.edgeStyle = const EdgeStyle(),
    this.nodeStyle = const NodeStyle(),
    this.liveSimulation = false,
    this.forceParams,
    this.camera,
    this.cameraController,
    this.onNodeTap,
    this.onNodeDoubleTap,
    this.nodeBuilders = const <int, WidgetBuilder>{},
    this.initialFit = true,
    this.simulation,
    this.topMostIndex,
  });

  final NodeBuffer nodes;
  final EdgeBuffer edges;

  /// Optional one-shot layout applied on first build. `null` keeps the
  /// positions the [NodeBuffer] already has.
  final GraphLayout? layout;

  final EdgeStyle edgeStyle;
  final NodeStyle nodeStyle;

  /// If true, spawns a [ForceSimulation] driven by a [Ticker] so the graph
  /// keeps re-organizing as the user drags nodes.
  final bool liveSimulation;

  final dynamic forceParams; // ForceParams from layouts/force_directed_layout.

  final GraphCamera? camera;
  final GraphCameraController? cameraController;

  final void Function(int nodeIndex)? onNodeTap;
  final void Function(int nodeIndex)? onNodeDoubleTap;

  /// Node-index → custom widget builder. Each entry mounts a Flutter widget
  /// pinned to the node's world position. Useful for "container nodes" that
  /// embed a mini chart or arbitrary UI.
  final Map<int, WidgetBuilder> nodeBuilders;

  /// If true, the camera fits to the layout's bounding box on first frame.
  final bool initialFit;

  /// User-supplied simulation. When non-null, [liveSimulation] is ignored
  /// and the widget treats this instance as the source of physics updates.
  /// Pass an [IsolateForceSimulation] here to push physics off the UI
  /// thread.
  final GraphSimulation? simulation;

  /// Node-builder index to render last (i.e. on top of every other
  /// node-widget). Useful for hover / focus states where the active
  /// node should rise above its neighbours without changing layout.
  /// Pass `null` to keep the natural map iteration order.
  final int? topMostIndex;

  @override
  State<PinealGraph> createState() => _PinealGraphState();
}

class _PinealGraphState extends State<PinealGraph>
    with TickerProviderStateMixin {
  late GraphCamera _camera;
  GraphSimulation? _simulation;
  bool _ownsSimulation = false;
  late EdgeRenderer _edgeRenderer;
  late NodeRenderer _nodeRenderer;
  SpatialHash? _hash;
  int _hashRevision = -1;
  bool _fitDone = false;

  @override
  void initState() {
    super.initState();
    _camera = widget.camera ?? GraphCamera();
    _edgeRenderer = EdgeRenderer(style: widget.edgeStyle);
    _nodeRenderer = NodeRenderer(style: widget.nodeStyle)
      ..widgetBackedIndices = widget.nodeBuilders.keys.toSet();
    if (widget.layout != null) {
      widget.layout!.apply(widget.nodes, widget.edges);
    }
    if (widget.simulation != null) {
      _simulation = widget.simulation;
      _ownsSimulation = false;
    } else if (widget.liveSimulation) {
      _simulation = ForceSimulation(
        nodes: widget.nodes,
        edges: widget.edges,
        vsync: this,
      );
      _ownsSimulation = true;
    }
  }

  @override
  void didUpdateWidget(covariant PinealGraph old) {
    super.didUpdateWidget(old);
    if (old.edgeStyle != widget.edgeStyle) {
      _edgeRenderer.style = widget.edgeStyle;
    }
    if (old.nodeStyle != widget.nodeStyle ||
        old.nodeBuilders != widget.nodeBuilders) {
      _nodeRenderer.style = widget.nodeStyle;
      _nodeRenderer.widgetBackedIndices = widget.nodeBuilders.keys.toSet();
    }
  }

  @override
  void dispose() {
    if (_ownsSimulation) _simulation?.dispose();
    super.dispose();
  }

  SpatialHash _ensureHash() {
    final rev = widget.nodes.revision;
    if (_hash == null || _hashRevision != rev) {
      final maxR = _maxRadius();
      _hash = SpatialHash.build(widget.nodes, cellSize: maxR * 2 + 8);
      _hashRevision = rev;
    }
    return _hash!;
  }

  double _maxRadius() {
    var r = 1.0;
    for (var i = 0; i < widget.nodes.length; i++) {
      final v = widget.nodes.r(i);
      if (v > r) r = v;
    }
    return r;
  }

  void _maybeFit(Size size) {
    if (_fitDone || !widget.initialFit || widget.nodes.length == 0) return;
    final b = widget.nodes.bounds();
    final rect = Rect.fromLTRB(b.xMin, b.yMin, b.xMax, b.yMax);
    _camera.fitTo(rect, size);
    _fitDone = true;
  }

  @override
  Widget build(BuildContext context) {
    final repaint = Listenable.merge([
      _camera,
      if (_simulation != null) _simulation!,
    ]);

    return LayoutBuilder(
      builder: (ctx, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _maybeFit(constraints.biggest);
        });

        final painter = GraphPainter(
          camera: _camera,
          nodes: widget.nodes,
          edges: widget.edges,
          edgeRenderer: _edgeRenderer,
          nodeRenderer: _nodeRenderer,
          repaint: repaint,
        );

        return GraphGestureHandler(
          camera: _camera,
          nodes: widget.nodes,
          simulation: _simulation,
          spatialHashBuilder: _ensureHash,
          onNodeTap: widget.onNodeTap,
          onNodeDoubleTap: widget.onNodeDoubleTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(painter: painter, size: Size.infinite),
              ),
              if (widget.nodeBuilders.isNotEmpty)
                _NodeWidgetOverlay(
                  camera: _camera,
                  nodes: widget.nodes,
                  builders: widget.nodeBuilders,
                  topMostIndex: widget.topMostIndex,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Mounts custom widgets at node positions. Only nodes whose screen
/// projection falls inside the viewport are added to the tree.
class _NodeWidgetOverlay extends StatelessWidget {
  const _NodeWidgetOverlay({
    required this.camera,
    required this.nodes,
    required this.builders,
    this.topMostIndex,
  });

  final GraphCamera camera;
  final NodeBuffer nodes;
  final Map<int, WidgetBuilder> builders;
  final int? topMostIndex;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: false,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          return AnimatedBuilder(
            animation: camera,
            builder: (ctx, _) {
              final size = constraints.biggest;
              final viewport = Rect.fromLTWH(0, 0, size.width, size.height);
              final children = <Widget>[];
              Widget? topMost;
              builders.forEach((index, builder) {
                if (index < 0 || index >= nodes.length) return;
                final screen = camera.toScreen(Offset(nodes.x(index), nodes.y(index)));
                if (!viewport.contains(screen)) return;
                final w = Positioned(
                  left: screen.dx,
                  top: screen.dy,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, -0.5),
                    child: Builder(builder: builder),
                  ),
                );
                if (topMostIndex != null && index == topMostIndex) {
                  topMost = w;
                } else {
                  children.add(w);
                }
              });
              if (topMost != null) children.add(topMost!);
              // `Clip.none` lets hovered/elevated nodes paint their
              // shadow and scaled bounds outside the immediate stack
              // bounds without being clipped at the chart edge.
              return Stack(clipBehavior: Clip.none, children: children);
            },
          );
        },
      ),
    );
  }
}
