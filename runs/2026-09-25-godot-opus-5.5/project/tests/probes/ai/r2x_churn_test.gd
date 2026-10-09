extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2, experience lens): population churn around a
## player flying ordinary laps (not travelling across the map). The growth
## run logs ~1,200 spawns in 270 s for a 60-bird population. Birds that are
## deleted and re-created every few seconds never finish a perch, a flock or
## a chase the player could watch. Measures, per player size, spawns per
## minute, despawn reasons, lifetime of recycled birds, and how many birds
## are recycled in the middle of a hunt, a flight or while perched.
## Report: artifacts/ai/verify/r2/churn.json.
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r2x_churn

const WARM_S := 30.0
const MEAS_S := 120.0


func _case(pm: float, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	p.path_center = Vector3(-20, 0, 10)
	# 90 m laps by default; --r2x_radius=25 is a player circling in a thermal.
	p.path_radius = float(Paths.arg("r2x_radius", "90"))
	p.path_height = 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 14.0)
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_v)
	e.focus = p
	var chk := make_checker()
	var born := {}
	var m := {"spawns": 0, "despawns": {}, "life": [], "mid_hunt": 0, "mid_flee": 0, "perched": 0, "flocking": 0, "dist": [], "beyond_despawn_radius": 0}
	var t := [0.0]
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		born[n.get_instance_id()] = t[0]
		if t[0] >= WARM_S:
			m["spawns"] += 1)
	e.npc_despawned.connect(func(n: NpcBird, reason: StringName) -> void:
		if t[0] < WARM_S or reason == &"caught":
			return
		m["despawns"][String(reason)] = m["despawns"].get(String(reason), 0) + 1
		m["life"].append(t[0] - float(born.get(n.get_instance_id(), 0.0)))
		var dd := n.global_position.distance_to(p.get_body_position())
		m["dist"].append(dd)
		if dd > e.despawn_radius:
			m["beyond_despawn_radius"] += 1
		if n.state == NpcBird.State.HUNT or n.state == NpcBird.State.STOOP:
			m["mid_hunt"] += 1
		elif n.state == NpcBird.State.FLEE or n.state == NpcBird.State.HIDE:
			m["mid_flee"] += 1
		elif n.perched:
			m["perched"] += 1
		elif n.state == NpcBird.State.FLOCK:
			m["flocking"] += 1)
	for i in int((WARM_S + MEAS_S) / DT):
		t[0] = i * DT
		p.step(DT)
		e.step(DT)
		chk.step(DT)
	var life: Array = m["life"]
	life.sort()
	(m["dist"] as Array).sort()
	var recycled := life.size()
	var out := {"mass": pm, "spawns_per_min": m["spawns"] / (MEAS_S / 60.0), "despawn_reasons": m["despawns"],
		"recycled": recycled, "recycled_life_median_s": life[recycled / 2] if recycled > 0 else -1.0,
		"recycled_life_p10_s": life[recycled / 10] if recycled > 0 else -1.0,
		"recycled_under_20s": life.filter(func(x: float) -> bool: return x < 20.0).size(),
		"recycled_mid_hunt": m["mid_hunt"], "recycled_mid_flee_or_hide": m["mid_flee"],
		"recycled_perched": m["perched"], "recycled_flocking": m["flocking"],
		"recycled_beyond_despawn_radius": m["beyond_despawn_radius"],
		"recycled_distance_median_m": (m["dist"] as Array)[(m["dist"] as Array).size() / 2] if not (m["dist"] as Array).is_empty() else -1.0,
		"population_turnover_per_min": m["spawns"] / (MEAS_S / 60.0) / 60.0}
	print("[ai-r2x] churn %.2f kg: %s" % [pm, JSON.stringify(out)])
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	checker = null
	await wait_frames(2)
	return out


func test_r2x_churn_around_a_lapping_player() -> void:
	await make_world(false, 1)
	var res := {}
	var k := 0
	for pm in Array(Paths.arg("r2x_masses", "0.03,0.1,0.3,0.85,3.0").split(",")).map(func(x: String) -> float: return float(x)):
		k += 1
		res[str(pm)] = await _case(pm, 70 + k)
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("verify/r2"))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("verify/r2/churn_r%s.json" % Paths.arg("r2x_radius", "90")), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	for key in res:
		var r: Dictionary = res[key]
		# A player circling one area: the population should mostly persist
		# (a full turnover of the 60 birds at most every 2 minutes).
		lt(r["population_turnover_per_min"], 0.5, "%s kg: population turnover per minute while lapping" % key)
		lt(float(r["recycled_under_20s"]) / maxf(r["recycled"], 1), 0.25, "%s kg: recycled birds that lived under 20 s" % key)
	await clear_sim()
