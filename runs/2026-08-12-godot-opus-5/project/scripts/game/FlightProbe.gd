class_name FlightProbe
extends Node

## Flies the real game — real world, real colliders, real game manager — through
## a scripted routine and checks that it behaved.
##
## The headless suites in `tests/` prove the aerodynamics and the input mapping
## in isolation. This proves the integration: that the player actually moves
## through the world, that hitting a hillside at speed is survivable, that
## landing sticks, and that nothing quietly turns into NaN after a minute of
## physics. Run it with:
##   godot --headless --xr-mode off --fixed-fps 90 -- --probe=1

signal finished(passed: bool)

var player: BirdPlayer
var world: WorldBuilder
var manager: GameManager

var _command := FlightCommand.new()
var _log: PackedStringArray = []
var _failures: PackedStringArray = []
var _steps: Array[Dictionary] = []
var _index: int = -1
var _timer: float = 0.0
var _snapshot: Dictionary = {}

var _unwrapped_heading: float = 0.0
var _last_heading: float = 0.0
var _flap_phase: float = 0.0
var _worst_ground_penetration: float = 0.0
var _saw_nonfinite: bool = false

## Sentinel for "beat the wings rhythmically" rather than a fixed stroke speed.
const FLAP: float = -1.0


func start(player_ref: BirdPlayer, world_ref: WorldBuilder, manager_ref: GameManager) -> void:
	player = player_ref
	world = world_ref
	manager = manager_ref
	player.scripted_command = _command
	_last_heading = player.model.heading
	_build_routine()
	_advance()


## [param reset] is the altitude above the start point to teleport to before the
## step runs, or 0 to continue from wherever the previous step left off. Each
## manoeuvre that needs air under it gets its own clean start, so one bad step
## cannot cascade into a page of misleading failures further down.
func _step(
	name: String, seconds: float, alpha: float, span: float, bank: float,
	stroke: float, check: String, reset: float = 0.0
) -> Dictionary:
	return {
		"name": name, "seconds": seconds, "alpha": alpha, "span": span,
		"bank": bank, "stroke": stroke, "check": check, "reset": reset,
	}


func _build_routine() -> void:
	var trim: float = player.model.alpha_trim
	var stall_edge: float = player.model.alpha_stall * 0.8
	_steps = [
		_step("hands-neutral glide", 8.0, trim, 1.0, 0.0, 0.0, "_check_glide", 320.0),
		_step("sustained flapping", 9.0, trim, 1.0, 0.0, FLAP, "_check_flap_climb", 320.0),
		_step("tuck dive", 6.0, -0.05, 0.12, 0.0, 0.0, "_check_dive", 520.0),
		_step("zoom climb", 4.5, stall_edge, 1.0, 0.0, 0.0, "_check_zoom"),
		_step("hard banked turn", 7.0, trim / cos(1.0), 1.0, 1.0, 0.0, "_check_turn", 420.0),
		_step("deliberate dive into terrain", 14.0, -0.30, 0.3, 0.0, 0.0, "_check_impact", 220.0),
		_step("settle and perch", 18.0, trim, 1.0, 0.0, 0.0, "_check_perch"),
		_step("launch off the perch", 5.0, trim, 1.0, 0.0, FLAP, "_check_launch"),
		_step("catch a smaller bird", 3.0, trim, 1.0, 0.0, 0.0, "_check_caught_prey", 300.0),
		_step("get caught by a bigger bird", 3.0, trim, 1.0, 0.0, 0.0, "_check_was_caught", 300.0),
	]


## Puts the bird back in clean air over the middle of the map, already flying.
func _reset_to(altitude: float) -> void:
	var ground: float = world.height_at(0.0, 0.0)
	player.perched = false
	player.stun_timer = 0.0
	player.model.bank = 0.0
	player.model.heading = 0.0
	player.global_position = Vector3(0.0, ground + altitude, 0.0)
	player.model.velocity = player.model.forward() * player.model.trim_speed()
	player.velocity = player.model.velocity


# --- checks ------------------------------------------------------------------

func _check_glide(before: Dictionary) -> String:
	var lost: float = before["altitude"] - player.altitude()
	if lost <= 0.0:
		return "a pure glide gained %.1f m out of nowhere" % -lost
	if lost > 60.0:
		return "glide sank %.1f m in 8s, far too fast" % lost
	if player.model.is_stalled:
		return "neutral hands stalled the wing"
	return ""


func _check_flap_climb(before: Dictionary) -> String:
	var gained: float = player.altitude() - before["altitude"]
	if gained < 15.0:
		return "9s of flapping only gained %.1f m" % gained
	return ""


func _check_dive(before: Dictionary) -> String:
	if player.airspeed() < 32.0:
		return "a 6s tuck dive only reached %.1f m/s" % player.airspeed()
	if player.altitude() >= before["altitude"]:
		return "the dive did not descend"
	return ""


func _check_zoom(before: Dictionary) -> String:
	var gained: float = player.altitude() - before["altitude"]
	if gained < 25.0:
		return "pulling out of a dive only regained %.1f m" % gained
	return ""


func _check_turn(before: Dictionary) -> String:
	var swept: float = absf(_unwrapped_heading - before["heading_total"])
	if swept < PI:
		return "a 7s hard bank only swept %.0f degrees" % rad_to_deg(swept)
	return ""


func _check_impact(_before: Dictionary) -> String:
	if not player.global_position.is_finite():
		return "position became non-finite after impact"
	var ground: float = world.height_at(player.global_position.x, player.global_position.z)
	if player.global_position.y < ground - 2.5:
		return "the player fell through the terrain"
	return ""


func _check_perch(_before: Dictionary) -> String:
	if not player.perched:
		var ground: float = world.height_at(
			player.global_position.x, player.global_position.z
		)
		return "never came to rest (%.1f m/s, %.1f m above ground)" % [
			player.airspeed(), player.global_position.y - ground
		]
	return ""


## Puts a bird of a given size directly in the player's path so the chase rules
## get exercised without waiting for the AI to oblige.
##
## It is aimed at the player as well as placed in front of them, because a catch
## now requires the hunter to be [i]going for it[/i] — see [method
## GameRules.within_strike]. A predator parked in the player's path with its own
## nose pointing away is not striking anything, and before the cone existed this
## setup was quietly relying on a rule that let it.
func _plant_bird(relative_size: float) -> void:
	if manager.birds.is_empty():
		return
	var bird: BirdNPC = manager.birds[0]
	bird.set_size(player.size * relative_size)
	bird.global_position = player.global_position + player.model.forward() * 2.0
	var toward: Vector3 = (player.global_position - bird.global_position).normalized()
	if toward.is_finite() and toward.length_squared() > 0.5:
		bird.model.heading = atan2(-toward.x, -toward.z)
		bird.model.velocity = toward * bird.model.trim_speed()


func _check_caught_prey(before: Dictionary) -> String:
	if manager.score <= int(before["score"]):
		return "flying through a much smaller bird scored nothing"
	if player.size <= before["size"]:
		return "caught a bird but did not grow (size %.3f)" % player.size
	return ""


func _check_was_caught(before: Dictionary) -> String:
	if player.size >= before["size"]:
		return "flew into a much bigger bird and was not caught (size %.3f)" % player.size
	if player.size < GameRules.MIN_SIZE:
		return "shrank below the minimum size"
	return ""


func _check_launch(_before: Dictionary) -> String:
	if player.perched:
		return "flapping did not get the bird off the ground"
	if player.airspeed() < 4.0:
		return "launched but never got flying (%.1f m/s)" % player.airspeed()
	return ""


# --- driving -----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if player == null or _index >= _steps.size():
		return

	_track_invariants()

	var step: Dictionary = _steps[_index]
	_command.alpha = step["alpha"]
	_command.span = step["span"]
	_command.bank = step["bank"]
	_command.asymmetry = 0.0

	var stroke: float = step["stroke"]
	if stroke < 0.0:
		# A realistic beat: down for 0.25s, recover, repeat.
		_flap_phase = fmod(_flap_phase + delta, 0.55)
		_command.stroke_speed = 3.0 if _flap_phase < 0.25 else 0.0
	else:
		_command.stroke_speed = stroke

	_timer -= delta
	if _timer <= 0.0:
		_complete_step(step)
		_advance()


func _track_invariants() -> void:
	var p: Vector3 = player.global_position
	if not p.is_finite() or not player.model.velocity.is_finite():
		_saw_nonfinite = true
		return
	var heading: float = player.model.heading
	_unwrapped_heading += wrapf(heading - _last_heading, -PI, PI)
	_last_heading = heading

	var ground: float = world.height_at(p.x, p.z)
	_worst_ground_penetration = maxf(_worst_ground_penetration, ground - p.y)


func _complete_step(step: Dictionary) -> void:
	var problem: String = call(step["check"], _snapshot)
	var label: String = step["name"]
	if problem.is_empty():
		_log.append("  ok    %-30s %6.1f m/s  %7.1f m" % [
			label, player.airspeed(), player.altitude()
		])
	else:
		_failures.append("%s: %s" % [label, problem])
		_log.append("  FAIL  %-30s %s" % [label, problem])


func _advance() -> void:
	_index += 1
	if _index >= _steps.size():
		_report()
		return
	var reset: float = _steps[_index]["reset"]
	if reset > 0.0:
		_reset_to(reset)
		_last_heading = player.model.heading
	_timer = _steps[_index]["seconds"]
	_snapshot = {
		"altitude": player.altitude(),
		"speed": player.airspeed(),
		"heading_total": _unwrapped_heading,
		"position": player.global_position,
		"size": player.size,
		"score": manager.score,
	}

	# Chase steps need something to chase, planted after the reset so it lands
	# in front of the bird's new position.
	match _steps[_index]["check"]:
		"_check_caught_prey":
			_plant_bird(0.5)
		"_check_was_caught":
			_plant_bird(2.2)


func _report() -> void:
	player.scripted_command = null
	print("")
	print("=== Soaring flight probe (real world, real collisions) ===")
	for line: String in _log:
		print(line)
	if _saw_nonfinite:
		_failures.append("simulation produced a non-finite state")
	if _worst_ground_penetration > 2.5:
		_failures.append("player sank %.1f m below the terrain" % _worst_ground_penetration)
	print("  final size %.2f, score %d, %d birds aloft" % [
		player.size, manager.score, manager.birds.size()
	])
	if _failures.is_empty():
		print("PROBE PASS")
	else:
		print("PROBE FAILED (%d):" % _failures.size())
		for f: String in _failures:
			print("  - %s" % f)
	finished.emit(_failures.is_empty())
