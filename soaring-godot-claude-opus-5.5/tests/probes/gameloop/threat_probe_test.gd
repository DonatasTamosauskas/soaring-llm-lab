extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (round 1) for G6/G5: worst-case cost with every bird a
## threat and every bird alive, flicker at the range boundaries, a
## predator vanishing mid-approach, TTC in a tail chase, a predator whose
## heading swings during the approach.

const DT := 1.0 / 72.0


func _player(mass: float) -> SimBird:
	make_loop()
	var p := make_bird(mass, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = mass
	p.global_position = Vector3(0, 30, 0)
	loop.teleported(p)
	loop.set_protection(p, 1e6)
	loop.step(DT)
	return p


static func _pct(xs: Array[float], q: float) -> float:
	var s := xs.duplicate()
	s.sort()
	return s[clampi(int(q * (s.size() - 1)), 0, s.size() - 1)]


func test_watch_cost_worst_case_all_threats_moving() -> void:
	# Sparrow player; 59 bigger birds (all threats, all highlighted) circling
	# within 25 m and closing: every bird takes the full TTC path each frame.
	var p := _player(0.03)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var others: Array[SimBird] = []
	for i in 59:
		var m := exp(rng.randf_range(log(0.05), log(4.5)))
		var pos := Vector3(rng.randf_range(-25, 25), 30 + rng.randf_range(-5, 5), rng.randf_range(-25, 25))
		var b := make_bird(m, pos, (Vector3(0, 30, 0) - pos), false, true)
		others.append(b)
	var times: Array[float] = []
	var totals: Array[float] = []
	for s in 400:
		for b in others:
			var to := Vector3(0, 30, 0) - b.global_position
			b.fly(to.normalized().rotated(Vector3.UP, 1.2), b.cruise_speed(), DT)
			if b.global_position.distance_to(Vector3(0, 30, 0)) < 3.0:
				b.global_position = Vector3(rng.randf_range(-25, 25), 30, rng.randf_range(-25, 25))
				loop.teleported(b)
		loop.step(DT)
		if s >= 20:
			times.append(float(loop.perf["watch"]))
			totals.append(float(loop.perf["total"]))
	var med := _pct(times, 0.5)
	var p95 := _pct(times, 0.95)
	metric("watch_us", {"median": med, "p95": p95, "max": _pct(times, 1.0)})
	metric("step_total_us", {"median": _pct(totals, 0.5), "p95": _pct(totals, 0.95)})
	var hl2 := 0
	for b in others:
		if b.model.highlight == 2:
			hl2 += 1
	metric("danger_highlights", hl2)
	lt(med, 300.0, "worst case watch pass (59 moving threats) median < 0.3 ms")
	lt(p95, 300.0, "worst case watch pass p95 < 0.3 ms")


func test_catch_cost_all_alive_dense() -> void:
	# The area's own cost test lets flocks eat each other, so later frames run
	# with fewer live birds. Here eaten birds are revived every frame.
	make_loop()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 60:
		var centre := Vector3((i % 4) * 30.0, 20, 0) if i < 40 else Vector3(rng.randf_range(-200, 200), 20, rng.randf_range(-200, 200))
		var spread := 3.0 if i < 40 else 0.0
		make_bird(exp(rng.randf_range(log(0.004), log(4.5))),
				centre + Vector3(rng.randf_range(-spread, spread), rng.randf_range(-spread, spread), rng.randf_range(-spread, spread)),
				Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)))
	var starts: Array[Vector3] = []
	for b in birds:
		starts.append(b.global_position)
	var times: Array[float] = []
	var alive_counts: Array[float] = []
	for s in 300:
		for i in birds.size():
			var b := birds[i]
			if not b.alive:
				b.alive = true
				b.global_position = starts[i]
				loop.teleported(b)
			b.fly(b.heading.rotated(Vector3.UP, 0.05), b.cruise_speed(), DT)
			# Keep flocks tight: circle around their start.
			if b.global_position.distance_to(starts[i]) > 4.0 and i < 40:
				b.global_position = starts[i]
				loop.teleported(b)
		var n_alive := 0
		for b in birds:
			if b.alive:
				n_alive += 1
		alive_counts.append(n_alive)
		loop.step(DT)
		if s >= 10:
			times.append(float(loop.perf["catch"]))
	metric("catch_us_all_alive", {"median": _pct(times, 0.5), "p95": _pct(times, 0.95), "max": _pct(times, 1.0),
			"alive_median": _pct(alive_counts, 0.5)})
	lt(_pct(times, 0.5), 200.0, "catch pass with 60 live birds in tight flocks: median < 200 µs (the area's budget)")


func test_target_does_not_flicker_at_the_range_edge() -> void:
	var p := _player(0.1)  # starling
	var span := p.get_wingspan()
	var edge := loop.watch.target_range_spans * span
	start_logging()
	var prey := make_bird(0.03, Vector3(0, 30, -edge * 0.98), Vector3.FORWARD, false, true)
	var hl_changes := 0
	var last_hl := -1
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in int(6.0 / DT):
		# Drifts +-3% across the target range edge with tracking noise.
		var z := -edge * (1.0 + 0.03 * sin(i * DT * 6.0)) + rng.randf_range(-0.02, 0.02) * span
		prey.global_position = Vector3(0, 30, z)
		loop.step(DT)
		if prey.model.highlight != last_hl:
			hl_changes += 1
			last_hl = prey.model.highlight
	var tg := events("target")
	metric("target_events_at_edge", tg.size())
	lt(float(tg.size()), 2.5, "a prey hovering at the 45-span edge changes the target at most twice (in, maybe out)")
	# Highlight range edge (70 spans).
	var hedge := loop.watch.highlight_range_spans * span
	hl_changes = 0
	last_hl = prey.model.highlight
	for i in int(6.0 / DT):
		var z := -hedge * (1.0 + 0.03 * sin(i * DT * 6.0))
		prey.global_position = Vector3(0, 30, z)
		loop.step(DT)
		if prey.model.highlight != last_hl:
			hl_changes += 1
			last_hl = prey.model.highlight
	metric("highlight_changes_at_edge", hl_changes)
	lt(float(hl_changes), 2.5, "highlight at the 70-span edge does not flicker")


func test_predator_vanishes_mid_approach() -> void:
	var p := _player(0.03)
	var emitted: Array = []
	var cb := func(lv: float, pr: Bird) -> void: emitted.append([lv, pr])
	Events.threat_changed.connect(cb)
	var hawk := make_bird(1.3, Vector3(0, 30, -30), Vector3.BACK)
	hawk.velocity = Vector3(0, 0, 12)
	for i in int(1.6 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	var peak := loop.watch.level
	# The Ecosystem despawns it (tree exit -> Birds.unregister).
	birds.erase(hawk)
	hawk.queue_free()
	await get_tree().process_frame
	var null_with_level := 0
	for i in int(3.0 / DT):
		loop.step(DT)
	for e: Array in emitted:
		if e[1] == null and float(e[0]) > 0.0:
			null_with_level += 1
	Events.threat_changed.disconnect(cb)
	metric("peak_before_despawn", peak)
	metric("emissions_level_gt0_without_predator", null_with_level)
	gt(peak, 0.3, "setup: a real threat before the despawn")
	eq(float(emitted[-1][0]), 0.0, "the cue ends at exactly 0 after the predator vanished")
	eq(loop.watch.predator, null, "no stale predator reference")


func test_ttc_in_a_tail_chase() -> void:
	var p := _player(0.03)
	p.velocity = Vector3(0, 0, -9)
	var hawk := make_bird(1.3, Vector3(0, 30, 12), Vector3.FORWARD)
	hawk.velocity = Vector3(0, 0, -14)
	loop.step(DT)
	var c := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius())
	near(loop.watch.predator_ttc, (12.0 - c) / 5.0, 1e-3, "tail chase TTC = gap / closing speed (5 m/s)")
	# Two predators: the one that will arrive first is named.
	var fast := make_bird(1.3, Vector3(0, 30, -12), Vector3.BACK)
	fast.velocity = Vector3(0, 0, 10)  # head-on: closing 19 m/s -> ~0.6 s
	for i in 5:
		loop.step(DT)
	eq(loop.watch.predator, fast, "the predator with the shortest TTC is named")


func test_heading_swing_during_approach() -> void:
	# A hawk closing at 8 m/s whose heading swings +-40 deg at 1.5 Hz (a
	# pursuer correcting its line as the player jinks). The aim weight swings
	# with it; the reported level must not pulse.
	var p := _player(0.03)
	var hawk := make_bird(1.3, Vector3(0, 30, -30), Vector3.BACK)
	var levels: Array[float] = []
	var raws: Array[float] = []
	for i in int(3.2 / DT):
		var t := i * DT
		hawk.velocity = Vector3(0, 0, 8)
		hawk.global_position += hawk.velocity * DT
		hawk.set_heading(Vector3.BACK.rotated(Vector3.UP, deg_to_rad(40.0) * sin(TAU * 1.5 * t)))
		loop.step(DT)
		levels.append(loop.watch.level)
		raws.append(loop.watch.raw_level)
	var rev := _reversals(levels, 0.03)
	metric("reversals_reported", rev)
	metric("reversals_raw", _reversals(raws, 0.03))
	metric("level_end", levels[-1])
	lt(float(rev), 1.5, "a swinging pursuer's threat keeps rising without perceptible pulses")


static func _reversals(xs: Array[float], threshold: float) -> int:
	var n := 0
	var trend := 0
	var hi := xs[0]
	var lo := xs[0]
	for v in xs:
		if trend == 0:
			hi = maxf(hi, v)
			lo = minf(lo, v)
			if v - lo >= threshold:
				trend = 1
				hi = v
			elif hi - v >= threshold:
				trend = -1
				lo = v
		elif trend == 1:
			if v > hi:
				hi = v
			elif hi - v >= threshold:
				n += 1
				trend = -1
				lo = v
		else:
			if v < lo:
				lo = v
			elif v - lo >= threshold:
				n += 1
				trend = 1
				hi = v
	return n
