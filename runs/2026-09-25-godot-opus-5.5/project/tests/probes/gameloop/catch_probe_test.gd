extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (round 1) for G1: the catch rule under other seeds, other
## frame rates, faster motion, the player inside crowded scenes, long
## multi-frame soaks with per-catch audits, extreme stoops and same-frame
## player chains.

const Y := 20.0


## Brute-force reference (the documented rule, applied directly), including
## the player (index `pl`, or -1) with its body-time reach.
func _reference_dead(p0: Array[Vector3], p1: Array[Vector3], masses: Array[float], heads: Array[Vector3],
		pl: int) -> Array[bool]:
	var rule := CatchRule.new()
	if pl >= 0:
		rule.player_time_scale = SizeRules.time_scale(masses[pl])
	var n := p0.size()
	var cands := []
	for i in n:
		for j in n:
			if i == j or masses[i] < masses[j] * SizeRules.EAT_RATIO:
				continue
			var is_p := i == pl
			var ri := SizeRules.body_radius_for_mass(masses[i])
			var rj := SizeRules.body_radius_for_mass(masses[j])
			var c := rule.contact_distance(ri, SizeRules.wingspan_for_mass(masses[i]), is_p, rj)
			var vd := (p1[i] - p0[i]).normalized() if p1[i] != p0[i] else Vector3.ZERO
			var t := rule.contact_time(p0[i], p1[i], p0[j], p1[j], c, (ri + rj) * rule.overlap_fraction, heads[i], vd, is_p)
			if t >= 0.0:
				cands.append([t, -masses[i], -masses[j], p1[i].x, p1[i].z, p1[j].x, p1[j].z, i, j])
	cands.sort_custom(func(a: Array, b: Array) -> bool:
		for k in 7:
			if a[k] != b[k]:
				return a[k] < b[k]
		return a[7] < b[7])
	var dead: Array[bool] = []
	dead.resize(n)
	dead.fill(false)
	var ate := {}
	for c: Array in cands:
		if dead[c[7]] or dead[c[8]] or ate.has(c[7]):
			continue
		dead[c[8]] = true
		ate[c[7]] = true
	return dead


func test_reference_other_seeds_rates_and_player() -> void:
	var report := {}
	var total_mismatch := 0
	var total_catches := 0
	var player_catches := 0
	for cfg in [[5, 1.0 / 90.0, 0.6, false], [17, 1.0 / 72.0, 1.5, true], [2026, 1.0 / 30.0, 2.0, true],
			[31337, 0.1, 3.5, true], [8, 1.0 / 72.0, 0.4, true]]:
		var seed_: int = cfg[0]
		var dt: float = cfg[1]
		var max_move: float = cfg[2]
		var with_player: bool = cfg[3]
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_
		var mism := 0
		var catches := 0
		for kind in [GameLoop.BroadPhase.SWEEP, GameLoop.BroadPhase.HASH]:
			for trial in 20:
				make_loop(with_player)
				loop.broad_phase = kind
				var n := rng.randi_range(30, 60)
				var p0: Array[Vector3] = []
				var p1: Array[Vector3] = []
				var masses: Array[float] = []
				var heads: Array[Vector3] = []
				var pl := 0 if with_player else -1
				for i in n:
					var m := exp(rng.randf_range(log(0.004), log(4.5)))
					if i == pl:
						m = exp(rng.randf_range(log(0.03), log(4.5)))
					var h := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1)).normalized()
					var a := Vector3(rng.randf_range(-4, 4), Y + rng.randf_range(-2, 2), rng.randf_range(-4, 4))
					# Occasionally exact ratio boundaries.
					if i > 1 and rng.randf() < 0.15:
						m = masses[i - 1] * SizeRules.EAT_RATIO
					p0.append(a)
					p1.append(a + h * rng.randf_range(0.0, max_move))
					masses.append(m)
					heads.append(h)
					make_bird(m, a, h, i == pl)
				if with_player:
					birds[0].mass = masses[0]
					loop.set_protection(birds[0], 0.0)
				loop.npc_catches_outside_run = false
				var was_phase := loop.phase
				loop.phase = GameLoop.Phase.IDLE
				loop.step(dt)  # remember p0 without resolving
				loop.phase = was_phase
				loop.npc_catches_outside_run = true
				loop.since_catch = 0.0
				for i in n:
					birds[i].global_position = p1[i]
					birds[i].velocity = (p1[i] - p0[i]) / dt
				loop.step(dt)
				var expect := _reference_dead(p0, p1, masses, heads, pl)
				for i in n:
					if (not birds[i].alive) != expect[i]:
						mism += 1
					if expect[i]:
						catches += 1
				if with_player:
					for i in range(1, n):
						if expect[i] and not birds[i].alive:
							pass
				await cleanup()
		report[str(seed_)] = {"dt": dt, "mismatches": mism, "catches": catches}
		total_mismatch += mism
		total_catches += catches
	metric("reference", report)
	gt(float(total_catches), 200.0, "the scenes produce plenty of catches")
	eq(total_mismatch, 0, "loop == brute-force reference (incl. the player, 5 seeds, 90/72/30/10 Hz, both broad phases)")


## Many frames of a dense, fast flock: audit every catch against the rules.
func test_soak_audit_every_catch() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	make_loop(true)
	var dt := 1.0 / 72.0
	var p := make_bird(0.03, Vector3(0, Y, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	for i in 59:
		var m := exp(rng.randf_range(log(0.004), log(4.5)))
		make_bird(m, Vector3(rng.randf_range(-5, 5), Y + rng.randf_range(-2, 2), rng.randf_range(-5, 5)),
				Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 0.2), rng.randf_range(-1, 1)))
	var caught_log: Array = []
	var cb := func(pred: Bird, prey: Bird) -> void: caught_log.append([pred, prey])
	Events.bird_caught.connect(cb)
	var problems: Array[String] = []
	var eaten_ids := {}
	var last_catch_t := {}
	var total := 0
	var clock := 0.0
	for f in 3000:
		# Snapshot masses/alive before the step (the rule's inputs).
		var pre_mass := {}
		var pre_alive := {}
		var pre_pos := {}
		for b in birds:
			pre_mass[b] = b.mass
			pre_alive[b] = b.alive
			pre_pos[b] = b.get_body_position()
		caught_log.clear()
		for b in birds:
			if b.alive and b != p:
				# Swirl around the centre so the flock stays dense.
				var to_c := (Vector3(0, Y, 0) - b.global_position)
				var want := b.heading.rotated(Vector3.UP, rng.randf_range(-0.3, 0.3)) + to_c * 0.4
				b.fly(want, b.cruise_speed() * rng.randf_range(0.9, 1.3), dt)
		if p.alive:
			p.fly(p.heading.rotated(Vector3.UP, 0.02) + (Vector3(0, Y, 0) - p.global_position) * 0.02, p.cruise_speed(), dt)
		loop.step(dt)
		clock += dt
		var preds_this_frame := {}
		for e: Array in caught_log:
			var pred: Bird = e[0]
			var prey: Bird = e[1]
			total += 1
			if not bool(pre_alive[pred]) or not bool(pre_alive[prey]):
				problems.append("f%d: dead bird involved" % f)
			if float(pre_mass[pred]) < float(pre_mass[prey]) * SizeRules.EAT_RATIO - 1e-12:
				problems.append("f%d: ratio %.3f < 1.25" % [f, float(pre_mass[pred]) / float(pre_mass[prey])])
			if eaten_ids.has(prey) and prey != p:
				problems.append("f%d: %s eaten twice" % [f, prey.name])
			eaten_ids[prey] = true
			if preds_this_frame.has(pred):
				problems.append("f%d: %s ate twice in a frame" % [f, pred.name])
			preds_this_frame[pred] = true
			if eaten_ids.has(pred) and pred != p:
				problems.append("f%d: %s ate after being eaten" % [f, pred.name])
			if last_catch_t.has(pred) and not pred.is_player() and clock - float(last_catch_t[pred]) < loop.rule.npc_handling_s - 1e-6:
				problems.append("f%d: %s ate within its handling time" % [f, pred.name])
			last_catch_t[pred] = clock
			# Geometric sanity: they were within contact + both displacements.
			var c := loop.rule.contact_distance(SizeRules.body_radius_for_mass(pre_mass[pred]),
					SizeRules.wingspan_for_mass(pre_mass[pred]), pred.is_player(), SizeRules.body_radius_for_mass(pre_mass[prey]))
			var d0: float = (pre_pos[pred] as Vector3).distance_to(pre_pos[prey])
			var d1: float = pred.get_body_position().distance_to(prey.get_body_position())
			if minf(d0, d1) > c * 2.0 + 1.0 and d0 > c and d1 > c:
				# Swept contacts may be between endpoints; flag only absurd gaps.
				var disp: float = (pre_pos[pred] as Vector3).distance_to(pred.get_body_position()) + (pre_pos[prey] as Vector3).distance_to(prey.get_body_position())
				if minf(d0, d1) > c + disp + 1e-3:
					problems.append("f%d: catch at a distance %.2f > contact %.2f + motion %.2f" % [f, minf(d0, d1), c, disp])
		# Keep the population up: eaten birds come back elsewhere in the cloud
		# (announced as teleports), as the Ecosystem's pooling would.
		for b in birds:
			if not b.alive and b != p and rng.randf() < 0.05:
				b.alive = true
				b.global_position = Vector3(rng.randf_range(-5, 5), Y + rng.randf_range(-2, 2), rng.randf_range(-5, 5))
				loop.teleported(b)
				eaten_ids.erase(b)
	Events.bird_caught.disconnect(cb)
	metric("catches_audited", total)
	metric("problems", problems.slice(0, 10))
	gt(float(total), 150.0, "the soak produced plenty of catches")
	eq(problems.size(), 0, "every catch obeyed ratio, liveness, once-only, one-per-frame, handling and distance")


func test_extreme_stoop_no_tunnelling() -> void:
	# Eagle stooping at 60 m/s crosses a sparrow flying 12 m/s across its path.
	for cfg in [[1.0 / 72.0, 0.0, true], [0.1, 0.0, true], [1.0 / 72.0, 1.3, false], [0.1, 1.3, false]]:
		make_loop()
		var dt: float = cfg[0]
		var off_mult: float = cfg[1]
		var eagle := make_bird(3.0, Vector3.ZERO, Vector3(0, -0.6, -0.8))
		var sparrow := make_bird(0.03, Vector3.ZERO, Vector3.RIGHT)
		var c := loop.rule.contact_distance(eagle.get_body_radius(), eagle.get_wingspan(), false, sparrow.get_body_radius())
		var ev := Vector3(0, -0.6, -0.8) * 60.0
		var sv := Vector3(12, 0, 0)
		# Paths meet at the origin at t = 1 s (plus a lateral offset for misses).
		var meet := Vector3(0, Y, 0)
		# Offset perpendicular to the relative velocity: closest approach = off.
		var off := (ev - sv).cross(Vector3.UP).normalized() * c * off_mult
		var steps := int(round(2.0 / dt))
		var caught_at := -1.0
		for s in steps + 1:
			var t := s * dt
			eagle.global_position = meet + off + ev * (t - 1.0)
			eagle.velocity = ev
			sparrow.global_position = meet + sv * (t - 1.0)
			sparrow.velocity = sv
			loop.step(dt)
			if not sparrow.alive and caught_at < 0.0:
				caught_at = t
		eq(not sparrow.alive, cfg[2], "60 m/s stoop at %.0f Hz, miss offset %.1f x contact: caught=%s" % [1.0 / dt, off_mult, cfg[2]])
		if cfg[2]:
			between(caught_at, 1.0 - 2.0 * dt, 1.0 + 2.0 * dt, "caught at the crossing, not before/after")
		await cleanup()


func test_same_frame_player_chain() -> void:
	# The player eats a wren early in the frame and a hawk reaches the player
	# later in the same frame, and the reverse. Deterministic, physical order.
	# Player: z 0 -> -1.5 (contact 0.544 with the wren); hawk: z h0 -> h0-3
	# (contact 0.694 with the player).
	for hawk_first in [false, true]:
		make_loop()
		start_logging()
		var dt := 0.1
		var p := make_bird(0.03, Vector3(0, Y, 0), Vector3.FORWARD, true)
		loop.start_run()
		loop.set_protection(p, 0.0)
		var pc := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.012))
		var t_player := 0.8 if hawk_first else 0.2
		var t_hawk := 0.2 if hawk_first else 0.8
		var wz := -(1.5 * t_player + pc)
		var wren := make_bird(0.012, Vector3(0, Y, wz), Vector3.FORWARD)
		var hawk := make_bird(1.3, Vector3(0, Y, 50), Vector3.FORWARD)
		var hc := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius())
		var h0 := hc + 1.5 * t_hawk
		hawk.global_position = Vector3(0, Y, h0)
		p.global_position = Vector3(0, Y, 0)
		loop.teleported(p)
		loop.teleported(hawk)
		loop.step(1e-4)  # remember the starts; nobody in contact yet
		check(p.alive and wren.alive and hawk.alive and count("caught") == 0, "setup: no contact at the start")
		p.global_position = Vector3(0, Y, -1.5)
		p.velocity = Vector3(0, 0, -15)
		hawk.global_position = Vector3(0, Y, h0 - 3.0)
		hawk.velocity = Vector3(0, 0, -30)
		loop.step(dt)
		var caught := count("player_caught")
		metric("hawk_first_%s" % hawk_first, {"player_caught": caught, "wren_eaten": not wren.alive,
				"phase": loop.phase, "catches": loop.stats.catches})
		eq(caught, 1, "hawk_first=%s: the hawk catches the player in that frame" % hawk_first)
		if hawk_first:
			check(wren.alive, "hawk first: the player never gets to eat the wren")
		else:
			check(not wren.alive, "player first: the wren is eaten, then the player is caught")
		await cleanup()
