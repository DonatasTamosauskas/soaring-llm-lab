# Integration: the whole game

How the eight areas become one game (`scenes/main.tscn`), how to run it on a
desktop, in the Meta XR Simulator and on a Quest, how the whole game is
tested, what it costs, and what is still open. Built 2026-09-26 on Godot
4.7.2 against the areas as they stood that day (flight and VR were still
receiving fixes in parallel; every run below used their code of the moment).
**Integration round 1 (2026-09-27)** fixed the three verifiers' findings:
§8 has each one, its fix, the test that pins it and the mutation run that
shows the test would have caught it. **Integration round 2 (2026-09-27)**
did the same for round 1's review (§9), and measured the brief's pacing
through real flight for the first time: it was not met then (§9, §7); the
game loop's core loop round and its fix round 1 (docs/areas/GAMELOOP.md,
"The evidence") now measure it on fresh held-out seeds (§10.6).
**Integration hygiene (2026-09-27, §10)** closed the last verification's
four open items: the soak's creep traced to bounded caches and its
threshold made principled, `game_flow_test`'s staged catches made honest
(a halved catch reach now fails it), the Quest's depth precision
quantified per size and the valley's coplanar surfaces found and fixed
(307 exactly coplanar spots and 3,289 within 5 mm to 0; the paving's tie
with the grass settled by a polygon offset), and the simulator re-run.
Resumed after a stop, it found the 6-run soak's object test unstable and
sized the soak to 12 runs with a drift test (PASS), and traced two AI
regressions in the composed game (an engine error from the moth swarms, the
Quest tier's sky thin while travelling; §10.5).

Owned files: `scenes/main.tscn`, `scripts/main.gd`, `scripts/integration/`
(new: `LoadingCard`, `UISoundBridge`, `QualityTier`, `QualityGovernor`;
round 1: `FirstFlightGate`; and `tools/export_quest.sh`),
`tests/unit/integration/`, `tests/soak/` (new: the soak, twelve whole runs, kept out
of `tests/unit`), `tests/shots/integration_*`, `artifacts/integration/`,
`export_presets.cfg`, `project.godot`, this document and `README.md`.

---

## 1. Composition

`scenes/main.tscn` is ARCHITECTURE §4, in that order:

```
Main (Node3D, scripts/main.gd: GameMain)
├── World        scenes/world/world.tscn     instance placeholder, built in step "world"
├── Ecosystem    scenes/ai/ecosystem.tscn    placeholder, step "ecosystem"
├── Player       scenes/player/player.tscn   placeholder, step "player" (at World.get_player_spawn())
│   └── XROrigin3D/VRRigExtras               scenes/vr/vr_rig_extras.tscn, added with the player
├── GameLoop     scripts/game/game_loop.gd   created in step "game_loop"
├── UI           scenes/ui/ui_root.tscn      placeholder, step "ui"
├── Audio        scenes/audio/audio_director.tscn  placeholder, step "audio"
├── BirdFX       BirdFXDirector              feather burst on every Events.bird_caught
├── UISounds     UISoundBridge               created with the UI
│   (FirstFlightGate: UIRoot's bridge, Play's gate to the first flight, round 1)
├── XRMirror     scripts/vr/xr_mirror.gd     head-view captures (renders only around a capture)
└── (QualityGovernor, Quest tier in VR only)
```

The heavy scenes are `InstancePlaceholder`s so the scene still shows the
composition in the editor while `main.gd` builds them one step per frame.
Pause modes: World, Ecosystem, Player (its body), GameLoop and the feather
bursts pause with the tree; everything under the XROrigin3D, UI, Audio,
UISounds and the mirror run always (ARCHITECTURE §4, §7.6; asserted by
`test_pause_freezes_play_but_not_the_rig`).

### Startup (BOOT -> MENU)

1. `main._ready` (engine start + scene load + script compile: ~1.0-1.25 s on
   the M1, the runtime's own loading indicator in a headset): a **boot rig**
   (our own XROrigin3D + XRCamera3D, not in `player_rig`), the valley's day
   sky (`WorldSky.make_environment`, identical to the world's), a
   **loading card** (`LoadingCard`: the game's name, what is being
   prepared, a segmented bar; world-locked in rig space, lazily re-centred
   beyond 30 deg, sized by `world_scale`, no depth test), and the audio
   bank's synthesis starts on worker threads (`AudioBank.acquire(true)`).
2. The load steps, each measured (`GameMain.load_report`: time and the
   longest frame gap after it):

   | step | what | M1 headless | M1 in the simulator |
   |---|---|---|---|
   | birds | `BirdModels.prewarm()`: 30 species x LOD meshes | 75 ms | 117 ms |
   | world | `SoaringWorld` generation | 1.3-1.8 s | 1.7 s |
   | player | PlayerBird at the spawn perch + rig extras; the boot rig hands over | 5 ms | 44 ms |
   | ecosystem | Ecosystem; its first step spawns the sky (60 NPCs) | 57 ms | 97 ms (gap 73 ms) |
   | game_loop | GameLoop | 0.1 ms | 0.4 ms |
   | audio | AudioDirector (the bank is already synthesizing) | 0.6 ms | 1 ms |
   | warm_up | 12 frames with the valley behind the card (pipelines) | 15 ms | 181 ms |
   | ui | UIRoot + UISounds; the card goes in the frame the menu appears; `Game.MENU` | 25 ms (gap 50 ms) | 66 ms (gap 112-146 ms) |

   **In the headset the long steps (birds, world, player: ~1.9 s on the M1,
   several times that on a Quest) run before our first frame**: until the
   XR session shows frames of ours the runtime draws its own loading
   indicator (compositor-drawn, head-tracked), so no frame of ours stands
   frozen. Our first frames are the sky and the card; after them the
   longest frame gap is 112-146 ms (the UI's build) in the simulator
   (`loading_never_freezes_a_frame`). On a desktop (and in headless tests)
   the steps run after the card, one per frame (the world is then a
   1.3-1.8 s frame). `--load_mode=stepped|early` forces either.
3. `Game.MENU`: the main menu opens in front of the head (13 deg from the
   gaze in the simulator), the player waits on the spawn perch.

Engine start to menu: 2.8 s headless; 5.7 s in a rendered desktop run
(the steps took 2.0 s, the first drawn frames 1.1 s, the frames drawn
around the steps the rest); ~4.8 s in the simulator (1.8 s engine +
2.8-3.0 s load). Quest estimate: 3-4x the script
parts, i.e. ~6-9 s (most of it behind the runtime's loading indicator).
The audio bank was ready by the menu in the runs checked (it is cached in
`user://audio_cache` after a sandbox's first run; a cold synthesis takes
~2 s of wall time on three threads, AUDIO.md).

### State glue (`main.gd`)

- **The body is still in BOOT, MENU and ENDED** (`PlayerBird.auto_process`
  false; the XR rig keeps tracking): a calm view behind the menus, and arms
  pointing at a menu never fly the bird. It flies in PLAYING and CAUGHT.
  Back in the menu (Quit to menu, Main menu) it is put back on the spawn
  perch. On a desktop it gets one tick on the perch when it spawns, so the
  virtual arms are placed (otherwise the hands sit on the rig's origin and
  the first-person wings cross the view: found in the first menu shot).
- **Desktop mouse**: captured when a run starts or on a click while flying
  (mouse look); the UI frees it in menus.
- **Quit** (menu, window close): `quit_started`, `await
  AudioDirector.shutdown()` (every sound stopped and drained), then
  `get_tree().quit()`. `auto_accept_quit` is off so closing the window takes
  the same path. Exit is clean (only the engine's known
  `1 ObjectDB instance` line).
- **Menu sounds** (`UISoundBridge`): UIScreen actions -> `AudioDirector.
  play_ui` (Play/Fly again/Keep flying/Restart/Quit to menu = confirm, Back
  = back, How to fly/Settings = open, Quit = close, the settings actions =
  select), hover on buttons (debounced 90 ms), settings widgets = click;
  pause open/close stay the director's own.
- **Feathers**: `BirdFXDirector` (not `BirdFX.catch_burst` in GameLoop:
  BIRDS.md allows one of the two).
- **Harness hook**: `--harness=<name>` adds
  `res://tests/shots/integration_<name>.gd` inside the real main.tscn
  (perf, shots, sim); excluded from the Android export.

### Project settings (integration's)

- `xr/openxr/extensions/hand_tracking=false` (explicit): the vendors plugin
  5.1.0 reads it with `get_setting_with_override` while it initializes,
  before Godot's OpenXR module registers it, which printed `WARNING:
  Property not found: 'xr/openxr/extensions/hand_tracking'` in every run
  (headless too). The game uses controllers only (the export preset asks
  for no hand tracking); the value equals Godot's default. **Round 1:** an
  export drops settings equal to their default, so the APK carried no such
  key and the Quest would have warned again; `hand_tracking.android=false`
  is a feature override the export keeps (checked in the exported pack by
  `tools/export_quest.sh`) and the lookup resolves on Android.
- `xr/openxr/extensions/meta/color_space.pc=false` (VR's change during
  integration, ARCHITECTURE "vr (calibration redesign)"): the Meta XR
  Simulator does not offer the plugin's default REC709, so every simulator
  run printed `ERROR: Color space is not supported: 3`
  (`openxr_fb_color_space_extension.cpp`); round 0's
  `starting_color_space.pc=0` only turned it into `WARNING: Recommended
  color space project setting is REC709`. With the extension off on
  desktops neither appears; the Quest keeps the extension and REC709
  (`starting_color_space=3`). (Round 0 of this document described the
  `.pc=0` setting; the round-1 verifiers found the mismatch.)
- Kept from VR's list: `rendering/vrs/mode=2`, foveation 3 dynamic,
  eye-tracked and subsampled off, `user_presence=true`, physics 72.

---

## 2. Running it

```bash
# Desktop (keyboard/mouse): the real tree (settings in the normal user dir)
godot --path . --xr-mode off --rendering-method forward_plus
# ...or a sandbox copy (private user://), e.g. 60 s:
tools/gd.sh play --rendering-method forward_plus res://scenes/main.tscn -- --autoquit=60

# Meta XR Simulator (queues on the machine-wide lock); with the controller
# driver and a verdict (§4, "Simulator"). Every run is a first launch in its
# own user:// (sandbox xr_integ, emptied inside the lock; --keep-user keeps
# it), the verdict reads the log xr.sh names for this run, and the game
# picks the Quest tier by itself (the simulator is a "Meta Quest Pro"):
tools/xr.sh 120 res://scenes/main.tscn
tests/shots/integration_sim.sh --tag=mobile                           # Mobile renderer: fps, draw calls, the gate
tests/shots/integration_sim.sh --tag=fplus --renderer=forward_plus   # clean mirror images
tests/shots/integration_sim.sh --tag=full --quality=full             # the 60-NPC desktop game in the headset

# Quest (after the export in §6: tools/export_quest.sh)
adb install -r build/soaring-quest.apk
adb shell am start -n com.soaring.game/com.godot.game.GodotAppLauncher
adb logcat -s godot:V
```

Desktop controls (DesktopPoseSource, the same WingInput as a headset):
Space flap, W/S wrists down/up (speed / balloon), A/D bank, Q/E one-wing
stroke, Shift tuck (dive), Ctrl/X sweep back/forward, mouse look (click to
capture), wheel stroke size, F/G grip, Esc pause/menu. VR: flap your arms,
tilt the wrists, trigger to click, menu button (left) to pause; B held 0.8 s
= pause, A/X held 1 s = recenter, Y held 1.5 s = recalibrate.

---

## 3. Whole-game tests

```bash
# Default suite (27 tests, ~4 min at load 6-9 since round 1 - the core-loop,
# sky and fleeing-chase tests fly minutes of game time): run with
# --fixed-fps 72 (one physics tick per frame, as fast as the machine allows:
# deterministic and quick)
tools/gd.sh integ --headless --fixed-fps 72 res://tests/runner.tscn -- --suite=unit/integration/ --fresh-settings
# The same without --fixed-fps (e.g. inside a whole tests/unit run): the kit
# then runs the game 3x faster than real time with every tick still exactly
# 1/72 s (216 ticks/s with Engine.time_scale 3)
tools/gd.sh integ --headless res://tests/runner.tscn -- --suite=unit/integration/ --fresh-settings
# The soak: twelve whole runs to the apex (separate: ~14 min of wall time;
# --soak_tag=<name> keeps its JSON apart, --soak_cycles=<n> for a diagnostic)
GD_TIMEOUT=2700 tools/gd.sh integ_soak --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/soak --suite=integration_soak --fresh-settings
# Hygiene diagnostics (§10): the coplanar scan of the drawn valley (JSON by owner),
# the catch-pass lab, the tier-up memory steps with parts switched off
tools/gd.sh ih_cop --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_coplanar --tag=after
tools/gd.sh ih_lab --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_catchpass_lab --fresh-settings --beside_spans=1.7
tools/gd.sh ih_steps --headless --fixed-fps 72 res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_steps --fresh-settings --off=hudtier
```

Everything runs the shipped `scenes/main.tscn` (`quit_for_real` off) and
counts every engine/script error and warning through a `Logger`
(`integration_log.gd`); the suites assert zero. Players are simulated the
way a player plays: menus through the UI's laser pointer API (scripted
`UIPointerSource`s aimed at a button, trigger pulled; holds for
Restart/Quit to menu), or the mouse on the desktop overlay; flight through
flight's `BotPoseSource` (human arm motion into the real `WingInput`) under
`integration_pilot.gd` (holds a height over the terrain ahead, steers at a
target, flies the lessons' gestures; `integration_bot.gd` adds the tuck).
Catches and deaths go through GameLoop's real catch rule: prey is staged on
the flight path as a hovering `NpcBird`, a predator strikes along a scripted
line at the player (`game_kit.gd`). In `game_flow_test` (integration
hygiene, §10.2) the prey hovers level with the player 1.7 of its wingspans
beside the line it flies - between the reach a sparrow has (2.2 spans
centre to centre) and half of it - held there by the kit until the pass
reaches it, the catch assist is the game's own (never pinned), and every
staged catch must be made on its first pass. (Until round 2 the assist was
pinned at full, the prey kept to the player's height until 8 m out so the
bot flew through it, and three passes were allowed: a halved reach passed.)
The soak still stages its prey the old way (it needs growth, not a reach
measurement). The catch itself, the growth, the events, the feathers and the
UI/audio reactions are the game's own.

| suite / test | asserts |
|---|---|
| `game_flow_test` (one game, played in order) | |
| boot | BOOT -> MENU, main menu up, §4 order and pause modes, real valley, >= 50 NPCs, VR extras attached to the player's rig, mirror on the head camera, player still on the spawn perch, every load step reported, 0 errors/warnings |
| play | Play with the laser pointer -> PLAYING, one `run_started`, HUD, lessons start at "spread", a sparrow with 3 lives, the confirm sound; the longest frame while the run starts < 250 ms |
| onboarding | spread, flap, glide, speed, turn, dive completed by the bot's gestures (none by timeout), take-off from the perch |
| catch a moth | a moth 1.7 spans beside the flight line caught on the first pass at the game's own assist (hygiene: a halved reach fails here), `bird_caught(player, moth)`, growth by exactly `SizeRules.meal_gain`, `player_grew` once, one feather burst where it was, the catch cue in audio, the last lesson completes the tutorial |
| grow | wrens (each on its first pass, beside the line) until sparrow -> swallow: one `player_tier_changed`, species follows mass, the HUD shows the celebration naming the swallow and the flight model flies the new mass and span (round 2: mutants breaking either passed), `world_scale` ramps to the new wingspan (never node scale), first-person wings in the swallow's colours |
| pause | menu button -> PAUSED, pause screen; every node under the XROrigin3D processes, UI/audio run; player, NPCs and run clock frozen; resume |
| caught | a hawk's strike -> CAUGHT, a life lost, the caught screen; read at `GameLoop.player_respawned`: at the spawn, on its perch (or hovering there if an NPC sat on the perch at that moment, see §7), protected, the mass cut by exactly `death_penalty()` |
| run end | caught until the lives run out -> ENDED, one `run_ended` (reason caught, catches, peak swallow, score), the summary screen, body still |
| fly again | Fly again (pointer): sparrow mass/species, 3 lives, 0 catches, clocks at 0, peak reset, at the spawn, world_scale snapped back, sparrow wings, the sky rebuilt (>= 50), no lessons for a finished tutorial, start protection |
| restarts leak nothing | 6 x (fly, a catch, pause, hold Restart run), each sample the least over 1.5 s (a bird caught a moment ago waits 0.5 s to be freed): from the second restart on exactly the same nodes, objects within 6 and the last within 6 of the second (NPC count corrected), orphans 0 (round 2: +-6 nodes / +-30 objects over 4 restarts let the verifier's 1 node + 3 objects a restart through) |
| quit | hold Quit to menu -> MENU, spawn perch, body still; a single pull on Quit does nothing (round 2), holding it runs the game's quit path, audio stopped; 0 errors, 0 warnings in the whole game |
| `game_desktop_test` | the desktop overlay: a mouse click on Play; the lesson card names the keys (round 2); Space flaps (strokes credited, take-off, climb), D banks and turns right, Escape pauses, a mouse click resumes; 0 errors/warnings |
| `game_lifecycle_test` | boot, play, free, twice in one process: registry empty, orphans 0, node count back to the baseline, the second game leaves no more objects than the first (+5 of 132 cached) |
| `quality_test` | the Quest tier's values reach the Ecosystem; the governor steps down only on sustained misses, never below its floor, not in menus; round 2: it recovers after 30 s at the refresh, never above the tier's budget, and a rise it cannot hold doubles the next wait |
| `game_first_launch_test` (round 1) | a first launch in the headset (VR emulated): nothing comes up by itself in the menu; Play closes the menu and asks for the spread, the body waits; B skips to the default wings and the run starts after the card; a held spread is captured, then the run starts; the menu button abandons the step and Play asks again; round 2: Recalibrate from the pause menu's Settings hides the menus while the card is up and brings them back as they were |
| `game_catch_test` (round 1; reworked in round 2) | the core loop with real flight: nothing staged, the assist the game's own, 6 minutes of the competent person (`integration_person.gd`: the game loop's modelled competent player flying the real chain) in the real sky: at least 2 catches; NPCs catch each other (>= 5) and hunt the player; every catch's assist recorded exactly (round 1 rounded it to a multiple of 2, so "one by the base rule" could never fail) |
| `chase_fleeing_test` (round 1) | 12 one-on-one chases of a live, fleeing wren in open air through the real chain: median closest approach under 3.5 m (without the AI's flee-from-the-player rule: 4.5 m) |
| `sky_hunt_test` (round 2) | predation from the player's eyes: a protected sparrow on the verifier's lap, 5 minutes at each tier: at least 3 show hunts set up where the player looked and at least 3 NPC-on-NPC hunts readable within 40 m in view (both birds in view for a second); the murmuration's visual mass flies; stoops, dives into cover and catches in view recorded |
| `real_pacing_test` (round 2) | the brief's pacing through real flight, on stored whole runs (`tests/unit/integration/data/real_pacing.json`, `tests/shots/integration_pacing.sh`): per tier, median time to the pigeon 5-8 min and to the eagle 20-30 min, caught at least once in >= 40 % of runs, < 20 % lost, no errors; the evidence played the tree's code and growth tuning (warns; fails with `--strict_evidence`) |
| `sky_view_test` (round 1) | birds a player notices straight along the flight (>= 0.37 deg across) while lapping and while travelling, 90 s each, at the Quest and the full tier: a mean of at least 1 and at least one in half the seconds |
| `game_water_test` (round 1) | gliding down onto the lake: splashes, never grounded, perched or stunned on the water, never under it, flaps away |
| `spawn_perch_test` (round 1) | the AI never offers the player's spawn perch to an NPC; a minute of the real sky: nobody sits on it (`game_flow_test` requires a perched respawn) |
| `depth_precision_test` (round 1) | the Quest's 24-bit depth buffer from ten real viewpoints at a sparrow's near plane: near >= 2x round 0's, no parallel surfaces of distinct bodies within 2 steps under 300 m, distinct-body risk < 0.5 % of each view, shores cross the water at >= 12.5 deg; hygiene: the depth-precision table for every size (§10.3) |
| `coplanar_test` (hygiene) | every triangle the valley draws: no overlap of differently coloured faces within 1 mm that can be seen, none within 5 mm that a sparrow sees fight, the paving's ties with the grass settled by its depth offset (§10.3; 307 / 3,289 / 406 spots before) |
| `tests/soak/integration_soak_test` (reworked in round 1; hygiene) | twelve whole runs, the same each time (menus, a staged strike, growth through every tier, the apex won, Fly again), the bounded caches emptied before each run-start sample: nodes exactly the second run's, objects within 8 of the median start and a drift (last 4 starts' median less the first 4's) of at most 5.5 - one object a run leaked moves it by 8 - static memory's median per-run increment within 1 MB an hour of play, 0 orphans, every run won, 0 errors/warnings (round 2: memory flat within 0.75 MB over the last three starts - fitted, and broken by any new glyph atlas page; hygiene's first version, 6 runs judged by the median per-run increment, failed 2 of 4 leak-free soaks; §10.1) |

Results (round 2, final tree): 30 / 33, 404 assertions, 452 s at load
16-24 - `game_catch_test` fails since the game loop's 05:27 edit and
`real_pacing_test` on the brief and the Quest tier's danger (§9).

Results (round 1, final code, `artifacts/tests/report_unit_integration_.json`):
27/27 passed, 337 assertions, 219.6 s with `--fixed-fps 72` at load 5.6 (the new tests fly minutes of game time; the core-loop, sky and chase tests start their run through the game's bridge so a seed is one run). (Round 0: 16/16, 212 assertions, 38 s.)

Soak (round 2, final code): one run FAILED on a single +2.0 MB step at
its last start (`soak.json`), its re-run PASSED (`soak_rerun.json`: 1640 s
of play, 103 catches, 6 deaths, every run won; starts 288.59-288.89 MB,
objects 11934-11954, nodes 2904-2908, 0 orphans) - §9.

Soak (round 1: `artifacts/integration/soak.json`, `soak_run.log`): six runs,
1886 s of play in 326 s of wall time, 239 cue chases, 119 staged prey, 101
catches, 8 deaths, every run won the apex. Nodes at the runs' starts
2837 (cold), then 2854-2856; objects 11839-11874; 0 orphans; static memory
at the starts 264.5 (cold), 289.6, 291.7, 291.8, 291.9, 291.9, 292.0 MB -
the second run still met first-time content (+2.1 MB; one run measured it
at the second victory), then +0.04-0.10 MB a run; the cycles' peaks 289.8,
292.0, 292.0, 292.3, 292.3, 292.2 MB. A slow creep of ~4 objects and
~0.05 MB a whole run (menus, victory, Fly again) remains to be found; 8
restarts without a victory are flat to +-3 objects and 0.03 MB
(`tests/shots/integration_diag_leak_test.gd`), so it is in the summary /
Fly again / menus path, not the run itself - ~1 MB after 20 runs.

---

## 4. Performance of the composed game

Measured by `tests/shots/integration_perf.gd` inside main.tscn (bracket
nodes around each system in the tree, the systems' own timers, VRProfile):
a run in the valley with the bot flying the orbit and chasing the target
cue, at three sizes (sparrow 60 s, pigeon 30 s, eagle 30 s). ms per frame
(one 72 Hz physics tick per frame), M1 Pro shared with other agents (load
avg 3.4-5.9 during these runs).

| system | headless, 60 NPCs | rendered (Mobile), 60 NPCs | headless, Quest tier (28 NPCs) |
|---|---|---|---|
| flight (PlayerBird.tick) | 0.26-0.28 | 0.31-0.33 | 0.26-0.27 |
| AI + ecosystem (all NPC brains and flight) | 1.21-1.30 | 1.21-1.43 | 0.55-0.62 |
| game loop (catch rule, cues) | 0.34-0.37 | 0.33-0.36 | 0.18-0.20 |
| UI | 0.08 | 0.09 | 0.07-0.08 |
| audio | 0.14 | 0.16 | 0.13 |
| VR scripts (VRProfile) | 0.11 | 0.13 | 0.10 |
| birds' draw sync (BirdBatch) | 0.24-0.25 | 0.26-0.27 | 0.13 |
| world (terrain LOD, wind) | 0.04 | 0.05 | 0.04 |
| **game logic, total** | **2.45-2.53** | **2.53-2.80** | **1.50-1.54** |
| Quest estimate (x3-4) | 7.3-10.1 | 7.6-11.2 | **4.5-6.1** (5.3 at x3.5) |
| all scripts (span of every callback) | 2.2-2.3 | 2.3-2.6 | 1.4 |
| physics server step (Jolt; time from the last physics callback to the first process callback, headless) | 0.26 | - | 0.14 |

`artifacts/integration/perf_cpu_headless_full.json`,
`perf_cpu_headless_quest.json`, `perf_all_rendered_full.json` (and the
exploration `perf_cpu_headless_q40_50_120.json`, `q32_40_100`, `q60_40_100`).
Note: Godot's `Performance.TIME_PROCESS` / `TIME_PHYSICS_PROCESS` are the
worst frame of each second, not means; the table uses our own timers.

**The full game does not fit the Quest target** (<= 5 ms of main-thread
logic in a 13.9 ms frame): 7-10 ms estimated. The cost is linear in the NPC
count: ~0.70 ms fixed + ~0.0275 ms per NPC (AI 0.022, catch sweep and draw
sync the rest); the AI's LOD radii changed it by < 5 % (60 NPCs at 40/100 m
vs 80/200 m: 2.35 vs 2.43 ms).

### Quest quality tier (`QualityTier`, automatic on Android; `--quality=quest` to try it)

- `Ecosystem.max_npcs` 60 -> **28** (the Ecosystem scales its whole plan -
  prey, threats, giants, the murmuration - to the budget), LOD radii 60/140 m.
  Measured 1.50-1.54 ms on the M1 -> **4.5-6.1 ms estimated on the Quest
  Pro** (5.3 ms at 3.5x).
- `QualityGovernor` (VR only): if the frame rate stays under 92 % of the
  refresh for 3 s while playing, the NPC budget drops by 4 (floor 20, 10 s
  cool-down, never back up in a session). The Ecosystem does not respawn
  above the new budget and trims at its next re-plan, so the sky thins
  gradually. Tested with a fake fps source (`quality_test`).
- In the simulator the tier holds 72 Hz: 71.5-71.8 fps, p95 14.2-14.3 ms,
  also at load 7 where the full game drops to 66-68 fps (§4, Simulator).
- **Open:** the game loop's pacing evidence (docs/areas/GAMELOOP.md) was
  run with 60 NPCs; with 28 there is less prey in the sky. The pacing tool
  should be re-run with `max_npcs = 28` (gameloop, next phase), and the
  number confirmed with OVR Metrics on the device.

### Draw calls and primitives

Mobile renderer (the Quest's), one view from the head camera, the UI in its
VR form (3D panels), the sky refilled round the player (7 s) at each place:

| view | size | draws (max) | primitives (max) | NPCs in view |
|---|---|---|---|---|
| main menu on the spawn roof | - | 83 | 96,483 | 27 |
| village street, HUD | sparrow | 87 | 131,439 | 50 |
| over the square looking down | sparrow | 74 | 101,976 | 4 |
| old wood canopy skim | crow | 93 | 123,567 | 3 |
| inside the old wood | sparrow | 68 | 152,935 | 1 |
| orchard and power line | starling | 61 | 86,526 | 4 |
| lake and bridge | pigeon | **97** | **155,504** | 42 |
| cliff colony | swallow | 32 | 43,245 | 5 |
| canyon | hawk | 43 | 55,929 | 2 |
| high over the valley | eagle | 46 | 51,689 | 0 |
| pause menu over the old wood | crow | 91 | 125,212 | 34 |
| eagle over the village | eagle | 52 | 82,256 | 0 |

In the XR simulator (stereo, multiview: one draw per object for both eyes)
over 20 s of flight: headset view **79 draw calls mean, 83 max, 189k
primitives max** (Quest tier: 69/73, 173k), inside the 150 / 300k budget.
Frames in which the HUD SubViewport re-renders (lesson cards, celebrations)
add up to ~75-130 2D draw calls of that texture (`draw_calls` total max
157-211 in `sim_result_*.json`); UI.md already notes the per-frame HUD
renders during celebrations.

### Simulator (Meta XR Simulator 207, "Quest Pro", 72 Hz)

`tests/shots/integration_sim.sh` (`artifacts/integration/sim_result_<tag>.json`,
`sim_run_<tag>.log`, driver `sim_driver_<tag>.log`), 10 checks in round 0,
12 since round 1:

Round 1: the game picks the Quest tier whenever the OpenXR system is a
Quest (`QualityTier.quest_system()`: the simulator reports "Meta Quest
Pro"), so the simulator runs judge the tier that ships (`--quality=full`
for the 60-NPC game); every run is a first launch in a private user://
(emptied inside the lock); the verdict reads the log `xr.sh` names for
this run (round 0 copied the newest `run_*.log`, and once judged another
agent's run); and two checks were added: **no_card_over_the_menu** and
**first_flight_gate** (Play closes the menu, VR's card asks for the spread,
the driver spreads the real controllers and holds still, the capture
comes - 10.1-10.3 s after the card, span 1.66-1.68 m - and only then the run
starts; `sim_mobile_calib_card.png`, `sim_fplus_calib_card.png`).

1. session FOCUSED; 2. physics tick = refresh (72 Hz);
3. loading: the long steps before our first frame (1.76-1.89 s), then the
   card; the worst frame gap after the first frame 109-146 ms, the menu
   2.8-3.0 s after main;
4. the main menu in front of the head (Play 13.3 deg from the gaze);
5. **the real right controller's laser on Play and its real trigger start
   the run**: the driver moves the controller with the simulator's own
   keys (MOVE_UP) until the game reports Play hovered, then presses T
   (`Btn_quit -> Btn_settings -> Btn_howto -> Btn_play`, one pull);
6. **the wings in the mirror**: after flight's SIM-05 spread (controllers
   out along the arms), a glance at each wing (the head view turned 55 deg
   and 25 deg down, wings shown vs hidden): 9.1-9.5 % of the view is wing;
7. **real controller strokes credit wingbeats**: 8 `player_flapped`
   (strength 1.0) through the real XR pose source and WingInput;
8. frame rate over 20 s of play (below);
9. draw budget: the headset's 3D view 79-81 mean, 82-84 max draw calls,
   189-191k primitives (Quest tier 69-70 / 73-74, 173-181k);
10. no error or warning in the full log (the engine's exit messages
    excepted, as in every area's runs; the vendors plugin's hand-tracking
    WARNING and color-space ERROR are gone).

| run (Mobile renderer, 72 Hz) | machine load | fps (>= 68.4) | p50 / p95 / p99 ms | frames > 1.5 intervals | verdict |
|---|---|---|---|---|---|
| full, 60 NPCs (early-load code, first run) | n/r (3-6 that hour) | 71.31 | 13.89 / 14.59 / 18.24 | - | PASS |
| full, 60 NPCs | n/r (3-6 that hour) | 69.64 | 13.91 / 16.11 / 27.48 | - | PASS |
| full, 60 NPCs (`sim_result_mobile_load8.json`) | 8.1 | 67.55 | 13.95 / 25.57 / 27.94 | 89 (6.6 %) | FAIL (fps only) |
| full, 60 NPCs (`sim_result_mobile.json`, final) | 6.9 | 66.32 | 13.97 / 26.06 / 28.81 | 114 (8.6 %) | FAIL (fps only) |
| Quest tier, 28 NPCs | n/r (3-6 that hour) | 71.51 | 13.89 / 14.24 / 18.16 | - | PASS |
| Quest tier, 28 NPCs (`sim_result_quest.json`, final) | 7.1 | **71.79** | 13.89 / 14.28 / 16.26 | 6 (0.4 %) | **PASS** |
| **Round 1**, Quest tier chosen by itself, first launch through the gate (`sim_result_mobile.json`) | ~7 | **71.69** | 13.89 / 14.20 / 15.81 | - | **PASS (12 checks)** |
| Round 1, Forward+ (`sim_result_fplus.json`: clean images; not an fps run) | ~7 | 37.80 | 27.75 / 28.14 / 29.08 | - | PASS |
| Hygiene, quiet moment (`sim_result_quiet1.json`) | 6.4 | 70.65 | 13.89 / 14.51 / 26.98 | 27 (1.9 %) | PASS (12 checks) |
| **Hygiene, final tree** (`sim_result_hygiene.json`) | 5.4 | **71.35** | 13.89 / 14.32 / 19.78 | 13 (0.9 %) | **PASS (12 checks)** |

The load was other agents' Godot runs (three game-loop pacing simulations
at ~100 % CPU each during the final runs). The median frame is on time in
every run; the full game's tail follows the machine's load (the VR area saw
the same with its stand-ins above load 12), while the Quest tier holds 72 Hz
at the same load: on this Mac too, the NPC budget is what decides the
frame rate. Images: `sim_fplus_*.png` (Forward+, clean: `menu`, `play`,
`spread`, `look_left_wing`, `look_right_wing`, `after_strokes`, `flight`),
`sim_mobile_*.png` / `sim_quest_*.png` (the Mobile renderer's mirror shows
MoltenVK's magenta tiles on this Mac). The uncontrolled flight after the
strokes ends where the fixed controllers send it (in `sim_fplus_flight.png`
inside a house it flew into).

---

## 5. Evidence (`artifacts/integration/`)

- Desktop screenshots, Forward+, from the head camera (UI in its VR form,
  90 deg field of view), `tests/shots/integration_shots.gd`:
  `shot_menu.png` (menu in the valley, laser on Play), `shot_first_flight.png`
  (over the village, lesson card, a wing), `shot_chase.png` (a wren with its
  edible ring), `shot_catch_feathers.png` / `_later.png` (the burst, from an
  observer camera beside the catch: at the head it flies past the eyes),
  `shot_tier_up.png` ("Now a Swallow!"), `shot_danger.png` (a hawk striking,
  the danger triangle), `shot_caught.png`, `shot_summary.png`; `shots.json`.
- `perf_*.json`, `soak.json`, `soak_run.log`, `sim_*`, `export_attempt*.log`.

```bash
tools/gd.sh integ --rendering-method forward_plus --resolution 1280x960 res://scenes/main.tscn -- --harness=shots --fresh-settings
tools/gd.sh integ --headless --fixed-fps 72 res://scenes/main.tscn -- --harness=perf --perf=cpu --fresh-settings [--quality=quest]
tools/gd.sh integ --fixed-fps 72 --resolution 1280x720 res://scenes/main.tscn -- --harness=perf --perf=all --fresh-settings
```

---

## 6. Android / Quest export

`export_presets.cfg`, preset **"Meta Quest"** (QUEST.md §5, option names
checked against the 4.7.2 editor and vendors 5.1.0 binaries): gradle build,
APK, arm64-v8a only, OpenXR (`xr_mode=1`), Meta plugin only, Quest 2/3/Pro,
no hand/eye/face/body tracking, no passthrough, package `com.soaring.game`
(change before publishing), debug-signed, `tests/*`, `artifacts/*`,
`scenes/dev/*`, `docs/*`, `tools/*`, `build/*`, `scripts/game/sim/*` excluded.

Outcome (`artifacts/integration/export_attempt1.log`, `_attempt2.log`):

1. Without a build template: *"Android build template not installed in the
   project"* (the only configuration error: the preset is otherwise valid).
2. With the 4.7.2 template installed into the export sandbox (unzipped
   locally from the installed `android_source.zip`, `android/.build_version`
   = `4.7.2.stable`; no download) and AGP's SDK auto-download turned off
   (`android.builder.sdkDownload=false`, so gradle could not fetch the
   missing NDK behind our back): **the debug export succeeds** -
   `build/soaring-quest.apk`, 97 MB, gradle build, signed with the debug
   key, `minSdk 29 / targetSdk 36`, `libgodot_android.so`,
   `libopenxr_loader.so`, `libgodotopenxrvendors.so`, OpenXR permissions,
   `android.hardware.vr.headtracking`, `com.oculus.supportedDevices =
   quest2|quest3|quest3s|questpro`, the VR / IMMERSIVE_HMD intent categories.
   Not installed on a device (none attached).

**Round 1:** `tools/export_quest.sh [debug|release|pack] [out]` exports on
the tree's own `project.godot` (tools/gd.sh writes a sandbox-only
`use_custom_user_dir` / `custom_user_dir_name` into its copies, and round
0's APK carried them) and checks the build: no sandbox user dir; the
settings the game relies on present (`hand_tracking.android`, the Meta
colour space, user presence); no `scripts/game/sim/` (the game loop's
pacing tooling, now excluded by the preset). Rebuilt from the round-1 tree:
`build/soaring-quest.apk`, 97,139,967 bytes, PASS
(`artifacts/integration/export_round1.log`). Not installed on a device.

```bash
# The build template goes into the sandbox the export runs in (tools/gd.sh
# never syncs /android/). Godot can install it itself
# (--install-android-build-template with --export-debug), but then gradle
# may fetch the missing NDK on its own; the verified path unzips it by hand
# and keeps gradle from downloading SDK parts:
( cd .sandboxes/export && mkdir -p android/build && cd android/build \
  && unzip -q ~/Library/Application\ Support/Godot/export_templates/4.7.2.stable/android_source.zip \
  && printf 4.7.2.stable > ../.build_version && touch .gdignore \
  && printf '\nandroid.builder.sdkDownload=false\n' >> gradle.properties )
tools/export_quest.sh debug "$PWD/build/soaring-quest.apk"   # round 0: tools/gd.sh export --export-debug ...
```

Missing for a release build: the template's `ndkVersion` is
**29.0.14206865** and only 26.1 is installed (the debug build did not need
it: gradle packages the prebuilt libraries); install it with
`sdkmanager --sdk_root=/opt/homebrew/share/android-commandlinetools "ndk;29.0.14206865"`
(~1+ GB, not downloaded here) and create a release keystore
(`keytool -genkeypair -v -keystore soaring-release.keystore -alias soaring -keyalg RSA -keysize 2048 -validity 10000`,
then the preset's `keystore/release*` options). `addons/godot_meta_toolkit`
(Platform SDK, unused) still adds `libgodot_meta_toolkit.so` and
`libovrplatformloader.so` (~3.5 MB) to the APK; removing the addon is
safe for sideloading (QUEST.md §5).

---

## 7. Known limits and findings for other areas

(Round 0's findings for VR, AI and the respawn perch are fixed: §8; round
1's in §9. This section is as of integration round 2.)

- **Game loop (its fix round 5 ran alongside this round; `scripts/game/`
  and `size_rules.gd` were not edited here - the findings go to it with
  patches tested on its suite in a private copy,
  `artifacts/integration/round2_gameloop_proposals/`):**
  - *The brief's pacing is not met through real flight* (§9, "Pacing
    through real flight"): 16 whole runs of the game loop's own modelled
    competent player flying the real chain on the final code - the full
    tier's median run never reaches the pigeon (1 of 8 did), the Quest
    tier's at 25 min (5 of 8); no run reached the eagle; ~0.25 catches a
    minute, and 86-96 % of the catches needed the game's catch assist. The
    pacing model (SimPilot flying NPC physics) and real flight disagree
    ~3-4x; the game loop's tuning, its pacing evidence and this evidence
    have to be reconciled (a real-chain batch: `tests/shots/integration_pacing.sh`,
    ~25 min for 16 runs at five workers).
  - *Pacing evidence:* the stored real-chain evidence played code
    `1814c9d36527e7d4` (the tree at 05:15, the game loop's fix round 5 as
    of 04:42); the game loop edited `threat_watch.gd` and
    `integrated_sim.gd` at ~05:27, so `real_pacing_test` warns (and fails
    with `--strict_evidence`) until the batch is re-run on its final code.
    The AI changed in round 2 (committed passes at the player, show hunts,
    the murmuration's mass): the game loop's own evidence must be
    regenerated on it too.
  - *Its 05:27 `threat_watch.gd` edit breaks the core loop through real
    flight* (§9): `game_catch_test` fails on the tree - 0 catches in 6
    minutes, 63 of 77 chases wedged in trees and houses - and passes with
    the 05:10 file put back (3 catches;
    `artifacts/integration/round2_mutants/gameloop_0527/`).
  - *The first tier-up* (adopted: `FIRST_TIER_GRACE_S`, 45 s): 0 of 7
    first tier-ups at either tier were followed by a death within 30 s.
  - *Danger marks* still go on every bird that can eat the player within
    range - the show's murmuration shows 8-12 marks in `sky_*_murmuration_zoom.png`,
    `shot_tier_up.png` and `sim_mobile_after_strokes.png`:
    `threat_watch.patch` (refreshed against fix round 5; danger 15/15,
    threat 23/23 on the patched copy) marks only birds hunting (anyone),
    within 3 s of it, or named.
  - *The target cue* still changes 8.4 times a minute at the full tier
    (3.4 by preference) and 5.8 at the Quest tier (2.1 by preference) in
    real-chain play (the verifier: 5-19); fix round 5's
    `target_commit_s` landed after the evidence batch had started.
  - *Tooling:* the game loop's frozen-copy pacing workers
    (`.sandboxes/gl_frozen_src/.sandboxes/gl_p*`) see the shared
    `artifacts/` through a link and import it (~1900 `*.import` files
    written beside every area's images; integration's own batches did the
    same until round 2 - `integration_pacing.sh` now gives its copy a real
    `artifacts/` with only `integration/` linked).
  - `ERROR: 7 resources still in use at exit` at the end of the game suite
    (round 0) is the game loop's.
- **UI:** the target cue's colours (teal / coral) still differ from the
  birds' highlights (blue-violet / magenta) - a look-and-feel decision for
  the UI and birds areas together.
- **Comfort (flight / VR, to try on the Quest Pro):** the turn-speed
  setting's default (Brisk, 180 deg/s) and its steps are a first guess;
  respawns, new runs and Quit to menu still cut the view to the spawn in
  one frame (no fade).
- **Quest performance is still an estimate** (§4): means and tails on the
  M1 x3-4; OVR Metrics on the Quest Pro decides the NPC budget. The
  governor now recovers the budget after 30 s at the refresh. The frame
  tail tool (`tests/shots/integration_frame_tail_test.gd`, Quest tier, 180
  s of chase play) could only run at load 20-22 this round: p50 1.81 ms,
  p95 8.4, p99 14.2, max 30.8 ms of CPU a frame on the M1 - scheduler
  preemption dominates it; a run on a quiet machine, and the device's own
  tails, are due. The round-2 simulator run (Mobile, 72 Hz) failed its
  frame rate at load 20-31 (48.4 fps, the governor thinned the sky to 20
  NPCs); round 1's passed at load ~7 (71.69).
- **Being eaten at the Quest tier** (AI + game loop): with the committed
  pass (0.4 s at 0.8 of the rate) the person was caught in 6 of 8 full-tier
  runs but 2 of 8 at the Quest tier (the 28-NPC sky has few raptors; every
  death was by a crow) - under the 40 % the game loop's thresholds ask.
  A per-tier attack window or more raptors in the Quest tier's sky need a
  pacing re-run.
- **Show hunts are few** (AI): most attempts find no pair (60-94 a
  5-minute flight): for a small player every raptor is a threat, and a
  show hunt never uses one (AI.md, "Integration round 2").
- **The soak's residue** (§9): traced in the hygiene round (§10.1) - the
  fonts' shaped-text caches, the glyph atlases, the polyphonic players'
  finished voices and three memo tables, all bounded; none is a leak. For
  the UI: `UIScreen.fit_size` opens a glyph cache (and a 2 MB atlas page)
  for every size it tries - a tested proposal halves the headline's atlas
  memory (`artifacts/integration/hygiene_ui_proposal/`).
- **Depth precision** (hygiene, §10.3): quantified per size; the few-mm and
  exactly coplanar surfaces fixed and pinned (`coplanar_test`); left for
  the world area: 5,466 spots with gaps of 1-30 cm that a sparrow sees
  fight beyond 38-150 m (panelling, the barn's boarding, stand-ins). A
  look at the village, the lake shore and the bridge as a sparrow on the
  device is still due.
- **Loading in the headset:** the valley's generation (1.6 s on the M1,
  ~5-7 s estimated on a Quest) runs before our first frame, under the
  runtime's loading indicator; a cold launch with `adb logcat` on the device
  must confirm no "not responding" warning (splitting the generation across
  frames is world-area work).
- **HUD re-renders** add up to ~130 2D draw calls in those frames (§4).
- **Flight (API note):** `PlayerBird._find_world` looks for the World once
  per tick; a player created before the world whose tick is off never finds
  it (integration spawns the player after the world, as §4 says).
- **DESIGN.md vs the calibration:** the brief says "calibration of reach
  and neutral wrist angle (automatic, with a manual recalibrate)"; the
  prompted step (at the first Play, and on request) is **the lead's
  decision** (ARCHITECTURE, "vr (calibration redesign, the lead's
  decision)"). DESIGN.md's wording predates it and is the lead's to update.
- **AI suite timing:** `perf_test`'s 2.0 ms gate (60 NPCs) passes when the
  shared Mac is not overloaded (1.53 ms at load 6.8; 2.36 ms at 10.5 -
  scheduler preemption); the threshold is not weakened.
- **Engine exit noise** in simulator runs (the OpenXR spatial-entity
  disconnect and 2 InteractionProfile RIDs) is present in every area's runs
  and not caused by the game.

---

## 8. Integration round 1: the verifiers' findings

Three verifiers (experience, engineering, Quest) reviewed round 0. Each
finding, what was wrong, the fix, and the test that pins it. **Mutation
runs:** every fix below was removed again in a private copy of the tree
(never the tree itself; `artifacts/integration/round1_mutants/mutrun.sh`
with the `mut_*.py` there) and its test run on that copy - results in
`artifacts/integration/round1_mutants.txt`.

| Finding (severity, lens) | Fix | Pinned by | Test on the copy without the fix |
|---|---|---|---|
| No pilot flying the real player bird catches real prey (major, experience) | The competent real-chain pilot (`integration_chase_pilot.gd`: 0.22 s tracking delay, under-led intercept, glide in the last second; 10 of 12 hovering targets). The AI: a bird fleeing the **player** holds each escape line 10x longer and turns at most 0.55 of its rate (`NpcBrain.FLEE_PLAYER_REAIM/TURN`): it weaved away from every correction a person makes, 0 of 12 fleeing wrens, 4.5 m median closest approach | `game_catch_test` (cue-following play, nothing staged, the game's assist: 3 catches in 6 min, 2 by the base rule, on the test's seed; 3-5 on seeds 11, 17, 23 and in earlier states of the sky); `chase_fleeing_test` (5 of 12 fleeing wrens caught, median closest approach 1.76 m; 0-3 of 12 at 2.2-2.7 m in earlier states of the sky) | `chase_fleeing_test` FAILS (4.53 m, 0 of 12). `game_catch_test` passes without the rule too (3 catches): whole-game catches are mostly of birds not fleeing yet |
| The sky looks empty from the player's eyes, worst on the Quest tier (major, experience) | The Ecosystem's **show**: flocks, the murmuration and big birds that are life and scale (never prey or threats) homed ahead of the flight, round a lap's curve; the murmuration forms at any budget (>= 8) | `sky_view_test` (both tiers, lap and travel, 90 s each; full tier: mean >= 1.5 noticed birds, one in 55 % of the seconds; Quest tier: >= 0.75, 35 %). Final run: full lap 2.3 / 77 %, travel 4.8 / 90 %; Quest lap 4.0 / 88 %, travel 0.9 / 54 %; over four skies full 2.0-7.9 / 60-99 %, Quest 0.9-4.5 / 41-88 %. The verifier: 0.05 (full) / 0.0 (Quest) | FAILS (Quest lap 0.42 / 28 %, travel 0.50 / 28 %; full travel 0.74 / 20 %) |
| First-launch calibration card over the main menu; Play cancelled it silently (major, engineering + Quest) | Play is the gate (`FirstFlightGate`): the menu closes, the card asks, the run starts after the capture or an explicit skip; nothing comes up by itself; the menu button abandons | `game_first_launch_test` (4 tests); simulator checks `no_card_over_the_menu`, `first_flight_gate` (real controllers, PASS) | FAILS (7 checks: card by itself, Play started the run, ...) |
| SCRIPT ERROR at `npc_brain.gd:602`, hidden by the kit (major, engineering) | Read untyped and checked; `Ecosystem._remove` clears other birds' references; the kit's workaround removed | `flee_test.test_alarm_from_a_freed_hunter_raises_nothing`, `ecosystem_test.test_a_removed_bird_leaves_no_references_behind` | FAILS |
| The soak failed on the tree; its threshold depended on timing (major, engineering) | Judged by repeating the same content: six whole runs to the apex; staged prey edible by its own mass (a run once sat 700 s as a hawk chasing uneatable gulls) | the soak (§3): PASS | - |
| Game suite fails: pacing evidence stale (major, engineering) | Not fixed here: `scripts/game/` was changing all round (the game loop's own agent). §7 | - | - |
| Predicted z-fighting on the Quest: 24-bit depth, 4 mm near plane (major, Quest) | Near plane 0.06 x world_scale (VR; flight's dev path too); shores cross the water steeply; the paving 0.2 m over the grass; the bridge's deck strip 12 cm | `depth_precision_test` (ten views), `near_plane_test` (no feather clipped) | FAILS with near 0.03, with round 0's shores, and with 0.1 m paving (77 px of street over grass from 45 m up) |
| Respawn hovers when an NPC sits on the spawn perch (minor, engineering) | The AI never offers that perch (`Habitat.find_perches`) | `spawn_perch_test`; `game_flow_test` requires a perched respawn | FAILS |
| The bird stands on lake and river water (minor, experience) | `World.is_water`; flight splashes and hops, never lands, stands or stuns on water | `game_water_test` | FAILS |
| Full game fails the simulator's fps under load; runs never used the Quest tier (minor, engineering) | The tier follows the OpenXR system (a Quest, the simulator included); `--quality=full` for the 60 NPCs | `quality_test.test_the_quest_tier_follows_the_openxr_system`; simulator 71.69 fps at load ~7 | FAILS |
| `test_restarts_leak_nothing` missed 20 nodes a restart (minor, engineering) | Tight bounds from the second restart on (the previous fixer) | `game_flow_test.test_restarts_leak_nothing` | FAILS with the verifier's mutant |
| `integration_sim.sh` could judge another agent's log; shared user:// (minor, engineering + Quest) | The log `xr.sh` names; a private, emptied user:// per run (`XR_SANDBOX`, `XR_FRESH_USER`); per-run IO files for the driver | the simulator runs (§4) | - |
| The APK carried the sandbox's user dir, lacked the hand_tracking key, shipped dev tooling, was stale (minor, engineering + Quest) | `tools/export_quest.sh`; `hand_tracking.android=false`; `scripts/game/sim/*` excluded; rebuilt | the script's own checks (PASS) | - |
| Calm NPCs integrated in lockstep (minor, Quest) | Tick phases from the Ecosystem (`NpcBird.set_tick_phase`) | `tick_phase_test` (busiest tick 1.04x the mean) | FAILS |
| A steep perch approach entered its flare 45 deg nose-down (found here) | `NpcBird._body_pitch` holds the body within 0.5 rad nose-down on a perch approach | `landing_test` (now also with tick phases) | FAILS (53 deg) |
| Docs described a colour-space setting project.godot no longer had (minor, all three) | §1 and ARCHITECTURE corrected | - | - |
| "New player? Recalibrate wings" after every launch (minor, experience) | No suggestion at app start with a saved calibration (the previous fixer) | `calibration_flow_test` | - |
| First-flight screenshot without card or HUD (minor, engineering) | UI round 5 put the HUD on the flight direction; the shot looked at the church, beside the path: it now looks along the flight | `shot_first_flight.png` (lesson card and size bar in view) | - |
| Quest CPU estimate from averages; governor never restores (minor, Quest + engineering) | Lockstep removed (above); estimates unchanged | - | open (§7) |
| Main-menu Quit a single pull; desktop cards show no keys; cue colours (minor, experience + engineering) | Not changed: `scripts/ui/` had its own fix round running | - | open (§7) |
| Turn comfort / no fade on teleports (minor, experience + Quest) | The misleading "behind a fade" comment corrected | - | open (§7) |
| AI suite 196 s (minor, engineering) | Not shortened (its valley soak even grew to 240 s: in 90 s one seed's sky made 3 catches by one species; 10 minutes: 42 by 8 with the show, 42 by 7 without) | - | open |

**Suites after the round (final code):** integration 27/27 (337 assertions, 219.6 s);
flight 182/182 (60.8 s); vr 160/160 (30.5 s); world 39/39 (18 s); ai 76/76
(219.5 s); the soak PASS (six runs); simulator Mobile PASS 12/12 and
Forward+ PASS (§4). The game loop's suite was not run for a verdict here:
its evidence is being regenerated by its own agent (§7).

**What the AI changes mean for the game loop:** the AI's code hash is now
`4c29ce769e7e7796` and the world's `79c0bb5c7f3cc938` (IntegratedSim's
`sky_code`). The pacing evidence must be regenerated on them (ARCHITECTURE,
"integration round 1").

**Evidence:** `sky_quest_*.png` / `sky_full_*.png` (the head view along the
flight while lapping, with the birds a player notices listed in
`sky_shots.json`), `shot_*.png` (desktop, all looked at), `sim_mobile_*.png`
/ `sim_fplus_*.png` (the headset's mirror: menu without a card, the card
alone after Play, the capture, the flight), `chase_lab_*.json` (the
one-on-one lab), `soak.json`, `export_round1.log`.

---

## 9. Integration round 2: the verifiers' findings

Three verifiers (experience, engineering, Quest) reviewed round 1. Each
finding, what was wrong, the fix, and the test that pins it. **Mutation
runs:** every fix was removed again in a private copy of the tree
(`artifacts/integration/round2_mutants/mutbatch.sh`, `mutrun.sh` and the
`mut_*.py` there; the tree is never touched) and its test run on the copy -
results in `artifacts/integration/round2_mutants.txt`.

**The game loop was not edited.** Its agent was working through this whole
round (its fix round 5: `scripts/game/` changed until 04:42), so the
game-loop findings are reported with proposed patches, each run against the
game loop's own suite in a private copy
(`artifacts/integration/round2_gameloop_proposals/`: `apply.py` applies
them). The game loop **adopted** round 2's first-tier grace
(`GameLoop.FIRST_TIER_GRACE_S` 45 s, "adopted in fix round 5") and replaced
the cue-hold proposal with its own (`ThreatWatch.target_commit_s`); what is
left is the danger-mark patch, refreshed against its fix-round-5 files
(`threat_watch.patch` with `danger_test.patch` / `threat_test.patch`:
danger 15/15 and threat 23/23 on the patched copy).

### Majors

| Finding (severity, lens) | Fix | Pinned by | Test on the copy without the fix |
|---|---|---|---|
| `game_catch_test`'s "catch by the base rule" could never fail: the assist was recorded with `snappedf(x, 2)` - to a multiple of 2 - so every assist under 1 read 0 (major, engineering) | Recorded exactly. Recorded that way, every one of round 1's catches was assisted, so that claim is withdrawn (§8's row stands corrected here). The test now plays the **competent person** (below) for 6 minutes and pins what is true: >= 2 catches with the game's own assist, NPCs catching each other (>= 5) and hunting the player; each catch's assist is recorded | `game_catch_test` (on the tree at 05:15: 3 catches at assists 0.59 / 0.52 / 0.41, none without it; **fails on the tree after the game loop's 05:27 `threat_watch.gd` edit** - 0 catches, see below) | FAILS with NPCs that never catch (`no_npc_catches`) or never hunt the player (`npcs_ignore_player`) |
| Real-chain growth far slower than the brief (major, experience; major, engineering and Quest: nothing showed the brief's pacing on the final code, the Quest tier missed it) | **Not fixable outside the game loop** (its growth and catch tuning). What integration adds, so the game loop can tune against the real chain: a **competent person** that flies the real chain with the game loop's own person model (`integration_person.gd`: SimPilot's cue reading, evasion, breaking across attacks, chase and give-up rules; `integration_person_pilot.gd`: looks where it flies, steers round obstacles, backs out of a wedge), a whole-run **pacing harness** at both tiers (`tests/shots/integration_pacing.sh`: frozen-copy batches, one part file per run with the code fingerprint; `integration_pacing_merge.py`) and **`real_pacing_test`** on the stored evidence (`tests/unit/integration/data/real_pacing.json`). Measured: the final code (fingerprint `1814c9d36527e7d4`), 16 whole 30-minute runs (seeds 5-41) - see "Pacing through real flight" below: the full tier's median run never reaches the pigeon (1 of 8 did), the Quest tier's at 25.0 min (5 of 8); no run reached the eagle (the brief: 5-8 and 20-30 min) | `real_pacing_test` (**FAILS: the brief is not met through real flight**) | - |
| NPC attacks on the player could not be evaded through the real chain (found here with the person: 3-4 deaths a run at both tiers, every one while evading from behind after 2-6 s of warning) | AI: the last `NpcBrain.HUNT_PLAYER_COMMIT_S` of an attack on the player is a committed pass (holds its line between re-aims every `HUNT_PLAYER_REAIM` x its reaction time, turns at `HUNT_PLAYER_TURN` of its rate). A first version committed the whole pursuit: 0 deaths in 16 whole runs - also wrong ("happens but is avoidable"). Swept through the real chain: the last 0.8 s at 0.6 of the rate - caught in 3 of 16 runs; 0.3 s at 1.0 - 5 of 6, one run lost; **0.4 s at 0.8** (final) - in the final evidence the full tier's person was caught in 6 of 8 runs (1.0 deaths a run, none lost), **the Quest tier's in only 2 of 8** (its 28-NPC sky has few raptors; every death was a crow's): the full tier meets the game loop's "at least 40 % caught, under 20 % lost", the Quest tier does not (§7) | `player_test.test_an_attack_on_the_player_can_be_broken` (9 of 9 well-timed breaks escape; a player that does not break is caught 3 of 3); `real_pacing_test.test_being_eaten_happens_but_is_avoidable` | FAILS (0 of 9 escape) |
| The first tier-up is punished within ~10 s (major, experience: a crow took the new size 9-13 s after "Now a Swallow!" in 4 of 10 real-chain runs) | Game loop, **adopted** in its fix round 5: the first flight ends with a 45 s grace for the new size (`FIRST_TIER_GRACE_S`), also after the 300 s cap | its `danger_test`; the pacing evidence: deaths within 30 s of the first tier-up 0 of 7 at each tier | - |
| Predation never on screen (major, experience: 130 NPC catches in 12 min, none within 60 m in view) | AI: **show hunts** (`Ecosystem.SHOW_HUNT_*`) set a hunt up where the player looks - never with the player's prey or threats, never with a hunter that would hunt the player; a hunter kept with the show's flock. **Partly fixed.** Over three seeds x two tiers (5 minutes each): readable hunts within 40 m 28 with the show hunts (1-7 a flight), 17 without (1-5); a hunt in view 0.7-5 % of the time with them, 1.5-2.4 % without; NPC catches seen within 40 m 0-1 a flight either way (the show's catches mostly happen after the player has flown past). Most attempts find no pair (60-94 a flight): for a small player every raptor is a threat, and a show hunt never uses one (AI.md; §7) | `sky_hunt_test` (both tiers, 5 min each: >= 3 show hunts set up in view, >= 3 hunts readable within 40 m, the murmuration's mass flying) | FAILS (0 show hunts; readable hunts alone 4 / 3 on the test's seed - see the text) |
| A sparrow yaws the view at ~205 deg/s, no comfort setting (major, experience; minor, Quest) | Settings **Turn speed** (Gentle 90 / Calm 120 / **Brisk 180, the default** / Full 240 deg/s) caps the rig's yaw rate and the bank that makes it (FLIGHT.md, UI.md) | `player_bird_test.test_pb28_turn_comfort_setting_caps_the_turn` (full-input peaks 90 / 120 / 170 / 207 deg/s), `ui_pointer_test` | FAILS |
| Danger triangles mostly on the murmuration (major, experience: to a sparrow its starlings were 64-69 % of the marks in view, and never attacked) | Game loop: **proposed** `threat_watch.patch` - a danger mark only on a bird hunting (anyone) or within 3 s of it, or the named threat; not on a big bird cruising or wheeling in a flock. Not applied (the game loop's file; its agent was active in it at 04:34). `shot_tier_up.png` still shows the marks on the murmuration | the proposal's `danger_test` / `threat_test` on the patched copy (15/15, 23/23) | the proposal's new `danger_test` assertions fail on the current file |
| The soak failed (major, engineering) | Round 1's soak failure was a cycle cut at 15 minutes: the plain bot sat as an eagle in the corner between the church's tower and nave. The soak's bot now flies with the person's eyes (`integration_person_pilot.gd`: steers round what is in the way, backs out of a wedge). The creep of objects, measured path by path (`tests/shots/integration_diag_leak_test.gd`): 16 menu round trips +1, 8 victories with growth through every tier +-3, 10 deaths and respawns +-4, 8 restarts with staged catches +-3, 8 x 3 minutes of play flat - each alone is flat, yet a whole soak cycle gains 3-4 objects and ~0.05 MB (the memory: two bounded static caches, `FlapDetector._ref_cache` and `NpcFlight._table_cache`, capped at 4096). **On the final code one soak FAILED** - a single +2.0 MB step in the last cycle (pigeon to crow), the size of the one-time step every soak takes in its first cycle (+2.05 MB, starling to pigeon) - **and its re-run PASSED** (starts 288.59-288.89 MB, objects 11934-11954, nodes 2904-2908, 0 orphans); an earlier run this round (audio dropped) passed with the step at its third start. The step's source is not pinned (§7) | the soak | - |
| Game-loop suite 6/127, its pacing evidence stale (major, engineering) | The game loop's own (its fix round 5 ran through this round). The AI changed again here (the committed pass, show hunts, the swarm): its evidence must be regenerated on this code | - | - |

### Minors

| Finding (lens) | Fix | Pinned by | Without the fix |
|---|---|---|---|
| The catch lesson timed out (45 s) before a typical first catch (experience) | A lesson's own timeout: the catch lesson waits 300 s (`Onboarding.CATCH_TIMEOUT`), its hint names the ringed bird | `ui_onboarding_test.test_the_catch_lesson_waits_for_the_first_catch` | FAILS |
| The cue re-targets often (experience) | Game loop (its fix round 5: `ThreatWatch.target_commit_s`, never a switch by preference while closing). Measured through the real chain: 8.4 changes a minute at the full tier (3.4 by preference), 5.8 at the Quest tier (2.1 by preference); the verifier measured 5-19 | the pacing evidence (cue changes by reason) | - |
| Calibration card's hint ~1 deg, "B or Y: skip" ~8 px, a black sans box (experience) | The UI's font and colours; every line's capitals >= 1.5 deg at 1.25 m; the card grows to fit (VR.md) | `calibration_flow_test.test_the_card` | FAILS (`card_small_text`) |
| The way out disappears after 1 s of a wrong pose; "Stand tall" to a seated player (Quest) | The hint is the problem, then the skip / cancel line under it; `PROMPT_SEATED` | `calibration_flow_test` | FAILS (`card_hint_one_line`: 2 tests) |
| Desktop cards name no key; held S stalls without a word (experience + engineering) | Lessons carry `"keys"`, the HUD shows them outside VR; How to fly's desktop captions (Space, W/S, A/D, Shift, mouse, Esc; "Held, S stalls"). S itself unchanged: too much angle of attack stalls (the physics) | `ui_onboarding_test.test_desktop_names_the_keys`, `game_desktop_test` (the real game) | FAILS (`desktop_gesture_hints`) |
| Main-menu Quit a single pull under the resting laser (all three) | "Hold to quit" (`HoldButton`) | `ui_flow_test.test_quit_button_calls_quit`, `game_flow_test.test_quit_to_menu_then_quit` | FAILS (`quit_single_pull`) |
| The murmuration is 8-13 birds (experience) | `MurmurationSwarm`: visual-only starlings round the murmuration's NPCs, 0.75 per NPC of the budget (45 desktop, 21 Quest); `sky_*_murmuration*.png` | `behaviour_test.test_the_murmuration_has_a_visual_mass`, `sky_hunt_test` | FAILS (`no_swarm`) |
| The governor never gives the budget back (engineering + Quest) | `QualityGovernor` recovers one step after 30 s at 98 % of the refresh, the wait doubling after each step back down (no pulsing), never above the tier | `quality_test.test_governor_recovers_the_budget_without_pulsing` | FAILS (`governor_no_recovery`) |
| The simulator's fps verdict could come from a thinned sky or a grounded bird (engineering) | `integration_sim.gd` checks `fps_window_in_flight` (>= 90 % of the window flying) and `tier_budget_held` (no governor step, the tier's budget, on the Mobile renderer) | the simulator run (§4) | - |
| `test_restarts_leak_nothing` loose (engineering) | Nodes and objects at the same moment of every restart (the minimum over 1.5 s), from the second restart on: nodes exact, objects within 6 (plus one NPC's worth per NPC of difference), no trend over the restarts | `game_flow_test.test_restarts_leak_nothing` | FAILS (`leak_small`: 1 node + 3 objects a run, 7 failures) |
| Glue mutants survived (engineering: growth not reaching the flight model, no tier-up card) | `game_flow_test.test_grow_to_the_next_species` checks the flight model's mass and the celebration | `game_flow_test` | FAILS (`growth_no_flight`, `no_tier_celebration`) |
| A recenter while paused turns the view twice (Quest) | PlayerBird re-aims the rig while paused, once the runtime's frame has reached the tracked nodes (FLIGHT.md) | `player_bird_test.test_pb29_recenter_while_paused_turns_the_view_once` | FAILS (`paused_recenter_late`) |
| A recalibration from the pause menu sits over the pause panel (Quest) | `FirstFlightGate` hides the menus while the card is up and restores them after | `game_first_launch_test.test_recalibrating_from_the_pause_menu_hides_the_menu_until_done` | FAILS (`menu_over_card`) |
| `player.tscn` and VR.md still said near 0.03 (Quest) | 0.06 (`NEAR_PER_WORLD_SCALE` = `NEAR_K`); docs corrected | `near_plane_test.test_the_player_scene_camera_starts_at_the_games_near_plane` | FAILS (`near_003`) |
| The APK shipped the game loop's tuning data (engineering) | `export_presets.cfg` excludes `scripts/game/data/*` with `scripts/game/sim/*`; `tools/export_quest.sh` fails if either is in the APK | the export script's checks (§6) | - |
| Quest CPU tail / governor (Quest + engineering) | The frame tail tool (`tests/shots/integration_frame_tail_test.gd`) ran only at load 20-22 this round (p50 1.81, p99 14.2 ms - preemption; §7); the governor recovers (above). The Quest's own tails need OVR Metrics on the device | - | open (§7) |
| AI `perf_test` fails on a busy Mac (engineering) | Not weakened: 2.0 ms at 60 NPCs passes at load < ~7 (§7) | - | open |
| DESIGN.md's "automatic" calibration vs the prompted step (engineering) | The lead's decision (ARCHITECTURE); raised, not decided here | - | open |
| Loading before the first frame (Quest) | Unchanged: the long steps run under the runtime's loading indicator; a cold launch with `adb logcat` on the device must confirm no ANR (§7) | - | open |
| The cue's colours differ from the highlights (experience) | Not changed (a look-and-feel decision for UI and birds together) | - | open |

**Mutation runs** (`artifacts/integration/round2_mutants.txt`): every fix
above with a test was removed again in a private copy and its test failed on
the copy (18 of 18). `no_show_hunts` first **passed** (the readable-hunt
count alone did not need the show on the test's seed); the test now also
pins the mechanism (>= 3 show hunts set up in view) and fails without it.

### Pacing through real flight

The game loop's pacing evidence models a person flying NPC physics
(SimPilot / IntegratedSim). This round's **competent person**
(`tests/unit/integration/integration_person.gd`: SimPilot's own rules -
it follows the target cue, gives up where SimPilot gives up, evades from
the threat cue at 0.31 and breaks across each attack run) flies the real
`PlayerBird` through `BotPoseSource` arms, the real `WingInput` and
`FlightModel`, in the real sky, nothing staged or pinned; its pilot
(`integration_person_pilot.gd`) looks where it flies and backs out of a
wedge. One run per process, a batch from a frozen copy of the tree:

```bash
tests/shots/integration_pacing.sh final --seeds="5 11 17 23 29 31 37 41" --tiers="full quest" --minutes=30 --workers=5
python3 tests/shots/integration_pacing_merge.py artifacts/integration/pacing/final --evidence=tests/unit/integration/data/real_pacing.json
```

Final code (`1814c9d36527e7d4`; `artifacts/integration/pacing/final/`,
16 runs of 30 minutes, 25 minutes of wall time at five workers):

| median time to (runs that got there, of 8) | swallow | starling | pigeon | crow | gull | hawk | eagle |
|---|---|---|---|---|---|---|---|
| full tier (60 NPCs) | 9:59 (7) | 27:13 (6) | never (1) | never (0) | never (0) | never (0) | never (0) |
| Quest tier (28 NPCs) | 6:24 (7) | 12:04 (6) | 25:03 (5) | never (4) | never (3) | never (2) | never (0) |
| the brief | | | 5-8 min | | | | 20-30 min |

| | catches / min | without the assist | deaths a run | runs caught >= 1 | runs lost | errors |
|---|---|---|---|---|---|---|
| full tier | 0.24 | 4 % | 1.0 | 6 of 8 | 0 | 0 |
| Quest tier | 0.28 | 14 % | 0.25 | 2 of 8 | 0 | 0 |

`real_pacing_test` therefore fails on the brief at both tiers and on the
Quest tier's danger; that is the finding, not a test to relax. The batches
that chose the attack window are kept (`base0`-`base3`, `sweepA`,
`sweepB`; `sweepA`/`sweepB` stopped after 6 of 8 runs).

### The game loop's latest edit breaks the core loop through real flight

The game loop edited `scripts/game/threat_watch.gd` at 05:27 (its fix round
5: the target is committed while the player gains on it and kept through a
short occlusion - "a person follows the marker"). On the tree after that
edit `game_catch_test` **fails**: the competent person made **0 catches in
6 minutes** (63 of 77 chases ended wedged in trees and houses, 79
unsticks). The same test on a private copy with only `threat_watch.gd` put
back to its 05:10 version passes with 3 catches, the same 3 as before
(`artifacts/integration/round2_mutants/gameloop_0527/`: the 05:10 file,
`revert_threat_watch.py` for `mutrun.sh`, both logs). Through real flight a cue that holds a bird hidden
among trees sends the player into them; the game loop's own model does not
fly into the trees. Reported to the game loop, not changed here.

### Suites after the round

| suite | result | notes |
|---|---|---|
| `unit/integration/` | 30 / 33 (404 assertions, 452 s at load 16-24) | `game_catch_test` (the game loop's 05:27 edit, above); `real_pacing_test`: the brief at both tiers, the Quest tier's danger (the evidence check warns: it played the tree of 05:15). On the tree of 05:15 (before the evidence was merged): 29 / 33 - `real_pacing_test`'s 3 and `game_flow_test`'s +2-node flake (a feather burst; fixed since: 11 / 11); `game_catch_test` passed there |
| `unit/flight/` | 184 / 184 | PERF-01 failed once at load ~45 by 0.4 % (0.879 ms against 0.875), passed on the re-run |
| `unit/vr/` | 161 / 161 | |
| `unit/ui/` | 187 / 187 | |
| `unit/ai/` | 77 / 78 | `perf_test`'s 2.0 ms at 60 NPCs: 2.37 ms at load ~20; at load 12 the means pass (trimmed 2.00, median 1.86) and the p95 tail fails; 1.53 ms at load 6.8 in round 1 - not weakened |
| the soak | FAIL, then PASS | above |
| simulator, Mobile | 10 / 12 | `fps_at_refresh` 48.4 fps and `tier_budget_held` (the governor thinned the sky to 20 NPCs) at load 20-31; everything else PASS (the gate, the menu, the wings, the strokes, 44 / 55 draw calls, 0 errors). Round 1: 71.69 fps at load ~7 |
| mutation runs | 18 / 18 fail without their fix | `round2_mutants.txt` |
| APK | PASS | `tools/export_quest.sh debug`: 97 MB, no `scripts/game/data/` or `scripts/game/sim/` inside |

The machine was shared with the game loop's agent all round (its pacing
batches and suites at ~100 % CPU each; load 10-50).

**Evidence** (looked at): `shot_*.png` (menu, settings with Turn speed,
first flight, chase, catch feathers, tier-up, danger, caught, summary),
`sim_mobile_*.png` (the menu, the card in the UI's style, calibrated, the
first lessons, the wings, the flight), `sky_{full,quest}_*.png` and
`sky_*_murmuration{,_zoom}.png` (the murmuration's mass - and the danger
marks on it), `pacing/final/` and `tests/unit/integration/data/real_pacing.json`,
`soak.json` (the failed soak) and `soak_rerun.json`, `round2_mutants.txt`,
`round2_gameloop_proposals/`.

---

## 10. Integration hygiene (2026-09-27)

Four open items of the last integration verification. The game loop's
agent was stopped mid-work at 06:38 and other agents were editing
`scripts/game/`, `scripts/ai/` and `scripts/ui/` all through this round, so
none of those were touched: findings for them are proposals with evidence.
The tree was consistent when this round started (every script parsed; the
import only failed for a few minutes at 07:12 while the game loop's agent
was mid-edit in `threat_watch.gd`, and parsed again after); `game_flow_test`
passed 11/11 on it. Edits outside integration's files, each marked in the
code with "integration hygiene, 2026-09-27": `scripts/world/tree_lib.gd`,
`village.gd`, `terrain.gd`, `palette.gd`, `soaring_world.gd` (item 3; the
world area was idle; its suite passes 39/39 on the result).

### 10.1 The soak's creep: bounded caches, not leaks

Tools: `tests/soak/soak_census.gd` (a reachability census - every object
reachable from the tree, every script's static variables, the SceneTree and
the engine singletons, through properties, containers, metadata and signal
connections, including the bound arguments where a pending `await` lives - and
a per-frame memory step detector), the soak's diagnostic flags
(`--soak_reach`, `--soak_memtrace=<MB>`, `--soak_drop=audio,ui_sounds`), and
`tests/shots/integration_diag_steps_test.gd` (tier-ups one by one with parts
of the game switched off). What they showed:

| creep | source | bounded by | how it was found |
|---|---|---|---|
| +3-7 objects a run | the fonts' shaped-text caches: every `Font` keeps the last 64 strings it measured and 16 wrapped paragraphs (engine: `Font::Font()` sets `cache.set_capacity(64)`, `cache_wrap` 16) as `TextLine` / `TextParagraph` objects outside the scene tree; every run's new scores, times and summary lines add some | 80 objects per font (4 UI font variations + the fallback) | reachable objects exactly equal between runs (9,593 = 9,593) while the total grew; objects kept after the game was freed (+199 after a 6-run soak, +132 after a short one); emptying the caches (`Font.set_fallbacks(get_fallbacks())` runs `_invalidate_rids`) freed 30-33 objects at every run start, and with that the starts were flat (below) |
| +2 MB steps, one in some runs; +6 / +4 / +10 MB in the first | the text caches of the HUD's cards (the TextServer's glyph caches and atlases): the tier-up headline is fitted by `UIScreen.fit_size`, which measures the text at 90, 88, 86 ... px until it fits - every size it tries gets its own glyph cache and a 1024 x 1024 atlas page (2 MB, and 2 MB of GPU texture on the Quest; `fit_size("Now a Swallow!")` alone allocates 6.0 MB, three sizes) | the sizes and glyphs the UI ever uses (29.6 MB of Nunito atlases after one run, from 13.6 MB at the menu) | the step detector put every step on the frame of a tier-up, a caught screen or a summary; audio, the NPC sky, the VR wings, world_scale, the feather bursts and flight each switched off left the pigeon step at +2.0 MB; disconnecting the UI's tier-change handler removed all of them, and `hud.show_tier_up` alone reproduces them (+6.0 swallow, +2.0 pigeon, +10.0 back to sparrow) |
| ~20-60 kB a run | memo tables keyed by continuous values: `FlapDetector._ref_cache` (a reference stroke per player size, x at 0.001: ~9 new a run), `NpcFlight._table_cache` (a level-speed table per NPC mass bucket, ~46 a run, capped at 4096), `Habitat._seat` / `_enclosed` (per perch and radius step) | their key spaces (1,001; 4,096; perches x steps) | the census's static-container diff; 550-940 entries emptied at each run start |
| ~1 object a run, slowly | the polyphonic players' finished voices: `AudioStreamPlaybackPolyphonic::mix` clears a voice's active flag when its sound ends but keeps its playback object until the voice is reused, so a player holds as many as the most one-shots that ever sounded at once - a new peak now and then | the polyphony (16 one-shot, 6 UI voices) | with the fonts' caches emptied the starts still rose ~1 a run (+5 over 5 runs) with audio and stayed flat (+-1 over 10 runs) without; restarting the polyphonic players at the sample empties them |
| +-5-14 objects at a sample | sounds playing (each holds its playback object while it plays) | the voice pools | dropping audio made the starts flat to +-1 |

None is a leak: each is a cache with a bound. The one worth changing is
the atlas growth (up to ~30 MB of textures on the Quest for sizes the fit
loop only tried): **proposal for the UI area**
(`artifacts/integration/hygiene_ui_proposal/fit_size_proportional.py`, not
applied - `scripts/ui` was being edited): measure once, scale (text width
is proportional to the size), confirm. On a patched copy the same tier-up
sequence allocates 8 MB instead of 18 (swallow +4.0 instead of +6.0, back
to sparrow +2.0 instead of +10.0; 13 atlas pages instead of 17), and the UI
suite passes 193/193 (`ui_suite_with_proposal.log`, `steps_*.log`).

**The soak's threshold, principled** (`tests/soak/integration_soak_test.gd`;
the round-2 window - memory at the last three starts within 0.75 MB - was
fitted after the fact and failed on any run that met a new atlas page):
before each run-start sample the caches that can be emptied under a running
game are emptied (the fonts' shaped-text caches, the polyphonic players'
finished voices - the players are restarted - and the three memo tables;
the glyph atlases cannot be: `FontFile.clear_cache` frees the font data the
labels' shaped text still points at - "Parameter fd is null"), and a start
is the least nodes / objects (less the sounds playing) / static memory over
3 s. Then:

- nodes from the second run on **exactly** the second run's (was +-8);
- objects: every start within 8 of the median start (a one-shot starting
  in the window, a caught bird's 0.5 s timer; was +-40 of the second run's)
  and the **drift** - the median of the last 4 starts less the median of
  the first 4 - at most 5.5 over **12 runs** (their centres 8 runs apart: a
  leak of one object a run moves it by 8; see "Resumed" below for why the
  per-run increments' median, judged until 09:40, had to go);
- static memory: the **median per-run increment** within a budget of 1 MB an
  hour of play (78 kB for a 280 s run). A leak adds every run; a bounded
  cache steps when new content first needs it, in any run - the median sees
  the first and not the second. 1 MB an hour is ~2 MB over a long session
  on a 12 GB headset; a per-frame 57-byte leak (4 kB/s) is 14 MB an hour and
  fails;
- 0 orphans, every cycle won the apex, 0 errors, 0 warnings.

**Result of the 6-run version** (08:55, `soak_run.log`; 6 cycles, 1,951 s of play in 357 s of wall time, 165
catches, 8 deaths, every run won the apex): nodes 2,990 at every start from
the second run on; objects 12,047, 12,051, 12,051, 12,050, 12,050, 12,051
(median increment 0); static memory 285.87, 287.89, 287.92, 289.92, 289.92,
289.93 MB - two steps of +2.02 and +2.00 MB (the size of the HUD's
text-cache steps) and a median increment of 0.033 MB against a budget of
0.087; what emptying the caches freed at each
start: 19-20 objects and 0.21-0.23 MB (730-940 memo entries). Its first
version failed on the polyphonic voices (above); round 2's soaks, whose
starts included the font caches, rose 2, 3, 2, 7 and 3 objects a run
(median 3: they would fail the object criterion). The soak's own 30 s
samples were ~20-40 kB a run of the memory it judged: they are now written
out as they are taken.
Mutation runs (`hygiene_mutants.txt`): 1 node + 3 objects kept per run
(`leak_small`, round 2's mutant) fails on nodes and objects; 150 kB kept per
run (`mem_leak`) fails the memory median (0.172 MB against 0.079).
Objects after the game is freed: +148 (the first game's process-wide caches:
bird meshes, the audio bank, the theme, the glyph atlases).

**Resumed (09:10-10:30, after the stop): the objects criterion was not
stable.** Five 6-run soaks of the same leak-free code (09:10-09:37) gave
run-start objects (from run 2) of 12,043 → 12,049, 12,051 flat, 12,047 →
12,051, 12,049-12,054 flat and (08:55) 12,047 → 12,051: each converges on
~12,050 +-2 within 1-5 runs and stays there, whatever the first start was.
That is a bounded fill, not a leak (a steady leak cannot give the flat
series), but the median of five per-run increments failed two of them (2.0:
[-2, -1, 2, 2, 4]; 1.0: [0, 0, 1, 1, 2]). What fills is engine-side, not
script-reachable: the reachability census (`--soak_reach`) between runs 2
and 6 moved only a live feather burst (+3: burst, MultiMesh, instance); the
engine's `--verbose` list of instances left at exit is the same after 2 and
6 runs (+150 / +148 objects after the game is freed, one known OpenXR
instance at exit). With 6 runs a leak of one object a run (+5) cannot be
told from that fill (+4-6), so the soak is sized instead: **12 runs** (~1 h
of play, ~14 min of wall time) judged by the drift (above). Leak-free, the
drift was -1, -1, 0, +3, +3 on the five 6-run soaks and +1.5 / +3.5 on the
two 12-run ones; one object a run moves it by 8, so the limit is halfway
(5.5). Memory keeps the median per-run increment (11 of them now).

**Result** (`artifacts/integration/soak_ih2_final.json`,
`soak_ih2_final_samples.jsonl`; 12 cycles, 4,312 s of play in 832 s of wall
time at load 4-6, 383 catches, 15 deaths, every run won the apex, 0 errors,
0 warnings): **PASS**. Nodes 2,990 at every start from run 2; objects 12,047,
12,047, 12,048, 12,049, 12,049, 12,052, 12,050, 12,050, 12,049, 12,049,
12,051, 12,048 (drift +1.5, all within -2..+3 of the median); static memory
285.96, then 287.97-288.12 for nine runs, then 290.14 / 290.12 (one +2.02 MB
glyph-atlas page in run 12) - median increment 0.007 MB against a budget of
0.096 (`artifacts/tests/report_integration_soak.json`). The same with the AI fix proposed in §10.5 (`moth_guard`): PASS,
drift +3.5 (a slower fill: 12,044 → 12,049 over six runs).
Mutation (`leak_one`, one RefCounted kept per run start; 12 runs, every one
won): **FAILS** - starts 12,052 → 12,072, drift **+14.5** against 5.5, and
runs 2-3 more than 8 under the median (`hygiene_mutants/logs/leak_one.log`,
`soak_leak_one.json`). A first attempt was cut when an eagle made no apex
catches for 15 minutes (§10.5; `leak_one_cut.log`); the old mutants
(`leak_small`, `mem_leak`) fail on nodes and memory, which did not change.

### 10.2 `game_flow_test`: honest staged catches

A mutant halving the player's catch reach (`CatchRule.player_reach` 2.0 ->
1.0) passed the whole suite: the staged catches pinned the assist at 1.0
(the capped reach, 2.9 spans, which a halved base reach nearly reaches too),
the kit's cooperative prey kept to the player's height so the bot flew
through the bird (closest approach 0.06-0.15 m in the lab,
`tests/shots/integration_catchpass_lab_test.gd`), and 3 passes were allowed.

Now (`game_flow_test._catch`, `game_kit.stage_prey(species, ahead, side_m)`):
the assist is the game's own (never pinned: 0.00-0.05 at the first moth, 0
after each catch); the prey hovers level with the player **1.7 of its
wingspans to the side of the line it flies**, held there until the player is
0.25 m from it along the line (the kit moves it with the line: the bot's
wingbeat moves a sparrow up to 0.3 m vertically in the last half metre -
left still for the last 0.6 m, the lab's closest approaches spread to
0.52 m, at the edge of the reach), and every
staged catch must be made **on its first pass** (a pass that never came
within 1.5 m - the bot turned away - is flown again, at most 3). 1.7 spans
lies between the reach a sparrow has (the bodies plus 2.0 spans: 2.2 spans,
0.53 m for a moth) and half of it (1.2 spans, 0.29 m): ~0.12 m of margin
either way at a sparrow's size, and the kit's hold means the bot's aim
cannot decide it. Deterministic: 11/11 in each of its runs with the new
catches (before and after the core-loop agent's pilot changes of 07:49-07:57).

Mutation runs (`artifacts/integration/hygiene_mutants/`, `mutbatch.sh`,
results in `artifacts/integration/hygiene_mutants.txt`): `half_reach` fails
`game_flow_test` (5 passed, 6 failed: the moth's first pass reaches 0.41 m
of it and misses at the game's own assist 0.04 - the catch, growth and
everything after it fail; before this round it passed 11/11). The lab
(`catchpass_lab_final.json`): 30 passes each at a moth and a wren, 1.7 spans
beside - closest approach 0.408-0.454 m (one moth pass never lined up and
would be flown again), contact 0.531 / 0.544 m with the real reach, 0.29 /
0.30 m with half of it.

### 10.3 Depth precision on the Quest

Confirmed from the engine source: with MSAA the Mobile renderer draws depth
into `RenderSceneBuffersRD::get_depth_format(false, true, false)` - D24_UNORM_S8
where the GPU has it (Adreno does; this Mac's MoltenVK does not, so no image
here can show a fight). One step at view depth z is z^2 / (near x 2^24).

**Depth precision by size** (`depth_precision_test.test_depth_precision_table`,
default arm span; near = 0.06 x world_scale):

| species | world_scale | near | step at 10 / 30 / 100 / 300 / 1000 m | a gap of 1 mm / 1 cm / 5 cm / 20 cm / 1 m is within two steps from |
|---|---|---|---|---|
| sparrow | 0.141 | 8.5 mm | 0.7 / 6.3 / 70 / 633 / 7037 mm | 8 / 27 / 60 / 119 / 267 m |
| swallow | 0.194 | 11.6 mm | 0.5 / 4.6 / 51 / 461 / 5118 mm | 10 / 31 / 70 / 140 / 313 m |
| starling | 0.235 | 14.1 mm | 0.4 / 3.8 / 42 / 380 / 4222 mm | 11 / 34 / 77 / 154 / 344 m |
| pigeon | 0.388 | 23.3 mm | 0.3 / 2.3 / 26 / 230 / 2559 mm | 14 / 44 / 99 / 198 / 442 m |
| crow | 0.559 | 33.5 mm | 0.2 / 1.6 / 18 / 160 / 1778 mm | 17 / 53 / 119 / 237 / 530 m |
| gull | 0.765 | 45.9 mm | 0.1 / 1.2 / 13 / 117 / 1299 mm | 20 / 62 / 139 / 277 / 620 m |
| hawk | 0.941 | 56.5 mm | 0.1 / 1.0 / 11 / 95 / 1056 mm | 22 / 69 / 154 / 308 / 688 m |
| eagle | 1.235 | 74.1 mm | 0.1 / 0.7 / 8 / 72 / 804 mm | 25 / 79 / 176 / 353 / 789 m |

In felt metres the precision is the same at every size (near is 6 cm
felt); in world metres a gap's fight starts ~3x further away for an eagle
than for a sparrow. **The near-plane policy stays** (`NEAR_K` 0.06): the
first-person wings' nearest feather is 8.1 cm from the eyes (a wing root
seen when looking down at a banked wing, `near_plane_test` with a 1.25
margin), so 0.065 is the ceiling - 4 % further per gap, not worth the risk.
The fix is in the geometry.

**The scan** (`tests/shots/integration_coplanar_scan.gd`; the regression
test `tests/unit/integration/coplanar_test.gd`, 28 s; the diagnostic
`tests/shots/integration_coplanar_test.gd` writes
`artifacts/integration/coplanar[_before|_after].json`): every triangle the
renderer draws (811k: every visible mesh and MultiMesh instance, shadow-only
proxies and hidden levels of detail skipped; the soft decor's double-sided
cards skipped), hashed in 4 m / 64 m cells, every pair within 3 deg and
0.3 m of each other whose projections overlap by more than 1 cm2 and a
5 mm-wide strip (a seam where two pieces meet end to end is a line, not a
patch). Pairs facing opposite ways are culled one way or the other (every
world material culls back faces); pairs of one colour (within MeshKit's +-5 %
facet jitter) look the same whichever wins; a pair is **seen fighting**
when its front face can be seen (rays from 2 m and 30 m back at it along
nine directions, the viewer above ground; the trees' and the stand-ins'
drawn faces collide with simpler shapes or not at all and count as seen) and,
at the distance its fight starts (z* = sqrt(gap x near x 2^23)), its patch
still covers a pixel of the Quest Pro (~20 px/deg). Judged at the sparrow's
near plane (the coarsest).

| | before (rounds 0-2) | after |
|---|---|---|
| overlaps within 1 mm, different colours, seen (fight at every distance and size) | **307 spots** | **0** |
| within 5 mm, seen fighting at a sparrow's near plane | **3,289** | **0** |
| paving over the grass (0.2 m), seen fighting | 406 (from 119 m for a sparrow, 353 m for an eagle) | **0** (settled by the offset: 450 pairs) |
| any gap up to 0.3 m, seen fighting | 11,262 | 5,466 |

What they were and the fixes (everything else in the valley is built
exactly as before: the MeshKit's random stream - which also shapes the
leaf clumps and so the stand-ins - consumes exactly as it did):

- **birch bark** (3,271 of the spots within 5 mm, 304 of the exact ones:
  the mutant that puts only this back): every tree piece starts a little
  back inside the piece it grows from (it closes the wedge at a kink), 1-4 mm
  under the parent's surface; a birch's dark band started inside white bark
  and the next white piece inside the dark band. The hidden start is now
  drawn in the parent's colour (`TreeLib._seg(..., parent_col)`; the birch,
  the two-tone boles of both broadleaves and the snag);
- **the belfry floor** (36 m2 of stone vs dark stone, exactly coplanar): the
  belt course was a slab through the tower's top; now a ring round it;
- **window crosses** (every closed window, 5 x 5 cm exactly coplanar): the
  cross bar in two halves either side of the upright;
- **a lake quad**: the jittered lattice's concave quads are split along the
  diagonal inside them;
- **the paving** (street and square, 0.2 m over the grass): the kit is drawn
  with `Palette.paving_material()`, the solid material with BaseMaterial3D's
  z clip scale at 1 - 3 x 2^-24 - Godot 4.5+'s `mix(w, z, scale)` on clip z,
  never in the shadow pass: 3 D24 steps nearer at every distance, a polygon
  offset (2 mm at 10 m for a sparrow). Its look is the solid material's own
  (before/after images differ only where the leaves sway:
  `depthfix_{before,after}_*.png`, `hygiene_depth/depthfix_imgdiff.txt`;
  `depthfix_bigoffset_street.png` shows the mechanism with 20,000 steps).

Mutation runs: the valley of before, the birch bands in their own colour,
and the plain material on the paving each fail `coplanar_test`
(`artifacts/integration/hygiene_mutants.txt`). World suite 39/39 after;
`depth_precision_test` 2/2.

**Left, for the world area:** 5,466 spots with gaps of 1-30 cm that a
sparrow sees fight once far enough away - 810 from under 50 m, 2,420 from
50-100 m, 2,236 from 100-150 m (x3 for an eagle): the houses' timber
panelling 2 cm proud of the plaster (seen through the windows from 38 m),
the barn's dark boarding 3 cm under the moss roof (76 m2, from 63 m through
the doors), the far tree stand-ins' faces 3.5-20 cm apart (from 50-120 m),
house floors 0.3 m over the grass (inside the houses, from 146 m), the water
tower's tank rim, the bridge's deck strip. Pushing a detail's offset from
2 cm to 20 cm moves its fight from ~38 m to ~120 m for a sparrow; drawing a
hidden surface in the colour of the one in front hides it at any distance
(as for the birch). `coplanar_test` prints the list; `coplanar_after.json`
has every spot.

### 10.4 The simulator

`tests/shots/integration_sim.sh` (Mobile renderer, the Quest tier chosen by
the game itself, a first launch through the calibration gate), twice this
round at quiet moments (my own soak and scans stopped; one or two other
Godot processes on the machine):

| run | 1-min load during the run | fps (72 Hz) | p50 / p95 / p99 / max ms | frames > 1.5 intervals | checks |
|---|---|---|---|---|---|
| 06:50 (`sim_result_quiet1.json`) | 4.8-8.4 (6.4 at the fps window) | 70.65 | 13.89 / 14.51 / 26.98 / 29.07 | 27 (1.9 %) | 12 / 12 PASS |
| 08:56 (`sim_result_hygiene.json`, final tree) | 3.9-5.5 (5.4 at the fps window) | **71.35** | 13.89 / 14.32 / 19.78 / 27.95 | 13 (0.9 %) | **12 / 12 PASS** |

Session FOCUSED, physics at 72 ticks/s, 0 errors and 0 warnings in the
whole log (the engine's exit messages excepted as always), 28 NPCs held (no
governor step), 45 / 56 draw calls in the headset view, 70k primitives. The
median frame is exactly on time; the tail is the Mac's scheduler (the
round-2 run at load 20-31 had 48 fps). Loading: 1.76 s of work before the
first frame, the worst frame gap after it 80-82 ms; the menu came at 3.5 s
and 5.3 s after main (the runtime took 2.7 s to show our frames in the
second). Images `sim_quiet1_*.png`, `sim_hygiene_*.png` (looked at: the
menu, the calibration card, the wings, the flight with its lesson card; the
Mobile renderer's mirror shows MoltenVK's magenta tiles on this Mac, as in
every round).

Resumed at 09:56 and 09:58 (`sim_result_hygiene2.json`, `hygiene3`; images
`sim_hygiene2_*.png`, `sim_hygiene3_*.png`, looked at): **11 / 12** each -
FOCUSED, 72 ticks/s, 0 errors and 0 warnings, 45-46 / 56 draw calls, 70k
primitives, 70.00 / 69.70 fps (p50 13.93 / 13.92 ms, p95 15.3 / 15.5, p99
27.6 / 26.7); `tier_budget_held` failed: the governor stepped the sky down
once (28 → 24 NPCs). Neither moment was quiet: the core-loop agent's three
30-minute pacing sims (`cl3_w0`-`w2`, 100 % CPU each) had started at 09:56,
and the load rose from 3.9 to 7.9 during the runs. At 10:21, with one or two
other Godot processes as at 08:56 (their next batch started mid-run; load
4.5 → 6.8, `sim_result_hygiene4.json`, images `sim_hygiene4_*.png`, looked
at): **12 / 12 PASS** - FOCUSED, 72 ticks/s, 69.10 fps (p50 13.91 ms, p95
15.8, p99 28.0), 28 NPCs held (no governor step), 0 errors and 0 warnings,
44 / 56 draw calls, 70.8k primitives, 1.75 s of work before the first frame,
the menu at 3.4 s. The median frame is on time in every run; the fps and
the governor follow the machine's load, not the build.

### 10.5 Suites and findings for other areas (resumed, 09:10-10:30)

The other areas kept editing all through (the AI's moth field and
ecosystem at 09:24 / 09:46, the game loop's growth and danger at 09:49 /
10:16, the HUD at 09:13, the core-loop agent's `integration_person_pilot.gd`
at 09:19), so each run names its tree: the suite ran on the tree of 09:10,
the 12-run soaks on that of 09:40, the leak mutant on 10:02's, the
simulator on 10:21's. The moth error (below) is still in the tree of 10:24
(`NpcBird._strike` unguarded, `MothField._drop` unchanged, moths stepped
before the NPCs).

| suite | result | notes |
|---|---|---|
| `unit/integration/` (`--fixed-fps 72`), tree of 10:23 | **32 / 41**, 488 assertions, 399 s at load 5-6 | `real_pacing_test` (8, the game loop's: its evidence predates the 10:16 growth tuning and has no full-tier novice / expert runs); `game_catch_test.test_the_catch_lesson_is_quick` (the game loop's new test: the ring came onto a lesson moth after 23.1 s, limit 5 s). `sky_view_test` passes again (below). Everything else passes |
| `unit/integration/`, tree of 09:10 | 31 / 41, 488 assertions, 436 s at load 5-8 | the game loop's `real_pacing_test` (8: its evidence predates the 09:06 growth tuning and names no held-out full-tier runs); `game_catch_test.test_the_catch_lesson_is_quick` (the game loop's new test: no ring on a lesson moth, and the AI's moth error below); `sky_view_test` (AI, below). Everything integration owns otherwise passes: `game_flow_test` 11 / 11, `coplanar_test`, `depth_precision_test` 2 / 2, lifecycle, first launch, desktop, water, quality, spawn perch, `sky_hunt_test`, `chase_fleeing_test`, and the competent person's `test_a_competent_person_catches_real_prey` |
| the soak, 12 runs | **PASS** (09:40, above) | also PASS with the AI fix below; the 6-run version failed 2 of 4 on objects (09:10-09:37, above) and once on the AI's moth error (below) |
| simulator (Mobile, Quest tier) | **12 / 12** at 10:21 (69.10 fps, 28 NPCs held, load 4.5-6.8) and 08:56; 11 / 12 at 09:56 / 09:58 (three other sims running: the governor stepped once) | §10.4 |
| mutation runs | 7 / 7 fail without their fix | `hygiene_mutants.txt`: `half_reach`, `world_before`, `birch_bands`, `no_paving_offset`, `leak_small`, `mem_leak`, `leak_one` (new, 12 runs) |

**For the AI area (1 open, major; 2 passing again, watch it):**

1. *An engine error in play.* `ERROR: Condition "!is_inside_tree()"`
   (`get_global_transform <- bird.gd:43 <- npc_bird.gd:620 (_strike) <- :509
   <- :375 <- ecosystem.gd`), in `game_catch_test` and in two soaks of nine (`soak_ih2_v6.json`, `leak_one.log`):
   `MothField._drop()` takes a swarm out of the tree (`remove_child`, then
   `queue_free`) and `Ecosystem` steps the moths before the NPCs in the same
   tick, so a bird striking at a moth of that swarm asks a node outside the
   tree for its position. Proposal (one line, `NpcBird._strike`): drop a
   target that is not inside the tree -
   `if not is_instance_valid(strike) or not strike.alive or not strike.is_inside_tree():`
   (`hygiene_mutants/mut_moth_strike_guard.py`; the 12-run soak with it:
   PASS, 0 errors, `logs/moth_guard_soak.log`). Marking a dropped swarm's
   moths dead before `remove_child` would do as well.
2. *The Quest tier's sky looked empty while travelling again (09:05-09:46).* `sky_view_test`
   (deterministic, 0 birds a player notices in 25 of the first 25 s and in
   ~40 of the last 45 s): Quest tier, travel **0.72** birds in view on
   average, one in **30 %** of the seconds (limits 0.75 / 35 %; the verifier's
   original finding was 0.0). It passed at 06:05 (1.03 / 43 %); on the
   current tree with `scripts/ai/` of 06:38 it passes at 1.21 / 48 %; with
   only `npc_brain.gd` of 06:38 (the moths kept) at 0.86 / 43 %. The AI
   area's 08:10-08:58 edits (the player-awareness and murmuration changes in
   `npc_brain.gd`, the moth field in `ecosystem.gd`) thinned the show ahead
   of a travelling player at 28 NPCs. The full tier and the laps pass. Not
   relaxed here. *On the tree of 10:23 (after the AI's 09:46 `ecosystem.gd`
   edit) it passes again at 0.86 / 43 %* - narrowly: the Quest tier's
   travelling show is still the thinnest number in the suite, and one
   realization per tier decides it.

**For the game loop:** `real_pacing_test`'s evidence is stale (above); in 1
soak cycle of ~80 today an eagle made no 3 worthwhile catches in 15 minutes
(the sky sent an eagle at it ~35 times; `logs/leak_one_cut.log`): the soak
failed that run on "every cycle won" - a bot/pacing edge, not a leak.

**Files this round (resumed):** `tests/soak/integration_soak_test.gd` (12
runs, the drift criterion), `artifacts/integration/hygiene_mutants/`
(`mut_leak_one.py`, `mut_moth_strike_guard.py`, logs), `soak_ih2_*.json`,
`sim_result_hygiene{2,3,4}.json` and their images, the doc's §3, §10.1, §10.4 and this section.

### 10.6 The core loop's fix round 1 (2026-09-27, 12:18-15:00)

Written by the game loop's fixer; integration's own code is unchanged, its
tests were touched where the game changed under them:

- `game_flow_test`: a staged pass counts only the staged bird's catch, and
  the catch lesson's moths are released before it - they now wait at the
  player's height, on the staged straight line (a swarm moth was eaten
  instead of the staged one).
- `real_pacing_test`: new `test_the_target_ring_follows_the_chase` (the
  mirror's ring bars on the held-out real-chain runs) and a check that no run
  has two tier-ups within 30 s; run lengths follow the lead's evidence
  economy (competent runs 30 minutes or more, novice / expert 12 or more).
- `pin_escape_test` (new): the real PlayerBird pressed into the west cliff
  gets clear within 3 s (the wall-air fix in `PlayerBird`).
- `integration_person_pilot.gd`: the person finds the window out of a room
  (it hung 9-14 minutes in village rooms in two runs).

Suite on the final tree (14:47-14:54, `--fixed-fps 72 --strict_evidence`):
**38 / 43**. Failing: `real_pacing_test` 3 (skill order, one death 25 s
after a first tier-up, the full tier's ring leaving a closing chase 0.57 a
minute against 0.5 - GAMELOOP.md, "The evidence") and `sky_hunt_test` at
the Quest tier on its seed 13 (1 readable hunt; seeds 21 and 29 pass at
both tiers). The brief's pacing through real flight now holds on fresh
held-out seeds at both tiers: pigeon 5:27 / 6:31, eagle 24:08 / 29:31 (full
/ Quest).
