class_name GameManager
extends Node

## Runs the chase: keeps the sky populated and escalating, tells birds what to
## look at, resolves catches, and owns the run.
##
## The rules themselves live in [GameRules] and [Progression] and the run's state
## in [GameSession] — all three are plain objects with no scene, which is what
## lets a whole session be simulated headlessly. This is the part that genuinely
## needs a scene tree.

signal score_changed(score: int)
signal player_caught_bird(prey_size: float)
signal player_was_caught(by_size: float)

## Everything that happens to the player as a run unfolds, on one channel:
## [code]&"catch"[/code], [code]&"caught"[/code], [code]&"rank_up"[/code],
## [code]&"rank_down"[/code], [code]&"ended"[/code], [code]&"restart_ready"[/code],
## [code]&"restart"[/code]. One signal rather than seven because the three things
## that react to a catch — the HUD banner, the wingbeat synth and the haptics —
## all want the same event, and a game that grows a signal per event grows a
## rewiring job per event too.
signal event_occurred(kind: StringName, payload: Dictionary)

const FLOCK_SIZE: int = 26
const SPAWN_MIN_DISTANCE: float = 140.0
const SPAWN_MAX_DISTANCE: float = 420.0

## Where birds you can eat are put, and what fraction of them go there.
##
## Everything used to spawn between 140 m and 420 m, and at 140 m a bird your own
## size is about a degree wide — a speck with no silhouette, no wingbeat you can
## see and no size you can judge. That is the central subject of the game, and
## every wide shot of it proved the point: an empty sky. Birds are only readable
## as birds inside about eighty metres, and only readable as [i]a size[/i] inside
## about forty.
##
## So the sky is now two tiers. Prey and peers — everything that cannot hurt you
## — are dealt into a near band you can actually see, which is also the band the
## hunting rules were tuned for (prey notices a threat at 40 m and a hunter picks
## out a meal at 55 m, so a meal at 60 m is a chase that starts immediately
## rather than a two-minute commute). Predators keep the far band, because
## something that can eat you arriving forty metres off your wing with no warning
## is not a threat, it is an ambush you could not have avoided.
const NEAR_MIN_DISTANCE: float = 55.0
const NEAR_MAX_DISTANCE: float = 190.0
## How much of the harmless half of the sky is dealt near. Not all of it: a flock
## that is entirely within a hundred metres has no depth and nothing to fly
## towards.
const NEAR_SHARE: float = 0.62
## How often birds re-evaluate who they are interested in. Every frame would be
## wasteful and would also make them twitch between targets.
const RETARGET_INTERVAL: float = 0.4

## How close something bigger has to be before a bird notices it, as opposed to
## the full [constant BirdNPC.SENSE_RADIUS] at which it notices something smaller.
##
## This asymmetry is the single change that made hunting possible at all. Every
## bird in this game flies the same [FlightModel], so a stern chase between two
## birds closes at the four percent of speed that separates their sizes: with
## prey that bolted the instant it came within 95 m, an autopilot flying straight
## at the nearest meal caught [b]nothing in ten minutes[/b] ([SessionProbe] with
## the old value: five chases, closest approach 31 m). Giving prey a short
## reaction range turns hunting into what it should be — approach unseen, then
## stoop — and makes the last forty metres the contest instead of the first
## hundred and fifty.
const THREAT_NOTICE_RADIUS: float = 40.0
## How far off a bird picks out something it could eat. Shorter than the AI's own
## [constant BirdNPC.SENSE_RADIUS] because that radius is what a predator uses on
## the player, and at 95 m with three predators in the sky a well-flown, evading
## autopilot was still being killed every two minutes — faster than any hunter
## can grow.
const HUNT_NOTICE_RADIUS: float = 55.0
## How much further a bird keeps watching a threat it has already broken cover
## from, as a multiple of the notice radius. Some memory is needed or prey
## flickers in and out of fleeing every time it gains a metre; too much and a
## single sighting means the chase is over, because a bird that flees forever
## cannot be caught by a bird that flies the same model.
const FLEE_MEMORY: float = 1.6

## Seconds a bird will run from one particular threat before it has to stop, and
## seconds before that same threat can frighten it again.
##
## This is a stamina rule, and without it the game has no hunting in it at all.
## An NPC flees by climbing while beating its wings flat out; its wingbeat costs
## it nothing, while the player's costs a real arm and is gated to about one beat
## a second by [WingInput]. [SessionProbe] measured the result exactly: seven
## chases, every one broken off with the hunter 20-37 m [i]below[/i] its prey and
## down at 6-14 m/s, mushing along behind a bird rowing away uphill. Nobody
## wearing a headset is ever going to win that.
##
## A panic burst that runs out turns it into a game with a technique: you cannot
## out-fly a frightened bird, so break off, spend the height you have on speed,
## and be back before it settles. The refractory period is what makes the second
## pass the good one.
const FLEE_STAMINA: float = 3.5
const FLEE_REFRACTORY: float = 6.0

## The same rule from the other side: how long a bird will pursue one particular
## meal, and how long before it will take an interest in that one again.
##
## Hunting had no stamina at all until [SessionProbe] measured what that costs
## the player. A predator that spotted you at 95 m pursued until you were 133 m
## clear, and with four or five of them in the sky an autopilot that evaded
## properly spent [b]29 percent of a ten-minute run running away[/b] — it never
## died, and it also only caught three birds. Unwinnable in the other direction.
## A predator that commits hard for twelve seconds and then breaks off is far
## more frightening and leaves a run in it.
const HUNT_STAMINA: float = 8.0
const HUNT_REFRACTORY: float = 8.0

## The sky is never allowed to run out of things you can eat, nor — while
## anything big enough to eat you can still exist — out of things that can.
## Without these floors the escalation curve is a distribution and nothing more:
## an unlucky minute leaves a player circling an empty sky, which is the one
## failure mode that makes an agar.io loop feel broken rather than hard.
const MIN_PREY_IN_SKY: int = 7
const MIN_PREDATORS_IN_SKY: int = 1

## Nothing further away than this can possibly be a strike, whatever the sizes
## and speeds involved — a cheap square-distance reject before the real test.
const STRIKE_RANGE_SQUARED: float = 40.0 * 40.0

## Seconds after being caught during which nothing hunts the player. Being eaten
## puts you back in the air 90 m away, winded, in a sky that had just decided you
## were lunch; without this the flock simply finished the job, and the probe
## measured deaths arriving in pairs seconds apart.
const RESPAWN_GRACE: float = 9.0

## Seconds after a run ends before a wingbeat starts the next one. Long enough
## that the flap which killed you cannot skip the summary you earned.
const RESTART_ARM_DELAY: float = 3.0

var player: BirdPlayer
var world: WorldBuilder
var birds: Array[BirdNPC] = []
var session := GameSession.new()
## The flock's own senses: who can see whom, who has claimed which branch, and
## who ate whom. Everything in here works with no player in the world at all,
## which is what lets `tests/ecosystem.gd` run the sky headlessly. This manager
## owns the run and the player's part in it; [Flock] owns the birds' part in
## each other.
var flock := Flock.new()

## Where the player stands among everything in the sky, 1 = biggest bird alive.
## The one number that turns "size 3.4" into a position in a pecking order.
var standing: int = 1
var standing_total: int = 1

var _rng := RandomNumberGenerator.new()
var _retarget_timer: float = 0.0
var _next_seed: int = 1
var _end_timer: float = 0.0
var _restart_armed: bool = false
## Seconds since the manager started, used to time panic bursts. Kept separately
## from [member GameSession.elapsed] because the flock goes on being frightened
## of things after a run has ended.
var _clock: float = 0.0
## Time until the flock is allowed to take an interest in the player again.
var _grace: float = 0.0
## Bird instance id -> {threat instance id, time its panic runs out}.
var _panic: Dictionary = {}


## Score of the current run. Kept as a read-only view of the session so that the
## flight probe and the HUD, which both ask the manager, cannot disagree with the
## run about what the score is.
var score: int:
	get:
		return session.score


func setup(player_ref: BirdPlayer, world_ref: WorldBuilder) -> void:
	player = player_ref
	world = world_ref
	flock.world = world
	_rng.seed = world.world_seed ^ 0x5EED
	player.set_size(Progression.START_SIZE)
	session.begin(player.size)
	session.rank_changed.connect(_on_rank_changed)
	session.score_changed.connect(func(value: int) -> void: score_changed.emit(value))
	session.ended.connect(_on_session_ended)
	for i in FLOCK_SIZE:
		_spawn_bird()
	_enforce_variety()


func _physics_process(delta: float) -> void:
	if player == null:
		return
	player.wind = world.wind_at(player.global_position)
	_clock += delta
	_grace = maxf(0.0, _grace - delta)
	session.tick(delta, player.size)
	# The flock senses on its own clock, and about each other only: this manager
	# is the only thing in the game that knows the player exists.
	flock.tick(delta)

	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		_retarget_all()
		_update_standing()
		# On the same tick as retargeting rather than every frame: counting the
		# flock twice is cheap, but it is cheap ninety times a second, and the
		# sky does not run out of prey inside four hundred milliseconds.
		if not session.is_over():
			_enforce_variety()

	if session.is_over():
		_process_ended(delta)
	else:
		_resolve_catches()
		_maintain_population()


# --- the run -----------------------------------------------------------------

func _on_rank_changed(index: int, rank_name: String, promoted: bool) -> void:
	event_occurred.emit(
		&"rank_up" if promoted else &"rank_down",
		{"index": index, "name": rank_name, "size": player.size}
	)


func _on_session_ended(won: bool) -> void:
	_end_timer = 0.0
	_restart_armed = false
	event_occurred.emit(&"ended", session.summary())
	print("[Soaring] run over — %s in %s, %d catches, %d deaths, score %d" % [
		session.outcome_title(), GameSession.clock(session.elapsed),
		session.catches, session.deaths, session.score
	])


## A finished run keeps flying — freezing a player mid-air in a headset is a
## good way to make them take it off — but it stops being played. Nothing can
## catch you and you cannot catch anything until a wingbeat starts the next run,
## which reuses the one verb every player already knows instead of hunting for a
## button nobody has been told about.
func _process_ended(delta: float) -> void:
	_end_timer += delta
	if not _restart_armed and _end_timer >= RESTART_ARM_DELAY:
		_restart_armed = true
		event_occurred.emit(&"restart_ready", session.summary())
	if _restart_armed and player.command.stroke_speed > 1.0:
		restart()


## Starts a fresh run: back to the starting size at the spawn point, with a sky
## repopulated around who you are now rather than who you had become.
func restart() -> void:
	session.begin(Progression.START_SIZE)
	player.set_size(Progression.START_SIZE)
	player.respawn()
	_end_timer = 0.0
	_restart_armed = false
	for bird: BirdNPC in birds:
		if is_instance_valid(bird):
			var size: float = _spawn_size()
			bird.position = _spawn_position(size)
			bird.set_size(size)
			# A bird teleported across the map must not still be sitting on the
			# branch it left behind.
			bird.rejoin()
	_enforce_variety()
	_update_standing()
	event_occurred.emit(&"restart", {})
	print("[Soaring] a new run begins")


# --- population --------------------------------------------------------------

## Sizes are drawn around the player's current size and the mix escalates as
## they grow — see [method Progression.threat_mix]. A flat distribution would
## leave a large player with nothing to eat and a small one with nothing but
## predators, and a mix that never moved would make the last rank feel exactly
## like the first.
func _spawn_size() -> float:
	var reference: float = player.size if player != null else Progression.START_SIZE
	return Progression.spawn_size(reference, _rng.randf(), _rng.randf())


func _spawn_size_for_role(role: Progression.Role) -> float:
	var reference: float = player.size if player != null else Progression.START_SIZE
	return Progression.size_for_role(reference, role, _rng.randf())


## Where to put a bird of [param size]. Anything that cannot eat the player may
## be dealt into the near band; anything that can arrives from a distance. See
## [constant NEAR_MIN_DISTANCE].
func _spawn_position(size: float = -1.0) -> Vector3:
	var anchor: Vector3 = player.global_position if player != null else Vector3.ZERO
	var harmless: bool = (
		player == null or size < 0.0 or not GameRules.can_catch(size, player.size)
	)
	var near: bool = harmless and _rng.randf() < NEAR_SHARE
	var angle: float = _rng.randf() * TAU
	var distance: float = (
		_rng.randf_range(NEAR_MIN_DISTANCE, NEAR_MAX_DISTANCE) if near
		else _rng.randf_range(SPAWN_MIN_DISTANCE, SPAWN_MAX_DISTANCE)
	)
	var x: float = anchor.x + cos(angle) * distance
	var z: float = anchor.z + sin(angle) * distance
	var ground: float = world.height_at(x, z)
	# Near birds are placed nearer the player's own height as well as nearer in
	# plan, or half of them are specks against the ground three hundred metres
	# below and the other half are specks against the sky.
	var above: float = (
		clampf(anchor.y - ground, 25.0, 170.0) + _rng.randf_range(-35.0, 45.0) if near
		else _rng.randf_range(40.0, 150.0)
	)
	return Vector3(x, ground + maxf(above, 20.0), z)


## Clear air a short way from where the player was caught, high enough above the
## terrain to have room to start flying again.
func _respawn_position() -> Vector3:
	var anchor: Vector3 = player.global_position
	var angle: float = _rng.randf() * TAU
	var x: float = anchor.x + cos(angle) * 90.0
	var z: float = anchor.z + sin(angle) * 90.0
	return Vector3(x, world.height_at(x, z) + 110.0, z)


func _spawn_bird() -> void:
	var bird := BirdNPC.new()
	_next_seed += 1
	add_child(bird)
	var size: float = _spawn_size()
	bird.configure(size, _spawn_position(size), world, world.world_seed + _next_seed)
	birds.append(bird)
	flock.add(bird)


func count_prey() -> int:
	var total: int = 0
	for bird: BirdNPC in birds:
		if is_instance_valid(bird) and GameRules.can_catch(player.size, bird.size):
			total += 1
	return total


func count_predators() -> int:
	var total: int = 0
	for bird: BirdNPC in birds:
		if is_instance_valid(bird) and GameRules.can_catch(bird.size, player.size):
			total += 1
	return total


## Being caught halves your mass, and that turns every bird that was your equal
## into a predator — one death used to hand the sky four new things that could
## eat you, and the probe measured deaths arriving in threes because of it. You
## respawn ninety metres away, so the sky you wake up in is redrawn around who
## you are now. Birds close enough to see keep their size; a bird that visibly
## shrank while you watched would be a worse lie than the spiral.
func _reseed_distant_flock() -> void:
	for bird: BirdNPC in birds:
		if not is_instance_valid(bird):
			continue
		if bird.global_position.distance_to(player.global_position) > 120.0:
			bird.set_size(_spawn_size())
	_enforce_variety()


## Makes the floors true. Resizes the furthest birds first, because a bird 400 m
## away changing size is invisible and a bird 40 m away doing it is a lie.
func _enforce_variety() -> void:
	if player == null or birds.is_empty():
		return
	_fill_role(Progression.Role.PREY, MIN_PREY_IN_SKY - count_prey())
	if Progression.threat_is_possible(player.size):
		_fill_role(Progression.Role.PREDATOR, MIN_PREDATORS_IN_SKY - count_predators())


func _fill_role(role: Progression.Role, shortfall: int) -> void:
	if shortfall <= 0:
		return
	var ordered: Array[BirdNPC] = birds.duplicate()
	ordered.sort_custom(_further_first)
	for bird: BirdNPC in ordered:
		if shortfall <= 0:
			return
		if not is_instance_valid(bird):
			continue
		var wanted: float = _spawn_size_for_role(role)
		var already: bool = (
			GameRules.can_catch(player.size, bird.size) if role == Progression.Role.PREY
			else GameRules.can_catch(bird.size, player.size)
		)
		if already:
			continue
		bird.set_size(wanted)
		shortfall -= 1


func _further_first(a: BirdNPC, b: BirdNPC) -> bool:
	if not is_instance_valid(a):
		return false
	if not is_instance_valid(b):
		return true
	var origin: Vector3 = player.global_position
	return a.global_position.distance_squared_to(origin) > b.global_position.distance_squared_to(origin)


## Keeps the flock topped up, and quietly recycles birds that have drifted so
## far away that they are no longer part of the game.
func _maintain_population() -> void:
	if player == null:
		return
	for bird: BirdNPC in birds.duplicate():
		if not is_instance_valid(bird):
			birds.erase(bird)
			_panic.erase(bird.get_instance_id())
			continue
		if bird.global_position.distance_to(player.global_position) > SPAWN_MAX_DISTANCE * 1.8:
			var size: float = _spawn_size()
			bird.position = _spawn_position(size)
			bird.set_size(size)
			bird.rejoin()
	while birds.size() < FLOCK_SIZE:
		_spawn_bird()


# --- awareness ---------------------------------------------------------------

## Each bird's view of the player, which is the only thing in the sky this
## manager still speaks for. Bird-versus-bird sight moved into [Flock], where it
## can run with nobody playing; the stamina rules below stay here because they
## were measured against a human being hunted by a flock, not against birds.
## A bird merges the two in [method BirdNPC._interest].
func _retarget_all() -> void:
	if player == null:
		return
	for bird: BirdNPC in birds:
		if not is_instance_valid(bird):
			continue
		bird.target = _player_interest(bird)
		bird.show_threat(player.size)


func _player_interest(bird: BirdNPC) -> Node3D:
	if _grace > 0.0:
		return null
	var distance: float = bird.global_position.distance_to(player.global_position)
	if distance >= BirdNPC.SENSE_RADIUS:
		return null
	# Only care about a player meaningfully bigger or smaller than this bird.
	if GameRules.can_catch(bird.size, player.size) and distance < HUNT_NOTICE_RADIUS \
			and _keeps_hunting(bird, player):
		return player
	if GameRules.can_catch(player.size, bird.size) and _notices_threat(bird, player, distance):
		return player
	return null


## Whether [param bird] is still interested in chasing [param quarry], or has
## run out of patience with it. Shares the panic ledger: a bird is only ever
## doing one of these two things about one other bird at a time.
func _keeps_hunting(bird: BirdNPC, quarry: Node3D) -> bool:
	var id: int = bird.get_instance_id()
	var record: Dictionary = _panic.get(id, {}) as Dictionary
	if int(record.get("hunting", 0)) == quarry.get_instance_id():
		var until: float = float(record.get("hunt_until", 0.0))
		if _clock < until:
			return true
		if _clock < until + HUNT_REFRACTORY:
			return false
	record = record.duplicate()
	record["hunting"] = quarry.get_instance_id()
	record["hunt_until"] = _clock + HUNT_STAMINA
	_panic[id] = record
	return true


## Whether [param bird] is currently frightened of [param threat]: it has to be
## close to notice one, it keeps running a little further than it noticed from,
## and it can only keep it up for so long before it has to settle.
func _notices_threat(bird: BirdNPC, threat: Node3D, distance: float) -> bool:
	var id: int = bird.get_instance_id()
	var panic: Dictionary = _panic.get(id, {}) as Dictionary
	if int(panic.get("threat", 0)) == threat.get_instance_id():
		if _clock < float(panic.get("until", 0.0)):
			return distance < THREAT_NOTICE_RADIUS * FLEE_MEMORY
		if _clock < float(panic.get("until", 0.0)) + FLEE_REFRACTORY:
			return false
	if distance >= THREAT_NOTICE_RADIUS:
		return false
	panic = panic.duplicate()
	panic["threat"] = threat.get_instance_id()
	panic["until"] = _clock + FLEE_STAMINA
	_panic[id] = panic
	return true


## Where the player ranks by size against everything currently in the sky.
func _update_standing() -> void:
	if player == null:
		return
	var above: int = 0
	var total: int = 1
	for bird: BirdNPC in birds:
		if not is_instance_valid(bird):
			continue
		total += 1
		if bird.size > player.size:
			above += 1
	standing = above + 1
	standing_total = total


# --- catches -----------------------------------------------------------------

func _resolve_catches() -> void:
	if player == null:
		return
	# Birds eat each other too, so the flock has its own pecking order and the
	# world keeps moving whether or not the player is involved. Resolved first,
	# and in [Flock], so that it also happens when there is no player at all.
	var eaten: Array[BirdNPC] = flock.resolve_rivalries()

	for bird: BirdNPC in birds:
		if not is_instance_valid(bird) or eaten.has(bird):
			continue
		# Cheap reject first: the strike test is arithmetic, but it is arithmetic
		# times twenty-six birds times ninety frames a second.
		if player.global_position.distance_squared_to(bird.global_position) > STRIKE_RANGE_SQUARED:
			continue
		if GameRules.can_catch(player.size, bird.size) \
				and _strikes(player.global_position, player.model.velocity, player.size, bird):
			eaten.append(bird)
			player.set_size(GameRules.grown_size(player.size, bird.size))
			var gained: int = session.record_catch(bird.size, player.size)
			player_caught_bird.emit(bird.size)
			event_occurred.emit(&"catch", {
				"prey": bird.size, "score": gained, "streak": session.streak,
				"total": session.score, "size": player.size,
			})
		elif GameRules.can_catch(bird.size, player.size) \
				and _strikes(bird.global_position, bird.model.velocity, bird.size, player):
			bird.devour(player.size)
			player.set_size(GameRules.size_after_being_caught(player.size))
			var over: bool = session.record_death(bird.size)
			# Back into the air nearby rather than at some fixed point, so being
			# caught costs you position, mass, your streak and a life — but never
			# the thread of play.
			player.respawn_at(_respawn_position())
			_grace = RESPAWN_GRACE
			_reseed_distant_flock()
			player_was_caught.emit(bird.size)
			event_occurred.emit(&"caught", {
				"by": bird.size, "lives": session.lives, "size": player.size,
				"final": over,
			})
			_enforce_variety()
			break

	for bird: BirdNPC in eaten:
		birds.erase(bird)
		_panic.erase(bird.get_instance_id())
		if is_instance_valid(bird):
			bird.die()


## Whether a hunter at this position, moving this way, is striking [param prey].
func _strikes(position: Vector3, velocity: Vector3, size: float, prey: Node3D) -> bool:
	var prey_size: float = BirdNPC._size_of(prey)
	var prey_velocity: Vector3 = (
		(prey as BirdNPC).model.velocity if prey is BirdNPC else (prey as BirdPlayer).model.velocity
	)
	return GameRules.within_strike(
		position, velocity, size, prey.global_position, prey_velocity, prey_size
	)


## Nearest bird the player can currently eat. Drives the HUD's guidance chevron
## and the hunt probe's autopilot.
func nearest_prey() -> BirdNPC:
	if player == null:
		return null
	var best: BirdNPC = null
	var best_distance: float = INF
	for bird: BirdNPC in birds:
		if not is_instance_valid(bird) or not GameRules.can_catch(player.size, bird.size):
			continue
		var distance: float = player.global_position.distance_to(bird.global_position)
		if distance < best_distance:
			best_distance = distance
			best = bird
	return best
