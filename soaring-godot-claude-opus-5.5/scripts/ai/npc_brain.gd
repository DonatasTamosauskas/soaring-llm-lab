class_name NpcBrain
extends RefCounted
## Decisions and steering for one NpcBird: a small utility AI.
##
## Two loops at different rates (level of detail from the ecosystem):
##  * think (0.1-0.6 s): sense threats and prey, keep or change the state.
##    Fleeing pre-empts everything once a predator has been noticed for the
##    species' reaction time. Otherwise committed states (hunt, perch
##    approach, soaring) run until their own exit rules fire, and free states
##    are chosen by utility: hunt = drive x hunger x best prey score,
##    perch = affinity x tiredness, soar = affinity x known lift nearby,
##    flock/wander as the baseline. The current state gets a small bonus
##    (hysteresis) so birds do not dither.
##  * steer (every tick when engaged, else 24/12/6.7 Hz): turn the state into
##    a wanted direction, speed, effort cap and wing tuck for NpcFlight, then
##    layer the safety overlays on top: obstacle feelers (rays on layer 1),
##    ground clearance that accounts for the pull-out radius at the current
##    speed, and the arena bounds/ceiling.
##
## "Can eat" is always Bird.can_eat (the size ladder): prey ignore birds
## that cannot eat them, hunters ignore birds they cannot eat or that are not
## worth it (SizeRules.is_worthwhile), and the player is just another bird.

## Flapping effort of a flock in the Ecosystem's show (see _steer_flock).
const SHOW_FLOCK_EFFORT := 0.7
const G := 9.81
const THINK_S: Array[float] = [0.25, 0.4, 0.6]
const ENGAGED_THINK_S := 0.1
const STEER_S: Array[float] = [1.0 / 18.0, 1.0 / 12.0, 0.15]
const FEEL_S: Array[float] = [0.1, 0.16, 0.3]
const ENGAGED_FEEL_S := 0.08
## Steering interval of an engaged bird whose counterpart is still far
## (see update); within CLOSE_FIGHT_M it steers every tick.
const ENGAGED_FAR_STEER_S := 1.0 / 36.0
const CLOSE_FIGHT_M := 25.0
## Bonus for the player as prey: "maybe a little more interesting".
const PLAYER_INTEREST := 1.25
## Scales hunt utility against the free states (wander 0.22, flock 0.4, plus
## 0.12 for staying put): a hungry hunter with worthwhile prey in range and a
## few seconds from it goes for it; a sated one, or one with far prey, not.
const HUNT_GAIN := 2.0
## A chase lasts CHASE_CLOSE_K x the time to close the gap at the speed
## advantage, plus CHASE_PASS_S for the strike passes, at most CHASE_MAX_S -
## which grows with the meal: from CHASE_MAX_S.x for a snack to CHASE_MAX_S.y
## for prey of CHASE_FEAST_RATIO of the hunter's mass or more (worth vs
## effort: a hawk runs a gull, two thirds of its own weight, into the
## ground; it does not spend a minute on a sparrow).
const CHASE_CLOSE_K := 1.3
const CHASE_PASS_S := 6.0
const CHASE_MAX_S := Vector2(30.0, 52.0)
const CHASE_FEAST_RATIO := 0.6
## Prey energy below which its sprint starts to fail (NpcBird.effort_cap).
const PREY_FLAGGING := 0.45
## Sprint advantage (m/s) under which a chase is a race of stamina.
const RACE_GAP := 2.0
const RACE_EXTRA := 1.3
const RACE_MEAL := 0.45
## A managed bird gives up a chase that has carried it this many home
## radii (at least HOME_LEASH_M) from its home.
const HOME_LEASH := 3.0
const HOME_LEASH_M := 220.0
## The prey judges an attack by where the hunter will be this many seconds
## ahead (see _steer_flee).
const FLEE_LEAD_S := 0.3
## A bird fleeing the PLAYER (integration round 1; the experience
## verifier's finding that no pilot flying the real player bird ever caught
## a fleeing bird: 0 of 83 chases). A person flying the player bird cannot
## fly like a bird: its turns are arm gestures read through WingInput with
## ~0.35 s of reaction and roll-in, and a rig whose yaw is comfort-capped -
## a sparrow-sized player turns at up to ~160 deg/s where an NPC sparrow
## turns at 220 and a wren at 280. Measured one-on-one through the real
## chain (tests/shots/integration_chase_lab_test.gd: a competent pilot that
## hits 10 of 12 hovering targets) a fleeing wren escaped every chase:
## re-aimed every ~0.25 s away from where the player was heading, it weaved
## with every correction the player made and the player's lagging turns
## never closed the last 3-4 m. So against the player a fleeing bird
##  * holds each escape line FLEE_PLAYER_REAIM times longer than its
##    reaction time (it breaks only with its jinks), and
##  * turns no tighter than FLEE_PLAYER_TURN of its own turn rate.
## It still sees the player, flees at full speed, jinks at the strike and
## dives for cover. Other hunters are unaffected.
const FLEE_PLAYER_TURN := 0.55
const FLEE_PLAYER_REAIM := 10.0
## ...and (core loop round, the lead's direction: "prey fleeing from the
## player: short reaction delay, limited burst stamina, unaware when
## perched/feeding until close - so a committed chase usually succeeds
## against smaller-tier prey and sometimes fails against near-equals"):
##  * a bird sitting on a perch (or landing on one) notices the player only
##    within PLAYER_AWARE_PERCHED of its awareness, one about its business
##    in the open (wandering, flocking, soaring: feeding and travelling)
##    within PLAYER_AWARE_CALM of it - the player can come close first;
##  * it takes FLEE_PLAYER_REACT_S longer than its reaction time to bolt;
##  * its sprint away from the player lasts FLEE_PLAYER_BURST_S (x the
##    square root of its body time, x up to 1 + FLEE_PLAYER_NEAR_EQUAL for a
##    bird near the player's own size: a near-equal has the legs for a
##    longer race); then it flags - it flies on at FLEE_PLAYER_FLAG_SPEED of
##    its cruise, at FLEE_PLAYER_FLAG_EFFORT - until it has rested as long
##    (the burst comes back at FLEE_PLAYER_RECOVER x real time once the
##    player is off its tail). Its jinks and dives into cover are its own.
## Before, a wren fled the player at full power for as long as it liked and
## a person through the real chain closed on it only by the catch assist
## (86-96% of the real chain's catches needed it; integration round 2).
const PLAYER_AWARE_PERCHED := 0.45
const PLAYER_AWARE_CALM := 0.7
const FLEE_PLAYER_REACT_S := 0.25
const FLEE_PLAYER_BURST_S := 2.0
const FLEE_PLAYER_NEAR_EQUAL := 1.5
const FLEE_PLAYER_FLAG_SPEED := 0.8
const FLEE_PLAYER_FLAG_EFFORT := 0.55
const FLEE_PLAYER_RECOVER := 0.5
## A bird HUNTING the player (integration round 2, the same asymmetry the
## other way: through the real chain a competent person - the game loop's
## modelled competent player flying the real PlayerBird, evading from the
## threat cue at 0.31 and breaking across each attack run - was caught 3-4
## times a run, always from behind (126-180 deg), after 2-6 s of evading at
## cue levels 0.6-0.9: a hunter steering by proportional navigation every
## tick homes on every correction a person's arms make ~0.35 s late, to the
## very end). So the last HUNT_PLAYER_COMMIT_S of an attack on the player is
## a committed pass, as a raptor's strike is: within that time to contact
## the hunter holds the line it has (re-aiming at most every
## HUNT_PLAYER_REAIM x its reaction time) and turns no tighter than
## HUNT_PLAYER_TURN of its rate - a break at the right moment makes it
## overshoot, the gamble the AI's own prey take and what the game loop's
## modelled player does. Until then it pursues as ever (and comes round
## for another pass after a miss). A first version committed the whole
## pursuit: the same person was then never caught in 14 whole runs, against
## 3-4 deaths a run before - "being eaten happens but is avoidable" needs
## both. The window and the turn were swept through the real chain (the
## person, whole runs at both tiers): the last 0.8 s at 0.6 of the rate
## caught the person in 3 of 16 runs (0.25 deaths a run), 0.3 s at 1.0 in 5
## of 6 with 1 run lost, 0.4 s at 0.8 in 3 of 6 with none lost (INTEGRATION
## §9). NPC-on-NPC hunts are unchanged.
const HUNT_PLAYER_COMMIT_S := 0.4
const HUNT_PLAYER_TURN := 0.8
const HUNT_PLAYER_REAIM := 3.0
## The values in effect (the constants; tuning sweeps set them from user
## args through Ecosystem - nothing else writes them).
static var hunt_player_commit_s := HUNT_PLAYER_COMMIT_S
static var hunt_player_turn := HUNT_PLAYER_TURN
static var hunt_player_reaim := HUNT_PLAYER_REAIM
## "Coming at me": the other bird's velocity points within ~37 deg of me.
const AT_ME_COS := 0.8
## Below this height (m) among obstacles a fleeing bird climbs out.
const CLUTTER_AGL := 14.0
## Seconds an obstacle is remembered after a feeler last saw it.
const OBS_MEMORY_S := 2.5
## A travel goal the bird has been kept from by an obstacle this long is
## given up for another (a spot behind a cliff, inside a house).
const GOAL_BLOCKED_S := 5.0
## Seconds (x sqrt of the hunter's SizeRules.time_scale) before the next
## hunt after a chase that failed.
const HUNT_REST_S := Vector2(6.0, 14.0)
## Hiding: a breather of HIDE_MIN_S, out after HIDE_QUIET_S without danger,
## and never in cover longer than HIDE_MAX_S (ranges, per stay).
const HIDE_MIN_S := Vector2(2.0, 4.0)
const HIDE_MAX_S := Vector2(12.0, 20.0)
const HIDE_QUIET_S := 1.0
## Seconds a quarry may be out of sight before the hunter has lost it.
const LOST_S := 1.5
## Seconds a hunter leaves the player alone after a chase on it failed.
const PLAYER_COOLDOWN_S := 40.0
## At most this many NPCs chase the player at once (kept as meta
## "npc_chasers" on the player). A person cannot dodge two raptors from
## opposite sides; the danger comes in waves, not as a siege.
const MAX_PLAYER_CHASERS := 1

## Per-tick snapshot of every registered bird and its position, taken by
## the Ecosystem before it ticks its birds (snapshot_begin/end): the
## sensing loops of 60 brains read positions from it instead of asking
## each bird (get_body_position is a script call; a brain's think visits
## every bird). Only for managed birds and only inside the Ecosystem's
## tick - loose birds (tests, dev scenes) read the birds directly.
static var snap_on := false
static var snap_birds: Array[Bird] = []
static var snap_pos := PackedVector3Array()


static func snapshot_begin() -> void:
	snap_birds = Birds.all().duplicate()
	snap_pos.resize(snap_birds.size())
	for i in snap_birds.size():
		snap_pos[i] = snap_birds[i].get_body_position()
	snap_on = true


static func snapshot_end() -> void:
	snap_on = false


## Profiling (perf probes only): with prof_on, microseconds spent in
## [think, feel, steer] across all brains, and NpcBird adds [fly].
static var prof_on := false
static var prof_us := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

const WANDER := NpcBird.State.WANDER
const FLOCK := NpcBird.State.FLOCK
const SOAR := NpcBird.State.SOAR
const PERCH := NpcBird.State.PERCH
const PERCHED := NpcBird.State.PERCHED
const HUNT := NpcBird.State.HUNT
const STOOP := NpcBird.State.STOOP
const FLEE := NpcBird.State.FLEE
const HIDE := NpcBird.State.HIDE

var b: NpcBird
var prof: Dictionary
var f: NpcFlight
var habitat: Habitat

var _age := 0.0
var _p := Vector3.ZERO
var _think_acc := 0.0
var _steer_acc := 0.0
var _feel_acc := 0.0
var _force_think_at := -1.0

# Senses
var _cand: Bird = null
## A predator close by but not hunting: kept at a distance, not fled.
var _nuisance: Bird = null
## A smaller bird this one is about to fly into without meaning to (not its
## prey target): steered round, since any contact would be a catch.
var _bump: Bird = null
var _cand_t := 0.0
var _cand_alarm := false
var _calm := 0.0
## A predator pressed this bird at the last think (see _sense).
var _danger_now := false
# Hiding (see _think_hidden): shortest and longest stay, quiet time so far.
var _hide_min := 3.0
var _hide_max := 15.0
var _hide_quiet := 0.0
## Seconds from a threat first entering awareness to fleeing (tests read it).
var last_reaction_s := -1.0
## True if the current flight was started by a flock-mate's alarm.
var fled_on_alarm := false

# Hunting
var _pending_prey: Bird = null
var _hunt_t := 0.0
var _prev_d := -1.0
var _closing := 0.0
var _slow_t := 0.0
var _passes := 0
var _in_pass := false
## Size of the striking zone the current pass entered (it shrinks as the
## hunter slows after a miss; the pass ends 3x beyond where it began).
var _pass_zone := 0.0
## Hunt time when the prey noticed us and started fleeing (-1 = not yet).
var _chase_t0 := -1.0
## Seconds this chase may last from then (set when the prey notices).
var _chase_budget := 10.0
## Seconds allowed to reach an unaware prey (from the intercept estimate).
var _approach_budget := 10.0
var _cooldown := {}
## No new hunt before this (brain age, s): see _give_up_hunt.
var _hunt_rest_until := 0.0
var _stoop_best := INF
## Seconds the quarry has been out of sight (see _hunt_ok).
var _unseen_t := 0.0
## Why the last hunt ended without a catch (tests/diagnostics).
var give_up_reason := ""

# Fleeing
var _jink_t := 0.0
var _jink_cool := 0.0
var _jink_dir := Vector3.ZERO
## t_reach (see _steer_flee) at which this attack run's jink fires (-1 = no run).
var _jink_at := -1.0
## Whether the prey will jink at all on this attack run.
var _run_jink := false
var _flee_dir := Vector3.ZERO
## Direction the bird dived into its refuge; it leaves the way it came.
var _refuge_entry := Vector3.ZERO
## The refuge it last hid in (for finding the way out if it gets stuck).
var _last_refuge := {}
## Cover this bird found it cannot fly into in straight legs (the way from
## the opening to the hiding spot runs through a wall or a frame): not
## chosen again.
var _bad_refuges: Array[Vector3] = []
## True while flying out of cover or a room through its opening.
var _exiting := false
## Cached Habitat.indoors() and when to look again (see _indoors_now).
var _indoor := false
var _indoor_t := 0.0
## When the refuge choice was last made (see _update_refuge_choice).
var _refuge_pick_t := -99.0
var _refuge_pick_threat: Bird = null
## Set while perched, hidden or flaring; the first free tick after feels at once.
var _settled := false
var _flee_next := 0.0
## Seconds of sprint spent fleeing the player (see FLEE_PLAYER_BURST_S).
var flee_burst_used := 0.0
## Distance to the bird we chase or flee, as of the last think.
var _engage_d := 0.0

# Soaring
var _thermal: Dictionary = {}
var _soar_c := Vector3.ZERO
var _soar_r := 20.0
var _soar_turn := 1
var _w_avg := 0.0
var _circling := false
var _climb_h := 0.0
var _climb_t := 0.0
var _climb_h5 := 0.0
var _climb_n := 0
var _soar_cool := 0.0
var _search_cool := 0.0

# Wandering
var _goal := Vector3.ZERO
var _goal_t := 999.0
var _flock_off := Vector3.INF
var _goal_life := 30.0
## The goal is not tied to the home range (searching for prey, escaping a
## trap): keep it even when the home has moved on.
var _goal_free := false
var _jitter := Vector3.ZERO

# Perching
var _perch_phase := 0
var _perch_fail := 0
var _phase_t := 0.0
var _approach := Vector3.ZERO
## Direction of the final run onto the claimed perch (see _pick_approach).
var _approach_dir := Vector3.FORWARD
## How far out along it the approach waypoint was checked clear (m).
var _approach_L := 0.0
var _rest_s := 10.0
var _perch_cool := 0.0

# Obstacles
## The surface the feelers found (at most one entry: the nearest wins, see
## _remember): a point on it and its normal (a local plane the bird keeps
## out of), the look-ahead it was seen with, seconds since last seen. Kept
## while it is ahead of the bird - not dropped the moment a feeler misses
## it (flying along a wall the forward ray sees nothing, and a bird that
## forgot the wall at once turned back into it: a zigzag of near-misses and
## grazes along every cliff). Several remembered planes at once were tried
## in round 3 and taken out again: a plane has no edges, and the planes of
## two houses' walls boxed birds in between them in open air, or turned a
## gull beyond a cliff's end back into the cliff. What a single plane
## misses - the far wall of a street - the path-confirmed brake
## (_brake_for_ahead) and the body's look-ahead (on_imminent) now catch.
## What the centre feeler last saw down the flight path: its distance, the
## surface normal, and when (brain age).
var _ahead_d := INF
var _ahead_n := Vector3.UP
var _ahead_t := -99.0
var _ob_p: Array[Vector3] = []
var _ob_n: Array[Vector3] = []
var _ob_look: Array[float] = []
var _ob_age: Array[float] = []
## Seconds the obstacle memory has been in use without a break.
var _obs_busy := 0.0
var _near_t := 0.0
var _feel_i := 0
var _learn_i := -1

var _steer_dt := 0.0
## Outward axis of the opening the bird is lining up on this steer (ZERO
## if none): the wall the opening is in is not an obstacle to steer off.
var _door_out := Vector3.ZERO

# Steering outputs (scratch)
var _o_dir := Vector3.FORWARD
var _o_speed := 9.0
var _o_eff := 1.0
var _o_fold := 0.0
var _o_brake := 0.0
var _o_turn := 1.0
## The line an attack on the player holds (see HUNT_PLAYER_REAIM).
var _attack_dir := Vector3.ZERO
var _attack_next := 0.0
var _attack_of: Bird = null
var _clear := 2.0
var _guard := true


func _init(bird: NpcBird) -> void:
	b = bird
	prof = bird.profile
	f = bird.flight
	habitat = bird.habitat
	_feel_i = bird.rng.randi() % 4
	_think_acc = bird.rng.randf() * THINK_S[0]
	_goal_life = bird.rng.randf_range(20.0, 40.0)


func update(dt: float) -> void:
	if habitat == null:
		habitat = b.habitat
	_age += dt
	_think_acc += dt
	_steer_acc += dt
	_feel_acc += dt
	for i in _ob_age.size():
		_ob_age[i] += dt
	_near_t -= dt
	_jink_t -= dt
	_jink_cool -= dt
	_goal_t += dt
	_soar_cool -= dt
	_perch_cool -= dt
	_search_cool -= dt
	if flee_burst_used > 0.0 and not (b.state == FLEE and _valid(b.threat) and b.threat.is_player()):
		flee_burst_used = maxf(flee_burst_used - dt * FLEE_PLAYER_RECOVER, 0.0)
	_p = b.global_position
	# Birds removed this frame (caught, despawned) may still be referenced.
	if b.target != null and not _valid(b.target):
		_drop_target()
	if b.threat != null and not _valid(b.threat):
		b.threat = null
	var eng := b.is_engaged()
	var lod := 0 if eng else clampi(b.lod, 0, 2)
	# Engaged birds steer every tick in the close fight (the strike, the
	# break), at 36 Hz while the other bird is still far off.
	var think_iv := ENGAGED_THINK_S if eng else THINK_S[lod]
	if _think_acc >= think_iv or (_force_think_at >= 0.0 and _age >= _force_think_at - 1e-5):
		_force_think_at = -1.0
		if prof_on:
			var t0 := Time.get_ticks_usec()
			_think(_think_acc)
			prof_us[0] += Time.get_ticks_usec() - t0
		else:
			_think(_think_acc)
		_think_acc = 0.0
	if not b.alive or b.perched or b.hidden:
		b.near_geometry = false
		_settled = true
		return
	# A flare flies itself (and may be a chain of legs): steering now would
	# restart it every tick. Thinking above still runs and can cancel it.
	if b.is_flaring():
		_settled = true
		return
	_exiting = false
	var feel_iv := ENGAGED_FEEL_S if eng else FEEL_S[lod]
	if _settled:
		# First free tick after a perch, cover or a flare: the bird is right
		# next to what it sat on or flew to (a nest box's mouth, a branch),
		# and what the feelers knew is stale - feel now, and keep the body's
		# sweep on meanwhile. (A wren out of a nest box flew on for a moment
		# unswept and grazed the box.)
		_settled = false
		_near_t = maxf(_near_t, 0.5)
		_feel_acc = feel_iv
	if _feel_acc >= feel_iv:
		if prof_on:
			var t1 := Time.get_ticks_usec()
			_feel(feel_iv)
			prof_us[1] += Time.get_ticks_usec() - t1
		else:
			_feel(feel_iv)
		_feel_acc = 0.0
	b.near_geometry = _near_t > 0.0
	var steer_iv: float = STEER_S[lod]
	if eng:
		steer_iv = 0.0 if (_engage_d < CLOSE_FIGHT_M or _jink_t > 0.0) else ENGAGED_FAR_STEER_S
	if _steer_acc >= steer_iv - 1e-5:
		if prof_on:
			var t2 := Time.get_ticks_usec()
			_steer(_steer_acc)
			prof_us[2] += Time.get_ticks_usec() - t2
		else:
			_steer(_steer_acc)
		_steer_acc = 0.0


# ---------------------------------------------------------------- thinking

static func _valid(o: Variant) -> bool:
	return is_instance_valid(o) and o.alive and o.is_inside_tree()


func _think(dt: float) -> void:
	_tick_cooldowns(dt)
	_sense(dt)
	if not b.alive:
		return
	var st := b.state
	var other: Bird = b.target if b.target != null else b.threat
	_engage_d = other.get_body_position().distance_to(_p) if _valid(other) else INF
	if st == HIDE:
		_think_hidden(dt)
		return
	# Fleeing pre-empts everything once the predator has been noticed.
	if b.threat != null:
		if st != FLEE:
			_enter(FLEE)
		else:
			_update_refuge_choice()
		return
	match st:
		FLEE:
			# Once diving into cover, finish it (hide) even if the danger passed.
			if _calm >= 1.5 and not b.is_flaring():
				_enter(_default_state())
			return
		HUNT, STOOP:
			_hunt_t += dt
			if not _hunt_ok(dt):
				_give_up_hunt()
				return
			_maybe_stoop()
			return
		PERCH:
			if b.perch_spot == null or (b.perch_spot.occupant != b and not b.perch_spot.is_free()):
				_perch_cool = 5.0
				_enter(_default_state())
			elif b.state_time > 30.0:
				_perch_cool = 15.0
				_enter(_default_state())
			return
		PERCHED:
			_think_perched()
			return
		SOAR:
			if _think_soar(dt):
				return
	_choose()


func _default_state() -> int:
	if b.flock != null and b.flock.mood == FlockGroup.Mood.FLY:
		return FLOCK
	return WANDER


func _tick_cooldowns(dt: float) -> void:
	if _cooldown.is_empty():
		return
	for k in _cooldown.keys():
		_cooldown[k] -= dt
		if _cooldown[k] <= 0.0:
			_cooldown.erase(k)


## Look for predators. A bird only reacts to birds that can eat it, within
## its awareness radius (shorter for an attack from above and behind - that
## is what makes a stoop work), after its reaction time.
func _sense(dt: float) -> void:
	if b.threat != null and (not _valid(b.threat) or not b.threat.can_eat(b)):
		b.threat = null
	var flee_ok := b.can_flee
	if not flee_ok:
		b.threat = null
	var aw: float = prof["awareness_m"]
	# Once alarmed a bird keeps its eyes on the danger: vigilance doubles the
	# range at which it keeps tracking a predator (a hunter looping round for
	# another pass is not forgotten the moment it is 10 m further away). Not
	# from cover: a hidden bird comes out when the danger near it has gone
	# (see _think_hidden), not when every raptor in twice its sight has.
	if b.state == FLEE:
		aw *= 2.0
	var fwd := b.velocity
	fwd = fwd / sqrt(fwd.length_squared()) if fwd.length_squared() > 0.01 else b.get_forward()
	var best: Bird = null
	var best_lv := 0.0
	var aw2 := aw * aw
	var nuis_d := INF
	_nuisance = null
	# Only birds heavy enough to eat us matter (Bird.can_eat, inlined: this
	# loop runs for every bird at every think).
	var eater_mass := b.mass * SizeRules.EAT_RATIO
	# Birds we could eat and must not fly into by accident (any contact is a
	# catch by the game's rule): not while hunting, not the target.
	var edible_mass := b.mass / SizeRules.EAT_RATIO
	var look_bumps := not (b.state == HUNT or b.state == STOOP or b.perched or b.hidden)
	var bump_t := INF
	var bump_pad := b.get_body_radius() + b.get_wingspan() * 0.25 + 0.5
	_bump = null
	var snap := snap_on and b.managed
	var all: Array[Bird] = snap_birds if snap else Birds.all()
	# Nothing beyond both the awareness radius and the 30-m bump horizon
	# matters here: with the snapshot that is one subtraction per bird.
	var reach2 := maxf(aw2, 900.0)
	for idx in all.size():
		if snap and (snap_pos[idx] - _p).length_squared() > reach2:
			continue
		var o := all[idx]
		if o == b or not o.alive:
			continue
		var om := o.mass
		if om < eater_mass:
			if look_bumps and om <= edible_mass and o != b.target:
				# Time and distance of closest approach over the next ~1.2 s.
				var rb := (snap_pos[idx] if snap else o.get_body_position()) - _p
				if rb.length_squared() < 900.0:
					var dvb := o.velocity - b.velocity
					var dv2 := dvb.length_squared()
					var tca := clampf(-rb.dot(dvb) / dv2, 0.0, 1.2) if dv2 > 1e-4 else 0.0
					if tca < bump_t and (rb + dvb * tca).length() < bump_pad + o.get_body_radius():
						bump_t = tca
						_bump = o
			continue
		if not flee_ok:
			continue
		var rel := (snap_pos[idx] if snap else o.get_body_position()) - _p
		var d2 := rel.length_squared()
		if d2 > aw2:
			continue
		var d := sqrt(d2)
		var eff := aw
		if not (b.perched or b.hidden):
			# Birds see ~300 degrees: an attacker from behind is seen late, one
			# stooping from above and behind later still.
			var behind := fwd.dot(rel) < -0.5 * d
			if behind and rel.y > d * 0.4:
				eff *= 0.55
			elif behind:
				eff *= 0.65
			elif rel.y > d * 0.5:
				eff *= 0.75
		if o.is_player() and b.threat != o:
			# Unaware of the player until it is close: on a perch, or about its
			# business in the open (PLAYER_AWARE_*).
			if b.perched or b.state == PERCH:
				eff *= PLAYER_AWARE_PERCHED
			elif b.state == WANDER or b.state == FLOCK or b.state == SOAR:
				eff *= PLAYER_AWARE_CALM
		if d > eff:
			continue
		# Intent matters as much as size: a predator chasing *me* is fled on
		# sight; one hunting something else only if it is coming this way
		# (flying at me, closing - a stoop into a flock takes whoever is in
		# its path) or passes really close. One that is passing or sitting is
		# watched and given a wide berth (the avoidance nudge in _steer), not
		# fled: otherwise every sparrow on a wire near a raptor hunting
		# pigeons would bolt, and in a valley full of hunters around a big
		# player perching and resting would hardly ever happen.
		var prox := 1.0 - d / eff
		var closing := -(o.velocity - b.velocity).dot(rel) / d if d > 0.01 else 0.0
		var ov2 := o.velocity.length_squared()
		var at_me := closing > 1.0 and ov2 > 0.25 and -o.velocity.dot(rel) > AT_ME_COS * sqrt(ov2) * d
		var lv := prox
		var on := o as NpcBird
		if on != null:
			if on.target == b:
				lv = 1.0 + prox
			elif on.state == HUNT or on.state == STOOP:
				var coming := at_me
				if coming and (b.perched or b.state == PERCH) and _valid(on.target):
					# Sitting or landing, a bird is in the way of a chase only
					# if it is on the line to the hunter's quarry, short of it
					# (within ~25 deg): a gull chasing a crow across the valley
					# is watched, not fled - round a big player, where every
					# mid-sized bird hunts another, landings were abandoned
					# more often than not.
					var to_q := on.target.get_body_position() - o.get_body_position()
					var ql := to_q.length()
					coming = ql > 0.01 and (-rel).dot(to_q) > 0.9 * d * ql and d < ql + 3.0
				lv = prox + 0.3 if coming else prox - 0.3
			else:
				lv = prox - 0.6
			if on.target != b and lv < 0.3 and prox > 0.5 and d < nuis_d:
				nuis_d = d
				_nuisance = o
		elif o.is_player():
			# Its intent is unknowable: one approaching is taken for a hunter,
			# one close by is watched warily (the player is also the one bird
			# the prey should scatter from - catching them is the game). A
			# bird sitting on a perch or landing on one is flushed only by a
			# player coming at it, not by one sweeping past.
			var coming := at_me if (b.perched or b.state == PERCH) else closing > 1.0
			lv = prox + 0.45 if coming else prox + 0.1
		if lv > best_lv:
			best_lv = lv
			best = o
	if not flee_ok:
		return
	var alarm := false
	# How pressing a danger must be to act on it. A bird in cover or on a
	# perch it has just reached sits tight unless the danger is plain (a
	# hunter after it, one coming its way, the player bearing down); one on
	# its final approach to a perch is committed to landing. Only birds
	# about their business in the open react to the first sign.
	var thr := 0.45
	if b.hidden:
		thr = 0.35
	elif b.perched:
		thr = 0.5
	elif b.state == PERCH:
		thr = 0.55
	if best_lv < thr and b.flock != null:
		# Alarm spreads through the flock faster than each bird could see
		# the predator itself: the wave in a murmuration.
		var ar := maxf(6.0, b.get_wingspan() * 20.0)
		# Only fresh alarms travel: a mate that bolted in the last two seconds
		# from a predator really near it. (Otherwise mates would keep each
		# other alarmed forever about a hawk long gone.)
		for m in b.flock.members:
			if m == b or not is_instance_valid(m) or not m.alive or m.state != FLEE or m.state_time > 2.0:
				continue
			# A mate's threat may have been freed this frame, before the
			# mate's own tick drops it: read it untyped and check it first
			# (assigning a freed instance to a typed variable is a SCRIPT
			# ERROR). Ecosystem._remove also clears such references.
			var mt_v: Variant = m.threat
			if not _valid(mt_v):
				continue
			var mt: Bird = mt_v
			if mt.can_eat(b) \
					and m.global_position.distance_squared_to(_p) < ar * ar \
					and mt.get_body_position().distance_to(m.global_position) < aw * 1.2:
				best = mt
				best_lv = 0.5
				alarm = true
				break
	_danger_now = best != null and best_lv >= thr
	if best != null and best_lv >= thr:
		_calm = 0.0
		if b.threat != null:
			b.threat = best  # already alert: switch to the worst one at once
			return
		var react: float = prof["reaction_s"] * (0.5 if alarm else 1.0) + (FLEE_PLAYER_REACT_S if best.is_player() else 0.0)
		if best != _cand:
			_cand = best
			_cand_t = _age
			_cand_alarm = alarm
			_force_think_at = _age + react
		elif _age - _cand_t >= react - 1e-4:
			b.threat = best
			last_reaction_s = _age - _cand_t
			fled_on_alarm = _cand_alarm
			_cand = null
	else:
		_cand = null
		_calm += dt
		# Nothing dangerous for a while: stand down (FLEE/HIDE then end on
		# their own calm timers).
		if b.threat != null and _calm >= 1.5:
			b.threat = null


func _choose() -> void:
	var st := b.state
	var e := b.energy
	var best_s := _default_state()
	var best_u := 0.4 if best_s == FLOCK else 0.22
	if b.flock != null and b.flock.mood == FlockGroup.Mood.ROOST and _perch_cool <= 0.0:
		best_s = PERCH
		best_u = 0.9
	var u_perch := float(prof["perch"]) * pow(1.0 - e, 1.5) * 1.4
	if b.flock != null:
		u_perch *= 0.3  # flocks roost together (mood), not one by one
	if _perch_cool > 0.0 or prof["perch"] <= 0.0:
		u_perch = 0.0
	var u_soar := 0.0
	if prof["soar"] > 0.0 and _soar_cool <= 0.0:
		var th := _home_thermal()
		if not th.is_empty() and _agl() < _alt_top() - 15.0:
			u_soar = float(prof["soar"]) * 0.6
	var u_hunt := 0.0
	_pending_prey = null
	if _may_hunt() and b.hunger > 0.25 and e > 0.25:
		var pick := _best_prey()
		if not pick.is_empty():
			_pending_prey = pick["bird"]
			u_hunt = float(prof["hunt"]) * smoothstep(0.25, 0.75, b.hunger) * float(pick["score"]) * HUNT_GAIN
			if b.flock != null:
				# A loose flock's hungry members break off for a chase and
				# rejoin after it; a murmuration is not the time for it.
				u_hunt *= 0.4 if b.flock.kind == "murmuration" else 0.8
	# Hungry with nothing in range: go looking. Hunters see prey much further
	# than they would start a chase from; head for the nearest worthwhile one.
	if u_hunt == 0.0 and _may_hunt() and b.hunger > 0.5 and e > 0.35 and _search_cool <= 0.0:
		_search_cool = 6.0
		var far := _nearest_prey(float(prof["hunt_range_m"]) * 3.0)
		if far != null:
			var fp := far.get_body_position()
			_goal = habitat.clamp_inside(fp + Vector3(0.0, float(prof["alt"][0]) * 0.5 + (15.0 if prof["stoop"] else 3.0), 0.0), 40.0)
			_goal_t = 0.0
			_goal_life = 15.0
			_goal_free = true
			if st != WANDER and st != SOAR:
				best_s = WANDER
				best_u = 0.5
	var bonus := 0.12
	var cands := [[PERCH, u_perch], [SOAR, u_soar], [HUNT, u_hunt]]
	if st == best_s:
		best_u += bonus
	for c in cands:
		var u: float = c[1]
		if c[0] == st:
			u += bonus
		if u > best_u:
			best_u = u
			best_s = c[0]
	if best_s != st:
		_enter(best_s)


## State transitions and their bookkeeping.
func _enter(s: int) -> void:
	var old := b.state
	if old == s:
		return
	_p = b.global_position
	# Leaving
	if (old == HUNT or old == STOOP) and s != HUNT and s != STOOP:
		if give_up_reason == "":
			give_up_reason = "left:" + NpcBird.STATE_NAMES[s]
			if s == FLEE:
				# Chased off its own hunt: it will not start another the moment
				# the danger has passed (see _give_up_hunt).
				_hunt_rest_until = _age + b.rng.randf_range(HUNT_REST_S.x, HUNT_REST_S.y) * sqrt(SizeRules.time_scale(b.mass))
		_drop_target()
	if old == PERCH and s != PERCHED:
		_release_claim()
	if old == FLEE and s != HIDE:
		b.refuge = {}
		b.clear_contact_target()
	if old == SOAR:
		_circling = false
	if b.is_flaring() and s != PERCHED and s != HIDE and not _exiting:
		b.cancel_flare()
	var launch := (old == PERCHED or old == HIDE) and s != PERCHED and s != HIDE
	# Entering
	match s:
		HUNT:
			if old != STOOP:
				if _pending_prey == null or not is_instance_valid(_pending_prey):
					s = _default_state()
				else:
					_set_target(_pending_prey)
					_event("hunt")
		STOOP:
			_stoop_best = INF
			_event("stoop")
		PERCH:
			if not _claim_perch():
				_perch_cool = 10.0
				s = _default_state()
		SOAR:
			if not _pick_thermal():
				_soar_cool = 20.0
				s = _default_state()
		WANDER:
			_goal_t = 999.0
		FLEE:
			_jink_cool = 0.0
			_flee_dir = Vector3.ZERO
			_jink_at = -1.0
			_event("flee")
			_raise_alarm()
			_update_refuge_choice()
	if s == old:
		return
	if launch:
		var dir := b.get_forward()
		if old == HIDE and _refuge_entry != Vector3.ZERO:
			# Out of cover the way we came in (the only way known to be open).
			dir = -_refuge_entry
		elif s == FLEE and b.threat != null:
			dir = _p - b.threat.get_body_position()
		elif (s == HUNT or s == STOOP) and b.target != null:
			dir = b.target.get_body_position() - _p
		var ref_left: Dictionary = b.refuge
		b.take_off(dir, old == HIDE)
		_near_t = 2.0
		_p = b.global_position
		if old == HIDE:
			# Out of cover: it is no longer ours (others may use it now), but
			# remember the way out in case we got stuck inside (unstick).
			_last_refuge = ref_left
			b.refuge = {}
			if ref_left.has("entry"):
				_exit_through(ref_left["entry"])
	if s == PERCH:
		_perch_phase = 0
		_perch_fail = 0
		_phase_t = 0.0
	b.set_state(s)
	if (old == HUNT or old == STOOP or old == FLEE) and s != HUNT and s != STOOP and s != FLEE \
			and s != HIDE and s != PERCHED and not _exiting:
		_leave_if_enclosed()


## A chase or a flight that ended indoors (prey that dived into a barn and
## the hunter after it; a room fled into and not hidden in): out by the
## nearest door or window now, rather than steering for a goal beyond the
## walls until the stuck watchdog notices. Only when plainly inside - a
## ceiling close overhead and walls on every side (in a village street
## under the eaves, "the nearest door" leads into a house, not out) - and
## only along a way the body fits through.
func _leave_if_enclosed() -> void:
	if _near_t <= 0.0 or b.is_flaring() or not habitat.indoors(_p):
		return
	var ex := habitat.exit_near(_p, 20.0)
	if ex.is_empty():
		return
	var door: Vector3 = ex["through"]
	var first: Vector3 = ex.get("inner", door)
	if _leg_clear(_p, first) and _leg_clear(first, door):
		_exit_through(ex)


## Habitat.indoors(), re-checked at most every half second (seven rays).
func _indoors_now() -> bool:
	if _age >= _indoor_t:
		_indoor_t = _age + 0.5
		_indoor = habitat.indoors(_p)
	return _indoor


## A bird bolting is seen by its neighbours at once (they need not wait
## for their next routine look round): nearby flock-mates think next tick.
func _raise_alarm() -> void:
	if b.flock == null:
		return
	var ar := maxf(6.0, b.get_wingspan() * 20.0)
	for m in b.flock.members:
		if m != b and is_instance_valid(m) and m.alive and m.global_position.distance_squared_to(_p) < ar * ar:
			m.brain.hear_alarm()


func hear_alarm() -> void:
	if _force_think_at < 0.0 or _force_think_at > _age + 0.02:
		_force_think_at = _age + 0.02


## True while the bird we chase or flee is still well away (as of the last
## think) and no evasive break is under way: the body may integrate at its
## level-of-detail rate.
func fight_far() -> bool:
	return _engage_d > CLOSE_FIGHT_M * 1.5 and _jink_t <= 0.0 and not b.is_flaring()


## Behaviour milestones for stats and tests ("hunt", "stoop", "flee",
## "jink", "refuge", "perch", "thermal", "give_up"...).
func _event(n: StringName) -> void:
	b.behaviour.emit(b, n)


func on_ate(_prey: Bird) -> void:
	_drop_target()
	# A meal settles the grudges against birds that got away (they would have
	# lapsed during the digest anyway) - but not the promise to the player:
	# after a failed chase a hunter leaves it alone for PLAYER_COOLDOWN_S,
	# whatever it ate meanwhile (a swallow digests in 15 s and was back
	# after 33 s).
	for k in _cooldown.keys():
		var o := instance_from_id(k) as Bird
		if o == null or not o.is_player():
			_cooldown.erase(k)
	# Digest: rest a while if the species perches, else wander on.
	if prof["perch"] > 0.3 and b.flock == null and _perch_cool <= 0.0:
		_enter(PERCH)
	if b.state == HUNT or b.state == STOOP:
		_enter(_default_state())


func on_removed() -> void:
	_drop_target()
	_release_claim()


# ---------------------------------------------------------------- hunting

## Starts a hunt on `prey` now, as if hunger had chosen it (the Ecosystem's
## show hunts: a chase set up where the player looks). The chase is then the
## bird's own - pursuit, stoop, passes, give-up rules. False (nothing
## changed) if the bird may not hunt (see _may_hunt), is fleeing, hiding or
## already hunting, or cannot eat the prey.
func begin_hunt(prey: Bird) -> bool:
	if not _may_hunt() or b.threat != null or b.hidden or not _valid(prey) or not b.can_eat(prey) or prey == b:
		return false
	if b.state == HUNT or b.state == STOOP or b.state == FLEE or b.state == HIDE:
		return false
	b.hunger = maxf(b.hunger, 0.8)
	_pending_prey = prey
	_enter(HUNT)
	return b.state == HUNT and b.target == prey


## Whether the bird would start a hunt now (a hunting species, not digesting,
## not resting after a failed chase).
func may_hunt() -> bool:
	return _may_hunt()


## Hunting at all: allowed, a hunting species, not still digesting, and not
## getting its breath back after a chase that failed.
func _may_hunt() -> bool:
	return b.can_hunt and prof["hunt"] > 0.0 and b.digest <= 0.0 and _age >= _hunt_rest_until


## Best prey in range: worth (diminishing, sqrt of mass ratio) over effort
## (rough intercept time), with the confusion effect for flocked prey and a
## bonus for raptors that have height on their prey.
func _best_prey() -> Dictionary:
	var rng_m: float = prof["hunt_range_m"]
	var best: Bird = null
	var best_s := 0.0
	var sprint := f.cruise * 1.2
	# Edible (Bird.can_eat inlined) and worth the chase by the same rule the
	# player's progression uses (SizeRules.is_worthwhile): as birds grow,
	# the smallest drop off their menu too.
	var lo := b.mass * SizeRules.MEAL_DUST_RATIO
	var hi := b.mass / SizeRules.EAT_RATIO
	var snap := snap_on and b.managed
	var all: Array[Bird] = snap_birds if snap else Birds.all()
	var rm2 := rng_m * rng_m * maxf(b.player_range, 1.0) * maxf(b.player_range, 1.0)
	for idx in all.size():
		var o := all[idx]
		var om := o.mass
		if om > hi or om < lo or o == b or not o.alive:
			continue
		# Out of range (at the widest, the player's): nothing more to ask.
		if ((snap_pos[idx] if snap else o.get_body_position()) - _p).length_squared() > rm2:
			continue
		if not SizeRules.is_worthwhile(b.mass, om):
			continue
		if not _cooldown.is_empty() and _cooldown.has(o.get_instance_id()):
			continue
		var ratio := om / b.mass
		var on := o as NpcBird
		if on != null and on.hidden:
			continue
		if o.is_player() and (not _player_open(o) or _murmuring()):
			continue
		var rel := o.get_body_position() - _p
		var d2 := rel.length_squared()
		var rm := rng_m * (b.player_range if o.is_player() else 1.0)
		if d2 > rm * rm:
			continue
		var d := sqrt(d2)
		var closing := sprint - (o.velocity.dot(rel / d) if d > 0.01 else 0.0)
		if closing < 0.5:
			continue
		var t_int := d / closing
		# Worth (diminishing: sqrt of the mass ratio) over effort (time to
		# intercept; ~8 s halves it).
		var s := sqrt(ratio) / (1.0 + t_int / 8.0)
		if on != null and on.state == FLOCK:
			s *= 0.6
		if prof["stoop"] and rel.y < -8.0:
			s *= 1.3
		if o.is_player():
			s *= PLAYER_INTEREST * b.player_interest
		if s > best_s:
			best_s = s
			best = o
	if best == null:
		return {}
	return {"bird": best, "score": best_s}


## Nearest edible, worthwhile, visible bird within r (for searching). The
## player counts as PLAYER_INTEREST^2 times nearer ("a little more
## interesting", as in prey choice).
func _nearest_prey(r: float) -> Bird:
	var lo := b.mass * SizeRules.MEAL_DUST_RATIO
	var hi := b.mass / SizeRules.EAT_RATIO
	var best: Bird = null
	var best_d2 := r * r
	for o in Birds.all():
		var om := o.mass
		if om > hi or om < lo or o == b or not o.alive or not SizeRules.is_worthwhile(b.mass, om):
			continue
		var on := o as NpcBird
		if on != null and on.hidden:
			continue
		if o.is_player() and (not _player_open(o) or _murmuring()):
			continue
		var op := o.get_body_position()
		# Hunt round home (it rides with the player), not off across the
		# valley after whatever is in sight: the bird is part of the player's
		# sky, and a chase from home ranges widely enough.
		if Vector2(op.x - b.home.x, op.z - b.home.z).length() > b.home_radius + r * 0.5:
			continue
		var d2 := op.distance_squared_to(_p)
		if o.is_player():
			var k := PLAYER_INTEREST * PLAYER_INTEREST * b.player_interest
			d2 /= k * k
		if d2 < best_d2:
			best_d2 = d2
			best = o
	return best


## NPCs leave the player alone outside of play (menus, being eaten) and
## while the game loop marks it protected (meta "npc_ignore", e.g. respawn).
func _player_ok(o: Bird) -> bool:
	if bool(o.get_meta(&"npc_ignore", false)):
		return false
	return Game.state == Game.State.PLAYING or Game.state == Game.State.BOOT


## A member of the murmuration never hunts the player (core loop round, the
## lead's direction: the murmuration is the sky's harmless spectacle - its
## starlings carried danger marks round a sparrow-sized player, and now and
## then one of them broke off after it).
func _murmuring() -> bool:
	return b.flock != null and b.flock.kind == "murmuration"


## The player may be picked as prey: in play, not protected, and not
## already being chased by MAX_PLAYER_CHASERS others.
func _player_open(o: Bird) -> bool:
	return _player_ok(o) and (b.target == o or int(o.get_meta(&"npc_chasers", 0)) < MAX_PLAYER_CHASERS)


func _set_target(t: Bird) -> void:
	_drop_target()
	b.target = t
	if t.is_player():
		t.set_meta(&"npc_chasers", int(t.get_meta(&"npc_chasers", 0)) + 1)
	give_up_reason = ""
	_hunt_t = 0.0
	_prev_d = -1.0
	_closing = 0.0
	_slow_t = 0.0
	_passes = 0
	_in_pass = false
	_pass_zone = 0.0
	_unseen_t = 0.0
	_chase_t0 = -1.0
	# Budget the stalk as if the prey might fly straight away from us.
	var d := t.get_body_position().distance_to(_p)
	var closing := maxf(f.sprint - t.velocity.length(), 2.0)
	_approach_budget = clampf(d / closing * 2.0 + 6.0, 10.0, 40.0)
	if t is NpcBird:
		(t as NpcBird).pursuers += 1


func _drop_target() -> void:
	if b.target != null and is_instance_valid(b.target):
		if b.target is NpcBird:
			var t := b.target as NpcBird
			t.pursuers = maxi(t.pursuers - 1, 0)
		elif b.target.is_player():
			b.target.set_meta(&"npc_chasers", maxi(int(b.target.get_meta(&"npc_chasers", 0)) - 1, 0))
	b.target = null


func _hunt_ok(dt: float) -> bool:
	var t := b.target
	if not _valid(t) or not b.can_eat(t):
		give_up_reason = "gone"
		return false
	if t.is_player() and not _player_ok(t):
		give_up_reason = "protected"
		return false
	var tn := t as NpcBird
	if tn != null and tn.hidden:
		# Gone into cover. Prey choose cover too small for the bird they flee
		# (Habitat.pick_refuge): safe from us. Cover we would fit (it fled
		# someone bigger) is still out of play (GameLoop's CatchRule: a hidden
		# bird is not caught) and behind leaves or an opening a hunter's
		# pursuit cannot thread - pressing on meant flying at the walls round
		# it. Either way the chase is over.
		_cooldown[t.get_instance_id()] = 12.0
		give_up_reason = "refuge" if b.get_wingspan() > float(tn.refuge.get("max_span", 0.0)) else "hid"
		return false
	var d := t.get_body_position().distance_to(_p)
	dt = maxf(dt, 1e-3)
	# Out of sight behind a house, a crown or a cliff for more than a moment:
	# lost. A hunter does not bore on through the walls between it and where
	# its quarry was (hunters pressing round buildings were half the birds
	# that hit walls in front of a chasing player).
	if d > 3.0 and not habitat.ray(_p, t.get_body_position() + Vector3.UP * t.get_body_radius() * 2.0).is_empty():
		_unseen_t += dt
		if _unseen_t > LOST_S:
			give_up_reason = "lost"
			return false
	else:
		_unseen_t = 0.0
	if _prev_d >= 0.0:
		_closing = lerpf(_closing, (_prev_d - d) / dt, 0.25)
	_prev_d = d
	# A pass: we got within striking distance - the reach, plus the ground
	# covered in the moment the prey breaks (~0.4 s at the closing speed:
	# a fast hunter is dodged a couple of metres out). Coming out of it
	# without the prey (it jinked, we overshot) counts as a failed attack.
	var strike := b.strike_reach() * 2.0 + maxf(_closing, 0.0) * 0.4
	if d < strike:
		_in_pass = true
		_pass_zone = maxf(_pass_zone, strike)
	elif _in_pass and d > _pass_zone * 3.0:
		_pass_zone = 0.0
		_in_pass = false
		_passes += 1
		_event("miss")
	if _passes >= _max_passes(t):
		give_up_reason = "passes"
		return false
	# Not gaining (closing slower than a walk) for a while, away from a pass.
	if _closing < 0.3 and d > strike * 3.0 and b.state == HUNT:
		_slow_t += dt
	else:
		_slow_t = maxf(_slow_t - dt, 0.0)
	# Patience: long enough for this bird to loop round and come again.
	if _slow_t > maxf(3.0, TAU / f.turn_rate + 1.5):
		give_up_reason = "no_progress"
		return false
	# Persistence: the species' chase time counts from when the prey noticed
	# us (a stalk of an unaware bird is not a chase yet).
	if tn != null and tn.threat == b and _chase_t0 < 0.0:
		_chase_t0 = _hunt_t
		_chase_budget = _chase_time(t, d)
	if _chase_t0 >= 0.0:
		# Past the budget a hunter gives up - unless it is a race between
		# near-equals for a big meal (sprints within RACE_GAP m/s, prey at
		# least RACE_MEAL of its mass) and the prey is flagging
		# (its sprint failing: energy below PREY_FLAGGING) while the hunter
		# is fresher and still gaining: then it runs it down, for up to
		# RACE_EXTRA of its budget (at most the cap for the size of the meal).
		# Such a race is won by stamina, and the hunter can see who is
		# winning it. (A faster hunter decides its chase by closing and
		# striking, within the budget.)
		var chased := _hunt_t - _chase_t0
		if chased > _chase_budget:
			var flagging := tn != null and f.sprint - tn.flight.sprint < RACE_GAP and tn.mass >= b.mass * RACE_MEAL \
				and tn.energy < PREY_FLAGGING and tn.energy < b.energy and _closing > 0.2
			if not flagging or chased > minf(_chase_budget * RACE_EXTRA, _chase_cap(t)):
				give_up_reason = "timeout"
				return false
	elif _hunt_t > _approach_budget + (float(prof["hunt_timeout_s"]) if t.is_player() else 0.0):
		give_up_reason = "timeout"
		return false
	if b.energy < 0.12:
		give_up_reason = "tired"
		return false
	if d > float(prof["hunt_range_m"]) * 1.6:
		give_up_reason = "range"
		return false
	# A bird of the player's sky does not follow a chase off across the
	# valley: past HOME_LEASH home ranges from home it turns back (loose
	# birds - tests, dev scenes - have no such home).
	if b.managed and Vector2(_p.x - b.home.x, _p.z - b.home.z).length() > maxf(HOME_LEASH_M, b.home_radius * HOME_LEASH):
		give_up_reason = "home"
		return false
	return true


## Failed strikes before giving up: a meal an eighth of our mass is worth
## two passes, a third of it three, two thirds four (worth vs effort).
func _max_passes(t: Bird) -> int:
	return clampi(roundi(3.0 * sqrt(t.mass / b.mass / 0.3)), 2, 4)


## How long to keep chasing a prey that has noticed us, d metres away:
## long enough to close the gap at our speed advantage and make a few
## passes (the chase is worth it while we gain - worth vs effort), never
## less than the species' persistence, at most CHASE_MAX_S for the size of
## the meal. (Stamina ends it sooner: see _hunt_ok, "tired".)
func _chase_time(t: Bird, d: float) -> float:
	var their := t.velocity.length()
	var tn := t as NpcBird
	if tn != null:
		their = maxf(their, tn.flight.sprint)
	var gain := maxf(f.sprint - their, 0.5)
	var base := float(prof["hunt_timeout_s"])
	return clampf(d / gain * CHASE_CLOSE_K + CHASE_PASS_S, base, maxf(base, _chase_cap(t)))


## Longest a chase after t may last (see CHASE_MAX_S).
func _chase_cap(t: Bird) -> float:
	return maxf(float(prof["hunt_timeout_s"]), lerpf(CHASE_MAX_S.x, CHASE_MAX_S.y, clampf(t.mass / b.mass / CHASE_FEAST_RATIO, 0.0, 1.0)))


func _give_up_hunt() -> void:
	# A failed chase costs: the hunter regains height and breath before the
	# next (a raptor that missed goes back to a perch or a thermal; it does
	# not launch at the next bird in sight). Without this pause the sky was
	# a constant scramble - ~80 hunts a minute among 60 birds - and prey
	# that tried to perch was chased off nearly every time.
	_hunt_rest_until = _age + b.rng.randf_range(HUNT_REST_S.x, HUNT_REST_S.y) * sqrt(SizeRules.time_scale(b.mass))
	if b.target != null and is_instance_valid(b.target):
		# A failed chase puts the hunter off that bird for a while - longer
		# for the player, so one keen raptor does not come back every few
		# seconds (the danger should come in waves, not a siege).
		_cooldown[b.target.get_instance_id()] = PLAYER_COOLDOWN_S if b.target.is_player() else 8.0
	_event("give_up")
	_event(StringName("give_up_" + give_up_reason))
	_drop_target()
	if prof["perch"] > 0.4 and b.energy < 0.6 and b.flock == null:
		_enter(PERCH)
	if b.state == HUNT or b.state == STOOP:
		_enter(_default_state())


## Raptors with height on their prey fold and stoop; after the pass they
## pull out (zoom) and continue the chase if it is still worth it.
func _maybe_stoop() -> void:
	var t := b.target
	var rel := t.get_body_position() - _p
	var dh := -rel.y
	var hd := Vector2(rel.x, rel.z).length()
	if b.state == HUNT and prof["stoop"]:
		var tp := t.get_body_position()
		var prey_agl := tp.y - habitat.ground_fast(rel.x + _p.x, rel.z + _p.z)
		# A stoop is a dive at 20-30 m/s: only at prey in open air, with a
		# clear line to it - not into a street or a copse after a bird that
		# is among walls and branches (hawks stooping into the village hit
		# its roofs and the church tower). (A prey skimming a field is in
		# open air: the ground is the pull-out's business.)
		if dh > 10.0 and hd < dh * 2.2 and prey_agl > 3.0 and habitat.ray(_p, tp).is_empty() \
				and not habitat.blocked(tp, clampf(prey_agl - 0.5, 1.0, 3.0 + b.get_wingspan())):
			_enter(STOOP)
	elif b.state == STOOP:
		var d := rel.length()
		_stoop_best = minf(_stoop_best, d)
		if dh < 0.5 or (d > _stoop_best + 5.0 and _stoop_best < 12.0):
			_enter(HUNT)


# ---------------------------------------------------------------- fleeing

func _update_refuge_choice() -> void:
	if b.threat == null:
		return
	# Re-judged twice a second (and at once for a new pursuer): it costs a
	# few rays, and cover does not move.
	if b.threat == _refuge_pick_threat and _age - _refuge_pick_t < 0.5:
		return
	_refuge_pick_t = _age
	_refuge_pick_threat = b.threat
	var tp := b.threat.get_body_position()
	var reach := clampf(float(prof["awareness_m"]) * 2.0, 25.0, 90.0)
	# Not into cover where a bird that could eat us - or that we could eat -
	# already sits or is heading (a room or a barn fits big and small
	# birds alike; sharing it would be a catch).
	var taken := []
	for o in Birds.all():
		if o == b or not o.alive:
			continue
		var on := o as NpcBird
		if on == null or on.refuge.is_empty():
			continue
		if SizeRules.can_eat(on.mass, b.mass) or SizeRules.can_eat(b.mass, on.mass):
			taken.append(on.refuge["position"])
	taken.append_array(_bad_refuges)
	# Only cover too small for the pursuer (see Habitat.pick_refuge): with
	# none in reach the bird escapes in the open, by speed and jinks.
	var r := habitat.pick_refuge(_p, b.get_wingspan(), tp, reach, taken, b.threat.get_wingspan())
	if not r.is_empty() and r != b.refuge:
		b.refuge = r
		b.set_contact_target(r["position"], float(r.get("radius", 1.0)) + 1.5)
	elif r.is_empty() and not b.refuge.is_empty():
		b.refuge = {}
		b.clear_contact_target()


# ---------------------------------------------------------------- hiding

## In cover: for how long this time (a breather, and a limit).
func _start_hiding() -> void:
	_hide_min = b.rng.randf_range(HIDE_MIN_S.x, HIDE_MIN_S.y)
	_hide_max = b.rng.randf_range(HIDE_MAX_S.x, HIDE_MAX_S.y)
	_hide_quiet = 0.0
	b.set_state(HIDE)
	_event("refuge")


## Hiding is an event, not a place to live: the bird stays in cover while
## danger presses - a predator after it, or one (or the player) coming this
## way close by (_sense) - and for a short breather; it comes out once it
## has been quiet for a moment, and after _hide_max at the latest. If the
## danger is still about then, it bolts again: something to watch, where
## staying put would leave a third of the valley's birds invisible in
## hedges around a big player (hunters of other birds are everywhere near
## it).
func _think_hidden(dt: float) -> void:
	if _danger_now:
		_hide_quiet = 0.0
	else:
		_hide_quiet += dt
	if (b.state_time >= _hide_min and _hide_quiet >= HIDE_QUIET_S) or b.state_time >= _hide_max:
		b.threat = null
		_enter(_default_state())


# ---------------------------------------------------------------- perching

func _claim_perch() -> bool:
	var kinds: Array = prof["perch_kinds"]
	var centre := _p
	var radius := 140.0
	var list: Array[Perch] = []
	if b.flock != null and b.flock.mood == FlockGroup.Mood.ROOST:
		centre = b.flock.roost_point
		radius = 40.0
	elif b.flock == null:
		# Towards home (homes ride with the player: a hawk rests on a pole
		# where the player flies, not on whatever tree it happens to be over
		# when it tires, a hundred metres off): perches within reach, nearest
		# first, those outside the heart of the home range counting as
		# further by as much as they lie outside it.
		var hc := Vector3(b.home.x, _p.y, b.home.z)
		var core := b.home_radius * 0.6
		list = habitat.find_perches(_p, 140.0, b.get_wingspan(), kinds)
		var cost := func(q: Perch) -> float: return q.position.distance_to(_p) + maxf(Vector2(q.position.x - hc.x, q.position.z - hc.z).length() - core, 0.0)
		list.sort_custom(func(a: Perch, c: Perch) -> bool: return cost.call(a) < cost.call(c))
	if list.is_empty():
		list = habitat.find_perches(centre, radius, b.get_wingspan(), kinds)
	if list.is_empty() and centre != _p:
		centre = _p
		radius = 140.0
		list = habitat.find_perches(_p, 140.0, b.get_wingspan(), kinds)
	list = _uncrowded(list, centre, radius)
	if list.is_empty():
		return false
	# An exhausted bird has little power to spare above level flight: it can
	# still zoom up a few metres on its speed and climb slowly for a while,
	# but a perch 10 m up is out of reach and it would circle under it until
	# it dropped. Keep to perches it can actually get up to (else the lowest).
	var cands: Array = list
	var climb := maxf(b.effort_cap() - f.p_min_frac, 0.0) * f.p_max / 9.81
	if climb < f.climb * 0.5:
		var gain := f.speed * f.speed / (2.0 * 9.81) * 0.5 + climb * 10.0
		cands = list.filter(func(q: Perch) -> bool: return q.position.y <= _p.y + gain)
		if cands.is_empty():
			cands = list.duplicate()
			cands.sort_custom(func(a: Perch, c: Perch) -> bool: return a.position.y < c.position.y)
			cands = cands.slice(0, 3)
	var n := mini(cands.size(), 5)
	var first := b.rng.randi() % n
	var p: Perch = null
	for k in n:
		var q: Perch = cands[(first + k) % n]
		var ad := _pick_approach(q)
		if ad != Vector3.ZERO:
			p = q
			_approach_dir = ad
			break
	if p == null:
		return false
	_release_claim()
	p.occupant = b
	b.perch_spot = p
	b.set_contact_target(p.position, maxf(b.get_wingspan(), 0.5) * 1.5 + 0.8, true, true)
	_event("perch_go")
	return true


## Perches not within reach of a perched bird that could eat this one or
## that this one could eat: settling next to it would be a catch (a hawk
## does not land on the pole top beside a sparrow on the wire; the sparrow
## does not sit down beside the hawk). Same-size birds sit shoulder to
## shoulder.
func _uncrowded(list: Array[Perch], centre: Vector3, radius: float) -> Array[Perch]:
	var others: Array[Bird] = []
	var r2 := (radius + 4.0) * (radius + 4.0)
	for o in Birds.all():
		if o == b or not o.alive or not o.perched:
			continue
		if not (SizeRules.can_eat(o.mass, b.mass) or SizeRules.can_eat(b.mass, o.mass)):
			continue
		if o.global_position.distance_squared_to(centre) < r2:
			others.append(o)
	if others.is_empty():
		return list
	var out: Array[Perch] = []
	for q in list:
		var ok := true
		for o in others:
			var reach := (o.get_body_radius() + b.get_body_radius() + maxf(o.get_wingspan(), b.get_wingspan()) * 0.25 + 0.3) * 1.5
			if o.global_position.distance_squared_to(q.position) < reach * reach:
				ok = false
				break
		if ok:
			out.append(q)
	return out


## Which way to make the final run onto perch p. Preferably along its
## facing (the bird lands facing the way it sits), but a ledge on a cliff or
## wall faces away from the rock: "from behind" is inside the rock. Then it
## comes in from the front or a side, whichever has open air, and turns
## round as it settles. The run must be open both ways and for the body -
## a ray from a waypoint inside a tree crown does not see the crown it
## starts in, so a branch deep among overlapping crowns looked reachable (a
## hawk that tried threaded the crowns and wedged in a pocket between
## them). Returns Vector3.ZERO if no side is open (not a perch for this
## bird).
func _pick_approach(p: Perch, start := 0) -> Vector3:
	var face := Vector3(p.facing.x, 0.0, p.facing.z)
	face = face.normalized() if face.length_squared() > 1e-4 else Vector3.FORWARD
	var r := b.get_body_radius()
	var tp := Habitat.seat(p, r)
	# The waypoint distance _steer_perch flies (at its approach speed): the
	# check must be of the leg that is flown. (It checked a 5-m leg while the
	# steering flew an 11-m one: a pigeon's waypoint for a ledge on the far
	# side of the church lay behind the nave, and it flew into the wall.)
	var L := _approach_len(f.cruise * 1.3)
	var o := tp + Vector3.UP * maxf(0.12, r * 3.0)
	var side := face.cross(Vector3.UP)
	var dirs := [face, -face, side, -side]
	for k in dirs.size():
		var d: Vector3 = dirs[(start + k) % dirs.size()]
		var ok := true
		# The whole leg in: from the waypoint and from half-way out (the
		# steering may place it nearer at lower speed).
		for frac: float in [1.0, 0.5]:
			var wp := tp - d * L * frac + Vector3.UP * L * frac * 0.3
			if wp.y < habitat.ground_fast(wp.x, wp.z) + 1.5 or not (habitat.ray(o, wp).is_empty() \
					and habitat.ray(wp, o).is_empty() and habitat.sweep_clear(wp, o, r * 0.6)):
				ok = false
				break
		if ok:
			_approach_L = L
			return d
	return Vector3.ZERO


## Distance of the perch approach waypoint from the seat at speed vl: three
## slow turn radii, and room to flare.
func _approach_len(vl: float) -> float:
	var slow := f.min_speed * 1.05
	var r_turn := slow / maxf(f.max_turn_rate(slow), 0.3)
	var flare_d := maxf(b.get_wingspan() * 4.0, 2.5) + vl * 0.35
	return maxf(maxf(3.0 * r_turn, 5.0), flare_d * 1.5)


func _release_claim() -> void:
	if b.perch_spot != null and not b.perched:
		if b.perch_spot.occupant == b:
			b.perch_spot.occupant = null
		b.perch_spot = null
		b.clear_contact_target()


func _think_perched() -> void:
	var e := b.energy
	# Perch-hunting: raptors watch from their perch and launch at prey.
	if _may_hunt() and prof["hunt"] >= 0.5 and b.hunger > 0.3 and e > 0.35:
		var pick := _best_prey()
		if not pick.is_empty() and float(pick["score"]) * smoothstep(0.3, 0.8, b.hunger) > 0.12:
			_pending_prey = pick["bird"]
			_enter(HUNT)
			_maybe_stoop()
			return
	var leave := false
	if b.flock != null:
		leave = b.flock.mood == FlockGroup.Mood.FLY and b.state_time > 2.0
	else:
		# Far from home (the home moved on with the player while it rested):
		# back as soon as it has its strength, not after a long rest.
		var far := Vector2(_p.x - b.home.x, _p.z - b.home.z).length() > b.home_radius * 1.5
		leave = (e > 0.92 and b.state_time > _rest_s) or (far and e > 0.6 and b.state_time > 4.0)
	if b.state_time > 90.0:
		leave = true
	if leave:
		_perch_cool = 20.0
		_enter(_default_state())


# ---------------------------------------------------------------- soaring

## Nearest usable thermal within the bird's home range (the ecosystem keeps
## homes near the player, so soaring birds stay part of the player's sky).
func _home_thermal() -> Dictionary:
	var th := habitat.nearest_thermal(_p, b.home_radius * 1.5)
	if th.is_empty():
		return th
	var c: Vector3 = th["position"]
	if Vector2(c.x - b.home.x, c.z - b.home.z).length() > b.home_radius * 1.5:
		return {}
	return th


func _pick_thermal() -> bool:
	var th := _home_thermal()
	if th.is_empty():
		return false
	_thermal = th
	var c := Habitat.thermal_center(th, _p.y)
	_soar_c = Vector3(c.x, 0.0, c.z)
	_circling = false
	if int(th["turn"]) == 0:
		# The first bird in a thermal picks the direction; the rest follow it
		# (as real soaring birds and glider pilots do).
		th["turn"] = 1 if b.rng.randf() < 0.5 else -1
	_soar_turn = int(th["turn"])
	var v := f.v_ms * 1.1
	_soar_r = clampf(v * v / (G * tan(deg_to_rad(38.0))), 5.0, maxf(float(th["radius"]) * 0.6, 6.0))
	return true


## Returns true when the soaring decision is final for this think.
func _think_soar(dt: float) -> bool:
	# Hungry raptors scan below while circling: the stoop comes from here.
	if _may_hunt() and b.hunger > 0.35 and b.energy > 0.3:
		var pick := _best_prey()
		if not pick.is_empty() and float(pick["score"]) * float(prof["hunt"]) * smoothstep(0.3, 0.8, b.hunger) > 0.2:
			_pending_prey = pick["bird"]
			_enter(HUNT)
			_maybe_stoop()
			return true
	if not _circling:
		if b.state_time > 60.0:
			_soar_cool = 20.0
			_enter(_default_state())
			return true
		return true
	# Leave a thermal that does not lift: under 2 m over the last 10 s AND
	# under 1 m over the last 5 s, checked every 5 s (a bird centring the
	# column sinks for its first few seconds; one climbing now stays).
	_climb_t += dt
	if _climb_t >= 5.0:
		_climb_t = 0.0
		_climb_n += 1
		if _climb_n >= 2 and _p.y - _climb_h < 2.0 and _p.y - _climb_h5 < 1.0:
			_soar_cool = 25.0
			_enter(_default_state())
			return true
		_climb_h = _climb_h5
		_climb_h5 = _p.y
	if _agl() > _alt_top() or _p.y > habitat.ceiling - 35.0 \
			or _p.y > float(_thermal.get("top", INF)) - 10.0:
		_soar_cool = 20.0
		_event("thermal_top")
		_enter(_default_state())
		return true
	return true


func _alt_top() -> float:
	return minf(float(prof["alt"][1]), habitat.ceiling * 0.8)


# ---------------------------------------------------------------- steering

func _steer(dt: float) -> void:
	_p = b.global_position
	_steer_dt = dt
	_door_out = Vector3.ZERO
	_o_dir = f.dir()
	_o_speed = f.cruise
	_o_eff = 1.0
	_o_fold = 0.0
	_o_brake = 0.0
	_o_turn = 1.0
	_clear = maxf(float(prof["alt"][0]) * 0.5, 1.5)
	_guard = true
	b.strike = null
	# Birds do not live indoors: one that finds itself inside a building
	# (chased in through a barn door, blown in, wandered in after a flight)
	# leaves by the nearest opening rather than wandering round the room
	# into its walls (a pigeon did, six times in a minute). Not while
	# landing, and a flight to cover has its own way in and out.
	if _near_t > 0.0 and b.state != PERCH and not (b.state == FLEE and not b.refuge.is_empty()) and _indoors_now():
		var ex := habitat.exit_near(_p, 20.0)
		if not ex.is_empty():
			var door: Vector3 = ex["through"]
			var first: Vector3 = ex.get("inner", door)
			if _leg_clear(_p, first) and _leg_clear(first, door):
				_exit_through(ex)
				return
	var q0 := Time.get_ticks_usec() if prof_on else 0
	match b.state:
		WANDER:
			_steer_wander()
		FLOCK:
			_steer_flock()
		SOAR:
			_steer_soar(dt)
		PERCH:
			_steer_perch(dt)
		HUNT:
			_steer_hunt()
		STOOP:
			_steer_stoop()
		FLEE:
			_steer_flee()
			# Fleeing the player past its burst: it flags, whatever the
			# flight (in the open, to cover, in a jink: FLEE_PLAYER_BURST_S).
			if flagging():
				_o_speed = minf(_o_speed, f.cruise * FLEE_PLAYER_FLAG_SPEED)
				_o_eff = minf(_o_eff, FLEE_PLAYER_FLAG_EFFORT)
	if not b.alive or b.perched or b.hidden:
		return
	if _o_dir.length_squared() < 1e-8:
		_o_dir = f.dir()
	_o_dir = _o_dir.normalized()
	var q1 := Time.get_ticks_usec() if prof_on else 0
	_keep_clear()
	_avoid_bump()
	var q2 := Time.get_ticks_usec() if prof_on else 0
	_avoid_obstacles()
	var q3 := Time.get_ticks_usec() if prof_on else 0
	_bounds()
	_ground()
	if prof_on:
		var q4 := Time.get_ticks_usec()
		prof_us[7] += q1 - q0
		prof_us[8] += q2 - q1
		prof_us[9] += q3 - q2
		prof_us[10] += q4 - q3
	# Lift found by chance becomes a known thermal for everyone (checked
	# once per feel, not at every steer of that feel).
	if prof["soar"] > 0.0 and b.state != SOAR and _feel_i % 8 == 0 and _learn_i != _feel_i:
		_learn_i = _feel_i
		var w := habitat.wind(_p).y
		# Only lift in open air can be circled (ridge lift hugs a cliff).
		if w > f.sink_rate(f.speed) + 0.6 and not habitat.blocked(_p, 30.0):
			habitat.learn_thermal(_p, 35.0)
	b.want_dir = _o_dir
	b.want_speed = _o_speed
	b.max_effort = _o_eff
	b.want_fold = _o_fold
	b.want_brake = _o_brake
	b.want_turn = _o_turn


## Height above the ground here: the body measured it this tick (its
## ground clamp), so the brain does not query the world again.
func _agl() -> float:
	return b.agl()


func _pick_goal() -> void:
	var alt: Array = prof["alt"]
	# A spot the bird can fly straight to, if one of a few tries is (not
	# behind a cliff or inside a house: it would fly at the wall, follow
	# it, give up and try again).
	for attempt in 4:
		var spot := habitat.random_spot(prof["habitat"], b.home, b.home_radius, b.rng)
		if Vector2(spot.x - b.home.x, spot.z - b.home.z).length() > b.home_radius * 1.5:
			var a := b.rng.randf() * TAU
			var r := sqrt(b.rng.randf()) * b.home_radius
			spot = Vector3(b.home.x + cos(a) * r, 0.0, b.home.z + sin(a) * r)
		spot.y = habitat.ground_fast(spot.x, spot.z) + b.rng.randf_range(float(alt[0]), minf(float(alt[1]), habitat.ceiling * 0.7))
		# Over whatever stands there (a house, a copse), not inside it or
		# down between the walls of a street: birds going somewhere fly over
		# a village.
		spot.y = maxf(spot.y, habitat.top(spot.x, spot.z, spot.y + 40.0) + maxf(float(alt[0]) * 0.5, 2.0))
		# Well inside the rim: goals near the edge make birds ride the boundary.
		_goal = habitat.clamp_inside(spot, minf(110.0, habitat.bounds_radius * 0.3))
		if habitat.ray(_p, _goal).is_empty():
			break
	_goal_t = 0.0
	_goal_life = b.rng.randf_range(20.0, 40.0)
	_goal_free = false


func _steer_wander() -> void:
	# A new goal when this one is reached, old, or - the home moves with the
	# player - no longer in the home range (else birds trail a travelling
	# player to where it used to be).
	if _goal_t > _goal_life or Vector2(_goal.x - _p.x, _goal.z - _p.z).length() < 12.0 \
			or (not _goal_free and Vector2(_goal.x - b.home.x, _goal.z - b.home.z).length() > b.home_radius * 1.6) \
			or _goal_blocked():
		_pick_goal()
	_o_dir = _goal - _p
	var erratic: float = prof["erratic"]
	if erratic > 0.0:
		# Moths flutter: a new random wobble a few times a second.
		if b.rng.randf() < 0.07:
			_jitter = Vector3(b.rng.randf_range(-1, 1), b.rng.randf_range(-0.6, 0.6), b.rng.randf_range(-1, 1))
		_o_dir = _o_dir.normalized() + _jitter * erratic * 0.75
	_relaxed()
	var from_home := Vector2(_p.x - b.home.x, _p.z - b.home.z).length()
	if not _goal_free and from_home > b.home_radius * 2.0 and b.energy > 0.35:
		# Far from home (it moved on with the player): commute back briskly.
		_o_speed = f.cruise * 1.15
		_o_eff = 0.95
	elif prof["style"] == "soar" and _agl() > float(prof["alt"][0]) + 10.0 and _o_dir.y < 5.0:
		# Soaring birds glide between thermals and flap only when low.
		_o_eff = 0.12
		_o_speed = f.v_md


## True if an obstacle has been in the way for GOAL_BLOCKED_S and the
## straight line to the goal still runs into it.
func _goal_blocked() -> bool:
	if _obs_busy < GOAL_BLOCKED_S:
		return false
	_obs_busy = 0.0
	return not habitat.ray(_p, _goal).is_empty()


## Travelling birds cruise: climb at a gentle angle and never flat out
## (they save the sprint for when it matters).
func _relaxed() -> void:
	var h := Vector2(_o_dir.x, _o_dir.z).length()
	if h > 1e-4:
		_o_dir.y = clampf(_o_dir.y, -h * 0.5, h * 0.22)
	_o_eff = minf(_o_eff, 0.75)


func _steer_flock() -> void:
	var fl := b.flock
	if fl == null:
		_steer_wander()
		return
	var murm := fl.kind == "murmuration"
	var k := 7 if murm else 5
	var span := b.get_wingspan()
	var sep_r := span * (7.0 if murm else 9.0)
	if _flock_off == Vector3.INF:
		# Each member keeps its own spot in the swarm (so the flock has volume
		# rather than collapsing onto one line); spots scale with flock size.
		# (A murmuration packs tighter than a loose flock: a dozen starlings
		# spread over a field's width read as scattered birds, not a body.)
		var rad := sep_r * (0.6 if murm else 0.8) * sqrt(float(maxi(fl.members.size(), 1)))
		_flock_off = Vector3(b.rng.randf_range(-1, 1), b.rng.randf_range(-0.4, 0.4), b.rng.randf_range(-1, 1)) * rad
	# k nearest flock-mates (topological neighbours, as starlings use).
	var nd: Array[float] = []
	var nb: Array[NpcBird] = []
	for m in fl.members:
		if m == b or not is_instance_valid(m) or not m.alive or m.perched or m.hidden:
			continue
		var d2: float = m.global_position.distance_squared_to(_p)
		if nb.size() < k:
			nb.append(m)
			nd.append(d2)
		else:
			var wi := 0
			for i in range(1, k):
				if nd[i] > nd[wi]:
					wi = i
			if d2 < nd[wi]:
				nb[wi] = m
				nd[wi] = d2
	var sep := Vector3.ZERO
	var ali := Vector3.ZERO
	var coh := Vector3.ZERO
	for i in nb.size():
		var m := nb[i]
		var rel: Vector3 = _p - m.global_position
		var d := sqrt(nd[i])
		if d < sep_r and d > 1e-3:
			sep += rel / d * (1.0 - d / sep_r)
		ali += m.velocity
		coh += m.global_position
	var desired := Vector3.ZERO
	if not nb.is_empty():
		var n := float(nb.size())
		ali = ali / (n * maxf(f.cruise, 1.0))
		coh = (coh / n - _p) / maxf(sep_r * 4.0, 1.0)
		if coh.length() > 1.0:
			coh = coh.normalized()
		desired = sep * 2.2 + ali * 1.0 + coh * (1.05 if murm else 0.8)
	var to_a := fl.anchor + _flock_off - _p
	var da := to_a.length()
	if da > 0.01:
		desired += to_a / da * (0.25 + clampf(da / (70.0 if murm else 40.0), 0.0, 1.8))
	# A flock among houses or trees climbs out over them: boids keep mates
	# apart and together, not off walls (flocks of pigeons crossing the
	# village low brushed its walls).
	if _near_t > 0.0 and _agl() < CLUTTER_AGL:
		var hh := Vector2(desired.x, desired.z).length()
		desired.y = maxf(desired.y, hh * 0.35)
	_o_dir = desired
	_o_speed = f.cruise * (1.0 + clampf((da - 25.0) / 100.0, 0.0, 0.25))
	_relaxed()
	# A flock the Ecosystem shows ahead of the player (FlockGroup.show_alt)
	# wheels at an easier effort: at 0.9 every flock tires within ~30 s and
	# roosts, and the show went dark every half minute.
	_o_eff = 0.9 if is_nan(fl.show_alt) else SHOW_FLOCK_EFFORT
	if murm:
		_clear = 8.0


func _steer_soar(dt: float) -> void:
	if _thermal.is_empty():
		_steer_wander()
		return
	var rel := Vector3(_p.x - _soar_c.x, 0.0, _p.z - _soar_c.z)
	var dh := rel.length()
	var rad := float(_thermal["radius"])
	if not _circling:
		_o_dir = Vector3(-rel.x, 0.0, -rel.z)
		if _agl() > float(prof["alt"][0]) + 5.0:
			_o_eff = 0.15
			_o_speed = f.v_md
		if dh < rad * 0.9:
			_circling = true
			_climb_h = _p.y
			_climb_h5 = _p.y
			_climb_n = 0
			_climb_t = 0.0
			_w_avg = habitat.wind(_p).y
			_event("thermal")
		return
	if _near_t > 0.0 and b.state_time > 1.0 and ((not _ob_p.is_empty() and _ob_age[0] < 0.3 \
			and obs_plane_d() < _soar_r * 0.5 + b.get_wingspan() + 2.0) or (_feel_i % 12 == 0 \
			and habitat.blocked(Vector3(_soar_c.x, _p.y, _soar_c.z), _soar_r + b.get_wingspan() + 1.5))):
		# The circle at this height runs into something (a tower, a crown by
		# the thermal - or a feeler has just seen something in the way): not
		# a thermal to circle here (an eagle circled into the church spire).
		_soar_cool = 25.0
		_enter(_default_state())
		return
	var radial := rel / maxf(dh, 0.01)
	var tangent := Vector3.UP.cross(radial) * float(_soar_turn)
	var err := clampf((dh - _soar_r) / _soar_r, -1.0, 1.0)
	_o_dir = tangent - radial * err * 1.6
	_o_speed = f.v_ms * 1.1
	# Glide in the lift; flap only if we are sinking out near the ground.
	_o_eff = 0.0 if _agl() > float(prof["alt"][0]) * 0.6 else 0.5
	# Centring: shift the circle towards where the lift was stronger than
	# average (the classic glider-pilot technique).
	var w := habitat.wind(_p).y
	_soar_c += radial * dh * clampf((w - _w_avg) * 0.25, -0.3, 0.3) * dt
	_w_avg = lerpf(_w_avg, w, clampf(dt * 0.4, 0.0, 1.0))
	var c := Habitat.thermal_center(_thermal, _p.y)
	var drift := Vector3(_soar_c.x - c.x, 0.0, _soar_c.z - c.z)
	if drift.length() > rad * 0.6:
		_soar_c = Vector3(c.x, 0.0, c.z) + drift.normalized() * rad * 0.6


func _steer_perch(dt_steer: float) -> void:
	var p := b.perch_spot
	if p == null:
		_steer_wander()
		return
	var r := b.get_body_radius()
	var tp := Habitat.seat(p, r)
	var face := p.facing
	face.y = 0.0
	face = face.normalized() if face.length_squared() > 1e-4 else Vector3.FORWARD
	var slow := f.min_speed * 1.05
	var r_turn := slow / maxf(f.max_turn_rate(slow), 0.3)
	var to := tp - _p
	var d := to.length()
	var v := b.velocity
	var vl := maxf(v.length(), 0.1)
	# Close, pointing at it and nothing in the way: flare in. Birds drop onto
	# a perch from just above it (never through the twig from below): leg one
	# to a point above the perch, fully checked; leg two straight down.
	var flare_d := maxf(b.get_wingspan() * 4.0, 2.5) + vl * 0.35
	var above := tp + Vector3.UP * maxf(0.12, r * 3.0)
	# (Within ~60 deg of it, not only dead ahead: circling round a tree for
	# the perfect line in, a wren bumped the crown three times - once the
	# straight way in is open, a landing bird takes it.)
	if d < flare_d * 1.3 and v.dot(to) > 0.5 * vl * d and _line_clear(above, 0.0) and _leg_clear(above, tp):
		var perch := p
		var land := func() -> void:
			if b.perch_spot == perch and b.alive:
				b.land_on(perch)
				_rest_s = b.rng.randf_range(8.0, 30.0) * (2.0 if prof["stoop"] else 1.0)
				b.set_state(PERCHED)
				_event("perch")
		b.flare_to(above, face, func() -> void:
			if b.alive and b.perch_spot == perch:
				b.flare_to(tp, face, land), true)
		return
	_clear = 0.3
	var L := maxf(maxf(3.0 * r_turn, 5.0), flare_d * 1.5)
	if _perch_phase == 0:
		# Approach waypoint: on the approach side (behind the perch along its
		# facing where there is air), a little above, so the final leg is
		# straight and slow.
		_phase_t += dt_steer
		# Never farther out than the leg _pick_approach checked.
		var lw := minf(L, _approach_L) if _approach_L > 0.0 else L
		_approach = tp - _approach_dir * lw + Vector3.UP * lw * 0.3
		var ta := _approach - _p
		_o_dir = ta
		_o_speed = f.cruise * 0.8
		if ta.length() < maxf(L * 0.35, 2.0):
			_perch_phase = 1
			_phase_t = 0.0
		elif _phase_t > 12.0:
			# Cannot get to that waypoint (terrain, a roof in the way): try
			# another side, and give the perch up after a few.
			_phase_t = 0.0
			_perch_fail += 1
			var ad := _pick_approach(p, _perch_fail)
			if ad != Vector3.ZERO:
				_approach_dir = ad
			if _perch_fail >= 4 or ad == Vector3.ZERO:
				_perch_cool = 15.0
				_enter(_default_state())
	else:
		_phase_t += dt_steer
		_guard = d > 3.0
		_o_dir = to
		_o_speed = slow if d < L * 1.5 else f.cruise * 0.7
		# Give the final leg time to line up before calling it an overshoot.
		if _phase_t > 1.5 and d > flare_d * 1.5 and v.dot(to) < 0.0:
			# Went past it: go round again.
			_perch_phase = 0
			_phase_t = 0.0
			_perch_fail += 1
			if _perch_fail >= 4:
				_perch_cool = 15.0
				_enter(_default_state())


## Nothing solid between us and p, apart from the thing we are landing on:
## the centre line must be clear, and the body (60% of its radius) must be
## able to sweep along it (so a crow's shoulders do not clip a window frame).
## True if the body (the A5 check's 60% of it) can fly straight from a to
## b, stopping a hair short of b (the contact spot).
func _leg_clear(a: Vector3, c: Vector3) -> bool:
	var d := c - a
	var L := d.length()
	if L < 0.05:
		return true
	return habitat.sweep_clear(a, a + d * maxf((L - 0.05) / L, 0.0), b.get_body_radius() * 0.6)


func _line_clear(p: Vector3, ignore_r: float) -> bool:
	var hit := habitat.ray(_p, p)
	if not hit.is_empty() and (hit["position"] as Vector3).distance_to(p) >= ignore_r:
		return false
	var d := p - _p
	var L := d.length()
	if L < 0.05:
		return true
	# Stop the body sweep a hair short of the end point (the contact spot).
	var end := _p + d * maxf((L - 0.05) / L, 0.0)
	return habitat.sweep_clear(_p, end, b.get_body_radius() * 0.6)


## Lead pursuit: fly at the intercept point of the prey's current velocity.
func _intercept(rel: Vector3, tv: Vector3, s: float) -> float:
	var a := tv.length_squared() - s * s
	var bq := 2.0 * rel.dot(tv)
	var c := rel.length_squared()
	var t := -1.0
	if absf(a) < 1e-6:
		if bq < 0.0:
			t = -c / bq
	else:
		var disc := bq * bq - 4.0 * a * c
		if disc >= 0.0:
			var sq := sqrt(disc)
			var t1 := (-bq - sq) / (2.0 * a)
			var t2 := (-bq + sq) / (2.0 * a)
			if t1 > 0.0 and t2 > 0.0:
				t = minf(t1, t2)
			else:
				t = maxf(t1, t2)
	if t <= 0.0:
		t = sqrt(c) / maxf(s, 1.0)
	return t


## Pursuit guidance. Far off or pointing away: lead pursuit towards the
## intercept point. Once roughly on course: proportional navigation (turn the
## velocity at N times the line-of-sight rotation rate), which is what real
## raptors (and missiles) do and what converges on a turning target without
## the tail-chase lag of pure pursuit.
func _pursue(t: Bird, s: float, max_tgo: float) -> Vector3:
	var tp := t.get_body_position()
	var r := tp - _p
	var d2 := maxf(r.length_squared(), 1e-4)
	var v := b.velocity
	var vl := v.length()
	var tv := t.velocity
	var lead := tp + tv * minf(_intercept(r, tv, s), max_tgo)
	if vl < 0.5:
		return lead - _p
	var my := v / vl
	var cos_a := my.dot(r / sqrt(d2))
	var closing := -(tv - v).dot(r) / sqrt(d2)
	if cos_a < 0.5 or closing <= 0.0:
		# A point inside our own turning circle cannot be reached by turning
		# at it - we would orbit it. Extend straight until it falls outside,
		# then come round (what a fighter pilot or a big raptor does).
		var h := Vector3(my.x, 0.0, my.z)
		if h.length_squared() > 1e-4:
			h = h.normalized()
			var right := h.cross(Vector3.UP)
			var to_aim := lead - _p
			var side := 1.0 if to_aim.dot(right) >= 0.0 else -1.0
			var r_t := vl / maxf(f.max_turn_rate(vl), 0.1)
			var c := _p + right * side * r_t
			var off := Vector2(lead.x - c.x, lead.z - c.z).length()
			if off < r_t * 0.95:
				return h + Vector3.UP * clampf(to_aim.y / maxf(r_t, 1.0), -0.3, 0.3)
		return lead - _p
	var los_rate := r.cross(tv - v) / d2
	var w := los_rate * 4.0
	return my + w.cross(my) / maxf(f.heading_gain, 1.0)


## An attack on the player: within HUNT_PLAYER_COMMIT_S of contact it holds
## its line between re-aims and turns at HUNT_PLAYER_TURN of the bird's rate
## (see there); further out it pursues as ever. `want` is where pursuit
## would steer now.
func _attack_player(t: Bird, want: Vector3) -> Vector3:
	var rel := t.get_body_position() - _p
	var d := rel.length()
	var closing := -(t.velocity - b.velocity).dot(rel / maxf(d, 1e-3))
	var tgo := maxf(d - b.strike_reach(), 0.0) / maxf(closing, 0.1)
	if tgo > hunt_player_commit_s and closing > 0.0:
		_attack_of = null
		return want
	_o_turn = hunt_player_turn
	if _attack_of != t or _attack_dir == Vector3.ZERO or _age >= _attack_next:
		_attack_of = t
		_attack_dir = want.normalized() if want.length_squared() > 1e-8 else f.dir()
		_attack_next = _age + float(prof["reaction_s"]) * hunt_player_reaim
	return _attack_dir


func _steer_hunt() -> void:
	var t := b.target
	if not _valid(t):
		return
	var tp := t.get_body_position()
	var rel := tp - _p
	_o_dir = _pursue(t, maxf(f.speed, f.cruise * 1.15), 3.0)
	if t.is_player():
		_o_dir = _attack_player(t, _o_dir)
	_o_speed = f.max_speed
	_o_eff = 1.0
	# Stalk at 80% power while the prey has not noticed us and is not close:
	# power grows with v^3, so that is ~97% of sprint speed for ~60% of
	# the fatigue - the sprint is saved for the chase.
	var tn0 := t as NpcBird
	var unaware := tn0 == null or tn0.threat != b
	if unaware and rel.length() > maxf(25.0, float(SpeciesProfile.of(t.species)["awareness_m"]) * 1.1):
		_o_eff = 0.8
	# Prey above: give up some speed for height (energy trade) instead of
	# sprinting flat underneath it.
	var up := _o_dir.normalized().y
	if up > 0.1:
		_o_speed = lerpf(f.max_speed, f.cruise, clampf((up - 0.1) / 0.3, 0.0, 1.0))
	_clear = 0.6 + b.get_body_radius()
	b.strike = t
	var tn := t as NpcBird
	if tn != null and (tn.perched or tn.hidden):
		_guard = rel.length() > 4.0
		# The feelers let it close in, but the body collides as ever: a catch
		# needs the bodies to touch, not the hunter's body to reach the
		# prey's centre - which, for a bird on a roof ridge or inside a nest
		# box, means through the roof or the box (a wren went through a
		# box's wall instead of its hole, a gull into a cottage's eaves).
		b.set_contact_target(tp, maxf(b.get_wingspan(), 0.5) + 0.5, false)
	else:
		b.clear_contact_target()


func _steer_stoop() -> void:
	var t := b.target
	if not _valid(t):
		return
	var tp := t.get_body_position()
	var d := (tp - _p).length()
	_o_dir = _pursue(t, maxf(f.speed, f.cruise), 4.0)
	if t.is_player():
		_o_dir = _attack_player(t, _o_dir)
	_o_speed = f.max_speed
	_o_eff = 0.4
	b.strike = t
	# Tucked for speed while far and steep; open up near the prey to steer.
	var steep := -_o_dir.normalized().y
	var r_v := f.speed / maxf(f.max_turn_rate(f.speed), 0.2)
	_o_fold = 1.0 if steep > 0.35 and d > f.speed * 0.5 + r_v * 0.25 else 0.35
	_clear = 1.2 + b.get_body_radius()


func _steer_flee() -> void:
	var th := b.threat
	if not _valid(th):
		return
	var tp := th.get_body_position()
	var tv := th.velocity
	# The prey judges the attack by the hunter's lead point - where the
	# hunter will be FLEE_LEAD_S from now (its line and speed are what a bird
	# sees) - and flees away from that point.
	var lead_pt := tp + tv * FLEE_LEAD_S
	var rel := _p - lead_pt
	var d := maxf(rel.length(), 0.01)
	var away := rel / d
	away.y *= 0.35
	_o_speed = f.max_speed
	_o_eff = 1.0
	if th.is_player():
		_o_turn = FLEE_PLAYER_TURN
		# A limited burst, then it flags (FLEE_PLAYER_BURST_S; applied in
		# _steer after every branch of this flight).
		flee_burst_used += _steer_dt
	_clear = 0.8 + b.get_body_radius()
	# Cover first: dive into a refuge the predator cannot follow into.
	if not b.refuge.is_empty():
		var rp: Vector3 = b.refuge["position"]
		var to_r := rp - _p
		var dr := to_r.length()
		var vl := maxf(b.velocity.length(), 0.1)
		var rr := float(b.refuge.get("radius", 1.0))
		var dive_d := maxf(rr * 2.0, 2.0) + vl * 0.3
		var entry: Dictionary = b.refuge.get("entry", {})
		if not entry.is_empty():
			# Line up on the opening's axis outside it, then flare straight in.
			var door: Vector3 = entry["through"]
			var out: Vector3 = entry["out"]
			if entry.get("two_sided", false) and (_p - door).dot(out) < 0.0:
				out = -out
			var lead := maxf(3.0, vl * 0.4) + b.get_wingspan()
			var wp := door + out * lead
			# In front of the opening and roughly in line with it (lateral and
			# vertical offsets judged against its width and height): the first
			# flare leg brings the bird exactly onto the axis from there.
			var rel_d := _p - door
			var lat_axis := out.cross(Vector3.UP)
			lat_axis = lat_axis.normalized() if lat_axis.length_squared() > 1e-4 else Vector3.RIGHT
			var up_axis := lat_axis.cross(out).normalized()
			var on_axis := rel_d.dot(out) > 0.5 \
				and absf(rel_d.dot(lat_axis)) < float(entry["width"]) * 0.5 + 1.5 \
				and absf(rel_d.dot(up_axis)) < float(entry["height"]) * 0.5 + 1.5
			var lineup := door + out * (1.0 + b.get_wingspan())
			if dr < 30.0 and (_p - door).dot(out) > 0.0:
				_door_out = out
			if on_axis and (_p - door).dot(out) < lead + 2.0 and _line_clear(lineup, 0.05):
				# The legs fly themselves (kinematic): the body must fit
				# through all of them - a crow and a sparrow clipped a door
				# frame on the leg from the opening to the spot inside it.
				if not (_leg_clear(lineup, door) and (rp.distance_to(door) <= 0.3 or _leg_clear(door, rp))):
					if _bad_refuges.size() >= 8:
						_bad_refuges.pop_front()
					_bad_refuges.append(rp)
					b.refuge = {}
					b.clear_contact_target()
					return
				# Three kinematic legs: onto the axis in front of the opening,
				# straight through its mouth, on to the hiding spot. (Openings
				# can be a 22 cm hedge tunnel: no steering is that precise.)
				var ref2 := b.refuge
				_refuge_entry = -out
				var finish := func() -> void:
					if b.alive:
						b.hide_in(ref2)
						_start_hiding()
				var inside := func() -> void:
					if not b.alive:
						return
					if rp.distance_to(door) > 0.3:
						b.flare_to(rp, -out, finish)
					else:
						finish.call()
				# Keep the pace through the first two legs; only the last brakes.
				b.flare_to(lineup, -out, func() -> void:
					if b.alive:
						b.flare_to(door, -out, inside, rp.distance_to(door) > 0.3), true)
				return
			_o_dir = wp - _p
			_guard = dr > 6.0
			_o_speed = maxf(f.cruise, f.min_speed * 1.3) if dr < 15.0 else f.max_speed
			return
		# No known opening: dive straight in when the way is clear, else come
		# in from above (hedge gaps, holes seen side-on are open above).
		if dr < dive_d * 2.5 and not _line_clear(rp, rr * 0.3):
			_o_dir = rp + Vector3.UP * clampf(dr * 0.5, 1.5, 5.0) - _p
			_guard = false
			_o_speed = maxf(f.cruise, f.min_speed * 1.3)
			return
		if dr < dive_d and b.velocity.dot(to_r) > 0.7 * vl * dr and _line_clear(rp, rr * 0.3):
			var ref := b.refuge
			_refuge_entry = to_r.normalized()
			b.flare_to(rp, to_r, func() -> void:
				if b.alive:
					b.hide_in(ref)
					_start_hiding())
			return
		_o_dir = to_r
		if dr < 12.0:
			_guard = false
			_o_speed = maxf(f.cruise, f.min_speed * 1.3)
		return
	# Selfish herd: flocked prey bunch towards their flock-mates.
	var desired := away
	if b.flock != null:
		var c := b.flock.centroid() - _p
		if c.length() > 1.0:
			desired += c.normalized() * 0.5
	# In among buildings or trees with no cover chosen, escape upwards to
	# open sky rather than down into the streets (a flat-out dash between
	# houses ends against a wall).
	if _near_t > 0.0 and _agl() < CLUTTER_AGL:
		var h := Vector2(desired.x, desired.z).length()
		desired.y = maxf(desired.y, h * 0.45)
	# Hold the escape line during the final run: re-aiming "away" from a
	# predator a metre off would swing the bird sideways every tick - a free,
	# perfect dodge. Real prey fly flat out and break only with a jink.
	# Between re-evaluations (at the bird's reaction rate) it flies straight.
	# The attack run is on once the hunter's lead point has reached and is
	# going past us - the hunter is within FLEE_LEAD_S of us at its own speed
	# (`passing` > 0: the rate at which that point moves on beyond us). Until
	# then the prey re-aims away from the lead point at its reaction rate
	# (each re-aim is a small swerve the hunter must follow); during the run
	# it holds its line - re-aiming away from a hunter a metre off would be a
	# free, perfect dodge every tick - and breaks only with a jink.
	var passing := (tv - b.velocity).dot(-rel / d)
	var final_run := passing > 0.0 and d / maxf(passing, 0.1) < 1.8
	if _flee_dir == Vector3.ZERO or (not final_run and _age >= _flee_next):
		_flee_dir = desired.normalized()
		if _near_t > 0.0:
			# Among buildings and trees: the open heading nearest to "away"
			# (a flat-out dash straight away from a hunter ends against a wall
			# - most of the hard hits a chasing player saw were such prey).
			_flee_dir = _open_dir(_flee_dir)
		# (Fleeing the player it holds each line longer: FLEE_PLAYER_REAIM.)
		_flee_next = _age + float(prof["reaction_s"]) * (FLEE_PLAYER_REAIM if th.is_player() else 1.0)
	desired = _flee_dir
	# Evasive jink: when the predator is about to strike, break hard
	# sideways across its path; its wider turn makes it overshoot.
	# How soon, in the run, the lead point is a strike reach beyond us (the
	# reach depends on the hunter's size; the player - arms for wings - is
	# given a whole wingspan).
	var reach := th.get_wingspan()
	if th is NpcBird:
		reach = (th as NpcBird).strike_reach()
	# Seconds until the lead point is a strike reach beyond us (not a time to
	# contact: the run is judged by the lead point, see above).
	var t_reach := maxf(d - reach, 0.0) / maxf(passing, 0.1)
	# Evasive jink: each time the predator commits to a strike run, the prey
	# breaks hard sideways across its path at some moment before contact.
	# Timing is everything: too early and the hunter re-aims, too late and
	# the talons are already there. Skill narrows the timing around the
	# sweet spot; it is still a gamble, which makes chases contests.
	if passing > 0.5 and t_reach < 1.6:
		if _jink_at < 0.0:
			# A new attack run: will we see it coming and dodge, and when?
			var skill: float = prof["jink"]
			_run_jink = b.rng.randf() < skill * (0.55 + 0.45 * b.energy)
			_jink_at = 0.38 + (b.rng.randf() - 0.5) * (1.3 - skill)
		if _run_jink and t_reach < _jink_at and _jink_t <= 0.0:
			var u := tv / maxf(tv.length(), 0.1)
			var lat := rel - u * rel.dot(u)
			lat.y *= 0.3
			if lat.length() < 0.05:
				lat = u.cross(Vector3.UP) * (1.0 if b.rng.randf() < 0.5 else -1.0)
			_jink_dir = lat.normalized() + Vector3.DOWN * b.rng.randf_range(0.0, 0.35) - u * 0.25
			_jink_t = b.rng.randf_range(0.3, 0.5)
			if _near_t > 0.0:
				# Break to the side that has room for it (the far side of the
				# hunter's line if the near one is a wall; up if both are).
				var need := b.velocity.length() * _jink_t + b.get_wingspan() + 0.5
				var ln := lat.normalized()
				if not habitat.ray(_p, _p + ln * need).is_empty():
					if habitat.ray(_p, _p - ln * need).is_empty():
						_jink_dir = -ln + Vector3.DOWN * 0.1 - u * 0.25
					else:
						_jink_dir = Vector3.UP - u * 0.25
			_run_jink = false
			_event("jink")
	elif t_reach > 2.5 or passing <= 0.0:
		_jink_at = -1.0
	if _jink_t > 0.0:
		desired = _jink_dir
	_o_dir = desired


## How long this bird can sprint away from `from` (the player) before it
## flags (see FLEE_PLAYER_BURST_S).
func flee_burst_s(from: Bird) -> float:
	var r := b.mass / maxf(from.mass, 1e-6)
	return FLEE_PLAYER_BURST_S * sqrt(SizeRules.time_scale(b.mass)) * (1.0 + FLEE_PLAYER_NEAR_EQUAL * smoothstep(0.3, 0.7, r))


## Whether the bird's sprint from the player has run out (it is flagging).
func flagging() -> bool:
	return b.state == FLEE and _valid(b.threat) and b.threat.is_player() and flee_burst_used > flee_burst_s(b.threat)


## The heading nearest to `want` that is open for a turn's worth of flight
## ahead: want itself if it is, else the best of it swung 35 and 70 deg to
## either side and pitched up 35 deg, scored by how far each is open and how
## close it stays to want. (Called at the bird's reaction rate, and only
## near geometry.)
func _open_dir(want: Vector3) -> Vector3:
	var sp := maxf(b.velocity.length(), f.cruise)
	var look := clampf(sp * 1.2 + sp / maxf(f.max_turn_rate(sp), 0.3), 6.0, 40.0)
	var hit := habitat.ray(_p, _p + want * look)
	if hit.is_empty():
		return want
	var best := want
	var best_s := (_p.distance_to(hit["position"]) / look) * 1.0
	for c in 5:
		var d: Vector3
		if c < 4:
			d = want.rotated(Vector3.UP, [0.6, -0.6, 1.2, -1.2][c])
		else:
			d = (want + Vector3.UP * 0.7).normalized()
		var h := habitat.ray(_p, _p + d * look)
		var free := 1.0 if h.is_empty() else _p.distance_to(h["position"]) / look
		var s2 := free * (0.6 + 0.4 * d.dot(want))
		if s2 > best_s:
			best_s = s2
			best = d
	return best


# ---------------------------------------------------------------- safety overlays

## Give a wide berth to a predator that is not hunting (yet).
func _keep_clear() -> void:
	if not _valid(_nuisance) or b.state == HUNT or b.state == STOOP or b.state == FLEE:
		return
	var away := _p - _nuisance.get_body_position()
	var d := away.length()
	var r := float(prof["awareness_m"]) * 0.5
	if d < 0.01 or d > r:
		return
	away.y *= 0.3
	_o_dir = (_o_dir + away.normalized() * (1.0 - d / r) * 1.5).normalized()

## Do not fly into a smaller bird by accident (it would be a catch): steer
## away from where the two would pass closest. Birds share a thermal or a
## tree without touching; only a hunt aims at contact.
func _avoid_bump() -> void:
	if not _valid(_bump) or b.state == HUNT or b.state == STOOP or _bump == b.target:
		return
	var rel := _bump.get_body_position() - _p
	var dv := _bump.velocity - b.velocity
	var dv2 := dv.length_squared()
	var tca := clampf(-rel.dot(dv) / dv2, 0.0, 1.2) if dv2 > 1e-4 else 0.0
	var m := rel + dv * tca
	var ml := m.length()
	var safe := (b.get_body_radius() + b.get_wingspan() * 0.25 + 0.5 + _bump.get_body_radius()) * 1.5
	if ml > safe:
		return
	var away := -m / ml if ml > 1e-3 else b.velocity.cross(Vector3.UP).normalized()
	away.y *= 0.5
	_o_dir = (_o_dir + away * (1.0 - ml / safe) * 3.0).normalized()


## The body hit something: treat it as an obstacle right in front of us so
## the avoidance overlay steers off it (a bird pinned against a wall has
## almost no velocity, so its feelers would not see the wall).
func on_bump(n: Vector3) -> void:
	_remember(b.global_position - n * b.get_body_radius(), n, 4.0)
	_near_t = 1.5
	_flee_dir = Vector3.ZERO
	if _goal_t > 2.0:
		_goal_t = 999.0
	if b.state == SOAR:
		# A thermal that grinds us against rock is not worth circling.
		_soar_cool = 30.0
		_enter(_default_state())


## The body's collision ray found a surface less than NpcBird.IMMINENT_S of
## flight ahead: remember it, brake for it at once and steer at the next
## tick (not at the next feel or steer).
func on_imminent(hp: Vector3, n: Vector3) -> void:
	if b.is_contact_target(hp) or b.state == PERCH:
		return
	_remember(hp, n, maxf(b.velocity.length() * 1.5, 3.0))
	_ahead_d = _p.distance_to(hp)
	_ahead_n = n
	_ahead_t = _age
	_near_t = maxf(_near_t, 1.0)
	_steer_acc = 1.0


## Safety net for traps nobody foresaw (the real world's geometry is built in
## parallel): a free-flying bird that has not got anywhere for seconds picks
## a new goal in open air, straight up and away.
func unstick() -> void:
	_event("unstick")
	_near_t = 3.0
	_forget_obstacles()
	if b.state == PERCH:
		# That perch cannot be reached from here: let it go for a while.
		_release_claim()
		_perch_cool = 30.0
	if b.state == SOAR:
		_soar_cool = 30.0
	if b.state != WANDER and b.state != FLOCK and b.state != FLEE:
		_enter(_default_state())
	# Still inside the cover we used last? Leave through its opening.
	var last: Dictionary = b.refuge if not b.refuge.is_empty() else _last_refuge
	if last.has("entry") and _p.distance_to(last["position"]) < 25.0:
		var entry: Dictionary = last["entry"]
		if _line_clear(entry["through"], 0.05):
			_exit_through(entry)
			return
	# Trapped in some room or loft: any nearby door or window will do. (Only
	# when plainly indoors: from a yard or a street the nearest door leads
	# into a house. An open-fronted shed is left by the open-sky probe below.)
	if habitat.indoors(_p):
		var ex := habitat.exit_near(_p, 20.0)
		if not ex.is_empty():
			_exit_through(ex)
			return
	# Otherwise head for the most open direction around (probe rays).
	var best_dir := Vector3.UP
	var best_len := -1.0
	for i in 12:
		var a := TAU * float(i % 8) / 8.0
		var el := 0.0 if i < 8 else 0.6
		var d := Vector3(cos(a) * cos(el), sin(el), sin(a) * cos(el))
		var hit := habitat.ray(_p, _p + d * 40.0)
		var free := 40.0 if hit.is_empty() else _p.distance_to(hit["position"])
		if free > best_len:
			best_len = free
			best_dir = d
	_goal = habitat.clamp_inside(_p + best_dir * minf(best_len, 30.0) + Vector3.UP * 5.0, 40.0)
	_goal_t = 0.0
	_goal_life = 10.0
	_goal_free = true
	b.want_dir = best_dir


## The body is about to back out of a trap along its trail (NpcBird.escape):
## drop what led it in (a perch it could not reach, a thermal, a chase) and
## let nothing interrupt the way out (a flight from a predator would cancel
## the leg and leave it wedged).
func before_escape() -> void:
	_event("unstick")
	if b.state == PERCH:
		_release_claim()
		_perch_cool = 30.0
	if b.state == SOAR:
		_soar_cool = 30.0
	if b.state != WANDER and b.state != FLOCK and b.state != FLEE:
		_enter(_default_state())
	_exiting = true


## Out of the trap, flying along dir: on the same way for a while, well
## clear, before anything else (the pocket is behind it).
func after_escape(dir: Vector3) -> void:
	_exiting = false
	_goal = habitat.clamp_inside(b.global_position + dir * 25.0 + Vector3.UP * 4.0, 40.0)
	_goal_t = 0.0
	_goal_life = 10.0
	_goal_free = true
	_forget_obstacles()
	_near_t = 2.0
	_flee_dir = Vector3.ZERO


## Leave an enclosed refuge the way in: flare to the opening, then straight
## out along its axis (a room or loft has no other way out).
func _exit_through(entry: Dictionary) -> void:
	var door: Vector3 = entry["through"]
	var out: Vector3 = entry["out"]
	var outside := door + out * (2.0 + b.get_wingspan() * 2.0)
	# (Out along the opening's axis as far as the body fits - something may
	# stand close outside a door.)
	if not _leg_clear(door, outside):
		outside = door + out * (1.0 + b.get_wingspan())
	# Nothing may interrupt the way out (a flight, a perch, a chase would
	# cancel the flare and leave the bird steering round inside the room,
	# into its walls): _enter keeps it while _exiting.
	_exiting = true
	var through := func() -> void:
		if b.alive:
			b.flare_to(door, out, func() -> void:
				if b.alive:
					b.flare_to(outside, out, func() -> void:
						_exiting = false
						if b.alive:
							b.flight.set_velocity(out * b.flight.min_speed * 1.2)
							_goal_t = 999.0, true), true)
	# (door -> outside runs straight along the opening's axis; a window seen
	# at a grazing angle is approached square-on from a point inside first.)
	if entry.has("inner"):
		b.flare_to(entry["inner"], out, through, true)
	else:
		through.call()


func _feel(feel_iv: float) -> void:
	var v := b.velocity
	var sp := v.length()
	if sp < 0.5:
		v = b.want_dir * maxf(f.min_speed, 1.0)
		sp = v.length()
		if sp < 0.1:
			return
	var fwd := v / sp
	var r_turn := sp / maxf(f.max_turn_rate(sp), 0.3)
	var look := clampf(sp * 1.0 + r_turn * 1.2, 3.0, 110.0)
	var slot := _feel_i % 4
	_feel_i += 1
	# Rays this feel: slots 0 and 2 look straight ahead - down the middle
	# and, beside it, a body radius and a margin off the path (a ray down
	# the middle misses a trunk, post or wire the shoulders would clip):
	# above/below with slot 0, left and right with slot 2; slots 1 and 3
	# look 26 deg left and right, shorter.
	var rays := []
	if slot == 1 or slot == 3:
		var d := fwd
		if fwd.x * fwd.x + fwd.z * fwd.z > 1e-4:
			d = fwd.rotated(Vector3.UP, 0.45 if slot == 1 else -0.45)
		rays.append([_p, d, look * 0.7])
	else:
		var side := fwd.cross(Vector3.UP)
		side = side.normalized() if side.length_squared() > 1e-4 else Vector3.RIGHT
		var up := side.cross(fwd).normalized()
		var off := b.get_body_radius() + b.get_wingspan() * 0.25 + 0.15
		# (In open air - nothing solid seen lately - the middle ray is
		# enough: the offset ones only matter close to thin things, and
		# they are the bulk of the cost for 60 birds.)
		if slot == 0 or _near_t <= 0.0:
			rays.append([_p, fwd, look])
			if _near_t > 0.0:
				rays.append([_p + up * off * (1.0 if (_feel_i / 4) % 2 == 0 else -1.0), fwd, look])
		else:
			rays.append([_p + side * off, fwd, look])
			rays.append([_p - side * off, fwd, look])
	for ry in rays:
		var from: Vector3 = ry[0]
		# (An offset start inside a wall would see nothing: check it, when
		# anything solid is about at all.)
		if from != _p and _near_t > 0.0 and not habitat.ray(_p, from).is_empty():
			continue
		var hit := habitat.ray(from, from + (ry[1] as Vector3) * float(ry[2]))
		# The ray straight down the flight path: what the bird would fly into
		# if it held its course (see _brake_for_ahead).
		var centre: bool = from == _p and ry[1] == fwd
		if centre:
			_ahead_t = _age
			_ahead_d = INF
		if hit.is_empty():
			continue
		var hp: Vector3 = hit["position"]
		# The tree or roof we are landing on is not something to steer away
		# from - but it is solid: the body's collision sweep must stay on.
		_near_t = 1.5
		if b.is_contact_target(hp):
			continue
		if centre:
			_ahead_d = from.distance_to(hp)
			_ahead_n = hit["normal"]
		_remember(hp, hit["normal"], look)
	# Anything solid the bird could reach before the next feel switches the
	# per-tick collision sweep on (thin trunks and wires slip between rays).
	if _near_t <= feel_iv:
		if habitat.blocked(_p, sp * feel_iv * 1.6 + 2.0 + b.get_body_radius()):
			_near_t = maxf(_near_t, feel_iv * 2.5)


## Remember a surface a feeler (or the body) found: the nearest one wins -
## a new hit replaces the remembered surface if that was not seen for a
## moment or the new one is nearer (by its plane).
func _remember(hp: Vector3, n: Vector3, look: float) -> void:
	if _ob_p.is_empty():
		_ob_p.append(hp)
		_ob_n.append(n)
		_ob_look.append(look)
		_ob_age.append(0.0)
		return
	var dist := (_p - hp).length()
	if _ob_age[0] > 0.3 or dist < maxf((_p - _ob_p[0]).dot(_ob_n[0]), 0.0) + 0.5:
		_ob_p[0] = hp
		_ob_n[0] = n
		_ob_look[0] = look
		_ob_age[0] = 0.0


func _drop_obstacle(i: int) -> void:
	_ob_p.remove_at(i)
	_ob_n.remove_at(i)
	_ob_look.remove_at(i)
	_ob_age.remove_at(i)


func _forget_obstacles() -> void:
	_ahead_d = INF
	_ob_p.clear()
	_ob_n.clear()
	_ob_look.clear()
	_ob_age.clear()
	_obs_busy = 0.0


## Distance from the nearest remembered surface (its local plane), or INF
## if there is none (diagnostics).
func obs_plane_d() -> float:
	var best := INF
	for i in _ob_p.size():
		if _ob_age[i] <= OBS_MEMORY_S:
			best = minf(best, maxf((_p - _ob_p[i]).dot(_ob_n[i]), 0.0))
	return best


## The speed to brake to, or INF: the flight path runs into a surface the
## centre feeler saw (at most a feel or two ago) closer than the flight can
## still turn parallel to it. Turning through the angle theta it meets the
## surface at takes r_turn (1 - cos theta) of room; the room is its distance
## from the surface's plane less the body, a margin and the ground covered
## before the next steer. The turn radius shrinks with the square of the
## speed, so braking to v sqrt(room / needed) makes it fit. Only what is in
## the path counts: a crown or a wall the bird will pass beside does not
## slow it (a hawk striking at a wren in a tree came in braking from 18 m).
func _brake_for_ahead() -> float:
	if _ahead_d == INF or _age - _ahead_t > 0.35:
		return INF
	var v := b.velocity
	var vl := v.length()
	if vl <= f.min_speed:
		return INF
	var vn := -v.dot(_ahead_n)
	if vn <= 0.5:
		return INF
	var sin_t := clampf(vn / vl, 0.0, 1.0)
	var along := _ahead_d - vl * (_age - _ahead_t)
	var r_t := vl / maxf(f.max_turn_rate(vl), 0.2)
	var turn := r_t * (1.0 - sqrt(1.0 - sin_t * sin_t))
	var room := along * sin_t - b.get_body_radius() - 0.5 - vn * 0.15
	if room >= turn * 1.5:
		return INF
	return vl * sqrt(clampf(room / maxf(turn * 1.5, 0.01), 0.0, 1.0))


## Keep out of the remembered surface: never head into it while it is near
## (the bird slides along a wall rather than turning back into it the
## moment its forward feeler clears), follow the wall when the goal lies
## straight through it (instead of turning tail, forgetting the wall and
## coming back at it), and push away more the closer it gets - and brake
## when the flight path runs into something closer than the flight can
## still turn off (_brake_for_ahead).
## Forgotten OBS_MEMORY_S after a feeler last saw it, or once the bird is
## past it (gone round a trunk).
func _avoid_obstacles() -> void:
	var brake_v := _brake_for_ahead()
	if brake_v < INF:
		_o_speed = minf(_o_speed, maxf(brake_v, f.min_speed * 1.05))
		_o_fold = 0.0
		_o_brake = 1.0
	for i in range(_ob_p.size() - 1, -1, -1):
		if _ob_age[i] > OBS_MEMORY_S or (_p - _ob_p[i]).dot(_ob_n[i]) < -0.5:
			_drop_obstacle(i)
	if _ob_p.is_empty():
		_obs_busy = 0.0
		return
	var n := _ob_n[0]
	var look := _ob_look[0]
	var dist := maxf((_p - _ob_p[0]).dot(n), 0.0)
	if dist > look:
		return
	if _door_out != Vector3.ZERO and n.dot(_door_out) > 0.9:
		return  # the face of the wall with the opening we are lining up on
	_obs_busy += _steer_dt
	# Fly at a speed whose turn fits the room: in a street a sprinting hawk
	# (19 m/s, a 14-m turn) cannot follow its quarry round a corner and
	# hits the wall; at a speed with a turn radius within the distance to
	# the wall it can. (The turn radius grows with the square of the speed.)
	var vl := b.velocity.length()
	if vl > f.min_speed * 1.2 and b.velocity.dot(n) < 0.3 * vl:
		var r_now := vl / maxf(f.max_turn_rate(vl), 0.2)
		var room := maxf(dist, 1.0) * 1.2 + b.get_wingspan()
		if r_now > room:
			_o_speed = minf(_o_speed, maxf(vl * sqrt(room / r_now), f.min_speed * 1.2))
	var closeness := clampf(1.0 - dist / look, 0.0, 1.0)
	var dd := _o_dir
	var into := dd.dot(n)
	if into < 0.0:
		dd -= n * into
		if dd.length_squared() < 0.25:
			# The way on is straight through it: follow the wall, the way the
			# bird is already turning (or right, if it flies square at it),
			# at a stand-off its side feelers still reach - pushed out inside
			# it, drawn back in beyond it. (Pushed away from the wall by
			# closeness alone the bird veered out of feeler range, forgot the
			# wall, and came back at it: a zigzag of grazes.)
			var t := b.velocity - n * b.velocity.dot(n)
			t.y *= 0.3
			if t.length_squared() < 0.01:
				t = n.cross(Vector3.UP)
			if t.length_squared() < 1e-4:
				t = f.dir() - n * f.dir().dot(n)
			var standoff := look * 0.25 + b.get_wingspan()
			var k := clampf((standoff - dist) / standoff, -0.3, 1.0)
			_o_dir = (t.normalized() + n * k * 1.5 + Vector3.UP * 0.1).normalized()
			if dist < standoff * 0.5:
				_o_speed = minf(_o_speed, f.cruise)
				_o_fold = 0.0
			return
	var push := n * closeness * 2.0
	if n.y < -0.3:
		# The underside of an eave, a branch or a crown: away from it is
		# down, but a bird does not dive at the roof or the ground below to
		# clear an overhang - it goes round it, level (a crow landing on a
		# roof dived from an eave onto the next roof at 5 m/s).
		push.y *= 0.2
	dd += push
	if absf(n.y) < 0.6:
		# A wall ahead: prefer going over it if it is low, around otherwise.
		dd += Vector3.UP * closeness * 0.3
	_o_dir = dd.normalized()
	if closeness > 0.5:
		_o_speed = minf(_o_speed, f.cruise)
		_o_fold = 0.0


func _bounds() -> void:
	var hr := Vector2(_p.x, _p.z).length()
	var R := habitat.bounds_radius
	var m := minf(70.0, R * 0.2)
	if hr > R - m and hr > 1.0:
		var inward := Vector3(-_p.x, 0.0, -_p.z) / hr
		_o_dir = (_o_dir + inward * (hr - (R - m)) / m * 3.0).normalized()
		if b.state == WANDER and _goal_t > 3.0:
			_goal_t = 999.0
	var top := habitat.ceiling - 25.0
	if _p.y > top:
		_o_dir = (_o_dir + Vector3.DOWN * (_p.y - top) / 25.0 * 2.0).normalized()


## Stay above the ground, allowing for the height a pull-out costs at the
## current speed and dive angle (a stooping hawk needs tens of metres).
func _ground() -> void:
	if not _guard:
		return
	var v := b.velocity
	var sp := maxf(f.speed, 0.1)
	# High above everything (most of the sky, most of the time): nothing
	# this overlay does could apply within its 1.2-s look ahead - no slope
	# the feelers would not see as a wall rises that fast - so skip the
	# terrain lookups (60 birds, 24-72 times a second each).
	var hv := Vector2(v.x, v.z).length()
	if b.agl() > hv * 1.2 + maxf(-v.y, 0.0) * 2.0 + _clear * 3.0 + 4.0:
		return
	var ahead := _p + Vector3(v.x, 0.0, v.z) * 1.2
	var gy := maxf(_p.y - b.agl(), habitat.ground_fast(ahead.x, ahead.z))
	var agl := _p.y - gy
	var vl := maxf(v.length(), 0.1)
	var sin_g := clampf(v.y / vl, -1.0, 1.0)
	var lost := 0.0
	if sin_g < 0.0:
		var r_v := sp / maxf(f.max_turn_rate(sp), 0.2)
		lost = r_v * (1.0 - sqrt(1.0 - sin_g * sin_g)) + (-v.y) * 0.35
	if _near_t > 0.0 and b.state != PERCH:
		# Among buildings and trees the clearance is kept above whatever is
		# below - a roof, a hedge, a crown - not just the ground: a bird
		# flying over the village stays over it rather than sinking into its
		# streets, where every turn is a wall. (Not on the way down to a
		# perch, which is on such a surface.)
		var reach := lost + _clear + 1.0
		var hit := habitat.ray(ahead + Vector3.UP * (_p.y - ahead.y), ahead + Vector3.UP * (_p.y - ahead.y - reach))
		if not hit.is_empty():
			var hy: float = (hit["position"] as Vector3).y
			if hy > gy + 0.5 and hy < _p.y:
				gy = hy
				agl = _p.y - gy
	var margin := agl - lost - _clear
	if margin < 0.0 and _near_t > 0.0 and not habitat.ray(_p, _p + Vector3.UP * (b.get_body_radius() + 2.0)).is_empty():
		# Low, but under a roof or a tree crown: climbing would press the bird
		# into it (a tired hawk ground against the crown over a pocket in a
		# copse for minutes, its clearance asking to climb). Hold height and
		# fly out from under it; the clearance applies again in the open.
		if _o_dir.y < 0.0:
			_o_dir.y = 0.0
			_o_dir = _o_dir.normalized() if _o_dir.length_squared() > 1e-6 else f.dir()
		return
	if margin < 0.0:
		var h := Vector3(_o_dir.x, 0.0, _o_dir.z)
		if h.length_squared() < 1e-4:
			h = Vector3(v.x, 0.0, v.z)
		if h.length_squared() < 1e-4:
			h = Vector3.FORWARD
		h = h.normalized()
		# Rising ground it cannot out-climb because it has almost no power
		# to spare (an exhausted bird can only hold height): turn off the
		# slope as well as up. "Just climb" left a tired hawk skimming up a
		# hillside, caught by the ground clamp every half second. A bird
		# with power in hand still climbs straight on (to a cliff ledge, a
		# hole in the cliff).
		var spare := f.climb_gradient(sp, b.effort_cap())
		if hv > 1.0 and spare < 0.08:
			var g0 := _p.y - b.agl()
			var rise := (habitat.ground_fast(ahead.x, ahead.z) - g0) / (hv * 1.2)
			if rise > spare - 0.02:
				var down := Vector3(habitat.ground_fast(_p.x - 2.0, _p.z) - habitat.ground_fast(_p.x + 2.0, _p.z), 0.0,
						habitat.ground_fast(_p.x, _p.z - 2.0) - habitat.ground_fast(_p.x, _p.z + 2.0))
				if down.length_squared() > 1e-6:
					h = h.lerp(down.normalized(), clampf((rise - spare + 0.02) * 10.0, 0.2, 0.9)).normalized()
		_o_dir = (h + Vector3.UP * clampf(-margin / maxf(_clear, 1.0), 0.35, 1.5)).normalized()
		_o_fold = 0.0
		_o_eff = 1.0
	elif margin < _clear * 2.0 and _o_dir.y < 0.0:
		_o_dir.y *= margin / (_clear * 2.0)
		_o_dir = _o_dir.normalized()
