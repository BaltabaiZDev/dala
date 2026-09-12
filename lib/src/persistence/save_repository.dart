import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/models.dart';

class SaveRepository {
  static const _saveKey = 'antiyoy.autosave.v1';

  Future<bool> hasSave() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_saveKey);
  }

  Future<void> save(GameState state) async {
    final raw = await compute(_encodeState, state.toJson());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_saveKey, raw);
  }

  Future<GameState?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_saveKey);
    if (raw == null) return null;
    try {
      return GameState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return null;
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_saveKey);
  }

  Future<String?> exportRaw() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_saveKey);
  }

  Future<bool> importRaw(String raw) async {
    try {
      GameState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_saveKey, raw);
    return true;
  }
}

String _encodeState(Map<String, dynamic> value) => jsonEncode(value);
