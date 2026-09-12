import 'dart:convert';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'content_package.dart';
import 'content_storage.dart';
import 'game_mod.dart';

class InstalledMod {
  InstalledMod(this.path, this.package, {Set<String>? paths})
    : hash = package.mod.fingerprint,
      paths = Set.unmodifiable(paths ?? {path});
  final String path;
  final Set<String> paths;
  final ContentPackage package;
  final String hash;
  GameMod get mod => package.mod;
}

class InstalledMap {
  const InstalledMap(this.path, this.map, {this.packageHash});
  final String path;
  final DalaMap map;
  final String? packageHash;
}

class ContentLibrary extends ChangeNotifier {
  ContentLibrary(this.defaultMod, {ContentStorage? storage})
    : storage = storage ?? createContentStorage();
  final GameMod defaultMod;
  final ContentStorage storage;
  final List<InstalledMod> mods = [];
  final List<InstalledMap> maps = [];
  final List<String> errors = [];
  String? activeHash;
  String location = '';
  static const _activeKey = 'dala.content.activeMod';
  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  GameMod get activeMod =>
      mods.where((m) => m.hash == activeHash).firstOrNull?.mod ?? defaultMod;

  Future<void> refresh() async {
    mods.clear();
    maps.clear();
    errors.clear();
    final prefs = await SharedPreferences.getInstance();
    activeHash = prefs.getString(_activeKey);
    try {
      location = await storage.location();
      final files = await storage.readAll();
      for (final entry in files.entries) {
        try {
          if (entry.key.toLowerCase().endsWith('.dalamod')) {
            final package = await compute(_decodeMod, entry.value);
            await validateImages(package.mod);
            final installed = InstalledMod(entry.key, package);
            final existingIndex = mods.indexWhere(
              (m) => m.hash == installed.hash,
            );
            if (existingIndex < 0) {
              mods.add(installed);
            } else {
              final existing = mods[existingIndex];
              final uniqueMaps = {
                for (final map in [...existing.package.maps, ...package.maps])
                  map.fingerprint: map,
              };
              mods[existingIndex] = InstalledMod(
                existing.path,
                ContentPackage(
                  mod: existing.mod,
                  maps: uniqueMaps.values.toList(),
                ),
                paths: {...existing.paths, entry.key},
              );
            }
            maps.addAll(
              package.maps.map(
                (m) => InstalledMap(entry.key, m, packageHash: installed.hash),
              ),
            );
          } else {
            maps.add(
              InstalledMap(entry.key, await compute(_decodeMap, entry.value)),
            );
          }
        } on Object catch (error) {
          errors.add('${entry.key}: $error');
        }
      }
      mods.sort((a, b) => a.mod.name.compareTo(b.mod.name));
      final seenMaps = <String>{};
      maps.removeWhere(
        (entry) =>
            !seenMaps.add('${entry.packageHash}:${entry.map.fingerprint}'),
      );
      maps.sort((a, b) => a.map.name.compareTo(b.map.name));
      if (activeHash != null && !mods.any((m) => m.hash == activeHash)) {
        errors.add('Қосылған мод табылмады. Жаңа ойын кәдімгі режимге қайтты.');
        activeHash = null;
        await prefs.remove(_activeKey);
      }
    } on Object catch (error) {
      errors.add('Кітапхана ашылмады: $error');
    }
    _changed();
  }

  Future<void> activate(String? hash) async {
    if (hash != null && !mods.any((m) => m.hash == hash)) {
      throw const FormatException('Мод орнатылмаған.');
    }
    final prefs = await SharedPreferences.getInstance();
    final ok = hash == null
        ? await prefs.remove(_activeKey)
        : await prefs.setString(_activeKey, hash);
    if (!ok) throw const FormatException('Мод таңдауын сақтау мүмкін болмады.');
    activeHash = hash;
    _changed();
  }

  Future<void> importFile(String name, Uint8List bytes) async {
    if (name.toLowerCase().endsWith('.dalamod')) {
      final package = await compute(_decodeMod, bytes);
      await validateImages(package.mod);
      // Maps can change without changing the rules/sprite fingerprint. Keep
      // both packages so an updated map bundle is never silently discarded.
      final hash = sha256.convert(bytes).toString();
      await storage.write(
        'mods/${package.mod.id}-${hash.substring(0, 12)}.dalamod',
        bytes,
      );
    } else if (name.toLowerCase().endsWith('.dalamap')) {
      final map = await compute(_decodeMap, bytes);
      await storage.write(
        'maps/map-${map.fingerprint.substring(0, 16)}.dalamap',
        bytes,
      );
    } else {
      throw const FormatException(
        'DALA үшін .dalamod немесе .dalamap файлын таңдаңыз.',
      );
    }
    await refresh();
  }

  Future<void> remove(String path) async {
    final mod = mods.where((m) => m.paths.contains(path)).firstOrNull;
    for (final file in mod?.paths ?? {path}) {
      await storage.remove(file);
    }
    await refresh();
  }

  GameMod? modForMap(InstalledMap entry) {
    if (entry.map.modId == defaultMod.id) return defaultMod;
    return mods
        .where(
          (m) =>
              m.mod.id == entry.map.modId &&
              (entry.map.requiredModHash == null ||
                  entry.map.requiredModHash == m.hash) &&
              (entry.packageHash == null || entry.packageHash == m.hash),
        )
        .firstOrNull
        ?.mod;
  }

  GameMod resolveSavedMod(String id, Map<String, dynamic>? snapshot) {
    if (snapshot != null) {
      final mod = GameMod.fromJson(snapshot);
      if (mod.id != id) {
        throw const FormatException('Сақтаудағы мод id сәйкес емес.');
      }
      return mod;
    }
    if (id == defaultMod.id) return defaultMod;
    final matches = mods.where((m) => m.mod.id == id).toList();
    if (matches.length != 1) {
      throw FormatException('Сақтауды ашу үшін $id моды керек.');
    }
    return matches.single.mod;
  }

  static Future<void> validateImages(GameMod mod) async {
    for (final encoded in mod.sprites.values) {
      final codec = await ui.instantiateImageCodec(
        base64Decode(encoded),
        targetWidth: 128,
        targetHeight: 128,
      );
      try {
        (await codec.getNextFrame()).image.dispose();
      } finally {
        codec.dispose();
      }
    }
  }
}

ContentPackage _decodeMod(Uint8List bytes) => ContentPackage.decode(bytes);
DalaMap _decodeMap(Uint8List bytes) => DalaMap.decode(bytes);
