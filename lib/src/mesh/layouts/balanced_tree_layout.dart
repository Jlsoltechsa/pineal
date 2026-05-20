import 'dart:typed_data';
import 'dart:ui';

import '../edge_buffer.dart';
import '../node_buffer.dart';
import 'graph_layout.dart';

/// Layout de árbol balanceado (Reingold–Tilford / Walker / Buchheim).
///
/// Equilibra el árbol respetando la regla canónica de "tidy trees":
///
/// 1. **Subárboles iguales tienen layouts idénticos** — la forma no
///    depende de la posición del subárbol dentro del árbol completo.
/// 2. **Padres centrados sobre sus hijos** — cada nodo queda sobre el
///    punto medio de la huella de sus descendientes.
/// 3. **Sin solapamientos** — los contornos de subárboles vecinos se
///    "empujan" lo justo y necesario para no chocar.
/// 4. **`O(n)` en tiempo** — la versión Buchheim 2002 usa un "default
///    ancestor" y "threads" para alcanzar tiempo lineal.
///
/// Comparado con [TreeLayout] (que reserva ancho por subárbol y luego
/// reparte): éste produce árboles más compactos y simétricos a costa de
/// más bookkeeping interno. Cuando los subárboles son de tamaño muy
/// distinto, la diferencia visual se nota.
///
/// Si el grafo de entrada tiene ciclos o varias componentes, los maneja
/// como [TreeLayout]: BFS desde [rootIndex] sobre la adyacencia
/// indirigida para fabricar un árbol enraizado.
class BalancedTreeLayout extends GraphLayout {
  const BalancedTreeLayout({
    this.rootIndex,
    this.layerSpacing = 110,
    this.subtreeSeparation = 60,
    this.siblingSeparation = 40,
    this.horizontal = false,
  });

  /// Nodo raíz. Si es null, usa 0.
  final int? rootIndex;

  /// Separación entre capas (vertical si `horizontal=false`).
  final double layerSpacing;

  /// Separación mínima horizontal entre subárboles hermanos.
  final double subtreeSeparation;

  /// Separación mínima horizontal entre nodos hermanos (al mismo padre).
  final double siblingSeparation;

  /// Si es true, el árbol fluye de izquierda a derecha en vez de arriba
  /// hacia abajo.
  final bool horizontal;

  @override
  void apply(NodeBuffer nodes, EdgeBuffer edges, {Rect? bounds}) {
    final n = nodes.length;
    if (n == 0) return;

    final root = (rootIndex ?? 0).clamp(0, n - 1);

    // ── Adyacencia indirigida ────────────────────────────────────────────
    final adj = List<List<int>>.generate(n, (_) => <int>[]);
    for (var i = 0; i < edges.length; i++) {
      final s = edges.src(i), t = edges.tgt(i);
      if (s == t) continue;
      adj[s].add(t);
      adj[t].add(s);
    }

    // ── BFS desde root para construir el árbol enraizado ─────────────────
    final parent = Int32List(n)..fillRange(0, n, -1);
    final children = List<List<int>>.generate(n, (_) => <int>[]);
    final depth = Int32List(n);
    final visited = List<bool>.filled(n, false);
    visited[root] = true;
    final queue = <int>[root];
    var head = 0;
    while (head < queue.length) {
      final u = queue[head++];
      for (final v in adj[u]) {
        if (visited[v]) continue;
        visited[v] = true;
        parent[v] = u;
        depth[v] = depth[u] + 1;
        children[u].add(v);
        queue.add(v);
      }
    }

    // Índice del hijo dentro del padre (1-based para el algoritmo).
    final childIndex = Int32List(n);
    for (var u = 0; u < n; u++) {
      for (var i = 0; i < children[u].length; i++) {
        childIndex[children[u][i]] = i;
      }
    }

    // ── Buchheim: estado por nodo ────────────────────────────────────────
    // `prelim` x preliminar (antes del second walk).
    final prelim = Float64List(n);
    // `mod` desplazamiento acumulado a propagar a descendientes.
    final mod = Float64List(n);
    // `shift` y `change`: redistribución entre subárboles para que el
    // espacio extra del apportion se reparta uniforme entre hermanos.
    final shift = Float64List(n);
    final change = Float64List(n);
    // `thread`: puntero a "siguiente nodo en el contorno" cuando el
    // árbol no tiene hijo en esa dirección. -1 = ninguno.
    final thread = Int32List(n)..fillRange(0, n, -1);
    // `ancestor`: para el apportion. Se inicializa a sí mismo.
    final ancestor = Int32List(n);
    for (var i = 0; i < n; i++) {
      ancestor[i] = i;
    }

    // El distance entre dos nodos a la misma profundidad. Hermanos
    // directos (mismo padre) usan siblingSeparation; subárboles distintos
    // usan subtreeSeparation. Para Buchheim original el `distance` es
    // global; aquí lo combinamos en _distance(v, w).
    double distanceBetween(int v, int w) {
      if (parent[v] == parent[w] && parent[v] != -1) {
        return siblingSeparation;
      }
      return subtreeSeparation;
    }

    int leftSibling(int v) {
      final p = parent[v];
      if (p == -1) return -1;
      final idx = childIndex[v];
      if (idx == 0) return -1;
      return children[p][idx - 1];
    }

    int leftmostSibling(int v) {
      final p = parent[v];
      if (p == -1) return -1;
      if (childIndex[v] == 0) return -1;
      return children[p][0];
    }

    int nextLeft(int v) =>
        children[v].isNotEmpty ? children[v].first : thread[v];

    int nextRight(int v) =>
        children[v].isNotEmpty ? children[v].last : thread[v];

    int resolveAncestor(int vInLeft, int v, int defaultAncestor) {
      // Si el ancestor de vInLeft es hermano de v, úsalo. Si no,
      // defaultAncestor.
      final cand = ancestor[vInLeft];
      if (cand != -1 && parent[cand] == parent[v]) return cand;
      return defaultAncestor;
    }

    void moveSubtree(int wL, int wR, double s) {
      final subtrees = childIndex[wR] - childIndex[wL];
      if (subtrees == 0) return;
      change[wR] -= s / subtrees;
      shift[wR] += s;
      change[wL] += s / subtrees;
      prelim[wR] += s;
      mod[wR] += s;
    }

    void executeShifts(int v) {
      var s = 0.0;
      var ch = 0.0;
      final cs = children[v];
      for (var i = cs.length - 1; i >= 0; i--) {
        final w = cs[i];
        prelim[w] += s;
        mod[w] += s;
        ch += change[w];
        s += shift[w] + ch;
      }
    }

    void apportion(int v, List<int> defaultAncestorRef) {
      final left = leftSibling(v);
      if (left == -1) return;
      var vir = v;        // vInRight
      var vor = v;        // vOutRight
      var vil = left;     // vInLeft
      var vol = leftmostSibling(v);  // vOutLeft
      var sir = mod[vir];
      var sor = mod[vor];
      var sil = mod[vil];
      var sol = mod[vol];
      while (nextRight(vil) != -1 && nextLeft(vir) != -1) {
        vil = nextRight(vil);
        vir = nextLeft(vir);
        vol = nextLeft(vol);
        vor = nextRight(vor);
        ancestor[vor] = v;
        final s = (prelim[vil] + sil) - (prelim[vir] + sir)
            + distanceBetween(vil, vir);
        if (s > 0) {
          moveSubtree(
              resolveAncestor(vil, v, defaultAncestorRef[0]), v, s);
          sir += s;
          sor += s;
        }
        sil += mod[vil];
        sir += mod[vir];
        sol += mod[vol];
        sor += mod[vor];
      }
      if (nextRight(vil) != -1 && nextRight(vor) == -1) {
        thread[vor] = nextRight(vil);
        mod[vor] += sil - sor;
      }
      if (nextLeft(vir) != -1 && nextLeft(vol) == -1) {
        thread[vol] = nextLeft(vir);
        mod[vol] += sir - sol;
        defaultAncestorRef[0] = v;
      }
    }

    // ── First walk (post-order iterativo) ────────────────────────────────
    // Visita post-orden con stack explícito; `defaultAncestor` por nodo
    // mantenido en una lista mutable (necesario para apportion).
    final iterIdx = Int32List(n);
    final defaultAncestorByParent = Int32List(n);
    final stack = <int>[];
    stack.add(root);
    while (stack.isNotEmpty) {
      final v = stack.last;
      final c = children[v];
      if (iterIdx[v] < c.length) {
        final w = c[iterIdx[v]];
        iterIdx[v]++;
        // Antes de visitar el hijo, registramos defaultAncestor = primer
        // hijo de v (sólo importa que sea el primero al apportion-ar el
        // primer hijo).
        if (c.isNotEmpty) defaultAncestorByParent[v] = c.first;
        stack.add(w);
      } else {
        // Post-orden de v.
        if (c.isEmpty) {
          final ls = leftSibling(v);
          prelim[v] = ls == -1
              ? 0.0
              : prelim[ls] + distanceBetween(ls, v);
        } else {
          // defaultAncestor en una lista mutable para que apportion lo
          // pueda actualizar.
          final daRef = <int>[defaultAncestorByParent[v]];
          for (final w in c) {
            apportion(w, daRef);
          }
          executeShifts(v);
          final midpoint =
              (prelim[c.first] + prelim[c.last]) * 0.5;
          final ls = leftSibling(v);
          if (ls != -1) {
            prelim[v] = prelim[ls] + distanceBetween(ls, v);
            mod[v] = prelim[v] - midpoint;
          } else {
            prelim[v] = midpoint;
          }
        }
        stack.removeLast();
      }
    }

    // ── Second walk: acumula `mod` y asigna posiciones finales ───────────
    double xMin = double.infinity;
    double xMax = -double.infinity;
    // Stack de (nodo, modSumadoAcumulado).
    final walkStack = <(int, double)>[];
    walkStack.add((root, -prelim[root])); // centra la raíz en x=0
    while (walkStack.isNotEmpty) {
      final (u, m) = walkStack.removeLast();
      final x = prelim[u] + m;
      final y = depth[u] * layerSpacing;
      if (x < xMin) xMin = x;
      if (x > xMax) xMax = x;
      if (horizontal) {
        nodes.setXY(u, y, x);
      } else {
        nodes.setXY(u, x, y);
      }
      for (final w in children[u]) {
        walkStack.add((w, m + mod[u]));
      }
    }

    nodes.revision++;
  }
}
