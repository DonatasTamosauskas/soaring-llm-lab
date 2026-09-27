extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 3, engineering lens): A8 in the world the game ships
## with. perf_test measures 60 NPCs in the AI arena (31 refuges, simple
## boxes); the real valley (scenes/world/world.tscn: ~1200 perches, ~300
## refuges, trimesh village and hedges) makes every feeler ray, sweep and
## perch search dearer. Same protocol as perf_test (crow-sized player lapping
## inside the population, real SceneTree physics ticks, 360 warm-up + 1080
## measured ticks, cost read from Ecosystem.step), reported with the load
## average. Two player sizes. The machine is shared: to compare like with
## like, --r3e_world=arena runs the identical protocol in the AI arena
## (perf_test's world) so the two can be alternated under the same load;
## p10/p25 are reported as the least load-inflated figures.
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r3e_valley_perf [--r3e_world=arena] [--r3e_sizes=crow]
## Report: artifacts/ai/verify/r3e/valley_perf_<world>_<n>.json

const WARMUP_TICKS := 360
const MEASURE_TICKS := 1080

var _w: World = null


func before_all() -> void:
	if Paths.arg("r3e_world", "valley") == "arena":
		_w = await make_world(false, 1)
		world = null
		return
	var ps := load("res://scenes/world/world.tscn") as PackedScene
	_w = ps.instantiate() as World
	add_child(_w)
	await wait_physics(3)
	if not _w.is_generated:
		await _w.generated


func after_all() -> void:
	if is_instance_valid(_w):
		_w.queue_free()
	Habitat.clear_cache()
	await wait_frames(2)


func _measure(pm: float, radius: float, seed_v: int) -> Dictionary:
	var p := MockPlayer.new()
	p.mass = pm
	var sp0 := _w.get_player_spawn().origin
	if Paths.arg("r3e_world", "valley") == "arena":
		sp0 = Vector3(-20, 0, 10)  # perf_test's lap centre
	p.path_center = Vector3(sp0.x, 0, sp0.z)
	p.path_radius = radius
	var gmax := 0.0
	for k in 36:
		var a := TAU * k / 36.0
		gmax = maxf(gmax, _w.ground_height(sp0.x + cos(a) * radius, sp0.z + sin(a) * radius))
	p.path_height = gmax + 22.0
	p.speed = minf(SizeRules.cruise_speed(pm), 12.0)
	if pm == 0.5:
		p.speed = 8.0  # as perf_test
		if Paths.arg("r3e_world", "valley") == "arena":
			p.path_height = 30.0  # as perf_test
	add_child(p)
	p.step(0.0)
	var e := EcoScene.instantiate() as Ecosystem
	e.rng_seed = seed_v
	e.auto_step = true
	add_child(e)
	e.focus = p
	for i in WARMUP_TICKS:
		p.step(DT)
		await get_tree().physics_frame
	var samples: Array[int] = []
	var lod_sum := [0, 0, 0]
	var engaged := 0
	var looks := 0
	for i in MEASURE_TICKS:
		p.step(DT)
		await get_tree().physics_frame
		samples.append(e._tick_us[(e._tick_i - 1 + e._tick_us.size()) % e._tick_us.size()] if e._tick_us.size() >= 600 else e._tick_us[-1])
		if i % 60 == 0:
			looks += 1
			for n in e.get_npcs():
				lod_sum[clampi(n.lod, 0, 2)] += 1
				engaged += 1 if n.is_engaged() else 0
	samples.sort()
	var med := samples[samples.size() / 2] / 1000.0
	var keep := int(samples.size() * 0.95)
	var tsum := 0
	for i in keep:
		tsum += samples[i]
	var la := []
	OS.execute("sysctl", ["-n", "vm.loadavg"], la)
	var row := {"world": Paths.arg("r3e_world", "valley"), "p10_ms": snappedf(samples[int(samples.size() * 0.10)] / 1000.0, 0.001),
		"p25_ms": snappedf(samples[int(samples.size() * 0.25)] / 1000.0, 0.001), "player_mass": pm, "lap_radius": radius, "npcs": e.count(), "median_ms": snappedf(med, 0.001),
		"trimmed_mean_ms": snappedf(tsum / 1000.0 / keep, 0.001),
		"p95_ms": snappedf(samples[int(samples.size() * 0.95)] / 1000.0, 0.001),
		"max_ms": snappedf(samples[-1] / 1000.0, 0.001),
		"lod_avg": [snappedf(lod_sum[0] / float(looks), 0.1), snappedf(lod_sum[1] / float(looks), 0.1), snappedf(lod_sum[2] / float(looks), 0.1)],
		"engaged_avg": snappedf(engaged / float(looks), 0.1), "parts_ms": e.stats()["tick_parts_ms"],
		"load_average": la[0].strip_edges() if not la.is_empty() else "?"}
	print("[ai] r3e valley perf %s" % JSON.stringify(row))
	e.auto_step = false
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await wait_frames(2)
	return row


func test_sixty_npcs_in_the_valley_fit_the_tick_budget() -> void:
	var rows := [await _measure(0.5, 25.0, 4)]
	if Paths.arg("r3e_sizes", "all") != "crow":
		rows.append(await _measure(0.03, 60.0, 5))
	for r in rows:
		eq(r["npcs"], 60, "a full population of 60 (player %.2f kg)" % r["player_mass"])
		lt(r["median_ms"], 2.0, "valley, player %.2f kg: median cost per tick (ms)" % r["player_mass"])
		lt(r["trimmed_mean_ms"], 2.0, "valley, player %.2f kg: 5%%-trimmed mean cost per tick (ms)" % r["player_mass"])
	metric("valley_perf", rows)
	var f := FileAccess.open(Paths.artifacts("ai/verify/r3e").path_join("valley_perf_%s_%d.json" % [Paths.arg("r3e_world", "valley"), Time.get_unix_time_from_system()]), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
