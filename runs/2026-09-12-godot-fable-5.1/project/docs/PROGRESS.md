# Progress log

## Session 1 (2026-09-12, 00:20 – paused 08:20 at the user's request)

### Done and verified
- **XR bootstrap** (`scripts/core/XRBoot.gd`, `project.godot`): OpenXR on,
  Vulkan pinned on macOS (Godot's Metal default does not interoperate with the
  simulator's Vulkan compositor). Verified against the running Meta XR
  Simulator: session reaches FOCUSED, 72 fps, both Touch controllers report
  poses (`[Main] ... L=(-0.291, 1.4, -0.5)(true) R=(0.291, 1.4, -0.5)(true)`).
- **Flight core** (`scripts/flight/`): `FlightModel` (lift/drag, stall,
  tuck, wingbeats, size scaling), `FlightCommand`, `WingInput` (controllers →
  command: spread, wrist-tilt attack, aileron roll, hand-drop bank,
  amplitude-gated wingbeats, neutral calibration, reach learning),
  `KeyboardWings` (desktop fallback).
- **Player** (`scripts/player/BirdPlayer.gd`, `scenes/Player.tscn`):
  CharacterBody3D driven by the model, perch/launch/crash handling, XR origin
  yaws with heading and rolls a comfort fraction of the bank.
- **Test harness** (`tests/`): `tests/run.sh` → `ALL PASS (87 assertions)`
  across `test_flight.gd` (glide ratio, lift ⟂ flow, coordinated turn rate
  within 15 % of g·tanφ/V, stall + recovery, dive/zoom, flapping climbs,
  terminal velocity, size ordering, NaN resistance, yaw flick, basis) and
  `test_wing_input.gd` (every gesture, jitter rejection, calibration, hostile
  input).
- **Capture pipeline** (`scripts/core/Capture.gd`, `DevScene.gd`): `--capture`
  works in XR (mirror camera) and desktop; verified PNGs at /tmp/soaring_xr1.png
  and /tmp/soaring_desk.png. Live simulator glide logged via `--flightlog`.
- **Contract for parallel work**: `docs/ARCHITECTURE.md` (directory ownership,
  APIs each area must expose), `docs/FLIGHT.md` (gesture table + physics).

### Not started
World building, bird art, enemy AI/ecosystem, game loop/progression, UI/menus,
audio, VR comfort settings, integration into `Main.gd`. The plan was a
Workflow (ultracode) with six parallel area agents building against
`docs/ARCHITECTURE.md`, each with a dev scene + headless suite + screenshot,
then an integration agent wiring `Main.gd` and running the whole game in the
simulator, then a review/fix round. The simulator is reserved for integration
(one session at a time); area agents use `--xr-mode off` captures.

### Open tuning notes
- Reference bird retuned to mass 1.6 kg / area 0.19 m² so size-1 cruise is
  ~13 m/s (was 9, felt slow in the headset). Envelope: size 0.5 trim 11.3,
  1.0 → 12.9, 2.0 → 14.9, 3.5 → 16.6 m/s. Stall 9.6 m/s at size 1.
- In the simulator the hands sit at ±0.29 m and never open, so `WingInput`
  stays uncalibrated and forces wings open — a deliberate rule (hands together
  before ever opening the arms is not a dive). Real flapping needs a VRS
  session recording (Session Capture) or the data-forwarding server with real
  controllers; automated XR gesture tests should use `player.command_source`.
- `.godot/global_script_class_cache.cfg` is not refreshed by CLI runs: after
  adding a `class_name`, run `godot --headless --path . --import`.

### How to run
```
tests/run.sh                                   # headless suites
godot --path . -- --quit_after=12 --flightlog  # fly in the Meta XR Simulator
godot --path . --xr-mode off -- --capture=/tmp/x.png --capture_delay=3 --quit_after=5
```
