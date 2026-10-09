extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2, experience lens): how many birds does the player
## actually SEE ahead of it? The builder's A6 metrics count birds in every
## direction (behind the player too) and count birds hidden inside refuges.
## A headset shows a ~106 x 96 deg field; this probe counts NPCs that are
##  * not hidden in a refuge,
##  * inside a forward view frustum along the flight path (50 deg half-angle
##    horizontally, 45 deg vertically),
##  * and big enough to notice: >= 0.3 deg across (about 6 px on a Quest Pro;
##    a sparrow within 46 m, a pigeon within 126 m, an eagle within 400 m),
##    or highlighted by GameLoop (worthwhile prey / can eat the player) and
##    within its highlight range (drawn >= 0.7 deg there).
## In the AI test world (the builder's evidence arena) and the real valley
## (SoaringWorld), for a lapping and a travelling player at three sizes.
## Records the mean count, the share of samples with nothing to see ahead,
## and the share with no worthwhile prey visible ahead.
## Report: artifacts/ai/verify/r2/forward_view.json.
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r2x_forward_view

const WARM_S := 25.0
const MEAS_S := 90.0
const MIN_ANG := 0.3


func _visible_ahead(e: Ecosystem, p: Bird, pm: float) -> Array:
	var eye := p.get_body_position()
	var f: Vector3 = p.get_view_direction()
	f = Vector3(f.x, 0.0, f.z).normalized()
	var right: Vector3 = f.cross(Vector3.UP).normalized()
	var n_all := 0
	var n_prey := 0
	var n_threat := 0
	for n in e.get_npcs():
		if n.hidden or n.state == NpcBird.State.HIDE:
			continue
		var rel := n.global_position - eye
		var d := rel.length()
		if d < 0.5:
			continue
		# GameLoop draws highlighted birds (worthwhile prey, birds that can
		# eat the player) at >= 0.7 deg within its highlight range
		# (ThreatWatch.highlight_range: max(70 spans, 6 s of cruise)), so
		# those count as noticeable there whatever their size.
		var hl := (SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)) or SizeRules.can_eat(n.mass, pm)
		var hl_r := maxf(70.0 * SizeRules.wingspan_for_mass(pm), 6.0 * SizeRules.cruise_speed(pm))
		if rad_to_deg(n.get_wingspan() / d) < MIN_ANG and not (hl and d < hl_r):
			continue
		var fz := rel.dot(f)
		if fz <= 0.0:
			continue
		var az := rad_to_deg(atan2(absf(rel.dot(right)), fz))
		var el := rad_to_deg(atan2(absf(rel.y), fz))
		if az > 50.0 or el > 45.0:
			continue
		n_all += 1
		if SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass):
			n_prey += 1
		elif SizeRules.can_eat(n.mass, pm):
			n_threat += 1
	return [n_all, n_prey, n_threat]


func _run(w: World, tag: String, pm: float, travel: bool, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	var c := w.get_player_spawn().origin if not (w is AiTestWorld) else Vector3(-20, 0, 10)
	p.path_center = Vector3(c.x, 0, c.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, w.ground_height(c.x + cos(a) * 90.0, c.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	if travel:
		p.travel = true
		p.speed = 12.0
		var y := 0.0
		for k in 61:
			y = maxf(y, w.ground_height(-300.0 + k * 10.0, c.z))
		p.line_a = Vector3(-300, y + 22.0, c.z)
		p.line_b = Vector3(300, y + 22.0, c.z)
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_v)
	e.focus = p
	if Paths.arg("r2x_no_recycle", "") != "":
		# Counterfactual: no "left behind a travelling player" recycling
		# (only the ordinary despawn_radius), to see what the churn costs.
		e.recycle_behind = 1e9
		e.recycle_behind_slow = 1e9
	var chk := make_checker()
	var s := {"n": 0, "sum": 0, "zero": 0, "no_prey": 0, "prey_sum": 0, "threat_sum": 0, "hidden": 0.0}
	for i in int((WARM_S + MEAS_S) / DT):
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		if i * DT > WARM_S and i % 36 == 0:
			var r := _visible_ahead(e, p, pm)
			s["n"] += 1
			s["sum"] += r[0]
			s["prey_sum"] += r[1]
			s["threat_sum"] += r[2]
			s["zero"] += 1 if r[0] == 0 else 0
			s["no_prey"] += 1 if r[1] == 0 else 0
			var hid := 0
			for n in e.get_npcs():
				if n.hidden:
					hid += 1
			s["hidden"] += float(hid) / maxf(e.count(), 1)
	var n: float = maxf(s["n"], 1)
	var out := {"tag": tag, "mass": pm, "travel": travel, "samples": s["n"],
		"mean_visible_ahead": s["sum"] / n, "share_nothing_ahead": s["zero"] / n,
		"mean_prey_ahead": s["prey_sum"] / n, "share_no_prey_ahead": s["no_prey"] / n,
		"mean_threats_ahead": s["threat_sum"] / n, "hidden_share": s["hidden"] / n}
	print("[ai-r2x] forward %s: %s" % [tag, JSON.stringify(out)])
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	checker = null
	await wait_frames(2)
	return out


func test_r2x_forward_view() -> void:
	var res := {}
	var cases := [["sparrow", 0.03, false], ["pigeon", 0.3, false], ["eagle", 3.0, false], ["sparrow_travel", 0.03, true], ["pigeon_travel", 0.3, true]]
	# Seeds are fixed per case (test world 61.., real valley 66..), so a
	# filtered or counterfactual run (--r2x_no_recycle) replays the same seeds.
	for i in cases.size():
		cases[i].append(i)
	if Paths.arg("r2x_cases", "") != "":
		var only: PackedStringArray = Paths.arg("r2x_cases", "").split(",")
		cases = cases.filter(func(c: Array) -> bool: return only.has(c[0]))
	var worlds: String = Paths.arg("r2x_worlds", "test,real")
	# The builder's evidence arena.
	if worlds.contains("test"):
		await make_world(false, 1)
		for c in cases:
			res["testworld_" + c[0]] = await _run(world, "testworld_" + c[0], c[1], c[2], 61 + c[3])
		await clear_sim()
	# The real valley.
	if worlds.contains("real"):
		var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(rw)
		await wait_physics(3)
		for c in cases:
			res["realworld_" + c[0]] = await _run(rw, "realworld_" + c[0], c[1], c[2], 66 + c[3])
		rw.queue_free()
		Habitat.clear_cache()
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("verify/r2"))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("verify/r2/forward_view%s.json" % ("_no_recycle" if Paths.arg("r2x_no_recycle", "") != "" else "")), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	for t in res:
		var r: Dictionary = res[t]
		lt(r["share_nothing_ahead"], 0.3, "%s: share of time with no noticeable bird ahead" % t)
		gt(r["mean_visible_ahead"], 2.0, "%s: mean noticeable birds ahead" % t)
	await wait_frames(2)
