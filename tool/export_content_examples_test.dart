import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/modding/example_mod.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export playable community-content examples', () async {
    final base = await GameMod.loadDefault();
    final technology = createExampleMod(base);
    await Directory('examples/technologies-source').create(recursive: true);
    await File(
      'examples/mods/dala-technologies.dalamod',
    ).writeAsBytes(ContentPackage(mod: technology).encode());
    await File('examples/technologies-source/mod.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'dala-mod',
        'version': 4,
        'mod': technology.toJson(),
      }),
    );
    final raw = base.toJson()
      ..['id'] = 'molshylyk'
      ..['name'] = 'Молшылық'
      ..['title'] = 'Молшылық'
      ..['author'] = 'DALA'
      ..['description'] =
          'Ферманың табысы 7, бастапқы қазына 30. Мод жасауға арналған үлгі.';
    (raw['rules'] as Map)
      ..['farmIncome'] = 7
      ..['initialMoney'] = 30;
    final mod = GameMod.fromJson(raw);
    const config = GameConfig(
      mapSize: MapSize.small,
      playerCount: 3,
      humanCount: 1,
      treePercent: 45,
      seed: 20260912,
      diplomacy: true,
    );
    final map = DalaMap.fromState(
      'Молшылық аралдары',
      MapGenerator(mod).generate(config),
      mod,
    );
    await Directory('examples/mods').create(recursive: true);
    await Directory('examples/maps').create(recursive: true);
    await Directory('examples/molshylyk-source').create(recursive: true);
    await File(
      'examples/mods/molshylyk.dalamod',
    ).writeAsBytes(ContentPackage(mod: mod, maps: [map]).encode());
    await File('examples/molshylyk-source/mod.json').writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'format': 'dala-mod', 'version': 1, 'mod': mod.toJson()}),
    );
    final normal = DalaMap.fromState(
      'Үш жағалау',
      MapGenerator(base).generate(config),
      base,
    );
    await File(
      'examples/maps/ush-zhagalau.dalamap',
    ).writeAsBytes(normal.encode());
    expect(
      ContentPackage.decode(
        await File('examples/mods/molshylyk.dalamod').readAsBytes(),
      ).maps.single.name,
      map.name,
    );
    expect(
      DalaMap.decode(
        await File('examples/maps/ush-zhagalau.dalamap').readAsBytes(),
      ).createState(base).modId,
      base.id,
    );
  });
}
