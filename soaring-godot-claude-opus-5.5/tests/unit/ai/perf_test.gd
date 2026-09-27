extends "res://tests/unit/ai/ai_sim.gd"
## A8 Performance: 60 NPCs (brains + flight + model driving + population
## upkeep), stepped by the real SceneTree physics ticks, must cost <= 2.0 ms
## per physics tick on this Mac (measured inside Ecosystem.step, the whole
## population). LOD is on, as in the game.
##
## Where: the valley the game ships with (scenes/world/world.tscn: ~1200
## perches, ~300 refuges, trimesh village and hedgerows - every feeler ray,
## sweep and perch search costs more there than in the AI arena; the
## round-3 verifier measured the valley at 1.12-1.44x the arena), and in
## the evidence run (--ai_full=1) the AI arena too, for comparison.
##
## The player flies small laps in the MIDDLE of the population (life
## follows it, so this is the normal case) at crow size, the size with the
## most birds engaged around it: the demanding case, not a flattering LOD
## mix.
##
## The machine is shared with other agents whose processes preempt ours
## mid-tick (load averages of 6-15 on its 10 cores are common), so single
## samples are inflated by the scheduler and even the ecosystem's own fixed
## bookkeeping measures up to ~1.5x slower under load. Pinned: the median
## and the 5%-trimmed mean against the 2.0 ms budget; as spike guards, the
## tail's shape - 95th percentile under twice the median (an absolute p95
## bound failed at a load of ~10 with a 1.8 ms median: preemption, not the
## code) - and the population upkeep (planning, spawning, recycling)
## amortised under 0.2 ms a tick; mean, p95, max and p10 (the least
## load-inflated figure) are recorded with the load average.

## 360 + 1080 ticks in the evidence run (--ai_full=1), 240 + 720 in the suite.
var WARMUP_TICKS := 360
var MEASURE_TICKS := 1080


func _measure(w: World, tag: String) -> Dictionary:
	var p := MockPlayer.new()
	add_child(p)
	p.mass = 0.5
	var c := Vector3(-20, 0, 10) if w is AiTestWorld else w.get_player_spawn().origin
	p.path_center = Vector3(c.x, 0, c.z)
	p.path_radius = 25.0
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, w.ground_height(c.x + cos(a) * 25.0, c.z + sin(a) * 25.0))
	p.path_height = 30.0 if w is AiTestWorld else gmax + 22.0
	p.speed = 8.0
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.rng_seed = 4
	e.auto_step = true
	add_child(e)
	e.focus = p
	for i in WARMUP_TICKS:
		p.step(DT)
		await get_tree().physics_frame
	e._part_us = [0, 0, 0]
	e._part_n = 0
	var samples: Array[int] = []
	var lod_sum := [0, 0, 0]
	var engaged := 0
	var looks := 0
	var near80 := 0
	for i in MEASURE_TICKS:
		p.step(DT)
		await get_tree().physics_frame
		samples.append(e._tick_us[(e._tick_i - 1 + e._tick_us.size()) % e._tick_us.size()] if e._tick_us.size() >= 600 else e._tick_us[-1])
		if i % 60 == 0:
			looks += 1
			for n in e.get_npcs():
				lod_sum[clampi(n.lod, 0, 2)] += 1
				engaged += 1 if n.is_engaged() else 0
				near80 += 1 if n.global_position.distance_to(p.get_body_position()) < 80.0 else 0
	samples.sort()
	var sum := 0
	for v in samples:
		sum += v
	var keep := int(samples.size() * 0.95)
	var tsum := 0
	for i in keep:
		tsum += samples[i]
	var st := e.stats()
	var la := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], la)
	var row := {"world": tag, "npcs": st["npcs"], "ticks": samples.size(),
		"mean": snappedf(sum / 1000.0 / samples.size(), 0.001), "trimmed_mean": snappedf(tsum / 1000.0 / keep, 0.001),
		"median": snappedf(samples[samples.size() / 2] / 1000.0, 0.001),
		"p10": snappedf(samples[int(samples.size() * 0.10)] / 1000.0, 0.001),
		"p95": snappedf(samples[int(samples.size() * 0.95)] / 1000.0, 0.001), "max": snappedf(samples[-1] / 1000.0, 0.001),
		"lod_avg": [snappedf(lod_sum[0] / float(looks), 0.1), snappedf(lod_sum[1] / float(looks), 0.1), snappedf(lod_sum[2] / float(looks), 0.1)],
		"engaged_avg": snappedf(engaged / float(looks), 0.1), "within_80m_avg": snappedf(near80 / float(looks), 0.1), "parts_ms": st["tick_parts_ms"],
		"load_average": la[0].strip_edges() if not la.is_empty() else "?"}
	print("[ai] perf %s: %s" % [tag, JSON.stringify(row)])
	e.auto_step = false
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func _check(row: Dictionary) -> void:
	var tag: String = row["world"]
	eq(row["npcs"], 60, "%s: a full population of 60" % tag)
	# The demanding case: most of the population round the player (the LOD
	# settings are the game's own, and the budget is measured with them).
	gt(row["within_80m_avg"], 30.0, "%s: most birds within 80 m of the player: the demanding case" % tag)
	lt(row["trimmed_mean"], 2.0, "%s: 5%%-trimmed mean AI+movement cost per physics tick (ms)" % tag)
	lt(row["median"], 2.0, "%s: median cost per tick (ms)" % tag)
	lt(float(row["p95"]) / maxf(row["median"], 1e-3), 2.0, "%s: 95th percentile under twice the median: no heavy tail (p95 %.2f ms)" % [tag, row["p95"]])
	lt(float(row["parts_ms"]["upkeep"]), 0.2, "%s: population upkeep amortised per tick (ms)" % tag)


func test_sixty_npcs_fit_the_tick_budget() -> void:
	if not full():
		WARMUP_TICKS = 240
		MEASURE_TICKS = 720
	var rows := {}
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	check(ps != null, "(setup) the valley scene loads")
	if ps != null:
		var w := ps.instantiate() as World
		add_child(w)
		await wait_physics(3)
		if not w.is_generated:
			await w.generated
		rows["valley"] = await _measure(w, "valley")
		w.queue_free()
		Habitat.clear_cache()
		await wait_frames(2)
		_check(rows["valley"])
	if full() or Paths.arg("perf_arena", "") != "":
		await make_world(false, 1)
		rows["arena"] = await _measure(world, "arena")
		_check(rows["arena"])
		await clear_sim()
	metric("tick_ms", rows)
	var f := FileAccess.open(Paths.artifacts("ai").path_join("perf_report%s.json" % ("" if full() else "_suite")), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
