// Run explicitly: flutter test tool/export_dala_brand_test.dart
// Rebuilds launcher artwork from the same original vector mark as the game.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:antiyoy_self/src/ui/dala_art.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export DALA launcher marks', () async {
    Future<void> save(String path, int size) async {
      final recorder = ui.PictureRecorder();
      DalaArt.drawBrand(ui.Canvas(recorder), size.toDouble());
      final picture = recorder.endRecording();
      final image = await picture.toImage(size, size);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    }

    for (final size in [192, 512]) {
      await save('web/icons/Icon-$size.png', size);
      await save('web/icons/Icon-maskable-$size.png', size);
    }
    await save('web/favicon.png', 32);
    await save('assets/dala/dala-mark.png', 512);
    await save('build/dala-icon-256.png', 256);
    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      await save(
        'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
        entry.value,
      );
    }
    const folder = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    final manifest =
        jsonDecode(await File('$folder/Contents.json').readAsString()) as Map;
    for (final entry in manifest['images'] as List) {
      final size = double.parse((entry['size'] as String).split('x').first);
      final scale = double.parse(
        (entry['scale'] as String).replaceAll('x', ''),
      );
      await save('$folder/${entry['filename']}', (size * scale).round());
    }
  });
}
