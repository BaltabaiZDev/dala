import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'game_mod.dart';

class ModConflict {
  const ModConflict(this.field, this.previous, this.winner);
  final String field;
  final String previous;
  final String winner;
}

class ModStack {
  const ModStack(this.mod, this.conflicts);
  final GameMod mod;
  final List<ModConflict> conflicts;

  /// Full v1 packages describe a default-based change: untouched base fields
  /// do not erase another package's changes. Later changed values win.
  static ModStack compose(GameMod base, List<GameMod> mods) {
    if (mods.length > 32 ||
        mods.map((m) => m.id).toSet().length != mods.length ||
        mods.any((m) => m.id == base.id || m.components.isNotEmpty)) {
      throw const FormatException('Модтар жиынтығы жарамсыз.');
    }
    if (mods.isEmpty) return ModStack(base, const []);
    if (mods.length == 1) return ModStack(mods.single, const []);
    final baseline = base.toJson();
    final result = Map<String, dynamic>.from(baseline);
    final rules = Map<String, dynamic>.from(base.rules.toJson());
    final sprites = Map<String, String>.from(base.sprites);
    final buildings = <String, ModBuilding>{...base.buildings};
    final units = <String, ModUnitType>{...base.units};
    final owners = <String, String>{};
    final values = <String, String>{};
    final conflicts = <ModConflict>[];
    void changed(String key, Object? value, String name) {
      final encoded = jsonEncode(value);
      if (values.containsKey(key) && values[key] != encoded) {
        conflicts.add(ModConflict(key, owners[key]!, name));
      }
      values[key] = encoded;
      owners[key] = name;
    }

    for (final mod in mods) {
      buildings.addAll(mod.buildings);
      units.addAll(mod.units);
      for (final entry in mod.rules.toJson().entries) {
        if (jsonEncode(entry.value) ==
            jsonEncode(base.rules.toJson()[entry.key])) {
          continue;
        }
        changed('rules.${entry.key}', entry.value, mod.name);
        rules[entry.key] = entry.value;
      }
      final json = mod.toJson();
      for (final key in ['palette', 'neutralColor', 'waterColor']) {
        if (jsonEncode(json[key]) == jsonEncode(baseline[key])) continue;
        changed(key, json[key], mod.name);
        result[key] = json[key];
      }
      for (final entry in mod.sprites.entries) {
        changed('sprites.${entry.key}', entry.value, mod.name);
        sprites[entry.key] = entry.value;
      }
    }
    final key = sha256
        .convert(utf8.encode(mods.map((m) => m.fingerprint).join(':')))
        .toString();
    final name = mods.map((m) => m.name).join(' + ');
    final nestedIds = buildings.values
        .expand((b) => b.production)
        .map((u) => u.id)
        .toSet();
    result.addAll({
      'id': 'stack_${key.substring(0, 24)}',
      'name': name.length <= 80 ? name : '${name.substring(0, 77)}...',
      'title': 'DALA',
      'version': 1,
      'rules': rules,
      'sprites': sprites,
      if (buildings.isNotEmpty)
        'buildings': buildings.values.map((v) => v.toJson()).toList(),
      if (units.isNotEmpty)
        'units': units.values
            .where((u) => !nestedIds.contains(u.id))
            .map((v) => v.toJson())
            .toList(),
      'components': mods.map((m) => m.reference.toJson()).toList(),
    });
    return ModStack(GameMod.fromJson(result), List.unmodifiable(conflicts));
  }

  static GameMod resolve(
    GameMod base,
    Iterable<GameMod> installed,
    List<ModReference> required,
  ) {
    final selected = <GameMod>[];
    for (final ref in required) {
      final mod = installed
          .where((m) => m.id == ref.id && m.fingerprint == ref.hash)
          .firstOrNull;
      if (mod == null) {
        throw FormatException(
          'Мод орнатылмаған немесе нұсқасы басқа: ${ref.name} v${ref.version}',
        );
      }
      selected.add(mod);
    }
    return compose(base, selected).mod;
  }
}
