class_name GameLoop
extends Node
## The rules of play: catch smaller birds, avoid bigger ones, grow.
##
## The ONLY owner of the catch rule. Every physics frame (after the birds have
## moved) it:
##  1. snapshots every live Bird (position, the position last frame, mass,
##     radius, heading) from the Birds registry,
##  2. finds candidate pairs with a broad phase (a spatial hash of x/z
##     columns, CatchGrid, by default; sort-and-sweep, CatchSweep, is the
##     tested alternative) and runs the swept contact + aim-cone test
##     (CatchRule) on each,
##  3. resolves all contacts of the frame in a deterministic order (earliest
##     contact first; ties: heavier predator, heavier prey, then position), so
##     chains like "A eats B while C eats A" have one well-defined outcome and
##     no bird is caught twice or eats after being eaten; the size ratio is
##     re-checked when each catch happens (a meal earlier in the frame may
##     have made the prey too big to eat),
##  4. applies the results: Events.bird_caught, prey.on_caught(), mass gain
##     for the eater (+ on_ate), the player's growth and tier events, or the
##     player's death,
##  5. evaluates threat and target for the player (ThreatWatch) and emits
##     Events.threat_changed / Events.target_changed, and sets BirdModel
##     highlights.
## Before the catch pass the final-approach magnet draws prey the player is
## flying straight at onto its path (_magnet), and the danger director
## sends the sky's attacks on the player at a set cadence (_direct_danger).
##
## Run flow (drives the Game autoload):
##   start_run() -> PLAYING -> caught -> CAUGHT (dramatic beat) -> penalty +
##   respawn with protection -> PLAYING ... -> lives exhausted -> ENDED
##   (Events.run_ended(summary)); apex goal completed -> ENDED with victory.
##   restart_run() resets everything from any state; pause()/resume() keep
##   the CAUGHT beat intact. UI may also drive Game.set_state directly: a
##   MENU/ENDED -> PLAYING transition starts a run, PLAYING -> MENU abandons it.
##
## Add to the scene (group "game_loop"); tolerates a missing player, world or
## ecosystem so dev scenes can run it alone. Tests set auto_step = false and
## call step(dt) themselves.

## Mass changed for any reason: &"meal", &"penalty" (caught), &"reset".
## Events.player_grew only fires for growth; this fires for everything.
signal player_mass_changed(old_mass: float, new_mass: float, reason: StringName)
signal lives_changed(lives: int)
## The player reached the apex tier for the first time this run.
signal apex_reached()
## A worthwhile catch while at the apex tier; the goal is `needed` of them.
signal apex_progress(catches: int, needed: int)
## The apex goal is complete (emitted just before Events.run_ended).
signal victory(summary: Dictionary)
## The player was put back after being caught, protected for protection_s.
signal player_respawned(protection_s: float)
## An attack run on the player missed and the attacker is past: the player
## shook it off (and has ESCAPE_GRACE_S of peace). For UI / audio cues.
signal escaped(predator: Bird)

enum Phase { IDLE, PLAYING, CAUGHT, ENDED }

## Everyone starts as a sparrow.
const START_MASS := 0.03
## Growth stops here (1.5x an eagle; a test pins the ratio): the apex is a
## goal, not a runaway.
const MAX_PLAYER_MASS := 4.5
const MAX_LIVES := 3
## Reaching a tier for the first time in a run gives a life back (up to
## MAX_LIVES): progress is rewarded, and a careful climber keeps a buffer.
const LIFE_ON_NEW_TIER := true
## ...and so does every LIFE_PER_MEALS-th worthwhile catch since a life was
## last lost: eat to heal. A struggler stuck at one size - the valley's
## modelled novices sat 10-15 minutes as starlings, eaten by pigeons and
## crows every 3-5 minutes, and lost 4 runs in 10 (fix round 3 tuning) -
## wins lives back by playing the loop, not only by climbing it.
const LIFE_PER_MEALS := 5
## The dramatic beat between being caught and respawning, s.
const CAUGHT_BEAT_S := 2.5
## Fraction of mass lost when caught (never below START_MASS); the danger
## assist cuts it by up to DANGER_ASSIST_PENALTY_CUT (a player caught again
## and again is not also pushed back down the ladder again and again).
const CAUGHT_MASS_LOSS := 0.3
const DANGER_ASSIST_PENALTY_CUT := 0.5
const START_PROTECT_S := 3.0
const RESPAWN_PROTECT_S := 5.0
## Escape grace: when a predator's strike at the player misses - its reach
## came within PASS_SPANS of its wingspans of the player, then it is past and
## PASS_CLEAR_SPANS away again with no catch - the player is protected for
## ESCAPE_GRACE_S (NPCs leave a protected player alone, so the attack is
## over). One well-timed break ends an attack, as a failed strike usually
## ends a raptor's; without it a person's reflexes lose to the AI's
## pursuit on the second or third pass (docs/areas/GAMELOOP.md, "Danger").
const PASS_SPANS := 1.0
const PASS_CLEAR_SPANS := 2.5
const ESCAPE_GRACE_S := 2.5
## The threat cue's time-to-contact horizon scales with the player's body
## time (SizeRules.time_scale ^ CUE_HORIZON_EXP): a big bird rolls and turns
## slower, so evading takes longer in seconds and the warning must come
## earlier (3.5 s for a sparrow).
const CUE_HORIZON_S := 3.5
const CUE_HORIZON_EXP := 1.0
## Danger assist (VR forgiveness for strugglers, the twin of the catch
## assist): every death adds DANGER_ASSIST_PER_DEATH (up to 1), and it
## decays with a time constant of DANGER_ASSIST_TAU_S body-seconds of play.
## At full assist the respawn protection is RESPAWN_PROTECT_S +
## DANGER_ASSIST_PROTECT_S, the escape grace ESCAPE_GRACE_S +
## DANGER_ASSIST_GRACE_S, strikes on the player need a cone
## DANGER_ASSIST_CONE_DEG narrower and reach DANGER_ASSIST_REACH_LOSS less
## far, respites are longer (DANGER_ASSIST_RESPITE) and the threat cue
## warns earlier (DANGER_ASSIST_CUE: its horizon x (1 + that x assist)). A
## player who is rarely caught never sees it; one who is caught again and
## again gets room to learn - in the valley novices lost a life every 3-4
## minutes as starlings, to crows and pigeons, and half their runs (fix
## round 3 tuning).
## Attack respite: once an attack on the player is over - the threat cue
## rose past ATTACK_LEVEL and has been quiet for ATTACK_QUIET_S, or the
## player shook the attacker off - NPCs leave the player alone for
## ATTACK_RESPITE_S (x body time). The player is not protected meanwhile
## (it can still fly into a predator), only not hunted: danger comes in
## episodes with room to breathe. Without it the AI's sky hunts a player
## about twice a minute and a person, whose evasion cannot match an AI
## bird's, is eaten several times a run. The AI also paces itself (one
## chaser at a time, a failed hunter leaves for 40 s), so the respite only
## tops that up; 12 s x body time was tuned on whole runs in the shipped
## valley (docs/areas/GAMELOOP.md, "Pacing and danger").
## Boldness: every further attack the player survives shortens the next
## respite by BOLD_DECAY, down to BOLD_FLOOR of it; being caught resets it. The sky
## grows bolder around a bird that keeps shaking its hunters off, so being
## eaten happens to good players too, while a struggler (caught before it
## has survived many) keeps its long respites. Round 2's fixed respite made
## the difficulty run backwards against the fix round 3 AI: novices lost 3-5
## lives a run, competent players were caught in 3 of 10 runs (review).
## After being caught the player is left alone for RESPAWN_RESPITE_S (x body
## time, and the danger assist): a life lost buys time to regroup - novices
## lost whole runs to a second hunter a minute after the first.
## First flight: a run opens with OPENING_RESPITE_S of attack respite -
## nothing hunts the player while it finds its wings (the UI's first-flight
## lessons run in these minutes too) - and it lasts until the player has
## grown out of its first species, up to OPENING_MAX_S of play. Not
## protection: a player that flies into a hunter's talons can still be
## taken. In the valley, 7 of 10 modelled novices were eaten by a swallow
## within two minutes of the start, one lost its whole run in 1:42 (fix
## round 3 review); with two minutes of peace, novices still a sparrow at
## 2:30 were eaten by the first swallow that came (fix round 3 tuning).
const OPENING_RESPITE_S := 90.0
## Core loop round (the lead's direction: "from ~60-90 s into the first
## flight (after the first catch or lessons), predators periodically pick the
## player"): the first flight ends OPENING_AFTER_CATCH_S after the player's
## first catch (the catch lesson's), never before OPENING_MIN_S and never
## after OPENING_RESPITE_S of play - no longer at the first tier-up (up to
## 300 s before: a fast climber met its first hunter as a starling or a
## pigeon, a slow one flew five minutes without any danger).
const OPENING_MIN_S := 60.0
const OPENING_AFTER_CATCH_S := 15.0
## (Kept for tools: the longest a first flight can last.)
const OPENING_MAX_S := OPENING_RESPITE_S
## The first tier-up brings a grace: FIRST_TIER_GRACE_S of respite from the
## moment the player first grows out of its first species (whenever that
## is), so the new size is the player's to enjoy before anything hunts it.
## Like the first flight, a respite, not protection. Why (integration round
## 2, adopted in fix round 5): the respite ended half a second after the
## "Now a Swallow!" card, and in 4 of 10 real-chain runs a crow took the new
## size away 9-13 s later - the first celebrated moment turned straight
## into "Caught!" (the brief: not within 30 s). 35 s (core loop round; 45
## before): a first tier-up at ~1:45 then held the first attack back past
## 2:30, where the lead's direction wants the sky to pick the player from
## 60-90 s on.
const FIRST_TIER_GRACE_S := 35.0
const ATTACK_LEVEL := 0.3
## An attack is over when every predator's threat has stayed at or under
## this for ATTACK_QUIET_S.
const ATTACK_QUIET_LEVEL := 0.05
const ATTACK_QUIET_S := 1.0
## The danger director (core loop round, the lead's direction: "predators
## periodically pick the player - about one telegraphed attack every 1-2
## minutes at the start, scaling with tier"): once the first flight is over
## NPCs leave the player alone except in an attack. When the respite after
## the last attack is over the director asks the sky for one
## (Ecosystem.send_attacker: the best-placed bird that would hunt the
## player, or a new one brought in out of view) and the AI's hunters may go
## for the player of their own accord; the attack is telegraphed from the
## moment it sets off (ThreatWatch.warn_level: the HUD's arrow, the haptic
## pulse, the predator's call). Once it is over (every predator quiet for
## ATTACK_QUIET_S, or the player shook the attacker off) the next respite
## runs: ATTACK_RESPITE_S at the first species, falling linearly in tiers to
## ATTACK_RESPITE_APEX of it at the apex (the danger scales with size), x
## the danger assist's factor, x boldness. (110 s, core loop round's second
## pass: 85 s - at 70 s the tuning runs met 0.9-1.2 attacks a minute over
## the first ten minutes - until the director's first attack came on time,
## 60-90 s in; then 85 s met ~1 attack a minute, the competent person was
## caught twice a run - 4 of 10 full-tier deaths as a starling - and the
## pigeon slid to 8:25 on the tuning seeds, cl3_it10.) Before (fix round 5) the respite
## was 12 s x body time and the AI's planned threats hunted when they
## happened to - through the real flight chain the person was caught in 6 of
## 8 full-tier runs but 2 of 8 at the Quest tier, whose 28-NPC sky has few
## raptors near the player; the director brings the attacks at either budget.
const ATTACK_RESPITE_S := 110.0
const ATTACK_RESPITE_APEX := 0.55
## Retry a call that found no attacker (or whose attacker never came) this
## often while the respite is over.
const ATTACK_CALL_RETRY_S := 5.0
## The bird sent is waited for this long before another is called, while it
## is still hunting the player and no attack has begun (_direct_danger).
const ATTACK_SENT_WAIT_S := 30.0
## Boldness: each attack survived since the last death shortens the next
## respite by BOLD_DECAY, down to BOLD_FLOOR of it.
const BOLD_DECAY := 0.85
const BOLD_FLOOR := 0.6
const RESPAWN_RESPITE_S := 60.0
const DANGER_ASSIST_PER_DEATH := 0.5
const DANGER_ASSIST_TAU_S := 180.0
const DANGER_ASSIST_PROTECT_S := 10.0
const DANGER_ASSIST_GRACE_S := 6.0
const DANGER_ASSIST_CONE_DEG := 20.0
const DANGER_ASSIST_REACH_LOSS := 0.5
const DANGER_ASSIST_CUE := 0.6
## ...and respites last (1 + DANGER_ASSIST_RESPITE x assist) times longer.
const DANGER_ASSIST_RESPITE := 2.0
## NPCs keep this share of a meal's gain...
const NPC_GROWTH_SHARE := 0.5
## ...and never grow more than this fraction above their spawn mass, so a
## species stays recognisably itself and the ladder stays readable - and so
## no bird can eat its own kind: the AI spawns a species within +-9% of its
## ladder mass (docs/areas/AI.md), so the heaviest fed bird weighs at most
## 1.09 x 1.04 / 0.91 = 1.246 x the lightest, under EAT_RATIO (1.25). (Round
## 2's +15% gave 1.09 x 1.15 = 1.25 x a nominal bird: a well-fed NPC eagle
## could eat a player who had just become the eagle, and NPC sparrows each
## other - fix round 3 review.)
const NPC_GROWTH_CAP := 0.04
## The sky's NPC budget the growth tuning was made for (the AI's Ecosystem at
## the full quality tier)...
const SKY_REF_NPCS := 60
## ...and in a sparser sky each of the player's meals grows it more:
## x (SKY_REF_NPCS / budget) ^ (SKY_GROWTH_EXP x ramp), at most
## SKY_GROWTH_MAX (sky_growth()), the ramp going from SKY_GROWTH_FLOOR as a
## sparrow to 1 as an eagle (on a log scale of mass): at the Quest's 28 NPCs
## the modelled competent player caught 0.8-0.9x as often as at 60 as a
## sparrow or a starling, but 0.5-0.7x as a pigeon, a gull or a hawk (the
## Ecosystem's plan runs short of the big birds a big player hunts), so the
## late game is what a sparser sky slows down most (fix round 5; a flat
## factor made a Quest player's first minutes too quick). The budget is the Ecosystem's `max_npcs` (integration's
## QualityTier sets 28 on the Quest, its governor down to 20); none, or the
## full budget, is x1. Why (fix round 5 review, major): on the Quest tier the
## modelled competent player met fewer and harder chases (chase success
## 0.45 -> 0.32 as a sparrow, 0.13 -> 0.09 as a hawk) and reached the eagle
## at 39:44 instead of 24:56 on the same seeds - outside the brief on the
## device the game ships on. Catches there are rarer; each one counts for
## more, so the climb takes the time the brief sets at either budget. (The
## better fix is a denser sky near the player at small budgets - the AI's
## population, requested in the contract notes; then this factor is tuned
## back towards 1 by the same evidence.)
## Core loop round, second pass: 0.55, flat (floor 1). Through the real
## chain the Quest tier's sky ran short of the small birds a swallow or a
## starling grows on (1.6 catches a minute from the swallow to the pigeon
## against the full tier's 3.5; the pellets are dust by then), and the old
## ramp gave least help exactly there (x1.1): pigeon 8:21 against 4:10 on
## the tuning seeds (cl3_it9).
## Core loop fix round 1: 0.08 (x1.06 at 28 NPCs). With the pellets, the
## director and the swallow time the Quest's sky is no longer short of meals:
## at x1.52 (fx1_it3) and x1.36 (fx1_hold1, then a tuning batch) the Quest
## tier ran 1.2-1.5x ahead of the full tier (pigeon 3:30-5:30, eagle
## 12:07-21:20) at the same base growth; at ~x1.06 the two tiers climb alike.
const SKY_GROWTH_EXP := 0.08
const SKY_GROWTH_FLOOR := 1.0
const SKY_GROWTH_MAX := 2.0
## SKY_GROWTH_EXP as the loop uses it (the pacing tool's sweeps vary it;
## like SizeRules.growth_gain, every evidence file records the value it ran
## and pacing_test checks it against the shipped one).
static var sky_growth_exp := SKY_GROWTH_EXP
static var sky_growth_floor := SKY_GROWTH_FLOOR
## Final-approach magnet (core loop round, the lead's direction: "a gentle
## final-approach magnetism when prey is inside a forward cone at close
## range; a catch should feel like 'I flew into it', not a precision
## test"). Each step, every bird the player can eat that is within
## MAGNET_S of flight ahead of it (at most MAGNET_SPANS of its wingspans, or
## MAGNET_MIN_M) and inside MAGNET_CONE_DEG of its velocity is drawn towards the player's
## flight line - the line through its head along its velocity - fast enough
## to be on it when the player arrives, but never faster than MAGNET_PULL of
## the player's speed (sideways: the bird drifts into the beak's path; it is
## not pulled along it). Not a bird perched, in cover, sheltering where the
## player cannot follow, or still protected. Why: through the real flight
## chain a person's arm-flown approach passes 0.7-1.4 m from a small bird
## (the wingbeat's scatter; a sparrow's reach is ~0.5 m), and 86-96% of the
## catches needed the catch assist (integration round 2).
const MAGNET_S := 0.4
const MAGNET_SPANS := 12.0
const MAGNET_MIN_M := 2.5
const MAGNET_CONE_DEG := 45.0
const MAGNET_PULL := 0.4
## The apex goal: at the top tier, make this many worthwhile catches. 3: in
## the valley an eagle's worthwhile prey (pigeons and up) is scarce and wary,
## and 5 took a competent player about as long as the whole climb - most
## runs ran out of their 50 minutes first (fix round 2).
const APEX_CATCHES := 3
## Swallowing (core loop fix round 1, the verifier's "murmuration buffet"):
## after a catch the player cannot catch again for SWALLOW_S_PER_GAIN x the
## share of its mass the meal added (at least CatchRule.player_handling_s,
## at most SWALLOW_MAX_S) - a moth that grows a sparrow 25% is swallowed in
## ~0.6 s, a starling that grows a swallow 40% in 1 s. Round 1's 0.2 s for
## every meal let a swallow eat five starlings of a murmuration in 0.6 s.
const SWALLOW_S_PER_GAIN := 2.5
const SWALLOW_MAX_S := 1.2
## ...and a new species settles in: for TIER_SETTLE_S after a tier-up, meals
## grow the player at most to just under the next species (TIER_SETTLE_CAP
## of its mass). A lucky feast never skips the middle of the ladder or piles
## one tier-up celebration on another (held-out Quest 405 went sparrow ->
## crow in 54 s, four celebrations, off one murmuration).
const TIER_SETTLE_S := 30.0
const TIER_SETTLE_CAP := 0.99
## Birds are never faster than this; a bigger jump in one frame is a
## teleport (respawn, pooling) and is not swept for contacts.
const MAX_BIRD_SPEED := 90.0
## Catch assist: after ASSIST_START_S of play without a catch (x the square
## root of body time, SizeRules.time_scale, like the player's reach) the
## player's reach and cone start to grow, reaching full assist
## (CatchRule.ASSIST_*) at ASSIST_FULL_S; any catch resets it. A beginner
## flailing in VR gets gradually more forgiving catches; a player who catches
## regularly never sees it. Deaths do not reset it. (Round 2 ran the clock in
## plain body time: a hawk waited 2 minutes before any help and 7 for full
## help, and its dry spells in the valley ran to 10-20 minutes; a player
## feels minutes, not body-seconds. The square root halves an eagle's wait.)
const ASSIST_START_S := 30.0
const ASSIST_FULL_S := 120.0

## Drive step() from _physics_process. Tests and simulations turn this off.
@export var auto_step := true
@export var records_path := RunRecords.DEFAULT_PATH
## Write BirdModel.highlight on NPCs (edible/danger).
@export var apply_highlights := true
## NPCs keep catching each other in menus and after a run: the sky behind
## the menu is alive too. Catches involving the player need a run.
@export var npc_catches_outside_run := true
## New NPCs cannot be caught for this long (they may spawn near a predator).
@export var npc_spawn_grace_s := 1.0
## Print run milestones (off for simulations running thousands of runs).
@export var verbose := true
## >= 0 pins the catch assist (tests, chase lab); < 0 = automatic.
@export var assist_override := -1.0
## Body-time scaling of the threat cue's horizon (CUE_HORIZON_EXP); < 0
## leaves watch.ttc_horizon alone (tests that pin the watch's numbers).
@export var cue_horizon_exp := CUE_HORIZON_EXP
## Seconds of peace after shaking off an attack (ESCAPE_GRACE_S; tools vary it).
@export var escape_grace_s := ESCAPE_GRACE_S
## ATTACK_RESPITE_S (tools vary it).
@export var attack_respite_s := ATTACK_RESPITE_S
## OPENING_RESPITE_S (tests of single encounters set 0).
@export var opening_respite_s := OPENING_RESPITE_S
## DANGER_ASSIST_RESPITE (tools vary it).
@export var danger_assist_respite := DANGER_ASSIST_RESPITE
## DANGER_ASSIST_CONE_DEG (tools vary it; CatchRule reads it).
@export var danger_assist_cone_deg := DANGER_ASSIST_CONE_DEG
## BOLD_DECAY / BOLD_FLOOR (tools vary them; 1 / 1 = no boldness).
@export var bold_decay := BOLD_DECAY
@export var bold_floor := BOLD_FLOOR
## RESPAWN_RESPITE_S (tools vary it; <= 0: the attack respite).
@export var respawn_respite_s := RESPAWN_RESPITE_S
## The final-approach magnet (tools and tests switch it off).
@export var magnet := true
## The danger director calls attackers (tests of single encounters switch
## it off; the respites still apply).
@export var direct_danger := true
## Attacks survived since the last death (boldness).
var attacks_survived := 0
## Worthwhile catches since a life was last lost (LIFE_PER_MEALS).
var meals_since_life_lost := 0
## false: NPCs can never catch the player (without being told to leave it
## alone) - the AI area's mock-player setup, for the pacing tool's
## comparison of hunting pressure. Always true in the game.
@export var player_catchable := true
## The target cue checks line of sight against the world's static geometry
## (ThreatWatch.space). Tools switch it off to measure what it buys.
@export var sight_cue := true

var rule := CatchRule.new()
var watch := ThreatWatch.new()
var stats := RunStats.new()
var records: RunRecords
var phase: Phase = Phase.IDLE
var lives := MAX_LIVES
## True after continue_after_victory(): free play, no second victory.
var endless := false
## This run has been folded into the records already (a won run that is
## continued and then ends must not count as a second run or a second win).
var _run_recorded := false
var _victory_recorded := false
## The records as they were when the run started: the run summary's
## new_records flags are against these, since the run's own progress is
## saved along the way (_save_progress).
var _records_at_start := {}
## Seconds of play since the player's last catch (drives the catch assist).
var since_catch := 0.0
## 0..1: the danger assist (see DANGER_ASSIST_*).
var danger_assist := 0.0
## Timing of the last step, µs: {catch, watch, total, pairs, birds, candidates}.
var perf := {}

var _sweep := CatchSweep.new()
var _grid := CatchGrid.new()
## instance_id -> _Track: everything the loop remembers about a bird.
var _tracks := {}
## Loop clock (s of unpaused steps); timers are absolute times on it.
var _clock := 0.0
var _beat_left := 0.0
var _player_tier := -1
var _player_mass_seen := -1.0
var _player_ref: WeakRef = null
var _changing_state := false
var _emitted_level := 0.0
var _emitted_pred: Bird = null
var _last_summary := {}
var _world: World = null
## The world's refuges and their index (RefugeIndex): assigning the list
## builds the index, once per world generation, and hands the same index to
## the watch (the catch pass and the target cue ask the same question).
var _refuges: Array[Dictionary] = []:
	set(v):
		_refuges = v
		_refuge_index = RefugeIndex.new(v) if not v.is_empty() else null
		watch.use_refuges(v, _refuge_index)
var _refuge_index: RefugeIndex = null
## The predator whose strike at the player is under way (escape grace).
var _pass_pred: Bird = null
## Attack respite bookkeeping (loop clock times).
var _attack_on := false
var _attack_quiet_since := -1.0
var _respite_until := -1.0
## The first flight has ended this run.
var _first_flight_over := false
## The first tier-up's grace has been given this run.
var _first_tier_grace_given := false
## When the player first caught something this run (run time; < 0: not yet).
var _first_catch_at := -1.0
## The run clock (RunStats.run_time) of the last tier-up (-1: none yet).
var _tier_up_at := -1.0
## The danger director: the next time it may call an attacker (loop clock),
## and the attacker it last sent.
var _next_call_at := 0.0
var _sent: Bird = null
var _sent_at := -INF
## The catch lesson's moths while the lesson runs (request_lesson_prey),
## and how many times it was asked for since the last release.
var _lesson_prey: Array[Bird] = []
var _lesson_asks := 0

# Frame snapshot (parallel arrays: cheap in GDScript, no per-bird allocations).
var _snap_n := 0  # birds in this step's snapshot (0 = none taken)
var _s_birds: Array[Bird] = []
var _s_tracks: Array[_Track] = []
var _s_pos := PackedVector3Array()
var _s_prev := PackedVector3Array()
var _s_mid := PackedVector3Array()
var _s_mass := PackedFloat64Array()
var _s_flags := PackedByteArray()  # bit0 player, bit1 may eat, bit2 may be eaten

const _F_PLAYER := 1
const _F_EAT := 2
const _F_PREY := 4

## Broad phase used by the catch pass: the spatial hash (CatchGrid), or
## sort-and-sweep (CatchSweep, up to CatchSweep.MAX_ITEMS birds). Both are
## exact supersets of the pairs within reach and contacts are resolved in a
## sorted order, so the choice changes the cost, never an outcome.
enum BroadPhase { SWEEP, HASH }
@export var broad_phase: BroadPhase = BroadPhase.HASH


## Per-bird memory. One dictionary lookup per bird per frame; timers are
## absolute loop-clock times so nothing has to tick them down.
class _Track:
	var prev := Vector3.ZERO
	var has_prev := false
	var protect_until := -1.0
	var handling_until := -1.0
	## Mass when first seen (NPC growth cap); < 0 = not yet known.
	var base_mass := -1.0
	## Cached geometry, valid while mass == geom_mass.
	var geom_mass := -1.0
	var span := 0.0
	var radius := 0.0

	func geometry(b: Bird) -> void:
		if b.mass != geom_mass:
			geom_mass = b.mass
			span = b.get_wingspan()
			radius = b.get_body_radius()


static func find(tree: SceneTree) -> GameLoop:
	return tree.get_first_node_in_group(&"game_loop") as GameLoop


static func apex_tier() -> int:
	return SizeRules.SPECIES.size() - 1


func _enter_tree() -> void:
	add_to_group(&"game_loop")


func _ready() -> void:
	# Gameplay pauses with the tree (the rig, UI and audio keep running).
	process_mode = Node.PROCESS_MODE_PAUSABLE
	# Run after the birds have moved this tick, so contacts use this tick's
	# positions.
	process_physics_priority = 100
	records = RunRecords.new(records_path)
	records.load_records()
	stats.reset(START_MASS)
	Events.game_state_changed.connect(_on_game_state_changed)
	Events.bird_spawned.connect(_on_bird_spawned)
	Events.bird_removed.connect(_on_bird_removed)
	_find_world.call_deferred()


func _exit_tree() -> void:
	_save_progress()
	if Events.game_state_changed.is_connected(_on_game_state_changed):
		Events.game_state_changed.disconnect(_on_game_state_changed)
		Events.bird_spawned.disconnect(_on_bird_spawned)
		Events.bird_removed.disconnect(_on_bird_removed)


func _physics_process(delta: float) -> void:
	if auto_step:
		step(delta)


func _notification(what: int) -> void:
	# On Quest a session often ends from the system menu or by taking the
	# headset off: the app is paused or killed without a run end. Bests
	# reached so far must survive that.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED \
			or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_save_progress()


# =====================================================================
# Run flow
# =====================================================================

## Starts a fresh run from any state: resets the player, lives, stats, the
## ecosystem and all catch bookkeeping, then enters PLAYING.
func start_run() -> void:
	_clear_watch()
	phase = Phase.PLAYING
	endless = false
	_run_recorded = false
	_victory_recorded = false
	_records_at_start = records.to_dict()
	danger_assist = 0.0
	attacks_survived = 0
	meals_since_life_lost = 0
	_attack_on = false
	# First flight (OPENING_RESPITE_S): nothing hunts a new run's player yet
	# (a rolling half second, renewed by step() until the first flight ends).
	_respite_until = _clock + minf(0.5, opening_respite_s) if opening_respite_s > 0.0 else -1.0
	_first_flight_over = opening_respite_s <= 0.0
	_first_tier_grace_given = false
	_first_catch_at = -1.0
	_tier_up_at = -1.0
	_next_call_at = 0.0
	_sent = null
	_lesson_prey.clear()
	_lesson_asks = 0
	lives = MAX_LIVES
	_beat_left = 0.0
	_tracks.clear()
	since_catch = 0.0
	stats.reset(START_MASS)
	_last_summary = {}
	var p := Birds.player()
	if p:
		p.alive = true
		p.velocity = Vector3.ZERO
		_set_player_mass(p, START_MASS, &"reset")
		_place_player(p)
		if p.has_method(&"set_controls_enabled"):
			p.call(&"set_controls_enabled", true)
		set_protection(p, START_PROTECT_S)
	# Repopulate around the reset player (the AI area's Ecosystem).
	var eco := get_tree().get_first_node_in_group(&"ecosystem") if is_inside_tree() else null
	if eco and eco.has_method(&"reset"):
		eco.call(&"reset")
	Game.run_time = 0.0
	_set_game_state(Game.State.PLAYING)
	lives_changed.emit(lives)
	Events.run_started.emit()
	if verbose:
		print("[gameloop] run started: mass %.3f, %d lives" % [START_MASS, lives])


func restart_run() -> void:
	start_run()


## Ends the run (reason: &"caught" lives exhausted, &"victory", &"quit").
## Records are updated and saved; Events.run_ended carries the summary.
func end_run(reason: StringName = &"quit") -> void:
	if phase == Phase.IDLE or phase == Phase.ENDED:
		return
	phase = Phase.ENDED
	_beat_left = 0.0
	var summary := _build_summary(reason)
	summary["new_records"] = _record(summary)
	summary["records"] = records.to_dict()
	_last_summary = summary
	var p := Birds.player()
	if p and reason != &"victory" and p.has_method(&"set_controls_enabled"):
		p.call(&"set_controls_enabled", false)
	_clear_watch()
	_set_game_state(Game.State.ENDED)
	if verbose:
		print("[gameloop] run ended (%s): score %d, peak %s, %d catches, %.0f s" % [
			reason, summary["score"], summary["peak_species"], summary["catches"], summary["duration_s"]])
	if reason == &"victory":
		victory.emit(summary)
	Events.run_ended.emit(summary)


## Leaves the run for the main menu. Bests still count (records are saved)
## but no run_ended summary is shown.
func to_menu() -> void:
	_abandon_run()
	_set_game_state(Game.State.MENU)


## Ends the run without a summary (the UI's "Quit to menu" calls this, then
## sets Game.MENU itself). Bests still count.
func quit_run() -> void:
	_abandon_run()


## Pause from PLAYING or CAUGHT (the CAUGHT beat resumes where it was).
func pause() -> void:
	if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
		_save_progress()
		_set_game_state(Game.State.PAUSED)


## Leaves PAUSED back to whatever the run was doing.
func resume() -> void:
	if Game.state != Game.State.PAUSED:
		return
	match phase:
		Phase.PLAYING:
			_set_game_state(Game.State.PLAYING)
		Phase.CAUGHT:
			_set_game_state(Game.State.CAUGHT)
		Phase.ENDED:
			_set_game_state(Game.State.ENDED)
		_:
			_set_game_state(Game.State.MENU)


## After a victory: keep flying in the same run (no further victory).
func continue_after_victory() -> void:
	if phase != Phase.ENDED or not stats.victory:
		return
	var keep_time := Game.run_time
	phase = Phase.PLAYING
	endless = true
	var p := Birds.player()
	if p and p.has_method(&"set_controls_enabled"):
		p.call(&"set_controls_enabled", true)
	_set_game_state(Game.State.PLAYING)
	Game.run_time = keep_time


func get_last_summary() -> Dictionary:
	return _last_summary


func _abandon_run() -> void:
	if phase == Phase.PLAYING or phase == Phase.CAUGHT:
		var summary := _build_summary(&"quit")
		_record(summary)
		_last_summary = summary
	phase = Phase.IDLE
	_beat_left = 0.0
	_clear_watch()


## Folds the run into the records. A run counts once and a victory once,
## however many times the run ends (victory, continue_after_victory(), then
## caught or quit): later submissions only raise the bests. Returns the
## records the run broke, against the bests at its start.
func _record(summary: Dictionary) -> Dictionary:
	var won := bool(summary.get("victory", false))
	records.submit(summary, not _run_recorded, won and not _victory_recorded)
	_run_recorded = true
	_victory_recorded = _victory_recorded or won
	return RunRecords.broken(_records_at_start, summary)


## Saves the bests of the run in progress without counting it as a run (it
## is counted when it ends): at every new peak tier, on pause, and when the
## app is paused, loses focus or is closed.
func _save_progress() -> void:
	if records != null and (phase == Phase.PLAYING or phase == Phase.CAUGHT):
		records.submit(_build_summary(&"progress"), false, false)


func _set_game_state(s: Game.State) -> void:
	_changing_state = true
	Game.set_state(s)
	_changing_state = false


func _on_game_state_changed(new_state: int, old_state: int) -> void:
	if _changing_state:
		return
	# Someone else (UI) moved the state machine; keep the run consistent.
	match new_state:
		Game.State.PAUSED:
			# (UI pauses on focus loss: headset off, system menu.)
			_save_progress()
		Game.State.PLAYING:
			if old_state == Game.State.MENU or old_state == Game.State.ENDED or old_state == Game.State.BOOT:
				# (continue_after_victory() changes state through
				# _set_game_state, which this handler ignores, so any
				# ENDED -> PLAYING seen here is a UI asking for a new run.)
				start_run()
			elif old_state == Game.State.PAUSED and phase == Phase.CAUGHT:
				# Unpaused mid-beat: the beat is not over yet.
				_set_game_state.call_deferred(Game.State.CAUGHT)
		Game.State.MENU:
			_abandon_run()
		Game.State.ENDED:
			if phase == Phase.PLAYING or phase == Phase.CAUGHT:
				end_run(&"quit")


# =====================================================================
# Per-frame step
# =====================================================================

func step(dt: float) -> void:
	if dt <= 0.0 or (is_inside_tree() and get_tree().paused):
		return
	var t0 := Time.get_ticks_usec()
	_clock += dt
	var p := Birds.player()
	_sync_player(p)
	# (Protection is only ever granted in PLAYING and ends when the player is
	# caught or eats; timers are on the loop clock, which stops while the
	# tree is paused, so a pause freezes it with no extra bookkeeping.)
	if phase == Phase.PLAYING:
		stats.tick(dt, _player_tier)
		since_catch += dt
		if opening_respite_s > 0.0 and not _first_flight_over:
			# The first flight: until OPENING_AFTER_CATCH_S after the first
			# catch, between OPENING_MIN_S and opening_respite_s of play (a
			# rolling half second, so it ends on time).
			var end_at := opening_respite_s
			if _first_catch_at >= 0.0:
				end_at = clampf(_first_catch_at + OPENING_AFTER_CATCH_S, minf(OPENING_MIN_S, opening_respite_s), opening_respite_s)
			if stats.run_time < end_at:
				_respite_until = maxf(_respite_until, _clock + minf(0.5, end_at - stats.run_time))
			else:
				_first_flight_over = true
		if not _first_tier_grace_given and stats.peak_tier > SizeRules.tier_for_mass(START_MASS):
			# The first tier-up: a grace for the new size (FIRST_TIER_GRACE_S).
			_first_tier_grace_given = true
			_respite_until = maxf(_respite_until, _clock + FIRST_TIER_GRACE_S)
		danger_assist *= exp(-dt / (DANGER_ASSIST_TAU_S * rule.player_time_scale))
		if _player_tier >= apex_tier():
			stats.reign_time += dt
	elif phase == Phase.CAUGHT:
		_beat_left -= dt
		if _beat_left <= 0.0:
			_after_beat()
	if p:
		# The AI area's brains leave a bird with meta "npc_ignore" alone:
		# NPCs do not stalk a protected (just respawned) player.
		var ignore := protection_left(p) > 0.0 or respite_left() > 0.0
		if bool(p.get_meta(&"npc_ignore", false)) != ignore:
			p.set_meta(&"npc_ignore", ignore)
	rule.player_assist = assist_override if assist_override >= 0.0 else catch_assist()
	rule.player_time_scale = SizeRules.time_scale(p.mass) if p else 1.0
	rule.player_danger_assist = danger_assist
	rule.danger_assist_cone_deg = danger_assist_cone_deg
	watch.body_time = rule.player_time_scale
	if cue_horizon_exp >= 0.0:
		watch.ttc_horizon = CUE_HORIZON_S * pow(rule.player_time_scale, cue_horizon_exp) \
				* (1.0 + DANGER_ASSIST_CUE * danger_assist)
	if p != null and phase == Phase.PLAYING:
		if magnet:
			_magnet(p, dt)
		if direct_danger:
			_direct_danger(p)
	var t1 := Time.get_ticks_usec()
	_snap_n = 0
	_resolve_catches(dt)
	var t2 := Time.get_ticks_usec()
	_update_watch(Birds.player(), dt)
	var t3 := Time.get_ticks_usec()
	_remember_positions()
	perf["catch"] = t2 - t1
	perf["watch"] = t3 - t2
	perf["total"] = Time.get_ticks_usec() - t0


## Where every bird was at the end of this step: the start of next step's
## swept segments. Reuses the snapshot positions (nothing moves birds between
## the snapshot and here except a respawn, which re-reads the player).
func _remember_positions() -> void:
	if _snap_n > 0 and Birds.count() == _snap_n:
		for i in _snap_n:
			var t := _s_tracks[i]
			t.prev = _s_pos[i]
			t.has_prev = true
		var p := Birds.player()
		if p:
			_track(p).prev = p.get_body_position()
		return
	for b in Birds.all():
		var t := _track(b)
		t.prev = b.get_body_position()
		t.has_prev = true


func _track(b: Bird) -> _Track:
	var id := b.get_instance_id()
	var t: _Track = _tracks.get(id)
	if t == null:
		t = _Track.new()
		_tracks[id] = t
	return t


func _sync_player(p: Bird) -> void:
	if p == null:
		return
	var same: bool = _player_ref != null and _player_ref.get_ref() == p
	if not same or not is_equal_approx(p.mass, _player_mass_seen):
		# A new player bird, or someone else changed its mass: adopt it
		# silently (tier events are only for growth the loop caused).
		_player_ref = weakref(p)
		_player_mass_seen = p.mass
		_player_tier = SizeRules.tier_for_mass(p.mass)
		# The player's species always follows its mass, whoever set it.
		p.species = SizeRules.species_for_mass(p.mass)
		if phase == Phase.PLAYING or phase == Phase.CAUGHT:
			stats.on_player_mass(p.mass)


# =====================================================================
# Catches
# =====================================================================

func _resolve_catches(dt: float) -> void:
	var birds := Birds.all()
	var n := birds.size()
	perf["birds"] = n
	perf["pairs"] = 0
	perf["candidates"] = 0
	if n < 2:
		return
	var player_ok := phase == Phase.PLAYING
	var npc_ok := phase == Phase.PLAYING or phase == Phase.CAUGHT or npc_catches_outside_run
	if not player_ok and not npc_ok:
		return
	var t_snap := Time.get_ticks_usec()
	_snap_n = n
	_s_birds = birds.duplicate()
	_s_tracks.resize(n)
	_s_pos.resize(n)
	_s_prev.resize(n)
	_s_mid.resize(n)
	_s_mass.resize(n)
	_s_flags.resize(n)
	var teleport2 := (MAX_BIRD_SPEED * dt + 1.0) ** 2
	var clock := _clock
	var max_rad := 0.0
	var max_reach := 0.0
	var max_disp2 := 0.0
	var active := PackedInt32Array()
	for i in n:
		var b := _s_birds[i]
		var id := b.get_instance_id()
		var t: _Track = _tracks.get(id)
		if t == null:
			t = _Track.new()
			_tracks[id] = t
		_s_tracks[i] = t
		var pos := b.get_body_position()
		var prev := t.prev if t.has_prev else pos
		var disp2 := prev.distance_squared_to(pos)
		if disp2 > teleport2:
			# Respawn / pooling jump: not a flight path, do not sweep it.
			prev = pos
			disp2 = 0.0
		_s_pos[i] = pos
		_s_prev[i] = prev
		var is_p := b.is_player()
		var flags := _F_PLAYER if is_p else 0
		# A bird in cover (CatchRule.is_hidden) is out of play until it comes out.
		if b.alive and (player_ok if is_p else npc_ok) and (is_p or not CatchRule.is_hidden(b)):
			if t.handling_until <= clock:
				flags |= _F_EAT
			if t.protect_until <= clock and (player_catchable or not is_p):
				flags |= _F_PREY
		_s_flags[i] = flags
		if flags & (_F_EAT | _F_PREY) == 0:
			continue
		var m := b.mass
		if t.base_mass < 0.0 and not is_p:
			t.base_mass = m
		t.geometry(b)
		_s_mass[i] = m
		_s_mid[i] = (prev + pos) * 0.5
		max_rad = maxf(max_rad, t.radius)
		max_reach = maxf(max_reach, t.span * rule.player_reach_spans() if is_p else t.span * rule.npc_reach_max())
		max_disp2 = maxf(max_disp2, disp2)
		active.append(i)
	perf["snapshot"] = Time.get_ticks_usec() - t_snap
	if active.size() < 2:
		return
	# Any pair that can touch this frame has segment midpoints within this
	# distance on every axis: contact + half of each bird's displacement.
	var reach := 2.0 * max_rad + max_reach + sqrt(max_disp2)
	var t_pairs := Time.get_ticks_usec()
	var pairs: PackedInt32Array
	if broad_phase == BroadPhase.HASH or active.size() > CatchSweep.MAX_ITEMS:
		pairs = _grid.pairs_of(_s_mid, active, reach)
	else:
		pairs = _sweep.pairs(_s_mid, active, reach)
	perf["pairs"] = pairs.size() / 2
	perf["broad"] = Time.get_ticks_usec() - t_pairs
	var cands: Array = []
	for k in range(0, pairs.size(), 2):
		var i := pairs[k]
		var j := pairs[k + 1]
		var pred := -1
		var prey := -1
		if _s_mass[i] >= _s_mass[j] * SizeRules.EAT_RATIO:
			pred = i
			prey = j
		elif _s_mass[j] >= _s_mass[i] * SizeRules.EAT_RATIO:
			pred = j
			prey = i
		else:
			continue
		if _s_flags[pred] & _F_EAT == 0 or _s_flags[prey] & _F_PREY == 0:
			continue
		var pl := _s_flags[pred] & _F_PLAYER != 0
		var ql := _s_flags[prey] & _F_PLAYER != 0
		var tp := _s_tracks[pred]
		var tq := _s_tracks[prey]
		var contact := rule.contact_distance(tp.radius, tp.span, pl, tq.radius, ql)
		# Cheap reject before the swept test: segments too far apart.
		var gap := contact + (_s_pos[pred].distance_to(_s_prev[pred]) + _s_pos[prey].distance_to(_s_prev[prey])) * 0.5
		if _s_mid[pred].distance_squared_to(_s_mid[prey]) > gap * gap:
			continue
		var bp := _s_birds[pred]
		var v := bp.velocity
		var vdir := v / v.length() if v.length_squared() > 1e-6 else Vector3.ZERO
		var overlap := (tp.radius + tq.radius) * rule.overlap_fraction
		var t := rule.contact_time(_s_prev[pred], _s_pos[pred], _s_prev[prey], _s_pos[prey],
				contact, overlap, bp.get_forward(), vdir, pl, ql)
		if t < 0.0:
			continue
		if _refuge_blocks(_s_prev[prey].lerp(_s_pos[prey], t), tp.span):
			continue
		cands.append([t, -_s_mass[pred], -_s_mass[prey], _s_pos[pred].x, _s_pos[pred].z,
				_s_pos[prey].x, _s_pos[prey].z, pred, prey])
	perf["candidates"] = cands.size()
	if cands.is_empty():
		return
	cands.sort_custom(_candidate_before)
	# Resolve and apply in contact order: once eaten, a bird can neither be
	# eaten again nor eat later in the frame; a predator eats at most once per
	# frame. The size ratio is checked again at the moment of each catch, with
	# the masses as they are then: a player that has just eaten may have
	# outgrown the bird about to strike it later in the same frame, and must
	# not be eaten by something now smaller than it (fix round 2 review).
	var eaten := {}
	var ate := {}
	for c: Array in cands:
		var pred: int = c[7]
		var prey: int = c[8]
		if eaten.has(pred) or eaten.has(prey) or ate.has(pred):
			continue
		if _commit_catch(_s_birds[pred], _s_birds[prey]):
			eaten[prey] = true
			ate[pred] = true


## Contact order: earliest contact time, then heavier predator, heavier prey,
## then positions (never registration order, so the outcome does not depend
## on which bird happened to spawn first).
static func _candidate_before(a: Array, b: Array) -> bool:
	for k in 7:
		if a[k] != b[k]:
			return a[k] < b[k]
	return a[7] < b[7]


func _refuge_blocks(prey_pos: Vector3, pred_span: float) -> bool:
	return _refuge_index != null and _refuge_index.blocks(prey_pos, pred_span)


## Whether `prey` is out of reach of a predator `pred_span` wide right now:
## in cover (CatchRule.is_hidden), or inside a refuge too small for the
## predator (the catch rule's refuge test). The target cue skips such prey,
## and a modelled player drops them: a bird that has dived into a hedge is
## not a chase to point anyone at.
func is_sheltered(prey: Bird, pred_span: float) -> bool:
	return CatchRule.is_hidden(prey) or _refuge_blocks(prey.get_body_position(), pred_span)


## Applies one catch; false if it cannot happen any more (see the callers).
func _commit_catch(pred: Bird, prey: Bird) -> bool:
	if not is_instance_valid(pred) or not is_instance_valid(prey) or not pred.alive or not prey.alive:
		return false
	# An earlier catch this frame may have ended the run or killed the
	# player (victory, caught): player catches need a run in progress.
	if (prey.is_player() or pred.is_player()) and phase != Phase.PLAYING:
		return false
	# ...or changed a mass: the ratio must still hold now.
	if pred.mass < prey.mass * SizeRules.EAT_RATIO:
		return false
	var prey_mass := prey.mass
	var prey_species := prey.species
	# Facts first, while the prey is still where it was caught.
	Events.bird_caught.emit(pred, prey)
	if prey.is_player():
		_player_caught(prey, pred)
	else:
		prey.alive = false
		prey.on_caught(pred)
	_track(pred).handling_until = _clock + rule.handling_s(pred.is_player())
	if pred.is_player():
		_player_ate(pred, prey, prey_mass, prey_species)
	else:
		_npc_ate(pred, prey, prey_mass)
	return true


func _npc_ate(pred: Bird, prey: Bird, prey_mass: float) -> void:
	var t := _track(pred)
	var base := t.base_mass if t.base_mass > 0.0 else pred.mass
	var old := pred.mass
	var cap := maxf(base * (1.0 + NPC_GROWTH_CAP), old)
	var new_mass := minf(old + SizeRules.meal_gain(old, prey_mass) * NPC_GROWTH_SHARE, cap)
	pred.mass = new_mass
	pred.on_ate(prey, new_mass - old)
	if phase == Phase.PLAYING or phase == Phase.CAUGHT:
		stats.npc_catches += 1


func _player_ate(p: Bird, prey: Bird, prey_mass: float, prey_species: StringName) -> void:
	var tier_before := _player_tier
	var old := p.mass
	var worthwhile := SizeRules.is_worthwhile(old, prey_mass)
	var new_mass := minf(old + SizeRules.meal_gain(old, prey_mass) * sky_growth(old), MAX_PLAYER_MASS)
	# A new species settles in (TIER_SETTLE_S).
	if _tier_up_at >= 0.0 and stats.run_time - _tier_up_at < TIER_SETTLE_S and tier_before >= 0 \
			and tier_before + 1 < SizeRules.SPECIES.size():
		new_mass = minf(new_mass, maxf(old, float(SizeRules.SPECIES[tier_before + 1]["mass"]) * TIER_SETTLE_CAP))
	# Swallowing (SWALLOW_S_PER_GAIN).
	var tr := _track(p)
	tr.handling_until = maxf(tr.handling_until, _clock + minf(SWALLOW_MAX_S, SWALLOW_S_PER_GAIN * (new_mass - old) / maxf(old, 1e-6)))
	if _first_catch_at < 0.0:
		_first_catch_at = stats.run_time
	stats.on_player_ate(prey_species, prey_mass, new_mass - old, worthwhile)
	if worthwhile and lives < MAX_LIVES:
		meals_since_life_lost += 1
		if meals_since_life_lost >= LIFE_PER_MEALS:
			meals_since_life_lost = 0
			lives += 1
			lives_changed.emit(lives)
	# Spawn protection ends when you attack (no invulnerable rampages).
	set_protection(p, 0.0)
	since_catch = 0.0
	_set_player_mass(p, new_mass, &"meal")
	p.on_ate(prey, new_mass - old)
	if tier_before >= apex_tier() and worthwhile and phase == Phase.PLAYING:
		stats.apex_catches += 1
		apex_progress.emit(stats.apex_catches, APEX_CATCHES)
		if stats.apex_catches >= APEX_CATCHES and not stats.victory and not endless:
			stats.victory = true
			end_run(&"victory")


func _player_caught(p: Bird, pred: Bird) -> void:
	lives -= 1
	meals_since_life_lost = 0
	danger_assist = minf(1.0, danger_assist + DANGER_ASSIST_PER_DEATH)
	stats.on_player_caught(pred.species)
	phase = Phase.CAUGHT
	_beat_left = CAUGHT_BEAT_S
	p.alive = false
	p.on_caught(pred)
	if p.has_method(&"set_controls_enabled"):
		p.call(&"set_controls_enabled", false)
	_clear_watch()
	lives_changed.emit(lives)
	Events.player_caught.emit(pred)
	_set_game_state(Game.State.CAUGHT)
	if verbose:
		print("[gameloop] player caught by %s; %d lives left" % [pred.species, lives])


func _after_beat() -> void:
	if lives > 0:
		_respawn_player()
	else:
		end_run(&"caught")


func _respawn_player() -> void:
	phase = Phase.PLAYING
	_beat_left = 0.0
	var p := Birds.player()
	if p:
		var penalised := maxf(START_MASS, p.mass * (1.0 - death_penalty()))
		_set_player_mass(p, penalised, &"penalty")
		p.alive = true
		p.velocity = Vector3.ZERO
		_place_player(p)
		_track(p).has_prev = false
		if p.has_method(&"set_controls_enabled"):
			p.call(&"set_controls_enabled", true)
		set_protection(p, respawn_protection())
		_attack_on = false
		attacks_survived = 0
		_start_respite(p, respawn_respite_s if respawn_respite_s > 0.0 else attack_respite_s)
	_set_game_state(Game.State.PLAYING)
	player_respawned.emit(respawn_protection())


func _place_player(p: Bird) -> void:
	var xf := Transform3D(Basis.IDENTITY, Vector3(0, 30, 0))
	var w := _find_world()
	if w:
		xf = w.get_player_spawn()
	if p.has_method(&"respawn"):
		p.call(&"respawn", xf)
	else:
		p.global_transform = xf


## The single place the player's mass changes: species follows mass, tier
## events fire exactly once per change, new peaks give a life back.
func _set_player_mass(p: Bird, new_mass: float, reason: StringName) -> void:
	var old := p.mass
	var old_tier := _player_tier if _player_tier >= 0 else SizeRules.tier_for_mass(old)
	new_mass = clampf(new_mass, 0.001, MAX_PLAYER_MASS)
	p.mass = new_mass
	p.species = SizeRules.species_for_mass(new_mass)
	var tier := SizeRules.tier_for_mass(new_mass)
	_player_tier = tier
	_player_mass_seen = p.mass
	_player_ref = weakref(p)
	var peak_before := stats.peak_tier
	stats.on_player_mass(new_mass)
	player_mass_changed.emit(old, new_mass, reason)
	if reason == &"reset":
		return
	if new_mass > old:
		Events.player_grew.emit(old, new_mass, tier)
	if tier > old_tier and reason == &"meal":
		_tier_up_at = stats.run_time
	if tier != old_tier:
		Events.player_tier_changed.emit(old_tier, tier)
		if verbose:
			print("[gameloop] tier %s -> %s" % [SizeRules.SPECIES[old_tier]["id"], SizeRules.SPECIES[tier]["id"]])
	if tier > peak_before:
		if LIFE_ON_NEW_TIER and lives < MAX_LIVES:
			lives += 1
			lives_changed.emit(lives)
		if tier >= apex_tier() and stats.apex_reached_at < 0.0:
			stats.apex_reached_at = stats.run_time
			apex_reached.emit()
		# A new peak is a best worth keeping even if the app dies next.
		_save_progress()


# =====================================================================
# Threat / target
# =====================================================================

func _update_watch(p: Bird, dt: float) -> void:
	if p == null or not p.alive or phase != Phase.PLAYING or not p.is_inside_tree():
		_clear_watch()
		return
	# The cue names only prey the player can see (ThreatWatch.space).
	watch.space = p.get_world_3d().direct_space_state if sight_cue else null
	watch.lesson_active = not _lesson_prey.is_empty()
	var old_target := watch.target
	var mask := watch.update(p, Birds.all(), dt, rule, apply_highlights)
	_track_passes(p)
	_track_attacks(p)
	if mask & 1:
		var lv := watch.level
		if watch.predator != _emitted_pred or absf(lv - _emitted_level) >= 0.02 \
				or (lv == 0.0 and _emitted_level > 0.0) or (lv >= 1.0 and _emitted_level < 1.0):
			var old_pred := _emitted_pred
			_emitted_level = lv
			_emitted_pred = watch.predator
			Events.threat_changed.emit(lv, watch.predator)
			if apply_highlights:
				# Listeners (the UI) mark the named predator by their own rule
				# (its level against a threshold): the loop's classification
				# of both birds is what the frame ends with.
				watch.reassert_highlight(old_pred)
				watch.reassert_highlight(watch.predator)
	if mask & 2:
		Events.target_changed.emit(watch.target)
		if apply_highlights:
			watch.reassert_highlight(old_target)
			watch.reassert_highlight(watch.target)


## Escape grace: follows the attack run of the most dangerous predator; when
## it has come within striking distance and is past again without a catch,
## the player shook it off.
func _track_passes(p: Bird) -> void:
	var q := _pass_pred
	if q != null and (not is_instance_valid(q) or not q.alive):
		_pass_pred = null
		q = null
	var span := 0.0
	var gap := INF
	if q != null:
		span = q.get_wingspan()
		gap = q.get_body_position().distance_to(p.get_body_position()) - rule.contact_distance(
				q.get_body_radius(), span, false, p.get_body_radius(), true)
		if gap > PASS_CLEAR_SPANS * span:
			_pass_pred = null
			stats.escapes += 1
			set_protection(p, maxf(protection_left(p), escape_grace_s + DANGER_ASSIST_GRACE_S * danger_assist))
			_attack_on = false
			attacks_survived += 1
			_start_respite(p)
			escaped.emit(q)
			if verbose:
				print("[gameloop] shook off a %s" % q.species)
			return
	var w := watch.predator
	# (Only a pass by a bird hunting the player - or within
	# DANGER_MARK_HOLD_S of hunting it - is a strike it escaped. Core loop
	# round, second pass: a crow merely named for flying past a sparrow in
	# its first flight counted as an attack shaken off and started the full
	# attack respite, and the sky's first attack came 1-2 minutes late.)
	if q == null and w != null and is_instance_valid(w) and w.alive \
			and (ThreatWatch.intent_weight(w, p) >= 1.0 or watch.hunted_recently(w)):
		var ws := w.get_wingspan()
		var wg := w.get_body_position().distance_to(p.get_body_position()) - rule.contact_distance(
				w.get_body_radius(), ws, false, p.get_body_radius(), true)
		if wg < PASS_SPANS * ws:
			_pass_pred = w


## Attack respite: an attack is on while any predator hunting the player
## is up (ThreatWatch.hunt_peak_level: whoever the cue names); when every
## one has been quiet for ATTACK_QUIET_S the attack is over and the respite
## starts. (A bird merely passing close is no attack.)
func _track_attacks(p: Bird) -> void:
	if watch.hunt_peak_level >= ATTACK_LEVEL:
		if not _attack_on:
			stats.attacks += 1
			_sent = null
		_attack_on = true
		_attack_quiet_since = -1.0
	elif _attack_on:
		if watch.hunt_peak_level > ATTACK_QUIET_LEVEL:
			_attack_quiet_since = -1.0
		elif _attack_quiet_since < 0.0:
			_attack_quiet_since = _clock
		elif _clock - _attack_quiet_since >= ATTACK_QUIET_S:
			_attack_on = false
			attacks_survived += 1
			_start_respite(p)
			if verbose:
				print("[gameloop] attack over at %.0f s: respite %.0f s" % [stats.run_time, respite_left()])


## Starts a respite of `base` (default: attack_respite(), the interval to the
## next attack at the player's size) x the danger assist's factor x
## boldness (the k-th attack survived since the last death:
## BOLD_DECAY^(k-1), at least BOLD_FLOOR).
func _start_respite(p: Bird, base: float = -1.0) -> void:
	var span := (attack_respite(p.mass if p else START_MASS) if base < 0.0 else base) \
			* (1.0 + danger_assist_respite * danger_assist) \
			* maxf(bold_floor, pow(bold_decay, maxi(attacks_survived - 1, 0)))
	_respite_until = maxf(_respite_until, _clock + span)
	_next_call_at = maxf(_next_call_at, _respite_until)


## The respite after an attack for a player of mass m: attack_respite_s at
## the first species, falling linearly in tiers to ATTACK_RESPITE_APEX of it
## at the apex (bigger birds are hunted more often).
func attack_respite(m: float) -> float:
	var t0 := SizeRules.tier_for_mass(START_MASS)
	var k := clampf(float(SizeRules.tier_for_mass(m) - t0) / float(apex_tier() - t0), 0.0, 1.0)
	return attack_respite_s * lerpf(1.0, ATTACK_RESPITE_APEX, k)


## The danger director (see ATTACK_RESPITE_S): with the respite over, no
## attack on and the player not protected, ask the sky for an attacker
## (every ATTACK_CALL_RETRY_S until one comes).
func _direct_danger(p: Bird) -> void:
	if respite_left() > 0.0 or _attack_on or protection_left(p) > 0.0 or _clock < _next_call_at:
		return
	# One telegraphed attack at a time: while the bird last sent is still on
	# its way (hunting the player, no attack yet) no other is called, for up
	# to ATTACK_SENT_WAIT_S (core loop round, second pass: the retry sent a
	# second and a third hunter every 5 s while the first was approaching).
	if _sent != null and is_instance_valid(_sent) and _sent.alive and _clock - _sent_at < ATTACK_SENT_WAIT_S \
			and (&"target" in _sent) and _sent.get(&"target") == p:
		return
	_next_call_at = _clock + ATTACK_CALL_RETRY_S
	var eco := get_tree().get_first_node_in_group(&"ecosystem") if is_inside_tree() else null
	if eco == null or not eco.has_method(&"send_attacker"):
		return
	var q: Variant = eco.call(&"send_attacker", p)
	if verbose and not (q is Bird) and &"last_attack_fail" in eco:
		print("[gameloop] no attacker to send (%s)" % eco.get(&"last_attack_fail"))
	if q is Bird and is_instance_valid(q):
		_sent = q
		_sent_at = _clock
		stats.attacks_sent += 1
		if verbose:
			print("[gameloop] the sky sends a %s at the player (%.0f m)" % [(q as Bird).species,
					(q as Bird).get_body_position().distance_to(p.get_body_position())])


## The final-approach magnet (see MAGNET_S): prey the player is flying
## straight at drifts onto its flight line.
func _magnet(p: Bird, dt: float) -> void:
	var v := p.velocity
	var sp := v.length()
	if sp < 1.0 or not p.alive:
		return
	var dir := v / sp
	var pp := p.get_body_position()
	var span := p.get_wingspan()
	var r := minf(maxf(MAGNET_SPANS * span, MAGNET_MIN_M), MAGNET_S * sp + rule.contact_distance(p.get_body_radius(), span, true, 0.0))
	var cos_c := cos(deg_to_rad(MAGNET_CONE_DEG))
	var edible := p.mass / SizeRules.EAT_RATIO
	var pulled := 0
	for b in Birds.all():
		if b == p or not b.alive or b.mass > edible or b.perched:
			continue
		var bp := b.get_body_position()
		var rel := bp - pp
		var along := rel.dot(dir)
		if along <= 0.0 or along > r:
			continue
		var d := rel.length()
		if along < cos_c * d:
			continue
		if CatchRule.is_hidden(b) or protection_left(b) > 0.0 or _refuge_blocks(bp, span):
			continue
		var lat := rel - dir * along
		var e := lat.length()
		if e < 1e-4:
			continue
		var closing := maxf(sp - b.velocity.dot(dir), 0.5)
		var t_arrive := maxf(along / closing, dt)
		var step_m := minf(minf(e / t_arrive, MAGNET_PULL * sp) * dt, e)
		b.global_position -= lat / e * step_m
		pulled += 1
	perf["magnet"] = pulled


## The first catch lesson's prey (for the UI's onboarding, the lead's
## direction: "a competent new player completes the catch lesson within 1-2
## minutes"): the Ecosystem places a slow, unaware moth swarm in open air
## ahead of the player's path - `near` (default: the player's head) along
## its flight - and keeps it ahead of the player until the lesson is
## released (release_lesson_prey). Calling it again while the lesson runs
## (the UI's help after a while without a catch) puts the swarm ahead of the
## player again, nearer each time (MothField.LESSON_HELP_M a call). Returns
## the moths (empty without an Ecosystem that offers it, or with no open
## air ahead). See docs/areas/GAMELOOP.md, "Lesson prey".
func request_lesson_prey(near: Vector3 = Vector3.INF) -> Array[Bird]:
	var out: Array[Bird] = []
	var eco := get_tree().get_first_node_in_group(&"ecosystem") if is_inside_tree() else null
	if eco == null or not eco.has_method(&"request_lesson_prey"):
		return out
	_lesson_asks += 1
	var p := Birds.player()
	var pos := near
	if pos == Vector3.INF:
		pos = p.get_body_position() if p else Vector3.ZERO
	var dir := Vector3.ZERO
	if p:
		dir = p.velocity if p.velocity.length() > 1.0 else p.get_forward()
	var got: Variant = eco.call(&"request_lesson_prey", pos, dir, _lesson_asks - 1)
	if got is Array:
		for b: Variant in got:
			if b is Bird:
				out.append(b)
	_lesson_prey = out.duplicate()
	return out


## The lesson is over (a catch, its timeout, a skip): the lesson swarm goes
## (its moths leave the sky; the pellets of the ordinary swarms stay).
func release_lesson_prey() -> void:
	_lesson_prey.clear()
	_lesson_asks = 0
	var eco := get_tree().get_first_node_in_group(&"ecosystem") if is_inside_tree() else null
	if eco != null and eco.has_method(&"stop_lesson_prey"):
		eco.call(&"stop_lesson_prey")


## The catch lesson's moths still in play (empty when there is no lesson).
func lesson_prey() -> Array[Bird]:
	var out: Array[Bird] = []
	for b in _lesson_prey:
		if is_instance_valid(b) and b.alive:
			out.append(b)
	return out


## Seconds left of the attack respite (NPCs do not hunt the player).
func respite_left() -> float:
	return maxf(_respite_until - _clock, 0.0)


func _clear_watch() -> void:
	if _emitted_level > 0.0 or _emitted_pred != null:
		_emitted_level = 0.0
		_emitted_pred = null
		Events.threat_changed.emit(0.0, null)
	if watch.target != null:
		watch.target = null
		Events.target_changed.emit(null)
	if not watch.highlights.is_empty():
		watch.clear_highlights(Birds.all())
	watch.reset()
	_pass_pred = null


# =====================================================================
# Queries
# =====================================================================

## How much more a meal grows the player in this sky than in the sky the
## growth was tuned for (SKY_GROWTH_EXP): 1 at the full budget, or with no
## Ecosystem.
func sky_growth(m: float = -1.0) -> float:
	var n := sky_budget()
	if n <= 0 or n >= SKY_REF_NPCS:
		return 1.0
	if m < 0.0:
		var p := Birds.player()
		m = p.mass if p else START_MASS
	var apex_mass := float(SizeRules.SPECIES[apex_tier()]["mass"])
	var ramp := clampf(log(m / START_MASS) / log(apex_mass / START_MASS), 0.0, 1.0)
	ramp = lerpf(sky_growth_floor, 1.0, ramp)
	return minf(pow(float(SKY_REF_NPCS) / float(n), sky_growth_exp * ramp), SKY_GROWTH_MAX)


## The sky's NPC budget: the AI's Ecosystem (group "ecosystem") exposes it as
## `max_npcs`; 0 without one (dev scenes, tests, the AI mirror).
func sky_budget() -> int:
	var eco := get_tree().get_first_node_in_group(&"ecosystem") if is_inside_tree() else null
	if eco == null:
		return 0
	var v: Variant = eco.get(&"max_npcs")
	return int(v) if v is int or v is float else 0


## Fraction of mass the player loses when caught now (the danger assist
## cuts it).
func death_penalty() -> float:
	return CAUGHT_MASS_LOSS * (1.0 - DANGER_ASSIST_PENALTY_CUT * danger_assist)


## Seconds of protection after a respawn (longer for a struggling player).
func respawn_protection() -> float:
	return RESPAWN_PROTECT_S + DANGER_ASSIST_PROTECT_S * danger_assist


## 0..1: how much catch assist the player currently gets.
func catch_assist() -> float:
	var p := Birds.player()
	return assist_for(since_catch, p.mass if p else START_MASS)


## The catch assist after `since` seconds of play without a catch at mass m
## (the ramp is in body time: an eagle waits ~4x longer in seconds).
static func assist_for(since: float, m: float) -> float:
	return clampf((since / sqrt(SizeRules.time_scale(m)) - ASSIST_START_S) / (ASSIST_FULL_S - ASSIST_START_S), 0.0, 1.0)


## Call after moving a bird discontinuously (placing, pooling, a scripted
## jump): the jump is not swept for contacts on the next frame. Respawns the
## loop does itself are handled already, and jumps faster than
## MAX_BIRD_SPEED are always treated as teleports.
func teleported(b: Bird) -> void:
	var t: _Track = _tracks.get(b.get_instance_id())
	if t:
		t.has_prev = false


## Seconds of catch protection left for a bird (0 = catchable).
func protection_left(b: Bird) -> float:
	var t: _Track = _tracks.get(b.get_instance_id())
	return maxf(t.protect_until - _clock, 0.0) if t else 0.0


func set_protection(b: Bird, seconds: float) -> void:
	_track(b).protect_until = _clock + seconds if seconds > 0.0 else -1.0


## Everything the HUD / menus need, as a plain Dictionary.
func get_run_stats() -> Dictionary:
	var p := Birds.player()
	var m := p.mass if p else START_MASS
	var tier := SizeRules.tier_for_mass(m)
	var sp: Dictionary = SizeRules.SPECIES[tier]
	var next_mass := -1.0
	var progress := 1.0
	if tier < SizeRules.SPECIES.size() - 1:
		next_mass = SizeRules.SPECIES[tier + 1]["mass"]
		progress = clampf(log(m / float(sp["mass"])) / log(next_mass / float(sp["mass"])), 0.0, 1.0)
	var worthwhile: Array[StringName] = []
	var edible: Array[StringName] = []
	for s in SizeRules.SPECIES:
		if SizeRules.can_eat(m, s["mass"]):
			edible.append(s["id"])
			if SizeRules.is_worthwhile(m, s["mass"]):
				worthwhile.append(s["id"])
	return {
		"phase": Phase.keys()[phase],
		"state": Game.state,
		"run_time": stats.run_time,
		"lives": lives,
		"max_lives": MAX_LIVES,
		"mass": m,
		"tier": tier,
		"species": sp["id"],
		"species_name": sp["name"],
		"next_tier_mass": next_mass,
		"tier_progress": progress,
		"peak_mass": stats.peak_mass,
		"peak_tier": stats.peak_tier,
		"catches": stats.catches,
		"worthwhile_catches": stats.worthwhile_catches,
		"catches_by_species": stats.catches_by_species.duplicate(),
		"mass_gained": stats.mass_gained,
		"times_caught": stats.times_caught,
		"streak": stats.streak,
		"best_streak": stats.best_streak,
		"escapes": stats.escapes,
		"score": stats.score(),
		"best_score": records.best_score if records else 0,
		"best_tier": records.best_tier if records else -1,
		"protection_s": protection_left(p) if p else 0.0,
		"respawn_in": maxf(_beat_left, 0.0) if phase == Phase.CAUGHT else 0.0,
		"threat_level": watch.level,
		"threat_ttc": watch.predator_ttc,
		"threat": watch.predator,
		"target": watch.target,
		"edible_species": edible,
		"worthwhile_species": worthwhile,
		"danger_species": danger_species(m),
		"edible_below_mass": m / SizeRules.EAT_RATIO,
		"danger_above_mass": m * SizeRules.EAT_RATIO,
		"apex": _apex_dict(),
		"npc_catches": stats.npc_catches,
		"endless": endless,
		"catch_assist": rule.player_assist,
		"danger_assist": danger_assist,
		# How much more a meal grows the player in this sky, at this size
		# (sky_growth()).
		"sky_growth": sky_growth(m),
		# The danger director: attacks on the player so far, how many the
		# director called, and seconds until the next may come.
		"attacks": stats.attacks,
		"attacks_sent": stats.attacks_sent,
		"respite_left": respite_left(),
		# Aliases the UI area reads (docs/ARCHITECTURE.md contract note).
		"time": stats.run_time,
		"max_mass": stats.peak_mass,
		"max_tier": stats.peak_tier,
		"lives_max": MAX_LIVES,
	}


## Species that can eat a player of mass m: every species whose ladder mass
## can, plus the species of every live bird in the sky that can (the AI
## spawns hunters heavier than their species to keep a threat above a big
## player: at the top of the ladder the eagle is hunted by bigger eagles).
## For the UI's "what hunts you" (get_run_stats().danger_species), which must
## never say "nothing" while something up there can eat the player. (As of
## fix round 5 the UI's pause screen and tier-up card still list the ladder
## only - reported to UI in the contract notes.)
func danger_species(m: float) -> Array[StringName]:
	var out: Array[StringName] = []
	for s in SizeRules.SPECIES:
		if SizeRules.can_eat(s["mass"], m):
			out.append(s["id"])
	for b in Birds.all():
		if b.alive and not b.is_player() and SizeRules.can_eat(b.mass, m) and not out.has(b.species):
			out.append(b.species)
	# Ladder order, whatever order the birds came in.
	out.sort_custom(func(a: StringName, c: StringName) -> bool:
		return SizeRules.species_index(a) < SizeRules.species_index(c))
	return out


func _apex_dict() -> Dictionary:
	return {
		"tier": apex_tier(),
		"species": SizeRules.SPECIES[apex_tier()]["id"],
		"reached": stats.apex_reached_at >= 0.0,
		"reached_at": stats.apex_reached_at,
		"reign_time": stats.reign_time,
		"catches": stats.apex_catches,
		"needed": APEX_CATCHES,
		"victory": stats.victory,
	}


func _build_summary(reason: StringName) -> Dictionary:
	var p := Birds.player()
	var m := p.mass if p else START_MASS
	var final_tier := SizeRules.tier_for_mass(m)
	return {
		"reason": reason,
		"victory": stats.victory,
		"duration_s": stats.run_time,
		"score": stats.score(),
		"lives_left": lives,
		"catches": stats.catches,
		"worthwhile_catches": stats.worthwhile_catches,
		"catches_by_species": stats.catches_by_species.duplicate(),
		"biggest_prey": stats.biggest_prey,
		"biggest_prey_mass": stats.biggest_prey_mass,
		"mass_gained": stats.mass_gained,
		"start_mass": stats.start_mass,
		"final_mass": m,
		"final_tier": final_tier,
		"final_species": SizeRules.SPECIES[final_tier]["id"],
		"peak_mass": stats.peak_mass,
		"peak_tier": stats.peak_tier,
		"peak_species": SizeRules.SPECIES[stats.peak_tier]["id"],
		"times_caught": stats.times_caught,
		"caught_by": stats.caught_by.duplicate(),
		"best_streak": stats.best_streak,
		"escapes": stats.escapes,
		"tier_timeline": stats.tier_timeline(),
		"time_in_tier": Array(stats.time_in_tier),
		"npc_catches": stats.npc_catches,
		"apex": _apex_dict(),
		# Aliases the UI area reads (docs/ARCHITECTURE.md contract note).
		"time": stats.run_time,
		"max_mass": stats.peak_mass,
		"max_tier": stats.peak_tier,
		"lives": lives,
		"lives_max": MAX_LIVES,
	}


# =====================================================================
# Bookkeeping
# =====================================================================

func _on_bird_spawned(b: Bird) -> void:
	if not b.is_player() and npc_spawn_grace_s > 0.0:
		set_protection(b, npc_spawn_grace_s)


func _on_bird_removed(b: Bird) -> void:
	_tracks.erase(b.get_instance_id())
	if b == watch.target:
		watch.target = null
		watch.last_target_change = &"gone"
		Events.target_changed.emit(null)
	if b == _emitted_pred:
		_emitted_pred = null
	watch.forget(b)


func _find_world() -> World:
	if _world != null and is_instance_valid(_world):
		return _world
	if not is_inside_tree():
		return null
	_world = World.find(get_tree())
	if _world:
		_refuges = _world.get_refuges()
		if not _world.generated.is_connected(_on_world_generated):
			_world.generated.connect(_on_world_generated)
	return _world


func _on_world_generated() -> void:
	if _world:
		_refuges = _world.get_refuges()
