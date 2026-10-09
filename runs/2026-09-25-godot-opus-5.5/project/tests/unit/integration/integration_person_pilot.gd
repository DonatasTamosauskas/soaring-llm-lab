extends "res://tests/unit/integration/integration_chase_pilot.gd"
## TEST-ONLY: the chase pilot plus what a person's eyes add to it - it sees
## an obstacle in the flight path and steers round it (the game loop's
## modelled player does the same: SimBird.avoid). Used by
## integration_person.gd, the whole-game "competent person".
##
## Steering round: a ray AVOID_LOOK_S of flight ahead along the path and
## along the way the pilot wants to go (physics layer 1, the world's static
## geometry); a wall-like hit (a house, a trunk, a cliff) bends the goal away
## from the surface and the pilot climbs over it, the harder the nearer.
## Ground-like hits (terrain, a roof seen from above) are left to the height
## hold, which already keeps clear of the ground ahead.

const AVOID_LOOK_S := 1.2
const GROUND_NORMAL_Y := 0.7
## Wedged anyway (a corner between a tower and a nave, a room): no metre
## made in STUCK_S -> back out and climb for UNSTICK_S, as a person would
## (the soak's plain pilot sat 13 minutes in the church's corner, twice).
const STUCK_S := 3.0
const STUCK_M := 1.0
const UNSTICK_S := 2.5
## Wedged again where the last way out was tried (core loop round): every
## second try the person drops out instead - wings still, nose down - as
## anyone would under an eave or in a notch whose way out climbing does not
## find: a flapping, climbing bot hung under the eaves of a village house
## (pressed against the wall, 1-2 m/s "flying") for ten and twenty minutes of
## two real-chain runs (cl_it6 full 104, cl3_it8 quest 101).
const UNSTICK_AGAIN_M := 2.0
## Wedged inside a room (core loop fix round 1: a sparrow that had flown in
## through a window of a village house hung in the ~8 m room for 14 minutes
## of a real-chain run, and a swallow for 9 minutes of another - the ways out
## that 16 bearings level and 40 deg up find are the room's corners): walls
## within ROOM_M every way round and a ceiling within ROOM_M above -> the
## person looks round properly for the window it came in by - ROOM_BEARINGS
## bearings at ROOM_UPS - and flies out along the longest free line for
## UNSTICK_ROOM_S, never dropping to the floor.
const ROOM_M := 10.0
const ROOM_BEARINGS := 64
const ROOM_UPS: Array[float] = [-0.35, -0.2, -0.1, 0.0, 0.1, 0.2, 0.35]
const UNSTICK_ROOM_S := 5.0

var space: PhysicsDirectSpaceState3D = null
## Radians the person still turns its whole body on the spot (integration_bot:
## standing, the heading follows the torso). Set by the person when it has
## come down wedged (integration_person.gd).
var torso_turn := 0.0
## Diagnostics: ticks on which something was in the way, and unsticks.
var avoid_ticks := 0
var unsticks := 0
var unsticking := false
var _stuck_ref := Vector3.INF
var _stuck_t := 0.0
var _unstick_left := 0.0
var _unstick_dir := Vector3.ZERO
var _unstick_at := Vector3.INF
var _unstick_tries := 0
## This unstick drops out (wings still, nose down) rather than climbing.
var dropping := false
## Unsticks that found the bird in a room (diagnostics).
var room_exits := 0
var _rng := RandomNumberGenerator.new()


func _init(p_params: FlightParams = null, p_course: FlightCourse = null) -> void:
	super(p_params, p_course)
	_rng.seed = 7919


func update(pos: Vector3, vel_raw: Vector3, airspeed: float, dt: float) -> void:
	if _stuck_ref == Vector3.INF or pos.distance_to(_stuck_ref) > STUCK_M:
		_stuck_ref = pos
		_stuck_t = 0.0
	else:
		_stuck_t += dt
	if _stuck_t > STUCK_S and _unstick_left <= 0.0:
		unsticks += 1
		_stuck_t = 0.0
		if _unstick_at != Vector3.INF and pos.distance_to(_unstick_at) < UNSTICK_AGAIN_M:
			_unstick_tries += 1
		else:
			_unstick_tries = 0
		_unstick_at = pos
		dropping = _unstick_tries % 2 == 1
		_unstick_left = UNSTICK_S
		if _in_room(pos):
			room_exits += 1
			dropping = false
			_unstick_dir = _window(pos)
			_unstick_left = UNSTICK_ROOM_S
		else:
			_unstick_dir = _most_open(pos, vel_raw, dropping)
	unsticking = _unstick_left > 0.0
	if unsticking:
		_unstick_left -= dt
		# Out along the escape line, climbing (the prey, if any, waits) - or,
		# tried there before, dropping out along it.
		var keep_prey := prey
		var keep_target := target
		var keep_chase := chase
		prey = null
		target = pos + _unstick_dir * 40.0
		chase = true
		super.update(pos, vel_raw, airspeed, dt)
		prey = keep_prey
		target = keep_target
		chase = keep_chase
		if dropping:
			flapping = false
			effort = 0.0
			tuck = false
			pitch = -0.6
		return
	dropping = false
	super.update(pos, vel_raw, airspeed, dt)


## The most open way out of where the bird is wedged, as a person looks
## round for it: rays in 16 bearings, level and 40 deg up (dropping: level
## and 27 deg down), the longest free one (up - or down - a little preferred;
## a fresh random start so a pocket that only opens one way is found from any
## side).
func _in_room(pos: Vector3) -> bool:
	if space == null:
		return false
	for d: Vector3 in [Vector3.UP, Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK,
			Vector3(1, 0, 1).normalized(), Vector3(-1, 0, 1).normalized(), Vector3(1, 0, -1).normalized(),
			Vector3(-1, 0, -1).normalized()]:
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(pos, pos + d * ROOM_M, 1)).is_empty():
			return false
	return true


## The way out of a room: the longest free line of a fine look round.
func _window(pos: Vector3) -> Vector3:
	var best := Vector3.UP
	var best_d := -1.0
	for k in ROOM_BEARINGS:
		var a := TAU * k / float(ROOM_BEARINGS)
		for up in ROOM_UPS:
			var d := Vector3(cos(a), up, sin(a)).normalized()
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pos, pos + d * 40.0, 1))
			var free := 40.0 if hit.is_empty() else pos.distance_to(hit["position"])
			if free > best_d:
				best_d = free
				best = d
	return best


func _most_open(pos: Vector3, vel: Vector3, down := false) -> Vector3:
	var h := Vector3(vel.x, 0.0, vel.z)
	var fallback := (-h.normalized() if h.length() > 0.2 else Vector3(-sin(heading), 0.0, -cos(heading))) + Vector3.UP * 0.8
	if space == null:
		return fallback.normalized()
	var best := fallback.normalized()
	var best_d := -1.0
	var a0 := _rng.randf() * TAU
	for k in 16:
		var a := a0 + TAU * k / 16.0
		for up: float in ([0.0, -0.5] if down else [0.0, 0.84]):
			var d := Vector3(cos(a), up, sin(a)).normalized()
			var q := PhysicsRayQueryParameters3D.create(pos, pos + d * 25.0, 1)
			var hit := space.intersect_ray(q)
			var free := 25.0 if hit.is_empty() else pos.distance_to(hit["position"])
			free *= 1.0 + 0.15 * absf(up)
			if free > best_d:
				best_d = free
				best = d
	return best


func steer_round(pos: Vector3, vel: Vector3, goal: Vector3) -> Vector3:
	climb_bonus = 0.0
	if space == null:
		return goal
	var v := vel.length()
	var span := params.span
	var look := clampf(maxf(v, params.v_c) * AVOID_LOOK_S, 3.0 * span + 1.0, 40.0)
	var to := goal - pos
	to.y = 0.0
	var want := to.normalized() if to.length_squared() > 1e-6 else Vector3(vel.x, 0.0, vel.z).normalized()
	if want.length_squared() < 1e-6:
		return goal
	var vdir := vel / v if v > 0.3 else want
	var out := want
	var hit_any := false
	for dir: Vector3 in [vdir, want]:
		var q := PhysicsRayQueryParameters3D.create(pos, pos + dir * look, 1)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		if n.y > GROUND_NORMAL_Y:
			continue
		hit_any = true
		var urgency := clampf(1.0 - pos.distance_to(hit["position"]) / look, 0.0, 1.0)
		var nh := Vector3(n.x, 0.0, n.z).normalized() if Vector2(n.x, n.z).length() > 1e-3 else -dir
		out -= nh * minf(out.dot(nh), 0.0)
		out += nh * (0.3 + urgency * 1.7)
		out.y = 0.0
		out = out.normalized() if out.length_squared() > 1e-8 else nh
		climb_bonus = maxf(climb_bonus, (0.5 + urgency) * maxf(4.0, 3.0 * span))
	if not hit_any:
		return goal
	avoid_ticks += 1
	return pos + out * maxf(to.length(), look)
