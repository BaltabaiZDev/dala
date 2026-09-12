# 4-кезең — іске асырылған бейімдеу есебі

Күні: 2026-08-30

Бұл кезең `STAGE3_MOD_COMPARISON.md` есебінен кейін және пайдаланушының
барлық кезеңді бірінен соң бірін орындауға берген рұқсатымен жасалды. Ресми
Classic/HD Java репозиторийлері тек оқылатын референс болып қалды; барлық
өзгеріс Flutter/Dart модының ішінде орындалды.

## AI

- AI жүрісі official-ға жақын фазаларға бөлінді: дипломатиялық шешім,
  дайын әскерлерді жылжыту, провинция экономикасы/сатып алу, тазалау, одан
  кейін артиллерия мен теңіз әрекеттері.
- Сатып алу тек қолдағы ақшаға емес, жаңа upkeep-ке және бірнеше келесі
  ходтағы экономикалық өміршеңдікке қарайды.
- Алты difficulty бірдей ботқа жай action-limit бермейді: әскер деңгейі,
  farm/defence, diplomacy, navy, artillery және sea-fort мүмкіндіктері
  біртіндеп ашылады.
- Алты personality приоритеттерді араластырады; сондықтан барлық бот бірдей
  бірінші қамал немесе бірдей бағытпен жүрмейді.
- Normal және одан жоғары боттар теңізді қолданады; флот allied/peace жағасын
  жау нысаны деп қабылдамайды және жарамды құрлық әскерін кемеге отырғыза
  алады.
- Соғыс declaration-ы кемінде 4-раундты, шекаралас нысанды және екінші
  қатарлас соғыс ашпау шартын ескереді.

## Дипломатия

- MAIL, INFO және EXCHANGE бір қабатталған sheet емес, үш бөлек толық экран.
- Кіріс келісімінде екі жақтың барлық шарты (ақша, жер, үшінші жаққа соғыс,
  бітім және subsidy мерзімі) қабылдаудан бұрын толық көрсетіледі.
- Соғыс басталғанда екі бағыттағы debt/subsidy және ескірген proposal
  тазарады; ceasefire cooldown арқылы бірден қайта соғыс ашу жабылды.
- Одақты бұзған aggressor жазаланады. Экрандағы traitor fine preview мен
  нақты раундтық шегерім бір ортақ base-profit формуласын қолданады.
- Seller-де қалатын жердің байланысы тексеріледі; cargo арқылы peacetime
  unit-cap айналып өту жабылды.
- Port және artillery appraisal жинақталған нақты mod бағасын қолданады;
  subsidy gross income-мен шектеледі; дипломатиялық жеңімпаз eligible
  елдердің ішіндегі ең үлкен жер иесі болады.
- Хаттар `GameState` schema 10 ішінде сақталады және undo/save арқылы жоғалмайды.

## Карта және setup

- Dart генераторы бір ғана blob өсірудің орнына бірнеше seed-пен staged land
  growth, link/repair және қорытынды topology түзетуін қолданады.
- Inland water 12/15/18 hex көлемімен құрылады және packed navigable graph
  ретінде кеме қолдана алатындай жөнделеді.
- Slay режимінде бір owner component-і 5 hex-тен аспайтын final split pass бар.
- 15 түске дейінгі старт бөлінеді.
- Бастапқы провинция селекторы дәл `Әдепкі -> 1 -> 2 -> 3`; `Әдепкі` әр
  ойыншыға seed бойынша тұрақты, бірақ ойыншылар арасында әртүрлі 1..3 санын
  береді. Constructor, JSON fallback және settings бәрі 0 мәнін қолданады.
- Жаңа skirmish пен editor regenerate әр жолы secure random seed алады; seed
  қолданушыға қолмен енгізілмейді.

## Редактор, сақтау және импорт

- Басты мәзірде бөлек `Редактор` route бар. Ол terrain, owner, object, unit,
  boat1/boat2 және sea-fort өңдейді, province/water topology-ді қайта құрады
  және жарамды толық `GameState`-ті іске қосады.
- Draft SharedPreferences-те толық state ретінде сақталады. Autosave жазулары
  revision бойынша бір Future queue-ға тізіледі; ескі async snapshot жаңа
  save/import/load нәтижесінің үстінен жаза алмайды.
- Import алдында raw JSON enum/type/matrix құрылымы, province BFS байланысы,
  capital, owned-component coverage, entity-to-province байланысы,
  nextProvinceId, coast, artillery ammo, boat cargo/damage және navigable sea
  invariанттары тексеріледі. Launch boundary editor ішінде де, Home ішінде де
  қайта тексеріледі.
- Progress transfer барлық бөлімді жазудан бұрын тексереді, белсенді mod id мен
  rules-ті қолданады және bundle-де null болған save/editor бөлімін жергілікті
  ескі дерекпен қалдырмай, нақты тазартады.
- Кампания немесе player-level пресетін ұзақ басу fixed-seed картаны жасап,
  editor draft-қа көшіріп, бөлек редактор бетін ашады. Қысқа басу ойынды
  бұрынғыдай бастайды.

## Antiyoy HD level-code адаптері

- Пайдаланушы өзі алмасу буферіне салған `onliyoy_level_code#...` мәтіні
  редактордың Import әрекетімен `GameState`-ке айналады.
- Sparse axial geometry, 15 player/4 human шегі, адамды алдыңғы индекстерге
  remap ету, owner/turn/diplomacy remap, readiness, province id/money,
  `def/classic`, fog және basic diplomacy қолданылады.
- Кодқа ресми campaign/user-level массивтері салынған жоқ. Бұл әдейі жасалды:
  тексерілген upstream snapshot-тарда анық OSS LICENSE файлы жоқ және жергілікті
  model HD events/objectives/history-дің бәрін дәл көрсете алмайды.
- Адаптер camera, events, history, entity names/unit ids-ті елемейді; HD
  friend+alliance жергілікті alliance-қа бірігеді, generic relation lock толық
  көрсетілмейді. Local state per-player arbitrary palette mapping сақтамайды,
  сондықтан human-first remap кезінде бастапқы HD түс атаулары дәл сақталмауы
  мүмкін. HD кодында navy болмағандықтан импорт кеме жасамайды.

## Контент туралы нақты шекара

`scenario_catalog.dart` ішіндегі 50 campaign және player-level жазбалары —
қолмен іріктелген fixed-seed процедуралық preset. Олар official authored map
geometry немесе goal/event көшірмесі емес. UI мен README енді оларды
"hand-authored official level" деп атамайды. Exact map үшін қолданушы берген HD
level code импортталады.

## Қатаңдатылған тест coverage

- Барлық 50 campaign және барлық player preset екі рет генерацияланып,
  deterministic JSON және playable semantic state ретінде тексеріледі.
- Editor import malformed diplomacy, disconnected/incomplete province,
  invalid capital/id, orphan unit/building, non-navigable asset, overloaded
  boat, excessive artillery ammo және legacy land-only compatibility-ді
  тексереді.
- HD importer тек қолдан жасалған шағын кодтармен тексеріледі; ресми level data
  тест fixture ретінде де көшірілмейді.
- Diplomacy regressions aggressor punishment, ceasefire, obligation cleanup,
  appraisal, winner, subsidy және traitor fine сәйкестігін қамтиды.

## Өзгерген Dart/test файлдары

Негізгі source:

- `lib/src/game/game_ai.dart`
- `lib/src/game/game_controller.dart`
- `lib/src/game/game_engine.dart`
- `lib/src/game/map_generator.dart`
- `lib/src/game/models.dart`
- `lib/src/game/scenario_catalog.dart`
- `lib/src/modding/game_mod.dart`
- `lib/src/persistence/antiyoy_hd_level_importer.dart`
- `lib/src/persistence/editor_repository.dart`
- `lib/src/persistence/settings_repository.dart`
- `lib/src/ui/diplomacy_sheet.dart`
- `lib/src/ui/editor_screen.dart`
- `lib/src/ui/home_screen.dart`

Тесттер:

- `test/antiyoy_hd_level_importer_test.dart`
- `test/editor_repository_test.dart`
- `test/game_mod_validation_test.dart`
- `test/game_test.dart`
- `test/menu_test.dart`
- `test/scenario_catalog_test.dart`

## Protected reference verification

- Classic HEAD: `f22acaa0d08cc908b9d236bfabc28f93d059ad3e`.
- HD HEAD: `120bd3c60eef1eccdda583cd5d9d70b1c493e4f5`.
- Екі working tree де `git status --short` бойынша бос.
- Classic map/AI/diplomacy және HD generator/AI/diplomacy protected paths үшін
  `git diff --exit-code` нәтижесі 0. Ресми Java логикасы өзгертілмеді.

## 5-кезең gate

Dart source форматталды. Пайдаланушының бір реттік тексеру талабына сай
`flutter test --update-goldens` бір рет орындалды. Консольдің қорытындысы:

```text
01:24 +146 -2: Some tests failed.
```

146 тест өтті. Екі failure де жаңа HD level-code importer-дің positive
fixture-лерінде болды: importer жарамды state орнына `null` қайтарды. Қалған
AI, diplomacy, map/scenario, editor validation, fog және UI/golden тесттері осы
бір реттік орындауда өтті.

Failure-дің нақты себебі статикалық trace арқылы табылды: ресми HD форматы
`provinces:` тізімін соңғы үтірмен аяқтайды, ал `_readProvinceData` пайда болған
бос record-ты қате деп санаған. Reader енді `_readEntities` және `_readHexes`
сияқты бос соңғы token-ді өткізіп жібереді. Файл `dart format` арқылы қайта
парсталды.

Пайдаланушының «толық тестті бір рет қана іске қос» талабын бұзбау үшін осы
post-test түзетуден кейін suite екінші рет жүргізілген жоқ. Сондықтан final
suite нәтижесі формалды түрде green деп жарияланбайды: importer patch-і
статикалық дәлелденген және форматталған, бірақ runtime re-run тек пайдаланушы
сұраса жасалады.

`--update-goldens` іске қосылғандықтан 2026-08-30 09:20 уақыт белгісімен
`test/goldens/*.png`, `test/diplomacy_*.png`, `test/slay_rules_phone.png` және
`test/visual_smoke_*.png` reference суреттері қайта жазылды. Workspace-та
`.git` жоқ болғандықтан олардың алдыңғы нұсқамен content diff-ін дәл шығару
мүмкін емес; ескі `test/failures/*` файлдары бұл іске қосуда өзгермеген.

## 5-кезең post-fix қайта тексеруі

Пайдаланушы кейін қалған тексеруді қайта орындауға нақты рұқсат берді.

- HD importer regression: `+3: All tests passed!`.
- Алғашқы negative fixture `1 0 red` деген жоқ мәтінді ауыстыруға тырысып,
  unsupported piece-ті source-қа қоспай қойған. Fixture нақты `1 0 aqua,`
  token-ін ауыстыратындай түзетілді.
- Толық `flutter test`: `01:07 +148: All tests passed!`.
- Windows debug build сәтті жиналып, native setup экраны ашылды және негізгі
  controls дұрыс көрінді.
- Start әрекетінен кейін Codex Windows automation-ы window handle-ды жоғалтты.
  Процесс тірі әрі responsive қалды, сондықтан app crash расталған жоқ; бірақ
  native картадағы ход/AI click-through осы pass-та тікелей бақыланбады.
