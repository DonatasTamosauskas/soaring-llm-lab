# Soaring — status (2026-09-27)

A playable v1: all eight areas built and integrated into `scenes/main.tscn`,
running end to end on desktop and in the Meta XR Simulator. A debug APK for
Quest is at `build/soaring-quest.apk` (97 MB, built 2026-09-27 15:06). It has
never run on real Quest hardware yet. How to play, run and verify:
`README.md`; how it is composed: `docs/INTEGRATION.md`.

## Install on the headset

Developer mode on, USB to the Mac, then `adb install -r build/soaring-quest.apk`
(or drag the APK into Meta Quest Developer Hub). It appears under Unknown
Sources. Rebuild with `tools/export_quest.sh debug "$PWD/build/soaring-quest.apk"`
(absolute output path).

## Verification at wrap-up (2026-09-27, 15:05–15:25)

| Check | Result |
|---|---|
| Suites (`tools/gd.sh <sb> --headless res://tests/runner.tscn -- --suite=unit/<area>/`) | core 6/6, game 141/141, ai 87/87, ui 193/193, flight 184/184, vr 161/161, world 39/39, birds 65/65, audio 43/43 |
| Integration suite (`--fixed-fps 72`) | 39/43: the 4 failures are the documented tuning gaps below |
| Simulator, whole game (`tests/shots/integration_sim.sh --tag=final`) | 14/14 PASS: FOCUSED, physics = refresh 72 Hz, 71.7 fps (p95 14.5 ms) at the Quest tier with 28 NPCs, 43–55 draw calls, 70k primitives, controller menu use, first-launch calibration, wings visible, 8 wingbeats from simulated strokes, 0 errors |
| Core loop through real flight (held-out seeds, modelled competent player) | pigeon 5:27 (full) / 6:31 (Quest), eagle 24:08 / 29:31; 1.4–1.7 catches/min, ~70% without assist; first hunt ~1:08; caught ≥ 1 in 11 of 12 runs, none lost |

Note: the ui and audio suites are real-time tests; run them without
`--fixed-fps` (with it, the UI's wall-clock menu debounce and the audio
buffer timing fail spuriously).

## What was cut to finish (by decision, for time/token budget)

- The second independent verification round of the last core-loop fixes was
  stopped at its start; those fixes are covered by the suites and evidence
  above, not by a fresh adversarial review.
- The planned cross-area polish review was dropped.

## Known issues / limits (to judge on the headset first)

- **Hardware-only unknowns:** controller-axis convention (wrist tilt → wing
  pitch was measured only in the simulator), real frame time (estimated, not
  measured; check with OVR Metrics), depth precision at sparrow size.
- **Comfort to tune in person:** a sparrow's full-input turn is fast (Turn speed
  setting 90–240 °/s, default 180); catches register ~3–5 felt metres from
  the head (deliberate VR forgiveness).
- **Tuning gaps** (`real_pacing_test`, `sky_hunt_test`): the modelled novice
  grows about as fast as the expert (skill ordering not shown); the danger
  threshold is met only by a thin margin; the target ring still switches
  ~0.5×/min away from a bird being closed on; on one seed at the Quest tier
  few NPC hunts are visible to the player.
- **Minor UI:** coral threat chevrons can show for a non-hunting bird close
  by during lessons; no notice explains the chevron at the first attack.
- Evidence is from a modelled player flying the real controls, not a person.
- Meta XR Simulator setting left changed by an early research probe:
  `~/Library/Application Support/MetaXR/MetaXrSimulator/persistent_data.json`
  has `dolly_scroll_speed: 0.0` (default 10.0) plus a few added keys; reset it
  in the simulator UI.
- `addons/godotopenxrvendors` was upgraded 3.1.2 → 5.1.0 (required for the
  Quest export); the old copy was only kept in a session scratch directory.

## Playtest build #1 changes (2026-09-27 evening, `playtest-notes.md`)

New APK built 18:41. All changes are live-tunable in **Settings → Developer**
(persisted; "Reset" restores the defaults below). Please report which values
feel best.

| Note | Change (default) | Developer control |
|---|---|---|
| Turning too sensitive | 10° dead zone around neutral, non-linear curve (x²), full turn at ~47° of tilt | Turn dead zone 0–20°, Turn sensitivity (full at 70–25°), Turn curve (x^1–x^3) |
| Arms-out T-pose tiring | Full wings now with elbows relaxed / upper arms down (reach 0.48 of arm, folds only below -68°); stretching fully out gives a +60% power flap | Glide: T / Relax |
| Too slow vs NPCs | Flap force and climb x1.6, glide efficiency and dive limit x1.3, roll rate x1.3 | Flap power, Speed / glide, Roll rate |
| Tilt turns the wrong way | Wrist-tilt turning inverted by default | Tilt dir: Norm / Inv; Tilt turn: Off / On; Arm turn: Off / On |

The flight/vr/ui/core suites pass (they pin the original tested physics
where they measure it). Not re-run: the long real-flight pacing evidence, so
catching and growth pacing will be somewhat faster than the numbers above.
