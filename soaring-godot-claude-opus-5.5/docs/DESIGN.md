# Soaring — game design brief

The product brief every area builds to. `docs/ARCHITECTURE.md` says *how the
code fits together*; this says *what the game must be*. Where the two disagree,
raise it — don't silently pick one.

## The pitch

Gorilla Tag's body-driven movement meets agar.io's eat-or-be-eaten growth, as a
bird. You are a small bird in a big, alive sky. You fly with your arms: flap to
climb, spread and tilt your wings to glide, bank and dive. You catch birds
smaller than you, avoid birds bigger than you, and grow — and as you grow the
world shrinks around you, your flight changes, and the birds that mattered
yesterday are beneath your notice.

## The prompt's requirements (non-negotiable)

1. **Movement is flapping the wings (controllers).** Flapping produces lift.
   The *direction* of that lift depends on the angle of the wings during the
   flap: wings held flat push straight up; wings pitched forward (leading edge
   down) push up **and forward**.
2. **Speed via angle of attack, like an aircraft.** Tilting both wings leading
   edge up raises angle of attack: lift jumps, the bird **balloons** upward
   temporarily, then bleeds speed and settles slower. Leading edge down: less
   lift, the nose drops, speed builds. Too much AoA stalls; stalls are
   recoverable.
3. **Turns via opposite tilts** — one wing's leading edge up, the other's down
   — acting like **ailerons with coordinated rudder**: the bird rolls into a
   bank and the heading follows without sideslip.
4. **Real aerodynamics inspired, tuned for play**: lift/drag from airspeed and
   AoA, gravity, energy trade between height and speed, stall. Numbers may be
   exaggerated for fun; the *relationships* must be real.
5. **Updrafts**: areas of rising air (thermals over sun-warmed ground, ridge
   lift on windward slopes/building faces) lift a gliding bird without flapping.
6. **World**: vast open spaces *and* intricate places that demand acrobatic
   flight — tree branches, open windows, electric poles and wires, tall
   buildings, nesting areas with tight airborne entrances; everything birds
   cling to.
7. **Core loop**: catch smaller birds, avoid bigger ones. NPCs do the same to
   each other (the ecosystem is alive with or without the player).
8. **Growth** changes flight characteristics and the loop itself: bigger birds
   fly faster and turn wider; the player stops caring about the smallest birds
   and starts caring about larger prey.
9. **VR first**, verified in the Meta XR Simulator; will be tested on a Meta
   Quest Pro later. Menus, pause, restart, controller help.
10. Low-poly art style.

## Flight — design intent

- **The wings are your arms.** Each controller is a wingtip; the line
  shoulder→controller is the wing. The bird's body frame comes from the
  player's wing geometry (forward = perpendicular to the left→right hand line,
  horizontal), not from where the head looks — you can look around freely
  while flying straight.
- **Inputs WingInput must read** (scale-free, calibrated to the player's reach):
  - *extension* per wing (0 tucked … 1 fully spread): wing area / tuck-to-dive.
  - *chord pitch* per wing (controller roll about the arm axis = wrist twist):
    leading edge up/down → per-wing angle-of-attack offset. Symmetric = pitch
    (speed control, balloon). Opposite = roll (ailerons) + auto rudder.
  - *arm dihedral* (one hand higher than the other) → also rolls: the natural
    "airplane arms" gesture must bank too.
  - *stroke velocity* per wing (hand velocity relative to head): a downstroke
    produces a force along the wing's normal, so wing pitch sets the lift
    direction (requirement 1). Upstrokes cost little (feathers open). One-wing
    flaps give a yaw/roll kick.
  - *sweep* (hands forward/back of the shoulders) may shift pitch trim.
- **Comfort**: the camera never pitches or rolls from flight. Only yaw
  (coordinated turning) and translation move the rig. A speed/turn-rate
  vignette (setting) softens optic flow. Turning is smooth, never snappy.
- **Size**: mass and wing area derive from the species ladder (SizeRules). Wing
  loading rises with size → bigger = faster cruise, higher stall speed, wider
  turns, more momentum; small = slow, floaty, nimble, hover-capable with hard
  flapping. The player's world_scale grows with wingspan so the world visibly
  shrinks as you grow.
- **Perching**: fly slowly into a perch (branch, wire, ledge) to cling; flap to
  launch. Perches fit only birds up to a wingspan.
- **Collisions**: continuous (fast small birds must not tunnel through twigs).
  Glancing hits slide; head-on hits stun briefly (no instant death).
- **Desktop mode** exists for development: keyboard/mouse emulate arm poses
  through the same WingInput.

## World — design intent

- A closed arena (mountains/hills ring it; you cannot fly off the map) about
  1–1.5 km across, with an open sky ceiling ~300 m.
- **Districts at many scales**, because the player spans a 10× size range:
  - *Village/town*: houses with **open windows you can fly through** (room
    inside, window on the far side), a church/bell tower with open belfry
    arches, barn with open doors and gaps in the slats, chimneys, rooftops,
    gutters and ledges.
  - *Power lines*: rows of electric poles with sagging wires — perches for
    small birds, slalom for bigger ones.
  - *Forest & orchard*: trees with real branch structure to weave through,
    dense hedges (refuges only small birds fit into).
  - *Nesting areas with tight airborne entrances*: nest boxes with small
    holes, a cliff face with swallow/sand-martin holes, a hollow tree, an old
    water tower or silo with a single opening.
  - *Vast open spaces*: meadow/fields, a lake or river, big sky over cliffs.
  - *Big-bird playgrounds*: cliffs and a canyon, tall towers/radio mast, a
    bridge with arches, rock arches.
- **Updrafts**: thermals (visible cues: rising dust/pollen motes, circling
  birds, sun-warmed fields/rooftops) and ridge lift along cliffs facing the
  wind. Strong enough that a player who finds them can climb without flapping.
- **Low-poly art**: flat-shaded, a limited harmonious palette, readable
  silhouettes, gentle atmospheric haze for depth, clear sky with a sun.
- Performance: Quest budgets (ARCHITECTURE §7). MultiMesh vegetation.

## Birds (assets) — design intent

- Every species in the ladder has its own low-poly model with a readable
  silhouette and colouring: moth (tiny food), wren, sparrow, swallow (forked
  tail), starling, pigeon, crow, gull, hawk, eagle. Size alone must not be the
  only cue; shape and colour say what a bird is from a distance.
- Wing animation: flap (downstroke faster than upstroke), glide, tuck/dive,
  perched (folded), with bank. One or very few materials for all birds.
- Readability tint/outline states: edible vs dangerous (UI/gameloop decide
  when), visible at gameplay distances in VR.
- VFX: feather burst on catch, subtle wing-tip trails at speed, updraft motes.
- Open assets (itch.io, Kenney, Quaternius, poly.pizza) may be used if CC0/CC-BY
  and credited in `docs/CREDITS.md`; procedural models are fine if better.

## NPC AI — design intent

- The sky feels **alive**: flocks of small birds wheeling, starlings murmuring,
  gulls soaring thermals, crows patrolling, hawks hunting from perches and
  stooping, small birds darting into hedges when a predator passes.
- Every NPC: hunts birds it can eat (prefers worthwhile prey, not dust),
  flees birds that can eat it (evasive turns, dives into refuges), rests on
  perches, soars thermals, avoids geometry, stays in bounds.
- NPCs target each other, not just the player. The player is simply another
  bird to them (maybe a little more interesting).
- The population is maintained around the player: a healthy spread of tiers,
  always some prey the player can eat and some threats, re-balanced as the
  player grows.
- NPCs obey the same size physics as the player (speed/turn limits by size),
  so a chase is fair and readable.

## Game loop — design intent

- Start small (sparrow). Catch → gain mass → grow (continuous) and change
  species at thresholds (tier-ups are celebrated moments).
- Prey worth scales with its mass; tiny prey stops being worth chasing
  (diminishing returns), which pushes the player up the ladder.
- Getting caught: brief dramatic moment → you lose (some) size, respawn at a
  safe perch with brief protection; a run ends on a limit (lives or time) with
  a summary; high score.
- Pacing target: a new player reaches pigeon in ~5–8 min, eagle in ~20–30 min
  of competent play; being eaten happens but is avoidable.
- Top of the ladder has a goal (e.g. become the eagle / apex and survive).

## UI — design intent

- VR-native: world-space panels, laser pointer on either controller, trigger to
  click, readable text (≥ 1.5° glyph height), comfortable distance (~1.5–2 m
  scaled by world_scale).
- Main menu (Play, How to fly, Settings, Quit), pause (menu button), resume,
  restart run, settings (comfort vignette, volume, haptics, seated mode,
  recenter/calibrate), controls/how-to-fly help with illustrations, caught
  screen, run summary.
- HUD: minimal and diegetic where possible — size/growth progress, subtle
  directional cues for nearby prey and threats, tier-up celebration.
- Onboarding: short first-flight lessons (spread, flap, glide, bank, dive,
  catch) that progress on doing, not reading.

## VR interactions — design intent

- Calibration of reach and neutral wrist angle (automatic, with a manual
  recalibrate). Recenter. Standing and seated modes.
- You see your wings: feathered wings attached to your hands.
- Haptics: wingbeat thump, catch, collision, stall buffet, updraft hum, danger
  proximity — distinct patterns, never a constant buzz.
- Comfort vignette on fast turns/speed. No camera roll/pitch.
- Controllers: menu button pauses; grip may be used to cling/perch or grab;
  trigger for UI.

## Audio — design intent

- Wind rising with airspeed (the main speed cue in VR), wingbeat whooshes,
  stall flutter, catch crunch/feather puff, danger (predator screech getting
  louder), bird calls for each species (3D), ambient per area, light music in
  menus. Procedural synthesis or CC0 samples.

## Also in v1

- Settings persistence, a clean Android/Quest export preset, performance
  within budgets, a desktop dev mode, a README with how to run and verify.
