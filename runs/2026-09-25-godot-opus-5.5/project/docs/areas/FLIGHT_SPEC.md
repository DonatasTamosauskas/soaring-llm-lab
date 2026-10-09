# Flight model & controls: authoritative spec (FLIGHT_SPEC)

Status: **authoritative** for the flight area (`scripts/flight/`, `scenes/player/`,
`tests/unit/flight/`). It synthesises the three panel designs in `docs/design/`:
`flight_aero.md` (the aerodynamicist), `flight_vr.md` (VR ergonomics) and
`flight_game.md` (game feel and test engineering). Where this spec and a panel doc
disagree, **this spec wins**. The panel docs stay as rationale and background.

Every number a test asserts here was reproduced by the chief designer's prototype of
**exactly the equations in §7 and Appendix A**. It is a Python point-mass model at
72 Hz, with substeps h ≤ 1/120 s, run across the species ladder. Appendix B lists
its outputs as golden values. The GDScript port must reproduce them within the
stated tolerances; that check also proves the port is faithful. Rows marked **†**
are scene-level behaviour (collision, perching, rig, devices) that the prototype
could not exercise. Their thresholds are design targets to confirm in the port.

Reading order: §0 for the decisions, §2 for the data flow, §5–§7 for the input and
physics, §10 for the player rig, §14 for the test plan.

**Port notes (2026-09-26).** Where the GDScript port had to depart from this spec
(a number that could not be met as written, a test that was untestable or wrong, a
controller that did not survive the human limits), the change is made in place
where it matters most and every departure is listed with its reason in **§19**.
The evidence is in `docs/areas/FLIGHT.md`.

---

## 0. Decisions at a glance (and how each panel conflict was resolved)

| # | Decision | Source → resolution |
|---|---|---|
| D1 | **Physics base: point mass + lagged attitude** (θ pitch, φ bank, a small yaw-offset channel), integrated with Heun (RK2) at h ≤ 1/120 s. It costs about 20–40 µs per step, so it can be shared with NPCs. | Game panel's base. The aero blade-element model stays the *physical reference*. It is not the runtime, because of cost (3–4 substeps × 2–8 wing evaluations), 30 state variables and porting risk. It also turns raw stroke velocity into force, so shaking produces lift. |
| D2 | **The body follows its flight path (weathercock feed-forward):** `θ += w_a·Δγ` every substep, so α tracks α_cmd with lag τ_α at any speed. | Grafted from aero (Ω_ff). The game model's θ-lag collapsed α at high speed. A V_max pull-out reached only 1.4–1.8 g and lost 240–320 spans in the prototype before this fix. |
| D3 | **No heave filter.** Forces and attitude both use the true airflow. | Aero's L8 heave decoupling was prototyped and **rejected**. Any causal ripple/mean split biases α for about 0.35 s after each change in flap effort, and the bird zoomed 1–3 m after every flap burst. Wingbeat body-pitch ripple is visual only: the player's camera never pitches, and NPC visuals smooth it. |
| D4 | **Flap force direction = the wing's normal** (from WingInput, §5.8), in the **level body frame**: horizon-referenced in pitch, bank-referenced in roll. Flat wrists push **straight up** (0°). Leading edge down tilts it **forward**, up to 35°. Leading edge up tilts it **back**, up to 20° (flare/brake). | VR's normal geometry plus aero's L7 (stroke plane referenced to the horizon) plus the game panel's world/bank frame. All three agreed; the numbers come from VR. |
| D5 | **Flap force magnitude is normalised to a reference stroke.** Mean force over the reference stroke is K_F(x) body weights at speed and K_H(x) at hover, blended by a smoothstep of horizontal airspeed. It is **power-capped** (F·v_air ≤ P_spec per unit weight) and **endurance-capped**: the stroke-averaged effort may exceed the reference by at most 15%, so frantic flapping cannot win and big birds cannot hover. Upstroke gain is +0.30 for small birds and −0.08 for big ones. Smoothing is τ_f(x). | Game panel's structure, re-parameterised as physical ratios: hover capability, forward flap force and muscle power are separate, tunable anchors. P_spec is anchored on `SizeRules.climb` (§7.7). The endurance cap comes from aero's L13 intent; the prototype showed that the F·v cap alone lets a frantic pigeon hover-climb at +3.4 m/s, because hovering costs no F·v power. |
| D6 | **Flap effort comes from VR's credited-stroke detector**: velocity along the wing normal, arc bank, amplitude credit and effort normalisation. It is **size-aware**, grafted from the game panel: small birds reward quick short strokes, big birds slow deep ones. | VR's detector gives 0% response to shaking, tremor and frantic small strokes (§6.5 of the VR doc). The aero raw-stroke model and the game model's simpler raise gate are replaced by it. |
| D7 | **One gesture, one meaning. There is no flap-hold.** Symmetric wrist twist is *both* the AoA command and the flap tilt, because it is the same physical wrist. Wrists forward means "go forward/faster"; wrists back means "slow/up/brake". | The game panel's sample-and-hold is **rejected**. With the lift-linear nose-down map (D8), live coupling gives near-level cruise when flapping forward at 40% effort for every size (Appendix B, FM-12). A held pitch instead made forward flapping climb rather than go forward. |
| D8 | **The pitch command is split at neutral.** Nose-up is linear in α up to α_s − 1°; this is where the balloon comes from. Nose-down is **linear in lift**, CL = CL_n(1 + p), so full down means zero lift and a dive. | Game panel's map with a new down side. Game's map put quarter-down at 1.55·V_c and half-down at zero lift, which was too twitchy. The new map gives +15% speed at quarter-down and +41% at half-down. |
| D9 | **Balloon emerges; the phugoid is damped** by speed-rate feedback in load-factor units: `+k·clamp(u̇/g)·min(1,(V_c/V)²)`. | Game's u̇ damper, scaled by aero's (V_c/V)² fix. Unscaled, it cancelled pull-outs. |
| D10 | **Stall is protected by default.** A reflex clamps the *actual* α to α_s − 0.5°. A deliberate stall needs pitch ≥ 0.9 held for 0.35 s. Buffet warning starts at α_s − 6° (about pitch 0.7); forced recovery happens at 1.5 s. In the `sim` preset, a static stall comes at pitch ≈ 0.82, and with no damper a sharp step from about 0.6 can stall in the balloon. | Game's design plus a correction: clamping only the *command* still stalled at pitch 0.85 (actual α overshoots while the path curves down). VR's R1 (buffet at about 0.6–0.7, stall in the last fifth of the range) is met. |
| D11 | **Roll is a bank-angle command** (auto-level) from `roll_input` = aileron twist + arm tilt (VR shaping). Bank is first-order, τ_φ(x), rate-limited to p_max(x)·clamp(V/V_c, 0.4, 1.25). φ_max comes from `SizeRules.turn_rate`. | All three panels: angle command, because the camera never rolls. Roll authority scales with airspeed (from aero). |
| D12 | **Coordinated aileron plus rudder by construction:** lift tilts with bank. An explicit yaw-offset channel carries adverse yaw, which the **auto-rudder** (`k_rud = 1`) cancels. With `k_rud = 0`, tests show adverse yaw exists. | Aero's T-ADVERSE idea, as one scalar state. It makes "coordinated rudder" an actual, testable mechanism, not a tautology. |
| D13 | **Body steer:** a physical torso turn becomes a *bank demand* (a coordinated turn), and the rig does **not** rotate for it. Head look never steers. | Game panel's approach. Aero's and VR's skid turn (side force from 30–90° of sideslip) is **rejected**: it violates requirement 3 (coordinated) and makes the wing lose lift. VR's rig invariant (bird heading = rig yaw + torso yaw) is kept. |
| D14 | **Rig:** `PlayerBird.global_position` is the body, which is the eye. `XROrigin3D.position = −head_track·ws (+ heave offset)` is set in the same physics tick, so head translation has zero latency. PlayerBird yaws only. Nothing ever scales. | Hybrid. The game panel wanted body = PlayerBird origin, for systems that read `global_position`. Aero and VR wanted zero-latency head motion. |
| D15 | **Controller conventions are measured, not assumed:** the grip pose, with forearm and chord axes calibrated in the grip frame, and wrist pitch from swing-twist decomposition. | VR's simulator probe. Aero's default chord axis `(0,1,0)` is **rejected**: under the measured convention it points up-back. |
| D16 | **Body frame:** VR's torso-yaw estimator (hand line, neck leash, jump gate) and neck-pivot shoulders. | VR. |
| D17 | **Fatigue:** full extension spans −60°…+60° arm elevation with soft elbows. **Soar lock:** both grips hold the wings open. Level flapping flight costs 30–40% of reference effort, and thermals climb with zero effort. | VR's design; the effort numbers are measured (FM-17). |
| D18 | **Perching** captures automatically below 0.8·V_min (×1.4 with grip) within max(0.6 span, 2 r_body). A perch assist handles line-up and landing configuration. Launch is a credited downstroke, or a tuck drop. | Game's capture rules with a new speed: game's 0.6·V_min needs a hover-brake or zoom inside 4 spans. AoA alone decelerates only about 0.25 g (prototype). |
| D19 | **Collisions:** a continuous sphere sweep, then slide, stun (0.6–1.4 s) or land. There is no death, and wingtips only brush. | Game panel §8, kept. |
| D20 | **Comfort caps are in the physics** (player only): yaw rate ≤ 240°/s and yaw acceleration ≤ 720°/s², enforced as bank limits. The camera therefore always shows the true heading. In the prototype they never bind in normal flight (sparrow full-input peak: 203°/s, 363°/s²). | Aero put the limiter on the rig, which lets the rig lag the bird. VR asked for a physics-consistent version, which this is. |
| D21 | **Growth:** `FlightParams.derive(mass)` runs every tick the mass changes, is continuous, and keeps state. `world_scale` is owned by VR (default `span/(arm_span + 0.20)`); flight is invariant to it. | All panels. |

The user requirements are mapped to tests in §14.2.

---

## 1. Conventions

- SI units. Godot axes: +Y up, **−Z forward**, +X right, right-handed.
- **Yaw / heading** follows the Godot convention: CCW seen from above is positive,
  and forward is `(−sin ψ, 0, −cos ψ)`.
- **Bank φ** is positive with the **right wing down**, which means a right turn.
  `roll_input > 0` banks right.
- **Pitch θ** is positive nose-up. **γ** is the flight-path angle of the air velocity.
  **α** = θ − γ.
- **Wrist twist / `pitch_input`** is positive with the **leading edge up** (more AoA:
  slower, balloon).
- **Dihedral** is positive with the hand above the shoulder. **Sweep** is positive
  with the hand forward of the shoulder line.
- Wing index: 0 or `_l` is left, 1 or `_r` is right. Side sign σ = −1 left, +1 right.
- **Spaces.** *Tracking space T*: XROrigin3D-local, with the scale removed, in **real
  metres**, gravity-aligned. *Body frame B*: yaw-only frame at the estimated shoulder
  centre, with forward F, up U = +Y and right Rt = F × U. *Level body frame*: the
  model's frame, with the bird's heading χ, horizontal, x right, y up, z back (Godot
  local axes of a yaw-only basis). *World*.
- "Span" means the bird's wingspan in world metres; `b = SizeRules.wingspan_for_mass(m)`.
  "x" is the size scalar of §7.1.
- `smoothstep(a, b, v)` always means `t = clamp((v−a)/(b−a), 0, 1); t²(3−2t)`, also
  when a > b. Implement it as a local helper rather than using the built-in, whose edge
  handling differs.
- Filters use `k = 1 − exp(−h/τ)`, never `h/τ`. Test input schedules are indexed by
  tick, never by an accumulated float time.

---

## 2. Architecture and data flow

```
PoseSource ─PoseFrame─▶ WingInput ─WingState─▶ PlayerBird ─(WingState + FlightEnv)─▶ FlightModel
 (XR / Scripted /        (calibrated,           (state machine, body steer,           (pure RefCounted,
  Replay / Desktop /      scale-free,            perch/collision, rig, comfort,         no scene deps)
  Bot / Hybrid)           tracking space)        telemetry, Events)                       │
                                                        ▲                                  │ state, telemetry,
NPC autopilot / tests ───WingState.set_commands()───────┴──────────────────────────────────┘ events
```

Files (flight owns all of them, per ARCHITECTURE §1):

| File | class_name | Role |
|---|---|---|
| `scripts/flight/pose_frame.gd` | `PoseFrame` | One tick of head and hand poses (§3.1). |
| `scripts/flight/pose_source.gd` | `PoseSource` | Base class, plus `XRPoseSource`, `ScriptedPoseSource`, `ReplayPoseSource`, `DesktopPoseSource`, `BotPoseSource`, `HybridPoseSource` in `scripts/flight/pose_sources/`. |
| `scripts/flight/human_pose_model.gd` | `HumanPoseModel` | Kinematic human that synthesises anatomically consistent poses (tests, desktop, bot). |
| `scripts/flight/pose_recorder.gd` | `PoseRecorder` | JSON-lines pose recording and replay. |
| `scripts/flight/wing_calibration.gd` | `WingCalibration` | Resource. Fields in §5.11 (a contract change). |
| `scripts/flight/flap_detector.gd` | `FlapDetector` | Per-wing credited stroke detection (§6). |
| `scripts/flight/wing_input.gd` | `WingInput` | Poses → WingState (§5, §6). |
| `scripts/flight/wing_state.gd` | `WingState` | The command and measurement contract (§4). |
| `scripts/flight/flight_tuning.gd` + `flight_tuning_default.tres` | `FlightTuning` | The single tuning resource. Every constant in §7–§9 lives here, never in code. |
| `scripts/flight/flight_params.gd` | `FlightParams` | Constants derived for one mass (§7.1). |
| `scripts/flight/flight_env.gd` | `FlightEnv` | Per-tick environment input (§7.10). |
| `scripts/flight/flight_model.gd` | `FlightModel` | The physics (§7, Appendix A). |
| `scripts/flight/flight_autopilot.gd` | `FlightAutopilot` | TECS and L1 autopilot that outputs WingState commands (bot, NPC option; §14.4). |
| `scripts/flight/player_bird.gd` + `scenes/player/player.tscn` | `PlayerBird` | Rig, state machine, collisions, perching, telemetry, Events (§10). |
| `scripts/flight/heave_smoother.gd` | `HeaveSmoother` | Camera vertical smoothing (§11.3). |
| `scripts/flight/flight_plot.gd` | `FlightPlot` | Headless PNG plots (§14.6). |

Per physics tick, `PlayerBird._physics_process(dt)` (pausable) calls `tick(dt)`.
Tests call `tick(dt)` directly with `auto_process = false`.

1. `pose_source.sample(frame, dt)`. If the source is synthetic, write the scaled poses
   into the XRCamera3D and XRController3D nodes, so wings and UI rays look real.
2. `ws = wing_input.update(frame, dt)`. If controls are disabled, `ws` is replaced by
   neutral glide (the torso yaw is kept).
3. Body steer: fold the torso heading error into `ws.roll` (§10.4).
4. Build `env` (FlightEnv): wind at the body, wind at both wingtips, ground distance,
   perch-assist terms.
5. Mode logic (§10.2), then `model.displace(Δhead·ws)` and `model.step(ws, env, dt)`
   while FLYING or STUNNED.
6. Continuous sweep of the body sphere and the head displacement (§12). On a hit,
   `model.apply_contact(...)`.
7. Rig: yaw update, origin offset, heave offset (§10.3, §11.3).
8. Events and telemetry cache.

**NPC reuse.** `FlightModel` has no scene dependencies. An NPC may own one and drive it
with `WingState.set_commands()` from a `FlightAutopilot`. AI keeps `NpcFlight` (its
kinematic model) for the bulk of the population. `FlightModel.envelope(mass)` publishes
the measured envelope (§7.12), so both models can be held to the same numbers
(PERF-02, §16 flag A1).

---

## 3. Poses and controller conventions

### 3.1 PoseFrame and PoseSource

```gdscript
class_name PoseFrame extends RefCounted
## One tick of the player's body in TRACKING space, REAL metres (never world_scale'd).
var t := 0.0                               # seconds since the source started
var head := Transform3D.IDENTITY           # eye-centre pose
var left := Transform3D.IDENTITY           # GRIP pose (see 3.2)
var right := Transform3D.IDENTITY
var head_valid := false
var left_valid := false
var right_valid := false
var grip := Vector2.ZERO                   # analog 0..1 (x = left, y = right)
var trigger := Vector2.ZERO
var buttons := 0                           # BTN_* bitmask
const BTN_MENU := 1; const BTN_AX := 2; const BTN_BY := 4; const BTN_STICK_L := 8; const BTN_STICK_R := 16

class_name PoseSource extends RefCounted
func sample(out: PoseFrame, dt: float) -> void: pass   # fill in place; never allocate per tick
func drives_nodes() -> bool: return false              # true for synthetic sources
func reset() -> void: pass
```

| Source | Use | Notes |
|---|---|---|
| `XRPoseSource` | headset, simulator | Reads `XRCamera3D.transform` and `LeftHand`/`RightHand.transform` (XRController3D, `pose = &"grip"`), local to XROrigin3D. Divides each **origin** by `XROrigin3D.world_scale`; bases are unaffected (measured by the VR panel). Validity comes from `get_has_tracking_data()` and a pose confidence that is not NONE. Node transforms include the reference frame, so recenter is handled. |
| `ScriptedPoseSource` | tests, simulator runs | A `HumanPoseModel` driven by a gesture timeline (tick-indexed channels: `spread`, `twist_l/r`, `dihedral_l/r`, `sweep`, `stroke(amp, hz, duty, side)`, `torso_yaw`, `head_yaw/pitch/roll`, `bob`, `noise`). Deterministic from a seed. |
| `ReplayPoseSource` | regression from real sessions | `PoseRecorder` JSON-lines: `{"t","h":[px,py,pz,qx,qy,qz,qw],"l":[…],"r":[…],"v":bits,"g":[gl,gr],"tr":[tl,tr],"b":int}`, interpolated to the tick. |
| `DesktopPoseSource` | dev without a headset | Keyboard and mouse drive the `HumanPoseModel` (§13). **It never writes WingState.** |
| `BotPoseSource` | bot pilot | `FlightAutopilot` → commands → `HumanPoseModel` joint targets under human limits (§14.4). |
| `HybridPoseSource` | simulator scripted runs | Head from XR, hands from a scripted or bot source. The simulator's controllers are fixed, so this is the only way to fly there. |

Sanity checks per tick: every basis finite with `det > 0.5`, origins finite with
`|p| < 20 m`, and a hand jump under 0.5 m per tick. A pose that fails counts as
invalid for that tick.

### 3.2 Godot OpenXR controller axes (measured; tested by SIM-01)

Measured in the Meta XR Simulator (runtime 207, "Meta Quest Pro", Godot 4.7.2), with
the simulator's fixed "pointing forward" controllers:

| Pose | Basis in tracking space | Meaning |
|---|---|---|
| `aim` (the project's `default` action is bound to aim) | X≈(1,0,±0.09), Y=(0,1,0), Z≈(∓0.09,0,1) | −Z is the pointing ray. |
| `grip` | X=(1,0,0), Y=(0,0.5,0.866), Z=(0,−0.866,0.5), i.e. **grip = aim · Rx(+60°)** | **−Z_grip** runs through the fist tube (little finger to thumb). **+X_grip** is the palm normal: out of the left palm, into the right palm (world-right for both hands in a handshake). |
| `palm` (grip_surface) | inactive in the simulator | Do not use it. |

For the neutral **"airplane arms, palms down"** pose, both hands have, in the grip frame:

- outward forearm axis `a_local = (0, −0.866, −0.5)`, which is the aim ray
- chord, i.e. leading-edge direction, `c_local = (0, 0.5, −0.866)`, which is −Z_grip
  projected perpendicular to `a_local`
- wing up-normal `+X_grip` (right hand) and `−X_grip` (left hand)

`Basis.IDENTITY` is **not** palms-down. No WingInput math hard-codes these axes. It uses
the calibrated `a_local`, `c_local` and neutral basis (§5.10), falling back to these
defaults. `LeftHand`/`RightHand` use `pose = &"grip"`. The UI laser uses separate
`LeftAim`/`RightAim` XRController3D nodes with `pose = &"aim"`; this is a contract change
(§15).

---

## 4. WingState (exact fields)

`WingState` is the only input FlightModel ever sees. It is reused in place: allocate
once and use `copy_from()`. Commands are what the model consumes; NPC autopilots write
only commands. Measurements exist for visuals, haptics, UI lessons and tests. **The
model must never re-derive roll or pitch from the per-wing measurements**, which would
double-count them.

```gdscript
class_name WingState extends RefCounted
## ---- commands (FlightModel consumes these; NPC autopilots write ONLY these) ----
var pitch := 0.0                  # -1..1 symmetric AoA command (+ = leading edges up: slower, balloon)
var roll := 0.0                   # -1..1 bank command (+ = right wing down); PlayerBird adds body steer
var ext_l := 1.0                  # 0 tucked .. 1 spread, per wing (area, lift, asymmetric roll)
var ext_r := 1.0
var flap_l := 0.0                 # 0..1.3 credited downstroke effort this tick (FlapDetector)
var flap_r := 0.0
var up_l := 0.0                   # 0..1 gated upstroke effort this tick
var up_r := 0.0
var flap_dir_l := Vector3.UP      # unit, LEVEL body frame (x right, y up, z back): flap force direction
var flap_dir_r := Vector3.UP
var body_yaw := 0.0               # rad, torso yaw in tracking space (Godot yaw). NPC: 0
var tracking := 1.0               # 0..1; 0 = both hands lost (WingInput already fed neutral)
## ---- measurements (visuals, haptics, UI, tests, telemetry) ----
var twist_l := 0.0                # rad, filtered wrist twist from calibrated neutral (+ = LE up)
var twist_r := 0.0
var dihedral_l := 0.0             # rad, arm elevation (+ = tip up); cycle-mean while stroking
var dihedral_r := 0.0
var sweep_l := 0.0                # rad (+ = forward)
var sweep_r := 0.0
var stroke_phase_l := 0.0         # 0..1 (0 = top of stroke), for wing visuals and audio
var stroke_phase_r := 0.0
var stroke_period := 1.0          # s, last measured cycle (0.3..1.5), for HeaveSmoother
var body_yaw_rate := 0.0          # rad/s
var grip_l := 0.0                 # analog 0..1
var grip_r := 0.0
var tucked := false               # both extensions < 0.25 for > 0.1 s
var soar_lock := false
var calibrated := false
var flapping := 0.0               # 0..1 activity: LP(0.3 s) of max(flap_l, flap_r)
## ---- one-tick event flags ----
var onset_l := false              # a credited downstroke started (haptic "air bite", flap event)
var onset_r := false
var onset_strength := 0.0         # credit (0..1) of the latest onset
var detent_l := false             # twist crossed the neutral dead-zone edge
var detent_r := false
var range_l := false              # twist crossed full scale
var range_r := false
var soar_lock_changed := false
var t := 0.0                      # source time, s

func mean_extension() -> float: return 0.5 * (ext_l + ext_r)
func set_neutral() -> void        # spread, level, no flap, flap_dir = UP; keeps body_yaw
func copy_from(o: WingState) -> void
func to_dict() -> Dictionary; static func from_dict(d: Dictionary) -> WingState
## NPC/bot helper: symmetric wings, reference-stroke flapping at `effort` (0..1.3),
## flap tilt from the same wrist rule as a human (tilt = f(pitch), §5.8) unless overridden.
func set_commands(pitch: float, roll: float, spread: float, effort: float, stroke_time: float,
		hz := 1.0, one_wing := 0, tilt_override_deg := NAN) -> void
```

---

## 5. WingInput: poses → WingState

All geometry is in tracking space, in real metres. WingInput never sees `world_scale`.
The whole update is deterministic. `dt` is clamped to ≤ 1/30 s.

### 5.1 Head forward (robust at any head pitch)
```
zf = −head.basis.z;  y = head.basis.y
f_head = horiz(zf) − zf.y · horiz(y)      # continuous through straight-up and straight-down gazes
φ_head = atan2(−f_head.x, −f_head.z)
```

### 5.2 Torso-yaw estimator (`body_yaw`)
```
w = right.origin − left.origin;  w_h = horiz(w);  f_w = normalize(UP × w_h);  φ_w = yaw(f_w)
c_span = smoothstep(0.35, 0.75, |w_h| / arm_span)                 # hands far apart ⇒ trustworthy
c_calm = 1 − 0.6·clamp(max(|ω_L|, |ω_R|)/4.0, 0, 1)                 # vigorous strokes wobble the line (ω from last tick)
jump = |wrap(φ_w − φ_est)|
c_gate = 1 if jump ≤ 75° else (1 if |wrap(φ_w − φ_head)| < 40° held for 0.3 s else 0)
c = c_span · c_calm · c_gate
φ_est += wrap(φ_w − φ_est)·(1 − exp(−dt·c/0.10))                     # follow the hands, τ = 0.1 s
e = wrap(φ_head − φ_est)                                             # neck leash: never > 70° from the gaze for long
if |e| > 70°: φ_est += sign(e)(|e| − 70°)(1 − exp(−dt/(0.5 if c > 0.5 else 2.0)))
φ_est += e·(1 − c)·(1 − exp(−dt/4.0))                                # no hand info: drift to the gaze, τ = 4 s
φ_est = rate_limit(φ_est, 400°/s);  body_yaw = φ_est;  B = Basis(UP, φ_est)
```
With arms spread, the head is ignored. Crossed arms are rejected by the jump gate.
Turning around while tucked is recovered through the leash and the gate. Asymmetric
sweep rotates the hand line, which acts as a gentle yaw input.

### 5.3 Shoulders (neck pivot)
```
neck   = head.origin + head.basis·(0, −0.08, +0.09)                  # below and behind the eyes
centre = neck + (0, −(shoulder_drop − 0.08), 0) − F·0.02
S_L = centre − Rt·shoulder_width/2;  S_R = centre + Rt·shoulder_width/2;  One-Euro(2.0 Hz, β 0.5)
L_arm = (arm_span − shoulder_width)/2
```

### 5.4 Per-wing geometry (σ = −1 left, +1 right)
```
a = p_i − S_i;  x_out = σ·a·Rt;  y = a·U;  z = a·F
r_c = sqrt(max(x_out,0)² + y²)/L_arm;  δ_i = atan2(y, max(x_out, 0.05));  s_i = atan2(z, max(x_out, 0.05))
```

### 5.5 Extension (0 tucked … 1 spread)
```
e_reach = smoothstep(0.30, R_HI, r_c)          # R_HI = calibrated glide reach (default 0.62)
e_low   = smoothstep(fold_elev − 20°, fold_elev, δ_i)   # fold_elev default −62°: arms hanging at the sides fold
e_back  = 1 − smoothstep(−35°, −70°, s_i)       # hands behind the back = folded (stoop)
ext_i   = OneEuro(e_reach·e_low·e_back, 1.5 Hz, β 0.2)
```
**Novice floor.** Until `has_spread` (both ext > 0.8 for 0.3 s since spawn or
calibration), the output is `max(ext_i, 0.85)`. **Tuck** means both < 0.25 for > 0.1 s;
it releases above 0.35. **Soar lock** (both grips > 0.6 while ext ≥ 0.5 at the press)
holds `ext = max(live, value at press)`. Twist and dihedral stay live. Release blends
back over 0.4 s.

### 5.6 Dihedral bank
`δ_a = (δ_L − δ_R)/2`: left hand higher means a right bank. It is valid only when both
r_c > 0.3, and 0 otherwise. While a wing strokes (|ω_i| > 1.0 rad/s), use that wing's
**mean δ over the last stroke cycle**: a 1.5 s ring buffer with a window of the
measured period, clamped to 0.3–1.5 s. Otherwise use `OneEuro(δ_i, 1.0 Hz, β 0.8)`.
This cancels the ±45° swing of a one-wing flap exactly.

### 5.7 Wrist twist: swing-twist about the calibrated forearm axis
```
R = B⁻¹·R_ctrl_i;  Q = N_iᵀ·R;  q = Quaternion(Q)                 # rotation since the calibrated neutral
τ = wrap(2·atan2(q.xyz·a_local_i, q.w));  conf = sqrt(q.w² + (q.xyz·a_local_i)²)   # conf < 0.25: hold last τ
twist_i = OneEuro(k_i·τ, 1.2 Hz, β 1.0)                             # k_i = side sign so + = LE up on both hands
```
Arm raise, sweep, elbow bend and arms at rest all read as **0** twist. A naive grip
axis would leak 21° of pitch into a 40° arm raise. The player's instruction is: "roll
your wrists back (thumbs up and out) to lift the leading edge; roll them forward to
drop it".

### 5.8 Flap direction (the wing normal), per wing
```
o_i  = normalize(a);  c0_i = normalize(F − (F·o_i)o_i);  n0_i = σ·normalize(o_i × c0_i)   # up-normal at zero incidence
u_i  = shape(twist_i; 5°, 40° up, 30° down, expo 1.4)                                      # §5.9
θ_i  = u_i·(20° if u_i > 0 else 35°)
normal_i = n0_i·cos θ_i − c0_i·sin θ_i                           # LE down (u<0) tilts forward, LE up tilts back
flap_dir_i = B⁻¹·normal_i                                         # into the level body frame
```
A flat wing at shoulder level gives exactly `(0,1,0)`. LE down 20° tilts it 17° forward,
30° gives 35°, and LE up 40° gives 20° back. Raising the arm tilts the normal inward;
for symmetric strokes the two sides cancel. **Fix round 4:** the model applies only the
normal's lift and thrust parts; its component across the body is not a force (§7.7,
§19 R4-5): a one-wing flap turns the bird through the roll kick and the paddle yaw only.

### 5.9 Shaping and aggregates
```
shape(x, dz, full_pos, full_neg, expo): a = |x| − dz; a ≤ 0 → 0; else sign(x)·clamp(a/(full − dz), 0, 1)^expo
```
| Signal | dz | full + | full − | expo |
|---|---|---|---|---|
| per-wing twist → `u_i` | 5° | 40° (LE up) | 30° (LE down) | 1.4 |
| symmetric twist `t_s = (t_L + t_R)/2` → pitch | 5° | 40° | 30° | 1.4 |
| antisymmetric twist `t_a = (t_L − t_R)/2` → aileron | 4° | 25° | 25° | 1.3 |
| dihedral bank `δ_a` | 4° | 30° | 30° | 1.2 |
| mean sweep | 12° | 35° | 35° | 1.0 |

```
pitch = clamp(shape(t_s) + sweep_gain·shape(mean sweep)·min(ext_L, ext_R), −1, 1)   # sweep_gain 0.30 (setting sweep_pitch)
roll  = clamp(shape(δ_a) + shape(t_a), −1, 1)
if Settings.invert_pitch: pitch = −pitch
```
Split into symmetric and antisymmetric parts **before** shaping. Otherwise, because
the up and down ranges differ, equal opposite twists would leak pitch.

Reference values: both wrists +20° gives pitch 0.31, both −20° gives −0.49, and
L +20°/R −20° gives roll 0.70 with pitch 0. A 15° arm tilt gives roll 0.36.

Assist presets scale every dead-zone (novice ×1.4, normal ×1.0, sim ×0.8).
`wrist_sensitivity` divides the twist full-scales.

### 5.10 Calibration (automatic, with manual recapture)
The **neutral capture** triggers when the following hold for 1.2 s: both hands valid,
`|w| > 0.9 m`, `|δ_L|, |δ_R| < 25°`, hand speed < 0.08 m/s, angular speed < 25°/s and
`|y_L − y_R| < 0.12 m`. It captures:
```
arm_span = |r − l| (clamp 1.0..2.2);  shoulder_drop = head.y − mean(hand.y) − L_arm·sin 5° (clamp 0.15..0.35)
shoulder_width = 0.23·arm_span;  N_i = B⁻¹·R_ctrl_i;  a_local_i = R_ctrl_iᵀ·normalize(p_i − S_i)
c_local_i = R_ctrl_iᵀ·F projected ⟂ a_local_i;  reject (keep defaults) if a_local is > 45° from (0, −0.866, −0.5)
```
- **Stroke capture** (the three big flaps in the onboarding):
  `ω_full = clamp(0.85·median(peak ω), 3.0, 6.0)` and
  `A_FULL = clamp(0.5·median(up_arc), 25°, 40°)`.
- **Glide-pose capture:** `R_HI = clamp(0.95·r_c, 0.50, 0.75)` and
  `fold_elev = min(−62°, δ_mean − 12°)`.
- **Continuous refinement:** the span grows, never shrinks. Neutral-twist auto-trim
  applies while gliding with ext > 0.8, |roll| < 0.2 and |twist| < 12°, drifting toward
  the live twist with τ = 60 s, bounded to ±10° (setting `auto_trim`).
- **Seated** (flag, or head below 1.30 m for 5 s at calibration): ω_full ×0.75, credit
  arc ×0.75, R_HI 0.58, fold limits −55°/−75°.
- **Recenter:** `Δhead = 0` for that tick, and the torso estimator is re-seeded from
  the hand line (or the head if tucked). There is no neutral recapture on recenter.

### 5.11 WingCalibration (flight-owned Resource; persisted as `Settings["wing_calibration"]`)
```gdscript
@export var arm_span := 1.50            # grip-to-grip at full spread (was 1.6 "fingertip")
@export var shoulder_width := 0.345
@export var shoulder_drop := 0.24
@export var neutral_left := Basis()             # controller basis in B at neutral. Uncalibrated: WingInput uses
@export var neutral_right := Basis()            #   the 3.2 airplane-pose grip basis (IDENTITY is NOT palms-down)
@export var forearm_axis_left := Vector3(0, -0.866, -0.5)
@export var forearm_axis_right := Vector3(0, -0.866, -0.5)
@export var chord_axis_left := Vector3(0, 0.5, -0.866)
@export var chord_axis_right := Vector3(0, 0.5, -0.866)
@export var glide_reach := 0.62         # R_HI
@export var fold_elevation := -1.082    # rad (-62 deg)
@export var stroke_full_rate := 4.5     # omega_full, rad/s
@export var stroke_full_arc := 0.611    # A_FULL, rad (35 deg)
@export var seated := false
@export var calibrated := false
func arm_length() -> float: return (arm_span - shoulder_width) * 0.5
func to_dict() -> Dictionary; func from_dict(d: Dictionary) -> void
```
The old fields `neutral_roll_*` and `neutral_pitch_*` are removed. A single roll angle
cannot express a full neutral orientation, and nothing outside flight reads them
(checked 2026-09-25).

### 5.12 Tracking loss (per hand)
- **< 0.25 s:** hold the last pose, with velocity 0, so no flap.
- **0.25–0.85 s:** blend that wing's extension, dihedral and twist toward a mirror of
  the other wing.
- **After that:** stay mirrored.
- **Both hands lost for > 0.25 s:** blend to neutral glide over 0.8 s and set
  `tracking = 0`. The HUD shows "controllers not tracked".
- **Head lost:** freeze the body frame. After 1 s, request pause.
  `VR.session_unfocused` also pauses.

### 5.13 Filter and latency budget (tested by WI-20)
| Channel | Filter | Target |
|---|---|---|
| twist | One-Euro 1.2 Hz, β 1.0 | step 0→20°: 90% within ≤ 90 ms |
| dihedral | One-Euro 1.0 Hz, β 0.8; cycle-mean while stroking | 90% within ≤ 120 ms |
| extension | One-Euro 1.5 Hz, β 0.2 | tuck→spread 90% within ≤ 150 ms |
| hand velocity | 2 × 1-pole 8 Hz | flap onset ≤ 80 ms after the top of the stroke |
| shoulders | One-Euro 2 Hz, β 0.5 | a ±30° nod moves the shoulders ≤ 2 cm |
| torso yaw | τ 0.10 s gated follow, rate limit 400°/s | 180° turn over 2 s: lag ≤ 8° |

One-Euro (Casiez 2012): `fc = min_cutoff + β·|dx̂/dt|`, `α = 1/(1 + 1/(2π·fc·dt))`,
derivative cutoff 1 Hz.

---

## 6. Flap detection (FlapDetector, per wing)

### 6.1 Signal
```
rel = p_i − neck;  v_raw = (rel − rel_prev)/dt                       # relative to the neck: crouch, jump, walk cancel
v1 += (v_raw − v1)·k8;  v2 += (v1 − v2)·k8;   k8 = 1 − exp(−2π·8 Hz·dt)  # 2-pole, ≈ 40 ms delay
n0' = the §5.8 normal with incidence clamped to ±20°
ω   = −(v2·n0')/L_arm                                                # rad/s-equivalent; + = downstroke
```
Pushing down and back with a leading-edge-down wing counts; swimming horizontally with
flat wings produces nothing.

### 6.2 Arc bank and amplitude credit
```
if ω < −W_UP (0.15):  # upstroke (slow recoveries count)
    if state != UP: state = UP; up_arc = 0
    up_arc += −ω·dt;  bank = min(bank + (−ω·dt), 150°)
    up_i = gate_up ? clamp(−ω/ω_full_x, 0, 1) : 0        # gate_up: previous downstroke credit ≥ 0.5 within 1.5 s
elif ω > W_DN (0.9):  # downstroke
    if state == UP: amp = up_arc; state = DOWN; credit = smoothstep(A_MIN_x, A_FULL_x, amp)
    d = ω·dt;  use = min(d, bank);  bank −= use
    flap_i = min(ω·(use/d)·credit/ω_full_x, 1.3)
else: bank *= exp(−dt/8.0)
flap_i = 0 outside a credited downstroke;  bank = 0 when ext_i < 0.3 or on tracking loss
```
**Invariants.** There is no downstroke without a preceding upstroke of at least as much
arc, and small arcs earn little credit. Shakes, tremor and waggles fail both tests.
The upstroke produces force only as the continuation of a credited rhythm.

### 6.3 Size-aware effort normalisation (graft from the game panel)
```
xn = clamp((x − 0.287)/(1 − 0.287), 0, 1)                   # 0 = sparrow, 1 = eagle
ω_full_x = stroke_full_rate·lerp(1.10, 0.85, xn)·(seated ? 0.75 : 1)
A_MIN_x  = lerp(10°, 15°, xn)·(seated ? 0.75 : 1);   A_FULL_x = stroke_full_arc·lerp(0.8, 1.2, xn)·(seated ? 0.75 : 1)
```
> **Corrected in fix round 2** (§19 D-1; the sentence below was the design panel's
> claim, the measured behaviour follows it).

~~Small birds therefore reach full effort with quick, short strokes (±15° at 2 Hz); big
birds need deep, slower strokes.~~

What the detector rewards is **stroke rate times credit**: the downstroke's angular
speed along the wing normal over `ω_full_x`, credited by the upstroke arc that preceded
it (full credit from `A_FULL_x`, §6.2). For a sinusoidal stroke the effort therefore
scales with amplitude × frequency, and the reference stroke (±45° at 1 Hz) gives `p_ref`
at every size. Measured through the whole chain (round-2 verifier, 12 s flights):
- ±15° at 2 Hz gives a sparrow 64 % of the reference effort (mean flap 0.179 vs 0.278)
  and 34 % of its climb; about ±22° at 2 Hz gives the full reference effort. Small
  birds keep full credit on short arcs (`A_FULL` 28° for a sparrow, 42° for an eagle).
- Big birds' lower `ω_full_x` lets them reach full effort at a slower rate, but only a
  deep arc earns full credit.
- Frantic small strokes (±15–20 cm forearm pumps at 3–4 Hz) are credited too and can
  out-climb the reference (sparrow 92 %, pigeon 131 %, eagle 103–106 % of the deep 1 Hz
  stroke's climb) at about 5× its arm power (A²f³): hard work, not a cheap exploit. F9
  pins the boundary: ±10 cm at 4 Hz and faster earns nothing.

### 6.4 Reference stroke and `p_ref`
The **reference stroke** is arm elevation `45°·cos(2π·1.0 Hz·t)`: a 90° arc at 1 Hz,
sinusoidal, 50% downstroke, flat wrists. `FlightParams.p_ref(x)` is the mean
`flap + up_gain·up` of the reference stroke through *this* detector at size x.
`FlapDetector.reference_effort(x, seated)` computes it once per derive and caches it.
Because the model divides flap effort by `p_ref`, the reference stroke produces exactly
the §7.7 forces at every size, whatever the detector scaling. WI-13 checks the full
WingInput chain against the cached value (±5%).

For example, the prototype used an unscaled detector (ω_full = 4.5 at every size,
standing). With it the sparrow's downstroke mean is 0.343 and its upstroke mean 0.340,
so p_ref = 0.343 + 0.30·0.340 = 0.445. With the §6.3 scaling, the downstroke means are
0.312 (sparrow), 0.328 (starling), 0.351 (pigeon) and 0.404 (eagle). Only the
normalised forces matter, so tests assert the chain against the cached value, never a
hard-coded number.

### 6.5 Events
- **Onset:** `flap_i` first exceeds 0.25 in a stroke. Set `onset_i` and
  `onset_strength = credit`. Haptics fire on it immediately.
- `Events.player_flapped(side, strength)` is emitted at the onset with
  `strength = credit`. If the other wing's onset arrives within 60 ms, a single event
  goes out with `side = 0`. Onboarding counts strokes with strength > 0.25.
- `stroke_period` is the time between successive onsets on the same wing (EMA 0.5),
  clamped to 0.3–1.5 s. It decays toward 0.3 s after 1.5 s without an onset.

---

## 7. FlightModel (pure `RefCounted`, no scene dependencies)

### 7.1 Size derivation: `FlightParams.derive(mass, tuning)`
Everything derives from `SizeRules.performance(mass)` (V_c, V_min = 0.45·V_c,
V_max = 2.6·V_c, Ω = turn_rate, climb, agility) plus a small set of per-size anchors
over the size scalar
```
x = clamp(ln(m/0.004) / ln(4.5/0.004), 0, 1)          # moth 0, sparrow .287, starling .443, pigeon .636, eagle 1
anchor(key, x) = piecewise-linear over FlightTuning.curves[key] (x, value) points, clamped at the ends
```
```
b      = SizeRules.wingspan_for_mass(m);  r_body = SizeRules.body_radius_for_mass(m)   (= 0.16 b)
CL_n   = 0.30                                   # neutral-wrist trim lift coefficient (trims at V_c)
CL_max = CL_n·(V_c/V_min)² = 1.481              # 1-g stall exactly at V_min
S      = 2 m g / (ρ V_c² CL_n)                  # effective area, ρ = 1.225, g = 9.81
AR     = anchor(aspect);  k_i = 1/(π·0.85·AR);  LD = anchor(ld_max);  CD0 = 1/(4 k_i LD²)
a      = 4.6 /rad;  α_n = CL_n/a = 3.74°;  α_s = CL_max/a = 18.45°
φ_max  = clamp(atan(Ω V_c / g), 55°, 78°)       # the bank that gives SizeRules.turn_rate at cruise
n_max  = max(1.05/cos φ_max, 3.0 + 1.5·agility) # sustains the max-bank turn; stoop pull-outs in < 70 spans
T_ph   = π √2 V_c / g                           # phugoid period (the time unit of pitch tests)
τ_α, q_max, τ_φ, p_max, K_F, K_H, up_gain, τ_f  = anchors (table 8.2)
P_spec = 1.08·climb + 0.40                      # m/s of energy height per unit weight at reference effort
p_ref  = FlapDetector.reference_effort(x)       # §6.4: mean(flap + up_gain·up) of the reference stroke
p_ref⁺ = same with max(0, up_gain)              # positive part (power and endurance caps)
E_CAP  = 1.15                                    # endurance: stroke-averaged effort ≤ 1.15·p_ref⁺
τ_wc   = 0.35 + 0.35·(1 − agility);  τ_sf = 0.6·τ_wc     # yaw channel (weathercock, side force)
```
`set_mass(m)` re-derives these (about 60 flops) and **keeps the state**, so growth is
continuous (FM-26).

### 7.2 State
| Field | Meaning |
|---|---|
| `position`, `velocity` | Vector3, world. For the player, the position is the eye/body point. |
| `chi` | Path heading: the yaw of the horizontal air velocity, **held** while that velocity is small (§7.3). |
| `theta` | Body pitch. Visual and telemetry only; **never** applied to the camera. |
| `phi`, `phidot` | Bank and bank rate. |
| `dpsi` | Yaw offset of the body from the path (sideslip, + = nose left of the path). |
| `stalled`, `t_stall`, `sigma` | Stall FSM, time in stall, separation blend. |
| `delib_t`, `stall_side` | Deliberate-stall timer; wing-drop side. |
| `udot` | Filtered dV/dt (τ 0.05 s), for the phugoid damper. |
| `V_lp`, `vh_lp` | Airspeed and horizontal airspeed, 0.5 s low-passed (posture cap and regime weight). |
| `P_l`, `P_r`, `U_l`, `U_r` | Flap and upstroke efforts, low-passed with τ_f. |
| `yaw_rate`, `yaw_acc` | Measured heading rate and acceleration (telemetry, comfort). |

### 7.3 Step algorithm (per substep `h = dt/ceil(dt·120)`; Appendix A is the exact pseudocode)
1. **Air data.** `va = v − W(x)`, `V = |va|`, `vh = |va_xz|`. The heading update:
   `χ += w·wrap(atan2(−va.x, −va.z) − χ)`, with `w = smoothstep(0.1, 0.4, vh/V_min)`,
   only if the wrapped difference is under 90°. A tail-slide or a vertical climb never
   flips the heading. The path angle `γ = atan2(va.y, va·f_h)` is signed along the held
   heading `f_h`, so it stays continuous through vertical flight.
2. **Flap smoothing and endurance.** `P_side += (clamp(ws.flap_side, 0, 1.3) − P_side)·(1 − e^{−h/τ_f})`,
   and the same for the upstroke efforts. Push this substep's raw effort into the
   per-wing stroke-synchronous buffer that gives Ē (§7.7).
3. **α command** (§7.4) → `α_cmd`.
4. **Posture cap.**
   `θ_hi = 90°·smoothstep(0.5, 1.2, max(vh_lp/V_min, (V_lp − V_min)/(0.5 V_min)))`.
   There are no tail-stands without real airspeed, while a fast zoom climb may go
   vertical.
5. **Pitch.**
   `θ += clamp((clamp(γ + α_cmd, θ_lo, θ_hi) − θ)/τ_α, ±q_max)·h`, where
   `θ_lo = −90°·(1 − hov)` and
   `hov = smoothstep(0.05, 0.2, mean P)·(1 − smoothstep(0.3, 0.6, V_lp/V_min))`.
   A *powered* hover holds the body near level. An unpowered stall-fall keeps the full
   range, so the nose can drop and recover (aero's lesson).
   Then, if stall-protect is on, the pilot is not deliberately stalling, and
   `V_lp ≥ 0.5 V_min` (AoA is meaningless below that): `θ = min(θ, γ + α_s − 0.5°)`.
   This is the reflex on the **actual** AoA. Then `α = θ − γ`.
6. **Stall FSM** (§7.5), **bank** (§7.6) and **yaw channel** (§7.6).
7. **Translate (Heun):** `a1 = acc(x, v)`, `a2 = acc(x + v h, v + a1 h)`,
   `v' = v + ½(a1 + a2)h`, `x' = x + ½(v + v')h`. `acc()` (§7.7) evaluates lift, drag,
   flap and side force at the given state, with α re-evaluated as θ − γ(state).
8. **Weathercock feed-forward:** `θ += w_a·wrap(γ(v') − γ)`, where
   `w_a = smoothstep(0.5 V_min, V_min, V_lp)`. The body rotates with its actual flight
   path, so α tracks α_cmd with lag τ_α at any speed. Re-apply the stall-protect clamp
   with the new γ. Then `θ = clamp(θ, −90°, 90°)`.
9. **Guards.** Non-finite state restores the last good state, zeroes rates and logs
   once. Speed is capped at `|v| ≤ 3·V_max`.

### 7.4 Pitch channel: AoA command, balloon, phugoid, protection
```
p = clamp(ws.pitch, −1, 1);  spread = mean ext;  f_A = 0.25 + 0.75·spread
top = α_s − 1° (stall_protect on) | α_s + 4° (sim preset)
α_b = α_n + p·(top − α_n)          if p ≥ 0          # nose-up: linear in α (the balloon lever)
α_b = α_n·(1 + p)                  if p < 0          # nose-down: linear in lift; −1 = zero lift (dive)
α_b += −2°·clamp((0.5 − spread)/0.5, 0, 1)           # tuck-to-dive
if turn_comp and α_b > 0:  α_b *= 1 + 0.85·(1/max(cos φ, 0.34) − 1)            # level turns without pulling
if damper and not stalled: α_b += (0.4 if u̇ > 0 else 0.1)·clamp(u̇/g, −1, 1)·min(1, (V_c/V)²)
if nlimit and α_b > 0:     α_b = min(α_b, n_max·m g/(q S f_A a))               # q = ½ρV²
if stall_protect:          delib_t = p ≥ 0.9 ? delib_t + h : 0
                           α_b = (delib_t ≥ 0.35) ? α_s + 4°·p : min(α_b, α_s − 1°)
if stalled:                α_b −= 12°/s·t_stall;  if t_stall > 1.5 s: α_b = min(α_b, α_s − 3°)
α_cmd = α_b
```
Nothing about the **balloon** is scripted. A nose-up step raises α_cmd, lift jumps
within τ_α, the path curves up, speed bleeds, and the bird settles at the slower trim
of the new α. The rise is 6.5–8.2 spans at every size, peaking at 1.4–3.2 s, and is
temporary (FM-03).

**Nose-down** speeds the bird up to the trim of `CL = CL_n(1 + p)`: +15% at p = −0.25,
+41% at −0.5, and a dive at −1.

### 7.5 Stall
```
enter: α > α_s + 0.5°  (count++, emit ev_stall_started; side = sign(φ) if |φ|>1°, else sign(roll) if |roll|>0.02, else alternate)
exit:  t_stall > 0.3 s and α < α_s − 3° and not (stall_protect and p ≥ 0.9 and t_stall ≤ 1.5 s)
σ += ((stalled ? 1 : 0) − σ)·(1 − e^{−h/0.15})                      # separation blend (smooth lift loss/recovery)
stall_warning = stalled ? 1 : smoothstep(α_s − 6°, α_s, α)            # buffet from about pitch 0.7
wing drop: φ_cmd += 15°·side·smoothstep(0, 0.5 s, t_stall)
```
- **Lift curve.** Attached: `CL = clamp(aα, −0.5, 1.05 CL_max)`. Post-stall:
  `lerp(min(aα, 0.6 CL_max), 0.9 sin 2α, smoothstep(α_s+2°, α_s+20°, |α|))`.
  Geometric separation beyond α_s + 1°…6° applies even without the flag.
- **Drag.** `CD = CD0(0.35 + 0.65 f_A) + f_A k_i CL² + 0.16 σ + 1.8 sin²α·smoothstep(α_s, α_s+15°, |α|)`.
- Holding full nose-up gives at most one stall per 1.5 s (forced recovery).
  Pitch ≤ 0.85 never stalls with protection on.

### 7.6 Roll and yaw: bank command, coordination, rudder, kicks
```
φ_cmd = roll·φ_max + 18°·(A_l − A_r) + 0.5·(ext_l − ext_r)·φ_max (+ stall wing drop)
        # one-wing flap: rolls AWAY from the stroking wing; one-wing fold: rolls TOWARD the folded wing
        # A_side (fix round 4, §19 R4-6): each wing's net effort (flap + max(0, up_gain)·up) averaged
        # over the last stroke period, with the relative asymmetry |A_l − A_r|/(A_l + A_r) beyond a
        # 0.15 dead zone kept (rescaled to full at a one-wing stroke): arms up to ~25 % unequal or
        # any timing offset are a symmetric stroke (round 3 used the instantaneous P_l − P_r)
lim   = φ_max;  p_lim = p_max·clamp(V/V_c, 0.4, 1.25)                # roll authority falls when slow
player comfort (§11.2): lim = min(lim, atan(Ψ̇_max·max(V, V_min)/g));  p_lim = min(p_lim, Ψ̈_max·max(V,V_min)·cos²φ/g)
φ̇ = clamp((clamp(φ_cmd, ±lim) − φ)/τ_φ, ±p_lim);  φ += φ̇ h
```
**Coordinated turn.** The lift vector is tilted by φ about the airflow (§7.7), so the
path turns at exactly `ψ̇ = L sin φ/(m V cos γ)`. In level flight that is
`g·tan φ/V`, measured to within 0.1–1.6% (FM-08). The bird has no sideslip from
banking.

**Rudder and yaw channel.**
```
N_adv  = (1 − k_rud)·0.04·(aα/CL_n)·φ̇                 # adverse yaw (rolling right yaws the nose left)
N_kick = −0.35·(A_l(0.3 + sin δ_l) − A_r(0.3 + sin δ_r))  # one-wing paddle yaw (δ = forward tilt of flap_dir; A as above)
dψ̇ = N_adv + N_kick − dψ/τ_wc − dψ/τ_sf
side acceleration (in acc): (vh·dψ/τ_sf) toward the body side (the path follows the body)
```
`k_rud = 1` is the **auto-rudder**, which cancels adverse yaw exactly. Tests set 0 to
prove adverse yaw exists (FM-10). The model's body heading is `heading = χ + dψ`.

### 7.7 Forces (`acc(x, v)`)
```
va = v − W(x);  V = |va|;  v̂ = va/V;  f_h, r_h from χ
perp  = normalize(r_h − (r_h·v̂)v̂) × v̂      # lift axis ⟂ airflow, continuous through vertical flight
ra    = v̂ × perp;  l̂ = cos φ·perp + sin φ·ra                 # bank tilts lift: the coordinated turn
L = q S f_A CL(θ − γ(va));  D = q S CD + m g·31·max(0, V/V_max − 0.85)²   # speed governor (L7)
a = (0, −g, 0) + (L l̂ − D v̂)/m + Σ_side F_flap,side/m + side_accel(dψ) + env.accel
```
**Flap force per wing** (both wings sum to the stroke-averaged K below):
```
up_b = cos φ·UP + sin φ·r_h;  r_b = cos φ·r_h − sin φ·UP             # banked frame at heading χ
d̂    = r_b·d.x + up_b·d.y + f_h·(−d.z)                              # d = ws.flap_dir_side (level body frame)
   (+ flap floor, 9.1: tilt d̂ 8°·(1 − vh/(0.8 V_min)) forward if K_H < 1, sinking, vh < 0.8 V_min, pitch ≤ 0.3)
d̂   −= r_b·(d̂·r_b)·(1 − flap_side_share)                            # fix round 4 (§19 R4-5): no force across the body (share 0)
en   = min(1, E_CAP·p_ref⁺ / Ē_side)                                # endurance: Ē = full-window mean of
                                                                     #   (flap + max(0,up_gain)·up) over ws.stroke_period
e    = en·(P_side + up_gain·U_side)                                  # net effort this substep
K    = lerp(K_H, K_F, smoothstep(0, 1, vh/V_min))                    # hover → forward-flight force ratio (advance ratio)
F    = ½ m g · K · e / p_ref                                        # reference stroke ⇒ mean total force K·m g
if F > 0 and d̂·va > 0:  F = min(F, ½ m g · P_spec·en·(P_side + max(0,up_gain)·U_side)/p_ref⁺ / (d̂·va))   # muscle power
F_flap = F·d̂
```
Here `p_ref⁺` is p_ref computed with `max(0, up_gain)`.

- **Direction** is the wing normal the player makes. Flat wrists give the banked "up";
  leading edge down tilts toward the heading. FM-11 measures the impulse direction:
  0°/17°/35° forward, −20° back.
- **Power cap.** `F·v_air ≤ P_spec` per unit weight, so hard flapping trades climb
  against speed and can never become a rocket. Best sustained climb is
  1.09–1.13 × `SizeRules.climb` (FM-13). A flat flap from a standstill rises straight
  up for hover-capable birds and sinks for the others (FM-14).
- **Hover capability** is K_H·(up to E_CAP): small birds hover-climb slowly, and
  flapping frantically gains them about 0.7–1.4 m/s. Pigeons and larger cannot hold
  position even frantically; they sink and drift forward to find airspeed (FM-14).

### 7.8 Tuck and dive
Extension `f_A` scales area, and tucking biases α down 2°. `pitch −1` plus a tuck
reaches 0.98–1.00 × V_max within 3.3–6.7 s (FM-15), limited by the speed governor.
Pull-out from V_max at pitch +0.5 loses 54–69 spans at ≤ n_max g, within 4% of the
ideal circle `V_max²/((n_max−1)g)` (FM-16).

### 7.9 Updrafts and wind
Wind is sampled from `World.get_wind(pos)` at the body, **per Heun evaluation**
(the World must keep it C¹-smooth). Thermals and ridge lift are simply `W.y > 0`.
Neutral gliding in a uniform 3 m/s updraft climbs at +1.15…+1.50 m/s. Slow circling
at 30° bank (pitch 0.6) climbs at +1.98…+2.32 m/s (FM-19), with zero flapping. The
wingtip samples `wind_l/wind_r` feed only haptics and telemetry; they are not physics
(a C¹ field keeps roll neutral). A change of the horizontal wind turns the air path
under the bird, not its body: the wind's share of that turn goes into the sideslip
channel, and the heading weathercocks into the new relative wind (§19 W-3).

### 7.10 FlightEnv
```gdscript
class_name FlightEnv extends RefCounted
var wind_fn: Callable            # (pos: Vector3) -> Vector3; default World.get_wind; empty = still air
var wind_l := Vector3.ZERO       # sampled at the wingtips (haptics/telemetry only)
var wind_r := Vector3.ZERO
var ground_distance := INF       # m along -Y to layer 1 (ray <= 2 spans), for cushion/ground effect/AGL
var ground_normal := Vector3.UP
var lift_scale := 1.0            # ceiling fade from World (thin air above World.ceiling - 20 m)
var accel := Vector3.ZERO        # assist accelerations (perch assist steering), world m/s^2, bounded by caller
var alpha_bias := 0.0            # assist AoA bias (perch auto-flare / ground cushion), rad, bounded +-3 deg
var drag_bonus := 0.0            # assist CD increment (landing configuration: legs and tail down), 0..0.4
```

### 7.11 Public API
```gdscript
class_name FlightModel extends RefCounted
var tuning: FlightTuning; var params: FlightParams
var assists := {}                          # StringName -> bool, from tuning preset (section 9)
var k_rud := 1.0                           # auto-rudder (tests: 0)
var comfort_yaw_rate := 0.0                # rad/s, 0 = off (player only; section 11.2)
var comfort_yaw_accel := 0.0               # rad/s^2, 0 = off
# state (read-only to callers)
var position: Vector3; var velocity: Vector3
var chi: float; var dpsi: float; var theta: float; var phi: float; var alpha: float
var stalled: bool; var stall_warning: float
func _init(mass: float = 0.03, p_tuning: FlightTuning = null) -> void
func set_mass(mass: float) -> void                       # re-derive; state kept (growth)
func reset(pos: Vector3, vel: Vector3, heading := NAN) -> void    # theta = gamma + alpha_n, phi = dpsi = 0, filters cleared
func trim(pos: Vector3, heading: float, pitch := 0.0) -> void    # solve the steady glide at `pitch` analytically, start there
func step(ws: WingState, env: FlightEnv, dt: float) -> void      # substeps internally (h <= 1/120 s)
func displace(delta: Vector3) -> void                    # kinematic move, no velocity change (player head motion)
func apply_contact(normal: Vector3, kind: int) -> float  # SLIDE / BOUNCE: modifies velocity (section 12); returns v_n
func heading() -> float                                  # chi + dpsi (beak)
func forward() -> Vector3                                 # Basis(Y, heading) * Basis(X, theta) * -Z
func airspeed() -> float; func gamma() -> float
func telemetry() -> Dictionary                           # physics keys of section 10.7 (builds a Dictionary only when asked)
func last_forces() -> Dictionary                         # {lift, drag, flap, gravity: Vector3, flap_impulse: Vector3}
func drain_events() -> PackedStringArray                 # "stall", "unstall" since the last call
static func envelope(mass: float, tuning: FlightTuning = null) -> Dictionary   # section 7.12
```
Allocation-free stepping: preallocate everything and build no Dictionaries inside
`step`.

### 7.12 `FlightModel.envelope(mass)`: the published envelope (for AI, HUD and tests)
`{cruise, min_speed, max_speed, phi_max, n_max, turn_rate_cruise, t90_roll,
climb_best, v_climb_best, climb_at_cruise, glide_ratio, min_sink, hover_capable,
t_phugoid}`.

`climb_best`, `v_climb_best` and `climb_at_cruise` come from the §7.7 power law,
computed analytically at derive time from the glide polar and P_spec. They are
confirmed by FM-01, FM-02, FM-13 and FM-27 within ±10%.

---

## 8. Parameter tables per species tier

### 8.1 Derived envelope (exact output of 7.1 for each ladder species)
| species | m kg | span m | x | V_c | V_min | V_max | turn_rate °/s | climb | agility | S m² | W/S N/m² | AR_eff | CD0 | L/D_max | φ_max ° | n_max | T_ph s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| moth¹ | 0.004 | 0.08 | 0.000 | 6.43 | 2.89 | 16.7 | 371 | 4.80 | 1.00 | 0.0052 | 7.6 | 4.50 | 0.0711 | 6.5 | 76.8 | 4.59 | 2.91 |
| wren¹ | 0.012 | 0.16 | 0.156 | 7.73 | 3.48 | 20.1 | 279 | 4.34 | 1.00 | 0.0107 | 11.0 | 4.97 | 0.0541 | 7.8 | 75.4 | 4.50 | 3.50 |
| **sparrow** | 0.03 | 0.24 | 0.287 | 9.00 | 4.05 | 23.4 | 220 | 4.00 | 1.00 | 0.0198 | 14.9 | 5.36 | 0.0448 | 8.9 | 74.2 | 4.50 | 4.08 |
| swallow | 0.055 | 0.33 | 0.373 | 9.96 | 4.48 | 25.9 | 188 | 3.79 | 0.83 | 0.0296 | 18.2 | 5.62 | 0.0401 | 9.7 | 73.3 | 4.25 | 4.51 |
| starling | 0.09 | 0.40 | 0.443 | 10.81 | 4.86 | 28.1 | 165 | 3.62 | 0.72 | 0.0411 | 21.5 | 5.83 | 0.0369 | 10.3 | 72.5 | 4.08 | 4.90 |
| **pigeon** | 0.35 | 0.66 | 0.636 | 13.55 | 6.10 | 35.2 | 116 | 3.21 | 0.48 | 0.1017 | 33.8 | 6.41 | 0.0302 | 11.9 | 70.4 | 3.72 | 6.14 |
| crow | 0.6 | 0.95 | 0.713 | 14.83 | 6.67 | 38.6 | 101 | 3.05 | 0.41 | 0.1457 | 40.4 | 6.64 | 0.0281 | 12.6 | 69.4 | 3.61 | 6.72 |
| gull | 1.1 | 1.30 | 0.799 | 16.40 | 7.38 | 42.7 | 86 | 2.89 | 0.34 | 0.2182 | 49.4 | 6.90 | 0.0261 | 13.3 | 68.3 | 3.51 | 7.43 |
| hawk | 1.6 | 1.60 | 0.853 | 17.46 | 7.86 | 45.4 | 78 | 2.80 | 0.30 | 0.2802 | 56.0 | 7.06 | 0.0249 | 13.7 | 67.6 | 3.45 | 7.91 |
| **eagle** | 4.5 | 2.10 | 1.000 | 20.75 | 9.34 | 53.9 | 60 | 2.55 | 0.22 | 0.5582 | 79.1 | 7.50 | 0.0223 | 15.0 | 65.6 | 3.33 | 9.40 |

¹ **Moth and wren are NPC-only.** The player starts as a sparrow and only grows. They
are listed for NPC FlightModel use; the player acceptance criteria apply from sparrow
to eagle.

Wing loading rises 5.3× from sparrow to eagle. That is what makes big birds faster and
heavier, gives them wider turns, and makes them unable to hover. The effective areas
are game-scaled (about 2× real for small birds) so that `min_speed = 0.45 × cruise`
holds.

### 8.2 Per-size anchors (`FlightTuning.curves`; piecewise-linear in x) and their values
| key | x = 0 (moth) | .287 (sparrow) | .443 (starling) | .636 (pigeon) | 1 (eagle) | meaning |
|---|---|---|---|---|---|---|
| `aspect` | 4.5 | 5.36 | (interp.) | 6.41 | 7.5 | effective AR (induced drag) |
| `ld_max` | 6.5 | 8.94 | (interp.) | 11.9 | 15 | best glide ratio at full spread |
| `tau_alpha` s | 0.08 | 0.112 | (interp.) | 0.150 | 0.19 | AoA lag |
| `pitch_rate_deg` | 400 | 320 | (interp.) | 222 | 120 | q_max |
| `tau_bank` s | 0.12 | 0.186 | (interp.) | 0.266 | 0.35 | bank lag τ_φ |
| `roll_rate_deg` | 420 | 343 | (interp.) | 248 | 150 | p_max at V_c |
| `flap_force` (K_F) | 1.6 | 1.5 | 1.4 | 1.3 | 1.2 | mean flap force in weights, reference stroke, V_h ≥ V_min |
| `hover_force` (K_H) | 1.35 | 1.20 | 1.02 | 0.80 | 0.60 | same at V_h = 0 (hover capability; K_H·E_CAP < 1 for pigeon and up) |
| `up_gain` | +0.30 | +0.30 | +0.10 | −0.08 | −0.08 | upstroke effort gain (lift for small birds, small cost for big) |
| `flap_tau` s | 0.30 | 0.30 | (interp.) | 0.26 | 0.22 | flap force smoothing τ_f |

Resolved per-species values:

| species | τ_α | q_max °/s | τ_φ | p_max °/s | K_F | K_H | up_gain | τ_f | P_spec m/s | τ_wc | ws² | perceived V_c m/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sparrow | 0.112 | 320 | 0.186 | 343 | 1.50 | 1.20 | +0.30 | 0.30 | 4.72 | 0.35 | 0.141 | 64 |
| swallow | 0.121 | 296 | 0.206 | 320 | 1.44 | 1.10 | +0.19 | 0.29 | 4.49 | 0.41 | 0.194 | 51 |
| starling | 0.129 | 276 | 0.222 | 300 | 1.40 | 1.02 | +0.10 | 0.28 | 4.31 | 0.45 | 0.235 | 46 |
| pigeon | 0.150 | 222 | 0.266 | 248 | 1.30 | 0.80 | −0.08 | 0.26 | 3.86 | 0.53 | 0.388 | 35 |
| crow | 0.158 | 200 | 0.284 | 227 | 1.28 | 0.76 | −0.08 | 0.25 | 3.70 | 0.56 | 0.559 | 27 |
| gull | 0.168 | 176 | 0.304 | 204 | 1.26 | 0.71 | −0.08 | 0.24 | 3.52 | 0.58 | 0.765 | 21 |
| hawk | 0.174 | 161 | 0.316 | 190 | 1.24 | 0.68 | −0.08 | 0.24 | 3.42 | 0.59 | 0.941 | 19 |
| eagle | 0.190 | 120 | 0.350 | 150 | 1.20 | 0.60 | −0.08 | 0.22 | 3.15 | 0.62 | 1.235 | 17 |

² `ws = span/(1.50 + 0.20)`: VR's default formula with the default arm span.

Global constants (FlightTuning, not per size): ρ 1.225, CL_n 0.30, a 4.6, Oswald
0.85, CL clamp −0.5, post-stall plateau 0.6 CL_max, separation τ 0.15 s, stall drag
0.16, plate 1.8, governor start 0.85·V_max with gain 31, turn_comp 0.85, damper
0.4/0.1, stall margins (−1°, +0.5°, −3°, +4°), deliberate 0.9 held 0.35 s, nose-drop
12°/s, forced recovery 1.5 s, wing drop 15°, warn from α_s − 6°, tuck bias −2°,
roll kick 18°, extension roll 0.5, adverse 0.04, paddle yaw 0.35, flap floor 8°,
P_spec 1.08·climb + 0.40, E_CAP 1.15, substep 120 Hz.

### 8.3 How the sizes feel (prototype, Appendix B)
| | sparrow (start) | pigeon | eagle (apex) |
|---|---|---|---|
| cruise / stall / dive cap m/s | 9.0 / 4.05 / 23.4 | 13.6 / 6.1 / 35.2 | 20.7 / 9.3 / 53.9 |
| glide at neutral: L/D, sink | 6.0, 1.50 m/s | 8.5, 1.59 | 11.3, 1.84 |
| max-input turn (gliding) | 198°/s, R ≈ 2.6 m | 109°/s | 55°/s, R ≈ 21 m |
| bank t90 at roll 0.6 | 0.43 s | 0.61 s | 0.81 s |
| balloon at pitch +0.5 | +1.9 m (7.9 spans) at 1.4 s | +5.4 m at 2.1 s | +14.1 m at 3.2 s |
| hard flat flapping from standstill | hover-climbs +1.43 m/s, drift 0.4 | sinks 0.87 m/s, drifts forward 2.7 m/s | sinks 1.5 m/s, drifts 5.7 m/s (must dive for airspeed) |
| frantic flapping (60° at 2.2 Hz) | climbs +2.14 m/s (capped at 1.15× force) | sinks 0.91 m/s: cannot hover | sinks 2.8 m/s |
| best sustained climb | 4.35 m/s at 5.4 m/s | 3.60 at 5.8 | 2.88 at 7.6 |
| level flapping effort | 30% of reference | 30% | 40% |
| V_max pull-out | 16.5 m | 45 m | 117 m |
| 3 m/s updraft, no flapping (neutral / circling) | +1.50 / +2.32 m/s | +1.41 / +2.20 | +1.15 / +1.98 |

---

## 9. Assists and the gameplay-law ledger

Every non-physical term is a named, bounded law with a physical analogue and a test.
The `flight_assist` setting selects a preset (`FlightTuning.apply_preset`):
- **0 sim:** only the safety set is on: governor, attitude limits, stall hysteresis,
  collisions.
- **1 normal:** the default.
- **2 novice:** turn_comp 1.0, perch assist at 8 spans and 0.6 g, cushion 0.8 g,
  deliberate-stall hold 0.6 s, body-steer dead-zone 5°, dead-zones ×1.4.

| # | Law / assist | Removes | Mechanism (normal preset) | Physical analogue | Bound | Test |
|---|---|---|---|---|---|---|
| G1 | Bank-angle command (`auto_level`) | holding the wings level by hand (the camera never rolls) | roll → φ_cmd, first-order τ_φ | vestibular wing-levelling reflex | p_lim, φ_max | FM-07, FM-09 |
| G2 | Auto-rudder `k_rud` | sideslip | cancels adverse yaw | rudder plus weathercock stability | k_rud ∈ [0,1] | FM-10 |
| G3 | `turn_comp` | losing height in every turn | α ×(1 + 0.85(sec φ − 1)) | pilot back-pressure | ≤ n_max, ≤ α_s − 1° | FM-08 |
| G4 | `phugoid_damper` | endless porpoising | +0.4/0.1·u̇/g·min(1,(V_c/V)²) | attitude-holding pilot | ±0.4 rad | FM-03, FM-16 |
| G5 | `nlimit` | 10 g zooms from a twitch at V_max | α ≤ α(n_max) | structural limit | n_max(x) | FM-16 |
| G6 | `stall_protect` | accidental stalls | actual α ≤ α_s − 0.5° unless pitch ≥ 0.9 for 0.35 s; forced recovery at 1.5 s | stall-warning reflex | deliberate stalls stay possible | FM-05, FM-06 |
| G7 | Speed governor | runaway dives; `max_speed` contract | overspeed drag from 0.85 V_max | feather flutter drag | V ≤ 1.00·V_max | FM-15 |
| G8 | Horizon/bank-referenced flap direction | pitch-coupled flap feedback | d̂ in the banked level frame | stroke plane set independently of the body | exact | FM-11 |
| G9 | Posture cap θ_hi | tail-stands without airspeed | θ ≤ 90°·smoothstep(…V_lp…) | hovering birds hold posture | uses 0.5 s airspeed | FM-14 |
| G10 | Game roll inertia and roll ∝ V | snappy turns (smooth, never snappy) | τ_φ 0.12–0.35 s, p_lim ∝ V | none (real birds roll faster) | per size | FM-07 |
| G11 | Reference-stroke normalisation, power cap and endurance cap | 1 Hz human arms vs 3–20 Hz bird wings; frantic flapping winning | K_F, K_H, P_spec, E_CAP 1.15 (stroke-synchronous) | wingbeat frequency, muscle power, endurance | climb ≤ 1.25·perf; frantic ≤ 1.15× force | FM-13, FM-14 |
| G12 | `flap_floor` | a non-hovering bird flapping flat until it stall-falls | +8°·(1 − vh/0.8V_min) forward tilt when K_H < 1, sinking, pitch ≤ 0.3 | a bird tilting its stroke plane to gain speed | ≤ 8° | FM-14 |
| G13 | Attitude limits | loops and inversion (view never pitches) | θ ∈ [−90°, 90°], abs(φ) ≤ φ_max < 78° | — | exact | FM-23 |
| G14 | Comfort caps (player) | yaw overload | yaw rate ≤ 240°/s, accel ≤ 720°/s² as bank limits | — | Settings | PB-02 |
| G15 | `ground_cushion` | face-planting while skimming grass or water | h < 0.5 span, v_y < 0, γ > −35°: `env.accel.y += 0.6 g(1 − h/0.5span)²·min(1, −v_y/2)`; induced drag ×(1 − 0.5(1 − h/span)²) for h < span. Fix round 5 (§19 R5-3, R5-4): the same switch carries the **landing configuration** (a slow, sinking, flaring bird within 4 spans of the ground: +0.4 CD at most, ≤ 0.5 g) and, with stall protection, the **stall guard** (no deliberate stall below 0.4 g·T_fr² + 0.25 V_min²/g) | ground effect | steep dives still hit (stun) | PB-15 †, G1–G7 |
| G16 | `perch_assist` | pixel-perfect landings | §10.6: steering ≤ 0.4 g, α bias ≤ 3°, landing drag ≤ 0.4 | legs and tail as air brakes | too fast still bounces | PB-10 † |
| G17 | `body_steer` | fighting the torso after turning in the room | §10.4: torso error → bank demand | a coordinated turn | ≤ 0.8 φ_max | PB-05 |
| G18 | `tracking_glide` | tracking loss → crash | §5.12 | — | — | WI-18 |
| G19 | Stun instead of death | instant-death frustration | §12 | — | 0.6–1.4 s | PB-12 † |

Lift and drag (polar, induced drag, stall), gravity, the energy trade, wind, the
coordinated turn from lift tilt, the balloon, the phugoid, flap-thrust direction,
power-limited climb and the weathercock are first-principles and **emerge**.

---

## 10. PlayerBird (`extends Bird`, root of `scenes/player/player.tscn`)

### 10.1 Scene and API
```
PlayerBird (Node3D, PROCESS_MODE_PAUSABLE, group "player"; never scaled; yaw only)
└── XROrigin3D (group "player_rig", PROCESS_MODE_ALWAYS; translation only, never rotated or scaled)
    ├── XRCamera3D (near = 0.03·world_scale, far ≤ 3000)
    ├── LeftHand / RightHand   (XRController3D, trackers left_hand/right_hand, pose &"grip")
    ├── LeftAim / RightAim     (XRController3D, pose &"aim": the UI laser)
    └── WingAnchors/L, R       (Node3D placed from the ACTIVE pose source; the VR/birds areas attach wing meshes here)
```
```gdscript
class_name PlayerBird extends Bird
enum Mode { SPAWNING, FLYING, PERCHED, GROUNDED, STUNNED, CAUGHT }
@export var tuning: FlightTuning
@export var auto_process := true            # tests set false and call tick(dt)
var mode: Mode; var model: FlightModel; var wing_input: WingInput; var pose_source: PoseSource
var perch: Perch                            # when PERCHED
func is_player() -> bool                    # true
func get_body_position() -> Vector3         # == global_position (the eye/body point, 10.3)
func get_forward() -> Vector3               # model.forward(): beak heading with body pitch (not the gaze)
func telemetry() -> Dictionary              # 10.7
func respawn(xform: Transform3D) -> void    # 10.2
func set_controls_enabled(on: bool) -> void # off: WingState neutral glide (menus, CAUGHT); mode unchanged
func set_pose_source(src: PoseSource) -> void
func wing_state() -> WingState              # read-only view for visuals, haptics, UI lessons
func begin_calibration(kind: StringName) -> void    # &"neutral", &"strokes", &"glide"
func calibration_status() -> Dictionary
func perch_on(p: Perch) -> void             # forced perch (respawn, tests)
func tick(dt: float) -> void                # exactly what _physics_process does
func _on_mass_changed() -> void             # model.set_mass(mass) in the same tick; species follows SizeRules
```

### 10.2 State machine
```
 respawn() ─▶ SPAWNING ─0.5 s (or a fitting perch within 1 span)─▶ PERCHED ──completed flap (credit ≥ 0.35)────────▶ FLYING
                                                                     ▲                                                     │
                            capture (10.6) ──────────────────────────┘◀────────────────────────────────────────────────────┤
 GROUNDED ◀── touchdown (V ≤ 1.2 V_min, n.y > 0.7, not perch geometry, v_n ≤ 1 V_min; the feet first; run-out) ◀────────┤
    └── takeoff: 1 credited stroke (x ≤ 0.64) | 2 strokes within 1.2 s (x > 0.64, a "running take-off") ──▶ FLYING           │
        (off the surface; no touchdown again while it keeps flapping, until 2 spans clear: fix round 6)                   │
 STUNNED ◀── head-on impact (section 12) ◀───────────────────────────────────────────────────────────────────────────────┘
    └── t_stun ──▶ FLYING (on ground: GROUNDED); controls fade in over 0.4 s
 Game unpaused: WingInput.resume() (poses trusted, stroke detectors restarted); controls neutral until the
    arms are out and settled (both extended > 0.6, |ω| < 0.5 rad/s) or 1.5 s, then fade in over 0.4 s (fix round 5)
 any ── GameLoop on_caught ──▶ CAUGHT (controls disabled; the model keeps gliding level) ── respawn() ──▶ SPAWNING
 Game PAUSED: tick() is not called (pausable); XROrigin3D, camera and hands keep updating (ALWAYS)
```
- **PERCHED / GROUNDED.** The body is locked to `perch.position + UP·r_body` (or the
  ground contact point), with velocity 0; on the ground after a touchdown it first runs
  out (fix round 5, §19 R5-2; along slopes, fix round 6, §19 R6-2): the run keeps to the
  ground's plane and brakes at μg·cos(slope) plus gravity along it (μ =
  `ground_friction` 0.6), at least `run_brake_min`·μg (0.3 g); it is swept (a steeper
  floor ahead turns it onto it, a wall along the wall) and settled onto the ground below;
  running off an edge, over a ridge (the ground falls away by more than 20°) or onto
  ground too steep to stand on is flying again, stepping off the way the bird faces.
  The **feet** reach `leg_reach` (1) body radius beyond the body, so they meet the ground
  first, and the **legs** take the speed into it along the surface normal over the reach
  plus at most `leg_flex` (0.75) body radii of bend (fix round 6, §19 R6-1): a constant
  deceleration, the gentlest that fits (a stop exactly at rest when that takes ≤ 2 g,
  else a bend at 2 g or what the whole travel needs; a settle slower than 1 g moves down
  at 1 g), then back to rest at ≤ 2 g. The **heading follows the torso**
  (`heading = rig_yaw + body_yaw`), so turning your body on a perch turns the bird and
  the view never rotates. Head motion moves the camera but not the anchor, within a
  real-world leash of ±0.5 m. `perch.occupant = self`, released on launch.
- **Launch.** A launch calls
  `model.reset(pos, heading_dir·0.6 V_min + n·0.35 V_min·credit, heading)` with `n` the
  ground's normal (UP off a perch); during a run-out it keeps the run's speed
  (`run + heading_dir·max(0, 0.6 V_min − run·heading_dir)`, fix round 5). Off a slope the
  launch never points into it: its part into the ground is removed at the same speed
  (fix round 6, §19 R6-3). Perches are ignored for 0.4 s afterwards. A bird launched off
  the ground is not touched down again while it keeps flapping (a stroke began within
  1.2 s) or for 0.5 s, until it is two spans clear of the surface below: touching the
  ground meanwhile is its feet scrambling (a silent contact, no friction), unless it no
  longer makes way up or along the slope, when its feet hold it (a touchdown; it never
  slides back down on its belly).
  - **Off a perch (fix round 4, §19 R4-4):** only a *completed flap* launches: a
    credited downstroke (credit ≥ 0.35) that ends with the wing still out (arm at or
    above the fold line, raw extension ≥ 0.5), or that ended low and rises back out
    within 0.8 s (a deep stroke). The bird leaves at the bottom of the stroke. Arms
    hanging at the sides, folded or crossed are the **rest pose** and never launch.
  - **Off the ground:** the credited onset (1 stroke, or 2 within 1.2 s for big birds).
  - The round-2 **drop-launch** (tuck while perched) is removed: relaxing the arms on a
    branch threw the player off it. The tuck means "dive" only in flight.
- **STUNNED.** Inputs are ignored. The model gets a limp WingState (pitch 0, roll 0,
  spread 0.6, no flap). Duration is
  `clamp(0.6 + 0.8·(v_n − v_stun)/V_c, 0.6, 1.4)` s. The bird stays catchable
  (GameLoop decides).
- **respawn(xform).** Resets the model, filters, stun and the WingInput transient state
  (calibration is kept). Places the eye at `xform.origin` and sets rig yaw from `xform`
  (yaw only; the only allowed yaw step, and VR fades). Perches on the nearest fitting
  perch within 1 span. Emits `Events.player_spawned`.

### 10.3 Rig transform (every physics tick; the comfort contract)
```
ws = XROrigin3D.world_scale;  h = frame.head.origin (tracking, real metres)
Δh = h − h_prev   (zero on recenter / respawn / first tick)
model.displace(Basis(UP, R)·(Δh·ws))            # physical head motion moves the body; the sweep covers it
... model.step ...
PlayerBird.global_transform = Transform3D(Basis(UP, R), model.position)       # pure yaw, unit scale
XROrigin3D.position = −h·ws + UP·heave_offset                                  # camera lands on the body (+ heave)
```
- The camera's world position is `model.position + Basis(UP,R)·((h_render − h)·ws) + heave`.
  Head motion since the physics tick shows immediately, with zero latency. The next
  tick moves the body by the same amount, so nothing is counted twice.
- Rotating PlayerBird pivots about the eye: turning never swings the player sideways.
- While paused, PlayerBird doesn't tick, so the offset freezes and head motion moves
  the camera naturally. On unpause, the accumulated Δh is swept into the body, and the
  view doesn't jump (PB-13).
- **Growth:** VR ramps `world_scale` (§11.4). Because the offset is recomputed from the
  body every tick, scaling pivots about the head automatically.

### 10.4 Heading bookkeeping and body steer
```
R = rig yaw (PlayerBird.rotation.y);  θ_b = ws.body_yaw (torso);  ψ = model.heading()
e = wrap(R + D + θ_b − ψ)                      # + = the torso is left of the bird's heading; D = the turn still owed to the view (§19 V-1)
φ_bs = −sign(e)·min(1.2·max(0, |e| − 2°), 0.8·φ_max)      # body steer bank demand (dead-zone 2°, novice 5°)
roll_input = ws.roll                                          # kept for telemetry
ws.roll = clamp(roll_input + φ_bs/φ_max, −1, 1)              # PlayerBird overwrites the command before model.step
w_b = clamp(φ_bs/(ws.roll·φ_max), 0, 1) if same sign else 0  # the body-steered share of the turn
R += Δψ_model·(1 − w_b)                                       # tilt-driven turning rotates the rig; body-steered turning does not
                                                              # heading jumps (contacts) and anything faster than the caps: owed, D += …, paid by ViewTurn (§19 V-1, R4-1)
```
- **Tilt turns** rotate the world around the player. **Torso turns** don't, because
  the player already rotated.
- Mixed turns split proportionally. A player who tilts against their torso overrides
  body steer (w_b = 0).
- **Recenter** (`VR.recentered` / `Events.recenter_requested`): set Δh = 0 and
  `R = ψ − θ_b_new`, so the view faces the flight direction. Heading stays continuous.
- Setting `body_steer = false`: `R += Δψ_model`, and the torso offset is simply
  tolerated.

### 10.5 Controls disabled and tracking loss
With `set_controls_enabled(false)`, the WingState is neutral glide with `body_yaw` kept.
The bird glides level (auto-level, trim). Physical turning still never rotates the
view. Tracking loss is handled in WingInput (§5.12).

### 10.6 Perching (capture and assist)
- **Candidate:** the nearest free perch with `fits(span)` from
  `World.find_perches(pos, 8 spans, span)`, within ±50° of the velocity direction
  through the air or over the ground, then held until passed (§19 P-2).
- **Capture** (all must hold):
  - `|body − (perch.position + UP·r_body)| ≤ max(0.6 span, 2 r_body)`
  - landing speed `min(airspeed, |v|)` ≤ `V_cap = 0.8·V_min`, ×1.4 while either grip > 0.5 (§19 P-3)
  - descent speed ≤ V_cap, not coming from under the perch (body above perch − 0.5 span)
  - perch free; and if `perch_needs_grip` is set, grip held
- **On capture:** ease the body onto the perch over 0.15 s with no view rotation, set
  PERCHED, emit `player_perched(perch.position)` and fire the "perch ready" haptic.
- A perch that is too fast, occupied or too small is ordinary geometry: §12 applies.
- **Perch assist** (assist preset normal: within 4 spans + 0.5 s·V; novice: 8 spans).
  Active when the candidate is ahead (±50°) and V ≤ 1.6·V_cap. It fills FlightEnv:
  - `accel`: PD steering toward the perch's approach line, lateral and vertical,
    capped at 0.4 g (novice 0.6 g).
  - `alpha_bias`: auto-flare that brings V linearly to 0.9·V_cap at the perch, capped
    at +3° and at α ≤ α_s − 1°.
  - `drag_bonus`: "legs and tail down" landing configuration, up to +0.4 CD, released
    below 0.8·V_cap.
- Big birds use the balloon as a landing tool: approach low and fast, then flare.

### 10.7 Telemetry (`telemetry() -> Dictionary`; audio, HUD, haptics and UI read it every frame)
Contract keys (ARCHITECTURE §6):

| key | definition |
|---|---|
| `airspeed` | `|v − W|` |
| `groundspeed` | `|v.xz|` |
| `vertical_speed` | `v.y` |
| `altitude_agl` | `y − World.ground_height(x, z)` (or `env.ground_distance`) |
| `aoa` | α (rad) |
| `bank` | φ (rad, + = right wing down) |
| `stalled` | model stalled |
| `flapping` | `ws.flapping` (0..1) |
| `wing_extension` | mean ext (0..1) |
| `tucked` | `ws.tucked` |
| `perched` | mode ∈ {PERCHED, GROUNDED} |
| `in_updraft` | `max(0, W.y)` (m/s) |
| `g_load` | (lift + flap)·l̂ / (m g) |
| `lift` | L (N) |
| `drag` | D (N) |

Extras: `mode`, `heading`, `rig_yaw`, `body_yaw`, `yaw_rate` (heading rate), `rig_yaw_rate`,
`sideslip` (dψ), `pitch` (θ), `gamma`, `speed_ratio` (V/V_c), `stall_warning` (0..1),
`pitch_input`, `roll_input`, `flap_l`, `flap_r`, `up_l`, `up_r`, `extension_l`,
`extension_r`, `twist_l`, `twist_r`, `flap_force` (N), `flap_power` (W/kg), `endurance`
(0..1; 1 = uncapped), `soar_lock`, `tracking`, `calibrated`, `perch_candidate`
(distance or −1), `stun_left` (s), `world_scale`, `perceived_speed` (airspeed/ws),
`heave_offset`, `wind_l_y`, `wind_r_y` (wingtip lift, for the updraft haptic),
`size_x`, `species`.

### 10.8 Events emitted (facts only)
- `player_flapped(side, strength)`: at onset (§6.5).
- `player_stalled()`: on stall entry.
- `player_collided(impact, normal)`: slides with v_n ≥ 0.5 and stuns; wing brushes emit
  impact 0 with the ray normal.
- `player_perched(pos)`: perch and ground landings.
- `player_took_off()`.
- `player_spawned(self)`.

---

## 11. Comfort

### 11.1 Rules (numbered; each has a test)

1. **C1 Yaw only.** No code path writes pitch, roll or scale to PlayerBird or
   XROrigin3D. XROrigin3D's local basis is always IDENTITY. θ and φ exist only for
   visuals and telemetry (PB-01).
2. **C2 Never scale** XROrigin3D or its ancestors. Growth uses `world_scale` only
   (ARCHITECTURE §7.1) (PB-01, PB-18).
3. **C3 Yaw rate ≤ 240°/s and yaw acceleration ≤ 720°/s²** (Settings
   `comfort_max_yaw_rate`/`comfort_max_yaw_accel`). They are enforced *in the physics*
   as bank limits (§7.6), so the view always shows the true heading. The prototype
   never reaches them in normal flight: sparrow full input peaks at 203°/s and
   363°/s² (PB-02). `turn_comfort` (0.5–1.0) additionally lowers the player's φ_max so
   that `g·tan φ/V_c ≤ turn_comfort·Ω`. This is an accessibility option; the player
   then turns wider than NPCs.
4. **C4 Yaw is continuous**, except on flagged ticks: respawn, recenter, or the opt-in
   fixed-chair snap turn (`snap_turn`, 30°) (PB-02).
5. **C5 The camera is the body**, plus a bounded heave offset. Physical head motion is
   1:1 (PB-03, PB-04).
6. **C6 Pause:** the rig keeps processing and there is no camera jump on unpause
   (PB-13).
7. **C7 Perching, stall and tracking loss never rotate the view** (PB-10, PB-14). A stun
   deflects the velocity and turns the bird the short way toward leaving the wall, at
   most 40° (fix round 4, §19 R4-2; C8b); the view follows that small step inside half
   the rate cap and a third of the acceleration cap (ViewTurn, §19 R4-1); the player
   turns the rest. On a perch or the ground nothing is owed and a turning rig brakes to
   rest at the acceleration cap (C10).
8. **C8 Look never steers** (WI-04, PB-07). **Physical turning never rotates the
   camera** (PB-05).
9. **C9 Vignette** (VR-owned camera-attached mesh). Flight provides `rig_yaw_rate`,
   `airspeed`, `perceived_speed`, rig acceleration and `world_scale`. The VR panel's
   formula is: yaw term 35→150°/s, optic-flow term 2.5→9 rad/s with 3 ray distances,
   accel term 6→20 m/s² perceived, attack 0.08 s, release 0.5 s.

### 11.2 Why the yaw limits live in the physics
A rig-side limiter (aero's proposal) lets the view lag the bird, so the player's arms
point off the flight path during hard turns. Instead, the model limits bank so that
the coordinated turn itself stays inside the caps:
- the bank itself: `φ ≤ atan(Ψ̇_max·V/g)`;
- the bank rate: `φ̇ ≤ Ψ̈_max·V·cos²φ/g`, from differentiating `ψ̇ = g·tan φ/V`.

The camera yaw is then exactly the physics yaw. The caps are player-only; NPCs are
unaffected. In the prototype they never bind in normal flight (§8.3).

### 11.3 Heave smoothing (`HeaveSmoother`; setting `heave_smoothing`, default on)
> **Replaced in fix round 1** (§19 H-1): the formula below jumps the view at every
> burst; the implementation removes only the fitted wingbeat. **Gated in fix round 2**
> (§19 H-3): it acts only on a steady rhythm and never adds motion to the view.
Flapping at 1 Hz moves a small bird's body by a large fraction of its span, and
perceived bob scales with 1/world_scale. The camera's vertical position therefore
follows a **stroke-synchronous average** of the body:
```
T = ws.stroke_period (0.3..1.5 s; decays to 0.3 s when not flapping)
y_avg = mean(body.y over the last T);  vy_avg = mean(v.y over the last T)
y_cam = y_avg + vy_avg·T/2                       # removes the wingbeat and its harmonics; no lag on steady climbs
heave_offset = clamp(y_cam − body.y, ±0.5 span)
heave_offset = min(offset, safe) after a sphere cast (r = 0.04·ws) from the body to the camera point (layer 1)
```
This is a ring buffer of up to 1.5 s (≤ 135 samples at 90 Hz), with running sums.

Measured perceived bob, meaning camera ripple ÷ ws, as raw → smoothed (cm):

| | hover | flapping cruise | hard climb |
|---|---|---|---|
| sparrow | 82 → 22 | 85 → 36 | 73 → 28 |
| starling | 74 → 16 | 67 → 24 | 81 → 27 |
| pigeon | — | 49 → 15 | 75 → 36 |
| eagle | — | 11 → 3 | 16 → 7 |

This is comfort risk R1 (§17).

### 11.4 Growth and world_scale (VR-owned; flight's requirements)
- Default `ws_target = SizeRules.wingspan_for_mass(mass)/(cal.arm_span + 0.20)`.
  The feathered wingtips drawn 10 cm past each grip then match the bird's real span,
  which keeps "your wings next to theirs" as the eat-or-flee size cue.
- `ws` is animated in log space at ≤ 0.25 ln/s. Flight requires:
  - WingInput is invariant to `ws` (WI-07);
  - the camera stays on the body during a ramp (PB-18);
  - the camera near plane is 0.03·ws.
- A `world_scale_exponent` (default 1.0) is reserved for the Quest Pro playtest
  (§17 R1). Flight is invariant to it. **Fix round 4:** 1.0 is the VR area's comfort
  recommendation (VR.md §4), adopted as the default: the angular optic flow that drives
  vection is the same at any exponent, and a smaller exponent draws a small player's
  own wings up to 1.5× too wide next to NPCs, off by a tier exactly where eat-or-flee
  matters.

---

## 12. Collisions (PlayerBird)

- **Sweep.** Each tick, the motion `Δ = Δflight + Δhead` is swept with
  `PhysicsDirectSpaceState3D.cast_motion`, using a `SphereShape3D` of radius r_body
  against layer 1 (world) and layer 2 (perches, except inside the 0.4 s post-launch
  window).
  - On a hit, move to `safe_fraction` and take the normal from `get_rest_info`.
  - Allow up to 3 slide iterations.
  - Then depenetrate with `intersect_shape` plus push-out (1 mm tolerance).
  - Thin geometry (wires, twigs) is ≥ 1 cm radius cylinders or capsules. Jolt's
    `cast_motion` must be *verified* against them (PB-12 C1).
- **Classify** with `v_n = −v·n` and `v_stun = max(0.35 V_c, 2 m/s)`:
  - `v_n < 0.5`: silent slide.
  - `v_n < v_stun`, or glancing (incidence < 25°) with `v_n < 0.7 V_c`: **slide**.
    Remove v_n, keep 92% of the tangent, emit `player_collided(v_n, n)`.
  - `n.y > 0.7`, not perch geometry (layer 2), V ≤ `touchdown_speed`·V_min (1.2; round
    4: 0.7) and v_n ≤ `touchdown_vn`·V_min (1; round 5: V_cap): **land** (GROUNDED, with
    the run-out and the legs, §10.2; fix rounds 5–6, §19 R5-1, R5-2, R6-1). The rest of
    the tick's motion carries on along the ground. A bird at or below the touchdown
    speed meets a floor with its **feet** first (a sphere of r_body + `leg_reach`·r_body
    swept along the tick's motion, floors only, never perch geometry): that is the
    touchdown, and the body settles onto the ground along the normal. During a take-off
    hold a floor contact is a silent scramble (§10.2).
  - A **skid** (a slide contact on a floor, too fast to land) also bends the legs when
    the bend can spread it over two ticks or more (v_n·dt ≤ the flex): the speed into
    the ground goes to the camera's bend, not a one-tick stop (fix round 6). A harder
    skid stops the view with the body (never harder: G1c).
  - A silent contact with the ground (`n.y > 0.7`) is a skid: Coulomb friction takes
    μ·v_n (the normal impulse) from the speed along it (fix round 5, §19 R5-1).
  - A slide arms the 0.5 s capture lockout only when it was too fast to perch
    (landing speed > V_cap; fix round 5, §19 R5-6).
  - Otherwise: **stun**. `v = 0.3 v_t + 0.25 v_n n` (bounce; floors 0.05 v_n, §19 V-3),
    then STUNNED. Fix round 4 (§19 R4-2): the body turns the short way toward leaving
    a wall at 20° to its plane, at most `contact_turn_max_deg` (40°); a path the
    turned body does not face within the sideslip limit is turned to that limit if it
    leaves the wall, else removed (the bird drops).
  - A slide turns the body only as far as the sideslip limit needs (≤ 40°); the rest is
    sideslip and weathercocks smoothly. Every heading step is paid to the view
    (§19 R4-1).
  - Grazing: if the rest query at the cast's unsafe point finds nothing, it is repeated
    with a 2 mm margin; the normal is never guessed from the motion (§19 R4-3).
- **Wing brush.** Rays from the body to ±right·0.5·span·spread (layers 1+2). A hit at
  fraction f nudges the bank away by ≤ 10°/s·(1 − f) and emits a brush. Wings never
  stop the bird.
- **Camera safety.** Body sphere ≥ camera near sphere (0.04·ws), and the heave offset
  is cast (§11.3) (PB-09).

---

## 13. Desktop emulation (`DesktopPoseSource` → `HumanPoseModel` → the same WingInput)

The desktop source animates **virtual arms**. It never writes WingState.

| Input | Arm motion synthesised | Result through WingInput |
|---|---|---|
| Mouse (captured) | head yaw/pitch | free look only: a live demo that gaze never steers |
| W / S (hold) | both wrists LE down / up, ramping 120°/s to −30° / +40°, springing back τ 0.15 s | pitch −/+; flap tilt forward/back |
| A / D (hold) | airplane arms: opposite wrist twist ±25° plus arm tilt ±15° | roll left/right (both channels) |
| Space (hold/tap) | reference stroke ±45° at 1.0 Hz (a tap = one stroke) | symmetric flap; W+Space = flap forward |
| Mouse wheel | stroke amplitude 20°…60° | gentle ↔ hard flapping |
| Q / E | left-only / right-only stroke | one-wing flap: roll and yaw kick away |
| Left Shift | hands to the chest (elbows 150°) | tuck / dive |
| Left Ctrl | arms swept back 45° | partial fold (speed) |
| X | arms swept forward 30° | flare (sweep pitch-up) |
| [ / ] | torso yaw at ±90°/s (hand line rotates) | body steer demo |
| V (toggle) | relaxed glide pose (−45°, elbows 40°) | fatigue pose stays fully spread |
| F / G | left / right grip (both = soar lock; near a perch = cling) | grip, soar lock |
| Tab | arm gizmos + telemetry overlay | debug |
| Esc | menu | `Events.menu_requested` |
| F5 / PgUp / PgDn | reload FlightTuning / previous / next species mass | lab only |

Gamepad (same arm animator): left stick X = airplane-arms roll, left stick Y = wrist
pitch, RT = stroke amplitude (held = flapping), LT = tuck, LB/RB = one-wing strokes,
right stick = look.

---

## 14. Test plan

### 14.1 Harness
- **Layers.**
  - **L1** `FlightModel` (pure, WingState commands);
  - **L2** `WingInput` (HumanPoseModel → PoseFrame → WingState);
  - **L3** `PlayerBird` in a generated test world (`tests/unit/flight/flight_test_world.gd`:
    flat ground, walls, a window, cylinders from 1 cm to 1 m, perches of all kinds, a
    stub thermal);
  - **L4** bot course;
  - **L5** Meta XR Simulator.
- **Suites.** `tests/unit/flight/flight_model_test.gd` (FM), `envelope_test.gd` (FM-01,
  FM-27, FM-28), `wing_input_test.gd` (WI), `flap_detector_test.gd` (WI-12…WI-15,
  WI-27), `player_bird_test.gd` (PB-01…09, 13, 14, 16…18), `collision_test.gd`
  (PB-12), `perch_test.gd` (PB-10, PB-11), `bot_course_test.gd` (B1–B3),
  `desktop_test.gd` (DSK-01). Simulator: `tests/sim/flight_sim.gd` (SIM-01…04).
- **Speed.** L3/L4 set `auto_process = false`; a driver calls `player.tick(1/72.0)`
  N times inside one `_physics_process`. The world is static, so direct space queries
  are valid, and 60 s of flight runs in about 1 s.
- **Budgets.** L1 < 15 s, L2 < 8 s, L3 < 20 s, L4 < 15 s; the whole suite stays under
  60 s. Inputs are tick-indexed and RNGs are seeded. No test reads the wall clock.
- **Scenario library.** `tests/unit/flight/flight_scenarios.gd` defines named scenarios
  `{mass, start (trim | rest | pos,vel), schedule [(tick0, tick1, cmd)], env, assists}`.
  They drive the asserts, the golden comparison and the plots.
- **Golden values.** `tests/unit/flight/golden.json` holds Appendix B (value and
  tolerance per scenario and species). Each FM test asserts **both** the fixed
  requirement threshold (below) **and** the golden value within tolerance. A tuning
  change that moves a golden value fails with a clear message and must be re-blessed
  with `--bless`, which prints the diff. `metric()` records every thresholded number
  together with `FlightTuning.hash()`.
- **Species sets.** S3 = {sparrow, pigeon, eagle} by default. SP = sparrow…eagle (all
  player tiers). 72 Hz with the `normal` assist preset unless stated. "Trim" means
  `model.trim()` at the stated pitch, or 40 s of flying at that pitch before t = 0
  (never an untrimmed start).
- **Definitions.**
  - **Recovered:** within 5° of the trim γ, within 15% of the trim V, not stalled.
  - **Settled:** V within ±5% and γ within ±2° of the new trim.
  - **Altitude lost in a stall:** from the release to the minimum before recovery.
  - **Flap direction:** `last_forces().flap_impulse`, not a Δv against a twin.

### 14.2 Requirement → test matrix
| User requirement | Tests |
|---|---|
| Flapping the wings (controllers) produces lift | FM-12, FM-14, FM-17, WI-12, WI-13, B3 |
| Lift direction follows the wing angle: flat → vertical, pitched forward → up and forward | FM-11, FM-12, WI-12 |
| Speed via angle of attack like an airplane, with a temporary balloon | FM-03, FM-04, FM-02 |
| Too much AoA stalls; stalls are recoverable | FM-05, FM-06 |
| Turns via opposite tilts = coordinated aileron plus rudder | FM-07, FM-08, FM-09, FM-10, WI-08, WI-10 |
| Real-aerodynamics relationships (polar, energy trade, load factor) | FM-01, FM-02, FM-08, FM-16, FM-22 |
| Updrafts lift without flapping | FM-19, FM-20 |
| Growth changes flight (bigger = faster, wider, more momentum; small = nimble, can hover) | FM-26, FM-27, FM-14 |
| Match `SizeRules.performance` | FM-01, FM-02, FM-08, FM-13, FM-15, FM-27 |
| Camera never pitches or rolls; only yaw and translation | PB-01, PB-02, SIM-02 |
| Look around freely while flying | WI-04, PB-07 |
| Verifiable headless (scripted poses, plots, bot) | all L1–L4, §14.6 |
| Perching, collisions, stun not death | PB-10, PB-11, PB-12 |
| VR interactions (calibration, tracking loss, seated, soar lock, recenter) | WI-18…WI-24, PB-14, PB-16, PB-17 |

### 14.3 Test list (numbered; requirement thresholds and the prototype values they guard)

**L1: FlightModel** (S3 unless stated; "proto" = Appendix B)

| ID | Scenario | Acceptance (numeric) |
|---|---|---|
| FM-01 | Trim, all SP: 40 s neutral glide | V = `perf.cruise` ±3% (proto 0.993–0.998). Glide ratio within ±10% of the analytic `CL_n/(CD0 + k_i CL_n²)`. |
| FM-02 | Slowest steady flight, pitch 0.88 (protected), all SP | V ∈ [1.00, 1.15]·V_min (proto 1.08), not stalled. |
| FM-03 | **Balloon:** trim, pitch step 0 → +0.5, 3·T_ph + 5 s | Peak rise ≥ 5 spans (proto 6.5–8.2) and ≥ 0.4·(V0² − V_lo²)/2g (proto 0.58–0.77). Peak time ∈ [0.8, 4.0] s (proto 1.36–3.15). V(3 s) ≤ 0.70·V0 (proto 0.41–0.59). Final V = trim(0.5) ±5%. Settled ≤ 0.8·T_ph (proto 0.62–0.64). Never stalled. Transient V_lo ≥ 0.85·V_min (proto 0.89–0.97). **Temporary**: h(end) < h(peak). |
| FM-04 | **Nose-down:** pitch 0 → −0.5 | V(3 s) ≥ 1.07·V0 (proto 1.09–1.18). γ(1 s) ≤ −8° (proto −9.7…−14.2°). Final V = trim(−0.5) ±5% (≈ 1.41·V_c). |
| FM-05 | **Stall and recovery:** (a) trim at pitch 0.8, hold 1.0 for 2 s, release to 0; (b) from cruise, hold 1.0 for 3 s, release | (a) Stall within 1.0 s (proto 0.40–0.44). Exactly 1 `stall` event. Recovered ≤ 0.8·T_ph (proto 0.36–0.45). Loss ≤ 0.6·V_t²/g (proto 0.31–0.34). (b) ≤ 2 stall events (at most one per 1.5 s). Recovered ≤ 0.8·T_ph (proto 0.22–0.56). |
| FM-06 | **Protection:** (c) full-up pulses of 0.25 s every 0.5 s for 6 s; (d) pitch 0.85 held 6 s; (e) sim preset | (c), (d): 0 stalls. `stall_warning` at trimmed pitch 0.85 ≥ 0.30 (proto 0.49). At pitch 0.6: ≤ 0.05 (proto 0). (e) Sim preset: a steady trim at pitch 0.9 is stalled, and a pitch-1.0 step from cruise stalls within 0.5 s (proto 0.19–0.32). |
| FM-07 | **Roll response:** roll 0.6 step, all SP | Bank reaches 90% of 0.6·φ_max within t90 ±20% of 0.43 / 0.51 / 0.61 / 0.65 / 0.69 / 0.81 s (sparrow…eagle, golden), strictly increasing with mass. Overshoot ≤ 5% (proto 0). |
| FM-08 | **Coordinated turn:** roll 0.6 and 1.0 for 6 s | ψ̇ / (g tan φ / V) ∈ [0.97, 1.03] for t > 1.5 s at 0.6 (proto 0.999–1.000), and ∈ [0.95, 1.05] at 1.0 (proto 0.988–0.995). Model sideslip `|dψ|` ≤ 0.1° (proto 0). Sink at 0.6 ≤ 1.25× straight glide (proto 1.17). Full-input mean turn rate over 1–3 s with the bot's altitude-holding flapping: ∈ [0.85, 1.10]·`perf.turn_rate` (proto 0.87–1.01). |
| FM-09 | **Auto-level:** roll 0.6 for 3 s, then 0 | abs(φ) < 3° within 1.5·t90 (proto 1.12–1.16). abs(ψ̇) < 2°/s within 1.6·t90 (proto ≤ 1.35). |
| FM-10 | **Rudder:** roll 0.8 step with `k_rud = 0`, and with `k_rud = 1` | k_rud = 0: peak dψ ≥ +0.4° (nose left in a right roll: adverse; proto 0.64–0.77°). k_rud = 1: abs(dψ) ≤ 0.05° (proto 0). |
| FM-11 | **Flap direction, white box:** one reference stroke at trim; flap_dir tilted 0 / 17° / 35° forward / 20° back; repeated at φ = 30° | Impulse angle from banked-up toward the heading: 0 ±1°, 17 ±1°, 35 ±1°, −20 ±1° (proto exact). In the bank, the impulse lies in the banked plane within 1°. Upstroke impulse ≤ 35% of the downstroke for up_gain > 0, and opposes it for up_gain < 0 (measured from the applied impulse, FM-11b, §19 F-1). |
| FM-12 | **Flap direction, behaviour** (the natural wrist gesture: tilt from §5.8 with pitch = u): (a) from rest, hard strokes, 3 s: flat / full-forward (pitch −1, 35°) / full-back (pitch +1, −20°); (b) from trim at 40% effort: forward gesture (pitch −0.49, 17°) vs flat | (a) Flat strokes: sparrow rises ≥ 1.0 m in 3 s (proto +2.0 m); sparrow and starling horizontal drift ≤ 0.8 m/s (proto 0.17, 0.43). Full-forward: forward speed ≥ 5 m/s, all SP (proto 6.9–13.0). Full-back: moves backward, all SP (proto −2.3…−4.9 m/s). (b) v_h gain ≥ 0.15·V_c (proto 0.24–0.43), with abs(vz) ≤ 1.5 m/s ("flap forward = cruise"). |
| FM-13 | **Climb vs SizeRules:** reference stroke; grid pitch ∈ {0, 0.2, 0.4} × tilt 0…30°, 20 s settle + 10 s energy-height rate; plus a speed-held climb at V_c ±10%; all SP | Best climb ∈ [1.00, 1.25]·`perf.climb` (proto 1.09–1.13). Best-climb speed ∈ [0.3, 0.7]·V_c (proto 0.36–0.60). Climb at cruise ≥ 0.5·`perf.climb` (proto 0.56–0.94). `envelope()` climb values within ±10% of these. |
| FM-14 | **Hover capability:** hard flat strokes from rest, pitch 0.5, vz and horizontal drift over 2–7 s; reference stroke and frantic (60° at 2.2 Hz) | Sparrow vz ≥ +1.0 and starling ≥ +0.15, drift ≤ 1.0 m/s (proto +1.43 / +0.33 m/s, drift 0.39 / 0.72). Pigeon…eagle **never hold position**: never (vz ≥ 0 and drift < 1.5 m/s), for the reference and frantic strokes alike (proto reference: −0.87…−1.52 m/s while drifting 2.7–5.7 m/s; frantic: pigeon −0.91 at 1.2 m/s drift, crow −1.58, eagle −2.76). Frantic mean flap force ≤ 1.20× reference (endurance cap; proto ≤ 1.15×; the frantic sparrow climbs +2.14 vs +1.43 m/s). |
| FM-15 | **Tuck dive:** pitch −1 plus tuck from trim, 20 s; then release to neutral | V ≥ 0.95·V_max within 8 s (proto 3.3–6.7 s). V never > 1.03·V_max (proto ≤ 1.00). Recovered ≤ 1.5·T_ph (proto 0.77–1.21). |
| FM-16 | **Pull-out:** from the V_max dive, spread, pitch +0.5 | Peak g_load ≤ n_max + 0.2 (proto 3.3–4.4 ≤ n_max). Height lost ≤ 1.25·V_max²/((n_max − 1)g) (proto 0.96–1.04 of the ideal) and ≤ 75 spans (proto 54–69). |
| FM-17 | **Level flapping effort:** forward gesture from trim, effort scale swept 0.1…1.3 | The smallest scale holding altitude ≤ 0.45 (proto 0.30 sparrow…gull, 0.40 eagle). |
| FM-18 | **One-wing flap and fold:** one left reference stroke at cruise (tilt 10°); separately ext_r = 0.3 | Heading change to the **right** ≥ 3° within 1 s (proto 5.1–10.6). Peak bank ∈ [5°, 12°] (proto 7.5–8.6). abs(dψ) ≤ 1.5° (proto 0.66–1.11). Δv ∈ [0.35, 0.85]× a symmetric stroke (proto 0.59–0.63). Fold: rolls **right** (toward the folded wing) ≥ 10°. |
| FM-19 | **Updraft:** uniform W = (0, 3, 0), no flapping; (a) neutral straight, (b) pitch 0.6 circling at 30° bank | (a) Climb ≥ +1.0 m/s (proto 1.15–1.50). (b) Climb ≥ +1.7 m/s (proto 1.98–2.32). `in_updraft` = 3.00 ± 0.01. |
| FM-20 | **Thermal:** stub World bell `4·(1 − r²/44²)²` m/s (like the World's "meadow" thermal); circle at pitch 0.6, 30° bank, 60 s | Net climb ≥ +0.6 m/s, all SP (proto eagle 0.91, sparrow 3.24). |
| FM-21 | **Wind:** uniform 5 m/s headwind | Airspeed = V_c ±3%; groundspeed = airspeed − 5 ± 0.1. |
| FM-22 | **Integrator:** drag, flaps and governor off; random pitch/roll every 0.5 s for 60 s | abs(ΔE)/E ≤ 0.05% (proto ≤ 0.007%). |
| FM-23 | **Fuzz**, 300 s per size: random out-of-range WingStates (pitch/roll ±1.5, ext 0…1.2, flap −0.2…1.5, tilt ±2 rad), dt ∈ {1e-4, 1/90, 1/72, 1/30, 0.1}; with and without ±8 m/s wind steps | 0 NaN/inf. Without wind: airspeed ≤ 1.05·V_max (proto ≤ 0.94). Always: θ ∈ [−90°, 90°] and abs(φ) ≤ φ_max + 0.5°. |
| FM-24 | **Frame-rate independence:** 30 s tick-indexed schedule (glide, turn, balloon, reverse turn, flapping turn, tuck dive, flare) at 72/90/120 Hz vs 720 Hz, with and without flapping | Final position error ≤ 1.5% of path length (proto ≤ 1.20%). |
| FM-25 | Determinism | The same scenario twice gives a bit-identical CSV. |
| FM-26 | **Growth:** `set_mass` 0.03 → 0.06 mid-glide; then a ramp 0.03 → 4.5 over 60 s, then 2·T_ph | No NaN. abs(Δv) across the growth tick ≤ 0.2 m/s (proto 0.027: one tick of normal acceleration). After the ramp, trim V = V_c ±5% (proto 0.994). |
| FM-27 | **Size ordering** (derived and measured), SP | V_c, V_max, turn radius at 45°, T_ph, t90 and pull-out height strictly increase from sparrow to eagle. K_H ≥ 1 exactly for sparrow…starling. `turn_rate_cruise` = g tan φ_max/V_c = `perf.turn_rate` ±2% (clamps 55–78° not hit for SP). |
| FM-28 | **Performance** | 10 000 model steps at 72 Hz: mean ≤ 40 µs per step on this Mac (debug build), recorded with `metric("us_per_step")`. |
| FM-29 | **Telemetry and units** | In level flight, `lift` ≈ `g_load`·m·g ±1%. Every key is finite across FM-23. |

**L2: WingInput** (HumanPoseModel, default body: arm span 1.50, eye 1.62 m; seeded)

| ID | Scenario | Acceptance |
|---|---|---|
| WI-01 | Model neutral | Reproduces `a_local`, `c_local` (§3.2) within 1e-3. The default `N_i` reads twist 0. |
| WI-02 | Airplane glide, 2 s | ext ∈ [0.95, 1]. abs(pitch), abs(roll) < 0.02. flap ≡ 0. |
| WI-03 | Relaxed glide (−45°, elbows 40°) and arms at −60° | ext ≥ 0.95 (fatigue pose = full spread). |
| WI-04 | Head yaw ±80°, pitch ±60°, roll ±20°, arms spread | Every WingState field changes < 0.01; body_yaw < 1°. |
| WI-05 | Whole body rotated ψ ∈ {0, 90, 180, −135}° | Identical except body_yaw = ψ ± 1°. |
| WI-06 | Room offset (1.2, 0, −0.8) m | Identical. |
| WI-07 | world_scale: the same poses through the XR node path at ws 0.141 and 1.235; a ramp 0.16 → 0.44 in 1 s while standing still | Identical ±1e-6. flap ≡ 0 during the ramp. |
| WI-08 | Twist: both +20°; both −20°; L +20°/R −20° | pitch ∈ [0.25, 0.37] with abs(roll) < 0.02; pitch ∈ [−0.55, −0.43]; roll ∈ [0.62, 0.78] (right bank) with abs(pitch) < 0.02. |
| WI-09 | Swings: dihedral ±40°, −60°; sweep ±30°; elbows 60° | abs(u_i) < 0.05 (swing-twist rejects them). |
| WI-10 | Dihedral: right hand 30° lower | roll ∈ [0.3, 0.5] (right bank); pitch unchanged ±0.02. |
| WI-11 | Grip-convention robustness: every controller basis post-multiplied by 3 seeded random rotations ≤ 40°, then recalibrated | Whole gesture library within 0.02 of the reference. |
| WI-12 | Flap normal: canonical flap flat / LE-down 20° / 30° / LE-up 40° | Within 3° of up; tilted forward 14–20° and 32–36°; tilted back 17–21°. |
| WI-13 | `p_ref`: reference stroke through WingInput, for sparrow, starling, pigeon, eagle | Mean net effort = `FlapDetector.reference_effort(x)` ±5%. |
| WI-14 | **Rejection set:** still + 0.7 mm noise; tremor 1 cm @ 10 Hz; wrist shake 3 cm @ 8 and 12 Hz; frantic 6 cm @ 5 Hz; 8 cm @ 4 Hz. Then L1+L2: 10 s glide with shakes | ∫flap² ≤ 1% of canonical (the 8 cm case ≤ 5%). Zero onsets. Altitude vs the no-input baseline: abs(Δh) ≤ 0.05 m. |
| WI-15 | **Accepted strokes:** slow recovery 1.2 s + fast power 0.3 s (90°); quick ±15° @ 2 Hz for sparrow and eagle | Slow-recovery stroke ≥ 50% of canonical. Quick stroke: sparrow ≥ 0.55× reference effort (detector design 0.65), eagle ≤ 0.45× (design 0.38). |
| WI-16 | Crouch 0.4 m in 0.3 s; a jump; walking at 1 m/s | flap ≡ 0. |
| WI-17 | One-wing flap, 1 Hz ±45° | Only that wing's flap > 0. abs(roll from dihedral) < 0.1 (cycle-mean). |
| WI-18 | Tracking loss: right hand lost 0.2 s / 2 s; both lost; reacquire | Unchanged; mirrored within 0.6 s; neutral within 1 s with tracking = 0; no jump on reacquire (Δroll ≤ 0.1 per tick). |
| WI-19 | Crossed arms; hands at the chest before and after `has_spread` | body_yaw holds within 10°. ext ≥ 0.85 before, ≈ 0 after. |
| WI-20 | Latency steps (§5.13) | Each channel within its target. |
| WI-21 | Physical 180° turn in 2 s, spread; the same while tucked, then spread | Lag ≤ 8°; converges ≤ 0.5 s after the spread; no flip. |
| WI-22 | Calibration: spans 1.30 / 1.50 / 1.90 m, seated and standing, neutral twist offsets −25…+25° | WI-02, WI-08 and WI-09 pass for every body. |
| WI-23 | Auto-trim | A 5° offset held for 120 s is ≥ 80% absorbed; a 20° deliberate input is untouched. |
| WI-24 | Soar lock | Arms dropped to −85° with both grips: ext ≥ the lock value; twist still reads. |
| WI-25 | Determinism | Identical state hash over 3 runs. |
| WI-26 | **Round trip:** `WingState.set_commands` → PoseSynth (HumanPoseModel) → WingInput, grid pitch/roll ∈ {−1, −.5, 0, .5, 1} × spread ∈ {0, .5, 1} | pitch, roll and spread ±0.03. flap_dir ±2°. Mirror symmetry exact (a mirrored pose gives −roll and swaps L/R). |
| WI-27 | Events: reference flap for 10 s | Exactly one onset per wing per stroke, and one `player_flapped(0, credit)` per stroke. |

**L3: PlayerBird** († = scene-level design targets, confirmed in the port)

| ID | Scenario | Acceptance |
|---|---|---|
| PB-01 | Every tick of every L3/L4 scenario, plus fuzz, stun, perch and respawn | PlayerBird and XROrigin3D: `global_basis.y·UP ≥ 1 − 1e-6` and `abs(det − 1) ≤ 1e-5`. XROrigin3D local basis = IDENTITY. |
| PB-02 | Yaw smoothness, all L3/L4 scenarios | abs(rig yaw rate) ≤ 240°/s and abs(rig yaw accel) ≤ 756°/s² (720 +5%), except on flagged ticks. |
| PB-03 | Camera = body: after yaw, lean and world_scale changes | `XRCamera3D.global_position` = `model.position` + (0, heave, 0) ±1 mm. |
| PB-04 | Head motion: a scripted 0.3 m real head move at ws; the same into a wall | The camera moves 0.3·ws, and so does the body (swept). Against the wall, the camera stays ≥ r_body from it. |
| PB-05 | **Body steer:** torso turns 90° right (poses), no tilt | Heading within ±5° of the torso within 1.25·90°/Ω(0.8 φ_max) + 2 s (proto sparrow 1.9 s, eagle 5.0 s). Rig yaw changes ≤ 2°. With body_steer off, heading changes ≤ 2°. |
| PB-06 | Tilt turn: roll 0.6 for 3 s | Rig yaw change = model heading change ±2°. |
| PB-07 | Look: head yaw ±90°, pitch ±45°, roll ±20° with fixed arms | Commands change ≤ 0.01; heading ≤ 0.5°. |
| PB-08 | **Flap bob** (K3), camera ripple ÷ ws after a 1-period detrend | Hover (sparrow, starling) ≤ 30 cm. Flapping cruise ≤ 45 cm (sparrow, starling), ≤ 20 cm (pigeon), ≤ 12 cm (crow and up). Hard climb ≤ 40 cm (sparrow…pigeon), ≤ 20 cm (crow and up). Proto values in §11.3. |
| PB-09 | Camera never clips (K4) | The camera near sphere never intersects layer 1 in any scenario, including a ceiling 0.3 span above a hovering body. |
| PB-10 † | **Perching** P1–P8 | P1: aligned approach at 0.9·V_cap → PERCHED within 1 s, within 0.1 span of the target, `player_perched` once, occupant set. P2: 1.5·V_cap without grip → not perched. P3: 1.2·V_cap with grip → perched. P4: `max_span < span` → never. P5: a completed flap (reference and deep stroke) → FLYING within 0.1 s of the downstroke's end (deep: of the recovery), V ≥ 0.5·V_min at 0.5 s, no re-perch for 0.4 s, `player_took_off` once. P6 (fix round 4, replaces the tuck-drop): arms relaxed at the sides for 60 s, 20 s of fidgeting (with credited downstrokes that end folded) → still PERCHED at three sizes, no tuck in telemetry; then a flap from the rest pose launches on its first stroke. P6b: relaxed postures (upper arm −60…−90°, elbows 0–90°) never drop the bird. P7: 20 seeded approaches (offset ±1 span, speed 0.9–1.3·V_cap) → assist on ≥ 90% perched, off ≤ 60%. P8: occupied → no capture. Round 3 (§19 P-2, P-3): P10 slow glide-ins in 2.1 m/s head / cross winds keep ≥ 80% of the still-air success and in a 2.1 m/s tailwind ≥ 70%; P11 tailwind glide-ins from a span above the glide path, pigeon and eagle ≥ 7 of 9. |
| PB-11 † | Ground | A shallow landing at ≤ 0.7·V_min on flat ground → GROUNDED. Takeoff: sparrow with 1 credited stroke; pigeon and up with 2 strokes within 1.2 s. |
| PB-12 † | **Collisions** C1–C7 | C1: 1000 random shots (2 m/s…1.2·V_max) at 1 cm-radius, 3 m cylinders: analytic hits = actual stops (0 tunnels, 0 false hits beyond 1 mm). C2: 15° glancing at V_c → no stun, speed ≥ 85% kept. C3: head-on at V_c → STUNNED 0.6–1.4 s, bounce v·n > 0, inputs ignored, then FLYING. C5: a slot 1.2 body diameters wide → escape within 2 s of flapping, ≤ 3 contacts/s after 1 s. C7: a 2×1.5-span window flown centred → 0 collisions (brushes allowed). Round 3 (§19 V-1…V-3): C8b oblique walls 30–90° at three sizes (one stun in 8 s, view within 10° of the heading 1 s after it, forced turn = incidence + 20° inside 120°/s and 240°/s², no overshoot) and C9 (a V_max dive into the ground stuns once). |
| PB-13 | **State and API** S1–S6 | S1: `set_controls_enabled(false)` → wings level within 2·t90, flaps ignored. S2: pause 1 s → model unchanged; a 0.3 m head move during the pause moves the camera 0.3·ws; no jump on unpause (≤ 1 mm). S3: `respawn(xf)` → eye at xf ±1 mm, yaw = xf yaw, PERCHED if a fitting perch is within 1 span (else SPAWNING 0.5 s), `player_spawned` once. S4: every contract key present and finite. S5: each event exactly once per occurrence. S6: the mass setter reconfigures within the same tick. |
| PB-14 | Tracking-loss glide: right hand lost 3 s mid-turn | No NaN. abs(φ) < 5° within 1.5 s after the loss decays. No flap events. |
| PB-15 † | Ground cushion: a 3° descending glide over flat ground | Cushion on: skims ≥ 40 spans before contact. Off: contact within 5 spans of the geometric intercept. A 40° dive still contacts and stuns. |
| PB-16 † | Seated: flag set, strokes of ±0.25 m hand travel at 1.3 Hz | Mean effort ≥ 0.85× the standing reference (the game panel measured 0.93–0.96 with its detector; confirm with §6.3). |
| PB-17 | Recenter mid-flight | Heading continuous (≤ 0.1°). Rig yaw = heading − body_yaw ±1°. |
| PB-18 | Growth mid-flight through the mass setter, with VR's ws ramp | The camera stays on the body ±1 mm; the head's world path is continuous (≤ v·dt + 1 mm); FlightParams re-derive in the same tick. |
| DSK-01 | Desktop: `Input.parse_input_event`, headless | Hold W 0.5 s → pitch ≤ −0.8. S → ≥ +0.8. A → roll ≤ −0.8. A Space tap → exactly one onset, peak flap ≥ 0.8. Q → flap_l > 0, flap_r = 0. Shift → tucked. Mouse look → commands unchanged. |

### 14.4 Bot pilot (L4) and the course
**Architecture.** `BotPoseSource = FlightAutopilot + HumanPoseModel`. The bot sees only
the bird's kinematic state and the read-only `FlightParams`, which is what a player
sees. It moves **arms**, never WingState, so calibration, the body frame, shaping, the
flap detector and the physics are all exercised.

Human limits: arm angular speed ≤ 8 rad/s, twist rate ≤ 360°/s, reaction delay
120 ms, tremor 1.5 mm at 9 Hz, twist noise 1.5°.

Control laws (these gains passed in the prototype; the port keeps a gain-sweep dev
test and re-picks them whenever tuning moves):
- **Lateral (L1 guidance).** `L1 = max(2.5 spans, 0.9 V_c)`. The target point is on the
  leg at L1 ahead; `a_lat = 2V²/L1·sin η`; `roll = atan(a_lat/g)/φ_max`.
- **Speed on pitch.** `pitch = pitch_trim(V_tgt) + 2.0·(V − V_tgt)/V_tgt + I_v`, with
  `I_v += 0.3·(V − V_tgt)/V_tgt·dt` clamped ±0.3. `pitch_trim` inverts the §7.4 map for
  level 1-g flight.
- **Altitude on flap effort (PI).** `vz_cmd = clamp(Δh/(0.6·T_ph), −2, perf.climb)`,
  `flap = clamp(0.35 + 0.25·(vz_cmd − vz) + I, 0, 1)`, with
  `I += 0.05·(vz_cmd − vz)·dt` clamped [−0.4, 0.6]. Effort is held per stroke.
- **Size-aware strokes.** `hz = lerp(2.0, 1.0, xn)`, amplitude `lerp(25°, 45°, xn)`.
  The flap tilt is whatever the wrist pitch makes (§5.8): no cheating.
- **Gap technique** *(port, 2026-09-26; see §19 B-1)*. A fixed **glideslope through
  the gap centre**, `y = gap.y + along·tan(−γ_gs)`, flown without flapping for
  `T = 5 s + 1 s` (the extra second: no stroke may carry into the glide), with
  `along` measured along the path (on a sparrow's course the glide begins in the
  turn). Entry height `h = max(d/LD − 0.44·V_c²/2g, 0.5 m)` over `d = V_c·T`: the
  bird arrives having shed at most a quarter of its speed (big birds glide in almost
  level, small birds from a few metres up, both within their climb). The loop is a
  **path-angle loop through the inverted pitch map** (`pitch_for_load(V, n)`,
  `n = cos γ + V/g·ω·(γ_cmd − γ)`, plus an anti-windup integral), with
  `γ_cmd = γ_gs − clamp(e_y/(τ V) + k_i∫e_y, ±6°)`; ω = 3.5 → 2.0 rad/s and
  τ = 0.9 → 1.5 s from sparrow to eagle. The spec's `pitch_trim + 4.0·(γ_cmd − γ)`
  aimed at the gap oscillated with the 120 ms delay and missed by up to 1 m.
- **Landing** *(port; §19 B-2)*. After the gap: a straight descent that slows toward
  1.3·V_min, 360° descending orbits whenever the total energy exceeds what the rest
  of the approach can shed by gliding, then a final line to the grip point flown with
  the same path-angle loop plus an **air brake** (extra wrist pitch while above the
  capture speed: induced drag bleeds the energy a short final cannot glide away),
  grip held, pitch 0.75 in the last 1.5 spans, perch assist on. The TECS split was
  tried and dropped: stroke-by-stroke flap impulses swing the path by 20–30°, and
  the energy-rate and balance errors it feeds on are dominated by that ripple.

**Course** (`FlightCourse`, scaled by size; also the flight lab
`scenes/dev/flight_dev.tscn`, which adds ring gates, poles and wires, a tree
perch and a thermal column):
1. Start 20 m AGL at trimmed V_c, heading −Z.
2. Climb to 35 m along leg 1 of length `L = max(120 m, 14 V_c)`.
3. A 180° right turn at ≈ 0.6·φ_max onto a return leg offset 2.6·R, where
   `R = V_c²/(g tan(0.6 φ_max))`.
4. A **window** at 0.35·L along the return leg: an opening **2 spans wide × 1.5 spans
   tall** in a 0.5-span-thick wall (layer 1).
5. A **branch perch** 60 spans after the window and 6 spans below the cruise line
   (`max_span = 1.5 × span`).

| ID | Scenario | Pass criteria |
|---|---|---|
| B1 | The course above, for sparrow, pigeon and eagle (and starling, crow, gull in the full run) | **Window** crossed with abs(lateral) ≤ 1 span − r_body and abs(vertical) ≤ 0.75 span − r_body, and the worst axis ≤ 60% of that tolerance (**prototype worst 27%**: sparrow 7%, starling 1%, pigeon 7%, crow 27%, gull 18%, eagle 8%). 0 stuns, 0 frame collisions (brushes allowed and counted). † **PERCHED** on the target within `1.6·L_total/V_c + 10 s`. Rig PB-01/PB-02 hold throughout. PNG and CSV written. |
| B2 † | **Novice bot:** seeded human noise (150 ms delay, twist tremor ±4° at 8 Hz, 20% roll over-rotation, stroke amplitude ±30%, 10% one-sided strokes), 10 seeds × S3 with assists normal and sim | Window + turn completion ≥ 80% (normal), and completion(normal) > completion(sim). Proves the assists remove frustration. |
| B3 | **First-flight smoke:** a flap-only sparrow (flat hard strokes, no tilts) from the spawn perch | Airborne ≥ 60 s; never stunned (proto: hover-climbs at +1.4 m/s). |

**Honest status of B1's perch leg.** The prototype confirms that the capture speeds are
physically reachable: in an earlier prototype iteration, sparrow and starling bots
perched at 2.97 and 4.15 m/s within 0.2 m, using a plain speed ramp and altitude hold. It did **not** converge an energy manager that lands pigeon-to-eagle bots
within 0.6 span. Their final approaches arrived 2–9 m high, because slowing by pitch
converts speed to height, and flapping can only add energy. The port's first
gain-sweep target is the TECS landing above. If it cannot meet B1, the fallback is
the **novice** perch assist (8 spans, 0.6 g) and/or a 1.2·V_min grip capture. That is
a tuning change, not a design change, and it must be recorded in `docs/areas/FLIGHT.md`.

### 14.5 Meta XR Simulator checks (L5; `tools/xr.sh`, one session machine-wide)
| ID | Run | Acceptance (from the log and the mirror PNGs) |
|---|---|---|
| SIM-01 | **Axes probe:** read `aim`/`grip` poses of the fixed simulated controllers | Within 5°: grip = aim·Rx(60°), `default` = aim, node origins scale with world_scale while raw tracker poses do not. On failure, re-derive the §3.2 defaults. |
| SIM-02 | `scenes/dev/flight_dev.tscn -- --pose=script:course --species=sparrow` (HybridPoseSource: XR head, the bot's arms), 40 s, `--labshot=5,15,25` (the lab's own head mirror) | Session FOCUSED. `[flight]` lines show bank > 30° while the XRCamera3D global basis has zero roll and pitch beyond the head's own. Mode sequence FLYING → … → (PERCHED). fps ≥ 70. No SCRIPT ERROR. Screenshots: horizon line fit abs(slope) ≤ 0.5° during the banked turn; scripted wings visible (non-sky pixels in the lower-left and lower-right thirds). |
| SIM-03 | `--xrdiag` for 60 s with growth sparrow → pigeon mid-flight | 90 Hz physics. WingInput ≤ 0.3 ms per tick. Camera stays at `model.position` during the ws ramp (log ±1 mm). |
| SIM-04 | XRPoseSource with the fixed controllers | Twist reads within ±5° of the value predicted from the probe basis (flags a convention change before the Quest session). |

### 14.6 Plots and visual evidence (`FlightPlot`, headless `Image` rendering)
- **Format.** 1600×900 PNGs with four panels: top view (course geometry, thermals as
  circles); side view (along-track vs altitude, with the window); V and altitude vs t
  (V_c line); and α, θ, φ, flap L/R, pitch/roll commands with event ticks.
  Polylines are drawn with Bresenham, 2 px, labelled with an embedded 5×7 bitmap font.
- **Output.** `artifacts/flight/<test>_<species>.png`, plus a CSV per scenario, plus
  `artifacts/flight/overview.png` (a contact sheet).
- **Required plots:**
  - FM-03 balloon and FM-04 sag altitude and V vs t;
  - FM-05 stall;
  - FM-08 bank and ψ̇ with the `g tan φ/V` overlay;
  - top-down turn circles for all SP on one plot (radius grows with size);
  - glide polars (sink vs V) for all SP;
  - FM-11 flap-impulse arrows (flat, 17°, 35°, −20°);
  - FM-14 hover vz vs mass;
  - FM-19/FM-20 thermal spirals;
  - B1 tracks for every size;
  - WingInput channel plots per gesture;
  - `scenes/dev/flight_vr_dev.tscn` gesture screenshots (skeleton, estimated
    shoulders and body frame, wing planes and normals, WingState read-out).
- **Review.** Each plot is reviewed by eye and listed in `docs/areas/FLIGHT.md`.

### 14.7 Performance
- **PERF-01.** Player tick (pose + WingInput + model + one sweep + rig) ≤ 0.35 ms mean
  on the dev Mac (debug), recorded in FM-28 and PB tests. Quest budget: ≤ 1 ms.
- **PERF-02.** `FlightModel` in `lite` mode (1 Heun step per tick at the NPC rate, no
  substeps) for ≤ 8 hero NPCs: ≤ 25 µs per step. `envelope(mass)` matches `NpcFlight`'s
  measured envelope within ±15% on cruise, min_speed, max_speed and turn_rate (a joint
  test with AI; §16 A1).

---

## 15. Contract changes (to record under ARCHITECTURE "Contract changes")

1. **flight → WingCalibration** (flight-owned): the fields of §5.11 replace
   `neutral_roll_*` and `neutral_pitch_*`. `arm_span` is now grip-to-grip, default
   1.50 m.
2. **Settings keys** (`DEFAULTS`):

   | Key | Default | Notes |
   |---|---|---|
   | `wing_calibration` | {} | serialised WingCalibration |
   | `flight_assist` | 1 | 0 sim / 1 normal / 2 novice |
   | `soar_lock` | true | |
   | `auto_trim` | true | |
   | `wrist_sensitivity` | 1.0 | |
   | `sweep_pitch` | true | |
   | `invert_pitch` | false | |
   | `body_steer` | true | |
   | `perch_needs_grip` | false | |
   | `heave_smoothing` | true | |
   | `comfort_max_yaw_rate` | 240 | °/s |
   | `comfort_max_yaw_accel` | 720 | °/s² |
   | `turn_comfort` | 1.0 | |
   | `record_poses` | false | |

   `arm_span` (the existing key) is deprecated: it mirrors
   `wing_calibration.arm_span`, read-only. `seated`, `snap_turn` (now the fixed-chair
   30° option), `haptics` and `comfort_vignette` are unchanged.
3. **Player scene:** `LeftHand`/`RightHand` use `pose = &"grip"`, and new
   `LeftAim`/`RightAim` nodes (aim pose) are the UI laser source. The UI and VR areas
   read the aim nodes.
4. **`Bird.get_forward()` for the player** returns the beak heading with body pitch
   (`model.forward()`), not the gaze and not the rig. `get_body_position()` is
   `global_position` (the eye/body).
5. **Telemetry:** the §10.7 extras are added (the contract keys are unchanged).
6. **No new Events signals.** A distinct ground landing is `player_perched` with the
   ground position. If UI needs to distinguish them, add
   `player_landed(pos, on_perch)` later.

---

## 16. Cross-area flags (for the owners; flight will not edit their files)

- **A1 (AI): climb semantics and fairness.**
  - `NpcFlight` sizes muscle power so that NPCs climb at `perf.climb` **at cruise
    speed**. Physically, the player's FlightModel reaches `perf.climb` at its best-climb
    speed, 0.36–0.60·V_c, and at cruise reaches 0.56 (eagle) to 0.94 (sparrow) of it
    (FM-13).
  - So big NPCs out-climb big players at cruise by up to about 1.8×.
  - Recommended: `NpcFlight` computes `p_max = g·climb + drag(v_climb_best)·v_climb_best`
    from `FlightModel.envelope()`. Joint test PERF-02.
- **A2 (AI): budget.** Full FlightModel for ≤ 8 NPCs within 30 m ("hero" chases,
  identical physics); `NpcFlight` for the rest.
- **W1 (World): thermals and wind.** `get_wind` must be C¹-smooth; the existing bell
  profile is. The eagle nets only +0.9 m/s circling a 44 m, 4 m/s bell at 30° bank
  (R ≈ 24 m). Keep ≥ 3 thermals at R ≥ 40 m and core ≥ 4 m/s for big birds. Ridge
  lift should reach ≥ 2 m/s within a 1-span band of cliff and building faces, so that
  small birds can use it. Keep the ceiling fade (`lift_scale`) over ≥ 20 m.
- **V1 (VR): perceived speed and bob.** With exact scale, a sparrow's cruise is
  perceived as 64 m/s and its flap bob as 22–36 cm (smoothed). Decide
  `world_scale_exponent` in the first Quest Pro session (§17 R1). Also: haptics per
  VR §13 from `WingState` flags and telemetry, and the vignette inputs listed in C9.
- **G1 (gameloop): turn_rate.** `SizeRules.turn_rate` (sparrow 220°/s) is met
  (FM-08: 0.87–1.01 with flapping) and stays under the 240°/s comfort cap. If
  playtests find small-bird turning too intense, lower `turn_rate` for *everyone*
  (NPC fairness) rather than capping only the player.
- **U1 (UI): onboarding.** The lesson thresholds read `wing_extension`, `flapping`,
  `airspeed`, `vertical_speed`, `bank`, `tucked`, `perched` and `player_flapped`
  strength ≥ 0.25. All of these are preserved. The "Tilt for speed" lesson should say
  *"roll both wrists forward"*; the physics also tilts the flaps forward, so the same
  gesture flaps forward.

---

## 17. Risks and open items for the Quest Pro session

- **R1 Small-bird comfort** (the biggest risk).
  - Exact world scale makes a sparrow's world 7× magnified: perceived cruise is
    64 m/s, and smoothed flap bob is 22–36 cm.
  - Mitigation ladder, in order:
    1. heave smoother (on);
    2. flow/accel vignette (VR);
    3. `flap_tau` +50% for x < 0.45;
    4. small-bird `up_gain` +0.55 (an earlier prototype iteration: hover bob 82 → 45 cm raw);
    5. `world_scale_exponent` 0.8.
  - Acceptance: three testers fly 5 minutes as a sparrow with no reported discomfort.
- **R2 Controller convention on real Touch Pro.** The measured grip convention is from
  the simulator. Run SIM-01's probe on the device first; the calibration makes it
  moot for play.
- **R3 Arm fatigue.** Level flight needs 30–40% effort, and gliding, thermals and soar
  lock are the efficient ways to travel. Measure the flapping duty of the "lazy" bot
  profile, and then of real players, over 5 minutes (target ≤ 25%).
- **R4 Big-bird landing skill** (B1 perch leg). See §14.4. The perch assist may need
  the novice values by default for pigeon and up.
- **R5 Detector constants** (credit arcs, ω_full) were tuned on synthetic strokes.
  Record 5 × 3 min Quest sessions (novice, expert, seated, lazy, abuse) with
  `PoseRecorder` into `tests/fixtures/poses/`. Replay tests then assert that onset
  counts are stable within ±10%, that abuse segments produce zero onsets, and that
  body_yaw never jumps more than 30° per tick.
- **R6 Roll mode A/B.** ANGLE command (default) versus a rate-like response for the
  twist channel at the `sim` preset.

---

## 18. Rejected alternatives (tried by a panelist or the chief designer's prototype; do not retry)

| Idea | What happened |
|---|---|
| Blade-element per-wing model as the runtime (aero) | Physically superior, but 3–4 substeps × 2–8 wing evaluations, about 30 states, and it turns raw stroke velocity into force (shaking lifts). Kept as the reference. |
| Aero default chord axis `(0,1,0)` in grip space | Points up-back under the measured convention: inverted pitch. |
| Skid turn from torso yaw (aero, VR) | Up to 90° sideslip, lift loss, and not coordinated (requirement 3). Replaced by body steer as a bank demand. |
| Flap-hold of the pitch command during strokes (game) | With the lift-linear down map it is unnecessary. Holding made "flap forward" climb instead of go forward, and split one gesture into two meanings. |
| θ-lag attitude without path feed-forward (game) | At V_max, α collapsed to about 0.4°: the pull-out reached 1.4–1.8 g and lost 290 spans. |
| Heave decoupling (L8) with a 0.35 s high-pass, for attitude and/or forces | Treats every change of flap effort as ripple, which biases α and zooms the bird 1–3 m after each burst. On forces, it also removes the real heave damping. |
| Stall protection on the α *command* only | The actual α overshoots while the path curves down after a balloon, so pitch 0.85 stalled. |
| Posture cap from horizontal airspeed only | Pushed fast vertical zoom climbs over into negative g. |
| Posture cap from instantaneous airspeed | Flipped between 20° and 80° every wingbeat near V_min, giving ±20° α oscillation. |
| Power cap on the heave-corrected flow | Weakened the cap: climb 1.32× target, bob ×2. |
| Power cap only (no endurance cap) | Hovering costs no F·v power, so frantic flapping let a pigeon hover-climb at +3.4 m/s. |
| Endurance cap on a 0.7–1.5 s low-pass | Ripple on a 1 Hz stroke clipped the reference stroke itself, and a slow window let bursts climb for seconds. Replaced by a stroke-synchronous full-window mean with a smoothstep hover-to-forward blend. |
| Heading from the instantaneous horizontal velocity | Random heading after a vertical climb: 48% path divergence between frame rates. |
| Game α map, nose-down side linear in α | Quarter-down gave 1.55·V_c and half-down zero lift, which is twitchy. |
| Unscaled phugoid damper | Cancelled pull-outs (as aero found). |
| Perch capture at 0.6·V_min (game) | AoA alone decelerates only about 0.25 g, so the capture needs a hover-brake or zoom within 4 spans. |
| Bot altitude hold by flap PI through a gap | Wingbeat ripple dominates the crossing (worst 1.4–6.9 × tolerance). Replaced by the final-glide technique (worst 0.27). |
| Everything in aero §16 | Still valid for the blade-element reference. |

---

## 19. Port notes (2026-09-26): where the implementation departs, and why

Each item: what changed, the reason, the test that pins it. Numbers are measured by the
suite (`tools/gd.sh flight --headless res://tests/runner.tscn -- --suite=flight/`).

**Physics (§7, Appendix A)**
- **M-1 Integrator.** Heun (RK2) with symmetric splitting (stage 1 sees the attitude and
  flap state at the start of the substep, stage 2 at its end) at `substep_hz = 144`
  (`h = dt/ceil(dt·144)`, so h ≤ 1/120 at 72 and 90 Hz), and exact first-order lags
  `k = 1 − e^(−h/τ)`. Explicit Euler with `h/τ` factors made the attitude lead by h/2
  per transient and failed FM-24 (frame-rate independence). dV/dt for the phugoid
  damper comes from the integrator's own tangential acceleration (no finite
  difference). FM-22, FM-24.
- **M-2 Heading follow band** (§7.3 step 1): held below 0.25 V_min, full from 0.6 V_min
  (spec 0.1–0.4). With the spec's band a hovering bird's heading chased its
  0.5 m/s bob drift (160° in 2 s, 375°/s peaks: the rig would spin). FM-14, PB-02.
- **M-3 Hover lift fade.** In a powered hover the glide polar's lift at the ±60°
  incidences of the wingbeat is faded out with the hover blend (the wing's force is
  the flap force, K_H); counting it twice pushed the bird around. FM-14.
- **M-4 Stall gate.** The stall FSM and the protection clamp need V ≥ 0.5 V_min (AoA is
  meaningless when hovering or launching; a hovering bird saw α ≈ 90° and wing-dropped).
- **M-5 Post-stall plateau** clamped on both sides (`cl_min` floor): the spec's
  `min(a α, 0.6 CL_max)` left negative α unbounded (CL −2 at −25°). FM-05.
- **M-6 Ground effect** (G15): cushion measured at the **belly** (centre − r_body) as a
  soft sink damper, `cushion_g = 1.5` (spec 0.6 g at the centre height gave ~0.2 g at
  touchdown), plus ground-effect lift `1 + 0.6·r²` within a span. PB-15.
- **M-7 Comfort caps as bank limits** use the actual normal load
  `n = max(g_load, 1/cos φ)` and the horizontal speed: with flapping the flap force
  tilts with the bank, so the 1-g formula under-limited the yaw rate. F11 composite.
- **M-8 Performance.** Derived constants and filter factors are cached and refreshed
  only when the assists, tuning, mass or substep change (`FlightModel.refresh()` after
  an in-place tuning edit). FM-28: 24.9 µs per 72 Hz step, 13.6 µs lite (limits 40/25).
- **M-9 FM-22** also asserts the energy drift against the kinetic energy alone
  (`v0²/2g`, the datum-free measure): ≤ 0.21 % over 60 s, bound 2 %.

**Input (§5, §6)**
- **I-1 A_MIN = 16° at every size** (spec lerp(10°, 15°)): an 8 cm hand waggle at 4 Hz
  is a 15.9° arc and must earn nothing (F9); the sparrow's ±15° strokes keep credit.
- **I-2 First onset:** the detector's first period is seeded from 2× the upstroke
  duration (no period exists yet; the default 1 s window was wrong for 2 Hz strokes).
- **I-3 Torso follow τ = 0.08 s** (spec 0.10): a first-order follow lags rate·τ, and the
  spec's own target (180° in 2 s, lag ≤ 8°) needs τ < 0.089. WI-05.
- **I-4 One-Euro filters run in degrees** (the spec's β values and latency targets are
  in degree units); the "stroking" latch holds for 0.5 s (ω crosses zero at every
  reversal); the jump filter compares with the previous raw sample.
- **I-5 Cycle-mean dihedral:** while both wings stroke they share one window (the mean
  of the two detectors' periods), and a stroking episode never averages the ring's
  pre-stroke history. Each detector's period estimate had its own history, so a bank
  gesture just before flapping gave a phantom roll of up to 0.36 for three beats.
  WI-28 (found from the WingInput channel plot).

**Player rig (§10–§12)**
- **R-1 Perch assist** steering cap 0.6 g / 0.8 g novice (spec 0.4/0.6): a bird at the
  0.8 V_min capture speed sinks at ~0.5 g even in a full flare. An air brake (≤ 0.5 g
  along −v, just enough to arrive at 0.95 V_cap) is part of the assist: the flare and
  CD bonus alone brake ~0.25 g, and a glide cannot get below ~1.03 V_min.
  Pigeon and bigger use the novice strength by default (§17 R4 fallback). PB-10 P1–P8.
- **R-2 P7** is flown at 1.0–1.3 V_min from 8 spans (what the bot and a player fly);
  the spec's 0.9–1.3 V_cap is below flying speed for the whole approach. Assist on
  20/20, off 0/20.
- **R-3 Touchdown:** the rig's yaw rate winds down within the acceleration cap when the
  bird lands or perches (stopping it in one tick was an 800+ °/s² jolt on a turning
  key-flown landing; found by F13). Telemetry `airspeed` is 0 while perched/grounded.
- **R-4 Heave smoother** (redesigned in fix round 1, below): the camera removes only the
  wingbeat, fitted on line; the flight path passes 1:1. The §11.3 formula (a
  full-period mean plus trend extrapolation) jumped the view at every burst.
  PB-08, PB-08b.
- **R-5 world_scale is VR's** (ARCHITECTURE, VR contract): `PlayerBird.drive_world_scale`
  defaults to false; flight's own driver (camera near `0.03·ws`, VR's value) runs only
  in flight's tests and lab.

**Bot and course (§14.4)**
- **B-1 Gap technique** replaced (see §14.4): glideslope, path-angle loop through the
  inverted pitch map, energy-budget entry height, flapping stops one beat early,
  distance along the path. Two defects surfaced: a stroke already under way landed
  its downstroke in the final glide and threw the bird metres above the line; and
  the P-only γ loop left a steady error (a steeper glide needs a faster trim).
- **B-2 Landing** replaced (see §14.4): orbits for excess energy; final line with the
  path-angle loop and an air brake. TECS was tried (stroke ripple dominates it).
- **B-3 Strokes are flap-glide:** effort below the reference is realised as full
  reference strokes with pauses (an accumulator owes `effort × rate` strokes), above
  it by rate (≤ 1.3×). Frequency-modulated slow strokes were credited little and,
  once started, blocked a change of mind for up to 2 s.
- **B-4 Cruise:** flap effort gets an envelope feed-forward (0.35 of the reference holds
  level, 1.0 climbs at `climb_at_cruise`); `k_l1 = 1.3` (spec 0.9: the human delay and a
  big bird's slow roll made 0.9 weave).
- **B-5 Robustness is tested:** B1 over 6 species × 10 seeds (`-- --full`): 60/60;
  B2 over 10 seeds × S3 × {normal, sim}: 100 % vs 3 %. The default suite runs a reduced
  sweep inside the L4 budget.
- **B-6 Course:** the window wall reaches the ground and stands 2× the gap height
  (no flying under or over it); the lab's ring gates sit on the key pilot's climb
  profile.

**Tests and tooling (§14)**
- **T-1** Golden values are asserted inline where they pin behaviour (balloon rise and
  peak time, stall times, stall loss, roll t90) and every other Appendix B quantity is
  recorded as a metric in the JSON report; there is no separate `golden.json`.
- **T-2** SIM-01 and SIM-04 run inside the lab (`--probe_axes`) under `tools/xr.sh`;
  `tests/sim/` belongs to the VR area.
- **T-3** DSK-01 is joined by **F13**: a closed-loop key pilot flies the lab (three
  ring gates, a 180° turn, a tuck dive, a landing, a take-off) with key events only.

**Fix round 1 (2026-09-26): verifier findings**
- **H-1 Camera heave (§11.3 replaced).** The spec's `y_avg + vy_avg·T/2` (round 1 added
  sample ages and a trend acceleration) extrapolates a trend from one stroke period.
  At the first and last stroke of every burst the window holds a partial wingbeat that
  the extrapolation reads as a climb or a dive, and the detector's period re-seeds at
  each burst (0.5 → 1.0 s); the view jumped up to 113 cm (perceived, one frame) in
  flap-glide bursts and 30–102 cm in the bot course (41–109× the body's own jerk). Now
  `HeaveSmoother` is an adaptive Fourier linear combiner on the body's vertical
  acceleration (k = 1..3 at the stroke **repetition** period, onset to onset, accepted
  only when it repeats; a DC weight takes the flight's own acceleration), with the
  displacement `A_k/(kω)²` rebuilt from critically damped copies of the weights, a
  continuous reference period, a fit-quality gain, a strokes-stopped fade, a smooth
  amplitude gain instead of a clamp knee, and an on/off ease. Nothing is extrapolated,
  so the flight path passes 1:1. The offset limit (`heave_clamp_spans`) means spans and
  is 1.5 (a sparrow's 1.35 s strokes bob about one span). Pinned by PB-08b
  (camera jerk ≤ 1.1× the body's in scripted flight, ≤ 1.4× in the bot course;
  wingbeat removal), HS-1..3, and the comfort monitor in every PlayerBird scenario.
  The design study (four rejected designs, with numbers) is in FLIGHT.md §2.
- **H-2 PB-08 transient** is measured path-separated (least-squares cubic path + stroke
  harmonics, `heave_metrics.wingbeat`): the moving-average bob counts a climb's own
  curvature as bob, which a camera that follows the path 1:1 must show.
- **S-1 F3 lift collapse is pinned directly** (FM-05c through
  `FlightModel.lift_coefficient`): separated flow ≤ 0.65 CL_max over α_s…α_s + 10°, and
  FM-05's stalled-mean / peak bound is 0.62 (was 0.8, which the stall FSM's nose-drop
  met with the separation removed).
- **S-2 Trim is attached flow** (`trim_solution` ignores the live `sigma`). FM-31.
- **S-3 Body pitch rate.** The weathercock feed-forward is gated on the current airspeed
  as well as the 0.5 s filtered one and limited, like the stall-protection clamps, to
  the pitch rate: the path angle flips 180° at the top of a vertical zoom. FM-30.
- **P-1 Tracker sanity** (§3.1 "no 0.5 m jump") is continuity with the last ACCEPTED
  pose: 0.15 m + v_lim·(time since), v_lim 3 m/s head, 5 m/s hands. The previous raw
  sample was the reference, so a glitch lasting two ticks was accepted from its second
  tick. A consistent offset held 0.25 s is a re-localization, head and both hands
  moving together a body translation (both accepted); hand gaps ≤ 0.1 s are bridged
  (a lost hand forfeits its arc, and one bad frame used to forfeit the stroke). WI-30;
  WI-20's extension step is a 4-tick ramp (a one-tick 0.5 m hand teleport is a glitch
  now).
- **P-2 Head-tracking loss** (§5 "after 1 s, request pause") emits
  `Events.menu_requested` once per loss (the menu button's route). PB-20.
- **P-3 Perch capture** is a cubic Hermite from the capture tick's start with the
  approach velocity to the grip at rest (T = 2d/V, ≤ 3d/V: no overshoot), not a
  one-tick stop and a 0.15 s linear slide. P9. Perched / grounded telemetry reports a
  still bird.
- **P-4 R5 record/replay** is wired: `record_poses` (Settings, `--record-poses`),
  tick-aligned replay. WI-29, PB-22.
- **T-4 FM-28** asserts the 40 / 25 µs budget with `-- --perf`; the default suite asserts
  2.5× that (a regression bound on a shared machine) and records the timings.
- **T-5 C3** asserts FLYING when the stun ends; a later second impact (the pilot keeps
  flapping at the wall) is correct and not asserted.
- **T-6 SIM-05** (F14): the simulator's own controllers, moved by its keybindings over
  SimRpc (`SendKey` only; nothing persisted), fly the bird: spread, neutral capture, a
  wrist twist and an arm raise bank it, one-wing strokes flap
  (`tests/shots/flight_sim_run.sh`).

**Fix round 2 (2026-09-26): verifier findings**
- **H-3 Camera heave: do no harm.** The round-1 fit predicted the next stroke from a
  reference period that lagged a changing rhythm; with irregular human flapping the view
  carried up to 61 % more wingbeat-band vertical acceleration than the body (42–96 % of
  3 s windows above 1.1×, windows up to 5×, per-tick jerk up to 1.72×; a pigeon's view
  bobbed 138 cm where its body bobbed 60 cm). `HeaveSmoother` keeps the adaptive fit but
  applies it only where it is known to help, closing each gate at the earliest moment a
  break is observable: **rhythm** (opens after three regular onset intervals, within
  30 %, on an onset within 12 % of the rhythm; closes when the rhythm breaks or the next
  onset is 1.2 periods overdue), **phase** (at every onset the template's phase against
  where onsets usually fall: the stroke's gain is `(cos e − cos 50°)/(1 − cos 50°)`),
  **arms** (the arms' stroke rate: the correction follows their stroke amplitude, the
  radius of the rate/angle phase portrait, and as they come to rest the template's
  phase stops with them and the still offset fades at 3 rad/s),
  **benefit** (least-squares gain of the template against the body's high-passed
  acceleration over one period, faded in between 0.3 and 0.9), all through
  jerk-limited critically damped eases (open 2.5 rad/s, close 10 rad/s). Flap-glide
  bursts, isolated strokes and irregular flapping are left untouched (camera = body);
  steady flapping is still ≥ 92 % removed (PB-08b: 6.2 / 7.7 / 6.7 % left). `update()` gains an optional `arm_rate`
  (NAN: no arm information, the arm gates stay open). The design study (four
  alternatives, including feed-forward from the known flap force, rejected with
  numbers) is in FLIGHT.md §2. Pinned by HS-1…HS-4, PB-08b, PB-08c (the verifier's
  human-flapping probe as a test) and B1/B2 (heave no-harm on the bot flights); the
  fixture's vertical comfort bound is 1.1× the body's jerk (was 1.4×).
- **H-4 PB-08 transient.** The correction waits for the rhythm, so while a hard climb is
  established (4–8 s) the wingbeat is only asserted not amplified; it is at least
  halved from the 6th second (6–10 s). HS-1 measures from 10 s.
- **L-1 Bird lifecycle.** `PlayerBird._exit_tree` calls `super()` (Godot 4 does not chain
  virtual callbacks): the player is unregistered from `Birds` when it leaves the tree.
  PB-23.
- **E-1 PB-13 S5** (events exactly once per occurrence) and **S2 in a real paused tree**
  are tests now; `player_flapped` is once per paired stroke (ARCHITECTURE §5).
- **E-2 PB-14** asserts the spec's |φ| < 5° from 1.5 s after the loss decays to the end
  of the loss (the round-1 test asserted 65° after the hand was back).
- **C-1 Stun turn-away** (superseded by V-2 in round 3). A stun off a wall (mostly horizontal normal) turns the bird to
  the reflection of its heading off the wall, a minimum-jerk yaw over 0.5 + |Δψ|/π s
  (180° in 1.5 s: 225°/s, 462°/s² peak, inside the comfort caps) that the rig follows
  like any turn. Before, a neutral-armed bird fell off the wall, regained speed along
  its old heading and hit it again (pigeon 3, eagle 5 stuns in 8 s). C8 (one stun in
  8 s at every size, walls 1 m and 0.2 m).
- **C-2 C1b** fires the real PlayerBird at a 1 cm rod (300 shots per size, to 1.2 V_max,
  1/72 s and 0.1 s ticks): C1 alone validated Jolt's `cast_motion`.
- **W-1 Wrist-twist jitter** (reversals faster than 0.15 s per half-cycle) is replaced by
  its critically damped mean before the pitch shaping: through the asymmetric shaping
  and the model's asymmetric pitch map, ±35° at 4–10 Hz had become a trim worth 6 m of
  energy height in 12 s. A pitch step keeps its 90 ms latency (WI-20); a pilot's pitch
  pumping at 1.5 Hz passes. F9 twist-jitter test.
- **W-2 Arc bank** (§6.2) is pinned by its own test (a slow raise banks nothing, a flick
  banks its arc, the downstroke after it earns only that).
- **D-1 §6.3** corrected to what the detector rewards (above).
- **M-1 `flap_impulse`** is the impulse the integrator applied (both Heun stages); round 1
  summed the first stage only.
- **B-7 Course facade.** The window wall is 60 spans (≥ 40 m) wide instead of 24 spans
  (≥ 12 m): in the lab it read as a narrow tower; a facade makes the window, not a way
  round, the route. B1/B2/F13 unchanged.
- **T-7 Runtime.** Redundant default work moved behind `-- --full` (B1 robustness at
  one size, the B2 sim preset at one size, PB-08's starling, FM-23 as one 10k run per
  size with the gusts in its second half, FM-24's reference at 360 Hz).
- **T-8 FM-24c** flies the verifier's flapping turn through the whole chain at 72 / 90 /
  120 Hz: end states within 3 % of the flown path and 5° of heading (measured 2.6 / 2.3 %,
  2.9 / 2.6°). The flap and roll commands agree within 0.5 % in integral across tick
  rates; the 15 s turn at up to ~150°/s amplifies that; ramped inputs give the same, so
  it is not a step landing on another tick; gliding turns agree within 0.1 %
  (FLIGHT.md §3).
- **T-9 PERF-01** is asserted (0.35 ms with `-- --perf`, 2.5× that by default) and
  recorded.
- **T-10 Mutation evidence** is written entirely by `tests/shots/flight_mutants.py`
  (`artifacts/flight/mutants.json`); its failure-line parser now matches the runner's
  output.

**Fix round 3 (2026-09-26): verifier findings**
- **V-1 Heading steps are owed to the view, never dropped (`ViewTurn`).** (The payout is superseded in round 4 by R4-1; the owing stands.) A bounce or a
  slide off a wall changes the flight path in one tick, and the model re-seats the
  heading on it (`apply_contact`; the bird is knocked round with its path).
  - **Round 2:** the rig followed heading changes only through its rate and
    acceleration clamps and discarded the rest. The view then kept facing the wall, and
    body steer (`e = R + θ_b − ψ`) read that stale view as the player's torso and banked
    the bird back in. At 30–60° incidence with the arms still this gave 2–4 stuns in 8 s
    at every size.
  - **Jumps:** the model reports them in `heading_step`, `take_heading_step()`: contact
    re-seats, the stun's redirect, and a path heading moving faster than 6 rad/s within a
    substep.
  - **Payout:** jumps become a debt `D` that `ViewTurn` pays along one minimum-jerk
    rotation within `view_turn_rate_deg` 120°/s and `view_turn_accel_deg` 240°/s². It
    re-plans from the current payout rate and acceleration whenever more is owed, so the
    view's acceleration never steps.
  - **Clamps:** the flown turn is followed directly while its rate changes no faster than
    half the acceleration cap; the excess is owed. What the rig's safety clamp holds back
    in the air is owed too.
  - **Body steer** reads `e = wrap(R + D + θ_b − ψ)`, where the view is heading for.
  - **Perch capture or landing:** `ViewTurn.settle(rig rate, accel)` brakes the rig's
    whole motion to rest along a quintic instead of stopping it in one tick.
  - **Pinned by:** C8b (30–90° at three sizes: one stun in 8 s; the view within 10° of
    the heading 1 s after the stun; the forced turn ≤ 120°/s and ≤ 240°/s² + 5 %; no
    overshoot; the heading held within 3°; the safety net idle) and P10 (the rig's
    acceleration stays below 540°/s² while the assist crabs the bird).
- **V-2 The stun leaves the wall the short way** (replaces C-1; superseded in round 4 by R4-2: at most 40°). A stun off a wall (a
  mostly horizontal normal) redirects the bird's air path to leave at `stun_exit_deg`
  (20°) to the wall's plane, turning the short way: the smallest rotation that does not
  lead back in. That is incidence + 20°, so 110° head-on instead of the reflection's
  180°. The view follows through V-1, so the "stun" clause of C7 is amended (§11.1).
  Round 2's turn-away turned 180° with its own yaw profile while the model snapped the
  rest to the path: the rig ran at 240°/s and 720°/s² and overshot by 17°. Pinned by C8b
  (turn = incidence + 20° ± 3°).
- **V-3 Floors bounce less.** A stun whose normal is floor-like (n.y > 0.7) bounces
  `floor_restitution` (0.05) of v_n instead of 0.25. A tucked V_max dive into a field
  hopped a metre (1.5 pigeon spans), the stun ended in the air, and the still-tucked bird
  dived in again. C9 (one stun, a hop under half a span, then GROUNDED, at 90° and 60°
  at three sizes).
- **V-4 Teleports start the view at rest.** `respawn`, `start_flying` and `perch_on`
  zero the rig's yaw rate and acceleration, the view debt, the body-steer lags, the
  model's pending heading jumps, and the previous flight's perching state (the capture
  lockout after a contact, the assist's last push). After "Restart run" from a pause taken mid-turn, the
  round-2 clamp wound the old 206°/s down over the spawn: 28° of view rotation, and a
  launch 30° off the respawn yaw. PB-24 (every teleport at three sizes out of a
  full-rate turn, and the real paused tree).
- **W-3 Gust weathercock.** When the wind changes (in time, or along the path) the air
  path turns under the bird. `chi` follows the air, and the wind's share of that turn is
  taken back into the sideslip channel `dpsi` (clamped ±0.5 rad). The body then
  weathercocks round (τ_wc) while the side force carries it with the air (τ_sf), and the
  heading settles `τ_sf/(τ_sf + τ_wc)` = 0.375 of the way into the new relative wind,
  smoothly (measured 0.40–0.42). Round 2 followed the air instantly: a crosswind gust
  front stepped the view's yaw rate in one tick (720°/s², the cap). PB-26 (0.5 s ramp:
  ≤ 104°/s², was 720).
- **P-2 Perch assist in the world's breeze** (§10.6 amended).
  - **Candidate:** acquired within 50° of the bird's AIR path or its ground path,
    then held until it is passed, leaves 1.5 × reach, is taken or no longer fits.
    Round 2 used the ground velocity only. A slow sparrow in a headwind has a steep ground
    path, so the perch left that cone two spans out and the assist, with its gravity
    compensation, let go under the grip.
  - **Wind budget:** removing the wind's drift across the line of sight gets its own
    steering budget on top of the cap, up to 0.5 g (`3·|w⊥|/t_go`).
  - **Brake:** plans with the ground speed (`a = Δv·(v_g − Δv/2)/d`, the still-air
    formula when v_g = v) and also cancels the bird's own acceleration along its path
    (a dive onto the branch).
  - **View:** the heading change the assist's push causes is owed to the view (V-1).
  - **Evidence:**
    - P10 (slow glide-ins, three sizes): 2.1 m/s head and cross winds and a 1.5 m/s tail
      keep ≥ 80 % of the still-air success, a 2.1 m/s tail ≥ 70 % (measured 90–100 %,
      80–100 %).
    - P11 (tailwind from above the glide path: pigeon and eagle ≥ 7 of 9).
    - The full sweep, including the verifier's set, is in FLIGHT.md §3.
- **P-3 Capture on the landing speed** `min(airspeed, |v|)`. The feet meet a static
  branch at the ground speed, so a headwind helps as it does real birds. Round 2 judged
  the airspeed only, and landing into the wind was harder than downwind. Downwind the
  airspeed stays the measure (a gameplay rule): a bird slow through the air still has its
  whole wing for the last flare, and downwind the branch already arrives sooner.
- **F-1 F1's upstroke clause from the applied impulse.** FM-11b and flap_detector f1 fly
  the same WingState stream three times, as given, with the upstroke commands zeroed and
  with the downstroke commands zeroed, and compare the vertical flap impulse the model
  applies. Measured: +0.30 / −0.12 / −0.13 at model level, +0.30 / −0.10 / −0.11 through
  the pose chain.
  - **Round 2** divided parameters (`up_gain·∫U/∫P`), so a model whose force ignored
    `up_gain` passed.
  - **In time:** the τ_f smoothing carries each downstroke's force into the next
    upstroke, so the impulse delivered while the arms rise is 0.84 / 0.56 / 0.48 of that
    while they fall. That is recorded and bounded below 1. The clause means the force the
    upstroke itself produces.
- **L-2 World found late.** `PlayerBird` looks for the World again (at most once a
  tick) while it has none. A World added after the player brings its wind, perches and
  ground. PB-25 also pins `in_updraft` (the vertical wind at the body, never negative)
  and the groups `player`, `birds` and `player_rig`.
- **T-11 Telemetry** adds `view_turn` (rad still owed to the view) and `view_turn_rate`
  (rad/s of the forced turn), which the VR vignette may cover. Contract keys unchanged.
- **T-12 Comfort monitor** asserts the cap itself (720°/s² + 10⁻³); round 2 allowed
  756.

**Fix round 4 (2026-09-26): verifier findings and the lead's direction**

The round-4 verifiers found one critical and two major defects; the lead asked for
simpler, provable mechanisms where one kept producing edge cases. Each item below is
pinned by a test that fails on the round-3 sources (`tests/shots/flight_r4_oldcode_check.py`,
`artifacts/flight/r4_old_code_check.json`).

- **R4-1 ViewTurn is a time-optimal follower (replaces V-1's quintic).** Round 3 paid
  owed heading steps along a re-planned minimum-jerk quintic whose duration search could
  run out: the coefficients were then solved for another duration, and after stuns that
  ended on the floor the view spun at the 240°/s rig cap for tens of seconds (15 of 96
  fast room entries; one turned 10 271° in 55 s). Now each tick the payout rate moves by
  at most `view_turn_accel_deg`·dt (240°/s²) toward the fastest rate that can still stop
  exactly on the target braking at that acceleration, never above `view_turn_rate_deg`
  (120°/s). The discrete stopping curve is exact: from rate v, with n = ⌊v/(a dt)⌋, the
  ticks that follow pay dt((n+1)v − a dt·n(n+1)/2), so v_stop(e) = e/(dt(n+1)) + a dt·n/2.
  No search, no failure branch. Properties (VT-1…VT-4, 3 000 random owe sequences by
  default, 20 000 with `--full`, at 72/90/120 Hz): the caps hold on every tick; owed =
  paid + debt; from rest it is at rest on the target within |e|/rate + rate/acc + 0.3 s
  and within 3 ticks of the continuous time-optimal turn; no overshoot from rest or on
  the stopping curve; a debt cut short under a fast payout overruns by at most the
  unavoidable brake run v²/2a. A rate left above a lowered cap only brakes. `settle()` is
  gone: on a perch capture or a landing the debt is forgiven and the rig's own turn
  brakes to rest at the comfort acceleration cap (≤ 0.33 s from 240°/s; C10).
- **R4-2 A stun deflects the velocity and turns the bird at most 40° (replaces V-2).**
  Round 3 turned a stun to leave the wall at 20° to its plane: incidence + 20°, 110°
  head-on, with no input from the player. Now the body turns the short way toward that,
  capped at `contact_turn_max_deg` (40°); the player turns the rest. The model can only
  hold a path within the sideslip limit (0.5 rad) of the body, so a bounce path outside
  it is turned to that limit if that leaves the wall, else removed (head-on: the bird is
  stopped and drops). Keeping a backward path was tried: while the stunned bird fell, it
  drifted inside 90° of the body and the heading snapped 84°. Slides turn the body only
  as far as the sideslip limit needs (≤ 40°). (A post-stun grace that let walls only
  slide a just-stunned bird was built and removed: no scenario, the verifier's room
  sweep and probes included, measured any effect.) With the arms still: one stun in 8 s
  at 30–90° and three sizes, the stun's turn min(incidence + 20°, 40°), no contact ever
  turns more than 40°, and in the 3 s after the hit the view turns at most as far as the
  wall line (the bird then flies along the wall; ≤ 94° head-on, all smooth) (C8, C8b).
- **R4-3 Grazing contacts.** When the rest query at the cast's unsafe point finds
  nothing (a bird sliding down a wall), it is repeated with a 2 mm margin; if there is
  still nothing the sweep stops at the safe point with no response. Round 3 guessed the
  normal as minus the motion: a fall along a wall read as a floor hit at the full fall
  speed and stunned the eagle five more times (C11: 48 falls along a wall face, none
  stunned; round 3's guess stuns the pigeon and eagle).
- **R4-4 The rest pose on a perch (replaces the drop-launch).** Round 3 dropped a bird
  off its perch as soon as the arms hung at the sides (read as the tuck): a pigeon or
  eagle fell 20 m to the ground, and 10 of 20 relaxed postures ejected it. Off a perch
  only a completed flap launches (§10.2): a credited downstroke that ends with the wing
  still out, or a deep stroke that ends low and rises back out within 0.8 s; the bird
  leaves at the bottom of the stroke. A brisk drop of the arms to the sides after
  raising them is a credited downstroke too, but it ends folded: no launch. The ground
  keeps the credited onset (a stroke must lift the bird with its whole downstroke; a
  relaxing drop there is at most a hop). Perched or grounded telemetry reports no tuck.
  P5, P6 (60 s at the sides, 20 s of fidgeting with 4 credited downstrokes that end
  folded, at three sizes; the first flap from the rest pose launches), P6b.
- **R4-5 No flap force across the body.** Each wing's force followed its instantaneous
  normal, which droops 20–45° late in the downstroke, so a single stroking arm shoved the
  body toward its own side (−0.76 g peak for the pigeon): after the first stroke the
  one-arm turn reversed (pigeon +47°, eagle +15.5° toward the stroking wing, banked the
  other way). Now the normal's component across the banked body is dropped
  (`flap_side_share` 0); symmetric strokes are unchanged (their parts cancelled).
  FM-18b, PB-28 (10 one-arm strokes: away every second, 59–136°, mirror-exact, banked
  the way they turn, sideslip ≤ 0.6°, sideways specific force ≤ 0.055 g).
- **R4-6 The one-wing kick on the stroke-mean asymmetry, with a dead zone.** The roll
  kick and paddle yaw read the instantaneous flap difference: arms 10 % unequal or 30 ms
  apart wobbled the sparrow's view 5.5–6.8° every wingbeat (25 % and 60 ms: 12–15° plus
  30–47° of drift in 10 s). Now they act on each wing's effort averaged over the last
  stroke period (a timing offset averages out), and only on the relative asymmetry
  beyond `one_wing_deadzone` 0.15 (rescaled to full at a one-wing stroke): natural human
  asymmetry is a symmetric stroke. Differential wing tilt still yaws (a real effect of
  twisting while flapping). PB-27 (±20 % amplitude, ±50 ms at three sizes, a sparrow's
  2 Hz stroke: wobble 0.0003°, drift 0.0005°/s, sideways force 1e-5 g). FM-18c: no kick
  inside the dead zone, 10 % of a one-wing stroke's bank at 20 % asymmetry (33 % without
  the rescale). FM-18 unchanged (bank 5.7–6.4°, turn right 3.9–6.7°).
- **R4-7 Camera heave at a rhythm's end.** With the arms at rest the template's phase
  stops outright (the amplitude radius keeps an arm-angle term that stays high while an
  arm is held at an extreme), and the amplitude gain closes at the rest rate: a still
  offset fades below the wingbeat band. A novice eagle whose last stroke ended at level
  had a 3 s window at 2.1× its body's motion (limit 1.5); now 1.39. Every heave test
  unchanged.
- **R4-8 Bot pilot (test instrument).** The unpowered final glide starts at its planned
  distance, but not while the bird is still banked beyond ~30° in the turn onto the
  return leg (for at most 30 % of the glide): the eagle's steep turn at the entry shed a
  quarter of its speed and it crossed the window at 1.07 V_min on 2 seeds of 6. Now
  1.30–1.52 V_min.
- **R4-9 world_scale exponent.** Default 1.0, the VR area's recommendation (§11.4).
- **R4-10 VR's requests.** WingInput refines the arm span only while flight owns the
  calibration (`refine_span`, set from `PlayerBird.auto_calibrate`; WI-32), and
  `WingCalibration.from_dict` validates native Basis / Vector3 / scalar values as its
  flat-array path does (WI-33).
- **T-13 Suite budget.** The default suite keeps one representative case per criterion;
  the sweeps run with `-- --full` (FLIGHT.md §3 lists what moved). FM-13's runs are
  12 s + 8 s (was 20 + 10; every result the same to 4 digits but one, by 0.9 %).
- **T-14 Unpinned contracts pinned.** PB-19b (a 1 s tick advances ≤ 0.1 s of flight),
  FM-23b (a NaN / INF state is restored to the last good one).

**Fix round 5 (2026-09-26): verifier findings**

- **R5-1 Landing on the ground: friction and the touchdown speed.** A silent contact
  with the ground was frictionless, and a touchdown needed V ≤ 0.7 V_min: a bird below
  stall speed with its belly on the grass slid on for 7 s (pigeon) to 15 s (eagle)
  "flying", and came to rest after 22 and 45 s. Now a silent ground contact is a skid
  (Coulomb friction μ·v_n from the speed along the ground, μ = `ground_friction` 0.6),
  and a ground contact at V ≤ `touchdown_speed` (1.2 V_min) is a touchdown. Perch
  geometry (layer 2) is never ground: a slow bird on a branch top away from its grip
  slides on it (G7). G2: a neutral glide into a meadow from 6 spans + 2 m never skims
  below V_min and rests within 20 s (2.6 / 7.5 / 16.7 s; the eagle's float in ground
  effect is the spec's own G15 skim, PB-15 ≥ 40 spans).
- **R5-2 The run-out and the legs.** The touchdown stopped the body in one tick
  (0.58–0.98 × the touchdown speed per tick; a perch capture has eased in since round
  1, P9). Now the speed along the ground runs out at μg (distance v²/2μg: a sparrow at
  V_min 1.4 m, an eagle 6.5 m), swept and settled on the ground, flying again off an
  edge; the rest of the touchdown tick's motion carries on along the ground; and the
  speed into it goes into the legs, a camera dip of at most 0.75 body radii (§10.2). A
  take-off during the run-out keeps its speed. G1 (the view's per-tick Δv ≤ 0.45 × the
  touchdown speed: 0.34 / 0.08 / 0.05), G3.
- **R5-3 The stall guard.** A full flare from the glide speed near the ground zoomed a
  sparrow 10 spans up; the deliberate stall there was held while the nose dropped to
  −45° and the bird dived into the grass at 4.7 m/s (a stun from every flare height
  tried). Now (normal and novice presets) a deliberate stall is refused, and a stall is
  not held, below the height a stall needs: what a held stall falls before its forced
  recovery (0.4 g·T_fr², 8.8 m) plus a quarter of V_min²/g of pull-out (sparrow 9.2,
  pigeon 9.7, eagle 10.8 m); there a full flare is the maximum-lift flare. `FlightEnv.agl`
  (the belly's height above the World's terrain, or the ground ray) feeds it. G5; above
  the guard F3 is unchanged (FM-05, FM-06; the verifier's wrist-stall probe at 300 m).
- **R5-4 The landing configuration over the ground.** A big bird's flare zoomed up to 7
  spans and then glided at L/D 14, landing only after 20 s. Now a slow (≤ 1.3–1.6 V_min),
  sinking, flaring (pitch 0.2–0.6) bird within 4 spans of the ground lowers its legs and
  fans its tail: the perch assist's landing configuration (+0.4 CD at most, ≤ 0.5 g of
  extra drag). A pull-up from a low pass (fast, climbing) zooms exactly as high, and a
  trimmed skim gets none (G6). G4: flares of +20 and +40° from 1 span land every size
  with no stun (the verifier's 27-case grid with `--full`).
- **R5-5 Perching into the full breeze.** A sparrow could not perch into or across the
  world's 2.64 m/s breeze at 30 m (65 % of its V_min). Into the wind, the slow bird lost
  airspeed to drag until the air carried it backwards 0.6 m short of the branch: now,
  below a closing speed of 0.25 V_cap along the line of sight, the assist cancels the
  bird's own deceleration along it and closes the gap, from the headwind's own budget
  (≤ 0.5 g, applied after the steering cap, as the crosswind's). Across the wind, see
  R5-6. P13.
- **R5-6 A slow brush of the branch keeps the capture.** A slide armed the 0.5 s capture
  lockout: a sparrow crabbing into the crosswind brushed the branch from below, hung
  within reach of the grip, locked out, and fell. Now only a scrape too fast to perch
  (landing speed > V_cap) locks the capture out. P13.
- **R5-7 Resume from the pause menu.** Unpausing only trusted the new poses: the jump to
  a raised pointing arm banked as an upstroke, the arm's way down 0.3–0.4 s after resume
  was a credited downstroke (0.36 of the weight in flap force), and the arms coming back
  from the menu pose flew at full authority (up to 70° of bank, 79° of view turn in 3 s).
  Now `WingInput.resume()` restarts the stroke detectors, and the controls stay neutral
  until the arms are out and settled (or 1.5 s), then fade in over 0.4 s (§10.2). PB-29.
- **R5-8 Hand velocity over the real pose interval.** The detectors clamped dt to 1/30 s
  (a 0.1 s tick read the hand 3× too fast), and an engine frame hitch (several fixed
  ticks on one XR pose, the first seeing it jump by the whole hitch) read as a 7× faster
  hand: slow arm sweeps flapped. Now `PoseFrame.pose_dt` carries the time the poses
  really advanced (XRPoseSource with `frame_timing`: the wall-clock time between engine
  frames, 0 for repeats; recorded and replayed), and the detectors measure velocity, arcs
  and the arc bank over it (repeats carry the stroke on). PB-31, WI-34. Synthetic
  sources sample every tick and do not hitch.
- **R5-9 A recenter mid-payout stops the rig's turn** (it kept its rate, overran at the
  720°/s² safety net and owed that back). PB-30.
- **R5-10 World-scale changes rescale the rig at once** (flight's fallback driver): the
  tracked nodes, the origin offset and the wing anchors, as the XR server will at its
  next update. The lab's first XR tick read the head 1.04 m off the body after the
  start-up snap. PB-32 (with the ramp and near = 0.03·world_scale, the verifier's two
  unpinned contracts).
- **R5-11 ViewTurn with a changing tick length** (qualified, not changed): the caps and
  conservation hold for any ticks; "never past the target" is exact for a constant tick
  (Godot's physics tick). With 72/90/120 Hz mixed every tick: overshoot ≤ 0.25° (0.21
  measured), convergence within 1 s of the constant-tick bound. VT-5. Arbitrary tick
  lengths (random 4–100 ms ticks mixed in) can run past by a few degrees (4.7° in the
  round-5 engineering probe). The game never feeds those: PlayerBird ticks at the
  fixed physics step, and a hitch runs more steps, not longer ones.
- **R5-12 Head-on stun: what the view turns.** The contact's own turn is ≤ 40°. A
  stopped, falling bird's heading then follows its air path once that is faster than
  0.25 V_min (it falls away along the wall): 22–34° head-on, 5° at 60°, also a heading
  jump owed to the view (paid smoothly inside 120°/s and 240°/s²). Round 4's docs called
  it all flown; the composition is now stated and the total forced (not flown) turn in
  the 3 s after the hit is pinned at ≤ min(incidence + 20°, 40°) + 40° (C8b: 40 / 45 /
  62–74°).
- **R5-13 Lab facade and chase framing.** Human-scale windows (at least 1.4 × 1.6 m)
  over the whole facade, the bird-sized opening among them; the chase camera at 2.8
  spans + 5 cm (a sparrow ~8 % of the frame width in a turn).

**Fix round 6 (2026-09-26): verifier findings (landing and taking off off flat ground)**

- **R6-1 The feet reach, the legs bend along the surface.** Round 5 met the ground with
  the belly and bent the legs vertically only, over 0.75 body radii: on an upslope the
  speed into the slope's horizontal part stopped in one tick, and a sparrow's 2.9 cm of
  bend stopped a touchdown on a 34–44° roof, or a steep one on the flat, at 0.5–0.85 ×
  the touchdown speed per tick (the 0.45 bound). Now a bird at landing speed meets a
  floor with its feet one body radius beyond its body (`leg_reach`), the legs take the
  speed into the surface along its normal over the reach plus the bend (1.75 body radii),
  and a touchdown may come in at up to 1 V_min into the surface (`touchdown_vn`; round
  5: V_cap = 0.8 V_min, and a slow bird flying into a 44° roof was stunned). The camera's
  offset from the body is heave (vertical) plus the legs' bend (along the normal):
  `PlayerBird.view_offset()`; `heave_offset()` stays its vertical part. The bend is a
  constant deceleration, the gentlest that fits; the stand back up is at ≤ 2 g (round
  5 stood up at the bend's own deceleration, up to 15 g for a sparrow). A skid (a slide
  on a floor at flying speed) bends the legs too when the bend can spread it over two
  ticks (v_n·dt ≤ the flex; a harder one stops the view with the body, never harder:
  G1c). G1 (flat, 10/20/38/44° upslopes, across
  a 38° roof, a 10° downslope, two approaches, three sizes), G1b (the touchdown envelope
  on the flat, forward 0.4–1.0 × sinking 0.3–0.7 V_min).
- **R6-2 The run-out along slopes.** Round 5 ran level, stepping up 0.3 body radii a
  tick: facing up a slope steeper than ~11° (sparrow) the slope stopped the run in one
  tick. Now the run keeps to the ground's plane and brakes at μg·cos(slope) plus gravity
  along it (at least `run_brake_min`·μg = 0.3 g: a steep downhill would speed it up, the
  feet grip), swept along the plane (a steeper floor ahead turns the run onto it, its
  legs taking the speed into it); a ridge (the ground falling away by more than 20°)
  launches it. At rest the feet hold on any floor (n.y > 0.7). G3d (v²/2a within 3 %
  up 20° and 38°, down 20°, across a 38° roof), G3e (flat into a 20° hill; up a 38° roof
  and over its ridge).
- **R6-3 Taking off from a slope.** Round 5 launched level (the heading's direction) and
  straight up: facing up any slope above 20–25° the launch drove the bird into the slope,
  which touched it down on the next tick, and every later stroke did it again (a
  took_off / perched pair per stroke, stuck). Now the launch leaves the surface (its
  part into the ground removed at the same speed, the kick along the surface normal) and
  a bird launched off the ground is not touched down again while it keeps flapping (a
  stroke within `take_off_hold_gap`, 1.2 s) or for `take_off_hold_s` (0.5 s), until it is
  two spans clear of the surface below; its feet scramble on the ground meanwhile (a
  silent contact without friction), and when the scramble no longer makes way up or along
  the slope its feet hold it (it stands; it never slides back down on its belly).
  Physics sets the rest: a sparrow climbs straight out of a 44° slope; a pigeon or an
  eagle cannot out-climb a long slope steeper than its climb gradient from a standing
  start (an eagle ~12°, a pigeon ~17–20°: F7's climb rates), so it bounds up it (one
  take-off per bound, 5–25 spans of way in 6 s) and leaves over a roof's ridge (a
  village roof is 3–5 m from eave to ridge) or with a banked turn away. G8 (20/30/38/44°
  at three sizes), G9 (a village roof, 38 and 44°), G10 (bank away from a 30° hillside).
- **R6-4 The stall guard reads flat roofs.** `World.ground_height` is the terrain only
  (no buildings, bridge or water-tower deck) and round 5's ground ray reached 2 spans:
  over a 25 m flat roof a full flare zoomed above the ray and stalled. Now the ray
  reaches below the guard height (guard + r_body + 1 m); its hit, when there is one, is
  `FlightEnv.agl` (the terrain only when it misses). G5b (PlayerBird level: a sparrow
  stalls from 15 and 25 m, never from 5 m; over a 25 m roof no stall below the guard
  height at any size, an eagle's 7-span zoom may stall above it, as over the meadow).
- **R6-5 Telemetry read inside an Events handler.** The round-5 cache kept mid-tick
  values (a touchdown's `player_perched` fires before the rig is placed) for the rest of
  the tick; the next read after the tick now rebuilds. PB-34.
- **R6-6 Pins for three round-5 behaviours the verifier's mutants could remove:** the
  game's XR source is frame-timed (PB-33, WI-34's hitches through the player's own
  source), the in-game stall guard height (G5b), and the fast-scrape capture lockout
  (P14; R5-6).
- **R6-7 Suite time.** P6's static 60 s rest runs at the sparrow by default and at all
  three sizes with `--full` (the held pose does not move, so no size's detectors see
  anything in it; the 20 s of fidgeting and the flap launch still run at three sizes).
- **R6-8 The wrap at ±180° is exact.** Godot's `wrapf(x, -PI, PI)` returns −π for any
  result within its `is_equal_approx` tolerance of +π: `ViewTurn.owe` lost up to
  2.5·10⁻⁵ rad of owed turn (VT-1's conservation over the 20 000 `--full` sequences
  failed since round 4). `ViewTurn` and `FlightMath.wrap_angle` now wrap exactly
  (VT-6).
- **R6-9 PB-08c's sparrow bound.** With `--full`, the sparrow at ±20 % stroke jitter over
  the held-out seeds 41–43 reads 0.9349 of the body's band acceleration against a
  bound of 0.93, since round 4 (the round-5 sources read the same). Round 4 set the
  bound below the heave study's own held-out measurement of this case (0.934,
  `heave_eval.txt`). The bound is 0.94; the no-harm assertions are unchanged.

## Appendix A: FlightModel step (GDScript-flavoured pseudocode; this is exactly what the prototype ran)

```gdscript
const G := 9.81
const RHO := 1.225
const SUBSTEP_HZ := 120.0

func step(ws: WingState, env: FlightEnv, dt: float) -> void:
	var n := maxi(1, ceili(dt * SUBSTEP_HZ - 1e-9))
	var h := dt / n
	for i in n:
		_substep(ws, env, h)

func _substep(ws: WingState, env: FlightEnv, h: float) -> void:
	var p := params
	var W := env.wind_fn.call(position) if env.wind_fn.is_valid() else Vector3.ZERO
	var va := velocity - W
	var V := va.length()
	var vh := Vector2(va.x, va.z).length()
	_update_chi(va)                                   # w = smoothstep(0.1, 0.4, vh/V_min); only if |wrapped d| < 90 deg
	var fh := Vector3(-sin(chi), 0, -cos(chi))
	var gam := atan2(va.y, va.dot(fh)) if V > 1e-6 else 0.0
	var spread := clampf(0.5 * (ws.ext_l + ws.ext_r), 0, 1)
	var fA := 0.25 + 0.75 * spread
	# --- flap smoothing and the endurance cap (G11)
	var kf := 1.0 - exp(-h / p.tau_f)
	_P_l += (clampf(ws.flap_l, 0, 1.3) - _P_l) * kf;  _P_r += (clampf(ws.flap_r, 0, 1.3) - _P_r) * kf
	_U_l += (clampf(ws.up_l, 0, 1) - _U_l) * kf;      _U_r += (clampf(ws.up_r, 0, 1) - _U_r) * kf
	_endurance.push(ws, h)                            # ring buffer over ws.stroke_period (0.3..1.5 s), FULL-window mean
	var en_l := minf(1.0, E_CAP * p.p_ref_pos / maxf(_endurance.mean_l, 1e-6))   # E_CAP = 1.15
	var en_r := minf(1.0, E_CAP * p.p_ref_pos / maxf(_endurance.mean_r, 1e-6))
	# --- speed-rate damper input and regime filters
	_udot += ((V - _V_prev) / h - _udot) * (1.0 - exp(-h / 0.05));  _V_prev = V
	var klp := 1.0 - exp(-h / 0.5)
	_V_lp += (V - _V_lp) * klp;  _vh_lp += (vh - _vh_lp) * klp
	# --- pitch (7.4)
	var a_cmd := _alpha_cmd(ws, V, fA, h)
	var th_hi := deg_to_rad(90) * smoothstep(0.5, 1.2, maxf(_vh_lp / p.v_min, (_V_lp - p.v_min) / (0.5 * p.v_min)))
	var hov := smoothstep(0.05, 0.2, 0.5 * (_P_l + _P_r)) * (1.0 - smoothstep(0.3, 0.6, _V_lp / p.v_min))
	var th_lo := -deg_to_rad(90) * (1.0 - hov)       # powered hover holds the body near level
	theta += clampf((clampf(gam + a_cmd, th_lo, th_hi) - theta) / p.tau_alpha, -p.q_max, p.q_max) * h
	var protect := assists.stall_protect and _delib_t < 0.35 and not stalled and _V_lp >= 0.5 * p.v_min
	if protect:
		theta = minf(theta, gam + p.alpha_s - deg_to_rad(0.5))
	var alpha_m := theta - gam
	# --- stall FSM (7.5)
	if not stalled and alpha_m > p.alpha_s + deg_to_rad(0.5):
		stalled = true; _t_stall = 0.0; _events.append("stall")
		_stall_side = signf(phi) if absf(phi) > deg_to_rad(1) else (signf(ws.roll) if absf(ws.roll) > 0.02 else -_stall_side)
	if stalled:
		_t_stall += h
		var held := assists.stall_protect and ws.pitch >= 0.9 and _t_stall <= 1.5
		if _t_stall > 0.3 and alpha_m < p.alpha_s - deg_to_rad(3) and not held:
			stalled = false; _events.append("unstall")
	_sigma += ((1.0 if stalled else 0.0) - _sigma) * (1.0 - exp(-h / 0.15))
	stall_warning = 1.0 if stalled else smoothstep(p.alpha_s - deg_to_rad(6), p.alpha_s, alpha_m)
	# --- bank (7.6)
	# ws.roll already includes body steer: PlayerBird writes roll_total into it before step (10.4)
	var phi_cmd := clampf(ws.roll, -1, 1) * p.phi_max + deg_to_rad(18) * (_P_l - _P_r) \
		+ 0.5 * (ws.ext_l - ws.ext_r) * p.phi_max
	if stalled:
		phi_cmd += deg_to_rad(15) * _stall_side * smoothstep(0, 0.5, _t_stall)
	var lim := p.phi_max
	var plim := p.p_max * clampf(V / p.v_c, 0.4, 1.25)
	if comfort_yaw_rate > 0.0:
		lim = minf(lim, atan(comfort_yaw_rate * maxf(V, p.v_min) / G))
	if comfort_yaw_accel > 0.0:
		plim = minf(plim, comfort_yaw_accel * maxf(V, p.v_min) * cos(phi) * cos(phi) / G)
	_phidot = clampf((clampf(phi_cmd, -lim, lim) - phi) / p.tau_bank, -plim, plim)
	phi += _phidot * h
	# --- yaw offset channel (7.6)
	var n_adv := (1.0 - k_rud) * 0.04 * clampf(p.a * alpha_m / p.cl_n, -2, 5) * _phidot
	var d_l := asin(clampf(-ws.flap_dir_l.z, -1, 1));  var d_r := asin(clampf(-ws.flap_dir_r.z, -1, 1))
	var n_kick := -0.35 * (_P_l * (0.3 + sin(d_l)) - _P_r * (0.3 + sin(d_r)))
	dpsi += (n_adv + n_kick - dpsi / p.tau_wc - dpsi / p.tau_sf) * h
	# --- translate: Heun (RK2)
	var heading0 := chi + dpsi
	var a1 := _acc(position, velocity, ws, env, fA, en_l, en_r, alpha_m, true)
	var a2 := _acc(position + velocity * h, velocity + a1 * h, ws, env, fA, en_l, en_r, alpha_m, false)
	var v_new := velocity + (a1 + a2) * (0.5 * h)
	position += (velocity + v_new) * (0.5 * h)
	velocity = v_new
	# --- weathercock feed-forward (D2): the body rotates with its actual path
	var W2 := env.wind_fn.call(position) if env.wind_fn.is_valid() else Vector3.ZERO
	var va2 := velocity - W2
	var gam2 := atan2(va2.y, va2.dot(fh))
	theta += smoothstep(0.5 * p.v_min, p.v_min, _V_lp) * wrapf(gam2 - gam, -PI, PI)
	if assists.stall_protect and _delib_t < 0.35 and not stalled and _V_lp >= 0.5 * p.v_min:   # re-evaluated: the FSM may have tripped
		theta = minf(theta, gam2 + p.alpha_s - deg_to_rad(0.5))
	theta = clampf(theta, -PI / 2, PI / 2)
	_update_chi(va2)
	yaw_rate = (chi + dpsi - heading0) / h                  # telemetry / comfort
	_guard_finite()                                          # restore last good state on NaN; |v| <= 3 V_max

func _acc(x, v, ws, env, fA, en_l, en_r, alpha_m, commit) -> Vector3:
	var p := params
	var W := env.wind_fn.call(x) if env.wind_fn.is_valid() else Vector3.ZERO
	var va := v - W
	var V := va.length()
	var vh := Vector2(va.x, va.z).length()
	var fh := Vector3(-sin(chi), 0, -cos(chi)); var rh := Vector3(cos(chi), 0, -sin(chi))
	var a := Vector3(0, -G, 0) + env.accel
	if V > 1e-4:
		var gam := atan2(va.y, va.dot(fh))
		var alpha := wrapf(theta - gam + env.alpha_bias, -PI, PI)
		var vhat := va / V
		var rp := rh - vhat * rh.dot(vhat)
		var perp := rp.normalized().cross(vhat) if rp.length() > 1e-6 else (Vector3.UP * cos(gam) - fh * sin(gam))
		var lhat := perp * cos(phi) + vhat.cross(perp) * sin(phi)
		var clcd := _cl_cd(alpha, fA, alpha_m)             # 7.5; separation geometry uses alpha_m
		var q := 0.5 * RHO * V * V * env.lift_scale
		var L := q * p.S * fA * clcd.x
		var D := q * p.S * (clcd.y + env.drag_bonus) + p.m * G * 31.0 * pow(maxf(0.0, V / p.v_max - 0.85), 2)
		a += (lhat * L - vhat * D) / p.m
	# flaps (7.7)
	var K := lerpf(p.k_hover, p.k_flap, smoothstep(0.0, 1.0, vh / p.v_min))
	var up_b := Vector3.UP * cos(phi) + rh * sin(phi)
	var r_b := rh * cos(phi) - Vector3.UP * sin(phi)
	var floor_tilt := 0.0
	if assists.flap_floor and p.k_hover < 1.0 and va.y < 0.0 and (_P_l + _P_r) > 0.05 and vh < 0.8 * p.v_min and ws.pitch <= 0.3:
		floor_tilt = deg_to_rad(8) * (1.0 - vh / (0.8 * p.v_min))
	for side in 2:
		var dn := (_P_l if side == 0 else _P_r) * (en_l if side == 0 else en_r)
		var up := (_U_l if side == 0 else _U_r) * (en_l if side == 0 else en_r)
		var e := dn + p.up_gain * up
		if absf(e) < 1e-9: continue
		var d := ws.flap_dir_l if side == 0 else ws.flap_dir_r
		var dh := (r_b * d.x + up_b * d.y - fh * d.z).normalized()
		if floor_tilt > 0.0:
			dh = (dh * cos(floor_tilt) + fh * sin(floor_tilt)).normalized()
		var F := 0.5 * p.m * G * K * e / p.p_ref
		var dv := dh.dot(va)
		if F > 0.0 and dv > 1e-6:
			F = minf(F, 0.5 * p.m * G * p.p_spec * (dn + maxf(0.0, p.up_gain) * up) / p.p_ref_pos / dv)
		a += dh * (F / p.m)
	# side force from the yaw offset: the path follows the body
	if vh > 1e-3:
		a += -rh * (vh * dpsi / p.tau_sf)
	return a
```

`_alpha_cmd` and `_cl_cd` are §7.4 and §7.5, verbatim. `_update_chi(va)` is §7.3 step 1.
`FlightModel.trim()` solves `CL(α_cmd(p)) = mg cos γ/(q S)` with the glide polar for γ,
V and θ, and starts there.

---

## Appendix B: Golden values (prototype, 72 Hz, `normal` assists; `golden.json` seeds)

These are the outputs of the chief designer's prototype of Appendix A: Python, 72 Hz,
120 Hz substeps, the scenario definitions of §14.3, and `normal` assists. They seed
`tests/unit/flight/golden.json`.

**Tolerances for the golden comparison** (the requirement thresholds in §14.3 are
separate and fixed):
- ±10% relative, or ±0.05 absolute for ratios near 1;
- ±1° for angles, ±0.1 s for times, ±0.2 m/s for speeds under 2 m/s;
- exact for event counts;
- ±15% where the value comes from a stroke-sampled flapping scenario (FM-12…FM-18).

The detector in the prototype is unscaled (ω_full = 4.5 at every size). The
normalised forces are identical by construction (§6.4). Prototype sources are not
committed; Appendix A is their algorithm, and §14.3 is their scenarios.

**B.1 Envelope (FM-01, FM-02, FM-27)**

| species | trim V / V_c | glide sink m/s | glide L/D | slowest V / V_min | φ_max ° | n_max | T_ph s |
|---|---|---|---|---|---|---|---|
| sparrow | 0.993 | 1.50 | 5.96 | 1.08 | 74.2 | 4.50 | 4.08 |
| swallow | 0.994 | 1.50 | 6.58 | 1.08 | 73.3 | 4.25 | 4.51 |
| starling | 0.995 | 1.52 | 7.09 | 1.08 | 72.5 | 4.08 | 4.90 |
| pigeon | 0.997 | 1.59 | 8.52 | 1.08 | 70.4 | 3.72 | 6.14 |
| crow | 0.997 | 1.63 | 9.09 | 1.08 | 69.4 | 3.61 | 6.72 |
| gull | 0.997 | 1.68 | 9.74 | 1.08 | 68.3 | 3.51 | 7.43 |
| hawk | 0.998 | 1.72 | 10.10 | 1.08 | 67.6 | 3.45 | 7.91 |
| eagle | 0.998 | 1.84 | 11.30 | 1.08 | 65.6 | 3.33 | 9.40 |

**B.2 Balloon, pitch 0 → +0.5 (FM-03)**

| species | Δh(1.5 s) m | peak m | peak spans | t_peak s | V(3 s)/V0 | final V (= trim) | settle ×T_ph | V_lo / V_min | energy fraction |
|---|---|---|---|---|---|---|---|---|---|
| sparrow | 1.86 | 1.91 | 7.9 | 1.36 | 0.59 | 5.33 | 0.62 | 0.97 | 0.58 |
| swallow | 2.51 | 2.52 | 7.6 | 1.51 | 0.59 | 5.90 | 0.63 | 0.96 | 0.62 |
| starling | 3.06 | 3.11 | 7.8 | 1.65 | 0.58 | 6.40 | 0.63 | 0.95 | 0.65 |
| pigeon | 4.51 | 5.41 | 8.2 | 2.07 | 0.53 | 8.03 | 0.63 | 0.92 | 0.70 |
| crow | 5.05 | 6.67 | 7.0 | 2.26 | 0.50 | 8.79 | 0.63 | 0.92 | 0.72 |
| gull | 5.62 | 8.39 | 6.5 | 2.50 | 0.45 | 9.73 | 0.63 | 0.91 | 0.74 |
| hawk | 5.94 | 9.66 | 6.0 | 2.67 | 0.42 | 10.40 | 0.63 | 0.90 | 0.75 |
| eagle | 6.72 | 14.10 | 6.7 | 3.15 | 0.41 | 12.30 | 0.64 | 0.89 | 0.77 |

**B.3 Nose-down, stall, protection (FM-04, FM-05, FM-06)**

| species | sag V(3 s)/V0 | sag γ(1 s) ° | (a) t_stall s | (a) recovery ×T_ph | (a) loss ×V²/g | (b) stalls / recovery ×T_ph | (c)/(d) stalls | warn @0.6 / 0.85 | sim t_stall s |
|---|---|---|---|---|---|---|---|---|---|
| sparrow | 1.18 | -14.2 | 0.40 | 0.36 | 0.31 | 2 / 0.56 | 0 / 0 | 0.00 / 0.49 | 0.19 |
| starling | 1.16 | -12.6 | 0.40 | 0.36 | 0.30 | 2 / 0.44 | 0 / 0 | 0.00 / 0.49 | 0.22 |
| pigeon | 1.13 | -11.3 | 0.42 | 0.39 | 0.32 | 2 / 0.24 | 0 / 0 | 0.00 / 0.49 | 0.25 |
| crow | 1.12 | -10.9 | 0.42 | 0.40 | 0.32 | 2 / 0.22 | 0 / 0 | 0.00 / 0.49 | 0.26 |
| gull | 1.11 | -10.6 | 0.43 | 0.42 | 0.33 | 2 / 0.31 | 0 / 0 | 0.00 / 0.49 | 0.28 |
| eagle | 1.09 | -9.7 | 0.44 | 0.45 | 0.34 | 2 / 0.46 | 0 / 0 | 0.00 / 0.49 | 0.32 |

**B.4 Roll, turn, rudder (FM-07…FM-10)**

| species | t90 @0.6 s | ψ̇/(g tanφ/V) @0.6 (full) | sink ratio @0.6 | full-input rate °/s (1–3 s) | max yaw rate / accel | flapping full-input rate / perf | release level ×t90 | adverse dψ° k_rud 0 / 1 |
|---|---|---|---|---|---|---|---|---|
| sparrow | 0.43 | 0.999 (0.988) | 1.17 | 198 | 203 / 363 | 1.01 | 1.16 | 0.76 / 0.00 |
| starling | 0.51 | 1.000 (0.991) | 1.17 | 152 | 157 / 253 | 0.96 | 1.16 | 0.77 / 0.00 |
| pigeon | 0.61 | 1.000 (0.991) | 1.17 | 109 | 113 / 167 | 0.92 | 1.14 | 0.74 / 0.00 |
| crow | 0.65 | 1.000 (0.993) | 1.17 | 95 | 99 / 143 | 0.91 | 1.15 | 0.72 / 0.00 |
| gull | 0.69 | 1.000 (0.994) | 1.17 | 81 | 84 / 120 | 0.90 | 1.14 | 0.70 / 0.00 |
| eagle | 0.81 | 1.000 (0.995) | 1.17 | 56 | 59 / 71 | 0.87 | 1.12 | 0.64 / 0.00 |

**B.5 Flapping (FM-11…FM-14, FM-17, FM-18)**

| species | impulse ° flat/17/35/−20 | best climb m/s (× perf) | climb @V_c (× perf) | hover vz / drift | level effort | fwd-flap gain ×V_c @0.4 | one-wing Δψ right ° | one-wing peak bank ° / dψ° |
|---|---|---|---|---|---|---|---|---|
| sparrow | 0/17/35/-20 | 4.35 (1.09) | 3.74 (0.94) | 1.43 / 0.39 | 0.3 | 0.24 | 10.6 | 8.6 / 0.66 |
| starling | 0/17/35/-20 | 4.04 (1.12) | 3.32 (0.92) | 0.33 / 0.72 | 0.3 | 0.26 | 9.0 | 8.3 / 0.81 |
| pigeon | 0/17/35/-20 | 3.60 (1.12) | 2.71 (0.84) | -0.87 / 2.68 | 0.3 | 0.32 | 7.3 | 8.0 / 0.94 |
| crow | 0/17/35/-20 | 3.44 (1.13) | 2.43 (0.80) | -0.88 / 3.41 | 0.3 | 0.35 | 6.7 | 7.9 / 0.99 |
| gull | 0/17/35/-20 | 3.26 (1.13) | 2.12 (0.73) | -0.75 / 4.31 | 0.3 | 0.39 | 6.2 | 7.8 / 1.03 |
| eagle | 0/17/35/-20 | 2.88 (1.13) | 1.42 (0.56) | -1.52 / 5.74 | 0.4 | 0.43 | 5.1 | 7.5 / 1.11 |

**B.6 Updraft, dive, robustness (FM-15, FM-16, FM-19, FM-20, FM-22, FM-23)**

| species | 3 m/s neutral / circling | thermal 4 m/s R44 climb | dive V/V_max (t95 s) | pull-out m (spans), g | dive recovery ×T_ph | energy drift % | fuzz V/V_max (no wind) | body steer t(±5°) s |
|---|---|---|---|---|---|---|---|---|
| sparrow | 1.50 / 2.32 | 3.24 | 0.978 (3.33) | 16.5 (69), 4.38 | 0.77 | 0.0071 | 0.94 | 1.92 |
| starling | 1.48 / 2.28 | 3.10 | 0.987 (3.78) | 26.3 (66), 4.00 | 0.81 | 0.0052 | 0.94 | 2.32 |
| pigeon | 1.41 / 2.20 | 2.76 | 0.995 (4.54) | 45.3 (69), 3.66 | 1.01 | 0.0035 | 0.89 | 3.00 |
| crow | 1.37 / 2.16 | 2.53 | 0.998 (4.92) | 55.7 (59), 3.56 | 1.07 | 0.0030 | 0.85 | 3.33 |
| gull | 1.31 / 2.12 | 2.21 | 1.000 (5.38) | 69.9 (54), 3.47 | 1.12 | 0.0025 | 0.81 | 3.75 |
| eagle | 1.15 / 1.98 | 0.91 | 1.000 (6.67) | 117.0 (56), 3.30 | 1.21 | 0.0016 | 0.71 | 4.99 |

**B.7 Growth, flap bob, frame-rate, frantic flapping, bot window** (raw prototype log lines; `F` = mean vertical flap force in body weights, 2–7 s)

```
growth {step_dv: 0.0271, final_ratio: 0.994}
sparrow   perceived bob cm (raw, sync-filtered): hover (82.5, 21.9) cruise (85.0, 36.3) climb (73.3, 28.4)
starling  perceived bob cm (raw, sync-filtered): hover (73.6, 16.2) cruise (67.0, 24.4) climb (81.4, 27.1)
pigeon    perceived bob cm (raw, sync-filtered): hover None cruise (48.6, 15.2) climb (74.7, 35.8)
crow      perceived bob cm (raw, sync-filtered): hover None cruise (32.1, 9.5) climb (41.5, 16.2)
gull      perceived bob cm (raw, sync-filtered): hover None cruise (21.7, 6.1) climb (29.9, 11.6)
eagle     perceived bob cm (raw, sync-filtered): hover None cruise (10.6, 2.9) climb (16.4, 6.5)
MODEL E_CAP 1.15 HEAVE_TAU 0.0 SUBSTEP 120.0
dt sparrow   noflap 0.98 0.74 1.20 | mixed 0.43 1.16 0.83
dt starling  noflap 0.69 0.53 0.84 | mixed 0.84 0.74 0.89
dt pigeon    noflap 0.36 0.27 0.44 | mixed 0.68 0.10 0.50
dt crow      noflap 0.27 0.21 0.34 | mixed 0.85 0.14 0.60
dt gull      noflap 0.20 0.14 0.27 | mixed 0.27 0.20 0.21
dt eagle     noflap 0.64 0.48 0.80 | mixed 0.79 0.64 0.88
frantic sparrow   ref vz +1.43 drift 0.3 F 1.20 || frantic vz +2.14 drift 0.0 F 1.38
frantic starling  ref vz +0.33 drift 0.7 F 1.04 || frantic vz +1.73 drift 0.4 F 1.19
frantic pigeon    ref vz -0.87 drift 3.2 F 1.01 || frantic vz -0.91 drift 1.2 F 0.96
frantic crow      ref vz -0.88 drift 4.5 F 1.02 || frantic vz -1.58 drift 1.2 F 0.90
frantic eagle     ref vz -1.52 drift 6.8 F 0.94 || frantic vz -2.76 drift 5.3 F 0.97
bot window frac (2x1.5 spans): [0.07, 0.01, 0.07, 0.27, 0.18, 0.08]
```

---

## Appendix C: Implementation order (flight area)

1. `FlightTuning` (+ `.tres`), `FlightParams.derive`, `FlapDetector.reference_effort`.
   Then FM-01, FM-27 and the §8 tables printed and diffed against Appendix B.
2. `FlightModel.step` exactly as Appendix A, plus the L1 suite FM-01…FM-29, until
   golden. Port the prototype's scenario functions one by one; each maps to one FM id.
3. `WingState`, `HumanPoseModel` (and its PoseSynth use), `FlapDetector`, `WingInput`,
   plus the L2 suite. Do the round trip WI-26 first, then WI-01…WI-27.
4. The `PoseSource` family (Scripted, Replay/Recorder, Hybrid, XR, Desktop, Bot), plus
   DSK-01 and SIM-01/SIM-04 (probe the axes before trusting the defaults).
5. `PlayerBird`: rig (§10.3), state machine, body steer, perching, collisions,
   `HeaveSmoother`, telemetry and events. Build the test world, then run PB-01…PB-18.
6. `FlightAutopilot` + `BotPoseSource` + `FlightCourseBuilder` + `FlightPlot`, then
   B1–B3 with a gain-sweep dev test (window leg first, then the landing).
7. `scenes/dev/flight_dev.tscn` (the lab: desktop, bot, XR, hybrid; port note §19) and
   the WingInput gesture plot (`artifacts/flight/wi_channels.png`) in place of
   `flight_vr_dev.tscn`.
   Run SIM-02/SIM-03 in the simulator. Write `docs/areas/FLIGHT.md` with the plots,
   metrics and known limits (§17).

---

## Panel scores

Scale 1–10. "Requirements" means how completely the design meets every user
requirement as written. "Implementability" means GDScript at 90 Hz for the player,
reusable for up to 60 NPCs.

| Panel doc | Requirements | Physical plausibility | VR intuitiveness / comfort | Implementability | Verifiability headless | Mean |
|---|---|---|---|---|---|---|
| **Aerodynamicist** (`flight_aero.md`) | 7 | **10** | 6 | 4 | 9 | 7.2 |
| **VR ergonomics** (`flight_vr.md`) | 7 | 6 | **10** | 8 | 9 | 8.0 |
| **Game feel & test** (`flight_game.md`) | **9** | 7 | 8 | **9** | **10** | **8.6** |

**Aero.** This is the best physics and the best-documented evidence. Blade-element
wings with LEV flap forces make "force along the wing normal" emerge rather than be
imposed, and every gameplay law is ledgered.

Against it:
- It turns raw stroke velocity into force, so shaking produces lift.
- It needs a `SizeRules` contract change for climb.
- It leaves an open one-wing-flap item and allows tumbling.
- Its default chord axis contradicts the measured grip convention.
- Its cost (3–4 substeps × 2–8 wing evaluations, about 30 states) makes it a poor
  runtime for 60 NPCs and a risky port.

It is kept as the physical reference. Its path feed-forward, damper scaling, ledger
discipline, horizon-referenced stroke plane and adverse-yaw test were grafted in.

**VR.** This is the definitive input design. It rests on measured controller axes,
swing-twist pitch, a robust torso estimator with neck-pivot shoulders, a credited flap
detector that rejects shaking, and calibration, fatigue design, haptics that teach,
and first-time-user mitigations. By design, it defers the flight model.

Its skid-turn body steer was rejected in favour of a coordinated bank demand. It is
adopted almost whole for WingInput, pose sources, calibration and comfort.

**Game.** This is the most complete and implementable package. It has a cheap
point-mass model tied to `SizeRules`, named assists with A/B tests, a full state
machine, perching and collisions, and an observables-first test plan with golden
values and a bot pilot. It is the **base** of this spec.

Its latent flaws were found and fixed by prototyping:
- θ-lag collapse at high speed;
- flap-hold coupling;
- a too-sensitive nose-down map;
- stall protection that only clamped the command;
- the flap floor overriding hover-capable birds;
- frantic hover without an endurance limit.

**Synthesis (this spec)** takes the game base, the VR input chain, and the aero
physics grafts, plus prototype-driven fixes. All FM thresholds are confirmed by the
chief designer's prototype. The open items are honest:
- small-bird comfort (R1);
- big-bird bot landing (R4);
- device conventions (R2).
