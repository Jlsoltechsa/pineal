import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'backend/pdf_backend.dart';

/// Bounded-concurrency scheduler for backend rasterize calls.
///
/// The viewer fires off rasterize requests greedily as tiles enter the
/// viewport. Most backends serialize FFI calls on the platform thread
/// anyway, so dispatching 50 parallel requests just builds a queue
/// somewhere we can't see. This class makes the queue explicit so we can
/// cancel obsolete requests when the user scrolls past them faster than
/// the backend can render.
///
/// Cancellation isn't preemptive — once a rasterize starts, it finishes.
/// What [cancel] does is drop the request from the *queue* and discard
/// the result if it arrives anyway. That's enough to keep memory and
/// frame budget bounded under fast pans.
class RasterizeQueue {
  RasterizeQueue({
    required this.document,
    this.maxConcurrent = 2,
  });

  final PinealPdfDocument document;
  final int maxConcurrent;

  int _running = 0;
  final Queue<_Request> _queue = Queue<_Request>();
  final Map<Object, _Request> _byTag = <Object, _Request>{};

  /// Enqueue a rasterize for the given page region. [tag] is an arbitrary
  /// identity (the tile cache uses `_TileKey` directly) — re-enqueuing
  /// with the same tag drops the older request silently. The returned
  /// future completes with the image, or with `null` if the request was
  /// cancelled before the backend produced a result.
  Future<ui.Image?> enqueue({
    required Object tag,
    required int pageIndex,
    required ui.Rect srcRect,
    required double scale,
  }) {
    final existing = _byTag[tag];
    if (existing != null) {
      // Same tile already in flight — return the same future so callers
      // don't fan out duplicate work.
      return existing.completer.future;
    }
    final req = _Request(
      tag: tag,
      pageIndex: pageIndex,
      srcRect: srcRect,
      scale: scale,
    );
    _byTag[tag] = req;
    _queue.add(req);
    _drain();
    return req.completer.future;
  }

  /// Drop every queued request whose tag matches [predicate]. In-flight
  /// requests are marked cancelled — their result is discarded when it
  /// arrives. Returns the number of requests actually removed from the
  /// queue (not including in-flight ones).
  int cancel(bool Function(Object tag) predicate) {
    var removed = 0;
    _queue.removeWhere((req) {
      if (predicate(req.tag)) {
        req.cancelled = true;
        if (!req.completer.isCompleted) {
          req.completer.complete(null);
        }
        _byTag.remove(req.tag);
        removed++;
        return true;
      }
      return false;
    });
    // In-flight requests stay in _byTag; we mark them cancelled so their
    // result is dropped on the floor when they resolve.
    for (final req in _byTag.values) {
      if (predicate(req.tag)) {
        req.cancelled = true;
      }
    }
    return removed;
  }

  void _drain() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final req = _queue.removeFirst();
      _running++;
      _runOne(req);
    }
  }

  Future<void> _runOne(_Request req) async {
    try {
      final image = await document.rasterize(
        pageIndex: req.pageIndex,
        srcRect: req.srcRect,
        scale: req.scale,
      );
      if (req.cancelled) {
        image.dispose();
        if (!req.completer.isCompleted) req.completer.complete(null);
      } else {
        if (!req.completer.isCompleted) req.completer.complete(image);
      }
    } catch (err, stack) {
      if (!req.completer.isCompleted) req.completer.completeError(err, stack);
    } finally {
      _byTag.remove(req.tag);
      _running--;
      _drain();
    }
  }

  /// Drops every pending request without completing their futures with an
  /// error — they resolve to `null`. Used by the viewer on dispose.
  void shutdown() {
    for (final req in _queue) {
      req.cancelled = true;
      if (!req.completer.isCompleted) req.completer.complete(null);
    }
    _queue.clear();
    for (final req in _byTag.values) {
      req.cancelled = true;
    }
    _byTag.clear();
  }
}

class _Request {
  _Request({
    required this.tag,
    required this.pageIndex,
    required this.srcRect,
    required this.scale,
  });

  final Object tag;
  final int pageIndex;
  final ui.Rect srcRect;
  final double scale;
  final Completer<ui.Image?> completer = Completer<ui.Image?>();
  bool cancelled = false;
}
