import 'dart:async';
import 'dart:math' as math;

import '../modding/game_mod.dart';
import 'game_engine.dart';
import 'models.dart';

/// Diagnostics from one Classic Generic Master turn. These values are not
/// persisted and never influence decisions; they exist so parity tests can
/// verify the official seven-cycle state machine without screenshots.
class ClassicMasterTurnReport {
  const ClassicMasterTurnReport({required this.provinces});

  final List<ClassicMasterProvinceReport> provinces;

  int get maximumCycles => provinces.fold<int>(
    0,
    (value, province) => math.max(value, province.cycles),
  );
}

class ClassicMasterProvinceReport {
  const ClassicMasterProvinceReport({
    required this.provinceId,
    required this.cycles,
    required this.attemptOrder,
  });

  final int provinceId;
  final int cycles;
  final List<String> attemptOrder;
}

/// Turn-local port of Classic Antiyoy's Generic `AiMaster` subsystem.
///
/// The original stores analysis fields directly on every Java Hex. This port
/// deliberately keeps the equivalent data in [_MasterHexData] for one turn so
/// saves, editor states and the mod schema stay unchanged. Naval pieces are not
/// considered as land actions here; GameAi invokes its naval/artillery adapter
/// only after this subsystem has completed.
///
/// Two Java sub-branches cannot be represented literally by the local model:
/// imported hexes expose an unordered neighbor list rather than six stable
/// direction slots, and GameEngine exposes committed reachability rather than
/// AiMaster's speculative MassMarch graph. Lateral attack-pattern ordering uses
/// the available deterministic neighbor order, while cover/cut-off simulations
/// reserve real reachable units in temporary sets. Their official thirst,
/// danger, affordability and branch ordering are retained.
class ClassicMasterAi {
  ClassicMasterAi({required this.mod, required this.engine});

  final GameMod mod;
  final GameEngine engine;
  late final List<_MasterHexData> _data;
  late final _JavaRandom _random;

  static bool shouldRunFor(GameState state) =>
      !state.config.slayRules && state.config.difficulty == AiDifficulty.master;

  ClassicMasterTurnReport perform() {
    _prepareTurn();
    final reports = <ClassicMasterProvinceReport>[];
    for (final provinceId in _startingProvinceIds()) {
      final session = _MasterProvinceSession(this, provinceId);
      if (!session.prepare()) continue;
      while (session.runNextCycle()) {}
      session.finish();
      reports.add(session.report());
      if (engine.state.winner != null) break;
    }
    return ClassicMasterTurnReport(provinces: reports);
  }

  /// Same state machine as [perform], with cooperative yields between setup,
  /// cycles and province finalization. Decision order and RNG consumption are
  /// therefore byte-for-byte identical between sync and async entry points.
  Future<ClassicMasterTurnReport> performAsync({
    void Function(double progress)? onProgress,
  }) async {
    final frameBudget = Stopwatch()..start();
    _prepareTurn();
    if (frameBudget.elapsedMicroseconds >= 10000) {
      await _yieldFrame(frameBudget);
    }
    final ids = _startingProvinceIds();
    final reports = <ClassicMasterProvinceReport>[];
    var completedWork = 0;
    final totalWork = math.max(1, ids.length * 9);
    for (final provinceId in ids) {
      final session = _MasterProvinceSession(this, provinceId);
      if (!session.prepare()) continue;
      completedWork++;
      onProgress?.call(completedWork / totalWork);
      if (frameBudget.elapsedMicroseconds >= 10000) {
        await _yieldFrame(frameBudget);
      }
      while (session.runNextCycle()) {
        completedWork++;
        onProgress?.call(math.min(1, completedWork / totalWork));
        if (frameBudget.elapsedMicroseconds >= 10000) {
          await _yieldFrame(frameBudget);
        }
      }
      session.finish();
      reports.add(session.report());
      completedWork++;
      onProgress?.call(math.min(1, completedWork / totalWork));
      if (frameBudget.elapsedMicroseconds >= 10000) {
        await _yieldFrame(frameBudget);
      }
      if (engine.state.winner != null) break;
    }
    onProgress?.call(1);
    return ClassicMasterTurnReport(provinces: reports);
  }

  Future<void> _yieldFrame(Stopwatch frameBudget) async {
    await Future<void>.delayed(Duration.zero);
    frameBudget
      ..reset()
      ..start();
  }

  void _prepareTurn() {
    _data = List<_MasterHexData>.generate(
      engine.state.hexes.length,
      (_) => _MasterHexData(),
    );
    final state = engine.state;
    _random = _JavaRandom(
      state.config.seed ^
          (state.round * 0x9e3779b9) ^
          (state.turn * 0x85ebca6b),
    );
    _updateLoneliness();
    _updateAttractiveness();
  }

  List<int> _startingProvinceIds() => engine
      .provincesOf(engine.state.turn)
      .map((province) => province.id)
      .toList(growable: false);

  bool _workable(int index) =>
      index >= 0 &&
      index < engine.state.hexes.length &&
      engine.state.hexes[index].active;

  List<int> _propagate(
    Iterable<int> starts,
    int depth, {
    required bool Function(int source, int destination) allowed,
  }) {
    final distance = <int, int>{};
    final queue = <int>[];
    for (final start in starts) {
      if (!_workable(start) || distance.containsKey(start)) continue;
      distance[start] = depth;
      queue.add(start);
    }
    final reached = <int>[];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final source = queue[cursor];
      final remaining = distance[source]!;
      if (remaining == 0) continue;
      for (final destination in engine.state.hexes[source].neighbors) {
        if (!_workable(destination) || distance.containsKey(destination)) {
          continue;
        }
        if (!allowed(source, destination)) continue;
        distance[destination] = remaining - 1;
        queue.add(destination);
        reached.add(destination);
      }
    }
    return reached;
  }

  void _updateLoneliness() {
    var maximum = 0;
    for (final tile in engine.state.hexes.where((tile) => tile.active)) {
      final count = _propagate([tile.index], 3, allowed: (_, _) => true).length;
      _data[tile.index].loneliness = count.toDouble();
      maximum = math.max(maximum, count);
    }
    if (maximum == 0) return;
    for (final tile in engine.state.hexes.where((tile) => tile.active)) {
      _data[tile.index].loneliness = 1 - _data[tile.index].loneliness / maximum;
    }
  }

  void _updateAttractiveness() {
    for (final tile in engine.state.hexes.where((tile) => tile.active)) {
      final nearby = _propagate([tile.index], 1, allowed: (_, _) => true);
      if (nearby.isEmpty) {
        _data[tile.index].attractiveness = 0;
        continue;
      }
      _data[tile.index].attractiveness =
          nearby.fold<double>(
            0,
            (sum, index) => sum + _data[index].loneliness,
          ) /
          nearby.length;
    }
  }

  int _distance(int first, int second) {
    final a = engine.state.hexes[first];
    final b = engine.state.hexes[second];
    final dq = a.q - b.q;
    final dr = a.r - b.r;
    return (dq.abs() + dr.abs() + (dq + dr).abs()) ~/ 2;
  }
}

class _MasterHexData {
  double loneliness = 0;
  double attractiveness = 0;
  bool firstLine = false;
  bool secondLine = false;
  double importance = 0;
  int solidDefense = 0;
  double armyPresence = 0;
  bool attack1 = false;
  bool attack2 = false;
  double tastiness = 0;
  int ownedLandsNearby = 0;
  double vicinity = 0;
  bool currentlyOwned = false;
  bool inReadyArea = false;
  final List<int> potentialAttackers = <int>[];
  int? referenceHex;
  final List<int> dependentUnits = <int>[];

  void resetForProvince() {
    firstLine = false;
    secondLine = false;
    importance = 0;
    solidDefense = 0;
    armyPresence = 0;
    attack1 = false;
    attack2 = false;
    tastiness = 0;
    ownedLandsNearby = 0;
    vicinity = 0;
    currentlyOwned = false;
    inReadyArea = false;
    potentialAttackers.clear();
    referenceHex = null;
    dependentUnits.clear();
  }
}

enum _MasterAction { cutTree, peacefullyExpand, attack, defend }

enum _MasterSpending { unit1, unit2, unit3, unit4, farm, tower1, tower2 }

class _ScoredChoice<T> {
  const _ScoredChoice(this.value, this.thirst);

  final T value;
  final double thirst;
}

class _MasterProvinceSession {
  _MasterProvinceSession(this.master, this.initialProvinceId)
    : owner = master.engine.state.turn;

  final ClassicMasterAi master;
  final int initialProvinceId;
  final int owner;
  final Set<int> currentlyOwned = <int>{};
  final List<int> firstLine = <int>[];
  final List<int> secondLine = <int>[];
  final List<int> adjacentNeutral = <int>[];
  final List<String> attemptOrder = <String>[];
  late final _MasterAttackManager attackManager;
  late final _MasterDefenseManager defenseManager;
  int anchor = -1;
  int cycles = 0;
  bool spendingAllowed = true;
  bool actionAllowed = true;
  int money = 0;
  int income = 0;
  int profit = 0;
  double averageAttractiveness = 0;

  GameEngine get engine => master.engine;
  GameMod get mod => master.mod;
  GameState get state => engine.state;

  Province? get province {
    for (final item in engine.provincesOf(owner)) {
      if (item.tiles.contains(anchor)) return item;
    }
    for (final item in engine.provincesOf(owner)) {
      if (item.tiles.any(currentlyOwned.contains)) return item;
    }
    return null;
  }

  bool prepare() {
    final initial = engine
        .provincesOf(owner)
        .where((province) => province.id == initialProvinceId)
        .firstOrNull;
    if (initial == null) return false;
    anchor = initial.capital;
    for (final data in master._data) {
      data.resetForProvince();
    }
    currentlyOwned
      ..clear()
      ..addAll(initial.tiles);
    _tagCurrentlyOwned();
    _updateMoneyStats();
    _updateAverageAttractiveness();
    _updatePerimeter();
    _updateImportance();
    _updateSolidDefense();
    _updateVicinity();
    _mergePeasantsBeforePlanning();
    defenseManager = _MasterDefenseManager(this)..onTurnStarted();
    attackManager = _MasterAttackManager(this)..onTurnStarted();
    return true;
  }

  bool runNextCycle() {
    if (cycles >= 7 || (!spendingAllowed && !actionAllowed)) return false;
    cycles++;
    if (spendingAllowed) {
      attemptOrder.add('spending');
      if (!_trySingleSpending()) spendingAllowed = false;
    }
    if (actionAllowed) {
      attemptOrder.add('action');
      if (!_trySingleAction()) actionAllowed = false;
    }
    return cycles < 7 && (spendingAllowed || actionAllowed);
  }

  void finish() {
    _casualGrab();
    _pullUnitsToPerimeter();
    _supplyArmyWithTowers();
    _pushUnitsToBetterDefense();
  }

  ClassicMasterProvinceReport report() => ClassicMasterProvinceReport(
    provinceId: initialProvinceId,
    cycles: cycles,
    attemptOrder: List<String>.unmodifiable(attemptOrder),
  );

  void _refreshAfterMutation() {
    _syncProvince();
    _updateMoneyStats();
    _updatePerimeter();
    _updateImportance();
    _updateSolidDefense();
    _updateVicinity();
  }

  void _syncProvince() {
    final current = province;
    if (current == null) return;
    currentlyOwned.addAll(current.tiles);
    _tagCurrentlyOwned();
  }

  void _tagCurrentlyOwned() {
    for (final data in master._data) {
      data.currentlyOwned = false;
    }
    for (final index in currentlyOwned) {
      if (master._workable(index) && state.hexes[index].owner == owner) {
        master._data[index].currentlyOwned = true;
      }
    }
  }

  void _updateMoneyStats() {
    final current = province;
    if (current == null) {
      money = 0;
      income = 0;
      profit = -9999;
      return;
    }
    money = current.money;
    income = engine.income(current);
    profit = engine.balance(current);
  }

  void _updateAverageAttractiveness() {
    final current = province;
    if (current == null || current.tiles.isEmpty) {
      averageAttractiveness = 0;
      return;
    }
    averageAttractiveness =
        current.tiles.fold<double>(
          0,
          (sum, index) => sum + master._data[index].attractiveness,
        ) /
        current.tiles.length;
  }

  void _updatePerimeter() {
    firstLine.clear();
    secondLine.clear();
    adjacentNeutral.clear();
    final current = province;
    if (current == null) return;
    for (final index in current.tiles) {
      final data = master._data[index];
      data
        ..firstLine = false
        ..secondLine = false;
      if (_isFirstLine(index)) {
        data.firstLine = true;
        firstLine.add(index);
      }
    }
    for (final index in current.tiles) {
      if (master._data[index].firstLine) continue;
      if (state.hexes[index].neighbors.any(
        (neighbor) =>
            state.hexes[neighbor].owner == owner &&
            master._data[neighbor].firstLine,
      )) {
        master._data[index].secondLine = true;
        secondLine.add(index);
      }
    }
    final seenNeutral = <int>{};
    for (final index in current.tiles) {
      for (final neighbor in state.hexes[index].neighbors) {
        if (!master._workable(neighbor) || state.hexes[neighbor].owner >= 0) {
          continue;
        }
        if (seenNeutral.add(neighbor)) adjacentNeutral.add(neighbor);
      }
    }
  }

  bool _isFirstLine(int index) => state.hexes[index].neighbors.any((neighbor) {
    if (!master._workable(neighbor)) return false;
    final other = state.hexes[neighbor];
    return other.owner >= 0 && other.owner != owner;
  });

  void _updateImportance() {
    final current = province;
    if (current == null) return;
    for (final index in current.tiles) {
      master._data[index].importance = 0;
    }
    final farms = current.tiles
        .where((index) => state.hexes[index].object == TileObject.farm)
        .toList(growable: false);
    final remaining = <int, int>{for (final index in farms) index: 4};
    final queue = <int>[...farms];
    for (final index in farms) {
      master._data[index].importance = 4;
    }
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final source = queue[cursor];
      final value = remaining[source]!;
      if (value == 0) continue;
      for (final neighbor in state.hexes[source].neighbors) {
        if (!master._workable(neighbor) ||
            state.hexes[neighbor].owner != owner ||
            remaining.containsKey(neighbor)) {
          continue;
        }
        remaining[neighbor] = value - 1;
        master._data[neighbor].importance = value - 1;
        queue.add(neighbor);
      }
    }
  }

  void _updateSolidDefense() {
    final current = province;
    if (current == null) return;
    for (final index in current.tiles) {
      master._data[index].solidDefense = 0;
    }
    for (final index in current.tiles) {
      final defense = switch (state.hexes[index].object) {
        TileObject.town => 1,
        TileObject.tower => 2,
        TileObject.strongTower => 3,
        _ => 0,
      };
      if (defense == 0) continue;
      for (final target in [index, ...state.hexes[index].neighbors]) {
        if (!master._workable(target) || state.hexes[target].owner != owner) {
          continue;
        }
        master._data[target].solidDefense = math.max(
          master._data[target].solidDefense,
          defense,
        );
      }
    }
  }

  void _updateVicinity() {
    if (adjacentNeutral.isEmpty) return;
    var maximum = 0;
    for (final index in adjacentNeutral) {
      final count = master
          ._propagate(
            [index],
            3,
            allowed: (_, destination) =>
                master._data[destination].currentlyOwned,
          )
          .where((item) => master._data[item].currentlyOwned)
          .length;
      master._data[index].ownedLandsNearby = count;
      maximum = math.max(maximum, count);
    }
    if (maximum == 0) return;
    for (final index in adjacentNeutral) {
      master._data[index].vicinity =
          master._data[index].ownedLandsNearby / maximum;
    }
  }

  List<int> _readyUnits() {
    final current = province;
    if (current == null) return const [];
    return current.tiles
        .where((index) => state.hexes[index].unit?.ready == true)
        .toList(growable: false);
  }

  bool _move(int from, int to) {
    if (!engine.moveUnit(from, to)) return false;
    if (state.hexes[to].owner == owner) currentlyOwned.add(to);
    _refreshAfterMutation();
    return true;
  }

  bool _buy(int target, int strength) {
    final current = province;
    if (current == null || !engine.buyUnit(current.id, target, strength)) {
      return false;
    }
    if (state.hexes[target].owner == owner) currentlyOwned.add(target);
    _refreshAfterMutation();
    return true;
  }

  bool _build(int target, TileObject object) {
    final current = province;
    if (current == null || !engine.build(current.id, target, object)) {
      return false;
    }
    _refreshAfterMutation();
    return true;
  }

  void _mergePeasantsBeforePlanning() {
    if (adjacentNeutral.length > firstLine.length) return;
    final current = province;
    if (current == null) return;
    final units = current.tiles
        .where((index) => state.hexes[index].unit != null)
        .toList();
    final peasants = units
        .where((index) => state.hexes[index].unit!.strength == 1)
        .length;
    final others = units.length - peasants;
    if (peasants < 5) return;
    final merges = math.min(3, peasants - 2 * others);
    if (merges <= 0) return;
    for (var attempt = 0; attempt < merges; attempt++) {
      var merged = false;
      for (final from in _readyUnits()) {
        if (state.hexes[from].unit?.strength != 1) continue;
        final targets =
            engine
                .moveTargets(from)
                .where(
                  (to) =>
                      state.hexes[to].owner == owner &&
                      state.hexes[to].unit?.ready == true &&
                      state.hexes[to].unit?.strength == 1,
                )
                .toList()
              ..sort();
        if (targets.isEmpty) continue;
        merged = _move(from, targets.first);
        if (merged) break;
      }
      if (!merged) break;
    }
  }

  bool canAffordTaxChange(int taxChange) {
    if (money > 500) return taxChange < profit + 50;
    if (money > 200) return taxChange < profit + 20;
    return taxChange < profit - 7;
  }

  int predictTaxChangeFromMerge(int first, int second) =>
      -engine.unitUpkeepAtStrength(first) -
      engine.unitUpkeepAtStrength(second) +
      engine.unitUpkeepAtStrength(first + second);

  int necessaryStrength(int target) {
    final defense = engine.defenseAt(target);
    if (defense == 4) return state.config.slayRules ? -1 : 4;
    return defense + 1;
  }

  bool canAttackOwner(int other) =>
      other != owner && (other < 0 || engine.areEnemies(owner, other));

  bool _isEmpty(int index) =>
      state.hexes[index].unit == null &&
      state.hexes[index].object == TileObject.none;

  bool _hasSupportiveTower(int index) =>
      [index, ...state.hexes[index].neighbors].any(
        (item) =>
            master._workable(item) &&
            state.hexes[item].owner == owner &&
            (state.hexes[item].object == TileObject.tower ||
                state.hexes[item].object == TileObject.strongTower),
      );

  double currentAttractiveness(int index) {
    final friendly = state.hexes[index].neighbors
        .where((neighbor) => state.hexes[neighbor].owner == owner)
        .length;
    if (friendly > 3) return 1;
    if (_hasSupportiveTower(index)) {
      return master._data[index].attractiveness + 0.4;
    }
    return master._data[index].attractiveness +
        0.2 * master._data[index].vicinity;
  }

  bool _trySingleAction() {
    _updatePerimeter();
    final choices = <_ScoredChoice<_MasterAction>>[];
    final current = province;
    if (current == null) return false;

    if (current.tiles.any((index) => state.hexes[index].hasTree) &&
        _canAnyTreeBeCut()) {
      final palms = current.tiles
          .where((index) => state.hexes[index].object == TileObject.palm)
          .length;
      final pines = current.tiles
          .where((index) => state.hexes[index].object == TileObject.pine)
          .length;
      choices.add(
        _ScoredChoice(_MasterAction.cutTree, 0.5 + 2 * palms + pines),
      );
    }
    if (adjacentNeutral.isNotEmpty) {
      final thirst = adjacentNeutral.length < 3
          ? 0.0
          : 0.5 + 0.3 * adjacentNeutral.length;
      choices.add(_ScoredChoice(_MasterAction.peacefullyExpand, thirst));
    }
    choices.add(_ScoredChoice(_MasterAction.attack, attackManager.thirst()));
    if (current.tiles.length > 6) {
      choices.add(_ScoredChoice(_MasterAction.defend, defenseManager.thirst()));
    }
    _ScoredChoice<_MasterAction>? best;
    for (final choice in choices) {
      if (best == null || choice.thirst > best.thirst) best = choice;
    }
    if (best == null || best.thirst < 1) return false;
    return switch (best.value) {
      _MasterAction.cutTree => _cutTree(),
      _MasterAction.peacefullyExpand => _peacefullyExpand(),
      _MasterAction.attack => attackManager.perform(),
      _MasterAction.defend => defenseManager.perform(),
    };
  }

  bool _canAnyTreeBeCut() {
    for (final from in _readyUnits()) {
      final unit = state.hexes[from].unit!;
      if (unit.strength > 2) continue;
      if (engine.moveTargets(from).any((to) => state.hexes[to].hasTree)) {
        return true;
      }
    }
    return false;
  }

  bool _cutTree() {
    final current = province;
    if (current == null) return false;
    for (final tree in current.tiles.where(
      (index) => state.hexes[index].hasTree,
    )) {
      for (final from in _readyUnits()) {
        if (engine.moveTargets(from).contains(tree)) return _move(from, tree);
      }
    }
    return false;
  }

  bool _peacefullyExpand() {
    for (final from in _readyUnits()) {
      final unit = state.hexes[from].unit!;
      if (unit.strength > 2) continue;
      final overall = _bestPeacefulHex(adjacentNeutral, unit.strength);
      if (overall == null) break;
      if (engine.moveTargets(from).contains(overall)) {
        return _move(from, overall);
      }
      final localNeutral = engine
          .moveTargets(from)
          .where((index) => state.hexes[index].owner < 0)
          .toList(growable: false);
      final local = _bestPeacefulHex(localNeutral, unit.strength);
      if (local != null &&
          currentAttractiveness(local) > 0.5 * currentAttractiveness(overall)) {
        return _move(from, local);
      }
      final ownedNeighbor = state.hexes[overall].neighbors
          .where((index) => currentlyOwned.contains(index))
          .firstOrNull;
      if (ownedNeighbor != null && _marchSingleUnit(from, ownedNeighbor)) {
        return true;
      }
      return false;
    }

    if (money >= 100) {
      final defended = adjacentNeutral
          .where((index) => engine.defenseAt(index) > 0)
          .toList(growable: false);
      if (defended.isNotEmpty) {
        final target = defended[master._random.nextInt(defended.length)];
        final strength = necessaryStrength(target);
        if (strength > 0 && _buy(target, strength)) return true;
      }
    }
    final current = province;
    if (current == null) return false;
    var changed = false;
    while (current.money >= mod.rules.unitPricePerLevel) {
      final tree = _worstTree();
      if (tree == null || !_buy(tree, 1)) break;
      changed = true;
    }
    return changed;
  }

  int? _bestPeacefulHex(Iterable<int> candidates, int strength) {
    final current = province;
    if (current == null) return null;
    final legal = candidates
        .where(
          (index) =>
              !currentlyOwned.contains(index) &&
              engine.defenseAt(index) <= strength - 1,
        )
        .toList(growable: false);
    if (legal.isEmpty) return null;
    final closestDistance = legal
        .map((index) => master._distance(index, current.capital))
        .reduce(math.min);
    final filtered = legal
        .where(
          (index) =>
              master._distance(index, current.capital) <
              math.max(1, 3 * closestDistance),
        )
        .toList(growable: false);
    final pool = filtered.isEmpty ? legal : filtered;
    int? best;
    var bestValue = 0.0;
    for (final index in pool) {
      final value = currentAttractiveness(index);
      if (best == null || value > bestValue) {
        best = index;
        bestValue = value;
      }
    }
    return best;
  }

  bool _trySingleSpending() {
    _updateMoneyStats();
    final defenseThirst = defenseManager.thirst();
    final thirsts = <_MasterSpending, double>{};
    for (final spending in _MasterSpending.values) {
      if (!_spendingValid(spending)) continue;
      thirsts[spending] = _spendingThirst(spending);
    }

    if (_needsToSaveForNormalTower()) {
      for (final key in thirsts.keys.toList()) {
        thirsts[key] = 0;
      }
      if (_spendingValid(_MasterSpending.tower1)) {
        thirsts[_MasterSpending.tower1] = 2;
      }
    }
    if (defenseThirst >= 5) {
      for (final key in thirsts.keys.toList()) {
        thirsts[key] = 0;
      }
    }

    _MasterSpending? best;
    var bestThirst = 0.0;
    for (final spending in _MasterSpending.values) {
      final thirst = thirsts[spending];
      if (thirst == null) continue;
      if (best == null || thirst > bestThirst) {
        best = spending;
        bestThirst = thirst;
      }
    }
    if (best == null || bestThirst < 1) return false;
    return _applySpending(best);
  }

  bool _spendingValid(_MasterSpending spending) {
    final current = province;
    if (current == null) return false;
    return switch (spending) {
      _MasterSpending.unit1 =>
        current.money >= mod.rules.unitPricePerLevel &&
            engine.unitBuildTargets(current.id, 1).isNotEmpty,
      _MasterSpending.unit2 =>
        current.money >= 2 * mod.rules.unitPricePerLevel &&
            engine.unitBuildTargets(current.id, 2).isNotEmpty,
      _MasterSpending.unit3 =>
        current.money >= 3 * mod.rules.unitPricePerLevel &&
            engine.unitBuildTargets(current.id, 3).isNotEmpty,
      _MasterSpending.unit4 =>
        current.money >= 4 * mod.rules.unitPricePerLevel &&
            engine.unitBuildTargets(current.id, 4).isNotEmpty,
      _MasterSpending.farm =>
        !state.config.slayRules &&
            engine.buildTargets(current.id, TileObject.farm).isNotEmpty,
      _MasterSpending.tower1 =>
        engine.buildTargets(current.id, TileObject.tower).isNotEmpty,
      _MasterSpending.tower2 =>
        !state.config.slayRules &&
            engine.buildTargets(current.id, TileObject.strongTower).isNotEmpty,
    };
  }

  double _spendingThirst(_MasterSpending spending) {
    final current = province;
    if (current == null) return 0;
    switch (spending) {
      case _MasterSpending.unit1:
        if (current.tiles.length < 5) return 2;
        if (profit < engine.unitUpkeepAtStrength(1)) return 0;
        final peasants = _countUnits(1);
        return math.max(
          3.5 - peasants,
          0.5 * adjacentNeutral.length - peasants,
        );
      case _MasterSpending.unit2:
        // Classic's source intentionally leaves unit2-4 thirst at zero after
        // the tax gate. Those strengths are acquired by attack/defense logic.
        if (profit < engine.unitUpkeepAtStrength(2)) return 0;
        return 0;
      case _MasterSpending.unit3:
        if (profit < engine.unitUpkeepAtStrength(3)) return 0;
        return 0;
      case _MasterSpending.unit4:
        if (profit < engine.unitUpkeepAtStrength(4)) return 0;
        return 0;
      case _MasterSpending.farm:
        if (profit > 120) return 0;
        if (averageAttractiveness < 0.4 &&
            firstLine.isEmpty &&
            _countUnits(null) < 8) {
          return 0;
        }
        final targetQuantity = math.max(10, 0.7 * current.tiles.length).toInt();
        final targetProfit = money > 2 * engine.farmPrice(current) ? 80 : 50;
        final overkill = math.max(0, profit - targetProfit);
        return 0.5 + targetQuantity - _countObjects(TileObject.farm) - overkill;
      case _MasterSpending.tower1:
        if (profit < mod.rules.towerUpkeep) return 0;
        final urgent = _countHexesThatReallyNeedTower();
        if (urgent > 0) return 2.0 + 3 * urgent;
        return 0.5 +
            _countSuitableTowers(firstLine, 2) +
            2 * _countSuitableTowers(secondLine, 2);
      case _MasterSpending.tower2:
        if (profit < mod.rules.strongTowerUpkeep ||
            _countObjects(TileObject.tower) == 0 ||
            money < mod.rules.strongTowerPrice + 10) {
          return 0;
        }
        return 0.5 + 0.7 * _countImportantNormalTowers();
    }
  }

  bool _applySpending(_MasterSpending spending) => switch (spending) {
    _MasterSpending.unit1 => _buildUnitSpending(1),
    _MasterSpending.unit2 => _buildUnitSpending(2),
    _MasterSpending.unit3 => _buildUnitSpending(3),
    _MasterSpending.unit4 => _buildUnitSpending(4),
    _MasterSpending.farm => _buildFarmSpending(),
    _MasterSpending.tower1 => _buildTowerSpending(2),
    _MasterSpending.tower2 => _buildTowerSpending(3),
  };

  bool _buildUnitSpending(int strength) {
    final current = province;
    if (current == null) return false;
    int? target;
    if (current.tiles.any((index) => state.hexes[index].hasTree)) {
      target = _worstTree();
    }
    target ??= _bestPeacefulHex(adjacentNeutral, strength);
    if (target != null && state.hexes[target].unit != null) target = null;
    target ??= _randomEmpty(firstLine);
    target ??= _randomEmpty(current.tiles);
    return target != null && _buy(target, strength);
  }

  int? _worstTree() {
    final current = province;
    if (current == null) return null;
    int? best;
    for (final index in current.tiles.where(
      (index) => state.hexes[index].hasTree,
    )) {
      if (best == null ||
          master._data[index].attractiveness >
              master._data[best].attractiveness) {
        best = index;
      }
    }
    return best;
  }

  int? _randomEmpty(Iterable<int> indexes) {
    final values = indexes.where(_isEmpty).toList(growable: false);
    if (values.isEmpty) return null;
    return values[master._random.nextInt(values.length)];
  }

  bool _buildFarmSpending() {
    final current = province;
    if (current == null) return false;
    final candidates = engine.buildTargets(current.id, TileObject.farm);
    int? best;
    var maximum = 0.0;
    for (final index in candidates) {
      var value = master._data[index].attractiveness;
      if (master._data[index].firstLine) value *= 0.5;
      if (best == null || value > maximum) {
        best = index;
        maximum = value;
      }
    }
    return best != null && _build(best, TileObject.farm);
  }

  bool _buildTowerSpending(int defense) {
    final current = province;
    if (current == null) return false;
    if (defense == 3) {
      final towers = current.tiles
          .where((index) => state.hexes[index].object == TileObject.tower)
          .toList(growable: false);
      int? best;
      for (final index in towers.where(_importantEnoughForStrongTower)) {
        if (best == null ||
            master._data[index].importance > master._data[best].importance) {
          best = index;
        }
      }
      best ??= towers
          .where(
            (index) =>
                (master._data[index].firstLine ||
                    master._data[index].secondLine) &&
                _friendlyNeighborCount(index) >= 4,
          )
          .firstOrNull;
      return best != null && _build(best, TileObject.strongTower);
    }
    final second = _bestTowerHex(secondLine, defense);
    if (second != null) return _build(second, TileObject.tower);
    final first = _bestTowerHex(firstLine, defense);
    return first != null && _build(first, TileObject.tower);
  }

  int? _bestTowerHex(Iterable<int> indexes, int defense) {
    int? best;
    for (final index in indexes.where(
      (index) => _suitableTower(index, defense),
    )) {
      if (best == null ||
          master._data[index].importance > master._data[best].importance) {
        best = index;
      }
    }
    return best;
  }

  bool _suitableTower(int index, int targetDefense) {
    if (!_isEmpty(index) || master._data[index].solidDefense >= targetDefense) {
      return false;
    }
    if (engine.defenseAt(index) < 2 && master._data[index].firstLine) {
      return true;
    }
    return _balancerTowerGain(index) >= 5;
  }

  int _balancerTowerGain(int index) {
    var gain = _isDefendedByTower(index) ? 0 : 1;
    for (final neighbor in state.hexes[index].neighbors) {
      if (state.hexes[neighbor].owner == owner &&
          !_isDefendedByTower(neighbor)) {
        gain++;
      }
      if (state.hexes[neighbor].object == TileObject.tower ||
          state.hexes[neighbor].object == TileObject.strongTower) {
        gain--;
      }
    }
    return gain;
  }

  bool _isDefendedByTower(int index) => _hasSupportiveTower(index);

  int _countUnits(int? strength) {
    final current = province;
    if (current == null) return 0;
    return current.tiles.where((index) {
      final unit = state.hexes[index].unit;
      return unit != null && (strength == null || unit.strength == strength);
    }).length;
  }

  int _countObjects(TileObject object) {
    final current = province;
    if (current == null) return 0;
    return current.tiles
        .where((index) => state.hexes[index].object == object)
        .length;
  }

  int _countSuitableTowers(Iterable<int> indexes, int defense) =>
      indexes.where((index) => _suitableTower(index, defense)).length;

  int _countHexesThatReallyNeedTower() =>
      [...firstLine, ...secondLine].where(_reallyNeedsTower).length;

  bool _reallyNeedsTower(int index) =>
      engine.defenseAt(index) <= 1 && master._data[index].importance >= 3;

  int _countImportantNormalTowers() {
    final current = province;
    if (current == null) return 0;
    return current.tiles
        .where(
          (index) =>
              state.hexes[index].object == TileObject.tower &&
              _importantEnoughForStrongTower(index),
        )
        .length;
  }

  bool _importantEnoughForStrongTower(int index) =>
      !_hasAdjacentStrongTower(index) &&
      (master._data[index].firstLine || master._data[index].secondLine) &&
      master._data[index].importance > 1.5;

  bool _hasAdjacentStrongTower(int index) =>
      [index, ...state.hexes[index].neighbors].any(
        (item) =>
            master._workable(item) &&
            state.hexes[item].owner == owner &&
            state.hexes[item].object == TileObject.strongTower,
      );

  int _friendlyNeighborCount(int index) => state.hexes[index].neighbors
      .where((neighbor) => state.hexes[neighbor].owner == owner)
      .length;

  bool _needsToSaveForNormalTower() {
    final whole = firstLine.length + secondLine.length;
    if (whole == 0) return false;
    final undefended = [
      ...firstLine,
      ...secondLine,
    ].where((index) => !_hasSupportiveTower(index)).length;
    return undefended > whole / 3;
  }

  void _casualGrab() {
    final ready = _readyUnits();
    for (final from in ready.reversed) {
      final unit = state.hexes[from].unit;
      if (unit?.ready != true) continue;
      final targets = engine.moveTargets(from).toList(growable: false);
      final tree = targets
          .where(
            (index) =>
                state.hexes[index].owner == owner && state.hexes[index].hasTree,
          )
          .firstOrNull;
      if (tree != null) {
        _move(from, tree);
        continue;
      }
      final attack = targets
          .where(
            (index) =>
                state.hexes[index].owner != owner &&
                unit!.strength > engine.defenseAt(index),
          )
          .firstOrNull;
      if (attack != null) _move(from, attack);
    }
  }

  void _pullUnitsToPerimeter() {
    final current = province;
    if (current == null) return;
    for (final from in current.tiles.toList(growable: false)) {
      if (master._data[from].firstLine || master._data[from].secondLine) {
        continue;
      }
      if (state.hexes[from].unit?.ready != true) continue;
      int? target;
      if (firstLine.isNotEmpty) {
        target = firstLine.reduce(
          (a, b) =>
              master._distance(from, a) <= master._distance(from, b) ? a : b,
        );
      } else {
        final nearNeutral = current.tiles
            .where(
              (index) => state.hexes[index].neighbors.any(
                (neighbor) => state.hexes[neighbor].owner < 0,
              ),
            )
            .toList(growable: false);
        if (nearNeutral.isNotEmpty) {
          target = nearNeutral.reduce(
            (a, b) =>
                master._distance(from, a) <= master._distance(from, b) ? a : b,
          );
        }
      }
      if (target != null) _marchSingleUnit(from, target);
    }
  }

  bool _marchSingleUnit(int from, int target) {
    final candidates =
        engine
            .moveTargets(from)
            .where(
              (index) =>
                  state.hexes[index].owner == owner &&
                  state.hexes[index].unit == null &&
                  (state.hexes[index].object == TileObject.none ||
                      state.hexes[index].hasTree),
            )
            .toList()
          ..sort((a, b) {
            final distance = master
                ._distance(a, target)
                .compareTo(master._distance(b, target));
            return distance != 0 ? distance : a.compareTo(b);
          });
    return candidates.isNotEmpty && _move(from, candidates.first);
  }

  void _supplyArmyWithTowers() {
    final current = province;
    if (current == null || _maximumUnitStrength() < 2) return;
    for (var guard = 0; guard < current.tiles.length; guard++) {
      final latest = province;
      if (latest == null || latest.money < mod.rules.towerPrice) break;
      final buildable = engine.buildTargets(latest.id, TileObject.tower);
      if (buildable.isEmpty) break;
      final predecessors = _pathPredecessors(latest.capital);
      for (final data in master._data) {
        data.dependentUnits.clear();
      }
      for (final unitIndex in latest.tiles.where(
        (index) => (state.hexes[index].unit?.strength ?? 0) > 1,
      )) {
        var cursor = unitIndex;
        final strength = state.hexes[unitIndex].unit!.strength;
        while (predecessors[cursor] != null) {
          cursor = predecessors[cursor]!;
          master._data[cursor].dependentUnits.add(strength);
        }
      }
      final vulnerable = buildable
          .where((index) {
            if (master._data[index].dependentUnits.isEmpty) return false;
            if (!_hasEnemyLandNearby(index) || _hasSupportiveTower(index)) {
              return false;
            }
            return true;
          })
          .toList(growable: false);
      if (vulnerable.isEmpty) break;
      vulnerable.sort((a, b) {
        final first = master._data[b].dependentUnits
            .fold<int>(0, (sum, value) => sum + value)
            .compareTo(
              master._data[a].dependentUnits.fold<int>(
                0,
                (sum, value) => sum + value,
              ),
            );
        if (first != 0) return first;
        final gain = _balancerTowerGain(b).compareTo(_balancerTowerGain(a));
        return gain != 0 ? gain : a.compareTo(b);
      });
      if (!_build(vulnerable.first, TileObject.tower)) break;
    }
  }

  Map<int, int?> _pathPredecessors(int start) {
    final result = <int, int?>{start: null};
    final queue = <int>[start];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final source = queue[cursor];
      for (final neighbor in state.hexes[source].neighbors) {
        if (result.containsKey(neighbor) ||
            state.hexes[neighbor].owner != owner ||
            !currentlyOwned.contains(neighbor)) {
          continue;
        }
        result[neighbor] = source;
        queue.add(neighbor);
      }
    }
    return result;
  }

  int _maximumUnitStrength() {
    final current = province;
    if (current == null) return 0;
    return current.tiles.fold<int>(
      0,
      (maximum, index) =>
          math.max(maximum, state.hexes[index].unit?.strength ?? 0),
    );
  }

  bool _hasEnemyLandNearby(int index) => state.hexes[index].neighbors.any(
    (neighbor) =>
        master._workable(neighbor) &&
        state.hexes[neighbor].owner >= 0 &&
        state.hexes[neighbor].owner != owner,
  );

  void _pushUnitsToBetterDefense() {
    for (final from in _readyUnits()) {
      final unit = state.hexes[from].unit;
      if (unit?.ready != true) continue;
      for (final target in state.hexes[from].neighbors) {
        if (state.hexes[target].owner != owner || !_isEmpty(target)) continue;
        if (_predictedDefenseGainWithUnit(target, unit!.strength) < 3) {
          continue;
        }
        if (_move(from, target)) break;
      }
    }
  }

  int _predictedDefenseGainWithUnit(int target, int strength) {
    var change = strength - engine.defenseAt(target);
    // This intentionally mirrors Classic's implementation, including its use
    // of the source-neighborhood concept; the local target is the only stable
    // coordinate after rebuilds, so adjacent friendly hexes are equivalent.
    for (final neighbor in state.hexes[target].neighbors) {
      if (state.hexes[neighbor].owner != owner) continue;
      change += strength - engine.defenseAt(neighbor);
    }
    return change;
  }

  int defenseGainPrediction(int index, int targetDefense) {
    var gain = master._data[index].solidDefense < targetDefense ? 1 : 0;
    for (final neighbor in state.hexes[index].neighbors) {
      if (!master._workable(neighbor)) {
        gain++;
        continue;
      }
      if (state.hexes[neighbor].owner != owner) continue;
      if (_hasSupportiveTower(neighbor)) gain--;
      if (master._data[neighbor].importance > 0) {
        gain += master._data[neighbor].importance ~/ 2;
      }
      if (master._data[neighbor].solidDefense < targetDefense) gain++;
    }
    return gain;
  }
}

class _MasterAttackManager {
  _MasterAttackManager(this.session);

  final _MasterProvinceSession session;
  bool cannotCover = false;
  final List<int> firstAttackLine = <int>[];
  final List<int> secondAttackLine = <int>[];
  final List<Province> nearbyProvinces = <Province>[];
  int? mostTastefulHex;
  Province? mostTastefulProvince;

  GameState get state => session.state;
  GameEngine get engine => session.engine;
  ClassicMasterAi get master => session.master;

  void onTurnStarted() {
    cannotCover = false;
  }

  double thirst() {
    if (cannotCover) return 0;
    _update();
    final target = mostTastefulHex;
    if (target == null) return 0;
    if (master._data[target].tastiness < 0.25 && session.money < 60) {
      return 0;
    }
    if (session.firstLine.length + session.secondLine.length >
        session.adjacentNeutral.length) {
      return 2;
    }
    return 0;
  }

  bool perform() {
    _update();
    final target = mostTastefulHex;
    if (target == null) return false;
    _applyArmyPresenceToAttackLine();
    final entry = _entryHex(target);
    if (entry == null) return false;
    final magnet = _magnetHex(entry);
    if (magnet == null) return false;
    if (!_ensureCover(magnet)) {
      cannotCover = true;
      return false;
    }

    var changed = false;
    for (final index in _attackPattern(magnet, entry, target)) {
      if (!_adjacentToCurrentlyOwned(index)) continue;
      if (_capture(index)) changed = true;
    }
    session._casualGrab();
    _pullUnitsToReadyArea(magnet);
    return changed;
  }

  void _update() {
    mostTastefulHex = null;
    _grabFreeLands();
    _updateArmyPresence();
    _updateAttackLines();
    _updateNearbyProvinces();
    _updateMostTastefulProvince();
    final targetProvince = mostTastefulProvince;
    if (targetProvince == null) return;
    for (final index in targetProvince.tiles) {
      if (master._data[index].attack1) {
        master._data[index].tastiness = 0.5 * _tileTastiness(index);
      }
      if (master._data[index].attack2) {
        master._data[index].tastiness = _tileTastiness(index);
      }
      if (!master._data[index].attack1 && !master._data[index].attack2) {
        continue;
      }
      final current = mostTastefulHex;
      if (current == null ||
          master._data[index].tastiness > master._data[current].tastiness) {
        mostTastefulHex = index;
      }
    }
  }

  void _grabFreeLands() {
    _updateAttackLines();
    if (!firstAttackLine.any((index) => engine.defenseAt(index) == 0)) {
      return;
    }
    for (final from in session._readyUnits().reversed) {
      final unit = state.hexes[from].unit;
      if (unit?.strength != 1 || unit?.ready != true) continue;
      final target = engine.moveTargets(from).where((index) {
        return master._data[index].attack1 &&
            engine.defenseAt(index) == 0 &&
            session.canAttackOwner(state.hexes[index].owner);
      }).firstOrNull;
      if (target != null) session._move(from, target);
    }
  }

  void _updateArmyPresence() {
    final current = session.province;
    if (current == null) return;
    for (final index in current.tiles) {
      master._data[index].armyPresence = 0;
    }
    const depth = 5;
    for (final unitIndex in session._readyUnits()) {
      final strength = state.hexes[unitIndex].unit!.strength;
      final distance = <int, int>{unitIndex: 0};
      final queue = <int>[unitIndex];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final source = queue[cursor];
        final steps = distance[source]!;
        final value = strength / (4 * depth) * (depth - steps);
        master._data[source].armyPresence = math.max(
          value,
          master._data[source].armyPresence,
        );
        if (steps == depth) continue;
        for (final neighbor in state.hexes[source].neighbors) {
          if (distance.containsKey(neighbor) ||
              state.hexes[neighbor].owner != session.owner) {
            continue;
          }
          distance[neighbor] = steps + 1;
          queue.add(neighbor);
        }
      }
    }
  }

  void _updateAttackLines() {
    firstAttackLine.clear();
    secondAttackLine.clear();
    for (final data in master._data) {
      data
        ..attack1 = false
        ..attack2 = false;
    }
    session._updatePerimeter();
    final firstSeen = <int>{};
    for (final owned in session.firstLine) {
      for (final target in state.hexes[owned].neighbors) {
        if (!master._workable(target) ||
            state.hexes[target].owner < 0 ||
            state.hexes[target].owner == session.owner ||
            !session.canAttackOwner(state.hexes[target].owner)) {
          continue;
        }
        master._data[target].attack1 = true;
        if (firstSeen.add(target)) firstAttackLine.add(target);
      }
    }
    final secondSeen = <int>{};
    for (final first in firstAttackLine) {
      for (final target in state.hexes[first].neighbors) {
        if (!master._workable(target) ||
            state.hexes[target].owner != state.hexes[first].owner ||
            master._data[target].attack1) {
          continue;
        }
        master._data[target].attack2 = true;
        if (secondSeen.add(target)) secondAttackLine.add(target);
      }
    }
  }

  void _updateNearbyProvinces() {
    nearbyProvinces.clear();
    for (final index in firstAttackLine) {
      final province = engine.provinceAt(index);
      if (province != null && !nearbyProvinces.contains(province)) {
        nearbyProvinces.add(province);
      }
    }
  }

  void _updateMostTastefulProvince() {
    mostTastefulProvince = null;
    Province? small;
    var minimumDefense = 0.0;
    final current = session.province;
    if (current == null) return;
    for (final candidate in nearbyProvinces) {
      if (6 * candidate.tiles.length >= current.tiles.length) continue;
      final defense = _averageDefense(candidate.tiles);
      if (small == null || defense < minimumDefense) {
        small = candidate;
        minimumDefense = defense;
      }
    }
    if (small != null) {
      mostTastefulProvince = small;
      return;
    }
    if (nearbyProvinces.isEmpty) return;
    final distances = <Province, int>{
      for (final candidate in nearbyProvinces)
        candidate: candidate.tiles
            .map((index) => master._distance(current.capital, index))
            .reduce(math.min),
    };
    final minimum = distances.values.reduce(math.min);
    final maximumAllowed = math.max((1.5 * minimum).ceil(), 5);
    var maximumTaste = 0.0;
    for (final candidate in nearbyProvinces.where(
      (province) => distances[province]! <= maximumAllowed,
    )) {
      final taste = _provinceTastiness(candidate);
      if (mostTastefulProvince == null || taste > maximumTaste) {
        mostTastefulProvince = candidate;
        maximumTaste = taste;
      }
    }
  }

  double _provinceTastiness(Province province) {
    final seeds = province.tiles
        .where((index) => master._data[index].attack1)
        .toList(growable: false);
    final slice = <int>{...seeds};
    final distance = <int, int>{for (final index in seeds) index: 0};
    final queue = <int>[...seeds];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final source = queue[cursor];
      if (distance[source] == 3) continue;
      for (final neighbor in state.hexes[source].neighbors) {
        if (distance.containsKey(neighbor) ||
            state.hexes[neighbor].owner != state.hexes[source].owner) {
          continue;
        }
        distance[neighbor] = distance[source]! + 1;
        slice.add(neighbor);
        queue.add(neighbor);
      }
    }
    if (slice.isEmpty) return 0;
    final defenseValue = 1 - _averageDefense(slice) / 4;
    final farms =
        slice
            .where((index) => state.hexes[index].object == TileObject.farm)
            .length /
        slice.length;
    final attractiveness =
        slice.fold<double>(
          0,
          (sum, index) => sum + master._data[index].attractiveness,
        ) /
        slice.length;
    return (defenseValue + farms + 2 * attractiveness) / 4;
  }

  double _averageDefense(Iterable<int> indexes) {
    final list = indexes.toList(growable: false);
    if (list.isEmpty) return 0;
    return (9 +
            list.fold<int>(0, (sum, index) => sum + engine.defenseAt(index))) /
        list.length;
  }

  double _tileTastiness(int index) {
    final current = session.province;
    if (current == null) return 0;
    final closest = current.tiles.reduce(
      (a, b) =>
          master._distance(a, index) <= master._distance(b, index) ? a : b,
    );
    var value = master._data[index].attractiveness;
    value += 3 * master._data[closest].armyPresence;
    value += 1 - engine.defenseAt(index) / 4;
    value += _supposedImportance(index);
    value += 2 * master._data[index].vicinity;
    if (state.hexes[index].object == TileObject.tower ||
        state.hexes[index].object == TileObject.strongTower) {
      value += 1;
    }
    return value / 9;
  }

  double _supposedImportance(int index) {
    final province = engine.provinceAt(index);
    if (province == null) return 0;
    final farms = province.tiles
        .where((item) => state.hexes[item].object == TileObject.farm)
        .toList(growable: false);
    final steps = farms.isEmpty
        ? 0
        : farms.map((farm) => master._distance(index, farm)).reduce(math.min);
    var value = math.max(0.0, 1 - steps / 5);
    if (state.hexes[index].object == TileObject.tower ||
        state.hexes[index].object == TileObject.strongTower) {
      value *= 3;
    }
    return math.min(1, value);
  }

  void _applyArmyPresenceToAttackLine() {
    for (final index in firstAttackLine) {
      final own = state.hexes[index].neighbors
          .where((neighbor) => master._data[neighbor].currentlyOwned)
          .toList(growable: false);
      if (own.isEmpty) continue;
      master._data[index].armyPresence =
          own.fold<double>(
            0,
            (sum, item) => sum + master._data[item].armyPresence,
          ) /
          own.length;
    }
  }

  int? _entryHex(int target) {
    if (master._data[target].attack1) return target;
    int? best;
    for (final neighbor in state.hexes[target].neighbors) {
      if (!master._data[neighbor].attack1) continue;
      if (best == null ||
          master._data[neighbor].armyPresence >
              master._data[best].armyPresence) {
        best = neighbor;
      }
    }
    return best;
  }

  int? _magnetHex(int entry) {
    int? best;
    for (final neighbor in state.hexes[entry].neighbors) {
      if (!master._data[neighbor].currentlyOwned) continue;
      if (best == null ||
          master._data[neighbor].armyPresence >
              master._data[best].armyPresence) {
        best = neighbor;
      }
    }
    return best;
  }

  List<int> _attackPattern(int magnet, int entry, int target) {
    final result = <int>[];
    void add(int index) {
      if (!result.contains(index) &&
          (master._data[index].attack1 || master._data[index].attack2)) {
        result.add(index);
      }
    }

    add(entry);
    add(target);
    void addSides(int source, int destination) {
      final neighbors = state.hexes[source].neighbors;
      final direction = neighbors.indexOf(destination);
      if (direction < 0 || neighbors.isEmpty) return;
      // Hex neighbor lists are generator-ordered. When imported maps do not
      // preserve directional slots this branch degrades to deterministic
      // adjacent candidates, while entry/target ordering remains official.
      for (final offset in const [-1, 1, -2, 2]) {
        add(neighbors[(direction + offset) % neighbors.length]);
      }
    }

    addSides(magnet, entry);
    if (entry != target) addSides(entry, target);
    return result;
  }

  bool _ensureCover(int magnet) {
    final current = session.province;
    if (current == null) return false;
    final predecessors = session._pathPredecessors(current.capital);
    final vulnerable = <int>[];
    var cursor = magnet;
    while (true) {
      if (session._isEmpty(cursor) &&
          !session._hasSupportiveTower(cursor) &&
          (master._data[cursor].firstLine || master._data[cursor].secondLine)) {
        vulnerable.add(cursor);
      }
      final previous = predecessors[cursor];
      if (previous == null) break;
      cursor = previous;
    }
    if (vulnerable.isEmpty) return true;
    vulnerable.sort((a, b) {
      final gain = session
          .defenseGainPrediction(b, 1)
          .compareTo(session.defenseGainPrediction(a, 1));
      return gain != 0 ? gain : a.compareTo(b);
    });
    final target = vulnerable.first;
    final reachable =
        session
            ._readyUnits()
            .where((from) => engine.moveTargets(from).contains(target))
            .toList()
          ..sort((a, b) {
            final strength = state.hexes[a].unit!.strength.compareTo(
              state.hexes[b].unit!.strength,
            );
            return strength != 0 ? strength : a.compareTo(b);
          });
    if (reachable.isNotEmpty) return session._move(reachable.first, target);
    if (current.money >= session.mod.rules.unitPricePerLevel) {
      final strength =
          current.money >= 2 * session.mod.rules.unitPricePerLevel &&
              session.canAffordTaxChange(engine.unitUpkeepAtStrength(2))
          ? 2
          : 1;
      if (session._buy(target, strength)) {
        state.hexes[target].unit?.ready = false;
        return true;
      }
    }
    return false;
  }

  bool _capture(int target) {
    final defense = engine.defenseAt(target) == 4
        ? 3
        : engine.defenseAt(target);
    final attackers = session
        ._readyUnits()
        .where((from) => engine.moveTargets(from).contains(target))
        .toList(growable: false);
    final strong =
        attackers
            .where((from) => state.hexes[from].unit!.strength > defense)
            .toList()
          ..sort((a, b) {
            final distance = master
                ._distance(b, target)
                .compareTo(master._distance(a, target));
            return distance != 0 ? distance : a.compareTo(b);
          });
    if (strong.isNotEmpty) return session._move(strong.first, target);
    if (_captureWithMerge(target, defense, attackers)) return true;
    if (_captureWithReinforcement(target, defense, attackers)) return true;
    final strength = defense + 1;
    final current = session.province;
    if (strength <= 4 &&
        current != null &&
        current.money >= strength * session.mod.rules.unitPricePerLevel &&
        session.canAffordTaxChange(engine.unitUpkeepAtStrength(strength) + 2)) {
      return session._buy(target, strength);
    }
    return false;
  }

  bool _captureWithMerge(int target, int defense, List<int> attackers) {
    for (final receiver in attackers) {
      final receiverStrength = state.hexes[receiver].unit!.strength;
      final candidates =
          session._readyUnits().where((other) {
            if (other == receiver) return false;
            final strength = state.hexes[other].unit!.strength;
            if (receiverStrength + strength > 4 ||
                receiverStrength + strength <= defense) {
              return false;
            }
            if (!engine.moveTargets(other).contains(receiver)) return false;
            return session.canAffordTaxChange(
              session.predictTaxChangeFromMerge(receiverStrength, strength) + 2,
            );
          }).toList()..sort((a, b) {
            final strength = state.hexes[a].unit!.strength.compareTo(
              state.hexes[b].unit!.strength,
            );
            if (strength != 0) return strength;
            return master
                ._distance(b, target)
                .compareTo(master._distance(a, target));
          });
      if (candidates.isEmpty || !session._move(candidates.first, receiver)) {
        continue;
      }
      return state.hexes[receiver].unit?.ready == true &&
          session._move(receiver, target);
    }
    return false;
  }

  bool _captureWithReinforcement(int target, int defense, List<int> attackers) {
    if (attackers.isEmpty) return false;
    final ordered = attackers.toList()
      ..sort((a, b) {
        final strength = state.hexes[b].unit!.strength.compareTo(
          state.hexes[a].unit!.strength,
        );
        return strength != 0 ? strength : a.compareTo(b);
      });
    final receiver = ordered.first;
    final receiverStrength = state.hexes[receiver].unit!.strength;
    final additional = defense - receiverStrength + 1;
    if (additional <= 0 || receiverStrength + additional > 4) return false;
    final current = session.province;
    if (current == null ||
        current.money < additional * session.mod.rules.unitPricePerLevel) {
      return false;
    }
    final taxChange =
        session.predictTaxChangeFromMerge(receiverStrength, additional) +
        engine.unitUpkeepAtStrength(additional);
    if (!session.canAffordTaxChange(taxChange + 2)) return false;
    final empty = engine
        .moveTargets(receiver)
        .where(
          (index) =>
              master._data[index].currentlyOwned && session._isEmpty(index),
        )
        .firstOrNull;
    if (empty == null || !session._buy(empty, additional)) return false;
    if (!session._move(empty, receiver)) return false;
    return state.hexes[receiver].unit?.ready == true &&
        session._move(receiver, target);
  }

  bool _adjacentToCurrentlyOwned(int index) => state.hexes[index].neighbors.any(
    (neighbor) => master._data[neighbor].currentlyOwned,
  );

  void _pullUnitsToReadyArea(int magnet) {
    final readyArea = <int>{magnet};
    final distance = <int, int>{magnet: 0};
    final queue = <int>[magnet];
    final limit = math.max(0, session.mod.rules.unitMoveLimit - 1);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final source = queue[cursor];
      if (distance[source] == limit) continue;
      for (final neighbor in state.hexes[source].neighbors) {
        if (distance.containsKey(neighbor) ||
            !master._data[neighbor].currentlyOwned) {
          continue;
        }
        distance[neighbor] = distance[source]! + 1;
        readyArea.add(neighbor);
        queue.add(neighbor);
      }
    }
    for (final from in session._readyUnits()) {
      if (readyArea.contains(from)) continue;
      session._marchSingleUnit(from, magnet);
    }
  }
}

class _MasterDefenseManager {
  _MasterDefenseManager(this.session);

  final _MasterProvinceSession session;
  final List<_DefenseGroup> groups = <_DefenseGroup>[];
  bool failure = false;

  GameState get state => session.state;
  GameEngine get engine => session.engine;
  ClassicMasterAi get master => session.master;

  void onTurnStarted() {
    _update();
    failure = false;
  }

  double thirst() {
    if (failure) return 0;
    final group = _mostDangerousGroup();
    if (group == null || group.danger <= 0.45) return 0;
    return 1.5 + 5 * group.danger;
  }

  bool perform() {
    final group = _mostDangerousGroup();
    if (group == null) return false;
    final success = _tryToCutOff(group) || _fightDirectly(group);
    if (!success) {
      failure = true;
      _update();
      return false;
    }
    if (_groupStillAlive(group)) _bringReinforcements(group);
    session._casualGrab();
    _update();
    return true;
  }

  void _update() {
    groups.clear();
    final adjacentEnemies = <int>{};
    for (final owned in session.firstLine) {
      for (final neighbor in state.hexes[owned].neighbors) {
        final tile = state.hexes[neighbor];
        if (!master._workable(neighbor) ||
            master._data[neighbor].currentlyOwned ||
            tile.owner < 0 ||
            tile.unit == null ||
            !session.canAttackOwner(tile.owner)) {
          continue;
        }
        adjacentEnemies.add(neighbor);
      }
    }
    final ungrouped = <int>{...adjacentEnemies};
    while (ungrouped.isNotEmpty) {
      final start = ungrouped.reduce(math.min);
      final owner = state.hexes[start].owner;
      final area = <int>[];
      final queue = <int>[start];
      ungrouped.remove(start);
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final source = queue[cursor];
        area.add(source);
        for (final neighbor in state.hexes[source].neighbors) {
          if (!ungrouped.contains(neighbor) ||
              state.hexes[neighbor].owner != owner ||
              state.hexes[neighbor].unit == null) {
            continue;
          }
          ungrouped.remove(neighbor);
          queue.add(neighbor);
        }
      }
      final group = _DefenseGroup(owner: owner, area: area);
      _analyze(group);
      groups.add(group);
    }
  }

  void _analyze(_DefenseGroup group) {
    group.maxStrength = group.area.fold<int>(
      0,
      (maximum, index) =>
          math.max(maximum, state.hexes[index].unit?.strength ?? 0),
    );
    group.averageStrength =
        group.area.fold<int>(
          0,
          (sum, index) => sum + (state.hexes[index].unit?.strength ?? 0),
        ) /
        group.area.length;
    final support = <int>{};
    final contact = <int>{};
    for (final index in group.area) {
      for (final neighbor in state.hexes[index].neighbors) {
        if (!master._workable(neighbor)) continue;
        if (state.hexes[neighbor].owner == group.owner &&
            state.hexes[neighbor].unit == null) {
          support.add(neighbor);
        }
        if (state.hexes[neighbor].owner == session.owner) contact.add(neighbor);
      }
    }
    group
      ..support.addAll(support)
      ..contact.addAll(contact);
    group.danger = _danger(group);
  }

  double _danger(_DefenseGroup group) {
    if (group.support.isEmpty) return 0;
    var coefficient = 0.25;
    final strongest = group.area
        .where(
          (index) => state.hexes[index].unit?.strength == group.maxStrength,
        )
        .length;
    if (strongest == 1) coefficient *= 0.8;
    final averageImportance = group.contact.isEmpty
        ? 0
        : group.contact.fold<double>(
                0,
                (sum, index) => sum + master._data[index].importance,
              ) /
              group.contact.length;
    if (averageImportance < 1) coefficient *= 0.9;
    if (group.area.length == 1 &&
        state.hexes[group.area.first].neighbors
                .where((neighbor) => master._data[neighbor].currentlyOwned)
                .length ==
            1) {
      coefficient *= 0.66;
    }
    return coefficient * group.maxStrength;
  }

  _DefenseGroup? _mostDangerousGroup() {
    _DefenseGroup? best;
    for (final group in groups) {
      if (best == null || group.danger > best.danger) best = group;
    }
    return best;
  }

  bool _tryToCutOff(_DefenseGroup group) {
    final entry = <int>{};
    for (final support in group.support) {
      for (final neighbor in state.hexes[support].neighbors) {
        if (master._data[neighbor].currentlyOwned) entry.add(neighbor);
      }
    }
    if (entry.isEmpty) return false;
    _updateArmyPresence();
    final entryHex = entry.reduce((a, b) {
      final first = master._data[a].armyPresence;
      final second = master._data[b].armyPresence;
      return first > second || (first == second && a < b) ? a : b;
    });
    final pattern = <int>{};
    final queue = <int>[entryHex];
    final seen = <int>{entryHex};
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final source = queue[cursor];
      for (final neighbor in state.hexes[source].neighbors) {
        if (seen.contains(neighbor) || !group.support.contains(neighbor)) {
          continue;
        }
        seen.add(neighbor);
        pattern.add(neighbor);
        queue.add(neighbor);
      }
    }
    if (pattern.length < group.support.length || pattern.length > 3) {
      return false;
    }
    final plan = <int>[];
    var requiredMoney = 0;
    var requiredTax = 0;
    final reserved = <int>{};
    for (final target in pattern) {
      final strength = session.necessaryStrength(target);
      if (strength < 1) return false;
      final ready =
          session
              ._readyUnits()
              .where(
                (from) =>
                    !reserved.contains(from) &&
                    state.hexes[from].unit!.strength >= strength &&
                    engine.moveTargets(from).contains(target),
              )
              .toList()
            ..sort(
              (a, b) => master
                  ._distance(b, target)
                  .compareTo(master._distance(a, target)),
            );
      if (ready.isNotEmpty) {
        reserved.add(ready.first);
        plan.add(ready.first);
      } else {
        plan.add(-strength);
        requiredMoney += strength * session.mod.rules.unitPricePerLevel;
        requiredTax += engine.unitUpkeepAtStrength(strength);
      }
    }
    final current = session.province;
    if (current == null ||
        current.money < requiredMoney ||
        session.profit < requiredTax) {
      return false;
    }
    var offset = 0;
    for (final target in pattern) {
      final source = plan[offset++];
      final success = source >= 0
          ? session._move(source, target)
          : session._buy(target, -source);
      if (!success) return false;
    }
    return true;
  }

  void _updateArmyPresence() {
    final current = session.province;
    if (current == null) return;
    for (final index in current.tiles) {
      master._data[index].armyPresence = 0;
    }
    const depth = 5;
    for (final start in session._readyUnits()) {
      final strength = state.hexes[start].unit!.strength;
      final distance = <int, int>{start: 0};
      final queue = <int>[start];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final source = queue[cursor];
        final steps = distance[source]!;
        master._data[source].armyPresence = math.max(
          master._data[source].armyPresence,
          strength / (4 * depth) * (depth - steps),
        );
        if (steps == depth) continue;
        for (final neighbor in state.hexes[source].neighbors) {
          if (distance.containsKey(neighbor) ||
              state.hexes[neighbor].owner != session.owner) {
            continue;
          }
          distance[neighbor] = steps + 1;
          queue.add(neighbor);
        }
      }
    }
  }

  bool _fightDirectly(_DefenseGroup group) {
    var changed = false;
    for (var guard = 0; guard < 1000; guard++) {
      final enemies =
          group.area.where((index) {
            final unit = state.hexes[index].unit;
            return state.hexes[index].owner == group.owner &&
                unit != null &&
                state.hexes[index].neighbors.any(
                  (neighbor) => master._data[neighbor].currentlyOwned,
                );
          }).toList()..sort((a, b) {
            final strength = state.hexes[b].unit!.strength.compareTo(
              state.hexes[a].unit!.strength,
            );
            return strength != 0 ? strength : a.compareTo(b);
          });
      if (enemies.isEmpty || state.hexes[enemies.first].unit!.strength == 1) {
        break;
      }
      final target = enemies.first;
      if (_fightDirect(target) ||
          _fightWithMerge(target) ||
          _fightWithReinforcement(target) ||
          _fightWithMoney(target)) {
        changed = true;
        continue;
      }
      break;
    }
    return changed;
  }

  List<int> _directAttackers(int target) => session
      ._readyUnits()
      .where((from) => engine.moveTargets(from).contains(target))
      .toList(growable: false);

  bool _fightDirect(int target) {
    final necessary = session.necessaryStrength(target);
    final attackers =
        _directAttackers(target)
            .where((from) => state.hexes[from].unit!.strength >= necessary)
            .toList()
          ..sort(
            (a, b) => master
                ._distance(b, target)
                .compareTo(master._distance(a, target)),
          );
    return attackers.isNotEmpty && session._move(attackers.first, target);
  }

  bool _fightWithMerge(int target) {
    final necessary = session.necessaryStrength(target);
    for (final receiver in _directAttackers(target)) {
      final first = state.hexes[receiver].unit!.strength;
      final owned = _mostImportantAdjacentOwned(target);
      final candidates =
          session._readyUnits().where((other) {
            if (other == receiver) return false;
            final second = state.hexes[other].unit!.strength;
            if (first + second < necessary || first + second > 4) return false;
            if (!engine.moveTargets(other).contains(receiver)) return false;
            final change = session.predictTaxChangeFromMerge(first, second);
            return _reallyNeedsDefense(owned) ||
                session.canAffordTaxChange(change);
          }).toList()..sort((a, b) {
            final strength = state.hexes[a].unit!.strength.compareTo(
              state.hexes[b].unit!.strength,
            );
            return strength != 0
                ? strength
                : master
                      ._distance(b, target)
                      .compareTo(master._distance(a, target));
          });
      if (candidates.isEmpty || !session._move(candidates.first, receiver)) {
        continue;
      }
      return session._move(receiver, target);
    }
    return false;
  }

  bool _fightWithReinforcement(int target) {
    final attackers = _directAttackers(target).toList()
      ..sort(
        (a, b) => state.hexes[b].unit!.strength.compareTo(
          state.hexes[a].unit!.strength,
        ),
      );
    if (attackers.isEmpty) return false;
    final receiver = attackers.first;
    final base = state.hexes[receiver].unit!.strength;
    final additional = session.necessaryStrength(target) - base;
    if (additional <= 0 || base + additional > 4) return false;
    final current = session.province;
    if (current == null ||
        current.money < additional * session.mod.rules.unitPricePerLevel) {
      return false;
    }
    final taxChange =
        session.predictTaxChangeFromMerge(base, additional) +
        engine.unitUpkeepAtStrength(additional);
    final important = _reallyNeedsDefense(_mostImportantAdjacentOwned(target));
    if (!important && !session.canAffordTaxChange(taxChange + 2)) return false;
    final empty = engine
        .moveTargets(receiver)
        .where(
          (index) =>
              master._data[index].currentlyOwned && session._isEmpty(index),
        )
        .firstOrNull;
    if (empty == null || !session._buy(empty, additional)) return false;
    if (!session._move(empty, receiver)) return false;
    return session._move(receiver, target);
  }

  bool _fightWithMoney(int target) {
    if (state.hexes[target].unit?.strength == 2) return false;
    final strength = session.necessaryStrength(target);
    if (strength < 1 || strength > 4) return false;
    final current = session.province;
    if (current == null ||
        current.money < strength * session.mod.rules.unitPricePerLevel) {
      return false;
    }
    final important = _reallyNeedsDefense(_mostImportantAdjacentOwned(target));
    if (!important &&
        !session.canAffordTaxChange(engine.unitUpkeepAtStrength(strength))) {
      return false;
    }
    return session._buy(target, strength);
  }

  int? _mostImportantAdjacentOwned(int target) {
    int? best;
    for (final neighbor in state.hexes[target].neighbors) {
      if (!master._data[neighbor].currentlyOwned) continue;
      if (best == null ||
          master._data[neighbor].importance > master._data[best].importance) {
        best = neighbor;
      }
    }
    return best;
  }

  bool _reallyNeedsDefense(int? index) =>
      index != null && master._data[index].importance > 2.5;

  bool _groupStillAlive(_DefenseGroup group) => group.area.any(
    (index) =>
        !master._data[index].currentlyOwned &&
        state.hexes[index].unit != null &&
        state.hexes[index].unit!.strength > 1,
  );

  void _bringReinforcements(_DefenseGroup group) {
    if (group.contact.isEmpty) return;
    final target = group.contact.reduce((a, b) {
      final first = _enemyStrengthNearby(a, group.owner);
      final second = _enemyStrengthNearby(b, group.owner);
      return first > second || (first == second && a < b) ? a : b;
    });
    for (final from in session._readyUnits()) {
      if (master._distance(from, target) < session.mod.rules.unitMoveLimit) {
        continue;
      }
      session._marchSingleUnit(from, target);
    }
  }

  int _enemyStrengthNearby(int index, int enemyOwner) => state
      .hexes[index]
      .neighbors
      .where((neighbor) => state.hexes[neighbor].owner == enemyOwner)
      .fold<int>(
        0,
        (sum, neighbor) => sum + (state.hexes[neighbor].unit?.strength ?? 0),
      );
}

class _DefenseGroup {
  _DefenseGroup({required this.owner, required this.area});

  final int owner;
  final List<int> area;
  final List<int> support = <int>[];
  final List<int> contact = <int>[];
  int maxStrength = 0;
  double averageStrength = 0;
  double danger = 0;
}

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
    if (bound <= 0) throw ArgumentError.value(bound, 'bound');
    if ((bound & -bound) == bound) {
      return ((BigInt.from(bound) * BigInt.from(_next(31))) >> 31).toInt();
    }
    while (true) {
      final bits = _next(31);
      final value = bits % bound;
      if (bits - value + bound - 1 < 1 << 31) return value;
    }
  }
}
