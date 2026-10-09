class_name SessionSim
extends RefCounted

## Plays whole runs of the game in a few milliseconds so the difficulty curve is
## a table of numbers instead of an opinion.
##
## It drives the [b]real[/b] [GameSession] through the [b]real[/b] [Progression]
## spawn distribution and the [b]real[/b] [GameRules] growth maths — everything
## that decides how a run feels is the shipping object. What is modelled is only
## the part that needs a world: how often a hunting bird finds something to
## chase, how long the chase takes, and how often something bigger finds it
## first.
##
## That model is not invented. Every constant below is either lifted from a
## shipping constant ([constant GameManager.FLOCK_SIZE], the spawn annulus) or
## calibrated against [SessionProbe], which flies the actual player through the
## actual world on an autopilot and counts what actually happens. Where the
## calibration is weak, the comment says so.
##
##   godot --headless --xr-mode off --script res://tests/session_report.gd

# --- geometry of the sky -----------------------------------------------------

## The volume the flock occupies around the player: the manager's spawn annulus,
## in a band of altitude as thick as the spread of its spawn heights.
const BAND_THICKNESS: float = 110.0
## How far off a bird has to be before a player picks it out as worth chasing.
## Larger than it sounds, because a bird against sky at 130 m is a clear shape
## and the threat tint is visible further than that. Calibrated: with these two
## numbers the simulation starts a chase every 13 s, which is what [SessionProbe]
## measures in the real game (94 chases in 1200 s).
const DETECT_RADIUS: float = 130.0
## A hunting bird sweeps a tube, not a sphere: it can only chase what ends up
## roughly ahead of it. This is the fraction of the swept cross-section that is
## actually convertible into a chase.
const FORWARD_FRACTION: float = 0.65

# --- the chase ---------------------------------------------------------------
#
# These four numbers are the whole model, and all four are measured rather than
# invented. [SessionProbe] flies the real game on an autopilot and reports:
# chases that end in a catch run about 9.5 s, chases that fail run about 12 s
# before the target is lost or abandoned, and a hunter with decent technique and
# a solved intercept converts 13-20 % of them. A perfect player is given 30 %,
# which is better than anything that has actually been measured, and a hopeless
# one 5 %.

const CHASE_WON_SECONDS: float = 9.5
const CHASE_LOST_SECONDS: float = 12.0
const CONVERSION_FLOOR: float = 0.05
const CONVERSION_SKILL: float = 0.25
## How much of the conversion an agility mismatch takes away. A big bird chasing
## something that turns twice as tightly does not get to eat it.
const CONVERSION_AGILITY: float = 0.28

# --- being hunted ------------------------------------------------------------

## The radius at which a predator picks the player out — [constant
## GameManager.HUNT_NOTICE_RADIUS], because that is the constant the game
## actually uses.
const THREAT_RADIUS: float = 65.0
## Chance a predator encounter ends with the player eaten, at zero and at full
## skill. Calibrated against two [SessionProbe] runs of the real game: an
## autopilot that ignores everything behind it dies 0.50 times a minute, and the
## same autopilot break-turning when something commits to it dies 0.20 times a
## minute, against roughly one encounter a minute in both.
const DEATH_CHANCE_FLOOR: float = 0.55
const DEATH_CHANCE_SKILL: float = 0.50
## Seconds after being caught during which the player is 90 m away, climbing, and
## the sky has been redrawn around them ([method GameManager._reseed_distant_flock]).
const RESPAWN_GRACE: float = 7.0

# --- population --------------------------------------------------------------

## Mean seconds before a given bird has drifted out of range and been recycled
## at a size drawn around the player's current one. This is the lag with which
## the sky escalates behind the player's growth.
const RECYCLE_PERIOD: float = 26.0
## The manager's floor on how many catchable birds are in the sky at once (see
## [method GameManager._maintain_population]).
const MIN_PREY: int = 7

## Simulation step. Chases last seconds, so half a second resolves everything
## that matters and keeps a 500-run sweep under a second of test time.
const DT: float = 0.5

var skill: float = 0.6
var max_seconds: float = 2400.0

var _rng := RandomNumberGenerator.new()
var _flock: PackedFloat32Array = PackedFloat32Array()
var _trim_cache: Dictionary = {}
## How many of the flock the player can eat, and how many can eat the player.
## Kept incrementally rather than counted: a sweep of a thousand runs asks this
## question about ten million times, and counting it each time was most of the
## simulation's cost.
var _prey_count: int = 0
var _predator_count: int = 0


# --- flight numbers, taken from the real model -------------------------------

## Trim speed of a bird of this size, straight out of [FlightModel] — the same
## number the player flies at. Cached because a sweep asks for it tens of
## thousands of times.
func _trim_speed(size: float) -> float:
	var key: int = int(round(size * 20.0))
	if _trim_cache.has(key):
		return float(_trim_cache[key])
	var model := FlightModel.new()
	model.set_size(maxf(size, GameRules.MIN_SIZE))
	var speed: float = model.trim_speed()
	_trim_cache[key] = speed
	return speed


## Radius of a hard 60-degree turn at chasing speed. The size/agility tradeoff
## is the whole reason a big bird cannot simply hoover up the sky, so the chase
## model reads it off the same physics the player feels.
func _turn_radius(size: float) -> float:
	var v: float = _trim_speed(size) * 1.25
	return v * v / (9.81 * tan(1.05))


## How outclassed a hunter is by its prey's agility. 1.0 when they turn alike,
## higher when the hunter is a barn door chasing a swift.
func _agility_gap(hunter: float, prey: float) -> float:
	return clampf(_turn_radius(hunter) / maxf(_turn_radius(prey), 0.001), 1.0, 2.6)


func _flock_volume() -> float:
	var r1: float = GameManager.SPAWN_MIN_DISTANCE
	var r2: float = GameManager.SPAWN_MAX_DISTANCE
	return PI * (r2 * r2 - r1 * r1) * BAND_THICKNESS


## Chance per second of running into one particular bird of the flock, given how
## fast the two of you are closing. This is the one number that sets the whole
## pace of the game, so it is derived rather than dialled: density times swept
## cross-section times closing speed.
func _encounter_rate(player_size: float, other_size: float, radius: float, forward: float) -> float:
	var closing: float = _trim_speed(player_size) + _trim_speed(other_size) * 0.35
	return PI * radius * radius * forward * closing / _flock_volume()


# --- one run -----------------------------------------------------------------

## Plays a single session to its end and returns its [method
## GameSession.summary], plus how the run finished.
func run(run_seed: int, run_skill: float) -> Dictionary:
	skill = clampf(run_skill, 0.0, 1.0)
	_rng.seed = run_seed
	var session := GameSession.new()
	var size: float = Progression.START_SIZE
	session.begin(size)

	_reseed_flock(size)

	var chase_size: float = 0.0
	var chase_timer: float = 0.0
	var chase_won: bool = false
	var grace: float = 0.0
	var chases: int = 0
	var escapes: int = 0
	var hunted: float = 0.0

	while not session.is_over() and session.elapsed < max_seconds:
		session.tick(DT, size)
		_recycle(size)

		if grace > 0.0:
			grace -= DT
			continue

		# Something bigger finds you whether or not you are busy. This is what
		# makes the late game frightening rather than merely slower: the mix
		# tilts toward predators exactly as your own growth slows down.
		var predator: float = _pick(size, false)
		if predator > 0.0:
			var rate: float = _encounter_rate(size, predator, THREAT_RADIUS, 1.0)
			rate *= float(_predator_count)
			hunted += rate * DT
			if _rng.randf() < 1.0 - exp(-rate * DT):
				if _rng.randf() < _death_chance():
					session.record_death(predator)
					size = GameRules.size_after_being_caught(size)
					chase_timer = 0.0
					chase_size = 0.0
					grace = RESPAWN_GRACE
					_reseed_flock(size)
					continue

		if chase_timer > 0.0:
			chase_timer -= DT
			if chase_timer <= 0.0:
				if chase_won:
					size = GameRules.grown_size(size, chase_size)
					session.record_catch(chase_size, size)
					_recount(size)
					_replace_one(size)
				else:
					escapes += 1
				chase_size = 0.0
			continue

		var prey: float = _pick(size, true)
		if prey <= 0.0:
			continue
		var acquire: float = _encounter_rate(size, prey, DETECT_RADIUS, FORWARD_FRACTION)
		acquire *= float(_prey_count)
		# A novice does not see half of what is in front of them.
		acquire *= lerpf(0.45, 1.0, skill)
		if _rng.randf() < 1.0 - exp(-acquire * DT):
			# Whether the chase works is decided when it starts, because how long
			# it lasts depends on the answer: a chase that works ends at the
			# moment of the strike, and one that does not runs until the bird is
			# lost or given up on.
			chase_size = prey
			chase_won = _rng.randf() < _catch_chance(size, prey)
			chase_timer = CHASE_WON_SECONDS if chase_won else CHASE_LOST_SECONDS
			chases += 1

	var result: Dictionary = session.summary()
	result["chases"] = chases
	result["escapes"] = escapes
	result["timed_out"] = not session.is_over()
	result["final_size"] = size
	result["threat_pressure"] = hunted
	result["catch_rate"] = 60.0 * float(session.catches) / maxf(session.elapsed, 1.0)
	result["death_rate"] = 60.0 * float(session.deaths) / maxf(session.elapsed, 1.0)
	return result


func _catch_chance(hunter: float, prey: float) -> float:
	var gap: float = _agility_gap(hunter, prey)
	return clampf(
		CONVERSION_FLOOR + CONVERSION_SKILL * skill - CONVERSION_AGILITY * (gap - 1.0),
		0.02, 0.45
	)


## Nobody is untouchable: the floor is what a perfect player still loses to a
## predator that picks exactly the wrong moment, and a model that let anyone
## reach zero would make the last rank a formality.
func _death_chance() -> float:
	return clampf(DEATH_CHANCE_FLOOR - DEATH_CHANCE_SKILL * skill, 0.07, 0.9)


# --- the flock ---------------------------------------------------------------

func _reseed_flock(player_size: float) -> void:
	_flock.resize(GameManager.FLOCK_SIZE)
	for i in _flock.size():
		_flock[i] = Progression.spawn_size(player_size, _rng.randf(), _rng.randf())
	_recount(player_size)
	_guarantee_prey(player_size)


## Birds drift away and come back resized around whoever the player is now.
func _recycle(player_size: float) -> void:
	var chance: float = DT / RECYCLE_PERIOD
	for i in _flock.size():
		if _rng.randf() < chance:
			_set_bird(i, Progression.spawn_size(player_size, _rng.randf(), _rng.randf()), player_size)
	_guarantee_prey(player_size)


## Mirrors [method GameManager._maintain_population] and [method
## GameManager._enforce_variety]: the sky is never allowed to run out of things
## you can eat.
func _guarantee_prey(player_size: float) -> void:
	var i: int = 0
	while _prey_count < MIN_PREY and i < _flock.size():
		if not GameRules.can_catch(player_size, _flock[i]):
			_set_bird(
				i, Progression.size_for_role(player_size, Progression.Role.PREY, _rng.randf()),
				player_size
			)
		i += 1


func _replace_one(player_size: float) -> void:
	if _flock.is_empty():
		return
	_set_bird(
		_rng.randi() % _flock.size(),
		Progression.spawn_size(player_size, _rng.randf(), _rng.randf()),
		player_size
	)
	_guarantee_prey(player_size)


func _set_bird(index: int, size: float, player_size: float) -> void:
	var was: float = _flock[index]
	if GameRules.can_catch(player_size, was):
		_prey_count -= 1
	elif GameRules.can_catch(was, player_size):
		_predator_count -= 1
	_flock[index] = size
	if GameRules.can_catch(player_size, size):
		_prey_count += 1
	elif GameRules.can_catch(size, player_size):
		_predator_count += 1


## Recount from scratch. Needed exactly when the player's own size changes, which
## reclassifies the whole flock at once.
func _recount(player_size: float) -> void:
	_prey_count = 0
	_predator_count = 0
	for size: float in _flock:
		if GameRules.can_catch(player_size, size):
			_prey_count += 1
		elif GameRules.can_catch(size, player_size):
			_predator_count += 1


## A random member of the flock the player can eat (or that can eat the player),
## or 0.0 if there is none. Returning a size rather than an index keeps the whole
## simulation in plain floats.
func _pick(player_size: float, prey: bool) -> float:
	if (_prey_count if prey else _predator_count) <= 0:
		return 0.0
	var start: int = _rng.randi() % maxi(_flock.size(), 1)
	for offset in _flock.size():
		var size: float = _flock[(start + offset) % _flock.size()]
		if GameRules.can_catch(player_size, size) if prey else GameRules.can_catch(size, player_size):
			return size
	return 0.0


# --- sweeps ------------------------------------------------------------------

## Runs [param count] seeded sessions at one skill level and reduces them to the
## numbers a designer actually argues about.
static func sweep(run_skill: float, count: int, first_seed: int = 1) -> Dictionary:
	var wins: int = 0
	var win_times: Array[float] = []
	var catches: Array[float] = []
	var deaths: Array[float] = []
	var scores: Array[float] = []
	var elapsed: Array[float] = []
	var catch_rates: Array[float] = []
	var death_rates: Array[float] = []
	var promotions: Array = []
	for i in Progression.RANKS.size():
		promotions.append([] as Array[float])

	for i in count:
		var sim := SessionSim.new()
		var result: Dictionary = sim.run(first_seed + i * 7919, run_skill)
		if bool(result["won"]):
			wins += 1
			win_times.append(float(result["elapsed"]))
		catches.append(float(result["catches"]))
		elapsed.append(float(result["elapsed"]))
		catch_rates.append(float(result["catch_rate"]))
		death_rates.append(float(result["death_rate"]))
		deaths.append(float(result["deaths"]))
		scores.append(float(result["score"]))
		var times: PackedFloat32Array = result["rank_times"]
		for r in times.size():
			if times[r] >= 0.0:
				(promotions[r] as Array[float]).append(times[r])

	var rank_medians := PackedFloat32Array()
	var rank_reach := PackedFloat32Array()
	for r in promotions.size():
		var samples: Array[float] = promotions[r]
		rank_medians.append(percentile(samples, 0.5))
		rank_reach.append(float(samples.size()) / maxf(float(count), 1.0))

	return {
		"skill": run_skill,
		"runs": count,
		"win_rate": float(wins) / maxf(float(count), 1.0),
		"win_time_median": percentile(win_times, 0.5),
		"win_time_p10": percentile(win_times, 0.1),
		"win_time_p90": percentile(win_times, 0.9),
		"catches_median": percentile(catches, 0.5),
		"deaths_median": percentile(deaths, 0.5),
		"deaths_mean": _mean(deaths),
		"score_median": percentile(scores, 0.5),
		"elapsed_median": percentile(elapsed, 0.5),
		"catch_rate_median": percentile(catch_rates, 0.5),
		"death_rate_median": percentile(death_rates, 0.5),
		"rank_time_median": rank_medians,
		"rank_reached": rank_reach,
	}


static func percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return NAN
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var index: int = clampi(
		int(round(fraction * float(sorted.size() - 1))), 0, sorted.size() - 1
	)
	return sorted[index]


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var total: float = 0.0
	for v: float in values:
		total += v
	return total / float(values.size())
