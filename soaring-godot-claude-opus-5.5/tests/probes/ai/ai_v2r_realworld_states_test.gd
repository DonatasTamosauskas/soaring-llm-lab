extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): how the population spends its time in the REAL
## valley (scenes/world/world.tscn, the world area's SoaringWorld) versus the
## AI test world, around the same mock player (laps of 90 m at 11 m/s, 25 m
## up), fixed at sparrow size (the start of every run) and at crow size.
## Samples every second: share of bird-time per state, visible (not hidden)
## birds within 100 m, NPC-vs-NPC catches (stand-in rule), safety.
## Informational: asserts only that the runs completed.

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const SIM_S := 180.0


func _scenario(real: bool, pm: float) -> Dictionary:
	var w: World
	if real:
		w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(w)
		await wait_physics(3)
	else:
		w = await make_world(false, 1)
	world = w as AiTestWorld if w is AiTestWorld else null
	var p := MockPlayer.new()
	p.mass = pm
	var spawn := w.get_player_spawn().origin
	p.path_center = Vector3(spawn.x, 0, spawn.z)
	p.path_radius = 90.0
	p.path_height = w.ground_height(spawn.x, spawn.z) + 25.0
	p.speed = 11.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 1)
	e.focus = p
	var chk := make_checker()
	var safety := Safety.new(w)
	var share := {}
	var samples := 0
	var vis100 := 0.0
	var hidden_max := 0
	for i in int(SIM_S / DT):
		p.step(DT)
		e.step(DT)
		chk.step(DT)
		safety.step(DT, e.get_npcs())
		if i % 72 == 0 and i > 72 * 10:
			samples += 1
			var hid := 0
			for n in e.get_npcs():
				share[n.state_name()] = share.get(n.state_name(), 0) + 1
				if n.hidden:
					hid += 1
				elif n.global_position.distance_to(p.get_body_position()) < 100.0:
					vis100 += 1
			hidden_max = maxi(hidden_max, hid)
	var tot := 0
	for k in share:
		tot += share[k]
	var out := {}
	for k in share:
		out[k] = snappedf(float(share[k]) / tot, 0.001)
	var npc_catches := 0
	for c in chk.catches:
		if c["prey"] != p:
			npc_catches += 1
	var st := e.stats()
	var res := {"world": "real" if real else "test", "player_mass": pm, "state_share": out,
		"visible_within_100m_mean": snappedf(vis100 / maxf(samples, 1), 0.1), "hidden_max": hidden_max,
		"npc_catches": npc_catches, "player_caught": p.times_caught, "hunts_on_player": st["hunts_on_player"],
		"behaviour": st["behaviour"], "safety": safety.counts.duplicate()}
	print("[ai] v2r states %s" % JSON.stringify(res))
	e.queue_free()
	eco = null
	checker = null
	remove_child(p)
	p.queue_free()
	w.queue_free()
	world = null
	Habitat.clear_cache()
	await wait_frames(2)
	return res


func test_state_shares_real_vs_test_world() -> void:
	var rows := []
	for pm: float in [0.03, 0.5]:
		rows.append(await _scenario(true, pm))
		rows.append(await _scenario(false, pm))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("v2r_realworld_states.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	eq(rows.size(), 4, "four scenarios ran")
