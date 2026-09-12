import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/content_library.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/modding/mod_stack.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_package_test.dart' show MemoryContentStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base;
  late GameMod economy;
  late GameMod army;
  late GameMod override;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    GameMod changed(String id, Map<String, Object> rules) {
      final json = base.toJson()
        ..['id'] = id
        ..['name'] = id;
      (json['rules'] as Map).addAll(rules);
      return GameMod.fromJson(json);
    }

    economy = changed('economy', {'farmIncome': 7});
    army = changed('army', {'unitPricePerLevel': 25});
    override = changed('override', {'farmIncome': 9});
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'independent rule changes combine; order resolves overlaps deterministically',
    () {
      final combined = ModStack.compose(base, [economy, army, override]);
      expect(combined.mod.rules.farmIncome, 9);
      expect(combined.mod.rules.unitPricePerLevel, 25);
      expect(combined.conflicts.single.field, 'rules.farmIncome');
      expect(combined.conflicts.single.winner, override.name);
      final reordered = ModStack.compose(base, [override, army, economy]);
      expect(reordered.mod.rules.farmIncome, 7);
      expect(reordered.mod.fingerprint, isNot(combined.mod.fingerprint));
      expect(
        GameMod.fromJson(combined.mod.toJson()).fingerprint,
        combined.mod.fingerprint,
      );
      expect(
        ModStack.resolve(base, [
          override,
          army,
          economy,
        ], combined.mod.requirements).fingerprint,
        combined.mod.fingerprint,
      );
      expect(base.rules.farmIncome, isNot(9));
      expect(() => ModStack.compose(base, [army, army]), throwsFormatException);
    },
  );

  test('missing or edited same-version package cannot resolve a stack', () {
    final combined = ModStack.compose(base, [economy, army]).mod;
    final raw = army.toJson();
    (raw['rules'] as Map)['unitPricePerLevel'] = 26;
    final edited = GameMod.fromJson(raw);
    expect(edited.version, army.version);
    expect(
      () => ModStack.resolve(base, [economy], combined.requirements),
      throwsFormatException,
    );
    expect(
      () => ModStack.resolve(base, [economy, edited], combined.requirements),
      throwsFormatException,
    );
  });

  test(
    'legacy selection migrates; toggles, order and removal survive refresh',
    () async {
      final storage = MemoryContentStorage();
      storage.files['mods/economy.dalamod'] = ContentPackage(
        mod: economy,
      ).encode();
      storage.files['mods/army.dalamod'] = ContentPackage(mod: army).encode();
      SharedPreferences.setMockInitialValues({
        'dala.content.activeMod': economy.fingerprint,
      });
      final library = ContentLibrary(base, storage: storage);
      addTearDown(library.dispose);
      await library.refresh();
      expect(library.activeHashes, [economy.fingerprint]);
      await library.setEnabled(army.fingerprint, true);
      await library.moveMod(army.fingerprint, -1);
      await library.refresh();
      expect(library.activeHashes, [army.fingerprint, economy.fingerprint]);
      await library.setEnabled(army.fingerprint, false);
      expect(library.activeMod.fingerprint, economy.fingerprint);
      await library.remove('mods/economy.dalamod');
      expect(library.activeMod.fingerprint, base.fingerprint);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('dala.content.activeMod'), isFalse);
    },
  );

  test(
    'exported map pins all packages and becomes playable with its exact stack',
    () {
      final combined = ModStack.compose(base, [economy, army]).mod;
      final state = MapGenerator(combined).generate(
        const GameConfig(
          mapSize: MapSize.small,
          playerCount: 2,
          humanCount: 1,
          seed: 302,
        ),
      );
      final map = DalaMap.decode(
        DalaMap.fromState('My map', state, combined).encode(),
      );
      expect(map.requiredMods.map((ref) => ref.hash), [
        economy.fingerprint,
        army.fingerprint,
      ]);
      final library = ContentLibrary(base, storage: MemoryContentStorage());
      addTearDown(library.dispose);
      final entry = InstalledMap('maps/map.dalamap', map);
      library.mods.add(
        InstalledMod('mods/army.dalamod', ContentPackage(mod: army)),
      );
      expect(library.modForMap(entry), isNull);
      library.mods.add(
        InstalledMod('mods/economy.dalamod', ContentPackage(mod: economy)),
      );
      final resolved = library.modForMap(entry)!;
      expect(resolved.fingerprint, combined.fingerprint);
      expect(map.createState(resolved).modSnapshot, combined.toJson());
    },
  );
}
