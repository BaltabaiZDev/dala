import 'package:antiyoy_self/src/l10n/catalog.dart';
import 'package:antiyoy_self/src/l10n/game_locale.dart';
import 'package:antiyoy_self/src/modding/content_library.dart';
import 'package:antiyoy_self/src/modding/content_package.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/content_screen.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_package_test.dart' show MemoryContentStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod base;
  setUpAll(() async {
    base = await GameMod.loadDefault();
    await (FontLoader(
      'Dala Sans',
    )..addFont(rootBundle.load('assets/dala/fonts/NotoSans.ttf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'catalog preserves arguments and locale reloads without changing content',
    () async {
      final placeholders = RegExp(r'\{\d+\}');
      for (final entry in gameTranslations.entries) {
        final required = placeholders
            .allMatches(entry.key)
            .map((m) => m[0])
            .toSet();
        for (final text in entry.value) {
          expect(
            placeholders.allMatches(text).map((m) => m[0]).toSet(),
            required,
            reason: entry.key,
          );
        }
      }
      final language = GameLocale();
      addTearDown(language.dispose);
      final hash = base.fingerprint;
      await language.select('en');
      expect(language.translate('Қосулы модтар: 3'), 'Enabled mods: 3');
      expect(
        language.translate('Ход уақыты: 2 минут 3 секунд'),
        'Turn time: 2 min 3 sec',
      );
      expect(
        language.translate('Сізге қарыз +\$45 · Төлем тоқтаулы'),
        'Owed to you +\$45 · Payments paused',
      );
      expect(language.translate('My own map v2'), 'My own map v2');
      final restored = GameLocale();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.language, 'en');
      await restored.select('invalid');
      expect(restored.language, 'en');
      expect(base.fingerprint, hash);
    },
  );

  Widget localized(GameLocale language, Widget home) => GameLocaleScope(
    controller: language,
    child: AnimatedBuilder(
      animation: language,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: DalaTheme.light,
        locale: language.locale,
        supportedLocales: GameLocale.supportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home,
      ),
    ),
  );

  testWidgets(
    'language switches live through settings and compact home fits a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final language = GameLocale();
      addTearDown(language.dispose);
      final home = HomeScreen(
        gameMod: base,
        saves: SaveRepository(),
        contentStorage: MemoryContentStorage(),
      );
      await tester.pumpWidget(localized(language, home));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Баптаулар'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('language-ru')));
      await tester.pumpAndSettle();
      expect(find.text('Язык'), findsOneWidget);
      expect(find.text('Автосохранение'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Назад'));
      await tester.pumpAndSettle();
      expect(find.text('Битва'), findsOneWidget);
      for (final entry in {
        'kk': 'Жүктеу',
        'ru': 'Загрузить',
        'en': 'Load',
      }.entries) {
        await language.select(entry.key);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text(entry.value)).bottom, lessThan(640));
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Overlay).first,
          matchesGoldenFile('goldens/compact_home_${entry.key}.png'),
        );
      }
      await tester.tap(find.text('Battle'));
      await tester.pumpAndSettle();
      expect(find.text('Difficulty'), findsOneWidget);
      expect(find.text('Map size'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'three-language mod library keeps user names and multiple switches at 320px',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final language = GameLocale();
      final library = ContentLibrary(base, storage: MemoryContentStorage());
      addTearDown(language.dispose);
      addTearDown(library.dispose);
      for (final id in ['economy', 'army']) {
        final mod = GameMod.fromJson(
          base.toJson()
            ..['id'] = id
            ..['name'] = id == 'economy' ? 'Шайқас' : 'Army & fleet',
        );
        library.mods.add(
          InstalledMod('mods/$id.dalamod', ContentPackage(mod: mod)),
        );
      }
      await tester.pumpWidget(
        localized(language, ContentScreen(library: library)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(library.activeHashes, hasLength(2));
      for (final code in ['kk', 'ru', 'en']) {
        await language.select(code);
        await tester.pumpAndSettle();
        expect(find.text('Шайқас'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(Overlay).first,
          matchesGoldenFile('goldens/compact_mods_$code.png'),
        );
      }
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      expect(library.activeMods.first.mod.id, 'army');
      await tester.tap(find.text('Classic DALA'));
      await tester.pumpAndSettle();
      expect(library.activeHashes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
