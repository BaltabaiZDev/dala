import 'package:antiyoy_self/src/game/diplomacy_ai.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());

  GameState generated(AiDifficulty difficulty, int seed, {bool fog = false}) =>
      MapGenerator(mod).generate(
        GameConfig(
          mapSize: MapSize.small,
          playerCount: 3,
          humanCount: 1,
          difficulty: difficulty,
          seed: seed,
          treePercent: 0,
          fogOfWar: fog,
        ),
      );

  for (final difficulty in AiDifficulty.values) {
    test('${difficulty.name} bonus applies to production and bots only', () {
      final state = generated(difficulty, 401);
      final engine = GameEngine(mod: mod, state: state);
      for (final p in state.provinces) {
        p.money = 1000;
        final sites = p.tiles.where((i) => i != p.capital).toList();
        state.hexes[sites[0]].object = TileObject.farm;
        state.hexes[sites[1]].unit = GameUnit(strength: 2);
      }
      final forecast = DiplomacyAiSnapshot(engine);
      final expected = <int, int>{};
      for (final p in state.provinces) {
        final report = engine.economicBreakdown(p, includeDiplomacy: false);
        final production =
            report.land + report.farms + report.trees + report.modIncome;
        final multiplier = p.owner == 0 ? 100 : difficulty.incomePercent;
        expect(report.aiBonus, production * (multiplier - 100) ~/ 100);
        expect(engine.aiIncomeBonus(p), report.aiBonus);
        expect(report.units, -engine.unitUpkeepAtStrength(2));
        expected[p.id] = 1000 + report.total;
      }
      for (var owner = 0; owner < state.config.playerCount; owner++) {
        final net = engine
            .provincesOf(owner)
            .fold<int>(
              0,
              (sum, p) =>
                  sum +
                  engine.economicBreakdown(p, includeDiplomacy: false).total,
            );
        expect(forecast.net[owner], net);
      }
      for (var i = 0; i < state.config.playerCount; i++) {
        engine.endTurn();
      }
      for (final p in state.provinces) {
        expect(p.money, expected[p.id]);
      }
    });
  }

  test(
    'strong expansion is legal, solvent and identical with frame yielding',
    () async {
      for (final seed in [19, 401, 1802]) {
        final state = generated(AiDifficulty.master, seed, fog: true)..turn = 1;
        final copy = GameState.fromJson(state.toJson());
        final before = state.hexes.where((h) => h.owner == 1).length;
        final sync = GameEngine(mod: mod, state: state);
        final cooperative = GameEngine(mod: mod, state: copy);
        GameAi(mod: mod, engine: sync).takeTurn();
        await GameAi(mod: mod, engine: cooperative).takeTurnAsync();
        expect(copy.toJson(), state.toJson());
        expect(
          state.hexes.where((h) => h.owner == 1).length,
          greaterThan(before),
        );
        expect(sync.provincesOf(1).every((p) => p.money >= 0), isTrue);
        expect(state.turn, 2);
      }
    },
  );

  test(
    'deterministic opening benchmark measures growth at each strong tier',
    () {
      final growth = <String, int>{};
      for (final difficulty in [
        AiDifficulty.hard,
        AiDifficulty.veryHard,
        AiDifficulty.master,
      ]) {
        var total = 0;
        for (final seed in [19, 73, 401, 1802, 6129]) {
          final state = generated(difficulty, seed)..turn = 1;
          final engine = GameEngine(mod: mod, state: state);
          final before = state.hexes.where((h) => h.owner == 1).length;
          for (var round = 0; round < 6 && state.winner == null; round++) {
            GameAi(mod: mod, engine: engine).takeTurn();
            while (state.turn != 1 && state.winner == null) {
              engine.endTurn();
            }
          }
          total += state.hexes.where((h) => h.owner == 1).length - before;
        }
        growth[difficulty.name] = total;
        expect(total, greaterThan(0));
      }
      // A reproducible scenario report, not a claim of win rate against humans.
      // ignore: avoid_print
      print('Six-round land growth across five seeds: $growth');
      expect(growth['master'], greaterThan(growth['hard']!));
    },
  );
}
