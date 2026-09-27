extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): how often NPC bodies actually hit world
## geometry (the collision sweep or the push-out fired: NpcBird.last_hit
## changed) per bird-minute of free flight, in the AI test world (60 NPCs,
## no player, seed 7 - the soak's setup) and in the real valley (a crow-sized
## mock player flying laps). Obstacle avoidance (feelers on layer 1) exists
## to keep this near zero; the A5 safety monitor cannot see it because the
## body's sweep and push-out keep every contact outside the geometry.
## Run on pristine code and on a copy with NpcBrain._avoid_obstacles()
## removed to see whether anything but this probe notices.

const SIM_S := 120.0


func _run(real: bool) -> Dictionary:
	var w: World
	var p: Bird = null
	if real:
		w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(w)
		await wait_physics(3)
		var mp := MockPlayer.new()
		mp.mass = 0.5
		var spawn := w.get_player_spawn().origin
		mp.path_center = Vector3(spawn.x, 0, spawn.z)
		mp.path_radius = 90.0
		mp.path_height = w.ground_height(spawn.x, spawn.z) + 25.0
		mp.speed = 11.0
		add_child(mp)
		mp.step(0.0)
		p = mp
	else:
		w = await make_world(false, 1)
	var e := make_eco(60, 7)
	if p:
		e.focus = p
	var last := {}
	var hits := 0
	var bird_s := 0.0
	var by_state := {}
	for i in int(SIM_S / DT):
		if p:
			p.step(DT)
		e.step(DT)
		for n in e.get_npcs():
			if not (n.perched or n.hidden):
				bird_s += DT
			var id := n.get_instance_id()
			var lh := n.last_hit
			if last.has(id) and lh != last[id]:
				hits += 1
				var k := "%s/%s%s" % [n.species, n.state_name(), "/flare" if n.is_flaring() else ""]
				by_state[k] = by_state.get(k, 0) + 1
			last[id] = lh
	var keys := by_state.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return by_state[a] > by_state[b])
	var top := {}
	for k in keys.slice(0, 10):
		top[k] = by_state[k]
	var res := {"world": "real" if real else "test", "sim_s": SIM_S, "geometry_hits": hits,
		"hits_per_bird_min": snappedf(hits / maxf(bird_s / 60.0, 0.01), 0.01), "top": top}
	print("[ai] v2r bumps %s" % JSON.stringify(res))
	e.queue_free()
	eco = null
	if p:
		remove_child(p)
		p.queue_free()
	w.queue_free()
	world = null
	Habitat.clear_cache()
	await wait_frames(2)
	return res


func test_geometry_hit_rate() -> void:
	var rows := [await _run(false), await _run(true)]
	var f := FileAccess.open(Paths.artifacts("ai").path_join("v2r_bumps.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	eq(rows.size(), 2, "both runs completed")
