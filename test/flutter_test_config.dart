import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Dala Math',
    )..addFont(rootBundle.load('assets/dala/fonts/NotoSansMath.ttf'))).load();
    await (FontLoader('Dala Symbols')
          ..addFont(rootBundle.load('assets/dala/fonts/NotoSansSymbols2.ttf')))
        .load();
    await (FontLoader(
      'Dala Sans',
    )..addFont(rootBundle.load('assets/dala/fonts/NotoSans.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  await testMain();
}
