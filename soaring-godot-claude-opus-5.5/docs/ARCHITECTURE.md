# Soaring — architecture contract

A VR bird game (Godot 4.7.2, OpenXR, Meta Quest Pro target, developed against
the Meta XR Simulator on macOS). You fly by flapping and tilting your arms,
catch birds smaller than you, flee birds bigger than you, and grow.

This document is the **contract between areas**. Areas are built in parallel by
different agents; each owns a set of files and talks to the others only through
the APIs below. If you need a contract changed, change it in the smallest
backwards-compatible way, note it under "Contract changes" at the bottom, and
say so in your report.

---

## 1. Ownership

| Area | Owns (create/edit freely) | Delivers |
|---|---|---|
| **core** (foundation) | `scripts/core/`, `tests/framework/`, `tests/runner.*`, `tools/` | autoloads, Bird, SizeRules (values owned by gameloop), test + capture tooling |
| **flight** | `scripts/flight/`, `scenes/player/`, `tests/unit/flight/`, `docs/areas/FLIGHT.md` | FlightModel, WingInput, pose sources, PlayerBird rig, desktop controls |
| **vr** | `scripts/vr/`, `tests/unit/vr/`, `tests/sim/`, `docs/areas/VR.md` | VR autoload, calibration, comfort, haptics, recenter, growth via world_scale, first-person wings/hands presence, simulator test harness |
| **world** | `scripts/world/`, `scenes/world/`, `tests/unit/world/`, `docs/areas/WORLD.md` | World (terrain, town, forest, poles & wires, buildings with open windows, nests, cliffs, updrafts), sky/light/fog environment, palette |
| **birds** | `scripts/birds/`, `assets/birds/`, `tests/unit/birds/`, `docs/areas/BIRDS.md` | BirdModels for every species, wing animation, catch/feather VFX |
| **ai** | `scripts/ai/`, `scenes/ai/`, `tests/unit/ai/`, `docs/areas/AI.md` | NpcBird, brains (hunt/flee/flock/perch/soar), Ecosystem population |
| **gameloop** | `scripts/game/`, `scripts/core/size_rules.gd` (values), `tests/unit/game/`, `docs/areas/GAMELOOP.md` | GameLoop: catch rule, growth, progression, death/respawn, run stats |
| **ui** | `scripts/ui/`, `scenes/ui/`, `tests/unit/ui/`, `docs/areas/UI.md` | menus, pause, restart, settings, HUD, controls help, onboarding, VR laser pointer |
| **audio** | `scripts/audio/`, `assets/audio/`, `tests/unit/audio/`, `docs/areas/AUDIO.md` | AudioDirector: wind, wingbeats, calls, catch/danger cues, ambience, music |
| **integration** | `scenes/main.tscn`, `scripts/main.gd` | composing everything; whole-game tests |

Every area also owns `scenes/dev/<area>_*.tscn` (standalone dev/test scenes),
`tests/shots/<area>_*.gd` (screenshot scripts) and `artifacts/<area>/`.

Shared files you do **not** own: read them, don't edit them (except the
contract-change rule above): `project.godot` (ask integration; autoloads and
layers are fixed below), other areas' directories, this document.

## 2. Tooling (read this before running Godot)

**Never run `godot --path .` directly on the shared tree.** Parallel agents
would corrupt each other's `.godot` import cache. Always use:

```bash
tools/gd.sh <sandbox> [godot args...]      # sandbox = your area name, e.g. "world"
```

It rsyncs the tree into `.sandboxes/<sandbox>/`, re-imports when files
changed (class_name scripts get registered), adds `--xr-mode off`, and kills
the run after `GD_TIMEOUT` seconds (default 300). If you need two concurrent
runs, use two sandbox names (`world`, `world2`).

```bash
# Headless tests (all, one area, one test):
tools/gd.sh flight --headless res://tests/runner.tscn -- --suite=flight
tools/gd.sh flight --headless res://tests/runner.tscn -- --suite=flight --test=stall

# Screenshots need a real renderer (a window opens). ALWAYS add
# --rendering-method forward_plus on this Mac: the Mobile renderer under
# MoltenVK paints magenta tiles that never appear on Quest.
tools/gd.sh world --rendering-method forward_plus --resolution 1280x720 res://tests/shots/world_shots.tscn -- --out=world

# The Meta XR Simulator (one session machine-wide; the script queues on a lock):
tools/xr.sh 20 res://scenes/dev/vr_dev.tscn -- --xrdiag --xrshot=5,10,15
```

- `Paths.artifacts("<area>")` gives the absolute output dir (real tree, not the
  sandbox). Everything you produce as evidence goes under `artifacts/<area>/`.
- `Paths.user_args()` parses `-- --key=value` args.
- `Capture.save_viewport(vp, path)` writes a PNG after the frame draws;
  `Capture.image_stats(img)` gives mean colour / dark fraction for asserts.
- XR screenshots: `XRMirror` (scripts/vr/xr_mirror.gd) renders a mirror camera
  following the XRCamera3D (the XR viewport reads back black on macOS).
- Script parse errors show up in the import step (`.sandboxes/<name>/.import.log`)
  and at load. Always check the output for `SCRIPT ERROR` / `Parse Error`.
- Output from the simulator is noisy. Prefix every `print` with `[<area>]`
  (e.g. `print("[world] ...")`) so logs can be filtered.
- macOS has no `timeout`; use `perl -e 'alarm N; exec @ARGV' cmd...` if needed.
- **No zombies.** Every Godot run dies at `GD_TIMEOUT` (hard cap 45 min in
  tools/gd.sh). Background shell loops that wait for a run's output must have
  a deadline (`for i in $(seq 90); do ...; sleep 20; done`), never a bare
  `until ...; do sleep; done`. Before you finish, kill anything you started in
  the background that is still running (`pkill -f .sandboxes/<your-sandbox>`).
- Python 3.9 is available (no PIL); Godot itself is the image tool
  (`Image.load`, `get_pixel`) and chart renderer when you need plots.

### Tests

A suite is `tests/unit/<area>/<name>_test.gd` extending `TestCase`
(tests/framework/test_case.gd): methods `test_*` run in order and may `await`;
assertions `check/eq/near/vnear/gt/lt/between/finite`; `metric(k, v)` records
numbers into `artifacts/tests/report_<suite>.json`. The suite node lives in the
real SceneTree with every autoload, so tests can instance scenes and run
physics. Tests must be deterministic (seed any RNG) and fast (< 60 s per area
suite; put long soaks behind `--test=soak` names like `test_soak_*` if needed,
but they still run in the full suite, so keep them bounded).

## 3. Units and conventions

- Metres, kilograms, seconds, radians. +Y up, **-Z forward**, right-handed.
- World origin at the centre of the map; ground near y = 0.
- `class_name` for every reusable script; typed GDScript (`var x: float`,
  `-> void`). Tabs for indentation. Comments explain *why*.
- Deterministic generation: all random layout from a seeded
  `RandomNumberGenerator`, never the global RNG.
- Physics layers (fixed): 1 `world` (static geometry), 2 `perch`, 3 `npc_birds`,
  4 `player`, 5 `wind` (updraft Area3Ds, if any), 6 `ui` (pointer targets),
  7 `triggers`.
- Groups: `birds` (every Bird), `world` (the World), `player_rig` (the
  XROrigin3D the player flies), `player` (the PlayerBird), `ecosystem`,
  `game_loop`, `ui_root`, `audio_director`, `ui_pointer_target`. Find
  singletons-in-scene with `get_tree().get_first_node_in_group(&"...")`;
  always tolerate them being absent (dev scenes run areas alone).
- Machine limits: 16 GB RAM shared by up to ~10 agents and the simulator.
  Prefer headless runs; keep rendering runs short; never leave a Godot
  process running (runs must quit themselves); one rendering Godot per agent
  at a time.
- Harmless noise to ignore: `ERROR: Condition "p_tracker.is_null()" is true`
  at exit of `--xr-mode off` runs, and the ObjectDB leak warning it causes.

## 4. Runtime composition

`scenes/main.tscn` (owned by integration) composes:

```
Main (Node3D, scripts/main.gd)
├── World            scenes/world/world.tscn   (World; includes WorldEnvironment + sun)
├── Ecosystem        scenes/ai/ecosystem.tscn  (spawns NpcBirds as its children)
├── Player           scenes/player/player.tscn (PlayerBird → XROrigin3D → camera, hands)
├── GameLoop         scripts/game/game_loop.gd
├── UI               scenes/ui/ui_root.tscn
└── Audio            scenes/audio/audio_director.tscn
```

Startup: autoloads (`Events`, `Game`, `Birds`, `Settings`, `VR`) → World
generates → Player spawns at `World.get_player_spawn()` → `Game.set_state(MENU)`
→ UI shows the main menu → Play → GameLoop starts a run (`Game.PLAYING`).

**Pause**: `Game.set_state(PAUSED)` sets `get_tree().paused`. Anything that must
keep running while paused sets `process_mode = PROCESS_MODE_ALWAYS`: the XR rig
(XROrigin3D and everything under it — a frozen head pose in VR is nauseating),
UI, audio director, VR autoload. Gameplay (flight integration, AI, game loop)
is pausable.

## 5. Core contracts (scripts/core, fixed)

- **`Bird`** (`class_name Bird extends Node3D`): `mass` (kg, progression
  currency), `species`, `velocity`, `alive`, `perched`; `is_player()`,
  `get_body_position()` (the player's is the head), `get_forward()`,
  `get_wingspan()`, `get_body_radius()`, `can_eat(other)`, `on_caught(by)`,
  `on_ate(prey, mass_gained)`. Birds self-register with `Birds`.
- **`Birds`** autoload: `all()`, `player()`, `nearby(pos, r, exclude)`,
  `nearest(pos, r, filter, exclude)`.
- **`Events`** autoload: the signal bus (see scripts/core/events.gd). Emit facts,
  never presentation. Who emits: GameLoop → `bird_caught`, `player_caught`,
  `player_grew`, `player_tier_changed`, `run_started`, `run_ended`; PlayerBird →
  `player_flapped`, `player_collided`, `player_perched`, `player_took_off`,
  `player_stalled`, `player_spawned`; GameLoop (or AI) → `threat_changed`,
  `target_changed`; UI → `menu_requested`, `recenter_requested`,
  `settings_changed` (via Settings).
- **`Game`** autoload: `State {BOOT, MENU, PLAYING, PAUSED, CAUGHT, ENDED}`,
  `set_state()`, `is_playing()`, `run_time`.
- **`Settings`** autoload: `get_value/set_value`, persisted. Add your keys to
  `DEFAULTS` via a contract change note.
- **`SizeRules`**: species ladder (`SPECIES`: moth, wren, sparrow, swallow,
  starling, pigeon, crow, gull, hawk, eagle — ids are fixed, values tunable by
  gameloop), `EAT_RATIO`, `wingspan_for_mass`, `body_radius_for_mass`,
  `tier_for_mass`, `species_for_mass`, `species_data`.
- **`VR`** autoload (owned by vr): `active` (headset/simulator vs desktop),
  `focused`, signals `session_focused/unfocused/stopping/recentered`. Sets
  physics ticks to the display refresh rate so flight integrates once per
  displayed frame.

## 6. Area contracts

### flight → everyone
- `PlayerBird extends Bird` (scenes/player/player.tscn root). Children:
  `XROrigin3D` (group `player_rig`, PROCESS_MODE_ALWAYS) → `XRCamera3D`,
  `LeftHand`/`RightHand` (XRController3D, trackers `left_hand`/`right_hand`).
- The player flies by moving the PlayerBird node (translation + yaw only; the
  view never pitches or rolls — comfort). Growth is `XROrigin3D.world_scale`,
  **never** node scale on the rig or its ancestors.
- `PlayerBird.telemetry() -> Dictionary` with at least: `airspeed`,
  `groundspeed`, `vertical_speed`, `altitude_agl`, `aoa` (rad), `bank` (rad),
  `stalled`, `flapping` (0..1), `wing_extension` (0..1, mean), `tucked`,
  `perched`, `in_updraft` (m/s of lift), `g_load`, `lift` (N), `drag` (N).
  Audio, HUD and haptics read this each frame.
- `PlayerBird.respawn(xform: Transform3D)`, `PlayerBird.set_controls_enabled(bool)`.
- `WingInput` turns hand/head poses (tracking space) into a scale-free
  `WingState`; `FlightModel` (RefCounted, no scene deps) integrates it. Pose
  sources are swappable: XR controllers, scripted/replayed poses (tests), and a
  desktop emulator (keyboard/mouse) — **all go through the same WingInput**.
- `FlightModel` is reusable by AI (NpcBird may fly the same physics with an
  autopilot producing WingState).

### world → everyone
`World` (scripts/world/world.gd; find with `World.find(get_tree())`):
`get_wind(pos)`, `ground_height(x, z)`, `get_perches()`, `find_perches(pos, r,
span)`, `get_player_spawn()`, `get_landmarks()`, `get_refuges()`,
`is_inside(pos)`, `bounds_radius`, `ceiling`, signal `generated`. `Perch`
(scripts/world/perch.gd): position, facing, kind, max_span, occupant. Static
geometry on layer 1 with collision; the world is closed (birds cannot leave).
The base class is a flat, windless plain so others can test now.

### birds → ai, flight, vr
`BirdModels.create(species) -> BirdModel`. `BirdModel` (Node3D, wingspan 1.0,
beak -Z, origin at body centre; owner sets `scale = Vector3.ONE * wingspan`):
set `flap_phase`, `flap_amount`, `wing_fold`, `bank`, `perched`, `highlight`
each frame. Plus VFX helpers (e.g. `BirdFX.feather_burst(parent, pos, color)`).

### ai → gameloop
`Ecosystem` (scenes/ai/ecosystem.tscn, group `ecosystem`): keeps the sky
populated around the player by tier; `reset()` on a new run; exposes `stats()`
for tests. `NpcBird extends Bird` (has `model: BirdModel`) steers itself (hunt smaller, flee bigger, flock, perch, soar
thermals, avoid geometry). NPCs never decide catches — they only get close.

### gameloop → everyone
`GameLoop` (scripts/game/game_loop.gd) is the **only** owner of the catch rule:
it checks predator/prey contact for every bird pair each physics frame, emits
`Events.bird_caught`, calls `on_caught/on_ate`, grows the eater, handles player
death → `Game.CAUGHT` → respawn/end, and tracks run stats (`get_run_stats()`).

### ui
World-space panels (SubViewport → quad) in VR, 2D overlay on desktop. Menus:
main, pause, settings, controls help, caught/game-over, run summary. HUD:
size/tier, growth progress, threat/target cues, altitude/speed if useful.
Onboarding: first-flight lessons. Laser pointer from controllers (trigger to
click). Menu opens on the controller menu button / Escape.

### audio
`AudioDirector`: listens to Events and polls `PlayerBird.telemetry()`. Wind by
airspeed, wingbeats, calls of nearby birds (3D), catch/caught/danger cues,
updraft, ambience per zone, light music. Must keep playing while paused
(menus) but duck gameplay sounds.

## 7. Quest target rules (hard-won; do not violate)

1. **Never scale the XROrigin3D or any ancestor of it.** A sibling attempt that
   did so ended up with a headset showing flat sky/ground colour. Growth uses
   `XROrigin3D.world_scale`. Scale bird models freely.
2. The view never pitches or rolls from flight; only yaw + translation.
3. Mobile renderer. No SSAO/SSR/SDFGI/volumetric fog. Glow sparingly. At most
   one directional shadow (or baked/blob shadows). MSAA 4x.
4. Budgets (Quest Pro, per eye, 72–90 Hz): ≤ 150 draw calls, ≤ 300k visible
   triangles, ≤ 60 active NPC birds. Use MultiMesh for trees/foliage/fences,
   merge static meshes, share materials (a palette texture/vertex colours).
5. Camera near/far sane for the scale: near ≈ 0.02–0.065 × world_scale
   (0.06 in the game since integration round 1: the Quest draws into a
   24-bit depth buffer, where the near plane sets the precision far away),
   far ≤ 3000.
6. Everything under XROrigin3D is PROCESS_MODE_ALWAYS.
7. Don't rely on the desktop window: in XR the main viewport is the headset.

## 8. Definition of done (per area)

An area is done only when all hold, with evidence in `artifacts/<area>/` and
`docs/areas/<AREA>.md`:
1. Headless suite `tests/unit/<area>/` passes and actually pins the behaviour
   the prompt asks for (not just "it runs").
2. A dev scene demonstrates the area on its own.
3. Visual evidence (screenshots / plotted telemetry) reviewed by eye.
4. No `SCRIPT ERROR`, no warnings spam, no leaks in its runs.
5. Budgets respected.
6. The area doc says what was built, how it was verified, known limits.

## Contract changes

(Append: date, area, what changed, why.)

- **2026-09-25, ui — additive, how UI talks to the other areas** (details in
  `docs/areas/UI.md`):
  - *GameLoop (duck-typed, all optional):* Play / Fly again call
    `start_run()`, Restart run calls `restart_run()` (falls back to
    `start_run()`), Quit to menu calls `quit_run()` then
    `Game.set_state(MENU)`. GameLoop should set `Game.PLAYING` itself; if the
    state was not reached, UI sets it (so the UI works without a GameLoop).
    UI reads `get_run_stats()` and the `Events.run_ended(summary)` dictionary,
    tolerating missing keys: `time`, `score`, `best_score`, `catches`,
    `catches_by_species` ({species id: count}), `max_mass`, `max_tier`,
    `lives` (remaining), `lives_max`, `respawn_in` (s, while CAUGHT).
  - *Menu button:* UI emits `Events.menu_requested` for the left controller's
    `menu_button` and for Escape, and toggles pause itself. Duplicate reports
    of one press within 250 ms are ignored, so VR may emit it too harmlessly.
    B/Y (`by_button`) = Back inside menus.
  - *VR:* `UIRoot` (group `ui_root`) has signal `recalibrate_requested()`
    (Settings > Recalibrate wings); Recenter emits `Events.recenter_requested`.
    UI adds its own `XRController3D` nodes (pose `aim`, names `UIAim_*`,
    PROCESS_MODE_ALWAYS) under the `player_rig` for the laser pointer.
  - *Birds:* UI sets `BirdModel.highlight` = 1 on the current target and 2 on
    the current threat (via the bird's `model` property, if it has one) and
    resets it to 0 when they change.
  - *Flight telemetry keys the lessons read:* `wing_extension`, `flapping`,
    `airspeed`, `vertical_speed`, `bank`, `tucked`, `perched`; plus
    `Events.player_flapped` (strength >= 0.25 counts as a wingbeat) and
    `Events.bird_caught` with the player as predator.
  - *Persistence:* tutorial completion and a fallback best score live in
    `user://ui_progress.cfg`, not in Settings. No Settings keys were added;
    the settings screen edits `comfort_vignette`, `master_volume`,
    `music_volume`, `haptics`, `seated`, `handedness`.

- **2026-09-25, world — additive** (details in `docs/areas/WORLD.md`):
  - `World` base: `var is_generated: bool` (check before awaiting
    `generated`, which may already have fired); `_ready()` now calls a
    virtual `_generate()` and then emits `generated` (subclasses that define
    their own `_ready`, like `AiTestWorld`, are unaffected but should set
    `is_generated = true` when done so waiters don't hang); new
    `get_thermals() -> Array[Dictionary]` (`{name, position (ground centre),
    radius, strength, base_strength, top, lean}`; base returns `[]`).
  - `Perch`: new `district: StringName`; documented that `position` is the
    grip point on the surface (body centre ≈ one body radius above).
  - Landmarks: kind `"opening"` entries carry `type` (window, belfry,
    barn_door, barn_slat, barn_loft, nest_box, cliff_hole, hedge_gap,
    tree_hollow, tower, arch, bridge_arch), `normal`, `width`, `height`,
    `max_span`, `depth`, `frame`, `up`; kind `"window"` (one per fly-through
    house, with `exit`); more kinds: glade, canyon, arch, tower, bridge,
    lake, meadow, field, hedge, orchard, farm, powerline, jetty. Refuge
    dictionaries also carry `name`.
  - The real world is `SoaringWorld` (`scenes/world/world.tscn`); it brings
    its own `WorldEnvironment` + `Sun` (export `with_environment` turns them
    off) — integration should remove main.tscn's placeholder
    environment/sun/ground. Extras: `set_lighting(&"day"|&"dusk")`,
    `set_air_time(t)`, `get_openings()`, `stats()`.
  - `ground_height()` includes water surfaces (`max(terrain, water)`); lake
    and river surfaces collide on layer 1. Tree bodies are on layers 1 and 2.
- **2026-09-25, gameloop — values + additive** (details in `docs/areas/GAMELOOP.md`):
  - *SizeRules values (owned by gameloop):* species masses retuned for pacing
    (starling 0.1, pigeon 0.3, crow 0.5, gull 0.85, hawk 1.3, eagle 3.0 kg;
    moth/wren/sparrow/swallow and every wingspan unchanged).
    `wingspan_for_mass()` is now continuous and strictly increasing
    (log-log interpolation between species; still exact at each species'
    mass) — the player's size (world_scale) no longer jumps at tier-ups
    (it used to shrink 7% on becoming an eagle).
  - *SizeRules additions:* `meal_value(eater, prey)` (how worth chasing,
    size-independent: depends only on the mass ratio), `is_worthwhile(eater,
    prey)` (value >= `WORTH_MIN`, i.e. prey heavier than ~1/10 of you),
    `meal_gain(eater, prey)` (the one growth formula: value x eater mass x
    `growth_efficiency(eater)`, which falls with size), `meal_worth(eater,
    prey)` (actual growth as a fraction of the eater's mass, for display),
    `meal_efficiency(ratio)`, `time_scale(mass)` (body time: 1 sparrow … 4
    eagle); constants `MEAL_CONVERSION`, `MEAL_DUST_RATIO`,
    `MEAL_FULL_RATIO`, `WORTH_MIN`, `GROWTH_REF_MASS`, `GROWTH_SIZE_EXP`.
    **AI: please rank/admit prey with `is_worthwhile`/`meal_value`** (the
    loop's highlights, target cue and apex count use them).
  - *GameLoop API* (`GameLoop.find(tree)`, group `game_loop`): `start_run()`,
    `restart_run()`, `quit_run()` (as UI expects), `end_run(reason)`,
    `to_menu()`, `pause()`, `resume()` (returns to CAUGHT if paused
    mid-beat; a UI that sets PLAYING from PAUSED mid-beat is corrected),
    `continue_after_victory()`, `get_run_stats()` (also carries the UI's
    keys `time`, `max_mass`, `max_tier`, `lives`, `lives_max`,
    `respawn_in`), `get_last_summary()`, `protection_left(bird)`,
    `set_protection(bird, s)`, `teleported(bird)` (call after moving a bird
    discontinuously, e.g. pooling, so the jump is not swept for catches;
    jumps > 90 m/s are detected anyway), `catch_assist()`. Signals:
    `player_mass_changed(old, new, reason)`, `lives_changed(lives)`,
    `apex_reached()`, `apex_progress(catches, needed)`, `victory(summary)`,
    `player_respawned(protection_s)`. `Events.player_grew` fires only for
    growth; tier changes (up or down) fire `player_tier_changed` once.
  - *Highlights:* GameLoop writes `BirdModel.highlight` for every bird in
    range (1 worthwhile prey, 2 can eat the player, else 0) and re-asserts
    it every frame, so UI's own writes to its target/threat (same values)
    are harmless; UI may drop them.
  - *Protection:* while the player is protected (run start 3 s, respawn
    5 s) GameLoop sets meta `npc_ignore = true` on the player (the AI
    brains already honour it).
  - *Pacing requirement on the Ecosystem:* the pacing tests assume the AI's
    current plan (60 NPCs, ~24 worthwhile prey, ~12 threats, metric radii)
    and its per-species wariness (mirrored in `scripts/game/sim/ai_mirror.gd`);
    fleeing prey must tire (fewer jinks/breaks once their burst is spent),
    or small-bird chases become unwinnable. Retuning those numbers means
    re-running `tests/shots/gameloop_pacing.tscn`.

- **2026-09-25, ai — additive** (details in `docs/areas/AI.md`):
  - *Ecosystem API* (group `ecosystem`): `reset(seed := -1)` (clears and
    repopulates on the next step), `stats()`, `step(dt)` (with
    `auto_step = false`), `get_npcs()`, `count()`, `in_view(pos)`, export
    `focus` (defaults to `Birds.player()`), `max_npcs`, `rng_seed`; signals
    `npc_spawned(npc)`, `npc_despawned(npc, reason)`. It waits for
    `World.is_generated`, reads `get_thermals()` (live, leaning columns) and
    links each refuge to the nearest `opening` landmark (birds enter and
    leave cover along the opening's normal).
  - *NpcBird* (for UI/audio/game loop): `model`, `state`/`state_name()`,
    `target` (prey it is chasing), `threat` (predator it is fleeing),
    `hidden`, `perched`, `energy`, `hunger`; signals `caught(bird, by)`,
    `ate(bird, prey)`, `behaviour(bird, what)` ("hunt", "stoop", "flee",
    "jink", "refuge", "perch", "thermal", ...). `on_caught` works whether or
    not the caller cleared `alive` first (GameLoop does). NPC mass may be
    changed by GameLoop at any time (flight envelope and model scale follow).
  - *Conventions the AI honours:* meta `npc_ignore == true` on a bird = NPCs
    neither hunt it nor count it as prey (GameLoop's respawn protection);
    the player is only hunted in `Game.PLAYING` (or `BOOT`, dev scenes).
    For "out of the player's view" the Ecosystem calls the player's
    `get_view_direction()` if it has one (optional), else uses the viewport
    camera's forward, else the body forward.
  - *Prey worth:* NPC prey choice and the Ecosystem's prey/dust split use
    `SizeRules.is_worthwhile` (as GameLoop asked).

- **2026-09-25, ui (fix round 1) — additive, plus one correction** (details
  in `docs/areas/UI.md`):
  - *Correction:* UI emits `Events.menu_requested` for **either**
    controller's `menu_button` (on Quest only the left one has it), not only
    the left's as noted above; still debounced 250 ms.
  - *Hands and wings in front of UI (for vr/flight):* UI panels, the HUD,
    the laser beam/reticle and the peripheral cues ignore depth (scenery
    must never cut into a menu), so anything of the player's own body would
    be painted over. Materials of the player's hands, wings and controller
    models should call `UIPanel.mark_occluder(mat)` (opaque
    `BaseMaterial3D`; it writes stencil value `UIPanel.OCCLUDER_STENCIL` =
    64) — UI does not draw over those pixels. Verified from rendered pixels
    (`tests/shots/ui_shots.gd`, `vr_occluders.png`). A ShaderMaterial can do
    the same with `stencil_mode write, compare_always, 64;`. Nothing else
    should write stencil 64.
  - *Focus:* UI pauses the run (`Game.set_state(PAUSED)` from PLAYING or
    CAUGHT) on `VR.session_unfocused` (headset off, system menu).
  - *Records:* the run summary's "New best!" and Best value follow
    `summary.new_records.score` / `summary.records.best_score` (as
    GameLoop's `end_run` already emits); UI's own `ui_progress.cfg` best is
    only a fallback when those keys are absent.
- **2026-09-25, world (fix round 1) — one semantic widening, additive**
  (details in `docs/areas/WORLD.md`):
  - `ground_height(x, z)` now returns the *solid ground*: terrain, water
    surface, **and the rock masses that stand on the floor** (the west cliff
    and the canyon walls, up to ~93 m above the valley floor there),
    precisely the first solid-to-air boundary going up from the floor (under
    an overhanging brow the flyable air in front of the face stays above
    ground).
    Round 1 returned the buried valley floor under them, so a bird placed at
    `ground_height + 10 m` over the cliff was inside rock and altitude-above-
    ground was off by up to 93 m. Free-standing things you can fly under or
    around are still not ground: buildings, trees, props, boulders, the
    bridge and the two rock arches. Signature unchanged; the base `World`
    doc comment says so. Cost ~2 µs per call.
  - `get_wind()` adds a **soft edge**: over the last 45 m inside the
    boundary the air pushes inward (horizontal, up to 6 m/s at the wall,
    smooth), so birds are slowed and turned back before the invisible wall
    (`WindField.EDGE_BAND`, `EDGE_PUSH`, `edge_push(pos)`). Flight/AI: this is
    ordinary wind; nothing to do.
  - Landmarks: the rock-arch *openings* are renamed `canyon_arch_passage`
    and `lake_arch_passage` (landmark names are now unique; the `arch`
    landmarks keep `canyon_arch` / `lake_arch`), and their size and
    `max_span` are measured on the built colliders. New landmark kinds
    `ride` (forest tracks) and a second `forest` entry, `old_wood` (the
    dense core).
- **2026-09-26, vr — additive** (details in `docs/areas/VR.md`):
  - *VR autoload* (`class_name VRManager`, still autoload `VR`): new signals
    `session_state_changed(state)`, `refresh_rate_changed(hz)`,
    `user_presence_changed(present)`, `recalibrate_requested()`; new fields
    `refresh_rate`, `user_present`, `haptics: VRHaptics`,
    `controls: VRControls`; `recenter()`, `request_pause()`. Focus loss
    (`session_visible`, `session_stopping`, `user_presence_changed(false)`)
    from PLAYING/CAUGHT emits `Events.menu_requested` **before**
    `session_unfocused` (UI toggles on the former and ignores the latter
    once paused), and pauses directly if nothing handled it; regaining
    focus never resumes. `Events.recenter_requested` and the runtime's
    `pose_recentered` both call `XRServer.center_on_hmd(RESET_BUT_KEEP_TILT,
    true)` and emit `VR.recentered` once: flight should re-seat on
    `VR.recentered` (listening to both is harmless, the re-seat is
    idempotent).
  - *world_scale is VR's*: `WorldScaleDriver` (in the rig extras) writes
    `XROrigin3D.world_scale` = (span / (arm_span + 0.20))^exponent, ramped
    at <= 0.25 ln/s, held while paused, and `XRCamera3D.near` =
    max(0.001, 0.03 x world_scale), in `_physics_process` with
    `process_physics_priority = -100` (before PlayerBird). Flight must not
    write either.
  - *Rig extras*: integration instances `scenes/vr/vr_rig_extras.tscn`
    under the player's `XROrigin3D` (it also finds group `player_rig` if
    placed elsewhere). At runtime it moves `FirstPersonWings` under the
    origin and `ComfortVignette` under the `XRCamera3D`, creates grip
    `XRController3D`s (`VRGrip_L/R`) only if the rig has none, and forces
    PROCESS_MODE_ALWAYS on the origin subtree (pausable nodes added under
    it are corrected, with a warning).
  - *Calibration*: VR's `VRCalibration` writes every `WingCalibration`
    field that exists (legacy `neutral_roll_*` and the FLIGHT_SPEC §5.11
    set, duck-typed) into `PlayerBird.wing_input.calibration` (or
    `PlayerBird.calibration`) and persists `Settings["wing_calibration"]`
    as `{version, arm_span, shoulder_width, shoulder_drop, glide_reach,
    fold_elevation, stroke_full_rate, stroke_full_arc, seated, calibrated,
    neutral_left/right (Basis), forearm_axis_left/right,
    chord_axis_left/right (Vector3)}` (the §5.11 field names, native
    values; VR also reads flat arrays), plus the deprecated `arm_span`
    mirror. If WingInput keeps its own neutral capture, VR's is the one
    that persists (last writer wins, same maths, FLIGHT_SPEC §5.10).
  - *Settings keys read with fallbacks* (core: please add to `DEFAULTS`):
    `vr_refresh_rate` (0 = auto: 72 Hz on Android, 90 elsewhere),
    `vr_foveation_level` (3), `vr_foveation_dynamic` (true),
    `world_scale_exponent` (1.0), `wing_calibration` ({}); existing
    `comfort_vignette`, `haptics`, `seated` are honoured.
  - *Services for other areas*: `VR.haptics.play(&"<pattern>", mask,
    strength)` is the one haptics player (patterns in `HapticPatterns`;
    rate limits, 30 % duty cap and the `haptics` setting applied);
    `VR.controls.trigger(hand)`, `grip(hand)`, `is_trigger_down`,
    `is_grip_down` and signals `trigger_changed`, `grip_changed`,
    `button_changed`, `long_pressed` (hands `&"left_hand"`/`&"right_hand"`).
    Long presses: B 0.8 s = pause (only while flying; short B/Y stays UI's
    Back), A/X 1 s = `Events.recenter_requested`, Y 1.5 s =
    `VR.recalibrate_requested`.
  - *XRMirror* now renders only around a capture (it rendered a second
    full view every frame, also in `main.tscn`); new `capture_image()`,
    `always_render`, `fov`, user arg `--xrshot_dir=<area>`.
  - *Project settings for integration* (not edited by VR):
    `rendering/vrs/mode=2` (VR also sets the main viewport's VRS mode at
    runtime), `xr/openxr/foveation_level=3`, `foveation_dynamic=true`,
    `foveation_eye_tracked=false`, `foveation_with_subsampled_images=false`,
    `xr/openxr/extensions/user_presence=true`; keep
    `physics_ticks_per_second=72` (VR overrides at runtime); vendors plugin
    upgrade before the first Android export (docs/research/QUEST.md §0).
- **2026-09-26, ui (fix round 2) — additive** (details in `docs/areas/UI.md`):
  - *GameLoop's apex goal and victory (duck-typed, optional):* UI connects
    GameLoop's `apex_progress(catches, needed)` and `apex_reached()` when
    they exist, and reads `get_run_stats()["apex"]` (`catches`, `needed`,
    `victory`) and `endless`. At the top of the ladder the HUD strip and
    the pause screen show the goal ("2 of 5 to win"); each apex catch gets
    a short celebration. A run summary with `victory == true` (or `reason
    == &"victory"`) is presented as a victory and offers **Keep flying**,
    which calls `GameLoop.continue_after_victory()` (fallback without a
    GameLoop: ENDED -> PLAYING keeping `Game.run_time`).
  - *What UI calls prey:* the pause ladder, its lines and the tier-up toast
    use `SizeRules.is_worthwhile` (as GameLoop's highlights and target cue
    do): "Hunt: <worthwhile range>", "Ignore: <edible but not worth it>";
    a tier-up names what just dropped off the menu.
  - *Where the HUD is (for integration and anyone placing things in the
    view):* no longer one panel at -19 deg. In VR the HUD is two bands of
    one SubViewport: notices (lesson card, celebrations) at +7..+20 deg
    above eye level and the growth strip at -37..-43 deg; nothing of the
    HUD sits between. A band turns see-through while it would cover the
    flight path (player `velocity`), the current target or a threat
    (level >= 0.1).
  - *Highlights:* UI writes `highlight` on any bird whose `model` has that
    property (duck-typed; UI no longer depends on `BirdModel` compiling).
  - *Restart run / Quit to menu* (pause screen) now act on a 0.8 s hold of
    the trigger (or mouse / Enter), not a single click. Testers on
    hardware: hold them.
- **2026-09-26, birds — additive** (details in `docs/areas/BIRDS.md`):
  - *BirdModel* fields are unchanged plain vars (`flap_phase`, `flap_amount`,
    `wing_fold`, `bank`, `perched`, `highlight`, `species`). The model shows
    them smoothed (0.08–0.16 s), so owners may switch them abruptly; call
    the new `snap()` after spawning, pooling or teleporting a bird to show
    the fields at once. Phase 0 = top of the upstroke; the downstroke is
    phase 0..0.42.
  - A BirdModel **has no child nodes**: every species/LOD is drawn by one
    shared MultiMesh (`BirdBatch`), synced once per frame in
    `RenderingServer.frame_pre_draw`, after every `_process` and
    `_physics_process`. Moving, scaling, hiding (`visible`), reparenting,
    freeing and changing `species` work as for any Node3D. Headless runs
    draw nothing, so nothing is synced there; the fields still work.
  - *Optional extras:* `get_wingtip(side)` (world position of a drawn
    wingtip), `displayed_pose()`, `displayed_bank()`,
    `displayed_highlight()`, `get_lod()`, `lod_bias`, `lod_override`,
    `render_layers` (e.g. to hide the player's own body from its camera),
    `cast_shadows`.
  - *Perching:* a perched model's feet are 0.16 x wingspan below its origin
    (= `SizeRules.body_radius_for_mass`), i.e. on `Perch.position` when
    the body centre sits one body radius above it. Set `perched = true`
    and `wing_fold = 1` (as NpcBird does).
  - *Highlight look:* 1 = violet (edible), 2 = orange-red (danger).
    Highlighted birds are drawn at least 0.7 deg wide so far targets read
    (visual only). UI may match its cues with the new
    `BirdModels.HIGHLIGHT_EDIBLE` / `HIGHLIGHT_DANGER` (sRGB).
  - *BirdModels additions:* `palette(sp)`, `wing_palette(sp)` (for VR's
    first-person wings: `upper_coverts`, `upper_flight`, `upper_primaries`,
    `under_coverts`, `under_flight`, `accent`, all sRGB), `prewarm()`
    (about 40 ms for all 30 meshes), `material()`, `mesh(sp, lod)`,
    `triangle_count()`, `body_aabb()`, `LOD_COUNT`.
  - *BirdFX:* `feather_burst(parent, pos, color := transparent, span := 0.3,
    species := &"", velocity := ZERO, seed := -1) -> FeatherBurst` (frees
    itself after about 2.3 s), `catch_burst(prey: Bird)`,
    `attach_trails(model) -> WingTrails` (subtle wingtip trails above 1.35x
    the bird's cruise speed). `BirdFXDirector` (Node) makes a burst on every
    `Events.bird_caught`: integration may drop one into `main.tscn`, or
    GameLoop may call `BirdFX.catch_burst`, but not both.

- **2026-09-26, audio — additive** (details in `docs/areas/AUDIO.md`):
  - *New shared file:* `res://default_bus_layout.tres` (Godot loads it at
    startup): buses `Master` [HardLimiter, ceiling -1.5 dB] > `Music`, `SFX`
    [muffle low-pass, off] > (`Wind`, `Body`, `Calls`, `Danger`), `Ambience`
    [muffle, off], `UI`. `AudioBuses.ensure()` recreates anything missing, so
    the director also works without the file. Nothing else should route to
    or change these buses (the director owns their volumes).
  - *Settings (optional keys, no DEFAULTS change needed):* the director reads
    `master_volume`, `music_volume` (existing) and `sfx_volume`,
    `ambience_volume`, `ui_volume` (default 1.0 via `Settings.get_value`
    fallback). Taper: bus dB = 40 log10(v) (0.5 = -12 dB), 0 mutes. UI may
    add sliders for the three new keys; core may add them to `DEFAULTS`.
  - *AudioDirector API* (group `audio_director`, all optional):
    `play_ui(kind)` (`click`, `select`, `back`, `open`, `close`, `confirm`,
    `hover`; pause open/close already play on `Game` state changes),
    `await shutdown()` (stops every sound and lets the mixer drain: call it
    before `get_tree().quit()` for a clean exit, since Godot's AudioServer
    does not free playbacks still in its list at quit), signal
    `cue(name, info)`, `debug_snapshot()`, `perf_stats()`.
  - *What audio reads (all tolerant of absence):* telemetry `airspeed`,
    `wing_extension`, `tucked`, `stalled`, `in_updraft`, `perched`, and
    optionally `stall_warning` (0..1) and `world_scale`; `XROrigin3D.world_scale`
    via group `player_rig` and its `LeftHand`/`RightHand` (wingbeats play at
    the flapping hand); `Events` player_flapped / bird_caught / player_caught
    / player_tier_changed / player_collided / player_perched /
    threat_changed / target_changed / game_state_changed /
    settings_changed / bird_removed; GameLoop's `apex_reached` / `victory`
    if present; `World.get_landmarks()` kinds forest, orchard, glade, ride,
    hedgerow, hedge, lake, river, jetty, bridge, town, village, farm,
    meadow, field, cliff, canyon, arch (a landmark named `church*` places
    the village bell); NpcBird duck-typed `state_name()`, `hidden` and its
    `behaviour` signal (`stoop` makes a hawk/eagle scream).
  - *Listener:* 3D sound follows the current `Camera3D` (the XRCamera3D in
    VR). Note for tests: a bare `AudioListener3D` renders 3D players silent
    in headless runs; use a current Camera3D.
- **2026-09-26, world (fix round 2) — values + additive** (details in
  `docs/areas/WORLD.md`):
  - *Openings:* two new `type`s for mid-size birds, `vent` (a 0.4 m pigeon
    hole high in the side wall of every house, into its room; rated ~1.04
    m span) and `barn_board` (two broken boards in the barn's north wall).
    The belfry arches' `max_span` and `depth` now come from a measured
    flight through the whole belfry and out of the opposite arch (the bell
    hangs higher, above the arches' line); `depth` is the tower width + 1 m.
  - *Refuges:* the belfry refuge sits under the bell and its `max_span` is
    measured (a body that gets in through an arch and fits there). Shut
    houses gain a `house_N_room` refuge reached only through their vent.
  - *Thermals (values):* `square` r 36 m, `east_plough` r 37 m, `hay_field`
    r 40 m / 3.9 m/s, `forest_glade` r 40 m / 3.8 m/s (so every species'
    30-degree thermalling circle gains >= 1.5 m/s; asserted per species).
  - *Swallow colony:* the burrows (`cliff_hole_*`, same names and ratings)
    are cut into a sand bed that is part of the cliff's strata; their
    positions and normals moved with the new face.
  - *Rendering only:* `SoaringWorld._process` swaps far terrain chunks to a
    16 m mesh from the current `Camera3D`'s position (the XR camera in VR);
    tree chunks use visibility parents (HLOD). Nothing to do for other
    areas; collision is unchanged.
- **2026-09-26, vr (fix round 1) — values + additive, backwards compatible**
  (details in `docs/areas/VR.md` §9):
  - *Refresh policy (value):* `vr_refresh_rate` 0 = auto is now **72 Hz
    everywhere** (Quest and the simulator alike); 90 Hz stays one setting
    (or `--refresh=90`) away. Supersedes "90 elsewhere" above.
  - *Calibration:* VR's automatic neutral capture now runs only while the
    PlayerBird is `spawning`/`perched`/`grounded` (duck-typed
    `mode_name()`; a player without it is trusted only outside PLAYING;
    never while paused), the same gate as flight's own capture. If flight
    captured first (`wing_input.calibration.calibrated`), VR adopts that
    calibration and persists it instead of capturing again. Uncalibrated,
    VR never pushes its defaults into flight's resource (it used to write
    `calibrated = false` over a flight capture at startup). Live `seated`
    written into flight's resource is detected OR the Settings preference
    (the persisted dict keeps only the detected flag). Two refinements of
    FLIGHT_SPEC §5.10 in the fields VR writes (same field meanings):
    `shoulder_drop` from body proportions (0.15 x stature, stature from the
    standing eye height and the arm span) kept consistent with the hand
    line, instead of assuming the arms 5° low; and `neutral_left/right`
    swung to the canonical arm direction (straight out, 5° low) so the
    wrist habit is kept but the capture's arm height and sweep are not.
    Flight may adopt both in its own capture (`WingCalibrator.estimate_drop`,
    `WingCalibrator.canonical_neutral`, static and pure).
  - *world_scale:* snaps (no ramp) on `Events.run_started` and
    `Events.player_spawned`, and is left untouched until a player mass
    exists; growth in play still ramps at <= 0.25 ln/s.
  - *Vignette:* one-tick rig yaw steps (> 720°/s, 3x flight's comfort cap),
    `PlayerBird.yaw_flagged` ticks and the tick after `VR.recentered` are
    re-seeded, not measured.
  - *Haptics:* the danger heartbeat holds the last `threat_changed` level
    until a report below 0.35, the hunter dies or is freed, the game leaves
    PLAYING/PAUSED, `run_ended` or `player_spawned`.
  - *First-person wings:* colours come from `BirdModels.wing_palette(sp)`
    (duck-typed; a copy is the fallback); VR places the `accent` per species
    (`FirstPersonWings.ACCENT_AT`). Birds: an `accent_kind` key in
    `wing_palette` (bar / tip / te / edge / band) would let VR drop that
    table; additive and optional.
  - *New file:* `scripts/vr/calibration_prompt.gd` (`CalibrationPrompt`),
    the calibration card (2 draw calls while the flow runs, none otherwise).

- **2026-09-26, flight — additive, plus one flight-owned field set replaced**
  (details in `docs/areas/FLIGHT.md` and `docs/areas/FLIGHT_SPEC.md` §15):
  - *WingCalibration* (flight's resource): the FLIGHT_SPEC §5.11 fields
    (`arm_span` grip-to-grip, default 1.50 m; `shoulder_width`,
    `shoulder_drop`, `glide_reach`, `fold_elevation`, `stroke_full_rate`,
    `stroke_full_arc`, `seated`, `calibrated`, `neutral_left/right`,
    `forearm_axis_left/right`, `chord_axis_left/right`) replace the old
    `neutral_roll_*` / `neutral_pitch_*`. `to_dict()` / `from_dict()` read
    and write exactly the dictionary VR persists in
    `Settings["wing_calibration"]` (native values or flat arrays).
  - *Player scene:* `LeftHand`/`RightHand` use `pose = &"grip"`; new
    `LeftAim`/`RightAim` (`pose = &"aim"`, the UI laser source) and
    `WingAnchors/L`, `WingAnchors/R` under `XROrigin3D`. All
    PROCESS_MODE_ALWAYS with the origin.
  - *PlayerBird (additive):* `model: FlightModel`, `wing_input: WingInput`
    (`.calibration`, `begin_calibration(kind)`, `calibration_status()`),
    `wing_state() -> WingState`, `set_pose_source(src)`,
    `start_flying(pos, yaw, pitch = 0)`, `perch_on(perch)`, `mode`
    (SPAWNING/FLYING/PERCHED/GROUNDED/STUNNED/CAUGHT) and `mode_name()`,
    `get_view_direction()` (gaze; `get_forward()` is the beak heading with
    body pitch), `rig_yaw_rate`, `yaw_flagged` (a deliberate view snap this
    tick: spawn, recenter, perch), `contacts`, `tick(dt)` with
    `auto_process` (tests tick it directly), `log_interval`.
    `drive_world_scale` defaults to **false**: VR's WorldScaleDriver owns
    `XROrigin3D.world_scale` and the camera near plane; flight writes them
    only when a scene has no VR rig extras (flight's lab, flight tests).
  - *Telemetry extras* (contract keys unchanged): `mode`, `heading`,
    `rig_yaw`, `body_yaw`, `yaw_rate`, `rig_yaw_rate`, `sideslip`, `pitch`,
    `gamma`, `speed_ratio`, `stall_warning`, `pitch_input`, `roll_input`,
    `flap_l/r`, `up_l/r`, `extension_l/r`, `twist_l/r`, `flap_force`,
    `flap_power`, `endurance`, `soar_lock`, `tracking`, `calibrated`,
    `perch_candidate`, `stun_left`, `world_scale`, `perceived_speed`,
    `heave_offset`, `wind_l_y`, `wind_r_y`, `size_x`, `species`,
    `body_steer_share`, `contacts`, `tick_ms`. `airspeed` is 0 while
    perched or grounded.
  - *Events:* no new signals. A ground landing emits `player_perched` with
    the ground point; `player_flapped(side, strength)` once per paired
    stroke.
  - *Settings keys read with fallbacks* (core: please add to `DEFAULTS`):
    `flight_assist` (1: 0 sim / 1 normal / 2 novice), `body_steer` (true),
    `heave_smoothing` (true), `perch_needs_grip` (false),
    `comfort_max_yaw_rate` (240, deg/s), `comfort_max_yaw_accel` (720,
    deg/s²), `invert_pitch` (false), `sweep_pitch` (true),
    `wrist_sensitivity` (1.0), `soar_lock` (true), `auto_trim` (true),
    `wing_calibration` ({}), and the existing `seated`.
  - *For AI (reuse):* `FlightModel.new(mass)`, `step(ws, env, dt)`, `lite`
    (one Heun step per tick, 13.6 µs median on the dev Mac),
    `FlightModel.envelope(mass)`, `FlightEnv`, `WingState.set_commands()`,
    and `FlightAutopilot` (commands for an NPC that flies the real physics).
- **2026-09-26, gameloop — values + additive (fix round 1)** (details in `docs/areas/GAMELOOP.md`, "Danger" and "Pacing"):
  - *SizeRules values/additions:* `GROWTH_GAIN` (new, 1.0: growth
    efficiency at sparrow size and below) and `GROWTH_SIZE_EXP` 0.4 → 0.22,
    tuned on whole simulated runs in the AI area's real sky (its Ecosystem in
    its AiTestWorld, as of this date) so a competent player reaches pigeon
    in 5-8 min and eagle in 20-30; `cruise_speed(mass)`
    (performance's cruise without the dictionary). `static var
    growth_gain/growth_size_exp` hold the values in effect (the pacing tool
    varies them; nothing else writes them). API otherwise unchanged.
  - *The player as prey (VR forgiveness, CatchRule):* an NPC's strike on the
    player needs the player inside a 40° cone (NPC-on-NPC 55°), a reach
    margin of 0.15 of the hunter's span (0.25) and does not count by body
    overlap alone (a sideways lunge landing on the player). Additive optional
    `prey_is_player` parameters on `contact_distance`, `cone_cos`,
    `contact_time`, `reach_margin`.
  - *GameLoop additions:* signal `escaped(predator)` (an attack run on the
    player missed and is past: the player gets `escape_grace_s` of
    protection); attack respites — after an attack is over (or shaken off,
    or a respawn) NPCs are told to leave the player alone for 20 s x body
    time (30 s before the AI capped its own hunting of the player): **meta
    `npc_ignore` is now also true during a respite**, not only while
    protected (the AI already honours it; the player stays catchable
    if it flies into a predator); `respite_left()`, `respawn_protection()`,
    `danger_assist` (0..1, rises with deaths, lengthens protection, grace
    and respites and narrows strikes on the player), `player_catchable`
    (tools only), exports `escape_grace_s`, `attack_respite_s`,
    `cue_horizon_exp`; static `GameLoop.assist_for(since, mass)`.
    `get_run_stats()` adds `escapes`, `danger_assist`.
  - *Threat cue (Events.threat_changed):* reads intent: a bird exposing a
    `target` property (NpcBird has one) that is hunting someone else, or
    nothing, counts at 0.35 of a bird hunting the player (**AI: keep
    `NpcBird.target` = the bird being hunted, null otherwise**); its
    time-to-contact horizon scales with body time (3.5 s x time_scale).
    Target cue: weighs how catchable prey is (near-equals rarely are) and
    height (prey below beats prey above); target and highlight ranges are at
    least 4 / 6 s of flight at the player's cruise (a sparrow's cue was empty
    at 45 wingspans in the AI's metric-radius sky).
  - *Refuges and the cues:* `static CatchRule.in_refuge(prey_pos, pred_span,
    refuges)` (the catch rule's refuge test), `GameLoop.is_sheltered(prey,
    pred_span)`, `ThreatWatch.refuges` (kept current by the loop). The
    target cue never points at prey sheltering in a refuge the player is too
    wide to enter (the AI's prey dive into hedges; a cue that kept pointing
    at one held a modelled player there for minutes). Highlights unchanged.
  - *Records* are JSON: `user://gameloop_records.json` (a corrupt file no
    longer makes the engine print an ERROR). A won run that is continued
    counts once.
  - *Pacing evidence and the AI:* the brief is asserted on runs in the AI
    area's real sky (`tests/shots/gameloop_pacing.tscn -- --live_ai`, a tool:
    the game-loop suite never runs AI code), stored with a hash of the AI
    code they ran (`scripts/game/data/live_ai_evidence.json`); the suite
    reports when the AI code has changed since. **AI: changes to the plan,
    spawning, hunting, fleeing or energy move the game's pacing and danger**;
    the game loop's evidence then needs a re-run (about 40 min, three
    sandboxes; docs/areas/GAMELOOP.md "Regenerating the evidence") and
    perhaps a re-tune of `GROWTH_GAIN` / `ATTACK_RESPITE_S`.
  - *For the AI area (found while mirroring it, not changed):* in the
    snapshot the game loop's mirror was taken from (before the AI's fix
    round 1), `npc_brain.gd _steer_flee` computed `closing` as
    `(tv - v).dot(-rel / d)` with `rel = prey - threat`, **negative while
    the threat approached**, so prey never held their escape line or jinked
    on an attack run, only after a pass. The AI's fix round 1 rewrote the
    flee (judged at the hunter's lead point); the mirror keeps the snapshot's
    behaviour (`scripts/game/sim/sim_brains.gd` says where) because its
    duel check is against the rates measured with it. Measured with
    `tests/shots/gameloop_ai_snapshot.tscn` after the AI's fix round 1: the
    AI hunts a non-evading mock player ~2 times a minute (3.6-4.2 before);
    calm birds carry energy ~0.7 (median; ~0.6 before).

- **2026-09-26, ui (fix round 3) — additive** (details in `docs/areas/UI.md`):
  - *Where the HUD notices are:* home is still +7..+20 deg, but the notice
    band (lesson card, tier-up and apex celebrations) now **steps aside**
    from the flight path (player `velocity`), the current target and a
    real threat: up to 16 deg higher or 30 deg to either side, never lower,
    at most 110 deg/s. Only if nothing in reach clears them does it fade
    (as in round 2), and a celebration then waits at most 3 s. The growth
    strip (-37..-43 deg) still fades when it covers one of them.
  - *Cues:* when the prey and threat chevrons point within 22 deg of each
    other, the threat chevron steps out to an outer ring (at most 33 deg
    from the view centre).
  - *Real threat:* `UIRoot.REAL_THREAT` (0.1) with `UIRoot.is_real_threat()`
    (`>=`) replaces `SEE_THROUGH_THREAT`: the danger tint and the HUD
    making way use the same test.
  - *UIPanel additions:* `set_band_offset(i, Vector2 deg)`, `band_offset`,
    `band_placement`, `level_direction`, `band_frame_pixel`, `band_mesh`;
    test hooks `note_draw_started()` / `clear_draw_started()`. A render
    request now stands until a draw has begun after it (it was cancelled
    after one frame even when that frame's draw was skipped).
  - *Settings:* the status messages are `SettingsScreen.STATUS_*`; the last
    lesson is now "Catch a smaller bird".

- **2026-09-26, birds (fix round 1) — values + additive, backwards compatible**
  (details in `docs/areas/BIRDS.md`):
  - *Highlight look (values):* 1 = edible is now blue-violet `#4020f0`,
    2 = danger magenta `#ff00c8` (were violet `#6b4cff` and orange-red
    `#ff4000`, which vanished against the village's red roofs). Both are
    measured far from every `Palette` colour; a far highlighted bird is drawn
    mostly self-lit in the hue, so it keeps its colour in sun and shade.
    `BirdModels.HIGHLIGHT_EDIBLE` / `HIGHLIGHT_DANGER` carry the new values
    (UI: use them if HUD cues should match the birds).
  - *Minimum highlighted size:* still at least 0.7 deg wide, and now also
    wide enough that the bird's body is ~0.13 deg thick
    (`BirdModels.min_highlight_angle(species)`, new): slim birds (moth,
    swallow, gull) are drawn up to ~2.3x wider than the 0.7 deg minimum
    (1.4-1.6 deg) when far and highlighted. Visual only; gameplay sizes are unchanged. Close up (wider
    than ~7 deg in view) the tint gives way to the plumage with a rim of the
    hue.
  - *Drawing:* a model joins the batch of the LOD it will be drawn with
    (spawned far = LOD2 at once), and LOD changes are drawn in the frame
    they happen (no blank frame). `get_lod()` is the drawn LOD.
  - *flap_phase:* the drawn phase follows the owner's beat in cycles per
    second, reading each owner step in the direction of its beat; a long
    frame is followed at once. Owners need not change anything.
  - *Perched look:* folded wings now lie along the back with the tips just
    over the tail (they drooped under it); feet are unchanged (0.16 x span
    below the origin).

- **2026-09-26, ai (fix round 1) — additive, plus plan values** (details in
  `docs/areas/AI.md`):
  - *Who threatens the player (plan values, gameloop's `EcosystemPlan`
    mirror should follow):* a "threat" is now a species that **would hunt**
    the player - it can eat it, the meal is worth it by
    `SizeRules.is_worthwhile` (the rule NPCs hunt by) and its hunt drive is
    >= 0.45 (`Ecosystem.would_hunt(species, mass, prey_mass)`, static). The
    plan keeps ~12 of them (keys `"<species>:hunter"`, solo, masses drawn in
    the part of the species band that qualifies), apex eagles when fewer
    than 6 qualify, plus ~4 "giants" (could eat the player, would not
    bother: a hawk and a sparrow) and the murmuration under
    `"starling:murm"`. `stats()["by_role"]` gains `giant`;
    `stats()["hunts_on_player"]` counts hunts started on the player.
    Measured pressure on a non-evading mock player: 1.2-4 hunt starts/min
    at every size (was ~0 at sparrow/starling size) - GameLoop's
    `ATTACK_BASE_PER_MIN` (0.15) was calibrated on the old plan.
  - *Player meta:* NPC brains keep `npc_chasers` (int) on the player: how
    many chase it now (at most 1 at a time); after a failed chase a hunter
    leaves the player alone for 40 s. `npc_ignore` is honoured as before.
  - *NpcBird additions:* `player_interest`, `player_range` (set by the
    Ecosystem for its threats), `digest` (s of digesting after a catch: no
    hunting), `agl()`, `heading_dir()`, `is_contact_target(p)`,
    `land_on(perch, snap := false)` (no snap by default: the body settles
    onto the perch facing at <= 10 rad/s), `lunges` (diagnostics).
  - *Ecosystem additions:* `focus_point()` (where life is centred: the
    player led by 6 s of its smoothed velocity), `spawn_distance(span)` /
    `spawn_visible(pos, span)` (the near distance is now per bird: 150
    wingspans, 40..`spawn_min` m - a moth may appear, out of view, from 40
    m; a pigeon or bigger from 70 m as before), exports `focus_lead_s`,
    `recycle_behind`, `recycle_behind_slow`.
- **2026-09-26, world (fix round 3) — values + additive, backwards compatible**
  (details in `docs/areas/WORLD.md`):
  - *Openings:* house vents now come in three sizes along the street (0.30 /
    0.40 / 0.52 m → `max_span` 0.78 / 1.04 / 1.35: a pigeon's, a crow's and
    a gull's refuge from the next size up); the farmhouse keeps 0.40 m. New
    `type` `owl_hole` (`barn_owl_hole`, 0.55 m in the barn's west end,
    `max_span` 1.43). Names of existing openings are unchanged.
  - *Perches (values):* the 13 cliff-shelf `LEDGE` perches are on solid
    shelf tops again and rated 2.1 m (round 3 had cut them to 1.785 inside
    inside-out boxes); the mast-top perch moved to the new top plate. New
    perches on the barn's hay-hoist beam and owl-hole sill. Perch validation
    now also requires the approach line to be flyable back out (a perch must
    be leavable); counts in `stats().perch_validation`.
  - *Nest boxes (values):* the 14 `nest_box_*` openings, refuges and perches
    keep their names and ratings; positions and normals changed (each box
    sits on a flat face of its trunk or pole on a batten; the two pole boxes
    are on real poles). They are placed after all kits are committed.
  - *MeshKit:* mirrored frames (a left-handed basis passed to
    `box`/`prism`/`wall`, or a mirrored `xf`) no longer produce inside-out
    geometry; `prism()` takes optional per-edge colours. Removed unused
    helpers `MeshKit.displace_plane`, `ico_faces`, `add_box`, `add_sphere`,
    `add_convex` and `Palette.soft_material` (no callers anywhere in the
    tree). `Palette.LIGHT` presets gain a `motes` colour.
  - *Tools:* `tests/shots/world_perf.tscn` exits 1 when over budget;
    `tests/shots/world_hlod_check.tscn` exits 1 when a wrong level is drawn.
- **2026-09-26, vr (fix round 2) — behaviour + additive, backwards compatible**
  (details in `docs/areas/VR.md` §10):
  - *Calibration ownership:* while `scenes/vr/vr_rig_extras.tscn` runs,
    VR's `VRCalibration` sets the PlayerBird's `auto_calibrate` to false
    (duck-typed; restored when it leaves the tree) and makes the one
    automatic capture. Reason: on the composed rig flight's WingInput
    capture (FLIGHT_SPEC §5.10 as written) finished first whenever
    tracking was steady, and its arms-5°-low drop and as-held neutral made
    a half fold read 0.09-0.61 depending on the capture pose. A capture
    flight still makes (`begin_calibration`, or one taken before the
    extras attached) is adopted, refined to VR's maths
    (`WingCalibrator.adopt` / `refine_foreign`) and written back into
    flight's `wing_input.calibration`; VR's calibration is also pushed to
    any PlayerBird whose resource reads uncalibrated. Scenes without the
    extras keep flight's own capture. Nothing for flight to change.
  - *WingCalibration.arm_span as VR writes it:* the full spread (shoulder
    width + 2 x the shoulder-to-grip distance, fitted with the width), not
    the grip distance as held; same §5.11 meaning ("grip-to-grip at full
    spread"). Static helper `WingCalibrator.fit_body(...)` (pure).
  - *Seated:* an adopted capture's `seated` never turns the Settings
    preference into "detected" (flight's loader ORs the two).
  - *Vignette:* the acceleration term is the mean over one stroke period,
    read from `PlayerBird.wing_state().stroke_period` (duck-typed; 0.8 s
    without it), then a 0.5 s box; flow rays are cast one per tick.
  - *Controls:* the B long-press pause is PLAYING/CAUGHT only (BOOT
    dropped, as documented).
  - *First-person wings:* a folding wing turns towards level, upper side
    up (0.8 of the way at extension 0); feather-group palette columns are
    shader uniforms (`FirstPersonWings.GROUP_COLUMNS`).
  - *VR-internal API trimmed (no callers outside VR):*
    `VRManager.choose_refresh_rate(available, requested)` (the `android`
    parameter is gone; `REFRESH_AUTO` 72 replaces `REFRESH_ANDROID` /
    `REFRESH_DESKTOP`), `XRMirror.get_mirror_viewport()`,
    `FirstPersonWings.hand_valid` / `feather_group()` / `palette_color()`
    removed. Additive: an optional `store` (Settings-like source) on
    `ComfortVignette`, `VRHaptics`, `WorldScaleDriver`;
    `VRPosePuppet.torso_yaw_offset`; `VRCalibration.own_auto_capture`,
    `claim_auto_capture()`.
- **2026-09-26, audio (fix round 2) — additive, one default changed**
  (details in `docs/areas/AUDIO.md` › Fix round 2):
  - *`AudioDirector.play_ui(kind, volume_db = NAN)`:* without a
    `volume_db` each UI sound now plays at its own measured level
    (`AudioDirector.UI_LEVEL`, click -2 ... confirm -19 dB) instead of one
    -4 dB for all; passing a level still overrides. Callers need no change.
  - *`debug_snapshot()`* gains `amb_speed_duck_db`.
  - *What audio reads:* NpcBird `target` (already in the NpcBird contract)
    decides whether a stooping raptor's scream is aimed at the player.
  - *Mix, no API change:* the ambience and NPC calls are ducked by flight
    speed; the church bell is levelled and follows the player's
    world_scale; the director survives being re-parented and resets the
    shared `Calls` bus when it leaves.
- **2026-09-26, birds (fix round 2) — behaviour + additive, backwards
  compatible** (details in `docs/areas/BIRDS.md` › Fix round 2):
  - *Highlighted birds are drawn at their true size* (the fix-round-1
    minimum drawn size, 0.7-1.6 deg, is gone: it drew prey larger than the
    player and stopped a chased bird looming). Far readability now comes
    from a **highlight marker** the bird shader draws around a far
    highlighted bird, facing the camera at a fixed angular size (0.64 deg
    across): a thin **ring** for edible, a **warning triangle** for danger
    (the shape is the colour-blind cue), in `BirdModels.HIGHLIGHT_*`. It
    thins away once the bird itself reads (its wingspan over
    `BirdModels.min_highlight_angle(species)`, which now means "the angle
    from which the bird reads by itself"). No API change for owners.
  - *Close up*, pale plumage under the tint is dyed towards the hue (a gull
    no longer turns pastel); the unlit glow gives way to the rim.
  - *Perched and dive-tucked wings* lie on the back and flanks and follow
    the body onto the rump (fold "hug", baked into each mesh's UV2); a
    bird's body now ends in a blunt rump as wide as its tail's base.
    Perch contract unchanged (feet 0.16 x span below the origin).
  - *BirdModel:* a field set to NaN/INF for a frame is ignored (the last
    good value stays); a model scaled to 0 draws nothing, with finite
    numbers.
  - *Wording:* a BirdModel has no child nodes **of its own**;
    `BirdFX.attach_trails(model)` adds a `WingTrails` child on request.
  - *Mesh data (birds-internal, for anyone reading the arrays):* wing
    vertices carry the fold hug in UV2; LOD1/LOD2 meshes also hold the
    22-triangle marker (group 6, collapsed at the origin unless drawn);
    `BirdMeshBuilder.marker_triangles(lod)`.
- **2026-09-26, vr (fix round 3) — behaviour + one request to flight, backwards compatible**
  (details in `docs/areas/VR.md` §11):
  - *Correction to "vr (fix round 2)":* "Nothing for flight to change" was
    not quite true. After VR replaces the neutral wrist bases (its
    automatic capture or the manual recalibration), flight's WingInput
    keeps its neutral-twist auto-trim (`_trim`, up to ±10°, τ 60 s), which
    was learnt against the old neutral: flat wrists then read up to ~6° of
    twist for a minute. **Request to flight (additive):** a public
    `WingInput.calibration_replaced()` that clears whatever is relative to
    the old neutral (the trim; the twist filters if you like). VR calls it
    (duck-typed) right after writing a new neutral. Until it exists, VR
    zeroes `wing_input._trim` in place (duck-typed, guarded by `in`; it
    touches nothing else), exactly as flight's own `_capture_neutral` does.
  - *Calibration (behaviour):* a capture flight makes **after** VR has
    calibrated (its `begin_calibration`) is now also adopted and refined
    (`VRCalibration.foreign_capture(res)`: flight's `neutral_left/right`
    differ from VR's by > 1e-3 rad), written back and persisted; round 2
    adopted only while VR had none. VR's refinements (span growth, seated
    detected or cleared) now reach flight's resource the moment they
    happen, not at the next `player_spawned`. Seated detection is also
    relative to the stature the calibrated span implies (eyes below
    0.75 x (span + 0.16) m, standing again above 0.80 x; the absolute
    1.30 / 1.40 m still apply) and is decided at the capture itself, so tall
    seated players (span >= 1.8 m, eyes 1.32-1.41 m) are seated.
  - *Vignette (behaviour):* the acceleration term (flight_vr.md §11.4,
    unchanged thresholds 6 -> 20 m/s² perceived) now counts only with a
    surface within 8 body spans (left, right or below: the flow rays), in
    full within 3 (`ComfortVignette.accel_proximity`; `VignetteModel.
    target_for/update` take an optional `proximity`, default 1). Reason:
    §11.4's own "straight, fast flight in open sky keeps the full view" —
    flight's real flap bursts at altitude narrowed a sparrow's view for
    30-86 % of ordinary flap/glide flight.
  - *Haptics (behaviour):* the 30 % duty cap is shared out: the continuous
    rhythms (stall, updraft, danger) together <= 15 %, of which the danger
    heartbeat's 8 % is kept free so its rate (the threat's distance)
    holds, while the buffet and the throb slow down together in the rest;
    routine pulses (flap, ticks) <= 21 %; catch / collision / caught up to
    30 %. Continuous beats never cut into another pulse; a discrete pulse
    blocked by the 40 ms rule waits up to 60 ms instead of being dropped.
    The stall buffet is 15 ms every 100-150 ms (was 20 ms every 70-110 ms,
    22 % on its own; flight_vr.md §13's 50-90 ms would be 28 %); the
    heartbeat is flight_vr.md §13's 2 x 20 ms (was 2 x 30 ms).
  - *world_scale:* non-finite `world_scale_exponent`, masses or spans are
    rejected (exponent 1.0, no player, default span); world_scale and the
    near plane are never NaN.
  - *First-person wings:* the fold-to-level turn is continuous (its weight
    fades to 0 near a vertical forearm and a palm-up hand instead of a hard
    gate that flipped a folded wing 50-80° for a 1° wrist change), and a
    folding wing's hand frame swings towards the arm's line so the wing
    closes along the arm; `FirstPersonWings.fold_level_turn(o, n, e)` and
    `fold_align_turn(o, a, e)` (static, pure). A spread wing still follows
    the controller exactly.
  - *Removed (VR-internal, no callers outside VR):*
    `WingCalibrator.pitch_norm()`, `VRMath.basis_to_array()`,
    `VRMath.vec_to_array()`. `WorldScaleDriver.TIP_ALLOWANCE` is now
    derived from `FirstPersonWings.TIP_OVERHANG` (same value, 0.20 m).
- **2026-09-26, flight (fix round 1) — additive + behaviour, backwards compatible**
  (details in `docs/areas/FLIGHT.md` §2 and §7, `docs/areas/FLIGHT_SPEC.md` §19 "Fix round 1"):
  - *VR's request (vr fix round 3), done:* `WingInput.calibration_replaced()`
    clears the neutral-twist auto-trim, the twist filters and held twists.
    Call it right after writing a new neutral; the `_trim` poke is no longer
    needed (it stays harmless).
  - *WingInput (additive):* `trust_next()` (the next poses are accepted as
    they come: PlayerBird calls it on unpause, recenter and discontinuity
    frames) and `static pose_sane(tr)`. *Behaviour:* tracker sanity is now
    continuity with the last ACCEPTED pose (0.15 m + 3 m/s head, 5 m/s hands
    × the time since); a consistent offset held 0.25 s is a re-localization
    (accepted, stroke detectors restart); head and both hands moving by the
    same vector is a body translation (accepted at once); a hand gap of up
    to 0.1 s is bridged with its own motion (one bad frame no longer
    forfeits a stroke). `head` / `hands` are the validated poses.
  - *PlayerBird (additive):* `record_poses`, `record_path`, `recorder`
    (`PoseRecorder`): JSON-lines pose sessions for replay tests; also on
    with the Settings key **`record_poses`** (false; core: please add to
    `DEFAULTS`) or the command line `--record-poses[=<path>]`.
    `PoseRecorder.record(frame, dt)` (was `record(frame)`, flight-internal
    callers only); `ReplayPoseSource` is tick-aligned.
  - *PlayerBird (behaviour):* head tracking lost for 1 s emits
    `Events.menu_requested` once per loss (the menu button's route; a scene
    with no UI is paused directly, never resumed); synthetic sources write
    WingInput's validated poses into the XR nodes; the rig reads the
    validated head; `tick(dt)` clamps dt to 0.1 s; perched / grounded
    telemetry reports a still bird (`aoa` 0, `g_load` 1, `lift`, `drag`,
    `flap_force`, `flap_power`, `sideslip`, `gamma` 0, `stalled` false,
    `stall_warning` 0) and the body eases level; the perch capture is a
    smooth deceleration to the grip (no one-tick stop). Camera heave is
    redesigned (the offset is only the removed wingbeat; see FLIGHT.md §2)
    and `FlightTuning.heave_clamp_spans` now means spans (default 1.5; the
    old 0.5 was applied as 1 span). `heave_offset` telemetry is unchanged
    (camera y − body y).
  - *FlightModel (additive):* `lift_coefficient(alpha, separation)` (pure
    read of the lift curve). *Behaviour:* `trim_solution()` / `trim()` use
    the attached-flow polar whatever the live stall state; the body's pitch
    never turns faster than its pitch rate (no 180° flip at the top of a
    vertical zoom; NPC visuals reusing the model no longer tumble).
- **2026-09-26, audio (fix round 3) — additive, mix changes, no API change**
  (details in `docs/areas/AUDIO.md` › Fix round 3):
  - *`debug_snapshot()`* gains `cue_duck_db` (the reward/failure cue duck
    now applied to the Calls and Ambience buses too).
  - *Mix, no API change:*
    - every `AudioStreamPlayer3D` the director owns sets its own
      air-absorption shelf (`attenuation_filter_db`) instead of Godot's
      default, whose depth follows `volume_db`. Calls and the bell get
      a distance-driven shelf; the wingbeat whooshes get none.
    - A catch ducks the flight layers deeper in a fast dive.
    - The NPC calls' crowd gain follows their summed gain at the listener.
    - The cruise wind is 2 dB louder and the ambience speed duck starts
      at 0.55x.
    - The menu music is 2 dB lower and the UI sounds follow it (the
      `UI_LEVEL` defaults are 2 dB lower; `play_ui(kind, volume_db)` still
      overrides).
    - Wingbeats are 3 dB lower and the tension drone rises earlier.
  - Other areas need no change. `play_ui` callers get the new defaults
    automatically.
- **2026-09-26, birds (fix round 3) — behaviour, backwards compatible; no
  API change for owners** (details in `docs/areas/BIRDS.md` › Fix round 3):
  - *Highlight look:* the marker (ring = edible, warning triangle = danger,
    in `BirdModels.HIGHLIGHT_*`) is now drawn around **every** highlighted
    bird at every distance and LOD (it no longer fades), just outside the
    wingtips once the bird is bigger than the far marker. A highlighted bird
    big enough to show its plumage (from 1.8 x
    `BirdModels.min_highlight_angle(species)`, at most 2.9 deg) keeps
    exactly its own colours (the tint had erased species identity in play);
    only a smaller one is tinted in the hue. The round-2 close-up dye and
    rim are gone. `highlight` values and meanings are unchanged.
  - *Rendering (birds-internal):* the marker is its own mesh
    (`BirdModels.marker_mesh()`, 70 triangles), drawn by one extra
    MultiMesh per world and render layers that holds only the highlighted
    birds (no shadow, not culled): +1 draw call while any bird is
    highlighted. Bird meshes no longer carry marker geometry
    (`BirdMeshBuilder.marker_triangles()` takes no LOD any more). Every
    bird vertex carries its species' readable angle in COLOR.a.
  - *Looks:* folded hands narrow to the tip and folded primaries stack
    (crow/hawk/eagle); the eagle's head and bill are bigger, the hawk's
    chest deeper. Perch contract unchanged (feet 0.16 x span below the
    origin).
  - *Timing:* the first model of a species builds all three LOD meshes
    when it is attached (~8 ms on an M1), so no mesh is built inside the
    frame's sync; `BirdModels.prewarm()` behind a loading screen still
    avoids even that (74 ms for all). `WingTrails` keeps its 12-trail
    budget when many start at once; trails the budget cuts fade out
    within ~0.1 s.
- **2026-09-26, flight (fix round 2) — behaviour fixes, additive, backwards
  compatible** (details in `docs/areas/FLIGHT.md` §2 and §8,
  `docs/areas/FLIGHT_SPEC.md` §19 "Fix round 2"):
  - *Bird lifecycle (fix):* `PlayerBird._exit_tree` now calls `super()`, so
    the player is unregistered from `Birds` (and `Events.bird_removed` is
    emitted) when it leaves the tree. Before, a freed player stayed in
    `Birds.all()` and `Birds.nearby(exclude = …)` hit a freed instance.
    AI / gameloop / audio need no change; anything that worked around a
    stale player entry can drop the workaround.
  - *Camera heave (behaviour):* the heave offset is non-zero only during a
    steady flapping rhythm (it opens after three regular strokes and eases
    in); flap-glide bursts, isolated strokes and irregular flapping leave
    the camera on the body. `heave_offset` telemetry and the
    `heave_smoothing` setting are unchanged. `HeaveSmoother.update()`
    takes an optional `arm_rate` (flight-internal).
  - *Stun (behaviour):* a stun off a wall turns the bird (a smooth yaw
    within the comfort caps, which the rig follows) to the reflection of
    its heading off the wall. `player_collided` is unchanged.
  - *WingInput (behaviour + additive):* wrist twist reversing faster than
    ~3 Hz no longer reaches the pitch command (its mean does);
    `pitch_jitter` (0..1, diagnostics). Step latency unchanged (90 ms).
  - *FlightModel (behaviour):* `flap_impulse` accumulates the impulse the
    integrator applied (both Heun stages); round 1 summed the first stage.
  - *Course (values):* `FlightCourse`'s window wall is 60 spans (≥ 40 m)
    wide (was 24 spans, ≥ 12 m). The opening and the rest of the course are
    unchanged.
- **2026-09-26, flight (fix round 3) — behaviour fixes, additive, backwards
  compatible** (details in `docs/areas/FLIGHT.md` §2 and §8,
  `docs/areas/FLIGHT_SPEC.md` §19 "Fix round 3"):
  - *Rig yaw (behaviour):* heading changes the comfort caps cannot follow in
    one tick (a bounce or slide off a wall, a slow bird's heading catching up)
    are no longer dropped. They are owed to the view and paid along one
    minimum-jerk rotation inside 120°/s and 240°/s² (`ViewTurn`, flight-internal),
    and body steer steers against where the view is heading. The comfort caps
    (240°/s, 720°/s²) and the rig's yaw-only contract are unchanged.
  - *Stun (behaviour, supersedes round 2's):* a stun off a wall turns the bird
    the short way until it leaves the wall at 20° to its plane (incidence + 20°;
    110° head-on, was 180°). The view follows smoothly. A floor stun bounces
    0.05 of the impact speed (was 0.25). `player_collided` is unchanged.
  - *Teleports (fix):* `respawn()`, `start_flying()` and `perch_on()` start the
    view (and the perching logic) at rest. Before, the previous flight's rig yaw rate carried into the
    spawn: after the pause menu's "Restart run" taken mid-turn the view turned
    28° with no heading change. GameLoop needs no change.
  - *Perching (behaviour):* the assist acquires a perch ahead of the bird's air
    or ground path and holds it until passed; it corrects the wind's drift on
    its own budget; its brake plans with the ground speed. The capture judges
    `min(airspeed, ground speed)` against 0.8 V_min, so landing into the wind
    is easier, as for real birds. In still air the only change is that the
    brake also cancels the speed a dive onto the branch adds.
  - *Wind (behaviour):* a change of the horizontal wind turns the bird's
    heading through its sideslip (weathercock) instead of in one tick.
  - *World lookup (fix):* `PlayerBird` looks for the World again while it has
    none, so a World added or regenerated after the player is found (§3).
  - *Telemetry (additive):* `view_turn` (rad still owed to the view) and
    `view_turn_rate` (rad/s): a forced view turn the VR vignette may cover.
    Contract keys unchanged.
  - *FlightModel API (additive):* `apply_contact(normal, kind, restitution := 0.25)`,
    `redirect(heading)`, `take_heading_step()`, `last_accel()`, and a
    `heading_step` field. Removed: the unused `mean_flap_effort()` and
    `last_forces()` (no caller in any area). Also removed, unused anywhere:
    `PoseFrame.hand_valid()`, `PoseRecorder.is_recording()`,
    `WingCalibration.reset_defaults()`.
  - *Player scene (value):* `XRCamera3D.near` is 0.03 (was 0.01): §7.5's range at
    world_scale 1, for scenes without the VR area's WorldScaleDriver.
- **2026-09-26, ai (fix round 2) — behaviour and plan values, additive,
  backwards compatible** (details in `docs/areas/AI.md`, "Fix round 2"):
  - *Population (behaviour):* the Ecosystem no longer recycles birds round a
    player that circles an area (laps, thermals, a dogfight): "left behind"
    applies only while the player travels (covers ground without turning
    more than 60 deg over its last 12 s), never to a bird in its first
    12 s, mid-chase, mid-flight, hiding or in a flock still in sight.
    Measured turnover round a lapping player: ~0.1-0.2 of the population a
    minute (was 2-4). Home ranges, the threats' patrol and spawn distances
    scale with the player's sky (`sky_radius()`: 1.25 x max(70 spans, 6 s
    of cruise), 60..110 m). Despawn reasons in `stats()["despawned"]` and
    `npc_despawned`: `caught`, `reset`, `surplus`, `outgrown`, `far`,
    `behind` (new), `prey_far` (new: the farthest idle prey recycled when
    none worth catching is within 120 m of the player).
  - *Plan values (GameLoop's `EcosystemPlan` mirror should follow):*
    `N_THREATS` 12 -> 9 (birds that would hunt the player), `N_GIANTS`
    4 -> 8 (big birds that would not bother - the small player's view).
    Hunts started on a non-evading mock player: ~1.5-5.9 a minute per size
    tier (growth run), 0.9-3.4 travelling [numbers corrected in round 3:
    the note first said 1-4.3 and 1.7-4.3, measured before the round's last
    changes]; the rest of the pressure rules (one chaser at a time, 40 s
    cool-down) are unchanged.
  - *Behaviour GameLoop's sim mirror (`scripts/game/sim/sim_brains.gd`)
    should know about:* hiding is bounded (a 2-4 s breather, out after a
    quiet second, never more than 12-20 s); a predator hunting another bird
    flushes prey only when flying at it (within ~37 deg, closing); a bird on
    a perch or landing on one is flushed by the player only when the player
    comes at it (flying birds still scatter from any approaching player);
    after a failed or interrupted chase a hunter rests 6-14 s x
    sqrt(`SizeRules.time_scale`); chases last at most 30-52 s by meal size
    (and a near-equal "stamina race" may run past its budget while the prey
    is flagging); managed hunters give up a chase 3 home ranges (>= 220 m)
    from home. Species values changed: gull awareness 48 -> 40 m, crow
    awareness 45 -> 48 m and jink 0.55 -> 0.65, swallow jink 0.85 -> 0.8,
    moth awareness 9 -> 11 m and jink 0.85 -> 0.9, wren jink 0.85 -> 0.95,
    pigeon jink 0.72 -> 0.76, gull hunt_timeout 14 -> 11 s, starling
    hunt_timeout 16 -> 20 s. The duel rates (A2) are in AI.md.
  - *NpcBird (additive + contract compliance):* a perched body now sits one
    body radius above `Perch.position` (was 0.8 r: the feet sank 20% of a
    radius into the perch); `model.snap()` is called after a spawn or a
    snapped landing; counters `geo_hits`, `ground_hits`, `bounds_hits`
    (contacts the safety net resolved). Leaving the tree any way releases
    the bird's target (the player's `npc_chasers` count can no longer leak
    when the Ecosystem is freed mid-chase).
  - *Ecosystem (additive):* `sky_radius()`, `travelling()`, `drift()`,
    static `spawn_order(keys)` (plan keys are spawned in text order - a
    seed no longer depends on what ran before in the process), exports
    `travel_drift`, `recycle_grace_s`; the shared `Habitat` is refreshed
    when an Ecosystem starts.
  - *World data (fix):* the AI's `Habitat` works on copies of
    `World.get_refuges()`; it no longer writes an `entry` key into the
    world's own dictionaries.
  - *Later in the same round (additive):* `NpcBird.set_contact_target(p,
    radius, body_contact := true)` - with `false` the feelers let the bird
    close in but its body still collides (hunters going for a perched or
    hidden bird now always collide; the landing exemption is about a body
    radius, not 20 cm); a kinematic flare cancels itself if its next step
    would run the body into geometry; `Habitat.indoors(pos)`,
    `Habitat.roofed_in(pos)`, `NpcFlight.climb_gradient(v, effort)`.
    Behaviour GameLoop may notice: a bird sitting on a perch or landing is
    flushed by an NPC hunter only when it is on the line to that hunter's
    quarry; the Ecosystem also keeps one visible worthwhile prey within
    75 m of the player (recycling a long-lived far one out of view).
- **2026-09-26, gameloop (fix round 2) — behaviour + values + additive, backwards compatible**
  (details in `docs/areas/GAMELOOP.md`, "Review findings (fix round 2)"):
  - *Cover is out of play (catch rule, behaviour):* a bird whose `hidden`
    property is true (NpcBird sitting in a refuge) can neither be caught
    nor catch, is never a threat (`Events.threat_changed`) and never the
    target cue (its highlight still says what it is). Before, any bird that
    fitted a refuge could take a sitting bird out of it: in the valley two
    thirds of a modelled player's catches were birds sitting in house rooms
    and nest boxes. New static `CatchRule.is_hidden(b)`;
    `GameLoop.is_sheltered()` includes it. **AI:** nothing to change - your
    hunters never start a hunt on a hidden bird; one that followed its prey
    into cover now waits for it to come out (your hiding is bounded).
  - *The ratio holds at the moment of the catch (behaviour):* a frame's
    contacts are applied in contact order and each re-checks `EAT_RATIO`
    with the masses of that moment (a player that just ate is not eaten by
    a now-smaller bird later in the same frame).
  - *Catch assist (values):* reach +125% at full assist (was +100%), cone
    +10 deg capped at 90 deg (was +15 deg, i.e. 95 deg: prey behind the wing
    line). Swept contact is now exact (the first moment within reach and
    inside the cone, solved from the roots; it sampled three moments).
  - *Refuges (additive):* `RefugeIndex` (scripts/game/refuge_index.gd), a
    column grid of `World.get_refuges()`; `ThreatWatch.refuge_index` is
    built when `ThreatWatch.refuges` is assigned. The threat/target pass
    with the valley's 296 refuges is back under 0.3 ms.
  - *Target cue (value):* minimum hold 1.5 s (was 0.6 s).
  - *Records (behaviour, additive):* saved mid-run at every new peak tier,
    on `GameLoop.pause()` / `Game.PAUSED`, and on
    `NOTIFICATION_APPLICATION_PAUSED`, `..._FOCUS_OUT`, `WM_CLOSE_REQUEST`
    and when the loop leaves the tree - without counting a run (a run still
    counts once, when it ends). `summary.new_records` is judged against the
    bests at the run's start (static `RunRecords.broken(before, summary)`).
    UI: nothing to change.
  - *Growth and danger (values):* `SizeRules.GROWTH_GAIN` 1.0 -> 1.55,
    `GROWTH_SIZE_EXP` 0.22 -> 0.05, `GameLoop.ATTACK_RESPITE_S` 20 -> 12 s
    x body time - tuned on whole runs in the shipped valley (below), where
    cover protects and the player cannot fly through houses, so catches are
    rarer and each counts for more.
  - *Apex goal (value):* `GameLoop.APEX_CATCHES` 5 -> 3 worthwhile catches
    as the eagle (UI reads `needed` from `apex_progress` / `get_run_stats()`;
    its dev mock still says 5).
  - *Statistical pacing model (additive):* `PacingModel`
    (scripts/game/sim/pacing_model.gd), and IntegratedSim logs what it is
    fitted from; test-only.
  - *Pacing evidence (process):* the brief is now asserted on runs in the
    world area's shipped valley (`SoaringWorld`) with the AI's Ecosystem,
    the modelled player colliding with the valley and steering round it,
    on held-out seeds too. `pacing_test` **fails** when the AI code
    (`scripts/ai`, `scenes/ai/ecosystem.tscn`) or the valley code
    (`scripts/world` minus paint-only files, `scenes/world/world.tscn`)
    differs from what the evidence ran (comment-only edits do not count).
    **AI / world: a behaviour change there means re-running the game loop's
    evidence** (about an hour, docs/areas/GAMELOOP.md "Regenerating the
    evidence"); **integration: run the game suite after the last AI/world
    change.**
- **2026-09-26, audio (fix round 4) — additive, behaviour fixes, backwards
  compatible** (details in `docs/areas/AUDIO.md` › Fix round 4):
  - *Bad input (behaviour):* every number audio takes from other areas
    (telemetry keys, `threat_changed` level, `player_flapped` strength,
    `player_collided` impact, prey and player masses, `play_ui` levels,
    camera/hand/bird/landmark positions, `World.ground_height`, Settings
    volumes) is sanitised at the boundary: NaN/INF take a safe default (a
    NaN airspeed falls back to `Bird.velocity`), absurd values are clamped;
    a `threat_changed` whose level is not a finite number is ignored.
    Nothing changes for well-formed input. (A single NaN `wing_extension`
    used to silence the wind for the rest of the session; flight's
    telemetry still builds `wing_extension` from the raw WingState, so
    flight may want to send its sanitised copy too, but audio no longer
    depends on it.)
  - *`AudioDirector.settings: Object` (additive):* where the volume sliders
    are read from, anything with `get_value(key, fallback)`; null (the
    default) = the Settings autoload. Tests pass an in-memory store and no
    longer write `user://settings.cfg`. `AudioBuses.setting_value(bus,
    store = null)` likewise; a non-finite stored volume reads as its
    shipped default.
  - *`perf_stats()`* gains `p25`.
  - *Mix (behaviour, no API change):* the call of the predator threatening
    the player starts louder as it closes in (the urgent floor rises 1.5 dB
    per halving of the distance from -6 dB at 400 perceived m), and its
    voice is not ducked by flight speed (headroom stays with the crowd
    rule). Other calls, levels and ducks are unchanged.
  - *Audio-internal:* new `AudioInput` (scripts/audio/audio_input.gd),
    `FlightSoundMap.clean_telemetry()`, `FlightSoundMap.MAX_RATIO`,
    `FlightSoundMap.compute(..., fallback_speed)`,
    `CallVoices.threat_floor_db()`, `THREAT_FLOOR_FAR`,
    `THREAT_FLOOR_RISE_DB`.
  - *Correction to "audio (fix round 3)":* only the `select`, `open`,
    `close`, `back` and `confirm` UI levels moved 2 dB lower; `click` and
    `hover` stayed at -2 dB (they were already as loud as their peaks
    allow).

- **2026-09-26, vr (fix round 4) — behaviour, backwards compatible**
  (details in `docs/areas/VR.md` §12):
  - *`VR.focused` (meaning refined):* true only while the session has
    input focus **and** the headset is worn. `user_presence_changed(false)`
    clears it at once (it stayed true until the runtime also sent
    `session_visible`); that removal counts as one focus loss (one
    `menu_requested`, one `session_unfocused`, even when `session_visible`
    follows). Putting the headset back on with the session still focused
    sets it again and emits `session_focused`; the game stays paused.
  - *Comfort vignette (behaviour):* self-motion only. The optic-flow term
    of flight_vr.md §11.4 / FLIGHT_SPEC C9 is removed (it pulsed the ring
    about once a second in steady flight over the orchard and the forest);
    strength = setting x max(yaw term, 0.5 x acceleration term x
    proximity), thresholds unchanged. Proximity is now slow (nearest probe
    hit held 1.5 s, low-passed with τ 1 s). Steady straight flight keeps
    the full view everywhere, near surfaces too. `VignetteModel.target_for`
    / `update` lose their `flow` parameter (VR-internal: no callers outside
    VR) and `ComfortVignette.flow` is deprecated (always 0). Flight: nothing to change;
    `view_turn_rate` still reaches the vignette as rig yaw.
  - *Calibration (behaviour):* the arm span grows only from genuine
    spread-arms poses while the game is played (not paused, not in a menu,
    headset focused and worn): 2 separate spreads, each
    its 80th-percentile sample, +0.10 m per session at most, reset by a
    manual recalibration. Seated thresholds are bounded by the standing
    eye height measured at the capture (new key `standing_eye` in
    `Settings["wing_calibration"]`, VR's own: flight's `from_dict` ignores
    it). A saved dict with a corrupt neutral / axis is rejected whole
    (defaults, uncalibrated, the automatic capture runs again) and never
    written into flight's WingCalibration. VR no longer touches
    `WingInput._trim` (it only calls `calibration_replaced()`); VR no
    longer writes the removed `neutral_roll_*` fields.
  - *VR re-asserts its span on flight's resource:* flight's WingInput
    still refines `arm_span` by the round-3 rule (any grip distance 5 cm
    wider for 0.5 s) even while VR owns the calibration
    (`auto_calibrate` false), so a controller on a table still inflated
    what flight flew. While VR is calibrated it now writes its span and
    shoulder width back whenever flight's differ (every VR tick).
  - *Requests to flight (not blocking):* skip WingInput's continuous span
    refinement while `auto_calibrate` is false (VR's extras run): between
    flight's tick and VR's, flight's copy is still wrong for that tick
    while a controller lies on a table; and `WingCalibration.from_dict`
    accepts a native `Basis` without the finite / determinant check its
    flat-array path has (VR rejects such a dict and overwrites flight's
    copy at VR's next capture).
- **2026-09-26, flight (fix round 4) — behaviour fixes, additive, backwards
  compatible** (details in `docs/areas/FLIGHT.md` §2 and §8,
  `docs/areas/FLIGHT_SPEC.md` §19 "Fix round 4"):
  - *Correction to "flight (fix round 3)", rig yaw:* the owed view turn was
    not "one minimum-jerk rotation" in every case. When a re-plan found no
    quintic inside the limits, the view spun at the 240°/s cap for tens of
    seconds (a stun that ended on the floor). `ViewTurn` is now a
    time-optimal (bang-bang) follower: it accelerates at 240°/s² up to
    120°/s and brakes on the exact discrete stopping curve, landing on the
    target. There is no search and no failure branch. Both caps hold on
    every tick, and the rate and acceleration stay under the comfort caps
    (240°/s, 720°/s²) with margin. The acceleration now steps (the only
    jerk is at those switch points). The view overshoots only when a new
    owe the other way cuts a debt short mid-payout, and then by the
    unavoidable braking distance. `settle()` is removed (flight-internal).
    Perched or grounded, the rig brakes to rest at the comfort caps and any
    owed turn is dropped; the bird is not turning. Telemetry `view_turn` /
    `view_turn_rate` are unchanged.
  - *Stun (behaviour, supersedes round 3's):* a contact deflects the
    velocity and turns the body as little as it can, never more than 40°
    (`FlightTuning.contact_turn_max_deg`). A stun off a wall turns toward
    leaving at 20° to its plane, the short way, capped at 40° (round 3:
    incidence + 20°, 110° head-on); the player turns the rest. A grazing sweep hit that returns no contact normal no longer
    guesses one (that gave bogus floor stuns): the bird stops at the safe
    point. `player_collided` is unchanged.
  - *Perching (behaviour):* a perch is a rest state. Arms at the sides or
    folded never drop the bird off it; round 1's "drop-launch: tuck while
    perched" is removed. Leaving a perch takes a completed downstroke: a
    credited onset, then the wing back out within 0.8 s. Fidgeting does not
    launch. Taking off from the ground is unchanged (a flap onset).
    `telemetry()["tucked"]` is false while perched or grounded: tuck means
    a dive, and only in flight (UI onboarding reads it only in flight or
    with `perched`, so nothing changes there).
  - *One-arm and uneven strokes (behaviour):* the flap force's component
    across the body is removed (`flap_side_share` 0), so a stroking arm no
    longer shoves the bird sideways. The one-wing roll kick and paddle yaw
    act on the stroke-mean effort asymmetry beyond a 15 % dead zone
    (`one_wing_deadzone`). Natural asymmetry therefore flies straight, and
    one arm stroking turns away from that wing on every stroke.
  - *Camera heave and bot (flight-internal):* the heave correction's
    amplitude gate always closes at the rest rate, and the template's phase
    holds while the arms rest. The autopilot starts its final glide later
    out of a steep bank.
  - *FlightTuning (additive):* `contact_turn_max_deg` 40, `flap_side_share`
    0, `one_wing_deadzone` 0.15.
    `world_scale_exponent` stays 1.0 and is now the recorded decision (VR.md
    §4 recommendation; FLIGHT_SPEC §11.4).
  - *FlightModel API:* `apply_contact(normal, kind, restitution := 0.25,
    turn := NAN)`, with an added optional parameter (the stun's turn). The
    round-3 `redirect()` is removed (flight-internal; no caller in any
    area).
  - *PlayerBird (additive):* `forced_turn` is the heading jump the model
    reported this tick (rad). Tests and telemetry consumers can measure
    forced view turns with it.
  - *VR's requests (vr fix round 4), done:*
    - `WingInput.refine_span` (default true). PlayerBird sets it to
      `auto_calibrate` every tick, so flight no longer refines the arm span
      while VR owns the calibration.
    - `WingCalibration.from_dict` validates native `Basis`, `Vector3` and
      scalar values as its flat-array path does. A non-finite or singular
      (|det| ≤ 0.5) basis, a non-finite or near-zero axis, or a non-finite
      number is ignored key by key and keeps the current value. VR still
      rejects such a dict whole before it gets here.
- **2026-09-26, vr (fix round 5) — behaviour + additive, backwards
  compatible** (details in `docs/areas/VR.md` §13):
  - *Calibration is automatic for every wearer (behaviour):* while the rig
    extras run, VR re-arms its automatic capture at app start, when the
    headset is put back on (`VR.user_presence_changed(true)`) and when the
    session is focused again (`VR.session_focused`). The next still, level
    spread at a safe moment (perched / spawning / grounded / no flight;
    never paused or with the headset unfocused) is a re-check: the same
    player (span and shoulder drop within 2 cm, each wrist within 1° of
    twist and 3° overall) keeps everything and nothing is written; anyone
    else gets exactly what a fresh automatic capture gives (the previous
    wearer's glide step reset), written into flight's `WingCalibration`
    with `WingInput.calibration_replaced()`, and persisted. Automatic
    captures (first or re-check) no longer fire while `VR.active` and not
    `VR.focused`.
  - *Comfort vignette (behaviour):* a speed term is back (DESIGN's
    "comfort vignette on fast turns/speed"): strength = setting x
    max(yaw_term, 0.7 x speed_term, 0.5 x accel_term x proximity),
    speed_term = smoothstep(1.3, 2.3, rig speed / SizeRules.cruise_speed(
    player mass)), the speed smoothed by two 0.35 s low-passes. Steady
    cruise keeps the full view everywhere (as in round 4); dives and boosts
    narrow it. VR reads `Birds.player().mass` (Bird contract).
    `ComfortVignette.flow` (deprecated, always 0 since round 4) is removed;
    `speed_ratio`, `speed_smooth`, `cruise` are added. `VignetteModel.
    target_for` / `update` take an optional trailing `speed_ratio`.
  - *VRManager (additive):* `connect_interface(source)` /
    `disconnect_interface()` and `runtime` (the object whose signals drive
    the session and whose refresh / perf-level calls the policies make:
    OpenXR's interface in the game; `VR.xr` is unchanged),
    `quit_on_session_end`, signal `quitting(reason)`,
    `refresh_policy_runs`, `perf_notifications`.
  - *VRRigExtras (behaviour):* the rig (or the extras) leaving the tree no
    longer frees the first-person wings and the vignette: they are parked
    (hidden, idle) and restored on re-entry, and freed only with the
    extras. Integration may reparent or re-add the player freely.
  - *WingCalibrator / VRCalibration / FirstPersonWings (additive,
    VR-internal):* `rechecked(replaced)`, `recapture_armed`,
    `arm_recapture()`, `auto_capture_pending()`, `recheck_plausible()`,
    `same_wearer()`, `RECHECK_*`, `DEFAULT_GLIDE_REACH`,
    `DEFAULT_FOLD_ELEVATION`; `VRCalibration.rearm(why)`;
    `FirstPersonWings.feather_custom(k)`, `local_builds`,
    `fold_shape(e)`, shader uniform `fold_lr` (its internal `_buf` is
    gone: feathers upload with `MultiMesh.set_instance_transform`).
  - *Flight's round-4 requests:* done by flight (`WingInput.refine_span`,
    validated `WingCalibration.from_dict`, see "flight (fix round 4)").
    VR's span write-back (`VRCalibration.span_drifted`) stays as a safety
    net and no longer fires on flight's real rig.
  - No project-setting changes.
- **2026-09-26, ai (fix round 3) — behaviour, additive, backwards compatible**
  (details in `docs/areas/AI.md`, "Fix round 3"):
  - *Refuges (behaviour, the brief):* a fleeing bird now dives only into
    cover that it fits and its pursuer does not (`span <= max_span <
    threat_span`, the rule of `CatchRule.in_refuge`). The cover must be in
    sight from where the bird is, and never shut (a room with no linked
    opening, or a hiding place inside a solid tree crown). With no such
    cover in reach, it escapes in the open. A hunter gives up any quarry
    that hides at once (give-up reasons `refuge` and the new `hid`).
    `Habitat.pick_refuge(pos, span, threat_pos, max_dist, taken := [],
    threat_span := INF)`: the new last parameter is optional, and callers
    without it get the old choice.
  - *Hunting (behaviour):* a hunter whose quarry has been out of sight for
    1.5 s gives up (reason `lost`). Stoops go only at prey in open air with a
    clear line to it. Near obstacles, birds fly no faster than a turn that
    fits the room, and they brake hard (up to 2 g at cruise) when their path
    runs into a surface too close to turn off.
  - *Movement (behaviour):* birds inside a building leave by its nearest
    opening. Take-offs go by the open way. Wander goals and flock waypoints
    sit above whatever stands there. Near geometry, ground clearance is kept
    above roofs and crowns. Perch approaches are checked along the leg that
    is flown. Calm birds in open air integrate at 36 Hz (24 Hz far away) and
    coast in between; engaged birds and anything near geometry run every
    tick.
  - *Safety (additive):* `NpcBird.escape()` backs a wedged bird out along its
    breadcrumb trail. `NpcBird.trapped()` is true after three watchdog
    strikes, and the Ecosystem then removes the bird out of view with the
    new despawn reason `stuck`. `NpcBird.escapes` counts escapes, and there
    is a new behaviour event, `escape`.
  - *Ecosystem (behaviour):*
    - A player jump of more than 40 m in one step is a respawn: the sky's
      focus restarts there at once (GameLoop's respawn at the spawn point),
      and the prey-near promise refills it within seconds, out of view.
    - An outgrown threat that is still in view no longer fills a threat's
      place. When the sky is full, the farthest unseen idle bird that is not
      a threat is recycled (`surplus`) to make room, and the replacement
      spawns at once.
  - *Player fairness (fix):* a meal no longer clears a hunter's 40-s
    cool-down on the player.
  - *Additive API:*
    - `NpcFlight.air_brake` (0..1, set before `step`);
    - `NpcBird.want_brake`;
    - `Habitat.top(x, z, from_y := INF)`, the highest surface below `from_y`;
    - `Habitat.ground_fast(x, z)`, a cached ground grid for steering;
    - `NpcBrain.snapshot_begin()` / `snapshot_end()`, the Ecosystem's
      per-tick position snapshot for sensing.
  - *Numbers GameLoop may use:* hunts started on the player run at 2.3–6.2 a
    minute per size tier (growth run), 2.6–5.1 travelling and 1.5–3.0 in
    the valley. Hunting-player runs in the valley: prey the player came
    within awareness of fled it 107 times of 108.

- **2026-09-26, audio (fix round 5) — behaviour fixes, additive API, one
  unused field removed** (details in `docs/areas/AUDIO.md` › Fix round 5):
  - *NPC calls and the church bell follow world metres (behaviour):* every
    call's level, reach and air absorption, and the bell's, are now set
    from the world distance at every player size. Rounds 1-4 divided
    distances by the player's `world_scale` (without magnifying the sources
    with the world), so a sparrow-sized player heard no call beyond 12-40 m
    and the Ecosystem's sky (60 birds, 60-110 m out) was silent.
    `world_scale` still sets the threatening predator's urgency floor.
    Nothing for AI or World to change: audio still finds birds through
    `Birds` and reads only core Bird fields.
  - *Mix (behaviour):* the danger drone rises earlier with the threat
    (-16 dB at 0.5, was -18) and, in fast flight with the wings spread,
    with the wind's body (up to 6 dB); in a tucked dive the
    threatening predator's call rises over the wind's edge layer (up to
    4 dB, headroom still held by the calls' crowd rule); a call that would
    reach the ear under -62 dB A no longer takes a voice. Nine shipped call
    recordings were re-cut so every call ends at a natural decay (files
    under `assets/audio/calls/`, names unchanged).
  - *Additive API:* `CallVoices.distance_m()`, `CallVoices.MIN_CALL_DB`,
    `CallVoices.edge_lift_target_db` / `edge_lift_db`, `stats["quiet"]`,
    and `playing()` entries gain `age` (s);
    `FlightSoundMap.threat_call_lift_db()`, `danger_makeup_db()` and their
    `compute()` keys `threat_lift_db`, `danger_makeup_db`;
    `AudioBank.SYNTH_THREADS` (clips synthesized on 3 worker threads: a
    cold build takes ~2 s of wall time on the dev Mac instead of ~6).
  - *Removed:* `AudioDirector.perf_max_usec` (written, never read; no
    caller in the tree). `perf_samples` is now a ring (its order is not
    chronological; `perf_stats()` is unchanged).
  - *Integration note (not audio's files):* nothing calls
    `AudioDirector.play_ui()` yet (menu clicks are silent) and
    `scenes/main.tscn` has no AudioDirector; the Quit path should
    `await AudioDirector.shutdown()` before `get_tree().quit()`.
- **2026-09-26, flight (fix round 5) — behaviour fixes, additive, backwards
  compatible** (details in `docs/areas/FLIGHT.md` §2 and §8,
  `docs/areas/FLIGHT_SPEC.md` §19 "Fix round 5"):
  - *Ground landing (behaviour):* a bird whose belly or feet press on the
    ground skids (Coulomb friction), and a ground contact at or below
    1.2 V_min (was 0.7) is a touchdown; perch geometry (layer 2) is never
    ground. GROUNDED now starts with a **run-out**: the body keeps its speed
    along the ground and slows at 0.6 g (a sparrow runs ~1.4 m, an eagle
    ~6.5 m), sliding along walls; running off an edge is FLYING again. So
    while GROUNDED `Bird.velocity` / telemetry `groundspeed` can be nonzero
    for up to ~2 s; `perched` is true and `airspeed` 0 as before, and
    `player_perched(ground pos)` still fires at the touchdown. The legs take
    the speed into the ground: for ~0.1 s the camera dips up to 0.75 body
    radii (included in telemetry `heave_offset`). A take-off during the
    run-out keeps its speed.
  - *Near the ground (behaviour, normal and novice presets):* below ~9-11 m
    (what a held stall falls before its forced recovery, plus a little) a
    full flare is the maximum-lift flare; the deliberate stall (and
    `player_stalled`) happens only above that. A slow, sinking, flaring bird
    within 4 spans of the ground lowers its legs and tail (extra drag).
  - *Pause (behaviour):* after the game unpauses, the controls stay neutral
    until the player's arms are out and settled (at most 1.5 s), then fade
    in over 0.4 s, and no stroke from before or during the pause is
    credited. Menus that call `set_controls_enabled` are unaffected.
  - *Perching (behaviour):* the perch assist keeps a closing speed into a
    headwind (a sparrow now perches in the world's full 2.64 m/s breeze), and
    a slow brush of the branch no longer locks the capture out for 0.5 s.
  - *Additive API:* `PoseFrame.pose_dt` (the seconds the poses advanced since
    the previous sample; -1 unknown, 0 a repeat) with pose recordings'
    optional `"pd"` key; `XRPoseSource.frame_timing` (on for the game's own
    XR source) and `clock` (tests); `WingInput.resume()`;
    `FlapDetector.step(..., sample_dt := -1.0)`; `FlightEnv.agl`;
    `FlightTuning.ground_friction`, `touchdown_speed`, `leg_flex`,
    `landing_config_spans`, `stall_guard_vmin2g`. A `PoseSource` that knows
    its frame timing may set `pose_dt`; others need nothing.
  - *World scale (flight's fallback driver only):* when it changes
    `world_scale` it rescales the tracked nodes, the origin offset and the
    wing anchors at once. Note for VR's `WorldScaleDriver` (not a request):
    between a `world_scale` snap and the XR server's next update the
    tracked nodes hold the old scale (rendering is unaffected; the server
    applies the current scale), which is what the lab's first XR frame
    showed as a 1.04 m camera offset.
  - *Lab (flight-internal):* the course facade has human-scale windows over
    the whole wall; the chase camera sits closer.
  - *Telemetry (timing only):* `PlayerBird.telemetry()` builds its
    dictionary on the first read in a tick instead of on every tick, still
    the same Dictionary updated in place, with the same keys and values.
    Every consumer (onboarding, VR haptics, audio) calls `telemetry()` for
    each read, so none sees a difference. Only a reference kept across ticks
    without calling again would now hold the last read's values.
- **2026-09-26, vr (fix round 6) — behaviour + additive, backwards
  compatible** (details in `docs/areas/VR.md` §14):
  - *Calibration never changes behind one player's back (behaviour):* the
    wearer re-check of round 5 is kept, but an UNPROMPTED pose no longer
    replaces a calibration. The same player is judged within human
    repeatability (span 2 cm from the captured-to-refined range, shoulder
    drop 2 cm, each wrist 5° of twist = FLIGHT_SPEC §5.9's pitch dead zone,
    7° of grip swing) and keeps everything silently. Any other still
    spread only raises a prompt ("Lower your arms, then spread your wings,
    hands flat"); a fresh prompted spread decides: kept, or a fresh
    calibration (glide step reset, `WingInput.calibration_replaced()`,
    persisted) followed by the optional glide step. An unanswered prompt
    (20 s, take-off, pause, headset off) goes away and keeps the
    calibration. Automatic captures (first or re-check) also wait 2 s
    after the bird was last seen flying (a landing flare, and flight's
    GROUNDED run-out). A focus regain arms the re-check only on a runtime
    without presence events.
  - *VRManager (additive):* `presence_supported` (from
    `OpenXRInterface.is_user_presence_supported()` or the first presence
    event). Integration's `xr/openxr/extensions/user_presence=true`
    request (VR.md §7) now also stops the system menu from arming a
    wearer re-check.
  - *VRRigExtras (behaviour):* extras placed away from the rig (the
    `player_rig` group lookup) give a REPLACED rig new first-person wings
    and a new vignette (the old ones die with the old rig); a rig queued
    for deletion is skipped. Round 5 threw a SCRIPT ERROR there and left
    the new rig without wings, vignette or growth.
  - *WingCalibrator / VRCalibration (additive, VR-internal):* signal
    `check_wanted(reason)`, `request_check()`, `dismiss_check()`,
    `check_capture`, `check_needs_break`, `wearer_verdict(geom)`,
    `capture_span` (also a saved key; older saves read the flown span),
    `RECHECK_SWING` (replaces `RECHECK_NEUTRAL`); `RECHECK_SPAN` 0.02,
    `RECHECK_TWIST` 5°; `rechecked(false)` also ends a dismissed prompt;
    `VRCalibration.Flow.CHECK`, `start_check()`, `dismiss_check()`,
    `player_flying()`, `CHECK_TIMEOUT`, `SETTLE_AFTER_FLIGHT`.
  - *VRControls (internal):* an empty `reader` means "read the XR
    trackers" (the dead `_xr_read` sentinel is gone); tests still inject
    a reader.
  - No project-setting changes.
- **2026-09-26, gameloop (fix round 3) — behaviour + values + additive, backwards compatible**
  (details in `docs/areas/GAMELOOP.md`, "Review findings (fix round 3)"):
  - *Player catch reach (behaviour):* `reach_spans = 2.0 x time_scale^-0.5`
    (was `^-1`): 2.0 wingspans as a sparrow, 1.46 as a pigeon, 1.0 as an
    eagle. However much catch assist, the player's catch never reaches
    further than `CatchRule.PLAYER_CONTACT_MAX_SPANS` (2.9) wingspans centre
    to centre (4.9 felt m; round 2's full assist gave a sparrow 8 felt m).
  - *Target cue (behaviour):* `Events.target_changed` names only prey in the
    player's sight - a ray against the world's static geometry (physics
    layer 1) from the player's physics space (`ThreatWatch.space`, set by
    GameLoop; `GameLoop.sight_cue`); a target out of sight for more than
    `ThreatWatch.SIGHT_GRACE_S` (1 s) is dropped. `ThreatWatch.chase_odds`
    falls to 0.05 from 0.65 of the player's mass (near-equals were the cue's
    pick and were caught 2-4% of the time). UI/audio: nothing to change.
  - *First flight (behaviour):* a run opens with `OPENING_RESPITE_S` (120 s)
    of attack respite (`npc_ignore`), lasting until the player has grown out
    of its first species, at most `OPENING_MAX_S` (300 s). UI: the
    onboarding lessons fit inside it. AI: nothing to change.
  - *Danger (behaviour, values):* boldness - every attack the player
    survives shortens the next respite x`BOLD_DECAY` (0.65) down to
    `BOLD_FLOOR` (0.25); a death resets it. After a respawn NPCs leave the
    player alone for `RESPAWN_RESPITE_S` (30 s) x body time x the danger
    assist. The danger assist also narrows the strike cone on the player by
    up to 20 deg (was 15), shortens the strike reach by up to 50%
    (`DANGER_ASSIST_REACH_LOSS`), lengthens every respite up to x5
    (`DANGER_ASSIST_RESPITE` 4, was 2) and the threat cue's horizon up to
    x1.6 (`DANGER_ASSIST_CUE`), and cuts the death penalty by up to half
    (`DANGER_ASSIST_PENALTY_CUT`; new `GameLoop.death_penalty()`). New
    public `GameLoop.attacks_survived`.
  - *Lives (behaviour):* besides a new peak tier, every `LIFE_PER_MEALS` (5)th
    worthwhile catch since a life was last lost gives it back ("eat to
    heal"; `GameLoop.meals_since_life_lost`, `lives_changed` fires as
    before). UI: nothing to change - it already follows `lives_changed`.
  - *NPC growth cap (value):* `NPC_GROWTH_CAP` 0.15 -> 0.04: with the AI's
    +-9% spawn band no bird can then eat its own kind (1.09 x 1.04 / 0.91 <
    `EAT_RATIO`). **AI:** if you widen the spawn band, tell gameloop.
  - *What hunts you (behaviour):* `get_run_stats().danger_species` lists the
    ladder species that can eat the player plus the species of every live
    bird that can (the AI's heavier apex eagles). New
    `GameLoop.danger_species(mass)`. UI: nothing to change; the pause
    screen's "Nothing hunts you" is now only shown when it is true.
  - *Values:* `SizeRules.GROWTH_GAIN` 1.55 -> 1.62, `GROWTH_SIZE_EXP`
    0.05 -> 0.012 (tuned on whole runs in the valley against the AI as of
    14:23, code hash `a06853cd96ec8bdc`).
  - *Catch assist (behaviour):* its clock runs in the square root of body
    time (`GameLoop.assist_for`), like the reach: an eagle gets help after
    60 s without a catch, not 120.
  - *Evidence (process):* the fingerprint keeps indentation (a line moved
    into a block changed nothing before) and leaves out the two growth
    constants (the evidence records its growth tuning and `pacing_test`
    checks it on its own). `pacing_test` still **fails** when the AI or
    valley code differs from what the evidence ran. **AI / world:** a
    behaviour change there means re-running the game loop's evidence (about
    an hour: docs/areas/GAMELOOP.md, "Regenerating the evidence").
  - *Request to AI (not a contract change):* in the late game the loop's
    catch rate is bounded by the sky - an eagle's worthwhile prey (crows,
    gulls, hawks) go out of sight behind the valley's geometry within
    seconds 2 chases in 3. If the AI's "prey near" promise could favour
    prey in open air for big players, the apex phase's dry spells would
    shorten; the loop's cue already points only at prey in sight.
- **2026-09-26, flight (fix round 6) — behaviour fixes, additive, backwards
  compatible** (details in `docs/areas/FLIGHT.md` §2 and §8,
  `docs/areas/FLIGHT_SPEC.md` §19 "Fix round 6"):
  - *Slopes and roofs (behaviour):* a bird at landing speed meets a floor
    with its feet (one body radius beyond its body), so `player_perched`
    fires at the feet's contact and the body then settles onto the ground;
    a touchdown may come in at up to 1 V_min into the surface (was
    0.8 V_min: a slow bird flying into a 44 deg roof was stunned). The
    run-out keeps to the ground's plane (on a slope `Bird.velocity` and
    telemetry `vertical_speed` can be nonzero while GROUNDED) and a ridge
    launches it. The legs bend along the surface normal: for ~0.1-0.3 s
    after a touchdown on a slope the camera's offset from the body has a
    horizontal part (`PlayerBird.view_offset()`); telemetry `heave_offset`
    and `heave_offset()` are its vertical part.
  - *Take-off (behaviour):* the launch off the ground leaves the surface
    (never into a slope), and a bird launched off the ground is not touched
    down again while it keeps flapping (a stroke within 1.2 s) or for 0.5 s,
    until two spans clear: so no `player_perched` / `player_took_off` pair on
    every stroke facing up a slope. A big bird that cannot out-climb a long
    slope stands again when its launch is spent (one `player_perched` per
    bound).
  - *Stall guard (behaviour):* one ground ray per tick now reaches below the
    guard height (~11 m; was 2 spans), so a flat roof counts like terrain.
    `FlightEnv.ground_distance` keeps its 2-span meaning.
  - *Telemetry (timing only):* a `telemetry()` read inside an Events
    handler (mid-tick) is rebuilt on the next read after the tick;
    `wind_l_y` / `wind_r_y` (and `FlightEnv.wind_l` / `wind_r`, haptics and
    telemetry only) are sampled when telemetry is read, with the same values.
  - *Angles (numerical):* `FlightMath.wrap_angle` (and `ViewTurn`) wrap
    exactly to [-PI, PI): Godot's `wrapf` returns the lower bound for any
    result within its `is_equal_approx` tolerance of the upper one, which lost
    up to 3e-5 rad at the seam. Callers see the same values elsewhere.
  - *Additive API:* `PlayerBird.view_offset()`;
    `FlightModel.stall_guard_height()`; `FlightTuning.leg_reach`,
    `touchdown_vn`, `run_brake_min`, `take_off_hold_gap`,
    `take_off_hold_s`; `FlightGeometry.slope()`, `slope_normal()`,
    `gable_roof()` (flight's test and lab geometry).
- **2026-09-26, flight (integration: the arena's lid) — behaviour fix,
  additive, backwards compatible** (details in `docs/areas/FLIGHT.md` §2
  "Integration: the arena's lid"):
  - *Thin air (behaviour):* under `World.ceiling` the air thins from 45 m
    below it (measured from the top of the body) to nothing 5 m below it
    (`FlightEnv.thin_air`), and the flap force now fades with lift and drag
    (`FlightEnv.lift_scale` keeps its name and range; it was lift and drag
    only, over the last 20 m, so flapping birds climbed into the lid). A
    climb levels off 17-27 m under the lid; a thermal cannot lift a bird
    within ~8 m of it. Nothing changes below 250 m under the 300 m lid.
  - *The lid never stuns (behaviour):* a PlayerBird contact met from below at
    `World.ceiling` is a slide (or silent under 0.5 m/s), never a stun or a
    touchdown, whichever body makes the lid. `player_collided` fires as for
    any slide.
  - *Additive API:* `FlightEnv.thin_air(gap, band, floor_gap)`,
    `FlightTuning.thin_air_band` / `thin_air_floor`,
    `PlayerBird.contacts["lid"]`.
  - *NPCs:* no change. NpcFlight birds never reach the lid (the brain's bounds
    overlay turns them back from `ceiling - 25 m`), measured in the real world
    by `tests/shots/flight_ceiling_npc_diag_test.gd`.
- **2026-09-26, vr (calibration redesign, the lead's decision) — behaviour + additive; one marked UI change; one project setting**
  (details in `docs/areas/VR.md` §2.3 and §15):
  - *Calibration (behaviour):* wrist neutral and arm span are captured ONLY
    in VR's explicit, prompted step. It runs on the first launch (no saved
    calibration), by itself once the headset is on, before the first
    flight; a run under way is paused first. It also runs whenever the
    player chooses Recalibrate: `UIRoot.recalibrate_requested` from
    Settings or the pause menu, the Y-hold (`VR.recalibrate_requested`), or
    `VRCalibration.start_manual()`. The card says "Stand tall. Spread your
    wings, hands flat. Hold still."; the capture needs a plausible pose that
    is still for 1 s. B/Y cancels, and so do Play/Resume and the headset
    coming off; the old calibration, or flight's defaults, stays.
  - A step asked for during play pauses the game (`Events.menu_requested`,
    then `Game.PAUSED` if nothing handled it). Nothing is ever captured in
    flight.
  - There is no automatic capture, no wearer re-check and no card
    answered by a pose any more (the fix rounds 1-6 machinery is deleted).
    Only the arm span is still refined from genuine spreads in play, and
    that never changes the neutral.
  - *VRManager (additive):* `recalibration_suggested: bool`, signal
    `recalibration_suggested_changed(on)`, `suggest_recalibration(on)`. VR
    raises it (VR only) when the headset comes off and back on, when focus
    is lost for 60 s or more, and at an app start with a saved
    calibration. A completed step clears it. It is only a hint for the UI.
  - *UI (the one allowed, marked change in `scripts/ui/`):*
    `UIRoot.context()["recalibrate_suggested"]` reads the flag duck-typed,
    and the pause screen refreshes on the signal. `PauseScreen` shows "New
    player? Recalibrate wings" (action `&"recalibrate"`, handled like
    Settings > Recalibrate wings) in its top row while it is set; the
    run-so-far line then sits on the tip's line. The UI suite passes
    144/144.
  - *Flight:* nothing to change. `WingInput.calibration_replaced()` is
    called after each new VR neutral and never otherwise.
    `begin_calibration` captures are still adopted and refined.
  - *Project setting (integration's file; the state notes' simulator
    noise):* `xr/openxr/extensions/meta/color_space.pc=false` replaces
    `.../color_space/starting_color_space.pc=0`. The vendors 5.1.0
    default, REC709 (3), is unsupported by the Meta XR Simulator; `.pc=0`
    had traded that ERROR for "WARNING: Recommended color space project
    setting is REC709". Disabling the extension on desktop silences both,
    and Quest keeps REC709. This was verified in a private sandbox under
    the simulator lock before it was applied. The `hand_tracking` warning
    was already fixed by `openxr/extensions/hand_tracking=false`.
  - *Removed (VR-internal):* the wearer re-check API and the glide step
    (listed in VR.md §15). `Settings["wing_calibration"]` keeps its keys;
    an old `capture_span` key is ignored.
- **2026-09-26, integration — the composed game** (details in `docs/INTEGRATION.md`):
  - *main.tscn* composes §4 in order (World, Ecosystem, Player with
    `vr_rig_extras.tscn` under its XROrigin3D, GameLoop, UI, Audio) plus
    `BirdFX` (BirdFXDirector: the one feather-burst source), `UISounds`
    (UISoundBridge: UI actions -> `AudioDirector.play_ui`) and `XRMirror`.
    The heavy scenes are InstancePlaceholders built one step per frame
    behind a loading card on a boot rig of integration's own (not in
    `player_rig`); **the Player spawns after the World, at
    `World.get_player_spawn()`** (as the startup order above says). In a
    headset the long steps (bird meshes, the valley, the player) run before
    the first frame of ours, under the runtime's loading indicator.
  - *Game-state glue (integration's):* `PlayerBird.auto_process` is false in
    BOOT, MENU and ENDED (the body waits on the spawn perch; the XR rig keeps
    tracking) and true in PLAYING/CAUGHT; entering MENU from a run respawns
    it at the spawn. Quit awaits `AudioDirector.shutdown()` before quitting
    (also on window close: `auto_accept_quit` off).
  - *Quest quality tier* (`scripts/integration/quality_tier.gd`, automatic on
    Android): `Ecosystem.max_npcs` 28, `lod_near`/`lod_far` 60/140 m, and a
    governor that lowers `max_npcs` (floor 20) when the headset misses frames
    while flying. **Game loop:** the pacing evidence assumed 60 NPCs.
  - *project.godot:* `xr/openxr/extensions/hand_tracking=false` (explicit:
    the vendors 5.1.0 plugin reads it before Godot defines it and warned in
    every run; integration round 1 added `hand_tracking.android=false`,
    because an export drops a setting equal to its default and the Quest
    would have warned again) and `xr/openxr/extensions/meta/color_space.pc
    = false` (VR's entry above: the Meta colour-space extension is off on
    desktops - the simulator rejects the plugin's REC709 - and the Quest
    keeps REC709; round 0's `starting_color_space.pc = 0` was replaced).
    `export_presets.cfg` holds the "Meta Quest" preset.
  - *For AI (defect, next phase):* `NpcBrain._sense` (`npc_brain.gd:602`,
    `var mt: Bird = m.threat`) raises "Trying to assign invalid previously
    freed instance" when a flock mate's `threat` was freed (the Ecosystem's
    `_remove` does not clear other birds' `threat`).
  - *For VR:* the first-launch calibration card appears on top of the main
    menu (both straight ahead).
- **2026-09-26, ui (fix round 4) — behaviour + additive, backwards compatible**
  (details in `docs/areas/UI.md`, "Fix round 4"):
  - *Where the HUD notices are (behaviour):* the notice band (lesson card,
    tier-up and apex celebrations) no longer sits on the centre line and
    dodges the flight path. Its fixed home is **beside** it: +7..+20 deg
    elevation, 10-52 deg to the right of the HUD's centre line (band yaw
    `HUD.NOTICE_YAW` = -31 deg), text on the inner side. The flight path,
    which every flap cycle sweeps up and down the centre line, never
    crosses it. If the flight path, the target, a real threat or one of
    their cue chevrons comes within 1.5 deg of a notice plate, the notices
    turn see-through at once (0.12 s); only if it stays 1 s, or crosses 3
    times within 8 s, do they move once to the mirror placement left of the
    path (`HUD.NOTICE_MIRROR`), eased over 0.9 s, at most once every 4 s.
    A new notice appears wherever is clear. The step-up/step-aside search
    and its `DODGE_*` constants are gone (`DODGE_SEARCH_S`, `dodge_target`,
    `dodge_stuck`, `peak_move_speed` and `placement_candidates()` remain
    so earlier probes compile).
  - *HUD follow (behaviour):* the HUD panel's yaw dead zone is
    `UIRoot.HUD_FOLLOW_DEADZONE_DEG` = 55 deg (was 24): turning the head to
    read the notices must not set the HUD following.
  - *Cues (behaviour):* the chevrons draw over the HUD plates (render
    priority `HudIndicators.CUE_RENDER_PRIORITY` = 11 > the HUD panel's 9;
    desktop CanvasLayer 6 > the HUD's 5). `UIRoot.hud_protected_directions()`
    now includes the drawn cues.
  - *Onboarding (behaviour, one telemetry key):* "Tilt for speed" needs the
    tilt itself: `PlayerBird.telemetry()["pitch_input"]` (flight already
    reports WingState.pitch) held past 0.15 for 1 s while gliding, and its
    effect in the same window (leading edges down: +0.5 m/s or 5 %;
    up: vertical speed +1 m/s while the airspeed falls as much). A
    telemetry provider without `pitch_input` never completes it (it times
    out after 45 s, as any lesson). `UIMockPlayer.tel` has the key.
  - *Pointer (behaviour + one flight-owned node reused):* the UI reads the
    rig's own aim controllers (`LeftAim` / `RightAim`: a direct
    XRController3D child of the XROrigin3D on that tracker with pose
    `aim`) and adds `UIAim_<hand>` only if there is none; it never frees
    a controller it did not add. Hover has 12 px of hysteresis and hover
    ticks are at least 0.35 s apart.
  - *Additive API:* `UIPanel` band dictionaries take an optional `"yaw"`
    (degrees, + = left; `band_yaw(i)`), included in `band_placement`;
    `HUD.advance(delta)`, `set_vr(on)`, `set_notice_side(side)`,
    `move_count`, `notice_side`; `HudIndicators.step(delta)`,
    `desktop_tip_radius()`; `SettingsScreen.advance(delta)`;
    `UIXRPointerSource.find_aim()`, `owns_controller`. `UIRoot._highlight`
    takes any object (a freed bird is skipped; the new target is taken
    first).
- **2026-09-26, ui (fix round 5) — behaviour + additive, backwards compatible**
  - *HUD placement (behaviour):* the HUD panel's centre line is the flight
    direction, not the head: `UIRoot.flight_yaw()` (rig space, radians,
    + = left) is the player's horizontal `Bird.velocity`, with
    `Bird.get_forward()` mixed in at 0.25 x `SizeRules.cruise_speed(mass)`
    (so it decides for a slow, hovering or perched bird), NAN without a
    player bird. The HUD holds still while that wanders less than
    `UIRoot.HUD_HEADING_LEASH_DEG` (4 deg), then eases back onto it
    (`HUD_HEADING_TAU` 0.2 s, <= 110 deg/s). Head turns never move the HUD;
    without a player bird it follows the head past
    `HUD_FOLLOW_DEADZONE_DEG` (55) as before. Only core contracts are read.
  - *Celebrations (behaviour):* a tier-up or apex celebration is placed
    where the player looks: as near the gaze as it can be beside the flight
    path (never nearer the path than the notices' home), clear of what
    matters, home's side unless the other is 5 deg nearer
    (`HUD.TOAST_HOME_BIAS_DEG`). Its clock holds while it is faded or its
    text is more than `HUD.TOAST_VIEW_DEG` (45) from the gaze, for at most
    3 s in all. It swaps text in place only over one being read. Text is
    at most `HUD.TOAST_TEXT_W` (680 px) wide, the title 90 px; the "what
    dropped off" line now reads "Ignore: ..." (the pause screen's word),
    the apex line "N more to win".
  - *Onboarding (behaviour):* a lesson that times out is not recorded as
    learned (`UIProgress.lessons_done`); the tutorial counts as done only
    when every lesson was done (or it was skipped); missed lessons come
    back next session (not at every resume of this one); learned ones are
    never taught again.
  - *Pointer (behaviour):* a press that slides off the panel before the
    release cancels (`UIPanel.pointer_exit` moves off, then releases).
  - *Rendering (behaviour):* UIRoot no longer keeps the HUD rendering for a
    whole celebration (`keep_alive`): the celebration's own redraws book
    each frame's render; a held clock renders nothing.
  - *Additive API:* `UIPanel.yaw_source` (Callable), `source_leash_deg`,
    `source_tau`, `source_yaw()`, `panel_yaw()`, `anchor_error()`,
    `band_frame_direction()`; `HUD.notice_rects()`, `gaze_level()`,
    `toast_view_angle()`, `lesson_labels()`, `toast_labels()`,
    `DESKTOP_MARGIN`. Removed (dead, only old probes read them):
    `HUD.DODGE_SEARCH_S`, `HUD.placement_candidates()`.
- **2026-09-26, gameloop (fix round 4) — behaviour + additive, backwards compatible** (details in `docs/areas/GAMELOOP.md`, "Threat and target" and "Pacing")
  - *Threat cue (`Events.threat_changed(level, predator)`, same signature):*
    `level` is now **the named predator's own** smoothed threat, never
    another bird's (each predator is smoothed on its own; round 3 reported
    the smoothed *worst* level under whatever name it held). The name is
    sticky: a rival takes it only when its level beats the named one's by
    0.15 for 0.5 s (`ThreatWatch.switch_margin`, `switch_hold_s`), or when
    the named one has been under 0.1 (`ThreatWatch.QUIET_LEVEL`, the UI's
    REAL_THREAT) for 0.5 s; a rival at 0.3 (`announce_level`) takes it at
    once from a quiet name (an attack is never announced late), a named
    bird that leaves the game (eaten, despawned, outgrown) is replaced at
    once, and the name never moves by preference to a bird whose own raw
    threat is under 0.1. So at a change of name the level may step to the
    new bird's own level (up or down). **UI / audio / VR:** nothing to
    change; the arrow, haptics and the predator's call now stay on the
    attacker through its jinks instead of hopping to bystanders.
  - *ThreatWatch additions:* `peak_level` (worst smoothed threat of any
    predator: GameLoop's attack respite reads it, as it read `level`
    before), `level_of(bird)`, `raw_of(bird)`, `last_change`
    (`&"new"/"gone"/"attack"/"challenge"/"quiet"/"faded"`),
    `switch_hold_s`, `announce_level`, `QUIET_LEVEL`,
    `reassert_highlight(bird)`. `GameLoop.ATTACK_QUIET_LEVEL` (0.05, the
    value `_track_attacks` used inline).
  - *Highlights:* right after emitting `threat_changed` / `target_changed`
    GameLoop re-writes its own highlight on the birds those events named
    (old and new), so every frame ends with the loop's classification. The
    UI's handlers may keep writing; a 0 the UI writes on a bird that can
    eat the player no longer survives the frame (round 3: a hawk passing
    5-9 m away ended 10 of 720 frames unlit). **UI (request, not
    required):** only raise highlights; never clear a value the loop owns.
  - *Restart:* `restart_run()` resets the player to a sparrow **without**
    `player_tier_changed` (a reset, not a tier change: listeners resync on
    `run_started`; emitting it would toast "sparrow" as a tier change at
    every new run). Pinned by `state_test`.
  - *Broad phase:* the catch pass's default is now the spatial hash the
    brief names (`CatchGrid`: x/z columns, the cell table a sorted array,
    any number of birds); sort-and-sweep stays the tested alternative.
    Outcomes are identical (contacts are resolved in a sorted order).
  - *Growth values (SizeRules, owned by gameloop):* `GROWTH_GAIN` 1.62 -> 1.1,
    `GROWTH_SIZE_EXP` 0.012 -> 0.03 (re-tuned on tuning seeds after the cue
    fix and the AI's new "show" moved the pacing; `docs/areas/GAMELOOP.md`).
  - *Evidence process:* stored runs record `core_code` (scripts/core
    game.gd, bird_registry.gd, events.gd) beside `ai_code` / `world_code`,
    and a `cue` block per run (IntegratedSim). `pacing_test` now **warns**
    when the AI, valley or core code differs from what its evidence ran and
    **fails only with `-- --strict_evidence`** (the unit suite no longer
    depends on other areas' source text; the integration check should pass
    the flag). `scripts/game/data/used_seeds.json` lists every seed any
    stored run used; the held-out seeds must be in none of them.
  - *For AI and integration (a finding, not a contract change):* the pacing
    evidence is only as current as the sky it ran. The AI (the Ecosystem's
    "show", then integration round 1's flee-from-the-player, tick phases and
    spawn perch) and the world changed while round 4's batches ran, a dozen
    AI versions in all; so the evidence ran from **a frozen copy of the tree
    (00:21): AI `528944a4ee31beb1`, world `eb2ad56411f6c180`, core
    `bca7bd3c0c04efbd`** - consistent, recorded, and before integration
    round 1's AI changes. When this was written the tree's AI was
    `ca4b9e28bccecf5b` (edited at 03:16 and 03:27, after the `4c29ce769e7e7796`
    announced as final) and the world `79c0bb5c7f3cc938`: `pacing_test` warns.
    **Gameloop re-runs the evidence (~2.5 h from a new frozen copy,
    GAMELOOP.md "Regenerating the evidence") once the AI settles; please
    announce behaviour changes to the Ecosystem's population, placement or
    fleeing.** The flee-from-the-player change (slower escape lines) will
    likely speed the catches up again, and may need another growth re-tune.
  - *The Quest tier (a finding for AI and integration):* at the Quest
    tier's 28 NPCs (LOD 60/140 m) on the evidence's sky and tuning, 20
    competent runs reached the pigeon at 8:14 and **the eagle at 39:44**
    (60 NPCs, same seeds: 6:38 / 24:56) - the brief's 20-30 minutes are not
    met on the Quest budget. Suggested fix on the AI side: at a small budget
    keep the player's worthwhile prey (and its threats) at the 60-NPC
    density near the player and trim ambient / distant / show birds first.
    `gameloop_pacing.tscn -- --live_ai --quest_npcs=28` re-checks it.
  - *For integration's target-cue finding (next phase):* "most
    cue-following chases end because the target cue names another bird
    before the player is on the first one's tail" (the whole-game catch
    test) - noted; the target's 1.5 s minimum hold and 1.35x switch ratio
    were tuned against modelled pilots, and changing them changes the
    evidence's fingerprint, so it is left for the evidence re-run above.
- **2026-09-27, integration round 1 (fixer) — AI behaviour: the show, the
  flee from the player, the spawn perch; no API removed** (details in
  `docs/INTEGRATION.md` §8 and `docs/areas/AI.md`, "Integration round 1").
  **Announced for the game loop's pacing evidence: the final AI code hash
  (`IntegratedSim.sky_code`) is in docs/INTEGRATION.md §8; the world's
  changed too (the shores, the paving, `is_water`).**
  - *The show (Ecosystem, behaviour + additive):* up to `SHOW_FLOCKS` (2)
    loose flocks or the murmuration and `SHOW_SOLOS` (5; at least
    `SHOW_SOLOS_MIN` 5 at any budget) free-flying solo birds that are only
    life and scale - roles ambient / giant / peer / dust / extra, never the
    player's prey or threats, and only species that cruise at least
    `SHOW_KEEP_UP` (0.95) of the player's cruise - are homed on a point
    ahead of the player's flight (`SHOW_AHEAD` x its sky, 36-110 m; on a
    lap, round the lap's own curve), re-placed when the player turns away
    from it (45 deg, at most every 2 s). A show flock wheels near the
    player's height (`FlockGroup.show_alt`), glides its home after the point
    (`FlockGroup.home_goal`, 0.85 x cruise), flies at effort 0.7
    (`NpcBrain.SHOW_FLOCK_EFFORT`) and roosts only after 90 s. The
    murmuration forms at any budget (at least 8 starlings,
    `N_MURMURATION_MIN`, taken from the near-equals, never from the prey).
    Additive: `Ecosystem.show_info()`, `stats()["show"]`,
    `FlockGroup.show_alt` / `home_goal`, `NpcBrain.SHOW_FLOCK_EFFORT`.
    Birds a player notices straight ahead (>= 0.37 deg span, 106 x 90 deg
    view): the verifier's 0.05 (full) / 0.0 (Quest) -> full 2.0-7.9, Quest
    0.9-4.5 on average (`tests/unit/integration/sky_view_test.gd`).
  - *Fleeing the player (NpcBrain + NpcFlight, behaviour + additive):* a
    bird fleeing the player holds each escape line
    `NpcBrain.FLEE_PLAYER_REAIM` (10) times longer than its reaction time
    and turns no tighter than `FLEE_PLAYER_TURN` (0.55) of its turn rate
    (`NpcFlight.turn_scale`, set each step from `NpcBird.want_turn`). It
    still flees at full speed, jinks and takes cover. Other hunters are
    unaffected. Why: through the real chain (arm gestures, WingInput, the
    comfort-capped rig) no pilot ever caught a fleeing bird (the
    experience verifier: 0 of 83 chases).
  - *The spawn perch (Habitat, behaviour):* `Habitat.find_perches` never
    offers the perch at `World.get_player_spawn()` (within
    `SPAWN_PERCH_M`) to an NPC: a respawn found it taken and left the
    player hovering beside it (the engineering verifier's confirmed finding).
  - *Tick phases (NpcBird + Ecosystem, behaviour + additive):* the
    Ecosystem gives each bird it spawns a tick phase
    (`NpcBird.set_tick_phase`), applied once to a calm bird that has lived
    1 s, so a sky spawned in one tick does not integrate in lockstep (the
    Quest verifier: even ticks 0.84 ms, odd 0.50). A bird coming in to a
    perch holds its body no steeper than 0.5 rad nose-down
    (`NpcBird.APPROACH_PITCH_MIN`).
  - *For the game loop (not changed here, `scripts/game/` is gameloop's):*
    the evidence in the tree ran the AI before these changes; it has to be
    regenerated on the final AI. The whole-game catch test
    (`tests/unit/integration/game_catch_test.gd`) is the real-chain check
    of the catch rule the pacing model should agree with.
- **2026-09-27, ui (fix round 6) — behaviour + additive; two removals** (details in `docs/areas/UI.md`, "Fix round 6")
  - *HUD placement (behaviour):* the HUD panel's centre line is where the
    player's **body faces**, not the flight path's heading (round 5) nor
    the head: `UIRoot.body_yaw()` (rig space, radians, + = left) reads
    `PlayerBird.telemetry()["body_yaw"]` (the documented telemetry extra:
    WingInput's torso yaw in tracking space, which is the XROrigin3D's own
    frame). A player bird without that key: the rig-space yaw of
    `Bird.get_forward()`, held while it is steeper than
    `UIRoot.BODY_STEEP_DEG` (60); NAN without a player bird (the HUD then
    follows the head past `HUD_FOLLOW_DEADZONE_DEG`, 55, as before). The
    torso is smoothed (`HUD_BODY_SMOOTH_TAU` 0.2 s), ignored within
    `HUD_HEADING_LEASH_DEG` (6), then followed (`HUD_HEADING_TAU` 0.2 s, at
    most `HUD_FOLLOW_MAX_SPEED` 90 deg/s) until it is within 0.5 deg of both
    the smoothed and the raw torso. Why: in the real game wind makes a slow
    bird's path crab tens of degrees off where it faces and a zoom over
    the top reverses it; the round-5 HUD swung 157 deg round the player
    (the round-6 verifier). The flight path stays protected: the notices
    make way for it as before.
  - *HUD notices (behaviour):* the card's home is 9.7-42 deg right of the
    centre line (`HUD.NOTICE_YAW` -25.9, was -31), its text column
    `HUD.CARD_TEXT_W` 548 px (card `CARD_W` 808, title `CARD_TITLE_SIZE`
    60), so every word is within 35 deg of a level gaze along the centre
    line while prey jinking +-8 deg round it stays clear; the text is
    right-aligned on the mirror side, changes sides mid-move (not at the
    start of a move), and is laid out at once when a hidden plate is shown
    again. The lesson card is not shown in the frame a celebration ends (it
    is placed by the next `make_way`). A crossing is counted once even when
    it begins in a zero-time `make_way`. Lesson hints and one title were
    shortened to fit (e.g. "Catch prey" / "Chase one, fly at it").
  - *UIPanel (behaviour):* a head that moves more than
    `UIPanel.HEAD_JUMP_M` (0.5 tracker metres) between frames is followed
    at once (the eye point is re-seated), not eased.
  - *Additive API:* `UIRoot.body_yaw()`, `BODY_STEEP_DEG`,
    `HUD_BODY_SMOOTH_TAU`, `HUD_FOLLOW_MAX_SPEED`; `UIPanel.source_smooth_tau`,
    `source_max_speed_deg`, `HEAD_JUMP_M`;
    `HUD.CARD_TEXT_W`, `CARD_ART_W`, `CARD_TITLE_SIZE`, `CARD_PAD`,
    `CARD_GAP`.
  - *Changed / removed (only the UI and verifier probes read them):*
    `UIRoot.flight_yaw()` is now only the flight path's heading (horizontal
    velocity, NAN below 0.3 m/s x world_scale), no longer the HUD's anchor;
    `UIRoot.SLOW_HEADING_FRACTION` is removed. Correction to the round-5
    note: it was headed "backwards compatible" but removed
    `HUD.DODGE_SEARCH_S` and `HUD.placement_candidates()` (read only by an
    old probe).
- **2026-09-27, integration round 1 (fixer) — world, flight, VR,
  integration; behaviour + additive, backwards compatible** (details in
  `docs/INTEGRATION.md` §8 and the area docs' "Integration round 1"):
  - *World (additive):* `World.is_water(pos) -> bool` (base: false; the
    valley: the lake and the river at the water line). *Behaviour:* the
    shores cross the water steeply (`WorldTerrain.SHORE_DROP` 1.3 /
    `SHORE_RISE` 0.7), the street and square paving is 0.2 m over the
    ground (`village.gd PAVING_TOP`), the bridge deck strip 12 cm.
  - *Flight (behaviour + additive):* a floor contact on water is a splash
    and a hop, never a touchdown, stand or stun (`PlayerBird.WATER_HOP`,
    `contacts["water"]`); `PlayerBird.NEAR_PER_WORLD_SCALE` 0.06 in its
    own dev world-scale path.
  - *VR (behaviour + additive):* `WorldScaleDriver.NEAR_K` 0.06 (§7.5);
    `VRCalibration.first_launch_due()`, `start_first_launch()`,
    `abandon(why)`; `first_launch_prompt` false in main.tscn (Play is the
    gate, `FirstFlightGate`); no recalibration suggestion at app start.
  - *Integration:* `FirstFlightGate` (UIRoot's bridge in main.tscn);
    `QualityTier` picks the Quest tier whenever the OpenXR system is a
    Quest (the simulator too; `--quality=full` for the desktop game there);
    `tools/export_quest.sh` (exports on the tree's own project.godot and
    checks the build's settings); the preset excludes `scripts/game/sim/*`.
  - *For the game loop (not changed, `scripts/game/`):* the whole-game
    catch test's record (INTEGRATION.md §8): most cue-following chases end
    because the target cue names another bird before the player is on the
    first one's tail - worth a look with the pacing re-run.
- **2026-09-27, integration round 2 (fixer) — AI, flight, VR, UI, core
  Settings, integration; behaviour + additive, backwards compatible**
  (details in `docs/INTEGRATION.md` §9 and the area docs' "Integration
  round 2"). **The AI's code changed again (the game loop's pacing
  evidence must be regenerated on it); `scripts/game/` and
  `size_rules.gd` were NOT edited (the game loop's agent was active):
  the game-loop findings are proposed as verified patches in
  `artifacts/integration/round2_gameloop_proposals/`.**
  - *AI (behaviour + additive):* the last `NpcBrain.HUNT_PLAYER_COMMIT_S`
    (0.4 s) of an NPC attack on the **player** is a committed pass: the
    hunter re-aims every `HUNT_PLAYER_REAIM` (3) x its reaction time and
    turns no tighter than `HUNT_PLAYER_TURN` (0.8) of its rate; further out
    it pursues as ever (the mirror of round 1's flee-from-the-player rule;
    NPC-on-NPC hunts unchanged; tuned through the real chain, INTEGRATION
    §9). `NpcBrain.begin_hunt(prey) -> bool` and
    `may_hunt()`. The Ecosystem sets up **show hunts** where the player
    looks (`SHOW_HUNT_*`, `show_hunts`; hunters never the player's threats
    and never ones that would hunt the player; prey of show roles only;
    `stats()["show_hunts"]`, `["show_hunt_catches"]`, `["show_hunt_misses"]`)
    and keeps a hunter with the show's first flock. `MurmurationSwarm`
    (new, `scripts/ai/murmuration_swarm.gd`): visual-only starlings
    (BirdModels, never Birds) wheeling round the murmuration, sized by the
    budget (`Ecosystem.swarm`, `murmuration_swarm`, `stats()["swarm"]`).
  - *Settings (core, additive):* `"turn_comfort": 0.75` (a 4-step bar:
    Gentle 90, Calm 120, Brisk 180, Full 240 deg/s).
  - *Flight (behaviour + additive):* `PlayerBird` caps the rig's (and the
    bank's) yaw rate at the player's choice (`FlightTuning.TURN_COMFORT_*`,
    `turn_comfort_rate()`), never above the tuning's own cap; a raw
    `comfort_max_yaw_rate` setting still wins. A recenter while the game is
    paused re-aims the rig while paused (`_recenter_when_tracked`), so
    Resume never turns the view. `scenes/player/player.tscn` camera near
    0.06 (= `WorldScaleDriver.NEAR_K` at world_scale 1).
  - *VR (behaviour):* the calibration card uses the UI's font and colours,
    every line's capitals >= 1.5 deg (`CalibrationPrompt.FONT_SIZE` 56,
    `HINT_FONT_SIZE` 54, the card grows to fit: `height`), the skip/cancel
    line stays under the pose's problem (`VRCalibration.hint_text()` is
    two lines then), and a seated player reads `PROMPT_SEATED`.
  - *UI (behaviour + additive):* main-menu **Quit is a hold** ("Hold to
    quit"); a **Turn speed** bar in Settings; the catch lesson waits
    `Onboarding.CATCH_TIMEOUT` (300 s) and says "Chase a ringed bird";
    lessons carry `"keys"` (the HUD shows them on the desktop) and How to
    fly's cards desktop captions (`HowToScreen.desktop`, `set_desktop()`).
  - *Integration:* `FirstFlightGate` hides the menus while a manual
    calibration step's card is up and restores them after its result;
    `QualityGovernor` recovers the budget (`ceiling_npcs`, `RECOVER_*`,
    `PULSE_S`); the export excludes `scripts/game/data/*`; the real-chain
    pacing harness (`tests/shots/integration_pacing.*`), its person model
    (`tests/unit/integration/integration_person*.gd`) and stored evidence
    (`tests/unit/integration/data/real_pacing.json`, `real_pacing_test`).
- **2026-09-27, ui (majors round) — behaviour + additive; one removal** (details in `docs/areas/UI.md`, "Majors round")
  - *HUD notices (behaviour):* the lead's rule exactly. A notice fades while
    the flight path, the target, a real threat or a cue chevron is within
    `HUD.FADE_MARGIN_DEG` (1.5) of a plate; the crossing lasts until
    everything is `FADE_HYST_DEG` (1.0) further off and has been for
    `FADE_CLEAR_S` (0.12 s), then the notices fade in over `NOTICE_IN_S`
    (0.28 s). They move (to the mirror placement, eased, at most once per
    `MOVE_GAP_S`) only when something has been on the plates for more than
    `MOVE_AFTER_S` (1 s) of one crossing. Removed: `HUD.MOVE_AFTER_ENTRIES`
    (the "3 crossings in 8 s" move; read only by UI tests). Why: live it
    moved the lesson card up to 4 times in a 35 s tutorial, and one jittery
    pass counted as 2-3 crossings (the round-7 verifier).
  - *Celebrations (behaviour):* a pause keeps a tier-up / apex
    celebration (its clock waits while the HUD is hidden); caught, a menu
    or the run's end still cancel it. `HUD.toast_active()` now means
    running (up, with the HUD shown); `toast_waiting()` is one held by a
    pause.
  - *Cues seen by the notices (behaviour):* `UIRoot.hud_protected_directions()`
    takes each cue from `HudIndicators.cue_direction()` (the camera as it
    is now and the cue's ring angle), not the chevron mesh's last position:
    make_way runs before the chevrons are re-placed and a flying rig moved
    them ~3 deg a frame (phantom covers, the round-7 engineering verifier).
  - *GameLoop's lesson prey (used, duck-typed, optional):* the catch lesson
    calls `GameLoop.request_lesson_prey()` when it begins (before its card
    shows) and again every `Onboarding.CATCH_HELP_S` (30 s) of play without
    a catch, unless the player is closing on a lesson bird (within
    `UIRoot.LESSON_CLOSING_SPANS` 60 wingspans, gaining
    `LESSON_CLOSING_SPS` 4 a second); `release_lesson_prey()` when it ends
    (catch, timeout, skip, reset) and when a run ends; reads
    `lesson_prey()` each frame while taught. It names the species from the
    first live bird returned (only if the pause screen's "Hunt" line has it
    at the player's size), and says "It glows" only if that bird's `model`
    has a `glow` that is true.
  - *Request to gameloop / ai:* a player who never steers at prey is not
    reached by the help: `MothField._place_lesson` puts the swarm
    `maxf(28 - 6 x help, 20)` m ahead along the current heading; an
    orbiting bird passes it 8-13 m off and the lesson times out at 300 s
    (`tests/shots/ui_lesson_real.gd`, passive player: 6 of 6 runs). Nearer
    at the higher help levels, on the player's predicted (curving) path at
    its height, would close it. (A `glow` on the lesson birds' models, if
    the birds area adds one, is read as above.)
  - *Additive API:* `Onboarding`: signals `lesson_changed`, `catch_help`,
    `catch_lesson`; `current_view()`, `teaching_catch()`,
    `set_catch_prey()`, `catch_copy()` (static), `help_ok`,
    `mass_provider`, `CATCH_HELP_S`, `CATCH_HINT_LEVELS`. `GameBridge`:
    `lesson_prey_start/help/stop/birds()`, `lesson_prey_info()` (static).
    `HUD`: `update_lesson()`, `crossings_lately()`, `toast_waiting()`,
    `last_on`, `FADE_HYST_DEG`, `FADE_CLEAR_S`, `NOTICE_IN_S`.
    `HudIndicators.cue_direction()`. `UIRoot`: `notice_causes()`,
    `protected_labels`, `LESSON_CLOSING_*`.
    `UIMockGameLoop` implements the lesson-prey API for the UI's tests.
