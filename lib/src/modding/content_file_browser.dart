import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart';
import 'content_package.dart';

/// Keep the input attached until the chooser completes. Removing it directly
/// after click (as older file picker versions do) loses chooser ownership in
/// embedded browsers and prevents automated file selection from completing.
Future<({String name, Uint8List bytes})?> pickBrowserFile() {
  final complete = Completer<({String name, Uint8List bytes})?>();
  final input = HTMLInputElement()
    ..type = 'file'
    ..accept = '.dalamod,.zip,.dalamap';
  input.style.display = 'none';
  input.addEventListener(
    'cancel',
    ((Event _) {
      if (!complete.isCompleted) complete.complete(null);
      input.remove();
    }).toJS,
  );
  input.addEventListener(
    'change',
    ((Event _) {
      final file = input.files?.item(0);
      if (file == null) {
        if (!complete.isCompleted) complete.complete(null);
        input.remove();
        return;
      }
      if (file.size > ContentPackage.maxBytes) {
        complete.completeError(const FormatException('Файл 16 МБ-тан үлкен.'));
        input.remove();
        return;
      }
      final reader = FileReader();
      reader.addEventListener(
        'load',
        ((Event _) {
          final buffer = reader.result as JSArrayBuffer;
          if (!complete.isCompleted) {
            complete.complete((
              name: file.name,
              bytes: buffer.toDart.asUint8List(),
            ));
          }
          input.remove();
        }).toJS,
      );
      reader.addEventListener(
        'error',
        ((Event _) {
          if (!complete.isCompleted) {
            complete.completeError(
              const FormatException('Файлды оқу мүмкін болмады.'),
            );
          }
          input.remove();
        }).toJS,
      );
      reader.readAsArrayBuffer(file);
    }).toJS,
  );
  document.body!.append(input);
  input.click();
  return complete.future;
}
