import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'content_package.dart';
import 'content_file_browser_stub.dart'
    if (dart.library.js_interop) 'content_file_browser.dart';

class ContentFiles {
  static Future<({String name, Uint8List bytes})?> pick() async {
    if (kIsWeb) return pickBrowserFile();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withReadStream: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    if (file.size > ContentPackage.maxBytes) {
      throw const FormatException('Файл 16 МБ-тан үлкен.');
    }
    final stream = file.readStream;
    if (stream == null) {
      throw const FormatException('Файлды оқу мүмкін болмады.');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (buffer.length + chunk.length > ContentPackage.maxBytes) {
        throw const FormatException('Файл 16 МБ-тан үлкен.');
      }
      buffer.add(chunk);
    }
    return (name: file.name, bytes: buffer.takeBytes());
  }

  static Future<bool> save(String name, Uint8List bytes) async =>
      await FilePicker.platform.saveFile(
        fileName: name,
        bytes: bytes,
        type: FileType.any,
      ) !=
      null;
}
