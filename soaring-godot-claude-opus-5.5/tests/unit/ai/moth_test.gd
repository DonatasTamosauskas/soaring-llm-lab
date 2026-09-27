extends "res://tests/unit/ai/ai_sim.gd"
## The core loop round's additions to the sky (the lead's direction, "agar.io
## in the sky"):
##  * moth swarms - the pellets: plentiful, slow, drifting in open air along
##    the player's path, barely fleeing (MothSwarm, MothField);
##  * the catch lesson's prey: an unaware swarm placed ahead of the player
##    (Ecosystem.request_lesson_prey);
##  * the danger director's attacker (Ecosystem.send_attacker).

var _open: World
var player: Bird


func before_all() -> void:
	_open = await make_open_world()


func after_all() -> void:
	await clear_sim()
	if is_instance_valid(_open):
		_open.queue_free()
	Game.state = Game.State.BOOT


func before_each() -> void:
	player = MockPlayer.new()
	player.mass = 0.03
	player.species = &"sparrow"
	add_child(player)
	player.moving = false
	player.global_position = Vector3(0, 40, 0)
	Game.state = Game.State.PLAYING


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	if is_instance_valid(player):
		remove_child(player)
		player.queue_free()
	if eco != null and is_instance_valid(eco):
		eco.queue_free()
	eco = null
	Game.state = Game.State.BOOT
	await wait_frames(2)


func _swarm(at: Vector3, lesson := false) -> MothSwarm:
	var s := MothSwarm.new(7)
	s.lesson = lesson
	add_child(s)
	s.place(at, 6, 0.004)
	return s


func test_a_swarm_drifts_slowly_round_its_anchor() -> void:
	# Six moths in a loose cloud round a centre that wanders within ANCHOR_R
	# of the anchor; no moth ever flies faster than MOTH_SPEED unless it
	# darts, or strays beyond the cloud's reach. Literal numbers.
	eq([MothSwarm.RADIUS, MothSwarm.ANCHOR_R, MothSwarm.MOTH_SPEED], [2.6, 4.0, 2.2], "the swarm's numbers")
	var at := Vector3(0, 40, -100)
	var s := _swarm(at)
	eq(s.alive_count(), 6, "six moths")
	for mo in s.moths:
		check(mo is Bird and Birds.all().has(mo), "a moth is a Bird in the registry (the catch rule, the cue and NPCs see it)")
		eq(mo.species, &"moth", "...a moth")
	var max_d := 0.0
	var max_v := 0.0
	for i in int(60.0 / DT):
		s.step(DT)
		for mo in s.moths:
			max_d = maxf(max_d, mo.global_position.distance_to(at))
			max_v = maxf(max_v, mo.velocity.length())
	metric("swarm_drift", {"max_from_anchor_m": max_d, "max_speed": max_v})
	lt(max_d, MothSwarm.ANCHOR_R + MothSwarm.RADIUS + MothSwarm.FLUTTER_M * 2.0 + 0.5, "the moths stay round the anchor (%.1f m)" % max_d)
	lt(max_v, MothSwarm.MOTH_SPEED + 1e-3, "no moth faster than 2.2 m/s (%.2f): the player takes them by flying into them" % max_v)
	s.queue_free()


func test_a_moth_barely_flees() -> void:
	# "Barely fleeing": a moth darts from a bird that can eat it only once
	# it has been within AWARE_M (2.5 m) and coming at it for REACT_S
	# (0.35 s), for DART_S at DART_SPEED, and not again for DART_COOL_S (its
	# stamina). A sparrow-sized bird flying straight through at 10 m/s covers
	# the 2.5 m in 0.25 s: no time to dart. A lesson swarm never darts.
	eq([MothSwarm.AWARE_M, MothSwarm.REACT_S, MothSwarm.DART_S, MothSwarm.DART_SPEED, MothSwarm.DART_COOL_S],
			[2.5, 0.35, 0.45, 3.5, 4.0], "the dart's numbers")
	var at := Vector3(0, 40, -50)
	var s := _swarm(at)
	for i in 30:
		s.step(DT)
	var mo := s.moths[0]
	# A bird coming at it slowly (2 m/s closing from 2.4 m): it darts after
	# the reaction time.
	player.global_position = mo.global_position + Vector3(0, 0, 2.4)
	player.velocity = Vector3(0, 0, -2.0)
	var darted_at := -1.0
	var t := 0.0
	for i in int(1.5 / DT):
		t += DT
		player.global_position = mo.global_position + Vector3(0, 0, 2.3)
		s.step(DT)
		if darted_at < 0.0 and mo.dart_left > 0.0:
			darted_at = t
	between(darted_at, MothSwarm.REACT_S - 2.0 * DT, MothSwarm.REACT_S + MothSwarm.LOOK_EVERY * DT + 2.0 * DT,
			"a moth with a bird 2.3 m off coming at it darts after its reaction time (%.2f s)" % darted_at)
	eq(mo.threat, null, "(the dart is over)")
	# ...and not again for DART_COOL_S.
	var again := false
	for i in int((MothSwarm.DART_COOL_S - 1.2) / DT):
		player.global_position = mo.global_position + Vector3(0, 0, 2.3)
		s.step(DT)
		again = again or mo.dart_left > 0.0
	check(not again, "no second dart within its stamina's cool-down")
	# A bird flying straight through at 10 m/s: no dart before it is there.
	var m2 := s.moths[1]
	player.global_position = m2.global_position + Vector3(0, 0, 3.0)
	player.velocity = Vector3(0, 0, -10.0)
	var dart2 := false
	for i in int(0.3 / DT):
		player.global_position += Vector3(0, 0, -10.0) * DT
		s.step(DT)
		dart2 = dart2 or m2.dart_left > 0.0
	check(not dart2, "a bird flying straight at it at 10 m/s arrives before the moth can dart")
	s.queue_free()
	# A lesson swarm: never.
	var ls := _swarm(at + Vector3(0, 0, -30), true)
	for i in 30:
		ls.step(DT)
	var lm := ls.moths[0]
	var dl := false
	for i in int(3.0 / DT):
		player.global_position = lm.global_position + Vector3(0, 0, 1.5)
		player.velocity = Vector3(0, 0, -2.0)
		ls.step(DT)
		dl = dl or lm.dart_left > 0.0
	check(not dl, "a lesson moth never darts")
	ls.queue_free()


func test_the_field_keeps_pellets_along_the_players_path() -> void:
	# The Ecosystem's MothField keeps swarms_for(budget) swarms (5 at 60 NPCs,
	# 4 at the Quest's 28) of 8 moths about a sparrow-sized player, in open air, never
	# nearer than PLACE_MIN_M (40 m) and, where the player looks, only beyond
	# the reach of its moths' marks; as it travels they are placed again
	# ahead of it. Once moths are beneath it (not worth the chase: at 60 g)
	# one swarm is left, for life and for the sky's wrens.
	eq([MothField.swarms_for(60), MothField.swarms_for(28), MothField.swarms_for(20)], [5, 4, 4], "swarms per budget")
	var e := make_eco(60, 3)
	e.focus = player
	player.moving = true
	player.travel = true
	player.line_a = Vector3(-400, 40, 0)
	player.line_b = Vector3(400, 40, 0)
	player.speed = 10.0
	player.step(0.0)
	var worst_near := [INF]
	var ahead_share := [0, 0]
	var in_view_near := [0]
	run(40.0, func(_i: int) -> bool:
		player.step(DT)
		if e.moths != null:
			for s in e.moths.swarms:
				if s.age <= DT * 1.01:
					# Just placed: where, from the player?
					var rel := s.anchor - player.get_body_position()
					var d := rel.length()
					worst_near[0] = minf(worst_near[0], d)
					# (In the view cone - looking where it flies, as the mock
					# player does - nearer than its moths' marks show.)
					var vd := player.velocity.normalized()
					if d < MothField.marks_range(player.mass) and vd.dot(rel / d) > cos(deg_to_rad(e.view_half_angle_deg)):
						in_view_near[0] += 1
					ahead_share[1] += 1
					if rel.dot(player.velocity) > 0.0:
						ahead_share[0] += 1
		return false)
	check(e.moths != null, "the Ecosystem has a moth field")
	eq(e.moths.swarms.size(), 5, "five swarms about a sparrow-sized player")
	gt(e.moths.moth_count(), 30.0, "...with their moths (%d)" % e.moths.moth_count())
	gt(float(e.moths.stats()["placed"]), 5.0, "swarms were placed again as the player travelled (%d)" % e.moths.stats()["placed"])
	gt(worst_near[0], MothField.PLACE_MIN_M - 1.0, "never placed nearer than 40 m (%.0f m)" % worst_near[0])
	lt(worst_near[0], 1e6, "(setup) placements were seen")
	eq(in_view_near[0], 0, "never placed in the view cone nearer than its marks show")
	gt(float(ahead_share[0]) / maxf(ahead_share[1], 1.0), 0.6, "most swarms are placed ahead of the travelling player (%d of %d)" % ahead_share)
	for s in e.moths.swarms:
		check(not e.habitat.blocked(s.anchor, MothSwarm.RADIUS), "a swarm's anchor is in open air")
	# Outgrown: one swarm left.
	player.mass = 0.06
	run(3.0, func(_i: int) -> bool:
		player.step(DT)
		return false)
	eq(e.moths.swarms.size(), MothField.AMBIENT, "a 60 g player (moths beneath it): one swarm left")


func test_the_lesson_prey_waits_ahead_of_the_player() -> void:
	# The catch lesson's prey (GameLoop.request_lesson_prey ->
	# Ecosystem.request_lesson_prey): five unaware moths LESSON_AHEAD_M (45 m)
	# ahead of the player's flight at its height, in open air; asked again
	# (the UI's help), 12 m nearer; placed ahead again when the player has
	# flown past or away; gone with stop_lesson_prey.
	eq([MothField.LESSON_AHEAD_M, MothField.LESSON_HELP_M, MothField.LESSON_SIZE], [45.0, 12.0, 5], "the lesson's numbers")
	var e := make_eco(60, 5)
	e.focus = player
	player.moving = false
	player.global_position = Vector3(0, 12, 0)
	player.velocity = Vector3(0, 0, -9)
	run(1.0)
	var got := e.request_lesson_prey(player.get_body_position(), player.velocity)
	eq(got.size(), 5, "five lesson moths")
	var ls := e.moths.lesson_swarm
	check(ls != null and ls.lesson, "an unaware lesson swarm")
	var rel := ls.anchor - player.get_body_position()
	near(rel.length(), 45.0, 1.5, "45 m out (%.1f)" % rel.length())
	gt(rel.normalized().dot(Vector3.FORWARD), 0.95, "straight ahead of the flight")
	near(ls.anchor.y, 12.0, 0.5, "at the player's height")
	# Help: nearer.
	e.request_lesson_prey(player.get_body_position(), player.velocity, 2)
	near((e.moths.lesson_swarm.anchor - player.get_body_position()).length(), 21.0, 1.5, "asked twice more: 24 m nearer")
	# The player turns round and flies off: the swarm is put ahead again.
	player.velocity = Vector3(0, 0, 9)
	var moved := [false]
	run(4.0, func(_i: int) -> bool:
		player.global_position += player.velocity * DT
		moved[0] = moved[0] or (e.moths.lesson_swarm.anchor - player.get_body_position()).dot(player.velocity) > 0.0
		return moved[0])
	check(moved[0], "flown away from: placed ahead again")
	e.stop_lesson_prey()
	await wait_frames(1)
	check(e.moths.lesson_swarm == null, "stopped: the lesson swarm is gone")


func test_a_high_player_still_gets_its_lesson_ringed() -> void:
	# Core loop fix round 1 (the onboarding verifier): a player cruising 80 m
	# up had its lesson moths kept 13-19 m above the ground, 61-67 m away -
	# out of a sparrow's 54 m target range: no ring, no arrow, and the lesson
	# could only time out. Now the swarm comes up to LESSON_MAX_AGL (40 m),
	# its moths carry `lesson`, and while the lesson runs the target cue
	# rings one out to ThreatWatch.LESSON_RANGE_M - over any other prey.
	var e := make_eco(60, 5)
	e.focus = player
	player.moving = false
	var top := Habitat.for_world(_open).top(0.0, 0.0)
	player.global_position = Vector3(0, top + 80.0, 0)
	player.velocity = Vector3(0, 0, -9)
	run(1.0)
	var got := e.request_lesson_prey(player.get_body_position(), player.velocity)
	eq(got.size(), 5, "five lesson moths")
	var ls := e.moths.lesson_swarm
	between(ls.anchor.y - top, MothField.HEIGHT.x - 0.1, MothField.LESSON_MAX_AGL + 0.1, "the swarm up to %.0f m above the ground (%.1f m)" % [
		MothField.LESSON_MAX_AGL, ls.anchor.y - top])
	gt(ls.anchor.y - top, 30.0, "...near the player's height (%.1f m up)" % [ls.anchor.y - top])
	check(got.all(func(b: Bird) -> bool: return b.get(&"lesson") == true), "the lesson's moths say so")
	var d := ls.anchor.distance_to(player.get_body_position())
	var w := ThreatWatch.new()
	gt(d, w.target_range(player.mass), "(setup) beyond a sparrow's usual target range (%.0f m > %.0f m)" % [d, w.target_range(player.mass)])
	# A wren near the player, in range, would be the ring's pick otherwise.
	var wren := spawn(&"wren", player.get_body_position() + Vector3(4, -2, -12))
	var all: Array[Bird] = []
	for b in Birds.all():
		all.append(b)
	w.update(player, all, 1.0 / 72.0, CatchRule.new(), false)
	check(w.target != null and w.target.get(&"lesson") != true, "(setup) without the lesson on, the ring is on other prey (%s)" % [
			w.target.species if w.target else "none"])
	w.lesson_active = true
	w.update(player, all, 1.0 / 72.0, CatchRule.new(), false)
	check(w.target != null and w.target.get(&"lesson") == true, "with the lesson on, the ring is on a lesson moth at once (%s)" % [
			w.target.species if w.target else "none"])
	despawn(wren)
	e.stop_lesson_prey()


func test_the_sky_sends_an_attacker() -> void:
	# The danger director's call (GameLoop._direct_danger ->
	# Ecosystem.send_attacker): a bird that would hunt the player, between
	# ATTACK_MIN_M and its hunting range, the one nearest ATTACK_BEST_M, is
	# sent at it (it hunts the player); none in range: one of the plan's
	# hunters is brought in out of view and sent.
	var e := make_eco(60, 11)
	e.focus = player
	player.moving = false
	player.global_position = Vector3(0, 40, 0)
	player.velocity = Vector3(0, 0, -9)
	player.set_meta(&"npc_ignore", true)
	run(3.0)
	player.set_meta(&"npc_ignore", false)
	var q := e.send_attacker(player)
	check(q != null, "an attacker was sent")
	if q == null:
		return
	check(Ecosystem.would_hunt(q.species, q.mass, player.mass) and SizeRules.can_eat(q.mass, player.mass), "...one that would hunt the player (%s)" % q.species)
	eq(q.state, NpcBird.State.HUNT, "...hunting")
	eq(q.target, player, "...the player")
	var d := q.global_position.distance_to(player.get_body_position())
	gt(d, Ecosystem.ATTACK_MIN_M - 1e-3, "...from at least 22 m (%.0f m)" % d)
	eq(int(e.stats()["attacks_sent"]), 1, "counted")
	# Nobody in range (every would-be hunter far off): one is brought in.
	for npc in e.get_npcs():
		if Ecosystem.would_hunt(npc.species, npc.mass, player.mass) and SizeRules.can_eat(npc.mass, player.mass):
			npc.brain._drop_target()
			npc.set_state(NpcBird.State.WANDER)
			npc.global_position = player.get_body_position() + Vector3(0, 0, 900)
	var n0 := e.count()
	var q2 := e.send_attacker(player)
	check(q2 != null and q2 != q, "none in range: a new one is brought in and sent")
	if q2 != null:
		eq(q2.target, player, "...hunting the player")
		check(not e.spawn_visible(q2.global_position, q2.get_wingspan(), player), "...from out of view (unnoticeable where it appeared)")
		lt(float(e.count()), float(n0) + 1.5, "...within the budget (%d -> %d)" % [n0, e.count()])
	# No bird that would hunt the player anywhere to send or swap, the sky
	# full (core loop round, second pass: the director found nobody for a
	# minute and more): the farthest idle bird out of view makes room, and
	# the one brought in would hunt the player. (The sky lives past the
	# spawn grace first: a bird is not recycled in its first 12 s.)
	player.set_meta(&"npc_ignore", true)
	run(e.recycle_grace_s)
	player.set_meta(&"npc_ignore", false)
	for npc in e.get_npcs():
		if Ecosystem.would_hunt(npc.species, npc.mass, player.mass) and SizeRules.can_eat(npc.mass, player.mass):
			npc.hidden = true
	var n1 := e.count()
	eq(n1, e.max_npcs, "(setup) the sky is full")
	var q3 := e.send_attacker(player)
	check(q3 != null and q3 != q2, "nobody to send or swap, the sky full: room is made and a hunter brought in (%s)" % e.last_attack_fail)
	if q3 != null:
		eq(q3.target, player, "...hunting the player")
		check(Ecosystem.would_hunt(q3.species, q3.mass, player.mass), "...one that would hunt it (%s)" % q3.species)
		lt(float(e.count()), float(n1) + 0.5, "...within the budget (%d -> %d)" % [n1, e.count()])


func test_a_show_hunt_takes_a_moth_where_the_player_looks() -> void:
	# Core loop round (the lead's direction: "the sky alive in view -
	# predation witnessed a few times per session"): the Ecosystem's show
	# hunts may set a wren (or any bird that would hunt a moth) on a swarm
	# moth where the player looks - and, while the game loop keeps the sky
	# off the player (meta npc_ignore), on any prey with any hunter.
	var e := make_eco(60, 21)
	e.focus = player
	player.moving = false
	player.global_position = Vector3(0, 30, 0)
	player.velocity = Vector3(0, 0, -9)
	player.view_dir = Vector3.FORWARD
	run(2.0)
	# A swarm 30 m ahead in the gaze, a wren 20 m beside it.
	var s := e.moths.swarms[0]
	s.place(Vector3(0, 30, -30), 8, 0.004)
	var wren := spawn(&"wren", Vector3(15, 30, -30), Vector3(0, 0, -7), _open)
	wren.hunger = 1.0
	# (The Ecosystem ticks it from now on, not the test's loop.)
	loose.erase(wren)
	e._npcs.append(wren)
	e._npc_key[wren.get_instance_id()] = &"wren"
	e._show_hunt_t = Ecosystem.SHOW_HUNT_S - 0.1
	var hunted: Array = [null]
	run(3.0, func(_i: int) -> bool:
		if e._show_hunter != null and is_instance_valid(e._show_hunter) and e._show_hunter.target is SwarmMoth:
			hunted[0] = e._show_hunter.target
		return hunted[0] != null)
	check(hunted[0] != null, "a show hunt on a swarm moth where the player looks (misses: %s)" % [e.stats()["show_hunt_misses"]])
	e._npcs.erase(wren)
	despawn(wren)
