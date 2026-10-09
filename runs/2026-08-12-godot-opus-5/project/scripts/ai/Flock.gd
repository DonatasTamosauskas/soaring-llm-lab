class_name Flock
extends RefCounted

## What a sky full of birds knows about itself.
##
## [BirdNPC] is one bird's brain: what to do about the thing it is looking at.
## This is the other half — who is looking at whom, who has claimed which twig,
## who is too close to whom, and who just ate whom.
##
## It is deliberately not a [Node] and it knows nothing about the player. That
## is what lets the whole ecosystem be run headlessly with no player, no
## [GameManager] and no scene at all (`tests/ecosystem.gd`), through exactly the
## same code the shipping game runs. An ecosystem you can only observe by
## playing it is an ecosystem nobody can hold to anything.
##
## Everything here is perception and bookkeeping. Nothing in this file moves a
## bird: birds move only by flying, through [FlightModel], which is invariant I4
## and the reason the size/agility tradeoff is legible at all.

# --- perception ---------------------------------------------------------------

## Spatial hash cell, metres. Bigger than the longest query radius so a lookup
## only ever has to visit the nine cells around a point.
const CELL: float = 120.0

## How often the flock re-senses. Every frame is waste — a bird 90 m away has
## not become a different bird in eleven milliseconds — and it also makes birds
## twitch between targets.
const SENSE_INTERVAL: float = 0.3

## How far a bird picks out something it could eat, and how much closer
## something has to be before a bird notices that it is being hunted.
##
## The gap between the two is the stalk. A predator that only ever saw prey at
## the same range prey saw it would announce every chase at maximum distance,
## and a stern chase between two birds flying the same [FlightModel] closes at
## the few percent of speed that separates their sizes — which is to say, never.
## Forty metres of unseen approach is what turns hunting from a tail chase into
## an ambush. The hunting radius is also the flock's predation dial: at 80 m the
## birds ate each other six or seven times a minute, which churned the sky around
## the player faster than the player could finish a chase. The same asymmetry, for the same measured reason, is why
## [constant GameManager.THREAT_NOTICE_RADIUS] is shorter than
## [constant GameManager.HUNT_NOTICE_RADIUS] for the player.
const HUNT_RADIUS: float = 62.0
const THREAT_RADIUS: float = 50.0
## How much further a bird keeps watching something it has already noticed.
const MEMORY: float = 1.7

## How close another bird has to be before this one starts avoiding it, as a
## multiple of the two birds' mean size. Twenty-six birds sharing four thermals
## will otherwise occupy the same cubic metre, which reads as one flickering
## bird rather than as a flock.
const PERSONAL_SPACE: float = 6.0
## Radius of the separation query. Anything further away than this is not
## crowding anybody.
const NEIGHBOUR_RADIUS: float = 70.0

## Points sampled along a line of sight. Terrain is the only occluder — see
## [method has_sight].
const SIGHT_SAMPLES: int = 8
## How far under the sightline the ground has to be to leave it clear.
const SIGHT_CLEARANCE: float = 1.5

# --- perches -------------------------------------------------------------------

## Cell size of the perch index. The world publishes several thousand perch
## points and a bird looking for somewhere to sleep must not walk all of them.
const PERCH_CELL: float = 90.0
## How far a bird will go looking for a roost.
const PERCH_SEARCH: float = 200.0
## How near a known roost a perch has to be to count as part of it, and how much
## being part of one is worth in metres of detour. Birds roost communally: one
## tree with nine birds in it is both what a real roost looks like and the only
## way two birds ever want the same branch.
const ROOST_RADIUS: float = 70.0
const ROOST_PULL: float = 120.0
## How many roosts the flock remembers. A handful, so the sites stay places
## rather than becoming a uniform scatter again.
const ROOST_MEMORY: int = 6
## How many of the nearest free perches to choose between. Picking strictly the
## nearest sends every tired bird in a grove to the same branch and turns the
## squabble rule into a queue.
const PERCH_CHOICES: int = 10

var world: WorldBuilder
var members: Array[BirdNPC] = []

## Emergent statistics, counted as they happen rather than reconstructed. These
## are what `tests/ecosystem.gd` reports and what [AITests] asserts on.
var catches: int = 0
var landings: int = 0
var evictions: int = 0
var soars: int = 0
var takeoffs: int = 0
## Approaches abandoned because the bird could not get down. Some of these are
## healthy — a bird gives up on a branch it cannot reach — but a run where most
## approaches end this way is a landing model that does not work.
var giveups: int = 0

var _cells: Dictionary = {}
var _perch_cells: Dictionary = {}
var _perch_index_built: bool = false
## Perch point index -> instance id of the bird that has claimed it.
var _claims: Dictionary = {}
## Bird instance id -> perch point index. The inverse, so releasing is O(1).
var _held: Dictionary = {}
## Where the flock has taken to sleeping, newest last.
## Narrates every landing. Off in the game; the ecosystem report turns it on.
var debug_landings: bool = false
var _roost_sites: Array[Vector3] = []
var _sense_timer: float = 0.0


func add(bird: BirdNPC) -> void:
	if bird == null or members.has(bird):
		return
	members.append(bird)
	bird.flock = self


func remove(bird: BirdNPC) -> void:
	if bird == null:
		return
	release(bird)
	members.erase(bird)
	# And out of the hash as well. The buckets are only rebuilt every
	# [constant SENSE_INTERVAL], and a bird that has been eaten is freed at the
	# end of the frame — leaving up to three hundred milliseconds in which a
	# lookup would hand somebody a dead bird to steer around.
	var key: Vector2i = _key(bird.at())
	var bucket: Array = _cells.get(key, [])
	bucket.erase(bird)
	_cells[key] = bucket
	if bird.flock == self:
		bird.flock = null


## Re-senses on a fixed tick. [param delta] is real seconds, so a headless sim
## running at ninety simulated hertz senses exactly as often as the game does.
func tick(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	_sense_timer -= delta
	if _sense_timer > 0.0:
		return
	_sense_timer = SENSE_INTERVAL
	_rebuild()
	for entry: Variant in members:
		if is_instance_valid(entry):
			_sense(entry)


# --- the spatial hash ----------------------------------------------------------

func _rebuild() -> void:
	_cells.clear()
	var living: Array[BirdNPC] = []
	for entry: Variant in members:
		if is_instance_valid(entry):
			living.append(entry)
	members = living
	for bird: BirdNPC in members:
		var key: Vector2i = _key(bird.at())
		var bucket: Array = _cells.get(key, [])
		bucket.append(bird)
		_cells[key] = bucket


static func _key(at: Vector3) -> Vector2i:
	return Vector2i(int(floor(at.x / CELL)), int(floor(at.z / CELL)))


## Every member within [param radius] of a point. Birds are spread over a
## kilometre horizontally and a few hundred metres vertically, so the hash is
## flat: only X and Z are bucketed.
func near(at: Vector3, radius: float) -> Array[BirdNPC]:
	var found: Array[BirdNPC] = []
	var reach: int = int(ceil(radius / CELL))
	var centre: Vector2i = _key(at)
	var limit: float = radius * radius
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			var bucket: Array = _cells.get(centre + Vector2i(dx, dz), [])
			for entry: Variant in bucket:
				# Validity is checked before the typed assignment, not after:
				# assigning an already-freed instance to a typed variable is
				# itself the error. A bird eaten this frame is still in the hash
				# until the next rebuild.
				if not is_instance_valid(entry):
					continue
				var other: BirdNPC = entry
				if other.at().distance_squared_to(at) <= limit:
					found.append(other)
	return found


# --- who is looking at whom ----------------------------------------------------

## One bird's senses. The nearest thing that can eat it wins outright over the
## nearest thing it can eat: a bird that kept hunting while something was diving
## on it would look stupid exactly when the player is watching most closely.
func _sense(bird: BirdNPC) -> void:
	var threat: BirdNPC = null
	var threat_distance: float = THREAT_RADIUS
	var prey: BirdNPC = null
	var prey_distance: float = HUNT_RADIUS
	for other: BirdNPC in near(bird.at(), HUNT_RADIUS * MEMORY):
		if other == bird:
			continue
		var distance: float = bird.at().distance_to(other.at())
		# Something already being watched stays watched further out than it would
		# be picked out from cold. Without this a stalk ends the first time the
		# quarry drifts a metre past the notice range, which is most of a second:
		# the hunter set up its climb, lost sight of what it was climbing for and
		# wandered off — measured, before this line existed, in every single run.
		var known: float = MEMORY if bird.rival == other else 1.0
		if GameRules.can_catch(other.size, bird.size):
			if distance < threat_distance * known and _is_closing(other, bird, distance):
				threat = other
				threat_distance = distance
		elif GameRules.can_catch(bird.size, other.size):
			if distance < prey_distance * known:
				prey = other
				prey_distance = distance

	# Sight is only tested on the one candidate that would have won, which keeps
	# the terrain sampling down to a couple of lines a second per bird. The
	# consequence is deliberate: a bird that puts a ridge between itself and its
	# pursuer is not merely harder to catch, it is genuinely lost.
	if threat != null and not has_sight(bird.eye(), threat.eye()):
		threat = null
	if prey != null and not has_sight(bird.eye(), prey.eye()):
		prey = null
	bird.rival = threat if threat != null else prey


## Whether a predator is actually coming this way, as opposed to merely being
## nearby. Birds share thermals and roosts with things that could eat them all
## day long; what empties a roost is something turning toward it. Without this
## test a third of the flock was permanently in flight from a bird that was
## going the other way.
static func _is_closing(threat: BirdNPC, bird: BirdNPC, distance: float) -> bool:
	if distance < 18.0:
		return true
	var toward: Vector3 = bird.at() - threat.at()
	var speed: float = threat.model.velocity.length()
	if speed < 0.5:
		return false
	return threat.model.velocity.dot(toward) / (speed * maxf(distance, 0.001)) > 0.5


## Whether one point can see another. Terrain is the only occluder: it is the
## one piece of world geometry with a cheap analytic height ([method
## WorldBuilder.height_at]) and it is also the interesting one, because it is
## what makes the gorge, the ridges and the rim worth flying into.
##
## Trees and buildings do not block sight. A raycast against them would need a
## physics space, which the headless ecosystem does not have, and 8000 collision
## shapes, which the frame budget does not want.
func has_sight(from: Vector3, to: Vector3) -> bool:
	if world == null:
		return true
	var span: Vector3 = to - from
	var distance: float = span.length()
	if not is_finite(distance) or distance < 1.0:
		return true
	var steps: int = clampi(int(distance / 22.0), 2, SIGHT_SAMPLES)
	for i in range(1, steps):
		var point: Vector3 = from.lerp(to, float(i) / float(steps))
		if world.height_at(point.x, point.z) > point.y + SIGHT_CLEARANCE:
			return false
	return true


## Where this bird is being crowded from, as a direction to steer away in.
## Returned as an offset to add to whatever the bird was already aiming at, so
## avoidance is expressed the only way a bird is allowed to move: by flying
## somewhere slightly different.
func crowding(bird: BirdNPC) -> Vector3:
	var push: Vector3 = Vector3.ZERO
	for other: BirdNPC in near(bird.at(), NEIGHBOUR_RADIUS):
		if other == bird:
			continue
		# Nothing keeps its distance from the thing it is trying to eat, or from
		# the thing trying to eat it. Avoidance is for traffic.
		if GameRules.can_catch(bird.size, other.size) or GameRules.can_catch(other.size, bird.size):
			continue
		var offset: Vector3 = bird.at() - other.at()
		var distance: float = offset.length()
		var space: float = PERSONAL_SPACE * (bird.size + other.size) * 0.5
		if distance > space or distance < 0.001:
			continue
		# Linear falloff, and a nudge upward or downward as well as sideways:
		# two birds on a collision course that only ever dodge horizontally
		# converge again the moment they have passed.
		push += (offset / distance) * (1.0 - distance / space)
	if push.length_squared() < 1e-6:
		return Vector3.ZERO
	return push.normalized() * push.length() * 22.0


## The middle of this bird's own kind — birds neither of which can eat the
## other. Used for a weak cohesion pull, which is what turns "twenty-six birds
## flying separately" into "a few loose parties sharing the same air".
## Returns [constant Vector3.INF] when a bird has no peers nearby to join.
func peer_centre(bird: BirdNPC) -> Vector3:
	var sum: Vector3 = Vector3.ZERO
	var count: int = 0
	for other: BirdNPC in near(bird.at(), NEIGHBOUR_RADIUS):
		if other == bird:
			continue
		if GameRules.can_catch(other.size, bird.size) or GameRules.can_catch(bird.size, other.size):
			continue
		sum += other.at()
		count += 1
	if count == 0:
		return Vector3.INF
	return sum / float(count)


# --- perches -------------------------------------------------------------------

func _build_perch_index() -> void:
	_perch_index_built = true
	if world == null:
		return
	for i in world.perch_points.size():
		var point: Vector3 = world.perch_points[i]
		var key: Vector2i = Vector2i(
			int(floor(point.x / PERCH_CELL)), int(floor(point.z / PERCH_CELL))
		)
		var bucket: Array = _perch_cells.get(key, [])
		bucket.append(i)
		_perch_cells[key] = bucket


## Somewhere free for [param bird] to sit, or -1. Picks at random among the
## nearest few rather than strictly the nearest, so a grove fills up instead of
## a queue forming at one branch.
##
## Perches below the bird are preferred outright: a tired bird gliding down onto
## a branch is a bird landing, and a tired bird clawing its way up to one is a
## bird that did not need to rest.
func find_perch(bird: BirdNPC, rng: RandomNumberGenerator) -> int:
	if world == null or world.perch_points.is_empty():
		return -1
	if not _perch_index_built:
		_build_perch_index()
	var at: Vector3 = bird.at()
	var reach: int = int(ceil(PERCH_SEARCH / PERCH_CELL))
	var centre := Vector2i(int(floor(at.x / PERCH_CELL)), int(floor(at.z / PERCH_CELL)))
	var best: Array[int] = []
	var best_score: Array[float] = []
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			var bucket: Array = _perch_cells.get(centre + Vector2i(dx, dz), [])
			for entry: Variant in bucket:
				var index: int = entry
				if _claims.has(index):
					continue
				var point: Vector3 = world.perch_points[index]
				var distance: float = point.distance_to(at)
				if distance > PERCH_SEARCH:
					continue
				# A perch above the bird costs it a climb it may not have the
				# energy for, so it scores as if it were further away; one at a
				# roost the flock already uses scores as if it were much nearer.
				var score: float = distance + maxf(0.0, point.y - at.y) * 3.0
				if _near_roost(point):
					score -= ROOST_PULL
				var slot: int = best_score.size()
				for i in best_score.size():
					if score < best_score[i]:
						slot = i
						break
				if slot >= PERCH_CHOICES:
					continue
				best.insert(slot, index)
				best_score.insert(slot, score)
				if best.size() > PERCH_CHOICES:
					best.resize(PERCH_CHOICES)
					best_score.resize(PERCH_CHOICES)
	if best.is_empty():
		return -1
	# Birds roost together. Given a choice, take a branch near one that is
	# already taken: it is what real roosts look like from the air, and it is
	# what makes two birds ever want the same twig.
	var sociable: Array[int] = []
	for index: int in best:
		if _neighbour_roost(index) < 40.0:
			sociable.append(index)
	if not sociable.is_empty() and rng.randf() < 0.75:
		return sociable[rng.randi() % sociable.size()]
	return best[rng.randi() % best.size()]


## Whether a point is part of a roost the flock already uses.
func _near_roost(point: Vector3) -> bool:
	for site: Vector3 in _roost_sites:
		if point.distance_to(site) < ROOST_RADIUS:
			return true
	return false


## Remembers where a bird just went to sleep. The first bird to sit somewhere
## makes it a roost; the rest of the flock is drawn to it, and stays drawn to it
## after that bird has gone.
func _remember_roost(point: Vector3) -> void:
	if _near_roost(point):
		return
	_roost_sites.append(point)
	if _roost_sites.size() > ROOST_MEMORY:
		_roost_sites.remove_at(0)


## Distance from a perch to the nearest one somebody has already claimed.
func _neighbour_roost(index: int) -> float:
	var point: Vector3 = world.perch_points[index]
	var nearest: float = INF
	for claimed: int in _claims:
		if claimed == index:
			continue
		nearest = minf(nearest, point.distance_to(world.perch_points[claimed]))
	return nearest


func perch_position(index: int) -> Vector3:
	if world == null or index < 0 or index >= world.perch_points.size():
		return Vector3.ZERO
	return world.perch_points[index]


func claim(bird: BirdNPC, index: int) -> bool:
	if index < 0:
		return false
	var owner_id: int = int(_claims.get(index, 0))
	if owner_id != 0 and owner_id != bird.get_instance_id():
		return false
	release(bird)
	_claims[index] = bird.get_instance_id()
	_held[bird.get_instance_id()] = index
	return true


func release(bird: BirdNPC) -> void:
	var id: int = bird.get_instance_id()
	if not _held.has(id):
		return
	var index: int = int(_held[id])
	if int(_claims.get(index, 0)) == id:
		_claims.erase(index)
	_held.erase(id)


func occupant(index: int) -> BirdNPC:
	var id: int = int(_claims.get(index, 0))
	if id == 0:
		return null
	var node: Object = instance_from_id(id)
	return node as BirdNPC


## Whether one bird gets to push another off a branch: bigger, but not big
## enough to eat it. If it could eat it there would be no argument, only a meal.
static func outranks(bird: BirdNPC, resident: BirdNPC) -> bool:
	return bird.size > resident.size * 1.02 \
		and not GameRules.can_catch(bird.size, resident.size)


## Takes a perch off a smaller bird. This is the squabble: a crow drops onto a
## wire, the jackdaw already sitting on it leaves, and both of those are things
## you can watch happen from three hundred metres up.
func challenge(bird: BirdNPC, index: int) -> bool:
	var resident: BirdNPC = occupant(index)
	if resident == null:
		return claim(bird, index)
	if resident == bird:
		return true
	if not outranks(bird, resident):
		return false
	resident.displace()
	evictions += 1
	return claim(bird, index)


## Everybody smaller than [param bird] sitting within [param radius] of it gets
## up and leaves. Called by a bird as it lands, which is the moment a squabble
## actually happens: roosts are gregarious ([method find_perch] puts birds on
## neighbouring branches on purpose), so a bird coming down on a crowded tree
## lands next to somebody, and the pecking order settles it.
func flush_neighbours(bird: BirdNPC, radius: float) -> void:
	_remember_roost(bird.at())
	if debug_landings:
		var nearest: float = INF
		for other: BirdNPC in members:
			if other != bird and other.state == BirdNPC.State.PERCH:
				nearest = minf(nearest, other.at().distance_to(bird.at()))
		print("[flock] landing size %.2f, nearest roosting bird %.1f m, sites %d" % [
			bird.size, nearest, _roost_sites.size()])
	for other: BirdNPC in near(bird.at(), radius):
		if other == bird or other.state != BirdNPC.State.PERCH:
			continue
		if other.size >= bird.size:
			continue
		other.displace()
		evictions += 1


## Whether anybody is sitting on this perch right now, as opposed to on their
## way to it. Used by the tests and the ecosystem report.
func roosting() -> int:
	var total: int = 0
	for entry: Variant in members:
		if is_instance_valid(entry) and (entry as BirdNPC).state == BirdNPC.State.PERCH:
			total += 1
	return total


# --- the pecking order ---------------------------------------------------------

## Birds eating each other, resolved with exactly the rule the player is judged
## by — [method GameRules.within_strike], the same cone and the same reach.
## Returns everything that was eaten, so the caller can bury it however it
## keeps its own books.
##
## This lives here rather than in [GameManager] so that the flock has a pecking
## order whether or not anybody is playing. It is O(n^2) over the flock, with a
## square-distance reject first; at twenty-six birds that is a few hundred
## comparisons a frame, and past a hundred birds it wants the hash above.
func resolve_rivalries() -> Array[BirdNPC]:
	var eaten: Array[BirdNPC] = []
	for i in members.size():
		if not is_instance_valid(members[i]):
			continue
		var a: BirdNPC = members[i]
		if eaten.has(a):
			continue
		for j in range(i + 1, members.size()):
			if not is_instance_valid(members[j]):
				continue
			var b: BirdNPC = members[j]
			if eaten.has(b):
				continue
			if a.at().distance_squared_to(b.at()) > 1600.0:
				continue
			if GameRules.can_catch(a.size, b.size) and _strikes(a, b):
				a.devour(b.size)
				eaten.append(b)
				catches += 1
			elif GameRules.can_catch(b.size, a.size) and _strikes(b, a):
				b.devour(a.size)
				eaten.append(a)
				catches += 1
				break
	return eaten


static func _strikes(hunter: BirdNPC, prey: BirdNPC) -> bool:
	return GameRules.within_strike(
		hunter.at(), hunter.model.velocity, hunter.size,
		prey.at(), prey.model.velocity, prey.size
	)


func stats() -> Dictionary:
	return {
		"members": members.size(),
		"catches": catches,
		"landings": landings,
		"evictions": evictions,
		"soars": soars,
		"takeoffs": takeoffs,
		"giveups": giveups,
		"roosting": roosting(),
		"claimed": _claims.size(),
		"roosts": _roost_sites.size(),
	}
