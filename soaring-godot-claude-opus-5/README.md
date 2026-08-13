# Soaring

A VR game about being a bird. You fly by actually flying: beat your arms to
climb, tilt the line between your hands to bank and turn, tuck your wings to
dive, spread and flare to trade that speed back for height. Catch birds smaller
than you, avoid the ones that are bigger, and grow.

A run starts you as a falcon-sized **HUNTER** with five lives, and ends when you
become the **SOVEREIGN** of the sky or when the fifth thing bigger than you
catches up. In between you climb a ladder of ranks, and every promotion but the
last visibly rebuilds you as a bigger bird.

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
| Squeeze a grip | Cling on: lets you land on a branch at nearly twice the speed |
| Hold both triggers | Recentre — re-trims your wrists and turns the world to face you |
| Menu / B / Y button | Open the menu — point with either hand, trigger to press |

The wings calibrate to you in the first second: it learns your reach and the
angle you naturally rest your wrists at, so "level" means level *for you*. Until
you have opened your arms once the wings cannot fold at all — holding two
controllers near each other is what everybody does before they know anything,
and it used to be a power dive.

Your hands are told what is happening to you. A wingbeat is a soft low thump in
the arm that did the work, a catch is two quick bites, a collision is a crack
with no swell, claws finding bark is a high click, and riding a thermal is a slow
throb under both hands that is silent two thirds of the time. Nothing is ever a
continuous buzz, and a wingbeat never talks over the rumble of being eaten.

Desktop fallback (no headset): `W`/`S` pitch, `A`/`D` bank, `Space` flap,
`Shift` tuck, mouse to look, `Escape` for the menu, `F1` for the flight debug
readout.

Nothing has to be discovered from a manual. The first time you fly, the game
asks for one gesture at a time — spread, flap, bank, tuck — and each prompt goes
away the moment you do it; it never comes back once you have shown it all four.

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

Five gates and a shelf of instruments, all runnable from a terminal without a
headset. This matters more than usual here: flight feel is invisible to a
compiler, and iterating on it by repeatedly putting a headset on is slow and
unrepeatable.

```bash
tests/all.sh           # every gate below, failing on any of them (~2 min)
tests/all.sh --quick   # the four fast ones, skipping the ten-minute hunt (~50 s)

tests/run.sh           # 10634 assertions: aerodynamics, input, growth, world,
                       #   palette, birds, progression, flock, UI, comfort, audio
tests/probe.sh         # flies the real game through the real world and checks it
tests/ui.sh            # opens the real menu and presses it: 35 checks
tests/firstcontact.sh  # somebody's first session: holds the controllers still,
                       # reads what the game says, and tries it badly
tests/hunt.sh          # ten minutes of real hunting; the only gate that can see
                       # whether a chase ever converts
godot -- --xrdiag=1    # what the live headset and controllers actually report

godot --xr-mode off --script res://tests/vista.gd -- --out=/tmp/v --sky=evening
                       # photographs the world from a dozen fixed viewpoints,
                       # at any hour of the day
godot --xr-mode off --script res://tests/aviary.gd -- --out=/tmp/a
                       # photographs the birds: every silhouette, the size
                       # ladder, one wingbeat frame by frame, the threat tints
                       # at the range they have to work at, and a flock of real
                       # NPCs flown by their own AI first

godot --headless --xr-mode off --script res://tests/ecosystem.gd -- --minutes=8
                       # runs the sky with nobody in it and reports what the
                       # flock did: catches, roosting, thermals, anything stuck
godot --xr-mode off --script res://tests/wildlife.gd -- --out=/tmp/w
                       # photographs it: a bird on a wire, a bird circling in
                       # lift, a chase, the tightest group in the sky

godot --headless --xr-mode off --script res://tests/audio_report.gd
                       # what the game sounds like, in numbers — and
                       # `-- --wav=/tmp/soaring` writes the clips out for ears

godot --xr-mode off -- --menu=settings --capture=/tmp/m.png --capture_delay=6
                       # photographs a menu screen: main | pause | settings |
                       # controls (the summary comes from --demo=ended)

godot --headless --xr-mode off --script res://tests/session_report.gd
                       # the difficulty curve: 200 simulated runs per skill
                       # level, time to each rank, catches, deaths, win rate

godot --headless --xr-mode off --fixed-fps 90 -- \
      --hunt=1200 --hunt_evade=1 --hunt_endless=1
                       # an autopilot hunts the real game for twenty minutes and
                       # reports the rates the simulation is calibrated against

godot --xr-mode off -- --demo=ended --capture=/tmp/x.png --capture_delay=9
                       # photographs a HUD state that only happens mid-run:
                       # catch | caught | rank | ended | won | restart

godot --xr-mode off -- --diag=1 --capture=/tmp/x.png --capture_delay=9
                       # draw calls, primitives, frame rate, where the rig is,
                       # and how close the flock is in degrees of visual angle
```

Each gate is blind to what the others see, which is why `tests/all.sh` exists:
with the menu's pause broken outright only `ui.sh` noticed, and with the hunting
rules reverted to the state that caught nothing in ten minutes only `hunt.sh`
did.

**`tests/run.sh`** — pure, headless, ~23 s, most of which is three minutes of
simulated ecosystem and eight seconds of rendered audio. Covers the
aerodynamics (energy conservation, glide polar, dive/zoom exchange, stall recovery, coordinated turn
rate, terminal velocity, NaN resistance), the input mapping (every gesture, plus
that shaking the controllers earns you nothing), the growth curve, and the
shape of the world — that the arena is closed by terrain on every bearing, that
nowhere inside it is more than 200 m from something worth looking at, and that
both still hold at four different seeds. It also holds the art direction to its
own rules: one palette with nothing invented outside it, shapes that still read
in greyscale once the haze has taken their colour, the ground published in the
colour space the GPU consumes, and air thick enough to actually see (see
`docs/ART-DIRECTION.md`). Finally it holds the birds to what makes them
readable: the size ladder is ordered so that growing never makes a bird look
smaller, no mesh is inside out, a wing cannot tear itself open mid-beat, the
downstroke is quicker than the recovery, a beat that starts finishes, and the
whole twenty-six bird flock still costs exactly one material.

It holds the catch rule to a shape as well as a distance: that a strike is aimed
(on the nose connects, ninety degrees off does not, and the boundary is where
the constant says it is), that reach at a real 60 m/s closing speed is still
under a big bird's own wingspan rather than only bounded at a standstill, and
that a bird which is not flying is not hunting — a perched player used to eat
anything smaller that drifted within five metres of it, from any direction, and
so did every roosting bird in the flock.

And it listens to the game. `AudioTests` asserts on the samples the synthesiser
actually produces: that wind rises monotonically with airspeed and a dive is
many times a glide, that a tuck is thinner, that a wingbeat is a transient that
ends rather than a level, that a stall shakes at the buffet rate and not at some
slow swell, that nothing in the game clips, that a poisoned frame cannot silence
it for ever, and that you can hear what is about to eat you. See
`docs/AUDIO.md`.

It also runs the flock. [AITests] rigs two birds and measures one manoeuvre at a
time — that a hunter climbs before it stoops rather than beelining, that it gives
up when it is getting nowhere, that prey runs for the ground instead of climbing
away, that a wingbeat costs reserves and gliding pays them back, that a branch
belongs to one bird, that a roost scatters when something that eats birds arrives
— and then runs a whole flock over the real world with no player at all and
asserts on what the sky did: nothing non-finite, nothing outside the world,
nothing going nowhere twice running, birds eating each other, birds landing,
birds circling in lift and getting height out of it. See `docs/ECOSYSTEM.md`.

**`tests/ui.sh`** — opens the real menu in the real game and presses it with a
real ray: that the game opens on a menu at all, that FLY hands back the sky,
that pausing genuinely stops the world (the bird moves less than a millimetre
across half a second of paused frames), that a comfort setting reaches `Tuning`
while the game is still running, and that FLY AGAIN starts another run. See
`docs/UI-AND-FLOW.md`.

**`tests/firstcontact.sh`** — the first sixty seconds of somebody's first
session, flown headlessly through the real sensor and the real coach. They sit
still for three seconds, then perform each lesson late and clumsily, and it fails
if the tutorial does not finish, if any of its promises turn out to be untrue
("beat your arms down — climb" had better change the sink), or if following the
game's own instructions leaves them on the ground. It is where the spawn
altitude came from. See `docs/COMFORT.md`.

**`tests/probe.sh`** — flies the actual game: real colliders, real game manager.
Glide, climb, dive, zoom, hard turn, crash into a hillside, land, launch, catch a
bird, get caught. This is the layer that caught respawn burying the player
underground.

**`tests/hunt.sh`** — the only gate that can see the hunting rules at all. An
autopilot flies ten minutes of the real game and has to come back with meals:
six catches at twenty percent conversion as it stands, two required. Reverting
`GameManager`'s awareness constants to the state that measured *zero catches in
ten minutes* leaves every other gate green and fails this one. Ten minutes
rather than four because the first catch takes about three: the autopilot starts
at size 1.0 with a thin speed advantage over anything it can eat, and the run
accelerates as it grows.

There is no automated Forward Mobile check, and there cannot usefully be one on
this machine: the project already renders through Forward Mobile everywhere, and
macOS/MoltenVK paints spurious magenta tiles into live frames, so a check for
Godot's invalid-material magenta would fail on platform noise. The equivalent
verification is `tools/deploy_quest.sh` and reading `[diag]` back off the
device. See `docs/PARKED-quest-visibility.md`, which is still open.

**`--diag=1`** — draw calls, primitives, frame rate, where the rig is, and how
close the flock is in degrees of visual angle. That last one exists because
distance is the wrong unit for "can I see a bird": a bird's wingspan over its
distance is what decides whether it reads as a bird, a speck, or nothing, and a
sky whose nearest bird is 165 m away measures 0.48 degrees and looks empty.

**`--xrdiag=1`** — prints live OpenXR poses, the buttons this game binds, and
what the wing sensor makes of all of it. A mapping that is correct against invented data and wrong against real
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

## The run

A session has a shape, and the numbers behind it are measured rather than
guessed. `SessionProbe` flies the real game on an autopilot and counts what
happens; `SessionSim` replays whole runs headlessly through the real
`GameSession`, `Progression` and `GameRules`, calibrated against those counts;
`ProgressionTests` asserts on the resulting curve.

| Rank | From size | What it is |
| --- | --- | --- |
| FLEDGLING | 0.35 | where a bad run puts you |
| HUNTER | 0.60 | where every run starts |
| RAIDER | 1.20 | a corvid |
| CORSAIR | 2.40 | a seabird |
| SOVEREIGN | 3.20 | the win |

The first four thresholds are exactly the size classes in `BirdMesh`, so a
promotion rebuilds you — and everyone else's read of you — as a different bird.

- **Escalation** is two separate levers: how often something above you spawns
  (7 % of the flock at the start, 22 % at the apex) and how much bigger it is
  when it does (1.2–1.75x early, 1.35–2.6x late). The sky is never allowed to run
  out of prey, or — while anything can still eat you — of predators.
- **Being caught** costs a third of your mass, your streak, your position and
  one of five lives. That is worth a little over one catch, which is the balance
  invariant the whole loop rests on and is asserted directly.
- **A streak** multiplies score up to 4x and is the only thing a death takes
  from you instantly.
- **The sky is dealt in two tiers.** Birds you can eat, and birds that can only
  stare at you, are placed 55–190 m away where they are large enough to read;
  predators still arrive from 140–420 m, because something that can eat you
  turning up forty metres off your wing is not a threat, it is an ambush you
  could not have avoided. Before that split the nearest bird in the sky measured
  0.48 degrees across and the game's central subject was invisible.
- **A strike has to be aimed.** The catch window is generous — up to 19.8 m for
  the biggest bird in a 60 m/s stoop, because a fixed hitbox at those speeds is
  a lottery decided by which physics tick you landed on — but it is a 44-degree
  cone off your own nose, and you have to be flying. A bird you dived at and
  connected with is inside it; one you slid past sideways at nine metres is not.
- **The curve**, simulated: an expert wins 92 % of runs with a median of 14
  minutes; a competent player 46 % at 17 minutes; a novice never, but still
  earns a promotion and a score. The autopilot, measured by `tests/hunt.sh` on
  the build as it stands, catches 0.70 birds a minute at 20 % chase conversion —
  a shade better than the "competent" column.

## Getting in and out

The game opens on a menu you look at and point at, and every menu in it is an
object standing in the sky rather than a layer stuck to your face — you can look
away from it, lean around it, and it stays where it was put. A full-screen panel
locked to the head is the fastest way to make someone in a headset want to stop.

Launch lands on **SOARING** (fly, how to fly, comfort, quit). The menu button on
either controller pauses mid-flight, and pausing genuinely stops the world — the
flock, the wind, the clock — while leaving the head trackers running, because a
frozen view over a moving head is the one thing in this codebase that will
reliably make somebody ill. Losing your fifth life raises a world-space summary
while the bird keeps gliding; a wingbeat or a button starts the next run. There
is no screen without a way out of it, and the test suite fails if one ever
appears.

Comfort settings — vignette strength, how far the horizon tips, whether the view
follows a turn smoothly or in steps, turn sensitivity, which hand points, whether
the prey marker is drawn — are reachable
from inside the headset and persist between sessions. They are declared once, in
`PlayerSettings.SPECS`, and the panel is built from that declaration; a test
reads `Tuning.gd` and fails if a setting names a knob that does not exist.
`RECENTRE MY WINGS` finally binds `WingInput.recentre()`, and so does holding
both triggers. The whole of it is in `docs/UI-AND-FLOW.md`, and what all of it
does to a person wearing it is in `docs/COMFORT.md`.

## Layout

```
scripts/flight/    FlightModel, FlightCommand, WingInput   — no scene deps
scripts/player/    BirdPlayer, WingVisual, FlightAudio
                   Haptics, ViewComfort — what the hands feel, what the eyes get
scripts/world/     WorldBuilder, GeometryBatch, Palette — every colour and light
scripts/art/       BirdMesh, BirdPose, BirdRig — every bird, and how it flaps
scripts/ai/        BirdNPC — one bird's brain; Flock — what the sky knows
scripts/game/      GameRules, Progression, GameSession — the run, as pure maths
                   GameManager, Main, FlightProbe, SessionProbe, MenuProbe
scripts/ui/        MenuModel, MenuLayout, PlayerSettings, Coach — no scene deps
                   GameMenu, MenuPanel, UIPointer, UITheme, HUD
scripts/audio/     Soundscape, SoundState — your own air, synthesised
                   VoiceBank, FlockAudio, AudioDirector — the sky's voices
tests/             headless suites, the flight envelope and the session curve
docs/              ART-DIRECTION, ECOSYSTEM, UI-AND-FLOW, COMFORT, AUDIO,
                   PARKED-quest-visibility (an open bug — leave it alone)
tools/             deploy_quest.sh
```

The world is a 620 m bowl — a town in the middle, four districts around it
(greenwood, spires, gorge, downs) and a 340 m mountain wall closing the horizon,
with more mountains behind it so there is nowhere to fly out to. It is seeded
and reproducible, because flight tuning is only meaningful
if the obstacle course stays the same between runs.

The ground is built on rings and spokes rather than a square grid, which sounds
like an implementation detail and is actually the difference between a mountain
and a defect: the wall climbs 340 m across 180 m of ground, and on the 15 m
square quads it used to have, every triangle on it was one quad wide and forty
long — the whole horizon rendered as a comb of vertical needles. Rings put the
resolution in the direction the ground is climbing (6 m on the wall, 15 m in the
bowl), which comes out as roughly square facets on a 65-degree face. Geometry is batched per
structure so a dense forest stays affordable at 90 Hz per eye; anything a bird
would land on gets a collider, and anything it would brush through — foliage,
window glass — deliberately does not.

The sky is inhabited rather than populated. Every NPC flies the same
`FlightModel` the player does and now pays for its wingbeats, which turns each
behaviour into a technique instead of a script: predators climb before they
stoop because height is the only speed they can afford, prey dives for the deck
because diving is free and because terrain really does break line of sight, and
everything looks for lift because lift is the only height nobody pays for. Birds
roost on the world's own perch points and get up again, scatter off a branch when
something that eats birds comes near, keep out of each other's way, and eat each
other whether or not anyone is watching. `docs/ECOSYSTEM.md` explains the whole
of it, and `tests/ecosystem.gd` runs it with no player in the world and counts
what happened.

It is lit as one thing: warm stone, cold air. A single low warm sun, a bright
blue fill carrying the half of the rim that is always backlit, and exponential
haze tuned so a bird 40 m ahead stays crisp while the mountain wall at 900 m
reads as mass and the massif behind it reads as air. That haze is the main cue
for how high and how fast you are. Every colour, material, light and atmosphere
value in the game comes from one place, `scripts/world/Palette.gd`; the
reasoning is in `docs/ART-DIRECTION.md`, and `--sky=morning|noon|evening`
switches the hour.

## The birds

Every bird in the game — the flock, and the body and wings the player wears — is
built out of `scripts/art/BirdMesh.gd`: a faceted low-poly loft with a head, a
hooked bill, a keeled body, tucked feet, a fanning tail of separate feathers and
a two-part wing with layered coverts, scalloped secondaries and splayed
primaries.

There are five silhouettes and **a bird's size class chooses which one it
wears**: swift, falcon, corvid, seabird, eagle, with the count of splayed
"fingers" at the wingtip going 0, 2, 3, 4, 5 up the ladder. That is a gameplay
decision rather than a decorative one — you have to judge edible-or-dangerous in
a fifth of a second against a shape whose distance you cannot know, and apparent
size alone cannot carry that. The threat tint is the second cue, not the only
one — cyan means you can eat it, red means it can eat you. Cyan rather than the
obvious green because green is the one colour this world is full of: a green
bird against a green hillside at forty metres was simply not there, while the
red one was obvious against everything, and that is half a signal. It also
happens to be the one pair of hues a red-green colourblind player can tell
apart, which "green means eat" never was. Growing across a class boundary
rebuilds the player as the next bird up, their own wings included.

The flap cycle (`scripts/art/BirdPose.gd`) is pure maths with no scene
dependencies, for the same reason the flight model is: the downstroke takes 38%
of the cycle and the recovery the rest, so the wing snaps down and drifts back
up; the wrist folds on the way up and not on the way down; a beat that starts
finishes even after the command stops. Everything else is the flight state
directly — span folds the wings, bank draws the inner wing in and twists the
tail, angle of attack pitches the body and drops the tail as a brake. What you
see is what the bird is commanding.

It costs one material for the whole game. Plumage, threat glow and the wrist
flex are `instance uniform`s on a single shared shader, and meshes are built
once per species and shared, so a bird is four draw calls, ~170 triangles and
no new material at all.

## The sound

Nothing here ships an audio file; every sound in the game is arithmetic. Your
own air is synthesised a sample at a time so it can track the flight
continuously — trim to a full dive is a tenfold change in level and a brighter
one, tucking at a fixed speed is audible on its own, the land below fades out
from under you as you climb, a stall buffets at about 13 Hz before the HUD can
say so, and a thermal arrives as a low swell rather than as more noise.
Everything else — bird calls in five species and three moods, wingbeats heard
from outside, a catch, a collision, a promotion, the beds under the forest and
the town — is baked once at load and played positionally by the engine's own
mixer, so a sky full of birds costs the script side nothing.

The one claim it has to earn is that you can hear what is about to eat you: a
held air rush whose level is how close, how much bigger and how fast it is
closing, on the single most dangerous bird near you, and silent for anything
that cannot actually catch you. Measured at 1.65 % of one core with every layer
running at once. `docs/AUDIO.md` has the numbers and what is missing.

## Putting it on a Quest

```bash
tools/deploy_quest.sh
```

Builds, installs, launches and then *verifies*: every build is stamped with the
commit and the time, and the script refuses to claim success until it has read
that exact stamp back out of the device's own log. Deploying by hand once left a
fix sitting in a local file while the headset ran an older APK, and the "the bug
persists" that followed cost a whole session.

It needs `adb` on the path, a headset in developer mode with its controllers
awake (the launcher refuses to start otherwise, and the script says so), and
`JAVA_HOME`/`ANDROID_HOME` if yours are not where the script guesses. Afterwards:

```bash
adb logcat -s godot | grep -E "\[diag\]|\[Soaring\]"
```

which is the same diagnostic `--diag=1` prints on the desktop: draw calls,
primitives, frame rate, where the rig is, and how close the flock is.

**Nothing in this repository has ever run on a headset.** Every number in it was
measured on a desktop or against the Meta XR Simulator. The world is bigger and
its terrain is finer than it was, the flock is nearer, and the shadow and haze
settings that carry most of the look have never been seen through a real panel.
Run the deploy before believing any performance claim here, and read
`docs/PARKED-quest-visibility.md` first — that bug is still open.
