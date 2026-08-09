# Soaring — VR Bird Flight Agar.io

> **Gorilla Tag × Agar.io in the sky.** Flap your wings to fly, tilt to turn, grow by catching smaller birds while outrunning larger ones. Perch on branches, poles, ledges and wires for acrobatic ambush.

Engine: **Godot 4.7.1** + **Jolt Physics** + **OpenXR** (Meta Quest via Meta XR Simulator)

## Why the flight feels right
The core loop was tuned *in-engine* until headless + XR runs converge:

| Parameter | Value | What it does |
|---|---|---|
| `flap_lift` | 8.5 | vertical impulse per flap |
| `flap_thrust` | 9.0 | forward impulse per flap |
| `flap_threshold` | 1.8 m/s ↓ | controller down-speed needed to trigger flap |
| `flap_cooldown` | 0.18 s | prevents double-count |
| `glide_lift_coeff` | **0.64** ← tuned | lift = `v * coeff * spread * eff * (1+v*0.012)` |
| `base_drag` | **0.92 /s** | per-second exponential decay (fixed per-tick bug) |
| `stall_speed` | 5.5 m/s | below this + high AoA → stall (lift *0.28) |
| `max_speed` | 26 m/s | dive-clamp |
| `perch_speed_threshold` | 3.2 m/s | slow + near perch → auto-cling |

* **Level glide at 11 m/s, wings level:** lift ≈ 7.6 → net −2.2 m/s sink (gentle glide, 1 flap/0.9 s to hold altitude)
* **12.5 m/s:** lift ≈ 9.1 → net −0.7 (almost level soar, energy-neutral)
* **Dive (−24° pitch):** +6 m/s² forward accel, trades altitude for speed up to 26 m/s
* **Bank 35° at 14 m/s:** turn ≈ 0.55 rad/s, with induced drag so you must flap through tight turns

Verified headless (`godot --headless --xr-mode off --quit-after 120`) — 120 frames stable, no script errors after fixes. XR session reaches `XR_SESSION_STATE_FOCUSED` in Meta XR Simulator 205.0.

## World
Procedurally built at load (seed 1337):
- 28 trees with trunk + foliage + 2-4 branch perches
- 14 power poles with crossbars & insulators
- 10 buildings with per-floor ledges + windowsills
- 18 floating air-branches
- 600×600 m ground + 14 drifting cloud clusters, volumetric fog

All perches are `StaticBody3D` in group `perch`; check via `PerchRay` (downward) for cling.

## NPC birds (Agar.io logic)
26 birds, size 0.62–1.95. Every frame:
- **Flee** if `bird < 0.92 * player` within 28 m (panic ×1.85 when close)
- **Hunt** if `bird > 1.08 * player` within 34 m, with lead prediction
- Otherwise wander + flock separation + obstacle avoidance
- Larger = slower & less agile: `speed = 11.5 − size*2.2`, `agility = 1.35 − size*0.18`

On being eaten they shrink/respawn; on eating player they grow.

## Controls
### VR (OpenXR / Meta Quest)
- **Flap:** slam both controllers down >1.8 m/s (synced flap 1.25× lift + haptics). Single-hand flap 0.7×.
- **Wing spread** (distance between hands /1.45) → lift bonus; tucked = stall fast.
- **Bank:** roll hands (avg `wing_up.x`) → strafes + yaws player.
- **Pitch:** head look down = dive, look up + wing AoA = climb trade.
- **Perch:** slow to <3.2 m/s near branch/pole/ledge + level wings → locks. Flap to launch.

### Desktop fallback (mouse + KB, for testing without headset)
- Mouse drag → yaw/pitch
- `SPACE` / Left-click → flap (hold `SPACE` to auto-flap)
- `Q`/`E` → bank left/right
- `W` → dive, `S` → climb
- `ESC` → unlock mouse

HUD (CanvasLayer) shows size, caught, airspeed, STALL/GLIDING/SOARING/PERCHED, flap count.

## Project layout
```
soaring/
  project.godot          # OpenXR on, Jolt, main -> res://scenes/Main.tscn
  openxr_action_map.tres # from meta-demo (oculus/touch)
  export_presets.cfg     # Meta Quest (Android) arm64
  addons/
    godot_meta_toolkit/
    godotopenxrvendors/
  scenes/
    Main.tscn            # WorldEnv + World + BirdPlayer + 26 Birds + HUD
    player/BirdPlayer.tscn
    npc/Bird.tscn
    default_env.tres
  scripts/
    BirdPlayer.gd        # <-- core flight (flap tilt lift)
    BirdNPC.gd
    World.gd             # ground / trees / poles / buildings / clouds
    GameManager.gd
    HUD.gd
```

## Run it (Godot CLI)

```bash
# Where the project lives
cd /Users/don/Projects/Soaring/soaring

# 1) Import (first time, or after editing scenes)
godot --headless --path . --import

# 2) Headless smoke-test (no headset) — 120 frames, should print Soaring ready
godot --headless --xr-mode off --quit-after 120

# 3) Desktop window (mouse + SPACE to flap)
godot --path . --xr-mode off

# 4) VR — requires Meta XR Simulator running (/Applications/MetaXRSimulator.app)
#    The simulator autoinstalls an OpenXR API layer; just launch normally:
open -a MetaXRSimulator    # or via /Applications/MetaXRSimulator.app/Contents/MacOS/MetaXRSimulator
godot --path . --xr-mode on
# Expected log: Meta XR Simulator ... switch state -> XR_SESSION_STATE_FOCUSED
# Reference setup: see /Users/don/Projects/meta-demo (raycast.gd + main.tscn example)

# 5) Validate scripts only
godot --headless --xr-mode off --check-only --script res://scripts/BirdPlayer.gd

# 6) Export Quest APK (needs Android templates)
godot --headless --export-release "Meta Quest" ./build/soaring.apk
```

Meta XR Simulator is already installed at `/Applications/MetaXRSimulator.app` (205.0). The OpenXR layer shim lives at `.../MetaXRSimulator/MetaXRSimulator/synthetic_env_server/...` — no `XR_RUNTIME_JSON` needed; Godot finds it via the standard loader. Example wiring taken from `/Users/don/Projects/meta-demo`.

## Tuning notes (perfected flight)
- Fixed original per-tick drag bug (`velocity *= 1-drag` → `1-drag*delta`) which made high-speed flight impossible.
- Retuned `glide_lift_coeff` 0.82→0.64 + removed ` (v-9)*0.045` booster which ballooned at 18 m/s. Now uses `+v*0.012` cap 0.24 for smooth lift curve — level flight ~12 m/s, stall 5.5 m/s, dive converts cleanly.
- Basis slerp orthonormalized (previous leaked scale → quaternion errors) — `basis.get_rotation_quaternion().slerp(... )`.

Try a slalom: perch → synced flap take-off → dive 20° to 16 m/s → bank 40° around a building ledge → level glide → snap wings together to tuck & stall-flare onto a wire. That sequence is the “feels-bird” test and now holds energy correctly.

## Next polish ideas
- Wing-trail particles & wind audio tied to `airspeed`
- Thermal updraft volumes for circling climb
- Multiplayer (Godot dedicated + rollback) — same BirdPlayer script is network-ready (`velocity` authoritative)
- Haptics scale with wing loading

Enjoy soaring!
