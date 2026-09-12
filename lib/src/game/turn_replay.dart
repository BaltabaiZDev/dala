import 'dart:collection';
import 'dart:convert';

import '../lan/lan_state_patch.dart';
import 'models.dart';

/// One frame per completed player turn. Only changed records are retained;
/// opening a replay never decodes hundreds of full maps simultaneously.
class TurnReplayFrames extends ListBase<Map<String, dynamic>> {
  TurnReplayFrames(GameState initial) {
    _builder.prime(initial);
    _records.add(jsonEncode(initial.toJson()));
  }

  static const checkpointInterval = 32;
  final _builder = LanStatePatchBuilder();
  final _records = <String>[];

  void captureTurn(GameState state) {
    if (length % checkpointInterval == 0) {
      _builder.prime(state);
      _records.add(jsonEncode(state.toJson()));
    } else {
      final patch = _builder.build(state);
      if (patch?['fullStateRequired'] == true) {
        throw StateError('A replay cannot change its map dimensions');
      }
      _records.add(jsonEncode(patch ?? <String, dynamic>{}));
    }
  }

  int get encodedBytes =>
      _records.fold(0, (sum, value) => sum + value.length * 2);

  @override
  int get length => _records.length;
  @override
  set length(int value) => throw UnsupportedError('Replay is append-only');
  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      throw UnsupportedError('Replay is read-only');

  @override
  Map<String, dynamic> operator [](int index) {
    RangeError.checkValidIndex(index, _records);
    final start = index ~/ checkpointInterval * checkpointInterval;
    final snapshot = (jsonDecode(_records[start]) as Map)
        .cast<String, dynamic>();
    for (var i = start + 1; i <= index; i++) {
      applyLanPatchToJson(
        snapshot,
        (jsonDecode(_records[i]) as Map).cast<String, dynamic>(),
      );
    }
    return snapshot;
  }
}
