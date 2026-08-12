class_name GameManager
extends Node

## Runs the chase: keeps the sky populated, tells birds what to look at, and
## resolves catches. The rules themselves live in [GameRules]; this is the part
## that needs a scene.

signal score_changed(score: int)
signal player_caught_bird(prey_size: float)
signal player_was_caught(by_size: float)

const FLOCK_SIZE: int = 26
const SPAWN_MIN_DISTANCE: float = 140.0
const SPAWN_MAX_DISTANCE: float = 420.0
## How often birds re-evaluate who they are interested in. Every frame would be
## wasteful and would also make them twitch between targets.
const RETARGET_INTERVAL: float = 0.4

var player: BirdPlayer
var world: WorldBuilder
var birds: Array[BirdNPC] = []
var score: int = 0

var _rng := RandomNumberGenerator.new()
var _retarget_timer: float = 0.0
var _next_seed: int = 1


func setup(player_ref: BirdPlayer, world_ref: WorldBuilder) -> void:
	player = player_ref
	world = world_ref
	_rng.seed = world.world_seed ^ 0x5EED
	for i in FLOCK_SIZE:
		_spawn_bird()


func _physics_process(delta: float) -> void:
	if player == null:
		return
	player.wind = world.wind_at(player.global_position)

	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		_retarget_all()

	_resolve_catches()
	_maintain_population()


## Sizes are drawn around the player's current size, so there is always
## something worth chasing and something worth fearing no matter how far along
## the player is. A flat distribution would leave a large player with nothing to
## eat and a small one with nothing but predators.
func _spawn_size() -> float:
	var reference: float = player.size if player != null else 1.0
	var roll: float = _rng.randf()
	if roll < 0.45:
		return clampf(reference * _rng.randf_range(0.35, 0.80), GameRules.MIN_SIZE, GameRules.MAX_SIZE)
	if roll < 0.80:
		return clampf(reference * _rng.randf_range(0.85, 1.25), GameRules.MIN_SIZE, GameRules.MAX_SIZE)
	return clampf(reference * _rng.randf_range(1.30, 2.10), GameRules.MIN_SIZE, GameRules.MAX_SIZE)


func _spawn_position() -> Vector3:
	var anchor: Vector3 = player.global_position if player != null else Vector3.ZERO
	var angle: float = _rng.randf() * TAU
	var distance: float = _rng.randf_range(SPAWN_MIN_DISTANCE, SPAWN_MAX_DISTANCE)
	var x: float = anchor.x + cos(angle) * distance
	var z: float = anchor.z + sin(angle) * distance
	var ground: float = world.height_at(x, z)
	return Vector3(x, ground + _rng.randf_range(40.0, 150.0), z)


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
	bird.configure(_spawn_size(), _spawn_position(), world, world.world_seed + _next_seed)
	birds.append(bird)


## Each bird looks at the nearest interesting thing — including the player.
func _retarget_all() -> void:
	var candidates: Array[Node3D] = []
	for bird: BirdNPC in birds:
		candidates.append(bird)
	if player != null:
		candidates.append(player)

	for bird: BirdNPC in birds:
		var best: Node3D = null
		var best_distance: float = BirdNPC.SENSE_RADIUS
		for other: Node3D in candidates:
			if other == bird:
				continue
			var distance: float = bird.global_position.distance_to(other.global_position)
			if distance >= best_distance:
				continue
			# Only care about birds that are meaningfully bigger or smaller.
			var other_size: float = BirdNPC._size_of(other)
			if GameRules.can_catch(bird.size, other_size) or GameRules.can_catch(other_size, bird.size):
				best = other
				best_distance = distance
		bird.target = best
		if player != null:
			bird.show_threat(player.size)


func _resolve_catches() -> void:
	if player == null:
		return
	var eaten: Array[BirdNPC] = []

	for bird: BirdNPC in birds:
		if not is_instance_valid(bird) or eaten.has(bird):
			continue
		var distance: float = player.global_position.distance_to(bird.global_position)
		if distance > GameRules.catch_distance(player.size, bird.size):
			continue
		if GameRules.can_catch(player.size, bird.size):
			eaten.append(bird)
			score += GameRules.score_for_catch(bird.size)
			player.set_size(GameRules.grown_size(player.size, bird.size))
			player_caught_bird.emit(bird.size)
			score_changed.emit(score)
		elif GameRules.can_catch(bird.size, player.size):
			bird.devour(player.size)
			player.set_size(GameRules.size_after_being_caught(player.size))
			# Back into the air nearby rather than at some fixed point, so being
			# caught costs you position and mass but never the thread of play.
			player.respawn_at(_respawn_position())
			player_was_caught.emit(bird.size)
			break

	# Birds eat each other too, so the flock has its own pecking order and the
	# world keeps moving whether or not the player is involved.
	for i in birds.size():
		var a: BirdNPC = birds[i]
		if not is_instance_valid(a) or eaten.has(a):
			continue
		for j in range(i + 1, birds.size()):
			var b: BirdNPC = birds[j]
			if not is_instance_valid(b) or eaten.has(b):
				continue
			var distance: float = a.global_position.distance_to(b.global_position)
			if distance > GameRules.catch_distance(a.size, b.size):
				continue
			if GameRules.can_catch(a.size, b.size):
				a.devour(b.size)
				eaten.append(b)
			elif GameRules.can_catch(b.size, a.size):
				b.devour(a.size)
				eaten.append(a)
				break

	for bird: BirdNPC in eaten:
		birds.erase(bird)
		if is_instance_valid(bird):
			bird.die()


## Keeps the flock topped up, and quietly recycles birds that have drifted so
## far away that they are no longer part of the game.
func _maintain_population() -> void:
	if player == null:
		return
	for bird: BirdNPC in birds.duplicate():
		if not is_instance_valid(bird):
			birds.erase(bird)
			continue
		if bird.global_position.distance_to(player.global_position) > SPAWN_MAX_DISTANCE * 1.8:
			bird.position = _spawn_position()
			bird.set_size(_spawn_size())
	while birds.size() < FLOCK_SIZE:
		_spawn_bird()


## Nearest bird the player can currently eat, for the HUD's guidance arrow.
func nearest_prey() -> BirdNPC:
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
