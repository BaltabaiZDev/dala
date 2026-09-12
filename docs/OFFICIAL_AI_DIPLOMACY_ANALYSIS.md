# Official Antiyoy AI, diplomacy, map generation, and editor analysis

This is the read-only Stage 2 baseline. No official or Flutter gameplay source was changed while producing it.

- Antiyoy Classic: `f22acaa0d08cc908b9d236bfabc28f93d059ad3e`
- Antiyoy HD: `120bd3c60eef1eccdda583cd5d9d70b1c493e4f5`

Search terms were `AI`, `Enemy`, `Computer`, `Bot`, `Diplomacy`, `Alliance`, and `War`, applied to Java filenames/classes and source content. Name-only matches such as campaign/user-level titles containing “War” are content, not AI implementations; the semantic implementation files are analyzed below.

## 1. Which source should be the baseline?

Use **HD for structure** and **Classic for original behavior/content/UI reference**.

- Classic centralizes a large amount of mutable state in `GameController`, `FieldManager`, `AiMaster`, and `DiplomacyManager`.
- HD separates authoritative `core_model`, events/history, `viewable_model`, renders, rulesets, generators, import/loading, and editor code.
- HD is not a drop-in runnable app: its snapshot has no Gradle/platform wrapper and contains online/network code that an offline Flutter port should not copy.
- The two codebases are rewrites, not interchangeable versions: only 125 Java basenames overlap case-insensitively and no Java file is byte-identical.

## 2. Classic AI

### Runtime and factory

- `ai/AbstractAi.java`: minimal contract, `perform()`.
- `ai/Difficulty.java`: easy, normal, hard, expert, balancer, master IDs.
- `ai/AiFactory.java`: creates one AI per faction and dispatches by difficulty and Generic/Slay rules. Generic master uses `AiMaster`; Slay master deliberately falls back to `AiExpertSlayRules`.
- `gameplay/GameController.java`: once a non-human turn is ready, exactly one synchronous `perform()` runs, caches update, then the turn ends. Neutral faction 7 is skipped. `playersNumber == 0` is official AI-only mode.

Turn dependencies:

1. Units become ready only when owned by the current faction and adjacent to friendly land.
2. Trees expand at the start of faction 0's round.
3. Graves transform, province profit is added, starvation is checked, diplomacy runs, then tactical AI performs.
4. An isolated unit is not activated.

### Shared classic tactical AI

`ai/ArtificialIntelligence.java` provides the common movement, spending, merge, tree-cleanup, and target routines.

- Movement range is 4. Propagation passes through friendly cells and may enter only the first legally attackable foreign cell.
- A unit's legal move zone is filtered by its strength and diplomacy/ruleset attack permission.
- Default action priority is palm/tree cleanup, legal attack, other tree, then defensive/inward relocation.
- Merge requires combined strength `<= 4` and province affordability.
- Default spending builds towers before units.
- With diplomacy and at least one human, new-unit construction is capped faction-wide at `min(max(3, provinceSize / 4), 10)`. It is not actually a per-province cap.

`ai/ArtificialIntelligenceGeneric.java` adds farms and strong-economy behavior:

- spending order: tower → farm → units;
- stops farm expansion when next farm cost exceeds 80;
- farm is allowed immediately when cash is more than twice its price; otherwise tower need has priority;
- farm tile must be empty and supported by a town/farm.

### Difficulty classes

- `AiEasy`: tree first, otherwise random movement; buys units inside its own province; never builds farms or towers; merges only 1+1 and only with 25% chance.
- `AiNormalGenericRules` / `AiNormalSlayRules`: each ready unit has a 50% skip chance; buys internally, clears palms, and can kick-start one attack.
- `AiHardGenericRules`: full attack logic; chooses strong tower if affordable, otherwise normal tower.
- `AiHardSlayRules`: full movement/attack logic, but Slay's normal-tower-only spending.
- `AiExpertGenericRules`: refuses attacks that leave more than 3 exposed perimeter cells, mass-marches idle units, repeatedly buys attackers, and may upgrade towers if a neighboring enemy province is larger than half its own and `profit - strongTowerTax >= 5`.
- `AiExpertSlayRules`: same safe-movement concept, without farm/strong-tower logic; towers only on the front line.
- `AiBalancerGenericRules` / `AiBalancerSlayRules`: expert behavior plus leader-biased targeting, reserve economics (`canAiAffordUnit(strength, 5)`), tree-before-attack, defense-gain positioning, and stricter front-line construction.
- `AiRestoredBalancerGeneric` / `AiRestoredBalancerSlay`: dormant historical flattened copies; factory/runtime do not use them.

Known fidelity defect in both Classic balancers: the adjacent-unit comparator checks that the same cell contains a unit **and** a tower. That state is impossible, so this component is always zero and the fallback sorting dominates.

### Classic Master AI

Files:

- `ai/master/AiMaster.java`
- `AttackManager.java`
- `DefenseManager.java`
- `AiData.java`
- `PropagationCaster.java`
- `MasterAction.java`, `MaType.java`
- `PossibleSpending.java`, `PsType.java`
- `DmGroup.java`

`AiData` stores per-hex topology and tactical data: loneliness, attractiveness, front/second lines, importance, solid defense, army presence, attack flags, target tastiness, vicinity, paths, reachable/ownership flags, potential attackers, and dependent units.

For every province, `AiMaster`:

1. resets tactical data;
2. reads money, income, profit, and ownership;
3. calculates perimeter, importance, defense, and neutral vicinity;
4. merges peasants;
5. initializes attack and defense managers;
6. alternates actions and purchases for at most 7 iterations;
7. captures cheap opportunities;
8. moves idle units toward the perimeter;
9. covers exposed strong-unit routes with towers;
10. repositions remaining units defensively.

Action “thirst” conditions:

- cut tree: `0.5 + 2 * palms + pines`;
- peaceful expansion: zero if adjacent neutral land `< 3`, otherwise `0.5 + 0.3 * adjacentNeutral`;
- defense: zero when danger `<= 0.45`, otherwise `1.5 + 5 * danger`;
- defend is invalid for provinces of size `<= 6`;
- only valid actions with thirst `>= 1` execute.

Spending conditions:

- defense thirst `>= 5` suppresses other spending;
- normal tower thirst is based on weak important first/second-line cells;
- strong tower requires Generic rules, profit `>= 6`, an existing normal tower, and cash `>= 45`;
- farm is disabled in Slay and when profit `> 120`; desired farms are tied to province size and target profit;
- ordinary unit-spending thirst is implemented only for strength 1; stronger units are acquired by attack/defense reinforcement paths;
- tax tolerance changes at cash thresholds 200 and 500.

`AttackManager`:

- target province taste: `((1 - averageDefense / 4) + farmPercentage + 2 * averageAttractiveness) / 4`;
- target tile taste: `(attractiveness + 3 * nearbyArmyPresence + (1 - defense / 4) + importance + 2 * vicinity + towerBonus) / 9`;
- first protects vulnerable tiles on the route to the capital;
- then attacks with an existing unit, merge, reinforcement, or direct purchase in that order;
- required strength is `defense + 1`;
- prefers very small enemy provinces (`< ownSize / 6`) before general taste scoring.

`DefenseManager`:

- groups contiguous adjacent enemy units;
- base danger is `0.25 * maxEnemyStrength`, reduced for one-unit groups, low-importance contacts, and already-cut-off groups;
- response order: small cutoff, direct unit, merge, reinforcement, purchase, then mass-march;
- only enemies legally attackable under diplomacy become defense groups.

### Classic economy inputs used by AI

- unit prices: 10/20/30/40;
- tower 15; strong tower 35; farm `12 + 2 * currentFarmCount`;
- Generic unit tax 2/6/18/36; Slay unit tax 2/6/18/54;
- Generic tower tax 1, strong tower tax 6;
- tile income: normal cell 1, tree 0, Generic farm 5;
- affordability predicts survival: `money + turnsToSurvive * (profit - newUnitTax) >= 0`;
- defense is maximum support from self and adjacent same-color pieces: city 1, tower 2, strong tower 3, unit strength.

Classic AI reads the complete authoritative map. It does not use fog-of-war visibility.

## 3. HD tactical AI

### Core classes

- `game/core_model/ai/AbstractAI.java`: `perform()` calls tactical `apply()`, diplomacy, then end-turn command. Mutations go through event commands. Affordability is `money >= price` and `money + (strength + 1) * (profit - unitConsumption) >= 0`.
- `AiManager.java`: creates AI after graph creation and invokes it for each AI turn. The runtime dispatches `ai_random` and `ai_balancer`.
- `AiFactory.java`: chooses Classic/Default/Duel/Experimental strategy by ruleset version.
- `AiRandom.java`: random legal movement per province; with money `>= 15`, has a 33% peasant-build chance.
- `AiBalancerDefaultV1.java`: production strategy—move units, build towers/farms/units, merge, clean redundant units, relocate idle units.
- `AiBalancerDuelV1.java` and `AiBalancerExperimentalV1.java`: substantially the same strategy, adding farm free-space checks and up to 14 reserve peasants.
- `AiBalancerClassicV1.java`: classic-style branch without modern farm/strong-tower/reinforcement and difficulty gates.
- `ExternalAiWorker.java`: external/turn integration seam.

Difficulty ordinals are tutorial, easy, average, hard, expert, balancer. Campaign selection is `<12 easy`, `<24 average`, `<60 hard`, `<120 expert`, else balancer.

Modern balancer gates:

- normal tower: average+ and predicted defense gain `>= 3`;
- strong tower: expert+, neighboring enemy province size `> ownSize / 2`, and `profit - strongTowerConsumption >= peasantPrice / 2`;
- farm: average+ and dynamic price `<= 80`;
- safe attack: hard+ and no more than 3 newly exposed front-line cells;
- merge: hard+, combined strength `<= 4`, and the province can support the new tax;
- reinforcement: balancer difficulty only;
- target allure: +1 per friendly neighbor, +5 for an adjacent city, doubled for a farm target.

HD preserves the same impossible unit-and-tower comparator defect in the Duel/Experimental lineage.

`RulesetDefaultV1` inputs: normal income 1, tree 0, farm 5; prices 10/20/30/40, tower 15, strong tower 35, farm `12 + 2 * farmCount`; consumption 2/6/18/36, tower 1, strong tower 6; defense values city 1, tower 2, strong tower 3, or unit strength.

## 4. Classic diplomacy

### Model and turn logic

Principal files:

- `gameplay/diplomacy/DiplomacyManager.java`
- `DiplomaticAI.java`
- `DiplomaticEntity.java`
- `DiplomaticContract.java`
- `DiplomaticRelation.java`
- `DiplomaticCooldown.java`
- `DiplomaticMessage.java`
- `DiplomaticLog.java`
- `Debt.java`
- `DipMessageType.java`
- `gameplay/diplomacy/exchange/ExchangePerformer.java`, `ExchangeType.java`, `ExchangeTypeListener.java`

Relations are `NEUTRAL`, `FRIEND`, and `ENEMY`. Each diplomatic entity derives:

- profit and income from all owned provinces;
- full money from all province treasuries;
- land count from province sizes;
- alive state from owning at least one province;
- alive friend count and mutual friends;
- black marks, contracts, debts, and cooldowns.

`DiplomaticEntity` autonomous relation logic:

- 1/3 chance to try friendship; otherwise a `1 / peacefulness` war branch;
- peacefulness is 3 for `AiMaster`, 9 for other tactical AIs;
- war target must be alive, neutral, and not protected by a peace contract;
- 5% of evaluations accept war unconditionally;
- otherwise no attack when target profit `> 2 * ownProfit`, target cash `> 5 * ownCash`, or target friends `> ownFriends + 1`.

`DiplomacyManager` rules:

- diplomatic winner is the alive faction whose other alive factions are all friends; land count breaks ties;
- attack is permitted against an `ENEMY`; neutral/friend provinces are protected, except isolated/neutral cells handled by ruleset semantics;
- during peace AI can build only strength-1 units, at most 4 peasants per province; during war the normal rules apply;
- friendship duration default 12 turns; peace treaty 9; traitor mark 20; black-mark removal lock 10; stopped-war cooldown 10;
- starting a war causes each defender friend to worsen relation with the aggressor by one step;
- breaking friendship creates the traitor consequence;
- money is distributed proportionally across province treasuries; unpaid exchange money can become debt; debt payment pauses during war.

Classic exchange actions: nothing, money, lands, friendship, war declaration, stop war, remove black mark, and dotations/subsidies. During war, an exchange is legal only when one side includes stop-war. Relation lock forbids friendship, war, stop-war, and black-mark removal, but permits money, land, subsidy, and nothing.

Official land prices used by classic diplomacy:

- unit: `25 + 15 * strength`;
- empty/grave: 25;
- tree: 15;
- town: `10 * provinceSize`;
- tower: 50;
- farm: 100;
- strong tower: 75.

Land sales rebuild/fix provinces and preserve connectivity constraints. Small selections are checked by adjacency; AI refuses selling all land or splitting its province.

`DiplomaticAI` per-turn message chances:

- friendship 1/4;
- black mark 1/4;
- peace offer to human 1/5;
- gift 1/15, only when money `> 100`;
- custom message `1 / (20 * factions)`, increased when an unread human message exists;
- peace to another AI 1/3;
- random human exchange 1/3;
- random AI exchange 1/3.

Exchange valuation accepts when gain exceeds loss, or when the difference is no more than 25% of the larger absolute score. Important values: remove black mark ±200; peace normally 120; impossible peace 900; unwanted peace −150; war declaration 180 or −800 when aimed at self; friendship `2.5 * giverIncome`; money face value; land official price.

Paid attack requires at least 50, cannot target self/friend, and offers below 250 have a 25% random refusal. AI land sale requires at least 70% of official value, never all land, and no province split. Some private direct buy/sell/attack-proposal sender methods are present but have no callers in this snapshot and must not be treated as active behavior.

## 5. HD diplomacy

### State and enforcement

- `core_model/DiplomacyManager.java`: relations, locks, attack permission, and alliance propagation.
- `Relation.java`: shared pair relation object and lock.
- `RelationType.java`: ordinal order `war`, `neutral`, `friend`, `alliance`.
- `EntitiesManager.canChangeBeDoneUnilaterally`: a worsening change is unilateral because target ordinal is lower than current ordinal.
- `Letter.java` / `LettersManager.java`: pending diplomatic offers, validation, expiration, and application.
- Events: `EventSendLetter`, `EventApplyLetter`, `EventDeclineLetter`, `EventSetRelationSoftly`, `EventIndicateUndoLetter`.

Attack permission requires relation `war` when diplomacy is enabled and both sides are actual entities. On turn end relation locks decrease for the current entity, except the sentinel lock 999. If one alliance member is at war, the other alliance members are propagated into war unless a relation lock prevents it.

Pending letters to a recipient expire when that recipient's turn ends. Notification/unilateral conditions can apply immediately. A war notification uses lock 3. A letter is valid only while sender and recipient are alive and every condition remains valid.

Condition validation:

- money: executor's total province money must cover the amount;
- lands: nonempty; every tile must still be owned by executor and belong to a province;
- relation: target alive and different, target state differs, relation unlocked; third-party changes must be unilateral;
- land conditions apply after non-land conditions, then cities/provinces are fixed;
- land transfer temporarily preserves pieces.

### HD diplomatic AI

- `ai/DiplomaticAI.java`: alive/adjacency helpers, inbox filtering, letter/event commands.
- `DiplomaticAiEasy.java`: asks every other alive faction for exactly 1 money with 15% chance; starts a random war with 10% chance; accepts every valid incoming letter.
- `DiplomaticAiNormal.java`: creates letters, appraises replies, may leave alliances, and performs aggression.
- `Appraiser.java`: converts land/pieces/relations into a common score.
- Letter templates: `LtAskForMoney`, `LtProposeMoney`, `LtBuyLands`, `LtSellLands`, `LtExchangeLands`, `LtImproveRelations`, `LtAskToWorsenRelations`.

Normal war conditions:

- no war before lap 4;
- target must be adjacent;
- if already at war with an adjacent faction, do not start another adjacent war;
- choose the weakest eligible adjacent faction by appraised wealth;
- own total money must meet `min(0.5 * ownWealth, targetWealth)`, except a 5% branch uses required money 15;
- do not attack a target protected by a third-party alliance when that third-party relation is non-war and unlocked;
- target relation cannot already be war or locked.

Reply logic rejects an abusive one-hex land offer or total appraisal `< 0`; otherwise accepts. The number of outgoing letters has distribution 0/1/2/3 = 25%/50%/15%/10%. AI-to-AI land exchange is suppressed 49/50. It refuses sending its own offer when its self-appraisal is `< -3`.

`Appraiser` values:

- entity wealth is owned hex/piece value; cash and income are not included;
- empty/default 10, pine 5, palm 2, farm 25;
- knight 30, baron 25, spearman 20, peasant 15;
- strong tower 30, tower 20, city 15, grave 7;
- disconnected land value is divided by 5;
- desired simple relation depends on `otherWealth / ownWealth`: `<0.7 war`, `<1.05 neutral`, `<1.2 friend`, otherwise alliance.

Letter templates produce: ask money 1–14; propose money 1–3; buy/sell/exchange contiguous blocks of 2–5 hexes. Relation-improvement and third-party-worsening offers may include money/land compensation and a random relation lock.

## 6. Exact data dependencies that a mod can break

| Dependency | Official assumption | Failure mode after changing it without adaptation |
|---|---|---|
| Unit strength | closed mapping 1–4 | unknown unit maps to invalid/null type; merge, price, defense, and purchase scoring fail |
| Unit price | roughly `10 * strength` | AI reserve/attack purchase thresholds become systematically too cheap or impossible |
| Unit upkeep | fixed strength table | affordability and starvation prediction become wrong |
| Building types | closed city/tower/strong-tower/farm/tree checks | new artillery/port/sea fort is invisible to defense, cleanup, and valuation |
| Defense | max support from self + adjacent same-color pieces | new ranged/naval defense is ignored unless translated into the same query layer |
| Movement | range 4 over connected land, first foreign cell only | ships/water paths cannot reuse land propagation unchanged |
| Province treasury | money/income/profit/tax per province | global or new recurring costs must be exposed through the province economy API |
| Territory size | connected same-color land count | sea cells or structures must not inflate land-size heuristics accidentally |
| Diplomacy | relation + lock + alive entity + ownership | UI-only diplomacy has no effect unless attack/build/AI validation reads the same model |
| Land valuation | hardcoded finite piece table | ports, ships, artillery, and sea forts receive zero/default value and trades become exploitable |
| Fog of war | tactical AI reads full authoritative state | hiding UI data must not delete simulation data; human visibility and AI knowledge are separate policies |
| Difficulty | gates safe attack, farms, towers, merges, reinforcement | making all profiles call the same path makes all bots behave alike |

Official code has no water, ship, port, naval pathfinding, artillery ammunition, ranged attack, or sea-fort strategy. These cannot be added by changing only prices; they need adapters at authoritative economy/defense/movement/appraisal seams while keeping the AI orchestration structure intact.

## 7. Map generators

### Classic

- `gameplay/MapGenerator.java`
- `gameplay/MapGeneratorGeneric.java`

`MapGenerator` initializes the field, builds land/islands, connects land, cuts/deactivates out-of-bounds cells, removes holes, creates trees, spawns many small provinces, splits oversized province components (maximum 5 in the relevant pass), balances starting advantage/province counts, and centers the result. `MapGeneratorGeneric` is the ruleset-specific counterpart.

### HD

- `core_model/generators/AbstractLevelGenerator.java`
- `GeneratorDefault.java`
- `GeneratorClassic.java`
- plan/chunk/link/piece/province spawner and balancer classes in the same directory.

`AbstractLevelGenerator` runs an explicit staged process: rebuild graph; generate/link/repair plan nodes; align center; turn chunks into land; spawn provinces; build/fix provinces and cities; optionally balance; spawn trees; optionally spawn graves, neutral towers, and neutral cities; finish. `GeneratorDefault` and `GeneratorClassic` select different spawner/balancer implementations. The generator owns its seeded random source; setting the seed also seeds the core search worker.

## 8. Diplomacy UI and editor locations

Classic diplomacy UI:

- `menu/scenes/gameplay/SceneDiplomacy.java`
- `menu/diplomacy_element/DiplomacyElement.java`
- `menu/render/RenderDiplomacyElement.java`
- `menu/scenes/gameplay/SceneDiplomaticExchange.java`
- `menu/diplomatic_exchange/ExchangeUiElement.java`
- `menu/render/RenderExchangeUiElement.java`
- relation/log/dialog classes under the diplomacy menu directories.

It is a layered bottom-sheet flow, not one long settings column: selecting a country changes the action strip; exchange opens a separate scene with two offer panels and dynamic arguments.

Classic editor:

- entry: choose-game-mode → editor lobby;
- state: `gameplay/editor/LevelEditorManager.java`;
- touch: `TmEditor` and province editing modes;
- separate scenes for lobby/load/overlay, hex, object, parameters, automation, game rules, diplomacy/relation, province, messages, and pause;
- save/import/export and relation/province/coalition managers.

HD editor:

- `game/editor/EditorManager.java` plus helper workers;
- `TmEditor`, `RenderEditorStuff`;
- `ProcessEditorCreate`, `ProcessEditorImport`, `IwEditor`;
- dedicated editor scenes and “open in editor” flow.

HD is the cleaner implementation pattern; Classic is the fuller behavior/UI checklist. No editor code has been ported in Stages 1–2.

## 9. Stage boundary

This report establishes the official baseline only. It does **not** claim which Flutter mod values are wrong. Stage 3 starts only after the exact mod file list is confirmed; it will report mismatches without editing code. Stage 4 will show proposed before/after diffs and wait for approval before changing protected gameplay files.
