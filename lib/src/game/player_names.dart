/// Classic Antiyoy's NameGenerator mask/group method and Russian city-name
/// tables (assets/languages.xml, yiotro/Antiyoy f22acaa). Names belong to this
/// mod's persistent factions, so use a separate map-seeded stream, not the
/// changing capital coordinate or the simulation's random stream.
List<String> generatePlayerNames(
  int seed,
  int count, {
  Iterable<String> reserved = const [],
}) {
  final random = _NameRandom(seed);
  final used = reserved.map((name) => name.trim().toLowerCase()).toSet();
  final names = <String>[];
  for (var player = 0; player < count; player++) {
    var name = '';
    for (var attempt = 0; attempt < 256; attempt++) {
      final mask = _masks[random.nextInt(_masks.length)];
      final word = StringBuffer();
      for (final key in mask.split('')) {
        final group = _groups[key]!;
        word.write(group[random.nextInt(group.length)]);
      }
      final raw = word.toString();
      name = '${raw[0].toUpperCase()}${raw.substring(1)}';
      if (used.add(name.toLowerCase())) break;
      name = '';
    }
    // Defensive bounded fallback; no unbounded random retry in large lobbies.
    if (name.isEmpty) {
      var suffix = player + 1;
      do {
        name = 'Дала ${suffix++}';
      } while (!used.add(name.toLowerCase()));
    }
    names.add(name);
  }
  return names;
}

const _masks = [
  'kama',
  'kakao',
  'kamao',
  'kakkao',
  'kakka',
  'amao',
  'amaka',
  'kamak',
  'kakaka',
  'kaakao',
  'akaka',
  'amakao',
];
const _groups = {
  'k': ['р', 'т', 'п', 'с', 'д', 'к', 'б', 'н', 'м'],
  'm': ['рб', 'кр', 'тр', 'бр', 'бн', 'ко', 'рт'],
  'a': ['о', 'а', 'аи', 'е', 'ой', 'о', 'е'],
  'o': ['во', 'ва', 'мск', 'ск', 'нск', 'ов', 'рг', 'ро'],
};

// Java-compatible RNG, isolated from map/AI/economy RNG. BigInt retains the
// same 48-bit arithmetic on Flutter web as on native Dart.
class _NameRandom {
  _NameRandom(int seed) : _state = (BigInt.from(seed) ^ _multiplier) & _mask;
  static final _multiplier = BigInt.from(0x5deece66d);
  static final _mask = (BigInt.one << 48) - BigInt.one;
  BigInt _state;
  int _next() {
    _state = (_state * _multiplier + BigInt.from(11)) & _mask;
    return (_state >> 17).toInt();
  }

  int nextInt(int bound) {
    if ((bound & -bound) == bound) {
      return ((BigInt.from(bound) * BigInt.from(_next())) >> 31).toInt();
    }
    while (true) {
      final bits = _next();
      final value = bits % bound;
      if (bits - value + bound - 1 < 0x80000000) return value;
    }
  }
}
