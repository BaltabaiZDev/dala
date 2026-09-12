import 'package:antiyoy_self/src/ui/dala_theme.dart';
import 'dart:convert';

import 'package:antiyoy_self/src/game/game_controller.dart';
import 'package:antiyoy_self/src/game/game_engine.dart';
import 'package:antiyoy_self/src/game/models.dart';
import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:antiyoy_self/src/persistence/save_repository.dart';
import 'package:antiyoy_self/src/ui/diplomacy_overview.dart';
import 'package:antiyoy_self/src/ui/diplomacy_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diplomacy_social_test.dart' show socialFixture;

GameState _fixture() {
  final state = socialFixture();
  state.setPlayerName(0, 'Ayan');
  state.setPlayerName(1, 'Alikhan');
  state.setPlayerName(2, 'Zhanibek');
  state.diplomacySocial.opinions[1][0] = 24;
  state.diplomacySocial.opinions[0][1] = 24;
  state.diplomacyDebts[1][0] = 65;
  state.diplomacyDebts[0][1] = 35;
  state.diplomacyRelations[0][1] = DiplomacyStatus.alliance;
  state.diplomacyRelations[1][0] = DiplomacyStatus.alliance;
  state.diplomacyAllianceTurns[0][1] = 9;
  state.diplomacyAllianceTurns[1][0] = 9;
  state.diplomacySubsidies.addAll(const [
    DiplomacySubsidy(payer: 1, receiver: 0, amount: 5, turnsLeft: 8),
    DiplomacySubsidy(payer: 0, receiver: 1, amount: 3, turnsLeft: 4),
    DiplomacySubsidy(
      payer: 1,
      receiver: 0,
      amount: 7,
      turnsLeft: 2,
      mandatory: true,
    ),
  ]);
  return state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GameMod mod;
  setUpAll(() async {
    mod = await GameMod.loadDefault();
    await (FontLoader(
      'Antiyoy',
    )..addFont(rootBundle.load('assets/classic/font.ttf'))).load();
  });

  test('overview is read-only with shared relationship and opposite debts', () {
    final state = _fixture();
    final before = jsonEncode(state.toJson());
    final overview = DiplomacyOverview.fromState(state, 0, 1);
    expect(overview.relationship, 24);
    expect(overview.statusLabel, 'Достық · 9 ход');
    expect(overview.obligations.map((item) => item.label), [
      'Сізге қарыз +\$65',
      'Сіз қарыз −\$35',
      'Субсидия +\$5/ход · 8x',
      'Субсидия −\$3/ход · 4x',
      'Өтемақы +\$7/ход · 2x',
    ]);
    expect(jsonEncode(state.toJson()), before);
    final reversed = DiplomacyOverview.fromState(state, 1, 0);
    expect(reversed.relationship, 24);
    expect(reversed.obligations.map((item) => item.amount), [
      35,
      -65,
      3,
      -5,
      -7,
    ]);
    expect(reversed.obligations.last.description, contains('Сіз оған'));
  });

  test('payment grouping keeps direction type and expiry distinct', () {
    final state = _fixture();
    state.diplomacySubsidies.addAll(const [
      DiplomacySubsidy(payer: 1, receiver: 0, amount: 2, turnsLeft: 8),
      DiplomacySubsidy(payer: 1, receiver: 0, amount: 9, turnsLeft: 5),
      DiplomacySubsidy(payer: 1, receiver: 0, amount: 99, turnsLeft: 0),
      DiplomacySubsidy(payer: 1, receiver: 0, amount: 0, turnsLeft: 9),
      DiplomacySubsidy(payer: 2, receiver: 1, amount: 90, turnsLeft: 9),
      DiplomacySubsidy(
        payer: 1,
        receiver: 0,
        amount: 6,
        turnsLeft: 2,
        mandatory: true,
      ),
    ]);
    final payments = DiplomacyOverview.fromState(
      state,
      0,
      1,
    ).obligations.where((item) => item.turnsLeft != null).toList();
    expect(payments.map((item) => (item.amount, item.turnsLeft)), [
      (9, 5),
      (7, 8),
      (-3, 4),
      (13, 2),
    ]);
    // The published amount is contractual, even if today's treasury is empty.
    state.provinces[1].money = 0;
    expect(DiplomacyOverview.fromState(state, 0, 1).obligations[2].amount, 9);
  });

  test('war pauses debt and retains mandatory compensation', () {
    final state = _fixture();
    final engine = GameEngine(mod: mod, state: state);
    engine.setDiplomacyStatus(0, 1, DiplomacyStatus.war);
    final overview = DiplomacyOverview.fromState(state, 0, 1);
    expect(overview.obligations.map((item) => item.label), [
      'Сізге қарыз +\$65 · Төлем тоқтаулы',
      'Сіз қарыз −\$35 · Төлем тоқтаулы',
      'Өтемақы +\$7/ход · 2x',
    ]);
    // Old snapshots also retain principal, but void voluntary subsidies.
    state.diplomacyDebts[1][0] = 123;
    state.diplomacySubsidies.add(
      const DiplomacySubsidy(payer: 1, receiver: 0, amount: 30, turnsLeft: 8),
    );
    expect(DiplomacyOverview.fromState(state, 0, 1).obligations, hasLength(3));
  });

  test(
    'remaining debt and duration reflect actual economy and saved state',
    () {
      final state = _fixture();
      final engine = GameEngine(mod: mod, state: state);
      for (var turn = 0; turn < 3; turn++) {
        engine.endTurn();
      }
      final overview = DiplomacyOverview.fromState(
        GameState.fromJson(state.toJson()),
        0,
        1,
      );
      expect(overview.friendshipTurns, 8);
      expect(
        overview.obligations.any(
          (item) => item.kind == DiplomacyObligationKind.debt,
        ),
        isFalse,
      );
      expect(overview.obligations.map((item) => item.turnsLeft), [7, 3, 1]);
    },
  );

  test('neutral truce alliance black mark and no-obligation states', () {
    final state = socialFixture();
    expect(DiplomacyOverview.fromState(state, 0, 1).obligations, isEmpty);
    state.diplomacyWarCooldowns[0][1] = 10;
    expect(
      DiplomacyOverview.fromState(state, 0, 1).statusLabel,
      'Бейтарап · Соғысқа тыйым: 10 ход',
    );
    state.diplomacyRelations[0][1] = DiplomacyStatus.coalition;
    expect(
      DiplomacyOverview.fromState(state, 0, 1).statusLabel,
      'Әскери одақ · 12 ход',
    );
    state.diplomacyBlackMarks[1][0] = true;
    expect(DiplomacyOverview.fromState(state, 0, 1).blackMark, isTrue);
  });

  for (final size in [
    const Size(320, 720),
    const Size(390, 844),
    const Size(1280, 720),
  ]) {
    testWidgets('both directions and all obligations fit at $size', (
      tester,
    ) async {
      final state = _fixture();
      final controller = await _open(tester, mod, state, size: size);
      final row = find.byKey(const ValueKey('diplomacy-country-1'));
      expect(
        find.descendant(of: row, matching: find.text('Қатынас: +24')),
        findsOneWidget,
      );
      for (final obligation in DiplomacyOverview.fromState(
        state,
        0,
        1,
      ).obligations) {
        expect(
          find.descendant(of: row, matching: find.text(obligation.label)),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      if (size.width == 390) {
        await expectLater(
          find.byType(Overlay).first,
          matchesGoldenFile('diplomacy_obligations.png'),
        );
      }
      await tester.tap(find.text('Alikhan'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Қатынастары'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Сізге қарыз +\$65'),
        100,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('diplomacy-info-page')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('Қарыздар мен төлемдер'), findsOneWidget);
      expect(find.text('Сізге қарыз +\$65'), findsOneWidget);
      expect(find.byKey(const ValueKey('diplomacy-info-page')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(controller.engine.playerMoney(0), 100);
    });
  }

  testWidgets('LAN viewer identity and open list update on host snapshot', (
    tester,
  ) async {
    final state = _fixture();
    final controller = await _open(tester, mod, state, localPlayer: 1);
    expect(find.byKey(const ValueKey('diplomacy-country-1')), findsNothing);
    expect(find.text('Сізге қарыз +\$35'), findsOneWidget);
    expect(find.text('Сіз қарыз −\$65'), findsOneWidget);
    expect(find.text('Қатынас: +24'), findsOneWidget);
    final update = GameState.fromJson(controller.state.toJson());
    update.turn = 2;
    update.diplomacyDebts[0][1] = 0;
    update.diplomacyDebts[1][0] = 12;
    update.diplomacySubsidies.clear();
    update.diplomacySocial.opinions[0][1] = 42;
    update.diplomacySocial.opinions[1][0] = 42;
    controller.replaceStateFromNetwork(update.toJson());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('diplomacy-country-1')), findsNothing);
    expect(find.text('Сізге қарыз +\$35'), findsNothing);
    expect(find.text('Сіз қарыз −\$12'), findsOneWidget);
    expect(find.text('Қатынас: +42'), findsOneWidget);
    expect(find.textContaining('Субсидия'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long names and large text wrap financial rows without overflow',
    (tester) async {
      final state = _fixture();
      state.setPlayerName(1, 'Аты өте ұзын дипломатиялық мемлекет');
      state.diplomacySubsidies.add(
        const DiplomacySubsidy(
          payer: 0,
          receiver: 1,
          amount: 10000,
          turnsLeft: 20,
          mandatory: true,
        ),
      );
      await _open(
        tester,
        mod,
        state,
        size: const Size(320, 720),
        textScale: 1.6,
      );
      final row = find.byKey(const ValueKey('diplomacy-country-1'));
      expect(tester.getSize(row).width, lessThanOrEqualTo(320));
      expect(find.text('Өтемақы −\$10000/ход · 20x'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('paused wartime debt remains visible on a narrow phone', (
    tester,
  ) async {
    final state = _fixture();
    GameEngine(
      mod: mod,
      state: state,
    ).setDiplomacyStatus(0, 1, DiplomacyStatus.war);
    await _open(tester, mod, state, size: const Size(320, 720), textScale: 1.6);
    expect(find.text('Сізге қарыз +\$65 · Төлем тоқтаулы'), findsOneWidget);
    expect(find.text('Сіз қарыз −\$35 · Төлем тоқтаулы'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<GameController> _open(
  WidgetTester tester,
  GameMod mod,
  GameState state, {
  Size size = const Size(390, 844),
  int? localPlayer,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  final controller = GameController(
    mod: mod,
    state: state,
    saves: SaveRepository(),
    autosaveEnabled: false,
    localPlayer: localPlayer,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: DalaTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAntiyoyDiplomacy(context, controller),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return controller;
}
