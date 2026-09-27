extends "res://tests/unit/ai/ai_sim.gd"
## The brain's safety overlays - obstacle feelers, ground clearance, arena
## bounds - keep a bird off geometry *before* the body's safety net (swept
## collision and push-out, the ground clamp, the bounds clamp) has to catch
## it. The A5 monitor cannot tell the difference: the net keeps every body
## outside geometry either way. So these tests count the net's catches
## (NpcBird.geo_hits / ground_hits / bounds_hits) for birds flown straight
## at trouble with a goal beyond it, and each fails if its overlay is
## removed:
##  * walls: the cliff face, the houses, the barn - turn or climb away,
##    0 contacts;
##  * trunks: small birds at tree trunks below the canopy - 0 contacts;
##  * ground: a gull gliding for a goal on the ground and a hawk stooping at
##    a pigeon skimming a field - pull out in time, 0 ground contacts;
##  * bounds: flying out at the rim, climbing for the ceiling - turn back
##    before the clamp, 0 bounds contacts.
## (The rate in the wild - contacts per bird-minute over the whole soak -
## is pinned in soak_test.)


func before_all() -> void:
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	checker = null
	await wait_frames(1)


## A calm bird flying at `dir` from `start`, bent on a goal it keeps (not
## tired, not hungry, not scared, no thermals or perches to distract it).
func _flier(sp: StringName, start: Vector3, dir: Vector3, goal: Vector3) -> NpcBird:
	var b := spawn(sp, start, dir.normalized() * SizeRules.performance(SizeRules.species_data(sp)["mass"])["cruise"])
	b.can_hunt = false
	b.can_flee = false
	b.energy = 1.0
	b.home = Vector3(goal.x, 0.0, goal.z)
	b.home_radius = 400.0
	b.brain._perch_cool = 999.0
	b.brain._soar_cool = 999.0
	b.brain._goal = goal
	b.brain._goal_t = 0.0
	b.brain._goal_life = 999.0
	b.brain._goal_free = true
	return b


## Runs `b` for `seconds`; returns contacts by kind, the nearest it came to
## the point `near` (if given) and how far it turned from `dir`.
func _run_one(b: NpcBird, seconds: float, near := Vector3.INF) -> Dictionary:
	var g0 := b.geo_hits
	var gr0 := b.ground_hits
	var bo0 := b.bounds_hits
	var m := {"min_d": INF, "min_agl": INF, "max_r": 0.0}
	var trace := OS.get_environment("AI_TRACE") != ""
	var hist: Array[String] = []
	run(seconds, func(_i: int) -> bool:
		if trace:
			hist.append("t=%.3f p=%s v=%s want=%s ws=%.1f brake=%.1f slots=%d ob_n=%s ahead=%.1f near=%s geo=%d" % [_i * DT,
				b.global_position.snapped(Vector3.ONE * 0.01), b.velocity.snapped(Vector3.ONE * 0.1), b.want_dir.snapped(Vector3.ONE * 0.01),
				b.want_speed, b.want_brake, b.brain._ob_p.size(), str(b.brain._ob_n), b.brain._ahead_d, b.near_geometry, b.geo_hits])
			if b.geo_hits > g0 and hist.size() < 100000:
				for j in range(maxi(0, hist.size() - 220), hist.size()):
					print("[ai-trace] ", hist[j])
				hist.resize(100000)
		var p := b.global_position
		if near != Vector3.INF:
			m["min_d"] = minf(m["min_d"], Vector2(p.x - near.x, p.z - near.z).length())
		m["min_agl"] = minf(m["min_agl"], p.y - world.ground_height(p.x, p.z))
		m["max_r"] = maxf(m["max_r"], Vector2(p.x, p.z).length())
		return false)
	if b.geo_hits > g0 and OS.get_environment("AI_DEBUG") != "":
		print("[ai] contact %s at %s normal %s bird %s" % [b.species, b.last_hit, b.last_hit_normal, b.global_position])
	return {"geo": b.geo_hits - g0, "ground": b.ground_hits - gr0, "bounds": b.bounds_hits - bo0,
		"min_d": m["min_d"], "min_agl": m["min_agl"], "max_r": m["max_r"]}


func test_walls_are_flown_round_not_into() -> void:
	var rows := []
	var total := 0
	# The cliff face (z = 330, 260 m wide, ~55 m high), goal behind it.
	for sp in [&"sparrow", &"crow", &"gull"]:
		for x in [-60.0, 0.0, 60.0]:
			var start := Vector3(x, world.ground_height(x, 270.0) + 18.0, 270.0)
			var b := _flier(sp, start, Vector3.BACK, Vector3(x, start.y, 400.0))
			var r := _run_one(b, 10.0)
			rows.append(["cliff", sp, x, r["geo"]])
			total += r["geo"]
			despawn(b)
	# Every house, from 40 m off at 3 m above the ground, goal beyond it.
	for i in world.houses.size():
		var xf: Transform3D = world.houses[i][0]
		var c := xf.origin
		for sp in [&"sparrow", &"pigeon"]:
			var a := TAU * i / world.houses.size()
			var dir := Vector3(cos(a), 0.0, sin(a))
			var start := c - dir * 40.0
			start.y = world.ground_height(start.x, start.z) + 3.0
			var goal := c + dir * 60.0
			goal.y = world.ground_height(goal.x, goal.z) + 3.0
			var b := _flier(sp, start, dir, goal)
			var r := _run_one(b, 9.0)
			rows.append(["house%d" % i, sp, 0, r["geo"]])
			total += r["geo"]
			despawn(b)
	# The barn's back wall.
	for sp in [&"starling", &"crow"]:
		var start := Vector3(-60, world.ground_height(-60, 100) + 4.0, 100)
		var b := _flier(sp, start, Vector3.FORWARD, Vector3(-60, start.y, -30))
		var r := _run_one(b, 9.0)
		rows.append(["barn", sp, 0, r["geo"]])
		total += r["geo"]
		despawn(b)
	metric("walls", rows)
	eq(total, 0, "birds flown at walls with a goal beyond turn or climb away before touching (%d runs) %s" % [rows.size(), rows.filter(func(r: Array) -> bool: return r[3] > 0)])


func test_trunks_are_flown_round_not_into() -> void:
	var rows := []
	var total := 0
	var n := 0
	for t in world.trees:
		if n >= 8:
			break
		var base: Vector3 = t[0]
		var h: float = t[1]
		# Below the lowest branches (42% of the height and up), across the
		# trunk; no other trunk right on the line.
		var y := base.y + minf(h * 0.3, 2.2)
		var start := base + Vector3(-30.0, 0.0, 0.0)
		start.y = y
		var end := base + Vector3(40.0, 0.0, 0.0)
		end.y = y
		var b := _flier(&"sparrow", start, Vector3.RIGHT, end)
		var r := _run_one(b, 7.0, base)
		rows.append([n, r["geo"], snappedf(r["min_d"], 0.01)])
		total += r["geo"]
		n += 1
		despawn(b)
	metric("trunks", rows)
	gt(n, 5, "trunks tested")
	eq(total, 0, "sparrows flown at tree trunks below the canopy steer round them %s" % str(rows))


func test_ground_is_never_hit() -> void:
	# A gull and a hawk gliding for a goal on the ground 250 m ahead, over
	# the field: they level off at their clearance (half the bottom of
	# their height band) - the feelers alone would let them sink to a few
	# metres before the ground turned them.
	var rows := []
	var total := 0
	var low := []
	for sp in [&"gull", &"hawk"]:
		var clear: float = maxf(float(SpeciesProfile.of(sp)["alt"][0]) * 0.5, 1.5)
		for x in [-150.0, -90.0, 0.0]:
			var start := Vector3(x, world.ground_height(x, 60) + 35.0, 60.0)
			var goal := Vector3(x + 250.0, world.ground_height(x + 250.0, 60.0), 60.0)
			var b := _flier(sp, start, (goal - start), goal)
			var r := _run_one(b, 14.0)
			rows.append(["%s_glide" % sp, x, r["ground"], snappedf(r["min_agl"], 0.1)])
			total += r["ground"]
			if r["min_agl"] < clear * 0.8:
				low.append([sp, x, snappedf(r["min_agl"], 0.1), clear])
			despawn(b)
	# A hawk stooping from 55 m at a pigeon skimming the field at 3.5 m.
	for k in 4:
		var px := -120.0 + k * 20.0
		var pp := Vector3(px, world.ground_height(px, 60.0) + 3.5, 60.0)
		var prey := spawn(&"pigeon", pp, Vector3(11, 0, 0))
		prey.can_flee = false
		prey.can_hunt = false
		prey.brain._goal = pp + Vector3(400, 0, 0)
		prey.brain._goal_t = 0.0
		prey.brain._goal_life = 999.0
		prey.brain._goal_free = true
		prey.brain._perch_cool = 999.0
		var hawk := spawn(&"hawk", pp + Vector3(-25.0 - k * 5.0, 55.0, 0.0), Vector3(12, -2, 0))
		hawk.can_flee = false
		hawk.hunger = 1.0
		hawk.brain._pending_prey = prey
		hawk.brain._enter(NpcBird.State.HUNT)
		hawk.brain._maybe_stoop()
		var stooped := {"v": false}
		var g0 := hawk.ground_hits
		var m := {"agl": INF}
		run(8.0, func(_i: int) -> bool:
			if hawk.state == NpcBird.State.STOOP:
				stooped["v"] = true
			var p := hawk.global_position
			m["agl"] = minf(m["agl"], p.y - world.ground_height(p.x, p.z))
			return false)
		rows.append(["hawk_stoop", k, hawk.ground_hits - g0, snappedf(m["agl"], 0.1), stooped["v"]])
		check(stooped["v"], "hawk %d stooped at the low pigeon" % k)
		total += hawk.ground_hits - g0
		despawn(prey)
		despawn(hawk)
	metric("ground", rows)
	eq(total, 0, "gliding for the ground and stooping at a low prey never touch the ground %s" % str(rows))
	eq(low.size(), 0, "gliders keep at least 80%% of their ground clearance %s" % str(low))


func test_bounds_turn_birds_back_before_the_rim() -> void:
	var rows := []
	var total := 0
	var R := world.bounds_radius
	# Four headings out to the rim (not the one straight at the cliff: that
	# is a wall test, above).
	for a in [0.3, 2.7, 3.6, 5.0]:
		var out := Vector3(cos(a), 0.0, sin(a))
		var start := out * (R - 75.0)
		start.y = world.ground_height(start.x, start.z) + 45.0
		var goal := out * (R + 120.0)
		goal.y = start.y
		var b := _flier(&"crow", start, out, goal)
		var r := _run_one(b, 16.0)
		rows.append(["rim", a, r["bounds"], snappedf(r["max_r"], 0.1), r["geo"]])
		total += r["bounds"] + r["geo"]
		despawn(b)
	# Climbing for a goal above the ceiling.
	var top := Vector3(-60, world.ceiling - 22.0, -60)
	var g := _flier(&"gull", top, Vector3(1, 0.2, 0), Vector3(200, world.ceiling + 60.0, -60))
	var rc := _run_one(g, 16.0)
	rows.append(["ceiling", 0, rc["bounds"], 0.0, rc["geo"]])
	total += rc["bounds"] + rc["geo"]
	despawn(g)
	metric("bounds", rows)
	eq(total, 0, "birds heading out of the arena turn back before the rim/ceiling clamp (and touch nothing) %s" % str(rows))
