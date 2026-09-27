# UI area: menus, HUD, pointer and onboarding

Everything the player reads or clicks: VR-native world-space panels (a 2D
overlay on desktop), a laser pointer on either controller, the main, pause,
settings, how-to-fly, caught and run-summary screens, the in-flight HUD with
peripheral target and threat cues, the tier-up and apex celebrations, and
first-flight lessons that advance when the player does the gesture.

Scene: `scenes/ui/ui_root.tscn` (group `ui_root`, `PROCESS_MODE_ALWAYS`).

## What was built

| File | Role |
|---|---|
| `scripts/ui/ui_root.gd` (`UIRoot`) | Maps `Game` states to screens, keeps a screen stack for Back, owns the HUD, pointer, cues and onboarding; menu button / Escape; pauses on headset focus loss; decides "New best!" (`summary_best`); follows GameLoop's apex goal; gives the HUD its centre line, **where the player's body faces** (`body_yaw`, round 6: PlayerBird's torso yaw), and the directions it must never hide (`hud_protected_directions`: the flight path among them) |
| `scripts/ui/ui_panel.gd` (`UIPanel`) | One UI surface. In VR a SubViewport drawn on **curved bands** (sections of a cylinder centred on the eye; each with its own elevation and an optional home azimuth `"yaw"`) in rig space; on desktop a CanvasLayer. Its yaw follows the head lazily (menus) or a **yaw source** (the HUD: the torso; smoothed, dead zone, capped follow; round 6). A head re-seated between frames (> 0.5 tracker m) moves the eye point at once (round 6). Renders only when something changed; a render request stands until a draw has begun after it. Per-band visibility, opacity (a shader value) and placement (`set_band_offset`: a turn about the eye), none of which re-render; ray hits → pushed mouse events; a press that slides off the panel cancels (round 5); the stencil contract that keeps the player's hands in front (`mark_occluder`) |
| `scripts/ui/ui_pointer.gd` (`UIPointer`) | Laser beam and reticle: hover with 12 px hysteresis, trigger clicks with hysteresis, *fresh-pull* rule, hand hand-over, haptic ticks (at least 0.35 s apart) scaled by Settings > Haptics |
| `scripts/ui/ui_pointer_source.gd`, `ui_xr_pointer_source.gd` | Pointer input: scripted (tests, dev) or the rig's own **aim** `XRController3D` (flight's `LeftAim` / `RightAim`); a `UIAim_<hand>` is added (and freed again) only on a rig without one |
| `scripts/ui/ui_theme.gd` (`UITheme`) | Palette, type scale, Theme, chamfered "low-poly" StyleBoxes, cap-height, visual-angle and WCAG contrast maths |
| `scripts/ui/ui_tonemap.gd` (`UITonemap`) | Inverse-tonemap LUT so VR panels show the designed colours under the world's tonemapper |
| `scripts/ui/screens/*.gd` | `MainMenuScreen`, `PauseScreen` (food-chain ladder with worthwhile prey / too small / threats, apex goal, one tip per pause, hold-to-confirm Restart and Quit), `SettingsScreen`, `HowToScreen` (8 illustrated cards), `CaughtScreen`, `SummaryScreen` (victory or peak bird, time, score, best / "New best!", peak size, catches biggest first; Keep flying after a victory) |
| `scripts/ui/hud/hud.gd` (`HUD`) | Two VR bands: notices (the lesson card, the tier-up and apex celebrations) above the horizon **beside** the centre line, and the growth strip (or, at the top, the apex goal) low under it. The lesson card lives at a fixed home 9.7–42° right of the centre line, its words within 35° of a level gaze (round 6); a **celebration appears where the player looks** (`_toast_place`) and its clock holds while it is faded or out of view (`advance`). `make_way`: a notice turns see-through while the flight path, the target, a real threat or a cue is on it, and moves once to the other side if one stays; the strip fades |
| `scripts/ui/hud/hud_math.gd`, `indicator_filter.gd`, `hud_indicators.gd` | Cue maths (pure), flicker-free filtering with a latched turn side for birds behind you, cuts instead of sweeps, 3D chevrons in VR and 2D chevrons on desktop, drawn over every HUD plate; the threat cue steps out to an outer ring when both cues point the same way |
| `scripts/ui/onboarding.gd` (`Onboarding`), `ui_progress.gd` | Seven lessons driven by telemetry and events, counted only in play ("Tilt for speed" needs the wing-pitch input held *and* its effect); only lessons **done** are stored as learned (round 5), in `user://ui_progress.cfg` (with a fallback best score). The catch lesson (majors round) asks GameLoop for its **lesson prey** (`request_lesson_prey`), names them ("Catch a Moth" / "Fly right into one"), and every 30 s without a catch asks again (the swarm comes back ahead, nearer) and says more; it lets them go when it ends |
| `scripts/ui/game_bridge.gd` (`GameBridge`) | Duck-typed GameLoop calls with fallbacks (start, restart, quit, continue after victory, the catch lesson's prey), the run-stats provider |
| `scripts/ui/widgets/*` | `FacetBackground`, `SegmentBar`, `ChoiceToggle`, `FacetBar`, `BirdIcon` (a from-below silhouette per species; relations prey / too small / threat / you / neutral), `HoldButton`, `Emblem`, `GestureCard`, `GestureArt` (all drawn in code, flat-shaded) |
| `scripts/ui/dev/*` | `UIMockPlayer`, `UIMockGameLoop` (fake runs, stats, apex goal, victory, `continue_after_victory`), `UIStandInBird` (low-poly stand-in NPC with a `model.highlight`), `UIBackdrop` (stand-in world, Filmic white 6 like the real world) |
| `tests/shots/ui_flight_record.gd` | Flies the real FlightModel once and records the flights the suites replay (`tests/unit/ui/ui_flight_runs.json`, round 5) |
| `tests/shots/ui_lesson_real.gd` (majors round) | Flies "Tilt for speed" and "Catch prey" in the **real game** through the real chain (the integration kit: BotPoseSource arms, WingInput, PlayerBird, GameLoop's lesson prey) and writes `artifacts/ui/lesson_real*.json`; `ui_wrist_pilot.gd` holds the wing-pitch command neutral or tilted |
| `tests/shots/ui_game_record.gd` | Boots the **real game** (scenes/main.tscn through the integration kit), plays the tutorial and 54 s of manoeuvres with the integration bot, and records what the view saw: rig heading, velocity, facing, torso and head, world_scale, GameLoop's target and threat (`tests/unit/ui/ui_game_flights.json`, round 6); the suites replay it through the mock player (`UITestKit.apply_game_row`) |
| `scenes/ui/fonts/Nunito-Variable.ttf` | Nunito (SIL OFL 1.1, `OFL.txt` alongside), weights 700–1000 |

## Design decisions

- **Two surfaces, never more.** All menu screens share one panel (a stack
  gives Back); the HUD has its own. At most two SubViewports ever exist;
  in practice at most one renders in any frame (U7).
- **The HUD stays out of the hunting gaze** (fix round 2). A bird hunts by
  looking from level to about 30° down: the ground ahead, prey below,
  perches. Nothing of the HUD sits there. In VR the HUD texture is shown as
  two bands of the same SubViewport (`UIPanel.bands`), each its own
  eye-centred cylinder section tilted to face the eye:
  - **notices** above the horizon, +8..+20°, **beside the centre line**
    (the lesson card 9.7–42° right of it; celebrations where the player
    looks, below);
  - **growth strip** low, −37..−43°, 30° wide, under the centre line. It
    is read with a deliberate glance down; in normal flight it is in the
    lower periphery.

  Measured (`ui_hud_test`): with the lesson card, the strip, or a tier-up
  toast up, **0 %** of the 10° cone round the gaze is covered anywhere from
  +2.5° to −30°; the strip covers the gaze centre only at −37.5..−42.5°;
  a gaze held at −26° is covered in **0 of 120** frames.
- **The HUD's centre line is where the body faces** (fix round 6). Round 4
  used the head's yaw when the HUD appeared (a Resume click left the card
  across the flight path); round 5 used the flight path's heading. In the
  real game (the round-6 verifier, through the integration bot) the flight
  path is not where the player faces: the valley's 2.6 m/s breeze crabs a
  slow sparrow's path 15–50° off, and a zoom over the top after a dive
  reverses it (and the bird's facing) while the view turns round at its
  comfort rate. The round-5 HUD swung 157° round the player and the lesson
  card was in view of a resting gaze 39 % of the tutorial.
  - `UIRoot.body_yaw()`: PlayerBird's telemetry `body_yaw`, WingInput's
    torso yaw in tracking space (the XROrigin3D's own frame: the
    perpendicular to the line between the hands, the head's yaw when the
    hands say little). A head at rest looks along it. It does not move
    when the rig yaws in a flown turn, when the path crabs, or over the
    top of a loop; it moves when the player turns in their room (body
    steer). Without that key (another player bird): the rig-space yaw of
    `Bird.get_forward()`, held while steeper than 60°. Without a player
    bird (a dev scene): the head past a 55° dead zone, as before.
  - Followed calmly: smoothed (τ 0.2 s: a flap's 1–2 Hz jitter in the
    torso estimate cut to a third), a 6° dead zone, then eased (τ 0.2 s,
    at most 90°/s; the menu's cap is 110) until it is within 0.5° of both
    the smoothed and the raw torso, and it stops. A 30° torso turn: no
    jump in a frame, within 1° after 1.03 s, peak 55.8°/s, 18.8°/s in the
    last 5°, settles 0.49° off; wobbles of ±4° and a 5° lean held 3 s move
    nothing, before and after a follow; 8° is followed.
  - **Head turns never move the HUD** (18°, 45°, 70°, 130°, 170°: 0.000 m).
    Shown (Play, Resume, respawn, Keep flying) and after a recenter it is
    placed where the torso faces at once (a respawn with the torso turned
    90° left while caught: 0.00° off in its first frame).
  - **The flight path is kept clear, not followed**: it stays one of the
    directions the notices make way for (fade while it crosses, move if it
    stays).
  - **Under the real game's flight** (recorded by `ui_game_record.gd`,
    replayed with the rig yawing under a PlayerBird-like parent, GameLoop's
    real targets and threats as stand-in birds, the head at rest along the
    torso; also with the player standing 60° left in their room): the HUD
    0.01° off where the body faces, 0° of travel; the lesson card read in
    view **99.0 %** of the tutorial (1 fade, 0 moves) and **86.5 %** of 54 s
    of hard manoeuvres (12 fades, **0 moves**; round 6: 9 fades, 3 moves,
    87.1 %), every word within 34.9° of the resting gaze, the path behind
    the readable card at most 0.056 s at a time. The verifier's own mock
    replay of the loop over the top: 0° of HUD travel, card in view 100 %.
  - **In the live game** (majors round; the round-7 verifier's live probe
    on six bot seeds, its three and three fresh ones: 6 of 6 pass): **0
    moves** in every 35 s tutorial (round 6: 2, 4 and 1 on its seeds),
    read in view **97.9-98.8 %** (round 6: 79.5-94.1 %), **1-2 fades**
    (round 6: 3-6): the flight path, or a real threat or its cue actually
    on the card (`UIRoot.notice_causes()` and the verifier's own cause test
    now agree).
- **The lesson card lives beside the centre line, and stays put** (fix
  round 4; pulled in round 6). The view never pitches with the bird, so
  every climb, zoom and flap cycle sweeps the flight path up and down
  (−46..+77° in the tutorial's flap-and-glide on the real FlightModel,
  −20..+52° on the flight area's B1 course).
  - **A fixed home beside it**: the notice band turned 25.9° right about
    the eye (band yaw `HUD.NOTICE_YAW`): the card spans 9.7–42° right of
    the centre line, its text 10.7–32.2° (a 548 px column, the title at
    the body size set apart by weight, hints shortened to fit: "Sweep down
    hard", "Arms out, hold still", "Tip one arm down", "Catch prey" /
    "Chase one, fly at it"). Every word of every lesson, at home and at the
    mirror, is within **34.9°** of a level gaze along the centre line
    (round 5: 41°, the round-6 verifier's minor), 10° inside the 45° a
    Quest Pro shows sharply. The text hugs the inner edge on either side
    (right-aligned on the mirror side) and changes sides mid-move, when the
    card is see-through, not at the start of a move.
  - **Why the edge at 9.7°**: prey jinking ±8° round the centre line at the
    notices' height (the round-4 verifier's fluttering moth) must pass
    outside the 1.5° fade margin, and the words must end within 35°. The
    first round-6 placement, edge 8° with a wider text column, faded the
    card a third of the time in that case (the r4x probe: readable 67 %);
    a crabbing path also crosses a nearer card more often.
  - **Calm by construction** with the path along the centre line
    (tutorial, B1 sparrow / pigeon / eagle, and a 30° torso turn on each):
    0 moves, the path never behind the card, read in view 100 % (97.8 %
    for the pigeon's torso turn, one fade while the HUD catches up).
  - **Fade while something crosses** (the lead's rule, majors round): the
    flight path, the target, a real threat or a cue chevron within 1.5° of
    a plate: see-through (15 %) below 20 % within 0.125 s. **Hysteresis**:
    the crossing lasts until everything is 1.0° further off
    (`FADE_HYST_DEG`, out beyond 2.5°) and has been for 0.12 s
    (`FADE_CLEAR_S`, the fade-out's own length: a shorter gap is no gap);
    the card is then back over 0.28 s (`NOTICE_IN_S`), within 0.4 s of the
    thing leaving, as before. A crossing, however often it comes back,
    never moves the card.
  - **Move only when it stays**: something actually on the plates for more
    than 1 s of one crossing: once, to the mirror placement left of the
    centre line, if clear; eased over 0.9 s (peak 103°/s, ≤ 110), at most
    once every 4 s. (Rounds 4-6 also moved it after 3 crossings in 8 s,
    counted without any debounce: in the live game that moved the lesson
    card up to 4 times in a 35 s tutorial, and a single jittery 0.4 s pass
    counted as 2-3 crossings; the round-7 verifier's probes.)
- **Celebrations appear where the player looks** (fix round 5). A tier-up
  comes right after a catch, and the player may be looking at the next bird;
  round 4 put every celebration at the card's home, and a player looking 25°
  or 40° left saw 0 s of it.
  - `HUD._toast_place`: as near the gaze as it can be while beside the
    centre line (either side, at home's distance from it or further out,
    never nearer), clear of what matters (the flight path among it) by 3°. In order: clear and in
    view (its text line within 45° of the gaze), in view but not clear (it
    waits, faded), clear but out of view, anything. Home's side unless the
    other is 5° nearer (`TOAST_HOME_BIAS_DEG`): looking ahead it shows
    where the lesson card lives, not by a hair's choice. A band
    offset is a turn about the vertical, so a candidate's distance from the
    gaze is exact arithmetic; the candidates are sorted natively and
    clearance is checked in that order (0.40 ms for the whole frame a
    celebration appears, text and fit included).
  - Once placed it **stays** (rig space: it moves only with the torso). Its clock **holds while it cannot be read**: faded, or its
    text more than 45° from the gaze (the player looked away), for at most
    3 s in all, so it is never used up unseen and cannot hang on.
  - A celebration **swaps its text in place only over one being read**;
    over one that is waiting out of view it is placed afresh where the
    player now looks.
  - **Narrower** (26° of text, was 35°): title 90 px (was 100), lines at
    most 680 px; "what dropped off the menu" says "Ignore: Wren–Sparrow"
    (the pause screen's word; was "Too small now: …", 859 px), the apex
    line "3 more to win". At home its words end 40.8° from a level gaze
    along the centre line (46° in round 4); it is placed at home only when
    the player looks ahead.
  - Measured: gaze 0°, 2.5° left, 25°/40°/60°/90°/150° left and right,
    40° left and 15° down, 20° right and 25° up, 5° down along the path:
    **read in view 2.69 s of 3.21 s** each (pop-in and fade-out take the
    rest), 0 frames over the flight path, no move, never nearer the centre
    line than 10.1°. Looking 100° away for 2 s after it appears: held 2.01 s,
    lasted 5.22 s, read 2.69 s. Looking 25° down along the path (where no
    place above the hunting gaze is in view): it waits (1.76 s) and is read
    2.58 s once the player looks up. Never looked at: ends after 3 s of
    waiting (6.22 s).
- **Cues draw over the HUD** (fix round 4). The chevrons render after the
  HUD panel (render priority 11 > 9; on desktop CanvasLayer 6 > 5), so a
  cue on a notice plate is never hidden (pixel check `vr_cue_over_card`).
  The notices also treat the cues as something that matters (except while
  the head points at them: the cue ring turns with the head), each where
  it is drawn from the eye as it is now (majors round:
  `HudIndicators.cue_direction`; the chevron meshes' last positions were a
  frame stale on a flying rig, ~3° off, and made phantom fades and moves).
- **The UI tells the loop the way the loop works.** "Prey" on the pause
  ladder and in the tier-up toast is what is *worth chasing*
  (`SizeRules.is_worthwhile`). The lines read "Hunt: Pigeon–Gull", "Flee:
  Eagle", "Ignore: Moth–Starling"; a tier-up names what just dropped off
  the menu ("Ignore: Starling").
- **The top of the ladder has a goal.** GameLoop's apex goal (N worthwhile
  catches as the eagle; GameLoop's `APEX_CATCHES` is 3, the UI's mock and
  screenshots use 5; the UI always shows GameLoop's number): the eagle toast
  says "Catch 5 big birds to win", the strip "2 of 5 to win", each apex
  catch "2 of 5!" / "3 more to win", the pause screen "Apex hunt: 2 of 5". A
  victory's summary says "Victory! You rule the sky" and offers **Keep
  flying** before Fly again and Main menu.
- **Destructive actions need a hold.** Restart run and Quit to menu act only
  after a 0.8 s hold, with an ink bar filling along the button; a short
  pull relabels them "Hold to restart" / "Hold to quit" for 2.5 s.
- **Panels curve round the eye.** Each band is a section of a vertical
  cylinder of radius = its distance (1.5 m × `world_scale`) with the eye on
  its axis, so every column of text is as far and as square-on as the
  centre column. The menu spans 51.9° × 33.4° (26.2 px/°).
- **Panels in rig space, never head-locked.** A menu opens straight ahead
  (4° below eye level), stays put for head turns inside ±32°, then eases
  back (τ 0.35 s, ≤ 110°/s, under 25°/s in the last 5°: measured 14.1) and
  stops again once recentred. The HUD follows the flight direction (above).
  Both move with the flying rig, snap after `VR.recentered`, and anchor in
  tracker metres, so a growing player moves nothing (0.000° drift).
- **Scale-free sizing.** Panel size and distance both scale with
  `world_scale`: the same visual angle for a wren and an eagle (U6).
- **Legibility where the text sits.** 1 panel px = 1 mm at 1.5 m. Body text
  and buttons are 60 px Nunito (cap 42.5 px, 1.62° at the centre). Every
  text run is measured at its real position on the real curved band, from
  the real camera, against the brief's literal 1.5° (round 5: never
  UITheme's own constant): smallest **1.535°** on menus, **1.614°** on the
  HUD, 1.6136–1.6194° wherever the notices are placed.
- **Palette:** deep dusk-blue panels, cream text, sunflower accent, teal
  (worth chasing), coral (danger), greyed teal (too small), chamfered
  corners, faceted background. Every text colour on every surface is
  ≥ 4.5:1 (worst 5.31:1, checked against the literal 4.5).
- **Desktop HUD keeps off the window edges** (fix round 5): the lesson card
  and the strip keep 19.2 px (32 texture px) from the top and bottom (the
  card was flush with the top).
- **Summary stats never run together.** Thin rules between the stat
  columns; on a new record the Score's caption becomes "New best!" and the
  Best column is dropped.
- **Pointer: a click needs a fresh pull.** Aim pose; one active hand;
  press ≥ 0.65, release ≤ 0.35; a trigger even half squeezed when a screen
  appears must be let go first; pulls in a screen's first 0.2 s are
  ignored.
- **Pointer: sliding off cancels** (fix round 5). Pulling on Play, sliding
  the beam into the sky and letting go started a run: leaving the panel
  released the held press at its last pixel, still on the button. It now
  moves the pointer off first and releases out there: no click, no run,
  Play not left held down, no error (the release off every panel was the
  path the engineering verifier found untested).
- **Pointer: no buzz at a button's edge** (fix round 4). Hover has 12 px of
  hysteresis (never holding a neighbour) and hover ticks are at least
  0.35 s apart: at 0.05–0.2° of tremor on a button's edge, 0–1.3 hover
  changes and 0–1.3 ticks a second (the verifier measured 13.7–15 and
  6.7–7.7 before).
- **Pointer: the hover highlight is visible.** An ordinary button hovered is
  1.36:1 lighter with a 6 px sunflower ring (6.76:1 against its normal
  fill) that the normal style lacks; the primary (sunflower) button gets a
  6 px cream ring. Pinned headless (round 5), not only in screenshots.
- **Pointer: the rig's own aim controllers** (fix round 4): the UI reads
  `LeftAim` / `RightAim` and adds `UIAim_<hand>` only on a rig without one.
- **Prey and threat cues never draw on top of each other** (fix round 3):
  when both point within 22° of each other the threat chevron steps out to
  an outer ring (≥ 5.7° apart, each pointing exactly its own way).
- **Cues: steady, cut instead of sweeping, and calm overhead.** Chevrons on
  a 24° ring, shown outside the central 15–21° cone; a latched turn side
  for birds behind you (true mid-plane angle); a side change elsewhere is a
  cut: hidden, moved, faded back in.
- **Every change reaches the texture, and only changes render.** A panel
  re-renders exactly in frames where something changed; a request stands
  until a draw has begun after it (skipped draws, late changes). A
  celebration needs no keep-alive (round 5: UIRoot used to keep the HUD
  rendering for its whole 3.3 s): its own redraws book each frame it
  animates, and while its clock is held nothing changes and nothing
  renders. A hidden panel books no render at all, and a keep-alive ends
  (both pinned headless in round 5).
- **Settings status lines fit** (fix round 3), clip rather than widen their
  row, and clear after 4 s.
- **"Tilt for speed" needs the tilt** (fix round 4): `pitch_input` (PlayerBird's
  telemetry: WingState.pitch) held past 0.15 for 1 s while gliding, and its
  effect in the same window (+0.5 m/s or 5 %, or a balloon). On the real
  FlightModel (recorded; re-recorded this round, identical): neutral-wrist
  flap-and-glide for 60 s, sparrow and eagle: never (progress 0); a ±0.35
  or ±0.6 tilt: 0.99–2.26 s. **In the real game through the real chain**
  (majors round, `ui_lesson_real.gd`: the bot's arms with twist noise,
  WingInput, PlayerBird in the valley's wind): 60 s each of neutral-wrist
  flap 2 + glide 2, 1 + 3 and 3 + 3 s, and 2 + 2 with a novice's 4° of
  twist noise: **never** (progress 0; the largest pitch input while
  gliding 0.08, under the 0.15 needed); a held tilt of −0.6 / +0.6:
  **1.17 / 1.19-1.24 s** (novice 1.32-1.33 / 1.26-1.33 s; two runs),
  −0.35: 1.21 s. A gentle +0.35
  (leading edges up) did not balloon the sparrow enough within 8 s (the
  novice's twitchier +0.35 did, in 4.5 s): the card's hint is the
  leading-edge-down gesture.
- **Lessons are learned by doing** (fix round 5). A lesson nobody did moves
  on after its 45 s timeout (play is never blocked), but round 4 stored it
  as learned, and an idle player's whole tutorial as complete for good.
  Now only lessons done are stored; the tutorial counts as done once every
  lesson was done (or it was skipped); the missed ones come back next
  session (not at every resume or respawn of this one) and the learned ones
  are never taught again. The thresholds are pinned both ways: arms half
  out (0.5, 0.7) for 5 s is not "Spread", two strong beats are not "Flap to
  climb".
- **The catch lesson brings its prey** (majors round, the lead's
  direction: no 300 s dead end). When it begins, UIRoot asks GameLoop for
  its lesson prey (`request_lesson_prey`: a slow, unaware moth swarm ahead
  of the player's flight, kept ahead until released) before the card first
  shows, so the card names them: "Catch a Moth" / "Fly right into one"
  (GameLoop rings every worthwhile bird; "It glows: fly into it" if their
  model says it glows). Every 30 s of play without a catch
  (`Onboarding.CATCH_HELP_S`) it asks again (the swarm is put ahead of the
  player again, nearer) and says more: "Follow the arrow", then "Fly
  straight into it". Not while the player is closing on a lesson bird
  (within 60 of its wingspans, gaining 4 a second: `UIRoot._lesson_help_ok`),
  which would take the moth from under the beak. The prey are released
  when the lesson ends (a catch, its timeout, a skip, Replay tutorial) and
  when a run ends; a new run with the lesson still up asks again.
  - **In the real game** (`ui_lesson_real.gd`, bot seeds 11, 33, 99, two
    runs: a fresh sparrow each time, the sky differing run to run): a
    competent player (steers at GameLoop's target cue) is done in **12.6-
    91.6 s** (12.6, 37.6, 34.7; 81.2, 20.7, 91.6), under the lead's 2
    minutes; a struggling one (a novice's arms, looks for the cue's bird
    only every 1.5 s) in **13.4-87.4 s** (27.4, 42.8, 87.4; 31.8, 13.4,
    45.2), the help coming at 30 and 60 s when needed. A **passive** player
    that never steers at prey is not reached: the help's swarm is placed at
    least 20 m ahead (GameLoop/AI), passes 8-13 m off an orbiting bird, and
    the lesson ends by its timeout at 300 s ("Let's move on"; offered again
    next session) after 9 requests, in all 6 runs. Reported to the game
    loop (see Known limits). 0 errors, 0 warnings in the game.
  - **The words agree with the food chain**: a species is named only while
    the pause screen lists it under "Hunt" at the player's size; without
    lesson prey the lesson says "Catch prey" / "Chase a ringed bird" (no
    species some size is told to ignore).
- **A pause keeps a celebration** (majors round, the round-7 verifier's
  probe): its clock waits while the HUD is hidden (no render meanwhile),
  and it plays out after Resume; being caught, a menu or the run's end
  still ends it.
- **Hands stay in front** (stencil 64: `UIPanel.mark_occluder`, and the VR
  area's wing shader writes 64 too), **colour in VR** (inverse-tonemap LUT),
  **pausing** (menu button, Escape, headset focus loss).
- **A freed bird never stops the cues** (fix round 4).
- **No dependency on other areas' in-progress code.** Bird highlights are
  duck-typed (`model.highlight`); the dev scene and screenshots use
  `UIStandInBird`. Round 5: the suites no longer call flight's internals
  (FlightModel, WingState, FlightEnv, FlightParams, FlightTuning); the
  tutorial and tilt flights are recorded once by
  `tests/shots/ui_flight_record.gd` into `tests/unit/ui/ui_flight_runs.json`
  and replayed, as the B1 course already was.

## Perfection criteria and how each is verified

Headless suite (majors round): 8 files, **193 tests, 5,783 assertions,
56.7 s** at load 5-8, all passing, 0 script errors
(`artifacts/ui/verify/majors/suite.log`), inside the architecture's 60 s
per area (62.5 s at load 12-28: the real-time parts below). Every HUD clock (the cues, the notices making
way, the celebration, the panels' follow) is driven with fixed synthetic
frames through public hooks (`HudIndicators.step`, `HUD.make_way`,
`HUD.advance`, `UIPanel.follow`, `SettingsScreen.advance`); what must stay
real time (the pointer's grace window, holds and haptic tick gaps, the menu
debounce, per-frame render counts) does; the end-to-end lesson test runs
the live path on a clock 4x fast (`Engine.time_scale`).

```bash
tools/gd.sh ui --headless res://tests/runner.tscn -- --suite=unit/ui/ui_
```

Report: `artifacts/tests/report_unit_ui_ui_.json` (per-test metrics).

| # | Criterion | Verified by | Key numbers |
|---|---|---|---|
| U1 | Every screen polished and on-style; glyph ≥ 1.5°; contrast ≥ 4.5:1 | **`ui_legibility_test.gd`** (17 tests): every visible Label and Button on all 6 screens (623 text runs), measured at its true position from the real camera, in worst-case contexts; the HUD over every lesson, every tier-up, the eagle and apex toasts; every celebration line ≤ 680 px at its drawn size; contrast of every palette pair; text keeps its angle wherever the notices move; the bars are the brief's literals (1.5°, 4.5:1). Round 6: **every lesson's title and hint fits the card's 548 px text column and the card never grows** (`test_hud_lessons_fit_the_viewport`). **Visuals:** `tests/shots/ui_shots.gd` (0 failures), all PNGs viewed; the pause shots now show a plausible run (5:12, 7 caught). | smallest glyph **1.535°** (menus), **1.614°** (HUD); body text anywhere ≥ 1.511°; contrast ≥ **5.31:1** |
| U2 | Synthetic ray → hover → trigger → pressed → state change | **`ui_pointer_test.gd`** (34 tests): Play starts a run, pause/resume, hold-to-confirm Restart and Quit, settings written to disk, the fresh-pull rule, the real XR input path headless, handedness, haptics, press-slide-off is no click. Round 6: **the hover ring stands out from the panel round the button by WCAG's 3:1 non-text bar** (9.36:1 ordinary, 13.15:1 Play) and Play's hover thresholds tightened (fill > 1.05, ring > 1.35; measured 1.09, 1.41). | tremor 0–1.3 ticks/s; sweep of 4 buttons: 1 tick |
| U3 | Menu reachable from every state; pause freezes gameplay; CAUGHT/ENDED screens | **`ui_flow_test.gd`** (40 tests): every state, pause freezing a pausable ticker and the run clock while the pointer still works, the caught and summary screens on their events, apex goal, victory and Keep flying, freed birds, focus loss. Round 6: **a tie is not "New best!"** (against UI's file and GameLoop's stats) and **the fallback best score is written to disk** (a new session reads it; a tie or a lower score changes nothing). The round-6 verifier's real-game probe: 4 of 4 flow checks pass on the real game (hawk strike, caught screen, pause while caught, settings saved, truthful summary). | |
| U4 | Cue maths, fades by distance and threat, no flicker | **`ui_hud_test.gd`** (majors round: 50 tests; `test_the_notices_see_the_cues_where_they_are_drawn_now` (0.19° against the meshes' 3.1°); `test_a_jittery_crossing_of_the_margin_is_one_fade`: the round-7 verifier's case, a 0.4 s pass on the margin with 0-0.6° of jitter is one crossing, one fade, no move, and 1.6 s on it is one move; the repeated-crossings case now asserts 10 crossings of 0.3 s every 2 s: a fade each, **no move**; the margins test pins the hysteresis; the real-game replay 0 moves). `ui_flow_test.test_a_pause_keeps_a_celebration_for_after_resume`. Cue maths and the no-flicker filter, cues apart, cues at every world_scale, the hunting gaze kept clear, cues over the HUD, celebrations where the player looks (15 gazes: read in view 2.69 s of 3.21 s). Round 6:<br>• **the real game's flight** (`test_notices_under_the_real_games_flight`: the tutorial and 54 s of manoeuvres recorded from scenes/main.tscn, the rig yawing under a PlayerBird-like parent, GameLoop's targets and threats, the player also standing 60° left in the room): HUD 0.01° off where the body faces, 0° travel; card read in view **99.1 %** / **87.1 %** (bars 95 % / 85 %), fades 1 / 9 (bars: < 3 in the tutorial, ≤ 15 a minute), moves 0 / 3 (≤ 1; ≤ 1 per 15 s), words ≤ 34.9° from the resting gaze, the path behind the readable card ≤ 0.056 s; both celebrations read in view ≥ 2.61 s;<br>• **the card pulled in** (`test_notices_live_beside_the_centre_line`): edge 9.66°, every word of every lesson at home and at the mirror within 34.9° of a level gaze and ≥ 10.7° from the centre line, the centre line from −60 to +85° keeps 8° of sky, **prey jinking ±8° at +5..+20° keeps 1.5° clear**;<br>• **the card after a celebration** is not shown where the celebration was (alpha 0 that frame) and comes back at home or the mirror, laid out for that side;<br>• **a crossing at a lesson change counts once** (a zero-time `make_way` no longer counts it twice);<br>• **the fade and reading margins are literal**: a bird 1.0° beyond the card's inner or bottom edge makes it fade, 2.2° does not; the head 4° off the card is reading it, 8° is not;<br>• the centre line whatever the head did (10 entries: text 10.7–32.2° beside the path, 0 fades, 0 moves, read in view 100 %); calm under the tutorial and B1 flights with and without a 30° torso turn: 0 moves. | real game: HUD 0° travel, card in view 99.1 % / 87.1 % |
| U5 | Onboarding advances on telemetry, never blocks, persists | **`ui_onboarding_test.gd`** (majors round: 20 tests; `test_the_catch_lesson_helps_a_struggling_player`: help every 30 s, levels in order, the words change at the first two, none while the player closes on a lesson bird, none after the lesson, the prey released once however it ends; `test_the_catch_lesson_uses_the_games_lesson_prey`: through UIRoot and GameBridge with the mock GameLoop's lesson-prey API: asked before the card shows and named on it, asked again at help, released at a run's end and asked again by the next run, released by the catch; without the API the ring's words; `test_help_waits_while_the_player_closes_on_a_lesson_bird`; `test_catch_lesson_never_names_a_bird_the_hud_says_to_ignore` over every species, size and help level. **Real chain:** `tests/shots/ui_lesson_real.gd` (see "Tilt for speed" and the catch lesson above). Round 6: lessons advance on telemetry and events, time out instead of stalling, never pause or touch controls, persist, skip, count only in play; a timed-out lesson is not stored as learned; missed lessons come back next session; half-spread arms and one or two beats are not lessons; "Tilt for speed" on the recorded FlightModel flights. Round 6: **Replay tutorial in the same session** brings the lessons back at once (after they ran to their end; a plain resume does not); **a tilt with a 0.3 m/s drift, or a nose-up tilt rising only 0.6 m/s, is not the lesson** (the effect bars 0.5 m/s / 5 % and the 1 m/s balloon are pinned). The round-6 verifier's real game: spread, flap, glide, speed, turn and dive all done by doing. | neutral wrists: 0 completions |
| U6 | Constant apparent size across `world_scale` 0.15–1.3 | **`ui_scale_test.gd`** (10 tests): menu 51.95° × 33.40° at every scale, 0.000° drift while growing, pointer at every scale, recentre snaps, the menu's ease-out (14.1°/s in its last 5°). Round 6: **the HUD follows where the body faces** (head turns: 0.000 m; the path crabbing 40°, over the top of a loop, a perched bird turned 120°: 0.000°; ±4° torso wobbles and a 5° lean: nothing, before and after a follow; 8°: followed; a 30° torso turn: no jump, within 1° after 1.03 s, peak 55.8°/s, 18.8°/s in the last 5°, settles 0.49° off; a 150° turn in the room at ≤ 90°/s); **without a torso estimate** it uses where the bird faces, world → rig with the rig yawed 70° and through a flown 90° turn (0.000° drift), held over the top; **re-shown where the torso now faces** (0.00° in its first frame after a respawn turned 90°); **a re-seated head moves the eye point at once** (the strip at −40.23° one frame after 1.62 m → 0.23 m at world_scale 0.141). | 51.95° × 33.40°; growth drift 0.000° |
| U7 | SubViewports update only when visible or dirty; ≤ 2 active | **`ui_perf_test.gd`** (18 tests): idle 0 renders, exactly 2 viewports, at most 1 renders at once, moves and fades cost nothing, a hidden panel books no render, a keep-alive ends; **the UI's script cost per frame** (the `_process` / `_physics_process` callbacks of UIRoot, the HUD, the cues, both panels, the pointer and the lessons; Control layout, `_draw` and the GPU's SubViewport render are not in it) in flight with the lesson card and both cues: **68 µs mean, 295 µs p99** on the M1 Pro (bounds 400 / 1500 µs); in a menu with the pointer 25 µs; the frame a celebration appears 0.41 ms. **From pixels** (`ui_shots.gd`): idle 1 distinct probe value in 20 frames, keep-alive 20, after hover 1, idle HUD 1. | idle 0 renders; max 1 at once; UI scripts 68 µs/frame |

### Recorded flights

The notice and onboarding tests replay flights rather than flying them:

- `tests/unit/ui/ui_b1_flightpath.json`: the flight area's B1 bot course
  (`artifacts/flight/b1_course_*.csv`) resampled to 20 Hz by
  `artifacts/ui/tools/b1_flightpath.py`;
- `tests/unit/ui/ui_flight_runs.json` (round 5): the tutorial's
  flap-and-glide (2+2 for 60 s, 3+3 for 36 s, [t, flight-path angle, speed]
  at 20 Hz) and 17 "Tilt for speed" flights (sparrow and eagle, neutral
  wrists 60 s at 24 Hz, tilts ±0.35/±0.6 and flap-then-tilt at 72 Hz; the
  telemetry PlayerBird reports), flown on the real FlightModel by
  `tools/gd.sh ui --headless res://tests/shots/ui_flight_record.tscn`.
  Rerun it after a flight-model change. (Round 6: the 2+2 replay is cut to
  30 s; the real-game recording covers long flight.)
- `tests/unit/ui/ui_game_flights.json` (round 6): the **real game**, as
  its view saw it: "tutorial" (34.8 s: the lessons flown with their
  gestures as the round-6 verifier did, then cruising with the catch
  lesson up) and "manoeuvres" (53.7 s straight on: an orbit cruise, hard
  banked turns both ways, a climb, a dive and a zoom, a chase that catches
  a moth). 36 Hz rows: rig heading, velocity and facing (world), torso and
  head (rig frame), world_scale, the lesson, GameLoop's target and threat
  (id, position from the eye, level). The sparrow's path crabs up to 60°
  off the torso and reverses over the top of two zooms (82°, 87°). Recorded
  headless in 90 s by

  ```bash
  tools/gd.sh ui_rec --headless --fixed-fps 72 res://tests/shots/ui_game_record.tscn
  ```

  (scenes/main.tscn through the integration area's test kit; the game
  logged 0 errors). It also watches the real UI meanwhile and writes each
  time the card made way or moved, and for what (`live_ui`). The suites
  replay it through the mock player and a
  rig parented like PlayerBird's (`UITestKit.apply_game_row`), so they
  still run no other area's code. Rerun after a change to flight, the
  world's wind or the integration bot.

### Mutation check

**Majors round** (`artifacts/ui/mutations/mutate_majors.py`, run on a
private rsync copy of the project through that copy's own `tools/gd.sh`;
results `summary_majors.json`, logs `majors_*.log`, `majors_run.log`):
**21 of 21 caught** on the final code: the notices' spatial hysteresis
and crossing hold removed (N1, N2), the "3 crossings" move put back (N3),
a move in the hold (N4), gap time counted as staying (N5), round 6's slow
return (N6), a pause cancelling the celebration or its clock running while
hidden (C1, C2), no help, help ignoring a closing player, never seeing
one, help stopping after 4 (L1-L4), the prey never released, asked twice,
kept after a run's end (L5, L6, L12), a species named whatever its worth
(L7), the card not told or told after it shows (L8, L9), a glow claimed
for every bird (L10), a hint too wide for the column (L11), and the cues
seen at the meshes' last places (P1). Two survived the first pass (N2, N5:
the margins test drove the hold with the constant itself, and no case had
a gap inside a crossing); the tests now use literal times and a gap case
(`summary_majors_first_pass.json`).

**Round 6** (`artifacts/ui/mutations/mutate_r6.py`, private copy
`.sandboxes/ui_mut6`, results `summary_r6.json`, logs `r6_*.log`,
`r6_run.log`, `r6_rerun.log`): **30 of 30 caught** on the final code, each
by the test written for it:

- the major put back: the HUD on the flight path's heading (F1, F1a:
  caught by the real-game replay and by the torso tests), the torso
  ignored (F1b), the facing not held when steep (F1c), no world → rig
  conversion (F1d: the engineering verifier's V01), no smoothing (F1e), a
  fast swing (F1f), a 3° or a 9° dead zone (F1g, F1h: V03), a follow that
  never stops (F1i: V12), a follow that rests short of the torso (F1j),
  not re-placed when shown (F1k: V10), a stale eye point after a
  re-seated head (F1l);
- the card at the edge of the view: round 5's far placement (L1), the
  card's edge at 2° or at 8° (L1e, L1e2: prey jinking ±8° fades it),
  round 6's first wide text column (L1h), left-aligned text on the mirror
  side (L1b), the text flipping sides at the start of a move (L1c), the
  card shown where the celebration was (L1d), a hint too long for the
  column (L1f), a crossing counted twice at a lesson change (L1g);
- the engineering verifier's other survivors: V09 (a tie is a new best),
  V17 (Replay tutorial a no-op in the session), V28 (a 10x lenient speed
  effect), V28b (a half-size balloon), V31 (the fallback best not saved),
  V40, V41 (fade and reading margins 0), a hover ring the panel's colour.

Two survived a first pass, each a gap in a new test, now closed: V28b (on
the intermediate code: the nose-up case lost too little speed for the
balloon's lift to decide; it now loses 0.6 m/s) and L1c (after the
re-recording its moves began while the card was already faded; the
repeated-crossing test now checks the text keeps its side while the card
is readable and changes sides as the band crosses the centre line).

**Round 5** (`artifacts/ui/mutations/mutate_r5.py`, private copy
`.sandboxes/ui_mut5`, results `summary_r5.json`, logs `r5_*.log`,
`r5_run.log`, `r5_rerun.log`): **29 of 29 caught**, each by the test written
for it:

- major 1 put back: the HUD following the head (D1), `flight_yaw` ignoring
  where the bird faces or its velocity (D1b, D1c), a leash that rests off
  the path after a turn (D1d), an instant or dead-zone-less follow (D1e,
  D1f);
- major 2 put back: every celebration at home (D2), no home bias (D2b), a
  clock that ignores the view (D2c), a swap in place out of view (D2d),
  round 4's wide celebration (D2e), a lenient view limit (D2f), the plate
  judged on its stale layout (D2g);
- the minors: timed-out lessons stored (M1), an idle tutorial marked done
  (M1b), missed lessons at every resume (M1c), learned lessons taught again
  (M1d), flush desktop plates (M2), sliding off clicks (M3);
- the round-5 engineering verifier's survivors, in its own terms: B1 (hover
  style invisible), B2, B3, L2 (bars lowered with the constants), O2, O3
  (lenient spread / flap), P5 (release anywhere), S3 (instant menu
  follow), R1 (keep-alive never ends), R3 (hidden panel requests).

Three survived the first pass, each a gap in my new tests, now closed: D2g
(nothing sat where the stale rect would be: the test now compares the rect
judged in the placement frame with the laid-out one), M1d (no learned
lesson followed a missed one: the test now does 'Glide' between two
timeouts) and P5 (the mutant only raised a script error once sliding off
released the press: the test now counts errors with an `OS.add_logger`
Logger).

Earlier rounds: round 4's 34 (`summary_r4.json`), rounds 1–3's 86
(`summary.json`); their notice-placement mutations target code that
round 4 and 5 replaced.

### Visual evidence (`artifacts/ui/`)

```bash
tools/gd.sh ui --rendering-method forward_plus --resolution 1280x720 \
    res://tests/shots/ui_shots.tscn -- --fresh-settings
```

The run exits 1 if the VR colour, occluders, render budget, see-through,
notice placement, cue-over-plate, cue separation, late-change,
skipped-draw, after-resume, crab, torso-turn or celebration-in-view checks
regress; the last run had **0 failures** (`shots.json`, log
`r6_shots.log`). All PNGs viewed.

- `desktop_*.png`, `vr_{main,pause,settings,howto,caught,summary}.png`,
  `panel_*.png`: every screen as overlay, as a curved panel from a head
  camera, and as the exact texture. `desktop_hud.png`: the plates keep
  off the window edges. Round 6: the pause shots show a plausible run
  ("5:12 · 7 caught"; `panel_pause_pigeon/hawk/eagle`: 7:42 · 12, 18:24 ·
  31, 24:12 · 44).
- **HUD in VR** (96° tall views like a Quest Pro eye; a 96° rectilinear
  image stretches the edges, so a constant-elevation band looks slanted
  there; in the headset it is level):
  - `vr_hud.png`, `panel_hud.png` (round 6): the pulled-in card ("Twist
    wrists down", the title at the body size) above the horizon right of
    the centre line, the strip under it.
  - `vr_hud_crab.png` (round 6, the verifier's case): the flight path
    (white ring) crabbing 30° right and a little down in the breeze; the
    HUD stays where the body faces (centre line 0.00°), the card opaque
    and 2° clear of the path.
  - `vr_hud_after_resume.png`: paused, the head 14° left on Resume,
    resumed, looking ahead: the card beside the centre line, the strip on
    it (0.0°), opaque, clear.
  - `vr_hud_body_turn.png` (round 6): the player turned their torso 30°
    right (the bird and the head with it): 1.2 s later the HUD is there
    (centre line −29.5°), the card beside the new path.
  - `vr_notice_read.png`: the head turned 20° right and 12° up to read the
    card: fully shown, the cues drawn over it; the HUD did not move (0.00°).
  - `vr_hud_dive.png`, `vr_hud_prey_behind_strip.png`,
    `vr_hud_glance.png`: the hunting gaze clear, the strip making way, a
    deliberate glance reading it.
  - `vr_hud_climb.png`: climbing 16°, the card beside the path, fully shown.
  - `vr_notices_moved.png`: prey staying on the card's home (teal chevron):
    the card moved once to the left, its text right-aligned on the inner
    side (round 6).
  - `vr_tierup.png`, `vr_tierup_climb.png`: celebrations at home beside the
    centre line (and the next prey in a 12° climb), fully readable.
  - `vr_tierup_gaze_left.png`: a tier-up while looking 30° left: the
    celebration appears there, its text 14.7° from the gaze.
  - `vr_cue_over_card.png` (pixel check: the cue's coral over the card),
    `vr_cues_chase.png`, `vr_hud_apex.png`.
  - The HUD texture: `panel_hud_tierup.png`, `panel_hud_eagle.png`,
    `panel_hud_apex.png` ("2 of 5!", "3 more to win").
- Loop wording, hold bar, settings status, victory, occluders, scale,
  icons and how-to cards as in earlier rounds (`panel_pause_*`,
  `panel_settings_status`, `panel_summary_*`, `vr_occluders`,
  `vr_scale_*`, `icons_species`, `howto_*`).
- **The HUD and the card under real flight, plotted** (round 6;
  `tests/shots/ui_notice_plot.tscn`, a short rendering run, log
  `r6_notice_plot.log`, numbers in `notice_calm.json`). Four lanes share
  the time axis: azimuth in the rig (where the body faces, the HUD's centre
  line, the flight path, the span of the card's words), the resting gaze
  to the card's farthest word (with the 45° bound), the flight path's
  elevation (with the notice band), the card's opacity (red ticks where
  the path was behind the readable card; grey while a celebration shows
  instead). Palette: the reference data-viz palette's first three slots
  (validated all-pairs), status red, neutral grey.
  - `notice_real_tutorial.png`: the real game's tutorial (recorded): the
    path swings 60° right in the breeze and over the top at 20 s; the HUD
    and the card do not move; the farthest word 34.9° from the gaze
    throughout; 1 fade, read in view 99.1 %.
  - `notice_real_manoeuvres.png`: 54 s of turns, a dive, zooms and a chase:
    the HUD does not move; 7 fades of the card, 3 moves (it changes sides
    as the crab does), read in view 87.1 %; the path behind the readable
    card only in blinks (≤ 0.056 s).
  - `notice_torso_turn.png`: the B1 course with a 30° torso turn to the
    right at 5 s: the HUD follows the body in about a second; 0 fades,
    0 moves, 100 % in view.
  - Round 5's `notice_calm_*.png` (paths locked to the rig's forward) are
    gone: the round-6 verifier showed they could not see azimuth.

### Meta XR Simulator

```bash
tools/xr.sh 50 res://scenes/dev/ui_dev.tscn -- --demo --panel_pitch=-8.5 \
    --shots=1,5,8,11,12,14,17,20,23,26,28,31,36,42,46 --fidelity=1 \
    --occluders=11.5 --ui_autoclick=44 --prefix=sim
```

Result (round 6): `artifacts/xr/run_20260927_010015.log` (`.app.log`),
`artifacts/ui/sim_*.png` (log of the call: `artifacts/ui/r6_xr_run.txt`);
the head mirror is 96° tall like a Quest Pro eye.

- **Session:** Quest Pro, FOCUSED, 72 Hz, Mobile renderer, **0 script
  errors**; the whole tour (menu → play → a climb with a tier-up → pause →
  settings → how-to → resume and a chase → caught → respawn → eagle → apex
  catches → victory → menu).
- **HUD where the body faces:** `sim_05s` (the pulled-in "Flap to climb" /
  "Sweep down hard" right of the centre line, the strip under it),
  `sim_08s` ("Now a Swallow!" beside it in the 14° climb), `sim_31s`
  ("2 of 5!" / "3 more to win").
- **Colours and occluders:** Play `ebc94c` (expected `ebc94d`) and Quit
  `2a4160` (expected `2b4160`), within 1/255; the hand block stays in front
  (err 0.4/255), the branch block behind.
- **Pointer:** the real (fixed) aim pose hovers `Btn_settings`; the
  scripted pull at 44 s opens Settings.
- **Exit noise:** the OpenXR module's exit messages (spatial-entity
  disconnect, 2 interaction-profile RIDs, 1 ObjectDB instance) appear in
  every run since round 1; they are not UI's.

## Majors re-check (2026-09-27, 09:10, after the stopped session)

*(Note added by the core loop's fix round 1: "the current tree" below is
the tree of 09:10-10:30, before the core loop's 10:40 moth-mass and
director changes and its fix round 1 - which changed the lesson prey (the
ring now prefers the lesson's moths, which wait up to 40 m above the
ground), the growth and the swallow time after a catch. The UI code is
unchanged by it; the catch-lesson numbers below were not re-measured. Of
the "fresh" full-tier seeds, 17 is also a base-batch and `game_catch_test`
seed.)*

The majors round below (06:50-07:49) was complete on disk: nothing in
`scripts/ui/` was half-edited, the UI suite is **193 of 193**, and all 20
of its mutants are caught. The core-loop agent changed `game_loop.gd`,
`threat_watch.gd`, the Ecosystem and `moth_field.gd` after it (08:10-08:58),
so the four majors were re-measured through the real chain on the current
tree, on seeds none of the earlier rounds used (logs in
`artifacts/ui/verify/recheck/`):

| Major | Current tree, real chain |
|---|---|
| 1. Tilt for speed | `ui_lesson_real.gd --part=speed`: 4 x 60 s of neutral-wrist flap-and-glide (2+2, 1+3, 3+3, novice 2+2): progress 0; tilts ±0.6 done in 1.17-1.21 s (novice 1.33-1.36 s; bar 3 s). A gentle +0.35 tilt without a novice's overshoot has no effect in the FlightModel (no balloon, no speed bleed) and so does not complete, by design. |
| 2. Calm notices | New evidence tool `tests/shots/ui_live_calm_test.gd` (the live game, 6 fresh bot seeds 3, 8, 14, 27, 46, 62: the lessons, then 60 s hunting the target cue with the catch card up): move starts **0-0.059 /s** (bar < 0.1), the flight path behind a readable plate **at most 0.042 s** (bar 0.3), card readable in view 83-98 % (the hunt's crossings are fades). `artifacts/ui/live_calm.json`. |
| 3. Cues over plates | The verifier's `ui_r4eng_probe_test.gd` now loads **unchanged** (HUD keeps `placement_candidates()` and `DODGE_SEARCH_S` for it): 4 of 4, a cue under an opaque plate in **0 of 16** prey and **0 of 9** threat cases. |
| 4. Catch lesson | `ui_lesson_real.gd --part=catch` (new `--who`, `--tag`; `--quality=quest` for the Quest tier), 6 fresh seeds per tier, competent and struggling: all **done by a catch**. Full tier (41, 58, 73, 86, 92, 17): competent 10.0-22.6 s, struggling 9.6-44.1 s. Quest tier (19, 24, 37, 52, 68, 81): competent 13.3-13.5 s, struggling 13.1-27.5 s. The first catch is usually an ordinary moth of the sky's swarms (the target cue picks it); the lesson's own moths are there when the sky has none near. A passive orbit still ends at the 300 s timeout ("Let's move on", after 9 helps; seeds 41, 58, 73; Known limits). Evidence `artifacts/ui/lesson_real_catch_{full1,full2,questA,questB}.json`, 0 game errors. |

Screens re-shot (`ui_shots`, 71 images, 0 failures) and looked at: no change.

The round-7 verifiers' probes on the current tree: `ui_r7x_flow` 3/3,
`ui_r7x_margin`, `_pointer`, `_replay` pass; `ui_r7x_torso` 3/4 (as
before, Known limits); `ui_r7x_live` 2/3: seed 5 now meets a **real
threat** crossing the card twice in the catch lesson (21.1 s and 32.8 s,
0.9 s and 0.37 s see-through; the live sky changed, not the UI, which is as
it was when the same seed gave 1 fade at 07:43), so 3 fades and the card
read in view 93.8 % (its bars: < 3, 95 %). The notices must make way for a
real threat, so this is left as it is. (Run `ui_r7x_flow` without
`--fixed-fps`: its pause comes after 500 ms of wall-clock time, by which a
fixed-fps run is seconds of game time in and the 3.2 s celebration is over.)

## Majors round (2026-09-27, after the round-7 verification)

The lead's four UI majors (`artifacts/ui/open_findings_b1.json`, the
round-3 verifiers' findings; rounds 4-6 had addressed three of them) and
the round-7 verifiers' probes (`tests/probes/ui/ui_r7x_*`). Evidence in
`artifacts/ui/verify/majors/`.

| Major / finding | State found / fix | Pinned by, measured |
|---|---|---|
| 1. "Tilt for speed" completes on neutral wrists | Already fixed (round 4): the lesson needs `pitch_input` held past 0.15 for 1 s in a glide *and* its effect. Checked on the current tree: the FlightModel recording re-recorded (identical) and, new, the **real chain in the real game** | `ui_onboarding_test` (recorded FlightModel: never in 60 s, tilts 0.99-2.26 s); `tests/shots/ui_lesson_real.gd --part=speed`: 4 x 60 s neutral-wrist flap-and-glide never (progress 0), ±0.6 tilts 1.17-1.33 s (bar 3 s); the verifier's `ui_r4x_experience` 9/10 (its control feeds `FlightModel.telemetry()`, which has no `pitch_input`, by construction) |
| 2. Notices move almost constantly and hide the path | Round 4-6's rules kept the replays calm, but **live** the lesson card still moved 1-4 times in a 35 s tutorial (the round-7 verifiers), because "3 crossings in 8 s" also moved it, one jittery 0.4 s pass on the margin counted as 2-3 crossings, and the cues were seen a frame late (phantom covers, below). Now the lead's rule exactly: fade while something crosses (hysteresis 1.0° and 0.12 s), **move only what stays > 1 s**, at most once per 4 s, eased | `test_a_jittery_crossing_of_the_margin_is_one_fade`, the repeated-crossings and margin tests; replays: tutorial flap2+glide2, 3+3, B1 sparrow / pigeon / eagle: 0 moves, path never hidden; real-game recording 0 moves (was 3), path behind the readable card ≤ 0.056 s; **live, six seeds: 0 moves** (was 2, 4, 1), 1-2 fades (was 3-6), read in view 97.9-98.8 % (was 79.5-94.1 %): the verifier's `ui_r7x_live` bars met on all six; `ui_r7x_margin` 1/1 (was 0/1); `ui_r4x_experience` calm checks pass (move starts 0/s, bar < 0.1; path hidden ≤ 0.056 s, bar 0.3) |
| 3. Cue chevrons hidden under notice plates | Already fixed (round 4): chevrons render over the HUD (priority 11 > 9; desktop layer 6 > 5), and the notices make way for the cues | The verifier's probe cases (`ui_r4eng_probe_test.gd`'s three cue tests, run from a copy: the file itself no longer loads, it calls `HUD.placement_candidates()` deleted in round 5): **0 of 16** prey and **0 of 9** threat cases with a cue under an opaque plate; `test_cues_draw_over_the_hud_and_never_sit_under_a_readable_plate`; pixel check `vr_cue_over_card` |
| 4. The catch lesson: lesson prey, copy, no 300 s dead end | New: GameLoop's lesson-prey API (`request_lesson_prey` / `release_lesson_prey` / `lesson_prey`, the core-loop agent's, this round); the card names the prey and says what to do; help every 30 s without a catch (the swarm put ahead again, nearer; the words say more), held back while the player closes on one | `test_the_catch_lesson_helps_a_struggling_player`, `test_the_catch_lesson_uses_the_games_lesson_prey`, `test_help_waits_while_the_player_closes_on_a_lesson_bird`, the naming and legibility tests; real game (6 runs each): competent 12.6-91.6 s, struggling 13.4-87.4 s; passive: 300 s timeout in 6 of 6 (GameLoop's placement, Known limits); shots `panel_hud_catch`, `panel_hud_catch_help`, `vr_hud_catch` |
| Round-7 (engineering): live, the notices made way for cues that were not on them (phantom covers) | Cue directions from the camera as it is now (`HudIndicators.cue_direction`), not the chevron meshes' last positions | `test_the_notices_see_the_cues_where_they_are_drawn_now` (0.19° vs 3.1°); the verifier's `ui_r7eng_replay_lessons`: live order + travelling rig 1 onset, 0 moves (was 6 onsets, 2 moves) |
| Round-7 (experience): a pause 0.5 s into a tier-up lost the celebration | A pause keeps it (its clock waits while the HUD is hidden) | `test_a_pause_keeps_a_celebration_for_after_resume`; the verifier's `ui_r7x_flow` 3/3 (was 2/3) |

Where the verifiers' probes stand (logs in `verify/majors/`): `ui_r7x_margin`
1/1 (was 0/1), `ui_r7x_flow` 3/3 (was 2/3), the six-seed copy of
`ui_r7x_live` 6/6 (was 0/3), `ui_r7x_replay` 1/1, `ui_r7x_pointer` 3/3,
`ui_r6x_experience` 3/3, `ui_v2eng` 5/5, `ui_r5x_experience` 5/5,
`ui_r5eng` 2/2, `ui_r3x_experience` 9/9, `ui_r4x_experience` 9/10 (its
speed control feeds `FlightModel.telemetry()`, which has no
`pitch_input`), the `ui_r4eng` cue cases 3/3 (from a copy; the file calls
the round-5-deleted `HUD.placement_candidates()`).
`ui_r7eng_replay_lessons` 0/1 by design: all its replay variants now give
1 fade and 0 moves, so none reproduces the recorded live UI's 2 moves
(those were the phantom covers). `ui_r7x_torso` 3/4: after a tucked dive
the HUD rests 5.8° from where the body faces, inside its 6° dead zone
(round 6's design, not changed here). A celebration held through a pause
is not "running" (`HUD.toast_active()` is false while the HUD is hidden,
`toast_waiting()` true), which is what `ui_r3x_experience`'s invariant and
`ui_r7x_flow` both ask.

Found while fixing:

- **The live tutorial's unexplained fades were phantom cue covers** (the
  round-7 engineering verifier's `ui_r7eng_replay_lessons`: live frame
  order plus a travelling rig). UIRoot's `make_way` runs before the
  chevrons are re-placed, and the rig carries the eye ~0.1 m a frame, so
  the meshes' last positions were ~3° off where the chevrons are drawn
  (3.1° measured): the notices faded, and in round 6 moved, for cues that
  were never on them; the verifier's own cause test, run after the cues had
  moved on, logged them as "". The notices now take each cue where it is
  drawn from the eye as it is now (`HudIndicators.cue_direction`, 0.19°
  off: the ring angle's one-frame lag). `UIRoot.notice_causes()` says what
  the notices made way for, as the HUD saw it.
- **A move could start after the thing had gone**: with the crossing
  held for 0.12 s, a card stuck on both sides moved in the hold's frames.
  Moves need something actually on the plates.
- **Re-running a verifier probe overwrote its evidence**:
  `ui_r7x_live` writes `artifacts/ui/verify/r7/live_tutorial.json`
  (restored from its printed content; this round's live runs are in
  `verify/majors/`); `ui_r4x_experience` redrew
  `verify/r4x_lesson_card_motion_tutorial_flight.png`, which now shows the
  current, calm card.

## Integration round 2 (the integration fixer, 2026-09-27)

The whole-game verifiers' UI findings (`docs/INTEGRATION.md` §9; the UI's
own agent was done, `scripts/ui/` had been quiet for hours):

| Finding (severity, lens) | Fix | Pinned by |
|---|---|---|
| Main menu in the headset: the resting right controller's laser lies on Quit, and one pull quits (minor, all three) | Quit is a `HoldButton` ("Hold to quit"), like Restart run and Quit to menu | `ui_flow_test.test_quit_button_calls_quit` (a pull does not quit, a hold does), `game_flow_test.test_quit_to_menu_then_quit` (the real game, the pointer) |
| The catch lesson timed out (45 s) before a typical first catch (39-390 s in real play, median ~110) and came back every session (minor, experience) | A lesson's own `"timeout"`: the catch lesson waits `Onboarding.CATCH_TIMEOUT` (300 s); its hint names the cue that marks prey: "Chase a ringed bird" | `ui_onboarding_test.test_the_catch_lesson_waits_for_the_first_catch` |
| Desktop mode never names a key; the Buttons tab says "Flying needs no buttons" (minor, experience + engineering) | Lessons carry `"keys"` ("Hold Space to flap", "W faster, S balloon", "A or D to bank", "Hold Shift to dive", ...), which the HUD shows outside VR (`HUD.show_lesson` by `set_vr`); How to fly's cards carry desktop captions (`HowToScreen.desktop`, set by `UIRoot.set_vr_mode`): the Buttons card lists Space, W/S, A/D, Shift, the mouse and Esc, the Speed card says a held S stalls | `ui_onboarding_test.test_desktop_names_the_keys`, `ui_legibility_test` (the key hints fit the card's column; the desktop captions fit three lines), `game_desktop_test` (the real game on the desktop: the card says the keys) |
| A turn-rate comfort setting (major, experience; minor, Quest) | Settings gains a **Turn speed** bar: 4 named steps (Gentle, Calm, Brisk, Full: 90-240 deg/s; flight's `FlightTuning.TURN_COMFORT_*`), never zero; the column's rows are 8 px apart and the action buttons 82 px tall so it fits the panel | `ui_pointer_test.test_settings_change_and_persist_by_pointer` (the - cap steps it down to Gentle and it says so), `ui_legibility_test` (every control inside the panel); `artifacts/integration/shot_settings.png` |
| The target cue's colours (teal / coral) differ from the birds' highlights (blue-violet / magenta) (minor) | Not changed (a look-and-feel decision for the UI and birds areas together) | - |

UI suite after the round: 187 of 187.

## Fix round 6: what the verifiers found and what changed

| Finding (severity, lens) | Fix | Pinned by |
|---|---|---|
| In real flight the HUD followed the ground-track heading: a zoom over the top swung it 157° round the player, the breeze put the card 45–64° from a resting gaze; card in view 39.5 % of the real tutorial; a real tier-up read 1.26 s (major, experience) | The HUD's centre line is where the body faces: `UIRoot.body_yaw()`, PlayerBird's telemetry `body_yaw` (the torso in the rig's frame), smoothed, a 6° dead zone, eased at ≤ 90°/s; the flight path is only kept clear (the notices make way for it) | `test_notices_under_the_real_games_flight` (the real game recorded and replayed: HUD 0° of travel, card in view 99.1 % / 87.1 %, celebrations ≥ 2.61 s), `test_hud_follows_where_the_body_faces_not_the_head_nor_the_path`, `test_hud_without_a_torso_estimate_uses_where_the_bird_faces`; plots `notice_real_tutorial`, `notice_real_manoeuvres`, `notice_torso_turn`; shot `vr_hud_crab`; mutations F1–F1l |
| The notice tests replayed flights with the path's azimuth locked to the rig's forward, so wind crab, the lagging view turn and the flip over the top never reached the UI (minor, experience) | `tests/shots/ui_game_record.gd` records the real game (scenes/main.tscn, the integration bot): rig heading, velocity, facing, torso, head, world_scale, GameLoop's target and threat; the suites replay it through core contracts with the rig parented like PlayerBird's, and a second time with the player 60° round in their room | `test_notices_under_the_real_games_flight` (`ui_game_flights.json`) |
| The card's words ended 41° from a level gaze, 4° inside the 45° bound (minor, experience) | The card 9.7–42° right, text 10.7–32.2° (548 px column, the title at the body size, hints shortened); right-aligned on the mirror side; it changes sides mid-move; still clear of prey jinking ±8° round the centre line | `test_notices_live_beside_the_centre_line` (every lesson at home and mirror ≤ 34.9°; the ±8° prey 1.5° clear), `test_hud_lessons_fit_the_viewport`; mutations L1–L1h |
| In non-XR runs the HUD snapped to the camera's unscaled menu height at Play and hung a metre above the eye for a second (minor, experience) | A head that jumps more than 0.5 tracker m between frames re-seats the eye point at once (`UIPanel.HEAD_JUMP_M`) | `test_hud_eye_point_follows_a_reseated_head_at_once` (the strip at −40.23° one frame after 1.62 → 0.23 m at world_scale 0.141); mutation F1l |
| Evidence screenshots showed "0:00 · 7 caught" (minor, experience) | The shots set a plausible run (5:12 · 7 caught; per species 7:42 · 12, 18:24 · 31, 24:12 · 44) | `desktop_pause.png`, `vr_pause.png`, `panel_pause_*.png` |
| World → rig conversion unpinned: every test kept the rig at the identity (minor, engineering, V01) | The real-game replay yaws the rig under a PlayerBird-like parent; the facing fallback is tested with the rig yawed 70° and through a flown 90° turn | `test_hud_without_a_torso_estimate_uses_where_the_bird_faces`; mutation F1d |
| "Placed at once when shown" tested only for head changes (minor, engineering, V10) | A respawn with the torso turned 90° while caught, a resume with it turned 50° the other way | `test_hud_reappears_where_the_body_now_faces`; mutation F1k |
| The dead zone was tested only before the first follow and bracketed 3–30° (minor, engineering, V03, V12) | Wobbles after a follow and after a 30° turn; ±4° and a 5° lean move nothing, 8° is followed | `test_hud_follows_where_the_body_faces_not_the_head_nor_the_path`; mutations F1g, F1h, F1i, F1j |
| Replay tutorial within the same session untested (minor, engineering, V17) | Tested: after the lessons ran out, a resume does not restart them, Replay tutorial does | `test_replay_tutorial_in_the_same_session`; mutation V17 |
| Constants unpinned or loosely bounded (minor, engineering: V09, V28, V31, V40, V41, the Play hover thresholds) | Boundary cases: a tie is not a new best; the fallback best is written to disk; a 0.3 m/s drift and a 0.6 m/s rise are not "Tilt for speed"; a bird 1.0° off the card fades it and 2.2° does not; the head 4° off is reading and 8° is not; the hover ring against the panel ≥ 3:1 (WCAG non-text), Play's thresholds tightened to 1.05 / 1.35 | `test_summary_best_rules`, `test_the_fallback_best_score_is_saved`, `test_weak_or_wrong_gestures_...`, `test_the_fade_and_reading_margins_are_literal`, `test_the_hover_highlight_is_visible`; mutations V09, V28, V28b, V31, V40, V41, V_hover |
| The round-5 contract note said "backwards compatible" but removed two symbols; "the whole UI's cost" overstated what was timed (minor, engineering) | A correction in the round-6 contract note; the cost is now described as the UI's script cost per frame (callbacks only: no layout, `_draw` or GPU) | `docs/ARCHITECTURE.md` (2026-09-27 ui note), U7 row |

Found while fixing this round:

- **The text flipped sides at the start of a move**, while the card was
  still opaque: its words were 44.7° from the gaze for a few frames. It now
  changes sides as the band crosses the centre line, mid-move, see-through.
- **On the mirror side left-aligned text started at the column's outer
  end** (37° from a level gaze instead of 34.8). It is right-aligned there.
- **A plate's layout could lag a side change made while it was hidden**
  (containers sort deferred, and not while hidden). The real game sorts
  before drawing, but anything measuring in the same frame (tests, the
  verifiers' probes) saw the words on the wrong side. Plates are laid out
  at once when the side changes and when they are shown again.
- **The lesson card showed for a frame where a celebration had been**
  (possibly 60° out). It is hidden until `make_way` places it.
- **Tried and dropped:** a "path side" rule (a new card on the side away
  from the path's recent drift, and a move after 2 crossings while it
  drifts). On the real tutorial it made things worse (2 moves, read 91.8 %,
  against 0 moves, 99.0 % without it), and it added a mechanism.
- **Pulling the card in to 8° broke an older requirement**: prey jinking
  ±8° round the centre line (the round-4 verifier's fluttering moth, rerun
  this round) faded the card a third of the time. The edge is at 9.7° with
  a narrower text column instead, which keeps both.
- **A crossing that began in a zero-time `make_way`** (UIRoot places a new
  lesson's card at once) **was counted twice**, so two crossings at lesson
  changes could move the card. Found by watching the real game's UI while
  recording (`live_ui` in `ui_game_flights.json`); now counted on the
  transition.

### Where the verifiers' probes stand

On the final round-6 code (logs in `artifacts/ui/verify/r6fix/`):

- `ui_r6x_real_game` (the real game, the verifier's own run): **the major
  is gone**: the HUD 0.0° from where the body faces, 0° of travel (was
  156.7° and 767°/min); the lesson card read in view of a resting gaze
  **90.5 %** (was 39.6 %), every word within 34.9° (was 143.5°); the real
  tier-up read in view **2.69 s** (was 1.26 s); the path behind the
  readable card at most 0.042 s; the caught, pause, settings and summary
  checks pass (4 of 5 tests). The tutorial test still fails four of its
  checks:
  - *"the card rarely fades" (4, bar < 3) and "at most one move" (2)*: in
    that run of the live game the card made way 4 times and changed sides
    twice. The ecosystem differs run to run: my recording's tutorial,
    replayed, fades once and never moves; watching the live UI while
    recording, the tutorial faded 3 times and moved twice, for the flight
    path, GameLoop's threat and its cue chevron (`live_ui` in
    `ui_game_flights.json`; that run also had the double-count bug, since
    fixed). Each is the card making way so that what matters is never
    hidden, which earlier verifiers asked for.
  - *"looking along the flight path, the card is in view >= 90 %"* (23 %)
    and *"the card's words never come within 6° of the real flight path"*
    (0.4°): these ask the card to follow the flight path, the opposite of
    the verifier's own fix for the major ("anchor the HUD to where the body
    faces; use the flight path only as a keep-clear constraint"). With the
    path crabbing 20–30° off the body, no card can be within 45° of both a
    resting gaze and a gaze along the (3D, often steep) path, and a card
    beside the body is crossed by the path now and then; it then turns
    see-through (see Known limits). I kept the verifier's recommendation.
- `ui_r6x_experience` (the verifier's mock replay of the real zoom over the
  top, the hovering drift and the slow crab): **3 of 3** (was 0 of 3): HUD
  0° of travel, card in view 100 % in all three. (The mock's telemetry
  reports `body_yaw` 0, as the real bot's torso did in the verifier's own
  trace.)
- `ui_v2eng` (the engineering verifier's probe): **5 of 5**.
- `ui_r5x_experience` 5 of 5, `ui_r5eng` 2 of 2, `ui_r3x_experience` 9 of
  9.
- `ui_r4x_experience`: 9 of 10. Its fluttering-moth check (prey jinking
  ±8° round the centre line at the notices' height) failed on an
  intermediate round-6 layout (card edge 8°: readable 67 %) and passes on
  the final one (edge 9.7°: readable 100 %, 0 moves). The one failure is
  its speed probe's control, as in rounds 4 and 5 (it feeds
  `FlightModel.telemetry()`, which has no `pitch_input`).
- `ui_r2_experience` 9 of 10 and `ui_r3eng` 6 of 8: the same disagreements
  by design as in round 5 (an idle player's tutorial stored as complete;
  the HUD following the head; an apex goal of 5 where GameLoop's is 3).
- `ui_r4eng_probe` does not load (it calls `HUD.placement_candidates()`,
  deleted in round 5).


## Fix round 5: what the verifiers found and what changed

(History. Round 6 replaced round 5's centre line, the flight path's
heading, with where the body faces, and pulled the card in; the numbers
below are round 5's, measured on flights whose path was locked to the
rig's forward.)

| Finding (severity, lens) | Fix | Pinned by |
|---|---|---|
| The HUD's centre line was the head's yaw when PLAYING started, so "notices beside the flight path" broke on ordinary Play and Resume clicks (major, experience) | The centre line is the flight direction (`UIRoot.flight_yaw`: velocity heading, the facing mixed in for a slow bird), followed with a 4° dead zone and a full, eased recentre; head turns never move the HUD | `test_the_hud_centre_line_is_the_flight_path_whatever_the_head_did` (10 entries: 0 fades, 0 moves, words 11.4–38.9°, read in view 100 %), `test_notices_stay_calm_under_real_flight` (+ body turns), `test_hud_follows_the_flight_direction_not_the_head`, `test_recenter_...`; shots `vr_hud_after_resume`, `vr_hud_body_turn`; plots `notice_calm_resume`, `notice_calm_body_turn`; mutations D1–D1f |
| Tier-up and apex celebrations could play out entirely outside the view; "84 % readable" was opacity only (major, experience) | A celebration is placed where the player looks (beside the path, clear, home's side unless the other is 5° nearer); its clock holds while faded or out of view (≤ 3 s); it swaps in place only over one being read; narrower (text ≤ 680 px, title 90 px) so its words end 41° out at home | `test_celebrations_appear_where_the_player_looks` (15 gazes: 2.69 s of 3.21 s in view), `test_a_celebration_waits_while_the_player_looks_away`, `test_a_new_celebration_over_one_out_of_view_goes_where_the_player_looks`, toast-width checks; shot `vr_tierup_gaze_left`; mutations D2–D2g |
| A timed-out lesson persisted as learned (minor, experience) | Only lessons done are stored; the tutorial is done when all were (or it was skipped); missed ones come back next session, not every resume; learned ones never re-taught | `test_a_timed_out_lesson_is_offered_again_next_session`; mutations M1–M1d |
| Readability numbers omitted visibility; plots unlabelled (minor, both) | Every notice number is now "read in view" (opacity ≥ 0.6 and every word within 45° of the gaze); the plots are re-drawn with axes, units, a legend and a summary line, and one per scenario the verifier raised | `_in_view_readable` in `ui_hud_test`; `notice_calm_*.png`, `notice_calm.json` |
| Desktop lesson card flush with the window's top (minor, experience) | 32 texture px (19.2 screen px) of margin top and bottom | `test_desktop_hud_keeps_off_the_window_edges`; `desktop_hud.png`; mutation M2 |
| Legibility and contrast bars read from UITheme's own constants (minor, engineering) | The checks use the brief's literals (1.5°, 4.5:1); a test pins the constants to them; the backwards "flat corner" message fixed | `test_the_theme_states_the_brief_bars`; mutations B2, B3, L2 |
| Spread and flap thresholds unpinned (minor, engineering) | Arms half out (0.5, 0.7) for 5 s and one or two strong beats are asserted not to pass | `test_half_spread_or_one_or_two_beats_are_not_the_lessons`; mutations O2, O3 |
| UI tests called flight internals beyond the contract (minor, engineering) | The tutorial and tilt flights are recorded by `tests/shots/ui_flight_record.gd` into `ui_flight_runs.json` and replayed; the suites, and the notice plot, no longer touch FlightModel / WingState / FlightEnv | `grep` shows only comments naming the FlightModel in `tests/unit/ui` |
| Dead compatibility code (minor, engineering) | `HUD.DODGE_SEARCH_S` and `placement_candidates()` deleted (the r4eng probe that used them no longer loads) | |
| Stale docs and a vestigial cross-process lock (minor, engineering) | The occluder limit removed (the VR wing shader writes stencil 64), the tremor figure corrected to 0–1.3 ticks/s, the kit's settings lock, backup and PID code (~140 lines) removed: each sandbox has its own `user://` | `ui_test_kit.gd` |
| Behaviours pinned only by screenshots or not at all (minor, engineering) | Hover style visible (headless); press, slide off, release: no click, no error; menu follow ease-out; hidden panels book no render; keep-alives end | `test_the_hover_highlight_is_visible`, `test_press_then_slide_off_the_panel_is_no_click`, `test_panel_is_lazily_head_following_...` (14.1°/s), `test_a_hidden_panel_takes_no_render_requests`, `test_a_keep_alive_ends`; mutations B1, P5, S3, R3, R1 |
| Whole-UI frame cost not reported (minor, engineering) | Measured and pinned: 68 µs mean, 294 µs p99 in flight with the card and both cues; 29 µs in a menu; 0.40 ms the frame a celebration appears | `test_the_whole_ui_is_cheap_every_frame` |

Found while verifying this round:

- **Sliding off a button clicked it.** The new press-then-slide-off test
  started a run: leaving the panel released the held press at the last
  pointer pixel, still on Play. Fixed in `UIPanel.pointer_exit` (move off,
  then release).
- **A celebration's words reached 46° at home**, past a Quest Pro's sharp
  view, when the player looked along the path: the in-view metric showed
  it (the verifier's plate-centre measure did not). Narrowed to 26° of
  text; "Too small now:" became the pause screen's "Ignore:".
- **A new celebration swapped in place over one waiting out of view**, and
  **a celebration chose its side by half a degree** after the HUD settled
  within its 0.5° tolerance: both showed in the screenshot run. A swap is
  now only over one being read; home's side wins unless the other is 5°
  nearer.
- **UIRoot's celebration keep-alive was redundant** (the burst's redraw
  books each frame's render); removing it let the flow test run the
  celebration in synthetic time (the suite went 60.9 → 55.4 s).

### Where the verifiers' probes stand

On the round-5 code (logs in `artifacts/ui/verify/r5fix/`):

- `ui_r5x_experience`: **5 of 5** (was 1 of 5): lesson text in view
  whatever the head did at show time; Resume / Play by pointer then the
  tutorial flight: 0 fades, 0 moves; a tier-up in view at gazes 0, −25,
  −40, +30; gentle tilts; a timed-out lesson not recorded.
- `ui_r5eng_probe`: **2 of 2**.
- `ui_r4x_experience`: 9 of 10: the speed probe's control feeds
  `FlightModel.telemetry()`, which has no `pitch_input` (by construction;
  `PlayerBird.telemetry()` reports it).
- `ui_r3x_experience`: 9 of 9.
- `ui_r2_experience`: 9 of 10: its no-telemetry check wants a tutorial of
  timed-out lessons stored as complete (`is_done()`), which is what the
  round-5 verifier asked to stop; the rest of that check (it finishes by
  itself, bounded by the per-lesson timeout) holds.
- `ui_r3eng_probe`: 6 of 8: `test_hud_panel_is_lazy_in_yaw` expects the HUD
  to follow the head past a dead zone (replaced by the flight direction,
  as the round-5 verifier asked); `test_ui_against_the_real_game_loop`
  hard-codes an apex goal of 5 (GameLoop's is 3; the UI shows 3).
- `ui_r4eng_probe`: does not load: it calls `HUD.placement_candidates()`,
  deleted as dead code at the round-5 engineering verifier's request.

## Fix round 4: what the verifiers found and what changed

(History. Round 5 made the HUD's centre line the flight direction (round 4
assumed it was, but it was the head's yaw at show time), placed
celebrations where the player looks, and replaced round 4's "path
drifted through the card" tests; the numbers below are round 4's.)

The lead's direction for this round: the speed lesson must read the
player's input and its effect; the notices must be calm (a fixed home the
flight path rarely crosses, slow hysteretic avoidance, fade while
something crosses); cues must draw on top of the HUD plates and the
plates avoid them; prefer simpler designs where a mechanism kept
producing edge cases. The step-aside search (placements up to 16° up and
30° aside, costs, settle and grace timers, a search every 0.1 s) is gone;
two fixed placements and three rules replace it.

| Finding (severity, lens) | Fix | Pinned by |
|---|---|---|
| "Tilt for speed" completed by ordinary flapping and gliding with neutral wrists (major, experience) | The lesson needs `pitch_input` held past 0.15 for 1 s while gliding and its effect (speed +0.5 m/s / 5 %, or a balloon) in the same window, which restarts on letting go, reversing, flapping | `test_speed_lesson_needs_the_tilt_on_the_real_flight_model` (neutral wrists never in 60 s; tilts 1.0–2.3 s), `test_weak_or_wrong_gestures_...`; mutations D1–D1e |
| Notices moving almost constantly under real flight, still hiding the path (major, experience) | A fixed home beside the flight path (10–52° right); fade while something crosses; move once, to the mirror placement, only if it stays 1 s or crosses 3 times in 8 s, at most every 4 s, eased; a new notice appears where it is clear; HUD dead zone 55° | `test_notices_live_beside_the_flight_path`, `test_notices_stay_calm_under_real_flight` (0 moves, 0 hidden), `test_notices_fade_for_a_crossing_and_move_only_when_something_stays`, `test_a_new_notice_appears_where_it_is_clear`, `test_celebrations_readable_and_clear_...`, `test_hud_follows_lazily_too`; `notice_calm_*.png`; mutations D2–D2i |
| Cue chevrons hidden under the notice plates (major, engineering) | Chevrons render after the HUD (priority 11 > 9; desktop layer 6 > 5); the drawn cues are protected directions (except while the head points at the notices: reading) | `test_cues_draw_over_the_hud_and_never_sit_under_a_readable_plate` (the probe's 25 cases: 0), `test_reading_the_notices_never_fades_them`; pixel check `vr_cue_over_card`; mutations D3–D3d |
| A freed target or threat bird breaks cue updates (minor, experience) | New bird taken first; the old one untinted only if valid; `_highlight` untyped | `test_a_freed_target_or_threat_never_stops_the_cues`; mutation F1 |
| Hover haptic buzz at a button's edge (minor, experience) | 12 px hover hysteresis (never holding a neighbour), hover ticks ≥ 0.35 s apart | `test_resting_on_a_button_edge_with_tremor_does_not_buzz` (0–1.2 ticks/s; sweep 1 tick; neighbour switch; pull lands on the highlight); mutations H1–H1c |
| A celebration replacing another blinks to 3 % (minor, experience) | The new one pops in from the old one's opacity | `test_back_to_back_celebrations_do_not_blink` (min 1.00); mutation T1 |
| Suite 120 s, over the 60 s budget (minor, both) | Synthetic time for every HUD clock and the head-follow | 54.9 s (`r4_suite.log`) |
| 9 mutations surviving (minor, engineering) | One test each: threat cue strength by level, sparrow vs eagle cue fade, empty bands hidden, filters reset, "Out of lives", confirm buzz × haptics, status line clears, menu button on a sub-screen, desktop threat step-out | mutations k03–k33 all caught |
| UI adds its own aim controllers next to the rig's (minor, engineering) | Reuse the rig's `LeftAim`/`RightAim` (aim pose); add `UIAim_*` only if absent; never free what it did not add | `test_the_rigs_own_aim_controllers_are_used`; mutations A1, A1b |

Found while verifying this round:

- **Reading the card faded it.** The new `vr_notice_read` shot (the head
  turned 28° right to read the lesson) showed a ghost card: the cue ring
  turns with the head and swept onto the card, and cues were protected
  directions. Cues now count only while the head does not point at the
  notices (within 6°); they draw on top anyway. Pinned by
  `test_reading_the_notices_never_fades_them` (mutation D3d).
- **The first move rule was not calm enough for a drifted path.** "Stays
  1 s" alone let a path drifted into the card's column fade it at every
  flap cycle (twice every 4 s) without ever moving it; a leaky
  accumulator was tried and missed short, frequent crossings. The rule
  "3 crossings within 8 s" moves it once instead (readable 94–97 % in all
  drifted profiles).
- **The celebration's burst was cut off** on the side where its plate
  hugs the band's edge; each side now spreads only as far as there is room.

### Where the verifiers' probes stand

On the round-4 code (logs in `artifacts/ui/verify/r4fix/`):

- `ui_r4x_experience` (headless, real time): **9 of 10**. Lesson card
  under the five real flight profiles: 0 moves, 0 hidden, readable
  100 %; tier-ups: 0 moves, 0 hidden, 84 % readable each; fluttering
  target: readable 100 %, never hidden, 0 moves; back-to-back celebrations
  min 0.97; button edge 0.3 ticks/s; freed birds; drag-off; long session.
  The one failure is the speed probe's **control** ("a real wrist tilt
  completes the lesson"): the probe feeds `FlightModel.telemetry()`, which
  has no `pitch_input` (PlayerBird's telemetry does, and the lesson now
  needs it). Its false-positive half passes (neutral wrists: 0 completions,
  progress 0). `ui_onboarding_test` runs the same flights with the key.
- `ui_r4eng_probe`: **4 of 4**: 0 of 16 prey cases and 0 of 9 threat
  cases with a cue under a readable plate; ring cover at home 34° of the
  24° ring; worst `make_way` 20 µs.
- Earlier rounds: `ui_r3x_experience` **9 of 9**, `ui_r2_experience`
  **10 of 10**, `ui_r3eng` **7 of 8**: its real-GameLoop check hard-codes
  an apex goal of 5 catches; GameLoop's goal is now 3, and the UI shows
  GameLoop's number everywhere ("Catch 3 big birds to win", "0 of 3 to
  win"). Compile check (`scenes/dev/ui_compile_check.tscn`): 0 failures.

## Fix round 3: what the verifiers found and what changed

(History. Round 4 replaced round 3's stepping-aside notices and their
tests; see "Fix round 4" above.)

| Finding (severity) | Fix | Pinned by |
|---|---|---|
| Celebrations and the lesson card nearly invisible while climbing (major, experience) | Notices step aside (up, else sideways) instead of fading; fading kept as a last resort, with the celebration's clock held (≤ 3 s) while unreadable | `test_celebrations_and_lessons_stay_readable_in_climbs_and_chases` (81–82 % readable in every case, was 0 %; 0 frames covering the path or target), `test_notices_step_aside_and_the_strip_fades`, `test_when_nothing_clears_the_notices_fade_and_the_celebration_waits`; verifier probe `ui_r3x_experience` 9/9 (was 3/9) |
| Prey and threat cues drawn on top of each other (major, experience) | Threat chevron steps out to an outer ring (≤ 9°) when both point within 22° | `test_prey_and_threat_cues_never_draw_on_top_of_each_other` (min 5.7°, was 0.0–0.9°); `vr_cues_chase.png` |
| "Replay tutorial" status pushes the Settings screen off the panel (minor) | Shorter message that fits; status label clips instead of widening its row | `test_settings_status_messages_fit_and_are_legible`; `panel_settings_status.png` |
| "Catch a moth" contradicts "Ignore: Moth" (minor) | "Catch a smaller bird" | `test_catch_lesson_never_names_a_bird_the_hud_says_to_ignore` |
| 12 of 16 new mutations survived (minor, engineering) | The probe's checks, as unit tests: HUD lazy yaw, recentre snap, cue angle and size across world_scale, the summary's menu button, an untracked hand, a lost aim pose, a caught target's cue, the strip's 2.5° margin, the see-through level (literal 20 %), gliding at rest, a 0.3 s dip, the drawn mesh vs the analytic surface | all 16 caught (see Mutation check) |
| See-through opacity asserted against the code's own constant (minor) | Literal bounds (< 0.2) in the suite and the screenshots | mutation X37 (0.45) caught |
| Dead code (minor) | `panel_box`, `outline_polygon`, `draw_arrow`, `set_label` removed; `toast_lines` kept (the engineering probe calls it) and now used by the legibility test | |
| Threat tint and threat see-through used different thresholds (minor) | `UIRoot.REAL_THREAT` (0.1) and `is_real_threat()` (`>=`) for both; public test hooks `UIPanel.note_draw_started()` / `clear_draw_started()` | boundary test at exactly 0.1 and 0.0999; mutations X35, X38, r16 caught |

Found and fixed while verifying this round:

- **A render request was lost when a draw was skipped.** One screenshot run
  (machine heavily loaded) left a hidden lesson card in the HUD texture: the
  request booked for the next frame was cancelled by frame number although
  that frame had not been drawn. Requests now stand until a draw has begun
  after them (see "Every change reaches the texture"); a pixel check turns
  the render loop off for 4 frames around a change.
- **The panel maths became a product of rotations.** A single-band panel's
  basis was no longer exactly the identity, and a ray at the menu's very
  edge missed (`test_hits_land_on_the_right_pixel...` caught it). The home
  basis is again a single rotation.
- **Two of my own new checks were vacuous or too tight at first:** the
  "prey cue appears beside a threat cue" check counted frames, and 40 fast
  headless frames are only 60 ms (it now watches 0.8 s and requires ≥ 20
  counted frames); a caught target's cue fades rather than vanishing (gone
  in 0.8 s, half in 0.25 s).

### Where the verifiers' earlier probes stand

All pass except the same three round-1 checks that round 2 changed on
purpose (both round-3 verifiers confirmed these): a single-click Quit to
menu (now a hold), the hard-coded −19° HUD elevation (now bands at +13° /
−40°), and aim controllers expected to survive a switch to scripted
sources (now freed). Logs: `artifacts/ui/verify/r3fix_probe_*.log`,
`r3fix_render_*.log`.

- headless: `ui_r3x_experience` **9/9**, `ui_r3eng` **8/8** (against the
  real GameLoop), `ui_r2_experience` 10/10, `ui_probe_r2` 5/5,
  `ui_probe_hud` 5/5, `ui_probe_phantom` 2/2, `ui_probe_pointer` 6/6,
  `ui_probe_scale_onboarding` 6/6, `ui_probe_text` 2/2, and the rest of
  `ui_probe_flow` (5/6), `ui_probe_geometry` (2/3), `ui_probe_test` (7/8);
- pixel-level with Forward+: `ui_probe_render` 1/1, `ui_r2_physics_render`
  4/4, `ui_r2_stale` 2/2.

The experience verifier's note on U7 (a keep-alive booked while the HUD is
hidden survives `show_panel`) describes intended behaviour: its only
caller is the respawn size penalty, which is announced while CAUGHT and
must be seen once the bird is back in the air (the verifier's own probe
shows the notice is seen and the HUD then goes idle).

## Fix round 2: what the verifiers found and what changed

| Finding (severity) | Fix | Pinned by |
|---|---|---|
| HUD plates cover the gaze when looking down at prey (major) | HUD split into two VR bands: notices at +7..+20°, a narrower strip at −37..−43°; bands turn see-through over the flight path, target and threat (round 3: the notices step aside instead) | `test_hud_keeps_out_of_the_hunting_gaze`, `test_hud_turns_see_through...`; verifier probe `ui_r2_experience` now 10/10 (gaze: 0 % cover at −10..−30°, 0 % of a held −26° gaze) |
| Food chain contradicts "ignore the smallest birds" (major) | Prey = worthwhile; DUST relation (greyed); Hunt / Flee / Ignore lines; tier-up names the worthwhile range and what dropped off | `test_food_chain_presents_only_worthwhile_prey_at_every_size` (0 of 30 masses), `test_tier_up_toast_names...`; verifier probe: 0 cases (was 23) |
| Apex goal and victory invisible (major) | HUD strip, pause line and toasts show the goal; eagle toast states it; Victory headline; Keep flying → `continue_after_victory` | `test_apex_goal_on_hud_and_pause`, `test_victory_is_a_victory...`, `test_keep_flying_without_a_game_loop...`; verifier probe `test_victory_is_presented_as_a_victory` passes |
| Cue flickers for birds near the zenith behind (minor) | Latch on the true mid-plane angle; slide when both sides point alike | `test_bird_high_above_and_behind_does_not_blink`, `test_side_change_near_the_zenith_slides...`; verifier's cases: 0 cuts (was 9) |
| Change after the draw never rendered (minor) | Late requests booked for the next frame; dedup checks the real mode; hide clears the booking | `test_a_change_after_the_draw_is_drawn_next_frame`, `test_hide_and_show_in_one_late_frame...`; `ui_shots` late-change pixel check (1.00 → 0.00) |
| Restart / Quit to menu on a single pull (minor) | `HoldButton` (0.8 s hold, bar, hint) | 3 pointer tests; verifier probe `test_restart_needs_more_than_one_pull` passes |
| Follow behaviour pinned only before the first recentre; speed cap compared to itself (minor) | Glance after the recentre must not move the panel; literal 110°/s; recentre ≥ 0.75 s | `test_panel_is_lazily_head_following...` (mutations S and AR caught) |
| DEADBAND / ALPHA_RATE unpinned (minor) | Literal thresholds (≤ 1 reversal, < 0.01 p2p, ≤ 1 per 0.25 s incl. fade-in) | mutations B and C caught |
| Onboarding turn / dive thresholds and PLAYING guard unpinned (minor) | Negatives that check no lesson completed; live gate also on wingbeat and catch events | `test_weak_or_wrong_gestures...`, `test_lessons_only_count_while_playing` (I, J, K caught) |
| Visible behaviours unpinned: BC, AT, Q, AG, countdown (minor) | One test each | mutations caught |
| Real XR action mapping untested (minor) | Headless `XRControllerTracker` test in the suite | `test_xr_controller_actions_drive_the_ui`; typo mutations n17/n18 caught |
| `attach_rig` orphans aim controllers (minor) | Reuse for the same rig; release (free) replaced XR sources; release on UI exit | `test_attach_rig_is_idempotent`; verifier probe passes |
| Test kit's settings backup races between processes (minor) | Cross-process lock (atomic mkdir + PID), taken lazily when a test first writes a setting (`Events.settings_changed` fires before the save). A live holder is waited for; only a dead or ancient holder's backup is restored; tests that never write settings never lock, so concurrent runs do not starve each other | `ui_test_kit.gd`; ran alongside the mutation harness and the verifiers' probes |
| Dead code (minor) | `UIProgress.load_from` removed; `_threat_level` now used (see-through); `button_ids` kept and used by the victory test (the verifier's probe uses it too) | |
| Mutation harness edits the shared tree (minor) | Sandbox-only harness | `artifacts/ui/mutations/mutate.py` |
| Summary stat values crowd (minor) | Rules between columns, wider gap; no repeated Best on a new record | `test_new_best_replaces_the_best_column` (gap 100 px, rule present) |

Found and fixed while verifying this round:

- A request cancelled by a hide was deduplicated against the next show. My
  first late-frame fix exposed it: the pause screenshots showed the caught
  screen. It is now pinned.
- A keep-alive and a celebration survived the HUD being hidden, and replayed
  and rendered into the next flight.
- The tier-up burst drew over the strip; it is now clipped to the notice
  band.
- The hold bar was accent on accent, so it could not be seen.
- The shots' stand-in birds were placed underground.

### Where earlier probes now disagree (by design)

Three round-1 verifier probes encode behaviour that round 2 was asked to
change. All other probes pass:

- headless: `ui_r2_experience` 10/10, `ui_probe_r2` 5/5, `ui_probe_hud`
  5/5, `ui_probe_phantom` 2/2, `ui_probe_pointer` 6/6,
  `ui_probe_scale_onboarding` 6/6, `ui_probe_text` 2/2, and the rest of
  `ui_probe_flow`, `ui_probe_geometry` and `ui_probe_test`;
- pixel-level with Forward+: `ui_r2_stale` 2/2 (the ghost card is gone:
  alpha 1.00 → 0.00), `ui_r2_physics_render` 4/4, `ui_probe_render` 1/1.

- **`ui_probe_flow_test.test_quit_to_menu_from_pause_while_caught`** clicks
  Quit to menu once. It is now hold-to-confirm, as the experience verifier
  asked.
- **`ui_probe_geometry_test.test_hud_during_realistic_growth`** hard-codes
  the old −19° HUD elevation. The HUD frame is now the strip band at −40°
  (asked for by the experience verifier). The probe's own measurement
  shows the elevation held within 0.0004° while growing.
- **`ui_probe_test.test_contract_process_mode_and_group`** expects the aim
  controllers from the kit's first `attach_rig` to remain after the kit
  switches to scripted sources, which were the orphans the engineering
  verifier asked to free. The contract part (UIAim_* names, `aim` pose,
  PROCESS_MODE_ALWAYS, rig not scaled) is now asserted by
  `test_attach_rig_is_idempotent` on a real-source UI.

## Fix round 1 (summary)

- Curved panels and 60 px body text (text below 1.5° at panel edges).
- Latched cue side and cuts instead of sweeps (a hawk on your tail).
- The fresh-pull rule (phantom clicks).
- The apex summary layout.
- Records from GameLoop ("New best!").
- Truthful viewport modes (U7 tests).
- Minor items: articles, toggles, growth drift, the stencil occluder
  contract, pause on focus loss, colour-compensation tests, the tip per
  pause, status lines, species silhouettes, the Quest Pro controller card.

## Dev scene

`scenes/dev/ui_dev.tscn` runs the whole UI stand-alone against mocks (and
UI-owned stand-in birds), on desktop or in the simulator.

- **Keys:** 1 menu, 2 play, 3 pause, 4 caught, 5 end, 6 tier up,
  7 settings, 8 how to fly, 9 shrink, 0 become the eagle, A apex catch (the
  fifth wins), Esc menu button.
- **Arguments:** `--demo` (tour incl. a tier-up in a 14° climb, a chase
  with both cues, the eagle, apex catches and victory),
  `--shots`, `--ui_autoclick`, `--fidelity`, `--occluders`,
  `--panel_pitch`, `--quit_after`.
- **Compile check:** `scenes/dev/ui_compile_check.tscn`.

## Contracts used and offered

Noted under "Contract changes" in ARCHITECTURE (dated ui notes; this
round's is "2026-09-27, ui (fix round 6)").

- **Core contracts read:** `Bird.velocity`, `Bird.get_forward()`,
  `Bird.mass`, `SizeRules`, `Birds.player()`, the `player_rig` group,
  `Events`, `Game`, `Settings`, `VR`; `PlayerBird.telemetry()` including
  the documented extras `pitch_input` (the speed lesson) and `body_yaw`
  (the HUD's centre line, round 6), each tolerant of absence.
- **GameLoop, duck-typed:**
  - Calls: `start_run`, `restart_run`, `quit_run`,
    `continue_after_victory`, `get_run_stats`; the catch lesson's
    `request_lesson_prey()` (at its start, and again at each help step),
    `release_lesson_prey()` (when it ends, and when a run ends),
    `lesson_prey()` (read each frame while it is taught).
  - Signals: `apex_progress`, `apex_reached`.
  - Keys read: `time`, `score`, `max_mass`, `max_tier`,
    `catches_by_species`, `lives`, `lives_max`, `respawn_in`,
    `new_records.score`, `records.best_score`, `victory` / `reason`,
    `apex.{catches, needed, victory}`, `endless`.
  - Without a GameLoop the UI still drives `Game` states.
- **Menu button:** `Events.menu_requested` for either controller's
  `menu_button` and for Escape (debounced 250 ms); VR's focus handling
  emits it first, and UI then ignores `session_unfocused` once paused.
- **For VR/flight:** `UIPanel.mark_occluder(material)` on hand, wing and
  controller materials (the VR wing shader writes stencil 64 itself).
- **HUD placement:** the HUD panel's centre line is where the body faces
  (`UIRoot.body_yaw()`: telemetry `body_yaw`, else the facing held when
  steeper than 60°; smoothed τ `HUD_BODY_SMOOTH_TAU` 0.2 s, dead zone
  `HUD_HEADING_LEASH_DEG` 6°, eased τ `HUD_HEADING_TAU` 0.2 s at ≤
  `HUD_FOLLOW_MAX_SPEED` 90°/s); bands at +8..+20° and −37..−43°, nothing
  between. The lesson card lives 9.7–42° right of the centre line (band
  yaw `HUD.NOTICE_YAW` −25.9°) or at the mirror placement
  (`HUD.NOTICE_MIRROR`); a celebration where the player looks
  (`HUD.TOAST_VIEW_DEG` 45, `TOAST_HOME_BIAS_DEG` 5). Without a player
  bird the HUD follows the head past `UIRoot.HUD_FOLLOW_DEADZONE_DEG`
  (55°). `UIRoot.flight_yaw()` is the flight path's heading (diagnostics,
  tests).
- **Cues:** drawn over the HUD (`HudIndicators.CUE_RENDER_PRIORITY` 11,
  desktop layer `CUE_DESKTOP_LAYER` 6).
- **Aim controllers:** the rig's own `XRController3D` on each hand's
  tracker with pose `aim` (flight's `LeftAim`/`RightAim`) if present; else
  `UIAim_<hand>` added and freed by the UI.
- **Real threat:** `UIRoot.REAL_THREAT` (0.1) / `is_real_threat(level)`.
- **UIPanel (additive):** optional band `"yaw"`, `set_band_offset`,
  `band_offset`, `band_placement`, `level_direction`, `band_frame_pixel`,
  `band_frame_direction`, `band_mesh`; `yaw_source`, `source_smooth_tau`,
  `source_leash_deg`, `source_tau`, `source_max_speed_deg`, `source_yaw()`,
  `panel_yaw()`, `anchor_error()`, `HEAD_JUMP_M`; test hooks `note_draw_started`, `clear_draw_started`.
- **HUD (additive):** `notice_rects()`, `gaze_level()`,
  `toast_view_angle()`, `lesson_labels()`, `toast_labels()`.
- **Time hooks:** `HUD.advance`, `HudIndicators.step`,
  `SettingsScreen.advance` (the frame loop calls them; tests drive them
  in synthetic time).
- **Highlights:** any bird `model` with `highlight`.
- **Telemetry keys** the lessons read: `wing_extension`, `flapping`,
  `airspeed`, `vertical_speed`, `bank`, `tucked`, `perched`, `pitch_input`
  (PlayerBird: WingState.pitch). A provider without `pitch_input` never
  completes "Tilt for speed" (that lesson then moves on after its 45 s
  timeout, and is offered again next session). UI adds no Settings keys.

## Known limits

- **A gaze along the flight path is not the resting gaze.** The HUD sits
  where the body faces. When the path crabs 20–30° off in the breeze, a
  player who turns their head to look along the path sees the card's far
  words past 45° (the round-6 verifier's "looking along the path" check:
  in view about 25 % of the real tutorial, where it counts the 3D path,
  60° up in a climb). The two cannot both hold with a crab bigger than
  about 10°: a card in view of both gazes would have to sit on the path.
  The body wins: it is where a head at rest looks, and it does not swing.
- **The flight path does cross the card** now and then, since it is kept
  clear, not followed: a slow bird's crab puts it in the card's column
  and each flap climb sweeps it through the band; a real threat's cue
  chevron sweeps over it too. Each crossing is a see-through blink (the
  path is never behind the readable card longer than 0.056 s), never a
  move unless something stays: 1 in the recorded real tutorial, 10-12 in
  54 s of hard manoeuvres (read in view 86.4-86.5 % there, 0 moves), 1-2
  in a live 35 s tutorial (six bot seeds). The verifier's "the card's
  words never come within 6° of the real path" cannot hold for a card
  beside the body, only for a card that follows the path.
- **A passive player's catch lesson** (majors round): the lesson asks
  GameLoop for its prey again every 30 s, but GameLoop places the swarm at
  least 20 m ahead (the AI's `MothField`: `maxf(28 - 6 x help, 20)` m) at
  the player's height; a bird cruising an orbit that never steers at prey
  passes it 8-13 m off and the lesson ends by its 300 s timeout (three
  seeds, `ui_lesson_real.gd`). Placing the swarm on the player's predicted
  path, nearer at the higher help levels, is the game loop's (requested in
  ARCHITECTURE's majors-round note). A player who steers at the cue, even
  late and clumsily, is done in 13-87 s.
- **Lesson prey do not glow yet.** The words say "It glows: fly into it"
  only if the bird's model has a `glow` that is on (duck-typed; none has
  one yet); until then they say "Fly right into one" (GameLoop's ring
  marks them).
- **The torso estimate is flight's.** `body_yaw` comes from WingInput (the
  line between the hands, the head when the hands say little). With arms
  tucked for a while it drifts towards the head (τ 4 s), so the HUD may
  drift with it in a long dive with the head turned. How it behaves with
  a real player's arms needs a Quest Pro session; the integration bot's
  torso never turns.
- **After a torso turn** the HUD needs about a second to come round
  (30°: within 1° after 1.03 s); meanwhile the card sits nearer the gaze
  (its farthest word 19° from it at the closest, `notice_torso_turn.png`).
- **Notices are read with a head turn.** The card's words are 9–33°
  right of the centre line (every word within 34.9° of a level gaze); a
  celebration at home ends 41° out. Whether a right-hand home suits
  left-handed players needs a headset session.
- **Looking down along the path.** The notices stay above the horizon (out
  of the hunting gaze), so with the gaze more than about 8° down a
  celebration's far words are past 45°: it waits (at most 3 s) for the
  player to look up.
- **A lesson card can stay on the left** once moved (until the next card
  appears where it is clear).
- **Cues can sit over a notice's text** while the player reads it (the
  cue ring turns with the head; the chevrons draw on top).
- **Target colours differ between areas.** The birds area tints a target
  blue-violet and a threat magenta; the UI's prey and danger colours are
  teal `#5fe0a8` and coral `#ff6b5e` everywhere, chosen for ≥ 4.5:1 text
  contrast on the panels. Integration should pick one language.
- **Real trigger and buttons on hardware** are untested on the device
  (headless OpenXR-style trackers and the simulator's fixed controllers
  are).
- **Notices above the horizon** can hide sky birds that are neither the
  target nor a threat while a lesson card or celebration is up.
- **The strip needs a glance down** (−37..−43°, the lower edge of a Quest
  Pro's view when looking level).
- **Tonemappers:** ACES and AgX get no colour compensation; Filmic white 6
  on the Mobile renderer caps the brightest colour at sRGB 235.
- **Per-frame HUD rendering during celebrations** (every frame of the 3.2 s
  animation) and about 15/s while a lesson card animates; fades and moves
  of whole bands cost nothing.
- **Recorded flights.** `ui_flight_runs.json` (FlightModel) and
  `ui_game_flights.json` (the real game) must be re-recorded after a
  change to flight, the world's wind or the integration bot
  (`ui_flight_record.tscn`, `ui_game_record.tscn`); otherwise the suites
  test against an older flight.
- **Test speed:** see "Perfection criteria" (the end-to-end lesson test
  now runs its live clock 4x fast); the real-time parts (grace windows,
  holds, tick gaps) push it over 60 s on a heavily loaded machine (62.5 s
  at load 12-28).
- **Old probes:** see "Where the verifiers' probes stand" (round 6).
- **Placeholder world** in screenshots (`UIBackdrop`, `UIStandInBird`);
  whole-game views belong to integration.
