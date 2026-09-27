extends "res://tests/unit/ai/ai_sim.gd"
## Individual behaviours in the AI test world: perching (wires, branches,
## one bird per perch), soaring a thermal (circling, climbing without
## flapping, centring), flocking (cohesion, spacing, alignment, murmuration
## motion), stoops (tuck, dive speed) and the flap/glide/bank animation drive.

const Plot := preload("res://tests/unit/ai/ai_plot.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")


func before_all() -> void:
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


func after_each() -> void:
	for b in loose:
		if is_instance_valid(b):
			b.queue_free()
	loose.clear()
	eco = null
	checker = null
	await wait_frames(1)


func _free_perches(kind: Perch.Kind) -> Array[Perch]:
	var out: Array[Perch] = []
	for p in world.get_perches():
		if p.kind == kind and p.is_free():
			out.append(p)
	return out


## A tired sparrow near the power line lands on a wire, stays put while
## resting, then leaves; a tired hawk takes a pole top.
func test_tired_birds_land_on_wires_and_poles() -> void:
	var wire: Perch = _free_perches(Perch.Kind.WIRE)[10]
	var landed := {}
	var trials := [[&"sparrow", Perch.Kind.WIRE], [&"starling", Perch.Kind.WIRE], [&"hawk", Perch.Kind.POLE_TOP], [&"wren", Perch.Kind.BRANCH]]
	for tr in trials:
		var sp: StringName = tr[0]
		var start := wire.position + Vector3(40, 12, 30)
		if tr[1] == Perch.Kind.BRANCH:
			start = Vector3(-140, 20, -40) + Vector3(40, 0, 30)
		var b := spawn(sp, start, Vector3(-8, 0, -6))
		b.energy = 0.15
		b.hunger = 0.0
		b.can_hunt = false
		# (Lambdas capture locals by value: mutable state lives in a dict.)
		var m := {"t_land": -1.0, "still": true, "pos": Vector3.ZERO}
		run(40.0, func(i: int) -> bool:
			if b.perched and m["t_land"] < 0.0:
				m["t_land"] = i * DT
				m["pos"] = b.global_position
			if m["t_land"] >= 0.0 and b.perched and b.global_position.distance_to(m["pos"]) > 0.01:
				m["still"] = false
			return m["t_land"] >= 0.0 and i * DT > m["t_land"] + 3.0)
		var t_land: float = m["t_land"]
		var still: bool = m["still"]
		check(t_land >= 0.0, "%s landed on a perch within 40 s" % sp)
		if t_land >= 0.0:
			landed[String(sp)] = snappedf(t_land, 0.1)
			check(b.perch_spot != null and b.perch_spot.occupant == b, "%s owns its perch" % sp)
			check(b.perch_spot.fits(b.get_wingspan()), "%s perch fits its span" % sp)
			check(int(b.perch_spot.kind) in (b.profile["perch_kinds"] as Array), "%s perch kind suits the species" % sp)
			check(still, "%s stays put while perched" % sp)
			check(b.model.perched and b.model.wing_fold > 0.99, "%s model shows folded, perched wings" % sp)
			lt(b.global_position.distance_to(b.perch_spot.position), b.get_body_radius() * 1.5 + 0.02, "%s sits on the perch point" % sp)
		loose.erase(b)
		b.queue_free()
	metric("landing_time_s", landed)


func test_perches_are_exclusive_and_released() -> void:
	# Six tired starlings aimed at the same stretch of wire each get their own.
	var wire: Perch = _free_perches(Perch.Kind.WIRE)[4]
	var birds: Array[NpcBird] = []
	for i in 6:
		var b := spawn(&"starling", wire.position + Vector3(30 + i * 2, 10, 25), Vector3(-7, 0, -6))
		b.energy = 0.1
		b.can_hunt = false
		birds.append(b)
	var m := {"peak": 0, "shared": 0, "wrong_owner": 0}
	run(45.0, func(_i: int) -> bool:
		var owners := {}
		var n := 0
		for b in birds:
			if b.perched:
				n += 1
				var id := b.perch_spot.get_instance_id()
				if owners.has(id):
					m["shared"] += 1
				owners[id] = true
				if b.perch_spot.occupant != b:
					m["wrong_owner"] += 1
		m["peak"] = maxi(m["peak"], n)
		return m["peak"] >= 6)
	eq(m["shared"], 0, "no two birds ever on one perch")
	eq(m["wrong_owner"], 0, "a perched bird is always its perch's occupant")
	gt(m["peak"], 4, "most of the tired starlings perched at once")
	for b in birds:
		if not b.perched:
			run(20.0, func(_i: int) -> bool: return birds[0].perched)
			break
	var p: Perch = birds[0].perch_spot if birds[0].perched else null
	birds[0].energy = 1.0
	birds[0].brain._rest_s = 0.0
	run(3.0)
	check(not birds[0].perched, "rested bird took off")
	if p != null:
		check(p.is_free(), "perch released after take-off")


## A gull finds the thermal, circles in it with the wings still and climbs.
func test_gull_soars_thermal_without_flapping() -> void:
	var th: Dictionary = world.thermals[0]
	var c: Vector3 = th["position"]
	var g := spawn(&"gull", c + Vector3(90, 35, 0), Vector3(-15, 0, 0))
	g.can_hunt = false
	g.energy = 0.95
	g.brain._perch_cool = 999.0
	var h0 := g.global_position.y
	var m := {"yaw": 0.0, "prev": g.flight.psi, "circ_t": 0.0, "effort": 0.0, "inside": 0, "ticks": 0,
		"trace": PackedVector3Array(), "h_circ0": INF}
	run(45.0, func(i: int) -> bool:
		if i % 6 == 0:
			m["trace"].append(g.global_position)
		if g.state == NpcBird.State.SOAR and g.brain._circling:
			if m["h_circ0"] == INF:
				m["h_circ0"] = g.global_position.y
			m["circ_t"] += DT
			m["yaw"] += wrapf(g.flight.psi - m["prev"], -PI, PI)
			m["effort"] += g.flight.effort
			m["ticks"] += 1
			if Vector2(g.global_position.x - c.x, g.global_position.z - c.z).length() < float(th["radius"]):
				m["inside"] += 1
		m["prev"] = g.flight.psi
		return false)
	var circ_t: float = m["circ_t"]
	var yaw: float = m["yaw"]
	var effort_sum: float = m["effort"]
	var inside: int = m["inside"]
	var ticks: int = m["ticks"]
	var trace: PackedVector3Array = m["trace"]
	gt(circ_t, 20.0, "circled in the thermal for most of the time")
	gt(absf(yaw), TAU * 2.0, "turned at least two full circles")
	var climb := g.global_position.y - minf(h0, float(m["h_circ0"]))
	gt(climb, 20.0, "gained height in the thermal")
	lt(effort_sum / maxf(ticks, 1), 0.05, "wings still (no flapping) while circling")
	gt(float(inside) / maxf(ticks, 1), 0.8, "stayed inside the lift core")
	metric("soar", {"climb_m": snappedf(climb, 0.1), "circles": snappedf(absf(yaw) / TAU, 0.1), "mean_effort": snappedf(effort_sum / maxf(ticks, 1), 0.001)})
	_plot_path("soar_gull", trace, c, float(th["radius"]))


## A starling flock stays together, keeps its spacing and flies aligned.
func test_starling_flock_is_cohesive_spaced_and_aligned() -> void:
	var home := Vector3(-140, 0, -40)
	var fl := FlockGroup.new(1, &"starling", "murmuration", home, Habitat.for_world(world), 99)
	var members: Array[NpcBird] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 16:
		var b := spawn(&"starling", fl.anchor + Vector3(rng.randf_range(-6, 6), rng.randf_range(-2, 2), rng.randf_range(-6, 6)), Vector3(0, 0, -10))
		b.flock = fl
		b.can_hunt = false
		b.energy = 1.0
		fl.members.append(b)
		b.set_state(NpcBird.State.FLOCK)
		members.append(b)
	var m := {"nn": 0.0, "close": 0, "pol": 0.0, "n": 0, "spread": 0.0}
	var traces := {}
	run(40.0, func(i: int) -> bool:
		fl.update(DT)
		if i % 6 == 0:
			for b in members:
				if not traces.has(b):
					traces[b] = PackedVector3Array()
				traces[b].append(b.global_position)
		if i < 72 * 5 or i % 12 != 0:
			return false
		var vsum := Vector3.ZERO
		var c := Vector3.ZERO
		for b in members:
			vsum += b.velocity.normalized()
			c += b.global_position
			var nn := INF
			for o in members:
				if o != b:
					nn = minf(nn, b.global_position.distance_to(o.global_position))
			m["nn"] += nn
			if nn < b.get_wingspan() * 0.5:
				m["close"] += 1
		c /= members.size()
		for b in members:
			m["spread"] = maxf(m["spread"], b.global_position.distance_to(c))
		m["pol"] += vsum.length() / members.size()
		m["n"] += 1
		return false)
	var nn_sum: float = m["nn"]
	var too_close: int = m["close"]
	var pol_sum: float = m["pol"]
	var samples: int = m["n"]
	var spread_max: float = m["spread"]
	var nn_mean := nn_sum / (samples * members.size())
	var pol := pol_sum / samples
	# ~2.7 m (7 starling wingspans, the separation radius) with separation
	# on; ~1.4 m without it - so the floor is 2.0.
	between(nn_mean, 2.0, 6.0, "mean nearest-neighbour distance (m)")
	gt(spread_max, 5.0, "flock has volume (does not collapse onto a line)")
	lt(float(too_close) / (samples * members.size()), 0.03, "birds almost never closer than half a wingspan")
	gt(pol, 0.6, "flock is aligned (polarisation)")
	lt(spread_max, 45.0, "flock never scatters beyond 45 m from its centre")
	metric("flock", {"nn_m": snappedf(nn_mean, 0.01), "polarisation": snappedf(pol, 0.01), "spread_max_m": snappedf(spread_max, 0.1)})
	var pl := Plot.new(700, 700, Color(0.97, 0.97, 0.95), Vector2(home.x - 90, home.z - 90), Vector2(home.x + 90, home.z + 90))
	for b in traces:
		var pts := PackedVector2Array()
		for p in traces[b]:
			pts.append(pl.top(p))
		pl.polyline(pts, Color(0.15, 0.2, 0.15, 0.55))
	pl.text(Vector2(10, 10), "STARLING MURMURATION 40S TOP VIEW 180M", Color.BLACK, 2)
	pl.save(Paths.artifacts("ai").path_join("flock_murmuration_top.png"))


## A hawk well above its prey folds and stoops, far faster than it cruises.
func test_hawk_stoops_from_height() -> void:
	var prey := spawn(&"pigeon", Vector3(60, 25, 60), Vector3(-10, 0, 0))
	prey.can_flee = false
	prey.can_hunt = false
	var hawk := spawn(&"hawk", Vector3(90, 110, 90), Vector3(-10, 0, -10))
	hawk.hunger = 1.0
	hawk.can_flee = false
	hawk.brain._pending_prey = prey
	hawk.brain._enter(NpcBird.State.HUNT)
	hawk.brain._maybe_stoop()
	var m := {"stooped": false, "fold": 0.0, "top": 0.0}
	run(12.0, func(_i: int) -> bool:
		if hawk.state == NpcBird.State.STOOP:
			m["stooped"] = true
			m["fold"] = maxf(m["fold"], hawk.flight.fold)
			m["top"] = maxf(m["top"], hawk.flight.speed)
		return not prey.alive)
	var stooped: bool = m["stooped"]
	var max_fold: float = m["fold"]
	var top: float = m["top"]
	check(stooped, "hawk entered a stoop")
	gt(max_fold, 0.8, "wings tucked in the stoop")
	gt(top, hawk.flight.cruise * 1.6, "stoop speed far above cruise")
	lt(top, hawk.flight.max_speed * 1.0001, "stoop speed within the size limit")
	metric("stoop", {"top_speed": snappedf(top, 0.1), "cruise": snappedf(hawk.flight.cruise, 0.1), "fold": snappedf(max_fold, 0.01)})


## The model is driven: beats while climbing, glides still while soaring
## down, banks into turns, tucks in a dive.
func test_model_is_driven_by_flight() -> void:
	var b := spawn(&"crow", Vector3(0, 60, 0), Vector3(0, 0, -14))
	b.can_hunt = false
	var phases := {}
	b.brain._perch_cool = 999.0
	b.want_dir = Vector3(0, 0.3, -1)
	b.want_speed = b.flight.cruise
	b.max_effort = 1.0
	# Drive the flight directly (brain paused) to check the animation link.
	for i in 72:
		b.flight.step(DT, Vector3(0, 0.3, -1), b.flight.cruise, 1.0, 0.0)
		b._animate(DT)
		phases[snappedf(b.model.flap_phase, 0.05)] = true
	gt(b.model.flap_amount, 0.3, "flapping while climbing")
	gt(phases.size(), 8, "flap phase advances through the beat")
	for i in 72 * 3:
		b.flight.step(DT, Vector3(0, -0.2, -1), b.flight.v_md, 0.0, 0.0)
		b._animate(DT)
	lt(b.model.flap_amount, 0.05, "wings still in a glide")
	for i in 72:
		b.flight.step(DT, Vector3(1, 0, 0), b.flight.cruise, 1.0, 0.0)
		b._animate(DT)
	gt(absf(b.model.bank), 0.3, "banked into the turn")
	for i in 72:
		b.flight.step(DT, Vector3(0, -1, -0.1), 999.0, 0.0, 1.0)
		b._animate(DT)
	gt(b.model.wing_fold, 0.9, "wings tucked in the dive")


func _plot_path(tag: String, pts3: PackedVector3Array, c: Vector3, r: float) -> void:
	var pl := Plot.new(600, 600, Color(0.97, 0.97, 0.95), Vector2(c.x - 110, c.z - 110), Vector2(c.x + 110, c.z + 110))
	pl.circle(pl.top(c), r / 220.0 * 600.0, Color(0.9, 0.5, 0.1))
	var pts := PackedVector2Array()
	for p in pts3:
		pts.append(pl.top(p))
	pl.polyline(pts, Color(0.2, 0.3, 0.8), 1)
	pl.text(Vector2(10, 10), "%s  THERMAL R %.0fM" % [tag.replace("_", " "), r], Color.BLACK, 2)
	if not pts3.is_empty():
		pl.text(Vector2(10, 30), "CLIMB %.1fM" % (pts3[-1].y - pts3[0].y), Color.BLACK, 2)
	pl.save(Paths.artifacts("ai").path_join("%s_top.png" % tag))


## GameLoop clears `alive` before calling on_caught (its catch commit): the
## NPC must still vanish, release its perch and report the catch.
func test_caught_cleanup_even_if_alive_already_cleared() -> void:
	var wire: Perch = _free_perches(Perch.Kind.WIRE)[30]
	var b := spawn(&"sparrow", wire.position + Vector3.UP, Vector3(0, 0, -5))
	b.land_on(wire)
	var hawk := spawn(&"hawk", Vector3(0, 50, 0), Vector3(0, 0, -17))
	var m := {"signal": false, "count": 0}
	b.caught.connect(func(_n: NpcBird, by: Bird) -> void:
		m["signal"] = by == hawk
		m["count"] += 1)
	b.alive = false
	b.on_caught(hawk)
	check(m["signal"], "caught signal emitted, with the predator")
	check(not b.visible, "eaten bird is hidden at once")
	check(wire.is_free(), "its perch is released")
	b.on_caught(hawk)
	eq(m["count"], 1, "a second on_caught call does nothing (one signal, one clean-up)")


## A hunter going for a bird sitting on a wire keeps its body out of the
## wire and its pole (its body collides as ever near its prey -
## it used not to, and went through nest boxes and eaves) and strikes
## rather than crashes. Whether it takes the bird is reported, not pinned:
## sitting birds are hard to take (a 10-cm strike at 10 m/s; see AI.md).
func test_hunters_go_for_perched_birds_without_touching_the_perch() -> void:
	var cases := [[&"hawk", &"pigeon", Perch.Kind.WIRE], [&"starling", &"sparrow", Perch.Kind.WIRE]]
	var took := {}
	for c in cases:
		var perch: Perch = null
		var span := SizeRules.wingspan_for_mass(SizeRules.species_data(c[1])["mass"])
		for q in _free_perches(c[2]):
			if q.fits(span):
				perch = q
				break
		check(perch != null, "(setup) a free %s perch for a %s" % [Perch.Kind.keys()[c[2]], c[1]])
		if perch == null:
			continue
		var prey := spawn(c[1], perch.position + Vector3(0, 2, 0))
		prey.can_flee = false
		prey.can_hunt = false
		prey.land_on(perch, true)
		# Starts inside its hunting range, heading roughly its way.
		var off := Vector3(30, 8, 20).normalized() * minf(37.0, float(SpeciesProfile.of(c[0])["hunt_range_m"]) * 0.6)
		var hunter := spawn(c[0], perch.position + off, Vector3(-off.x, -off.y * 0.5, -off.z).normalized() * SizeRules.cruise_speed(SizeRules.species_data(c[0])["mass"]))
		hunter.hunger = 1.0
		hunter.can_flee = false
		hunter.brain._pending_prey = prey
		hunter.brain._enter(NpcBird.State.HUNT)
		make_checker()
		var g0 := hunter.geo_hits
		var safety := Safety.new(world)
		var m := {"t": -1.0, "min_d": INF}
		run(30.0, func(i: int) -> bool:
			safety.step(DT, [hunter])
			if prey.alive:
				m["min_d"] = minf(m["min_d"], hunter.global_position.distance_to(prey.global_position))
			if not prey.alive and m["t"] < 0.0:
				m["t"] = i * DT
			return m["t"] >= 0.0)
		var k := "%s>%s on %s" % [c[0], c[1], Perch.Kind.keys()[c[2]]]
		took[k] = snappedf(m["t"], 0.1) if m["t"] >= 0.0 else "no (%s, closest %.2f m)" % [hunter.brain.give_up_reason, m["min_d"]]
		lt(m["min_d"], 5.0, "%s: the hunter went for it (closest approach, m)" % k)
		eq(safety.counts["inside"], 0, "%s: the hunter never went into the perch's geometry %s" % [k, safety.examples])
		lt(hunter.geo_hits - g0, 3, "%s: a strike, not a crash (geometry contacts)" % k)
		checker = null
		for b in [prey, hunter]:
			loose.erase(b)
			if is_instance_valid(b):
				b.queue_free()
		await wait_frames(1)
	metric("perched_catch_s", took)


## Integration round 2 (the experience verifier: "8-13 birds, a small flock
## rather than a murmuration"): the murmuration's visual-only mass
## (MurmurationSwarm) wheels round the flock's own starlings - sized by the
## NPC budget, never a Bird (not in Birds, never prey, threat or caught),
## within a few cloud radii of the flock, moving, and gone while there is no
## flying murmuration.
func test_the_murmuration_has_a_visual_mass() -> void:
	eq(MurmurationSwarm.size_for_budget(60), 45, "45 visual starlings at 60 NPCs")
	eq(MurmurationSwarm.size_for_budget(28), 21, "21 at the Quest's 28")
	eq(MurmurationSwarm.size_for_budget(20), 16, "16 at the governor's floor")
	var home := Vector3(-140, 0, -40)
	var fl := FlockGroup.new(2, &"starling", "murmuration", home, Habitat.for_world(world), 7)
	for i in 10:
		var b := spawn(&"starling", fl.anchor + Vector3(i * 0.8 - 4.0, 0.0, 0.0), Vector3(0, 0, -10))
		b.flock = fl
		b.can_hunt = false
		fl.members.append(b)
		b.set_state(NpcBird.State.FLOCK)
	var sw := MurmurationSwarm.new(28, 3)
	add_child(sw)
	var birds0 := Birds.all().size()
	# (Lambdas capture locals by value: the tallies live in a dictionary.)
	var m := {"far": 0.0, "moved": 0.0, "prev": PackedVector3Array()}
	run(20.0, func(i: int) -> bool:
		fl.update(DT)
		sw.step(DT, fl)
		if i > 72 * 3:
			var c := fl.centroid()
			for p in sw.positions():
				m["far"] = maxf(m["far"], p.distance_to(c))
			if i % 72 == 0:
				var prev: PackedVector3Array = m["prev"]
				if not prev.is_empty():
					for k in sw.size:
						m["moved"] += sw.positions()[k].distance_to(prev[k]) / sw.size
				m["prev"] = sw.positions().duplicate()
		return false)
	var far: float = m["far"]
	var moved: float = m["moved"]
	check(sw.visible and sw.shown() == 28, "shown with a flying murmuration (%d)" % sw.shown())
	eq(Birds.all().size(), birds0, "never registered as birds")
	lt(far, MurmurationSwarm.RADIUS * 3.5, "every visual starling within 3.5 cloud radii of the flock (%.1f m)" % far)
	gt(moved, 20.0, "the mass moves (%.0f m per bird over 16 s)" % moved)
	metric("swarm", {"far_m": snappedf(far, 0.1), "moved_m": snappedf(moved, 0.1)})
	fl.mood = FlockGroup.Mood.ROOST
	sw.step(DT, fl)
	check(not sw.visible and sw.shown() == 0, "gone while the murmuration roosts")
	sw.step(DT, null)
	check(not sw.visible, "and without one")
	sw.queue_free()
