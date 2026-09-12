# Official Java source classification

Read-only inventory of the two official repositories at the exact commits shown below. The complete path-by-path repository trees are in `OFFICIAL_REPOSITORY_TREES.md`.

Classification is disjoint: specialist rules are applied first (AI, Diplomacy, Editor, Entity/Unit, Grid/Tile, Province/Territory), then presentation classes are assigned to Screen/UI, and every remaining source file is assigned to Other. Every `.java` file is counted exactly once.

## Summary

| Repository | AI | Diplomacy | Editor | Entity / Unit | Grid / Tile | Province / Territory | Screen / UI | Other | Total |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Antiyoy Classic | 26 | 82 | 66 | 2 | 7 | 2 | 265 | 579 | **1,029** |
| Antiyoy HD | 22 | 28 | 31 | 15 | 26 | 19 | 508 | 368 | **1,017** |

Checks: `26+82+66+2+7+2+265+579=1029`; `22+28+31+15+26+19+508+368=1017`.

## Antiyoy Classic

- Repository: `https://github.com/yiotro/Antiyoy`
- Commit: `f22acaa0d08cc908b9d236bfabc28f93d059ad3e`
- Source root: `core/src`
- Package root: `core/src/yio/tro/antiyoy`

### AI — 26

- All 16 direct Java files under `core/src/yio/tro/antiyoy/ai`: `AbstractAi`, `AiBalancerGenericRules`, `AiBalancerSlayRules`, `AiEasy`, `AiExpertGenericRules`, `AiExpertSlayRules`, `AiFactory`, `AiHardGenericRules`, `AiHardSlayRules`, `AiNormalGenericRules`, `AiNormalSlayRules`, `AiRestoredBalancerGeneric`, `AiRestoredBalancerSlay`, `ArtificialIntelligence`, `ArtificialIntelligenceGeneric`, and `Difficulty`.
- All 10 files under `core/src/yio/tro/antiyoy/ai/master`: `AiData`, `AiMaster`, `AttackManager`, `DefenseManager`, `DmGroup`, `MasterAction`, `MaType`, `PossibleSpending`, `PropagationCaster`, and `PsType`.

### Diplomacy — 82

- All 11 direct files under `gameplay/diplomacy` and all 3 under `gameplay/diplomacy/exchange`.
- All files under `menu/diplomacy_element` (5), `menu/diplomatic_dialogs` (17), and `menu/diplomatic_exchange` (16).
- `menu/diplomatic_log/DiplomaticLogPanel.java`, the diplomacy-specific scene classes, renderers, menu behaviors, and touch-mode files identified by their `Diplomatic*`, `Diplomacy*`, `Exchange*`, or relation-editing responsibility.
- Principal model files: `DiplomacyManager.java`, `DiplomaticAI.java`, `DiplomaticEntity.java`, `DiplomaticContract.java`, `DiplomaticRelation.java`, `DiplomaticCooldown.java`, `DiplomaticMessage.java`, `DiplomaticLog.java`, `Debt.java`, and `DipMessageType.java`.

### Editor — 66

- All 12 files under `gameplay/editor`.
- `gameplay/game_view/RenderTmEditProvinces.java`.
- Editor touch modes `TmEditor.java`, `TmEditProvinces.java`, and `TmepCityName.java`.
- All 21 files under `menu/behaviors/editor`.
- All files under `menu/editor_elements/add_relation` (3), `color_picker` (3), and `edit_land` (3).
- All 20 files under `menu/scenes/editor`.

### Entity / Unit — 2

- `gameplay/Obj.java`
- `gameplay/Unit.java`

### Grid / Tile — 7

- `gameplay/FieldManager.java`
- `gameplay/Hex.java`
- `gameplay/HexActionPerformer.java`
- `gameplay/MapGenerator.java`
- `gameplay/MapGeneratorGeneric.java`
- `gameplay/MoveZoneDetection.java`
- `gameplay/MoveZoneManager.java`

### Province / Territory — 2

- `gameplay/DetectorProvince.java`
- `gameplay/Province.java`

### Screen / UI — 265

The category contains the remaining view/controller/menu presentation classes after specialist exclusions: direct `gameplay/game_view` renderers (except the editor renderer), direct `menu` controllers/views, and the non-specialist files under menu behavior, element, renderer, scene, help, setup, and creation directories. The directory rules and specialist exclusions make this set disjoint from AI, Diplomacy, and Editor.

### Other — 579

All remaining application, gameplay orchestration, rules, persistence, localization, utilities, campaign/content, and embedded level sources. This includes all 416 files under `gameplay/user_levels`. They are content-as-code and are deliberately not mislabeled as UI or AI.

## Antiyoy HD

- Repository: `https://github.com/yiotro/antiyoy_hd`
- Commit: `120bd3c60eef1eccdda583cd5d9d70b1c493e4f5`
- Source root: `src`
- Package root: `src/yio/tro/onliyoy`

### AI — 22

All files under `game/core_model/ai`: `AbstractAI`, `AbstractLetterTemplate`, `AiBalancerClassicV1`, `AiBalancerDefaultV1`, `AiBalancerDuelV1`, `AiBalancerExperimentalV1`, `AiFactory`, `AiManager`, `AiRandom`, `AiSmileysGenerator`, `Appraiser`, `DiplomaticAI`, `DiplomaticAiEasy`, `DiplomaticAiNormal`, `ExternalAiWorker`, `LtAskForMoney`, `LtAskToWorsenRelations`, `LtBuyLands`, `LtExchangeLands`, `LtImproveRelations`, `LtProposeMoney`, and `LtSellLands`.

### Diplomacy — 28

- Core: `DiplomacyManager`, `Letter`, `LettersManager`, `Relation`, `RelationType`.
- Events: `EventApplyLetter`, `EventDeclineLetter`, `EventIndicateUndoLetter`, `EventSendLetter`, `EventSetRelationSoftly`.
- Import/test: `IwCoreDiplomacy`, `TestDiplomaticSimulation`.
- Touch/view: `TmChooseLands`, `TmDiplomacy`, `TmEditRelations`, `RenderViewableRelations`, `RenderTmDiplomacy`, `RenderTmEditRelations`, `ViewableRelationsManager`.
- UI: `LetterListItem`, `RveRelationItem`, `RenderDiplomaticItems`, `RenderEditRelationsItems`, `RenderLetterListItem`, `RenderRveRelationItem`, `SceneComposeLetter`, `SceneReadLetter`, `SceneSetupRelationCondition`.

### Editor — 31

- All 7 files under `game/editor`: `EditorManager`, `EmEntitiesFixer`, `EmHexAdditionWorker`, `EmPieceAdditionWorker`, `EmProvinceUpdater`, `LgDebugManager`, and `ViewableChange`.
- `export_import/IwEditor.java`, `loading/loading_processes/ProcessEditorCreate.java`, `ProcessEditorImport.java`, `touch_modes/TmEditor.java`, and `view/game_renders/RenderEditorStuff.java`.
- All 3 files under `menu/elements/editor`, all 13 under `menu/scenes/editor`, plus `SceneOpenInEditor`, `SceneEditorCreate`, and `SceneEditorLobby`.

### Entity / Unit — 15

`CityManager`, `ConstructionManager`, `DeathManager`, `EntitiesManager`, `EntityType`, `PieceType`, `PlayerEntity`, `TreeManager`, `EventPieceAdd`, `EventPieceBuild`, `EventPieceDelete`, `EventUnitMove`, `ViewableEntityInfo`, `UnitsManager`, and `ViewableUnit`.

### Grid / Tile — 26

`CoreGraphBuilder`, `Hex`, `EventGraphCreated`, `EventHexChangeColor`, all 18 generator/plan classes (`AbstractLevelGenerator` through `LgTreeCluster`), `IwCoreGraph`, `IwCoreHexes`, `IwStartingHexes`, `RenderHexesInTransition`, `GeometricalHexData`, `GhDataContainer`, and `ViewableHex`.

### Province / Territory — 19

- All 6 files under `game/core_model/core_provinces`.
- Province spawner, analyzer, builder, and balancer classes under `game/core_model/generators`.
- `IwCoreProvinces`, `IwStartingProvinces`, `RenderProvinceSelection`, `LandsManager`, `ProvinceSelectionManager`, and `SceneProvinceManagement`.

### Screen / UI — 508

- `game/view/GameView.java`.
- Presentation files under `game/view/game_renders`, `tm_renders`, and `viewable_model` after excluding the specialist files listed above.
- Every Java source under `menu` after excluding the explicitly listed Diplomacy, Editor, Province, Grid, and Entity files. This covers menu roots plus button, calendar, choose-game-mode, experience, forefinger, gameplay/income graph/province UI, keyboard, network UI, plot, replay, rules picker, setup, shop, slider, smileys, customizable lists, resizable elements, menu renderers, and scene directories.

### Other — 368

All remaining bootstrap, core orchestration, event, ruleset, export/import, loading, save, campaign, tutorial, debug, tests, networking/protocol, and utility sources. The large `net` subtree remains Other because it is infrastructure rather than gameplay UI or AI.

## Architecture conclusion

Antiyoy HD is the cleaner structural baseline: it separates authoritative `core_model`, events/history, viewable/replay state, rendering, rulesets, generators, import/loading, and editor concerns. Classic remains the behavior/content oracle for original rules, diplomacy UX, assets, and embedded levels. An offline Flutter port should reuse concepts rather than copy the HD network/LibGDX/platform layers.

Neither checked snapshot contains a complete runnable platform wrapper. Classic has `core/build.gradle`; HD has no Gradle build file. Both therefore require an external wrapper to run as original LibGDX projects.
