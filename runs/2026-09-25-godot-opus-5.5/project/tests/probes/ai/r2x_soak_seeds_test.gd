extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2, experience lens): the A1 soak on seeds the
## builder never tuned against, and longer than 10 minutes, with the A1/A5
## assertions restated independently plus "is the sky alive" measures the
## suite does not take:
##  * catches in EVERY 2-minute window, >= 4 predator species, each counted
##    behaviour present (flock, perch, thermal, hunt, flee, stoop);
##  * share of the population hidden in refuges / fleeing (a sky whose birds
##    are mostly hiding is not alive), perch attempts that end on a perch;
##  * safety every tick (A5 monitor), population in band, no engine warnings;
##  * NPC-vs-NPC catch mix: catches by birds that were not hunting (bumps,
##    shared refuges) must be rare.
## Outputs artifacts/ai/verify/r2/soak_seed<N>_<S>s.json.
##   tools/gd.sh aiexp --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai \
##       --suite=r2x_soak_seeds --r2x_seed=23 --r2x_soak_s=600

const Safety := preload("res://tests/unit/ai/safety_monitor.gd")
const WarningLog := preload("res://tests/unit/ai/warning_log.gd")


func test_r2x_soak_other_seed() -> void:
	var soak_s := float(Paths.arg("r2x_soak_s", "600"))
	var seed_v := int(Paths.arg("r2x_seed", "23"))
	var real := Paths.arg("r2x_world", "test") == "real"
	var log: Logger = WarningLog.install()
	var w: World = null
	if real:
		# The shipped valley (SoaringWorld) instead of the AI test arena.
		w = (load("res://scenes/world/world.tscn") as PackedScene).instantiate() as World
		add_child(w)
		await wait_physics(3)
	else:
		w = await make_world(false, 1)
	var e := make_eco(60, seed_v)
	var chk := make_checker()
	var safety := Safety.new(w)
	var n_win := int(ceil(soak_s / 120.0))
	var windows := []
	for i in n_win:
		windows.append(0)
	var pop := {"min": 999, "max": 0}
	var samples := 0
	var hidden_sum := 0.0
	var flee_sum := 0.0
	var fear_max := 0.0
	var perched_sum := 0.0
	var not_hunting_catches := 0
	var pre_state := {}
	var t0 := Time.get_ticks_msec()
	var steps := int(round(soak_s / DT))
	for i in steps:
		e.step(DT)
		pre_state.clear()
		for n in e.get_npcs():
			pre_state[n] = n.state
		var before: int = chk.catches.size()
		chk.step(DT)
		for j in range(before, chk.catches.size()):
			var c: Dictionary = chk.catches[j]
			var pr: Variant = c["predator"]
			var st: int = pre_state.get(pr, -1)
			if st != NpcBird.State.HUNT and st != NpcBird.State.STOOP:
				not_hunting_catches += 1
		safety.step(DT, e.get_npcs())
		if i > 72:
			pop["min"] = mini(pop["min"], e.count())
			pop["max"] = maxi(pop["max"], e.count())
		if i % 72 == 0 and i > 72 * 30:
			var hid := 0
			var fl := 0
			var pc := 0
			for n in e.get_npcs():
				if n.hidden or n.state == NpcBird.State.HIDE:
					hid += 1
				if n.state == NpcBird.State.FLEE:
					fl += 1
				if n.perched:
					pc += 1
			var cnt := maxf(e.count(), 1)
			samples += 1
			hidden_sum += hid / cnt
			flee_sum += fl / cnt
			perched_sum += pc / cnt
			fear_max = maxf(fear_max, (hid + fl) / cnt)
	var wall := (Time.get_ticks_msec() - t0) / 1000.0
	log.uninstall()
	for c in chk.catches:
		windows[mini(int(c["t"] / 120.0), n_win - 1)] += 1
	var st2 := e.stats()
	var beh: Dictionary = st2["behaviour"]
	var by_pred: Dictionary = chk.count_by_predator()
	var flock_share := float(st2["flock_time"]) / (soak_s * 60.0)
	var perch_ok := float(beh.get("perch", 0)) / maxf(float(beh.get("perch_go", 0)), 1.0)
	var report := {
		"seed": seed_v, "sim_s": soak_s, "wall_s": wall, "catches": chk.catches.size(),
		"catch_windows_2min": windows, "catches_by_predator": by_pred,
		"catches_by_non_hunting_predator": not_hunting_catches,
		"flock_share": flock_share, "behaviour": beh, "population": pop,
		"safety": safety.counts, "safety_examples": safety.examples,
		"hidden_share_mean": hidden_sum / maxf(samples, 1), "flee_share_mean": flee_sum / maxf(samples, 1),
		"fear_share_max": fear_max, "perched_share_mean": perched_sum / maxf(samples, 1),
		"perch_landing_per_attempt": perch_ok, "engine_warnings": log.warnings, "engine_errors": log.errors,
		"envelope": safety.envelope, "motion_mismatch_mean": safety.motion_sum / maxf(safety.motion_segments, 1),
		"tick_ms_avg": st2["tick_ms_avg"], "despawned": st2["despawned"],
	}
	report["world"] = "real" if real else "test"
	print("[ai-r2x] soak seed %d: %s" % [seed_v, JSON.stringify(report)])
	DirAccess.make_dir_recursive_absolute(Paths.artifacts("ai").path_join("verify/r2"))
	var f := FileAccess.open(Paths.artifacts("ai").path_join("verify/r2/soak_%sseed%d_%ds.json" % ["real_" if real else "", seed_v, int(soak_s)]), FileAccess.WRITE)
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	# --- A1 ---
	gt(chk.catches.size(), soak_s / 30.0, "NPC-vs-NPC catches >= 1 per 30 s")
	for wi in windows.size():
		gt(windows[wi], 0, "catches in 2-minute window %d" % wi)
	gt(by_pred.size(), 3, "predator species that caught something (>= 4)")
	gt(flock_share, 0.1, "flocking share of bird-time")
	for k in ["perch", "thermal", "hunt", "flee", "stoop", "jink", "refuge"]:
		gt(beh.get(k, 0), 0, "behaviour counted: %s" % k)
	lt(float(not_hunting_catches) / maxf(chk.catches.size(), 1), 0.2, "catches by birds that were not hunting (accidents) are rare")
	# --- aliveness ---
	lt(hidden_sum / maxf(samples, 1), 0.25, "mean share of birds hidden in refuges")
	gt(perch_ok, 0.4, "perch attempts that end on a perch")
	# --- A5 / population / hygiene ---
	for k in safety.counts:
		eq(safety.counts[k], 0, "safety: %s" % k)
	lt(pop["max"], e.max_npcs + 1, "never above the cap")
	gt(pop["min"], e.max_npcs - e.tolerance - 1, "never below target - tolerance")
	eq(log.warnings + log.errors, 0, "no engine warnings/errors %s" % str(log.samples))
	if real:
		e.queue_free()
		eco = null
		w.queue_free()
		Habitat.clear_cache()
		await wait_frames(2)
	else:
		await clear_sim()
