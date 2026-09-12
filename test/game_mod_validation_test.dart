import 'package:antiyoy_self/src/modding/game_mod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy land-only mod receives balanced naval defaults', () {
    final mod = GameMod.fromJson(_validLegacyMod());
    expect(mod.rules.port1Upkeep, 2);
    expect(mod.rules.port2Upkeep, 6);
    expect(mod.rules.boat1Upkeep, 3);
    expect(mod.rules.boat2Upkeep, 8);
    expect(mod.rules.boatMoveLimit, 2);
    expect(mod.rules.portLaunchRadius, 0);
    expect(mod.rules.navalSupplyUpkeep, 1);
    expect(mod.rules.artilleryAmmoCapacity, [0, 2, 4, 7]);
  });

  test('mod validation rejects unsafe economy and truncated tables', () {
    final negative = _validLegacyMod();
    (negative['rules'] as Map<String, dynamic>)['unitPricePerLevel'] = 0;
    expect(() => GameMod.fromJson(negative), throwsFormatException);

    final truncated = _validLegacyMod();
    (truncated['rules'] as Map<String, dynamic>)['unitUpkeep'] = [0, 2];
    expect(() => GameMod.fromJson(truncated), throwsFormatException);

    final badColour = _validLegacyMod()..['neutralColor'] = '#xyz';
    expect(() => GameMod.fromJson(badColour), throwsFormatException);

    final missingWater = _validLegacyMod()..remove('waterColor');
    expect(() => GameMod.fromJson(missingWater), throwsFormatException);
  });
}

Map<String, dynamic> _validLegacyMod() => {
  'id': 'legacy_test',
  'name': 'Legacy test',
  'title': 'Legacy test',
  'version': 1,
  'rules': <String, dynamic>{
    'unitMoveLimit': 4,
    'unitPricePerLevel': 10,
    'farmBasePrice': 12,
    'farmPriceGrowth': 2,
    'towerPrice': 15,
    'strongTowerPrice': 35,
    'farmIncome': 4,
    'treeCutReward': 3,
    'unitUpkeep': [0, 2, 6, 18, 36],
    'towerUpkeep': 1,
    'strongTowerUpkeep': 6,
    'initialMoney': 10,
    'pineSpreadChance': .2,
    'palmSpreadChance': .3,
  },
  'palette': ['#5AC568', '#E35D5D'],
  'neutralColor': '#B8B29C',
  'waterColor': '#2A6F9E',
};
