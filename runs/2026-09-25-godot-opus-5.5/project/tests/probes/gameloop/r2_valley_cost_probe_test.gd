extends "res://tests/unit/game/game_fixture.gd"
## Verifier round 2 probe: what the GameLoop costs per physics frame in the
## world the game ships with - the AI's real Ecosystem (60 NPCs) in the world
## area's valley (SoaringWorld, ~300 refuges), a modelled player hunting with
## the loop's own target cue. G6 asks for the threat/target pass < 0.3 ms for
## 60 birds; the area measures it with no refuges at all.
##
##   tools/gd.sh gameloop_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r2_valley_cost [--r2_cost_s=180]

const ValleySky := preload("res://tests/probes/gameloop/r2_valley_sky.gd")


func _pct(xs: Array[float], q: float) -> float:
	return xs[clampi(int(xs.size() * q), 0, xs.size() - 1)]


func test_loop_cost_in_the_live_valley() -> void:
	var secs := float(Paths.user_args().get("r2_cost_s", "180"))
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node: return ValleySky.new()
	add_child(sim)
	await get_tree().process_frame
	var report := {}
	for start_mass in [0.03, 0.35]:
		for use_refuges in [true, false]:
			sim._build()
			await sim.eco.call(&"prepare")
			sim.eco.call(&"seed_rng", 5)
			var loop2 := sim.loop
			var player := sim.player
			var pilot := SimPilot.new(&"competent", 5)
			loop2.start_run()
			player.mass = start_mass
			loop2.set_protection(player, 1e6)  # measure, do not die
			if not use_refuges:
				loop2.watch.refuges = []
				loop2._refuges = []
			var n_ref := loop2._refuges.size()
			var watch: Array[float] = []
			var catch_: Array[float] = []
			var total: Array[float] = []
			var prey_in_range: Array[float] = []
			var t := 0.0
			while t < secs:
				t += IntegratedSim.DT
				sim.eco.call(&"step", IntegratedSim.DT)
				var tg := loop2.watch.target
				if tg != null and is_instance_valid(tg) and tg.alive:
					pilot.hunt(player, tg, IntegratedSim.DT)
				else:
					pilot.cruise(player, IntegratedSim.DT)
				# Keep the size fixed (a meal would change the scenario).
				if absf(player.mass - start_mass) > 1e-6:
					player.mass = start_mass
				loop2.step(IntegratedSim.DT)
				if t > 5.0:
					watch.append(float(loop2.perf.get("watch", 0)))
					catch_.append(float(loop2.perf.get("catch", 0)))
					total.append(float(loop2.perf.get("total", 0)))
					var tr := loop2.watch.target_range(player.mass)
					var k := 0
					for b in Birds.all():
						if b != player and b.alive and SizeRules.is_worthwhile(player.mass, b.mass) \
								and b.get_body_position().distance_to(player.get_body_position()) <= tr:
							k += 1
					prey_in_range.append(float(k))
			watch.sort()
			catch_.sort()
			total.sort()
			prey_in_range.sort()
			var key := "%s_%s" % ["sparrow" if start_mass < 0.1 else "pigeon", "refuges" if use_refuges else "no_refuges"]
			report[key] = {"refuges": n_ref, "birds": Birds.count(), "frames": watch.size(),
				"watch_us": {"median": _pct(watch, 0.5), "p95": _pct(watch, 0.95), "p99": _pct(watch, 0.99), "max": watch[-1]},
				"catch_us": {"median": _pct(catch_, 0.5), "p95": _pct(catch_, 0.95)},
				"total_us": {"median": _pct(total, 0.5), "p95": _pct(total, 0.95), "p99": _pct(total, 0.99)},
				"worthwhile_prey_in_target_range": {"median": _pct(prey_in_range, 0.5), "p95": _pct(prey_in_range, 0.95), "max": prey_in_range[-1]}}
			print("[gameloop-verify] live valley cost %s: %s" % [key, JSON.stringify(report[key])])
	metric("live_valley_cost", report)
	for key in report:
		if String(key).ends_with("_refuges") and not String(key).ends_with("no_refuges"):
			lt(float(report[key]["watch_us"]["median"]), 300.0, "G6 %s: watch pass < 0.3 ms (median) in the live valley" % key)
			lt(float(report[key]["watch_us"]["p95"]), 300.0, "G6 %s: watch pass < 0.3 ms (p95) in the live valley" % key)
	sim.queue_free()
	await get_tree().process_frame
