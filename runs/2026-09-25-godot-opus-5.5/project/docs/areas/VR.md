# VR area: being in the headset

Owner of `scripts/vr/`, `scenes/vr/`, `tests/unit/vr/`, `tests/sim/`, plus
`scenes/dev/vr_*`, `tests/shots/vr_*` and `artifacts/vr/`. Built on
2026-09-25/26 against Godot 4.7.2, OpenXR, the Meta XR Simulator 207
("Meta Quest Pro" profile) on an M1 Pro shared with other agents. Fix round
1 (2026-09-26) addressed both verifiers' round-0 findings (§9), fix round 2
(2026-09-26) their round-1 findings (§10), fix round 3 (2026-09-26) their
round-2 findings (§11), fix round 4 (2026-09-26) their round-3 findings
and the lead's direction (§12), and fix round 5 (2026-09-26) the
re-verification's findings (§13): calibration is automatic for every
wearer (a re-check whenever the headset may have changed hands), the
comfort vignette answers speed again (over the bird's own cruise, steady
wherever it is flown), the rig extras survive the rig leaving and
re-entering the tree, the OpenXR session wiring is tested through a
stand-in interface, folded wings read as feathers from the eyes, and the
wing layout costs a fifth of what it did. Fix round 6 (2026-09-26, §14)
addressed the second re-verification: the wearer re-check never replaces
a calibration from a pose nobody asked for (a landing flare held on a
perch had become one player's "flat"; a re-grip threw away their manual
calibration 17 times in 20); the same player is judged within human
repeatability and kept silently, anything else only puts up the prompt
card and a fresh prompted spread decides; automatic captures wait 2 s
after landing. Extras placed away from the rig give a replaced rig new
wings and a new vignette; the simulator harness reports frame pacing; the
dev scene's simulator shots show four different moments.

**Integration round 2 (2026-09-27, the integration fixer; `docs/INTEGRATION.md` §9).**
- *The calibration card reads like the rest of the game* (the experience
  verifier: its hint was ~1.0 deg of capital height in the simulator's
  mirror, "B or Y: skip" about 8 px where the menus' smallest text is 14, a
  black sans-serif box): the UI's font (`CalibrationPrompt.card_font()`,
  UITheme's bold) and colours (navy card, sunflower ring, cream text), every
  line's capitals >= 1.5 deg at 1.25 m measured the UI's way
  (`CalibrationPrompt.cap_deg()`: 1.63 / 1.55 deg; `FONT_SIZE` 56,
  `HINT_FONT_SIZE` 54), and the card grows to fit its text (`height`; ~1.06 x
  0.30 m). `calibration_flow_test.test_the_card`.
- *The way out never disappears* (the Quest verifier: after 1 s of a pose
  that did not pass, the pose's problem replaced "B or Y: skip" for as long
  as it was wrong, and the first-launch step has no timeout): the hint is
  the problem, then the skip / cancel line under it (`hint_text()`), and a
  seated player reads "Sit tall. ..." (`PROMPT_SEATED`), not "Stand tall".
- *A step asked for from the pause menu no longer sits over the pause
  panel* (the Quest verifier): integration's `FirstFlightGate` hides the
  menus while the card is up and brings them back as they were after the
  result card (`game_first_launch_test.test_recalibrating_from_the_pause_menu_hides_the_menu_until_done`).
- *A recenter while paused turns the view once* (the Quest verifier: 50
  deg at the press, then the whole world 51.5 deg back at Resume): flight's
  PlayerBird re-aims the rig while paused (FLIGHT.md, "Integration round 2").
- *Near plane:* this document's §2.4 and V7 still said 0.03; the value is
  `NEAR_K` 0.06 since round 1, and `scenes/player/player.tscn`'s camera
  now starts at it too (`near_plane_test.test_the_player_scene_camera_starts_at_the_games_near_plane`).
- *Calibration "automatic" in DESIGN.md:* the prompted step is the lead's
  decision (ARCHITECTURE, "vr (calibration redesign, the lead's decision)");
  DESIGN.md's wording predates it and was not edited here.

**Integration round 1 (2026-09-27, the integration fixer; `docs/INTEGRATION.md` §8).**
- *The first launch is Play's gate.* In `main.tscn` the first-launch step
  no longer starts by itself (`first_launch_prompt` false there): it came up
  during loading, sat opaque over the main menu (How to fly, Settings and
  Quit hidden) and Play cancelled it silently, so the first flight flew
  uncalibrated. Now Play closes the menu and asks for the spread
  (`FirstFlightGate`, integration's; `VRCalibration.first_launch_due()`,
  `start_first_launch()`, `abandon()`); the run starts after the capture or
  an explicit skip (B or Y: "Calibration skipped / Using default wings");
  the menu button abandons the step and Play asks again. The card is the
  only thing in front of the player meanwhile, and the body waits on its
  perch. `tests/unit/integration/game_first_launch_test.gd` (4 tests); the
  simulator harness checks it with the real controllers
  (`tests/shots/integration_sim.sh`, check `first_flight_gate`). Scenes
  without the gate keep the old behaviour (the card by itself, outside play).
- *No "New player?" at every launch:* an app start with a saved calibration
  no longer raises `recalibration_suggested` (the same player saw it every
  session). The headset coming off and on, and a long absence, still do.
  DESIGN.md's "calibration ... (automatic, with a manual recalibrate)" is
  now the prompted step at the first Play plus Recalibrate - a conflict
  with the brief raised in the integration report, not silently decided.
- *Near plane:* `WorldScaleDriver.NEAR_K` 0.06 (was 0.03): the Quest's 24-bit
  depth buffer (see `docs/areas/WORLD.md`, "Integration round 1").
  `tests/unit/vr/near_plane_test.gd` pins that no first-person feather in
  view comes nearer than 1.25 x the near plane in any pose (the nearest, a
  wing root at the shoulder looking down at a banked wing, is 8.1 cm);
  ARCHITECTURE §7.5's range became 0.02-0.065 x world_scale.
  *Integration hygiene (2026-09-27, the integration agent; no VR file
  changed):* the depth precision per size was tabled
  (`depth_precision_test.test_depth_precision_table`, INTEGRATION.md §10.3)
  and `NEAR_K` stays 0.06 - with the 8.1 cm wing root and the 1.25 margin,
  0.065 is its ceiling (4 % more reach per gap). The valley's coplanar
  surfaces were fixed instead (`coplanar_test`).
- *A comment corrected:* respawns and new runs cut the view to the spawn in
  one frame; `world_scale_driver.gd` said they happened behind a fade (none
  exists). A teleport fade is an open comfort item (INTEGRATION.md §7).
- Suite: `unit/vr` 160 of 160 (2659 assertions, 30.5 s) after these changes.

**Calibration redesign (2026-09-26, the lead's decision; §2.3, §15).** The
automatic calibration is gone. Its automatic capture, the wearer re-check,
and the cards answered by a pose each kept producing new edge cases. The
last open defect was a landing flare held on a perch answering its own
card after a one-frame blip, and being persisted as "flat". Wrist neutral
and arm span are now captured ONLY in one explicit, prompted step:
- on the first launch, before the first flight;
- whenever the player chooses Recalibrate (Settings, the pause menu, or
  the Y-hold).

The card says "Stand tall. Spread your wings, hands flat. Hold still." It
captures a plausible pose that is still for 1 s, confirms, and can be
cancelled (B/Y). The headset coming off and on, a long absence or a
relaunch only raise `VR.recalibration_suggested`, and the pause menu then
offers "New player? Recalibrate wings". Only the arm span is still learnt
in play, and it never changes the neutral.

Status after the redesign: the headless suite has 158 tests (~30 s;
`calibration_flow_test`, 11 tests, replaces `wearer_test`), all passing.
`flight_rig` passes 7/7. The new simulator check
(`tests/sim/run_calibration_sim.sh`) gives VERDICT PASS on 6 checks, on
both the Mobile and the Forward+ renderer. Each run of it does the
following in the real Meta XR Simulator:
- the first-launch card appears by itself;
- the resting controllers are not captured;
- the gRPC driver spreads the real controllers, and the capture comes
  1.22 s after they stopped (Mobile; 1.28 s with Forward+), with span
  1.54 m and drop 0.27 m;
- the simulator's B/Y key cancels a new step with the calibration
  unchanged;
- `SetUserPresent` off/on only raises the flag.

The V1 harness (`run_vr_sim.sh --tag=default`), rerun after the
redesign, gives VERDICT PASS on all 14 checks at load 5.0:
- 71.8 fps against the 68.4 bar;
- frame times p50 13.89 / p95 13.98 / p99 14.15 ms, 0.2 % hitches;
- the VR scripts take 0.14 ms a frame;
- the calibration takes 40.5 µs a call;
- no unexpected warning.

An earlier rerun at load 17.5 failed only on fps (66.9), which is the
documented load dependence. The on-demand perf gate reads 72.1 µs a frame
(budget 100) at load 5.2. Its round-6 numbers follow.
Round 6: V1-V10 pass. The headless suite had 161 tests (~39 s). The
simulator harness gives VERDICT PASS at the refresh policy's own default
(`tests/sim/run_vr_sim.sh`, no override) with the game's NPC budget in the
scene as stand-ins: FOCUSED, 71.55 fps against the 68.4 bar over 20 s at
load 8.3 (68.55 at load 12.0; a run at load 15.3 failed on fps alone,
kept as `sim_result_default_load15_fail.json`), frame times p50 13.89 /
p95 14.40 / p99 17.44 ms against the 13.89 ms budget, 96 draw calls mean
(123 worst), physics 72 = refresh 72 with the refresh policy seen to run
at session start, focused through the whole window, the main viewport's
VRS mode = XR (foveation), a driven head turn of 40.0° re-centred to 0.0°
by `VR.recenter()`, and zero script errors: 14 checks. The VR scripts take
~0.13-0.15 ms a frame in the simulator at load 7-8 (round 4: ~0.26-0.29). An integration
suite on flight's real `scenes/player/player.tscn` (`tests/sim/flight_rig/`,
7 tests) and one over the real world geometry (`tests/sim/real_world/`:
steady cruise through the orchard, the forest and along the power line
keeps the vignette at exactly 0, and a steady fast glide reads one
constant value) run on demand.

---

## 1. What was built

| File | class | Role |
|---|---|---|
| `scripts/vr/vr_manager.gd` | `VRManager` (autoload `VR`) | OpenXR lifecycle (its signals wired by `connect_interface`, so tests drive it through a stand-in), focus -> pause, refresh-rate policy, physics tick = refresh, foveation, CPU/GPU perf levels, recenter; owns `VR.haptics` and `VR.controls` |
| `scripts/vr/vr_controls.gd` | `VRControls` | Controller buttons -> intents (menu, long presses), analog trigger/grip with hysteresis, for UI and perching |
| `scripts/vr/vr_haptics.gd` | `VRHaptics` | The one haptics player: Events + PlayerBird telemetry -> patterns; rate limits, priorities, 30 % duty cap, Settings "haptics" |
| `scripts/vr/haptic_patterns.gd` | `HapticPatterns` | The haptic vocabulary (pulse lists, priorities, repeat intervals) |
| `scripts/vr/wing_calibrator.gd` | `WingCalibrator` | Pure calibration maths (FLIGHT_SPEC §5): body frame, shoulders, extension, wrist twist; the ONE capture, only on request (`request_capture`): a plausible, still spread held 1 s (`neutral_blocker`, one hint per gate, incl. the live grip-axis check `grip_axis_error`); body fit (anthropometric shoulder height, full-spread span), canonical neutral, refinement of a foreign capture, seated (bounded by the standing eyes), span refinement from genuine spreads only (never the neutral), persistence (corrupt geometry rejected), WingCalibration writer/reader |
| `scripts/vr/vr_calibration.gd` | `VRCalibration` | Rig component: the calibration step (first launch, Recalibrate from Settings / the pause menu / the Y-hold; pauses a running game first; cancel by B/Y, Play/Resume, headset off, timeout), feeds the calibrator every frame, raises `VR.recalibration_suggested` on headset off/on, a long absence or a relaunch (never recalibrates), switches the PlayerBird's own capture off, adopts and refines a capture flight makes explicitly, keeps flight's resource in step, persists through Settings |
| `scripts/vr/calibration_prompt.gd` | `CalibrationPrompt` | The step's card: the instruction, a hint line, progress ring, pictogram (pose / tick / cross); opaque, world-locked with a lazy follow, as wide as its text |
| `scripts/vr/fp_wings.gd` | `FirstPersonWings` | First-person feathered wings in the NPC palette (one MultiMesh, one draw call) |
| `scripts/vr/comfort_vignette.gd` | `ComfortVignette` | Camera-attached vignette ring + motion measurement (rig yaw rate, smoothed speed over the bird's cruise, stroke-averaged acceleration; jumps re-seeded) and a slow proximity from held probe hits |
| `scripts/vr/vignette_model.gd` | `VignetteModel` | The strength curve and its attack/release |
| `scripts/vr/world_scale_driver.gd` | `WorldScaleDriver` | Growth: world_scale from the bird's span, log-space ramp, snap on a new body, camera near plane |
| `scripts/vr/vr_rig_extras.gd` + `scenes/vr/vr_rig_extras.tscn` | `VRRigExtras` | The package integration instances under the player's XROrigin3D; wires everything to the rig (a moved rig keeps its parts, a replaced one gets new ones); enforces PROCESS_MODE_ALWAYS under it |
| `scripts/vr/xr_mirror.gd` | `XRMirror` | Mirror screenshots of the head view (renders only around a capture) |
| `scripts/vr/vr_human_pose.gd` | `VRHumanPose` | Synthetic human (any span, proportions, wrist habit, capture style, seated) producing anatomically consistent grip poses |
| `scripts/vr/vr_pose_puppet.gd` | `VRPosePuppet` | Drives the rig nodes from a VRHumanPose (desktop dev, shots, "hybrid" real-head + scripted-arms in the simulator) |
| `scripts/vr/vr_math.gd`, `vr_profile.gd` | `VRMath`, `VRProfile` | Shared maths; per-feature CPU timing (off unless the harness or perf test turns it on) |
| `tests/unit/vr/vr_perf_bench.gd`, `tests/sim/perf/vr_perf_test.gd` | | The per-frame CPU bench (fix round 3): the unit suite pins its work, the on-demand `perf` suite gates its time |
| `scenes/dev/vr_dev.tscn` (+ `vr_dev.gd`, `vr_dev_env.gd`, `vr_stub_player.gd`) | | Dev scene: stand-in player rig (with a flight mode, `yaw_flagged`, optional calibration resource) + extras + practice field; desktop and simulator |
| `tests/unit/vr/*_test.gd` (+ `vr_memory_store.gd`, `vr_wing_calibration_mock.gd`) | | 158 headless tests (+ `vr_perf_bench.gd`). The calibration redesign replaced `wearer_test` (the automatic wearer re-check, deleted with its machinery) with `calibration_flow_test` (11 tests: first launch, the capture, implausible poses, cancel, persistence, nothing in flight changes the neutral, span refinement keeps it, a request in play pauses first, presence only raises the flag, the card) and updated `calibration_test` (the capture only on request), `span_refinement_test` and `calibration_load_test`; fix round 5 added `vr_session_test` (the OpenXR wiring through a stand-in interface); fix round 6 added `rig_lifecycle_test` (a replaced rig) and `sim_harness_test` (the harness's pacing arithmetic); the suite depends only on core contracts and its own mocks (fix round 4: the two checks that read the birds area's internal data moved to `tests/sim/birds_palette`) |
| `tests/sim/vr_sim.tscn`, `vr_sim.gd`, `sim_driver.py`, `run_vr_sim.sh` | | Simulator harness: self-verifying scene (world + the NPC budget as stand-ins) + SimRpc controller driver + verdict (its first-launch card is off: it measures the session) |
| `tests/sim/vr_calibration_sim.tscn`, `vr_calibration_sim.gd`, `run_calibration_sim.sh` (+ `sim_driver.py calibrate`) | | The calibration step in the simulator: the first-launch card, real controllers spread over SimRpc and captured, a B/Y cancel, `SetUserPresent` off/on (redesign) |
| `tests/shots/vr_pause_suggestion.*` | | The pause menu's "New player? Recalibrate wings" button (layout checked) and the card over the VR pause panel (redesign) |
| `tests/sim/flight_rig/vr_flight_rig_test.gd` | | Integration checks on flight's real `player.tscn` with the extras attached (fix round 2); run on demand, not part of the unit suite |
| `tests/sim/real_world/vr_real_world_vignette_test.gd` | | The vignette over the real world's orchard, forest and power line (fix round 4); on demand |
| `tests/sim/birds_palette/vr_birds_palette_test.gd` | | Drift report: VR's fallback palette and accent placement vs the birds area's current internal data (fix round 4); on demand, not a contract |
| `tests/shots/vr_shots.*`, `vr_plots.*`, `vr_plot.gd`, `vr_look_hands.*` | | Screenshots and plots (`vr_look_hands`: the natural look-at-your-hands poses, fix round 4) |

### How integration attaches it

```gdscript
# under the player's XROrigin3D (scenes/player/player.tscn is flight's; do it at runtime or in main.tscn)
var extras := preload("res://scenes/vr/vr_rig_extras.tscn").instantiate()
player.get_node("XROrigin3D").add_child(extras)
```

It also works anywhere else in the tree (it finds group `player_rig`,
retrying until the rig exists, and follows a rig that is deleted and
replaced, fix round 6). At runtime it moves the wings under the
origin (identity transform) and the vignette under the `XRCamera3D`, uses
the rig's grip `XRController3D`s (tracker `left_hand`/`right_hand`, pose
`grip`; UI's aim-pose pointers are ignored) and creates `VRGrip_L/R` only if
there are none. Nothing is edited in flight's scene. Verified on flight's
real `scenes/player/player.tscn` by both verifiers' probes (§9).

---

## 2. Design decisions

### 2.1 Session lifecycle and pausing (`VRManager`)
- States: `none -> begun -> synchronized -> visible -> focused -> stopping`
  (`session_state`, `session_state_changed`). `session_loss_pending` and
  `instance_exiting` quit the app (the runtime is going away).
- **Focus loss pauses with the pause menu.** `session_visible` (system menu,
  guardian, headset coming off), `session_stopping` and
  `user_presence_changed(false)` call `request_pause()`: from PLAYING or
  CAUGHT it emits `Events.menu_requested` first (UI pauses and shows the
  menu), falls back to `Game.set_state(PAUSED)` if nothing handled it, then
  emits `session_unfocused`. The order matters: UI *toggles* on
  `menu_requested` and pauses on `session_unfocused` only while playing;
  emitting `session_unfocused` first would make the menu request resume the
  game (pinned by `vr_manager_test.test_focus_loss_with_a_toggling_ui`).
  In MENU/PAUSED nothing is toggled. **Regaining focus never resumes**: the
  player resumes deliberately from the menu.
- **`VR.focused` = the session has input focus and the headset is worn**
  (fix round 4, engineering verifier: it stayed true after the headset came
  off until the runtime also sent `session_visible`, and the two made two
  focus losses). Presence off clears it at once and is the one focus loss;
  a `session_visible` after it finds focus already gone. Headset back on,
  session still focused: focused again and `session_focused`, the game
  stays paused.
- **The wiring is testable (fix round 5, engineering verifier).** The
  twelve OpenXR signals are connected by `connect_interface(source)`, the
  call `_ready` makes with the real interface, and the policies call the
  `runtime` object it recorded (`VR.xr` is unchanged). `vr_session_test`
  connects a stand-in carrying the same signals and methods and EMITS
  them: session begun (refresh policy: 60 -> 72 Hz asked for, physics 72,
  CPU/GPU sustained-high), synchronized, visible, focussed, stopping, loss
  pending and exiting (quit, via `quit_on_session_end`), recentered,
  refresh changed (physics follows), presence, perf notifications; a
  headset put back on while the session is only VISIBLE is not focus
  (mutant E30); `--refresh=90` and a runtime without 90 Hz. Round 4's V2
  tests called the handlers directly, so deleting a connect line or the
  policy at session start (E53) passed every test. The simulator harness
  now also checks `refresh_policy_applied` (the policy counted a run and
  the runtime shows the rate it chose), which the physics-tick check cannot
  see at 72 Hz (the project's own tick is 72).
- **`VR.presence_supported` (fix round 6).** True when the runtime reports
  the headset coming off and going back on: `OpenXRInterface.
  is_user_presence_supported()` (asked when the interface is connected and
  again at `session_begun`), or the first `user_presence_changed` event.
  Without it a removal only shows as lost focus, so the calibration's
  wearer re-check also treats a focus regain as "maybe put back on"; with
  it a focus regain is only the system menu closing and arms nothing
  (§2.3). The project setting `xr/openxr/extensions/user_presence=true`
  (§7, integration) turns it on.
- **Physics object picking is off in XR (fix round 5).** It is on by
  default in the project settings and cannot work in stereo; the engine
  turns it off itself with a warning the first time a mouse event reaches
  the desktop mirror window, which one simulator run caught
  (`sim_run_default_picking_warning.log`). `VRManager` switches it off
  with `use_xr`.
- **Refresh policy** (`choose_refresh_rate`): Settings `vr_refresh_rate`,
  0 = auto = **72 Hz everywhere** (QUEST.md §1.2: the safe Quest Pro
  default until OVR Metrics shows headroom; the simulator runs the rate the
  game ships with). An explicit 90 (or `--refresh=90`) is honoured; never
  below 72 unless nothing else exists; never above what the runtime offers.
  Until fix round 1, auto was 90 Hz off-device, "to exercise the stricter
  budget". That only measured this shared Mac's load (§8), and it meant the
  policy's own simulator default failed V1.
- **Physics tick = refresh**, applied at `session_begun` and again on every
  `refresh_rate_changed` (thermal throttling, setting changes), with
  `Engine.max_fps = 0` and vsync off on the desktop mirror (the compositor
  paces frames).
- CPU and GPU perf levels `SUSTAINED_HIGH` at `session_begun`; perf-level
  notifications are logged.
- **Foveation** at startup: level from `vr_foveation_level` (default 3,
  high), dynamic on, subsampled images off (Godot #123406), and the main
  viewport's `vrs_mode = VRS_XR` (without it the Mobile renderer ignores
  foveation, QUEST.md §0.2). The simulator reports foveation unsupported
  (and MSAA disables it on desktop anyway): no errors, no effect there.
- **Recenter**: `Events.recenter_requested` (UI, A/X long press) and the
  runtime's `pose_recentered` both call
  `XRServer.center_on_hmd(RESET_BUT_KEEP_TILT, true)` and emit
  `VR.recentered` once (on desktop only the signal).

### 2.2 Controller mapping (`VRControls`, `VR.controls`)
Reads the OpenXR controller trackers directly (one lookup per hand per
frame; tests inject a `reader`; left empty, the default, it reads the
trackers: fix round 6 removed the old default reader, a sentinel whose
body never ran), so it works in every scene.

| Input | Intent |
|---|---|
| menu (left ≡; the right one is the system button) | `Events.menu_requested` once per press |
| B (right `by_button`) held 0.8 s | `Events.menu_requested`, only while PLAYING/CAUGHT (not BOOT, where UI would open the main menu: fix round 2): a pause for right-handed players; a short B/Y stays UI's Back |
| A or X held 1.0 s | `Events.recenter_requested` |
| Y (left `by_button`) held 1.5 s | `VR.recalibrate_requested` (flight_vr.md's "Y-hold" recapture) |
| trigger, grip (analog) | `trigger(hand)`, `grip(hand)`; `is_*_down` with 0.6 on / 0.4 off hysteresis; `trigger_changed`, `grip_changed` signals |

UI de-duplicates menu presses within 250 ms (ARCHITECTURE), so VR and UI
both emitting for the same button is harmless.

### 2.3 Calibration (`WingCalibrator`, `VRCalibration`, `CalibrationPrompt`)
Redesigned on 2026-09-26 (the lead's decision after fix round 6; history
in §15). The maths follow FLIGHT_SPEC §5, so the numbers written into
flight's `WingCalibration` mean what `WingInput` expects: torso yaw from
the hand line (75° jump gate, 70° neck leash), neck-pivot shoulders,
reach / elevation / sweep -> extension (§5.5), wrist twist by swing-twist
about the calibrated forearm axis (§5.7). Kept refinements of §5.10: the
shoulder drop from body proportions (0.15 x stature, stature from the
standing eyes and the span, bounded by the hand line), the span as the
full spread (`fit_body`), and the neutral swung to the canonical arm
direction (`canonical_neutral`), so how high or far forward the arms were
held at capture does not change later readings (§3 V3).

**One explicit step is the only capture.** Wrist neutral, arm span,
shoulder height and the forearm / chord axes are captured only in the
calibration step, and only when the player is asked:
- **First launch** (no saved calibration, or a corrupt one): the step
  starts by itself as soon as the headset is on and the session focused,
  normally in the main menu, before the first flight (a run already under
  way is paused first). It has no timeout. Pressing Play or B/Y ends it:
  the defaults apply and it is not asked again this session (again at the
  next launch while uncalibrated). Taking the headset off abandons it
  quietly, and it comes back when the headset is on again.
- **Recalibrate**: Settings > Recalibrate wings, or the pause menu's "New
  player? Recalibrate wings" (both `UIRoot.recalibrate_requested`), or Y
  held 1.5 s (`VR.recalibrate_requested`), or `start_manual()`. If asked
  during play, the game pauses first through the menu request, so the
  pause menu shows. Nothing is ever captured in flight. The step times out
  after 45 s (`STEP_TIMEOUT`).
- **The card** (`CalibrationPrompt`): "Stand tall. Spread your wings,
  hands flat. Hold still." with a dimmer hint line under it. The hint
  reads "B or Y: cancel". If the pose has been wrong for a second, it
  says what to change (below), and it stays up for 0.4 s after the pose
  is right, so it does not flicker. The card also has a progress ring and
  a pictogram of the pose. It is opaque, world-locked with a lazy follow
  (it stays put for glances under 28°, then glides back in front, τ
  0.25 s), 1.25 m away and 14 cm below the eyes. It is at least 0.80 m
  wide and grows to fit its text, and is sized by world_scale. It costs 3
  draw calls while shown and none when hidden.
  - On success: "Wings calibrated / Arm span 1.62 m", a tick, a confirm
    haptic and a wing glow, shown for 2 s.
  - On cancel: "Calibration cancelled / Your wings are unchanged" (or
    "Using default wings"), a cross, shown for 1.5 s.
- **Captured** when the pose is plausible and still for
  `NEUTRAL_HOLD` = 1.0 s without a break. A one-frame tracking loss, a
  moving hand or a turning wrist starts the hold again. The capture
  averages over the hold. The gates are checked in this order; the first
  one that fails is the card's hint:

  | Gate | Hint when it fails |
  |---|---|
  | Head and both controllers tracked | (none shown for the first second; then "Keep both controllers in view") |
  | Grips more than 0.9 m apart | "Spread your arms wider" |
  | Grips less than 2.3 m apart | "Hold a controller in each hand" |
  | Both grips on the wrong side of the head | "Controllers in the wrong hands?" |
  | Each grip on its own side, within 40° of straight out | "Spread your arms out to the sides" |
  | Each arm within 25° of level | "Hold your arms level" |
  | Hands within 12 cm of each other in height | "Hold both hands at the same height" |
  | Grips within 12 cm of the same distance from their shoulders | "Spread both arms evenly" |
  | Each controller's forearm axis within 40° of the grip convention | "Hold the controllers as usual" |
  | Head within 30° of upright | "Stand tall, look ahead" |
  | Hands slower than 0.08 m/s and 25°/s (smoothed, τ 0.15 s) | "Hold still" |

  The capture's own check (the axis within 45°, measured from the fitted
  shoulders) remains as a safety net. If it refuses, the step ends as
  "Calibration not changed".
- **A capture is a fresh calibration of whoever holds the controllers.**
  Seating is judged by the capture alone: eyes below 0.75 of the stature
  the span implies. The standing eye height is recorded only for a
  standing capture. The glide reach and fold elevation go back to
  FLIGHT_SPEC's defaults, because the optional glide step went with the
  redesign. The result is persisted, written into flight's resource,
  flight's `WingInput.calibration_replaced()` is called, and
  `VR.recalibration_suggested` is cleared.
- **Cancel keeps everything.** A B/Y press that starts while the card
  waits (the Y-hold that opened it is no press), `cancel()`, the game
  going back into play (Play, Resume), the headset coming off, or the
  timeout: nothing is written, and flight's resource and trim are
  untouched.

**Nothing else ever touches the wrist neutral.** There is no automatic
capture, no wearer re-check and no card answered by a pose. The
re-check of fix rounds 5-6 is deleted: its last open defect was a landing
flare held on a perch answering its own card after one small movement or
a one-frame tracking blip, and being persisted as "flat". Three events
may mean a new player:
- the headset comes off and goes back on (user presence);
- focus is lost for at least `LONG_ABSENCE` = 60 s (a runtime without
  presence events shows a removal only as lost focus);
- the app starts with a saved calibration.

Each of them only raises `VR.recalibration_suggested` (signal
`recalibration_suggested_changed`), and only in VR. The UI's pause menu
then offers **"New player? Recalibrate wings"** in its top row, and the
run-so-far line moves to the tip's line. The flag is a hint and never a
capture.

**Still learnt in play: the arm span only** (fix round 4's strict rules,
unchanged). Genuine spread-arms poses while the game is played (never
paused, in a menu, or unfocused) count: two separate spreads, each its
80th-percentile sample, more than 5 cm wider, at most +10 cm per session.
This changes `arm_span` and `shoulder_width` and never the neutral or the
axes; that is pinned bit for bit. Seated detection stays as it was (below
the seated threshold for 5 s, with hysteresis; thresholds bounded by the
standing eyes; the Settings preference ORed in).

**One calibration, and it is VR's.** While the extras run, VR sets the
PlayerBird's `auto_calibrate` to false (and restores it when it leaves).
A capture flight makes through its explicit `begin_calibration` is adopted
and refined to VR's maths (`adopt` / `refine_foreign`), written back and
persisted. VR's calibration goes to every new PlayerBird and to a reset
resource, and VR's span is written back if flight's drifts.
Uncalibrated, VR never pushes its defaults into flight.

**Persistence**: `Settings["wing_calibration"]` holds the §5.11 field
names (Basis / Vector3 native; flat arrays accepted) plus VR's
`standing_eye`, and the deprecated `arm_span` mirror is kept. A corrupt
neutral or axis rejects the geometry whole: the defaults apply,
uncalibrated, so the first-launch step is due. A `capture_span` key left
by fix round 6 is ignored. Poses are read from the rig's nodes,
origin-local and divided by world_scale.

### 2.4 Growth and the near plane (`WorldScaleDriver`)
`world_scale = (span(mass) / (arm_span + 0.20 m))^exponent`, exponent from
Settings `world_scale_exponent` (default **1.0**, see §4), animated in log
space at <= 0.25 ln/s (sparrow -> eagle in 8.7 s), held while paused
(PlayerBird doesn't re-seat the camera then). **A new body is not growth**
(fix round 1): the first size of a player, a new run
(`Events.run_started`) and a respawn (`Events.player_spawned`) snap
straight to the target (they happen behind a fade; the next tick snaps
again in case the mass is set after the signal). With no player the scale
is left alone, so a player registered after the rig is never ramped from
1.0. Runs in `_physics_process` before PlayerBird
(`process_physics_priority = -100`) so each tick's rig offset uses the new
scale. Non-finite inputs never reach the rig (fix round 3: a NaN
`world_scale_exponent` made world_scale and the near plane NaN): a NaN/INF
exponent reads as 1.0, a NaN mass as no player, a NaN span as 1.5 m. Camera near plane = max(1 mm, `NEAR_K` x world_scale) with `NEAR_K` = **0.06**
since integration round 1 (was 0.03, FLIGHT_SPEC §10.1's value): the Quest
draws into a 24-bit depth buffer, where the near plane sets the precision
far away (ARCHITECTURE §7.5, now 0.02-0.065; `depth_precision_test`), and
0.06 still leaves the body sphere (0.27 x ws) far outside the near plane and
clips no feather of the first-person wings (`near_plane_test`). The player
scene's own camera default (`scenes/player/player.tscn`) is 0.06 too
(integration round 2: it said 0.03 until the rig extras attached). Nothing
is ever node-scaled.

### 2.5 Comfort vignette (`ComfortVignette`, `VignetteModel`)
- **Turns, speed and accelerations (fix round 5).** Strength = `setting x
  max(yaw_term, 0.7 x speed_term, 0.5 x accel_term x proximity)`:
  - the view's angular velocity (the rig's yaw rate; flight never pitches
    or rolls the view), 35 -> 150°/s;
  - **speed** (fix round 5, below): the rig's speed over the bird's own
    cruise speed, 1.3 -> 2.3 x;
  - the rig's sustained linear acceleration, 6 -> 20 m/s² perceived
    (a / world_scale), counted near a surface only.

  A fast attack (0.08 s) and a slower release (0.5 s); Settings
  `comfort_vignette` (default 0.6), 0 = off: strength exactly 0 and the
  node hidden (no draw call). The yaw and acceleration thresholds and
  weights are flight_vr.md §11.4's; the speed term takes its flow term's
  weight.
- **Speed is back, as speed over the bird's own cruise (fix round 5, the
  experience verifier: DESIGN asks for a "comfort vignette on fast
  turns/speed", and round 4, at the lead's direction, had dropped every
  speed response).** `speed_ratio` = the rig's speed, smoothed by two
  0.35 s low-passes (a flap's ±5 % surge is cut 6-20x, a dive shows within
  ~0.7 s), over `SizeRules.cruise_speed(player mass)` (the core contract:
  flight is tuned to it; `max_speed` is 2.6 x). Every steady cruise keeps
  the full view wherever it is flown, as in round 4; dives and boosts
  narrow it: 1.3 x cruise -> 0, 1.8 x -> 0.21 at the default setting,
  2.3 x and faster -> 0.42. It is scale-free (a sparrow's dive and an
  eagle's read alike, `vignette_steady_test`) and nothing but the speed
  moves it (the same fast glide reads the same over the orchard, the
  forest, the fence and in open sky, within 0.005; along the 36 real-world
  lines worst std 0.0006). Without a player (no cruise to compare with)
  there is no speed term.
  - **Why not optic flow.** flight_vr.md §11.4's version is optic flow =
    speed / the nearest surface. Round 3 measured it per frame on single
    rays and the ring pulsed with every crown and post; round 4 removed it.
    I prototyped it again on the slow held probe distances (held 1.5-5 s,
    faded over the probes' last 2 spans, rising with τ 0.6-1 s and falling
    with τ 2.5-5 s) and flew the real world's 36 lines in steady cruise:
    it follows the canopy's height along each line, and every variant read
    a worst std of 0.19-0.20 and slow periodic components of 0.06-0.11
    (`flow_term_sweep_round5.log`), the pulsing the lead ruled out, only
    slower. Speed over cruise is what DESIGN names, is steady whenever the
    speed is, and needs no surface. What it does not do: steady cruise
    skimming a hedge keeps the full view (round 3 narrowed it to 0.42
    there); §8.
- **The optic-flow term stays gone (fix round 4).** It was speed / nearest
  surface, from 3 single rays cast one per tick and forgotten the tick a
  ray missed. In STEADY straight flight over the orchard rows it snapped
  to 0.2-0.4 over each crown and drained in the gaps (a sawtooth, 0.3-2.3
  pulses a second), pulsed 0 <-> 0.42 through the forest and flashed on
  fence posts (the verifier's probes; `vr_plot_vignette.png` panel F
  reproduces it). A ring that swings in the periphery about once a second
  is itself a flicker stimulus, in the brief's signature places.
- **The one geometry input left is slow.** The acceleration term counts
  only with a surface near enough to see the motion by (fix round 3's
  proximity: 1 within 3 body spans, 0 beyond 8). Round 3 took it from the
  same per-tick rays, so it pulsed too. Now five probes (right, left,
  down, ahead, ahead-down, in the rig's yaw frame, 8 body spans long) are
  cast one per tick, the sides every 3rd tick; the nearest hit of the last
  `PROX_HOLD` = 1.5 s is kept (a sliding-window minimum: a ray that misses
  the gap between two trees changes nothing), and the proximity follows it
  with `PROX_TAU` = 1 s, so it moves at most ~1 per second and a row of
  trees or posts reads as one surface. The side probes are spheres swept
  as wide as the travel since that side's last probe (`cast_motion`): a
  thin ray aliased with a fence line and held it only now and then, and
  the proximity wandered (a probe of mine, `vignette_steady_test` posts
  surge: std 0.022 -> 0.004).
- The acceleration term counts sustained speed changes (dives, flares,
  flap surges) and vertical heave, **not the horizontal centripetal part of
  a turn**: the turn is the yaw term's job, and counting it twice narrowed
  the view in every gentle small-bird turn (a sparrow circling at 30 m
  radius and 9 m/s yaws 17°/s but "perceives" 2.7 / 0.141 = 19 m/s²). A
  refinement of flight_vr.md §11.4's "rig acceleration".
- **Averaged over one wingbeat (fix round 2).** The rig surges and heaves
  with every stroke, and the round-1 0.1 s low-pass let a sparrow's
  ordinary flapping climb hold the view at 0.22-0.29 and pulse it on every
  beat while hovering (a verifier's probe on flight's real PlayerBird). The
  mean acceleration over a window T is exactly (v(t) - v(t - T)) / T, so
  with T = flight's own stroke period (`PlayerBird.wing_state().
  stroke_period`, duck-typed, read every 6 ticks) a periodic beat cancels
  at every harmonic, and only a sustained surge, dive or flare is left.
  Without a stroke period (no flight in the scene) T = 0.8 s. A second
  fixed 0.5 s box follows: flight's period estimate converges over the
  first 2-3 strokes after a pause, and while it is off the second box
  cuts the leftover beat (0.25 s of extra delay for a real surge; with the
  period reported 30 % short a 1.25 Hz beat's residue falls 2.6x, from 18
  to 6.9 perceived m/s², `vignette_test`). The lateral (centripetal) part
  is removed against the window's mean heading (v_now + v_then), which is
  exactly perpendicular to the chord of a constant-speed turn. Zero until
  the ring spans the window after a re-seed.
- Measured on the **XROrigin3D's world motion**, which is exactly the
  artificial (flight) motion: PlayerBird displaces the body by the head
  delta and offsets the origin back, so physical head movement (never a
  visual-vestibular mismatch) doesn't count.
- **Jumps are not motion** (extended in fix round 1): a rig move > 250 m/s,
  a one-tick yaw step > 720°/s (3x flight's 240°/s comfort cap, which its
  physics enforces), a tick where `PlayerBird.yaw_flagged` is set
  (respawn, recenter re-aim) and the tick after `VR.recentered` are
  re-seeded, not measured, and the strength is left as it was. The first
  velocity after a (re)seed is the baseline, not an acceleration from zero
  (8 m/s in one tick would read 720 m/s²). A teleport also forgets the
  surfaces held from before (the proximity glides on).
- Drawn as a ring in **view space** (`skip_vertex_transform`): each eye gets
  it centred on its own optical axis at a fixed angular aperture (clear
  cone 55° -> 24° radius with strength, 20° soft edge, dark to 85°),
  independent of world_scale, near plane and IPD; `depth_test_disabled`, at
  twice the near plane; only the ring is geometry (the clear centre costs no
  fragments). One draw call when visible; its shader parameters are only
  written when they change.

### 2.6 First-person wings (`FirstPersonWings`)
Reworked in fix round 1: the wing read as "a feathered strip", its colours
drifted from the NPCs', and the hand primaries were short.
- **Shape, like the NPC models**: per wing, 30 feathers of one flat-shaded
  mesh (16 triangles), **one MultiMesh for both wings: 60 instances,
  960 triangles, 1 draw call** (measured in the renderer,
  `artifacts/vr/drawcalls.json`), one ShaderMaterial, no shadows.
  - 7 long pointed **primaries** are rooted along the forearm (a bird's
    hand wing), 14-32 cm inboard of the grip, and fan out and back from 3°
    to 75°.
  - 5 **primary coverts** sit over their roots.
  - 8 blunt **secondaries** (27-30 cm) run along the inner arm.
  - 5 **greater coverts** sit over the secondaries' roots.
  - 5 wide **lesser covert** plates form a smooth leading edge.

  The chord is ~0.36 m and the wingtip tapers.
- **One draw call, three outlines**: each instance picks pointed / blunt /
  plate in the vertex shader. The mesh carries every outline's half-width
  per vertex in COLOR. Facet normals come from screen derivatives, so the
  reshaped geometry stays flat-shaded. The upper palette is on the front
  face and the underside palette on the back.
- The leading primary reaches **10 cm past the grip** at full spread, so the
  drawn span is (grip span + 0.20 m) x world_scale = the bird's true span
  (FLIGHT_SPEC §11.4): your wings next to theirs is a true size cue.
- **Colours = the NPC palette of the player's species**:
  `BirdModels.wing_palette(sp)` (the birds area's contract for exactly
  this) supplies upper coverts / flight feathers / primaries, the
  underside and the accent. It is looked up duck-typed through the global
  class list, and a copy is the fallback if the birds area is missing or
  mid-edit. The accent goes where that species wears it (`ACCENT_AT`):
  - a wing bar on the greater coverts: wren, sparrow, pigeon;
  - dark primary tips: gull;
  - a trailing edge: starling, hawk;
  - a band: moth;
  - none: swallow, crow, eagle.

  Tier changes cross-fade over 0.8 s via two uniforms. A ±7 % brightness
  jitter per feather and darker vane edges make the layers read.
- Spread/fold: every feather rotates in the wing plane from its spread
  angle to lie back along the forearm, with the extension (flight's
  `wing_state().ext_l/ext_r` when present, so soar lock and the novice
  floor show; else the calibrator's own), lightly smoothed. Folded, the
  primaries keep a 20° stagger (it was 12°) so a closed wing shows layered
  tips.
- **A folding wing settles upper side up (fix round 2), continuously (fix
  round 3).** Relaxed hands hold the controllers palms-in, so a folded
  wing in the hand's plane was seen edge-on from the eyes, as a pale
  sliver of underside. The wing plane turns about the forearm from the
  controller's plane towards level (`fold_level_turn`), `FOLD_LEVEL` 0.8
  of the way at extension 0 and quadratically less above (a fifth of the
  way at 0.5; a spread wing follows the wrist exactly), as a perched
  bird's folded wing lies. Round 2 switched that turn on and off with a
  hard gate (forearm near vertical, turn > ~100°), so a folded wing
  flipped 52-82° when a wrist or elbow moved 1° across it and flickered
  under tracker noise (both verifiers). Both limits are singular ("level"
  has no direction about a vertical forearm; at 180° either way round is
  as good), so the turn's weight now fades smoothly to 0 towards each:
  smoothstep over the forearm's tilt from vertical (sine 0.15 -> 0.6) and
  1 - smoothstep over the turn angle (100° -> 180°). A 1° change of any
  input turns no feather more than 3.65° (sweeps of wrist roll through a
  full turn, elbows, the arm to vertical, the hand to the shoulder), and
  ±0.3° of tracker noise at the old gates moves feathers <= 1.9° a frame.
- The arm feathers lie along shoulder -> grip and hand over smoothly to the
  forearm as the grip comes within 30 -> 10 cm of the shoulder (fix round
  3: a hard switch at 5 cm; in a tuck the arm feathers now fold in along
  the forearm with the primaries, one closed wing instead of two groups).
- **A folding wing closes along the arm (fix round 3).** Before the level
  turn, the hand frame swings from the controller's forearm axis towards
  the arm's line (`fold_align_turn`: `FOLD_ALIGN` 1.0 x (1 - e)², fading
  to 0 as the two approach opposite, where the swing's axis is
  undefined), so the folded primaries lie back over the secondaries even
  when the wrist is bent. With the simulator's fixed controllers (pointing
  straight ahead: a wrist flexed ~60° from a natural grip) they used to
  stick up above the hands (`wings_fp_sim_controllers.png`, §8).
- Feather outlines are stronger (vane edge 0.58, a darker shaft), each
  feather's root third lies in the shade of the row above (fix round 3:
  folded, a covert row read as one flat paddle; shaded roots and lit tips
  scallop it into feathers), the covert plates carry a low ridge (30 %, they
  read as pillows up close), and the per-feather brightness jitter is
  ±7 %.
- The shader has no colour mapping of its own (fix round 2): each feather
  group samples the palette columns named in `GROUP_COLUMNS` (primaries:
  upper primaries / under flight feathers; secondaries: upper flight /
  under flight; the three covert rows: upper / under coverts, with a
  shade), passed as uniforms, so tests can check what is drawn.
- Writes the UI occluder stencil (64): menus and the laser never paint over
  the player's wings (UI contract). A wing whose controller loses tracking
  collapses. The layout is skipped when the complete pose key (both grips
  with full bases, both shoulders, extensions, world_scale, validity) is
  unchanged.
- **The layout costs a fifth of what it did (fix round 5; both verifiers:
  the VR scripts took ~0.26-0.29 ms a frame in the simulator, the wings
  ~90-100 µs of it).** Each feather's transform in its frame (hand or
  arm) depends on the extension only; it is cached per wing (`_local`)
  and a feather in origin space is then ONE native `Transform3D` product,
  frame x local, uploaded with `MultiMesh.set_instance_transform` (a
  native call), with a CPU copy for readback. Round 4 did ~16 vector
  operations and 12 scalar writes into an upload buffer per feather in
  GDScript (the scalar writes alone were 14 µs), and its fan cache never
  hit: the key was a 32-bit copy of the 64-bit extension
  (`wings_test.test_a_held_extension_rebuilds_no_fan` pins the cache now;
  an extension that has arrived snaps to its target). Wings: 38-46 ->
  19-21 µs headless while flapping, 87.7 -> 9.3 µs in the simulator.
- **Folded wings seen from the eyes (fix round 5, the experience
  verifier's look-at-your-hands sheets: "stepped slabs or planks across
  palettes").** Seen from the eyes a folded wing's far end is the wrist,
  where the covert plates' square roots (they make the spread wing's
  smooth leading edge) read as a sawn-off plank. As a wing folds
  (`fold_shape(e)` = (1 - e)², per wing through the shader uniform
  `fold_lr`), the plates' roots taper to a feather's end (to 0.3 of the
  width at the root), so the staggered plates make a scalloped edge
  towards the hand; every folded feather gets an outline round its exposed
  end and a wider vane edge; the sheen that outlines dark plumage is
  brighter (x2.4 + 0.05, was x1.8 + 0.03). A spread wing is exactly as
  before (fold 0). Evidence: `wings_look_at_hands_sheet.png` (now twelve
  poses: the builder's six and the verifier's palettes: gull, pigeon,
  swallow, starling, wren, moth), `sim_wings_real_controllers_fplus.png`,
  `wings_fp_held.png`; `wings_test.test_folded_coverts_become_feathers`
  pins the uniform per wing.
- **The folded wing reads as feathers (fix round 4, a verifier's
  look-at-your-hands shots).** Folded, the wing showed 2-3 rounded
  wing-coloured plates per hand, and the crow an almost featureless navy
  blob. The covert plates are square-ish on purpose (they make the spread
  wing's smooth leading edge), so as the wing folds they now narrow to
  0.55 of their width and lengthen 1.45x (quadratically with the fold;
  unchanged when spread, so the spread wing and its wingtip are exactly as
  before): folded they are longer than wide (length/width >= 1.5, spread
  0.57) and overlap in rows like a perched bird's coverts, each tip a
  scallop over the next, with no gaps. The primary coverts fold in a
  slightly wider fan (160-175°, was 166-172°). On dark plumage (crow,
  starling, swallow) the vane edge is a lighter sheen instead of a darker
  line, so the feathers outline each other (a darkened edge vanished into
  a navy vane). Evidence: `wings_look_at_hands_sheet.png` and
  `wings_look_*.png` (the verifier's natural poses, `tests/shots/vr_look_hands.tscn`),
  `wings_outside_sim_controllers.png`, `wings_outside_tuck.png`;
  `wings_test.test_folded_coverts_become_feathers`.

### 2.7 Haptics (`VRHaptics`, `HapticPatterns`, `VR.haptics`)
Quest's simple haptics ignore frequency and delay (QUEST.md §3.2), so the
patterns are amplitude x duration x rhythm, scheduled in code:

| Pattern | Source | Feel |
|---|---|---|
| flap | `player_flapped(side, strength)`, that side | 1 x 35 ms thump, 0.2 + 0.6 x credit |
| catch | `bird_caught` with the player as predator | double bite: 2 x 45 ms, 110 ms apart, 0.8 then 1.0 |
| collision | `player_collided(impact >= 0.5)` | 1 x 90 ms crack, 0.35..1.0, the impact side twice the other |
| brush | `player_collided(impact < 0.5)` (wing brush) | 12 ms tick on the touching side |
| stall | telemetry `stalled` / `stall_warning` > 0.6, `player_stalled` | 15 ms buffet every 100..150 ms, jittered (fix round 3; was 20 ms every 70..110 ms, 22 % duty on its own) |
| updraft | telemetry `wind_l_y` / `wind_r_y` (else `in_updraft`) > 0.5 m/s | 15 ms throbs at 3..6 Hz, per wing |
| danger | `threat_changed(level >= 0.35)`, held (see below) | heartbeat pair (2 x 20 ms, 150 ms apart; flight_vr.md §13, was 2 x 30 ms) every 1.0 -> 0.5 s |
| caught | `player_caught` | 1 x 280 ms at 1.0 |
| perch | `player_perched` | 2 x 12 ms ticks |
| confirm | calibration captured | 2 x 15 ms ticks |

Rules: at most one start per hand per 40 ms unless the new pulse outranks
the last (collision > caught > catch > stall > flap > danger > updraft >
ticks); per-pattern minimum intervals (flap 120 ms, catch 300 ms, ...); a
new pulse replaces the one playing (OpenXR), and the unplayed rest isn't
budgeted; **duty <= 30 % in every 1 s window per hand**, shared out (fix
round 3; a verifier's probe: with stall + updraft + danger busy, a catch
reached the hands whole 6 times in 24, and a stalled player felt 15 of 20
flaps):
- the continuous rhythms (stall, updraft, danger) together use at most
  15 %. The danger heartbeat's rate says how close the threat is, so its
  share (8 %: 2 x 20 ms pairs at 2 Hz at most) is kept free and it is never
  slowed; the buffet and the throb share the rest and slow down together
  in proportion when they would need more (`continuous_stretch`, aiming
  10 % under), and a beat that does not fit waits a tick or two instead of
  being skipped;
- routine pulses (flap, ticks) may fill to 21 %;
- catch, collision and caught (priority >= 70) to 30 %: at least 90 ms of
  every second is theirs, so a double bite and a crash are felt whole; a
  pulse that still does not fit is shortened to the room left (caught:
  >= 150 ms with the rhythms busy, 280 ms from quiet hands);
- a continuous beat never cuts into or crowds another pulse (it waits; the
  second beat of a heartbeat pair up to 100 ms), and a discrete pulse that
  meets the 40 ms rule or a stronger pulse waits for its turn (at most
  60 ms) instead of being dropped.

Settings
`haptics` scales amplitude and 0 sends nothing; gameplay haptics stop while
paused (a calibration confirm still plays); telemetry is polled at 30 Hz.
**The danger heartbeat holds** the last reported level (fix round 1; it
used to die 2 s after the last report). `threat_changed` is a change
signal: GameLoop re-emits only when the level moves by 0.02 and sends 0
when the threat ends. It stops on a report below 0.35 (queued beats
dropped), when the hunter dies or is freed, when the game leaves
PLAYING/PAUSED, on `run_ended` and on `player_spawned`; a pause silences it
and play resumes it. Output: `XRInterface.trigger_haptic_pulse("haptic",
tracker, 0, amp, dur, 0)` (`VRHaptics.XRSink`; tests inject a recorder
as its `xr` and check each hand reaches its own controller).

### 2.8 Pause keeps head and hands alive
`VRRigExtras` sets the XROrigin3D to PROCESS_MODE_ALWAYS when it attaches
and corrects any node under it that would stop on one side of the pause
(PAUSABLE: stops while paused; WHEN_PAUSED: stops in play), with a
warning, so head tracking, hands, wings, vignette, calibration, the prompt
card and UI rays keep running in play and while `SceneTree.paused`. Both
modes are pinned (fix round 6: the engineering verifier's mutant that
corrected PAUSABLE only passed the suite), added under the rig and already
there at attach.

**Leaving the tree is not being deleted (fix round 5, both verifiers'
probe).** The extras move the wings onto the origin and the vignette onto
the camera. Round 4 freed both in `_exit_tree`, so any `remove_child` /
`add_child` or `reparent` of the player (a respawn, a scene rebuild) lost
the first-person wings and the comfort vignette for the rest of the
session, silently, and the pause-rule hook with them. Now leaving parks
the parts (hidden, not processing), re-entering restores them, re-wires
the rig and reconnects the hook (`_ready` does not run again), and the
vignette forgets the motion from before the move; the parts are freed
only with the extras (`NOTIFICATION_PREDELETE`).
`pause_test.test_rig_leaving_and_reentering_keeps_its_parts`: remove/add
and reparent, the extras removed alone (parked) and added back, then
deleted (the parts go too).

**A replaced rig (fix round 6, engineering verifier).** With the extras
placed away from the rig (the `player_rig` group lookup: e.g. a sibling in
`main.tscn`, the easy editor path) a respawn that deletes the player and
adds a new one used to hand VRCalibration the freed wings: a SCRIPT ERROR
in `try_attach` before the world-scale driver was wired, and the new rig
had no wings, no vignette and no growth for the rest of the session. Now
`try_attach` makes new parts when the old ones went with the old rig
(`_ensure_parts`), never picks a rig whose player is being deleted
(`_doomed`), and re-attaches at once: when the rig goes (`_process`) and
when a new rig enters the tree (`_on_node_added`), not at the 0.5 s retry.
`rig_lifecycle_test` (its own file: exactly one rig and one player in the
tree): the old rig freed, and queued with the new one added in the same
frame; within 3 frames the new rig has shown, laid-out wings wired to it
and the calibrator, the vignette on its camera measuring its motion, the
calibration glow and poses on it, the world-scale driver on it, and
growth (an eagle's mass moves its target 0.141 -> 1.235); an attach in the
very frame of a respawn takes the live rig. The engineering verifier's
`r5eng` probe passes.

---

## 3. Perfection criteria: how each is verified

Commands (from the project root):

```bash
# Headless unit suite (158 tests, ~30 s)
tools/gd.sh vr --headless res://tests/runner.tscn -- --suite=unit/vr
# Integration checks on flight's real player.tscn (7 tests, ~14 s; not in the unit suite)
tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=flight_rig
# The vignette over the real world geometry (orchard, forest, power line; ~4 s; on demand)
tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=real_world
# Drift report against the birds area's current internal colours (on demand; not a contract)
tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=birds_palette
# Every verifier probe (tests/probes/vr, their own sandbox)
tools/gd.sh vr_probes --headless res://tests/runner.tscn -- --dir=res://tests/probes/vr
# Fix rounds 6 and 5's mutation runs (a scratch copy); round 4's old-code check and mutation run
python3 artifacts/vr/mutate_round6.py "$PWD"
python3 artifacts/vr/mutate_round5.py "$PWD"
python3 artifacts/vr/old_code_check_round4.py "$PWD"
python3 artifacts/vr/mutate_round4.py "$PWD"
# Simulator harness at the policy's default (72 Hz): starts the SimRpc driver, runs tools/xr.sh, gives a verdict
tests/sim/run_vr_sim.sh --tag=default
# The calibration step in the simulator (first-launch card, real controllers spread and captured over SimRpc,
# B/Y cancel, headset off/on); --fplus for clean Forward+ mirror shots
tests/sim/run_calibration_sim.sh [--fplus]
tests/sim/run_vr_sim.sh --refresh=90 --tag=hz90      # the optional 90 Hz rate (see §8)
# The per-frame CPU time gate (on demand: wall-clock time on this shared Mac is not deterministic)
tools/gd.sh vr --headless res://tests/runner.tscn -- --dir=res://tests/sim --suite=perf
# Clean Forward+ mirror images (the Mobile renderer paints MoltenVK magenta tiles on this Mac)
tools/xr.sh 60 "--rendering-method forward_plus res://tests/sim/vr_sim.tscn" -- --shots_only --tag=fplus
# fps only, with / without every VR feature (bare baseline)
tools/xr.sh 80 res://tests/sim/vr_sim.tscn -- --fps_only --tag=fps [--bare] [--refresh=90]
# Desktop screenshots and plots
tools/gd.sh vr --rendering-method forward_plus --resolution 1280x960 res://tests/shots/vr_shots.tscn
tools/gd.sh vr --rendering-method forward_plus --resolution 800x600 res://tests/shots/vr_look_hands.tscn
tools/gd.sh vr --rendering-method forward_plus --resolution 640x360 res://tests/shots/vr_plots.tscn
# The pause menu's "New player? Recalibrate wings" (layout checked, exits 1 on a failure) and the card over the VR pause panel
tools/gd.sh vr --rendering-method forward_plus --resolution 1280x960 res://tests/shots/vr_pause_suggestion.tscn
# Dev scene: desktop (8 s, the V9 log) / simulator (real head, scripted arms, the body turned to look
# along the right wing; --demo: spread, flap, wrists up as a gull, a hard turn; one shot each)
tools/gd.sh vr --rendering-method forward_plus --resolution 960x540 res://scenes/dev/vr_dev.tscn -- --autoquit=8
tools/xr.sh 24 "--rendering-method forward_plus res://scenes/dev/vr_dev.tscn" -- --puppet --demo --torso_yaw=66 --xrdiag --xrshot=7,11.1,15,20 --xrshot_dir=vr --xrshot_prefix=dev_sim
```

### V1 Simulator: FOCUSED, fps >= 0.95 x refresh over 20 s, tick == refresh, zero script errors
`tests/sim/run_vr_sim.sh`: the harness waits for FOCUSED, checks
`Engine.physics_ticks_per_second == round(display_refresh_rate)`, both grip
controllers and the head tracked, then flies the stand-in player (reporting
flight mode `flying`) on a 30 m circle at 9 m/s over **the real world**
(`scenes/world/world.tscn`, spawn) with wings, vignette and world scale
running, and counts frames over 20.0 s. **Fix round 2: the game's NPC
budget is in the scene** (the verifier noted the scene was lighter than
the game): 60 stand-in birds (`--npcs=60`, the default; each a separate
~1k-triangle flat-shaded body with its own material and shadow, 12 cm to
1 m long, circling at 8-90 m and moved every physics tick). The frame then
carries 96 draw calls on average (123 worst; the world alone 61/70) and
101k primitives, against the budgets of 150 and 300k. The stand-ins are the
harness's own, since the AI and birds areas are in progress. The wrapper
fails on any `SCRIPT ERROR` / unexpected `ERROR`/`WARNING` in the full log
(tolerated: engine/runtime exit noise present in every simulator run of
every area, listed in the script).

| run | refresh | scene | fps (20 s) | slow frames | ticks | load avg | script errors | verdict |
|---|---|---|---|---|---|---|---|---|
| `sim_result_default.json` (fix round 6, final code, no override) | 72 (auto) | world + 60 NPC stand-ins, 96 draw calls | **71.55** (>= 68.4) | 6 (0.4 %) | 72 = 72, policy ran | 8.3 | 0 | **PASS** (all 14 checks) |
| (fix round 6, before the last rig-extras edit) | 72 (auto) | the same | 68.55 | 67 (4.9 %) | 72 = 72, policy ran | 12.0 | 0 | PASS (all 14 checks) |
| `sim_result_default_load15_fail.json` (fix round 6, final code, another area's eight headless runs at ~95 % CPU each) | 72 (auto) | the same | 62.92 | 180 (14.3 %) | 72 = 72, policy ran | 15.3 | 0 | FAIL (fps only; GPU 4.82 ms as in the passing runs, every VR script +25-45 %: contention) |
| `sim_result_default.json` (fix round 5, final code, no override) | 72 (auto) | world + 60 NPC stand-ins, 96 draw calls | **69.85** (>= 68.4) | 42 | 72 = 72, policy ran | 11.2 (rising from 7) | 0 | **PASS** (all 14 checks) |
| (fix round 5, the same run before the last test-driven edits: the extension snap, the removed seated rule) | 72 (auto) | the same | 71.8 | 3 | 72 = 72, policy ran | 7.0 | 0 | PASS (all 14 checks) |
| `sim_result_default_picking_warning.json` (fix round 5, first run) | 72 (auto) | the same | 71.95 | 0 | 72 = 72, policy ran | 5.3 | 0 (one engine warning: object picking in stereo, §2.1; fixed) | harness PASS (14/14), wrapper FAIL on the warning |
| (fix round 4, final code, no override) | 72 (auto) | world + 60 NPC stand-ins, 95 draw calls | 70.25 (>= 68.4) | 32 | 72 = 72 | 14.4 (another agent's 5 pacing sims at ~100 % CPU each) | 0 | PASS (all 13 checks) |
| `verify/r1x_sim/`, `verify/r1eng_sim_result.json` (the re-verification's own runs, round-4 code) | 72 | the same | 68.45 / 69.56 | 75 / (not reported) | 72 = 72 | 13.6 / 11.7-14.7 | 0 | PASS |
| (fix round 3, final code, no override) | 72 (auto) | world + 60 NPC stand-ins, 96 draw calls | **71.9** (>= 68.4) | 1 | 72 = 72 | 6.6 | 0 | **PASS** (all 11 checks) |
| (fix round 3, three earlier runs during this round's changes) | 72 (auto) | the same | 71.55 / 69.6 / 71.8 | 7 / 50 / 3 | 72 = 72 | 9.9 / 12.0 / 7.3 | 0 | PASS x3 |
| (fix round 2, no override) | 72 (auto) | world + 60 NPC stand-ins, 96 draw calls | **71.55** (>= 68.4) | 8 | 72 = 72 | 9.1 | 0 | **PASS** (all 10 checks) |
| (fix round 2, first run of the same code) | 72 (auto) | the same | 71.5 | 10 | 72 = 72 | 7.7 | 0 | PASS |
| `sim_result_default_load13_fail.json` (fix round 2, same code, other agents' 10 Godot runs at ~90 % CPU each) | 72 (auto) | the same | 67.56 | 88 | 72 = 72 | 13.0 | 0 | FAIL (fps only) |
| (fix round 1, kept in §9) | 72 (auto) | world only, 61 draw calls | 71.35 | 13 | 72 = 72 | 12.2 | 0 | PASS |
| `verify/sim_probe_r2x_default.json` (a verifier's own run, round 1 code) | 72 | world only | 71.6 | | 72 = 72 | 6.4 | 0 | PASS |

**Fix round 6, frame pacing** (the experience verifier: the mean fps hides
hitches). The result now carries `metrics.fps.frame_ms`: the 50th, 95th
and 99th percentile and the maximum of the window's frame intervals, the
72 Hz budget and the frames longer than 1.5 intervals (a visible hitch),
and the log prints one `SIM pacing` line (`frame_pacing()`, pinned headless
by `sim_harness_test`). The final run at load 8.3: p50 13.89 ms (budget
13.89), p95 14.40, p99 17.44, max 25.16, 6 of 1433 frames (0.4 %) over
1.5 intervals. At load 12.0 the same scene read p95 20.80 / p99 26.39
(4.9 % hitches) and at load 15.3 p95 25.28 / p99 30.76 (14.3 %, the fps
failing): the median frame stays on time and the tail follows this
shared Mac's load (the VR scripts take ~0.15 ms of the frame,
`vr_usec_per_call`), which is why the percentiles are reported, not gated: integration repeats V1 on
`main.tscn` and on the device with OVR Metrics, where they are the
numbers to judge.

Fix round 5 adds a 14th check, `refresh_policy_applied` (§2.1), and the
VR scripts' own cost fell from ~257 µs a frame (round 4, load 14.4) to
~134 µs (load 7.0) / ~146 µs (load 11.2; wings 87.7 -> 9.4-10.1 µs, §5):
the fps margin no longer rests on the VR area's share; at load 11-13 the
margin is the machine's (round 2's code failed once at load 13 with every
script and the frame slowed alike, §3 V1 below). Fix round 3 adds an 11th check, `focused_through_the_fps_window`: the fps
only counts if the session stayed focused the whole window (VR's
`focus_losses` counter, which a verifier found was never read). Fix round
4 adds `foveation_reaches_the_renderer` (the main viewport's VRS mode is
VRS_XR: mode 2; the simulator reports foveation unsupported, so this is
the part that can be checked here) and `recenter_faces_forward` (the
driver selects the simulated head alone and turns it left with the
simulator's ROTATE_H_POS key; the harness reads 40.0° of head yaw, calls
`VR.recenter()` and reads 0.0°, height kept: `XRServer.center_on_hmd`
really re-centres the tracking space; the engineering verifier's mutant
R10 survived because no test observed it).

The failing run (round 2) is machine contention, not the scene: the same code
passed before and after it, its GPU time was unchanged (4.84 vs 4.74 ms),
and every script cost rose by ~45 % at once (wings 85 vs 62 µs,
calibration 64 vs 46), the signature of a starved CPU; the reruns waited
for the load to fall below 9. The UI and audio are still not in the scene
(in progress); integration should repeat V1 on `main.tscn`. Here all
scripts of the scene take 0.21 ms of the 13.9 ms frame and the GPU
4.7 ms; the per-feature VR costs are `vr_usec_per_call` in the result
(§5).

### V2 Focus loss/regain -> pause and menu
`vr_session_test` (fix round 5, 4 tests): the same paths through the
OpenXR signals themselves, emitted by a stand-in interface connected with
`VRManager.connect_interface` (§2.1): every session signal reaches its
handler; headset off in play pauses with the menu, once; headset on while
the session is only VISIBLE is not focus, `session_focussed` then is
(mutant E30); the policy at session start (E53); disconnecting removes
all twelve connections. Round 4's tests below call the handlers directly.

`vr_manager_test`:
- `test_focus_loss_pauses_with_the_menu`: visible -> exactly one
  `menu_requested`, `Game.PAUSED`, tree paused, `session_unfocused`;
  regaining focus keeps it paused and doesn't toggle.
- `test_focus_loss_with_a_toggling_ui`: a UI-like listener that toggles on
  the menu request ends PAUSED, one toggle.
- `test_focus_loss_outside_play_changes_nothing` (MENU, PAUSED).
- `test_caught_moment_pauses_too`.
- `test_headset_removed_pauses` (`user_presence_changed(false)`).
- `test_session_stopping_pauses`.
- `vr_presence_test.test_headset_off_clears_focused_once` (fix round 4):
  headset off -> `focused` false at once, one pause, one
  `session_unfocused`, one menu request, also when `session_visible`
  follows; session focused but headset off -> not focused; back on ->
  focused, `session_focused`, still paused; presence toggling alone
  follows it. Fails on the round-3 code (`old_code_check_round4.log`:
  focused stays true, two focus losses).
  `test_a_running_game_pauses_on_any_loss_signal`: a game PLAYING with
  the headset already off is paused by any loss signal, without a second
  focus loss (round 3 had no "focused without the headset" state; this
  test guards the first round-4 draft's regression, see §12).

### V3 Calibration
**The calibration step (redesign, 2026-09-26)**
(`calibration_flow_test`, 11 tests). Each test runs the real service with
a private store and a stand-in PlayerBird that has a WingInput and a
WingCalibration look-alike, at 72 Hz. The design is in §2.3.
- `test_first_launch_asks_before_the_first_flight`:
  - In the headset with nothing saved, the card comes up by itself. Its
    text is exactly "Stand tall. Spread your wings, / hands flat. Hold
    still." and the hint reads "B or Y: cancel".
  - It waits through 50 s of arms down and flapping (up to 10° under
    level) and captures nothing.
  - The arms come up and stay still, and the capture follows 1.21 s after
    they stop (the hold itself is 1.014 s). Then: the confirmation with a
    tick; persisted; flight's resource written with VR's neutral; flight's
    trim told; the owner's 12° / -8° habit commands no pitch.
  - No card comes up by itself on the desktop, with the headset off (it
    appears once the headset is on), or with a saved calibration.
  - When a run is already under way, the game is paused first.
- `test_first_launch_step_ends_with_the_players_choice`:
  - Play ends the card ("Using default wings"), and so does B.
  - After either, the card does not come back this session and nothing is
    captured.
  - With the headset off, the card goes and nothing is captured; with the
    headset back on, the card returns.
- `test_a_stable_spread_is_captured_in_about_a_second`:
  - The capture comes 1.43 s after a 0.5 s arm movement ends, and the
    ring fills steadily.
  - One lost frame 0.8 s into the hold resets the ring, and the capture
    comes a full second later. That lost frame was the old design's open
    defect.
- `test_unstable_or_implausible_poses_are_never_captured`: 14 poses, each
  held 4 s while the card waits. None is captured, the ring never
  completes, and the card's hint names the problem:
  - hands moving: "hold still";
  - a wrist rolling: "hold still";
  - a tracking blip every 0.5 s;
  - one controller untracked: "Keep both controllers in view";
  - the simulator's resting controllers, 0.6 m apart: "spread your arms
    wider";
  - arms 45° low, or 40° raised: "hold your arms level";
  - one hand 20 cm higher: "hold both hands at the same height";
  - hands 55° forward: "spread your arms out to the sides";
  - one arm spread and the other controller on a shelf 2.1 m away:
    "spread both arms evenly";
  - swapped controllers: "controllers in the wrong hands?";
  - controllers held upright like torches: "hold the controllers as
    usual";
  - a controller 2.6 m away: "hold a controller in each hand";
  - head bent 45°: "stand tall, look ahead".

  Nothing is written. Afterwards the plausible spread is captured by the
  same step.
- `test_cancel_keeps_the_old_calibration`: A calibrates; then B, a 1.9 m
  player with a ±20° habit, holds a spread with the ring already past
  0.3. The step then ends in one of these ways:
  - B on the right controller, or Y on the left (through VR.controls'
    real input path);
  - `cancel()`;
  - the game resumed;
  - the headset off;
  - the 45 s timeout;
  - a grip the capture refuses.

  After each, and after a further 3 s of B spreading: the calibration is
  equal bit for bit, VR's and flight's neutral and axes are identical,
  nothing is written, and flight's trim is untouched. A's flat wrists then
  command exactly the same pitch. The Y-hold that starts a step does not
  cancel it on release; a new press does.
- `test_persisted_and_reloaded`: captured by the first-launch step, then
  sent through a real ConfigFile and reloaded at the next launch.
  - Every field matches: floats within 1e-9, rotations within 1e-6 rad.
  - Flight gets the calibration.
  - The launch starts no step and captures nothing from spreads or a
    flare, and only raises the pause menu's suggestion (none on the
    desktop).
  - The owner's 15° / -10° habit reads flat.
- `test_nothing_in_flight_changes_the_wrist_neutral`: the bird goes
  through a flight's everyday moments:
  - a still dive-trim glide held 5 s;
  - landing flares of 15° and 20°, held on the perch with a one-frame
    blip and a small move in each;
  - the headset off and on, with the flare held in the pause menu;
  - the system menu;
  - a 61 s absence;
  - a 6° re-grip;
  - Y tapped.

  No card ever comes up and nothing is ever capturing. VR's, flight's and
  the persisted neutral and axes are identical bit for bit, flight's trim
  is never voided, and flat wrists command exactly the pitch they did.
  Only the suggestion rises.
- `test_span_refinement_never_touches_the_neutral`: a cramped capture
  grows by more than 5 cm from spreads in play. The span is persisted and
  flown, while the neutral and axes (VR's, flight's, persisted) stay
  identical.
- `test_recalibrate_during_play_pauses_first`: the Y-hold in flight
  pauses the game through one menu request, and the card is up. B's
  spread is captured in the pause menu. Resuming mid-step ends it with
  nothing captured.
- `test_presence_change_only_raises_the_flag`: the headset off and on
  raises `VR.recalibration_suggested` and signals it once, with no card,
  no capture, nothing written and the calibration unchanged. A completed
  step clears it. 10 s without focus raises nothing; 60 s raises it. On
  the desktop nothing is ever raised.
- `test_the_card`: checks the instruction, the cancel hint, and the hint
  "Hold your arms level" after a second of relaxed arms. The card is wide
  enough for its text, the smaller hint line is at least 1.5° tall, and
  the text fits the card's height. The ring fills; the confirmation shows
  "Wings calibrated / Arm span ..." with a tick; a cancel shows a cross
  and "Your wings are unchanged"; the card is gone when idle.
- **In the simulator** (`tests/sim/run_calibration_sim.sh`, VERDICT PASS
  with Mobile and with Forward+):
  - the first-launch card comes up in the real session;
  - the resting controllers are not captured (hint "Spread your arms
    wider");
  - the SimRpc driver moves (A/D, S) and turns (yaw, pitch) the REAL
    simulated controllers into a spread;
  - the capture comes 1.22 / 1.28 s after the pose stream last showed
    motion, with span 1.54 m, drop 0.27 m and grip axes 12-19° from the
    convention;
  - the simulator's B/Y key cancels a new step, and the calibration is
    unchanged;
  - `DeviceService/SetUserPresent` off and on only raises the flag;
  - the driver leaves `persistent_data.json` unchanged.

  Shots: `sim_calibration_card/holding/done/cancelled(_fplus).png`.
- The pause menu (`tests/shots/vr_pause_suggestion`, 13 checks): "New
  player? Recalibrate wings" appears when the flag rises, at once, fits
  the top row inside the 60 px margins and overlaps nothing. The run so
  far moves to the tip's line. A click emits `recalibrate_requested` and
  the card comes up over the VR pause panel, still paused. When the flag
  clears, everything is back. Shots: `pause_plain.png`,
  `pause_new_player.png`, `pause_card_vr.png`.
- `calibration_test.test_poses_are_read_relative_to_the_origin_even_nested`
  (fix round 5, mutant F06): the head and grips are read in tracking space
  whether they hang directly under the origin (their own transform, the
  fast path) or under an offset node below it.
- `calibration_test.test_hands_behind_the_back_fold_the_wing` (fix round
  5, mutant E28): straight arms swept 60° back read e_back(-60°) = 0.20 of
  the same arms swept 60° forward, for every player of the brief's grid
  within 0.03; 80° back folds completely; 20° back stays spread.

**Fix round 4, span refinement** (`span_refinement_test`, 6 tests; the
real service `VRCalibration.tick` with a private store, a synthetic 1.6 m
player at 72 Hz; each scenario asserts the span, the persisted span, the
same half fold's extension, a sparrow's world_scale and the seated flag
before vs after):
- `test_everyday_moments_never_change_the_span`: a controller set down on
  a table 1.8 / 2.0 / 2.15 m from the other grip for 4 s (then a spread,
  then 6 s looking down with a 15 cm knee dip: the verifier's
  `r4x_span_inflation` scenario); a controller on a shoulder-high shelf 2 m
  away with the other arm spread; a controller handed to someone 2 m away
  (swaying); controllers held together (in front, and both in one hand
  stretched out); turning round with the arms spread (180° in 1.2 s,
  three times, and in 16 s); stretching overhead and reaching forward.
  **None changes anything** (span within 0.1 mm, extension within 0.01,
  world_scale within 1e-4, not seated). Round 3: spans 1.80 / 2.00 / 2.15
  / 2.00 / 2.06 m, half fold 0.000, world_scale 0.120 / 0.109 / 0.102,
  "seated" (`old_code_check_round4.log`).
- `test_tracking_glitches_do_not_count`: 40 cm two-tick jumps, and a slow
  7 cm drift over 1.2 s (under the hand-speed gate) in three spreads of
  the true span: unchanged (the 80th percentile; mutant N13, the maximum,
  is caught).
- `test_no_refinement_in_menus_or_unfocused`: a player with 25 cm longer
  arms spreads three times in the pause menu (tree paused), the main menu
  and with the headset unfocused: unchanged (round 3: 1.50 -> 1.75 m in
  each; the verifier's `r4x_menu_recalibration` saw 1.894).
- `test_real_spreads_refine_the_span`: a capture with soft elbows (8 cm
  short): one full spread does not change it, a second separate one makes
  it the true span within 1 cm, persisted.
- `test_growth_is_bounded_per_session_and_recalibration_resets`: a capture
  22 cm short grows exactly +10 cm in a session, +10 more after a reload;
  a smaller player's manual recalibration resets it to 1.50 m, persisted,
  and the first player's spreads no longer count.
- `test_seated_is_bounded_by_the_standing_eyes`: a long-armed player (span
  1.90 m, stature 1.76 m) dipping 15 cm and looking down 40° for 6 s stays
  standing; sitting down is detected after 5 s and standing up again too.
- `calibration_test.test_standing_eyes_only_from_a_standing_capture`:
  the standing eyes are recorded (and persisted) from a standing capture
  only, never from a seated one or one with the seated preference on.
- `calibration_test.test_spread_gates`: each gate alone blocks the sample
  with its reason (owner gate, head tilted, shoulder height, out to the
  side, 0.75 / 1.4 arm lengths, uneven, hands moving, tracking); a genuine
  spread samples the calibrated span within 5 mm.
- `calibration_load_test.test_corrupt_saved_geometry_is_rejected` (fix
  round 4, engineering verifier): a NaN / singular / mirrored neutral, a
  NaN / INF / zero axis, a short array: rejected (uncalibrated, nothing
  capturing by itself, defaults, the valid span kept); through the service
  nothing reaches flight's resource and the first-launch step is due; a
  spread alone captures nothing, the step recalibrates it, reaches flight
  and a 20° roll reads 20°. (Fix round 4's version, with the automatic
  capture, failed on the round-3 code.)
- `calibration_test.test_untracked_controllers_are_not_measured_in_xr`
  (mutant R15): with VR active, controllers without tracking data are not
  measured or captured.

`calibration_test` (41 tests since fix round 5; synthetic players via `VRHumanPose`):
- **The brief's criterion**: 16 players (grip spans 1.4/1.6/1.8/2.0 m x
  wrist habits -25/0/+25/±25°) read the same as the reference for 9
  gestures after the (requested) capture, within **extension 0.03, twist 1°,
  pitch command 0.02**. Spec reference values hold: +20° -> pitch 0.305,
  -20° -> -0.49, aileron leaks no pitch, a 40° arm raise reads 0° twist.
  The captured span is the full spread within 0.2 %.
- **Real bodies, bounded at every corner of the population box (fix
  round 3).** `test_real_bodies_worst_case_is_bounded_at_the_corners`: the
  population is a box of adult ranges (span 1.4-2.0 m, shoulders
  0.20-0.26 of the span, ape index 0.95-1.05, drop 0.14-0.16 of stature,
  eyes 0.925-0.945 of stature, floor ±3 cm, wrist habits ±25° on each
  hand) and of capture styles that combine (arms 12° low .. 8° high, hands
  up to 10° forward, elbows up to 15° soft, a glance at a hand). Round 2
  applied each style alone and argued the corners bound the rest; a
  verifier combined them and read worse (extension 0.192, twist 4.9°), so
  the enumeration is now the full factorial: **64 body corners x 16
  capture-style corners x 4 wrist-habit corners = 4096 players**, and
  **three seeds of 120 random players with continuously random combined
  styles** (2026, 7, 42) must never read worse than the corners (+0.005;
  +0.05° for twist). The tracker noise of this test is seeded by itself.

  | worst over | extension | spread-wing twist | spread-wing pitch | folded pitch | shoulder height |
  |---|---|---|---|---|---|
  | the 4096 corner players (fix round 3) | **0.192** | 4.94° | 0.088 | 0.152 | 3.3 cm |
  | 3 x 120 random players, combined styles | 0.121 | 3.92° | 0.076 | 0.117 | 2.5 cm |
  | asserted (corners, rounded up) | 0.20 | 5.2° | 0.095 | 0.16 | 3.5 cm |
  | round 2 (1024 players, styles alone; understated) | 0.159 | 3.56° | 0.080 | 0.135 | 3.3 cm |

  The worst corner is a 1.4 m, broad-shouldered player with a long neck
  and low eyes, 3 cm of floor error, arms 8° high, hands 10° forward,
  elbows 15° soft and looking at a hand, reading a half fold 0.19 more
  open than the reference. What is left is what a still pose cannot
  observe (§8): shoulder width and the drop ratio for the half fold, soft
  elbows for twist and pitch. The verifier's own combined-style probe now
  reads the same numbers (0.192 / 4.94° / 0.088 / 0.151) inside these
  bounds.
- `test_breakdown_one_factor_at_a_time`: arm height and gaze at capture
  leave pitch unchanged (< 0.005, measured <= 0.001) and the shoulder
  height within 2 mm; every capture style moves extension < 0.02 (measured
  <= 0.016; was up to 0.43, and 0.04 in round 1) and pitch < 0.08. Body
  factors alone: shoulders 0.20/0.26 cost 0.062/0.080 of half-fold
  extension, the drop ratio 0.14/0.16 H 0.024/0.032 (and 0.058 of pitch).
- `test_capture_style_does_not_move_the_shoulders`: drop within 5 mm for
  arms 12° low .. 8° high; seated drop from the span.
- `test_seated_grid_reads_the_same` (fix round 3): the brief's grid seated
  (spans 1.4-2.0, habits ±25°), with the Settings preference (spread at
  once, or after 6 s seated) and by detection alone: every player is
  detected seated and reads like the seated reference within the grid's
  tolerances (a verifier's seated grid read 0.035: spans >= 1.8 m were
  never detected; now 0.0002). `test_seated_detection_has_hysteresis`:
  the band between the seated and standing thresholds never flips either
  way, at spans 1.5 and 2.0 (mutant E04).
- Fix round 3 (the verifiers' surviving mutants and new paths):
  `test_flight_recapture_after_vr_is_adopted` (flight recaptures with the
  arms 8° high after VR calibrated: adopted, refined to the body's drop
  within 1.5 cm, written back, persisted; a resource reloaded from the
  saved dict is not "foreign"), `test_refinements_reach_flight_and_persist`
  (sitting, standing up again and a grown span reach flight's resource at
  once and are persisted; E01), `test_new_neutral_clears_flights_trim`
  (flight's `calibration_replaced()` called for VR's capture and a manual
  recapture, not for a refinement; since fix round 4 a WingInput without
  the hook is left alone), `test_new_resource_on_the_same_player_is_found` (E03, with
  the old resource kept alive), `test_span_grows_only_past_the_margin` (3 cm no in three spreads,
  7 cm yes in two; E05),
  `test_crossed_arms_do_not_flip_the_body` (worst 0° of body yaw with the
  hands crossed; E06), `test_ill_conditioned_twist_is_held` (E15).
- **Who captures, and what flight flies (fix round 2):**
  - `test_vr_owns_the_automatic_capture` (the name predates the
    redesign): the PlayerBird's own capture is
    switched off while VR's runs, handed back to the previous PlayerBird
    when a new one appears, and restored when VR leaves; a new PlayerBird
    with an uncalibrated resource gets VR's calibration on the next tick.
  - `test_adopted_capture_is_refined_to_vrs_maths`: this suite's own mock
    of flight's §5.10 capture (arms-5°-low drop, neutral as held), for
    captures 12° low .. 8° high with a 15/-10° wrist habit. Adopted, it is
    written back to flight and persisted, and every gesture read through
    what flight now flies matches VR's own capture of the same hold
    within 0.02 extension, 0.5° twist and 0.01 pitch. Across capture
    heights the half fold's extension range is < 0.04 and its pitch range
    < 0.02; read as is, flight's capture spreads it over > 0.2 (the
    contrast is asserted).
  - `test_adoption_keeps_the_seated_preference_out_of_the_saved_dict` (a
    verifier's probe, as a test) and `test_seated_setting_applies_live`.
  - **On flight's real rig** (`tests/sim/flight_rig`,
    `test_vr_owns_the_capture_on_flights_rig`): `player.tscn` with the
    extras attached, in the game's frame order, a 1.75 m player holding
    the pose 12° low .. 8° high with 0 / 0.3 / 1.5 mm of tremor (12
    runs). Flight's automatic capture is off from the moment the extras
    attach; a spread held 3 s without the calibration step captures
    nothing (flight's defaults apply; redesign); with the step VR makes
    the one capture every time, flight flies VR's span,
    drop and neutral, the drop is within 1 cm of the body's, and flight's
    own WingState reads the half fold at **extension 0.124-0.128 and pitch
    0.328-0.329 for every capture height and tremor** (ranges 0.004 and
    0.001; round 1: 0.09-0.61 and 0-0.19).
    `test_a_capture_flight_made_first_is_refined`: flight captures before
    the extras attach (drop 0.150-0.350 for a true 0.286); VR adopts it,
    refines it to 0.286-0.287, writes it back and persists it, and the
    half fold then reads 0.125-0.128 / 0.328-0.329 (flight's own capture
    read it 0.095-0.614 / 0.194-0.457).
    Fix round 3, on the same real rig: `test_flight_recapture_after_vr_is_refined`
    (flight's `begin_calibration` after VR's capture, arms 8° high: flight
    flies drop 0.2865 = the body's 0.2865, VR and the saved dict agree;
    the verifier's probe had flight at 0.150),
    `test_recalibration_clears_flights_trim` (6° of stale trim, then VR's
    manual flow: flat wrists read 0.00°; the verifier measured 5.64°) and
    `test_detected_seating_reaches_flight` (seated and standing again
    reach flight's resource at once).
- **Only when asked** (redesign):
  - `test_the_calibrator_captures_only_when_asked`: still spreads, a
    20°-LE-down glide or flat, are never taken unasked and flat wrists read
    flat; asked, the glide held would be taken (+0.31 pitch on flat wrists
    afterwards: the contrast), one request makes one capture.
  - `test_the_service_captures_only_in_its_step`: in every flight mode
    (flying, perched, spawning, grounded, stunned, caught), paused or not,
    a pitched glide and a still spread held 2 s each capture nothing,
    persist nothing and leave flight's defaults; no card comes up by
    itself on the desktop; the step captures and writes flight's resource
    and the store.
  - `test_capture_waits_for_still_hands` (fix round 2; the verifier's
    surviving mutant M09): arms drifting at 0.12 m/s through an otherwise
    perfect spread (wrists turning < 13°/s, so only the hand-speed gate
    can stop it) are not a hold; a sway under 0.02 m/s is; a wrist rolling
    at 60°/s with still hands is not.
- **Glue**: `test_saved_calibration_reaches_the_player` (a pre-filled store
  loads calibrated, no step, and reaches the PlayerBird, also one spawned
  later).
- Capture accuracy, guards (flapping, arms low, uneven hands, tucked, hand
  lost), swapped controllers (never captured, the hint says so; the same
  request completes once swapped back) and odd grips (the live check asks
  for the usual grip; the capture's safety net refuses a torch grip's
  geometry), seated detection, span refinement, world_scale independence,
  persistence round trips (ConfigFile, flat arrays, `apply_to`/`read_from`
  through a local §5.11 mock: the suite never loads flight's class), the
  step (Y-hold, one step to the confirmation, UI root created later,
  timeout keeps the old calibration).
- `test_prompt_card_follows_lazily`: centred 1.25 m ahead, the exact
  instruction; a 20° glance leaves it; a 60° look re-centres it within
  3.5°; the ring fills while the pose is held; sized x world_scale, never
  node-scaled; a cancel shows the cross, then hidden when idle.
- Plot: `vr_plot_calibration.png`. Panel D: the half fold against the arm
  height at capture, for VR's capture (flat lines), flight's capture
  refined on adoption (dots on those lines) and flight's capture read as
  is (what the player flew in round 1: 0.09-0.56 extension, 0.01-0.56
  pitch).
- Screenshots of the card (desktop, Forward+): `calibration_prompt_card /
  _hint / _holding / _done / _cancelled.png`.

### V4 Vignette
**Fix round 5, speed** (`vignette_steady_test.test_speed_term_is_steady_and_scale_free`,
`vignette_test.test_strength_curve`): a sparrow and an eagle stand-in
flying straight at 0.6-2.6 x their cruise with a flap's ±5 % surge on it:
the curve (1.3 x -> 0, 1.8 x -> 0.21, 2.3 x -> 0.42 at setting 0.6)
within 0.01 for both species, std < 0.005 and no periodic component above
0.005 (the flap ripple, cut by the two low-passes), cruise and slower 0,
setting 0 nothing in a 2.6 x dive. A 1.8 x cruise glide past every
broken surface reads its open-sky value within 0.005. On the real world
(`tests/sim/real_world`, a sparrow player now in the scene): steady cruise
still 0.0000 on all 36 lines, a steady 1.8 x glide one constant value
(worst std 0.0006, periodic 0.0004, the open-sky value within 0.01).
`vignette_test.test_wingbeat_does_not_breathe` now asserts that in open
sky the acceleration term is exactly 0 and the view narrows by the speed
a surge reaches alone. On flight's real rig (flight_rig) every open-sky
case reads as in round 4 (cruise flight stays under 1.3 x cruise).

**Fix round 4, steady flight never pulses** (`vignette_steady_test`, over
the suite's own geometry at a sparrow's world_scale 0.141, 72 Hz, setting
0.6: a continuous canopy, orchard crowns 4/4, 3/5, 6/3, 2/2 m (crown /
gap) 1 m below, sparse crowns every 12 m, a forest of 0.3 m trunks 0.7-1.6 m
either side every 2-7 m, a fence of 0.15 m posts every 2.5 m 1 m abeam):
- steady straight flight at 9 and 8.3 m/s: **strength exactly 0** over
  every surface (round 3: 0.19-0.42 peaks, `old_code_check_round4.log`);
- a sustained +2 m/s² surge (14 perceived m/s²) over the same surfaces:
  **std <= 0.005 (bar 0.02), no periodic component above 0.0023 (bar
  0.005) between 0.3 and 6 Hz**, and the same as over the continuous
  canopy within 0.002 (bar 0.02: a row of trees is one surface); the
  proximity never moves faster than 1/`PROX_TAU` per second (0.07-0.09
  measured); round 3: std 0.03-0.08, 1.2-4.7 Hz components of 0.02-0.09;
- a 150°/s turn over each of them still closes the view (> 0.55 at
  setting 0.6);
- `test_proximity_is_slow_and_teleports_are_not_motion`: one post passing
  builds at most what `PROX_HOLD` of it can (1 - e^-1.5), never faster
  than 1/`PROX_TAU`, with the full view throughout (round 3: proximity
  0 -> 1 in a tick).

**On the real world geometry** (`tests/sim/real_world`, on demand;
`report_real_world.json`): straight lines through the orchard, the forest
and along the power line (landmarks from `World.get_landmarks()`), six
headings each, 1 m over the tallest thing under the path and 2.5 m over
the ground: **steady flight: worst std 0.0000, worst periodic component
0.0000 over 36 lines** (the lead's bars: std < 0.02, no periodic
component); a hard turn over each place closes the view. With a sustained
2 m/s² surge the strength follows the real distance to the canopy through
the slow proximity: at most 2 reversals of >= 0.01 in ~5 s (bar: one per
2 s) and never faster than 0.15 per second (bar 0.3 = setting x 0.5 /
`PROX_TAU`). The verifier's `r4x_vignette_flicker` and
`r4x_vignette_real_world` probes pass.

`vignette_test` (9 tests):
- The curve is pinned numerically: 35°/s -> 0, 92.5°/s -> 0.5, 150°/s -> 1;
  20 m/s² perceived -> 0.5 at any world scale, 13 -> 0.25, 6 -> 0;
  proximity 1 / 0.5 / 0 scales the acceleration term (open sky: 50 m/s²
  alone gives 0, a hard turn still closes the view); max-combination, not
  a sum; the setting scales it; setting 0 is 0 for every input; monotonic.
- Attack reaches 63 % at 0.08 s and release falls to 37 % at 0.5 s.
- **Setting 0 = strength 0 and hidden in a 200°/s turn.**
- The rig yaw rate is measured within 1°/s.
- A sparrow's gentle 30 m circle keeps the full view. A hard flare (3 m/s²
  along the path at world scale 0.141, 21 perceived) is measured in full;
  in open sky it keeps the full view (acceleration term 0); 0.5 m above a
  floor (3.5 perceived m) steady flight keeps the full view, the
  proximity rises slowly (1 - e^-2 after 2 s, measured within 0.03), and
  the flare's acceleration term counts in full. `test_accel_proximity`: 1
  within 3 body spans, 0 at 8 and beyond or with nothing in reach, 0.5 at
  5.5, monotonic, at world scale 0.141, 0.388 and 1.235.
- The aperture is angular, and the ring sits beyond the near plane at
  world scale 0.15 and 1.3.
- `test_yaw_steps_are_not_turns` (fix round 1): one-tick yaw steps of
  15-180° while gliding give **no vignette at all** (peak 0.000). A flagged
  tick and the tick after `VR.recentered` are re-seeded, while a real
  240°/s turn is still measured and closes the view.
- `test_wingbeat_does_not_breathe` (fix round 2, judged as if a surface
  were within 3 spans, where the term counts): a sparrow-scale rig (ws
  0.141) flapping straight with flight's measured amplitudes (surge 0.45
  m/s, heave 0.55 m/s, second harmonics) at 1.0, 1.25 and 1.6 Hz, with a
  PlayerBird stand-in reporting its stroke period: **peak < 0.005 and
  never above 0.05**; in the open sky it flies in, exactly 0. With no
  stroke period the fixed 0.8 s window keeps the peak <= 0.10. A sustained
  surge while flapping (+2.5 m/s² for 3 s = 18 perceived) is measured at
  its mean (17.7) and narrows the view near a surface (0.28), not in open
  sky. **The second 0.5 s box** (fix round 3; mutant E37): with flight's
  stroke period reported 30 % short, a 1.25 Hz beat's residue is cut 2.6x
  (18.0 -> 6.9 perceived) and stays under a visible edge.
- `test_setting_is_read_from_settings` (fix round 2): the player's
  `comfort_vignette` through the settings source production uses: 0 =
  strength 0 and hidden in a 200°/s turn, 0.35 -> 0.35, 1 -> fully closed.

**On flight's real PlayerBird** (`tests/sim/flight_rig`,
`test_vignette_in_open_sky_flight`, default setting 0.6, heave smoothing
on), asserted over the whole run, onset included:
- steady cases (sparrow glide / cruise / climb / hover / 1.6 Hz fast flaps;
  starling, pigeon, eagle cruise and climb) in open sky: peak 0.000-0.010;
- the verifier's flap/glide rhythms for the sparrow, starling and pigeon:
  narrowed > 0.10 for 0 % of the time, peak 0.000;
- a sparrow gliding straight along a cliff face 0.6 m to its right keeps
  the full view (peak 0.000; round 3's flow term: 0.42), and folding into
  a dive there narrows it by the acceleration (peak 0.294, term 0.98).

Screenshots: `vignette_rest.png` vs `vignette_turn.png` (150°/s, strength
1.0) vs `vignette_turn_off.png` (setting 0). In the simulator mirror,
`sim_vignette_rest_fplus.png` vs `sim_vignette_turn_fplus.png`. Plot:
`vr_plot_vignette.png`: the turn curve, the speed curve (panel B, fix
round 5), the acceleration curve by proximity, a hard turn's response, a
flapping sparrow then a surge, and (panel F, fix round 4) steady flight
over orchard crowns: round 3's
formula (emulated from its rays) pulsing 0.2-0.42 about once a second vs
now 0, then a steady 0.16 in a surge, with the slow proximity.

### V5 First-person wings
Fix round 5 (`wings_test`, now 20 tests):
`test_wings_follow_the_controllers_in_the_same_frame` (mutant E38: the
wings laid out before the calibrator sampled): with the extras processing
as in the game, a 30° wrist roll made at the start of a frame is on the
feathers when the frame ends (30.0°) and nothing is left for the next
(< 0.05°); `test_a_held_extension_rebuilds_no_fan` (the layout cache);
`test_folded_coverts_become_feathers` also pins the shader's per-wing fold
(`fold_lr`); `test_arm_feathers_lie_along_the_arm` (the arm feathers'
roots at their fraction along shoulder -> grip, offset only across the
arm, at world_scale 1 and 0.15; mutant F05 passed every other test). The stub rig now carries aim-pose controllers ahead of the
grip ones (flight's `LeftAim`/`RightAim`, UI's pointers): mutant E41
(the extras taking aim poses) fails 13 tests.

`wings_test` (17 tests in round 4):
- Hand feathers ride the grip pose over 8 gestures x 3 phases (root error
  < 1 mm). The wing plane is the controller's wherever the wing is spread
  (< 1°), and turns towards level only by the fold rule (`FOLD_LEVEL` x
  (1 - e)², < 1° from it).
- `test_folded_wing_lies_upper_side_up` (fix round 2): relaxed hands
  holding the controllers palms-in (their plane within 30° of vertical),
  wings folded: every primary faces up (cos to vertical > 0.75).
- **`test_folded_wing_turns_continuously` (fix round 3, both verifiers'
  major finding):** the relaxed hands' wrist roll through a full turn,
  the hanging arm's elbow 0-140°, the arm lowering to vertical, the hand
  coming to the shoulder (elbow 100-178°) and a raised arm's wrist roll,
  at extensions 0 and 0.3, in 0.5° steps: **no feather's plane or
  direction turns more than 4° per degree of input** (worst 3.67°/°; round
  2: 52-82° for a 1° step). ±0.3° of tracker noise held for 90 frames at
  the round-2 gates and at the sweep's own worst point: **no feather turns
  more than 3° between frames** (worst 1.95°; round 2 flipped > 30° on
  36-43 of 90 frames). `test_palm_up_fold_keeps_the_hands_plane`: where
  the controller's wing normal is most nearly opposite to level (179.5°),
  the folded wing stays in the hand's plane (0.02°; mutant E31).
- The pose rule the layout is checked against (`folded_frame`) is written
  out independently in the test with slerps: as the wing folds the hand
  frame swings towards the arm's line (`FOLD_ALIGN` x (1 - e)²) and then
  turns towards level; spread, it is the controller's exactly.
- A 30° wrist roll tilts the hand feathers 30° (leading edge up leans the
  normal back).
- **The wingtip is exactly 10 cm x world_scale past the grip, and the drawn
  span = (grip span + 0.20) x ws, at ws 0.15/0.3/0.6/1.0/1.3.** Feather
  size scales with ws while the node stays unscaled.
- The fan opens monotonically from 20° (folded, staggered) to 72° with
  extension and folds back along the forearm; flight's extension is used
  when present.
- **What the shader gets (fix round 2; the tint test was tautological, the
  verifier's mutants M67 and M68 survived it):**
  `test_palette_reaches_the_shader` reads the palette texture back from the
  material: row `SizeRules.species_index(sp)` holds that species' wing
  palette (worst 0.000) and its accent placement; the species uniform
  points at the player's row (crow, sparrow); every feather instance's
  group is in its uploaded custom data; and each group samples the
  palette column its name says (primaries the primaries, secondaries the
  flight feathers, coverts the coverts, both surfaces).
  `test_species_tint`: the tint follows the player with a 0.8 s
  cross-fade, every colour equals `BirdModels.wing_palette` (the birds
  contract), and neighbouring tiers differ by >= 0.1. Fix round 4
  (engineering verifier): the two checks that read the birds area's
  internal data (the fallback copy `PALETTE` equal to today's NPC colours,
  and `ACCENT_AT` against `BirdSpecies.data()`) moved to the on-demand
  drift report `tests/sim/birds_palette` (both pass today), so a colour
  retune by birds can no longer break VR's unit suite.
- `test_folded_coverts_become_feathers` (fix round 4): folded, the covert
  plates are 1.45x longer and 0.55x as wide (every feather's size checked
  at extensions 1 / 0.75 / 0.5 / 0.25 / 0); length/width rises
  monotonically from 0.57 (spread) to >= 1.5; flight feathers unchanged.
- `test_extension_is_smoothed_against_jitter` (fix round 4, mutant R21):
  ±0.05 frame-to-frame jitter in flight's extension moves the drawn wing
  by < 0.02 per frame, while a real fold shows within 0.2 s.
- An untracked wing collapses (through the calibrator's per-hand validity,
  the path the rig uses), and a still pose costs nothing.
- The re-layout key is complete. All 60 feathers are right-handed, with the
  upper surface up on a level spread.
- **One MultiMesh / one surface / one material / 960 triangles / no
  shadow**, and the UI occluder stencil is written.

Renderer measurement: wings +1 draw call, vignette +1 (`drawcalls.json`).
Simulator mirror (V5 "visible in simulator mirror screenshots"): the harness
compares each mirror shot with the same shot with the wings hidden. **Fix
round 2: two shots look along a spread wing** (the verifier found no mirror
shot with a recognisable wing): the fitted body turns 60-66° under the
simulator's fixed head, as a player looking over the right shoulder does
(`sim_wings_hybrid_look_spread_fplus.png`, arms 12° up;
`sim_wings_hybrid_look_flap_fplus.png`, top of the upstroke). Both show the
sparrow's wing whole: covert rows with their outlines, the white wing bar,
the dark primary fan (11.9 % and 17.3 % of pixels). With the real (fixed)
simulated controllers the folded wings now lie upper side up in the
species' colours (4.2 %; they were pale grey slabs), and scripted arms on
the real head give 2.8-5.3 % at world_scale 0.15 and 1.3
(`sim_wings_*_fplus.png`). Desktop views: `wings_fp_*.png` (first person
per gesture, including `wings_fp_held*.png`: relaxed hands, folded, and
`wings_fp_sim_controllers.png` / `wings_outside_sim_controllers.png`: the
simulator's fixed controllers reproduced on the desktop, fix round 3),
`wings_ws_015.png` / `wings_ws_130.png`, `wings_outside_*.png`, and
`wings_species.png` (all ten species).

### V6 Haptics
`haptics_test` (24 tests) with a recording sink:
- The ten patterns are pairwise distinct (count, >= 8 ms duration, >= 20 ms
  gap or >= 0.15 amplitude differences).
- Each event maps to its pattern on the right hands.
- Flap spam at 90 Hz gives <= 17 thumps per hand in 2 s at >= 120 ms
  spacing.
- An all-patterns storm never exceeds **30 % duty in any 1 s window** and
  never starts two pulses **< 40 ms** apart unless the second outranks the
  first. Both are asserted against the brief's numbers, not the code's
  constants: the verifier's MAX_DUTY 0.90 and MIN_GAP 0 mutants now fail.
- Priorities hold; **haptics 0 = not a single call**; 0.5 halves amplitude.
- The stall buffet is jittered, and the updraft throbs per wing.
- Silent while paused; telemetry-driven; the XR sink is a no-op without a
  runtime.
- `test_danger_heartbeat_holds_while_the_threat_is_steady` (fix round 1):
  one `threat_changed(0.8)` gives 13-17 pulses per hand in 3-8 s (measured
  15). `threat_changed(0)` then gives none, the heartbeat resumes after a
  pause without a new report, and leaving play or the hunter dying ends it.
- Fix round 3 (a verifier's saturation probe and the surviving mutants
  E10, E12, E13, E44):
  - `test_important_events_get_through_a_saturated_budget`: catch,
    collision and caught during stall / stall+updraft /
    stall+updraft+danger / updraft+danger, 12 phases x 2 hands each:
    **felt whole every time (24/24)**, caught >= 150 ms (measured 180-195);
    round 2 delivered the catch whole 6 times in 24.
  - `test_flaps_are_felt_while_stalled`: 20 of 20 flaps felt at 1.6 Hz
    (round 2: 15), none later than 60 ms, the buffet going on between them.
  - `test_continuous_rhythms_share_the_budget`: stall + updraft + danger
    at full, with and without 1.5 Hz flapping: the heartbeat keeps >= 90 %
    of its beats (a round-2 verifier's probe wants it kept), the buffet
    and the throb still play, slowed together (x3.8), and duty <= 30 %.
  - `test_busy_hands_still_feel_catches_and_flaps`: stall + thermal +
    hunter with frantic flapping (every 122 ms: routine pulses stop at
    their 21 %) — every catch felt whole — and with 1.6 Hz flapping over
    three buffet-jitter seeds, every flap felt.
  - `test_duty_cap_shortens_important_pulses` (E13): a caught pulse on a
    busy hand is shortened to the room left (>= 90 ms), not dropped.
  - `test_updraft_wings_throb_in_turn` (E12): both wings in a thermal throb
    half a period apart; `test_telemetry_drives_continuous_patterns` now
    runs in PLAYING (E44) and checks no throb while perched in rising air
    (E10).
- Fix round 4 (the verifier's surviving mutants R01, R17, R18):
  `test_stall_warning_threshold` (telemetry `stall_warning` 0.3 and 0.55:
  no buffet; 0.8: > 2 pulses/s), `test_xr_sink_sends_each_hand_to_its_controller`
  (the real sink with a recorder as its interface: a left flap reaches
  `left_hand`'s `haptic` action with the flap's 35 ms, frequency 0; a right
  one `right_hand`) and `test_being_caught_stops_the_rhythms` (a buffet and
  a heartbeat running, then `player_caught` with the game state untouched:
  only the caught pulse follows).
- Fix round 2 (the verifier's surviving mutants M29, M28, M62, M15):
  `test_setting_is_read_from_settings` (the player's `haptics` through the
  settings source production uses: 0 = not one pulse in a storm, 0.5
  halves the amplitude), `test_run_end_and_respawn_end_continuous_patterns`
  (`run_ended` ends the heartbeat; `player_spawned` ends stall, updraft
  and danger) and `test_catch_has_a_minimum_interval` (two catches 150 ms
  apart give one double bite; 650 ms later a second).

Plot: `vr_plot_haptics.png`. Real call path in the simulator: every pattern
through `XRInterface.trigger_haptic_pulse` (28 pulses, >= 2 per pattern),
zero errors (the simulator has no haptic output to observe).

### V7 world_scale smooth, near plane, never node-scaled
`world_scale_test`:
- target = span / (arm span + 0.2) (exponent option).
- Sparrow -> eagle ramps monotonically at **<= 0.25 ln/s** and takes
  **>= 8.6 s** (arrives at ln(8.75)/0.25 = 8.68 s). These are asserted as
  the brief's numbers: the verifier's MAX_RATE 3.0 mutant now fails.
  Shrinking ramps likewise.
- `origin.world_scale` stays in sync, and **camera near = NEAR_K x ws (0.06 since integration round 1; 0.03 when this was written)
  (>= 1 mm) on every step**; the scale is held while paused and the
  calibrated span feeds it.
- `test_new_run_and_respawn_snap` and `test_first_size_is_not_ramped_from_one`
  (fix round 1): a new run after an eagle run is sparrow-sized in one tick,
  and so is a respawn. Growth in play still ramps; with no player the
  scale is untouched; the first player size is applied in one tick.
- **For 150 physics frames of a growth ramp with all VR extras running,
  the camera, both controllers, the XROrigin3D and every ancestor keep unit
  scale, and the origin's local basis stays identity.**
- `test_corrupt_settings_never_reach_the_rig` (fix round 3): a NaN, INF or
  -INF `world_scale_exponent` reads as 1.0, and world_scale and the near
  plane stay finite through snaps and a ramp; `target_scale` with a
  non-finite mass, span or exponent stays within 0.05-5; a NaN/INF value
  in the saved calibration dict keeps the default.
- `test_a_foreign_write_is_corrected` (fix round 4, mutant R02): a
  foreign write to the origin's world_scale or the camera's near plane is
  undone within a tick (the near plane alone too).
- Fix round 2 (the verifier's surviving mutants M36, M14, M51):
  `test_mass_set_after_the_signal_still_snaps` (GameLoop may set the new
  mass after `run_started` / `player_spawned`: the next tick still snaps),
  `test_scale_is_applied_before_the_player_tick` (a default-priority node
  placed before the driver in the tree sees each frame's new scale in that
  frame: the physics priority orders them), `test_exponent_is_read_from_settings`
  (0.8, clamped to 0.5, 1.0).

Plot: `vr_plot_world_scale.png` (fix round 3: it showed a "caught"
shrink as a 4.6 s ramp; now growth in play ramps at 1 s and 15 s, and the
respawn after being caught at 12 s snaps, as the game does on
`Events.player_spawned`).

### V8 Pause keeps head and hands
Fix round 6: `pause_test.test_pausable_node_under_the_rig_is_fixed` now
adds a PAUSABLE and a WHEN_PAUSED node under the rig and checks both are
set to ALWAYS and process in play and while paused;
`test_origin_forced_to_always_at_attach` has a WHEN_PAUSED node already
under the rig at attach (the engineering verifier's mutant P1, correcting
PAUSABLE only, passed the round-5 suite; `mutations_round6.log` P01).
`rig_lifecycle_test` (§2.8): a replaced rig with the extras elsewhere gets
wings, vignette and growth within 3 frames.

`pause_test.test_rig_leaving_and_reentering_keeps_its_parts` (fix round
5, §2.8): the rig removed and re-added, then reparented: the wings and
the vignette survive, shown and processing, the automatic capture is VR's
again, and a pausable node added under the rig afterwards is still
corrected; the extras removed alone park the parts, added back restore
them, deleted take them along. The engineering verifier's probe passes
(it failed on round 4: `verify/r1eng_probe.log`).

`pause_test`:
- With `Game.PAUSED` (tree paused) the XROrigin3D and every node under it
  can process (camera, hands, wings, vignette, extras), while the pausable
  body can't (sanity).
- The wings follow a moving controller while paused.
- A pausable node added under the rig is corrected to ALWAYS.
- `test_origin_forced_to_always_at_attach` (fix round 1; mutant M17): a rig
  built with its origin INHERIT under a pausable body, and (fix round 4,
  mutant R09) a PAUSABLE node added under its camera before the deferred
  attach, are both corrected by the attach alone, with no manual call,
  and then process while paused.
- `test_extras_place_their_parts_and_clean_up` (fix round 3; mutants E07,
  E08): the vignette hangs under the XRCamera3D at identity (the brief's
  "camera-attached"), the wings under the origin at identity, the
  calibration reads the rig's grip controllers, the near plane follows the
  rig's camera; when the extras leave, the wings and the vignette go with
  them and the player's own automatic capture is handed back.

### V9 Desktop fallback (`--xr-mode off`)
- `vr_manager_test.test_desktop_fallback_is_clean`: no interface, main
  viewport not XR, physics tick untouched; refresh, foveation, haptics and
  controls are safe no-ops; VR, haptics and controls process while paused.
- The dev scene rendered 8 s on the desktop with only the documented exit
  noise (`artifacts/vr/desktop_fallback.log`, regenerated in fix round 4).
- All 161 unit tests run with `--xr-mode off`.

### V10 Controller mapping
`controls_test`:
- Left menu button -> one `Events.menu_requested` per press (holding
  doesn't repeat).
- B held 0.8 s pauses while PLAYING or CAUGHT, never in PAUSED, MENU,
  ENDED or BOOT (fix round 2: BOOT used to be included; M65), and a short
  B is Back.
- A/X held 1 s -> `Events.recenter_requested` -> `VR.recentered` once; Y
  held 1.5 s -> recalibrate.
- Grip and trigger analog values with 0.6/0.4 hysteresis (two transitions,
  no chatter).
- The real read path through a registered `XRControllerTracker`; fix
  round 5: a controller that goes away with Y and the grip held reads
  released and stays so (no recalibration from a vanished Y), and reads
  its held Y again when it comes back (a hand without a tracker is
  skipped once it reads released: controls 8.4 -> 1.1 µs headless).
- Fix round 6 (engineering verifier): the default reader was a sentinel
  Callable whose body never ran; an empty `reader` now means "read the
  trackers", so the tracker path is the one code path the tests above
  exercise (mutant C02, ignoring an injected reader, is caught).

### Simulator input path (the harness's driven controllers)
`tests/sim/sim_driver.py` talks SimRpc (gRPC over HTTP/2 with curl; the port
comes from the simulator log of the harness's pid).
- It **never calls SetInputPluginSettings, SetInputSource, SetBindings or
  SetActionInput** (they persist into `persistent_data.json`). It selects
  devices with the simulator's own CYCLE_INPUT key (`]`), which is
  in-memory session state, and checks the file's SHA-256 before and after
  (**unchanged** in every run).
- Observed device cycle: all -> head -> left -> right -> all. There is no
  "both controllers, head still" state without SetInputPluginSettings, so
  the two-hand flap is interleaved one-hand strokes (0.45 s at the
  simulator's 1 m/s).
- Results in every run: **both hands 2 downstrokes each, 1.07 m/s relative
  to a head that moved 0.0 mm**; a left wrist roll of 24.3° about the
  forearm, read by the calibration maths as 24.4°; the right hand 0°.
- Fix round 4: the driver then selects the head alone and holds
  ROTATE_H_POS (LeftArrow, `KeyboardKey` 1) for 0.5 s: the head turns 40°,
  and the harness's recenter check brings it back to 0.0°.
- osascript keystrokes would need Accessibility permission and window
  focus; SendKey is the same thing without either. Session-capture replay
  needs `persistent_data.json` edits, so it is not used.

---

## 4. Comfort R1: world_scale exponent (recommendation: keep 1.0)

FLIGHT_SPEC §17 R1 asks whether small birds need `world_scale_exponent`
~0.8. Numbers (`vr_plot_comfort_r1.png`; cruise from
`SizeRules.performance`, arm span 1.5 m):

| species | ws (1.0) | ws (0.8) | perceived cruise 1.0 / 0.8 (m/s) | own wings vs a same-size NPC at 0.8 | angular flow at 3 spans (rad/s, any exponent) |
|---|---|---|---|---|---|
| wren | 0.094 | 0.151 | 82 / 51 | 1.60x | 16.1 |
| sparrow | 0.141 | 0.209 | 64 / 43 | 1.48x | 12.5 |
| swallow | 0.194 | 0.269 | 51 / 37 | 1.39x | 10.1 |
| starling | 0.235 | 0.314 | 47 / 35 | 1.34x | 9.2 |
| pigeon | 0.388 | 0.469 | 34 / 28 | 1.21x | 6.7 |
| crow | 0.559 | 0.628 | 26 / 23 | 1.12x | 5.0 |
| gull | 0.765 | 0.807 | 21 / 20 | 1.06x | 4.0 |
| hawk | 0.941 | 0.953 | 18 / 18 | 1.01x | 3.5 |
| eagle | 1.235 | 1.184 | 16 / 16 | 0.96x | 3.1 |

- **The drivers of vection sickness don't depend on world_scale.** Angular
  optic flow (speed / distance, rad/s), yaw rate and the flow per eye
  height are geometric: a sparrow skimming a hedge sees the same 12.5 rad/s
  whatever the exponent. Only the *perceived linear* speed, acceleration
  and bob (divided by ws) change, through stereo and eye-height scaling.
- **0.8 buys a 33 % lower perceived speed for a sparrow at the price of the
  core size cue**: the player's own wings are drawn at the hands, so with
  ws 1.48x larger than exact they look 1.48x their true span next to NPCs.
  A sparrow player would see its wings (0.36 m apparent) wider than a real
  swallow's (0.33 m): the eat-or-flee judgement is off by a tier at exactly
  the tiers where it matters most. It also weakens the vignette's
  perceived-acceleration term for small birds.
- **Recommendation: keep 1.0** (default; the setting stays available for the
  Quest Pro session). If testers report discomfort as a small bird, use the
  levers that act on what causes it and keep the size cue: (1) the
  vignette (raise `comfort_vignette`; it answers turns, speed over the
  bird's cruise and accelerations near surfaces; a term for steady
  cruise near surfaces, if testers need one, cannot be built on the
  distance to the canopy without the ring following the canopy: fix round
  5's prototype read std 0.19-0.20 along the real orchard and forest
  lines, §2.5), (2) flight's heave smoother, (3) lower small-bird cruise for
  everyone in `SizeRules.performance` (gameloop; this lowers the true
  angular flow), (4) only then an exponent < 1. (The right-hand panel of
  `vr_plot_comfort_r1.png` no longer draws the removed flow term's
  thresholds; its old label collided with the hawk bar.)


---

## 5. Performance

- **Fix round 5 (both verifiers: the timing gate passed on its best
  block while its medians were 110-128 µs, and the simulator measured the
  VR scripts at ~0.26-0.29 ms a frame, ~3x the area's own 100 µs
  budget).** The budget is VR's own (ARCHITECTURE sets none per area):
  0.1 ms a frame on this Mac, ~0.3-0.4 ms on the Quest Pro's cores
  (3-4x slower), ~2-3 % of a 13.9 ms frame. The gate now judges the
  **median** of its 5 blocks (a typical frame), and the work was cut to
  fit it with room:
  - the wing layout (§2.6): one native product per feather from a fan
    cache that now hits; 38-46 -> 19-21 µs headless while flapping (every
    feather re-laid every frame), 87.7 -> 9.4 µs in the simulator;
  - controls: a hand without a tracker is skipped once it reads released
    (8.4 -> 1.1 µs headless; in XR the trackers exist and nothing changes);
  - calibration: the XR nodes' origin-local pose read directly when they
    are the origin's children (no global-transform compositions).
  **Headless gate (`report_perf_round5.json`): median 70.8 µs (best
  67.7) at load 8.2** (calibration 25.6, wings 20.0, vignette 17.4,
  haptics 3.4, world scale 3.4, controls 1.1); in the day's contended runs
  the median was 79-91 µs at load 10-12 (round 4's: 110-128 at load
  13-14). The bench runs calibrated and unarmed; while a re-check is
  armed the tick also asks the capture gate (0.7 µs, profiled) and
  computes the hands' angular speeds, exactly as every tick did before
  the first capture in round 4.
- **In the simulator (fix round 5, profiling on, a live XR frame):** at
  load 7.0 calibration 45.2, vignette 35.5 + 6.9, world scale 15.7,
  controls 13.9, wings 9.4, haptics 7.3: **~134 µs per frame**; on the
  final code at load 11.2 (`sim_result_default.json`) ~146 µs (wings
  10.1). Round 4: ~257 µs at load 14.4; the re-verification measured
  ~294. `script_process_ms_per_frame` 0.15-0.16 (round 4: 0.32). By the
  3-4x rule that is **~0.4-0.6 ms on the Quest Pro**, ~3-4 % of a
  13.9 ms frame; integration should confirm on the device (OVR Metrics)
  and on `main.tscn` at a known machine load.
- **Fix round 6** (final code, load 8.3, `sim_result_default.json`):
  calibration 50.2, vignette 39.8 + 7.5, world scale 19.1, controls 14.8,
  wings 10.0, haptics 8.2: **~150 µs**, `script_process_ms_per_frame`
  0.16 (round 5: ~134 at load 7.0, ~146 at 11.2). At load 12.0 the same
  parts read ~172 µs and at 15.3 ~210, all rising together, the
  contention signature of §3 V1. The calibration's only extra work this
  round is one duck-typed flight-mode read per tick while a capture is
  pending (it replaced the gate's own) and a settle counter.
- History. Round 4: 94-96 µs headless (fastest block) at load 5.7-19.6;
  round 3: 89-97 µs; round 2 brought the flow rays to one per tick and
  split the wing loop. The unit suite pins the work (`perf_test`: every
  feather re-laid every frame, every probe hitting) and records the time;
  wall-clock time on this shared Mac is gated on demand only
  (`tests/sim/perf`: median of 5 blocks < 100 µs; a run whose median is
  more than 1.5x its best block was disturbed and is measured again, up
  to 3 runs).
  Profiling (`VRProfile`) is off in the game (one static read per feature);
  the harness and perf test turn it on.
- **Draw calls**: wings 1 (960 triangles), vignette 1 when visible (672
  triangles, a ring: no fragments in the clear centre), calibration card 2
  only while the flow runs. No shadows.
- **XRMirror** doesn't render a second full view every frame (it did, in
  `main.tscn` too): only around captures.

## 6. Evidence index (`artifacts/vr/`)

| File | Shows |
|---|---|
| `sim_result_default.json`, `sim_run_default.log`, `sim_driver_default.log` | **calibration redesign (final code): full simulator verdict PASS at the policy's default (72 Hz, no override) with the NPC budget as stand-ins**, all 14 checks (71.8 fps at load 5.0, p50 13.89 / p95 13.98 / p99 14.15 ms, 0.2 % hitches, the VR scripts 0.14 ms a frame, no unexpected warning after the colour-space setting). Fix round 6's run of the same harness: 14 checks (71.55 fps at load 8.3, frame times p50 13.89 / p95 14.40 / p99 17.44 ms, 0.4 % hitches, the refresh policy seen to run, focused throughout, VRS_XR, recenter 41.1° -> 0.0°, the VR scripts ~150 µs a frame), driver, persistent file unchanged; `sim_result_default_load15_fail.json` / `sim_run_default_load15_fail.log`: the same code at load 15.3, fps 62.92 (contention: GPU unchanged, every script slower) |
| `sim_result_fplus.json`, `sim_run_fplus.log`, `sim_*_fplus.png` | fix round 6 (final code, rerun): the clean Forward+ mirror shots, 7/7 (wings visible in every shot, 2.5-17.3 % of pixels; folded wings on the simulator's fixed controllers end in tapered feathers; the vignette in a hard turn, edge luminance 0.632 -> 0.015) |
| `dev_sim_7s.png`, `dev_sim_11s.png`, `dev_sim_15s.png`, `dev_sim_20s.png`, `dev_sim_run.log` | fix round 6: the dev scene's `--demo` in the simulator, Forward+, looking along the right wing: a sparrow's spread wing, the top of an upstroke, a gull's wing with the wrists rolled back (leading edge up), the gull in a fast hard turn with the comfort vignette (round 5's two shots were byte-identical) |
| `sim_calibration_result.json`, `sim_calibration_run.log`, `sim_calibration_driver.json` / `.log` (+ `_fplus`) | **calibration redesign: the step in the Meta XR Simulator, VERDICT PASS (6 checks) with Mobile and with Forward+**: the first-launch card by itself, the resting controllers not captured, the real controllers spread over SimRpc and captured 1.22 / 1.28 s after the stream last showed motion (span 1.54 m, drop 0.27 m), a B/Y cancel keeping the calibration, `SetUserPresent` off/on raising only the flag; the driver's actions and pose stream, persistent file unchanged |
| `sim_calibration_card/holding/done/cancelled(_fplus).png` | the card in the simulator's head view: first launch with the hint "Spread your arms wider" (the resting controllers and folded wings in view), the ring filling, "Wings calibrated / Arm span 1.54 m", "Calibration cancelled / Your wings are unchanged" (the Mobile ones carry MoltenVK's magenta tiles) |
| `pause_plain.png`, `pause_new_player.png`, `pause_card_vr.png`, `pause_suggestion.json` | the pause menu without and with "New player? Recalibrate wings" (the one change in `scripts/ui/`), and the card over the VR pause panel after a click; 13 layout / behaviour checks |
| `calibration_prompt_card/hint/holding/done/cancelled.png` | the calibration card on the desktop: the instruction with "B or Y: cancel", the hint "Hold your arms level" after a second of relaxed arms, the ring filling, the confirmation, a cancel |
| `report_unit_vr_round6.json`, `unit_vr_run.log` | fix round 6's final unit run: 161/161, zero script errors (the only warnings are the pause tests' intended corrections) |
| `probes_round6.log`, `probes_round6_r1x_prompt_followed.log` | fix round 6: every verifier probe on that code: 78 of 88 passed (§14). The calibration redesign removed the API the wearer probes call, so those no longer parse by design (§15) |
| `mutate_round6.py`, `mutations_round6.log` | fix round 6's mutation run (§14) |
| `sim_result_default_picking_warning.json`, `sim_run_default_picking_warning.log` | fix round 5's first simulator run: harness PASS (14/14, 71.95 fps at load 5.3) but the wrapper failed it on an engine warning (object picking in stereo), fixed in `VRManager` (§2.1) |
| `report_unit_vr_round5.json`, `report_flight_rig_round5.json`, `report_real_world_round5.json`, `report_perf_round5.json` | fix round 5's final runs: the unit suite (152/152), the flight-rig checks (7/7), the vignette over the real world (steady cruise 0.0000, a steady fast glide std <= 0.0006 over 36 lines), the on-demand perf gate (median 70.8 µs) |
| `probes_round5.log`, `probes_round5_flow_patched.log` | every verifier probe on the final code: 70 of 79 pass, the 9 others by design (§13); the two that read the removed `ComfortVignette.flow`, with only that read replaced: 3/3 pass |
| `mutate_round5.py`, `mutations_round5.log` | fix round 5's mutation run: the re-verification's surviving mutants (E28, E30, E38, E41, E53, two deleted connect lines) and mutants of this round's code |
| `flow_term_sweep_round5.log` | fix round 5: a prototype optic-flow term on the slow held distances over the real world's 36 lines (worst std 0.19-0.20 in steady cruise for every variant): why the speed term is speed over cruise (§2.5) |
| `report_unit_vr_round4.json`, `report_flight_rig_round4.json`, `report_real_world_round4.json`, `report_perf_round4.json`, `probes_round4.log` | fix round 4's final runs (unit 135/135, flight rig 7/7, real world, perf gate 95.3 µs best block; probes 64 of 71) |
| `old_code_check_round4.py`, `old_code_check_round4.log` | this round's defect tests run against the round-3 code: every one fails, with zero script errors (span 1.60 -> 2.15 m, vignette peaks 0.19-0.42 in steady flight, corrupt geometry loaded, `focused` true with the headset off) |
| `mutate_round4.py`, `mutations_round4.log` | this round's mutation run: the engineering verifier's surviving mutants in the current code's form and mutants of this round's code |
| `wings_look_at_hands_sheet.png`, `wings_look_*.png` | fix round 5: the natural look-at-your-hands poses (sparrow palms down / in / wrists up, crow palms in, an arm spread looked along as a sparrow and an eagle, and the re-verification's palettes: gull, pigeon, swallow, starling, wren, moth), folded wings ending in tapered, outlined feathers |
| `report_unit_vr_round3.json`, `report_flight_rig_round3.json`, `report_perf_round3.json` | fix round 3's final runs of the unit suite (114/114), the flight-rig checks (6/6) and the on-demand perf gate (92.8 µs), copied here because `artifacts/tests/` is overwritten by anyone who reruns the suites |
| `sim_result_default_load13_fail.json` | round 2's code in a contended run (load 13): fps 67.56, every script cost +45 %, GPU unchanged (§3 V1) |
| (the same, since fix round 2) | Forward+ mirror shots: real controllers (folded wings upper side up), scripted arms, ws 0.15/1.3, **looking along a spread wing** (`sim_wings_hybrid_look_spread/flap_fplus.png`), vignette rest vs turn |
| `sim_result_hz72.json`, `sim_run_hz72.log` | round 0: PASS with `--refresh=72` |
| `sim_result_hz90.json`, `sim_result_fps90_{bare,extras}_{1,2}.json` | round 0: the 90 Hz runs and the A/B with and without the VR features (§8) |
| `sim_*.png` (no suffix) | the same through the Mobile renderer (magenta tiles = MoltenVK artifact) |
| `desktop_fallback.log` | dev scene on the desktop without XR, 8 s: only the documented exit noise (regenerated in fix round 6) |
| `wings_fp_*.png` (incl. `wings_fp_held*.png`), `wings_ws_015.png`, `wings_ws_130.png`, `wings_outside_*.png`, `wings_species.png` | the wings (fix round 2: stronger outlines, folded wings upper side up): first person per gesture and with relaxed hands, world_scale 0.15 and 1.3, outside views of the shape, all ten species in their NPC palettes |
| `vignette_rest.png`, `vignette_turn.png`, `vignette_turn_off.png` | V4 screenshots |
| `drawcalls.json` | measured draw calls of wings (1) and vignette (1) |
| `vr_plot_vignette.png`, `vr_plot_world_scale.png`, `vr_plot_haptics.png`, `vr_plot_calibration.png`, `vr_plot_comfort_r1.png` | plots computed from the real classes (vignette panel B: the speed curve, fix round 5; panel E: a flapping sparrow, round 1 vs now; panel F: steady flight over orchard crowns, round 3 vs now; calibration panel D: the half fold vs the capture height for VR's capture, flight's refined and flight's as is) |
| `mutations_round2.log`, `mutate_round2.py` | fix round 2's mutation run on a scratch copy: the verifiers' surviving mutants in their new form plus mutants of the new code, all caught (§10) |
| `mutations_round3.log`, `mutate_round3.py` | fix round 3's mutation run on a scratch copy: the round-3 verifier's 15 survivors plus 20 mutants of the round-3 code (§11) |
| `probes_round3/` | the verifiers' probes (`tests/probes/vr`, all rounds) run against the fix-round-3 code: `report_r3.json` (20/20), `report_r2.json`, `report_exp.json`, `report_eng2.json` and their logs (§11 says why the old ones still fail) |
| `wings_fp_sim_controllers.png`, `wings_outside_sim_controllers.png` | fix round 3: the simulator's fixed controllers reproduced on the desktop (folded wings close along the arm) |
| `../tests/report_perf.json` | the on-demand CPU time gate (fix round 3) |
| `probes_round2/` | the verifiers' probes (`tests/probes/vr`, rounds 1 and 2) run against the fix-round-2 code: `report_r2.json` (16/19), `report_r2x_flight.json` (the flight-vignette probe on stable flight code), `report_exp_.json`, `report_eng2_.json` (§10 says why the rest fail) |
| `verify/` | the verifiers' own probe outputs (kept as they left them) |
| `../tests/report_unit_vr.json` | unit results and metrics (corner and random real-body worst cases, breakdown, adoption table, perf blocks) |
| `../tests/report_flight_rig.json` | the integration checks on flight's real `player.tscn` (who captures, the half fold as flown, the vignette in flight) |

## 7. Notes for other areas

- **flight**:
  - Re-seat the rig on `VR.recentered`.
  - Don't write `XROrigin3D.world_scale` or the camera near plane (VR's
    driver does it, before your tick).
  - `WingCalibration.from_dict` receives native Basis/Vector3 (also accept
    flat arrays if you parse JSON).
  - `wing_state()` with `ext_l/ext_r` drives the wing visuals.
  - Telemetry keys used: `stalled`, `stall_warning`, `in_updraft`,
    `wind_l_y`, `wind_r_y`, `perched`. Events used: `player_flapped`,
    `player_collided`, `player_stalled`, `player_perched`. VR reads
    `mode_name()` (the auto-capture gate) and `yaw_flagged` (vignette).
  - **Calibration (fix round 2): VR's is the one the player flies.** While
    the rig extras run, `VRCalibration` sets your PlayerBird's
    `auto_calibrate` to false (and restores it when it leaves): WingInput's
    §5.10 capture raced VR's and usually won, and its arms-5°-low drop and
    as-held neutral made a half fold read 0.09-0.61 depending on how high
    the arms were held. A capture you make anyway (`begin_calibration`) is
    adopted, refined to VR's maths and written back into your resource, so
    nothing breaks if you keep it. Scenes without the extras (your lab,
    your tests) keep your own capture. If you want the same result in
    `WingInput._capture_neutral`, the pieces are static and pure:
    `WingCalibrator.fit_body(pl, pr, neck, body_basis, seated)` (shoulder
    height from body proportions, the full-spread span) and
    `WingCalibrator.canonical_neutral(side, n_body, a_local)`.
  - VR reads `wing_state().stroke_period` (duck-typed) for the vignette's
    stroke-averaged acceleration.
  - **Request (fix round 3), done by flight:**
    `WingInput.calibration_replaced()` clears state learnt against the old
    neutral (auto-trim, twist filters, held twists). VR calls it right
    after writing a new neutral (fix round 4: VR no longer touches
    `_trim` itself). Correction to fix round 2's "nothing for flight to
    change": this was the one thing.
  - **Fix round 4, done by flight:** VR's span refinement needs genuine
    spreads while the game is played; flight's own WingInput refinement
    (the round-3 rule) no longer runs while VR owns the calibration
    (`WingInput.refine_span`, set from `auto_calibrate` every tick), and
    `WingCalibration.from_dict` validates native values. On the real rig
    flight's copy of the span now stays at VR's between VR's ticks
    (1.5996 m with a controller on a table; round 4: 2.00 m); VR's
    write-back (`span_drifted`) stays as a safety net. The vignette has
    no optic-flow term; `view_turn_rate` (a forced re-aim) still reaches
    it as rig yaw.
  - **Calibration redesign:** VR captures only in its explicit step (the
    first launch, and Recalibrate). Nothing captures in flight: a step
    requested during play pauses the game first. You get
    `calibration_replaced()` after each new VR neutral, and never
    otherwise; VR's span refinement changes only `arm_span` /
    `shoulder_width`. Your own automatic capture stays switched off while
    the extras run. Uncalibrated (first launch, until the step), your
    defaults fly. The vignette reads your PlayerBird's `mass` (Bird
    contract) for the cruise speed its speed term compares with.
  - A capture you make with `begin_calibration` after VR has calibrated
    is also adopted and refined now (it used to be ignored while VR held
    one). VR's span growth and seated changes reach your resource at once.
  - Synthetic pose sources that write the XR nodes work with the
    calibration and wings. Write your nodes after the XR nodes update
    (priority > 0).
- **ui**: `UIRoot.recalibrate_requested` starts VR's calibration step (its
  card is VR's own, transient, 3 draw calls; a step asked for during play
  pauses the game through `Events.menu_requested`). The redesign made one
  small, marked change in `scripts/ui/`: `UIRoot.context()` carries
  `recalibrate_suggested` (`VR.recalibration_suggested`, read
  duck-typed; the pause screen refreshes on
  `VR.recalibration_suggested_changed`), and `PauseScreen` shows "New
  player? Recalibrate wings" (action `&"recalibrate"`) in its top row
  while it is set, the run-so-far line then on the tip's line (UI suite
  144/144 after the change). A B/Y press while VR's card waits cancels the
  step (in a sub-screen your Back pops it as well). `VR.controls` exposes
  trigger/grip, and `VR.haptics.play(&"confirm")` etc. is available for UI
  feedback.
- **integration**:
  - Instance `scenes/vr/vr_rig_extras.tscn` under the player's
    XROrigin3D. With it, VR owns the wing calibration (above): with
    nothing saved, its first-launch card comes up as soon as the headset
    is focused (in the main menu).
  - Repeat V1 on `main.tscn` once UI, audio and the real NPCs are in it
    (the harness carries the NPC budget as stand-ins only), at a known
    machine load, and on the Quest Pro with OVR Metrics (the VR scripts:
    ~0.13 ms a frame in the simulator, ~0.4-0.55 ms projected there).
  - The player may be removed and re-added or reparented freely (fix
    round 5): the extras park and restore their parts. It may also be
    deleted and replaced (a respawn) with the extras placed elsewhere
    (fix round 6): the new rig gets new wings and a new vignette within a
    frame or two. Under the origin remains the recommended place.
  - The project settings list is in ARCHITECTURE "Contract changes"
    (2026-09-26, vr). `xr/openxr/extensions/user_presence=true` pauses
    when the headset comes off and raises the pause menu's "New player?"
    suggestion when it goes back on (without presence events only a
    60 s loss of focus raises it). The calibration redesign also set
    `xr/openxr/extensions/meta/color_space.pc=false` (vendors 5.1.0:
    the simulator supports no REC709, so on desktop the extension either
    errored or warned; §15).
  - world_scale snaps by itself on `run_started` / `player_spawned`;
    `WorldScaleDriver.snap()` remains for any other cut.
- **core**: add the Settings keys `vr_refresh_rate` 0 (auto = 72 Hz),
  `vr_foveation_level` 3, `vr_foveation_dynamic` true,
  `world_scale_exponent` 1.0 and `wing_calibration` {} to `DEFAULTS` (VR
  reads them with these fallbacks).
- **birds**: the player's wings now use `BirdModels.wing_palette`. An
  optional `accent_kind` key (bar / tip / te / edge / band) would let VR
  drop its `ACCENT_AT` table. A second covert colour (the eagle's golden
  `cov2`) would show on the player's eagle wings if `wing_palette` carried
  it.

## 8. Known limits

- **What one still pose cannot observe (calibration).** Measured over the
  whole population box, capture styles combined
  (`test_real_bodies_worst_case_is_bounded_at_the_corners`: 4096 corner
  players and 360 random ones; §3 V3):
  - **Shoulder width** (0.20-0.26 of the span across adults, ±3 sd) and
    the **eyes-to-shoulder drop ratio** (0.14-0.16 of stature, ±1.6 cm):
    straight arms put both shoulders on the hand line, and the drop ratio
    is an individual trait, so no capture pose shows either. They act on
    the half fold (its hand is ~20 cm from the shoulder, where a 2-3 cm
    shoulder error is 10-15 % of reach): up to 0.08 and 0.03 of extension
    on their own, **0.192 at the worst corner** of the box (a 1.4 m,
    broad-shouldered player with a long neck, low eyes and a floor 3 cm
    off, holding the arms 8° high, hands forward, elbows soft and looking
    at a hand), 0.121 over 360 random players with random combined styles.
    Every other gesture is well under that. The reference half fold itself
    reads 0.13, so this is the difference between a wing 13 % and 32 %
    open for the same arm pose. (Round 2 quoted 0.159: it applied each
    capture style alone, and a verifier showed combined styles read worse.)
    Considered and not done: estimating the shoulders from stroke arcs
    during play. It needs the elbow held constant through a stroke and a
    shoulder that does not rise with the arm, and neither is true of real
    people (scapular elevation), so a fitted "shoulder" could be further
    off than the population mean, and it would re-calibrate a flying
    player's wings; a controlled lesson ("hold your hand at your
    shoulder") would be the right tool if testers need it.
  - **Elbows held soft** at capture (15°): the measured forearm axis is
    the shoulder -> hand chord, off by half the bend. That leaks up to
    4.9° of twist into spread-wing gestures (glide pitch 0.088) with the
    other styles combined, and more into the arms-down fold. Flight's neutral-twist auto-trim (±10°, τ 60
    s, FLIGHT_SPEC §5.10) absorbs a glide bias of that size in play.
  - Everything the capture *can* see (arm height, hands forward, gaze,
    floor, ape index, eye ratio) now costs < 0.02 of extension.
- **Steady cruise near surfaces keeps the full view (fix rounds 4-5).**
  The vignette answers turns, speed over the bird's own cruise and
  sustained accelerations near surfaces; a sparrow skimming a hedge or a
  canopy at its cruise keeps the full view (round 3 narrowed it to 0.42
  there, and pulsed). An optic-flow term that follows the distance to the
  canopy cannot be steady along real lines (§2.5), so if testers find
  constant-speed low flight uncomfortable as a small bird, the levers are
  the wind audio, flight's heave smoother and small-bird cruise (§4),
  or lowering `VignetteModel.SPEED_LO` (1.3 x cruise) towards 1.0, which
  keeps the ring steady but narrows every flight. The speed term needs a
  player with a mass (it compares with `SizeRules.cruise_speed`); ground
  speed is what it measures, so a strong tailwind reads as speed (the
  flow the eye sees is ground speed too). The acceleration term needs a
  surface within 8 body spans (the probes: sides, below, ahead,
  ahead-down), judged slowly: after entering a forest it takes ~1 s to
  count in full, and after leaving one it fades over ~1.5-2.5 s. A thin
  object alone (a post, a wire) counts as a surface while it is near.
  Near surfaces flight's burst onsets (~35-59 m/s² perceived for a
  sparrow) still narrow the view to ~0.3 for 2-4 s: that is the
  accelerated motion the term exists for; lower
  `VignetteModel.ACCEL_WEIGHT` (0.5) if testers find it too eager.
- The stroke average needs flight's stroke period (a WingState contract
  field). Without it (no flight in the scene) a fixed 0.8 s window keeps a
  1 Hz beat under the threshold, but a 1.6 Hz beat can still show a faint
  (<= 0.09) edge.
- **90 Hz on this Mac**: in round 0 every 90 Hz run landed at 81.5-87.9 fps
  against the 85.5 bar (load 6-9), the same with and without the VR
  features (the A/B: fps 87.50 bare vs 87.85 with extras, 84.15 vs 83.00;
  all scripts < 0.2 ms of the 11.1 ms frame). 72 Hz passes every run.
  Enable 90 on the Quest Pro only after OVR Metrics shows headroom.
- The fps scene carries the NPC budget only as stand-ins (60 moving
  bodies, their draw calls, shadows and transforms; not the AI's CPU), and
  no UI or audio (in-progress areas). Integration should repeat V1 on
  `main.tscn`.
- Seated detection by head height (bounded by the standing eyes since fix
  round 4) cannot tell a player kneeling or crouching > 20 cm for 5 s from
  one sitting; the Settings `seated` preference is the reliable path. A
  player who calibrated seated has no measured standing eye height, so
  the span-derived thresholds apply until a standing capture.
- **Who wears the headset (calibration redesign).** Nothing recognises a
  new wearer any more, deliberately:
  - A new player flies the previous player's calibration until they
    choose Recalibrate. The headset off and on, a 60 s loss of focus or a
    relaunch put "New player? Recalibrate wings" in the pause menu; the
    same player sees it too (after every relaunch), until a step
    completes. Settings > Recalibrate wings and the Y-hold always work.
  - The step captures whatever plausible, still spread it is shown. A
    player who holds it with the wrists pitched, although the card says
    "hands flat", gets that pitch as flat; they asked, and a new step
    fixes it.
  - Uncalibrated players who skip the first-launch card fly flight's
    defaults (a 1.50 m span, the default wrist neutral). The card comes
    back at the next launch while nothing is saved.
  - The step's 45 s timeout does not apply to the first-launch card: it
    waits in the menu until it is done or cancelled.
  - The glide step (a personal glide reach and fold elevation) is gone
    with the redesign; the FLIGHT_SPEC defaults apply to every capture.
  - The span still never shrinks by itself: it grows only from two
    separate genuine spreads, by 10 cm a session, and a new step resets
    it.
- The simulator can't move both controllers at once with the head still
  without a persisted setting, so the harness flap is interleaved one-hand
  strokes. Its controllers are fixed "pointing forward" until moved: the
  calibration check (`run_calibration_sim.sh`) moves and turns them with
  the simulator's keys into a spread; the wing spread is shown with
  scripted arms on the real head (hybrid) and in desktop tests.
- The simulator has no haptic output: the real call path is exercised
  error-free, but the feel needs the device (QUEST.md §7). Foveation is
  unsupported in the simulator (and disabled by MSAA on desktop).
- The grip-pose convention is the simulator's; calibration absorbs any
  difference on real Touch Pro controllers (tests use ±25° wrist habits).
- Haptic amplitudes are tuned on paper and by rhythm plots; tune them on
  the Quest Pro.
- The moth tier gets feathered wings in the moth's palette (cream with a
  brown band) rather than a moth's scaled wings.
- Wing layout runs on the CPU: 19-21 µs a frame headless while the arms
  move (fix round 5; was 38-46), 9.4 µs in the simulator (was 87.7). The
  whole VR area: median 70.8 µs headless at load 8.2 against its own
  100 µs budget, ~134 µs in the simulator (§5). A vertex-shader layout
  would cut the wings further if the device ever needs it.
- **Folded wings seen from the eye** (fix rounds 4-5). Folded, the
  covert plates narrow and lengthen (round 4) and their roots, the wrist
  end seen from the eyes, taper to feathers' ends with outlines round
  them (round 5), so the wrist end is a scalloped edge of feathers in
  every palette (`wings_look_at_hands_sheet.png`). The primaries' own
  staggered tips lie back towards the elbows, below the view in those
  poses (they show from outside: `wings_outside_tuck.png`). The moth's
  folded wing reads as banded feathers, not a moth's. Judge the resting
  look on the Quest Pro with real hands.
- **Haptics under full load** (fix round 3): with the stall buffet, a
  thermal and a hunter all at once, the heartbeat keeps its rhythm and
  the buffet and the throb slow down together (x3.8: a buffet tick every
  ~0.45 s). flight_vr.md §13 ranks the stall above danger; VR keeps the
  heartbeat's rate because it encodes the threat's distance. Tune on the
  device.

## 9. Fix round 1 (2026-09-26): the verifiers' findings

| # | Finding (severity) | Fix | Evidence |
|---|---|---|---|
| 1 | Danger heartbeat stops 2 s into a steady threat (major) | The level is held until `threat_changed(< 0.35)` (queued beats dropped), the hunter dies or is freed, the game leaves PLAYING/PAUSED, `run_ended`, or `player_spawned` | `haptics_test.test_danger_heartbeat_holds_while_the_threat_is_steady` (15 pulses in 3-8 s, 0 after the all-clear); verifier probe `exp_haptics_probe_test` passes |
| 2 | Ungated automatic capture turns a pitched glide into "flat", persists it and overwrites flight's calibration (major, both verifiers) | Capture gate (`auto_capture_allowed`, closed by default; VRCalibration opens it only while spawning/perched/grounded, never paused); flight's capture adopted; uncalibrated VR never writes flight's resource | `calibration_test.test_auto_capture_waits_for_a_safe_moment`, `test_service_captures_only_while_perched`, `test_adopts_flights_own_capture`; verifier probes `exp_calibration_probe_test.test_auto_capture_does_not_take_a_pitched_glide_as_flat` and (adapted, see below) `eng2_integration_probe_test.test_auto_capture_while_flying_overrides_flight` pass on flight's real `player.tscn` |
| 3 | Rate-limit / smoothness tests use the code's own constants (major) | Tests assert the brief's numbers: duty <= 0.30, gap >= 0.040 s unless it outranks, <= 0.25 ln/s, sparrow -> eagle >= 8.6 s | `haptics_test.test_storm_never_becomes_a_buzz`, `world_scale_test.test_growth_ramps_smoothly` (the M3/M4/M5 mutants now fail) |
| 4 | V3 agrees by construction; the capture pose biases shoulder height ~1.1 cm/deg (minor) | Anthropometric shoulder drop; canonical neutral; 120 real-body players, a one-factor breakdown, a capture-style test | §3 V3; `vr_plot_calibration.png` panel D; limits in §8 |
| 5 | world_scale never snaps on a new run/respawn; late player ramps from 1.0 (minor) | Snap on `run_started`/`player_spawned`; untouched until a player mass exists | `world_scale_test.test_new_run_and_respawn_snap`, `test_first_size_is_not_ramped_from_one`; probes settle in 0.01 s (were 8.64 s / 7.79 s) |
| 6 | Vignette flashes on a flagged yaw step (minor, both) | Yaw steps > 720°/s, `yaw_flagged` ticks and the tick after `VR.recentered` re-seed; velocity baseline after a re-seed | `vignette_test.test_yaw_steps_are_not_turns` (peak 0.000); probes pass (were 0.29 / 0.096) |
| 7 | The policy's own simulator default (90 Hz) fails V1 (minor, both) | Auto = 72 Hz everywhere | `sim_result_default.json`: PASS with no override |
| 8 | perf_test near its bar under load (minor, both) | Fastest of 5 blocks < 100 µs, median < 2x; wing loop inlined (50 -> 44 µs) | `perf_test` (84-92 µs best block at load 7-8) |
| 9 | Calibration prompt is placeholder-grade (minor) | `CalibrationPrompt` card: lazy follow, progress ring, pose pictogram, tick/cross | `calibration_prompt_*.png`; `calibration_test.test_prompt_card_follows_lazily` |
| 10 | Wings read as feathered strips; colours drift from NPC wings (minor, both) | New layout (forearm-rooted primary fan, long secondaries, covert band), 3 outlines in one draw call, NPC palette + per-species accent | `wings_*.png`, `sim_wings_*_fplus.png`; `wings_test.test_species_tint` (NPC distance 0.0000); probe `exp_palette_probe_test` passes (was 0.31-0.38) |
| 11 | Production glue untested (M6, M12, M17) (minor) | Tests for load -> player, adoption, attach-time ALWAYS | `test_saved_calibration_reaches_the_player`, `test_adopts_flights_own_capture`, `pause_test.test_origin_forced_to_always_at_attach` |
| 12 | Suite hard-depends on flight's `WingCalibration` (minor) | Local §5.11 mock (`vr_wing_calibration_mock.gd`) | `calibration_test` never names flight's class |
| 13 | VR.md V1 scene numbers wrong (minor) | Corrected (61 mean / 70 worst draw calls, 81k primitives) | §3 V1 |
| 14 | Dead/test-only code, always-on profiling (minor) | `reset_calibration` removed; `read_from` wired in (adoption); `VRProfile` off unless enabled | `vr_profile.gd`, `vr_calibration.gd` |
| 15 | Lossy re-layout key (minor) | Full key (both grips with full bases, shoulders, extensions, ws, validity) | `wings_test.test_relayout_key_is_complete` |

Found while fixing:
- `load_saved()` used to push the uncalibrated defaults (`calibrated = false`)
  into flight's resource at startup, erasing a capture flight had made.
- The live `seated` flag lost the Settings preference.
- The vignette's first tick after any re-seed read the whole speed as an
  acceleration (a flash of its own, also after a teleport).

All three are fixed and tested.

**Where the verifiers' probes now fail, and why the code is right.**
- `exp_calibration_probe_test.test_real_bodies_and_capture_styles_read_consistently`
  and `test_json_round_trip_keeps_readings`, plus
  `eng2_integration_probe_test.test_saved_calibration_reaches_flight`:
  - These probes build a bare `WingCalibrator.new()` and expect it to
    auto-capture. The gate is deliberately closed by default. The owner
    must say the bird is perched, and VRCalibration does so from the flight
    state, so these probes never capture.
  - With the gate opened, as while perched (a temporary copy, deleted
    after the run): the JSON round trip passes. The integration probe
    passes on flight's real rig. The real-body grid reads a worst of
    extension 0.125, twist 6.6° (arms-down fold) and pitch 0.076. Those are
    the two unobservable residuals in §8, not the capture-pose bias it was
    written to catch: its capture-height rows now differ by <= 0.03.
- `eng2_integration_probe_test.test_auto_capture_while_flying_overrides_flight`:
  - It calls `reset_calibration()`, which the same verifier listed as dead
    code; it is removed.
  - A copy that resets through `from_dict` instead passes all asserts on
    flight's real `player.tscn` when flight holds nothing to adopt. Flight's
    neutral does not move, and VR does not capture while `mode` is FLYING.
  - When flight already holds a calibration, VR adopts it by design (one
    calibration, whoever took it). Flight's neutral still does not move
    (drift < 1° passes). The probe's `cal.calibrated` then reads true
    because of the adoption, not a capture.

## 10. Fix round 2 (2026-09-26): the verifiers' findings

Both verifiers' factual findings were reproduced before fixing (their
probes, `tests/probes/vr/r2x_*` and `r2eng_*`, on this tree); none was
wrong.

| # | Finding (severity) | Fix | Evidence |
|---|---|---|---|
| 1 | In the composed game the player flies flight's unrefined capture; VR adopted and persisted it (major, both) | VR owns the automatic capture: while its extras run, the PlayerBird's `auto_calibrate` is off (restored when they leave). A capture flight makes anyway is adopted, refined to VR's maths (`fit_body`, re-aimed axes, canonical neutral) and written back; VR's calibration refills a new or reset flight resource | `calibration_test.test_vr_owns_the_automatic_capture`, `test_adopted_capture_is_refined_to_vrs_maths`; on flight's real rig (`tests/sim/flight_rig`): 12 captures (12° low .. 8° high x tremor 0 / 0.3 / 1.5 mm), all VR's, half fold as flown 0.124-0.128 extension / 0.328-0.329 pitch (was 0.09-0.61 / 0-0.19); a capture flight made first, refined: 0.125-0.128 (flight's as is: 0.095-0.614). Probes `r2x_integration_probe_test` (2/2) and `r2eng_calibration_probe_test` (4/4) pass |
| 2 | Real-body bound fitted to one seed; residuals understated (major eng, minor exp) | The bound is the worst case over the corners of the population box (1024 players), and 3 seeds of random players must not exceed the corners; the full-spread span (`fit_body`) cut the corner worst from 0.190 to 0.159 and capture-style dependence to < 0.02; §8 quotes the true worst | `calibration_test.test_real_bodies_worst_case_is_bounded_at_the_corners` (corners 0.159 / 3.56° / 0.080 / 3.3 cm, bounds 0.17 / 4° / 0.085 / 3.5 cm); the six seeds the verifiers used read 0.106-0.118 (were 0.117-0.153) |
| 3 | Vignette pulses with the wingbeat (minor) | Acceleration averaged over flight's stroke period, then a 0.5 s box, judged against the window's mean heading | `vignette_test.test_wingbeat_does_not_breathe` (peak < 0.005 at 1-1.6 Hz); flight_rig `test_vignette_in_steady_flapping_flight` (every steady case 0.000-0.004; a dive still 0.30); `vr_plot_vignette.png` panel D |
| 4 | No simulator mirror shot shows a recognisable wing (minor) | Two hybrid shots look along a spread wing (the body turns 60-66° under the fixed head); a folding wing turns upper side up; stronger feather outlines; a 20° folded stagger | `sim_wings_hybrid_look_spread_fplus.png`, `sim_wings_hybrid_look_flap_fplus.png`, `sim_wings_real_controllers_fplus.png`, `wings_fp_held*.png`; `wings_test.test_folded_wing_lies_upper_side_up` |
| 5 | The V1 fps scene is lighter than the game (minor) | The NPC budget as 60 stand-ins in the harness | `sim_result_default.json`: PASS, 71.55 fps, 96 draw calls mean / 123 worst (one run at load 13 missed it: §3 V1) |
| 6 | Settings wiring for V4 / V6 / seated / exponent untested (minor; M33, M29, M50, M51) | An injectable settings source (`store`) on the vignette, haptics and world-scale driver, and tests through it | `test_setting_is_read_from_settings` (vignette, haptics), `test_exponent_is_read_from_settings`, `test_seated_setting_applies_live` |
| 7 | Species-tint test tautological (minor; M67, M68) | The group -> palette-column mapping is shader uniforms (`GROUP_COLUMNS`); the test reads the palette texture and the uniforms back; the accent placement is cross-checked against the birds area's species bands (M42) | `wings_test.test_palette_reaches_the_shader`, `test_accent_placement_matches_the_npc_species` |
| 8 | Adoption persists the Settings seated preference as "detected" (minor) | With the preference on, an adopted flag is replaced by VR's own detection | `test_adoption_keeps_the_seated_preference_out_of_the_saved_dict` (the probe, as a test); the probe passes |
| 9 | Claimed behaviours untested (minor; M28, M62, M36, M14, M09, M15, M42, M65) | A test for each | §3 V3/V6/V7/V10; `mutations_round2.log` |
| 10 | B long-press pauses in BOOT (minor) | BOOT dropped, as documented | `controls_test.test_right_b_long_press_pauses_only_while_flying`; the probe passes |
| 11 | Docs and test comments inaccurate (minor) | The real-body test documents its corner bounds; §5 rewritten from a perf test whose rays hit (a corridor) and from the simulator's per-feature costs (~186 µs/frame; 0.5-0.7 ms projected on Quest) | §5; `perf_test` |
| 12 | Dead or test-only code (minor) | Removed `feather_group`, `palette_color`, `get_mirror_viewport`, `hand_valid` (the rig's own validity path is tested instead), `REFRESH_ANDROID/DESKTOP` and the unused `android` parameter | `wings_test.test_untracked_wing_hides`; ARCHITECTURE contract note |

**Mutation run** (`artifacts/vr/mutations_round2.log`, on a scratch copy of
the tree): the verifiers' 15 surviving mutants in their round-2 form and 13
mutants of the new code, each applied alone. All 28 are caught. The first
pass let one survive (N09: VR's calibration not pushed to a flight
resource that was reset), because the claim path also pushes it; the
test gained that case.

Found while fixing:
- Round 1's `test_adopts_flights_own_capture` (§9) asserted the verbatim
  adoption that was the defect; `test_adopted_capture_is_refined_to_vrs_maths`
  replaces it. Round 1's real-body test is replaced by the corner test.
- The first-person "tuck" shot had always been empty: the tuck pose holds
  the hands under the chin, outside a headset's field of view. It is shown
  from outside (`wings_outside_tuck.png`); the folded wings a player sees
  are `wings_fp_held*.png`.
- With the perf test's rays hitting surfaces the budget was down to ~5 %;
  one ray per tick and a split, pre-scaled wing loop bought ~10 µs back.

**Where the verifiers' probes still fail, and why.**
- `r2x_calibration_probe_test.test_builders_bounds_hold_on_other_seeds`
  (0.1317 over 600 players against round 1's 0.13) and
  `test_corners_of_the_body_box` (0.1594 / 0.0800 / 3.28 cm against 0.13 /
  0.08 / 3 cm): they assert round 1's bounds, which were the defect. The
  probe's own corner numbers are the new test's corner worst (0.159 /
  0.080 / 3.3 cm) and lie inside the population bounds.
- `r2x_flight_vignette_probe_test`, sparrow fast flaps (1.6 Hz, 40°)
  only: peak 0.30, 54 % of 6-12 s above 0.05. Every other case passes
  (sparrow climb 0.29 -> 0.03, hover 0.26 -> 0.03, cruise 0.03 -> 0,
  starling climb 0.08 -> 0.01). In that window flight's model is still
  ringing after the frantic start (a trace of the probe's own case: forward
  speed 1.87-4.23 m/s at ~0.8 Hz, twice the stroke period, while climbing
  at 4.6-5.7 m/s, from 6 to 8 s): up to ~40 m/s² perceived at sparrow
  scale, real accelerated motion, not the beat (the window is the stroke,
  0.625 s). It drops below 0.05 at 9.3 s and to 0 at 10.9 s; flight_rig
  measures the same case settled at 0.004.
- Round-1 probes: `exp_calibration_probe_test` (2 tests) and
  `eng2_integration_probe_test` (2 tests) fail as in round 1 (§9): a bare
  `WingCalibrator.new()` with the gate closed, and `reset_calibration()`.
  `exp_palette_probe_test` no longer parses: it calls `palette_color()`,
  which the engineering verifier listed as test-only code and is removed.
  A copy using `wing_colors()` for the same lookup passes.

## 11. Fix round 3 (2026-09-26): the verifiers' findings

Every finding was reproduced with the verifiers' own probes
(`tests/probes/vr/r3x_*`, `r3eng_*`) before fixing; none was factually
wrong. After the fixes **all 20 round-3 probe tests pass**
(`artifacts/vr/probes_round3/report_r3.json`), and so do the round-2
haptics probes that the first version of the haptics fix broke (§ below).

| # | Finding (severity, lens) | Fix | Evidence |
|---|---|---|---|
| 1 | Folded wings pop 52-82° for a 1° wrist/elbow change and flicker under tracker noise (major, both) | The fold-to-level turn's weight fades smoothly to 0 near a vertical forearm and a palm-up hand (`fold_level_turn`); the arm-line handover near the shoulder is smooth; a folding wing also closes along the arm (`fold_align_turn`) | `wings_test.test_folded_wing_turns_continuously` (worst 3.67°/° of input, <= 1.95° per frame under ±0.3° noise), `test_palm_up_fold_keeps_the_hands_plane`; probes `r3x_wings` 4/4 (were 2 failing), `r3eng_probe.test_folded_wing_plane_is_continuous_in_wrist_roll` passes |
| 2 | The vignette narrows during ordinary open-sky flap/glide flight (major, experience) | The acceleration term counts only with a surface within 8 body spans (in full within 3), thresholds unchanged: §11.4's "open sky keeps the full view" | `vignette_test.test_accel_proximity`, the flare and surge cases near a surface vs open sky; flight_rig `test_vignette_in_open_sky_flight`: 0 % of flap/glide flight narrowed > 0.10 for every species (round 2: 30-86 % for the sparrow), a dive along a cliff still 0.42; probe `r3x_flight_rig` passes |
| 3 | Important haptics dropped or cut when the continuous patterns fill the budget (minor, experience) | Duty shares: rhythms <= 15 % (heartbeat's 8 % kept, buffet and throb slowed together), routine <= 21 %, important to 30 %; rhythms never cut into a pulse; discrete pulses wait (<= 60 ms) instead of being dropped; stall buffet 15 ms / 100-150 ms; heartbeat 2 x 20 ms (flight_vr.md §13) | `haptics_test`: important events whole 24/24 in every combination and under frantic flapping, 20/20 flaps while stalled, every flap felt through all three rhythms, heartbeat >= 90 % of beats under full load, shortening (E13); probes `r3x_haptics` 3/3, `r2x_haptics` 4/4 |
| 4 | "Worst case at the corners" breaks once capture styles combine (minor, experience) | The corners are now the full factorial (64 body x 16 style x 4 habit = 4096 players), random players get random combined styles; bounds restated; §8 quotes the true residuals | `calibration_test.test_real_bodies_worst_case_is_bounded_at_the_corners`: 0.192 / 4.94° / 0.088 / 0.152 / 3.3 cm (bounds 0.20 / 5.2° / 0.095 / 0.16 / 3.5 cm); probe `r3x_calibration.test_combined_capture_styles` passes |
| 4b | Seated grid reads 0.035 after detection (part of #4) | Seated below max(1.30 m, 0.75 x stature from the span), also decided at the capture; standing above max(1.40, 0.80 x) | `test_seated_grid_reads_the_same` (detected and by preference: 0.0002), `test_seated_detection_has_hysteresis`; probe `test_seated_grid_reads_consistently` passes |
| 5 | Flight's recapture after VR has calibrated is not adopted; docs overclaim (minor, both) | `foreign_capture(res)` each tick (flight's neutrals differ from VR's by > 1e-3 rad) -> adopt, refine, write back, persist; docs now true | `test_flight_recapture_after_vr_is_adopted`; flight_rig `test_flight_recapture_after_vr_is_refined` (flight flies 0.2865 = the body's; was 0.150); probe passes |
| 6 | NaN `world_scale_exponent` poisons world_scale and the near plane (minor, experience) | Non-finite exponent / mass / span / saved values rejected | `world_scale_test.test_corrupt_settings_never_reach_the_rig`; probe `r3x_focus_scale` passes |
| 7 | World-scale plot shows a "caught" shrink as a ramp (minor, experience) | The plot snaps on the respawn as the game does, and shows growth ramps separately | `vr_plot_world_scale.png` |
| 8 | Wing visuals at rest and in the tuck read poorly (minor, experience) | Feather roots shaded under the row above, ±7 % per-feather jitter, low ridge on covert plates, the arm feathers fold in along the forearm in a tuck, the folded hand frame closes along the arm | `wings_outside_tuck.png` (one closed wing), `wings_fp_sim_controllers.png` (primaries no longer stick up), `wings_fp_*`, `wings_species.png`; the simulator mirror's resting corners still show plain shoulder coverts (§8) |
| 9 | 15 of 24 new mutants survive (minor, engineering) | A test for each (§3) | `mutations_round3.log` (below) |
| 10 | `perf_test` is load-sensitive (minor, engineering) | The unit test pins the work and records time; the 100 µs gate moved to the on-demand `tests/sim/perf` suite (fastest block, rerun if disturbed) | `perf_test`, `tests/sim/perf/vr_perf_test.gd`, `report_perf.json` |
| 11 | Seating detected after calibration never reaches flight (minor, engineering) | Refinements are applied to flight at once (after adopting any foreign capture) | `test_refinements_reach_flight_and_persist`; flight_rig `test_detected_seating_reaches_flight`; probe `r3eng_probe.test_detected_seating_reaches_flight` passes |
| 12 | VR's recalibration leaves flight's auto-trim stale; "nothing for flight to change" was wrong (minor, engineering) | Contract request (ARCHITECTURE "vr (fix round 3)"): `WingInput.calibration_replaced()`, called after every new VR neutral; flight has added it; `_trim` fallback for older flight code | `test_new_neutral_clears_flights_trim`; flight_rig `test_recalibration_clears_flights_trim` (0.00° with 6° of stale trim, via flight's hook); probe `r3eng_flight_grid` 2/2 |
| 13 | Dead and test-only code (minor, engineering) | Removed `_t_on_hand`, `pitch_norm()`, `VRMath.basis_to_array/vec_to_array`; `focus_losses` is now read by the harness's 11th check; `TIP_ALLOWANCE` derived from `TIP_OVERHANG` | ARCHITECTURE note; `sim_result_default.json` `focused_through_the_fps_window` |
| 14 | The flight-rig vignette check skipped the first 10 s (minor, engineering) | Asserted over the whole run, onset included, plus the flap/glide rhythms | flight_rig `test_vignette_in_open_sky_flight` |
| 15 | Report nits (minor, engineering) | The random-population summary counts its players (360); the corner summary 4096. The runner writing `artifacts/tests/report_<suite>.json` is core's tooling (not VR's to change); VR's evidence copies live under `artifacts/vr/` | `report_unit_vr.json` |

Found while fixing:
- The birds area retuned the starling's colours; the fallback palette copy
  had drifted (`test_species_tint` failed at the start of this round). The
  copy is updated, and the test now prints the rows to paste when it
  drifts again.
- The first version of the haptics fix slowed every rhythm together,
  including the danger heartbeat, whose rate is the threat's distance: two
  round-2 verifier probes (heartbeat while flapping in a thermal, and in
  the worst mix) that had passed began to fail. The heartbeat now keeps a
  reserved share and its rhythm; both probes pass again. Two scheduling
  rules of that first version (continuous beats in overdue order, discrete
  pulses first within a tick) had no measurable effect once the heartbeat
  had its share (their mutants N11/N12 survived), so they were removed
  rather than kept untested.
- The capture-window bookkeeping re-summed the whole hold every tick; it
  is a running total now (the 4096-player test takes ~20 s).
- Seated players were decided only by the 5 s timer, which could not know
  the stature before the first capture; the capture now decides it too.

**Mutation run** (`artifacts/vr/mutations_round3.log`, `mutate_round3.py`,
on a scratch copy of the tree, each mutant alone, the unit suite plus the
flight-rig suite where marked): the round-3 verifier's 15 surviving
mutants (E01-E15, E31, E37, E44 in the current code's form) and 20
mutants of the round-3 code (N01-N20). **All 35 are caught** on the final
code. The first pass let E06 through (the crossed arms in its test were
not far enough apart to steer the torso estimate; the test now crosses
them wide) and N08/N11/N12 (the first haptics design; a test was added for
N08, and the two rules N11/N12 broke were removed, see above; N11/N12 now
mutate the heartbeat's reservation). The log keeps every pass.

**Where old verifiers' probes still fail, and why the code is right.**
- `r2x_calibration_probe_test` (2 tests): they assert round 1's bounds
  (0.13 / 0.08 / 3 cm), which were the defect; round 3's corner
  enumeration measures the population's true worst (§3 V3), inside its
  stated bounds.
- `exp_calibration_probe_test` and `exp_palette_probe_test` no longer
  parse (they call `VRMath.basis_to_array` / `palette_color()`, removed as
  test-only code at the engineering verifiers' request); round 1's
  explanation (§9) holds for their other asserts.
- `eng2_integration_probe_test` (2 tests): a bare `WingCalibrator.new()`
  with the capture gate closed, and `reset_calibration()`, as in §9.


## 12. Fix round 4 (2026-09-26): the verifiers' findings and the lead's direction

Both verifiers' round-4 findings (`artifacts/vr/open_findings_b2.json`),
fixed at the root, each with a test that fails on the round-3 code
(`artifacts/vr/old_code_check_round4.log`: the round-3 `scripts/vr` with
this round's defect test files, which use only the round-3 API).

| # | Finding (severity, lens) | Fix | Verified by |
|---|---|---|---|
| 1 | Span refinement accepted any wide grip distance and persisted it: a controller on a table changed span, readings, bird size and the seated flag; also while paused (major, experience) | Rewritten (§2.3): genuine spread-arms pose only (each gate with a reason), only while the game is played and focused, 2 separate spreads, 80th percentile, +10 cm per session, a manual recalibration starts a new session; seated thresholds bounded by the standing eyes measured at the capture, on the level-head eye height. Flight's WingInput applies the same round-3 rule to its own copy (the verifier's "where" noted it): VR now writes its span back into flight's resource whenever they differ | `span_refinement_test` (6), `calibration_test.test_spread_gates`, `test_flights_own_span_growth_is_undone`, flight_rig `test_a_controller_on_a_table_changes_nothing_in_flight` (flight's copy 2.00 m between ticks, VR's 1.60 m back each tick, half fold 0.125 before and after); round 3 fails 5 of 6 (table: 1.60 -> 1.80/2.00/2.15 m, half fold 0.125 -> 0.000, world_scale 0.133 -> 0.120/0.109/0.102, "seated"; menus: 1.50 -> 1.75 m); verifier probes `r4x_span_inflation`, `r4x_menu_recalibration` pass |
| 2 | The vignette pulsed in steady flight over broken surfaces (orchard, forest, posts) (major, experience) | Self-motion only (§2.5): the per-frame optic-flow term removed; the acceleration term's proximity is slow (nearest probe hit held 1.5 s, low-passed 1 s; side probes swept, never aliasing) | `vignette_steady_test` (steady: exactly 0 over every surface; surge: std <= 0.005, periodic <= 0.0023; round 3: peaks 0.19-0.42, std 0.03-0.08); `tests/sim/real_world` (36 lines on the real world: steady std 0.0000); plot panel E; probes `r4x_vignette_flicker`, `r4x_vignette_real_world` pass |
| 3 | Folded wings read as rounded plates, also in natural poses; the crow a navy blob (minor, experience) | Covert plates narrow (0.55x) and lengthen (1.45x) as the wing folds; a wider folded fan of hand coverts; light feather edges on dark plumage | `wings_test.test_folded_coverts_become_feathers`; `wings_look_at_hands_sheet.png`, `wings_outside_tuck.png`, `wings_outside_sim_controllers.png` |
| 4 | Comfort R1 plot label collided with the hawk bar (minor, experience) | The obsolete flow-threshold lines are gone with the flow term | `vr_plot_comfort_r1.png` |
| 5 | A corrupt saved neutral / axis silently disabled wrist control and reached flight (minor, engineering) | All-or-nothing sanity check of the saved rotations and axes (finite, near-rotation, near-unit), else defaults + uncalibrated + a log line; the same path for a capture read from flight's resource | `calibration_load_test` (fails on round 3); probe `r4eng` (its one remaining failure asserts the round-3 state "still calibrated", which is the defect) |
| 6 | 10 of 22 mutants survived (minor, engineering) | Tests for R01, R02 (plus a near-plane re-assert the driver lacked), R09, R10 (a fake XR interface: `center_on_hmd` really re-centres), R11 (`VRManager.vrs_mode_for`, and the simulator checks the live viewport), R15, R17 (`XRSink.xr` injectable), R18, R21; R13 is gone with the flow term; the simulator harness now also turns the head and checks `VR.recenter()` (40.0° -> 0.0°) | `mutations_round4.log` |
| 7 | Unit suite depended on the birds area's internal data (minor, engineering) | The fallback-palette drift and accent checks moved to the on-demand `tests/sim/birds_palette`; the contract check (drawn colours = `BirdModels.wing_palette`) stays | `wings_test`, `tests/sim/birds_palette` (2/2 today) |
| 8 | Dead code and a poke into flight's private `_trim` (minor, engineering) | Removed the `neutral_roll_*` writer and its never-running test branch, the `_trim` fallback, and `vr_shots`' unused `wings_calls` | `calibration_test` (writes and checks all six §5.11 geometry fields), `test_new_neutral_clears_flights_trim` (a WingInput without the hook is left alone) |
| 9 | `VR.focused` stayed true after the headset came off (minor, engineering) | `focused` = session focused and headset worn; presence off is the one focus loss; any loss signal still pauses a running game | `vr_presence_test` (2; fails on round 3); probe `r3x_focus_scale` |

**Found along the way.**
- My first draft counted a focus loss only on the focused true -> false
  transition and paused only then: a verifier's older focus-chatter probe
  (`r3x_focus_scale`) found that a game left PLAYING with the headset
  already off was then never paused. Every loss signal now pauses a running
  game (idempotent); only the transition is counted and announced
  (`vr_presence_test.test_a_running_game_pauses_on_any_loss_signal`).
- Removing `ComfortVignette.flow` broke two older verifier probes that read
  it; it stays as a deprecated field that is always 0.
- The span estimate: grip-to-grip distance (round 3) is shorter than the
  full spread whenever the arms are not exactly level; the sample is now
  width + reach_l + reach_r from the calibrated shoulders, which equals the
  captured span for the captured pose, so a player spreading as at capture
  never drifts it.
- Two gates of my first design were removed rather than kept untested:
  "head facing between the hands" (the neck-pivot shoulder model follows a
  turned head, so it protected nothing) and "not during the manual flow"
  (a spread there is genuine and the capture starts a new session anyway;
  mutant N04 survived it). "Grips centred on the neck" was dropped as the
  symmetric-reach gate implies it.
- The perf bench's corridor was out of the new probes' reach at a
  sparrow's world_scale (674 of 900 frames held a surface); it now sits
  inside it (every probe but "ahead" hits: the worst case for cost).
- `vr_shots` printed the wingtip as a 3D distance (0.024 m at ws 0.15 for
  a wanted 0.015): the leading primary sits 3° back and the shot measured
  before the extension had settled. It now prints the overhang along the
  forearm after settling: 0.0150 / 0.1300 m at ws 0.15 / 1.3, exact.

**Verifier probes after this round** (`tests/probes/vr`, 71 tests,
`artifacts/vr/probes_round4.log`): 64 pass. Failing by design: `r2x_calibration` (2: round 1's bounds, §11),
`exp_calibration` / `exp_palette` (parse: test-only code removed at a
verifier's request, §11), `eng2_integration` (2, §9), `r4eng`'s corrupt-
basis test (1 assertion: it records the round-3 state "the corrupt dict
still says calibrated"; marking it uncalibrated is the verifier's own
suggested fix). All of this round's probes' substantive assertions pass.

**Mutation run** (`artifacts/vr/mutations_round4.log`, `mutate_round4.py`,
on a scratch copy of the tree, each mutant alone, the unit suite plus the
flight-rig suite where marked): the engineering verifier's surviving
mutants R01, R02, R09, R10, R11, R15, R17, R18, R21 in the current code's
form, and 26 mutants of this round's code (N01-N28: every refinement gate,
the two-spread rule, the percentile, the session cap and reset, the
standing-eye bound and the level-eye height, the corrupt-geometry check,
the slow proximity, the hold, the swept side probes, the presence-focus
rules, the folded coverts, flight's span re-assert, the standing eyes
under the seated preference). **All are caught; the only survivor is N24,
a deliberately equivalent control.** The first pass let N01 (the
paused-tree gate: the state gate hid it; a test now pauses the tree with
the state still PLAYING) and N04 (the manual-flow gate: removed, see
above) through. N20 (no hold) also showed that a 32-bit timestamp could
empty the hold queue; it now always keeps the newest entry.

**Old-code check** (`artifacts/vr/old_code_check_round4.log`): on the
round-3 `scripts/vr`, `span_refinement_test` fails 5 of 6 (the sixth,
tracking glitches, pins new behaviour round 3 happened to share),
`vignette_steady_test` 2 of 2, `calibration_load_test` 1 of 1,
`vr_presence_test` 2 of 2, all with zero script errors.


## 13. Fix round 5 (2026-09-26): the re-verification's findings

Both re-verifiers' findings on the round-4 code (experience lens: fail on
one major; engineering lens: pass with minors), reproduced with their own
probes before fixing (`r1x_experience.test_second_wearer`,
`r1eng_probe.test_rig_leaving_and_reentering...` fail on round 4 in their
logs, pass now). None was factually wrong. One suggestion was tightened
on measurement: the experience verifier proposed keeping the old
calibration unless the span differs by > 5 cm or a neutral by > 5°; a
second wearer differing only by 5 cm of span reads 0.084 of extension off
under the first one's calibration (the brief's bar is 0.03), so the
re-check keeps only what agrees within 2 cm, 1° of twist and 3° overall
(§2.3).

| # | Finding (severity, lens) | Fix | Verified by |
|---|---|---|---|
| 1 | Automatic calibration runs once per install: a second wearer flies the first one's span and wrist neutral (+20° habit: pitch +0.31 on flat wrists; half fold 0.77 for 0.13) (major, experience) | A re-check armed at app start, headset on and focus regained; the same player keeps everything, anyone else gets a fresh automatic calibration (glide step reset), sent to flight with its trim voided and persisted; only a body counts (symmetric reaches), seating judged afresh, never with the headset unfocused (§2.3) | `wearer_test` (6 tests, 7 hand-overs within the brief's bars: extension 0.005, twist 0.07°, pitch 0.0013); the verifier's probe passes (pitch 0.000, half fold 0.124 vs own 0.125); mutations W01-W18 |
| 2 | Folded wings seen from the eye read as stepped slabs or planks across palettes (minor, experience) | Folded covert roots taper to feather ends (the wrist end becomes a scalloped edge), outlines round every folded feather's end and a wider vane edge, a brighter sheen on dark plumage; per wing by its fold (`fold_lr`); spread wings unchanged (§2.6) | `wings_look_at_hands_sheet.png` (12 poses, the verifier's palettes included), `sim_wings_real_controllers_fplus.png`; `wings_test` pins the uniform; mutations F03, F04 |
| 3 | V1 fps margin razor-thin; the VR scripts ~3x the area's budget in the simulator; the perf gate judged its best block (minor, experience; §5 stale, engineering) | The gate judges the median; the wing layout is one native product per feather from a fan cache that now hits (38-46 -> 19-21 µs headless, 87.7 -> 9.4-10.1 µs in the simulator); absent controllers skipped; §5 rewritten from this round's runs | `report_perf_round5.json` (median 70.8 µs at load 8.2); `sim_result_default.json` (69.85 fps at load 11.2, VR ~146 µs a frame; 71.8 fps / ~134 µs at load 7.0 earlier; round 4 ~257); mutations F01, F02 |
| 4 | No speed response, which DESIGN asks for (minor, experience) | Speed term: the smoothed rig speed over the bird's cruise speed (1.3 -> 2.3 x, weight 0.7); an optic-flow term on the held distances was prototyped and rejected: it follows the canopy (§2.5) | `vignette_steady_test.test_speed_term_is_steady_and_scale_free`, `vignette_test.test_strength_curve`; `tests/sim/real_world` (steady cruise 0.0000, a fast glide std 0.0006 on 36 lines); `flow_term_sweep_round5.log`; plot panel B; mutations S01-S03 |
| 5 | The rig leaving and re-entering the tree frees the wings and the vignette for good (minor, both) | Parts parked on exit, restored on entry (tree hook reconnected, rig re-wired, vignette motion reset), freed with the extras only (§2.8) | `pause_test.test_rig_leaving_and_reentering_keeps_its_parts`; the verifier's probe passes; mutations X01-X04 |
| 6 | The dev-scene simulator screenshots show no wings (minor, experience) | Re-rendered with Forward+; the old frames were a forward view with the flap's arms out of frame, so the dev scene gained `--torso_yaw` (the harness's hybrid body turn) and looks along the wing | `dev_sim_10s.png`, `dev_sim_18s.png` (replaced in fix round 6 by the `--demo` shots, §14: these two were byte-identical) |
| 7 | The OpenXR wiring, the refresh policy at session start and headset-on while only VISIBLE are untested (E30, E53 survived) (minor, engineering) | `connect_interface(source)`; a stand-in interface emits every signal in `vr_session_test`; the harness checks `refresh_policy_applied` (§2.1) | `vr_session_test` (4); `sim_result_default.json` (14th check); mutations E30, E53, D01, D02, H01 |
| 8 | Test gaps: sweep-back fold (E28), wing/calibration order (E38), aim-pose controllers only in flight's rig (E41) (minor, engineering) | `calibration_test.test_hands_behind_the_back_fold_the_wing`, `wings_test.test_wings_follow_the_controllers_in_the_same_frame`, aim-pose controllers ahead of the grips in the stub rig | mutations E28, E38, E41 (13 tests fail) |
| 9 | Docs and comments drifted (VR.md §5's simulator cost; `fp_wings.gd` pointing at checks that moved) (minor, engineering) | §5 rewritten; the comments point at `tests/sim/birds_palette` | §5 |
| 10 | `ComfortVignette.flow`, always 0, kept only for old probes (minor, engineering) | Removed, as the verifier suggested | `probes_round5.log`: the two probes that read it no longer run; with only that read replaced they pass (`probes_round5_flow_patched.log`, 3/3) |

**Found along the way.**
- The wing layout's fan cache had never hit since round 2: its key was a
  32-bit copy of the 64-bit extension (performance only; now pinned by
  `test_a_held_extension_rebuilds_no_fan`).
- The first simulator run of this round passed all 14 harness checks but
  the wrapper failed it on an engine warning: physics object picking (on
  by default) is switched off by the engine in stereo when a mouse event
  reaches the mirror window. `VRManager` switches it off with `use_xr`;
  the rerun is clean.
- A re-check with the controllers in the wrong hands reads as crossed arms
  (the body's facing is known) and never fires; the odd grip is the case
  that reaches the rejection, and the test uses it.
- Headless rendering keeps no MultiMesh instance data, so the wings keep
  CPU copies of what they give the renderer (`feather_transform`,
  `feather_custom`) for the tests.
- Two timer resets I first wrote into the re-check had no observable
  effect (a standing capture sets thresholds its own eyes are above, so
  the seated timer resets on the next tick anyway); they were removed
  rather than kept untested. The mutation run then showed that an extra
  "eyes under 1.30 m" rule in the re-check was unpinned: it would have made
  a re-check disagree with a fresh install for small bodies, so it went
  too (mutant W10 now mutates the capture's stature rule). The re-check's
  1° twist check survived at first (the 3° whole-neutral check covered
  every case); a wearer with only a 2° wrist habit now pins it. The glide-step reset is observable only for a
  glide step low enough to move the fold elevation, so the test's glide
  step is now 55° low.

**Mutation run** (`mutations_round5.log`, `mutate_round5.py`, on a
scratch copy of the tree, each mutant alone, the unit suite): the
re-verification's surviving mutants in the current code's form (E28, E30,
E38, E41, E53, and two deleted connect lines D01/D02), the harness counter
(H01) and 33 mutants of this round's code (the re-check's arming, gates,
thresholds, resets and seating W01-W18, the extras' lifecycle X01-X04, the
speed term S01-S03, the wing cache, snap, fold shading, arm placement and
the direct pose read F01-F06, the controls' idle skip C01): **41 mutants,
40 caught; the only survivor is Z01, a deliberately equivalent control.**
The first pass let four through: W16 and F05 / F06 had no test (added:
the 2° wrist habit, the arm feathers along the arm, nested XR nodes) and
W10's extra 1.30 m rule was removed rather than pinned (see above); the
follow-up pass (same log) catches all of them, and W18 (the fold
elevation reset) and W07 against the stronger glide-step test.

**Final runs** (`report_unit_vr_round5.json` 152/152,
`report_flight_rig_round5.json` 7/7, `report_real_world_round5.json` 1/1,
`report_perf_round5.json` median 70.8 µs, `birds_palette_run.log` 2/2,
`sim_result_default.json` 14/14, `sim_result_fplus.json` 7/7).

**Verifier probes** (`tests/probes/vr`, 79 tests, `probes_round5.log`):
70 pass, including the re-verification's new ones (the second wearer, the
rig re-entering the tree, bodies beyond the brief, ten minutes of play,
the tucked view). Failing by design: `r2x_calibration` (2) and
`eng2_integration` (2) and `r4eng`'s corrupt-basis assertion (1), as
before (§9, §11, §12); `exp_calibration` / `exp_palette` do not parse
(test-only code removed at a verifier's request, §11); `r2x_flight_vignette`
and `r3x_flight_rig` read the removed `ComfortVignette.flow` (their
substantive assertions pass with that read replaced by 0).

## 14. Fix round 6 (2026-09-26): the second re-verification's findings

Both round-5 verifiers failed the area on the wearer re-check (major),
the engineering one also on a replaced rig (major); four minor findings.
Every finding was checked and none was factually wrong. Both verifiers'
round-5 probes (`r5x_recheck` 3, `r5eng` 6) fail on the round-5 code and
pass now.

| # | Finding | Root cause and fix | Evidence |
|---|---|---|---|
| 1 | The wearer re-check replaced ONE player's calibration from an unprompted pose: a flare held on a perch after the system menu (or at the next launch) became "flat" (-0.28 / -0.49 pitch for 15° / 20°); a 1.5° re-grip kept it 3 times in 20, discarding the manual glide step; the same-player test modelled no variation (major, both) | Round 5 judged "the same player" within 2 cm / 1° / 3°, far inside human repeatability, and acted on any difference. Now (§2.3): the same player is judged within what one person repeats (span 2 cm of the captured-to-refined range, drop 2 cm, wrist twist 5° = the pitch dead zone, grip swing 7°) and kept silently; any other pose only puts up the card ("Lower your arms, then spread your wings, hands flat"), and only a FRESH prompted spread (after a break) can recalibrate; an unanswered card goes away keeping the calibration; automatic captures wait 2 s after landing; a focus regain arms the re-check only without presence events (`VR.presence_supported`) | `wearer_test` (12): 60/60 realistic re-dons kept at once; every flare / trigger / answer combination reads flat wrists as before (pitch change 0.0000); the relaunch variants kept; bounds both sides; probes `r5x_recheck` 3/3, `r5eng` relaunch 5/5 kept |
| 2 | With the extras placed away from the rig, a replaced rig threw a SCRIPT ERROR and got no wings, vignette or growth (major, engineering) | The parts moved onto the old rig died with it and `try_attach` reused the freed references. Now it makes new parts (`_ensure_parts`), skips a rig being deleted (`_doomed`) and re-attaches at once when the rig goes or a new one enters the tree | `rig_lifecycle_test` (freed; queued with the new rig in the same frame; an attach in the respawn's own frame): wings, vignette, calibration, growth 0.141 -> 1.235 within 3 frames; probe `r5eng.test_rig_replaced...` passes |
| 3 | The dev scene's two simulator shots were byte-identical: one still pose (minor, experience) | The dev scene gained `--demo`: a timeline (spread as a sparrow, flapping, the wrists rolled back as a gull, a fast hard turn) with one shot per phase | `dev_sim_7s/11s/15s/20s.png` (four different md5s), `dev_sim_run.log` |
| 4 | Frame pacing hidden behind the mean fps (minor, experience) | The harness records every frame interval of the fps window and reports p50/p95/p99/max, the budget and the hitches (> 1.5 intervals) in `metrics.fps.frame_ms` and a `SIM pacing` log line; reported, not gated (the tail is the shared Mac) | `sim_result_default.json` (p50 13.90 / p95 20.80 / p99 26.39 ms at load 12.0); `sim_harness_test` (2) |
| 5 | A missing `fold_lr` uniform showed as a SCRIPT ERROR inside a test the runner counted as passed (minor, engineering) | The test assigned `get_shader_parameter()` to a typed Vector2; it now checks the value is a Vector2 first, so the test itself fails. (That the runner counts a test aborted by a script error as passed is the core test framework's; VR's commands and mutation script grep for script errors besides) | `mutations_round6.log` F03: caught by a failing `wings_test`, not only by an error |
| 6 | The WHEN_PAUSED correction under the rig was unpinned (minor, engineering) | `pause_test` adds WHEN_PAUSED nodes (added under the rig, and already there at attach) and checks they process in play and while paused | mutant P01 caught |
| 7 | `VRControls._xr_read` never ran (minor, engineering) | The sentinel is gone: an empty `reader` means "read the trackers", which is the path the real-tracker test drives | `controls_test`; mutant C02 caught |

**Why prompt instead of deciding (the design choice).** An unprompted
still spread cannot tell a second wearer with another wrist habit from
the same player holding a flare or re-gripping: the two verifiers' probes
are the same pose with opposite right answers. The experience verifier
suggested prompting whenever it is armed; prompting only when the pose
differs keeps the same player's re-dons silent (60 of 60 in the test).
Requiring a fresh spread (`check_needs_break`) is what makes the prompted
pose trustworthy: without it the flare that raised the question answered
it 1.2 s later, before the player could read the card (mutant R06). The
bounds come from the flight model, not from a guess about people: a kept
calibration never makes flat, level wrists command pitch (5° = the pitch
dead zone) and at most 0.0078 of roll; within 2 cm of span a half fold
reads within 0.027 of the wearer's own. Replacing on a prompted answer
also resets the glide step (the same body may be another person) and
goes straight on to the optional glide step.

**One earlier probe now fails by design:** `r1x_experience.
test_second_wearer_after_the_headset_changes_hands` (round 1) holds one 3 s
spread and never answers the card, and expects that unprompted pose to
recalibrate, which is exactly what fix round 6 forbids. With only that
probe's second wearer lowering the arms and spreading again (what the
card asks) it passes: flat wrists pitch 0.000, half fold 0.123 vs B's own
0.125 (`probes_round6_r1x_prompt_followed.log`; the patched copy was run
from the unit directory and deleted).

**Mutation run** (`mutations_round6.log`, `mutate_round6.py`, on a
scratch copy of the tree, each mutant alone, the unit suite): 29 mutants
of this round's code and of the verifiers' unpinned findings: the wearer
check's rule, bounds, break, capture span, dismissal, prompt, settle,
presence arming, glide reset and flow (R01-R21), the replaced rig
(X05-X08), WHEN_PAUSED (P01, the engineering verifier's P1), the fold
uniform (F03), the controls' reader (C02), the harness's hitch count
(H02), plus the equivalent control Z01. **The first pass caught 28 of 29;
R10 survived** (a kept prompted check kept capturing, so a flare held
afterwards could still have been taken): the flare test's "follow the
prompt" branch now checks the capture stops and holds the flare again
for 2.5 s, and the follow-up pass (same log) catches R10. Only Z01, the
deliberately equivalent control, survives. F03 is now caught by a
failing `wings_test` with zero script errors (round 5's F03 was caught
only by the error grep). X07 and X08 (the two immediate re-attach paths)
are each caught alone.

**Final runs** (`report_unit_vr_round6.json` 161/161, zero script
errors; `report_flight_rig_round6.json` 7/7; `report_real_world_round6.json`
1/1; `report_perf_round6.json` median 91.7 µs at load 13.9-14.9, 74.2 µs
at load 8.9 earlier the same afternoon, budget 100; `birds_palette_run.log`
2/2; `sim_result_default.json` 14/14, 71.55 fps at load 8.3, pacing p95
14.40 / p99 17.44 ms; `sim_result_fplus.json` 7/7; the dev scene's four
`--demo` shots; `desktop_fallback.log` regenerated. All on the final
code: nothing under `scripts/vr/` changed after these runs).

**Verifier probes** (`tests/probes/vr`, 88 tests, `probes_round6.log`):
78 pass, including both round-5 verifiers' probes. The 10 others fail by
design: the 9 of §13 (`r2x_calibration` 2, `eng2_integration` 2, `r4eng`'s
corrupt-basis assertion 1, `exp_calibration` and `exp_palette` do not
parse, `r2x_flight_vignette` and `r3x_flight_rig` read the removed
`ComfortVignette.flow`) and `r1x_experience.test_second_wearer` (above).

## 15. Calibration redesign (2026-09-26): the lead's decision

**Why.** Over fix rounds 1-6, the automatic calibration kept producing
new edge cases. It combined an automatic neutral capture, a "wearer
re-check" whenever the headset came off and on, and cards answered by
poses. Each fix moved the problem, and the last open defect showed the
pattern. A landing flare still held on the perch answered its own
wearer-check card after one small movement or a one-frame tracking blip,
and was persisted as "flat". A calibration that silently re-captures from
poses the player did not intend is the wrong design. The lead decided:
wrist neutral and arm span are captured only in an explicit, prompted
step (first launch, and Recalibrate); nothing else ever re-captures; the
headset off/on or a long absence only raises a flag for the pause menu.

**What changed** (the design is in §2.3):
- `WingCalibrator`:
  - The capture now runs only on `request_capture()`, and it is the only
    capture. `NEUTRAL_HOLD` is 1.0 s (was 1.2 s).
  - `neutral_blocker()` gained plausibility gates, each with a hint:
    grips at most 2.3 m apart, each on its own side of the head (both on
    the wrong side reads as swapped controllers), within 40° of straight
    out, the same distance from their shoulders within 12 cm, the grip
    axis within 40° (`grip_axis_error`, `AXIS_LIVE`), and the head
    upright.
  - A capture resets the glide reach and fold elevation to their defaults
    and judges seating afresh.
  - Removed: the automatic capture (`auto_capture`,
    `auto_capture_allowed`, `auto_capture_pending/active`), the wearer
    re-check (`recapture_armed`, `arm_recapture`, `request_check`,
    `dismiss_check`, `check_capture`, `check_needs_break`,
    `wearer_verdict`, `same_wearer`, `recheck_plausible`, `RECHECK_*`,
    signals `rechecked` and `check_wanted`, `capture_span`), and the glide
    capture (`glide_blocker`, `GLIDE_HOLD`, the `kind` argument).
- `VRCalibration`:
  - `Flow` is now {IDLE, CAPTURE, DONE, FAILED}.
  - Added: `start(reason)`, `first_launch_pending`,
    `first_launch_prompt`, `flow_reason`, `game_in_play()`,
    `hint_text()`, `PROMPT`, `CANCEL_HINT`, `CANCEL_SHOW`,
    `LONG_ABSENCE`, `HINT_AFTER`, `HINT_LINGER`. `STEP_TIMEOUT` is 45 s.
  - Removed: `rearm`, `start_check`, `dismiss_check`,
    `auto_capture_safe`, `player_flying`, `force_auto_allowed`,
    `SETTLE_AFTER_FLIGHT`, `CHECK_TIMEOUT`, `GLIDE_TIMEOUT` and the glide
    step.
- `CalibrationPrompt`: `Step` is now {POSE, DONE, FAILED}. It gained a
  hint label, grows to fit its text, and scales its corner and ring
  stroke with the card's size. The card is fully opaque: at alpha 0.965,
  the tone-compensated text of the pause panel behind it showed through
  as readable words (`pause_card_vr.png`, first render). It now costs 3
  draw calls while shown.
- `VRManager` (additive): `recalibration_suggested`,
  `recalibration_suggested_changed(on)`, `suggest_recalibration(on)`.
  `presence_supported` stays and is informative.
- `scripts/ui/` (the one allowed, marked change):
  - `UIRoot.context()` gained `recalibrate_suggested`, read duck-typed
    from `VR.recalibration_suggested`.
  - The pause screen refreshes on the signal.
  - `PauseScreen` shows "New player? Recalibrate wings" (action
    `&"recalibrate"`) in its top row, with 24 px side padding so the row
    keeps its 60 px margins. The run-so-far line then moves to the tip's
    line.
  - The UI suite passes 144/144 after the change.
- Tests: `wearer_test` (12 tests) was deleted with the machinery, and
  `calibration_flow_test` (11 tests) added. `calibration_test` was
  adapted: its helpers ask for the capture; `test_the_calibrator_captures_only_when_asked`
  and `test_the_service_captures_only_in_its_step` replace the
  safe-moment gate tests; `test_swapped_controllers_and_odd_grips_are_never_captured`
  was added; the glide-capture and mode-less-player tests were removed.
  `span_refinement_test`, `calibration_load_test`, `wings_test`, the
  perf bench, the flight-rig suite, the shots and the plots now calibrate
  through the step. The V1 simulator harness switches the first-launch
  card off, because it measures the session and not the card.
- The simulator check (new): `tests/sim/vr_calibration_sim.*`,
  `run_calibration_sim.sh` and `sim_driver.py calibrate`. The driver
  spreads the real controllers with the simulator's keys, closed loop on
  the harness's own reading (the grip axis). Using the pose stream, it
  shows the capture came a full hold after the last motion. It then
  cancels with the B/Y key, drives `DeviceService/SetUserPresent`
  (`SetUserPresentRequest{bool userPresent = 2}`, decoded from
  `SIMULATOR.so`; runtime state, not persisted), and resets the controller
  poses (Space) and the selection at the end. NaN Euler angles from the
  stream are written as null.
- Simulator noise after the vendors 5.1.0 upgrade (the state notes):
  - `Property not found: 'xr/openxr/extensions/hand_tracking'` came from
    the plugin reading a core setting the project did not define. It was
    already gone by this round, because `openxr/extensions/hand_tracking=false`
    was added before it.
  - `Color space is not supported: 3` came from the plugin's new default
    starting colour space REC709 (3), which the simulator does not
    support. That round's `starting_color_space.pc=0` traded it for
    `WARNING: Recommended color space project setting is REC709`
    (openxr_fb_color_space_extension.cpp:266, `_on_state_ready`), which
    failed the harness verdicts. The fix is to disable the
    XR_FB_color_space extension on desktop:
    `openxr/extensions/meta/color_space.pc=false`, replacing the `.pc=0`
    line. Quest keeps the extension and REC709.
  - The fix was verified first in a private sandbox copy of
    `project.godot` under the simulator lock, and then applied: no colour
    space message and no property warning in any later run.

**Evidence** (final code):
- `unit/vr`: 158/158, zero script errors.
- `flight_rig`: 7/7. On flight's real rig a still spread without the step
  captures nothing; with it, the half fold reads 0.124-0.128 / 0.328-0.33
  for every capture height and tremor.
- `unit/ui`: 144/144.
- `run_calibration_sim.sh`: PASS 6/6 with Mobile and with Forward+.
- `vr_pause_suggestion`: 13/13 checks.
- The desktop card shots.
- V1 (`run_vr_sim.sh --tag=default`): VERDICT PASS, 14/14, at load 5.0.
  It reads 71.8 fps, p95 13.98 ms, and the VR scripts take 0.14 ms a frame
  (`sim_result_default.json`). An earlier rerun at load 17.5 failed only
  on fps (66.9), as round 6 recorded at load 15.3.
- The perf gate (`tests/sim/perf`) reads a 72.1 µs median at load 5.2,
  with 26.6 µs for the calibration (`report_perf_redesign.json`).
- Reports: `report_unit_vr_redesign.json`,
  `report_flight_rig_redesign.json` and
  `ui_suite_after_pause_button.log`.

**Verifier probes** (`tests/probes/vr`, not VR's files): 56 of 89 pass
on the final code (round 6: 78 of 88). Every new failure is a probe whose
setup relied on the automatic capture ("(setup) VR captured" never
happens without the step), or that calls the removed API. These use the
automatic capture (`auto_capture_allowed`, `force_auto_allowed`,
`auto_capture_safe`), the glide step or the wearer re-check (`Flow.CHECK`
/ `GLIDE`), and fail or do not parse by design: `exp_calibration`, `r1x_experience`,
`r1x_tuck_view`, `r2eng_calibration`, `r2x_calibration`,
`r2x_integration`, `r2x_wings`, `r3eng` (and `r3eng_bare_player`),
`r3x_flight_rig`, `r3x_wings`, `r4eng`, `r4x_menu_recalibration`,
`r4x_span_inflation`, `r5eng`, `r5x_recheck`, `r6eng`, `rv3x_wearer`
and `eng2_integration`. Round 6's by-design failures (`exp_palette`,
`r2x_flight_vignette`, the removed `palette_color` / `basis_to_array` /
`vec_to_array`) remain. The calibration scenarios of these probes are
covered by `calibration_flow_test` in the new design's terms
(`probes_redesign.log`).
