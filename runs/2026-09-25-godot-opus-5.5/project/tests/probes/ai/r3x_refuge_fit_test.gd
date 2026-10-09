extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 3, requirements lens): the area brief says fleeing
## birds "dive into World.get_refuges() spots that are too small for the
## pursuer". Habitat.pick_refuge filters refuges by the *prey's* span only
## (npc_brain.gd _update_refuge_choice -> habitat.gd pick_refuge); nothing
## prefers cover the pursuer cannot follow into. This probe counts, for every
## refuge dive ("refuge" behaviour event) in the real valley around lapping
## mock players of several sizes and in the AI arena with no player:
##  * dives where the bird's threat could follow it in (threat span <=
##    refuge max_span);
##  * birds caught while hidden (the refuge did not save them).
## Target (the brief): >= 80% of dives from a known threat into cover the
## threat cannot enter.
## Report: artifacts/ai/verify/r3/refuge_fit.json
##   tools/gd.sh ai_verify --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3x_refuge_fit

const MEAS_S := 150.0


func _count(w: World, tag: String, pm: float, seed_v: int) -> Dictionary:
	var p: Bird = null
	if pm > 0.0:
		var mp := MockPlayer.new()
		mp.mass = pm
		var c := w.get_player_spawn().origin if not (w is AiTestWorld) else Vector3(-20, 0, 10)
		mp.path_center = Vector3(c.x, 0, c.z)
		mp.path_radius = 90.0
		mp.path_height = w.ground_height(c.x, c.z) + 25.0
		mp.speed = minf(SizeRules.cruise_speed(pm), 14.0)
		add_child(mp)
		mp.step(0.0)
		p = mp
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = seed_v
	add_child(e)
	if p != null:
		e.focus = p
	var chk: RefCounted = CatchChecker.new()
	var r := {"dives": 0, "known_threat": 0, "threat_fits": 0, "by_pair": {}, "caught_hidden": 0, "caught_total": 0}
	e.npc_spawned.connect(func(n: NpcBird) -> void:
		n.behaviour.connect(func(b: NpcBird, what: StringName) -> void:
			if what != &"refuge":
				return
			r["dives"] += 1
			var th: Bird = b.threat
			if th == null or not is_instance_valid(th):
				return
			r["known_threat"] += 1
			var fits := th.get_wingspan() <= float(b.refuge.get("max_span", 0.0))
			if fits:
				r["threat_fits"] += 1
				var k := "%s>%s" % [th.species, b.species]
				r["by_pair"][k] = r["by_pair"].get(k, 0) + 1)
		n.caught.connect(func(b: NpcBird, _by: Bird) -> void:
			r["caught_total"] += 1
			if b.hidden or b.state == NpcBird.State.HIDE:
				r["caught_hidden"] += 1))
	for i in int(MEAS_S / DT):
		if p != null:
			p.step(DT)
		e.step(DT)
		chk.step(DT)
	r["tag"] = tag
	r["share_threat_could_follow"] = snappedf(float(r["threat_fits"]) / maxf(r["known_threat"], 1), 0.01)
	print("[ai-r3x] refuge %s: %s" % [tag, JSON.stringify(r)])
	e.queue_free()
	if p != null:
		remove_child(p)
		p.queue_free()
	await wait_frames(2)
	return r


func test_r3_refuge_fit() -> void:
	var res := {}
	var rw := (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
	add_child(rw)
	await wait_physics(3)
	if not rw.is_generated:
		await rw.generated
	for c in [["pigeon", 0.3, 811], ["gull", 0.85, 812], ["eagle", 3.0, 813]]:
		res["valley_" + c[0]] = await _count(rw, "valley_" + c[0], c[1], c[2])
	rw.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)
	await make_world(false, 1)
	res["arena_no_player"] = await _count(world, "arena_no_player", -1.0, 814)
	await clear_sim()
	var tot := 0
	var fit := 0
	for k in res:
		tot += res[k]["known_threat"]
		fit += res[k]["threat_fits"]
	res["pooled_share_threat_could_follow"] = float(fit) / maxf(tot, 1)
	var dir := Paths.artifacts("ai").path_join("verify/r3")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("refuge_fit.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	gt(tot, 20, "refuge dives from a known threat measured")
	lt(res["pooled_share_threat_could_follow"], 0.2, "dives into cover the pursuer could follow into (brief: too small for the pursuer)")
