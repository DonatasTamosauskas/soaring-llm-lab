extends "res://tests/unit/game/game_fixture.gd"
## The watch pass's cost in its worst plausible 60-bird frames (a tool, not
## in any suite): 59 predators all hunting and closing on the player, and 59
## worthwhile prey all in range with static geometry around (the target cue
## casts sight rays) - the fix round 5 review's cases - and a mixed sky.
##   tools/gd.sh gameloop --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=gameloop_watch_bench
## Prints the median of perf["watch"] (µs) per case, best of three windows.

const DT := 1.0 / 72.0


func _case(mode: String) -> Dictionary:
	make_loop()
	var p := make_bird(0.3 if mode == "hunters" else 1.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var others: Array[SimBird] = []
	for k in 59:
		var ang := rng.randf() * TAU
		var d := rng.randf_range(6.0, 30.0)
		var pos := Vector3(cos(ang) * d, 30 + rng.randf_range(-5, 5), sin(ang) * d)
		var m := 0.0
		match mode:
			"hunters":
				m = rng.randf_range(0.5, 3.0)
			"prey":
				m = rng.randf_range(0.2, 0.9)
			_:
				m = exp(rng.randf_range(log(0.01), log(3.0)))
		var b := make_bird(m, pos, (Vector3(0, 30, 0) - pos).normalized())
		b.velocity = (Vector3(0, 30, 0) - pos).normalized() * 6.0
		others.append(b)
	var best := INF
	var p95 := 0.0
	for w in 3:
		var costs: Array[float] = []
		for i in 240:
			await get_tree().physics_frame
			for b in others:
				b.global_position += b.velocity * DT * 0.2
			loop.step(DT)
			costs.append(float(loop.perf.get("watch", 0)))
		costs.sort()
		if costs[costs.size() / 2] < best:
			best = costs[costs.size() / 2]
			p95 = costs[(costs.size() * 95) / 100]
	await cleanup()
	return {"median_us": best, "p95_us": p95}


func test_watch_bench() -> void:
	var walls: Array[StaticBody3D] = []
	for k in 12:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2, 8, 2)
		cs.shape = box
		sb.add_child(cs)
		sb.collision_layer = 1
		add_child(sb)
		sb.global_position = Vector3(cos(k * 0.52) * 9.0, 30, sin(k * 0.52) * 9.0)
		walls.append(sb)
	await get_tree().physics_frame
	for mode in ["hunters", "prey", "mixed"]:
		var r: Dictionary = await _case(mode)
		metric(mode, r)
		print("[gameloop] watch bench %-8s median %.0f us, p95 %.0f us" % [mode, r["median_us"], r["p95_us"]])
	for w in walls:
		w.queue_free()
	check(true, "measured")
