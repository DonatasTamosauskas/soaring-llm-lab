extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2, experience lens): what a player actually meets
## in the REAL valley (SoaringWorld, scenes/world/world.tscn - the world the
## game ships with, full of refuges and perches), not the AI test arena.
## The builder's A6 metrics count every NPC near the player, including birds
## tucked away inside refuges the player cannot see or reach. Here only
## birds the player could see and chase count.
##
## Scenarios: a mock player at fixed sizes (sparrow, starling, pigeon, gull,
## eagle) flying laps round the player spawn at its own cruise speed, and a
## sparrow crossing the valley in straight legs at 12 m/s. Each: 20 s warm-up,
## 120 s measured, sampled every second:
##  * visible (not hidden) worthwhile prey within 80 m (3D), >= 2 within
##    150 m (horizontal), visible birds that would hunt the player within 200 m;
##  * share of the population hidden / fleeing / perched;
##  * birds in the player's forward view (45 deg half-angle, < 120 m);
##  * hunts started on the player per minute, NPC-vs-NPC catches, perch
##    landings per attempt, spawns inside the view cone / near distance,
##    A5 safety.
## Report: artifacts/ai/verify/r2/realworld_life.json.
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r2x_realworld_life

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WARM_S := 20.0
const MEAS_S := 120.0

var _w: World


func _hunts(n: NpcBird, pm: float) -> bool:
	return SizeRules.can_eat(n.mass, pm) and Ecosystem.would_hunt(n.species, n.mass, pm)


func _scenario(tag: String, pm: float, travel: bool, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	var spawn := _w.get_player_spawn().origin
	p.path_center = Vector3(spawn.x, 0, spawn.z)
	p.path_radius = 90.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(spawn.x + cos(a) * 90.0, spawn.z + sin(a) * 90.0))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	if travel:
		p.travel = true
		p.speed = 12.0
		var y := 0.0
		for k in 61:
			y = maxf(y, _w.ground_height(-300.0 + k * 10.0, spawn.z))
		p.line_a = Vector3(-300, y + 22.0, spawn.z)
		p.line_b = Vector3(300, y + 22.0, spawn.z)
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_v)
	e.focus = p
	var chk := make_checker()
	var safety := Safety.new(_w)
	var sv := {"spawns": 0, "in_view": 0, "near": 0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		sv["spawns"] += 1
		var rel := n.global_position - p.get_body_position()
		if rel.length() < e.spawn_distance(n.get_wingspan()):
			sv["near"] += 1
		elif p.get_view_direction().dot(rel.normalized()) > cos(deg_to_rad(e.view_half_angle_deg)):
			sv["in_view"] += 1)
	var m := {"n": 0, "vis_prey80": 0, "vis_prey150_2": 0, "any_prey80": 0, "vis_threat200": 0,
		"hidden": 0.0, "flee": 0.0, "perched": 0.0, "in_front": 0.0, "in_front_min": 999}
	var h0 := 0
	var beh0 := {}
	var c0 := 0
	var total := int((WARM_S + MEAS_S) / DT)
	for i in total:
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		if i * DT >= WARM_S:
			safety.step(DT, e.get_npcs())
		if i == int(WARM_S / DT):
			h0 = e.stats()["hunts_on_player"]
			beh0 = e.stats()["behaviour"].duplicate()
			c0 = chk.catches.size()
		if i * DT > WARM_S and i % 72 == 0:
			var pp := p.get_body_position()
			var vd := p.get_view_direction()
			var r := {"vp80": 0, "vp150": 0, "ap80": 0, "vt": 0, "hid": 0, "fl": 0, "pc": 0, "front": 0}
			for n in e.get_npcs():
				var gp := n.global_position
				var d3 := gp.distance_to(pp)
				var dh := Vector2(gp.x - pp.x, gp.z - pp.z).length()
				var hid := n.hidden or n.state == NpcBird.State.HIDE
				if hid:
					r["hid"] += 1
				if n.state == NpcBird.State.FLEE:
					r["fl"] += 1
				if n.perched:
					r["pc"] += 1
				if not hid and d3 < 120.0 and d3 > 0.1 and vd.dot((gp - pp) / d3) > cos(deg_to_rad(45.0)):
					r["front"] += 1
				if SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass):
					if d3 < 80.0:
						r["ap80"] += 1
					if not hid:
						if d3 < 80.0:
							r["vp80"] += 1
						if dh < 150.0:
							r["vp150"] += 1
				elif not hid and _hunts(n, pm) and dh < 200.0:
					r["vt"] += 1
			var cnt := maxf(e.count(), 1)
			m["n"] += 1
			m["vis_prey80"] += 1 if r["vp80"] >= 1 else 0
			m["any_prey80"] += 1 if r["ap80"] >= 1 else 0
			m["vis_prey150_2"] += 1 if r["vp150"] >= 2 else 0
			m["vis_threat200"] += 1 if r["vt"] >= 1 else 0
			m["hidden"] += r["hid"] / cnt
			m["flee"] += r["fl"] / cnt
			m["perched"] += r["pc"] / cnt
			m["in_front"] += r["front"]
			m["in_front_min"] = mini(m["in_front_min"], r["front"])
	var st := e.stats()
	var beh: Dictionary = st["behaviour"]
	var n: float = maxf(m["n"], 1)
	var npc_c := 0
	for j in range(c0, chk.catches.size()):
		var c: Dictionary = chk.catches[j]
		if c["prey"] != p:
			npc_c += 1
	var perch_go: int = beh.get("perch_go", 0) - beh0.get("perch_go", 0)
	var perch_ok: int = beh.get("perch", 0) - beh0.get("perch", 0)
	var out := {
		"tag": tag, "player_mass": pm, "travel": travel, "samples": m["n"],
		"visible_prey_within_80m": m["vis_prey80"] / n, "any_prey_within_80m_incl_hidden": m["any_prey80"] / n,
		"visible_prey_2_within_150m": m["vis_prey150_2"] / n, "visible_threat_within_200m": m["vis_threat200"] / n,
		"hidden_share": m["hidden"] / n, "flee_share": m["flee"] / n, "perched_share": m["perched"] / n,
		"birds_in_front_mean": m["in_front"] / n, "birds_in_front_min": m["in_front_min"],
		"hunts_on_player_per_min": (st["hunts_on_player"] - h0) / (MEAS_S / 60.0),
		"npc_catches_per_min": npc_c / (MEAS_S / 60.0), "player_caught": p.times_caught,
		"perch_attempts": perch_go, "perch_landings": perch_ok,
		"refuge_dives": beh.get("refuge", 0) - beh0.get("refuge", 0),
		"spawns": sv, "safety": safety.counts, "roles_end": st["by_role"], "states_end": st["by_state"],
	}
	print("[ai-r2x] realworld %s: %s" % [tag, JSON.stringify(out)])
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	checker = null
	await wait_frames(2)
	return out


func test_r2x_life_around_the_player_in_the_real_valley() -> void:
	_w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated
	world = null
	var all := {}
	var cases := [["sparrow", 0.03, false], ["starling", 0.1, false], ["pigeon", 0.3, false],
		["gull", 0.85, false], ["eagle", 3.0, false], ["sparrow_travel", 0.03, true]]
	var k := 0
	for c in cases:
		k += 1
		var r: Dictionary = await _scenario(c[0], c[1], c[2], 40 + k)
		all[c[0]] = r
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("verify/r2"))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("verify/r2/realworld_life.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(all, "  "))
	f.close()
	for tag in all:
		var r: Dictionary = all[tag]
		gt(r["visible_prey_within_80m"], 0.9, "%s: a visible worthwhile prey within 80 m" % tag)
		gt(r["visible_prey_2_within_150m"], 0.95, "%s: >= 2 visible worthwhile prey within 150 m" % tag)
		if tag != "eagle":
			gt(r["visible_threat_within_200m"], 0.9, "%s: a visible bird that would hunt it within 200 m" % tag)
			between(r["hunts_on_player_per_min"], 0.5, 6.0, "%s: hunts started on the player per minute" % tag)
		lt(r["hidden_share"], 0.25, "%s: mean share of the population hidden in refuges" % tag)
		gt(float(r["perch_landings"]) / maxf(float(r["perch_attempts"]), 1.0), 0.4, "%s: perch attempts that end on a perch (%d/%d)" % [tag, r["perch_landings"], r["perch_attempts"]])
		eq(r["spawns"]["in_view"] + r["spawns"]["near"], 0, "%s: spawns in view / near" % tag)
		for s in r["safety"]:
			eq(r["safety"][s], 0, "%s: safety %s" % [tag, s])
	_w.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
