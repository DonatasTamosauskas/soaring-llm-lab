class_name BirdNPC
extends Node3D

## A rival bird.
##
## Crucially it flies through the *same* [FlightModel] the player does — it
## banks to turn, must dive to build speed, and cannot climb without flapping.
## An NPC that cheated physics would immediately give the game away, and would
## also make the size/agility tradeoff meaningless. The only sanctioned
## exception is [method _avoid_ground], which comments its own reasoning.
##
## What that constraint buys, once a bird also has to pay for its wingbeats
## ([member energy]), is that every behaviour below is a technique rather than a
## script: a predator climbs before it stoops because height is the only speed it
## can afford, prey dives for the deck because diving is free, and both of them
## look for lift because lift is the only height nobody has to pay for.
##
## This file is one bird's brain: what to do about the thing it is looking at.
## Who is looking at whom, and who has claimed which branch, is [Flock].

signal died(bird: BirdNPC)

## [br]WANDER — cross-country, going somewhere.
## [br]HUNT   — committed: the stoop, or the tail chase after it.
## [br]FLEE   — running, using the ground for cover.
## [br]PERCH  — sitting on a branch, wire or ledge, resting.
## [br]STALK  — closing on prey from above and behind, outside its notice range.
## [br]SOAR   — circling in lift, climbing for free.
## [br]LAND   — approaching a claimed perch.
##
## The first four keep their original ordinals: nothing serialises this, but the
## save-nothing rule is not a licence to shuffle an enum other code reads.
enum State { WANDER, HUNT, FLEE, PERCH, STALK, SOAR, LAND }

const SENSE_RADIUS: float = 95.0
## How long a bird stays down once it is down. Long enough that a roost is a
## thing you can fly over and see, rather than a bird touching a branch and
## bouncing straight off it.
const PERCH_REST_MIN: float = 18.0
const PERCH_REST_MAX: float = 50.0
## Prey must be this much smaller to be worth chasing, and predators this much
## bigger to be worth running from. The gap stops birds of near-equal size from
## twitching between hunting and fleeing.
const SIZE_MARGIN: float = 1.12

# --- hunting -------------------------------------------------------------------

## Inside this range a hunter stops setting up and commits.
const STOOP_RANGE: float = 55.0
## How far above and behind its prey a stalking bird tries to sit. Height is
## stored speed: a bird that arrives level with its quarry has to out-fly it,
## and two birds on the same [FlightModel] differ by a few percent of speed.
const STALK_HEIGHT: float = 30.0
const STALK_TRAIL: float = 40.0
## The most a committed hunter will ask to climb, in metres above itself.
##
## It is a compromise, and it was measured from both ends. Uncapped, a hunter
## below its quarry pitches up, arrives slow and drops behind — a chase of
## zooms, each one further back than the last. Capped hard at eight metres, a
## hunter simply cannot reach anything flying above it: [SessionProbe] flew ten
## minutes with a hundred percent survival, which is a game with nothing to fear
## in it. Twenty-five metres is a climb the airspeed guard in
## [method _steer_toward] can actually fly.
const INTERCEPT_CLIMB: float = 25.0
## How far above prey a hunter has to be before tucking into the dive.
const STOOP_HEIGHT: float = 8.0
## Seconds a bird will keep after one particular meal [i]without making any
## progress[/i], how long a chase may last however well it is going, and how long
## the bird then ignores that quarry. Without all three, two evenly matched
## fliers chase each other until one of them leaves the map.
const HUNT_PATIENCE: float = 12.0
const HUNT_LIMIT: float = 45.0
const HUNT_GRUDGE: float = 12.0

# --- fleeing --------------------------------------------------------------------

## How far ahead a frightened bird plans its escape.
const FLEE_DISTANCE: float = 120.0
## How close to the ground it tries to get while doing it, as a multiple of its
## own size. Hugging terrain is not decoration: [method Flock.has_sight] tests
## the ground between two birds, so a ridge really does break the chase.
const FLEE_CLEARANCE: float = 12.0
## Seconds between changes of escape bearing. A straight run is a solved
## intercept problem; a jink is not.
const JINK_INTERVAL: float = 2.2

# --- wings and energy ------------------------------------------------------------

## Fraction of a bird's reserves a full-power wingbeat costs per second. Nine
## seconds of flat-out flapping empties it.
##
## This is the constant that makes the sky an ecosystem rather than a screensaver.
## Without it a frightened bird climbs away from anything for ever — its wingbeat
## is free, while the player's costs a real arm — and nothing in the world has any
## reason to ever land. With it, a chase is a budget: run now and roost later.
const FLAP_DRAIN: float = 0.115
## Reserves recovered per second gliding, plus a bonus for doing it in lift,
## plus what an actual rest on a branch is worth.
const GLIDE_RECOVER: float = 0.045
const LIFT_RECOVER: float = 0.055
const ROOST_RECOVER: float = 0.22
## Below this a bird cannot beat its wings at full power; the shortfall scales
## smoothly so exhaustion is a fade, not a switch.
const TIRED_ENERGY: float = 0.22
## Reserves at which a bird starts looking for somewhere to sit.
const ROOST_ENERGY: float = 0.3
## Reserves it wants before leaving again.
const RESTED_ENERGY: float = 0.8

# --- perching ---------------------------------------------------------------------

## How far a perched bird sits nose-up, in radians. Birds do not stand level.
const PERCH_PITCH: float = 0.45
## How far above the published perch point the bird's centre sits, as a multiple
## of its size — a branch tip is inside the foliage blob it belongs to.
const PERCH_LIFT: float = 0.30
## How close to its claimed perch a bird has to get to be on it.
const LAND_RADIUS: float = 3.0
## Seconds to make the approach work before giving up on that branch. A bird
## that cannot get down is the classic way an AI hangs: it must always be able
## to stop trying.
const LAND_TIMEOUT: float = 40.0
## Seconds before a bird that has just left a perch will look for another.
const PERCH_COOLDOWN: float = 20.0
## How far a bird will go to take a branch off a neighbour. Short, so that the
## eviction happens with the challenger already bearing down on the perch rather
## than a hundred metres away and out of sight.
const SQUABBLE_RADIUS: float = 90.0
## And how close is too close once it is down. Roughly one tree.
const SQUABBLE_TOUCH: float = 18.0
## How often a bird re-measures how crowded it is, in seconds.
const CROWD_INTERVAL: float = 0.1
## And how often it re-measures the air. See [method _sample_air].
const WIND_INTERVAL: float = 0.1
## How close something that eats you has to be to be worth abandoning a perch
## for. Scattering a roost is one of the few things in this game that happens
## because the player flew somewhere.
const FLUSH_RADIUS: float = 55.0

# --- soaring ------------------------------------------------------------------------

## Height a bird is content with, above the ground under it. Below this it takes
## any lift it is offered; above it, it gets on with going somewhere.
##
## It is also where the flock ends up living, which is the reason the number is
## this high: with the old value birds circled in the bottom fifty metres of
## every thermal — the lift reaches all the way to the ground — and the band the
## player actually flies in was empty.
const CRUISE_CEILING: float = 210.0
## Lift, in m/s, worth stopping to circle in. Weak lift is not worth the turn:
## a bird that stops for every whisper never gets anywhere, and forty percent of
## the flock circling at once reads as a sky full of moths.
const SOAR_LIFT: float = 2.4
## And the lift below which a core is considered lost.
const SOAR_LOST_LIFT: float = 0.7
## How a bird works a thermal: a steady moderate bank, flown slow.
##
## Both halves matter and the second one is the one people get wrong. A bird
## circling at trim speed sinks faster than any core in this world lifts; easing
## the nose up to just under minimum-sink speed is what turns a 50 m/min descent
## into a 100 m/min climb. Swept over bank and angle of attack against the real
## world before choosing: at this bank and this much extra alpha a size-1 bird
## climbs about 65 m a minute in a good core and drifts 28 m across it, while at
## trim speed the same circle loses 50 m a minute.
##
## It is also the technique the player can copy, which is the whole point of
## making birds do it where they can be seen: spread, ease up, hold the turn.
const SOAR_BANK: float = 0.66
const SOAR_ALPHA: float = 0.14
const SOAR_TIMEOUT: float = 60.0
## Seconds of no lift before leaving a core.
const SOAR_PATIENCE: float = 5.0

var model := FlightModel.new()
var command := FlightCommand.new()
var state: State = State.WANDER
var size: float = 1.0

var world: WorldBuilder
## The flock this bird senses through. Optional: a bird with no flock still
## flies, still wanders and still reacts to whatever [member target] it is
## handed — it simply has no peers, no perch claims and no sight of its own.
var flock: Flock

## What the outside world has told this bird to care about (the player, from
## [GameManager]).
var target: Node3D = null
## What the flock's own senses turned up. Merged with [member target] by
## [method _interest]: the nearest thing that can eat this bird beats the
## nearest thing it can eat, every time.
var rival: BirdNPC = null

## Reserves, 0..1. Flapping spends it, gliding earns it slowly, lift earns it
## faster and a perch earns it fastest.
var energy: float = 1.0

var _goal: Vector3 = Vector3.ZERO
var _goal_timer: float = 0.0
var _perch_timer: float = 0.0
var _flap_phase: float = 0.0
var _rng := RandomNumberGenerator.new()
var _body: Node3D
var _scaler: Node3D
var _rig: BirdRig

## The one bird this one is currently doing something about, resolved once per
## think from [member target] and [member rival] — see [method _interest].
var _focus: Node3D = null
var _clock: float = 0.0
var _state_timer: float = 0.0
var _perch_index: int = -1
var _perch_cooldown: float = 0.0
var _rest_timer: float = 0.0
var _launch_timer: float = 0.0
var _jink: float = 0.0
var _jink_timer: float = 0.0
var _soar_direction: float = 1.0
var _soar_dry: float = 0.0
## The best lift this bird has found in the core it is working, and where.
var _core: Vector3 = Vector3.ZERO
var _core_lift: float = 0.0
## Instance id of a bird this one has given up on, and when it will care again.
var _grudge_id: int = 0
var _grudge_until: float = 0.0
var _hunt_started: float = 0.0
var _hunt_best_range: float = INF
var _hunt_since: float = 0.0
## The last position that was a position. See [method fly].
var _last_good: Vector3 = Vector3.ZERO
var _crowd: Vector3 = Vector3.ZERO
var _crowd_timer: float = 0.0
var _wind: Vector3 = Vector3.ZERO
var _wind_timer: float = 0.0
var _last_delta: float = 0.0
## Whether the wings are working this frame, and how hard. Kept apart from
## [member FlightCommand.stroke_speed], which is zero for half of every beat.
var _working: bool = false
var _effort: float = 0.0


func configure(new_size: float, spawn: Vector3, world_ref: WorldBuilder, rng_seed: int) -> void:
	_rng.seed = rng_seed
	size = new_size
	world = world_ref
	position = spawn
	_last_good = spawn
	model.set_size(size)
	model.heading = _rng.randf() * TAU
	model.velocity = model.forward() * model.trim_speed()
	energy = _rng.randf_range(0.55, 1.0)
	_rest_timer = _rng.randf_range(30.0, 120.0)
	# [method _ready] has already run by the time a manager configures a bird, so
	# without this a freshly spawned bird wore the size it was built with — 1.0 —
	# until something else happened to resize it. Every spawned bird was the same
	# size on screen no matter what size it actually was, which is a lie about
	# the one fact the player has to read fastest.
	_apply_size()
	_pick_new_goal()


func _ready() -> void:
	_build_visual()
	_apply_size()


func _build_visual() -> void:
	# Rotation and scale are kept on separate nodes on purpose: slerping a basis
	# that carries a scale is not a valid rotation and Godot rejects it.
	_body = Node3D.new()
	add_child(_body)
	_scaler = Node3D.new()
	_body.add_child(_scaler)

	# Feathers come from the shared palette rather than from the whole hue circle:
	# a random hue put teal and magenta birds in an earth-coloured world. See
	# [method Palette.plumage].
	_rig = BirdRig.new()
	_scaler.add_child(_rig)
	_rig.build(BirdMesh.species_for_size(size), Palette.plumage(_rng.randf()))


## Glow tells you, at a glance and at 40 m/s, whether the shape ahead is lunch
## or a predator. It is deliberately the *second* cue rather than the only one:
## the silhouette a bird wears is chosen by its size class, so a five-fingered
## eagle is readable as an eagle before any tint is applied — see [BirdMesh].
func show_threat(relative_to_size: float) -> void:
	if _rig == null:
		return
	if GameRules.can_catch(relative_to_size, size):
		# As strong as the predator tint, and then some. It was 0.55, and at that
		# strength a bird you could eat was invisible at forty metres while a bird
		# that could eat you was not — so the game answered "run" clearly and
		# "hunt" not at all. Both halves of the question deserve the same budget.
		_rig.set_threat(Palette.colour("threat_prey"), 0.95)
	elif GameRules.can_catch(size, relative_to_size):
		_rig.set_threat(Palette.colour("threat_predator"), 0.8)
	else:
		_rig.set_threat(Palette.colour("threat_prey"), 0.0)


func _apply_size() -> void:
	if _scaler != null:
		_scaler.scale = Vector3.ONE * size
	if _rig != null:
		# Eating enough to change size class changes what you look like, which is
		# the only reason anyone else in the sky can tell that you did.
		_rig.set_species(BirdMesh.species_for_size(size, _rig.species))


func set_size(new_size: float) -> void:
	size = clampf(new_size, 0.2, 10.0)
	model.set_size(size)
	_apply_size()


func catch_radius() -> float:
	return 0.55 * size


## Where this bird is.
##
## Not [member Node3D.global_position], which reads zero for a node that is not
## inside a scene tree — and the headless ecosystem in `tests/EcosystemSim.gd`
## runs a whole flock outside one. In the game the two are identical, because
## every bird hangs directly off the manager and nothing in that chain carries a
## transform.
func at() -> Vector3:
	return global_position if is_inside_tree() else position


## Where this bird looks from. A metre matters here: sight is tested against
## terrain, and a bird's own position is its centre, not its eye.
func eye() -> Vector3:
	return at() + Vector3.UP * (0.35 * size)


func is_perched() -> bool:
	return state == State.PERCH


func _physics_process(delta: float) -> void:
	fly(delta)


## One step of being a bird, exposed so a headless ecosystem can drive a flock
## faster than real time and without a scene tree. [method _physics_process] is
## nothing but a call to this.
func fly(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	# Sanitised at the boundary, the same rule [FlightModel.step] follows: a bird
	# handed a broken state carries on being a bird. Reserves are repaired to
	# empty rather than full, because a bird that has just come back from NaN has
	# not earned a wingbeat.
	if not is_finite(energy):
		energy = 0.0
	if not position.is_finite():
		position = _last_good
		model.velocity = Vector3.ZERO
	else:
		_last_good = position
	_last_delta = delta
	_clock += delta
	_state_timer += delta
	_perch_cooldown = maxf(0.0, _perch_cooldown - delta)
	_rest_timer -= delta
	_launch_timer = maxf(0.0, _launch_timer - delta)

	if state == State.PERCH:
		_process_perched(delta)
		return

	_sample_air()
	_think(delta)
	# Landing happens inside the think: a bird that touched down this frame must
	# not then be flown one more step off its own branch.
	if state == State.PERCH:
		return
	command.wind = _wind
	_spend_energy(delta)
	model.step(command, delta)
	position += model.velocity * delta
	_avoid_ground()
	_update_pose(delta)


# --- deciding ------------------------------------------------------------------

## Steering is expressed purely as wing commands — a heading and altitude the
## bird wants, converted into bank, angle of attack and effort. It has no
## ability to move except by flying, exactly like the player.
func _think(delta: float) -> void:
	_goal_timer -= delta
	_choose_state()

	match state:
		State.HUNT:
			_goal = _intercept()
		State.STALK:
			_goal = _stalking_point()
		State.FLEE:
			_goal = _escape_point(delta)
		State.LAND:
			# Arrival and the give-up timer are checked here rather than in
			# [method _choose_state] so that they are checked every frame,
			# whatever else the bird has noticed.
			_continue_landing()
			if state != State.LAND:
				return
			_goal = _approach_point()
		State.SOAR:
			_steer_soaring(delta)
			return
		State.WANDER:
			if _goal_timer <= 0.0 or at().distance_to(_goal) < 40.0:
				_pick_new_goal()

	_steer_toward(_goal + _crowding(), delta)


func _choose_state() -> void:
	var previous: State = state
	_focus = _interest()

	if _focus != null and _is_threat(_focus):
		_enter(State.FLEE)
	elif _focus != null:
		_choose_hunt(_focus)
	else:
		_hunt_started = 0.0
		_hunt_best_range = INF
		match state:
			State.HUNT, State.STALK, State.FLEE:
				_enter(State.WANDER)
			State.WANDER:
				_choose_errand()
	if previous != state:
		_goal_timer = 0.0


## Committing, or setting up. A hunter that beelines is a hunter that arrives
## slow, low and in front of its quarry; one that climbs first arrives with
## twenty metres of height to spend and does it from behind.
func _choose_hunt(quarry: Node3D) -> void:
	var range_now: float = at().distance_to(_position_of(quarry))
	if _hunt_started <= 0.0:
		_hunt_started = _clock
		_hunt_since = _clock
		_hunt_best_range = range_now
	elif _clock - _hunt_since > HUNT_LIMIT and range_now > STOOP_RANGE * 0.6:
		# There is a limit to a chase however well it is going. Two birds that
		# are still at it after three quarters of a minute are a dogfight nobody
		# is winning, and with progress-based patience they will go on for ever:
		# the ecosystem run measured a pair circling each other for eighty
		# seconds and getting nowhere.
		_give_up_on(quarry)
		return
	elif range_now < _hunt_best_range - 5.0:
		# Getting somewhere. Patience is for chases that are going nowhere, not
		# for chases that are slow: a hunter closing a metre a second on a bird
		# seventy metres ahead needs a minute, and giving up at twelve seconds
		# meant every stern chase in the game was abandoned half way.
		_hunt_best_range = range_now
		_hunt_started = _clock
	elif _clock - _hunt_started > HUNT_PATIENCE:
		# Getting nowhere. Give up on this one for a while: two birds of nearly
		# equal speed can otherwise chase each other out of the world.
		_give_up_on(quarry)
		return

	var offset: Vector3 = _position_of(quarry) - at()
	var distance: float = offset.length()
	var above: float = -offset.y
	var committed: bool = state == State.HUNT
	# Hysteresis: commit inside the stoop range, and stay committed a good way
	# past it, or a hunter flickers between climbing and diving at the boundary.
	# Height is what a stoop spends, so a bird that has bought enough of it can
	# commit from much further out: a stern chase between two birds on the same
	# flight model closes at a metre or two a second, while a dive from forty
	# metres up arrives at fifty.
	var high: bool = above > STOOP_HEIGHT * 2.5
	if distance < STOOP_RANGE and (above > -10.0 or distance < STOOP_RANGE * 0.4):
		_enter(State.HUNT)
	elif high and distance < STOOP_RANGE * 1.7:
		_enter(State.HUNT)
	elif committed and distance < STOOP_RANGE * 1.8:
		_enter(State.HUNT)
	else:
		_enter(State.STALK)


func _give_up_on(quarry: Node3D) -> void:
	_grudge_id = quarry.get_instance_id()
	_grudge_until = _clock + HUNT_GRUDGE
	_hunt_started = 0.0
	_hunt_best_range = INF
	_enter(State.WANDER)
	_pick_new_goal()


## What a bird does when nothing is hunting it and it has nothing to hunt: rest,
## climb, or get on with going somewhere.
func _choose_errand() -> void:
	if _wants_to_roost() and _seek_perch():
		return
	if _lift_here() > SOAR_LIFT and _wants_height():
		_enter(State.SOAR)
		_soar_direction = 1.0 if _rng.randf() < 0.5 else -1.0
		_soar_dry = 0.0
		_core = at()
		_core_lift = _lift_here()
		if flock != null:
			flock.soars += 1


func _wants_to_roost() -> bool:
	if _perch_cooldown > 0.0 or flock == null:
		return false
	# Either tired, or simply due a rest. The second half matters more than the
	# first: birds that only ever landed when they ran out of reserves almost
	# never landed at all, because a bird that is not being chased barely flaps —
	# four landings in four minutes across a flock of twenty-six, which is a sky
	# with 4196 published perch points and nothing sitting on any of them.
	return energy < ROOST_ENERGY or _rest_timer <= 0.0


## A bird climbs when it is low, or when it is tired: height is the reserve it
## can spend without flapping.
func _wants_height() -> bool:
	if world == null:
		return true
	var above: float = at().y - world.height_at(at().x, at().z)
	return above < CRUISE_CEILING or energy < RESTED_ENERGY


func _lift_here() -> float:
	return _wind.y


## What the air is doing here, re-measured ten times a second rather than ninety.
##
## [method WorldBuilder.wind_at] walks forty-four thermals and takes five terrain
## samples for the ridge term; at ninety hertz times twenty-six birds that is the
## single most expensive thing the flock does, and it is measuring a field that
## varies over tens of metres. A bird covers two metres between samples.
func _sample_air() -> void:
	_wind_timer -= _last_delta
	if _wind_timer > 0.0:
		return
	_wind_timer = WIND_INTERVAL
	_wind = world.wind_at(at()) if world != null else Vector3.ZERO


## The one thing this bird is currently interested in, out of what the manager
## told it about and what it can see for itself. A threat always wins: a bird
## that kept hunting while something stooped on it would look stupid exactly
## when the player is watching most closely.
func _interest() -> Node3D:
	var best: Node3D = null
	var best_rank: int = 0
	var best_distance: float = INF
	for entry: Variant in [target, rival]:
		# Checked before the typed assignment: handing a freed instance to a
		# typed variable is itself an error in GDScript, and either of these two
		# can have been eaten since the last time anybody looked.
		if entry == null or not is_instance_valid(entry):
			continue
		var candidate: Node3D = entry
		if candidate == self:
			continue
		var distance: float = at().distance_to(_position_of(candidate))
		# The flock has already applied its own ranges to [member rival], memory
		# included; this cutoff is for whatever the manager handed over. Applying
		# both used to drop a quarry the flock was still tracking, three seconds
		# into every stalk.
		if candidate == target and distance > SENSE_RADIUS * 1.4:
			continue
		var other: float = _size_of(candidate)
		var rank: int = 0
		if GameRules.can_catch(other, size):
			rank = 2
		elif GameRules.can_catch(size, other):
			if candidate.get_instance_id() == _grudge_id and _clock < _grudge_until:
				continue
			# A bird with nothing left in the tank does not start a chase. It is
			# also what keeps an exhausted bird's roost from being cancelled by
			# every finch that happens past.
			if energy < ROOST_ENERGY:
				continue
			rank = 1
		else:
			continue
		if rank > best_rank or (rank == best_rank and distance < best_distance):
			best = candidate
			best_rank = rank
			best_distance = distance
	return best


func _is_threat(other: Node3D) -> bool:
	return GameRules.can_catch(_size_of(other), size)


func _enter(next: State) -> void:
	if state == next:
		return
	if state == State.LAND and next != State.PERCH:
		_abandon_perch()
	state = next
	_state_timer = 0.0


static func _size_of(node: Node3D) -> float:
	if node is BirdPlayer:
		return (node as BirdPlayer).size
	if node is BirdNPC:
		return (node as BirdNPC).size
	return 1.0


## Where another bird — or the player — is. [method at] is a [BirdNPC] method
## and the player is not one, so anything that can be either goes through here.
static func _position_of(node: Node3D) -> Vector3:
	if node is BirdNPC:
		return (node as BirdNPC).at()
	return node.global_position


static func _velocity_of(node: Node3D) -> Vector3:
	if node is BirdPlayer:
		return (node as BirdPlayer).model.velocity
	if node is BirdNPC:
		return (node as BirdNPC).model.velocity
	return Vector3.ZERO


# --- where to go ------------------------------------------------------------------

func _pick_new_goal() -> void:
	# Long enough to actually get there. At eight seconds a bird changed its mind
	# three times before crossing its own turning circle, which measured as a
	# flock that never went anywhere: fourteen of twenty-three "went nowhere"
	# reports in the ecosystem run were wanderers zig-zagging on the spot.
	_goal_timer = _rng.randf_range(20.0, 38.0)
	# Somewhere with lift in it, if there is any: birds go where the air goes up,
	# and a flock that visibly converges on the same columns the player is
	# learning to use is the cheapest lesson in the game.
	if world != null and _rng.randf() < 0.45:
		var lifted: Vector3 = _best_lift_nearby()
		if lifted.is_finite():
			_goal = lifted
			return
	var angle: float = _rng.randf() * TAU
	# The arena is 620 m of bowl inside a rim wall. Wandering inside 380 m of the
	# origin — which is what this used to do — left three districts of a world
	# that the world-building work built with nothing in them.
	var radius: float = _rng.randf_range(60.0, 520.0)
	var ground: float = world.height_at(cos(angle) * radius, sin(angle) * radius) if world != null else 0.0
	_goal = Vector3(
		cos(angle) * radius,
		ground + _rng.randf_range(70.0, 230.0),
		sin(angle) * radius
	)


## Samples a handful of places a glide away and returns the one with the most
## lift under it, or [constant Vector3.INF] if none of them has any. Cheap
## because it happens once every several seconds per bird, not every frame.
func _best_lift_nearby() -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_lift: float = 0.9
	for i in 6:
		var angle: float = _rng.randf() * TAU
		var distance: float = _rng.randf_range(70.0, 300.0)
		var x: float = at().x + cos(angle) * distance
		var z: float = at().z + sin(angle) * distance
		var y: float = maxf(at().y, world.height_at(x, z) + 70.0)
		var sample := Vector3(x, y, z)
		var lift: float = world.wind_at(sample).y
		if lift > best_lift:
			best_lift = lift
			best = sample
	return best


## Lead pursuit: aim where the quarry will be, not where it is. Without this a
## hunter flies a pure pursuit curve, arrives behind and outside the turn, and
## converts nothing.
func _intercept() -> Vector3:
	var quarry: Node3D = _focus
	if quarry == null or not is_instance_valid(quarry):
		return _goal
	var offset: Vector3 = _position_of(quarry) - at()
	var closing: float = maxf(model.velocity.length(), 8.0)
	var lead: float = clampf(offset.length() / closing, 0.0, 2.5)
	var aim: Vector3 = _position_of(quarry) + _velocity_of(quarry) * lead
	# A committed hunter never asks for much of a climb. Matching the quarry's
	# altitude from below means pitching up, and pitching up means arriving slow:
	# the chase turned into a series of zooms, each one further behind than the
	# last. Close the ground first and spend the last few metres of height on the
	# strike itself.
	aim.y = minf(aim.y, at().y + INTERCEPT_CLIMB)
	return aim


## Above and behind. The point of a stalk is to arrive with height already
## bought and to spend the approach outside the range at which prey looks up.
func _stalking_point() -> Vector3:
	var quarry: Node3D = _focus
	if quarry == null or not is_instance_valid(quarry):
		return _goal
	var motion: Vector3 = _velocity_of(quarry)
	var behind := Vector3(0.0, 0.0, 1.0)
	if motion.length_squared() > 1.0:
		behind = -motion.normalized()
	behind.y = 0.0
	if behind.length_squared() < 0.01:
		behind = Vector3(0.0, 0.0, 1.0)
	var quarry_at: Vector3 = _position_of(quarry)
	# Height it already has is height it does not have to buy. The stalk asks for
	# a band above the quarry, not a ceiling: a hunter told to sit sixty metres
	# up climbed for the whole chase, spent two thirds of its reserves doing it
	# and never closed a metre. Get into the band, then close.
	var ceiling: float = quarry_at.y + STALK_HEIGHT * clampf(size, 0.8, 1.3)
	# Climb to the perch above it, and never dive back down out of one it has
	# already got: height is the only thing a stalk is for. Clamping the goal to
	# the bird's own altitude instead — "height it already has is height it does
	# not have to buy" — sounded right and stopped every stalk dead thirteen
	# metres above its quarry, which is not enough to dive with.
	var height: float = maxf(at().y, ceiling)
	var point: Vector3 = quarry_at + behind.normalized() * STALK_TRAIL
	point.y = height
	return point


## Down and away, and not in a straight line.
##
## The old escape was "away plus twenty-five metres of climb", which is what a
## bird with free wingbeats does and what made prey uncatchable: it rowed uphill
## faster than anything could follow. Diving is free, terrain hides you, and
## [method Flock.has_sight] means hiding actually works.
func _escape_point(delta: float) -> Vector3:
	var threat: Node3D = _focus
	if threat == null or not is_instance_valid(threat):
		return _goal
	var away: Vector3 = at() - _position_of(threat)
	away.y = 0.0
	if away.length_squared() < 1.0:
		away = -model.forward()
	away = away.normalized()

	_jink_timer -= delta
	if _jink_timer <= 0.0:
		_jink_timer = JINK_INTERVAL
		# Pick the escape bearing whose ground rises most: a bird that runs at a
		# ridge can put it between itself and whatever is chasing it.
		_jink = _rng.randf_range(-0.5, 0.5)
		if world != null:
			var best: float = -INF
			for turn: float in [-0.7, -0.25, 0.25, 0.7]:
				var bearing: Vector3 = away.rotated(Vector3.UP, turn)
				var probe: Vector3 = at() + bearing * FLEE_DISTANCE
				var relief: float = world.height_at(probe.x, probe.z)
				if relief > best:
					best = relief
					_jink = turn
	var heading: Vector3 = away.rotated(Vector3.UP, _jink)
	var goal: Vector3 = at() + heading * FLEE_DISTANCE
	if world != null:
		goal.y = world.height_at(goal.x, goal.z) + FLEE_CLEARANCE * clampf(size, 0.6, 2.5)
	else:
		goal.y = at().y - 30.0
	return goal


## Crowding, as an offset to whatever this bird was aiming at, plus a weak pull
## toward its own kind. Avoidance has to be expressed as a place to fly, not as
## a nudge to the velocity — a bird that sidesteps is a bird that cheated.
func _crowding() -> Vector3:
	if flock == null:
		return Vector3.ZERO
	# Two spatial queries per bird per frame is 4700 lookups a second across the
	# flock, for a steering nudge that is measured in tens of metres. Ten hertz
	# is plenty and costs a ninth as much; the goal it modifies only changes
	# every few seconds anyway.
	_crowd_timer -= _last_delta
	if _crowd_timer > 0.0:
		return _crowd
	_crowd_timer = CROWD_INTERVAL
	_crowd = flock.crowding(self)
	if state == State.WANDER or state == State.SOAR:
		var centre: Vector3 = flock.peer_centre(self)
		if centre.is_finite():
			var toward: Vector3 = centre - at()
			# Only from far enough out that it never fights the separation term.
			if toward.length() > 45.0:
				_crowd += toward.normalized() * 18.0
	return _crowd


# --- flying -----------------------------------------------------------------------

func _steer_toward(goal: Vector3, delta: float) -> void:
	var offset: Vector3 = goal - at()
	var horizontal := Vector2(offset.x, offset.z)
	if horizontal.length_squared() < 1.0:
		horizontal = Vector2(0.0, -1.0)

	# Bank toward the target: how far off the nose it is becomes roll command.
	var desired_heading: float = atan2(-horizontal.x, -horizontal.y)
	var error: float = wrapf(desired_heading - model.heading, -PI, PI)
	command.bank = clampf(-error * 1.5, -1.15, 1.15)

	# Climb by raising the nose; dive by lowering it. Held short of the stall,
	# because an AI that stalls itself into the ground is not a threat.
	var height_error: float = offset.y
	var pitch: float = clampf(height_error / 45.0, -1.0, 1.0)
	# Do not climb yourself to a standstill. Nose-up authority is faded out as
	# the airspeed falls toward trim, because the flight model will happily let a
	# bird stand on its tail: a stalking hunter asked for thirty metres of height
	# pitched up until it was doing 3.6 m/s, mushed, and watched its quarry sail
	# away. Wandering birds did the same thing more quietly — most of the flock's
	# "going nowhere" reports were birds hanging off a climb they could not fly.
	if pitch > 0.0:
		var trim: float = model.trim_speed()
		pitch *= clampf(
			(model.velocity.length() - trim * 0.92) / maxf(trim * 0.35, 0.001), 0.0, 1.0
		)
	var alpha: float = model.alpha_trim + pitch * model.alpha_range
	if state == State.LAND:
		alpha = _flare_alpha(horizontal.length(), height_error)
	command.alpha = clampf(alpha, -model.alpha_range, model.alpha_stall * 0.92)
	command.span = _span_for(height_error)
	_update_effort(height_error, delta)


## Wings are the throttle. A tuck buys speed and costs turn; a spread buys turn
## and costs speed. Which one a bird wants is entirely a function of what it is
## doing, which is why this is a state machine and not a constant.
func _span_for(height_error: float) -> float:
	match state:
		State.HUNT:
			# The stoop. Only worth tucking with height to spend.
			return 0.32 if height_error < -STOOP_HEIGHT else 1.0
		State.FLEE:
			return 0.45 if height_error < -18.0 else 1.0
		State.LAND:
			return 1.0
		State.STALK:
			return 1.0
		_:
			return 0.28 if height_error < -60.0 else 1.0


## Angle of attack on final approach. A bird lands by trading every last metre
## per second for a moment of hanging still — the flare — and it cannot start
## that from two hundred metres out or it stalls into the trees.
func _flare_alpha(range_out: float, height_error: float) -> float:
	var descent: float = clampf(height_error / 30.0, -1.0, 1.0)
	var cruise: float = model.alpha_trim + descent * model.alpha_range * 0.8
	var flare: float = clampf(1.0 - range_out / 28.0, 0.0, 1.0)
	return lerpf(cruise, model.alpha_stall * 0.9, flare)


## Flapping is rhythmic and only when it is needed — birds that beat their wings
## constantly look like insects — and it is now also rationed. A bird out of
## reserves cannot flap at all, which is the whole reason a chase ends.
func _update_effort(height_error: float, delta: float) -> void:
	var strength: float = clampf(energy / TIRED_ENERGY, 0.0, 1.0)
	var slow: bool = model.velocity.length() < model.trim_speed() * 0.95
	# Height that the air is already providing is height not worth paying for.
	var wants_height: bool = height_error > 8.0 and command.wind.y < 1.2
	var urgent: bool = state == State.FLEE or state == State.HUNT or _launch_timer > 0.0
	var should_flap: bool = (slow or wants_height or _launch_timer > 0.0) \
		and command.span > 0.5 and strength > 0.02
	# Nothing flaps on a stoop or a landing approach: a diving bird has all the
	# speed it needs, and a flapping bird cannot slow down.
	if state == State.HUNT and height_error < -STOOP_HEIGHT:
		should_flap = false
	if state == State.LAND and height_error < 4.0:
		should_flap = false

	if not should_flap:
		command.stroke_speed = 0.0
		_flap_phase = 0.0
		_working = false
		return

	var period: float = 0.55 if urgent else 0.8
	_flap_phase = fmod(_flap_phase + delta, period)
	var downstroke: bool = _flap_phase < period * 0.45
	command.stroke_speed = ((3.2 if urgent else 2.4) * strength) if downstroke else 0.0
	# Charged for the whole cycle, not only the half of it that pushes. A bird is
	# working just as hard picking its wings back up, and billing only the
	# downstroke made twenty seconds of climbing cost a quarter of a tank.
	_working = true
	_effort = 1.0 if urgent else 0.72


## Reserves in and out. Flapping is the only thing that spends them; gliding,
## lift and a branch are the three ways to get them back — in that order of
## generosity, which is exactly the order the game wants birds to prefer.
func _spend_energy(delta: float) -> void:
	var change: float = -FLAP_DRAIN * _effort if _working else GLIDE_RECOVER
	if not _working and command.wind.y > 1.0:
		change += LIFT_RECOVER
	energy = clampf(energy + change * delta, 0.0, 1.0)


## Circling. Held bank, no flapping, nose a little up: the same technique a
## glider pilot uses and the same one the player can copy, which is the point of
## making it visible.
func _steer_soaring(delta: float) -> void:
	var lift: float = _lift_here()
	_soar_dry = 0.0 if lift > SOAR_LOST_LIFT else _soar_dry + delta

	# Remember where the lift was best and go back to it when the circle falls
	# out of the side of the core. This is the whole of thermalling technique:
	# nobody centres a thermal first time, and a bird that gave up the moment it
	# lost the core climbed thirteen metres in a minute where the same bird
	# working the core climbs sixty.
	_core_lift = maxf(_core_lift - delta * 0.6, 0.0)
	if lift > _core_lift:
		_core_lift = lift
		_core = at()
	if lift < _core_lift * 0.5 and _core_lift > SOAR_LOST_LIFT \
			and at().distance_to(_core) > 14.0:
		_steer_toward(_core + Vector3.UP * 8.0, delta)
		command.stroke_speed = 0.0
		_working = false
		_spend_energy(delta)
		return

	command.span = 1.0
	command.stroke_speed = 0.0
	_working = false
	command.alpha = clampf(
		model.alpha_trim + SOAR_ALPHA, -model.alpha_range, model.alpha_stall * 0.92
	)
	# Weak lift means the edge of the core, and the answer to the edge is to turn
	# harder, not to open the circle out. The first version of this had it the
	# wrong way round — bank fell from 0.66 to 0.23 as the lift faded, which flew
	# the bird straight out of the thermal it was trying to stay in.
	var tighten: float = clampf(1.35 - lift * 0.09, 0.85, 1.35)
	command.bank = clampf(
		SOAR_BANK * tighten, 0.45, 0.95
	) * _soar_direction
	_spend_energy(delta)

	if _soar_dry > SOAR_PATIENCE or _state_timer > SOAR_TIMEOUT or not _wants_height():
		_enter(State.WANDER)
		_pick_new_goal()


func _avoid_ground() -> void:
	if world == null:
		return
	var ground: float = world.height_at(at().x, at().z)
	var clearance: float = 3.0 * size
	# A bird on final approach is *supposed* to be near the ground. Without this
	# exemption the clearance rule holds it above the branch it is aiming at and
	# it circles the same tree until it gives up.
	if state == State.LAND and at().distance_to(_goal) < 60.0:
		clearance = 0.0
	if at().y < ground + clearance:
		position.y = ground + clearance
		# Bounce the flight path upward rather than teleporting silently, so it
		# reads as a bird skimming a hillside.
		model.velocity.y = maxf(model.velocity.y, 4.0)


# --- perching -----------------------------------------------------------------------

## Claims somewhere to sit, taking it off a smaller bird if the only free branch
## in reach is one somebody else is already on. Returns whether it found one.
func _seek_perch() -> bool:
	if flock == null:
		return false
	# Birds roost where other birds are roosting, which means the good branches
	# are the taken ones. A third of the time this bird goes for one anyway.
	var index: int = _contested_perch() if _rng.randf() < 0.33 else -1
	if index < 0:
		index = flock.find_perch(self, _rng)
		if index < 0:
			index = _contested_perch()
		if index < 0:
			_perch_cooldown = 6.0
			return false
		if not flock.claim(self, index):
			return false
	_perch_index = index
	_enter(State.LAND)
	return true


## The nearest perch worth taking off somebody, or -1.
##
## Only from a bird this one is bigger than but cannot eat. If it could eat it
## there would be no squabble, only a meal — and the roost would have emptied
## itself already, because anything that eats birds flushes a perch from
## [constant FLUSH_RADIUS] away.
func _contested_perch() -> int:
	if flock == null or world == null:
		return -1
	var best: int = -1
	var best_distance: float = SQUABBLE_RADIUS
	for other: BirdNPC in flock.near(at(), SQUABBLE_RADIUS):
		if other == self or other.state != State.PERCH or other._perch_index < 0:
			continue
		if not Flock.outranks(self, other):
			continue
		var distance: float = at().distance_to(other.at())
		if distance < best_distance:
			best_distance = distance
			best = other._perch_index
	if best >= 0 and flock.challenge(self, best):
		return best
	return -1


func _approach_point() -> Vector3:
	if flock == null or _perch_index < 0:
		_enter(State.WANDER)
		return _goal
	var point: Vector3 = flock.perch_position(_perch_index)
	var offset: Vector3 = point - at()
	if offset.length() > 60.0:
		# Set up above the perch first; a bird arriving low has to climb back up
		# to it and cannot land from underneath.
		return point + Vector3.UP * (18.0 + 6.0 * size)
	return point


func _continue_landing() -> void:
	if flock == null or _perch_index < 0:
		_enter(State.WANDER)
		return
	var point: Vector3 = flock.perch_position(_perch_index)
	if at().distance_to(point) < LAND_RADIUS + size:
		_land_on(point)
		return
	if _state_timer > LAND_TIMEOUT:
		if flock != null:
			flock.giveups += 1
		_abandon_perch()
		_perch_cooldown = 10.0
		_enter(State.WANDER)
		_pick_new_goal()


func _land_on(point: Vector3) -> void:
	state = State.PERCH
	_state_timer = 0.0
	position = point + Vector3.UP * (PERCH_LIFT * size)
	model.velocity = Vector3.ZERO
	model.bank = 0.0
	_perch_timer = _rng.randf_range(PERCH_REST_MIN, PERCH_REST_MAX)
	command.span = 0.2
	command.stroke_speed = 0.0
	if flock != null:
		flock.landings += 1
		# Everything smaller sharing this branch gets up. See
		# [method Flock.flush_neighbours].
		flock.flush_neighbours(self, SQUABBLE_TOUCH)


func _abandon_perch() -> void:
	if flock != null:
		flock.release(self)
	_perch_index = -1


func _process_perched(delta: float) -> void:
	energy = clampf(energy + ROOST_RECOVER * delta, 0.0, 1.0)
	model.velocity = Vector3.ZERO
	_perch_timer -= delta
	_perched_pose(delta)

	# Anything that eats birds, arriving anywhere near a roost, empties it. This
	# is the most visible thing the AI does: fly at a tree and it comes apart.
	var interest: Node3D = _interest()
	if interest != null and _is_threat(interest) \
			and at().distance_to(_position_of(interest)) < FLUSH_RADIUS:
		_launch()
		return
	if _perch_timer <= 0.0 and energy > RESTED_ENERGY:
		_launch()


## Off the branch. A bird leaves a perch with a couple of hard beats and almost
## no speed, which the flight model is perfectly happy to fly out of — see
## [code]_test_flapping_climbs_from_a_standstill[/code].
func _launch() -> void:
	_abandon_perch()
	state = State.WANDER
	_state_timer = 0.0
	_perch_cooldown = PERCH_COOLDOWN
	_rest_timer = _rng.randf_range(50.0, 140.0)
	_launch_timer = 3.5
	if flock != null:
		flock.takeoffs += 1
	model.bank = 0.0
	model.velocity = model.forward() * 5.0 + Vector3.UP * 3.0
	_pick_new_goal()


## Thrown off a branch by something bigger. Same departure, but it does not get
## to count as a rest and it goes looking again sooner.
func displace() -> void:
	if state != State.PERCH and state != State.LAND:
		return
	_launch()
	_perch_cooldown = 6.0
	energy = maxf(energy, 0.25)


## Sit down here, wherever here is. Kept as the public verb; the AI's own
## roosting goes through [method _seek_perch] so that the branch is claimed.
func perch_here() -> void:
	state = State.PERCH
	_state_timer = 0.0
	model.velocity = Vector3.ZERO
	_perch_timer = _rng.randf_range(PERCH_REST_MIN, PERCH_REST_MAX)


## Back into the air, wherever the caller has just put this bird. A recycled or
## restarted bird that was sitting on a branch four hundred metres away would
## otherwise still be sitting — in mid-air, at its new position, holding a claim
## on a twig it can no longer see.
func rejoin() -> void:
	_abandon_perch()
	state = State.WANDER
	_state_timer = 0.0
	_perch_cooldown = PERCH_COOLDOWN
	target = null
	rival = null
	_focus = null
	energy = maxf(energy, 0.6)
	model.bank = 0.0
	model.velocity = model.forward() * model.trim_speed()
	_pick_new_goal()


func devour(prey_size: float) -> void:
	# Same growth rule the player uses, so the leaderboard means something.
	set_size(GameRules.grown_size(size, prey_size))
	# A meal is worth a rest as well as a size: it is the only thing in the world
	# that gives energy back without costing time on a branch.
	energy = clampf(energy + 0.35, 0.0, 1.0)


func die() -> void:
	if flock != null:
		flock.remove(self)
	died.emit(self)
	queue_free()


# --- looking like it --------------------------------------------------------------

func _update_pose(delta: float) -> void:
	if _body == null or _rig == null:
		return
	var forward: Vector3 = model.velocity
	if forward.length_squared() > 1.0:
		var direction: Vector3 = forward.normalized()
		# In a vertical dive or climb the world up-vector is useless as a
		# reference, so fall back on the bird's own heading.
		var up: Vector3 = Vector3.UP
		if absf(direction.dot(Vector3.UP)) > 0.99:
			up = model.forward()
		var target_basis := Basis.looking_at(direction, up)
		# Roll the model with the bank so the turn is visible from outside.
		target_basis = target_basis.rotated(direction, -model.bank)
		_body.global_basis = _body.global_basis.slerp(
			target_basis, clampf(delta * 8.0, 0.0, 1.0)
		)

	# Everything below the body — the beat, the fold, the tail — comes straight
	# out of the same command the flight model was just stepped with, so what the
	# bird looks like it is doing is what it is doing.
	_rig.animate(
		command.stroke_speed, command.span, model.bank,
		command.alpha, model.alpha_trim, delta
	)


## A perched bird stands level and folds its wings. Without this it keeps
## whatever attitude it happened to land in — a 40-degree bank, usually — and a
## roost full of birds leaning over sideways looks like a bug, because it is one.
func _perched_pose(delta: float) -> void:
	if _body == null or _rig == null:
		return
	# Level, then nose-up: a bird that keeps its gliding attitude on a branch
	# reads as a dart stuck in a tree, which is exactly what the first roost
	# screenshot showed. The pitch and the folded wings are the whole difference
	# between "perched" and "crashed".
	var level := Basis.looking_at(model.forward(), Vector3.UP)
	level = level.rotated(level.x.normalized(), PERCH_PITCH)
	_body.global_basis = _body.global_basis.slerp(level, clampf(delta * 3.0, 0.0, 1.0))
	# Wings shut and the tail hanging: [BirdPose] takes both from the flight
	# command, so a perched bird is posed by handing it the command a perched
	# bird would be flying if it were flying.
	_rig.animate(0.0, 0.1, 0.0, model.alpha_trim + 0.5, model.alpha_trim, delta)
