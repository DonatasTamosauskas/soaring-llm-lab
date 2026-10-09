class_name EcosystemSim
extends RefCounted

## The sky with nobody in it.
##
## Runs a real [Flock] of real [BirdNPC]s over the real world — the same brains,
## the same [FlightModel], the same perch points — with no player, no
## [GameManager] and no scene tree, and counts what happens. Feeding it a fixed
## step makes several minutes of ecosystem run in a couple of seconds, which is
## what turns "it looks alive" into numbers somebody can argue with.
##
## Two things use it: [AITests], which asserts on a short run, and
## `tests/ecosystem.gd`, which prints a long one.
##
## The one thing it fakes is population: with nobody playing there is no manager
## to keep the sky stocked, so a bird that gets eaten is re-configured somewhere
## else at a fresh size, exactly as [method GameManager._maintain_population]
## would. Everything else — who sees whom, who chases whom, who lands where and
## who eats whom — is the shipping code.

## Birds are parented under a stage in the scene tree's root, because
## [member Node3D.global_position] reads zero for a node that is not in a tree
## and a whole flock at the origin eats itself twenty-five times a frame. They
## are stepped by hand all the same — [method Node.set_physics_process] is turned
## off on every one of them — so the simulation stays deterministic and runs as
## fast as the machine can go rather than at ninety frames a second.
const STEP: float = 1.0 / 90.0
## How often the census is taken.
const SAMPLE_INTERVAL: float = 5.0
## How far a bird has to move between stuck checks not to count as stuck, and
## how long a check is. A bird sitting on a branch is not stuck, and neither is
## one circling a thermal or spiralling onto a perch — both of those are
## excluded outright. Forty metres in forty seconds is seven hundred metres of
## flight path: a bird that fails it is going nowhere in any useful sense.
const STUCK_WINDOW: float = 40.0
const STUCK_TRAVEL: float = 40.0
## Anything further from the origin than this has left the arena for good — the
## rim crest is at 880 m and the massif runs out at 1150 m.
const STRAY_RADIUS: float = 1250.0

var world: WorldBuilder
var flock := Flock.new()
var birds: Array[BirdNPC] = []
var elapsed: float = 0.0

## One row per [constant SAMPLE_INTERVAL], each a census of the whole flock.
var samples: Array[Dictionary] = []
## Counters that only ever go up.
var respawns: int = 0
var stuck_reports: int = 0
## What the birds that went nowhere were doing at the time — a bird circling its
## quarry is a dogfight, a bird circling nothing is a bug, and the count alone
## cannot tell them apart.
var stuck_states: Dictionary = {}
## The longest a single bird has ever been going nowhere, in consecutive checks.
## One bird flagged twenty times running is a hang; twenty birds flagged once
## each is a flock that turns corners.
var stuck_streak: int = 0
var strays: int = 0
var nonfinite: int = 0
var soar_climb: float = 0.0
var perch_seconds: float = 0.0
var flight_seconds: float = 0.0
## Instance id -> how many landings that bird made. Perch usage per individual,
## so "the same two birds landed forty times" cannot masquerade as a roost.
var landings_by_bird: Dictionary = {}
## Perch point indices that have been sat on at least once.
var perches_used: Dictionary = {}
var closest_pass: float = INF

var _rng := RandomNumberGenerator.new()
var _sample_timer: float = 0.0
var _stuck_timer: float = 0.0
var _stuck_marks: Dictionary = {}
var _stuck_runs: Dictionary = {}
var _was_perched: Dictionary = {}
var _soar_altitude: Dictionary = {}
var _seed: int = 20260813
var _stage: Node3D


## [param world_ref] may be null, in which case birds fly in a void with no
## ground, no lift and nowhere to perch — useful for the pure-behaviour tests
## and useless for an ecosystem.
func setup(world_ref: WorldBuilder, count: int, sim_seed: int = 20260813) -> void:
	world = world_ref
	_seed = sim_seed
	_rng.seed = sim_seed
	flock.world = world
	_stage = Node3D.new()
	_stage.name = "Ecosystem"
	(Engine.get_main_loop() as SceneTree).root.add_child(_stage)
	for i in count:
		var bird := BirdNPC.new()
		_stage.add_child(bird)
		# Driven by [method step], never by the tree: being stepped twice would
		# double every bird's speed and halve its turn radius.
		bird.set_physics_process(false)
		bird.configure(_draw_size(), _draw_position(), world, sim_seed + i * 17)
		birds.append(bird)
		flock.add(bird)


## Makes every bird due a rest within the next few seconds. Only for short test
## runs: roosting is a thing birds do every minute or two, and a sixty-second
## simulation would otherwise never see one.
func hurry_rest() -> void:
	for bird: BirdNPC in birds:
		bird._rest_timer = _rng.randf_range(2.0, 25.0)


## The size mix. Deliberately wide: an ecosystem where nothing can eat anything
## is a screensaver, and one where everything can eat everything empties itself.
func _draw_size() -> float:
	var roll: float = _rng.randf()
	if roll < 0.45:
		return _rng.randf_range(0.4, 0.9)
	if roll < 0.85:
		return _rng.randf_range(0.9, 1.8)
	return _rng.randf_range(1.8, 3.4)


func _draw_position() -> Vector3:
	var angle: float = _rng.randf() * TAU
	var radius: float = _rng.randf_range(60.0, 520.0)
	var x: float = cos(angle) * radius
	var z: float = sin(angle) * radius
	var ground: float = world.height_at(x, z) if world != null else 0.0
	return Vector3(x, ground + _rng.randf_range(60.0, 200.0), z)


func run(seconds: float) -> void:
	var steps: int = int(seconds / STEP)
	for i in steps:
		step()


func step() -> void:
	elapsed += STEP
	flock.tick(STEP)
	for bird: BirdNPC in birds:
		bird.fly(STEP)
	_recycle(flock.resolve_rivalries())
	_account(STEP)


## An eaten bird becomes a new bird somewhere else, which is what the manager
## does when it tops the flock back up. Reusing the node rather than freeing it
## keeps the simulation independent of the scene tree, which never runs a frame
## here and so would never actually free anything.
func _recycle(eaten: Array[BirdNPC]) -> void:
	for bird: BirdNPC in eaten:
		flock.remove(bird)
		respawns += 1
		bird.configure(_draw_size(), _draw_position(), world, _seed + respawns * 31)
		flock.add(bird)


func _account(delta: float) -> void:
	for bird: BirdNPC in birds:
		var id: int = bird.get_instance_id()
		if not bird.at().is_finite() or not bird.model.velocity.is_finite() \
				or not is_finite(bird.energy):
			nonfinite += 1
		if bird.is_perched():
			perch_seconds += delta
			if not bool(_was_perched.get(id, false)):
				_was_perched[id] = true
				landings_by_bird[id] = int(landings_by_bird.get(id, 0)) + 1
				if bird._perch_index >= 0:
					perches_used[bird._perch_index] = true
		else:
			flight_seconds += delta
			_was_perched[id] = false
		if bird.state == BirdNPC.State.SOAR:
			var last: float = float(_soar_altitude.get(id, bird.at().y))
			soar_climb += maxf(0.0, bird.at().y - last)
		_soar_altitude[id] = bird.at().y
		if Vector2(bird.at().x, bird.at().z).length() > STRAY_RADIUS:
			strays += 1

	_stuck_timer += delta
	if _stuck_timer >= STUCK_WINDOW:
		_stuck_timer = 0.0
		_check_stuck()

	_sample_timer += delta
	if _sample_timer >= SAMPLE_INTERVAL or samples.is_empty():
		_sample_timer = 0.0
		samples.append(_census())


## A bird is stuck if it is neither perched nor going anywhere. Everything in
## this AI has a timeout for exactly this reason, and this is the thing that
## proves the timeouts work.
func _check_stuck() -> void:
	for bird: BirdNPC in birds:
		var id: int = bird.get_instance_id()
		var mark: Vector3 = _stuck_marks.get(id, bird.at())
		# A bird circling a thermal or spiralling down onto a branch is not going
		# anywhere either, and is doing exactly what it should be. Both of those
		# states carry their own timeout.
		var busy: bool = bird.state == BirdNPC.State.SOAR or bird.state == BirdNPC.State.LAND
		if not bird.is_perched() and not busy and bird.at().distance_to(mark) < STUCK_TRAVEL:
			stuck_reports += 1
			stuck_states[bird.state] = int(stuck_states.get(bird.state, 0)) + 1
			var run: int = int(_stuck_runs.get(id, 0)) + 1
			_stuck_runs[id] = run
			stuck_streak = maxi(stuck_streak, run)
		else:
			_stuck_runs[id] = 0
		_stuck_marks[id] = bird.at()


func _census() -> Dictionary:
	var states: Dictionary = {}
	for value: int in BirdNPC.State.values():
		states[value] = 0
	var sizes: Array[float] = []
	var energy_sum: float = 0.0
	var energy_low: float = 1.0
	var altitude_sum: float = 0.0
	var nearest: float = INF
	var nearest_sum: float = 0.0
	var nearest_sum_all: float = 0.0
	for bird: BirdNPC in birds:
		states[bird.state] = int(states[bird.state]) + 1
		sizes.append(bird.size)
		energy_sum += bird.energy
		energy_low = minf(energy_low, bird.energy)
		var ground: float = world.height_at(
			bird.at().x, bird.at().z
		) if world != null else 0.0
		altitude_sum += bird.at().y - ground
		var closest: float = INF
		for other: BirdNPC in birds:
			if other == bird:
				continue
			var distance: float = bird.at().distance_to(other.at())
			nearest_sum_all += distance
			# Predator and prey are excluded from the closest-pass figure: two
			# birds converging because one of them is eating the other are
			# supposed to touch. What this measures is traffic — birds with no
			# business being near each other flying through each other.
			if GameRules.can_catch(bird.size, other.size) \
					or GameRules.can_catch(other.size, bird.size):
				continue
			closest = minf(closest, distance)
		if is_finite(closest):
			nearest = minf(nearest, closest)
			nearest_sum += closest
	sizes.sort()
	closest_pass = minf(closest_pass, nearest)
	var count: float = maxf(float(birds.size()), 1.0)
	return {
		"time": elapsed,
		"states": states,
		"size_min": sizes[0] if not sizes.is_empty() else 0.0,
		"size_mid": sizes[sizes.size() / 2] if not sizes.is_empty() else 0.0,
		"size_max": sizes[sizes.size() - 1] if not sizes.is_empty() else 0.0,
		"energy_mean": energy_sum / count,
		"energy_min": energy_low,
		"altitude_mean": altitude_sum / count,
		"nearest_min": nearest,
		"nearest_mean": nearest_sum / count,
		"spacing_mean": nearest_sum_all / maxf(count * (count - 1.0), 1.0),
	}


# --- reading the result ---------------------------------------------------------

## How many birds were sitting on something, at the busiest moment of the run.
func peak_roosting() -> int:
	var peak: int = 0
	for sample: Dictionary in samples:
		peak = maxi(peak, int((sample["states"] as Dictionary)[BirdNPC.State.PERCH]))
	return peak


## Seconds of bird-time spent in one state, as a fraction of all of it.
func state_share(which: BirdNPC.State) -> float:
	if samples.is_empty():
		return 0.0
	var total: float = 0.0
	var mine: float = 0.0
	for sample: Dictionary in samples:
		var states: Dictionary = sample["states"]
		for key: int in states:
			total += float(states[key])
		mine += float(states[which])
	return mine / maxf(total, 1.0)


func birds_that_perched() -> int:
	return landings_by_bird.size()


func summary() -> Dictionary:
	var last: Dictionary = samples[samples.size() - 1] if not samples.is_empty() else {}
	return {
		"minutes": elapsed / 60.0,
		"birds": birds.size(),
		"catches": flock.catches,
		"catches_per_min": float(flock.catches) / maxf(elapsed / 60.0, 0.001),
		"landings": flock.landings,
		"birds_that_perched": birds_that_perched(),
		"perches_used": perches_used.size(),
		"evictions": flock.evictions,
		"soars": flock.soars,
		"soar_climb": soar_climb,
		"perch_share": perch_seconds / maxf(perch_seconds + flight_seconds, 0.001),
		"peak_roosting": peak_roosting(),
		"stuck": stuck_reports,
		"stuck_streak": stuck_streak,
		"giveups": flock.giveups,
		"strays": strays,
		"nonfinite": nonfinite,
		"closest_pass": closest_pass,
		"size_max": float(last.get("size_max", 0.0)),
		"energy_mean": float(last.get("energy_mean", 0.0)),
	}


func release() -> void:
	birds.clear()
	flock.members.clear()
	if _stage != null:
		_stage.free()
		_stage = null
