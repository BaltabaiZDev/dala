import 'dart:math' as math;
import 'dart:ui';

/// A shared, equal-area curvilinear tiling. No geometry enters the simulation.
/// Each S edge is point-symmetric about its midpoint, so its signed area
/// relative to the straight chord is zero. Two reversible shears have unit
/// Jacobian determinant, preserving that area while varying cell silhouettes.
class OrganicCells {
  static const radius = 30.0;
  static const padding = 100.0;
  static const directions = [
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, 0),
    (-1, 1),
    (0, 1),
  ];
  static final _paths = <(int, int), Path>{};
  static final _boundaries = <(int, int), List<Offset>>{};
  static final _edges = <(int, int, int), List<Offset>>{};
  static final _edgePaths = <(int, int, int), Path>{};
  static final _centers = <(int, int), Offset>{};
  static final _centerCoordinates = <Offset, (int, int)>{};
  // A giant board has 5,041 cells. Bound retained geometry across editor/map
  // changes and off-board pointer input without evicting a normal whole map.
  static T _cached<K, T>(
    Map<K, T> cache,
    K key,
    int limit,
    T Function() build,
  ) {
    final existing = cache[key];
    if (existing != null) return existing;
    if (cache.length >= limit) cache.remove(cache.keys.first);
    return cache[key] = build();
  }

  static const _vertexX = [2, 1, -1, -2, -1, 1];
  static const _vertexY = [0, 1, 1, 0, -1, -1];
  static const _edgeVertex = [0, 5, 4, 3, 2, 1];

  static Offset warp(Offset point) {
    final x = point.dx + 8 * math.sin(point.dy / 113 + .7);
    return Offset(x, point.dy + 7 * math.sin(x / 127 + 1.1));
  }

  static Offset unwarp(Offset point) {
    final y = point.dy - 7 * math.sin(point.dx / 127 + 1.1);
    return Offset(point.dx - 8 * math.sin(y / 113 + .7), y);
  }

  static Offset center(int q, int r) {
    final value = _cached(
      _centers,
      (q, r),
      8192,
      () => warp(
        Offset(
          padding + radius * (1.5 * q + 1),
          padding + math.sqrt(3) * radius * (r + q / 2 + .5),
        ),
      ),
    );
    _cached(_centerCoordinates, value, 8192, () => (q, r));
    return value;
  }

  static (int, int) nearestAxial(Offset position) {
    final point = unwarp(position);
    final q = (point.dx - padding - radius) / (radius * 1.5);
    final r =
        (point.dy - padding - math.sqrt(3) * radius * .5) /
            (math.sqrt(3) * radius) -
        q / 2;
    var cq = q.round();
    var cr = r.round();
    final cs = (-q - r).round();
    final dq = (cq - q).abs();
    final dr = (cr - r).abs();
    if (dq > dr && dq > (cs + q + r).abs()) {
      cq = -cr - cs;
    } else if (dr > (cs + q + r).abs()) {
      cr = -cq - cs;
    }
    return (cq, cr);
  }

  /// Selection, fog, painting and pointer input share this exact boundary.
  static (int, int) coordinateAt(Offset point) {
    final origin = nearestAxial(point);
    for (final delta in [(0, 0), ...directions]) {
      final q = origin.$1 + delta.$1;
      final r = origin.$2 + delta.$2;
      if (path(q, r).contains(point)) return (q, r);
    }
    return origin; // Boundary tie: deterministic choice, no dead pixel strips.
  }

  static List<Offset> edge(int q, int r, int direction) {
    final neighbor = directions[direction];
    final nq = q + neighbor.$1;
    final nr = r + neighbor.$2;
    final reverse = nq < q || (nq == q && nr < r);
    final cq = reverse ? nq : q;
    final cr = reverse ? nr : r;
    final cd = reverse ? (direction + 3) % 6 : direction;
    final key = (cq, cr, cd);
    final points = _cached(_edges, key, 32768, () {
      final v = _edgeVertex[cd];
      Offset vertex(int i) => Offset(
        padding + radius + (3 * cq + _vertexX[i]) * radius / 2,
        padding +
            math.sqrt(3) * radius * .5 +
            (2 * cr + cq + _vertexY[i]) * math.sqrt(3) * radius / 2,
      );
      final a = vertex(v);
      final b = vertex((v + 1) % 6);
      final chord = b - a;
      final normal = Offset(-chord.dy, chord.dx) / chord.distance;
      final hash =
          ((cq * 73856093) ^ (cr * 19349663) ^ (cd * 83492791)) & 0x7fffffff;
      final bend =
          radius * (.32 + (hash % 997) / 997 * .29) * (hash.isEven ? 1 : -1);
      // Symmetric samples cancel the signed chord area even in the polygon
      // approximation; the shear introduces <0.01% rendering area error.
      return List.generate(25, (i) {
        final t = i / 24;
        final normalOffset = 3 * t * (1 - t) * (1 - 2 * t) * bend;
        return warp(a + chord * t + normal * normalOffset);
      }, growable: false);
    });
    return reverse ? points.reversed.toList(growable: false) : points;
  }

  static List<Offset> boundary(int q, int r) => _cached(
    _boundaries,
    (q, r),
    8192,
    () => [
      for (final direction in [0, 5, 4, 3, 2, 1])
        ...edge(q, r, direction).take(24),
    ],
  );

  static Path path(int q, int r) => _cached(_paths, (q, r), 8192, () {
    final result = Path();
    for (final direction in [0, 5, 4, 3, 2, 1]) {
      _appendCurve(result, edge(q, r, direction), move: direction == 0);
    }
    return result..close();
  });

  // Two cubic pieces interpolate each shared warped edge. The old 24 tiny
  // straight strokes per edge forced mobile GPUs to tessellate hundreds of
  // thousands of round joins on giant maps. Cubics retain the same lobes and
  // endpoints with a sub-pixel approximation, and GPU-adaptive subdivision.
  static void _appendCurve(Path path, List<Offset> p, {bool move = true}) {
    if (move) path.moveTo(p.first.dx, p.first.dy);
    for (final start in [0, 12]) {
      final a = p[start + 4] * 27 - p[start] * 8 - p[start + 12];
      final b = p[start + 8] * 27 - p[start] - p[start + 12] * 8;
      final c1 = (a * 2 - b) / 18;
      final c2 = (b * 2 - a) / 18;
      final end = p[start + 12];
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
    }
  }

  static Path around(Offset cellCenter, {double inset = 0}) {
    final coordinate =
        _centerCoordinates[cellCenter] ?? nearestAxial(cellCenter);
    final original = path(coordinate.$1, coordinate.$2);
    if (inset == 0) return original;
    final scale = (radius - inset) / radius;
    return Path()..addPolygon([
      for (final point in boundary(coordinate.$1, coordinate.$2))
        cellCenter + (point - cellCenter) * scale,
    ], true);
  }

  static Path edgePath(Offset cellCenter, int direction) {
    final coordinate =
        _centerCoordinates[cellCenter] ?? nearestAxial(cellCenter);
    return _cached(
      _edgePaths,
      (coordinate.$1, coordinate.$2, direction),
      32768,
      () {
        final path = Path();
        _appendCurve(path, edge(coordinate.$1, coordinate.$2, direction));
        return path;
      },
    );
  }
}
