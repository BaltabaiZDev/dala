import 'dart:async';

import 'package:antiyoy_self/src/ui/antiyoy_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Antiyoy loader blocks input without a Material spinner', (
    tester,
  ) async {
    final task = Completer<void>();
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  taps++;
                  unawaited(
                    runWithAntiyoyLoader<void>(
                      context,
                      semanticsLabel: 'Карта жасалуда',
                      task: () => task.future,
                    ),
                  );
                },
                child: const Text('Бастау'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Бастау'));
    await tester.pump();
    expect(find.bySemanticsLabel('Карта жасалуда'), findsOneWidget);
    expect(find.text('...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Бастау'), warnIfMissed: false);
    expect(taps, 1);

    task.complete();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Карта жасалуда'), findsNothing);
  });
}
