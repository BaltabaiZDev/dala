# Bilateral diplomacy overview — 2026-09-03

## Delivered

The flag's country list now displays both directed opinions, diplomatic status and remaining friendship/truce cooldown, black mark, outstanding debts, recurring subsidies and mandatory friendship-break compensation. Country information shows the same obligations with a short explanation. The existing Classic palette, faces, toolbar, single-panel navigation and generated/custom names are retained.

- `Ол → сіз` is the other country's opinion of the viewer; `Сіз → ол` is the reverse opinion.
- Positive money is receivable by the viewer; negative money is payable by the viewer. Opposing debts/payments are never netted into an invisible zero.
- Debt is the remaining balance, not a per-turn income figure. `/ход` is the contractual recurring amount, not a guaranteed next payment. Actual settlement still depends on the existing income/treasury rules.
- `x` is the number of rounds left. Contracts are grouped only when type, direction and expiry match; different expiries remain visible separately.
- Expired/zero payments and third-party agreements are excluded. War voids ordinary debts/subsidies but mandatory compensation remains visible, matching the engine.
- LAN uses the local viewing player, not whoever currently owns the turn. Host snapshots update the open list. Opinion action buttons remain disabled off-turn.

## Implementation boundary

`lib/src/ui/diplomacy_overview.dart` is a read-only projection of the existing state. It never calculates map-wide income, consumes RNG, modifies a contract, or sends a network command. `diplomacy_sheet.dart` renders its compact rows and wraps money chips on narrow screens.

No changes to the engine, models, AI, generator, camera, save format or LAN protocol. Existing economic rules are not rebalanced. Pending offers are not obligations; legacy global traitor fines are not attributed to an invented counterparty.

Read-only Classic reference: `DiplomacyElement.getItemDescription()` at commit `f22acaa0d08cc908b9d236bfabc28f93d059ad3e` lists signed debts and subsidy contracts with expiry from the main entity's perspective. The mod adds directed opinions and its military-alliance/mandatory-compensation distinctions.

## Verification

- 10 new tests: directional opinions and balances, reverse viewer, immutable projection, matching/different expiries, expired/third-party exclusion, war compensation, actual round settlement/save round-trip, statuses, 320/390/1280px layouts, large text and long names, and live LAN snapshot updates.
- Final regression selection: **247/247 passed**, 1m37s, `build/diplomacy-overview-final-tests.log`. This includes game/economy, diplomatic trading, alliances/conferences, LAN, camera, polish and visual tests. It is not a full-suite rerun.
- An old game UI assertion expected the previous combined status/opinion string. Updated it to assert the status and both directed opinions; the real action checks remain. The final selection is clean.
- Inspected the new obligations visual baseline and intentionally updated country-list/selected-row baselines. Existing exchange, inbox and face visual checks pass.
- Final analysis: no issues. Web release: 93.5s; Windows release: 85.0s.
- Browser: continued the saved match in a new tab without moving, trading or overwriting it. Verified incoming and outgoing `$250/ход` contracts with 13 rounds remaining, both opinions, country information, same-panel back, and narrow/wide rendering. Warning/error log empty. Temporary viewport override reset.
- Preview: `http://localhost:7357/?build=20260903-diplomacy-obligations`. Existing user tabs preserved; loopback server unchanged.

The original modal height is captured when opened; resizing an already-open modal keeps that captured height. This predates the change. Fresh opening uses the current viewport. No modal-sizing redesign was included here.

## Reference protection

Both official repositories remain clean; complete `git diff --quiet HEAD -- .` checks returned 0. Map generator, AI, engine and model SHA256 hashes match the prior camera task. `game-ui-frontend` guided compact game-style disclosure and `game-playtest` guided visual/interaction checks. No subagents.
