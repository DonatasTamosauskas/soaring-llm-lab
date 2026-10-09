# Flight controls: VR ergonomics design

*Flight design panel, lens: the human holding two Quest controllers.*
Scope: how head and controller poses become wing inputs (`WingInput` → `WingState`),
the pose-source abstraction, the rig/comfort rules, calibration, fatigue, haptics,
and the public APIs of `FlightModel` and `PlayerBird` as seen from the input side.
The aerodynamic internals of `FlightModel` belong to the other panelists; §14.4 lists
what this lens needs from them.

Evidence gathered for this doc (all reproducible):
- **Simulator probe** (Meta XR Simulator runtime 207.0.0, system "Meta Quest Pro", Godot
  4.7.2, 2026-09-25). A scratch `SceneTree` script run through `XR=1 tools/gd.sh design_vr -s`
  printed every pose of the simulated Touch controllers. Results are in §1.3.
- **Flap detector prototype** (Python, 90 Hz, 0.7 mm tracker noise). Results are in §6.5.
- **Swing-twist check** (Python, grip convention from the probe). Results are in §4.4.

---

## 0. Decisions at a glance

| # | Decision | Why |
|---|---|---|
| D1 | All input math runs in **tracking space, in real metres**. Pose sources divide node origins by `world_scale`. | Growth cannot change the feel of the controls or create false hand velocity. |
| D2 | Read the hands from the **grip** pose (palm centroid), not `default`/`aim`. In this project `default` is bound to **aim**. | The palm point moves least under wrist flicks, and the grip frame is anatomical. |
| D3 | **Body forward** = horizontal perpendicular to the hand-to-hand line, fused with a head-yaw "neck leash" and a jump gate. The head's gaze never steers while the arms are spread. | Lets the player look around freely. Survives tucks, crossed arms and turning around. |
| D4 | Shoulders are estimated from a **neck pivot** under and behind the eyes, not from the eye point. | Nodding or looking down does not move the shoulders. |
| D5 | **Wrist pitch = swing-twist decomposition** of the controller's rotation from its calibrated neutral, about a **calibrated forearm axis in the controller frame**. | Decouples pitch from arm raise, sweep and elbow bend. The naive axis leaks 21° of pitch into a 40° arm raise (§4.4). |
| D6 | The input is an **attitude command**. `pitch_input` sets the commanded incidence. `roll_input` (arm tilt plus opposite wrist twist) sets a commanded bank. Neutral arms mean wings level. | Holding a pose holds a turn. No rate-command spirals for novices. |
| D7 | **Physical heading.** The bird's body yaw is rig yaw (aerodynamic) + torso yaw (physical). Turning your body turns the bird through sideslip. The camera never rotates from it. | Physical turning is the one turn with zero vection mismatch, and it makes "turned around in the room" a non-issue. |
| D8 | **Flap detection** uses the hand's velocity normal to the wing, relative to the neck, a 2-pole 8 Hz filter, an **arc bank** (no downstroke without a matching upstroke) and **amplitude credit** (12°→35°). | Shaking and tremor give 0% of a real flap. Slow-recovery/fast-power strokes count (§6.5). |
| D9 | **Flap force direction** = the wing normal, tilted by the shaped wrist pitch: up to 35° forward (leading edge down) and 20° back (leading edge up). | Requirement 1, plus flare/brake for perching. |
| D10 | The **fatigue-tolerant glide pose** counts as fully spread: arms 0° to −60° below horizontal, with soft elbows (reach ≥ 62%). **Soar lock**: hold both grips to keep the wings open with your arms at rest. | Holding your arms out horizontally for minutes is not sustainable (§9). |
| D11 | **Calibration** is automatic on the first "spread your wings" pose. It captures span, shoulder height, per-hand neutral basis, forearm axis and chord axis. A 3-stroke flap capture sets the player's full effort. | Works regardless of controller convention, body size or seated/standing. |
| D12 | **world_scale = wingspan / (arm_span + 0.20 m)**. The feathered wingtips drawn 10 cm past each grip match the bird's real span. The rig pivots about the head. | The size cue (your wings next to theirs) is the core of eat-or-flee. |
| D13 | **Haptics teach the model.** A per-stroke "air bite" only on credited strokes. A detent click at the edge of the neutral wrist band. A stall buffet. A per-wing updraft hum (turn toward the buzzing wing). | The player learns the model through their hands. |

---

## 1. Frames, units, conventions

### 1.1 Spaces
- **Tracking space T**: the `XROrigin3D` local space with the scale removed. Metres are real
  metres. +Y is up (gravity-aligned; OpenXR stage and local-floor spaces are gravity-aligned).
  The floor is at y≈0 in stage space. Every pose `WingInput` sees is in T.
- **Body frame B** (in T): origin at the estimated shoulder centre. `F` = body forward
  (horizontal unit), `U` = +Y, `Rt = F × U` = body right. Torso yaw `φ` is the yaw of `F` in T,
  in Godot's convention: `F = Basis(UP, φ) * (0,0,-1)`, CCW positive seen from above.
- **World**: the `PlayerBird` node carries yaw `ψ_rig` and translation only (§11.1).

### 1.2 Sign conventions (used everywhere, tested in §15)
| Quantity | Positive means |
|---|---|
| `pitch` / `pitch_input` | leading edge **up** (nose-up command, more AoA) |
| `roll_input`, `bank` | **right** wing down (turn right) |
| `dihedral` (per wing) | wingtip (hand) **above** the shoulder |
| `sweep` (per wing) | hand **forward** of the shoulder line |
| `body_yaw`, `aero_yaw`, `heading` | CCW from above (Godot `Basis(UP, a)`) |
| wing index | 0 = left, 1 = right. Side sign `σ` = −1 left, +1 right |

### 1.3 Controller pose conventions (measured, not assumed)
From the probe, with the simulator's fixed "pointing forward" controllers at T-origin
(±0.29, 1.40, −0.50):

| pose | basis columns (X, Y, Z) in T | origin |
|---|---|---|
| `aim` (= `default` in `openxr_action_map.tres`) | X≈(1,0,±0.09) Y=(0,1,0) Z≈(∓0.09,0,1). **−Z points forward along the pointing ray.** | (±0.291, 1.400, −0.500) |
| `grip` | X=(1,0,0) Y=(0,0.5,0.866) Z=(0,−0.866,0.5), i.e. **grip = aim · Rx(+60°)** | (±0.300, 1.370, −0.460) |
| `palm` (grip_surface) | **inactive in the simulator.** Do not depend on it. | — |

This matches the OpenXR grip definition. **−Z_grip** runs through the fist tube (little
finger to thumb). **±X_grip** is the palm normal (+X points *out of* the left palm and
*into* the right palm, i.e. world-right for both hands in a handshake). **+Y_grip** points
back toward the wrist. The runtime's aim ray, expressed in the grip frame, is
`(0, −0.866, −0.5)`. This is the default forearm-distal axis.

For the **"airplane arms, palms down"** pose (the neutral wing), the anatomical model
(§2.4) gives these values in the grip frame, identical for both hands:
- forearm/arm outward axis `a_local = (0, −0.866, −0.5)`
- chord (leading-edge direction) `c_local = (0, 0.5, −0.866)`
- wing up-normal: `+X_grip` for the right hand, `−X_grip` for the left

**Consequence:** a controller with `Basis.IDENTITY` is *not* palms-down. (A sibling attempt's
tests assumed it was.) None of `WingInput`'s math hard-codes these axes. It uses the
calibrated `a_local` and `c_local`, and falls back to the defaults above.

**World-scale semantics (measured):** after `world_scale = 2.0`, `XRController3D.transform.origin`
and `XRCamera3D.transform.origin` doubled. Bases were unchanged. The raw
`XRPositionalTracker.get_pose(name).transform` stayed in real metres.

---

## 2. Pose pipeline

### 2.1 `PoseFrame` (one per physics tick)
```gdscript
class_name PoseFrame extends RefCounted
var t := 0.0                          # seconds since the source started
var head := Transform3D.IDENTITY      # tracking space, REAL metres
var left := Transform3D.IDENTITY      # grip pose, tracking space, real metres
var right := Transform3D.IDENTITY
var head_valid := false
var left_valid := false
var right_valid := false
var grip := Vector2.ZERO              # analog 0..1 (x = left, y = right)
var trigger := Vector2.ZERO
var buttons := 0                      # bitmask, see BTN_* below
const BTN_MENU := 1; const BTN_AX := 2; const BTN_BY := 4
const BTN_STICK_L := 8; const BTN_STICK_R := 16
```

### 2.2 `PoseSource` (swappable, same `WingInput` behind all of them)
```gdscript
class_name PoseSource extends RefCounted
## Fill `out` in place for this physics tick. Never allocate per tick.
func sample(out: PoseFrame, dt: float) -> void: pass
## True when the source is synthetic: PlayerBird then writes the poses into the
## XRCamera3D / XRController3D nodes (scaled by world_scale) so wings, UI rays
## and screenshots look exactly as they would in a headset.
func drives_nodes() -> bool: return false
```
| Source | Use | Notes |
|---|---|---|
| `XRPoseSource` | headset and simulator | Reads `camera.transform`, `left_hand.transform`, `right_hand.transform` (hand nodes use `pose = &"grip"`) and divides each **origin** by `origin.world_scale`. Validity comes from `get_has_tracking_data()` and the `XRPose.tracking_confidence != NONE`. Inputs come from `get_float(&"grip")`, `get_float(&"trigger")`, `is_button_pressed(&"menu_button")`, and so on. |
| `ScriptedPoseSource` | tests, bot pilot, simulator scripted runs | Wraps a `HumanPoseModel` (§2.4) driven by a `Callable(t) -> HumanPose` or a gesture timeline. |
| `ReplayPoseSource` | regression from real sessions | Reads JSON-lines recorded by `PoseRecorder` (below). Interpolates to the requested tick. |
| `DesktopPoseSource` | dev on a Mac without a headset | Keyboard and mouse drive a `HumanPoseModel` (§2.5). **Never synthesises `WingState` directly.** |

`PoseRecorder` (vr area) appends one line per tick to `user://pose_rec/<stamp>.jsonl`:
`{"t":…, "h":[px,py,pz,qx,qy,qz,qw], "l":[…], "r":[…], "v":7, "g":[gl,gr], "tr":[tl,tr], "b":int}`.
At 90 Hz that is about 20 MB per 10 minutes. Enable it from the settings "Record flight" toggle,
or `--record-poses`. Quest Pro sessions recorded later become `tests/fixtures/poses/*.jsonl`
replay tests (§15.4).

### 2.3 Validity and tracking loss
Per hand, a tracking loss is handled like this:
- **< 0.25 s**: hold the last valid pose. Velocity is 0, so no flap.
- **0.25–0.85 s**: blend that wing's outputs toward a mirror of the other wing's
  extension, dihedral and twist.
- **After that**: stay mirrored.

When both hands are lost for more than 0.25 s, blend over 0.8 s to the neutral glide
(extension 1, pitch 0, roll 0) and set `tracking = 0`. The HUD then shows "controllers not
tracked".

When the head is lost, freeze the body frame. After 1 s, request a pause, because the
headset was removed. `VR.session_unfocused` also pauses. (The Quest Pro Touch Pro
controllers track themselves, so a hand loss is rare, but the simulator and battery
dropouts do lose tracking.)

Sanity check before use: every basis is finite with `determinant() > 0.5`, the origins are
finite with `|p| < 20 m`, and a single hand jump is under 0.5 m per tick (otherwise treat it
as invalid for that tick).

### 2.4 `HumanPoseModel` (tests, desktop, bot pilot)
A small kinematic human that produces **anatomically consistent** poses, grip bases
included. Everything synthetic goes through it.
```gdscript
class_name HumanPoseModel extends RefCounted
var arm_span := 1.50        # grip-to-grip at full lateral spread, m
var eye_height := 1.62      # standing; seated ≈ 1.20
var shoulder_width := 0.345 # 0.23 * arm_span
var shoulder_drop := 0.24   # eyes to shoulder-joint height
var torso_yaw := 0.0        # rad, in T
var room_offset := Vector3.ZERO
var head_yaw := 0.0; var head_pitch := 0.0      # relative to the torso
var arm := [ArmPose.new(), ArmPose.new()]       # left, right
var tremor_mm := 0.0; var tremor_hz := 9.0; var twist_noise_deg := 0.0
func frame(out: PoseFrame) -> void               # builds head/left/right in T
class ArmPose: var dihedral := 0.0; var sweep := 0.0; var twist := 0.0; var elbow := 0.0 # rad
```
To build a grip basis for side `s` (σ = ±1):
```
AIR_R = cols(( 0,1,0), (0,0,-1), (-1,0,0))   # handshake → airplane-palms-down, right
AIR_L = cols(( 0,-1,0),(0,0,-1), ( 1,0,0))   # left
GRIP_OFF = Basis(X, +60°)                    # measured grip = aim · Rx(60°)
grip = Torso(φ) · Sweep(UP, σ·sweep) · Dihedral(-Z, -σ·dihedral) · Twist(outward, σ·twist) · AIR_s · GRIP_OFF
```
The arm has two equal segments of length `L_arm/2`. The upper arm points along the swung
arm direction. The elbow bends the forearm **forward** about the body-vertical hinge at the
elbow. The controller basis is carried along by that hinge rotation, which is a pure swing,
so a bent elbow never reads as twist. The hand sits at the end of the forearm.
`twist` is positive for leading edge up on both sides.

This construction was checked numerically (§4.4). A test asserts that the model's neutral
reproduces the §1.3 `a_local` and `c_local` to within 1e-3.

### 2.5 Desktop emulation (keyboard and mouse → `HumanPoseModel`)
| Input | Pose change (rates are per second, and the input springs back to neutral on release unless noted) |
|---|---|
| Mouse | head yaw and pitch (free look; it must not steer: this is a live demo of D3) |
| Space (hold) | both arms flap at 1.2 Hz, ±45° about −5°; a tap gives one stroke |
| Q / E | left / right wing flaps only |
| W / S | both wrists leading edge down / up (twist ramps at 90°/s to ±40°) |
| A / D | arm tilt (dihedral bank) ±30° |
| Alt + A / D | opposite wrist twists (aileron) ±30° |
| Shift | tuck (elbows 150°, arms in) |
| Ctrl | sweep both arms back 45° (partial fold) |
| Z | sweep forward 30° (flare) |
| [ / ] | physical torso turn at 90°/s (tests D7) |
| C (toggle) | low relaxed glide pose (−45°, elbows 40°) |
| F / G | left / right grip (both = soar lock; near a perch = cling) |
| Esc | menu |

---

## 3. Body frame estimation

### 3.1 Head forward (robust at any head pitch)
```
zf = -head.basis.z; y = head.basis.y
f_head = horiz(zf) - zf.y * horiz(y)     # continuous through straight-up and straight-down gazes
φ_head = atan2(-f_head.x, -f_head.z)
```
Looking down, the top of the head points forward. Looking up, the back of the head does.
The `-zf.y` weighting blends these without a singularity.

### 3.2 Torso yaw estimator (per tick)
```
w   = right.origin - left.origin;  w_h = horiz(w)
f_w = normalize(UP.cross(w_h))                      # ⟂ to the hand line; (UP × +X) = -Z ✓
φ_w = yaw(f_w)
c_span = smoothstep(0.35, 0.75, |w_h| / arm_span)   # hands far apart ⇒ trustworthy
c_calm = 1 - 0.6 * clamp(max(|ω_L|, |ω_R|) / 4.0, 0, 1)   # vigorous strokes wobble the line (ω from the previous tick)
jump = |wrap(φ_w - φ_est)|
if jump > 75°:                                      # crossed arms, glitch, or a turn during a tuck
    agree = |wrap(φ_w - φ_head)| < 40° held for 0.3 s  # a real turn: the head turned too
    c_gate = 1 if agree else 0
else: c_gate = 1
c = c_span * c_calm * c_gate
φ_est += wrap(φ_w - φ_est) * (1 - exp(-dt * c / 0.10))          # follow the hands (τ = 0.1 s)
# neck leash: the torso cannot stay > 70° from the gaze for long
e = wrap(φ_head - φ_est); lim = 70°
if |e| > lim: φ_est += sign(e) * (|e| - lim) * (1 - exp(-dt / (0.5 if c > 0.5 else 2.0)))
# with no hand information, drift gently toward the gaze
φ_est += e * (1 - c) * (1 - exp(-dt / 4.0))
φ_est = rate_limit(φ_est, 400°/s)
```
The output is `WingState.body_yaw = φ_est` plus its rate. The body basis
`B = Basis(UP, φ_est)` gives `F`, `U` and `Rt`.

| Situation | Behaviour |
|---|---|
| Arms spread, head looks around ±90° | `c≈1`, so the head is ignored (the leash only acts beyond 70° and is overpowered by the τ = 0.1 s hand follow). **Test T3.** |
| Tucked (hands close together) | `c_span≈0`: the estimate is held, drifts to the gaze with τ = 4 s, and follows the leash beyond 70°. |
| Arms crossed or hands swapped | `f_w` flips by about 180°, so the jump gate rejects it. The head disagrees, so the estimate holds. |
| Physically turning around with arms spread | Continuous. Follows at up to 400°/s. |
| Turning around while tucked, then spreading again | The leash keeps the estimate within 70° of the gaze. At the spread the gate sees jump > 75° but the head agrees, so the estimate is accepted within about 0.4 s. |
| One arm swept forward and one back | The hand line rotates, so the body yaw rotates by about atan(Δz/span). This acts as a gentle **yaw input**, the bird's asymmetric-sweep rudder. |
| Walking or leaning | Only translation; no yaw effect. |

### 3.3 Shoulders
```
neck    = head.origin + head.basis * Vector3(0, -0.08, 0.09)     # pivot below and behind the eyes
centre  = neck + Vector3(0, -(shoulder_drop - 0.08), 0) - F * 0.02
S_L = centre - Rt * shoulder_width/2;  S_R = centre + Rt * shoulder_width/2
L_arm = (arm_span - shoulder_width) / 2      # shoulder joint to grip centre; 0.577 for span 1.50
```
A shoulder estimate is **smoothed** (One-Euro, 2.0 Hz, β 0.5) so nods do not jitter it.

Known limit: when the player bends forward at the waist by 30°, the true shoulders are
about 8 cm further forward than estimated. This shows up as a small forward sweep bias,
inside the 12° sweep dead-zone.

---

## 4. Per-wing measurements

For each side `i` (σ = −1 left, +1 right):
```
a     = p_i - S_i                                    # arm vector (T)
x_out = σ * a.dot(Rt);  y = a.dot(U);  z = a.dot(F)  # outward, up, forward
r_c   = sqrt(max(x_out,0)² + y²) / L_arm             # reach in the wing (coronal) plane
δ_i   = atan2(y, max(x_out, 0.05))                   # dihedral (elevation)
s_i   = atan2(z, max(x_out, 0.05))                   # sweep
```

### 4.1 Extension (0 tucked … 1 spread)
```
e_reach = smoothstep(0.30, R_HI, r_c)                 # R_HI = 0.62 (calibrated: 0.95·glide reach, 0.50..0.75)
e_low   = smoothstep(-82°, -62°, δ_i)                  # arms hanging at your sides = folded
e_back  = 1 - smoothstep(-35°, -70°, s_i)              # hands behind the back = folded (a bird's stoop)
e_i     = OneEuro(e_reach * e_low * e_back, 1.5 Hz, β 0.2)
```
Reference poses (L_arm 0.577):

| Pose | r_c | δ | e |
|---|---|---|---|
| Airplane arms, straight | 1.0 | 0° | 1.00 |
| Relaxed glide: −45°, soft elbows (reach 0.65) | 0.65 | −45° | **1.00** (D10) |
| Straight arms at −70° | 1.0 | −70° | 0.65 |
| "Chicken wings" (hands at 0.25 m) | 0.43 | −10° | 0.38 |
| Hands together at the chest | ≤0.25 | — | 0.00 |
| Superman: both arms straight ahead | ≤0.17 | — | 0.00 |
| Arms hanging at the sides | ~0.95 | −85° | 0.00 |
| Straight arms swept 60° back | 0.50 | 0° | 0.14 |

`smoothstep(a, b, x)` in this document always means `t = clamp((x−a)/(b−a), 0, 1); t²(3−2t)`,
including when `a > b`. Implement it as a local helper rather than relying on the built-in's
edge handling.

**Novice floor:** until `has_spread` (both `e > 0.8` for 0.3 s at least once since spawn or
calibration), the output is `max(e_i, 0.85)`. A newcomer holding the controllers together
is not asking for a dive. (A sibling attempt measured hands-together poses flying into the
ground within seconds without this floor.)

`tucked = (e_L < 0.25 and e_R < 0.25)` for longer than 0.1 s.

### 4.2 Dihedral for banking
`δ_a = (δ_L − δ_R)/2`. Positive means the left hand is higher, which is a **right** bank.
It is only valid when both `r_c > 0.3`; otherwise it is 0. A one-wing fold rolls through
the per-wing extension instead.

While a wing is stroking (`|ω_i| > 1.0 rad/s`), use that wing's **mean δ over the last
stroke cycle** (a ring buffer of 1.5 s; the window is the last measured cycle period,
clamped to 0.3–1.5 s, default 1.0 s). When calm, use `OneEuro(δ_i, 1.0 Hz, β 0.8)`.

This cancels the ±45° swing of one-wing flaps exactly. A plain low-pass with τ = 0.35 s
would leave about ±19° of bank wobble at 1 Hz. It also keeps "flap while tilted" banking.

### 4.3 Wrist pitch: swing-twist about the calibrated forearm axis
Calibration stores, per hand:
- `N_i`, the controller basis **in the body frame** at neutral (`B⁻¹·R_ctrl`)
- `a_local_i`, the outward arm axis in the controller frame
- the side sign `k_i = sign((N_i·a_local_i)·Rt)`

Each tick:
```
R  = B⁻¹ · R_ctrl_i                       # body-relative controller basis (removes torso yaw)
Q  = N_iᵀ · R                             # rotation since neutral, in the controller's own frame
q  = Quaternion(Q)
τ  = wrap(2 * atan2(q.xyz · a_local_i, q.w))       # twist about the forearm
conf = sqrt(q.w² + (q.xyz · a_local_i)²)           # < 0.25: swing near 180°; hold the last τ
twist_i = k_i * τ                                   # + = leading edge up, both hands
twist_i = OneEuro(twist_i, 1.2 Hz, β 1.0)
```
Physically, this is forearm pronation/supination plus shoulder internal/external rotation.
The instruction to the player is "**roll your wrists back** (thumbs up and out) to lift the
leading edge; **roll them forward** to drop it". It works with arms up, down, forward,
elbows bent, or at rest by your sides. Arms hanging with palms facing your thighs read as
exactly neutral: that is a pure swing from the airplane pose.

### 4.4 Why the calibrated axis (numbers)
Checked with the measured grip convention (script: scratchpad `twist_check.py`, both hands):

| Motion | pitch read with the calibrated axis | pitch read with naive −Y_grip |
|---|---|---|
| twist leading edge up 20° | **+20.0°** | +17.4° |
| dihedral +40° (arm raise) | **0.0°** | +20.6° |
| dihedral −60° | **0.0°** | −32.2° |
| sweep ±30° | **0.0°** | 0.0° |
| arm down −85° (rest) | **0.0°** | −49.2° |

The naive axis would pitch the bird up every time the player banked with their arms. The
leak is roughly `swing · sin(axis error)`. Calibration from a straight-armed spread gets
the axis within about 5° (a 5 cm shoulder-height error over a 0.58 m arm), so the leak is
about 3.5° at a 40° raise, below the 5° dead-zone.

### 4.5 Chord and wing normal (for the flap-force direction)
```
o_i  = normalize(a)                                  # actual arm direction (swings included)
c0_i = normalize(F - (F·o_i) o_i)                    # forward, ⟂ to the arm
n0_i = σ * normalize(o_i × c0_i)                     # the wing's up normal at zero incidence (R: X×-Z = +Y ✓)
θ_i  = u_i * (20° if u_i > 0 else 35°)               # shaped incidence (§5.1), LE up +
normal_i = n0_i*cos θ_i - c0_i*sin θ_i               # LE down ⇒ tilts forward; LE up ⇒ back
```
`normal_i` is in the **body frame**. For a flat wing it is straight up. Leading-edge down
20° tilts it 17° forward. Leading-edge down 30°, which is full scale, tilts it the full 35°
forward. Leading-edge up 40° tilts it 20° back (the braking flap for landings). Raising the
arm tilts it inward, and the two sides cancel.

---

## 5. Control mapping (what the player does → `WingState`)

### 5.1 Shaping curves (smooth dead-zone plus expo; slope is continuous at the dead-zone edge)
```
func shape(x, dz, full_pos, full_neg, expo) -> float:
    var a = absf(x) - dz
    if a <= 0.0: return 0.0
    var full = full_pos if x > 0 else full_neg
    return signf(x) * pow(clampf(a / (full - dz), 0, 1), expo)
```
| Signal | dz | full + | full − | expo | Notes |
|---|---|---|---|---|---|
| per-wing twist → `u_i` (normals, visuals) | 5° | 40° (LE up) | 30° (LE down) | 1.4 | Pronation beyond palms-down is short (about 30° including the shoulder), supination is long. |
| symmetric twist `t_s = (t_L+t_R)/2` → pitch | 5° | 40° | 30° | 1.4 | same ranges |
| antisymmetric twist `t_a = (t_L−t_R)/2` → aileron | 4° | 25° | 25° | 1.3 | symmetric range, so equal opposite tilts never leak pitch |
| dihedral bank `δ_a` | 4° | 30° | 30° | 1.2 | A 30° arm tilt is a hand-height difference of about 0.75 m at span 1.5, a clear gesture. |
| symmetric sweep | 12° | 35° | 35° | 1.0 | Arms drift, so the dead-zone is wide. |

The flight-assist setting (§10.3) scales every dead-zone ×0.6 to ×1.4. `wrist_sensitivity`
divides the twist full-scales.

### 5.2 Aggregates
Split the raw twists into symmetric and antisymmetric parts *before* shaping. Shaping each
wing first would make ±20° opposite tilts produce −0.09 of pitch, because the up and
down ranges differ.
```
pitch_input = clamp( shape(t_s) + 0.30 * shape(mean sweep) * min(e_L, e_R), -1, 1 )
roll_input  = clamp( shape(δ_a) + shape(t_a), -1, 1 )
```
Reference values: both wrists +20° gives `pitch_input` 0.31. Both −20° gives −0.49.
Left +20° with right −20° gives `roll_input` 0.70 and `pitch_input` 0. A 15° arm tilt gives
`roll_input` 0.36.
- **Symmetric twist sets speed and AoA.** Leading edge up means more AoA: the bird balloons,
  then settles slower. Leading edge down means the nose drops and speed builds.
- **Sweep forward pitches up and sweep back pitches down.** A bird moves its centre of lift
  ahead of its centre of mass to flare, and sweeps back to stoop. Skydivers use the same
  convention. (The Opus-5 sibling used the reverse, "Superman" mapping.) Sweep is a
  secondary trim with 0.3 authority and can be turned off.
- **Opposite twist (left leading edge up, right down) banks right**, like ailerons. Either
  gesture alone reaches the full bank command. Together they add.
- `roll_input` is a **bank-angle command** and `pitch_input` an **incidence command** (D6).
  Returning to neutral levels the wings and returns to trim.
- **Physical yaw** (D7) is not in `roll_input`. It enters through `body_yaw` (§11.2).
- **One-wing flap:** force on that wing only (§6). The flight model turns it into a roll
  and yaw kick.
- **One-wing fold:** asymmetric extension, so that wing drops (a real bird's quick drop-turn).

### 5.3 Buttons (the body does the flying; buttons are only for discrete intents)
| Control | In flight | Near a perch (in reach and slow) | In menus |
|---|---|---|---|
| Grip, either hand (analog, on > 0.6, off < 0.4) | — | **Cling** (perch) | — |
| Both grips | **Soar lock** (§9.3) | cling | — |
| Trigger | unassigned (reserved) | — | UI click |
| Menu (left) | pause | pause | back |
| Y (left secondary), hold 1 s with wings spread | quick recalibration of neutral and span | same | — |
| Thumbsticks | unused. Optional snap-turn of `aero_yaw` for fixed-chair seated play (setting `snap_turn`, 30°) | — | scroll |
| Oculus button, long press | system recenter (§11.5) | | |

---

## 6. Flap detection

### 6.1 Signal
```
rel_i  = p_i - neck                         # relative to the neck: crouch, jump, walk and lean cancel
v_raw  = (rel_i - rel_prev_i) / dt
v1 += (v_raw - v1) * α;  v2 += (v1 - v2) * α          # α = 1 - exp(-2π·8 Hz·dt)  (2-pole, ~40 ms delay)
v_n    = -(v2 · n0_i')                      # n0_i' = the normal with incidence clamped to ±20°; + = downstroke
ω_i    = v_n / L_arm                        # rad/s-equivalent, independent of arm length
```
Using the full 3-D velocity along the normal means "rowing" also counts: pushing down and
back with a leading-edge-down wing drives air backward-down, a real bird's downstroke path.
Horizontal "swimming" with flat wings produces nothing, and the onboarding says "flap
**down**".

### 6.2 Arc bank and amplitude credit (per wing)
```
if ω < -W_UP (0.15 rad/s):                  # upstroke (slow recoveries count)
    if state != UP: state = UP; up_arc = 0
    up_arc += -ω·dt;  bank = min(bank + (-ω·dt), 150°)
    upstroke_i = clamp(-ω / ω_full, 0, 1)
elif ω > W_DN (0.9 rad/s):                  # downstroke (≈ 0.5 m/s hand speed)
    if state == UP: amp = up_arc; state = DOWN
    d = ω·dt;  use = min(d, bank);  bank -= use
    credit = smoothstep(12°, 35°, amp)      # A_MIN, A_FULL (seated 9°→26°)
    flap_i = min(ω · (use/d) · credit / ω_full, 1.3)
else:
    bank *= exp(-dt / 8.0)                  # hygiene only
flap_i reset to 0 when not in a credited downstroke; bank = 0 when e_i < 0.3 or on tracking loss
```
The invariants: **there is no downstroke without a preceding upstroke of at least as much
arc**, and small arcs earn little credit. A downstroke's thrust is limited by how far the
arm was raised. Shakes, tremor and waggles fail both tests.

### 6.3 Effort normalisation
`ω_full` = 4.5 rad/s standing and 3.4 seated, then personalised by calibration (§8.2) to
`clamp(0.85 · median peak ω of 3 big strokes, 3.0, 6.0)`. Everyone can reach full effort
whatever their strength or arm length.

### 6.4 Events
- **Onset:** `flap_i` first exceeds 0.25 in a stroke. Haptics fire here immediately, per
  hand (§13).
- `Events.player_flapped(side, strength)`: `strength = credit` (how big the upstroke was).
  If the other wing's onset arrives within 60 ms, emit once with `side = 0`. The latency is
  at most 60 ms, which is fine for audio and UI.
- The stroke period (for §4.2) is the time between successive onsets on the same wing.

### 6.5 Prototype results (P = mean effort² relative to the canonical flap, 10 s runs)
| Motion | Standing | Seated profile |
|---|---|---|
| canonical 90° @ 1.0 Hz | **1.00** | 1.00 |
| gentle 50° @ 0.8 Hz | 0.19 | 0.23 |
| small 30° @ 1.2 Hz | 0.11 | 0.19 |
| vigorous 110° @ 1.6 Hz | 1.86 | 1.38 |
| seated-style 60° @ 1.2 Hz | 0.64 | 0.77 |
| slow recovery 1.2 s + fast power 0.3 s, 90° | **0.71** | 0.55 |
| flutter 45° @ 2 Hz | 0.95 | 1.02 |
| still + 0.7 mm noise | **0.00** | 0.00 |
| tremor 1 cm @ 10 Hz | **0.00** | 0.00 |
| wrist shake 3 cm @ 8 and 12 Hz | **0.00** | 0.00 |
| frantic 6 cm @ 5 Hz | **0.00** | 0.00 |
| frantic 8 cm @ 4 Hz | 0.00 | 0.01 |
| elbow pump ±15 cm @ 3 Hz (real work) | 0.38 | 0.93 |

Onset latency from the top of the stroke to `flap > 0.2`: **67 ms**, which includes the
arm's own acceleration.

Implication for the aero panel: if thrust ∝ effort², tempo matters a lot. Gentle flapping
gives about 20% of the canonical flap. Recommendation: sustained level flight for a small
bird should need only about 25–35% of canonical P, i.e. gentle flapping or a flap every
2–3 s, with climbing at 60–100%.

---

## 7. Filters and latency budget
| Channel | Filter | Added latency (typical motion) | Target (tested) |
|---|---|---|---|
| twist → `u_i` | One-Euro 1.2 Hz, β 1.0 | ≈ 35 ms | step 0→20°: 90% of final in ≤ 90 ms |
| dihedral | One-Euro 1.0 Hz, β 0.8, cycle-mean while stroking | ≈ 45 ms calm | step: 90% in ≤ 120 ms |
| extension | One-Euro 1.5 Hz, β 0.2 | ≈ 60 ms | tuck→spread 90% in ≤ 150 ms |
| hand velocity | 2 × 1-pole 8 Hz | ≈ 40 ms | onset ≤ 80 ms |
| shoulders | One-Euro 2 Hz, β 0.5 | — | nod ±30° moves shoulders ≤ 2 cm |
| torso yaw | τ 0.10 s gated follow, rate limit 400°/s | ≈ 100 ms | 180° turn over 2 s: lag ≤ 8° |

One-Euro: `fc = min_cutoff + β·|dx̂/dt|`, `α = 1/(1 + 1/(2π·fc·dt))`, derivative cutoff 1 Hz
(Casiez et al. 2012). With 0.2° orientation noise at rest, output noise is ≤ 0.05°.

---

## 8. Calibration

### 8.1 Automatic "spread your wings" capture (first launch, onboarding step 1, Y-hold, settings)
The capture triggers when the following have held for **1.2 s**:
- both hands valid
- `|w| > 0.9 m`
- `|δ_L|, |δ_R| < 25°`
- hand speed < 0.08 m/s
- angular speed < 25°/s
- `|y_L − y_R| < 0.12 m`

The capture averages over the window:
```
arm_span       = |r - l|  (clamped 1.0 .. 2.2)
shoulder_drop  = head.y - mean(hand.y) - L_arm·sin(5°)          # people hold arms ≈5° low; clamp 0.15..0.35
shoulder_width = 0.23 · arm_span
φ_cal          = yaw of f_w   (body frame at calibration)
N_i            = B(φ_cal)⁻¹ · R_ctrl_i                          # neutral basis per hand
a_local_i      = R_ctrl_iᵀ · normalize(p_i - S_i)               # arm line in the controller frame
c_local_i      = R_ctrl_iᵀ · F, projected ⟂ a_local_i, normalised
```
Reject the capture, and keep the defaults, if `a_local` is more than 45° from
`(0,−0.866,−0.5)`. That indicates a strange grip or controllers swapped between hands.

Before any calibration, the defaults are: span 1.50, drop 0.24, `N_i` = the airplane-pose
basis from §2.4, and `a_local`/`c_local` from §1.3.

Feedback: a haptic double tick plus a brief wing-glow. The player is not asked to do
anything special beyond "spread your wings, hands flat".

### 8.2 Stroke capture (onboarding step 2: "three big flaps")
Record the peak ω and up-arc of 3 credited strokes:
- `ω_full = clamp(0.85·median(peak ω), 3.0, 6.0)`
- `A_FULL = clamp(0.5·median(up_arc), 25°, 40°)`

### 8.3 Glide-pose capture (optional, onboarding "relax into a glide")
Hold a comfortable glide for 2 s. Then:
- `R_HI = clamp(0.95·r_c, 0.50, 0.75)`
- fold start = `min(−62°, δ_mean − 12°)`

The player's own rest pose becomes full extension.

### 8.4 Continuous refinement (small and bounded)
- **Span grows** when the observed hand spread exceeds `arm_span + 5 cm` for 0.5 s (the
  calibration was cramped). It never shrinks automatically.
- **Neutral-twist auto-trim** (setting on by default). Conditions: gliding (no onset for 5 s),
  `e > 0.8`, `|roll_input| < 0.2`, and `|twist − neutral| < 12°`. Then drift the neutral
  toward the current twist with τ = 60 s, bounded to ±10° from the captured neutral. This
  follows the slow pronation drift of tired forearms, and never eats a deliberate input
  (12° or more).

### 8.5 Seated
The `Settings.seated` flag, or automatic detection when the head is below 1.30 m for 5 s at
calibration. The flag selects:
- `ω_full` × 0.75
- credit 9°→26°
- `R_HI` 0.58
- fold limits −55°/−75°

The shoulder estimate is unchanged, because it is relative to the head.

Help text: "use a chair without armrests; a swivel chair lets you turn with your body".

### 8.6 Persistence
`WingCalibration` (flight-owned Resource) is serialised into
`Settings["wing_calibration"]` (a Dictionary). Proposed fields, replacing
`neutral_roll_*` and `neutral_pitch_*`, which cannot express a full neutral orientation:
```gdscript
@export var arm_span := 1.50           # grip-to-grip at full spread (was 1.6 "fingertip")
@export var shoulder_width := 0.345
@export var shoulder_drop := 0.24
@export var neutral_left := Basis.IDENTITY     # controller basis in the body frame at neutral
@export var neutral_right := Basis.IDENTITY
@export var forearm_axis_left := Vector3(0, -0.866, -0.5)   # grip-frame, outward
@export var forearm_axis_right := Vector3(0, -0.866, -0.5)
@export var chord_axis_left := Vector3(0, 0.5, -0.866)
@export var chord_axis_right := Vector3(0, 0.5, -0.866)
@export var glide_reach := 0.62        # R_HI
@export var fold_elevation := -1.082   # rad (-62°)
@export var stroke_full_rate := 4.5    # ω_full, rad/s
@export var stroke_full_arc := 0.611   # A_FULL, rad (35°)
@export var seated := false
@export var calibrated := false
func arm_length() -> float: return (arm_span - shoulder_width) * 0.5
```

---

## 9. Fatigue

### 9.1 The budget
Holding one arm horizontal with a 0.16 kg Touch Pro puts a shoulder torque of about
3.6 kg × 9.81 × 0.30 m ≈ 10.5 N·m on it. That is 17–25% of maximal abduction torque, which
gives an endurance of **about 2–4 minutes** before the arm is noticeably tired. Torque scales
with `cos(elevation)`:
- 45° below horizontal: 71%, about 4–8 minutes
- 60° below: 50%, over 10 minutes
- soft elbows cut the lever arm by about 30%

The game must therefore never *require* horizontal arms for long.

### 9.2 Pose tolerance (D10)
Full extension covers elevations from +60° to −60° and reach ratios ≥ 0.62. The flight
model must not penalise symmetric dihedral or anhedral in that range (requirement R7 in
§14.4). Only arms hanging down (< −62°) or pulled in fold the wing.

### 9.3 Soar lock (both grips, in flight)
While both grips are held with `e ≥ 0.5` at the press, extension is held at
`max(current, value at press)`. Twist (pitch and aileron) and dihedral stay live. Because
twist is measured about the forearm, the arms can rest at your sides, palms toward the
thighs, reading neutral, and you can still pitch by rolling your wrists and bank by lifting
one arm slightly outward.

On release, extension blends back to the arm-derived value over 0.4 s, with a tick on
release. If the arms are down at that moment, the wing folds, which is learnable ("spread,
then let go"). The setting `soar_lock` defaults to on. Thermals and ridge lift are where
the player rests.

### 9.4 Exertion design targets (for the aero panel and the level designers)
- Level cruise for a small bird: ≤ 30% of canonical flap power, or glide.
- Climb: bursts of 5–10 s at 60–100%.
- Thermals and ridges must climb with **zero** flapping.
- A run's first 5 minutes should need ≤ 25% flapping duty, measured with the bot pilot's
  "lazy" profile (§15.3).

---

## 10. First-time users

### 10.1 Failure modes → mitigations
| Failure mode | Mitigation |
|---|---|
| Holds the controllers together at the chest | Spawn **perched**. The novice floor keeps extension ≥ 0.85 until the first spread. Prompt: "Spread your wings". |
| Never fully spreads | `R_HI` 0.62, glide-pose capture, soft elbows count. |
| Flails fast and small | Arc bank plus credit give zero thrust. The haptic "air bite" never fires, so no reward. After 3 s of flailing (high ω, no credit), hint "Big, slow strokes: lift, then push down". |
| Flaps with leading edge up (thrust goes backward) | The normal tilts back, so the bird brakes and hovers. Hint: "Tip your hands forward as you flap to go forward". The wing visual shows the tilt. |
| Swims horizontally | Zero normal velocity. Hint: "Flap down". |
| Looks around and expects to steer by gaze | The gaze is ignored by design. Lesson: "Tilt your arms to turn". |
| Drops the arms from fatigue | Relaxed pose tolerated, soar lock, thermals. |
| Tucks near the ground | Assist ≥ 0.5: a ground-proximity haptic warning (§13) when tucked, less than 3 s to impact, and below 10 body lengths AGL. |
| Crosses arms or turns around | §3.2 handles both. |
| Crouches, jumps or walks | Everything is relative to the neck, so none of these reads as a flap. The kinematic displacement is tiny at small `world_scale` (§11.1). |
| Swaps the controllers between hands | The calibration rejects it (§8.1). Hint: "Controllers in the wrong hands?". |
| Leading-edge-up wrists by habit, so a permanent stall | The auto-trim follows within ±10°. The stall buffet teaches "less". Flight assist clamps AoA below stall. |

### 10.2 The first 60 seconds (lessons progress on doing; UI owns presentation)
| t | Prompt | Completion predicate (on `WingState` / telemetry) |
|---|---|---|
| 0–10 s | "Spread your wings, hands flat" (perched) | the §8.1 capture fires. Fallback after 12 s: `e_L, e_R > 0.8` for 0.5 s |
| 10–20 s | "Flap! Lift your arms, then push down hard" | 3 × `player_flapped` with strength > 0.4 plus liftoff. The §8.2 capture runs silently. |
| 20–30 s | "Hold your wings out to glide; relax your arms lower if tired" | no onset for 4 s, `e > 0.8`, `|roll_input| < 0.2` |
| 30–45 s | "Tilt your arms like a plane to turn" | `roll_input > 0.5` for 1 s **and** `< -0.5` for 1 s, with bank > 25° |
| 45–60 s | "Tuck in to dive, spread to pull out" | `tucked` for 1 s, then airspeed > 1.5 × cruise, then `e > 0.8` |
| later | "Roll your wrists back to slow and climb" | `pitch_input > 0.5` and a positive vertical speed bump |
| later | ailerons, one-wing flaps, thermals (the per-wing buzz), perching (grip) | per lesson |

### 10.3 Flight assist (setting `flight_assist`, 0..1, default 0.6; 1.0 during the first lessons)
- **WingInput side:** dead-zones ×(0.6 + 0.8·assist), and the ground-proximity warning at ≥ 0.5.
- **FlightModel side:** a stall-protection AoA clamp at stall − 1° when assist ≥ 0.5, and
  stronger auto-level. These are requests to the aero panel.

---

## 11. Comfort and the rig

### 11.1 Rig transform per physics tick (yaw and translation only)
```
ws = origin.world_scale
Δh = frame.head.origin - prev_head_origin               # real metres, T (zero on recenter)
model.displace(Basis(UP, model.aero_yaw) * (Δh * ws))   # physical head movement moves the body kinematically
model.step(state, env, dt)                               # physics; position = the head/body point
var R := Basis(UP, model.aero_yaw)
global_transform = Transform3D(R, model.position - R * (frame.head.origin * ws))
```
- `PlayerBird` (the parent of `XROrigin3D`) only ever gets a pure-yaw basis at unit scale.
  **Test I1 asserts this every tick.**
- **The rig pivots about the head.** Changing `aero_yaw` leaves
  `head_world = model.position` fixed. A player standing 1 m from their room centre is
  not swung sideways in turns.
- Physical head movement moves the view 1:1 (no mismatch) and moves the bird's body by
  `Δh · ws`. For a sparrow a 1 m step is 0.16 m, so there is no exploit. Collisions sweep the
  total displacement.

### 11.2 Heading decomposition (D7): what the flight model must implement
```
heading  = aero_yaw + state.body_yaw                        # the bird's body/beak yaw in world
χ        = horizontal velocity heading;  β = wrap(heading - χ)  # sideslip
d(aero_yaw)/dt = coordinated turn rate from bank (g·tanφ/V) + flap-asymmetry yaw
dχ/dt          = same bank term + Y(β)/(m·V)                  # side force realigns velocity to the body
```
- **Side force:** `|Y/m| ≤ n_side·g`, with `n_side` = 1.5 (small birds) … 0.8 (eagle). The
  sideslip drag is ∝ `sin²β`.
- A physical turn therefore swings the flight path round in 0.3–0.8 s without rotating the
  camera: vestibular and visual cues agree.
- Recentre/snap: add to `aero_yaw` only.
- **NPCs:** `body_yaw ≡ 0`, so `heading = aero_yaw`.

### 11.3 Yaw smoothness (smooth, never snappy)
- The camera yaw rate is `d(aero_yaw)/dt`. The bank lag (τ_roll ≥ 0.12 s) bounds it.
- **Test I2:** in every scripted manoeuvre for a sparrow, `|d²(aero_yaw)/dt²| ≤ 720°/s²`
  and `|d(aero_yaw)/dt| ≤` the envelope `turn_rate`.
- The flap-asymmetry yaw goes through the flight model's yaw damping, not as an instant step.

### 11.4 Vignette (0..1, scaled by `Settings.comfort_vignette`)
```
yaw_term   = smoothstep(35°/s, 150°/s, |aero_yaw_rate|)
flow_term  = smoothstep(2.5, 9.0, airspeed / max(d_near, 0.1))   # rad/s optic flow; d_near = min of 3 rays (L, R, down) ≤ 8 wingspans
accel_term = smoothstep(6, 20, |a_rig_linear| / ws)              # perceived m/s² (the eye judges motion in body sizes)
target     = comfort_vignette * max(yaw_term, 0.7*flow_term, 0.5*accel_term)
strength  → target with attack 0.08 s, release 0.5 s
```
- Straight, fast flight in open sky keeps the full view.
- The vignette is drawn in the eye buffer by the vr area, as a camera-attached mesh. Its
  aperture must be verified at the frame edges.

**Perceived speed** is `v / ws`. The table uses the D12 scale `ws = span / (1.50 + 0.20)`
and `SizeRules.performance()` values:

| species | ws | cruise m/s | perceived cruise | perceived dive | turn °/s |
|---|---|---|---|---|---|
| wren | 0.094 | 7.7 | 82 | 213 | 279 |
| sparrow | 0.141 | 9.0 | 64 | 166 | 220 |
| starling | 0.235 | 10.8 | 46 | 119 | 165 |
| pigeon | 0.388 | 13.6 | 35 | 91 | 116 |
| crow | 0.559 | 14.8 | 27 | 69 | 101 |
| gull | 0.765 | 16.4 | 21 | 56 | 86 |
| eagle | 1.235 | 20.7 | 17 | 44 | 60 |

Small birds feel blisteringly fast and big birds majestic. This is desirable as the growth
arc, but it is the biggest comfort risk, and it is at its worst at the start, for new
players. Mitigations:
- the flow and accel vignette terms
- the first lessons in open terrain
- flap-force smoothing (τ_flap about 0.12 s) so each stroke is not a 1 m perceived bounce
- optional `heave_smoothing`: the camera's vertical position follows the body through a
  critically damped 2 Hz filter, bounded to ±0.25 m perceived (±0.25·ws world)

Flagged for the Quest Pro playtest (§16).

### 11.5 Recenter
On `VR.recentered` (system recenter), or `Events.recenter_requested`:
- Zero `Δh` for that tick.
- Keep `heading` continuous: set `aero_yaw = heading − body_yaw_new`. The player's view now
  faces the flight direction, which is what "recenter" means.
- Re-seed the torso estimator from the hand line, or from the head if the hands are tucked.

No neutral recapture happens on recenter. That needs a spread (Y-hold).

### 11.6 Never
Pitch or roll of the rig. Scale on `XROrigin3D` or its ancestors. A camera offset from
the tracked head other than the bounded heave filter. An abrupt yaw (every yaw goes
through a smooth rate, except the opt-in snap turn).

---

## 12. Growth and world_scale
- `ws_target = SizeRules.wingspan_for_mass(mass) / (cal.arm_span + 0.20)`.
- Animate `ws` in log space, at ≤ 0.25 ln-units/s (a tier-up takes about 1–3 s).
- Because the rig is re-derived from `model.position` (the head) every tick, the scale
  pivots about the head automatically. **Test I5:** the head's world path stays continuous
  during a ramp.
- `WingInput` never sees `ws`. **Test T6:** a ramp while holding still gives zero effort and
  no state change.
- Visual wings built from the tracked points under `XROrigin3D` scale automatically.
  Meshes parented to `XRController3D` must be scaled by `ws` by hand, because node scale
  under the controller is fine; only the origin and its ancestors must never scale.
- The camera near plane is `0.03·ws`, per ARCHITECTURE §7.5.

---

## 13. Haptics that teach
Use `XRController3D.trigger_haptic_pulse(&"haptic", freq, amp, dur, 0)`, where the action
name comes from `openxr_action_map.tres` and `freq = 0` means the runtime default. Scale
everything by `Settings.haptics`.

Rules:
- **Never a constant buzz:** duty cycle ≤ 30%.
- At most one pattern per hand per 40 ms, by priority: collision > caught > catch >
  stall > flap > danger > updraft > detent.

| Pattern | Trigger | Hand | amp | dur | Teaches |
|---|---|---|---|---|---|
| **Air bite** | flap onset (§6.4) | that hand | 0.2 + 0.6·credit | 35 ms | "that stroke counted". Big strokes feel bigger; shakes feel nothing. |
| **Neutral detent** | twist crosses ±dz (the neutral band edge) | that hand | 0.12 | 10 ms | where "flat" is, without looking |
| **Range stop** | twist crosses full scale (40° up / 30° down) | that hand | 0.25 | 15 ms | "no more authority past here" |
| **Stall buffet** | `stall_margin < 0.25`: random pulses every 50–90 ms, amp 0.15→0.6 as the margin → 0. Per-wing if the model reports tip stall. | both / that wing | 0.15–0.6 | 20 ms | "roll your wrists forward" |
| **Updraft hum** | lift at the wingtip > 0.5 m/s: pulses at 3–6 Hz, amp ∝ lift, **per wing**, from `env.wind_left/right` | per wing | 0.05–0.25 | 15 ms | "the buzzing wing is in the thermal: turn toward it" |
| **Speed rumble** | airspeed > 1.5 × cruise: sparse random ticks at 6–12 Hz | both | 0.05–0.2 | 8 ms | speed, when eyes are busy |
| **Perch ready** | a perch is in grip reach and speed < perch limit | nearest hand | 0.3, 0.3 | 2 × 12 ms, 60 ms apart | "squeeze to cling" |
| **Soar lock on / off** | both grips pressed / released | both | 0.2 | 15 ms / 2 × 10 ms | the mode change |
| **Ground warning** | assist ≥ 0.5, tucked, time-to-impact < 3 s | both | 0.4 | 3 × 30 ms | "spread!" |
| **Collision** | `player_collided` | both (side of the normal stronger) | 0.3 + impact/10 | 120 ms | contact |
| **Catch** | `bird_caught` by the player | both | 0.5, 0.7, 0.9 | 3 × 25 ms | reward |
| **Danger** | `threat_changed` > 0.5: a heartbeat double pulse at 1 → 2 Hz | both | 0.15–0.4 | 2 × 20 ms | threat nearby |
| **Caught** | `player_caught` | both | 1.0 | 400 ms | — |

The vr area owns the haptics player. `WingInput` exposes the per-tick event flags it needs:
`onset_l/r`, `detent_l/r`, `range_l/r`, `soar_lock_changed`.

---

## 14. Data and APIs

### 14.1 `WingState` (produced by `WingInput`; also produced directly by NPC autopilots)
```gdscript
class_name WingState extends RefCounted
## Scale-free wing command for one physics tick. Reused in place (no per-tick allocation).

class Side:
	var extension := 1.0          # 0 tucked .. 1 spread (smoothed, novice floor applied)
	var pitch := 0.0              # -1..1 shaped wrist twist u_i (+ = leading edge up)
	var twist := 0.0              # rad, filtered raw twist relative to neutral (telemetry, visuals)
	var dihedral := 0.0           # rad, arm elevation (+ = tip up), cycle-mean while stroking
	var sweep := 0.0              # rad (+ = forward)
	var flap := 0.0               # 0..1.3 credited downstroke effort this tick
	var upstroke := 0.0           # 0..1 upstroke effort (the model applies a small reverse force)
	var normal := Vector3.UP      # BODY-frame unit normal: the flap-force direction (§4.5)
	var stroke_phase := 0.0       # 0..1 (0 = top), for wing visuals and audio
	var onset := false            # true on the tick a credited stroke starts
	var grip := 0.0               # analog 0..1

var left := Side.new()
var right := Side.new()
var pitch_input := 0.0        # -1..1 symmetric incidence command (§5.2)
var roll_input := 0.0         # -1..1 bank command (+ = right wing down)
var body_yaw := 0.0           # rad, torso yaw in tracking space (NPC: 0)
var body_yaw_rate := 0.0      # rad/s
var tucked := false
var soar_lock := false
var tracking := 1.0           # 0..1: 0 = both hands lost (the model flies neutral)
var calibrated := false
var flapping := 0.0           # 0..1 activity: low-pass (τ 0.3 s) of max(flap_l, flap_r)

func side(i: int) -> Side: return left if i == 0 else right
func mean_extension() -> float: return (left.extension + right.extension) * 0.5
## Convenience for NPC autopilots: symmetric wings, flat normals.
func set_symmetric(extension: float, flap: float, pitch: float, roll: float) -> void
func copy_from(o: WingState) -> void
```
**The FlightModel consumes:** `pitch_input`, `roll_input`, `side(i).extension`,
`side(i).flap`, `side(i).upstroke`, `side(i).normal`, `body_yaw`, `tucked`, `soar_lock`
(informational) and `tracking`.

It **must not** re-derive roll from the per-wing `pitch`, or it will double-count the
aileron. The per-wing `pitch`, `twist`, `dihedral` and `sweep` exist for visuals,
telemetry, haptics and tests.

### 14.2 `WingInput`
```gdscript
class_name WingInput extends RefCounted
var calibration: WingCalibration            # flight-owned Resource (§8.6)
var assist := 0.6                           # Settings.flight_assist
var auto_trim := true
var state := WingState.new()                # the returned object (reused)
# diagnostics (read-only; debug gizmos, tests)
var body_basis := Basis.IDENTITY; var shoulder_l := Vector3.ZERO; var shoulder_r := Vector3.ZERO
var neck := Vector3.ZERO; var has_spread := false

func update(frame: PoseFrame, dt: float) -> WingState    # the whole of §3–§6; deterministic; dt clamped to ≤ 1/30
func reset() -> void                                        # new life: clears filters, banks, has_spread
func request_capture(kind: StringName) -> void              # &"neutral", &"strokes", &"glide"
func capture_status() -> Dictionary                         # {kind, progress 0..1, done, rejected_reason}
func on_recentered(frame: PoseFrame) -> void
func debug() -> Dictionary                                  # every intermediate value (for plots)
```

### 14.3 `FlightEnv` and `FlightModel` (pure `RefCounted`; the input-facing surface)
```gdscript
class_name FlightEnv extends RefCounted
var wind := Vector3.ZERO          # m/s at the body (World.get_wind)
var wind_left := Vector3.ZERO     # at the left wingtip (updraft asymmetry, haptics); = wind if unsampled
var wind_right := Vector3.ZERO
var gravity := 9.81
var air_density := 1.225
var ground_height := -INF         # below the body (ground effect, AGL)

class_name FlightModel extends RefCounted
signal-free; state is plain fields, events are flags reset at the start of each step()

func _init(mass: float, params: FlightParams = null)
func set_mass(mass: float) -> void          # re-derives span, area, inertia and envelope via SizeRules; smooth
func step(input: WingState, env: FlightEnv, dt: float) -> void   # integrates velocity, position, attitudes
func displace(delta: Vector3) -> void       # kinematic move, no velocity change (player head movement)
func apply_contact(position: Vector3, normal: Vector3, impact_speed: float) -> void  # slide / stun
func teleport(position: Vector3, heading: float, velocity := Vector3.ZERO) -> void
func telemetry() -> Dictionary              # the PlayerBird telemetry keys that belong to physics

# state (world units)
var position: Vector3          # body point (player: the eyes)
var velocity: Vector3
var aero_yaw: float            # rig yaw: integrates only aerodynamic turning (§11.2)
var heading: float             # aero_yaw + input.body_yaw (beak direction)
var bank: float                # rad, + right wing down
var body_pitch: float          # rad, visual/telemetry only; the camera NEVER uses it
var aoa: float, sideslip: float, airspeed: float
var stalled: bool, stall_margin: float   # 0 = at stall .. 1 = far from it
var lift: float, drag: float, thrust: float, g_load: float, in_updraft: float
var wing_lift := Vector2.ZERO  # per-wing lift fraction (tip stall, haptics)
# events (valid until the next step)
var ev_stall_started := false; var ev_stall_ended := false
```

### 14.4 Requirements from this lens on the flight model (for the aero panelists)
| # | Requirement |
|---|---|
| R1 | `pitch_input` is a commanded incidence: `α_cmd = α_trim + pitch_input · (range_up if > 0 else range_dn)`. Lift responds within ≤ 0.1 s, so the balloon feels connected. Put stall at about `pitch_input` 0.8, so buffet starts near 0.6 and the last fifth of the wrist range is the stall zone. |
| R2 | `roll_input` is a **bank-angle command** (steady input gives a steady bank; zero gives wings level). τ_roll is about 0.12 s (wren) to 0.45 s (eagle), with a bank limit of about 70°. |
| R3 | Coordinated turns: `aero_yaw` rate = `g·tanφ/V`, with zero sideslip from banking (the auto-rudder). |
| R4 | Physical heading via `body_yaw` gives sideslip, realigned with bounded lateral g (§11.2). |
| R5 | Flap force per wing: along `side.normal` (body frame to world via `heading`), magnitude ∝ `flap^1.5…2` × size factor, passed through a first-order lag with τ_flap about 0.12 s. Upstroke: −10% of the equivalent. Asymmetric flaps give roll and yaw moments. |
| R6 | Per-wing `extension` scales that wing's area and lift. Asymmetric extension rolls toward the folded wing. |
| R7 | **No penalty** for symmetric dihedral or anhedral within [−60°, +30°]. |
| R8 | Expose `stall_margin`, `wing_lift`, `g_load` and the stall events for haptics and audio. |
| R9 | Deterministic, with a fixed dt of 1/72–1/90. Substep when dt > 1/60. `tracking = 0` must glide safely. |
| R10 | `aero_yaw` acceleration bounded (§11.3). No input may produce a yaw step. |

### 14.5 `PlayerBird` (scenes/player/player.tscn root)
```gdscript
class_name PlayerBird extends Bird
# Scene: PlayerBird (process: pausable) → XROrigin3D (group player_rig, PROCESS_MODE_ALWAYS)
#   → XRCamera3D, LeftHand/RightHand (XRController3D, tracker left_hand/right_hand, pose &"grip"),
#     Wings (first-person wing visuals built from the tracked points), Vignette (vr area)
var model: FlightModel
var wing_input: WingInput
var pose_source: PoseSource            # auto: XRPoseSource if VR.active, else DesktopPoseSource
var controls_enabled := true

func is_player() -> bool: return true
func get_body_position() -> Vector3     # XRCamera3D.global_position (== model.position ± 1 frame)
func get_forward() -> Vector3            # heading (beak/body), NOT the gaze
func set_pose_source(src: PoseSource) -> void     # tests and the bot pilot inject here
func set_controls_enabled(on: bool) -> void       # off: WingState = neutral glide (menus, CAUGHT)
func respawn(xform: Transform3D) -> void          # perched at xform; resets model, WingInput (keeps calibration)
func wing_state() -> WingState                    # read-only view for visuals, haptics, UI lessons
func begin_calibration(kind: StringName) -> void  # forwards to WingInput.request_capture
func calibration_status() -> Dictionary
func telemetry() -> Dictionary
```
The per-physics-tick order is:
1. `pose_source.sample(frame)`
2. if the source is synthetic, write the scaled poses into the XR nodes
3. `state = wing_input.update(frame, dt)` (neutral if `controls_enabled` is false)
4. perch logic: cling or launch
5. `env` = the World's wind at the body and the wingtips
6. `model.displace()` and `model.step()`
7. a continuous sweep (shape cast, radius `get_body_radius()`), then `model.apply_contact()`
   on a hit
8. the rig transform (§11.1)
9. `ws` ramp
10. Events: `player_flapped`, `player_stalled`, `player_collided`, `player_perched`,
    `player_took_off`

**`telemetry()`** returns the contract keys: `airspeed`, `groundspeed`, `vertical_speed`,
`altitude_agl`, `aoa`, `bank`, `stalled`, `flapping`, `wing_extension`, `tucked`,
`perched`, `in_updraft`, `g_load`, `lift` and `drag`. **Extras:**
- `pitch_input`, `roll_input`
- `flap_l`, `flap_r`, `extension_l`, `extension_r`, `twist_l`, `twist_r`
- `body_yaw`, `heading`, `aero_yaw_rate`, `sideslip`, `stall_margin`
- `soar_lock`, `tracking`, `calibrated`
- `world_scale`, `perceived_speed` (= airspeed / ws), `vignette`

### 14.6 Proposed contract changes (non-breaking; flight and vr to record them in ARCHITECTURE)
1. `LeftHand`/`RightHand` use `pose = &"grip"`. The UI laser uses the **aim** pose: extra
   `LeftAim`/`RightAim` XRController3D nodes, or `XRServer.get_tracker(...).get_pose(&"aim")`.
2. `WingCalibration` fields as in §8.6 (flight owns the file). `arm_span` is defined as
   grip-to-grip, with default 1.50.
3. New `Settings.DEFAULTS` keys: `"wing_calibration": {}`, `"flight_assist": 0.6`,
   `"soar_lock": true`, `"auto_trim": true`, `"wrist_sensitivity": 1.0` (scales twist
   full-scale ×1/s), `"sweep_pitch": true`, `"heave_smoothing": 0.0`,
   `"record_poses": false`. `snap_turn` stays reserved as the fixed-chair option (§5.3).
4. `Bird.get_forward()` for the player is the heading (§11.2).

---

## 15. Verification without a headset

### 15.1 `WingInput` unit tests (`tests/unit/flight/wing_input_test.gd`, `HumanPoseModel`, fixed seed)
| # | Scenario | Pass criteria |
|---|---|---|
| T0 | The model's neutral reproduces §1.3 | `a_local`, `c_local` within 1e-3. Default `N_i` read as twist 0. |
| T1 | Airplane glide for 2 s | `e` ∈ [0.95, 1]; `|pitch_input|, |roll_input|` < 0.02; flap ≡ 0 |
| T2 | Relaxed glide (−45°, elbows 40°), and arms at −60° | `e ≥ 0.95` |
| T3 | Head yaw ±80° and pitch ±60°, arms spread | every WingState field changes by < 0.01; `body_yaw` by < 1° |
| T4 | Whole body rotated ψ ∈ {0, 90, 180, −135}° | WingState equal except `body_yaw = ψ ± 1°` |
| T5 | Room offset (1.2, 0, −0.8) m | identical |
| T6 | `ws` ramp 0.16 → 0.44 in 1 s through `XRPoseSource` normalisation, still | flap ≡ 0; state changes by < 0.01 |
| T7 | Twist both 20° leading edge up; both 20° down; left +20° / right −20° | `pitch_input` ∈ [0.25, 0.37] with `|roll_input|` < 0.02; ∈ [−0.55, −0.43]; `roll_input` ∈ [0.62, 0.78] (a right bank) with `|pitch_input|` < 0.02 |
| T8 | Swings: dihedral ±40°, −60°, sweep ±30°, elbows 60° | `|u_i| < 0.05` |
| T9 | Right hand 30° lower (δ_a = 15°) | `roll_input` ∈ [0.3, 0.5] |
| T10 | Grip-convention robustness: every controller basis post-multiplied by 3 seeded random rotations ≤ 40°, then recalibrate | whole gesture library within 0.02 of the reference |
| T11 | Canonical flap: flat; leading edge down 20° and 30°; leading edge up 40° | peak flap ∈ [0.9, 1.3]; normal within 3° of up; tilted forward 14–20° and 32–36°; tilted back 17–20° |
| T12 | The §6.5 rejection set | ∫flap² ≤ 1% of canonical; frantic 8 cm/4 Hz ≤ 5% |
| T13 | Slow recovery with a fast power stroke | ≥ 50% of canonical |
| T14 | Crouch 0.4 m in 0.3 s, a jump, walking at 1 m/s | flap ≡ 0 |
| T15 | One-wing flap, 1 Hz ±45° | only that wing's flap > 0; `|roll_input|` from dihedral < 0.1 |
| T16 | Crossed arms; hands at the chest (before and after `has_spread`) | `body_yaw` holds within 10°; `e` ≥ 0.85 before, ≈ 0 after |
| T17 | Physical turn of 180° in 2 s spread; the same while tucked, then spread | lag ≤ 8°; converges ≤ 0.5 s after the spread; no flip |
| T18 | Right hand lost for 0.2 s / 2 s; both lost | unchanged; mirrored within 0.6 s; neutral within 1 s and `tracking` = 0 |
| T19 | Calibration: spans 1.30/1.50/1.90, seated/standing, neutral twist offsets −25…+25° | T1, T7 and T8 pass for every body |
| T20 | Latency steps (§7) | within the targets in the table |
| T21 | Determinism | identical state hash over 3 runs |
| T22 | Auto-trim | a 5° offset held for 120 s is absorbed (≥ 80%); a 20° deliberate input is untouched |
| T23 | Soar lock | arms dropped to −85° with both grips give `e` ≥ lock value; twist still reads |

### 15.2 Integration tests (flight suite: `PlayerBird` headless with `ScriptedPoseSource`)
| # | Scenario | Pass criteria |
|---|---|---|
| I1 | A 60 s scripted flight (flaps, banks, dives, physical turns, growth) | `XROrigin3D` and `PlayerBird` bases are pure yaw with unit scale every tick (`|basis.y − UP| < 1e-5`, `|det − 1| < 1e-5`) |
| I2 | Yaw smoothness | §11.3 bounds hold |
| I3 | Head pivot: turning at 90°/s with the head 1 m from the room centre | the head's world step is ≤ v·dt·1.05 |
| I4 | Physical 90° body turn at cruise | `aero_yaw` unchanged (< 0.5°); velocity heading within 5° of the new heading in ≤ 1 s |
| I5 | Growth ramp mid-flight | head world path continuous (≤ v·dt + 1 mm) |
| I6 | **Bot pilot course** (§15.3): perch → takeoff → climb 20 m → hold ±3 m for 30 s → 360° turns both ways → dive and pull out → a 1.5-wingspan gap → flare and perch | completes; flap duty ≤ 40% in the level segment; trajectories and channels plotted |
| I7 | "Lazy" pilot: arms at −45°, soft elbows, no flapping, in a thermal | glides ≥ 20 s from 30 m; climbs in the thermal with zero flaps |

### 15.3 Bot pilot that moves arms, not numbers (`PosePilot`, in `tests/` or `scripts/flight/dev/`)
A goal-seeking controller that outputs `HumanPoseModel` joint angles rather than
`WingState`. It therefore exercises calibration, body-frame estimation, shaping, flap
detection and the aerodynamics together.

**Human limits:**
- arm angular speed ≤ 8 rad/s, twist rate ≤ 360°/s
- reaction delay 120 ms
- tremor 1.5 mm at 9 Hz, twist noise 1.5°
- overshoot of 10% on steps

**Profiles:**
- `expert` (uses twist and sweep)
- `novice` (arm tilt and flaps only, twist near neutral with ±4° wander)
- `lazy` (low arms, soar lock)
- `seated`

**Control laws:**
- altitude → flap tempo and amplitude
- heading error → arm-tilt bank
- speed → twist

The pilot writes `artifacts/flight/course_<profile>.png`: top view, altitude over time, and
the input channels. It is rendered by Godot, with each image reviewed by eye.

### 15.4 Replay fixtures (after the Quest Pro arrives)
Record 5 × 3 min sessions (novice, expert, seated, lazy, abuse: shaking and flailing) with
`PoseRecorder`. Commit them to `tests/fixtures/poses/`. Replay tests assert that the
statistics are stable:
- flap-onset count within ±10%
- no onset during the "abuse-shake" segments
- `body_yaw` never jumps > 30° in a tick

These re-tune the §6 and §7 constants against real hands.

### 15.5 Meta XR Simulator checks (vr area, `tools/xr.sh`)
- **S1 (axes regression).** The probe in §1.3 asserts, within 5°: grip = aim · Rx(60°), the
  `default` pose is aim, and node origins scale with `world_scale` while raw poses do not.
  Reason: if a runtime update changes the grip convention, the defaults need
  re-derivation.
- **S2 (scripted flight through the real XR path).** Run `--pose-source=scripted:course`,
  where the simulator's controllers are fixed, and take `--xrshot` mirror captures. The
  logs must show `bank > 30°` while the `XRCamera3D` global basis has zero roll and pitch
  beyond the head's own. The screenshots show a level horizon during a banked turn.
- **S3.** Enable `--xrdiag` for 60 s: no errors, 90 Hz physics, `WingInput` at most 0.3 ms
  per tick.

### 15.6 Visual evidence
`scenes/dev/flight_vr_dev.tscn` renders, for each gesture in the library:
- the `HumanPoseModel` skeleton
- the estimated neck, shoulders and body frame (RGB axes)
- the wing planes with their normals
- a `WingState` read-out

It produces one screenshot per gesture: `artifacts/flight/gesture_<name>.png`. Channel
plots over time go to `artifacts/flight/wing_input_<gesture>.png`.

---

## 16. Parameter table (starting values; tune from replays)
| Name | Value | § |
|---|---|---|
| neck offset (head frame) | (0, −0.08, +0.09) m | 3.3 |
| shoulder_drop / width | 0.24 m / 0.23·span | 3.3 |
| torso follow τ / leash / drift τ / jump gate / rate | 0.10 s / 70° / 4 s / 75° / 400°/s | 3.2 |
| `c_span` ramp | 0.35 → 0.75 of span | 3.2 |
| extension reach ramp | 0.30 → 0.62 (`R_HI`) | 4.1 |
| fold elevation | −62° → −82° | 4.1 |
| fold sweep-back | −35° → −70° | 4.1 |
| novice floor | 0.85 | 4.1 |
| twist (per-wing and symmetric) dz / full up / full down / expo | 5° / 40° / 30° / 1.4 | 5.1 |
| aileron (antisymmetric twist) dz / full / expo | 4° / 25° / 1.3 | 5.1 |
| dihedral dz / full / expo | 4° / 30° / 1.2 | 5.1 |
| sweep dz / full / pitch gain | 12° / 35° / 0.30 | 5.2 |
| flap normal tilt: forward / back | 35° / 20° | 4.5 |
| velocity low-pass | 2 × 8 Hz | 6.1 |
| `W_UP` / `W_DN` | 0.15 / 0.9 rad/s | 6.2 |
| credit arc (standing / seated) | 12°→35° / 9°→26° | 6.2 |
| bank max / leak | 150° / 8 s | 6.2 |
| `ω_full` (standing / seated) | 4.5 / 3.4 rad/s, calibrated to 3.0–6.0 | 6.3 |
| effort cap | 1.3 | 6.2 |
| onset threshold / pairing window | 0.25 / 60 ms | 6.4 |
| grip on / off | 0.6 / 0.4 | 5.3 |
| tracking hold / mirror blend / both-lost blend | 0.25 / 0.6 / 0.8 s | 2.3 |
| auto-trim τ / band / bound | 60 s / 12° / ±10° | 8.4 |
| vignette yaw / flow / accel | 35→150°/s, 2.5→9 rad/s, 6→20 m/s² perceived | 11.4 |
| `ws` | span / (arm_span + 0.20) | 12 |
| `ws` ramp | ≤ 0.25 ln/s | 12 |

---

## 17. Risks and open questions for the panel
1. **Perceived speed of small birds** (§11.4 table). Exact wing-to-hand scale is right for
   gameplay readability, but a sparrow cruises at a perceived 64 m/s. Decide with the aero
   and gameloop panelists whether the early tiers' `performance().cruise` should be lower,
   or whether the playtest vignette is enough. Measure it on the Quest Pro in week one.
2. **Attitude versus rate for roll.** This lens asks for an attitude-like response (R2). A
   purist rate-command aileron would be "more real" but would spiral novices. A possible
   compromise: attitude-like for the dihedral term, and more rate-like for the twist term
   at assist 0.
3. **Physical heading (D7)** needs the sideslip model. If the aero panel rejects it, the
   fallback is the "slow re-orientation" alternative: rotate `aero_yaw` toward the torso at
   ≤ 8°/s after 3 s beyond 55°. It is worse for comfort and it is what the sibling attempt
   shipped.
4. The **grip-convention defaults** were measured in the simulator, not on a physical Touch
   Pro. Calibration makes this moot for play, but re-run the S1 probe on the device and
   update §1.3.
5. **Seated in a fixed chair** limits dihedral and physical turning. Twist ailerons and the
   optional snap turn carry it. Verify with the seated bot profile, then on the device.
