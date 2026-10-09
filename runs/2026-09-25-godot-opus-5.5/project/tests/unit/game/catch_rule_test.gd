extends "res://tests/unit/game/game_fixture.gd"
## G1 — the catch rule: ratio and distance boundaries, aim cone (and its
## cap with the catch assist), swept contact (exact, against a finely sampled
## reference), invulnerability, self/dead birds, deterministic chains, the
## ratio re-checked at each catch, no double catches, broad phase == brute
## force, and cost.

const DT := 1.0 / 72.0
const Y := 20.0


func _contact(pred_mass: float, prey_mass: float, player: bool) -> float:
	var r := CatchRule.new()
	r.player_time_scale = SizeRules.time_scale(pred_mass)
	return r.contact_distance(SizeRules.body_radius_for_mass(pred_mass), SizeRules.wingspan_for_mass(pred_mass),
			player, SizeRules.body_radius_for_mass(prey_mass))


func test_ratio_boundary() -> void:
	make_loop()
	start_logging()
	# Independent pairs 50 m apart; prey 0.1 kg directly ahead at 70% of reach.
	var cases := [
		[0.1 * SizeRules.EAT_RATIO, true, "exactly EAT_RATIO heavier catches"],
		[0.1 * SizeRules.EAT_RATIO * 0.999, false, "0.1% under EAT_RATIO cannot"],
		[0.1, false, "equal mass cannot"],
		[0.05, false, "smaller cannot eat bigger"],
		[0.5, true, "5x heavier catches"],
	]
	var prey_list: Array[SimBird] = []
	var pred_list: Array[SimBird] = []
	for i in cases.size():
		var x := i * 50.0
		var pm: float = cases[i][0]
		var d := _contact(pm, 0.1, false) * 0.7
		pred_list.append(make_bird(pm, Vector3(x, Y, 0)))
		prey_list.append(make_bird(0.1, Vector3(x, Y, -d)))
	loop.step(DT)
	for i in cases.size():
		eq(not prey_list[i].alive, cases[i][1], cases[i][2])
	eq(count("caught"), 2, "exactly the two legal catches happened")
	# Eater mass grows (NPC: capped share), loser untouched.
	gt(pred_list[0].mass, 0.1 * SizeRules.EAT_RATIO, "NPC eater grew")
	check(pred_list[1].alive and prey_list[1].alive, "no-catch pair both alive")


func test_distance_boundary() -> void:
	var pm := 0.35  # pigeon
	var qm := 0.09  # starling
	var c_npc := _contact(pm, qm, false)
	var c_pl := _contact(pm, qm, true)
	# Pin the formula: radii (0.16 span each) + reach (NPC 0.25 span; player
	# 2.0 / sqrt(time_scale) spans).
	var sp := SizeRules.wingspan_for_mass(pm)
	var sq := SizeRules.wingspan_for_mass(qm)
	near(CatchRule.new().player_reach_exp, 0.5, 1e-9, "player reach ~ 1 / sqrt(body time)")
	near(c_npc, 0.16 * sp + 0.16 * sq + 0.25 * sp, 1e-6, "NPC contact distance = radii + 0.25 span")
	near(c_pl, 0.16 * sp + 0.16 * sq + 2.0 / sqrt(SizeRules.time_scale(pm)) * sp, 1e-6,
			"player contact distance = radii + 2.0/sqrt(time_scale) spans")
	gt(c_pl, c_npc * 1.4, "player reach is substantially more forgiving than NPC reach")
	# Reach in spans shrinks with body time: 2 spans for a sparrow, 1 for an eagle.
	var r := CatchRule.new()
	r.player_time_scale = SizeRules.time_scale(0.03)
	near(r.player_reach_spans(), 2.0, 1e-6, "sparrow-sized player reach: 2 spans")
	r.player_time_scale = SizeRules.time_scale(float(SizeRules.species_data(&"eagle")["mass"]))
	between(r.player_reach_spans(), 0.95, 1.05, "eagle-sized player reach: ~1 span")
	r.player_assist = 1.0
	r.player_time_scale = 1.0
	near(r.player_reach_spans(), 2.0 * (1.0 + CatchRule.ASSIST_REACH), 1e-6, "full catch assist: reach x (1 + ASSIST_REACH)...")
	near(CatchRule.ASSIST_REACH, 1.25, 1e-9, "full assist: +125% reach")
	near(r.contact_distance(0.16 * 0.24, 0.24, true, 0.16 * 0.16), CatchRule.PLAYER_CONTACT_MAX_SPANS * 0.24, 1e-9,
			"...but a sparrow's contact stops at PLAYER_CONTACT_MAX_SPANS wingspans")
	near(r.cone_cos(true), cos(deg_to_rad(90.0)), 1e-6, "full assist widens the cone to 90 deg and no further")
	metric("npc_contact_m", c_npc)
	metric("player_contact_m", c_pl)
	make_loop(true)
	make_bird(pm, Vector3(0, Y, 0))
	var q_in := make_bird(qm, Vector3(0, Y, -c_npc * 0.99))
	make_bird(pm, Vector3(50, Y, 0))
	var q_out := make_bird(qm, Vector3(50, Y, -c_npc * 1.01))
	loop.step(DT)
	check(not q_in.alive, "prey at 0.99 x NPC reach is caught")
	check(q_out.alive, "prey at 1.01 x NPC reach is not")
	await cleanup()
	for f: float in [0.99, 1.01]:
		make_loop(true)
		var p := make_bird(pm, Vector3(0, Y, 0), Vector3.FORWARD, true)
		loop.set_protection(p, 0.0)
		var q := make_bird(qm, Vector3(0, Y, -c_pl * f))
		loop.step(DT)
		eq(not q.alive, f < 1.0, "prey at %.2f x player reach caught by the player: %s" % [f, f < 1.0])
		await cleanup()


func test_felt_reach_by_size() -> void:
	# What the reach is in the headset (world_scale follows the wingspan:
	# CatchRule.FELT_M_PER_SPAN felt metres per wingspan), centre to centre,
	# for a typical worthwhile prey (a third of the player's mass): never
	# beyond three arm spans (~5.1 m) whatever the assist (round 2's full
	# assist gave a sparrow 8 m: a magnet), never so short a big bird has to
	# touch beaks (>= 0.85 m), and not wildly different between sizes (round
	# 2: an eagle's 1.3 m against a sparrow's 3.8 m, and its chases failed
	# nine times in ten more often).
	var r := CatchRule.new()
	var rows := {}
	var felt_sparrow := 0.0
	var worst_lo := INF
	for s in SizeRules.SPECIES.slice(SizeRules.species_index(&"sparrow")):
		var m: float = s["mass"]
		var span := SizeRules.wingspan_for_mass(m)
		r.player_time_scale = SizeRules.time_scale(m)
		var out := []
		for assist in [0.0, 0.5, 1.0]:
			r.player_assist = assist
			var c := r.contact_distance(SizeRules.body_radius_for_mass(m), span, true, SizeRules.body_radius_for_mass(m / 3.0))
			out.append(c / span * CatchRule.FELT_M_PER_SPAN)
		rows[String(s["id"])] = out.map(func(x: float) -> float: return snappedf(x, 0.01))
		lt(out[2], 3.0 * 1.7, "%s: felt reach at full assist under three arm spans (%.2f m)" % [s["id"], out[2]])
		check(out[1] >= out[0] - 1e-9 and out[2] >= out[1] - 1e-9, "%s: assist never shortens the reach" % s["id"])
		worst_lo = minf(worst_lo, out[0])
		if s["id"] == &"sparrow":
			felt_sparrow = out[0]
		else:
			gt(out[0], felt_sparrow * 0.5, "%s: unassisted felt reach at least half a sparrow's" % s["id"])
	gt(worst_lo, 0.85, "felt reach never under half an arm span")
	metric("felt_reach_m_by_assist_0_half_full", rows)


func test_aim_cone() -> void:
	make_loop(true)
	var pm := 0.35
	var qm := 0.09
	var c := _contact(pm, qm, false) * 0.9
	var cp := _contact(pm, qm, true) * 0.9
	var rule := loop.rule
	eq(rule.npc_cone_deg, 55.0, "NPC cone half-angle")
	eq(rule.player_cone_deg, 80.0, "player cone half-angle")
	var probes := []
	# [x, pred_is_player, angle_deg, heading, velocity, dist, want_caught, msg]
	probes.append([0.0, false, 50.0, Vector3.FORWARD, Vector3.ZERO, c, true, "NPC: prey 50 deg off-axis (inside 55)"])
	probes.append([30.0, false, 60.0, Vector3.FORWARD, Vector3.ZERO, c, false, "NPC: prey 60 deg off-axis (outside 55)"])
	probes.append([60.0, false, 180.0, Vector3.FORWARD, Vector3.ZERO, c, false, "NPC: prey behind within reach"])
	probes.append([90.0, false, 180.0, Vector3.FORWARD, Vector3.ZERO, 0.05, true, "NPC: bodies overlapping deeply, any heading"])
	var outcomes: Array[SimBird] = []
	for pr in probes:
		var x: float = pr[0]
		var ang := deg_to_rad(float(pr[2]))
		var dir := Vector3(sin(ang), 0, -cos(ang))
		make_bird(pm, Vector3(x, Y, 0), pr[3], pr[1])
		outcomes.append(make_bird(qm, Vector3(x, Y, 0) + dir * float(pr[5])))
	loop.step(DT)
	for i in probes.size():
		eq(not outcomes[i].alive, probes[i][6], probes[i][7])
	await cleanup()

	# Player cone (separate runs: one player per registry).
	var pcases := [
		[75.0, Vector3.FORWARD, Vector3.ZERO, true, "player: prey 75 deg off heading (inside 80)"],
		[85.0, Vector3.FORWARD, Vector3.ZERO, false, "player: prey 85 deg off heading (outside 80)"],
		[0.0, Vector3.BACK, Vector3.FORWARD * 8.0, true, "player: heading away but flying at the prey (velocity cone)"],
		[0.0, Vector3.BACK, Vector3.ZERO, false, "player: heading away, not moving at it"],
	]
	for pc in pcases:
		make_loop(true)
		var p := make_bird(pm, Vector3(0, Y, 0), pc[1], true)
		loop.set_protection(p, 0.0)
		p.velocity = pc[2]
		var ang := deg_to_rad(float(pc[0]))
		var q := make_bird(qm, Vector3(0, Y, 0) + Vector3(sin(ang), 0, -cos(ang)) * cp)
		loop.step(DT)
		eq(not q.alive, pc[3], pc[4])
		await cleanup()


func test_full_assist_cone_stays_in_front() -> void:
	# The brief says prey in front: even at full catch assist the player's
	# cone stops at the wing line (90 deg). Still prey at 70% of the reach,
	# `angle` off the heading, both birds still.
	var caught := {}
	for assist in [0.0, 1.0]:
		for ang in [75.0, 85.0, 89.0, 92.0, 100.0]:
			make_loop()
			loop.assist_override = assist
			var p := make_bird(0.03, Vector3(0, Y, 0), Vector3.FORWARD, true)
			loop.start_run()
			loop.set_protection(p, 0.0)
			loop.step(DT)
			var reach := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.012))
			var a := deg_to_rad(ang)
			var q := make_bird(0.012, p.global_position + Vector3(sin(a), 0, -cos(a)) * reach * 0.7, Vector3.RIGHT)
			p.velocity = Vector3.ZERO
			loop.step(DT)
			caught["%.0f@%.0f" % [assist, ang]] = not q.alive
			await cleanup()
	metric("caught_by_angle", caught)
	check(caught["0@75"] and not caught["0@85"], "no assist: the 80 deg cone")
	check(caught["1@85"] and caught["1@89"], "full assist: out to 90 deg")
	check(not caught["1@92"] and not caught["1@100"], "full assist: never behind the wing line")


func test_swept_contact_is_exact() -> void:
	# contact_time against a reference that samples the frame 4000 times:
	# the first moment the prey is within reach AND inside the cone (or
	# overlapping). Random relative motions, all cones and both forgiveness
	# rules. The rule must never miss a contact the samples see, never
	# report one they do not, and find the same first moment (to a sample).
	var rule := CatchRule.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var missed := 0
	var phantom := 0
	var late := 0
	var early := 0
	var contacts := 0
	var n_s := 4000
	for trial in 3000:
		var pl := trial % 3 == 0
		var on_pl := trial % 3 == 1
		rule.player_assist = rng.randf() if pl else 0.0
		rule.player_danger_assist = rng.randf() if on_pl else 0.0
		var contact := rng.randf_range(0.3, 1.5)
		var overlap := contact * rng.randf_range(0.0, 0.4)
		var d0 := Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(-0.8, 0.8), rng.randf_range(-1.5, 1.5))
		var dv := Vector3(rng.randf_range(-3, 3), rng.randf_range(-1, 1), rng.randf_range(-3, 3))
		var fwd := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized()
		var vel := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized() if pl else Vector3.ZERO
		var pred0 := Vector3(rng.randf_range(-5, 5), 0, rng.randf_range(-5, 5))
		var pred1 := pred0 + Vector3(rng.randf_range(-2, 2), rng.randf_range(-0.5, 0.5), rng.randf_range(-2, 2))
		var prey0 := pred0 + d0
		var prey1 := pred1 + d0 + dv
		var got := rule.contact_time(pred0, pred1, prey0, prey1, contact, overlap, fwd, vel, pl, on_pl)
		# Reference: sample.
		var cc := rule.cone_cos(pl, on_pl)
		var ov := -1.0 if on_pl and not rule.overlap_on_player else overlap
		var want := -1.0
		for k in n_s + 1:
			var t := float(k) / n_s
			var d := d0 + dv * t
			var dist := d.length()
			if dist > contact:
				continue
			var ok := dist <= ov or (dist > 1e-9 and (fwd.dot(d / dist) >= cc or (pl and vel != Vector3.ZERO and vel.dot(d / dist) >= cc)))
			if ok:
				want = t
				break
		if want >= 0.0:
			contacts += 1
		if want >= 0.0 and got < 0.0:
			missed += 1
		elif want < 0.0 and got >= 0.0:
			# The exact rule may find a contact thinner than one sample: accept
			# only if it is genuinely inside the reach and the cone there.
			var d := d0 + dv * got
			var dist := d.length()
			if dist > contact + 1e-6 or not (dist <= ov + 1e-6 or fwd.dot(d) >= cc * dist - 1e-6 or (pl and vel.dot(d) >= cc * dist - 1e-6)):
				phantom += 1
		elif want >= 0.0:
			if got > want + 1e-9:
				late += 1
			elif got < want - 1.0 / n_s - 1e-9:
				early += 1
	metric("swept_exact", {"contacts": contacts, "missed": missed, "phantom": phantom, "late": late, "early": early})
	gt(float(contacts), 500.0, "(setup) many contacts among the random motions")
	eq(missed, 0, "no contact missed")
	eq(phantom, 0, "no contact reported where there is none")
	eq(late, 0, "never later than the first sampled moment")
	eq(early, 0, "never earlier than a sample before it")


func test_the_ratio_holds_at_the_moment_of_the_catch() -> void:
	# In one frame the player (75 g) eats a swallow (55 g) and grows past
	# 100 g; later in the same frame a 100 g starling that could eat it at the
	# start of the frame strikes it. It is no longer 1.25x heavier: the
	# player must not be eaten by a bird now smaller than it.
	make_loop()
	var p := make_bird(0.075, Vector3(0, Y, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.075
	loop.set_protection(p, 0.0)
	var o := p.global_position
	var q := make_bird(0.055, o + Vector3(0, 0, -5), Vector3.FORWARD)
	var h := make_bird(0.1, o + Vector3(0, 0, 5), Vector3.FORWARD)
	loop.step(DT)
	var cp := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, q.get_body_radius(), false)
	var ch := loop.rule.contact_distance(h.get_body_radius(), h.get_wingspan(), false, p.get_body_radius(), true)
	# Start of the frame: the prey 0.02 m beyond the player's reach, the
	# starling 0.05 m beyond its strike reach behind the player.
	q.global_position = o + Vector3(0, 0, -(cp + 0.02))
	h.global_position = o + Vector3(0, 0, ch + 0.05)
	loop.teleported(q)
	loop.teleported(h)
	loop.step(DT)
	check(q.alive and p.alive, "(setup) nothing in contact yet")
	# In the frame: the player reaches the prey at t = 0.5, the starling
	# reaches the player at t = 0.625.
	p.global_position += Vector3(0, 0, -0.04)
	h.global_position += Vector3(0, 0, -0.12)
	loop.step(DT)
	check(not q.alive, "the player ate the swallow")
	gt(p.mass, h.mass, "(setup) and outgrew the starling")
	check(p.alive, "the now-smaller starling does not eat the player in the same frame")
	eq(loop.phase, GameLoop.Phase.PLAYING, "the run goes on")


func test_swept_contact_no_tunnelling() -> void:
	make_loop()
	start_logging()
	# A hawk stooping at 40 m/s simulated at 10 Hz moves 4 m per step: both
	# endpoints are far outside reach, the path goes straight through.
	var dt := 0.1
	var hm := 1.3
	var sm := 0.03
	var reach := _contact(hm, sm, false)
	var lanes := [[0.0, true, "straight through"], [reach * 0.8, true, "passing within reach"],
			[reach * 1.3, false, "passing outside reach"]]
	var hawks: Array[SimBird] = []
	var prey: Array[SimBird] = []
	for i in lanes.size():
		var x := i * 40.0
		hawks.append(make_bird(hm, Vector3(x, Y, 2.0)))
		prey.append(make_bird(sm, Vector3(x + float(lanes[i][0]), Y, 0.0)))
	loop.step(dt)  # records start positions
	for h in hawks:
		h.global_position += Vector3(0, 0, -4.0)
		h.velocity = Vector3(0, 0, -40.0)
	loop.step(dt)
	for i in lanes.size():
		eq(not prey[i].alive, lanes[i][1], "4 m/step stoop, " + lanes[i][2])
	# Teleports are not swept: a bird jumping 500 m in a frame catches nothing on the way.
	await cleanup()
	make_loop()
	var jumper := make_bird(1.3, Vector3(0, Y, 250))
	var victim := make_bird(0.03, Vector3(0, Y, 0))
	loop.step(DT)
	jumper.global_position = Vector3(0, Y, -250)
	loop.step(DT)
	check(victim.alive, "teleport across a bird is not a catch")


func test_invulnerability() -> void:
	make_loop()
	var pred := make_bird(0.35, Vector3(0, Y, 0))
	var prey := make_bird(0.09, Vector3(0, Y, -0.2))
	loop.set_protection(prey, 0.5)
	var caught_at := -1
	for i in 60:
		loop.step(0.02)
		if not prey.alive and caught_at < 0:
			caught_at = i
	between(caught_at * 0.02, 0.48, 0.54, "protected prey is caught right after 0.5 s of protection")
	await cleanup()

	# NPC spawn grace: birds entering the game are safe for npc_spawn_grace_s.
	make_loop()
	loop.npc_spawn_grace_s = 1.0
	var p2 := make_bird(0.35, Vector3(0, Y, 0))
	var q2 := make_bird(0.09, Vector3(0, Y, -0.2))
	near(loop.protection_left(q2), 1.0, 1e-6, "new NPC protected for the spawn grace")
	near(loop.protection_left(p2), 1.0, 1e-6, "predator too (grace is per bird)")
	run_steps(40, 0.02)
	check(q2.alive, "still alive at 0.8 s")
	run_steps(15, 0.02)
	check(not q2.alive, "caught once the grace ran out")
	await cleanup()

	# Player: start protection, then catchable; protection ends on attack.
	make_loop(true)
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()  # the player now exists: start protection applies
	near(loop.protection_left(p), GameLoop.START_PROTECT_S, 1e-6, "run starts with protection")
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3), Vector3.FORWARD)
	start_logging()
	run_steps(int((GameLoop.START_PROTECT_S - 0.1) / 0.05), 0.05, func(_i: int) -> void:
		hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3))
	eq(count("player_caught"), 0, "not caught during start protection")
	run_steps(4, 0.05, func(_i: int) -> void:
		hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3))
	eq(count("player_caught"), 1, "caught once protection expired")
	await cleanup()

	make_loop(true)
	var p3 := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	gt(loop.protection_left(p3), 0.0, "protected")
	make_bird(0.012, p3.get_body_position() + Vector3(0, 0, -0.1))
	loop.step(DT)
	eq(loop.protection_left(p3), 0.0, "protection ends when the player catches something")


func test_self_dead_and_inactive_birds() -> void:
	make_loop()
	start_logging()
	var a := make_bird(0.35, Vector3(0, Y, 0))
	var dead := make_bird(0.09, Vector3(0, Y, -0.2))
	dead.alive = false
	var dead_pred := make_bird(0.35, Vector3(40, Y, 0))
	dead_pred.alive = false
	var live := make_bird(0.09, Vector3(40, Y, -0.2))
	var twin_a := make_bird(0.2, Vector3(80, Y, 0))
	var twin_b := make_bird(0.2, Vector3(80, Y, -0.1), Vector3.BACK)
	run_steps(10, DT)
	eq(count("caught"), 0, "dead prey, dead predators and equal-mass twins never produce a catch")
	check(live.alive and twin_a.alive and twin_b.alive and a.alive, "all live birds survive")
	await cleanup()

	# The player cannot catch or be caught outside a run; NPCs can.
	make_loop()
	start_logging()
	var p := make_bird(0.35, Vector3(0, Y, 0), Vector3.FORWARD, true)
	var edible := make_bird(0.09, Vector3(0, Y, -0.2))
	var hawk := make_bird(0.6, Vector3(0, Y, 0.4))  # crow: could eat the player, cannot reach `edible`
	var n1 := make_bird(0.35, Vector3(40, Y, 0))
	var n2 := make_bird(0.09, Vector3(40, Y, -0.2))
	run_steps(5, DT)
	check(p.alive and edible.alive, "no player catches in the menu (IDLE)")
	check(not n2.alive, "NPCs still hunt each other behind the menu")
	check(hawk.alive and n1.alive, "predators fine")
	eq(count("player_caught"), 0, "no player_caught outside a run")


func _chain_outcome(order: Array, c_first: bool) -> Dictionary:
	# B (0.5) waits at z=-10; A (1.0) flies at B; C (2.5) flies at A.
	make_loop()
	var dt := 0.1
	var starts := {}
	var ends := {}
	if c_first:
		# C closes on A (contact at t~0.42) before A reaches B (t~0.66).
		starts = {"A": Vector3(0, Y, -8.9), "B": Vector3(0, Y, -10), "C": Vector3(0, Y, -7.5)}
		ends = {"A": Vector3(0, Y, -9.6), "B": Vector3(0, Y, -10), "C": Vector3(0, Y, -9.3)}
	else:
		# A reaches B early; C closes on A only at the end of the frame.
		starts = {"A": Vector3(0, Y, -9.2), "B": Vector3(0, Y, -10), "C": Vector3(0, Y, -6.0)}
		ends = {"A": Vector3(0, Y, -9.8), "B": Vector3(0, Y, -10), "C": Vector3(0, Y, -8.9)}
	var masses := {"A": 1.0, "B": 0.5, "C": 2.5}
	var made := {}
	for id: String in order:
		made[id] = make_bird(masses[id], starts[id])
		made[id].name = id
	var log2: Array = []
	var cb := func(pred: Bird, prey: Bird) -> void: log2.append("%s>%s" % [pred.name, prey.name])
	Events.bird_caught.connect(cb)
	loop.step(dt)
	check(log2.is_empty(), "no contact before the chain frame")
	for id: String in order:
		made[id].global_position = ends[id]
		made[id].velocity = (ends[id] - starts[id]) / dt
	loop.step(dt)
	Events.bird_caught.disconnect(cb)
	var out := {"catches": ",".join(log2), "alive": ""}
	for id in ["A", "B", "C"]:
		out["alive"] += id if made[id].alive else "-"
	return out


func test_simultaneous_chains_are_deterministic() -> void:
	var orders := [["A", "B", "C"], ["C", "B", "A"], ["B", "C", "A"], ["C", "A", "B"]]
	for c_first in [false, true]:
		var first := {}
		for order in orders:
			var o := _chain_outcome(order, c_first)
			await cleanup()
			if first.is_empty():
				first = o
			eq(o, first, "same outcome whatever the registration order (c_first=%s, order=%s)" % [c_first, order])
		if c_first:
			eq(first["catches"], "C>A", "C catches A first, so A never eats B")
			eq(first["alive"], "-BC", "B survives the chain")
		else:
			eq(first["catches"], "A>B,C>A", "A eats B, then C eats A in the same frame")
			eq(first["alive"], "--C", "only C survives")
	# Exact ties (everyone in contact at t=0): heavier predator resolves first.
	make_loop()
	start_logging()
	var a := make_bird(1.0, Vector3(0, Y, -0.3))
	var b := make_bird(0.5, Vector3(0, Y, -0.6))
	var c := make_bird(2.5, Vector3(0, Y, 0.0))
	a.name = "A"
	b.name = "B"
	c.name = "C"
	loop.step(DT)
	eq(count("caught"), 1, "one catch in a full tie")
	check(not a.alive and b.alive, "tie: C (heaviest) eats A first, A cannot then eat B")


func test_no_double_catches() -> void:
	make_loop()
	start_logging()
	var p1 := make_bird(1.0, Vector3(0, Y, 0))
	var p2 := make_bird(1.2, Vector3(0.3, Y, 0))
	var q := make_bird(0.3, Vector3(0.15, Y, -0.3))
	run_steps(30, DT)
	eq(count("caught"), 1, "one prey, two predators in reach: exactly one catch")
	var e: Array = events("caught")[0]
	eq(e[1], p2, "the heavier predator wins the tie")
	check(not q.alive, "prey dead")
	await cleanup()

	# One predator, two prey in reach: one per frame, then handling time.
	make_loop()
	start_logging()
	var hunter := make_bird(1.0, Vector3(0, Y, 0))
	make_bird(0.2, Vector3(0.1, Y, -0.3))
	make_bird(0.2, Vector3(-0.1, Y, -0.3))
	loop.step(DT)
	eq(count("caught"), 1, "at most one catch per predator per frame")
	var frames := 0
	while count("caught") < 2 and frames < 200:
		loop.step(DT)
		frames += 1
	near(frames * DT, loop.rule.npc_handling_s, 2.0 * DT, "second catch waits for the NPC handling time")
	check(hunter.alive, "hunter alive")


func test_broad_phase_finds_every_contact() -> void:
	# Both broad phases alone: every pair whose swept segments come within
	# `reach` must be emitted, exactly once.
	for kind in ["sweep", "hash"]:
		var rng := RandomNumberGenerator.new()
		rng.seed = 1234
		var missed := 0
		var dupes := 0
		var total := 0
		var emitted := 0
		for trial in 40:
			var n := 60
			var p0 := PackedVector3Array()
			var p1 := PackedVector3Array()
			var mids := PackedVector3Array()
			var items := PackedInt32Array()
			var max_disp := 0.0
			for i in n:
				var a := Vector3(rng.randf_range(-6, 6), rng.randf_range(0, 6), rng.randf_range(-6, 6))
				var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * rng.randf_range(0.0, 0.9)
				p0.append(a)
				p1.append(a + d)
				mids.append(a + d * 0.5)
				items.append(i)
				max_disp = maxf(max_disp, d.length())
			var reach := 0.9
			var pr: PackedInt32Array
			if kind == "hash":
				pr = CatchGrid.new().pairs_of(mids, items, reach + max_disp)
			else:
				pr = CatchSweep.new().pairs(mids, items, reach + max_disp)
			var got := {}
			for k in range(0, pr.size(), 2):
				var key := Vector2i(mini(pr[k], pr[k + 1]), maxi(pr[k], pr[k + 1]))
				if got.has(key):
					dupes += 1
				got[key] = true
			emitted += got.size()
			# The reference is a pure distance test: an overlap radius equal
			# to the reach counts every moment within reach whatever the
			# heading (cones stop at 90 deg, so a cone alone would only see
			# the front hemisphere).
			var rule := CatchRule.new()
			for i in n:
				for j in range(i + 1, n):
					if rule.contact_time(p0[i], p1[i], p0[j], p1[j], reach, reach, Vector3.FORWARD, Vector3.ZERO, false) >= 0.0:
						total += 1
						if not got.has(Vector2i(i, j)):
							missed += 1
		gt(total, 100, "%s: the random scenes contain many contacts" % kind)
		eq(missed, 0, "%s: broad phase misses no swept contact" % kind)
		eq(dupes, 0, "%s: no pair reported twice" % kind)
		lt(float(emitted), 40.0 * 60 * 59 / 2 * 0.5, "%s: broad phase prunes most of the n^2 pairs" % kind)
		metric("%s_contacts" % kind, total)
		metric("%s_candidate_pairs" % kind, emitted)
	# The hash takes any number of birds (the sweep's keys stop at
	# CatchSweep.MAX_ITEMS): 1100 points, every pair within reach on every
	# axis found once, against a brute-force box test.
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 77
	var pts := PackedVector3Array()
	var its := PackedInt32Array()
	for i in 1100:
		pts.append(Vector3(rng2.randf_range(-60, 60), rng2.randf_range(0, 40), rng2.randf_range(-60, 60)))
		its.append(i)
	var pr2 := CatchGrid.new().pairs_of(pts, its, 3.0)
	var got2 := {}
	var dup2 := 0
	for k in range(0, pr2.size(), 2):
		var key := mini(pr2[k], pr2[k + 1]) * 4096 + maxi(pr2[k], pr2[k + 1])
		if got2.has(key):
			dup2 += 1
		got2[key] = true
	var want2 := 0
	var miss2 := 0
	for i in 1100:
		var a := pts[i]
		for j in range(i + 1, 1100):
			var b := pts[j]
			if absf(a.x - b.x) <= 3.0 and absf(a.y - b.y) <= 3.0 and absf(a.z - b.z) <= 3.0:
				want2 += 1
				if not got2.has(i * 4096 + j):
					miss2 += 1
	gt(float(want2), 200.0, "(setup) 1100 points: many pairs within reach")
	eq(miss2, 0, "hash, 1100 birds: no pair within reach missed")
	eq(dup2, 0, "hash, 1100 birds: no pair twice")
	eq(got2.size(), want2, "hash, 1100 birds: exactly the pairs within reach on every axis")


func test_loop_matches_brute_force_reference() -> void:
	# Random crowded scenes through the real loop vs. an O(n^2) reference that
	# applies the documented rule directly.
	for kind in [GameLoop.BroadPhase.SWEEP, GameLoop.BroadPhase.HASH]:
		await _reference_scenes(kind)


func _reference_scenes(kind: GameLoop.BroadPhase) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var mismatches := 0
	var catches := 0
	for trial in 25:
		make_loop()
		loop.broad_phase = kind
		var n := 40
		var p0: Array[Vector3] = []
		var p1: Array[Vector3] = []
		var masses: Array[float] = []
		var heads: Array[Vector3] = []
		for i in n:
			var m := exp(rng.randf_range(log(0.004), log(4.5)))
			var h := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1, 1)).normalized()
			var a := Vector3(rng.randf_range(-4, 4), Y + rng.randf_range(-2, 2), rng.randf_range(-4, 4))
			p0.append(a)
			p1.append(a + h * rng.randf_range(0.0, 0.6))
			masses.append(m)
			heads.append(h)
			make_bird(m, a, h)
		# Seed start positions without resolving (the reference starts at p0).
		loop.npc_catches_outside_run = false
		loop.step(DT)
		loop.npc_catches_outside_run = true
		for i in n:
			birds[i].global_position = p1[i]
			birds[i].velocity = (p1[i] - p0[i]) / DT
		loop.step(DT)
		var expect := _reference_dead(p0, p1, masses, heads)
		for i in n:
			if (not birds[i].alive) != expect[i]:
				mismatches += 1
			if expect[i]:
				catches += 1
		await cleanup()
	var label: String = GameLoop.BroadPhase.keys()[kind]
	gt(catches, 20, "%s: reference scenes produce plenty of catches" % label)
	eq(mismatches, 0, "%s: loop outcome == brute-force reference in every scene" % label)
	metric("reference_catches_%s" % label, catches)


func _reference_dead(p0: Array[Vector3], p1: Array[Vector3], masses: Array[float], heads: Array[Vector3]) -> Array[bool]:
	var rule := CatchRule.new()
	var n := p0.size()
	var cands := []
	for i in n:
		for j in n:
			if i == j or masses[i] < masses[j] * SizeRules.EAT_RATIO:
				continue
			var ri := SizeRules.body_radius_for_mass(masses[i])
			var rj := SizeRules.body_radius_for_mass(masses[j])
			var c := rule.contact_distance(ri, SizeRules.wingspan_for_mass(masses[i]), false, rj)
			var vd := (p1[i] - p0[i]).normalized() if p1[i] != p0[i] else Vector3.ZERO
			var t := rule.contact_time(p0[i], p1[i], p0[j], p1[j], c, (ri + rj) * rule.overlap_fraction, heads[i], vd, false)
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
	# Applied in contact order; the ratio must still hold with the masses of
	# the moment (an NPC keeps NPC_GROWTH_SHARE of a meal, capped).
	var live := masses.duplicate()
	for c: Array in cands:
		if dead[c[7]] or dead[c[8]] or ate.has(c[7]):
			continue
		if live[c[7]] < live[c[8]] * SizeRules.EAT_RATIO:
			continue
		dead[c[8]] = true
		ate[c[7]] = true
		var old: float = live[c[7]]
		live[c[7]] = minf(old + SizeRules.meal_gain(old, live[c[8]]) * GameLoop.NPC_GROWTH_SHARE,
				maxf(masses[c[7]] * (1.0 + GameLoop.NPC_GROWTH_CAP), old))
	return dead


func test_catch_cost_60_birds() -> void:
	var meds := {}
	for kind in [GameLoop.BroadPhase.SWEEP, GameLoop.BroadPhase.HASH]:
		var label: String = GameLoop.BroadPhase.keys()[kind]
		var med := await _catch_cost(kind)
		meds[kind] = med
		metric("catch_us_median_%s" % label, med)
		# Budget: the whole catch pass for 60 birds well under 0.2 ms on the
		# dev Mac (Quest's CPU is roughly 2-3x slower for GDScript).
		lt(med, 200.0, "catch pass for 60 birds, median µs (%s)" % label)
		await cleanup()
	# (A Node never added to the tree must be freed by hand: fix round 5
	# review - this line leaked a GameLoop and its RefCounteds at exit.)
	var fresh := GameLoop.new()
	eq(fresh.broad_phase, GameLoop.BroadPhase.HASH, "the spatial hash is the default broad phase")
	fresh.free()
	# The column hash is not the round-3 cube hash (~135 µs against ~20 µs
	# for the sweep's broad phase): the default costs little over the sweep.
	lt(float(meds[GameLoop.BroadPhase.HASH]), float(meds[GameLoop.BroadPhase.SWEEP]) * 1.35 + 15.0,
			"the spatial hash costs at most ~1/3 more than the sweep for the whole pass")


func _catch_cost(kind: GameLoop.BroadPhase) -> float:
	make_loop()
	loop.broad_phase = kind
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# 60 birds: tight flocks (worst case for the broad phase) and scattered singles.
	for i in 60:
		var centre := Vector3((i % 4) * 30.0, Y, 0) if i < 40 else Vector3(rng.randf_range(-200, 200), Y, rng.randf_range(-200, 200))
		var spread := 3.0 if i < 40 else 0.0
		make_bird(exp(rng.randf_range(log(0.004), log(4.5))),
				centre + Vector3(rng.randf_range(-spread, spread), rng.randf_range(-spread, spread), rng.randf_range(-spread, spread)),
				Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)))
	var times: Array[float] = []
	var parts := {}
	for s in 200:
		for b in birds:
			if b.alive:
				b.fly(b.heading.rotated(Vector3.UP, 0.05), b.cruise_speed(), DT)
		loop.step(DT)
		times.append(float(loop.perf["catch"]))
		for k in ["snapshot", "broad"]:
			parts[k] = float(parts.get(k, 0.0)) + float(loop.perf.get(k, 0.0)) / 200.0
	# Best of four 50-frame medians: other agents' runs share this machine.
	var best := INF
	for w in 4:
		var win := times.slice(w * 50, w * 50 + 50)
		win.sort()
		best = minf(best, win[25])
	times.sort()
	print("[gameloop] catch cost %s: median %.0f us (best window %.0f), p95 %.0f us, parts %s" % [
		GameLoop.BroadPhase.keys()[kind], times[100], best, times[190], parts])
	return best
