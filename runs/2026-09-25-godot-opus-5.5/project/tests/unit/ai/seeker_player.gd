extends Bird
## TEST-ONLY player that hunts, the way a person plays (adapted from the
## round-3 verifier's probe tests/probes/ai/r3x_seeker_player.gd; MockPlayer
## only flies scripted laps and never chases anything). It flies the NPCs'
## own NpcFlight physics at its mass (SizeRules.performance), searches in
## laps low over the valley where its prey lives, and pursues the nearest
## worthwhile, not-hidden prey inside GameLoop's highlight range
## (max(70 spans, 6 s of cruise)) with a lead. It gives a chase up after
## chase_limit_s and leaves that bird alone for 20 s. With `collide` its body
## sweeps against layer-1 geometry and slides along what it hits (the
## player's rig collides too); it never goes for hidden birds.
## The view direction is the gaze: at its quarry while chasing, else along
## its flight.

var flight: NpcFlight
var world: World
var target: NpcBird = null
var view_dir := Vector3.FORWARD
var protect_s := 5.0
var times_caught := 0
var collide := true
var wall_hits := 0
## false: flies its search laps but starts no chase (warm-up).
var active := true
var grow := false
var t := 0.0
## {t, species, fled, targeted}
var catches: Array = []
## {t0, t1, species, reason, fled, in_awareness, min_d}
var pursuits: Array = []
var search_center := Vector3.ZERO
var search_r := 70.0
var search_agl := 8.0
var sense_r := 50.0
var chase_limit_s := 12.0
var _ang := 0.0
var _protect_left := 0.0
var _retarget_t := 0.0
var _chase_t := 0.0
var _blacklist := {}
var _cur := {}


func is_player() -> bool:
	return true


func get_view_direction() -> Vector3:
	return view_dir


func setup(w: World, pm: float, center: Vector3) -> void:
	world = w
	search_center = Vector3(center.x, 0.0, center.z)
	_apply_mass(pm)
	var p0 := search_center + Vector3(search_r, 0, 0)
	p0.y = w.ground_height(p0.x, p0.z) + search_agl
	global_position = p0
	flight.set_velocity(Vector3(0, 0, -1) * flight.cruise)
	velocity = flight.air_velocity()


func _apply_mass(pm: float) -> void:
	mass = pm
	species = SizeRules.species_for_mass(pm)
	var keep := flight
	flight = NpcFlight.new(pm, float(SpeciesProfile.of(species)["glide_ratio"]))
	if keep != null:
		flight.set_velocity(keep.air_velocity())
	var span := SizeRules.wingspan_for_mass(pm)
	sense_r = maxf(70.0 * span, 6.0 * SizeRules.cruise_speed(pm))
	search_agl = clampf(3.0 + 20.0 * span, 6.0, 40.0)
	search_r = clampf(40.0 + 60.0 * span, 50.0, 150.0)
	chase_limit_s = clampf(10.0 * SizeRules.time_scale(pm), 10.0, 30.0)


func eligible(n: NpcBird) -> bool:
	return is_instance_valid(n) and n.alive and n.is_inside_tree() and not n.hidden \
			and n.state != NpcBird.State.HIDE and SizeRules.can_eat(mass, n.mass) \
			and SizeRules.is_worthwhile(mass, n.mass)


func _nearest_prey(npcs: Array) -> Array:
	var best: NpcBird = null
	var bd := INF
	for n in npcs:
		if not eligible(n) or _blacklist.get(n.get_instance_id(), -1.0) > t:
			continue
		var d := global_position.distance_to(n.global_position)
		if d < bd:
			bd = d
			best = n
	return [best, bd]


func _end(reason: String) -> void:
	if not _cur.is_empty():
		_cur["t1"] = t
		_cur["reason"] = reason
		pursuits.append(_cur)
	if is_instance_valid(target) and reason != "caught":
		_blacklist[target.get_instance_id()] = t + 20.0
	_cur = {}
	target = null
	_chase_t = 0.0


func step(dt: float, npcs: Array) -> void:
	t += dt
	if _protect_left > 0.0:
		_protect_left -= dt
		if _protect_left <= 0.0:
			set_meta(&"npc_ignore", false)
	var pp := global_position
	if target != null:
		if not is_instance_valid(target) or not target.alive or not target.is_inside_tree():
			_end("gone")
		elif target.hidden or target.state == NpcBird.State.HIDE:
			_end("hid")
		else:
			_chase_t += dt
			var d := pp.distance_to(target.global_position)
			_cur["min_d"] = minf(_cur["min_d"], d)
			if target.threat == self and target.state == NpcBird.State.FLEE:
				_cur["fled"] = true
			if d < float(target.profile.get("awareness_m", 20.0)):
				_cur["in_awareness"] = true
			if _chase_t > chase_limit_s:
				_end("timeout")
			elif d > sense_r * 1.6:
				_end("outran")
	if not active:
		if target != null:
			_end("inactive")
	else:
		_retarget_t -= dt
		if target == null and _retarget_t <= 0.0:
			_retarget_t = 0.25
			var r := _nearest_prey(npcs)
			if r[0] != null and r[1] <= sense_r:
				target = r[0]
				_chase_t = 0.0
				_cur = {"t0": t, "species": String(target.species), "reason": "", "fled": false,
					"in_awareness": false, "min_d": r[1]}
	var want := Vector3.ZERO
	var want_speed := flight.cruise
	var effort := 0.6
	if target != null:
		var tp := target.global_position
		var tv := target.velocity
		var rel := tp - pp
		var d := rel.length()
		var closing := maxf(-(tv - flight.air_velocity()).dot(rel / maxf(d, 0.01)), 1.0)
		var aim := tp + tv * clampf(d / closing, 0.0, 1.2)
		aim.y = maxf(aim.y, world.ground_height(aim.x, aim.z) + 0.6)
		want = aim - pp
		want_speed = flight.max_speed
		effort = 1.0
	else:
		# Search laps round the search centre, low where the prey lives.
		_ang += flight.speed / search_r * dt
		var c := search_center + Vector3(cos(_ang + 0.35) * search_r, 0.0, sin(_ang + 0.35) * search_r)
		c.y = world.ground_height(c.x, c.z) + search_agl
		want = c - pp
	if not world.is_inside(pp + want.normalized() * 20.0):
		want = Vector3(-pp.x, 0.0, -pp.z)
	flight.step(dt, want, want_speed, effort, 0.0)
	var v := flight.air_velocity()
	var np := pp + v * dt
	if collide:
		np = _sweep(pp, np)
	var g2 := world.ground_height(np.x, np.z) + 0.8
	if np.y < g2:
		np.y = g2
		if flight.gamma < 0.0:
			flight.gamma = 0.0
			flight.q = 0.0
	velocity = (np - pp) / dt
	# (Not looking straight up or down: Basis.looking_at warns about a
	# target colinear with UP - a stop against a roof leaves only a vertical
	# slide.)
	if velocity.x * velocity.x + velocity.z * velocity.z > 0.01:
		global_transform = Transform3D(Basis.looking_at(velocity.normalized(), Vector3.UP), np)
	else:
		global_position = np
	view_dir = (target.global_position - np).normalized() if target != null else Vector3(v.x, 0.0, v.z).normalized()


func _sweep(pp: Vector3, np: Vector3) -> Vector3:
	var mv := np - pp
	var ml := mv.length()
	if ml < 1e-6:
		return np
	var r := get_body_radius()
	var sp := world.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pp, np + mv / ml * r, 1)
	var hit := sp.intersect_ray(q)
	if hit.is_empty():
		return np
	var n: Vector3 = hit["normal"]
	var hp: Vector3 = hit["position"]
	if n.y > 0.6 and absf(hp.y - world.ground_height(hp.x, hp.z)) < 0.3:
		return np
	wall_hits += 1
	var stop := maxf(hp.distance_to(pp) - r - 0.02, 0.0)
	var v := flight.air_velocity()
	v -= n * minf(v.dot(n), 0.0) * 1.05
	if v.length() < flight.min_speed:
		v = (v + n * flight.min_speed).normalized() * flight.min_speed
	flight.set_velocity(v)
	return pp + mv / ml * stop + n * 0.01


func on_caught(by: Bird) -> void:
	if _protect_left > 0.0:
		return
	times_caught += 1
	_protect_left = protect_s
	set_meta(&"npc_ignore", true)


func on_ate(prey: Bird, _gain: float) -> void:
	var n := prey as NpcBird
	catches.append({"t": t, "species": String(prey.species), "fled": n != null and n.threat == self,
		"targeted": prey == target})
	if prey == target:
		_end("caught")
	if grow:
		_apply_mass(mass + SizeRules.meal_gain(mass, prey.mass))
