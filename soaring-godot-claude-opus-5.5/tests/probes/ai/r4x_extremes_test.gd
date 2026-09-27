extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, requirements lens): the ends of the player's
## range, in the real valley.
##  * apex: GameLoop lets the player grow to MAX_PLAYER_MASS (4.5 kg), past
##    the eagle (3.0 kg). The sky must still hold worthwhile prey and
##    something that would hunt it (A6), stay in band and safe, and the
##    NPCs it makes for that (apex eagles) should stay believable: report
##    their mass and wingspan.
##  * sitting: a player that sits still on the spawn perch for two minutes,
##    looking one way (resting, looking round the valley, reading a menu
##    panel): life around it (prey within 80 / 150 m, a hunter within
##    200 m, anything noticeable ahead), spawns out of the fixed view.
## Report: artifacts/ai/verify/r4/extremes.json
##   tools/gd.sh ai_r4exp2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4x_extremes

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")

var _w: World = null


func before_all() -> void:
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	_w = ps.instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated


func after_all() -> void:
	if is_instance_valid(_w):
		_w.queue_free()
	_w = null
	Habitat.clear_cache()
	await wait_frames(2)


static func _prey(pm: float, n: NpcBird) -> bool:
	return SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)


func _ahead(e: Ecosystem, p: MockPlayer) -> int:
	var eye := p.get_body_position()
	var f: Vector3 = p.get_view_direction()
	f = Vector3(f.x, 0.0, f.z).normalized()
	var right: Vector3 = f.cross(Vector3.UP).normalized()
	var pm := p.mass
	var hl_r := maxf(70.0 * SizeRules.wingspan_for_mass(pm), 6.0 * SizeRules.cruise_speed(pm))
	var n_all := 0
	for n in e.get_npcs():
		if n.hidden or n.state == NpcBird.State.HIDE:
			continue
		var rel := n.global_position - eye
		var d := rel.length()
		if d < 0.5:
			continue
		var hl := _prey(pm, n) or SizeRules.can_eat(n.mass, pm)
		if rad_to_deg(n.get_wingspan() / d) < 0.3 and not (hl and d < hl_r):
			continue
		var fz := rel.dot(f)
		if fz <= 0.0:
			continue
		if rad_to_deg(atan2(absf(rel.dot(right)), fz)) > 50.0 or rad_to_deg(atan2(absf(rel.y), fz)) > 45.0:
			continue
		n_all += 1
	return n_all


func _run(tag: String, pm: float, sitting: bool, seed_v: int, secs: float) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	var sxf := _w.get_player_spawn()
	var sp0 := sxf.origin
	if sitting:
		p.moving = false
		add_child(p)
		p.global_transform = sxf
		var fw := -sxf.basis.z
		p.view_dir = Vector3(fw.x, 0.0, fw.z).normalized() if Vector2(fw.x, fw.z).length() > 0.1 else Vector3.FORWARD
		p.velocity = Vector3.ZERO
	else:
		p.path_center = Vector3(sp0.x, 0, sp0.z)
		p.path_radius = 120.0
		var gmax := 0.0
		for k in 36:
			var a := TAU * k / 36.0
			gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * 120.0, sp0.z + sin(a) * 120.0))
		p.path_height = gmax + 30.0
		add_child(p)
		p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var safety: RefCounted = Safety.new(_w)
	var bad := {"spawn": 0, "examples": []}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		var rel := n.global_position - p.get_body_position()
		if rel.length() < e.spawn_distance(n.get_wingspan()) or p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(75.0)):
			bad["spawn"] += 1
			if bad["examples"].size() < 5:
				bad["examples"].append("%s at %.0f m" % [n.species, rel.length()]))
	var s := {"n": 0, "prey80": 0, "prey2_150": 0, "threat200": 0, "ahead0": 0, "ahead_sum": 0}
	var pop_min := 999
	var hunts := 0
	var hunting := {}
	var apex := {"max_mass": 0.0, "max_span": 0.0}
	var warm := 20.0
	for i in int((warm + secs) / DT):
		var t := i * DT
		air(_w, t)
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if t < warm:
			continue
		pop_min = mini(pop_min, e.count())
		for n in e.get_npcs():
			var on := n.target == p
			if on and not hunting.get(n, false):
				hunts += 1
			hunting[n] = on
		if i % 36 == 0:
			var pp := p.get_body_position()
			var c80 := 0
			var c150 := 0
			var th := 0
			for n in e.get_npcs():
				apex["max_mass"] = maxf(apex["max_mass"], n.mass)
				apex["max_span"] = maxf(apex["max_span"], n.get_wingspan())
				if n.hidden or n.state == NpcBird.State.HIDE:
					continue
				var gp := n.global_position
				var dh := Vector2(gp.x - pp.x, gp.z - pp.z).length()
				if _prey(pm, n):
					if gp.distance_to(pp) < 80.0:
						c80 += 1
					if dh < 150.0:
						c150 += 1
				elif SizeRules.can_eat(n.mass, pm) and Ecosystem.would_hunt(n.species, n.mass, pm) and dh < 200.0:
					th += 1
			var ah := _ahead(e, p)
			s["n"] += 1
			s["prey80"] += 1 if c80 >= 1 else 0
			s["prey2_150"] += 1 if c150 >= 2 else 0
			s["threat200"] += 1 if th >= 1 else 0
			s["ahead0"] += 1 if ah == 0 else 0
			s["ahead_sum"] += ah
	var k := maxf(s["n"], 1)
	var st := e.stats()
	var row := {"tag": tag, "player_mass": pm, "sitting": sitting, "seed": seed_v, "seconds": secs,
		"prey80_share": s["prey80"] / k, "prey2_150_share": s["prey2_150"] / k, "threat200_share": s["threat200"] / k,
		"nothing_ahead_share": s["ahead0"] / k, "mean_ahead": s["ahead_sum"] / k, "pop_min": pop_min,
		"hunts_on_player_per_min": hunts / (secs / 60.0), "player_caught": p.times_caught,
		"spawns_in_view_or_near": bad["spawn"], "spawn_examples": bad["examples"], "largest_npc": apex,
		"plan": st["plan"], "roles": st["by_role"], "safety": safety.counts.duplicate(), "safety_examples": safety.examples}
	print("[ai-r4x] extremes %s: %s" % [tag, JSON.stringify(row)])
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func test_r4x_extremes() -> void:
	if _w == null:
		return
	var rows := {}
	rows["apex_4_5kg"] = await _run("apex_4_5kg", 4.5, false, 4601, 150.0)
	rows["sitting_sparrow"] = await _run("sitting_sparrow", 0.03, true, 4602, 120.0)
	rows["sitting_pigeon"] = await _run("sitting_pigeon", 0.3, true, 4603, 120.0)
	var dir := Paths.artifacts("ai").path_join("verify/r4")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("extremes.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	for tag in rows:
		var r: Dictionary = rows[tag]
		gt(r["prey2_150_share"], 0.9, "%s: two visible worthwhile prey within 150 m" % tag)
		gt(r["prey80_share"], 0.65, "%s: a visible worthwhile prey within 80 m" % tag)
		gt(r["threat200_share"], 0.9, "%s: a bird that would hunt it within 200 m" % tag)
		gt(r["pop_min"], 55, "%s: population in band" % tag)
		eq(r["spawns_in_view_or_near"], 0, "%s: spawns in view or near %s" % [tag, r["spawn_examples"]])
		for kk in r["safety"]:
			eq(r["safety"][kk], 0, "%s: safety %s %s" % [tag, kk, r["safety_examples"]])
