extends "res://tests/unit/ai/ai_sim.gd"
## A5 regression tests for the geometry traps found in the world area's
## real valley. Each was fixed at its cause; these pin the fixes with a small
## purpose-built world, so they cannot come back unnoticed (the real-valley
## check itself is a dev scene: the world area's scene still changes).
##  1. A body whose centre ends up inside a solid (convex) shape - a foliage
##     clump - leaves it along the surface normal at once (pushing "away from
##     the contact point" used to drive it deeper in: a starling spent 40 s
##     inside a tree).
##  2. Sliding along a wall at a grazing angle never lets the body overlap it
##     (sweep + push-out), nor pass through it.
##  3. A perch whose seat is buried in a solid is never offered or chosen.
##  4. Cover behind an opening is entered from the open side - whichever way
##     the world author's opening normal points - never through the trunk a
##     nest box hangs on.
##  5. A bird wedged where no steering gets it out (a dead end narrower than
##     its turn; the round-3 verifier found a tired hawk held for 160 s in a
##     pocket among overlapping crowns) backs out the way it came; one with
##     no way out at all is taken out of play by the Ecosystem, unseen.
##  6. A bird low under a roof or a crown holds its height and flies out
##     from under it: its ground clearance must not press it up into it.

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")


class TrapWorld extends World:
	const CLUMP := Vector3(0, 12, 0)
	const CLUMP_R := 3.0
	const WALL_X := 40.0
	const TRUNK := Vector3(-40, 8, 0)
	const TRUNK_HALF := 0.8
	const BOX_S := 0.36
	const HOLE := 0.1
	## A dead-end tunnel along X, open at +X (inside 1.3 x 1.3 m, 9 m deep)
	## and a sealed 2-m box, both far from everything else.
	const TUNNEL := Vector3(-90, 20, 60)
	const TUNNEL_L := 9.0
	const TUNNEL_W := 1.3
	const SEALED := Vector3(90, 20, 60)
	## A flat roof 30 x 30 m whose underside is 3 m above the ground (a
	## crown or an eave over a low bird), far from everything else.
	const ROOF := Vector3(0, 3.2, -100)
	const ROOF_W := 30.0
	var flip_normal := false
	var refuges: Array[Dictionary] = []
	var landmarks: Array[Dictionary] = []
	var _body: StaticBody3D
	var box_c := Vector3.ZERO
	var buried: Perch
	var open_perch: Perch
	var hedge_top: Perch

	func _generate() -> void:
		bounds_radius = 300.0
		ceiling = 150.0
		_body = StaticBody3D.new()
		_body.collision_layer = 1
		_body.collision_mask = 0
		add_child(_body)
		# A tree: trunk and a round foliage clump (a convex solid).
		_box(Vector3(0, 4.5, 0), Vector3(0.5, 9.0, 0.5))
		var s := SphereShape3D.new()
		s.radius = CLUMP_R
		_shape(s, CLUMP)
		# A long, tall wall to slide along (40 m x 60 m).
		_box(Vector3(WALL_X, 30, 0), Vector3(0.4, 60, 40))
		# A thick trunk with a nest box on its +X side, hole facing +X.
		_box(TRUNK, Vector3(TRUNK_HALF * 2.0, 16, TRUNK_HALF * 2.0))
		var t := 0.03
		box_c = TRUNK + Vector3(TRUNK_HALF + BOX_S * 0.5 + t, 0, 0)
		var c := box_c
		_box(c + Vector3(-BOX_S * 0.5, 0, 0), Vector3(t, BOX_S, BOX_S))
		_box(c + Vector3(0, 0, BOX_S * 0.5), Vector3(BOX_S, BOX_S, t))
		_box(c + Vector3(0, 0, -BOX_S * 0.5), Vector3(BOX_S, BOX_S, t))
		_box(c + Vector3(0, BOX_S * 0.5 + t, 0), Vector3(BOX_S + 0.08, t * 2.0, BOX_S + 0.08))
		_box(c + Vector3(0, -BOX_S * 0.5, 0), Vector3(BOX_S, t, BOX_S))
		var fx := c.x + BOX_S * 0.5
		var side := (BOX_S * 0.5 - HOLE * 0.5)
		_box(Vector3(fx, c.y + (BOX_S * 0.5 + HOLE * 0.5) * 0.5, c.z), Vector3(t, side, BOX_S))
		_box(Vector3(fx, c.y - (BOX_S * 0.5 + HOLE * 0.5) * 0.5, c.z), Vector3(t, side, BOX_S))
		_box(Vector3(fx, c.y, c.z + (BOX_S * 0.5 + HOLE * 0.5) * 0.5), Vector3(t, HOLE, side))
		_box(Vector3(fx, c.y, c.z - (BOX_S * 0.5 + HOLE * 0.5) * 0.5), Vector3(t, HOLE, side))
		refuges.append({"name": "nest_box", "position": c, "radius": 0.12, "max_span": 0.2})
		landmarks.append({"name": "nest_box_hole", "kind": "opening", "type": "nest_box",
			"position": Vector3(fx, c.y, c.z), "normal": Vector3.LEFT if flip_normal else Vector3.RIGHT,
			"width": HOLE, "height": HOLE, "max_span": 0.2})
		# Perches: one whose seat is buried in the clump, one in the open on
		# a pole nearby.
		buried = Perch.new(CLUMP + Vector3(1.0, 0.2, 0), Vector3.FORWARD, Perch.Kind.BRANCH, 1.0)
		_perches.append(buried)
		_box(Vector3(12, 3.5, 0), Vector3(0.2, 7.0, 0.2))
		open_perch = Perch.new(Vector3(12, 7.02, 0), Vector3.FORWARD, Perch.Kind.POLE_TOP, 2.0)
		_perches.append(open_perch)
		# A "hedge top" whose leafy surface bulges 1 cm above the grip point
		# (the real valley's hedgerows): a moth sitting there would be a few
		# millimetres inside the leaves; a sparrow's body clears it.
		_box(Vector3(-12, 0.5 + 0.01, 20), Vector3(1.0, 1.0, 1.0))
		hedge_top = Perch.new(Vector3(-12, 1.0, 20), Vector3.FORWARD, Perch.Kind.BRANCH, 0.4)
		_perches.append(hedge_top)
		# The dead end: floor, roof, two sides and the closed end (-X).
		var w2 := TUNNEL_W * 0.5 + 0.15
		var tc := TUNNEL
		_box(tc + Vector3(0, -w2, 0), Vector3(TUNNEL_L, 0.3, TUNNEL_W + 0.6))
		_box(tc + Vector3(0, w2, 0), Vector3(TUNNEL_L, 0.3, TUNNEL_W + 0.6))
		_box(tc + Vector3(0, 0, -w2), Vector3(TUNNEL_L, TUNNEL_W + 0.6, 0.3))
		_box(tc + Vector3(0, 0, w2), Vector3(TUNNEL_L, TUNNEL_W + 0.6, 0.3))
		_box(tc + Vector3(-TUNNEL_L * 0.5 - 0.15, 0, 0), Vector3(0.3, TUNNEL_W + 0.6, TUNNEL_W + 0.6))
		_box(ROOF, Vector3(ROOF_W, 0.4, ROOF_W))
		# The sealed box: six walls round a 2-m cube.
		for ax in 3:
			for sg in [-1.0, 1.0]:
				var off := Vector3.ZERO
				off[ax] = sg * 1.15
				var size := Vector3(2.6, 2.6, 2.6)
				size[ax] = 0.3
				_box(SEALED + off, size)

	func _box(c: Vector3, size: Vector3) -> void:
		var b := BoxShape3D.new()
		b.size = size
		_shape(b, c)

	func _shape(sh: Shape3D, at: Vector3) -> void:
		var cs := CollisionShape3D.new()
		cs.shape = sh
		cs.position = at
		_body.add_child(cs)

	func get_refuges() -> Array[Dictionary]:
		return refuges

	func get_landmarks() -> Array[Dictionary]:
		return landmarks


var _tw: TrapWorld


func _trap_world(flip := false) -> TrapWorld:
	if is_instance_valid(_tw):
		_tw.queue_free()
		Habitat.clear_cache()
		await wait_frames(1)
	_tw = TrapWorld.new()
	_tw.flip_normal = flip
	add_child(_tw)
	await wait_physics(3)
	world = null
	return _tw


func after_all() -> void:
	if is_instance_valid(_tw):
		_tw.queue_free()
	await clear_sim()


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	checker = null
	await wait_frames(1)


func test_body_inside_a_foliage_clump_leaves_along_the_normal() -> void:
	var w := await _trap_world()
	var table := {}
	for k in 4:
		var dir := Vector3(cos(TAU * k / 4.0 + 0.3), 0.25, sin(TAU * k / 4.0 + 0.3)).normalized()
		var start := TrapWorld.CLUMP + dir * (TrapWorld.CLUMP_R - 1.2)
		# Flying tangentially: nothing but the push-out takes it outward.
		var tangent := dir.cross(Vector3.UP).normalized()
		var b := spawn(&"starling", start, tangent * 10.0, w)
		b.can_hunt = false
		b.can_flee = false
		b.always_sweep = true
		var m := {"deeper": false, "out_tick": -1, "exit_dir": Vector3.ZERO}
		var d0 := start.distance_to(TrapWorld.CLUMP)
		run(1.0, func(i: int) -> bool:
			var d := b.global_position.distance_to(TrapWorld.CLUMP)
			if d < d0 - 0.05:
				m["deeper"] = true
			if m["out_tick"] < 0 and d >= TrapWorld.CLUMP_R + b.get_body_radius() * 0.8:
				m["out_tick"] = i
				m["exit_dir"] = (b.global_position - TrapWorld.CLUMP).normalized()
			return m["out_tick"] >= 0)
		check(not m["deeper"], "case %d: never pushed deeper into the clump" % k)
		check(m["out_tick"] >= 0 and m["out_tick"] <= 2, "case %d: out of the clump within 3 ticks (got tick %d)" % [k, m["out_tick"]])
		gt((m["exit_dir"] as Vector3).dot(dir), 0.9, "case %d: left along the surface normal" % k)
		table["case_%d" % k] = {"out_tick": m["out_tick"], "normal_dot": snappedf((m["exit_dir"] as Vector3).dot(dir), 0.001)}
		despawn(b)
	metric("clump", table)


func test_sliding_along_a_wall_never_overlaps_it() -> void:
	# The body-level safety (collision sweep + push-out), with the brain out
	# of the loop: the bird is flown straight into the wall at a grazing
	# angle, pressing on (what avoidance steering normally prevents - but a
	# bird can be pushed there by a chase, a gust or another overlay).
	var w := await _trap_world()
	var worst := INF
	var crossed := 0
	var table := {}
	for k in 3:
		var sp: StringName = [&"sparrow", &"pigeon", &"crow"][k]
		for ang in [5.0, 12.0, 25.0]:
			var b := spawn(sp, Vector3.ZERO, Vector3(0, 0, 1), w)
			var r := b.get_body_radius()
			var face := TrapWorld.WALL_X - 0.2
			var start := Vector3(face - r - 0.3, 20.0 + k * 5.0, -12.0)
			var dir := Vector3(sin(deg_to_rad(ang)), 0, cos(deg_to_rad(ang)))
			b.global_position = start
			b.flight.set_velocity(dir * b.flight.cruise)
			b.velocity = dir * b.flight.cruise
			b.always_sweep = true
			var gap := INF
			var through := false
			for i in int(1.5 / DT):
				b.want_dir = dir
				b.want_speed = b.flight.cruise
				b.max_effort = 1.0
				b.want_fold = 0.0
				b._pos = b.global_position
				b._fly(DT)
				var p := b.global_position
				gap = minf(gap, face - (p.x + r * 0.6))
				if p.x > TrapWorld.WALL_X:
					through = true
			worst = minf(worst, gap)
			crossed += 1 if through else 0
			table["%s_%d" % [sp, int(ang)]] = snappedf(gap, 0.0001)
			despawn(b)
	metric("wall_gap_m", table)
	gt(worst, -0.005, "pressed into a wall at 5-25 deg, the body (60%% of its radius) never overlaps it (worst %.4f m)" % worst)
	eq(crossed, 0, "and never passes through it")


func test_buried_perch_is_never_chosen() -> void:
	var w := await _trap_world()
	var h := Habitat.for_world(w)
	check(h.is_enclosed(w.buried), "a perch whose seat is inside the clump is flagged")
	check(not h.is_enclosed(w.open_perch), "the open pole top is not")
	var offered := h.find_perches(TrapWorld.CLUMP, 60.0, 0.3)
	check(not offered.has(w.buried), "the buried perch is never offered")
	check(offered.has(w.open_perch), "the open perch is")
	var claimed_buried := 0
	for k in 6:
		var b := spawn(&"wren", TrapWorld.CLUMP + Vector3(6.0 + k, -2.0, 4.0), Vector3(-6, 0, 0), w)
		b.can_hunt = false
		b.energy = 0.1
		b.brain._enter(NpcBird.State.PERCH)
		if b.perch_spot == w.buried:
			claimed_buried += 1
		despawn(b)
	eq(claimed_buried, 0, "no tired bird ever claims the buried perch")


func test_nest_box_on_a_trunk_is_entered_from_the_open_side() -> void:
	var table := {}
	for flip in [false, true]:
		var w := await _trap_world(flip)
		var h := Habitat.for_world(w)
		var r: Dictionary = h.refuges[0]
		check(r.has("entry"), "flip %s: the nest box refuge is linked to its hole" % flip)
		var out: Vector3 = r["entry"]["out"]
		vnear(out, Vector3.RIGHT, 0.01, "flip %s: approached from the open side (+X), away from the trunk" % flip)
		var hid := 0
		var through_trunk := 0
		var inside := 0
		for k in 4:
			var start := w.box_c + Vector3(7.0, 1.0 + k * 0.5, -3.0 + k * 2.0)
			var wren := spawn(&"wren", start, Vector3(0, 0, 7.0), w)
			wren.can_hunt = false
			var hunter := spawn(&"sparrow", start + Vector3(14.0, 3.0, 6.0), Vector3(-8.0, 0, -3.0), w)
			hunter.can_flee = false
			hunter.hunger = 1.0
			hunter.brain._pending_prey = wren
			hunter.brain._enter(NpcBird.State.HUNT)
			var safety := Safety.new(w)
			var m := {"trunk": false}
			run(15.0, func(_i: int) -> bool:
				safety.step(DT, [wren])
				var p := wren.global_position
				var q := p - TrapWorld.TRUNK
				if absf(q.x) < TrapWorld.TRUNK_HALF and absf(q.z) < TrapWorld.TRUNK_HALF and absf(q.y) < 8.0:
					m["trunk"] = true
				return wren.hidden or not wren.alive)
			hid += 1 if wren.hidden else 0
			through_trunk += 1 if m["trunk"] else 0
			inside += safety.counts["inside"]
			despawn(wren)
			despawn(hunter)
		table["flip_%s" % flip] = {"hid": hid, "through_trunk": through_trunk, "inside_samples": inside}
		gt(hid, 2, "flip %s: most wrens reached the nest box" % flip)
		eq(through_trunk, 0, "flip %s: no wren went through the trunk" % flip)
		eq(inside, 0, "flip %s: no contact with geometry on the way in" % flip)
	metric("nest_box", table)


## A perched body sits one body radius above the grip point (the Perch
## contract), clear of the surface: perches where a body of the bird's size
## would touch geometry are not offered to it (a moth on the bulging top of
## a hedge), though they are to bigger birds whose body clears it.
func test_perched_bodies_sit_on_the_perch_clear_of_geometry() -> void:
	var w := await _trap_world()
	var h := Habitat.for_world(w)
	for sp in [&"moth", &"sparrow"]:
		var span := SizeRules.wingspan_for_mass(SizeRules.species_data(sp)["mass"])
		var offered := h.find_perches(w.hedge_top.position, 5.0, span)
		var r := span * 0.16
		var seat := w.hedge_top.position + Vector3.UP * r
		var q := PhysicsShapeQueryParameters3D.new()
		var sph := SphereShape3D.new()
		sph.radius = r * 0.6
		q.shape = sph
		q.collision_mask = 1
		q.transform = Transform3D(Basis.IDENTITY, seat)
		var touching := not w.get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()
		eq(offered.has(w.hedge_top), not touching, "%s: the hedge-top perch is offered only if its body would sit clear (touching=%s)" % [sp, touching])
		if sp == &"moth":
			check(touching, "(setup) a moth's body would touch the bulging hedge top")
			check(not offered.has(w.hedge_top), "a moth is not offered the hedge top")
		else:
			check(offered.has(w.hedge_top), "a sparrow is offered the hedge top")
	# Seat height: a bird put on the open pole top sits one radius above it.
	var b := spawn(&"crow", w.open_perch.position + Vector3(0, 3, 3), Vector3(0, 0, -5), w)
	b.land_on(w.open_perch, true)
	near(b.global_position.y - w.open_perch.position.y, b.get_body_radius(), 0.001, "perched body centre one body radius above the grip point")


## The AI reads the world's refuges but never writes into them (other
## areas read the same dictionaries): its linked openings live on copies.
func test_habitat_leaves_the_worlds_refuges_untouched() -> void:
	var w := await _trap_world()
	var h := Habitat.for_world(w)
	h.refresh()
	check(not h.refuges.is_empty() and h.refuges[0].has("entry"), "(setup) the habitat linked the nest box to its hole")
	for r in w.get_refuges():
		check(not r.has("entry"), "the world's own refuge dictionary gained no key")


## A bird that flew nose first into a dead end narrower than its turn
## gets out - and when steering cannot do it, it backs out the way it came
## (NpcBird.escape, which the watchdog calls on its second strike): a
## kinematic leg back to the newest clear breadcrumb a couple of wingspans
## away, never through the walls, then on out under its own steering. With
## no trail there is nothing to back out along (the Ecosystem's last resort,
## next test, takes over).
func test_a_bird_wedged_in_a_dead_end_backs_out_the_way_it_came() -> void:
	var w := await _trap_world()
	var table := {}
	var mouth_x := TrapWorld.TUNNEL.x + TrapWorld.TUNNEL_L * 0.5
	for sp in [&"hawk", &"crow"]:
		for mode in ["steering", "escape"]:
			var inner := TrapWorld.TUNNEL + Vector3(-TrapWorld.TUNNEL_L * 0.5 + 1.2, 0, 0)
			var b := spawn(sp, inner, Vector3(-4.0, 0, 0), w)
			b.can_hunt = false
			b.can_flee = false
			b.energy = 0.5
			b.always_sweep = true
			# The way it came in: breadcrumbs from outside the mouth to here,
			# as NpcBird._fly lays them (every 0.3 s where the body is clear).
			for k in 12:
				b._trail.append(TrapWorld.TUNNEL + Vector3(TrapWorld.TUNNEL_L * 0.5 + 6.0 - k * 1.2, 0, 0))
			var safety := Safety.new(w)
			var m := {"out_t": -1.0, "escapes": 0}
			b.behaviour.connect(func(_b: NpcBird, what: StringName) -> void:
				if what == &"escape":
					m["escapes"] += 1)
			if mode == "escape":
				# The watchdog's second strike, now.
				check(b.escape(), "%s: escape() finds a way back along its trail" % sp)
			run(25.0, func(i: int) -> bool:
				safety.step(DT, [b])
				if m["out_t"] < 0.0 and b.global_position.x > mouth_x + 2.0:
					m["out_t"] = i * DT
				return m["out_t"] >= 0.0 and i * DT > m["out_t"] + 3.0)
			var tag := "%s_%s" % [sp, mode]
			table[tag] = {"out_s": snappedf(m["out_t"], 0.01), "escapes": m["escapes"], "geo_hits": b.geo_hits}
			between(m["out_t"], 0.0, 12.0, "%s: out of the dead end, 2 m past its mouth (s) %s" % [tag, table[tag]])
			eq(safety.counts["inside"], 0, "%s: never inside the tunnel's walls" % tag)
			eq(safety.counts["stuck"], 0, "%s: never stuck" % tag)
			if mode == "escape":
				gt(m["escapes"], 0, "%s: backed out along the trail" % tag)
			despawn(b)
		var bare := spawn(sp, TrapWorld.TUNNEL + Vector3(-TrapWorld.TUNNEL_L * 0.5 + 1.2, 0, 0), Vector3(-4.0, 0, 0), w)
		bare._trail.clear()
		check(not bare.escape(), "%s: no trail, no escape (nothing to back out along)" % sp)
		despawn(bare)
	metric("dead_end", table)


## Low under a roof or a crown (the round-3 verifier's hawk, 2.7 m above the
## ground in a copse): its ground clearance asks it to climb, and climbing
## presses it into what is overhead. It holds its height and flies out from
## under, without grinding along the underside.
func test_a_low_bird_under_a_roof_flies_out_from_under_not_up_into_it() -> void:
	var w := await _trap_world()
	var table := {}
	for sp in [&"hawk", &"crow", &"pigeon"]:
		var b := spawn(sp, TrapWorld.ROOF + Vector3(-6.0, -1.7, 0.0), Vector3(1, 0, 0), w)
		b.flight.set_velocity(Vector3(b.flight.cruise * 0.8, 0, 0))
		b.velocity = b.flight.air_velocity()
		b.can_hunt = false
		b.can_flee = false
		b.brain._perch_cool = 999.0
		b.home = Vector3(TrapWorld.ROOF.x, 0, TrapWorld.ROOF.z)
		b.always_sweep = true
		var safety := Safety.new(w)
		var m := {"out_t": -1.0, "hits": 0}
		var half := TrapWorld.ROOF_W * 0.5 + b.get_body_radius()
		run(12.0, func(i: int) -> bool:
			safety.step(DT, [b])
			var q := b.global_position - TrapWorld.ROOF
			if m["out_t"] < 0.0 and (absf(q.x) > half or absf(q.z) > half):
				m["out_t"] = i * DT
				m["hits"] = b.geo_hits
			return m["out_t"] >= 0.0)
		table[sp] = {"out_s": snappedf(m["out_t"], 0.01), "roof_hits": m["hits"], "y": snappedf(b.global_position.y, 0.01)}
		between(m["out_t"], 0.0, 8.0, "%s: out from under the roof (s) %s" % [sp, table[sp]])
		lt(m["hits"], 3, "%s: contacts with the roof on the way out %s" % [sp, table[sp]])
		eq(safety.counts["inside"], 0, "%s: never inside the roof" % sp)
		eq(safety.counts["below"], 0, "%s: never below the ground" % sp)
		despawn(b)
	metric("under_roof", table)


## The last resort: a bird with no way out at all (sealed in a box, no
## trail - nothing in the real valley is like this; it stands for any trap
## neither steering nor its trail can get it out of) is flagged trapped
## after three watchdog periods and the Ecosystem removes it out of view
## ("stuck") and refills the population.
func test_a_bird_with_no_way_out_is_taken_out_of_play_unseen() -> void:
	var w := await _trap_world()
	var e := make_eco(8, 3)
	e.step(DT)
	check(e.count() == 8, "(setup) the population is up")
	var n: NpcBird = e.get_npcs()[0]
	for o in e.get_npcs():
		if o.flock == null:
			n = o
			break
	n.global_position = TrapWorld.SEALED
	n.flight.set_velocity(Vector3(3, 0, 0))
	n._trail.clear()
	n.always_sweep = true
	var m := {"reason": &"", "t": -1.0}
	e.npc_despawned.connect(func(o: NpcBird, reason: StringName) -> void:
		if o == n:
			m["reason"] = reason)
	var t := [0.0]
	run(20.0, func(i: int) -> bool:
		t[0] = i * DT
		if m["reason"] != &"" and m["t"] < 0.0:
			m["t"] = t[0]
		return m["t"] >= 0.0)
	eq(m["reason"], &"stuck", "removed as stuck")
	between(m["t"], 2.5, 13.5, "after three watchdog periods (s)")
	run(1.0)
	eq(e.count(), 8, "and the population refilled")
	e.queue_free()
	eco = null
	await wait_frames(1)
