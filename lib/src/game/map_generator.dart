import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../modding/game_mod.dart';
import 'models.dart';

/// Generates on a worker isolate on native platforms. Flutter's web fallback
/// still yields before work starts, so the Classic loading overlay is painted
/// instead of leaving the previous screen apparently frozen.
Future<GameState> generateMapAsync(GameMod mod, GameConfig config) async {
  final json = await compute(_generateMapJson, <String, dynamic>{
    'mod': mod.toJson(),
    'config': config.toJson(),
  });
  return GameState.fromJson(json);
}

Map<String, dynamic> _generateMapJson(Map<String, dynamic> payload) {
  final mod = GameMod.fromJson((payload['mod'] as Map).cast<String, dynamic>());
  final config = GameConfig.fromJson(
    (payload['config'] as Map).cast<String, dynamic>(),
  );
  return MapGenerator(mod).generate(config).toJson();
}

class MapGenerator {
  const MapGenerator(this.mod);

  final GameMod mod;

  static const _dimensions = {
    MapSize.small: (27, 27, 206),
    MapSize.medium: (35, 35, 378),
    MapSize.large: (43, 43, 630),
    MapSize.huge: (55, 55, 1060),
    MapSize.giant: (71, 71, 1749),
  };

  static const _legacyDimensions = {
    MapSize.small: (17, 13),
    MapSize.medium: (23, 17),
    MapSize.large: (29, 21),
    MapSize.huge: (37, 27),
  };

  /// Expands saves made with the old land-sized rhombus into a finite sea
  /// arena. Land, province money and pieces keep their relative positions;
  /// the newly created ring is real navigable water rather than background.
  static bool ensureSeaArena(GameState state) {
    final dimensions = _dimensions[state.config.mapSize]!;
    final legacy = _legacyDimensions[state.config.mapSize];
    final isLegacySize =
        legacy != null && state.width == legacy.$1 && state.height == legacy.$2;
    final isMaskedCurrentSize =
        state.width == dimensions.$1 &&
        state.height == dimensions.$2 &&
        state.hexes.any((tile) => !tile.inWorld);
    if (!isLegacySize && !isMaskedCurrentSize) return false;

    final oldWidth = state.width;
    final oldHeight = state.height;
    final oldHexes = [...state.hexes];
    final oldBoats = <({int column, int row, GameBoat boat})>[
      for (final cell in state.waterCells)
        if (cell.boat != null && cell.tiles.isNotEmpty)
          (
            column: cell.tiles.first % oldWidth,
            row: cell.tiles.first ~/ oldWidth,
            boat: cell.boat!,
          ),
    ];
    final oldForts = <({int column, int row, SeaFort fort})>[
      for (final cell in state.waterCells)
        if (cell.seaFort != null && cell.tiles.isNotEmpty)
          (
            column: cell.tiles.first % oldWidth,
            row: cell.tiles.first ~/ oldWidth,
            fort: cell.seaFort!,
          ),
    ];
    final oldMints = <({int column, int row})>[
      for (final cell in state.waterCells)
        if (cell.seaMint && cell.tiles.isNotEmpty)
          (
            column: cell.tiles.first % oldWidth,
            row: cell.tiles.first ~/ oldWidth,
          ),
    ];
    final width = math.max(dimensions.$1, oldWidth);
    final height = math.max(dimensions.$2, oldHeight);
    final hexes = _createRectangularHexGrid(width, height, inWorld: false);
    _wireNeighbors(hexes);
    _markWorldArena(hexes, width, height);

    final offsetQ = (width - oldWidth) ~/ 2;
    final offsetR = (height - oldHeight) ~/ 2;
    final oldToNew = <int, int>{};
    for (final old in oldHexes) {
      final column = old.index % oldWidth + offsetQ;
      final row = old.index ~/ oldWidth + offsetR;
      if (column < 0 || column >= width || row < 0 || row >= height) continue;
      final replacement = hexes[row * width + column];
      if (!old.active) continue;
      replacement
        ..inWorld = true
        ..active = true
        ..owner = old.owner
        ..object = old.object
        ..unit = old.unit
        ..treeBorn = old.treeBorn
        ..artilleryCooldown = old.artilleryCooldown
        ..artilleryAmmo = old.artilleryAmmo;
      oldToNew[old.index] = replacement.index;
    }

    final migratedProvinces = <Province>[];
    for (final province in state.provinces) {
      final tiles = province.tiles
          .map((index) => oldToNew[index])
          .whereType<int>()
          .toList();
      final capital = oldToNew[province.capital];
      if (tiles.isEmpty || capital == null) continue;
      migratedProvinces.add(
        Province(
          id: province.id,
          owner: province.owner,
          tiles: tiles,
          money: province.money,
          capital: capital,
          navalCapital: province.navalCapital,
          navalFounded: province.navalFounded,
        ),
      );
    }

    state
      ..width = width
      ..height = height
      ..provinces = migratedProvinces;
    state.hexes
      ..clear()
      ..addAll(hexes);
    state.waterCells.clear();
    ensureWaterCells(state);

    for (final migrated in oldBoats) {
      final column = migrated.column + offsetQ;
      final row = migrated.row + offsetR;
      final preferred = row * width + column;
      final preferredTile = hexes[preferred];
      final candidates = [...state.waterCells]
        ..sort((a, b) {
          final aTile = state.hexes[a.tiles.first];
          final bTile = state.hexes[b.tiles.first];
          final aDistance = _hexDistanceStatic(
            aTile.q,
            aTile.r,
            preferredTile.q,
            preferredTile.r,
          );
          final bDistance = _hexDistanceStatic(
            bTile.q,
            bTile.r,
            preferredTile.q,
            preferredTile.r,
          );
          final preferredA = a.tiles.contains(preferred) ? -1 : aDistance;
          final preferredB = b.tiles.contains(preferred) ? -1 : bDistance;
          return preferredA.compareTo(preferredB);
        });
      final destination = candidates.cast<WaterCell?>().firstWhere(
        (cell) => cell!.navigable && cell.boat == null && cell.seaFort == null,
        orElse: () => null,
      );
      if (destination != null) destination.boat = migrated.boat;
    }
    for (final migrated in oldForts) {
      final column = migrated.column + offsetQ;
      final row = migrated.row + offsetR;
      final preferred = row * width + column;
      final preferredTile = hexes[preferred];
      final candidates = [...state.waterCells]
        ..sort((a, b) {
          final aTile = state.hexes[a.tiles.first];
          final bTile = state.hexes[b.tiles.first];
          return _hexDistanceStatic(
            aTile.q,
            aTile.r,
            preferredTile.q,
            preferredTile.r,
          ).compareTo(
            _hexDistanceStatic(
              bTile.q,
              bTile.r,
              preferredTile.q,
              preferredTile.r,
            ),
          );
        });
      final destination = candidates.cast<WaterCell?>().firstWhere(
        (cell) => cell!.navigable && cell.boat == null && cell.seaFort == null,
        orElse: () => null,
      );
      if (destination != null) destination.seaFort = migrated.fort;
    }
    for (final migrated in oldMints) {
      final preferred =
          (migrated.row + offsetR) * width + migrated.column + offsetQ;
      final destination = _nearestFreeNavigableWaterCell(
        state,
        preferred,
        preferredIndex: state.waterCells
            .where((cell) => cell.tiles.contains(preferred))
            .map((cell) => cell.index)
            .firstOrNull,
      );
      if (destination != null) destination.seaMint = true;
    }
    return true;
  }

  /// Creates the editor's clean canvas: the selected finite map-size frame is
  /// real water from edge to edge and contains no generated land or pieces.
  GameState createBlank(GameConfig config) {
    final dims = _dimensions[config.mapSize]!;
    final hexes = _createRectangularHexGrid(dims.$1, dims.$2, inWorld: true);
    _wireNeighbors(hexes);
    _markWorldArena(hexes, dims.$1, dims.$2);
    final rng = FastRandom(config.seed);
    final state = GameState(
      config: config,
      modId: mod.id,
      width: dims.$1,
      height: dims.$2,
      hexes: hexes,
      provinces: <Province>[],
      turn: 0,
      round: 1,
      rngState: rng.state,
      nextProvinceId: 1,
    );
    ensureWaterCells(state);
    return state;
  }

  GameState generate(GameConfig config) {
    final watch = Stopwatch()..start();
    void stage(String name) {
      if (const bool.fromEnvironment('ANTIYOY_GENERATION_TRACE')) {
        debugPrint('ANTIYOY_GENERATION $name ${watch.elapsedMilliseconds}ms');
      }
    }

    final dims = _dimensions[config.mapSize]!;
    final rng = FastRandom(config.seed);
    final classicRng = _JavaRandom(config.seed);
    final hexes = _createRectangularHexGrid(dims.$1, dims.$2, inWorld: false);
    _wireNeighbors(hexes);
    _markWorldArena(hexes, dims.$1, dims.$2);
    // Inland lakes are large enough to pack into at least three WaterCells.
    // This keeps them useful for ports and boats instead of making decorative
    // one-cell puddles. Extra land is grown first, then carved back out so the
    // configured land budget remains stable.
    final inlandLakeTiles = const [0, 0, 12, 15, 18][rng.nextInt(5)];
    _growLandMasses(
      hexes,
      dims.$3 + inlandLakeTiles,
      config.mapSize,
      classicRng,
    );
    stage('land');
    _removeClassicSingleHoles(hexes);
    _eliminateTinySeaPockets(
      hexes,
      dims.$3 + inlandLakeTiles,
      minimumWaterTiles: 12,
    );
    stage('coastRepair');
    final inlandWater = _carveInlandWater(hexes, inlandLakeTiles, rng);
    stage('lake');
    _eliminateTinySeaPockets(hexes, dims.$3, protectedWater: inlandWater);
    stage('coast');
    final state = GameState(
      config: config,
      modId: mod.id,
      width: dims.$1,
      height: dims.$2,
      hexes: hexes,
      provinces: [],
      turn: 0,
      round: 1,
      rngState: rng.state,
      nextProvinceId: 1,
    );
    ensureWaterCells(state);
    stage('water');
    _addTrees(state, config.treePercent, classicRng);
    stage('trees');
    if (config.slayRules) {
      _spawnSlayProvinces(state, classicRng);
    } else {
      _spawnPlayers(state, classicRng);
    }
    state.rngState = rng.state;
    stage('provinces');
    return state;
  }

  /// Packs the whole inactive lattice into connected three-hex sea regions.
  /// Triangle-shaped triples are preferred; unavoidable one/two-tile edge
  /// remainders are absorbed by a neighboring region instead of becoming
  /// tiny broken cells.
  static void ensureWaterCells(GameState state) {
    final inactive = state.hexes
        .where((tile) => tile.inWorld && !tile.active)
        .map((tile) => tile.index)
        .toSet();
    final existingTiles = state.waterCells.expand((cell) => cell.tiles).toSet();
    final existingTileCount = state.waterCells.fold<int>(
      0,
      (sum, cell) => sum + cell.tiles.length,
    );
    final isCurrentLayout =
        existingTileCount == inactive.length &&
        existingTiles.length == inactive.length &&
        existingTiles.containsAll(inactive) &&
        List<int>.generate(state.waterCells.length, (index) => index).every((
          index,
        ) {
          final cell = state.waterCells[index];
          return cell.index == index &&
              cell.tiles.length >= 3 &&
              cell.tiles.length <= 5 &&
              _waterTilesAreConnected(state, cell.tiles.toSet());
        });
    if (isCurrentLayout) {
      _markNavigableWaterBodies(state);
      _relocateBoatsFromSmallWater(state);
      return;
    }

    final boatsToMigrate = <({int tile, GameBoat boat})>[
      for (final cell in state.waterCells)
        if (cell.boat != null && cell.tiles.isNotEmpty)
          (tile: cell.tiles.first, boat: cell.boat!),
    ];
    final fortsToMigrate = <({int tile, SeaFort fort})>[
      for (final cell in state.waterCells)
        if (cell.seaFort != null && cell.tiles.isNotEmpty)
          (tile: cell.tiles.first, fort: cell.seaFort!),
    ];
    final mintsToMigrate = <int>[
      for (final cell in state.waterCells)
        if (cell.seaMint && cell.tiles.isNotEmpty) cell.tiles.first,
    ];
    state.waterCells.clear();
    final unassigned = SplayTreeSet<int>.of(
      state.hexes
          .where((tile) => tile.inWorld && !tile.active)
          .map((tile) => tile.index),
    );
    final tileToWater = <int, int>{};
    while (unassigned.length >= 3) {
      final members =
          _findWaterTriangle(state, unassigned) ??
          _findConnectedWaterTriple(state, unassigned);
      if (members == null) break;
      final cellIndex = state.waterCells.length;
      state.waterCells.add(WaterCell(index: cellIndex, tiles: members));
      for (final index in members) {
        unassigned.remove(index);
        tileToWater[index] = cellIndex;
      }
    }

    // Absorb remainders from the already packed edge inward. Processing a
    // frozen index order could accidentally create a two-hex region even when
    // its later neighbor already touched a valid triple.
    while (unassigned.isNotEmpty) {
      final attachable =
          unassigned
              .where(
                (tileIndex) => state.hexes[tileIndex].neighbors.any(
                  (neighbor) => tileToWater.containsKey(neighbor),
                ),
              )
              .toList()
            ..sort();
      final tileIndex = attachable.isNotEmpty
          ? attachable.first
          : (unassigned.toList()..sort()).first;
      final candidates =
          state.hexes[tileIndex].neighbors
              .map((neighbor) => tileToWater[neighbor])
              .whereType<int>()
              .where(
                (cellIndex) => state.waterCells[cellIndex].tiles.length < 5,
              )
              .toSet()
              .toList()
            ..sort((a, b) {
              final sizeOrder = state.waterCells[a].tiles.length.compareTo(
                state.waterCells[b].tiles.length,
              );
              return sizeOrder != 0 ? sizeOrder : a.compareTo(b);
            });
      if (candidates.isEmpty) {
        final cellIndex = state.waterCells.length;
        state.waterCells.add(WaterCell(index: cellIndex, tiles: [tileIndex]));
        tileToWater[tileIndex] = cellIndex;
      } else {
        final cellIndex = candidates.first;
        state.waterCells[cellIndex].tiles.add(tileIndex);
        tileToWater[tileIndex] = cellIndex;
      }
      unassigned.remove(tileIndex);
    }

    // Greedy triples can leave a one/two-tile tail behind a completely full
    // five-tile cell on an irregular Classic coastline. Repartition the two
    // touching groups instead of exposing an unusable one-cell sea region.
    // Every source water body was already repaired to at least twelve tiles,
    // so a small group always has a connected neighbour to absorb or split
    // with. The exhaustive split is tiny (at most seven tiles).
    final repairedGroups = _repairSmallWaterGroups(
      state,
      state.waterCells.map((cell) => [...cell.tiles]).toList(),
    );
    state.waterCells.clear();
    tileToWater.clear();
    for (final group in repairedGroups) {
      group.sort();
      final cellIndex = state.waterCells.length;
      state.waterCells.add(WaterCell(index: cellIndex, tiles: group));
      for (final tileIndex in group) {
        tileToWater[tileIndex] = cellIndex;
      }
    }

    for (final cell in state.waterCells) {
      final waterNeighbors = <int>{};
      final coast = <int>{};
      for (final tileIndex in cell.tiles) {
        for (final neighbor in state.hexes[tileIndex].neighbors) {
          if (state.hexes[neighbor].active) {
            coast.add(neighbor);
          } else if (state.hexes[neighbor].inWorld) {
            final other = tileToWater[neighbor];
            if (other != null && other != cell.index) waterNeighbors.add(other);
          }
        }
      }
      cell.neighbors.addAll(waterNeighbors.toList()..sort());
      cell.coastTiles.addAll(coast.toList()..sort());
    }

    _markNavigableWaterBodies(state);

    for (final migrated in boatsToMigrate) {
      final destination = _nearestFreeNavigableWaterCell(
        state,
        migrated.tile,
        preferredIndex: tileToWater[migrated.tile],
      );
      if (destination != null) destination.boat = migrated.boat;
    }
    for (final migrated in fortsToMigrate) {
      final destination = _nearestFreeNavigableWaterCell(
        state,
        migrated.tile,
        preferredIndex: tileToWater[migrated.tile],
      );
      if (destination != null) destination.seaFort = migrated.fort;
    }
    for (final tile in mintsToMigrate) {
      final destination = _nearestFreeNavigableWaterCell(
        state,
        tile,
        preferredIndex: tileToWater[tile],
      );
      if (destination != null) destination.seaMint = true;
    }
    _relocateBoatsFromSmallWater(state);
  }

  static List<List<int>> _repairSmallWaterGroups(
    GameState state,
    List<List<int>> source,
  ) {
    final groups = source.map((group) => group.toSet()).toList();
    var guard = math.max(1, groups.length * 4);
    while (guard-- > 0) {
      final smallIndex = groups.indexWhere((group) => group.length < 3);
      if (smallIndex < 0) break;
      final small = groups[smallIndex];
      final neighbors = <int>[];
      for (var index = 0; index < groups.length; index++) {
        if (index == smallIndex) continue;
        if (small.any(
          (tile) => state.hexes[tile].neighbors.any(groups[index].contains),
        )) {
          neighbors.add(index);
        }
      }
      neighbors.sort((a, b) {
        final sizeOrder = groups[a].length.compareTo(groups[b].length);
        return sizeOrder != 0 ? sizeOrder : a.compareTo(b);
      });

      var repaired = false;
      for (final neighborIndex in neighbors) {
        final combined = <int>{...small, ...groups[neighborIndex]};
        if (combined.length <= 5) {
          groups[neighborIndex] = combined;
          groups.removeAt(smallIndex);
          repaired = true;
          break;
        }
        final split = _splitConnectedWaterGroup(state, combined);
        if (split == null) continue;
        groups[smallIndex] = split.$1.toSet();
        groups[neighborIndex] = split.$2.toSet();
        repaired = true;
        break;
      }
      if (!repaired) {
        final selectedGroups = <int>{smallIndex};
        final combined = <int>{...small};
        while (combined.length <= 16) {
          final frontier = <int>[];
          for (var index = 0; index < groups.length; index++) {
            if (selectedGroups.contains(index)) continue;
            if (selectedGroups.any(
              (selected) => groups[selected].any(
                (tile) =>
                    state.hexes[tile].neighbors.any(groups[index].contains),
              ),
            )) {
              frontier.add(index);
            }
          }
          frontier.sort((a, b) {
            final sizeOrder = groups[a].length.compareTo(groups[b].length);
            return sizeOrder != 0 ? sizeOrder : a.compareTo(b);
          });
          final next = frontier.cast<int?>().firstWhere(
            (index) => combined.length + groups[index!].length <= 16,
            orElse: () => null,
          );
          if (next == null) break;
          selectedGroups.add(next);
          combined.addAll(groups[next]);
          final partition = _partitionConnectedWaterTiles(state, combined);
          if (partition == null) continue;

          final insertionIndex = selectedGroups.reduce(math.min);
          final removalOrder = selectedGroups.toList()
            ..sort((a, b) => b.compareTo(a));
          for (final index in removalOrder) {
            groups.removeAt(index);
          }
          groups.insertAll(
            insertionIndex,
            partition.map((part) => part.toSet()),
          );
          repaired = true;
          break;
        }
      }
      if (!repaired) break;
    }
    return [for (final group in groups) group.toList()];
  }

  static List<List<int>>? _partitionConnectedWaterTiles(
    GameState state,
    Set<int> source,
  ) {
    final failed = <String>{};

    List<Set<int>> componentsOf(Set<int> tiles) {
      final unseen = {...tiles};
      final result = <Set<int>>[];
      while (unseen.isNotEmpty) {
        final seed = unseen.reduce(math.min);
        final component = <int>{seed};
        final queue = <int>[seed];
        unseen.remove(seed);
        for (var cursor = 0; cursor < queue.length; cursor++) {
          for (final neighbor in state.hexes[queue[cursor]].neighbors) {
            if (unseen.remove(neighbor)) {
              component.add(neighbor);
              queue.add(neighbor);
            }
          }
        }
        result.add(component);
      }
      return result;
    }

    late List<List<int>>? Function(Set<int>) solve;
    solve = (remaining) {
      if (remaining.isEmpty) return <List<int>>[];
      final key = (remaining.toList()..sort()).join(',');
      if (failed.contains(key)) return null;
      if (remaining.length < 3) {
        failed.add(key);
        return null;
      }

      final components = componentsOf(remaining);
      if (components.length > 1) {
        final result = <List<int>>[];
        for (final component in components) {
          final partition = solve(component);
          if (partition == null) {
            failed.add(key);
            return null;
          }
          result.addAll(partition);
        }
        return result;
      }
      if (remaining.length <= 5) {
        return [(remaining.toList()..sort())];
      }

      final anchor = remaining.reduce(math.min);
      final visitedGroups = <String>{};

      List<List<int>>? grow(Set<int> group) {
        final groupKey = (group.toList()..sort()).join(',');
        if (!visitedGroups.add(groupKey)) return null;
        if (group.length >= 3) {
          final rest = remaining.difference(group);
          final restComponents = componentsOf(rest);
          if (restComponents.every((component) => component.length >= 3)) {
            final tail = solve(rest);
            if (tail != null) {
              return [(group.toList()..sort()), ...tail];
            }
          }
        }
        if (group.length == 5) return null;
        final frontier =
            group
                .expand((index) => state.hexes[index].neighbors)
                .where(
                  (index) =>
                      remaining.contains(index) && !group.contains(index),
                )
                .toSet()
                .toList()
              ..sort();
        for (final next in frontier) {
          final result = grow(<int>{...group, next});
          if (result != null) return result;
        }
        return null;
      }

      final result = grow(<int>{anchor});
      if (result == null) failed.add(key);
      return result;
    };

    return solve({...source});
  }

  static (List<int>, List<int>)? _splitConnectedWaterGroup(
    GameState state,
    Set<int> combined,
  ) {
    final tiles = combined.toList()..sort();
    if (tiles.length < 6 || tiles.length > 10) return null;
    final combinations = 1 << tiles.length;
    for (var mask = 1; mask < combinations - 1; mask++) {
      // Fix the first tile in the first half to avoid checking mirrored cuts.
      if (mask & 1 == 0) continue;
      final first = <int>[];
      final second = <int>[];
      for (var index = 0; index < tiles.length; index++) {
        ((mask & (1 << index)) != 0 ? first : second).add(tiles[index]);
      }
      if (first.length < 3 || first.length > 5) continue;
      if (second.length < 3 || second.length > 5) continue;
      if (!_waterTilesAreConnected(state, first.toSet()) ||
          !_waterTilesAreConnected(state, second.toSet())) {
        continue;
      }
      return (first, second);
    }
    return null;
  }

  static bool _waterTilesAreConnected(GameState state, Set<int> tiles) {
    if (tiles.isEmpty) return false;
    final remaining = {...tiles};
    final queue = <int>[remaining.first];
    remaining.remove(queue.first);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      for (final neighbor in state.hexes[queue[cursor]].neighbors) {
        if (remaining.remove(neighbor)) queue.add(neighbor);
      }
    }
    return remaining.isEmpty;
  }

  static void _markNavigableWaterBodies(GameState state) {
    final unseen = state.waterCells.map((cell) => cell.index).toSet();
    while (unseen.isNotEmpty) {
      final seed = unseen.first;
      final component = <int>[];
      final queue = <int>[seed];
      unseen.remove(seed);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        component.add(index);
        for (final neighbor in state.waterCells[index].neighbors) {
          if (unseen.remove(neighbor)) queue.add(neighbor);
        }
      }
      final navigable = component.length >= 3;
      for (final index in component) {
        state.waterCells[index].navigable = navigable;
      }
    }
  }

  static void _relocateBoatsFromSmallWater(GameState state) {
    final stranded = <({int tile, GameBoat boat})>[];
    for (final cell in state.waterCells.where((cell) => !cell.navigable)) {
      if (cell.boat == null) continue;
      stranded.add((tile: cell.tiles.first, boat: cell.boat!));
      cell.boat = null;
    }
    for (final item in stranded) {
      final destination = _nearestFreeNavigableWaterCell(state, item.tile);
      if (destination != null) destination.boat = item.boat;
    }
    final strandedForts = <({int tile, SeaFort fort})>[];
    for (final cell in state.waterCells.where((cell) => !cell.navigable)) {
      if (cell.seaFort == null) continue;
      strandedForts.add((tile: cell.tiles.first, fort: cell.seaFort!));
      cell.seaFort = null;
    }
    for (final item in strandedForts) {
      final destination = _nearestFreeNavigableWaterCell(state, item.tile);
      if (destination != null) destination.seaFort = item.fort;
    }
    final strandedMints = <int>[];
    for (final cell in state.waterCells.where((cell) => !cell.navigable)) {
      if (!cell.seaMint) continue;
      strandedMints.add(cell.tiles.first);
      cell.seaMint = false;
    }
    for (final tile in strandedMints) {
      final destination = _nearestFreeNavigableWaterCell(state, tile);
      if (destination != null) destination.seaMint = true;
    }
  }

  /// Finds the closest usable destination across the complete navigable water
  /// graph. Repacking can map several legacy cells onto one new cell, so looking
  /// only at that cell and its immediate neighbours can silently lose a boat or
  /// fort even though a free destination exists farther away.
  static WaterCell? _nearestFreeNavigableWaterCell(
    GameState state,
    int sourceTile, {
    int? preferredIndex,
  }) {
    if (sourceTile < 0 || sourceTile >= state.hexes.length) return null;
    final source = state.hexes[sourceTile];
    final candidates = state.waterCells
        .where(
          (cell) =>
              cell.navigable &&
              cell.tiles.isNotEmpty &&
              cell.boat == null &&
              cell.seaFort == null &&
              !cell.seaMint,
        )
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final preferredA = a.index == preferredIndex ? 0 : 1;
      final preferredB = b.index == preferredIndex ? 0 : 1;
      final preferredOrder = preferredA.compareTo(preferredB);
      if (preferredOrder != 0) return preferredOrder;
      final aDistance = a.tiles
          .map((index) {
            final tile = state.hexes[index];
            return _hexDistanceStatic(source.q, source.r, tile.q, tile.r);
          })
          .reduce(math.min);
      final bDistance = b.tiles
          .map((index) {
            final tile = state.hexes[index];
            return _hexDistanceStatic(source.q, source.r, tile.q, tile.r);
          })
          .reduce(math.min);
      final distanceOrder = aDistance.compareTo(bDistance);
      return distanceOrder != 0 ? distanceOrder : a.index.compareTo(b.index);
    });
    return candidates.first;
  }

  static List<int>? _findWaterTriangle(
    GameState state,
    SplayTreeSet<int> unassigned,
  ) {
    for (final seed in unassigned) {
      final neighbors =
          state.hexes[seed].neighbors.where(unassigned.contains).toList()
            ..sort();
      for (var a = 0; a < neighbors.length; a++) {
        for (var b = a + 1; b < neighbors.length; b++) {
          if (state.hexes[neighbors[a]].neighbors.contains(neighbors[b])) {
            return [seed, neighbors[a], neighbors[b]];
          }
        }
      }
    }
    return null;
  }

  static List<int>? _findConnectedWaterTriple(
    GameState state,
    SplayTreeSet<int> unassigned,
  ) {
    for (final seed in unassigned) {
      final firstNeighbors =
          state.hexes[seed].neighbors.where(unassigned.contains).toList()
            ..sort();
      for (final first in firstNeighbors) {
        final secondNeighbors =
            state.hexes[first].neighbors
                .where((index) => index != seed && unassigned.contains(index))
                .toList()
              ..sort();
        if (secondNeighbors.isNotEmpty) {
          return [seed, first, secondNeighbors.first];
        }
      }
    }
    return null;
  }

  /// Builds a pointy-top axial grid whose rendered outline is rectangular.
  ///
  /// [HexTile.q]/[HexTile.r] stay true axial coordinates so distance and
  /// combat algorithms remain unchanged. Only the row-to-axial conversion is
  /// offset; this prevents a width×height map from being drawn as a rhombus.
  static List<HexTile> _createRectangularHexGrid(
    int width,
    int height, {
    required bool inWorld,
  }) => <HexTile>[
    for (var row = 0; row < height; row++)
      for (var column = 0; column < width; column++)
        HexTile(
          index: row * width + column,
          q: column,
          r: row - (column ~/ 2),
          inWorld: inWorld,
        ),
  ];

  static void _wireNeighbors(List<HexTile> hexes) {
    const directions = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];
    final byCoordinate = <(int, int), int>{
      for (final tile in hexes) (tile.q, tile.r): tile.index,
    };
    for (final tile in hexes) {
      for (final direction in directions) {
        final q = tile.q + direction.$1;
        final r = tile.r + direction.$2;
        final neighbor = byCoordinate[(q, r)];
        if (neighbor != null) tile.neighbors.add(neighbor);
      }
    }
  }

  void _growLandMasses(
    List<HexTile> hexes,
    int target,
    MapSize mapSize,
    _JavaRandom rng,
  ) {
    final worldTiles = hexes.where((tile) => tile.inWorld).toList();
    if (worldTiles.isEmpty) return;
    final landTarget = math.min(target, worldTiles.length);

    // Classic MapGenerator.createLand: make several potential-7 islands,
    // connect every centre to its closest unlinked neighbour with potential-2
    // roads, repair any remaining disconnected groups, then centre the result.
    // The Java generator only requires >25% land. The Flutter state has a fixed
    // per-size land budget, an axial arena and later naval carving, so the final
    // coast-only grow/trim pass preserves the local contract. The broad phase
    // order mirrors Classic; topology and per-seed tile signatures cannot be
    // identical across the two coordinate/state models.
    final seedCount = math.min(worldTiles.length, switch (mapSize) {
      MapSize.small => 2,
      MapSize.medium => 4,
      MapSize.large => 20,
      MapSize.huge => 35,
      MapSize.giant => 45,
    });
    final seeds = _chooseClassicIslandSeeds(hexes, worldTiles, seedCount, rng);
    for (final seed in seeds) {
      _spawnClassicIsland(hexes, seed.index, 7, rng);
    }
    _uniteClassicIslandCenters(hexes, seeds, rng);
    _repairClassicLandConnectivity(hexes, rng);
    _fitClassicLandBudget(hexes, landTarget, rng);
    _centerClassicLand(hexes);
  }

  List<HexTile> _chooseClassicIslandSeeds(
    List<HexTile> hexes,
    List<HexTile> worldTiles,
    int count,
    _JavaRandom rng,
  ) {
    final eligible = worldTiles
        .where(
          (tile) =>
              tile.neighbors.where((index) => hexes[index].inWorld).length >= 5,
        )
        .toList();
    final pool = [...(eligible.length >= count ? eligible : worldTiles)];
    final seeds = <HexTile>[];
    while (seeds.length < count && pool.isNotEmpty) {
      seeds.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    return seeds;
  }

  void _spawnClassicIsland(
    List<HexTile> hexes,
    int start,
    int potential,
    _JavaRandom rng,
  ) {
    final queue = <({int index, int potential})>[
      (index: start, potential: potential),
    ];
    final queued = <int>{start};
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      if (rng.nextInt(potential) > current.potential) continue;
      final tile = hexes[current.index];
      if (!tile.inWorld) continue;
      final activated = !tile.active;
      tile.active = true;
      if (!activated || current.potential == 0) continue;
      for (final neighbor in tile.neighbors) {
        if (!hexes[neighbor].inWorld || !queued.add(neighbor)) continue;
        queue.add((index: neighbor, potential: current.potential - 1));
      }
    }
  }

  void _uniteClassicIslandCenters(
    List<HexTile> hexes,
    List<HexTile> seeds,
    _JavaRandom rng,
  ) {
    final links = <String>{};
    for (var first = 0; first < seeds.length; first++) {
      int? closest;
      var closestDistance = 1 << 30;
      for (var second = 0; second < seeds.length; second++) {
        if (first == second) continue;
        final key = first < second ? '$first:$second' : '$second:$first';
        if (links.contains(key)) continue;
        final distance = _hexDistanceStatic(
          seeds[first].q,
          seeds[first].r,
          seeds[second].q,
          seeds[second].r,
        );
        if (distance >= closestDistance) continue;
        closest = second;
        closestDistance = distance;
      }
      if (closest == null) continue;
      final key = first < closest ? '$first:$closest' : '$closest:$first';
      links.add(key);
      for (final index in _shortestWorldPath(
        hexes,
        seeds[first].index,
        seeds[closest].index,
      )) {
        _spawnClassicIsland(hexes, index, 2, rng);
      }
    }
  }

  void _repairClassicLandConnectivity(List<HexTile> hexes, _JavaRandom rng) {
    while (true) {
      final components = _activeLandComponents(hexes);
      if (components.length <= 1) return;
      List<int>? bestFirst;
      List<int>? bestSecond;
      var bestFirstTile = -1;
      var bestSecondTile = -1;
      var bestDistance = 1 << 30;
      for (var first = 0; first < components.length; first++) {
        for (var second = first + 1; second < components.length; second++) {
          for (final a in components[first]) {
            for (final b in components[second]) {
              final distance = _hexDistanceStatic(
                hexes[a].q,
                hexes[a].r,
                hexes[b].q,
                hexes[b].r,
              );
              if (distance >= bestDistance) continue;
              bestDistance = distance;
              bestFirst = components[first];
              bestSecond = components[second];
              bestFirstTile = a;
              bestSecondTile = b;
            }
          }
        }
      }
      if (bestFirst == null || bestSecond == null) return;
      for (final index in _shortestWorldPath(
        hexes,
        bestFirstTile,
        bestSecondTile,
      )) {
        _spawnClassicIsland(hexes, index, 2, rng);
      }
    }
  }

  void _fitClassicLandBudget(List<HexTile> hexes, int target, _JavaRandom rng) {
    while (hexes.where((tile) => tile.active).length < target) {
      final frontier =
          hexes
              .where(
                (tile) =>
                    tile.inWorld &&
                    !tile.active &&
                    tile.neighbors.any((neighbor) => hexes[neighbor].active),
              )
              .toList()
            ..sort((a, b) {
              final aFriends = a.neighbors
                  .where((neighbor) => hexes[neighbor].active)
                  .length;
              final bFriends = b.neighbors
                  .where((neighbor) => hexes[neighbor].active)
                  .length;
              final friendOrder = bFriends.compareTo(aFriends);
              return friendOrder != 0
                  ? friendOrder
                  : a.index.compareTo(b.index);
            });
      if (frontier.isEmpty) break;
      final band = math.min(8, frontier.length);
      frontier[rng.nextInt(band)].active = true;
    }

    while (hexes.where((tile) => tile.active).length > target) {
      final coast =
          hexes
              .where(
                (tile) =>
                    tile.active &&
                    tile.neighbors.any(
                      (neighbor) =>
                          hexes[neighbor].inWorld && !hexes[neighbor].active,
                    ),
              )
              .toList()
            ..sort((a, b) {
              final aFriends = a.neighbors
                  .where((neighbor) => hexes[neighbor].active)
                  .length;
              final bFriends = b.neighbors
                  .where((neighbor) => hexes[neighbor].active)
                  .length;
              final friendOrder = aFriends.compareTo(bFriends);
              return friendOrder != 0
                  ? friendOrder
                  : a.index.compareTo(b.index);
            });
      if (coast.isEmpty) break;
      final offset = rng.nextInt(math.min(8, coast.length));
      var removed = false;
      for (var step = 0; step < coast.length; step++) {
        final candidate = coast[(offset + step) % coast.length];
        candidate.active = false;
        if (_activeLandComponentCount(hexes) == 1 &&
            _inactiveWaterHasMinimumSize(hexes, 3)) {
          removed = true;
          break;
        }
        candidate.active = true;
      }
      if (!removed) break;
    }
  }

  List<List<int>> _activeLandComponents(List<HexTile> hexes) {
    final unseen = hexes
        .where((tile) => tile.active)
        .map((tile) => tile.index)
        .toSet();
    final result = <List<int>>[];
    while (unseen.isNotEmpty) {
      final queue = <int>[unseen.first];
      final component = <int>[];
      unseen.remove(queue.first);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        component.add(index);
        for (final neighbor in hexes[index].neighbors) {
          if (hexes[neighbor].active && unseen.remove(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      result.add(component);
    }
    return result;
  }

  void _centerClassicLand(List<HexTile> hexes) {
    final active = hexes.where((tile) => tile.active).toList();
    final world = hexes.where((tile) => tile.inWorld).toList();
    if (active.isEmpty || world.isEmpty) return;
    final activeMidQ =
        (active.map((tile) => tile.q).reduce(math.min) +
            active.map((tile) => tile.q).reduce(math.max)) ~/
        2;
    final activeMidR =
        (active.map((tile) => tile.r).reduce(math.min) +
            active.map((tile) => tile.r).reduce(math.max)) ~/
        2;
    final worldMidQ =
        (world.map((tile) => tile.q).reduce(math.min) +
            world.map((tile) => tile.q).reduce(math.max)) ~/
        2;
    final worldMidR =
        (world.map((tile) => tile.r).reduce(math.min) +
            world.map((tile) => tile.r).reduce(math.max)) ~/
        2;
    final deltaQ = worldMidQ - activeMidQ;
    final deltaR = worldMidR - activeMidR;
    if (deltaQ == 0 && deltaR == 0) return;
    final byCoordinate = <String, HexTile>{
      for (final tile in hexes) '${tile.q}:${tile.r}': tile,
    };
    final destinations = <HexTile>[];
    for (final source in active) {
      final destination =
          byCoordinate['${source.q + deltaQ}:${source.r + deltaR}'];
      if (destination == null || !destination.inWorld) return;
      destinations.add(destination);
    }
    for (final tile in active) {
      tile.active = false;
    }
    for (final tile in destinations) {
      tile.active = true;
    }
  }

  List<int> _shortestWorldPath(List<HexTile> hexes, int start, int finish) {
    final previous = <int, int>{};
    final seen = <int>{start};
    final queue = <int>[start];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      if (index == finish) break;
      final neighbors =
          hexes[index].neighbors
              .where((neighbor) => hexes[neighbor].inWorld)
              .toList()
            ..sort((a, b) {
              final target = hexes[finish];
              final distanceOrder =
                  _hexDistanceStatic(
                    hexes[a].q,
                    hexes[a].r,
                    target.q,
                    target.r,
                  ).compareTo(
                    _hexDistanceStatic(
                      hexes[b].q,
                      hexes[b].r,
                      target.q,
                      target.r,
                    ),
                  );
              return distanceOrder != 0 ? distanceOrder : a.compareTo(b);
            });
      for (final neighbor in neighbors) {
        if (!seen.add(neighbor)) continue;
        previous[neighbor] = index;
        queue.add(neighbor);
      }
    }
    if (!seen.contains(finish)) return [start, finish];
    final result = <int>[finish];
    var current = finish;
    while (current != start) {
      current = previous[current]!;
      result.add(current);
    }
    return result.reversed.toList(growable: false);
  }

  static void _markWorldArena(List<HexTile> hexes, int width, int height) {
    // Classic lets the editor use the complete size-dependent level bounds.
    // Every lattice cell inside that finite frame is therefore real water or
    // land; no hidden rounded mask steals editable space near the edges.
    for (final tile in hexes) {
      tile.inWorld = true;
    }
  }

  static int _hexDistanceStatic(int aq, int ar, int bq, int br) {
    final dq = aq - bq;
    final dr = ar - br;
    return (dq.abs() + dr.abs() + (dq + dr).abs()) ~/ 2;
  }

  void _removeClassicSingleHoles(List<HexTile> hexes) {
    final holes = hexes.where(
      (tile) =>
          tile.inWorld &&
          !tile.active &&
          tile.neighbors.length == 6 &&
          tile.neighbors.every((neighbor) => hexes[neighbor].active),
    );
    for (final hole in holes) {
      hole.active = true;
    }
  }

  void _eliminateTinySeaPockets(
    List<HexTile> hexes,
    int targetLand, {
    Set<int> protectedWater = const <int>{},
    int minimumWaterTiles = 3,
  }) {
    final inactiveComponents = <List<int>>[];
    final unseen = hexes
        .where((tile) => tile.inWorld && !tile.active)
        .map((tile) => tile.index)
        .toSet();
    while (unseen.isNotEmpty) {
      final seed = unseen.first;
      final component = <int>[];
      final queue = <int>[seed];
      unseen.remove(seed);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        component.add(index);
        for (final neighbor in hexes[index].neighbors) {
          if (hexes[neighbor].inWorld &&
              !hexes[neighbor].active &&
              unseen.remove(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      inactiveComponents.add(component);
    }
    final tiny = inactiveComponents
        .where((component) => component.length < minimumWaterTiles)
        .expand((component) => component)
        .toList();
    for (final index in tiny) {
      hexes[index].active = true;
    }

    final friends = [
      for (final tile in hexes)
        tile.neighbors.where((i) => hexes[i].active).length,
    ];
    bool eligible(HexTile tile) =>
        tile.active &&
        !tile.neighbors.any(protectedWater.contains) &&
        tile.neighbors.any((i) => hexes[i].inWorld && !hexes[i].active);
    final coast = SplayTreeSet<int>((a, b) {
      final order = friends[a].compareTo(friends[b]);
      return order != 0 ? order : a.compareTo(b);
    })..addAll(hexes.where(eligible).map((t) => t.index));
    var land = hexes.where((t) => t.active).length;
    while (land > targetLand && coast.isNotEmpty) {
      final index = coast.first;
      coast.remove(index);
      final candidate = hexes[index];
      // A rejected articulation stays an articulation until one of its
      // incident branches disappears. Revisit it when a neighbor is removed.
      if (!_removalPreservesLandComponents(hexes, candidate)) continue;
      for (final neighbor in candidate.neighbors) {
        coast.remove(neighbor); // remove before changing the ordering key
      }
      candidate.active = false;
      land--;
      for (final neighbor in candidate.neighbors) {
        friends[neighbor]--;
        if (eligible(hexes[neighbor])) coast.add(neighbor);
      }
      // The new water cell touches a valid water body: adding it can only
      // enlarge/merge water, never create a one-cell pocket.
    }
  }

  bool _removalPreservesLandComponents(List<HexTile> hexes, HexTile removed) {
    final pending = removed.neighbors.where((i) => hexes[i].active).toSet();
    if (pending.isEmpty) return false;
    final start = pending.first;
    pending.remove(start);
    if (pending.isEmpty) return true;
    final seen = <int>{removed.index, start};
    final queue = <int>[start];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      for (final next in hexes[queue[cursor]].neighbors) {
        if (!hexes[next].active || !seen.add(next)) continue;
        pending.remove(next);
        if (pending.isEmpty) return true;
        queue.add(next);
      }
    }
    return false;
  }

  int _activeLandComponentCount(List<HexTile> hexes) {
    final unseen = hexes
        .where((tile) => tile.active)
        .map((tile) => tile.index)
        .toSet();
    var count = 0;
    while (unseen.isNotEmpty) {
      count++;
      final seed = unseen.first;
      final queue = <int>[seed];
      unseen.remove(seed);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        for (final neighbor in hexes[queue[cursor]].neighbors) {
          if (hexes[neighbor].active && unseen.remove(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
    }
    return count;
  }

  bool _inactiveWaterHasMinimumSize(List<HexTile> hexes, int minimum) {
    final unseen = hexes
        .where((tile) => tile.inWorld && !tile.active)
        .map((tile) => tile.index)
        .toSet();
    while (unseen.isNotEmpty) {
      final seed = unseen.first;
      var size = 0;
      final queue = <int>[seed];
      unseen.remove(seed);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        size++;
        for (final neighbor in hexes[queue[cursor]].neighbors) {
          if (hexes[neighbor].inWorld &&
              !hexes[neighbor].active &&
              unseen.remove(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      if (size < minimum) return false;
    }
    return true;
  }

  Set<int> _carveInlandWater(
    List<HexTile> hexes,
    int tileCount,
    FastRandom rng,
  ) {
    if (tileCount < 3) return const <int>{};
    final deepLand = hexes.where((tile) {
      if (!tile.active || tile.neighbors.length != 6) return false;
      return tile.neighbors.every((neighbor) {
        final nearby = hexes[neighbor];
        return nearby.active &&
            nearby.neighbors.every((second) => hexes[second].active);
      });
    }).toList();
    if (deepLand.length < tileCount) return const <int>{};
    final deepLandIndexes = deepLand.map((tile) => tile.index).toSet();

    for (var attempt = 0; attempt < deepLand.length; attempt++) {
      final start =
          deepLand[(rng.nextInt(deepLand.length) + attempt) % deepLand.length];
      final chosen = <int>{start.index};
      final frontier = <int>{
        ...start.neighbors.where(deepLandIndexes.contains),
      };
      while (chosen.length < tileCount && frontier.isNotEmpty) {
        final candidates = frontier.toList()..sort();
        final next = candidates[rng.nextInt(candidates.length)];
        frontier.remove(next);
        if (!chosen.add(next)) continue;
        frontier.addAll(
          hexes[next].neighbors.where(
            (index) =>
                !chosen.contains(index) && deepLandIndexes.contains(index),
          ),
        );
      }
      if (chosen.length != tileCount) continue;
      final componentsBefore = _activeLandComponentCount(hexes);
      for (final index in chosen) {
        hexes[index].active = false;
      }
      if (_activeLandComponentCount(hexes) == componentsBefore) return chosen;
      for (final index in chosen) {
        hexes[index].active = true;
      }
    }
    return const <int>{};
  }

  void _addTrees(GameState state, int percentage, _JavaRandom rng) {
    final navigableCoast = state.waterCells
        .where((cell) => cell.navigable)
        .expand((cell) => cell.coastTiles)
        .toSet();
    for (final tile in state.hexes) {
      if (!tile.active || rng.nextInt(100) >= percentage) continue;
      final isCoastal = navigableCoast.contains(tile.index);
      tile.object = isCoastal ? TileObject.palm : TileObject.pine;
      tile.treeBorn = -1;
    }
  }

  /// Original Antiyoy Slay starts with the entire island divided between the
  /// chosen colours. Every connected kingdom is deliberately small (at most
  /// five hexes), a one-hex fragment has no economy, and every component of two
  /// or more hexes receives its own city and ten-coin treasury.
  void _spawnSlayProvinces(GameState state, _JavaRandom rng) {
    final active = state.hexes.where((tile) => tile.active).toList();
    if (active.isEmpty || state.config.playerCount <= 0) return;

    for (final tile in active) {
      tile
        ..owner = -1
        ..unit = null;
    }

    final playerCount = state.config.playerCount;
    final targetCounts = List<int>.filled(
      playerCount,
      active.length ~/ playerCount,
    );
    for (var owner = 0; owner < active.length % playerCount; owner++) {
      targetCounts[owner]++;
    }
    final assignedCounts = List<int>.filled(playerCount, 0);
    final seedCenters = <HexTile>[];

    // Give every colour a real province first. Farthest-pair sampling keeps
    // those guaranteed starts spread around the island instead of clustering.
    for (var owner = 0; owner < playerCount; owner++) {
      final pairs = <({HexTile first, HexTile second, int distance})>[];
      for (final tile in active) {
        if (tile.owner >= 0) continue;
        for (final neighborIndex in tile.neighbors) {
          final neighbor = state.hexes[neighborIndex];
          if (!neighbor.active ||
              neighbor.owner >= 0 ||
              neighbor.index < tile.index) {
            continue;
          }
          final distance = seedCenters.isEmpty
              ? _distanceToCenter(tile, state)
              : seedCenters
                    .map((seed) => _hexDistance(tile.q, tile.r, seed.q, seed.r))
                    .reduce(math.min);
          pairs.add((first: tile, second: neighbor, distance: distance));
        }
      }
      if (pairs.isEmpty) break;
      pairs.sort((a, b) => b.distance.compareTo(a.distance));
      final band = math.min(5, pairs.length);
      final pair = pairs[rng.nextInt(band)];
      pair.first.owner = owner;
      pair.second.owner = owner;
      assignedCounts[owner] = 2;
      seedCenters.add(pair.first);
    }

    final remaining = active.where((tile) => tile.owner < 0).toList();
    _shuffleSlayTiles(remaining, rng);
    for (final tile in remaining) {
      final tieBreakers = <int, int>{
        for (var owner = 0; owner < playerCount; owner++)
          owner: rng.nextInt(1 << 30),
      };
      final candidates = List<int>.generate(playerCount, (owner) => owner)
        ..sort((a, b) {
          final aNeed = targetCounts[a] - assignedCounts[a];
          final bNeed = targetCounts[b] - assignedCounts[b];
          final needOrder = bNeed.compareTo(aNeed);
          return needOrder != 0
              ? needOrder
              : tieBreakers[a]!.compareTo(tieBreakers[b]!);
        });
      final owner = candidates.firstWhere(
        (candidate) =>
            _slayMergedComponentSize(state, tile.index, candidate) <= 5,
        orElse: () => candidates.first,
      );
      tile.owner = owner;
      assignedCounts[owner]++;
    }

    _enforceSlayProvinceLimit(state, targetCounts, assignedCounts, rng);
    _balanceSlayProvinceCounts(state, assignedCounts);
    _enforceSlayProvinceLimit(state, targetCounts, assignedCounts, rng);

    final seen = <int>{};
    for (final tile in active) {
      if (!seen.add(tile.index)) continue;
      if (tile.owner < 0) continue;
      final component = <int>[];
      final queue = <int>[tile.index];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        component.add(index);
        for (final neighbor in state.hexes[index].neighbors) {
          if (state.hexes[neighbor].active &&
              state.hexes[neighbor].owner == tile.owner &&
              seen.add(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      if (component.length < 2) continue;
      final free = component
          .where((index) => state.hexes[index].object == TileObject.none)
          .toList();
      final choices = free.isEmpty ? component : free;
      final capital = choices[rng.nextInt(choices.length)];
      state.hexes[capital]
        ..object = TileObject.town
        ..unit = null
        ..treeBorn = -1;
      state.provinces.add(
        Province(
          id: state.nextProvinceId++,
          owner: tile.owner,
          tiles: component,
          money: mod.rules.initialMoney,
          capital: capital,
        ),
      );
    }
  }

  void _balanceSlayProvinceCounts(GameState state, List<int> assignedCounts) {
    // Classic achieveFairNumberOfProvincesForEveryPlayer transfers complete
    // real provinces until the largest/smallest counts differ by at most one.
    // The same 50-step limit is retained. A transfer may touch a one-hex
    // fragment, but never merges into a 6+ component (the mod's hard Slay cap).
    for (var iteration = 0; iteration < 50; iteration++) {
      final components = _slayOwnerComponents(
        state,
      ).where((component) => component.tiles.length >= 2).toList();
      final counts = List<int>.filled(state.config.playerCount, 0);
      for (final component in components) {
        counts[component.owner]++;
      }
      final maxCount = counts.reduce(math.max);
      final minCount = counts.reduce(math.min);
      if (maxCount - minCount <= 1) return;
      final donor = counts.indexOf(maxCount);
      final recipient = counts.indexOf(minCount);
      final candidates =
          components.where((component) => component.owner == donor).toList()
            ..sort((a, b) => a.tiles.length.compareTo(b.tiles.length));
      final transferable = candidates
          .cast<({int owner, List<int> tiles})?>()
          .firstWhere(
            (component) =>
                _canTransferSlayProvince(state, component!.tiles, recipient),
            orElse: () => null,
          );
      if (transferable == null) return;
      for (final index in transferable.tiles) {
        state.hexes[index].owner = recipient;
      }
      assignedCounts[donor] -= transferable.tiles.length;
      assignedCounts[recipient] += transferable.tiles.length;
    }
  }

  bool _canTransferSlayProvince(
    GameState state,
    List<int> province,
    int recipient,
  ) {
    final adjacentRecipient = <int>{};
    for (final index in province) {
      for (final neighbor in state.hexes[index].neighbors) {
        if (state.hexes[neighbor].active &&
            state.hexes[neighbor].owner == recipient) {
          adjacentRecipient.add(neighbor);
        }
      }
    }
    if (adjacentRecipient.isEmpty) return true;
    final connectedRecipient = <int>{};
    final queue = <int>[...adjacentRecipient];
    connectedRecipient.addAll(queue);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      for (final neighbor in state.hexes[queue[cursor]].neighbors) {
        if (state.hexes[neighbor].active &&
            state.hexes[neighbor].owner == recipient &&
            connectedRecipient.add(neighbor)) {
          queue.add(neighbor);
        }
      }
    }
    return province.length + connectedRecipient.length <= 5;
  }

  List<({int owner, List<int> tiles})> _slayOwnerComponents(GameState state) {
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

  void _enforceSlayProvinceLimit(
    GameState state,
    List<int> targetCounts,
    List<int> assignedCounts,
    _JavaRandom rng,
  ) {
    // The greedy assignment above normally keeps components small. This pass
    // is the hard guarantee: moving an edge tile to a component of at most five
    // strictly reduces the total oversized area. Neutral is only a last-resort
    // separator and is filled back whenever a legal owner exists.
    while (true) {
      final oversized = _firstOversizedSlayComponent(state);
      if (oversized == null) break;
      final sourceOwner = state.hexes[oversized.first].owner;
      final tieBreakers = <int, int>{
        for (final index in oversized) index: rng.nextInt(1 << 30),
      };
      final cutCandidates = [...oversized]
        ..sort((a, b) {
          final aSame = state.hexes[a].neighbors
              .where((neighbor) => state.hexes[neighbor].owner == sourceOwner)
              .length;
          final bSame = state.hexes[b].neighbors
              .where((neighbor) => state.hexes[neighbor].owner == sourceOwner)
              .length;
          final edgeOrder = aSame.compareTo(bSame);
          return edgeOrder != 0
              ? edgeOrder
              : tieBreakers[a]!.compareTo(tieBreakers[b]!);
        });
      var reassigned = false;
      for (final tileIndex in cutCandidates) {
        final ownerNoise = <int, int>{
          for (var owner = 0; owner < state.config.playerCount; owner++)
            owner: rng.nextInt(1 << 30),
        };
        final owners =
            List<int>.generate(state.config.playerCount, (owner) => owner)
              ..sort((a, b) {
                final aNeed = targetCounts[a] - assignedCounts[a];
                final bNeed = targetCounts[b] - assignedCounts[b];
                final needOrder = bNeed.compareTo(aNeed);
                return needOrder != 0
                    ? needOrder
                    : ownerNoise[a]!.compareTo(ownerNoise[b]!);
              });
        final destination = owners.cast<int?>().firstWhere(
          (owner) =>
              owner != sourceOwner &&
              _slayMergedComponentSize(state, tileIndex, owner!) <= 5,
          orElse: () => null,
        );
        if (destination == null) continue;
        state.hexes[tileIndex].owner = destination;
        assignedCounts[sourceOwner]--;
        assignedCounts[destination]++;
        reassigned = true;
        break;
      }
      if (reassigned) continue;

      // With only one usable color or a completely surrounded component there
      // may be no safe recipient. A one-cell neutral cut still guarantees that
      // no 6+ province survives; the refill pass below normally reclaims it.
      final separator = cutCandidates.first;
      state.hexes[separator].owner = -1;
      assignedCounts[sourceOwner]--;
    }

    final neutral =
        state.hexes
            .where((tile) => tile.active && tile.owner < 0)
            .map((tile) => tile.index)
            .toList()
          ..sort();
    for (final tileIndex in neutral) {
      final owners =
          List<int>.generate(state.config.playerCount, (owner) => owner)
            ..sort((a, b) {
              final aNeed = targetCounts[a] - assignedCounts[a];
              final bNeed = targetCounts[b] - assignedCounts[b];
              final needOrder = bNeed.compareTo(aNeed);
              return needOrder != 0 ? needOrder : a.compareTo(b);
            });
      final destination = owners.cast<int?>().firstWhere(
        (owner) => _slayMergedComponentSize(state, tileIndex, owner!) <= 5,
        orElse: () => null,
      );
      if (destination == null) continue;
      state.hexes[tileIndex].owner = destination;
      assignedCounts[destination]++;
    }
  }

  List<int>? _firstOversizedSlayComponent(GameState state) {
    final unseen = state.hexes
        .where((tile) => tile.active && tile.owner >= 0)
        .map((tile) => tile.index)
        .toSet();
    while (unseen.isNotEmpty) {
      final seed = unseen.first;
      final owner = state.hexes[seed].owner;
      final component = <int>[];
      final queue = <int>[seed];
      unseen.remove(seed);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        component.add(index);
        for (final neighbor in state.hexes[index].neighbors) {
          if (state.hexes[neighbor].active &&
              state.hexes[neighbor].owner == owner &&
              unseen.remove(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      if (component.length > 5) return component;
    }
    return null;
  }

  int _slayMergedComponentSize(GameState state, int tileIndex, int owner) {
    final neighboringComponents = <int>{};
    var size = 1;
    for (final neighbor in state.hexes[tileIndex].neighbors) {
      if (state.hexes[neighbor].owner != owner ||
          neighboringComponents.contains(neighbor)) {
        continue;
      }
      final queue = <int>[neighbor];
      neighboringComponents.add(neighbor);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        size++;
        for (final next in state.hexes[index].neighbors) {
          if (state.hexes[next].owner == owner &&
              neighboringComponents.add(next)) {
            queue.add(next);
          }
        }
      }
    }
    return size;
  }

  void _shuffleSlayTiles(List<HexTile> tiles, _JavaRandom rng) {
    for (var index = tiles.length - 1; index > 0; index--) {
      final other = rng.nextInt(index + 1);
      final value = tiles[index];
      tiles[index] = tiles[other];
      tiles[other] = value;
    }
  }

  void _spawnPlayers(GameState state, _JavaRandom rng) {
    final active = state.hexes.where((tile) => tile.active).toList();
    final territories = <({int owner, HexTile start, Set<int> tiles})>[];
    final requestedPerPlayer = state.config.startingProvinceCount
        .clamp(0, 3)
        .toInt();
    final provincesByPlayer = [
      for (var player = 0; player < state.config.playerCount; player++)
        requestedPerPlayer == 0 ? 1 + rng.nextInt(3) : requestedPerPlayer,
    ];
    // Default is a deterministic per-player 1..3 roll from the stored map seed.
    // Explicit positions are exact: 1, 2 or 3, with three as the fixed maximum.
    if (requestedPerPlayer == 0 &&
        provincesByPlayer.length > 1 &&
        provincesByPlayer.toSet().length == 1) {
      final last = provincesByPlayer.length - 1;
      provincesByPlayer[last] = provincesByPlayer[last] == 3
          ? provincesByPlayer[last] - 1
          : provincesByPlayer[last] + 1;
    }
    final provinceSlots = provincesByPlayer.reduce(math.max);

    // Generic Classic phases: make all land neutral, then spawn one province
    // per fraction for every requested slot. The official search chooses the
    // active hex with the highest movement-zone number (farthest by land BFS).
    // Connected pairs are reserved first only because the local Province model
    // cannot represent Classic's temporary one-hex fraction as an economy.
    for (final tile in active) {
      tile.owner = -1;
    }
    final requestedTotal = provincesByPlayer.fold<int>(
      0,
      (sum, count) => sum + count,
    );
    final reservedPairs = _reserveStartingProvincePairs(
      state,
      active,
      requestedTotal,
      rng,
    );
    if (reservedPairs.length < requestedTotal) {
      _spawnFallbackGenericProvinces(state, active, provincesByPlayer, rng);
      return;
    }
    final allocations = _allocateStartingProvincePairs(
      state,
      reservedPairs,
      provincesByPlayer,
      provinceSlots,
      rng,
    );
    if (allocations.length != requestedTotal) {
      _spawnFallbackGenericProvinces(state, active, provincesByPlayer, rng);
      return;
    }
    for (final allocation in allocations) {
      final start = allocation.pair.first;
      final partner = allocation.pair.second;
      territories.add((
        owner: allocation.owner,
        start: start,
        tiles: {start.index, partner.index},
      ));
      state.hexes[start.index].owner = allocation.owner;
      state.hexes[partner.index].owner = allocation.owner;
    }

    // Potential-2 Classic starts are cut to SMALL_PROVINCE_SIZE=5. Crowded
    // 15-color / three-province layouts shrink evenly, never below the two
    // cells required by the local Province/capital representation.
    final territorySize = math.max(
      2,
      math.min(5, active.length ~/ math.max(1, territories.length * 2)),
    );
    final territoryTargets = [
      for (final territory in territories)
        _classicGenericProvinceTarget(
          territorySize,
          territory.owner,
          state.config.playerCount,
          rng,
        ),
    ];
    while (List<int>.generate(territories.length, (index) => index).any(
      (index) => territories[index].tiles.length < territoryTargets[index],
    )) {
      var grew = false;
      for (
        var territoryIndex = 0;
        territoryIndex < territories.length;
        territoryIndex++
      ) {
        final territory = territories[territoryIndex];
        if (territory.tiles.length >= territoryTargets[territoryIndex]) {
          continue;
        }
        final frontier = territory.tiles
            .expand((index) => state.hexes[index].neighbors)
            .where(
              (index) =>
                  state.hexes[index].active &&
                  state.hexes[index].owner < 0 &&
                  !state.hexes[index].neighbors.any(
                    (neighbor) =>
                        state.hexes[neighbor].owner == territory.owner &&
                        !territory.tiles.contains(neighbor),
                  ),
            )
            .toSet()
            .toList();
        if (frontier.isEmpty) continue;
        frontier.sort((a, b) {
          final aSpace = state.hexes[a].neighbors
              .where(
                (index) =>
                    state.hexes[index].active && state.hexes[index].owner < 0,
              )
              .length;
          final bSpace = state.hexes[b].neighbors
              .where(
                (index) =>
                    state.hexes[index].active && state.hexes[index].owner < 0,
              )
              .length;
          return bSpace.compareTo(aSpace);
        });
        final band = math.min(3, frontier.length);
        final next = frontier[rng.nextInt(band)];
        state.hexes[next].owner = territory.owner;
        territory.tiles.add(next);
        grew = true;
      }
      if (!grew) break;
    }

    for (final territory in territories) {
      for (final index in territory.tiles) {
        state.hexes[index].owner = territory.owner;
      }
      final capitalCandidates = territory.tiles.toList()..sort();
      final capital = capitalCandidates[rng.nextInt(capitalCandidates.length)];
      state.hexes[capital]
        ..object = TileObject.town
        ..unit = null
        ..treeBorn = -1;
      final province = Province(
        id: state.nextProvinceId++,
        owner: territory.owner,
        tiles: territory.tiles.toList(),
        money: mod.rules.initialMoney,
        capital: capital,
      );
      state.provinces.add(province);
    }
  }

  /// Deterministic last-resort allocator for unusually awkward coast shapes.
  ///
  /// The normal path keeps connected two-to-five-hex starting economies. This
  /// fallback follows Classic's temporary single-fraction semantics first, then
  /// grows every seed where a safe neighbour exists. It guarantees that every
  /// supported 2..15 / default|1|2|3 setup returns a playable set of capitals
  /// instead of exposing a random matching failure as a [StateError].
  void _spawnFallbackGenericProvinces(
    GameState state,
    List<HexTile> active,
    List<int> provincesByPlayer,
    _JavaRandom rng,
  ) {
    for (final tile in active) {
      tile.owner = -1;
    }
    final ownerOrder = <int>[];
    final slots = provincesByPlayer.reduce(math.max);
    for (var slot = 0; slot < slots; slot++) {
      for (var owner = 0; owner < provincesByPlayer.length; owner++) {
        if (slot < provincesByPlayer[owner]) ownerOrder.add(owner);
      }
    }

    final territories = <({int owner, Set<int> tiles})>[];
    final available = active.map((tile) => tile.index).toSet();
    final selected = <int>[];
    for (final owner in ownerOrder) {
      var candidates = available.where((index) {
        final tile = state.hexes[index];
        return !tile.neighbors.any(
          (neighbor) => state.hexes[neighbor].owner == owner,
        );
      }).toList();
      if (candidates.isEmpty) candidates = available.toList();
      if (candidates.isEmpty) break;
      final tie = <int, int>{
        for (final index in candidates) index: rng.nextInt(1 << 30),
      };
      final distances = _activeDistancesFromStarts(state, [
        for (final index in selected) state.hexes[index],
      ]);
      candidates.sort((a, b) {
        final spreadOrder = (distances[b] ?? 0).compareTo(distances[a] ?? 0);
        if (spreadOrder != 0) return spreadOrder;
        final tieOrder = tie[a]!.compareTo(tie[b]!);
        return tieOrder != 0 ? tieOrder : a.compareTo(b);
      });
      final seed = candidates.first;
      available.remove(seed);
      selected.add(seed);
      state.hexes[seed].owner = owner;
      territories.add((owner: owner, tiles: <int>{seed}));
    }

    // Grow each temporary one-hex fraction once whenever possible, which keeps
    // the local economy model's usual two-hex start without risking a crash.
    for (final territory in territories) {
      final frontier =
          territory.tiles
              .expand((index) => state.hexes[index].neighbors)
              .where(
                (index) =>
                    available.contains(index) &&
                    !state.hexes[index].neighbors.any(
                      (neighbor) =>
                          state.hexes[neighbor].owner == territory.owner &&
                          !territory.tiles.contains(neighbor),
                    ),
              )
              .toList()
            ..sort();
      if (frontier.isEmpty) continue;
      final partner = frontier.first;
      available.remove(partner);
      state.hexes[partner].owner = territory.owner;
      territory.tiles.add(partner);
    }

    for (final territory in territories) {
      final candidates = territory.tiles.toList()..sort();
      final capital = candidates[rng.nextInt(candidates.length)];
      state.hexes[capital]
        ..object = TileObject.town
        ..unit = null
        ..treeBorn = -1;
      state.provinces.add(
        Province(
          id: state.nextProvinceId++,
          owner: territory.owner,
          tiles: candidates,
          money: mod.rules.initialMoney,
          capital: capital,
        ),
      );
    }
  }

  int _classicGenericProvinceTarget(
    int base,
    int owner,
    int playerCount,
    _JavaRandom rng,
  ) {
    final change = _classicGenericBalanceChange(owner, playerCount);
    var result = base;
    if (change > 0 && rng.nextDouble() < change) {
      result++;
    } else if (change < 0 && rng.nextDouble() < -change) {
      result--;
    }
    return result.clamp(2, 5).toInt();
  }

  double _classicGenericBalanceChange(int owner, int playerCount) {
    const official = <int, List<double>>{
      2: [-0.4, 0.3],
      3: [-0.5, 0.2, 0.4],
      4: [-0.6, 0.12, 0.3, 0.6],
      5: [-0.5, -0.35, 0.15, 0.32, 0.5],
      6: [-0.6, -0.75, 0.15, 0.25, 0.4, 0.6],
      7: [-0.4, -0.9, 0.2, 0.3, 0.45, 0.6, 0.8],
    };
    final exact = official[playerCount];
    if (exact != null) return exact[owner];
    if (playerCount <= 1) return 0;
    // Classic has no table above seven fractions. Preserve its first-player
    // disadvantage / later-player compensation with a bounded interpolation.
    return -0.45 + 1.15 * owner / (playerCount - 1);
  }

  List<_StartingPair> _reserveStartingProvincePairs(
    GameState state,
    List<HexTile> active,
    int required,
    _JavaRandom rng,
  ) {
    final allPairs = <_StartingPair>[];
    for (final tile in active) {
      for (final neighborIndex in tile.neighbors) {
        final neighbor = state.hexes[neighborIndex];
        if (!neighbor.active || neighbor.index < tile.index) {
          continue;
        }
        allPairs.add(_StartingPair(tile, neighbor));
      }
    }
    var best = <_StartingPair>[];
    final attempts = math.max(24, math.min(96, required * 2));
    for (var attempt = 0; attempt < attempts; attempt++) {
      final ranked =
          <({_StartingPair pair, int pressure, int tie})>[
            for (final pair in allPairs)
              (
                pair: pair,
                pressure:
                    pair.first.neighbors
                        .where((index) => state.hexes[index].active)
                        .length +
                    pair.second.neighbors
                        .where((index) => state.hexes[index].active)
                        .length,
                tie: rng.nextInt(1 << 30),
              ),
          ]..sort((a, b) {
            final pressureOrder = a.pressure.compareTo(b.pressure);
            return pressureOrder != 0 ? pressureOrder : a.tie.compareTo(b.tie);
          });
      final used = <int>{};
      final selected = <_StartingPair>[];
      for (final candidate in ranked) {
        final pair = candidate.pair;
        if (used.contains(pair.first.index) ||
            used.contains(pair.second.index)) {
          continue;
        }
        used
          ..add(pair.first.index)
          ..add(pair.second.index);
        selected.add(pair);
      }
      if (selected.length > best.length) best = selected;
      if (best.length == active.length ~/ 2) return best;
    }
    return best;
  }

  List<({int owner, _StartingPair pair})> _allocateStartingProvincePairs(
    GameState state,
    List<_StartingPair> pairs,
    List<int> provincesByPlayer,
    int provinceSlots,
    _JavaRandom rng,
  ) {
    final required = provincesByPlayer.fold<int>(
      0,
      (sum, count) => sum + count,
    );
    var best = <({int owner, _StartingPair pair})>[];
    for (var attempt = 0; attempt < 96; attempt++) {
      final ownerOrder = <int>[];
      for (var slot = 0; slot < provinceSlots; slot++) {
        final owners = <int>[
          for (var owner = 0; owner < provincesByPlayer.length; owner++)
            if (slot < provincesByPlayer[owner]) owner,
        ];
        // MapGeneratorGeneric.spawnProvinces iterates fractions in turn order.
        ownerOrder.addAll(owners);
      }

      final remaining = [...pairs];
      final selected = <({int owner, _StartingPair pair})>[];
      final starts = <HexTile>[];
      for (final owner in ownerOrder) {
        final candidates = remaining.where((pair) {
          final sameOwner = selected
              .where((allocation) => allocation.owner == owner)
              .map((allocation) => allocation.pair)
              .toList();
          return sameOwner.every(
            (existing) =>
                !pair.first.neighbors.contains(existing.first.index) &&
                !pair.first.neighbors.contains(existing.second.index) &&
                !pair.second.neighbors.contains(existing.first.index) &&
                !pair.second.neighbors.contains(existing.second.index),
          );
        }).toList();
        if (candidates.isEmpty) break;
        final tieBreakers = <_StartingPair, int>{
          for (final pair in candidates) pair: rng.nextInt(1 << 30),
        };
        final landDistances = _activeDistancesFromStarts(state, starts);
        candidates.sort((a, b) {
          final aSpread = starts.isEmpty
              ? 0
              : math.min(
                  landDistances[a.first.index] ?? -1,
                  landDistances[a.second.index] ?? -1,
                );
          final bSpread = starts.isEmpty
              ? 0
              : math.min(
                  landDistances[b.first.index] ?? -1,
                  landDistances[b.second.index] ?? -1,
                );
          final spreadOrder = bSpread.compareTo(aSpread);
          return spreadOrder != 0
              ? spreadOrder
              : tieBreakers[a]!.compareTo(tieBreakers[b]!);
        });
        final pair = candidates.first;
        remaining.remove(pair);
        selected.add((owner: owner, pair: pair));
        starts.add(pair.first);
      }
      if (selected.length > best.length) best = selected;
      if (selected.length == required) return selected;
    }
    return best;
  }

  Map<int, int> _activeDistancesFromStarts(
    GameState state,
    List<HexTile> starts,
  ) {
    if (starts.isEmpty) return const <int, int>{};
    final distances = <int, int>{for (final start in starts) start.index: 0};
    final queue = <int>[for (final start in starts) start.index];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final distance = distances[index]! + 1;
      for (final neighbor in state.hexes[index].neighbors) {
        if (!state.hexes[neighbor].active || distances.containsKey(neighbor)) {
          continue;
        }
        distances[neighbor] = distance;
        queue.add(neighbor);
      }
    }
    return distances;
  }

  int _distanceToCenter(HexTile tile, GameState state) {
    final centerIndex = (state.height ~/ 2) * state.width + (state.width ~/ 2);
    final center = state.hexes[centerIndex.clamp(0, state.hexes.length - 1)];
    return _hexDistance(tile.q, tile.r, center.q, center.r);
  }

  int _hexDistance(int aq, int ar, int bq, int br) {
    final dq = aq - bq;
    final dr = ar - br;
    return (dq.abs() + dr.abs() + (dq + dr).abs()) ~/ 2;
  }
}

/// java.util.Random's 48-bit LCG, scoped to Classic generation only.
///
/// The simulation keeps using [FastRandom]. Java-style draws make the translated
/// phases deterministic without changing save/runtime randomness or secure new
/// seed creation. Axial bounds, fixed land budgets and naval adapters mean this
/// is not a tile-for-tile reproduction of an upstream Java seed.
class _JavaRandom {
  _JavaRandom(int seed) : _seed = (BigInt.from(seed) ^ _multiplier) & _mask;

  static final BigInt _multiplier = BigInt.from(0x5deece66d);
  static final BigInt _addend = BigInt.from(0xb);
  static final BigInt _mask = (BigInt.one << 48) - BigInt.one;

  BigInt _seed;

  int _next(int bits) {
    _seed = (_seed * _multiplier + _addend) & _mask;
    return (_seed >> (48 - bits)).toInt();
  }

  int nextInt(int bound) {
    if (bound <= 0) {
      throw ArgumentError.value(bound, 'bound', 'must be positive');
    }
    if ((bound & -bound) == bound) {
      return ((BigInt.from(bound) * BigInt.from(_next(31))) >> 31).toInt();
    }
    while (true) {
      final bits = _next(31);
      final value = bits % bound;
      if (bits - value + (bound - 1) < 0x80000000) return value;
    }
  }

  double nextDouble() {
    final bits = _next(26) * 0x8000000 + _next(27);
    return bits / 0x20000000000000;
  }
}

class _StartingPair {
  const _StartingPair(this.first, this.second);

  final HexTile first;
  final HexTile second;
}
