import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Key for the [TileCache]. v0.1 caches one tile per (page × mip level)
/// because the reference backend doesn't sub-rect rasterize, but the
/// `row`/`col` fields are already part of the identity so future tile
/// splits don't need to change consumers.
@immutable
class TileKey {
  const TileKey({
    required this.pageIndex,
    required this.mipLevel,
    this.row = 0,
    this.col = 0,
  });

  final int pageIndex;
  final int mipLevel;
  final int row;
  final int col;

  @override
  bool operator ==(Object other) =>
      other is TileKey &&
      other.pageIndex == pageIndex &&
      other.mipLevel == mipLevel &&
      other.row == row &&
      other.col == col;

  @override
  int get hashCode => Object.hash(pageIndex, mipLevel, row, col);

  @override
  String toString() => 'TileKey(p=$pageIndex mip=$mipLevel r=$row c=$col)';
}

/// LRU of rasterized tiles. Entries are `ui.Image`, which already live on
/// the GPU once decoded; the eviction call disposes the underlying
/// texture so this is the only place memory accounting needs to happen.
///
/// Capacity is in tiles, not bytes — sizing the cache by image area would
/// be more accurate but every tile in v0.1 represents a whole page, so
/// `maxTiles = 12` already caps memory at a sensible ceiling for the
/// 16M-pixel-per-page budget the backend enforces.
class TileCache {
  TileCache({this.maxTiles = 12});

  final int maxTiles;

  /// `LinkedHashMap` keeps insertion order; we exploit that for the LRU
  /// by removing + reinserting on access.
  final LinkedHashMap<TileKey, ui.Image> _tiles =
      LinkedHashMap<TileKey, ui.Image>();

  int get length => _tiles.length;

  /// Returns the cached image and promotes it to MRU, or `null` on miss.
  ui.Image? lookup(TileKey key) {
    final hit = _tiles.remove(key);
    if (hit == null) return null;
    _tiles[key] = hit;
    return hit;
  }

  /// Inserts [image] at the MRU slot. If [key] was already cached, the
  /// previous entry is disposed first.
  void put(TileKey key, ui.Image image) {
    final old = _tiles.remove(key);
    if (old != null) old.dispose();
    _tiles[key] = image;
    while (_tiles.length > maxTiles) {
      final lru = _tiles.keys.first;
      final evicted = _tiles.remove(lru);
      evicted?.dispose();
    }
  }

  /// Drop every tile whose key matches [predicate]. Disposes the
  /// underlying images. Use on `pageCount` change, document close, or
  /// when a zoom level transitions to a different mip.
  int evictWhere(bool Function(TileKey key) predicate) {
    var removed = 0;
    final toRemove = <TileKey>[];
    for (final key in _tiles.keys) {
      if (predicate(key)) toRemove.add(key);
    }
    for (final key in toRemove) {
      final image = _tiles.remove(key);
      image?.dispose();
      removed++;
    }
    return removed;
  }

  /// Drop and dispose every tile.
  void clear() {
    for (final image in _tiles.values) {
      image.dispose();
    }
    _tiles.clear();
  }
}
