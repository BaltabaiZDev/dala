import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/antiyoy_hd_level_importer.dart';
import 'package:antiyoy_self/src/persistence/editor_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameMod mod;

  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });

  test('imports a sparse HD level and remaps humans, state, and diplomacy', () {
    const source =
        'onliyoy_level_code#'
        'client_init:small,-1#'
        'hexes:'
        '0 0 red city -1,1 0 red peasant 7,0 1 red,'
        '2 0 gray pine -1,3 0 gray,'
        '4 0 aqua city -1,5 0 aqua spearman 9,4 1 aqua,#'
        'player_entities:'
        'ai_balancer>red>Bot,human>aqua>Human,#'
        'provinces:2>0<0<0<31<Redland,4<0<1<17<Aqualand,#'
        'ready:5 0,#'
        'rules:def 1#'
        'turn:1 3#'
        'diplomacy:friend red aqua 4,#'
        'fog:true#';

    final state = const AntiyoyHdLevelImporter().decode(
      source,
      mod,
      campaignLevel: 7,
    );

    expect(state, isNotNull);
    final imported = state!;
    expect(imported.config.playerCount, 2);
    expect(imported.config.humanCount, 1);
    expect(imported.config.campaignLevel, 7);
    expect(imported.config.fogOfWar, isTrue);
    expect(imported.config.diplomacy, isTrue);
    expect(imported.config.slayRules, isFalse);
    expect(
      imported.turn,
      0,
      reason: 'the original second entity is now player 0',
    );
    expect(imported.round, 4);
    expect(imported.diplomacyRelations[0][1], DiplomacyStatus.alliance);

    final humanProvince = imported.provinces.singleWhere(
      (province) => province.owner == 0,
    );
    final botProvince = imported.provinces.singleWhere(
      (province) => province.owner == 1,
    );
    expect(humanProvince.id, 1);
    expect(humanProvince.money, 17);
    expect(botProvince.id, 0);
    expect(botProvince.money, 31);
    expect(imported.nextProvinceId, 2);

    final humanUnits = imported.hexes
        .where((tile) => tile.owner == 0 && tile.unit != null)
        .toList();
    final botUnits = imported.hexes
        .where((tile) => tile.owner == 1 && tile.unit != null)
        .toList();
    expect(humanUnits.single.unit!.strength, 2);
    expect(humanUnits.single.unit!.ready, isTrue);
    expect(botUnits.single.unit!.strength, 1);
    expect(botUnits.single.unit!.ready, isFalse);

    expect(imported.waterCells, isNotEmpty);
    final waterTiles = imported.waterCells.expand((cell) => cell.tiles).toSet();
    final expectedWaterTiles = imported.hexes
        .where((tile) => tile.inWorld && !tile.active)
        .map((tile) => tile.index)
        .toSet();
    expect(waterTiles, expectedWaterTiles);
    expect(imported.hexes.where((tile) => !tile.inWorld), isNotEmpty);
    expect(
      EditorRepository.isValidState(
        imported,
        expectedModId: mod.id,
        requirePlayable: true,
        rules: mod.rules,
      ),
      isTrue,
    );
  });

  test('maps HD classic rules to the local Slay ruleset', () {
    final state = const AntiyoyHdLevelImporter().decode(
      _minimalCode.replaceFirst('rules:def 1', 'rules:classic 1'),
      mod,
    );

    expect(state, isNotNull);
    final imported = state!;
    expect(imported.config.slayRules, isTrue);
    expect(imported.config.diplomacy, isFalse);
    expect(
      EditorRepository.isValidState(
        imported,
        expectedModId: mod.id,
        requirePlayable: true,
        rules: mod.rules,
      ),
      isTrue,
    );
  });

  test('rejects malformed, oversized, and unsupported level codes', () {
    const importer = AntiyoyHdLevelImporter();
    expect(importer.decode('not-a-level', mod), isNull);
    expect(
      importer.decode(
        _minimalCode.replaceFirst('rules:def 1', 'rules:duel 1'),
        mod,
      ),
      isNull,
    );
    expect(
      importer.decode(
        _minimalCode.replaceFirst(
          '1 0 aqua,',
          '1 0 aqua unsupported_piece -1,',
        ),
        mod,
      ),
      isNull,
    );
    expect(importer.decode(_sixteenPlayerCode, mod), isNull);
  });
}

const _minimalCode =
    'onliyoy_level_code#'
    'client_init:tiny,-1#'
    'hexes:0 0 aqua city -1,1 0 aqua,4 0 red city -1,5 0 red,#'
    'player_entities:human>aqua>Human,ai_balancer>red>Bot,#'
    'provinces:2>0<0<0<10<Home,4<0<1<10<Away,#'
    'ready:-#'
    'rules:def 1#'
    'turn:0 0#'
    'diplomacy:off#';

const _sixteenPlayerCode =
    'onliyoy_level_code#'
    'hexes:0 0 yellow city -1,1 0 yellow,3 0 green city -1,4 0 green,#'
    'player_entities:'
    'human>yellow>A,ai_balancer>green>B,ai_balancer>aqua>C,'
    'ai_balancer>cyan>D,ai_balancer>blue>E,ai_balancer>purple>F,'
    'ai_balancer>red>G,ai_balancer>brown>H,ai_balancer>mint>I,'
    'ai_balancer>lavender>J,ai_balancer>brass>K,ai_balancer>ice>L,'
    'ai_balancer>rose>M,ai_balancer>algae>N,ai_balancer>orchid>O,'
    'ai_balancer>whiskey>P,#'
    'provinces:2>0<0<0<10<A,3<0<1<10<B,#'
    'ready:-#'
    'rules:def 1#'
    'turn:0 0#'
    'diplomacy:off#';
