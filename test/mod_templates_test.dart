import 'dart:convert';
import 'dart:io';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/example_mod.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base;
  setUpAll(() async => base = await GameMod.loadDefault());

  Map<String, dynamic> definition(String template) => {
    'id': 'test.$template',
    'name': template,
    'price': 30,
    'template': template,
  };
  GameMod parse(List<Map<String, dynamic>> buildings, {List? units}) =>
      GameMod.fromJson(
        base.toJson()
          ..addAll({'id': 'test', 'buildings': buildings, 'units': ?units}),
      );

  test(
    'all five templates retain their gameplay role through package import',
    () {
      final mod = parse([
        definition('radar')..['vision'] = 8,
        definition('mine')..['income'] = 8,
        definition('fortification')..['defense'] = 3,
        definition('barracks')
          ..['production'] = [
            {'id': 'test.scout', 'name': 'Scout', 'price': 15},
          ],
        definition('airfield')
          ..['production'] = [
            {
              'id': 'test.plane',
              'name': 'Plane',
              'price': 40,
              'movement': 'air',
            },
          ],
      ]);
      final decoded = ContentPackage.decode(
        ContentPackage(mod: mod).encode(),
      ).mod;
      expect(decoded.fingerprint, mod.fingerprint);
      expect(
        decoded.buildings.values.map((b) => b.template).toSet(),
        ModBuildingTemplate.values.toSet(),
      );
      expect(decoded.units['test.plane']!.requiresBuilding, 'test.airfield');
      expect(decoded.units['test.scout']!.requiresBuilding, 'test.barracks');
    },
  );

  test(
    'template boundaries reject mixed powers, wrong products and scripts',
    () {
      for (final building in [
        definition('radar')..['income'] = 1,
        definition('mine')..['defense'] = 3,
        definition('fortification')..['vision'] = 7,
        definition('airfield')..['income'] = 5,
        definition('barracks')..['vision'] = 5,
        definition('teleporter'),
        definition('radar')..['script'] = 'arbitrary code',
        definition('radar')
          ..['production'] = [
            {'id': 'test.scout', 'name': 'Scout', 'price': 10},
          ],
        definition('barracks')
          ..['production'] = [
            {
              'id': 'test.plane',
              'name': 'Plane',
              'price': 10,
              'movement': 'air',
            },
          ],
        definition('airfield')
          ..['production'] = [
            {'id': 'test.scout', 'name': 'Scout', 'price': 10},
          ],
      ]) {
        expect(
          () => parse([building]),
          throwsFormatException,
          reason: '$building',
        );
      }
      expect(
        () => parse(
          [],
          units: [
            {
              'id': 'test.plane',
              'name': 'Plane',
              'price': 10,
              'movement': 'air',
            },
          ],
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy templates remain implicit and preserve the canonical fingerprint',
    () {
      final raw = createExampleMod(base).toJson();
      for (final building in raw['buildings']) {
        building.remove('template');
      }
      final legacy = GameMod.fromJson(raw);
      expect(
        legacy.buildings.values.every((b) => !b.hasExplicitTemplate),
        isTrue,
      );
      expect(GameMod.fromJson(legacy.toJson()).fingerprint, legacy.fingerprint);
      expect(
        ContentPackage.decode(
          ContentPackage(mod: legacy).encode(),
        ).mod.fingerprint,
        legacy.fingerprint,
      );
    },
  );

  test('distributed example matches the in-game export', () async {
    final expected = createExampleMod(base);
    final archive = ContentPackage.decode(
      await File('examples/mods/dala-technologies.dalamod').readAsBytes(),
    );
    final source =
        jsonDecode(
              await File(
                'examples/technologies-source/mod.json',
              ).readAsString(),
            )
            as Map;
    expect(archive.mod.fingerprint, expected.fingerprint);
    expect(
      GameMod.fromJson(Map<String, dynamic>.from(source['mod'])).fingerprint,
      expected.fingerprint,
    );
    expect(source['version'], 4);
  });
}
