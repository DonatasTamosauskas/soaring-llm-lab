# Soaring

A VR bird game for the Meta Quest (Godot 4.7.2, OpenXR). You are a small
bird in a big, alive valley. You fly with your arms: flap to climb, spread
and tilt your wings to glide, bank and dive. Catch birds smaller than you,
flee birds bigger than you, and grow from a sparrow to an eagle while the
world shrinks around you.

- The product brief: `docs/DESIGN.md`. How the code fits together:
  `docs/ARCHITECTURE.md`. How the areas become one game, measurements and
  known limits: `docs/INTEGRATION.md`. Each area: `docs/areas/*.md`.

## How to play

1. **Start.** The game opens on a village roof with the main menu in front
   of you. Point at **Play** with either controller and pull the trigger.
2. **Learn to fly.** Short lessons appear above the horizon and move on when
   you do them: spread your wings, flap to climb, glide, tilt for speed, bank
   to turn, tuck to dive, catch a smaller bird.
3. **Fly with your arms** (each controller is a wingtip):
   - **Flap**: sweep both arms down hard. Wings flat push you up; wrists
     twisted leading-edge-down push you up *and* forward.
   - **Speed**: twist both wrists leading-edge down to dive and gain speed;
     leading-edge up to balloon up and slow down (too far and you stall;
     stalls recover).
   - **Turn**: one wing's leading edge up, the other's down (or one hand
     higher than the other): you bank and the heading follows.
   - **Dive**: pull both arms in to your chest.
   - **Perch**: fly slowly into a branch, wire or ledge; flap to leave.
   - Rising air (dust and pollen motes over warm fields, cliffs facing the
     wind) lifts a gliding bird without flapping.
4. **Eat or be eaten.** Birds you can catch get a blue ring (worth chasing);
   birds that can catch you get a magenta triangle. Fly into prey to catch
   it; each catch makes you heavier. At each threshold you become the next
   species (sparrow, swallow, starling, pigeon, crow, gull, hawk, eagle):
   faster, heavier, wider turns, bigger prey. The smallest birds stop being
   worth it. Get caught and you lose some size and a life, and wake up on a
   perch. A run ends when your lives run out (catching and growing earn them
   back). As the eagle, three worthwhile catches win the valley.
5. **Menus.** Left menu button (or hold **B** 0.8 s): pause, resume, restart
   (hold), settings (comfort vignette, **turn speed** - Gentle 90, Calm
   120, Brisk 180 (default), Full 240 deg/s: how fast the view may turn -,
   volumes, haptics, seated mode, handedness, recalibrate, recenter), how
   to fly, quit to menu (hold). Quit on the main menu is a hold too.
   Hold **A/X** 1 s to recenter, **Y** 1.5 s to recalibrate your arms.

### Desktop controls (development; the same wing input as the headset)

| Key | Action |
|---|---|
| Space | flap (hold; mouse wheel = stroke size) |
| W / S | wrists leading-edge down / up (speed / balloon) |
| A / D | bank left / right |
| Q / E | one-wing stroke (left / right) |
| Shift | tuck (dive) |
| Ctrl / X | arms swept back / forward |
| Mouse | look around (click to capture) |
| Esc | pause menu; the mouse clicks menus |

On the desktop the lesson cards and How to fly name these keys. Held, S
(full nose-up) balloons and then stalls, as in the headset with the wrists
twisted all the way.

## Running it

Godot 4.7.2 must be on the path (`godot`).

```bash
# Desktop (keyboard/mouse)
godot --path . --xr-mode off --rendering-method forward_plus
# Meta XR Simulator (macOS; queues on a lock so parallel runs wait)
tools/xr.sh 120 res://scenes/main.tscn
```

On this Mac always add `--rendering-method forward_plus` to desktop runs
that you look at: the Mobile renderer (the one the Quest uses) paints
magenta tiles under MoltenVK.

### Quest (Pro, 2, 3)

```bash
# Debug APK (gradle build). One-time setup: the Android build template in the
# export sandbox, and optionally NDK 29.0.14206865 - docs/INTEGRATION.md §6
# has the exact commands (the verified path keeps gradle from downloading
# SDK parts on its own). The script exports on the tree's own project.godot
# and checks the build's settings.
tools/export_quest.sh debug "$PWD/build/soaring-quest.apk"
adb install -r build/soaring-quest.apk
adb shell am start -n com.soaring.game/com.godot.game.GodotAppLauncher
adb logcat -s godot:V
```

On a Quest (and in the Meta XR Simulator, which reports a Quest Pro) the
game picks its Quest quality tier by itself (28 NPC birds instead of 60,
and a safety valve that thins the sky if frames drop). On a first launch
Play asks for the wing calibration first (spread your wings and hold
still, or B/Y to fly with the default wings).

## Verifying it

Always run Godot through `tools/gd.sh <sandbox>` (a private copy of the
project and its own `user://`), never on the shared tree. Run the UI suite
(`--suite=unit/ui/`) **without** `--fixed-fps`: several of its tests
(ui_flow, ui_pointer, ui_perf's how-to animation) wait on wall-clock time
and fail under a fixed frame rate (182/193 with it, 193/193 without).

```bash
# The whole game, end to end (~6-8 min with --fixed-fps 72: the core loop
# with real flight, the sky from the player's eyes and its hunts, the first
# launch, water, depth precision, the brief's pacing through real flight
# on stored whole runs, ...)
tools/gd.sh integ --headless --fixed-fps 72 res://tests/runner.tscn -- --suite=unit/integration/ --fresh-settings
# The brief's pacing through the real game: a batch of whole runs played by
# a competent person model through the real chain, both quality tiers
# (~40 min at four at a time; then merge into the stored evidence)
tests/shots/integration_pacing.sh <batch> --seeds="5 11 17 23 29 31 37 41" --tiers="full quest" --minutes=35
python3 tests/shots/integration_pacing_merge.py artifacts/integration/pacing/<batch> --evidence=tests/unit/integration/data/real_pacing.json
# Six whole runs to the apex: steady nodes/objects, memory flat at the end, no errors (~5.5 min)
GD_TIMEOUT=2000 tools/gd.sh integ_soak --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/soak --suite=integration_soak --fresh-settings
# One area's suite (flight, vr, world, birds, ai, game, ui, audio, core)
tools/gd.sh flight --headless res://tests/runner.tscn -- --suite=unit/flight/
# The composed game in the XR simulator (a first launch, the Quest tier):
# controller-driven menu, the calibration gate, flaps, fps, draw calls
tests/shots/integration_sim.sh --tag=mobile
# Screenshots of the key moments / per-system CPU and draw calls
tools/gd.sh integ --rendering-method forward_plus --resolution 1280x960 res://scenes/main.tscn -- --harness=shots --fresh-settings
tools/gd.sh integ --headless --fixed-fps 72 res://scenes/main.tscn -- --harness=perf --perf=cpu --fresh-settings
```

Reports land in `artifacts/tests/report_*.json`; evidence in
`artifacts/<area>/` (the whole game's in `artifacts/integration/`). A run
is clean when it prints no `SCRIPT ERROR`, `ERROR` or `WARNING` lines other
than the engine's known exit messages (`1 ObjectDB instance was leaked at
exit`, and in simulator runs the OpenXR spatial-entity disconnect and
InteractionProfile RIDs).

## Layout

| Path | What |
|---|---|
| `scenes/main.tscn`, `scripts/main.gd` | the game: composition and startup |
| `scripts/<area>/`, `scenes/<area>/` | flight, vr, world, birds, ai, game (loop), ui, audio, core |
| `scripts/integration/` | loading card, menu sounds, Quest quality tier |
| `tests/unit/<area>/`, `tests/soak/`, `tests/sim/`, `tests/shots/` | suites, soak, simulator harnesses, evidence tools |
| `tools/gd.sh`, `tools/xr.sh` | the only way to run Godot here |
| `docs/` | design, architecture, per-area docs, research, integration |

Assets and credits: `docs/CREDITS.md`.
