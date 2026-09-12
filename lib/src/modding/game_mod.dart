import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

class ModReference {
  const ModReference({
    required this.id,
    required this.name,
    required this.version,
    required this.hash,
  });
  final String id;
  final String name;
  final int version;
  final String hash;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'hash': hash,
  };
  factory ModReference.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        !(RegExp(
          r'^[a-z0-9][a-z0-9_-]{0,63}$',
        ).hasMatch(json['id'] as String)) ||
        json['name'] is! String ||
        (json['name'] as String).length > 80 ||
        json['version'] is! int ||
        (json['version'] as int) < 1 ||
        json['hash'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['hash'] as String)) {
      throw const FormatException('Мод нұсқасының сипаттамасы жарамсыз.');
    }
    return ModReference(
      id: json['id'] as String,
      name: json['name'] as String,
      version: json['version'] as int,
      hash: json['hash'] as String,
    );
  }
  static List<ModReference> readList(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 32 || raw.any((v) => v is! Map)) {
      throw const FormatException('Модтар тізімі жарамсыз.');
    }
    final values = raw
        .map((v) => ModReference.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (values.map((v) => v.id).toSet().length != values.length) {
      throw const FormatException(
        'Бір модтың екі нұсқасын қатар қосуға болмайды.',
      );
    }
    return List.unmodifiable(values);
  }
}

class GameRules {
  const GameRules({
    required this.unitMoveLimit,
    required this.unitPricePerLevel,
    required this.farmBasePrice,
    required this.farmPriceGrowth,
    required this.towerPrice,
    required this.strongTowerPrice,
    required this.farmIncome,
    required this.treeCutReward,
    required this.unitUpkeep,
    required this.towerUpkeep,
    required this.strongTowerUpkeep,
    required this.port1Price,
    required this.port2Price,
    required this.boat1Price,
    required this.boat2Price,
    required this.port1Upkeep,
    required this.port2Upkeep,
    required this.boat1Upkeep,
    required this.boat2Upkeep,
    required this.boatMoveLimit,
    required this.portLaunchRadius,
    required this.boat1Capacity,
    required this.boat2Capacity,
    required this.seaFortPrice,
    required this.seaFortUpkeep,
    required this.navalSupplyUpkeep,
    required this.artilleryCosts,
    required this.artilleryUpkeep,
    required this.artilleryAmmoCapacity,
    required this.artilleryShotCost,
    required this.initialMoney,
    required this.pineSpreadChance,
    required this.palmSpreadChance,
  });

  final int unitMoveLimit;
  final int unitPricePerLevel;
  final int farmBasePrice;
  final int farmPriceGrowth;
  final int towerPrice;
  final int strongTowerPrice;
  final int farmIncome;
  final int treeCutReward;
  final List<int> unitUpkeep;
  final int towerUpkeep;
  final int strongTowerUpkeep;
  final int port1Price;
  final int port2Price;
  final int boat1Price;
  final int boat2Price;
  final int port1Upkeep;
  final int port2Upkeep;
  final int boat1Upkeep;
  final int boat2Upkeep;
  final int boatMoveLimit;
  final int portLaunchRadius;
  final int boat1Capacity;
  final int boat2Capacity;
  final int seaFortPrice;
  final int seaFortUpkeep;
  final int navalSupplyUpkeep;
  final List<int> artilleryCosts;
  final List<int> artilleryUpkeep;
  final List<int> artilleryAmmoCapacity;
  // Retained for backwards-compatible mod loading. Artillery ammunition is
  // automatic now, so the simulation no longer charges per shot.
  final int artilleryShotCost;
  final int initialMoney;
  final double pineSpreadChance;
  final double palmSpreadChance;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'unitMoveLimit': unitMoveLimit,
    'unitPricePerLevel': unitPricePerLevel,
    'farmBasePrice': farmBasePrice,
    'farmPriceGrowth': farmPriceGrowth,
    'towerPrice': towerPrice,
    'strongTowerPrice': strongTowerPrice,
    'farmIncome': farmIncome,
    'treeCutReward': treeCutReward,
    'unitUpkeep': unitUpkeep,
    'towerUpkeep': towerUpkeep,
    'strongTowerUpkeep': strongTowerUpkeep,
    'port1Price': port1Price,
    'port2Price': port2Price,
    'boat1Price': boat1Price,
    'boat2Price': boat2Price,
    'port1Upkeep': port1Upkeep,
    'port2Upkeep': port2Upkeep,
    'boat1Upkeep': boat1Upkeep,
    'boat2Upkeep': boat2Upkeep,
    'boatMoveLimit': boatMoveLimit,
    'portLaunchRadius': portLaunchRadius,
    'boat1Capacity': boat1Capacity,
    'boat2Capacity': boat2Capacity,
    'seaFortPrice': seaFortPrice,
    'seaFortUpkeep': seaFortUpkeep,
    'navalSupplyUpkeep': navalSupplyUpkeep,
    'artilleryCosts': artilleryCosts,
    'artilleryUpkeep': artilleryUpkeep,
    'artilleryAmmoCapacity': artilleryAmmoCapacity,
    'artilleryShotCost': artilleryShotCost,
    'initialMoney': initialMoney,
    'pineSpreadChance': pineSpreadChance,
    'palmSpreadChance': palmSpreadChance,
  };

  factory GameRules.fromJson(Map<String, dynamic> json) {
    int readInt(String key, {int? fallback}) {
      final value = json[key];
      if (value is num && value.isFinite && value == value.roundToDouble()) {
        if (value.abs() > 1000000) {
          throw FormatException('Mod rule "$key" is too large.');
        }
        return value.toInt();
      }
      if (fallback != null && value == null) return fallback;
      throw FormatException('Mod rule "$key" must be an integer.');
    }

    double readChance(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite) {
        throw FormatException('Mod rule "$key" must be a number.');
      }
      final result = value.toDouble();
      if (result < 0 || result > 1) {
        throw FormatException('Mod rule "$key" must be between 0 and 1.');
      }
      return result;
    }

    List<int> readList(String key, List<int> fallback, int minimumLength) {
      final raw = json[key] ?? fallback;
      if (raw is! List || raw.length < minimumLength || raw.length > 64) {
        throw FormatException(
          'Mod rule "$key" must contain at least $minimumLength integers.',
        );
      }
      final values = <int>[];
      for (final value in raw) {
        if (value is! num ||
            !value.isFinite ||
            value != value.roundToDouble()) {
          throw FormatException('Mod rule "$key" contains a non-integer.');
        }
        values.add(value.toInt());
        if (value.abs() > 1000000) {
          throw FormatException('Mod rule "$key" is too large.');
        }
      }
      return List<int>.unmodifiable(values);
    }

    final rules = GameRules(
      unitMoveLimit: readInt('unitMoveLimit'),
      unitPricePerLevel: readInt('unitPricePerLevel'),
      farmBasePrice: readInt('farmBasePrice'),
      farmPriceGrowth: readInt('farmPriceGrowth'),
      towerPrice: readInt('towerPrice'),
      strongTowerPrice: readInt('strongTowerPrice'),
      farmIncome: readInt('farmIncome'),
      treeCutReward: readInt('treeCutReward'),
      unitUpkeep: readList('unitUpkeep', const [0, 2, 6, 18, 36], 5),
      towerUpkeep: readInt('towerUpkeep'),
      strongTowerUpkeep: readInt('strongTowerUpkeep'),
      port1Price: readInt('port1Price', fallback: 45),
      port2Price: readInt('port2Price', fallback: 75),
      boat1Price: readInt('boat1Price', fallback: 40),
      boat2Price: readInt('boat2Price', fallback: 110),
      port1Upkeep: readInt('port1Upkeep', fallback: 2),
      port2Upkeep: readInt('port2Upkeep', fallback: 6),
      boat1Upkeep: readInt('boat1Upkeep', fallback: 3),
      boat2Upkeep: readInt('boat2Upkeep', fallback: 8),
      boatMoveLimit: readInt('boatMoveLimit', fallback: 2),
      portLaunchRadius: readInt('portLaunchRadius', fallback: 0),
      boat1Capacity: readInt('boat1Capacity', fallback: 4),
      boat2Capacity: readInt('boat2Capacity', fallback: 10),
      seaFortPrice: readInt('seaFortPrice', fallback: 80),
      seaFortUpkeep: readInt('seaFortUpkeep', fallback: 8),
      navalSupplyUpkeep: readInt('navalSupplyUpkeep', fallback: 1),
      artilleryCosts: readList('artilleryCosts', const [0, 50, 65, 90], 4),
      artilleryUpkeep: readList('artilleryUpkeep', const [0, 4, 8, 14], 4),
      artilleryAmmoCapacity: readList('artilleryAmmoCapacity', const [
        0,
        2,
        4,
        7,
      ], 4),
      artilleryShotCost: readInt('artilleryShotCost', fallback: 0),
      initialMoney: readInt('initialMoney'),
      pineSpreadChance: readChance('pineSpreadChance'),
      palmSpreadChance: readChance('palmSpreadChance'),
    );
    rules._validate();
    return rules;
  }

  void _validate() {
    final nonNegative = <String, int>{
      'farmBasePrice': farmBasePrice,
      'farmPriceGrowth': farmPriceGrowth,
      'towerPrice': towerPrice,
      'strongTowerPrice': strongTowerPrice,
      'farmIncome': farmIncome,
      'treeCutReward': treeCutReward,
      'towerUpkeep': towerUpkeep,
      'strongTowerUpkeep': strongTowerUpkeep,
      'port1Price': port1Price,
      'port2Price': port2Price,
      'boat1Price': boat1Price,
      'boat2Price': boat2Price,
      'port1Upkeep': port1Upkeep,
      'port2Upkeep': port2Upkeep,
      'boat1Upkeep': boat1Upkeep,
      'boat2Upkeep': boat2Upkeep,
      'portLaunchRadius': portLaunchRadius,
      'seaFortPrice': seaFortPrice,
      'seaFortUpkeep': seaFortUpkeep,
      'navalSupplyUpkeep': navalSupplyUpkeep,
      'artilleryShotCost': artilleryShotCost,
      'initialMoney': initialMoney,
    };
    for (final entry in nonNegative.entries) {
      if (entry.value < 0) {
        throw FormatException('Mod rule "${entry.key}" cannot be negative.');
      }
    }
    if (unitMoveLimit <= 0 || unitPricePerLevel <= 0 || boatMoveLimit <= 0) {
      throw const FormatException(
        'Move limits and unitPricePerLevel must be positive.',
      );
    }
    if (boat1Capacity <= 0 || boat2Capacity < boat1Capacity) {
      throw const FormatException(
        'Boat capacities must be positive and level 2 cannot be smaller.',
      );
    }
    for (final entry in <String, List<int>>{
      'unitUpkeep': unitUpkeep,
      'artilleryCosts': artilleryCosts,
      'artilleryUpkeep': artilleryUpkeep,
      'artilleryAmmoCapacity': artilleryAmmoCapacity,
    }.entries) {
      if (entry.value.any((value) => value < 0)) {
        throw FormatException('Mod rule "${entry.key}" cannot be negative.');
      }
    }
    if (artilleryAmmoCapacity[1] <= 0 ||
        artilleryAmmoCapacity[2] < artilleryAmmoCapacity[1] ||
        artilleryAmmoCapacity[3] < artilleryAmmoCapacity[2]) {
      throw const FormatException(
        'Artillery ammo capacities must be positive and non-decreasing.',
      );
    }
  }
}

class GameMod {
  const GameMod({
    required this.id,
    required this.name,
    required this.title,
    required this.version,
    required this.rules,
    required this.palette,
    required this.neutralColor,
    required this.waterColor,
    this.sprites = const {},
    this.author = '',
    this.description = '',
    this.components = const [],
  });

  final String id;
  final String name;
  final String title;
  final int version;
  final GameRules rules;
  final List<Color> palette;
  final Color neutralColor;
  final Color waterColor;
  final Map<String, String> sprites;
  final String author;
  final String description;
  final List<ModReference> components;
  ModReference get reference =>
      ModReference(id: id, name: name, version: version, hash: fingerprint);
  List<ModReference> get requirements => components.isNotEmpty
      ? components
      : id == 'classic_steppe'
      ? const []
      : [reference];

  static final _fingerprints = Expando<String>();
  String get fingerprint =>
      _fingerprints[this] ??
      sha256.convert(utf8.encode(jsonEncode(_canonical(toJson())))).toString();

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'title': title,
    'version': version,
    'rules': rules.toJson(),
    'palette': palette.map(_colorToHex).toList(growable: false),
    'neutralColor': _colorToHex(neutralColor),
    'waterColor': _colorToHex(waterColor),
    if (sprites.isNotEmpty) 'sprites': sprites,
    if (author.isNotEmpty) 'author': author,
    if (description.isNotEmpty) 'description': description,
    if (components.isNotEmpty)
      'components': components.map((m) => m.toJson()).toList(),
  };

  static Future<GameMod> loadDefault() =>
      loadAsset('assets/mods/default_mod.json');

  static Future<GameMod> loadAsset(String path) async {
    final json =
        jsonDecode(await rootBundle.loadString(path)) as Map<String, dynamic>;
    return GameMod.fromJson(json);
  }

  factory GameMod.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final title = json['title'];
    final version = json['version'];
    final rules = json['rules'];
    final rawPalette = json['palette'];
    final neutralColor = json['neutralColor'];
    final waterColor = json['waterColor'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        version is! int ||
        version <= 0 ||
        rules is! Map ||
        rawPalette is! List ||
        rawPalette.length < 2 ||
        neutralColor is! String ||
        waterColor is! String) {
      throw const FormatException('Invalid game mod metadata.');
    }
    final palette = rawPalette
        .map((value) {
          if (value is! String) {
            throw const FormatException('Palette entries must be hex colours.');
          }
          return _parseColor(value);
        })
        .toList(growable: false);
    if (palette.length > 15 ||
        name.length > 80 ||
        title.length > 80 ||
        id.length > 64) {
      throw const FormatException('Мод атауы немесе палитрасы тым үлкен.');
    }
    final sprites = <String, String>{};
    final rawSprites = json['sprites'] ?? const <String, String>{};
    if (rawSprites is! Map || rawSprites.length > spriteNames.length) {
      throw const FormatException('Мод суреттері жарамсыз.');
    }
    var spriteBytes = 0;
    for (final entry in rawSprites.entries) {
      if (!spriteNames.contains(entry.key) ||
          entry.value is! String ||
          (entry.value as String).length > 700000) {
        throw const FormatException('Сурет атауы не көлемі жарамсыз.');
      }
      final bytes = base64Decode(entry.value as String);
      spriteBytes += bytes.length;
      if (spriteBytes > 4 * 1024 * 1024 ||
          bytes.length < 24 ||
          bytes[0] != 137 ||
          utf8.decode(bytes.sublist(1, 4), allowMalformed: true) != 'PNG') {
        throw const FormatException(
          'Мод суреттері PNG, жалпы 4 МБ-қа дейін болуы керек.',
        );
      }
      final header = ByteData.sublistView(bytes);
      final width = header.getUint32(16);
      final height = header.getUint32(20);
      if (width < 1 || height < 1 || width > 512 || height > 512) {
        throw const FormatException('PNG өлшемі 1–512 пиксель болуы керек.');
      }
      sprites[entry.key as String] = entry.value as String;
    }
    String text(String key, int limit) {
      final value = json[key] ?? '';
      if (value is! String || value.length > limit) {
        throw FormatException('Модтың $key өрісі жарамсыз.');
      }
      return value;
    }

    final mod = GameMod(
      id: id,
      name: name,
      title: title,
      version: version,
      rules: GameRules.fromJson(rules.cast<String, dynamic>()),
      palette: List.unmodifiable(palette),
      neutralColor: _parseColor(neutralColor),
      waterColor: _parseColor(waterColor),
      sprites: Map.unmodifiable(sprites),
      author: text('author', 80),
      description: text('description', 1000),
      components: ModReference.readList(json['components']),
    );
    _fingerprints[mod] = mod.fingerprint;
    return mod;
  }

  static Color _parseColor(String value) {
    final hex = value.replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
      throw FormatException('Invalid colour value: $value');
    }
    return Color(int.parse('ff$hex', radix: 16));
  }

  static String _colorToHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  static const spriteNames = <String>{
    'selection',
    'selection_pixel',
    'man0',
    'man1',
    'man2',
    'man3',
    'castle',
    'house',
    'farm1',
    'tower',
    'strong_tower',
    'pine',
    'palm',
    'grave',
    'port1',
    'port2',
    'boat1',
    'boat2',
    'sea_mint',
    'sea_fort',
    'artillery',
    'artillery_base',
    'artillery_turret',
    'man0_team',
    'man1_team',
    'man2_team',
    'man3_team',
    'castle_team',
    'farm1_team',
    'tower_team',
    'strong_tower_team',
    'port1_team',
    'port2_team',
    'boat1_team',
    'boat2_team',
    'naval_supply_link',
    'exclamation_mark',
    'diplomacy_black_mark',
  };
}
