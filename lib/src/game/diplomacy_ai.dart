import 'dart:math' as math;

import 'game_engine.dart';
import 'models.dart';

enum DiplomacyTactic {
  secureBorder,
  relief,
  investment,
  trade,
  coalition,
  containLeader,
  recruitAgainstEnemy,
  negotiatePeace,
  pressure,
  counterOffer,
}

class DiplomacyPlan {
  const DiplomacyPlan({
    required this.other,
    required this.tactic,
    required this.terms,
    required this.rationale,
  });
  final int other;
  final DiplomacyTactic tactic;
  final List<DiplomacyTerm> terms;
  final String rationale;
}

/// One linear board scan, then bounded pair/contract arithmetic. This is a
/// conservative strategic forecast, not the authoritative settlement ledger.
class DiplomacyAiSnapshot {
  DiplomacyAiSnapshot(GameEngine engine) {
    final state = engine.state;
    final rules = engine.mod.rules;
    final n = state.config.playerCount;
    land = List.filled(n, 0);
    cash = List.filled(n, 0);
    income = List.filled(n, 0);
    upkeep = List.filled(n, 0);
    power = List.filled(n, 0.0);
    borders = List.generate(n, (_) => List.filled(n, 0));
    freeBorders = List.filled(n, 0);
    borderTiles = List.generate(n, (_) => List.generate(n, (_) => <int>[]));
    landNet = List.filled(state.hexes.length, 0);
    final fundedTiles = <int>{};
    for (final p in state.provinces) {
      land[p.owner] += p.tiles.length;
      cash[p.owner] += math.max(0, p.money);
      income[p.owner] += p.tiles.length;
      fundedTiles.addAll(p.tiles);
    }
    for (final tile in state.hexes) {
      visitedCells++;
      if (!tile.active) continue;
      final owner = tile.owner;
      if (owner >= 0 && owner < n) {
        for (final neighbor in tile.neighbors) {
          final other = state.hexes[neighbor];
          if (!other.active) continue;
          if (other.owner < 0) {
            freeBorders[owner]++;
          } else if (other.owner != owner) {
            borders[owner][other.owner]++;
            final candidates = borderTiles[owner][other.owner];
            if (candidates.length < 12 &&
                !candidates.contains(tile.index) &&
                tile.object != TileObject.town &&
                tile.unit == null &&
                tile.coalitionClaim == null) {
              candidates.add(tile.index);
            }
          }
        }
        if (fundedTiles.contains(tile.index)) {
          if (tile.hasTree) income[owner]--;
          if (tile.object == TileObject.farm && !state.config.slayRules) {
            income[owner] += rules.farmIncome;
          }
          final buildingUpkeep = switch (tile.object) {
            TileObject.tower => state.config.slayRules ? 0 : rules.towerUpkeep,
            TileObject.strongTower =>
              state.config.slayRules ? 0 : rules.strongTowerUpkeep,
            TileObject.port1 => rules.port1Upkeep,
            TileObject.port2 => rules.port2Upkeep,
            TileObject.artillery1 => rules.artilleryUpkeep[1],
            TileObject.artillery2 => rules.artilleryUpkeep[2],
            TileObject.artillery3 => rules.artilleryUpkeep[3],
            _ => 0,
          };
          upkeep[owner] += buildingUpkeep;
          landNet[tile.index] =
              1 -
              (tile.hasTree ? 1 : 0) +
              (tile.object == TileObject.farm && !state.config.slayRules
                  ? rules.farmIncome
                  : 0) -
              buildingUpkeep;
          if (tile.object == TileObject.tower) power[owner] += 4;
          if (tile.object == TileObject.strongTower) power[owner] += 8;
        }
      }
      final unit = tile.unit;
      if (unit != null) {
        final sovereign = engine.unitOwnerAt(tile.index);
        if (sovereign >= 0 && sovereign < n) {
          final cost = engine.unitUpkeepAtStrength(unit.strength);
          upkeep[sovereign] += cost;
          if (sovereign == owner) landNet[tile.index] -= cost;
          power[sovereign] += unit.strength * unit.strength * 4;
        }
      }
    }
    for (final cell in state.waterCells) {
      visitedCells++;
      final boat = cell.boat;
      if (boat != null) {
        final owner = boat.owner;
        upkeep[owner] +=
            (boat.level == 1 ? rules.boat1Upkeep : rules.boat2Upkeep) +
            math.max(0, rules.navalSupplyUpkeep);
        var transferCost = boat.level == 1
            ? rules.boat1Upkeep
            : rules.boat2Upkeep;
        for (final unit in boat.cargo) {
          transferCost += engine.unitUpkeepAtStrength(unit.strength) * 3 ~/ 2;
        }
        navalNet[NavalAssetRef(kind: NavalAssetKind.boat, id: boat.id)] =
            -transferCost;
        power[owner] += boat.level * 8;
        for (final unit in boat.cargo) {
          upkeep[owner] += engine.unitUpkeepAtStrength(unit.strength) * 3 ~/ 2;
          power[owner] += unit.strength * unit.strength * 2;
        }
      }
      final fort = cell.seaFort;
      if (fort != null) {
        upkeep[fort.owner] += rules.seaFortUpkeep;
        navalNet[NavalAssetRef(kind: NavalAssetKind.seaFort, id: fort.id)] =
            -rules.seaFortUpkeep;
        power[fort.owner] += 12;
      }
    }
    for (final contract in state.diplomacySubsidies) {
      if (contract.turnsLeft <= 0 ||
          (!contract.mandatory &&
              engine.areEnemies(contract.payer, contract.receiver))) {
        continue;
      }
      // Count the promised expense in full, but do not bank uncertain receipts.
      upkeep[contract.payer] += contract.amount;
    }
    net = [for (var p = 0; p < n; p++) income[p] - upkeep[p]];
    for (var p = 0; p < n; p++) {
      power[p] += land[p] * .65 + math.min(cash[p], 150) * .12;
    }
    alive = [
      for (var p = 0; p < n; p++)
        if (land[p] > 0) p,
    ];
    totalLand = land.fold(0, (sum, value) => sum + value);
  }
  late final List<int> land, cash, income, upkeep, net, freeBorders, alive;
  late final List<int> landNet;
  final Map<NavalAssetRef, int> navalNet = {};
  int assetNet(DiplomacyOffer offer) =>
      offer.tiles.fold(0, (sum, i) => sum + landNet[i]) +
      offer.navalRefs.fold(0, (sum, ref) => sum + (navalNet[ref] ?? 0));
  late final List<double> power;
  late final List<List<int>> borders;
  late final List<List<List<int>>> borderTiles;
  late final int totalLand;
  int visitedCells = 0;
  bool touches(int a, int b) => borders[a][b] > 0;
  bool distressed(int p) => net[p] < 0 || cash[p] < math.max(12, upkeep[p]);
  int reserve(int p, int horizon) => 10 + math.max(0, -net[p]) * horizon;
  int spare(int p, int horizon) => math.max(0, cash[p] - reserve(p, horizon));
}

/// Offline, deterministic utility negotiation. No language service or hidden
/// rule bypass: generated prose explains an executable, validated contract.
class StrategicDiplomacyAi {
  StrategicDiplomacyAi(this.engine) : snapshot = DiplomacyAiSnapshot(engine);
  final GameEngine engine;
  DiplomacyAiSnapshot snapshot;
  int evaluatedPlans = 0;
  int validatedPlans = 0;
  int snapshotsBuilt = 1;
  final Set<int> consideredPartners = {};
  DiplomacyTactic? chosenTactic;
  final Map<int, double> _blocPowerCache = {};
  final Map<(int, int), int?> _threatCache = {};
  GameState get state => engine.state;
  int get tier => state.config.difficulty.index;
  int get horizon => 2 + tier;
  int get candidateLimit => 2 + tier;
  int get contactGap => tier >= 4
      ? 3
      : tier >= 2
      ? 4
      : 8;
  double _blocPower(int player) => _blocPowerCache.putIfAbsent(
    player,
    () => engine
        .militaryAllianceComponent(player)
        .fold(0.0, (sum, p) => sum + _mobilizedPower(p)),
  );
  // A large treasury alone is not a sustainable army. Count only recruitment
  // that both cash and the next few turns' operating surplus can support.
  double _mobilizedPower(int p) =>
      snapshot.power[p] +
      math.min(
            snapshot.spare(p, horizon),
            math.max(0, snapshot.net[p]) * horizon,
          ) *
          .4;

  Set<int> _warOpponents(int owner, int target) => {
    ...engine.militaryAllianceComponent(target),
    for (final enemy in _enemies(owner))
      ...engine.militaryAllianceComponent(enemy),
  }..removeAll(engine.militaryAllianceComponent(owner));

  List<int> _enemies(int p) =>
      snapshot.alive.where((e) => engine.areEnemies(p, e)).toList();
  bool _commonEnemy(int a, int b) => snapshot.alive.any(
    (e) =>
        e != a && e != b && engine.areEnemies(a, e) && engine.areEnemies(b, e),
  );
  int? _sharedThreat(int a, int b) {
    final key = a < b ? (a, b) : (b, a);
    if (_threatCache.containsKey(key)) return _threatCache[key];
    final threats =
        snapshot.alive
            .where(
              (p) =>
                  p != a &&
                  p != b &&
                  !engine.areFriends(a, p) &&
                  !engine.areFriends(b, p) &&
                  (snapshot.touches(a, p) || engine.areEnemies(a, p)) &&
                  (snapshot.touches(b, p) || engine.areEnemies(b, p)) &&
                  (snapshot.power[p] >
                          math.min(snapshot.power[a], snapshot.power[b]) *
                              1.15 ||
                      snapshot.land[p] * 3 > snapshot.totalLand),
            )
            .toList()
          ..sort((x, y) => snapshot.power[y].compareTo(snapshot.power[x]));
    return _threatCache[key] = threats.firstOrNull;
  }

  double friendshipValue(int owner, int other) {
    if (!engine.canBecomeFriends(owner, other) ||
        engine.opinionOf(owner, other) < -15) {
      return -10000;
    }
    // An isolated, healthy country gains nothing from a decorative pact.
    var value = -6.0;
    if (snapshot.touches(owner, other)) {
      value += snapshot.freeBorders[owner] > 0 ? 20 : 6;
    }
    if (snapshot.distressed(owner)) {
      value += snapshot.touches(owner, other) ? 24 : 4;
    }
    if (_sharedThreat(owner, other) != null || _commonEnemy(owner, other)) {
      value += 20;
    }
    if (snapshot.touches(owner, other) && _enemies(owner).isNotEmpty) {
      value += 12;
    }
    if (snapshot.land[owner] * 2 > snapshot.totalLand) value -= 30;
    if (snapshot.alive.length == 2 && !snapshot.distressed(owner)) value -= 25;
    if (tier >= 3 &&
        snapshot.power[owner] > snapshot.power[other] * 1.7 &&
        snapshot.freeBorders[owner] == 0) {
      value -= 18;
    }
    return value;
  }

  double allianceValue(int owner, int other) {
    if (!engine.botWantsMilitaryAlliance(owner, other)) return -10000;
    final members = {
      ...engine.militaryAllianceComponent(owner),
      ...engine.militaryAllianceComponent(other),
    };
    var value = -18.0 - (members.length - 2) * 7;
    if (_sharedThreat(owner, other) != null) value += 55;
    if (_commonEnemy(owner, other)) value += 40;
    if (snapshot.touches(owner, other) && snapshot.freeBorders[owner] > 0) {
      value += 28;
    }
    if (snapshot.distressed(owner) &&
        snapshot.power[other] > snapshot.power[owner]) {
      value += 12;
    }
    if (snapshot.land[owner] * 2 >= snapshot.totalLand) value -= 80;
    if (snapshot.land[other] * 5 > snapshot.totalLand * 2 &&
        snapshot.land[other] > snapshot.land[owner] * 1.4) {
      value -= 45;
    }
    if (snapshot.power[other] < snapshot.power[owner] * .15) value -= 20;
    return value;
  }

  bool _blocConsents(int first, int second) {
    if (!engine.botWantsMilitaryAlliance(first, second)) return false;
    final a = engine.militaryAllianceComponent(first);
    final b = engine.militaryAllianceComponent(second);
    for (final member in {...a, ...b}) {
      if (state.isHuman(member)) continue;
      final partner = a.contains(member) ? second : first;
      if (allianceValue(member, partner) <= 0) return false;
    }
    return true;
  }

  double peaceValue(int owner, int other) {
    final ours = math.max(1.0, _blocPower(owner));
    final theirs = _blocPower(other);
    var value = 10.0 + math.max(0.0, theirs / ours - .75) * 55;
    if (snapshot.distressed(owner)) value += 30;
    if (_enemies(owner).length > 1) value += 20;
    if (!snapshot.touches(owner, other)) value += 8;
    if (ours > theirs * 1.8 &&
        snapshot.touches(owner, other) &&
        !snapshot.distressed(owner)) {
      value = 4;
    }
    return value.clamp(4, 160);
  }

  double warValue(int owner, int target, {int? supportingPlayer}) {
    if (owner == target ||
        engine.hasMilitaryAccess(owner, target) ||
        !engine.canDeclareWar(owner, target) ||
        !snapshot.touches(owner, target)) {
      return -10000;
    }
    final opponents = _warOpponents(owner, target);
    final theirs = math.max(
      1.0,
      opponents.fold(0.0, (sum, p) => sum + _mobilizedPower(p)),
    );
    var ours = math.max(1.0, _blocPower(owner));
    if (supportingPlayer != null &&
        engine.areEnemies(supportingPlayer, target)) {
      final independentSupport =
          engine.militaryAllianceComponent(supportingPlayer).toSet()
            ..removeAll(engine.militaryAllianceComponent(owner))
            ..removeAll(opponents);
      ours +=
          independentSupport.fold(0.0, (sum, p) => sum + _mobilizedPower(p)) *
          .5;
    }
    // Count each sovereign once across all fronts, even if multiple enemies
    // belong to one coalition. A payment cannot buy a plainly doomed war.
    if (ours < theirs * .6) return -10000;
    var result =
        30 * (ours / theirs - 1) + math.min(20, snapshot.land[target]) * .7;
    if (snapshot.distressed(owner)) result -= 28;
    if (engine.opinionOf(owner, target) >= 35) result -= 22;
    return result.clamp(-200, 100);
  }

  double _landValue(int owner, int giver, DiplomacyOffer offer) {
    var value = 0.0;
    for (final index in offer.tiles) {
      final tile = state.hexes[index];
      var base = engine.diplomacyLandPrice(index).toDouble();
      if (giver != owner && tile.object == TileObject.town) {
        // A capital tile is not a deed to the seller's entire province. Towns
        // regenerate after a split/merge, and the old treasury is not sold.
        // Appraise only the offered cells, not the empire behind the house.
        base = 25 + math.min(25, offer.tiles.length * 5).toDouble();
      }
      final neighbors = tile.neighbors
          .where((n) => state.hexes[n].owner == owner)
          .length;
      if (giver == owner) {
        final holdingValue =
            base + (tile.object == TileObject.town ? base : 0) + neighbors * 4;
        value += holdingValue * (snapshot.distressed(owner) ? .72 : 1);
        if (tile.unit != null) value += tile.unit!.strength * 15;
      } else {
        value += base * (neighbors > 0 ? 1.15 : .65);
        if (tile.object == TileObject.farm) value += 6 + tier * 2;
      }
    }
    final operating = snapshot.assetNet(offer);
    value += operating * horizon * (giver == owner ? 1.0 : .75);
    // Naval objects retain real appraised prices but no optimistic route bonus.
    for (final ref in offer.navalRefs) {
      value += engine.diplomacyNavalPrice(ref);
    }
    return value;
  }

  /// Values a complete contract from one sovereign's perspective. Existing
  /// commitments and all clauses share one budget; unfunded gifts/IOUs don't
  /// become imaginary buying power. The numeric trust is shared, utility isn't.
  double utility(int owner, int from, int to, List<DiplomacyTerm> terms) {
    final other = owner == from ? to : from;
    var score = 0.0;
    var cashLeft = snapshot.cash[owner];
    var otherCash = snapshot.cash[other];
    var promised = 0;
    var receivedCash = 0;
    var projectedNet = snapshot.net[owner];
    var otherNet = snapshot.net[other];
    var ownReplacedCost = 0;
    var otherReplacedCost = 0;
    final subsidyGivers = <int>{};
    // Project the whole exchange first, so clause order cannot hide lost farm
    // income, imported army upkeep or renewal of an existing subsidy.
    for (final term in terms) {
      final giver = term.fromSender ? from : to;
      final own = giver == owner;
      if (term.offer.type == DiplomacyExchangeType.lands) {
        final delta = snapshot.assetNet(term.offer) * (own ? -1 : 1);
        projectedNet += delta;
        otherNet -= delta;
      } else if (term.offer.type == DiplomacyExchangeType.subsidies) {
        if (!subsidyGivers.add(giver)) return -10000;
        for (final existing in state.diplomacySubsidies) {
          if (existing.payer != giver ||
              existing.receiver != (own ? other : owner) ||
              existing.mandatory ||
              existing.turnsLeft <= 0 ||
              engine.areEnemies(existing.payer, existing.receiver)) {
            continue;
          }
          if (own) {
            projectedNet += existing.amount;
            ownReplacedCost += existing.amount * existing.turnsLeft;
          } else {
            otherNet += existing.amount;
            otherReplacedCost +=
                existing.amount * math.min(horizon, existing.turnsLeft);
          }
        }
      }
    }
    var otherRecurringBudget = math.max(0, otherNet);
    var sold = 0;
    var peace = false;
    final relationTypes = <DiplomacyExchangeType>{};
    for (final term in terms) {
      final giver = term.fromSender ? from : to;
      final own = giver == owner;
      final offer = term.offer;
      switch (offer.type) {
        case DiplomacyExchangeType.nothing:
          continue;
        case DiplomacyExchangeType.friendship:
          if (relationTypes.add(offer.type)) {
            final duration = offer.duration > 0 ? offer.duration : 12;
            score +=
                friendshipValue(owner, other) *
                math.min(1.0, duration / horizon);
          }
        case DiplomacyExchangeType.militaryAlliance:
          if (!_blocConsents(from, to)) return -10000;
          if (relationTypes.add(offer.type)) {
            score += allianceValue(owner, other);
          }
        case DiplomacyExchangeType.ceasefire:
          peace = true;
          if (relationTypes.add(offer.type)) score += peaceValue(owner, other);
        case DiplomacyExchangeType.removeBlackMark:
          if (relationTypes.add(offer.type)) {
            score += _sharedThreat(owner, other) != null ? 18 : 3;
          }
        case DiplomacyExchangeType.money:
          if (own) {
            cashLeft -= offer.amount;
            score -= offer.amount;
          } else {
            final received = math.min(otherCash, offer.amount);
            otherCash -= received;
            receivedCash += received;
            score += received * (snapshot.distressed(owner) ? 1.25 : 1);
          }
        case DiplomacyExchangeType.subsidies:
          if (own) {
            promised += offer.amount;
            score -= offer.amount * offer.duration - ownReplacedCost.toDouble();
          } else {
            final reliable = math.min(offer.amount, otherRecurringBudget);
            otherRecurringBudget -= reliable;
            final trust = (.55 + engine.opinionOf(owner, other) / 200).clamp(
              .2,
              .95,
            );
            score +=
                (reliable * math.min(horizon, offer.duration) -
                    otherReplacedCost) *
                trust;
          }
        case DiplomacyExchangeType.lands:
          if (own) sold += offer.tiles.length;
          final value = _landValue(owner, giver, offer);
          score += own ? -value : value;
        case DiplomacyExchangeType.warDeclaration:
          if (own) {
            final value = warValue(
              owner,
              offer.targetPlayer,
              supportingPlayer: other,
            );
            if (value < -80 ||
                engine.opinionOf(owner, offer.targetPlayer) >= 50) {
              return -10000;
            }
            score += value - 18;
          } else {
            if (offer.targetPlayer == owner ||
                engine.hasMilitaryAccess(owner, offer.targetPlayer)) {
              return -10000;
            }
            score += engine.areEnemies(owner, offer.targetPlayer)
                ? 40
                : (_sharedThreat(owner, other) == offer.targetPlayer ? 25 : 0);
          }
      }
    }
    if (cashLeft < 0 || sold >= snapshot.land[owner]) return -10000;
    if (promised > math.max(0, projectedNet) ~/ 2 ||
        (promised > 0 && cashLeft < promised * math.min(3, horizon))) {
      return -10000;
    }
    if (!peace &&
        cashLeft < snapshot.reserve(owner, horizon) &&
        cashLeft < snapshot.cash[owner]) {
      return -10000;
    }
    final netAfter = projectedNet - promised;
    // A land/army purchase must not create an unfunded deficit. A distressed
    // seller may still exchange frontier land for enough cash to recover.
    if (netAfter < snapshot.net[owner] &&
        cashLeft + receivedCash + math.min(0, netAfter) * horizon < 10) {
      return -10000;
    }
    if (sold > 0 && sold * 3 >= snapshot.land[owner]) score -= 40;
    // A small relationship discount is bounded; nobody pays 100 for a smile.
    return score + engine.opinionOf(owner, other).clamp(-40, 40) * .04;
  }

  List<DiplomacyTerm> _proposalTerms(DiplomacyProposal p) =>
      p.type == DiplomacyProposalType.exchange
      ? p.effectiveTerms
      : [
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: switch (p.type) {
                DiplomacyProposalType.friendship =>
                  DiplomacyExchangeType.friendship,
                DiplomacyProposalType.militaryAlliance =>
                  DiplomacyExchangeType.militaryAlliance,
                DiplomacyProposalType.peace => DiplomacyExchangeType.ceasefire,
                DiplomacyProposalType.exchange => DiplomacyExchangeType.nothing,
              },
              duration: 10,
            ),
          ),
        ];

  bool accepts(int owner, DiplomacyProposal proposal) {
    final terms = _proposalTerms(proposal);
    return engine.exchangeValidationError(proposal.from, proposal.to, terms) ==
            null &&
        utility(owner, proposal.from, proposal.to, terms) >=
            (tier >= 3 ? 1 : 0);
  }

  bool canContact(int owner, int other) {
    final contact = state.diplomacySocial.lastContact;
    return state.round -
                math.max(contact[owner][other], contact[other][owner]) >=
            contactGap &&
        !state.diplomacyProposals.any(
          (p) =>
              (p.from == owner && p.to == other) ||
              (p.from == other && p.to == owner),
        ) &&
        (!state.isHuman(other) || engine.proposalsFor(other).length < 2);
  }

  List<DiplomacyPlan> plansFor(int owner, int other) {
    final plans = <DiplomacyPlan>[];
    final relation = engine.diplomacyBetween(owner, other);
    final spare = snapshot.spare(owner, horizon);
    final theirSpare = snapshot.spare(other, horizon);
    DiplomacyTerm give(DiplomacyOffer offer) =>
        DiplomacyTerm(fromSender: true, offer: offer);
    DiplomacyTerm ask(DiplomacyOffer offer) =>
        DiplomacyTerm(fromSender: false, offer: offer);
    DiplomacyOffer money(int amount) => DiplomacyOffer(
      type: DiplomacyExchangeType.money,
      amount: amount.clamp(1, 10000),
    );
    if (relation == DiplomacyStatus.war) {
      if (engine.diplomacyCooldown(owner, other) > 0) return plans;
      final weaker =
          _blocPower(owner) < _blocPower(other) || snapshot.distressed(owner);
      final payment = math.min(40, weaker ? spare ~/ 3 : theirSpare ~/ 4);
      plans.add(
        DiplomacyPlan(
          other: other,
          tactic: DiplomacyTactic.negotiatePeace,
          terms: [
            give(const DiplomacyOffer(type: DiplomacyExchangeType.ceasefire)),
            if (payment > 0)
              weaker ? give(money(payment)) : ask(money(payment)),
          ],
          rationale: weaker
              ? 'Соғысты тоқтатып, қазынаны қалпына келтірейік. Бітімге айырбас ретінде \$$payment ұсынамыз; екеуміз де әскер шығынын азайтамыз.'
              : 'Майдандағы басымдығымыз бар. \$$payment өтемақыға бітім ұсынамыз: сіз еліңізді сақтайсыз, біз соғыс шығынын тоқтатамыз.',
        ),
      );
      return plans;
    }
    final threat = _sharedThreat(owner, other);
    if (_blocConsents(owner, other)) {
      plans.add(
        DiplomacyPlan(
          other: other,
          tactic: threat == null
              ? DiplomacyTactic.coalition
              : DiplomacyTactic.containLeader,
          terms: [
            give(
              const DiplomacyOffer(
                type: DiplomacyExchangeType.militaryAlliance,
              ),
            ),
          ],
          rationale: threat == null
              ? 'Ортақ шекараны қауіпсіз етіп, сыртқа кеңейейік. Одақтағы әр елдің келісімі мен жеткілікті сенімі қажет.'
              : '${state.playerName(threat)} күшейіп келеді. Күшімізді біріктірсек, оның басымдығын тежеп, өз жерімізді қорғай аламыз.',
        ),
      );
    }
    if (relation == DiplomacyStatus.peace &&
        engine.canBecomeFriends(owner, other) &&
        engine.opinionOf(owner, other) >= -15) {
      final duration = tier >= 3 ? 6 : 10;
      final friendship = give(
        DiplomacyOffer(
          type: DiplomacyExchangeType.friendship,
          duration: duration,
        ),
      );
      final strongerPartner =
          snapshot.power[other] > snapshot.power[owner] * 1.25;
      {
        plans.add(
          DiplomacyPlan(
            other: other,
            tactic: DiplomacyTactic.secureBorder,
            terms: [friendship],
            rationale:
                '$duration ходқа шекараны тыныш ұстайық. Сіз шаруашылықты дамытасыз, біз басқа бағытқа назар аударамыз.',
          ),
        );
      }
      if (strongerPartner &&
          tier >= 1 &&
          spare >= 15 &&
          (snapshot.touches(owner, other) || threat != null)) {
        final payment = math.min(
          30,
          math.min(
            math.max(5, spare ~/ 4),
            math.max(1, friendshipValue(owner, other).floor() ~/ 2),
          ),
        );
        plans.add(
          DiplomacyPlan(
            other: other,
            tactic: DiplomacyTactic.secureBorder,
            terms: [give(money(payment)), friendship],
            rationale:
                'Сіздің еліңіз күштірек. $duration ход тыныш шекара үшін '
                '\$$payment ұсынамыз: сіз қазынаңызды толықтырасыз, біз қорғанысқа уақыт аламыз.',
          ),
        );
      }
      if (tier >= 1 &&
          snapshot.distressed(other) &&
          spare >= 15 &&
          (snapshot.touches(owner, other) || threat != null)) {
        final aid = math.min(25, spare ~/ 3);
        plans.add(
          DiplomacyPlan(
            other: other,
            tactic: DiplomacyTactic.relief,
            terms: [give(money(aid)), friendship],
            rationale:
                'Қазынаңызға \$$aid көмек ұсынамыз. Оның орнына $duration ход достық: сіз шығынды өтейсіз, біз қауіпсіз шекара аламыз.',
          ),
        );
      }
      if (tier >= 3 &&
          snapshot.touches(owner, other) &&
          snapshot.power[owner] > snapshot.power[other] * 1.7 &&
          theirSpare > 5) {
        final price = math.min(30, theirSpare ~/ 3);
        plans.add(
          DiplomacyPlan(
            other: other,
            tactic: DiplomacyTactic.pressure,
            terms: [friendship, ask(money(price))],
            rationale:
                'Шекарадағы күш арақатынасын ескеріңіз. \$$price үшін $duration ход қауіпсіздік ұсынамыз. Екеумізге де жаңа соғыс шығынынан тиімді.',
          ),
        );
      }
    }
    if (tier >= 2 &&
        engine.areFriends(owner, other) &&
        threat != null &&
        spare >= 20 &&
        snapshot.distressed(other) &&
        snapshot.net[owner] >= 6) {
      final amount = math.min(4, snapshot.net[owner] ~/ 3);
      plans.add(
        DiplomacyPlan(
          other: other,
          tactic: DiplomacyTactic.investment,
          terms: [
            give(
              DiplomacyOffer(
                type: DiplomacyExchangeType.subsidies,
                amount: amount,
                duration: 4,
              ),
            ),
          ],
          rationale:
              '${state.playerName(threat)}-ге қарсы тірек керек. Төрт ход бойы \$$amount көмекпен қорғанысыңызды сақтаңыз; біз ортақ қауіптің күшеюіне жол бермейміз.',
        ),
      );
    }
    if (tier >= 1) {
      for (final seller in [owner, other]) {
        final buyer = seller == owner ? other : owner;
        if (snapshot.land[seller] <= 4) continue;
        for (final index in snapshot.borderTiles[seller][buyer].take(
          2 + tier ~/ 2,
        )) {
          final land = DiplomacyOffer(
            type: DiplomacyExchangeType.lands,
            tiles: [index],
          );
          // Quote inside the overlap of both reservation prices. A solvent
          // seller does not sell below its actual strategic holding value.
          final minimum =
              (_landValue(seller, seller, land) /
                      (snapshot.distressed(seller) ? 1.25 : 1))
                  .ceil() +
              1;
          final maximum = math.min(
            snapshot.spare(buyer, horizon),
            _landValue(buyer, seller, land).floor() - 1,
          );
          if (maximum < minimum || maximum < 1) continue;
          final price = math.max(1, (minimum + maximum) ~/ 2);
          plans.add(
            DiplomacyPlan(
              other: other,
              tactic: DiplomacyTactic.trade,
              terms: seller == owner
                  ? [give(land), ask(money(price))]
                  : [ask(land), give(money(price))],
              rationale: seller == owner
                  ? 'Шекарадағы жерді \$$price-ға ұсынамыз. Сіз іргелес аумақ аласыз, біз бұл ақшаны елді нығайтуға жұмсаймыз.'
                  : 'Іргелес жеріңізге \$$price ұсынамыз. Сіз қазынаны толықтырасыз, біз аумақты біріктіріп дамытамыз.',
            ),
          );
        }
      }
    }
    if (tier >= 3 && spare >= 25) {
      for (final enemy in _enemies(owner).take(2)) {
        if (!engine.canDeclareWar(other, enemy) ||
            !snapshot.touches(other, enemy) ||
            engine.opinionOf(other, enemy) >= 35) {
          continue;
        }
        final price = math.min(35, spare ~/ 2);
        plans.add(
          DiplomacyPlan(
            other: other,
            tactic: DiplomacyTactic.recruitAgainstEnemy,
            terms: [
              give(money(price)),
              ask(
                DiplomacyOffer(
                  type: DiplomacyExchangeType.warDeclaration,
                  targetPlayer: enemy,
                ),
              ),
            ],
            rationale:
                '${state.playerName(enemy)}-ге екінші майдан ашсаңыз, \$$price төлейміз. Сіз көршілес бағытта мүмкіндік аласыз, біз қарсыластың күшін бөлеміз.',
          ),
        );
      }
    }
    return plans;
  }

  double _planScore(int owner, DiplomacyPlan plan, {bool validate = true}) {
    evaluatedPlans++;
    if (validate) {
      validatedPlans++;
      if (engine.exchangeValidationError(owner, plan.other, plan.terms) !=
          null) {
        return -10000;
      }
    }
    var ours = utility(owner, owner, plan.other, plan.terms);
    final theirs = utility(plan.other, owner, plan.other, plan.terms);
    if (plan.tactic == DiplomacyTactic.investment &&
        _sharedThreat(owner, plan.other) != null) {
      ours += 22;
    }
    if (plan.tactic == DiplomacyTactic.relief &&
        _sharedThreat(owner, plan.other) != null) {
      // A signature alone does not keep a collapsing buffer's army alive.
      // Value concrete stabilization above a cheaper but ineffective pact.
      ours += snapshot.net[plan.other] < 0 ? 35 : 10;
    }
    // Self-interest first, but don't send an obviously losing deal to either
    // a human or a bot. Strong tiers trade surplus to secure useful cooperation.
    if (ours < 1 || theirs < 0) return -10000;
    return ours +
        math.min(20.0, theirs) * .2 +
        (plan.tactic == DiplomacyTactic.negotiatePeace ? 8 : 0);
  }

  DiplomacyPlan? bestPlan(int owner) {
    final candidates =
        snapshot.alive.where((p) => p != owner && canContact(owner, p)).toList()
          ..sort((a, b) {
            double priority(int p) =>
                (snapshot.touches(owner, p) ? 30 : 0) +
                (engine.areEnemies(owner, p) ? 20 : 0) +
                (_sharedThreat(owner, p) != null ? 20 : 0) +
                (snapshot.distressed(p) ? 5 : 0) +
                engine.opinionOf(owner, p) * .1 +
                math.min(
                      16,
                      math.max(
                        0,
                        state.round -
                            state.diplomacySocial.lastContact[owner][p],
                      ),
                    ) *
                    .5;
            final result = priority(b).compareTo(priority(a));
            return result == 0 ? a.compareTo(b) : result;
          });
    final selected = candidates.take(candidateLimit).toList();
    final human = candidates
        .where(
          (p) =>
              state.isHuman(p) &&
              (snapshot.touches(owner, p) ||
                  engine.areEnemies(owner, p) ||
                  _sharedThreat(owner, p) != null),
        )
        .firstOrNull;
    if (human != null && !selected.contains(human)) {
      selected[selected.length - 1] = human;
    }
    DiplomacyPlan? best;
    var bestScore = 0.0;
    for (final other in selected) {
      consideredPartners.add(other);
      for (final plan in plansFor(owner, other)) {
        if (evaluatedPlans >= 64) break;
        // Generated candidates already contain real board refs. Rank their
        // cheap economic value first: only a contender needs the authoritative
        // (potentially flood-filling) territorial validation. Incoming offers
        // and counteroffers always validate before touching their refs.
        final score = _planScore(owner, plan, validate: false);
        if (score > bestScore) {
          validatedPlans++;
          if (engine.exchangeValidationError(owner, plan.other, plan.terms) !=
              null) {
            continue;
          }
          best = plan;
          bestScore = score;
        }
      }
    }
    return best;
  }

  bool _send(int owner, DiplomacyPlan plan) {
    if (!engine.proposeExchange(
      from: owner,
      to: plan.other,
      terms: plan.terms,
      rationale: plan.rationale,
    )) {
      return false;
    }
    chosenTactic = plan.tactic;
    // Both AIs evaluate from their own interest, never from the sender's score.
    if (!state.isHuman(plan.other)) {
      final proposal = engine
          .proposalsFor(plan.other)
          .firstWhere((p) => p.from == owner);
      engine.resolveDiplomacyProposal(
        proposal,
        accept: accepts(plan.other, proposal),
      );
    }
    return true;
  }

  DiplomacyPlan? counterOffer(int owner, DiplomacyProposal proposal) {
    if (tier < 2 || proposal.type != DiplomacyProposalType.exchange) {
      return null;
    }
    final other = proposal.from;
    if (state.isHuman(other) && engine.proposalsFor(other).length >= 2) {
      return null;
    }
    final reversed = [
      for (final term in proposal.effectiveTerms)
        DiplomacyTerm(fromSender: !term.fromSender, offer: term.offer),
    ];
    final cashIndex = reversed.indexWhere(
      (t) => t.offer.type == DiplomacyExchangeType.money,
    );
    if (cashIndex < 0) return null;
    final original = reversed[cashIndex];
    // Bounded bargaining band. Preserve land/war/duration; only quote a price.
    for (final adjustment in [5, 15, 30, 50]) {
      final amount =
          original.offer.amount +
          (original.fromSender ? -adjustment : adjustment);
      if (amount <= 0 || amount > 10000) continue;
      final terms = List<DiplomacyTerm>.from(reversed);
      terms[cashIndex] = DiplomacyTerm(
        fromSender: original.fromSender,
        offer: original.offer.copyWith(amount: amount),
      );
      final plan = DiplomacyPlan(
        other: other,
        tactic: DiplomacyTactic.counterOffer,
        terms: terms,
        rationale:
            'Бастапқы баға бізге тиімді емес. Ақша шартын \$$amount деп өзгертсек, екі жақтың мүддесі мен қазынасы теңгеріледі. Қалған шарттарыңыз сақталды.',
      );
      if (_planScore(owner, plan) > 0) return plan;
    }
    return null;
  }

  void takeTurn(int owner) {
    if (!state.config.diplomacy || state.winner != null) return;
    var sent = false;
    for (final proposal
        in engine.proposalsFor(owner).take(3 + tier ~/ 2).toList()) {
      final accept = accepts(owner, proposal);
      final counter = !accept && !sent ? counterOffer(owner, proposal) : null;
      final resolved = engine.resolveDiplomacyProposal(
        proposal,
        accept: accept,
      );
      if (resolved && accept) {
        snapshot = DiplomacyAiSnapshot(engine);
        snapshotsBuilt++;
        _blocPowerCache.clear();
        _threatCache.clear();
      } else if (resolved && counter != null) {
        sent = _send(owner, counter);
      }
      if (resolved && counter == null && state.isHuman(proposal.from)) {
        _reply(owner, proposal, accept);
      }
    }
    if (sent || snapshot.alive.length <= 1) return;
    if (_pursueSoloVictory(owner)) return;
    // Stronger bots look more often, not more randomly. Every offer still
    // obeys the same legality, treasury, inbox and bilateral cooldown limits.
    if (tier < 3 && (state.round + owner) % (tier < 2 ? 3 : 2) != 0) return;
    final plan = bestPlan(owner);
    // A token trade must not repeatedly postpone a clearly favorable campaign.
    // Preserve strategic pacts and recovery plans; only low-value trade competes.
    if (tier >= 3 &&
        (plan == null || plan.tactic == DiplomacyTactic.trade) &&
        _considerWar(owner, minimumValue: 35)) {
      return;
    }
    if (plan != null && _send(owner, plan)) return;
    if (_investInRelations(owner)) return;
    _considerWar(owner);
  }

  void _reply(int owner, DiplomacyProposal proposal, bool accepted) {
    // At most one response per pair/round, even if somebody submits many
    // offers. These letters explain the decision; they are not extra treaties.
    if (state.diplomacyMessages.any(
      (m) =>
          m.from == owner &&
          m.to == proposal.from &&
          m.createdRound == state.round,
    )) {
      return;
    }
    final terms = _proposalTerms(proposal);
    final types = terms.map((t) => t.offer.type).toSet();
    final String reason;
    if (accepted) {
      reason =
          'Келісеміз. Ұсынылған шарттар орындалды: бұл келісім қазіргі мүдделерімізге сай.';
    } else if (types.contains(DiplomacyExchangeType.militaryAlliance)) {
      reason =
          engine.botAllianceAdmissionError(owner, proposal.from) ??
          'Қатынасымыз жақсы болуы жеткіліксіз. Әр одақтасқа ортақ қауіп пен нақты пайда керек; қазір бұл одақ стратегиямызға сай емес.';
    } else if (types.contains(DiplomacyExchangeType.warDeclaration)) {
      reason =
          'Бұл соғысқа кірмейміз. Күш арақатынасы, қазіргі майдандар мен міндеттемелеріміз тәуекелді ақтамайды.';
    } else if (snapshot.distressed(owner)) {
      reason =
          'Қазір қазына мен әскерді сақтап қалу маңызды. Шығынымызды азайтатын немесе қолма-қол көмек беретін шарт ұсыныңыз.';
    } else {
      reason =
          'Бұл шарт бізге жеткілікті пайда бермейді. Бағаны, шекарадағы жерді немесе қауіпсіздік шартын өзгертсеңіз, қайта қараймыз.';
    }
    engine.sendDiplomacyMessage(from: owner, to: proposal.from, text: reason);
  }

  bool _investInRelations(int owner) {
    if (tier < 2 || snapshot.spare(owner, horizon) < 25) return false;
    for (final other in snapshot.alive) {
      if (other == owner ||
          !canContact(owner, other) ||
          _sharedThreat(owner, other) == null ||
          engine.areEnemies(owner, other) ||
          engine.hasBlackMark(owner, other)) {
        continue;
      }
      final needed = engine.militaryAllianceTrustRequired(owner, other);
      final score = engine.opinionOf(owner, other);
      if (score >= needed || score < needed - 24) continue;
      if (engine.influenceOpinion(owner, other, improve: true)) {
        state.diplomacySocial.lastContact[owner][other] = state.round;
        return true;
      }
    }
    return false;
  }

  bool _pursueSoloVictory(int owner) {
    if (tier < 3 || state.round < 8) return false;
    for (final other in snapshot.alive) {
      if (other == owner || !engine.areFriends(owner, other)) continue;
      final wholeWorldBloc =
          engine.militaryAllianceComponent(owner).length >=
          snapshot.alive.length;
      final endgameAdvantage =
          snapshot.land[owner] * 5 >= snapshot.totalLand * 2 &&
          snapshot.power[owner] > snapshot.power[other] * 1.8 &&
          snapshot.touches(owner, other);
      if (!wholeWorldBloc && !(tier >= 4 && endgameAdvantage)) continue;
      if (state.diplomacyRelations[owner][other] == DiplomacyStatus.alliance) {
        final fine = engine.friendshipBreakCompensationTotal(owner, other);
        if (snapshot.spare(owner, horizon) < fine + 30 ||
            snapshot.net[owner] <= 5) {
          continue;
        }
      }
      if (engine.worsenDiplomacy(owner, other)) {
        engine.sendDiplomacyMessage(
          from: owner,
          to: other,
          text:
              'Біздің мүдделер өзгерді. Одақты тоқтатамыз; қолданыстағы бітім мен өтемақы міндеттерін орындаймыз.',
        );
        return true; // no instant betrayal + war in a single diplomatic action
      }
    }
    return false;
  }

  bool _considerWar(int owner, {double? minimumValue}) {
    if (state.round < 4 || snapshot.distressed(owner)) return false;
    if ((state.round * 7 + owner * 3 + state.config.seed) %
            (tier >= 3 ? 2 : 6) !=
        0) {
      return false;
    }
    var best = minimumValue ?? (tier >= 3 ? 12.0 : 24.0);
    int? target;
    for (final other in snapshot.alive) {
      final score = warValue(owner, other);
      if (score > best) {
        best = score;
        target = other;
      }
    }
    return target != null && engine.declareWar(owner, target);
  }
}
