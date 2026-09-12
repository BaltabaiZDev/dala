import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:antiyoy_self/src/ui/map_viewport.dart';
import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/ui/game_screen.dart';
import 'package:antiyoy_self/src/ui/diplomacy_sheet.dart';
import 'package:antiyoy_self/src/persistence/lan_settings_repository.dart';
import 'diplomacy_social_test.dart' show socialFixture;
import 'render_test_helpers.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:antiyoy_self/src/l10n/game_locale.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/dala_viewport.dart';
import 'package:antiyoy_self/src/ui/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_package_test.dart' show MemoryContentStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = await GameMod.loadDefault();
    await (FontLoader(
      'Dala Sans',
    )..addFont(rootBundle.load('assets/dala/fonts/NotoSans.ttf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'continuous scale preserves insets, sharp DPR and transformed taps',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [
        240.0,
        281.0,
        320.0,
        359.0,
        390.0,
        411.0,
        599.0,
        720.0,
      ]) {
        tester.view.physicalSize = Size(width, width * 2);
        MediaQueryData? inside;
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 24),
                viewInsets: const EdgeInsets.only(bottom: 200),
                textScaler: const TextScaler.linear(1.5),
              ),
              child: DalaViewport(child: child!),
            ),
            home: Builder(
              builder: (context) {
                inside = MediaQuery.of(context);
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => taps++,
                      child: const Text('Tap'),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();
        expect(inside!.size.width, closeTo(390, .001));
        expect(inside!.padding.top * width / 390, closeTo(24, .001));
        expect(inside!.viewInsets.bottom * width / 390, closeTo(200, .001));
        expect(inside!.devicePixelRatio, closeTo(width / 390, .001));
        expect(inside!.textScaler.scale(10), 15);
        await tester.tap(find.text('Tap'));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  for (final size in [
    const Size(280, 540),
    const Size(320, 568),
    const Size(393, 851),
    const Size(600, 960),
    const Size(844, 390),
  ]) {
    for (final font in [1.0, 1.5, 2.0]) {
      testWidgets('menus and LAN at ${size.width}x${size.height}, font $font', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final language = GameLocale();
        await language.select('ru');
        addTearDown(language.dispose);
        await tester.pumpWidget(
          GameLocaleScope(
            controller: language,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: DalaTheme.light,
              locale: const Locale('ru'),
              supportedLocales: const [
                Locale('kk'),
                Locale('ru'),
                Locale('en'),
              ],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (context, child) => RepaintBoundary(
                key: const ValueKey('responsive-capture'),
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(font),
                    padding: const EdgeInsets.only(top: 24, bottom: 16),
                  ),
                  child: DalaViewport(child: child!),
                ),
              ),
              home: HomeScreen(
                gameMod: mod,
                saves: SaveRepository(),
                contentStorage: MemoryContentStorage(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'home');
        if (font == 1 && size.width == 320) await capture(tester, 'home-320');
        await tester.ensureVisible(find.text('Битва'));
        await tester.tap(find.text('Битва'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'new game');
        await tester.tap(find.bySemanticsLabel('Назад'));
        await tester.pumpAndSettle();
        await tester.tap(find.bySemanticsLabel('Настройки'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'settings');
        await tester.tap(find.bySemanticsLabel('Назад'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Игра по LAN'));
        await tester.tap(find.text('Игра по LAN'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'LAN');
        await tester.ensureVisible(
          find.byKey(const ValueKey('lan-network-settings')),
        );
        await tester.tap(find.byKey(const ValueKey('lan-network-settings')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'LAN settings');
        await tester.ensureVisible(find.byKey(const ValueKey('lan-port')));
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('lan-port')),
            matching: find.byType(TextField),
          ),
          '8888',
        );
        await tester.pumpAndSettle();
        if (font == 1 && size.width == 320) await capture(tester, 'lan-320');
        expect(tester.takeException(), isNull, reason: 'port editing');
        tester.view.viewInsets = FakeViewPadding(bottom: size.height * .4);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('lan-port')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'keyboard');
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.arrow_back));
        await tester.pumpAndSettle();
        expect(await LanSettingsRepository().loadPort(), 8888);
        await tester.ensureVisible(find.text('Моды и карты'));
        await tester.tap(find.text('Моды и карты'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'mod library');
        if (font == 2 && size.width == 320) {
          await capture(tester, 'mods-320-large-font');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
  for (final size in [
    const Size(280, 540),
    const Size(393, 851),
    const Size(844, 390),
  ]) {
    for (final font in [1.0, 2.0]) {
      testWidgets('game HUD, pause and diplomacy at $size, font $font', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = GameController(
          mod: mod,
          state: socialFixture(),
          saves: SaveRepository(),
          autosaveEnabled: false,
        );
        addTearDown(controller.dispose);
        final key = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: key,
            theme: DalaTheme.light,
            debugShowCheckedModeBanner: false,
            builder: (context, child) => RepaintBoundary(
              key: const ValueKey('responsive-capture'),
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(font),
                  padding: const EdgeInsets.only(top: 24, bottom: 16),
                ),
                child: DalaViewport(child: child!),
              ),
            ),
            home: GameScreen(controller: controller, disposeController: false),
          ),
        );
        await waitForMapSprites(tester);
        final viewer = tester.widget<MapViewport>(find.byType(MapViewport));
        final localPoint = MatrixUtils.transformPoint(
          viewer.transformationController.value,
          HexBoard.centerOf(controller.state.hexes[0]),
        );
        final render = tester.renderObject<RenderBox>(find.byType(MapViewport));
        await tester.tapAt(render.localToGlobal(localPoint));
        expect(
          controller.selectedTile,
          0,
          reason: 'map taps use the scaled viewport coordinates',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: 'game HUD');
        if (size.width == 280 && font == 1) await capture(tester, 'game-280');
        await tester.tap(find.bySemanticsLabel('Мәзір'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Жалғастыру'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'pause menu');
        key.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 300));
        showAntiyoyDiplomacyInbox(
          key.currentState!.overlay!.context,
          controller,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: 'diplomacy inbox');
        key.currentState!.pop();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }
  }
}

Future<void> capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('responsive-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    final file = File('build/responsive-qa/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  });
}
