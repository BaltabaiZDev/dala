import 'dart:math' as math;

import '../modding/game_mod.dart';
import 'classic_master_ai.dart';
import 'diplomacy_ai.dart';
import 'game_engine.dart';
import 'models.dart';

typedef _AiAction = bool Function();

/// A difficulty-scaled strategic bot. Every player gets a deterministic
/// personality from its color and seed, so bots at the same tier still do not
/// execute an identical build order.
class GameAi {
  GameAi({required this.mod, required this.engine});

  final GameMod mod;
  final GameEngine engine;

  /// Units and fleets that existed at the beginning of the turn. Keeping an
  /// identity snapshot is important: a freshly bought unit/boat must not gain
  /// an action merely because the engine represents it as ready on an empty
  /// friendly tile.
  final Set<GameUnit> _turnLandUnits = <GameUnit>{};
  final Set<GameBoat> _turnBoats = <GameBoat>{};
  final Map<GameUnit, int> _landUnitLocations = <GameUnit, int>{};
  _JavaRandom? _turnRandom;
  int _landUnitsBuilt = 0;
  ClassicMasterTurnReport? lastClassicMasterReport;
  StrategicDiplomacyAi? lastDiplomacyReport;

  int get _tier => engine.state.config.difficulty.index;
  int get _personality {
    // Mix higher seed bits rather than `seed * 3 mod 6` (which used only its
    // parity). Consecutive colors still cover all six archetypes exactly once.
    final seed = engine.state.config.seed;
    final mixedSeed = (seed ^ (seed >> 7) ^ (seed >> 13)) & 0x7fffffff;
    final seedOffset = (mixedSeed + 2) % 6;
    return (engine.state.turn * 5 + seedOffset) % 6;
  }

  /// Stable strategic profile for this color: attacker, economist, guardian,
  /// admiral, engineer, or opportunist. Exposed for deterministic simulations.
  int get personalityId => _personality;

  bool get usesClassicMasterLand => ClassicMasterAi.shouldRunFor(engine.state);

  void takeTurn() {
    final state = engine.state;
    if (state.winner != null) return;
    _beginTurn();
    if (usesClassicMasterLand) {
      lastClassicMasterReport = ClassicMasterAi(
        mod: mod,
        engine: engine,
      ).perform();
      _moveExpeditionaryUnits();
      _retainStartingPieces();
    } else {
      lastClassicMasterReport = null;
      _runLandMovementPhase();
      if (state.winner != null) return;
      _runProvinceSpendingPhase();
      if (state.winner != null) return;
      _runCleanupPhase();
    }
    _runNewSystemsPhase();
    _manageDiplomacy();
    if (state.winner == null) engine.endTurn();
  }

  /// Runs the same deterministic strategy while regularly yielding back to
  /// Flutter's event loop. Large maps therefore keep animating and accepting
  /// frames instead of presenting one long synchronous AI stall.
  Future<void> takeTurnAsync({
    void Function(double progress)? onProgress,
    bool yieldBeforeWork = true,
  }) async {
    final state = engine.state;
    if (state.winner != null) return;
    _beginTurn();
    final frameBudget = Stopwatch()..start();
    onProgress?.call(.02);
    if (yieldBeforeWork) await _yieldFrame(frameBudget);
    if (state.winner != null) return;

    if (usesClassicMasterLand) {
      lastClassicMasterReport = await ClassicMasterAi(mod: mod, engine: engine)
          .performAsync(
            onProgress: (progress) => onProgress?.call(.04 + .61 * progress),
          );
      _moveExpeditionaryUnits();
      _retainStartingPieces();
    } else {
      lastClassicMasterReport = null;
      final startingUnits = _startingReadyLandUnits();
      for (var index = 0; index < startingUnits.length; index++) {
        _moveStartingUnit(startingUnits[index]);
        if (state.winner != null) return;
        onProgress?.call(
          .08 + .30 * (index + 1) / math.max(1, startingUnits.length),
        );
        if (_sliceExpired(frameBudget)) await _yieldFrame(frameBudget);
      }
      if (state.winner != null) return;

      final provinceIds = _provinceIdsForLandSpending();
      for (var index = 0; index < provinceIds.length; index++) {
        _spendAndMergeProvince(provinceIds[index]);
        if (state.winner != null) return;
        onProgress?.call(
          .38 + .27 * (index + 1) / math.max(1, provinceIds.length),
        );
        if (_sliceExpired(frameBudget)) await _yieldFrame(frameBudget);
      }

      _runCleanupPhase();
    }
    onProgress?.call(.68);
    if (_sliceExpired(frameBudget)) await _yieldFrame(frameBudget);

    var systemActions = 0;
    final systemBudget = _newSystemsActionBudget;
    while (systemActions < systemBudget &&
        _takeNextNewSystemsAction(systemActions)) {
      systemActions++;
      onProgress?.call(.70 + .27 * systemActions / math.max(1, systemBudget));
      if (_sliceExpired(frameBudget)) await _yieldFrame(frameBudget);
      if (state.winner != null) return;
    }

    _manageDiplomacy();
    onProgress?.call(.98);
    if (_sliceExpired(frameBudget)) await _yieldFrame(frameBudget);
    if (state.winner == null) engine.endTurn();
    onProgress?.call(1);
  }

  void _beginTurn() {
    final state = engine.state;
    _landUnitsBuilt = 0;
    _turnRandom = _JavaRandom(
      state.config.seed ^
          (state.round * 0x9e3779b9) ^
          (state.turn * 0x85ebca6b),
    );
    _turnLandUnits
      ..clear()
      ..addAll(
        state.hexes
            .where(
              (tile) =>
                  tile.unit != null &&
                  engine.unitOwnerAt(tile.index) == state.turn,
            )
            .map((tile) => tile.unit!),
      );
    _landUnitLocations
      ..clear()
      ..addEntries(
        state.hexes
            .where(
              (tile) =>
                  tile.unit != null &&
                  engine.unitOwnerAt(tile.index) == state.turn,
            )
            .map((tile) => MapEntry(tile.unit!, tile.index)),
      );
    _turnBoats
      ..clear()
      ..addAll(
        state.waterCells
            .where((cell) => cell.boat?.owner == state.turn)
            .map((cell) => cell.boat!),
      );
  }

  Future<void> _yieldFrame(Stopwatch frameBudget) async {
    await Future<void>.delayed(Duration.zero);
    frameBudget
      ..reset()
      ..start();
  }

  bool _sliceExpired(Stopwatch frameBudget) {
    // A zero-delay Future is not free on Flutter Web. Yielding after every
    // second unit/province made a 15-player round spend more time scheduling
    // timers than choosing moves. Keep the UI responsive with a real frame
    // budget instead: cheap work stays in one slice, while expensive late-game
    // empires still return to the event loop at least every ~10 ms.
    return frameBudget.elapsedMicroseconds >= 10000;
  }

  void _manageDiplomacy() {
    if (!engine.state.config.diplomacy) return;
    final owner = engine.state.turn;
    if (_managePeaceConferences(owner)) return;
    lastDiplomacyReport = StrategicDiplomacyAi(engine)..takeTurn(owner);
  }

  /// Resolves the mod's post-war coalition conference before ordinary
  /// diplomacy. A bot accepts a proposal that gives it most of its earned
  /// quota (or whose remaining gap cannot fit even the cheapest disputed
  /// tile); otherwise it sends one deterministic counteroffer. This keeps
  /// human/AI conferences interactive without letting unattended AI blocs
  /// wait until the five-round fallback every time.
  bool _managePeaceConferences(int owner) {
    final conferences = engine.peaceConferencesFor(owner).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    var acted = false;
    for (final conference in conferences) {
      if (conference.revision == 0) {
        acted =
            engine.submitPeaceConferenceProposal(
              conference.id,
              owner,
              _buildPeaceConferenceAllocation(conference),
            ) ||
            acted;
        continue;
      }
      if (conference.acceptedBy.contains(owner)) continue;
      final quota = engine.peaceConferenceQuota(conference.id, owner);
      final assigned = engine.peaceConferenceAssignedValue(
        conference.id,
        owner,
      );
      final cheapest = conference.tileValues.values.fold<int>(
        1 << 30,
        math.min,
      );
      final fair =
          quota <= 0 ||
          assigned * 4 >= quota * 3 ||
          quota - assigned < cheapest;
      if (fair) {
        acted = engine.acceptPeaceConference(conference.id, owner) || acted;
        continue;
      }
      acted =
          engine.submitPeaceConferenceProposal(
            conference.id,
            owner,
            _buildPeaceConferenceAllocation(conference),
          ) ||
          acted;
    }
    return acted;
  }

  Map<int, List<int>> _buildPeaceConferenceAllocation(
    PeaceConference conference,
  ) {
    final remaining = <int, int>{
      for (final player in conference.participants)
        player: engine.peaceConferenceQuota(conference.id, player),
    };
    final allocation = <int, List<int>>{
      for (final player in conference.participants) player: <int>[],
    };
    final tiles = conference.claimTiles.toList()
      ..sort((first, second) {
        final valueOrder = (conference.tileValues[second] ?? 0).compareTo(
          conference.tileValues[first] ?? 0,
        );
        return valueOrder != 0 ? valueOrder : first.compareTo(second);
      });
    for (final tile in tiles) {
      final value = conference.tileValues[tile] ?? 0;
      final candidates =
          conference.participants
              .where((player) => (remaining[player] ?? 0) >= value)
              .toList()
            ..sort((first, second) {
              final roomOrder = (remaining[second] ?? 0).compareTo(
                remaining[first] ?? 0,
              );
              return roomOrder != 0 ? roomOrder : first.compareTo(second);
            });
      if (candidates.isEmpty) continue;
      final recipient = candidates.first;
      allocation[recipient]!.add(tile);
      remaining[recipient] = remaining[recipient]! - value;
    }
    allocation.removeWhere((_, tiles) => tiles.isEmpty);
    return allocation;
  }

  _LandAiProfile get _landProfile {
    // Classic's factory has no Slay Master implementation and deliberately
    // dispatches that combination to AiExpertSlayRules.
    if (engine.state.config.slayRules && _tier == AiDifficulty.master.index) {
      return _landAiProfiles[AiDifficulty.hard.index];
    }
    return _landAiProfiles[_tier];
  }

  bool get _canBuildFarms => _landProfile.buildsFarms;
  bool get _canBuildTowers => _landProfile.buildsTowers;
  bool get _canMerge => _landProfile.mergesUnits;
  bool get _canUseNavy => _tier >= AiDifficulty.normal.index;
  bool get _canUseArtillery => _tier >= AiDifficulty.normal.index;
  bool get _canUseSeaForts => _tier >= AiDifficulty.normal.index;
  bool get _canUpgradeNavy => _tier >= AiDifficulty.hard.index;
  bool get _canUpgradeArtillery => _tier >= AiDifficulty.veryHard.index;

  int get _maxUnitStrength => _landProfile.maxUnitStrength;
  int get _survivalTurns => const [1, 2, 3, 4, 5, 5][_tier];

  void _runLandMovementPhase() {
    for (final unit in _startingReadyLandUnits()) {
      _moveStartingUnit(unit);
      if (engine.state.winner != null) return;
    }
  }

  /// Classic Master deliberately plans per sovereign province. This adapter
  /// only handles this mod's expeditionary troops that stand on allied land,
  /// leaving the protected Classic planner and every home unit untouched.
  void _moveExpeditionaryUnits() {
    final state = engine.state;
    final starts =
        state.hexes
            .where(
              (tile) =>
                  tile.unit?.ready == true &&
                  engine.unitOwnerAt(tile.index) == state.turn &&
                  tile.owner != state.turn,
            )
            .map((tile) => tile.index)
            .toList()
          ..sort();
    for (final from in starts) {
      final unit = state.hexes[from].unit;
      if (unit?.ready != true) continue;
      final knownTargets = engine.moveTargets(from);
      final targets = knownTargets.toList();
      if (targets.isEmpty) continue;
      targets.sort((a, b) {
        int score(int index) {
          final tile = state.hexes[index];
          final hostile =
              tile.owner < 0 || engine.areEnemies(state.turn, tile.owner);
          final enemyEdges = tile.neighbors.where((neighbor) {
            final owner = state.hexes[neighbor].owner;
            return owner < 0 || engine.areEnemies(state.turn, owner);
          }).length;
          return (hostile ? 1000 : 0) + enemyEdges * 10 - index;
        }

        return score(b).compareTo(score(a));
      });
      _moveLandUnit(from, targets.first, knownTargets: knownTargets);
    }
  }

  void _runProvinceSpendingPhase() {
    for (final provinceId in _provinceIdsForLandSpending()) {
      _spendAndMergeProvince(provinceId);
      if (engine.state.winner != null) return;
    }
  }

  List<GameUnit> _startingReadyLandUnits() =>
      _turnLandUnits.where((unit) => unit.ready).toList(growable: false);

  List<int> _provinceIdsForLandSpending() => engine
      .provincesOf(engine.state.turn)
      .map((province) => province.id)
      .toList(growable: false);

  /// The official HD order after spending is redundant-unit cleanup followed
  /// by AFK relocation. Both operate only on units that were idle from the
  /// beginning of this turn; purchases never receive a second land action.
  void _runCleanupPhase() {
    if (_landProfile.cullsRedundantUnits && !engine.state.config.slayRules) {
      _cullRedundantUnits();
    }
    if (_landProfile.movesAfkUnits) _moveAfkUnits();

    _retainStartingPieces();
  }

  void _retainStartingPieces() {
    final state = engine.state;
    final currentUnits = state.hexes
        .where(
          (tile) =>
              tile.unit != null && engine.unitOwnerAt(tile.index) == state.turn,
        )
        .map((tile) => tile.unit!)
        .toSet();
    final currentBoats = state.waterCells
        .where((cell) => cell.boat?.owner == state.turn)
        .map((cell) => cell.boat!)
        .toSet();
    _turnLandUnits.retainAll(currentUnits);
    _turnBoats.retainAll(currentBoats);
  }

  void _runNewSystemsPhase() {
    var action = 0;
    final budget = _newSystemsActionBudget;
    while (engine.state.winner == null &&
        action < budget &&
        _takeNextNewSystemsAction(action)) {
      action++;
    }
  }

  /// A state-derived guard, not the former empire-wide mixed action cap. Every
  /// operation in this phase either consumes one ready starting piece or pays
  /// at least one construction price; the guard only protects corrupted mods
  /// with zero/negative prices from an accidental infinite loop.
  int get _newSystemsActionBudget {
    final state = engine.state;
    final cargo = _turnBoats.fold<int>(
      0,
      (sum, boat) => sum + boat.cargo.length,
    );
    final cash = engine
        .provincesOf(state.turn)
        .fold<int>(0, (sum, province) => sum + math.max(0, province.money));
    final positivePrices = <int>[
      mod.rules.port1Price,
      mod.rules.port2Price,
      mod.rules.boat1Price,
      mod.rules.boat2Price,
      mod.rules.seaFortPrice,
      ...mod.rules.artilleryCosts.skip(1),
    ].where((price) => price > 0);
    final cheapest = positivePrices.isEmpty
        ? math.max(1, mod.rules.unitPricePerLevel)
        : positivePrices.reduce(math.min);
    return math.max(
      8,
      _turnLandUnits.length +
          _turnBoats.length * 2 +
          cargo +
          cash ~/ cheapest +
          4,
    );
  }

  bool _takeNextNewSystemsAction(int action) {
    if (!_canUseNavy && !_canUseArtillery) return false;
    bool board() => _canUseNavy && _boardBestUnit();
    bool sail() => _canUseNavy && _moveBestBoat();
    bool fort() => _canUseSeaForts && _buildSeaFort();
    bool navy() => _canUseNavy && _developNavy();
    bool artillery() => _canUseArtillery && _developArtillery();
    bool upgrade() =>
        (_canUpgradeNavy || _canUpgradeArtillery) && _upgradeInfrastructure();
    final preferred = switch (_personality) {
      2 => <_AiAction>[fort, board, sail, artillery, upgrade, navy],
      3 => <_AiAction>[board, sail, navy, fort, upgrade, artillery],
      4 => <_AiAction>[artillery, upgrade, board, fort, sail, navy],
      _ => <_AiAction>[board, sail, artillery, navy, fort, upgrade],
    };
    final rotation = action % preferred.length;
    for (final candidate in <_AiAction>[
      ...preferred.skip(rotation),
      ...preferred.take(rotation),
    ]) {
      if (candidate()) return true;
    }
    return false;
  }

  void _moveStartingUnit(GameUnit unit) {
    final from = _tileIndexForUnit(unit);
    if (from == null || !unit.ready) return;
    final state = engine.state;
    final knownTargets = engine.moveTargets(from);
    final moveZone = knownTargets
        .where((index) {
          final target = state.hexes[index];
          return target.owner != state.turn || target.unit == null;
        })
        .toList(growable: false);
    if (moveZone.isEmpty) return;

    if (_landProfile.skipsHalfMoves && _deterministicRoll(2, 191 + from) == 0) {
      return;
    }

    if (_landProfile.cleansTreesBeforeRandom) {
      final trees = moveZone
          .where(
            (index) =>
                state.hexes[index].owner == state.turn &&
                state.hexes[index].hasTree,
          )
          .toList(growable: false);
      if (trees.isNotEmpty) {
        _moveLandUnit(
          from,
          _chooseDeterministically(trees, 193),
          knownTargets: knownTargets,
        );
        return;
      }
    }

    if (_landProfile.randomMovement) {
      _moveLandUnit(
        from,
        _chooseDeterministically(moveZone, 197),
        knownTargets: knownTargets,
      );
      return;
    }

    if (_landProfile.cleansPalms && unit.strength <= 2) {
      final palms = moveZone
          .where(
            (index) =>
                state.hexes[index].owner == state.turn &&
                state.hexes[index].object == TileObject.palm,
          )
          .toList(growable: false);
      if (palms.isNotEmpty) {
        _moveLandUnit(
          from,
          _chooseDeterministically(palms, 211),
          knownTargets: knownTargets,
        );
        return;
      }
    }

    if (_landProfile.cleansTreesBeforeAttack) {
      final trees = moveZone
          .where(
            (index) =>
                state.hexes[index].owner == state.turn &&
                state.hexes[index].hasTree,
          )
          .toList(growable: false);
      if (trees.isNotEmpty) {
        _moveLandUnit(
          from,
          _chooseDeterministically(trees, 223),
          knownTargets: knownTargets,
        );
        return;
      }
    }

    final attackable = moveZone
        .where((index) {
          final owner = state.hexes[index].owner;
          return owner < 0 || engine.areEnemies(state.turn, owner);
        })
        .toList(growable: false);
    if (attackable.isNotEmpty) {
      if (_landProfile.safeAttacks && !_canUnitMoveSafely(from, unit)) return;
      final target = _mostAttractiveAttack(attackable, unit.strength);
      _moveLandUnit(from, target, knownTargets: knownTargets);
      return;
    }

    if (_landProfile.cleansTreesAfterAttack) {
      final trees = moveZone
          .where(
            (index) =>
                state.hexes[index].owner == state.turn &&
                state.hexes[index].hasTree,
          )
          .toList(growable: false);
      if (trees.isNotEmpty) {
        _moveLandUnit(
          from,
          _chooseDeterministically(trees, 225),
          knownTargets: knownTargets,
        );
        return;
      }
    }

    if (!_landProfile.repositionsDefense ||
        _foreignProvinceNeighbors(from) == 0) {
      return;
    }
    final defensiveTargets = state.hexes[from].neighbors
        .where(moveZone.contains)
        .where((index) {
          final target = state.hexes[index];
          final eligible =
              target.owner == state.turn &&
              target.unit == null &&
              target.object == TileObject.none;
          if (!eligible) return false;
          if (_landProfile.usesDefenseGainReposition) {
            return _predictedDefenseGain(from, index, unit.strength) >= 3;
          }
          return _differentOwnerNeighbors(index) == 0;
        })
        .toList(growable: false);
    if (defensiveTargets.isNotEmpty) {
      _moveLandUnit(
        from,
        _chooseDeterministically(defensiveTargets, 227),
        knownTargets: knownTargets,
      );
    }
  }

  bool _moveLandUnit(int from, int target, {Set<int>? knownTargets}) {
    final moving = engine.state.hexes[from].unit;
    if (moving == null ||
        !engine.moveUnit(from, target, knownTargets: knownTargets)) {
      return false;
    }
    _turnLandUnits.remove(moving);
    _landUnitLocations.remove(moving);
    final occupant = engine.state.hexes[target].unit;
    if (occupant != null && engine.unitOwnerAt(target) == engine.state.turn) {
      _landUnitLocations[occupant] = target;
    }
    return true;
  }

  int? _tileIndexForUnit(GameUnit unit) {
    final cached = _landUnitLocations[unit];
    if (cached != null &&
        engine.unitOwnerAt(cached) == engine.state.turn &&
        identical(engine.state.hexes[cached].unit, unit)) {
      return cached;
    }
    for (final tile in engine.state.hexes) {
      if (identical(tile.unit, unit) &&
          engine.unitOwnerAt(tile.index) == engine.state.turn) {
        _landUnitLocations[unit] = tile.index;
        return tile.index;
      }
    }
    _landUnitLocations.remove(unit);
    return null;
  }

  int _mostAttractiveAttack(List<int> targets, int strength) {
    final state = engine.state;
    if (_landProfile.masterPlanning) {
      final ordered = targets.toList()
        ..sort((a, b) {
          final taste = _masterTargetTaste(b).compareTo(_masterTargetTaste(a));
          if (taste != 0) return taste;
          return _personalityOrder(a, 235).compareTo(_personalityOrder(b, 235));
        });
      return ordered.first;
    }
    // Expert/Balancer and Slay's Master fallback use a bounded tactical
    // evaluation. It only inspects the candidate and its six neighbours, so
    // large maps gain better human-like choices without a deep-search pause.
    if (_tier >= AiDifficulty.hard.index) {
      final ordered = targets.toList()
        ..sort((a, b) {
          final strategic = _strategicAttackScore(
            b,
            strength,
          ).compareTo(_strategicAttackScore(a, strength));
          if (strategic != 0) return strategic;
          return _personalityOrder(a, 233).compareTo(_personalityOrder(b, 233));
        });
      return ordered.first;
    }
    if (_landProfile.prioritizesBaronTargets && strength >= 3) {
      for (final target in _orderedByPersonality(targets, 239)) {
        final object = state.hexes[target].object;
        if (object == TileObject.tower ||
            (strength == 4 && object == TileObject.strongTower)) {
          return target;
        }
      }
      for (final target in _orderedByPersonality(targets, 241)) {
        if (_isDefendedByTower(target)) return target;
      }
    }

    final ordered = targets.toList()
      ..sort((a, b) {
        final allure = _attackAllure(b).compareTo(_attackAllure(a));
        if (allure != 0) return allure;
        if (_landProfile.leaderBiasedTargets) {
          final territory = _ownerLandCount(b).compareTo(_ownerLandCount(a));
          if (territory != 0) return territory;
        }
        final personality = _personalityOrder(
          a,
          251,
        ).compareTo(_personalityOrder(b, 251));
        return personality != 0 ? personality : a.compareTo(b);
      });
    return ordered.first;
  }

  int _masterTargetTaste(int index) {
    final state = engine.state;
    final tile = state.hexes[index];
    var friendlyNeighbors = 0;
    var nearbyArmy = 0;
    for (final neighbor in tile.neighbors) {
      final support = state.hexes[neighbor];
      if (support.owner != state.turn) continue;
      friendlyNeighbors++;
      nearbyArmy += support.unit?.strength ?? 0;
    }
    final weakness = math.max(0, 4 - engine.defenseAt(index));
    final importance = tile.object == TileObject.farm ? 4 : 0;
    final towerBonus = _isDefendedByTower(index) ? 3 : 0;
    // Integer-scaled form of AttackManager's attractiveness, army-presence,
    // weakness, importance, vicinity and tower terms. The missing persistent
    // first/second-line graph is the documented Master adaptation boundary.
    return friendlyNeighbors +
        3 * nearbyArmy +
        weakness +
        importance +
        2 * friendlyNeighbors +
        towerBonus;
  }

  int _attackAllure(int index) {
    final state = engine.state;
    var allure = 0;
    for (final neighbor in state.hexes[index].neighbors) {
      final friendly = state.hexes[neighbor];
      if (friendly.owner != state.turn) continue;
      allure++;
      if (_landProfile.enhancedAllure && friendly.object == TileObject.town) {
        allure += 5;
      }
    }
    if (_landProfile.enhancedAllure &&
        state.hexes[index].object == TileObject.farm) {
      allure *= 2;
    }
    return allure;
  }

  int _strategicAttackScore(int index, int strength) {
    final state = engine.state;
    final target = state.hexes[index];
    final targetProvince = engine.provinceAt(index);
    final neighboringFriendlyProvinces = <int>{};
    var friendlyNeighbors = 0;
    var hostileNeighbors = 0;
    var sameOwnerNeighbors = 0;
    for (final neighbor in target.neighbors) {
      final tile = state.hexes[neighbor];
      if (tile.owner == state.turn) {
        friendlyNeighbors++;
        final province = engine.provinceAt(neighbor);
        if (province != null) neighboringFriendlyProvinces.add(province.id);
      } else if (tile.owner == target.owner && target.owner >= 0) {
        sameOwnerNeighbors++;
      } else if (tile.owner >= 0 && engine.areEnemies(state.turn, tile.owner)) {
        hostileNeighbors++;
      }
    }

    var score = _attackAllure(index) * 12 + friendlyNeighbors * 7;
    score += switch (target.object) {
      TileObject.town => 92,
      TileObject.farm => 36,
      TileObject.port1 || TileObject.port2 => 44,
      TileObject.artillery1 ||
      TileObject.artillery2 ||
      TileObject.artillery3 => 52,
      TileObject.tower => 20,
      TileObject.strongTower => 28,
      TileObject.pine || TileObject.palm => 5,
      _ => 0,
    };
    if (targetProvince?.capital == index) score += 135;
    if (neighboringFriendlyProvinces.length > 1) {
      score += (neighboringFriendlyProvinces.length - 1) * 80;
    }
    // A bridge tile is valuable because taking it tends to split the enemy's
    // economy. This is deliberately local rather than an expensive flood fill.
    if (sameOwnerNeighbors >= 3) score += (sameOwnerNeighbors - 2) * 18;
    score += math.max(0, strength - engine.defenseAt(index)) * 8;
    score -= math.max(0, hostileNeighbors - friendlyNeighbors) * 9;
    if (target.owner < 0) score -= 14;
    return score;
  }

  int _ownerLandCount(int index) {
    final owner = engine.state.hexes[index].owner;
    return owner < 0 ? 0 : engine.playerLandCount(owner);
  }

  bool _canUnitMoveSafely(int from, GameUnit unit) {
    var exposed = 0;
    final state = engine.state;
    for (final neighbor in state.hexes[from].neighbors) {
      final tile = state.hexes[neighbor];
      if (tile.owner != state.turn ||
          _foreignProvinceNeighbors(neighbor) == 0) {
        continue;
      }
      final defended = _landProfile.usesBalancerSafety
          ? _isDefendedWithoutUnit(neighbor, unit)
          : _hasFriendlyBuildingOrOtherUnit(neighbor, unit);
      if (!defended) exposed++;
    }
    return exposed <= 3;
  }

  bool _hasFriendlyBuildingOrOtherUnit(int index, GameUnit ignored) {
    final state = engine.state;
    for (final neighbor in state.hexes[index].neighbors) {
      final tile = state.hexes[neighbor];
      if (!tile.active || tile.owner != state.turn) continue;
      if (tile.unit != null && !identical(tile.unit, ignored)) return true;
      if (_isLandBuilding(tile.object)) return true;
    }
    return false;
  }

  bool _isLandBuilding(TileObject object) => switch (object) {
    TileObject.town ||
    TileObject.farm ||
    TileObject.tower ||
    TileObject.strongTower ||
    TileObject.port1 ||
    TileObject.port2 ||
    TileObject.artillery1 ||
    TileObject.artillery2 ||
    TileObject.artillery3 => true,
    _ => false,
  };

  bool _isDefendedWithoutUnit(int index, GameUnit ignored) {
    final without = _defenseAtIgnoring(index, ignored);
    if (without == 0) return false;
    return engine.defenseAt(index) - without < 2;
  }

  int _defenseAtIgnoring(int index, GameUnit ignored) {
    final state = engine.state;
    final owner = state.hexes[index].owner;
    var defense = _pieceDefense(state.hexes[index], ignored);
    for (final neighbor in state.hexes[index].neighbors) {
      final tile = state.hexes[neighbor];
      if (tile.owner == owner) {
        defense = math.max(defense, _pieceDefense(tile, ignored));
      }
    }
    return defense;
  }

  int _pieceDefense(HexTile tile, GameUnit ignored) {
    var defense = identical(tile.unit, ignored) ? 0 : tile.unit?.strength ?? 0;
    final objectDefense = switch (tile.object) {
      TileObject.town ||
      TileObject.port1 ||
      TileObject.port2 ||
      TileObject.artillery1 ||
      TileObject.artillery2 ||
      TileObject.artillery3 => 1,
      TileObject.tower => 2,
      TileObject.strongTower => 3,
      _ => 0,
    };
    return math.max(defense, objectDefense);
  }

  int _predictedDefenseGain(int from, int target, int strength) {
    final state = engine.state;
    var gain = strength - engine.defenseAt(target);
    for (final neighbor in state.hexes[from].neighbors) {
      if (state.hexes[neighbor].owner != state.turn) continue;
      gain += strength - engine.defenseAt(neighbor);
    }
    return gain;
  }

  void _spendAndMergeProvince(int provinceId) {
    _tryToBuildTowers(provinceId);
    _tryToBuildFarms(provinceId);
    _tryToBuildUnits(provinceId);
    _mergeProvinceUnits(provinceId);
  }

  Province? _provinceById(int provinceId) => engine
      .provincesOf(engine.state.turn)
      .where((province) => province.id == provinceId)
      .firstOrNull;

  void _tryToBuildTowers(int provinceId) {
    if (!_canBuildTowers) return;
    for (var guard = 0; guard < 100; guard++) {
      final province = _provinceById(provinceId);
      if (province == null || province.money < mod.rules.towerPrice) break;
      final buildStrong =
          _landProfile.buildsStrongTowersDirectly &&
          !engine.state.config.slayRules &&
          province.money >= mod.rules.strongTowerPrice;
      final object = buildStrong ? TileObject.strongTower : TileObject.tower;
      final target = _findTowerSite(province, object);
      if (target == null || !engine.build(province.id, target, object)) {
        break;
      }
    }
    if (!_landProfile.upgradesStrongTowers || engine.state.config.slayRules) {
      return;
    }
    for (var guard = 0; guard < 100; guard++) {
      final province = _provinceById(provinceId);
      if (province == null ||
          province.money < mod.rules.strongTowerPrice ||
          engine.balance(province) - mod.rules.strongTowerUpkeep <
              mod.rules.unitPricePerLevel ~/ 2) {
        break;
      }
      final candidates = province.tiles
          .where((index) {
            return engine.state.hexes[index].object == TileObject.tower &&
                _needsStrongTower(province, index);
          })
          .toList(growable: false);
      if (candidates.isEmpty) break;
      final target = _chooseDeterministically(candidates, 263 + guard);
      if (!engine.build(province.id, target, TileObject.strongTower)) break;
    }
  }

  int? _findTowerSite(
    Province province, [
    TileObject object = TileObject.tower,
  ]) {
    final candidates = engine
        .buildTargets(province.id, object)
        .where(_needsNormalTower)
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    return _chooseDeterministically(candidates, 269 + province.id);
  }

  bool _needsNormalTower(int index) {
    final slayExpert =
        engine.state.config.slayRules && _landProfile.safeAttacks;
    if ((_landProfile.towersRequireFrontLine || slayExpert) &&
        _nearbyForeignOwners(index, 2).isEmpty) {
      return false;
    }
    final threshold = slayExpert ? 3 : _landProfile.towerDefenseThreshold;
    return _predictedTowerDefenseGain(index) >= threshold;
  }

  int _predictedTowerDefenseGain(int index) {
    final state = engine.state;
    final source = state.hexes[index];
    var gain = _isDefendedByTower(index) ? 0 : 1;
    for (final neighbor in source.neighbors) {
      final tile = state.hexes[neighbor];
      if (tile.owner == source.owner && !_isDefendedByTower(neighbor)) gain++;
      if (tile.object == TileObject.tower) gain--;
    }
    return gain;
  }

  bool _isDefendedByTower(int index) {
    final state = engine.state;
    final tile = state.hexes[index];
    if (tile.object == TileObject.tower ||
        tile.object == TileObject.strongTower) {
      return true;
    }
    return tile.neighbors.any((neighbor) {
      final support = state.hexes[neighbor];
      return support.owner == tile.owner &&
          (support.object == TileObject.tower ||
              support.object == TileObject.strongTower);
    });
  }

  bool _needsStrongTower(Province province, int index) {
    for (final nearby in _nearbyForeignProvinces(index, 2)) {
      if (nearby.tiles.length > province.tiles.length ~/ 2) return true;
    }
    return false;
  }

  List<Province> _nearbyForeignProvinces(int start, int radius) {
    final state = engine.state;
    final owner = state.hexes[start].owner;
    final ids = <int>{};
    final distance = <int, int>{start: 0};
    final queue = <int>[start];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      final nextDistance = distance[current]! + 1;
      if (nextDistance > radius) continue;
      for (final neighbor in state.hexes[current].neighbors) {
        final tile = state.hexes[neighbor];
        if (!tile.active) continue;
        if (tile.owner >= 0 && tile.owner != owner) {
          final nearby = engine.provinceAt(neighbor);
          if (nearby != null) ids.add(nearby.id);
        }
        if (distance.containsKey(neighbor)) continue;
        distance[neighbor] = nextDistance;
        queue.add(neighbor);
      }
    }
    return state.provinces
        .where((candidate) => ids.contains(candidate.id))
        .toList(growable: false);
  }

  Set<int> _nearbyForeignOwners(int start, int radius) {
    final state = engine.state;
    final owner = state.hexes[start].owner;
    final result = <int>{};
    final distance = <int, int>{start: 0};
    final queue = <int>[start];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      final nextDistance = distance[current]! + 1;
      if (nextDistance > radius) continue;
      for (final neighbor in state.hexes[current].neighbors) {
        final tile = state.hexes[neighbor];
        if (!tile.active) continue;
        if (tile.owner >= 0 && tile.owner != owner) result.add(tile.owner);
        if (distance.containsKey(neighbor)) continue;
        distance[neighbor] = nextDistance;
        queue.add(neighbor);
      }
    }
    return result;
  }

  void _tryToBuildFarms(int provinceId) {
    if (!_canBuildFarms || engine.state.config.slayRules) return;
    // Classic limits the *extra* farm cost to 80, not the total price.
    final maximumFarmPrice = mod.rules.farmBasePrice + 80;
    for (var guard = 0; guard < 100; guard++) {
      final province = _provinceById(provinceId);
      if (province == null) break;
      final price = engine.farmPrice(province);
      if (price > maximumFarmPrice || province.money < price) break;
      if (!_isOkToBuildFarm(province, price)) break;
      final targets = engine
          .buildTargets(province.id, TileObject.farm)
          .toList();
      if (targets.isEmpty) break;
      final target = _chooseDeterministically(targets, 277 + guard);
      if (!engine.build(province.id, target, TileObject.farm)) break;
    }
  }

  bool _isOkToBuildFarm(Province province, int price) {
    if (province.money > 2 * price) return true;
    if (_landProfile.cautiousFarms) {
      final army = _armyStrength(province);
      for (final nearby in _adjacentForeignProvinces(province)) {
        if (army < _armyStrength(nearby) ~/ 2) return false;
      }
    }
    return _findTowerSite(province) == null;
  }

  int _armyStrength(Province province) => province.tiles.fold<int>(
    0,
    (sum, index) => sum + (engine.state.hexes[index].unit?.strength ?? 0),
  );

  List<Province> _adjacentForeignProvinces(Province province) {
    final ids = <int>{};
    for (final index in province.tiles) {
      for (final neighbor in engine.state.hexes[index].neighbors) {
        final nearby = engine.provinceAt(neighbor);
        if (nearby != null && nearby.owner != province.owner) {
          ids.add(nearby.id);
        }
      }
    }
    return engine.state.provinces
        .where((candidate) => ids.contains(candidate.id))
        .toList(growable: false);
  }

  void _tryToBuildUnits(int provinceId) {
    var province = _provinceById(provinceId);
    if (province == null) return;
    if (_landProfile.cleansPalms) _buildUnitsOnPalms(provinceId);
    if (_landProfile.reinforcesUnits) _reinforceBlockedUnits(provinceId);

    if (_landProfile.buildsUnitsInsideProvince) {
      _buildUnitsInsideProvince(provinceId);
      province = _provinceById(provinceId);
      if (province != null &&
          _canAffordUnit(province, 1) &&
          _unitCount(province) <= 1) {
        _tryToAttackWithPurchasedUnit(province, 1);
      }
      return;
    }

    for (var strength = 1; strength <= _maxUnitStrength; strength++) {
      province = _provinceById(provinceId);
      final forecast = _landProfile.usesFiveTurnUnitForecast ? 5 : strength + 1;
      if (province == null || !_canAffordUnit(province, strength, forecast)) {
        break;
      }
      for (var guard = 0; guard < 50; guard++) {
        province = _provinceById(provinceId);
        if (province == null ||
            !_canAffordUnit(province, strength) ||
            !_tryToAttackWithPurchasedUnit(province, strength)) {
          break;
        }
        if (engine.state.winner != null) return;
      }
    }

    province = _provinceById(provinceId);
    if (province != null &&
        _canAffordUnit(province, 1) &&
        _unitCount(province) <= 1) {
      _tryToAttackWithPurchasedUnit(province, 1);
    }
  }

  void _buildUnitsInsideProvince(int provinceId) {
    for (var strength = 1; strength <= 4; strength++) {
      for (var guard = 0; guard < 100; guard++) {
        final province = _provinceById(provinceId);
        if (province == null ||
            !_canAffordUnit(province, strength) ||
            !_canBuildAnotherLandUnit(province)) {
          break;
        }
        final targets = engine
            .unitBuildTargets(province.id, strength)
            .where((index) {
              final tile = engine.state.hexes[index];
              return tile.owner == engine.state.turn &&
                  tile.unit == null &&
                  tile.object == TileObject.none;
            })
            .toList(growable: false);
        if (targets.isEmpty) break;
        if (!_buyLandUnit(
          province,
          _chooseDeterministically(targets, 281 + guard + strength),
          strength,
        )) {
          break;
        }
      }
    }
  }

  void _buildUnitsOnPalms(int provinceId) {
    for (var guard = 0; guard < 100; guard++) {
      final province = _provinceById(provinceId);
      if (province == null ||
          !_canAffordUnit(province, 1) ||
          !_canBuildAnotherLandUnit(province)) {
        break;
      }
      final palms = engine
          .unitBuildTargets(province.id, 1)
          .where(
            (index) =>
                engine.state.hexes[index].owner == engine.state.turn &&
                engine.state.hexes[index].object == TileObject.palm,
          )
          .toList(growable: false);
      if (palms.isEmpty) break;
      if (!_buyLandUnit(
        province,
        _chooseDeterministically(palms, 283 + guard),
        1,
      )) {
        break;
      }
    }
  }

  void _reinforceBlockedUnits(int provinceId) {
    final province = _provinceById(provinceId);
    if (province == null) return;
    final starts = province.tiles.toList(growable: false);
    for (final index in starts) {
      final current = _provinceById(provinceId);
      if (current == null) return;
      final unit = engine.state.hexes[index].unit;
      if (unit == null ||
          unit.strength >= 4 ||
          !_turnLandUnits.contains(unit) ||
          !_unitHasBlockedEnemy(index)) {
        continue;
      }
      final resultingStrength = unit.strength + 1;
      if (current.money < mod.rules.unitPricePerLevel ||
          !_canSurviveUnit(current, resultingStrength) ||
          !engine.unitBuildTargets(current.id, 1).contains(index)) {
        continue;
      }
      _buyLandUnit(current, index, 1);
    }
  }

  bool _unitHasBlockedEnemy(int from) {
    final state = engine.state;
    final owner = state.turn;
    final distance = <int, int>{from: 0};
    final queue = <int>[from];
    var foreignInZone = false;
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      final nextDistance = distance[current]! + 1;
      if (nextDistance > mod.rules.unitMoveLimit) continue;
      for (final neighbor in state.hexes[current].neighbors) {
        final tile = state.hexes[neighbor];
        if (!tile.active) continue;
        if (tile.owner == owner) {
          if (!distance.containsKey(neighbor)) {
            distance[neighbor] = nextDistance;
            queue.add(neighbor);
          }
        } else if (tile.owner < 0 || engine.areEnemies(owner, tile.owner)) {
          foreignInZone = true;
        }
      }
    }
    if (!foreignInZone) return false;
    return !engine
        .moveTargets(from)
        .any((index) => state.hexes[index].owner != owner);
  }

  bool _tryToAttackWithPurchasedUnit(Province province, int strength) {
    if (!_canBuildAnotherLandUnit(province)) return false;
    final targets = engine
        .unitBuildTargets(province.id, strength)
        .where((index) => engine.state.hexes[index].owner != engine.state.turn)
        .toList(growable: false);
    if (targets.isEmpty) return false;
    return _buyLandUnit(
      province,
      _mostAttractiveAttack(targets, strength),
      strength,
    );
  }

  bool _buyLandUnit(Province province, int target, int strength) {
    if (!engine.buyUnit(province.id, target, strength)) return false;
    _landUnitsBuilt++;
    // The movement snapshot was already consumed. Keep the engine's official
    // readiness semantics here: friendly purchases may merge later in this
    // province phase, while attacks and tree-clearing purchases are unready.
    final result = engine.state.hexes[target].unit;
    if (result != null &&
        engine.state.hexes[target].owner == engine.state.turn) {
      _landUnitLocations[result] = target;
    }
    return true;
  }

  bool _canBuildAnotherLandUnit(Province province) {
    final config = engine.state.config;
    if (!config.diplomacy || config.humanCount == 0) return true;
    final limit = math.min(math.max(3, province.tiles.length ~/ 4), 10);
    return _landUnitsBuilt < limit;
  }

  bool _canAffordUnit(Province province, int strength, [int? turnsToSurvive]) {
    if (strength < 1 || strength > 4) return false;
    final price = strength * mod.rules.unitPricePerLevel;
    if (province.money < price) return false;
    return _canSurviveUnit(province, strength, turnsToSurvive);
  }

  bool _canSurviveUnit(Province province, int strength, [int? turnsToSurvive]) {
    if (strength < 1 || strength > 4) return false;
    if (!engine.provinceAllowsUnitStrength(province.id, strength)) return false;
    final newProfit =
        engine.balance(province) - _unitUpkeepAtStrength(strength);
    return province.money + (turnsToSurvive ?? strength + 1) * newProfit >= 0;
  }

  int _unitCount(Province province) => province.tiles
      .where((index) => engine.state.hexes[index].unit != null)
      .length;

  void _mergeProvinceUnits(int provinceId) {
    if (!_canMerge) return;
    if (_landProfile.mergeChanceDenominator > 1 &&
        _deterministicRoll(
              _landProfile.mergeChanceDenominator,
              289 + provinceId,
            ) !=
            0) {
      return;
    }
    final starts = _provinceById(provinceId)?.tiles.toList(growable: false);
    if (starts == null) return;
    for (final from in starts) {
      final province = _provinceById(provinceId);
      if (province == null || !province.tiles.contains(from)) return;
      final moving = engine.state.hexes[from].unit;
      if (moving?.ready != true) continue;
      final targets = engine
          .moveTargets(from)
          .where((index) {
            final receiving = engine.state.hexes[index].unit;
            if (engine.state.hexes[index].owner != engine.state.turn ||
                receiving?.ready != true) {
              return false;
            }
            final result = moving!.strength + receiving!.strength;
            if (_landProfile.mergesOnlyPeasants &&
                (moving.strength != 1 || receiving.strength != 1)) {
              return false;
            }
            return result <= 4 && _canSurviveUnit(province, result);
          })
          .toList(growable: false);
      if (targets.isEmpty) continue;
      final target = _chooseDeterministically(targets, 293 + from);
      final receiving = engine.state.hexes[target].unit;
      if (engine.moveUnit(from, target)) {
        _turnLandUnits.remove(moving);
        if (receiving != null) _turnLandUnits.remove(receiving);
        _landUnitLocations
          ..remove(moving)
          ..remove(receiving);
        final result = engine.state.hexes[target].unit;
        if (result != null) _landUnitLocations[result] = target;
      }
    }
  }

  void _cullRedundantUnits() {
    final provinceIds = _provinceIdsForLandSpending();
    for (final provinceId in provinceIds) {
      for (var guard = 0; guard < 1000; guard++) {
        final province = _provinceById(provinceId);
        if (province == null) break;
        final units = province.tiles
            .where((index) => engine.state.hexes[index].unit != null)
            .toList(growable: false);
        if (units.any(
              (index) => engine.state.hexes[index].unit!.ready == false,
            ) ||
            !units.any(
              (index) => engine.state.hexes[index].unit!.strength >= 3,
            ) ||
            province.money < mod.rules.unitPricePerLevel ||
            engine.balance(province) < 0 ||
            !_canAffordUnit(province, 1) ||
            !_canBuildAnotherLandUnit(province)) {
          break;
        }
        final candidates =
            units
                .where((index) => engine.state.hexes[index].unit!.strength < 4)
                .toList()
              ..sort((a, b) {
                final strength = engine.state.hexes[b].unit!.strength.compareTo(
                  engine.state.hexes[a].unit!.strength,
                );
                return strength != 0 ? strength : a.compareTo(b);
              });
        if (candidates.isEmpty ||
            !_buyLandUnit(province, candidates.first, 1)) {
          break;
        }
      }
    }
  }

  void _moveAfkUnits() {
    // Classic refreshes the ready list here. Friendly purchases that stayed
    // ready after spending can therefore join the large-province AFK pass;
    // they still never re-enter the earlier ordinary movement phase.
    final readyUnits = engine.state.hexes
        .where(
          (tile) =>
              tile.unit?.ready == true &&
              engine.unitOwnerAt(tile.index) == engine.state.turn,
        )
        .map((tile) => tile.unit!)
        .toList(growable: false);
    for (final unit in readyUnits) {
      if (!unit.ready) continue;
      final from = _tileIndexForUnit(unit);
      if (from == null) continue;
      final province = engine.provinceAt(from);
      if (province == null || province.tiles.length <= 20) continue;
      final perimeter = province.tiles
          .where((index) => _foreignProvinceNeighbors(index) > 0)
          .toList(growable: false);
      if (perimeter.isEmpty) continue;
      final destination = _chooseDeterministically(perimeter, 307 + from);
      final knownTargets = engine.moveTargets(from);
      final friendly = knownTargets.where((index) {
        final tile = engine.state.hexes[index];
        return tile.owner == engine.state.turn &&
            tile.unit == null &&
            tile.object == TileObject.none;
      }).toList();
      if (friendly.isNotEmpty) {
        friendly.sort((a, b) {
          final distance = _hexDistance(
            a,
            destination,
          ).compareTo(_hexDistance(b, destination));
          return distance != 0
              ? distance
              : _personalityOrder(a, 311).compareTo(_personalityOrder(b, 311));
        });
        _moveLandUnit(from, friendly.first, knownTargets: knownTargets);
        continue;
      }
      final fallback = knownTargets
          .where((index) {
            final tile = engine.state.hexes[index];
            return tile.owner != engine.state.turn ||
                (tile.unit == null &&
                    tile.object != TileObject.town &&
                    tile.object != TileObject.farm &&
                    tile.object != TileObject.tower &&
                    tile.object != TileObject.strongTower &&
                    tile.object != TileObject.port1 &&
                    tile.object != TileObject.port2 &&
                    engine.artilleryLevelAt(index) == 0);
          })
          .toList(growable: false);
      if (fallback.isNotEmpty) {
        _moveLandUnit(
          from,
          _chooseDeterministically(fallback, 313 + from),
          knownTargets: knownTargets,
        );
      }
    }
  }

  int _hexDistance(int first, int second) {
    final a = engine.state.hexes[first];
    final b = engine.state.hexes[second];
    final dq = (a.q - b.q).abs();
    final dr = (a.r - b.r).abs();
    final ds = (a.q + a.r - b.q - b.r).abs();
    return (dq + dr + ds) ~/ 2;
  }

  List<int> _orderedByPersonality(Iterable<int> values, int salt) {
    final result = values.toList();
    result.sort((a, b) {
      final order = _personalityOrder(
        a,
        salt,
      ).compareTo(_personalityOrder(b, salt));
      return order != 0 ? order : a.compareTo(b);
    });
    return result;
  }

  int _chooseDeterministically(List<int> values, int salt) {
    if (values.length == 1) return values.first;
    final ordered = values.toList()..sort();
    final random = _turnRandom ?? _JavaRandom(engine.state.config.seed ^ salt);
    return ordered[random.nextInt(ordered.length)];
  }

  int _deterministicRoll(int bound, int salt) {
    final random = _turnRandom ?? _JavaRandom(engine.state.config.seed ^ salt);
    return random.nextInt(math.max(1, bound));
  }

  int _personalityOrder(int value, int salt) =>
      _tieBreak(value, engine.state.turn, salt);

  bool _developArtillery({int? onlyProvinceId}) {
    final state = engine.state;
    if (!_canUseArtillery) return false;
    final proactiveEngineer = _personality == 4 && state.round >= 7;
    for (final province
        in engine
            .provincesOf(state.turn)
            .where(
              (province) =>
                  onlyProvinceId == null || province.id == onlyProvinceId,
            )) {
      final existing = province.tiles
          .where((index) => engine.artilleryLevelAt(index) > 0)
          .toList();
      for (final index in existing) {
        final current = engine.artilleryLevelAt(index);
        if (_canUpgradeArtillery && current < 3) {
          final price = mod.rules.artilleryCosts[current + 1];
          final upkeepDelta =
              mod.rules.artilleryUpkeep[current + 1] -
              mod.rules.artilleryUpkeep[current];
          if (_survivesPurchase(
                province,
                price: price,
                recurringDelta: -upkeepDelta,
              ) &&
              engine.upgradeArtillery(index)) {
            return true;
          }
        }
      }
      final desiredArtillery = math.max(
        1,
        math.min(_personality == 4 ? 3 : 2, (province.tiles.length + 9) ~/ 10),
      );
      if (existing.length >= desiredArtillery) continue;
      final price = mod.rules.artilleryCosts[1];
      if (!_survivesPurchase(
        province,
        price: price,
        recurringDelta: -mod.rules.artilleryUpkeep[1],
      )) {
        continue;
      }
      final targets =
          engine
              .buildTargets(province.id, TileObject.artillery1)
              .where(
                (index) =>
                    _nearbyEnemyBoats(index) > 0 ||
                    (proactiveEngineer && _isNavigableCoast(index)),
              )
              .toList()
            ..sort(
              (a, b) => _nearbyEnemyBoats(b).compareTo(_nearbyEnemyBoats(a)),
            );
      if (targets.isNotEmpty &&
          engine.build(province.id, targets.first, TileObject.artillery1)) {
        return true;
      }
    }
    return false;
  }

  bool _developNavy({int? onlyProvinceId}) {
    final state = engine.state;
    if (!_canUseNavy) return false;
    if (_personality != 3 && state.round < 5) return false;
    for (final province
        in engine
            .provincesOf(state.turn)
            .where(
              (province) =>
                  onlyProvinceId == null || province.id == onlyProvinceId,
            )) {
      final ports = province.tiles.where(
        (index) => engine.portLevelAt(index) > 0,
      );
      if (ports.isEmpty) {
        final targets = engine.buildTargets(province.id, TileObject.port1);
        if (targets.isNotEmpty &&
            _survivesPurchase(
              province,
              price: mod.rules.port1Price,
              recurringDelta: -mod.rules.port1Upkeep,
            )) {
          return engine.build(province.id, targets.first, TileObject.port1);
        }
        continue;
      }
      for (final port in ports) {
        final currentFleet = state.waterCells
            .where((cell) => cell.boat?.homeProvinceId == province.id)
            .length;
        final desiredFleet = math.max(
          1,
          math.min(_personality == 3 ? 4 : 2, (province.tiles.length + 7) ~/ 8),
        );
        // Establish a basic fleet before paying for the premium port. This
        // avoids a hard bot buying level two and then being unable to launch.
        if (currentFleet > 0 &&
            _canUpgradeNavy &&
            engine.portLevelAt(port) == 1 &&
            _survivesPurchase(
              province,
              price: mod.rules.port2Price,
              recurringDelta: -(mod.rules.port2Upkeep - mod.rules.port1Upkeep),
            ) &&
            engine.upgradePort(port)) {
          return true;
        }
        final preferredLevel = _canUpgradeNavy && engine.portLevelAt(port) >= 2
            ? 2
            : 1;
        final boatTargets = engine.boatBuildTargets(
          province.id,
          port,
          preferredLevel,
        );
        final boatPrice = preferredLevel == 1
            ? mod.rules.boat1Price
            : mod.rules.boat2Price;
        final boatUpkeep = preferredLevel == 1
            ? mod.rules.boat1Upkeep
            : mod.rules.boat2Upkeep;
        if (currentFleet < desiredFleet &&
            boatTargets.isNotEmpty &&
            _survivesPurchase(
              province,
              price: boatPrice,
              recurringDelta: -boatUpkeep,
            ) &&
            engine.buildBoat(
              province.id,
              port,
              boatTargets.first,
              preferredLevel,
            )) {
          return true;
        }
      }
      final cargoStrength = math.min(_maxUnitStrength, _tier >= 4 ? 2 : 1);
      for (var strength = cargoStrength; strength >= 1; strength--) {
        final cargoTargets =
            engine.unitBoatBuildTargets(province.id, strength).toList()..sort();
        final cargoUpkeep = (_unitUpkeepAtStrength(strength) * 3) ~/ 2;
        final price = strength * mod.rules.unitPricePerLevel;
        for (final target in cargoTargets) {
          final boat = state.waterCells[target].boat;
          final home = boat == null ? null : _provinceById(boat.homeProvinceId);
          if (home == null) continue;
          final affordable = home.id == province.id
              ? _survivesPurchase(
                  province,
                  price: price,
                  recurringDelta: -cargoUpkeep,
                )
              : _survivesPurchase(province, price: price, recurringDelta: 0) &&
                    _survivesPurchase(
                      home,
                      price: 0,
                      recurringDelta: -cargoUpkeep,
                    );
          if (affordable &&
              engine.buyUnitIntoBoat(province.id, target, strength)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  /// Loads an existing, still-idle land unit into an existing fleet. The old
  /// AI could only buy new cargo, leaving veteran coastal armies stranded.
  bool _boardBestUnit() {
    final state = engine.state;
    final choices = <({int from, int water, int score})>[];
    final objectiveDistance = _navalObjectiveDistanceMap();
    for (final tile in state.hexes) {
      final unit = tile.unit;
      if (tile.owner != state.turn ||
          unit?.ready != true ||
          !_turnLandUnits.contains(unit)) {
        continue;
      }
      final province = engine.provinceAt(tile.index);
      if (province == null) continue;
      final landUpkeep = _unitUpkeepAtStrength(unit!.strength);
      final cargoUpkeep = (landUpkeep * 3) ~/ 2;
      for (final water in engine.unitBoardingTargets(tile.index)) {
        final boat = state.waterCells[water].boat;
        if (boat == null || !_turnBoats.contains(boat)) continue;
        final home = _provinceById(boat.homeProvinceId);
        if (home == null) continue;
        final affordable = home.id == province.id
            ? _survivesPurchase(
                province,
                price: 0,
                recurringDelta: -(cargoUpkeep - landUpkeep),
              )
            : _survivesPurchase(home, price: 0, recurringDelta: -cargoUpkeep);
        if (!affordable) continue;
        var score = 50 + unit.strength * 8;
        score += math.max(0, 60 - (objectiveDistance[water] ?? 99) * 8);
        if (_personality == 3) score += 30;
        score += _scoreNoise(tile.index, water, 71, 9);
        choices.add((from: tile.index, water: water, score: score));
      }
    }
    if (choices.isEmpty) return false;
    choices.sort((a, b) => b.score.compareTo(a.score));
    final chosen = choices.first;
    final unit = state.hexes[chosen.from].unit;
    if (!engine.boardUnit(chosen.from, chosen.water)) return false;
    if (unit != null) _turnLandUnits.remove(unit);
    return true;
  }

  bool _moveBestBoat() {
    final state = engine.state;
    final objectiveDistance = _navalObjectiveDistanceMap();
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat?.owner != state.turn ||
          boat?.ready != true ||
          !_turnBoats.contains(boat)) {
        continue;
      }
      if (boat!.cargo.isNotEmpty) {
        for (var cargo = 0; cargo < boat.cargo.length; cargo++) {
          final targets =
              engine.boatDisembarkTargets(cell.index, cargo).toList()
                ..sort((a, b) {
                  return _landingScore(
                    b,
                    boat.cargo[cargo],
                  ).compareTo(_landingScore(a, boat.cargo[cargo]));
                });
          if (targets.isNotEmpty &&
              engine.disembarkUnit(cell.index, cargo, targets.first)) {
            return true;
          }
        }
      }
      if (objectiveDistance.isEmpty) continue;
      final currentDistance = objectiveDistance[cell.index] ?? 1 << 20;
      final targets =
          engine
              .boatMoveTargets(cell.index)
              .where(
                (target) =>
                    _directWaterObjectiveScore(target) > 0 ||
                    (objectiveDistance[target] ?? 1 << 20) < currentDistance,
              )
              .toList()
            ..sort(
              (a, b) => _waterTargetScore(
                b,
                objectiveDistance,
              ).compareTo(_waterTargetScore(a, objectiveDistance)),
            );
      if (targets.isNotEmpty && engine.moveBoat(cell.index, targets.first)) {
        _turnBoats.remove(boat);
        return true;
      }
    }
    return false;
  }

  bool _buildSeaFort() {
    final state = engine.state;
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat?.owner != state.turn ||
          boat?.ready != true ||
          !_turnBoats.contains(boat)) {
        continue;
      }
      final provinces = engine
          .provincesOf(state.turn)
          .where((province) => province.id == boat!.homeProvinceId);
      if (provinces.isEmpty) continue;
      final province = provinces.first;
      if (!_survivesPurchase(
        province,
        price: mod.rules.seaFortPrice,
        recurringDelta: -mod.rules.seaFortUpkeep,
      )) {
        continue;
      }
      final objectiveDistance = _navalObjectiveDistanceMap();
      final targets = engine.seaFortBuildTargets(cell.index).toList()
        ..sort(
          (a, b) => _waterTargetScore(
            b,
            objectiveDistance,
          ).compareTo(_waterTargetScore(a, objectiveDistance)),
        );
      final threatened = targets.where((index) {
        final target = state.waterCells[index];
        return target.neighbors.any((neighbor) {
              final boat = state.waterCells[neighbor].boat;
              return boat != null && engine.areEnemies(state.turn, boat.owner);
            }) ||
            target.coastTiles.any((tile) => _hostilePressure(tile) > 0);
      }).toList();
      if (threatened.isNotEmpty &&
          engine.buildSeaFort(cell.index, threatened.first)) {
        _turnBoats.remove(boat);
        return true;
      }
    }
    return false;
  }

  bool _upgradeInfrastructure() {
    final state = engine.state;
    for (final province in engine.provincesOf(state.turn)) {
      for (final index in province.tiles) {
        final artilleryLevel = engine.artilleryLevelAt(index);
        if (_canUpgradeArtillery && artilleryLevel > 0 && artilleryLevel < 3) {
          final price = mod.rules.artilleryCosts[artilleryLevel + 1];
          final upkeepDelta =
              mod.rules.artilleryUpkeep[artilleryLevel + 1] -
              mod.rules.artilleryUpkeep[artilleryLevel];
          if (_survivesPurchase(
                province,
                price: price,
                recurringDelta: -upkeepDelta,
              ) &&
              engine.upgradeArtillery(index)) {
            return true;
          }
        }
        if (_canUpgradeNavy &&
            engine.portLevelAt(index) == 1 &&
            _survivesPurchase(
              province,
              price: mod.rules.port2Price,
              recurringDelta: -(mod.rules.port2Upkeep - mod.rules.port1Upkeep),
            ) &&
            engine.upgradePort(index)) {
          return true;
        }
      }
    }
    return false;
  }

  int _waterTargetScore(int index, [Map<int, int>? objectiveDistances]) {
    final state = engine.state;
    final distances = objectiveDistances ?? _navalObjectiveDistanceMap();
    var score = _directWaterObjectiveScore(index);
    final distance = distances[index];
    if (distance != null) score += math.max(0, 80 - distance * 10);
    score += _scoreNoise(index, state.round, 29, 9);
    return score;
  }

  /// Peaceful/allied coasts are deliberately not objectives. They may still
  /// be crossed en route to an actual enemy/neutral legal landing, but a fleet
  /// will not reveal or stalk them merely because they are non-owned.
  int _directWaterObjectiveScore(int index) {
    final state = engine.state;
    final cell = state.waterCells[index];
    var score = 0;
    final boat = cell.boat;
    if (boat != null && engine.areEnemies(state.turn, boat.owner)) score += 120;
    final fort = cell.seaFort;
    if (fort != null && engine.areEnemies(state.turn, fort.owner)) score += 90;
    for (final tileIndex in cell.coastTiles) {
      final tile = state.hexes[tileIndex];
      final legalForeign =
          tile.owner < 0 ||
          (tile.owner != state.turn &&
              engine.areEnemies(state.turn, tile.owner));
      if (!legalForeign) continue;
      score += tile.owner < 0 ? 10 : 22;
      score += switch (tile.object) {
        TileObject.town => 32,
        TileObject.farm => 18,
        TileObject.port1 || TileObject.port2 => 24,
        TileObject.artillery1 ||
        TileObject.artillery2 ||
        TileObject.artillery3 => 28,
        _ => 0,
      };
    }
    return score;
  }

  Map<int, int> _navalObjectiveDistanceMap() {
    final state = engine.state;
    final distances = <int, int>{};
    final queue = <int>[];
    for (final cell in state.waterCells) {
      if (!cell.navigable || _directWaterObjectiveScore(cell.index) <= 0) {
        continue;
      }
      distances[cell.index] = 0;
      queue.add(cell.index);
    }
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      final nextDistance = distances[current]! + 1;
      for (final neighbor in state.waterCells[current].neighbors) {
        if (!state.waterCells[neighbor].navigable ||
            distances.containsKey(neighbor)) {
          continue;
        }
        distances[neighbor] = nextDistance;
        queue.add(neighbor);
      }
    }
    return distances;
  }

  int _landingScore(int index, GameUnit unit) {
    final state = engine.state;
    final target = state.hexes[index];
    var score = target.owner == state.turn
        ? (target.hasTree ? 18 : 2)
        : (target.owner < 0 ? 48 : 82);
    score += switch (target.object) {
      TileObject.town => 70,
      TileObject.farm => 38,
      TileObject.port1 || TileObject.port2 => 48,
      TileObject.artillery1 ||
      TileObject.artillery2 ||
      TileObject.artillery3 => 55,
      TileObject.tower || TileObject.strongTower => 20,
      _ => 0,
    };
    score -= math.max(0, engine.defenseAt(index) + 1 - unit.strength) * 25;
    return score + _scoreNoise(index, unit.strength, 83, 7);
  }

  int _nearbyEnemyBoats(int tileIndex) {
    final state = engine.state;
    return state.waterCells.where((cell) {
      final boat = cell.boat;
      if (boat == null || !engine.areEnemies(state.turn, boat.owner)) {
        return false;
      }
      return cell.coastTiles.contains(tileIndex) ||
          cell.neighbors.any(
            (neighbor) =>
                state.waterCells[neighbor].coastTiles.contains(tileIndex),
          );
    }).length;
  }

  bool _isNavigableCoast(int tileIndex) => engine.state.waterCells.any(
    (cell) => cell.navigable && cell.coastTiles.contains(tileIndex),
  );

  int _hostilePressure(int index) {
    var pressure = 0;
    for (final neighbor in engine.state.hexes[index].neighbors) {
      final tile = engine.state.hexes[neighbor];
      if (!tile.active ||
          tile.owner < 0 ||
          !engine.areEnemies(engine.state.turn, tile.owner)) {
        continue;
      }
      pressure += 2 + (tile.unit?.strength ?? 0) * 4;
      if (tile.object == TileObject.town) pressure += 2;
    }
    return pressure;
  }

  /// Applies the official AI reserve test to mod-only purchases: cash must
  /// cover the configured price, then current cash must survive the configured
  /// number of future profit ticks with the new recurring cost included.
  bool _survivesPurchase(
    Province province, {
    required int price,
    required int recurringDelta,
  }) {
    if (price < 0 || province.money < price) return false;
    final futureBalance = engine.balance(province) + recurringDelta;
    return province.money + _survivalTurns * futureBalance >= 0;
  }

  int _unitUpkeepAtStrength(int strength) {
    if (strength <= 0) return 0;
    final clamped = math.max(1, math.min(4, strength));
    return engine.unitUpkeepAtStrength(clamped);
  }

  /// Classic perimeter: adjacent active land owned by another real province.
  /// Neutral land is not a province; peace/alliance does not erase geography.
  int _foreignProvinceNeighbors(int index) =>
      engine.state.hexes[index].neighbors.where((neighbor) {
        final tile = engine.state.hexes[neighbor];
        return tile.active &&
            tile.owner >= 0 &&
            tile.owner != engine.state.turn;
      }).length;

  /// Classic `howManyEnemyHexesNear`: every active different fraction,
  /// including neutral land, regardless of a diplomatic non-aggression pact.
  int _differentOwnerNeighbors(int index) =>
      engine.state.hexes[index].neighbors.where((neighbor) {
        final tile = engine.state.hexes[neighbor];
        return tile.active && tile.owner != engine.state.turn;
      }).length;

  int _tieBreak(int a, int b, int salt) =>
      (a * 31 + b * 17 + engine.state.round * salt + engine.state.config.seed)
          .abs();

  int _scoreNoise(int a, int b, int salt, int spread) =>
      _tieBreak(a, b, salt) % math.max(1, spread);
}

/// Local ordinals preserve Classic's six-profile dispatcher:
/// veryEasy/Easy, easy/Normal, normal/Hard, hard/Expert,
/// veryHard/Balancer, master/Master. The shared rules also match their HD
/// descendants. Generic Master is explicitly a partial manager adaptation;
/// the local model has no persisted AiData/AttackManager/DefenseManager graph.
class _LandAiProfile {
  const _LandAiProfile({
    required this.maxUnitStrength,
    this.randomMovement = false,
    this.skipsHalfMoves = false,
    this.cleansTreesBeforeRandom = false,
    this.buildsUnitsInsideProvince = false,
    this.buildsTowers = false,
    this.buildsFarms = false,
    this.mergesUnits = false,
    this.mergesOnlyPeasants = false,
    this.mergeChanceDenominator = 1,
    this.cleansPalms = false,
    this.cleansTreesBeforeAttack = false,
    this.cleansTreesAfterAttack = false,
    this.safeAttacks = false,
    this.usesBalancerSafety = false,
    this.repositionsDefense = false,
    this.usesDefenseGainReposition = false,
    this.movesAfkUnits = false,
    this.buildsStrongTowersDirectly = false,
    this.upgradesStrongTowers = false,
    this.reinforcesUnits = false,
    this.cullsRedundantUnits = false,
    this.prioritizesBaronTargets = false,
    this.leaderBiasedTargets = false,
    this.enhancedAllure = false,
    this.towersRequireFrontLine = false,
    this.towerDefenseThreshold = 5,
    this.cautiousFarms = false,
    this.usesFiveTurnUnitForecast = false,
    this.masterPlanning = false,
  });

  final int maxUnitStrength;
  final bool randomMovement;
  final bool skipsHalfMoves;
  final bool cleansTreesBeforeRandom;
  final bool buildsUnitsInsideProvince;
  final bool buildsTowers;
  final bool buildsFarms;
  final bool mergesUnits;
  final bool mergesOnlyPeasants;
  final int mergeChanceDenominator;
  final bool cleansPalms;
  final bool cleansTreesBeforeAttack;
  final bool cleansTreesAfterAttack;
  final bool safeAttacks;
  final bool usesBalancerSafety;
  final bool repositionsDefense;
  final bool usesDefenseGainReposition;
  final bool movesAfkUnits;
  final bool buildsStrongTowersDirectly;
  final bool upgradesStrongTowers;
  final bool reinforcesUnits;
  final bool cullsRedundantUnits;
  final bool prioritizesBaronTargets;
  final bool leaderBiasedTargets;
  final bool enhancedAllure;
  final bool towersRequireFrontLine;
  final int towerDefenseThreshold;
  final bool cautiousFarms;
  final bool usesFiveTurnUnitForecast;
  final bool masterPlanning;
}

const _landAiProfiles = <_LandAiProfile>[
  _LandAiProfile(
    maxUnitStrength: 4,
    randomMovement: true,
    cleansTreesBeforeRandom: true,
    buildsUnitsInsideProvince: true,
    mergesUnits: true,
    mergesOnlyPeasants: true,
    mergeChanceDenominator: 4,
  ),
  _LandAiProfile(
    maxUnitStrength: 4,
    skipsHalfMoves: true,
    buildsUnitsInsideProvince: true,
    buildsTowers: true,
    buildsFarms: true,
    mergesUnits: true,
    cleansPalms: true,
    cleansTreesAfterAttack: true,
    repositionsDefense: true,
    prioritizesBaronTargets: true,
  ),
  _LandAiProfile(
    maxUnitStrength: 4,
    buildsTowers: true,
    buildsFarms: true,
    mergesUnits: true,
    cleansPalms: true,
    cleansTreesAfterAttack: true,
    repositionsDefense: true,
    movesAfkUnits: true,
    buildsStrongTowersDirectly: true,
    prioritizesBaronTargets: true,
  ),
  _LandAiProfile(
    maxUnitStrength: 4,
    buildsTowers: true,
    buildsFarms: true,
    mergesUnits: true,
    cleansPalms: true,
    cleansTreesAfterAttack: true,
    safeAttacks: true,
    repositionsDefense: true,
    movesAfkUnits: true,
    upgradesStrongTowers: true,
    prioritizesBaronTargets: true,
    towerDefenseThreshold: 4,
  ),
  _LandAiProfile(
    maxUnitStrength: 4,
    buildsTowers: true,
    buildsFarms: true,
    mergesUnits: true,
    cleansPalms: true,
    cleansTreesBeforeAttack: true,
    safeAttacks: true,
    usesBalancerSafety: true,
    repositionsDefense: true,
    usesDefenseGainReposition: true,
    movesAfkUnits: true,
    upgradesStrongTowers: true,
    reinforcesUnits: true,
    cullsRedundantUnits: true,
    prioritizesBaronTargets: true,
    leaderBiasedTargets: true,
    enhancedAllure: true,
    towersRequireFrontLine: true,
    towerDefenseThreshold: 3,
    cautiousFarms: true,
    usesFiveTurnUnitForecast: true,
  ),
  _LandAiProfile(
    maxUnitStrength: 4,
    buildsTowers: true,
    buildsFarms: true,
    mergesUnits: true,
    cleansPalms: true,
    cleansTreesBeforeAttack: true,
    safeAttacks: true,
    usesBalancerSafety: true,
    repositionsDefense: true,
    usesDefenseGainReposition: true,
    movesAfkUnits: true,
    upgradesStrongTowers: true,
    reinforcesUnits: true,
    prioritizesBaronTargets: true,
    leaderBiasedTargets: true,
    enhancedAllure: true,
    towersRequireFrontLine: true,
    towerDefenseThreshold: 3,
    cautiousFarms: true,
    masterPlanning: true,
  ),
];

/// A turn-local java.util.Random-compatible generator. It deliberately does
/// not consume or replace the simulation's global FastRandom stream.
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
      if (bits - value + (bound - 1) < (1 << 31)) return value;
    }
  }
}
