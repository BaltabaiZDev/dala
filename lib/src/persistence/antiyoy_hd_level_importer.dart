import '../game/map_generator.dart';
import '../game/models.dart';
import '../modding/game_mod.dart';

/// Converts a user-supplied Antiyoy HD level code into this game's save model.
///
/// This parser intentionally contains no bundled campaign data. It accepts the
/// documented text interchange format at the application boundary, validates
/// every supported section, and returns `null` for malformed or unsupported
/// input instead of partially importing it.
class AntiyoyHdLevelImporter {
  const AntiyoyHdLevelImporter();

  static const _prefix = 'onliyoy_level_code#';
  static const _maximumSourceLength = 2 * 1024 * 1024;
  static const _maximumHexCount = 5000;
  static const _maximumDimension = 192;
  static const _seaPadding = 3;

  static const List<(int, int)> _directions = [
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, 0),
    (-1, 1),
    (0, 1),
  ];

  static const Set<String> _colors = {
    'gray',
    'yellow',
    'green',
    'aqua',
    'cyan',
    'blue',
    'purple',
    'red',
    'brown',
    'mint',
    'lavender',
    'brass',
    'ice',
    'rose',
    'algae',
    'orchid',
    'whiskey',
  };

  static const Set<String> _aiEntityTypes = {
    'ai_random',
    'ai_balancer',
    'ai_easy',
    'ai_average',
    'ai_hard',
    'ai_expert',
  };

  GameState? decode(String raw, GameMod mod, {int? campaignLevel}) {
    try {
      return _decode(raw, mod, campaignLevel: campaignLevel);
    } on Object {
      return null;
    }
  }

  GameState? _decode(String raw, GameMod mod, {required int? campaignLevel}) {
    final source = raw.trim();
    if (source.length > _maximumSourceLength ||
        !source.startsWith(_prefix) ||
        (campaignLevel != null && campaignLevel <= 0)) {
      return null;
    }
    final sections = _readSections(source);
    if (sections == null ||
        !sections.keys.toSet().containsAll(const {
          'hexes',
          'player_entities',
          'provinces',
          'ready',
          'rules',
          'turn',
          'diplomacy',
        })) {
      return null;
    }

    final entities = _readEntities(sections['player_entities']!);
    if (entities == null ||
        entities.length < 2 ||
        entities.length > 15 ||
        entities.where((entity) => entity.human).length > 15) {
      return null;
    }
    final orderedEntities = <_HdEntity>[
      ...entities.where((entity) => entity.human),
      ...entities.where((entity) => !entity.human),
    ];
    final ownerByColor = <String, int>{
      for (var index = 0; index < orderedEntities.length; index++)
        orderedEntities[index].color: index,
    };

    final rule = _readRule(sections['rules']!);
    final fogOfWar = _readFog(sections['fog']);
    if (rule == null || fogOfWar == null) return null;

    final diplomacy = _readDiplomacy(
      sections['diplomacy']!,
      ownerByColor,
      orderedEntities.length,
    );
    if (diplomacy == null) return null;

    final rawHexes = _readHexes(sections['hexes']!, ownerByColor);
    if (rawHexes == null ||
        rawHexes.isEmpty ||
        rawHexes.length > _maximumHexCount) {
      return null;
    }
    final geometry = _buildGeometry(rawHexes, ownerByColor);
    if (geometry == null) return null;

    final turn = _readTurn(sections['turn']!, entities, ownerByColor);
    if (turn == null) return null;

    final readyCoordinates = _readCoordinates(sections['ready']!);
    if (readyCoordinates == null) return null;
    for (final tile in geometry.hexes) {
      if (tile.unit != null) tile.unit!.ready = false;
    }
    for (final coordinate in readyCoordinates) {
      final tileIndex = geometry.originalCoordinateToIndex[coordinate];
      if (tileIndex == null || geometry.hexes[tileIndex].unit == null) {
        return null;
      }
      geometry.hexes[tileIndex].unit!.ready = true;
    }

    final provinceData = _readProvinceData(sections['provinces']!);
    if (provinceData == null) return null;
    final provinces = _rebuildProvinces(
      geometry.hexes,
      provinceData,
      geometry.originalCoordinateToIndex,
    );
    if (provinces == null) return null;

    final mapSize = _readMapSize(sections['client_init'], rawHexes.length);
    if (mapSize == null) return null;

    final config = GameConfig(
      mapSize: mapSize,
      playerCount: orderedEntities.length,
      humanCount: orderedEntities.where((entity) => entity.human).length,
      seed: _stableHash(source),
      difficulty: _readDifficulty(orderedEntities),
      treePercent: 0,
      startingProvinceCount: 0,
      playerColorOffset: 0,
      slayRules: rule.slay,
      fogOfWar: fogOfWar,
      diplomacy: diplomacy.enabled,
      campaignLevel: campaignLevel,
    );
    final state = GameState(
      config: config,
      modId: mod.id,
      width: geometry.width,
      height: geometry.height,
      hexes: geometry.hexes,
      provinces: provinces,
      turn: turn.player,
      round: turn.lap + 1,
      rngState: _stableHash('$source#rng'),
      nextProvinceId: provinceData.nextProvinceId,
      diplomacyRelations: diplomacy.relations,
      diplomacyAllianceTurns: diplomacy.allianceTurns,
      diplomacyWarCooldowns: diplomacy.warCooldowns,
    );
    MapGenerator.ensureWaterCells(state);
    return state;
  }

  Map<String, String>? _readSections(String source) {
    final result = <String, String>{};
    for (final rawSection in source.substring(_prefix.length).split('#')) {
      if (rawSection.isEmpty) continue;
      final separator = rawSection.indexOf(':');
      if (separator <= 0) return null;
      final name = rawSection.substring(0, separator).trim();
      if (!RegExp(r'^[a-z_]+$').hasMatch(name) || result.containsKey(name)) {
        return null;
      }
      result[name] = rawSection.substring(separator + 1).trim();
    }
    return result;
  }

  List<_HdEntity>? _readEntities(String source) {
    final result = <_HdEntity>[];
    final colors = <String>{};
    for (final rawToken in source.split(',')) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      final fields = token.contains('>')
          ? token.split('>').map((value) => value.trim()).toList()
          : token.split(RegExp(r'\s+'));
      if (fields.length < 2) return null;
      final type = fields[0];
      final color = fields[1];
      final human = type == 'human';
      if ((!human && !_aiEntityTypes.contains(type)) ||
          color == 'gray' ||
          !_colors.contains(color) ||
          !colors.add(color)) {
        return null;
      }
      result.add(_HdEntity(type: type, color: color, human: human));
    }
    return result;
  }

  _HdRule? _readRule(String source) {
    final fields = source.split(RegExp(r'\s+'));
    if (fields.length != 2 || int.tryParse(fields[1]) != 1) return null;
    return switch (fields[0]) {
      'def' => const _HdRule(slay: false),
      'classic' => const _HdRule(slay: true),
      _ => null,
    };
  }

  bool? _readFog(String? source) {
    if (source == null) return false;
    return switch (source) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  }

  _HdDiplomacy? _readDiplomacy(
    String source,
    Map<String, int> ownerByColor,
    int playerCount,
  ) {
    if (source.isEmpty) return null;
    final enabled = source != 'off';
    final relations = <List<DiplomacyStatus>>[
      for (var first = 0; first < playerCount; first++)
        <DiplomacyStatus>[
          for (var second = 0; second < playerCount; second++)
            first == second
                ? DiplomacyStatus.alliance
                : enabled
                ? DiplomacyStatus.peace
                : DiplomacyStatus.war,
        ],
    ];
    final allianceTurns = <List<int>>[
      for (var first = 0; first < playerCount; first++)
        List<int>.filled(playerCount, 0),
    ];
    final warCooldowns = <List<int>>[
      for (var first = 0; first < playerCount; first++)
        List<int>.filled(playerCount, 0),
    ];
    if (!enabled) {
      return _HdDiplomacy(
        enabled: false,
        relations: relations,
        allianceTurns: allianceTurns,
        warCooldowns: warCooldowns,
      );
    }
    if (source == '-') {
      return _HdDiplomacy(
        enabled: true,
        relations: relations,
        allianceTurns: allianceTurns,
        warCooldowns: warCooldowns,
      );
    }
    final seenPairs = <(int, int)>{};
    for (final rawToken in source.split(',')) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      final fields = token.split(RegExp(r'\s+'));
      if (fields.length != 4) return null;
      final first = ownerByColor[fields[1]];
      final second = ownerByColor[fields[2]];
      final lock = int.tryParse(fields[3]);
      if (first == null ||
          second == null ||
          first == second ||
          lock == null ||
          lock < 0 ||
          lock > 999) {
        return null;
      }
      final pair = first < second ? (first, second) : (second, first);
      if (!seenPairs.add(pair)) return null;
      final status = switch (fields[0]) {
        'war' => DiplomacyStatus.war,
        'neutral' => DiplomacyStatus.peace,
        'friend' => DiplomacyStatus.alliance,
        'alliance' => DiplomacyStatus.coalition,
        _ => null,
      };
      if (status == null) return null;
      relations[first][second] = status;
      relations[second][first] = status;
      // The local model has no generic relation lock. Its war cooldown is the
      // exact equivalent for war/peace transitions, while friendship and
      // military-alliance durations have different semantics and must not be
      // populated from an HD lock.
      if (status != DiplomacyStatus.alliance &&
          status != DiplomacyStatus.coalition) {
        warCooldowns[first][second] = lock;
        warCooldowns[second][first] = lock;
      }
    }
    return _HdDiplomacy(
      enabled: true,
      relations: relations,
      allianceTurns: allianceTurns,
      warCooldowns: warCooldowns,
    );
  }

  List<_RawHdHex>? _readHexes(String source, Map<String, int> ownerByColor) {
    final result = <_RawHdHex>[];
    final coordinates = <(int, int)>{};
    for (final rawToken in source.split(',')) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      final fields = token.split(RegExp(r'\s+'));
      if (fields.length != 3 && fields.length != 5) return null;
      final q = int.tryParse(fields[0]);
      final r = int.tryParse(fields[1]);
      final color = fields[2];
      if (q == null ||
          r == null ||
          q.abs() > 10000 ||
          r.abs() > 10000 ||
          !_colors.contains(color) ||
          !coordinates.add((q, r)) ||
          (color != 'gray' && !ownerByColor.containsKey(color))) {
        return null;
      }
      String? piece;
      if (fields.length == 5) {
        piece = fields[3];
        if (int.tryParse(fields[4]) == null || !_isSupportedPiece(piece)) {
          return null;
        }
        if (color == 'gray' && _unitStrength(piece) != null) return null;
      }
      result.add(_RawHdHex(q: q, r: r, color: color, piece: piece));
      if (result.length > _maximumHexCount) return null;
    }
    return result;
  }

  bool _isSupportedPiece(String piece) =>
      _unitStrength(piece) != null ||
      const {
        'palm',
        'pine',
        'tower',
        'city',
        'farm',
        'strong_tower',
        'grave',
      }.contains(piece);

  int? _unitStrength(String? piece) => switch (piece) {
    'peasant' => 1,
    'spearman' => 2,
    'baron' => 3,
    'knight' => 4,
    _ => null,
  };

  TileObject _tileObject(String? piece) => switch (piece) {
    'palm' => TileObject.palm,
    'pine' => TileObject.pine,
    'tower' => TileObject.tower,
    'city' => TileObject.town,
    'farm' => TileObject.farm,
    'strong_tower' => TileObject.strongTower,
    'grave' => TileObject.grave,
    _ => TileObject.none,
  };

  _HdGeometry? _buildGeometry(
    List<_RawHdHex> source,
    Map<String, int> ownerByColor,
  ) {
    final minimumQ = source.map((tile) => tile.q).reduce(_minimum);
    final maximumQ = source.map((tile) => tile.q).reduce(_maximum);
    final minimumR = source.map((tile) => tile.r).reduce(_minimum);
    final maximumR = source.map((tile) => tile.r).reduce(_maximum);
    final width = maximumQ - minimumQ + 1 + 2 * _seaPadding;
    final height = maximumR - minimumR + 1 + 2 * _seaPadding;
    if (width <= 0 ||
        height <= 0 ||
        width > _maximumDimension ||
        height > _maximumDimension) {
      return null;
    }

    final sourceCoordinates = <(int, int)>{
      for (final tile in source) (tile.q, tile.r),
    };
    var inWorldCoordinates = {...sourceCoordinates};
    for (var ring = 0; ring < _seaPadding; ring++) {
      final expanded = {...inWorldCoordinates};
      for (final coordinate in inWorldCoordinates) {
        for (final direction in _directions) {
          expanded.add((
            coordinate.$1 + direction.$1,
            coordinate.$2 + direction.$2,
          ));
        }
      }
      inWorldCoordinates = expanded;
    }

    final offsetQ = _seaPadding - minimumQ;
    final offsetR = _seaPadding - minimumR;
    final hexes = <HexTile>[
      for (var r = 0; r < height; r++)
        for (var q = 0; q < width; q++)
          HexTile(
            index: r * width + q,
            q: q,
            r: r,
            inWorld: inWorldCoordinates.contains((q - offsetQ, r - offsetR)),
          ),
    ];
    _wireNeighbors(hexes, width, height);
    final originalCoordinateToIndex = <(int, int), int>{};
    for (final rawTile in source) {
      final q = rawTile.q + offsetQ;
      final r = rawTile.r + offsetR;
      final index = r * width + q;
      final strength = _unitStrength(rawTile.piece);
      hexes[index]
        ..inWorld = true
        ..active = true
        ..owner = rawTile.color == 'gray' ? -1 : ownerByColor[rawTile.color]!
        ..object = _tileObject(rawTile.piece)
        ..unit = strength == null
            ? null
            : GameUnit(strength: strength, ready: false)
        ..treeBorn = -1;
      originalCoordinateToIndex[(rawTile.q, rawTile.r)] = index;
    }
    return _HdGeometry(
      width: width,
      height: height,
      hexes: hexes,
      originalCoordinateToIndex: originalCoordinateToIndex,
    );
  }

  void _wireNeighbors(List<HexTile> hexes, int width, int height) {
    for (final tile in hexes) {
      for (final direction in _directions) {
        final q = tile.q + direction.$1;
        final r = tile.r + direction.$2;
        if (q >= 0 && q < width && r >= 0 && r < height) {
          tile.neighbors.add(r * width + q);
        }
      }
    }
  }

  _HdTurn? _readTurn(
    String source,
    List<_HdEntity> originalEntities,
    Map<String, int> ownerByColor,
  ) {
    final fields = source.split(RegExp(r'\s+'));
    if (fields.length != 2) return null;
    final originalPlayer = int.tryParse(fields[0]);
    final lap = int.tryParse(fields[1]);
    if (originalPlayer == null ||
        lap == null ||
        originalPlayer < 0 ||
        originalPlayer >= originalEntities.length ||
        lap < 0) {
      return null;
    }
    return _HdTurn(
      player: ownerByColor[originalEntities[originalPlayer].color]!,
      lap: lap,
    );
  }

  Set<(int, int)>? _readCoordinates(String source) {
    if (source == '-') return <(int, int)>{};
    final result = <(int, int)>{};
    for (final rawToken in source.split(',')) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      final fields = token.split(RegExp(r'\s+'));
      if (fields.length != 2) return null;
      final q = int.tryParse(fields[0]);
      final r = int.tryParse(fields[1]);
      if (q == null || r == null || !result.add((q, r))) return null;
    }
    return result;
  }

  _HdProvinceData? _readProvinceData(String source) {
    final outer = source.split('>');
    if (outer.isEmpty) return null;
    final encodedNextId = int.tryParse(outer.first.trim());
    if (encodedNextId == null || encodedNextId < 0 || outer.length > 2) {
      return null;
    }
    final provinces = <_HdProvince>[];
    final ids = <int>{};
    final coordinates = <(int, int)>{};
    if (outer.length == 2 && outer[1].trim().isNotEmpty) {
      for (final rawToken in outer[1].split(',')) {
        final token = rawToken.trim();
        // Antiyoy HD terminates the province list with a comma. Match the
        // other section readers and ignore that final empty record.
        if (token.isEmpty) continue;
        final fields = token.split('<');
        if (fields.length < 5) return null;
        final q = int.tryParse(fields[0]);
        final r = int.tryParse(fields[1]);
        final id = int.tryParse(fields[2]);
        final money = int.tryParse(fields[3]);
        if (q == null ||
            r == null ||
            id == null ||
            id < 0 ||
            money == null ||
            money < -1000000000 ||
            money > 1000000000 ||
            !ids.add(id) ||
            !coordinates.add((q, r))) {
          return null;
        }
        provinces.add(_HdProvince(q: q, r: r, id: id, money: money));
      }
    }
    final minimumNextId = ids.isEmpty ? 0 : ids.reduce(_maximum) + 1;
    return _HdProvinceData(
      nextProvinceId: encodedNextId < minimumNextId
          ? minimumNextId
          : encodedNextId,
      provinces: provinces,
    );
  }

  List<Province>? _rebuildProvinces(
    List<HexTile> hexes,
    _HdProvinceData data,
    Map<(int, int), int> coordinateToIndex,
  ) {
    final metadataByTile = <int, _HdProvince>{};
    for (final metadata in data.provinces) {
      final index = coordinateToIndex[(metadata.q, metadata.r)];
      if (index == null ||
          !hexes[index].active ||
          hexes[index].owner < 0 ||
          metadataByTile.containsKey(index)) {
        return null;
      }
      metadataByTile[index] = metadata;
    }

    final rebuilt = <Province>[];
    final consumedMetadata = <int>{};
    final seen = <int>{};
    for (final start in hexes) {
      if (!start.active || start.owner < 0 || !seen.add(start.index)) continue;
      final component = <int>[];
      final queue = <int>[start.index];
      for (var cursor = 0; cursor < queue.length; cursor++) {
        final index = queue[cursor];
        component.add(index);
        for (final neighbor in hexes[index].neighbors) {
          if (hexes[neighbor].active &&
              hexes[neighbor].owner == start.owner &&
              seen.add(neighbor)) {
            queue.add(neighbor);
          }
        }
      }
      if (component.length < 2) continue;
      final matchingMetadata = component
          .where(metadataByTile.containsKey)
          .map((index) => metadataByTile[index]!)
          .toList();
      if (matchingMetadata.length != 1) return null;
      final metadata = matchingMetadata.single;
      consumedMetadata.add(metadata.id);

      final towns =
          component
              .where((index) => hexes[index].object == TileObject.town)
              .toList()
            ..sort();
      late final int capital;
      if (towns.isNotEmpty) {
        capital = towns.first;
        for (final extra in towns.skip(1)) {
          hexes[extra].object = TileObject.none;
        }
      } else {
        final free =
            component
                .where(
                  (index) =>
                      hexes[index].object == TileObject.none &&
                      hexes[index].unit == null,
                )
                .toList()
              ..sort();
        capital = free.isNotEmpty ? free.first : (component..sort()).first;
        hexes[capital]
          ..object = TileObject.town
          ..unit = null
          ..treeBorn = -1;
      }
      rebuilt.add(
        Province(
          id: metadata.id,
          owner: start.owner,
          tiles: component..sort(),
          money: metadata.money,
          capital: capital,
        ),
      );
    }
    if (consumedMetadata.length != data.provinces.length) return null;
    return rebuilt;
  }

  MapSize? _readMapSize(String? source, int landCount) {
    if (source == null) {
      if (landCount <= 140) return MapSize.small;
      if (landCount <= 260) return MapSize.medium;
      if (landCount <= 450) return MapSize.large;
      return MapSize.huge;
    }
    final encoded = source.split(',').first.trim();
    return switch (encoded) {
      'tiny' || 'small' => MapSize.small,
      'normal' || 'big' => MapSize.medium,
      'large' => MapSize.large,
      'giant' || 'giant_landscape' => MapSize.giant,
      _ => null,
    };
  }

  AiDifficulty _readDifficulty(List<_HdEntity> entities) {
    var result = AiDifficulty.veryEasy;
    for (final entity in entities.where((entity) => !entity.human)) {
      final difficulty = switch (entity.type) {
        'ai_random' => AiDifficulty.veryEasy,
        'ai_easy' => AiDifficulty.easy,
        'ai_average' || 'ai_balancer' => AiDifficulty.normal,
        'ai_hard' => AiDifficulty.hard,
        'ai_expert' => AiDifficulty.master,
        _ => AiDifficulty.normal,
      };
      if (difficulty.index > result.index) result = difficulty;
    }
    return result;
  }

  int _stableHash(String source) {
    var hash = 0x811c9dc5;
    for (final codeUnit in source.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 0x6d2b79f5 : hash;
  }

  int _minimum(int first, int second) => first < second ? first : second;
  int _maximum(int first, int second) => first > second ? first : second;
}

class _HdEntity {
  const _HdEntity({
    required this.type,
    required this.color,
    required this.human,
  });

  final String type;
  final String color;
  final bool human;
}

class _HdRule {
  const _HdRule({required this.slay});

  final bool slay;
}

class _RawHdHex {
  const _RawHdHex({
    required this.q,
    required this.r,
    required this.color,
    required this.piece,
  });

  final int q;
  final int r;
  final String color;
  final String? piece;
}

class _HdGeometry {
  const _HdGeometry({
    required this.width,
    required this.height,
    required this.hexes,
    required this.originalCoordinateToIndex,
  });

  final int width;
  final int height;
  final List<HexTile> hexes;
  final Map<(int, int), int> originalCoordinateToIndex;
}

class _HdTurn {
  const _HdTurn({required this.player, required this.lap});

  final int player;
  final int lap;
}

class _HdProvince {
  const _HdProvince({
    required this.q,
    required this.r,
    required this.id,
    required this.money,
  });

  final int q;
  final int r;
  final int id;
  final int money;
}

class _HdProvinceData {
  const _HdProvinceData({
    required this.nextProvinceId,
    required this.provinces,
  });

  final int nextProvinceId;
  final List<_HdProvince> provinces;
}

class _HdDiplomacy {
  const _HdDiplomacy({
    required this.enabled,
    required this.relations,
    required this.allianceTurns,
    required this.warCooldowns,
  });

  final bool enabled;
  final List<List<DiplomacyStatus>> relations;
  final List<List<int>> allianceTurns;
  final List<List<int>> warCooldowns;
}
