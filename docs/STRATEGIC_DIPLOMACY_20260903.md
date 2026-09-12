# Shared relations and strategic diplomacy — 2026-09-03

## Delivered behavior

The two directed opinions have become **one shared relationship** in `[-100, 100]`. The flag list, country information, map-facing relationship rules, AI and LAN all read the same pair score. Financial directions are intentionally unchanged: money owed to you and money you owe are different obligations.

- Both directions are written atomically. A mirrored event cannot award the same relationship change twice in one round.
- Friendship loyalty increases the shared score once per round, not twice. War, black marks, fulfilled agreements and aid affect the shared score.
- Embassy/protest cooldown is shared, so the second player cannot pay for an already-counted embassy action.
- Legacy saves use the rounded mean of the old directed scores. Existing event history remains historical; old paired entries may still be present. Version-2 social data must have a symmetric score matrix in strict imports.

### Military alliance admission

Any alliance containing a bot requires every pair in the resulting group to meet a common minimum: `35 + 8 × (members − 2)`, capped at 91. Thus two members require +35, three +43, four +51. This includes the relationship between the newcomer and members other than the recruiter, and the cohesion of existing members. Checking only one offer arrow cannot bypass the rule. Stale proposals are revalidated before any payment or territory changes.

AI negotiations additionally require a strategic reason for **each bot member**: shared danger, useful frontier, balance of power or common enemy. Trust alone is not a promise to accept. A bloc containing every surviving country is rejected by bots because victory is individual. Human-only alliances retain voluntary consent without a numeric threshold, as requested previously. Existing campaign, peace-conference, black-mark and military-access restrictions remain authoritative.

### Negotiation policy

`StrategicDiplomacyAi` replaces the previous random peacetime offer loop. It evaluates legal, executable contracts from both sovereigns' perspectives:

- Secure a useful border with a temporary friendship while expanding elsewhere.
- Support a financially collapsing buffer against a shared threat; a signature alone does not preserve its army.
- Offer bounded recurring aid to preserve a useful partner.
- Buy adjacent territory or sell non-capital border land for useful liquidity; never sell the entire country.
- Contain a stronger rival with a military alliance, without automatically strengthening the map leader.
- Recruit a neighbor to open a second front against a real enemy; refuse allied, inaccessible or overwhelmingly dangerous war targets.
- Negotiate peace and compensation according to relative strength and economic distress.
- Use bargaining leverage to request payment for security; reprice a rejected cash clause while preserving the other clauses.
- Harder bots can end an obsolete partnership in pursuit of solo victory, respecting campaign locks, treaty compensation and separate declaration-of-war rules.

Each outgoing proposal carries a contextual explanation of its actual terms. A bot can answer a human with an acceptance/rejection reason or a counteroffer. Responses are bounded per pair/round; proposals respect bilateral contact cooldowns and a two-proposal human inbox cap. An isolated, healthy state does not receive decorative gifts/pacts simply to create activity.

These are deterministic offline utilities and grounded Kazakh text templates, **not an LLM, free-form language understanding, trained human-level negotiation, or a guarantee of optimal play**. They introduce self-interested bargaining and temporary cooperation, not arbitrary unenforceable promises. Player-written prose is not interpreted as game commands.

### Difficulty and bounded work

| Difficulty | Candidate countries | Economic horizon | Minimum contact gap |
|---|---:|---:|---:|
| Very easy | 2 | 2 rounds | 8 rounds |
| Easy | 3 | 3 rounds | 8 rounds |
| Normal | 4 | 4 rounds | 6 rounds |
| Hard | 5 | 5 rounds | 6 rounds |
| Very hard | 6 | 6 rounds | 4 rounds |
| Master | 7 | 7 rounds | 4 rounds |

Lower tiers initiate diplomacy every two/three turns; harder tiers look each turn. Counteroffers and strategic aid begin at normal; pressure and third-party recruitment at hard. All tiers obey the same legality and budget rules.

One economic snapshot visits each land/water cell once and builds bounded border candidates. Bloc power and shared threats are cached within a decision, invalidated after accepted agreements. At most 64 plans are scored; only promising generated candidates undergo expensive authoritative territory-connectivity checks. Incoming proposals are validated before evaluation. Accepted incoming contracts can require a fresh snapshot (at most five incoming decisions at master). No remote service, extra network round trip, or per-render diplomacy evaluation was added. Snapshot cash/income are conservative forecasts; actual settlement continues to use the existing engine.

## Research and adaptation

- [Meta CICERO research](https://ai.meta.com/research/cicero/) and its [technical explanation](https://ai.meta.com/blog/cicero-ai-negotiates-persuades-and-cooperates-with-people/) motivated separating strategic planning from dialogue and explaining concrete mutually useful plans. No model, training system or code from CICERO was ported.
- [Freeciv AI diplomacy source documentation](https://files.freeciv.org/nightly/weekly/main/doxygen/html/de/d0d/daidiplomacy_8c.html) provided a primary-source comparison for treaty valuation, alliance-conflict checks, war desire and bounded diplomatic timing. This implementation uses the existing Antiyoy-style engine's constraints and a new local utility policy, not a Freeciv rules transplant.
- Both locally inspected official Antiyoy repositories remain read-only. Custom alliance behavior is an adaptation for this game, not a claim that stock Antiyoy implements these extensions.

## Integration and compatibility

- `models.dart`: shared score migration and optional bounded proposal rationale.
- `diplomacy_rules.dart` / `game_engine.dart`: shared updates, whole-group admission, atomic validation.
- `diplomacy_ai.dart` / `game_ai.dart`: deterministic planning and existing turn-loop integration. Peace-conference allocation logic and land/naval tactical phases are preserved.
- `editor_repository.dart`: strict migration/version/rationale validation.
- `diplomacy_overview.dart` / `diplomacy_sheet.dart`: compact single score, group threshold help and proposal explanation. Existing Classic faces, colors, financial chips and single-panel transitions remain.
- **LAN protocol 3:** host and clients must run the same updated build. Save files remain migratable; incompatible older LAN clients are rejected instead of silently disagreeing about diplomacy.

## Validation

The dedicated strategic suite covers shared/migrated scores, larger-group admission and vetoes, stale atomic proposals, useful containment, budgets and promises, distress land sales, complete-country protection, peace/war restrictions, recruitment, counteroffers, letters, LAN patches, contact limits, difficulty, legal endgame exits and synchronous/yielding determinism. It includes a 6,300-cell / 15-country bounded-search diagnostic, not a universal phone frame-rate guarantee.

- `flutter analyze`: clean.
- Full suite: **354/354 passed**, 3m46s. Log: `build/strategic-diplomacy-final-tests.log`.
- Dedicated strategic scenarios: 25 tests; 15-country diagnostic evaluated 23 plans / 6,300 cells in about 65 ms in a concurrent debug test run. This is not a release/device latency benchmark.
- Release Web: successful, 94.1s; Windows: successful, 59.3s. Logs: `build/strategic-diplomacy-web-build.log`, `build/strategic-diplomacy-windows-build.log`.
- Updated and visually reviewed only the intentional diplomacy score goldens (`diplomacy_main`, `diplomacy_selected`, `diplomacy_obligations`). Full suite verified the other existing goldens.
- Browser smoke test at 1280×720 and 390×844: boot → continue existing save → flag → country → relationship information. Legacy scores 6/3 became +5 and 20/30 became +25; opposing ±250/round subsidies remained separately visible. No overflow or browser warning/error logs observed. No game turns, purchases or treaties were executed in the user's saved match. Viewport override was reset afterward.
- New preview: `http://localhost:7357/?build=20260903-strategic-diplomacy`. Existing tabs were not reloaded. Existing loopback server retained; no firewall/public/LAN service changes made.
- Official Classic and HD repositories remained clean, with complete diff checks returning 0. Map generator, viewport and HexBoard SHA256 values match the pre-task baseline. No camera/generator or official-source changes were needed.

The first broad run caught one test fixture that allowed a separate war-declaration tick while asserting a single response letter. The fixture now isolates response behavior; separate tests verify war decisions and legal endgame pact termination. The final full run above is clean.
