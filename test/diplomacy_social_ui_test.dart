import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/diplomacy_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diplomacy_social_test.dart' show socialFixture;

class _Routes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = await GameMod.loadDefault();
  });
  testWidgets(
    'multi-condition inbox letter opens and accepts in the same panel',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(320, 720));
      final controller = GameController(
        mod: mod,
        state: socialFixture(),
        saves: SaveRepository(),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      controller.engine.proposeExchange(
        from: 1,
        to: 0,
        rationale:
            'Шекараны алты ход тыныш ұстайық. Сіз қазынаны толықтырасыз, біз басқа майданға күш жинаймыз.',
        terms: const [
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.money,
              amount: 20,
            ),
          ),
          DiplomacyTerm(
            fromSender: false,
            offer: DiplomacyOffer(type: DiplomacyExchangeType.money, amount: 5),
          ),
          DiplomacyTerm(
            fromSender: true,
            offer: DiplomacyOffer(
              type: DiplomacyExchangeType.friendship,
              duration: 12,
            ),
          ),
        ],
      );
      final routes = _Routes();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAntiyoyDiplomacyInbox(context, controller),
                child: const Text('Inbox'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
      final pushes = routes.pushes;
      await tester.tap(find.textContaining('↓ Ақша'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diplomacy-letter-page')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('diplomacy-letter-rationale')),
        findsNothing,
      );
      expect(find.textContaining('20 ақша'), findsOneWidget);
      expect(find.textContaining('5 ақша'), findsOneWidget);
      await tester.ensureVisible(find.text('Толық түсіндірме'));
      await tester.tap(find.text('Толық түсіндірме'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diplomacy-letter-rationale')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Түсіндірмені жабу'));
      await tester.tap(find.text('Түсіндірмені жабу'));
      await tester.pumpAndSettle();
      expect(routes.pushes, pushes);
      await tester.tap(find.text('Қабылдау'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('diplomacy-inbox-list')),
        findsOneWidget,
      );
      expect(controller.engine.proposalsFor(0), isEmpty);
      expect(controller.engine.playerMoney(0), 115);
      expect(controller.engine.areFriends(0, 1), isTrue);
      expect(routes.pushes, pushes);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(1280, 720),
  ]) {
    testWidgets('single-panel info black mark and three terms at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(size);
      final controller = GameController(
        mod: mod,
        state: socialFixture(),
        saves: SaveRepository(),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      final routes = _Routes();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showAntiyoyDiplomacy(
                    context,
                    controller,
                    initialPlayer: 1,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final pushes = routes.pushes;
      await tester.tap(find.byTooltip('Қатынастары'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('diplomacy-info-page')), findsOneWidget);
      expect(routes.pushes, pushes);
      await tester.tap(find.text('Елшілік +12 · \$10'));
      await tester.pumpAndSettle();
      expect(controller.engine.opinionOf(1, 0), 12);
      await tester.tap(find.byTooltip('Артқа'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Қара белгі қою'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('black-mark-panel')), findsOneWidget);
      expect(routes.pushes, pushes);
      await tester.tap(find.byTooltip('Артқа'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Айырбас'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-diplomacy-term')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('term-direction-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-diplomacy-term')), findsNothing);
      // Reverse the given row: all three rows now point toward the sender.
      await tester.tap(find.byKey(const ValueKey('term-direction-1')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        final selector = find.byKey(const ValueKey('offer-type-1-0')).at(i);
        await tester.ensureVisible(selector);
        await tester.pumpAndSettle();
        await tester.tap(selector);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('offer-type-option-money')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('offer-type-option-money')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Ұсыну'));
      await tester.pumpAndSettle();
      final proposal = controller.engine.proposalsFor(1).single;
      expect(proposal.effectiveTerms.length, 3);
      expect(
        proposal.effectiveTerms.every(
          (t) => !t.fromSender && t.offer.type == DiplomacyExchangeType.money,
        ),
        isTrue,
      );
      expect(routes.pushes, pushes);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(null);
    });
  }
}
