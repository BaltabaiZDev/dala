import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../game/models.dart';
import '../game/game_engine.dart';
import '../persistence/editor_repository.dart';
import 'game_mod.dart';

/// Portable, declarative content. DALA packages never execute scripts.
class ContentPackage {
  const ContentPackage({required this.mod, this.maps = const []});
  final GameMod mod;
  final List<DalaMap> maps;
  static const maxBytes = 16 * 1024 * 1024;
  static const maxExpandedBytes = 32 * 1024 * 1024;

  /// File managers may append .zip when saving or compressing a mod package.
  /// The archive's manifest is still validated before anything is installed.
  static bool isModFile(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.dalamod') || lower.endsWith('.zip');
  }

  static ContentPackage decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('Пакет 16 МБ-тан үлкен.');
    }
    try {
      // Inspect headers before ZipDecoder reads any symlink target or inflates
      // data; its Archive representation otherwise coalesces duplicate names.
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      var declaredBytes = 0;
      final names = <String>{};
      if (directory.fileHeaders.length > 128) {
        throw const FormatException('Пакетте тым көп файл бар.');
      }
      for (final header in directory.fileHeaders) {
        declaredBytes += header.uncompressedSize;
        if (!names.add(header.filename) ||
            declaredBytes > maxExpandedBytes ||
            ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
            header.uncompressedSize != header.file?.uncompressedSize) {
          throw const FormatException(
            'Архивтегі көлем, сілтеме не қайталанған файл жарамсыз.',
          );
        }
      }
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.length > 128) {
        throw const FormatException('Пакетте 128-ден көп файл бар.');
      }
      var expanded = 0;
      final files = <String, ArchiveFile>{};
      for (final file in archive) {
        final path = file.name;
        if (path.startsWith('/') ||
            path.contains('\\') ||
            path.contains(':') ||
            path.split('/').contains('..') ||
            file.isSymbolicLink) {
          throw const FormatException('Пакеттегі файл жолы жарамсыз.');
        }
        if (!file.isFile) continue;
        expanded += file.size;
        if (expanded > maxExpandedBytes || files.containsKey(path)) {
          throw const FormatException(
            'Пакет көлемі не файл атаулары жарамсыз.',
          );
        }
        files[path] = file;
      }
      // Desktop/mobile archivers often wrap the selected folder itself.
      // Accept one shared wrapper, after validating every original path above.
      if (!files.containsKey('mod.json') && files.isNotEmpty) {
        final wrapper = files.keys.first.split('/').first;
        final prefix = '$wrapper/';
        if (wrapper.isNotEmpty &&
            files.containsKey('${prefix}mod.json') &&
            files.keys.every((path) => path.startsWith(prefix))) {
          final unwrapped = {
            for (final entry in files.entries)
              entry.key.substring(prefix.length): entry.value,
          };
          files
            ..clear()
            ..addAll(unwrapped);
        }
      }
      final manifest = files['mod.json'];
      if (manifest == null || manifest.size > 1024 * 1024) {
        throw const FormatException('Пакеттің түбінде mod.json болуы керек.');
      }
      final root = jsonDecode(utf8.decode(manifest.content));
      if (root is! Map ||
          root['format'] != 'dala-mod' ||
          !const [1, 2, 3].contains(root['version']) ||
          root['mod'] is! Map) {
        throw const FormatException('Бұл DALA мод пакеті емес.');
      }
      final raw = Map<String, dynamic>.from(root['mod'] as Map);
      if (raw.containsKey('sprites')) {
        throw const FormatException(
          'Суреттер sprites/ қалтасында болуы керек.',
        );
      }
      raw['sprites'] = {
        for (final entry in files.entries)
          if (entry.key.startsWith('sprites/') && entry.key.endsWith('.png'))
            entry.key.substring(8, entry.key.length - 4): base64Encode(
              entry.value.content,
            ),
      };
      final mod = GameMod.fromJson(raw);
      if (mod.components.isNotEmpty ||
          mod.id == 'classic_steppe' ||
          !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(mod.id)) {
        throw const FormatException(
          'Модқа жеке id беріңіз: a–z, 0–9, _ немесе -.',
        );
      }
      final maps = <DalaMap>[];
      for (final entry in files.entries) {
        if (entry.key == 'mod.json' ||
            entry.key == 'README.md' ||
            entry.key == 'LICENSE') {
          continue;
        }
        if (entry.key.startsWith('sprites/') && entry.key.endsWith('.png')) {
          continue;
        }
        if (entry.key.startsWith('maps/') && entry.key.endsWith('.dalamap')) {
          maps.add(DalaMap.decode(entry.value.content, mod: mod));
        } else {
          throw FormatException('Қолдау жоқ файл: ${entry.key}');
        }
      }
      return ContentPackage(mod: mod, maps: List.unmodifiable(maps));
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Мод архивін оқу мүмкін болмады.');
    }
  }

  Uint8List encode() {
    final archive = Archive();
    final raw = mod.toJson()..remove('sprites');
    archive.addFile(
      ArchiveFile.bytes(
        'mod.json',
        utf8.encode(
          jsonEncode({
            'format': 'dala-mod',
            'version': mod.buildings.values.any((b) => b.production.isNotEmpty)
                ? 3
                : mod.buildings.isEmpty && mod.units.isEmpty
                ? 1
                : 2,
            'mod': raw,
          }),
        ),
      ),
    );
    for (final entry in mod.sprites.entries) {
      archive.addFile(
        ArchiveFile.bytes(
          'sprites/${entry.key}.png',
          base64Decode(entry.value),
        ),
      );
    }
    for (var i = 0; i < maps.length; i++) {
      archive.addFile(
        ArchiveFile.bytes('maps/map-$i.dalamap', maps[i].encode()),
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }
}

class DalaMap {
  const DalaMap({
    required this.name,
    required this.stateJson,
    this.requiredModHash,
    this.requiredMods = const [],
  });
  final String name;
  final Map<String, dynamic> stateJson;
  final String? requiredModHash;
  final List<ModReference> requiredMods;
  String get modId => stateJson['modId'] as String;
  String get fingerprint => sha256.convert(encode()).toString();
  int get width => stateJson['width'] as int;
  int get height => stateJson['height'] as int;
  int get playerCount => (stateJson['config'] as Map)['playerCount'] as int;
  Set<int> get activeFactions => {
    for (final province in stateJson['provinces'] as List)
      (province as Map)['owner'] as int,
  };

  // Human seats in the engine are the first N factions. Never assign a device
  // to an empty faction in a hand-painted map (it cannot take a turn).
  int get maxHumanCount {
    final active = activeFactions;
    var count = 0;
    while (count < playerCount && active.contains(count)) {
      count++;
    }
    return count;
  }

  factory DalaMap.fromState(String name, GameState state, GameMod mod) {
    GameEngine(
      mod: mod,
      state: GameState.fromJson(state.toJson()),
    ).validateModState();
    if (!EditorRepository.isValidState(
      state,
      expectedModId: mod.id,
      requirePlayable: true,
      rules: mod.rules,
    )) {
      throw const FormatException(
        'Картада кемінде екі ойнайтын тарап болуы керек.',
      );
    }
    return DalaMap(
      name: _name(name),
      stateJson: state.toJson()..remove('modSnapshot'),
      requiredModHash: mod.id == 'classic_steppe' ? null : mod.fingerprint,
      requiredMods: mod.requirements,
    );
  }

  static DalaMap decode(List<int> bytes, {GameMod? mod}) {
    if (bytes.length > ContentPackage.maxBytes) {
      throw const FormatException('Карта тым үлкен.');
    }
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map ||
          raw['format'] != 'dala-map' ||
          !const [1, 2].contains(raw['version']) ||
          raw['state'] is! Map) {
        throw const FormatException('Бұл .dalamap картасы емес.');
      }
      final state = Map<String, dynamic>.from(raw['state'] as Map)
        ..remove('modSnapshot');
      final width = state['width'];
      final height = state['height'];
      if (width is! int ||
          height is! int ||
          width < 1 ||
          height < 1 ||
          width * height > 16384 ||
          state['hexes'] is! List ||
          (state['hexes'] as List).length != width * height) {
        throw const FormatException(
          'Карта өлшемі жарамсыз (ең көбі 16384 ұяшық).',
        );
      }
      final hash = raw['requiredModHash'];
      if (hash != null &&
          (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))) {
        throw const FormatException('Картаның мод нұсқасы жарамсыз.');
      }
      final map = DalaMap(
        name: _name(raw['name']),
        stateJson: state,
        requiredModHash: hash as String?,
        requiredMods: ModReference.readList(raw['requiredMods']),
      );
      if (EditorRepository.decodeStateJson(
            state,
            requirePlayable: true,
            rules: mod?.rules,
          ) ==
          null) {
        throw const FormatException(
          'Карта құрылымы немесе ойын ережесі жарамсыз.',
        );
      }
      if (mod != null) map.createState(mod);
      return map;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Картаны оқу мүмкін болмады.');
    }
  }

  GameState createState(
    GameMod mod, {
    bool multiplayer = false,
    int? humanCount,
  }) {
    if (modId != mod.id ||
        (requiredModHash != null && requiredModHash != mod.fingerprint)) {
      throw FormatException('Картаға $modId модының сәйкес нұсқасы керек.');
    }
    final copy = jsonDecode(jsonEncode(stateJson)) as Map<String, dynamic>;
    final config = copy['config'] as Map<String, dynamic>;
    final minimum = multiplayer ? 2 : 1;
    if (maxHumanCount < minimum) {
      throw const FormatException(
        'Бұл картада LAN үшін алғашқы екі тараптың да жері болуы керек. Редакторда түзетіңіз.',
      );
    }
    final humans =
        humanCount ??
        (multiplayer
            ? 2
            : (config['humanCount'] as int? ?? 1).clamp(1, maxHumanCount));
    if (humans < minimum || humans > maxHumanCount) {
      throw const FormatException('Адам саны карта орындарына сәйкес емес.');
    }
    config['humanCount'] = humans;
    // A custom scenario is never an official campaign completion.
    config.remove('campaignLevel');
    final state = EditorRepository.decodeStateJson(
      copy,
      expectedModId: mod.id,
      requirePlayable: true,
      rules: mod.rules,
    );
    if (state == null) {
      throw const FormatException('Карта осы ережелермен ойналмайды.');
    }
    state.modSnapshot = mod.toJson();
    GameEngine(mod: mod, state: state).validateModState();
    return state;
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': 'dala-map',
        'version':
            (stateJson['hexes'] as List).any(
                  (tile) =>
                      tile['buildingTypeId'] != null ||
                      tile['airUnit'] != null ||
                      tile['unit']?['typeId'] != null,
                ) ||
                (stateJson['waterCells'] as List? ?? []).any(
                  (cell) => (cell['boat']?['cargo'] as List? ?? []).any(
                    (unit) => unit['typeId'] != null,
                  ),
                )
            ? 2
            : 1,
        'name': name,
        if (requiredModHash != null) 'requiredModHash': requiredModHash,
        if (requiredMods.isNotEmpty)
          'requiredMods': requiredMods.map((m) => m.toJson()).toList(),
        'state': stateJson,
      }),
    ),
  );

  static String _name(Object? raw) {
    if (raw is! String || raw.trim().isEmpty || raw.length > 80) {
      throw const FormatException('Карта атауы 1–80 таңба болуы керек.');
    }
    return raw.trim();
  }
}
