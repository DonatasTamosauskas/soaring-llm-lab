extends TestCase
## The core loop with real flight (integration round 1; reworked in round 2).
##
## Nothing staged, nothing pinned: the real main.tscn with its real sky (the
## AI's Ecosystem, 60 NPCs), a sparrow flown through the real chain
## (flight's BotPoseSource arm motion -> WingInput -> FlightModel) by the
## competent person of integration_person.gd - the game loop's own modelled
## competent player (SimPilot's cues, evasion and chase rules) flying the
## real PlayerBird: it follows the HUD's target cue, keeps a bird it can see,
## drops a chase that stops closing or goes out of sight, evades what the
## threat cue names and breaks across each attack. The game's own catch rule
## decides, with the catch assist the game gives a player who has not caught
## anything for a while (it grows after 30 s without a catch).
##
## Pinned over PLAY_S of play: at least MIN_CATCHES catches; the rest of the
## core loop in the same minutes - NPCs catch each other through the loop's
## catch rule, and NPC hunters go after the player (integration round 2:
## mutants that stopped either passed the whole-game suite). Recorded, not
## pinned: every catch with the catch assist at that moment, EXACTLY
## (round 2: round 1 rounded it with snappedf(x, 2) - to a multiple of two -
## so every assist under 1 read 0 and "one catch by the base rule" could
## never fail; recorded exactly, all three of round 1's catches were
## assisted), and how chases ended. The brief's pacing is
## real_pacing_test's (stored whole runs at both tiers).

const Kit := preload("res://tests/unit/integration/game_kit.gd")
const Person := preload("res://tests/unit/integration/integration_person.gd")
const PLAY_S := 360.0
## At least one catch a minute (core loop round, second pass; was 2 in 6
## minutes): the pellets, the reachable-only ring and the magnet make ~2 a
## minute the loop's pace through the real chain (the held-out pacing runs:
## 1.4-1.9 catches a minute over whole runs, more in the first minutes).
const MIN_CATCHES := 6
const MIN_NPC_CATCHES := 5
## The catch lesson (test_the_catch_lesson_is_quick): its first catch within
## this (the lead's direction: "within 1-2 minutes").
const LESSON_S := 120.0

var kit: Kit
var booted := false


func before_all() -> void:
	kit = Kit.new()
	booted = await kit.boot(self)


func after_all() -> void:
	if kit:
		await kit.teardown()
	await wait_frames(5)


func test_a_competent_person_catches_real_prey() -> void:
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	# Play through the game's own bridge rather than the laser pointer: the
	# pointer's grace and debounce run on the wall clock, so a click took a
	# different number of ticks in every run and the sky the run started in
	# differed. This way a seed is one run. (game_flow_test clicks Play with
	# the pointer.)
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING, 3.0)
	m.ui.onboarding.skip()
	eq(m.game_loop.assist_override, -1.0, "the catch assist is the game's own (not pinned)")
	var play_s := float(Paths.arg("catch_play_s", str(PLAY_S)))
	var seed_v := int(Paths.arg("catch_seed", "5"))
	var person := Person.new(kit, seed_v)
	var catches: Array = []
	var deaths := [0]
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player:
			catches.append({"t": snappedf(Game.run_time, 0.1), "prey": String(prey.species),
				"assist": snappedf(m.game_loop.rule.player_assist, 0.001)})
	var on_death := func(_by: Bird) -> void:
		deaths[0] += 1
	Events.bird_caught.connect(on_caught)
	Events.player_caught.connect(on_death)
	var t := 0.0
	while t < play_s and Game.state != Game.State.ENDED:
		await kit.advance(1.0 / 72.0)
		t += 1.0 / 72.0
		person.step(1.0 / 72.0)
	Events.bird_caught.disconnect(on_caught)
	Events.player_caught.disconnect(on_death)
	person.release()
	var unassisted := 0
	for c: Dictionary in catches:
		if float(c["assist"]) <= 0.0:
			unassisted += 1
	var ps := person.summary()
	print("[integration] catch play %.0f s: %d catches (%d without the assist), %d deaths; %s; person %s" % [
		t, catches.size(), unassisted, deaths[0], catches, ps])
	metric("catch_play", {"play_s": t, "catches": catches, "unassisted": unassisted, "deaths": deaths[0], "person": ps,
		"chases": person.chase_log})
	gt(float(catches.size()), MIN_CATCHES - 0.5, "%d catches in %.0f s of a competent person's play (assists at the catches: %s)" % [
		catches.size(), t, catches.map(func(c: Dictionary) -> float: return c["assist"])])
	# The rest of the core loop, in the same minutes of real play: the sky
	# eats itself, and hunts the player too.
	var eco: Dictionary = m.ecosystem.stats()
	var npc_catches := int(m.game_loop.get_run_stats().get("npc_catches", 0))
	metric("npc_catches", npc_catches)
	metric("hunts_on_player", int(eco.get("hunts_on_player", 0)))
	gt(float(npc_catches), MIN_NPC_CATCHES - 0.5, "NPCs catch each other through the loop's catch rule: %d in %.0f s" % [npc_catches, t])
	gt(float(eco.get("hunts_on_player", 0)), 0.5, "NPC hunters went after the player: %d hunts" % int(eco.get("hunts_on_player", 0)))
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())


func test_the_catch_lesson_is_quick() -> void:
	# Core loop round (the lead's direction: "a competent new player
	# completes the catch lesson within 1-2 minutes"): a new run, and the
	# UI's catch lesson asks the game for its prey
	# (GameLoop.request_lesson_prey: an unaware moth swarm in open air ahead
	# of the player's flight - the ring on it) as the player takes off. The
	# competent person, who follows the ring, catches one within LESSON_S.
	if not check(booted, "the game loaded"):
		return
	var m := kit.main
	m.ui.bridge.start_run()
	await kit.wait_until(func() -> bool: return Game.state == Game.State.PLAYING and m.game_loop.stats.run_time < 1.0, 3.0)
	m.ui.onboarding.skip()
	var seed_v := int(Paths.arg("catch_seed", "5")) + 1000
	var person := Person.new(kit, seed_v)
	var first := [-1.0]
	var lesson_catch := [-1.0]
	var ringed := [-1.0]
	var lesson_ids := {}
	var on_caught := func(pred: Bird, prey: Bird) -> void:
		if pred == m.player:
			if first[0] < 0.0:
				first[0] = m.game_loop.stats.run_time
			if lesson_catch[0] < 0.0 and lesson_ids.has(prey.get_instance_id()):
				lesson_catch[0] = m.game_loop.stats.run_time
	Events.bird_caught.connect(on_caught)
	# The lesson begins a moment into the flight (the UI's first lessons).
	var t := 0.0
	var asked := false
	var got: Array[Bird] = []
	while t < LESSON_S + 5.0 and Game.state != Game.State.ENDED and lesson_catch[0] < 0.0:
		await kit.advance(1.0 / 72.0)
		t += 1.0 / 72.0
		person.step(1.0 / 72.0)
		if not asked and t >= 5.0:
			asked = true
			got = m.game_loop.request_lesson_prey()
			for b in got:
				lesson_ids[b.get_instance_id()] = true
		elif asked and fmod(t - 5.0, 30.0) < 1.0 / 72.0 and t > 6.0:
			# (The UI asks again every 30 s without a catch: its help.)
			for b in m.game_loop.request_lesson_prey():
				lesson_ids[b.get_instance_id()] = true
		if asked and ringed[0] < 0.0 and m.game_loop.watch.target != null and lesson_ids.has(m.game_loop.watch.target.get_instance_id()):
			ringed[0] = t - 5.0
	Events.bird_caught.disconnect(on_caught)
	person.release()
	m.game_loop.release_lesson_prey()
	var ps := person.summary()
	print("[integration] catch lesson: prey %d, ringed after %.1f s, first catch %.1f s, lesson moth caught %.1f s into the lesson; person %s" % [
		got.size(), ringed[0], first[0], lesson_catch[0] - 5.0 if lesson_catch[0] >= 0.0 else -1.0, ps])
	metric("catch_lesson", {"prey": got.size(), "ringed_after_s": ringed[0], "lesson_catch_s": lesson_catch[0] - 5.0 if lesson_catch[0] >= 0.0 else -1.0,
		"person": ps, "chases": person.chase_log})
	eq(got.size(), 5, "the game put up five lesson moths")
	between(ringed[0], 0.0, 5.0, "the ring is on a lesson moth within 5 s (%.1f s)" % ringed[0])
	between(lesson_catch[0] - 5.0, 0.0, LESSON_S, "the competent person catches a lesson moth within %.0f s of the lesson (%.1f s)" % [
		LESSON_S, lesson_catch[0] - 5.0])
	eq(kit.log.errors, 0, "no errors: %s" % kit.log.summary())
