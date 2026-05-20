import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'edge_buffer.dart';
import 'edge_renderer.dart';
import 'graph_camera.dart';
import 'node_buffer.dart';
import 'node_renderer.dart';

/// Paints edges then nodes, transformed by [camera]. Single repaint listenable
/// covering both camera and (optional) simulation, so a node drag re-renders
/// without rebuilding the widget tree.
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.camera,
    required this.nodes,
    required this.edges,
    required this.edgeRenderer,
    required this.nodeRenderer,
    Listenable? repaint,
  }) : super(repaint: repaint ?? camera);

  final GraphCamera camera;
  final NodeBuffer nodes;
  final EdgeBuffer edges;
  final EdgeRenderer edgeRenderer;
  final NodeRenderer nodeRenderer;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.transform(camera.matrixStorage);
    edgeRenderer.paint(canvas, nodes, edges);
    nodeRenderer.paint(canvas, nodes);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GraphPainter old) {
    return old.nodes != nodes ||
        old.edges != edges ||
        old.edgeRenderer != edgeRenderer ||
        old.nodeRenderer != nodeRenderer;
  }
}
