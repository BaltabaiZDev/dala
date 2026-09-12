import 'dart:math' as math;

import '../modding/game_mod.dart';
import 'models.dart';

part 'diplomacy_rules.dart';

class EconomicBreakdown {
  const EconomicBreakdown({
    required this.land,
    required this.farms,
    required this.diplomacy,
    required this.landUnits,
    required this.cargoUnits,
    required this.towers,
    required this.artillery,
    required this.trees,
    required this.ports,
    required this.boats,
    required this.seaForts,
    required this.navalTransfer,
    required this.navalSupport,
  });

  final int land;
  final int farms;
  final int diplomacy;
  final int landUnits;
  final int cargoUnits;
  final int towers;
  final int artillery;
  final int trees;
  final int ports;
  final int boats;
  final int seaForts;
  final int navalTransfer;
  final int navalSupport;

  int get units => landUnits + cargoUnits;

  int get total =>
      land +
      farms +
      diplomacy +
      landUnits +
      cargoUnits +
      towers +
      artillery +
      trees +
      ports +
      boats +
      seaForts +
      navalTransfer +
      navalSupport;

  EconomicBreakdown operator +(EconomicBreakdown other) => EconomicBreakdown(
    land: land + other.land,
    farms: farms + other.farms,
    diplomacy: diplomacy + other.diplomacy,
    landUnits: landUnits + other.landUnits,
    cargoUnits: cargoUnits + other.cargoUnits,
    towers: towers + other.towers,
    artillery: artillery + other.artillery,
    trees: trees + other.trees,
    ports: ports + other.ports,
    boats: boats + other.boats,
    seaForts: seaForts + other.seaForts,
    navalTransfer: navalTransfer + other.navalTransfer,
    navalSupport: navalSupport + other.navalSupport,
  );

  static const zero = EconomicBreakdown(
    land: 0,
    farms: 0,
    diplomacy: 0,
    landUnits: 0,
    cargoUnits: 0,
    towers: 0,
    artillery: 0,
    trees: 0,
    ports: 0,
    boats: 0,
    seaForts: 0,
    navalTransfer: 0,
    navalSupport: 0,
  );
}

class ArtilleryStrike {
  const ArtilleryStrike({
    required this.fromTile,
    required this.toWaterCell,
    required this.sourceOwner,
    required this.targetOwner,
    required this.targetLevel,
    required this.destroyed,
  });

  final int fromTile;
  final int toWaterCell;
  final int sourceOwner;
  final int targetOwner;
  final int targetLevel;
  final bool destroyed;
}

/// Groups each cannon's first shot into one simultaneous volley, then every
/// cannon's second shot, and so on. This keeps the cinematic duration tied to
/// the strongest cannon rather than to the total number of cannons.
List<List<ArtilleryStrike>> artilleryStrikeVolleys(
  List<ArtilleryStrike> strikes,
) {
  final bySource = <int, List<ArtilleryStrike>>{};
  for (final strike in strikes) {
    bySource.putIfAbsent(strike.fromTile, () => []).add(strike);
  }
  final volleyCount = bySource.values.fold<int>(
    0,
    (longest, source) => math.max(longest, source.length),
  );
  return [
    for (var volley = 0; volley < volleyCount; volley++)
      [
        for (final source in bySource.values)
          if (volley < source.length) source[volley],
      ],
  ];
}

enum SeaFortBuildBlock {
  noBoat,
  enemyBoat,
  levelTwoRequired,
  boatAlreadyActed,
  missingHomeProvince,
  insufficientFunds,
  noOpenNeighbor,
}

class GameEngine {
  GameEngine({required this.mod, required this.state}) {
    // Legacy military treaties had no timer. Give them a finite grace period.
    for (var a = 0; a < state.config.playerCount; a++) {
      for (var b = a + 1; b < state.config.playerCount; b++) {
        if (state.diplomacyRelations[a][b] == DiplomacyStatus.coalition &&
            state.diplomacyAllianceTurns[a][b] <= 0) {
          state.diplomacyAllianceTurns[a][b] = 12;
          state.diplomacyAllianceTurns[b][a] = 12;
        }
      }
    }
    for (final tile in state.hexes) {
      if (tile.unit != null) _normalizeUnitIdentity(tile.index);
    }
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null) continue;
      _normalizeCargoFunding(boat);
    }
  }

  static const int slayPortMinimumTiles = 5;
  static const int slayArtilleryMinimumTiles = 7;
  static const int slayPort2MinimumTiles = 10;
  static const int slayArtillery2MinimumTiles = 10;
  static const int slayArtillery3MinimumTiles = 14;
  static const int seaMintReward = 7;
  static const double seaMintSpreadChance = .16;

  final GameMod mod;
  final GameState state;
  final List<ArtilleryStrike> lastArtilleryStrikes = [];
  bool _settlingCampaigns = false;

  Province? provinceAt(int tileIndex) {
    for (final province in state.provinces) {
      if (province.tiles.contains(tileIndex)) return province;
    }
    return null;
  }

  Iterable<Province> provincesOf(int owner) =>
      state.provinces.where((province) => province.owner == owner);

  /// Land troops keep their sovereign owner and funding province even while
  /// standing on a military ally's territory. Legacy units use the containing
  /// tile/province until they are first normalized by the engine.
  int unitOwnerAt(int tileIndex) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return -1;
    final tile = state.hexes[tileIndex];
    final unit = tile.unit;
    if (unit == null) return -1;
    return unit.owner >= 0 ? unit.owner : tile.owner;
  }

  int unitHomeProvinceAt(int tileIndex) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return -1;
    final tile = state.hexes[tileIndex];
    final unit = tile.unit;
    if (unit == null) return -1;
    if (unit.homeProvinceId >= 0) return unit.homeProvinceId;
    final owner = unitOwnerAt(tileIndex);
    if (tile.owner == owner) return provinceAt(tileIndex)?.id ?? -1;
    return provincesOf(owner).fold<Province?>(null, (best, item) {
          if (best == null || item.tiles.length > best.tiles.length) {
            return item;
          }
          if (item.tiles.length == best.tiles.length && item.id < best.id) {
            return item;
          }
          return best;
        })?.id ??
        -1;
  }

  void _normalizeUnitIdentity(
    int tileIndex, {
    int? owner,
    int? homeProvinceId,
  }) {
    final unit = state.hexes[tileIndex].unit;
    if (unit == null) return;
    unit.owner = owner ?? unitOwnerAt(tileIndex);
    unit.homeProvinceId =
        homeProvinceId ??
        (unit.homeProvinceId >= 0
            ? unit.homeProvinceId
            : unitHomeProvinceAt(tileIndex));
    unit.transitAllies
      ..removeWhere((player) => player < 0 || player == unit.owner)
      ..sort();
  }

  void _normalizeCargoFunding(GameBoat boat) {
    for (final unit in boat.cargo) {
      unit
        ..owner = boat.owner
        ..homeProvinceId = boat.homeProvinceId;
      final transit =
          unit.transitAllies
              .where(
                (player) =>
                    player >= 0 &&
                    player < state.config.playerCount &&
                    player != unit.owner,
              )
              .toSet()
              .toList()
            ..sort();
      unit.transitAllies
        ..clear()
        ..addAll(transit);
    }
  }

  void _fundUnitOnOwnLand(HexTile tile) {
    final unit = tile.unit;
    if (unit == null ||
        tile.coalitionClaim != null ||
        tile.owner != unit.owner) {
      return;
    }
    final province = provinceAt(tile.index);
    if (province?.owner == unit.owner) unit.homeProvinceId = province!.id;
  }

  int playerMoney(int owner) =>
      provincesOf(owner).fold(0, (sum, province) => sum + province.money);

  int playerLandCount(int owner) => provincesOf(
    owner,
  ).fold(0, (sum, province) => sum + province.tiles.length);

  int friendCount(int owner) =>
      List<int>.generate(state.config.playerCount, (index) => index)
          .where(
            (other) =>
                other != owner && _isAlive(other) && areAllies(owner, other),
          )
          .length;

  bool kingdomsTouch(int first, int second) {
    for (final province in provincesOf(first)) {
      for (final index in province.tiles) {
        if (state.hexes[index].neighbors.any(
          (neighbor) => state.hexes[neighbor].owner == second,
        )) {
          return true;
        }
      }
    }
    return false;
  }

  WaterCell? waterCellById(int index) =>
      index >= 0 && index < state.waterCells.length
      ? state.waterCells[index]
      : null;

  DiplomacyStatus diplomacyBetween(int first, int second) {
    if (first == second) return DiplomacyStatus.alliance;
    if (!state.config.diplomacy) return DiplomacyStatus.war;
    if (first < 0 ||
        second < 0 ||
        first >= state.config.playerCount ||
        second >= state.config.playerCount) {
      return DiplomacyStatus.war;
    }
    return state.diplomacyRelations[first][second];
  }

  bool areEnemies(int first, int second) =>
      first != second &&
      (first < 0 ||
          second < 0 ||
          diplomacyBetween(first, second) == DiplomacyStatus.war);

  bool areFriends(int first, int second) =>
      first == second ||
      diplomacyBetween(first, second) == DiplomacyStatus.alliance ||
      hasMilitaryAccess(first, second);

  bool areAllies(int first, int second) => areFriends(first, second);

  /// Returns the complete, deterministic military-alliance component. A-B
  /// and B-C therefore grants A/C open borders and puts all three countries
  /// on the same side of a war.
  Set<int> militaryAllianceComponent(int owner) {
    final alive = state.provinces.map((province) => province.owner).toSet();
    if (owner < 0 ||
        owner >= state.config.playerCount ||
        !alive.contains(owner)) {
      return <int>{};
    }
    if (!state.config.diplomacy) return {owner};
    final reached = <int>{owner};
    final queue = <int>[owner];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final current = queue[cursor];
      for (var other = 0; other < state.config.playerCount; other++) {
        if (reached.contains(other) || !alive.contains(other)) continue;
        if (diplomacyBetween(current, other) == DiplomacyStatus.coalition) {
          reached.add(other);
          queue.add(other);
        }
      }
    }
    return reached;
  }

  bool hasMilitaryAccess(int first, int second) =>
      first == second || militaryAllianceComponent(first).contains(second);

  void setDiplomacyStatus(int first, int second, DiplomacyStatus status) {
    if (!state.config.diplomacy ||
        first == second ||
        first < 0 ||
        second < 0 ||
        first >= state.config.playerCount ||
        second >= state.config.playerCount) {
      return;
    }
    final previous = state.diplomacyRelations[first][second];
    state.diplomacyRelations[first][second] = status;
    state.diplomacyRelations[second][first] = status;
    if (previous != status) {
      final (delta, reason) = switch (status) {
        DiplomacyStatus.war => (-45, 'Соғыс басталды'),
        DiplomacyStatus.coalition => (20, 'Әскери одақ құрылды'),
        DiplomacyStatus.alliance when previous != DiplomacyStatus.coalition => (
          20,
          'Достық келісімі',
        ),
        DiplomacyStatus.peace when previous == DiplomacyStatus.war => (
          12,
          'Бітім жасалды',
        ),
        _ => (0, ''),
      };
      changeOpinion(first, second, delta, reason);
    }
    if (status == DiplomacyStatus.coalition && previous != status) {
      state.diplomacyAllianceTurns[first][second] = 12;
      state.diplomacyAllianceTurns[second][first] = 12;
    } else if (status != DiplomacyStatus.alliance &&
        status != DiplomacyStatus.coalition) {
      state.diplomacyAllianceTurns[first][second] = 0;
      state.diplomacyAllianceTurns[second][first] = 0;
    }
    // A ceasefire lock belongs to the pair, not to the current relation label.
    // Preserve it through a later friendship so alliance -> peace cannot be
    // used to bypass the remaining no-war period.
    if (status == DiplomacyStatus.war && previous != DiplomacyStatus.war) {
      _clearHostileObligations(first, second);
    }
  }

  int diplomacyCooldown(int first, int second) {
    if (first < 0 ||
        second < 0 ||
        first >= state.config.playerCount ||
        second >= state.config.playerCount) {
      return 0;
    }
    return state.diplomacyWarCooldowns[first][second];
  }

  int allianceTurnsLeft(int first, int second) {
    if (first < 0 ||
        second < 0 ||
        first >= state.config.playerCount ||
        second >= state.config.playerCount) {
      return 0;
    }
    return state.diplomacyAllianceTurns[first][second];
  }

  /// Classic Antiyoy charges a friendship breaker roughly one third of their
  /// state profit (at least $5) per turn and pays it to the former friend. This
  /// mod keeps that rate but ties the duration to the friendship time that was
  /// actually left when it was broken.
  int friendshipBreakFinePerTurn(int breaker) => _traitorFine(breaker);

  int friendshipBreakCompensationTurns(int first, int second) {
    if (!_validDiplomacyPair(first, second) ||
        diplomacyBetween(first, second) != DiplomacyStatus.alliance) {
      return 0;
    }
    return math.max(1, allianceTurnsLeft(first, second));
  }

  int friendshipBreakCompensationTotal(int breaker, int formerFriend) =>
      friendshipBreakFinePerTurn(breaker) *
      friendshipBreakCompensationTurns(breaker, formerFriend);

  bool hasBlackMark(int first, int second) =>
      _validDiplomacyIndexes(first, second) &&
      state.diplomacyBlackMarks[first][second];

  int blackMarkCooldown(int first, int second) =>
      _validDiplomacyIndexes(first, second)
      ? state.diplomacyBlackMarkCooldowns[first][second]
      : 0;

  bool canBecomeFriends(int first, int second) {
    if (!_validDiplomacyPair(first, second) || hasBlackMark(first, second)) {
      return false;
    }
    for (var other = 0; other < state.config.playerCount; other++) {
      if (other == first || other == second || !_isAlive(other)) continue;
      final linked = areFriends(first, other) || areFriends(second, other);
      if (linked &&
          (hasBlackMark(first, other) || hasBlackMark(second, other))) {
        return false;
      }
    }
    return true;
  }

  bool placeBlackMark(int first, int second) {
    if (!_validDiplomacyPair(first, second) ||
        hasBlackMark(first, second) ||
        blackMarkCooldown(first, second) > 0) {
      return false;
    }
    final lostFriends = <int>[
      if (areFriends(first, second)) first,
      for (var friend = 0; friend < state.config.playerCount; friend++)
        if (friend != first &&
            friend != second &&
            _isAlive(friend) &&
            areFriends(first, friend) &&
            areFriends(second, friend))
          friend,
    ];
    if (lostFriends.any((friend) => _allianceEdgeIsLocked(second, friend))) {
      return false;
    }
    state.diplomacyBlackMarks[first][second] = true;
    state.diplomacyBlackMarks[second][first] = true;
    changeOpinion(second, first, -35, 'Қара белгі қойды');
    sendDiplomacyMessage(
      from: first,
      to: second,
      text: '${state.playerName(first)} сізге қара белгі қойды',
    );
    // In this mod a black mark is stronger than the Classic Antiyoy default:
    // the marked player cannot remain allied with the marker's friends.
    // Keep the marker's own alliances intact and dissolve only the conflicting
    // target-to-friend links.
    for (final friend in lostFriends) {
      setDiplomacyStatus(second, friend, DiplomacyStatus.peace);
      _logDiplomacy(
        '${state.playerName(second)} және ${state.playerName(friend)} достығы қара белгіге байланысты тоқтады',
      );
    }
    _logDiplomacy(
      '${state.playerName(first)} ${state.playerName(second)} ойыншысына қара белгі қойды',
    );
    _updateWinner();
    return true;
  }

  bool removeBlackMark(int first, int second) {
    if (!_validDiplomacyPair(first, second) || !hasBlackMark(first, second)) {
      return false;
    }
    state.diplomacyBlackMarks[first][second] = false;
    state.diplomacyBlackMarks[second][first] = false;
    state.diplomacyBlackMarkCooldowns[first][second] = 10;
    state.diplomacyBlackMarkCooldowns[second][first] = 10;
    changeOpinion(first, second, 10, 'Қара белгі алынды');
    _logDiplomacy(
      '${state.playerName(first)} және ${state.playerName(second)} арасындағы қара белгі алынды',
    );
    return true;
  }

  bool improveDiplomacy(int first, int second) {
    if (!_validDiplomacyPair(first, second)) return false;
    switch (diplomacyBetween(first, second)) {
      case DiplomacyStatus.war:
        if (diplomacyCooldown(first, second) > 0) return false;
        return makePeace(first, second);
      case DiplomacyStatus.peace:
        if (!canBecomeFriends(first, second)) return false;
        setDiplomacyStatus(first, second, DiplomacyStatus.alliance);
        state.diplomacyAllianceTurns[first][second] = 12;
        state.diplomacyAllianceTurns[second][first] = 12;
        _removeDiplomacyProposalsBetween(first, second);
        _logDiplomacy(
          '${state.playerName(first)} және ${state.playerName(second)} достық құрды',
        );
        _updateWinner();
        return true;
      case DiplomacyStatus.alliance:
        return false;
      case DiplomacyStatus.coalition:
        return false;
    }
  }

  bool worsenDiplomacy(int first, int second) {
    if (!_validDiplomacyPair(first, second)) return false;
    switch (diplomacyBetween(first, second)) {
      case DiplomacyStatus.coalition:
        if (_allianceEdgeIsLocked(first, second)) return false;
        setDiplomacyStatus(first, second, DiplomacyStatus.alliance);
        changeOpinion(second, first, -35, 'Әскери одақтан шықты');
        state.diplomacyAllianceTurns[first][second] = 12;
        state.diplomacyAllianceTurns[second][first] = 12;
        _logDiplomacy(
          '${state.playerName(first)} және ${state.playerName(second)} әскери альянсты тоқтатты',
        );
        return true;
      case DiplomacyStatus.alliance:
        final turns = friendshipBreakCompensationTurns(first, second);
        final fine = friendshipBreakFinePerTurn(first);
        _addFriendshipBreakCompensation(
          payer: first,
          receiver: second,
          amount: fine,
          turns: turns,
        );
        setDiplomacyStatus(first, second, DiplomacyStatus.peace);
        changeOpinion(second, first, -30, 'Достықты мерзімінен бұрын тоқтатты');
        _logDiplomacy(
          '${state.playerName(first)} достықты тоқтатты және '
          '${state.playerName(second)} ойыншысына $fine ақша × $turns ход өтем төлейді',
        );
        return true;
      case DiplomacyStatus.peace:
        if (diplomacyCooldown(first, second) > 0) return false;
        return declareWar(first, second);
      case DiplomacyStatus.war:
        return false;
    }
  }

  bool canFormMilitaryAlliance(int first, int second) {
    final relation = diplomacyBetween(first, second);
    if (!_validDiplomacyPair(first, second) ||
        (relation != DiplomacyStatus.peace &&
            relation != DiplomacyStatus.alliance) ||
        hasBlackMark(first, second)) {
      return false;
    }
    final firstSide = militaryAllianceComponent(first);
    final secondSide = militaryAllianceComponent(second);
    // Campaign membership and contribution quotas are a fixed contract. A
    // late ally must not acquire access without inheriting that contract's war.
    if (_militaryCommitmentsPending({...firstSide, ...secondSide})) {
      return false;
    }
    for (final a in firstSide) {
      for (final b in secondSide) {
        if (a != b && (areEnemies(a, b) || !canBecomeFriends(a, b))) {
          return false;
        }
      }
    }
    return botAllianceAdmissionError(first, second) == null;
  }

  bool formMilitaryAlliance(int first, int second, {int duration = 12}) {
    if (duration < 1 || duration > 20) return false;
    if (_validDiplomacyPair(first, second) &&
        diplomacyBetween(first, second) == DiplomacyStatus.coalition) {
      return true;
    }
    if (!canFormMilitaryAlliance(first, second)) return false;
    setDiplomacyStatus(first, second, DiplomacyStatus.coalition);
    state.diplomacyAllianceTurns[first][second] = duration;
    state.diplomacyAllianceTurns[second][first] = duration;
    _removeDiplomacyProposalsBetween(first, second);
    _logDiplomacy(
      '${state.playerName(first)} және ${state.playerName(second)} әскери альянс құрды',
    );
    return true;
  }

  bool _allianceEdgeIsLocked(int first, int second) {
    final component = militaryAllianceComponent(first);
    if (!component.contains(second)) return false;
    if (_militaryCommitmentsPending(component)) return true;
    for (final tile in state.hexes) {
      final unit = tile.unit;
      if (unit == null) continue;
      final owner = unitOwnerAt(tile.index);
      if (owner != tile.owner &&
          component.contains(owner) &&
          component.contains(tile.owner)) {
        return true;
      }
    }
    return false;
  }

  bool _militaryCommitmentsPending(Set<int> members) =>
      state.campaigns.any(
        (campaign) =>
            campaign.sideA.any(members.contains) ||
            campaign.sideB.any(members.contains),
      ) ||
      state.peaceConferences.any(
        (conference) => conference.participants.any(members.contains),
      );

  bool proposeDiplomacy(int from, int to, DiplomacyProposalType type) {
    if (!_validDiplomacyPair(from, to)) return false;
    final expected = switch (type) {
      DiplomacyProposalType.friendship => DiplomacyStatus.peace,
      DiplomacyProposalType.peace => DiplomacyStatus.war,
      DiplomacyProposalType.militaryAlliance => DiplomacyStatus.alliance,
      DiplomacyProposalType.exchange => null,
    };
    if (expected == null) return false;
    if (type != DiplomacyProposalType.militaryAlliance &&
        diplomacyBetween(from, to) != expected) {
      return false;
    }
    if (type == DiplomacyProposalType.peace &&
        diplomacyCooldown(from, to) > 0) {
      return false;
    }
    if (type == DiplomacyProposalType.friendship &&
        !canBecomeFriends(from, to)) {
      return false;
    }
    if (type == DiplomacyProposalType.militaryAlliance &&
        !canFormMilitaryAlliance(from, to)) {
      return false;
    }
    final duplicate = state.diplomacyProposals.any(
      (proposal) =>
          proposal.from == from && proposal.to == to && proposal.type == type,
    );
    if (duplicate) return false;
    state.diplomacyProposals.add(
      DiplomacyProposal(
        from: from,
        to: to,
        type: type,
        createdRound: state.round,
      ),
    );
    state.diplomacySocial.lastContact[from][to] = state.round;
    final label = switch (type) {
      DiplomacyProposalType.friendship => 'достық',
      DiplomacyProposalType.peace => 'бітім',
      DiplomacyProposalType.militaryAlliance => 'әскери альянс',
      DiplomacyProposalType.exchange => 'келісім',
    };
    _logDiplomacy(
      '${state.playerName(from)} ${state.playerName(to)} ойыншысына $label ұсынды',
    );
    return true;
  }

  bool proposeExchange({
    required int from,
    required int to,
    DiplomacyOffer fromOffer = const DiplomacyOffer(),
    DiplomacyOffer toOffer = const DiplomacyOffer(),
    List<DiplomacyTerm>? terms,
    String rationale = '',
  }) {
    if (rationale.length > 400) return false;
    final conditions =
        terms ??
        [
          DiplomacyTerm(fromSender: true, offer: fromOffer),
          DiplomacyTerm(fromSender: false, offer: toOffer),
        ];
    if (exchangeValidationError(from, to, conditions) != null) {
      return false;
    }
    state.diplomacyProposals.removeWhere(
      (proposal) => proposal.from == from && proposal.to == to,
    );
    state.diplomacyProposals.add(
      DiplomacyProposal(
        from: from,
        to: to,
        type: DiplomacyProposalType.exchange,
        createdRound: state.round,
        fromOffer: fromOffer,
        toOffer: toOffer,
        terms: terms == null ? null : List.unmodifiable(terms),
        rationale: rationale.trim(),
      ),
    );
    state.diplomacySocial.lastContact[from][to] = state.round;
    _logDiplomacy(
      '${state.playerName(from)} ${state.playerName(to)} ойыншысына келісім жіберді',
    );
    return true;
  }

  bool resolveDiplomacyProposal(
    DiplomacyProposal proposal, {
    required bool accept,
  }) {
    if (!state.diplomacyProposals.contains(proposal)) return false;
    if (!accept) {
      state.diplomacyProposals.remove(proposal);
      // One remembered refusal per pair/round, never a score-per-click exploit.
      changeOpinion(proposal.from, proposal.to, -2, 'Ұсынысты қабылдамады');
      _logDiplomacy('${state.playerName(proposal.to)} ұсынысты қабылдамады');
      return true;
    }
    if (proposal.type == DiplomacyProposalType.exchange) {
      final terms = proposal.effectiveTerms;
      if (exchangeValidationError(proposal.from, proposal.to, terms) != null) {
        return false;
      }
      state.diplomacyProposals.remove(proposal);
      final normalized = _normalizedTerms(terms);
      // Money/obligations use the original sovereign treasury before any
      // land changes. Both sides' assets then transfer before a single rebuild.
      for (final term in normalized.where(
        (t) => t.offer.type != DiplomacyExchangeType.lands,
      )) {
        _performOffer(
          term.fromSender ? proposal.from : proposal.to,
          term.fromSender ? proposal.to : proposal.from,
          term.offer,
        );
      }
      final hasTerritorialTransfer = normalized.any(
        (t) => t.offer.type == DiplomacyExchangeType.lands,
      );
      for (final term in normalized.where(
        (t) => t.offer.type == DiplomacyExchangeType.lands,
      )) {
        _performTerritorialOffer(
          term.fromSender ? proposal.from : proposal.to,
          term.fromSender ? proposal.to : proposal.from,
          term.offer,
        );
      }
      if (hasTerritorialTransfer) {
        // Both halves are committed before province lineage is rebuilt. This
        // keeps full-land swaps and traded fleets atomic.
        rebuildProvinces(preserveNewCapitalUnits: true);
      }
      _recordAcceptedExchange(proposal);
      _logDiplomacy(
        '${state.playerName(proposal.from)} және ${state.playerName(proposal.to)} келісім жасады',
      );
      _updateWinner();
      return true;
    }
    if (proposal.type == DiplomacyProposalType.militaryAlliance) {
      if (!canFormMilitaryAlliance(proposal.from, proposal.to)) return false;
      state.diplomacyProposals.remove(proposal);
      return formMilitaryAlliance(proposal.from, proposal.to);
    }
    final expected = proposal.type == DiplomacyProposalType.peace
        ? DiplomacyStatus.war
        : DiplomacyStatus.peace;
    if (!_validDiplomacyPair(proposal.from, proposal.to) ||
        diplomacyBetween(proposal.from, proposal.to) != expected) {
      return false;
    }
    if (proposal.type == DiplomacyProposalType.friendship &&
        !canBecomeFriends(proposal.from, proposal.to)) {
      return false;
    }
    if (proposal.type == DiplomacyProposalType.peace &&
        diplomacyCooldown(proposal.from, proposal.to) > 0) {
      return false;
    }
    state.diplomacyProposals.remove(proposal);
    return improveDiplomacy(proposal.from, proposal.to);
  }

  Iterable<DiplomacyProposal> proposalsFor(int player) =>
      state.diplomacyProposals.where((proposal) => proposal.to == player);

  Iterable<DiplomacyMessage> incomingDiplomacyMessages(int player) =>
      state.diplomacyMessages.where((message) => message.to == player);

  Iterable<PeaceConference> peaceConferencesFor(int player) => state
      .peaceConferences
      .where((conference) => conference.participants.contains(player));

  PeaceConference? peaceConferenceById(int id) => state.peaceConferences
      .where((conference) => conference.id == id)
      .firstOrNull;

  int peaceConferenceTileValue(int id, int tile) =>
      peaceConferenceById(id)?.tileValues[tile] ?? 0;

  int peaceConferenceQuota(int id, int player) =>
      peaceConferenceById(id)?.contributionPoints[player] ?? 0;

  int peaceConferenceAssignedValue(int id, int player) {
    final conference = peaceConferenceById(id);
    if (conference == null) return 0;
    return (conference.allocations[player] ?? const <int>[]).fold<int>(
      0,
      (sum, tile) => sum + (conference.tileValues[tile] ?? 0),
    );
  }

  bool submitPeaceConferenceProposal(
    int id,
    int proposer,
    Map<int, List<int>> allocations,
  ) {
    final conference = peaceConferenceById(id);
    if (conference == null ||
        !conference.participants.contains(proposer) ||
        !_isAlive(proposer)) {
      return false;
    }
    final claimTiles = conference.claimTiles.toSet();
    final assigned = <int>{};
    final normalized = <int, List<int>>{};
    for (final entry in allocations.entries) {
      final recipient = entry.key;
      if (!conference.participants.contains(recipient) ||
          !_isAlive(recipient)) {
        return false;
      }
      final tiles = entry.value.toSet().toList()..sort();
      if (tiles.length != entry.value.length ||
          tiles.any(
            (tile) =>
                !claimTiles.contains(tile) ||
                !assigned.add(tile) ||
                state.hexes[tile].coalitionClaim?.conferenceId != id,
          )) {
        return false;
      }
      final value = tiles.fold<int>(
        0,
        (sum, tile) => sum + (conference.tileValues[tile] ?? 0),
      );
      if (value > (conference.contributionPoints[recipient] ?? 0)) {
        return false;
      }
      if (tiles.isNotEmpty) normalized[recipient] = tiles;
    }
    conference.allocations
      ..clear()
      ..addAll(normalized);
    conference
      ..proposer = proposer
      ..revision = conference.revision + 1;
    conference.acceptedBy
      ..clear()
      ..add(proposer);
    _logDiplomacy(
      '${state.playerName(proposer)} №$id бейбіт конференциясына жер бөлу ұсынысын жіберді',
    );
    _tryFinalizePeaceConference(conference);
    return true;
  }

  bool acceptPeaceConference(int id, int player) {
    final conference = peaceConferenceById(id);
    if (conference == null ||
        conference.proposer < 0 ||
        !conference.participants.contains(player) ||
        !_isAlive(player)) {
      return false;
    }
    if (!conference.acceptedBy.contains(player)) {
      conference.acceptedBy.add(player);
      conference.acceptedBy.sort();
    }
    _tryFinalizePeaceConference(conference);
    return true;
  }

  bool hasDiplomacyInbox(int player) =>
      proposalsFor(player).isNotEmpty ||
      incomingDiplomacyMessages(player).isNotEmpty ||
      peaceConferencesFor(player).isNotEmpty;

  bool sendDiplomacyMessage({
    required int from,
    required int to,
    required String text,
  }) {
    if (!_validDiplomacyPair(from, to)) return false;
    final message = text.trim();
    if (message.isEmpty || message.length > 400) return false;
    state.diplomacyMessages.add(
      DiplomacyMessage(
        from: from,
        to: to,
        text: message,
        createdRound: state.round,
      ),
    );
    if (state.diplomacyMessages.length > 80) {
      state.diplomacyMessages.removeAt(0);
    }
    _logDiplomacy(
      '${state.playerName(from)} ${state.playerName(to)} ойыншысына хат жіберді',
    );
    return true;
  }

  Iterable<DiplomacyMessage> messagesBetween(int first, int second) =>
      state.diplomacyMessages.where(
        (message) =>
            (message.from == first && message.to == second) ||
            (message.from == second && message.to == first),
      );

  bool dismissDiplomacyMessage(DiplomacyMessage message) =>
      state.diplomacyMessages.remove(message);

  bool clearDiplomacyInbox(int player) {
    var changed = false;
    final proposals = proposalsFor(player).toList();
    for (final proposal in proposals) {
      changed = resolveDiplomacyProposal(proposal, accept: false) || changed;
    }
    final before = state.diplomacyMessages.length;
    state.diplomacyMessages.removeWhere((message) => message.to == player);
    return changed || state.diplomacyMessages.length != before;
  }

  bool _validDiplomacyPair(int first, int second) =>
      state.config.diplomacy &&
      first != second &&
      first >= 0 &&
      second >= 0 &&
      first < state.config.playerCount &&
      second < state.config.playerCount &&
      _isAlive(first) &&
      _isAlive(second);

  bool _validDiplomacyIndexes(int first, int second) =>
      first >= 0 &&
      second >= 0 &&
      first < state.config.playerCount &&
      second < state.config.playerCount;

  WarCampaign? campaignBetween(int first, int second) => state.campaigns
      .where((campaign) => campaign.opposes(first, second))
      .firstOrNull;

  bool declareWar(int attacker, int defender) {
    if (!canDeclareWar(attacker, defender)) return false;
    final sideA = militaryAllianceComponent(attacker).toList()..sort();
    final sideB = militaryAllianceComponent(defender).toList()..sort();
    if (sideA.toSet().intersection(sideB.toSet()).isNotEmpty) return false;
    // A peace-conference ban belongs to every participant pair. Checking the
    // complete blocs here prevents an unblocked ally from dragging a banned
    // country back into the same war indirectly.
    for (final first in sideA) {
      for (final second in sideB) {
        if (diplomacyCooldown(first, second) > 0) return false;
      }
    }
    for (final first in sideA) {
      for (final second in sideB) {
        setDiplomacyStatus(first, second, DiplomacyStatus.war);
        state.diplomacyWarCooldowns[first][second] = 10;
        state.diplomacyWarCooldowns[second][first] = 10;
      }
    }
    state.campaigns.add(
      WarCampaign(
        id: state.nextWarCampaignId++,
        attackerLeader: attacker,
        defenderLeader: defender,
        sideA: sideA,
        sideB: sideB,
        startedRound: state.round,
      ),
    );
    // A declaration of war is also a real inbox item, matching Classic's
    // letter flow. Every directly attacked bloc member is informed; the
    // defender always receives the first message.
    for (final target in sideB) {
      state.diplomacyMessages.add(
        DiplomacyMessage(
          from: attacker,
          to: target,
          text: '${state.playerName(attacker)} сізге соғыс жариялады',
          createdRound: state.round,
        ),
      );
    }
    while (state.diplomacyMessages.length > 80) {
      state.diplomacyMessages.removeAt(0);
    }
    // Ordinary friendship carries a diplomatic consequence, not automatic
    // military participation. Only the military blocs join this campaign;
    // a friendship must not bypass a third country's truce or its own bloc.
    for (var friend = 0; friend < state.config.playerCount; friend++) {
      if (friend == attacker ||
          friend == defender ||
          sideA.contains(friend) ||
          sideB.contains(friend) ||
          !_isAlive(friend) ||
          diplomacyBetween(defender, friend) != DiplomacyStatus.alliance) {
        continue;
      }
      _punishAggressorForDefenderFriend(attacker, friend);
    }
    _logDiplomacy(
      '${state.playerName(attacker)} альянсы '
      '${state.playerName(defender)} альянсына соғыс жариялады',
    );
    return true;
  }

  void _punishAggressorForDefenderFriend(int aggressor, int defenderFriend) {
    final status = diplomacyBetween(aggressor, defenderFriend);
    if (status == DiplomacyStatus.alliance) {
      final turns = friendshipBreakCompensationTurns(aggressor, defenderFriend);
      final fine = friendshipBreakFinePerTurn(aggressor);
      _addFriendshipBreakCompensation(
        payer: aggressor,
        receiver: defenderFriend,
        amount: fine,
        turns: turns,
      );
      setDiplomacyStatus(aggressor, defenderFriend, DiplomacyStatus.peace);
      _logDiplomacy(
        '${state.playerName(aggressor)} шабуылы '
        '${state.playerName(defenderFriend)} ойыншысымен достықты бұзды; '
        '$fine ақша × $turns ход өтем белгіленді',
      );
    } else if (status == DiplomacyStatus.peace) {
      changeOpinion(defenderFriend, aggressor, -20, 'Досына соғыс жариялады');
    }
  }

  bool makePeace(int first, int second) {
    if (!_validDiplomacyPair(first, second) || !areEnemies(first, second)) {
      return false;
    }
    final campaigns = state.campaigns
        .where((campaign) => campaign.opposes(first, second))
        .toList();
    if (campaigns.isEmpty) {
      setDiplomacyStatus(first, second, DiplomacyStatus.peace);
      state.diplomacyWarCooldowns[first][second] = 9;
      state.diplomacyWarCooldowns[second][first] = 9;
    } else {
      for (final campaign in campaigns) {
        _openPeaceConferences(campaign);
        _setCampaignPeace(campaign);
        state.campaigns.remove(campaign);
      }
    }
    _logDiplomacy(
      '${state.playerName(first)} және ${state.playerName(second)} бітім жасады',
    );
    _updateWinner();
    return true;
  }

  void _setCampaignPeace(WarCampaign campaign) {
    for (final a in campaign.sideA) {
      for (final b in campaign.sideB) {
        if (!_validDiplomacyIndexes(a, b)) continue;
        setDiplomacyStatus(a, b, DiplomacyStatus.peace);
        state.diplomacyWarCooldowns[a][b] = 9;
        state.diplomacyWarCooldowns[b][a] = 9;
      }
    }
  }

  void _openPeaceConferences(WarCampaign campaign) {
    final groups =
        <({int originalOwner, bool capturedBySideA}), List<HexTile>>{};
    for (final tile in state.hexes) {
      final claim = tile.coalitionClaim;
      if (claim == null ||
          claim.campaignId != campaign.id ||
          claim.conferenceId >= 0) {
        continue;
      }
      final capturedBySideA = campaign.sideA.contains(claim.captor);
      final capturedBySideB = campaign.sideB.contains(claim.captor);
      if (!capturedBySideA && !capturedBySideB) continue;
      groups
          .putIfAbsent((
            originalOwner: claim.originalOwner,
            capturedBySideA: capturedBySideA,
          ), () => <HexTile>[])
          .add(tile);
    }
    final orderedGroups = groups.entries.toList()
      ..sort((a, b) {
        final ownerOrder = a.key.originalOwner.compareTo(b.key.originalOwner);
        if (ownerOrder != 0) return ownerOrder;
        return (a.key.capturedBySideA ? 0 : 1).compareTo(
          b.key.capturedBySideA ? 0 : 1,
        );
      });
    for (final group in orderedGroups) {
      final side = group.key.capturedBySideA ? campaign.sideA : campaign.sideB;
      final sideSet = side.toSet();
      final tiles = group.value..sort((a, b) => a.index.compareTo(b.index));
      final participants = <int>{};
      final tileValues = <int, int>{};
      final rawContributionPoints = <int, double>{};
      for (final tile in tiles) {
        final claim = tile.coalitionClaim!;
        final contributors =
            claim.contributors.where(sideSet.contains).toSet().toList()..sort();
        if (!contributors.contains(claim.captor) &&
            sideSet.contains(claim.captor)) {
          contributors.add(claim.captor);
          contributors.sort();
        }
        if (contributors.isEmpty) continue;
        participants.addAll(contributors);
        final value = math.max(1, claim.settlementValue);
        tileValues[tile.index] = value;
        final share = value / contributors.length;
        for (final player in contributors) {
          rawContributionPoints[player] =
              (rawContributionPoints[player] ?? 0) + share;
        }
      }
      if (participants.isEmpty || tileValues.isEmpty) continue;
      final id = state.nextPeaceConferenceId++;
      final participantList = participants.toList()..sort();
      final claimTiles = tileValues.keys.toList()..sort();
      // Apply largest-remainder rounding after the whole pool is known. Doing
      // it claim-by-claim would give the lowest player every odd-dollar
      // remainder and accumulate a systematic bias across many claims.
      final contributionPoints = <int, int>{
        for (final player in participantList)
          player: (rawContributionPoints[player] ?? 0).floor(),
      };
      var remainder =
          tileValues.values.fold<int>(0, (sum, value) => sum + value) -
          contributionPoints.values.fold<int>(0, (sum, value) => sum + value);
      final remainderOrder = participantList.toList()
        ..sort((a, b) {
          final fractionA =
              (rawContributionPoints[a] ?? 0) -
              (rawContributionPoints[a] ?? 0).floor();
          final fractionB =
              (rawContributionPoints[b] ?? 0) -
              (rawContributionPoints[b] ?? 0).floor();
          final fractionOrder = fractionB.compareTo(fractionA);
          return fractionOrder != 0 ? fractionOrder : a.compareTo(b);
        });
      for (var i = 0; remainder > 0; i++, remainder--) {
        final player = remainderOrder[i % remainderOrder.length];
        contributionPoints[player] = contributionPoints[player]! + 1;
      }
      final conference = PeaceConference(
        id: id,
        sourceCampaignId: campaign.id,
        originalOwner: group.key.originalOwner,
        claimTiles: claimTiles,
        participants: participantList,
        openedRound: state.round,
        deadlineRound: state.round + 5,
        tileValues: tileValues,
        contributionPoints: contributionPoints,
      );
      state.peaceConferences.add(conference);
      for (final index in claimTiles) {
        final claim = state.hexes[index].coalitionClaim;
        if (claim != null) {
          state.hexes[index].coalitionClaim = claim.copyWith(conferenceId: id);
        }
      }
      _logDiplomacy(
        '№$id бейбіт конференция ашылды: '
        '${state.playerName(group.key.originalOwner)} ойыншысының ${claimTiles.length} жері',
      );
    }
  }

  void _tryFinalizePeaceConference(PeaceConference conference) {
    if (!state.peaceConferences.contains(conference) ||
        conference.proposer < 0) {
      return;
    }
    final living = conference.participants.where(_isAlive).toList();
    if (living.isEmpty ||
        living.any((player) => !conference.acceptedBy.contains(player))) {
      return;
    }
    _resolvePeaceConference(conference, useAllocation: true);
  }

  void _resolvePeaceConference(
    PeaceConference conference, {
    required bool useAllocation,
  }) {
    if (!state.peaceConferences.contains(conference)) return;
    final recipients = <int, int>{};
    if (useAllocation) {
      for (final entry in conference.allocations.entries) {
        for (final tile in entry.value) {
          recipients[tile] = entry.key;
        }
      }
    }
    final displaced = <({int source, GameUnit unit})>[];
    var changed = false;
    for (final index in conference.claimTiles) {
      if (index < 0 || index >= state.hexes.length) continue;
      final tile = state.hexes[index];
      final claim = tile.coalitionClaim;
      if (claim == null || claim.conferenceId != conference.id) continue;
      final assigned = recipients[index];
      final recipient = assigned != null && _isAlive(assigned)
          ? assigned
          : claim.originalOwner;
      final unit = tile.unit;
      if (unit != null && unit.owner < 0) unit.owner = claim.captor;
      tile
        ..owner = recipient
        ..coalitionClaim = null;
      if (unit != null &&
          recipient != unit.owner &&
          !hasMilitaryAccess(unit.owner, recipient)) {
        tile.unit = null;
        displaced.add((source: index, unit: unit));
      }
      changed = true;
    }
    for (final item in displaced) {
      _repatriatePeaceConferenceUnit(item.source, item.unit);
    }
    for (final participant in conference.participants) {
      if (!_validDiplomacyIndexes(participant, conference.originalOwner) ||
          participant == conference.originalOwner) {
        continue;
      }
      state.diplomacyWarCooldowns[participant][conference.originalOwner] = math
          .max(
            10,
            state.diplomacyWarCooldowns[participant][conference.originalOwner],
          );
      state.diplomacyWarCooldowns[conference.originalOwner][participant] =
          state.diplomacyWarCooldowns[participant][conference.originalOwner];
    }
    state.peaceConferences.remove(conference);
    if (changed) rebuildProvinces(preserveNewCapitalUnits: true);
    _logDiplomacy(
      useAllocation
          ? '№${conference.id} бейбіт конференциясының жер бөлуі қабылданды'
          : '№${conference.id} бейбіт конференциясы келісімсіз аяқталды; жер қайтарылды',
    );
    _updateWinner();
  }

  void _repatriatePeaceConferenceUnit(int source, GameUnit unit) {
    final owner = unit.owner;
    if (owner < 0 || owner >= state.config.playerCount || !_isAlive(owner)) {
      return;
    }
    final distances = <int, int>{source: 0};
    final queue = <int>[source];
    var bestDistance = 1 << 30;
    final candidates = <int>[];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final distance = distances[index]!;
      if (distance > bestDistance) break;
      final tile = state.hexes[index];
      final friendly =
          tile.coalitionClaim == null &&
          tile.active &&
          tile.owner >= 0 &&
          (tile.owner == owner || hasMilitaryAccess(owner, tile.owner));
      final open =
          tile.unit == null &&
          tile.object != TileObject.town &&
          tile.object != TileObject.farm &&
          tile.object != TileObject.tower &&
          tile.object != TileObject.strongTower &&
          tile.object != TileObject.port1 &&
          tile.object != TileObject.port2 &&
          _artilleryLevel(tile.object) == 0;
      if (friendly && open) {
        bestDistance = distance;
        candidates.add(index);
        continue;
      }
      if (distance >= bestDistance) continue;
      final neighbors = tile.neighbors.toList()..sort();
      for (final neighbor in neighbors) {
        if (neighbor < 0 ||
            neighbor >= state.hexes.length ||
            distances.containsKey(neighbor) ||
            !state.hexes[neighbor].active) {
          continue;
        }
        distances[neighbor] = distance + 1;
        queue.add(neighbor);
      }
    }
    if (candidates.isEmpty) return;
    candidates.sort((a, b) {
      final ownA = state.hexes[a].owner == owner ? 0 : 1;
      final ownB = state.hexes[b].owner == owner ? 0 : 1;
      final ownOrder = ownA.compareTo(ownB);
      return ownOrder != 0 ? ownOrder : a.compareTo(b);
    });
    final destination = state.hexes[candidates.first];
    if (destination.owner == owner) {
      destination
        ..object = TileObject.none
        ..treeBorn = -1;
      unit.transitAllies.clear();
    }
    destination.unit = unit..ready = false;
    _fundUnitOnOwnLand(destination);
  }

  void _settleCampaignsWithDefeatedSide() {
    if (_settlingCampaigns) return;
    final ended = state.campaigns.where((campaign) {
      final sideAAlive = campaign.sideA.any(_isAlive);
      final sideBAlive = campaign.sideB.any(_isAlive);
      return !sideAAlive || !sideBAlive;
    }).toList();
    if (ended.isEmpty) return;
    _settlingCampaigns = true;
    try {
      for (final campaign in ended) {
        _openPeaceConferences(campaign);
        _setCampaignPeace(campaign);
        state.campaigns.remove(campaign);
      }
    } finally {
      _settlingCampaigns = false;
    }
  }

  void _clearHostileObligations(int first, int second) {
    // Principal remains owed regardless of who declared war, including an
    // ally's declaration. Collection pauses until peace; voluntary subsidies
    // end, while mandatory compensation retains its existing contract.
    state.diplomacySubsidies.removeWhere(
      (subsidy) =>
          !subsidy.mandatory &&
          ((subsidy.payer == first && subsidy.receiver == second) ||
              (subsidy.payer == second && subsidy.receiver == first)),
    );
    _removeDiplomacyProposalsBetween(first, second);
  }

  bool _offerIsValid(int giver, int receiver, DiplomacyOffer offer) {
    switch (offer.type) {
      case DiplomacyExchangeType.nothing:
        return true;
      case DiplomacyExchangeType.money:
        return offer.amount > 0;
      case DiplomacyExchangeType.lands:
        final allLand = offer.tiles.length == playerLandCount(giver);
        return (offer.tiles.isNotEmpty || offer.navalRefs.isNotEmpty) &&
            offer.tiles.toSet().length == offer.tiles.length &&
            _navalRefsAreUnique(offer.navalRefs) &&
            offer.navalRefs.every(
              (reference) => _navalAssetBelongsTo(reference, giver),
            ) &&
            offer.tiles.every(
              (index) =>
                  index >= 0 &&
                  index < state.hexes.length &&
                  state.hexes[index].owner == giver &&
                  state.hexes[index].coalitionClaim == null &&
                  provinceAt(index) != null &&
                  _landUnitMayTransfer(index, giver, receiver),
            ) &&
            (offer.tiles.isEmpty || _landSelectionConnected(offer.tiles)) &&
            (allLand ||
                _landTransferPreservesSellerProvinces(giver, offer.tiles));
      case DiplomacyExchangeType.friendship:
        return diplomacyBetween(giver, receiver) != DiplomacyStatus.war &&
            diplomacyBetween(giver, receiver) != DiplomacyStatus.coalition &&
            canBecomeFriends(giver, receiver);
      case DiplomacyExchangeType.militaryAlliance:
        return canFormMilitaryAlliance(giver, receiver);
      case DiplomacyExchangeType.warDeclaration:
        final target = offer.targetPlayer;
        return canDeclareWar(giver, target);
      case DiplomacyExchangeType.ceasefire:
        return diplomacyBetween(giver, receiver) == DiplomacyStatus.war &&
            diplomacyCooldown(giver, receiver) == 0;
      case DiplomacyExchangeType.removeBlackMark:
        return hasBlackMark(giver, receiver);
      case DiplomacyExchangeType.subsidies:
        return offer.amount > 0 && offer.duration > 0;
    }
  }

  void _performOffer(int giver, int receiver, DiplomacyOffer offer) {
    switch (offer.type) {
      case DiplomacyExchangeType.nothing:
        return;
      case DiplomacyExchangeType.money:
        final paid = _transferPlayerMoney(giver, receiver, offer.amount);
        if (paid >= 10 &&
            state.diplomacySocial.lastAidReward[receiver][giver] !=
                state.round) {
          state.diplomacySocial.lastAidReward[receiver][giver] = state.round;
          changeOpinion(
            receiver,
            giver,
            math.min(10, paid ~/ 10),
            'Ақшалай көмек',
          );
        }
        if (paid < offer.amount) {
          state.diplomacyDebts[giver][receiver] += offer.amount - paid;
        }
      case DiplomacyExchangeType.lands:
        return;
      case DiplomacyExchangeType.friendship:
        setDiplomacyStatus(giver, receiver, DiplomacyStatus.alliance);
        state.diplomacyAllianceTurns[giver][receiver] = offer.duration > 0
            ? offer.duration
            : 12;
        state.diplomacyAllianceTurns[receiver][giver] =
            state.diplomacyAllianceTurns[giver][receiver];
      case DiplomacyExchangeType.militaryAlliance:
        formMilitaryAlliance(
          giver,
          receiver,
          duration: offer.duration > 0 ? offer.duration : 12,
        );
      case DiplomacyExchangeType.warDeclaration:
        if (diplomacyBetween(giver, offer.targetPlayer) ==
            DiplomacyStatus.peace) {
          worsenDiplomacy(giver, offer.targetPlayer);
        }
      case DiplomacyExchangeType.ceasefire:
        makePeace(giver, receiver);
      case DiplomacyExchangeType.removeBlackMark:
        removeBlackMark(giver, receiver);
      case DiplomacyExchangeType.subsidies:
        state.diplomacySubsidies.removeWhere(
          (subsidy) =>
              !subsidy.mandatory &&
              subsidy.payer == giver &&
              subsidy.receiver == receiver,
        );
        state.diplomacySubsidies.add(
          DiplomacySubsidy(
            payer: giver,
            receiver: receiver,
            amount: offer.amount,
            turnsLeft: offer.duration,
          ),
        );
    }
  }

  int diplomacyOfferValue(int giver, DiplomacyOffer offer) {
    switch (offer.type) {
      case DiplomacyExchangeType.nothing:
        return 0;
      case DiplomacyExchangeType.money:
        return offer.amount;
      case DiplomacyExchangeType.lands:
        return offer.tiles.fold(
              0,
              (sum, index) => sum + diplomacyLandPrice(index),
            ) +
            offer.navalRefs.fold(
              0,
              (sum, reference) => sum + diplomacyNavalPrice(reference),
            );
      case DiplomacyExchangeType.friendship:
        return math.max(
          5,
          (playerEconomicBreakdown(giver).total * 2.5).round(),
        );
      case DiplomacyExchangeType.militaryAlliance:
        return math.max(10, (playerEconomicBreakdown(giver).total * 4).round());
      case DiplomacyExchangeType.warDeclaration:
        return 180;
      case DiplomacyExchangeType.ceasefire:
        return 120;
      case DiplomacyExchangeType.removeBlackMark:
        return 200;
      case DiplomacyExchangeType.subsidies:
        return math.min(offer.amount, math.max(0, playerIncome(giver))) *
            offer.duration;
    }
  }

  int diplomacyLandPrice(int index) {
    if (index < 0 || index >= state.hexes.length) return 0;
    final tile = state.hexes[index];
    if (tile.unit != null) return 25 + 15 * tile.unit!.strength;
    return switch (tile.object) {
      TileObject.pine || TileObject.palm => 15,
      TileObject.town => 10 * (provinceAt(index)?.tiles.length ?? 1),
      TileObject.tower => 50,
      TileObject.farm => 100,
      TileObject.strongTower => 75,
      TileObject.port1 => mod.rules.port1Price,
      TileObject.port2 => mod.rules.port1Price + mod.rules.port2Price,
      TileObject.artillery1 => _cumulativeArtilleryCost(1),
      TileObject.artillery2 => _cumulativeArtilleryCost(2),
      TileObject.artillery3 => _cumulativeArtilleryCost(3),
      _ => 25,
    };
  }

  int diplomacyNavalPrice(NavalAssetRef reference) {
    switch (reference.kind) {
      case NavalAssetKind.boat:
        final boat = _boatById(reference.id)?.boat;
        if (boat == null) return 0;
        final cargoValue = boat.cargo.fold<int>(
          0,
          (sum, unit) => sum + 25 + 15 * unit.strength,
        );
        return (boat.level == 1 ? mod.rules.boat1Price : mod.rules.boat2Price) +
            cargoValue;
      case NavalAssetKind.seaFort:
        return _seaFortById(reference.id) == null ? 0 : mod.rules.seaFortPrice;
    }
  }

  bool _navalRefsAreUnique(List<NavalAssetRef> references) =>
      references
          .map((reference) => '${reference.kind.name}:${reference.id}')
          .toSet()
          .length ==
      references.length;

  bool _navalAssetBelongsTo(NavalAssetRef reference, int owner) =>
      switch (reference.kind) {
        NavalAssetKind.boat => _boatById(reference.id)?.boat.owner == owner,
        NavalAssetKind.seaFort =>
          _seaFortById(reference.id)?.fort.owner == owner,
      };

  bool _landUnitMayTransfer(int index, int giver, int receiver) {
    final unit = state.hexes[index].unit;
    if (unit == null) return true;
    final owner = unitOwnerAt(index);
    return owner == giver || hasMilitaryAccess(owner, receiver);
  }

  ({WaterCell cell, GameBoat boat})? _boatById(int id) {
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat != null && boat.id == id) return (cell: cell, boat: boat);
    }
    return null;
  }

  ({WaterCell cell, SeaFort fort})? _seaFortById(int id) {
    for (final cell in state.waterCells) {
      final fort = cell.seaFort;
      if (fort != null && fort.id == id) return (cell: cell, fort: fort);
    }
    return null;
  }

  void _performTerritorialOffer(int giver, int receiver, DiplomacyOffer offer) {
    for (final index in offer.tiles) {
      final tile = state.hexes[index];
      if (tile.owner != giver || tile.coalitionClaim != null) continue;
      final unitOwner = unitOwnerAt(index);
      tile.owner = receiver;
      if (tile.unit != null && unitOwner == giver) {
        tile.unit!
          ..owner = receiver
          ..homeProvinceId = -1
          ..ready = false;
        tile.unit!.transitAllies.clear();
      }
    }
    for (final reference in offer.navalRefs) {
      switch (reference.kind) {
        case NavalAssetKind.boat:
          final asset = _boatById(reference.id);
          if (asset == null || asset.boat.owner != giver) continue;
          asset.boat
            ..owner = receiver
            ..homeProvinceId = -1
            ..ready = false
            ..supportedTiles.clear();
          for (final unit in asset.boat.cargo) {
            unit
              ..owner = receiver
              ..homeProvinceId = -1
              ..ready = false
              ..transitAllies.clear();
          }
        case NavalAssetKind.seaFort:
          final asset = _seaFortById(reference.id);
          if (asset == null || asset.fort.owner != giver) continue;
          asset.fort
            ..owner = receiver
            ..homeProvinceId = -1;
      }
    }
  }

  int _cumulativeArtilleryCost(int level) {
    var result = 0;
    final last = math.min(level, mod.rules.artilleryCosts.length - 1);
    for (var current = 1; current <= last; current++) {
      result += mod.rules.artilleryCosts[current];
    }
    return result;
  }

  bool _landSelectionConnected(List<int> tiles) {
    if (tiles.isEmpty) return false;
    final selected = tiles.toSet();
    final reached = <int>{tiles.first};
    final queue = <int>[tiles.first];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      for (final neighbor in state.hexes[queue[cursor]].neighbors) {
        if (selected.contains(neighbor) && reached.add(neighbor)) {
          queue.add(neighbor);
        }
      }
    }
    return reached.length == selected.length;
  }

  bool _landTransferPreservesSellerProvinces(
    int seller,
    List<int> transferredTiles,
  ) {
    final transferred = transferredTiles.toSet();
    for (final province in provincesOf(seller)) {
      if (!province.tiles.any(transferred.contains)) continue;
      final remainder = province.tiles
          .where((index) => !transferred.contains(index))
          .toSet();
      // A one-hex remainder is no longer a province in this ruleset. Classic
      // treats that as an invalid sale alongside a genuinely split remainder.
      if (remainder.length < 2) return false;
      final reached = <int>{remainder.first};
      final queue = <int>[remainder.first];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        for (final neighbor in state.hexes[queue[cursor]].neighbors) {
          if (remainder.contains(neighbor) && reached.add(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      if (reached.length != remainder.length) return false;
    }
    return true;
  }

  int _transferPlayerMoney(int payer, int receiver, int amount) {
    var left = math.max(0, amount);
    var paid = 0;
    final sources = provincesOf(payer).toList()
      ..sort((a, b) => b.money.compareTo(a.money));
    for (final province in sources) {
      if (left == 0) break;
      final take = math.min(left, math.max(0, province.money));
      province.money -= take;
      paid += take;
      left -= take;
    }
    final targets = provincesOf(receiver).toList()
      ..sort((a, b) => b.tiles.length.compareTo(a.tiles.length));
    if (targets.isNotEmpty) targets.first.money += paid;
    return paid;
  }

  void _addFriendshipBreakCompensation({
    required int payer,
    required int receiver,
    required int amount,
    required int turns,
  }) {
    if (amount <= 0 || turns <= 0) return;
    state.diplomacySubsidies.add(
      DiplomacySubsidy(
        payer: payer,
        receiver: receiver,
        amount: amount,
        turnsLeft: turns,
        mandatory: true,
      ),
    );
  }

  void _removeDiplomacyProposalsBetween(int first, int second) {
    state.diplomacyProposals.removeWhere(
      (proposal) =>
          (proposal.from == first && proposal.to == second) ||
          (proposal.from == second && proposal.to == first),
    );
  }

  void _logDiplomacy(String message) {
    state.diplomacyLog.add(message);
    if (state.diplomacyLog.length > 30) state.diplomacyLog.removeAt(0);
  }

  EconomicBreakdown economicBreakdown(
    Province province, {
    bool includeDiplomacy = true,
  }) {
    var farms = 0;
    var trees = 0;
    var landUnits = 0;
    var cargoUnits = 0;
    var towers = 0;
    var artillery = 0;
    var ports = 0;
    var boats = 0;
    var seaForts = 0;
    var navalTransfer = 0;
    var navalSupport = 0;
    var diplomacy = 0;
    navalSupport += _navalSupportForProvince(province);
    for (final index in province.tiles) {
      final tile = state.hexes[index];
      if (tile.object == TileObject.farm && !state.config.slayRules) {
        farms += mod.rules.farmIncome;
      }
      if (tile.hasTree) trees--;
      if (tile.object == TileObject.tower && !state.config.slayRules) {
        towers -= mod.rules.towerUpkeep;
      }
      if (tile.object == TileObject.strongTower) {
        if (!state.config.slayRules) towers -= mod.rules.strongTowerUpkeep;
      }
      final artilleryLevel = _artilleryLevel(tile.object);
      if (artilleryLevel > 0) {
        artillery -= mod.rules.artilleryUpkeep[artilleryLevel];
      }
      if (tile.object == TileObject.port1) ports -= mod.rules.port1Upkeep;
      if (tile.object == TileObject.port2) ports -= mod.rules.port2Upkeep;
    }
    for (final tile in state.hexes) {
      final unit = tile.unit;
      if (unit == null ||
          unitOwnerAt(tile.index) != province.owner ||
          unitHomeProvinceAt(tile.index) != province.id) {
        continue;
      }
      landUnits -= _unitUpkeep(unit.strength);
    }
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null ||
          boat.owner != province.owner ||
          boat.homeProvinceId != province.id) {
        continue;
      }
      boats -= boat.level == 1 ? mod.rules.boat1Upkeep : mod.rules.boat2Upkeep;
      for (final unit in boat.cargo) {
        final landCost = _unitUpkeep(unit.strength);
        cargoUnits -= (landCost * 3) ~/ 2;
      }
      if (_primaryNavalProvinceForBoat(cell, boat) != null) {
        // The temporary city's +4/+10 is a transfer from the province that
        // launched the boat, not free money and not a second unit-upkeep bill.
        // Supply upkeep is charged once per active boat-to-bridgehead chain;
        // the bridgehead's matching positive transfer is not charged again.
        navalTransfer -=
            boatCapacity(boat.level) + math.max(0, mod.rules.navalSupplyUpkeep);
      }
    }
    for (final cell in state.waterCells) {
      final fort = cell.seaFort;
      if (fort != null &&
          fort.owner == province.owner &&
          fort.homeProvinceId == province.id) {
        seaForts -= mod.rules.seaFortUpkeep;
      }
    }
    final primaryProvince = provincesOf(province.owner).fold<Province?>(
      null,
      (best, item) =>
          best == null || item.tiles.length > best.tiles.length ? item : best,
    );
    if (includeDiplomacy && primaryProvince?.id == province.id) {
      for (final subsidy in state.diplomacySubsidies) {
        if (!subsidy.mandatory && areEnemies(subsidy.payer, subsidy.receiver)) {
          continue;
        }
        final effectiveAmount = math.min(
          subsidy.amount,
          math.max(0, playerIncome(subsidy.payer)),
        );
        if (subsidy.payer == province.owner) diplomacy -= effectiveAmount;
        if (subsidy.receiver == province.owner) diplomacy += effectiveAmount;
      }
      for (var other = 0; other < state.config.playerCount; other++) {
        if (other == province.owner || areEnemies(province.owner, other)) {
          continue;
        }
        diplomacy -= math.min(
          state.diplomacyDebts[province.owner][other],
          math.max(0, playerMoney(province.owner)),
        );
        diplomacy += math.min(
          state.diplomacyDebts[other][province.owner],
          math.max(0, playerMoney(other)),
        );
      }
      if (state.diplomacyTraitorTurns[province.owner] > 0) {
        diplomacy -= _traitorFine(province.owner);
      }
    }
    return EconomicBreakdown(
      land: province.tiles.length,
      farms: farms,
      // Friendship changes vision, combat and victory conditions; it does not
      // mint free money. Antiyoy handles money transfers as explicit deals.
      diplomacy: diplomacy,
      landUnits: landUnits,
      cargoUnits: cargoUnits,
      towers: towers,
      artillery: artillery,
      trees: trees,
      ports: ports,
      boats: boats,
      seaForts: seaForts,
      navalTransfer: navalTransfer,
      navalSupport: navalSupport,
    );
  }

  EconomicBreakdown playerEconomicBreakdown(int owner) => provincesOf(
    owner,
  ).fold(EconomicBreakdown.zero, (sum, p) => sum + economicBreakdown(p));

  int _traitorFine(int owner) {
    final baseProfit = provincesOf(owner).fold<int>(
      0,
      (sum, province) =>
          sum + economicBreakdown(province, includeDiplomacy: false).total,
    );
    return math.max(5, math.max(0, baseProfit) ~/ 3);
  }

  int income(Province province) {
    final report = economicBreakdown(province, includeDiplomacy: false);
    return report.land + report.farms + report.trees + report.navalSupport;
  }

  int _unitUpkeep(int strength) {
    if (state.config.slayRules) {
      return const [0, 2, 6, 18, 54][strength.clamp(0, 4)];
    }
    return mod.rules.unitUpkeep[strength];
  }

  /// Public read-only forecast used by AI so Generic and Slay calculations
  /// cannot drift from the economy that is actually charged at round end.
  int unitUpkeepAtStrength(int strength) => _unitUpkeep(strength);

  int get _treeCutReward =>
      state.config.slayRules ? 0 : mod.rules.treeCutReward;

  int playerIncome(int owner) => provincesOf(
    owner,
  ).fold<int>(0, (total, province) => total + income(province));

  int upkeep(Province province) {
    final report = economicBreakdown(province);
    return -(report.units +
        report.towers +
        report.artillery +
        report.ports +
        report.boats +
        report.seaForts +
        report.navalTransfer);
  }

  int balance(Province province) => economicBreakdown(province).total;

  int farmPrice(Province province) {
    final count = province.tiles
        .where((index) => state.hexes[index].object == TileObject.farm)
        .length;
    return mod.rules.farmBasePrice + count * mod.rules.farmPriceGrowth;
  }

  int defenseAt(int tileIndex) {
    final tile = state.hexes[tileIndex];
    final defender = tile.coalitionClaim?.captor ?? tile.owner;
    if (defender < 0) return 0;
    var defense = _tileDefense(tile);
    final province = provinceAt(tileIndex);
    if (province?.navalCapital == true && province!.capital == tileIndex) {
      defense = math.max(defense, 1);
    }
    for (final neighbor in tile.neighbors) {
      final support = state.hexes[neighbor];
      final supportOwner = support.unit == null
          ? support.coalitionClaim?.captor ?? support.owner
          : unitOwnerAt(neighbor);
      if (supportOwner == defender) {
        defense = math.max(defense, _tileDefense(support));
      }
    }
    return defense;
  }

  int _tileDefense(HexTile tile) {
    var defense = tile.unit?.strength ?? 0;
    defense = switch (tile.object) {
      TileObject.town => math.max(defense, 1),
      TileObject.port1 ||
      TileObject.port2 ||
      TileObject.artillery1 ||
      TileObject.artillery2 ||
      TileObject.artillery3 => math.max(defense, 1),
      TileObject.tower => math.max(defense, 2),
      TileObject.strongTower => math.max(defense, 3),
      _ => defense,
    };
    return defense;
  }

  // Official Slay is strict: an attacker must be stronger. Generic Antiyoy
  // keeps the level-four exception and may capture equal defense.
  bool _canAttack(int strength, int tileIndex) {
    return _canAttackFor(state.turn, strength, tileIndex);
  }

  bool _canAttackFor(int attacker, int strength, int tileIndex) {
    final tile = state.hexes[tileIndex];
    final defender = tile.coalitionClaim?.captor ?? tile.owner;
    // Claims have no province, but are not abandoned/neutral land. A pending
    // treaty freezes its exact pool until unanimous allocation or timeout.
    if (tile.coalitionClaim case final claim?) {
      if (claim.conferenceId >= 0 || !areEnemies(attacker, defender)) {
        return false;
      }
    }
    if (tile.coalitionClaim?.members.contains(attacker) == true) return false;
    if (defender >= 0 &&
        _isAlive(defender) &&
        (!areEnemies(attacker, defender) ||
            hasMilitaryAccess(attacker, defender))) {
      return false;
    }
    if (tile.unit != null &&
        _isAlive(unitOwnerAt(tileIndex)) &&
        !areEnemies(attacker, unitOwnerAt(tileIndex))) {
      return false;
    }
    return state.config.slayRules
        ? strength > defenseAt(tileIndex)
        : strength == 4 || strength > defenseAt(tileIndex);
  }

  void _applySlayCapitalCapture(HexTile target) {
    if (!state.config.slayRules || target.object != TileObject.town) return;
    provinceAt(target.index)?.money = 0;
  }

  Set<int> moveTargets(int from) {
    if (from < 0 || from >= state.hexes.length) return {};
    final source = state.hexes[from];
    if (source.unit == null ||
        unitOwnerAt(from) != state.turn ||
        !source.unit!.ready) {
      return {};
    }
    _normalizeUnitIdentity(from);
    final actor = source.unit!.owner;
    final result = <int>{};
    final distance = <int, int>{from: 0};
    final queue = <int>[from];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final nextDistance = distance[index]! + 1;
      if (nextDistance > mod.rules.unitMoveLimit) continue;
      for (final neighbor in state.hexes[index].neighbors) {
        final target = state.hexes[neighbor];
        if (!target.active) continue;
        if (_canTraverseLand(actor, target)) {
          if (distance.containsKey(neighbor)) continue;
          distance[neighbor] = nextDistance;
          queue.add(neighbor);
          if (_canOccupyFriendly(source.unit!, target, actor: actor)) {
            result.add(neighbor);
          }
        } else if (_canAttackFor(actor, source.unit!.strength, neighbor)) {
          result.add(neighbor);
        }
      }
    }
    return result;
  }

  bool _canTraverseLand(int actor, HexTile target) =>
      target.owner == actor ||
      (target.owner >= 0 && hasMilitaryAccess(actor, target.owner)) ||
      target.coalitionClaim?.members.contains(actor) == true;

  bool _canOccupyFriendly(GameUnit unit, HexTile target, {int? actor}) {
    final movingOwner = actor ?? (unit.owner >= 0 ? unit.owner : state.turn);
    if (!_canTraverseLand(movingOwner, target) ||
        target.object == TileObject.town ||
        target.object == TileObject.farm ||
        target.object == TileObject.tower ||
        target.object == TileObject.strongTower ||
        target.object == TileObject.port1 ||
        target.object == TileObject.port2 ||
        _artilleryLevel(target.object) > 0) {
      return false;
    }
    if (target.unit == null) return true;
    return unitOwnerAt(target.index) == movingOwner &&
        target.unit!.strength + unit.strength <= 4;
  }

  /// Reconstructs the same bounded shortest route as the move flood-fill.
  /// Credit crossings, not only stops; a return to sovereign land ends an
  /// expedition. No transit search is needed in ordinary non-alliance games.
  void _recordLandTransit(
    GameUnit unit,
    int actor,
    List<int> starts,
    int target, {
    int initialDistance = 0,
  }) {
    final allies = militaryAllianceComponent(actor)..remove(actor);
    if (allies.isEmpty) {
      unit.transitAllies.clear();
      return;
    }
    final parents = <int, int>{for (final start in starts) start: -1};
    final distances = <int, int>{
      for (final start in starts) start: initialDistance,
    };
    final queue = [...starts];
    for (
      var cursor = 0;
      cursor < queue.length && !parents.containsKey(target);
      cursor++
    ) {
      final index = queue[cursor];
      if (distances[index]! >= mod.rules.unitMoveLimit ||
          !_canTraverseLand(actor, state.hexes[index])) {
        continue;
      }
      for (final neighbor in state.hexes[index].neighbors) {
        if (!state.hexes[neighbor].active || parents.containsKey(neighbor)) {
          continue;
        }
        parents[neighbor] = index;
        distances[neighbor] = distances[index]! + 1;
        if (neighbor == target) break;
        if (_canTraverseLand(actor, state.hexes[neighbor])) queue.add(neighbor);
      }
    }
    if (!parents.containsKey(target)) return;
    final route = <int>[];
    for (var index = target; index >= 0; index = parents[index]!) {
      route.add(index);
    }
    for (final index in route.reversed) {
      final tile = state.hexes[index];
      if (tile.coalitionClaim != null) continue;
      if (tile.owner == actor) {
        unit.transitAllies.clear();
      } else if (allies.contains(tile.owner) &&
          !unit.transitAllies.contains(tile.owner)) {
        unit.transitAllies.add(tile.owner);
      }
    }
    unit.transitAllies.sort();
  }

  bool moveUnit(int from, int to, {Set<int>? knownTargets}) {
    if (from < 0 ||
        from >= state.hexes.length ||
        to < 0 ||
        to >= state.hexes.length) {
      return false;
    }
    final source = state.hexes[from];
    if (source.unit == null ||
        unitOwnerAt(from) != state.turn ||
        !source.unit!.ready) {
      return false;
    }
    if (!(knownTargets ?? moveTargets(from)).contains(to)) return false;
    final target = state.hexes[to];
    final moving = source.unit!;
    final actor = unitOwnerAt(from);
    // Cached move zones are hints. A treaty or another move may have changed
    // the destination since it was calculated.
    if (!target.active ||
        (_canTraverseLand(actor, target)
            ? !_canOccupyFriendly(moving, target, actor: actor)
            : !_canAttackFor(actor, moving.strength, to))) {
      return false;
    }
    _normalizeUnitIdentity(from);
    _recordLandTransit(moving, actor, [from], to);
    final sourceProvince = _provinceById(moving.homeProvinceId);
    final movedFromSupportedBridgehead = _isSupportedBridgehead(from, actor);
    source.unit = null;
    if (_canTraverseLand(actor, target)) {
      final sovereignOwner = target.owner;
      final ownSovereignLand =
          target.coalitionClaim == null && sovereignOwner == actor;
      if (target.unit == null) {
        if (ownSovereignLand && target.hasTree && sourceProvince != null) {
          sourceProvince.money += _treeCutReward;
        }
        if (ownSovereignLand) {
          target.object = TileObject.none;
          target.treeBorn = -1;
          moving.transitAllies.clear();
        } else if (target.coalitionClaim == null &&
            sovereignOwner >= 0 &&
            sovereignOwner != actor) {
          if (!moving.transitAllies.contains(sovereignOwner)) {
            moving.transitAllies.add(sovereignOwner);
            moving.transitAllies.sort();
          }
        }
        target.unit = moving..ready = false;
      } else {
        final bothUnitsWereReady = moving.ready && target.unit!.ready;
        target.unit!.strength += moving.strength;
        target.unit!.ready = bothUnitsWereReady;
        target.unit!.transitAllies
          ..addAll(moving.transitAllies)
          ..retainWhere((player) => player != actor);
        final merged = target.unit!.transitAllies.toSet().toList()..sort();
        target.unit!.transitAllies
          ..clear()
          ..addAll(ownSovereignLand ? const <int>[] : merged);
      }
      _fundUnitOnOwnLand(target);
    } else {
      _applySlayCapitalCapture(target);
      _captureLand(target, moving, actor);
      rebuildProvinces();
      _updateWinner();
    }
    if (movedFromSupportedBridgehead) {
      rebuildProvinces();
    }
    return true;
  }

  void _captureLand(HexTile target, GameUnit unit, int actor) {
    final previousClaim = target.coalitionClaim;
    final originalOwner = previousClaim?.originalOwner ?? target.owner;
    final settlementValue =
        previousClaim?.settlementValue ??
        math.max(1, diplomacyLandPrice(target.index));
    final campaign = campaignBetween(actor, originalOwner);
    final actorSide = campaign == null
        ? const <int>[]
        : (campaign.sideA.contains(actor) ? campaign.sideA : campaign.sideB);
    final contributors = <int>{actor};
    if (campaign != null) {
      contributors.addAll(
        unit.transitAllies.where(
          (ally) => ally != actor && actorSide.contains(ally),
        ),
      );
    }
    final contributorList = contributors.toList()..sort();
    final joint = campaign != null && contributorList.length > 1;
    unit.ready = false;
    target
      ..owner = actor
      ..object = TileObject.none
      ..treeBorn = -1
      ..artilleryAmmo = 0
      ..artilleryCooldown = 0
      ..unit = unit;
    unit.owner = actor;
    if (previousClaim != null && actor == previousClaim.originalOwner) {
      target.coalitionClaim = null;
      unit.transitAllies.clear();
    } else if (joint) {
      final members = actorSide.toSet().toList()..sort();
      target.coalitionClaim = CoalitionClaim(
        campaignId: campaign.id,
        originalOwner: originalOwner,
        members: members,
        captor: actor,
        contributors: contributorList,
        settlementValue: settlementValue,
      );
    } else {
      target.coalitionClaim = null;
      unit.transitAllies.clear();
    }
  }

  /// Classic hold-to-march behavior. Every ready unit in the province moves
  /// once to the free friendly hex in its normal move zone that is closest to
  /// [targetIndex]. Units never auto-attack or merge during a mass march.
  int massMarch(int provinceId, int targetIndex) {
    final province = _provinceById(provinceId);
    if (province == null ||
        province.owner != state.turn ||
        !province.tiles.contains(targetIndex)) {
      return 0;
    }
    final provinceTiles = province.tiles.toSet();
    final distanceToTarget = <int, int>{targetIndex: 0};
    final queue = <int>[targetIndex];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      for (final neighbor in state.hexes[index].neighbors) {
        if (!provinceTiles.contains(neighbor) ||
            distanceToTarget.containsKey(neighbor)) {
          continue;
        }
        distanceToTarget[neighbor] = distanceToTarget[index]! + 1;
        queue.add(neighbor);
      }
    }

    final unitStarts = province.tiles
        .where((index) => state.hexes[index].unit?.ready == true)
        .toList(growable: false);
    var moved = 0;
    for (final from in unitStarts) {
      final unit = state.hexes[from].unit;
      if (unit?.ready != true) continue;
      final candidates =
          moveTargets(from).where((index) {
            final tile = state.hexes[index];
            return provinceTiles.contains(index) &&
                tile.owner == state.turn &&
                tile.unit == null &&
                (tile.object == TileObject.none || tile.hasTree);
          }).toList()..sort((a, b) {
            final distanceOrder = (distanceToTarget[a] ?? 1 << 30).compareTo(
              distanceToTarget[b] ?? 1 << 30,
            );
            return distanceOrder != 0 ? distanceOrder : a.compareTo(b);
          });
      if (candidates.isEmpty) continue;
      if (moveUnit(from, candidates.first)) moved++;
    }
    return moved;
  }

  Set<int> unitBuildTargets(int provinceId, int strength) {
    if (strength < 1 || strength > 4) return {};
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return {};
    if (!_provinceAllowedToBuildUnit(province, strength)) return {};
    final price = strength * mod.rules.unitPricePerLevel;
    if (province.money < price) return {};

    final result = <int>{};
    for (final index in province.tiles) {
      final tile = state.hexes[index];
      if (_canPlaceBoughtUnitFriendly(tile, strength)) {
        result.add(index);
      }
      for (final neighbor in tile.neighbors) {
        final target = state.hexes[neighbor];
        if (target.active &&
            target.owner != state.turn &&
            _canAttack(strength, neighbor)) {
          result.add(neighbor);
        }
      }
    }
    return result;
  }

  /// Checks only the ruleset/diplomacy strength gate. This is intentionally
  /// separate from [unitBuildTargets]: a merge is free and has no placement
  /// target, but its resulting strength must still be legal.
  bool provinceAllowsUnitStrength(int provinceId, int strength) {
    if (strength < 1 || strength > 4) return false;
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return false;
    return _provinceAllowedToBuildUnit(province, strength);
  }

  bool _provinceAllowedToBuildUnit(Province province, int strength) {
    // Classic applies the peace-time peasant restriction through the AI
    // affordability path. Human construction still follows the ordinary
    // 1-4 strength and money rules even when diplomacy is enabled.
    if (!state.config.diplomacy || state.currentPlayerIsHuman) return true;
    if (_playerIsAtWar(province.owner)) return true;
    if (strength > 1) return false;
    var peasants = state.hexes
        .where(
          (tile) =>
              tile.unit?.strength == 1 &&
              unitOwnerAt(tile.index) == province.owner &&
              unitHomeProvinceAt(tile.index) == province.id,
        )
        .length;
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null ||
          boat.owner != province.owner ||
          boat.homeProvinceId != province.id) {
        continue;
      }
      peasants += boat.cargo.where((unit) => unit.strength == 1).length;
    }
    return peasants <= 4;
  }

  bool _playerIsAtWar(int owner) =>
      List<int>.generate(state.config.playerCount, (index) => index).any(
        (other) =>
            other != owner &&
            _isAlive(other) &&
            diplomacyBetween(owner, other) == DiplomacyStatus.war,
      );

  bool _canPlaceBoughtUnitFriendly(HexTile target, int strength) {
    if (target.owner != state.turn) return false;
    if (target.object == TileObject.town ||
        target.object == TileObject.farm ||
        target.object == TileObject.tower ||
        target.object == TileObject.strongTower ||
        target.object == TileObject.port1 ||
        target.object == TileObject.port2 ||
        _artilleryLevel(target.object) > 0) {
      return false;
    }
    return target.unit == null ||
        (unitOwnerAt(target.index) == state.turn &&
            target.unit!.strength + strength <= 4);
  }

  bool buyUnit(int provinceId, int targetIndex, int strength) {
    if (strength < 1 || strength > 4) return false;
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return false;
    if (!unitBuildTargets(provinceId, strength).contains(targetIndex)) {
      return false;
    }
    final target = state.hexes[targetIndex];
    final price = strength * mod.rules.unitPricePerLevel;
    final clearedOwnedTree = target.owner == state.turn && target.hasTree;
    province.money -= price;
    if (clearedOwnedTree) {
      province.money += _treeCutReward;
    }

    if (target.owner != state.turn) {
      _applySlayCapitalCapture(target);
      final unit = GameUnit(
        strength: strength,
        ready: false,
        owner: state.turn,
        homeProvinceId: province.id,
      );
      _captureLand(target, unit, state.turn);
      rebuildProvinces();
      _updateWinner();
      return true;
    }

    target.object = TileObject.none;
    target.treeBorn = -1;
    if (target.unit == null) {
      target.unit = GameUnit(
        strength: strength,
        ready: !clearedOwnedTree,
        owner: state.turn,
        homeProvinceId: province.id,
      );
    } else {
      target.unit!.strength += strength;
    }
    return true;
  }

  Set<int> buildTargets(int provinceId, TileObject object) {
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return {};
    // A level-two port is never placed as a separate construction. It is
    // available only through upgradePort on an existing level-one port.
    if (object == TileObject.port2) return {};
    // Slay has one land structure (the ordinary tower). Our naval extension
    // keeps ports and artillery, but farms and strong land towers stay part of
    // the generic ruleset only.
    if (state.config.slayRules &&
        (object == TileObject.farm || object == TileObject.strongTower)) {
      return {};
    }
    if (object == TileObject.port1 && !canAddPort(province)) return {};
    if (object == TileObject.artillery1 && !canAddArtillery(province)) {
      return {};
    }
    final price = switch (object) {
      TileObject.farm => farmPrice(province),
      TileObject.tower => mod.rules.towerPrice,
      TileObject.strongTower => mod.rules.strongTowerPrice,
      TileObject.port1 => mod.rules.port1Price,
      TileObject.artillery1 => mod.rules.artilleryCosts[1],
      _ => -1,
    };
    if (price < 0 || province.money < price) return {};
    return province.tiles.where((index) {
      final tile = state.hexes[index];
      if (tile.unit != null) return false;
      if (object == TileObject.strongTower && tile.object == TileObject.tower) {
        return true;
      }
      if (tile.object != TileObject.none) return false;
      if (object == TileObject.port1) {
        return _hasNavigableSeaCoast(index);
      }
      if (object == TileObject.artillery1) {
        return _hasNavigableSeaCoast(index);
      }
      if (object != TileObject.farm) return true;
      return tile.neighbors.any((neighbor) {
        final nearby = state.hexes[neighbor];
        return nearby.owner == province.owner &&
            (nearby.object == TileObject.town ||
                nearby.object == TileObject.farm);
      });
    }).toSet();
  }

  bool build(int provinceId, int targetIndex, TileObject object) {
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return false;
    if (!province.tiles.contains(targetIndex)) return false;
    if (!buildTargets(provinceId, object).contains(targetIndex)) return false;
    final target = state.hexes[targetIndex];
    final price = switch (object) {
      TileObject.farm => farmPrice(province),
      TileObject.tower => mod.rules.towerPrice,
      TileObject.strongTower => mod.rules.strongTowerPrice,
      TileObject.port1 => mod.rules.port1Price,
      TileObject.artillery1 => mod.rules.artilleryCosts[1],
      _ => -1,
    };
    province.money -= price;
    target.object = object;
    if (object == TileObject.artillery1) {
      target
        ..artilleryCooldown = 0
        ..artilleryAmmo = 0;
    }
    return true;
  }

  int portLevelAt(int tileIndex) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return 0;
    return switch (state.hexes[tileIndex].object) {
      TileObject.port1 => 1,
      TileObject.port2 => 2,
      _ => 0,
    };
  }

  bool canAddPort(Province province) {
    if (!state.config.slayRules) return true;
    if (province.tiles.length < slayPortMinimumTiles) return false;
    final ports = province.tiles.where((index) {
      final object = state.hexes[index].object;
      return object == TileObject.port1 || object == TileObject.port2;
    }).length;
    final limit = math.max(1, (province.tiles.length + 7) ~/ 8);
    return ports < limit;
  }

  bool canAddArtillery(Province province) {
    if (!state.config.slayRules) return true;
    if (province.tiles.length < slayArtilleryMinimumTiles) return false;
    final artillery = province.tiles
        .where((index) => _artilleryLevel(state.hexes[index].object) > 0)
        .length;
    return artillery < province.tiles.length ~/ slayArtilleryMinimumTiles;
  }

  bool canUpgradePortAt(int tileIndex) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return false;
    final tile = state.hexes[tileIndex];
    final province = provinceAt(tileIndex);
    return province != null &&
        province.owner == state.turn &&
        tile.object == TileObject.port1 &&
        province.money >= mod.rules.port2Price &&
        (!state.config.slayRules ||
            province.tiles.length >= slayPort2MinimumTiles);
  }

  bool upgradePort(int tileIndex) {
    if (!canUpgradePortAt(tileIndex)) return false;
    final tile = state.hexes[tileIndex];
    final province = provinceAt(tileIndex);
    province!.money -= mod.rules.port2Price;
    tile.object = TileObject.port2;
    return true;
  }

  int artilleryLevelAt(int tileIndex) =>
      tileIndex >= 0 && tileIndex < state.hexes.length
      ? _artilleryLevel(state.hexes[tileIndex].object)
      : 0;

  int artilleryAmmoCapacityAt(int tileIndex) {
    final level = artilleryLevelAt(tileIndex);
    return level == 0 ? 0 : mod.rules.artilleryAmmoCapacity[level];
  }

  int _artilleryLevel(TileObject object) => switch (object) {
    TileObject.artillery1 => 1,
    TileObject.artillery2 => 2,
    TileObject.artillery3 => 3,
    _ => 0,
  };

  bool canUpgradeArtilleryAt(int tileIndex) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return false;
    final tile = state.hexes[tileIndex];
    final province = provinceAt(tileIndex);
    final current = _artilleryLevel(tile.object);
    if (province == null ||
        province.owner != state.turn ||
        current < 1 ||
        current >= 3) {
      return false;
    }
    final minimumTiles = current == 1
        ? slayArtillery2MinimumTiles
        : slayArtillery3MinimumTiles;
    return province.money >= mod.rules.artilleryCosts[current + 1] &&
        (!state.config.slayRules || province.tiles.length >= minimumTiles);
  }

  bool upgradeArtillery(int tileIndex) {
    if (!canUpgradeArtilleryAt(tileIndex)) return false;
    final tile = state.hexes[tileIndex];
    final province = provinceAt(tileIndex)!;
    final current = _artilleryLevel(tile.object);
    final cost = mod.rules.artilleryCosts[current + 1];
    province.money -= cost;
    tile.object = current == 1 ? TileObject.artillery2 : TileObject.artillery3;
    tile.artilleryCooldown = 0;
    return true;
  }

  int boatCapacity(int level) =>
      level == 1 ? mod.rules.boat1Capacity : mod.rules.boat2Capacity;

  Set<int> boatBuildTargets(int provinceId, int portTile, int level) {
    if (level < 1 || level > 2) return {};
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return {};
    if (!province.tiles.contains(portTile)) return {};
    final port = state.hexes[portTile];
    final portLevel = switch (port.object) {
      TileObject.port1 => 1,
      TileObject.port2 => 2,
      _ => 0,
    };
    if (portLevel < level) return {};
    if (state.config.slayRules) {
      if (level == 2 && province.tiles.length < slayPort2MinimumTiles) {
        return {};
      }
      final ports = province.tiles.where((index) {
        final object = state.hexes[index].object;
        return object == TileObject.port1 || object == TileObject.port2;
      }).length;
      final boats = state.waterCells
          .where((cell) => cell.boat?.homeProvinceId == province.id)
          .length;
      if (boats >= math.max(1, ports * 2)) return {};
    }
    final price = level == 1 ? mod.rules.boat1Price : mod.rules.boat2Price;
    if (province.money < price) return {};
    return _portLaunchCells(portTile)
        .where(
          (index) =>
              state.waterCells[index].boat == null &&
              state.waterCells[index].seaFort == null,
        )
        .toSet();
  }

  Iterable<int> _portLaunchCells(int portTile) {
    final starts = state.waterCells
        .where((cell) => cell.navigable && cell.coastTiles.contains(portTile))
        .map((cell) => cell.index)
        .toList();
    final distance = <int, int>{for (final index in starts) index: 0};
    final queue = <int>[...starts];
    final radius = math.max(0, mod.rules.portLaunchRadius);
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final currentDistance = distance[index]!;
      if (currentDistance >= radius) continue;
      for (final neighbor in state.waterCells[index].neighbors) {
        if (neighbor < 0 ||
            neighbor >= state.waterCells.length ||
            distance.containsKey(neighbor) ||
            !state.waterCells[neighbor].navigable) {
          continue;
        }
        distance[neighbor] = currentDistance + 1;
        queue.add(neighbor);
      }
    }
    return distance.keys;
  }

  bool buildBoat(int provinceId, int portTile, int waterCellId, int level) {
    if (!boatBuildTargets(provinceId, portTile, level).contains(waterCellId)) {
      return false;
    }
    final province = _provinceById(provinceId)!;
    final launchCell = state.waterCells[waterCellId];
    final clearedSeaMint = launchCell.seaMint;
    province.money -= level == 1 ? mod.rules.boat1Price : mod.rules.boat2Price;
    if (clearedSeaMint) {
      launchCell.seaMint = false;
      province.money += seaMintReward;
    }
    launchCell.boat = GameBoat(
      id: state.nextNavalEntityId++,
      owner: state.turn,
      level: level,
      homeProvinceId: province.id,
      ready: !clearedSeaMint,
    );
    return true;
  }

  Set<int> unitBoatBuildTargets(int provinceId, int strength) {
    if (strength < 1 || strength > 4) return {};
    final province = _provinceById(provinceId);
    if (province == null || province.owner != state.turn) return {};
    if (!_provinceAllowedToBuildUnit(province, strength)) return {};
    if (province.money < strength * mod.rules.unitPricePerLevel) return {};
    return state.waterCells
        .where((cell) {
          final boat = cell.boat;
          return cell.navigable &&
              boat != null &&
              boat.owner == state.turn &&
              (!state.config.diplomacy ||
                  _playerIsAtWar(province.owner) ||
                  boat.homeProvinceId == province.id) &&
              cell.coastTiles.any(province.tiles.contains) &&
              boat.usedCapacity + strength <= boatCapacity(boat.level);
        })
        .map((cell) => cell.index)
        .toSet();
  }

  bool buyUnitIntoBoat(int provinceId, int waterCellId, int strength) {
    if (!unitBoatBuildTargets(provinceId, strength).contains(waterCellId)) {
      return false;
    }
    final province = _provinceById(provinceId)!;
    province.money -= strength * mod.rules.unitPricePerLevel;
    final boat = state.waterCells[waterCellId].boat!;
    boat.cargo.add(
      GameUnit(
        strength: strength,
        ready: false,
        owner: state.turn,
        homeProvinceId: boat.homeProvinceId,
      ),
    );
    return true;
  }

  int playerBoatCount(int owner) =>
      state.waterCells.where((cell) => cell.boat?.owner == owner).length;

  int playerSeaFortCount(int owner) =>
      state.waterCells.where((cell) => cell.seaFort?.owner == owner).length;

  Set<int> _openSeaFortBuildTargets(WaterCell source) =>
      source.neighbors.where((index) {
        final target = state.waterCells[index];
        return target.navigable &&
            !target.seaMint &&
            target.boat == null &&
            target.seaFort == null;
      }).toSet();

  SeaFortBuildBlock? seaFortBuildBlock(int fromWaterCell) {
    final source = waterCellById(fromWaterCell);
    final boat = source?.boat;
    if (source == null || boat == null) return SeaFortBuildBlock.noBoat;
    if (boat.owner != state.turn) return SeaFortBuildBlock.enemyBoat;
    if (boat.level < 2) return SeaFortBuildBlock.levelTwoRequired;
    if (!boat.ready) return SeaFortBuildBlock.boatAlreadyActed;
    final province = _provinceById(boat.homeProvinceId);
    if (province == null) return SeaFortBuildBlock.missingHomeProvince;
    if (province.money < mod.rules.seaFortPrice) {
      return SeaFortBuildBlock.insufficientFunds;
    }
    if (_openSeaFortBuildTargets(source).isEmpty) {
      return SeaFortBuildBlock.noOpenNeighbor;
    }
    return null;
  }

  Set<int> seaFortBuildTargets(int fromWaterCell) {
    final source = waterCellById(fromWaterCell);
    if (source == null || seaFortBuildBlock(fromWaterCell) != null) return {};
    return _openSeaFortBuildTargets(source);
  }

  bool buildSeaFort(int fromWaterCell, int targetWaterCell) {
    if (!seaFortBuildTargets(fromWaterCell).contains(targetWaterCell)) {
      return false;
    }
    final boat = state.waterCells[fromWaterCell].boat!;
    final province = _provinceById(boat.homeProvinceId)!;
    province.money -= mod.rules.seaFortPrice;
    state.waterCells[targetWaterCell].seaFort = SeaFort(
      id: state.nextNavalEntityId++,
      owner: boat.owner,
      homeProvinceId: province.id,
    );
    boat.ready = false;
    return true;
  }

  Set<int> seaFortProtectedCells(int fortWaterCell) {
    final cell = waterCellById(fortWaterCell);
    if (cell?.seaFort == null) return {};
    return <int>{fortWaterCell, ...cell!.neighbors};
  }

  Set<int> seaFortNetworkProtectedCells(int fortWaterCell) {
    final fort = waterCellById(fortWaterCell)?.seaFort;
    if (fort == null) return {};
    final result = <int>{};
    for (final cell in state.waterCells) {
      final other = cell.seaFort;
      if (other != null &&
          other.owner == fort.owner &&
          other.homeProvinceId == fort.homeProvinceId) {
        result.addAll(seaFortProtectedCells(cell.index));
      }
    }
    return result;
  }

  bool _protectedByEnemySeaFort(int waterCellId, int owner) {
    for (final cell in state.waterCells) {
      final fort = cell.seaFort;
      if (fort != null &&
          areEnemies(owner, fort.owner) &&
          seaFortProtectedCells(cell.index).contains(waterCellId)) {
        return true;
      }
    }
    return false;
  }

  Set<int> boatMoveTargets(int fromWaterCell) {
    final source = waterCellById(fromWaterCell);
    final boat = source?.boat;
    if (source == null ||
        boat == null ||
        !source.navigable ||
        boat.owner != state.turn ||
        !boat.ready) {
      return {};
    }
    final result = <int>{};
    final distance = <int, int>{fromWaterCell: 0};
    final queue = <int>[fromWaterCell];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final nextDistance = distance[index]! + 1;
      if (nextDistance > mod.rules.boatMoveLimit) continue;
      for (final neighbor in state.waterCells[index].neighbors) {
        if (distance.containsKey(neighbor)) continue;
        distance[neighbor] = nextDistance;
        final target = state.waterCells[neighbor];
        if (!target.navigable) continue;
        final fort = target.seaFort;
        if (fort != null) {
          if (hasMilitaryAccess(boat.owner, fort.owner)) {
            queue.add(neighbor);
          } else if (areEnemies(boat.owner, fort.owner) && boat.level >= 2) {
            result.add(neighbor);
          }
          continue;
        }
        if (boat.level < 2 && _protectedByEnemySeaFort(neighbor, boat.owner)) {
          continue;
        }
        if (target.seaMint) {
          // Mint is a solid water obstacle. A boat may enter the first mint
          // cell to clear it, but pathfinding must never sail through it.
          result.add(neighbor);
          continue;
        }
        if (target.boat == null) {
          result.add(neighbor);
          queue.add(neighbor);
        } else if (hasMilitaryAccess(boat.owner, target.boat!.owner)) {
          // A friendly ship occupies the cell, but does not block the route to
          // a free cell behind it, just like friendly land pieces do not stop
          // unit pathfinding through their province.
          queue.add(neighbor);
        } else if (areEnemies(state.turn, target.boat!.owner) &&
            boatCombatPower(boat) >= boatCombatPower(target.boat!)) {
          // Enemy fleets can be attacked, but cannot be sailed through.
          result.add(neighbor);
        }
      }
    }
    return result;
  }

  int boatCombatPower(GameBoat boat) =>
      boat.level + boat.cargo.fold(0, (sum, unit) => sum + unit.strength);

  void _clearSeaMint(WaterCell cell, GameBoat boat) {
    if (!cell.seaMint) return;
    cell.seaMint = false;
    final province = _provinceById(boat.homeProvinceId);
    if (province != null && province.owner == boat.owner) {
      province.money += seaMintReward;
    }
  }

  void _sinkBoatIntoSeaMint(WaterCell cell) {
    final boat = cell.boat;
    if (boat == null) return;
    _materializeNavalCapitalsForBoat(boat);
    cell.boat = null;
    if (cell.navigable && cell.seaFort == null) cell.seaMint = true;
  }

  bool moveBoat(int fromWaterCell, int toWaterCell) {
    if (!boatMoveTargets(fromWaterCell).contains(toWaterCell)) return false;
    final source = state.waterCells[fromWaterCell];
    final boat = source.boat!;
    final targetCell = state.waterCells[toWaterCell];
    final targetFort = targetCell.seaFort;
    if (targetFort != null && areEnemies(boat.owner, targetFort.owner)) {
      if (boat.level < 2) return false;
      _materializeNavalCapitalsForBoat(boat);
      source.boat = null;
      targetCell.seaFort = null;
      if (!_isValidSupplyChain(targetCell, boat)) {
        boat.supportedTiles.clear();
      }
      targetCell.boat = boat..ready = false;
      return true;
    }
    final defender = targetCell.boat;
    if (defender != null) {
      final attack = boatCombatPower(boat);
      final defense = boatCombatPower(defender);
      if (attack < defense) return false;
      _materializeNavalCapitalsForBoat(boat);
      _materializeNavalCapitalsForBoat(defender);
      source.boat = null;
      if (attack == defense) {
        targetCell
          ..boat = null
          ..seaMint = true;
      } else {
        if (!_isValidSupplyChain(targetCell, boat)) {
          boat.supportedTiles.clear();
        }
        targetCell.boat = boat..ready = false;
      }
      return true;
    }
    _materializeNavalCapitalsForBoat(boat);
    source.boat = null;
    _clearSeaMint(targetCell, boat);
    if (!_isValidSupplyChain(targetCell, boat)) {
      boat.supportedTiles.clear();
    }
    targetCell.boat = boat..ready = false;
    return true;
  }

  /// Sends every ready friendly boat toward one sea cell. Boats only sail to
  /// empty water and never auto-attack or merge during this group command.
  int massSail(int targetWaterCell) {
    final target = waterCellById(targetWaterCell);
    if (target == null || !target.navigable) return 0;
    final distanceToTarget = <int, int>{targetWaterCell: 0};
    final queue = <int>[targetWaterCell];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      for (final neighbor in state.waterCells[index].neighbors) {
        final cell = state.waterCells[neighbor];
        if (!cell.navigable || distanceToTarget.containsKey(neighbor)) {
          continue;
        }
        distanceToTarget[neighbor] = distanceToTarget[index]! + 1;
        queue.add(neighbor);
      }
    }

    final starts =
        state.waterCells
            .where(
              (cell) =>
                  cell.boat?.owner == state.turn && cell.boat?.ready == true,
            )
            .map((cell) => cell.index)
            .toList()
          ..sort(
            (a, b) => (distanceToTarget[a] ?? 1 << 30).compareTo(
              distanceToTarget[b] ?? 1 << 30,
            ),
          );
    var moved = 0;
    for (final from in starts) {
      final boat = state.waterCells[from].boat;
      if (boat?.owner != state.turn || boat?.ready != true) continue;
      final currentDistance = distanceToTarget[from] ?? 1 << 30;
      final candidates =
          boatMoveTargets(from).where((index) {
            final cell = state.waterCells[index];
            return cell.boat == null &&
                cell.seaFort == null &&
                (distanceToTarget[index] ?? 1 << 30) < currentDistance;
          }).toList()..sort((a, b) {
            final byDistance = (distanceToTarget[a] ?? 1 << 30).compareTo(
              distanceToTarget[b] ?? 1 << 30,
            );
            return byDistance != 0 ? byDistance : a.compareTo(b);
          });
      if (candidates.isNotEmpty && moveBoat(from, candidates.first)) moved++;
    }
    return moved;
  }

  Set<int> unitBoardingTargets(int fromTile) {
    if (fromTile < 0 || fromTile >= state.hexes.length) return {};
    final tile = state.hexes[fromTile];
    final unit = tile.unit;
    if (unit == null || unitOwnerAt(fromTile) != state.turn || !unit.ready) {
      return {};
    }
    _normalizeUnitIdentity(fromTile);
    final sourceProvince = _provinceById(unit.homeProvinceId);
    final keepPeaceCapAtHome =
        state.config.diplomacy &&
        sourceProvince != null &&
        !_playerIsAtWar(unit.owner) &&
        unit.strength == 1;
    final reachableCoast = _reachableFriendlyTiles(fromTile, unit.owner);
    return state.waterCells
        .where((cell) {
          final boat = cell.boat;
          return cell.navigable &&
              boat != null &&
              boat.owner == state.turn &&
              (!keepPeaceCapAtHome ||
                  boat.homeProvinceId == sourceProvince.id) &&
              boat.usedCapacity + unit.strength <= boatCapacity(boat.level) &&
              cell.coastTiles.any(reachableCoast.contains);
        })
        .map((cell) => cell.index)
        .toSet();
  }

  Set<int> _reachableFriendlyTiles(int fromTile, [int? owner]) {
    final actor = owner ?? state.turn;
    final result = <int>{fromTile};
    final distance = <int, int>{fromTile: 0};
    final queue = <int>[fromTile];
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final nextDistance = distance[index]! + 1;
      if (nextDistance > mod.rules.unitMoveLimit) continue;
      for (final neighbor in state.hexes[index].neighbors) {
        final tile = state.hexes[neighbor];
        if (!tile.active ||
            !_canTraverseLand(actor, tile) ||
            distance.containsKey(neighbor)) {
          continue;
        }
        distance[neighbor] = nextDistance;
        result.add(neighbor);
        queue.add(neighbor);
      }
    }
    return result;
  }

  bool boardUnit(int fromTile, int waterCellId) {
    if (!unitBoardingTargets(fromTile).contains(waterCellId)) return false;
    final unit = state.hexes[fromTile].unit!;
    final boat = state.waterCells[waterCellId].boat!;
    final reachable = _reachableFriendlyTiles(fromTile, unit.owner);
    // The flood-fill visits nearest coast first, just like moveTargets.
    final coast = reachable
        .where(state.waterCells[waterCellId].coastTiles.contains)
        .firstOrNull;
    if (coast != null) {
      _recordLandTransit(unit, unit.owner, [fromTile], coast);
    }
    state.hexes[fromTile].unit = null;
    boat.cargo.add(unit..ready = false);
    _normalizeCargoFunding(boat);
    if (_isSupportedBridgehead(fromTile, state.turn)) {
      rebuildProvinces();
    }
    return true;
  }

  Set<int> boatDisembarkTargets(int waterCellId, int cargoIndex) {
    final cell = waterCellById(waterCellId);
    final boat = cell?.boat;
    if (cell == null ||
        !cell.navigable ||
        boat == null ||
        boat.owner != state.turn) {
      return {};
    }
    if (cargoIndex < 0 || cargoIndex >= boat.cargo.length) return {};
    final unit = boat.cargo[cargoIndex];
    if (!unit.ready) return {};
    return _navalLandingDistances(cell).keys.where((index) {
      final target = state.hexes[index];
      if (!target.active) return false;
      if (_canTraverseLand(boat.owner, target)) {
        return _canOccupyFriendly(unit, target, actor: boat.owner);
      }
      return _canAttackFor(boat.owner, unit.strength, index);
    }).toSet();
  }

  /// Treats a boat as a temporary origin for an ordinary land move. Friendly
  /// land may be crossed, enemy and neutral land may only be the destination,
  /// and the water-to-coast step counts toward the normal movement radius.
  /// This removes the old three-tile landing cap without allowing an unlimited
  /// bridgehead chain to crawl inland.
  Map<int, int> _navalLandingDistances(WaterCell cell) {
    final distances = <int, int>{};
    final queue = <int>[];
    for (final index in cell.coastTiles) {
      if (index < 0 || index >= state.hexes.length) continue;
      final tile = state.hexes[index];
      if (!tile.active) continue;
      distances[index] = 1;
      queue.add(index);
    }
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      final distance = distances[index]!;
      if (distance >= mod.rules.unitMoveLimit ||
          !_canTraverseLand(state.turn, state.hexes[index])) {
        continue;
      }
      for (final neighbor in state.hexes[index].neighbors) {
        if (neighbor < 0 ||
            neighbor >= state.hexes.length ||
            distances.containsKey(neighbor) ||
            !state.hexes[neighbor].active) {
          continue;
        }
        distances[neighbor] = distance + 1;
        queue.add(neighbor);
      }
    }
    return distances;
  }

  bool disembarkUnit(int waterCellId, int cargoIndex, int targetIndex) {
    if (!boatDisembarkTargets(waterCellId, cargoIndex).contains(targetIndex)) {
      return false;
    }
    final boat = state.waterCells[waterCellId].boat!;
    final unit = boat.cargo.removeAt(cargoIndex)..ready = false;
    unit.owner = boat.owner;
    unit.homeProvinceId = boat.homeProvinceId;
    _recordLandTransit(
      unit,
      boat.owner,
      state.waterCells[waterCellId].coastTiles.toList(),
      targetIndex,
      initialDistance: 1,
    );
    final target = state.hexes[targetIndex];
    final homeProvince = _provinceById(boat.homeProvinceId);
    if (_canTraverseLand(boat.owner, target)) {
      final ownSovereignLand =
          target.coalitionClaim == null && target.owner == boat.owner;
      if (ownSovereignLand && target.hasTree && homeProvince != null) {
        homeProvince.money += _treeCutReward;
      }
      if (ownSovereignLand) {
        target.object = TileObject.none;
        target.treeBorn = -1;
        unit.transitAllies.clear();
      } else if (target.coalitionClaim == null &&
          target.owner >= 0 &&
          target.owner != boat.owner) {
        if (!unit.transitAllies.contains(target.owner)) {
          unit.transitAllies.add(target.owner);
          unit.transitAllies.sort();
        }
      }
      if (target.unit == null) {
        target.unit = unit;
      } else {
        target.unit!.strength += unit.strength;
        target.unit!.ready = false;
        final transit = {
          ...target.unit!.transitAllies,
          ...unit.transitAllies,
        }.toList()..sort();
        target.unit!.transitAllies
          ..clear()
          ..addAll(ownSovereignLand ? const <int>[] : transit);
      }
      _fundUnitOnOwnLand(target);
      if (ownSovereignLand && provinceAt(targetIndex) == null) {
        if (!boat.supportedTiles.contains(targetIndex)) {
          boat.supportedTiles.add(targetIndex);
        }
        rebuildProvinces();
        _updateWinner();
      }
    } else {
      _applySlayCapitalCapture(target);
      _captureLand(target, unit, boat.owner);
      if (target.coalitionClaim == null &&
          !boat.supportedTiles.contains(targetIndex)) {
        boat.supportedTiles.add(targetIndex);
      }
      rebuildProvinces();
      _refreshNavalSupportLinks();
      _updateWinner();
    }
    return true;
  }

  /// Converts an intentionally departed LAN faction into neutral territory.
  /// Buildings, units, boats and forts remain on the board as abandoned
  /// objects; only sovereignty, funding and readiness are removed. This is
  /// deliberately separate from bankruptcy/elimination, which has different
  /// grave and sea-mint rules.
  bool neutralizeDepartedPlayer(int player) {
    if (player < 0 || player >= state.config.playerCount) return false;
    // A leaving seat cannot retain a veto or leave dangling claim references.
    // End its outstanding military contract and return its disputed pool
    // before neutralizing sovereign assets (ordinary conquests stay intact).
    final ended = state.campaigns
        .where(
          (campaign) =>
              campaign.sideA.contains(player) ||
              campaign.sideB.contains(player),
        )
        .toList();
    for (final campaign in ended) {
      _openPeaceConferences(campaign);
      _setCampaignPeace(campaign);
      state.campaigns.remove(campaign);
    }
    final endedIds = ended.map((campaign) => campaign.id).toSet();
    for (final conference in state.peaceConferences.toList()) {
      if (conference.participants.contains(player) ||
          conference.originalOwner == player ||
          endedIds.contains(conference.sourceCampaignId)) {
        _resolvePeaceConference(conference, useAllocation: false);
      }
    }
    var changed = false;
    final removedProvinceIds = state.provinces
        .where((province) => province.owner == player)
        .map((province) => province.id)
        .toSet();
    if (removedProvinceIds.isNotEmpty) {
      state.provinces.removeWhere((province) => province.owner == player);
      changed = true;
    }

    for (final tile in state.hexes) {
      final unit = tile.unit;
      final unitOwner = unit == null ? -1 : unitOwnerAt(tile.index);
      if (tile.owner == player) {
        tile
          ..owner = -1
          ..coalitionClaim = null;
        changed = true;
      }
      if (unit != null &&
          (unitOwner == player ||
              removedProvinceIds.contains(unit.homeProvinceId))) {
        unit
          ..owner = -1
          ..homeProvinceId = -1
          ..ready = false;
        unit.transitAllies.clear();
        changed = true;
      }
    }

    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat != null &&
          (boat.owner == player ||
              removedProvinceIds.contains(boat.homeProvinceId))) {
        boat
          ..owner = -1
          ..homeProvinceId = -1
          ..ready = false;
        boat.supportedTiles.clear();
        for (final unit in boat.cargo) {
          unit
            ..owner = -1
            ..homeProvinceId = -1
            ..ready = false;
          unit.transitAllies.clear();
        }
        changed = true;
      }
      final fort = cell.seaFort;
      if (fort != null &&
          (fort.owner == player ||
              removedProvinceIds.contains(fort.homeProvinceId))) {
        fort
          ..owner = -1
          ..homeProvinceId = -1;
        changed = true;
      }
    }

    for (var other = 0; other < state.config.playerCount; other++) {
      if (other == player) continue;
      state.diplomacyRelations[player][other] = DiplomacyStatus.peace;
      state.diplomacyRelations[other][player] = DiplomacyStatus.peace;
      state.diplomacyAllianceTurns[player][other] = 0;
      state.diplomacyAllianceTurns[other][player] = 0;
      state.diplomacyWarCooldowns[player][other] = 0;
      state.diplomacyWarCooldowns[other][player] = 0;
      state.diplomacyBlackMarks[player][other] = false;
      state.diplomacyBlackMarks[other][player] = false;
      state.diplomacyBlackMarkCooldowns[player][other] = 0;
      state.diplomacyBlackMarkCooldowns[other][player] = 0;
      state.diplomacyDebts[player][other] = 0;
      state.diplomacyDebts[other][player] = 0;
    }
    state.diplomacyTraitorTurns[player] = 0;
    state.diplomacySubsidies.removeWhere(
      (item) => item.payer == player || item.receiver == player,
    );
    state.diplomacyProposals.removeWhere(
      (item) => item.from == player || item.to == player,
    );
    state.diplomacyMessages.removeWhere(
      (item) => item.from == player || item.to == player,
    );
    state.winner = null;
    return changed;
  }

  void endTurn() {
    if (state.winner != null) return;
    _materializeOrphanedNavalCapitals();
    lastArtilleryStrikes.clear();
    final current = state.turn;
    var next = current;
    for (var i = 0; i < state.config.playerCount; i++) {
      next = (next + 1) % state.config.playerCount;
      if (_isAlive(next)) break;
    }
    final wrapped = next <= current;
    if (wrapped) {
      _advanceDiplomacyRound();
      // Settle the same pre-bankruptcy board for every province. Losing a
      // supply boat must not change a later province's bill this round.
      final settlements = [
        for (final province in state.provinces)
          (
            province: province,
            balance: economicBreakdown(province, includeDiplomacy: false).total,
          ),
      ]..sort((a, b) => a.province.id.compareTo(b.province.id));
      for (final settlement in settlements) {
        settlement.province.money += settlement.balance;
      }
      for (final settlement in settlements) {
        _resolveBankruptcy(settlement.province);
      }
      _processArtilleryRound();
      state.round++;
      _spreadTrees();
      _spreadSeaMint();
    }
    state.turn = next;
    _preparePlayerTurn(next);
    for (final tile in state.hexes) {
      if (tile.unit != null && unitOwnerAt(tile.index) == next) {
        tile.unit!.ready = true;
      }
    }
    for (final cell in state.waterCells) {
      if (cell.boat?.owner == next) {
        cell.boat!.ready = true;
        for (final unit in cell.boat!.cargo) {
          unit.ready = true;
        }
      }
    }
    _updateWinner(commit: true);
  }

  void _advanceDiplomacyRound() {
    _advanceOpinionRound();
    if (!state.config.diplomacy) return;

    // Debts are paid before ordinary income, richest provinces first.
    for (var payer = 0; payer < state.config.playerCount; payer++) {
      for (var receiver = 0; receiver < state.config.playerCount; receiver++) {
        final debt = state.diplomacyDebts[payer][receiver];
        if (debt <= 0 || !_isAlive(payer) || !_isAlive(receiver)) continue;
        if (areEnemies(payer, receiver)) {
          continue;
        }
        final paid = _transferPlayerMoney(payer, receiver, debt);
        state.diplomacyDebts[payer][receiver] = debt - paid;
      }
    }

    final renewedSubsidies = <DiplomacySubsidy>[];
    for (final subsidy in state.diplomacySubsidies) {
      if (!_isAlive(subsidy.payer) || !_isAlive(subsidy.receiver)) continue;
      if (!subsidy.mandatory && areEnemies(subsidy.payer, subsidy.receiver)) {
        continue;
      }
      final affordable = math.max(0, playerIncome(subsidy.payer));
      final paid = _transferPlayerMoney(
        subsidy.payer,
        subsidy.receiver,
        math.min(subsidy.amount, affordable),
      );
      if (!subsidy.mandatory) {
        changeOpinion(
          subsidy.receiver,
          subsidy.payer,
          paid > 0 ? 1 : -2,
          paid > 0 ? 'Субсидия төленді' : 'Субсидия төленбеді',
        );
      }
      if (subsidy.turnsLeft > 1) {
        renewedSubsidies.add(
          subsidy.copyWith(turnsLeft: subsidy.turnsLeft - 1),
        );
      }
    }
    state.diplomacySubsidies
      ..clear()
      ..addAll(renewedSubsidies);

    // Keep charging the old save-format global fine when loading a game that
    // already contained it. New friendship breaks use the pair-specific,
    // receiver-paid mandatory contracts above.
    for (var player = 0; player < state.config.playerCount; player++) {
      if (state.diplomacyTraitorTurns[player] <= 0 || !_isAlive(player)) {
        continue;
      }
      final fine = _traitorFine(player);
      final provinces = provincesOf(player).toList()
        ..sort((a, b) => b.money.compareTo(a.money));
      if (provinces.isNotEmpty) provinces.first.money -= fine;
      state.diplomacyTraitorTurns[player]--;
    }

    for (var first = 0; first < state.config.playerCount; first++) {
      for (
        var second = first + 1;
        second < state.config.playerCount;
        second++
      ) {
        final cooldown = state.diplomacyWarCooldowns[first][second];
        if (cooldown > 0) {
          final next = cooldown - 1;
          state.diplomacyWarCooldowns[first][second] = next;
          state.diplomacyWarCooldowns[second][first] = next;
        }
        final markCooldown = state.diplomacyBlackMarkCooldowns[first][second];
        if (markCooldown > 0) {
          final next = markCooldown - 1;
          state.diplomacyBlackMarkCooldowns[first][second] = next;
          state.diplomacyBlackMarkCooldowns[second][first] = next;
        }
        final alliance = state.diplomacyAllianceTurns[first][second];
        if (alliance <= 0) continue;
        if (alliance == 1 &&
            diplomacyBetween(first, second) == DiplomacyStatus.coalition &&
            _militaryCommitmentsPending(militaryAllianceComponent(first))) {
          // Campaign shares remain binding until the war/conference settles.
          // Transit alone does not prolong a treaty: troops return on expiry.
          continue;
        }
        final next = alliance - 1;
        state.diplomacyAllianceTurns[first][second] = next;
        state.diplomacyAllianceTurns[second][first] = next;
        if (next == 0 &&
            diplomacyBetween(first, second) == DiplomacyStatus.coalition) {
          setDiplomacyStatus(first, second, DiplomacyStatus.alliance);
          state.diplomacyAllianceTurns[first][second] = 6;
          state.diplomacyAllianceTurns[second][first] = 6;
          final displaced = <({int source, GameUnit unit})>[];
          for (final tile in state.hexes) {
            final unit = tile.unit;
            if (unit == null ||
                unit.owner == tile.owner ||
                hasMilitaryAccess(unit.owner, tile.owner)) {
              continue;
            }
            tile.unit = null;
            displaced.add((source: tile.index, unit: unit));
          }
          for (final item in displaced) {
            _repatriatePeaceConferenceUnit(item.source, item.unit);
          }
          _logDiplomacy(
            '${state.playerName(first)} және ${state.playerName(second)} әскери одағының мерзімі аяқталды; 6 ход достық сақталады',
          );
          continue;
        }
        if (next == 0 &&
            diplomacyBetween(first, second) == DiplomacyStatus.alliance) {
          setDiplomacyStatus(first, second, DiplomacyStatus.peace);
          _logDiplomacy(
            '${state.playerName(first)} және ${state.playerName(second)} достығы аяқталды',
          );
        }
      }
    }
    state.diplomacyProposals.removeWhere(
      (proposal) => state.round - proposal.createdRound >= 3,
    );
    _advancePeaceConferences(state.round + 1);
  }

  void _advancePeaceConferences(int completedRound) {
    final expired = state.peaceConferences
        .where((conference) => completedRound >= conference.deadlineRound)
        .toList();
    for (final conference in expired) {
      _resolvePeaceConference(conference, useAllocation: false);
    }
  }

  void _resolveBankruptcy(Province province) {
    if (province.money >= 0) return;
    final units =
        state.hexes
            .where(
              (tile) =>
                  tile.unit != null &&
                  unitOwnerAt(tile.index) == province.owner &&
                  unitHomeProvinceAt(tile.index) == province.id,
            )
            .toList()
          ..sort((a, b) => b.unit!.strength.compareTo(a.unit!.strength));
    for (final tile in units) {
      tile.unit = null;
      if (tile.coalitionClaim == null &&
          (tile.owner == province.owner || tile.object == TileObject.none)) {
        tile.object = TileObject.grave;
        // Economy is resolved immediately before the round counter advances.
        // Stamp the grave with the upcoming round so it remains visible for
        // one complete round before becoming a tree.
        tile.treeBorn = state.round + 1;
      }
    }
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat?.owner != province.owner ||
          boat?.homeProvinceId != province.id) {
        continue;
      }
      // Cargo dies with the unsupported ship. Landed bridgeheads keep their
      // own budgets, but the departed supply ship becomes harvestable mint.
      _sinkBoatIntoSeaMint(cell);
    }
    province.money = 0;
  }

  void _preparePlayerTurn(int owner) {
    final provinceTiles = provincesOf(
      owner,
    ).expand((province) => province.tiles).toSet();
    for (final tile in state.hexes) {
      if (tile.owner != owner || tile.object != TileObject.grave) continue;
      if (tile.treeBorn < state.round) _turnIntoTree(tile);
    }
    for (final tile in state.hexes) {
      if (tile.owner != owner || provinceTiles.contains(tile.index)) continue;
      if (tile.coalitionClaim != null) continue;
      if (_isSupportedBridgehead(tile.index, owner)) continue;
      if (tile.unit != null) {
        if (unitOwnerAt(tile.index) != owner) continue;
        tile.unit = null;
        tile.object = TileObject.grave;
        tile.treeBorn = state.round;
      } else if (tile.object == TileObject.town ||
          tile.object == TileObject.port1 ||
          tile.object == TileObject.port2) {
        tile.unit = null;
        _turnIntoTree(tile);
      }
    }
  }

  void _turnIntoTree(HexTile tile) {
    if (tile.unit != null) return;
    tile.object = _isCoastal(tile) ? TileObject.palm : TileObject.pine;
    tile.treeBorn = state.round;
  }

  bool _isCoastal(HexTile tile) => _hasNavigableSeaCoast(tile.index);

  bool _hasNavigableSeaCoast(int tileIndex) => state.waterCells.any(
    (cell) => cell.navigable && cell.coastTiles.contains(tileIndex),
  );

  void sanitizeOverlaps() {
    // Migrate saves created while a departed boat could leave a permanent
    // one-hex city behind. A lone permanent province is never a civilization;
    // removing it here lets the normal orphan cleanup below turn its house or
    // port into the correct coastal/inland tree.
    state.provinces.removeWhere(
      (province) => !province.navalCapital && province.tiles.length < 2,
    );
    final provinceTiles = state.provinces
        .expand((province) => province.tiles)
        .toSet();
    for (final tile in state.hexes) {
      if (tile.unit != null &&
          unitOwnerAt(tile.index) == tile.owner &&
          (tile.hasTree || tile.object == TileObject.grave)) {
        tile
          ..object = TileObject.none
          ..treeBorn = -1;
      }
      if (tile.owner < 0 || provinceTiles.contains(tile.index)) continue;
      if (tile.object == TileObject.town ||
          tile.object == TileObject.port1 ||
          tile.object == TileObject.port2) {
        tile.unit = null;
        _turnIntoTree(tile);
      } else if (tile.object == TileObject.farm) {
        tile.object = TileObject.none;
      }
    }
    for (final cell in state.waterCells) {
      if (cell.boat != null && cell.seaFort != null) {
        cell.seaFort = null;
      }
      if (!cell.navigable || cell.boat != null || cell.seaFort != null) {
        cell.seaMint = false;
      }
    }
  }

  void _spreadTrees() {
    final rng = FastRandom(state.rngState);
    final additions = <int, TileObject>{};
    for (final target in state.hexes) {
      if (!target.active ||
          target.coalitionClaim != null ||
          target.object != TileObject.none ||
          target.unit != null) {
        continue;
      }
      final nearbyTrees = target.neighbors
          .map((index) => state.hexes[index])
          .where((tile) => tile.hasTree)
          .toList(growable: false);
      if (_isCoastal(target)) {
        final hasMaturePalm = nearbyTrees.any(
          (tree) =>
              tree.object == TileObject.palm && tree.treeBorn < state.round,
        );
        final palmChance = state.config.slayRules
            ? 1.0
            : mod.rules.palmSpreadChance;
        if (hasMaturePalm && rng.nextDouble() < palmChance) {
          additions[target.index] = TileObject.palm;
        }
      } else {
        final hasMaturePine = nearbyTrees.any(
          (tree) =>
              tree.object == TileObject.pine && tree.treeBorn < state.round,
        );
        final pineChance = state.config.slayRules
            ? .8
            : mod.rules.pineSpreadChance;
        if (nearbyTrees.length >= 2 &&
            hasMaturePine &&
            rng.nextDouble() < pineChance) {
          additions[target.index] = TileObject.pine;
        }
      }
    }
    for (final entry in additions.entries) {
      state.hexes[entry.key]
        ..object = entry.value
        ..treeBorn = state.round;
    }
    state.rngState = rng.state;
  }

  void _spreadSeaMint() {
    final rng = FastRandom(state.rngState);
    final additions = <int>{};
    final sources = state.waterCells
        .where((cell) => cell.navigable && cell.seaMint)
        .toList(growable: false);
    for (final source in sources) {
      if (rng.nextDouble() >= seaMintSpreadChance) continue;
      final candidates = source.neighbors.where((index) {
        if (index < 0 || index >= state.waterCells.length) return false;
        final target = state.waterCells[index];
        return target.navigable &&
            !target.seaMint &&
            target.boat == null &&
            target.seaFort == null &&
            !additions.contains(index);
      }).toList()..sort();
      if (candidates.isEmpty) continue;
      additions.add(candidates[rng.nextInt(candidates.length)]);
    }
    for (final index in additions) {
      state.waterCells[index].seaMint = true;
    }
    state.rngState = rng.state;
  }

  Set<int> artilleryTargetWaterCells(int tileIndex) =>
      _artilleryWaterDistances(tileIndex).keys.toSet();

  Map<int, int> _artilleryWaterDistances(int tileIndex) {
    if (tileIndex < 0 || tileIndex >= state.hexes.length) return {};
    final distance = <int, int>{};
    final queue = <int>[];
    for (final cell in state.waterCells) {
      if (cell.navigable && cell.coastTiles.contains(tileIndex)) {
        distance[cell.index] = 1;
        queue.add(cell.index);
      }
    }
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final index = queue[cursor];
      if (distance[index]! >= 2) continue;
      for (final neighbor in state.waterCells[index].neighbors) {
        final cell = state.waterCells[neighbor];
        if (!cell.navigable || distance.containsKey(neighbor)) continue;
        distance[neighbor] = distance[index]! + 1;
        queue.add(neighbor);
      }
    }
    return distance;
  }

  void _processArtilleryRound() {
    for (final tile in state.hexes) {
      final level = _artilleryLevel(tile.object);
      if (level == 0) continue;
      final ammoCapacity = mod.rules.artilleryAmmoCapacity[level];
      if (tile.artilleryCooldown > 0) {
        tile.artilleryCooldown--;
        if (tile.artilleryCooldown == 0 && tile.artilleryAmmo <= 0) {
          tile.artilleryAmmo = ammoCapacity;
        }
        continue;
      }
      if (tile.artilleryAmmo <= 0) {
        // An empty cannon spends this entire artillery phase reloading. It
        // never creates a paid emergency shell and therefore cannot fire in
        // the same round in which it had no ammunition.
        tile.artilleryAmmo = ammoCapacity;
        continue;
      }
      final province = provinceAt(tile.index);
      if (province == null) continue;
      final distances = _artilleryWaterDistances(tile.index);
      final targets =
          distances.keys.where((index) {
            final boat = state.waterCells[index].boat;
            return boat != null && areEnemies(tile.owner, boat.owner);
          }).toList()..sort((a, b) {
            final byDistance = distances[a]!.compareTo(distances[b]!);
            return byDistance != 0 ? byDistance : a.compareTo(b);
          });
      var shots = math.min(level, tile.artilleryAmmo);
      var fired = false;
      while (shots > 0 && targets.isNotEmpty) {
        final targetIndex = targets.first;
        final boat = state.waterCells[targetIndex].boat;
        if (boat == null || !areEnemies(tile.owner, boat.owner)) {
          targets.removeAt(0);
          continue;
        }
        tile.artilleryAmmo--;
        shots--;
        fired = true;
        boat.damage++;
        final destroyed = boat.damage >= boat.level;
        lastArtilleryStrikes.add(
          ArtilleryStrike(
            fromTile: tile.index,
            toWaterCell: targetIndex,
            sourceOwner: tile.owner,
            targetOwner: boat.owner,
            targetLevel: boat.level,
            destroyed: destroyed,
          ),
        );
        if (destroyed) {
          _sinkBoatIntoSeaMint(state.waterCells[targetIndex]);
          targets.removeAt(0);
        }
      }
      if (fired) tile.artilleryCooldown = 1;
    }
    _refreshNavalSupportLinks();
  }

  void rebuildProvinces({bool preserveNewCapitalUnits = false}) {
    // Resolve lost coast/inland links before deciding which one-hex
    // components still qualify as supplied provinces.
    _refreshNavalSupportLinks();
    final old = state.provinces;
    final oldByTile = <int, Province>{};
    for (final province in old) {
      for (final index in province.tiles) {
        oldByTile[index] = province;
      }
    }
    final seen = <int>{};
    final components =
        <
          ({int owner, List<int> tiles, bool navalCapital, bool navalFounded})
        >[];
    for (final tile in state.hexes) {
      if (!tile.active ||
          tile.owner < 0 ||
          tile.coalitionClaim != null ||
          seen.contains(tile.index)) {
        continue;
      }
      final queue = <int>[tile.index];
      final tiles = <int>[];
      seen.add(tile.index);
      for (var i = 0; i < queue.length; i++) {
        final index = queue[i];
        tiles.add(index);
        for (final neighbor in state.hexes[index].neighbors) {
          if (!seen.contains(neighbor) &&
              state.hexes[neighbor].owner == tile.owner &&
              state.hexes[neighbor].coalitionClaim == null) {
            seen.add(neighbor);
            queue.add(neighbor);
          }
        }
      }
      final navalCapital = _isNavalCapitalComponent(tile.owner, tiles);
      final navalFounded = tiles.any(
        (index) => oldByTile[index]?.navalFounded == true,
      );
      // A permanent civilization needs at least two connected land hexes.
      // Only an actively supplied boat-city may temporarily exist on one hex;
      // navalFounded is historical state, not an exemption from this rule.
      if (tiles.length >= 2 || navalCapital) {
        components.add((
          owner: tile.owner,
          tiles: tiles,
          navalCapital: navalCapital,
          navalFounded: navalCapital || navalFounded,
        ));
      }
    }

    // Classic reduction rule: a split province keeps its identity and money in
    // the part containing its city. If the city was lost, farms decide, then
    // size. Fresh fragments start at zero money.
    // Index actual overlaps once. Scanning the whole board for every old
    // province made a fragmented map quadratic after each capture.
    final overlaps = <int, Map<int, ({bool capital, int farms, int count})>>{};
    for (var i = 0; i < components.length; i++) {
      for (final index in components[i].tiles) {
        final previous = oldByTile[index];
        if (previous == null || previous.owner != components[i].owner) continue;
        final candidates = overlaps.putIfAbsent(previous.id, () => {});
        final prior = candidates[i];
        candidates[i] = (
          capital: (prior?.capital ?? false) || index == previous.capital,
          farms:
              (prior?.farms ?? 0) +
              (state.hexes[index].object == TileObject.farm ? 1 : 0),
          count: (prior?.count ?? 0) + 1,
        );
      }
    }
    final successorByOld = <int, int>{};
    for (final province in old) {
      var best = -1;
      var bestHasCapital = false;
      var bestFarmCount = -1;
      var bestOverlap = -1;
      for (final entry in (overlaps[province.id] ?? {}).entries) {
        final i = entry.key;
        final hasCapital = entry.value.capital;
        final farmCount = entry.value.farms;
        final count = entry.value.count;
        if ((hasCapital && !bestHasCapital) ||
            (hasCapital == bestHasCapital && farmCount > bestFarmCount) ||
            (hasCapital == bestHasCapital &&
                farmCount == bestFarmCount &&
                count > bestOverlap)) {
          bestHasCapital = hasCapital;
          bestFarmCount = farmCount;
          bestOverlap = count;
          best = i;
        }
      }
      if (best >= 0) successorByOld[province.id] = best;
    }

    final rebuilt = <Province>[];
    final displacedCapitalUnits = <({int source, GameUnit unit})>[];
    for (var i = 0; i < components.length; i++) {
      final component = components[i];
      final inherited =
          component.tiles
              .map((index) => oldByTile[index])
              .whereType<Province>()
              .where((province) => successorByOld[province.id] == i)
              .toSet()
              .toList()
            ..sort((a, b) {
              final sizeOrder = b.tiles.length.compareTo(a.tiles.length);
              return sizeOrder != 0 ? sizeOrder : a.id.compareTo(b.id);
            });
      final survivor = inherited.isEmpty ? null : inherited.first;
      final id = survivor?.id ?? state.nextProvinceId++;
      final money = inherited.fold<int>(
        0,
        (sum, province) => sum + province.money,
      );
      final towns = component.tiles
          .where((index) => state.hexes[index].object == TileObject.town)
          .toList();
      final survivorCapital = survivor?.capital;
      final capital = component.navalCapital
          ? survivorCapital != null && component.tiles.contains(survivorCapital)
                ? survivorCapital
                : _pickNewCapital(component.tiles, id)
          : survivorCapital != null && towns.contains(survivorCapital)
          ? survivorCapital
          : towns.isNotEmpty
          ? _strongestExistingCapital(towns, component.owner, oldByTile)
          : _pickNewCapital(component.tiles, id);
      if (!component.navalCapital) {
        for (final extra in towns.where((index) => index != capital)) {
          state.hexes[extra].object = TileObject.none;
        }
        final capitalTile = state.hexes[capital];
        // A city is a piece in classic Antiyoy: when no free hex exists, the
        // weakest replaceable piece is removed before the city is spawned.
        capitalTile
          ..object = TileObject.town
          ..treeBorn = -1;
        final capitalUnit = capitalTile.unit;
        if (capitalUnit != null &&
            (preserveNewCapitalUnits ||
                unitOwnerAt(capital) != component.owner)) {
          displacedCapitalUnits.add((source: capital, unit: capitalUnit));
        }
        capitalTile.unit = null;
      }
      rebuilt.add(
        Province(
          id: id,
          owner: component.owner,
          tiles: component.tiles,
          money: money,
          capital: capital,
          navalCapital: component.navalCapital,
          navalFounded: component.navalFounded,
        ),
      );
    }
    final successorIdByOld = <int, int>{
      for (final entry in successorByOld.entries)
        if (entry.value >= 0 && entry.value < rebuilt.length)
          entry.key: rebuilt[entry.value].id,
    };
    state.provinces = rebuilt;
    for (final displaced in displacedCapitalUnits) {
      _repatriatePeaceConferenceUnit(displaced.source, displaced.unit);
    }
    _refreshNavalSupportLinks();
    final provinceTiles = rebuilt.expand((province) => province.tiles).toSet();
    for (final tile in state.hexes) {
      if (tile.owner < 0 || provinceTiles.contains(tile.index)) continue;
      if (tile.object == TileObject.town ||
          tile.object == TileObject.port1 ||
          tile.object == TileObject.port2) {
        tile.unit = null;
        _turnIntoTree(tile);
      } else if (tile.object == TileObject.farm) {
        tile.object = TileObject.none;
      }
    }
    final rebuiltById = {for (final province in rebuilt) province.id: province};
    final rebuiltByTile = {
      for (final province in rebuilt)
        for (final index in province.tiles) index: province,
    };
    Province? deterministicHome(int owner, Iterable<int> coastTiles) {
      final ownerProvinces =
          rebuilt.where((province) => province.owner == owner).toList()
            ..sort((a, b) {
              final coastalA = a.tiles.any(coastTiles.contains) ? 1 : 0;
              final coastalB = b.tiles.any(coastTiles.contains) ? 1 : 0;
              final coastalOrder = coastalB.compareTo(coastalA);
              if (coastalOrder != 0) return coastalOrder;
              final sizeOrder = b.tiles.length.compareTo(a.tiles.length);
              return sizeOrder != 0 ? sizeOrder : a.id.compareTo(b.id);
            });
      return ownerProvinces.firstOrNull;
    }

    for (final tile in state.hexes) {
      final unit = tile.unit;
      if (unit == null) continue;
      final owner = unit.owner >= 0 ? unit.owner : tile.owner;
      unit.owner = owner;
      final inheritedId = successorIdByOld[unit.homeProvinceId];
      final inherited = rebuiltById[inheritedId];
      final current = rebuiltById[unit.homeProvinceId];
      final sovereignHome = tile.coalitionClaim == null && tile.owner == owner
          ? rebuiltByTile[tile.index]
          : null;
      final home = sovereignHome?.owner == owner
          ? sovereignHome
          : inherited?.owner == owner
          ? inherited
          : current?.owner == owner
          ? current
          : deterministicHome(owner, const <int>[]);
      if (home == null) {
        tile.unit = null;
        if (tile.coalitionClaim == null && tile.object == TileObject.none) {
          tile
            ..object = TileObject.grave
            ..treeBorn = state.round;
        }
      } else {
        unit.homeProvinceId = home.id;
      }
    }

    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null) continue;
      final inheritedId = successorIdByOld[boat.homeProvinceId];
      final inherited = rebuiltById[inheritedId];
      if (inherited != null && inherited.owner == boat.owner) {
        boat.homeProvinceId = inherited.id;
        _normalizeCargoFunding(boat);
        continue;
      }
      final current = rebuiltById[boat.homeProvinceId];
      if (current != null && current.owner == boat.owner) {
        _normalizeCargoFunding(boat);
        continue;
      }
      final fallback = deterministicHome(boat.owner, cell.coastTiles);
      if (fallback == null) {
        _sinkBoatIntoSeaMint(cell);
      } else {
        boat.homeProvinceId = fallback.id;
        _normalizeCargoFunding(boat);
      }
    }
    for (final cell in state.waterCells) {
      final fort = cell.seaFort;
      if (fort == null) continue;
      final inheritedId = successorIdByOld[fort.homeProvinceId];
      final inherited = rebuiltById[inheritedId];
      if (inherited != null && inherited.owner == fort.owner) {
        fort.homeProvinceId = inherited.id;
        continue;
      }
      final current = rebuiltById[fort.homeProvinceId];
      if (current != null && current.owner == fort.owner) continue;
      final fallback = deterministicHome(fort.owner, cell.coastTiles);
      if (fallback == null) {
        cell.seaFort = null;
      } else {
        fort.homeProvinceId = fallback.id;
      }
    }
    _refreshNavalSupportLinks();
  }

  bool _isNavalCapitalComponent(int owner, List<int> componentTiles) {
    if (componentTiles.any((index) => state.hexes[index].unit == null)) {
      return false;
    }
    final component = componentTiles.toSet();
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat?.owner != owner) continue;
      final supported = boat!.supportedTiles.toSet();
      if (supported.containsAll(component) && _isValidSupplyChain(cell, boat)) {
        return true;
      }
    }
    return false;
  }

  bool _isSupportedBridgehead(int tileIndex, int owner) {
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat?.owner == owner &&
          boat!.supportedTiles.contains(tileIndex) &&
          _isValidSupplyChain(cell, boat)) {
        return true;
      }
    }
    return false;
  }

  int _navalSupportForProvince(Province province) {
    if (!province.navalCapital) return 0;
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null ||
          boat.owner != province.owner ||
          !_isValidSupplyChain(cell, boat)) {
        continue;
      }
      final supported = boat.supportedTiles.toSet();
      if (!supported.containsAll(province.tiles)) continue;
      final linkedTiles = supported.where((tileIndex) {
        final linkedProvince = provinceAt(tileIndex);
        return linkedProvince?.owner == boat.owner &&
            linkedProvince?.navalCapital == true;
      }).toList()..sort();
      if (linkedTiles.isEmpty) continue;

      // A boat is one shared economic connection even when its marines form
      // several disconnected bridgeheads. Split the single +4/+10 transfer
      // across every linked landing tile instead of giving all of it to the
      // first province and bankrupting the later landings. The quotient plus
      // deterministic remainder preserves the exact boat-wide total.
      final capacity = boatCapacity(boat.level);
      final baseShare = capacity ~/ linkedTiles.length;
      final remainder = capacity % linkedTiles.length;
      final provinceTiles = province.tiles.toSet();
      var support = 0;
      for (var i = 0; i < linkedTiles.length; i++) {
        if (provinceTiles.contains(linkedTiles[i])) {
          support += baseShare + (i < remainder ? 1 : 0);
        }
      }
      return support;
    }
    return 0;
  }

  Province? _primaryNavalProvinceForBoat(WaterCell cell, GameBoat boat) {
    if (!_isValidSupplyChain(cell, boat)) return null;
    final supported = boat.supportedTiles.toSet();
    final provinces =
        state.provinces
            .where(
              (province) =>
                  province.navalCapital &&
                  province.owner == boat.owner &&
                  supported.containsAll(province.tiles),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return provinces.isEmpty ? null : provinces.first;
  }

  void _materializeNavalCapitalsForBoat(GameBoat boat) {
    if (boat.supportedTiles.isEmpty) return;
    final supported = boat.supportedTiles.toSet();
    final orphanedProvinceIds = <int>{};
    for (final province in state.provinces.toList()) {
      if (!province.navalCapital ||
          province.owner != boat.owner ||
          !province.tiles.any(supported.contains)) {
        continue;
      }
      if (!_materializeNavalProvince(province)) {
        orphanedProvinceIds.add(province.id);
      }
    }
    state.provinces.removeWhere(
      (province) => orphanedProvinceIds.contains(province.id),
    );
    boat.supportedTiles.clear();
  }

  void _materializeOrphanedNavalCapitals() {
    final orphanedProvinceIds = <int>{};
    for (final province in state.provinces.toList()) {
      if (!province.navalCapital) continue;
      final supported = state.waterCells.any((cell) {
        final boat = cell.boat;
        return boat?.owner == province.owner &&
            boat!.supportedTiles.toSet().containsAll(province.tiles) &&
            _isValidSupplyChain(cell, boat);
      });
      if (!supported && !_materializeNavalProvince(province)) {
        orphanedProvinceIds.add(province.id);
      }
    }
    state.provinces.removeWhere(
      (province) => orphanedProvinceIds.contains(province.id),
    );
  }

  /// Ends temporary naval-capital status. Returns whether enough connected
  /// land remains to form a permanent city.
  bool _materializeNavalProvince(Province province) {
    if (province.tiles.length < 2) {
      province
        ..navalCapital = false
        ..navalFounded = false;
      return false;
    }
    final capital = _pickNewCapital(province.tiles, province.id);
    province
      ..capital = capital
      ..navalCapital = false
      ..navalFounded = true;
    state.hexes[capital]
      ..object = TileObject.town
      ..unit = null
      ..treeBorn = -1;
    return true;
  }

  void _refreshNavalSupportLinks() {
    for (final cell in state.waterCells) {
      final boat = cell.boat;
      if (boat == null || boat.supportedTiles.isEmpty) continue;
      boat.supportedTiles.removeWhere((index) {
        if (index < 0 || index >= state.hexes.length) return true;
        final tile = state.hexes[index];
        if (!tile.active ||
            tile.owner != boat.owner ||
            tile.coalitionClaim != null) {
          return true;
        }
        final province = provinceAt(index);
        return province != null &&
            province.owner == boat.owner &&
            !province.navalCapital;
      });
      if (boat.supportedTiles.isNotEmpty) {
        final reachable = _reachableSupplyTiles(cell, boat);
        boat.supportedTiles.removeWhere((index) => !reachable.contains(index));
      }
    }
  }

  bool _isValidSupplyChain(WaterCell cell, GameBoat boat) {
    final supported = boat.supportedTiles;
    return supported.isNotEmpty &&
        _reachableSupplyTiles(cell, boat).length == supported.toSet().length;
  }

  Set<int> _reachableSupplyTiles(WaterCell cell, GameBoat boat) {
    if (!cell.navigable) return {};
    final supportedSet = boat.supportedTiles
        .where(
          (index) =>
              index >= 0 &&
              index < state.hexes.length &&
              state.hexes[index].active &&
              state.hexes[index].owner == boat.owner &&
              state.hexes[index].coalitionClaim == null,
        )
        .toSet();
    final anchors = supportedSet.where(cell.coastTiles.contains).toList();
    if (anchors.isEmpty) return {};
    // Every coast anchor is supplied directly by the boat. Inland bridgehead
    // tiles must connect to an anchor and stay inside the normal four-step
    // unit movement radius, so extra cargo can land without creating an
    // unlimited supply chain.
    final visited = anchors.toSet();
    final queue = <int>[...anchors];
    final distance = <int, int>{for (final anchor in anchors) anchor: 1};
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final nextDistance = distance[queue[cursor]]! + 1;
      if (nextDistance > mod.rules.unitMoveLimit) continue;
      for (final neighbor in state.hexes[queue[cursor]].neighbors) {
        if (supportedSet.contains(neighbor) && visited.add(neighbor)) {
          distance[neighbor] = nextDistance;
          queue.add(neighbor);
        }
      }
    }
    return visited;
  }

  int _strongestExistingCapital(
    List<int> towns,
    int owner,
    Map<int, Province> oldByTile,
  ) {
    final ordered = [...towns]
      ..sort((a, b) {
        final oldSizeA = oldByTile[a]?.tiles.length ?? 0;
        final oldSizeB = oldByTile[b]?.tiles.length ?? 0;
        final sizeOrder = oldSizeB.compareTo(oldSizeA);
        if (sizeOrder != 0) return sizeOrder;
        final farmsA = state.hexes[a].neighbors
            .where(
              (index) =>
                  state.hexes[index].owner == owner &&
                  state.hexes[index].object == TileObject.farm,
            )
            .length;
        final farmsB = state.hexes[b].neighbors
            .where(
              (index) =>
                  state.hexes[index].owner == owner &&
                  state.hexes[index].object == TileObject.farm,
            )
            .length;
        final farmOrder = farmsB.compareTo(farmsA);
        return farmOrder != 0 ? farmOrder : a.compareTo(b);
      });
    return ordered.first;
  }

  int _pickNewCapital(List<int> tiles, int provinceId) {
    var bestPriority = 1 << 30;
    final candidates = <int>[];
    for (final index in tiles) {
      final priority = _capitalReplacementPriority(state.hexes[index]);
      if (priority < bestPriority) {
        bestPriority = priority;
        candidates
          ..clear()
          ..add(index);
      } else if (priority == bestPriority) {
        candidates.add(index);
      }
    }
    candidates.sort();
    final pick = (117 + 119 * tiles.length + provinceId).abs();
    return candidates[pick % candidates.length];
  }

  int _capitalReplacementPriority(HexTile tile) {
    if (tile.object == TileObject.none && tile.unit == null) return 0;
    if (tile.unit != null) return 10 + tile.unit!.strength;
    return switch (tile.object) {
      TileObject.pine || TileObject.palm || TileObject.grave => 5,
      TileObject.farm => 20,
      TileObject.port1 => 30,
      TileObject.artillery1 => 35,
      TileObject.tower => 40,
      TileObject.port2 => 45,
      TileObject.artillery2 => 47,
      TileObject.strongTower => 50,
      TileObject.artillery3 => 55,
      TileObject.town => 60,
      TileObject.none => 0,
    };
  }

  Province? _provinceById(int id) {
    for (final province in state.provinces) {
      if (province.id == id) return province;
    }
    return null;
  }

  bool _isAlive(int player) => state.provinces.any((p) => p.owner == player);

  void _updateWinner({bool commit = false}) {
    _settleCampaignsWithDefeatedSide();
    // A former owner may legally regain land when a conference resolves or
    // times out. Declaring a winner first would freeze endTurn and make that
    // restoration unreachable.
    if (state.peaceConferences.isNotEmpty) {
      state.winner = null;
      return;
    }
    final alive = <int>[];
    for (var player = 0; player < state.config.playerCount; player++) {
      if (_isAlive(player)) alive.add(player);
    }
    if (alive.length == 1 && commit) {
      state.winner = alive.single;
      return;
    }
    state.winner = null;
  }
}
