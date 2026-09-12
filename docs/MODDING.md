# Мод жасау

Ойын ережелері UI мен renderer-ден бөлінген. Алғашқы мод форматы — bundled JSON: ол жылдамдық, экономика, AI қолданатын бағалар және карта түстерін код өзгертпей ауыстырады.

## Жаңа мод қосу

1. `assets/mods/default_mod.json` файлын жаңа атпен көшіріңіз.
2. `id` мәнін бірегей етіңіз және `version` санын өзгерістер сайын өсіріңіз.
3. Баға, upkeep, tree chance және palette мәндерін өзгертіңіз.
4. `pubspec.yaml` бүкіл `assets/mods/` бумасын қосып қойған.
5. `GameMod.loadDefault()` орнына `GameMod.loadAsset('assets/mods/my_mod.json')` таңдаңыз.

## Manifest өрістері

```json
{
  "id": "my_mod",
  "name": "My Mod",
  "title": "Ойын атауы",
  "version": 1,
  "rules": {
    "unitMoveLimit": 4,
    "unitPricePerLevel": 10,
    "farmBasePrice": 12,
    "farmPriceGrowth": 2,
    "towerPrice": 15,
    "strongTowerPrice": 35,
    "farmIncome": 4,
    "treeCutReward": 3,
    "unitUpkeep": [0, 2, 6, 18, 36],
    "towerUpkeep": 1,
    "strongTowerUpkeep": 6,
    "initialMoney": 10,
    "pineSpreadChance": 0.2,
    "palmSpreadChance": 0.3
  },
  "palette": ["#5AC568", "#E35D5D", "#5D9BE3", "#E3C95D"],
  "neutralColor": "#B8B29C",
  "waterColor": "#7BC7D6"
}
```

`unitUpkeep[0]` қолданылмайды; 1–4 индекстері әскер деңгейіне сәйкес.
`unitUpkeep` кемінде 5, ал артиллерияның баға/upkeep/ammo кестелері кемінде
4 элементтен тұруы керек. Баға мен upkeep теріс болмауы, қозғалыс пен әскер
бағасы нөлден үлкен болуы, ықтималдықтар `0.0`–`1.0` аралығында болуы тиіс.
Manifest жүктелгенде бұл шарттар тексеріліп, жарамсыз мод `FormatException`
береді. `palette` кемінде екі түстен тұрады; ойыншылар саны одан көп болса,
түстер циклмен қайталанады.

Bundled fallback теңіз балансы default модпен бірдей: порт upkeep 2/6, кеме
upkeep 3/8, кеме жүрісі 2. Артиллерия оқ сыйымдылығы 2/4/7 және оқтау
автоматты; `artilleryShotCost` ескі manifest үйлесімділігі үшін ғана қалады.

## Карта редакторы

Негізгі мәзірдегі **Редактор** нақты `GameState`-ті өңдейді. Жер/су,
иелік түсі, қала-ағаш-қамал-порт-артиллерия нысандары және 1–4 деңгейлі
әскер өзгертіледі. Әр өзгеріс `antiyoy.editor.draft.v1` SharedPreferences
кілтінде автосақталады. Экспорт форматы:

```json
{
  "format": "antiyoy-self-map",
  "version": 1,
  "state": { "...": "GameState JSON" }
}
```

Импорт алдында формат, өлшем, hex саны және 2–15 ойыншы шегі тексеріледі.

## Келесі кеңейту нүктелері

- `GameMod` ішіне custom sprite asset path және локализация кестесін қосу;
- `GameEngine` action-дарын command/replay журналына жазу;
- сыртқы ZIP-модтарды қауіпсіз app documents бумасынан тікелей импорттау;
- scenario каталогын сыртқы JSON пакетіне кеңейту.

Save ішінде `schema` және `modId` сақталады. Save форматын өзгерткенде schema migration қосыңыз; ескі save-ті үнсіз бұзбаңыз.
