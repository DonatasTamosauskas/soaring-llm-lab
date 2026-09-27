extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (fix-round-4 review, experience & requirements lens).
## Adversarial checks of the gameloop claims, on the builder's own mocks
## (SimBird, the fixture) - no other area's code.
##   tools/gd.sh gameloop_verify --headless res://tests/runner.tscn -- \
##     --dir=res://tests/probes/gameloop --suite=r5exp_probes
## Report copied to artifacts/gameloop/verify/r5exp_report_probes.json.

const DT := 1.0 / 72.0


# ---------------------------------------------------------------------------
# G6: an attack behind a bird the cue is already SHOWING
# ---------------------------------------------------------------------------

## A bystander (not hunting the player) holds the name at a level the cue
## shows (>= QUIET_LEVEL); a hawk that IS hunting the player stoops in.
## Returns timing of the hawk's own level vs when the cue names it.
func _stoop_behind_bystander(bystander_closing: bool, stoop_speed: float) -> Dictionary:
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var crow := make_bird(0.5, Vector3(0, 30, 0), Vector3.RIGHT)
	crow.target = null  # hunting something else (intent x0.35)
	var cc := loop.rule.contact_distance(crow.get_body_radius(), crow.get_wingspan(), false, p.get_body_radius(), true)
	if bystander_closing:
		# Flying at the player (after a moth beside it), not hunting it.
		move(crow, Vector3(cc + 6.0, 30, 0), Vector3(-3.0, 0, 0))
		crow.set_heading(Vector3.LEFT)
	else:
		move(crow, Vector3(cc + 0.8 * crow.get_wingspan(), 30, 0), Vector3.ZERO)
	var hawk := make_bird(1.3, Vector3(0, 30, -60), Vector3.BACK)
	hawk.velocity = Vector3.ZERO
	run_steps(int(0.5 / DT), DT, func(_i: int) -> void:
		if bystander_closing:
			move(crow, Vector3(cc + 6.0, 30, 0), Vector3(-3.0, 0, 0)))
	var out := {"bystander_named": loop.watch.predator == crow, "bystander_level": loop.watch.level}
	var z := -60.0
	var hc := loop.rule.contact_distance(hawk.get_body_radius(), hawk.get_wingspan(), false, p.get_body_radius(), true)
	var reached := -1
	var named := -1
	var max_unnamed := 0.0
	var reported_while_unnamed := 0.0
	var ttc_at_named := INF
	var i := 0
	while -z - hc > 0.05 and i < int(8.0 / DT):
		z += stoop_speed * DT
		move(hawk, Vector3(0, 30, z), Vector3(0, 0, stoop_speed))
		if bystander_closing:
			move(crow, Vector3(cc + 6.0, 30, 0), Vector3(-3.0, 0, 0))
		loop.step(DT)
		var hl := loop.watch.level_of(hawk)
		if reached < 0 and hl >= loop.watch.announce_level:
			reached = i
		if loop.watch.predator == hawk:
			if named < 0:
				named = i
				ttc_at_named = (-z - hc) / stoop_speed
		elif reached >= 0:
			max_unnamed = maxf(max_unnamed, hl)
			reported_while_unnamed = maxf(reported_while_unnamed, loop.watch.level)
		i += 1
	out["reached_attack_frame"] = reached
	out["named_frame"] = named
	out["late_s"] = (named - reached) * DT if reached >= 0 and named >= 0 else INF
	out["hawk_level_while_unnamed_max"] = snappedf(max_unnamed, 0.001)
	out["reported_while_unnamed_max"] = snappedf(reported_while_unnamed, 0.001)
	out["ttc_left_when_named_s"] = snappedf(ttc_at_named, 0.001)
	out["horizon_s"] = loop.watch.ttc_horizon
	await cleanup()
	return out


func test_an_attack_is_not_announced_late_behind_a_shown_bystander() -> void:
	# The doc: "a rival at attack strength takes it at once from a quiet name:
	# ... an attack is never announced late". Here the bystander is NOT quiet
	# (it is shown, 0.1-0.35, as a non-hunting bird can be). Director's bar:
	# the attacker is named within 0.1 s of reaching attack strength, as it
	# is behind a quiet bystander.
	for case: Array in [[false, 14.0], [false, 30.0], [true, 14.0], [true, 30.0]]:
		var r: Dictionary = await _stoop_behind_bystander(case[0], case[1])
		var tag := "%s bystander, stoop %.0f m/s" % ["closing" if case[0] else "loitering", case[1]]
		metric("masked_%s_%d" % ["closing" if case[0] else "loiter", int(case[1])], r)
		check(bool(r["bystander_named"]), "(setup, %s) the bystander is named first" % tag)
		gt(float(r["bystander_level"]), ThreatWatch.QUIET_LEVEL, "(setup, %s) at a shown level" % tag)
		check(int(r["reached_attack_frame"]) >= 0, "(setup, %s) the hawk reaches attack strength" % tag)
		lt(float(r["late_s"]), 0.1, "%s: the hunting hawk is named within 0.1 s of reaching attack strength (hawk at up to %.2f while the cue reported %.2f about the bystander; %.2f s of time-to-contact left when named, horizon %.1f s)" % [
				tag, r["hawk_level_while_unnamed_max"], r["reported_while_unnamed_max"], r["ttc_left_when_named_s"], r["horizon_s"]])


func _second_hunter(a_ttc: float) -> Dictionary:
	# Hunter A holds a steady threat (held in place, pointed at the player,
	# with a closing velocity that gives a constant time-to-contact a_ttc:
	# the watch reads closing speed from velocities); hunter B stoops in from
	# behind at 16 m/s.
	make_loop()
	var p := make_bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 1e6)
	p.velocity = Vector3.ZERO
	var a := make_bird(1.3, Vector3(0, 30, -4.0), Vector3.BACK)
	var ac := loop.rule.contact_distance(a.get_body_radius(), a.get_wingspan(), false, p.get_body_radius(), true)
	var gap := 4.0 - ac
	var hold_a := func() -> void:
		move(a, Vector3(0, 30, -4.0), Vector3(0, 0, gap / a_ttc))
	run_steps(int(1.5 / DT), DT, func(_i: int) -> void: hold_a.call())
	var out := {"a_named": loop.watch.predator == a, "a_level": snappedf(loop.watch.level, 0.001)}
	var b := make_bird(1.3, Vector3(0, 30, 60), Vector3.FORWARD)
	var bc := loop.rule.contact_distance(b.get_body_radius(), b.get_wingspan(), false, p.get_body_radius(), true)
	var z := 60.0
	var named := -1
	var ttc_named := INF
	var max_b_unnamed := 0.0
	var i := 0
	while z - bc > 0.05 and i < int(8.0 / DT):
		hold_a.call()
		z -= 16.0 * DT
		move(b, Vector3(0, 30, z), Vector3(0, 0, -16.0))
		loop.step(DT)
		if loop.watch.predator == b and named < 0:
			named = i
			ttc_named = (z - bc) / 16.0
		elif named < 0:
			max_b_unnamed = maxf(max_b_unnamed, loop.watch.level_of(b))
		i += 1
	out["b_named"] = named >= 0
	out["ttc_left_when_b_named"] = snappedf(ttc_named, 0.001)
	out["b_level_max_while_unnamed"] = snappedf(max_b_unnamed, 0.001)
	await cleanup()
	return out


func test_a_second_hunter_from_behind_is_named_in_time() -> void:
	# Two hawks hunt a sparrow (the AI sends two or three at once): A holds a
	# steady threat (named); B stoops in from behind. Director's bar: B, the
	# one about to strike, is named with at least 1.0 s of time-to-contact
	# left (a person needs ~0.2 s to react and ~0.5 s to roll into an
	# evasive turn), and the arrow is on B, not A, for its last second.
	for a_ttc: float in [2.6, 1.75, 1.2]:
		var r: Dictionary = await _second_hunter(a_ttc)
		metric("second_hunter_a_ttc_%.2f" % a_ttc, r)
		var tag := "A at level %.2f" % r["a_level"]
		check(bool(r["a_named"]), "(setup, %s) hunter A is named" % tag)
		check(bool(r["b_named"]), "%s: the stooping hunter B is named before it strikes" % tag)
		gt(float(r["ttc_left_when_b_named"]), 1.0, "%s: B named with >= 1.0 s to contact (B reached %.2f unnamed)" % [
				tag, r["b_level_max_while_unnamed"]])


# ---------------------------------------------------------------------------
# G1: chains are deterministic whatever the registration order (fuzz)
# ---------------------------------------------------------------------------

func _scene(rng: RandomNumberGenerator, n: int, with_player: bool) -> Array:
	var out := []
	for k in n:
		var sp := rng.randi_range(1, SizeRules.SPECIES.size() - 1)
		var m := float(SizeRules.SPECIES[sp]["mass"]) * rng.randf_range(0.91, 1.09)
		var p0 := Vector3(rng.randf_range(-3, 3), 30.0 + rng.randf_range(-3, 3), rng.randf_range(-3, 3))
		var v := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized() \
				* rng.randf_range(4.0, 25.0)
		var h := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 0.2), rng.randf_range(-1, 1)).normalized()
		out.append({"m": m, "p0": p0, "v": v, "h": h, "player": with_player and k == 0})
	return out


## Plays one frame of the scene with birds registered in `order`; returns
## the catches as [pred label, prey label] in event order.
func _play(scene: Array, order: Array) -> Array:
	var log: Array = []
	var on_c := func(pred: Bird, prey: Bird) -> void:
		log.append([int(pred.get_meta(&"lbl")), int(prey.get_meta(&"lbl"))])
	var made: Array[SimBird] = []
	# The player (if any) first: Birds.player() must exist before start_run.
	var ord := order.duplicate()
	for k in scene.size():
		if scene[k]["player"]:
			ord.erase(k)
			ord.push_front(k)
	for k: int in ord:
		var d: Dictionary = scene[k]
		var b := make_bird(d["m"], d["p0"] + d["v"] * DT, d["h"], d["player"])
		b.set_meta(&"lbl", k)
		b.velocity = d["v"]
		b.target = null
		made.append(b)
	if Birds.player() != null:
		loop.start_run()
		loop.set_protection(Birds.player(), 0.0)
	for b in made:
		var d: Dictionary = scene[int(b.get_meta(&"lbl"))]
		# (start_run resets and respawns the player: put it back as described.)
		b.mass = d["m"]
		b.set_heading(d["h"])
		b.velocity = d["v"]
		var t = loop._track(b)
		t.prev = d["p0"]
		t.has_prev = true
		b.global_position = d["p0"] + d["v"] * DT
	Events.bird_caught.connect(on_c)
	loop.step(DT)
	Events.bird_caught.disconnect(on_c)
	for b in made:
		birds.erase(b)
		b.free()
	return log


func test_chains_are_deterministic_whatever_the_order_fuzz() -> void:
	make_loop()
	loop.npc_catches_outside_run = true
	var rng := RandomNumberGenerator.new()
	var scenes := 0
	var mismatches := 0
	var total_catches := 0
	var chains := 0
	var bad_invariants := 0
	var first_bad := ""
	for s in 160:
		rng.seed = 90210 + s
		var with_player := s % 3 == 0
		var scene := _scene(rng, 26, with_player)
		var fwd := range(scene.size())
		var rev := fwd.duplicate()
		rev.reverse()
		var shuf := fwd.duplicate()
		var r2 := RandomNumberGenerator.new()
		r2.seed = s
		for k in range(shuf.size() - 1, 0, -1):
			var j := r2.randi_range(0, k)
			var tmp: Variant = shuf[k]
			shuf[k] = shuf[j]
			shuf[j] = tmp
		var a := _play(scene, fwd)
		var b := _play(scene, rev)
		var c := _play(scene, shuf)
		scenes += 1
		total_catches += a.size()
		if JSON.stringify(a) != JSON.stringify(b) or JSON.stringify(a) != JSON.stringify(c):
			mismatches += 1
			if first_bad.is_empty():
				first_bad = "scene %d: %s | %s | %s" % [s, a, b, c]
		# Invariants: a bird is eaten at most once; a predator eats at most
		# once; a bird eaten earlier in the frame never eats later.
		var eaten := {}
		var ate := {}
		for e: Array in a:
			if eaten.has(e[1]) or ate.has(e[0]) or eaten.has(e[0]):
				bad_invariants += 1
			if ate.has(e[1]):
				chains += 1  # the prey had eaten earlier this frame: a chain
			eaten[e[1]] = true
			ate[e[0]] = true
	metric("chain_fuzz", {"scenes": scenes, "catches": total_catches, "chains_A_eats_B_then_C_eats_A": chains,
		"mismatches": mismatches, "bad_invariants": bad_invariants, "first_bad": first_bad})
	gt(float(total_catches), 100.0, "(setup) the scenes produce many catches")
	gt(float(chains), 0.0, "(setup) some scenes contain a chain (A eats B, then C eats A)")
	eq(mismatches, 0, "the same scene resolves identically in forward, reverse and shuffled registration orders")
	eq(bad_invariants, 0, "no double catch, no predator eating twice, no eaten bird eating later")


func _chain_scene(rng: RandomNumberGenerator, n_chains: int) -> Array:
	# Chains B <- A <- C along a line (each pointed at the one ahead, ratio
	# 1.3-1.6 each), closing at random speeds, so within one frame A may reach
	# B before or after C reaches A.
	var out := []
	for k in n_chains:
		var base := Vector3(k * 12.0, 30.0, 0.0)
		var mb := rng.randf_range(0.03, 0.15)
		var ma := mb * rng.randf_range(1.3, 1.6)
		var mc := ma * rng.randf_range(1.3, 1.6)
		var dir := Vector3(rng.randf_range(-0.3, 0.3), 0, -1).normalized()
		var vb := dir * rng.randf_range(3.0, 6.0)
		var va := dir * rng.randf_range(10.0, 30.0)
		var vc := dir * rng.randf_range(10.0, 30.0)
		var gap_ab := rng.randf_range(0.0, 0.2)
		var gap_ca := rng.randf_range(0.0, 0.2)
		var pb := base
		var pa := pb - dir * (SizeRules.body_radius_for_mass(ma) + SizeRules.body_radius_for_mass(mb) + 0.25 * SizeRules.wingspan_for_mass(ma) + gap_ab)
		var pc := pa - dir * (SizeRules.body_radius_for_mass(mc) + SizeRules.body_radius_for_mass(ma) + 0.25 * SizeRules.wingspan_for_mass(mc) + gap_ca)
		out.append({"m": mb, "p0": pb, "v": vb, "h": dir, "player": false})
		out.append({"m": ma, "p0": pa, "v": va, "h": dir, "player": false})
		out.append({"m": mc, "p0": pc, "v": vc, "h": dir, "player": false})
	return out


func test_structured_chains_are_deterministic() -> void:
	make_loop()
	var rng := RandomNumberGenerator.new()
	var mism := 0
	var chains := 0
	var a_blocked := 0
	var bad := 0
	for s in 60:
		rng.seed = 555 + s
		var scene := _chain_scene(rng, 8)
		var fwd := range(scene.size())
		var rev := fwd.duplicate()
		rev.reverse()
		var a := _play(scene, fwd)
		var b := _play(scene, rev)
		if JSON.stringify(a) != JSON.stringify(b):
			mism += 1
		var eaten := {}
		var ate := {}
		for e: Array in a:
			if eaten.has(e[1]) or ate.has(e[0]) or eaten.has(e[0]):
				bad += 1
			eaten[e[1]] = true
			ate[e[0]] = true
		for k in 8:
			var ib := 3 * k
			var ia := ib + 1
			var ic := ib + 2
			if eaten.has(ib) and eaten.has(ia):
				chains += 1
			elif eaten.has(ia) and not eaten.has(ib):
				a_blocked += 1
	metric("structured_chains", {"scenes": 60, "full_chains": chains, "A_eaten_before_it_ate": a_blocked,
		"order_mismatches": mism, "bad_invariants": bad})
	gt(float(chains), 20.0, "(setup) many full chains (A eats B, C eats A)")
	gt(float(a_blocked), 5.0, "(setup) and many where C gets A first")
	eq(mism, 0, "identical outcome in forward and reverse registration order")
	eq(bad, 0, "invariants hold")


# ---------------------------------------------------------------------------
# G1: handling time bounds a predator in a flock (no rampage)
# ---------------------------------------------------------------------------

func test_a_hawk_through_a_flock_eats_at_most_once_per_handling_time() -> void:
	make_loop()
	loop.npc_catches_outside_run = true
	var hawk := make_bird(1.3, Vector3(0, 30, 10), Vector3.FORWARD)
	var flock: Array[SimBird] = []
	for k in 40:
		flock.append(make_bird(0.1, Vector3(randf_range(-0.6, 0.6), 30 + randf_range(-0.6, 0.6), 8.0 - k * 0.45), Vector3.FORWARD))
	var n := [0]
	var times: Array[float] = []
	var t := [0.0]
	var on_c := func(pred: Bird, _prey: Bird) -> void:
		if pred == hawk:
			n[0] += 1
			times.append(t[0])
	Events.bird_caught.connect(on_c)
	var z := 10.0
	for i in int(3.0 / DT):
		t[0] += DT
		z -= 7.0 * DT
		move(hawk, Vector3(0, 30, z), Vector3(0, 0, -7.0))
		loop.step(DT)
	Events.bird_caught.disconnect(on_c)
	metric("flock_rampage", {"catches": n[0], "times": times})
	gt(float(n[0]), 1.0, "(setup) the hawk catches in the flock")
	lt(float(n[0]), 4.0, "at most 3 catches in 3 s (handling 1.2 s)")
	for k in range(1, times.size()):
		gt(times[k] - times[k - 1], loop.rule.npc_handling_s - 1e-3, "catches at least a handling time apart")


# ---------------------------------------------------------------------------
# G2: random meals and deaths: tier events exactly once, species follows mass
# ---------------------------------------------------------------------------

func test_growth_and_tier_events_fuzz() -> void:
	make_loop()
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	start_logging()
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var bad_species := 0
	var bad_tier_events := 0
	var bad_grew := 0
	var expected_tier_events := 0
	var meals := 0
	var deaths := 0
	var restarts := 0
	for step in 1500:
		if loop.phase != GameLoop.Phase.PLAYING:
			for k in int(3.0 / DT):
				loop.step(DT)
			if loop.phase == GameLoop.Phase.ENDED:
				loop.restart_run()
				restarts += 1
			continue
		var before_m := p.mass
		var before_t := SizeRules.tier_for_mass(before_m)
		var n_tier := count("tier")
		var n_grew := count("grew")
		var roll := rng.randf()
		if roll < 0.04:
			var hunter := make_bird(p.mass * 1.4, Vector3(0, 30, -1), Vector3.BACK)
			loop._commit_catch(hunter, p)
			deaths += 1
			birds.erase(hunter)
			hunter.free()
			continue
		var r := rng.randf_range(0.02, 0.79)
		var prey := make_bird(p.mass * r, Vector3(0, 30, -0.5), Vector3.FORWARD)
		loop.set_protection(prey, 0.0)
		var ok := loop._commit_catch(p, prey)
		birds.erase(prey)
		prey.free()
		if not ok:
			continue
		meals += 1
		var after_t := SizeRules.tier_for_mass(p.mass)
		if p.species != SizeRules.species_for_mass(p.mass):
			bad_species += 1
		var dt_ev := count("tier") - n_tier
		if after_t != before_t:
			expected_tier_events += 1
			if dt_ev != 1:
				bad_tier_events += 1
			else:
				var e: Array = events("tier")[-1]
				if e[1] != before_t or e[2] != after_t:
					bad_tier_events += 1
		elif dt_ev != 0:
			bad_tier_events += 1
		var dg := count("grew") - n_grew
		if dg != (1 if p.mass > before_m else 0):
			bad_grew += 1
	stop_logging()
	metric("growth_fuzz", {"meals": meals, "deaths": deaths, "restarts": restarts,
		"tier_changes_by_meals": expected_tier_events, "bad_tier_events": bad_tier_events,
		"bad_grew": bad_grew, "bad_species": bad_species})
	gt(float(meals), 800.0, "(setup) many meals")
	gt(float(expected_tier_events), 10.0, "(setup) many tier changes")
	eq(bad_tier_events, 0, "exactly one player_tier_changed(old, new) per tier change by a meal, none otherwise")
	eq(bad_grew, 0, "exactly one player_grew per growing meal")
	eq(bad_species, 0, "the species always follows the mass")


# ---------------------------------------------------------------------------
# G5: the loop moves up the ladder monotonically with size (fine sweep)
# ---------------------------------------------------------------------------

func test_the_menu_moves_up_monotonically() -> void:
	var prev_low_w := -1
	var prev_high_e := -1
	var prev_low_d := -1
	var non_mono := []
	var thin := []
	var m := GameLoop.START_MASS
	while m <= GameLoop.MAX_PLAYER_MASS * 1.0001:
		var low_w := -1
		var high_e := -1
		var low_d := -1
		var n_w := 0
		for i in SizeRules.SPECIES.size():
			var sm := float(SizeRules.SPECIES[i]["mass"])
			if SizeRules.is_worthwhile(m, sm):
				n_w += 1
				if low_w < 0:
					low_w = i
			if SizeRules.can_eat(m, sm):
				high_e = i
			if low_d < 0 and SizeRules.can_eat(sm, m):
				low_d = i
		if low_w < prev_low_w or high_e < prev_high_e or (low_d >= 0 and prev_low_d >= 0 and low_d < prev_low_d):
			non_mono.append(snappedf(m, 0.0001))
		if n_w < 2:
			thin.append([snappedf(m, 0.0001), n_w])
		prev_low_w = maxi(prev_low_w, low_w)
		prev_high_e = maxi(prev_high_e, high_e)
		if low_d >= 0:
			prev_low_d = maxi(prev_low_d, low_d)
		m *= 1.01
	metric("menu_sweep", {"non_monotone_at": non_mono, "fewer_than_2_worthwhile_species_at": thin.slice(0, 20),
		"n_thin": thin.size()})
	eq(non_mono.size(), 0, "the smallest worthwhile, largest edible and smallest dangerous species only move up with size")
	eq(thin.size(), 0, "at every size at least two ladder species are worth hunting")


# ---------------------------------------------------------------------------
# G6: cost in the worst plausible frames (60 birds)
# ---------------------------------------------------------------------------

func _median(a: Array) -> float:
	var s := a.duplicate()
	s.sort()
	return float(s[s.size() / 2]) if not s.is_empty() else 0.0


func _p95(a: Array) -> float:
	var s := a.duplicate()
	s.sort()
	return float(s[(s.size() * 95) / 100]) if not s.is_empty() else 0.0


func test_watch_cost_all_hunters_and_all_prey_with_sight_rays() -> void:
	# (a) 59 predators all hunting and closing on the player; (b) 59
	# worthwhile prey all in range with static geometry around (the target
	# cue casts sight rays). G6: < 0.3 ms for 60 birds.
	var walls: Array[StaticBody3D] = []
	for k in 12:
		var sb := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2, 8, 2)
		cs.shape = box
		sb.add_child(cs)
		sb.collision_layer = 1
		add_child(sb)
		sb.global_position = Vector3(cos(k * 0.52) * 9.0, 30, sin(k * 0.52) * 9.0)
		walls.append(sb)
	await get_tree().physics_frame
	var res := {}
	for mode in ["hunters", "prey"]:
		make_loop()
		var p := make_bird(0.3 if mode == "hunters" else 1.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
		loop.start_run()
		loop.set_protection(p, 1e6)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var others: Array[SimBird] = []
		for k in 59:
			var ang := rng.randf() * TAU
			var d := rng.randf_range(6.0, 30.0)
			var pos := Vector3(cos(ang) * d, 30 + rng.randf_range(-5, 5), sin(ang) * d)
			var m := rng.randf_range(0.5, 3.0) if mode == "hunters" else rng.randf_range(0.2, 0.9)
			var b := make_bird(m, pos, (Vector3(0, 30, 0) - pos).normalized())
			b.velocity = (Vector3(0, 30, 0) - pos).normalized() * 6.0
			others.append(b)
		var costs := []
		for i in 240:
			await get_tree().physics_frame
			for b in others:
				b.global_position += b.velocity * DT * 0.2
			loop.step(DT)
			costs.append(float(loop.perf.get("watch", 0)))
		res[mode] = {"median_us": _median(costs.slice(20)), "p95_us": _p95(costs.slice(20))}
		await cleanup()
	for sb in walls:
		sb.queue_free()
	metric("watch_cost_worst", res)
	lt(float(res["hunters"]["median_us"]), 300.0, "59 hunters closing: watch median < 0.3 ms")
	lt(float(res["prey"]["median_us"]), 300.0, "59 worthwhile prey in range with sight rays: watch median < 0.3 ms")


func test_catch_cost_in_a_mixed_cluster() -> void:
	# 60 birds of mixed species within a few metres (a hawk in a mixed flock
	# over a feeder): every pair is a broad-phase candidate.
	make_loop()
	loop.npc_catches_outside_run = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for k in 60:
		var sp := rng.randi_range(1, 8)
		var b := make_bird(float(SizeRules.SPECIES[sp]["mass"]), Vector3(rng.randf_range(-4, 4), 30 + rng.randf_range(-2, 2),
				rng.randf_range(-4, 4)), Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized())
		b.velocity = b.get_forward() * 8.0
	# A cone of ~0 and no overlap rule: every candidate pair runs the whole
	# swept test, and no catch removes birds, so every frame is the worst.
	loop.rule.npc_cone_deg = 0.01
	loop.rule.overlap_fraction = 0.0
	var costs := []
	var cands := []
	for i in 120:
		for b in birds:
			b.global_position += b.velocity * DT
		loop.step(DT)
		costs.append(float(loop.perf.get("catch", 0)))
		cands.append(int(loop.perf.get("pairs", 0)))
	metric("catch_cost_cluster", {"median_us": _median(costs.slice(10)), "p95_us": _p95(costs.slice(10)),
		"pairs": _median(cands)})
	lt(_median(costs.slice(10)), 1000.0, "the catch pass in a 60-bird mixed cluster stays under 1 ms (median)")


# ---------------------------------------------------------------------------
# G3: odd UI-driven sequences around the CAUGHT beat
# ---------------------------------------------------------------------------

func test_restart_from_pause_during_the_last_beat_cancels_the_run_end() -> void:
	make_loop()
	var p := make_bird(0.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	start_logging()
	loop.lives = 1
	var hunter := make_bird(1.3, Vector3(0, 30, -1), Vector3.BACK)
	loop._commit_catch(hunter, p)
	eq(Game.state, Game.State.CAUGHT, "(setup) caught on the last life")
	run_steps(int(1.0 / DT), DT)
	Game.set_state(Game.State.PAUSED)  # the UI's pause (menu button)
	run_steps(int(5.0 / DT), DT)
	eq(Game.state, Game.State.PAUSED, "a paused beat stays paused")
	eq(count("run_ended"), 0, "(paused) no run end while paused")
	loop.restart_run()  # "Restart run" from the pause screen
	get_tree().paused = false
	run_steps(int(6.0 / DT), DT)
	eq(count("run_ended"), 0, "restarting mid-beat cancels the pending run end")
	eq(Game.state, Game.State.PLAYING, "a fresh run is playing")
	eq(loop.lives, GameLoop.MAX_LIVES, "with full lives")
	check(p.alive, "the player is alive")
	near(p.mass, GameLoop.START_MASS, 1e-9, "and back to the start mass")
	stop_logging()


func test_ui_resume_into_caught_keeps_the_remaining_beat() -> void:
	# The UI resumes a pause taken during the beat with Game.set_state(CAUGHT)
	# (ui_root._resume_state). The beat must continue where it was: not
	# restart, not be skipped.
	make_loop()
	var p := make_bird(0.3, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	var hunter := make_bird(1.3, Vector3(0, 30, -1), Vector3.BACK)
	loop._commit_catch(hunter, p)
	run_steps(int(1.0 / DT), DT)
	var left := loop._beat_left
	Game.set_state(Game.State.PAUSED)
	run_steps(int(3.0 / DT), DT)
	Game.set_state(Game.State.CAUGHT)
	get_tree().paused = false
	near(loop._beat_left, left, 1e-6, "the remaining beat is unchanged by the pause")
	var steps := 0
	while Game.state == Game.State.CAUGHT and steps < 1000:
		loop.step(DT)
		steps += 1
	near(steps * DT, left, 2.0 * DT, "the beat resumes for exactly what was left")
	eq(Game.state, Game.State.PLAYING, "then respawns into play")


# ---------------------------------------------------------------------------
# G7: bests persist across loop instances (a new session)
# ---------------------------------------------------------------------------

func test_bests_persist_into_a_new_session() -> void:
	make_loop()
	var path := loop.records_path
	var p := make_bird(GameLoop.START_MASS, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	# Grow to a crow by meals, then quit to the menu (no summary).
	var guard := 0
	while SizeRules.tier_for_mass(p.mass) < SizeRules.species_index(&"crow") and guard < 400:
		var prey := make_bird(p.mass * 0.7, Vector3(0, 30, -0.3), Vector3.FORWARD)
		loop.set_protection(prey, 0.0)
		loop._commit_catch(p, prey)
		birds.erase(prey)
		prey.free()
		guard += 1
	var tier := SizeRules.tier_for_mass(p.mass)
	var score := int(loop.get_run_stats()["score"])
	# The app is killed (no run end): only the mid-run saves count.
	remove_child(loop)
	loop.free()
	loop = null
	var l2 := GameLoop.new()
	l2.auto_step = false
	l2.records_path = path
	l2.verbose = false
	add_child(l2)
	loop = l2
	var st := l2.get_run_stats()
	metric("persist", {"tier_reached": tier, "best_tier_loaded": st["best_tier"], "score": score,
		"best_score_loaded": st["best_score"]})
	eq(int(st["best_tier"]), tier, "a new session loads the best tier reached (saved at the tier-up)")
	gt(float(st["best_score"]), 0.0, "and a best score")
