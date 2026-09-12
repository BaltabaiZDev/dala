part of 'game_engine.dart';

extension ModGameplay on GameEngine {
  ModBuilding? modBuildingAt(int index) =>
      mod.buildings[state.hexes[index].buildingTypeId];
  ModUnitType? modUnitType(GameUnit unit) => mod.units[unit.typeId];
  int unitPrice(GameUnit unit) =>
      modUnitType(unit)?.price ?? unit.strength * mod.rules.unitPricePerLevel;
  int unitMaintenance(GameUnit unit) =>
      modUnitType(unit)?.upkeep ?? _unitUpkeep(unit.strength);
  int unitMovement(GameUnit unit) =>
      modUnitType(unit)?.moveRange ?? mod.rules.unitMoveLimit;
  bool canMergeUnits(GameUnit first, GameUnit second) =>
      first.typeId == null &&
      second.typeId == null &&
      first.strength + second.strength <= 4;

  /// Also used at map/import boundaries with the resolved package snapshot.
  void validateModState() {
    void unit(GameUnit value, ModMovement movement) {
      if (value.typeId == null && movement == ModMovement.land) return;
      final type = modUnitType(value);
      if (type == null ||
          type.movement != movement ||
          value.strength != type.strength) {
        throw FormatException(
          'Unknown or incompatible mod unit: ${value.typeId}',
        );
      }
    }

    for (final tile in state.hexes) {
      if (tile.buildingTypeId != null &&
          (modBuildingAt(tile.index) == null ||
              !tile.active ||
              tile.owner < 0 ||
              tile.object != TileObject.none ||
              tile.unit != null ||
              tile.coalitionClaim != null)) {
        throw FormatException('Invalid mod building: ${tile.buildingTypeId}');
      }
      if (tile.unit != null) unit(tile.unit!, ModMovement.land);
      if (tile.airUnit != null) {
        unit(tile.airUnit!, ModMovement.air);
        if (!tile.inWorld ||
            tile.airUnit!.owner < 0 ||
            tile.airUnit!.owner >= state.config.playerCount) {
          throw const FormatException('Invalid aircraft location or owner.');
        }
      }
    }
    for (final cell in state.waterCells) {
      for (final cargo in cell.boat?.cargo ?? <GameUnit>[]) {
        unit(cargo, ModMovement.land);
      }
    }
  }

  Set<int> modBuildTargets(int provinceId, String typeId) {
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return {};
    final building = mod.buildings[typeId];
    final unit = mod.units[typeId];
    if (building == null && unit == null) return {};
    if (province.money < (building?.price ?? unit!.price)) return {};
    Set<int>? production;
    if (unit?.requiresBuilding != null) {
      production = {};
      for (final index in province.tiles) {
        if (state.hexes[index].buildingTypeId != unit!.requiresBuilding) {
          continue;
        }
        production.addAll(state.hexes[index].neighbors);
        if (unit.movement == ModMovement.air) production.add(index);
      }
    }
    return province.tiles.where((index) {
      final tile = state.hexes[index];
      if (!tile.active ||
          tile.owner != state.turn ||
          tile.coalitionClaim != null ||
          (production != null && !production.contains(index))) {
        return false;
      }
      if (unit?.movement == ModMovement.air) return tile.airUnit == null;
      return tile.object == TileObject.none &&
          tile.buildingTypeId == null &&
          tile.unit == null;
    }).toSet();
  }

  bool buildModType(int provinceId, int targetIndex, String typeId) {
    if (!modBuildTargets(provinceId, typeId).contains(targetIndex)) {
      return false;
    }
    final province = _provinceById(provinceId)!;
    final tile = state.hexes[targetIndex];
    final building = mod.buildings[typeId];
    if (building != null) {
      province.money -= building.price;
      tile.buildingTypeId = typeId;
    } else {
      final type = mod.units[typeId]!;
      province.money -= type.price;
      final unit = GameUnit(
        strength: type.strength,
        ready: false,
        owner: state.turn,
        homeProvinceId: province.id,
        typeId: typeId,
      );
      if (type.movement == ModMovement.air) {
        tile.airUnit = unit;
      } else {
        tile.unit = unit;
      }
    }
    return true;
  }

  bool _airspaceAllowed(int actor, HexTile tile) =>
      !tile.active ||
      tile.owner < 0 ||
      tile.owner == actor ||
      !state.config.diplomacy ||
      areEnemies(actor, tile.owner) ||
      hasMilitaryAccess(actor, tile.owner);

  Set<int> airMoveTargets(int from) {
    if (from < 0 || from >= state.hexes.length) return {};
    final unit = state.hexes[from].airUnit;
    if (unit == null || unit.owner != state.turn || !unit.ready) return {};
    return _modRadius(
          state,
          from,
          unitMovement(unit),
          traverse: (tile) => _airspaceAllowed(unit.owner, tile),
        )
        .where(
          (index) =>
              index != from &&
              state.hexes[index].airUnit == null &&
              _airspaceAllowed(unit.owner, state.hexes[index]),
        )
        .toSet();
  }

  bool moveAirUnit(int from, int to) {
    if (!airMoveTargets(from).contains(to)) return false;
    final unit = state.hexes[from].airUnit!;
    state.hexes[from].airUnit = null;
    state.hexes[to].airUnit = unit..ready = false;
    return true;
  }

  bool _modHostile(int actor, int target) =>
      target >= 0 &&
      target != actor &&
      (!state.config.diplomacy || areEnemies(actor, target));

  Set<int> airAttackTargets(int from) {
    if (from < 0 || from >= state.hexes.length) return {};
    final unit = state.hexes[from].airUnit;
    if (unit == null || unit.owner != state.turn || !unit.ready) return {};
    final type = modUnitType(unit)!;
    if (type.attackRange == 0) return {};
    Set<int>? vision;
    if (state.config.fogOfWar) {
      bool allied(int other) => areAllies(unit.owner, other);
      vision = landVisionTiles(state, mod, allied);
      for (final index in waterVisionCells(state, mod, allied, land: vision)) {
        vision.addAll(state.waterCells[index].tiles);
      }
    }
    return _modRadius(state, from, type.attackRange).where((index) {
      if (vision != null && !vision.contains(index)) return false;
      final target = state.hexes[index];
      final air = target.airUnit;
      if (air != null) {
        return _modHostile(unit.owner, air.owner) &&
            unit.strength > air.strength;
      }
      if (!target.active ||
          !_modHostile(unit.owner, target.owner) ||
          target.coalitionClaim != null) {
        return false;
      }
      if (target.unit != null && !_modHostile(unit.owner, unitOwnerAt(index))) {
        return false;
      }
      final destructible =
          target.unit != null ||
          target.buildingTypeId != null ||
          (target.object != TileObject.none &&
              target.object != TileObject.town &&
              target.object != TileObject.grave &&
              !target.hasTree);
      return destructible && unit.strength > defenseAt(index);
    }).toSet();
  }

  bool attackWithAirUnit(int from, int to) {
    if (!airAttackTargets(from).contains(to)) return false;
    final target = state.hexes[to];
    state.hexes[from].airUnit!.ready = false;
    if (target.airUnit != null) {
      target.airUnit = null;
    } else {
      target.unit = null;
      if (target.object != TileObject.town) {
        target.object = TileObject.none;
        target.artilleryAmmo = target.artilleryCooldown = 0;
      }
    }
    return true;
  }

  /// Buildings need a funded province. Aircraft retain their payer through
  /// flight; a lost/merged payer is replaced deterministically by an own one.
  void normalizeModAssets({Map<int, int> successors = const {}}) {
    if (mod.buildings.isEmpty && mod.units.isEmpty) return;
    final byId = {
      for (final province in state.provinces) province.id: province,
    };
    final byTile = {
      for (final province in state.provinces)
        for (final index in province.tiles) index: province,
    };
    final homes = <int, List<Province>>{};
    for (final province in state.provinces) {
      homes.putIfAbsent(province.owner, () => []).add(province);
    }
    for (final values in homes.values) {
      values.sort((a, b) => a.id.compareTo(b.id));
    }
    final displaced = <({int from, GameUnit unit})>[];
    for (final tile in state.hexes) {
      if (tile.buildingTypeId != null &&
          byTile[tile.index]?.owner != tile.owner) {
        tile.buildingTypeId = null;
      }
      final air = tile.airUnit;
      if (air == null) continue;
      final provinces = homes[air.owner] ?? [];
      if (provinces.isEmpty) {
        tile.airUnit = null;
        continue;
      }
      final successor = successors[air.homeProvinceId] ?? air.homeProvinceId;
      air.homeProvinceId = byId[successor]?.owner == air.owner
          ? successor
          : provinces.first.id;
      if (!_airspaceAllowed(air.owner, tile)) {
        tile.airUnit = null;
        displaced.add((from: tile.index, unit: air));
      }
    }
    for (final item in displaced) {
      final unit = item.unit;
      final available =
          (homes[unit.owner] ?? [])
              .expand((p) => p.tiles)
              .where((index) => state.hexes[index].airUnit == null)
              .toList()
            ..sort((a, b) {
              final distance = _modDistance(
                state.hexes[item.from],
                state.hexes[a],
              ).compareTo(_modDistance(state.hexes[item.from], state.hexes[b]));
              return distance != 0 ? distance : a.compareTo(b);
            });
      if (available.isEmpty) {
        byId[unit.homeProvinceId]!.money += unitPrice(unit);
      } else {
        state.hexes[available.first].airUnit = unit..ready = false;
      }
    }
  }
}

int _modDistance(HexTile a, HexTile b) =>
    ((a.q - b.q).abs() + (a.r - b.r).abs() + (a.q + a.r - b.q - b.r).abs()) ~/
    2;

Set<int> _modRadius(
  GameState state,
  int start,
  int radius, {
  bool Function(HexTile)? traverse,
}) {
  final distances = {start: 0};
  final queue = [start];
  for (var i = 0; i < queue.length; i++) {
    final index = queue[i];
    if (distances[index]! >= radius) continue;
    for (final next in state.hexes[index].neighbors) {
      if (!state.hexes[next].inWorld ||
          distances.containsKey(next) ||
          (traverse != null && !traverse(state.hexes[next]))) {
        continue;
      }
      distances[next] = distances[index]! + 1;
      queue.add(next);
    }
  }
  return distances.keys.toSet();
}

/// A bounded multi-source flood includes water hexes, so radar and aircraft
/// reveal islands across straits instead of stopping at the shoreline.
Set<int> modVisionTiles(
  GameState state,
  GameMod mod,
  bool Function(int) allied,
) {
  if (mod.buildings.isEmpty && mod.units.isEmpty) return {};
  final remaining = <int, int>{};
  final queue = <int>[];
  void reveal(int index, int radius) {
    if (radius < 0 || (remaining[index] ?? -1) >= radius) return;
    remaining[index] = radius;
    queue.add(index);
  }

  for (final tile in state.hexes) {
    if (!tile.inWorld) continue;
    if (tile.buildingTypeId != null && allied(tile.owner)) {
      final radius = mod.buildings[tile.buildingTypeId]?.vision ?? 0;
      if (radius > 0) reveal(tile.index, radius);
    }
    for (final unit in [tile.unit, tile.airUnit]) {
      if (unit?.typeId == null ||
          !allied(unit!.owner < 0 ? tile.owner : unit.owner)) {
        continue;
      }
      reveal(tile.index, mod.units[unit.typeId]?.vision ?? 0);
    }
  }
  for (var i = 0; i < queue.length; i++) {
    final index = queue[i];
    final radius = remaining[index]!;
    if (radius == 0) continue;
    for (final next in state.hexes[index].neighbors) {
      if (state.hexes[next].inWorld) reveal(next, radius - 1);
    }
  }
  return remaining.keys.toSet();
}
