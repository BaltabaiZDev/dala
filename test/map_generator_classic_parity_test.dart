import 'dart:math' as math;

import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test('Classic land phases are deterministic, linked and hole free', () {
    const budgets = <MapSize, int>{
      MapSize.small: 206,
      MapSize.medium: 378,
      MapSize.large: 630,
      MapSize.huge: 1060,
      MapSize.giant: 1749,
    };
    for (final size in MapSize.values) {
      for (final seed in const [1, 29, 4242]) {
        final config = GameConfig(mapSize: size, seed: seed);
        final first = MapGenerator(mod).generate(config);
        final repeated = MapGenerator(mod).generate(config);

        expect(_signature(first), _signature(repeated));
        expect(
          first.hexes.where((tile) => tile.active),
          hasLength(budgets[size]),
          reason: '$size/$seed keeps the local fixed land budget',
        );
        expect(
          first.hexes.where((tile) => tile.active).length,
          greaterThan(first.hexes.where((tile) => tile.inWorld).length * 0.25),
          reason: '$size/$seed keeps Classic isGood land density',
        );
        expect(
          _landComponents(first),
          hasLength(1),
          reason: '$size/$seed must pass Classic isLinked',
        );
        expect(
          _waterTileComponents(
            first,
          ).every((component) => component.length >= 3),
          isTrue,
          reason: '$size/$seed has no one/two-hex holes',
        );
      }
    }
  });

  test('arena bounds stay fixed while external seeds change coastlines', () {
    final worldMasks = <String>{};
    final coastlines = <String>{};
    for (var seed = 100; seed < 112; seed++) {
      final state = MapGenerator(
        mod,
      ).generate(GameConfig(mapSize: MapSize.small, seed: seed));
      worldMasks.add(
        state.hexes
            .where((tile) => tile.inWorld)
            .map((tile) => tile.index)
            .join(','),
      );
      coastlines.add(
        state.hexes
            .where(
              (tile) =>
                  tile.active &&
                  tile.neighbors.any(
                    (neighbor) =>
                        state.hexes[neighbor].inWorld &&
                        !state.hexes[neighbor].active,
                  ),
            )
            .map((tile) => tile.index)
            .join(','),
      );
    }
    expect(worldMasks, hasLength(1));
    expect(coastlines.length, greaterThanOrEqualTo(10));
  });

  test('size frames are fully editable and giant extends the arena', () {
    const dimensions = <MapSize, (int, int)>{
      MapSize.small: (27, 27),
      MapSize.medium: (35, 35),
      MapSize.large: (43, 43),
      MapSize.huge: (55, 55),
      MapSize.giant: (71, 71),
    };
    for (final entry in dimensions.entries) {
      final state = MapGenerator(
        mod,
      ).generate(GameConfig(mapSize: entry.key, seed: 8800 + entry.key.index));
      expect((state.width, state.height), entry.value);
      expect(
        state.hexes,
        everyElement(
          isA<HexTile>().having((tile) => tile.inWorld, 'inWorld', isTrue),
        ),
      );
    }
  });

  test('editor blank is all-water and contains no generated pieces', () {
    final state = MapGenerator(mod).createBlank(
      const GameConfig(
        mapSize: MapSize.giant,
        playerCount: 15,
        humanCount: 15,
        seed: 1515,
      ),
    );

    expect(state.width, 71);
    expect(state.height, 71);
    expect(
      state.hexes,
      everyElement(
        isA<HexTile>().having((tile) => tile.inWorld, 'inWorld', isTrue),
      ),
    );
    expect(state.hexes.where((tile) => tile.active), isEmpty);
    expect(state.provinces, isEmpty);
    expect(
      state.waterCells.expand((cell) => cell.tiles).toSet(),
      state.hexes.map((tile) => tile.index).toSet(),
    );
    expect(
      state.waterCells.every(
        (cell) => cell.boat == null && cell.seaFort == null && !cell.seaMint,
      ),
      isTrue,
    );
  });

  test('giant extension remains linked at the expanded land budget', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.giant,
        playerCount: 15,
        humanCount: 15,
        seed: 150045,
      ),
    );
    expect(state.hexes.where((tile) => tile.active), hasLength(1749));
    expect(_landComponents(state), hasLength(1));
    expect(
      state.waterCells.every(
        (cell) =>
            cell.tiles.length >= 3 &&
            cell.tiles.length <= 5 &&
            _cellIsConnected(state, cell),
      ),
      isTrue,
    );
    expect(state.provinces.map((province) => province.owner).toSet(), {
      for (var owner = 0; owner < 15; owner++) owner,
    });
  });

  test(
    'Generic starts keep exact counts, connected economies and max five',
    () {
      for (var count = 1; count <= 3; count++) {
        final state = MapGenerator(mod).generate(
          GameConfig(
            mapSize: MapSize.medium,
            playerCount: 7,
            startingProvinceCount: count,
            seed: 7000 + count,
          ),
        );
        for (var owner = 0; owner < 7; owner++) {
          final provinces = state.provinces
              .where((province) => province.owner == owner)
              .toList();
          expect(provinces, hasLength(count));
          for (final province in provinces) {
            expect(province.tiles.length, inInclusiveRange(2, 5));
            expect(_provinceIsConnected(state, province), isTrue);
            expect(state.hexes[province.capital].object, TileObject.town);
          }
        }
      }
    },
  );

  test('Generic capitals replace only their own tree', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.medium,
        playerCount: 7,
        startingProvinceCount: 3,
        treePercent: 100,
        seed: 77331,
      ),
    );
    for (final province in state.provinces) {
      expect(state.hexes[province.capital].object, TileObject.town);
      expect(
        province.tiles
            .where((index) => index != province.capital)
            .map((index) => state.hexes[index].hasTree),
        everyElement(isTrue),
        reason: 'Generic balancing must not erase non-capital trees',
      );
    }
  });

  test('default starts remain deterministic per-player one to three', () {
    const config = GameConfig(
      mapSize: MapSize.medium,
      playerCount: 15,
      startingProvinceCount: 0,
      seed: 812,
    );
    final first = MapGenerator(mod).generate(config);
    final repeated = MapGenerator(mod).generate(config);
    final counts = <int>[
      for (var owner = 0; owner < 15; owner++)
        first.provinces.where((province) => province.owner == owner).length,
    ];
    final repeatedCounts = <int>[
      for (var owner = 0; owner < 15; owner++)
        repeated.provinces.where((province) => province.owner == owner).length,
    ];
    expect(counts, repeatedCounts);
    expect(counts, everyElement(inInclusiveRange(1, 3)));
    expect(counts.toSet().length, greaterThan(1));
  });

  test('fifteen players can each reserve three real starting provinces', () {
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 15,
        startingProvinceCount: 3,
        seed: 15003,
      ),
    );
    expect(state.provinces, hasLength(45));
    for (var owner = 0; owner < 15; owner++) {
      expect(
        state.provinces.where((province) => province.owner == owner),
        hasLength(3),
      );
    }
  });

  test('Classic turn-order compensation survives the 2-15 adaptation', () {
    var firstPlayerLand = 0;
    var lastPlayerLand = 0;
    for (var seed = 1; seed <= 24; seed++) {
      final state = MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.medium,
          playerCount: 7,
          startingProvinceCount: 1,
          seed: 9000 + seed,
        ),
      );
      firstPlayerLand += state.provinces
          .where((province) => province.owner == 0)
          .single
          .tiles
          .length;
      lastPlayerLand += state.provinces
          .where((province) => province.owner == 6)
          .single
          .tiles
          .length;
    }
    expect(lastPlayerLand, greaterThan(firstPlayerLand));
  });

  test('Slay cuts to five and balances real province counts', () {
    for (final seed in const [7, 824, 1901, 15015]) {
      final state = MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.small,
          playerCount: 15,
          seed: seed,
          slayRules: true,
        ),
      );
      final components = _ownedComponents(state);
      expect(
        components.every((component) => component.tiles.length <= 5),
        isTrue,
      );
      expect(
        state.hexes
            .where((tile) => tile.active)
            .every((tile) => tile.owner >= 0),
        isTrue,
      );
      final provinceCounts = List<int>.filled(15, 0);
      for (final component in components.where(
        (component) => component.tiles.length >= 2,
      )) {
        provinceCounts[component.owner]++;
      }
      expect(provinceCounts, everyElement(greaterThan(0)));
      expect(
        provinceCounts.reduce((a, b) => a > b ? a : b) -
            provinceCounts.reduce((a, b) => a < b ? a : b),
        lessThanOrEqualTo(1),
      );
    }
  });

  test('coasts and carved lakes remain navigable for the naval extension', () {
    var sawEnclosedLake = false;
    for (var seed = 1; seed <= 40; seed++) {
      final state = MapGenerator(
        mod,
      ).generate(GameConfig(mapSize: MapSize.small, seed: seed));
      expect(
        state.waterCells.expand((cell) => cell.tiles).toSet(),
        state.hexes
            .where((tile) => tile.inWorld && !tile.active)
            .map((tile) => tile.index)
            .toSet(),
      );
      expect(
        state.waterCells.any(
          (cell) => cell.navigable && cell.coastTiles.isNotEmpty,
        ),
        isTrue,
      );
      for (final component in _waterCellComponents(state)) {
        final rawTiles = component
            .expand((index) => state.waterCells[index].tiles)
            .toSet();
        final enclosed = rawTiles.every((index) {
          final tile = state.hexes[index];
          return tile.neighbors.length == 6 &&
              tile.neighbors.every((neighbor) => state.hexes[neighbor].inWorld);
        });
        if (!enclosed) continue;
        sawEnclosedLake = true;
        expect(component.length, greaterThanOrEqualTo(3));
        expect(
          component.every((index) => state.waterCells[index].navigable),
          isTrue,
        );
      }
    }
    expect(sawEnclosedLake, isTrue);
  });

  test(
    'representative size capacities and every province setup generate safely',
    () {
      for (final size in MapSize.values) {
        final playerCounts = <int>{
          2,
          math.min(4, size.maxPlayers),
          size.maxPlayers,
        };
        for (final players in playerCounts) {
          for (
            var startingProvinces = 0;
            startingProvinces <= 3;
            startingProvinces++
          ) {
            final seed =
                1000000 * (size.index + 1) +
                10000 * players +
                101 * startingProvinces;
            final state = MapGenerator(mod).generate(
              GameConfig(
                mapSize: size,
                playerCount: players,
                startingProvinceCount: startingProvinces,
                seed: seed,
              ),
            );
            for (var owner = 0; owner < players; owner++) {
              final provinces = state.provinces
                  .where((province) => province.owner == owner)
                  .toList();
              if (startingProvinces == 0) {
                expect(
                  provinces.length,
                  inInclusiveRange(1, 3),
                  reason: '$size/$players/default/$seed',
                );
              } else {
                expect(
                  provinces,
                  hasLength(startingProvinces),
                  reason: '$size/$players/$startingProvinces/$seed',
                );
              }
              expect(
                provinces.every(
                  (province) =>
                      province.tiles.length >= 2 &&
                      province.tiles.length <= 5 &&
                      _provinceIsConnected(state, province),
                ),
                isTrue,
                reason: '$size/$players/$startingProvinces/$seed',
              );
            }
            expect(
              state.waterCells.every(
                (cell) =>
                    cell.tiles.length >= 3 &&
                    cell.tiles.length <= 5 &&
                    _cellIsConnected(state, cell),
              ),
              isTrue,
              reason:
                  '$size/$players/$startingProvinces/$seed invalid cells: '
                  '${state.waterCells.where((cell) => cell.tiles.length < 3 || cell.tiles.length > 5 || !_cellIsConnected(state, cell)).map((cell) => '${cell.index}:${cell.tiles}:neighbors=${cell.neighbors.map((index) => '$index/${state.waterCells[index].tiles}').join(',')}').join(';')}',
            );
          }
        }
      }

      // Extra pressure on the densest supported setup, where the old random
      // matching heuristic had the smallest margin for a successful result.
      for (var seed = 0; seed < 12; seed++) {
        final state = MapGenerator(mod).generate(
          GameConfig(
            mapSize: MapSize.small,
            playerCount: 15,
            startingProvinceCount: 3,
            seed: 930000 + seed,
          ),
        );
        expect(state.provinces, hasLength(45), reason: 'crowded seed $seed');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('water repack keeps boats forts and mint when free cells exist', () {
    for (final asset in const ['boat', 'fort', 'mint']) {
      final state = MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.small,
          seed: switch (asset) {
            'boat' => 441,
            'fort' => 442,
            _ => 443,
          },
        ),
      );
      final central = state.waterCells.firstWhere(
        (cell) =>
            cell.navigable &&
            cell.tiles.length >= 3 &&
            cell.neighbors.length >= 2,
      );
      final sourceTiles = <int>[
        central.tiles.first,
        for (final neighbor in central.neighbors)
          state.waterCells[neighbor].tiles.first,
        central.tiles[1],
      ];
      final allWaterTiles = state.waterCells
          .expand((cell) => cell.tiles)
          .toSet();
      final remaining = allWaterTiles.difference(sourceTiles.toSet()).toList()
        ..sort();
      final malformed = <WaterCell>[];
      for (var index = 0; index < sourceTiles.length; index++) {
        malformed.add(
          WaterCell(
            index: malformed.length,
            tiles: [sourceTiles[index]],
            boat: asset == 'boat'
                ? GameBoat(owner: 0, level: 1, homeProvinceId: 1)
                : null,
            seaFort: asset == 'fort'
                ? SeaFort(owner: 0, homeProvinceId: 1)
                : null,
            seaMint: asset == 'mint',
          ),
        );
      }
      for (final tile in remaining) {
        malformed.add(WaterCell(index: malformed.length, tiles: [tile]));
      }
      state.waterCells
        ..clear()
        ..addAll(malformed);

      MapGenerator.ensureWaterCells(state);

      final preserved = switch (asset) {
        'boat' => state.waterCells.where((cell) => cell.boat != null).length,
        'fort' => state.waterCells.where((cell) => cell.seaFort != null).length,
        _ => state.waterCells.where((cell) => cell.seaMint).length,
      };
      expect(
        preserved,
        sourceTiles.length,
        reason: '$asset must not be dropped',
      );
      expect(
        state.waterCells.every(
          (cell) =>
              cell.tiles.length >= 3 &&
              cell.tiles.length <= 5 &&
              _cellIsConnected(state, cell),
        ),
        isTrue,
      );
    }
  });
}

String _signature(GameState state) => state.hexes
    .map(
      (tile) =>
          '${tile.inWorld}:${tile.active}:${tile.owner}:${tile.object.name}',
    )
    .join('|');

List<List<int>> _landComponents(GameState state) => _components(
  state.hexes.where((tile) => tile.active).map((tile) => tile.index).toSet(),
  (index) => state.hexes[index].neighbors.where(
    (neighbor) => state.hexes[neighbor].active,
  ),
);

List<List<int>> _waterTileComponents(GameState state) => _components(
  state.hexes
      .where((tile) => tile.inWorld && !tile.active)
      .map((tile) => tile.index)
      .toSet(),
  (index) => state.hexes[index].neighbors.where(
    (neighbor) =>
        state.hexes[neighbor].inWorld && !state.hexes[neighbor].active,
  ),
);

List<List<int>> _waterCellComponents(GameState state) => _components(
  state.waterCells.map((cell) => cell.index).toSet(),
  (index) => state.waterCells[index].neighbors,
);

List<List<int>> _components(
  Set<int> source,
  Iterable<int> Function(int index) neighbors,
) {
  final unseen = {...source};
  final result = <List<int>>[];
  while (unseen.isNotEmpty) {
    final queue = <int>[unseen.first];
    final component = <int>[];
    unseen.remove(queue.first);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      component.add(index);
      for (final neighbor in neighbors(index)) {
        if (unseen.remove(neighbor)) queue.add(neighbor);
      }
    }
    result.add(component);
  }
  return result;
}

bool _provinceIsConnected(GameState state, Province province) {
  final remaining = province.tiles.toSet();
  final queue = <int>[remaining.first];
  remaining.remove(queue.first);
  for (var cursor = 0; cursor < queue.length; cursor++) {
    for (final neighbor in state.hexes[queue[cursor]].neighbors) {
      if (remaining.remove(neighbor)) queue.add(neighbor);
    }
  }
  return remaining.isEmpty;
}

bool _cellIsConnected(GameState state, WaterCell cell) {
  final remaining = cell.tiles.toSet();
  if (remaining.isEmpty) return false;
  final queue = <int>[remaining.first];
  remaining.remove(queue.first);
  for (var cursor = 0; cursor < queue.length; cursor++) {
    for (final neighbor in state.hexes[queue[cursor]].neighbors) {
      if (remaining.remove(neighbor)) queue.add(neighbor);
    }
  }
  return remaining.isEmpty;
}

List<({int owner, List<int> tiles})> _ownedComponents(GameState state) {
  final unseen = state.hexes
      .where((tile) => tile.active && tile.owner >= 0)
      .map((tile) => tile.index)
      .toSet();
  final result = <({int owner, List<int> tiles})>[];
  while (unseen.isNotEmpty) {
    final seed = unseen.first;
    final owner = state.hexes[seed].owner;
    final queue = <int>[seed];
    final tiles = <int>[];
    unseen.remove(seed);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      tiles.add(index);
      for (final neighbor in state.hexes[index].neighbors) {
        if (state.hexes[neighbor].active &&
            state.hexes[neighbor].owner == owner &&
            unseen.remove(neighbor)) {
          queue.add(neighbor);
        }
      }
    }
    result.add((owner: owner, tiles: tiles));
  }
  return result;
}
