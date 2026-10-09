extends TestCase
## Verifier probe (round 2, experience & requirements lens): does the world
## deliver what a PLAYER needs, at every size, over a long session?
##
##   tools/gd.sh world_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/world --suite=r2exp_play
##
## - Soaring for every size: mean lift on each species' own thermalling
##   circle (from SizeRules.performance, a core contract), at several heights
##   and over 10 minutes of drift/pulse.
## - The ceiling: is a soaring bird pinned against the invisible lid?
## - Long sessions: thermals after hours of air time; how fast the air a
##   hovering bird feels changes (dW/dt).
## - Every tier from wren to eagle has perches and tight places to thread.
## - Refuges work as refuges: the rated bird gets from the doorway to the
##   refuge point; a clearly bigger bird cannot follow.
## - Through-flights: in one belfry arch and out of the opposite one; in one
##   barn door and out the other.
## - The first minute: what the starting sparrow has within reach of spawn.

var world: SoaringWorld
var space: PhysicsDirectSpaceState3D
var k_body := 0.16
const G := 9.81


func before_all() -> void:
	k_body = WorldBuild.body_k()
	world = load("res://scenes/world/world.tscn").instantiate()
	world.with_decoration = false
	add_child(world)
	await wait_physics(2)
	space = world.get_world_3d().direct_space_state


func after_all() -> void:
	if world:
		world.set_air_time(0.0)
		world.queue_free()


func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.collision_mask = 1
	return space.intersect_ray(q)


func _overlaps(c: Vector3, r: float) -> bool:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, c)
	return not space.intersect_shape(q, 1).is_empty()


func _cast(from: Vector3, to: Vector3, r: float) -> float:
	var sp := SphereShape3D.new()
	sp.radius = r
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sp
	q.collision_mask = 1
	q.transform = Transform3D(Basis.IDENTITY, from)
	q.motion = to - from
	var res := space.cast_motion(q)
	return res[0] if res.size() > 0 else 1.0


## Clear start and an untouched sweep (a cast ignores what it starts in).
func _fits(from: Vector3, to: Vector3, r: float) -> bool:
	return not _overlaps(from, r) and _cast(from, to, r) >= 1.0


## Radius of a species' slow thermalling circle at 30 deg bank:
## v = 1.1 x min_speed / sqrt(cos bank) (stall speed rises in a bank),
## R = v^2 / (g tan bank). min_speed from SizeRules.performance (core).
func _circle_radius(mass: float, bank_deg := 30.0) -> float:
	var perf := SizeRules.performance(mass)
	var b := deg_to_rad(bank_deg)
	var v := 1.1 * float(perf["min_speed"]) / sqrt(cos(b))
	return v * v / (G * tan(b))


func _mean_lift_on_circle(c: Vector3, radius: float) -> float:
	var s := 0.0
	for k in 48:
		var a := TAU * k / 48.0
		s += world.get_wind(c + Vector3(cos(a), 0, sin(a)) * radius).y
	return s / 48.0


# --- 1. soaring for every size -------------------------------------------------

func test_thermals_carry_every_size() -> void:
	# FLIGHT_SPEC FM-19: circling at 30 deg bank in a uniform 3 m/s updraft
	# climbs +1.98..+2.32 m/s, i.e. circling sink ~0.7-1.0 m/s. So a thermal
	# carries a species if the mean lift on its circle beats ~1.0 m/s; we
	# ask for 1.3 (a visible climb of ~0.3 m/s) in the WORST moment of 10
	# minutes of drift/pulse, at 120 m.
	var ths := world.get_thermals()
	var table := {}
	var worst_by_species := {}
	for sp in SizeRules.SPECIES:
		var id := String(sp["id"])
		if id == "moth":
			continue
		var R := _circle_radius(float(sp["mass"]))
		var worst := INF
		var worst_name := ""
		var per_th := {}
		for i in ths.size():
			var th_worst := INF
			for tt in 21:
				world.set_air_time(float(tt) * 30.0)
				var c := world.wind.thermal_center(i, 120.0)
				th_worst = minf(th_worst, _mean_lift_on_circle(c, R))
			per_th[String(ths[i]["name"])] = snappedf(th_worst, 0.01)
			if th_worst < worst:
				worst = th_worst
				worst_name = String(ths[i]["name"])
		table[id] = {"circle_r": snappedf(R, 0.1), "worst": snappedf(worst, 0.01), "worst_thermal": worst_name, "by_thermal": per_th}
		worst_by_species[id] = worst
	world.set_air_time(0.0)
	# The eagle at other heights too (it is the one near the edge).
	var eagle_R := _circle_radius(3.0)
	var eagle_heights := {}
	for h: float in [50.0, 80.0, 160.0, 200.0]:
		var w := INF
		for i in ths.size():
			if h > float(ths[i]["top"]) - 50.0:
				continue
			w = minf(w, _mean_lift_on_circle(world.wind.thermal_center(i, h), eagle_R))
		eagle_heights[str(int(h))] = snappedf(w, 0.01)
	print("[world-r2exp] thermalling circle (30 deg bank) mean lift, worst over 10 min at 120 m: ", table)
	print("[world-r2exp] eagle (R %.1f m) worst mean lift by height: %s" % [eagle_R, eagle_heights])
	metric("soaring_by_species", table)
	metric("eagle_by_height", eagle_heights)
	for id in worst_by_species:
		gt(worst_by_species[id], 1.3, "every thermal carries a %s circling at 30 deg bank (mean lift on its circle)" % id)


# --- 2. the ceiling -------------------------------------------------------------

func test_no_strong_lift_pins_birds_under_the_lid() -> void:
	# A bird riding lift climbs until something stops it. Thermals fade out
	# 50 m below their tops (< 285 m), but ridge lift is banded relative to
	# the local ground. Where the air still rises strongly just under the
	# 300 m lid, a soaring bird is pressed against an invisible ceiling.
	var R := world.bounds_radius
	var y := world.ceiling - 2.0
	var inner_worst := 0.0
	var inner_over1 := 0
	var cells := 0
	var over1 := 0
	var over2 := 0
	var worst := 0.0
	var worst_at := Vector3.ZERO
	var x := -R
	while x <= R:
		var z := -R
		while z <= R:
			if Vector2(x, z).length() < R - 1.0 and world.ground_height(x, z) < y - 3.0:
				cells += 1
				var wy := world.get_wind(Vector3(x, y, z)).y
				if Vector2(x, z).length() < R - WindField.EDGE_BAND:
					inner_worst = maxf(inner_worst, wy)
					if wy > 1.0:
						inner_over1 += 1
				if wy > 1.0:
					over1 += 1
				if wy > 2.0:
					over2 += 1
				if wy > worst:
					worst = wy
					worst_at = Vector3(x, y, z)
			z += 8.0
		x += 8.0
	var a1 := over1 * 64.0
	var a2 := over2 * 64.0
	# Where is it? Report the ground and radius at the worst point.
	var g := world.ground_height(worst_at.x, worst_at.z)
	print("[world-r2exp] lift at %.0f m (lid at %.0f): worst %.2f m/s at %s (ground %.0f m, r %.0f m); area > 1 m/s %.0f m2, > 2 m/s %.0f m2 (of %.0f m2 of air at that height)" % [
		y, world.ceiling, worst, worst_at, g, Vector2(worst_at.x, worst_at.z).length(), a1, a2, cells * 64.0])
	print("[world-r2exp] lid lift inside the soft-edge band (r < R - %.0f): worst %.2f m/s, area > 1 m/s %.0f m2" % [WindField.EDGE_BAND, inner_worst, inner_over1 * 64.0])
	metric("lid_lift", {"worst": worst, "at": worst_at, "area_over_1": a1, "area_over_2": a2, "air_area": cells * 64.0,
		"inner_worst": inner_worst, "inner_area_over_1": inner_over1 * 64.0})
	# Inside the soft-edge band the inward push (up to 6 m/s) carries a bird
	# off the wall, so the strict check applies to the rest of the arena;
	# the whole-arena number is reported above.
	lt(inner_worst, 1.0, "no updraft over 1 m/s just under the invisible lid, away from the pushing edge")


# --- 3. long sessions -----------------------------------------------------------

func test_air_after_hours_and_its_rate_of_change() -> void:
	var ths := world.get_thermals()
	var R := world.bounds_radius
	var bad: Array = []
	var core_min := INF
	var core_max := 0.0
	for t: float in [0.0, 3600.0, 36000.0, 360000.0, 3.6e6]:
		world.set_air_time(t)
		for i in ths.size():
			var c := world.wind.thermal_center(i, 120.0)
			var base: Vector3 = world.get_thermals()[i]["position"]
			var core := world.get_wind(c).y
			core_min = minf(core_min, core)
			core_max = maxf(core_max, core)
			if core < 3.0 or core > 5.0:
				bad.append("t=%.0f %s core %.2f" % [t, ths[i]["name"], core])
			if Vector2(c.x, c.z).length() > R - 60.0:
				bad.append("t=%.0f %s drifted to r %.0f" % [t, ths[i]["name"], Vector2(c.x, c.z).length()])
			if not is_finite(core) or not is_finite(base.x):
				bad.append("t=%.0f %s not finite" % [t, ths[i]["name"]])
	# How fast the air changes for a bird holding still (gusts, drift, pulse):
	# a jerky field makes flight (and haptics) twitch.
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst_dt := 0.0
	var worst_dt_at := ""
	for n in 6000:
		var i := rng.randi() % ths.size()
		var t := rng.randf_range(0.0, 7200.0)
		world.set_air_time(t)
		var c := world.wind.thermal_center(i, 100.0)
		var p := c + Vector3(rng.randf_range(-45, 45), rng.randf_range(-60, 120), rng.randf_range(-45, 45))
		var w0 := world.get_wind(p)
		world.set_air_time(t + 0.05)
		var w1 := world.get_wind(p)
		var rate := (w1 - w0).length() / 0.05
		if rate > worst_dt:
			worst_dt = rate
			worst_dt_at = "%s t=%.1f" % [p.snapped(Vector3.ONE * 0.1), t]
	world.set_air_time(0.0)
	print("[world-r2exp] thermal cores over 0 s..1000 h: [%.2f, %.2f] m/s; problems %s; worst |dW/dt| for a still bird %.3f m/s^2 at %s" % [
		core_min, core_max, bad.slice(0, 6), worst_dt, worst_dt_at])
	metric("long_run", {"core_min": core_min, "core_max": core_max, "problems": bad, "worst_dwdt": worst_dt})
	eq(bad.size(), 0, "thermals stay 3-5 m/s, inside the arena and finite after 1000 h of air time")
	lt(worst_dt, 1.0, "the air a still bird feels changes by < 1 m/s per second")


# --- 4. every tier has places --------------------------------------------------

func test_every_tier_has_perches_and_tight_places() -> void:
	var ops := world.get_openings()
	var perches := world.get_perches()
	var table := {}
	var thin: Array = []
	for i in SizeRules.SPECIES.size():
		var sp: Dictionary = SizeRules.SPECIES[i]
		var id := String(sp["id"])
		if id == "moth":
			continue
		var span: float = sp["span"]
		var fit := 0
		var tight := 0
		var types := {}
		var tight_types := {}
		for o in ops:
			var ms: float = o["max_span"]
			if ms >= span:
				fit += 1
				types[o["type"]] = true
				# Tight for this bird: it fits, but a bird twice its span does not.
				if ms < span * 2.0:
					tight += 1
					tight_types[o["type"]] = true
		var perch_fit := 0
		for p in perches:
			if p.max_span >= span:
				perch_fit += 1
		table[id] = {"openings_fit": fit, "opening_types": types.size(), "tight": tight, "tight_types": tight_types.keys(), "perches": perch_fit}
		if perch_fit < 20 or types.size() < 3:
			thin.append(id)
	print("[world-r2exp] per species (openings it fits / types / tight (< 2x span) / perches): ", table)
	metric("tiers", table)
	eq(thin.size(), 0, "every tier wren..eagle has >= 20 perches and >= 3 kinds of opening it can fly through: %s" % [thin])


# --- 5. refuges work as refuges ------------------------------------------------

func test_refuges_reachable_by_their_birds_only() -> void:
	# The AI links each refuge to the nearest "opening" landmark and flies in
	# along its normal. The rated bird must get from 1 m outside that doorway
	# to the refuge point untouched; a bird 1.5x its span must not.
	var ops := world.get_openings()
	var by_kind := {}
	var fails: Array = []
	for rf in world.get_refuges():
		var rp: Vector3 = rf["position"]
		var best: Dictionary = {}
		var bd := INF
		for o in ops:
			var d := rp.distance_to(o["position"])
			if d < bd:
				bd = d
				best = o
		var nm := String(rf["name"])
		var kind := nm.get_slice("_", 0)
		var e: Dictionary = by_kind.get(kind, {"n": 0, "in_ok": 0, "big_kept_out": 0, "door_far": 0})
		e["n"] += 1
		var span: float = rf["max_span"]
		var r := k_body * span
		var n: Vector3 = best["normal"]
		var door: Vector3 = best["position"]
		var outside := door + n * (r + 1.0)
		var ok_in := false
		# Straight from the doorway, or doorway -> just inside -> refuge.
		var inner := door - n * minf(float(best["depth"]) * 0.5, 0.6)
		if _fits(outside, rp, r) or (_fits(outside, inner, r) and _fits(inner, rp, r)):
			ok_in = true
			e["in_ok"] += 1
		elif fails.size() < 12:
			fails.append("%s (door %s %.1f m away, span %.2f)" % [nm, best["name"], bd, span])
		var rb := r * 1.5
		var big_in := _fits(door + n * (rb + 1.0), rp, rb) or (_fits(door + n * (rb + 1.0), inner, rb) and _fits(inner, rp, rb))
		if not big_in:
			e["big_kept_out"] += 1
		if bd > 6.0:
			e["door_far"] += 1
		by_kind[kind] = e
	print("[world-r2exp] refuges by kind {n, rated bird gets in, 1.5x bird kept out, nearest door > 6 m}: ", by_kind)
	print("[world-r2exp] refuges the rated bird cannot reach from their nearest doorway: ", fails)
	metric("refuges", by_kind)
	metric("refuge_fails", fails)
	var n_all := 0
	var in_all := 0
	var out_all := 0
	for k in by_kind:
		n_all += by_kind[k]["n"]
		in_all += by_kind[k]["in_ok"]
		out_all += by_kind[k]["big_kept_out"]
	gt(float(in_all) / n_all, 0.95, "the rated bird reaches >= 95% of refuges from their nearest doorway")
	gt(float(out_all) / n_all, 0.95, "a 1.5x bird is kept out of >= 95% of refuges")


# --- 6. through-flights ---------------------------------------------------------

func test_belfry_and_barn_through_flights() -> void:
	var ops := world.get_openings()
	var belfry: Array = ops.filter(func(o: Dictionary) -> bool: return o["type"] == "belfry")
	var barn: Array = ops.filter(func(o: Dictionary) -> bool: return o["type"] == "barn_door")
	var res := {}
	var fails: Array = []
	for group in [["belfry", belfry], ["barn", barn]]:
		var arr: Array = group[1]
		var pairs := 0
		var ok := 0
		for a in arr:
			# The opening facing most nearly the other way.
			var bst: Dictionary = {}
			var dotmin := 2.0
			for b in arr:
				if b == a:
					continue
				var dd := (a["normal"] as Vector3).dot(b["normal"])
				if dd < dotmin:
					dotmin = dd
					bst = b
			if bst.is_empty() or dotmin > -0.9:
				continue
			pairs += 1
			# Ratings above the ladder's largest bird (eagle 2.1 m) name no real
			# bird: test the largest real one (the belfry is rated 4.4 m).
			var span := minf(minf(a["max_span"], bst["max_span"]), 2.1)
			var r := k_body * span
			var p0: Vector3 = a["position"] + (a["normal"] as Vector3) * (r + 1.5)
			var p1: Vector3 = bst["position"] + (bst["normal"] as Vector3) * (r + 1.5)
			# A player/NPC of the rated size and a pigeon-sized one.
			var rated := _fits(p0, p1, r)
			var pig := _fits(p0, p1, k_body * 0.66)
			if rated:
				ok += 1
			else:
				fails.append("%s -> %s rated %.2f blocked (pigeon %s)" % [a["name"], bst["name"], span, pig])
		res[group[0]] = {"pairs": pairs, "through": ok}
	print("[world-r2exp] through-flights: %s; blocked: %s" % [res, fails])
	metric("through_flights", res)
	gt(float(res["belfry"]["pairs"]), 1.0, "the belfry has opposite arches")
	eq(res["belfry"]["through"], res["belfry"]["pairs"], "in one belfry arch and straight out of the opposite one")
	eq(res["barn"]["through"], res["barn"]["pairs"], "in one barn door and straight out of the other")


# --- 7. the first minute --------------------------------------------------------

func test_first_minute_around_spawn() -> void:
	var sp := world.get_player_spawn().origin
	var span := 0.24
	var perch := 0
	for p in world.get_perches():
		if p.max_span >= span and p.position.distance_to(sp) < 150.0:
			perch += 1
	var ops := 0
	var types := {}
	for o in world.get_openings():
		if float(o["max_span"]) >= span and (o["position"] as Vector3).distance_to(sp) < 150.0:
			ops += 1
			types[o["type"]] = true
	var th_d := INF
	for th in world.get_thermals():
		var c: Vector3 = th["position"]
		th_d = minf(th_d, Vector2(c.x - sp.x, c.z - sp.z).length())
	var gh := world.ground_height(sp.x, sp.z)
	print("[world-r2exp] spawn %s (%.1f m above ground): within 150 m %d sparrow perches, %d sparrow openings %s; nearest thermal %.0f m" % [
		sp, sp.y - gh, perch, ops, types.keys(), th_d])
	metric("spawn_neighbourhood", {"perches": perch, "openings": ops, "types": types.keys(), "thermal_m": th_d, "height": sp.y - gh})
	gt(float(perch), 30.0, "the starting sparrow has > 30 perches within 150 m")
	gt(float(ops), 5.0, "and > 5 openings it can fly through")
	lt(th_d, 150.0, "and a thermal within 150 m")
	gt(sp.y - gh, 5.0, "the spawn is high enough to launch into a glide")


# --- 8. the belfry, species by species ---------------------------------------------

func test_belfry_by_species() -> void:
	# The belfry arches are rated 4.4 m (entering 1.2 m deep). Which real
	# birds can fly THROUGH the belfry (arch to opposite arch, straight or
	# with a small offset), and which can reach the belfry refuge point from
	# some arch?
	var ops := world.get_openings()
	var belfry: Array = ops.filter(func(o: Dictionary) -> bool: return o["type"] == "belfry")
	var refuge: Dictionary = {}
	for rf in world.get_refuges():
		if String(rf["name"]) == "belfry":
			refuge = rf
	var table := {}
	for sp in SizeRules.SPECIES:
		var id := String(sp["id"])
		var r := k_body * float(sp["span"])
		var through := 0
		var pairs := 0
		for a in belfry:
			for b in belfry:
				if (a["normal"] as Vector3).dot(b["normal"]) > -0.9:
					continue
				pairs += 1
				var up: Vector3 = a["up"]
				var right := up.cross(a["normal"]).normalized()
				var ok := false
				for off in [Vector2.ZERO, Vector2(0, 0.35), Vector2(0, -0.35), Vector2(0.35, 0), Vector2(-0.35, 0), Vector2(0, 0.7), Vector2(0, -0.7)]:
					var o3: Vector3 = right * off.x + up * off.y
					var p0: Vector3 = a["position"] + (a["normal"] as Vector3) * (r + 1.5) + o3
					var p1: Vector3 = b["position"] + (b["normal"] as Vector3) * (r + 1.5) + o3
					if _fits(p0, p1, r):
						ok = true
						break
				if ok:
					through += 1
		var reach := false
		if not refuge.is_empty():
			for a in belfry:
				var p0: Vector3 = a["position"] + (a["normal"] as Vector3) * (r + 1.0)
				var inner: Vector3 = a["position"] - (a["normal"] as Vector3) * 0.6
				if _fits(p0, refuge["position"], r) or (_fits(p0, inner, r) and _fits(inner, refuge["position"], r)):
					reach = true
					break
		table[id] = {"through": "%d/%d" % [through, pairs], "reaches_refuge": reach}
	print("[world-r2exp] belfry by species (through-flights incl. +-0.35/0.7 m offsets; refuge reachable): ", table)
	print("[world-r2exp] belfry refuge: ", refuge, " arches rated ", belfry.map(func(o: Dictionary) -> String: return "%s %.2f w %.2f h %.2f" % [o["name"], o["max_span"], o["width"], o["height"]]))
	metric("belfry_by_species", table)
	check(bool(table["eagle"]["reaches_refuge"]), "every bird the belfry refuge admits (all, up to 4.4 m) reaches it: eagle")
	check(String(table["eagle"]["through"]).begins_with("4") or String(table["hawk"]["through"]).begins_with("4"), "a big bird can fly through the belfry")
