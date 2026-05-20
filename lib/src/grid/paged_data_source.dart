import 'dart:async';
import 'dart:collection';

import 'data_source.dart';
import 'grid_controller.dart';

/// Result of a single page fetch — the building block of [PagedGridDataSource].
class PageResult {
  const PageResult({
    required this.rows,
    this.totalRowCount,
    this.hasMore = false,
    this.cursor,
  });

  final List<Map<String, Object?>> rows;

  /// Authoritative total when the backend can produce one (`SELECT COUNT(*)`,
  /// API meta field, etc.). Leave `null` for streaming sources that don't
  /// know the total in advance — the data source will report a growing
  /// high-water-mark instead.
  final int? totalRowCount;

  /// `true` when there's at least one more page beyond this one. Used to
  /// advertise a row past the last loaded page so the painter can scroll
  /// into the unloaded region and trigger the next fetch.
  final bool hasMore;

  /// Opaque cursor for the *next* page. Sources that use cursor pagination
  /// can ignore [PagedGridDataSource.fetchPage]'s `offset` arg and instead
  /// read this value via [PagedGridDataSource.cursorBefore] (which the
  /// abstract impl threads through automatically).
  final Object? cursor;
}

/// Server-friendly base class. Implementations only have to write
/// [fetchPage]; the rest — LRU caching, paint-time prefetch fan-out, sort
/// and filter re-invalidation, total-count bookkeeping — is provided.
///
/// **Threading model**: every read goes through [valueAt], which is
/// synchronous. Misses trigger an async fetch and return `null`; the
/// painter draws a shimmer placeholder. When the fetch completes the
/// source notifies and the painter repaints the now-resolved cells.
///
/// **Cache policy**: a fixed-capacity LRU keyed by page index. Eviction
/// runs after every successful fetch and drops the least-recently-touched
/// page. Increase [maxPagesInMemory] for wide scrolling sessions where the
/// user keeps revisiting old rows.
abstract class PagedGridDataSource extends GridDataSource {
  PagedGridDataSource({
    this.pageSize = 100,
    this.maxPagesInMemory = 50,
    this.maxRetries = 3,
    this.retryBackoff = const Duration(milliseconds: 200),
  });

  /// How many rows the source asks for per fetch. Smaller = more requests
  /// but smaller blast radius on a miss; larger = fewer round trips but
  /// chunkier shimmer when the user lands on a fresh page.
  final int pageSize;

  /// LRU cache cap. Once exceeded, the least-recently-accessed page is
  /// dropped on the next successful fetch.
  final int maxPagesInMemory;

  /// How many times a failing `fetchPage` is retried before [onFetchError]
  /// fires. `0` disables retries; the default of 3 covers transient
  /// network blips without piling on a flaky backend.
  final int maxRetries;

  /// Base delay between retries. Doubled on each attempt (200ms → 400ms →
  /// 800ms with the default), so total worst-case wait is bounded but the
  /// backend gets breathing room.
  final Duration retryBackoff;

  /// LRU keyed by page index. `LinkedHashMap` keeps insertion order, which
  /// we exploit by `remove` + re-insert on access to move entries to the
  /// most-recent slot.
  final LinkedHashMap<int, _Page> _pages = LinkedHashMap<int, _Page>();
  final Set<int> _pending = <int>{};

  int _highWaterMark = 0;
  bool _hasMore = true;
  Object? _lastCursor;
  List<SortSpec> _currentSort = const [];
  Map<String, GridFilter> _currentFilters = const {};

  /// Last cursor the most-recent successful fetch returned. Cursor-based
  /// subclasses read this in [fetchPage] to keep scrolling forward; the
  /// offset arg is still passed so they can correlate.
  Object? get cursorBefore => _lastCursor;

  @override
  int get rowCount => _highWaterMark;

  /// Whether the source thinks more pages exist past the high-water mark.
  /// Reset to `true` whenever sort or filters change.
  bool get hasMore => _hasMore;

  @override
  Object? valueAt(int row, String columnId) {
    if (row < 0 || row >= _highWaterMark) return null;
    final pageIdx = row ~/ pageSize;
    final page = _pages[pageIdx];
    if (page == null) {
      _requestPage(pageIdx);
      return null;
    }
    // Move to MRU end so eviction targets the right pages.
    _pages
      ..remove(pageIdx)
      ..[pageIdx] = page;
    final rowInPage = row - pageIdx * pageSize;
    if (rowInPage >= page.rows.length) return null;
    return page.rows[rowInPage][columnId];
  }

  @override
  void prefetch(int firstRow, int lastRow) {
    if (firstRow < 0 || lastRow < firstRow) return;
    final firstPage = firstRow ~/ pageSize;
    final lastPage = lastRow ~/ pageSize;
    for (var p = firstPage; p <= lastPage; p++) {
      if (!_pages.containsKey(p)) _requestPage(p);
    }
  }

  @override
  void sort(List<SortSpec> chain) {
    if (_chainsEqual(_currentSort, chain)) return;
    _currentSort = List.unmodifiable(chain);
    _invalidate();
  }

  @override
  void applyFilters(Map<String, GridFilter> filters) {
    if (_filtersEqual(_currentFilters, filters)) return;
    _currentFilters = Map.unmodifiable(filters);
    _invalidate();
  }

  /// Drops every cached page and resets the high-water mark. Subclasses
  /// should call this when an event outside sort/filter (server-push,
  /// manual reload) invalidates the cache.
  void invalidateAll() => _invalidate();

  void _invalidate() {
    _pages.clear();
    _pending.clear();
    _highWaterMark = 0;
    _hasMore = true;
    _lastCursor = null;
    notifyListeners();
  }

  void _requestPage(int pageIdx, [int attempt = 0]) {
    if (_pending.contains(pageIdx)) return;
    if (!_hasMore && pageIdx * pageSize >= _highWaterMark) return;
    _pending.add(pageIdx);
    final offset = pageIdx * pageSize;
    fetchPage(
      offset: offset,
      limit: pageSize,
      sort: _currentSort,
      filters: _currentFilters,
      cursor: _lastCursor,
    ).then((result) {
      if (!_pending.remove(pageIdx)) return;
      _pages[pageIdx] = _Page(rows: result.rows);
      _evictIfNeeded();
      _lastCursor = result.cursor;
      _hasMore = result.hasMore;
      // Advertise either the authoritative total or a high-water mark that
      // includes one page of look-ahead so scrolling can trigger the next
      // fetch.
      if (result.totalRowCount != null) {
        _highWaterMark = result.totalRowCount!;
      } else {
        final loaded = offset + result.rows.length;
        _highWaterMark =
            result.hasMore ? loaded + pageSize : loaded;
      }
      notifyListeners();
    }).catchError((Object error, StackTrace stack) {
      _pending.remove(pageIdx);
      if (attempt < maxRetries) {
        // Exponential backoff: 200ms, 400ms, 800ms, … doubling each retry.
        final delay = retryBackoff * (1 << attempt);
        Future.delayed(delay, () => _requestPage(pageIdx, attempt + 1));
      } else {
        // Hand the final failure to the subclass — default is to swallow
        // so the cell stays in shimmer state until something else
        // (sort/filter change, manual invalidate) re-triggers the fetch.
        onFetchError(pageIdx, error, stack);
      }
    });
  }

  void _evictIfNeeded() {
    while (_pages.length > maxPagesInMemory) {
      final lru = _pages.keys.first;
      _pages.remove(lru);
    }
  }

  /// Override to fetch one page. The returned future may complete with
  /// rows shorter than [limit] for the final page; `hasMore: false` tells
  /// the source to stop advancing the high-water mark.
  Future<PageResult> fetchPage({
    required int offset,
    required int limit,
    required List<SortSpec> sort,
    required Map<String, GridFilter> filters,
    Object? cursor,
  });

  /// Hook for subclasses that want to log or retry on failure. The default
  /// swallows — the cell stays in shimmer state.
  void onFetchError(int pageIdx, Object error, StackTrace stack) {}

  // ─── Optimistic writes ────────────────────────────────────────────────────

  /// Default write path: optimistically updates the local page cache and
  /// fires [writeCell] in the background. If the future completes with an
  /// error, the cell rolls back to its previous value and [onWriteError]
  /// fires. Subclasses can override [writeCell] alone to wire a real
  /// backend without touching this method.
  ///
  /// Writes to rows whose page isn't cached are dropped silently — there's
  /// nothing to optimistically update against, and the row isn't visible
  /// to the user anyway. Subclasses that need fire-and-forget writes for
  /// non-cached rows should override this method directly.
  @override
  void setValueAt(int row, String columnId, Object? value) {
    final pageIdx = row ~/ pageSize;
    final page = _pages[pageIdx];
    if (page == null) return;
    final rowInPage = row - pageIdx * pageSize;
    if (rowInPage < 0 || rowInPage >= page.rows.length) return;
    final previous = page.rows[rowInPage][columnId];
    page.rows[rowInPage][columnId] = value;
    notifyListeners();
    writeCell(row, columnId, value).catchError((Object err, StackTrace stack) {
      final pageNow = _pages[pageIdx];
      if (pageNow != null && rowInPage < pageNow.rows.length) {
        // Roll back only if the page is still cached at the same slot.
        // Otherwise the user has scrolled away and re-fetched, and the
        // authoritative value already lives in the new page.
        pageNow.rows[rowInPage][columnId] = previous;
        notifyListeners();
      }
      onWriteError(row, columnId, value, err, stack);
    });
  }

  /// Same optimistic pattern, but for the bulk paste/delete path. Each
  /// write's previous value is captured before the in-memory mutation, so
  /// a partial-failure response from [writeBatchCells] can roll back the
  /// exact set of cells the server rejected. Default falls back to
  /// per-cell [writeCell] when a subclass doesn't override
  /// [writeBatchCells].
  @override
  void writeBatch(List<CellWrite> writes) {
    final touched = <_TouchedCell>[];
    for (final w in writes) {
      final pageIdx = w.row ~/ pageSize;
      final page = _pages[pageIdx];
      if (page == null) continue;
      final rowInPage = w.row - pageIdx * pageSize;
      if (rowInPage < 0 || rowInPage >= page.rows.length) continue;
      touched.add(_TouchedCell(
        write: w,
        pageIdx: pageIdx,
        rowInPage: rowInPage,
        previous: page.rows[rowInPage][w.columnId],
      ));
      page.rows[rowInPage][w.columnId] = w.value;
    }
    if (touched.isEmpty) return;
    notifyListeners();
    writeBatchCells(touched.map((t) => t.write).toList())
        .catchError((Object err, StackTrace stack) {
      for (final t in touched) {
        final page = _pages[t.pageIdx];
        if (page == null) continue;
        if (t.rowInPage >= page.rows.length) continue;
        page.rows[t.rowInPage][t.write.columnId] = t.previous;
      }
      notifyListeners();
      onBatchWriteError(touched.map((t) => t.write).toList(), err, stack);
    });
  }

  /// Server-side write of a single cell. Override to hit your backend.
  /// The default no-ops with a resolved future, so subclasses that only
  /// need optimistic-locally-mutate-and-keep-going semantics get them
  /// for free.
  Future<void> writeCell(int row, String columnId, Object? value) async {}

  /// Server-side write of a batch. Default fans out to [writeCell] per
  /// cell concurrently — fine for small batches; override for backends
  /// that have a native bulk endpoint (`PATCH /rows?ids=…`).
  Future<void> writeBatchCells(List<CellWrite> writes) async {
    await Future.wait(
        writes.map((w) => writeCell(w.row, w.columnId, w.value)));
  }

  /// Single-cell write failure hook. Default swallows — the local cache
  /// has already been rolled back by the time this fires.
  void onWriteError(int row, String columnId, Object? attemptedValue,
      Object error, StackTrace stack) {}

  /// Batch failure hook. Same semantics as [onWriteError] but with the
  /// full set of attempted writes (already rolled back).
  void onBatchWriteError(
      List<CellWrite> writes, Object error, StackTrace stack) {}

  static bool _chainsEqual(List<SortSpec> a, List<SortSpec> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].columnId != b[i].columnId ||
          a[i].direction != b[i].direction) {
        return false;
      }
    }
    return true;
  }

  static bool _filtersEqual(
      Map<String, GridFilter> a, Map<String, GridFilter> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      // Filter equality isn't structural — different instances of the same
      // filter compare unequal. That's fine: the controller only re-applies
      // filters on a user gesture, not on every paint, so we're not spamming
      // this path.
      if (!identical(a[k], b[k])) return false;
    }
    return true;
  }
}

class _Page {
  _Page({required this.rows});
  final List<Map<String, Object?>> rows;
}

class _TouchedCell {
  _TouchedCell({
    required this.write,
    required this.pageIdx,
    required this.rowInPage,
    required this.previous,
  });
  final CellWrite write;
  final int pageIdx;
  final int rowInPage;
  final Object? previous;
}
