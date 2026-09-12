import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antiyoy_self/src/game/map_generator.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/content_library.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/content_files.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/content_screen.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/lan_screen.dart';
import 'content_package_test.dart' show MemoryContentStorage;

class _Files extends FilePicker {
  String name = 'custom.dalamod';
  Uint8List? data;
  Uint8List? saved;
  String? savedName;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    dynamic onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => data == null
      ? null
      : FilePickerResult([
          PlatformFile(
            name: name,
            size: data!.length,
            readStream: Stream.value(data!),
            bytes: withData ? data : null,
          ),
        ]);
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saved = bytes;
    savedName = fileName;
    return fileName;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base;
  late GameMod mod;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    mod = GameMod.fromJson(
      base.toJson()
        ..['id'] = 'ui_test'
        ..['name'] = 'Сары дала',
    );
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'file import cancellation and byte stream export are real file operations',
    () async {
      final picker = _Files();
      FilePicker.platform = picker;
      expect(await ContentFiles.pick(), isNull);
      picker.data = ContentPackage(mod: mod).encode();
      final file = (await ContentFiles.pick())!;
      expect(ContentPackage.decode(file.bytes).mod.id, mod.id);
      expect(await ContentFiles.save('export.dalamod', file.bytes), isTrue);
      expect(picker.savedName, 'export.dalamod');
      expect(picker.saved, file.bytes);
    },
  );
  testWidgets('phone library imports, activates and exports an actual mod', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final picker = _Files()..data = ContentPackage(mod: mod).encode();
    FilePicker.platform = picker;
    final library = ContentLibrary(base, storage: MemoryContentStorage());
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: ContentScreen(library: library),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Импорт'));
      final watch = Stopwatch()..start();
      while (library.mods.isEmpty && watch.elapsedMilliseconds < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Сары дала'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(library.activeMod.id, mod.id);
    await tester.tap(find.text('Экспорт'));
    await tester.pumpAndSettle();
    expect(ContentPackage.decode(picker.saved!).mod.id, mod.id);
    await tester.tap(find.text('Кәдімгі DALA'));
    await tester.pumpAndSettle();
    expect(library.activeMod.id, base.id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    library.dispose();
  });
  testWidgets('LAN offers explicit normal/mod mode and matching custom maps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = ContentLibrary(base, storage: MemoryContentStorage());
    final state = MapGenerator(mod).generate(
      const GameConfig(
        mapSize: MapSize.small,
        playerCount: 2,
        humanCount: 2,
        seed: 35,
      ),
    );
    library.mods.add(InstalledMod('mods/ui.dalamod', ContentPackage(mod: mod)));
    library.maps.add(
      InstalledMap(
        'maps/custom.dalamap',
        DalaMap.fromState('Екі жағалау', state, mod),
      ),
    );
    library.activeHash = mod.fingerprint;
    await tester.pumpWidget(
      MaterialApp(
        theme: DalaTheme.light,
        home: LanScreen(
          mod: mod,
          defaultMod: base,
          library: library,
          saves: SaveRepository(),
          pickConfig: (_) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Кәдімгі'), findsOneWidget);
    expect(find.text('Модпен'), findsOneWidget);
    expect(find.text('Сары дала'), findsOneWidget);
    await tester.tap(find.text('Кездейсоқ карта'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Екі жағалау').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Кәдімгі'));
    await tester.pumpAndSettle();
    expect(find.text('Сары дала'), findsNothing);
    expect(find.text('Кездейсоқ карта'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    library.dispose();
  });
}
