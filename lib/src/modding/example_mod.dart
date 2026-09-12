import 'game_mod.dart';

/// Products are configured inside their building; their ids stay stable in saves.
GameMod createExampleMod(GameMod base) {
  final raw = base.toJson()
    ..['id'] = 'my_dala_mod'
    ..['version'] = 2
    ..['name'] = 'Дала технологиялары'
    ..['title'] = 'DALA'
    ..['author'] = 'Мод авторы'
    ..['description'] =
        'Радар, аэродром және казарма. Әр ғимараттың production тізіміне өз әскеріңізді қосыңыз.'
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
        production: [
          ModUnitType(
            id: 'my_dala_mod.aircraft',
            name: 'Ұшақ',
            price: 40,
            upkeep: 4,
            strength: 3,
            moveRange: 8,
            vision: 5,
            movement: ModMovement.air,
            attackRange: 2,
            icon: 'aircraft',
          ),
        ],
      ).toJson(),
      const ModBuilding(
        id: 'my_dala_mod.barracks',
        name: 'Казарма',
        price: 25,
        upkeep: 1,
        defense: 1,
        icon: 'building',
        production: [
          ModUnitType(
            id: 'my_dala_mod.scout',
            name: 'Барлаушы',
            price: 15,
            upkeep: 2,
            moveRange: 6,
            vision: 4,
            icon: 'scout',
          ),
        ],
      ).toJson(),
    ]
    ..remove('units');
  return GameMod.fromJson(raw);
}
