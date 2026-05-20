/// Node in a Sankey/alluvial diagram.
class FlowNode {
  const FlowNode({
    required this.id,
    this.label = '',
    this.color,
  });
  final String id;
  final String label;

  /// Optional fill color. Painter falls back to a hash-of-id palette.
  final Object? color;
}

/// Directed, weighted link between two [FlowNode]s.
class FlowLink {
  const FlowLink({
    required this.source,
    required this.target,
    required this.value,
    this.color,
  });

  /// Source node id.
  final String source;

  /// Target node id.
  final String target;

  /// Width of the ribbon at both endpoints.
  final double value;

  /// Optional ribbon color. Painter falls back to a translucent mix of the
  /// endpoint node colors.
  final Object? color;
}
