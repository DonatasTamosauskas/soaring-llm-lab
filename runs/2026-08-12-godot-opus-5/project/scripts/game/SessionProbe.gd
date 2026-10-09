class_name SessionProbe
extends Node

## Flies a whole session of the real game on an autopilot and counts what
## actually happens.
##
## [SessionSim] can play two hundred runs in a second, but only because it
## models the two things it cannot compute: how long it takes a hunting bird to
## find something, and how long it takes to run it down. This is where those two
## numbers come from. It hunts through the real world, with the real flock, the
## real AI, the real collisions and the real catch rules, and prints the rates
## the simulation is calibrated against.
##
##   godot --headless --xr-mode off --fixed-fps 90 -- --hunt=600
##
## The autopilot hunts the way the game wants to be played — climb above the
## target, then stoop, because two birds flying the same [FlightModel] level and
## straight close on each other at four percent of their speed and a dive closes
## at forty — and pays no attention whatsoever to what is behind it. That is what
## makes it a useful anchor: it measures the hunting rate of someone with decent
## technique and no situational awareness, which is the zero-evasion end of the
## skill axis.

signal finished(passed: bool)

## Altitude above terrain the autopilot refuses to go below. Low, because prey
## that is low is still prey: at 55 m the probe was measured circling above a
## bird near the ground for forty seconds, never closing from 99 m away. Not so
## low that it spends the run landing in fields, which is what 14 m produced.
const FLOOR_CLEARANCE: float = 32.0
const CRUISE_CLEARANCE: float = 130.0
## How long a chase may run before the autopilot gives up and picks again. Real
## players give up too; without this, one unreachable swift eats the whole run.
const CHASE_TIMEOUT: float = 25.0
## Height the autopilot wants over its target before it commits, and the range
## inside which it stops climbing and dives. A shallow stoop on purpose: diving
## from 45 m up arrives at 45 m/s, and at 45 m/s a 75-degree bank still needs a
## 44 m turn radius, so a steep stoop that is even slightly off cannot correct.
const STOOP_HEIGHT: float = 22.0
const STOOP_RANGE: float = 90.0
## Inside this range the autopilot stops manoeuvring for position and simply
## flies the intercept: wings open for turn authority, aim point led.
const TERMINAL_RANGE: float = 28.0
## Furthest the autopilot will bother engaging. Chasing a bird 240 m away is not
## hunting, it is commuting, and it measures nothing useful.
const ENGAGE_RANGE: float = 130.0
## How close a bird that is actually coming for you has to get before an evading
## autopilot breaks off and runs, and how far it runs before going back to
## hunting. Only birds in [constant BirdNPC.State.HUNT] with the player as their
## target count: running from every larger bird in the sky put 44 percent of a
## measured run into evasion and four catches into fifteen minutes, which is not
## caution, it is paralysis.
const PANIC_RANGE: float = 75.0
const SAFE_RANGE: float = 105.0

var player: BirdPlayer
var world: WorldBuilder
var manager: GameManager
var duration: float = 600.0
## Whether the autopilot looks over its shoulder. Off measures the zero-evasion
## end of the skill axis (a beginner who has not yet worked out that the red
## birds are a problem); on measures someone who has.
##   godot --headless --xr-mode off --fixed-fps 90 -- --hunt=600 --hunt_evade=1
var evade: bool = false
## Whether this run is a gate rather than a measurement. When set, the probe
## prints a verdict and fails if the autopilot did not convert enough chases.
##
## This exists because the awareness constants in [GameManager] —
## [constant GameManager.THREAT_NOTICE_RADIUS],
## [constant GameManager.HUNT_NOTICE_RADIUS] and
## [constant GameManager.FLEE_STAMINA] — are the whole reason hunting works, and
## nothing else in the tree can tell whether they are still doing their job. All
## four other gates stay green with them reverted to the state that measured
## [b]zero catches in ten minutes[/b]; a chase is a scene, a flock, an AI, a
## flight model and an hour of real time, so the only honest test of it is to fly
## one.
##   godot --headless --xr-mode off --fixed-fps 90 -- --hunt=600 --hunt_gate=1
var gate: bool = false
## Catches per minute the gate insists on. The measured rate with the constants
## as they stand is 0.60 (six catches in ten minutes, twenty percent conversion);
## with them reverted it is 0.00. A third of the measured rate is enough margin
## that the gate is not a coin flip, and still nowhere near passable by a game
## in which prey bolts at ninety-five metres and never tires.
const GATE_CATCH_RATE: float = 0.20
## Keep flying after a run ends, restarting it, so that one invocation measures
## dozens of chases and a useful number of deaths instead of one noisy sample.
## Rates, not outcomes, are what the simulation needs calibrating against.
##   godot --headless --xr-mode off --fixed-fps 90 -- --hunt=1200 --hunt_evade=1 --hunt_endless=1
var endless: bool = false

var _command := FlightCommand.new()
var _elapsed: float = 0.0
var _flap_phase: float = 0.0
var _target: BirdNPC = null
var _chase_time: float = 0.0
var _search_time: float = 0.0
var _searching: float = 0.0
var _chasing: float = 0.0
var _chases: int = 0
var _catches: int = 0
var _deaths: int = 0
var _abandoned: int = 0
var _search_samples: Array[float] = []
var _chase_samples: Array[float] = []
## Closest the autopilot actually got to the bird it was chasing, per chase.
## When hunting fails, this is the number that says why: a chase that ends at
## 60 m is a kinematics problem, one that ends at 3 m is an aiming problem.
var _approach_samples: Array[float] = []
var _closest: float = INF
var _start_distance: float = 0.0
var _fleeing_time: float = 0.0
var _speed_at_closest: float = 0.0
var _prey_speed_at_closest: float = 0.0
var _height_at_closest: float = 0.0
var _restarts: int = 0
var _evading: float = 0.0
var _evading_from: BirdNPC = null
var _size_trace: Array[float] = []
var _trace_timer: float = 0.0
var _done: bool = false


func start(player_ref: BirdPlayer, world_ref: WorldBuilder, manager_ref: GameManager,
		seconds: float) -> void:
	player = player_ref
	world = world_ref
	manager = manager_ref
	duration = seconds
	player.scripted_command = _command
	manager.player_caught_bird.connect(_on_catch)
	manager.player_was_caught.connect(_on_death)
	print("")
	print("=== Soaring hunt probe: %.0f s of autopiloted hunting ===" % duration)


func _on_catch(prey_size: float) -> void:
	_catches += 1
	_chase_samples.append(_chase_time)
	_approach_samples.append(0.0)
	print("  %6.1f s  caught %.2f  ->  size %.2f  (%s, chase %.1f s, search %.1f s)" % [
		_elapsed, prey_size, player.size, Progression.rank_name(player.size),
		_chase_time, _search_time
	])
	_target = null
	_chase_time = 0.0
	_search_time = 0.0


func _on_death(by_size: float) -> void:
	_deaths += 1
	print("  %6.1f s  CAUGHT by %.2f  ->  size %.2f  (%d lives left)" % [
		_elapsed, by_size, player.size, manager.session.lives
	])
	_target = null
	_chase_time = 0.0


func _physics_process(delta: float) -> void:
	if _done or player == null:
		return
	_elapsed += delta
	_trace_timer -= delta
	if _trace_timer <= 0.0:
		_trace_timer = 5.0
		_size_trace.append(player.size)

	var threat: BirdNPC = _closing_threat() if evade else null
	if threat != null:
		_evading += delta
		_target = null
		_chase_time = 0.0
		_flee_from(threat, delta)
	else:
		_choose_target(delta)
		_fly(delta)

	if manager.session.is_over() and endless and _elapsed < duration:
		_restarts += 1
		manager.restart()
	if _elapsed >= duration or (manager.session.is_over() and not endless):
		_report()


## Nearest bird the player can legally eat, re-picked whenever the current one
## is gone or has taken too long. This is [method GameManager.nearest_prey] —
## the same call the HUD's guidance chevron uses.
func _choose_target(delta: float) -> void:
	if _target != null and (not is_instance_valid(_target)
			or not GameRules.can_catch(player.size, _target.size)
			or _chase_time > CHASE_TIMEOUT):
		if _chase_time > CHASE_TIMEOUT:
			_abandoned += 1
			_approach_samples.append(_closest)
			print("  %6.1f s  gave up: started %.0f m, closest %.0f m, %.0f%% fleeing, "
				% [_elapsed, _start_distance, _closest,
					100.0 * _fleeing_time / maxf(_chase_time, 0.001)]
				+ "at closest: me %.0f m/s, it %.0f m/s, %.0f m above it" % [
					_speed_at_closest, _prey_speed_at_closest, _height_at_closest
				])
		_target = null
		_chase_time = 0.0

	if _target == null:
		_search_time += delta
		_searching += delta
		var prey: BirdNPC = _best_target()
		if prey != null:
			_target = prey
			_chases += 1
			_search_samples.append(_search_time)
			_search_time = 0.0
			_start_distance = player.global_position.distance_to(prey.global_position)
			_closest = _start_distance
			_fleeing_time = 0.0
	else:
		_chase_time += delta
		_chasing += delta
		var gap: float = player.global_position.distance_to(_target.global_position)
		if gap < _closest:
			_closest = gap
			_speed_at_closest = player.airspeed()
			_prey_speed_at_closest = _target.model.velocity.length()
			_height_at_closest = player.global_position.y - _target.global_position.y
		if _target.state == BirdNPC.State.FLEE:
			_fleeing_time += delta


## The nearest bird that could eat us and is not already being left behind.
## Hysteresis on the range so that breaking off is a decision, not a flutter.
func _closing_threat() -> BirdNPC:
	var limit: float = SAFE_RANGE if _evading_from != null else PANIC_RANGE
	var best: BirdNPC = null
	var best_distance: float = limit
	for bird: BirdNPC in manager.birds:
		if not is_instance_valid(bird) or not GameRules.can_catch(bird.size, player.size):
			continue
		if bird.state != BirdNPC.State.HUNT or bird.target != player:
			continue
		var distance: float = player.global_position.distance_to(bird.global_position)
		if distance < best_distance:
			best_distance = distance
			best = bird
	_evading_from = best
	return best


## Break, do not run. A bird that is bigger is also faster in a straight line,
## so running away from a stooping attacker is the one thing that cannot work —
## [SessionProbe] measured an autopilot that ran straight dying 0.73 times a
## minute while catching 0.53. What the player does have is a tighter turning
## circle, because [FlightModel] turn radius goes with the square of speed: turn
## hard across the attacker's line and it has to overshoot.
func _flee_from(threat: BirdNPC, delta: float) -> void:
	var model: FlightModel = player.model
	var ground: float = world.height_at(player.global_position.x, player.global_position.z)

	# Perpendicular to the attacker's approach, whichever way is the cheaper turn.
	var approach: Vector3 = threat.model.velocity
	if approach.length_squared() < 1.0:
		approach = player.global_position - threat.global_position
	var across: Vector3 = approach.normalized().cross(Vector3.UP)
	if across.length_squared() < 0.01:
		across = model.forward()
	across = across.normalized()
	var heading_now: Vector3 = model.forward()
	if across.dot(heading_now) < 0.0:
		across = -across

	var horizontal := Vector2(across.x, across.z)
	var desired: float = atan2(-horizontal.x, -horizontal.y)
	var error: float = wrapf(desired - model.heading, -PI, PI)
	# All the bank there is. A break turn is not a course correction.
	_command.bank = clampf(-error * 3.0, -1.25, 1.25)

	# Trade a little height for the speed the turn costs, unless there is none.
	var clearance: float = player.global_position.y - ground
	var descend: bool = clearance > FLOOR_CLEARANCE * 1.5
	_command.alpha = clampf(
		model.alpha_trim + (-0.25 if descend else 0.15) * model.alpha_range,
		-model.alpha_range, model.alpha_stall * 0.92
	)
	# Wings stay spread: span is turn authority, and turning is the whole plan.
	_command.span = 1.0
	_flap_phase = fmod(_flap_phase + delta, 0.55)
	_command.stroke_speed = 3.2 if _flap_phase < 0.25 else 0.0


## Which bird to go after. Nearest is not the answer a player would give: they
## pick the one that is ahead of them, below them and not already running, which
## is the same thing as picking the chase that will actually convert.
func _best_target() -> BirdNPC:
	var forward: Vector3 = player.model.forward()
	var best: BirdNPC = null
	var best_score: float = -INF
	for bird: BirdNPC in manager.birds:
		if not is_instance_valid(bird) or not GameRules.can_catch(player.size, bird.size):
			continue
		var offset: Vector3 = bird.global_position - player.global_position
		var distance: float = offset.length()
		if distance > ENGAGE_RANGE or distance < 0.01:
			continue
		var score: float = -distance
		# Ahead is worth about forty metres of distance; behind means turning
		# around, and turning around at 20 m/s takes a hundred metres of sky.
		score += forward.dot(offset / distance) * 40.0
		# Below is free speed.
		score += clampf(-offset.y, -30.0, 30.0) * 0.6
		if bird.state == BirdNPC.State.FLEE:
			score -= 45.0
		if score > best_score:
			best_score = score
			best = bird
	return best


## Where to fly to hit a bird that is moving: the classic intercept solution,
## the smallest positive root of |r + v t| = speed * t. A player does this by
## eye without thinking about it, and an autopilot that does not do it at all
## misses non-manoeuvring targets by twenty metres — which was being read as
## "the game is too hard" when it was only "the instrument cannot aim".
func _intercept_point(target: BirdNPC, speed: float) -> Vector3:
	var r: Vector3 = target.global_position - player.global_position
	var v: Vector3 = target.model.velocity
	var a: float = v.length_squared() - speed * speed
	var b: float = 2.0 * r.dot(v)
	var c: float = r.length_squared()
	var time: float = 0.0
	if absf(a) < 0.001:
		time = -c / b if absf(b) > 0.001 else 0.0
	else:
		var discriminant: float = b * b - 4.0 * a * c
		if discriminant >= 0.0:
			var root: float = sqrt(discriminant)
			var t1: float = (-b + root) / (2.0 * a)
			var t2: float = (-b - root) / (2.0 * a)
			time = minf(t1, t2) if minf(t1, t2) > 0.0 else maxf(t1, t2)
	if not is_finite(time) or time <= 0.0:
		time = r.length() / maxf(speed, 1.0)
	return target.global_position + v * clampf(time, 0.0, 6.0)


func _fly(delta: float) -> void:
	var model: FlightModel = player.model
	var ground: float = world.height_at(player.global_position.x, player.global_position.z)
	var goal: Vector3
	var terminal: bool = false
	if _target != null and is_instance_valid(_target):
		# Aim where the target will be, not where it is: at a closing speed of
		# 30 m/s a bird flown at its prey's current position arrives behind it.
		# Solved once against the closing rate rather than raw speed, which is
		# what makes the lead hold up in a tail chase as well as a head-on pass.
		var to_target: Vector3 = _target.global_position - player.global_position
		var range_now: float = to_target.length()
		goal = _intercept_point(_target, maxf(model.velocity.length(), model.trim_speed()))
		terminal = range_now < TERMINAL_RANGE
		# Set up the stoop. Beyond striking range, fly to a perch of air above the
		# target and keep the height; inside it, spend the height on the strike.
		var height: float = player.global_position.y - _target.global_position.y
		if range_now > STOOP_RANGE and height < STOOP_HEIGHT:
			goal.y = _target.global_position.y + STOOP_HEIGHT
	else:
		# No prey in sight: cruise at a useful altitude, turning slowly, which is
		# roughly what a player scanning the sky does.
		var angle: float = _elapsed * 0.05
		goal = Vector3(cos(angle) * 260.0, ground + CRUISE_CLEARANCE, sin(angle) * 260.0)
	goal.y = maxf(goal.y, ground + FLOOR_CLEARANCE)

	var offset: Vector3 = goal - player.global_position
	var horizontal := Vector2(offset.x, offset.z)
	if horizontal.length_squared() < 1.0:
		horizontal = Vector2(0.0, -1.0)
	var desired: float = atan2(-horizontal.x, -horizontal.y)
	var error: float = wrapf(desired - model.heading, -PI, PI)
	_command.bank = clampf(-error * 1.6, -1.2, 1.2)

	# Aim harder the closer it gets: a 40 m error at 200 m is nothing, the same
	# error at 20 m is a miss.
	var pitch_scale: float = clampf(offset.length() * 0.4, 8.0, 40.0)
	var pitch: float = clampf(offset.y / pitch_scale, -1.0, 1.0)
	# Energy before position. Chasing a climbing bird by pointing the nose at it
	# is how the autopilot spent its first measured runs at 6 m/s and 30 m below
	# its prey; a bird that is slow has nothing to strike with, so it puts the
	# nose down first and takes the shot on the way back up.
	if model.velocity.length() < model.trim_speed() * 0.95:
		pitch = minf(pitch, 0.0)
	_command.alpha = clampf(
		model.alpha_trim + pitch * model.alpha_range,
		-model.alpha_range, model.alpha_stall * 0.92
	)
	# Wings stay open for the strike. Tucking buys speed and spends exactly the
	# turn authority the last twenty metres need.
	_command.span = 0.25 if (offset.y < -30.0 and _target != null and not terminal) else 1.0

	# A chasing bird flaps. The NPCs beat their wings urgently the whole time
	# they are fleeing, so an autopilot that only flapped when it was slow was
	# being out-powered by its own prey — the first ten minutes of measurement
	# were of a hunter gliding after a bird that was rowing away from it.
	var chasing: bool = _target != null and is_instance_valid(_target)
	var slow: bool = model.velocity.length() < model.trim_speed() * (1.45 if chasing else 1.05)
	var climbing: bool = offset.y > 6.0
	if player.perched or ((slow or climbing) and _command.span > 0.5):
		_flap_phase = fmod(_flap_phase + delta, 0.55)
		_command.stroke_speed = 3.2 if _flap_phase < 0.25 else 0.0
	else:
		_command.stroke_speed = 0.0
		_flap_phase = 0.0


func _report() -> void:
	_done = true
	player.scripted_command = null
	var minutes: float = maxf(_elapsed / 60.0, 0.001)
	print("")
	print("  flown           %.0f s (%.1f min)%s" % [
		_elapsed, minutes, "  across %d runs" % (_restarts + 1) if endless else ""
	])
	print("  catches         %d  (%.2f /min, one per %.1f s)" % [
		_catches, _catches / minutes, _elapsed / maxf(float(_catches), 1.0)
	])
	print("  chases started  %d  (%d abandoned after %.0f s)" % [
		_chases, _abandoned, CHASE_TIMEOUT
	])
	print("  conversion      %.0f%% of chases ended in a catch" % [
		100.0 * float(_catches) / maxf(float(_chases), 1.0)
	])
	print("  mean search     %.1f s   (%.0f%% of the run spent looking)" % [
		_mean(_search_samples), 100.0 * _searching / maxf(_elapsed, 0.001)
	])
	print("  mean chase      %.1f s   (%.0f%% of the run spent chasing)" % [
		_mean(_chase_samples), 100.0 * _chasing / maxf(_elapsed, 0.001)
	])
	print("  closest pass    %.1f m mean over %d chases (catch needs %.1f m)" % [
		_mean(_approach_samples), _approach_samples.size(),
		GameRules.catch_distance(player.size, player.size * 0.7)
	])
	print("  deaths          %d  (%.2f /min)%s" % [
		_deaths, _deaths / minutes,
		"  [evading: %.0f%% of the run spent running]" % (100.0 * _evading / maxf(_elapsed, 0.001))
			if evade else "  [no evasion]"
	])
	print("  size            %.2f -> %.2f (%s), score %d, %d catches banked" % [
		Progression.START_SIZE, player.size, Progression.rank_name(player.size),
		manager.session.score, manager.session.catches
	])
	var trace: String = ""
	for size: float in _size_trace:
		trace += "%.2f " % size
	print("  size every 5 s  %s" % trace)
	if not gate:
		print("HUNT PROBE DONE")
		finished.emit(true)
		return

	var required: int = maxi(1, int(round(minutes * GATE_CATCH_RATE)))
	var passed: bool = _catches >= required
	print("")
	print("  gate            %d catches in %.0f s, %d required (%.2f /min needed)" % [
		_catches, _elapsed, required, GATE_CATCH_RATE
	])
	if passed:
		print("HUNT PROBE PASS — hunting converts")
	else:
		print("  - the autopilot could not convert a chase. The hunting rules in")
		print("    GameManager (THREAT_NOTICE_RADIUS, HUNT_NOTICE_RADIUS,")
		print("    FLEE_STAMINA) are what make a stern chase winnable; check those")
		print("    first, then BirdNPC's flee behaviour and the strike rule.")
		print("HUNT PROBE FAIL")
	finished.emit(passed)


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for v: float in values:
		total += v
	return total / float(values.size())
