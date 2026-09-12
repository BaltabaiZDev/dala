# Alliance and performance audit — 2026-09-03

## Rules now enforced

- A funded expedition does **not** die just because shared occupied land has no province. Its sovereign home province pays upkeep. Bankruptcy removes it; losing all sovereign funding removes it during rebuilding. Ordinary unsupported one-cell sovereign provinces retain the Classic orphan rule.
- A deterministic radius-limited movement route records every sovereign allied territory crossed, including intermediate cells traversed in one action and landing routes. Returning to sovereign land resets the expedition, including merges. Crossing an existing claim does not invent credit for that claim's captor.
- Direct conquest remains ordinary land. Allied-transit conquest retains exact contributor wedges and frozen appraisal, without a province/town or construction. Trees do not spontaneously grow into invalid unresolved claims.
- Claim land is not abandoned neutral land: the normal relation check applies even without a province. A pending conference freezes the disputed pool against recapture until resolution.
- Military membership is locked while a campaign or peace conference is pending. A coalition split that would strand any member's guest troops is blocked, including transitive access. Black marks cannot bypass those locks; in peacetime they sever the marked country's conflicting direct/transitive links. An aggressor is not punished into war with its own military-bloc member merely because that member also has an ordinary friendship with the defender.
- Guest troops remain selected instead of receiving the foreign-territory selection fade. A guest on an allied tree/grave survives strict save validation and normalization. Its bankruptcy does not overwrite the host's tree.
- Funded troops on claims survive strict schema-12 save/import validation during both war and conference. Home-province identity is still required.
- Settlement never stacks a unit on a newly created town. Protected displaced troops are moved to a deterministic legal free allied/own cell; when none exists they are removed. A forced return onto own trees/graves clears the obstacle without awarding money. Dead recipients cannot be assigned new treaty land.
- An explicitly departing LAN faction cannot leave a permanent conference veto or dangling claim reference. Its outstanding campaign ends and the affected disputed pool is returned before its sovereign assets are neutralized. Direct conquests are not part of that rollback. Existing cross-bloc cooldowns prevent an immediate new war.

These are mod rules around the existing Classic land economy. The multi-color occupation and unanimous peace conference are not claimed to be original Antiyoy features. Five-round fallback, ten-round war ban, exact quotas and unanimous counteroffers remain unchanged.

## Verified performance causes and changes

The read-only Classic reference at `f22acaa0d08cc908b9d236bfabc28f93d059ad3e` separates background and moving pieces:

- [RenderBackgroundCache.java](https://github.com/yiotro/Antiyoy/blob/f22acaa0d08cc908b9d236bfabc28f93d059ad3e/core/src/yio/tro/antiyoy/gameplay/game_view/RenderBackgroundCache.java) retains framebuffer regions and refreshes affected regions.
- [RenderUnits.java](https://github.com/yiotro/Antiyoy/blob/f22acaa0d08cc908b9d236bfabc28f93d059ad3e/core/src/yio/tro/antiyoy/gameplay/game_view/RenderUnits.java) iterates a unit list and rejects positions outside the view frame before drawing sprites.

The Flutter adaptation uses its own rendering primitives, not Java/OpenGL code copied into Flutter:

- A board-owned disposable `ui.Picture` caches terrain/grid/object draw commands across selection and defense fades. It is a display-list cache, not a claim that Flutter now uses the same framebuffer implementation.
- Separate repaint boundaries retain stationary pieces/markers/supply links while ready units, ships and province alerts animate. Prepared visible piece lists avoid scanning thousands of empty cells per idle frame; the animated pass filters to the current turn's ready pieces. Camera-relative bounds reject offscreen sprite draws. Camera changes invalidate the affected piece views.
- Full animations remain at ordinary zoom on all sizes. Existing fit-relative overview hysteresis (pause at 1.22, resume above 1.38) and system reduced-motion behavior are unchanged.
- Province rebuilding indexes actual old/new overlaps once instead of scanning every new component for every old province. Exact city/farm/size priorities and deterministic tie order remain. Per-rebuild tile/ID maps replace repeated scans while restoring unit/ship/fort funding lineage.
- Alliance graph traversal builds one alive-owner set per query instead of rescanning provinces for every edge.

### Measurement

`test/alliance_performance_test.dart` builds 5040 cells, 2520 two-cell provinces, 15 colors and 2520 units. The pre-optimization rebuild was **350 ms**; the isolated post-optimization run was **62 ms** (about 5.6× faster for this operation). Loaded full-suite runs measured 73–81 ms. The test compares the complete serialized state before/after, not only troop counts.

This is a host-side CPU microbenchmark, not phone FPS or whole-turn latency. No claim of zero stutter on all devices is made. Native release builds and browser CanvasKit rendering have different budgets. The map generator, tactical AI decisions and 10 ms cooperative AI scheduling were not changed.

## Verification inventory

- `military_alliance_test.dart`: 28 passing cases, including route credit, bankruptcy, strict save, hostile treaty attacks, coalition locks, black marks, departure cleanup, direct conquest, counteroffers and expiry.
- `render_performance_test.dart`: cached display-list invalidation; byte-identical RGBA output from combined versus separated piece passes; offscreen draw exclusion.
- Final complete regression run: **279/279** in 3m33s, without refreshing goldens. Static analysis passed with no issues. Final web and Windows release builds succeeded.
- Browser smoke: giant 15-color Master game, pan/zoom, diplomacy list/exchange panel, full opponent turn cycle, and zero warning/error entries in the inspected browser log. Screenshots were inspected in the tool output.
- The source reference repositories remain untouched. The workspace has no root `.git`; authored files are the four Dart sources and three tests listed below plus this report and append-only memory.

Sources changed: `lib/src/game/game_engine.dart`, `lib/src/game/game_controller.dart`, `lib/src/persistence/editor_repository.dart`, `lib/src/ui/hex_board.dart`.

Tests changed/added: `test/military_alliance_test.dart`, `test/alliance_performance_test.dart`, `test/render_performance_test.dart`.
