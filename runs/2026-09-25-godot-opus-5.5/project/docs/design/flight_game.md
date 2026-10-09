# Flight model & controls: game feel, tunability, verifiability

Panel lens: **game-feel designer & test engineer**. This document defines the
gameplay layer on top of the flight physics (assists, size feel, perching,
collisions, the state machine), the data contracts (`PoseSource` → `WingInput`
→ `WingState` → `FlightModel` → `PlayerBird`), one tuning resource, and a test
plan that proves every user requirement headless with numeric acceptance
criteria, trajectory plots and a bot pilot.

Every number below that a test asserts was produced by a Python prototype of
the reference model in §3 (point mass + attitude lags, Heun integration,
72 Hz), run across the species ladder. Appendix A lists those "golden"
values. The GDScript port must reproduce them within the stated tolerances,
which also checks that the port is faithful.

---

## 0. Key decisions (one line each)

1. **Observables first.** Tests pin behaviour a player would notice (balloon
   height, settle time, turn-rate/bank ratio, flap impulse direction, perch
   capture). They do not pin internal variables, so the physics panel can
   change internals without breaking the suite.
2. **AoA is the pitch control and the body attitude follows it.** Wrist chord
   pitch sets a commanded angle of attack. Lift is ½ρV²·S·CL(α)
   perpendicular to the airflow. Ballooning, the speed/AoA trade and stalls
   all come out of the physics; nothing is scripted.
3. **Bank is angle-commanded (auto-level by construction).** Holding a tilt
   holds a bank. Neutral hands level the wings. Rate-command ("real aileron")
   stays available as a tuning flag for an A/B on the Quest Pro.
4. **Coordination is exact by construction.** Lift tilts with bank and the
   body yaw is the air-velocity heading, so sideslip is 0 and
   ψ̇ = L·sinφ/(mV cosγ). An automatic **turn AoA compensation** (0.85) keeps
   level turns near g·tanφ/V (the prototype measured 0.993–1.001 of it).
5. **Flap force is defined in the world/bank frame, not the flight-path
   frame.** Wings flat push along the banked "up"; leading edge down tilts the
   push toward the horizontal heading by 1.3× the chord angle. This is the
   user's requirement taken literally. Flap force is **power-limited**
   (F·v ≤ P_max), so flapping can never turn into a rocket.
6. **The balloon is kept and the phugoid is damped** by a speed-rate
   (u̇) feedback on AoA: +0.4 rad/g when accelerating, +0.1 rad/g when
   decelerating. In the prototype the balloon kept 14–32 % of its kinetic
   energy height at 1.5 s, settled in 0.81–0.85 phugoid periods, never mushed
   below 0.95·V_stall, and recovered from stalls in ≤ 0.6 T_ph.
7. **Soft stall protection:** α ≤ α_stall − 1° unless the player holds full
   nose-up (≥ 0.9) for 0.35 s. Stalls are therefore deliberate, readable and
   recoverable (nose-drop, 15° wing-drop, forced recovery at 1.5 s).
8. **Size is one scalar**, `x = log(m/0.004)/log(4.5/0.004)` (moth 0 …
   eagle 1). Aero constants are *derived* from `SizeRules.performance(mass)`,
   so the player and NPC envelopes match by construction. Feel-only
   parameters are anchors over x in a single `FlightTuning` resource.
9. **Head-centred rig.** `PlayerBird` sits at the eye. Physical head motion
   moves the body through the same collision sweep, and `XROrigin3D` is offset
   so the camera sits exactly at the body. The rig only ever yaws.
10. **Body-steer.** Physically turning your torso (the hand line) is a turn
    demand that does *not* rotate the rig, because you already rotated. Tilt
    turns do rotate the rig. Head look never steers.
11. **Every pose goes through WingInput**, whether it comes from XR,
    scripted/replayed poses, desktop keyboard emulation or the bot pilot. The
    bot flies with `PoseSynth` (WingState → poses), so the full chain is
    exercised headless.
12. **Collisions never kill.** A continuous sphere sweep is followed by
    slide, bounce+stun (0.5–1.5 s) or land. Wingtips never collide; they only
    "brush".

---

## 1. Reading guide and scope

This panelist owns *feel and proof*. §3 gives a complete, prototype-validated
reference physics model so every assist and test has a concrete hook. If the
aerodynamics panel's model replaces it, keep the §2 contracts and re-derive
Appendix A. The tests in §11 are phrased against telemetry and positions.

Units follow ARCHITECTURE §3: metres, kg, s, rad, +Y up, −Z forward.
"Spans" means the bird's wingspan in world metres. "A" means the player's
calibrated real-world arm span (`WingCalibration.arm_span`). Pose data is
always **tracking space in real metres, before `world_scale`**.

---

## 2. Data contracts

### 2.1 PoseFrame and PoseSource

```gdscript
class_name PoseFrame extends RefCounted
## One sample of the player's body in TRACKING space (real metres, not world_scale'd).
var t := 0.0                         # seconds (source clock)
var head := Transform3D.IDENTITY     # eye-centre pose
var hands: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]  # 0 = left, 1 = right, GRIP pose
var tracked := PackedByteArray([1, 1])     # per hand: 1 tracked, 0 lost
var confidence := PackedFloat32Array([1, 1])
var grip := PackedFloat32Array([0, 0])     # 0..1 analog
var trigger := PackedFloat32Array([0, 0])
var menu_pressed := false            # rising edge
var hand_velocity: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]  # optional; ZERO = WingInput differentiates

class_name PoseSource extends RefCounted
func sample(dt: float) -> PoseFrame:   # called once per physics tick
	return null
func is_live() -> bool:                # true for XR (head must never be faked while live)
	return false
func reset() -> void:
	pass
```

| Implementation | Purpose | Notes |
|---|---|---|
| `XRPoseSource` | headset / simulator | Reads `XRServer.get_tracker(&"head"/&"left_hand"/&"right_hand").get_pose(&"grip")`. These are raw tracker poses, unscaled. Verified by test W9 (world_scale invariance). |
| `ScriptedPoseSource` | tests, demos | Evaluates a `PoseScript` (list of timed `PoseClip`s: spread, tuck, twist(l,r), dihedral, sweep, stroke(A,f,duty,chord), look(yaw,pitch), bob, noise). Deterministic from a seed. |
| `ReplayPoseSource` | regression from real sessions | Plays `.poses.jsonl` recorded by `PoseRecorder` (wraps any source). Quest Pro sessions later become regression tests. |
| `DesktopPoseSource` | dev on desktop | Keyboard/mouse drive *virtual arms* that move like real arms (§10). |
| `BotPoseSource` | bot pilot | `Autopilot` → command targets → `PoseSynth` → PoseFrame (§11.4). |
| `HybridPoseSource` | XR simulator runs | Head from `XRPoseSource`, hands from another source. The simulator's controllers are fixed at (±0.29, 1.4, −0.5), so scripted wings are the only way to fly in the simulator. |

The visible wing and hand anchors under `XROrigin3D` are placed from the
*active pose source*, not from `XRController3D`. In the simulator with a
hybrid source you therefore *see* the scripted wings flap.

### 2.2 WingInput → WingState

`WingInput` (RefCounted) owns calibration, body-frame estimation and the
per-wing `FlapDetector`s:
`func update(frame: PoseFrame, dt: float, size_x: float) -> WingState`.

```gdscript
class_name WingState extends RefCounted
# ---- measured geometry (scale-free; index 0 = left, 1 = right) ----
var extension := PackedFloat32Array([1, 1])   # 0 tucked .. 1 spread
var chord := PackedFloat32Array([0, 0])       # rad, leading edge UP positive, calibrated neutral = 0
var elevation := PackedFloat32Array([0, 0])   # rad, hand above shoulder positive
var sweep := PackedFloat32Array([0, 0])       # -1 back .. +1 forward (fraction of reach)
var stroke_speed := PackedFloat32Array([0, 0])# arm spans/s, DOWN positive, relative to the head
var body_yaw := 0.0                           # rad, tracking-space yaw of the wing frame (0 = -Z)
var body_yaw_valid := false
var tracking := 1.0                           # min hand confidence after loss handling
# ---- commands: what FlightModel consumes (NPC autopilots write ONLY these) ----
var pitch := 0.0          # -1..1 symmetric AoA command (+ = leading edges up = slower / balloon)
var roll := 0.0           # -1..1 bank command (+ = right)
var flap := PackedFloat32Array([0, 0])        # per-wing instantaneous stroke power, [-0.1, 1] (unfiltered)
var flap_pitch := PackedFloat32Array([0, 0])  # rad, chord during the stroke -> flap force direction
var spread := 1.0         # 0..1 mean extension -> wing area
var tuck := false         # both wings folded (dive)
var grip := PackedFloat32Array([0, 0])        # 0..1 (cling / perch assist bonus)
func copy() -> WingState
func to_dict() -> Dictionary                   # CSV/plots/replay
```

**Mapping (defaults; the input panel may refine the ergonomics, but the
round-trip test W1 must hold).**

1. *Body frame.* `r̂ = horizontal(R_hand − L_hand)`. The frame is valid when
   the horizontal hand separation is ≥ 0.45·A. When valid,
   `body_yaw` = yaw of `forward = Y × r̂`, low-passed with τ = 0.25 s. When
   invalid (tucked or hands together), hold the last value. If it stays
   invalid for > 2 s, drift toward head yaw with τ = 1 s. Head look is never
   used while the frame is valid.
2. *Shoulders.* `S_side = head + B·(∓sw/2, −shoulder_drop, +0.08)`, where B
   is the body yaw basis (+0.08 puts the shoulder behind the eyes).
   `w = hand − S_side` in the body frame, `reach = (A − sw)/2`.
3. `extension = smoothstep(0.25, 0.85, outward(w)/reach)`, where `outward` is
   ±w.x. Hands forward-and-together therefore read as tucked.
4. `elevation = atan2(w.y, max(outward(w), 0.05))`,
   `sweep = clamp(−w.z/reach, −1, 1)`.
5. *Chord.* `â = normalize(w)`. Take the controller's forward axis f (−Z of
   the grip basis), project it off â, and measure its angle from the
   horizontal in the plane ⟂ â (leading edge up = +). Subtract
   `neutral_roll_side` and mirror the left side.
6. *Stroke speed.* `s = −(v_hand.y − v_head.y)/A`. Subtracting the head
   velocity means crouching or jumping is not flapping. `v` comes from the
   tracker, or from a 2-tap finite difference.
7. *FlapDetector* (per wing, size-aware, prototype-validated):
   - phase switches with hysteresis at ±0.05 spans/s;
   - a downstroke's **raise gate** is `q = smoothstep(r0, r1, raise/A)`, where
     raise = top − bottom of the preceding upstroke;
   - down: `P = q · ramp(s; s0 = 0.20, s1(x))`;
   - up: `P = up_gain(x) · q_prev · ramp(−s; s0, s1)`, gated by the previous
     downstroke's travel, so shaking has **exactly zero** effect either way.
     `up_gain` is +0.30 for x ≤ 0.30 (small birds lift on the upstroke, which
     cuts view bob) and −0.08 for x ≥ 0.60 (feathers open, small cost);
   - `s1(x)` = 1.5 → 0.9 spans/s, `r0(x)` = 0.05 → 0.10 A, `r1(x)` = 0.20 →
     0.40 A. Seated mode scales r0, r1 and s1 by 0.7; a seated ±0.25 m stroke
     then gives 0.93–0.96 of the standing P̄. The effect is that small birds reward
     quick short strokes and big birds reward slow deep ones. In the
     prototype a ±20 cm stroke at 3 Hz gave P_avg 0.32 for a sparrow but
     0.15 for an eagle.
   - `flap_pitch[i] = chord[i]`, sampled continuously.
8. *Pitch command.* `pitch_raw = expo(dead(mean(chord), 3°)/35°, 0.35) +
   0.25·mean(sweep)`. **Sample-and-hold while flapping:** if either wing had
   P > 0 in the last 0.3 s, output the value held at stroke start, blending
   toward live with τ = 0.8 s. Wrist twist during a stroke means *flap
   direction*; between strokes it means *AoA*. Without the hold, pitching
   forward to flap forward would also dive the bird, and the prototype showed
   that coupling is chaotic.
9. *Roll command.* `roll = expo(clamp((chord_L − chord_R)/(2·35°) +
   (elev_L − elev_R)/(2·30°), −1, 1), 0.3)` with a 0.05 deadband. Left leading
   edge up plus right down rolls right, and so does the right arm lower
   (airplane arms).
10. `spread = mean(extension)`. `tuck` is true when both extensions < 0.2 and
    false again above 0.3.
11. *Tracking loss.* A lost hand's values hold for 0.25 s, then decay to glide
    neutral (extension 1, chord 0, flap 0) over 0.5 s. If both hands are lost
    for > 1 s, pitch and roll go to 0 (auto-level glide).

`PoseSynth` (the inverse, used by the bot and tests) takes
`(pitch, roll, spread, sweep, stroke(A, f, phase, chord), look(yaw, pitch))`
and returns a PoseFrame for a default body (head at 1.6 m, A = 1.6,
sw = 0.38). It splits roll 50/50 between twist and dihedral.

### 2.3 FlightModel (pure `RefCounted`, no scene dependencies)

```gdscript
class_name FlightModel extends RefCounted
var tuning: FlightTuning
var params: FlightParams            # derived for the current mass (read-only to callers)
# --- state (world units) ---
var position := Vector3.ZERO
var velocity := Vector3.ZERO
var heading := 0.0      # rad, yaw of horizontal AIR velocity (0 = -Z); body yaw == heading (no sideslip)
var bank := 0.0         # rad, + right
var theta := 0.0        # rad, body pitch attitude (for NPC visuals; NEVER applied to the camera)
var alpha := 0.0        # rad, derived: theta - gamma_air
var stalled := false
var assists := {}       # StringName -> bool, seeded from tuning; tests/settings override

func _init(p_tuning: FlightTuning = null) -> void
func configure(mass: float) -> void                    # re-derive params; state untouched (growth is continuous)
func reset(pos: Vector3, vel: Vector3, p_heading := NAN) -> void
func step(cmd: WingState, dt: float, env: FlightEnv) -> void   # sub-steps internally, dt_sub <= 1/90
func apply_velocity_change(dv: Vector3) -> void        # launch, bounce, external shoves
func solve_glide_trim(pitch_cmd: float, spread := 1.0) -> Dictionary   # {airspeed, gamma, sink}
func body_basis() -> Basis                             # yaw(heading) * pitch(theta) * roll(bank)
func telemetry() -> Dictionary                         # see 2.4 keys + model internals
func last_forces() -> Dictionary                       # {lift, drag, flap, gravity: Vector3, flap_impulse: Vector3 (this step)}
func events() -> PackedStringArray                     # since last call: "stall", "unstall", "flap_peak_l", ...
static func envelope(mass: float, tuning: FlightTuning) -> Dictionary   # derived table row (Appendix A)

class_name FlightEnv extends RefCounted
var wind := Vector3.ZERO            # World.get_wind(body) sampled once per tick
var ground_distance := INF          # m along -Y to layer-1 geometry (ray, <= 2 spans)
var ground_normal := Vector3.UP
var lift_scale := 1.0               # ceiling fade from World (thin air)
var perch_assist := {}              # filled by PlayerBird when a candidate perch exists (see 7.3)
```

`FlightParams` holds the derived constants (S, CL_max, CD0, k_i, α_n, α_s,
φ_max, n_max, T_ph, τ_α, τ_φ, p_max, q_max, A_peak, hover_eff, P_spec, V_c,
V_min, V_max, V_floor, span, r_body, x). Tests read them.

NPC reuse: `NpcBird` may own a FlightModel and drive it with an `Autopilot`
that writes WingState *commands* directly (no poses). **Budget warning:** the
full model is about 2× (2 Heun evaluations) × substeps. Assume ~20–60 µs per
step in GDScript on the Mac, and roughly 3× that on Quest. 60 NPCs at 72 Hz
would cost 26 % of one core. Run NPCs at a decimated rate (24 Hz with
interpolation) or with a LOD, keeping the full model only for NPCs within
~40 m. That call belongs to the AI panel; test F17 records the real cost.

### 2.4 PlayerBird

```gdscript
class_name PlayerBird extends Bird      # scenes/player/player.tscn root
enum Mode { SPAWNING, FLYING, PERCHED, GROUNDED, STUNNED, CAUGHT }
@export var tuning: FlightTuning
@export var auto_process := true        # tests set false and call tick(dt) themselves (fast, deterministic)
var mode: Mode
var model: FlightModel
var wing_input: WingInput
var pose_source: PoseSource             # default: XR if VR.active else Desktop
var wing: WingState                     # last frame's
var perch: Perch                        # when PERCHED
func set_pose_source(src: PoseSource) -> void
func tick(dt: float) -> void            # exactly what _physics_process does
func telemetry() -> Dictionary
func respawn(xform: Transform3D) -> void
func set_controls_enabled(on: bool) -> void
func perch_on(p: Perch) -> void         # forced perch (respawn, tests)
func launch(strength := 1.0) -> void
func set_assist(name: StringName, on: bool) -> void
func is_player() -> bool                # true
func get_body_position() -> Vector3     # == global_position (the eye) — see head-centred rig
func get_forward() -> Vector3           # horizontal flight heading, NOT head look
```

**Scene:** `PlayerBird (Node3D, pausable)` → `XROrigin3D (group player_rig,
ALWAYS)` → `XRCamera3D`, `LeftHand`/`RightHand` (XRController3D), and
`WingAnchors/L,R` (Node3D, placed from the pose source; VR/birds attach the
wing meshes here).

**Head-centred rig (comfort and collision in one rule).**
`PlayerBird.global_position` *is* the eye and the body point. Each physics
tick:

1. `Δhead_world = Basis(Y, rig_yaw) · (head_t − head_{t−1}) · world_scale`
   is added to the body through the collision sweep, so leaning into a wall
   is blocked.
2. The model integrates flight motion. The sweep covers both.
3. In `_process` (render rate), set
   `XROrigin3D.position = −XRCamera3D.position + bob_offset`. The camera's
   local position already includes world_scale. The result is
   camera == body (+ smoothing offset).

Rotating `PlayerBird` (yaw) therefore rotates the view about the eye, never
about the floor. Nothing ever sets pitch or roll on PlayerBird or XROrigin3D,
and test K1 asserts it every tick of every scenario.

The offset update in step 3 lives in PlayerBird's own (pausable) `_process`.
While the game is paused it stops, so the offset freezes and head motion
moves the camera naturally: the view never locks to the body in menus. On
unpause the body re-anchors to the current head, with no sweep and no jump in
the view.

**Body-steer reconciliation (yaw bookkeeping).** R = rig yaw (PlayerBird),
θ_b = WingState.body_yaw, ψ = model heading. The body heading error is
`e = wrap(R + θ_b − ψ)`.

- `φ_body = clamp(1.2·dead(e, 15°), ±0.8·φ_max)`. The bank command becomes
  `roll_total = clamp(roll + φ_body/φ_max, −1, 1)`.
- Rig update per tick: `R += Δψ · (1 − w_b)`. Here
  `w_b = clamp(|φ_body|/max(|φ_cmd_total|, ε), 0, 1)` when φ_body and
  φ_cmd_total have the same sign, and 0 otherwise. A turn driven by the torso
  does not rotate the world (the player already rotated). A turn driven by
  tilt rotates the world. Mixed turns split proportionally.
- Setting `body_steer` (default on). When off, R += Δψ and the torso offset
  is simply tolerated (WingInput still measures in the torso frame).

**`telemetry()` keys.** Contract keys first: `airspeed`, `groundspeed`,
`vertical_speed`, `altitude_agl`, `aoa`, `bank`, `stalled`, `flapping` (0..1,
filtered flap level), `wing_extension`, `tucked`, `perched`, `in_updraft`
(m/s of vertical wind), `g_load` (L/mg), `lift`, `drag`. Additions: `mode`,
`heading`, `gamma`, `theta`, `stall_warning` (0..1 buffet), `flap_l`,
`flap_r`, `flap_power` (W/kg), `ground_effect` (0..1), `perch_candidate`
(bool/dist), `wing_brush_l/r` (0..1), `stun_left` (s), `speed_frac` (V/V_c),
`sideslip` (rad; model 0, rig includes body-steer transient), `assist_*`
flags, `size_x`, `species`.

**Events emitted:**
- `player_flapped(side, strength)` at each downstroke's end (side 0 when both
  wings' peaks fall within 80 ms), strength = peak P;
- `player_stalled` on stall entry;
- `player_collided(impact, normal)` for slides (impact < v_stun) and stuns;
- `player_perched(pos)` for perch *and* ground landings;
- `player_took_off`, `player_spawned`.

---

## 3. Reference flight model (prototype-validated)

### 3.1 Derived per-mass constants

`perf = SizeRules.performance(m)` gives V_c, V_min = 0.45·V_c,
V_max = 2.6·V_c, Ω_max, climb and agility.

```
x      = clamp(ln(m/0.004)/ln(4.5/0.004), 0, 1)
CL_n   = 0.30                          # neutral-wing lift coefficient (trim at V_c)
CL_max = CL_n·(V_c/V_min)²             # = 1.48  -> 1-g stall exactly at V_min
S      = 2 m g /(ρ V_c² CL_n)          # effective wing area, ρ = 1.225
AR     = anchor(aspect, x)  ; k_i = 1/(π·0.85·AR)
CD0    = 1/(4 k_i LDmax(x)²)           # LDmax 6.5 (moth) -> 15 (eagle)
a      = 4.6 /rad ; α_n = CL_n/a = 3.7° ; α_s = CL_max/a = 18.5°
φ_max  = clamp(atan(Ω_max·V_c/g), 55°, 78°)   # sparrow 74°, eagle 66° -> hits perf.turn_rate at cruise
n_max  = 1.05/cos φ_max                         # sparrow 3.84, eagle 2.54
T_ph   = π·√2·V_c/g                              # phugoid period, the time unit for pitch tests
P_spec = (perf.climb + 0.4)/p_ref(x)            # flap power limit per unit weight (m/s)
```

### 3.2 Step (per substep h ≤ 1/90 s)

```
va = v − wind ; V = |va| ; γ = atan2(va.y, |va.xz|)

# α command pipeline (gameplay layer lives here)
α_b  = α_n + pitch·(α_s − 1° − α_n)            if pitch ≥ 0
     = α_n + pitch·(α_n + 5°)                   if pitch < 0        # full down = −5°
α_b += −2°·clamp((0.5 − spread)/0.5, 0, 1)      # tuck-to-dive
α   = α_b·(1 + 0.85·(1/max(cos φ, 0.34) − 1))   # turn AoA compensation (α_b>0)
α  += (u̇/g > 0 ? 0.4 : 0.1)·clamp(u̇/g, −1, 1)  # phugoid damper (u̇ = filtered dV/dt, τ 50 ms); off while stalled
α   = min(α, n_max·m g/(q S f_A a))             # load-factor limit (q = ½ρV², f_A = 0.25+0.75·spread)
α   = min(α, α_s − 1°)  unless deliberate: pitch ≥ 0.9 held ≥ 0.35 s → α = α_s + 4°·pitch
if stalled: α −= 12°/s·t_stall ; if t_stall > 1.5 s: α = min(α, α_s − 3°)

# attitude: θ is the state; α follows the flow
θ_hi = lerp(0°, 90°, smoothstep(0.5, 1.2, V_h/V_min))    # no tail-stands without airspeed (hover posture)
θ_cmd = clamp(γ + α, −90°, θ_hi)
θ += clamp((θ_cmd − θ)/τ_α, ±q_max)·h ; α = θ − γ

# stall state machine (hysteresis)
enter: α > α_s + 0.5° ; exit: t_stall > 0.3 s and α < α_s − 3°

# bank (angle command, auto-level)
φ_cmd = roll·φ_max + 18°·(flap_L − flap_R) + stalled·(15°·side·smoothstep(0, 0.5, t_stall))
φ    += clamp((clamp(φ_cmd, ±φ_max) − φ)/τ_φ, ±p_max)·h

# forces (Heun / RK2: evaluate at v and at v + a·h, average)
lift dir  l̂ = rotate(perp_up(va), φ about v̂a)   # coordinated: lift tilts with bank
CL(α)     = a·α (|α| ≤ α_s); post-stall: 0.6·CL_max, blending to flat plate sin 2α by α_s+20°
CD        = CD0·(0.35 + 0.65 f_A) + f_A·k_i·CL² + 1.5·min(|α|−α_s, 6°) + 1.8 sin²α·smoothstep(α_s, α_s+15°, |α|)
L = q S f_A CL·lift_scale ; D = q S CD + m g·31·max(0, V/V_max − 0.85)²   # soft speed cap
flap (per wing i): P_i = LP(cmd.flap[i], τ_f(x))                        # smoothing (comfort, §9)
     δ_i = clamp(−1.3·flap_pitch_i, −10°, 45°) (+ floor assist, §4)
     d̂_i = up_bank·cos δ_i + heading_h·sin δ_i        # WORLD/bank frame: flat = straight up
     F_i = ½ m g A_peak(x) P_i · eff(V),  eff = lerp(hover_eff(x), 1, min(1, V/V_min))
     if P_i>0 and d̂_i·va > 0: F_i = min(F_i, ½ m g P_spec P_i/(d̂_i·va))   # power limit
F = m g·(−Y) + L l̂ − D v̂a + Σ F_i d̂_i + ground_effect (§4)
```

Why the non-obvious parts are there (each was found with the prototype):

- *World-frame flap direction plus power limit.* In the flight-path frame,
  flat flapping steepened the climb, tilted the push backward and stalled the
  bird into a hover at 2–3 m/s at every size. Force in the world frame
  *without* a power limit produced 13–28 m/s vertical rockets. With both, the
  steady climb came to 3.0–4.2 m/s at 5–19 % above `perf.climb`, and
  pitching the flap forward monotonically trades climb for speed.
- *θ as a state and α = θ − γ.* If α is a lagged state, a tail-slide (flow
  reversal) leaves α at nonsense values (68°). With θ as the state, a
  hammerhead stall behaves physically.
- *Hover posture θ_hi.* Without it, a bird rising vertically on flaps got
  "gliding" lift perpendicular to the vertical flow, which pushed it
  sideways.
- *u̇ damper instead of a high-pass γ damper.* The γ-based damper fought
  every dive pull-out (the pigeon lost 126 m after a stall). The u̇ damper
  acts only on speed *change*, has zero steady-state bias with flapping or
  thermals, and helps both balloon settle and stall recovery.
- *Heun integration.* Explicit Euler added 2–5 % energy in 30 s of turning at
  72 Hz, because a force perpendicular to v grows |v|. Heun measured
  ≤ 0.0006 % in 60 s.
- Filters use `1 − exp(−h/τ)`, not `h/τ`. The input schedule in tests is
  indexed by tick, not by an accumulated float t. With both, the 72/90/120 Hz
  error vs a 720 Hz reference is ≤ 1.1 % of path length.

---

## 4. Assists: remove frustration, keep the relationships

Every assist is a named flag in `FlightModel.assists`, has an explicit
strength in `FlightTuning`, and has an A/B test showing both that it helps
and that the real relationship survives. The Settings key `flight_assist`
selects 0 = "sim" (all off except the physics safety set: speed cap,
attitude limits, stall hysteresis), 1 = normal (default) or 2 = novice.

| Assist | Frustration it removes | Mechanism (default) | Relationship preserved | Test |
|---|---|---|---|---|
| `auto_level` | holding the wings level precisely by hand | bank is angle-commanded; neutral hands → φ→0 with τ_φ | roll still needs differential lift; rate limit p_max(x) | F6 |
| `turn_comp` | losing height in every turn | α ×(1 + 0.85·(sec φ − 1)) | turns still cost energy (sink ×1.10–1.15 at 45°), capped by n_max and stall | F5 |
| `phugoid_damper` | endless porpoising after a pitch change | +0.4/0.1 rad per g of u̇ | balloon still happens (≥ 0.14 E_k height), new trim = physics trim | F2 |
| `stall_protect` | accidental stalls from sloppy wrists | α ≤ α_s − 1° unless full nose-up held 0.35 s; `stall_warning` buffet from α_s − 4° | deliberate stalls still happen and cost height (≈ 0.4 V²/g) | F4 |
| `nlimit` | violent zooms from small wrist twitches at speed | α capped for n ≤ 1.05/cos φ_max | a steep AoA step still balloons | F2 |
| `flap_floor` | flapping with wings flared, bird slowing to a stall-fall | when flapping, V < 0.8 V_min and pitch ≤ 0.3: flap direction +8°·(1 − V/V_floor) forward | off while flaring (pitch > 0.3) so hover-braking to land still works; +8° is inside the 10° "flat" tolerance | F7 |
| `flap_hold` | flap direction and AoA fighting each other | sample-and-hold pitch during strokes (WingInput) | between strokes wrist = AoA again | W5 |
| `flap_smoothing` | bobbing view, VR discomfort | LP τ_f(x) 0.30 → 0.22 s; small-bird upstroke lift; view bob smoothing (§9) | same mean force; t50 latency 0.25–0.31 s (vs 0.15–0.18 raw) | K3 |
| `speed_cap` | runaway dives, fairness with NPC envelopes | overspeed drag from 0.85·V_max | tuck still accelerates to V_max (0.95–1.0·V_max reached) | F14 |
| `ground_cushion` | face-planting while skimming grass or water | h < 0.5 span, v_y < 0, γ > −35°: a_up = 0.6 g(1 − h/0.5span)²·min(1, −v_y/2); induced drag ×(1 − 0.5(1 − h/span)²) for h < span | steep dives still hit the ground (stun) | F16 |
| `perch_assist` | pixel-perfect landings | ≤ 4 spans from a free fitting perch, ahead ±50°, V ≤ 1.6·V_cap: steer ≤ 0.4 g toward the approach line, auto-flare toward V_cap | too fast is still too fast (bounce); grip widens the window | P7 |
| `wing_brush` | wings clipping thin geometry | wingtips never collide; ray probes nudge the roll away (≤ 10°/s) and emit a brush | body still collides | C7 |
| `body_steer` | fighting the torso after turning in the room | torso yaw → bank demand, no rig yaw for that part | coordinated turn physics unchanged | K5 |
| `tracking_glide` | tracking loss → crash | hold 0.25 s, decay to neutral, auto-level | none | W7 |
| no-loop limits | disorientation (view never pitches) | θ ∈ [−90°, 90°], abs(φ) ≤ φ_max < 80° | vertical stoops still allowed | F12 |
| `stun` instead of death | frustration of instant death | bounce + 0.5–1.5 s stun | collisions still cost speed, time and exposure to predators | C3 |

Novice preset (2): turn_comp 1.0, perch assist 6 spans and 0.6 g, cushion
0.8 g, deliberate-stall hold 0.6 s, body_steer deadband 20°. Sim preset (0)
is used by the pure-relationship tests (F10 energy, F18 textbook turn).

---

## 5. How the sizes feel different

Prototype values from Appendix A. "Perceived ×" = 1/world_scale when
world_scale = span/A. This is the VR panel's call; see §12.

| | sparrow (start) | pigeon | eagle (apex) |
|---|---|---|---|
| cruise / stall / dive cap (m/s) | 9.0 / 4.0 / 23.4 | 13.6 / 6.1 / 35.2 | 20.7 / 9.3 / 53.9 |
| max bank → turn rate at cruise | 74° → 238°/s | 70° → 123°/s | 66° → 62°/s |
| roll rate / bank t90 (roll 0.6) | 343°/s / 0.42 s | 248°/s / 0.61 s | 150°/s / 0.79 s |
| glide L/D neutral / min sink | 6.0 / 0.54 m/s | 8.5 / 0.64 | 11.3 / 0.81 |
| 3 m/s thermal, no flap (neutral / min-sink) | +1.50 / +2.46 m/s | +1.43 / +2.36 | +1.24 / +2.19 |
| best sustained flap climb (target) | +4.2 (4.0) | +3.7 (3.2) | +3.0 (2.5) |
| hard flat flapping from a standstill (flared) | hovers: +2.7 m/s straight up, drift 0.2 m/s | cannot hover: sinks −1.2 m/s at zero airspeed, climbs +3.7 once moving | sinks −1.5 m/s; must dive for airspeed (hover_eff 0.35) |
| balloon (pitch 0 → 0.5): Δh at 1.5 s / peak | +1.3 m / +1.4 m at 1.8 s | +2.5 / +4.6 at 2.7 s | +3.2 / +12.8 at 4.1 s |
| favoured stroke | quick, short (±20 cm at 3 Hz works) | medium | slow, deep (≥ 30 % A raise) |
| turning circle at 45° bank (R = V²/g) | 8 m (33 spans) | 19 m (28 spans) | 44 m (21 spans) |
| perceived speed ×1/world_scale (if ws = span/A) | 60 "human m/s" | 33 | 16 |

The sparrow is floaty (sink 0.54 m/s at 4.5 m/s), nimble, hovers with hard
flapping and flutters. The eagle is heavy: it cannot hover, needs airspeed
before flapping works (hover_eff 0.35), has slow roll, a 44 m turning circle
and a huge balloon (it zooms 12 m on a pitch step). It is the best soarer: to
thermal it must slow to about 10–12 m/s and circle at R ≈ 19–24 m (30° bank). The
world panel should build thermal cores of at least 40–50 m radius where
eagles are meant to soar.

---

## 6. FlightTuning (the single tuning resource)

`scripts/flight/flight_tuning.gd` (`class_name FlightTuning extends
Resource`) with defaults in `scripts/flight/flight_tuning_default.tres`. Group
the exported fields as follows:

- **aero (global):** `rho 1.225, cl_neutral 0.30, lift_slope 4.6, oswald 0.85,
  stall_cl_drop 0.4, stall_cd_slope 1.5, post_stall_blend_deg 6/20, overspeed_start 0.85,
  overspeed_k 31`
- **control:** `pitch_full_deg 35, pitch_dead_deg 3, pitch_expo 0.35,
  pitch_down_deg 5, sweep_pitch 0.25, roll_full_twist_deg 35, roll_full_dih_deg 30,
  roll_expo 0.3, roll_mode ANGLE|RATE, tuck_alpha_bias_deg -2, theta_min -90,
  theta_max 90, theta_hover 0, flap_hold_s 0.3, flap_hold_tau 0.8`
- **stall:** `margin_deg 1, deliberate_cmd 0.9, deliberate_hold_s 0.35,
  deliberate_over_deg 4, exit_hyst_deg 3, min_time 0.3, nose_drop_dps 12,
  force_recover_s 1.5, wing_drop_deg 15, warn_from_deg 4`
- **assists:** `turn_comp 0.85, ud_k_pos 0.4, ud_k_neg 0.1, ud_tau 0.05,
  n_margin 1.05, floor_deg 8, floor_frac 0.8, cushion_g 0.6, cushion_h_spans 0.5,
  ge_h_spans 1.0, ge_induced 0.5, perch_radius_spans 4, perch_accel_g 0.4,
  perch_cone_deg 50, body_steer_gain 1.2, body_steer_dead_deg 15`
- **flap:** `dir_gain 1.3, dir_min_deg -10, dir_max_deg 45, up_cost 0.08,
  roll_kick_deg 18, s0 0.20, phase_hyst 0.05, seated_scale 0.7`
- **perch & ground:** `capture_spans 0.6, v_cap_frac 0.6, grip_bonus 1.4,
  launch_fwd_frac 0.6, launch_up_frac 0.35, launch_min_power 0.35,
  reperch_block_s 0.4, ground_land_frac 0.7, big_takeoff_strokes 2 (x > 0.64)`
- **collision:** `slide_min 0.5, stun_frac 0.35, stun_min_mps 2.0,
  glance_deg 25, restitution 0.25, tangent_keep 0.92, stun_bounce_keep 0.3,
  stun_min_s 0.6, stun_max_s 1.4, brush_nudge_dps 10`
- **comfort (read by PlayerBird):** `bob_smooth_tau 0.4, bob_clamp_spans 0.5,
  bob_pos_tau 1.0`
- **per-size anchors:** `curves: Dictionary[StringName, PackedVector2Array]`
  of `(x, value)` points, piecewise-linear:

| key | moth x=0 | sparrow .287 | pigeon .636 | eagle 1 |
|---|---|---|---|---|
| aspect | 4.5 | 5.36 | 6.41 | 7.5 |
| ld_max | 6.5 | 8.94 | 11.9 | 15 |
| flap_peak_g (A_peak) | 4.4 | 4.0 | 3.31 | 2.6 |
| hover_eff | 1.0 | 1.0 (to x .44) | 0.77 | 0.35 |
| climb_extra (m/s) | 0.4 | 0.4 | 0.4 | 0.4 |
| p_ref (reference-stroke P̄, computed by W4) | ≈0.46 | 0.46 | 0.32 | 0.33 |
| tau_alpha (s) | 0.08 | 0.112 | 0.150 | 0.19 |
| pitch_rate (°/s) | 400 | 320 | 222 | 120 |
| tau_bank (s) | 0.12 | 0.186 | 0.266 | 0.35 |
| roll_rate (°/s) | 420 | 343 | 248 | 150 |
| flap_tau (s) | 0.30 | 0.30 | 0.26 | 0.22 |
| up_gain | +0.30 | +0.30 | −0.08 | −0.08 |
| stroke_s1 (spans/s) | 1.5 | 1.33 | 1.12 | 0.9 |
| raise_r0 / r1 (×A) | .05/.20 | .064/.257 | .082/.33 | .10/.40 |

API: `sample(key, mass) -> float`, `derive(mass) -> FlightParams`,
`hash() -> String` (short content hash, printed in every test report so
metrics can be tied to a tuning), `apply_preset(level)`. `p_ref` must equal
the mean P of the *reference stroke* (±0.40 m at 1.3 Hz, 45 % down) through
WingInput; test W4 enforces it, which keeps the detector and the model
consistent. Hot reload: the flight lab re-reads the `.tres` on F5 and calls
`configure(mass)`. Tuning never lives in code constants.

---

## 7. State machine

```
             respawn()                         flap P≥0.35 (or tuck=drop)
 [SPAWNING] ──0.5 s──> [PERCHED] ─────────────────────────────> [FLYING]
                          ^  ^                                   │  │  │
      capture (7.3)       │  └───────── capture ─────────────────┘  │  │
                          │                                         │  │ head-on impact ≥ v_stun
 [GROUNDED] <── soft ground contact (V ≤ 0.7 V_min, n.y > 0.7) ─────┘  v
     │  flap P≥0.5 (x>0.64: 2 strokes within 1.2 s) ──> FLYING   [STUNNED] ──t_stun──> FLYING
     │                                                              (if on ground → GROUNDED)
 any ──GameLoop: on_caught──> [CAUGHT] ──respawn()──> SPAWNING
 set_controls_enabled(false): mode unchanged; WingState replaced by neutral glide (auto-level)
 Game PAUSED: tick() not called (pausable); XROrigin3D/camera/hands keep updating (ALWAYS)
```

### 7.1 FLYING
The model runs. Flags: `stalled`, `tucked`, `flapping`, `in_updraft`,
`ground_effect`, `perch_candidate`. Events come from `model.events()`.

### 7.2 PERCHED / GROUNDED
The body is locked to `perch.position + Y·r_body` (or the ground contact
point), velocity is 0, and the heading keeps its current yaw: the view is
never rotated to face the perch. Head motion moves the camera but not the
anchor, with a ±0.5 m real-world leash scaled by world_scale.
`Perch.occupant = self`, released on launch.

**Launch:** a downstroke with P ≥ 0.35 applies
`Δv = heading·0.6·V_min + Y·0.35·V_min·P`, then normal flight. Perches are
ignored for 0.4 s so you don't re-perch or collide with the branch you left.
**Drop-launch:** tuck while perched releases you with v = 0 and you fall into
flight (big birds fall to gain speed). On the ground, big birds (x > 0.64)
need two strokes within 1.2 s ("running take-off"), which makes perching high
matter.

### 7.3 Perch capture and assist
The candidate perch is the nearest free perch with `fits(span)` from
`World.find_perches(pos, 4 spans, span)`, within ±50° of the velocity
direction.

**Capture** requires all of:
- `|body − perch| ≤ max(0.6 span, 2 r_body)`;
- relative speed ≤ `V_cap = 0.6·V_min` (×1.4 with grip > 0.5);
- approach not from below (`v_y ≥ −V_cap`);
- perch free.

Capture eases the body onto the perch over 0.15 s with no view rotation, then
emits `player_perched`. A perch that is too fast, occupied or too small acts
as ordinary geometry: C-rules apply and the bird bounces.

The **assist** (when enabled and a candidate is within 4 spans, V ≤ 1.6
V_cap) adds, in FlightEnv:
- a lateral and vertical acceleration toward the line through the perch
  along its approach direction (PD, capped at 0.4 g);
- an auto-flare Δα that brings V down linearly to V_cap at the perch (capped
  so α ≤ α_s − 1°).

The swoop technique works for big birds: approach 1.4 V_min about
`0.35(V² − V_cap²)/g` below the perch and flare. The balloon mechanic is also
the landing tool.

### 7.4 STUNNED
Inputs are ignored and the model runs a limp configuration: pitch 0, roll 0,
spread 0.6, no flaps. Duration is
`clamp(0.6 + 0.8·(v_n − v_stun)/V_c, 0.6, 1.4)` s. On exit, controls fade in
over 0.4 s. The bird stays catchable (GameLoop decides). Haptics and audio
key off `player_collided`.

### 7.5 SPAWNING / respawn(xform)
`respawn` resets the model (v = 0), clears stall, filters, holds and stun,
places the body (the eye) at `xform.origin`, sets rig yaw from `xform`
(yaw only), perches on the nearest fitting perch within 1 span if one exists
(otherwise hovers in SPAWNING for 0.5 s), and emits `player_spawned`. The yaw
jump is allowed here; VR fades.

---

## 8. Collisions

- **Sweep:** each tick, the motion `Δ = Δflight + Δhead` is swept with
  `PhysicsDirectSpaceState3D.cast_motion` using a `SphereShape3D`
  (r = `body_radius_for_mass` = 0.16 span) against layer 1 (world) and
  layer 2 (perch colliders, when not in the perch-ignore window). On a hit,
  move to `safe_fraction`, then take the normal from `get_rest_info` at the
  contact. Up to 3 slide iterations per tick. Afterwards, depenetrate with
  `intersect_shape` + push-out if overlapping (tolerance 1 mm).
- **Classify** with `v_n = −v·n` and `v_stun = max(0.35·V_c, 2 m/s)`:
  - `v_n < 0.5` gives a silent slide.
  - `v_n < v_stun`, or a glancing hit (incidence < 25°) with `v_n < 0.7 V_c`,
    slides: remove v_n, keep 92 % of the tangent, and emit a small
    `player_collided`.
  - A surface with `n.y > 0.7`, `V ≤ 0.7 V_min` and `v_n ≤ V_cap` lands
    (GROUNDED).
  - Anything else stuns: `v = 0.3·v_t + 0.25·v_n·n` (bounce), then STUNNED.
- **Thin geometry:** wires and twigs are `CylinderShape3D`/`CapsuleShape3D`
  with radius ≥ 1 cm. The sweep is continuous, so there is no tunnelling at
  any speed. Test C1 checks this with 1000 random shots, because Jolt's
  cast_motion against thin shapes must be verified, not assumed.
- **Wing brush:** each tick, cast rays from the body to ±right·0.5·span·spread
  (layers 1+2). A hit at fraction f sets `wing_brush_side = 1 − f`, nudges the
  bank away at ≤ 10°/s·(1 − f), and emits a haptic brush (via
  `player_collided` with impact 0 and the ray normal). Wings never stop the
  bird.
- **Camera safety:** body sphere ≥ camera near-plane sphere
  (0.05·world_scale), so the view never clips into walls (test K4).

---

## 9. Comfort guarantees owned by flight

1. **Yaw-only rig.** No code path writes pitch or roll to PlayerBird or
   XROrigin3D. Body pitch θ and bank φ exist only for visuals and telemetry.
2. **Yaw continuity.** The rig yaw rate is the coordinated turn rate. Bank
   is first-order with a rate limit, so the yaw rate ramps. Max yaw
   acceleration at full input: sparrow ≈ 1200°/s², pigeon 450, eagle 170.
   The opt-in Settings `gentle_turns` puts the roll command through an extra
   first-order stage (τ_φ/2), which cut these by ~25 % in the prototype.
   Physics is unchanged and the cost is a slower turn entry. Step changes in
   yaw are allowed only on respawn and are flagged.
3. **Flap bob.** The force is smoothed (τ_f), small birds get upstroke lift,
   and the *view* uses velocity-feed-forward smoothing: `v_s = LP(v_y, 0.4 s)`,
   `y_view += v_s·dt + (y_body − y_view)·(1 − e^{−dt/1.0})`, clamped to
   ±0.5 span of the body. This removes the stroke ripple without lagging
   climbs. A plain low-pass lagged 2 m in a climb and pinned to the clamp.
   Prototype perceived bob (world ripple/world_scale, hard strokes) with all
   three: sparrow ±13 cm hover / ±13 cm cruise flapping, starling ±14/±10,
   pigeon ±11/±8, crow ±7/±5, gull ±6/±3, eagle ±6/±1. Without them, the
   sparrow bobbed ±200 cm. Setting `flap_bob_smoothing`
   defaults to on.
4. **No loops, no inverted flight, no forced view changes** on perch or
   stall.

---

## 10. Desktop emulation (`DesktopPoseSource`)

The desktop source animates **virtual arms**. It does not inject WingState;
it produces hand and head transforms that WingInput reads like any other
pose source.

| Input | Arm motion synthesized | Result through WingInput |
|---|---|---|
| mouse move (captured) | head yaw/pitch (look) | look only; never steers |
| W / S (hold) | both wrists twist leading edge down/up, ramping 120°/s to 35°, returning with τ 0.15 s | pitch −/+ (dive / balloon, stall if S held with Ctrl) |
| A / D (hold) | opposite twists (±30°) + arm dihedral (±12 cm) | roll left/right |
| Space (tap/hold) | a real stroke: hands rise 0.4 m then sweep down, 1.3 Hz while held | symmetric flap. The chord during the stroke follows W/S, so W+Space flaps forward. |
| Q / E | a left-only / right-only stroke | one-wing flap: flick bank away, half the thrust |
| mouse wheel | stroke amplitude 0.15–0.45 m (gentle ↔ hard) | flap power |
| Left Shift (hold) | hands pull in to 15 % extension | tuck / dive |
| Ctrl + Left Shift | hands swept back 40 % | partial tuck (speed) |
| G / right mouse | grip both | perch cling bonus |
| Z / X | torso yaw −/+ 20° (hand line rotates) | body-steer demo |
| Tab | toggle arm gizmos + telemetry overlay | debug |
| F5 / [ / ] | reload tuning / previous / next species mass | lab only |

A gamepad mapping (left stick = twist/dihedral, RT = stroke amplitude,
LT = tuck) uses the same arm animator.

---

## 11. Test plan

### 11.1 Harness

- **Layers:**
  - L1 pure `FlightModel` (WingState commands, no scene; microseconds);
  - L2 `WingInput` (PoseFrame in, WingState out);
  - L3 `PlayerBird` in a generated test world (collision, perch, rig);
  - L4 bot course (pose → everything);
  - L5 XR simulator smoke.
- **Speed and determinism.** L3/L4 set `auto_process = false`. A driver node
  calls `player.tick(1/72.0)` N times inside one `_physics_process`
  callback. The world is static, so direct space queries are valid.
  4320 ticks (60 s of flight) run in about 1 s. Inputs are scheduled by tick
  index. RNGs are seeded. No test reads the wall clock.
- **Scenario library** `tests/unit/flight/flight_scenarios.gd` holds named
  scenarios `{mass, start (trim|rest|pos,vel), schedule: [(t0, t1, cmd)],
  env, assists}`. The same scenarios drive the unit asserts, the golden
  comparison (Appendix A values in `golden.json`, each with a tolerance) and
  the plots.
- **Artifacts:** `artifacts/flight/<test>.csv` (t, pos, vel, V, γ, α, θ, φ,
  heading, flap_l/r, pitch, roll, mode, events) and `<test>.png` (§11.5).
  `metric()` records every thresholded number together with the tuning hash.
- **Runtime budget:** L1 < 10 s, L2 < 5 s, L3 < 20 s, L4 < 20 s. The whole
  suite stays < 60 s. The fuzz runs 600 simulated s per size, which costs
  ~0.1 s of wall time per size.

### 11.2 Requirement → test matrix

Unless stated, tests run for the sparrow (0.03), pigeon (0.35) and eagle
(4.5) at 72 Hz with assists at default. Thresholds carry ≥ 20 % margin over
the prototype values in Appendix A. Rows marked † are scene-level (collision,
perch, rig, input devices) and had no prototype. Their thresholds are design
targets to confirm in the port. Everything else was simulated.

| Req. (user words) | Test | Scenario | Acceptance |
|---|---|---|---|
| Flapping produces lift | F7a | from rest (detector primed): flat hard strokes, pitch 0.5 | x ≤ 0.44: Δh(5 s) ≥ +8 m (proto ≈ +13); every size: mean flap force ≥ 0.9·(A_peak·p_ref·g·eff) |
| Lift direction by wing angle: flat → vertical | F7b (white-box) | one stroke, chord 0, V ≥ V_floor | ∠(∫F_flap dt, banked up) ≤ 2° |
| … leading edge down → up + forward | F7c | one stroke, chord −14° / −20° | forward/vertical of ∫F_flap = tan(1.3·chord) ± 0.02, i.e. ≥ 0.30 at −14° (req ≥ 0.25) and ≥ 0.45 at −20° |
| … behaviourally | F7d | 8 s moderate strokes (±0.22 m, 1 Hz) at chord 0 vs −20° from cruise | v_h(−20°) ≥ v_h(0°) + 0.1·V_c (proto +2.7/+1.6/+3.0 m/s) and vz(0°, hard) ≥ vz(−30°, hard) − 0.3 |
| Speed via AoA; balloon | F2 | trimmed glide, pitch 0 → 0.5 step | Δh(1.5 s) ≥ 0.9 / 1.8 / 2.2 m; V(3 s) ≤ 0.70·V0; V(20 s) = trim prediction ±5 %; settle (V ±5 %, γ ±2°) ≤ 1.1·T_ph = 4.5 / 6.7 / 10.3 s; V_min in transient ≥ 0.9·V_stall; h(3·T_ph) < h_peak (temporary) |
| … leading edge down speeds up | F3 | pitch 0 → −0.5 | V(3 s) ≥ 1.12·V0 (proto +37/+26/+17 %); γ(1 s) ≤ −8° |
| Too much AoA stalls; recoverable | F4 | (a) slow-flight trim pitch 0.8, hold 1.0 for 2 s, release to 0; (b) cruise, hold 1.0 for 3 s, release; (c) pulses of 1.0 < 0.3 s every 0.5 s for 6 s; (d) hold 0.85 for 6 s | (a) stall within 1.0 s (proto 0.44–0.53), `player_stalled` once, recovered (γ within 5° of trim γ, V within 15 %, not stalled) ≤ 0.8·T_ph (proto ≤ 0.55), altitude lost ≤ 0.6·V_t²/g (proto ≤ 0.45); (b) recovered ≤ 0.8·T_ph (proto ≤ 0.58); (c, d) never stalled; `stall_warning` ≥ 0.15 in (d) (≈ 0.22 expected) and 0 at pitch ≤ 0.6 |
| Opposite tilts → coordinated turn | F5 | roll 0.6 (via twist only, through WingInput at L2+L1) | bank reaches 90 % of 0.6·φ_max within 0.5 / 0.75 / 1.0 s; ψ̇ / (g tanφ/V) ∈ [0.90, 1.10] for t > 1.5 s (req 20 %; proto 0.993–1.001); model sideslip ≤ 0.5°, rig sideslip (body_steer off) ≤ 2°; sink ≤ 1.25× straight glide |
| … auto-level on release | F6 | roll 0.6 for 3 s → 0 | abs(φ) < 3° within 2·t90; heading rate < 2°/s within 3·t90 |
| … airplane-arms dihedral banks too | F6b | dihedral only (right hand 0.3 m lower) | same bank direction as twist-right; bank ≥ 0.4·φ_max |
| Turn envelope = SizeRules | E1 (all 10 species) | derived table + runs | glide speed at neutral = perf.cruise ±5 %; slowest steady speed at protected α = perf.min_speed ±10 %; tucked nose-down top speed ∈ [0.95, 1.03]·max_speed; max-bank turn rate at cruise = perf.turn_rate ±15 %; best sustained flap climb = perf.climb +0…+25 %; t90 roll monotonically increases with mass |
| Updrafts lift without flapping | F9 | uniform 3 m/s updraft, no flap, (a) neutral straight, (b) pitch 0.6 circling at 30° bank | (a) climb ≥ +0.8 m/s all sizes (proto +1.24…+1.50); (b) climb ≥ +1.6 m/s (proto +2.00…+2.32); `in_updraft` telemetry = 3 ± 0.01 |
| … ridge/thermal as World wind field | F9c | a Gaussian thermal from a stub World (core 3 m/s, σ 40 m); bot circles | eagle at pitch 0.6, 30° bank: net climb ≥ +1.0 m/s over 60 s (estimate +1.4) |
| Real-aerodynamics relationships | F10 | drag, flaps and speed cap off, random pitch/roll every 0.5 s, 60 s | energy drift ≤ 0.5 % (req 2 %; proto 0.0006 %; Euler would fail at 2–5 %) |
| | F18 | sim preset, 45° bank level turn | ψ̇ = g tanφ/V ±2 % while L cosφ = mg ±2 %; load factor = 1/cosφ ±2 % |
| | F11 | glide sink vs speed sweep (pitch −0.3…1.0) | polar is U-shaped; min sink at CL ≈ min(√(3·CD0/k_i), CL(α_s − 1°)) ±15 %; best L/D = LDmax(x) ±10 % (true by construction at full spread) |
| Growth changes characteristics | F13 | mass 0.03 → 0.06 step mid-glide; then continuous ramp 0.03 → 4.5 over 60 s | no velocity jump (abs(Δv) over the tick ≤ 1e-4); no NaN; trim V tracks perf.cruise(m) within 10 % after 2·T_ph; φ_max, n_max, t90 monotonic |
| Big = faster, wider, more momentum | E2 | derived table | V_c, R_turn(45°), T_ph, t90 strictly increase with tier; hover capability (F7e) true for tiers ≤ starling, false for ≥ pigeon |
| Robustness | F12 | fuzz: random commands incl. out-of-range values (±1.5, spread 1.2, flap −0.2…1.5, chord ±2 rad), dt ∈ {1e-4, 1/90, 1/72, 1/30, 0.1}, wind spikes ±8 m/s, start states incl. vertical up/down and V = 0 | 0 NaN/inf; V ≤ 1.05·V_max (proto ≤ 0.96); θ ∈ [−90°, 90°], abs(φ) ≤ φ_max |
| Frame-rate independence | F15 | maneuver schedule (tick-indexed), 30 s at 72/90/120 Hz vs 720 Hz | final position error ≤ 1.5 % of path (proto ≤ 1.1 %) |
| Determinism | F17a | same scenario twice | bit-identical CSV |
| Shaking yields no climb | W3 | 10 s glide with ±3 cm @ 10 Hz, ±5 cm @ 6 Hz, ±5 cm @ 3 Hz, tracker noise σ = 2 mm | abs(Δh vs no-input baseline) ≤ 0.05 m, flap events = 0 (proto 0.000 m with the upstroke gate) |
| One-wing flap = yaw/roll kick | F8 | one hard left stroke at cruise | heading change to the **right** ≥ 3.5° (sparrow) / 2.5° (pigeon) / 1.5° (eagle) within 1 s (proto 5.3 / 3.4 / 2.2; peak bank ≈ 7°); sideslip ≤ 1°; Δv ≈ half a symmetric stroke ±20 % |
| Tuck to dive | F14 | pitch −1 with tuck, from cruise | V ≥ 0.95·V_max within 20 s (proto 0.983–1.010); never > 1.03·V_max; release to neutral → recovered ≤ 2.2·T_ph (proto ≤ 1.82) |
| Hover (small) vs no-hover (big) | F7e | hard flat strokes from a standstill, detector primed, pitch 0.5, floor off, measured over 2–7 s | x ≤ 0.44: vz ≥ +2.0 m/s and drift ≤ 1.0 m/s (proto +2.72/+2.63, 0.21/0.23); x ≥ 0.6: vz < 0 (proto −0.84…−1.50) |
| Ground cushion † | F16 | glide at 3° descent over flat ground | cushion on: skims ≥ 40 spans before contact; cushion off: contact within 5 spans of the geometric intercept; a 40° dive into the ground still contacts and stuns (not in the prototype) |
| Look around freely † | W6 | head yaw ±90°, pitch ±45°, roll ±20° sweeps with arms fixed | pitch/roll commands change ≤ 0.01; body_yaw ≤ 0.5° |
| Flapping via real arm motion only † | W2 | crouch/jump: head+hands move 0.3 m together at 1 m/s | flap = 0 |
| Seated play | W8 | seated flag; stroke ±0.25 m, 1.3 Hz | P̄ ≥ 0.85·standing reference P̄ (proto 0.93–0.96) |
| WingInput correctness † | W1 | PoseSynth → WingInput round trip on a grid (pitch/roll ∈ {−1, −.5, 0, .5, 1}, spread ∈ {0, .5, 1}, strokes) plus head-look noise | pitch, roll ±0.03; spread ±0.03; flap_pitch ±2°; P̄ ±10 %; mirror symmetry: mirrored pose gives −roll and swaps flap L/R exactly |
| | W4 | reference stroke per size | P̄ = tuning p_ref(x) ±5 % |
| | W5 | flap with chord −20° for 3 s, stop | pitch command held at pre-stroke value (±0.05) during strokes; after stop reaches −0.5 ±0.1 within 1.5 s |
| | W7 | right hand lost 3 s mid-turn | no NaN; bank → abs(φ) < 5° within 1.5 s after the loss decays; no flap events; resumes on reacquire without a jump (Δroll ≤ 0.1/tick) |
| | W9 | same poses at world_scale 0.15 and 1.31 (XR node path) | WingState identical ±1e-6 |
| | W10 | calibration: neutral roll 15° per hand | after calibration, pitch = 0 ±0.02 |
| Perching (approach slowly; flap to launch) † | P1–P8 | see §7.3 | P1 aligned approach at 0.9·V_cap → PERCHED within 1 s, body within 0.1 span of the target, `player_perched` once, occupant set; P2 1.5·V_cap without grip → not perched; P3 1.2·V_cap with grip → perched; P4 perch.max_span < span → never perched; P5 stroke P ≥ 0.35 → FLYING ≤ 0.1 s, V ≥ 0.5 V_min at 0.5 s, no re-perch 0.4 s, `player_took_off`; P6 tuck → drop, V ≥ V_min within 1.5 s; P7 assist A/B: 20 seeded sloppy approaches (offset ±1 span, speed 1.2–1.5 V_cap) → on ≥ 90 % perched, off ≤ 60 %; P8 occupied → no capture |
| Collisions (continuous, stun not death) † | C1–C7 | generated test world | C1 1000 random shots at 2 m/s…1.2·V_max vs 1 cm-radius, 3 m cylinders: analytic hits = actual stops (0 tunnels, 0 false hits beyond 1 mm); C2 15° glancing at V_c: no stun, speed kept ≥ 85 %; C3 head-on at V_c: STUNNED 0.6–1.4 s, bounce v·n > 0, inputs ignored, then FLYING; C4 shallow landing at 0.6 V_min on flat ground → GROUNDED, pigeon 1 stroke / eagle 2 strokes take off; C5 slot 1.2 body diameters wide: escape within 2 s of flapping, contacts ≤ 3/s after 1 s; C6 head leaned 0.4 m (real) into a wall: camera stays ≥ r_body from the wall; C7 window 2 spans × 1.5 spans flown centred: 0 collisions, brush events allowed |
| Comfort: camera never pitches or rolls † | K1 | every L3/L4 scenario + fuzz + stun + perch + respawn | every tick: `XROrigin3D.global_basis.y · UP ≥ 1 − 1e-6` and `PlayerBird.global_basis.y · UP ≥ 1 − 1e-6` |
| | K2 | all L3 scenarios | abs(Δyaw) per tick ≤ 1.05·Ω_max(x)·dt except flagged respawn ticks; yaw rate continuous (no jump > p_max·dt·g/V equivalent) |
| | K3 | hard hover (primed, flared) and hard cruise flapping (chord −20°), per tier | perceived bob (camera y ripple after 1-period moving-average detrend, ÷ world_scale) ≤ ±20 cm hover, ≤ ±18 cm cruise (proto worst ±14 / ±13) |
| | K4 | all L3/L4 | camera near sphere never intersects layer 1 |
| | K5 | torso turns 90° right (poses), no tilts | heading +90° ±5° within 90°/Ω(0.8 φ_max) + 1.5 s; rig yaw change ≤ 5°; with body_steer off, heading change ≤ 2° |
| State & API † | S1–S6 | | S1 `set_controls_enabled(false)` → roll/pitch/flap ignored, wings level within 2·t90; S2 pause 1 s: model position unchanged; a scripted 0.3 m head move during the pause moves the camera 0.3·world_scale (not cancelled); on unpause the camera does not jump (≤ 1 mm); S3 `respawn(xf)`: mode SPAWNING→PERCHED/FLYING, v = 0, eye at xf ±1 mm, yaw = xf yaw, `player_spawned`; S4 telemetry has every contract key, finite, units consistent (`lift` ≈ g_load·m·g ±1 %); S5 events fire exactly once per occurrence; S6 growth via `mass` setter reconfigures within the same tick |
| Desktop emulation † | D1 | Input.parse_input_event (headless) | hold W 0.5 s → pitch ≤ −0.8; S → ≥ +0.8; A → roll ≤ −0.8; Space tap → exactly 1 downstroke, peak P ≥ 0.8; Q → flap_l > 0, flap_r = 0; Shift → tuck; mouse look → commands unchanged |
| Bot pilot course | B1 | §11.4 | all three sizes complete; window error ≤ 50 % of tolerance (proto worst 21 %) |
| Assists help | B2 | novice-noise bot × 10 seeds × 3 sizes | completion ≥ 80 % (assists 1); completion(assists 1) > completion(assists 0) |
| Performance | F17 | 10 000 model steps, and 72 player ticks with sweeps | record µs/step (metric); assert model ≤ 40 µs, player tick ≤ 150 µs on this Mac (debug build) |

### 11.3 Scenario details that are easy to get wrong

- **Trim start.** Use `solve_glide_trim()` or integrate 40 s at the command
  before t = 0, then reset position (keep v, θ, filters). Starting a pitch
  test from an un-trimmed state injects a phugoid and corrupts settle times.
  Prototype runs that did this showed eagle "V0" varying by ±0.4 m/s.
- **Recovered.** Recovery means "within 5° of the *trim* γ and 15 % of trim
  V". It does not mean "γ > −5°", because the neutral glide itself is −6.4°
  for a sparrow.
- **Altitude lost in a stall.** Measure from the release to the minimum
  *before* recovery, not over the whole run (which includes normal sink).
- **Flap direction.** Assert on `last_forces().flap_impulse`. A black-box Δv
  comparison against a no-flap twin is confounded by aerodynamics: the twin
  dives and gains forward speed. In the prototype that made a flat stroke
  look 6–11° "backward". The behavioural test F7d covers the gameplay
  meaning instead.
- **Flapping inputs.** Drive them through a stroke generator (asymmetric
  cosine, 45 % down) into WingInput, or use its PoseSynth equivalent. The
  detector needs one priming upstroke (the raise gate).
- **Time.** Schedules are tick-indexed. Never accumulate `t += dt` for event
  times, which alone produced 2.5 % trajectory differences between rates in
  the prototype.

### 11.4 Bot pilot

`BotPoseSource` = `Autopilot` + `PoseSynth` + a synthetic stroke generator.
The bot sees only its own WingState-level commands and the bird's kinematic
state (position, velocity), exactly what a player sees. It never touches
model internals except the read-only `FlightParams` for gain scaling. This
architecture was validated in the prototype.

- **Lateral:** L1 guidance. `L1 = max(2.5 spans, 0.9·V_c)`, target point on
  the leg at distance L1, `a_lat = 2V²/L1·sin η`, `φ = atan(a_lat/g)`,
  `roll = φ/φ_max`.
- **Speed on pitch:** `pitch = pitch_trim(V_tgt) + 2.0·(V − V_tgt)/V_tgt`,
  where `pitch_trim` inverts the α map for `CL = mg/(q S)`.
- **Altitude on flap (PI):** `vz_cmd = clamp(Δh/(0.6·T_ph), −2, perf.climb)`,
  `flap = clamp(ff + 0.25·e + I, 0, 1)`, `I += 0.05·e·dt` (clamped to
  [−0.4, 0.6]),
  `ff = 1.7/(climb + 1.7)`, flap chord −0.35·35°. The earlier variant,
  "γ on pitch + energy on flap", left 1–6 m steady altitude errors on big
  birds. Speed-on-pitch plus altitude-on-flap is how birds and gliders fly,
  and it converged for every size.
- **Landing:** from 12 spans out, target V = 1.4·V_min at perch height
  − 0.35(V² − V_cap²)/g. At 4 spans, flare (pitch 0.8). Small birds add
  hover-brake strokes (flat, pitch 0.6) when V > V_cap within 2 spans.
- **Course** (generated by `FlightCourseBuilder`, scaled by size; this is also
  the dev scene `scenes/dev/flight_course.tscn`):
  - start 20 m AGL at V_c heading −Z;
  - climb to +15 m along a leg of `L = max(120 m, 14·V_c)`;
  - 180° right turn at ~0.6·φ_max, radius R = V_c²/(g tan(0.6 φ_max));
  - return leg offset 2.6 R;
  - window at 0.35·L: a wall with an opening **2 spans wide × 1.5 spans
    tall**, frame 0.5 span thick, all layer 1;
  - a perch post 25 spans after the window with a branch perch
    (`max_span = 1.5 × span`).
- **B1 pass criteria per size:**
  - window crossed with |lateral| ≤ 1 span − r_body and |vertical| ≤ 0.75 span
    − r_body. With the gains above, the prototype's worst case was 21 % of
    that tolerance (sparrow ey 0.000 m, pigeon 0.044 m, eagle 0.262 m of
    1.24 m). Gains are sensitive: one earlier set passed the sparrow at 95 %
    of tolerance. The port should keep a gain-sweep dev test (grid over kv,
    τ_h, kp, ki) and re-pick gains whenever tuning moves;
  - 0 stuns and 0 frame collisions (wing brushes allowed and counted);
  - PERCHED on the target within `1.6·L_total/V_c + 10 s`;
  - rig K1/K2 hold throughout;
  - PNG and CSV written.
- **B2 novice bot** adds seeded human noise: 150 ms command delay, chord
  tremor ±4° at 8 Hz, 20 % over-rotation on roll, strokes of random amplitude
  ±30 %, 10 % of strokes one-sided. It runs with assists 1 and 0 and reports
  both completion rates. This test proves the assists remove frustration
  rather than asserting it.
- **First-flight smoke (B3):** a "flap-only" player (flat hard strokes, no
  tilts at all) as a sparrow from the spawn perch stays airborne ≥ 60 s and
  never stuns. Onboarding's first lesson must be survivable without skill.

### 11.5 Plots (`tests/unit/flight/flight_plot.gd`, class `FlightPlot`)

Plots are drawn on a pure `Image` (works headless) at 1600×900 with four
panels:

1. top view x/z with course geometry (walls, windows as segments, perches as
   dots, thermals as circles);
2. side view along-track distance vs altitude, with the window rectangle;
3. time series V, V_c reference line and altitude;
4. time series α, θ, φ, flap L/R, pitch and roll commands, with event ticks
   (stall, perch, collide).

Polylines use Bresenham with 2 px thickness. Labels use an embedded 5×7
bitmap font (digits, A–Z, `.-+/%°`), which keeps it independent of fonts and
the renderer. The fixed palette is readable on white. Output:
`artifacts/flight/<test>_<species>.png`, plus a contact sheet
`artifacts/flight/overview.png` (a 3×N grid of the key scenarios) for review
by eye. Every B1/F2/F4/F5/F9/F14 run writes one.

### 11.6 Meta XR Simulator checks (flight's part)

`scenes/dev/flight_lab.tscn -- --pose=script:course --species=sparrow`
uses a HybridPoseSource (XR head, scripted wings) and runs via
`tools/xr.sh 40 res://scenes/dev/flight_lab.tscn -- --pose=script:course --xrshot=5,15,25`.
Assert from the log:

- session FOCUSED;
- `[flight]` telemetry lines show the position advancing and the mode
  sequence FLYING→…→PERCHED;
- fps ≥ 70;
- no SCRIPT ERROR.

Assert from the mirror screenshots:

- the horizon is level. Scan columns for the sky→ground luminance edge and
  fit a line: |slope| ≤ 0.5° (automated proof of "no roll" through the real
  XR camera path);
- the scripted wings are visible (non-sky pixels in the lower-left and
  lower-right thirds).

The same lab runs on desktop with the DesktopPoseSource for tuning.

### 11.7 Golden values and the port

`tests/unit/flight/golden.json` holds Appendix A (per scenario and species:
value, tolerance). F-tests compare against golden values *and* the
requirement thresholds. A tuning change that moves a golden value fails the
golden check with a clear message ("tuning changed feel: balloon Δh 1.30 →
0.95, re-bless with --bless"). The requirement thresholds stay fixed. The
`--bless` flag rewrites golden.json and prints a diff for review, so feel
changes are deliberate and reviewable.

---

## 12. Cross-panel flags and open questions

1. **World-scale compresses perceived speed and amplifies bob for small
   birds.** With ws = span/A, the sparrow perceives 9 m/s as ~60 m/s and its
   flap ripple ×6.7. Consider `ws = (span/A)^0.6` (sparrow 0.32, eagle 1.18):
   perceived speed 28 vs 18 and half the bob, with wings drawn to the hands
   regardless. This is the VR panel's call. Flight is invariant to it (W9).
2. **SizeRules.turn_rate vs comfort.** The envelope asks a sparrow for
   220°/s at cruise, and the model delivers it at 74° bank. That is honest
   physics but intense in VR. Options: keep it (vignette), `gentle_turns`, or
   have gameloop lower `turn_rate` (e.g. 220 → 150°/s at the sparrow). NPC
   fairness requires that the player and NPCs share whatever is chosen.
3. **Roll mode A/B on the Quest Pro:** ANGLE (default) vs RATE, plus the
   body_steer default for seated players.
4. **Thermal geometry:** eagles need thermal cores ≥ 40–50 m radius at 3 m/s
   (§5). Ridge lift on cliff faces should reach ≥ 2 m/s within 1 span-scaled
   band of the face so small birds can use building faces.
5. **NPC cost:** see §2.3. The AI panel should decide the LOD and decimation
   and add a perf test.
6. **Events:** no new signals are needed. If UI wants distinct ground
   landings, add `player_landed(pos, on_perch: bool)` as a contract change.
7. **Settings keys to add** (contract change): `flight_assist` (1),
   `body_steer` (true), `flap_bob_smoothing` (true), `gentle_turns` (false).
   `seated` already exists.

---

## Appendix A: prototype golden values (72 Hz, Heun, assists default)

**Derived envelope** (all species; drives E1/E2):

| species | m kg | x | V_c | V_min | V_max | φ_max | n_max | T_ph s | τ_α | τ_φ | roll °/s | A_pk g | hov_eff | L/D neutral | sink m/s | min sink @ V |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| moth | .004 | 0 | 6.43 | 2.89 | 16.7 | 77 | 4.59 | 2.9 | .080 | .120 | 420 | 4.40 | 1.00 | 3.9 | 1.60 | 0.50 @ 3.2 |
| wren | .012 | .156 | 7.73 | 3.48 | 20.1 | 75 | 4.16 | 3.5 | .097 | .156 | 378 | 4.18 | 1.00 | 5.0 | 1.52 | 0.52 @ 3.9 |
| sparrow | .03 | .287 | 9.00 | 4.05 | 23.4 | 74 | 3.84 | 4.1 | .112 | .186 | 343 | 4.00 | 1.00 | 6.0 | 1.50 | 0.54 @ 4.5 |
| swallow | .055 | .373 | 9.96 | 4.48 | 25.9 | 73 | 3.65 | 4.5 | .121 | .206 | 319 | 3.83 | 1.00 | 6.6 | 1.50 | 0.56 @ 5.0 |
| starling | .09 | .443 | 10.81 | 4.86 | 28.1 | 73 | 3.50 | 4.9 | .129 | .222 | 300 | 3.69 | 1.00 | 7.1 | 1.52 | 0.58 @ 5.4 |
| pigeon | .35 | .636 | 13.55 | 6.10 | 35.2 | 70 | 3.12 | 6.1 | .150 | .266 | 248 | 3.31 | 0.77 | 8.5 | 1.58 | 0.64 @ 6.8 |
| crow | .6 | .713 | 14.83 | 6.67 | 38.6 | 69 | 2.99 | 6.7 | .158 | .284 | 227 | 3.16 | 0.68 | 9.1 | 1.62 | 0.67 @ 7.5 |
| gull | 1.1 | .799 | 16.40 | 7.38 | 42.7 | 68 | 2.84 | 7.4 | .168 | .304 | 204 | 2.99 | 0.58 | 9.7 | 1.68 | 0.71 @ 8.3 |
| hawk | 1.6 | .853 | 17.46 | 7.86 | 45.4 | 68 | 2.76 | 7.9 | .174 | .316 | 190 | 2.89 | 0.52 | 10.1 | 1.72 | 0.73 @ 8.8 |
| eagle | 4.5 | 1 | 20.75 | 9.34 | 53.9 | 66 | 2.54 | 9.4 | .190 | .350 | 150 | 2.60 | 0.35 | 11.3 | 1.84 | 0.81 @ 10.4 |

**Scenario results** (sparrow / starling / pigeon / crow / gull / eagle):

| scenario | values |
|---|---|
| F2 balloon Δh at 1.5 s (m) | 1.30 / 1.86 / 2.50 / 2.72 / 2.96 / 3.18 |
| F2 balloon peak (m @ s) | 1.44@1.8 / 2.53@2.2 / 4.64@2.7 / 5.80@3.0 / 7.41@3.3 / 12.75@4.1 |
| F2 V at 3 s vs V0 | −43 / −49 / −56 / −56 / −54 / −45 % (final −40 … −41 %, = trim prediction ±0.1 m/s) |
| F2 settle (s, ×T_ph) | 3.5 (.85) / 4.1 (.85) / 5.1 (.83) / 5.6 (.83) / 6.1 (.82) / 7.6 (.81) |
| F2 min V / V_stall | 1.01 / 1.00 / 0.98 / 0.97 / 0.96 / 0.95 |
| F3 V at 3 s (pitch −0.5) | +37 / +32 / +26 / +24 / +22 / +17 %; γ(1 s) −19 … −13° |
| F4a slow-stall recovery (×T_ph) | .55 / .50 / .44 / .44 / .46 / .48; altitude lost ≈ 0.37–0.45 V_t²/g |
| F4b zoom-stall recovery (×T_ph) | .58 / .55 / .28 / .28 / .33 / .46 |
| F5 bank t90 at roll 0.6 (s) | .42 / .50 / .61 / .64 / .69 / .79; ψ̇ ratio .993–1.001; sink ×1.13–1.15 |
| max-bank turn rate (°/s) vs perf | 238/220, 177/165, 123/116, 107/101, 90/86, 62/60 |
| F9 3 m/s updraft climb, neutral | +1.50 / +1.49 / +1.43 / +1.40 / +1.36 / +1.24 m/s |
| F9b updraft, pitch 0.6, circling 30° bank | +2.32 / +2.28 / +2.20 / +2.16 / +2.11 / +2.00 m/s |
| F7e primed standstill hover, vz (drift) | +2.72 (0.21) / +2.63 (0.23) / −1.19 (2.4) / −0.97 (3.8) / −0.84 (4.9) / −1.50 (7.6) |
| F8 one-wing stroke heading change (1 s) | +5.3 / +4.4 / +3.4 / +3.1 / +2.8 / +2.2° |
| W8 seated P̄ / standing P̄ | 0.94 / 0.94 / 0.95 / 0.96 / 0.96 / 0.96 |
| best flap climb (target) | 4.18 (4.0) / 3.95 (3.6) / 3.68 (3.2) / 3.61 (3.1) / 3.42 (2.9) / 2.97 (2.5) |
| F7d v_h moderate strokes chord 0 → −20° (m/s) | 3.1→5.8 / 4.8→7.3 / 8.3→9.9 / 9.4→11.4 / 10.9→13.3 / 15.3→18.3 |
| F14 tucked nose-down top speed / V_max | 0.983–1.010 (within 20 s) |
| F10 energy drift, 60 s | ≤ 0.0006 % |
| F15 error vs 720 Hz | 72 Hz ≤ 1.07 %, 90 Hz ≤ 0.82 %, 120 Hz ≤ 0.58 % |
| F12 fuzz (600 s each) | 0 NaN; max V/V_max 0.96 / 0.93 / 0.90 / 0.87 / 0.84 / 0.77 |
| W3 shake (±3 cm 10 Hz, ±5 cm 6 Hz) | Δh 0.000 m (with the gated upstroke) |
| K3 perceived bob (hover/cruise) | sparrow ±13/±13 cm, starling ±14/±10, pigeon ±11/±8, crow ±7/±5, gull ±6/±3, eagle ±6/±1 |
| B1 window error / tolerance | ≤ 0.21 with kv 2.0, τ_h 0.6·T_ph, kp 0.25, ki 0.05 (sparrow ey 0.000 of 0.142 m; pigeon 0.044 of 0.389; eagle 0.262 of 1.239) |
| flap latency t50 (τ_f 0.2–0.3) | 0.25–0.31 s (raw 0.15–0.18 s) |

## Appendix B: implementation order (flight area)

1. `FlightTuning` + `FlightParams.derive` + E1 table test (prints Appendix A;
   diff against golden).
2. `FlightModel` step (§3.2) + the L1 suite (F2–F18). Port until golden.
3. `WingState`, `FlapDetector`, `WingInput`, `PoseSynth` + the L2 suite
   (W1–W10, round-trip first).
4. `PoseSource` family (Scripted, Replay, Recorder, Hybrid, XR, Desktop) + D1.
5. `PlayerBird` (head-centred rig, sweep, state machine, perch, telemetry,
   events) + the L3 suite (C, P, K, S). Test world builder.
6. `Autopilot` + `BotPoseSource` + course builder + B1–B3 + FlightPlot.
7. `flight_lab.tscn` desktop + XR simulator run (§11.6); `docs/areas/FLIGHT.md`
   with plots and metrics.
