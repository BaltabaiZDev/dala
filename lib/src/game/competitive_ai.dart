part of 'game_ai.dart';

extension CompetitiveLandAi on GameAi {
  /// Bounded expansion before infrastructure spending, using ordinary actions.
  bool _takeExpansionAction() {
    if (_tier < AiDifficulty.veryHard.index || engine.state.winner != null) {
      return false;
    }
    final state = engine.state;
    final owner = state.turn;
    final visible = state.config.fogOfWar
        ? landVisionTiles(state, mod, (p) => p == owner)
        : null;
    bool targetAllowed(int index) =>
        (visible == null || visible.contains(index)) &&
        state.hexes[index].owner != owner &&
        (state.hexes[index].owner < 0 ||
            engine.areEnemies(owner, state.hexes[index].owner) ||
            engine.isIsolatedHolding(index));
    int value(int index, int strength) {
      final tile = state.hexes[index];
      final openings = tile.neighbors
          .where((n) => state.hexes[n].active && state.hexes[n].owner < 0)
          .length;
      final contested = tile.neighbors
          .where(
            (n) => state.hexes[n].owner >= 0 && state.hexes[n].owner != owner,
          )
          .length;
      return 100 +
          _strategicAttackScore(index, strength) +
          openings * 16 +
          contested * 12;
    }

    int? source, target;
    var best = -1;
    Set<int>? legalTargets;
    for (final unit in _startingReadyLandUnits()) {
      if (unit.typeId != null) continue;
      final from = _tileIndexForUnit(unit);
      if (from == null) continue;
      final capital = engine.provinceAt(from)?.capital;
      if (capital != null &&
          (capital == from || state.hexes[capital].neighbors.contains(from))) {
        final remainingDefense = _defenseAtIgnoring(capital, unit);
        if (state.hexes[capital].neighbors.any(
          (n) =>
              engine.areEnemies(owner, engine.unitOwnerAt(n)) &&
              (state.hexes[n].unit?.strength ?? 0) > remainingDefense,
        )) {
          continue;
        }
      }
      final targets = engine.moveTargets(from);
      for (final index in targets.where(targetAllowed)) {
        final score = value(index, unit.strength);
        if (score > best) {
          best = score;
          source = from;
          target = index;
          legalTargets = targets;
        }
      }
    }
    if (source != null && target != null) {
      return _moveLandUnit(source, target, knownTargets: legalTargets);
    }

    Province? buyer;
    var strengthToBuy = 0;
    best = -1;
    final productionPercent = state.isHuman(owner)
        ? 100
        : state.config.difficulty.incomePercent;
    for (final province in engine.provincesOf(owner).toList()) {
      final profit = engine
          .economicBreakdown(province, includeDiplomacy: false)
          .total;
      for (var strength = 1; strength <= 4; strength++) {
        final price = mod.rules.unitPricePerLevel * strength;
        if (province.money < price ||
            !engine.provinceAllowsUnitStrength(province.id, strength)) {
          continue;
        }
        final afterCapture =
            profit +
            productionPercent ~/ 100 -
            engine.unitUpkeepAtStrength(strength);
        if (province.money - price + math.min(0, afterCapture) * 3 < 0) {
          continue;
        }
        for (final index
            in engine
                .unitBuildTargets(province.id, strength)
                .where(targetAllowed)) {
          final score = value(index, strength) - strength * 28;
          if (score > best) {
            best = score;
            buyer = province;
            target = index;
            strengthToBuy = strength;
          }
        }
      }
    }
    return buyer != null &&
        target != null &&
        _buyLandUnit(buyer, target, strengthToBuy);
  }
}
