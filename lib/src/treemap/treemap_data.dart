/// Recursive node for hierarchical visualization.
///
/// Leaves carry the only positive [value]; internal nodes compute their
/// total from children. Optional [color] and [label] are passed through to
/// the painter.
class TreemapNode {
  TreemapNode({
    required this.id,
    this.label = '',
    this.value = 0,
    this.children = const <TreemapNode>[],
    this.color,
  });

  final String id;
  final String label;
  final double value;
  final List<TreemapNode> children;

  /// Optional fill color. Painter falls back to a hash-of-id palette
  /// when null.
  final Object? color;

  /// Sum of leaf values reachable from this node.
  double get totalValue {
    if (children.isEmpty) return value;
    var sum = 0.0;
    for (final c in children) {
      sum += c.totalValue;
    }
    return sum;
  }

  bool get isLeaf => children.isEmpty;
}
