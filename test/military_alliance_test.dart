import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  group('sovereign diplomacy and migration', () {
    test(
      'isolated holdings can be taken in every diplomatic status without declaring war',
      () {
        for (final status in DiplomacyStatus.values.where(
          (s) => s != DiplomacyStatus.coalition,
        )) {
          final state = _isolatedHoldingState();
          final engine = GameEngine(mod: mod, state: state);
          engine.setDiplomacyStatus(0, 1, status);
          expect(engine.isIsolatedHolding(2), isTrue);
          expect(engine.moveTargets(1), contains(2), reason: status.name);
          expect(engine.moveUnit(1, 2), isTrue);
          expect(state.hexes[2].owner, 0);
          expect(engine.diplomacyBetween(0, 1), status);
          expect(state.campaigns, isEmpty);
          expect(state.hexes[4].owner, 1);
          expect(EditorRepository.isValidState(state), isTrue);
        }
      },
    );

    test(
      'adjacent same-owner land removes isolated conquest permission, including stale zones',
      () {
        final state = _isolatedHoldingState();
        final engine = GameEngine(mod: mod, state: state);
        final oldTargets = engine.moveTargets(1);
        expect(oldTargets, contains(2));
        state.hexes[3].owner = 1;
        engine.rebuildProvinces();
        expect(engine.isIsolatedHolding(2), isFalse);
        expect(engine.moveUnit(1, 2, knownTargets: oldTargets), isFalse);
        expect(state.hexes[2].owner, 1);
      },
    );

    test(
      'isolated capture still respects strength and supports direct recruitment',
      () {
        final state = _isolatedHoldingState();
        final engine = GameEngine(mod: mod, state: state);
        state.hexes[2].object = TileObject.tower;
        expect(engine.moveTargets(1), isNot(contains(2)));
        expect(engine.unitBuildTargets(1, 3), contains(2));
        expect(engine.buyUnit(1, 2, 3), isTrue);
        expect(state.hexes[2].owner, 0);
        expect(state.hexes[2].unit!.strength, 3);
      },
    );

    test('removed military offers reject human consent and high trust', () {
      final state = _blocState(3);
      final engine = GameEngine(mod: mod, state: state);
      engine.changeOpinion(0, 1, 100, 'test');
      final before = state.toJson().toString();
      expect(engine.formMilitaryAlliance(0, 1), isFalse);
      expect(
        engine.proposeDiplomacy(0, 1, DiplomacyProposalType.militaryAlliance),
        isFalse,
      );
      for (final fromSender in [true, false]) {
        expect(
          engine.proposeExchange(
            from: 0,
            to: 1,
            terms: [
              DiplomacyTerm(
                fromSender: fromSender,
                offer: const DiplomacyOffer(
                  type: DiplomacyExchangeType.militaryAlliance,
                ),
              ),
            ],
          ),
          isFalse,
        );
      }
      expect(state.toJson().toString(), before);
    });
    for (final home in ['empty', 'merge', 'full', 'island']) {
      test('legacy guest returns safely when home is $home', () {
        final state = _transitState();
        state.diplomacyRelations[0][1] = DiplomacyStatus.coalition;
        state.diplomacyRelations[1][0] = DiplomacyStatus.coalition;
        state.diplomacyDebts[1][0] = 47;
        final guest = state.hexes[1].unit!
          ..owner = 0
          ..homeProvinceId = 1;
        state.hexes[1].unit = null;
        state.hexes[2].unit = guest;
        if (home == 'merge' || home == 'full') {
          state.hexes[1].unit = GameUnit(
            strength: home == 'merge' ? 1 : 4,
            owner: 0,
            homeProvinceId: 1,
          );
        }
        if (home == 'island') {
          state.hexes[1].neighbors.remove(2);
          state.hexes[2].neighbors.remove(1);
        }
        final engine = GameEngine(mod: mod, state: state);
        expect(engine.hasMilitaryAccess(0, 1), isFalse);
        expect(engine.diplomacyBetween(0, 1), DiplomacyStatus.peace);
        expect(state.hexes[2].unit, isNull);
        expect(state.hexes[2].object, TileObject.pine);
        expect(state.diplomacyDebts[1][0], 47);
        expect(state.provinces.first.money, home == 'full' ? 120 : 100);
        expect(
          state.hexes[1].unit!.strength,
          home == 'full'
              ? 4
              : home == 'merge'
              ? 3
              : 2,
        );
        final saved = state.toJson().toString();
        GameEngine(mod: mod, state: state);
        expect(
          state.toJson().toString(),
          saved,
          reason: 'migration never refunds twice',
        );
      });
    }
    test('legacy disputed land stays with captor and loses shared claims', () {
      final state = _blocState(3);
      state.hexes[2].coalitionClaim = const CoalitionClaim(
        campaignId: 1,
        originalOwner: 1,
        members: [0, 2],
        captor: 0,
        contributors: [0, 2],
      );
      state.hexes[2].owner = -1;
      final engine = GameEngine(mod: mod, state: state);
      expect(state.hexes[2].owner, 0);
      expect(state.hexes[2].coalitionClaim, isNull);
      expect(engine.provinceAt(2)!.owner, 0);
      expect(state.campaigns, isEmpty);
      expect(state.peaceConferences, isEmpty);
      expect(engine.peaceConferencesFor(0), isEmpty);
    });
  });
}

GameState _blocState(int playerCount) {
  final owners = <int>[
    for (var owner = 0; owner < playerCount; owner++) ...[owner, owner],
  ];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        object: index.isEven ? TileObject.town : TileObject.none,
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  return GameState(
    config: GameConfig(
      playerCount: playerCount,
      humanCount: playerCount,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      for (var owner = 0; owner < playerCount; owner++)
        Province(
          id: owner + 1,
          owner: owner,
          tiles: [owner * 2, owner * 2 + 1],
          money: 100,
          capital: owner * 2,
        ),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: playerCount + 1,
  );
}

GameState _isolatedHoldingState() {
  final state = _blocState(4);
  const owners = [0, 0, 1, -1, 1, 1, 2, 2];
  for (var i = 0; i < state.hexes.length; i++) {
    state.hexes[i]
      ..owner = owners[i]
      ..object = TileObject.none;
  }
  for (final i in [0, 4, 6]) {
    state.hexes[i].object = TileObject.town;
  }
  state.hexes[1].unit = GameUnit(strength: 2, owner: 0, homeProvinceId: 1);
  state.hexes[2].object = TileObject.pine;
  state.provinces
    ..clear()
    ..addAll([
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [4, 5], money: 100, capital: 4),
      Province(id: 3, owner: 2, tiles: [6, 7], money: 100, capital: 6),
    ]);
  return state;
}

GameState _transitState() {
  final owners = <int>[0, 0, 1, 1, 2, 2, 2];
  final hexes = <HexTile>[
    for (var index = 0; index < owners.length; index++)
      HexTile(
        index: index,
        q: index,
        r: 0,
        active: true,
        owner: owners[index],
        neighbors: [
          if (index > 0) index - 1,
          if (index + 1 < owners.length) index + 1,
        ],
      ),
  ];
  hexes[0].object = TileObject.town;
  hexes[1].unit = GameUnit(strength: 2);
  hexes[2]
    ..object = TileObject.pine
    ..treeBorn = 0;
  hexes[3].object = TileObject.town;
  hexes[5].object = TileObject.town;
  return GameState(
    config: const GameConfig(
      playerCount: 3,
      humanCount: 3,
      diplomacy: true,
      seed: 1,
    ),
    modId: 'classic_steppe',
    width: hexes.length,
    height: 1,
    hexes: hexes,
    provinces: [
      Province(id: 1, owner: 0, tiles: [0, 1], money: 100, capital: 0),
      Province(id: 2, owner: 1, tiles: [2, 3], money: 100, capital: 3),
      Province(id: 3, owner: 2, tiles: [4, 5, 6], money: 100, capital: 5),
    ],
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: 4,
  );
}
