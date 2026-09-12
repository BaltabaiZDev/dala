import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antiyoy_self/src/l10n/catalog.dart';
import 'package:antiyoy_self/src/l10n/game_locale.dart';
import 'package:antiyoy_self/src/l10n/languages.dart';
import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'package:antiyoy_self/src/ui/dala_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in {
      'Dala Sans': 'NotoSans.ttf',
      'Dala Chinese': 'DalaChinese.ttf',
    }.entries) {
      await (FontLoader(
        font.key,
      )..addFont(rootBundle.load('assets/dala/fonts/${font.value}'))).load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    '26 offline languages cover the catalog and preserve every dynamic argument',
    () async {
      expect(GameLocale.supported.toSet(), hasLength(26));
      final controller = GameLocale();
      addTearDown(controller.dispose);
      List<String> arguments(String text) =>
          RegExp(r'\{\d+\}').allMatches(text).map((m) => m[0]!).toList()
            ..sort();
      for (final language in dalaLanguages) {
        expect(
          GlobalMaterialLocalizations.delegate.isSupported(language.locale),
          isTrue,
          reason: language.code,
        );
        if (['kk', 'ru', 'en'].contains(language.code)) continue;
        final strings = Map<String, String>.from(
          jsonDecode(
                await rootBundle.loadString(
                  'assets/l10n/${language.code}.json',
                ),
              )
              as Map,
        );
        expect(
          strings.keys.toSet(),
          gameTranslations.keys.toSet(),
          reason: language.code,
        );
        for (final entry in strings.entries) {
          expect(entry.value.trim(), isNotEmpty, reason: language.code);
          expect(
            arguments(entry.value),
            arguments(entry.key),
            reason: '${language.code}: ${entry.key}',
          );
          expect(
            entry.value.split('\n').length,
            entry.key.split('\n').length,
            reason: '${language.code}: ${entry.key}',
          );
          expect(RegExp(r'ZXQ|QXZ|DALA\d{4}').hasMatch(entry.value), isFalse);
        }
        await controller.select(language.code);
        expect(controller.translate('Тіл'), strings['Тіл']);
        expect(
          controller.translate('Адамдар: 3 · Боттар: 1'),
          strings['Адамдар: {0} · Боттар: {1}']!
              .replaceAll('{0}', '3')
              .replaceAll('{1}', '1'),
        );
        expect(controller.translate('My own map v2'), 'My own map v2');
      }
      await controller.select('zh_CN');
      final restored = GameLocale();
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.locale, const Locale('zh', 'CN'));
      expect(restored.translate('Тіл'), controller.translate('Тіл'));
      await restored.select('pt_BR');
      expect(restored.locale, const Locale('pt', 'BR'));
    },
  );

  Widget screen(GameLocale language, {double scale = 1}) => RepaintBoundary(
    key: const ValueKey('language-capture'),
    child: GameLocaleScope(
      controller: language,
      child: AnimatedBuilder(
        animation: language,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: DalaTheme.light,
          locale: language.locale,
          supportedLocales: GameLocale.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: DalaViewport(child: child!),
          ),
          home: const Scaffold(
            body: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [GameText('Баптаулар'), LanguagePicker()],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('language-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/localization-qa/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'search finds native names and codes; no-result and keyboard fit a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final language = GameLocale();
      addTearDown(language.dispose);
      await tester.pumpWidget(screen(language, scale: 1.5));
      await tester.tap(find.byKey(const ValueKey('language-picker')));
      await tester.pumpAndSettle();
      await capture(tester, 'picker-320');
      await tester.enterText(
        find.byKey(const ValueKey('language-search')),
        'missing language',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(find.text('Тіл табылмады'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('language-search')),
        '简体',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('language-zh_CN')), findsOneWidget);
      await capture(tester, 'picker-keyboard-320');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('language-zh_CN')));
        final watch = Stopwatch()..start();
        while (language.language != 'zh_CN' &&
            watch.elapsedMilliseconds < 5000) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(language.language, 'zh_CN');
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('简体中文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'chinese-320');
      await tester.tap(find.byKey(const ValueKey('language-picker')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('language-search')),
        'pt_BR',
      );
      await tester.pumpAndSettle();
      expect(find.text('Português (Brasil)'), findsOneWidget);
    },
  );
}
