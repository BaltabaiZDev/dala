import 'game_mod.dart';

/// The exported starter is immediately playable, including its new types.
GameMod createExampleMod(GameMod base) {
  final raw = base.toJson()
    ..['id'] = 'my_dala_mod'
    ..['name'] = 'Дала технологиялары'
    ..['title'] = 'DALA'
    ..['author'] = 'Мод авторы'
    ..['description'] =
        'Радар, аэродром, барлаушы және ұшақ. mod.json арқылы өз түрлеріңізді қосыңыз.'
    ..['buildings'] = [
      const ModBuilding(
        id: 'my_dala_mod.radar',
        name: 'Радар',
        price: 30,
        upkeep: 2,
        vision: 7,
        icon: 'radar',
      ).toJson(),
      const ModBuilding(
        id: 'my_dala_mod.airfield',
        name: 'Аэродром',
        price: 50,
        upkeep: 2,
        defense: 1,
        vision: 2,
        icon: 'airfield',
      ).toJson(),
    ]
    ..['units'] = [
      const ModUnitType(
        id: 'my_dala_mod.scout',
        name: 'Барлаушы',
        price: 15,
        upkeep: 2,
        moveRange: 6,
        vision: 4,
        icon: 'scout',
      ).toJson(),
      const ModUnitType(
        id: 'my_dala_mod.aircraft',
        name: 'Ұшақ',
        price: 40,
        upkeep: 4,
        strength: 3,
        moveRange: 8,
        vision: 5,
        movement: ModMovement.air,
        attackRange: 2,
        requiresBuilding: 'my_dala_mod.airfield',
        icon: 'aircraft',
      ).toJson(),
    ];
  return GameMod.fromJson(raw);
}
