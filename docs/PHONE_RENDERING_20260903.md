# Phone camera and rendering — 2026-09-03

## Scope

Physical Android phone `2201117TG` (arm64), native AOT profile measurements,
not a desktop browser with a narrow viewport. The requested bottom-of-map
access and large-map interaction stalls were addressed. Game rules, generator,
AI, LAN protocol and save schema were not changed.

## Changes

- The camera's actual viewport excludes the construction/cargo panel (54–92
  logical pixels according to layout). Opening/resizing the panel reveals a
  clipped selected cell without resetting zoom. Both normal and Slay layouts
  have real tap-to-build tests at the bottom edge across zoom levels.
- `MapRasterCache` retains a 1536-pixel-long-side overview plus visible
  512-world-unit detail chunks at quantized resolution. Detail allocations are
  capped at 48 MiB for terrain and 12 MiB for the transparent action mask.
  Jobs run serially after frames; obsolete results are disposed. A new terrain
  or visibility signature immediately discards old images, so the cache cannot
  preserve stale fog/ownership. Allocation failure uses current vector data.
- Whole-map overview uses less decorative detail. Important buildings remain;
  ordinary-scale trees/buildings use sharp detail tiles with a visible-object
  fallback until a tile is ready. Existing idle/fade animation hysteresis is
  retained: animation pauses near the fitted overview and resumes when zooming
  in. It is not disabled solely because the map is large.
- Selection, water targets, defenses and firing artillery are not baked into
  an unchanging terrain image. The full object state is still used for detail
  tiles and all game interactions.
- Team masks are prepared into one premultiplied RGBA atlas rather than doing
  a color-filter pass for every sprite during pan/rasterization. A pixel test
  compares the atlas with the original `srcIn` filter. No image assets, palette
  values or save data were changed.
- Flutter's whole-board raster-cache hints are disabled on the large retained
  layers; explicit bounded textures own that job. Grid batching is used only
  for overview: batching the entire map for individual detail tiles was tested
  and rejected because it defeated spatial culling.

## Original Antiyoy and Flutter evidence

Classic's [RenderBackgroundCache.java](https://github.com/yiotro/Antiyoy/blob/f22acaa0d08cc908b9d236bfabc28f93d059ad3e/core/src/yio/tro/antiyoy/gameplay/game_view/RenderBackgroundCache.java)
stores framebuffer regions and draws their textures, with affected-region
updates. This project previously retained only a Flutter `ui.Picture`, which
still replays drawing commands on the GPU. The adaptation is architectural;
Flutter is not libGDX, and this change does not claim identical performance.

Measurements follow Flutter's guidance to use a [physical device in profile
mode](https://docs.flutter.dev/perf/ui-performance) and separate [UI and raster
frame durations](https://docs.flutter.dev/tools/devtools/performance).

## Reproducible physical-phone comparison

`tool/device_render_benchmark.dart`: fixed giant-map seed 20260903, 15 human
colors, 3 starting provinces, 65% trees, diplomacy enabled. Same camera
trajectory, warmup and three 15-second phases before/after. Selection toggles
every 0.7 seconds. Uses `FrameTiming`; it measures the rendering path, **not**
end-to-end touch latency, AI turn time or LAN transport latency.

| Raster duration | Before P50 / P95 | After P50 / P95 |
| --- | --- | --- |
| Whole-map overview | 635.1 / 676.8 ms | 5.9 / 6.4 ms |
| Pan and zoom | 38.8 / 61.0 ms | 3.9 / 8.2 ms |
| Pan + selection | 40.7 / 75.0 ms | 5.1 / 11.5 ms |

After: no raster frames over 32 ms in pan (1038 samples) or selection (996
samples); maxima 28.2 and 30.4 ms. Overview had 4 frames over 32 ms (666
samples), worst 951.8 ms during initial preparation. **Cold preparation is not
stall-free**, and these results are not a guarantee of zero dropped frames on
every phone or under memory/thermal pressure. The asynchronously measured
overview preparation time can include waiting behind other rendering work.

Raw logs: `build/phone-render-baseline-results.log` and
`build/phone-render-atlas-results.log`. Intermediate experiments are retained
in `build/phone-render-*-results.log`, including regressions which were not
shipped. Final source uses the atlas, not the intermediate per-mask GPU tint
jobs or uncached visible-object renderer.

## Verification and delivery

Final analyzer: **clean**. Final full suite: **363/363 passed** in 3m14s.
Release APK: **55.2 MB**, built successfully in 82.3s and installed with `-r`
on the physical phone. Main game launch returned `Status: ok`; foreground
activity and last update `2026-09-03 13:26:16` were verified. The original
first-install timestamp `2026-08-28 19:23:11` was retained. The separate
benchmark package was removed after testing; the real game was not uninstalled.
This task rebuilt/deployed Android, not the older live web preview.

- New tests cover camera/HUD bounds, actual bottom-cell placement, pixel-cache
  reuse, bounded memory, stale-job disposal, hidden-layer idling, allocation
  fallback, transparent-mask opacity and tint pixel equivalence.
- Visual tests now wait for loaded map sprites instead of comparing a partly
  loaded board. Only the affected fog, Slay and board/panel golden images were
  regenerated after inspection; menu/diplomacy goldens were not regenerated.
- Native screenshots: `build/phone-render-actual.png` (an intermediate measured
  probe) and `build/phone-render-final-release.png` (installed normal release).
- Diagnostic Android package is `.benchmark`, with autosave and authoritative
  simulation disabled. Normal release package remains `kz.antiyoy.antiyoy_self`.
  Updating uses `adb install -r`, never uninstall/clear-data on the real game.
- Analyzer/build/test logs use the `build/phone-render-` prefix. See the final
  completion entry in `MEMORY.md` for the completed suite and install outcome.

The official Classic and HD checkouts were inspected read-only and remained
clean. Rendering caches are board-owned and never serialized or sent via LAN.
