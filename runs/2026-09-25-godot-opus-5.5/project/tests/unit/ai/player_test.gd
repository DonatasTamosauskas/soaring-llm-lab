extends "res://tests/unit/ai/ai_sim.gd"
## A7 The player is just another bird: the size rules decide. NPC predators
## that can eat the (mock) player hunt it and reach it; prey it can eat flee
## it; birds bigger than the player but smaller than 1.25x ignore it both
## ways; if the player outgrows a hawk the hawk flees. Outside of play
## (menus) or while the game loop marks it protected, NPCs leave it alone.

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
	add_child(player)
	player.moving = true
	player.path_center = Vector3.ZERO
	player.path_radius = 80.0
	player.path_height = 40.0
	player.speed = 10.0
	player.step(0.0)
	Game.state = Game.State.PLAYING


func after_each() -> void:
	for b in loose.duplicate():
		despawn(b)
	if is_instance_valid(player):
		remove_child(player)
		player.queue_free()
	checker = null
	Game.state = Game.State.BOOT
	await wait_frames(1)


func _run_with_player(seconds: float, per_tick: Callable = Callable()) -> void:
	run(seconds, func(i: int) -> bool:
		player.step(DT)
		return per_tick.call(i) if per_tick.is_valid() else false)


func test_predator_hunts_and_reaches_the_player() -> void:
	# A pigeon-sized player: edible for a hawk and worth it by the game's own
	# rule (SizeRules.is_worthwhile) - a starling-sized one is beneath it.
	player.mass = 0.35
	var hawk := spawn(&"hawk", player.global_position + Vector3(60, 15, 0), Vector3(-17, 0, 0), _open)
	hawk.hunger = 1.0
	hawk.can_flee = false
	make_checker()
	var m := {"hunt_t": -1.0, "reached": -1.0, "min_d": INF}
	_run_with_player(25.0, func(i: int) -> bool:
		if hawk.target == player and m["hunt_t"] < 0.0:
			m["hunt_t"] = i * DT
		m["min_d"] = minf(m["min_d"], hawk.global_position.distance_to(player.global_position))
		if player.caught_by == hawk and m["reached"] < 0.0:
			m["reached"] = i * DT
		return m["reached"] >= 0.0)
	check(m["hunt_t"] >= 0.0, "hawk chose the player as prey")
	lt(m["hunt_t"], 2.0, "within its first thinks")
	check(m["reached"] >= 0.0, "hawk reached the (non-evading) player")
	metric("hawk_vs_player", {"hunt_start_s": snappedf(m["hunt_t"], 0.01), "contact_s": snappedf(m["reached"], 0.01)})


## Worth, not only size: prey that is edible but not worth the chase
## (SizeRules.is_worthwhile) is ignored - the player included, and with the
## player in play and unprotected (the control: at pigeon size the same
## hawk goes for it at once).
func test_hunters_ignore_prey_not_worth_the_chase() -> void:
	var cases := [[&"hawk", 0.09, &"starling"], [&"eagle", 0.03, &"sparrow"], [&"gull", 0.012, &"wren"]]
	for cs in cases:
		var hunter_sp: StringName = cs[0]
		var small: float = cs[1]
		check(SizeRules.can_eat(SizeRules.species_data(hunter_sp)["mass"], small) and not SizeRules.is_worthwhile(SizeRules.species_data(hunter_sp)["mass"], small),
			"(setup) a %s can eat %.3f kg but it is not worth it" % [hunter_sp, small])
		player.mass = small
		player.moving = true
		player.set_meta(&"npc_ignore", false)
		var npc := spawn(cs[2], player.global_position + Vector3(20, 0, 0), Vector3(0, 0, -8), _open)
		npc.can_flee = false
		npc.can_hunt = false
		var hunter := spawn(hunter_sp, player.global_position + Vector3(50, 12, 0), Vector3(-15, 0, 0), _open)
		hunter.hunger = 1.0
		hunter.energy = 1.0
		hunter.can_flee = false
		var m := {"player": false, "npc": false}
		_run_with_player(4.0, func(_i: int) -> bool:
			if hunter.target == player:
				m["player"] = true
			if hunter.target == npc:
				m["npc"] = true
			return false)
		check(not m["player"], "a %s does not hunt a %.3f kg player (not worth it), in play and unprotected" % [hunter_sp, small])
		check(not m["npc"], "nor a %s NPC of that size" % cs[2])
		despawn(npc)
		despawn(hunter)
	# Control: the same hawk goes for a pigeon-sized player at once.
	player.mass = 0.35
	var hawk := spawn(&"hawk", player.global_position + Vector3(50, 12, 0), Vector3(-15, 0, 0), _open)
	hawk.hunger = 1.0
	hawk.can_flee = false
	var c := {"hunted": false}
	_run_with_player(3.0, func(_i: int) -> bool:
		if hawk.target == player:
			c["hunted"] = true
		return c["hunted"])
	check(c["hunted"], "control: a hawk hunts a pigeon-sized player")


func test_player_is_more_interesting_than_equal_npc_prey() -> void:
	# (pigeon-sized, see above) Same mass, both still in the air, the NPC a
	# little nearer: on worth over effort alone the hawk would take the NPC;
	# PLAYER_INTEREST ("maybe a little more interesting") tips it.
	player.mass = 0.35
	player.moving = false
	player.velocity = Vector3.ZERO
	player.global_position = Vector3(0, 40, 0)
	var npc := spawn(&"pigeon", Vector3(0, 40, 30), Vector3(0, 0, 0.01), _open)
	npc.mass = 0.35
	npc.velocity = Vector3.ZERO
	npc.can_flee = false
	npc.can_hunt = false
	# 5% nearer to the NPC than to the player.
	var hawk := spawn(&"hawk", Vector3(62, 40, 22), Vector3(-17, 0, 0), _open)
	hawk.hunger = 1.0
	check(hawk.global_position.distance_to(npc.global_position) < hawk.global_position.distance_to(player.global_position) * 0.97,
		"(setup) the NPC pigeon is the nearer of the two")
	hawk.brain._p = hawk.global_position  # (the brain's position is read at its update)
	var pick := hawk.brain._best_prey()
	eq(pick.get("bird"), player, "hawk rates the player above an identical, slightly nearer NPC pigeon")


func test_prey_flee_the_player() -> void:
	player.mass = 0.6  # crow-sized
	player.moving = false
	player.global_position = Vector3(0, 40, 60)
	var sparrow := spawn(&"sparrow", Vector3(0, 40, 0), Vector3(0, 0, 9), _open)
	sparrow.can_hunt = false
	sparrow.brain._goal = Vector3(0, 40, 600)
	sparrow.brain._goal_t = 0.0
	sparrow.brain._goal_life = 999.0
	sparrow.brain._goal_free = true
	var m := {"fled": false}
	run(4.0, func(_i: int) -> bool:
		# The player flies at the sparrow.
		player.global_position += Vector3(0, 0, -10.0) * DT
		player.velocity = Vector3(0, 0, -10)
		if sparrow.state == NpcBird.State.FLEE and sparrow.threat == player:
			m["fled"] = true
		return m["fled"])
	check(m["fled"], "sparrow fled the crow-sized player")


func test_near_equal_player_is_ignored_both_ways() -> void:
	player.mass = 0.1  # a starling's mass: neither can eat the other (EAT_RATIO 1.25, masses +-9%)
	player.moving = false
	player.global_position = Vector3(0, 40, 30)
	player.velocity = Vector3(0, 0, -9)
	var st := spawn(&"starling", Vector3(0, 40, 0), Vector3(0, 0, 9), _open)
	st.hunger = 1.0
	var m := {"reacted": false}
	run(3.0, func(_i: int) -> bool:
		player.global_position += player.velocity * DT
		if st.target == player or st.threat == player:
			m["reacted"] = true
		return false)
	check(not m["reacted"], "a starling neither hunts nor flees a near-equal player")


func test_player_bigger_than_hawk_makes_hawk_flee() -> void:
	player.mass = 2.5  # outgrew the hawk (at most 1.3 x 1.09 = 1.42 kg; 1.42 x 1.25 = 1.77)
	player.moving = false
	player.global_position = Vector3(0, 40, 50)
	var hawk := spawn(&"hawk", Vector3(0, 40, 0), Vector3(0, 0, 17), _open)
	hawk.hunger = 1.0
	hawk.brain._goal = Vector3(0, 40, 600)
	hawk.brain._goal_t = 0.0
	hawk.brain._goal_life = 999.0
	hawk.brain._goal_free = true
	var m := {"fled": false, "hunted": false}
	run(3.0, func(_i: int) -> bool:
		player.velocity = Vector3(0, 0, -14)
		player.global_position += player.velocity * DT
		if hawk.threat == player:
			m["fled"] = true
		if hawk.target == player:
			m["hunted"] = true
		return false)
	check(m["fled"], "hawk flees an eagle-sized player")
	check(not m["hunted"], "hawk never hunts a player it cannot eat")


func test_player_left_alone_outside_play_and_when_protected() -> void:
	player.mass = 0.35
	player.moving = false
	player.global_position = Vector3(0, 40, 0)
	var hawk := spawn(&"hawk", Vector3(50, 40, 0), Vector3(-17, 0, 0), _open)
	hawk.hunger = 1.0
	Game.state = Game.State.MENU
	var m := {"hunted": false}
	run(3.0, func(_i: int) -> bool:
		if hawk.target == player:
			m["hunted"] = true
		return false)
	check(not m["hunted"], "no hunting the player while in the menu")
	Game.state = Game.State.PLAYING
	player.set_meta(&"npc_ignore", true)
	run(3.0, func(_i: int) -> bool:
		if hawk.target == player:
			m["hunted"] = true
		return false)
	check(not m["hunted"], "no hunting a protected (respawning) player")
	player.set_meta(&"npc_ignore", false)
	# Bring the hawk back into range (it has wandered off meanwhile).
	hawk.global_position = Vector3(50, 40, 0)
	hawk.flight.set_velocity(Vector3(-17, 0, 0))
	hawk.hunger = 1.0
	hawk.energy = 1.0
	run(3.0, func(_i: int) -> bool:
		if hawk.target == player:
			m["hunted"] = true
		return m["hunted"])
	check(m["hunted"], "hunting resumes once play is on and protection ends")


## Danger comes in waves, not as a siege: a hunter whose chase on the
## player failed leaves it alone for NpcBrain.PLAYER_COOLDOWN_S (40 s) even
## with the player the only prey in reach - and takes it up again after.
## Also when it has eaten something else meanwhile (a meal used to clear
## the cool-down: a swallow, 15 s of digesting, was back after 33 s -
## found by the round-3 verifier's r3e_cooldown_meal probe).
func test_a_failed_hunter_leaves_the_player_alone_for_a_while() -> void:
	var rows := {}
	for c in [[&"hawk", 0.35, false], [&"swallow", 0.03, true], [&"hawk", 0.35, true]]:
		player.mass = c[1]
		player.protect_s = 0.0
		var hunter := spawn(c[0], player.global_position + Vector3(30, 8, 0), Vector3(-10, 0, 0), _open)
		hunter.can_flee = false
		# Something it eats in between (GameLoop calls on_ate after a catch).
		var snack := spawn(&"moth", Vector3(400, 60, 400), Vector3(0, 0, -3), _open)
		snack.can_flee = false
		snack.can_hunt = false
		var m := {"first": -1.0, "again": -1.0, "gave_up_at": -1.0}
		_run_with_player(75.0, func(i: int) -> bool:
			var t := i * DT
			hunter.hunger = 1.0
			hunter.energy = 1.0
			# Keep it in easy reach of the player (it wanders off otherwise).
			if hunter.global_position.distance_to(player.global_position) > 60.0:
				hunter.global_position = player.global_position + Vector3(30, 8, 0)
			if hunter.target == player:
				if m["first"] < 0.0:
					m["first"] = t
				elif m["gave_up_at"] >= 0.0 and m["again"] < 0.0:
					m["again"] = t
					return true
				if m["gave_up_at"] < 0.0 and t > m["first"] + 1.0:
					# The chase fails (as if it timed out).
					hunter.brain.give_up_reason = "timeout"
					hunter.brain._give_up_hunt()
					m["gave_up_at"] = t
					if c[2]:
						hunter.on_ate(snack, 0.0)
			return false)
		var tag := "%s%s" % [c[0], " after a meal" if c[2] else ""]
		check(m["first"] >= 0.0, "(setup) %s: went for the player" % tag)
		check(m["gave_up_at"] >= 0.0, "(setup) %s: and gave up" % tag)
		check(m["again"] >= 0.0, "%s: took the player up again later" % tag)
		# (40 s is the design value, stated here rather than read back from
		# NpcBrain: a test that reads the constant it checks checks nothing.)
		gt(float(m["again"]) - float(m["gave_up_at"]), 39.5, "%s: not before the 40-s cool-down had run out (s)" % tag)
		rows[tag] = snappedf(float(m["again"]) - float(m["gave_up_at"]), 0.1)
		despawn(hunter)
		despawn(snack)
	metric("retry_after_s", rows)


## Integration round 2: an attack on the PLAYER is a committed pass
## (NpcBrain.HUNT_PLAYER_REAIM / HUNT_PLAYER_TURN). Through the real chain a
## competent person evading from the threat cue was caught 3-4 times a run,
## always from behind after seconds of evading: a hunter steering by
## proportional navigation every tick homes on every correction a person
## makes ~0.35 s late. Here a swallow-sized player flies straight, a crow
## comes at it from behind, and the player breaks across the attack as a
## person does (the game loop's modelled player: 0.4 s before the strike, a
## 150 deg/s turn a sparrow-sized bird makes in the real chain after 0.25 s
## of reaction, a little down) - at several offsets and break timings. A
## break at the right moment makes the crow overshoot most of the time; the
## crow still catches a player that does not break (the control).
func test_an_attack_on_the_player_can_be_broken() -> void:
	var escapes := 0
	var trials := 0
	var rows := []
	for lat: float in [0.0, 1.5, 3.0]:
		for break_at: float in [0.3, 0.45, 0.6]:
			for breaks: bool in [true, false]:
				if not breaks and break_at != 0.45:
					continue
				var r := _attack_trial(lat, break_at, breaks)
				rows.append(r)
				if breaks:
					trials += 1
					escapes += 0 if r["caught"] else 1
				else:
					check(r["caught"], "control (lateral %.1f m): a player that does not break is caught (%s)" % [lat, r])
	metric("attack_breaks", {"escapes": escapes, "trials": trials, "rows": rows})
	gt(float(escapes) / trials, 0.5, "a well-timed break makes most attacks miss: %d of %d escaped" % [escapes, trials])


func _attack_trial(lat: float, break_at: float, breaks: bool) -> Dictionary:
	player.moving = false
	player.mass = 0.06
	player.set_meta(&"npc_ignore", false)
	player.caught_by = null
	var p0 := Vector3(0, 40, 0)
	player.global_position = p0
	var pv := Vector3(0, 0, -9.0)
	player.velocity = pv
	var crow := spawn(&"crow", p0 + Vector3(lat, 3.0, 45.0), Vector3(0, 0, -14.0), _open)
	crow.hunger = 1.0
	crow.can_flee = false
	make_checker()
	checker.reach = 0.15
	# The attack itself is the subject: the crow is set on the player at once
	# (whether and when a crow picks the player is test_predator_hunts...).
	check(crow.brain.begin_hunt(player), "(setup) the crow hunts the player")
	# (Lambdas capture locals by value: the player's velocity lives in the
	# dictionary too.)
	var st := {"broke_t": -1.0, "turning_left": 0.0, "caught": false, "hunted": false, "min_d": INF, "side": 1.0, "wait": -1.0,
		"pv": pv}
	run(12.0, func(i: int) -> bool:
		var t := i * DT
		if crow.target == player:
			st["hunted"] = true
		var rel := player.global_position - crow.global_position
		var d := rel.length()
		st["min_d"] = minf(st["min_d"], d)
		var closing := (crow.velocity - player.velocity).dot(rel / maxf(d, 1e-3))
		var tts := maxf(d - crow.strike_reach(), 0.0) / maxf(closing, 0.1)
		if breaks and st["broke_t"] < 0.0 and st["wait"] < 0.0 and st["hunted"] and closing > 0.5 and tts < break_at + 0.25:
			# Seen: the person reacts 0.25 s later, to the side it is on.
			st["wait"] = 0.25
			var cv := crow.velocity.normalized()
			var side := rel - cv * rel.dot(cv)
			st["side"] = 1.0 if side.x >= 0.0 else -1.0
		if st["wait"] >= 0.0 and st["broke_t"] < 0.0:
			st["wait"] -= DT
			if st["wait"] < 0.0:
				st["broke_t"] = t
				st["turning_left"] = 0.8
		var v: Vector3 = st["pv"]
		if st["turning_left"] > 0.0:
			st["turning_left"] -= DT
			var w: float = deg_to_rad(150.0) * DT * float(st["side"])
			v = v.rotated(Vector3.UP, -w)
			v.y = -1.5
		else:
			v.y = 0.0
		st["pv"] = v
		player.velocity = v
		player.global_position += v * DT
		if player.caught_by == crow:
			st["caught"] = true
			return true
		return st["broke_t"] >= 0.0 and t - float(st["broke_t"]) > 5.0)
	despawn(crow)
	return {"lat": lat, "break_at": break_at, "breaks": breaks, "hunted": st["hunted"], "caught": st["caught"],
		"heading_change_deg": snappedf(rad_to_deg(Vector3(0, 0, -1).angle_to(Vector3((st["pv"] as Vector3).x, 0.0, (st["pv"] as Vector3).z))), 1.0),
		"broke_t": snappedf(st["broke_t"], 0.01), "min_d": snappedf(st["min_d"], 0.01)}


func test_prey_notice_the_player_late_when_perched_or_about_their_business() -> void:
	# Core loop round (the lead's direction: prey fleeing the player are
	# "unaware when perched/feeding until close"): a bird notices the player
	# coming at it within its awareness only - x0.45 of it sitting on a
	# perch, x0.7 about its business in the open (wandering, flocking,
	# soaring) - and bolts FLEE_PLAYER_REACT_S (0.25 s) later than its own
	# reaction time. The player is held in front of the wren, coming at it,
	# just outside and just inside those ranges. Literal factors.
	eq([NpcBrain.PLAYER_AWARE_PERCHED, NpcBrain.PLAYER_AWARE_CALM, NpcBrain.FLEE_PLAYER_REACT_S], [0.45, 0.7, 0.25], "the numbers")
	player.mass = 0.03
	player.moving = false
	var aw: float = SpeciesProfile.of(&"wren")["awareness_m"]
	var react: float = SpeciesProfile.of(&"wren")["reaction_s"] + NpcBrain.FLEE_PLAYER_REACT_S
	var rows := {}
	for case in ["wander", "perched"]:
		var k := 0.7 if case == "wander" else 0.45
		for inside in [false, true]:
			var wren := spawn(&"wren", Vector3(0, 40, 0), Vector3(0, 0, -7), _open)
			wren.can_hunt = false
			if case == "perched":
				var perch := Perch.new(Vector3(0, 39.8, 0), Vector3.FORWARD, Perch.Kind.WIRE, 1.0)
				wren.land_on(perch, true)
				wren.set_state(NpcBird.State.PERCHED)
			else:
				wren.brain._goal = Vector3(0, 40, -600)
				wren.brain._goal_t = 0.0
				wren.brain._goal_life = 999.0
				wren.brain._goal_free = true
			var d := aw * k + (-1.5 if inside else 1.5)
			var m := {"flee_t": -1.0}
			var t := [0.0]
			run(2.0, func(_i: int) -> bool:
				t[0] += DT
				var fwd := wren.velocity.normalized() if wren.velocity.length() > 0.5 else -wren.global_basis.z
				player.global_position = wren.global_position + fwd * d
				player.velocity = -fwd * 8.0
				if wren.state == NpcBird.State.FLEE and wren.threat == player and float(m["flee_t"]) < 0.0:
					m["flee_t"] = t[0]
				return float(m["flee_t"]) >= 0.0)
			rows["%s_%s" % [case, "inside" if inside else "outside"]] = m["flee_t"]
			despawn(wren)
	metric("bolt_after_s", rows)
	eq(float(rows["wander_outside"]), -1.0, "a wandering wren does not notice the player just beyond 0.7 of its awareness")
	eq(float(rows["perched_outside"]), -1.0, "a perched one not just beyond 0.45 of it")
	for case in ["wander_inside", "perched_inside"]:
		between(float(rows[case]), react - 2.0 * DT, react + NpcBrain.THINK_S[0] + 3.0 * DT,
				"%s: it bolts its reaction time plus 0.25 s after the player comes into range (%.2f s)" % [case, rows[case]])


func test_prey_fleeing_the_player_flag_after_their_burst() -> void:
	# Core loop round (the lead's direction: "limited burst stamina - so a
	# committed chase usually succeeds against smaller-tier prey and sometimes
	# fails against near-equals"): a bird fleeing the player sprints for
	# flee_burst_s() - FLEE_PLAYER_BURST_S (2 s) x the square root of its body
	# time, x up to 1 + FLEE_PLAYER_NEAR_EQUAL (2.5) for a near-equal - then
	# flags at FLEE_PLAYER_FLAG_SPEED (0.8) of its cruise; the burst comes
	# back once the player is off its tail. Literal numbers.
	eq([NpcBrain.FLEE_PLAYER_BURST_S, NpcBrain.FLEE_PLAYER_NEAR_EQUAL, NpcBrain.FLEE_PLAYER_FLAG_SPEED], [2.0, 1.5, 0.8], "the numbers")
	player.mass = 0.03
	player.moving = false
	var wren := spawn(&"wren", Vector3(0, 60, 0), Vector3(0, 0, -7), _open)
	wren.can_hunt = false
	wren.energy = 1.0
	near(wren.brain.flee_burst_s(player), 2.0 * (1.0 + 1.5 * smoothstep(0.3, 0.7, wren.mass / 0.03)), 1e-6,
			"a wren fleeing a sparrow: a ~2.5 s burst (%.2f)" % wren.brain.flee_burst_s(player))
	lt(wren.brain.flee_burst_s(player), 2.6, "...short")
	var swallow := spawn(&"swallow", Vector3(0, 60, -300), Vector3(0, 0, -9), _open)
	var big := MockPlayer.new()
	big.mass = 0.08
	near(swallow.brain.flee_burst_s(big), 2.0 * sqrt(SizeRules.time_scale(swallow.mass)) * (1.0 + 1.5 * smoothstep(0.3, 0.7, swallow.mass / 0.08)),
			1e-6, "a swallow fleeing a near-equal: a longer burst (%.1f s)" % swallow.brain.flee_burst_s(big))
	gt(swallow.brain.flee_burst_s(big), 4.0, "...over twice the wren's")
	big.free()
	despawn(swallow)
	# The player chases the wren flat out (14 m/s, 6 m behind it).
	player.global_position = wren.global_position + Vector3(0, 0, 6)
	var m := {"flee_t": -1.0, "sprint": 0.0, "late_speed": 0.0, "late_n": 0}
	var t := [0.0]
	run(7.0, func(_i: int) -> bool:
		t[0] += DT
		var to := wren.global_position - player.global_position
		player.velocity = to.normalized() * 14.0
		player.global_position += player.velocity * DT
		if to.length() < 3.0:
			player.global_position = wren.global_position - to.normalized() * 3.0
		if wren.state == NpcBird.State.FLEE and float(m["flee_t"]) < 0.0:
			m["flee_t"] = t[0]
		if float(m["flee_t"]) >= 0.0:
			var since: float = t[0] - float(m["flee_t"])
			if since < 1.8:
				m["sprint"] = maxf(float(m["sprint"]), wren.velocity.length())
			elif since > 3.5:
				m["late_speed"] = float(m["late_speed"]) + wren.velocity.length()
				m["late_n"] = int(m["late_n"]) + 1
		return false)
	gt(float(m["flee_t"]), 0.0, "(setup) the wren fled the player")
	var cruise := wren.flight.cruise
	var late := float(m["late_speed"]) / maxf(float(m["late_n"]), 1.0)
	metric("flagging", {"sprint": m["sprint"], "late_mean": late, "cruise": cruise})
	gt(float(m["sprint"]), cruise * 1.05, "it sprints away at first (%.1f m/s, cruise %.1f)" % [m["sprint"], cruise])
	check(wren.brain.flagging(), "past its burst it is flagging")
	lt(late, cruise * 0.8 + 0.6, "...and flies at ~0.8 of its cruise (%.1f m/s)" % late)
	# The player leaves: the burst comes back (at half real time).
	player.global_position = Vector3(0, 60, 2000)
	player.velocity = Vector3.ZERO
	run(20.0)
	lt(wren.brain.flee_burst_used, 0.5, "off its tail, its burst comes back (%.2f s used)" % wren.brain.flee_burst_used)
