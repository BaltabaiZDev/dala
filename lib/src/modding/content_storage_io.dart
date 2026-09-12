import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_storage.dart';
import 'content_package.dart';

class PlatformContentStorage implements ContentStorage, ContentFolderPicker {
  PlatformContentStorage({this.rootPath});
  final String? rootPath;
  static const _folderKey = 'dala.content.folder';
  static const _channel = MethodChannel('dala/content_folders');
  Future<String?> _selected() async =>
      rootPath ?? (await SharedPreferences.getInstance()).getString(_folderKey);
  @override
  bool get canChooseFolder => !Platform.isIOS;
  @override
  Future<bool> chooseFolder() async {
    final selected = Platform.isAndroid
        ? await _channel.invokeMethod<String>('choose')
        : await FilePicker.platform.getDirectoryPath();
    if (selected == null) return false;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_folderKey, selected)) {
      throw const FormatException('Қалта таңдауын сақтау мүмкін болмады.');
    }
    return true;
  }

  Future<Directory> _root() async {
    final root = Directory(
      await _selected() ??
          '${(await getApplicationDocumentsDirectory()).path}/DALA',
    );
    for (final folder in ['mods', 'maps']) {
      await Directory('${root.path}/$folder').create(recursive: true);
    }
    return root;
  }

  @override
  Future<String> location() async {
    final selected = await _selected();
    return selected != null && selected.startsWith('content:')
        ? selected
        : (await _root()).path;
  }

  @override
  Future<Map<String, Uint8List>> readAll() async {
    final selected = await _selected();
    if (selected != null && selected.startsWith('content:')) {
      final files = await _channel.invokeMapMethod<String, Uint8List>('read', {
        'tree': selected,
      });
      return files ?? {};
    }
    final root = await _root();
    final files = <String, Uint8List>{};
    for (final folder in ['mods', 'maps']) {
      await for (final file in Directory(
        '${root.path}/$folder',
      ).list(followLinks: false)) {
        if (file is! File) continue;
        final name = file.uri.pathSegments.last;
        if (!(folder == 'mods'
            ? ContentPackage.isModFile(name)
            : name.toLowerCase().endsWith('.dalamap'))) {
          continue;
        }
        if (files.length >= 100) {
          throw const FormatException(
            'Бір кітапханада ең көбі 100 пакет сақталады.',
          );
        }
        if (await file.length() > ContentPackage.maxBytes) {
          // Keep the file visible as an invalid entry without reading it all.
          files['$folder/$name'] = Uint8List(0);
        } else {
          files['$folder/$name'] = await file.readAsBytes();
        }
      }
    }
    return files;
  }

  Future<File> _file(String path) async {
    if (!RegExp(
      r'^(mods/[^/\\:]+\.(dalamod|zip)|maps/[^/\\:]+\.dalamap)$',
      caseSensitive: false,
    ).hasMatch(path)) {
      throw const FormatException('Файл атауы жарамсыз.');
    }
    return File('${(await _root()).path}/$path');
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final selected = await _selected();
    if (selected != null && selected.startsWith('content:')) {
      await _channel.invokeMethod<void>('write', {
        'tree': selected,
        'path': path,
        'bytes': bytes,
      });
      return;
    }
    final file = await _file(path);
    if (await file.exists()) return;
    final temp = File('${file.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> remove(String path) async {
    final selected = await _selected();
    if (selected != null && selected.startsWith('content:')) {
      await _channel.invokeMethod<void>('remove', {
        'tree': selected,
        'path': path,
      });
      return;
    }
    final file = await _file(path);
    if (await file.exists()) await file.delete();
  }
}
