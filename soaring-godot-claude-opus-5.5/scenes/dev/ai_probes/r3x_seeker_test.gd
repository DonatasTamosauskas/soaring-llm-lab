extends "res://tests/unit/ai/ai_sim.gd"
## COPY of the verifier probe tests/probes/ai/r3x_seeker_test.gd (round 3), run by the ai
## builder with its output redirected to artifacts/ai/fix_r3/verifier_probes/, so
## the verifier's own files are never overwritten. Logic unchanged.
## VERIFIER PROBE (round 3, experience lens): what does a player who actually
## HUNTS meet? Every builder test flies a scripted MockPlayer that never chases
## anything, so "edible birds always present near the player" (A6), "prey flee
## it" (A7) and "a chase is fair and readable" were never exercised with a
## player in pursuit. Here r3x_seeker_player.gd flies the NPCs' own physics at
## the player's mass, searches low and chases the nearest worthwhile prey the
## game would highlight. Catches use the stand-in checker with GameLoop's
## 0.25-span reach margin (the rule the real game applies).
##
## Fixed-size cases (sparrow, starling, pigeon, hawk) in the real valley and in
## the AI arena, WARM_S + MEAS_S each, then a growing run in the valley from
## sparrow for GROW_S. Thresholds (a game director's, not the builder's):
##  * the first catch comes within 90 s of hunting (a new player must eat);
##  * >= 0.5 catches a minute while hunting;
##  * a chase is a contest: of chases that ended caught/escaped, 15-90% caught;
##  * prey flee the player: >= 70% of chased prey that the player got within
##    their awareness radius fled it;
##  * a worthwhile, not-hidden prey inside highlight range (any direction) at
##    least 50% of the time;
##  * A5 safety 0 for every NPC; spawns never in view or near.
## Report: artifacts/ai/verify/r3/seeker.json
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_seeker

const Seeker := preload("res://tests/probes/ai/r3x_seeker_player.gd")
const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WARM_S := 25.0
const MEAS_S := 150.0
const GROW_S := 600.0
const VIEW_HALF_DEG := 75.0

var _real: World = null


func _run(w: World, tag: String, pm: float, seed_v: int, meas: float, grow: bool, schedule: Array = []) -> Dictionary:
	var s := Seeker.new()
	add_child(s)
	var c := w.get_player_spawn().origin if not (w is AiTestWorld) else Vector3(-20, 0, 10)
	s.setup(w, pm, c)
	s.grow = grow
	s.travel_a = Vector3(-320, 0, c.z)
	s.travel_b = Vector3(320, 0, c.z)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	e.focus = s
	var chk: RefCounted = CatchChecker.new()
	chk.reach = 0.25
	var safety: RefCounted = Safety.new(w)
	var m := {"samples": 0, "in_range": 0, "d": [], "spawns": 0, "spawn_bad": 0, "hunts_on_player": 0,
		"prey150": 0, "despawn": {}, "tiers": {}, "phase": {}}
	var tt := [0.0]
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		if tt[0] < WARM_S:
			return
		m["spawns"] += 1
		var rel := n.global_position - s.get_body_position()
		if rel.length() < e.spawn_distance(n.get_wingspan()) or s.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(VIEW_HALF_DEG)):
			m["spawn_bad"] += 1)
	e.npc_despawned.connect(func(_n: NpcBird, reason: StringName) -> void:
		if tt[0] >= WARM_S:
			m["despawn"][String(reason)] = m["despawn"].get(String(reason), 0) + 1)
	var hunting := {}
	var npc_catch0 := 0
	var total := int((WARM_S + meas) / DT)
	var hunt_s := 0.0
	var first_catch := -1.0
	var tier_at := {}
	for i in total:
		tt[0] = i * DT
		var ph := "hunt"
		if tt[0] < WARM_S:
			ph = "warm"
			s.active = false
		else:
			s.active = true
			var rel_t: float = tt[0] - WARM_S
			for sc in schedule:
				if rel_t >= sc[0] and rel_t < sc[1]:
					ph = sc[2]
			s.mode = ph
		s.step(DT, e.get_npcs())
		e.step(DT)
		chk.step(DT)
		if tt[0] < WARM_S:
			continue
		if i == int(WARM_S / DT):
			npc_catch0 = chk.catches.size() - s.catches.size()
		if ph == "hunt":
			hunt_s += DT
		if first_catch < 0.0 and not s.catches.is_empty():
			first_catch = s.catches[0]["t"] - WARM_S
		var sp := String(SizeRules.species_for_mass(s.mass))
		if not tier_at.has(sp):
			tier_at[sp] = snappedf(tt[0] - WARM_S, 0.1)
		safety.step(DT, e.get_npcs())
		for n in e.get_npcs():
			var on := n.target == s
			if on and not hunting.get(n, false):
				m["hunts_on_player"] += 1
			hunting[n] = on
		if i % 36 == 0:
			var r: Array = s.nearest_prey(e.get_npcs())
			# Nearest eligible prey regardless of the seeker's blacklist.
			var bd := INF
			var n150 := 0
			for n in e.get_npcs():
				if s.eligible(n):
					var dd := s.global_position.distance_to(n.global_position)
					bd = minf(bd, dd)
					if dd < 150.0:
						n150 += 1
			m["samples"] += 1
			var pk: Dictionary = m["phase"].get(ph, {"n": 0, "in_range": 0})
			pk["n"] += 1
			if bd <= s.sense_r:
				m["in_range"] += 1
				pk["in_range"] += 1
			m["phase"][ph] = pk
			if n150 >= 1:
				m["prey150"] += 1
			m["d"].append(bd if is_finite(bd) else 9999.0)
			var tk: Dictionary = m["tiers"].get(sp, {"n": 0, "in_range": 0})
			tk["n"] += 1
			tk["in_range"] += 1 if bd <= s.sense_r else 0
			m["tiers"][sp] = tk
			if r.is_empty():
				pass
	# Close an open chase for the tally.
	if s.target != null:
		s._end("end")
	var res := {}
	var reasons := {}
	var decided := 0
	var caught := 0
	var aware := 0
	var fled := 0
	for p in s.pursuits:
		reasons[p["reason"]] = reasons.get(p["reason"], 0) + 1
		if p["reason"] in ["caught", "hid", "timeout", "outran"]:
			decided += 1
			if p["reason"] == "caught":
				caught += 1
		if p["in_awareness"] and p["t1"] - p["t0"] > 0.5:
			aware += 1
			if p["fled"]:
				fled += 1
	var ds: Array = m["d"]
	ds.sort()
	var med: float = ds[ds.size() / 2] if not ds.is_empty() else INF
	var p90: float = ds[int(ds.size() * 0.9)] if not ds.is_empty() else INF
	var tiers := {}
	for k in m["tiers"]:
		tiers[k] = snappedf(float(m["tiers"][k]["in_range"]) / maxf(m["tiers"][k]["n"], 1), 0.01)
	var phases := {}
	for k in m["phase"]:
		phases[k] = snappedf(float(m["phase"][k]["in_range"]) / maxf(m["phase"][k]["n"], 1), 0.01)
	var npc_catches: int = chk.catches.size() - s.catches.size() - npc_catch0
	res = {"tag": tag, "mass0": pm, "mass_end": snappedf(s.mass, 0.001), "species_end": String(SizeRules.species_for_mass(s.mass)),
		"sense_r": snappedf(s.sense_r, 0.1), "hunt_s": snappedf(hunt_s, 0.1),
		"first_catch_s": snappedf(first_catch, 0.1), "catches": s.catches.size(),
		"catches_per_min": snappedf(s.catches.size() / maxf(hunt_s / 60.0, 0.01), 0.01),
		"catch_species": s.catches.map(func(x: Dictionary) -> String: return x["species"]),
		"pursuits": s.pursuits.size(), "pursuit_reasons": reasons,
		"success_of_decided": snappedf(float(caught) / maxf(decided, 1), 0.01), "decided": decided,
		"chased_within_awareness": aware, "fled_share": snappedf(float(fled) / maxf(aware, 1), 0.01),
		"prey_in_range_share": snappedf(float(m["in_range"]) / maxf(m["samples"], 1), 0.01),
		"prey_in_range_by_tier": tiers, "prey_in_range_by_phase": phases,
		"any_prey_within_150m_share": snappedf(float(m["prey150"]) / maxf(m["samples"], 1), 0.01),
		"nearest_prey_median_m": snappedf(med, 0.1), "nearest_prey_p90_m": snappedf(p90, 0.1),
		"hunts_on_player": m["hunts_on_player"], "player_caught": s.times_caught, "caught_by": s.caught_by_species,
		"npc_catches": npc_catches, "spawns": m["spawns"], "spawn_bad": m["spawn_bad"], "despawn": m["despawn"],
		"tier_reached_at_s": tier_at, "safety": safety.counts.duplicate(), "safety_examples": safety.examples.slice(0, 5)}
	print("[ai-r3x] seeker %s: %s" % [tag, JSON.stringify(res)])
	e.queue_free()
	remove_child(s)
	s.queue_free()
	await wait_frames(2)
	return res


func _write(name: String, data: Dictionary) -> void:
	var dir := Paths.artifacts("ai").path_join("fix_r3/verifier_probes")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))
	f.close()


func _judge(r: Dictionary) -> void:
	var tag: String = r["tag"]
	check(r["first_catch_s"] >= 0.0 and r["first_catch_s"] <= 90.0, "%s: first catch within 90 s of hunting (got %s s)" % [tag, r["first_catch_s"]])
	gt(r["catches_per_min"], 0.5, "%s: catches a minute while hunting" % tag)
	if r["decided"] >= 4:
		between(r["success_of_decided"], 0.15, 0.9, "%s: a chase is a contest (caught / decided chases, n=%d)" % [tag, r["decided"]])
	if r["chased_within_awareness"] >= 4:
		gt(r["fled_share"], 0.7, "%s: chased prey that could see the player fled it (n=%d)" % [tag, r["chased_within_awareness"]])
	gt(r["prey_in_range_share"], 0.5, "%s: a worthwhile unhidden prey within highlight range %.0f m" % [tag, r["sense_r"]])
	for k in r["safety"]:
		eq(r["safety"][k], 0, "%s: A5 safety %s" % [tag, k])
	eq(r["spawn_bad"], 0, "%s: spawns in view or near" % tag)


func test_r3_seeker_fixed_sizes() -> void:
	var cases := [["sparrow", 0.03], ["starling", 0.1], ["pigeon", 0.3], ["hawk", 1.3]]
	var only := String(Paths.arg("r3_cases", ""))
	if not only.is_empty():
		cases = cases.filter(func(c: Array) -> bool: return only.split(",").has(c[0]))
	var worlds := String(Paths.arg("r3_worlds", "real,test"))
	var base := int(Paths.arg("r3_seed", "731"))
	var res := {}
	if worlds.contains("real"):
		_real = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(_real)
		await wait_physics(3)
		if not _real.is_generated:
			await _real.generated
		for i in cases.size():
			var r := await _run(_real, "valley_" + cases[i][0], cases[i][1], base + i, MEAS_S, false)
			res[r["tag"]] = r
			_judge(r)
		_real.queue_free()
		_real = null
		Habitat.clear_cache()
		await wait_frames(2)
	if worlds.contains("test"):
		await make_world(false, 1)
		for i in cases.size():
			var r := await _run(world, "arena_" + cases[i][0], cases[i][1], base + 10 + i, MEAS_S, false)
			res[r["tag"]] = r
			_judge(r)
		await clear_sim()
	_write("seeker%s.json" % String(Paths.arg("r3_tag", "")), res)


## A player's first ten minutes in the shipped valley: it starts as a sparrow
## sitting on the spawn, hunts, grows by GameLoop's meal rule, crosses the
## valley, circles a thermal, hunts again.
func test_r3_seeker_growing_session() -> void:
	if Paths.arg("r3_grow", "1") == "0":
		check(true, "skipped")
		return
	_real = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(_real)
	await wait_physics(3)
	if not _real.is_generated:
		await _real.generated
	var sched := [[0.0, 20.0, "perch"], [20.0, 260.0, "hunt"], [260.0, 340.0, "travel"], [340.0, 400.0, "thermal"], [400.0, GROW_S, "hunt"]]
	var r := await _run(_real, "valley_growing_session", 0.03, int(Paths.arg("r3_seed", "731")) + 50, GROW_S, true, sched)
	_write("seeker_growing%s.json" % String(Paths.arg("r3_tag", "")), r)
	for k in r["safety"]:
		eq(r["safety"][k], 0, "growing: A5 safety %s" % k)
	eq(r["spawn_bad"], 0, "growing: spawns in view or near")
	check(r["first_catch_s"] >= 0.0 and r["first_catch_s"] <= 110.0, "growing: first catch within 90 s of hunting (20 s perched first; got %s)" % r["first_catch_s"])
	gt(r["catches_per_min"], 0.5, "growing: catches a minute")
	check(r["tier_reached_at_s"].has("starling"), "growing: a hunting sparrow reaches starling within 10 minutes (%s)" % str(r["tier_reached_at_s"]))
	for k in r["prey_in_range_by_tier"]:
		gt(r["prey_in_range_by_tier"][k], 0.4, "growing: worthwhile prey within highlight range as a %s" % k)
	_real.queue_free()
	_real = null
	Habitat.clear_cache()
	await wait_frames(2)
