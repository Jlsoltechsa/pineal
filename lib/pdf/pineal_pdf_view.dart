import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pdf_controller.dart';
import 'pdf_element.dart';
import 'pdf_geometry.dart';
import 'render_pineal_pdf.dart';

/// Build callback invoked once per visible page so the host can pin
/// annotations (Pineal painters, Flutter widgets, anything) to PDF-point
/// coordinates. The [PdfPageLayout] exposes screen-space and PDF-space
/// mapping helpers — pass `layout.pdfToScreen(...)` to a `Positioned` to
/// glue a widget to a PDF coordinate; it follows scroll + zoom for free.
typedef PdfOverlayBuilder = Widget Function(
    BuildContext context, PdfPageLayout layout);

/// Top-level PDF viewer.
///
/// Composition:
///   - Outer `Listener` captures raw pointer events (no `GestureDetector`,
///     no gesture arena overhead) and mutates the [PinealPdfController].
///   - A `LeafRenderObjectWidget` wraps the [RenderPinealPdf] paint pass.
///   - An optional overlay layer above renders [overlayBuilder] for every
///     visible page; updates each animation frame via an `AnimatedBuilder`
///     subscribed to the controller.
class PinealPdfView extends StatefulWidget {
  const PinealPdfView({
    super.key,
    required this.controller,
    this.overlayBuilder,
    this.onElementTap,
    this.onPageTap,
    this.scrollWheelLineHeight = 64,
    this.zoomScrollSensitivity = 0.0015,
  });

  final PinealPdfController controller;

  /// Per-page overlay. Called once per visible page on every paint cycle.
  /// Returning `const SizedBox.shrink()` is the no-op opt-out.
  final PdfOverlayBuilder? overlayBuilder;

  /// Element-level tap (text span, link annotation). Wires through
  /// `controller.hitTestPdf`; fires `null` element callbacks are
  /// suppressed (use [onPageTap] for blank-page taps).
  final void Function(PdfElement element)? onElementTap;

  /// Fires for any tap that doesn't land on a known element. The
  /// payload is the PDF-point coordinate so callers can drop a marker /
  /// open a context menu / start drawing an annotation there.
  final void Function(int pageIndex, Offset pdfPoint)? onPageTap;

  /// Pixels of scroll per scroll-wheel detent. Trackpads send a stream
  /// of small deltas; mouse wheels send big chunky ones. The default
  /// 64px feels right for both.
  final double scrollWheelLineHeight;

  /// Ctrl + scroll wheel zoom step per pixel of wheel delta. Negative
  /// because scrolling up should zoom in.
  final double zoomScrollSensitivity;

  @override
  State<PinealPdfView> createState() => _PinealPdfViewState();
}

class _PinealPdfViewState extends State<PinealPdfView> {
  final GlobalKey _renderKey = GlobalKey();
  final FocusNode _focusNode = FocusNode(debugLabel: 'PinealPdfView');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'PinealPdfSearch');
  final TextEditingController _searchCtrl = TextEditingController();
  bool _searchOpen = false;
  Offset? _panAnchor;
  Offset? _tapDown;

  /// Pixels of scroll per arrow keypress. Roughly one line at typical
  /// PDF zoom — small enough that holding the key feels analog, large
  /// enough that single taps make progress.
  static const double _arrowScrollStep = 60;

  @override
  void dispose() {
    _focusNode.dispose();
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    // Defer focus until the bar's TextField is in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    setState(() => _searchOpen = false);
    widget.controller.clearSearch();
    _searchCtrl.clear();
    _focusNode.requestFocus();
  }

  void _runSearch(String q) {
    // Fire-and-forget; controller dedupes via epoch counter.
    widget.controller.search(q);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final c = widget.controller;
    final k = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final ctl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final renderObj = _renderObject();
    final viewportH = renderObj?.size.height ?? 0;
    final viewportW = renderObj?.size.width ?? 0;

    // Scroll
    if (k == LogicalKeyboardKey.arrowUp) {
      c.scrollBy(dy: -_arrowScrollStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      c.scrollBy(dy: _arrowScrollStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      c.scrollBy(dx: -_arrowScrollStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      c.scrollBy(dx: _arrowScrollStep);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageDown ||
        (k == LogicalKeyboardKey.space && !shift)) {
      c.scrollBy(dy: viewportH);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageUp ||
        (k == LogicalKeyboardKey.space && shift)) {
      c.scrollBy(dy: -viewportH);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.home) {
      c.setScroll(x: 0, y: 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.end) {
      // Jump to bottom — controller clamps to (contentHeight - viewportH).
      c.setScroll(x: 0, y: double.infinity);
      return KeyEventResult.handled;
    }

    // Search
    if (ctl && k == LogicalKeyboardKey.keyF) {
      _openSearch();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _searchOpen) {
      _closeSearch();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.f3) {
      if (shift) {
        c.previousHit();
      } else {
        c.nextHit();
      }
      return KeyEventResult.handled;
    }

    // Zoom
    if (k == LogicalKeyboardKey.equal ||
        k == LogicalKeyboardKey.add ||
        k == LogicalKeyboardKey.numpadAdd) {
      c.animateZoomTo(c.zoom * 1.25);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      c.animateZoomTo(c.zoom / 1.25);
      return KeyEventResult.handled;
    }
    if (ctl && k == LogicalKeyboardKey.digit0) {
      // Fit to width: zoom that makes the widest page exactly viewportW.
      final content = c.contentSize();
      // contentSize is at current zoom, so unscale by current zoom for
      // the raw point width.
      final maxPagePts = c.zoom == 0 ? 0.0 : content.width / c.zoom;
      if (maxPagePts > 0 && viewportW > 0) {
        c.animateZoomTo(viewportW / maxPagePts);
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  RenderPinealPdf? _renderObject() {
    final ctx = _renderKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    return ro is RenderPinealPdf ? ro : null;
  }

  void _onPointerDown(PointerDownEvent event) {
    _panAnchor = event.localPosition;
    _tapDown = event.localPosition;
    // Make sure key events land here for the rest of the gesture.
    _focusNode.requestFocus();
  }

  void _onPointerMove(PointerMoveEvent event) {
    final anchor = _panAnchor;
    if (anchor == null) return;
    widget.controller.scrollBy(
      dx: -event.delta.dx,
      dy: -event.delta.dy,
    );
    // If the user moved more than the tap-slop, this isn't a tap anymore.
    if (_tapDown != null &&
        (event.localPosition - _tapDown!).distance > kTouchSlop) {
      _tapDown = null;
    }
    _panAnchor = event.localPosition;
  }

  Future<void> _onPointerUp(PointerUpEvent event) async {
    _panAnchor = null;
    final downPos = _tapDown;
    _tapDown = null;
    if (downPos == null) return;
    if ((event.localPosition - downPos).distance > kTouchSlop) return;
    await _dispatchTap(event.localPosition);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _panAnchor = null;
    _tapDown = null;
  }

  Future<void> _dispatchTap(Offset localPosition) async {
    final renderObj = _renderObject();
    if (renderObj == null) return;
    final hit = renderObj.pageAtLocal(localPosition);
    if (hit == null) return;
    final element = await widget.controller.hitTestPdf(
      pageIndex: hit.layout.geometry.pageIndex,
      pdfPoint: hit.pdfPoint,
    );
    if (!mounted) return;
    if (element != null) {
      widget.onElementTap?.call(element);
    } else {
      widget.onPageTap?.call(
          hit.layout.geometry.pageIndex, hit.pdfPoint);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Ctrl/⌘ + scroll → zoom around the cursor. Plain scroll → pan.
    final wantZoom = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (wantZoom) {
      final delta = event.scrollDelta.dy * -widget.zoomScrollSensitivity;
      final factor = (1.0 + delta).clamp(0.5, 2.0);
      widget.controller.setZoom(
        widget.controller.zoom * factor,
        anchor: (
          sx: event.localPosition.dx,
          sy: event.localPosition.dy,
        ),
      );
    } else {
      widget.controller.scrollBy(
        dx: event.scrollDelta.dx,
        dy: event.scrollDelta.dy,
      );
    }
  }

  /// Trackpad pinch-zoom. Web doesn't deliver these so we keep Ctrl+scroll
  /// as the universal fallback.
  void _onPointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (kIsWeb) return;
    if (event.scale == 1.0) {
      // Pure pan (two-finger drag on trackpad).
      widget.controller.scrollBy(
        dx: -event.panDelta.dx,
        dy: -event.panDelta.dy,
      );
      return;
    }
    // Anchor zoom around the gesture center.
    final c = widget.controller;
    c.setZoom(c.zoom * event.scale, anchor: (
      sx: event.localPosition.dx,
      sy: event.localPosition.dy,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        onPointerSignal: _onPointerSignal,
        onPointerPanZoomUpdate: _onPointerPanZoomUpdate,
        child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final overlay = widget.overlayBuilder;
          return Stack(
            children: [
              Positioned.fill(
                child: _PdfRenderObjectWidget(
                  key: _renderKey,
                  controller: widget.controller,
                ),
              ),
              if (overlay != null) ..._buildOverlay(context, overlay),
              if (_searchOpen)
                Positioned(
                  top: 8,
                  right: 8,
                  child: _SearchBar(
                    controller: widget.controller,
                    textController: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: _runSearch,
                    onClose: _closeSearch,
                  ),
                ),
            ],
          );
        },
      ),
      ),
    );
  }

  List<Widget> _buildOverlay(
      BuildContext context, PdfOverlayBuilder builder) {
    final renderObj = _renderObject();
    if (renderObj == null) return const [];
    final layouts = renderObj.visiblePageLayouts();
    return [
      for (final layout in layouts)
        Positioned.fromRect(
          rect: layout.screenRect,
          child: IgnorePointer(child: builder(context, layout)),
        ),
    ];
  }
}

/// Compact floating search bar. Appears in the top-right when the user
/// hits `Ctrl+F` and stays until they press `Escape` or click `Close`.
/// Mirrors browser-style "find in page" UX: typing rebuilds the hit set,
/// Enter / Shift+Enter cycle through them.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.textController,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
  });

  final PinealPdfController controller;
  final TextEditingController textController;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1B2128),
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search, size: 16, color: Color(0xFF9AA4AD)),
            const SizedBox(width: 6),
            SizedBox(
              width: 200,
              child: TextField(
                controller: textController,
                focusNode: focusNode,
                style: const TextStyle(
                    color: Color(0xFFE6ECF2), fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Find in page…',
                  hintStyle: TextStyle(
                      color: Color(0xFF6B7480), fontSize: 13),
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: onChanged,
                onSubmitted: (_) => controller.nextHit(),
              ),
            ),
            const SizedBox(width: 6),
            _HitCounter(controller: controller),
            IconButton(
              tooltip: 'Previous (Shift+Enter)',
              icon: const Icon(Icons.keyboard_arrow_up, size: 18),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: controller.searchHits.isEmpty
                  ? null
                  : controller.previousHit,
            ),
            IconButton(
              tooltip: 'Next (Enter / F3)',
              icon: const Icon(Icons.keyboard_arrow_down, size: 18),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed:
                  controller.searchHits.isEmpty ? null : controller.nextHit,
            ),
            IconButton(
              tooltip: 'Close (Esc)',
              icon: const Icon(Icons.close, size: 18),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _HitCounter extends StatelessWidget {
  const _HitCounter({required this.controller});
  final PinealPdfController controller;

  @override
  Widget build(BuildContext context) {
    final n = controller.searchHits.length;
    if (n == 0 && controller.searchQuery == null) {
      return const SizedBox(width: 0);
    }
    final cur = controller.currentHitIndex;
    final label = n == 0
        ? '0/0'
        : '${(cur ?? 0) + 1}/$n';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        style: const TextStyle(color: Color(0xFF9AA4AD), fontSize: 11),
      ),
    );
  }
}

/// Internal `LeafRenderObjectWidget` that bridges the controller to the
/// custom `RenderBox`. Pulled out so the outer state widget can keep a
/// `GlobalKey` on it and reach the RenderBox for hit-tests.
class _PdfRenderObjectWidget extends LeafRenderObjectWidget {
  const _PdfRenderObjectWidget({
    super.key,
    required this.controller,
  });

  final PinealPdfController controller;

  @override
  RenderPinealPdf createRenderObject(BuildContext context) {
    return RenderPinealPdf(controller: controller);
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderPinealPdf renderObject) {
    renderObject.controller = controller;
  }
}
