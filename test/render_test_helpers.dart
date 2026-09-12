import 'package:antiyoy_self/src/ui/hex_board.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A visual assertion must inspect the loaded game, not win a race against
/// asynchronous image decoding on a busy test runner.
Future<void> waitForMapSprites(WidgetTester tester) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
    if (painters.any(
      (widget) =>
          widget.painter is HexBoardPainter &&
          (widget.painter! as HexBoardPainter).sprites != null,
    )) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('Map sprites did not finish loading before the visual check');
}
