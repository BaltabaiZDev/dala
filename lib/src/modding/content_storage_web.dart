import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_storage.dart';

class PlatformContentStorage implements ContentStorage {
  static const _prefix = 'dala.content.file.';
  @override
  Future<String> location() async => 'Осы браузердегі DALA кітапханасы';
  @override
  Future<Map<String, Uint8List>> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final key in prefs.getKeys())
        if (key.startsWith(_prefix))
          key.substring(_prefix.length): base64Decode(prefs.getString(key)!),
    };
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('$_prefix$path', base64Encode(bytes))) {
      throw const FormatException(
        'Браузер жады толды. Пакетті сақтау мүмкін болмады.',
      );
    }
  }

  @override
  Future<void> remove(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$path');
  }
}
