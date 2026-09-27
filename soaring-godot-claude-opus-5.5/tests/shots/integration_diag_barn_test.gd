extends "res://tests/unit/ai/ai_sim.gd"
## DIAGNOSTIC (integration round 1): flee_test's barn-door scenario over many
## RNG seed offsets (the AI suite's spawn() advances a shared seed, so a test
## added earlier in flee_test shifted the barn test's seeds).
##
##   tools/gd.sh fx_ai --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=integration_diag_barn


func test_barn_over_seeds() -> void:
	const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
	var w := AiTestWorld.new()
	w.with_visuals = false
	w.with_environment = false
	add_child(w)
	await wait_physics(3)
	var h := Habitat.for_world(w)
	var barn := {}
	for r in h.refuges:
		if float(r["max_span"]) >= 0.7:
			barn = r
			break
	var entry: Dictionary = barn["entry"]
	var door: Vector3 = entry["through"]
	var rows := []
	for off in 12:
		_seed = 1000 + off * 17 * 7
		var hid := 0
		var trials := 6
		for t in trials:
			var a := -0.9 + 1.8 * t / (trials - 1)
			var start := door + Vector3(sin(a) * 16.0, 4.0, -cos(a) * 16.0)
			var prey := spawn(&"pigeon", start, Vector3(-sin(a), 0, cos(a)) * 12.0, w)
			prey.can_hunt = false
			var hawk := spawn(&"hawk", start + Vector3(sin(a) * 45.0, 15.0, -cos(a) * 45.0), Vector3(-sin(a), 0, cos(a)) * 17.0, w)
			hawk.can_flee = false
			hawk.hunger = 1.0
			hawk.brain._pending_prey = prey
			hawk.brain._enter(NpcBird.State.HUNT)
			var res := {"caught": false}
			run(15.0, func(_i: int) -> bool:
				if not prey.alive:
					res["caught"] = true
				return prey.hidden or not prey.alive)
			if prey.hidden:
				hid += 1
			despawn(prey)
			despawn(hawk)
			await wait_frames(1)
		rows.append(hid)
		print("[integration] barn seed offset %d: %d of 6 hid" % [off, hid])
	print("[integration] barn over seeds: ", rows)
	w.queue_free()
	await wait_frames(1)
