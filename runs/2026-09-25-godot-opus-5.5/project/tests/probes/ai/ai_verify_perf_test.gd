extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (A8). The builder's perf test measured with LOD
## [1, 22, 37] - the mock player circled 110 m from the population centre,
## so 59 of 60 birds were in the cheap LOD tiers. Here the player hovers in
## the middle of the population (homes centre on it), so most birds are
## near (LOD 0) - the case of a player sitting in a busy area. Same method
## as the builder: real SceneTree physics ticks, Ecosystem auto-stepped,
## cost measured inside Ecosystem.step.

const WARMUP := 360
const MEASURE := 1080


func _measure(pm: float, seed_value: int, moving: bool) -> Dictionary:
	await make_world(false, 1)
	var p := MockPlayer.new()
	add_child(p)
	p.mass = pm
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 25.0
	p.path_height = 30.0
	p.speed = 6.0
	p.moving = moving
	p.step(0.0)
	if not moving:
		p.global_position = Vector3(-20, 30, 10)
	var e := make_eco(60, seed_value)
	e.focus = p
	e.auto_step = true
	for i in WARMUP:
		p.step(DT)
		await get_tree().physics_frame
	var samples: Array[int] = []
	var lod_sum := [0, 0, 0]
	var engaged := 0
	for i in MEASURE:
		p.step(DT)
		await get_tree().physics_frame
		samples.append(e._tick_us[(e._tick_i - 1 + e._tick_us.size()) % e._tick_us.size()] if e._tick_us.size() >= 600 else e._tick_us[-1])
		if i % 60 == 0:
			for n in e.get_npcs():
				lod_sum[clampi(n.lod, 0, 2)] += 1
				engaged += 1 if n.is_engaged() else 0
	samples.sort()
	var sum := 0
	for v in samples:
		sum += v
	var keep := int(samples.size() * 0.95)
	var tsum := 0
	for i in keep:
		tsum += samples[i]
	var r := {"mean": sum / 1000.0 / samples.size(), "trimmed": tsum / 1000.0 / keep,
		"median": samples[samples.size() / 2] / 1000.0, "p95": samples[int(samples.size() * 0.95)] / 1000.0,
		"max": samples[-1] / 1000.0, "lod_avg": [lod_sum[0] / 18.0, lod_sum[1] / 18.0, lod_sum[2] / 18.0],
		"engaged_avg": engaged / 18.0, "npcs": e.count()}
	e.auto_step = false
	remove_child(p)
	p.queue_free()
	await clear_sim()
	return r


func test_player_in_the_middle_of_the_population() -> void:
	var table := {}
	for c in [[0.1, 3, true], [0.5, 4, true], [0.03, 5, false]]:
		var r := await _measure(c[0], c[1], c[2])
		table["%.2f_%s" % [c[0], "moving" if c[2] else "still"]] = r
		print("[ai-verify] perf player %.2f kg %s: %s" % [c[0], "moving" if c[2] else "still", r])
		lt(r["median"], 2.0, "median ms/tick with the player among the birds")
		lt(r["trimmed"], 2.0, "5%-trimmed mean ms/tick with the player among the birds")
	metric("perf", table)
