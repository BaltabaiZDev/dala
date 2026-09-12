import 'package:antiyoy_self/src/ui/top_snack_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('top notice uses the root safe area from a nested SafeArea', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 44);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTopSnackBar(
                  context,
                  'Жоғарғы хабарлама',
                  duration: const Duration(milliseconds: 80),
                ),
                child: const Text('Көрсету'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Көрсету'));
    await tester.pump();

    final notice = find.byKey(const ValueKey('top-snack-bar'));
    expect(notice, findsOneWidget);
    expect(tester.getTopLeft(notice).dy, greaterThanOrEqualTo(52));

    await tester.pump(const Duration(milliseconds: 100));
    expect(notice, findsNothing);
  });
}
