# Camera motion audit — 2026-09-03

## Reproduced/code-confirmed causes

- The old camera wrote `Matrix4.diagonal3Values(scale, scale, 1)`.
  Flutter's `InteractiveViewer` uses `getMaxScaleOnAxis()` internally. Below
  unit zoom it therefore read the untouched Z scale (1), not the visible XY
  scale. Pinch, wheel and kinetic calculations could disagree about zoom.
- Finite zero-margin `InteractiveViewer` bounds enforce **cover** (maximum
  viewport/canvas ratio). The game separately uses **fit** (minimum ratio),
  centered on a short axis. The game clamped on gesture end, before Flutter
  starts its own kinetic animation. Those two policies could correct each
  other after release.
- Every camera notification changed the static-piece culling rectangle. This
  invalidated the still-piece painter even for a one-pixel pan.
- The diplomatic territory picker still had a fixed 0.28 minimum scale and
  the old rhombus height formula, independently of the main map bounds.

## Adaptation

The protected Classic `CameraController.java` was read in full at commit
`f22acaa0d08cc908b9d236bfabc28f93d059ad3e`. Its key pattern is a bounded target
position, a smoothed view position and decaying kinetics. Its pan/zoom factors
are per-frame, and orthographic zoom is the inverse of Flutter display scale.
The new implementation follows that separation rather than copying these
numbers into an incompatible coordinate system.

`lib/src/ui/map_viewport.dart` is renderer-local; it never sends commands,
modifies simulation state, or enters save data. It provides:

- Explicit XY scale reading; uniform scale when publishing matrices.
- The same fit/center/boundary policy at every drag, pinch, wheel and inertia
  step. No second correction on finger release.
- Incremental clamped targets, so excess travel at a boundary is discarded
  and reversing responds immediately, including zoom saturation.
- Exponential, elapsed-time smoothing; bounded velocity and exponential
  kinetic decay. Outward velocity stops at the relevant edge. Pinch zoom has
  no ballistic tail. A new touch stops prior camera motion.
- One transformation notification per display tick. Pointer streams update
  the target only. The viewport retains its child and static display layers.
- Rebased one/two-finger transitions, trackpad pan/zoom, mouse wheel support,
  layout-bound correction and an interaction lock for editor painting.
- A retained overscan window for still-piece drawing; animated pieces retain
  their per-frame view culling. Ordinary-zoom animations remain enabled.

The main game (including LAN and replay), editor and territory/conference
selection use this viewport. The territory picker now uses actual coordinate
extents and a map-relative minimum zoom. No gameplay, AI, map-generation or
network protocol changes are part of this task.

## Automated evidence

`test/map_camera_test.dart` covers XY/Z regression, focal-anchor preservation,
500 saturated-boundary inputs and immediate reversal, bounded fling, 30/60/120
Hz mathematical agreement, 3000 mixed-input frames, retained culling, actual
Flutter drag/pinch gestures, one-finger transition, locked painting and resize.

A 200-event wheel burst emits zero camera notifications before a display
tick, then one on the first progressing frame. The retained board neither
rebuilds nor repaints during the tested camera-only sequence. One thousand
small pan steps need fewer than six still-piece culling windows.

These are deterministic input/render-work checks, not a smartphone FPS
measurement or a guarantee that every device will never drop a frame.
Final suite/build/browser results are recorded in the append-only MEMORY.md.
