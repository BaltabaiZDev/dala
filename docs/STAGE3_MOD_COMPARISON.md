# 3-кезең — модты ресми Antiyoy логикасымен салыстыру

Күні: 2026-08-29  
Күйі: **read-only аудит аяқталды; ойын коды өзгертілген жоқ**

## 1. База, әдіс және қамту аймағы

Салыстыру екі ресми базаға сүйенді:

- Classic Antiyoy, commit `f22acaa0d08cc908b9d236bfabc28f93d059ad3e`;
- Antiyoy HD, commit `120bd3c60eef1eccdda583cd5d9d70b1c493e4f5`.

HD архитектуралық база ретінде, Classic нақты ереже, баланс және толық diplomacy UX эталоны ретінде қаралды. Ресми репозиторийлердегі файлдар өзгертілмеді.

Негізгі салыстырылған Flutter файлдары:

- `lib/src/game/game_ai.dart`;
- `lib/src/game/game_engine.dart`;
- `lib/src/game/models.dart`;
- `lib/src/game/map_generator.dart`;
- `lib/src/modding/game_mod.dart`;
- `lib/src/ui/diplomacy_sheet.dart`.

Тікелей тәуелділіктер де тексерілді:

- `lib/src/game/game_controller.dart`;
- `lib/src/ui/hex_board.dart`;
- `lib/src/ui/game_screen.dart`;
- `lib/src/ui/home_screen.dart`;
- `lib/src/persistence/save_repository.dart`;
- `lib/src/persistence/settings_repository.dart`;
- `assets/mods/default_mod.json`.

Бұл кезеңде тест, ойын іске қосу және screenshot жасалмады. Пайдаланушының тәртібі бойынша бір реттік runtime тексеру тек мақұлданған өзгерістен кейінгі 5-кезеңге сақталды.

Severity мағынасы:

- **Critical** — «Antiyoy логикасы сақталған» деуге кедергі келтіретін немесе матч нәтижесін қате өзгертетін алшақтық;
- **High** — AI/дипломатия/карта шешімін елеулі өзгертетін алшақтық;
- **Medium** — үйлесімділік, конфигурация немесе UX айырмасы;
- **Compatible** — ресми ережеге сәйкес немесе саналы әрі дұрыс интеграцияланған мод кеңейтімі.

## 2. Қысқа қорытынды

Модтың негізгі land economy және capture ережелері Classic/HD Default/Generic-пен жақсы сәйкеседі. Ең үлкен мәселе сандарда емес, архитектура мен decision flow-да:

1. `GameAi` — ресми AI порт емес; барлық tier мен Slay үшін бір global action scheduler қолданады.
2. AI жаңа unit/port/boat/artillery/fort алғаннан кейінгі upkeep-ті болжамайды, сондықтан өз экономикасын банкрот етуі мүмкін.
3. Әдепкі `normal` tier порт, кеме, артиллерия және теңіз қамалын мүлде қолданбайды.
4. Дипломатияда aggressor жазасының бағыты теріс, war басталғанда debt/subsidy тоқтамайды, ceasefire бірден бұзыла алады.
5. Incoming exchange шарттары адамға көрсетілмей, бір батырмамен орындалады.
6. Карта алгоритмі ресми multi-seed/plan-node алгоритм емес; кішкентай ішкі көлдер «теңіз» болып жасалғанымен navigable болмай қалады.
7. Slay-дағы maximum 5-hex province кепілдігі және ресми province-count/turn-order балансы сақталмаған.
8. Campaign/player-level экрандары ашылады, бірақ ішіндегі контент authored Antiyoy levels емес, seed арқылы жасалатын demo конфигурациялар.
9. Editor мүлде жоқ.

Демек, UI-де Antiyoy элементтері мен көптеген функциялар бар, бірақ «100% Antiyoy логикасы» деңгейіне әлі жетпеген.

## 3. Блоктайтын mismatch матрицасы

| ID | Severity | Official не күтеді | Модта не бар | Нәтиже |
|---|---|---|---|---|
| AI-01 | Critical | Classic difficulty classes және `AiMaster`; HD `AbstractAI`/factory/ruleset strategies | Бір `GameAi`, tier тек limit/gate/band өзгертеді | Ресми AI class hierarchy сақталмаған |
| AI-02 | Critical | Барлық ready unit қозғалады, кейін province spending/merge/cleanup жүреді | 6/10/16/24/34/48 аралас global action | Үлкен елдің кей unit/province-і жүрмейді; жаңа unit сол turn-де қайта жүре алады |
| AI-03 | Critical | Сатып алудан кейін бірнеше turn өмір сүру affordability формуласы | Cash minus arbitrary reserve | AI өзін банкрот етіп, барлық әскер/cargo-дан айырыла алады |
| AI-04 | High | Difficulty tactical quality-ді өзгертеді | Tier жаңа құралдарды unlock етеді | Default `normal` жаңа naval/artillery жүйесін пайдаланбайды |
| AI-05 | High | Difficulty strength gates және minimum sufficient force | Барлық tier 1–4 strength-ті қарайды | Easy bot қымбат unit-ті артық алуы мүмкін |
| AI-06 | High | Stateful movement/defense/propagation heuristics | Бір global score + deterministic noise | Барлық bot бір логиканың варианттары болып көрінеді |
| DIP-01 | Critical | Defender достары aggressor-мен қатынасты нашарлатады; айып aggressor-ға | Traitor fine defender ally-ға түседі | Кінәсіз ally 20 turn жазаланады |
| DIP-02 | Critical | War кезінде екі жақтың debt/dotation-ы өшеді | Debt/subsidy war ішінде төлене береді | Жауға соғыс кезінде ақша ағады |
| DIP-03 | Critical | Ұсыныстың ақша/жер/war/subsidy шарттары көрсетіледі | «Жаңа айырбас» деген generic жол және Accept | Пайдаланушы шартты көрмей жерін/соғысын мақұлдай алады |
| DIP-04 | High | Truce lock қайта соғыс ашуды уақытша тоқтатады | Cooldown жазылады, бірақ declaration оны тексермейді | Ceasefire келесі сәтте бұзылады |
| DIP-05 | High | Барлық eligible diplomatic winner ішінен жері ең көбі жеңеді | `firstWhere`, яғни ең төмен alive id | Player order жеңісті қате анықтайды |
| DIP-06 | High | New pieces appraisal-ға бейімделуі керек | Port/artillery `_ => 25` | Қымбат инфрақұрылым арзанға бағаланады |
| DIP-07 | High | Seller province-ін бөлу AI бағалауында тексеріледі | Тек сатылатын set connected болуы тексеріледі | AI өз аумағын стратегиялық бөліп сатуы мүмкін |
| MAP-01 | High | Classic multi-seed+roads немесе HD node/link/chunk pipeline | Бір орталық seed-тен connected growth | Карта әртүрлі көрінгенімен топологиялық variety ресми деңгейде емес |
| MAP-02 | High | Мод жасаған inland sea naval gameplay-ға қатысуы керек | 3–5 water hex көбіне 1–2 `WaterCell`; navigable үшін 3 cell керек | Көл көрінеді, бірақ кеме кіре алмайды |
| MAP-03 | High | Slay component maximum 5 hex-ке міндетті бөлінеді | Candidate болмаса oversized owner таңдалады, split post-pass жоқ | 6+ hex starting province пайда болуы мүмкін |
| CONTENT-01 | Critical | Authored campaign/user levels | 50 formula-based және 7 hardcoded-seed demo config | Экран жұмыс істейді, бірақ нақты level контент жоқ |
| EDITOR-01 | Critical | Full editor state, tools, import/export, scenes | Editor class/menu/route жоқ | Редактор функциясы орындалмаған |

## 4. AI және экономика

### AI-01 — ресми class hierarchy сақталмаған

Current:

- `game_ai.dart:12-26` — бір ғана `GameAi`;
- `game_ai.dart:19-24,270-344` — attacker/economist/guardian/admiral/engineer/opportunist деген алты personality;
- `models.dart:3-5` — `veryEasy/easy/normal/hard/veryHard/master`;
- Slay да сол бір `GameAi`-ды қолданады.

Official Classic:

- `core/src/yio/tro/antiyoy/ai/Difficulty.java:7-12` — `EASY/NORMAL/HARD/EXPERT/BALANCER/MASTER`;
- `AiFactory.java:44-115` — difficulty/ruleset бойынша бөлек implementation;
- `master/AiMaster.java` + `AttackManager` + `DefenseManager` + `AiData` — бөлек stateful subsystem;
- Slay Master әдейі Slay Expert implementation-ға түседі.

Official HD:

- `AbstractAI` → ruleset-specific concrete AI → `AiFactory`/`AiManager`;
- ең жоғарғы HD tier — Balancer; Classic Master-дің аты мен логикасы жай ғана action limit емес.

Салдар: current «алты bot мінезі» — official алты difficulty емес. Personality негізінен action order-ды өзгертеді; tactic/state model ортақ.

Қосымша: personality формуласы `seed * 3 mod 6` болғандықтан seed-тің тек parity-і әсер етеді; profile алты player сайын қайталанады (`game_ai.dart:19-24`). 15 түсте кемінде бірнеше bot міндетті түрде бір profile алады.

### AI-02 — turn scheduler legal outcome-ты өзгертеді

Current flow:

- `game_ai.dart:26-35,41-65` — бүкіл империяға fixed action limit;
- `game_ai.dart:263-360` — move, buy, farm, tower, navy, artillery, upgrade бір тізімде айналады;
- әр action тек бірінші successful operation-ды орындайды;
- `game_engine.dart:1104-1110` — бос friendly hex-ке алынған unit tree кеспесе ready;
- friendly ready merge нәтижесі ready болып қалады (`game_engine.dart:916-953`).

Official flow:

- HD `AiBalancerDefaultV1.java:55-60`: барлық ready unit қозғалады → әр province spending/merge → redundant cleanup → AFK movement;
- Classic `ArtificialIntelligence.java:30-139`: movement және spending/merge бөлек phase.

Нақты салдар:

- сатып алынған unit кейінгі local action-да тағы жүре алады;
- ready merge жасалған күшейген unit сол turn-де шабуылдай алады;
- navy/artillery action land movement лимитін жейді;
- global limit біткенде ready unit қозғалыссыз қалады;
- province money бойынша сұрыптау rich province-ке көп action береді;
- жеңіс action loop ортасында болғанда AI limit біткенше артық action жасай алады (`game_ai.dart:29-30,44-45`).

### AI-03 — upkeep-aware affordability жоқ

Current unit шешімі:

`maxAffordable = min(4, (money - reserve) ~/ unitPricePerLevel)`

Evidence: `game_ai.dart:404-447`.

Бұл тек current cash-ты тексереді. Жаңа unit consumption-ы мен 5-turn survival есептелмейді. Port/boat/cargo/artillery/upgrade/sea-fort үшін де post-purchase forecast жоқ (`game_ai.dart:524-673`). Admiral profile current balance guard-ты да айналып өтеді (`555-560`).

Official HD `AbstractAI.java:192-204` cash-пен бірге мына мағынадағы шартты қолданады:

`money + turnsToSurvive × (profit - newConsumption) >= 0`

`AiBalancerDefaultV1.java:244-260` strength сатып алғанда бес turn survival тексереді.

Current bankruptcy салдары өте қатты: `game_engine.dart:1873-1905` province теріс ақшаға түссе барлық land unit-ті өшіреді және сол province-ке тиесілі boat cargo-ны тазартады.

### AI-04 — tier қазіргі модта quality емес, feature unlock болып кеткен

| Tier | Current name | Action limit | Қолданатын жүйе |
|---:|---|---:|---|
| 0 | veryEasy | 6 | unit move/buy |
| 1 | easy | 10 | + farm |
| 2 | normal | 16 | + delayed tower |
| 3 | hard | 24 | + port/boat/cargo |
| 4 | veryHard | 34 | + strong tower, artillery, port2/boat2, upgrade |
| 5 | master | 48 | + sea fort, eager artillery upgrade |

Evidence: `game_ai.dart:26,270-360,450-673`.

Әдепкі config `normal` болғандықтан әдеттегі матчтағы боттар порт, кеме, артиллерия және теңіз қамалын қолданбайды. Бұл «боттар жаңа мод жүйелерін сауатты пайдалануы керек» талабына тікелей қайшы.

Барлық tier strength 1–4-ті қарайды (`game_ai.dart:413-437`). HD Default-та төмен difficulty strength-ті кезеңмен ашады; current veryEasy/easy bot та бірден knight алуы мүмкін.

### AI-05 — land/naval target policy ресми емес

Current global score (`game_ai.dart:363-402`) town/farm/port/artillery/tower-ға fixed bonus, defense penalty, enemy distance және deterministic noise береді.

Жоғалған ресми heuristics ішіне мыналар кіреді:

- palm/tree cleaning priority;
- Hard+ safe-vacate check;
- Expert defensive push;
- baron/knight tower preference;
- adjacency/city/farm allure;
- province-by-province AFK movement;
- redundant-unit cleanup;
- Classic Normal-дың ықтимал skip/random behavior-ы.

`_buyForBestAttack`-та defense target score-ға `+ defense * 7` болып қосылады (`game_ai.dart:424-431`), ал movement score-да сол defense шегеріледі (`:385`). Бір legal target әр strength үшін қайталанады және strength/cost penalty жоқ, сондықтан минимал жеткілікті unit орнына қымбат unit таңдалуы мүмкін.

Naval integration gaps:

- AI `boardUnit` шақырмайды; бар land army кемеге отыра алмайды, тек жаңа cargo сатып алынады (`game_ai.dart:594-600`, engine API `game_engine.dart:1607-1658`);
- first ready boat өңделеді, global best fleet action таңдалмайды (`game_ai.dart:605-630`);
- disembark score тек enemy/friendly деп сұрыптайды;
- `_waterTargetScore` барлық non-owned coast-ты тартымды санайды, `areEnemies` қолданбайды (`675-687`), сондықтан peace/allied coast-қа бос жүзе алады;
- Master artillery threat болмаса да upgrade-ты алдымен жасап көреді (`524-533`);
- sea fort future route/network/upkeep-ті есептемейді (`634-650`).

### AI-06 — экономикадағы сәйкес және өзгерген бөліктер

Land base сандары толық дерлік сәйкес:

| Rule | Current | Official Classic/HD |
|---|---:|---:|
| Unit move radius | 4 | 4 |
| Unit prices | 10/20/30/40 | 10/20/30/40 |
| Farm price | `12 + 2n` | `12 + 2n` |
| Empty/tree/farm income | 1/0/5 | 1/0/5 |
| Tree reward Generic/Slay | 3/0 | 3/0 |
| Unit upkeep Generic | 2/6/18/36 | 2/6/18/36 |
| Unit upkeep Slay | 2/6/18/54 | 2/6/18/54 |
| Tower price/upkeep | 15/1 | 15/1 |
| Strong tower price/upkeep | 35/6 | 35/6 |
| Farm/strong tower in Slay | disabled | disabled |

Evidence: current `assets/mods/default_mod.json:7-17`, `game_engine.dart:677-878`; Classic `gameplay/rules/GameRules.java:7-23`; HD `RulesetDefaultV1.java`.

Модтың intentional жаңа экономикасы:

- port prices 45/75, upkeep 2/6;
- boat prices 40/110, upkeep 3/8;
- sea fort price/upkeep 80/8;
- artillery incremental costs `[0,50,65,90]`, upkeep `[0,4,8,14]`;
- artillery ammo `[0,2,4,7]`;
- artillery shot price 0, reload automatic;
- cargo upkeep land upkeep-тің 1.5 есесі;
- port, boat, cargo, artillery, sea fort және naval transfer `economicBreakdown`-қа кіреді (`game_engine.dart:677-791`).

Порт пен артиллерияның land defense-і 1 (`game_engine.dart:854-862`), сондықтан оларды кемінде strength-2 unit жаулай алады. Бұл пайдаланушы сұраған қорғаныс талабына сәйкес.

Schema мәселелері:

- `game_mod.dart:78-116` list length/sign/range validation жасамайды; қысқа upkeep/ammo массиві runtime `RangeError` бере алады;
- `portLaunchRadius` және `navalSupplyUpkeep` жарияланған, бірақ engine-де consumer жоқ;
- legacy fallback пен default asset арасында айырма бар: port2 upkeep 5/6, boat upkeep 1/3 және 3/8, boat move 3/2 (`game_mod.dart:90-112`, `default_mod.json:18-36`). Ескі mod жаңа navy-ді басқа балансқа алады.

Economy timing ресми ойыннан өзгеше: current барлық province экономикасын player index wrap кезінде бірден өткізеді (`game_engine.dart:1752-1771`); official әр faction turn boundary-інде current faction экономикасын өткізеді. Бұл current test-пен бекітілген architecture, бірақ кейінгі player-лер player 0 жүрмей тұрып-ақ income/starvation алады.

## 5. Дипломатия

### DIP-01 — aggressor жазасының бағыты теріс

Current `game_engine.dart:326-358`:

- A ел B елге war ашады;
- B елінің ally-лары табылады;
- `_worsenRelationOnce(ally, A)` шақырылады.

`_worsenRelationOnce` alliance→peace кезінде `traitorTurns[first] = 20` қояды (`471-484`). Сондықтан айып aggressor A-ға емес, B-ның ally-ына түседі.

Classic `DiplomacyManager.java:1142-1185` `punishAggressor(aggressor, defender)` арқылы aggressor-дың defender friend-пен қатынасын нашарлатады. Жаза aggressor-ға тиесілі.

### DIP-02 — war debt пен subsidy-ді тоқтатпайды

Current war transition relation/cooldown/proposal-ды ғана өзгертеді (`game_engine.dart:326-358`). `game_engine.dart:1788-1821` enemy pair үшін де қарыз бен subsidy төлеуді жалғастырады.

Classic `DiplomacyManager.java:1164-1175,1341-1355` enemy болғанда debts-ті reset және dotations-ты remove етеді. Official `Debt` enemy debt-ті active деп санамайды.

### DIP-03 — ceasefire lock орындалмайды

Current ceasefire `game_engine.dart:568-571` relation=peace және cooldown=9 қояды. Бірақ peace→war тармағы (`326-358`) cooldown-ды тексермейді. Cooldown тек war→peace improvement-ке қолданылады (`304-324`).

Салдар: «9 turn truce» UI/state-та бар, бірақ тарап оны бірден бұза алады.

Quick peace offer төлемі `max(15, opponentMoney / 4)` (`game_ai.dart:113-123`, `diplomacy_sheet.dart:347-355`). Classic negotiated reparations/payment екі жақтың қаржысы, border және profit шарттарына тәуелді.

### DIP-04 — diplomatic winner tie-break

Current `game_engine.dart:2543-2567` барлық alive player-ге ally болған бірінші player-ді алады.

Classic `DiplomacyManager.java:219-255` барлық eligible кандидат ішінен land count ең үлкенін таңдайды.

Барлық ел бір coalition болса current ең кіші player id-ді жеңімпаз етеді; бұл match result қатесі.

### DIP-05 — relation және lock model толық емес

Current `models.dart:7` — `war/peace/alliance`. Бұл Classic `enemy/neutral/friend` үш күйін атау жағынан бейімдей алады, бірақ HD `war/neutral/friend/alliance` төрт күйін және relation lock-тарын көрсете алмайды.

Жоқ мүмкіндіктер:

- global/editor diplomatic relation lock;
- per-relation temporary/permanent lock;
- friend пен alliance-ты бөлек көрсету;
- authored level relation restrictions.

Бұл editor жоқтығымен де байланысты.

### DIP-06 — appraisal mod объектілеріне бейімделмеген

`game_engine.dart:617-629` Classic объектілеріне fixed price береді, ал қалғанының бәрін 25 деп бағалайды.

Сондықтан:

- port1/port2 = 25, actual spend 45 және cumulative 120;
- artillery1/2/3 = 25, actual cumulative spend 50/115/205;
- AI offer acceptance осы төмен бағаларға сүйенеді (`game_ai.dart:189-220`).

Land trade validation (`game_engine.dart:501-516,631-643`) сатылатын set connected болуын талап етеді, бірақ сатудан кейін seller province бөлініп қалатынын тексермейді. Classic AI `doesHexListSplitProvince` арқылы мұндай сатудан бас тартады. Сонымен бірге current legitimate multi-province bundle-ды артық шектеуі мүмкін.

### DIP-07 — AI diplomacy ресми алгоритм емес

Current `game_ai.dart:67-179` барлық tier-ге бір algorithm қолданады. Difficulty тек war roll-ды 1/9-дан Hard+ үшін 1/3-ке өзгертеді.

Official HD Normal:

- lap 4-ке дейін war ашпайды;
- adjacent eligible weak target іздейді;
- екінші adjacent war-дан қашады;
- alliance protection және relation locks-ты сыйлайды;
- letter condition-дарын `Appraiser` арқылы бағалайды.

Current:

- lap 4-тен бұрын war аша алады;
- disconnected neutral target таңдай алады;
- басқа war жүріп жатса да жаңа war аша алады;
- fixed `received * 4 >= given * 3` acceptance қолданады (`189-220`);
- land buy/sell proposal, gift, attack proposition, free-text human message секілді Classic diplomatic AI behavior-лары жоқ;
- deterministic roll advancing RNG қолданбайды (`181-187`).

Proposal expiry де өзгеше: current 3 global round өткен соң өшіреді (`game_engine.dart:1868-1870`); Classic/HD unanswered recipient letter-ді recipient turn end-де тазалайды.

### DIP-08 — subsidy self-referential underpayment

`economicBreakdown` active subsidy amount-ты payer balance-тен алдын ала шегереді (`game_engine.dart:738-747`). Payment кезінде affordability ретінде сол subsidy already subtracted `playerEconomicBreakdown(...).total` қайта алынады (`1801-1818`).

Мысал: base balance 10, promised subsidy 8. Reported balance 2 болады да, payer 8 емес, 2 ғана төлейді. Subsidy 10 немесе көп болса, 0 төлейді.

Classic dotation limit-і state income-ға сүйенеді және осы contract-ті affordability-ден алдын ала екі рет шегермейді.

### DIP-09 — isolated neutral/friendly hex capture

Current `_canAttack` owned peace/friendly hex-тің бәрін relation арқылы қорғайды (`game_engine.dart:870-877`). Classic/HD province-ке кірмейтін isolated hex үшін diplomacy protection bypass жасайды. Сондықтан current isolated tile official-де жоқ immunity алады.

### DIP-10 — UI-де нақты қызметке сәйкес келмейтін батырмалар бар

Current `diplomacy_sheet.dart:110-169`:

- MAIL және EXCHANGE екеуі де `_openExchange` ашады;
- INFO selected-country details орнына global relations matrix ашады;
- action availability official relation/lock filter-лерінің толық шарттарын қолданбайды.

Classic:

- MAIL — custom text/message;
- INFO — таңдалған елдің ақпараты;
- EXCHANGE — generic trade;
- transfer money, buy/sell land және attack-prefilled бөлек actions бар.

Incoming offer safety қатесі:

- `diplomacy_sheet.dart:172-180,308-344` тек sender-дің `firstOrNull` proposal-ын «Жаңа айырбас ұсынысы» деп көрсетеді;
- нақты money/lands/third-party war/subsidy terms көрсетілмейді;
- Accept бірден `resolveDiplomacyProposal` шақырады;
- бір sender-дің қалған ұсыныстары UI-де көрінбейді.

Бұл жай дизайн айырмасы емес — informed consent қатесі.

Экран technically үш internal page-ке ауысады (`countries/exchange/relations`, `diplomacy_sheet.dart:37-76,572`), бірақ бәрі бір 64% modal bottom sheet ішінде. Official бөлек scene/panel flow қолданады. Пайдаланушы сұраған «әр action жеке бетке өтсін» UX толық орындалмаған.

## 6. Карта генерациясы және бастапқы провинциялар

### MAP-01 — алгоритм ресми generator емес

Current `map_generator.dart:174-212`:

- fixed dimensions/land targets;
- 5 world-arena shape;
- 8 coastline style;
- орталық band-тен бір seed;
- бір connected frontier growth;
- 0/3/4/5-hex inland lake;
- кейін player/province spawn.

Classic `MapGenerator.java`:

- map size бойынша 2/4/20/35 island seed;
- әр seed-ті бөлек өсіреді;
- closest islands-ты road арқылы байланыстырады;
- bounds/hole/tree/province/balance post-pass жасайды.

HD:

- plan nodes/links;
- link repair және center;
- chunks→land;
- province spawn/build/balance;
- optional pieces.

Current algorithm өздігінен жарамды procedural generator, бірақ ресми Classic не HD алгоритмінің порт/адаптері емес. Бір connected core және cosmetic style айырмасы картаға әртүрлі silhouette бергенімен, strategic chokepoint/region variety азаяды.

### MAP-02 — inland lake navigable емес

Current:

- inland water 3–5 hex (`map_generator.dart:185-190,773-814`);
- inactive hex-тер 3–5 hex `WaterCell`-дерге pack болады (`219-321`);
- water body navigable болу үшін кемінде **3 WaterCell** керек (`351-369`).

3–5 raw water hex әдетте 1–2 WaterCell ғана береді. Сондықтан comment «inland sea» десе де, lake `navigable=false` болып қалады. Port/boat build `_hasNavigableSeaCoast` талап еткендіктен ішкі көл naval route бола алмайды.

### MAP-03 — Slay max-5 кепілдігі жоқ

Current owner таңдағанда component ≤5 болуын іздейді, бірақ candidate табылмаса `candidates.first` алады (`map_generator.dart:901-905`). Одан кейін oversized component-ті бөліп шығатын post-pass жоқ (`910-945`).

Classic `cutProvincesToSmallSizes()` oversized component қалғанша қайталанады. Сондықтан Classic maximum-ды guarantee етеді, current тек best effort.

### MAP-04 — Slay fairness өлшемі басқа

Current `map_generator.dart:843-908` барлық player-ге land tile quota-ны теңестіреді.

Classic:

- starting province санын айырмасы ≤1 болғанша теңестіреді;
- oversized province-ті бөледі;
- turn-order advantage/disadvantage balance қолданады.

Tile quota province count, capital count, early income және first-turn advantage-ты өздігінен теңестірмейді. Current starts көлем жағынан ұқсас көрінуі мүмкін, бірақ ресми fairness сақталмаған.

### MAP-05 — «Әдепкі → 1 → 2 → 3» UI дұрыс, semantics саналы түрде өзгерген

UI `home_screen.dart:451-463` және settings clamp `settings_repository.dart:129-142` value 0..3 қолданады. Classic slider да `SceneMoreSkirmishOptions.java:90-99` ішінде 0..3.

Айырма:

- Classic `MapGeneratorGeneric.java:298-310`: 0/default → map size бойынша әр faction-ға fixed 1/2/3/4;
- current `map_generator.dart:981-1012`: 0/default → әр player-ге random 1..maximum (maximum 3), мүмкін болса әдейі asymmetric.

Пайдаланушы дәл variable default сұраған, сондықтан бұл **intentional adaptation**, bug емес. Бірақ current comment «Antiyoy сияқты asymmetric» дегені ресми Classic-ке дәл емес.

Config consistency gap:

- `AppSettings.startingProvinceCount` default 0;
- UI жаңа матчқа 0-ді береді;
- бірақ `GameConfig` constructor және missing-JSON fallback 1 (`models.dart:128-180`).

Сондықтан ескі save/config field-і жоқ болса «Әдепкі» емес, explicit 1 болып жүктеледі.

## 7. Fog, seed, autosave және performance

### Compatible fog behavior

Current fog implementation пайдаланушы хабарлаған негізгі leak-терді код деңгейінде жапқан:

- original vision radii empty/unit/tower/town/strong = 1/2/3/4/5 (`game_controller.dart:145-191`), Classic-пен сәйкес;
- port/artillery radius модқа қосылған;
- boat coast-ты ашады, сондықтан fog кезінде әскерді жағаға түсіруге болады (`171-188`);
- hidden land gray (`hex_board.dart:798-808`);
- enemy object/unit/boat/fort visible set-тен тыс салынбайды;
- hidden edge enemy border-ды leak етпейді (`hex_board.dart:1081-1091`);
- province alert тек current/visible owner үшін (`1248-1277`);
- income graph hidden player color-ын gray етеді (`game_screen.dart:267-289,629-690`).

AI full authoritative state-ты оқиды және fog view-ға тәуелді емес. Бұл official Classic/HD omniscient AI behavior-ына сәйкес.

Current alliance Classic friend-тің fog sharing рөлін атқарады. HD-дегі friend және alliance бөлек модельденбегені DIP-05-те көрсетілді.

### Seed

Жаңа skirmish әр жолы `math.Random.secure().nextInt(...)` қолданады (`home_screen.dart:218-235`). Manual seed input жоқ. Campaign/player-level authored reproducibility үшін fixed seed қолданады — бұл дұрыс ерекшелік.

### Autosave және AI pause

`game_controller.dart:1053-1150`:

- fog match-та AI басталғанда human-visible state clone жасайды;
- AI identity/action animation-ы көрсетілмейді, generic «Қарсыластар жүріп жатыр» көрсетіледі;
- барлық AI аяқталған соң human turn state қайта ашылады;
- autosave human+AI толық cycle соңында бір рет жасалады;
- async AI шамамен 6 ms сайын event loop-қа yield береді (`game_ai.dart:41-65`).

Бұл бұрынғы «әр AI action сайын save/қатып қалу» мәселесін архитектура бойынша түзетеді. Runtime smoothness benchmark 5-кезеңге дейін жасалмады.

## 8. Campaign, player levels және editor

### Campaign/player levels — батырма ашылады, контент demo

`home_screen.dart:159-169`:

- «Ойыншы деңгейлері» `_CampaignScreen` ашады;
- «Кампания» `_LevelsScreen` ашады.

Private class атаулары кері сияқты болғанымен visible destination мағынасы дұрыс: player levels list, campaign grid.

Алайда контент ресми емес:

- Campaign 50 ұяшық береді, бірақ әр деңгей нақты authored map емес; `_levelConfig` map size/player count/seed/difficulty-ді формуламен жасайды (`home_screen.dart:484-573`);
- Player levels тек 7 hardcoded title/author/seed entry; басқанда сол seed-пен random map config жасалады (`591-725`);
- official level map geometry, units, provinces, messages, win conditions, scripted state және import data жоқ.

Сондықтан бұл батырмалар «ештеңе істемейді» емес, бірақ мазмұны prototype/demo.

### Editor жоқ

Current `lib/src` ішінде editor manager, state, tools, touch mode, import/export немесе editor screen жоқ. Main menu-де «Редактор» entry жоқ; `test/menu_test.dart:39` оның жоқтығын әдейі тексереді.

Official inventory:

- Classic editor category — 66 Java file;
- HD editor category — 31 Java file;
- map/entity/province editing, relation editing, parameters, import/export, launch/open-in-editor flows бар.

Editor-ды «қосу» жай ғана menu button емес; current architecture-де editor domain түгел жоқ.

## 9. Дұрыс сақталған және саналы өзгертілген бөліктер

Мыналар bug емес:

- land economy base constants ресми мәндерге сәйкес;
- unit movement/defense/capture, Generic vs Slay capture айырмасы engine-де орталықтанған;
- farm adjacency және Slay farm/strong disable дұрыс;
- artillery ammo 2/4/7, automatic reload, per-shot ақша жоқ;
- port/artillery defense 1, strength-2 capture талабы орындалады;
- new port/boat/artillery/sea-fort upkeep breakdown-қа кіреді;
- 15 player color — official 11 шегінен саналы кеңейту;
- starting province 0/default variable allocation — пайдаланушы сұраған саналы өзгеріс;
- fog opponent state-ты render-ден жасырады, AI authoritative state-ты сақтайды;
- random skirmish seed автоматты;
- settings/save diplomacy/naval state SharedPreferences арқылы сақталады;
- sync/async AI бір strategy path қолданады және turn-ді бір рет аяқтайды.

## 10. 4-кезеңге өту gate-і

Бұл құжат тек mismatch есебі. Ешбір fix немесе diff қолданылған жоқ.

4-кезеңде алдымен мына ретпен before/after ұсыныс дайындау керек:

1. Informed-consent diplomacy UI, aggressor fine, war cleanup, truce lock, winner tie-break;
2. official phase-based AI scheduler және upkeep-aware affordability;
3. difficulty hierarchy/adapters және naval/artillery strategy integration;
4. diplomacy appraisal-ға port/artillery/naval economy қосу;
5. Slay max-5/fairness және map pipeline;
6. authored campaign/player-level data model;
7. editor architecture.

Пайдаланушы бекітпейінше осы тармақтардың ешқайсысы source code-қа енгізілмеуі тиіс.

## 11. Өзгермеген protected логика

Stage 3 барысында мыналар өзгертілмеді:

- Flutter: `map_generator.dart`, `game_ai.dart`, `game_engine.dart`, `models.dart`, `game_mod.dart`, `diplomacy_sheet.dart`;
- Classic: `MapGenerator.java`, `MapGeneratorGeneric.java`, барлық `ai/`, `ai/master/`, `gameplay/diplomacy/`;
- HD: барлық `core_model/generators/`, `core_model/ai/` және diplomacy core/event classes.

Official clone working trees аудит соңында clean және exact commit-те қалды. Workspace root-та `.git` жоқ болғандықтан Flutter tree үшін Git diff шығару мүмкін емес; protected Dart файлдары Stage 3 басы/соңында SHA-256 арқылы салыстырылады.
