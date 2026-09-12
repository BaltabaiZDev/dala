import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../game/models.dart';

class AppSettings {
  const AppSettings({
    this.mapSize = MapSize.medium,
    this.playerCount = 4,
    this.humanCount = 1,
    this.difficulty = AiDifficulty.normal,
    this.treePercent = 10,
    this.startingProvinceCount = 0,
    this.playerColorChoice = -1,
    this.sensitivity = 6,
    this.waterTexture = true,
    this.leftHanded = false,
    this.confirmEndTurn = true,
    this.fullscreen = false,
    this.autoEndTurn = false,
    this.sound = false,
    this.music = false,
    this.autosave = true,
    this.cityNames = true,
    this.useCityNameList = true,
    this.slayRules = false,
    this.fogOfWar = false,
    this.diplomacy = false,
  });

  final MapSize mapSize;
  final int playerCount;
  final int humanCount;
  final AiDifficulty difficulty;
  final int treePercent;
  final int startingProvinceCount;
  final int playerColorChoice;
  final int sensitivity;
  final bool waterTexture;
  final bool leftHanded;
  final bool confirmEndTurn;
  final bool fullscreen;
  final bool autoEndTurn;
  final bool sound;
  final bool music;
  final bool autosave;
  final bool cityNames;
  final bool useCityNameList;
  final bool slayRules;
  final bool fogOfWar;
  final bool diplomacy;

  AppSettings copyWith({
    MapSize? mapSize,
    int? playerCount,
    int? humanCount,
    AiDifficulty? difficulty,
    int? treePercent,
    int? startingProvinceCount,
    int? playerColorChoice,
    int? sensitivity,
    bool? waterTexture,
    bool? leftHanded,
    bool? confirmEndTurn,
    bool? fullscreen,
    bool? autoEndTurn,
    bool? sound,
    bool? music,
    bool? autosave,
    bool? cityNames,
    bool? useCityNameList,
    bool? slayRules,
    bool? fogOfWar,
    bool? diplomacy,
  }) => AppSettings(
    mapSize: mapSize ?? this.mapSize,
    playerCount: playerCount ?? this.playerCount,
    humanCount: humanCount ?? this.humanCount,
    difficulty: difficulty ?? this.difficulty,
    treePercent: treePercent ?? this.treePercent,
    startingProvinceCount: startingProvinceCount ?? this.startingProvinceCount,
    playerColorChoice: playerColorChoice ?? this.playerColorChoice,
    sensitivity: sensitivity ?? this.sensitivity,
    waterTexture: waterTexture ?? this.waterTexture,
    leftHanded: leftHanded ?? this.leftHanded,
    confirmEndTurn: confirmEndTurn ?? this.confirmEndTurn,
    fullscreen: fullscreen ?? this.fullscreen,
    autoEndTurn: autoEndTurn ?? this.autoEndTurn,
    sound: sound ?? this.sound,
    music: music ?? this.music,
    autosave: autosave ?? this.autosave,
    cityNames: cityNames ?? this.cityNames,
    useCityNameList: useCityNameList ?? this.useCityNameList,
    slayRules: slayRules ?? this.slayRules,
    fogOfWar: fogOfWar ?? this.fogOfWar,
    diplomacy: diplomacy ?? this.diplomacy,
  );

  Map<String, Object> toJson() => {
    'mapSize': mapSize.name,
    'playerCount': playerCount,
    'humanCount': humanCount,
    'difficulty': difficulty.name,
    'treePercent': treePercent,
    'startingProvinceCount': startingProvinceCount,
    'playerColorChoice': playerColorChoice,
    'sensitivity': sensitivity,
    'waterTexture': waterTexture,
    'leftHanded': leftHanded,
    'confirmEndTurn': confirmEndTurn,
    'fullscreen': fullscreen,
    'autoEndTurn': autoEndTurn,
    'sound': sound,
    'music': music,
    'autosave': autosave,
    'cityNames': cityNames,
    'useCityNameList': useCityNameList,
    'slayRules': slayRules,
    'fogOfWar': fogOfWar,
    'diplomacy': diplomacy,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    T read<T>(String key, T fallback) =>
        json[key] is T ? json[key] as T : fallback;
    final difficultyName = read('difficulty', AiDifficulty.normal.name);
    final sizeName = read('mapSize', MapSize.medium.name);
    final mapSize =
        MapSize.values.where((value) => value.name == sizeName).firstOrNull ??
        MapSize.medium;
    final playerCount = read('playerCount', 4).clamp(2, mapSize.maxPlayers);
    return AppSettings(
      mapSize: mapSize,
      playerCount: playerCount,
      humanCount: read('humanCount', 1).clamp(0, playerCount),
      difficulty:
          AiDifficulty.values
              .where((value) => value.name == difficultyName)
              .firstOrNull ??
          AiDifficulty.normal,
      treePercent: read('treePercent', 10).clamp(0, 100),
      startingProvinceCount: read('startingProvinceCount', 0).clamp(0, 3),
      playerColorChoice: read('playerColorChoice', -1).clamp(-1, 14),
      sensitivity: read('sensitivity', 6).clamp(1, 10),
      waterTexture: read('waterTexture', true),
      leftHanded: read('leftHanded', false),
      confirmEndTurn: read('confirmEndTurn', true),
      fullscreen: read('fullscreen', false),
      autoEndTurn: read('autoEndTurn', false),
      sound: read('sound', false),
      music: read('music', false),
      autosave: read('autosave', true),
      cityNames: read('cityNames', true),
      useCityNameList: read('useCityNameList', true),
      slayRules: read('slayRules', false),
      fogOfWar: read('fogOfWar', false),
      diplomacy: read('diplomacy', false),
    );
  }

  /// Strict boundary validation for clipboard/progress imports. Normal local
  /// loading remains tolerant so older preference payloads can use defaults.
  static bool isValidJson(Map<String, dynamic> json) {
    bool validInt(String key, int min, int max) {
      final value = json[key];
      return value == null || (value is int && value >= min && value <= max);
    }

    bool validBool(String key) => json[key] == null || json[key] is bool;
    final playerCount = json['playerCount'] is int
        ? json['playerCount'] as int
        : 4;
    final size = json['mapSize'];
    final mapSize = size == null
        ? MapSize.medium
        : size is String
        ? MapSize.values.where((value) => value.name == size).firstOrNull
        : null;
    final difficulty = json['difficulty'];
    if (mapSize == null ||
        (difficulty != null &&
            (difficulty is! String ||
                !AiDifficulty.values.any(
                  (value) => value.name == difficulty,
                ))) ||
        !validInt('playerCount', 2, mapSize.maxPlayers) ||
        !validInt('humanCount', 0, playerCount) ||
        !validInt('treePercent', 0, 100) ||
        !validInt('startingProvinceCount', 0, 3) ||
        !validInt('playerColorChoice', -1, 14) ||
        !validInt('sensitivity', 1, 10)) {
      return false;
    }
    return <String>[
      'waterTexture',
      'leftHanded',
      'confirmEndTurn',
      'fullscreen',
      'autoEndTurn',
      'sound',
      'music',
      'autosave',
      'cityNames',
      'useCityNameList',
      'slayRules',
      'fogOfWar',
      'diplomacy',
    ].every(validBool);
  }
}

class SettingsRepository {
  const SettingsRepository();

  static const _key = 'antiyoy.settings.v2';
  static const _unlockedLevelsKey = 'antiyoy.levels.unlocked.v1';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(settings.toJson()));
  }

  Future<int> unlockedLevels() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_unlockedLevelsKey) ?? 9).clamp(1, 50);
  }

  Future<void> setUnlockedLevels(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_unlockedLevelsKey, value.clamp(1, 50));
  }

  Future<String> exportRaw() async {
    final settings = await load();
    final unlocked = await unlockedLevels();
    return jsonEncode({
      'version': 1,
      'settings': settings.toJson(),
      'unlockedLevels': unlocked,
    });
  }

  Future<bool> importRaw(String raw) async {
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['version'] != 1 || data['settings'] is! Map) return false;
      final settingsJson = (data['settings'] as Map).cast<String, dynamic>();
      final unlocked = data['unlockedLevels'];
      if (!AppSettings.isValidJson(settingsJson) ||
          unlocked is! int ||
          unlocked < 1 ||
          unlocked > 50) {
        return false;
      }
      final settings = AppSettings.fromJson(settingsJson);
      await save(settings);
      await setUnlockedLevels(unlocked);
      return true;
    } on Object {
      return false;
    }
  }
}
