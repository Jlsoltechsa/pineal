import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'grid_controller.dart';
import 'grid_painter.dart';

/// Overlay that floats a single [TextField] over the cell being edited.
///
/// This is the foundational *edit-first* piece of the grid: every cell uses
/// the same widget, positioned by [GridPainter.cellRect]. Commit happens on
/// Enter/Tab/blur; cancel on Escape. Future iterations will add per-column
/// editor types (numeric, date, dropdown) by branching the inner widget on
/// the column's value type — the positioning machinery stays the same.
class FloatingEditor extends StatefulWidget {
  const FloatingEditor({
    super.key,
    required this.controller,
    required this.painter,
    required this.size,
    this.style,
    this.onCommit,
  });

  final GridController controller;
  final GridPainter painter;
  final Size size;
  final TextStyle? style;

  /// Called after a commit succeeds. `(dx, dy)` carries the desired post-edit
  /// navigation: `(0, 1)` for Enter (advance down), `(1, 0)` for Tab,
  /// `(0, 0)` for tap-outside commits where the caller stays put.
  final void Function(int dx, int dy)? onCommit;

  @override
  State<FloatingEditor> createState() => _FloatingEditorState();
}

class _FloatingEditorState extends State<FloatingEditor> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  GridCell? _bound;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _sync();
  }

  @override
  void didUpdateWidget(covariant FloatingEditor old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
    }
    _sync();
  }

  void _onControllerChange() => _sync();

  void _sync() {
    final editing = widget.controller.editingCell;
    if (editing == _bound) return;
    _bound = editing;
    if (editing != null) {
      final seed = widget.controller.editorSeed;
      if (seed != null) {
        // Type-to-replace: skip the selection so the caret lands at the end
        // and the next keypress appends rather than overwrites.
        _text.text = seed;
        _text.selection = TextSelection.collapsed(offset: seed.length);
      } else {
        final v = widget.controller.source.valueAt(editing.row, editing.columnId);
        _text.text = v?.toString() ?? '';
        _text.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _text.text.length,
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
    if (mounted) setState(() {});
  }

  void _commit({int dx = 0, int dy = 0}) {
    final raw = _text.text;
    final originalValue = _bound == null
        ? null
        : widget.controller.source.valueAt(_bound!.row, _bound!.columnId);
    final coerced = coerceValue(raw, originalValue);
    widget.controller.commitEdit(coerced);
    widget.onCommit?.call(dx, dy);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.controller.cancelEdit();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _commit(dy: 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final back = HardwareKeyboard.instance.isShiftPressed;
      _commit(dx: back ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cell = _bound;
    if (cell == null) return const SizedBox.shrink();
    final rect = widget.painter.cellRect(cell, widget.size);
    if (rect == null) return const SizedBox.shrink();

    return Positioned.fromRect(
      rect: rect,
      child: Material(
        color: const Color(0xFF1B2128),
        elevation: 4,
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _handleKey,
          child: TextField(
            controller: _text,
            autofocus: true,
            style: widget.style ??
                const TextStyle(color: Color(0xFFE6ECF2), fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              enabledBorder: InputBorder.none,
            ),
            onSubmitted: (_) => _commit(),
            onTapOutside: (_) => _commit(),
          ),
        ),
      ),
    );
  }
}
