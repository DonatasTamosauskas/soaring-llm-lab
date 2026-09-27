extends "res://tests/unit/ai/ai_sim.gd"
## AI builder DIAGNOSTIC (not in the suite): where the per-tick cost of 60
## NPCs goes - population upkeep, flocks, and per bird think / feel / steer
## / fly - with perf_test's protocol (crow-sized player lapping inside the
## population) but stepped manually, in the AI arena and the valley.
##   tools/gd.sh ai --headless res://tests/runner.tscn -- --dir=res://scenes/dev/ai_probes --suite=ai_perf_prof [--pp_world=valley|arena]


func test_perf_profile() -> void:
	var w: World = null
	if Paths.arg("pp_world", "valley") == "arena":
		w = await make_world(false, 1)
	else:
		w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(w)
		await wait_physics(3)
		if not w.is_generated:
			await w.generated
	var p := MockPlayer.new()
	p.mass = 0.5
	var c := Vector3(-20, 0, 10) if w is AiTestWorld else w.get_player_spawn().origin
	p.path_center = Vector3(c.x, 0, c.z)
	p.path_radius = 25.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, w.ground_height(c.x + cos(a) * 25.0, c.z + sin(a) * 25.0))
	p.path_height = gmax + 22.0 if not (w is AiTestWorld) else 30.0
	p.speed = 8.0
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.auto_step = false
	e.rng_seed = 4
	add_child(e)
	e.focus = p
	for i in int(10.0 / DT):
		air(w, i * DT)
		p.step(DT)
		e.step(DT)
	e._part_us = [0, 0, 0]
	e._part_n = 0
	NpcBrain.prof_us = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	NpcBrain.prof_on = true
	var n := int(30.0 / DT)
	var t0 := Time.get_ticks_usec()
	for i in n:
		air(w, 10.0 + i * DT)
		p.step(DT)
		e.step(DT)
	var total_ms := (Time.get_ticks_usec() - t0) / 1000.0 / n
	NpcBrain.prof_on = false
	var parts: Dictionary = e.stats()["tick_parts_ms"]
	var pu: Array = NpcBrain.prof_us
	var row := {"world": Paths.arg("pp_world", "valley"), "tick_ms": snappedf(total_ms, 0.001), "parts_ms": parts,
		"think_ms": snappedf(pu[0] / 1000.0 / n, 0.001), "feel_ms": snappedf(pu[1] / 1000.0 / n, 0.001),
		"steer_ms": snappedf(pu[2] / 1000.0 / n, 0.001), "fly_ms": snappedf(pu[3] / 1000.0 / n, 0.001),
		"fly_step_ms": snappedf(pu[4] / 1000.0 / n, 0.001), "fly_resolve_ms": snappedf(pu[5] / 1000.0 / n, 0.001), "fly_pose_ms": snappedf(pu[6] / 1000.0 / n, 0.001),
		"steer_state_ms": snappedf(pu[7] / 1000.0 / n, 0.001), "steer_clear_bump_ms": snappedf(pu[8] / 1000.0 / n, 0.001),
		"steer_avoid_ms": snappedf(pu[9] / 1000.0 / n, 0.001), "steer_bounds_ground_ms": snappedf(pu[10] / 1000.0 / n, 0.001)}
	var la := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], la)
	row["load"] = la[0].strip_edges() if not la.is_empty() else "?"
	print("[ai-prof] %s" % JSON.stringify(row))
	check(true, "profiled")
	e.queue_free()
	remove_child(p)
	p.queue_free()
	if not (w is AiTestWorld):
		w.queue_free()
	await clear_sim()
