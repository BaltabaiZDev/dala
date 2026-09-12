import 'dart:convert';
import 'package:antiyoy_self/src/game/diplomacy_ai.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/game_ai.dart';
import 'package:antiyoy_self/src/game/turn_replay.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/match_replay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'strategic_diplomacy_test.dart' show strategicFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());

  test(
    'concealed AI turns are recorded without publishing hidden UI moves',
    () async {
      final raw = strategicFixture().toJson();
      (raw['config'] as Map)['fogOfWar'] = true;
      raw['turn'] = 0;
      final state = GameState.fromJson(raw);
      expect(state.config.fogOfWar, isTrue);
      final controller = GameController(
        mod: mod,
        state: state,
        saves: SaveRepository(),
        autosaveEnabled: false,
      );
      addTearDown(controller.dispose);
      state.turn = 1;
      final recorder = MatchRecorder(state);
      void capture() => recorder.capture(state);
      controller.addListener(capture);
      controller.turnCompleted.addListener(capture);
      await controller.runAiTurns();
      expect(recorder.frames.map((frame) => frame['turn']), [1, 2, 0]);
      expect(recorder.statistics.turns, 2);
    },
  );

  test(
    'giant 15 colors 100 percent forest 45 provinces starts and runs a round',
    () {
      final state = MapGenerator(mod).generate(
        const GameConfig(
          mapSize: MapSize.giant,
          playerCount: 15,
          humanCount: 1,
          treePercent: 100,
          startingProvinceCount: 3,
          seed: 20260903,
          difficulty: AiDifficulty.hard,
          diplomacy: true,
        ),
      );
      expect(state.provinces.length, 45);
      expect(state.hexes.where((t) => t.hasTree).length, greaterThan(1500));
      final e = GameEngine(mod: mod, state: state);
      final frames = TurnReplayFrames(state);
      e.endTurn();
      frames.captureTurn(state);
      while (!state.currentPlayerIsHuman && state.winner == null) {
        GameAi(mod: mod, engine: e).takeTurn();
        frames.captureTurn(state);
      }
      expect(state.turn, 0);
      expect(state.round, 2);
      expect(frames.length, 16);
      expect(frames.first['turn'], 0);
      expect(frames[1]['turn'], 1);
      expect(GameState.fromJson(frames.last).round, 2);
    },
  );

  test('capital alone is not appraised as the entire seller province', () {
    final state = strategicFixture();
    state.provinces[1].money = 500;
    final e = GameEngine(mod: mod, state: state);
    final terms = [
      DiplomacyTerm(
        fromSender: true,
        offer: DiplomacyOffer(
          type: DiplomacyExchangeType.lands,
          tiles: [state.provinces[0].capital],
        ),
      ),
      const DiplomacyTerm(
        fromSender: false,
        offer: DiplomacyOffer(type: DiplomacyExchangeType.money, amount: 100),
      ),
    ];
    expect(e.exchangeValidationError(0, 1, terms), isNull);
    expect(StrategicDiplomacyAi(e).utility(1, 0, 1, terms), lessThan(0));
    expect(
      StrategicDiplomacyAi(e).utility(1, 0, 1, [terms.first]),
      greaterThan(0),
    );
  });

  test('military treaty expires to friendship, round-trip preserves timer', () {
    final state = strategicFixture(humans: 3);
    final e = GameEngine(mod: mod, state: state);
    expect(e.formMilitaryAlliance(0, 1, duration: 1), isTrue);
    final copy = GameState.fromJson(jsonDecode(jsonEncode(state.toJson())));
    expect(copy.diplomacyAllianceTurns[0][1], 1);
    final initialRound = state.round;
    while (state.round == initialRound) {
      e.endTurn();
    }
    expect(e.diplomacyBetween(0, 1), DiplomacyStatus.alliance);
    expect(e.allianceTurnsLeft(0, 1), 6);
    expect(e.hasMilitaryAccess(0, 1), isFalse);
  });

  test('draft choices hide impossible relations and mixed transitions', () {
    final e = GameEngine(mod: mod, state: strategicFixture(humans: 3));
    expect(
      e.canChooseExchangeType(0, 1, DiplomacyExchangeType.ceasefire, []),
      isFalse,
    );
    expect(
      e.canChooseExchangeType(0, 1, DiplomacyExchangeType.removeBlackMark, []),
      isFalse,
    );
    const selected = [
      DiplomacyTerm(
        fromSender: true,
        offer: DiplomacyOffer(
          type: DiplomacyExchangeType.friendship,
          duration: 6,
        ),
      ),
    ];
    expect(
      e.canChooseExchangeType(
        0,
        1,
        DiplomacyExchangeType.militaryAlliance,
        selected,
      ),
      isFalse,
    );
    expect(
      e.canChooseExchangeType(
        0,
        1,
        DiplomacyExchangeType.warDeclaration,
        selected,
      ),
      isFalse,
    );
    expect(
      e.canChooseExchangeType(0, 1, DiplomacyExchangeType.money, selected),
      isTrue,
    );
    expect(e.declareWar(0, 1), isTrue);
    expect(
      e.canChooseExchangeType(0, 1, DiplomacyExchangeType.friendship, []),
      isFalse,
    );
  });

  test('strong human can receive a funded material concession for a pact', () {
    final state = strategicFixture();
    final e = GameEngine(mod: mod, state: state);
    for (final tile
        in state.hexes
            .where((t) => t.owner == 0 && t.object == TileObject.none)
            .take(5)) {
      tile.unit = GameUnit(strength: 4, owner: 0);
    }
    final plans = StrategicDiplomacyAi(e)
        .plansFor(1, 0)
        .where((p) => p.tactic == DiplomacyTactic.secureBorder)
        .toList();
    expect(plans, isNotEmpty);
    expect(
      plans.any(
        (p) => p.terms.any(
          (t) =>
              t.fromSender &&
              t.offer.type == DiplomacyExchangeType.money &&
              t.offer.amount > 0,
        ),
      ),
      isTrue,
    );
  });

  test('hundreds of actions do not evict the opening replay turns', () {
    final state = strategicFixture();
    final recorder = MatchRecorder(state);
    for (var i = 0; i < 250; i++) {
      state.provinces.first.money++;
      recorder.capture(state);
    }
    expect(recorder.frames.length, 1);
    state.turn = 2;
    recorder.capture(state);
    expect(recorder.frames.length, 2);
    expect(recorder.frames.first['turn'], 1);
    expect(recorder.frames.last['turn'], 2);
  });

  test(
    'turn patches retain every turn beyond old limit and decode independently',
    () {
      final state = strategicFixture();
      final frames = TurnReplayFrames(state);
      final original = jsonEncode(state.toJson());
      for (var i = 1; i <= 260; i++) {
        state.turn = i % 3;
        state.round = 10 + i ~/ 3;
        state.provinces.first.money = 100 + i;
        frames.captureTurn(state);
      }
      expect(frames.length, 261);
      expect(jsonEncode(frames.first), original);
      for (final i in [1, 32, 259, 4, 260]) {
        final restored = GameState.fromJson(frames[i]);
        expect(restored.provinces.first.money, 100 + i);
        expect(restored.turn, i % 3);
      }
      expect(frames.encodedBytes, lessThan(original.length * frames.length));
    },
  );
}
