import 'dart:typed_data';
import 'content_storage_web.dart'
    if (dart.library.io) 'content_storage_io.dart'
    as platform;

abstract class ContentStorage {
  Future<String> location();
  Future<Map<String, Uint8List>> readAll();
  Future<void> write(String path, Uint8List bytes);
  Future<void> remove(String path);
}

abstract class ContentFolderPicker {
  bool get canChooseFolder;
  Future<bool> chooseFolder();
}

ContentStorage createContentStorage() => platform.PlatformContentStorage();
