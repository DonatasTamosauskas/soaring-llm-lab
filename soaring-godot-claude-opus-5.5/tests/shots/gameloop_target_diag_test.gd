extends TestCase
## Diagnostic (not in any suite): every preference switch of the target cue
## in a whole valley run, with the watch's own commitment state and the
## distances behind it, to see why IntegratedSim's tracker calls some of
## them "closing" (5% closer than 2 s before).
##   tools/gd.sh gl_diag --headless res://tests/runner.tscn -- --dir=res://tests/shots --suite=gameloop_target_diag --tdiag_seed=101 --tdiag_minutes=12

const LiveSky := preload("res://tests/shots/gameloop_live_sky.gd")


class DiagWatch extends ThreatWatch:
	var log: Array = []
	var hist: Array = []  # [now, target id, distance]

	func update(p: Bird, birds: Array[Bird], dt: float, rule: CatchRule, apply_highlights: bool = true) -> int:
		var old := target
		var was_committed := target_committed
		var old_best := _target_best_d
		var old_prog := _target_progress_at
		var old_d := _tg_d.duplicate()
		var m := super.update(p, birds, dt, rule, apply_highlights)
		var pp := p.get_body_position()
		if old != null and is_instance_valid(old):
			hist.append([_now, old.get_instance_id(), old.get_body_position().distance_to(pp)])
		while hist.size() > 0 and _now - float(hist[0][0]) > 3.0:
			hist.pop_front()
		if target != old and last_target_change == &"preference" and old != null and is_instance_valid(old):
			var d_now := old.get_body_position().distance_to(pp)
			var d2 := -1.0
			for h: Array in hist:
				if int(h[1]) == old.get_instance_id() and _now - float(h[0]) <= 2.0:
					d2 = float(h[2])
					break
			var far := 0.0
			for x in old_d:
				far = maxf(far, x)
			log.append({"t": snappedf(_now, 0.01), "d_now": snappedf(d_now, 0.01), "d_2s": snappedf(d2, 0.01),
				"tracker_closing": d2 > 0.0 and d_now < d2 * 0.95, "was_committed": was_committed,
				"best": snappedf(old_best, 0.01), "since_progress": snappedf(_now - old_prog, 0.01),
				"window": snappedf(target_commit_s * sqrt(maxf(body_time, 1.0)), 0.01), "far": snappedf(far, 0.01),
				"samples": old_d.size(), "held": snappedf(_target_held, 0.01)})
		return m


func test_target_diag() -> void:
	var args := Paths.user_args()
	var seed_ := int(args.get("tdiag_seed", "101"))
	var minutes := float(args.get("tdiag_minutes", "12"))
	var sim := IntegratedSim.new()
	sim.sky_factory = func() -> Node:
		var sky: Node = LiveSky.new()
		sky.set(&"world_kind", &"valley")
		return sky
	var watches: Array = []
	sim.configure = func(s: IntegratedSim) -> void:
		var w := DiagWatch.new()
		s.loop.watch = w
		watches.append(w)
		if args.has("tdiag_cone"):
			s.loop.rule.npc_cone_on_player_deg = float(args["tdiag_cone"])
	add_child(sim)
	await get_tree().process_frame
	var r: Dictionary = await sim.run(&"competent", seed_, minutes * 60.0)
	var w: DiagWatch = watches[-1]
	var n_close := 0
	for e: Dictionary in w.log:
		if e["tracker_closing"]:
			n_close += 1
			print("[gameloop] tdiag closing-pref ", e)
	print("[gameloop] tdiag seed %d: %d preference switches, %d the tracker calls closing; run target_cue %s" % [seed_, w.log.size(), n_close,
		{"preference": r["target_cue"]["preference"], "preference_closing": r["target_cue"]["preference_closing"]}])
	check(true, "measured")
	sim.queue_free()
	await get_tree().process_frame
