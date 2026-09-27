# AI area — a living sky

NPC birds that fly the same size-physics as the player, hunt what they can
eat, flee what can eat them, flock, perch, soar thermals and hide. The
Ecosystem keeps about 60 of them alive around the player as it grows from
sparrow to eagle.

Owned files: `scripts/ai/`, `scenes/ai/`, `tests/unit/ai/`,
`scenes/dev/ai_*`, `tests/shots/ai_*`, `artifacts/ai/`, this doc.

## What was built

| File | Class | Role |
|---|---|---|
| `scripts/ai/npc_flight.gd` | `NpcFlight` | Point-mass flight with an energy budget, derived from `SizeRules.performance(mass)`: glide polar, power, coordinated turns with a load-factor limit, tucked and spread dives, energy trade (zoom), stall recovery, and an air brake (`air_brake`, up to 2 g at cruise). A per-effort level-speed table is memoised per 0.5 % mass bucket. `climb_gradient(v, effort)` gives the steepest steady climb. Pure RefCounted. |
| `scripts/ai/npc_bird.gd` | `NpcBird extends Bird` | The body. It flies `NpcFlight` in the air mass, and its displayed attitude is rate-limited (≤ 10 rad/s per axis). Calm birds in open air integrate at 36 Hz (24 Hz far away) and coast in between; engaged birds and anything near geometry run every tick. It has a safety net: a terrain-following ground clamp, a bounds and ceiling clamp, a swept collision on layer 1 that looks 0.3 s ahead and tells the brain (`on_imminent`), push-out, and a stuck/wedged watchdog that backs a wedged bird out along its breadcrumb trail (`escape()`) and flags one it cannot free (`trapped()`). Contacts are counted in `geo_hits`, `ground_hits` and `bounds_hits`. Other parts: perching (seat one body radius above the grip point), hiding, energy (Kleiber endurance), hunger, digestion, the strike lunge and LOD. Flares are kinematic legs, and each is checked before it starts and cancelled if its next step would hit geometry. |
| `scripts/ai/npc_brain.gd` | `NpcBrain` | Utility AI. **Think** senses threats by awareness, blind zone, reaction time and *intent*: a hunter after another bird is fled only if it is coming at me. It chooses prey by worth over effort and applies give-up rules (chase budget and cap by meal size, failed passes, stamina, a stamina race between near-equals, a home leash, a quarry that hides or has been out of sight for 1.5 s). A hunter rests after a failed chase. Hiding is bounded, and only in cover the pursuer cannot follow into. **Steer** handles boids and the murmuration, thermals, perch approach and flare, pursuit and stoop (only at prey in open air), flee with jinks and refuge entries through openings (every leg checked), and leaving cover or a building through its opening. Overlays keep it clear of predators and smaller birds and away from obstacles (memory of the obstacle's plane, wall-following, a speed that fits the room, the air brake), bounds and the ground (kept above roofs and crowns near geometry; tired birds turn off slopes they cannot climb). |
| `scripts/ai/habitat.gd` | `Habitat` | Shared cache of the World contract. It holds landmarks, live thermals and *copies* of the world's refuges linked to their openings. Perch search offers only seats clear of geometry (`seat`, `seat_clear`). It provides ray, sweep and rest queries, refuge choice (`pick_refuge`: cover the bird fits and its pursuer does not, in sight, never shut), `indoors()`, `roofed_in()`, `exit_near()`, `top()`, a cached ground grid (`ground_fast()`) and learned lift. |
| `scripts/ai/flock_group.gd` | `FlockGroup` | Goal and mood for the murmuration and for loose flocks, which roost in their home range. Waypoints sit above whatever stands there. |
| `scripts/ai/species_profile.gd` | `SpeciesProfile` | Temperament per species. |
| `scripts/ai/ecosystem.gd` + `scenes/ai/ecosystem.tscn` | `Ecosystem` | Keeps `max_npcs` (60) round the player, deterministic per seed. The plan holds worthwhile prey, dust, near-equals, 9 **threats** (birds that would hunt the player), 8 giants and the murmuration. Life follows the player's *sky*: a player circling an area keeps its birds, and one that travels gets new ones on its flanks. A jump of more than 40 m in one step is a respawn, and the sky restarts there. Spawns happen out of view and beyond the near distance. There is prey upkeep near the player, plus LOD, `reset()` and `stats()`. A bird still trapped after its escape is removed out of view (`stuck`). |

Test and dev support (not shipped):
- `scenes/dev/ai_test_world.gd` is the AI arena.
- `scenes/dev/ai_dev.tscn` is the dev scene.
- `scenes/dev/ai_diag.tscn` is the measurement harness (laps and travel, contacts, perch outcomes, traces).
- `scenes/dev/ai_realworld_check.tscn` runs the world area's real valley.
- `scenes/dev/ai_probes/` holds copies of the round-3 verifiers' probes (output redirected to `artifacts/ai/fix_r3/verifier_probes/`) and this round's tracing diagnostics (`ai_grind_trace`, `ai_bonk_diag`, `ai_wall_trace`, `ai_trace`, `ai_thermal_trace`, `ai_perf_prof`, `ai_refuge_count`).
- The test helpers in `tests/unit/ai/`:
  - the catch checker (strict stand-in);
  - the mock player (with a gaze that can turn away from the heading);
  - the seeker player, a player that hunts with the NPC flight physics and collides with the world;
  - the safety monitor;
  - the warning log, which attributes engine warnings to AI code by the innermost frame;
  - the plots.

## Core loop round (2026-09-27): pellets, careless prey, the attacker on call

The lead's direction for the core loop ("agar.io in the sky"), the AI's
part of it. The game loop owns the pacing evidence (docs/areas/GAMELOOP.md,
"Core loop round"): whole 30-minute runs of the real game played through the
real flight chain.

- **Moth swarms - the pellets** (`scripts/ai/moth_field.gd` `MothField`,
  `moth_swarm.gd` `MothSwarm`, `swarm_moth.gd` `SwarmMoth`). The
  Ecosystem's child keeps `MothField.swarms_for(max_npcs)` swarms (5 at 60
  NPCs, 4 at the Quest's 28) of `SWARM_SIZE` (8) moths about the player
  while a moth is worth its chase (`SizeRules.is_worthwhile`), and
  `AMBIENT` (1) once it has outgrown them (life, and food for the sky's
  wrens and sparrows). A swarm is placed **in open air**: a disc of the
  cloud's reach plus `SWARM_CLEAR_M` round its anchor clear of the world's
  geometry (spheres at the anchor and on a ring, as tall as the height over
  the highest surface allows), not indoors, inside the valley, 5-13 m over
  the highest surface under it and near the player's own height; **along
  the player's path** - 70% of the tries ahead of its flight (within 60
  deg), the rest over the open places moths gather (meadow, fields, the
  village, thermals, the lake, glades, orchard, rides); never nearer than
  40 m, and where the player looks only beyond the reach of its moths'
  edible marks (6 s of its flight: nothing appears in view). A swarm left
  behind (90 m and behind the flight, or 170 m) or eaten out (after 4 s) is
  placed ahead again, one a second at most. Moths are real `Bird`s (the
  catch rule, the target cue, NPC hunters and audio see them) without a
  brain or a flight model: the swarm moves them - a slot in a loose,
  slowly turning cloud round a centre that wanders within `ANCHOR_R` (4 m)
  of the anchor, a flutter, never faster than `MOTH_SPEED` (2.2 m/s; a
  sparrow cruises at 9) - so a moth costs a transform and a wingbeat a
  tick (the Ecosystem's "flocks" part of the tick: 0.076 -> 0.107 ms at 60
  NPCs in `perf_test`). **Barely fleeing:** a moth notices a bird that
  can eat it only within `AWARE_M` (2.5 m) and coming at it, reacts after
  `REACT_S` (0.35 s) and darts `DART_S` (0.45 s) across its line at
  `DART_SPEED` (3.5 m/s), at most once every `DART_COOL_S` (4 s). A player
  flying straight at it arrives before it can dart. **A swarm moth weighs
  `PELLET_MASS` (6 g**, half again the ladder's 4 g moth; core loop round,
  second pass): with 4 g pellets a sparrow outgrew them at 40 g, half-way to
  the swallow, the target cue rang wrens instead (a wren is worth seven 4 g
  moths) and through the real chain only 5 of 17 of a sparrow's catches
  were pellets (`cl3_it8`). A 6 g moth grows a sparrow ~20%, outweighs a
  wren for the cue at equal distance until ~40 g, and is dust from 60 g:
  about one swarm to the swallow.
- **The catch lesson's prey** (`Ecosystem.request_lesson_prey(near, dir,
  help)`, `stop_lesson_prey()`; the game loop's `request_lesson_prey` /
  `release_lesson_prey` call them - the UI's contract is in GAMELOOP.md):
  a lesson swarm of five moths that never dart, 45 m ahead of the player's
  flight at its height (at most `LESSON_MAX_AGL`, 40 m, above the ground -
  fix round 1: at 13-19 m a player cruising 80 m up had them out of its
  target range) in open air, kept ahead of the player, 12 m nearer at each
  help. Its moths carry `SwarmMoth.lesson`, which the target cue prefers
  while the lesson runs (GAMELOOP.md, "Lesson prey").
- **Careless prey** (`NpcBrain`, the lead's direction: "prey fleeing from
  the player: short reaction delay, limited burst stamina, unaware when
  perched/feeding until close"): a bird notices the player coming at it
  only within `PLAYER_AWARE_PERCHED` (0.45) of its awareness on a perch,
  `PLAYER_AWARE_CALM` (0.7) about its business in the open (wandering,
  flocking, soaring); it bolts `FLEE_PLAYER_REACT_S` (0.25 s) later than its
  own reaction time; its sprint away from the player lasts
  `flee_burst_s()` - `FLEE_PLAYER_BURST_S` (2 s) x the square root of its
  body time, x up to 1 + `FLEE_PLAYER_NEAR_EQUAL` (1.5) for a near-equal -
  then it flags at `FLEE_PLAYER_FLAG_SPEED` (0.8) of its cruise and
  `FLEE_PLAYER_FLAG_EFFORT` (0.55), in the open, to cover or in a jink,
  until it has rested (the burst comes back at half real time).
- **The attacker on call** (`Ecosystem.send_attacker(player)`, for the game
  loop's danger director): of the birds that would hunt the player
  (`would_hunt`), can hunt now (not digesting, resting, fleeing, hiding or
  already hunting) and are between `ATTACK_MIN_M` (22 m) and their hunting
  range, the one nearest `ATTACK_BEST_M` (50 m) is sent
  (`NpcBrain.begin_hunt`: its own pursuit, stoop, committed pass and
  give-up rules). With none in range, the farthest one out of view is
  recycled and one of the plan's hunters is brought in out of view at its
  near distance - a sparse sky (the Quest tier's 28 NPCs) has few raptors
  near the player. Second pass: the bird brought in is one of the plan's
  hunters that **would hunt the player** (not an eagle for a swallow), and
  with the sky full and no far hunter to swap, **the farthest idle bird out
  of view makes room** (the rebalance's rule) - real-chain runs had waited
  60-70 s after the first flight for a director that found nobody to send.
  `stats()["attacks_sent"]`; `stats()["attack_fails"]` counts why a call
  came back empty (`no_hunter_planned`, `no_room`, `no_spawn_spot`,
  `brought_cannot_hunt`, `refused`; `last_attack_fail` for the loop's log).
- **Dropped swarms die first** (second pass): the field drops its swarms
  when the player outgrows the pellets; their moths are now marked dead
  before they leave the tree, and a hunter's strike lets go of a bird out of
  the tree (`NpcBird._strike`). A Quest-tier real-chain run logged
  `get_global_transform` on a moth a wren was striking at that moment
  (`cl3_it11` quest 105).
- **The murmuration never hunts the player** (`NpcBrain._murmuring`): its
  starlings carried danger marks round a sparrow-sized player now and then
  as one broke off after it; the murmuration is the sky's harmless
  spectacle.

Pinned by `tests/unit/ai/moth_test.gd` (a swarm drifts slowly round its
anchor; a moth barely flees - its reaction, dart and stamina - and a lesson
moth never; the field keeps its swarms along a travelling player's path,
never nearer than 40 m and never in view within its marks' reach, and one
once it has outgrown moths; the lesson prey waits ahead; the sky sends an
attacker, and brings one in when none is in range) and
`tests/unit/ai/player_test.gd`
(`test_prey_notice_the_player_late_when_perched_or_about_their_business`,
`test_prey_fleeing_the_player_flag_after_their_burst`).

## Integration round 1 (the integration fixer, 2026-09-27)

The whole-game verifiers found three things in the AI's part of the composed
game. Each is fixed here with a test that fails without the fix
(`docs/INTEGRATION.md` §8 has the measurements and the mutation runs).

- **The sky looked empty from the player's eyes** (experience, major).
  Straight ahead a cruising sparrow had on average 0.15 NPCs in view and
  0.05 big enough to notice; 0.0 at the Quest tier (28 NPCs). The birds
  were there, but beside and behind a flying player: homes spread over the
  area a lapping player circles, and it flies on past them (a census:
  bearings 90-175 deg from the flight direction for most of the 60).
  - *The show (Ecosystem):* up to `SHOW_FLOCKS` (2) loose flocks or the
    murmuration and `SHOW_SOLOS` (5, at least `SHOW_SOLOS_MIN` 5) free
    solo birds are homed on a point ahead of the player's flight
    (`SHOW_AHEAD` x its sky, 36-110 m; on a lap, round the lap's own
    curve), re-placed when the player turns away from it (45 deg, at most
    every 2 s). Only life and scale take part: roles ambient, giant, peer,
    dust, extra - never the player's prey or threats (the loop's pacing
    rests on those) - and only species that can keep up (cruise at least
    0.95 x the player's). Candidates are ranked by distance over visible
    size (a gull shows from 180 m, a sparrow from 40), the murmuration
    first; members keep their place against a newcomer up to 1/0.6 better
    placed; a bird hunting, fleeing, hiding or perched leaves the show.
  - *Flocks in the show* wheel near the player's height
    (`FlockGroup.show_alt`), their home glides after the point at 0.85 x
    1.1 x its cruise (`FlockGroup.home_goal`, `SHOW_HOME_SPEED`: a
    home that jumped ahead made the whole flock sprint, tire and roost; at
    0.85 x a flock could not get ahead of a travelling player again after a
    turn), they fly at effort 0.7
    (`NpcBrain.SHOW_FLOCK_EFFORT`, not 0.9) and roost only after 90 s.
  - *The murmuration forms at any budget:* at least `N_MURMURATION_MIN` (8)
    starlings (the Quest's 28 NPCs planned 6, under the species' flock
    minimum of 12, and its starlings flew alone), the extra taken from the
    near-equals, never from the prey.
  - *Pinned:* `tests/unit/integration/sky_view_test.gd` - the real game,
    the bot flying a lap and straight legs (a 45-75 deg turn every 25 s) at
    both tiers, 90 s each: birds a player notices (>= 0.37 deg across,
    106 x 90 deg view along the flight). Full tier: a mean of at least 1.5,
    one in 55 % of the seconds; Quest tier: 0.75 and 35 %. Measured over
    four skies: full 2.0-4.2 lapping and 4.6-7.9 travelling, one in 60-99 %
    of the seconds; Quest 1.4-4.5 lapping and 0.9-2.6 travelling, one in
    41-88 % (without the show: Quest 0.4-0.5 / 28 %, full travel 0.7 / 20 %;
    the verifier: 0.05 / 0.0). The Quest's 28 NPCs are the limit: its show
    is the murmuration and a few big birds. A diagnostic census:
    `tests/shots/integration_diag_sky_test.gd`; head-view images
    `artifacts/integration/sky_{quest,full}_*.png`.
- **No pilot flying the real player bird ever caught a fleeing bird**
  (experience, major; 0 of 83 chases in the verifier's probes).
  A competent pilot through the real chain (arm gestures -> WingInput ->
  FlightModel; `tests/unit/integration/integration_chase_pilot.gd`) hits
  10 of 12 hovering targets, but a fleeing wren re-aimed its escape every
  ~0.25 s away from where the player was heading - it weaved with every
  correction, the player's turns lagged ~0.35 s and never closed the last
  3-4 m; and it out-turns a sparrow-sized player (280 deg/s against ~160).
  One-on-one lab (`tests/shots/integration_chase_lab_test.gd`, 12 chases of
  30 s each): 0 of 12 at full evasion, 0 of 12 with the turn limit alone,
  3 of 12 once the escape line is held (closest approach median 4.6 m ->
  1.1-2.1 m).
  - *Fix (NpcBrain + NpcFlight):* a bird fleeing the **player** holds each
    escape line `FLEE_PLAYER_REAIM` (10) x its reaction time and turns no
    tighter than `FLEE_PLAYER_TURN` (0.55) of its turn rate
    (`NpcFlight.turn_scale`, from `NpcBird.want_turn`). It still flees at
    full speed, jinks and takes cover; other hunters are unaffected.
  - *Pinned:* `tests/unit/integration/chase_fleeing_test.gd` (12 fleeing
    wrens: median closest approach under 3.5 m; the final code catches 5 at
    1.76 m, without the rule 0 at 4.5 m) and
    `tests/unit/integration/game_catch_test.gd` - the real game, nothing
    staged, the assist the game's own: following the target cue a competent
    pilot made 3-5 catches in 6 minutes on four seeds, most by the base rule
    (the verifier: none in ~25 minutes). That count holds without the rule
    too: whole-game catches are mostly of birds not yet fleeing.
- **An NPC on the player's spawn perch** (engineering, confirmed): a
  respawn found it taken and the player hovered beside it.
  `Habitat.find_perches` (every NPC perch choice goes through it) never
  offers the perch at `World.get_player_spawn()`
  (`tests/unit/integration/spawn_perch_test.gd`; `game_flow_test` now
  requires the respawn to be perched).
- **Calm birds integrated in lockstep** (Quest, minor): a sky spawned in one
  tick integrated on the same ticks (even ticks 0.84 ms, odd 0.50). The
  Ecosystem gives each bird it spawns a tick phase
  (`NpcBird.set_tick_phase`, applied once, only to a calm bird that has
  lived 1 s: applied at spawn it made a hawk placed in a crown pocket coast
  a tick deeper into the branches). `tests/unit/ai/tick_phase_test.gd`:
  the busiest tick carries 1.04 x the mean (was ~1.25-2 x).
- **A steep descent onto a low perch entered its flare 45 deg nose-down**
  (found by `landing_test` once tick phases moved): a bird approaching a
  perch now holds its body no steeper than 0.5 rad nose-down
  (`NpcBird._body_pitch`, `APPROACH_PITCH_MIN`), as its flare legs already
  did.
- **The latent SCRIPT ERROR** (`npc_brain.gd:602`, a flock mate's freed
  threat): read untyped and checked; `Ecosystem._remove` also clears other
  birds' `threat`/`target`/`strike` (`flee_test.test_alarm_from_a_freed_hunter_raises_nothing`,
  `ecosystem_test.test_a_removed_bird_leaves_no_references_behind`; the
  whole-game kit no longer hides it).

- **The suite's valley soak runs 240 s** (was 90 s): with the show one
  seed's first 90 s made 3 catches by one species (the test asks for two).
  Noise, not a change: the 10-minute soak made 42 NPC catches by 8 species
  with the show and 42 by 7 without it (`--rw_soak_s=600`, same seed), and
  240 s gives two whole 2-minute windows (17 catches by 7 species). (A show
  bird that gets hungry still hunts, and so leaves the show.)

Suite: 76 of 76 (840 assertions, 218.9 s at load 6.6-7.6; `tick_phase_test` added), the known
limit below stands (the soak's 150 s more account for ~20 s). The game loop's pacing evidence ran the AI before
these changes: its `ai_code` must be regenerated (ARCHITECTURE, "integration
round 1").

## Integration round 2 (the integration fixer, 2026-09-27)

Three more findings in the AI's part of the composed game, each fixed with
a test that fails without the fix (`docs/INTEGRATION.md` §9 has the
measurements; `artifacts/integration/round2_mutants.txt` the mutation runs).

- **An attack on the player could not be evaded through the real chain**
  (found with integration's real-chain pacing runs; it is what made the
  verifiers' pilots lose 3-4 lives a run). A competent person model (the
  game loop's own modelled player, SimPilot's rules, flying the real
  PlayerBird: evading from the threat cue at 0.31 and breaking across each
  attack run) was caught in every death while evading, after 2-6 s of
  warning at cue levels 0.6-0.9, from behind (126-180 deg): a hunter
  steering by proportional navigation every tick homes on every correction
  a person's arms make ~0.35 s late. The mirror image of round 1's
  flee-from-the-player rule:
  - *Fix (NpcBrain):* the last `HUNT_PLAYER_COMMIT_S` (0.4 s) of an attack
    on the **player** is a committed pass, as a raptor's strike is: within
    that time to contact (or while the gap opens, after a miss) the hunter
    holds its line, re-aiming only every `HUNT_PLAYER_REAIM` (3) x its
    reaction time, and turns no tighter than `HUNT_PLAYER_TURN` (0.8) of its
    rate (`NpcFlight.turn_scale`) - a break at the right moment makes it
    overshoot. Further out it pursues as ever; it still picks the player,
    sprints, stoops and strikes; NPC-on-NPC hunts are unchanged.
  - *Tuned through the real chain* (whole runs of the person at both
    tiers; `artifacts/integration/pacing/`): a first version committed the
    whole pursuit - 0 deaths in 16 runs; the last 0.8 s at 0.6 of the rate
    caught the person in 3 of 16 runs (`base3`); 0.3 s at 1.0 in 5 of 6,
    one run lost (`sweepB`); **0.4 s at 0.8** in 3 of 6, none lost
    (`sweepA`), the brief's "happens but is avoidable" (at least one death
    in 40 % of the runs, fewer than 20 % lost). The final evidence is
    INTEGRATION.md §9's.
  - *Pinned:* `player_test.test_an_attack_on_the_player_can_be_broken` (a
    crow attacks a swallow-sized player from behind at three offsets; the
    player breaks as a person does - 0.25 s after it sees the run, at 150
    deg/s, at three timings - and escapes 9 of 9; a player that does not
    break is caught every time; with proportional navigation every tick the
    breaks fail).
- **The ecosystem was alive but off-screen** (experience, major): in 12
  minutes of cruising the sky made 130 NPC-on-NPC catches and none within
  60 m inside the player's view; a hunt was in view 2-6 % of the time.
  - *Show hunts (Ecosystem):* every `SHOW_HUNT_S` (12 s) without a hunt
    where the player looks, the Ecosystem sets one up there: prey of a show
    role (never the player's prey or threats) `SHOW_HUNT_MIN_M`..`MAX_M`
    (12-55 m) out within `SHOW_HUNT_VIEW_DEG` (40) of the gaze, and the
    nearest hunter within `SHOW_HUNTER_M` (90 m) that would hunt it anyway
    (`would_hunt`) - never one of the player's threats, never one that
    would hunt the player (a show hunt adds no danger), raptors with height
    preferred (a stoop). The chase is the hunter's own
    (`NpcBrain.begin_hunt(prey)`). A hunter that would hunt the show's
    first flock is homed on the show point with it. Additive:
    `Ecosystem.show_hunts`, `stats()["show_hunts"]`, `["show_hunt_catches"]`,
    `["show_hunt_misses"]`, `show_info()["stalker"]`; `NpcBrain.begin_hunt()`,
    `may_hunt()`.
  - *Pinned:* `tests/unit/integration/sky_hunt_test.gd` - the real game, a
    protected sparrow on the verifier's lap for 5 minutes at each tier:
    at least 3 show hunts set up in view (the mechanism) and at least 3
    hunts readable within 40 m in view (both birds in view for a second).
    Stoops and dives into cover in view are recorded, not pinned (0-3 a
    flight; none at the Quest tier's 28 NPCs, whose sky has few raptors).
  - *What it achieves, honestly:* over three seeds x two tiers, readable
    hunts 28 in six 5-minute flights with the show hunts (1-7 a flight),
    17 without (1-5); a hunt in view 0.7-5 % of the time with them, 1.5-2.4
    % without; NPC catches seen within 40 m 0-1 a flight either way (the
    show's catches mostly happen after the player has flown past). Most
    attempts find no pair (60-94 `no_pair` a flight): for a small player
    every raptor is a threat, and a show hunt never uses one. Relaxing that
    (a raptor hunting a pigeon in front of a sparrow) adds danger in view
    and needs the pacing re-run - open for the AI.
- **The murmuration was 8-13 birds** (experience, minor).
  `MurmurationSwarm` (new): visual-only starlings - BirdModels batched by
  BirdBatch like any bird, never Birds (never prey, threat, target,
  highlighted or caught; no physics) - wheel round the murmuration's own
  NPCs: slots in a flattened cloud (`RADIUS` 4.5 m) that turns about a
  wandering axis, breathes and stretches along the travel; each bird
  follows its slot, so the mass flows. 0.75 per NPC of the budget, 16-45
  (45 on the desktop, 21 on the Quest): ~3 us of BirdBatch's draw sync and
  ~1 us of stepping each a frame on the M1 (Quest tier: ~0.09 ms of the
  frame on the M1). `behaviour_test.test_the_murmuration_has_a_visual_mass`,
  `sky_hunt_test` (it flies in the game); `artifacts/integration/sky_*_murmuration*.png`.

For the game loop: the AI's code changed again; the pacing evidence must
be regenerated on it (ARCHITECTURE, "integration round 2").

## Fix round 3: what changed and why

Two verifiers reviewed round 2. The engineering lens passed it with nine
minor defects. The experience lens failed it on three major defects:

- **A5:** a tired hawk wedged for good in a pocket of tree crowns (and a crow
  inside a tree);
- **wall hits:** birds crashed into walls and trees in front of a player who
  chased them, 1–21 times a minute;
- **refuges:** 82 % of dives went into cover the pursuer could follow into,
  against the brief.

Each was fixed at its causes, and so was every minor defect. Wall hits are
now rare rather than gone (see Known limits).

### Refuges too small for the pursuer (experience, major)

**Cause.** `Habitat.pick_refuge` filtered cover by the fleeing bird's span
only. In the valley most cover a crow or a pigeon fits also fits its pursuer:
house rooms, the barn loft, the belfry, the water tower. The hunter pressed
on after it and could not thread the window, and that fed the wall hits.

**Fix.**
- `pick_refuge(..., threat_span)` takes only cover that the bird fits and the
  pursuer does not (`span <= max_span < threat_span`). This is the rule
  `_hunt_ok` and GameLoop's `CatchRule.in_refuge` already use. With no such
  cover in reach, the bird escapes in the open by speed and jinks.
- Cover must be in sight: the bird must see either the point in front of the
  cover's opening or the cover itself. Dashing round a house for a window on
  its far side had grazed every corner.
- Shut cover is never chosen. That means a room whose window is not linked,
  or a hiding place inside a solid tree crown.
- A hunter gives up a hidden quarry at once, with reason `refuge` when the
  cover is too small for it, or `hid` when it would fit. GameLoop keeps
  hidden birds out of play, and a pursuit cannot thread an opening.

**Result.**
- `realworld_test.test_a_hunting_player_meets_skilled_flyers`, evidence run
  (8 cases, 24 minutes): 101 dives from a known pursuer, **1 into cover it
  could follow into (1 %)**; the bound is 5 %.
- The verifier's `r3x_refuge_fit` probe: 22 dives from a known threat over its four cases, 0 into cover the threat could follow (the verifier measured 82 %).
- `flee_test.test_refuge_choice_fits_and_avoids_the_predator` and
  `test_a_hunter_gives_up_a_quarry_that_hides` (`hid` in 0.01 s, `refuge`
  in 0.1 s) pin the rules. Mutations M22 (any cover the bird fits) and M23
  (keep hunting a quarry hidden in cover the hunter fits) fail them.

### A bird wedged in tree crowns (experience, major)

**Cause.** A tired hawk flew a perch approach into a pocket under three
overlapping crowns, 2.7 m above the ground. Two things held it there:
- its ground clearance kept asking it to climb, into the crown overhead;
- the `unstick()` probes found every way blocked within a metre.

The bird was 365 m from the player, inside `despawn_radius`, and "left
behind" recycling applies only while the player travels, so nothing ever
freed it.

**Fix (four layers).**
1. *Under a roof or crown, the clearance holds height* instead of climbing
   into it (`_ground`).
2. *Perch approaches are checked both ways and for the body.* A ray from a
   waypoint inside a crown does not see the crown it starts in. A perch with
   no open side is not claimed. The check covers the leg the steering
   actually flies: it had checked a 5-m leg while the steering flew an 11-m
   one.
3. *The bird backs out the way it came* (`NpcBird.escape`). Every bird lays
   breadcrumbs where its body was clear (every 0.3 s, 16 kept). On the
   watchdog's second strike it flies a checked kinematic leg back to the
   newest crumb a couple of wingspans away, then on along that line.
4. *Last resort:* if the bird is still trapped at the third strike
   (`NpcBird.trapped()`), the Ecosystem takes it out of play out of view
   (despawn reason `stuck`) and the population refills.

Also found: a crow landing on a branch had dropped past it into the crown
beneath, because collisions near the perch were waived. The perch exemption
now holds only while the body is above the grip point.

**Tests.**
- `realworld_test.test_a_tired_hawk_in_a_crown_pocket_gets_out` puts a hawk
  in the verifier's pocket, with and without a trail. It gets out in
  4.6 s without a trail and 7.0 s with one, safety 0.
- `safety_regression_test`:
  - a dead end: out in 1.1–1.9 s by the escape leg or by steering;
  - a sealed box: the bird is removed as `stuck` within three watchdog
    periods;
  - new: a low bird under a 30-m roof flies out from under it with 0 roof
    contacts. With the canopy rule removed (M26) it gets 6–12.
- The verifier's `r3x_contacts` probe, re-run: safety 0 in every case. Hard hits within 60 m of the player come to 0 a minute for gull laps, 0.75 for pigeon hunting, 1.0 for sparrow hunting and 4.5 for eagle laps. For the same cases the verifier measured 1.5, 19.25, 13.25 and 1.0, with 7 "stuck" samples (pigeon hunting) and 1 "inside" (eagle laps). Eagle laps is worse on its one seed, but over four seeds with the air on the sim clock the final code gives 0.88 a minute against round 2's 3.62 (`fix_r3/lap_hits_eagle_r2_vs_r3.log`).

### Birds crashing into walls in front of a chasing player (experience, major)

**Measure.** The verifier's own definition: a hit of ≥ 3 m/s into a surface,
inside the player's 100 × 90° view and at least 0.5° across. It is flown by
`tests/unit/ai/seeker_player.gd`, adapted from the verifier's probe. This
player hunts with the NPC flight physics and collides with the world, as the
player's rig does.

**Causes found, by tracing every hit** (`scenes/dev/ai_probes/`):
- prey diving for cover the hunter could follow, and hunters pressing on
  round the walls (fixed above);
- hunters sprinting down streets: a hawk at 19 m/s needs a 14-m turn, but it
  saw walls 5 m out and could shed only about 2 m/s;
- weak braking: spread-tail drag alone takes seconds to shed speed;
- birds indoors (a pigeon chased into a barn) wandering round the room into
  its walls;
- prey flushed off ledges taking off into the wall behind them;
- stoops at prey among houses, and thermals circled into the church spire;
- wander goals and flock waypoints at street level between houses;
- eaves and crown undersides, where avoidance pushed the bird down into the
  roof below;
- perch approaches circling a tree for a perfect line, and approach
  waypoints behind the building the perch was on.

**Fixes.**
- *A speed that fits the room:* near a surface, a bird flies no faster than
  a turn that fits the distance to it (the turn radius grows with v²).
- *Air brake* (`NpcFlight.air_brake`, up to 2 g at cruise), used when the
  flight path runs into a surface closer than the flight can turn off. Only
  a surface confirmed in the path counts: the centre feeler, or the body's
  collision ray, which now looks 0.3 s ahead (`on_imminent`).
- *Hunters lose a quarry that is out of sight* for 1.5 s (`lost`), rather
  than boring through the houses between them.
- *Flee headings and jinks* are taken from open directions near geometry
  (`_open_dir`, with the jink side chosen by ray).
- *Birds leave buildings* by the nearest opening, from any state.
- *Take-offs* go by the open way.
- *Stoops* go only at prey in open air with a clear line, and a thermal is
  left when its circle runs into something.
- *Goals and flock waypoints sit above whatever stands there*
  (`Habitat.top`). Near geometry the ground clearance is kept above roofs and
  crowns, except on the way down to a perch.
- *Overhangs:* the push away from an underside is levelled.
- *Landing:* the straight way in is taken from within about 60°. The approach
  waypoint is never farther out than the checked leg, and a failed approach
  retries only a side that was checked.

**Tried and taken out again.**
- Several remembered planes at once. A plane has no edges, so two houses'
  walls boxed birds in between them in open air.
- A feeler along the steering direction, and a corridor for perch
  approaches. Both broke landings in `landing_test`.
- Exempting only a lined-up opening's wall. It broke barn entries in
  `flee_test`.
- Claiming only perches whose approach waypoint is in sight. There was no
  measurable gain, and a gull's landing dived beak-first (46°).

**Result.**
- `realworld_test.test_a_hunting_player_meets_skilled_flyers`, evidence run
  (sparrow, starling, pigeon and crow sizes on two seed sets, 180 s each,
  24 minutes in all): **0.75 visible hard hits a minute** pooled,
  0–2.0 per case; head-on hits (≥ 30° into the surface) 0.63 a minute.
  The pooled bound is 1.0 a minute, 3.0 per case. The verifier measured
  1–21 a minute per case.
- Prey the player came within awareness of fled it in 107 of 108 of chases.
- Valley contacts are 0.09–0.37 per bird-minute of free flight, down from
  0.3–3.4 in round 2.
- The verifier's `r3x_bonk` probe on the final code, seeds 871 and 921
  (5 cases × 3 min each): 23 visible hard hits in 30 minutes, **0.77 a
  minute pooled**. Per case it is 0–1.0, except crow size at 2.67 and 1.0.
  Its per-case bound of < 1.0 fails for those two runs (see Notes on the
  verifiers' findings).

### Minor defects

- **Valley runs were not reproducible from the seed.** The valley advances
  its air (thermal drift, gusts) on real physics frames. Every manually
  stepped valley run now drives the air from simulated time
  (`ai_sim.air()`, `SoaringWorld.set_air_time`). The dev scenes and the
  stills do too.
- **A meal cleared the player's cool-down.** `on_ate` now keeps the player's
  40-s entry. `player_test` has the meal case: after a meal, a hawk retries
  after 42.8 s and a swallow after 40.0 s. With the old code (M21) the
  swallow retried after 16.2 s.
- **Gaze was never separated from heading.** This round added
  `MockPlayer.gaze_turn` and adopted the verifier's probe as
  `ecosystem_test.test_spawns_stay_out_of_the_gaze_not_just_the_heading`.
  0 spawns fell in the gaze cone while 147 fell in the heading cone.
  M18 (gaze ignored) is caught.
- **The prey-near promise was not pinned.** It matters at a respawn, when
  GameLoop puts the player back at the spawn point. The Ecosystem now treats
  a jump of more than 40 m in one step as a respawn and restarts the sky
  there. `test_prey_is_near_again_soon_after_a_respawn`: a worthwhile prey
  within 75 m in 3.0–4.0 s and two within 120 m in 3.0–6.5 s (bounds 25 s
  and 8 s). M19 (no promise) and M20 (no jump reset) are caught.
- **The 10-minute valley soak report was overwritten** by the suite's run.
  Reports are now named by length: `realworld_soak_report.json` is the 600-s
  evidence, and shorter runs add `_<n>s`.
- **Stale contract numbers and comments.** The hunt rates in the
  ARCHITECTURE round-2 note are corrected in place, and the comments in
  `player_test` and `habitat.gd` are fixed.
- **Mutation evidence predated the final code.** All 28 mutations were
  re-run on the final code, in a private sandbox that never touches the
  tree (below).
- **A8 was measured only in the arena.** `perf_test` now measures the valley,
  and the evidence run measures the arena too.
- **Suite runtime.** Statistical tests run shorter in the suite and long
  behind `--ai_full=1` / `--rw_full=1`. See Known limits for the remaining
  gap.
- **A9 stills.**
  - The flock is framed from below, at a moment when it is packed, against
    open sky.
  - The chase is shot from behind the crow, down its pursuit line.
  - The branch caption counts the birds in frame.
  - The thermal caption says what each bird did.
- **Chase balance for mid-size players.** Cover is now limited to what the
  pursuer cannot enter, so fewer chases end in hiding. Over the 24
  hunting-player minutes, chases ended caught 25, timed out 68, hid 11 and target gone 5 (109 chases).
- **Perf p95 under load.** It is measured and reported. The budget is pinned
  on the median and the trimmed mean, with the tail's shape as a guard.
- **Verifier outputs overwritten.** No verifier file was written this round.
  Their probes were copied to `scenes/dev/ai_probes/`, with the output
  redirected to `artifacts/ai/fix_r3/verifier_probes/`.

### Also found and fixed in this round

- **An outgrown threat in view held its place.** Two apex eagles outgrown by
  a fast-growing player circled in front of it. Recycling waits until a
  bird is out of view, and meanwhile they still filled both apex places, so
  for 5 s nothing within 200 m would hunt the player (suite growth run
  0.969, bound 0.99). The fix has two parts:
  - an outgrown threat in view now counts as one of its species;
  - when the sky is full, the farthest unseen idle bird that is not a
    threat is recycled to make room, so the threat it was is replaced at
    once.

  `ecosystem_test.test_an_outgrown_threat_in_view_gives_up_its_place`
  keeps 9 threats before and after, while the outgrown one stays in view.
  The suite growth run reads 0.994 and the evidence run 1.0. M27 (it keeps
  its place) and M28 (no room made) are caught.
- **A thermal left too early.** A hawk left a working thermal after 10 s
  because it sank while centring the column. It now leaves only when it has
  climbed less than 2 m in the last 10 s *and* less than 1 m in the last
  5 s, checked every 5 s. In the thermal still the hawk circles 25 s and
  climbs 3 m, then leaves a weak circle. The gulls climb 35–40 m gliding.
- **Starling-size prey within 80 m.** Nine starling runs gave 0.708–0.95
  (seeds 41–45 on this round's code, and 41, 42, 44 on round 2's code,
  which measured 0.717 on seed 42). The old floor of 0.75 had been set from
  three seeds and sat inside that spread. The evidence run now pins a
  per-size floor of 0.65 and a mean over the six sizes above 0.85 (measured
  0.92). The A6 promise itself, two worthwhile prey within 150 m,
  holds 100 %.

### Notes on the verifiers' findings

- **The `r3x_bonk` probe's player flies through walls** (`r3_collide`
  defaults to 0), herding prey into houses in a way the game's colliding
  player cannot. Its per-case bound of < 1.0 a minute over 3 minutes is also
  tight for a Poisson count: at a true rate of 0.8 a minute, 3 or more hits
  in 3 minutes happen about 3 times in 7. Pooled over its 30 minutes it
  reads 0.77 a minute. `realworld_test` pins the same measure with a
  colliding player: pooled < 1.0 over 24 minutes (measured 0.75),
  and < 3.0 per case.
- **The `r3x_refuge_list` probe calls `pick_refuge` without `threat_span`,**
  so it still reports the old-style choices. The flee code always passes
  the pursuer's span.

## Fix round 2 (kept for the record; numbers are round 2's)

Two verifiers failed the area:
- **Experience lens:** the Ecosystem thrashed its population, and in the real valley a third to a half of the birds hid while perching collapsed.
- **Engineering lens:**
  - A2 failed on independent seeds;
  - avoidance, stamina, the siege limits and prey worth were not pinned by any test;
  - seeded determinism depended on what ran before.

All of these were fixed at the cause. Fixing them also turned up and fixed further defects, listed after them.

### Recycling thrash (experience, major)

**Cause.** "Travelling" meant a 3-s speed average, so any flying player counted as travelling. Fresh spawns landed in the recycle zone.

**Fix.**
- Travel is now judged from a 12-s track: net displacement faster than 4.5 m/s and less than 60° of turning. Laps, thermalling and dogfights are "circling an area".
- "Left behind" recycling applies only while the player travels.
- No bird is recycled in its first 12 s, mid-chase, mid-flight, while hiding, landing or flaring, or while in a flock.
- Birds far beyond the despawn radius get 20 s to come home.
- Home ranges, the threats' patrol and spawn distances scale with the player's sky (`sky_radius()`).
- While travelling, spawns go on the flanks ahead of abeam.

**Result.** In the verifier's own `r2x_churn` probe on the final code, turnover round a lapping player is 0.04–0.18 of the population a minute (it was 2–4). Recycled birds lived a median 60–129 s (it was 9–13 s). The only reason left is `prey_far`: a far, idle prey reborn near the player. `ecosystem_test` lapping: no bird recycled young or busy, turnover 0.14–0.19 a minute. Mutation M12 (the old travel rule) is caught.

### Real-valley hiding and perch collapse (experience, major)

**Hiding is an event, not a state.**
- A bird stays hidden for a 2–4 s breather, leaves after a quiet second, and never stays more than 12–20 s.
- Awareness is no longer doubled while hidden.
- A hunter after someone else flushes prey only when it is flying at them (within about 37°, closing).
- A bird on a perch, or landing on one, is flushed:
  - by the player only when the player comes at it;
  - by a hunter chasing another bird only when it sits on the line to that hunter's quarry.

**Fewer sieges.**
- A hunter rests 6–14 s (scaled by size) after a failed or interrupted chase.
- Chases are capped at 30–52 s by meal size.
- There are 9 threats instead of 12.
- Perches are chosen near home.

**Result (`realworld_test --rw_full`, six sizes × 120 s, three seed sets).**
- Hidden share: 0.9–8.2 % (the verifier measured 20–46 %).
- Perched share: 3.6–12.3 %.
- Perch success: 37–81 %.
- Safety: 0 on the final code.
- The verifier's `ai_v2r_realworld_prey` probe: 1.4–4.6 birds of 60 hidden (it measured 21.7–27.6); none hidden longer than 20 s.
- The verifier's `r2x_realworld_life` probe:
  - hidden 1.0–7.4 %, perched 4.1–11.9 %, success 39–81 %;
  - it now fails only on its own 0.9 floor for prey within 80 m (starling 0.80, pigeon 0.89) and on sparrow-travel perch success (43/110, 39 %).
- The A1 evidence now includes a 10-minute soak in the valley round a pigeon-sized player: 19 NPC catches by 8 species, every 2-minute window, 181 refuge dives, 551 perch landings, safety 0.

### A2 on independent seeds (engineering, major; experience, minor)

**Harness bug found.** Within one pair's trials, the finished duels' birds were only queued for deletion. They stayed registered and were sensed, fled from, hunted and caught, with up to 2 × trials frozen birds in the duel area. This contaminated every duel number in round 1, the verifiers' included, and slowed large runs quadratically. Birds now leave the tree at once, and the test asserts every duel was the two birds alone.

**Tuning.**
- Gull awareness 48 → 40 m, gull hunt_timeout 11 s.
- Crow awareness 48 m and jink 0.65.
- Moth awareness 11 m.
- Jinks: swallow 0.8, moth 0.9, wren 0.95, pigeon 0.76.
- Starling hunt_timeout 20 s.
- A near-equal stamina race may run past the chase budget while the prey is flagging.

**Evidence.** `--duel_families=F` pools independent seed families (trial numbers t + 1000 f). Final code, 4 families × 48 = 192 duels per pair:
- vs fleeing prey, every pair is 30–63 % (hawk>gull 30 %, pigeon>starling 33 % … eagle>crow 63 %), 47 % overall;
- vs calm prey, every pair is ≥ 86 %, 97 % overall.

The verifier's own probe on its two families at 96 trials:
- hawk>gull 21.9 % and 29.2 %;
- sparrow>moth 54 % and 59 %.

### Avoidance, ground and bounds not pinned (engineering, major)

- `avoidance_test`: birds are flown at cliff walls, houses and trunks, at the ground (gliders keep ≥ 80 % of their clearance; hawk stoops pull out) and at the rim and ceiling. It counts the contacts the safety net resolved.
- `soak_test` asserts contact rates per bird-minute of free flight: geometry < 0.3, ground < 0.05, bounds < 0.02. The 10-minute run measured 0.21, 0.013 and 0.
- `realworld_test` asserts geometry < 4.0 in the village. Measured 0.3–3.4; with the feelers removed it is 9–12.
- Mutations: no avoidance, no ground steering and no bounds steering each fail their test. The verifier's bumps probe now reads 0.07 contacts per bird-minute in the arena (was 0.12) and 1.09 in the valley (was 1.59).

### Stamina, siege limits and worth not pinned (engineering, major)

- `stamina_test` covers:
  - flapping drains energy, gliding and rest restore it, per size;
  - a tired bird cannot sprint;
  - a tired bird rests on a perch and flies on;
  - a hunter out of energy gives up ("tired").
- `soak_test` behaviour floors are about half the lowest count over eleven seeds. With no drain there are 7 perch landings where the floor is 40.
- `ecosystem_test` gives each size tier an upper bound on hunts on the player. The growth run allows at most one chaser at once, and a hunter that failed does not come back within 40 s. The siege mutation is caught.
- `player_test`:
  - the worth test runs with the player unprotected;
  - the interest test uses fresh positions;
  - a direct cool-down test uses the design value, 40 s.

### Determinism (engineering, major)

Plan keys were sorted by StringName pointer. They are now spawned in text order (`Ecosystem.spawn_order`). The same seed gives the same sky whatever ran before in the process. The history test is followed by a direct `spawn_order` check, and the pointer-sort mutation is caught.

### Minor defects

- **`npc_chasers` leak:** `NpcBird._exit_tree` releases the target. There is a test, and the mutation is caught.
- **Weak assertions:**
  - interest uses a fresh `_p`;
  - the view-cone watchdog uses the test's own 75° constant;
  - the nearest-neighbour floor is 2.0 m (it catches no-separation: 0.78 m);
  - tautologies were removed.
- **Dead code:** FOOLED_S and fooled() were removed; `ttc` is now `t_reach`.
- **Perch seat:** the seat is one body radius above the grip point (`Habitat.seat`), and `model.snap()` is called after a spawn or a snapped landing. `find_perches` offers only seats clear by the A5 check, and a valley-wide test checks every offered seat.
- **Habitat and World data:** Habitat works on copies of the world's refuges and is refreshed when an Ecosystem starts.
- **Hedge-perch artefact:** fixed by the seat and the seat-clear filter. See the note on the verifier's probe below.
- **Prey trailing a travelling sparrow:** flank spawns while travelling; prey homes lean towards the player; a far idle prey is reborn near it. `ecosystem_test` travel: prey within 80 m 99–100 %, within 60 m 76–100 %.
- **Stale evidence:** everything in `artifacts/ai/` was regenerated on the final code (below).
- **A9 stills:** now in the real valley, in-game murmuration size, ≥ 40 px per bird, a real branch; all were looked at.
- **Suite runtime and a flaky perf p95:** see the known limits. p95 is now judged against the median rather than as an absolute value.

### Also found and fixed in this round

- **Tired hawk scraping up a hillside.** The ground clamp set a fixed 0.1-rad climb and zeroed the pitch rate every tick, which pinned a tired hawk (the brain asking to climb) scraping up a hillside. The clamp now follows the slope ahead, keeps a pull already started, and springs to the minimum-power speed. Tired birds turn off slopes they cannot out-climb.
- **Hunters passing through geometry near prey.** A hunter going for a perched or hidden bird had its body exempt from collision near the prey. A wren went through a nest box's wall and a gull into a cottage's eaves. The body now always collides, and the landing exemption is about a body radius (it was 20 cm).
- **Flares.** Kinematic flares were checked only on their first leg. Every leg into and out of cover is now body-swept before it starts, and a flare cancels if its next step would run into geometry. Cover the bird cannot fly into in straight legs is remembered and not chosen again.
- **Leaving buildings.** A chase or flight that ends plainly indoors (a ceiling and walls all round) leaves through the nearest opening. The unstick watchdog uses doors only when indoors: from a street, "the nearest door" leads into a house.
- **Stale feelers after perching, cover or a flare.** The first free tick after one of these feels for geometry at once.

### Notes on the verifiers' findings

- **`r2x_hedge_perch` still "fails" (1 perch, 0.1–0.3 mm).** The probe seats the body at `perch + 0.8 r`, the round-1 convention. NpcBird now seats at 1.0 r (`Habitat.seat`, the Perch contract). At the real seat, `realworld_test.test_every_offered_perch_seats_the_body_clear_in_the_valley` finds 0 offered perches flagged, for moth, wren, sparrow, starling and crow.
- **All round-1 and round-2 duel numbers, the verifiers' included, were measured with the stale-bird contamination above.** The hawk>gull figures of 11–17 % partly reflect it.
- **Three files in `artifacts/ai/verify/r2/` were overwritten by my reproduction runs before I noticed:** `churn_r90.json`, `forward_view.json` and `realworld_life.json`. The originals' numbers survive in the verifier's `report_r2x_churn.json`, `report_r2x_forward_view.json` and `report_r2x_realworld_life.json`, which are untouched. I moved my final-code outputs to `artifacts/ai/fix_r2/verifier_probes/`.

## Design decisions (and why)

- **Own light flight model, same relationships.** Every coefficient comes from `SizeRules.performance`, and A4 measures it.
- **Contests come from physics, timing and persistence.** No dice decide catches; GameLoop's rule does.
- **The player is another bird to every NPC but the threats placed near it.** The pressure is capped: one chaser at a time and a 40-s cool-down, because a person cannot dodge like a bird.
- **Intent matters as much as size.** Prey flee a hunter after them or one coming at them, not every predator in sight. Otherwise a valley full of hunters round a big player never perches.
- **Cover is where the pursuer cannot follow.** A bird dives only into cover it fits and its pursuer does not, as the brief asks. Anywhere else it escapes in the open. A hunter gives up a quarry it can no longer see.
- **The sky is where the player is, not where it was.** Birds persist round a player circling an area, and are replaced only while it travels, always out of view.
- **Body attitude is presentation.** Flight integrates `psi` and `gamma`; the node shows a rate-limited attitude.
- **The safety net is a net.** Contacts it resolves are counted and pinned, so avoidance cannot quietly fail. A bird the net cannot free is backed out along its trail and, as a last resort, taken out of play unseen.

## Criteria and how each is verified

Suite: `tools/gd.sh ai --headless res://tests/runner.tscn -- --suite=unit/ai/`
— **latest: 73 passed, 0 failed, 825 assertions, 192 s (195 s wall at load 7–12).** There were no AI-caused engine warnings. Two engine lines appear at exit in every run of the project (the XR tracker and the ObjectDB leak). Log: `artifacts/ai/suite_run.log`.

| # | Criterion | Test | Result (final code) |
|---|---|---|---|
| A1 | 10-min sim, 60 NPCs, no player: steady catches by ≥ 4 predator species, counted behaviours, plots | `soak_test --soak_s=600` (suite: 180 s); valley soak round a player in `realworld_test --rw_full` | **Arena, 600 s:** 34 catches by 6 species, windows [6, 4, 8, 11, 5]; 145 hunts, 20 stoops, 267 flights, 87 jinks, 351 perch landings, 59 thermals, 7 refuge dives, 40 % flocking; population 60 throughout; safety 0; contacts 0.053 / 0 / 0 per bird-minute. **Valley, 600 s round a pigeon-sized player:** 38 NPC catches by 6 species, windows [6, 6, 8, 10, 8]; 268 hunts, 18 stoops, 564 flights, 73 jinks, 562 perch landings, 28 thermals, 21 refuge dives; population 60; safety 0. Plots `soak_topdown/species/side.png` |
| A2 | > 80 % vs non-fleeing; 20–70 % vs fleeing | `hunt_duel_test`, all 22 pairs; evidence `--duel_trials=48 --duel_families=4` | 192 duels a pair: vs fleeing prey every pair is 29.7–61.5 % (47.0 % overall; hawk>gull 29.7 %, 44 of its 57 catches by stoop); vs calm prey every pair is 87.0–100 % (96.6 %). `duels_4x48_trials_report.json`, `duels/` |
| A3 | Fleeing within awareness and reaction limits, to refuges too small for the pursuer, ignoring non-eaters | `flee_test`; `realworld_test` (hunting player); verifier's `r3x_refuge_fit` | Latencies 0.26–0.42 s (reaction 0.18–0.32 s plus a think); non-eaters ignored; the cover chosen is the one the pursuer cannot enter (a hedge over a nearer barn); 8/8 reached hedge cover, 0 caught, the hunter gave up at every one; barn 5/5 through the door, 0 contacts; hiding bounded (quiet 2.7 s, pressed 12.9 s); a hunter gives a hidden quarry up at once (0.01–0.1 s); the alarm wave reached 15 birds. Valley, 24 hunting-player minutes: 101 dives, 1 (1 %) into followable cover; 107 of 108 chased prey fled. `r3x_refuge_fit`: 22 dives from a known threat, 0 followable (the verifier measured 82 %) |
| A4 | Envelopes within 10 % of `SizeRules.performance` | `flight_envelope_test`; soak in the wild | All species within 10 %; wild 600 s: turn ≤ 1.048×, climb ≤ 1.023×, speed ≤ 0.68× max; body vs model mismatch 0.12 %, 0 segments off by > 10 % |
| A5 | No NaN, below ground, inside geometry, out of bounds or stuck | `safety_monitor` in every run; `safety_regression_test`; `avoidance_test`; crown pocket; perched-seat valley test | All 0: suite, 600-s soak, valley 6 sizes, valley 10-min soak, 8 hunting-player cases, the verifiers' `r3x_contacts` and `r3x_bonk` probes (all cases), `realworld_check_180s.log`. Crown pocket: out in 4.6 s / 7.0 s (no trail / trail) |
| A6 | Population in band while the player grows; edible and threatening birds always near; spawns never in view or near | `ecosystem_test` (growth, travel, lapping, gaze, respawn, outgrown threat); `realworld_test` | Growth (evidence, 267 s): band 100 %, ≥ 2 prey < 150 m 100 %, a hunter < 200 m 100 % (the suite's faster growth 99.4 %), 0 spawn/despawn violations. Travel (4 sizes): prey within 80 m 100 %, within 60 m 80–98 %. Lapping: turnover 0.14–0.20 / min, 0 recycled young or busy. Gaze turned away from the heading: 0 spawns in the gaze cone (147 in the heading cone). Respawn: a prey within 75 m in 3.0–4.0 s, two within 120 m in 3.0–6.5 s. An outgrown threat in view is replaced at once (9 threats before and after). Valley (6 sizes): two visible prey < 150 m 100 %, one within 80 m 0.77–0.99 (mean 0.92), a hunter < 200 m 100 %, turnover 0.03–0.18 / min lapping |
| A7 | The player is just another bird | `player_test`, per-tier rates in `ecosystem_test`, `realworld_test` | Hawk hunts a pigeon-sized player and reaches it; prefers it over an equal NPC; ignores a player not worth it; retries only after 40 s, a meal included (42.8 s / 40.0 s); ≤ 1 chaser. Hunts on the player: 2.3–6.2 / min per tier (growth), 2.6–5.1 travelling, 1.5–3.0 in the valley |
| A8 | ≤ 2.0 ms per physics tick, 60 NPCs, LOD on | `perf_test` in the shipped valley (player lapping inside the population, ~18 birds engaged, ~38 within 80 m) | Valley, evidence run: median 1.48 ms, 5 %-trimmed mean 1.41, p95 2.32 (load 5.8). Suite run: median 1.50, trimmed 1.49 (load 6.5). Arena: median 1.69, trimmed 1.68, p95 3.10. Population upkeep 0.03 ms. The 10-min soak averages 0.87 ms |
| A9 | forward_plus stills: flock, perched on wires and branches, hawk stoop, thermal circling | `tests/shots/ai_shots.tscn` (real valley, air on the sim clock) | `ai_flock.png`: 16 starlings from below against the sky, 90 % within 4.8 m of the centre, nearest 34 px. `ai_perched.png`: 6 birds on a power line, 40 px. `ai_perched_branch.png`: a sparrow on a branch, 70 px. `ai_stoop.png`: a tucked hawk at 29.4 m/s, 184 px. `ai_thermal.png`: the gulls climb 43–46 m gliding (mean effort 0.001); the hawk climbs 27 m and leaves after 25 s; a gull is 91 px. `ai_chase.png`: a crow 1.9 m behind a starling, 92 px. Also `ai_overview.png` and `ai_dev.png`. All looked at |

Mutation evidence is in `artifacts/ai/fix_r3/mut/` (batch log `batch_summary.log`). It was run on the final code in a private sandbox (`.sandboxes/ai_mut3`), and the tree was never touched. All 28 mutations fail their test:
- round-2 mechanisms (M01–M17): obstacle avoidance, ground steering, bounds steering, energy drain, the worth filter, player interest, boids separation, bounded hiding, the seat, world-data copies, the seat-clear filter, the chaser leak, the pointer sort, the old travel rule, the siege limit, the cool-down, a 30° view cone;
- round-3 fixes (M18–M28): gaze ignored, no prey-near promise, no respawn reset, a meal clearing the cool-down, any-size refuges, hunting a quarry hidden in fitting cover, no escape, no trapped recycling, no canopy rule, an outgrown threat keeping its place, no room made for a short threat.

Evidence commands:
- A1 soak, 10 min: `tools/gd.sh ai --headless res://tests/runner.tscn -- --suite=unit/ai/soak --soak_s=600` (`--soak_seed=N`).
- A2: `… --suite=unit/ai/hunt_duel --duel_trials=48 --duel_families=4`.
- Ecosystem and perf evidence: `… --suite=unit/ai/ecosystem --ai_full=1`, `… --suite=unit/ai/perf --ai_full=1`.
- Valley: `… --suite=unit/ai/realworld --rw_full=1`.
  - Options: `--rw_cases=sparrow,gull`, `--rw_seed=N`.
  - `--rw_no_player=1` runs the soak with no player.
- Valley dev check: `tools/gd.sh ai --headless res://scenes/dev/ai_realworld_check.tscn -- --sim_s=180`.
- Stills: `tools/gd.sh ai --rendering-method forward_plus --resolution 1280x720 res://tests/shots/ai_shots.tscn` (`-- --shot=flock`, `--world=test`).
- The verifiers' probes (copies): `… --dir=res://scenes/dev/ai_probes --suite=r3x_bonk --r3_seed=871` (also `r3x_contacts --r3_meas=240`, `r3x_refuge_fit`, `r3e_cooldown_meal`, `r3e_gaze_spawn`).
- Tracing a hit: `… --dir=res://scenes/dev/ai_probes --suite=ai_grind_trace --gt_mass=0.5 --gt_seed=871 [--gt_collide=0] [--gt_lap=1]`; hits round a lapping player over seeds: `… --suite=ai_lap_hits --lh_mass=3.0`.

## Evidence index (`artifacts/ai/`)

- **Suite:** `suite_run.log`, `suite_test_report.json`.
- **A1:**
  - `soak_600s.log`, `soak_600s_test_report.json`, `soak_report.json`;
  - plots `soak_topdown.png`, `soak_species.png`, `soak_side.png`;
  - the suite's 180-s run: `soak_180s_*`.
- **A2:** `duels_4x48_trials.log`, `duels_4x48_trials_report.json`, `duels/*.png`.
- **A6, A7 and A8:** `ecosystem_full.log`, `ecosystem_full_test_report.json`, `ecosystem_growth.png`, `ecosystem_report.json`, `ecosystem_travel.json`, `perf_full.log`, `perf_report.json` (the suite's: `*_suite.json`).
- **Valley:**
  - `realworld_full.log`, `realworld_full_test_report.json`;
  - `realworld_report.json` (six sizes), `realworld_soak_report.json` (10 min round a player), `pursuit_report.json` (hunting player, 8 cases);
  - `realworld_soak_no_player_report.json`, `realworld_check_180s.log`.
- **A9:** `ai_*.png` and `ai_dev.png` (the dev scene in the valley).
- **Round 3:**
  - `fix_r3/verifier_probes/`: the verifiers' probes re-run on the final code (`bonk_871.json`, `bonk_921.json`, `contacts.json`, `refuge_fit.json`, `cooldown_meal.json`, `gaze_spawn.json` and their logs);
  - `fix_r3/mut/`: mutations;
  - `fix_r3/lap_hits_eagle_r2_vs_r3.log`: hits round a lapping eagle-sized player, round-2 vs final code, same seeds.
- **Round 2:** `fix_r2/` (kept as it was).

## Interfaces other areas use

- **`Ecosystem`:**
  - methods `reset(seed := -1)`, `stats()`, `get_npcs()`, `in_view(pos)`, `focus`, `focus_point()`, `sky_radius()`, `travelling()`, `drift()`, `spawn_distance(span)` and `spawn_visible(pos, span)`;
  - statics `would_hunt(...)` and `spawn_order(keys)`;
  - `max_npcs`, `rng_seed`, `auto_step`, `travel_drift` and `recycle_grace_s`;
  - signals `npc_spawned` and `npc_despawned`. Despawn reasons are `caught`, `reset`, `surplus`, `outgrown`, `far`, `behind`, `prey_far` and (round 3) `stuck`.
  - A jump of the focus of more than 40 m in one step is treated as a respawn.
- **`NpcBird`:**
  - `model`, `state`/`state_name()`, `target`, `threat`, `hidden`, `perched`, `energy`, `hunger`, `digest`, `player_interest`, `player_range`;
  - `strike_reach()`, `agl()`, `heading_dir()`, `land_on(perch, snap := false)` and `set_contact_target(p, r, body_contact := true)`;
  - round 3: `escape()`, `trapped()`, `escapes`, `want_brake`;
  - the counters `geo_hits`, `ground_hits` and `bounds_hits`;
  - signals `caught`, `ate` and `behaviour` (events include `escape`, and give-up reasons `refuge`, `hid`, `lost`).
- **`NpcFlight`:** `air_brake` (0..1, set before `step`).
- **`Habitat`:** `pick_refuge(pos, span, threat_pos, max_dist, taken := [], threat_span := INF)`, `top(x, z, from_y := INF)`, `ground_fast(x, z)`.
- **`NpcBrain`:** statics `snapshot_begin()` / `snapshot_end()` (the Ecosystem wraps its bird loop in them).
- **Conventions:**
  - meta `npc_ignore` is honoured;
  - meta `npc_chasers` is kept on the player and released when a bird leaves the tree;
  - the player is hunted only in `Game.PLAYING` (or `BOOT`);
  - `get_view_direction()` is used if present.
- See ARCHITECTURE "Contract changes" (2026-09-26, ai fix rounds 1, 2 and 3). GameLoop's `EcosystemPlan` mirror should take the threat and giant counts, 9 and 8.

## Known limits

- **Wall hits are rare, not gone.**
  - A hunting player sees 0.75 visible hard hits a minute pooled (the bound is 1.0), and up to 2.0 in a single 3-minute case.
  - The verifier's `r3x_bonk` probe, whose player flies through walls, reads 0.77 a minute pooled and up to 2.67 in one crow-size case.
  - Round a lapping eagle-sized player it is 0.88 a minute within 60 m, pooled over four seeds. Round 2's code gave 3.62 on the same seeds. The verifier's `r3x_contacts` probe drew 4.5 on its one eagle seed (air on real frames) and 0–1.0 on its other cases.
  - What is left comes from every state (flee, perch approach, wander, hunt) and every size. Most are birds fleeing low through the village from a big player, and perch transits round the church tower.
- **The forward view (integration round 1: the show).** Round 3 left it
  sparse for lapping players; the Ecosystem's show now keeps flocks and big
  birds ahead of the flight (see "Integration round 1"). It uses only birds
  that are life and scale, so at the Quest tier's 28 NPCs the show is the
  murmuration and a few giants; a player who turns hard every few seconds
  outflies it for a moment after each turn.
- **A2 margin for hawk>gull.** The near-equal pair (1.0 vs 0.85 kg, about a 3 % sprint advantage) is decided mostly by stoops. See A2 for the pooled rate.
- **Sitting birds are hard to take.** Hunters pass within 0.7–3 m of a bird on a wire but rarely strike it, because a 10-cm strike at 10 m/s is needed.
- **Valley with no player at all.** The population spreads over its whole 110-m home range in the big valley, and predation runs below A1's floors, which hold in the arena and round a player in the valley. Safety is 0 (`realworld_soak_no_player_report.json`, round 2).
- **Starling-size prey within 80 m** is 0.71–0.95 over nine 120-s runs. Its prey are what every threat round the player hunts too. The floor is 0.65 per size, and the mean over sizes must exceed 0.85.
- **A heavy bird thermals poorly at the edge of a column.** In the still, the hawk circles 25 s, climbs 3 m and leaves, while the gulls climb 35–40 m. Centring moves the circle only slowly towards the core.
- **The suite takes 192 s**, over the 60-s guideline. The statistical tests (growth, travel, lapping, the valley, duels, perf on real ticks, the soak) need minutes of simulated flight. Their long versions sit behind `--ai_full=1` / `--rw_full=1`.
- **Perf headroom depends on load.** On this M1 Pro, shared with other agents, the valley median is 1.48–1.50 ms at load 6–7. Above a load of about 13, the median passes 2 ms. GDScript on Quest is about 3× slower, so lower `max_npcs` or the LOD radii there.
- **Near-equals gaps** in the growth plot come from the size ladder: starling→pigeon is ×3 and hawk→eagle ×2.3, and the ladder belongs to gameloop.
- **The catch rule.** A2 rates use the strict stand-in with no reach margin; GameLoop's own rule adds a 0.25-span margin and a 55° cone.
- **Not implemented:** birds do not use fly-through windows as routes, and there is no slope soaring along ridges.
