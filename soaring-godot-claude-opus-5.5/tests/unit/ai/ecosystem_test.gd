extends "res://tests/unit/ai/ai_sim.gd"
## A6 Ecosystem (+ A7 rates): the population around a player.
##  * Growth: a mock player flies laps while growing from sparrow to eagle
##    (exponentially over 4 minutes, then holds): population within target
##    - tolerance .. target; worthwhile prey and *effective* threats (birds
##    that would actually hunt the player: they can eat it, it is worth
##    their while, and they are real hunters) near it essentially all the
##    time; the mix re-balances (smallest give way to larger prey, apex
##    eagles once nothing else would eat the player).
##  * Travel: a mock player crossing the valley back and forth in straight
##    legs at 12 m/s, looking where it flies (the hardest case: it outruns
##    slow prey and spawns must stay out of its forward view), at four
##    sizes: life around it (birds within 100 m, worthwhile prey within
##    60/80 m, threats within 200 m) and hunts started on it per minute.
##  * Every spawn is checked independently: outside the view cone and
##    beyond the bird's near distance (150 of its wingspans - under 0.4 deg -
##    clamped to 40..spawn_min m); despawns only out of view.
##  * Safety (A5 monitor), determinism per seed, reset(), LOD by distance.
## Evidence (the long runs: --ai_full=1): artifacts/ai/ecosystem_growth.png,
## ecosystem_report.json, ecosystem_travel.json; the suite's shorter runs
## write *_suite.* beside them.

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const EcoPlot := preload("res://tests/unit/ai/eco_plot.gd")
## Growth over GROW_S then holding HOLD_S: 240 + 30 s in the evidence run
## (--ai_full=1), 150 + 15 s in the suite.
var GROW_S := 240.0
var HOLD_S := 30.0
const NEAR_PREY := 150.0
const NEAR_THREAT := 200.0
## Travel runs: TRAVEL_S each, measured after TRAVEL_WARMUP_S (four sizes
## for 90 s in the evidence run, two for 70 s in the suite).
var TRAVEL_S := 90.0
const TRAVEL_WARMUP_S := 20.0


func before_all() -> void:
	if not full():
		GROW_S = 150.0
		HOLD_S = 15.0
		TRAVEL_S = 70.0
	await make_world(false, 1)


func after_all() -> void:
	await clear_sim()


## Would this bird hunt a bird of mass pm? Stated here independently of the
## Ecosystem: it can eat it, the meal is worth it by the game's rule
## (SizeRules.is_worthwhile, what NpcBrain hunts by) and its species is a
## real hunter (hunt drive >= 0.45).
static func _hunts(n: NpcBird, pm: float) -> bool:
	return SizeRules.can_eat(n.mass, pm) and SizeRules.is_worthwhile(n.mass, pm) \
		and float(SpeciesProfile.of(n.species)["hunt"]) >= 0.45


## The view cone spawns must stay out of, stated here independently of the
## Ecosystem's own setting: the Quest Pro shows ~106 deg across (53 deg
## half-angle) and a player glances round, so 75 deg.
const VIEW_HALF_DEG := 75.0


## Spawn/despawn watchdog: every spawn must be out of the view cone and
## beyond the bird's near distance; despawns (other than caught/reset) out
## of view.
func _watch_spawns(e: Ecosystem, p: Bird) -> Dictionary:
	var m := {"spawn_view": 0, "spawn_near": 0, "despawn_view": 0, "spawns": 0, "despawns": 0, "near_min": INF}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		m["spawns"] += 1
		var rel := n.global_position - p.get_body_position()
		var near := clampf(150.0 * n.get_wingspan(), 40.0, e.spawn_min)
		m["near_min"] = minf(m["near_min"], rel.length() - near)
		if rel.length() < near:
			m["spawn_near"] += 1
		elif p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
			m["spawn_view"] += 1)
	e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
		if reason == &"caught" or reason == &"reset":
			return
		m["despawns"] += 1
		var rel := n.global_position - p.get_body_position()
		if rel.length() < e.spawn_min or p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
			m["despawn_view"] += 1)
	return m


## What is around the player right now.
static func _around(e: Ecosystem, p: Bird) -> Dictionary:
	var pp := p.get_body_position()
	var pm := p.mass
	var r := {"prey150": 0, "prey60": 0, "prey80": 0, "dust": 0, "peer": 0, "threat": 0, "n100": 0}
	for n in e.get_npcs():
		var gp := n.global_position
		var d3 := gp.distance_to(pp)
		# Horizontal distance for the wide metrics: a raptor circling 150 m
		# overhead is right there (it stoops from up there).
		var dh := Vector2(gp.x - pp.x, gp.z - pp.z).length()
		if d3 < 100.0:
			r["n100"] += 1
		if SizeRules.can_eat(pm, n.mass):
			if SizeRules.is_worthwhile(pm, n.mass):
				if dh < NEAR_PREY:
					r["prey150"] += 1
				if d3 < 60.0:
					r["prey60"] += 1
				if d3 < 80.0:
					r["prey80"] += 1
			elif dh < NEAR_PREY:
				r["dust"] += 1
		elif _hunts(n, pm):
			if dh < NEAR_THREAT:
				r["threat"] += 1
		elif dh < NEAR_PREY and not SizeRules.can_eat(n.mass, pm):
			r["peer"] += 1
	return r


func test_population_follows_a_growing_player() -> void:
	var p := MockPlayer.new()
	p.mass = 0.03
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 5)
	e.focus = p
	var chk := make_checker()
	var safety := Safety.new(world)
	var m := _watch_spawns(e, p)
	if OS.get_environment("AI_DEBUG") != "":
		e.npc_spawned.connect(func(n: NpcBird) -> void:
			if n.species == &"eagle":
				print("[ai]  + eagle %.2f kg key %s at %.0f m (pm %.2f)" % [n.mass, e._npc_key.get(n.get_instance_id(), &""), n.global_position.distance_to(p.global_position), p.mass]))
		e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
			if n.species == &"eagle":
				print("[ai]  - eagle %.2f kg %s (pm %.2f)" % [n.mass, reason, p.mass]))
	var series := []
	var sec := {"ok_count": 0, "prey": 0, "threat": 0, "n": 0}
	var hunting := {}
	var tier_hunts := {}
	var tier_time := {}
	# The fairness rules on the player: at most one NPC after it at a time,
	# and a hunter whose chase on it ended without the catch leaves it alone
	# for 40 s (NpcBrain.MAX_PLAYER_CHASERS / PLAYER_COOLDOWN_S).
	var chase := {"max_at_once": 0, "ended": {}, "too_soon": 0, "min_gap": INF}
	var total := int((GROW_S + HOLD_S) / DT)
	for i in total:
		var t := i * DT
		p.mass = 0.03 * pow(4.5 / 0.03, minf(t / GROW_S, 1.0))
		# A run starts with the player sitting on its spawn perch (GameLoop
		# places it there); it takes off after 5 s.
		p.moving = t > 5.0
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		var tier := String(SizeRules.species_for_mass(p.mass))
		tier_time[tier] = tier_time.get(tier, 0.0) + DT
		var at_once := 0
		for n in e.get_npcs():
			var on := n.target == p
			if on:
				at_once += 1
			if on and not hunting.get(n, false):
				tier_hunts[tier] = tier_hunts.get(tier, 0) + 1
				if chase["ended"].has(n):
					var gap: float = t - float(chase["ended"][n])
					chase["min_gap"] = minf(chase["min_gap"], gap)
					if gap < 39.0:
						chase["too_soon"] += 1
			elif not on and hunting.get(n, false):
				# Ended in failure (given up - not broken off to flee a
				# bigger bird, not a meal of the player).
				if n.digest <= 0.0 and not n.brain.give_up_reason.begins_with("left:"):
					chase["ended"][n] = t
			hunting[n] = on
		chase["max_at_once"] = maxi(chase["max_at_once"], at_once)
		if i % 72 == 0 and t > 2.0:
			var c := e.count()
			sec["n"] += 1
			if c >= e.max_npcs - e.tolerance and c <= e.max_npcs:
				sec["ok_count"] += 1
			var roles := _around(e, p)
			if roles["prey150"] >= 2:
				sec["prey"] += 1
			if roles["threat"] >= 1:
				sec["threat"] += 1
			if OS.get_environment("AI_DEBUG") != "" and (c < e.max_npcs - e.tolerance or roles["threat"] < 1 or roles["prey150"] < 2):
				print("[ai] t=%.0f pm %.2f count %d roles %s plan %s" % [t, p.mass, c, roles, e.stats()["plan"]])
				for n0 in e.get_npcs():
					if roles["prey150"] < 2 and SizeRules.can_eat(p.mass, n0.mass):
						print("[ai]    prey %s %.3f kg %s dh %.0f worth %s home->p %.0f hr %.0f flock %s" % [n0.species, n0.mass, n0.state_name(), Vector2(n0.global_position.x - p.global_position.x, n0.global_position.z - p.global_position.z).length(), SizeRules.is_worthwhile(p.mass, n0.mass), Vector2(n0.home.x - p.global_position.x, n0.home.z - p.global_position.z).length(), n0.home_radius, n0.flock != null])
					if n0.species == &"eagle" and roles["threat"] < 1:
						print("[ai]    eagle %.2f kg (eats %.2f) %s dh %.0f key %s" % [n0.mass, n0.mass / SizeRules.EAT_RATIO, n0.state_name(), Vector2(n0.global_position.x - p.global_position.x, n0.global_position.z - p.global_position.z).length(), e._npc_key.get(n0.get_instance_id(), &"")])
					if SizeRules.can_eat(n0.mass, p.mass) and roles["threat"] < 1:
						print("[ai]    eater %s %.2f kg %s dh %.0f hunts %s key %s" % [n0.species, n0.mass, n0.state_name(), Vector2(n0.global_position.x - p.global_position.x, n0.global_position.z - p.global_position.z).length(), _hunts(n0, p.mass), e._npc_key.get(n0.get_instance_id(), &"")])
			series.append([t, p.mass, {"prey": roles["prey150"], "threat": roles["threat"], "peer": roles["peer"]}, c])
	var n: int = sec["n"]
	gt(float(sec["ok_count"]) / n, 0.99, "population within target - tolerance .. target")
	gt(float(sec["prey"]) / n, 0.99, "at least 2 worthwhile prey within 150 m (horizontally) of the player")
	gt(float(sec["threat"]) / n, 0.99, "at least 1 bird that would hunt the player within 200 m (horizontally)")
	eq(m["spawn_view"], 0, "no spawn inside the player's view cone")
	eq(m["spawn_near"], 0, "no spawn within the bird's near distance of the player")
	eq(m["despawn_view"], 0, "no despawn inside the player's view cone")
	gt(m["despawns"], 5, "the mix was re-balanced as the player grew (surplus/far birds recycled)")
	for k in safety.counts:
		eq(safety.counts[k], 0, "safety: %s" % k)
	# At eagle size: the plan has larger prey and apex threats, no swarm of dust.
	var plan: Dictionary = e.stats()["plan"]
	check(plan.has(String(Ecosystem.APEX_KEY)), "apex eagles planned once nothing in the ladder would hunt the player")
	var apex := 0
	var dust := 0
	for npc in e.get_npcs():
		if npc.mass >= p.mass * SizeRules.EAT_RATIO:
			apex += 1
		if SizeRules.can_eat(p.mass, npc.mass) and not SizeRules.is_worthwhile(p.mass, npc.mass):
			dust += 1
	gt(apex, 0, "apex threats flying at the end")
	lt(dust, e.max_npcs * 0.35, "dust (too small to matter) is a minority at eagle size")
	var npc_catches := 0
	for c in chk.catches:
		if c["prey"] != p:
			npc_catches += 1
	var hunts_pm := {}
	var all_hunts := 0
	for k in tier_hunts:
		hunts_pm[k] = snappedf(tier_hunts[k] / (tier_time[k] / 60.0), 0.1)
		all_hunts += tier_hunts[k]
	# Danger, not a siege, at every size: at most 6 hunts a minute in each
	# tier the player spent >= 20 s in (plus 2 for the short samples - a
	# siege with the fairness rules off is 16 a minute).
	for k in tier_time:
		if tier_time[k] >= 20.0:
			lt(float(tier_hunts.get(k, 0)), 6.0 * tier_time[k] / 60.0 + 2.0, "%s-sized player: hunts started on it in %.0f s (no siege)" % [k, tier_time[k]])
	between(all_hunts / ((GROW_S + HOLD_S) / 60.0), 1.0, 6.0, "hunts started on the growing player per minute, overall")
	lt(chase["max_at_once"], 2, "never more than one NPC chasing the player at once")
	eq(chase["too_soon"], 0, "a hunter whose chase on the player failed leaves it alone for 40 s (closest re-try %.1f s)" % chase["min_gap"])
	var report := {"seconds": n, "population_ok_share": float(sec["ok_count"]) / n,
		"prey_share": float(sec["prey"]) / n, "threat_share": float(sec["threat"]) / n,
		"spawns": m["spawns"], "despawns": m["despawns"], "violations": {"spawn_view": m["spawn_view"], "spawn_near": m["spawn_near"], "despawn_view": m["despawn_view"]},
		"closest_spawn_beyond_near_m": snappedf(m["near_min"], 0.01),
		"safety": safety.counts, "plan_end": plan, "npc_catches": npc_catches,
		"npc_catches_per_min": snappedf(npc_catches / ((GROW_S + HOLD_S) / 60.0), 0.1),
		"player_caught": p.times_caught, "hunts_on_player_per_min_by_tier": hunts_pm,
		"tier_seconds": tier_time, "tick_ms_avg": e.stats()["tick_ms_avg"],
		"chasers_max_at_once": chase["max_at_once"], "player_retry_min_gap_s": chase["min_gap"]}
	metric("ecosystem", report)
	print("[ai] growth: %s" % report)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("ecosystem_report%s.json" % ("" if full() else "_suite")), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	_plot(series)
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await wait_frames(1)


## A player crossing the valley in straight legs at 12 m/s, looking where it
## flies, at four sizes (90 s each, measured after 20 s).
func test_life_around_a_travelling_player() -> void:
	var table := {}
	for pm: float in ([0.03, 0.1, 0.3, 1.3] if full() else [0.03, 0.3]):
		var p := MockPlayer.new()
		p.mass = pm
		p.travel = true
		p.speed = 12.0
		add_child(p)
		p.step(0.0)
		var e := make_eco(60, 11)
		e.focus = p
		var chk := make_checker()
		var safety := Safety.new(world)
		var m := _watch_spawns(e, p)
		var s := {"n": 0, "band": 0, "prey150": 0, "prey60": 0, "prey80": 0, "threat": 0, "n100": 0.0}
		var hunting := {}
		var hunts := 0
		for i in int(TRAVEL_S / DT):
			p.step(DT)
			e.step(DT)
			chk.step(DT)
			safety.step(DT, e.get_npcs())
			if i * DT < TRAVEL_WARMUP_S:
				continue
			for n in e.get_npcs():
				var on := n.target == p
				if on and not hunting.get(n, false):
					hunts += 1
				hunting[n] = on
			if i % 36 == 0:
				var r := _around(e, p)
				s["n"] += 1
				s["band"] += 1 if e.count() >= e.max_npcs - e.tolerance else 0
				s["prey150"] += 1 if r["prey150"] >= 2 else 0
				s["prey60"] += 1 if r["prey60"] >= 1 else 0
				s["prey80"] += 1 if r["prey80"] >= 1 else 0
				s["threat"] += 1 if r["threat"] >= 1 else 0
				s["n100"] += r["n100"]
		var k: float = s["n"]
		var mins := (TRAVEL_S - TRAVEL_WARMUP_S) / 60.0
		var row := {"species": String(SizeRules.species_for_mass(pm)), "population_ok": s["band"] / k,
			"prey150_ge2": s["prey150"] / k, "prey_within_60m": s["prey60"] / k, "prey_within_80m": s["prey80"] / k,
			"threat200": s["threat"] / k, "mean_npcs_within_100m": snappedf(s["n100"] / k, 0.1),
			"hunts_on_player_per_min": snappedf(hunts / mins, 0.1), "player_caught": p.times_caught,
			"spawn_violations": m["spawn_view"] + m["spawn_near"], "despawn_view": m["despawn_view"],
			"spawns": m["spawns"], "safety": safety.counts.duplicate()}
		table[row["species"]] = row
		print("[ai] travel %s: %s" % [row["species"], row])
		var sp: String = row["species"]
		gt(row["population_ok"], 0.99, "%s: population within band while the player travels" % sp)
		gt(row["prey150_ge2"], 0.99, "%s: >= 2 worthwhile prey within 150 m" % sp)
		gt(row["threat200"], 0.99, "%s: a bird that would hunt the player within 200 m" % sp)
		gt(row["mean_npcs_within_100m"], 15.0, "%s: a living sky around a travelling player (birds within 100 m)" % sp)
		gt(row["prey_within_80m"], 0.9, "%s: worthwhile prey within 80 m" % sp)
		gt(row["prey_within_60m"], 0.6, "%s: worthwhile prey within 60 m" % sp)
		gt(row["hunts_on_player_per_min"], 0.5, "%s: hunts started on the player per minute (danger)" % sp)
		lt(row["hunts_on_player_per_min"], 6.0, "%s: hunts started on the player per minute (not a siege)" % sp)
		eq(row["spawn_violations"], 0, "%s: no spawn in view or within the near distance" % sp)
		eq(row["despawn_view"], 0, "%s: no despawn in view" % sp)
		for key in safety.counts:
			eq(safety.counts[key], 0, "%s: safety %s" % [sp, key])
		e.queue_free()
		eco = null
		checker = null
		remove_child(p)
		p.queue_free()
		await wait_frames(2)
	metric("travel", table)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("ecosystem_travel%s.json" % ("" if full() else "_suite")), FileAccess.WRITE)
	f.store_string(JSON.stringify(table, "  "))
	f.close()


func _plot(series: Array) -> void:
	var W := 1200
	var H := 560
	var pl := EcoPlot.Plot.new(W, H, EcoPlot.SURFACE)
	var x0 := 70.0
	var x1 := W - 20.0
	var y0 := H - 60.0
	var y1 := 70.0
	var maxc := 30.0
	var tmax := GROW_S + HOLD_S
	# Grid and axes (recessive).
	for v in [0, 10, 20, 30]:
		var y := lerpf(y0, y1, v / maxc)
		pl.line(Vector2(x0, y), Vector2(x1, y), Color("#e6e5df"))
		pl.text(Vector2(x0 - 30, y - 7), str(v), EcoPlot.INK2, 2)
	# Tier bands: species the player is at.
	var prev_tier := -1
	for s in series:
		var tier := SizeRules.tier_for_mass(s[1])
		if tier != prev_tier:
			var x := lerpf(x0, x1, s[0] / tmax)
			pl.line(Vector2(x, y0), Vector2(x, y1 - 10), Color("#cfcec8"))
			pl.text(Vector2(x + 3, y1 - 26), String(SizeRules.SPECIES[tier]["id"]).to_upper(), EcoPlot.INK2, 1)
			prev_tier = tier
	var keys := ["prey", "threat", "peer"]
	var cols := [EcoPlot.GROUP_COLORS[0], EcoPlot.GROUP_COLORS[2], EcoPlot.GROUP_COLORS[1]]
	for ki in keys.size():
		var pts := PackedVector2Array()
		for s in series:
			pts.append(Vector2(lerpf(x0, x1, s[0] / tmax), lerpf(y0, y1, minf(float(s[2][keys[ki]]), maxc) / maxc)))
		pl.polyline(pts, cols[ki], 1)
	pl.text(Vector2(14, 12), "BIRDS NEAR THE PLAYER AS IT GROWS SPARROW -> EAGLE (%.0f S)" % tmax, EcoPlot.INK, 2)
	pl.text(Vector2(14, 34), "PREY IT CAN EAT (<150M)   THREATS THAT WOULD HUNT IT (<200M)   NEAR-EQUALS (<150M)", EcoPlot.INK2, 1)
	var lx := 14.0
	for ki in keys.size():
		pl.rect(Vector2(lx, H - 30), Vector2(lx + 16, H - 22), cols[ki])
		pl.text(Vector2(lx + 22, H - 34), keys[ki].to_upper(), EcoPlot.INK, 2)
		lx += 150.0
	pl.text(Vector2(x1 - 200, H - 34), "TIME ->", EcoPlot.INK2, 2)
	pl.save(Paths.artifacts("ai").path_join("ecosystem_growth%s.png" % ("" if full() else "_suite")))


func _fingerprint(e: Ecosystem) -> String:
	var parts := []
	for n in e.get_npcs():
		parts.append("%s:%s:%s" % [n.species, n.global_position.snapped(Vector3.ONE * 0.001), n.state])
	return str(hash(",".join(parts))) + "/%d" % parts.size()


func test_deterministic_per_seed_and_reset_clears() -> void:
	var p := MockPlayer.new()
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	add_child(p)
	var e := make_eco(30, 42)
	e.focus = p
	var runs := []
	for r in 3:
		e.reset(42 if r < 2 else 43)
		eq(e.count(), 0, "reset() removes every NPC")
		p.angle = 0.0
		p.mass = 0.09
		p.step(0.0)
		for i in int(20.0 / DT):
			p.step(DT)
			e.step(DT)
		runs.append(_fingerprint(e))
	eq(runs[0], runs[1], "same seed, same sky after 20 s")
	check(runs[0] != runs[2], "a different seed gives a different sky")
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await wait_frames(1)


func test_lod_by_distance_and_far_birds_still_move_smoothly() -> void:
	var p := MockPlayer.new()
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 9)
	e.focus = p
	for i in int(10.0 / DT):
		p.step(DT)
		e.step(DT)
	# Life stays near the player now: send three calm flyers far off (as if
	# left behind), in open air well above the ground, and let LOD catch up.
	var pp := p.get_body_position()
	var sent := 0
	for n in e.get_npcs():
		if sent >= 3 or n.is_engaged() or n.perched or n.hidden or n.is_flaring():
			continue
		var a := TAU * sent / 3.0
		var q := Vector3(pp.x + cos(a) * 260.0, 0.0, pp.z + sin(a) * 260.0)
		q = Habitat.for_world(world).clamp_inside(q, 60.0)
		q.y = world.ground_height(q.x, q.z) + 60.0
		n.global_position = q
		sent += 1
	for i in 36:
		p.step(DT)
		e.step(DT)
	var wrong := 0
	pp = p.get_body_position()
	var far: NpcBird = null
	for n in e.get_npcs():
		var d := n.global_position.distance_to(pp)
		var want := 0 if d < e.lod_near else (1 if d < e.lod_far else 2)
		# LOD is refreshed every 0.25 s: allow birds right at a boundary.
		if n.lod != want and absf(d - e.lod_near) > 5.0 and absf(d - e.lod_far) > 5.0:
			wrong += 1
		if n.lod == 2 and not n.is_engaged() and not n.perched and not n.hidden and not n.near_geometry and far == null:
			far = n
	eq(wrong, 0, "LOD level follows distance to the player")
	check(far != null, "some birds are far (LOD 2)")
	if far != null:
		var moved := 0
		var prev := far.global_position
		for i in 12:
			e.step(DT)
			if far.global_position.distance_to(prev) > 1e-4:
				moved += 1
			prev = far.global_position
		gt(moved, 10, "a far bird moves every tick (coasting between full updates), no stutter")
	# A far, calm bird skimming a field below 3 m keeps its speed too (it
	# coasts held above the ground instead of waiting for its full tick).
	var low: NpcBird = far
	if low != null:
		# Open meadow, nothing within 12 m, flying level along a clear line.
		var h := Habitat.for_world(world)
		var gp := low.global_position
		var dir := Vector3.RIGHT
		for k in 16:
			var a := TAU * k / 16.0
			var q := Vector3(pp.x + cos(a) * 260.0, 0.0, pp.z + sin(a) * 260.0)
			q = h.clamp_inside(q, 80.0)
			q.y = world.ground_height(q.x, q.z) + 2.0
			var fwd := Vector3(-sin(a), 0.0, cos(a))
			if not h.blocked(q, 12.0) and h.ray(q, q + fwd * 30.0).is_empty():
				gp = q
				dir = fwd
				break
		low.global_position = gp
		low.flight.set_velocity(dir * low.flight.cruise)
		low.velocity = dir * low.flight.cruise
		low.want_dir = dir
		low._agl = 2.0
		low.near_geometry = false
		var steps := 0
		var dist := 0.0
		var p0 := low.global_position
		var prev2 := p0
		for i in 12:
			e.step(DT)
			if low.global_position.distance_to(prev2) > 1e-4:
				steps += 1
			dist += Vector2(low.global_position.x - prev2.x, low.global_position.z - prev2.z).length()
			prev2 = low.global_position
		gt(steps, 10, "a far bird low over the ground also moves every tick")
		gt(dist / (12 * DT), low.flight.cruise * 0.7, "and at (about) its speed, not a fraction of it")
		gt(low.global_position.y - world.ground_height(low.global_position.x, low.global_position.z), 0.0, "held above the ground while coasting")
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await wait_frames(1)


## Seeded runs do not depend on what ran before them in the process. Plan
## keys ("crow:hunter"...) are StringNames made at run time, and sorting
## StringNames orders them by pointer - i.e. by allocation history - so the
## spawn order, the RNG draws and the whole sky once changed after other
## plans had been made. They are spawned in text order now, and a new
## population starts from the world's own state (the shared habitat
## forgets thermal directions and lift learned by an earlier one).
## Scenario X (fresh ecosystem, seed 3, crow-sized player, 30 s) runs first,
## again after populations for three other player sizes, and in a freshly
## built world: the three skies must be identical.
func test_same_seed_same_sky_whatever_ran_before() -> void:
	# The order deficits are filled in is the order of the keys' text, not
	# of their StringNames (whose sort follows allocation): keys made here in
	# a scrambled order come back sorted by name.
	var names := ["kite:hunter", "owl:hunter", "crow:hunter", "zz:peer", "eagle:apex", "moth", "gull:hunter", "a:dust", "starling:murm", "hawk:hunter", "b:prey", "yy:giant"]
	var made: Array = []
	for n in names:
		made.append(StringName(n + ":order_test"))
	var want := made.map(func(x: StringName) -> String: return String(x))
	want.sort()
	eq(Ecosystem.spawn_order(made).map(func(x: StringName) -> String: return String(x)), want, "plan keys are spawned in text order")
	var fps := []
	var fs := 30.0 if full() else 15.0
	fps.append(await _scenario_fingerprint(world, 0.5, 3, fs))
	for pm: float in [0.03, 1.3, 3.0]:
		await _scenario_fingerprint(world, pm, 17, fs * 0.67)
	fps.append(await _scenario_fingerprint(world, 0.5, 3, fs))
	var w2 := AiTestWorld.new()
	w2.world_seed = 1
	w2.with_visuals = false
	w2.with_environment = false
	add_child(w2)
	await wait_physics(3)
	world.process_mode = Node.PROCESS_MODE_DISABLED
	fps.append(await _scenario_fingerprint(w2, 0.5, 3, fs, world))
	w2.queue_free()
	await wait_frames(2)
	world.process_mode = Node.PROCESS_MODE_INHERIT
	metric("fingerprints", fps)
	eq(fps[1], fps[0], "same seed, same sky after other plans were made in the process")
	eq(fps[2], fps[0], "same seed, same sky in a freshly built world")


## Runs a fresh ecosystem round a lapping player in world w for `seconds`;
## returns the sky's fingerprint. (A second world is taken out of the
## physics space's way by moving the first one far off.)
func _scenario_fingerprint(w: World, pm: float, seed_v: int, seconds: float, hide: World = null) -> String:
	var off := Vector3.ZERO
	if hide != null:
		hide.position = Vector3(0, -5000, 0)
		await wait_physics(2)
	var p := MockPlayer.new()
	p.mass = pm
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 90.0
	p.path_height = 30.0
	p.speed = 11.0
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	e.max_npcs = 60
	add_child(e)
	e.focus = p
	e.world = w
	e.habitat = Habitat.for_world(w)
	e.habitat.refresh()
	for i in int(seconds / DT):
		p.step(DT)
		e.step(DT)
	var fp := _fingerprint(e)
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	if hide != null:
		hide.position = off
		await wait_physics(2)
	return fp


## A player circling one area keeps the same birds round it: no recycling of
## birds "left behind" by laps (it used to replace the whole population
## every 15-30 s), no bird removed in the middle of a chase, a flight or
## hiding. Only catches, and birds that wander beyond despawn_radius, go.
func test_population_persists_around_a_lapping_player() -> void:
	var rows := {}
	for pm: float in ([0.03, 0.85] if full() else [0.03]):
		var p := MockPlayer.new()
		p.mass = pm
		p.path_center = Vector3(-20, 0, 10)
		p.path_radius = 90.0
		p.path_height = 24.0
		p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
		add_child(p)
		p.step(0.0)
		var e := make_eco(60, 71)
		e.focus = p
		var chk := make_checker()
		var t := [0.0]
		var born := {}
		var m := {"spawns": 0, "recycled": 0, "young": 0, "busy": 0, "reasons": {}}
		e.npc_spawned.connect(func(n: NpcBird) -> void:
			born[n.get_instance_id()] = t[0]
			if t[0] >= 20.0:
				m["spawns"] += 1)
		e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
			if t[0] < 20.0 or reason == &"caught":
				return
			m["recycled"] += 1
			m["reasons"][String(reason)] = m["reasons"].get(String(reason), 0) + 1
			if OS.get_environment("AI_DEBUG") != "":
				print("[ai] recycled %s %s age %.1f d %.0f key %s home->p %.0f flock %s" % [n.species, n.state_name(), t[0] - float(born.get(n.get_instance_id(), 0.0)), n.global_position.distance_to(p.get_body_position()), e._npc_key.get(n.get_instance_id(), &""), Vector2(n.home.x - p.global_position.x, n.home.z - p.global_position.z).length(), n.flock != null])
			if t[0] - float(born.get(n.get_instance_id(), 0.0)) < 60.0:
				m["young"] += 1
			if n.is_engaged() or n.hidden or n.state == NpcBird.State.HIDE:
				m["busy"] += 1)
		for i in int(110.0 / DT):
			t[0] = i * DT
			p.step(DT)
			e.step(DT)
			chk.step(DT)
		var sp := String(SizeRules.species_for_mass(pm))
		var turnover: float = m["spawns"] / 1.5 / float(e.max_npcs)
		rows[sp] = {"spawns_per_min": snappedf(m["spawns"] / 1.5, 0.1), "turnover_per_min": snappedf(turnover, 0.01),
			"recycled": m["recycled"], "recycled_young": m["young"], "recycled_busy": m["busy"], "reasons": m["reasons"]}
		lt(turnover, 0.5, "%s lapping: population turnover per minute (catches included)" % sp)
		lt(m["recycled"], 4, "%s lapping: birds recycled in 90 s (catches aside)" % sp)
		eq(m["young"], 0, "%s lapping: no bird recycled within a minute of its spawn" % sp)
		eq(m["busy"], 0, "%s lapping: no bird recycled mid-chase, mid-flight or hiding" % sp)
		e.queue_free()
		eco = null
		checker = null
		remove_child(p)
		p.queue_free()
		await wait_frames(2)
	metric("lapping", rows)
	print("[ai] lapping: %s" % rows)


## A6 with the head turned: spawns stay out of where the player LOOKS
## (get_view_direction(), the camera in VR), not where it flies - looking 90
## deg left on laps and while crossing, and straight back while crossing.
## Each case also counts spawns inside the heading cone, which must happen
## (else the case could not tell gaze from heading): an Ecosystem that used
## the body's forward passed every other test while spawning up to 101 birds
## inside the real view cone (the round-3 verifier's r3e_gaze_spawn probe,
## adopted here).
func test_spawns_stay_out_of_the_gaze_not_just_the_heading() -> void:
	var rows := {}
	for c in [["lap_look_left", 0.3, false, PI * 0.5, 21], ["travel_look_left", 0.03, true, PI * 0.5, 22],
			["travel_look_back", 0.1, true, PI, 23]]:
		var p := MockPlayer.new()
		p.mass = c[1]
		p.path_center = Vector3(-20, 0, 10)
		p.path_radius = 90.0
		p.path_height = 26.0
		p.speed = minf(SizeRules.cruise_speed(c[1]), 14.0)
		if c[2]:
			p.travel = true
			p.speed = 12.0
		p.gaze_turn = c[3]
		add_child(p)
		p.step(0.0)
		var e := make_eco(60, c[4])
		e.focus = p
		var cos_v := cos(deg_to_rad(VIEW_HALF_DEG))
		var m := {"spawns": 0, "in_gaze": 0, "near": 0, "in_heading": 0}
		e.npc_spawned.connect(func(n: NpcBird) -> void:
			m["spawns"] += 1
			var rel := n.global_position - p.get_body_position()
			var d := rel.length()
			if d < clampf(150.0 * n.get_wingspan(), 40.0, e.spawn_min):
				m["near"] += 1
			elif p.get_view_direction().dot(rel / d) > cos_v:
				m["in_gaze"] += 1
			if p.get_forward().dot(rel / d) > cos_v:
				m["in_heading"] += 1)
		for i in int((45.0 if full() else 30.0) / DT):
			p.step(DT)
			e.step(DT)
		rows[c[0]] = m.duplicate()
		gt(m["spawns"], 20, "%s: (setup) the population spawned" % c[0])
		gt(m["in_heading"], 0, "%s: (control) spawns inside the heading cone happen here" % c[0])
		eq(m["in_gaze"], 0, "%s: no spawn inside the 75-deg cone round the gaze" % c[0])
		eq(m["near"], 0, "%s: no spawn within the near distance" % c[0])
		e.queue_free()
		eco = null
		remove_child(p)
		p.queue_free()
		await wait_frames(2)
	metric("gaze_spawn", rows)


## The population's one promise to the player (Ecosystem._keep_prey_near):
## something worth catching is about. It matters when the player is put
## somewhere else - GameLoop respawns it at the spawn point after it was
## caught, often hundreds of metres from where its prey were. There, within
## a few seconds, two worthwhile prey are within 120 m and one flies within
## 75 m soon after (far idle prey - lone birds, or a whole loose flock - are
## reborn near it, out of view), long before the old population could fly
## over. (The round-3 verifier found no test that
## failed with the promise switched off; this one does - see AI.md.)
func test_prey_is_near_again_soon_after_a_respawn() -> void:
	var rows := {}
	for pm: float in ([0.03, 0.3] if full() else [0.03]):
		var p := MockPlayer.new()
		p.mass = pm
		p.path_center = Vector3(-150, 0, -120)
		p.path_radius = 50.0
		p.path_height = 24.0
		p.speed = minf(SizeRules.cruise_speed(pm), 12.0)
		add_child(p)
		p.step(0.0)
		var e := make_eco(60, 31)
		e.focus = p
		var spawns := _watch_spawns(e, p)
		for i in int(50.0 / DT):
			p.step(DT)
			e.step(DT)
		# Caught and respawned 300 m away.
		p.path_center = Vector3(150, 0, 90)
		var m := {"t_close": -1.0, "t_two": -1.0}
		for i in int(30.0 / DT):
			var t := i * DT
			p.step(DT)
			e.step(DT)
			var pp := p.get_body_position()
			var close := 0
			var near := 0
			for n in e.get_npcs():
				if n.hidden or not (SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)):
					continue
				var d := n.global_position.distance_to(pp)
				close += 1 if d < 75.0 else 0
				near += 1 if d < 120.0 else 0
			if m["t_close"] < 0.0 and close >= 1:
				m["t_close"] = t
			if m["t_two"] < 0.0 and near >= 2:
				m["t_two"] = t
			if m["t_close"] >= 0.0 and m["t_two"] >= 0.0:
				break
		var sp := String(SizeRules.species_for_mass(pm))
		rows[sp] = {"s_to_prey_within_75m": snappedf(m["t_close"], 0.01), "s_to_two_within_120m": snappedf(m["t_two"], 0.01),
			"spawns_in_view": spawns["spawn_view"], "spawns_near": spawns["spawn_near"]}
		# Two within 120 m (the promise) at once; one within 75 m once they
		# have flown in (new birds appear beyond their near distance - 40 m
		# for a sparrow's prey, 60 m for a pigeon's starlings - and out of
		# view, then close in).
		between(m["t_two"], 0.0, 8.0, "%s: two worthwhile prey within 120 m this soon after the respawn (s)" % sp)
		between(m["t_close"], 0.0, 25.0, "%s: one within 75 m (s)" % sp)
		eq(spawns["spawn_view"] + spawns["spawn_near"], 0, "%s: none of them popped in in view or near" % sp)
		e.queue_free()
		eco = null
		remove_child(p)
		p.queue_free()
		await wait_frames(2)
	metric("respawn_prey", rows)
	print("[ai] respawn prey: %s" % rows)


## A threat the player has outgrown is recycled out of view. While it is
## still in view it cannot go, but it no longer fills a threat's place (two
## outgrown apex eagles circling in front of a fast-growing player once held
## both apex places for 5 s, with nothing within 200 m that would hunt it):
## it counts as one of its species, and the threat it was is replaced.
func test_an_outgrown_threat_in_view_gives_up_its_place() -> void:
	var p := MockPlayer.new()
	p.mass = 0.3
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 60.0
	p.path_height = 30.0
	p.speed = 9.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 7)
	e.focus = p
	# (Past the recycling grace period, so there is an idle bird to make
	# room with.)
	for i in int(15.0 / DT):
		p.step(DT)
		e.step(DT)
	var th: NpcBird = null
	for n in e.get_npcs():
		if Ecosystem._is_threat_key(e._npc_key.get(n.get_instance_id(), &"")) and n.flock == null:
			th = n
			break
	check(th != null, "(setup) a threat is out")
	if th == null:
		return
	var key0: StringName = e._npc_key[th.get_instance_id()]
	var threats0 := _qualifying_threats(e, p)
	# Outgrown: it can no longer eat the player. Held in front of it, in view.
	th.mass = p.mass
	for i in int(1.5 / DT):
		p.step(DT)
		th.global_position = p.get_body_position() + p.get_view_direction() * 25.0
		th.flight.set_velocity(p.get_view_direction() * th.flight.cruise)
		e.step(DT)
	check(is_instance_valid(th) and e.get_npcs().has(th), "the outgrown threat is not removed in view")
	var key1: StringName = e._npc_key.get(th.get_instance_id(), &"")
	check(not Ecosystem._is_threat_key(key1), "it no longer holds a threat's place (was %s, now %s)" % [key0, key1])
	var threats1 := _qualifying_threats(e, p)
	gt(threats1, threats0 - 1, "its place is filled again at once: threats that would hunt the player (before %d, after %d)" % [threats0, threats1])
	metric("outgrown_in_view", {"key_before": String(key0), "key_after": String(key1), "threats_before": threats0, "threats_after": threats1})
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await wait_frames(2)


func _qualifying_threats(e: Ecosystem, p: Bird) -> int:
	var k := 0
	for n in e.get_npcs():
		if Ecosystem._is_threat_key(e._npc_key.get(n.get_instance_id(), &"")) \
				and SizeRules.can_eat(n.mass, p.mass) and Ecosystem.would_hunt(n.species, n.mass, p.mass):
			k += 1
	return k


## The "npc_chasers" count on the player is released however a chasing NPC
## leaves the tree - also when the whole Ecosystem is freed mid-chase (a
## scene change): with one chaser allowed, a leaked count would end all
## hunting of the player for the rest of the session.
## Integration round 1: when the Ecosystem removes a bird (despawn, caught),
## no other bird keeps it as its threat, target or strike, and the flock
## mates that fled it raise no error on the following thinks (the verifier
## logged 79 SCRIPT ERRORs in 1.25 s through this path).
func test_a_removed_bird_leaves_no_references_behind() -> void:
	var WarningLog := load("res://tests/unit/ai/warning_log.gd")
	var p := MockPlayer.new()
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	p.mass = 0.09
	add_child(p)
	p.step(0.0)
	var e := make_eco(40, 7)
	e.focus = p
	for i in int(12.0 / DT):
		p.step(DT)
		e.step(DT)
	var flocks := []
	for n in e.get_npcs():
		if n.flock != null and n.flock.size() >= 3 and not flocks.has(n.flock):
			flocks.append(n.flock)
	var hunter: NpcBird = null
	if not flocks.is_empty():
		for n in e.get_npcs():
			if n.flock == null and n.can_eat((flocks[0] as FlockGroup).members[0]):
				hunter = n
				break
	if check(hunter != null, "(setup) a flock (%d) and a bird that can eat it" % flocks.size()):
		var marked := 0
		for fl: FlockGroup in flocks:
			for m in fl.members:
				if hunter.can_eat(m):
					m.threat = hunter
					marked += 1
			var m0: NpcBird = fl.members[0]
			if hunter.can_eat(m0):
				m0.set_state(NpcBird.State.FLEE)
		# Another hunter chasing the same bird, to cover target and strike.
		for n in e.get_npcs():
			if n != hunter and n.can_eat(hunter):
				n.target = hunter
				n.strike = hunter
				break
		gt(marked, 0, "(setup) birds hold the hunter as their threat")
		var log: Logger = WarningLog.install()
		e._remove(hunter, &"far")
		var left := 0
		for n in e.get_npcs():
			if n.threat == hunter or n.target == hunter or n.strike == hunter:
				left += 1
		eq(left, 0, "no bird still points at the removed one")
		for i in int(1.5 / DT):
			p.step(DT)
			e.step(DT)
		var errors: int = log.errors
		var samples: Array = log.samples.duplicate()
		log.uninstall()
		eq(errors, 0, "no AI error on the thinks after the removal: %s" % [samples])
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await wait_frames(2)


func test_freeing_the_ecosystem_mid_chase_releases_the_player() -> void:
	var p := MockPlayer.new()
	p.mass = 0.3
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 60.0
	p.path_height = 30.0
	p.speed = 9.0
	p.protect_s = 0.0
	add_child(p)
	p.step(0.0)
	Game.state = Game.State.PLAYING
	var e := make_eco(60, 5)
	e.focus = p
	var chasing := false
	for i in int(120.0 / DT):
		p.step(DT)
		e.step(DT)
		for n in e.get_npcs():
			if n.target == p:
				chasing = true
		if chasing:
			break
	check(chasing, "(setup) an NPC started chasing the player")
	eq(int(p.get_meta(&"npc_chasers", 0)), 1, "one chaser counted while it chases")
	e.queue_free()
	eco = null
	await wait_frames(3)
	eq(int(p.get_meta(&"npc_chasers", 0)), 0, "npc_chasers back to 0 once the ecosystem is gone")
	Game.state = Game.State.BOOT
	remove_child(p)
	p.queue_free()
	await wait_frames(1)
