# Soaring

A VR game about being a bird. You fly by actually flying: beat your arms to
climb, tilt the line between your hands to bank and turn, tuck your wings to
dive, spread and flare to trade that speed back for height. Catch birds smaller
than you, avoid the ones that are bigger, and grow.

Godot 4.7, OpenXR, tested through the Meta XR Simulator.

## The flight model

Flight is a real lift/drag simulation, not a bag of impulses, and that choice
drives almost everything else:

- **Lift acts perpendicular to the airflow**, so it does no work. Energy
  exchange between altitude and speed falls out for free — a dive genuinely buys
  speed and a pull-up genuinely spends it. The test suite pins this to within 2%
  over 20 seconds of banked flight.
- **Turning is not scripted.** Banking tilts the lift vector sideways, the
  sideways force curves the velocity, and the heading follows. A coordinated
  turn emerges from the same equations that hold the bird up, and lands within
  tolerance of the textbook `ω = g·tan(φ)/V` on its own.
- **Size changes handling, not just scale.** Mass and wing area grow at
  different rates, so wing loading climbs: big birds cruise faster and turn in
  wider arcs, small birds are slow but nimble. The size/agility tradeoff *is*
  the chase game rather than something layered on top of it.
- **Stalling is real and recoverable.** Hold too much angle of attack and lift
  collapses while drag explodes. Lower the nose and fly out of it.

`FlightModel` and `WingInput` are plain `RefCounted` objects with no scene
dependencies, which is what lets the entire core mechanic be exercised headless.

## Flying it

| Gesture | Effect |
| --- | --- |
| Beat both arms down | Thrust. One beat per arm-raise — you must lift your arms |
| Drop one hand | Bank and turn toward that hand |
| Roll your wrists back / sweep arms back | Nose up, flare, slow down |
| Roll your wrists forward / push arms ahead | Nose down, speed up |
| Bring your hands together | Tuck the wings and dive |
| Beat one wing harder | Yaw flick — for threading a branch with no room to bank |
| Flap while perched | Launch |

The wings calibrate to you in the first second: it learns your reach and the
angle you naturally rest your wrists at, so "level" means level *for you*.

Desktop fallback (no headset): `W`/`S` pitch, `A`/`D` bank, `Space` flap,
`Shift` tuck, mouse to look, `F1` for the flight debug readout.

## Running it

```bash
godot                       # play (uses the active OpenXR runtime)
godot --xr-mode off         # desktop flight test mode
```

macOS note: `project.godot` pins the Vulkan rendering driver. Godot 4.7 defaults
to Metal there, which does not interoperate with the Meta XR Simulator's Vulkan
compositor — the session comes up and then dies inside Metal texture-view
validation.

## Verifying it

Three layers, all runnable from a terminal without a headset. This matters more
than usual here: flight feel is invisible to a compiler, and iterating on it by
repeatedly putting a headset on is slow and unrepeatable.

```bash
tests/run.sh      # 549 assertions: aerodynamics, input mapping, growth rules
tests/probe.sh    # flies the real game through the real world and checks it
godot -- --xrdiag=1   # what the live headset and controllers actually report
```

**`tests/run.sh`** — pure, headless, ~0.7 s. Covers the aerodynamics (energy
conservation, glide polar, dive/zoom exchange, stall recovery, coordinated turn
rate, terminal velocity, NaN resistance), the input mapping (every gesture, plus
that shaking the controllers earns you nothing), and the growth curve.

**`tests/probe.sh`** — flies the actual game: real colliders, real game manager.
Glide, climb, dive, zoom, hard turn, crash into a hillside, land, launch, catch a
bird, get caught. This is the layer that caught respawn burying the player
underground.

**`--xrdiag=1`** — prints live OpenXR poses and what the wing sensor makes of
them. A mapping that is correct against invented data and wrong against real
data looks fine in every test and is unflyable in the headset; this closes that
gap. It is how the two calibration bugs below were found.

Also useful:

```bash
godot --headless --xr-mode off --script res://tests/flight_report.gd
```

Prints the flight envelope as numbers — glide polar, turn radius by bank angle,
what one flap buys, the dive-and-zoom round trip, and how growth changes the
bird. The test suite answers "is it correct?"; this answers "is it fun?".

```bash
godot -- --capture=/tmp/shot.png --capture_delay=8
```

Photographs the running game. Under XR it renders through a mirror camera pinned
to the headset, because the real XR viewport is submitted straight to the
compositor and reads back black.

## Things the simulator caught that the tests could not

Both were invisible to the headless suites because both were about the gap
between invented poses and real ones — and both are now covered by tests:

1. **Resting controllers read as 16.3° angle of attack, with the stall at
   17.2°.** Assuming "controller upright = wings level" is a guess, and the wrong
   guess spawns the player permanently stalled with no visible cause. Neutral is
   now measured, not assumed.
2. **Wingspan calibration took four seconds to converge**, during which the
   wings read as tucked and the bird dived. Reach is now acquired immediately.

## Layout

```
scripts/flight/    FlightModel, FlightCommand, WingInput   — no scene deps
scripts/player/    BirdPlayer, WingVisual, FlightAudio
scripts/world/     WorldBuilder, GeometryBatch
scripts/ai/        BirdNPC — flies the same model the player does
scripts/game/      GameRules, GameManager, Main, FlightProbe, XRDiagnostic
tests/             headless suites and the flight envelope report
```

The world is seeded and reproducible, because flight tuning is only meaningful
if the obstacle course stays the same between runs. Geometry is batched per
structure so a dense forest stays affordable at 90 Hz per eye; anything a bird
would land on gets a collider, and anything it would brush through — foliage,
window glass — deliberately does not.
