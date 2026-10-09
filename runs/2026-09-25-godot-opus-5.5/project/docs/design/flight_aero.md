# Flight model & controls — the Aerodynamicist's design

Panel lens: **physical fidelity**. Scope: `FlightModel` (physics), `WingState` /
`WingInput` / pose sources (controls), `PlayerBird` (rig integration) and how all
of it is verified without a headset.

**Evidence standard.** Every number in §9 comes from a Python prototype that
implements exactly the equations in §3–§7. It was run at a fixed 1/240 s step
for all ten species (scripted inputs, no headset). Those runs drove every
parameter choice here; several first ideas failed and are listed in §16 so they
are not re-tried. The GDScript `FlightModel` must reproduce §9 within the
tolerances of §13.

Conventions: SI units, Godot axes (+Y up, **-Z forward**, +X right),
right-handed. Body frame B = Godot local axes of the bird. Rates use aerospace
names:

- `p` = roll rate, positive when the right wing goes down.
- `q` = pitch rate, positive nose up.
- `r` = yaw rate, positive nose right.

In Godot body components that is `ω_B = (q, -r, -p)`. Bank `φ` is positive with
the right wing down. Heading `ψ` follows the Godot convention (CCW from above =
`rotation.y`). `θ` is body pitch, `γ` flight-path angle, `α` angle of attack
(AoA), `β` sideslip (positive when air comes from the right, i.e. the nose is
left of the path).

---

## 0. Decisions in one screen

1. **One physics for player and NPCs.** Each wing is a single blade element
   with a full-range airfoil model: attached lift, stall with hysteresis,
   post-stall flat plate, and dynamic-stall/LEV augmentation while flapping.
   Flapping is **the same wing moving through the air**: stroke velocity is
   added to the local airflow. There is no separate "thrust" force.
2. **Flap force goes along the wing normal.** When the local flow is dominated
   by the stroke, leading-edge suction is lost (the LEV regime) and the
   resultant is normal to the plate. This is the robofly result and exactly
   the user's mental model.
   - The stroke plane is referenced to the **horizon** in pitch, not to the
     simulated body pitch. The player's arms live in a gravity-aligned frame
     and their camera never pitches.
   - Flat wrists push straight **up** (0.0–0.6° measured). Wrists pitched
     forward push **up and forward** (14° at half deflection, 35° at full).
   - Upstrokes are feathered: less than 3% of the downstroke force.
3. **Size is allometry, not a lookup.**
   - Wing area comes from the stall-speed target: `min_speed` is the 1-g stall
     at `CL_max = 1.4`. Span comes from `SizeRules`; CD0 falls with size.
   - Cruise, glide ratio (5.6 → 9.1 at cruise, 6.8 → 13.6 best), sink, turn
     radius and roll rate `p ∝ V/b` **emerge** from these.
   - The hover gradient emerges too: stroke speed is nearly size-independent
     while wing loading rises 5× from sparrow to eagle. Hover climb: sparrow
     +1.15 m/s, starling ±0, pigeon -1.7, eagle -5.3 m/s.
4. **Attitude.** The body quaternion follows the stroke-averaged flight path,
   which amounts to a perfectly weathercock-stable, perfectly rudder-coordinated
   airframe.
   - α has explicit short-period dynamics that track the AoA the wrists
     command. The **balloon** is genuine point-mass physics: lift jumps, the
     path curves up, speed bleeds, and the bird settles slower. It rises about
     5 wingspans at every size.
   - The phugoid is damped by a flight-path washout expressed in load-factor
     terms.
5. **Roll is bank-command.** Differential wrist twist plus arm-line tilt set a
   target bank. The bird's reflex moves a *physical* aileron twist
   (≤ 1.0–3.6°), so roll acceleration and rate come from real rolling moments
   and physical roll damping.
   - The maximum roll rate scales as `V/b`: sparrow 360°/s, eagle 150°/s.
   - Rate-command ailerons are unflyable when the camera never rolls, because
     the player cannot see bank.
6. **Yaw.** Coordination is by construction: the body follows the lift-driven
   path rotation and adverse yaw is computed and cancelled by an auto-rudder
   gain `k_rud`.
   - The player's **torso yaw is the body yaw**, applied kinematically. The
     flight path follows through sideslip side-force (a skid) with a time
     constant of 0.7–1.7 s.
   - Coordinated turning is what yaws the rig.
7. **Every non-physical term is a named, bounded "gameplay law"** (§1). There
   are thirteen, and each has a physical analogue.
8. **Integration.** Semi-implicit Euler with fixed substeps `h ≤ 1/240 s`
   (72 Hz → 4, 90 Hz → 3). Deterministic. Trajectories at 60/72/90/120 Hz
   agree within 0.2 m after 12 s of mixed manoeuvres.

---

## 1. Gameplay-law ledger (what is not raw physics, and why)

| # | Law | Why | Physical analogue | Bound |
|---|---|---|---|---|
| L1 | Bank-hold reflex (attitude-command roll) | Camera never rolls, so bank is invisible and rate command is unflyable | Vestibular wing-levelling reflex; autopilot bank hold | Acts only through physical aileron twist `\|δ\| ≤ δ_lim` |
| L2 | Perfect auto-rudder | Requirement 3 (coordinated) | Rudder + strong weathercock stability | `k_rud` gain (1 = perfect; tests set 0 to prove adverse yaw exists) |
| L3 | Turn compensation (auto-pull `1/cosφ`) | Level turns without the player pulling | What pilots and birds do | α capped at `α_s - 3°` |
| L4 | Phugoid damper (flight-path washout) | The raw phugoid (ζ ≈ 0.07) porpoises | Attitude-holding pilot | `K_g = 0.3`, ±4° clamp, load-factor scaled |
| L5 | Envelope protection: `φ ≤ acos(1/n_avail)`, `n ≤ n_max`, pitch stop `θ ∈ [−82°, 70°]` | No spiral dives from full input, no 12 g pull-outs, no loops (heading stays defined for the rig) | Airliner envelope protection; bird structural limits | n_max 5.4–7 g; stop ω = 8 rad/s |
| L6 | Speed governor above 0.75·V_max | `SizeRules.max_speed` contract, VR comfort | none (the physical terminal speed is 1.4–1.7× higher) | Exactly `max_speed` in a tucked vertical dive |
| L7 | Stroke plane referenced to the horizon | The player's arms are gravity-aligned and the body pitch is invisible to them | Birds set stroke-plane angle independently of body angle | Blended in by stroke dominance only |
| L8 | Heave decoupling (attitude follows the stroke-averaged path) | Without it the body pitched ±15° every wingbeat | Body inertia filtering wingbeat forces | τ = 0.35 s |
| L9 | Asymmetric roll-moment soft clip, yaw-kick clamp | One-wing flaps should kick, not flip | Reflex counter-twist | `k_asym = 1.3`, `k_yaw_kick = 0.4` |
| L10 | Hover posture reflex (low airspeed) | Aero moments vanish near V = 0 | Hovering birds hold posture actively | Blended out by 1.0·V_s |
| L11 | Game roll inertia (τ_p 0.10–0.22 s instead of ~0.01 s) | Smooth, never snappy turning in VR | none (real small birds roll almost instantly) | Chosen per size from agility |
| L12 | Stroke gain `G(m)` (human arm swing → bird wingbeat) | Humans flap at 1–2 Hz, birds at 3–20 Hz | Wingbeat-frequency multiplier | Calibrated (§4) |
| L13 | Muscle power cap `P_max(m)` | Frantic flapping must not win | Flight-muscle power | Physical scale (175–375 W/kg instantaneous peak; 30–70 W/kg cycle average) |

Everything else (lift, drag, stall, gravity, energy trade, wind, induced drag,
roll damping, adverse yaw, sideslip side force, stall wing-drop) is
first-principles and **emerges**.

---

## 2. Architecture

```
PoseSource ──PoseFrame──▶ WingInput ──WingState──▶ FlightModel.step(dt, ws, wind)
 (XR / Scripted /          (calibrated,             (pure RefCounted, no scene deps)
  Replay / Desktop)         scale-free)                     │ state, telemetry, events
                                                            ▼
                                  PlayerBird (Bird): rig yaw + translation, collisions,
                                  perching, Events, telemetry(), comfort limiter
FlightAutopilot ──WingState──▶ FlightModel   (tests' bot pilot; NPCs that fly real physics)
```

- `WingState` is the only input FlightModel ever sees. NPCs, tests and the
  bot build it directly (`WingState.from_commands`) or through a
  `ScriptedPoseSource` (end-to-end chain tests).
- FlightModel never reads nodes, never calls `World`: wind is a `Callable(pos) ->
  Vector3` passed in, typically `world.get_wind`.

---

## 3. State vector

| Symbol | Type | Meaning |
|---|---|---|
| `x` | Vector3 | position (m, world). For the player this is **the head** (the Bird contract) |
| `v` | Vector3 | inertial velocity (m/s, world) |
| `Q` | Quaternion | body→world attitude (Godot body axes) |
| `p` | float | roll rate state (rad/s), full moment dynamics |
| `q_d` | float | pitch "deviation" rate (short-period / posture), rad/s |
| `r_d` | float | yaw deviation rate (flap yaw kick / uncoordinated part), rad/s |
| `φ_I` | float | bank reflex integrator (rad of aileron twist) |
| `α_c` | float | slew-limited AoA command (rad) |
| `γ_w` | float | washout-filtered flight-path angle (rad) |
| `a_f,lp` | Vector3 | low-passed flap acceleration (m/s²) |
| `v_hp` | Vector3 | high-passed flap heave velocity (m/s) |
| `Ω_ff` | Vector3 | flight-path feed-forward rate (body axes), from the previous substep |
| `stalled[2]` | bool | per-wing separated-flow flag (hysteresis) |
| `mode` | enum | FLYING / PERCHED / STUNNED / GROUNDED |

Total body angular velocity (body components):

```
ω_B = w_a·Ω_ff + ( q_d ,  −(r_d + r_β + p·sin α_b') ,  −p·cos α_b' )      α_b' = w_a·α_b
```

Roll acts about the **airflow (stability) axis**. Rolling about the body axis at
α ≠ 0 converts α into β; that produced 16° sideslip spikes in the prototype. `r_β`
is the NPC-only weathercock term (§6.4).

---

## 4. Size scaling: everything derives from mass

Inputs are `SizeRules.performance(m)` → `V_c` (cruise), `V_s` (min_speed),
`V_max`, `ω_turn`, `agility` (`agi`), and `b = SizeRules.wingspan_for_mass(m)`.
Let `k = m / 0.03`, `ρ = 1.225`, `g = 9.81`.

```
CL_max = 1.4,  CL_min = −0.7,  e = 0.85,  α0 = −4°  (cambered bird wing)
S      = 2 m g / (ρ V_s² CL_max)                 wing area: V_s is the 1-g stall speed
AR     = b² / S
a      = 2π·AR/(AR+2) · 0.95                      3-D lift slope, per rad
CD0    = clamp(0.040 − 0.006·log10 k, 0.024, 0.045)   ; 60 % on the wing (∝ area), 40 % body
CD0w   = 0.6·CD0       (per unit wing area)         CdA_body = 0.4·CD0·S
CD90   = 1.8           (flat plate normal)
CL_c   = 2 m g/(ρ V_c² S)   (= CL_max·(V_s/V_c)² = 0.2835 for every species)
α_trim = α0 + CL_c/a ;  α_s = α0 + CL_max/a ;  α_hi = α_s + 2° ;  α_lo = α0 − 3°
L/D_max = ½·sqrt(π e AR / CD0)
```

Control and dynamics parameters:

```
w_sp  = 4 + 8·agi        ζ_sp = 0.7      (short period on α)
w_post= 6,  θ_post_max = 30°             (hover posture)
K_g   = 0.3, T_w = 0.35·π√2·V_c/g, clamp 4°   (phugoid damper; T_w = 0.35 phugoid period)
φ_max = atan(ω_turn·V_c/g)               (bank that gives SizeRules turn rate at cruise)
w_roll= 2.5 + 6·agi,  ζ_roll = 0.9,  τ_p = 0.10 + 0.15·(1−agi)
y_ac  = 0.45·(b/2)                        aerodynamic centre of each half-wing
Cl_δ  = a·y_ac/b                          rolling moment per rad of differential twist (both wings)
c_roll= ½ ρ V_c S a y_ac²                 physical roll damping at cruise (N·m·s)
I_x   = τ_p·c_roll   ;  I_z = 1.5·I_x    (game inertia, L11)
L_δ   = Cl_δ·½ρV_c²·S·b
K_φ   = w_roll²·I_x / L_δ ; K_pd = max(0, (2ζ w_roll I_x − c_roll)/L_δ) ; K_I = K_φ·w_roll/12
p_tgt = radians(60 + 300·agi^0.8)         (roll-rate target at cruise)
δ_lim = p_tgt·b/(4.44·V_c)                (aileron twist limit → p_max ≈ 4.44 δ V / b, strip theory)
p_clamp = 1.5·p_tgt ;  n_max = 5 + 2·agi ;  φ_hover = 35°
G(m)  = 1.25·k^−0.08   (m/s of bird stroke per rad/s of arm swing)          L12
P_max = 300·m·k^−0.11  (W, instantaneous, both wings)                       L13
Governor: D_gov = gov_D·((V − 0.75 V_max)/(0.25 V_max))²  for V > 0.75 V_max,
          gov_D = m g − ½ρV_max²·(CdA_body + CD0w·0.2·S)   (exact V_max in a tucked vertical dive)
```

`set_mass(m)` recomputes all of this (about 60 flops) and keeps the state.
Growth is continuous. The small span discontinuities at `SizeRules` tier
boundaries shift AR a little at tier-ups, which is intended: a new species
flies differently.

### 4.1 Derived table (prototype output)

| species | m kg | b m | S m² | AR | W/S N/m² | a /rad | CD0 | L/D max | α_trim° | α_s° | V_s | V_c | V_max | φ_max° | w_sp | w_roll | τ_p s | δ_lim° | G | P_max W | n_max |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| moth | 0.004 | 0.08 | 0.0055 | 1.17 | 7.2 | 2.21 | .0450 | 4.2 | 3.4 | 32.4 | 2.9 | 6.4 | 16.7 | 76.8 | 12.0 | 8.5 | .100 | 1.01 | 1.47 | 1.5 | 7.0 |
| wren | 0.012 | 0.16 | 0.0114 | 2.25 | 10.4 | 3.16 | .0424 | 6.0 | 1.1 | 21.4 | 3.5 | 7.7 | 20.1 | 75.4 | 12.0 | 8.5 | .100 | 1.68 | 1.35 | 4.0 | 7.0 |
| **sparrow** | 0.030 | 0.24 | 0.0209 | 2.75 | 14.1 | 3.46 | .0400 | 6.8 | 0.7 | 19.2 | 4.05 | 9.0 | 23.4 | 74.2 | 12.0 | 8.5 | .100 | 2.16 | 1.25 | 9.0 | 7.0 |
| swallow | 0.055 | 0.33 | 0.0313 | 3.47 | 17.2 | 3.79 | .0384 | 7.8 | 0.3 | 17.2 | 4.5 | 10.0 | 25.9 | 73.3 | 10.7 | 7.5 | .125 | 2.38 | 1.19 | 15.4 | 6.7 |
| starling | 0.090 | 0.40 | 0.0435 | 3.68 | 20.3 | 3.87 | .0371 | 8.1 | 0.2 | 16.7 | 4.9 | 10.8 | 28.1 | 72.5 | 9.8 | 6.8 | .142 | 2.42 | 1.15 | 23.9 | 6.4 |
| **pigeon** | 0.35 | 0.66 | 0.1076 | 4.05 | 31.9 | 3.99 | .0336 | 9.0 | 0.1 | 16.1 | 6.1 | 13.6 | 35.2 | 70.4 | 7.8 | 5.4 | .178 | 2.48 | 1.03 | 80.1 | 6.0 |
| crow | 0.60 | 0.95 | 0.1542 | 5.85 | 38.2 | 4.45 | .0322 | 11.0 | −0.3 | 14.0 | 6.7 | 14.8 | 38.6 | 69.4 | 7.3 | 4.9 | .189 | 2.98 | 0.98 | 129 | 5.8 |
| gull | 1.10 | 1.30 | 0.2309 | 7.32 | 46.7 | 4.69 | .0306 | 12.6 | −0.5 | 13.1 | 7.4 | 16.4 | 42.7 | 68.3 | 6.7 | 4.5 | .199 | 3.33 | 0.94 | 222 | 5.7 |
| hawk | 1.60 | 1.60 | 0.2965 | 8.63 | 52.9 | 4.85 | .0296 | 13.9 | −0.6 | 12.6 | 7.9 | 17.5 | 45.4 | 67.6 | 6.4 | 4.3 | .205 | 3.62 | 0.91 | 310 | 5.6 |
| **eagle** | 4.50 | 2.10 | 0.5907 | 7.47 | 74.7 | 4.71 | .0269 | 13.6 | −0.5 | 13.0 | 9.3 | 20.7 | 53.9 | 65.6 | 5.8 | 3.8 | .217 | 3.42 | 0.84 | 778 | 5.4 |

Game-scaled areas are about 2× real for small birds (a real sparrow has about
0.009 m²), so that `min_speed = 0.45·cruise` holds. The pigeon is about 1.6×
real and the eagle (0.59 m²) is close to real. Wing loading still rises 5× from sparrow to eagle, which is what
makes big birds fast, heavy and hover-incapable.

**The moth is NPC food only.** Its AR of 1.2 and α_s of 32° make it fluttery
and nearly balloon-free. That is fine for prey and not tuned for the player.

---

## 5. Per-wing aerodynamics

### 5.1 Geometry (per wing w, side σ = −1 left, +1 right)

```
e     = clamp(ext_w, 0, 1)                   A = 0.2 + 0.8 e   (area fraction; tucked keeps 20 %)
B     = 0.35 + 0.65 e                         (span fraction)
S_w   = ½ S A ;  AR_e = AR·B²/A               (tuck lowers effective AR: induced drag per CL rises)
δ_w   = clamp(dihedral_w, −35°, +35°)         (aero dihedral clamp: huge arm swings are not penalised)
span  = (σ cos δ_w, sin δ_w, 0)               root→tip
ê_s   = (cos δ_w, σ sin δ_w, 0)               spanwise unit pointing to body +X for both wings
ĉ0    = (0,0,−1) ;  n̂0 = ê_s × ĉ0            (n̂0 is "up" for both wings)
inc_w = i_mean − σ·δ_ail                       incidence: mean AoA share + reflex aileron twist
ĉ_g   = ĉ0 cos inc + n̂0 sin inc ;  n̂_g = n̂0 cos inc − ĉ0 sin inc     (glide chord / normal)
r_w   = span · y_ac · B                        aerodynamic centre relative to CG
```

### 5.2 Stroke velocity and the stroke-plane reference (L7)

`WingState.stroke_w` is the hand velocity relative to the shoulder, in the
**torso frame** (horizon-level; x right, y up, z back), divided by arm length
(units 1/s, "arm-lengths per second"). FlightModel maps it into body axes with
the level→body rotation `q_BL = Q⁻¹ · (Yaw(ψ) · Roll_fwd(φ))`. The level frame
has the body's heading and bank but no pitch: flapping is bank-referenced
(flapping in a turn tightens it, as it physically should) and
horizon-referenced in pitch.

```
s_raw = q_BL · stroke_w ;  |s| < 0.5 → v_s = 0 (tracking-noise deadzone)
v_s   = G·k_P·(|s| − 0.5)/|s| · s_raw            k_P = power-cap scale (§5.6), 1 when uncapped
i_s   = θ_post_max·curve(τ_sym) + k_inc·(α_c − α_trim) − σ δ_ail   stroke incidence
ĉ_s   = q_BL · (ĉ0 cos i_s + n̂0 sin i_s)
s_est = clamp(2·(−v_s·n̂_g)/(|u_b| + |v_s|), 0, 1) ;  r_s = smoothstep(0.1, 0.6, s_est)
ĉ     = normalize(lerp(ĉ_g, ĉ_s, r_s)) projected ⊥ ê_s ;   n̂ = ĉ × ê_s  (flip so n̂·n̂0 > 0)
```

Gliding uses the body-referenced chord (AoA control), and a hard flap uses the
horizon-referenced stroke plane. In between, the two blend by how much the
stroke dominates the local flow.

### 5.3 Local airflow (wind, rotation, stroke)

```
u_b  = Q⁻¹·(W(x) − v)                   air velocity relative to the body (body axes); W = world.get_wind
u_g  = u_b − ω_B × r_w                  + rotation (this is where roll damping and yaw-rate lift asymmetry come from)
v_sn = v_s · n̂
downstroke (v_sn < 0):  u = u_g − v_s ;              S_eff = S_w
upstroke   (v_sn ≥ 0):  u = u_g − (v_s − v_sn n̂) ;   S_eff = S_w·(1 − 0.1·smoothstep(0,1,v_sn))
                        (feathered: the stroke-normal component is sliced away, area −10 %)
u⊥   = u − (u·ê_s)ê_s   (sweep theory: spanwise flow does no work)
V_l  = |u⊥| ; d̂ = u⊥/V_l ; q_l = ½ρV_l²
α_w  = atan2(d̂·n̂, −d̂·ĉ)                full range, −π..π
s    = downstroke ? clamp(−v_sn/V_l, 0, 1) : 0        stroke dominance
```

Wind is sampled at the CG. An optional flag samples it at both wing ACs
(two extra `get_wind` calls) so the edge of a thermal rolls the bird; this is
recommended for the player and off for NPCs.

### 5.4 Full-range section model (per wing)

```
s'     = smoothstep(0, 0.45, s)                         LEV / dynamic-stall onset (saturates early)
CLmax' = 1.4 + 0.6 s' ;  CLmin' = −0.7 − 0.6 s'
raw    = a(α − α0) ; CL_att = raw soft-saturated at 0.85·CLmax' (tanh knee, same for CLmin')
α_s'   = α0 + CLmax'/a + 15°·s' − 4°·stalled ;  α_sn' = α0 + CLmin'/a − 15°·s' + 4°·stalled
σ      = max(smoothstep(α_s', α_s'+5°, α), smoothstep(−α_sn', −α_sn'+5°, −α))   separated fraction
CN_ps  = 1.8·(1 + 0.8 s')·sin α / (0.56 + 0.44|sin α|)                           Hoerner flat plate (+LEV)
CL     = (1−σ)·CL_att + σ·CN_ps cos α
CD     = CD0w + (1−σ)·CL_att²/(π e AR_e) + σ·CN_ps sin α
stall flag (only when s < 0.3): set at α > α_s + 1.5°, clear at α < α_s − 4°  (hysteresis)
```

### 5.5 Force: normal/tangential with leading-edge-suction loss

```
CN = CL cos α + CD sin α ;  CT = CD cos α − CL sin α      (CT > 0 pushes toward the trailing edge)
ls = smoothstep(0.5, 0.95, s)                              stroke-dominated → LE suction lost
CT ← CT + (CD0w·cos α − CT)·ls                             resultant ≈ plate normal + skin friction
F_w = q_l·S_eff·(CN·n̂ − CT·ĉ)          (body axes)
M_w = r_w × F_w ;  P_w = −F_w · v_s     (muscle power; > 0 on the downstroke)
```

In attached gliding flow (`ls = 0`) this is exactly lift ⊥ flow plus drag
∥ flow. In a hover downstroke (α ≈ 90°) it is the moving plate, force along
n̂. Requirement 1 holds by construction.

### 5.6 Muscle power cap (L13)

```
P = Σ P_w (k_P = 1). If P > P_max: repeat ≤ 3×: k_P ← k_P·(P_max/P)^0.4, re-evaluate both wings.
```

Evaluation is lazy: when `P ≤ P_max` there is no second pass. Frantic
flapping (60°, 2.2 Hz) is capped to k_P ≈ 0.3–0.55 and ends up roughly equal to
the reference flap, not better.

### 5.7 Body forces

```
β      = asin(−u_b.x/|u_b|)
D_body = q̄·CdA_body·(1 + 3β²)  along û_b                 (sideslip costs drag)
Y      = q̄·S·CYβ·β  along body x,  CYβ = −0.35           (side force: what makes the path follow a torso turn)
D_gov  (L6) along û_b
F_total = Q·(ΣF_w + D_body + Y + D_gov) + (0, −m g, 0)
```

Two optional extras: ground effect, which multiplies induced drag by
`(16h/b)²/(1+(16h/b)²)` with h = AGL passed in as a hint, and per-wing wind
sampling.

---

## 6. Control laws (the bird's airframe stability and reflexes)

### 6.1 Pitch channel: AoA from symmetric wrist pitch

```
τ_sym = ½(pitch_l + pitch_r) ∈ [−1,1] ;  c = curve(τ_sym),  curve(x) = x(0.6 + 0.4|x|)   (expo: fine near neutral)
α_raw = α_trim + c·(α_hi − α_trim)   (c ≥ 0)      |   α_trim + c·(α_trim − α_lo)   (c < 0)
α_c  ← α_c + clamp(α_raw − α_c, ±60°/s·h)                                    slew (wrist jitter filter)
Δα_tc = k_tc·(1/max(cos φ, 0.25) − 1)·min(mg/(q̄S), CL_max)/a · w_a          turn compensation (L3), k_tc = 1
α_cmd = min(α_c + Δα_tc, max(α_c, α_s − 3°))                                  compensation never stalls the wing
α_cmd = min(α_cmd, max(α_trim, α0 + n_max·mg/(q̄S)/a))                       load-factor limit (L5)
i_mean = k_inc·(α_cmd − α_trim), k_inc = 0.3                                   30 % of an AoA change is instant wing twist
```

Neutral wrists trim at `V_c`. Full wrist-up gives `α_s + 2°`: a deliberate
flare or stall, which is also the landing flare used for perching. Full
wrist-down gives `α0 − 3°`, which is negative lift and makes the bird push
over into a dive.

### 6.2 Pitch dynamics: flight-path feed-forward, short period, balloon, phugoid damper

1. **Feed-forward (weathercock).** The body rotates with the *stroke-averaged,
   lift-driven* rotation of the airflow vector:
   ```
   a_ff  = a − a_side − a_flap + a_f,lp          (exclude body side force and instantaneous flap pulses)
   v_m   = v − W − v_hp                            (heave-corrected airflow)
   Ω_ff  = (v_m × a_ff)/|v_m|²   → body axes, × w_a
   ```
   `a_flap = Q·F_flap/m`, where `F_flap = F_wings − F_wings(stroke = 0)` comes
   from a glide-only pass that is evaluated only while stroking. It feeds
   `a_f,lp ← a_f,lp + (a_flap − a_f,lp)·h/0.35` and
   `v̇_hp = (a_flap − a_f,lp) − v_hp/0.35` (L8). If the side force were not
   excluded, a torso turn would self-perpetuate: body chases path chases body.
2. **Short period on α** (heave-corrected `α_b = atan2(u_m.y, u_m.z)`,
   `u_m = Q⁻¹(−v_m)`):
   ```
   γ    = asin(v_m.y/|v_m|) ;  γ_w ← γ_w + (γ − γ_w)·h/T_w
   α_tgt = α_cmd − i_mean − clamp(K_g(γ − γ_w), ±4°)·min(1, (V_c/|v_m|)²)      phugoid damper in load-factor units (L4)
   q̇_d  = w_a·w_sp²·clamp(α_tgt − α_b, ±0.8) + (1−w_a)·w_post²·(θ_post − θ) − 2ζ_sp·(w_a w_sp + (1−w_a) w_post)·q_d
   θ_post = θ_post_max·c                                                     hover posture (L10)
   ```
   Because `ω = Ω_ff + q_d`, the equation is `α̈ = ω²(α_tgt − α) − 2ζωα̇`,
   the textbook short period.

   Pitch stop (L5):
   ```
   θ > 70°:  q̇_d += −8²(θ − 70°) − 2·8·max(0, q_body)
   θ < −82°: q̇_d += −8²(θ + 82°) − 2·8·min(0, q_body)
   ```
   Here `q_body = q_d + Ω_ff.x`. Stoops still reach −82…−88° path angle; with
   the stop, pull-out height loss improves to 9.9 / 22.8 / 48.8 m.
3. **Balloon.** It is not scripted. A step in α_cmd raises CL (30% instantly
   through `i_mean`, the rest within 1/w_sp). The path curves up, gravity and
   induced drag bleed speed, and CL·q̄ returns to the weight at the new, slower
   trim. The damper removes the undershoot that followed (72–103% undershoot
   and near-zero airspeed without it).
4. **The load-factor scaling `(V_c/V)²` matters.** In α units, the damper
   cancelled 7 g of pull-out at 2.5·V_c; eagle pull-outs lost 240 m instead
   of 66 m (49 m with the pitch stop).

### 6.3 Roll channel: bank command → reflex aileron twist (L1) → physical moments

```
τ_diff = ½(pitch_l − pitch_r)            left LE up, right LE down → +  (roll right)
ail    = clamp(curve(τ_diff) + curve(tilt), −1, 1)
n_av   = 0.85·CL_max·q̄S/(mg) ;  φ_env = n_av > 1 ? acos(1/n_av) : 0           (L5: never hold an unsupportable bank)
φ_lim  = min(φ_max, max(φ_env, φ_hover·(1 − smoothstep(0.7V_s, V_s, V))))
φ_cmd  = clamp(φ_max·ail, ±φ_lim)
e_φ    = φ_cmd − φ ;  φ_I ← clamp(φ_I + e_φ·K_I·w_a·h, ±δ_lim)
δ_ail  = clamp(K_φ e_φ + φ_I − K_pd p, ±δ_lim)·w_a                         twist enters inc_w (±σ), §5.1
```

The rolling moment comes from the wings (`−(ΣM_w).z`). Aileron, damping, stall
wing-drop, one-wing flap and extension asymmetry are all in it. The only
treatment is to split and soft-clip the asymmetric part (L9):

```
L_auth = Cl_δ·max(q̄, q̄_floor)·S·b·δ_lim          q̄_floor = ½ρ(0.6 V_s)²
M_ail  = Cl_δ·q̄·S·b·δ_ail
M_damp = −½ρ V S(0.2+0.8ē) a y_ac(ē)² · p          physical strip-theory damping (ē = mean extension)
M_asym = 1.3·L_auth·tanh((M_roll − M_ail − M_damp)/(1.3·L_auth))
M_hov  = −I_x·(6²(φ − φ_hover·ail) + 2·0.9·6·p)·max(0, q̄_floor − q̄)/q̄_floor        (L10)
M_stop = |φ| > φ_max+5° : −sign(φ)·2.8·L_auth·smoothstep(0,5°,|φ|−φ_max−5°) − I_x·24·p·[p·φ>0]
ṗ      = (M_ail + M_damp + M_asym + M_hov + M_stop)/I_x ;   p ∈ ±p_clamp
```

The integral term is needed. In a descending turn the body really rolls
(`p = φ̇ − ψ̇ sin θ`) and physical roll damping resists it, so a P-only reflex
sits 6–8° short of the command. That shortfall is a big turn-rate error near
70° of bank.

Emergent roll behaviour: time to 90% bank is 0.34 s for the sparrow, 0.57 s
for the pigeon and 0.77 s for the eagle. Overshoot is at most 11%. Maximum
roll rate `≈ 4.44 δ_lim V/b` falls as speed drops, so controls are sluggish
when slow. A stalled wing drops (a roll toward it), bounded by L9 and the stop.

**Dihedral and spiral stability.** Arms raised in a V (symmetric `dihedral`
> 0) give the textbook dihedral effect with no extra code. The spanwise flow is
discarded per wing along its own tilted `ê_s`, so in a sideslip the windward
wing sees a higher α and rolls the bird away from the slip. The V also costs
`cos δ` of vertical lift. Both are physical and small next to the bank reflex.

The natural spiral mode, which is neutral in a coordinated turn because the
auto-rudder removes the sideslip that dihedral would act on, is deliberately
replaced by L1. Hold a twist and the bank holds; release it and the bird rolls
level. That is spiral stability as a reflex.

### 6.4 Yaw: coordination, adverse yaw, torso steering, kicks

- **Coordinated turns.** `Ω_ff` contains the lift-driven turn rate
  `g·tanφ/V`, so the body yaws with the path (β stays 0 in steady turns,
  < 1.5° at roll-in).
- **Adverse yaw** (physical). The more-lifting wing has more induced drag, so
  there is a yaw moment `N_glide` from the glide-only pass. The auto-rudder
  cancels the fraction `k_rud`:
  ```
  ṙ_d = (N_flap + (1 − k_rud)·N_glide)/I_z − r_d/0.15 ;  r_d ∈ ±0.4·ω_turn   (flap yaw kick, L9)
  ```
  With `k_rud = 0` the roll-in shows β = +2.3° (sparrow) or +0.7° (eagle) in
  the adverse sense. With `k_rud = 1` it is < 0.02°.
- **Torso yaw (player).** `apply_body_yaw(Δψ_torso)` rotates `Q` about world
  up kinematically each tick. Velocity is unchanged, so β appears, and the side
  force `Y` turns the path toward the body. The measured time to 63% is 0.71 s
  (sparrow), 1.10 s (pigeon) and 1.68 s (eagle). There is no yaw washout for
  the player, because that would rotate the rig against the player's physical
  turn: vestibular mismatch.
- **NPC weathercock.** `r_β = β/τ_β·w_a`, `τ_β = 0.35 + 0.35(1 − agi)`. It
  halves the NPC β transients.

### 6.5 Regime blend and hover

`w_a = smoothstep(0.5·V_s, 1.0·V_s, |v − W − v_hp|)` blends aerodynamic
attitude (feed-forward, α tracking, reflex aileron) against the posture
reflexes. Using total heave-corrected airspeed matters. The first version used
the forward airflow component, and a stalled bird falling belly-first then
held level posture forever instead of weathercocking its nose into the
relative wind: no stall recovery.

---

## 7. Integration scheme

```
step(dt, ws, wind):                       # called once per physics tick
  n = ceil(dt·240); h = dt/n              # 72 Hz→4, 90→3, 120→2, 60→4
  apply_body_yaw(ws.torso_dyaw)           # kinematic, once per tick
  for i in n: substep(h, lerp(ws_prev, ws, (i+1)/n))   # stroke & dihedral interpolated across substeps
substep(h, ws):
  1 read ψ,θ,φ; W=wind(x); commands (§6.1, §6.3 δ_ail) using state at start of substep
  2 forces (§5) with ω_B from current rates and Ω_ff from the previous substep
  3 v += a·h ; x += v·h                               semi-implicit (symplectic) Euler
  4 heave filters, Ω_ff from new v and a_ff (§6.2)
  5 q_d, p, r_d += rate·h (§6.2–6.4)                  rates updated before attitude
  6 Q ← Q ⊗ exp(ω_B·h/2) ; normalise
  7 guards: non-finite → restore last good state, zero rates, log once; |v| ≤ 3·V_max
```

**Stability.** The stiffest mode is the sparrow's short period, w_sp = 12
rad/s, so `w·h = 0.05` (Euler is stable for `w·h < 2`). Roll with τ_p ≥ 0.1 s
has `h/τ = 0.04`. Drag decay is below 1/s.

**Determinism.** The model is a pure function of state, inputs and the wind
callable, with no RNG. Verified results:

- 60/72/90/120 Hz ticks agree within 0.18 m (sparrow), 0.12 m (pigeon) and
  0.06 m (eagle) after 12 s of flap, cruise and turn.
- A 120 s soak with random wrist, extension, dihedral, tilt and ±12 /s strokes
  (re-randomised every 0.3 s) stays finite, with `|v| ≤ 0.67·V_max`.
- Such adversarial flailing can tumble small birds past 90° of bank or pitch.
  Eagles stay within 82°. After 10 s of flailing, every seed tested (8 seeds ×
  3 species) recovers to controlled flight (`|φ| < 20°`, `|θ| < 45°`,
  V > 1.05 V_s, unstalled) within 2.6 s of neutral input. The rig
  must not follow a tumbling body; see §12.2.

**Cost.** Each wing evaluation is about 150 flops. Gliding takes 2 evaluations
per substep. Flapping takes 4 (plus the glide-only pass), and 6–8 when
power-capped. In GDScript that is about 40–150 µs per substep, or about
0.2–0.6 ms per frame for the player at 4 substeps. See §14 for NPCs.

---

## 8. Analytic sanity checks (all reproduced by the prototype)

| Check | Formula | Sparrow | Pigeon | Eagle | Prototype |
|---|---|---|---|---|---|
| Stall speed | `V_s = sqrt(2mg/(ρ S CL_max))` | 4.05 | 6.10 | 9.34 | slowest steady 1.07·V_s (τ = 0.8) |
| Best-glide CL | `CL_md = sqrt(π e AR CD0)` | 0.542 | 0.603 | 0.733 | — |
| Best-glide speed | `V_md = V_c sqrt(CL_c/CL_md)` | 6.5 | 9.3 | 12.9 | 6.4 / 9.7 / 12.4 |
| L/D max | `½ sqrt(π e AR/CD0)` | 6.8 | 9.0 | 13.6 | 6.8 / 8.9 / 13.6 |
| Min sink | at `V_mp = 0.76 V_md`, L/D = 0.866·L/D_max | 0.84 | 0.91 | 0.83 (V_mp near V_s) | 0.83 / 0.90 / 0.84 |
| Trim at neutral | `L = W` at `CL_c`, glide `1/(L/D(CL_c))` | 9.0, 5.6:1 | 13.6, 6.9:1 | 20.7, 9.1:1 | 8.93 / 13.48 / 20.65 |
| Coordinated turn | `ω = g tanφ / V` | — | — | — | < 1% error in steady turns, β_ss < 0.3° |
| Balloon energy bound | `Δh ≤ (V1² − V2²)/2g` | 2.58 | 5.9 | 13.9 | 1.25 / 3.76 / 10.8 m (48–78%) |
| Phugoid period | `T = π√2·V/g` | 4.1 s | 6.1 s | 9.4 s | damper T_w = 0.35 T |
| Max roll rate | `p ≈ 4.44 δ_lim V/b` | 6.3 rad/s | 3.95 | 2.62 | p_tgt by construction |
| Tucked terminal (physics) | `sqrt(2mg/(ρ CdA_tuck))` | 33 | 55 | 93 | governor caps at 23.3 / 35.1 / 53.6 = V_max |
| Hover ideal power | `(mg)^1.5/sqrt(2ρA_disk)`, `A_disk = 0.7·π(b/2)²` | 0.57 W | 8.3 W | 120 W | measured paddling power is 2–3.5× this (drag-based stroke) |

---

## 9. Verified behaviour: all species (prototype, reference inputs)

Reference inputs used everywhere, and to be reproduced by `ScriptedPoseSource`:

- **Reference flap.** Both arms follow `δ(t) = 45°·cos(2π·1.4·t)`.
  `stroke_l = δ̇·(sin δ, cos δ, 0)` and `stroke_r = δ̇·(−sin δ, cos δ, 0)` in
  the torso frame (peak 6.9 /s), with dihedral = δ(t).
- **Frantic flap.** 60°, 2.2 Hz.
- **Twist 0.5 / 1.0.** `pitch_l = +x`, `pitch_r = −x`.
- **Balloon step.** `pitch_l = pitch_r = +0.5` from trimmed cruise.

**Longitudinal**

| species | trim V | glide at trim | sink | best L/D @ V | min sink | balloon rise (spans) @ t | V after | V_min/V_s during |
|---|---|---|---|---|---|---|---|---|
| wren | 7.65 | 5.1 | 1.48 | 5.9 @ 5.5 | 0.83 | 0.74 m (4.6) @ 1.1 s | 4.6 | 1.11 |
| sparrow | 8.93 | 5.6 | 1.58 | 6.8 @ 6.4 | 0.83 | 1.25 m (5.2) @ 1.4 s | 5.4 | 1.11 |
| swallow | 9.89 | 6.0 | 1.62 | 7.7 @ 7.1 | 0.76 | 1.76 m (5.3) @ 1.5 s | 6.0 | 1.12 |
| starling | 10.74 | 6.3 | 1.70 | 8.1 @ 7.7 | 0.79 | 2.17 m (5.4) @ 1.7 s | 6.5 | 1.12 |
| pigeon | 13.48 | 6.9 | 1.93 | 8.9 @ 9.7 | 0.90 | 3.76 m (5.7) @ 2.1 s | 8.1 | 1.12 |
| crow | 14.77 | 7.6 | 1.93 | 11.0 @ 9.6 | 0.75 | 4.87 m (5.1) @ 2.4 s | 8.9 | 1.14 |
| gull | 16.34 | 8.2 | 1.99 | 12.6 @ 9.8 | 0.70 | 6.23 m (4.8) @ 2.8 s | 9.8 | 1.15 |
| hawk | 17.40 | 8.5 | 2.02 | 13.9 @ 10.4 | 0.66 | 7.26 m (4.5) @ 3.1 s | 10.4 | 1.15 |
| eagle | 20.65 | 9.1 | 2.25 | 13.6 @ 12.4 | 0.84 | 10.81 m (5.1) @ 3.6 s | 12.4 | 1.14 |

After the balloon peak, speed undershoots its new trim by 21–25% and never
falls below 1.11·V_s. It settles within 10% in about 0.7 phugoid periods
(sparrow 2.6 s, pigeon 4.1 s, eagle 6.8 s).

**Lateral** (bank, time to 90%, sustained `g tanφ/V`, peak β)

| species | twist 0.5: bank, t90, ω°/s | twist 1.0: bank, t90, ω°/s | SizeRules turn_rate °/s | full-input sink m/s | β_pk° |
|---|---|---|---|---|---|
| wren | 30.2, 0.35, 43 | 71.7, 0.34, 206 | 279 | 5.6 | 1.1 |
| sparrow | 29.7, 0.34, 36 | 71.8, 0.34, 186 | 220 | 5.4 | 1.1 |
| swallow | 29.3, 0.38, 32 | 71.5, 0.40, 172 | 188 | 4.4 | 0.9 |
| starling | 29.0, 0.42, 29 | 71.8, 0.45, 157 | 165 | 4.2 | 0.8 |
| pigeon | 28.2, 0.54, 23 | 70.2, 0.57, 116 | 116 | 5.1 | 0.3 |
| crow | 27.8, 0.59, 20 | 69.5, 0.62, 105 | 101 | 4.3 | 0.2 |
| gull | 27.4, 0.64, 18 | 68.2, 0.66, 91 | 86 | 3.8 | 0.1 |
| hawk | 27.2, 0.67, 17 | 67.5, 0.70, 84 | 78 | 3.4 | 0.1 |
| eagle | 26.5, 0.75, 14 | 65.5, 0.77, 65 | 60 | 3.8 | 0.06 |

Sustained max-input turn rate is 100–109% of `SizeRules.turn_rate` from pigeon
up, and 74–95% for wren to starling, where energy runs out at 3.6 g. The moth
reaches 50%; it is NPC-only. Full-input
turns are descending spirals that cost 3.4–5.6 m/s of sink, which is why
players flap in tight turns, exactly as birds do.

**Asymmetry kicks** (from trimmed cruise, reflex active; 1.5 s window after the stroke)

| species | one-wing (left) reference flap | right wing extension 0.6 | right wing extension 0.3 |
|---|---|---|---|
| sparrow | +73° peak, reflex overshoot to −47°, then level; net heading **+8° (left)** — see the open item below | peak +33°, integrator trims back to +2° | rolls to the stop (+73°): tuck-roll |
| pigeon | +38° peak, heading −8.7° (turns right: canoe-paddle logic) | +23° → +6° | +76° → +75° |
| eagle | +24° peak, heading −9.3° | +16° → +7° | +32° → +13° |

**Open tuning item.** For the smallest birds the reflex over-corrects the
one-wing-flap roll, so the net heading change is small and can go either way.
Lowering `k_asym` does not fix it (sparrow +57°/−37° at 1.05), and it also
removes the tuck-roll. Try a temporarily raised `K_pd` while one wing strokes.
Pigeon and larger behave as intended.

**Flapping, dive, thermal**

| species | hover (ref flap) vy | flat-wrist flap: climb @ V | wrists −0.5: climb @ V | best climb | frantic vs ref (hover) | tucked dive V | thermal 3 m/s, slow circle |
|---|---|---|---|---|---|---|---|
| wren | +1.72 | 1.77 @ 2.1 | 2.41 @ 3.4 | 2.41 | — | 20.0 | +1.84 |
| sparrow | **+1.15** | 1.22 @ 2.2 (hover-climb) | 2.62 @ 7.5 | 2.62 | +1.05 vs +1.19 | 23.3 | +1.80 |
| swallow | +0.59 | 0.83 @ 2.6 | 2.17 @ 9.3 | 2.17 | — | 25.8 | +1.81 |
| starling | **+0.04** | 0.59 @ 3.1 | 1.78 @ 11.1 | 1.78 | — | 28.0 | +1.76 |
| pigeon | **−1.66** | 2.32 @ 8.4 | 1.07 @ 14.9 | 2.32 | −0.40 vs −1.60 | 35.1 | +1.61 |
| crow | −2.37 | 2.60 @ 9.9 | 0.65 @ 16.5 | 2.60 | — | 38.3 | +1.67 |
| gull | −3.20 | 2.52 @ 11.2 | 0.69 @ 18.4 | 2.52 | — | 42.4 | +1.65 |
| hawk | −3.72 | 2.43 @ 12.0 | 0.62 @ 19.7 | 2.43 | — | 45.1 | +1.65 |
| eagle | **−5.28** | 1.91 @ 14.5 | 0.41 @ 23.4 | 1.91 | −3.44 vs −5.14 | 53.6 | +1.46 |

Reading the flapping table:

- **Flat wrists mean "up".** Hover-capable birds helicopter up slowly. The
  others climb at about 0.65 V_c, which is the minimum-power speed.
- **Forward-pitched wrists mean "up and forward".** Big birds fly faster than
  cruise and climb gently.
- **Flap direction (hover).** Flat: 0.0–0.6° from vertical. Pitch −0.5:
  13.6–14.5° forward. Pitch −1: 34–35° forward. Upstroke force is at most
  3% of the downstroke.
- **Stall.** Full wrist-up from cruise zooms and flares to near-zero speed;
  the stall flag sets within 1.0–2.5 s, then the bird drops. Releasing to
  neutral recovers (V > 1.1 V_s, path > −30°) in 0.2–2.3 s, losing 5–19 m
  (9–21 spans).
- **Pull-out.** From a tucked V_max dive with wrists at +0.5, the height lost
  is 9.9 m (sparrow), 22.8 m (pigeon) and 48.8 m (eagle), at a peak of
  5.9–6.9 g.

---

## 10. WingInput: poses → WingState

All geometry is in **real-world tracking metres**, relative to the XROrigin
and divided by `world_scale`. A test must show that the output is unchanged
when `world_scale` changes. Everything is normalised by the calibrated body,
so an adult and a child produce the same WingState from the same gesture.

### 10.1 WingState (the contract)

```gdscript
class_name WingState extends RefCounted
## Scale-free wing command. Produced by WingInput (player), FlightAutopilot / from_commands (NPC, bot).
var ext_l := 1.0          ## 0 tucked … 1 fully spread (per wing)
var ext_r := 1.0
var pitch_l := 0.0        ## wrist chord pitch, −1 … 1 (+ = leading edge up), after calibration + deadzone
var pitch_r := 0.0
var dihedral_l := 0.0     ## rad, arm elevation above shoulder level with the held tilt removed (§10.3)
var dihedral_r := 0.0
var tilt := 0.0           ## −1 … 1 arm-line bank gesture (+ = left hand higher = roll right)
var sweep := 0.0          ## −1 … 1 mean hands forward (+) / back of shoulders; small pitch-trim input
var stroke_l := Vector3.ZERO   ## hand velocity rel. shoulder, torso frame (x right, y up, z back), ÷ arm length (1/s)
var stroke_r := Vector3.ZERO
var torso_yaw := 0.0      ## rad, heading of the arm frame in tracking space (Godot yaw convention)
var torso_dyaw := 0.0     ## rad, change since previous WingState (what FlightModel applies)
var grip_l := false       ## cling/perch
var grip_r := false
var confidence := 1.0     ## 0..1 tracking quality (lost hands decay toward glide)
var t := 0.0              ## seconds (source time), for interpolation/replay

static func glide() -> WingState                           ## neutral, spread, no stroke
static func from_commands(bank: float, pitch: float, flap_power: float, tuck: float,
		phase: float, flap_hz := 1.4, one_wing := 0) -> WingState   ## NPC / bot / desktop
func sym_pitch() -> float: return 0.5 * (pitch_l + pitch_r)
func diff_pitch() -> float: return 0.5 * (pitch_l - pitch_r)
func duplicate_state() -> WingState
func to_dict() -> Dictionary / static from_dict(d) -> WingState   ## replay & logging
```

`from_commands` synthesises exactly the §9 reference flap, with amplitude
45°·√flap_power and frequency `flap_hz`:

- `ail = bank` → `pitch_l = +bank`, `pitch_r = −bank`, clipped against the
  pitch channel.
- `pitch` → symmetric pitch.
- `tuck` → `ext = 1 − tuck`.
- `one_wing` = −1 / 0 / +1 selects the stroking side.

### 10.2 Calibration (WingCalibration, owned by flight, filled by the VR flow)

The existing fields are `arm_span`, `shoulder_width`, `shoulder_drop`,
`neutral_roll_l/r`, `neutral_pitch_l/r`, `seated` and `calibrated`.
**Proposed additions** (contract note, §15):

- `chord_axis_left/right: Vector3`, the controller-local unit vector that
  points along the wing chord (leading edge). It is captured in a T-pose with
  palms down and wrists flat: `k = B_ctrlᵀ·f̂_torso` projected ⊥ arm and
  normalised.
  - The default before calibration is grip-local `(0, 1, 0)`. Under the OpenXR
    grip convention, −Z is the straightened index finger (outward along the arm
    in a T-pose) and +X is the palm normal, which makes +Y the thumb/forward
    side for both hands.
  - This must be **verified in the Meta XR Simulator and on Quest**
    (tests/sim).
  - Capturing the axis makes WingInput independent of grip and aim pose
    offsets.
- `stroke_gain := 1.0` (a player-strength or accessibility multiplier;
  seated defaults to 1.25).

The reach `R = (arm_span − shoulder_width)/2` has a default of 0.61 m.
Auto-calibration takes a running maximum of hand-to-hand distance (with a slow
0.2%/s decay) as `arm_span`, and the median wrist pitch over the first 10 s of
steady spread-arm gliding as `neutral_roll`.

### 10.3 Per-tick computation

```
1  H = head, L/R = hand poses (real metres). up = +Y.
2  Torso yaw: h = (R.pos − L.pos) with y = 0; wh = smoothstep(0.35, 0.55, |h|/arm_span)
   ψ_raw = heading of (up × ĥ); ψ_t = unwrap(ψ_t + wh·angle_diff(ψ_raw, ψ_t))   (hold when hands close)
   One-Euro filter (min cutoff 1.0 Hz, β 0.5); while flapping, changes < 2° are ignored (deadband).
   torso_dyaw = ψ_t − ψ_t,prev.   f̂ = forward(ψ_t), r̂ = right(ψ_t)
3  Shoulders: N = H.pos − up·shoulder_drop − f̂·0.08 ;  S_l/r = N ∓ r̂·shoulder_width/2
4  Arm a = P − S, d = |a|, â = a/d.
   ext = clamp((d − 0.40R)/(0.45R), 0, 1) · smoothstep(80°, 50°, sweep_angle)   (hands straight forward = folded)
   (seated: d_open = 0.75R). Critically damped smoothing, 12 Hz.
5  Dihedral: δ = asin(â·up), clamp ±60°.
6  Tilt: τ_tilt = atan2(L.y − R.y, |h|); tilt = soft_deadzone(τ_tilt, 3°)/40° (seated 30°), clamp ±1.
   Sample-and-hold while either stroke > 1.5 /s; release blends back over 0.25 s.
   dihedral_l = δ_l − τ_tilt_held, dihedral_r = δ_r + τ_tilt_held   (tilt is a bank command, not a lift tilt)
7  Wrist pitch: ĉ = B_ctrl·chord_axis; ĉ⊥ = normalize(ĉ − (ĉ·â)â)
   r0 = normalize(f̂ − (f̂·â)â); n0 = normalize(r0 × â)·s, sign chosen so n0·up > 0
   τ = atan2(ĉ⊥·n0, ĉ⊥·r0) − neutral_roll       (if |f̂ − (f̂·â)â| < 0.3: τ = asin(ĉ·up), the arm-forward fallback)
   pitch = clamp(soft_deadzone(τ, 3°)/35°, −1, 1)  (seated 28°). One-Euro (2 Hz, β 0.2). α_c slew does the rest.
8  Stroke: v_hand from tracker linear velocity if valid, else a 2-tap finite difference of positions
   through a 2nd-order low-pass at 10 Hz (latency ≤ 20 ms).
   v_rel = v_hand − v_head − ω_t × (P − H)      (subtract head translation and whole-body turning)
   stroke = yaw(−ψ_t)·v_rel / max(d, 0.25R) · stroke_gain ; clamp |stroke| ≤ 20.
9  Sweep: mean forward angle of the arms in the torso plane / 40°, clamp ±1.
10 Tracking loss per hand > 0.1 s: stroke → 0, ext → 1, pitch → 0 over 0.5 s; confidence → 0.
   Both hands lost > 1 s: FlightAutopilot "wings level, hold speed" blends in.
```

Sweep is a small pitch-trim input: `α_raw += 0.25·curve(sweep)·(α_hi − α_trim)`.
Forward sweep moves the AC forward, which is nose-up, as in birds.

### 10.4 Flap events (for audio and haptics)

Per wing, a downstroke opens when `−stroke·up > 1.5 /s` and closes on sign
change or when it drops below 0.5 /s. At close, the event emits
`strength = clamp(peak P_w / (0.5·P_max), 0, 1)`. If both wings close within
0.12 s, `side = 0`. PlayerBird forwards the event to
`Events.player_flapped(side, strength)`.

---

## 11. Pose sources and the bot pilot

```gdscript
class_name PoseSource extends RefCounted
func sample(dt: float) -> PoseFrame        ## tracking-space, real metres
func is_active() -> bool
class_name PoseFrame extends RefCounted
var t: float; var head: Transform3D; var left: Transform3D; var right: Transform3D
var left_ok: bool; var right_ok: bool; var left_vel: Vector3; var right_vel: Vector3   ## vel = NAN-free, ZERO if unknown
var grip_l: bool; var grip_r: bool; var menu: bool
```

| Source | Use | Notes |
|---|---|---|
| `XRPoseSource` | headset / simulator | reads `XRServer` trackers `head`, `left_hand`, `right_hand` (pose `grip`), divides by world_scale, takes velocities from `XRPose.linear_velocity` |
| `ScriptedPoseSource` | unit + sim tests | timeline of segments on channels (`ext`, `pitch_sym`, `pitch_diff`, `tilt`, `flap_amp`, `flap_hz`, `flap_pitch`, `one_wing`, `torso_yaw`, `head_yaw`), hold or ramp; a shared `PoseSynth` turns channels into T-pose-based hand transforms |
| `ReplayPoseSource` | regression from real Quest sessions | JSON-lines of PoseFrames; the recorder lives in PlayerBird (`--record_poses=path`) |
| `DesktopPoseSource` | dev without headset | keys → `PoseSynth` channels (below) |

`PoseSynth` is also what `WingState.from_commands` mirrors analytically.
Because of that, a scripted pose passed through WingInput and the equivalent
`from_commands` WingState must agree. That is a test (§13, T-IN-5), and it
proves the input chain is lossless.

Desktop keys: W/S pitch wrists ±; A/D twist wrists opposite (bank);
Q/E tilt arms; Space flaps (reference 45°/1.4 Hz), Shift+Space is a hard flap
(60°/2 Hz); LMB/RMB flap one wing; Ctrl tucks (hands to chest); mouse X turns
the torso (bird yaw) and mouse Y is look pitch (head only); G grips.

**FlightAutopilot** (RefCounted; used by the bot pilot in tests and optionally
by NPCs):

```
bank  = clamp(K_ψ·wrap(ψ_tgt − ψ) + K_r·(ω_tgt − ω), ±0.8)                K_ψ = 1.2, K_r = 0.3 (normalised units)
pitch = clamp(K_V·(V − V_tgt)/V_c, ±0.8)                                   faster than target → wrists up
flap  = clamp(K_h·(h_tgt − h)/10 + K_z·(vz_tgt − vz)/3, 0, 1) ;  flap_pitch = V < V_tgt ? −0.5 : 0
tuck  = dive_requested ? 1 : 0
→ WingState.from_commands(bank, pitch, flap, tuck, phase += 2π·1.4·dt)
```

The bot flies test courses: a gate slalom, figure-8s, thermal centring
(it circles at the bank that maximises measured climb) and
perch approach-and-flare. Its trajectories are the plotted evidence (§13.3).

---

## 12. Public APIs

### 12.1 FlightModel (pure `RefCounted`, no scene dependencies)

```gdscript
class_name FlightModel extends RefCounted
enum Mode { FLYING, PERCHED, STUNNED, GROUNDED }
# --- configuration
func _init(mass: float = 0.03, overrides: Dictionary = {}) -> void
func set_mass(mass: float) -> void                 ## re-derive §4 params; keeps state (growth)
func get_params() -> Dictionary                    ## all §4 derived values (read-only copy)
static func envelope(mass: float) -> Dictionary    ## {cruise, stall, max_speed, phi_max, p_max, climb_best, hover_capable, glide_ratio}
var k_rud := 1.0                                   ## auto-rudder (tests set 0)
var npc_weathercock := false
var per_wing_wind := false
var lite := false                                  ## NPC LOD: 1 substep, no glide-only pass, no stroke-plane blend
# --- state (read; write via the methods below)
var position: Vector3; var velocity: Vector3; var attitude: Quaternion
var mode := Mode.FLYING
# --- lifecycle
func reset(xform: Transform3D, vel := Vector3.ZERO) -> void    ## basis yaw → heading; pitch/bank 0
func trim(xform: Transform3D, speed_ratio := 1.0) -> void      ## trimmed glide at ratio·V_c, α = α_trim
func step(dt: float, ws: WingState, wind: Callable = Callable()) -> void   ## wind(pos: Vector3) -> Vector3
# --- kinematic inputs / contact
func apply_body_yaw(delta: float) -> void          ## torso steering (also done inside step from ws.torso_dyaw)
func translate(offset: Vector3) -> void            ## head leaning etc. (PlayerBird sweeps it first)
func apply_contact(normal: Vector3, restitution := 0.1, friction := 0.2) -> float   ## returns impact normal speed
func stun(seconds: float) -> void                  ## tucked, ballistic, controls ignored, then recovers
func perch(pos: Vector3, facing: Vector3) -> void  ## Mode.PERCHED, v = 0, attitude level facing
func launch(ws: WingState) -> void                 ## leg hop: v = facing·0.6 V_s + up·0.5 V_s, Mode.FLYING
# --- outputs
func forward() -> Vector3; func up() -> Vector3
func heading() -> float; func pitch() -> float; func bank() -> float    ## ψ, θ, φ (rad)
## heading() is flip-free: yaw of h = f_h − f.y·u_h (horizontal parts of forward f and up u).
## It equals the Euler yaw in normal flight and stays defined through a vertical dive.
func tumbling() -> bool                            ## attitude outside the envelope (rig must not follow)
func aoa() -> float; func sideslip() -> float; func airspeed() -> float
func telemetry() -> Dictionary                     ## §12.3 keys (minus world-dependent ones)
func drain_flap_events() -> Array[Dictionary]      ## [{side, strength, t}]
var stalled: bool                                  ## any wing separated
var power: float                                   ## W, muscle power this step
```

### 12.2 PlayerBird (`extends Bird`, scenes/player/player.tscn)

```gdscript
class_name PlayerBird extends Bird
@export var pose_source_kind := &"auto"            ## auto | xr | desktop | scripted | replay
var flight: FlightModel
var wing_input: WingInput
var pose_source: PoseSource
var calibration: WingCalibration
func is_player() -> bool                           ## true
func get_body_position() -> Vector3                ## XRCamera3D.global_position (== flight.position)
func get_forward() -> Vector3                      ## flight.forward() — the bird's forward, not the rig's
func telemetry() -> Dictionary
func respawn(xform: Transform3D) -> void           ## perched at xform (origin = head position), filters reset
func set_controls_enabled(on: bool) -> void        ## off → WingState.glide() (menus, caught, onboarding freeze)
func set_pose_source(src: PoseSource) -> void
func get_wing_state() -> WingState                 ## last input (visual wings, HUD, tests)
func _on_mass_changed() -> void                    ## flight.set_mass(mass); VR sets world_scale from wingspan
```

Per physics tick (PlayerBird is pausable; the XROrigin subtree is
`PROCESS_MODE_ALWAYS` as the contract requires):

```
frame = pose_source.sample(dt); ws = wing_input.update(frame, dt, calibration)
if not controls_enabled: ws = WingState.glide() with torso_dyaw kept      (never fight the player's real turn)
x0 = flight.position
flight.step(dt, ws, world.get_wind)
sweep sphere(r = body_radius) x0 → flight.position (layers world|perch); on hit:
    n = normal; vn = −v·n; flight.apply_contact(n)       (slide: remove normal part, 20 % friction)
    stun if vn > 0.6·V_c and vn/|v| > 0.7 (head-on): flight.stun(0.8 s); Events.player_collided(vn, n)
head_delta = R(ψ_rig)·(head_track − head_track_prev)·world_scale → swept, flight.translate(...)
ψ_target = flight.heading() − ψ_torso           (invariant: rig yaw + torso yaw = bird heading)
if flight.tumbling(): ψ_target = ψ_rig           (|φ| > φ_max+20° or |θ| > 75°: hold the view; physics recovers ≤ 2.6 s)
ψ_rig = comfort_limit(ψ_rig → ψ_target)          (max rate, max accel from Settings; physics never sees the lag)
rotation = (0, ψ_rig, 0)                         (the node never pitches or rolls; Quest rule 2)
global_position = flight.position − R(ψ_rig)·(head_track·world_scale)     (camera lands exactly on the bird; yaw pivots at the head)
velocity = flight.velocity ; perch detection ; events
```

**Comfort limiter.** The prototype measured the rig yaw the physics asks for
under twist-only input:

| input | sparrow | pigeon | eagle |
|---|---|---|---|
| twist 0.5 | 42°/s, 114°/s² | 26°/s, 46°/s² | 15°/s, 20°/s² |
| twist 1.0 | 341°/s, 1100°/s² | 162°/s, 258°/s² | 86°/s, 91°/s² |

The full-input sparrow figure is a steep spiral, where Euler heading moves
fast. Proposed defaults are yaw rate ≤ 240°/s and yaw acceleration ≤ 720°/s².
The residual heading error, meaning the player's arms point a few degrees off
the flight path during violent manoeuvres, decays within 0.3 s and never feeds
back into physics.

The VR panel may prefer a physics-consistent cap: a Settings
`turn_comfort` < 1 lowers the player's `φ_max` so that
`g tanφ/V_c ≤ turn_comfort·ω_turn`, meaning the player simply turns wider.

**Perching.** A free perch that fits (`Perch.fits(span)`) is taken when:

- it is within `body_radius + 0.15·span`,
- airspeed is below `1.4·V_s`,
- the approach is not from below the perch at more than 45°,
- and, if the Settings key `flight/perch_needs_grip` is on, either grip is held.

The bird snaps over 0.25 s, calls `flight.perch()`, and emits
`Events.player_perched`. Launch happens on any downstroke with strength > 0.3,
or when wrists pitch down past −0.5 with the arms spread. That calls
`flight.launch()` and emits `Events.player_took_off`. Touching the ground
below 0.8·V_s gives `GROUNDED`, which behaves like a perch.

### 12.3 Telemetry (`PlayerBird.telemetry()`)

Contract keys:

| key | definition |
|---|---|
| `airspeed` | `\|v − W\|` |
| `groundspeed` | `\|v.xz\|` |
| `vertical_speed` | `v.y` |
| `altitude_agl` | `x.y − world.ground_height(x.x, x.z)` |
| `aoa` | `α_b + i_mean` (rad, mean wing AoA) |
| `bank` | `φ` |
| `stalled` | any wing separated |
| `flapping` | `clamp(P_lp/(0.5 P_max), 0, 1)`, with `P_lp` a 0.3 s low-pass of muscle power |
| `wing_extension` | mean ext |
| `tucked` | mean ext < 0.35 |
| `perched` | mode == PERCHED |
| `in_updraft` | `max(0, W.y)` |
| `g_load` | `(F_aero·up_B)/(mg)` |
| `lift` | `Σ q S CL` (N) |
| `drag` | `Σ q S CD + D_body + D_gov` (N) |

Extras:

| key | definition |
|---|---|
| `sideslip` | β |
| `pitch` | θ |
| `heading` | ψ |
| `turn_rate` | `ψ̇` (smoothed) |
| `power` | W |
| `power_frac` | `P/P_max` |
| `speed_ratio` | `V/V_c` |
| `stall_margin` | `α_s − max α_w` (rad; haptic buffet when < 2°) |
| `energy_height` | `y + V²/2g` |
| `mode` | FlightModel mode |
| `stroke_l`, `stroke_r` | per-wing normalised stroke |
| `k_power` | `k_P`: 1 = uncapped, < 1 = flapping harder than muscles allow |

---

## 13. Verification plan (headless unless noted)

### 13.1 Unit suite `tests/unit/flight/` (FlightModel pure; each is ≤ 5 s of CPU)

Each test runs at 1/240 s. The tolerance is against the §9 numbers plus the
physical invariant named.

| ID | Test | Pass condition |
|---|---|---|
| T-TRIM | 40 s neutral glide, all species | V within ±3% of V_c; glide within ±10% of analytic `L/D(CL_c)` |
| T-POLAR | τ_sym 0.2…0.7 steady glides | best L/D within ±10% of `½sqrt(πeAR/CD0)`; V at best within ±15% of `V_md`; min sink within ±20% of analytic |
| T-STALL-SPEED | slowest steady glide | within [1.0, 1.15]·V_s; `stalled` false at τ = 0.6, true at τ = 1.0 within 2.5 s |
| T-BALLOON | +0.5 step from trim | rise ≥ 3 wingspans and ≥ 35% of `(V1²−V2²)/2g`; peak at 0.8–4 s; V_min ≥ 1.05 V_s; settles within 10% by 1.2·T_ph; new V within ±10% of the τ = 0.5 polar speed |
| T-SAG | −0.5 step from trim | altitude drops monotonically for 1 s; V rises above 1.4 V_c |
| T-TURN | twist 0.5 / 1.0 | steady `\|ω − g tanφ/V\| ≤ 5%`; `\|β\|_ss ≤ 1°`; `\|β\|_pk ≤ 3°`; overshoot ≤ 15%; t90 within ±20% of §9 and increasing with mass; full-input ω ≥ 0.7·turn_rate (≥ 0.9 from pigeon up; moth excluded) |
| T-ADVERSE | `k_rud = 0` roll-in right | β_pk ≥ +0.5° (nose left, adverse); `k_rud = 1` → `\|β\| ≤ 0.1°` |
| T-ROLL-SCALE | max roll rate at V_c vs 1.5 V_c | ratio within 1.5 ± 0.15 (p ∝ V) |
| T-FLAPDIR | hover, reference flap, pitch 0 / −0.5 / −1 | downstroke force angle from vertical `\|·\| ≤ 3°`, 8–20°, 25–45°; upstroke/downstroke ≤ 0.15 |
| T-HOVER | reference flap from rest, 8 s | sparrow vy ≥ +0.5; starling `\|vy\| ≤ 0.5`; pigeon ≤ −1; eagle ≤ −3; hover-capable birds keep body `\|θ\| ≤ 5°` at pitch 0 (non-hoverers weathercock nose-down as they fall — correct) |
| T-CLIMB | reference flap from trim | best-of(flat, −0.5) climb within ±30% of `envelope().climb_best` (§15 values); flap at −0.5 holds V ≥ 0.75 V_c (sparrow and larger) |
| T-FRANTIC | 60°/2.2 Hz vs reference | hover climb ≥ 0.8× reference − 0.3 m/s; `k_P` < 1 (cap engaged); P never exceeds 1.02·P_max |
| T-DIVE | tuck + wrists −1 | max V within ±3% of V_max; `D_gov = 0` below 0.75 V_max |
| T-PULLOUT | from V_max dive, wrists +0.5 | height lost ≤ 60 wingspans; peak g ≤ n_max + 2 |
| T-STALL-REC | full-up 4 s, then neutral | recovered (V > 1.1 V_s, γ > −30°) ≤ 2.5 s; loss ≤ 25 spans |
| T-THERMAL | W = (0, 3, 0), slow circle | climb ≥ +1.2 m/s for sparrow…eagle with no stroke |
| T-WIND | uniform headwind 5 m/s | airspeed within ±3% of V_c; groundspeed = airspeed − 5 |
| T-TORSO | 30° torso yaw step | path heading reaches 63% in 0.4–2.5 s, monotone in mass; final β ≤ 1.5° |
| T-KICK | one-wing flap, one-wing ext 0.3 | roll away from the stroking wing and toward the tucked wing; `\|φ\| ≤ φ_max + 15°` throughout (pigeon and larger; sparrow is an open item, §9) |
| T-DT | 60/72/90/120 Hz, 12 s scripted mix | final positions within 0.5 m |
| T-ENERGY | aero off (vacuum) | total energy drift < 0.2% over 10 s (integrator check) |
| T-SOAK | 120 s random WingStates (8 seeds), 3 species | finite; `\|v\| ≤ 1.1 V_max`; after 10 s of flailing, recovers to `\|φ\| < 20°`, `\|θ\| < 45°`, V > 1.05 V_s within 3 s of neutral input; the rig heading rate never exceeds the comfort limit |
| T-GROW | set_mass sparrow→pigeon mid-glide | no NaN, no jump in v; new trim reached within 2 T_ph |
| T-IN-1..6 (WingInput) | scripted poses | world_scale invariance; extension / pitch / tilt / dihedral round-trips within ±2%; torso-yaw deadband; tracking-loss decay; **ScriptedPoseSource → WingInput equals `from_commands`** within 2%; flap events: one per downstroke at the reference flap (± 0) |

### 13.2 Scene-level tests (PlayerBird in a flat World, desktop-mode renderer off)

| ID | Pass condition |
|---|---|
| T-RIG-NOROLL | rig basis pitch and roll are exactly 0 every frame during a scripted aerobatic sequence |
| T-RIG-INVARIANT | `\|ψ_rig + ψ_torso − ψ_bird\| ≤ 3°` in normal flight, ≤ 15° under the comfort limiter, re-converging within 0.5 s |
| T-RIG-HEAD | camera global position equals `flight.position` within 1 mm after yaw, lean and world_scale changes |
| T-COLLIDE | at 2·V_max a 2 cm twig does not tunnel; a head-on wall stuns; a glancing wall slides |
| T-PERCH | the bot flares onto a branch perch below 1.4 V_s and perches; launch works |
| T-PAUSE | pausing freezes flight while the XR rig keeps processing |

### 13.3 Visual and plotted evidence (`artifacts/flight/`)

`tests/shots/flight_plots.gd` renders PNG plots with Godot `Image`, plus CSV
for every §13.1 scenario:

- altitude and V vs t (balloon and phugoid),
- bank and ω vs t with the `g tanφ/V` overlay,
- top-down turn circles for all species on one plot (radius grows with size),
- glide polars,
- hover vy vs mass,
- force-direction arrows for T-FLAPDIR,
- the bot's slalom and figure-8 ground tracks.

Each plot is reviewed by eye, per the ARCHITECTURE definition of done.

### 13.4 Simulator (`tests/sim/flight_sim.gd` via tools/xr.sh)

PlayerBird runs in the XR session with a `ScriptedPoseSource`, because the
simulator's controllers are fixed in place. The test checks:

- the XR camera never rolls or pitches relative to the head tracker,
- a turn yaws the XR view,
- world_scale growth mid-flight keeps the camera at `flight.position`,
- XRMirror screenshots at scripted moments: level flight, 45° bank, dive, perch.

A second run uses `XRPoseSource` to confirm the default `chord_axis` sign on
the fixed simulator controllers. Rotate them with the simulator's keyboard
bindings if available; otherwise flag the axis for the Quest session.

---

## 14. Performance budget and NPC LOD

- **Player.** 3–4 substeps × (2–8 wing evaluations) ≈ 0.2–0.6 ms per frame in
  GDScript on Quest-class CPUs. Measure it in T-SOAK (`metric("us_per_step")`)
  and keep it under 0.8 ms.
- **NPCs.** 60 full models would cost around 12–30 ms, which is not
  affordable. Recommendation to the AI area:
  - Use full `FlightModel` with `lite = true` for at most 4–6 NPCs within
    about 25 m of the player (fair close chases, identical physics):
    1 substep, symmetric wings evaluated once each, no glide-only pass.
  - All others fly a kinematic model clamped to
    `FlightModel.envelope(mass)` (cruise, stall, max_speed, `φ_max`,
    `p_max`, climb_best, glide_ratio, hover_capable).
  - The envelope numbers come from the same physics as §9, so switching LOD
    does not change what a bird can do.
- Allocation-free stepping: preallocate Vectors, no Dictionaries inside
  `step` (telemetry builds its Dictionary only when asked).

---

## 15. Contract-change requests (for the owners)

1. **gameloop (`SizeRules.performance`).**
   - `climb` targets (4.0 → 2.55 m/s) are not reachable by the physics without
     turning small birds into 4 m/s helicopters. Forward-flight flap force
     grows linearly with stroke speed and hover force quadratically, so any
     gain that meets the small-bird forward climb targets over-powers their
     hover. The emergent best climb at the reference flap is 2.62 (sparrow),
     2.17 (swallow), 1.78 (starling), 2.32 (pigeon), 2.60 (crow),
     2.52 (gull), 2.43 (hawk) and 1.91 (eagle) m/s.
   - Proposal: `climb = 2.4 * pow(k, -0.02)`, which gives 2.4 → 2.2 and fits
     the emergent values within ±25%. FlightModel publishes the measured
     `climb_best` through `envelope()`.
   - `turn_rate` is met (sustained, full input) within ±10% from pigeon up.
     Small birds reach 74–95% because 3.6 g at cruise is energy-limited. That
     is acceptable, or define turn_rate as instantaneous, in which case the
     peak is 104–183%.
2. **flight (`WingCalibration`, flight-owned).** Add `chord_axis_left`,
   `chord_axis_right` (Vector3) and `stroke_gain` (float).
3. **Settings keys** (`DEFAULTS`):
   - `flight/stroke_gain` 1.0
   - `flight/twist_full_deg` 35
   - `flight/tilt_full_deg` 40
   - `flight/invert_pitch` false
   - `flight/perch_needs_grip` false
   - `comfort/max_yaw_rate_deg` 240
   - `comfort/max_yaw_accel_deg` 720
   - `comfort/turn_comfort` 1.0
4. **`Bird.get_forward()` for the player** returns the bird's body forward,
   not the rig's, because the rig lags under the comfort limiter and the torso
   is part of the heading. This is within the contract but worth noting for AI
   and UI.

---

## 16. Rejected alternatives (tried in the prototype and failed; do not retry)

| Idea | What happened |
|---|---|
| Split model: glide airfoil + separate plate increment `n̂·½ρSC(\|u_t\|u_tn − \|u_g\|u_gn)` | Heave from the flap made the glide part see −30° α with stall drag. Flapping at cruise decelerated the bird to hover. Replaced by the unified per-wing model (§5). |
| Feed-forward including flap forces | The body pitched ±15° per wingbeat, tilting the flap force; efficiency collapsed. Replaced by L8. |
| Stroke plane in body axes | Climbing pitched the body up, which tilted the flap force back, which slowed the bird, which pitched it up more: positive feedback into hover. Replaced by L7. |
| Holding α only (no phugoid damper) | Balloon then 72–103% speed undershoot, falling to 0.5 V_s. |
| γ-hold with a long washout | Killed the balloon entirely (0 m rise). |
| Leveller-spring roll law (bank = aileron/spring) | Underbanked 8° at full input; inverted in a spiral. Replaced by reflex aileron + integral + stall margin. |
| Roll about the body x axis | α turned into β: 16° sideslip spikes at roll-in. Replaced by roll about the airflow axis. |
| Regime blend on forward airflow | Deep-stalled birds fell belly-first forever. Replaced by total airspeed. |
| Damper in α units | Cancelled pull-outs at speed (240 m height loss). Replaced by `(V_c/V)²` scaling. |
| Unclipped asymmetric moments | A single one-wing flap rolled the sparrow to 131° (inverted). Replaced by L9. |
| Constant stroke gain tuned to climb targets | Sparrow hover-climb of 4.4 m/s (helicopter). Hence §15.1. |
| Rig follows a "robust" body heading while tumbling | Flip-free heading still spun at up to 15 000°/s during flailing. Replaced by holding the rig while `tumbling()`. |
| Pitch stop alone to prevent inversions | Adversarial flailing still tumbles small birds. Tumbling is accepted (physical); recovery ≤ 2.6 s is tested instead. |

---

## 17. Tuning knobs (safe ranges) and risks

| Knob | Default | Range | Effect |
|---|---|---|---|
| `curve` expo | 0.6 / 0.4 | — | wrist sensitivity near neutral |
| `k_inc` | 0.3 | 0.2–0.5 | instant lift response to wrist pitch (snappier balloon onset) |
| `K_g`, clamp | 0.3, 4° | 0.2–0.4 | phugoid damping vs balloon height |
| `w_roll`, `ζ_roll` | 2.5 + 6·agi, 0.9 | ±25% | bank response time (comfort) |
| `δ_lim` via `p_tgt` | 60 + 300·agi^0.8 °/s | ±30% | roll-rate authority |
| `G(m)` | 1.25·k^−0.08 | ±20% | flap strength; `stroke_gain` scales it per player |
| `P_max(m)` | 300·m·k^−0.11 | ±30% | frantic-flap ceiling |
| `k_asym`, `k_yaw_kick` | 1.3, 0.4 | 1.1–1.6, 0.2–0.6 | one-wing kick size |
| `n_max` | 5 + 2·agi | 4–8 | pull-out radius |
| `CYβ` | −0.35 | −0.2 to −0.6 | torso-steer responsiveness |
| comfort limits | 240°/s, 720°/s² | VR panel | yaw comfort |

**Risks and mitigations**

- **Controller chord-axis convention.** Wrong sign means inverted pitch. It is
  calibrated in the T-pose and there is an `invert_pitch` setting;
  T-IN tests plus a Quest check cover it.
- **Arm fatigue.** Flapping at 1.4 Hz for minutes is tiring. The physics
  deliberately makes gliding, thermals (+1.5–1.8 m/s in a 3 m/s core) and
  dives the efficient way to travel. `stroke_gain` and seated mode give an
  accessibility margin.
- **Small-bird yaw intensity** (full-input sparrow at about 185°/s sustained).
  Handled by the comfort limiter or `turn_comfort` (VR panel decides) and the
  vignette.
- **GDScript cost.** Budgeted in §14. If it is exceeded, drop the player to 3
  substeps (`h = 1/216` at 72 Hz still passes T-DT) before cutting physics.
- **Thermal strength coupling with World.** Core updrafts must be ≥ 2.5 m/s
  (≥ 3 recommended), because trim sink is 1.5–2.3 m/s and min sink is
  0.7–0.9 m/s. World's `get_wind` must be smooth (C¹) across thermal edges,
  or the α short period will buzz.

---

## Appendix A: FlightModel substep pseudocode (GDScript-flavoured)

```gdscript
func _substep(h: float, ws: WingState, wind: Callable) -> void:
	var e := _euler()                       # ψ, θ, φ from attitude (YXZ; φ = atan2(−x.y, y.y))
	var W := wind.call(position) if wind.is_valid() else Vector3.ZERO
	var v_air := velocity - W
	var V := v_air.length()
	var qbar := 0.5 * RHO * V * V
	# ---- commands (§6.1, §6.3)
	var c := _curve(ws.sym_pitch() + 0.25 * _curve(ws.sweep))
	var a_raw := alpha_trim + (c * (alpha_hi - alpha_trim) if c >= 0.0 else c * (alpha_trim - alpha_lo))
	_alpha_c += clampf(a_raw - _alpha_c, -ALPHA_SLEW * h, ALPHA_SLEW * h)
	var ail := clampf(_curve(ws.diff_pitch()) + _curve(ws.tilt), -1.0, 1.0)
	var phi_lim := _bank_limit(qbar, V)
	var phi_cmd := clampf(phi_max * ail, -phi_lim, phi_lim)
	var wa := _smoothstep(0.5 * v_stall, v_stall, (v_air - _v_hp).length())
	var e_phi := phi_cmd - e.phi
	_phi_i = clampf(_phi_i + e_phi * K_I * wa * h, -delta_lim, delta_lim)
	var delta := clampf(K_phi * e_phi + _phi_i - K_pd * _p, -delta_lim, delta_lim) * wa
	var alpha_cmd := _alpha_with_turn_comp_and_limits(_alpha_c, e.phi, qbar, wa)
	var i_mean := K_INC * (alpha_cmd - alpha_trim)
	var i_stroke := THETA_POST_MAX * c + K_INC * (_alpha_c - alpha_trim)
	var q_bl := attitude.inverse() * (Quaternion(Vector3.UP, e.psi) * Quaternion(Vector3.FORWARD, e.phi))
	# ---- wing forces (§5) with lazy power cap
	var omega_b := _omega_b()               # from Ω_ff (prev substep), q_d, r_d, p
	var u_b := attitude.inverse() * (-v_air)
	var kP := 1.0
	_eval_wings(ws, u_b, omega_b, i_mean, i_stroke, delta, q_bl, kP)     # fills _F[2], _M[2], _P[2], _alpha[2]
	var i := 0
	while _P[0] + _P[1] > p_max and i < 3:
		kP *= pow(p_max / (_P[0] + _P[1]), 0.4); i += 1
		_eval_wings(ws, u_b, omega_b, i_mean, i_stroke, delta, q_bl, kP)
	_commit_stall_flags()
	var F_b := _F[0] + _F[1]
	var M_b := _M[0] + _M[1]
	var F_flap_b := Vector3.ZERO
	var N_glide := -M_b.y
	if ws.stroke_l.length() > DEADZONE or ws.stroke_r.length() > DEADZONE:
		var g := _eval_wings_glide_only(u_b, omega_b, i_mean, delta)      # returns [F, M]
		F_flap_b = F_b - g[0]; N_glide = -g[1].y
	# ---- body forces
	var beta := 0.0
	var F_side_b := Vector3.ZERO
	if V > 1e-4:
		var dir_b := u_b / V
		beta = asin(clampf(-u_b.x / V, -1.0, 1.0))
		F_b += dir_b * qbar * cda_body * (1.0 + 3.0 * beta * beta)
		F_side_b = Vector3(qbar * S * CY_BETA * beta, 0, 0)
		F_b += F_side_b
		if V > 0.75 * v_max:
			var x := (V - 0.75 * v_max) / (0.25 * v_max)
			F_b += dir_b * gov_D * x * x
	var a := (attitude * F_b) / mass + Vector3(0, -G, 0)
	var a_flap := (attitude * F_flap_b) / mass
	# ---- translate
	velocity += a * h
	position += velocity * h
	# ---- heave filter + flight-path feed-forward (§6.2)
	_af_lp += (a_flap - _af_lp) * minf(1.0, h / TAU_FLAP)
	_v_hp += ((a_flap - _af_lp) - _v_hp / TAU_FLAP) * h
	var a_ff := a - (attitude * F_side_b) / mass - a_flap + _af_lp
	var v_m := velocity - W - _v_hp
	var Vm := v_m.length()
	_omega_ff = (attitude.inverse() * (v_m.cross(a_ff) / (Vm * Vm))) * wa if Vm > 1e-3 else Vector3.ZERO
	# ---- pitch (§6.2)
	var u_m := attitude.inverse() * (-v_m)
	var alpha_b := atan2(u_m.y, u_m.z) if Vm > 1e-3 else 0.0
	var gamma := asin(clampf(v_m.y / Vm, -1.0, 1.0)) if Vm > 1e-3 else 0.0
	_gamma_w += (gamma - _gamma_w) * minf(1.0, h / T_w)
	var sc := minf(1.0, pow(v_cruise / maxf(Vm, 1e-3), 2.0))
	var alpha_tgt := alpha_cmd - i_mean - clampf(K_G * (gamma - _gamma_w), -DAMP_LIM, DAMP_LIM) * sc
	var w_eff := wa * w_sp + (1.0 - wa) * W_POST
	_q_d += (wa * w_sp * w_sp * clampf(alpha_tgt - alpha_b, -0.8, 0.8)
		+ (1.0 - wa) * W_POST * W_POST * (THETA_POST_MAX * c - e.theta)
		- 2.0 * Z_SP * w_eff * _q_d
		+ _pitch_stop(e.theta, _q_d + _omega_ff.x)) * h                 # L5: θ ∈ [−82°, 70°]
	# ---- roll (§6.3) and yaw (§6.4)
	_p = clampf(_p + _roll_moment(M_b, delta, qbar, V, ws, e.phi, ail) / Ix * h, -p_clamp, p_clamp)
	var N_flap := -M_b.y - N_glide
	_r_d = clampf(_r_d + ((N_flap + (1.0 - k_rud) * N_glide) / Iz - _r_d / TAU_R) * h, -r_kick, r_kick)
	var r_beta := beta / tau_beta * wa if npc_weathercock else 0.0
	# ---- attitude (§3): roll about the airflow axis
	var ab := alpha_b * wa
	var w := _omega_ff + Vector3(_q_d, -(_r_d + r_beta + _p * sin(ab)), -_p * cos(ab))
	var ang := w.length() * h
	if ang > 1e-12:
		attitude = (attitude * Quaternion(w / w.length(), ang)).normalized()
	_guard_finite()
```

`_eval_wings` follows §5.1–5.5 literally. Use local variables only; no
allocation.
