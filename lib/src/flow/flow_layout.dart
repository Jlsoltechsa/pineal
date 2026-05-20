import 'dart:ui';

import 'flow_data.dart';

/// Pixel-space placement for a node after layout. The painter only needs
/// these — no need to round-trip data structures.
class FlowNodeRect {
  FlowNodeRect({
    required this.node,
    required this.rect,
    required this.column,
  });
  final FlowNode node;
  final Rect rect;
  final int column;
}

/// Pixel-space ribbon endpoints for a link. Each endpoint is a vertical
/// segment `[topY, bottomY]` on the node's right (source) or left (target)
/// edge; the painter draws a cubic ribbon between them.
class FlowLinkLayout {
  FlowLinkLayout({
    required this.link,
    required this.sourceX,
    required this.sourceTop,
    required this.sourceBottom,
    required this.targetX,
    required this.targetTop,
    required this.targetBottom,
  });
  final FlowLink link;
  final double sourceX, sourceTop, sourceBottom;
  final double targetX, targetTop, targetBottom;
}

/// Full layout result.
class FlowLayoutResult {
  FlowLayoutResult(this.nodeRects, this.linkLayouts);
  final Map<String, FlowNodeRect> nodeRects;
  final List<FlowLinkLayout> linkLayouts;
}

/// Sankey-style auto-layout.
///
/// Phases:
/// 1. Topological layering — column index = longest path from any source.
/// 2. Per node, compute total flow as `max(sum_in, sum_out)` so visual
///    height reflects throughput.
/// 3. Stack nodes vertically within each column, proportional to flow.
/// 4. Assign source/target stripe positions on each node's right/left
///    edge so links never cross the node body.
class FlowLayout {
  const FlowLayout({
    this.nodeWidth = 14,
    this.nodePaddingPx = 12,
    this.linkPadding = 1.0,
    this.maxOrderingIterations = 16,
  });

  final double nodeWidth;
  final double nodePaddingPx;
  final double linkPadding;

  /// Hard cap on the barycenter-based crossing-minimisation loop. The loop
  /// stops early as soon as crossings stop decreasing, so this only matters
  /// for pathological graphs.
  final int maxOrderingIterations;

  FlowLayoutResult compute(
    List<FlowNode> nodes,
    List<FlowLink> links,
    Rect bounds,
  ) {
    if (nodes.isEmpty || bounds.width <= 0 || bounds.height <= 0) {
      return FlowLayoutResult(<String, FlowNodeRect>{}, <FlowLinkLayout>[]);
    }

    final indexOf = <String, int>{};
    for (var i = 0; i < nodes.length; i++) {
      indexOf[nodes[i].id] = i;
    }

    final outAdj = List<List<int>>.generate(nodes.length, (_) => <int>[]);
    final inDeg = List<int>.filled(nodes.length, 0);
    final outValue = List<double>.filled(nodes.length, 0);
    final inValue = List<double>.filled(nodes.length, 0);
    for (final l in links) {
      final s = indexOf[l.source];
      final t = indexOf[l.target];
      if (s == null || t == null || s == t) continue;
      outAdj[s].add(t);
      inDeg[t]++;
      outValue[s] += l.value;
      inValue[t] += l.value;
    }

    // Longest-path layer assignment.
    final layer = List<int>.filled(nodes.length, 0);
    final remaining = List<int>.from(inDeg);
    final ready = <int>[];
    for (var i = 0; i < nodes.length; i++) {
      if (inDeg[i] == 0) ready.add(i);
    }
    var head = 0;
    while (head < ready.length) {
      final u = ready[head++];
      for (final v in outAdj[u]) {
        if (layer[v] < layer[u] + 1) layer[v] = layer[u] + 1;
        if (--remaining[v] == 0) ready.add(v);
      }
    }
    var maxLayer = 0;
    for (final l in layer) {
      if (l > maxLayer) maxLayer = l;
    }
    final columns = List<List<int>>.generate(maxLayer + 1, (_) => <int>[]);
    for (var i = 0; i < nodes.length; i++) {
      columns[layer[i]].add(i);
    }

    // Build directed in-adjacency for barycenter ordering.
    final inAdj = List<List<int>>.generate(nodes.length, (_) => <int>[]);
    for (final l in links) {
      final s = indexOf[l.source];
      final t = indexOf[l.target];
      if (s == null || t == null || s == t) continue;
      inAdj[t].add(s);
    }

    _orderColumnsByBarycenter(columns, outAdj, inAdj);

    // Node flow = max(in, out), used as vertical height contribution.
    final flow = List<double>.generate(
        nodes.length, (i) => inValue[i] > outValue[i] ? inValue[i] : outValue[i],
        growable: false);

    // Compute column widths so the rightmost column lands flush with bounds.
    final colCount = columns.length;
    final colSpacing = colCount > 1
        ? (bounds.width - nodeWidth) / (colCount - 1)
        : 0.0;

    final rects = <String, FlowNodeRect>{};

    for (var c = 0; c < colCount; c++) {
      final col = columns[c];
      if (col.isEmpty) continue;
      var sumFlow = 0.0;
      for (final i in col) {
        sumFlow += flow[i];
      }
      if (sumFlow <= 0) sumFlow = 1;

      final totalPaddingPx = (col.length - 1) * nodePaddingPx;
      final available = (bounds.height - totalPaddingPx).clamp(1.0, double.infinity);
      var y = bounds.top;
      final x = bounds.left + c * colSpacing;
      for (final i in col) {
        final h = (flow[i] / sumFlow) * available;
        rects[nodes[i].id] = FlowNodeRect(
          node: nodes[i],
          rect: Rect.fromLTWH(x, y, nodeWidth, h.clamp(1.0, double.infinity)),
          column: c,
        );
        y += h + nodePaddingPx;
      }
    }

    // Per-node cursors for stacking link stripes on each edge.
    final outCursor = <String, double>{};
    final inCursor = <String, double>{};
    for (final r in rects.values) {
      outCursor[r.node.id] = r.rect.top;
      inCursor[r.node.id] = r.rect.top;
    }

    // Per-node flow factor so the rightmost edge stripe heights sum to the
    // node rect height (regardless of in vs out flow).
    final outFactor = <String, double>{};
    final inFactor = <String, double>{};
    for (final entry in rects.entries) {
      final id = entry.key;
      final h = entry.value.rect.height;
      final ov = outValue[indexOf[id]!];
      final iv = inValue[indexOf[id]!];
      outFactor[id] = ov > 0 ? h / ov : 0;
      inFactor[id] = iv > 0 ? h / iv : 0;
    }

    // Sort links per source by target's vertical position to minimise
    // crossings. For a clean v1 we sort outgoing links of each node by
    // target.top, and incoming by source.top.
    final outgoing = <String, List<FlowLink>>{};
    final incoming = <String, List<FlowLink>>{};
    for (final l in links) {
      (outgoing[l.source] ??= <FlowLink>[]).add(l);
      (incoming[l.target] ??= <FlowLink>[]).add(l);
    }
    outgoing.forEach((_, list) {
      list.sort((a, b) {
        final ay = rects[a.target]?.rect.top ?? 0;
        final by = rects[b.target]?.rect.top ?? 0;
        return ay.compareTo(by);
      });
    });
    incoming.forEach((_, list) {
      list.sort((a, b) {
        final ay = rects[a.source]?.rect.top ?? 0;
        final by = rects[b.source]?.rect.top ?? 0;
        return ay.compareTo(by);
      });
    });

    final linkLayouts = <FlowLinkLayout>[];
    for (final src in outgoing.keys) {
      for (final l in outgoing[src]!) {
        final sourceRect = rects[src]?.rect;
        final targetRect = rects[l.target]?.rect;
        if (sourceRect == null || targetRect == null) continue;
        final hSrc = l.value * (outFactor[src] ?? 0);
        final hTgt = l.value * (inFactor[l.target] ?? 0);
        final sTop = outCursor[src]!;
        final tTop = inCursor[l.target]!;
        outCursor[src] = sTop + hSrc;
        inCursor[l.target] = tTop + hTgt;
        linkLayouts.add(FlowLinkLayout(
          link: l,
          sourceX: sourceRect.right,
          sourceTop: sTop,
          sourceBottom: sTop + hSrc,
          targetX: targetRect.left,
          targetTop: tTop,
          targetBottom: tTop + hTgt,
        ));
      }
    }

    return FlowLayoutResult(rects, linkLayouts);
  }

  /// Reorders nodes within each column to minimise link crossings.
  ///
  /// Same shape as the Sugiyama-style loop in [HierarchicalLayout]: alternate
  /// down/up barycenter passes and break when total crossings stop
  /// decreasing.
  void _orderColumnsByBarycenter(
    List<List<int>> columns,
    List<List<int>> outAdj,
    List<List<int>> inAdj,
  ) {
    if (columns.length < 2) return;
    var prev = _countCrossings(columns, outAdj);
    for (var it = 0; it < maxOrderingIterations; it++) {
      _barycenterPass(columns, outAdj, inAdj, downward: it.isEven);
      final cur = _countCrossings(columns, outAdj);
      if (cur >= prev) break;
      prev = cur;
    }
  }

  void _barycenterPass(
    List<List<int>> columns,
    List<List<int>> outAdj,
    List<List<int>> inAdj, {
    required bool downward,
  }) {
    final pos = <int, int>{};
    for (final row in columns) {
      for (var i = 0; i < row.length; i++) {
        pos[row[i]] = i;
      }
    }
    if (downward) {
      for (var c = 1; c < columns.length; c++) {
        columns[c].sort((a, b) =>
            _barycenter(a, inAdj, pos).compareTo(_barycenter(b, inAdj, pos)));
        for (var i = 0; i < columns[c].length; i++) {
          pos[columns[c][i]] = i;
        }
      }
    } else {
      for (var c = columns.length - 2; c >= 0; c--) {
        columns[c].sort((a, b) =>
            _barycenter(a, outAdj, pos).compareTo(_barycenter(b, outAdj, pos)));
        for (var i = 0; i < columns[c].length; i++) {
          pos[columns[c][i]] = i;
        }
      }
    }
  }

  double _barycenter(int node, List<List<int>> adj, Map<int, int> pos) {
    var sum = 0.0;
    var count = 0;
    for (final n in adj[node]) {
      final p = pos[n];
      if (p == null) continue;
      sum += p;
      count++;
    }
    return count == 0 ? 0 : sum / count;
  }

  /// Counts edge crossings between every adjacent column pair via merge-
  /// sort inversion counting — `O(L log L)` per pair vs `O(L²)` for the
  /// naive pairwise check. Lets the iterative ordering scale to graphs
  /// with hundreds of links without blowing the layout budget.
  int _countCrossings(List<List<int>> columns, List<List<int>> outAdj) {
    final pos = <int, int>{};
    for (final row in columns) {
      for (var i = 0; i < row.length; i++) {
        pos[row[i]] = i;
      }
    }
    var total = 0;
    for (var c = 0; c < columns.length - 1; c++) {
      final edges = <List<int>>[];
      for (final u in columns[c]) {
        for (final v in outAdj[u]) {
          final pu = pos[u];
          final pv = pos[v];
          if (pu == null || pv == null) continue;
          edges.add([pu, pv]);
        }
      }
      // Sort by source position, break ties by target so equal sources
      // don't produce spurious inversions.
      edges.sort((a, b) {
        final cmp = a[0].compareTo(b[0]);
        return cmp != 0 ? cmp : a[1].compareTo(b[1]);
      });
      final targets = List<int>.generate(edges.length, (i) => edges[i][1]);
      total += _countInversions(targets);
    }
    return total;
  }

  static int _countInversions(List<int> arr) {
    if (arr.length < 2) return 0;
    final temp = List<int>.filled(arr.length, 0);
    return _mergeCount(arr, temp, 0, arr.length - 1);
  }

  static int _mergeCount(List<int> arr, List<int> temp, int left, int right) {
    if (left >= right) return 0;
    final mid = (left + right) >> 1;
    var count = _mergeCount(arr, temp, left, mid);
    count += _mergeCount(arr, temp, mid + 1, right);
    count += _mergeStep(arr, temp, left, mid, right);
    return count;
  }

  static int _mergeStep(
      List<int> arr, List<int> temp, int left, int mid, int right) {
    var i = left, j = mid + 1, k = left;
    var inv = 0;
    while (i <= mid && j <= right) {
      if (arr[i] <= arr[j]) {
        temp[k++] = arr[i++];
      } else {
        temp[k++] = arr[j++];
        inv += mid - i + 1;
      }
    }
    while (i <= mid) {
      temp[k++] = arr[i++];
    }
    while (j <= right) {
      temp[k++] = arr[j++];
    }
    for (var x = left; x <= right; x++) {
      arr[x] = temp[x];
    }
    return inv;
  }
}
