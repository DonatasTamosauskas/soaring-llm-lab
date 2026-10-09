# Soaring — architecture contract

VR bird flight in Godot 4.7 (OpenXR, Meta Quest target; tested through the
Meta XR Simulator on macOS with the Vulkan driver). This file is the contract
between the areas that are built in parallel. Read it before writing code.

## Conventions

- Godot: forward is -Z, right is +X, up is +Y. Metres, seconds, radians.
- Physics runs at 90 Hz (`common/physics_ticks_per_second=90`). Jolt.
- Collision layers: 1 `world` (terrain, buildings, trees, poles, wires — anything
  a bird can hit), 2 `player`, 4 `npc_bird`, 8 `perch` (optional extra layer
  for things birds land on; perches must ALSO be on layer 1 so they collide).
- Rendering: Forward+ on desktop, Mobile on Android. Low-poly art: flat
  shading, vertex colours or one shared `StandardMaterial3D` per system,
  no textures. Keep total draw calls low: batch geometry into few meshes.
- Run flags shared by every scene (see `scripts/core/DevScene.gd`):
  `--xr-mode off`, `--capture=/path.png`, `--capture_delay=N`, `--quit_after=N`,
  `--spawn=x,y,z`, `--look=x,y,z`, `--flightlog`. Everything after `--` on the
  command line is a user arg (`Args.value("key")`, `Args.flag("key")`).
- Headless tests: `tests/run.sh [suite]`. Any `tests/test_<name>.gd` with
  `func run(t: TestCase)` is auto-discovered. Assertions: `t.ok`, `t.near`,
  `t.lt`, `t.gt`, `t.finite3`. Exit 0 = ALL PASS.
- After adding a script with `class_name`, run `godot --headless --path . --import`
  once so command-line runs see the class (the editor cache is not updated
  by CLI runs otherwise).
- Screenshots: `godot --path . --xr-mode off -- --capture=/tmp/x.png --capture_delay=3 --quit_after=5`
  and then look at the PNG. Do not use the XR simulator from area agents;
  it is reserved for the integration pass (one session at a time).

## Who owns what

| Directory | Owner | Do not edit if you are not the owner |
| --- | --- | --- |
| `scripts/core/`, `scripts/flight/`, `scripts/player/`, `scenes/Main.tscn`, `scenes/Player.tscn` | core (main agent + integration) | yes |
| `scripts/world/`, `scenes/dev/World.tscn` | world | |
| `scripts/art/`, `scenes/dev/Aviary.tscn` | bird art | |
| `scripts/ai/`, `scenes/dev/Ecosystem.tscn` | enemy AI | |
| `scripts/game/`, `scenes/dev/GameLoop.tscn` | game loop | |
| `scripts/ui/`, `scenes/dev/Menus.tscn` | UI | |
| `scripts/audio/`, `scenes/dev/Audio.tscn` | audio | |
| `tests/test_<area>.gd` | each area | |
| `docs/<AREA>.md` | each area | |

Each area builds a dev scene (`scenes/dev/<Area>.tscn`, root script extends
`DevScene`) that shows its work in isolation, and a headless suite. An area is
done when its suite passes, its dev scene renders without errors, and a
screenshot of it looks right. The integration pass wires every area into
`scenes/Main.tscn` via `scripts/core/Main.gd`.

## Core API (exists now; read the code, it is short)

`FlightModel` (RefCounted, `scripts/flight/FlightModel.gd`) — lift/drag bird.
- `FlightModel.new(size)`; `size` scales mass ~size^2.4, wing area ~size^2.
- `position`, `velocity`, `heading` (unit), `bank`, `alpha`, `spread`, `stalled`, `airspeed`, `wind`.
- `step(cmd: FlightCommand, dt) -> Vector3` net force; `launch(pos, dir, speed=-1)`.
- `trim_speed()`, `stall_speed()`, `wing_loading()`, `body_basis() -> Basis`
  (-Z forward, use it to orient a bird mesh), `ideal_turn_rate()`.
- Envelope (size 1.0 hawk): stall 9.6 m/s, trim 12.9 m/s, glide ratio ~9,
  tucked terminal ~80 m/s. Size 3.5: trim 16.6 m/s. Size 0.5: trim 11.3 m/s.

`FlightCommand` — `alpha` (rad, trim ≈ 0.105), `bank` (rad, + = right),
`spread` 0..1, `flap` 0..1 (downstroke only), `flap_asym` -1..1, `grip`.
NPCs fly by producing a FlightCommand per tick and stepping their own
FlightModel — the same physics as the player. Use `FlightModel.ALPHA_STALL`.

`WingInput` — controllers → FlightCommand (see docs/FLIGHT.md).

`BirdPlayer` (CharacterBody3D, `scenes/Player.tscn`) —
- `model: FlightModel`, `size` (setter rescales model + mesh), `command`,
  `xr_active`, `perched`, `frozen` (pause), `camera: XRCamera3D`,
  `origin: XROrigin3D`, `left/right: XRController3D`, `body_visual: Node3D`
  (put the player's bird mesh under `$Body`; it is oriented by `body_basis()`).
- `spawn(pos, dir, speed=-1)`, `launch()`, `eye_position()`,
  `haptic(hand 0|1, strength, duration)`,
  `command_source: Callable(dt) -> FlightCommand` (autopilots/tutorials).
- signals: `perched_changed(bool)`, `collided(speed, normal)`, `launched()`,
  `wingbeat(strength)`.
- Collision: layer 2, mask 1|8. Perches at ≤ 6 m/s (11 with grip).

`DevScene`, `Args`, `Capture`, `XRBoot` — `scripts/core/`.

## Area contracts (what each area must expose)

### world — `scripts/world/WorldBuilder.gd`, `class_name WorldBuilder extends Node3D`
- `func build(seed: int = 1) -> void` builds everything as children (idempotent).
- `func height_at(x: float, z: float) -> float` terrain height.
- `var perches: Array[Dictionary]` — `{position: Vector3, normal: Vector3, kind: String}`
  (kind in `branch|wire|pole|ledge|roof|rock|ground`). Hundreds of them.
- `var world_radius: float`; `func random_air_point(min_alt, max_alt) -> Vector3`;
  `var landmarks: Array[Dictionary]` `{position, name}`; `var spawn_point: Vector3`
  (a good place for the player to start, ~60 m up over open ground).
- `func line_of_sight(a: Vector3, b: Vector3) -> bool` (raycast on layer 1).
- Design: a bowl ~700 m across closed by a ridge so nobody can leave; vast
  open air in the middle; dense zones for acrobatics — a forest with reachable
  branches, a village with windows/arches/roofs, a line of electric poles with
  wires, a rocky gorge. Low-poly, distinct colour zones, fog + sky.
- Environment (sky, fog, sun) is owned by the world; `WorldEnvironment` node
  named `WorldEnvironment` as a child of the WorldBuilder.

### bird art — `scripts/art/BirdMesh.gd`, `class_name BirdMesh extends Node3D`
- `static func create(size_class: int) -> BirdMesh` size classes 0..4
  (sparrow, starling/jay, hawk, eagle/heron, condor); one low-poly mesh with
  a body, head, tail and two wings that flap.
- `func set_flight(flap_phase: float, spread: float, bank: float) -> void`
  flap_phase 0..1 cycles one beat; spread folds the wings.
- `func set_tint(c: Color)`; `func size_class_for(size: float) -> int` static:
  0: <0.45, 1: <0.9, 2: <1.8, 3: <3.0, 4: ≥3.0. Mesh should be ~1 unit
  wingspan at scale 1 (the owner scales the node by `size`).
- Must be cheap: ≤ 400 triangles, one material for all birds.

### enemy AI — `scripts/ai/BirdNPC.gd` (`class_name BirdNPC extends CharacterBody3D`), `scripts/ai/Flock.gd` (`class_name Flock extends Node3D`)
- `Flock.setup(world: WorldBuilder, player: BirdPlayer)`; `Flock.spawn_bird(size: float, pos: Vector3) -> BirdNPC`;
  `Flock.birds: Array[BirdNPC]`; `Flock.populate(count: int)`; `Flock.clear()`.
- `Flock` maintains a population: keeps the sky full at the sizes the game
  loop asks for (`Flock.desired_population: Dictionary {size_band: count}` or
  a `spawn_request(size)` API), despawns far birds.
- `BirdNPC.size`, `BirdNPC.model: FlightModel`, `state` (`HUNT|FLEE|ROOST|SOAR|FLOCK`),
  `target: Node3D`. Behaviour: hunt anything smaller within awareness, flee
  anything bigger (dive for cover, break line of sight using the world),
  roost on `world.perches`, ride thermals, avoid terrain (raycasts).
  Birds hunt EACH OTHER, not just the player. Uses the same `FlightModel`.
- signal `caught(hunter: Node3D, prey: Node3D)` on Flock, emitted for NPC–NPC
  catches too; the game loop decides what a catch means for the player.
- `func strike_check(hunter_pos, hunter_heading, hunter_size, prey_pos, prey_size) -> bool`
  static rule: within reach (~1.5 × hunter wingspan) and within a 45° cone off
  the nose. Put it in `scripts/ai/CatchRules.gd` (`class_name CatchRules`).
  The game loop uses the same rule for the player.
- Collision layer 4, mask 1. Capsule/sphere shape sized by `size`.

### game loop — `scripts/game/`
- `GameRules` (RefCounted, pure): `can_eat(hunter_size, prey_size) -> bool`
  (prey < 0.85 × hunter), `growth_for(hunter_size, prey_size) -> float`,
  `loss_when_caught(size) -> float`, ranks: `rank_for(size) -> int`, `RANK_NAMES`.
- `GameManager` (`class_name GameManager extends Node`): `setup(player, flock, world)`;
  runs the loop every physics tick: player strikes on NPC prey via `CatchRules`,
  predators strike the player; growth, lives (5), score, streak, ranks; win at
  size ≥ 3.2; `restart()`; `signal event(kind: StringName, payload: Dictionary)`
  with kinds `catch, caught, rank_up, rank_down, ended, restart, spawn`;
  `var state: Dictionary` (size, lives, score, streak, rank, time, won).
  Tells the Flock what population to keep (more, bigger predators as you grow).
- `Session` (pure) optional: simulates whole runs headlessly for balance.

### UI — `scripts/ui/`
- `GameMenu` (`class_name GameMenu extends Node3D`): world-space menu panels
  (SubViewport + Control on a quad, or Label3D/MeshInstance buttons) placed
  ~2 m in front of the player's head when opened, NOT head-locked afterwards.
  Screens: MAIN (FLY, HOW TO FLY, SETTINGS, QUIT), PAUSE (RESUME, RESTART,
  SETTINGS, QUIT), SETTINGS (comfort: vignette, camera roll fraction, turn
  sensitivity, snap turn view), CONTROLS (the gesture list), SUMMARY (score, rank, FLY AGAIN).
  `open(screen)`, `close()`, `is_open`, signals `fly`, `restart`, `quit`,
  `setting_changed(key: String, value: Variant)`.
- `UIPointer`: ray from either controller, trigger to press; desktop: mouse.
- `HUD` (`class_name HUD extends Node3D`): in-world, near-field readout that
  follows the head softly: size/rank, lives, score, a threat/prey indicator
  (arrows/tints toward nearest prey and nearest predator). Legible in VR (large
  text, high contrast, ≥ 1.5° cap height at its distance).
- Keyboard: Escape opens/closes the menu. XR: menu button on either controller
  (`XRController3D.button_pressed("menu_button")` / "by_button"/"ax_button" — bind via the
  default action map).
- Pausing sets `player.frozen = true` and pauses the flock (`get_tree().paused`
  with the player's XR origin/camera process_mode ALWAYS so head tracking continues).

### audio — `scripts/audio/`
- `Soundscape` (`class_name Soundscape extends Node`): `attach(player)`;
  procedural (AudioStreamGenerator) wind that rises with airspeed, a whoosh
  per wingbeat, stall buffet, and `cue(kind)` for catch/caught/rank_up/perch/collide.
  No external audio files needed; keep CPU low.

## Integration (done last, by the integration agent)
`Main.gd`: build world → spawn player at `world.spawn_point` → flock.setup +
populate → GameManager.setup → HUD/menu attach → Soundscape.attach; menu
opens on launch; game runs in the Meta XR Simulator with captures.
