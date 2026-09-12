part of 'game_ai.dart';

extension _ModAi on GameAi {
  bool _takeModAction() {
    if (mod.buildings.isEmpty && mod.units.isEmpty) return false;
    final state = engine.state;
    for (final tile in state.hexes) {
      final air = tile.airUnit;
      if (air == null ||
          air.owner != state.turn ||
          !air.ready ||
          !_modAircraftTried.add(air)) {
        continue;
      }
      final attacks = engine.airAttackTargets(tile.index).toList()
        ..sort((a, b) {
          int value(int index) {
            final t = state.hexes[index];
            return (t.airUnit == null ? 0 : engine.unitPrice(t.airUnit!)) +
                (t.unit == null ? 0 : engine.unitPrice(t.unit!)) +
                (engine.modBuildingAt(index)?.price ?? 0);
          }

          final priority = value(b).compareTo(value(a));
          return priority != 0 ? priority : a.compareTo(b);
        });
      if (attacks.isNotEmpty &&
          engine.attackWithAirUnit(tile.index, attacks.first)) {
        return true;
      }
      final enemies = engine.state.provinces
          .where(
            (p) =>
                p.owner != state.turn && engine.areEnemies(state.turn, p.owner),
          )
          .toList();
      if (enemies.isEmpty) continue;
      int distance(HexTile a, HexTile b) =>
          (a.q - b.q).abs() + (a.r - b.r).abs() + (a.q + a.r - b.q - b.r).abs();
      int targetDistance(int index) => enemies
          .map((p) => distance(state.hexes[index], state.hexes[p.capital]))
          .reduce(math.min);
      final moves =
          engine
              .airMoveTargets(tile.index)
              .where(
                (index) => targetDistance(index) < targetDistance(tile.index),
              )
              .toList()
            ..sort((a, b) {
              final order = targetDistance(a).compareTo(targetDistance(b));
              return order != 0 ? order : a.compareTo(b);
            });
      if (moves.isNotEmpty && engine.moveAirUnit(tile.index, moves.first)) {
        return true;
      }
    }
    final provinces = engine.provincesOf(state.turn).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final province in provinces) {
      if (!_modBuildProvinces.add(province.id)) continue;
      final ownedBuildings = {
        for (final index in province.tiles) state.hexes[index].buildingTypeId,
      };
      final ownUnits = state.hexes
          .expand((tile) => [tile.unit, tile.airUnit])
          .whereType<GameUnit>()
          .where(
            (unit) =>
                unit.owner == state.turn && unit.homeProvinceId == province.id,
          )
          .toList();
      final options =
          <({String id, int score, int price, int upkeep, int income})>[];
      for (final building in mod.buildings.values) {
        if (ownedBuildings.contains(building.id)) continue;
        final production = mod.units.values.any(
          (type) => type.requiresBuilding == building.id,
        );
        final utility = building.income > building.upkeep
            ? 50
            : state.config.fogOfWar && building.vision > 4
            ? 45
            : production
            ? 35
            : building.defense > 1
            ? 25
            : 0;
        if (utility > 0) {
          options.add((
            id: building.id,
            score: utility,
            price: building.price,
            upkeep: building.upkeep,
            income: building.income,
          ));
        }
      }
      for (final type in mod.units.values) {
        if (ownUnits.where((unit) => unit.typeId == type.id).length >=
            (type.movement == ModMovement.air ? 2 : 3)) {
          continue;
        }
        if (type.requiresBuilding != null &&
            !ownedBuildings.contains(type.requiresBuilding)) {
          continue;
        }
        options.add((
          id: type.id,
          score: type.movement == ModMovement.air ? 40 : 30,
          price: type.price,
          upkeep: type.upkeep,
          income: 0,
        ));
      }
      options.sort((a, b) {
        final order = b.score.compareTo(a.score);
        return order != 0 ? order : a.id.compareTo(b.id);
      });
      for (final option in options) {
        final remaining = province.money - option.price;
        final future = engine.balance(province) + option.income - option.upkeep;
        if (remaining < math.max(10, option.upkeep * 3) ||
            (future < 0 && remaining < -future * 4 + 20)) {
          continue;
        }
        final targets = engine.modBuildTargets(province.id, option.id).toList()
          ..sort();
        if (targets.isNotEmpty &&
            engine.buildModType(province.id, targets.first, option.id)) {
          return true;
        }
      }
    }
    return false;
  }
}
