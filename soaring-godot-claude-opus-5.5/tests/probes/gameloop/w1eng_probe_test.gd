extends "res://tests/unit/game/game_fixture.gd"
## Engineering verifier (workflow round 1) probes for the game loop. Not part
## of the area's suite; run with:
##
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop --suite=w1eng
##
## 1. catch cost: is test_catch_cost_60_birds really measuring 60 live birds?
##    (it takes the best of four 50-frame windows while the flocks eat each
##    other); the same scenario with the population held at 60.
## 2. a named predator that leaves the game: what the cue listeners see.
## 3. the loop runs after the birds moved in the same physics tick.
## 4. the stored valley evidence replays (only in a tree whose AI / valley /
##    core code is what the evidence ran: the frozen-sky overlay).

const DT := 1.0 / 72.0
const Y := 20.0
const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")
const LIVE_EVIDENCE := "res://scripts/game/data/live_ai_evidence.json"


func _flock_scene(rng: RandomNumberGenerator) -> void:
	for i in 60:
		var centre := Vector3((i % 4) * 30.0, Y, 0) if i < 40 else Vector3(rng.randf_range(-200, 200), Y, rng.randf_range(-200, 200))
		var spread := 3.0 if i < 40 else 0.0
		make_bird(exp(rng.randf_range(log(0.004), log(4.5))),
				centre + Vector3(rng.randf_range(-spread, spread), rng.randf_range(-spread, spread), rng.randf_range(-spread, spread)),
				Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)))


func _cost_run(keep_population: bool) -> Dictionary:
	make_loop()
	loop.broad_phase = GameLoop.BroadPhase.HASH
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	_flock_scene(rng)
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 8
	var times: Array[float] = []
	var alive_at := []
	var windows := []
	for s in 200:
		for b in birds:
			if b.alive:
				b.fly(b.heading.rotated(Vector3.UP, 0.05), b.cruise_speed(), DT)
		loop.step(DT)
		times.append(float(loop.perf["catch"]))
		var n_alive := 0
		for b in birds:
			if b.alive:
				n_alive += 1
		if s % 50 == 0 or s == 199:
			alive_at.append([s, n_alive])
		if keep_population:
			# Eaten birds come back into a flock at once (a stand-in for the
			# Ecosystem's respawns): the pass always sees 60 live birds.
			var k := 0
			for b in birds:
				if not b.alive:
					b.alive = true
					var c := Vector3((k % 4) * 30.0, Y, 0)
					b.global_position = c + Vector3(rng2.randf_range(-3, 3), rng2.randf_range(-3, 3), rng2.randf_range(-3, 3))
					loop.teleported(b)
					k += 1
	for w in 4:
		var win := times.slice(w * 50, w * 50 + 50)
		win.sort()
		windows.append(win[25])
	var all := times.duplicate()
	all.sort()
	var out := {"alive_at": alive_at, "window_medians": windows, "median": all[100], "p95": all[190],
		"best_window": windows.min()}
	await cleanup()
	return out


func test_w1_catch_cost_population() -> void:
	var shrinking := await _cost_run(false)
	var steady := await _cost_run(true)
	metric("catch_cost_as_in_the_unit_test", shrinking)
	metric("catch_cost_60_live_birds", steady)
	print("[gameloop] w1eng catch cost: unit-test scenario %s; population held at 60 %s" % [shrinking, steady])
	check(true, "measured")


func test_w1_named_predator_leaves_the_game() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3(0, Y, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.opening_respite_s = 0.0
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var hawk := make_bird(1.3, Vector3(0, Y, -30), Vector3.BACK, false, true)
	hawk.velocity = Vector3(0, 0, 12)
	var got: Array = []
	var cb := func(level: float, pred: Bird) -> void:
		got.append([level, pred, is_instance_valid(pred) if pred != null else true])
	Events.threat_changed.connect(cb)
	for i in 60:
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	var named_before := loop.watch.predator == hawk
	var level_before := loop.watch.level
	got.clear()
	# The hawk leaves the game (despawned by the Ecosystem): bird_removed on
	# exit, then freed.
	hawk.queue_free()
	await get_tree().process_frame
	var events_before_step := got.size()
	loop.step(DT)
	Events.threat_changed.disconnect(cb)
	var last: Array = got[-1] if not got.is_empty() else []
	metric("removed_predator", {"named_before": named_before, "level_before": level_before,
		"events_on_removal_before_next_step": events_before_step, "events_after_step": got.size(),
		"last_level": last[0] if not last.is_empty() else -1.0,
		"last_pred_null": (last[1] == null) if not last.is_empty() else false})
	check(named_before and level_before > 0.3, "(setup) the hawk is named at attack level")
	check(not last.is_empty() and last[1] == null and float(last[0]) == 0.0,
			"after the named predator leaves, the cue says (0, null) by the next step")


## A node that moves the hunter into the prey at the default physics priority.
class _Mover extends Node:
	var bird: SimBird
	var to := Vector3.ZERO
	var at_frame := -1
	var frame := 0

	func _physics_process(_dt: float) -> void:
		frame += 1
		if frame == at_frame:
			bird.global_position = to


func test_w1_loop_runs_after_the_birds_moved() -> void:
	make_loop()
	loop.auto_step = true
	var hunter := make_bird(0.35, Vector3(0, Y, 1.5), Vector3.FORWARD)
	var prey := make_bird(0.09, Vector3(0, Y, -0.1), Vector3.FORWARD)
	# Beyond reach at first; the mover puts it in reach on its frame 3 (a
	# 1.4 m jump at 72 Hz is under the loop's teleport threshold, so it is
	# swept, and the segment ends in reach).
	var mover := _Mover.new()
	mover.bird = hunter
	mover.to = Vector3(0, Y, 0.1)
	mover.at_frame = 3
	add_child(mover)
	var dead_on := -1
	for f in 8:
		await get_tree().physics_frame
		if not prey.alive and dead_on < 0:
			dead_on = mover.frame
	metric("catch_seen_after_mover_frame", dead_on)
	eq(dead_on, 3, "the catch happens in the physics tick the hunter moved (the loop runs after the birds)")
	mover.queue_free()
	loop.auto_step = false


## How often the HUD's target cue moves away from a bird that is still a
## valid chase (alive, not sheltered, still worthwhile): the whole-game
## catch test (docs/INTEGRATION.md §8) saw 60-80% of cue-following chases end
## that way. The pacing pilot keeps its own target whatever the cue says
## (IntegratedSim._choose_target), so the evidence never measures it. Mirror
## sky (deterministic, no AI code), competent pilot, --w1_churn_s seconds.
func test_w1_target_cue_churn() -> void:
	var secs := float(Paths.user_args().get("w1_churn_s", "900"))
	var sim := IntegratedSim.new()
	add_child(sim)
	await get_tree().process_frame
	var named_at := {}  # instance id -> loop run time when named
	var st := {"prev": null, "prev_id": 0, "voluntary": 0, "total": 0, "holds": [], "gaps_spans": []}
	var cb := func(t: Bird) -> void:
		var now := sim.loop.stats.run_time
		var old: Variant = st["prev"]
		var old_id: int = st["prev_id"]
		if old_id != 0:
			st["total"] = int(st["total"]) + 1
			var ob := instance_from_id(old_id) as Bird
			# Still a valid target for the cue itself: alive, not sheltered,
			# worthwhile, inside the target range with its hysteresis (the
			# mirror sky has no geometry: always in sight). A switch away
			# from such a bird is by preference (a rival scored 1.35x after
			# the 1.5 s hold), not because the old one became invalid.
			if ob != null and is_instance_valid(ob) and ob.alive and sim.player != null and sim.player.alive \
					and not sim.loop.is_sheltered(ob, sim.player.get_wingspan()) \
					and SizeRules.is_worthwhile(sim.player.mass, ob.mass) and t != null \
					and ob.get_body_position().distance_to(sim.player.get_body_position()) \
						<= sim.loop.watch.target_range(sim.player.mass) * sim.loop.watch.range_hysteresis:
				st["voluntary"] = int(st["voluntary"]) + 1
				(st["holds"] as Array).append(now - float(named_at.get(old_id, now)))
				(st["gaps_spans"] as Array).append(ob.get_body_position().distance_to(sim.player.get_body_position())
						/ sim.player.get_wingspan())
		st["prev"] = t
		st["prev_id"] = t.get_instance_id() if t != null else 0
		if t != null:
			named_at[t.get_instance_id()] = now
	Events.target_changed.connect(cb)
	var r: Dictionary = await sim.run(&"competent", 100, secs)
	Events.target_changed.disconnect(cb)
	var holds: Array = st["holds"]
	holds.sort()
	var gaps: Array = st["gaps_spans"]
	gaps.sort()
	var short := holds.filter(func(h: float) -> bool: return h < 3.0).size()
	var minutes := secs / 60.0
	var out := {"seconds": secs, "target_changes": st["total"], "voluntary_switches": st["voluntary"],
		"voluntary_per_min": float(st["voluntary"]) / minutes,
		"median_hold_s_before_voluntary_switch": holds[holds.size() / 2] if not holds.is_empty() else -1.0,
		"share_of_voluntary_switches_within_3s": float(short) / maxf(holds.size(), 1.0),
		"median_gap_to_abandoned_target_spans": gaps[gaps.size() / 2] if not gaps.is_empty() else -1.0,
		"player_catches": r["catches"]}
	metric("target_cue_churn", out)
	print("[gameloop] w1eng target cue churn: %s" % out)
	check(true, "measured")
	sim.queue_free()
	await get_tree().process_frame


func test_w1_evidence_replays_in_its_own_sky() -> void:
	var f := FileAccess.open(LIVE_EVIDENCE, FileAccess.READ)
	var ev: Dictionary = JSON.parse_string(f.get_as_text()) if f else {}
	var now := IntegratedSim.sky_code(&"valley")
	var same := String(now["ai_code"]) == String(ev.get("ai_code", "")) \
			and String(now["world_code"]) == String(ev.get("world_code", "")) \
			and String(now["core_code"]) == String(ev.get("core_code", ""))
	metric("sky_code_now_vs_evidence", {"now": now, "evidence": {"ai_code": ev.get("ai_code"),
		"world_code": ev.get("world_code"), "core_code": ev.get("core_code")}, "same": same,
		"fingerprint_now": IntegratedSim.fingerprint(), "fingerprint_evidence": ev.get("fingerprint")})
	if not same:
		check(true, "(skipped: this tree's AI/valley/core is not what the evidence ran)")
		return
	var args := Paths.user_args()
	var seed_ := int(args.get("w1_seed", "800"))
	var block := String(args.get("w1_block", "holdout"))
	var secs := float(args.get("w1_s", "360"))
	var stored := {}
	for r: Dictionary in ev.get(block, {}).get("competent", {}).get("runs", []):
		if int(r["seed"]) == seed_:
			stored = r
	check(not stored.is_empty(), "(setup) stored run found")
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	add_child(sim)
	await get_tree().process_frame
	var r: Dictionary = await sim.run(&"competent", seed_, secs)
	var diffs := 0
	var n := 0
	for c: Array in stored["checkpoints"]:
		if float(c[0]) > secs + 1e-6:
			continue
		if n >= (r["checkpoints"] as Array).size():
			diffs += 1
			n += 1
			continue
		var a: Array = r["checkpoints"][n]
		for k in c.size():
			if absf(float(a[k]) - float(c[k])) > 1e-3:
				diffs += 1
				break
		n += 1
	var out := {"seed": seed_, "block": block, "seconds": secs, "checkpoints_compared": n, "checkpoints_differing": diffs,
		"stored_catches": (stored["catch_log"] as Array).filter(func(c: Array) -> bool: return float(c[0]) <= secs).size(),
		"replayed_catches": (r["catch_log"] as Array).filter(func(c: Array) -> bool: return float(c[0]) <= secs).size()}
	metric("replay", out)
	print("[gameloop] w1eng replay: %s" % out)
	var w := FileAccess.open(Paths.artifacts("gameloop").path_join("verify/w1eng_replay_%s_%d_%ds.json" % [block, seed_, int(secs)]), FileAccess.WRITE)
	if w:
		w.store_string(JSON.stringify(out, "  "))
	gt(float(n), 3.0, "(setup) several checkpoints")
	eq(diffs, 0, "every checkpoint of the stored run replays")
	eq(out["replayed_catches"], out["stored_catches"], "same catches")
	sim.queue_free()
	await get_tree().process_frame
