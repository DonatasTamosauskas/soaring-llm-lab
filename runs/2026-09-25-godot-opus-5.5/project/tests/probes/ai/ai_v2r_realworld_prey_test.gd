extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): A6 "edible birds always present near the
## player" as the builder's ecosystem_test counts it (every NPC, hidden in a
## refuge or not) versus counting only prey the player could actually go
## for (not hidden). Real valley (world area's SoaringWorld) and the AI test
## world, mock player flying laps at four sizes, 150 s each (after 20 s).

const SIM_S := 150.0
const WARM_S := 20.0


func _scenario(real: bool, pm: float) -> Dictionary:
	var w: World
	if real:
		w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(w)
		await wait_physics(3)
	else:
		w = await make_world(false, 1)
	var p := MockPlayer.new()
	p.mass = pm
	var spawn := w.get_player_spawn().origin
	p.path_center = Vector3(spawn.x, 0, spawn.z)
	p.path_radius = 90.0
	p.path_height = w.ground_height(spawn.x, spawn.z) + 25.0
	p.speed = 11.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 3)
	e.focus = p
	var s := {"n": 0, "all150": 0, "vis150": 0, "vis60": 0, "all60": 0, "hidden_sum": 0, "hidden_prey_sum": 0,
		"hid_threat_player": 0, "hid_threat_npc": 0, "hid_no_threat": 0, "hid_over_20s": 0}
	for i in int(SIM_S / DT):
		p.step(DT)
		e.step(DT)
		if i * DT < WARM_S or i % 36 != 0:
			continue
		s["n"] += 1
		var pp := p.get_body_position()
		var c := {"all150": 0, "vis150": 0, "vis60": 0, "all60": 0}
		for n in e.get_npcs():
			if n.hidden:
				s["hidden_sum"] += 1
				if n.threat == p:
					s["hid_threat_player"] += 1
				elif n.threat != null:
					s["hid_threat_npc"] += 1
				else:
					s["hid_no_threat"] += 1
				if n.state_time > 20.0:
					s["hid_over_20s"] += 1
			if not (SizeRules.can_eat(pm, n.mass) and SizeRules.is_worthwhile(pm, n.mass)):
				continue
			if n.hidden:
				s["hidden_prey_sum"] += 1
			var gp := n.global_position
			var dh := Vector2(gp.x - pp.x, gp.z - pp.z).length()
			var d3 := gp.distance_to(pp)
			if dh < 150.0:
				c["all150"] += 1
				if not n.hidden:
					c["vis150"] += 1
			if d3 < 60.0:
				c["all60"] += 1
				if not n.hidden:
					c["vis60"] += 1
		s["all150"] += 1 if c["all150"] >= 2 else 0
		s["vis150"] += 1 if c["vis150"] >= 2 else 0
		s["all60"] += 1 if c["all60"] >= 1 else 0
		s["vis60"] += 1 if c["vis60"] >= 1 else 0
	var k := float(s["n"])
	var res := {"world": "real" if real else "test", "player": String(SizeRules.species_for_mass(pm)),
		"prey150_ge2_counting_hidden": snappedf(s["all150"] / k, 0.001), "prey150_ge2_visible_only": snappedf(s["vis150"] / k, 0.001),
		"prey60_counting_hidden": snappedf(s["all60"] / k, 0.001), "prey60_visible_only": snappedf(s["vis60"] / k, 0.001),
		"mean_hidden_birds": snappedf(s["hidden_sum"] / k, 0.1), "mean_hidden_prey": snappedf(s["hidden_prey_sum"] / k, 0.1),
		"hidden_share_threat_is_player": snappedf(s["hid_threat_player"] / maxf(s["hidden_sum"], 1), 0.01),
		"hidden_share_threat_is_npc": snappedf(s["hid_threat_npc"] / maxf(s["hidden_sum"], 1), 0.01),
		"hidden_share_no_threat": snappedf(s["hid_no_threat"] / maxf(s["hidden_sum"], 1), 0.01),
		"hidden_share_longer_than_20s": snappedf(s["hid_over_20s"] / maxf(s["hidden_sum"], 1), 0.01)}
	print("[ai] v2r prey %s" % JSON.stringify(res))
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	w.queue_free()
	world = null
	Habitat.clear_cache()
	await wait_frames(2)
	return res


func test_prey_present_counting_hidden_vs_visible() -> void:
	var rows := []
	for pm: float in (([0.5] if Paths.arg("only_crow", "") != "" else [0.03, 0.3, 0.5, 1.3]) as Array):
		rows.append(await _scenario(true, pm))
		if Paths.arg("only_crow", "") == "":
			rows.append(await _scenario(false, pm))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("v2r_realworld_prey.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	gt(rows.size(), 0, "scenarios ran")
