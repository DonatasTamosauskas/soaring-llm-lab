extends "res://tests/unit/game/game_fixture.gd"
## G1 / G6 — the secondary mechanics, each pinned by its own test: the catch
## assist ramp and the reach it buys, refuges (and their index), birds in
## cover out of play, teleported(), the player's handling time, the target's
## minimum hold, highlight range hysteresis, highlights re-asserted over other
## writers, a threat cue that never outlives its predator, and bookkeeping
## that does not grow with bird churn.

const DT := 1.0 / 72.0


## A World (core contract) with refuge spheres, no geometry.
class RefugeWorld extends World:
	var refuges: Array[Dictionary] = []

	func get_refuges() -> Array[Dictionary]:
		return refuges


## A bird that can take cover, as the AI's NpcBird (`hidden`).
class HidingBird extends SimBird:
	var hidden := false


func _hiding_bird(mass: float, pos: Vector3, facing: Vector3 = Vector3.FORWARD) -> HidingBird:
	var b := HidingBird.new()
	b.mass = mass
	b.species = SizeRules.species_for_mass(mass)
	b.name = "Hiding_%d" % birds.size()
	b.model = FakeModel.new()
	b.add_child(b.model)
	add_child(b)
	b.global_position = pos
	b.set_heading(facing)
	var pl := Birds.player()
	if pl != null and SizeRules.can_eat(mass, pl.mass):
		b.target = pl
	birds.append(b)
	return b


var _walls: Array[Node] = []


func after_each() -> void:
	for w in _walls:
		if is_instance_valid(w):
			w.queue_free()
	_walls.clear()
	await super()


## A static box on the world's physics layer (1), as the valley's houses,
## trunks and crowns are.
func _wall(pos: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	body.global_position = pos
	_walls.append(body)
	return body


func _player(mass: float = 0.03) -> SimBird:
	make_loop()
	var p := make_bird(mass, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = mass
	loop.set_protection(p, 0.0)
	loop.step(DT)
	return p


func _unassisted_contact(p: Bird, prey_mass: float) -> float:
	var r := CatchRule.new()
	r.player_time_scale = SizeRules.time_scale(p.mass)
	return r.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(prey_mass))


func _advance_without_catch(until_s: float) -> void:
	while loop.since_catch < until_s - 1e-6:
		loop.step(minf(0.5, until_s - loop.since_catch))


# --- Catch assist ----------------------------------------------------------

func test_catch_assist_ramp_and_the_reach_it_buys() -> void:
	var p := _player(0.03)
	var ramp := {}
	for t in [29.0, 52.5, 75.0, 120.0, 200.0]:
		_advance_without_catch(t)
		ramp[t] = loop.catch_assist()
	metric("assist_ramp_sparrow", ramp)
	near(ramp[29.0], 0.0, 1e-6, "no assist before 30 body-seconds without a catch")
	near(ramp[52.5], 0.25, 1e-3, "a quarter at 52.5 s")
	near(ramp[75.0], 0.5, 1e-3, "half at 75 s")
	near(ramp[120.0], 1.0, 1e-6, "full at 120 s")
	near(ramp[200.0], 1.0, 1e-6, "capped at full")
	loop.step(DT)
	eq(loop.rule.player_assist, 1.0, "the loop hands the assist to the catch rule")
	near(loop.rule.player_reach_spans(), 2.0 * (1.0 + CatchRule.ASSIST_REACH), 1e-6, "full assist: a sparrow's reach x (1 + ASSIST_REACH)")
	# (capped at PLAYER_CONTACT_MAX_SPANS: prey beyond is never caught)
	var c0 := _unassisted_contact(p, 0.012)
	var far := make_bird(0.012, p.get_body_position() + Vector3(0, 0, -CatchRule.PLAYER_CONTACT_MAX_SPANS * p.get_wingspan() * 1.03))
	loop.step(DT)
	check(far.alive, "full assist: prey beyond PLAYER_CONTACT_MAX_SPANS wingspans is not caught")
	far.global_position = Vector3(0, -900, 0)
	# A wren at 1.2x the normal reach, dead ahead: caught with full assist...
	var q := make_bird(0.012, p.get_body_position() + Vector3(0, 0, -c0 * 1.2))
	loop.step(DT)
	check(not q.alive, "full assist: prey at 1.2x the normal reach is caught")
	near(loop.catch_assist(), 0.0, 1e-6, "a catch resets the assist")
	# ...and not without it (same geometry, just after that catch).
	run_steps(int(0.3 / DT), DT)
	var c1 := _unassisted_contact(p, 0.012)
	var q2 := make_bird(0.012, p.get_body_position() + Vector3(0, 0, -c1 * 1.2))
	loop.step(DT)
	check(q2.alive, "no assist: the same prey at 1.2x reach is out of reach")
	# Deaths do not reset the ramp (a struggling player keeps the help).
	_advance_without_catch(100.0)
	var before := loop.catch_assist()
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.4))
	loop.step(DT)
	eq(loop.phase, GameLoop.Phase.CAUGHT, "(setup) caught")
	hawk.global_position = Vector3(0, -900, 0)
	run_steps(int((GameLoop.CAUGHT_BEAT_S + 0.2) / DT), DT)
	eq(loop.phase, GameLoop.Phase.PLAYING, "(setup) respawned")
	gt(loop.catch_assist(), before - 1e-6, "a death does not reset the assist")


func test_catch_assist_is_in_body_time() -> void:
	# The assist's clock runs in the square root of body time (as the reach
	# does): an eagle (body time 4) waits twice a sparrow's 30 s before any
	# help, and gets half of it at twice the sparrow's 75 s - not four times
	# (round 2: a hawk waited 2 minutes for any help, 7 for full help).
	var ts := SizeRules.time_scale(3.0)
	near(ts, 4.0, 1e-6, "(setup) an eagle's body time")
	near(GameLoop.assist_for(55.0, 3.0), 0.0, 1e-9, "eagle, 55 s: none")
	near(GameLoop.assist_for(75.0 * sqrt(ts), 3.0), 0.5, 1e-6, "eagle, 150 s: half")
	near(GameLoop.assist_for(75.0, 0.03), 0.5, 1e-6, "sparrow, 75 s: half")
	gt(GameLoop.assist_for(150.0, 3.0), GameLoop.assist_for(150.0 * ts / sqrt(ts), 3.0) - 1.0, "(sanity)")
	lt(GameLoop.assist_for(100.0, 3.0), GameLoop.assist_for(100.0, 0.03), "a big bird still waits longer than a small one")
	var p := _player(3.0)
	_advance_without_catch(55.0)
	near(loop.catch_assist(), 0.0, 1e-6, "live loop, eagle after 55 s: none")
	_advance_without_catch(150.0)
	near(loop.catch_assist(), 0.5, 1e-3, "live loop, eagle after 150 s: half")
	metric("eagle_time_scale", ts)


# --- Refuges and teleports ---------------------------------------------------

func test_refuges_block_only_predators_too_wide_to_follow() -> void:
	var world := RefugeWorld.new()
	world.refuges = [{"position": Vector3(0, 20, 0), "radius": 3.0, "max_span": 0.5}]
	add_child(world)
	make_loop()
	await get_tree().process_frame  # the loop finds the world (deferred)
	# A hawk (1.6 m span) at a sparrow hiding inside a hedge-sized refuge.
	var hawk := make_bird(1.3, Vector3(0, 20, 0.3))
	var hidden := make_bird(0.03, Vector3(0, 20, 0))
	# A starling (0.40 m span: fits) at a wren inside the same refuge.
	var starling := make_bird(0.1, Vector3(1.5, 20, 0.1))
	var wren := make_bird(0.012, Vector3(1.5, 20, 0.0))
	run_steps(10, DT)
	check(hidden.alive, "a hawk cannot catch a sparrow inside a refuge it cannot enter")
	check(not wren.alive, "a starling that fits still catches a wren in there")
	# The sparrow leaves cover: now it can be caught.
	hidden.global_position = Vector3(0, 20, 6.0)
	hawk.global_position = Vector3(0, 20, 6.3)
	loop.teleported(hidden)
	loop.teleported(hawk)
	run_steps(int(1.5 / DT), DT)
	check(not hidden.alive, "outside the refuge the hawk catches it")
	check(hawk.alive and starling.alive, "(predators unharmed)")
	world.queue_free()


func test_teleported_jumps_are_not_swept() -> void:
	# A 2 m jump in one 72 Hz frame is under the automatic teleport threshold
	# (90 m/s x dt + 1 m = 2.25 m): only teleported() keeps it from being
	# swept as a flight path straight through the sparrow.
	for announce in [false, true]:
		make_loop()
		var hawk := make_bird(1.3, Vector3(0, 20, 1.0))
		var sparrow := make_bird(0.03, Vector3(0, 20, 0))
		loop.step(DT)
		check(sparrow.alive, "(setup) out of reach before the jump")
		hawk.global_position = Vector3(0, 20, -1.0)
		if announce:
			loop.teleported(hawk)
		loop.step(DT)
		eq(sparrow.alive, announce, "2 m jump through a sparrow %s teleported(): %s" % [
			"with" if announce else "without", "not caught" if announce else "caught (swept)"])
		await cleanup()


# --- Birds in cover ------------------------------------------------------------

func test_birds_in_cover_are_out_of_play() -> void:
	# The AI's NpcBird hides in a refuge (`hidden`): until it comes out it can
	# neither be caught - even by a predator that fits the refuge, the
	# valley's rooms and nest boxes had become a larder - nor catch, and it
	# is never the target or a threat.
	var p := _player(0.09)  # starling
	var o := p.get_body_position()
	var span := p.get_wingspan()
	var c := _unassisted_contact(p, 0.03)
	# Hidden prey right in front of the player, well within reach.
	var sitting := _hiding_bird(0.03, o + Vector3(0, 0, -c * 0.4))
	sitting.hidden = true
	var open := make_bird(0.03, o + Vector3(3 * span, 0, -25 * span), Vector3.FORWARD, false, true)
	check(loop.is_sheltered(sitting, span), "a bird in cover is sheltered from any predator")
	loop.set_protection(p, 600.0)  # (no catches while the cue settles)
	loop.step(DT)
	eq(loop.watch.target, open, "the target cue skips the bird in cover, however close")
	eq(sitting.model.highlight, 1, "...which still shows what it is (worthwhile prey)")
	loop.set_protection(p, 0.0)
	run_steps(10, DT)
	check(sitting.alive, "a bird in cover cannot be caught, even within reach and dead ahead")
	# It comes out: now it can.
	sitting.hidden = false
	run_steps(3, DT)
	check(not sitting.alive, "out of cover it is caught")
	await cleanup()
	# A hidden hawk touching the player neither catches it nor is a threat.
	p = _player(0.03)
	o = p.get_body_position()
	var hawk := _hiding_bird(1.3, o + Vector3(0, 0, -0.2), Vector3.BACK)
	hawk.hidden = true
	hawk.velocity = Vector3(0, 0, 3.0)
	run_steps(10, DT)
	check(p.alive, "a bird in cover does not catch")
	eq(loop.watch.predator, null, "...and is not named as a threat")
	eq(loop.watch.raw_level, 0.0, "...at any level")
	hawk.hidden = false
	run_steps(3, DT)
	check(not p.alive, "out of cover it strikes")


func test_refuge_index_matches_the_linear_scan() -> void:
	# RefugeIndex (what the loop and the cue query every frame) gives the
	# same answer as CatchRule.in_refuge (the linear reference) everywhere.
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var refuges: Array[Dictionary] = []
	for i in 320:
		var r := {"name": "r%d" % i, "position": Vector3(rng.randf_range(-300, 300), rng.randf_range(0, 30), rng.randf_range(-300, 300)),
			"radius": rng.randf_range(0.05, 2.5), "max_span": rng.randf_range(0.1, 3.0)}
		if i % 40 == 0:
			r.erase("max_span")  # no limit: nothing is kept out
		refuges.append(r)
	# A cluster: many refuges in one cell (a hedgerow's hollows).
	for i in 40:
		refuges.append({"position": Vector3(10.0 + i * 0.15, 1.0, 5.0), "radius": 0.4, "max_span": rng.randf_range(0.2, 0.6)})
	var index := RefugeIndex.new(refuges)
	var mismatches := 0
	var inside := 0
	for k in 20000:
		var q: Dictionary = refuges[rng.randi() % refuges.size()]
		var pos: Vector3 = q["position"] + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() \
				* rng.randf_range(0.0, float(q["radius"]) * 1.3)
		if k % 4 == 0:
			pos = Vector3(rng.randf_range(-310, 310), rng.randf_range(0, 30), rng.randf_range(-310, 310))
		var span := rng.randf_range(0.05, 3.5)
		var want := CatchRule.in_refuge(pos, span, refuges)
		if want:
			inside += 1
		if index.blocks(pos, span) != want:
			mismatches += 1
	metric("refuge_queries_blocked", inside)
	gt(float(inside), 2000.0, "(setup) many queries are inside a refuge too small")
	eq(mismatches, 0, "the index agrees with the linear scan on 20000 queries")
	check(not RefugeIndex.new([] as Array[Dictionary]).blocks(Vector3.ZERO, 5.0), "no refuges: nothing blocks")


# --- Handling time -----------------------------------------------------------

func test_player_handling_time() -> void:
	# Two wrens inside the sparrow's reach: one per frame at most, the second
	# only after the player has swallowed the first (core loop fix round 1:
	# GameLoop.SWALLOW_S_PER_GAIN x the share of its mass the meal added,
	# at least the handling time 0.2 s, at most SWALLOW_MAX_S) - but no
	# longer than that.
	var p := _player(0.03)
	var c := _unassisted_contact(p, 0.012)
	var a := make_bird(0.012, p.get_body_position() + Vector3(0.02, 0, -c * 0.4))
	var b := make_bird(0.012, p.get_body_position() + Vector3(-0.02, 0, -c * 0.45))
	var eaten_at: Array[float] = []
	var t := 0.0
	var m0 := p.mass
	var m1 := -1.0
	for i in int(2.0 / DT):
		# Keep both where they are relative to the (static) player.
		loop.step(DT)
		t += DT
		for q in [a, b]:
			if not q.alive and not q.has_meta(&"counted"):
				q.set_meta(&"counted", true)
				eaten_at.append(t)
				if m1 < 0.0:
					m1 = p.mass
	eq(eaten_at.size(), 2, "both eaten within 2 s")
	if eaten_at.size() == 2:
		var gap := eaten_at[1] - eaten_at[0]
		var swallow := clampf(GameLoop.SWALLOW_S_PER_GAIN * (m1 - m0) / m0, loop.rule.player_handling_s, GameLoop.SWALLOW_MAX_S)
		metric("player_handling_gap_s", {"gap": gap, "swallow": swallow, "gain": (m1 - m0) / m0})
		gt(gap, swallow - 1e-6, "second catch waits the swallowing (%.2f s)" % swallow)
		lt(gap, swallow + 2.0 * DT, "...and not longer (%.2f s)" % gap)
	near(loop.rule.player_handling_s, 0.2, 1e-9, "player handling time")
	near(loop.rule.npc_handling_s, 1.2, 1e-9, "NPC handling time")


# --- Target hold, highlight hysteresis, re-assertion --------------------------

func test_target_switch_waits_for_the_minimum_hold() -> void:
	var p := _player(0.09)  # starling
	loop.set_protection(p, 600.0)
	p.velocity = Vector3.ZERO
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var first := make_bird(0.03, o + Vector3(0, 0, -30 * span), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, first, "(setup) the sparrow is the target")
	# One frame later a clearly better prey appears (as catchable, much
	# nearer: over target_switch_ratio x the score). The player hovers - it
	# is not closing on its target, so only the minimum hold stands between.
	loop.step(DT)
	var prize := make_bird(0.03, o + Vector3(0, 0, -3 * span), Vector3.FORWARD)
	# The watch's hold clock: 0 when the target was set, +dt every update.
	var held := DT
	var switched_at := -1.0
	for i in int((loop.watch.target_min_hold_s + 1.5) / DT):
		loop.step(DT)
		held += DT
		if loop.watch.target == prize and switched_at < 0.0:
			switched_at = held
	metric("target_switched_after_s", switched_at)
	gt(switched_at, loop.watch.target_min_hold_s - 1e-6, "no switch before the minimum hold")
	lt(switched_at, loop.watch.target_min_hold_s + 2.0 * DT, "switch as soon as the hold is over")
	# Literal values (fix round 5 review and integration round 2: at 1.35x
	# after 1.5 s the cue moved on from chases ~9 times a minute; core loop
	# fix round 1: at 2x after 4 s, through the real chain, 2.5-4.5 times a
	# minute).
	near(loop.watch.target_min_hold_s, 10.0, 1e-9, "hold time")
	near(loop.watch.target_switch_ratio, 3.0, 1e-9, "switch ratio")


func test_a_target_being_closed_on_is_never_switched_away() -> void:
	# The player flies at its target, gaining on it; a far better bird
	# appears beside it. As long as the player keeps gaining (5% closer than
	# ever within target_commit_s), the cue stays on the chase it is winning -
	# however long, past the minimum hold. When the player stops gaining,
	# the better bird takes over within target_commit_s.
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var chase := make_bird(0.03, o + Vector3(0, 0, -40 * span), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, chase, "(setup) the chase is the target")
	var prize := make_bird(0.03, o + Vector3(2 * span, 0, -3 * span), Vector3.FORWARD)
	start_logging()
	# The gap closes by 0.9 wingspans a second: the player gains on it.
	var d := 40.0 * span
	var switched := false
	var committed_frames := 0
	var frames := int(9.0 / DT)
	for i in frames:
		d -= 0.9 * span * DT
		move(chase, o + Vector3(0, 0, -d), Vector3(0, 0, -1.0))
		p.velocity = Vector3(0, 0, -0.9 * span)
		loop.step(DT)
		# (Committed from the first 5% gain on: 2 wingspans, ~2.2 s here.)
		if loop.watch.target_committed or i * DT < 2.5:
			committed_frames += 1
		switched = switched or loop.watch.target != chase
	gt(loop.watch.target_min_hold_s, 3.9, "(setup) longer than the minimum hold")
	check(not switched, "a target the player keeps gaining on is never switched away (9 s, a bird 3x better beside it)")
	eq(committed_frames, frames, "committed while closing, from its first gain on")
	eq(count("target"), 0, "no target_changed while closing")
	# The player stops gaining (it matches the chase's speed): the better
	# bird takes over once the commitment runs out.
	var t_stop := 0.0
	var switched_after := -1.0
	for i in int(6.0 / DT):
		move(chase, o + Vector3(0, 0, -d), Vector3.ZERO)
		p.velocity = Vector3.ZERO
		loop.step(DT)
		t_stop += DT
		if loop.watch.target == prize and switched_after < 0.0:
			switched_after = t_stop
	metric("switched_after_stop_s", switched_after)
	gt(switched_after, 0.0, "once the player stops gaining, the better bird becomes the target")
	lt(switched_after, loop.watch.target_commit_s * sqrt(loop.watch.body_time) + 2.0 * DT,
			"...within the commitment window (%.2f s)" % switched_after)
	near(loop.watch.target_commit_s, 2.5, 1e-9, "commitment window (s x sqrt(body time))")


func test_a_big_players_commitment_lasts_longer() -> void:
	# The commitment window is in the square root of body time, like the
	# catch assist: an eagle closes on its prey slower in seconds, so after
	# it last gained on its target a better bird may take the cue only
	# target_commit_s x sqrt(4) = 5 s later (a sparrow: 2.5 s).
	var p := _player(3.0)
	loop.set_protection(p, 600.0)
	p.velocity = Vector3.ZERO
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var first := make_bird(0.85, o + Vector3(0, 0, -40 * span), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, first, "(setup) the gull is the target")
	near(loop.watch.body_time, 4.0, 1e-6, "(setup) an eagle's body time")
	# The eagle gains on the gull for 6 s (past the minimum hold)...
	var d := 40.0 * span
	for i in int(6.0 / DT):
		d -= 2.0 * span * DT
		move(first, o + Vector3(0, 0, -d), Vector3.ZERO)
		loop.step(DT)
	var prize := make_bird(0.85, o + Vector3(0, 0, -3 * span), Vector3.FORWARD)
	# ...then stops gaining: the better bird takes over 5 s after the last
	# gain, not before.
	var t := 0.0
	var switched_at := -1.0
	for i in int(8.0 / DT):
		loop.step(DT)
		t += DT
		if loop.watch.target == prize and switched_at < 0.0:
			switched_at = t
	metric("eagle_switched_after_stop_s", switched_at)
	between(switched_at, loop.watch.target_commit_s * 2.0 - 0.8, loop.watch.target_commit_s * 2.0 + 2.0 * DT,
			"an eagle's chase stays committed ~5 s after its last gain (%.2f s)" % switched_at)


func test_target_marker_does_not_hop() -> void:
	# A crowd of worthwhile prey milling about in front of the player, their
	# scores reshuffling all the time, some eaten by others now and then: the
	# marker changes rarely, and a rival never takes over less than the hold
	# time after the last change (only a target that became invalid is
	# replaced sooner). The live review found a quarter of switches within a
	# second of the previous one with the 0.6 s hold.
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var crowd: Array[SimBird] = []
	for i in 12:
		crowd.append(make_bird(0.03, o + Vector3(rng.randf_range(-8, 8) * span, rng.randf_range(-3, 3) * span,
				-rng.randf_range(6, 30) * span), Vector3.FORWARD))
	var switches: Array[float] = []
	var rival_quick := 0
	var last: Bird = loop.watch.target
	var t := 0.0
	for i in int(30.0 / DT):
		t += DT
		for k in crowd.size():
			var b := crowd[k]
			if b.alive:
				b.global_position += Vector3(sin(t * 1.3 + k), 0.3 * cos(t * 0.7 + k * 2.0), cos(t * 0.9 + k * 1.7)) * span * 3.0 * DT
		if i % int(4.0 / DT) == int(2.0 / DT):
			# Now and then someone else eats one (the current target, too).
			var victim: Bird = loop.watch.target if i % int(8.0 / DT) == int(2.0 / DT) and loop.watch.target != null else crowd[i % crowd.size()]
			victim.alive = false
		var valid_before: bool = last != null and last.alive
		loop.step(DT)
		if loop.watch.target != last:
			if not switches.is_empty() and t - switches[-1] < 1.5 - 1e-6 and valid_before:
				rival_quick += 1
			switches.append(t)
			last = loop.watch.target
	var within_1s := 0
	for k in range(1, switches.size()):
		if switches[k] - switches[k - 1] < 1.0:
			within_1s += 1
	metric("marker_switches", {"n": switches.size(), "within_1s": within_1s, "rival_within_hold": rival_quick})
	gt(float(switches.size()), 2.5, "(setup) the marker does move in 30 s of reshuffling")
	eq(rival_quick, 0, "a rival never takes over within the hold time of the last change")
	lt(float(within_1s), maxf(1.0, switches.size() * 0.1), "under 10% of switches come within 1 s of the previous one")


func test_target_cue_prefers_catchable_prey_below() -> void:
	# A near-equal bird (worth the most, but it escapes nearly every chase)
	# a little nearer, and a third-size bird: the cue points at the one the
	# player can catch. And of two equal birds at equal distance, the one
	# below (it can be dived on) beats the one above (it climbs away).
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var near_equal := make_bird(0.07, o + Vector3(0, 0, -6 * span), Vector3.FORWARD)
	var catchable := make_bird(0.03, o + Vector3(1 * span, 0, -8 * span), Vector3.FORWARD)
	loop.step(DT)
	check(SizeRules.meal_value(p.mass, near_equal.mass) > SizeRules.meal_value(p.mass, catchable.mass), "(setup) the near-equal is worth more")
	eq(loop.watch.target, catchable, "the cue points at the prey the player can catch")
	lt(ThreatWatch.chase_odds(0.78), 0.06, "near-equals are rated nearly hopeless (valley: 2-4% of chases)")
	lt(ThreatWatch.chase_odds(0.6), 0.15, "...from 0.6 of your mass")
	near(ThreatWatch.chase_odds(0.3), 1.0, 1e-6, "a third of your size: easy")
	# The cue's pick between a near-equal worth 2.4x more and a third-sized
	# bird at the same distance: the one it can catch.
	gt(SizeRules.meal_value(1.0, 0.33) * ThreatWatch.chase_odds(0.33), SizeRules.meal_value(1.0, 0.75) * ThreatWatch.chase_odds(0.75),
			"a catchable third beats a near-equal")
	await cleanup()
	p = _player(0.09)
	loop.set_protection(p, 600.0)
	o = p.get_body_position()
	var above := make_bird(0.03, o + Vector3(-1 * span, 8 * span, -10 * span), Vector3.FORWARD)
	var below := make_bird(0.03, o + Vector3(1 * span, -8 * span, -10 * span), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, below, "prey below beats the same prey above")
	gt(ThreatWatch.height_edge(8.0 * span, span), ThreatWatch.height_edge(-8.0 * span, span) * 1.5, "height edge")


func test_target_cue_skips_prey_sheltering_where_the_player_cannot_follow() -> void:
	# A sparrow that has dived into a hedge (a refuge too small for the
	# player) is no target, however good it looks; the next best bird is.
	# Found in the live-AI runs: the AI's prey hide in hedges, and a cue that
	# kept pointing at one held a modelled swallow there for 20 minutes.
	var world := RefugeWorld.new()
	add_child(world)
	var p := _player(0.09)  # the run start finds the world
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var hedge := o + Vector3(0, 0, -5 * span)
	# A hedge in front of the player (the world announces new refuges by
	# regenerating).
	world.refuges = [{"position": hedge, "radius": 1.0, "max_span": span * 0.8}]
	world.generated.emit()
	check(loop._refuge_index != null and loop.watch.refuge_index == loop._refuge_index,
			"one refuge index per world, shared by the catch pass and the target cue")
	var hidden := make_bird(0.03, hedge, Vector3.FORWARD)
	var open := make_bird(0.03, o + Vector3(2 * span, 0, -14 * span), Vector3.FORWARD)
	loop.step(DT)
	check(loop.is_sheltered(hidden, span), "(setup) the hidden sparrow is out of the player's reach")
	check(not loop.is_sheltered(open, span), "(setup) the other one is in the open")
	eq(loop.watch.target, open, "the cue points at the bird in the open, not the nearer one in the hedge")
	check(not loop.is_sheltered(hidden, span * 0.7), "a bird narrow enough to follow it in could still get it")
	# It leaves cover, and the other one is gone: now it is the target.
	hidden.global_position = o + Vector3(0, 0, -9 * span)
	loop.teleported(hidden)
	open.queue_free()
	birds.erase(open)
	await get_tree().process_frame
	loop.step(DT)
	eq(loop.watch.target, hidden, "out of cover it is a target again")
	world.queue_free()


func test_target_cue_names_only_prey_in_sight() -> void:
	# Prey behind the world's geometry (a house, a trunk, a crown: physics
	# layer 1) is never the target, however good it looks - the next best
	# bird in sight is. A target that slips behind something for less than
	# SIGHT_GRACE_S stays the target; one out of sight longer is dropped at
	# once. (In the valley two in three of a big player's chases ended with
	# the prey out of sight within seconds: a cue pointing behind a house
	# points at a chase already lost.)
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	var wall := _wall(o + Vector3(0, 0, -3 * span), Vector3(2 * span, 3 * span, 0.2))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var behind := make_bird(0.03, o + Vector3(0, 0, -6 * span), Vector3.FORWARD)
	# (Far enough that the bird behind the wall scores over
	# target_switch_ratio x it once in sight.)
	var clear := make_bird(0.03, o + Vector3(20 * span, 0, -35 * span), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, clear, "the cue names the bird in sight, not the better one behind the wall")
	# The wall goes: the better bird takes over (after the minimum hold).
	wall.free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	run_steps(int((loop.watch.target_min_hold_s + 0.3) / DT), DT)
	eq(loop.watch.target, behind, "in sight, the better bird is the target")
	# Something comes between (a trunk crossing the line): the target keeps
	# the ring for SIGHT_GRACE_S after it was last seen (core loop fix round
	# 1: dropped at once, the ring hopped off still-valid birds 4-13 times a
	# minute through the real chain), then is dropped at the next look.
	eq(ThreatWatch.SIGHT_GRACE_S, 2.0, "a target out of sight keeps the ring 2 s (literal)")
	var trunk := _wall(o + Vector3(0, 0, -3 * span), Vector3(2 * span, 3 * span, 0.2))
	await get_tree().physics_frame
	await get_tree().physics_frame
	run_steps(int((ThreatWatch.SIGHT_GRACE_S - 0.5) / DT), DT)
	eq(loop.watch.target, behind, "out of sight for less than the grace: still the target")
	run_steps(int((ThreatWatch.SIGHT_CACHE_S + 0.55) / DT), DT)
	eq(loop.watch.target, clear, "out of sight longer: dropped within a look for the bird in sight")
	eq(loop.watch.last_target_change, &"sight", "...for the line to it (sight)")
	trunk.free()
	# Open air (no physics space): everything is in sight.
	loop.sight_cue = false
	loop.step(DT)
	check(loop.watch.space == null, "without the sight cue the watch has no space to cast in")


func test_target_cue_names_only_prey_in_open_air() -> void:
	# Core loop round (the lead's direction: "only reachable prey is ever the
	# target cue/ring: require open-air line of sight and an approach path -
	# no committing to birds inside crowns/hedges"): a bird with the world's
	# geometry within ThreatWatch.reach_clear() of it (a crown, a hedge, a
	# wall it perches on - here a box beside it, the line to it clear) is
	# never the target however good it looks; the moment geometry comes
	# round the target it is dropped (at the next look); a bird in open air
	# is the target. Literal clearances: 1.2 m or 3 wingspans.
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var o := p.get_body_position()
	near(loop.watch.reach_clear(0.2), 1.2, 1e-9, "open air round a small player's target: 1.2 m")
	near(loop.watch.reach_clear(2.1), 6.3, 1e-9, "...an eagle's: 3 wingspans, 6.3 m")
	var clr := loop.watch.reach_clear(span)
	var crowned := make_bird(0.03, o + Vector3(0, 0, -6 * span), Vector3.FORWARD)
	# A crown beside it: its near face 0.6 of the clearance from the bird, off
	# the line of sight.
	var crown := _wall(crowned.global_position + Vector3(-(clr * 0.6 + 0.5), 0, 0), Vector3(1.0, 3.0, 3.0))
	var open := make_bird(0.03, o + Vector3(10 * span, 0, -40 * span), Vector3.FORWARD)
	await get_tree().physics_frame
	await get_tree().physics_frame
	loop.step(DT)
	eq(loop.watch.target, open, "the cue names the bird in open air, not the better one in the crown")
	run_steps(int((loop.watch.target_min_hold_s + 0.5) / DT), DT)
	eq(loop.watch.target, open, "...and never switches to it")
	# The crown goes (the bird is in the open): it is the better target.
	crown.free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	run_steps(int((loop.watch.target_min_hold_s + 0.5) / DT), DT)
	eq(loop.watch.target, crowned, "out of the crown, the better bird takes over")
	# Geometry brushing past (0.7 of the clearance from it): the target keeps
	# the ring (core loop fix round 1: the current target's open air is
	# TARGET_CLEAR_KEEP of the clearance).
	var brush := _wall(crowned.global_position + Vector3(0, clr * 0.7 + 0.5, 0), Vector3(3.0, 1.0, 3.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	run_steps(int((ThreatWatch.CLUTTER_GRACE_S + ThreatWatch.SIGHT_CACHE_S + 0.1) / DT), DT)
	eq(loop.watch.target, crowned, "geometry brushing past the target: it keeps the ring")
	brush.free()
	# Geometry comes round it (it perches in the next tree): dropped within
	# CLUTTER_GRACE_S (1.5 s) and a look.
	eq(ThreatWatch.CLUTTER_GRACE_S, 1.5, "a target in clutter keeps the ring at most 1.5 s (literal)")
	_wall(crowned.global_position + Vector3(0, clr * 0.3 + 0.5, 0), Vector3(3.0, 1.0, 3.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	run_steps(int((ThreatWatch.CLUTTER_GRACE_S + ThreatWatch.SIGHT_CACHE_S + 0.05) / DT), DT)
	eq(loop.watch.target, open, "geometry round the target: dropped within the grace and a look")
	eq(loop.watch.last_target_change, &"clutter", "...as out of open air (clutter)")


## Flies the player straight on at `v` for `secs` (the fixture's birds do
## not move by themselves), stepping the loop.
func _fly_player(p: SimBird, v: Vector3, secs: float) -> void:
	p.velocity = v
	for i in int(secs / DT):
		if not p.alive:
			return
		move(p, p.global_position + v * DT, v)
		loop.step(DT)


func test_the_magnet_draws_prey_onto_the_flight_line() -> void:
	# Core loop round (the lead's direction: "a gentle final-approach
	# magnetism when prey is inside a forward cone at close range; a catch
	# should feel like 'I flew into it', not a precision test"): prey the
	# player can eat, ahead within MAGNET_CONE_DEG (45) of its velocity and
	# within MAGNET_S (0.4 s) of flight / MAGNET_SPANS (12) of its wingspans
	# (at least MAGNET_MIN_M, 2.5 m), drifts towards the player's flight line
	# - never faster than MAGNET_PULL (0.4) of the player's speed. Literal.
	eq([GameLoop.MAGNET_S, GameLoop.MAGNET_SPANS, GameLoop.MAGNET_MIN_M, GameLoop.MAGNET_CONE_DEG, GameLoop.MAGNET_PULL],
			[0.4, 12.0, 2.5, 45.0, 0.4], "the magnet's numbers")
	var p := _player(0.03)
	var o := p.get_body_position()
	var v := Vector3(0, 0, -10)
	p.velocity = v
	# In the cone and in range (2.2 m ahead, 1.0 m aside): drawn in, at most
	# 0.4 x 10 m/s.
	var moth := make_bird(0.004, o + Vector3(1.0, 0, -2.2))
	loop.step(DT)
	var moved := 1.0 - moth.global_position.x
	gt(moved, 0.0, "a moth ahead in the cone drifts towards the flight line (%.3f m)" % moved)
	lt(moved, 0.4 * 10.0 * DT + 1e-6, "...no faster than 0.4 of the player's speed")
	near(moth.global_position.z, o.z - 2.2, 1e-6, "...sideways only: not pulled along the line")
	# Out of the cone (60 deg off), out of range (4 m ahead), perched, in
	# cover, protected, too big to eat: untouched.
	birds.erase(moth)
	moth.free()
	var off_cone := make_bird(0.004, o + Vector3(1.6, 0, -0.92))
	var far := make_bird(0.004, o + Vector3(0.5, 0, -4.0))
	var sitting := make_bird(0.004, o + Vector3(0.6, 0, -1.8))
	sitting.perched = true
	var guarded := make_bird(0.004, o + Vector3(-0.6, 0, -1.8))
	loop.set_protection(guarded, 5.0)
	var big := make_bird(0.03, o + Vector3(0, 0.6, -1.8))
	var still := {}
	for b: SimBird in [off_cone, far, sitting, guarded, big]:
		still[b] = b.global_position
	loop.step(DT)
	for b: SimBird in [off_cone, far, sitting, guarded, big]:
		check(b.global_position.is_equal_approx(still[b]), "untouched: %s" % b.name)
	for b: SimBird in [off_cone, far, sitting, guarded, big]:
		birds.erase(b)
	for b: SimBird in [off_cone, far, sitting, guarded, big]:
		b.free()
	# Flying on at a moth 1.2 m off its line - more than twice its reach: the
	# player takes it with the magnet...
	loop.set_protection(p, 60.0)
	var reach := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.004))
	lt(reach, 0.6, "(setup) the sparrow's reach for a moth: %.2f m" % reach)
	var m1 := make_bird(0.004, p.get_body_position() + Vector3(1.2, 0, -6.0))
	start_logging()
	_fly_player(p, v, 1.0)
	eq(count("caught"), 1, "flying straight on, the moth 1.2 m off the line is taken (the magnet)")
	stop_logging()
	# ...and without it, it is not.
	loop.magnet = false
	var m2 := make_bird(0.004, p.get_body_position() + Vector3(1.2, 0, -6.0))
	start_logging()
	_fly_player(p, v, 1.0)
	eq(count("caught"), 0, "without the magnet the same pass misses")
	check(m2.alive, "(the moth is still there)")
	stop_logging()
	if is_instance_valid(m1):
		m1.queue_free()


func test_highlight_range_hysteresis() -> void:
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var r := loop.watch.highlight_range(p.mass)
	var o := p.get_body_position()
	var prey := make_bird(0.03, o + Vector3(0, 0, -0.97 * r), Vector3.FORWARD, false, true)
	var place := func(k: float) -> void:
		prey.global_position = o + Vector3(0, 0, -k * r)
		loop.step(DT)
	place.call(0.97)
	eq(prey.model.highlight, 1, "inside the range: lit")
	place.call(1.10)
	eq(prey.model.highlight, 1, "lit birds stay lit out to 1.15x the range")
	place.call(1.18)
	eq(prey.model.highlight, 0, "beyond 1.15x: off")
	place.call(1.10)
	eq(prey.model.highlight, 0, "unlit birds must come inside the range to light up")
	# A bird wobbling +-4% around the edge: at most one change.
	var changes := 0
	var last: int = prey.model.highlight
	for i in 300:
		place.call(1.0 + 0.04 * sin(i * 0.7))
		if prey.model.highlight != last:
			changes += 1
			last = prey.model.highlight
	metric("edge_wobble_changes", changes)
	lt(float(changes), 1.5, "no flicker at the range edge (at most one change)")


func test_highlights_reassert_over_other_writers() -> void:
	# UI marks its target/threat with the same values; if anything writes a
	# stale value the loop's classification wins on the next frame.
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var o := p.get_body_position()
	var prey := make_bird(0.03, o + Vector3(0, 0, -10), Vector3.FORWARD, false, true)
	var dust := make_bird(0.004, o + Vector3(2, 0, -10), Vector3.FORWARD, false, true)
	var hawk := make_bird(1.3, o + Vector3(-2, 0, -20), Vector3.FORWARD, false, true)
	loop.step(DT)
	eq([prey.model.highlight, dust.model.highlight, hawk.model.highlight], [1, 0, 2], "(setup) classified")
	prey.model.highlight = 0
	dust.model.highlight = 2
	hawk.model.highlight = 1
	loop.step(DT)
	eq([prey.model.highlight, dust.model.highlight, hawk.model.highlight], [1, 0, 2],
			"stale values from another writer are corrected next frame")


func test_the_target_cue_follows_the_chase_in_whole_runs() -> void:
	# The cue in whole runs (the mirror sky, a competent modelled pilot that
	# follows the cue: IntegratedSim's "target_cue"). Fix round 5 review: at
	# 1.35x after 1.5 s the cue moved on from a still-valid bird ~9 times a
	# minute (median hold 2.2 s, 65% within 3 s), and a person following it
	# lost the chase. Now: rarely away from a bird the player is gaining on,
	# a target held for seconds, and few changes of a valid target at all.
	var sim := IntegratedSim.new()
	add_child(sim)
	await get_tree().process_frame
	var secs := 480.0
	var r: Dictionary = await sim.run(&"competent", 100, secs)
	var g: Dictionary = r["target_cue"]
	var minutes := secs / 60.0
	metric("target_cue_mirror", g)
	gt(float(r["catches"]), 5.0, "(setup) the pilot hunts and catches (%d)" % r["catches"])
	lt(float(g["voluntary_closing"]) / minutes, 0.5, "under 0.5 a minute away from a valid bird the player was gaining on (%d in %.0f min)" % [
			g["voluntary_closing"], minutes])
	lt(float(g["voluntary"]) / minutes, 3.0, "under 3 a minute away from a still-valid bird (%d)" % g["voluntary"])
	if int(g["voluntary"]) > 0:
		gt(float(g["hold_median_s"]), 5.0 - 1e-6, "a target is held a median 5 s or more before such a change (%.1f s)" % g["hold_median_s"])
	sim.queue_free()
	await get_tree().process_frame


# --- Pins of details (fix round 5 review: mutants that survived) -------------

func test_the_target_leaving_the_game_clears_the_cue_at_once() -> void:
	# A target bird that leaves the game (eaten elsewhere, despawned by the
	# Ecosystem) is cleared from the HUD as it leaves - target_changed(null)
	# before the next step - so no listener keeps a freed bird.
	var p := _player(0.09)
	loop.set_protection(p, 600.0)
	var span := p.get_wingspan()
	var prey := make_bird(0.03, p.get_body_position() + Vector3(0, 0, -10 * span), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.watch.target, prey, "(setup) the target")
	start_logging()
	birds.erase(prey)
	prey.free()  # leaves the tree: Birds.unregister -> Events.bird_removed
	var ev := events("target")
	eq(ev.size(), 1, "target_changed fires as the bird leaves, before the next step")
	check(ev.size() == 1 and ev[0][1] == null, "...naming nobody")
	check(loop.watch.target == null, "the watch's target is cleared")


func test_the_respawn_jump_is_not_swept() -> void:
	# Caught 2 m from the spawn point (under the loop's teleport threshold at
	# 72 Hz, 90 m/s x dt + 1 m = 2.25 m) with a prey bird on the line between:
	# put back at the spawn, the player must not catch what lay along the
	# jump - the respawn is a teleport, not a flight path.
	make_loop()
	var p := make_bird(0.09, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.09
	loop.opening_respite_s = 0.0
	loop.set_protection(p, 0.0)
	move(p, Vector3(0, 30, 2), Vector3.ZERO)
	loop.step(DT)
	var hunter := make_bird(1.3, Vector3(0, 30, 2.3), Vector3.FORWARD)
	loop.step(DT)
	check(not p.alive, "(setup) the player is caught 2 m from the spawn")
	birds.erase(hunter)
	hunter.free()
	var prey := make_bird(0.02, Vector3(0, 30, 1.0), Vector3.BACK)
	check(SizeRules.is_worthwhile(p.mass * (1.0 - loop.death_penalty()), prey.mass), "(setup) a meal the player would take")
	run_steps(int((GameLoop.CAUGHT_BEAT_S + 0.2) / DT), DT)
	check(p.alive, "(setup) respawned")
	near(p.get_body_position().distance_to(Vector3(0, 30, 0)), 0.0, 1e-4, "(setup) at the spawn point")
	run_steps(3, DT)
	check(prey.alive, "the bird on the line of the respawn jump is not caught")


## Moves a bird on its own physics tick at the default priority (as the
## player's flight and the AI's NPCs move).
class _Mover extends Node:
	var bird: SimBird
	var to := Vector3.ZERO
	var at_frame := -1
	var frame := 0

	func _physics_process(_dt: float) -> void:
		frame += 1
		if frame == at_frame:
			bird.global_position = to


func test_the_loop_runs_after_the_birds_moved() -> void:
	# GameLoop's process_physics_priority puts it after the birds in every
	# physics tick: a hunter moved into reach is caught in the same tick,
	# with this tick's positions.
	make_loop()
	loop.auto_step = true
	var hunter := make_bird(0.35, Vector3(0, 30, 1.5), Vector3.FORWARD)
	var prey := make_bird(0.09, Vector3(0, 30, -0.1), Vector3.FORWARD)
	var mover := _Mover.new()
	mover.bird = hunter
	mover.to = Vector3(0, 30, 0.1)
	mover.at_frame = 3
	add_child(mover)
	var dead_on := -1
	for f in 8:
		await get_tree().physics_frame
		if not prey.alive and dead_on < 0:
			dead_on = mover.frame
	metric("catch_seen_after_mover_frame", dead_on)
	eq(dead_on, 3, "the catch happens in the physics tick the hunter moved")
	mover.queue_free()
	loop.auto_step = false


func test_a_new_npc_is_uncatchable_for_its_first_second() -> void:
	# The Ecosystem spawns birds out of view, sometimes beside a predator: a
	# new NPC cannot be caught for npc_spawn_grace_s - 1 s by default (the
	# other tests set 0).
	make_loop()
	var d := GameLoop.new()
	loop.npc_spawn_grace_s = d.npc_spawn_grace_s
	d.free()
	var hunter := make_bird(0.5, Vector3(0, 30, 0), Vector3.FORWARD)
	hunter.velocity = Vector3.ZERO
	var prey := make_bird(0.1, Vector3(0, 30, -0.3), Vector3.FORWARD)
	prey.velocity = Vector3.ZERO
	var t := 0.0
	var caught_at := -1.0
	for i in int(1.5 / DT):
		loop.step(DT)
		t += DT
		if caught_at < 0.0 and not prey.alive:
			caught_at = t
	metric("new_npc_caught_after_s", caught_at)
	gt(caught_at, 1.0 - 1e-6, "not caught in its first second")
	lt(caught_at, 1.0 + 2.0 * DT, "...and caught once it is over")


# --- Threat cue never outlives its predator -----------------------------------

func _approach(p: SimBird, hawk: SimBird, seconds: float) -> void:
	for i in int(seconds / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)


func test_threat_cue_never_names_nobody() -> void:
	var emitted: Array = []
	# Validity is judged when the cue is emitted (a predator freed later
	# does not make an earlier cue wrong).
	var cb := func(lv: float, pr: Bird) -> void: emitted.append([lv, pr, pr != null and is_instance_valid(pr) and pr.alive])
	Events.threat_changed.connect(cb)
	var p := _player(0.03)
	loop.set_protection(p, 600.0)
	var o := p.get_body_position()
	# 1. The predator is despawned mid-approach (leaves the tree).
	var hawk := make_bird(1.3, o + Vector3(0, 0, -30), Vector3.BACK)
	hawk.velocity = Vector3(0, 0, 12)
	_approach(p, hawk, 1.6)
	var peak := loop.watch.level
	gt(peak, 0.3, "(setup) a real threat before the despawn")
	birds.erase(hawk)
	hawk.queue_free()
	await get_tree().process_frame
	loop.step(DT)
	eq(loop.watch.level, 0.0, "despawned predator: the cue ends at once")
	eq(loop.watch.predator, null, "no stale predator")
	eq(float(emitted[-1][0]), 0.0, "the last emission is exactly 0")
	# 2. The predator is eaten (alive = false) while a second one closes in:
	# the cue passes to the second at its own level, no dip to zero.
	var a := make_bird(1.3, o + Vector3(0, 0, -25), Vector3.BACK)
	a.velocity = Vector3(0, 0, 12)
	var b := make_bird(1.3, o + Vector3(6, 0, -34), Vector3.BACK)
	b.velocity = Vector3(0, 0, 11)
	for i in int(1.2 / DT):
		a.global_position += a.velocity * DT
		b.global_position += b.velocity * DT
		loop.step(DT)
	eq(loop.watch.predator, a, "(setup) the nearer hawk is named")
	var raw_b := loop.watch.threat_of(p, b, loop.rule)
	a.alive = false
	b.global_position += b.velocity * DT
	loop.step(DT)
	eq(loop.watch.predator, b, "the cue passes to the remaining predator")
	lt(loop.watch.level, raw_b + 0.05, "at no more than its own danger")
	gt(loop.watch.level, 0.0, "without dropping to zero first")
	for i in int(2.0 / DT):
		b.global_position += b.velocity * DT
		b.global_position.x += 0.4  # veers off
		loop.step(DT)
	var orphans := 0
	for e: Array in emitted:
		if float(e[0]) > 0.0 and not bool(e[2]):
			orphans += 1
	Events.threat_changed.disconnect(cb)
	metric("threat_emissions", emitted.size())
	eq(orphans, 0, "no threat_changed with a level above 0 and no live predator")


# --- Bookkeeping ----------------------------------------------------------------

func test_bookkeeping_does_not_leak_with_churn() -> void:
	# The AI frees and respawns NPCs all the time: the loop's per-bird tracks,
	# the watch's highlights and per-predator tracks must follow the live birds.
	var p := _player(0.3)
	loop.set_protection(p, 1e6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for round_ in 30:
		var batch: Array[SimBird] = []
		for i in 20:
			batch.append(make_bird(exp(rng.randf_range(log(0.03), log(3.0))),
					p.get_body_position() + Vector3(rng.randf_range(-20, 20), 0, rng.randf_range(-20, 20)), Vector3.FORWARD, false, true))
		run_steps(3, DT)
		for b in batch:
			birds.erase(b)
			b.queue_free()
		await get_tree().process_frame
	loop.step(DT)
	metric("after_churn", {"tracks": loop._tracks.size(), "highlights": loop.watch.highlights.size(), "threats": loop.watch._threats.size()})
	lt(float(loop._tracks.size()), 3.0, "the loop keeps tracks of live birds only (600 came and went)")
	lt(float(loop.watch.highlights.size()), 1.0, "no highlight entries for birds that left")
	lt(float(loop.watch._threats.size()), 1.0, "no per-predator threat track (geometry, smoothed level) for birds that left")
