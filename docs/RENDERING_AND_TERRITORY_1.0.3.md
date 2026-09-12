# DALA 1.0.3: map clarity and territory previews

## Player-facing changes

- Incoming and outgoing land terms have a **View on map** action, with the
  giver and recipient named in the correct direction. The camera frames the
  offered cells, and the cells receive a bright outline. Viewing is read-only:
  it neither accepts a proposal nor changes the selected offer.
- Land footprints can be inspected even when the terrain is under fog. Other
  hidden terrain, ownership and pieces remain concealed. Naval assets are
  located only when they are currently visible. The picker uses mod sprites
  and colors, and large previews use the same bounded terrain cache as gameplay.
- The full-width blank HUD becomes two small dark, gold-edged field panels.
  The left panel shows the player or selected province's treasury and balance;
  pause stays at the right edge. Income ranking/report actions remain available.
  The ground construction tray has a straight gold edge.
- New strings are included in Kazakh, Russian and English.

## Renderer

Large-map trees and static buildings are drawn once, separately from terrain
textures. Zooming and terrain-cache completion cannot swap them between a
low-resolution overview and a sharp sprite. Strategic buildings remain visible
at overview scale; tiny decorative objects are culled at that scale.

Detail recording queries an axial coordinate index for the visible region,
instead of repeatedly walking the entire board. Color fills and edges are
batched within detail regions. Full overview fills remain separate: profiling
showed that combining the entire map into large fill paths made cold rendering
slower. Object signatures are computed outside camera animation callbacks.

All land grid and sea-region lines are retained in the overview. Detail
resolution has hysteresis to avoid repeatedly replacing textures during a
pinch. On memory pressure, the existing overview survives and a smaller 1x
detail set refills; the game no longer stays permanently blurred at overview
resolution. Mobile detail budgets are 16 MiB for terrain and 4 MiB for masks;
pressure budgets are at most 4 MiB and 1 MiB respectively. The mobile overview
remains capped at 1024 pixels. An experimental 1536-pixel mobile overview was
discarded after measuring its higher cold-render cost.

## Verification

- Full suite: 561 passed, with two expected failures from the HUD redesign.
  The income-report test now taps the semantic action instead of its old screen
  coordinate, and the inbox golden was visually reviewed and updated. Both
  tests passed individually afterward. The static inbox golden now disables
  idle flag animation so asset-loading time cannot change its pixels. The final
  18 rendering/cache/HUD/preview checks passed together, as did localization.
  No assertion or timing limit was relaxed.
- New regression coverage checks incoming gifts and demands, exact highlighted
  cells and camera framing, no state mutation during preview, and acceptance
  afterward. HUD layout is checked at 320, 390 and 1280 logical pixels, including
  very large treasury values and the pause action.
- Pixel comparisons verify direct town/pine/palm sprite pixels on a giant map,
  including memory pressure. Spatial queries are checked against a full-map
  reference, along with bounded texture refill and pinch threshold reuse.
- Release browser: giant map, 15 human players, three starting provinces,
  100% trees and diplomacy. Startup, overview, close zoom and pan were visually
  inspected; the captured error log was empty. QA used a separate localhost
  origin to preserve the player's browser save.
- Android arm64 and Web release builds and static analysis pass.

### Desktop rendering comparison

Same `tool/terrain_benchmark_test.dart`, same Flutter runtime, Android cache
policy under the desktop test renderer. Baseline is commit `2151c64` (1.0.2)
in a detached worktree. Giant 5041-cell map, 15 players, three provinces each,
100% trees, seed 20260903. Detail textures are 514 x 514 in both runs.

| Measurement | 1.0.2 | 1.0.3 |
| --- | ---: | ---: |
| Median detail preparation/dispatch | 19.70 ms | 9.74 ms |
| Median detail texture raster | 11.57 ms | 8.75 ms |
| Cold overview texture raster | 113.21 ms | 130.32 ms |

The detailed region work is cheaper, while retaining all overview lines has a
small one-time cost. These are desktop rendering measurements, not phone FPS.
The physical phone probe and installation of 1.0.3 are pending the player's
availability; no new phone performance result is claimed for this release.
