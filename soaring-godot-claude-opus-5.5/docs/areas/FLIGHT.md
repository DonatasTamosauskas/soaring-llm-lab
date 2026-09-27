# Flight area (FLIGHT.md)

This document covers what the flight area built and why, how to verify every
criterion, where the evidence is, and what is still open.

- **Design:** the authoritative design is `docs/areas/FLIGHT_SPEC.md`.
- **Departures:** wherever the port departs from the spec, the change and its reason
  are listed in **FLIGHT_SPEC §19**: the port notes, then the fix-round notes for
  rounds 1–6.

**Integration round 2 (2026-09-27, the integration fixer).**
- *A player setting for how fast the view turns* (both round-2 verifiers:
  a sparrow at full input yawed the view at ~205 deg/s, 23.8 % of ticks over
  90 deg/s in play, and no setting): Settings `"turn_comfort"` (a 4-step
  bar in the UI's Settings: Gentle 90, Calm 120, **Brisk 180, the
  default**, Full 240 deg/s; `FlightTuning.TURN_COMFORT_RATES`,
  `turn_comfort_rate()`) caps the rig's yaw rate - and, through
  FlightModel's comfort caps, the bank that makes it - with the
  acceleration cap at 3x the rate (720 deg/s^2 at 240); never above the
  tuning's own cap; a raw `comfort_max_yaw_rate` setting still wins
  (dev/tests). Full-input sparrow turns peak at 90 / 120 / 170 / 207 deg/s
  (`player_bird_test.test_pb28_turn_comfort_setting_caps_the_turn`). The
  default is a first guess to try on the Quest Pro. One-on-one chases of
  fleeing wrens through the real chain did not change measurably between
  Calm, Brisk and Full (closest approach median 2.8 / 2.4 / 2.7 m, 0 of 12
  each: `tests/shots/integration_chase_lab_test.gd --turn_comfort=`).
- *A recenter while paused* (the Quest verifier: the runtime's
  center_on_hmd turned the view at the press, and the first tick after
  Resume re-aimed the rig and turned the world 51.5 deg back): PlayerBird
  re-aims the rig while paused, two frames after the recenter (once the
  runtime's new reference frame has reached the tracked nodes;
  `_recenter_when_tracked`), so the view changes once, as a recenter in
  flight does, and Resume turns nothing
  (`player_bird_test.test_pb29_recenter_while_paused_turns_the_view_once`).
  What "Recenter view" does in this game: the body frame comes from the
  arms, so it re-faces the bird's heading along the torso - the view turns
  by the head's offset from the torso at the press.
- `scenes/player/player.tscn`'s camera near is 0.06 (`NEAR_PER_WORLD_SCALE`,
  VR's `NEAR_K`); it said 0.03 until the rig extras attached.
- *Desktop:* S (full nose-up, 40 deg of wrist) still balloons and then
  stalls when held (the physics: too much AoA stalls); the desktop's How to
  fly now says so ("Held, S stalls") and the lesson cards name the keys (UI).

**Integration round 1 (2026-09-27, the integration fixer).**
- *Water is not ground* (the experience verifier: gliding down onto the
  lake the bird went "grounded" on the water line and stood there). A
  floor contact where `World.is_water()` (new, additive; the valley: the
  lake and the river) is never a touchdown, a stand or a stun: the bird
  splashes and leaves the water at `PlayerBird.WATER_HOP` (1.6 m/s up, or
  0.35 x its speed into it), counted in `contacts["water"]`; the feet never
  touch down on water either. A bird that does not flap hops on the water
  until it does; the hops after the first are silent (`player_collided`
  only above 1.25 x the hop). `tests/unit/integration/game_water_test.gd`
  (the verifier's scenario in the real valley: 42 splashes in 12 s, never
  grounded, perched or stunned, never under the surface, flaps away).
- *Near plane in flight's own world-scale path* (`drive_world_scale`, dev
  scenes only): `PlayerBird.NEAR_PER_WORLD_SCALE` 0.06, the same factor as
  VR's `WorldScaleDriver.NEAR_K` (the Quest's 24-bit depth buffer); PB-32
  reads the constant.
- Flight suite: 182 of 182 after both changes (60.8 s).

**Integration (2026-09-26): the arena's lid.** The integration verifier's major
finding ("flapping birds hit the arena's invisible ceiling and are stunned
repeatedly; the thin-air fade does not fade the flap force") is fixed at the root
(§2 "Integration: the arena's lid"):
- **Thin air:** lift, drag **and the flap force** fade together with the air's
  density ratio over the last 45 m under `World.ceiling` (`FlightEnv.thin_air`), so
  every climb tops out 17–27 m under the lid and settles a few metres lower. A
  thermal cannot lift a bird into the last 8 m either.
- **The lid never stuns:** momentum alone (a zoom) can still reach it, and then the
  bird slides along it.
- **The verifier's scenario:** reference and frantic strokes at sparrow, starling,
  pigeon and eagle from 40 m under the lid, circling in a 4 m/s thermal, and the
  real world's 300 m lid. Result: 0 stuns and 0 lid contacts (round 6: up to 6
  stuns or 11 bumps per 40 s).
- **Below 250 m** the flight is the same to the bit (the same climb rates).
- **NPCs** (scripts/ai) never reach the lid: no change was needed there (§2).
- **Suite:** 182 tests in 13 suites, 0 failures. 57.4 s by the runner at load 4–5
  and 58.7 s at load 6–9 (`ceiling/suite_final.log`; 55.8 s CPU by `time -p`). At
  load 13–14 it took 77.8 s (§6).

**Status (2026-09-26, fix round 6):** F1–F14 are met. Both round-6 major findings
(taking off from, and touching down on, slopes and roofs) and every minor finding are
fixed at the root (§2 round 6, §8), except that the suite still runs over 60 s when the
shared machine is at load 12 (it is 53 s at load 5; §6).

- **Headless suite:** 175 tests, 0 failures, 3 651 assertions. Command:
  `tools/gd.sh flight --headless res://tests/runner.tscn -- --suite=flight/`.
  - **Time:** 52.9 s by the runner at load 4.5–5.4 (50.2 s CPU;
    `verify/r6_builder/suite_final_run3.log`); on the final files 62.6 s at load 10–11
    (56.9 s CPU; `suite_final_run4.log`), with other agents' Godot runs sharing the
    machine (§6).
  - **`--full`** (the sweeps): 175 of 175, 7 441 assertions, 248.6 s
    (`verify/r6_builder/suite_full_final.log`).
- **Round-6 fixes:**
  - **Tests against the round-5 code** (`r6_old_code_check.json`): all 10 new behaviour
    tests fail on the round-5 sources, on their own assertions. The 4 pins of behaviour
    round 5 already had (the verifier's mutant survivors PB-33 and P14; G1c and WS-copy,
    which guard round-6 changes) pass there.
  - **Mutation runs** (`mutants.json`, final code): 109 of 115 caught. All 22 round-6
    mutants are caught: each fix, the verifier's three survivors, and the two
    `--full` findings. All 25 round-5 mutants are caught too; three were re-pointed to
    where round 6 moved their code. The six survivors are the documented second layers
    (§6).
  - **Verifier probes on the final code:** `r6eng` 8 of 8. `r6x` passes except where
    physics (a big bird cannot out-climb a long steep slope) or the guard's own rule
    (an eagle's stall above the guard height) differs from its assertion (§8).
- **Meta XR Simulator, after the last source edit (18:09):** SIM-05 PASS, 6 of 6 (18:14),
  and the hybrid course (18:15). Camera error 0.0 mm from the first tracked frame,
  0 SCRIPT ERRORs (§5).

---

## Note from the core loop's fix round 1 (2026-09-27): air does not blow into rock

`PlayerBird._wall_wind` (the flight model's `env.wind_fn` now points at it):
for `WALL_AIR_S` (0.3 s) after the body touches a face (contact normal below
0.7 up, in the sweep or the depenetration) the wind the flight model feels
loses its component *into* that face (two faces remembered, for corners). The
valley's wind field is not bounded by geometry: at the west cliff it blows
into the rock at 2.7 m/s with a 1.3-1.5 m/s updraft, and a slow eagle or hawk
under the overhang was held against the face - "flying" at 1.3 m/s airspeed,
not stalled, not sinking - for 4-10 minutes of real-chain runs. Pinned by
`tests/unit/integration/pin_escape_test.gd` (the real PlayerBird at both
spots, still wings or banking away: 2 m clear in 0.7-0.8 s; before, 0.1 m in
6 s). `unit/flight` 184 / 184 with it. Floors are untouched (ground handling,
landings). The wind also blows inside the village's rooms (1.4 m/s in one) -
a world-side limit.

## 1. What was built

| Piece | File(s) | What it is |
|---|---|---|
| FlightModel | `scripts/flight/flight_model.gd` | See the FlightModel detail below the table. |
| Parameters / tuning | `flight_params.gd`, `flight_tuning.gd` | `FlightParams.derive(mass)` computes every §7.1 quantity from SizeRules. `FlightTuning` holds every constant as an exported default, the per-size anchor curves, and the sim / normal / novice assist presets. Round 5 adds `ground_friction`, `touchdown_speed`, `leg_flex`, `landing_config_spans` and `stall_guard_vmin2g`. |
| WingState | `wing_state.gd` | The scale-free record of commands and measurements. `set_commands()` is for bots and NPCs. |
| WingInput | `wing_input.gd`, `flap_detector.gd`, `wing_calibration.gd`, `one_euro.gd` | Turns poses into a WingState. See the WingInput detail below the table. |
| Pose sources | `pose_source.gd`, `pose_frame.gd`, `pose_sources/*.gd`, `human_pose_model.gd`, `pose_recorder.gd` | XR, Hybrid (XR head with synthetic hands), Scripted, Replay (JSONL, tick-aligned), Desktop and Bot. All of them go through the same WingInput. The XR source stamps each sample with the real time its poses advanced (`PoseFrame.pose_dt`, round 5). |
| PlayerBird | `player_bird.gd`, `view_turn.gd`, `heave_smoother.gd`, `scenes/player/player.tscn` | The player's bird and rig. See the PlayerBird detail below the table. |
| Bot pilot | `flight_autopilot.gd`, `pose_sources/bot_pose_source.gd`, `flight_course.gd`, `flight_geometry.gd` | The FlightAutopilot moves the arms of a human model within human limits. The course's window wall is a 60-span (≥ 40 m) facade. |
| Plot tool | `flight_plot.gd` | Headless `Image` charts and contact sheets. |
| Flight lab | `scenes/dev/flight_dev.tscn` (+ `flight_dev.gd`, `_world.gd`, `_bird.gd`, `_wings.gd`, `_mirror.gd`, `_simdrive.gd`) | See the flight lab detail below the table. |
| Simulator drive | `tests/shots/flight_sim_driver.py`, `tests/shots/flight_sim_run.sh` | SIM-05 moves the simulator's own controllers and headset with its keybindings over SimRpc (`SendKey` only). The mirror is rendered with Forward+. |
| Tests | `tests/unit/flight/*_test.gd` (+ `pb_fixture.gd`, `perch_wind.gd`, `heave_metrics.gd`, …) | 182 tests in 13 suites. Integration adds `ceiling_test.gd` (CE-1…CE-6 and its plot). Round 6 added G1 on slopes, G1b, G1c, G3d, G3e, G5b, G8, G9, G10, PB-33, PB-34, P14, VT-6 and WS-copy. |
| Shots / plots / tools | `tests/shots/flight_plots.*`, `flight_shots.*`, `flight_roof_shots.*`, `flight_r6_diag_test.gd`, `flight_r6_oldcode_check.py`, `flight_r6_probe_copies.py`, `flight_mutants.py`, earlier rounds' `flight_r5_*`, `flight_perchwind_*`, `flight_heave_*` | Evidence and diagnostics, written to `artifacts/flight/`. |

**FlightModel detail**
- **Core:** a pure `RefCounted` point mass with a lagged attitude (θ, φ, dψ). It
  integrates with Heun (RK2) and symmetric attitude/flap splitting at 144 Hz
  substeps.
- **Stall and pitch:** a stall FSM, stall protection and a phugoid damper.
  - **Stall guard (round 5):** below the height a stall needs to recover in, a full
    flare is the maximum-lift flare. No deliberate stall is started there, and none is
    held. Normal and novice presets only. Round 6: the height is read with a ground ray
    down to the guard height, so a flat roof counts like terrain
    (`stall_guard_height()`).
- **Turning:** coordinated-turn lift tilt and adverse yaw with auto-rudder.
- **Flapping:**
  - flap force along each wing's normal, minus its component across the body;
  - the K_H→K_F blend;
  - a muscle-power cap;
  - a stroke-synchronous endurance cap.
- **One-wing kick:** from the stroke-mean effort asymmetry beyond a dead zone.
- **Limits and ground:** a speed governor, a ground cushion and ground-effect lift.
- **Thin air (integration):** under `World.ceiling` lift, drag and the flap force fade
  with the air's density ratio (`FlightEnv.lift_scale`, from `FlightEnv.thin_air`).
- **Safety and scaling:** a NaN guard (restores the last good state), a `lite` NPC mode
  and `envelope(mass)`.
- **Contacts:** `apply_contact(normal, kind, restitution, turn)` deflects the velocity
  and turns the body at most 40°, then seats the heading within the sideslip limit of
  the air path. Jumps are reported through `heading_step` / `take_heading_step()`.
- **Wind:** changes turn the heading through the sideslip channel.

**WingInput detail**
- **Tracker sanity:** tracker sanity gates, a torso-yaw estimator and neck-pivot
  shoulders.
- **Per wing:** extension, dihedral, swing-twist wrist twist and the wing normal.
- **Flapping:**
  - a credited-stroke flap detector with the arc bank, and wrist-twist jitter rejection;
  - hand velocity, arcs and the arc bank over the time the poses really advanced
    (`pose_dt`, round 5; an engine frame hitch is not a faster hand).
- **Command shaping:** shaping, a novice floor, the tuck and the soar lock.
- **Robustness:**
  - tracking-loss mirroring;
  - auto-calibration and auto-trim;
  - span refinement, only while flight owns the calibration (`refine_span`);
  - `resume()` after the pause menu: the poses are trusted and the stroke detectors
    restart (round 5).

**PlayerBird detail**
- **Bird:** `extends Bird` and registers and unregisters with `Birds`.
- **Rig:** PlayerBird → XROrigin3D (group `player_rig`, ALWAYS) → XRCamera3D,
  LeftHand/RightHand (grip), LeftAim/RightAim (aim) and WingAnchors.
- **Rig rules:** the rig only yaws, and the camera is the body (the eye).
- **Steering and comfort:**
  - body steer and the comfort caps;
  - owed view turns paid by a time-optimal follower (`ViewTurn`);
  - a camera heave that removes only the wingbeat of a steady rhythm.
- **Collisions:** a continuous sphere sweep. Contacts slide, land or stun. A stun turns
  the bird at most 40°. The arena's lid never stuns: a contact with it is a slide
  (integration).
- **Ground (rounds 5–6):**
  - the grass has friction;
  - a ground contact at or below 1.2 V_min is a touchdown, never on perch geometry,
    at up to 1 V_min into the surface (round 6);
  - a bird that could land meets the ground with its feet first, one body radius
    beyond its body (round 6);
  - the legs take the speed into the surface along its normal, over the reach plus
    at most 0.75 body radii of bend, and stand back up at ≤ 2 g (round 6);
  - the touchdown runs out along the ground's plane, braking at μg·cos(slope) plus
    gravity along it (at least 0.3 g), swept; it flies on off an edge or over a ridge;
  - a take-off leaves the surface, and is not landed again while the bird keeps
    flapping, until two spans clear; a scramble that makes no way stands (round 6);
  - a slow, sinking, flaring bird near the ground lowers its legs and tail.
- **Perching:**
  - captures ease in along a smooth Hermite curve;
  - the assist holds the perch it has acquired, corrects for wind and brakes on the
    ground speed;
  - it keeps a closing speed into a headwind, and a slow brush of the branch keeps
    the capture (round 5);
  - the perch is a rest state: only a completed flap leaves it.
- **Lifecycle:** take-off and respawn. Teleports start the view at rest, and the World
  is found even if it arrives late.
  - **After the pause menu:** the controls stay neutral until the arms are out and
    settled, then fade in (round 5).
- **Outputs:**
  - telemetry (plus `view_turn` and `view_turn_rate`), and `forced_turn` for tests;
  - events and a head-loss pause request;
  - growth through `world_scale` only. Flight's fallback driver rescales the rig at
    once when it changes the scale (round 5).

**Flight lab detail**
- **Course:** rings, a building facade with human-scale windows and the bird-sized open
  window (with shutters), poles and wires, perches, a thermal column, and route
  chevrons.
- **Views:** chase, eye and side cameras, a telemetry overlay and a head-view mirror.
- **Poses:** desktop, bot, novice, xr and hybrid.
- **Visuals:** feathered low-poly first-person wings in each species' colours, and a
  stand-in bird whose wings fold back when perched.
- **Tools:** the SIM-01/04 probe, the SIM-05 simulator drive, a camera-error trace
  printed per second (counted while the head is tracked), and growth.

### Data flow (one physics tick of the player)

1. `PoseSource.sample(frame)` produces poses and their pose interval, and feeds the
   recorder.
2. `WingInput.update(frame)` turns them into a WingState; the sanity gates run first.
3. The XR nodes are written from the validated poses (synthetic sources only).
4. Body steer runs against where the view is heading: `rig + owed turn`.
5. `FlightEnv` is built: wind, one ground ray (the cushion's distance within 2 spans,
   AGL down to the stall guard height), perch assist, and the ground landing
   configuration. The take-off hold is updated.
6. `FlightModel.step(ws, env, dt)` advances the model (dt clamped to 0.1 s). Perched or
   grounded, the body stays on its anchor instead, or runs out on the ground.
7. Perch capture is tested along the tick's path.
8. The continuous sweep runs and contacts respond. A bird that could land first
   sweeps its feet (a touchdown settles the body onto the ground along the normal). A
   contact deflects the velocity and turns the body at most 40°. A touchdown keeps
   the rest of the tick's motion along the ground.
9. The rig is updated.
   - **In flight:**
     - the flown turn goes directly into the rig's yaw while its rate changes no faster
       than half the acceleration cap;
     - heading jumps and anything faster are owed to `ViewTurn`;
     - the comfort safety net applies.
   - **Perched or grounded:** the rig brakes to rest at the comfort cap, and nothing is
     owed.
   - **Then:** the heave offset (vertical) and the legs' bend (along the surface
     normal) are added: the camera is the body plus `view_offset()`.
10. Events, growth and telemetry follow.

The model never sees a node, and the rig never feeds back into the model.

## 2. Design decisions (the ones that matter)

- **One input chain.** Every source produces poses, and only WingInput turns poses
  into commands. The bot, the desktop keys and the simulator's controllers and
  headset therefore exercise the same code a player uses (F12, F13, F14).
- **Physics owns comfort; the view never drops a heading change.** The comfort caps
  are bank limits inside the model: 240°/s yaw rate and 720°/s² yaw acceleration.
  - **Flown turns:** the rig follows them directly while their rate changes no faster
    than half the acceleration cap.
  - **Anything else is owed to the view and paid by `ViewTurn`** within 120°/s and
    240°/s². This covers:
    - a contact's turn;
    - a slow bird's heading catching up with its path;
    - the perch assist crabbing into the wind.
  - **The rig's yaw acceleration in flight is therefore ≤ 360 + 240 = 600°/s²** by
    construction.
    - Round 5 closed one exception: a recenter during a payout now stops the rig's
      turn (PB-30).
    - One tick can still reach the 720°/s² cap: a bird that runs off an edge within
      0.33 s of a crabbing touchdown, while the rig is still braking as on the
      ground.
  - **Body steer** reads where the view is heading, not where it is.
  - **The rig** only yaws and translates.
- **Heun + symmetric splitting at 144 Hz.**
  - The model is frame-rate independent to within 0.4–0.9 % of the path against
    360 Hz ticks (FM-24).
  - Energy drift is ≤ 0.1 % of the kinetic energy in 20 s (FM-22).
- **Credited strokes.** A downstroke earns force only for the upstroke arc that
  preceded it at real speed (the arc bank). A stroke's effort is its stroke rate ×
  credit (FLIGHT_SPEC §6.3).

### Integration: the arena's lid (thin air)

**The finding.** The world closes the sky with an invisible slab whose underside is
`World.ceiling` (300 m; `soaring_world._build_boundary`).
- **Before:** `FlightEnv.lift_scale` faded lift and drag over the last 20 m, but not
  the flap force.
- **Effect:** a flapping bird climbed through the fade at its full rate (4–7 m/s),
  bounced off the slab, and was stunned. The verifier measured a sparrow stunned 6
  times in 40 s of reference strokes from 40 m below, a pigeon 5 times, and an eagle
  11 bumps (`verify/r7x/r7x_ceiling_lid.png`).
- **Why:** the flap force alone carries more than the bird's weight (that is how a
  flapping bird climbs), and it did not fade; lift and drag did, so the thinner the
  air, the less held the climb back.

**The fix (`flight_env.gd`, `flight_model.gd`, `player_bird.gd`, `flight_tuning.gd`):**
- **Every force fades with the air.** `FlightEnv.lift_scale` is now the air's
  density ratio, and `FlightModel` scales each wing's flap force by it (after the
  power cap), exactly as it scales lift and drag. In air of ratio *s* a bird's force
  is *s* times its full-air force, so a climb levels off where *s* = 1 / (the bird's
  force-to-weight ratio). The harder it flaps, the higher it goes.
- **The profile.** `FlightEnv.thin_air(gap, band, floor)` works on the gap between
  the top of the body and the lid:
  - 1 from `FlightTuning.thin_air_band` = 45 m under the lid (255 m in the game, so
    everything below 250 m is untouched);
  - easing as 1 − (1 − u)² (no kink where the fade starts);
  - down to 0 at `thin_air_floor` = 5 m under the lid.
  The last 5 m are dead air: only momentum crosses them, and a thermal cannot lift a
  bird there, because air that carries nothing lifts nothing.
- **The profile was chosen by measurement** (`ceiling/diag_arr_*.txt`,
  `diag_feel_*.txt`). Arriving from below, the peak stroke-mean deceleration and the
  top of the climb were:
  - 1 − (1 − u)²: at most 1.83 m/s², levelling off 17–26 m under the lid;
  - smoothstep: 2.03 m/s², and 25–31 m under the lid (a steeper middle);
  - linear: 1.57 m/s², but 27–35 m under the lid, with a kink at the start.
- **The lid never stuns.** A contact met from below at `World.ceiling` (normal
  pointing down, contact point at the ceiling) is always a slide, or silent under
  0.5 m/s. `PlayerBird.contacts["lid"]` counts these contacts. It takes the upward
  speed and keeps the speed along the lid (92 %, as any slide), with the usual
  `player_collided` event. Only a zoom gets there: CE-6 puts the body's top 1 m under
  the lid rising at 8 m/s. It meets the lid at 6.7 m/s (a stun against a wall for the
  sparrow and the pigeon), slides, and flies on.

**Numbers (final code; `ceiling/diag_after.txt`, the verifier's own setups):**

*Flapping from 40 m under an 80 m lid slab, 40 s (top of the body under the lid):*

| Strokes | Sparrow | Starling | Pigeon | Eagle |
|---|---|---|---|---|
| Reference (1.3 Hz 45°) | 25.0 m | 19.0 m | 19.3 m | 17.0 m |
| Frantic (2 Hz 60°) | 27.2 m | 21.7 m | 20.2 m | 18.4 m |

Every one of these runs has 0 contacts and 0 stuns (round 6, reference strokes: every
size reached the lid about 9 s in).

*Thermals, 60 s:*
- circling in the verifier's 4 m/s thermal (sparrow, starling and pigeon flapping,
  and sparrow, pigeon and eagle soaring): tops 9.3–11.8 m under the lid;
- gliding in air rising 4 m/s everywhere: 8.0–10.5 m under the lid;
- every case: 0 lid contacts.

*The real world's 300 m lid (from 260 m at the spawn), reference and frantic strokes
at four sizes:*
- tops 16.7–26.4 m under the lid;
- 0 contacts. In round 6 the same runs had 5–242 lid contacts each, and the
  sparrow and starling were stunned 5–7 times.

*Below 250 m (CE-5):*
- a climb from 205 m under a 300 m lid and the same climb under a 3000 m ceiling
  are the same flight to the bit until 250 m;
- climb rates: sparrow 4.607 m/s, eagle 4.452 m/s, pigeon (2 Hz) 3.950 m/s, the same
  under both ceilings.

*Arriving from below:*
- into the thin air at 255 m, a climb levels off with a peak stroke-mean deceleration
  of 0.95–1.86 m/s² (≤ 0.19 g);
- for scale, stopping the wings mid-climb decelerates the same strokes' climbs at
  4.9–7.4 m/s² in full air;
- the round-6 lid stopped them at 5–13 m/s², and stunned.

**The verifier's own probes** (redirected copies, `verify/r7_builder/`) pass on the final
code:
- `test_r7x_ceiling_lid`: 0 lid contacts in all four cases;
- the climb diagnostic: 0 contacts at every size and stroke;
- the real world's lid: the sparrow tops out at 278.0 m and the pigeon at 281.7 m,
  with 0 stuns.

**NPCs (scripts/ai): no change needed.** NPCs fly `NpcFlight`, not `FlightModel`.
Three things keep them off the lid:
- the brain's bounds overlay steers them down above `ceiling − 25 m`;
- soaring leaves a thermal at `ceiling − 35 m`;
- the body clamps at `ceiling − 0.5 m` (the only way to "bump" it).

`tests/shots/flight_ceiling_npc_diag_test.gd` measured them in the real world
(`ceiling/npc_diag_final.txt`). It saw 0 clamp events, 0 lid contacts and 0 geometry
hits in every case:
- every size, sparrow to eagle, climbing for a goal 60 m above the lid from 22 m and
  8 m under it (closest 6.7 m);
- hawks, an eagle and a crow hunting prey at 285–292 m (closest 7.9 m);
- 2 minutes of the ecosystem round a player lapping at 275 m (closest 165 m: no NPC
  went above 250 m);
- five sizes in a 4 m/s thermal column through a 300 m lid (closest 9.4 m).

The real world's air near the lid rises at most 2.0–2.7 m/s (260–300 m, at the rim).
Its ground reaches 250 m only at the rim, and its highest perch is at 103.5 m, so
the thin air touches no perch or landing ground.

| Integration finding | Severity | Done | Pinned by (mutant killed) |
|---|---|---|---|
| Flapping birds hit the invisible ceiling and are stunned repeatedly; the thin-air fade does not fade the flap force | major | The flap force fades with the air (the root cause); the thin-air profile; the lid never stuns | CE-2 (M1 no flap fade), CE-3/CE-4/CE-5 (M1, M3 the round-6 fade, M4 a 15 m band), CE-1 (M5 no dead air), CE-6 (M2 the lid can stun, M6 lid detection); all 6 caught (`ceiling/mutants.txt`); CE-2…CE-6 fail on the round-6 code (`ceiling/ce_old_code_check.log`) |

### Round 6: slopes and roofs (the two major findings)

**The findings** (experience verifier, `r6x_experience_probe`; the world's hillsides
and every village roof, pitched 34–44°, are floors for PlayerBird):
- **No take-off facing up a slope of 25° or more (20° for the eagle).** Every stroke
  launched the bird level into the slope, which touched it down on the next tick:
  3–12 `player_took_off` / `player_perched` pairs in 6 s of strokes, stuck.
- **An uphill touchdown stopped in one tick.** The run-out ran level with a 0.3
  body-radius step-up, and the legs bent vertically only: on 15–34° upslopes the
  view's worst per-tick Δv was 0.52–0.85 × the touchdown speed (G1's bound is 0.45),
  and a slow touchdown facing the ridge of a 38–44° roof stunned.

**Root causes.**
1. The launch was `heading·0.6 V_min + UP·0.35 V_min·credit`: facing up a slope it
   pointed into the ground, and nothing kept a bird that had just taken off from
   touching down again.
2. The run-out's velocity was flattened to horizontal; its step-up (0.3 body radii
   a tick) could not follow a slope steeper than ~11° for a sparrow, and the slope then
   removed the run's uphill part in one tick.
3. The legs bent vertically: the part of the speed into a slope that is horizontal
   stopped at once. And their travel was the flex alone, 0.75 body radii (2.9 cm for a
   sparrow): a steep touchdown needed up to 15 g to stop in it.
4. A touchdown needed v_n ≤ V_cap (0.8 V_min): a slow bird flying into a 44° roof has
   0.87 V_min into it, so it was a stun.

**Fix (`PlayerBird._feet_contact`, `_touch_down`, `_legs_*`, `_run_out`, `_launch`,
`_update_takeoff_hold`; FLIGHT_SPEC §19 R6-1…R6-3).**
- **The feet reach.** A bird at or below the touchdown speed meets a floor with its feet
  one body radius beyond its body (`leg_reach`): a sphere of r_body + reach swept along
  the tick's motion, floors only, never perch geometry. That is the touchdown; the body
  then settles onto the ground along the normal (swept).
- **The legs bend along the surface normal**, over the reach plus the flex (1.75 body
  radii). The camera's offset from the body is the heave (vertical) plus this bend
  (`view_offset()`). The bend is a constant deceleration, the gentlest that fits: a
  stop exactly at rest when that takes 1–2 g; else a dip at 2 g or what the whole
  travel needs; a settle slower than 1 g moves down at 1 g. The stand back up is at
  ≤ 2 g (round 5 stood up at the bend's own deceleration: up to 15 g for a sparrow).
  A skid (a slide on a floor at flying speed) bends the legs too, when the bend can
  spread it over two ticks or more (v_n·dt ≤ the flex; a sparrow's 2 m/s). A harder
  skid stops the view with the body: bent within about a tick, split unevenly across
  the tick boundary, it read as more jerk than the body's own stop (the fixture's
  comfort rule; found on the round-5 verifier's ground-glide probe, pinned by G1c).
- **A touchdown may come in at up to 1 V_min into the surface** (`touchdown_vn`).
  The legs keep that within the 0.45 bound at every size.
- **The run-out keeps to the ground's plane.** It brakes at μg·cos(slope) plus gravity
  along the run, at least 0.3 g (a steep downhill would speed it up; the feet grip).
  It is swept along the plane: a steeper floor ahead turns the run onto it (the legs
  take the speed into it); a wall turns it along the wall. A ridge (the ground falling
  away by more than 20°) launches it. At rest the feet hold on any floor.
- **The take-off leaves the surface.** The launch's part into the ground is removed
  (at the same speed) and the kick is along the surface normal.
- **The take-off hold.** A bird launched off the ground is not touched down again while
  it keeps flapping (a stroke within 1.2 s, the ground launch's own stroke window) or
  for 0.5 s, until it is two spans clear of the surface below. Its feet scramble on
  the ground meanwhile (a silent contact, no friction). When the scramble no longer
  makes way up or along the slope, the feet hold it: it stands again (a touchdown),
  never sliding back down on its belly.

**What physics leaves.** A sparrow climbs straight out of a 44° slope. A pigeon or an
eagle cannot out-climb a long slope steeper than its climb gradient from a standing
start (F7's climb rates: an eagle ~12°, a pigeon ~17°; the verifier's own probe: the
eagle only 0.9 spans up a 15° hill after 6 s). Facing up such a slope it bounds up it
(one take-off per bound, 5–25 spans of way in 6 s), stands when the launch is spent,
and leaves over a village roof's ridge (3–5 m from eave to ridge: G9) or with a banked
turn away (G10). Turning the torso round on the ground also works (the verifier's
`roof_turn_round` probe, unchanged).

**Result** (touchdowns: the verifier's two approaches; take-offs: 6 s of 1.3 Hz 45°
strokes):

| Measure | Round 5 | Round 6 |
|---|---|---|
| Touchdown on an upslope, 1.1 V_min: worst view Δv per tick / speed, sparrow 15–34° | 0.52–0.78 | 0.10–0.26 |
| … pigeon 25–38° | 0.43–0.77 | 0.08–0.14 |
| … 38° roof facing the ridge (sparrow / pigeon / eagle) | stun / 0.43 / 0.42 | 0.30 / 0.14 / 0.10 |
| … 44° roof (every size) | stun | 0.32 / 0.16 / 0.12 |
| PB-11's slow touchdown, sparrow flat / 20° / 38° | 0.32 / 0.58 / 0.77 | 0.14 / 0.24 / 0.33 |
| The eng. verifier's touchdown grid (84 landings, started 1 cm above the grass): over 0.45 | 8 (up to 0.70) | 1, at 0.45 (a sparrow started inside its feet's reach, sinking at 0.7 V_min; from outside the reach, G1b: 0.31) |
| `took_off` events facing up 25–44° (sparrow / pigeon / eagle) | 7 / 3 / 2–3 | 1 / 1–2 / 1–2 |
| Way made up a 20–44° slope in 6 s (spans) | 0 | 26–50 / 10–24 / 5–9 |
| Village roof (38°, 44°) facing the ridge: leaves over the ridge | no (stuck) | every size |

Plots: `r6_slopes.png`, `r6_takeoff.png`. Renders: `r6_roof_{sparrow,pigeon,eagle}_*.png`
(a bird landing on a 38° village roof facing the ridge, standing, and taking off over
the ridge; `tests/shots/flight_roof_shots.tscn`).

### Round 6: the minor findings

- **Tall flat roofs (experience).** The stall guard read `World.ground_height` (the
  terrain; no buildings) or a 2-span ray. Now one ray per tick reaches below the guard
  height (guard + r_body + 1 m ≈ 11 m); its hit is `FlightEnv.agl`, the terrain only
  when it misses. `env.ground_distance` keeps its 2-span meaning. Over a 25 m flat roof
  a full flare from a span up no longer stalls below the guard height at any size
  (round 5: 2–3 stalls, the sparrow stunned). An eagle's flare zooms 7 spans up and may
  stall at the top, 16 m above the roof, as it does over the meadow (G5b).
- **Pins for three round-5 behaviours** (engineering; each was a mutant survivor):
  - **the game's XR source is frame-timed:** PB-33 runs WI-34's hitches through the
    player's own default XR source (0 flaps; 2 with the timing off);
  - **the in-game stall guard height:** G5b (a sparrow stalls from 15 and 25 m, never
    from 5 m);
  - **the fast-scrape capture lockout:** P14 (after a scrape at 1.5 V_cap no capture
    for 0.5 s, then the capture; after a slow brush at once).
- **Telemetry read inside an Events handler** (engineering). The cache kept the mid-tick
  values for the rest of the tick. Now the next read after the tick rebuilds (PB-34).
- **G1 covered only a gentle touchdown** (engineering). G1 now covers the flat,
  10/20/38/44° upslopes, a 38° roof crossed at 60°, and a 10° downslope, with two
  approaches at three sizes. G1b covers the touchdown envelope on the flat (forward
  0.4–1.0 × sinking 0.3–0.7 V_min). All stay within 0.45.
- **XR evidence dated before the final edit** (engineering). SIM-05, the hybrid course
  in the simulator and the bot sweep were re-run after the last source edit (§5).
- **Suite runtime** (both). See §6. Changes:
  - no physics-frame wait per fixture (28 ms of wall each; Jolt answers queries about a
    new static body at once);
  - an exact WingState copy (the reflective one was ~20 µs a tick);
  - an O(1) dihedral window mean (was a loop over up to 135 samples a wing a tick);
  - no per-tick array allocations in WingInput;
  - wind samples cached within a model step;
  - the wingtip wind sampled only when telemetry is read;
  - the terrain call skipped when the ground ray hits;
  - the pose model's arm directions computed once per hand;
  - P6's static 60 s rest at one size by default (`--full`: three).

**Found in this round (not a verifier finding): two `--full` failures that predate it.**
Both fail identically on the round-5 sources (checked in the old-code sandbox).
- **VT-1 over 20 000 sequences lost 2.5·10⁻⁵ rad of view turn.** Godot's
  `wrapf(x, -PI, PI)` returns −π for any result within its `is_equal_approx` tolerance
  of +π: a debt 2.5·10⁻⁵ rad short of +π became −π. `ViewTurn.owe` and
  `FlightMath.wrap_angle` now wrap exactly (VT-6).
- **PB-08c `--full`, sparrow ±20 % jitter, seeds 41–43: 0.9349** against a bound of
  0.93. Round 4 set that bound below the heave study's own held-out measurement of
  this very case (0.934, `heave_eval.txt`, "heave_data_heldout"). The bound is 0.94 now,
  justified there. The smoother still takes 6.5 % of the wingbeat band off (1.0 is no
  smoothing); the no-harm assertions (no window above 1.5×, jerk ≤ 1.1×) are unchanged.

### Round 5: landing on the ground (the major finding)

**The finding** (experience verifier, `test_r5x_ground_landing_quality`):
- **Skimming below stall speed.** Gliding into a meadow with the arms still, the
  pigeon and eagle stayed FLYING on the grass below V_min for 7 and 15 s, sliding on
  their lift alone. They came to rest only after 22 and 45 s.
- **Flares.** Moderate flares (+20/+30°) never landed the pigeon or eagle in 25 s. A
  full flare (+40°) near the ground stunned the sparrow from every height tried.
- **The touchdown stopped the view in one tick:** 0.98 / 0.58 / 0.90 × the touchdown
  speed. For the sparrow that is 17.8 m/s perceived; the perch capture's P9 bound is
  0.45×.

**Root causes.**
1. A silent contact with the ground was frictionless.
2. A touchdown needed V ≤ 0.7 V_min. Between 0.7 and 1.0 V_min a bird's belly slid on
   the grass while the model called it flying.
3. The touchdown zeroed the velocity in one tick.
4. The flare: from the glide speed a full flare zooms a sparrow 10 spans up. The
   deliberate stall there was *held* while the nose dropped to −45°, and the bird
   dived into the grass at 4.7 m/s (`flight_r5_diag --test=diag_flare`).
5. A big bird's flare zooms up to 7 spans, then glides down at the slow trim at an
   L/D of 14: 20 s before it can touch the ground.

**Fix (`PlayerBird._classify`, `_touch_down`, `_run_out`, `_landing_config`;
`FlightModel` stall guard; FLIGHT_SPEC §19 R5-1…R5-4).**
- **Friction.** A silent ground contact is a skid: Coulomb friction takes μ × the
  normal impulse from the speed along the ground (μ = 0.6). A bird the wing no longer
  holds up decelerates at (1 − L/W)·μg.
- **Touchdown.** A ground contact at or below 1.2 V_min (the verifier's 1–1.2) is a
  touchdown. Perch geometry is never ground (G7). This bug was found while re-running
  the wind sweep: a slow sparrow "landed" on a branch top 0.2 m from the grip.
- **Run-out.** The body keeps its speed along the ground and runs out at μg:
  - distance v²/2μg: 1.4 m (5.8 spans) for a sparrow at V_min, 6.5 m (3.1 spans) for
    an eagle;
  - swept, so a wall turns the run along it;
  - settled onto the ground with a ray (exact, no jitter);
  - running off an edge is flying again, stepping off the way the bird faces;
  - the rest of the touchdown tick's motion carries on along the ground. Dropping it
    was a 3 m/s dip in the view's speed.
  - A take-off during the run-out keeps its speed.
- **Legs.** The speed into the ground goes into the legs: a time-optimal camera dip
  (the `ViewTurn` follower) of at most 0.75 body radii, at the deceleration that stop
  needs (≥ 2 g). The eye never nears the grass.
- **Stall guard** (normal and novice). A deliberate stall is refused, and a stall is
  not held, below the height a stall needs to recover in:
  - what a held stall falls before its forced recovery (0.4 g × 1.5² = 8.8 m, at every
    size), plus a quarter of V_min²/g for the pull-out: sparrow 9.2 m, pigeon 9.7 m,
    eagle 10.8 m;
  - there a full flare is the maximum-lift flare;
  - above it, F3's deliberate stall is unchanged (FM-05, FM-06; the verifier's
    wrist-stall probe at 300 m).
  - Half of V_min²/g guarded the whole of an eagle's zoom, and at maximum lift it
    porpoised for 17 s. A quarter lets a big bird stall at the top of its zoom, well
    above the ground, as round 4 did.
- **Landing configuration.** A slow (1.6 → 1.3 V_min), sinking (0 → 0.5 m/s), flaring
  (pitch 0.2 → 0.6) bird within 4 spans of the ground lowers its legs and fans its
  tail. This is the perch assist's configuration: +0.4 CD at most, ≤ 0.5 g of extra
  drag. A pull-up from a low pass (fast, climbing) zooms exactly as high, and a
  trimmed skim gets none (G6).

**What stayed.** The spec's G15 skim (PB-15: a trimmed glide skims ≥ 40 spans in ground
effect) is kept.
- A lower ground-effect lift gain (0.2) would land an eagle's neutral glide in 13 s,
  but it skims only 8.5 spans (PB-15 fails). 0.4 sits on the edge of both, so the
  round-4 gain (0.6) stays.
- The eagle's neutral glide therefore rests at 18.4 s, inside the verifier's "about
  20 s". Any flare lands it sooner.

**Result.**

| Measure | Round 4 | Round 5 |
|---|---|---|
| FLYING on the grass below V_min, longest (sparrow / pigeon / eagle) | 3.3 / 7.3 / 15.1 s | 0 / 0 / 0 s |
| Neutral glide from 6 spans + 2 m: at rest after | 9.7 / 21.8 / 45 s | 3.4 / 8.7 / 18.4 s |
| Touchdown (PB-11 set-up): the view's worst per-tick Δv / touchdown speed | 0.98 / 0.58 / 0.90 | 0.32 / 0.08 / 0.05 |
| Full flare (+40°) from 0.3 / 1 / 2 spans: stuns (sparrow) | 1 / 1 / 1 | 0 / 0 / 0 |
| Flares +20 / +30 / +40° × 0.3 / 1 / 2 spans × 3 sizes, landed within 20 s | pigeon and eagle +20/+30 never | 27 of 27 (worst 19.1 s: eagle +20° from 2 spans) |

Plot: `r5_ground.png`.

### Round 5: resume, hitches, recenter, world-scale snaps

- **Resume from the pause menu (minor finding).**
  - *The finding:* unpausing only trusted the new poses. The jump to a raised pointing
    arm banked as an upstroke, and the arm's way down 0.3–0.4 s after resume was a
    credited downstroke (`player_flapped`, 0.36 of the weight in flap force). The
    arms' way back from the menu pose flew at full authority: up to 70° of bank and
    79° of view turn in 3 s.
  - *The fix:* `WingInput.resume()` also restarts the stroke detectors. PlayerBird then
    holds the controls neutral until both arms are out (extension > 0.6) and settled
    (neither swinging faster than 0.5 rad/s), or for at most 1.5 s, and fades them in
    over 0.4 s, as after a stun.
  - *PB-29:* 0 flap events, 0 flap force, bank ≤ 0.4°, heading change ≤ 0.1° in the
    3 s after resume. A wrist roll then banks the bird again.
- **Frame hitches (minor finding).** Hand velocity is now measured over the time the
  poses really advanced.
  - The detectors no longer clamp their dt to 1/30 s: a 0.1 s tick read the hand 3×
    too fast (PB-31).
  - `XRPoseSource.frame_timing`, on for the game's and the lab's XR sources, stamps
    each sample. It records the wall-clock time since the previous engine frame's
    pose, and 0 for the repeats within one frame. The XR server writes the tracked
    nodes once per engine frame, so after a hitch several fixed ticks run on one
    pose, and the first sees it jump by the whole hitch.
  - The detectors divide the jump by that interval and carry the stroke on through
    the repeats. Recordings keep `pose_dt` (`"pd"`).
  - *WI-34* runs the XR source with an emulated engine clock (a 100 ms hitch every
    0.5 s): slow sweeps give 0 onsets (2 without frame timing), and real strokes keep
    their onsets and their effort (ratio 1.0015).
  - In the simulator, SIM-05's strokes read as before (4 onsets per wing) and
    `pose_dt` reads 13.9 ms per frame.
- **Recenter during a view payout (minor finding).** The recenter now also stops the
  rig's own turn. PB-30: no safety-net tick (round 4: 8), rate after the snap < 10°/s
  (was 53°/s), no run-on the old way.
- **The first XR frame's 1.04 m camera offset (minor finding).**
  - *Cause:* flight's fallback world-scale driver snapped `world_scale` (1 → 0.388) on
    the first tick, after the XR server had written the tracked nodes at the old
    scale. Until its next update, the camera node sat 1.04 m above the body. The
    rendered view was unaffected (the server applies the current scale), and that
    frame came before the session was visible.
  - *Fix:* a scale change rescales the rig at once (the tracked nodes, the origin
    offset, the wing anchors), as the server will. The lab counts the camera error
    only while the head is tracked.
  - *Result:* four XR starts read 0.0 mm from the first frame (§5). PB-32 pins it,
    with the verifier's two unpinned contracts (the ramp, and near = 0.03 ×
    world_scale).
- **ViewTurn with a changing tick length (minor finding).** Qualified, not changed: the
  caps and conservation hold for any ticks. "Never past the target" is exact for a
  constant tick, which is Godot's fixed physics tick. VT-5 mixes 72/90/120 Hz every
  tick: overshoot ≤ 0.25° (0.21° measured over 5 000 sequences), settled within 1 s
  of the constant-tick bound. Arbitrary 4–100 ms ticks, which the game never feeds
  it, can run past by a few degrees (§9).

Plot: `r5_resume_hitch.png` (with the full breeze, below).

### Round 5: perching in the full breeze (minor finding)

A sparrow could not perch into or across the world's 2.64 m/s breeze at 30 m (65 % of
its V_min), on the round-3 verifier's approach (6 spans out, 1.2 V_cap through the air,
wrists slightly up, arms still).
- **Headwind:** the slow bird lost airspeed to drag until the air carried it backwards
  0.6 m short of the branch (`flight_r5_diag --test=diag_breeze`).
  - Now, below a closing speed of 0.25 V_cap along the line of sight, the assist
    cancels the bird's own deceleration along it and closes the gap.
  - It draws on the headwind's own budget (≤ 0.5 g, applied after the steering cap,
    like the crosswind's): the small wingbeats of a bird landing into the wind.
- **Crosswind:** the crabbing bird brushed the branch from below and hung within reach
  of the grip, locked out of the capture for 0.5 s by the contact, and fell. Now only
  a scrape too fast to perch locks the capture out.
- **P13:** the sparrow perches head / cross / tail in 1.40 / 0.78 / 0.22 s, and all
  three sizes do with `--full`.
- **Wind sweeps:** re-run on the final code (§3). Both improve or match round 4 in
  every cell, and in-air rig acceleration stays ≤ 600°/s².

### Round 5: lab facade and chase framing (minor finding)

- **The finding:** round 4 sized every facade window like the opening and kept them to
  12 floors × 12 columns round it. A sparrow's 0.48 m windows were 3 px wide from
  flight distance: a dense dotted patch on a blank slab that shimmered in the headset.
- **The facade now:** human-scale windows (at least 1.4 × 1.6 m, or the opening's size
  for an eagle) cover the whole wall, 13 × 20 on a sparrow's 40 × 70 m facade. The
  bird-sized opening sits among them with its frame and shutters.
- **The chase camera** sits 2.8 spans + 5 cm back: the sparrow is ~8 % of the frame
  width in a turn (was a few pixels).
- It is still dev art (§6).

### Round 4: the view turn is a time-optimal follower (the critical finding)

**The finding.** After a stun that ended on the floor, the view spun at the 240°/s rig
cap for tens of seconds: 15 of 96 fast room entries, and one turned 10 271° in 55 s.

**Root cause.** Round 3 paid owed turns along a minimum-jerk quintic, re-planned
whenever more was owed. Its duration search could run out. The coefficients were then
solved for one duration and run for another, and nothing caught it. On the ground the
rig clamped its rate without owing the rest, so a spin never ended.

**Fix (`scripts/flight/view_turn.gd`, rewritten; FLIGHT_SPEC §19 R4-1).** Each tick,
the payout rate moves by at most `max_acc·dt` toward the fastest rate that can still
stop exactly on the target at that deceleration, and never above `max_rate`.

- **The stopping curve is exact for the discrete ticks:**
  `v_stop(e) = e/(dt(n+1)) + a·dt·n/2`, with `n = ⌊√(1/4 + 2e/(a·dt²)) − 1/2⌋`.
  The continuous `√(2ae)` overshoots by up to a·dt²/2.
- **There is no plan, no search and no failure branch.** The properties hold by
  construction:
  - both caps on every tick;
  - owed = paid + debt;
  - at rest on the target within `|e|/rate + rate/acc + 0.3 s`, and within 3 ticks
    of the continuous time-optimal turn;
  - no overshoot from rest or on the stopping curve.
- **One overshoot cannot be avoided.** A new owe the other way can cut the debt short
  while the view turns fast. The view then runs past by the braking distance v²/2a
  and comes back, inside both caps.
- **A rate above a lowered cap only brakes.**
- **Perched or grounded:** nothing is owed and the rig brakes to rest at the comfort
  cap: ≤ 0.33 s from 240°/s, ≤ 0.15 s from a landing's typical 100°/s. Round 3's
  `settle()` is gone.

**Trade-off.** The acceleration now steps (bang-bang) instead of easing. It stays inside
240°/s², a third of the comfort cap, and the lead chose provable bounds over
smoothness here. A spring or a jerk-limited follower would round the corners but lose
the simple proof, and round 3 showed where planners fail.

**Result.**

| Measure | Round 3 | Round 4 |
|---|---|---|
| Room entries (96, the verifier's sweep, C10 `--full`) with a spin | 15 | 0 |
| Longest spin | 55 s | 0.2 s |
| Low-wall hits (162) with a spin | — | 0 |
| VT-1: 3 000 random owe sequences (20 000 with `--full`) at 72/90/120 Hz, violations | 2 819 | 0 |
| Peak payout | 642°/s | 120°/s |
| Peak acceleration | — | 240°/s² |
| Worst convergence margin | −1.02 s | +0.29 s |

Plot: `r4_view_turns.png`.

### Round 4: a contact turns the bird at most 40°

**Direction.** Minimise forced view rotation from collisions. A stun deflects the
velocity and changes the heading minimally; the player turns the rest.

**Fix (`FlightModel.apply_contact`, `_seat_heading`; §19 R4-2, R4-3).**
- **The stun turn.** It turns the body the short way toward leaving the wall at 20° to
  its plane, capped at `contact_turn_max_deg` (40°). Round 3 turned it
  incidence + 20°: 110° head-on.
- **The heading can only sit within the sideslip limit (0.5 rad) of the air path.**
  - A bounce path outside that limit is turned to the limit, if that leaves the wall.
  - Otherwise the path is removed (head-on: the bird stops and drops).
  - Keeping a backward path was tried: while the stunned bird fell, the path drifted
    inside 90° of the body and the heading snapped 84°.
- **Slides** turn the body only as far as the sideslip limit needs (≤ 40°).
- **A post-stun grace was built and removed.** It let walls only slide a bird the stun
  had just released, but no scenario measured any effect, the verifier's room sweep
  and probes included.
- **Grazing contacts.**
  - When the rest query finds nothing at the cast's unsafe point, it is repeated with
    a 2 mm margin.
  - If there is still nothing, the sweep stops at the safe point with no response.
  - Round 3 guessed the normal as −motion, and a fall along a wall read as a floor hit.
  - C11: 48 falls along a wall face at varied gaps and drift, none stunned or landed.
    Round 3's guess stuns the pigeon and the eagle there.

**Result (C8b, three sizes, arms still):**

| Incidence | Stuns | Stun turn | View rotation in the 3 s after the hit | ViewTurn peak |
|---|---|---|---|---|
| 30° | 1 | 40° (was 50°) | 46° | 98–100°/s, 240°/s² |
| 60° | 1 | 40° (was 80°) | 62–64° | 107–110°/s, 240°/s² |
| 90° (head-on) | 1 | 40° (was 110°) | 93–96° | 104–120°/s, 240°/s² |

- **No tick turns the bird more than 40° plus one flown tick** (C8).
- **The view faces the heading 1 s after the stun:** 0.0°. The safety net never acts.
- **What the 3 s rotation is** (corrected in round 5; round 4 called it all flown,
  which the engineering verifier showed was wrong):
  - the contact's own turn, ≤ 40°;
  - then the stopped, falling bird's heading following its air path once that is
    faster than 0.25 V_min, as it falls away along the wall: 22–34° head-on, 5° at
    60°. These are heading jumps too, owed to the view and paid by `ViewTurn` inside
    120°/s and 240°/s²;
  - the rest (19–34°) is flown, as the bird lines up with the wall.
  - C8b now pins the total forced (not flown) turn in the 3 s after the hit at
    ≤ min(incidence + 20°, 40°) + 40°: measured 40 / 45 / 62–74°.
  - The alternative, no turn at all, plunges the bird down the wall.

### Round 4: the perch is a rest state (major finding)

**The finding.** Relaxing the arms on a perch dropped the bird off it. Arms at the
sides read as the tuck, and round 1's "drop-launch: tuck while perched" launched the
bird:
- pigeon and eagle fell 20 m to the ground;
- 10 of 20 relaxed postures ejected the bird.

**Fix (`PlayerBird._tick_perched`, `_completed_flap`; §19 R4-4).** Arms at the sides
or folded are the rest pose and never leave the perch.
- **Only a completed flap launches:** a credited downstroke that ends with the wing
  still out, or a deep stroke that ends low and rises back out within 0.8 s. The bird
  leaves at the bottom of the stroke.
- **A brisk drop of the arms to the sides** after raising them is a credited
  downstroke too, but it ends folded: no launch.
- **The ground keeps the credited onset.** A stroke there must lift the bird with its
  whole downstroke, and a relaxing drop is at most a hop.
- **Tuck means a dive only in flight.** Perched or grounded telemetry reports no tuck.

**Result.**
- **P6** (three sizes):
  - 60 s with the arms relaxed at the sides, then 20 s of fidgeting with 4 credited
    downstrokes that end folded: still perched, no take-off event, no tuck in
    telemetry;
  - then a flap from the rest pose launches on its first stroke, 0.78 s after it
    begins.
- **P6b:** relaxed postures (upper arm −60…−90°, elbows 0–90°) never drop the bird: 6
  by default, 20 per size with `--full`.
- **P5:** the reference stroke launches at the bottom of the stroke (0.0 s after the
  downstroke ends) and the deep stroke at its recovery (0.125 s).
- **The verifier's rest grid:** 0 of 20 drop (was 10).

Plot: `r4_perch_rest.png`.

### Round 4: one-arm and uneven strokes (major finding)

**The finding.**
- **One arm stroking shoved the body toward the stroking wing:** −0.76 g sideways peak
  for the pigeon. After the first stroke the one-arm turn reversed (pigeon +47°,
  eagle +15.5° toward the stroking wing), banked the other way.
- **Ordinary asymmetry shook the view.** Arms 10 % unequal or 30 ms apart wobbled the
  sparrow's view 5.5–6.8° every wingbeat.

**Root causes.**
1. Each wing's force followed its instantaneous normal. The normal droops 20–45° late
   in the downstroke; for two wings those parts cancel, for one they push the body
   sideways.
2. The roll kick and paddle yaw read the instantaneous flap difference, so every
   wingbeat of slightly uneven arms kicked the bank.

**Fix (§19 R4-5, R4-6).**
1. **The flap force's component across the banked body is dropped**
   (`flap_side_share` 0). Symmetric strokes are unchanged.
2. **The kick acts on each wing's effort averaged over the last stroke period.** A
   timing offset averages out.
3. **Only the relative asymmetry |l − r|/(l + r) beyond `one_wing_deadzone` (0.15)
   counts.** It is rescaled to grow from zero at that edge to full at a one-wing
   stroke, so natural human asymmetry (±20 % amplitude) is a symmetric stroke.
   Differential wing tilt still yaws.

**Result.**
- **PB-28 (10 one-arm strokes, three sizes):**
  - the bird turns away from the stroking wing every second: sparrow 136°, pigeon 77°,
    eagle 59°;
  - it is mirror-exact, banked the way it turns (5.8–6.8°);
  - sideslip ≤ 0.63°; sideways specific force 0.023–0.055 g (was 0.77 g).
- **PB-27 (±20 % amplitude, ±50 ms phase, 1 and 2 Hz, three sizes):** view yaw wobble
  ≤ 0.001° per wingbeat, drift ≤ 0.003°/s, sideways force ≤ 10⁻⁴ g. The limits were
  < 1° per stroke, < 1°/s and < 0.05 g.
- **FM-18b:** a drooped wing pushes nothing sideways (0 g; was 0.86–0.97 g).
- **FM-18c:** the kick is 0 inside the dead zone, 10 % of a one-wing stroke's bank at
  20 % asymmetry (33 % without the rescale), and grows monotonically.
- **FM-18 unchanged:** a one-wing stroke banks 5.7–6.4° and turns 3.9–6.7°.

Plot: `r4_strokes.png`.

### Round 4: other changes

- **Camera heave at a rhythm's end (§19 R4-7).**
  - With the arms at rest, the template's phase stops.
  - The amplitude gain closes at the rest rate.
  - A novice eagle whose last stroke ended level had a 3 s window at 2.1× its body's
    motion (limit 1.5); it is now 1.39. Every heave test is unchanged.
- **Bot pilot (§19 R4-8).**
  - The final glide starts at its planned distance, but not while the bird is still
    banked beyond ~30° in the turn onto the return leg, and for at most 30 % of the
    glide.
  - The eagle crossed the window at 1.07 V_min on 2 of 6 seeds; it now crosses at
    1.30–1.52 V_min.
- **world_scale exponent.**
  - The default is 1.0, the VR area's recommendation (VR.md §4).
  - The angular optic flow that drives vection is the same at any exponent. A smaller
    exponent draws a small player's wings up to 1.5× too wide next to NPCs.
  - The "perceived speed" gap the experience verifier measured is recorded with VR's
    levers for it in FLIGHT_SPEC §11.4 and §17 R1.
- **Pinned contracts.**
  - PB-19b: a 1 s tick advances at most 0.1 s of flight.
  - FM-23b: a NaN or INF state is restored to the last good one.
- **VR's requests (VR.md §12).**
  - WingInput refines the arm span only while flight owns the calibration (WI-32).
  - `WingCalibration.from_dict` validates native Basis, Vector3 and scalar values
    (WI-33).
- **Lab visuals** (superseded in round 5, §2): detail round the opening only.

### Round 3 decisions that stand

- **Heading steps are owed to the view, never dropped.** Round 3 traced its stun-lock
  to the rig discarding heading changes the caps could not follow. The view kept
  facing the wall, and body steer read that stale view as the player's torso. The
  owing stands; round 4 replaced the payout.
  - **Explicit jumps:** contacts, and any path-heading change faster than 6 rad/s
    within a substep, are reported (`take_heading_step()`).
  - **Body steer** steers against `rig + debt`.
  - **Gust fronts:** a change of the wind turns the air path under the bird, and the
    wind's share goes into the sideslip channel. The body weathercocks round smoothly
    (PB-26: peak view acceleration 104 / 46 / 27°/s², was 720).
  - **Teleports:** `respawn`, `start_flying` and `perch_on` zero the rig's motion, the
    debt, the body-steer lags and the previous flight's perching state (PB-24).
- **Perching in the world's breeze** (1.3–2.1 m/s at perch height).
  - **Acquisition:** the assist acquires the perch within 50° of the air path or the
    ground path and holds it.
  - **Crosswind:** the wind's drift across the line of sight gets its own steering
    budget, up to 0.5 g.
  - **Brake:** planned with the ground speed, `a = Δv·(v_g − Δv/2)/d`, plus
    cancellation of the bird's own acceleration along its path.
  - **Capture:** judged on `min(airspeed, ground speed)`.

  Results on the final code: the wind sweeps in §3 (round 5 adds the headwind hold and
  keeps the capture through a slow brush of the branch, §2).

### Camera heave (round 2, amended in round 4)

**Round-2 finding.** The round-1 fit helped steady flapping and hurt irregular
flapping: up to 61 % more wingbeat-band vertical acceleration in the view than in the
body.

**Shipped design.** The round-1 fit, applied only where it is known to help. Each gate
closes at the earliest moment a break is observable:

| Gate | Rule |
|---|---|
| Rhythm | Opens after three regular onsets; a pause is never a period. |
| Phase | Each stroke's gain is scaled by the template's phase error at its onset. |
| Arms | The correction follows the arms' stroke amplitude; at rest the phase stops and the gain closes at the rest rate (round 4). |
| Benefit | Least-squares gain of the template against the body's motion. |
| Easing | Every gain moves through a jerk-limited critically damped ease. |

**Results.**
- **Round 2** (`heave_eval.txt`):
  - worst mean view/body band acceleration ≤ 1.009;
  - no window at 1.5× or above;
  - per-tick jerk ≤ 1.06× the body's;
  - steady flapping keeps 6–8 % of its wingbeat.
- **Round 4, B2's 30 novice flights:** worst window 1.39× (eagle s8, was 2.1×). All
  other flights are ≤ 1.05×.

### Other decisions (earlier rounds, unchanged)

- **Tracker sanity.** A tracker sample is trusted when it is:
  - finite;
  - a proper basis;
  - within 20 m;
  - continuous with the last accepted pose (0.15 m plus 3 m/s for the head, 5 m/s for
    the hands, times the time since).

  Beyond that:
  - A consistent offset held for 0.25 s is a re-localization.
  - When the head and both hands move by one vector, it is a body translation.
  - Hand gaps ≤ 0.1 s are bridged (WI-30).
  - A head-only re-localization moves the body to the view, which gives one view jump
    instead of two.
- **Wrist-twist jitter:** a symmetric twist reversing faster than a 0.15 s half-cycle
  with swings ≥ 10° is replaced by its critically damped mean before the pitch shaping.


## 3. Criteria: verification and results

**Commands**

| What | Command |
|---|---|
| Everything | `tools/gd.sh flight --headless res://tests/runner.tscn -- --suite=flight/` |
| One suite / one test | `--suite=flight/<file stem>`; add `--test=<substring>` for one test |
| Options | `-- --full` adds the sweeps (below); `-- --perf` makes FM-28 and PERF-01 strict |
| Plots | `tools/gd.sh flight --headless res://tests/shots/flight_plots.tscn` (`-- --only=r6` for the round-6 plots) |
| Roof renders (round 6) | `tools/gd.sh flight --rendering-method forward_plus --resolution 1280x720 res://tests/shots/flight_roof_shots.tscn -- --species=pigeon` (also sparrow, eagle; `--pitch=`) |
| Screenshots | `tools/gd.sh flight --rendering-method forward_plus --resolution 1280x720 res://tests/shots/flight_shots.tscn -- --species=sparrow` (also pigeon, eagle) |
| Wind sweep | `tools/gd.sh flight --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=flight_perchwind_sweep --set=glide` (or `--set=verifier`) |
| Ceiling (integration) | `... -- --suite=flight/ceiling` (CE-1…CE-6; `--full=1` for the verifier's durations and every case); the verifier's scenarios and more, reported: `... -- --dir=res://tests/shots --suite=flight_ceiling_diag --tag=<name>` (`--test=climb_under_lid \| thermal_under_lid \| normal_climb \| real_world_lid \| zoom \| stop_flapping \| arrival \| uniform \| trace`; trace takes `--case=sparrow,2.0,60,0.3,0.2,4.0`); NPCs at the lid: `... -- --dir=res://tests/shots --suite=flight_ceiling_npc_diag --tag=<name>` |
| The integration verifier's lid probes, redirected | `... -- --dir=res://tests/shots/flight_r7_probes --test=ceiling` and `--suite=r7x_realworld` (outputs under `verify/r7_builder/`) |
| Round-6 diagnostics | `... -- --dir=res://tests/shots --suite=flight_r6_diag --test=<diag_slope_touchdown \| diag_slope_takeoff \| diag_ridge \| diag_ground_glide_jerk \| diag_tick_cost \| diag_fixture_cost \| diag_space_immediate \| diag_cast_overlap>` (`--species=`, `--deg=`, `--yaw=`, `--vf=`, `--vs=`, `--gap=`, `--roll=`) |
| Round-5 diagnostics | `... -- --dir=res://tests/shots --suite=flight_r5_diag --test=<diag_flare \| diag_touchdown \| diag_breeze \| diag_air_accel>` |
| Tests against the round-5 code | `python3 tests/shots/flight_r6_oldcode_check.py` (private copy with `artifacts/flight/verify/r5_sources`); round 5's against round 4: `flight_r5_oldcode_check.py` |
| The verifiers' probes, redirected | `python3 tests/shots/flight_r6_probe_copies.py`, then `... -- --dir=res://tests/shots/flight_r6_probes --suite=<r6x_experience \| r6eng_probe \| r5x_experience \| r5eng_probe \| r4x_experience \| r4eng_probe \| r3_experience>` (outputs under `verify/r6_builder/`) |
| Heave replay | `... -- --dir=res://tests/shots --suite=flight_heave_dump [--set=heldout]`, then `python3 tests/shots/flight_heave_eval.py` |
| Mutation runs | `python3 tests/shots/flight_mutants.py [substring \| round=N]` (private copy) |
| Simulator | `tests/shots/flight_sim_run.sh` (SIM-05) and the `tools/xr.sh` runs in §5 |

**What `--full` adds** (the default keeps one representative case per criterion, to
stay inside the 60 s budget):

| Test | Default | `--full` |
|---|---|---|
| G1b | the sparrow's 3 × 3 grid; at the pigeon and eagle the steepest touchdown and the skid | the grid at 3 sizes |
| G3d | pigeon: up 20°, up 38°, across 38°, down 20° | three sizes |
| G4 | 5 flares from 1 span: +40° at 3 sizes, +20° at pigeon and eagle | the verifier's grid: +20 / +30 / +40° × 0.3 / 1 / 2 spans × 3 sizes |
| G8 | 38° (sparrow, pigeon), 20° and 44° (eagle) | 20 / 30 / 38 / 44° at three sizes |
| G9 | a 44° roof | 38° and 44° |
| P6 | the 60 s rest at the sparrow (10 s at pigeon and eagle); fidget and launch at 3 sizes | the 60 s rest at 3 sizes |
| P13 | sparrow (the hard case) | three sizes |
| VT-1 / VT-5 | 3 000 / 1 000 random owe sequences | 20 000 / 5 000 |
| C8b | incidences 30/60/90° | + 45/75° |
| C10 | 12 room / low-wall flights | the round-4 verifier's 96-flight room sweep and low walls |
| C11 | eagle, 48 falls | three sizes |
| P6b | pigeon, 6 postures | 20 postures at 3 sizes |
| P10 | sparrow (the hard case) | three sizes and the whole glide set |
| P11 | 2.1 m/s tailwind | + 1.5 m/s |
| PB-08 / PB-08b / PB-08c | reduced (sparrow + eagle, one seed of human jitter) | every size and seed |
| PB-27 | every case at the sparrow, the combined case at the others | every case at three sizes |
| FM-13, FM-17, FM-18c, FM-24 | pigeon | three sizes |
| CE-3 | the verifier's 8 cases for 16 s | for 40 s (the verifier's) |
| CE-4 | sparrow flapping and eagle soaring in the 4 m/s column, eagle in air rising everywhere, 30 s | 60 s (the verifier's), plus sparrow, starling and pigeon soaring, pigeon and sparrow (1.3 Hz) flapping, sparrow and pigeon in air rising everywhere |
| CE-5 | sparrow and eagle (1.3 Hz) | plus pigeon 2 Hz, starling 1.3 / 2 Hz, pigeon 1.3 Hz, sparrow 1 Hz |
| FM-20 | sparrow and eagle | every species |
| FM-23 | sparrow | three sizes |
| F9 (shaking) | sparrow | + eagle |
| F13 (desktop course) | sparrow | + pigeon |
| WI-30 (tracker glitches) | head and left hand | + right hand |
| B1 | pigeon, one seed, plus the three-size course | 6 species × 10 seeds |
| B2 | eagle seed 8 (the heave case) | 10 seeds × 3 sizes × {normal, sim} and the completion rates |

| # | Criterion | Command (suite / test) | Evidence |
|---|---|---|---|
| F1 | Flap lift direction | `flight/flap_detector --test=f1`, `flight/flight_model --test=fm11` | `f1_flap_impulse.png`, `f1_hover.png` |
| F2 | AoA / balloon | `--test=fm03`, `--test=fm04` | `f2_balloon_sag.png`, `f2_alpha_map.png` |
| F3 | Stall and recovery | `--test=fm05`, `--test=fm06`; near the ground `flight/ground --test=g5` (G5, G5b) | `f3_stall.png`, `f3_lift_curve.png` |
| F4 | Coordinated turn, auto-level, arm dihedral; one-wing strokes | `--test=fm08`, `fm09`, `fm10`, `fm18`; `flight/player_bird --test=pb27`, `pb28`; `flight/wing_input` | `f4_turn.png`, `wi_channels.png`, `r4_strokes.png` |
| F5 | Tuck dive, pull-out | `--test=fm15` | `f5_tuck_dive.png` |
| F6 | Updraft ≥ 3 m/s climbs without flapping | `--test=fm19`, `--test=fm20` | `f6_thermals.png` |
| F7 | Envelope vs SizeRules; ordering | `flight/envelope` | `f7_turn_circles.png`, `f7_glide_polars.png` |
| F8 | Energy 2 % / 20 s; no NaN | `--test=fm22`, `fm23`, `fm23b`, `fm24`; `flight/player_bird --test=fm24c`, `pb19b`; `--test=wi30`, `pb19`, `hs3` | `f8_energy.png` |
| F9 | Anti-cheese | `flight/flap_detector --test=wi14`, `--test=f9`, `--test=wi15`; frame hitches `flight/wing_input --test=wi34`, `flight/player_bird --test=pb31`, `--test=pb33` | `r5_resume_hitch.png` |
| F10 | Continuous collision, perching, the ground, slopes and roofs | `flight/collision` (C1–C12), `flight/perch` (P1–P14), `flight/ground` (G1–G10) | `r6_slopes.png`, `r6_takeoff.png`, `r6_roof_*.png`, `r5_ground.png`, `r5_resume_hitch.png`, `r4_view_turns.png`, `r4_perch_rest.png`, `r3_perch_wind.png`, `perch_wind_sweep_*.json`, `shot_*_side_perch.png`, `shot_*_perched.png` |
| F11 | Comfort | `flight/view_turn` (VT-1…VT-6); `flight/player_bird --test=f11`, `pb0`, `pb08`, `pb24`, `pb26`, `pb27`, `pb29`, `pb30`, `pb32`, `pb34`; `flight/heave`; `flight/ground --test=g1` (G1, G1b, G1c); the fixture's monitor in every scenario | `f11_comfort.png`, `pb08_heave.png`, `r4_view_turns.png`, `r6_slopes.png` |
| F12 | Bot completes the course at 3 sizes | `flight/bot_course` (`--full`) | `b1_course_*.png/.csv`, `bot_sweep_full_report.json`, `shot_*.png` |
| F13 | Desktop controls fly the lab | `flight/desktop` | `f13_keys_*.png` |
| F14 | Meta XR Simulator | `tests/shots/flight_sim_run.sh`; `tools/xr.sh` runs in §5 | `sim05_result.json`, `sim05_run.log`, `xr_simdrive_*.png`, `xr_hybrid_turn_*.png` |

**Results by criterion**

- **F1**
  - Flat-stroke impulse is 0.0° from vertical.
  - A 17° tilt gives forward/up 0.36.
  - Sustained flapping climbs +54…62 m where gliding sinks 22…26 m.
  - **Upstroke from the applied impulse** (FM-11b and f1, counterfactual runs):
    - +0.32 / −0.12 / −0.13 at model level;
    - +0.30 / −0.10 / −0.11 through the pose chain.
- **F2**
  - Pitch +0.5: rise of 7.9 / 7.8 / 5.9 spans.
  - Pitch −0.5: the nose drops, V(3 s) = 1.10–1.18 V0.
- **F3**
  - Stalls in 0.40–0.44 s.
  - Separated flow ≤ 0.60 CL_max.
  - Recovery in 0.36–0.44 T_ph.
  - **Near the ground (G5, round 5):** below the stall guard (sparrow 9.2 m, pigeon
    9.7 m, eagle 10.8 m) full nose-up held 3 s gives no stall and α stays within the
    protected top. Above it the deliberate stall is there. A stall entered above it is
    released within 0.3–1.2 s once below it. The sim preset stalls anywhere.
  - **In the game (G5b, round 6):** a sparrow holding full nose-up stalls from 15 and
    25 m (2 stalls each), never from 5 m. Over a 25 m flat roof a full flare from a
    span up stalls nowhere below the guard: the sparrow and pigeon not at all, the
    eagle once, 16.2 m above the roof at the top of its zoom; no stun, at rest on the
    roof.
- **F4**
  - Heading rate / (g tan φ / V) = 0.985–1.001, sideslip 0.0°.
  - Wings level within 1.12–1.19 t90.
  - Arm dihedral rolls, also in the simulator (+22.2° bank).
  - One-arm strokes turn away consistently, and uneven arms fly straight.
- **F5**
  - 0.95 V_max in 3.3 / 4.4 / 6.2 s, never above 1.03 V_max.
  - Pull-out ≤ n_max + 0.2.
- **F6**
  - +1.28…+1.50 m/s in a 3 m/s updraft.
  - Thermal circling: +1.4…+3.2 m/s.
- **F7**
  - All ratios 0.91–1.14.
  - Bigger birds are faster and turn wider.
- **F8**
  - Drift ≤ 0.1 % in 20 s.
  - 10k random frames stay finite.
  - A NaN/INF state is restored (FM-23b).
  - A 1 s hitch advances 0.1 s (PB-19b).
  - Against 360 Hz, the path agrees within 0.4–0.9 %; the chain at 72 / 90 / 120 Hz
    agrees within 2.3 % (FM-24c).
- **F9**
  - Shakes to ±10 cm at 4–12 Hz: 0 onsets.
  - The arc bank holds.
  - Wrist-twist jitter is not a trim.
  - **Frame hitches (round 5):**
    - 0.1 s ticks among slow arm sweeps flap nothing (PB-31; round 4: 2–3 flaps);
    - engine hitches through the XR source give 0 onsets, where round 4 gave 2
      (WI-34); strokes keep their onsets and effort;
    - the same hitches through the game's own default XR source (PB-33, round 6):
      0 flaps, 2 with its frame timing off.
- **F10**
  - **C1b:** 300 real-PlayerBird shots per size at a 1 cm rod, 0 tunnels.
  - **Stuns:** one per wall hit; the contact turns ≤ 40° (C8, C8b). The total forced
    turn in the 3 s after a hit is ≤ min(incidence + 20°, 40°) + 40°: measured 40 /
    45 / 62–74°.
  - **Room and floor stuns never spin the view (C10).**
  - **A fall along a wall is not a floor hit (C11).**
  - **Pressed against a wall, the bird slides along it at its speed (C12, round 5):**
    in contact on all 144 ticks, it covers 17.6 m (sparrow) and 38.6 m (eagle) in 2 s.
  - **C9:** a V_max dive into the ground stuns once, then GROUNDED.
  - **Perch:**
    - P1–P9 pass;
    - P6/P6b: the rest pose never leaves the perch;
    - P10/P11: perching in 2.1 m/s head, cross and tail winds. P11 also asserts
      that at least 7 of the 9 tailwind glide-ins from above the glide path grab the
      branch without bumping it first (8 of 9 for both at 2.1 m/s), and it reports the
      landing speed half a span out (median 0.96–0.98 V_cap, the plan's 0.95);
    - P12 (round 5): a tucked bird in reach of the grip is not captured, the same bird
      spread is;
    - P13 (round 5): the sparrow perches in the full 2.64 m/s breeze: head, cross and
      tail in 1.40 / 0.78 / 0.22 s (round 4: never head or cross). All three sizes
      pass with `--full`.
  - **Ground (round 5):**
    - G1 (the flat, PB-11's set-up): the touchdown's worst per-tick view Δv is
      0.14 / 0.07 / 0.03 × the touchdown speed since round 6's feet (round 5: 0.32 /
      0.08 / 0.05; round 4: 0.98 / 0.58 / 0.90; bound 0.45).
    - G2: a neutral glide into a meadow never skims below V_min (round 4: 3.3–15.1 s)
      and rests in 3.4 / 8.7 / 18.4 s (round 4: 9.7 / 21.8 / 45 s).
    - G3: the run-out is v²/2μg within 3 % (5.8 / 4.5 / 3.1 spans from V_min),
      decelerating at μg. Off an edge the bird flies on at its running speed; into a
      wall at 45° the run turns along it; a take-off keeps the run's speed.
    - G4: flares near the ground land with no stun: default 5 of 5; `--full` 27 of 27,
      landing 0.4–19.1 s after the flare.
    - G6: the landing configuration only for a landing (a low pull-up zooms as high).
    - G7: a branch top is not ground.
  - **Slopes and roofs (round 6):**
    - G1: touchdowns on the flat, 10 / 20 / 38 / 44° upslopes, a 38° roof crossed at
      60° and a 10° downslope, two approaches, three sizes: 0 stuns, worst per-tick
      view Δv 0.335 / 0.162 / 0.123 × the approach speed (bound 0.45; round 5 up to
      0.85 and stuns on 38–44° roofs); the eye never nearer the surface than 0.25 body
      radii; the legs at rest within 0.6 s.
    - G1b: the touchdown envelope on the flat (forward 0.4–1.0, sinking 0.3–0.7 V_min,
      `--full`): worst touchdown 0.309 / 0.164 / 0.076. The case above the touchdown
      speed (forward 1.0, sinking 0.7: 1.22 V_min) is a skid first: the legs take it
      for the pigeon and eagle (0.243 / 0.119); the sparrow's is too hard for them and
      stops the view with the body (0.50), never harder (G1c). The legs stand back up
      at ≤ 2 g.
    - G3d: run-outs along slopes are v²/2a within 0.1 % (up 20° at 0.91 g, up 38° at
      1.09 g, across 38° at 0.71 g, down 20° at the 0.3 g minimum); the body stays on
      the plane within 1 mm.
    - G3e: a run from the flat into a 20° hill turns up it; a run up a 38° roof leaves
      the ground at the ridge; ≤ 0.45, no stun.
    - G8: facing up 20–44° slopes, took_off on the take-off stroke (0.35 s sparrow,
      1.11 s pigeon and eagle), at most 2 took_off in 6 s, never touched down within
      1 s of a take-off, never sliding back; way made 26–50 / 10–24 / 5–9 spans.
    - G9: a village roof (38°, 44°) facing the ridge: every size leaves over the ridge,
      one take-off, no touchdown after it.
    - G10: banking away from a 30° hillside: pigeon 39 spans clear, eagle 2.7.
  - **P14 (round 6):** a scrape at 1.5 V_cap locks the capture for 0.5 s; a brush at
    0.7 V_cap does not.
- **F11**
  - The rig basis is level with unit scale every tick.
  - Yaw ≤ 240°/s and ≤ 720°/s², asserted at the cap in every scenario.
  - Camera = body + heave (+ the legs' dip on the ground), ±1 mm.
  - View jerk ≤ 1.1× the body's.
  - ViewTurn ≤ 120°/s and ≤ 240°/s² by construction (VT-1…VT-4). With the tick length
    changing every tick, the overshoot is ≤ 0.25° (VT-5).
  - Perched or grounded, the rig is at rest 0.35 s after touching down.
  - Uneven strokes wobble the view ≤ 0.001°.
  - **Round 5:**
    - resume from the menu pose: bank ≤ 0.4°, view turn ≤ 0.1° (PB-29);
    - a recenter mid-payout: no safety-net tick (PB-30);
    - a world-scale snap: the camera on the body within 1 mm on every tick (PB-32).
  - **Round 6:**
    - the legs bend along the surface normal and never jolt the view more than the
      body (G1c: 23.7 against the body's 25.9 cm perceived);
    - telemetry read inside an Events handler is rebuilt after the tick (PB-34);
    - the view's turn is conserved across ±180° (VT-6; VT-1 `--full` lost 2.5·10⁻⁵ rad
      to Godot's `wrapf` before).
- **F12**
  - B1 at 3 sizes: 0 stuns, 0 frame hits, perched in time.
  - **Full sweep (`--full`, final code):**
    - B1 60 / 60 (6 species × 10 seeds);
    - B2 novice window + turn: 96.7 % (29 / 30) with normal assists vs 0 % with sim.
      The one miss, sparrow seed 9, hits the facade once (as in round 4).
  - **Heave on the 30 novice flights:** worst window 1.39×.
- **F13**
  - Keys alone fly 3 rings, the 180° turn, a tuck dive, a landing and a take-off
    (sparrow by default, sparrow and pigeon with `--full`).
  - The comfort monitor is clean.
- **F14**
  - **SIM-05 PASS, 6 of 6 checks** (18:14, after the last source edit at 18:09; frame
    timing on):
    - spread arms read ext 1.00 / 1.00;
    - neutral captured;
    - a −18° wrist twist → bank −18.7°;
    - a 20° arm raise → bank +20.7°;
    - strokes → 4 onsets per wing, 9 flap events;
    - a 66° headset look about the neck shows the left wing for the whole hold, with
      rig turn 0.000007° and roll input unchanged.
  - Camera error 0.0 mm from the first tracked frame in both XR starts on the final
    code (SIM-05 and the hybrid course); 0 SCRIPT ERRORs.

**Other spec tests in the suite**
- FM-01/02/07/13/14/17/21/25/26/27/28/29/30/31;
- WI-01…34;
- PB-03…09/11;
- PB-13 (S1–S6);
- PB-14/15/16/17/19/20/21/22/23/25/29/30/31/32/33/34;
- PERF-01, HS-1…4, C1–C12, P1–P14, G1–G10 (G1b, G1c, G3b–e, G5b), VT-1…6, WS-copy, B3.

**PERF-01.** One player tick (pose, WingInput, model, sweep and rig, flapping and
turning) is timed as the median of 5 batches. Budget 350 µs.
- Round 6, final suite run at load 12: medians 248 µs (sparrow) and 204 µs (eagle);
  the fastest batch of each size 184 µs (the batches spread with the load).
- Round 5 (load 9–10): 204 / 200 µs. At load 15–16 the eagle's batches spread from 190
  to 329 µs.
- Round 6's per-tick additions (the feet's sweep while slow, the longer ground ray, the
  legs along a normal) are paid for by an exact WingState copy (the reflective one was
  ~20 µs), an O(1) dihedral window mean, no per-tick allocations in WingInput, wind
  samples cached within a model step, and the wingtip wind sampled only when telemetry
  is read.
- Round 5's per-tick additions (the ground query, the landing configuration, the
  legs) are paid for by building telemetry only when it is read, and by caching the
  assist preset: `tuning.assists()` had built a dictionary on every call.

**Wind sweeps on the final code.** Share of approaches that perch; round 4 in brackets
where it differs.

27 slow glide-ins per cell (`--set=glide`, asserted):

| | still | head 1.5 | head 2.1 | cross 1.5 | cross 2.1 | tail 1.5 | tail 2.1 |
|---|---|---|---|---|---|---|---|
| sparrow | 1.00 | 1.00 | 1.00 (0.96) | 1.00 | 1.00 | 0.89 | 0.81 (0.78) |
| pigeon | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 (0.96) | 0.96 (0.93) |
| eagle | 1.00 | 0.96 | 0.93 | 1.00 | 1.00 | 0.96 | 0.96 |

- Stuns: none.
- Rig yaw acceleration in the air: ≤ 270°/s².
- View turn after the touchdown: ≤ 4.3°.

The round-3 verifier's 54 close approaches starting 2–6 spans out (`--set=verifier`,
reported, asserted only for comfort):

| | still | head 1.5 | head 2.1 | cross 1.5 | cross 2.1 | tail 1.5 | tail 2.1 |
|---|---|---|---|---|---|---|---|
| sparrow | 0.76 | 0.81 (0.80) | 0.81 (0.63) | 0.93 (0.91) | 0.57 (0.39) | 0.85 (0.80) | 0.72 |
| pigeon | 0.98 | 0.96 (0.93) | 0.96 (0.87) | 1.00 | 1.00 | 1.00 | 1.00 (0.94) |
| eagle | 0.81 | 0.93 | 0.93 (0.91) | 0.93 | 0.94 | 0.93 | 0.81 |

- **Rig in the air:** ≤ 600°/s², as designed. A first run of this sweep in round 5
  read 720°/s²: the branch-top touchdown bug (G7), fixed.
- **Crabbing sparrow after the touchdown:** its crab turns the rig up to ~150°/s at the
  touchdown, and braking at the cap then turns the view ≤ 9.7° (v²/2a). That is up
  from 6.9° because more of the close crosswind approaches now perch.
- **Stuns:** one, the eagle in the 2.1 m/s tailwind, as in round 4.

## 4. Evidence index (`artifacts/flight/`)

All regenerated on the final round-6 code unless marked (the plots and renders after the last source edit at 18:09).

| File | Shows |
|---|---|
| `ceiling/ce_lid.png`, `ceiling/ce_lid_full.png` | Integration, the arena's lid: height under the lid and vertical speed for the verifier's scenario (reference strokes from 40 m under), and the height and the air's density arriving from 205 m under a 300 m lid (default and `--full` runs) |
| `ceiling/diag_before.txt`, `ceiling/diag_after.txt` | The verifier's lid scenarios (climbs, thermals, the real world's lid, the zoom, the below-250 m comparison) on the round-6 code and on the final code |
| `ceiling/diag_arr_{quad,smooth,lin}.txt`, `ceiling/diag_feel_{q,s,lin,q50}.txt` | The profile comparison (arrival from below, level-off deceleration against stopping the wings and flapping on in full air) |
| `ceiling/diag_updraft*.txt`, `ceiling/diag_zoom.txt`, `ceiling/diag_trace.txt` | Air rising 4 and 8 m/s everywhere (with and without the 5 m of dead air), the zoom into the lid, one trace |
| `ceiling/npc_diag_final.txt` | NPCs at the lid in the real world (and a thermal column through a lid) |
| `verify/r7_builder/` | The integration verifier's own lid probes (`tests/probes/flight/r7x_*`), run from copies redirected here (`tests/shots/flight_r7_probes/`, `--test=ceiling`), on the final code: `probe_ceiling.log`, `probe_realworld.log`, `experience_probe.txt`, `realworld_probe.txt` and their plot `r7x_ceiling_lid.png`, redrawn on the final code (the caption is the verifier's, written for the old code; the legend reads stuns 0, collided 0). The verifier's own `verify/r7x/` is untouched |
| `ceiling/mutants.txt`, `ceiling/ce_old_code_check.log` | The six ceiling mutants (all caught); the CE suite on the round-6 code (CE-2…CE-6 fail) |
| `ceiling/suite_final.log`, `ceiling/suite_final_load13.log`, `ceiling/ce_default.log`, `ceiling/ce_full.log` | The flight suite (182 of 182: 58.7 s at load 6–9, 77.8 s at load 13–14) and the ceiling suite, default and `--full` |
| `overview.png` | Contact sheet of all plots |
| `r6_slopes.png` | Round 6: the touchdown's worst per-tick view Δv against the slope rising ahead (both approaches, three sizes, round 5's values as faint points), pigeon run-outs along slopes, and the legs of a steep sparrow touchdown (camera and body along the normal) |
| `r6_takeoff.png` | Round 6: took_off events and the way made in 6 s of strokes facing up 20–44° slopes (round 5 as faint points), and an eagle facing up 38° (straight on, banking away, a village roof) |
| `r6_roof_{sparrow,pigeon,eagle}_{touchdown,standing,eye,takeoff}.png` | Forward+ renders: a bird lands on a 38° village roof facing the ridge, stands, and takes off over the ridge (`tests/shots/flight_roof_shots.tscn`; log `verify/r6_builder/roof_shots.log`) |
| `r6_old_code_check.json` | Every round-6 test run against the round-5 sources: which fail, with the first failing assertions |
| `f1_*`, `f2_*`, `f3_*`, `f4_turn.png`, `f5_tuck_dive.png`, `f6_thermals.png`, `f7_*`, `f8_energy.png`, `f11_comfort.png`, `wi_channels.png`, `pb08_heave.png` | The criteria plots |
| `r5_ground.png` | Round 5 ground landing: neutral glides (belly height and speed), full flares from 1 span, and the touchdown's per-tick view Δv against the 0.45 bound |
| `r5_resume_hitch.png` | Round 5: bank after a resume from the menu pose; flap effort through engine frame hitches with and without frame timing; a sparrow perching into the full 2.64 m/s breeze |
| `r4_view_turns.png`, `r4_strokes.png`, `r4_perch_rest.png`, `r3_perch_wind.png` | Rounds 3–4 (the ViewTurn, strokes, the perch rest state, perching in wind) |
| `perch_wind_sweep_glide.json`, `perch_wind_sweep_verifier.json` | The wind sweeps (final code); round 4's copies in `verify/r5_builder/*_round4.json` |
| `r5_old_code_check.json` | Round 5's tests against the round-4 sources |
| `mutants.json` | Every mutant of rounds 1–6, written by `tests/shots/flight_mutants.py` (final code; logs `verify/r6_builder/mutants_all_final.log` and, for the three mutants re-pointed after it, `mutants_retargeted.log`) |
| `heave_eval.txt`, `heave_eval.json`, `dev/heave_study/` | Round 2: the camera heave study |
| `b1_course_{sparrow,pigeon,eagle}.png/.csv`, `bot_sweep_full_report.json` | Bot course tracks and the full-sweep report (B1, B2, heave per novice flight), from the `--full` run on the final code |
| `f13_keys_{sparrow,pigeon}.png` | The lab flown by keys |
| `shot_<species>_{overview,side_flap,chase_ring,eye_wing,chase_turn,window_wall,eye_window,side_perch,perched}.png` | Forward+ renders of the lab course for sparrow, pigeon and eagle (round 5; the bot's course and its perch landing do not touch round 6's ground code) |
| `xr_simdrive_{spread_done,tilt_left,raise_left,strokes_begin,look_left_wing}.png`, `sim05_result.json`, `sim05_run.log`, `sim_driver.log` | SIM-05 on the final code (18:14, `run_20260926_181338`) |
| `xr_hybrid_turn_{8,16,18,20,22,32}s.png` | Hybrid course in the simulator on the final code (18:15, `run_20260926_181510`) |
| `verify/r6_builder/` | Round 6's runs on the final code: the suite (`suite_final_run2.log`, `report_flight_final.json`), the `--full` suite (`suite_full_final.log`, `report_flight_full_final.json`), the verifiers' probes redirected (`probe_*.log` and the copies' outputs under `r6exp/`, `r6eng/`, …; `r6exp/r6x_slopes_roofs.png` is the experience verifier's own plot drawn on the final code: every touchdown up to 44° at ≤ 0.32, no stun), the old-code check and mutation logs, the roof renders' log |
| `verify/r5_sources/` | The round-5 flight sources and tests (README), used by the round-6 old-code check |
| `verify/r6exp/`, `verify/r6eng/` | The round-6 verifiers' evidence (untouched: the re-runs write to `verify/r6_builder/`) |
| `verify/r5_builder/` | Round 5's re-runs: the verifiers' probes on the final code (`probe_*.log`, the redirected copies' outputs), the suite and mutation logs, the bot sweep log, the first touchdown/probe re-runs |
| `verify/r4_sources/` | The round-4 flight sources (README), used by the old-code check |
| `verify/r5_sim05_first_run/` | The first round-5 SIM-05 run (stalled by NaN in the driver's JSON; README) |
| `verify/r5exp/`, `verify/r5eng/` | The round-5 verifiers' evidence. `r5exp/experience_probe.txt` was overwritten by a first re-run of their probe and restored from their own run log (`probe_final.log`); their `r5x_ground_landing.png` could not be restored (the re-run's version is `verify/r5_builder/r5x_ground_landing_rerun_step1.png`) |
| `verify/r3_sources/`, `verify/r4_round3_code/`, `verify/r4_builder_rerun/`, `verify/r4_sim05_first_run/`, `verify/r3_as_reported/`, `verify/r3_builder_rerun/` | Earlier rounds' evidence, kept for the record |
| `archive/` | Superseded captures (round 1 and a round-2 probe's strays); see `archive/README.md` |

Test reports (JSON with every metric) are in `artifacts/tests/report_flight_*.json`.

## 5. Meta XR Simulator (F14; SIM-01…05)

### 1. SIM-05: the simulator's own controllers and headset fly the bird

Command: `tests/shots/flight_sim_run.sh --species=pigeon` (Forward+ mirror).

- **Driver actions:**
  1. Selects one controller at a time with the simulator's `]` / `[` bindings (in
     memory, restored afterwards).
  2. Slides each controller out in line with the shoulder and yaws it along the arm.
  3. Twists one wrist, raises one arm and strokes each wing.
  4. Levels both arms at the spread height again, closed loop on the controllers'
     height.
  5. Selects the headset alone, yaws it ~60° toward the left wing, then moves it so
     WingInput's neck pivot stays put, as a person turns the head. It holds the look
     and turns back the same way.
- **Checks: all 6 pass** on the final round-6 code (18:14, after the last source edit
  at 18:09; `run_20260926_181338`) with the lab's XR source frame-timed (the F14 row of
  §3). Persistent settings are unchanged (SHA-256). Round 5's run at 15:18 predated its
  own last edit (the engineering verifier's finding); round 6 re-ran after its last.
- **The first round-5 run stalled** (`verify/r5_sim05_first_run/`), and flight was not
  the cause.
  - The simulator reported a controller yawed ~89° with Euler angles [0, NaN, 0]
    (the heading from its pose was fine).
  - The driver wrote it into its JSON as a bare `NaN`, which the lab's parser rejects.
  - The lab never saw the driver's steps after the first.
  - The driver now writes NaN / inf as `null` (`Report.write`).

### 2. The first XR frame (the round-5 minor finding)

Round 6, on the final code: the SIM-05 run and the hybrid course (§3) both read
`cam-body 0.0 mm` from the first tracked frame, worst 0.0 mm; `pose_dt` 0 for the
start-up repeats and 13.8–13.9 ms per frame after.

Round 5: four XR starts on its code: the SIM-05 run and three `tools/xr.sh 12 "--rendering-method forward_plus res://scenes/dev/flight_dev.tscn" -- --pose=xr --species=pigeon --view=eye --xrdiag`
runs (`run_20260926_152014`, `_152036`, `_152055`).
- The first tracked frame reads `cam-body 0.0 mm` at `ws 0.388` in every run.
- The worst of each run is 0.0 mm; 0 SCRIPT ERRORs.
- `pose_dt` reads 0 for the start-up repeats and 13.9 ms per frame after.

### 3. Hybrid course through the turn

Command: `tools/xr.sh 45 "--rendering-method forward_plus res://scenes/dev/flight_dev.tscn" -- --pose=script:course --species=sparrow --xrdiag --labshot=8,16,18,20,22,32 --labshot_prefix=hybrid_turn`
(run `run_20260926_181510`, the final round-6 code; round 5's `run_20260926_152123`).

- The bot flew the course and perched at 31 s.
- XROrigin3D tilt was 0.000° and camera roll 0.00° on every logged second, while the
  bird banked up to 31°.
- The camera error was 0.0 mm throughout; 0 SCRIPT ERRORs.
- `xr_hybrid_turn_22s.png` shows the new facade from the approach: 13 × 20 windows of
  about 20 px each and the small shuttered opening, where round 4 had a dense dotted
  patch.

### 4. Round-1 runs

The round-1 XRPoseSource runs with the simulator's fixed controllers (SIM-01 / SIM-04)
are still valid for what they measured: grip = aim·Rx(60.09°), 5.00° from the
convention. Their captures are archived.

## 6. Known limits and open items

- **The top of the sky (integration).** Flapping tops out 17–27 m under the 300 m lid
  (273–283 m), and a glider in a thermal 8–12 m under it. The last 5 m are dead air.
  - **Thermals near the top:** the thin air makes a circling bird fly faster at the
    same bank (true airspeed), so its circle widens (the sparrow's from 8 to ~50 m).
    Near the top it drifts out of a thermal's core and sinks back out. In the
    verifier's 4 m/s column the circlers first top out 9–12 m under the lid, then
    range 12–44 m under it over the rest of the minute (`diag_after.txt`).
  - **Extreme air:** air rising at 8 m/s everywhere (twice the strongest thermal in
    the game) can carry an eagle's phugoid zoom up to the lid (`diag_updraft8.txt`,
    6 contacts in 60 s). Those contacts are slides, as any contact with the lid is.
  - **A zoom into the lid** is a slide with the usual `player_collided` event; its
    upward speed is taken in one tick, as at any wall.
- **Observed, not changed (outside the lid):** flapping hard with the leading edges up
  (pitch 0.2) while banked slows a starling or an eagle below V_min, where it cannot
  hover (hover force 1.02 and 0.6 W). It then mushes down at ~1.8–2.4 m/s whatever
  the strokes (`diag_trace.txt` and the diag's eagle and starling thermal cases).
  Frantic 2 Hz 60° strokes with the wrists neutral take a sparrow into a vertical
  hover-climb (~0.75 m/s), slower than reference strokes (4.6 m/s). Both are the
  existing model (hover-capable small birds, the endurance cap), and the round-6
  code does the same.

- **Suite runtime (load-dependent).** Integration: 182 tests in 13 suites.
  - 57.4 s by the runner at load 4–5;
  - 58.7 s at load 6–9 (55.8 s CPU; `ceiling/suite_final.log`);
  - 77.8 s at load 13–14 (64.9 s CPU; `ceiling/suite_final_load13.log`), while other
    agents' runs shared the machine.
  The ceiling suite (`ceiling_test.gd`) is 4.4–6.4 s of it, and its `--full` run
  takes ~20 s. Round 6: 175 tests in 12 suites, measured on the round-6 code:
  - 52.9 s by the runner at load 4.5–5.4 (50.2 s CPU; `verify/r6_builder/suite_final_run3.log`,
    before G1b's default gained the two skid cases, ~0.2 s);
  - on the final files 62.6 s at load 10–11 (56.9 s CPU; `suite_final_run4.log`) and
    66.2 s at load 12 (59.2 s CPU; `suite_final_run2.log`), while other agents' Godot
    runs shared the machine.
  Round 5 measured 60 s CPU at load 11–15 with 162 tests. Round 6 added 13 tests (the
  slopes, roofs and take-offs the verifiers asked for, ~5 s) and cut more than that.
  The PlayerBird tick is ~200 µs of GDScript (WingInput and the model ~50 µs each), and
  175 000 of them are ~60 % of the suite. So on a machine at load 12 the wall clock is
  over 60 s, while at moderate load it is under. Further cuts would have to drop
  coverage (sizes, seeds or sweeps from the default run).
- **Big birds facing up a long steep slope** cannot out-climb it straight ahead: a
  pigeon above ~17–20°, an eagle above ~12° (F7's climb rates). They take off (on the
  take-off stroke, once per bound), bound up the slope 5–25 spans in 6 s, and stand
  when a launch is spent. They leave over a roof's ridge (every village roof: G9), by
  banking away (G10), or by turning round on the ground. The game does not hint at the
  turn: the view stays the player's, and flight never turns it for them.
- **A hard belly skid** (above the touchdown speed, the speed into the ground over a
  tick beyond the legs' flex: a sparrow sinking at 0.7 V_min at 1.22 V_min) stops the
  view with the body, 0.50× the approach speed in one tick, as in round 5. The legs
  cannot spread it over two ticks. G1c pins that it is never more than the body's own
  jolt.
- **The legs bend along the surface normal:** on a slope the camera's offset from the
  body has a horizontal part for ~0.1–0.3 s after a touchdown (up to ~3 cm for a
  sparrow). `heave_offset` telemetry is its vertical part, `view_offset()` the whole.
- **A run over a ridge launches the bird:** it lands again on the far slope, a second
  `player_perched` (G3e).
- **A steep downhill run-out** brakes at 0.3 g (the feet's minimum), so a touchdown
  facing a 38° roof's gutter at speed can run off the eave and fly on.
- **An eagle's neutral glide into a meadow rests after 18.4 s** from 6 spans + 2 m.
  - That is inside the round-5 verifier's "about 20 s", but outside their earlier
    probe's 15 s check (§9).
  - The float in ground effect is the spec's G15 skim (PB-15 ≥ 40 spans). A flare of
    any size lands it sooner.
- **Moderate flares by big birds are slow.** An eagle's +20° flare from 2 spans lands
  after 19.1 s (G4 `--full` bound 20 s): at pitch ~0.3 the landing configuration is
  only just engaging. A fuller flare lands in 8–13 s.
- **No deliberate stall below ~9–11 m** (normal and novice presets, now over roofs as
  over terrain): near a surface a full flare is the maximum-lift flare. An eagle's
  flare zooms 7 spans up and may stall above the guard height. Stall practice is an
  altitude manoeuvre; the sim preset stalls anywhere.
- **Head-on stun, total view rotation.** The forced turn is ≤ 40° plus the falling
  bird's path snap (22–34° head-on). The rest is flown. All of it is paid inside
  120°/s and 240°/s², and C8b pins the forced total.
- **A bird wedged in a corner** (round 4, unchanged). With the arms still, a bird that
  stuns into a 90° corner can stay pressed into it and slide down it, because the
  stun turns it at most 40°; the player turns out. In the round-4 verifier's corner
  probe the birds drop below the walls' lower edge (y 57–59, walls from 60 m) and fly
  on under them. There is no tunnel.
- **Crabbing touchdowns** turn the view ≤ 9.7° after the touchdown (the rig braking at
  the 720°/s² cap from ~150°/s). That is the quickest stop the comfort contract allows.
- **Frame hitches from synthetic sources.** A synthetic pose source that reports a
  pose jump inside a normal-length tick, with no frame timing, still reads it as a
  fast hand (the round-5 engineering verifier's probes model the engine that way).
  In the game only XR poses hitch, and the game's own XR source is frame-timed (PB-33).
- **B2 novice completion 96.7 %** (as round 4). The one miss is sparrow seed 9, which
  hits the facade once.
- **Heave:**
  - a sparrow with ±20 % stroke-timing jitter keeps 0.87–0.935 of the body's band
    acceleration (the held-out seeds 41–43 at 0.9349; PB-08c's `--full` bound is 0.94,
    §2 round 6);
  - flap-glide bursts shorter than four strokes are not smoothed;
  - the camera follows the body's real bob for the first strokes and for irregular
    flapping (±80 cm perceived for a sparrow at ~1 Hz, `pb08_heave.png`). That is
    by design (removing it would hurt irregular flapping), but it needs judging on a
    headset.
- **Chain rate dependence:** FM-24c reads 2.3 % of the flown path.
- **Forced view turns are reported in telemetry** (`view_turn`, `view_turn_rate`) so
  the VR area's vignette can cover them; VR owns that choice.
- **Lab art** is a dev lab's: stand-in bird, box-built facade, procedural first-person
  wings. The roof renders use flight's own box geometry. The birds, world and VR areas
  own the game's models and first-person wing presence.
- **Needs the device:** R1 small-bird comfort, the heave above, the legs' bend on a
  slope, and the SIM-01 grip offset (exactly 5° in the simulator) still need judging
  on a headset.
- **Redundant second layers** (mutation runs, §9): the weathercock airspeed gate, the
  stall-protection rate limit, the heave benefit gate and weight low-pass, the perch
  hold, and the tailwind brake's ground-speed term. Removing any one changes no
  measured result beyond one clean approach (P11).
- **FM-28 / PERF-01** assert their budgets strictly only with `-- --perf`. At load 12
  the medians were 248 µs (sparrow) and 204 µs (eagle); the fastest batches 184 µs.

## 7. Contract changes

Recorded in `docs/ARCHITECTURE.md` under Contract changes, in the entries "flight",
"flight fix round 1", "flight fix round 2", "flight (fix round 3)", "flight (fix round 4)"
**"flight (fix round 5)"**, **"flight (fix round 6)"** and **"flight (integration:
the arena's lid)"**.

- **Behaviour (integration, the lid):**
  - under `World.ceiling` the air thins from 45 m below it (the body's top) to nothing
    5 m below it, and the flap force fades with lift and drag, so a bird cannot fly
    within ~8 m of the lid except by momentum;
  - a contact with the lid (met from below at `World.ceiling`) is never a stun or a
    touchdown: it is a slide, or silent under 0.5 m/s;
  - nothing changes below 250 m under the 300 m lid.
- **Additive (integration):** `FlightEnv.thin_air(gap, band, floor_gap)`,
  `FlightTuning.thin_air_band`, `thin_air_floor`, `PlayerBird.contacts["lid"]`.
  `FlightEnv.lift_scale` keeps its name and range; it now also scales the flap force.
  This supersedes FLIGHT_SPEC's "ceiling fade from World (thin air above
  World.ceiling − 20 m)" (§7.10, §15); the spec's "over ≥ 20 m" still holds (40 m).

- **Behaviour (round 6):**
  - slopes and roofs: the feet meet the ground first (`player_perched` at the feet's
    contact), a touchdown at up to 1 V_min into the surface, the run-out along the
    ground's plane (GROUNDED `velocity` can have a vertical part), a ridge launches
    the run, the legs bend along the surface normal (`view_offset()` can have a
    horizontal part; `heave_offset` is its vertical part);
  - take-off: the launch leaves the surface; no touchdown again while the bird keeps
    flapping, until two spans clear; a scramble that makes no way stands again;
  - the stall guard reads a ground ray down to its height (flat roofs count);
  - telemetry read inside an Events handler is rebuilt after the tick; the wingtip
    wind is sampled when telemetry is read.
- **Additive (round 6):** `PlayerBird.view_offset()`, `FlightModel.stall_guard_height()`,
  `FlightTuning.leg_reach`, `touchdown_vn`, `run_brake_min`, `take_off_hold_gap`,
  `take_off_hold_s`; `FlightGeometry.slope()`, `slope_normal()`, `gable_roof()`.

- **Behaviour (round 5):**
  - ground landing: friction, the touchdown at ≤ 1.2 V_min (never on perch geometry),
    the run-out while GROUNDED (`velocity` / `groundspeed` nonzero for up to ~2 s), and
    the legs' camera dip (in `heave_offset`);
  - near the ground: the stall guard and the landing configuration;
  - after a pause: the controls stay neutral until the arms settle, then fade in;
  - perching: the headwind hold, and no capture lockout from a slow brush;
  - a recenter stops the rig's turn;
  - flight's fallback world-scale driver rescales the rig at once;
  - `telemetry()` is built on the first read in a tick, not on every tick. It is the
    same Dictionary with the same values; every consumer calls it for each read.
- **Additive (round 5):**
  - `PoseFrame.pose_dt` (and the recordings' `"pd"`);
  - `XRPoseSource.frame_timing` and `clock`;
  - `WingInput.resume()`;
  - `FlapDetector.step(…, sample_dt)`;
  - `FlightEnv.agl`;
  - `FlightTuning.ground_friction`, `touchdown_speed`, `leg_flex`,
    `landing_config_spans`, `stall_guard_vmin2g`.
- **Note for VR (not a request):** between a `world_scale` snap and the XR server's
  next update the tracked nodes hold the old scale. The rendering is unaffected; this
  is what the lab's first XR frame showed.
- **Earlier rounds:** see the ARCHITECTURE entries (round 4: the ViewTurn follower, the
  stun turn ≤ 40°, the perch rest state, no flap side force, the kick's dead zone).

## 8. Round-6 verifier findings: disposition

| Finding | Severity | Done | Pinned by (mutant killed) |
|---|---|---|---|
| A bird that lands facing up a roof or hillside cannot take off (a took_off / perched pair per stroke) | major | The launch leaves the surface; the take-off hold (no touchdown while flapping, until two spans clear); the feet's scramble and foothold (§2 round 6) | G8, G9, G10 ("TAKEOFF into the slope", "TAKEOFF no hold", "TAKEOFF hold on the flap low-pass", "TAKEOFF belly-slides back") |
| An uphill touchdown stops the run-out in one tick; view jolt above 0.45; slow roof touchdowns stun | major | The feet's reach; the legs bend along the surface normal over reach + flex; touchdown at up to 1 V_min into the surface; the run-out keeps to the ground's plane; a ridge launches it; skids bend the legs; a gentle stand-up | G1, G1b, G3d, G3e ("FEET no reach", "FEET on perch geometry", "TOUCHDOWN vn cap 0.8 V_min", "LEGS vertical", "LEGS restart mid-bend", "LEGS stand up at the bend's deceleration", "SKID no legs", "RUN level brake", "RUN bends over a ridge"; round-5's ground mutants re-pointed) |
| The stall guard and landing configuration ignore elevated flat surfaces | minor | One ground ray per tick down to the guard height (§2 round 6) | G5b ("AGL ray 2 spans") |
| Suite runtime over the 60 s budget under shared load | minor | Partly: faster ticks and fixtures, P6's static rest at one size by default (§2 round 6). 52.9 s at load 5, but still 62.6–66.2 s at load 10–12 (§6) | measured, §6 |
| The game's XR source frame-timing wiring untested | minor | PB-33 (WI-34's hitches through the player's own XR source) | "GAME XR source not frame-timed" |
| In-game stall-guard height not pinned | minor | G5b at PlayerBird level (5 / 15 / 25 m, a 25 m roof) | "AGL 20 m low" |
| Fast-scrape capture lockout unpinned | minor | P14 | "SLIDE never locks the capture out" |
| Telemetry read inside an Events handler keeps mid-tick values | minor | The next read after the tick rebuilds | PB-34 ("TELEMETRY kept mid-tick") |
| G1 covers only a gentle touchdown | minor | G1 on slopes, roofs and the flat at two approaches and three sizes; G1b the touchdown envelope; the feet's reach brings every touchdown within 0.45. A hard skid above the touchdown speed stops the view with the body, never harder (G1c) | G1, G1b, G1c ("SKID no legs", "SKID legs even when hard") |
| XR evidence claimed on the final code predates the last edit | minor | SIM-05, the hybrid course in the simulator and the bot sweep re-run after the last source edit (§5; timestamps in the evidence index) | – |

**Tests against the round-5 code** (`tests/shots/flight_r6_oldcode_check.py`,
`r6_old_code_check.json`, the round-5 sources in `verify/r5_sources/`): all 10 new
behaviour tests (G1, G1b, G3d, G3e, G5b, G8, G9, G10, PB-34, VT-6) fail there on their
own assertions (no script errors: they read round-6 names defensively), for example:
- G1: the sparrow's PB-11 touchdown on a 20° upslope at 0.59× (and stuns on 38–44° roofs);
- G3d: the run up a 20° slope decelerates at 5.9 m/s² where v²/2a needs 5.5;
- G5b: a full flare over a 25 m roof stalls at 0.6 mm above it (guard 9.2 m);
- G8: the sparrow touches down again 0.014 s after its take-off;
- PB-34: `altitude_agl`, `heave_offset` and `tick_ms` keep their mid-tick values.
The 4 pins pass there, as expected: PB-33 and P14 (round-5 behaviour, the verifier's
mutant survivors), G1c and WS-copy (guards on round-6 changes: the skid legs and the
explicit WingState copy). Their mutants are caught.

**Where the experience verifier's probe asks for more than physics allows**
(`r6x_experience`, re-run on the final code, `verify/r6_builder/probe_r6x_experience.log`):
- **"6 s of strokes leave the ground (FLYING, > 2 spans clear at the end)" on long
  slopes facing uphill: the pigeon on 34° and steeper (a 38° slab in their other
  test), the eagle from 15°.** Their slab is 900 m
  long. Neither bird can out-climb a slope steeper than its climb gradient from a
  standing start; F7 pins those climb rates to SizeRules within 15 %. The take-off now
  works as their fix asked:
  - it leaves the ground on its take-off stroke;
  - `took_off` falls from 3–12 to 1–3 in 6 s (one per bound, each bound 5–25 spans up
    the slope);
  - no belly slide back.
  The ways off are the ones a bird has: over the ridge of a village roof (G9, every
  size), a banked turn away (G10, 2.7 and 39 spans clear), or turning round on the
  ground (their own `roof_turn_round` probe passes).
- **"No stall within a stall's recovery height of the roof": the eagle's 1 stall.** It
  happens 16.2 m above the 25 m roof, above the 10.8 m guard height, at the top of the
  flare's 7-span zoom, as over the meadow (FLIGHT_SPEC R5-3: a big bird may stall at
  the top of its zoom). Their assertion counts every stall. G5b pins the guard's intent:
  none below the guard height.
- Every other probe passes: the touchdowns on slopes and roofs (0 stuns, worst 0.34),
  the glides into rising ground, take-off from the flat, along a roof and toward its
  gutter, the turn-round, and resume-then-strokes.

`r6eng_probe` (8 / 8 pass on the final code):
- telemetry read inside a handler: 0 keys differ;
- the touchdown grid: 1 of 84 at 0.45, the rest below (round 5: 8 over, up to 0.70). The one is the sparrow sinking at 0.7 V_min, started 1 cm above the grass: inside its feet's reach, so the legs have 1 cm of reach plus the flex. From outside the reach (G1b) the same approach reads 0.31;
- random play near the ground: clean. The camera's horizontal offset from the body is
  ≤ 0.3 mm: the legs bend along a contact normal at the platform's edge (by design).
  "below ground" ≤ 0.5 mm (their bound: 2 mm).

**The earlier rounds' probes, redirected, on the final code**
(`verify/r6_builder/probe_*.log`):

| Probe | Result | Notes |
|---|---|---|
| `r5x_experience` | 17 / 18 | As round 5: only the eagle's 15 s rest check in `glide_into_the_ground` (it rests at 18.4 s; §9). This probe's sparrow nose-down glide found round 6's first skid legs jolting the view more than the body; fixed and pinned (G1c) before the final runs. |
| `r5eng_probe` | 6 / 9 | As round 5: the two synthetic-hitch probes and the zero-overshoot ViewTurn probe (§9). |
| `r4x_experience` | 20 / 20 | |
| `r4eng_probe` | 12 / 13 | As round 5: only the corner scenario (§6); the eagle's corner now passes its z-wall check. |
| `r3_experience` | 7 / 7 | |

## 9. Round-5 verifier findings: disposition (for the record)

| Finding | Severity | Done | Pinned by (mutant killed) |
|---|---|---|---|
| Landing on flat ground: skims below stall speed for up to 15 s, stops in one tick, a full flare stuns the sparrow | major | Friction; touchdown at ≤ 1.2 V_min (never on perch geometry); run-out at μg; the legs; the stall guard; the landing configuration (§2) | G1–G7 ("GROUND no friction", "touchdown 0.7 V_min", "one-tick stop", "no legs", "touchdown drops the tick", "run-out off-edge sticks", "lands on a branch top", "STALL guard off", "guard still holds", "LANDING config off", "config while climbing") |
| Resume from the pause menu adds a wingbeat; the arms' way back flies at full authority | minor | `WingInput.resume()` restarts the detectors; controls neutral until the arms settle, then a 0.4 s fade | PB-29 ("RESUME keeps strokes", "RESUME no hold") |
| The first XR frame's 1.04 m camera offset | minor | The fallback driver rescales the rig on a scale change; the lab counts tracked frames; 4 XR starts at 0.0 mm | PB-32 ("XR nodes keep the old scale") |
| A sparrow cannot perch in a 2.64 m/s head or cross wind | minor | Headwind closing-speed hold; no capture lockout from a slow brush | P13 ("PERCH no headwind hold", "slow brush locks out") |
| Lab facade pegboard; chase shots barely show the bird | minor | Human-scale windows over the whole facade; chase at 2.8 spans + 5 cm | screenshots and XR captures regenerated and reviewed |
| Frame hitches ≥ 56 ms turn slow arm motion into flaps | minor | Velocity, arcs and bank over the real pose interval: no 1/30 s clamp; XR frame timing (`pose_dt`) | PB-31, WI-34 ("HITCH clamped dt", "pose interval ignored", "repeats read as still") |
| Docs call the head-on stun's rotation flown; 22–34° is a forced path snap | minor | Composition stated (§2 round 4, FLIGHT_SPEC R5-12); the forced total pinned in C8b | C8b ("C8b forced-turn pin") |
| A recenter mid-payout leaves the rig's rate running | minor | The recenter zeroes the rig's rate and the flown-follow rate | PB-30 ("RECENTER keeps the rig rate") |
| 4 mutants survive the suite (slide continuation, near plane, world-scale ramp, capture while tucked) | minor | Each behaviour pinned | C12, PB-32, P12 (all 4 of the verifier's mutants caught) |
| ViewTurn's "no overshoot from rest" holds only for a constant tick | minor | Qualified in `view_turn.gd` and here; VT-5 pins the measured bounds | VT-5 |

**Tests against the round-4 code** (`tests/shots/flight_r5_oldcode_check.py`,
`r5_old_code_check.json`). Every round-5 test runs in a private copy with the round-4
flight sources (`verify/r4_sources/`).
- **All 14 behaviour tests fail there on their own assertions.** They read round-5
  members by name, so the old code runs. Examples:
  - G2: 3.3 / 5.5 s on the grass below V_min, and the pigeon not at rest in 20 s;
  - G4: the sparrow's full flare stuns;
  - G5: the sparrow stalls below the guard;
  - PB-29: flap force 0.28 × weight, bank 70.6°, heading change 78.6°;
  - PB-30: 8 safety-net ticks;
  - PB-31: 3 and 2 flaps;
  - PB-32: camera 1.39 m off the body;
  - WI-34: 2 onsets;
  - P13: the sparrow never perches head or cross.
- **The 4 pins of behaviour round 4 already had pass there,** as expected: C12, P12,
  VT-5 and C8b. They were the round-5 verifier's mutant survivors and are now covered
  by mutants.

**Mutation runs** (round 5's run, on its code, log
`verify/r5_builder/mutants_all_final.log`; `mutants.json` now holds round 6's): 87 of 93
caught.
- **Round 5: 25 of 25.** These are the verifier's four survivors, now caught, and one
  or more mutants per round-5 fix.
- **Rounds 1–4:** 62 of 68. The six survivors are second layers:
  - the weathercock airspeed gate and the stall-protection rate limit ("ZOOM
    filtered speed", "ZOOM protect snaps", round 1);
  - the heave weight low-pass and benefit gate ("HEAVE raw weights", "HEAVE no
    benefit gate", rounds 1–2);
  - the perch hold ("PERCH no hold", round 3).

    Removing any one of these five changes no measured result.
  - **New in round 5, the tailwind brake's ground-speed term** ("PERCH still-air
    brake", round 3; caught in round 4).
    - The mutant plans the perch brake on the airspeed, as round 2 did.
    - Round 5 no longer locks the capture out after a slow brush of the branch
      (the crosswind fix), so the slightly fast arrivals this causes still perch.
    - The brake re-plans every tick, and in the last half span both forms meet the
      same 0.5 g cap. A sweep of fast, short tailwind approaches (2.5–6 spans,
      1.3–1.55 V_cap, 2.1 m/s) arrives within 0.01 V_cap of the real brake.
    - P11 measures the difference as at most one clean approach: eagle 8 → 7 of 9,
      inside the ≥ 7 bound.
    - The 27-approach glide sweep drops one approach in three tailwind cells:
      sparrow 2.1 m/s (0.81 → 0.78), eagle 1.5 and 2.1 m/s (0.96 → 0.93). Every other
      cell is unchanged (`verify/r5_builder/perchwind_glide_mutant_stillair_brake.log`).
    - A bound that caught it would sit on the real code's own count, so it is left
      documented, not pinned.

**Where a verifier was partly off, or a probe does not apply**
- **"A one-frame 1 m view jump at spawn"** (experience verifier).
  - The offset was in the XR camera *node* between two server updates. OpenXR renders
    from the server's own view transform with the current `world_scale`, and that
    frame came before the session was visible (the log's "session visible" follows it).
  - The node is now kept consistent anyway (§2).
- **`test_r5x_glide_into_the_ground`** (their earlier probe): the eagle's neutral glide
  from 6 spans + 2 m is not at rest within 15 s (it is at 18.4 s).
  - Their fix criterion ("comes to rest within about 20 s") is met.
  - The 15 s check conflicts with the spec's G15 skim (PB-15 ≥ 40 spans): the eagle
    needs 7.5 s to descend and 4.4 s to skim 40 spans, before any friction or run-out.
  - Every other assertion of their 18 probe tests passes (§2 round 5 table).
- **`test_r5_hitches_do_not_make_slow_arms_flap` and `test_r5_engine_style_hitches`**
  (engineering verifier): both feed a synthetic scripted source.
  - The first advances its pose clock after the tick, so the long tick's arm motion
    lands in the next normal-length tick.
  - The second reports every repeated pose as a fresh sample one tick apart.
  - A pose source with no frame timing cannot tell that from a fast hand. In the game
    only XR poses hitch, and the XR source is now frame-timed.
  - The same scenarios through the real XR source code path (WI-34, an emulated engine
    clock) and through `tick(dt)` with the pose at the tick's end (PB-31) give 0
    flaps.
- **`test_r5_viewturn_variable_dt`** asserts zero overshoot with the tick length
  changing every tick. Their fix offered "qualify the guarantee, or add a variable-dt
  case with the measured bound": both are done (VT-5).
  - Their mode 0 (72/90/120 Hz mixed) measures 0.196°, inside VT-5's 0.25° bound.
  - Their mode 1 also mixes in random 4–100 ms ticks and runs past by 4.66°.
  - The game never feeds the follower such ticks. PlayerBird ticks only from
    `_physics_process` at Godot's fixed step (72 Hz, switched to the headset's rate
    by VRManager), and a hitch runs more fixed steps, not longer ones.
  - `view_turn.gd` and FLIGHT_SPEC R5-11 state both numbers.
- **The round-4 corner probe** (r4eng) still fails its "never through the wall" check:
  the birds drop below the walls' lower edge and fly on under them (§6, round 4).

**The verifiers' probes on the final code** (redirected copies,
`verify/r5_builder/probe_*.log`):

| Probe | Result | Notes |
|---|---|---|
| `r5x_experience` | 17 / 18 | Ground landing, resume, stall, dihedral, updraft, growth, ledge, perch-turn, relaxed postures and hover all pass; `glide_into_the_ground` fails only the eagle's 15 s check (above). |
| `r5eng_probe` | 6 / 9 | Random play with growth, respawns, recenters and hitches: basis, scale, ancestors, camera and NaN all clean. Recenter mid-payout: 0 safety-net ticks. The two hitch probes and the zero-overshoot ViewTurn probe fail for the reasons above. |
| `r4x_experience` | 20 / 20 | |
| `r4eng_probe` | 12 / 13 | Fails only the corner scenario (round 4). |
| `r3_experience` | 7 / 7 | The breeze perch now passes (was 6 / 7). |
