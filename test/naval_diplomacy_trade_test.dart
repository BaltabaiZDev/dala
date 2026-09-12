import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test(
    'selling a port tile keeps its untraded ship on the original upkeep',
    () {
      final state = _portSaleState();
      final engine = GameEngine(mod: mod, state: state);
      final boat = state.waterCells.single.boat!;
      final originalHome = boat.homeProvinceId;

      expect(
        engine.economicBreakdown(_province(state, originalHome)).boats,
        -mod.rules.boat1Upkeep,
      );
      expect(
        engine.proposeExchange(
          from: 0,
          to: 1,
          fromOffer: const DiplomacyOffer(
            type: DiplomacyExchangeType.lands,
            tiles: [2],
          ),
          toOffer: const DiplomacyOffer(),
        ),
        isTrue,
      );

      final proposal = engine.proposalsFor(1).single;
      expect(engine.resolveDiplomacyProposal(proposal, accept: true), isTrue);

      expect(state.hexes[2].owner, 1);
      expect(state.hexes[2].object, TileObject.port1);
      expect(state.waterCells.single.boat, same(boat));
      expect(boat.owner, 0);
      expect(boat.homeProvinceId, originalHome);
      expect(state.waterCells.single.seaMint, isFalse);
      expect(
        engine.economicBreakdown(_province(state, originalHome)).boats,
        -mod.rules.boat1Upkeep,
      );
      expect(engine.playerEconomicBreakdown(1).boats, 0);
    },
  );

  test('small-province naval assets follow their exact merged lineage', () {
    final state = _provinceMergeState();
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells[0].boat!;
    final fort = state.waterCells[1].seaFort!;

    // Province 11 is the launch province. Province 22 is the stronger province
    // it joins; province 33 is deliberately coastal so a generic fallback
    // would choose the wrong home and expose a lineage regression.
    state.hexes[2].owner = 0;
    engine.rebuildProvinces();

    final merged = state.provinces.singleWhere(
      (province) => province.tiles.contains(0),
    );
    final coastalFallback = _province(state, 33);
    expect(merged.id, 22);
    expect(merged.tiles.toSet(), {0, 1, 2, 3, 4, 5});
    expect(boat.homeProvinceId, merged.id);
    expect(fort.homeProvinceId, merged.id);
    expect(boat.homeProvinceId, isNot(coastalFallback.id));
    expect(fort.homeProvinceId, isNot(coastalFallback.id));
    expect(engine.economicBreakdown(merged).boats, -mod.rules.boat1Upkeep);
    expect(engine.economicBreakdown(merged).seaForts, -mod.rules.seaFortUpkeep);
    expect(engine.economicBreakdown(coastalFallback).boats, 0);
    expect(engine.economicBreakdown(coastalFallback).seaForts, 0);
  });

  test('gifting every land tile sinks an untraded boat into a sea mint', () {
    final state = _fullGiftState(boatLevel: 1);
    final engine = GameEngine(mod: mod, state: state);

    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: const DiplomacyOffer(
          type: DiplomacyExchangeType.lands,
          tiles: [0, 1],
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isTrue,
    );
    expect(
      engine.resolveDiplomacyProposal(
        engine.proposalsFor(1).single,
        accept: true,
      ),
      isTrue,
    );

    expect(engine.provincesOf(0), isEmpty);
    expect(state.waterCells.single.boat, isNull);
    expect(state.waterCells.single.seaMint, isTrue);
  });

  test('a traded boat survives and moves ownership and upkeep together', () {
    final state = _fullGiftState(boatLevel: 2, cargo: true);
    final engine = GameEngine(mod: mod, state: state);
    final boat = state.waterCells.single.boat!;
    final boatId = boat.id;

    expect(engine.playerEconomicBreakdown(0).boats, -mod.rules.boat2Upkeep);
    expect(engine.playerEconomicBreakdown(1).boats, 0);
    expect(
      engine.proposeExchange(
        from: 0,
        to: 1,
        fromOffer: DiplomacyOffer(
          type: DiplomacyExchangeType.lands,
          navalRefs: [NavalAssetRef(kind: NavalAssetKind.boat, id: boatId)],
        ),
        toOffer: const DiplomacyOffer(),
      ),
      isTrue,
    );
    expect(
      engine.resolveDiplomacyProposal(
        engine.proposalsFor(1).single,
        accept: true,
      ),
      isTrue,
    );

    final buyerHome = engine.provincesOf(1).single;
    expect(state.waterCells.single.boat, same(boat));
    expect(state.waterCells.single.seaMint, isFalse);
    expect(boat.id, boatId);
    expect(boat.owner, 1);
    expect(boat.homeProvinceId, buyerHome.id);
    expect(boat.ready, isFalse);
    expect(
      boat.cargo.every(
        (unit) => unit.owner == 1 && unit.homeProvinceId == buyerHome.id,
      ),
      isTrue,
    );
    expect(engine.playerEconomicBreakdown(0).boats, 0);
    expect(engine.playerEconomicBreakdown(1).boats, -mod.rules.boat2Upkeep);
  });

  test('stable naval IDs and offer references survive repeated save loads', () {
    final state = _navalIdentityState();
    final boatId = state.waterCells[0].boat!.id;
    final fortId = state.waterCells[1].seaFort!.id;
    final nextId = state.nextNavalEntityId;
    final references = <NavalAssetRef>[
      NavalAssetRef(kind: NavalAssetKind.boat, id: boatId),
      NavalAssetRef(kind: NavalAssetKind.seaFort, id: fortId),
    ];
    state.diplomacyProposals.add(
      DiplomacyProposal(
        from: 0,
        to: 1,
        type: DiplomacyProposalType.exchange,
        createdRound: state.round,
        fromOffer: DiplomacyOffer(
          type: DiplomacyExchangeType.lands,
          navalRefs: references,
        ),
      ),
    );

    final firstLoad = GameState.fromJson(state.toJson());
    final secondLoad = GameState.fromJson(firstLoad.toJson());

    expect(boatId, greaterThan(0));
    expect(fortId, greaterThan(0));
    expect(boatId, isNot(fortId));
    expect(firstLoad.waterCells[0].boat!.id, boatId);
    expect(firstLoad.waterCells[1].seaFort!.id, fortId);
    expect(secondLoad.waterCells[0].boat!.id, boatId);
    expect(secondLoad.waterCells[1].seaFort!.id, fortId);
    expect(firstLoad.nextNavalEntityId, nextId);
    expect(secondLoad.nextNavalEntityId, nextId);
    expect(firstLoad.diplomacyProposals.single.fromOffer.navalRefs, references);
    expect(
      secondLoad.diplomacyProposals.single.fromOffer.navalRefs,
      references,
    );
  });
}

Province _province(GameState state, int id) =>
    state.provinces.singleWhere((province) => province.id == id);

GameState _portSaleState() {
  final hexes = _linearHexes([0, 0, 0, 1, 1, null]);
  hexes[0].object = TileObject.town;
  hexes[2].object = TileObject.port1;
  hexes[3].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2, diplomacy: true),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [5],
        coastTiles: [2],
        boat: GameBoat(id: 71, owner: 0, level: 1, homeProvinceId: 10),
      ),
    ],
    provinces: [
      Province(id: 10, owner: 0, tiles: [0, 1, 2], money: 80, capital: 0),
      Province(id: 20, owner: 1, tiles: [3, 4], money: 80, capital: 3),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 30,
    nextNavalEntityId: 100,
  );
}

GameState _provinceMergeState() {
  final hexes = _linearHexes([0, 0, -1, 0, 0, 0, null, null, 0, 0, 0, 0]);
  hexes[0].object = TileObject.town;
  hexes[3].object = TileObject.town;
  hexes[8].object = TileObject.town;
  // Keep the third province disconnected despite its linear display position.
  hexes[7].neighbors.clear();
  hexes[8].neighbors
    ..clear()
    ..add(9);
  return GameState(
    config: const GameConfig(playerCount: 1, humanCount: 1),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [6],
        coastTiles: [8],
        boat: GameBoat(id: 101, owner: 0, level: 1, homeProvinceId: 11),
      ),
      WaterCell(
        index: 1,
        tiles: [7],
        coastTiles: [8],
        seaFort: SeaFort(id: 102, owner: 0, homeProvinceId: 11),
      ),
    ],
    provinces: [
      Province(id: 11, owner: 0, tiles: [0, 1], money: 11, capital: 0),
      Province(id: 22, owner: 0, tiles: [3, 4, 5], money: 22, capital: 3),
      Province(id: 33, owner: 0, tiles: [8, 9, 10, 11], money: 33, capital: 8),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 40,
    nextNavalEntityId: 200,
  );
}

GameState _fullGiftState({required int boatLevel, bool cargo = false}) {
  final hexes = _linearHexes([0, 0, 1, 1, null]);
  hexes[0].object = TileObject.town;
  hexes[1].object = TileObject.port1;
  hexes[2].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2, diplomacy: true),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [4],
        coastTiles: [1],
        boat: GameBoat(
          id: 51,
          owner: 0,
          level: boatLevel,
          homeProvinceId: 10,
          cargo: cargo
              ? [GameUnit(strength: 1, owner: 0, homeProvinceId: 10)]
              : null,
        ),
      ),
    ],
    provinces: [
      Province(id: 10, owner: 0, tiles: [0, 1], money: 80, capital: 0),
      Province(id: 20, owner: 1, tiles: [2, 3], money: 80, capital: 2),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 30,
    nextNavalEntityId: 100,
  );
}

GameState _navalIdentityState() {
  final hexes = _linearHexes([0, 0, 1, 1, null, null]);
  hexes[0].object = TileObject.town;
  hexes[2].object = TileObject.town;
  return GameState(
    config: const GameConfig(playerCount: 2, humanCount: 2, diplomacy: true),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    waterCells: [
      WaterCell(
        index: 0,
        tiles: [4],
        coastTiles: [1],
        boat: GameBoat(owner: 0, level: 2, homeProvinceId: 10),
      ),
      WaterCell(
        index: 1,
        tiles: [5],
        coastTiles: [1],
        seaFort: SeaFort(owner: 0, homeProvinceId: 10),
      ),
    ],
    provinces: [
      Province(id: 10, owner: 0, tiles: [0, 1], money: 80, capital: 0),
      Province(id: 20, owner: 1, tiles: [2, 3], money: 80, capital: 2),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 30,
    nextNavalEntityId: 5,
  );
}

List<HexTile> _linearHexes(List<int?> owners) => [
  for (var index = 0; index < owners.length; index++)
    HexTile(
      index: index,
      q: index,
      r: 0,
      active: owners[index] != null,
      owner: owners[index] ?? -1,
      neighbors: [
        if (index > 0) index - 1,
        if (index + 1 < owners.length) index + 1,
      ],
    ),
];
