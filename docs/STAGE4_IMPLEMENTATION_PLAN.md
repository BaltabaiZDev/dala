# Stage 4 — approved implementation plan

Date: 2026-08-29

This plan follows the read-only comparison in `STAGE3_MOD_COMPARISON.md`.
The official Classic and HD Java repositories remain reference-only. The
implementation adapts their behaviour inside this Flutter/Dart project while
retaining this mod's ports, boats, artillery, sea forts, 15 colours, fog and
variable starting-province option.

## AI

- Before: one mixed global action loop lets movement, construction and naval
  actions compete for the same small budget.
- After: deterministic phases run in the Classic/HD order: diplomacy/tactical
  setup, existing-unit movement, province spending and safe merges, cleanup,
  then separately budgeted naval/artillery actions.
- Before: purchases only check cash and can bankrupt a province on the next
  economy tick.
- After: purchases forecast price, added upkeep and several survival turns.
- Before: all tiers can buy strength 1–4 and largely share one policy.
- After: tier gates, farm/fortification conditions and target-selection quality
  scale independently; six personalities change priorities without replacing
  difficulty.
- Before: fleets value allied coasts and never board existing armies.
- After: relations filter naval targets and eligible land armies can embark.

## Diplomacy

- Before: incoming contracts can be accepted without seeing exact terms;
  mail/exchange/info share placeholder-like surfaces.
- After: every contract shows both sides, values, duration and affected land;
  country info, mail and exchange each open a distinct functional page.
- Before: alliance betrayal fines the defender's friend, truces can be broken
  immediately, and war can leave debts/subsidies paying an enemy.
- After: the aggressor is penalised, cooldown is enforced, and hostile financial
  obligations are cancelled at the war transition.
- Before: subsidy affordability subtracts the same subsidy twice; the first
  eligible player wins diplomatically; new naval structures are under-valued.
- After: gross pre-contract income caps payment, diplomatic victory favours the
  largest eligible country, and appraisal includes port/artillery investment.
- Before: land sales can split the seller's remainder and cargo can bypass the
  peacetime army cap.
- After: connectivity and peacetime-cap validation cover both cases.

## Map and setup

- Before: one-seed growth tends to repeat silhouettes; tiny lakes can be
  non-navigable; Slay size five is best-effort.
- After: staged multi-seed growth, lake-size repair and a final Slay split pass
  produce coherent but varied maps and enforce province-size limits.
- Starting provinces remain the requested `default -> 1 -> 2 -> 3`; default is
  deterministic variable 1..3 per player. Constructor, JSON and settings
  fallbacks will agree on `default`.
- Each new skirmish still receives a secure random seed automatically.

## Functional editor and content

- Add a separate editor route, not an overlay on the battle setup screen.
- The editor generates a map, lets the user alter terrain, ownership, objects
  and units, rebuilds water/province topology, and launches the edited state.
- Draft save/load and import/export are backed by SharedPreferences/clipboard;
  every exposed editor action has a real effect.
- Replace formula-only campaign configuration and the seven fixed player-level
  demos with persisted, explicit scenario descriptors. Built-in scenarios can
  be copied into the editor and user-created scenarios appear in the level list.

## Verification contract

- No repeated screen capture during implementation.
- After all patches and formatting, run one final test command and retain its
  console output as Stage 5 evidence.
- Re-hash protected/reference algorithms and report every changed Dart/docs file.
