import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../game/models.dart';
import '../modding/game_mod.dart';

/// Persistent storage for the real map-editor draft.
///
/// The editor deliberately stores a complete [GameState], not a screenshot or
/// a seed-only placeholder. That makes every ownership, terrain, object and
/// unit edit survive an application restart and keeps exported maps portable.
class EditorRepository {
  const EditorRepository();

  static const _draftKey = 'antiyoy.editor.draft.v1';

  Future<bool> hasDraft() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_draftKey);
  }

  Future<GameState?> loadDraft({GameRules? rules}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_draftKey);
    if (raw == null) return null;
    return decode(raw, rules: rules);
  }

  Future<void> saveDraft(GameState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_draftKey, encode(state));
  }

  Future<void> clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey);
  }

  Future<String?> exportRaw({GameRules? rules}) async {
    final state = await loadDraft(rules: rules);
    return state == null ? null : encode(state);
  }

  Future<bool> importRaw(String raw, {GameRules? rules}) async {
    final state = decode(raw, rules: rules);
    if (state == null) return false;
    await saveDraft(state);
    return true;
  }

  String encode(GameState state) => jsonEncode({
    'format': 'antiyoy-self-map',
    'version': 1,
    'state': state.toJson(),
  });

  GameState? decode(String raw, {GameRules? rules}) {
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return null;
      final data = root.cast<String, dynamic>();
      if (data['format'] != 'antiyoy-self-map' ||
          data['version'] is! int ||
          data['version'] != 1) {
        return null;
      }
      final stateJson = data['state'];
      if (stateJson is! Map) return null;
      final strictStateJson = stateJson.cast<String, dynamic>();
      return decodeStateJson(strictStateJson, rules: rules);
    } on Object {
      return null;
    }
  }

  /// Strictly decodes a bare [GameState] payload such as a progress-transfer
  /// save section. This prevents the tolerant legacy decoder from silently
  /// repairing malformed clipboard data before validation sees it.
  static GameState? decodeStateJson(
    Map<String, dynamic> stateJson, {
    String? expectedModId,
    bool requirePlayable = false,
    GameRules? rules,
  }) {
    try {
      if (!_isValidRawStateJson(stateJson)) return null;
      final state = GameState.fromJson(stateJson);
      return isValidState(
            state,
            expectedModId: expectedModId,
            requirePlayable: requirePlayable,
            rules: rules,
          )
          ? state
          : null;
    } on Object {
      return null;
    }
  }

  /// Performs semantic validation after JSON decoding, before imported state
  /// is allowed to reach the simulation. The regular save decoder is tolerant
  /// for backwards compatibility; the editor import boundary must be strict.
  static bool isValidState(
    GameState state, {
    String? expectedModId,
    bool requirePlayable = false,
    GameRules? rules,
  }) {
    final players = state.config.playerCount;
    if (state.width <= 0 ||
        state.height <= 0 ||
        state.hexes.length != state.width * state.height ||
        players < 2 ||
        players > 15 ||
        state.config.humanCount < 0 ||
        state.config.humanCount > players ||
        state.config.treePercent < 0 ||
        state.config.treePercent > 100 ||
        state.config.startingProvinceCount < 0 ||
        state.config.startingProvinceCount > 3 ||
        state.modId.trim().isEmpty ||
        (expectedModId != null && state.modId != expectedModId) ||
        state.turn < 0 ||
        state.turn >= players ||
        state.round < 0 ||
        state.nextProvinceId < 0 ||
        state.nextNavalEntityId <= 0 ||
        state.nextWarCampaignId <= 0 ||
        state.nextPeaceConferenceId <= 0 ||
        (state.winner != null &&
            (state.winner! < 0 || state.winner! >= players))) {
      return false;
    }

    bool validTileIndex(int index) => index >= 0 && index < state.hexes.length;
    bool validWaterIndex(int index) =>
        index >= 0 && index < state.waterCells.length;
    bool validOwner(int owner) => owner >= 0 && owner < players;
    bool validUnit(GameUnit unit) =>
        unit.strength >= 1 &&
        unit.strength <= 4 &&
        unit.owner >= -1 &&
        unit.owner < players &&
        unit.homeProvinceId >= -1 &&
        unit.transitAllies.toSet().length == unit.transitAllies.length &&
        unit.transitAllies.every(validOwner) &&
        (unit.owner < 0 || !unit.transitAllies.contains(unit.owner));

    final campaignById = <int, WarCampaign>{};
    for (final campaign in state.campaigns) {
      final sideA = campaign.sideA.toSet();
      final sideB = campaign.sideB.toSet();
      if (campaign.id <= 0 ||
          campaignById.putIfAbsent(campaign.id, () => campaign) != campaign ||
          campaign.startedRound < 0 ||
          campaign.startedRound > state.round ||
          campaign.sideA.isEmpty ||
          campaign.sideB.isEmpty ||
          sideA.length != campaign.sideA.length ||
          sideB.length != campaign.sideB.length ||
          campaign.sideA.any((owner) => !validOwner(owner)) ||
          campaign.sideB.any((owner) => !validOwner(owner)) ||
          sideA.intersection(sideB).isNotEmpty ||
          !sideA.contains(campaign.attackerLeader) ||
          !sideB.contains(campaign.defenderLeader)) {
        return false;
      }
    }
    if (campaignById.isNotEmpty &&
        state.nextWarCampaignId <=
            campaignById.keys.reduce(
              (first, second) => first > second ? first : second,
            )) {
      return false;
    }

    final conferenceById = <int, PeaceConference>{};
    final conferenceClaimTiles = <int>{};
    for (final conference in state.peaceConferences) {
      final participants = conference.participants.toSet();
      final claimTiles = conference.claimTiles.toSet();
      final tileValueKeys = conference.tileValues.keys.toSet();
      final contributionOwners = conference.contributionPoints.keys.toSet();
      final accepted = conference.acceptedBy.toSet();
      if (conference.id <= 0 ||
          conferenceById.putIfAbsent(conference.id, () => conference) !=
              conference ||
          conference.sourceCampaignId <= 0 ||
          !validOwner(conference.originalOwner) ||
          conference.claimTiles.isEmpty ||
          claimTiles.length != conference.claimTiles.length ||
          conference.claimTiles.any(
            (index) =>
                !validTileIndex(index) || !conferenceClaimTiles.add(index),
          ) ||
          conference.participants.length < 2 ||
          participants.length != conference.participants.length ||
          conference.participants.any((owner) => !validOwner(owner)) ||
          participants.contains(conference.originalOwner) ||
          conference.openedRound < 0 ||
          conference.openedRound > state.round ||
          conference.deadlineRound != conference.openedRound + 5 ||
          conference.revision < 0 ||
          tileValueKeys.length != claimTiles.length ||
          !tileValueKeys.containsAll(claimTiles) ||
          conference.tileValues.values.any((value) => value <= 0) ||
          contributionOwners.length != participants.length ||
          !contributionOwners.containsAll(participants) ||
          conference.contributionPoints.values.any((value) => value <= 0) ||
          conference.tileValues.values.fold<int>(
                0,
                (sum, value) => sum + value,
              ) !=
              conference.contributionPoints.values.fold<int>(
                0,
                (sum, value) => sum + value,
              ) ||
          conference.proposer < -1 ||
          (conference.proposer >= 0 &&
              !participants.contains(conference.proposer)) ||
          accepted.length != conference.acceptedBy.length ||
          conference.acceptedBy.any((owner) => !participants.contains(owner)) ||
          (conference.proposer < 0 &&
              (conference.allocations.isNotEmpty ||
                  conference.acceptedBy.isNotEmpty)) ||
          (conference.proposer >= 0 &&
              (conference.revision <= 0 ||
                  !accepted.contains(conference.proposer)))) {
        return false;
      }

      final allocated = <int>{};
      for (final entry in conference.allocations.entries) {
        if (!participants.contains(entry.key) ||
            entry.value.toSet().length != entry.value.length ||
            entry.value.any(
              (index) => !claimTiles.contains(index) || !allocated.add(index),
            )) {
          return false;
        }
        final assignedValue = entry.value.fold<int>(
          0,
          (sum, index) => sum + (conference.tileValues[index] ?? 0),
        );
        if (assignedValue > (conference.contributionPoints[entry.key] ?? 0)) {
          return false;
        }
      }
    }
    if (conferenceById.isNotEmpty &&
        state.nextPeaceConferenceId <=
            conferenceById.keys.reduce(
              (first, second) => first > second ? first : second,
            )) {
      return false;
    }

    bool validCoalitionClaim(HexTile tile, CoalitionClaim claim) {
      if (!tile.active ||
          tile.owner != claim.captor ||
          tile.object != TileObject.none ||
          !validOwner(claim.originalOwner) ||
          !validOwner(claim.captor) ||
          claim.originalOwner == claim.captor ||
          claim.members.length < 2 ||
          claim.members.toSet().length != claim.members.length ||
          !claim.members.contains(claim.captor) ||
          claim.members.any((owner) => !validOwner(owner)) ||
          claim.contributors.isEmpty ||
          claim.contributors.toSet().length != claim.contributors.length ||
          !claim.contributors.contains(claim.captor) ||
          claim.contributors.any(
            (owner) => !validOwner(owner) || !claim.members.contains(owner),
          ) ||
          claim.settlementValue <= 0 ||
          claim.conferenceId < -1) {
        return false;
      }

      if (claim.conferenceId >= 0) {
        final conference = conferenceById[claim.conferenceId];
        return conference != null &&
            claim.campaignId == conference.sourceCampaignId &&
            claim.originalOwner == conference.originalOwner &&
            conference.claimTiles.contains(tile.index) &&
            conference.participants.contains(claim.captor) &&
            claim.contributors.every(conference.participants.contains) &&
            conference.tileValues[tile.index] == claim.settlementValue;
      }

      final campaign = campaignById[claim.campaignId];
      if (campaign == null) return false;
      final captorSide = campaign.sideA.contains(claim.captor)
          ? campaign.sideA
          : campaign.sideB.contains(claim.captor)
          ? campaign.sideB
          : const <int>[];
      final opposingSide = identical(captorSide, campaign.sideA)
          ? campaign.sideB
          : campaign.sideA;
      return captorSide.isNotEmpty &&
          opposingSide.contains(claim.originalOwner) &&
          claim.members.every(captorSide.contains) &&
          claim.contributors.every(captorSide.contains);
    }

    int artilleryLevel(TileObject object) => switch (object) {
      TileObject.artillery1 => 1,
      TileObject.artillery2 => 2,
      TileObject.artillery3 => 3,
      _ => 0,
    };
    int? artilleryCapacity(int level) {
      if (rules != null && rules.artilleryAmmoCapacity.length > level) {
        return rules.artilleryAmmoCapacity[level];
      }
      if (state.modId == 'classic_steppe') {
        return const [0, 2, 4, 7][level];
      }
      return null;
    }

    int? boatCapacity(int level) {
      if (rules != null) {
        return level == 1 ? rules.boat1Capacity : rules.boat2Capacity;
      }
      if (state.modId == 'classic_steppe') return level == 1 ? 4 : 10;
      return null;
    }

    for (var index = 0; index < state.hexes.length; index++) {
      final tile = state.hexes[index];
      final level = artilleryLevel(tile.object);
      final ammoCapacity = level == 0 ? 0 : artilleryCapacity(level);
      if (tile.index != index ||
          (tile.active && !tile.inWorld) ||
          (!tile.active && tile.owner != -1) ||
          tile.owner < -1 ||
          tile.owner >= players ||
          tile.artilleryAmmo < 0 ||
          tile.artilleryCooldown < 0 ||
          (level == 0 &&
              (tile.artilleryAmmo != 0 || tile.artilleryCooldown != 0)) ||
          (level > 0 && tile.artilleryCooldown > 1) ||
          (ammoCapacity != null && tile.artilleryAmmo > ammoCapacity) ||
          tile.neighbors.toSet().length != tile.neighbors.length ||
          tile.neighbors.contains(index) ||
          tile.neighbors.any((neighbor) => !validTileIndex(neighbor)) ||
          (tile.coalitionClaim != null &&
              !validCoalitionClaim(tile, tile.coalitionClaim!)) ||
          (tile.unit != null &&
              (!validUnit(tile.unit!) ||
                  (tile.object != TileObject.none &&
                      !(tile.unit!.owner >= 0 &&
                          tile.unit!.owner != tile.owner &&
                          (tile.hasTree ||
                              tile.object == TileObject.grave)))))) {
        return false;
      }
    }
    for (final conference in state.peaceConferences) {
      for (final index in conference.claimTiles) {
        final claim = state.hexes[index].coalitionClaim;
        if (claim == null ||
            claim.conferenceId != conference.id ||
            claim.campaignId != conference.sourceCampaignId ||
            claim.originalOwner != conference.originalOwner) {
          return false;
        }
      }
    }

    final provinceIds = <int>{};
    final provinceOwners = <int, int>{};
    final provinceTiles = <int>{};
    final provinceByTile = <int, Province>{};
    for (final province in state.provinces) {
      if (province.id < 0 ||
          !provinceIds.add(province.id) ||
          !validOwner(province.owner) ||
          province.tiles.isEmpty ||
          province.money < -1000000000 ||
          !province.tiles.contains(province.capital) ||
          province.tiles.any(
            (index) =>
                !validTileIndex(index) ||
                !provinceTiles.add(index) ||
                !state.hexes[index].active ||
                state.hexes[index].owner != province.owner,
          )) {
        return false;
      }
      final component = <int>{province.tiles.first};
      final queue = <int>[province.tiles.first];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        for (final neighbor in state.hexes[queue[cursor]].neighbors) {
          if (province.tiles.contains(neighbor) && component.add(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      if (component.length != province.tiles.length) return false;
      if (!province.navalCapital &&
          (province.tiles.length < 2 ||
              state.hexes[province.capital].object != TileObject.town)) {
        return false;
      }
      for (final index in province.tiles) {
        provinceByTile[index] = province;
      }
      provinceOwners[province.id] = province.owner;
    }
    if (provinceIds.isNotEmpty &&
        state.nextProvinceId <= provinceIds.reduce((a, b) => a > b ? a : b)) {
      return false;
    }

    bool validUnitOrigin(GameUnit unit) {
      if (unit.owner < 0 || unit.homeProvinceId < 0) {
        return unit.owner == -1 && unit.homeProvinceId == -1;
      }
      return provinceOwners[unit.homeProvinceId] == unit.owner;
    }

    final waterTiles = <int>{};
    final navalEntityIds = <int>{};
    var largestNavalEntityId = 0;
    for (var index = 0; index < state.waterCells.length; index++) {
      final cell = state.waterCells[index];
      final boat = cell.boat;
      final fort = cell.seaFort;
      if (cell.index != index ||
          cell.tiles.isEmpty ||
          cell.tiles.toSet().length != cell.tiles.length ||
          cell.tiles.any(
            (tile) =>
                !validTileIndex(tile) ||
                !waterTiles.add(tile) ||
                state.hexes[tile].active ||
                !state.hexes[tile].inWorld,
          ) ||
          cell.neighbors.toSet().length != cell.neighbors.length ||
          cell.neighbors.contains(index) ||
          cell.neighbors.any((neighbor) => !validWaterIndex(neighbor)) ||
          cell.coastTiles.toSet().length != cell.coastTiles.length ||
          cell.coastTiles.any(
            (tile) => !validTileIndex(tile) || !state.hexes[tile].active,
          ) ||
          (!cell.navigable && (boat != null || fort != null || cell.seaMint)) ||
          (boat != null && fort != null) ||
          (cell.seaMint && (boat != null || fort != null))) {
        return false;
      }
      final capacity = boat == null ? null : boatCapacity(boat.level);
      if (boat != null &&
          (boat.id <= 0 ||
              !navalEntityIds.add(boat.id) ||
              !validOwner(boat.owner) ||
              boat.level < 1 ||
              boat.level > 2 ||
              boat.damage < 0 ||
              boat.damage >= boat.level ||
              boat.supportedTiles.toSet().length !=
                  boat.supportedTiles.length ||
              (capacity != null && boat.usedCapacity > capacity) ||
              provinceOwners[boat.homeProvinceId] != boat.owner ||
              boat.supportedTiles.any(
                (tile) =>
                    !validTileIndex(tile) ||
                    !state.hexes[tile].active ||
                    state.hexes[tile].owner != boat.owner,
              ) ||
              boat.cargo.any(
                (unit) => !validUnit(unit) || !validUnitOrigin(unit),
              ))) {
        return false;
      }
      if (boat != null) {
        if (boat.id > largestNavalEntityId) largestNavalEntityId = boat.id;
      }
      if (fort != null &&
          (fort.id <= 0 ||
              !navalEntityIds.add(fort.id) ||
              !validOwner(fort.owner) ||
              provinceOwners[fort.homeProvinceId] != fort.owner)) {
        return false;
      }
      if (fort != null) {
        if (fort.id > largestNavalEntityId) largestNavalEntityId = fort.id;
      }
    }
    if (state.nextNavalEntityId <= largestNavalEntityId) return false;
    final expectedWaterTiles = state.hexes
        .where((tile) => tile.inWorld && !tile.active)
        .map((tile) => tile.index)
        .toSet();
    // Schema 7 and older land-only saves had no packed water graph. They are
    // still safe to accept because GameController/Editor regenerates that graph
    // before simulation; a partially supplied graph, however, is corruption.
    if (state.waterCells.isNotEmpty &&
        (waterTiles.length != expectedWaterTiles.length ||
            !waterTiles.containsAll(expectedWaterTiles))) {
      return false;
    }

    bool ownerDependentObject(TileObject object) => switch (object) {
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
    bool requiresNavigableCoast(TileObject object) => switch (object) {
      TileObject.port1 ||
      TileObject.port2 ||
      TileObject.artillery1 ||
      TileObject.artillery2 ||
      TileObject.artillery3 => true,
      _ => false,
    };
    for (final tile in state.hexes) {
      final province = provinceByTile[tile.index];
      if ((tile.unit != null && !validUnitOrigin(tile.unit!)) ||
          (((tile.unit != null && tile.coalitionClaim == null) ||
                  ownerDependentObject(tile.object)) &&
              (province == null || province.owner != tile.owner))) {
        return false;
      }
      if (tile.object == TileObject.town && province?.capital != tile.index) {
        return false;
      }
      if (state.waterCells.isNotEmpty &&
          requiresNavigableCoast(tile.object) &&
          !state.waterCells.any(
            (cell) => cell.navigable && cell.coastTiles.contains(tile.index),
          )) {
        return false;
      }
    }

    bool boatSuppliesProvince(Province province) {
      if (!province.navalCapital ||
          province.tiles.any((index) => state.hexes[index].unit == null)) {
        return false;
      }
      final provinceSet = province.tiles.toSet();
      final moveLimit =
          rules?.unitMoveLimit ?? (state.modId == 'classic_steppe' ? 4 : null);
      for (final cell in state.waterCells) {
        final boat = cell.boat;
        if (!cell.navigable || boat?.owner != province.owner) continue;
        final supported = boat!.supportedTiles.toSet();
        if (!supported.containsAll(provinceSet)) continue;
        final anchors = supported.where(cell.coastTiles.contains).toList();
        if (anchors.isEmpty) continue;
        final visited = anchors.toSet();
        final queue = <int>[...anchors];
        final distance = <int, int>{for (final anchor in anchors) anchor: 1};
        for (var cursor = 0; cursor < queue.length; cursor++) {
          final nextDistance = distance[queue[cursor]]! + 1;
          if (moveLimit != null && nextDistance > moveLimit) continue;
          for (final neighbor in state.hexes[queue[cursor]].neighbors) {
            if (supported.contains(neighbor) && visited.add(neighbor)) {
              distance[neighbor] = nextDistance;
              queue.add(neighbor);
            }
          }
        }
        if (visited.length == supported.length) return true;
      }
      return false;
    }

    final seenOwned = <int>{};
    for (final tile in state.hexes) {
      if (!tile.active ||
          tile.owner < 0 ||
          tile.coalitionClaim != null ||
          !seenOwned.add(tile.index)) {
        continue;
      }
      final component = <int>{tile.index};
      final queue = <int>[tile.index];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        for (final neighbor in state.hexes[queue[cursor]].neighbors) {
          final candidate = state.hexes[neighbor];
          if (candidate.active &&
              candidate.owner == tile.owner &&
              candidate.coalitionClaim == null &&
              seenOwned.add(neighbor)) {
            component.add(neighbor);
            queue.add(neighbor);
          }
        }
      }
      final componentProvinces = component
          .map((index) => provinceByTile[index])
          .whereType<Province>()
          .toSet();
      if (component.length >= 2) {
        if (componentProvinces.length != 1 ||
            component.any((index) => provinceByTile[index] == null)) {
          return false;
        }
      } else if (componentProvinces.isEmpty) {
        continue;
      }
      if (componentProvinces.length != 1) return false;
      final province = componentProvinces.single;
      if (province.owner != tile.owner ||
          province.tiles.toSet().length != component.length ||
          !province.tiles.toSet().containsAll(component) ||
          (province.navalCapital && !boatSuppliesProvince(province)) ||
          (!province.navalCapital && component.length < 2)) {
        return false;
      }
    }

    bool validSquareMatrix(List<List<Object?>> matrix) =>
        matrix.length == players &&
        matrix.every((row) => row.length == players);
    if (!validSquareMatrix(
          state.diplomacyRelations
              .map<List<Object?>>((row) => row.cast<Object?>())
              .toList(),
        ) ||
        !validSquareMatrix(
          state.diplomacyAllianceTurns
              .map<List<Object?>>((row) => row.cast<Object?>())
              .toList(),
        ) ||
        !validSquareMatrix(
          state.diplomacyWarCooldowns
              .map<List<Object?>>((row) => row.cast<Object?>())
              .toList(),
        ) ||
        !validSquareMatrix(
          state.diplomacyBlackMarks
              .map<List<Object?>>((row) => row.cast<Object?>())
              .toList(),
        ) ||
        !validSquareMatrix(
          state.diplomacyBlackMarkCooldowns
              .map<List<Object?>>((row) => row.cast<Object?>())
              .toList(),
        ) ||
        !validSquareMatrix(
          state.diplomacyDebts
              .map<List<Object?>>((row) => row.cast<Object?>())
              .toList(),
        ) ||
        state.diplomacyTraitorTurns.length != players) {
      return false;
    }
    if (state.diplomacyAllianceTurns
            .expand((row) => row)
            .any((value) => value < 0) ||
        state.diplomacyWarCooldowns
            .expand((row) => row)
            .any((value) => value < 0) ||
        state.diplomacyBlackMarkCooldowns
            .expand((row) => row)
            .any((value) => value < 0) ||
        state.diplomacyDebts.expand((row) => row).any((value) => value < 0) ||
        state.diplomacyTraitorTurns.any((value) => value < 0) ||
        state.diplomacySubsidies.any(
          (subsidy) =>
              !validOwner(subsidy.payer) ||
              !validOwner(subsidy.receiver) ||
              subsidy.payer == subsidy.receiver ||
              subsidy.amount <= 0 ||
              subsidy.turnsLeft <= 0,
        ) ||
        state.diplomacyProposals.any(
          (proposal) =>
              !validOwner(proposal.from) ||
              !validOwner(proposal.to) ||
              proposal.from == proposal.to ||
              proposal.createdRound < 0 ||
              proposal.rationale.length > 400 ||
              !_validOffer(proposal.fromOffer, state.hexes.length, players) ||
              !_validOffer(proposal.toOffer, state.hexes.length, players) ||
              proposal.effectiveTerms.length > 3 ||
              proposal.effectiveTerms.any(
                (term) => !_validOffer(term.offer, state.hexes.length, players),
              ),
        ) ||
        state.diplomacyMessages.any(
          (message) =>
              !validOwner(message.from) ||
              !validOwner(message.to) ||
              message.from == message.to ||
              message.text.trim().isEmpty ||
              message.text.length > 400 ||
              message.createdRound < 0,
        )) {
      return false;
    }
    for (var first = 0; first < players; first++) {
      if (state.diplomacyRelations[first][first] != DiplomacyStatus.alliance ||
          state.diplomacyAllianceTurns[first][first] != 0 ||
          state.diplomacyWarCooldowns[first][first] != 0 ||
          state.diplomacyBlackMarks[first][first] ||
          state.diplomacyBlackMarkCooldowns[first][first] != 0 ||
          state.diplomacyDebts[first][first] != 0) {
        return false;
      }
      for (var second = first + 1; second < players; second++) {
        if (state.diplomacyRelations[first][second] !=
                state.diplomacyRelations[second][first] ||
            state.diplomacyAllianceTurns[first][second] !=
                state.diplomacyAllianceTurns[second][first] ||
            state.diplomacyWarCooldowns[first][second] !=
                state.diplomacyWarCooldowns[second][first] ||
            state.diplomacyBlackMarks[first][second] !=
                state.diplomacyBlackMarks[second][first] ||
            state.diplomacyBlackMarkCooldowns[first][second] !=
                state.diplomacyBlackMarkCooldowns[second][first]) {
          return false;
        }
      }
    }

    if (requirePlayable) {
      final alive = state.provinces.map((province) => province.owner).toSet();
      if (!alive.contains(0) || alive.length < 2) return false;
    }
    return true;
  }

  static bool _validOffer(
    DiplomacyOffer offer,
    int tileCount,
    int playerCount,
  ) {
    final navalKeys = offer.navalRefs
        .map((reference) => '${reference.kind.name}:${reference.id}')
        .toList();
    if (offer.amount < 0 ||
        offer.duration < 0 ||
        offer.targetPlayer < -1 ||
        offer.targetPlayer >= playerCount ||
        offer.tiles.toSet().length != offer.tiles.length ||
        offer.tiles.any((tile) => tile < 0 || tile >= tileCount) ||
        navalKeys.toSet().length != navalKeys.length ||
        offer.navalRefs.any((reference) => reference.id <= 0)) {
      return false;
    }
    return switch (offer.type) {
      DiplomacyExchangeType.money => offer.amount > 0,
      DiplomacyExchangeType.lands =>
        offer.tiles.isNotEmpty || offer.navalRefs.isNotEmpty,
      DiplomacyExchangeType.warDeclaration => offer.targetPlayer >= 0,
      DiplomacyExchangeType.subsidies => offer.amount > 0 && offer.duration > 0,
      _ => true,
    };
  }

  static bool _isValidRawStateJson(Map<String, dynamic> json) {
    bool isInt(Object? value) => value is int;
    bool isIntList(Object? value) =>
        value is List && value.every((item) => item is int);
    Map<String, dynamic>? mapOf(Object? value) {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        return null;
      }
      return value.cast<String, dynamic>();
    }

    bool validIntKeyMap(Object? raw, bool Function(Object? value) validValue) {
      final map = mapOf(raw);
      if (map == null) return false;
      final parsedKeys = <int>{};
      for (final entry in map.entries) {
        final key = int.tryParse(entry.key);
        if (key == null || '$key' != entry.key || !parsedKeys.add(key)) {
          return false;
        }
        if (!validValue(entry.value)) return false;
      }
      return true;
    }

    bool optionalType<T>(Map<String, dynamic> map, String key) =>
        !map.containsKey(key) || map[key] == null || map[key] is T;
    bool enumName<T extends Enum>(Object? value, List<T> values) =>
        value is String && values.any((item) => item.name == value);
    bool validUnitJson(Object? raw) {
      final unit = mapOf(raw);
      return unit != null &&
          isInt(unit['strength']) &&
          unit['ready'] is bool &&
          optionalType<int>(unit, 'owner') &&
          optionalType<int>(unit, 'homeProvinceId') &&
          (!unit.containsKey('transitAllies') ||
              isIntList(unit['transitAllies']));
    }

    bool validNavalRefJson(Object? raw) {
      final reference = mapOf(raw);
      return reference != null &&
          enumName(reference['kind'], NavalAssetKind.values) &&
          isInt(reference['id']);
    }

    bool validCoalitionClaimJson(
      Object? raw, {
      required bool requireConferenceFields,
    }) {
      final claim = mapOf(raw);
      return claim != null &&
          isInt(claim['campaignId']) &&
          isInt(claim['originalOwner']) &&
          isIntList(claim['members']) &&
          isInt(claim['captor']) &&
          (!requireConferenceFields || claim.containsKey('contributors')) &&
          (!claim.containsKey('contributors') ||
              isIntList(claim['contributors'])) &&
          (!requireConferenceFields || claim.containsKey('settlementValue')) &&
          (!claim.containsKey('settlementValue') ||
              isInt(claim['settlementValue'])) &&
          (!requireConferenceFields || claim.containsKey('conferenceId')) &&
          (!claim.containsKey('conferenceId') || isInt(claim['conferenceId']));
    }

    bool validCampaignJson(Object? raw) {
      final campaign = mapOf(raw);
      return campaign != null &&
          isInt(campaign['id']) &&
          isInt(campaign['attackerLeader']) &&
          isInt(campaign['defenderLeader']) &&
          isIntList(campaign['sideA']) &&
          isIntList(campaign['sideB']) &&
          isInt(campaign['startedRound']);
    }

    bool validPeaceConferenceJson(Object? raw) {
      final conference = mapOf(raw);
      return conference != null &&
          isInt(conference['id']) &&
          isInt(conference['sourceCampaignId']) &&
          isInt(conference['originalOwner']) &&
          isIntList(conference['claimTiles']) &&
          isIntList(conference['participants']) &&
          isInt(conference['openedRound']) &&
          isInt(conference['deadlineRound']) &&
          validIntKeyMap(conference['tileValues'], isInt) &&
          validIntKeyMap(conference['contributionPoints'], isInt) &&
          validIntKeyMap(conference['allocations'], isIntList) &&
          isInt(conference['proposer']) &&
          isInt(conference['revision']) &&
          isIntList(conference['acceptedBy']);
    }

    bool validOfferJson(Object? raw) {
      final offer = mapOf(raw);
      if (offer == null ||
          !enumName(offer['type'], DiplomacyExchangeType.values)) {
        return false;
      }
      return (!offer.containsKey('amount') || isInt(offer['amount'])) &&
          (!offer.containsKey('duration') || isInt(offer['duration'])) &&
          (!offer.containsKey('targetPlayer') ||
              isInt(offer['targetPlayer'])) &&
          (!offer.containsKey('tiles') || isIntList(offer['tiles'])) &&
          (!offer.containsKey('navalRefs') ||
              (offer['navalRefs'] is List &&
                  (offer['navalRefs'] as List).every(validNavalRefJson)));
    }

    bool validMatrix(
      Object? raw,
      int players,
      bool Function(Object? value) validValue,
    ) =>
        raw is List &&
        raw.length == players &&
        raw.every(
          (row) =>
              row is List && row.length == players && row.every(validValue),
        );

    final config = mapOf(json['config']);
    if (config == null ||
        !enumName(config['mapSize'], MapSize.values) ||
        !isInt(config['playerCount']) ||
        !isInt(config['seed']) ||
        !enumName(config['difficulty'], AiDifficulty.values) ||
        !optionalType<int>(config, 'humanCount') ||
        !optionalType<int>(config, 'treePercent') ||
        !optionalType<int>(config, 'startingProvinceCount') ||
        !optionalType<int>(config, 'playerColorOffset') ||
        !optionalType<bool>(config, 'slayRules') ||
        !optionalType<bool>(config, 'fogOfWar') ||
        !optionalType<bool>(config, 'diplomacy') ||
        !optionalType<int>(config, 'campaignLevel')) {
      return false;
    }
    final players = config['playerCount'] as int;
    final schema = json['schema'];
    final requiresPeaceConferenceFields = schema is int && schema >= 12;
    if (players < 2 ||
        players > 15 ||
        (json.containsKey('schema') && !isInt(json['schema'])) ||
        json['modId'] is! String ||
        !isInt(json['width']) ||
        !isInt(json['height']) ||
        json['hexes'] is! List ||
        json['provinces'] is! List ||
        !isInt(json['turn']) ||
        !isInt(json['round']) ||
        !isInt(json['rngState']) ||
        !isInt(json['nextProvinceId']) ||
        !optionalType<int>(json, 'nextNavalEntityId') ||
        !optionalType<int>(json, 'nextWarCampaignId') ||
        !optionalType<int>(json, 'nextPeaceConferenceId') ||
        (json['nextNavalEntityId'] is int &&
            (json['nextNavalEntityId'] as int) <= 0) ||
        (json['nextWarCampaignId'] is int &&
            (json['nextWarCampaignId'] as int) <= 0) ||
        (json['nextPeaceConferenceId'] is int &&
            (json['nextPeaceConferenceId'] as int) <= 0) ||
        (requiresPeaceConferenceFields &&
            (!json.containsKey('nextPeaceConferenceId') ||
                !json.containsKey('peaceConferences'))) ||
        (json.containsKey('campaigns') && json['campaigns'] is! List) ||
        (json.containsKey('peaceConferences') &&
            json['peaceConferences'] is! List) ||
        (json.containsKey('playerNamesVersion') &&
            json['playerNamesVersion'] != 1) ||
        (json.containsKey('playerNames') &&
            (json['playerNames'] is! List ||
                (json['playerNames'] as List).length != players ||
                !(json['playerNames'] as List).every(
                  (name) => name is String,
                ))) ||
        (json['winner'] != null && !isInt(json['winner']))) {
      return false;
    }

    if ((json['campaigns'] as List? ?? const <Object>[]).any(
      (campaign) => !validCampaignJson(campaign),
    )) {
      return false;
    }

    final rawConferenceIds = <int>{};
    var largestRawConferenceId = 0;
    for (final rawConference
        in (json['peaceConferences'] as List? ?? const <Object>[])) {
      if (!validPeaceConferenceJson(rawConference)) return false;
      final conference = mapOf(rawConference)!;
      final id = conference['id'] as int;
      if (id <= 0 || !rawConferenceIds.add(id)) return false;
      if (id > largestRawConferenceId) largestRawConferenceId = id;
    }
    final rawNextConferenceId = json['nextPeaceConferenceId'];
    if (rawNextConferenceId is int &&
        rawNextConferenceId <= largestRawConferenceId) {
      return false;
    }

    for (final rawTile in json['hexes'] as List) {
      final tile = mapOf(rawTile);
      if (tile == null ||
          !isInt(tile['index']) ||
          !isInt(tile['q']) ||
          !isInt(tile['r']) ||
          tile['active'] is! bool ||
          !isInt(tile['owner']) ||
          !enumName(tile['object'], TileObject.values) ||
          !isIntList(tile['neighbors']) ||
          !optionalType<bool>(tile, 'inWorld') ||
          !optionalType<int>(tile, 'treeBorn') ||
          !optionalType<int>(tile, 'artilleryCooldown') ||
          !optionalType<int>(tile, 'artilleryAmmo') ||
          (tile['coalitionClaim'] != null &&
              !validCoalitionClaimJson(
                tile['coalitionClaim'],
                requireConferenceFields: requiresPeaceConferenceFields,
              )) ||
          (tile['unit'] != null && !validUnitJson(tile['unit']))) {
        return false;
      }
    }

    final rawWater = json['waterCells'];
    if (rawWater != null && rawWater is! List) return false;
    final rawNavalEntityIds = <int>{};
    for (final rawCell in (rawWater as List? ?? const [])) {
      final cell = mapOf(rawCell);
      if (cell == null ||
          !isInt(cell['index']) ||
          !isIntList(cell['tiles']) ||
          (!cell.containsKey('neighbors') || isIntList(cell['neighbors'])) ==
              false ||
          (!cell.containsKey('coastTiles') || isIntList(cell['coastTiles'])) ==
              false ||
          !optionalType<bool>(cell, 'navigable') ||
          !optionalType<bool>(cell, 'seaMint')) {
        return false;
      }
      final boat = cell['boat'];
      if (boat != null) {
        final data = mapOf(boat);
        if (data == null ||
            !optionalType<int>(data, 'id') ||
            !isInt(data['owner']) ||
            !isInt(data['level']) ||
            !isInt(data['homeProvinceId']) ||
            !optionalType<bool>(data, 'ready') ||
            !optionalType<int>(data, 'supportedTile') ||
            (!data.containsKey('supportedTiles') ||
                    isIntList(data['supportedTiles'])) ==
                false ||
            !optionalType<int>(data, 'damage') ||
            (data.containsKey('cargo') && data['cargo'] is! List) ||
            (data['cargo'] as List? ?? const []).any(
              (unit) => !validUnitJson(unit),
            )) {
          return false;
        }
        final id = data['id'];
        if (id is int && id > 0 && !rawNavalEntityIds.add(id)) return false;
        final supported = data['supportedTiles'] as List?;
        final legacySupported = data['supportedTile'];
        if (supported != null &&
            legacySupported != null &&
            (supported.isEmpty || supported.first != legacySupported)) {
          return false;
        }
      }
      final fort = cell['seaFort'];
      if (fort != null) {
        final data = mapOf(fort);
        if (data == null ||
            !optionalType<int>(data, 'id') ||
            !isInt(data['owner']) ||
            !isInt(data['homeProvinceId'])) {
          return false;
        }
        final id = data['id'];
        if (id is int && id > 0 && !rawNavalEntityIds.add(id)) return false;
      }
    }

    for (final rawProvince in json['provinces'] as List) {
      final province = mapOf(rawProvince);
      if (province == null ||
          !isInt(province['id']) ||
          !isInt(province['owner']) ||
          !isIntList(province['tiles']) ||
          !isInt(province['money']) ||
          !isInt(province['capital']) ||
          !optionalType<bool>(province, 'navalCapital') ||
          !optionalType<bool>(province, 'navalFounded')) {
        return false;
      }
    }

    final matrixChecks = <String, bool Function(Object?)>{
      'diplomacyRelations': (value) => enumName(value, DiplomacyStatus.values),
      'diplomacyAllianceTurns': isInt,
      'diplomacyWarCooldowns': isInt,
      'diplomacyBlackMarks': (value) => value is bool,
      'diplomacyBlackMarkCooldowns': isInt,
      'diplomacyDebts': isInt,
    };
    for (final entry in matrixChecks.entries) {
      if (json.containsKey(entry.key) &&
          !validMatrix(json[entry.key], players, entry.value)) {
        return false;
      }
    }
    if (json.containsKey('diplomacyTraitorTurns') &&
        (json['diplomacyTraitorTurns'] is! List ||
            (json['diplomacyTraitorTurns'] as List).length != players ||
            !isIntList(json['diplomacyTraitorTurns']))) {
      return false;
    }

    final subsidies = json['diplomacySubsidies'];
    if (subsidies != null && subsidies is! List) return false;
    for (final rawSubsidy in (subsidies as List? ?? const [])) {
      final subsidy = mapOf(rawSubsidy);
      if (subsidy == null ||
          !isInt(subsidy['payer']) ||
          !isInt(subsidy['receiver']) ||
          !isInt(subsidy['amount']) ||
          !isInt(subsidy['turnsLeft'])) {
        return false;
      }
    }

    final proposals = json['diplomacyProposals'];
    if (proposals != null && proposals is! List) return false;
    for (final rawProposal in (proposals as List? ?? const [])) {
      final proposal = mapOf(rawProposal);
      if (proposal == null ||
          !isInt(proposal['from']) ||
          !isInt(proposal['to']) ||
          !enumName(proposal['type'], DiplomacyProposalType.values) ||
          !optionalType<int>(proposal, 'createdRound') ||
          !optionalType<String>(proposal, 'rationale') ||
          ((proposal['rationale'] as String?)?.length ?? 0) > 400 ||
          (proposal.containsKey('fromOffer') &&
              !validOfferJson(proposal['fromOffer'])) ||
          (proposal.containsKey('toOffer') &&
              !validOfferJson(proposal['toOffer']))) {
        return false;
      }
      if (proposal.containsKey('terms')) {
        final terms = proposal['terms'];
        if (terms is! List || terms.isEmpty || terms.length > 3) return false;
        for (final raw in terms) {
          final term = mapOf(raw);
          if (term == null ||
              term['fromSender'] is! bool ||
              !validOfferJson(term['offer'])) {
            return false;
          }
        }
      }
    }

    if (json.containsKey('diplomacySocial')) {
      final social = mapOf(json['diplomacySocial']);
      if (social == null) return false;
      if (social.containsKey('relationsVersion') &&
          social['relationsVersion'] != 2) {
        return false;
      }
      for (final key in [
        'opinions',
        'actionCooldowns',
        'lastContact',
        'lastTradeReward',
        'lastAidReward',
      ]) {
        // Optional for the first social-state saves, but strict when present.
        if ((key == 'lastTradeReward' || key == 'lastAidReward') &&
            !social.containsKey(key)) {
          continue;
        }
        final matrix = social[key];
        if (matrix is! List || matrix.length != players) return false;
        for (var a = 0; a < players; a++) {
          final row = matrix[a];
          if (row is! List || row.length != players) return false;
          for (var b = 0; b < players; b++) {
            final value = row[b];
            if (value is! int) return false;
            if (key == 'opinions' &&
                (value < -100 || value > 100 || (a == b && value != 0))) {
              return false;
            }
            if (key == 'opinions' &&
                social['relationsVersion'] == 2 &&
                matrix[b] is List &&
                (matrix[b] as List).length == players &&
                value != matrix[b][a]) {
              return false;
            }
            if (key == 'actionCooldowns' && (value < 0 || value > 3)) {
              return false;
            }
            if ((key == 'lastContact' ||
                    key == 'lastTradeReward' ||
                    key == 'lastAidReward') &&
                (value < -1000 || value > (json['round'] as int))) {
              return false;
            }
          }
        }
      }
      final events = social['events'];
      if (events is! List || events.length > 160) return false;
      for (final raw in events) {
        final event = mapOf(raw);
        if (event == null ||
            !isInt(event['observer']) ||
            !isInt(event['subject']) ||
            !isInt(event['delta']) ||
            !isInt(event['round']) ||
            event['reason'] is! String) {
          return false;
        }
        final a = event['observer'] as int;
        final b = event['subject'] as int;
        if (a < 0 ||
            a >= players ||
            b < 0 ||
            b >= players ||
            a == b ||
            (event['delta'] as int).abs() > 200 ||
            (event['round'] as int) < 0 ||
            (event['reason'] as String).length > 100) {
          return false;
        }
      }
    }

    final messages = json['diplomacyMessages'];
    if (messages != null && messages is! List) return false;
    for (final rawMessage in (messages as List? ?? const [])) {
      final message = mapOf(rawMessage);
      if (message == null ||
          !isInt(message['from']) ||
          !isInt(message['to']) ||
          message['text'] is! String ||
          !optionalType<int>(message, 'createdRound')) {
        return false;
      }
    }
    return !json.containsKey('diplomacyLog') ||
        (json['diplomacyLog'] is List &&
            (json['diplomacyLog'] as List).every((item) => item is String));
  }
}
