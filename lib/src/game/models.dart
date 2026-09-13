import 'dart:math' as math;

import 'player_names.dart';

enum MapSize { small, medium, large, huge, giant }

extension MapSizeRules on MapSize {
  int get maxPlayers => switch (this) {
    MapSize.small => 5,
    MapSize.medium => 9,
    MapSize.large || MapSize.huge => 10,
    MapSize.giant => 15,
  };
}

/// Six distinct AI tiers, matching the classic campaign difficulty ladder.
/// Existing save names (`easy`, `normal`, `hard`) remain valid.
enum AiDifficulty { veryEasy, easy, normal, hard, veryHard, master }

extension AiDifficultyEconomy on AiDifficulty {
  int get incomePercent => switch (this) {
    AiDifficulty.veryHard => 150,
    AiDifficulty.master => 200,
    _ => 100,
  };
}

/// `alliance` is the existing timed friendship relation retained for save
/// compatibility. `coalition` is retired and migrated to peace on load.
enum DiplomacyStatus { war, peace, alliance, coalition }

enum DiplomacyProposalType { friendship, militaryAlliance, peace, exchange }

/// The eight exchange arguments available in the original Antiyoy diplomacy
/// editor. An offer describes what one side gives to the other side.
enum DiplomacyExchangeType {
  nothing,
  money,
  lands,
  friendship,
  militaryAlliance,
  warDeclaration,
  ceasefire,
  removeBlackMark,
  subsidies,
}

enum NavalAssetKind { boat, seaFort }

class NavalAssetRef {
  const NavalAssetRef({required this.kind, required this.id});

  final NavalAssetKind kind;
  final int id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavalAssetRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  Map<String, dynamic> toJson() => {'kind': kind.name, 'id': id};

  factory NavalAssetRef.fromJson(Map<String, dynamic> json) => NavalAssetRef(
    kind:
        NavalAssetKind.values
            .where((value) => value.name == json['kind'])
            .firstOrNull ??
        NavalAssetKind.boat,
    id: (json['id'] as num?)?.toInt() ?? -1,
  );
}

class DiplomacyOffer {
  const DiplomacyOffer({
    this.type = DiplomacyExchangeType.nothing,
    this.amount = 0,
    this.duration = 0,
    this.targetPlayer = -1,
    this.tiles = const <int>[],
    this.navalRefs = const <NavalAssetRef>[],
  });

  final DiplomacyExchangeType type;
  final int amount;
  final int duration;
  final int targetPlayer;
  final List<int> tiles;
  final List<NavalAssetRef> navalRefs;

  DiplomacyOffer copyWith({
    DiplomacyExchangeType? type,
    int? amount,
    int? duration,
    int? targetPlayer,
    List<int>? tiles,
    List<NavalAssetRef>? navalRefs,
  }) => DiplomacyOffer(
    type: type ?? this.type,
    amount: amount ?? this.amount,
    duration: duration ?? this.duration,
    targetPlayer: targetPlayer ?? this.targetPlayer,
    tiles: tiles ?? this.tiles,
    navalRefs: navalRefs ?? this.navalRefs,
  );

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'amount': amount,
    'duration': duration,
    'targetPlayer': targetPlayer,
    'tiles': tiles,
    'navalRefs': navalRefs.map((reference) => reference.toJson()).toList(),
  };

  factory DiplomacyOffer.fromJson(Map<String, dynamic> json) => DiplomacyOffer(
    type:
        DiplomacyExchangeType.values
            .where((value) => value.name == json['type'])
            .firstOrNull ??
        DiplomacyExchangeType.nothing,
    amount: (json['amount'] as num?)?.toInt() ?? 0,
    duration: (json['duration'] as num?)?.toInt() ?? 0,
    targetPlayer: (json['targetPlayer'] as num?)?.toInt() ?? -1,
    tiles: (json['tiles'] as List? ?? const <Object>[])
        .map((value) => (value as num).toInt())
        .toList(),
    navalRefs: (json['navalRefs'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((value) => NavalAssetRef.fromJson(value.cast<String, dynamic>()))
        .toList(),
  );
}

class DiplomacySubsidy {
  const DiplomacySubsidy({
    required this.payer,
    required this.receiver,
    required this.amount,
    required this.turnsLeft,
    this.mandatory = false,
  });

  final int payer;
  final int receiver;
  final int amount;
  final int turnsLeft;

  /// True for a friendship-break compensation. Unlike a voluntary subsidy,
  /// this obligation survives a later war between the same two players.
  final bool mandatory;

  DiplomacySubsidy copyWith({int? turnsLeft}) => DiplomacySubsidy(
    payer: payer,
    receiver: receiver,
    amount: amount,
    turnsLeft: turnsLeft ?? this.turnsLeft,
    mandatory: mandatory,
  );

  Map<String, dynamic> toJson() => {
    'payer': payer,
    'receiver': receiver,
    'amount': amount,
    'turnsLeft': turnsLeft,
    'mandatory': mandatory,
  };

  factory DiplomacySubsidy.fromJson(Map<String, dynamic> json) =>
      DiplomacySubsidy(
        payer: json['payer'] as int,
        receiver: json['receiver'] as int,
        amount: json['amount'] as int,
        turnsLeft: json['turnsLeft'] as int,
        mandatory: json['mandatory'] as bool? ?? false,
      );
}

class DiplomacyMessage {
  const DiplomacyMessage({
    required this.from,
    required this.to,
    required this.text,
    required this.createdRound,
  });

  final int from;
  final int to;
  final String text;
  final int createdRound;

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'text': text,
    'createdRound': createdRound,
  };

  factory DiplomacyMessage.fromJson(Map<String, dynamic> json) =>
      DiplomacyMessage(
        from: json['from'] as int,
        to: json['to'] as int,
        text: json['text'] as String? ?? '',
        createdRound: json['createdRound'] as int? ?? 0,
      );
}

enum TileObject {
  none,
  pine,
  palm,
  town,
  farm,
  tower,
  strongTower,
  grave,
  port1,
  port2,
  artillery1,
  artillery2,
  artillery3,
}

class GameConfig {
  const GameConfig({
    this.mapSize = MapSize.medium,
    this.playerCount = 4,
    this.humanCount = 1,
    this.seed = 1,
    this.difficulty = AiDifficulty.normal,
    this.treePercent = 10,
    this.startingProvinceCount = 0,
    this.playerColorOffset = 0,
    this.slayRules = false,
    this.fogOfWar = false,
    this.diplomacy = false,
    this.campaignLevel,
  });

  final MapSize mapSize;
  final int playerCount;
  final int humanCount;
  final int seed;
  final AiDifficulty difficulty;
  final int treePercent;
  final int startingProvinceCount;
  final int playerColorOffset;
  final bool slayRules;
  final bool fogOfWar;
  final bool diplomacy;
  final int? campaignLevel;

  Map<String, dynamic> toJson() => {
    'mapSize': mapSize.name,
    'playerCount': playerCount,
    'humanCount': humanCount,
    'seed': seed,
    'difficulty': difficulty.name,
    'treePercent': treePercent,
    'startingProvinceCount': startingProvinceCount,
    'playerColorOffset': playerColorOffset,
    'slayRules': slayRules,
    'fogOfWar': fogOfWar,
    'diplomacy': diplomacy,
    if (campaignLevel != null) 'campaignLevel': campaignLevel,
  };

  factory GameConfig.fromJson(Map<String, dynamic> json) => GameConfig(
    mapSize: MapSize.values.byName(json['mapSize'] as String),
    playerCount: json['playerCount'] as int,
    humanCount: json['humanCount'] as int? ?? 1,
    seed: json['seed'] as int,
    difficulty: AiDifficulty.values.byName(json['difficulty'] as String),
    treePercent: json['treePercent'] as int? ?? 10,
    startingProvinceCount: json['startingProvinceCount'] as int? ?? 0,
    playerColorOffset: json['playerColorOffset'] as int? ?? 0,
    slayRules: json['slayRules'] as bool? ?? false,
    fogOfWar: json['fogOfWar'] as bool? ?? false,
    diplomacy: json['diplomacy'] as bool? ?? false,
    campaignLevel: json['campaignLevel'] as int?,
  );
}

class GameUnit {
  GameUnit({
    required this.strength,
    this.ready = true,
    this.owner = -1,
    this.homeProvinceId = -1,
    this.typeId,
    List<int>? transitAllies,
  }) : transitAllies = transitAllies ?? <int>[];

  int strength;
  bool ready;
  int owner;
  int homeProvinceId;
  final String? typeId;
  final List<int> transitAllies;

  Map<String, dynamic> toJson() => {
    'strength': strength,
    'ready': ready,
    'owner': owner,
    'homeProvinceId': homeProvinceId,
    if (typeId != null) 'typeId': typeId,
    'transitAllies': transitAllies,
  };

  factory GameUnit.fromJson(Map<String, dynamic> json) => GameUnit(
    strength: json['strength'] as int,
    ready: json['ready'] as bool,
    owner: (json['owner'] as num?)?.toInt() ?? -1,
    homeProvinceId: (json['homeProvinceId'] as num?)?.toInt() ?? -1,
    typeId: json['typeId'] as String?,
    transitAllies: (json['transitAllies'] as List? ?? const <Object>[])
        .map((value) => (value as num).toInt())
        .toList(),
  );
}

class GameBoat {
  GameBoat({
    this.id = -1,
    required this.owner,
    required this.level,
    required this.homeProvinceId,
    this.ready = true,
    int? supportedTile,
    List<int>? supportedTiles,
    this.damage = 0,
    List<GameUnit>? cargo,
  }) : supportedTiles =
           supportedTiles ??
           (supportedTile == null ? <int>[] : <int>[supportedTile]),
       cargo = cargo ?? [];

  int id;
  int owner;
  int level;
  int homeProvinceId;
  bool ready;
  final List<int> supportedTiles;
  int damage;
  final List<GameUnit> cargo;

  int? get supportedTile =>
      supportedTiles.isEmpty ? null : supportedTiles.first;

  set supportedTile(int? value) {
    supportedTiles.clear();
    if (value != null) supportedTiles.add(value);
  }

  int get usedCapacity => cargo.fold(0, (sum, unit) => sum + unit.strength);

  Map<String, dynamic> toJson() => {
    'id': id,
    'owner': owner,
    'level': level,
    'homeProvinceId': homeProvinceId,
    'ready': ready,
    'supportedTile': supportedTile,
    'supportedTiles': supportedTiles,
    'damage': damage,
    'cargo': cargo.map((unit) => unit.toJson()).toList(),
  };

  factory GameBoat.fromJson(Map<String, dynamic> json) => GameBoat(
    id: (json['id'] as num?)?.toInt() ?? -1,
    owner: json['owner'] as int,
    level: json['level'] as int,
    homeProvinceId: json['homeProvinceId'] as int,
    ready: json['ready'] as bool? ?? true,
    supportedTile: json['supportedTile'] as int?,
    supportedTiles: json['supportedTiles'] == null
        ? null
        : (json['supportedTiles'] as List).cast<int>(),
    damage: json['damage'] as int? ?? 0,
    cargo: (json['cargo'] as List? ?? const [])
        .map((item) => GameUnit.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class SeaFort {
  SeaFort({this.id = -1, required this.owner, required this.homeProvinceId});

  int id;
  int owner;
  int homeProvinceId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'owner': owner,
    'homeProvinceId': homeProvinceId,
  };

  factory SeaFort.fromJson(Map<String, dynamic> json) => SeaFort(
    id: (json['id'] as num?)?.toInt() ?? -1,
    owner: json['owner'] as int,
    homeProvinceId: json['homeProvinceId'] as int,
  );
}

class WaterCell {
  WaterCell({
    required this.index,
    required this.tiles,
    List<int>? neighbors,
    List<int>? coastTiles,
    this.navigable = true,
    this.seaMint = false,
    this.boat,
    this.seaFort,
  }) : neighbors = neighbors ?? [],
       coastTiles = coastTiles ?? [];

  final int index;
  final List<int> tiles;
  final List<int> neighbors;
  final List<int> coastTiles;
  bool navigable;
  bool seaMint;
  GameBoat? boat;
  SeaFort? seaFort;

  Map<String, dynamic> toJson() => {
    'index': index,
    'tiles': tiles,
    'neighbors': neighbors,
    'coastTiles': coastTiles,
    'navigable': navigable,
    'seaMint': seaMint,
    'boat': boat?.toJson(),
    'seaFort': seaFort?.toJson(),
  };

  factory WaterCell.fromJson(Map<String, dynamic> json) => WaterCell(
    index: json['index'] as int,
    tiles: (json['tiles'] as List).cast<int>(),
    neighbors: (json['neighbors'] as List? ?? const []).cast<int>(),
    coastTiles: (json['coastTiles'] as List? ?? const []).cast<int>(),
    navigable: json['navigable'] as bool? ?? true,
    seaMint: json['seaMint'] as bool? ?? false,
    boat: json['boat'] == null
        ? null
        : GameBoat.fromJson(json['boat'] as Map<String, dynamic>),
    seaFort: json['seaFort'] == null
        ? null
        : SeaFort.fromJson(json['seaFort'] as Map<String, dynamic>),
  );
}

class CoalitionClaim {
  const CoalitionClaim({
    required this.campaignId,
    required this.originalOwner,
    required this.members,
    required this.captor,
    List<int>? contributors,
    this.settlementValue = 25,
    this.conferenceId = -1,
  }) : contributors = contributors ?? members;

  final int campaignId;
  final int originalOwner;

  /// The complete campaign side. This remains the military-access list while
  /// the land is disputed, including for schema-11 compatibility.
  final List<int> members;
  final int captor;

  /// The exact countries that enabled this capture: the captor and only the
  /// allies whose sovereign land the capturing unit actually crossed.
  final List<int> contributors;

  /// Frozen before combat clears the captured object/unit from the tile.
  final int settlementValue;

  /// Set once an ended war moves this claim into a peace conference.
  final int conferenceId;

  CoalitionClaim copyWith({
    int? campaignId,
    int? originalOwner,
    List<int>? members,
    int? captor,
    List<int>? contributors,
    int? settlementValue,
    int? conferenceId,
  }) => CoalitionClaim(
    campaignId: campaignId ?? this.campaignId,
    originalOwner: originalOwner ?? this.originalOwner,
    members: members ?? this.members,
    captor: captor ?? this.captor,
    contributors: contributors ?? this.contributors,
    settlementValue: settlementValue ?? this.settlementValue,
    conferenceId: conferenceId ?? this.conferenceId,
  );

  Map<String, dynamic> toJson() => {
    'campaignId': campaignId,
    'originalOwner': originalOwner,
    'members': members,
    'captor': captor,
    'contributors': contributors,
    'settlementValue': settlementValue,
    'conferenceId': conferenceId,
  };

  factory CoalitionClaim.fromJson(Map<String, dynamic> json) => CoalitionClaim(
    campaignId: (json['campaignId'] as num?)?.toInt() ?? -1,
    originalOwner: (json['originalOwner'] as num?)?.toInt() ?? -1,
    members: (json['members'] as List? ?? const <Object>[])
        .map((value) => (value as num).toInt())
        .toList(),
    captor: (json['captor'] as num?)?.toInt() ?? -1,
    contributors:
        (json['contributors'] as List? ??
                json['members'] as List? ??
                const <Object>[])
            .map((value) => (value as num).toInt())
            .toList(),
    settlementValue: (json['settlementValue'] as num?)?.toInt() ?? 25,
    conferenceId: (json['conferenceId'] as num?)?.toInt() ?? -1,
  );
}

class HexTile {
  HexTile({
    required this.index,
    required this.q,
    required this.r,
    this.active = false,
    this.inWorld = true,
    this.owner = -1,
    TileObject object = TileObject.none,
    this.buildingTypeId,
    this.airUnit,
    this.unit,
    this.treeBorn = -1,
    this.artilleryCooldown = 0,
    this.artilleryAmmo = 0,
    this.coalitionClaim,
    List<int>? neighbors,
  }) : _object = object,
       neighbors = neighbors ?? [];

  final int index;
  final int q;
  final int r;
  bool active;
  bool inWorld;
  int owner;
  TileObject _object;
  TileObject get object => _object;
  set object(TileObject value) {
    _object = value;
    // Existing captures, clearing, capital creation and editor painting all
    // replace the land object through this setter.
    buildingTypeId = null;
  }

  String? buildingTypeId;
  GameUnit? airUnit;
  GameUnit? unit;
  int treeBorn;
  int artilleryCooldown;
  int artilleryAmmo;
  CoalitionClaim? coalitionClaim;
  final List<int> neighbors;

  bool get hasTree => object == TileObject.pine || object == TileObject.palm;

  Map<String, dynamic> toJson() => {
    'index': index,
    'q': q,
    'r': r,
    'active': active,
    'inWorld': inWorld,
    'owner': owner,
    'object': object.name,
    if (buildingTypeId != null) 'buildingTypeId': buildingTypeId,
    if (airUnit != null) 'airUnit': airUnit!.toJson(),
    'unit': unit?.toJson(),
    'treeBorn': treeBorn,
    'artilleryCooldown': artilleryCooldown,
    'artilleryAmmo': artilleryAmmo,
    'coalitionClaim': coalitionClaim?.toJson(),
    'neighbors': neighbors,
  };

  factory HexTile.fromJson(Map<String, dynamic> json) => HexTile(
    index: json['index'] as int,
    q: json['q'] as int,
    r: json['r'] as int,
    active: json['active'] as bool,
    inWorld: json['inWorld'] as bool? ?? true,
    owner: json['owner'] as int,
    object: TileObject.values.byName(json['object'] as String),
    buildingTypeId: json['buildingTypeId'] as String?,
    airUnit: json['airUnit'] == null
        ? null
        : GameUnit.fromJson(Map<String, dynamic>.from(json['airUnit'] as Map)),
    unit: json['unit'] == null
        ? null
        : GameUnit.fromJson(json['unit'] as Map<String, dynamic>),
    treeBorn: json['treeBorn'] as int? ?? -1,
    artilleryCooldown: json['artilleryCooldown'] as int? ?? 0,
    artilleryAmmo: json['artilleryAmmo'] as int? ?? 0,
    coalitionClaim: json['coalitionClaim'] is Map
        ? CoalitionClaim.fromJson(
            (json['coalitionClaim'] as Map).cast<String, dynamic>(),
          )
        : null,
    neighbors: (json['neighbors'] as List).cast<int>(),
  );
}

class Province {
  Province({
    required this.id,
    required this.owner,
    required this.tiles,
    required this.money,
    required this.capital,
    this.navalCapital = false,
    this.navalFounded = false,
  });

  final int id;
  final int owner;
  final List<int> tiles;
  int money;
  int capital;
  bool navalCapital;
  bool navalFounded;

  Map<String, dynamic> toJson() => {
    'id': id,
    'owner': owner,
    'tiles': tiles,
    'money': money,
    'capital': capital,
    'navalCapital': navalCapital,
    'navalFounded': navalFounded,
  };

  factory Province.fromJson(Map<String, dynamic> json) => Province(
    id: json['id'] as int,
    owner: json['owner'] as int,
    tiles: (json['tiles'] as List).cast<int>(),
    money: json['money'] as int,
    capital: json['capital'] as int,
    navalCapital: json['navalCapital'] as bool? ?? false,
    navalFounded: json['navalFounded'] as bool? ?? false,
  );
}

class WarCampaign {
  const WarCampaign({
    required this.id,
    required this.attackerLeader,
    required this.defenderLeader,
    required this.sideA,
    required this.sideB,
    required this.startedRound,
  });

  final int id;
  final int attackerLeader;
  final int defenderLeader;
  final List<int> sideA;
  final List<int> sideB;
  final int startedRound;

  bool containsPlayer(int player) =>
      sideA.contains(player) || sideB.contains(player);

  bool opposes(int first, int second) =>
      (sideA.contains(first) && sideB.contains(second)) ||
      (sideA.contains(second) && sideB.contains(first));

  Map<String, dynamic> toJson() => {
    'id': id,
    'attackerLeader': attackerLeader,
    'defenderLeader': defenderLeader,
    'sideA': sideA,
    'sideB': sideB,
    'startedRound': startedRound,
  };

  factory WarCampaign.fromJson(Map<String, dynamic> json) => WarCampaign(
    id: (json['id'] as num?)?.toInt() ?? -1,
    attackerLeader: (json['attackerLeader'] as num?)?.toInt() ?? -1,
    defenderLeader: (json['defenderLeader'] as num?)?.toInt() ?? -1,
    sideA: (json['sideA'] as List? ?? const <Object>[])
        .map((value) => (value as num).toInt())
        .toList(),
    sideB: (json['sideB'] as List? ?? const <Object>[])
        .map((value) => (value as num).toInt())
        .toList(),
    startedRound: (json['startedRound'] as num?)?.toInt() ?? 0,
  );
}

/// A multi-party settlement for coalition-assisted conquests from one former
/// owner by one side of a completed war campaign. Direct sovereign conquests
/// never enter this model.
class PeaceConference {
  PeaceConference({
    required this.id,
    required this.sourceCampaignId,
    required this.originalOwner,
    required this.claimTiles,
    required this.participants,
    required this.openedRound,
    required this.deadlineRound,
    Map<int, int>? tileValues,
    Map<int, int>? contributionPoints,
    Map<int, List<int>>? allocations,
    this.proposer = -1,
    this.revision = 0,
    List<int>? acceptedBy,
  }) : tileValues = tileValues ?? <int, int>{},
       contributionPoints = contributionPoints ?? <int, int>{},
       allocations = allocations ?? <int, List<int>>{},
       acceptedBy = acceptedBy ?? <int>[];

  final int id;
  final int sourceCampaignId;
  final int originalOwner;
  final List<int> claimTiles;
  final List<int> participants;
  final int openedRound;
  final int deadlineRound;
  final Map<int, int> tileValues;
  final Map<int, int> contributionPoints;
  final Map<int, List<int>> allocations;
  int proposer;
  int revision;
  final List<int> acceptedBy;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceCampaignId': sourceCampaignId,
    'originalOwner': originalOwner,
    'claimTiles': claimTiles,
    'participants': participants,
    'openedRound': openedRound,
    'deadlineRound': deadlineRound,
    'tileValues': _encodeIntMap(tileValues),
    'contributionPoints': _encodeIntMap(contributionPoints),
    'allocations': _encodeIntListMap(allocations),
    'proposer': proposer,
    'revision': revision,
    'acceptedBy': acceptedBy,
  };

  factory PeaceConference.fromJson(Map<String, dynamic> json) =>
      PeaceConference(
        id: (json['id'] as num?)?.toInt() ?? -1,
        sourceCampaignId: (json['sourceCampaignId'] as num?)?.toInt() ?? -1,
        originalOwner: (json['originalOwner'] as num?)?.toInt() ?? -1,
        claimTiles: (json['claimTiles'] as List? ?? const <Object>[])
            .map((value) => (value as num).toInt())
            .toList(),
        participants: (json['participants'] as List? ?? const <Object>[])
            .map((value) => (value as num).toInt())
            .toList(),
        openedRound: (json['openedRound'] as num?)?.toInt() ?? 0,
        deadlineRound: (json['deadlineRound'] as num?)?.toInt() ?? 5,
        tileValues: _decodeIntMap(json['tileValues']),
        contributionPoints: _decodeIntMap(json['contributionPoints']),
        allocations: _decodeIntListMap(json['allocations']),
        proposer: (json['proposer'] as num?)?.toInt() ?? -1,
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        acceptedBy: (json['acceptedBy'] as List? ?? const <Object>[])
            .map((value) => (value as num).toInt())
            .toList(),
      );
}

Map<String, int> _encodeIntMap(Map<int, int> values) {
  final keys = values.keys.toList()..sort();
  return <String, int>{for (final key in keys) '$key': values[key]!};
}

Map<int, int> _decodeIntMap(Object? raw) {
  if (raw is! Map) return <int, int>{};
  final result = <int, int>{};
  for (final entry in raw.entries) {
    final key = int.tryParse(entry.key.toString());
    final value = entry.value;
    if (key != null && value is num) result[key] = value.toInt();
  }
  return result;
}

Map<String, List<int>> _encodeIntListMap(Map<int, List<int>> values) {
  final keys = values.keys.toList()..sort();
  return <String, List<int>>{for (final key in keys) '$key': values[key]!};
}

Map<int, List<int>> _decodeIntListMap(Object? raw) {
  if (raw is! Map) return <int, List<int>>{};
  final result = <int, List<int>>{};
  for (final entry in raw.entries) {
    final key = int.tryParse(entry.key.toString());
    final value = entry.value;
    if (key == null || value is! List) continue;
    result[key] = value.map((item) => (item as num).toInt()).toList();
  }
  return result;
}

class DiplomacyProposal {
  const DiplomacyProposal({
    required this.from,
    required this.to,
    required this.type,
    required this.createdRound,
    this.fromOffer = const DiplomacyOffer(),
    this.toOffer = const DiplomacyOffer(),
    this.terms,
    this.rationale = '',
  });

  final int from;
  final int to;
  final DiplomacyProposalType type;
  final int createdRound;
  final String rationale;
  final DiplomacyOffer fromOffer;
  final DiplomacyOffer toOffer;

  /// Online-style independently directed conditions. Null migrates old saves.
  final List<DiplomacyTerm>? terms;

  List<DiplomacyTerm> get effectiveTerms =>
      terms ??
      [
        DiplomacyTerm(fromSender: true, offer: fromOffer),
        DiplomacyTerm(fromSender: false, offer: toOffer),
      ];

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    'type': type.name,
    'createdRound': createdRound,
    if (rationale.isNotEmpty) 'rationale': rationale,
    'fromOffer': fromOffer.toJson(),
    'toOffer': toOffer.toJson(),
    if (terms != null) 'terms': terms!.map((term) => term.toJson()).toList(),
  };

  factory DiplomacyProposal.fromJson(Map<String, dynamic> json) =>
      DiplomacyProposal(
        from: json['from'] as int,
        to: json['to'] as int,
        type:
            DiplomacyProposalType.values
                .where((value) => value.name == json['type'])
                .firstOrNull ??
            DiplomacyProposalType.exchange,
        createdRound: json['createdRound'] as int? ?? 0,
        rationale: json['rationale'] as String? ?? '',
        terms: (json['terms'] as List?)
            ?.map(
              (item) =>
                  DiplomacyTerm.fromJson((item as Map).cast<String, dynamic>()),
            )
            .toList(),
        fromOffer: json['fromOffer'] is Map
            ? DiplomacyOffer.fromJson(
                (json['fromOffer'] as Map).cast<String, dynamic>(),
              )
            : const DiplomacyOffer(),
        toOffer: json['toOffer'] is Map
            ? DiplomacyOffer.fromJson(
                (json['toOffer'] as Map).cast<String, dynamic>(),
              )
            : const DiplomacyOffer(),
      );
}

class DiplomacyTerm {
  const DiplomacyTerm({required this.fromSender, required this.offer});
  final bool fromSender;
  final DiplomacyOffer offer;
  Map<String, dynamic> toJson() => {
    'fromSender': fromSender,
    'offer': offer.toJson(),
  };
  factory DiplomacyTerm.fromJson(Map<String, dynamic> json) => DiplomacyTerm(
    fromSender: json['fromSender'] as bool,
    offer: DiplomacyOffer.fromJson(
      (json['offer'] as Map).cast<String, dynamic>(),
    ),
  );
}

/// One shared relationship per pair. The symmetric matrix retains the old
/// save shape; version 2 migrates directed scores by their rounded mean.
/// This small, bounded section is also the unit of LAN synchronization.
class DiplomacySocialState {
  DiplomacySocialState(int players)
    : opinions = _zeroDiplomacyMatrix(players),
      actionCooldowns = _zeroDiplomacyMatrix(players),
      lastContact = List.generate(players, (_) => List.filled(players, -1000)),
      lastTradeReward = List.generate(
        players,
        (_) => List.filled(players, -1000),
      ),
      lastAidReward = List.generate(
        players,
        (_) => List.filled(players, -1000),
      );
  final List<List<int>> opinions;
  final List<List<int>> actionCooldowns;
  final List<List<int>> lastContact;
  final List<List<int>> lastTradeReward;
  final List<List<int>> lastAidReward;
  final List<DiplomacyOpinionEvent> events = [];
  int relationship(int first, int second) => first == second
      ? 0
      : ((opinions[first][second] + opinions[second][first]) / 2).round().clamp(
          -100,
          100,
        );
  Map<String, dynamic> toJson() => {
    'relationsVersion': 2,
    'opinions': opinions,
    'actionCooldowns': actionCooldowns,
    'lastContact': lastContact,
    'lastTradeReward': lastTradeReward,
    'lastAidReward': lastAidReward,
    'events': events.map((event) => event.toJson()).toList(),
  };
  factory DiplomacySocialState.fromJson(
    Map<String, dynamic>? json,
    int players,
  ) {
    final result = DiplomacySocialState(players);
    if (json == null) return result;
    for (final entry in {
      'opinions': result.opinions,
      'actionCooldowns': result.actionCooldowns,
      'lastContact': result.lastContact,
      'lastTradeReward': result.lastTradeReward,
      'lastAidReward': result.lastAidReward,
    }.entries) {
      final raw = json[entry.key];
      if (raw is! List || raw.length != players) continue;
      for (var i = 0; i < players; i++) {
        if (raw[i] is! List || (raw[i] as List).length != players) continue;
        for (var j = 0; j < players; j++) {
          final value = raw[i][j];
          if (value is int) entry.value[i][j] = value;
        }
      }
    }
    result.events.addAll(
      (json['events'] as List? ?? []).map(
        (item) => DiplomacyOpinionEvent.fromJson(
          (item as Map).cast<String, dynamic>(),
        ),
      ),
    );
    for (var a = 0; a < players; a++) {
      result.opinions[a][a] = 0;
      for (var b = a + 1; b < players; b++) {
        final shared = result.relationship(a, b);
        result.opinions[a][b] = shared;
        result.opinions[b][a] = shared;
      }
    }
    return result;
  }
}

class DiplomacyOpinionEvent {
  const DiplomacyOpinionEvent({
    required this.observer,
    required this.subject,
    required this.delta,
    required this.round,
    required this.reason,
  });
  final int observer;
  final int subject;
  final int delta;
  final int round;
  final String reason;
  Map<String, dynamic> toJson() => {
    'observer': observer,
    'subject': subject,
    'delta': delta,
    'round': round,
    'reason': reason,
  };
  factory DiplomacyOpinionEvent.fromJson(Map<String, dynamic> json) =>
      DiplomacyOpinionEvent(
        observer: json['observer'] as int,
        subject: json['subject'] as int,
        delta: json['delta'] as int,
        round: json['round'] as int,
        reason: json['reason'] as String,
      );
}

class GameState {
  GameState({
    required this.config,
    required this.modId,
    this.modSnapshot,
    required this.width,
    required this.height,
    required this.hexes,
    List<WaterCell>? waterCells,
    required this.provinces,
    required this.turn,
    List<int>? turnOrder,
    required this.round,
    required this.rngState,
    required this.nextProvinceId,
    this.nextNavalEntityId = 1,
    this.nextWarCampaignId = 1,
    this.nextPeaceConferenceId = 1,
    this.winner,
    List<WarCampaign>? campaigns,
    List<PeaceConference>? peaceConferences,
    List<List<DiplomacyStatus>>? diplomacyRelations,
    List<List<int>>? diplomacyAllianceTurns,
    List<List<int>>? diplomacyWarCooldowns,
    List<List<bool>>? diplomacyBlackMarks,
    List<List<int>>? diplomacyBlackMarkCooldowns,
    List<List<int>>? diplomacyDebts,
    List<int>? diplomacyTraitorTurns,
    List<DiplomacySubsidy>? diplomacySubsidies,
    List<DiplomacyProposal>? diplomacyProposals,
    List<DiplomacyMessage>? diplomacyMessages,
    List<String>? diplomacyLog,
    List<String>? playerNames,
    DiplomacySocialState? diplomacySocial,
  }) : _turnOrder = _validatedTurnOrder(turnOrder, config.playerCount),
       waterCells = waterCells ?? [],
       diplomacySocial =
           diplomacySocial ?? DiplomacySocialState(config.playerCount),
       playerNames = _normalizedPlayerNames(
         playerNames,
         config.playerCount,
         config.seed,
       ),
       diplomacyRelations =
           diplomacyRelations ??
           _defaultDiplomacy(config.playerCount, config.diplomacy),
       diplomacyAllianceTurns =
           diplomacyAllianceTurns ?? _zeroDiplomacyMatrix(config.playerCount),
       diplomacyWarCooldowns =
           diplomacyWarCooldowns ?? _zeroDiplomacyMatrix(config.playerCount),
       diplomacyBlackMarks =
           diplomacyBlackMarks ?? _falseDiplomacyMatrix(config.playerCount),
       diplomacyBlackMarkCooldowns =
           diplomacyBlackMarkCooldowns ??
           _zeroDiplomacyMatrix(config.playerCount),
       diplomacyDebts =
           diplomacyDebts ?? _zeroDiplomacyMatrix(config.playerCount),
       diplomacyTraitorTurns =
           diplomacyTraitorTurns ??
           List<int>.filled(config.playerCount, 0, growable: true),
       diplomacySubsidies = diplomacySubsidies ?? [],
       diplomacyProposals = diplomacyProposals ?? [],
       campaigns = campaigns ?? [],
       peaceConferences = peaceConferences ?? [],
       diplomacyMessages = diplomacyMessages ?? [],
       diplomacyLog = diplomacyLog ?? [] {
    _assignLegacyNavalEntityIds(this);
    _advanceNextWarCampaignId(this);
    _advanceNextPeaceConferenceId(this);
  }

  final GameConfig config;
  final String modId;
  Map<String, dynamic>? modSnapshot;
  int width;
  int height;
  final List<HexTile> hexes;
  final List<WaterCell> waterCells;
  List<Province> provinces;
  int turn;
  List<int> _turnOrder;
  List<int> get turnOrder => _turnOrder;
  set turnOrder(List<int> value) {
    _turnOrder = _validatedTurnOrder(value, config.playerCount);
  }

  /// Called once when starting a match, never while loading or replaying it.
  /// Seat IDs (human/bot identity, color and LAN ownership) stay unchanged.
  void randomizeTurnOrder({math.Random? random}) {
    final order = List<int>.generate(config.playerCount, (i) => i)
      ..shuffle(random ?? math.Random.secure());
    turnOrder = order;
    turn = order.firstWhere(
      (player) =>
          provinces.any((province) => province.owner == player) ||
          waterCells.any(
            (cell) =>
                cell.boat?.owner == player || cell.seaFort?.owner == player,
          ),
      orElse: () => order.first,
    );
  }

  int round;
  int rngState;
  int nextProvinceId;
  int nextNavalEntityId;
  int nextWarCampaignId;
  int nextPeaceConferenceId;
  int? winner;
  final List<WarCampaign> campaigns;
  final List<PeaceConference> peaceConferences;
  final List<List<DiplomacyStatus>> diplomacyRelations;
  final List<List<int>> diplomacyAllianceTurns;
  final List<List<int>> diplomacyWarCooldowns;
  final List<List<bool>> diplomacyBlackMarks;
  final List<List<int>> diplomacyBlackMarkCooldowns;
  final List<List<int>> diplomacyDebts;
  final List<int> diplomacyTraitorTurns;
  final List<DiplomacySubsidy> diplomacySubsidies;
  final List<DiplomacyProposal> diplomacyProposals;
  final List<DiplomacyMessage> diplomacyMessages;
  final List<String> diplomacyLog;
  final List<String> playerNames;
  DiplomacySocialState diplomacySocial;

  bool isHuman(int player) => player >= 0 && player < config.humanCount;
  bool get currentPlayerIsHuman => isHuman(turn);

  String playerName(int player) {
    if (player < 0 || player >= config.playerCount) {
      return '${player + 1}-ойыншы';
    }
    final name = playerNames[player].trim();
    return name.isEmpty ? '${player + 1}-ойыншы' : name;
  }

  String playerPossessiveName(int player) {
    final name = playerName(player);
    return name.endsWith('-ойыншы') ? '$nameның' : '$name ойыншысының';
  }

  void setPlayerName(int player, String value) {
    if (player < 0 || player >= config.playerCount) return;
    final compact = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (compact.isNotEmpty) {
      playerNames[player] = compact;
    } else {
      final raw = List<String>.of(playerNames)..[player] = '';
      playerNames[player] = _normalizedPlayerNames(
        raw,
        config.playerCount,
        config.seed,
      )[player];
    }
  }

  Map<String, dynamic> toJson() => {
    'schema': 13,
    'config': config.toJson(),
    'modId': modId,
    if (modSnapshot != null) 'modSnapshot': modSnapshot,
    'width': width,
    'height': height,
    'hexes': hexes.map((tile) => tile.toJson()).toList(),
    'waterCells': waterCells.map((cell) => cell.toJson()).toList(),
    'provinces': provinces.map((province) => province.toJson()).toList(),
    'turn': turn,
    'turnOrder': turnOrder,
    'round': round,
    'rngState': rngState,
    'nextProvinceId': nextProvinceId,
    'nextNavalEntityId': nextNavalEntityId,
    'nextWarCampaignId': nextWarCampaignId,
    'nextPeaceConferenceId': nextPeaceConferenceId,
    'winner': winner,
    'playerNames': playerNames,
    'playerNamesVersion': 1,
    'diplomacySocial': diplomacySocial.toJson(),
    'campaigns': campaigns.map((campaign) => campaign.toJson()).toList(),
    'peaceConferences': peaceConferences
        .map((conference) => conference.toJson())
        .toList(),
    'diplomacyRelations': diplomacyRelations
        .map((row) => row.map((status) => status.name).toList())
        .toList(),
    'diplomacyAllianceTurns': diplomacyAllianceTurns,
    'diplomacyWarCooldowns': diplomacyWarCooldowns,
    'diplomacyBlackMarks': diplomacyBlackMarks,
    'diplomacyBlackMarkCooldowns': diplomacyBlackMarkCooldowns,
    'diplomacyDebts': diplomacyDebts,
    'diplomacyTraitorTurns': diplomacyTraitorTurns,
    'diplomacySubsidies': diplomacySubsidies
        .map((subsidy) => subsidy.toJson())
        .toList(),
    'diplomacyProposals': diplomacyProposals
        .map((proposal) => proposal.toJson())
        .toList(),
    'diplomacyMessages': diplomacyMessages
        .map((message) => message.toJson())
        .toList(),
    'diplomacyLog': diplomacyLog,
  };

  factory GameState.fromJson(Map<String, dynamic> json) => GameState(
    config: GameConfig.fromJson(json['config'] as Map<String, dynamic>),
    modId: json['modId'] as String,
    modSnapshot: (json['modSnapshot'] as Map?)?.cast<String, dynamic>(),
    width: json['width'] as int,
    height: json['height'] as int,
    hexes: (json['hexes'] as List)
        .map((item) => HexTile.fromJson(item as Map<String, dynamic>))
        .toList(),
    waterCells: (json['waterCells'] as List? ?? const [])
        .map((item) => WaterCell.fromJson(item as Map<String, dynamic>))
        .toList(),
    provinces: (json['provinces'] as List)
        .map((item) => Province.fromJson(item as Map<String, dynamic>))
        .toList(),
    turn: json['turn'] as int,
    turnOrder: (json['turnOrder'] as List?)?.cast<int>(),
    round: json['round'] as int,
    rngState: json['rngState'] as int,
    nextProvinceId: json['nextProvinceId'] as int,
    nextNavalEntityId: (json['nextNavalEntityId'] as num?)?.toInt() ?? 1,
    nextWarCampaignId: (json['nextWarCampaignId'] as num?)?.toInt() ?? 1,
    nextPeaceConferenceId:
        (json['nextPeaceConferenceId'] as num?)?.toInt() ?? 1,
    winner: json['winner'] as int?,
    playerNames: _savedPlayerNames(json),
    diplomacySocial: DiplomacySocialState.fromJson(
      (json['diplomacySocial'] as Map?)?.cast<String, dynamic>(),
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    campaigns: (json['campaigns'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((item) => WarCampaign.fromJson(item.cast<String, dynamic>()))
        .toList(),
    peaceConferences: (json['peaceConferences'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((item) => PeaceConference.fromJson(item.cast<String, dynamic>()))
        .toList(),
    diplomacyRelations: _readDiplomacy(
      json['diplomacyRelations'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
      (json['config'] as Map<String, dynamic>)['diplomacy'] as bool? ?? false,
    ),
    diplomacyAllianceTurns: _readDiplomacyIntMatrix(
      json['diplomacyAllianceTurns'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    diplomacyWarCooldowns: _readDiplomacyIntMatrix(
      json['diplomacyWarCooldowns'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    diplomacyBlackMarks: _readDiplomacyBoolMatrix(
      json['diplomacyBlackMarks'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    diplomacyBlackMarkCooldowns: _readDiplomacyIntMatrix(
      json['diplomacyBlackMarkCooldowns'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    diplomacyDebts: _readDiplomacyIntMatrix(
      json['diplomacyDebts'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    diplomacyTraitorTurns: _readDiplomacyIntList(
      json['diplomacyTraitorTurns'],
      (json['config'] as Map<String, dynamic>)['playerCount'] as int,
    ),
    diplomacySubsidies: (json['diplomacySubsidies'] as List? ?? const [])
        .map(
          (item) =>
              DiplomacySubsidy.fromJson((item as Map).cast<String, dynamic>()),
        )
        .toList(),
    diplomacyProposals: (json['diplomacyProposals'] as List? ?? const [])
        .map(
          (item) =>
              DiplomacyProposal.fromJson((item as Map).cast<String, dynamic>()),
        )
        .toList(),
    diplomacyMessages: (json['diplomacyMessages'] as List? ?? const [])
        .map(
          (item) =>
              DiplomacyMessage.fromJson((item as Map).cast<String, dynamic>()),
        )
        .toList(),
    diplomacyLog: (json['diplomacyLog'] as List? ?? const []).cast<String>(),
  );
}

List<int> _validatedTurnOrder(List<int>? raw, int playerCount) {
  final order = raw ?? List<int>.generate(playerCount, (i) => i);
  if (order.length != playerCount ||
      order.toSet().length != playerCount ||
      order.any((player) => player < 0 || player >= playerCount)) {
    throw const FormatException('Invalid turn order');
  }
  return List<int>.unmodifiable(order);
}

List<String>? _savedPlayerNames(Map<String, dynamic> json) {
  final raw = (json['playerNames'] as List?)?.whereType<String>().toList();
  if (raw == null || json['playerNamesVersion'] == 1) return raw;
  return [
    for (var i = 0; i < raw.length; i++)
      raw[i].trim() == '${i + 1}-ойыншы' ? '' : raw[i],
  ];
}

List<String> _normalizedPlayerNames(
  List<String>? raw,
  int playerCount,
  int seed,
) {
  final names = [
    for (var i = 0; i < playerCount; i++)
      raw != null && i < raw.length
          ? raw[i].trim().replaceAll(RegExp(r'\s+'), ' ')
          : '',
  ];
  if (!names.contains('')) return names;
  final generated = generatePlayerNames(
    seed,
    playerCount,
    reserved: names.where((name) => name.isNotEmpty),
  );
  return [
    for (var i = 0; i < playerCount; i++)
      names[i].isEmpty ? generated[i] : names[i],
  ];
}

/// Schema 10 and older saves had no stable identity for naval entities. Keep
/// every valid unique ID and assign the remaining entities in packed-water
/// order (boat before fort), starting after both the saved counter and the
/// largest retained ID. This makes repeated loads of the same legacy save
/// produce byte-for-byte stable references.
void _assignLegacyNavalEntityIds(GameState state) {
  final used = <int>{};
  var maximum = 0;
  for (final cell in state.waterCells) {
    final boat = cell.boat;
    if (boat != null) {
      if (boat.id <= 0 || !used.add(boat.id)) {
        boat.id = -1;
      } else if (boat.id > maximum) {
        maximum = boat.id;
      }
    }
    final fort = cell.seaFort;
    if (fort != null) {
      if (fort.id <= 0 || !used.add(fort.id)) {
        fort.id = -1;
      } else if (fort.id > maximum) {
        maximum = fort.id;
      }
    }
  }

  var next = state.nextNavalEntityId;
  if (next <= maximum) next = maximum + 1;
  if (next <= 0) next = 1;
  for (final cell in state.waterCells) {
    final boat = cell.boat;
    if (boat != null && boat.id <= 0) {
      while (used.contains(next)) {
        next++;
      }
      boat.id = next;
      used.add(next++);
    }
    final fort = cell.seaFort;
    if (fort != null && fort.id <= 0) {
      while (used.contains(next)) {
        next++;
      }
      fort.id = next;
      used.add(next++);
    }
  }
  state.nextNavalEntityId = next;
}

void _advanceNextWarCampaignId(GameState state) {
  var next = state.nextWarCampaignId <= 0 ? 1 : state.nextWarCampaignId;
  for (final campaign in state.campaigns) {
    if (campaign.id >= next) next = campaign.id + 1;
  }
  state.nextWarCampaignId = next;
}

void _advanceNextPeaceConferenceId(GameState state) {
  var next = state.nextPeaceConferenceId <= 0 ? 1 : state.nextPeaceConferenceId;
  for (final conference in state.peaceConferences) {
    if (conference.id >= next) next = conference.id + 1;
  }
  state.nextPeaceConferenceId = next;
}

List<List<DiplomacyStatus>> _defaultDiplomacy(
  int playerCount,
  bool diplomacyEnabled,
) => [
  for (var a = 0; a < playerCount; a++)
    [
      for (var b = 0; b < playerCount; b++)
        a == b
            ? DiplomacyStatus.alliance
            : diplomacyEnabled
            ? DiplomacyStatus.peace
            : DiplomacyStatus.war,
    ],
];

List<List<DiplomacyStatus>> _readDiplomacy(
  Object? raw,
  int playerCount,
  bool diplomacyEnabled,
) {
  final fallback = _defaultDiplomacy(playerCount, diplomacyEnabled);
  if (raw is! List || raw.length != playerCount) return fallback;
  for (var a = 0; a < playerCount; a++) {
    final row = raw[a];
    if (row is! List || row.length != playerCount) return fallback;
    for (var b = 0; b < playerCount; b++) {
      final name = row[b];
      fallback[a][b] =
          DiplomacyStatus.values
              .where((status) => status.name == name)
              .firstOrNull ??
          fallback[a][b];
    }
  }
  return fallback;
}

List<List<int>> _zeroDiplomacyMatrix(int playerCount) => [
  for (var a = 0; a < playerCount; a++)
    [for (var b = 0; b < playerCount; b++) 0],
];

List<List<bool>> _falseDiplomacyMatrix(int playerCount) => [
  for (var a = 0; a < playerCount; a++)
    [for (var b = 0; b < playerCount; b++) false],
];

List<List<bool>> _readDiplomacyBoolMatrix(Object? raw, int playerCount) {
  final fallback = _falseDiplomacyMatrix(playerCount);
  if (raw is! List || raw.length != playerCount) return fallback;
  for (var a = 0; a < playerCount; a++) {
    final row = raw[a];
    if (row is! List || row.length != playerCount) return fallback;
    for (var b = 0; b < playerCount; b++) {
      fallback[a][b] = row[b] as bool? ?? false;
    }
  }
  return fallback;
}

List<int> _readDiplomacyIntList(Object? raw, int playerCount) {
  if (raw is! List || raw.length != playerCount) {
    return List<int>.filled(playerCount, 0, growable: true);
  }
  return raw.map((value) => (value as num?)?.toInt() ?? 0).toList();
}

List<List<int>> _readDiplomacyIntMatrix(Object? raw, int playerCount) {
  final fallback = _zeroDiplomacyMatrix(playerCount);
  if (raw is! List || raw.length != playerCount) return fallback;
  for (var a = 0; a < playerCount; a++) {
    final row = raw[a];
    if (row is! List || row.length != playerCount) return fallback;
    for (var b = 0; b < playerCount; b++) {
      fallback[a][b] = (row[b] as num?)?.toInt() ?? 0;
    }
  }
  return fallback;
}

class FastRandom {
  FastRandom(int seed) : state = seed == 0 ? 0x6d2b79f5 : seed;
  int state;

  int nextInt(int max) {
    var x = state & 0x7fffffff;
    x ^= (x << 13) & 0x7fffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0x7fffffff;
    state = x & 0x7fffffff;
    return state % max;
  }

  double nextDouble() => nextInt(0x3fffffff) / 0x3fffffff;
}
