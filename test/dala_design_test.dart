import 'package:antiyoy_self/main.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late GameMod mod;
  setUpAll(() async => mod = await GameMod.loadDefault());
  for (final size in [const Size(360, 640), const Size(844, 390)]) {
    testWidgets('atlas menu fits $size with enlarged text', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        AntiyoyApp(gameMod: mod, saves: SaveRepository()),
      );
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('DALA'))).scale(10),
        13,
      );
      expect(find.text('DALA'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Жүктеу'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Жүктеу'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Артқа'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
