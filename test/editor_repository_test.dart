import 'dart:convert';

import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('editor stores and restores the complete edited game state', () async {
    SharedPreferences.setMockInitialValues({});
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(
      mod,
    ).generate(const GameConfig(mapSize: MapSize.small, seed: 74129));
    final edited = state.hexes.firstWhere(
      (tile) =>
          tile.active &&
          tile.owner >= 0 &&
          tile.object == TileObject.none &&
          state.waterCells.any(
            (cell) => cell.navigable && cell.coastTiles.contains(tile.index),
          ) &&
          state.provinces.any(
            (province) =>
                province.capital != tile.index &&
                province.tiles.contains(tile.index),
          ),
    );
    final province = state.provinces.firstWhere(
      (province) => province.tiles.contains(edited.index),
    );
    edited
      ..object = TileObject.artillery2
      ..artilleryAmmo = 4
      ..unit = null;
    final unitTile = state.hexes.firstWhere(
      (tile) =>
          tile.active &&
          tile.owner >= 0 &&
          tile.index != edited.index &&
          tile.object == TileObject.none &&
          state.provinces.any(
            (province) =>
                province.capital != tile.index &&
                province.tiles.contains(tile.index),
          ),
    )..unit = GameUnit(strength: 3);

    const repository = EditorRepository();
    await repository.saveDraft(state);
    final loaded = await repository.loadDraft();

    expect(loaded, isNotNull);
    expect(loaded!.config.seed, 74129);
    expect(loaded.hexes[edited.index].owner, province.owner);
    expect(loaded.hexes[edited.index].object, TileObject.artillery2);
    expect(loaded.hexes[edited.index].artilleryAmmo, 4);
    expect(loaded.hexes[unitTile.index].unit?.strength, 3);
    expect(repository.decode(repository.encode(loaded)), isNotNull);
    expect(repository.decode('{"fake":true}'), isNull);
  });

  test(
    'editor rejects malformed raw diplomacy instead of using fallbacks',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(
        mod,
      ).generate(const GameConfig(mapSize: MapSize.small, seed: 8123));
      const repository = EditorRepository();

      Map<String, dynamic> encoded() =>
          (jsonDecode(repository.encode(state)) as Map).cast<String, dynamic>();

      final badStatus = encoded();
      final statusState = (badStatus['state'] as Map).cast<String, dynamic>();
      (statusState['diplomacyRelations'] as List)[0][1] = 'secret';
      expect(repository.decode(jsonEncode(badStatus)), isNull);

      final badMatrixType = encoded();
      final matrixState = (badMatrixType['state'] as Map)
          .cast<String, dynamic>();
      (matrixState['diplomacyDebts'] as List)[0][1] = '9';
      expect(repository.decode(jsonEncode(badMatrixType)), isNull);

      final badOffer = encoded();
      final offerState = (badOffer['state'] as Map).cast<String, dynamic>();
      offerState['diplomacyProposals'] = [
        {
          'from': 0,
          'to': 1,
          'type': 'exchange',
          'createdRound': 0,
          'fromOffer': {'type': 'teleport'},
          'toOffer': {'type': 'nothing'},
        },
      ];
      expect(repository.decode(jsonEncode(badOffer)), isNull);
    },
  );

  test('editor rejects disconnected or incomplete province coverage', () async {
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(
      mod,
    ).generate(const GameConfig(mapSize: MapSize.small, seed: 93217));
    const repository = EditorRepository();

    final disconnected = (jsonDecode(repository.encode(state)) as Map)
        .cast<String, dynamic>();
    final disconnectedState = (disconnected['state'] as Map)
        .cast<String, dynamic>();
    final provinces = disconnectedState['provinces'] as List;
    final province = (provinces.first as Map).cast<String, dynamic>();
    final isolated = (province['tiles'] as List).first as int;
    final provinceTiles = (province['tiles'] as List).cast<int>().toSet();
    final rawTile = ((disconnectedState['hexes'] as List)[isolated] as Map)
        .cast<String, dynamic>();
    rawTile['neighbors'] = (rawTile['neighbors'] as List)
        .where((neighbor) => !provinceTiles.contains(neighbor))
        .toList();
    expect(repository.decode(jsonEncode(disconnected)), isNull);

    final uncovered = (jsonDecode(repository.encode(state)) as Map)
        .cast<String, dynamic>();
    final uncoveredState = (uncovered['state'] as Map).cast<String, dynamic>();
    (uncoveredState['provinces'] as List).removeAt(0);
    expect(repository.decode(jsonEncode(uncovered)), isNull);
  });

  test(
    'editor enforces capital, province id and owned piece invariants',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(
        mod,
      ).generate(const GameConfig(mapSize: MapSize.small, seed: 4812));
      const repository = EditorRepository();

      Map<String, dynamic> encoded() =>
          (jsonDecode(repository.encode(state)) as Map).cast<String, dynamic>();

      final badCapital = encoded();
      final capitalState = (badCapital['state'] as Map).cast<String, dynamic>();
      final province = ((capitalState['provinces'] as List).first as Map)
          .cast<String, dynamic>();
      final capital = province['capital'] as int;
      ((capitalState['hexes'] as List)[capital] as Map)['object'] = 'farm';
      expect(repository.decode(jsonEncode(badCapital)), isNull);

      final badNextId = encoded();
      final idState = (badNextId['state'] as Map).cast<String, dynamic>();
      final ids = (idState['provinces'] as List)
          .map((item) => (item as Map)['id'] as int)
          .toList();
      idState['nextProvinceId'] = ids.reduce((a, b) => a > b ? a : b);
      expect(repository.decode(jsonEncode(badNextId)), isNull);

      final orphanUnit = encoded();
      final unitState = (orphanUnit['state'] as Map).cast<String, dynamic>();
      final hexes = unitState['hexes'] as List;
      final singleton = hexes.cast<Map>().firstWhere(
        (candidate) => candidate['active'] == true && candidate['owner'] == -1,
      );
      singleton['owner'] = 0;
      singleton['object'] = 'none';
      singleton['unit'] = {'strength': 1, 'ready': true};
      expect(repository.decode(jsonEncode(orphanUnit)), isNull);

      final orphanBuilding = encoded();
      final buildingState = (orphanBuilding['state'] as Map)
          .cast<String, dynamic>();
      final buildingHexes = buildingState['hexes'] as List;
      final buildingTile = buildingHexes.cast<Map>().firstWhere(
        (candidate) => candidate['active'] == true && candidate['owner'] == -1,
      );
      buildingTile['owner'] = 0;
      buildingTile['object'] = 'farm';
      buildingTile['unit'] = null;
      expect(repository.decode(jsonEncode(orphanBuilding)), isNull);
    },
  );

  test(
    'editor enforces navigable assets, capacity and artillery ammo',
    () async {
      final mod = await GameMod.loadDefault();
      final state = MapGenerator(
        mod,
      ).generate(const GameConfig(mapSize: MapSize.small, seed: 67891));
      const repository = EditorRepository();

      Map<String, dynamic> encoded() =>
          (jsonDecode(repository.encode(state)) as Map).cast<String, dynamic>();

      final blockedFort = encoded();
      final fortState = (blockedFort['state'] as Map).cast<String, dynamic>();
      final home = ((fortState['provinces'] as List).first as Map)
          .cast<String, dynamic>();
      final water = (fortState['waterCells'] as List).first as Map;
      water['navigable'] = false;
      water['seaFort'] = {'owner': home['owner'], 'homeProvinceId': home['id']};
      expect(repository.decode(jsonEncode(blockedFort)), isNull);

      final overloadedBoat = encoded();
      final boatState = (overloadedBoat['state'] as Map)
          .cast<String, dynamic>();
      final boatHome = ((boatState['provinces'] as List).first as Map)
          .cast<String, dynamic>();
      final boatCell =
          (boatState['waterCells'] as List).firstWhere(
                (item) => (item as Map)['navigable'] == true,
              )
              as Map;
      boatCell['boat'] = {
        'owner': boatHome['owner'],
        'level': 1,
        'homeProvinceId': boatHome['id'],
        'ready': true,
        'supportedTile': null,
        'supportedTiles': <int>[],
        'damage': 0,
        'cargo': [
          {'strength': 4, 'ready': true},
          {'strength': 1, 'ready': true},
        ],
      };
      expect(
        repository.decode(jsonEncode(overloadedBoat), rules: mod.rules),
        isNull,
      );

      final excessAmmo = encoded();
      final ammoState = (excessAmmo['state'] as Map).cast<String, dynamic>();
      final ammoProvince = ((ammoState['provinces'] as List).first as Map)
          .cast<String, dynamic>();
      final artilleryTile = (ammoProvince['tiles'] as List)
          .cast<int>()
          .firstWhere((index) => index != ammoProvince['capital']);
      final artillery = (ammoState['hexes'] as List)[artilleryTile] as Map;
      artillery['object'] = 'artillery1';
      artillery['unit'] = null;
      artillery['artilleryAmmo'] = mod.rules.artilleryAmmoCapacity[1] + 1;
      expect(
        repository.decode(jsonEncode(excessAmmo), rules: mod.rules),
        isNull,
      );
    },
  );

  test('editor still accepts a complete legacy land-only state', () async {
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(
      mod,
    ).generate(const GameConfig(mapSize: MapSize.small, seed: 1907));
    const repository = EditorRepository();
    final legacy = (jsonDecode(repository.encode(state)) as Map)
        .cast<String, dynamic>();
    final legacyState = (legacy['state'] as Map).cast<String, dynamic>();
    legacyState['waterCells'] = <Object>[];

    expect(repository.decode(jsonEncode(legacy), rules: mod.rules), isNotNull);
  });

  test('editor preserves a complete schema-12 peace conference', () async {
    final fixture = await _peaceConferenceFixture();
    const repository = EditorRepository();

    final restored = repository.decode(
      repository.encode(fixture.state),
      rules: fixture.mod.rules,
    );

    expect(restored, isNotNull);
    expect(restored!.toJson()['schema'], 12);
    expect(restored.nextPeaceConferenceId, 4);
    expect(restored.peaceConferences, hasLength(1));
    final conference = restored.peaceConferences.single;
    expect(conference.id, 3);
    expect(conference.sourceCampaignId, 7);
    expect(conference.claimTiles, fixture.claimTiles);
    expect(conference.tileValues.values, everyElement(25));
    expect(conference.contributionPoints, {0: 50, 2: 50});
    expect(conference.allocations, {
      0: fixture.claimTiles.take(2).toList(),
      2: fixture.claimTiles.skip(2).toList(),
    });
    expect(conference.acceptedBy, [0]);
    for (final index in fixture.claimTiles) {
      final claim = restored.hexes[index].coalitionClaim;
      expect(claim?.conferenceId, 3);
      expect(claim?.campaignId, 7);
      expect(claim?.contributors, [0, 2]);
      expect(claim?.settlementValue, 25);
    }
  });

  test(
    'editor rejects malformed peace conference counters, maps and links',
    () async {
      final fixture = await _peaceConferenceFixture();
      const repository = EditorRepository();

      Map<String, dynamic> encoded() =>
          (jsonDecode(repository.encode(fixture.state)) as Map)
              .cast<String, dynamic>();
      Map<String, dynamic> stateOf(Map<String, dynamic> root) =>
          (root['state'] as Map).cast<String, dynamic>();
      Map<String, dynamic> conferenceOf(Map<String, dynamic> state) =>
          ((state['peaceConferences'] as List).single as Map)
              .cast<String, dynamic>();

      final staleCounter = encoded();
      stateOf(staleCounter)['nextPeaceConferenceId'] = 3;
      expect(
        repository.decode(jsonEncode(staleCounter), rules: fixture.mod.rules),
        isNull,
      );

      final duplicateAllocation = encoded();
      final duplicateConference = conferenceOf(stateOf(duplicateAllocation));
      duplicateConference['allocations'] = {
        '0': fixture.claimTiles.take(2).toList(),
        '2': [fixture.claimTiles[1], fixture.claimTiles[2]],
      };
      expect(
        repository.decode(
          jsonEncode(duplicateAllocation),
          rules: fixture.mod.rules,
        ),
        isNull,
      );

      final invalidRecipient = encoded();
      conferenceOf(stateOf(invalidRecipient))['allocations'] = {
        '1': [fixture.claimTiles.first],
      };
      expect(
        repository.decode(
          jsonEncode(invalidRecipient),
          rules: fixture.mod.rules,
        ),
        isNull,
      );

      final malformedMap = encoded();
      final malformedConference = conferenceOf(stateOf(malformedMap));
      final tileValues = (malformedConference['tileValues'] as Map)
          .cast<String, dynamic>();
      final firstKey = tileValues.keys.first;
      final firstValue = tileValues.remove(firstKey);
      tileValues['0$firstKey'] = firstValue;
      expect(
        repository.decode(jsonEncode(malformedMap), rules: fixture.mod.rules),
        isNull,
      );

      final mismatchedClaim = encoded();
      final mismatchedState = stateOf(mismatchedClaim);
      final tile =
          ((mismatchedState['hexes'] as List)[fixture.claimTiles.first] as Map);
      (tile['coalitionClaim'] as Map)['campaignId'] = 8;
      expect(
        repository.decode(
          jsonEncode(mismatchedClaim),
          rules: fixture.mod.rules,
        ),
        isNull,
      );

      final missingSchema12ClaimField = encoded();
      final missingState = stateOf(missingSchema12ClaimField);
      final missingTile =
          ((missingState['hexes'] as List)[fixture.claimTiles.first] as Map);
      (missingTile['coalitionClaim'] as Map).remove('contributors');
      expect(
        repository.decode(
          jsonEncode(missingSchema12ClaimField),
          rules: fixture.mod.rules,
        ),
        isNull,
      );
    },
  );

  test('editor accepts schema-11 active campaign claims', () async {
    final mod = await GameMod.loadDefault();
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        seed: 45091,
        playerCount: 3,
        humanCount: 3,
        diplomacy: true,
      ),
    );
    final tile = state.hexes.firstWhere(
      (candidate) =>
          candidate.active &&
          candidate.owner == -1 &&
          candidate.object == TileObject.none &&
          candidate.unit == null,
    );
    tile
      ..owner = 0
      ..coalitionClaim = const CoalitionClaim(
        campaignId: 2,
        originalOwner: 1,
        members: [0, 2],
        captor: 0,
      );
    state.campaigns.add(
      const WarCampaign(
        id: 2,
        attackerLeader: 0,
        defenderLeader: 1,
        sideA: [0, 2],
        sideB: [1],
        startedRound: 0,
      ),
    );
    state.nextWarCampaignId = 3;
    const repository = EditorRepository();
    final legacy = (jsonDecode(repository.encode(state)) as Map)
        .cast<String, dynamic>();
    final legacyState = (legacy['state'] as Map).cast<String, dynamic>()
      ..['schema'] = 11
      ..remove('nextPeaceConferenceId')
      ..remove('peaceConferences');
    final rawClaim =
        (((legacyState['hexes'] as List)[tile.index] as Map)['coalitionClaim']
            as Map);
    rawClaim
      ..remove('contributors')
      ..remove('settlementValue')
      ..remove('conferenceId');

    final restored = repository.decode(jsonEncode(legacy), rules: mod.rules);

    expect(restored, isNotNull);
    expect(restored!.nextPeaceConferenceId, 1);
    expect(restored.peaceConferences, isEmpty);
    expect(restored.hexes[tile.index].coalitionClaim?.conferenceId, -1);
    expect(restored.hexes[tile.index].coalitionClaim?.contributors, [0, 2]);
  });
}

Future<({GameMod mod, GameState state, List<int> claimTiles})>
_peaceConferenceFixture() async {
  final mod = await GameMod.loadDefault();
  final state = MapGenerator(mod).generate(
    const GameConfig(
      mapSize: MapSize.small,
      seed: 88421,
      playerCount: 3,
      humanCount: 3,
      diplomacy: true,
    ),
  );
  final claimTiles = state.hexes
      .where(
        (tile) =>
            tile.active &&
            tile.owner == -1 &&
            tile.object == TileObject.none &&
            tile.unit == null,
      )
      .take(4)
      .map((tile) => tile.index)
      .toList();
  expect(claimTiles, hasLength(4));
  for (final index in claimTiles) {
    state.hexes[index]
      ..owner = 0
      ..coalitionClaim = const CoalitionClaim(
        campaignId: 7,
        originalOwner: 1,
        members: [0, 2],
        captor: 0,
        contributors: [0, 2],
        settlementValue: 25,
        conferenceId: 3,
      );
  }
  state.peaceConferences.add(
    PeaceConference(
      id: 3,
      sourceCampaignId: 7,
      originalOwner: 1,
      claimTiles: claimTiles,
      participants: const [0, 2],
      openedRound: state.round,
      deadlineRound: state.round + 5,
      tileValues: {for (final index in claimTiles) index: 25},
      contributionPoints: const {0: 50, 2: 50},
      allocations: {
        0: claimTiles.take(2).toList(),
        2: claimTiles.skip(2).toList(),
      },
      proposer: 0,
      revision: 1,
      acceptedBy: [0],
    ),
  );
  state.nextPeaceConferenceId = 4;
  return (mod: mod, state: state, claimTiles: claimTiles);
}
