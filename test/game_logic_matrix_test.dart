import 'dart:convert';

import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/ui/diplomacy_overview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());

  for (final slay in [false, true]) {
    for (final seed in [1907, 20260912, 73]) {
      test(
        'seed=$seed slay=$slay preserves economy and ownership over 60 turns',
        () {
          var engine = GameEngine(
            mod: mod,
            state: MapGenerator(mod).generate(
              GameConfig(
                mapSize: MapSize.small,
                playerCount: 4,
                humanCount: 0,
                seed: seed,
                difficulty: AiDifficulty.hard,
                diplomacy: true,
                slayRules: slay,
              ),
            ),
          );
          // Seed a military war as well as normal AI diplomacy, so the audit
          // exercises combat and shared borders from the first turn.
          engine.setDiplomacyStatus(0, 1, DiplomacyStatus.coalition);
          engine.setDiplomacyStatus(2, 3, DiplomacyStatus.coalition);
          expect(engine.declareWar(0, 2), isTrue);
          for (var turn = 0; turn < 60 && engine.state.winner == null; turn++) {
            GameAi(mod: mod, engine: engine).takeTurn();
            final state = engine.state;
            final context =
                'seed=$seed slay=$slay turn=$turn round=${state.round}';
            // Runtime permits cut-off troops until their next owner turn;
            // editor-map validation deliberately rejects those transient
            // pieces. Check live-game invariants and exact save round-trips.
            final owned = <int>{};
            for (final province in state.provinces) {
              expect(province.money, greaterThanOrEqualTo(0), reason: context);
              expect(
                province.tiles,
                contains(province.capital),
                reason: context,
              );
              expect(
                province.navalCapital || province.tiles.length >= 2,
                isTrue,
                reason: context,
              );
              for (final tile in province.tiles) {
                expect(owned.add(tile), isTrue, reason: context);
                expect(
                  state.hexes[tile].owner,
                  province.owner,
                  reason: context,
                );
                expect(
                  state.hexes[tile].coalitionClaim,
                  isNull,
                  reason: context,
                );
              }
            }
            final homes = {for (final p in state.provinces) p.id: p.owner};
            for (final tile in state.hexes.where((t) => t.unit != null)) {
              expect(
                homes[tile.unit!.homeProvinceId],
                tile.unit!.owner,
                reason: context,
              );
            }
            for (final cell in state.waterCells.where((c) => c.boat != null)) {
              final boat = cell.boat!;
              expect(homes[boat.homeProvinceId], boat.owner, reason: context);
              for (final unit in boat.cargo) {
                expect(
                  unit.homeProvinceId,
                  boat.homeProvinceId,
                  reason: context,
                );
                expect(unit.owner, boat.owner, reason: context);
              }
            }
            final reports = state.provinces
                .map(
                  (p) => engine.economicBreakdown(p, includeDiplomacy: false),
                )
                .toList();
            final unitCost = state.hexes
                .where((t) => t.unit != null)
                .fold(
                  0,
                  (sum, t) =>
                      sum + engine.unitUpkeepAtStrength(t.unit!.strength),
                );
            expect(
              reports.fold(0, (sum, r) => sum + r.landUnits),
              -unitCost,
              reason: context,
            );
            for (var a = 0; a < 4; a++) {
              for (var b = 0; b < 4; b++) {
                expect(
                  state.diplomacyRelations[a][b],
                  state.diplomacyRelations[b][a],
                  reason: context,
                );
                if (a != b && engine.hasMilitaryAccess(a, b)) {
                  expect(engine.areEnemies(a, b), isFalse, reason: context);
                }
              }
            }
            if (turn % 10 == 0) {
              final snapshot = jsonEncode(state.toJson());
              engine = GameEngine(
                mod: mod,
                state: GameState.fromJson(jsonDecode(snapshot)),
              );
              expect(
                jsonEncode(engine.state.toJson()),
                snapshot,
                reason: context,
              );
            }
          }
        },
      );
    }
  }

  for (final diplomacy in [false, true]) {
    for (final abandoned in [false, true]) {
      test(
        'unowned or defeated land stays capturable diplomacy=$diplomacy abandoned=$abandoned',
        () {
          final raw = _state([0, 0, abandoned ? 1 : -1, null, 2, 2]).toJson();
          (raw['config'] as Map)['diplomacy'] = diplomacy;
          final state = GameState.fromJson(raw);
          final engine = GameEngine(mod: mod, state: state);
          state.hexes[1].unit = GameUnit(
            strength: 1,
            owner: 0,
            homeProvinceId: 1,
          );
          expect(engine.moveUnit(1, 2), isTrue);
          expect(state.hexes[2].owner, 0);
        },
      );
    }
  }

  test('a cached attack cannot outlive a peace treaty', () {
    final state = _state([0, 0, 1, 1, 2, 2]);
    final engine = GameEngine(mod: mod, state: state);
    state.hexes[1].unit = GameUnit(strength: 2, owner: 0, homeProvinceId: 1);
    expect(engine.declareWar(0, 1), isTrue);
    final targets = engine.moveTargets(1);
    expect(targets, contains(2));
    expect(engine.makePeace(0, 1), isTrue);
    final before = jsonEncode(state.toJson());
    expect(engine.moveUnit(1, 2, knownTargets: targets), isFalse);
    expect(jsonEncode(state.toJson()), before);
  });

  for (final action in ['march', 'recruit', 'land']) {
    test('$action destroys the captured artillery ammunition too', () {
      final state = _state([0, 0, 1, 1, 1, 2, 2]);
      final engine = GameEngine(mod: mod, state: state);
      state.hexes[3].object = TileObject.artillery1;
      state.hexes[3].artilleryAmmo = 2;
      state.hexes[3].artilleryCooldown = 1;
      state.hexes[1].unit = GameUnit(strength: 2, owner: 0, homeProvinceId: 1);
      state.hexes[1].neighbors.add(3);
      state.hexes[3].neighbors.add(1);
      state.waterCells[0].coastTiles.add(3);
      state.waterCells[0].boat = GameBoat(
        owner: 0,
        level: 1,
        homeProvinceId: 1,
        cargo: [GameUnit(strength: 2, owner: 0, homeProvinceId: 1)],
      );
      expect(engine.declareWar(0, 1), isTrue);
      expect(switch (action) {
        'march' => engine.moveUnit(1, 3),
        'recruit' => engine.buyUnit(1, 3, 2),
        _ => engine.disembarkUnit(0, 0, 3),
      }, isTrue);
      expect(state.hexes[3].artilleryAmmo, 0);
      expect(state.hexes[3].artilleryCooldown, 0);
    });
  }

  test('landing restores supply to an owned one-hex outpost', () {
    final state = _state([0, 0, null, 0, null, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final cell = state.waterCells[0]..coastTiles.add(3);
    cell.boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: 1,
      cargo: [GameUnit(strength: 1, owner: 0, homeProvinceId: 1)],
    );
    expect(engine.disembarkUnit(0, 0, 3), isTrue);
    expect(engine.provinceAt(3)?.navalCapital, isTrue);
    expect(state.hexes[3].unit?.homeProvinceId, engine.provinceAt(3)?.id);
    expect(cell.boat!.supportedTiles, [3]);
  });

  for (final slay in [false, true]) {
    for (final relation in DiplomacyStatus.values) {
      for (final holding in ['province', 'orphan', 'bridgehead', 'claim']) {
        for (final action in ['march', 'recruit', 'land']) {
          test('$action / $holding / ${relation.name} / slay=$slay', () {
            final state = _state([0, 0, 1, 1, 2, 2], slay: slay);
            final engine = GameEngine(mod: mod, state: state);
            engine.setDiplomacyStatus(0, 1, relation);
            state.hexes[2].object = TileObject.none;
            if (holding != 'province') {
              state.provinces[1].tiles.remove(2);
              state.provinces[1].capital = 3;
              state.hexes[3].object = TileObject.town;
            }
            if (holding == 'bridgehead') {
              state.provinces.add(
                Province(
                  id: 10,
                  owner: 1,
                  tiles: [2],
                  money: 0,
                  capital: 2,
                  navalCapital: true,
                  navalFounded: true,
                ),
              );
              state.hexes[2].unit = GameUnit(
                strength: 1,
                owner: 1,
                homeProvinceId: 10,
              );
              state.waterCells.add(
                WaterCell(
                  index: 1,
                  tiles: [],
                  coastTiles: [2],
                  boat: GameBoat(
                    owner: 1,
                    level: 1,
                    homeProvinceId: 2,
                    supportedTiles: [2],
                  ),
                ),
              );
            }
            if (holding == 'claim') {
              state.hexes[2].coalitionClaim = CoalitionClaim(
                campaignId: 1,
                originalOwner: 2,
                members: [1],
                captor: 1,
              );
            }
            state.hexes[1].unit = GameUnit(
              strength: 2,
              owner: 0,
              homeProvinceId: 1,
            );
            state.waterCells[0].coastTiles.add(2);
            state.waterCells[0].boat = GameBoat(
              owner: 0,
              level: 1,
              homeProvinceId: 1,
              cargo: [GameUnit(strength: 2, owner: 0, homeProvinceId: 1)],
            );
            final permitted =
                relation == DiplomacyStatus.war ||
                (relation == DiplomacyStatus.coalition &&
                    action != 'recruit' &&
                    holding != 'bridgehead');
            final result = switch (action) {
              'march' => engine.moveUnit(1, 2),
              'recruit' => engine.buyUnit(1, 2, 2),
              _ => engine.disembarkUnit(0, 0, 2),
            };
            expect(result, permitted);
            if (relation != DiplomacyStatus.war) {
              expect(state.hexes[2].owner, 1);
            }
          });
        }
      }
    }
  }

  // All six choices of declarer/target, and both directions of debt, for
  // each possible two-country bloc among three sovereign countries.
  for (final bloc in [
    [0, 1],
    [0, 2],
    [1, 2],
  ]) {
    for (var attacker = 0; attacker < 3; attacker++) {
      for (var defender = 0; defender < 3; defender++) {
        if (attacker == defender) continue;
        test('debt survives bloc=$bloc declaration=$attacker->$defender', () {
          final state = _state([0, 0, 1, 1, 2, 2]);
          var engine = GameEngine(mod: mod, state: state);
          expect(engine.formMilitaryAlliance(bloc[0], bloc[1]), isTrue);
          for (var payer = 0; payer < 3; payer++) {
            for (var receiver = 0; receiver < 3; receiver++) {
              if (payer != receiver) state.diplomacyDebts[payer][receiver] = 7;
            }
          }
          final ownBloc = bloc.contains(attacker) && bloc.contains(defender);
          expect(engine.canDeclareWar(attacker, defender), !ownBloc);
          final before = jsonEncode(state.toJson());
          expect(engine.declareWar(attacker, defender), !ownBloc);
          if (ownBloc) {
            expect(jsonEncode(state.toJson()), before);
            return;
          }
          for (final debts in state.diplomacyDebts) {
            expect(debts.where((debt) => debt == 7), hasLength(2));
          }
          engine = GameEngine(
            mod: mod,
            state: GameState.fromJson(state.toJson()),
          );
          _round(engine);
          for (var payer = 0; payer < 3; payer++) {
            for (var receiver = 0; receiver < 3; receiver++) {
              if (payer == receiver) continue;
              final atWar = engine.areEnemies(payer, receiver);
              expect(
                engine.state.diplomacyDebts[payer][receiver],
                atWar ? 7 : 0,
              );
              final overview = DiplomacyOverview.fromState(
                engine.state,
                payer,
                receiver,
              );
              if (atWar) {
                expect(overview.obligations, hasLength(2));
                expect(
                  overview.obligations.first.description,
                  contains('Бітімнен кейін'),
                );
                expect(engine.playerEconomicBreakdown(payer).diplomacy, 0);
              }
            }
          }
          expect(engine.makePeace(attacker, defender), isTrue);
          _round(engine);
          expect(
            engine.state.diplomacyDebts.expand((row) => row),
            everyElement(0),
          );
        });
      }
    }
  }

  test('ordinary friendship cannot create an undeclared third-party war', () {
    final state = _state([0, 0, 1, 1, 2, 2, 3, 3]);
    final engine = GameEngine(mod: mod, state: state);
    expect(engine.formMilitaryAlliance(2, 3), isTrue);
    engine.setDiplomacyStatus(1, 2, DiplomacyStatus.alliance);
    state.diplomacyWarCooldowns[0][2] = 6;
    state.diplomacyWarCooldowns[2][0] = 6;
    expect(engine.declareWar(0, 1), isTrue);
    expect(engine.areEnemies(0, 2), isFalse);
    expect(engine.areEnemies(0, 3), isFalse);
    expect(engine.diplomacyCooldown(0, 2), 6);
    expect(state.campaigns.single.sideB, [1]);
  });

  test('a host cannot buy upgrades for a visiting allied army', () {
    final state = _state([0, 0, 1, 1, 2, 2]);
    final engine = GameEngine(mod: mod, state: state);
    expect(engine.formMilitaryAlliance(0, 1), isTrue);
    state.hexes[1].unit = GameUnit(strength: 1, owner: 1, homeProvinceId: 2);
    final before = jsonEncode(state.toJson());
    expect(engine.buyUnit(1, 1, 1), isFalse);
    expect(jsonEncode(state.toJson()), before);
  });

  test('losing an inland supply tile preserves the still-connected coast', () {
    final state = _state([0, 0, null, -1, -1, -1, null, 1, 1]);
    final engine = GameEngine(mod: mod, state: state);
    final cell = state.waterCells[0]..coastTiles.add(3);
    cell.boat = GameBoat(
      owner: 0,
      level: 1,
      homeProvinceId: 1,
      cargo: List.generate(
        3,
        (_) => GameUnit(strength: 1, owner: 0, homeProvinceId: 1),
      ),
    );
    for (final target in [3, 4, 5]) {
      expect(engine.disembarkUnit(0, 0, target), isTrue);
    }
    expect(engine.declareWar(1, 0), isTrue);
    state.turn = 1;
    state.hexes[8].neighbors.add(4);
    state.hexes[4].neighbors.add(8);
    state.hexes[8].unit = GameUnit(strength: 2, owner: 1, homeProvinceId: 2);
    expect(engine.moveUnit(8, 4), isTrue);
    expect(cell.boat!.supportedTiles, [3]);
    expect(engine.provinceAt(3)?.navalCapital, isTrue);
    expect(engine.economicBreakdown(engine.provinceAt(3)!).navalSupport, 4);
    expect(engine.provinceAt(5), isNull);
  });

  for (final relation in DiplomacyStatus.values) {
    for (final targetKind in ['boat', 'fort']) {
      test('sea attack $targetKind respects ${relation.name}', () {
        final state = _state([0, 0, 1, 1]);
        final engine = GameEngine(mod: mod, state: state);
        engine.setDiplomacyStatus(0, 1, relation);
        state.waterCells[0].neighbors.add(1);
        state.waterCells[0].boat = GameBoat(
          owner: 0,
          level: 2,
          homeProvinceId: 1,
        );
        state.waterCells.add(
          WaterCell(
            index: 1,
            tiles: [],
            neighbors: [0],
            boat: targetKind == 'boat'
                ? GameBoat(owner: 1, level: 1, homeProvinceId: 2)
                : null,
            seaFort: targetKind == 'fort'
                ? SeaFort(owner: 1, homeProvinceId: 2)
                : null,
          ),
        );
        expect(engine.moveBoat(0, 1), relation == DiplomacyStatus.war);
      });
    }
  }

  for (final travel in ['march', 'land']) {
    test('$travel home from ally changes funding immediately', () {
      final state = _state([0, 0, 1, 1, 0, 0, 2, 2]);
      final engine = GameEngine(mod: mod, state: state);
      expect(engine.formMilitaryAlliance(0, 1), isTrue);
      state.hexes[3].unit = GameUnit(strength: 1, owner: 0, homeProvinceId: 1);
      if (travel == 'land') {
        state.hexes[3].unit = null;
        state.waterCells[0].coastTiles.add(5);
        state.waterCells[0].boat = GameBoat(
          owner: 0,
          level: 1,
          homeProvinceId: 1,
          cargo: [GameUnit(strength: 1, owner: 0, homeProvinceId: 1)],
        );
      }
      final moved = travel == 'march'
          ? engine.moveUnit(3, 5)
          : engine.disembarkUnit(0, 0, 5);
      expect(moved, isTrue);
      expect(state.hexes[5].unit?.homeProvinceId, engine.provinceAt(5)!.id);
      expect(engine.economicBreakdown(engine.provinceAt(0)!).landUnits, 0);
      expect(
        engine.economicBreakdown(engine.provinceAt(5)!).landUnits,
        -mod.rules.unitUpkeep[1],
      );
      final before = engine.playerEconomicBreakdown(0).total;
      engine.rebuildProvinces();
      expect(engine.playerEconomicBreakdown(0).total, before);
    });
  }

  test('boarding adopts ship funding before landing on allied territory', () {
    final state = _state([0, 0, 1, 1, 0, 0, 2, 2]);
    final engine = GameEngine(mod: mod, state: state);
    expect(engine.formMilitaryAlliance(0, 1), isTrue);
    state.hexes[5].unit = GameUnit(strength: 2, owner: 0, homeProvinceId: 3);
    final cell = state.waterCells[0]..coastTiles.addAll([3, 5]);
    cell.boat = GameBoat(owner: 0, level: 1, homeProvinceId: 1);
    expect(engine.boardUnit(5, 0), isTrue);
    expect(cell.boat!.cargo.single.homeProvinceId, 1);
    cell.boat!.cargo.single.ready = true;
    expect(engine.disembarkUnit(0, 0, 3), isTrue);
    expect(state.hexes[3].unit!.homeProvinceId, 1);
  });

  test(
    'recruiting into another province ship uses its cargo budget immediately',
    () {
      final state = _state([0, 0, null, 0, 0, null, 1, 1]);
      final engine = GameEngine(mod: mod, state: state);
      final cell = state.waterCells[0]..coastTiles.add(4);
      cell.boat = GameBoat(
        id: state.nextNavalEntityId++,
        owner: 0,
        level: 1,
        homeProvinceId: 1,
      );
      expect(engine.declareWar(0, 1), isTrue);
      expect(engine.buyUnitIntoBoat(2, 0, 1), isTrue);
      expect(cell.boat!.cargo.single.homeProvinceId, 1);
      expect(engine.economicBreakdown(engine.provinceAt(0)!).cargoUnits, -3);
      expect(engine.economicBreakdown(engine.provinceAt(4)!).cargoUnits, 0);
      final saved = jsonEncode(state.toJson());
      final restored = GameEngine(
        mod: mod,
        state: GameState.fromJson(jsonDecode(saved)),
      );
      expect(jsonEncode(restored.state.toJson()), saved);
    },
  );

  test('round settlement is independent of province iteration order', () {
    final outcomes = <String>[];
    for (final reverse in [false, true]) {
      final state = _state([0, 0, null, -1, -1, -1, -1, null, 1, 1]);
      final engine = GameEngine(mod: mod, state: state);
      final cell = state.waterCells[0]..coastTiles.add(3);
      cell.boat = GameBoat(
        owner: 0,
        level: 1,
        homeProvinceId: 1,
        cargo: List.generate(
          4,
          (_) => GameUnit(strength: 1, owner: 0, homeProvinceId: 1),
        ),
      );
      for (var target = 3; target <= 6; target++) {
        expect(engine.disembarkUnit(0, 0, target), isTrue);
      }
      engine.provinceAt(0)!.money = 0;
      final landingId = engine.provinceAt(3)!.id;
      if (reverse) state.provinces = state.provinces.reversed.toList();
      _round(engine);
      final landing = state.provinces.singleWhere((p) => p.id == landingId);
      outcomes.add(
        jsonEncode({
          'money': landing.money,
          'units': landing.tiles
              .where((t) => state.hexes[t].unit != null)
              .length,
          'naval': landing.navalCapital,
          'ship': cell.boat != null,
        }),
      );
    }
    expect(outcomes[0], outcomes[1]);
    expect(jsonDecode(outcomes[0])['units'], 3);
  });
}

void _round(GameEngine engine) {
  final round = engine.state.round;
  while (engine.state.round == round) {
    engine.endTurn();
  }
}

GameState _state(List<int?> owners, {bool slay = false}) {
  final hexes = [
    for (var i = 0; i < owners.length; i++)
      HexTile(
        index: i,
        q: i,
        r: 0,
        active: owners[i] != null,
        owner: owners[i] ?? -1,
        neighbors: [
          if (i > 0 && owners[i - 1] != null) i - 1,
          if (i + 1 < owners.length && owners[i + 1] != null) i + 1,
        ],
      ),
  ];
  final provinces = <Province>[];
  for (var start = 0; start < owners.length;) {
    final owner = owners[start];
    var end = start + 1;
    while (end < owners.length && owners[end] == owner) {
      end++;
    }
    if (owner != null && owner >= 0 && end - start >= 2) {
      hexes[start].object = TileObject.town;
      provinces.add(
        Province(
          id: provinces.length + 1,
          owner: owner,
          tiles: [for (var i = start; i < end; i++) i],
          money: 100,
          capital: start,
        ),
      );
    }
    start = end;
  }
  final count = owners.whereType<int>().fold(
    0,
    (max, p) => p >= max ? p + 1 : max,
  );
  return GameState(
    config: GameConfig(
      playerCount: count,
      humanCount: count,
      diplomacy: true,
      slayRules: slay,
    ),
    modId: 'classic_steppe',
    width: owners.length,
    height: 1,
    hexes: hexes,
    waterCells: [WaterCell(index: 0, tiles: [], coastTiles: [])],
    provinces: provinces,
    turn: 0,
    round: 1,
    rngState: 1,
    nextProvinceId: provinces.length + 1,
  );
}
