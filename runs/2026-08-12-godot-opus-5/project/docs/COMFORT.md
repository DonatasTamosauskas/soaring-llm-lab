# Soaring — what the game does to a person wearing it

Everything between the bird's motion and the player's body: what their hands
feel, how fast the world is allowed to rotate, what happens when the trackers
stop reporting, and what the first sixty seconds are like for somebody who has
never done this before.

Three plain objects carry all of it, for the same reason `FlightModel` is a
plain object: comfort claims are testable claims, and testing them by putting a
headset on is slow, unrepeatable, and depends on which day it is.

| | |
|---|---|
| `scripts/player/Haptics.gd` | the haptic mixer: cues, textures, priority, rate limiting |
| `scripts/player/ViewComfort.gd` | view yaw, horizon roll, the vignette, and physical turning |
| `scripts/flight/WingInput.gd` | (existing) the gesture sensor, plus tracking loss and first contact |
| `scripts/game/FirstContact.gd` | a novice's first session, flown headlessly |
| `tests/test_comfort.gd` | 17 tests over the first three |
| `tests/firstcontact.sh` | the gate for the fourth |

---

## 1. Rotation is what makes people ill

Not speed. A bird flying flat out in a straight line is comfortable for almost
everybody; the same bird in a 70-degree turn is not, because the eyes report a
spin the inner ear cannot feel. Every comfort knob in the game is some way of
spending visual fidelity to buy that spin down.

**VIEW TURNING** (comfort screen, `Tuning.turning_comfort`) has three settings:

- **SMOOTH** — the view is exactly the bird's heading. The default, and what
  most people want.
- **EASED** — rate limited. The view chases the heading at
  `EASED_RATE + EASED_CATCHUP × lag`, so a violent turn is smeared out over the
  following moment. The lag is bounded by construction: at a steady turn rate
  `H` it settles at `(H − EASED_RATE) / EASED_CATCHUP` radians, about 13 degrees
  at this bird's hardest turn, and it converges to zero whenever the turn stops.
  A heading that *teleports* (a respawn) is taken instantly rather than eased
  through, which is what `EASED_GIVE_UP` and `snap_to()` are for.
- **STEPPED** — the view only ever sits on whole multiples of `STEP` (18
  degrees). There is no smooth rotation to be sick about at all. The steps are
  not blinked — at four a second a blink is a strobe — the periphery is masked
  continuously for as long as the heading is moving, so the jumps happen inside
  an aperture that is already narrow.

**HORIZON ROLL** shows a fraction of the bank (0.35 by default). Full 1:1 roll
is the most thrilling and the most nauseating.

**COMFORT VIGNETTE** closes with speed, with bank, and with view yaw rate — the
three moments the eyes and the inner ear disagree most.

### The vignette was broken for its whole life

It measured distance in the quad's own UV. The quad is a 1.6 m square held
0.32 m from the eye, so a camera only ever sees the middle two thirds of it, and
the entire darkening lived outside the frame. Forced to full strength and
photographed, the frame was unchanged. It now measures `SCREEN_UV` — the eye's
own viewport, in both eyes, at any aspect ratio — and the aperture radius comes
from `ViewComfort.aperture()`, so "at nought the view is unobstructed" and "at
the strongest the game goes, the corners are solid" are assertions rather than
something somebody once looked at.

`/tmp/soaring-vig-default.png` is what 39 m/s looks like at the default setting.

---

## 2. Haptics have a vocabulary

Godot gives you one number per hand. `Haptics` turns that into something a
player can read without looking, using the three channels a rumble motor
actually has:

- **Envelope** — a short list of ramps. A wingbeat swells and fades; a collision
  cracks and stops; a catch is two quick bites; a promotion is three rising
  ticks.
- **Frequency** — low is soft and bodily (wingbeat 62 Hz, being caught 42 Hz,
  lift 55 Hz), high is sharp and mechanical (a strike 165 Hz, claws on bark
  210 Hz, a recentre 240 Hz).
- **Duration** — everything is under `MAX_CUE_SECONDS`, and being caught is the
  only cue allowed a third of a second.

`ComfortTests._test_the_cues_are_tellable_apart` plays every cue on its own and
fails if any pair is close in all three.

**Textures** are states rather than events — riding a thermal, stalling. They
*throb*: most of every cycle is silence, they never exceed a quarter amplitude,
and they are the first thing dropped when the hands have been busy. A continuous
vibration stops being information within about ten seconds and becomes fatigue
for the rest of the session; a test holds every texture and every event at
maximum for twenty seconds and fails if the hands are busy more than 75 % of it
or never get a gap longer than a tenth of a second.

Two more rules worth knowing before adding a cue:

- **Priority.** A wingbeat never interrupts the rumble of being eaten. What
  happened *to* you outranks what you were doing.
- **One beat, one thump.** `WingInput.flap_pulse` is true for every frame of a
  downstroke, so `BirdPlayer` fires on the leading edge only, and the cue's own
  `interval` is longer than a stroke as a backstop.

Asymmetry is passed through: a one-winged beat is felt in that wing, because a
game that disagrees with the player's own body about which arm just worked is a
game they stop trusting.

---

## 3. Buttons

The action map is Godot's stock one; these are the only things read.

| gesture | what it does |
|---|---|
| squeeze either grip | cling: raises the speed at which arriving at a branch is a landing rather than a crash, from 5 to 9 m/s |
| hold both triggers, 1.2 s | recentre: relearns your neutral wrist angle and reach, and turns the world to face your shoulders |
| menu button / B / Y | pause, and back out of a menu |
| trigger / A / X | press whatever the pointer is on |

The recentre gesture is one-shot per hold, so a player who rests their fingers
on the triggers re-trims once rather than once a second. It is the same
implementation the RECENTRE MY WINGS row uses. That row used to also call
`XRServer.center_on_hmd`, which recentres on the player's *head*; doing both
turned the world twice, and recentring on where somebody happens to be looking
is not what "face forward" means to a bird whose wings are its arms.

---

## 4. Turning around in your room

A player in a swivel chair ends up facing 90 degrees away from their bird. Their
bank control still works — it reads the roll of the hand line and is yaw
invariant — but their wings now point across the direction of flight, which
looks wrong and feels worse.

`ViewComfort.update_reorientation()` eases the tracked rig around to meet them,
at 8 degrees a second, which is below the rate at which a rotation is noticed as
motion at all. Three things keep it from ever firing when it should not:

- It is measured from the **wing line**, not the head. Looking over your
  shoulder at a bird you are chasing is not turning around, and costs nothing.
- A **55-degree dead band**. An asymmetric posture — one hand held further
  forward, which is also this game's pitch control — is worth about 12 degrees.
- A **three-second dwell**. A glance ends; sitting sideways does not.

The correction goes on `XROrigin3D`, not on the view rig above it: the player's
own body hangs off the view rig and has to keep pointing where the bird is
actually flying.

---

## 5. Tracking loss

Holding the last good command is the right answer for a blink of lost tracking
and the wrong answer for a controller put down on a table mid-turn: the bird
keeps whatever bank it had, which is a spiral, and spirals end in the ground.

After `TRACKING_GRACE` (0.35 s) the wings level themselves, open, and settle to
trim — the attitude a real bird falls into when it stops doing anything, and the
one a player can be handed back in mid-air without a surprise. The HUD says
`TRACKING LOST — the wings are gliding themselves`, above even the folded-wings
warning, because a bird that has stopped answering the controls and says nothing
is a game that has crashed as far as anyone wearing a headset can tell.

---

## 6. First contact

A player who has just put a headset on holds two controllers about 25 cm apart
and waits to see what happens. That posture used to read as *wings fully
folded*, which is a power dive: `tests/hands.sh` at 0.10, 0.25 and 0.40 m put
the bird in a field within seconds and left it there for 90 % of the run, every
time.

A tuck is something you **do**. Until the player has opened their arms once
(`SPREAD_DEMONSTRATED`, 0.55 m of separation) the wings cannot fold below
`NOVICE_MIN_SPAN` (0.80). One spread is enough, it happens the instant anybody
follows the first instruction, and after it the tuck is a full control again.

`tests/firstcontact.sh` is the gate. It flies the real game through the real
sensor with a synthetic novice who sits still for three seconds, then reads each
of the coach's four lessons and performs it late and badly — a 0.62 m spread
rather than a full arm-span, a 1.8 m/s wingbeat rather than the 3.5 m/s one the
flight tests use — and it checks that each lesson's promise is true:

```
  taught in       21.7 s
  gliding         3.10 m/s down
  beating         1.00 m/s down over 6.0s     <- "beat your arms down — climb"
  one hand down   71 degrees in 3s            <- "drop one hand — turn that way"
  hands together  +10.5 m/s                   <- "hands together — tuck and dive"
  then flying     -16 m over 37s
  lowest wings    0.80 while resting
```

Two findings came out of building it:

- **A timid wingbeat does not climb; it cuts the sink by two thirds.** Thrust
  goes as the square of hand speed, so a first attempt at half the speed of a
  committed beat has a quarter of the thrust. The probe asserts the sink is at
  least halved rather than asserting a climb, because that is what is true. A
  player who beats properly climbs.
- **The tutorial did not fit in the sky.** Four lessons cost about 70 m of
  glide, and the dive lesson spends another 50 m. At the old 95 m spawn a player
  following the game's own instructions reached the last lesson at treetop
  height and finished it in a field. `Main.SPAWN_ALTITUDE` is now 190 m, which
  leaves a first session about a minute of air to be wrong in.

---

## 7. Running it

```bash
./tests/run.sh                                    # includes ComfortTests
./tests/firstcontact.sh                           # the first-session gate
./tests/hands.sh                                  # still a diagnostic; see the header
godot -- --xrdiag=1                               # live input, against the simulator
godot --xr-mode off -- --menu=settings --capture=/tmp/c.png --capture_delay=6
godot --xr-mode off -- --probe=1 --capture=/tmp/v.png --capture_delay=21   # the vignette at 39 m/s
```

`--xrdiag=1` now also reports whether the grip and both-trigger gestures are
reaching the game, so "I squeezed it and nothing happened" has a line to point
at.

---

## 8. What is not verified

Nothing here has been felt. There is no Quest on this machine, so every haptic
cue is an envelope that compiles and a set of assertions about its shape, and no
button has been physically pressed on this build — the action names resolve and
are read every frame at 72 fps against the Meta XR Simulator, which is as far as
that can be taken without hardware. The panel distances, the reorientation rate
and the vignette strength were all judged from monoscopic captures on a monitor,
and headset panels are dimmer and lower contrast than a monitor.
