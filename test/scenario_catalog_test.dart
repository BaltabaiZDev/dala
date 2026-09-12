import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/scenario_catalog.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('campaign contains fifty deterministic playable scenarios', () async {
    final mod = await GameMod.loadDefault();
    final generator = MapGenerator(mod);

    expect(campaignScenarios, hasLength(50));
    expect(
      campaignScenarios.map((scenario) => scenario.level),
      orderedEquals(List<int>.generate(50, (index) => index + 1)),
    );
    expect(
      campaignScenarios.map((scenario) => scenario.seed).toSet(),
      hasLength(50),
    );
    for (final scenario in campaignScenarios) {
      final config = scenario.toConfig();
      expect(config.playerCount, inInclusiveRange(2, 15));
      expect(config.startingProvinceCount, inInclusiveRange(0, 3));
      expect(config.campaignLevel, scenario.level);

      final state = generator.generate(config);
      final repeatedState = generator.generate(config);
      expect(state.config.seed, scenario.seed);
      expect(state.config.campaignLevel, scenario.level);
      expect(
        EditorRepository.isValidState(
          state,
          expectedModId: mod.id,
          requirePlayable: true,
          rules: mod.rules,
        ),
        isTrue,
        reason: 'Campaign level ${scenario.level} must generate a valid map',
      );
      expect(
        repeatedState.toJson(),
        equals(state.toJson()),
        reason: 'Campaign level ${scenario.level} must be seed-deterministic',
      );
    }
  });

  test('player scenarios are deterministic playable configurations', () async {
    final mod = await GameMod.loadDefault();
    final generator = MapGenerator(mod);

    expect(playerScenarios.length, greaterThanOrEqualTo(10));
    for (final scenario in playerScenarios) {
      final config = scenario.toConfig();
      expect(config.playerCount, inInclusiveRange(2, 15));
      expect(config.humanCount, inInclusiveRange(1, config.playerCount));
      expect(config.seed, greaterThan(0));

      final state = generator.generate(config);
      final repeatedState = generator.generate(config);
      expect(state.config.seed, scenario.seed);
      expect(state.config.campaignLevel, config.campaignLevel);
      expect(
        EditorRepository.isValidState(
          state,
          expectedModId: mod.id,
          requirePlayable: true,
          rules: mod.rules,
        ),
        isTrue,
        reason: 'Player scenario ${scenario.name} must generate a valid map',
      );
      expect(
        repeatedState.toJson(),
        equals(state.toJson()),
        reason: 'Player scenario ${scenario.name} must be seed-deterministic',
      );
    }
  });
}
