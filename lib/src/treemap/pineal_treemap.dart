import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'squarify.dart';
import 'treemap_data.dart';

/// Visual configuration applied to every tile in the tree.
class TreemapStyle {
  const TreemapStyle({
    this.padding = 1.0,
    this.borderColor = const Color(0x66000000),
    this.borderWidth = 0.5,
    this.labelColor = const Color(0xFFFFFFFF),
    this.labelFontSize = 11,
    this.categoryLabelColor = const Color(0xFFCBD2D8),
    this.categoryLabelFontSize = 13,
    this.minTileSideForLabel = 32,
    this.categoryBackgroundOpacity = 0.18,
    this.categoryPadding = 4.0,
    this.headerHeight = 18,
    this.showRootLabel = false,
  });

  /// Padding around each leaf rect.
  final double padding;

  final Color borderColor;
  final double borderWidth;
  final Color labelColor;
  final double labelFontSize;

  /// Style for internal-node labels (depth-1 categories).
  final Color categoryLabelColor;
  final double categoryLabelFontSize;

  /// Tiles smaller than this in either dimension skip their label.
  final double minTileSideForLabel;

  /// Background tint applied to category (depth-1) rects so the user can
  /// see the grouping even when leaves are tightly packed. Multiplied with
  /// the category's base color and alpha-blended on top of the canvas.
  final double categoryBackgroundOpacity;

  /// Extra padding around the leaves *inside* a category, in pixels. Adds
  /// to [padding] for nested visuals.
  final double categoryPadding;

  /// Height reserved at the top of each category rect for its label.
  final double headerHeight;

  /// Whether to draw the depth-0 label (usually the dataset name). Off by
  /// default because it tends to overlap the whole canvas.
  final bool showRootLabel;
}

/// Squarified treemap widget. All tiles share one painter and one
/// gesture detector — hit testing walks the layout list once, no
/// per-tile widgets.
class PinealTreemap extends StatefulWidget {
  const PinealTreemap({
    super.key,
    required this.root,
    this.style = const TreemapStyle(),
    this.onTileTap,
    this.colorOf,
  });

  final TreemapNode root;
  final TreemapStyle style;

  final void Function(TreemapNode node)? onTileTap;

  /// Optional per-node color override. Falls back to [TreemapNode.color]
  /// (if [Color]) and ultimately to a hash-of-categoryId palette with a
  /// per-leaf brightness wobble.
  final Color Function(TreemapNode)? colorOf;

  @override
  State<PinealTreemap> createState() => _PinealTreemapState();
}

class _PinealTreemapState extends State<PinealTreemap> {
  List<TreemapTile>? _tiles;
  Size? _lastSize;
  int _rootHash = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final size = constraints.biggest;
      final h = _hashRoot(widget.root);
      if (_tiles == null || _lastSize != size || _rootHash != h) {
        _tiles = squarify(widget.root, Offset.zero & size);
        _lastSize = size;
        _rootHash = h;
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: widget.onTileTap == null
            ? null
            : (d) {
                final hit = _hitTest(d.localPosition);
                if (hit != null) widget.onTileTap!(hit);
              },
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _TreemapPainter(
              tiles: _tiles!,
              style: widget.style,
              colorOf: widget.colorOf,
            ),
            size: Size.infinite,
          ),
        ),
      );
    });
  }

  int _hashRoot(TreemapNode node) {
    var h = node.id.hashCode ^ node.value.hashCode;
    for (final c in node.children) {
      h = (h * 31) ^ _hashRoot(c);
    }
    return h;
  }

  TreemapNode? _hitTest(Offset p) {
    if (_tiles == null) return null;
    // Walk in reverse so deeper/smaller tiles win over their ancestors.
    for (var i = _tiles!.length - 1; i >= 0; i--) {
      final t = _tiles![i];
      if (t.node.isLeaf && t.rect.contains(p)) return t.node;
    }
    return null;
  }
}

class _TreemapPainter extends CustomPainter {
  _TreemapPainter({
    required this.tiles,
    required this.style,
    required this.colorOf,
  });

  final List<TreemapTile> tiles;
  final TreemapStyle style;
  final Color Function(TreemapNode)? colorOf;

  static const _palette = <Color>[
    Color(0xFF42A5F5),
    Color(0xFFEF5350),
    Color(0xFF66BB6A),
    Color(0xFFFFCA28),
    Color(0xFFAB47BC),
    Color(0xFF26A69A),
    Color(0xFFFF7043),
    Color(0xFF5C6BC0),
    Color(0xFF26C6DA),
    Color(0xFFEC407A),
  ];

  Color _categoryColor(String id) =>
      _palette[id.hashCode.abs() % _palette.length];

  Color _leafColor(TreemapTile t) {
    final override = colorOf?.call(t.node);
    if (override != null) return override;
    if (t.node.color is Color) return t.node.color! as Color;
    // Brightness wobble per leaf so siblings under the same category are
    // distinguishable but visibly related.
    final base = _categoryColor(t.categoryId);
    final wobble = ((t.node.id.hashCode & 0xFF) / 255.0 - 0.5) * 0.18;
    return _shift(base, wobble);
  }

  Color _shift(Color base, double delta) {
    final r = (base.r * 255).round();
    final g = (base.g * 255).round();
    final b = (base.b * 255).round();
    final factor = 1 + delta;
    int clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    return Color.fromARGB(
      (base.a * 255).round(),
      clamp((r * factor).round()),
      clamp((g * factor).round()),
      clamp((b * factor).round()),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..isAntiAlias = false;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..color = style.borderColor
      ..strokeWidth = style.borderWidth;

    // 1. Faint background tint for each category (depth 1) so groupings
    //    read even between leaves.
    for (final t in tiles) {
      if (t.depth != 1 || t.node.isLeaf) continue;
      final base = _categoryColor(t.categoryId);
      fill.color = base.withValues(alpha: style.categoryBackgroundOpacity);
      canvas.drawRect(t.rect, fill);
    }

    // 2. Leaves.
    for (final t in tiles) {
      if (!t.node.isLeaf) continue;
      final r = _leafRect(t);
      if (r.width <= 0 || r.height <= 0) continue;
      fill.color = _leafColor(t);
      canvas.drawRect(r, fill);
      if (style.borderWidth > 0) canvas.drawRect(r, border);
    }

    // 3. Labels — leaves first (low priority), then category headers, then
    //    optional root header. Drawing categories *after* leaves ensures
    //    the header sits on top.
    for (final t in tiles) {
      if (!t.node.isLeaf) continue;
      _drawLeafLabel(canvas, t);
    }
    for (final t in tiles) {
      if (t.depth != 1 || t.node.isLeaf) continue;
      _drawCategoryLabel(canvas, t);
    }
    if (style.showRootLabel) {
      for (final t in tiles) {
        if (t.depth != 0) continue;
        _drawCategoryLabel(canvas, t);
      }
    }
  }

  Rect _leafRect(TreemapTile t) {
    final p = style.padding;
    final l = t.rect.left + p;
    final tp = t.rect.top + p;
    final ri = t.rect.right - p;
    final b = t.rect.bottom - p;
    return Rect.fromLTRB(l, tp, ri < l ? l : ri, b < tp ? tp : b);
  }

  void _drawLeafLabel(Canvas canvas, TreemapTile tile) {
    if (tile.rect.shortestSide < style.minTileSideForLabel) return;
    final text = tile.node.label.isEmpty ? tile.node.id : tile.node.label;
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: style.labelFontSize,
      maxLines: 1,
      ellipsis: '…',
    ))
      ..pushStyle(ui.TextStyle(
        color: style.labelColor,
        fontSize: style.labelFontSize,
        fontWeight: FontWeight.w600,
      ))
      ..addText(text);
    final paragraph = pb.build()
      ..layout(ui.ParagraphConstraints(width: (tile.rect.width - 8).clamp(0, double.infinity)));
    canvas.drawParagraph(
        paragraph, Offset(tile.rect.left + 4, tile.rect.top + 4));
  }

  void _drawCategoryLabel(Canvas canvas, TreemapTile tile) {
    if (tile.rect.shortestSide < style.minTileSideForLabel) return;
    final label = tile.node.label.isEmpty ? tile.node.id : tile.node.label;
    final headerHeight = style.headerHeight.clamp(8, tile.rect.height);
    final total = tile.node.totalValue;
    final text = total > 0 ? '$label  ·  ${total.toStringAsFixed(0)}' : label;
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: style.categoryLabelFontSize,
      maxLines: 1,
      ellipsis: '…',
    ))
      ..pushStyle(ui.TextStyle(
        color: style.categoryLabelColor,
        fontSize: style.categoryLabelFontSize,
        fontWeight: FontWeight.w700,
      ))
      ..addText(text);
    final paragraph = pb.build()
      ..layout(ui.ParagraphConstraints(width: (tile.rect.width - 12).clamp(0, double.infinity)));
    // Sit inside the header band at the top-left, with a tiny inset.
    canvas.drawParagraph(
      paragraph,
      Offset(tile.rect.left + 6, tile.rect.top + 2),
    );
    // Optional underline of the header band to anchor it visually.
    final underlinePaint = Paint()
      ..color = style.categoryLabelColor.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(tile.rect.left + 6, tile.rect.top + headerHeight - 1),
      Offset(tile.rect.right - 6, tile.rect.top + headerHeight - 1),
      underlinePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _TreemapPainter old) {
    return old.tiles != tiles || old.style != style;
  }
}
