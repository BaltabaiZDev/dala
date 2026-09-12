import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/content_library.dart';
import 'package:antiyoy_self/src/modding/content_storage.dart';
import 'package:antiyoy_self/src/modding/content_storage_io.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';

class MemoryContentStorage implements ContentStorage {
  final files = <String, Uint8List>{};
  @override
  Future<String> location() async => 'test/DALA';
  @override
  Future<Map<String, Uint8List>> readAll() async => Map.of(files);
  @override
  Future<void> write(String path, Uint8List bytes) async {
    files[path] = bytes;
  }

  @override
  Future<void> remove(String path) async {
    files.remove(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base;
  late GameMod mod;
  late GameState state;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    final raw = base.toJson()
      ..['id'] = 'steppe_test'
      ..['name'] = 'Тест мод';
    (raw['rules'] as Map)['farmIncome'] = 7;
    mod = GameMod.fromJson(raw);
    state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 1,
        seed: 122,
      ),
    );
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Uint8List zip(Map<String, List<int>> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  List<int> manifest(GameMod m) => utf8.encode(
    jsonEncode({'format': 'dala-mod', 'version': 1, 'mod': m.toJson()}),
  );

  test('mod plus maps survives package export and import', () {
    final map = DalaMap.fromState('Теңіз жолы', state, mod);
    final decoded = ContentPackage.decode(
      ContentPackage(mod: mod, maps: [map]).encode(),
    );
    expect(decoded.mod.fingerprint, mod.fingerprint);
    expect(decoded.mod.rules.farmIncome, 7);
    expect(decoded.maps.single.name, 'Теңіз жолы');
    final restored = decoded.maps.single.createState(decoded.mod);
    expect(
      restored.hexes.map((t) => t.toJson()),
      state.hexes.map((t) => t.toJson()),
    );
    expect(restored.modSnapshot, mod.toJson());
  });
  for (final path in [
    '../mod.json',
    '/mod.json',
    'sprites/../../oops.png',
    r'C:\oops.png',
    'code.dart',
  ]) {
    test('reject invalid package entry $path', () {
      expect(
        () => ContentPackage.decode(
          zip({
            'mod.json': manifest(mod),
            path: [1, 2, 3],
          }),
        ),
        throwsFormatException,
      );
    });
  }
  test('base game id cannot be replaced by an imported mod', () {
    expect(
      () => ContentPackage.decode(zip({'mod.json': manifest(base)})),
      throwsFormatException,
    );
  });
  test(
    'ZIP aliases and a single wrapper folder import as the same mod',
    () async {
      final storage = MemoryContentStorage();
      final library = ContentLibrary(base, storage: storage);
      addTearDown(library.dispose);
      final bytes = zip({'My mod/mod.json': manifest(mod)});
      for (final name in [
        'sample.dalamod.zip',
        'SAMPLE.ZIP',
        'sample.DALAMOD',
      ]) {
        await library.importFile(name, bytes);
        expect(library.errors, isEmpty);
        expect(library.mods.single.mod.fingerprint, mod.fingerprint);
        expect(storage.files.keys.single, endsWith('.dalamod'));
      }
      await expectLater(
        library.importFile(
          'unrelated.zip',
          zip({
            'notes.txt': [1, 2],
          }),
        ),
        throwsFormatException,
      );
      expect(library.mods, hasLength(1));
      expect(
        () => ContentPackage.decode(
          zip({'one/mod.json': manifest(mod), 'two/mod.json': manifest(mod)}),
        ),
        throwsFormatException,
      );
      expect(
        () => ContentPackage.decode(
          zip({
            'one/mod.json': manifest(mod),
            'one/../README.md': [1, 2],
          }),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'reject broken archive, foreign format, overlarge and future versions',
    () {
      expect(
        () => ContentPackage.decode(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      expect(
        () => ContentPackage.decode(Uint8List(ContentPackage.maxBytes + 1)),
        throwsFormatException,
      );
      expect(
        () => ContentPackage.decode(
          zip({'mod.json': utf8.encode('{"format":"rwmod"}')}),
        ),
        throwsFormatException,
      );
      final root = {'format': 'dala-mod', 'version': 99, 'mod': mod.toJson()};
      expect(
        () => ContentPackage.decode(
          zip({'mod.json': utf8.encode(jsonEncode(root))}),
        ),
        throwsFormatException,
      );
    },
  );
  test('reject ZIP expanded limit before inflating a large entry', () {
    expect(
      () => ContentPackage.decode(
        zip({
          'mod.json': manifest(mod),
          'README.md': Uint8List(ContentPackage.maxExpandedBytes + 1),
        }),
      ),
      throwsFormatException,
    );
  });
  test(
    'map enforces exact mod version and stays independent between matches',
    () {
      final map = DalaMap.fromState('Карта', state, mod);
      final changed = mod.toJson();
      (changed['rules'] as Map)['farmIncome'] = 8;
      expect(
        () => map.createState(GameMod.fromJson(changed)),
        throwsFormatException,
      );
      expect(() => map.createState(base), throwsFormatException);
      final first = map.createState(mod, multiplayer: true);
      expect(first.config.humanCount, first.config.playerCount);
      first.hexes.first.owner = 1;
      expect(map.createState(mod).hexes.first.owner, state.hexes.first.owner);
    },
  );
  test(
    'malformed dimensions, duplicate coordinates and unsupported map rejected',
    () {
      final json =
          jsonDecode(
                utf8.decode(DalaMap.fromState('Карта', state, mod).encode()),
              )
              as Map;
      (json['state'] as Map)['width'] = 100000;
      expect(
        () => DalaMap.decode(utf8.encode(jsonEncode(json))),
        throwsFormatException,
      );
      expect(
        () => DalaMap.decode(utf8.encode('<map orientation="orthogonal"/>')),
        throwsFormatException,
      );
    },
  );
  test('sprites travel in archive, invalid names or PNG sizes fail', () {
    final png = File('web/icons/Icon-192.png').readAsBytesSync();
    final raw = mod.toJson()..['sprites'] = {'castle': base64Encode(png)};
    final imageMod = GameMod.fromJson(raw);
    final result = ContentPackage.decode(
      ContentPackage(mod: imageMod).encode(),
    );
    expect(result.mod.sprites, imageMod.sprites);
    raw['sprites'] = {'../castle': base64Encode(png)};
    expect(() => GameMod.fromJson(raw), throwsFormatException);
    raw['sprites'] = {
      'castle': base64Encode([1, 2, 3]),
    };
    expect(() => GameMod.fromJson(raw), throwsFormatException);
  });
  test('selection persists; saves retain rules after mod removal', () async {
    final storage = MemoryContentStorage();
    final library = ContentLibrary(base, storage: storage);
    await library.importFile('test.dalamod', ContentPackage(mod: mod).encode());
    await library.activate(library.mods.single.hash);
    final fresh = ContentLibrary(base, storage: storage);
    await fresh.refresh();
    expect(fresh.activeMod.rules.farmIncome, 7);
    final saved = GameState.fromJson(state.toJson())
      ..modSnapshot = mod.toJson();
    await SaveRepository().save(saved);
    await fresh.remove(fresh.mods.single.path);
    expect(fresh.activeMod.id, base.id);
    final loaded = (await SaveRepository().load())!;
    expect(
      fresh.resolveSavedMod(loaded.modId, loaded.modSnapshot).rules.farmIncome,
      7,
    );
    expect(() => fresh.resolveSavedMod(mod.id, null), throwsFormatException);
    library.dispose();
    fresh.dispose();
  });
  test(
    'new maps with unchanged mod rules survive import and re-export',
    () async {
      final storage = MemoryContentStorage();
      final library = ContentLibrary(base, storage: storage);
      addTearDown(library.dispose);
      final first = DalaMap.fromState('First coast', state, mod);
      final second = DalaMap.fromState('Second coast', state, mod);
      await library.importFile(
        'first.dalamod',
        ContentPackage(mod: mod, maps: [first]).encode(),
      );
      await library.activate(mod.fingerprint);
      await library.importFile(
        'second.dalamod',
        ContentPackage(mod: mod, maps: [first, second]).encode(),
      );
      expect(library.mods, hasLength(1));
      expect(library.maps, hasLength(2));
      expect(storage.files, hasLength(2));
      expect(library.activeMod.fingerprint, mod.fingerprint);
      expect(
        ContentPackage.decode(library.mods.single.package.encode()).maps,
        hasLength(2),
      );
      await library.remove(library.mods.single.path);
      expect(storage.files, isEmpty);
      expect(library.maps, isEmpty);
    },
  );
  test(
    'native mods/maps folders scan real imported files and ignore symlinks',
    () async {
      final root = await Directory.systemTemp.createTemp('dala-content-test-');
      addTearDown(() => root.delete(recursive: true));
      final storage = PlatformContentStorage(rootPath: root.path);
      await storage.location();
      expect(await Directory('${root.path}/mods').exists(), isTrue);
      expect(await Directory('${root.path}/maps').exists(), isTrue);
      await storage.write(
        'mods/test.DALAMOD.ZIP',
        ContentPackage(mod: mod).encode(),
      );
      final library = ContentLibrary(base, storage: storage);
      await library.refresh();
      expect(library.mods.single.mod.id, mod.id);
      await expectLater(
        storage.write('../escape.dalamod', Uint8List(0)),
        throwsFormatException,
      );
      await library.remove('mods/test.DALAMOD.ZIP');
      expect(library.mods, isEmpty);
      library.dispose();
    },
  );
}
