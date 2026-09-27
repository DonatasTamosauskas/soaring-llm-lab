extends "res://tests/unit/game/game_fixture.gd"
## G1 / G4 / G6 — the danger half of the loop, and the simulations it is tuned
## with:
##  * the sims fly the AI's physics: no bird (and no simulated player) holds
##    more than its species' sprint in level flight - the fault that made the
##    first sims' player escape ~99.9% of attacks;
##  * the sims' NPCs hunt and flee like the AI's: SimBrains duels in the AI
##    area's own duel setup land on the AI's measured catch rates;
##  * being caught is real and avoidable: an unaware player is caught by a
##    committed hunter, evading players escape more the better they are;
##  * the loop's player-side danger rules: strikes on the player must
##    connect (reach, cone, no lunge-overlap), a missed pass gives escape
##    grace, the threat cue warns earlier for bigger (slower-turning) birds.

const DT := 1.0 / 72.0


func _player(mass: float) -> SimBird:
	make_loop()
	# Single attacks: no first-flight respite (test_first_flight_respite).
	loop.opening_respite_s = 0.0
	var p := make_bird(mass, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = mass
	loop.set_protection(p, 0.0)
	loop.step(DT)
	return p


# --- The simulations' physics and behaviour ------------------------------------

func test_sim_birds_fly_the_ai_envelope() -> void:
	# Level flight at full effort settles on the AI's sprint (AiMirror,
	# measured from NpcFlight), for NPCs and the tireless player alike, and
	# asking for more speed does not give more.
	var worst := 0.0
	for id in [&"sparrow", &"pigeon", &"hawk", &"eagle"]:
		for as_player in [false, true]:
			var m: float = SizeRules.species_data(id)["mass"]
			var b := make_bird(m, Vector3(0, 500, 0), Vector3.FORWARD, as_player)
			b.species = id
			b.energy = 1.0
			b.speed = b.cruise_speed()
			b.set_heading(Vector3.FORWARD)
			for i in 300:
				b.fly(Vector3.FORWARD, b.max_speed(), 1.0 / 30.0)
			var ratio := b.speed / b.cruise_speed()
			var want := AiMirror.sprint_ratio(m)
			worst = maxf(worst, absf(ratio / want - 1.0))
			near(ratio, want, want * 0.02, "%s%s: level sprint = the AI's (x cruise)" % [id, " (player)" if as_player else ""])
			lt(ratio, 1.33, "%s: no level flight faster than 1.33 x cruise" % id)
	metric("sprint_worst_rel_error", worst)
	# A tucked vertical stoop reaches the dive limit; spread wings do not.
	var h := make_bird(1.3, Vector3(0, 3000, 0), Vector3.DOWN)
	h.species = &"hawk"
	h.speed = h.cruise_speed()
	h.set_heading(Vector3.DOWN)
	for i in 900:
		h.fly(Vector3.DOWN, h.max_speed(), 1.0 / 30.0, 1.0, 0.4, 1.0)
	gt(h.speed, h.max_speed() * 0.9, "tucked stoop reaches > 90% of max_speed")
	# Energy: an NPC sprinting flat out tires (effort capped), the player never.
	var npc := make_bird(0.03, Vector3(50, 500, 0), Vector3.FORWARD)
	npc.energy = 0.8
	var pl := make_bird(0.03, Vector3(-50, 500, 0), Vector3.FORWARD, true)
	pl.energy = 0.8
	for i in 900:
		npc.fly(Vector3.FORWARD, npc.max_speed(), 1.0 / 30.0)
		pl.fly(Vector3.FORWARD, pl.max_speed(), 1.0 / 30.0)
	lt(npc.energy, 0.5, "30 s of sprinting drains an NPC")
	lt(npc.speed, npc.sprint_speed() * 0.97, "...and slows it")
	near(pl.energy, 0.8, 1e-6, "the player's bird is tireless")


func test_mirror_duels_match_the_ai() -> void:
	# The AI area's hunt_duel_test setup with SimBrains on both sides, judged
	# by the AI test's strict stand-in rule: the rates must be the AI's.
	var lab := ChaseLab.new()
	add_child(lab)
	await get_tree().process_frame
	var flee := lab.measure_duels(true, true, AiMirror.DUEL_TRIALS)
	var calm := lab.measure_duels(false, true, AiMirror.DUEL_TRIALS)
	var ai_flee := 0.0
	var ai_calm := 0.0
	for i in AiMirror.DUEL_PAIRS.size():
		ai_flee += AiMirror.DUEL_FLEE[i] / AiMirror.DUEL_PAIRS.size()
		ai_calm += AiMirror.DUEL_CALM[i] / AiMirror.DUEL_PAIRS.size()
	metric("duels_flee", flee)
	metric("duels_calm_overall", calm["overall"])
	near(float(flee["overall"]), ai_flee, 0.12, "mirror vs AI: overall catch rate against fleeing prey")
	gt(float(calm["overall"]), 0.85, "mirror: hunters catch prey that does not flee (AI %.2f)" % ai_calm)
	var stoop_catches := 0
	for i in AiMirror.DUEL_PAIRS.size():
		var pr: Array = AiMirror.DUEL_PAIRS[i]
		var k := "%s>%s" % [pr[0], pr[1]]
		var r: Dictionary = flee["pairs"][k]
		stoop_catches += int(r["stoop_catches"])
		# Per pair within 0.4 of the AI (24 trials each side: 1 sigma ~0.1),
		# and a contest (neither sure nor hopeless).
		near(float(r["rate"]), AiMirror.DUEL_FLEE[i], 0.4, "%s vs fleeing prey, mirror vs AI" % k)
		between(float(r["rate"]), 0.1, 0.95, "%s is a contest" % k)
	gt(float(stoop_catches), 3.0, "raptors catch with stoops")
	lab.queue_free()
	await get_tree().process_frame


func test_skill_catches_more_in_a_chase() -> void:
	# Chase by chase in open air, no catch assist - only the flying differs:
	# the catch rule rewards skill. A modelled novice (late, jittery, little
	# lead) catches a fleeing prey at a third of its mass far less often than
	# a competent player; an expert at least as often as a competent one.
	var lab := ChaseLab.new()
	add_child(lab)
	await get_tree().process_frame
	var p := {}
	for skill: StringName in [&"novice", &"competent", &"expert"]:
		var s := 0.0
		for m in [0.03, 0.09, 0.35]:
			s += float(lab.measure_hunt(m, 0.32, skill, 12, 5)["p"]) / 3.0
		p[String(skill)] = s
	metric("open_air_chase_success", p)
	gt(float(p["competent"]), float(p["novice"]) * 1.5, "competent players catch far more of their chases than novices")
	gt(float(p["expert"]), float(p["competent"]) - 0.05, "experts at least as many as competent players")
	lab.queue_free()
	await get_tree().process_frame


func test_danger_is_real_and_avoidable() -> void:
	# A committed hunter (the AI's geometry: 55-90% of its hunting range away,
	# raptors often from above) against a sparrow-sized player. A player who
	# never reacts is caught nearly every time; evading helps, the more
	# skilled the more. (These are single attacks with the AI's full
	# persistence: the integrated runs measure deaths per run.)
	var lab := ChaseLab.new()
	add_child(lab)
	await get_tree().process_frame
	var n := 16
	var odds := {}
	for skill: StringName in [&"novice", &"competent", &"expert"]:
		var e := 0.0
		for r in [1.8, 3.0]:
			e += float(lab.measure_escape(0.03, r, skill, n, 77)["p"]) * 0.5
		odds[String(skill)] = e
	lab.unaware = true
	var blind := float(lab.measure_escape(0.03, 3.0, &"competent", n, 77)["p"])
	lab.unaware = false
	metric("escape_odds_sparrow", odds)
	metric("escape_unaware", blind)
	lt(blind, 0.2, "a player who never evades is caught by a committed hunter (>80%)")
	gt(float(odds["competent"]), blind + 0.3, "evading makes a large difference")
	check(float(odds["expert"]) >= float(odds["competent"]) and float(odds["competent"]) > float(odds["novice"]),
			"escape odds rise with skill")
	gt(float(odds["competent"]), 0.5, "a competent player escapes most single attacks as a sparrow")
	lt(float(odds["novice"]), 0.7, "novices are caught often")
	lab.queue_free()
	await get_tree().process_frame


# --- The loop's player-side danger rules ---------------------------------------

func test_strikes_on_the_player_must_connect() -> void:
	var r := CatchRule.new()
	var hawk_r := SizeRules.body_radius_for_mass(1.3)
	var span := SizeRules.wingspan_for_mass(1.3)
	var pr := SizeRules.body_radius_for_mass(0.3)
	var on_npc := r.contact_distance(hawk_r, span, false, pr, false)
	var on_player := r.contact_distance(hawk_r, span, false, pr, true)
	near(on_npc - on_player, (r.npc_reach - r.npc_reach_on_player) * span, 1e-9, "smaller reach margin on the player")
	lt(r.npc_reach_on_player, r.npc_reach, "the player gets VR forgiveness as prey")
	# (A cone no wider than NPC-on-NPC strikes: 55 deg since fix round 5, the
	# AI's committed pass on the player being the forgiveness now - literal.)
	near(r.npc_cone_on_player_deg, 55.0, 1e-9, "the strike cone on the player (fix round 5: 40 -> 55)")
	check(r.npc_cone_on_player_deg <= r.npc_cone_deg, "...no wider than an NPC's on an NPC")
	check(not r.overlap_on_player, "...and a lunge landing on the player does not count by itself")
	# Live: a hawk alongside (bodies overlapping, heading 70 degrees off) does
	# not take the player; the same geometry takes an NPC pigeon.
	var p := _player(0.3)
	var off := Vector3(0.05, 0, 0)
	# Heading 70 degrees away from the bird it overlaps.
	var head := Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(-70.0))
	var h1 := make_bird(1.3, p.get_body_position() + off, head)
	var q := make_bird(0.3, Vector3(40, 30, 0), Vector3.FORWARD)
	var h2 := make_bird(1.3, q.get_body_position() + off, head)
	loop.step(DT)
	check(p.alive, "overlap without aim: the player is not caught")
	check(not q.alive, "overlap without aim: an NPC pigeon is (NPC-on-NPC rule unchanged)")
	# Aimed and within the player's (smaller) contact: caught.
	h1.global_position = p.get_body_position() + Vector3(0, 0, on_player * 0.9)
	h1.set_heading(Vector3.FORWARD)
	loop.teleported(h1)
	loop.step(DT)
	check(not p.alive, "an aimed strike within reach takes the player")
	h2.queue_free()


func test_a_missed_pass_gives_escape_grace() -> void:
	var p := _player(0.03)
	var got := []
	var respite_then := []
	loop.escaped.connect(func(q: Bird) -> void:
		got.append(q)
		respite_then.append(loop.respite_left()))
	# A hawk passes 1 m beside the player (inside PASS_SPANS, outside reach)
	# and flies on.
	var h := make_bird(1.3, p.get_body_position() + Vector3(1.0, 0, -30), Vector3.BACK)
	h.velocity = Vector3(0, 0, 14)
	var min_gap := INF
	var protected_at := -1.0
	var t := 0.0
	for i in int(4.0 / DT):
		h.global_position += h.velocity * DT
		loop.step(DT)
		t += DT
		min_gap = minf(min_gap, h.global_position.distance_to(p.get_body_position()))
		if protected_at < 0.0 and loop.protection_left(p) > 0.0:
			protected_at = t
	check(p.alive, "(setup) the pass missed")
	eq(got.size(), 1, "escaped() once for the pass")
	eq(loop.stats.escapes, 1, "counted in the run stats")
	eq(loop.get_run_stats()["escapes"], 1, "and in get_run_stats()")
	gt(protected_at, 0.0, "the player is protected after the pass")
	var left := loop.protection_left(p)
	gt(left, 0.0, "(still inside the grace)")
	lt(left, loop.escape_grace_s + 1e-6, "no longer than the grace")
	check(bool(p.get_meta(&"npc_ignore", false)), "NPCs are told to leave the player alone meanwhile")
	# Shaking the attacker off ends the attack: the respite starts right then
	# (not a second later, when the cue has been quiet).
	check(respite_then.size() == 1 and float(respite_then[0]) > GameLoop.ATTACK_RESPITE_S * 0.9,
			"shaking off an attacker starts the attack respite at once")
	# A struggling player (danger assist) gets a longer grace.
	await cleanup()
	p = _player(0.03)
	loop.danger_assist = 1.0
	var h2 := make_bird(1.3, p.get_body_position() + Vector3(1.0, 0, -30), Vector3.BACK)
	h2.velocity = Vector3(0, 0, 14)
	var granted := 0.0
	for i in int(4.0 / DT):
		h2.global_position += h2.velocity * DT
		var before := loop.protection_left(p)
		loop.step(DT)
		if loop.protection_left(p) > before + DT:
			granted = loop.protection_left(p)
	check(p.alive and loop.stats.escapes == 1, "(setup) the pass missed and was shaken off")
	gt(granted, loop.escape_grace_s + GameLoop.DANGER_ASSIST_GRACE_S * 0.95 - 1e-6,
			"at full danger assist the grace is ESCAPE_GRACE_S + DANGER_ASSIST_GRACE_S (%.2f s)" % granted)
	# A predator that never came close is not an escape.
	await cleanup()
	p = _player(0.03)
	got.clear()
	loop.escaped.connect(func(q: Bird) -> void: got.append(q))
	var far := make_bird(1.3, p.get_body_position() + Vector3(8.0, 0, -30), Vector3.BACK)
	far.velocity = Vector3(0, 0, 14)
	for i in int(4.0 / DT):
		far.global_position += far.velocity * DT
		loop.step(DT)
	eq(got.size(), 0, "a hawk 8 m away never made a pass")
	eq(loop.stats.escapes, 0, "no escape counted")


func test_danger_assist_narrows_the_strike_cone() -> void:
	# A hawk strikes at the player 45 deg off its heading, within reach: a
	# fresh player (no danger assist) is inside the 55 deg strike cone and
	# taken; one at full danger assist (cone 55 - DANGER_ASSIST_CONE_DEG = 35)
	# is not.
	for assist in [0.0, 1.0]:
		var p := _player(0.03)
		loop.set_protection(p, 0.0)
		loop.danger_assist = assist
		# (well inside even the shortened strike reach, so only the cone decides)
		var reach := SizeRules.body_radius_for_mass(1.3) + p.get_body_radius() \
				+ SizeRules.wingspan_for_mass(1.3) * loop.rule.npc_reach_on_player * (1.0 - GameLoop.DANGER_ASSIST_REACH_LOSS)
		var dir := Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(45.0))
		var hawk := make_bird(1.3, p.get_body_position() - dir * reach * 0.6, Vector3.FORWARD)
		loop.step(DT)
		if assist == 0.0:
			check(not p.alive, "no assist: a strike 45 deg off the hawk's heading takes the player")
			near(loop.rule.reach_margin(1.6, false, true), 1.6 * loop.rule.npc_reach_on_player, 1e-9, "no assist: the full strike reach")
		else:
			near(loop.rule.reach_margin(1.6, false, true), 1.6 * loop.rule.npc_reach_on_player * (1.0 - GameLoop.DANGER_ASSIST_REACH_LOSS * loop.danger_assist),
					1e-9, "full danger assist: the strike must come DANGER_ASSIST_REACH_LOSS closer")
			near(loop.watch.ttc_horizon, GameLoop.CUE_HORIZON_S * (1.0 + GameLoop.DANGER_ASSIST_CUE * loop.danger_assist), 1e-6,
					"...and the threat cue warns earlier")
		if assist == 0.0:
			pass
		else:
			check(p.alive, "full danger assist: the strike cone is %.0f deg, the player is not taken" % (
					loop.rule.npc_cone_on_player_deg - GameLoop.DANGER_ASSIST_CONE_DEG))
		hawk.queue_free()
		await cleanup()


## Catches `p` a moth right in front of it (its first catch).
func _feed_moth(p: SimBird) -> void:
	var c0 := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.004))
	make_bird(0.004, p.get_body_position() + p.get_forward() * c0 * 0.5)
	loop.step(DT)


## Steps the loop until its run clock reads t (0.5 s steps, then DT).
func _run_to(t: float) -> void:
	while loop.stats.run_time < t - 0.5:
		loop.step(0.5)
	while loop.stats.run_time < t:
		loop.step(DT)


func test_first_flight_respite() -> void:
	# A run opens with its first flight: NPCs leave the new player alone (it
	# is not protected: a hawk it flies into still takes it) until
	# OPENING_AFTER_CATCH_S after its first catch, never before OPENING_MIN_S
	# and never past OPENING_RESPITE_S of play (core loop round, the lead's
	# direction: "from ~60-90 s into the first flight (after the first catch
	# or lessons), predators periodically pick the player"). A restart opens
	# a new one. Literal numbers (round 3: a mutant 300 -> 100000 s survived a
	# symbolic check).
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.direct_danger = false
	loop.start_run()
	eq([GameLoop.OPENING_RESPITE_S, GameLoop.OPENING_MIN_S, GameLoop.OPENING_AFTER_CATCH_S], [90.0, 60.0, 15.0], "the first flight's numbers")
	gt(loop.respite_left(), 0.0, "a run opens with its first flight")
	loop.set_protection(p, 0.0)
	loop.step(DT)
	check(bool(p.get_meta(&"npc_ignore", false)), "NPCs leave the new player alone")
	# No catch: it ends at 1:30.
	_run_to(89.0)
	gt(loop.respite_left(), 0.0, "no catch yet at 1:29: still the first flight")
	check(bool(p.get_meta(&"npc_ignore", false)), "...and NPCs leave it alone")
	_run_to(90.6)
	eq(loop.respite_left(), 0.0, "no catch by 1:30: the first flight is over")
	check(not bool(p.get_meta(&"npc_ignore", false)), "and NPCs may hunt the player")
	# A first catch at 0:20: it ends at 1:00 (never before).
	loop.restart_run()
	loop.set_protection(p, 0.0)
	_run_to(20.0)
	_feed_moth(p)
	eq(loop.stats.catches, 1, "(setup) the first catch at 0:20")
	_run_to(59.5)
	gt(loop.respite_left(), 0.0, "first catch at 0:20: still the first flight at 0:59.5")
	_run_to(60.6)
	eq(loop.respite_left(), 0.0, "...over at 1:00")
	# A first catch at 1:10: it ends 15 s later, at 1:25.
	loop.restart_run()
	loop.set_protection(p, 0.0)
	_run_to(70.0)
	_feed_moth(p)
	_run_to(84.5)
	gt(loop.respite_left(), 0.0, "first catch at 1:10: still the first flight at 1:24.5")
	_run_to(85.6)
	eq(loop.respite_left(), 0.0, "...over at 1:25")
	# The first tier-up, whenever it comes, gives the new size 35 s of grace
	# (FIRST_TIER_GRACE_S, integration round 2: a crow took the new size
	# away 9-13 s after the "Now a Swallow!" card in 4 of 10 real-chain runs;
	# the brief: not punished within 30 s). Here at ~1:40, after the first
	# flight.
	loop.restart_run()
	loop.set_protection(p, 0.0)
	_run_to(100.0)
	eq(loop.respite_left(), 0.0, "(setup) at 1:40 the first flight is over")
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.02))
	while SizeRules.tier_for_mass(p.mass) == SizeRules.tier_for_mass(GameLoop.START_MASS):
		make_bird(0.02, p.get_body_position() + p.get_forward() * c * 0.5)
		loop.step(DT)
		loop.step(0.3)
	near(loop.respite_left(), 35.0, 0.35, "grown a tier: 35 s of grace for the new size")
	check(bool(p.get_meta(&"npc_ignore", false)), "NPCs leave the new swallow alone")
	for i in int(34.0 / 0.5):
		loop.step(0.5)
	gt(loop.respite_left(), 0.0, "still in the grace 34 s after the tier-up")
	for i in 3:
		loop.step(0.5)
	eq(loop.respite_left(), 0.0, "the grace is over 35 s after the tier-up")
	# ...and a tier-up inside the first flight: the grace runs from it.
	loop.restart_run()
	loop.set_protection(p, 0.0)
	_run_to(50.0)
	while SizeRules.tier_for_mass(p.mass) == SizeRules.tier_for_mass(GameLoop.START_MASS):
		make_bird(0.02, p.get_body_position() + p.get_forward() * c * 0.5)
		loop.step(DT)
		loop.step(0.3)
	var at := loop.stats.run_time
	_run_to(at + 34.0)
	gt(loop.respite_left(), 0.0, "a tier-up at ~0:51 (first catch then too): 34 s later still in grace")
	_run_to(at + 35.6)
	eq(loop.respite_left(), 0.0, "...over 35 s after it (the first flight ended at 1:06 meanwhile)")
	# Not protection: flying into a hawk during the first flight.
	loop.restart_run()
	gt(loop.respite_left(), 0.0, "a restart opens a new first flight")
	loop.set_protection(p, 0.0)
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3), Vector3.FORWARD)
	loop.step(DT)
	check(not p.alive, "the respite is not protection: a strike that connects still takes the player")
	hawk.queue_free()


func test_attack_respite() -> void:
	# A hawk hunting the player closes in (cue up), then breaks off and flies
	# away without a pass: once the cue has been quiet for ATTACK_QUIET_S the
	# attack is over and NPCs leave the player alone for ATTACK_RESPITE_S (x
	# body time) - without protecting it (it can still fly into trouble).
	var p := _player(0.03)
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, -30), Vector3.BACK)
	hawk.velocity = Vector3(0, 0, 12)
	var peak := 0.0
	for i in int(1.2 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
		peak = maxf(peak, loop.watch.level)
	gt(peak, GameLoop.ATTACK_LEVEL, "(setup) an attack registered")
	eq(loop.respite_left(), 0.0, "no respite while the attack is on")
	check(not bool(p.get_meta(&"npc_ignore", false)), "NPCs may hunt the player during an attack")
	hawk.velocity = Vector3(0, 0, -14)
	hawk.set_heading(Vector3.FORWARD)
	var started := -1.0
	var t := 0.0
	for i in int(8.0 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
		t += DT
		if started < 0.0 and loop.respite_left() > 0.0:
			started = t
	gt(started, 0.0, "the respite started after the attack")
	eq(loop.stats.escapes, 0, "(no pass was made: not an escape)")
	near(loop.respite_left(), GameLoop.ATTACK_RESPITE_S - (t - started), 0.1, "respite length (sparrow: ATTACK_RESPITE_S)")
	check(bool(p.get_meta(&"npc_ignore", false)), "NPCs leave the player alone during the respite")
	eq(loop.protection_left(p), 0.0, "...but the player is not protected")
	# It ends.
	for i in int((GameLoop.ATTACK_RESPITE_S + 1.0) / 0.25):
		loop.step(0.25)
	eq(loop.respite_left(), 0.0, "the respite ends")
	check(not bool(p.get_meta(&"npc_ignore", false)), "NPCs may hunt again")
	# Bigger birds are hunted more often (linearly in tiers to 0.55 of it at
	# the apex); the danger assist lengthens it. Literal numbers.
	near(loop.attack_respite(0.03), 110.0, 1e-9, "a sparrow's respite: 110 s")
	near(loop.attack_respite(0.3), 110.0 * (1.0 - 0.45 * 3.0 / 7.0), 1e-9, "a pigeon's: 88.8 s")
	near(loop.attack_respite(3.0), 60.5, 1e-9, "an eagle's: 60.5 s")
	await cleanup()
	var big := _player(3.0)
	loop.danger_assist = 0.5
	loop._start_respite(big)
	near(loop.respite_left(), 60.5 * (1.0 + 2.0 * 0.5), 1e-3, "an eagle's respite, with half the danger assist: x2")


func test_an_attack_starts_when_any_predator_reaches_attack_strength() -> void:
	# The named bird's level is not the whole danger: a hawk loitering at its
	# proximity floor (~0.23) holds the name; a second closes to ~0.32 of its
	# own - worse, but not by switch_margin, so the cue still names the first.
	# The attack is on all the same (ThreatWatch.peak_level).
	var p := _player(0.03)
	var a := make_bird(1.3, p.get_body_position(), Vector3.RIGHT)
	var span := a.get_wingspan()
	var contact := loop.rule.contact_distance(a.get_body_radius(), span, false, p.get_body_radius(), true)
	a.global_position = p.get_body_position() + Vector3(contact + 2.5 * span, 0, 0)
	a.velocity = Vector3.ZERO
	for i in int(1.0 / DT):
		loop.step(DT)
	eq(loop.watch.predator, a, "(setup) the loitering hawk is named")
	check(not loop._attack_on, "(setup) a hawk at its proximity floor alone is no attack (%.2f)" % loop.watch.level)
	var b := make_bird(1.3, p.get_body_position() + Vector3(-(contact + 1.2 * span), 0, 0), Vector3.LEFT)
	b.velocity = Vector3.ZERO
	for i in int(0.3 / DT):
		loop.step(DT)
	eq(loop.watch.predator, a, "(setup) still named: the newcomer is worse by less than switch_margin")
	lt(loop.watch.level, GameLoop.ATTACK_LEVEL, "(setup) the named level is under attack strength")
	gt(loop.watch.level_of(b), GameLoop.ATTACK_LEVEL, "(setup) the newcomer's own threat is at attack strength")
	check(loop._attack_on, "an attack is on when any predator reaches attack strength")


## A stand-in for the AI's Ecosystem: its NPC budget and the danger
## director's calls (send_attacker: records them, answers `send`).
class _Sky extends Node:
	var max_npcs := 60
	var calls: Array[float] = []
	var send: Bird = null
	var clock: Callable

	func _enter_tree() -> void:
		add_to_group(&"ecosystem")

	func send_attacker(_p: Bird) -> Bird:
		calls.append(float(clock.call()))
		return send


func test_one_sent_attacker_at_a_time() -> void:
	# Core loop round, second pass: while the bird the sky sent is still on
	# its way (hunting the player, no attack yet) the director calls nobody
	# else - for up to ATTACK_SENT_WAIT_S (30 s, literal); a sender that
	# gives up frees it at once.
	eq(GameLoop.ATTACK_SENT_WAIT_S, 30.0, "30 s")
	make_loop()
	var sky := _Sky.new()
	sky.clock = func() -> float: return loop.stats.run_time
	add_child(sky)
	var p := make_bird(0.03, Vector3(0, 40, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	_run_to(89.0)
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, -150), Vector3.FORWARD)
	check(hawk.target == p, "(setup) the hawk hunts the player")
	sky.send = hawk
	_run_to(91.0)
	eq(sky.calls.size(), 1, "the first call sends the hawk")
	_run_to(115.0)
	eq(sky.calls.size(), 1, "no call while the hawk is on its way (far off, no attack yet)")
	_run_to(122.0)
	eq(sky.calls.size(), 2, "called again once it has been waited for 30 s")
	sky.send = null
	var n := sky.calls.size()
	hawk.target = null
	_run_to(loop.stats.run_time + 5.1)
	gt(float(sky.calls.size()), n + 0.5, "a sent bird that gives up frees the director at once")
	sky.free()
	await cleanup()


func test_the_director_sends_attacks() -> void:
	# Core loop round (the lead's direction: "predators periodically pick the
	# player - about one telegraphed attack every 1-2 minutes at the start,
	# scaling with tier"): once the respite is over the loop asks the sky for
	# an attack (Ecosystem.send_attacker) at once, and again every
	# ATTACK_CALL_RETRY_S (5 s, literal) while none has come - never while
	# the player is protected, in its first flight or under attack. After an
	# attack the next respite is ATTACK_RESPITE_S (110 s at the first species).
	make_loop()
	var sky := _Sky.new()
	sky.clock = func() -> float: return loop.stats.run_time
	add_child(sky)
	var p := make_bird(0.03, Vector3(0, 40, 0), Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	_run_to(89.0)
	eq(sky.calls.size(), 0, "no call in the first flight")
	_run_to(91.0)
	eq(sky.calls.size(), 1, "the first flight over (no catch: 1:30): one call")
	near(sky.calls[0], 90.0, 0.02, "...at 1:30")
	_run_to(104.0)
	eq(sky.calls.size(), 3, "no attacker came: called again every 5 s (1:35, 1:40)")
	near(sky.calls[2] - sky.calls[1], 5.0, 0.02, "...5 s apart")
	eq(loop.stats.attacks_sent, 0, "(nobody was sent)")
	# Protected (a respawn, an escape): no call.
	loop.set_protection(p, 20.0)
	_run_to(120.0)
	eq(sky.calls.size(), 3, "no call while the player is protected")
	loop.set_protection(p, 0.0)
	# The sky sends a hawk: it attacks (the cue at attack strength), then
	# flies off; no call during the attack, and the next call comes a
	# respite (110 s) after it is over.
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, -30), Vector3.BACK)
	sky.send = hawk
	var n0 := sky.calls.size()
	loop.step(DT)
	eq(sky.calls.size(), n0 + 1, "called the moment the protection is over")
	eq(loop.stats.attacks_sent, 1, "the sky sent an attacker")
	sky.send = null
	hawk.velocity = Vector3(0, 0, 12)
	for i in int(1.5 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	check(loop._attack_on, "(setup) the attack is on")
	eq(loop.stats.attacks, 1, "one attack counted")
	var n1 := sky.calls.size()
	hawk.velocity = Vector3(0, 0, -14)
	hawk.set_heading(Vector3.FORWARD)
	var over_at := -1.0
	for i in int(10.0 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
		if over_at < 0.0 and not loop._attack_on:
			over_at = loop.stats.run_time
	eq(sky.calls.size(), n1, "no call during the attack or after it")
	gt(over_at, 0.0, "(setup) the attack ended")
	_run_to(over_at + 109.0)
	eq(sky.calls.size(), n1, "no call in the 110 s respite after the attack")
	_run_to(over_at + 110.6)
	eq(sky.calls.size(), n1 + 1, "called again 110 s after the attack")
	# The director is off: no calls (tests of single encounters, the lab).
	loop.direct_danger = false
	_run_to(over_at + 130.0)
	eq(sky.calls.size(), n1 + 1, "no calls with the director off")
	sky.queue_free()
	await get_tree().process_frame


func test_an_attack_ends_when_every_predator_is_quiet() -> void:
	# The attack respite reads ThreatWatch.peak_level - the worst threat of
	# any predator - not the named one's: a hawk attacks and flies off (the
	# cue's named bird goes quiet), while a second one lingers nearby at a
	# faint threat of its own (proximity floor ~0.07: too faint to take the
	# name, over ATTACK_QUIET_LEVEL). The attack is not over until it leaves
	# too (the rule the pacing evidence ran; round 3 read the smoothed worst
	# level). Mutant P09 (the named level) survived fix round 4's first check.
	var p := _player(0.03)
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, -30), Vector3.BACK)
	hawk.velocity = Vector3(0, 0, 12)
	var other := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0), Vector3.RIGHT)
	var span := other.get_wingspan()
	var contact := loop.rule.contact_distance(other.get_body_radius(), span, false, p.get_body_radius(), true)
	# Proximity floor 0.4 x (1 - gap / 6 spans) = ~0.07 at gap 4.9 spans.
	other.global_position = p.get_body_position() + Vector3(contact + 4.9 * span, 0, 0)
	other.velocity = Vector3.ZERO
	for i in int(1.2 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	gt(loop.watch.peak_level, GameLoop.ATTACK_LEVEL, "(setup) an attack registered")
	hawk.velocity = Vector3(0, 0, -14)
	hawk.set_heading(Vector3.FORWARD)
	for i in int(4.0 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	var lv := loop.watch.level_of(other)
	between(lv, GameLoop.ATTACK_QUIET_LEVEL + 0.005, ThreatWatch.QUIET_LEVEL - 0.005, "(setup) the lingering hawk's own threat is faint: %.3f" % lv)
	lt(loop.watch.level_of(hawk), GameLoop.ATTACK_QUIET_LEVEL, "(setup) the attacker has gone quiet")
	eq(loop.respite_left(), 0.0, "no respite while a predator still threatens, however faintly")
	# The second one leaves too: now the attack is over - after a second of
	# quiet (ATTACK_QUIET_S, literal: a mutant setting 0 survived the fix
	# round 5 review's check).
	other.velocity = Vector3(14, 0, 0)
	other.set_heading(Vector3.RIGHT)
	var t := 0.0
	var quiet_at := -1.0
	var started_at := -1.0
	for i in int(4.0 / DT):
		other.global_position += other.velocity * DT
		loop.step(DT)
		t += DT
		if quiet_at < 0.0 and loop.watch.peak_level <= GameLoop.ATTACK_QUIET_LEVEL:
			quiet_at = t
		if started_at < 0.0 and loop.respite_left() > 0.0:
			started_at = t
	check(started_at > 0.0, "the respite starts once every predator is quiet")
	near(started_at - quiet_at, 1.0, 1.5 * DT, "...after 1 s of quiet (%.3f s)" % (started_at - quiet_at))


var _assist_at_respite := 0.0


## One attack on the player and its end: a hawk closes in until the cue is
## up, then turns away; returns the respite that followed (s), or -1 (the
## danger assist then: _assist_at_respite).
func _one_attack(p: SimBird) -> float:
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, -30), Vector3.BACK)
	hawk.velocity = Vector3(0, 0, 12)
	for i in int(1.2 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
	hawk.velocity = Vector3(0, 0, -14)
	hawk.set_heading(Vector3.FORWARD)
	var got := -1.0
	for i in int(8.0 / DT):
		hawk.global_position += hawk.velocity * DT
		loop.step(DT)
		if got < 0.0 and loop.respite_left() > 0.0:
			got = loop.respite_left()
			_assist_at_respite = loop.danger_assist
	hawk.global_position = Vector3(0, -900, 0)
	hawk.alive = false
	# Wait the respite out.
	while loop.respite_left() > 0.0:
		loop.step(0.25)
	return got


func test_boldness_and_the_respawn_respite() -> void:
	# Every attack the player survives shortens the next respite by
	# BOLD_DECAY (the first is the full ATTACK_RESPITE_S), never below
	# BOLD_FLOOR of it; being caught resets that, and a respawn opens a
	# RESPAWN_RESPITE_S respite (x body time, x the danger assist).
	var p := _player(0.03)
	loop.set_protection(p, 600.0)
	var spans: Array[float] = []
	for k in 7:
		spans.append(snappedf(_one_attack(p), 0.01))
	metric("respites_after_survived_attacks", spans)
	near(spans[0], GameLoop.ATTACK_RESPITE_S, 0.05, "the first attack survived: the full respite")
	for k in range(1, spans.size()):
		var want := GameLoop.ATTACK_RESPITE_S * maxf(GameLoop.BOLD_FLOOR, pow(GameLoop.BOLD_DECAY, k))
		near(spans[k], want, 0.05, "attack %d survived: respite x %.2f" % [k + 1, want / GameLoop.ATTACK_RESPITE_S])
	near(spans[-1], GameLoop.ATTACK_RESPITE_S * GameLoop.BOLD_FLOOR, 0.05, "...down to the floor")
	eq(loop.attacks_survived, 7, "seven attacks survived")
	# Caught: the count resets and the respawn opens its own respite.
	loop.set_protection(p, 0.0)
	var h := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.phase, GameLoop.Phase.CAUGHT, "(setup) caught")
	h.global_position = Vector3(0, -900, 0)
	for i in int((GameLoop.CAUGHT_BEAT_S + 0.1) / DT):
		loop.step(DT)
	eq(loop.phase, GameLoop.Phase.PLAYING, "(setup) respawned")
	eq(loop.attacks_survived, 0, "a death resets the boldness")
	var a := loop.danger_assist
	near(loop.respite_left(), GameLoop.RESPAWN_RESPITE_S * SizeRules.time_scale(p.mass) * (1.0 + GameLoop.DANGER_ASSIST_RESPITE * a),
			0.3, "respawn respite: RESPAWN_RESPITE_S x body time x the danger assist (%.2f)" % a)
	gt(loop.respite_left(), 60.0, "a life lost buys over a minute unhunted")
	loop.set_protection(p, 600.0)
	while loop.respite_left() > 0.0:
		loop.step(0.25)
	var after := _one_attack(p)
	near(after, GameLoop.ATTACK_RESPITE_S * (1.0 + GameLoop.DANGER_ASSIST_RESPITE * _assist_at_respite), 0.05,
			"after the death the first attack survived gets the full respite again (with the assist)")


func test_danger_assist_builds_with_deaths_and_decays_with_play() -> void:
	# Each death adds DANGER_ASSIST_PER_DEATH (to 1); it decays with a time
	# constant of DANGER_ASSIST_TAU_S body-seconds of play, and not while
	# the run waits in the CAUGHT beat.
	var p := _player(0.03)
	loop.set_protection(p, 0.0)
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3), Vector3.FORWARD)
	loop.step(DT)
	eq(loop.phase, GameLoop.Phase.CAUGHT, "(setup) caught")
	near(loop.danger_assist, GameLoop.DANGER_ASSIST_PER_DEATH, 1e-9, "a death adds DANGER_ASSIST_PER_DEATH")
	hawk.global_position = Vector3(0, -900, 0)
	var at_beat := loop.danger_assist
	for i in int((GameLoop.CAUGHT_BEAT_S - 0.2) / DT):
		loop.step(DT)
	near(loop.danger_assist, at_beat, 1e-9, "no decay during the caught beat")
	for i in int(0.5 / DT):
		loop.step(DT)
	eq(loop.phase, GameLoop.Phase.PLAYING, "(setup) respawned")
	loop.danger_assist = 1.0
	var tau := GameLoop.DANGER_ASSIST_TAU_S * SizeRules.time_scale(p.mass)
	for i in int(tau / 0.5):
		loop.step(0.5)
	near(loop.danger_assist, exp(-1.0), 0.02, "after one time constant of play: 1/e")
	for i in int(3.0 * tau / 0.5):
		loop.step(0.5)
	lt(loop.danger_assist, 0.03, "after four: nearly gone")


func test_threat_cue_reads_intent() -> void:
	# The same hawk on the same course: hunting the player it is a full
	# threat; hunting something else, or nothing, it is NOT_HUNTING_WEIGHT of
	# that - and (core loop round) it carries no danger mark then: marks are
	# for the player's hunters; a bird that exposes no intent counts in full.
	var p := _player(0.03)
	loop.set_protection(p, 600.0)
	var other := make_bird(0.03, p.get_body_position() + Vector3(50, 0, 0))
	var hawk := make_bird(1.3, p.get_body_position() + Vector3(0, 0, -20), Vector3.BACK, false, true)
	hawk.velocity = Vector3(0, 0, 12)
	var levels := {}
	for who in ["player", "other", "none"]:
		hawk.target = p if who == "player" else (other if who == "other" else null)
		levels[who] = loop.watch.threat_of(p, hawk, loop.rule)
	metric("threat_by_intent", levels)
	gt(float(levels["player"]), 0.3, "(setup) a real threat")
	near(float(levels["other"]), float(levels["player"]) * ThreatWatch.NOT_HUNTING_WEIGHT, 1e-6, "hunting someone else")
	near(float(levels["none"]), float(levels["player"]) * ThreatWatch.NOT_HUNTING_WEIGHT, 1e-6, "not hunting")
	loop.step(DT)
	eq(hawk.model.highlight, 0, "a big bird not hunting the player carries no danger mark")
	hawk.target = p
	loop.step(DT)
	eq(hawk.model.highlight, 2, "...hunting it, it does")
	# A bird without a `target` property: full weight.
	var plain := Bird.new()
	eq(ThreatWatch.intent_weight(plain, p), 1.0, "unknown intent counts in full")
	plain.free()


func test_threat_cue_warns_earlier_for_bigger_birds() -> void:
	for m in [0.03, 0.3, 3.0]:
		var p := _player(m)
		var want := GameLoop.CUE_HORIZON_S * pow(SizeRules.time_scale(m), GameLoop.CUE_HORIZON_EXP)
		near(loop.watch.ttc_horizon, want, 1e-6, "cue horizon at %.2f kg" % m)
		await cleanup()
	var p2 := _player(0.03)
	var small := loop.watch.ttc_horizon
	await cleanup()
	p2 = _player(3.0)
	gt(loop.watch.ttc_horizon, small * 3.0, "an eagle is warned > 3x earlier (in seconds) than a sparrow")
