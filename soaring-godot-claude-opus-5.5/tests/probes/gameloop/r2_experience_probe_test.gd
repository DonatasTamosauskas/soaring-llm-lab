extends "res://tests/unit/game/game_fixture.gd"
## Verifier round 2 (experience & requirements auditor) probes for gameloop.
##
##   tools/gd.sh gameloop_verify --headless res://tests/runner.tscn -- \
##       --dir=res://tests/probes/gameloop --suite=r2_experience
##
## Each test pins a claim from the brief the way a player would meet it:
##  * G6 "cheap (< 0.3 ms for 60 birds)" in the world the game SHIPS with
##    (the valley has ~300 refuges; the area's cost tests run with none);
##  * G1 "prey inside the predator's FORWARD aim cone" at full catch assist;
##  * G1/G3 edge cases a player hits: a same-frame eat-and-be-eaten, a pause
##    straight after the caught beat, a restart while protected.

const DT := 1.0 / 72.0
const WorldScene := preload("res://scenes/world/world.tscn")


## The valley's real refuge list (SoaringWorld), or [] if it cannot be built.
func _valley_refuges() -> Array[Dictionary]:
	var w := WorldScene.instantiate() as World
	if "with_environment" in w:
		w.set(&"with_environment", false)
	if "with_decoration" in w:
		w.set(&"with_decoration", false)
	add_child(w)
	var out: Array[Dictionary] = w.get_refuges().duplicate()
	remove_child(w)
	w.free()
	return out


## Median / p95 of loop.perf["watch"] over n steps, birds drifting.
func _watch_cost(n: int, movers: Array[SimBird]) -> Dictionary:
	var times: Array[float] = []
	for s in n:
		for b in movers:
			b.global_position += b.velocity * DT
		loop.step(DT)
		times.append(float(loop.perf["watch"]))
	times.sort()
	return {"median": times[n / 2], "p95": times[int(n * 0.95)], "max": times[n - 1]}


## A pigeon-sized player with a murmuration of 30 starlings (its prey, the
## AI's signature flock) inside its target range ahead, and 29 other birds
## (predators and dust) around: 60 birds. Measured with no refuges (the area's
## setting) and with the valley's real refuge list.
func test_watch_cost_with_the_valleys_refuges() -> void:
	var refuges := _valley_refuges()
	check(refuges.size() > 50, "(setup) the valley has many refuges (got %d)" % refuges.size())
	var spans := {}
	for r in refuges:
		var k := "<0.3" if float(r["max_span"]) < 0.3 else ("<0.7" if float(r["max_span"]) < 0.7 else ("<1.4" if float(r["max_span"]) < 1.4 else ">=1.4"))
		spans[k] = int(spans.get(k, 0)) + 1
	metric("valley_refuges", {"count": refuges.size(), "max_span_buckets": spans})
	make_loop()
	var p := make_bird(0.35, Vector3(0, 60, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.35
	loop.set_protection(p, 600.0)
	p.velocity = Vector3.FORWARD * 12.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var movers: Array[SimBird] = [p]
	for i in 30:
		var pos := p.global_position + Vector3(rng.randf_range(-12, 12), rng.randf_range(-6, 6), -rng.randf_range(10, 40))
		var b := make_bird(0.1, pos, Vector3.FORWARD, false, true)
		b.velocity = Vector3.FORWARD * 11.0
		loop.set_protection(b, 600.0)
		movers.append(b)
	for i in 29:
		var m := exp(rng.randf_range(log(0.004), log(4.5)))
		var pos := p.global_position + Vector3(rng.randf_range(-80, 80), rng.randf_range(-20, 20), rng.randf_range(-80, 80))
		var b := make_bird(m, pos, Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), false, true)
		b.velocity = b.heading * 9.0
		loop.set_protection(b, 600.0)
		movers.append(b)
	# Warm up, then measure without refuges (the area's cost tests) ...
	_watch_cost(30, movers)
	loop.watch.refuges = []
	loop._refuges = []
	var none := _watch_cost(300, movers)
	# ... and with the valley's refuges (what the game runs with).
	var typed: Array[Dictionary] = refuges
	loop.watch.refuges = typed
	loop._refuges = typed
	var with := _watch_cost(300, movers)
	metric("watch_us_no_refuges", none)
	metric("watch_us_valley_refuges", with)
	print("[gameloop-verify] watch cost 60 birds (pigeon + 30-starling murmuration): no refuges %s | valley refuges (%d) %s" % [
		str(none), refuges.size(), str(with)])
	lt(float(none["median"]), 300.0, "G6 watch < 0.3 ms median without refuges")
	lt(float(with["median"]), 300.0, "G6 watch < 0.3 ms median with the valley's refuges")
	lt(float(with["p95"]), 300.0, "G6 watch < 0.3 ms p95 with the valley's refuges")


## G1: "prey inside the predator's forward aim cone" (+ VR forgiveness). At
## full catch assist the player's cone half-angle is 80 + 15 = 95 degrees:
## prey BEHIND the player's wing line is caught.
func test_full_catch_assist_keeps_the_cone_forward() -> void:
	var caught_at := {}
	for assist in [0.0, 1.0]:
		for ang in [75.0, 85.0, 92.0, 94.0]:
			make_loop()
			loop.assist_override = assist
			var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
			loop.start_run()
			loop.set_protection(p, 0.0)
			p.velocity = Vector3.FORWARD * 9.0
			loop.step(DT)
			var reach := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true,
					SizeRules.body_radius_for_mass(0.012))
			var a := deg_to_rad(ang)
			# In the horizontal plane, `ang` degrees off the heading (-Z), at
			# 70% of the contact distance, both birds still.
			var pos := p.global_position + Vector3(sin(a), 0.0, -cos(a)) * reach * 0.7
			var q := make_bird(0.012, pos, Vector3.RIGHT)
			q.velocity = Vector3.ZERO
			p.velocity = Vector3.FORWARD * 0.0001
			loop.step(DT)
			caught_at["assist %.0f @ %.0f deg" % [assist, ang]] = not q.alive
			await cleanup()
	metric("caught_by_angle", caught_at)
	print("[gameloop-verify] player catch by angle off heading: ", caught_at)
	check(bool(caught_at["assist 0 @ 75 deg"]), "(control) 75 deg off-axis is inside the 80 deg forgiveness cone")
	check(not bool(caught_at["assist 1 @ 92 deg"]), "full assist must not catch prey behind the wing line (92 deg)")
	check(not bool(caught_at["assist 1 @ 94 deg"]), "full assist must not catch prey behind the wing line (94 deg)")


## Same frame: the player eats a swallow while a starling that could eat it
## at the START of the frame strikes it later in the same frame, after the
## meal has made the player heavier than the starling. The start-of-frame
## snapshot rule then lets a lighter bird eat a heavier one. Recorded as a
## metric (documented behaviour), not asserted.
func test_eat_and_be_eaten_in_one_frame() -> void:
	make_loop()
	var p := make_bird(0.075, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.075
	loop.set_protection(p, 0.0)
	var o := p.global_position
	var q := make_bird(0.055, o + Vector3(0, 0, -5), Vector3.FORWARD)
	var h := make_bird(0.1, o + Vector3(0, 0, 5), Vector3.FORWARD)
	h.target = p
	loop.step(DT)
	var cp := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, q.get_body_radius(), false)
	var ch := loop.rule.contact_distance(h.get_body_radius(), h.get_wingspan(), false, p.get_body_radius(), true)
	# Start of the frame: prey 0.02 m beyond the player's reach, hunter 0.05 m
	# beyond its strike reach behind the player.
	q.global_position = o + Vector3(0, 0, -(cp + 0.02))
	h.global_position = o + Vector3(0, 0, ch + 0.05)
	loop.teleported(q)
	loop.teleported(h)
	loop.step(DT)
	check(q.alive and p.alive, "(setup) nothing in contact yet")
	# During the frame: the player moves 0.04 forward (reaches the prey at
	# t = 0.5), the hunter 0.12 forward (reaches the player at t = 0.625).
	p.global_position += Vector3(0, 0, -0.04)
	q.velocity = Vector3.ZERO
	h.global_position += Vector3(0, 0, -0.12)
	loop.step(DT)
	metric("same_frame", {"prey_eaten": not q.alive, "player_alive": p.alive, "player_mass_after": p.mass,
		"hunter_mass": h.mass, "state": Game.state_name()})
	print("[gameloop-verify] eat-and-be-eaten: prey eaten %s, player alive %s, player %.3f kg vs hunter %.3f kg" % [
		not q.alive, p.alive, p.mass, h.mass])
	check(true, "recorded")


## G3: restart while protected / mid-respite: nothing carries over.
func test_restart_clears_protection_respite_and_assists() -> void:
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	# Die once (danger assist, respite), then restart immediately.
	var h := make_bird(0.1, p.get_body_position() + Vector3(0, 0, 0.12), Vector3.FORWARD)
	h.target = p
	loop.set_protection(p, 0.0)
	loop.step(DT)
	check(not p.alive, "(setup) caught")
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 3, DT)
	h.global_position = Vector3(0, -500, 0)
	gt(loop.respite_left(), 1.0, "(setup) a respite after the respawn")
	gt(loop.danger_assist, 0.2, "(setup) danger assist after a death")
	loop.since_catch = 500.0
	loop.restart_run()
	loop.step(DT)
	near(loop.respite_left(), 0.0, 1e-6, "restart: no respite left over")
	near(loop.danger_assist, 0.0, 1e-3, "restart: danger assist cleared")
	near(loop.catch_assist(), 0.0, 1e-6, "restart: catch assist cleared")
	near(loop.protection_left(p), GameLoop.START_PROTECT_S - DT, 0.05, "restart: only the start protection")
	eq(loop.lives, GameLoop.MAX_LIVES, "restart: full lives")
	eq(bool(p.get_meta(&"npc_ignore", false)), true, "restart: protected player is ignored by NPCs (start protection)")
	run_steps(int(GameLoop.START_PROTECT_S / DT) + 5, DT)
	eq(bool(p.get_meta(&"npc_ignore", false)), false, "after start protection: NPCs may hunt the player again")


## G1 brute-force reference with the CURRENT documented rule (NPC strikes on
## the player: 0.15-span reach, 40-degree cone, no overlap catch), on seeds
## round 1 never used, every scene with the player in it.
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
			var q_p := j == pl
			var ri := SizeRules.body_radius_for_mass(masses[i])
			var rj := SizeRules.body_radius_for_mass(masses[j])
			var c := rule.contact_distance(ri, SizeRules.wingspan_for_mass(masses[i]), is_p, rj, q_p)
			var vd := (p1[i] - p0[i]).normalized() if p1[i] != p0[i] else Vector3.ZERO
			var t := rule.contact_time(p0[i], p1[i], p0[j], p1[j], c, (ri + rj) * rule.overlap_fraction, heads[i], vd, is_p, q_p)
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


func test_reference_with_the_player_as_prey_rule() -> void:
	var total_mismatch := 0
	var total_catches := 0
	var player_deaths := 0
	var report := {}
	for cfg in [[99, 1.0 / 72.0, 1.2], [4242, 1.0 / 90.0, 0.8], [777, 1.0 / 30.0, 2.5], [123456, 1.0 / 72.0, 0.3]]:
		var rng := RandomNumberGenerator.new()
		rng.seed = cfg[0]
		var dt: float = cfg[1]
		var max_move: float = cfg[2]
		var mism := 0
		var catches := 0
		for kind in [GameLoop.BroadPhase.SWEEP, GameLoop.BroadPhase.HASH]:
			for trial in 25:
				make_loop(true)
				loop.broad_phase = kind
				var n := rng.randi_range(30, 60)
				var p0: Array[Vector3] = []
				var p1: Array[Vector3] = []
				var masses: Array[float] = []
				var heads: Array[Vector3] = []
				for i in n:
					var m := exp(rng.randf_range(log(0.004), log(4.5)))
					if i == 0:
						m = exp(rng.randf_range(log(0.03), log(1.0)))  # a player with plenty above it
					var h := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.5, 0.5), rng.randf_range(-1, 1)).normalized()
					var a := Vector3(rng.randf_range(-3, 3), 20.0 + rng.randf_range(-1.5, 1.5), rng.randf_range(-3, 3))
					p0.append(a)
					p1.append(a + h * rng.randf_range(0.0, max_move))
					masses.append(m)
					heads.append(h)
					make_bird(m, a, h, i == 0)
				birds[0].mass = masses[0]
				loop.set_protection(birds[0], 0.0)
				loop.npc_catches_outside_run = false
				var was_phase := loop.phase
				loop.phase = GameLoop.Phase.IDLE
				loop.step(dt)
				loop.phase = was_phase
				loop.npc_catches_outside_run = true
				loop.since_catch = 0.0
				for i in n:
					birds[i].global_position = p1[i]
					birds[i].velocity = (p1[i] - p0[i]) / dt
				loop.step(dt)
				var expect := _reference_dead(p0, p1, masses, heads, 0)
				for i in n:
					if (not birds[i].alive) != expect[i]:
						mism += 1
					if expect[i]:
						catches += 1
				if expect[0]:
					player_deaths += 1
				await cleanup()
		report[str(cfg[0])] = {"mismatches": mism, "catches": catches}
		total_mismatch += mism
		total_catches += catches
	metric("reference_player_as_prey", report)
	metric("reference_player_deaths", player_deaths)
	gt(float(total_catches), 200.0, "the scenes produce plenty of catches")
	gt(float(player_deaths), 5.0, "the player is caught in some scenes (the rule on the player is exercised)")
	eq(total_mismatch, 0, "loop == brute-force reference with the player-as-prey rule (4 new seeds, both broad phases)")
