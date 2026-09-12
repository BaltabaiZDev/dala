import 'dart:convert';

import '../game/models.dart';

/// Builds compact authoritative LAN updates after the initial full snapshot.
///
/// A normal move changes only a handful of hexes/water cells plus the province
/// list. Sending those records instead of reparsing a 5k-cell [GameState] on
/// every tap keeps giant LAN maps responsive while the host remains the only
/// simulation authority.
class LanStatePatchBuilder {
  final List<String> _hexFingerprints = <String>[];
  final List<String> _waterFingerprints = <String>[];
  final Map<String, String> _sectionFingerprints = <String, String>{};
  final Map<String, Object?> _scalarValues = <String, Object?>{};

  static const List<String> _sectionKeys = <String>[
    'provinces',
    'campaigns',
    'peaceConferences',
    'diplomacyRelations',
    'diplomacySocial',
    'diplomacyAllianceTurns',
    'diplomacyWarCooldowns',
    'diplomacyBlackMarks',
    'diplomacyBlackMarkCooldowns',
    'diplomacyDebts',
    'diplomacyTraitorTurns',
    'diplomacySubsidies',
    'diplomacyProposals',
    'diplomacyMessages',
    'diplomacyLog',
  ];

  static const List<String> _scalarKeys = <String>[
    'turn',
    'round',
    'rngState',
    'nextProvinceId',
    'nextNavalEntityId',
    'nextWarCampaignId',
    'nextPeaceConferenceId',
    'winner',
  ];

  void prime(GameState state) {
    final sections = _sectionJson(state);
    final scalars = _scalarJson(state);
    _hexFingerprints
      ..clear()
      ..addAll(state.hexes.map((tile) => jsonEncode(tile.toJson())));
    _waterFingerprints
      ..clear()
      ..addAll(state.waterCells.map((cell) => jsonEncode(cell.toJson())));
    _sectionFingerprints
      ..clear()
      ..addEntries(
        _sectionKeys.map((key) => MapEntry(key, jsonEncode(sections[key]))),
      );
    _scalarValues
      ..clear()
      ..addEntries(_scalarKeys.map((key) => MapEntry(key, scalars[key])));
  }

  Map<String, dynamic>? build(GameState state) {
    if (_hexFingerprints.length != state.hexes.length ||
        _waterFingerprints.length != state.waterCells.length) {
      prime(state);
      return <String, dynamic>{'fullStateRequired': true};
    }

    final changedHexes = <Map<String, dynamic>>[];
    for (var index = 0; index < state.hexes.length; index++) {
      final raw = state.hexes[index].toJson();
      final fingerprint = jsonEncode(raw);
      if (fingerprint == _hexFingerprints[index]) continue;
      _hexFingerprints[index] = fingerprint;
      changedHexes.add(raw);
    }

    final changedWater = <Map<String, dynamic>>[];
    for (var index = 0; index < state.waterCells.length; index++) {
      final raw = state.waterCells[index].toJson();
      final fingerprint = jsonEncode(raw);
      if (fingerprint == _waterFingerprints[index]) continue;
      _waterFingerprints[index] = fingerprint;
      changedWater.add(raw);
    }

    final currentSections = _sectionJson(state);
    final sections = <String, dynamic>{};
    for (final key in _sectionKeys) {
      final fingerprint = jsonEncode(currentSections[key]);
      if (fingerprint == _sectionFingerprints[key]) continue;
      _sectionFingerprints[key] = fingerprint;
      sections[key] = currentSections[key];
    }

    final currentScalars = _scalarJson(state);
    final scalars = <String, dynamic>{};
    for (final key in _scalarKeys) {
      final value = currentScalars[key];
      if (_scalarValues.containsKey(key) && _scalarValues[key] == value) {
        continue;
      }
      _scalarValues[key] = value;
      scalars[key] = value;
    }

    if (changedHexes.isEmpty &&
        changedWater.isEmpty &&
        sections.isEmpty &&
        scalars.isEmpty) {
      return null;
    }
    return <String, dynamic>{
      if (changedHexes.isNotEmpty) 'hexes': changedHexes,
      if (changedWater.isNotEmpty) 'waterCells': changedWater,
      if (sections.isNotEmpty) 'sections': sections,
      if (scalars.isNotEmpty) 'scalars': scalars,
    };
  }

  Map<String, dynamic> _sectionJson(GameState state) => <String, dynamic>{
    'provinces': state.provinces.map((item) => item.toJson()).toList(),
    'campaigns': state.campaigns.map((item) => item.toJson()).toList(),
    'peaceConferences': state.peaceConferences
        .map((item) => item.toJson())
        .toList(),
    'diplomacyRelations': state.diplomacyRelations
        .map((row) => row.map((status) => status.name).toList())
        .toList(),
    'diplomacyAllianceTurns': state.diplomacyAllianceTurns,
    'diplomacySocial': state.diplomacySocial.toJson(),
    'diplomacyWarCooldowns': state.diplomacyWarCooldowns,
    'diplomacyBlackMarks': state.diplomacyBlackMarks,
    'diplomacyBlackMarkCooldowns': state.diplomacyBlackMarkCooldowns,
    'diplomacyDebts': state.diplomacyDebts,
    'diplomacyTraitorTurns': state.diplomacyTraitorTurns,
    'diplomacySubsidies': state.diplomacySubsidies
        .map((item) => item.toJson())
        .toList(),
    'diplomacyProposals': state.diplomacyProposals
        .map((item) => item.toJson())
        .toList(),
    'diplomacyMessages': state.diplomacyMessages
        .map((item) => item.toJson())
        .toList(),
    'diplomacyLog': state.diplomacyLog,
  };

  Map<String, dynamic> _scalarJson(GameState state) => <String, dynamic>{
    'turn': state.turn,
    'round': state.round,
    'rngState': state.rngState,
    'nextProvinceId': state.nextProvinceId,
    'nextNavalEntityId': state.nextNavalEntityId,
    'nextWarCampaignId': state.nextWarCampaignId,
    'nextPeaceConferenceId': state.nextPeaceConferenceId,
    'winner': state.winner,
  };
}

/// Applies a compact patch to the client's retained JSON snapshot. The bound
/// controller separately parses only the changed model records.
void applyLanPatchToJson(
  Map<String, dynamic> stateJson,
  Map<String, dynamic> patch,
) {
  final hexes = stateJson['hexes'];
  final changedHexes = patch['hexes'];
  if (hexes is List && changedHexes is List) {
    for (final raw in changedHexes.whereType<Map>()) {
      final item = raw.cast<String, dynamic>();
      final index = (item['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= hexes.length) {
        throw const FormatException('LAN жер патчы жарамсыз.');
      }
      hexes[index] = item;
    }
  }

  final water = stateJson['waterCells'];
  final changedWater = patch['waterCells'];
  if (water is List && changedWater is List) {
    for (final raw in changedWater.whereType<Map>()) {
      final item = raw.cast<String, dynamic>();
      final index = (item['index'] as num?)?.toInt() ?? -1;
      if (index < 0 || index >= water.length) {
        throw const FormatException('LAN су патчы жарамсыз.');
      }
      water[index] = item;
    }
  }

  final sections = patch['sections'];
  if (sections is Map) {
    for (final entry in sections.entries) {
      stateJson[entry.key.toString()] = entry.value;
    }
  }
  final scalars = patch['scalars'];
  if (scalars is Map) {
    for (final entry in scalars.entries) {
      stateJson[entry.key.toString()] = entry.value;
    }
  }
}
