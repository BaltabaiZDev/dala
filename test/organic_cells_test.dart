import 'dart:math' as math;
import 'package:antiyoy_self/src/ui/organic_cells.dart';
import 'package:flutter_test/flutter_test.dart';

double area(List<Offset> points) {
  // Translate first to avoid cancellation for distant coordinates.
  final origin = points.first;
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i] - origin;
    final b = points[(i + 1) % points.length] - origin;
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  return sum.abs() / 2;
}

void main() {
  test('shared land, coast and water edges are exactly reversed', () {
    for (var q = -10; q <= 10; q++) {
      for (var r = -10; r <= 10; r++) {
        for (var d = 0; d < 6; d++) {
          final delta = OrganicCells.directions[d];
          expect(
            OrganicCells.edge(q, r, d),
            OrganicCells.edge(
              q + delta.$1,
              r + delta.$2,
              (d + 3) % 6,
            ).reversed.toList(),
          );
        }
      }
    }
  });
  test('curves preserve equal area and a broad circular center', () {
    final expectedArea = 3 * math.sqrt(3) * 30 * 30 / 2;
    var maxError = 0.0;
    for (var q = -20; q <= 20; q++) {
      for (var r = -20; r <= 20; r++) {
        final error = (area(OrganicCells.boundary(q, r)) / expectedArea - 1)
            .abs();
        maxError = math.max(maxError, error);
        expect(error, lessThan(.0001), reason: 'Area at $q,$r');
        final center = OrganicCells.center(q, r);
        for (var i = 0; i < 72; i++) {
          final angle = i * math.pi / 36;
          final point = center + Offset(math.cos(angle), math.sin(angle)) * 19;
          expect(
            OrganicCells.path(q, r).contains(point),
            isTrue,
            reason: '19-unit core at $q,$r',
          );
        }
        expect(OrganicCells.coordinateAt(center), (q, r));
      }
    }
    // Recorded for design verification, independently of a visual golden.
    // ignore: avoid_print
    print(
      'Maximum rendered cell area error: ${(maxError * 100).toStringAsFixed(6)}%',
    );
  });
  test('pointer selection follows lobes, without gaps or overlaps', () {
    for (var x = 20.37; x < 700; x += 5.71) {
      for (var y = 15.29; y < 700; y += 5.13) {
        final point = Offset(x, y);
        final origin = OrganicCells.nearestAxial(point);
        final containing = <(int, int)>[];
        for (final delta in [(0, 0), ...OrganicCells.directions]) {
          final cell = (origin.$1 + delta.$1, origin.$2 + delta.$2);
          if (OrganicCells.path(cell.$1, cell.$2).contains(point)) {
            containing.add(cell);
          }
        }
        expect(containing, hasLength(1), reason: 'Tiling at $point');
        expect(OrganicCells.coordinateAt(point), containing.single);
      }
    }
  });
  test('silhouettes vary while inverse map remains stable', () {
    final shapes = <String>{};
    for (var q = 0; q < 30; q++) {
      final center = OrganicCells.center(q, 3);
      shapes.add(
        OrganicCells.boundary(q, 3)
            .map(
              (p) =>
                  '${(p.dx - center.dx).toStringAsFixed(2)},${(p.dy - center.dy).toStringAsFixed(2)}',
            )
            .join(';'),
      );
      final p = Offset(q * 47.123, q * 79.813);
      expect(
        (OrganicCells.unwarp(OrganicCells.warp(p)) - p).distance,
        lessThan(1e-10),
      );
    }
    expect(shapes, hasLength(30));
  });
}
