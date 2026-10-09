extends "res://tests/unit/game/game_fixture.gd"
## The modelled player in a world with geometry (the pacing evidence runs in
## the world area's valley): SimBird.collide_world never lets it through
## static geometry (physics layer 1) - head-on hits stun, glancing ones slide
## - and SimBird.avoid() steers it round what is in its way, as a person
## sees a wall coming. Without these the pilot had shortcuts through houses,
## trees and cliffs that no person has.

const DT := 1.0 / 30.0

var _bodies: Array[Node] = []


func after_each() -> void:
	for b in _bodies:
		if is_instance_valid(b):
			b.queue_free()
	_bodies.clear()
	await super()


## A static box on layer 1 (the world's layer), centred at `pos`.
func _wall(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = pos
	_bodies.append(body)
	return body


func _flier(pos: Vector3, dir: Vector3) -> SimBird:
	var b := make_bird(0.03, pos, dir, true)
	b.collide_world = true
	b.speed = b.cruise_speed()
	b.set_heading(dir)
	return b


func test_head_on_hits_stop_at_the_wall_and_stun() -> void:
	# A wall 1 m thick across the path, its near face at z = -10 (tall: a
	# stunned bird drops, and must not pass under it).
	_wall(Vector3(0, 20, -10.5), Vector3(20, 400, 1))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b := _flier(Vector3(0, 20, 0), Vector3.FORWARD)
	var deepest := 0.0
	var stunned := false
	for i in 90:
		b.fly(Vector3.FORWARD, b.cruise_speed(), DT)
		deepest = minf(deepest, b.global_position.z)
		stunned = stunned or b.stun_left > 0.0
	gt(float(b.world_hits), 0.5, "the bird hit the wall")
	gt(deepest, -10.0 + b.get_body_radius() * SimBird.COLLIDE_RADIUS_FRAC - 0.01, "never inside the wall (deepest z %.3f)" % deepest)
	check(stunned, "a head-on hit stuns")
	metric("head_on", {"hits": b.world_hits, "deepest_z": deepest})


func test_glancing_hits_slide_along() -> void:
	# A wall along the path, the bird angling into it at ~15 deg.
	_wall(Vector3(1.5, 20, -20), Vector3(1, 20, 60))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var dir := Vector3(sin(deg_to_rad(15.0)), 0, -cos(deg_to_rad(15.0)))
	var b := _flier(Vector3(0, 20, 0), dir)
	var max_x := -INF
	for i in 60:
		b.fly(dir, b.cruise_speed(), DT)
		max_x = maxf(max_x, b.global_position.x)
	gt(float(b.world_hits), 0.5, "(setup) the bird touched the wall")
	lt(max_x, 1.0 - b.get_body_radius() * SimBird.COLLIDE_RADIUS_FRAC + 0.01, "never inside the wall")
	lt(b.global_position.z, -8.0, "it slid on along the wall")
	gt(b.speed, b.cruise_speed() * 0.5, "a glancing hit keeps most of the speed")


func test_avoid_steers_round_a_wall_in_the_way() -> void:
	_wall(Vector3(0, 20, -10.5), Vector3(20, 20, 1))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b := _flier(Vector3(0, 20, -5), Vector3.FORWARD)
	var w := b.avoid(Vector3.FORWARD)
	gt(w.y, 0.2, "a wall ahead: the wanted direction turns up (over it)")
	lt(w.dot(Vector3.FORWARD), 0.95, "... and away from straight on")
	# Nothing in the way: unchanged.
	var clear := _flier(Vector3(100, 20, 0), Vector3.FORWARD)
	eq(clear.avoid(Vector3.FORWARD), Vector3.FORWARD, "no obstacle: the pilot's wish stands")
	# Off (the default, mirror sky): never consulted.
	clear.collide_world = false
	b.collide_world = false
	eq(b.avoid(Vector3.FORWARD), Vector3.FORWARD, "collide_world off: avoid() is a no-op")


func test_a_wedged_pilot_finds_the_way_out() -> void:
	# A deep box open only at its front (a barn with one door): the bird flies
	# in, then wants something beyond the back wall. Pressing on, bouncing off
	# walls, ceiling and floor, would keep it in there for the rest of the run
	# (a round-2 calibration run spent 46 minutes like that); a person looks
	# for the way out and takes it.
	var c := Vector3(0, 20, -19)
	_wall(c + Vector3(0, 0, -8.25), Vector3(4.5, 4.5, 0.5))  # back
	_wall(c + Vector3(-2.25, 0, 0), Vector3(0.5, 4.5, 16.5))  # left
	_wall(c + Vector3(2.25, 0, 0), Vector3(0.5, 4.5, 16.5))  # right
	_wall(c + Vector3(0, 2.25, 0), Vector3(4.5, 0.5, 16.5))  # ceiling
	_wall(c + Vector3(0, -2.25, 0), Vector3(4.5, 0.5, 16.5))  # floor
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b := _flier(Vector3(0, 20, 2), Vector3.FORWARD)
	b.ground_y = -INF
	# In through the opening (z = -11), straight, to the far end.
	while b.global_position.z > -22.0:
		b.fly(Vector3.FORWARD, b.cruise_speed(), DT)
	var pilot := SimPilot.new(&"competent", 3)
	var got_out := -1.0
	var backed := false
	for i in int(30.0 / DT):
		pilot.search(b, Vector3(0, 20, -80), DT)
		backed = backed or b.escaping
		if got_out < 0.0 and b.global_position.z > -10.5:
			got_out = i * DT
	metric("wedged", {"got_out_s": got_out, "stuck_s": b.stuck_s, "hits": b.world_hits})
	check(backed, "the pilot noticed it was wedged (in contact, going nowhere)")
	gt(got_out, 0.0, "...and got out through the opening")
	lt(got_out, 20.0, "...within 20 s")


func test_avoid_leaves_the_ground_to_the_ground_guard() -> void:
	# Stooping on prey near the ground, the look-ahead meets the ground: that
	# is not an obstacle to turn from (the ground guard keeps the bird's
	# clearance, pull-out aware, as every NPC's). Seen as one, it stopped every
	# low chase in the valley.
	_wall(Vector3(0, -0.5, 0), Vector3(200, 1, 200))  # the ground, top at y = 0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b := _flier(Vector3(0, 2, 0), Vector3(0, -0.3, -1).normalized())
	b.velocity = Vector3(0, -0.3, -1).normalized() * b.cruise_speed()
	var want := Vector3(0, -0.3, -1).normalized()
	var hit := b.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
			b.global_position, b.global_position + want * b.cruise_speed(), 1))
	check(not hit.is_empty(), "(setup) the look-ahead meets the ground")
	vnear(b.avoid(want), want, 1e-5, "the ground is not an obstacle: the stoop stands")


func test_a_stall_on_the_ground_takes_off() -> void:
	# A stalled bird drops its nose to regain speed; on the ground (or the
	# lake) it cannot, and the ground clamp kept a modelled player crawling
	# along at 1.5 m/s for 48 minutes of a calibration run. A person flaps
	# and takes off.
	var b := make_bird(0.03, Vector3(0, 0.05, 0), Vector3.FORWARD, true)
	b.ground_y = 0.0
	b.speed = 1.2
	b.set_heading(Vector3.FORWARD)
	var slowest_late := INF
	var travelled := 0.0
	for i in 60:
		var before := b.global_position
		b.fly(Vector3.FORWARD, b.cruise_speed(), DT)
		travelled += before.distance_to(b.global_position)
		if i >= 30:
			slowest_late = minf(slowest_late, b.speed)
	gt(float(b.ground_launches), 0.5, "the stalled player took off")
	gt(slowest_late, b.min_speed() * 0.95, "...and keeps flying speed (no crawl)")
	gt(travelled, 2.0 * b.min_speed(), "...covering flying distance in 2 s")


func test_a_bird_pinned_inside_geometry_is_pushed_out() -> void:
	# A bird shut in a pocket no bigger than itself (a crevice under a rock:
	# every cast hits at once and it cannot move): within about SimBird.PIN_S
	# it is moved to the nearest free spot and flies on - it never sits there
	# for the rest of the run (a fix round 3 valley run did, for 39 minutes).
	var c0 := Vector3(0, 20, 0)
	var h := 0.16 * SizeRules.wingspan_for_mass(0.03) * SimBird.COLLIDE_RADIUS_FRAC + 0.002
	for ax in 3:
		for sgn in [-1.0, 1.0]:
			var off := Vector3.ZERO
			off[ax] = sgn * (h + 0.25)
			var sz := Vector3(1.2, 1.2, 1.2)
			sz[ax] = 0.5
			_wall(c0 + off, sz)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b := _flier(c0, Vector3.FORWARD)
	var start := b.global_position
	var freed_at := -1.0
	for i in int((SimBird.PIN_S + 2.0) / DT):
		b.fly(Vector3.FORWARD, b.cruise_speed(), DT)
		if freed_at < 0.0 and b.unpins > 0:
			freed_at = i * DT
	eq(b.unpins, 1, "pushed out once")
	between(freed_at, SimBird.PIN_S - 0.2, SimBird.PIN_S + 0.5, "after about PIN_S pinned")
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := SphereShape3D.new()
	sh.radius = b.get_body_radius() * SimBird.COLLIDE_RADIUS_FRAC
	q.shape = sh
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, b.global_position)
	check(b.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty(), "out in open air")
	gt(b.global_position.distance_to(start), 1.5, "and away from where it was stuck")
	# Flying on in open air, it is never moved again.
	for i in int(10.0 / DT):
		b.fly(b.heading, b.cruise_speed(), DT)
	eq(b.unpins, 1, "a free flier is never pushed")


func test_line_of_sight() -> void:
	# The pilot loses a bird that is behind a hedge, a house or a tree (it
	# then ends that chase instead of grinding into what is between).
	_wall(Vector3(0, 20, -5), Vector3(4, 4, 0.5))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b := _flier(Vector3(0, 20, 0), Vector3.FORWARD)
	check(not b.sees(Vector3(0, 20, -10)), "a bird behind the wall is out of sight")
	check(b.sees(Vector3(6, 20, -10)), "one beside it is in sight")
	b.collide_world = false
	check(b.sees(Vector3(0, 20, -10)), "open air (no collisions): always in sight")
