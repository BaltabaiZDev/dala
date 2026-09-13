import 'dart:math';
import 'dart:async';

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/lan/lan_state_patch.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());

  GameState fixture() => MapGenerator(mod).generate(
    const GameConfig(
      mapSize: MapSize.small,
      playerCount: 4,
      humanCount: 2,
      seed: 103,
      difficulty: AiDifficulty.normal,
      treePercent: 0,
    ),
  );

  test('new matches mix human and bot seats without changing identities', () {
    final firstSeats = <int>{};
    final permutations = <String>{};
    for (var seed = 0; seed < 80; seed++) {
      final state = fixture()..randomizeTurnOrder(random: Random(seed));
      firstSeats.add(state.turn);
      permutations.add(state.turnOrder.join(','));
      expect(state.turnOrder.toSet(), {0, 1, 2, 3});
      expect(state.turn, state.turnOrder.first);
      expect(state.isHuman(0), isTrue);
      expect(state.isHuman(2), isFalse);
    }
    expect(firstSeats, {0, 1, 2, 3});
    expect(permutations.length, greaterThan(12));
  });
  test(
    'a bot can open the match and hand control to the first human in order',
    () async {
      final state = fixture()
        ..turnOrder = [3, 2, 1, 0]
        ..turn = 3;
      final initialRound = state.round;
      final game = GameController(
        mod: mod,
        state: state,
        saves: SaveRepository(),
        autosaveEnabled: false,
      );
      addTearDown(game.dispose);
      final complete = Completer<void>();
      game.addListener(() {
        if (!game.aiThinking &&
            state.currentPlayerIsHuman &&
            !complete.isCompleted) {
          complete.complete();
        }
      });
      await complete.future.timeout(const Duration(seconds: 15));
      expect(state.turn, 1);
      expect(state.round, initialRound);
      expect(state.turnOrder, [3, 2, 1, 0]);
      expect(game.visibilityPlayer, 1);
    },
  );

  test(
    'round and income settle once at order boundary, skipping dead seats',
    () {
      final state = fixture()
        ..turnOrder = [2, 0, 3, 1]
        ..turn = 2;
      final engine = GameEngine(mod: mod, state: state);
      final cash = {for (final p in state.provinces) p.id: p.money};
      final income = {
        for (final p in state.provinces)
          p.id: engine.economicBreakdown(p, includeDiplomacy: false).total,
      };
      final round = state.round;
      for (final next in [0, 3, 1]) {
        engine.endTurn();
        expect(state.turn, next);
        expect(state.round, round);
        for (final p in state.provinces) {
          expect(p.money, cash[p.id]);
        }
      }
      engine.endTurn();
      expect(state.turn, 2);
      expect(state.round, round + 1);
      for (final p in state.provinces) {
        expect(p.money, cash[p.id]! + income[p.id]!);
      }

      for (final tile in state.hexes.where((tile) => tile.owner == 2)) {
        tile.owner = -1;
        tile.unit = null;
      }
      state.provinces.removeWhere((p) => p.owner == 2);
      state.turn = 1;
      engine.endTurn();
      expect(state.turn, 0);
      expect(state.round, round + 2);
    },
  );

  test(
    'save and LAN patch keep the same order; legacy saves remain sequential',
    () {
      final state = fixture()
        ..turnOrder = [3, 0, 2, 1]
        ..turn = 3;
      expect(GameState.fromJson(state.toJson()).turnOrder, [3, 0, 2, 1]);
      final legacy = state.toJson()..remove('turnOrder');
      expect(GameState.fromJson(legacy).turnOrder, [0, 1, 2, 3]);
      for (final bad in [
        [0, 0, 2, 3],
        [0, 1, 2],
        [0, 1, 2, 4],
      ]) {
        expect(
          () => GameState.fromJson(state.toJson()..['turnOrder'] = bad),
          throwsFormatException,
        );
      }
      final snapshot = state.toJson();
      final client = GameController(
        mod: mod,
        state: GameState.fromJson(snapshot),
        saves: SaveRepository(),
        authoritativeSimulation: false,
        autosaveEnabled: false,
        localPlayer: 0,
        networkRole: GameNetworkRole.client,
      );
      addTearDown(client.dispose);
      final builder = LanStatePatchBuilder()..prime(state);
      state.turnOrder = [2, 1, 3, 0];
      state.turn = 2;
      final patch = builder.build(state)!;
      applyLanPatchToJson(snapshot, patch);
      client.applyStatePatchFromNetwork(patch);
      expect(GameState.fromJson(snapshot).turnOrder, state.turnOrder);
      expect(client.state.turnOrder, state.turnOrder);
      expect(client.state.turn, state.turn);
    },
  );
}
