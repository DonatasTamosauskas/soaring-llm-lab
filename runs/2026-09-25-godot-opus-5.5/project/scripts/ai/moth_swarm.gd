class_name MothSwarm
extends Node3D
## A loose swarm of SwarmMoths drifting in open air (core loop round: the
## sky's pellets - see SwarmMoth and MothField).
##
## Every moth keeps a place in a loose, slowly turning cloud round the
## swarm's centre, flutters about it, and moves towards it no faster than
## MOTH_SPEED (a sparrow cruises at 9 m/s: a moth is taken by flying into
## it). The centre wanders slowly within ANCHOR_R of the swarm's anchor
## (MothField puts the anchor in open air, clear of the world's geometry by
## more than the cloud). "Barely fleeing": a moth notices a bird that can eat
## it only within AWARE_M and coming at it, only after REACT_S, and then
## darts DART_S sideways at DART_SPEED - once every DART_COOL_S at most (its
## stamina) - and flutters back. A lesson swarm (`lesson`) never darts.

const RADIUS := 2.6
const FLATTEN := 0.55
## The cloud turns this fast (rad/s) about a slowly wandering axis.
const SPIN := 0.25
## How far the centre wanders from its anchor (m), and how fast (m/s).
const ANCHOR_R := 4.0
const DRIFT_SPEED := 0.5
## The flutter round each moth's place (m) and its rate (Hz, per axis).
const FLUTTER_M := 0.3
const FLUTTER_HZ := Vector3(1.7, 2.3, 1.3)
## A moth moves towards its place at most this fast (m/s)...
const MOTH_SPEED := 2.2
## ...and follows it with this time constant (s).
const FOLLOW_TAU := 0.35
const AWARE_M := 2.5
const REACT_S := 0.35
const DART_SPEED := 3.5
const DART_S := 0.45
const DART_COOL_S := 4.0
## Birds are looked for round the swarm every this many ticks (a bird that
## could reach a moth before the next look is further than this covers).
const LOOK_EVERY := 3

var anchor := Vector3.ZERO
var centre := Vector3.ZERO
## A lesson swarm (MothField.request_lesson): unaware, it never darts.
var lesson := false
var moths: Array[SwarmMoth] = []
## Seconds since the swarm was (re)placed.
var age := 0.0
## Moths caught out of this swarm since it was placed.
var eaten := 0
var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _drift := Vector3.ZERO
var _drift_t := 0.0
var _look_i := 0
var _near: Array[Bird] = []


func _init(seed_value: int = 1) -> void:
	name = "MothSwarm"
	_rng.seed = seed_value


## Put the swarm at `at` with n moths of mass m (moths it already has are
## re-used; missing ones are made).
func place(at: Vector3, n: int, m: float) -> void:
	anchor = at
	centre = at
	age = 0.0
	eaten = 0
	_drift = Vector3.ZERO
	_drift_t = 0.0
	while moths.size() > n:
		var x: SwarmMoth = moths.pop_back()
		x.swarm = null
		x.queue_free()
	for i in n:
		var mo: SwarmMoth
		if i < moths.size():
			mo = moths[i]
		else:
			mo = SwarmMoth.new()
			mo.name = "Moth_%d" % i
			mo.swarm = self
			moths.append(mo)
			add_child(mo)
		var d := Vector3(_rng.randfn(), _rng.randfn() * FLATTEN, _rng.randfn()).normalized()
		mo.setup(m * _rng.randf_range(0.93, 1.07), d * pow(_rng.randf(), 1.0 / 3.0),
				Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU))
		mo.swarm = self
		mo.lesson = lesson
		var p := at + mo.slot * RADIUS
		mo.place(p, Vector3.ZERO, 0.0)
		# (A moth placed afresh is not a flight path: the catch pass must not
		# sweep it from where it was eaten or last flew.)
		var gl := GameLoop.find(get_tree()) if is_inside_tree() else null
		if gl != null:
			gl.teleported(mo)


## Live moths in the swarm.
func alive_count() -> int:
	var n := 0
	for mo in moths:
		if mo.alive:
			n += 1
	return n


## A moth of this swarm was eaten (SwarmMoth.on_caught): it stays out of
## play, hidden, until the swarm is placed again.
func on_moth_caught(_mo: SwarmMoth, _by: Bird) -> void:
	eaten += 1


func step(dt: float) -> void:
	if dt <= 0.0:
		return
	_t += dt
	age += dt
	# The centre wanders round its anchor.
	_drift_t -= dt
	if _drift_t <= 0.0:
		_drift_t = _rng.randf_range(2.0, 4.0)
		var want := anchor + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.4, 0.4), _rng.randf_range(-1, 1)) * ANCHOR_R
		_drift = (want - centre).limit_length(1.0) * DRIFT_SPEED * (0.4 if lesson else 1.0)
	centre += _drift * dt
	if centre.distance_to(anchor) > ANCHOR_R:
		centre = anchor + (centre - anchor).limit_length(ANCHOR_R)
	# Who is near (every LOOK_EVERY ticks): birds that could eat a moth.
	_look_i += 1
	if _look_i >= LOOK_EVERY or _near.is_empty():
		_look_i = 0
		_near.clear()
		if not lesson:
			var r := RADIUS + AWARE_M + 6.0
			for b in Birds.all():
				if b is SwarmMoth or not b.alive:
					continue
				if b.get_body_position().distance_squared_to(centre) < r * r:
					_near.append(b)
	var axis := Vector3(sin(_t * 0.11) * 0.5, 1.0, cos(_t * 0.13) * 0.5).normalized()
	var rot := Basis(axis, _t * SPIN)
	var k := 1.0 - exp(-dt / FOLLOW_TAU)
	for mo in moths:
		if not mo.alive:
			continue
		var p := mo.global_position
		var fl := Vector3(sin(_t * FLUTTER_HZ.x * TAU + mo.phase.x), sin(_t * FLUTTER_HZ.y * TAU + mo.phase.y) * 0.6,
				sin(_t * FLUTTER_HZ.z * TAU + mo.phase.z)) * FLUTTER_M
		var want_p := centre + rot * mo.slot * RADIUS + fl
		var v := mo.velocity
		mo.dart_cool = maxf(mo.dart_cool - dt, 0.0)
		if mo.dart_left > 0.0:
			mo.dart_left -= dt
			v = mo.dart_dir * DART_SPEED
			if mo.dart_left <= 0.0:
				mo.threat = null
		else:
			var nv := ((want_p - p) / FOLLOW_TAU).limit_length(MOTH_SPEED)
			v = v.lerp(nv, k)
			if not lesson and not _near.is_empty():
				_sense(mo, p, dt)
		mo.place(p + v * dt, v, dt)


## A bird that can eat the moth within AWARE_M and coming at it: after
## REACT_S the moth darts across its line (if it has the stamina).
func _sense(mo: SwarmMoth, p: Vector3, dt: float) -> void:
	var worst: Bird = null
	var worst_d := AWARE_M
	for b in _near:
		if not is_instance_valid(b) or not b.alive or not SizeRules.can_eat(b.mass, mo.mass):
			continue
		var rel := p - b.get_body_position()
		var d := rel.length()
		if d >= worst_d or d < 1e-3:
			continue
		if (b.velocity - mo.velocity).dot(rel / d) < 1.0:
			continue
		worst = b
		worst_d = d
	if worst == null:
		mo.noticed_for = 0.0
		return
	mo.noticed_for += dt
	if mo.noticed_for < REACT_S or mo.dart_cool > 0.0:
		return
	var u := worst.velocity.normalized() if worst.velocity.length() > 0.3 else (p - worst.get_body_position()).normalized()
	var rel2 := p - worst.get_body_position()
	var lat := rel2 - u * rel2.dot(u)
	if lat.length() < 0.05:
		lat = u.cross(Vector3.UP)
		if lat.length() < 0.05:
			lat = Vector3.RIGHT
		lat *= 1.0 if _rng.randf() < 0.5 else -1.0
	mo.dart_dir = (lat.normalized() + Vector3.UP * _rng.randf_range(-0.4, 0.4)).normalized()
	mo.dart_left = DART_S
	mo.dart_cool = DART_COOL_S
	mo.noticed_for = 0.0
	mo.threat = worst
