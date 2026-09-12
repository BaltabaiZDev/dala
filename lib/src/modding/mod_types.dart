/// Declarative gameplay types. Packages provide data, never executable code.
/// Limits bound flood fills, sprite memory and economic arithmetic on phones.
enum ModMovement { land, air }

class ModBuilding {
  const ModBuilding({
    required this.id,
    required this.name,
    required this.price,
    this.upkeep = 0,
    this.income = 0,
    this.defense = 0,
    this.vision = 0,
    this.icon = 'building',
  });
  final String id;
  final String name;
  final int price;
  final int upkeep;
  final int income;
  final int defense;
  final int vision;
  final String icon;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'price': price,
    'upkeep': upkeep,
    'income': income,
    'defense': defense,
    'vision': vision,
    'icon': icon,
  };

  factory ModBuilding.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'id',
      'name',
      'price',
      'upkeep',
      'income',
      'defense',
      'vision',
      'icon',
    });
    return ModBuilding(
      id: _id(json['id']),
      name: _name(json['name']),
      price: _integer(json, 'price', 0, 1000000),
      upkeep: _integer(json, 'upkeep', 0, 1000000, fallback: 0),
      income: _integer(json, 'income', 0, 1000000, fallback: 0),
      defense: _integer(json, 'defense', 0, 3, fallback: 0),
      vision: _integer(json, 'vision', 0, 12, fallback: 0),
      icon: _icon(json['icon'] ?? 'building', {
        'building',
        'radar',
        'airfield',
        'factory',
      }),
    );
  }
}

class ModUnitType {
  const ModUnitType({
    required this.id,
    required this.name,
    required this.price,
    this.upkeep = 2,
    this.strength = 1,
    this.moveRange = 4,
    this.vision = 1,
    this.movement = ModMovement.land,
    this.attackRange = 0,
    this.requiresBuilding,
    this.icon = 'infantry',
  });
  final String id;
  final String name;
  final int price;
  final int upkeep;
  final int strength;
  final int moveRange;
  final int vision;
  final ModMovement movement;

  /// Air units may strike visible hostile land/air targets without capturing.
  /// Land units use DALA's ordinary occupation combat instead.
  final int attackRange;
  final String? requiresBuilding;
  final String icon;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'price': price,
    'upkeep': upkeep,
    'strength': strength,
    'moveRange': moveRange,
    'vision': vision,
    'movement': movement.name,
    'attackRange': attackRange,
    if (requiresBuilding != null) 'requiresBuilding': requiresBuilding,
    'icon': icon,
  };

  factory ModUnitType.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'id',
      'name',
      'price',
      'upkeep',
      'strength',
      'moveRange',
      'vision',
      'movement',
      'attackRange',
      'requiresBuilding',
      'icon',
    });
    final movement = ModMovement.values
        .where((value) => value.name == (json['movement'] ?? 'land'))
        .firstOrNull;
    if (movement == null) throw const FormatException('Unknown mod movement.');
    final range = _integer(json, 'attackRange', 0, 6, fallback: 0);
    if (movement == ModMovement.land && range != 0) {
      throw const FormatException(
        'Land units use occupation combat; attackRange must be 0.',
      );
    }
    return ModUnitType(
      id: _id(json['id']),
      name: _name(json['name']),
      price: _integer(json, 'price', 0, 1000000),
      upkeep: _integer(json, 'upkeep', 0, 1000000, fallback: 2),
      strength: _integer(json, 'strength', 1, 4, fallback: 1),
      moveRange: _integer(json, 'moveRange', 1, 12, fallback: 4),
      vision: _integer(json, 'vision', 0, 12, fallback: 1),
      movement: movement,
      attackRange: range,
      requiresBuilding: json['requiresBuilding'] == null
          ? null
          : _id(json['requiresBuilding']),
      icon: _icon(
        json['icon'] ?? (movement == ModMovement.air ? 'aircraft' : 'infantry'),
        {'infantry', 'scout', 'aircraft'},
      ),
    );
  }
}

Map<String, T> readModTypes<T>(
  Object? raw,
  T Function(Map<String, dynamic>) parse,
  String Function(T) idOf,
) {
  if (raw == null) return const {};
  if (raw is! List || raw.length > 32) {
    throw const FormatException('At most 32 mod types per category.');
  }
  final result = <String, T>{};
  for (final item in raw) {
    if (item is! Map) throw const FormatException('Invalid mod type.');
    final value = parse(Map<String, dynamic>.from(item));
    final id = idOf(value);
    if (result.containsKey(id)) {
      throw FormatException('Duplicate mod type: $id');
    }
    result[id] = value;
  }
  return Map.unmodifiable(result);
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[a-z0-9][a-z0-9_-]{0,63}\.[a-z0-9][a-z0-9_-]{0,31}$',
      ).hasMatch(value)) {
    throw const FormatException(
      'Use a qualified type id such as my_mod.radar.',
    );
  }
  return value;
}

String _name(Object? value) {
  if (value is! String || value.trim().isEmpty || value.length > 60) {
    throw const FormatException('Mod type name must have 1–60 characters.');
  }
  return value;
}

String _icon(Object? value, Set<String> allowed) {
  if (value is! String || !allowed.contains(value)) {
    throw const FormatException('Unknown mod icon.');
  }
  return value;
}

int _integer(
  Map<String, dynamic> json,
  String key,
  int min,
  int max, {
  int? fallback,
}) {
  final value = json[key] ?? fallback;
  if (value is! int || value < min || value > max) {
    throw FormatException('Mod $key must be $min–$max.');
  }
  return value;
}

void _keys(Map<String, dynamic> json, Set<String> allowed) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('Unknown mod type field: $key');
    }
  }
}
