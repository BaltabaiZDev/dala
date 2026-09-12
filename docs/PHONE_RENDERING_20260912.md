# DALA 1.0.1–1.0.2: mobile startup, mods and menus

## Device and evidence

Test device: Redmi 2201117TG (`spes`), Android 13, 6 GB RAM.
The original foreground exit at 17:36:33 was a SIGKILL (signal 9), with
192 MB PSS / 264 MB RSS recorded by Android. No Dart exception was found.
The exit reason alone does not establish an out-of-memory cause.

The user confirmed that a large map opens and plays after installing 1.0.1.
The package remains `kz.antiyoy.antiyoy_self`. The user subsequently saved the
open game and authorized installing 1.0.2 (version code 3), which succeeded.
Installation used `adb install -r`, preserving application data.

## Rendering changes

- Pending terrain textures draw only the visible region. Previously the initial
  close camera could tessellate the entire curved map in its vector fallback.
- Action-mask fallbacks and detail recording also cull offscreen land and water.
- Android/iOS use 256-unit detail tiles, a 1024-pixel overview, 20 MiB terrain
  detail and 4 MiB action-mask detail budgets. Desktop budgets remain unchanged.
- Terrain and mask texture allocations share a serial queue.
- On a memory-pressure notification, detail textures and organic geometry caches
  are released. The existing small overview is retained, avoiding a full vector
  repaint and a new allocation under pressure. Detail does not immediately refill.
- Army recruitment hints use the active mod's price.

## Physical benchmark

`tool/device_render_benchmark.dart`, separate `.benchmark` Android package:
giant map (5041 cells), 15 players, 45 starting provinces, 100% trees,
diplomacy, seed 20260903. Three 15-second phases after warmup.

The original and first optimized rendering builds both completed this scenario:

| Measurement | Original | First optimized build |
| --- | ---: | ---: |
| Map generation | 4687 ms | 4888 ms |
| Overview raster p95 | 18.023 ms | 9.488 ms |
| Pan raster p95 | 18.558 ms | 11.101 ms |
| Selection raster p95 | 21.428 ms | 15.227 ms |
| Pan frames over 32 ms | 9 | 0 |
| Selection frames over 32 ms | 10 | 0 |
| Final PSS | 241414 KiB | 236454 KiB |
| Final graphics memory | 93764 KiB | 92972 KiB |

These are single-run measurements, not a guarantee of frame rate. A cold
overview stall remained (780 ms original / 984 ms optimized). The later
memory-pressure refinement retains the overview after a pressure signal.
An initial final-build probe was dismissed through `SwipeUpClean`. A repeat
with the phone left idle completed on the final rendering build:

- Generation: 4288 ms; overview/pan/selection raster p95: 11.938/10.717/15.551 ms.
- Pan and selection: zero frames above 32 ms; cold overview maximum: 972.793 ms.
- Before `RUNNING_CRITICAL`: PSS 274645 KiB, RSS 348684 KiB.
- After that pressure signal: PSS 232125 KiB, RSS 292184 KiB; same process alive.
- Graphics memory: 93372 → 92940 KiB. Most released memory was outside graphics.

The benchmark app was then uninstalled. The player's app and saved data were
preserved. These physical measurements precede 1.0.2's startup-camera and ZIP
import changes; those changes are covered separately by automated checks.

## Automated and visual checks

- Earlier complete suite: 554 tests passed before the final refinement.
- Final 1.0.2 suite: 556 passed; one wall-clock AI check took 3437 ms against
  its 3000 ms limit while release builds ran concurrently. That exact test
  passed separately after builds finished, without changing its limit or code.
- Camera golden images were inspected and updated for the intended province
  focus; all final visual comparisons passed.
- Final cache/render tests verify retained overview, no detail refill, viewport
  culling, allocation-failure fallback and unchanged visible pixels.
- Analyzer: no issues. Android release and web release builds succeeded.
- Home and mod library verified at 320/360 px, including KK/RU/EN, persisted
  language changes, several active mods, priority arrows and unchanged custom names.
- Browser checked: compact home, language switch, mod library and map tab.
- LAN sockets checked: missing packages, edited same-version packages, complete
  multi-mod stack, host ordering and rejection of mismatching controller rules.

## Follow-up: ZIP imports and camera (1.0.2)

- `.dalamod.zip` and `.zip` are accepted in the file picker, native `mods/`
  scans, Android document folders and the library. A single enclosing folder
  is accepted; unrelated ZIPs, multiple roots and invalid paths are rejected.
- Startup frames the largest owned province (capital order breaks ties),
  falling back to owned land or a naval asset. Distant ships cannot pull the
  initial view into empty sea. Human turns restore both pan and zoom; AI and
  remote LAN turns keep the local player's view.
  A selected owned province or naval piece takes precedence when opening a
  saved game, so an active selection does not start offscreen.

The mod file is `.dalamod` (also accepted as `.dalamod.zip`/`.zip`); map file
is `.dalamap`. All LAN participants install
matching packages before joining. See [MODDING.md](MODDING.md) and
[LOCALIZATION.md](LOCALIZATION.md).
