extends "res://tests/unit/game/game_fixture.gd"
## G3 — death -> CAUGHT beat -> penalty -> respawn -> lives -> run end ->
## restart, consistent with the Game state machine and pause, and restart
## resetting everything. Ends with a randomized operation fuzz that checks
## the invariants after every step.

const DT := 1.0 / 72.0
const FUZZ_OPS := 1200


## Stand-in for the AI area's Ecosystem: counts reset() calls.
class MockEcosystem extends Node:
	var resets := 0

	func _enter_tree() -> void:
		add_to_group(&"ecosystem")

	func reset() -> void:
		resets += 1


var eco: MockEcosystem


func before_each() -> void:
	eco = MockEcosystem.new()
	add_child(eco)


func after_each() -> void:
	eco.queue_free()
	await cleanup()


## Starts a run with a player; returns it (sparrow at the spawn point).
func start() -> SimBird:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	start_logging()
	loop.start_run()
	return p


## Parks a hawk right behind the player (player in its aim cone).
func hawk_on(p: SimBird) -> SimBird:
	var h := make_bird(1.3, p.get_body_position() + Vector3(0, 0, 0.3), Vector3.FORWARD)
	return h


func test_run_start_state() -> void:
	var p := start()
	eq(Game.state, Game.State.PLAYING, "Game is PLAYING")
	eq(loop.phase, GameLoop.Phase.PLAYING, "loop phase PLAYING")
	eq(loop.lives, GameLoop.MAX_LIVES, "full lives")
	near(p.mass, GameLoop.START_MASS, 1e-9, "start mass")
	eq(p.species, &"sparrow", "start as a sparrow")
	eq(p.respawn_count, 1, "placed at the spawn via respawn()")
	vnear(p.global_position, Vector3(0, 30, 0), 1e-6, "no World: fallback spawn")
	check(p.controls_enabled, "controls on")
	near(loop.protection_left(p), GameLoop.START_PROTECT_S, 1e-6, "start protection")
	eq(count("run_started"), 1, "run_started once")
	eq(eco.resets, 1, "ecosystem reset once")
	near(Game.run_time, 0.0, 1e-9, "run clock zeroed")


func test_caught_beat_penalty_respawn() -> void:
	var p := start()
	loop.set_protection(p, 0.0)
	p.mass = 0.2
	loop.step(DT)
	var hawk := hawk_on(p)
	var respawned := []
	loop.player_respawned.connect(func(s: float) -> void: respawned.append(s))
	loop.step(DT)
	eq(count("player_caught"), 1, "player_caught once")
	eq(count("caught"), 1, "bird_caught once")
	eq(events("player_caught")[0][1], hawk, "caught by the hawk")
	eq(Game.state, Game.State.CAUGHT, "Game CAUGHT")
	eq(loop.lives, GameLoop.MAX_LIVES - 1, "lost a life")
	check(not p.alive, "player not alive during the beat")
	check(not p.controls_enabled, "controls off during the beat")
	var st := loop.get_run_stats()
	near(st["respawn_in"], GameLoop.CAUGHT_BEAT_S, DT * 1.5, "beat countdown exposed")
	# Nothing else happens during the beat, even with the hawk right there.
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) - 3, DT)
	eq(Game.state, Game.State.CAUGHT, "still CAUGHT just before the beat ends")
	eq(count("player_caught"), 1, "no second catch during the beat")
	run_steps(4, DT)
	eq(Game.state, Game.State.PLAYING, "PLAYING after the beat")
	check(p.alive and p.controls_enabled, "alive with controls")
	eq(p.respawn_count, 2, "respawned at the spawn")
	near(p.mass, 0.2 * (1.0 - GameLoop.CAUGHT_MASS_LOSS * (1.0 - GameLoop.DANGER_ASSIST_PENALTY_CUT * GameLoop.DANGER_ASSIST_PER_DEATH)), 1e-9, "penalty: 30% mass lost, cut by the danger assist of one death")
	near(GameLoop.CAUGHT_MASS_LOSS, 0.3, 1e-9, "the penalty is 30% at no assist")
	# One death: the danger assist is DANGER_ASSIST_PER_DEATH, which lengthens
	# the respawn protection (RESPAWN_PROTECT_S + DANGER_ASSIST_PROTECT_S x it).
	near(loop.danger_assist, GameLoop.DANGER_ASSIST_PER_DEATH, 0.01, "one death: danger assist")
	var protect := loop.respawn_protection()
	near(protect, GameLoop.RESPAWN_PROTECT_S + GameLoop.DANGER_ASSIST_PROTECT_S * loop.danger_assist, 1e-6, "respawn protection formula")
	near(loop.protection_left(p), protect, 2 * DT, "respawn protection")
	eq(respawned.size(), 1, "player_respawned once")
	near(float(respawned[0]), protect, 1e-6, "player_respawned carries the protection")
	gt(loop.respite_left(), 0.0, "a respawn starts an attack respite")
	# Protection holds even though the hawk is waiting at the old spot next to the spawn.
	hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3)
	run_steps(int((protect - 0.2) / DT), DT, func(_i: int) -> void:
		hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3))
	eq(count("player_caught"), 1, "protected after respawn")
	# Penalty never goes below the start mass.
	p.mass = GameLoop.START_MASS
	run_steps(int(0.4 / DT), DT, func(_i: int) -> void:
		hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3))
	eq(count("player_caught"), 2, "caught again once protection ends")
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
	near(p.mass, GameLoop.START_MASS, 1e-9, "mass floor at the start mass")


func test_pause_during_beat_resumes_beat() -> void:
	var p := start()
	loop.set_protection(p, 0.0)
	hawk_on(p)
	loop.auto_step = true
	await wait_physics(2)
	eq(Game.state, Game.State.CAUGHT, "caught (auto-stepped)")
	var left := float(loop.get_run_stats()["respawn_in"])
	loop.pause()
	eq(Game.state, Game.State.PAUSED, "paused")
	check(get_tree().paused, "tree paused")
	await wait_seconds(GameLoop.CAUGHT_BEAT_S + 0.5)
	near(float(loop.get_run_stats()["respawn_in"]), left, 1e-6, "beat frozen while paused")
	eq(loop.phase, GameLoop.Phase.CAUGHT, "still in the beat")
	loop.resume()
	eq(Game.state, Game.State.CAUGHT, "resume() returns to CAUGHT, not PLAYING")
	check(not get_tree().paused, "unpaused")
	# UI that resumes with Game.set_state(PLAYING) gets corrected.
	loop.pause()
	Game.set_state(Game.State.PLAYING)
	await wait_frames(2)
	eq(Game.state, Game.State.CAUGHT, "direct PLAYING mid-beat is corrected to CAUGHT")
	await wait_seconds(GameLoop.CAUGHT_BEAT_S + 0.3)
	eq(Game.state, Game.State.PLAYING, "beat completes after resuming")
	check(p.alive, "respawned")
	loop.auto_step = false


func test_pause_freezes_play() -> void:
	var p := start()
	loop.auto_step = true
	await wait_physics(5)
	var prot := loop.protection_left(p)
	var rt := loop.stats.run_time
	loop.pause()
	await wait_physics(30)
	near(loop.protection_left(p), prot, 1e-9, "protection does not run down while paused")
	near(loop.stats.run_time, rt, 1e-9, "run time frozen while paused")
	# A catch that would happen is held until resume.
	loop.set_protection(p, 0.0)
	var q := make_bird(0.01, p.get_body_position() + Vector3(0, 0, -0.1))
	await wait_physics(10)
	check(q.alive, "no catches while paused")
	loop.resume()
	await wait_physics(3)
	check(not q.alive, "catch resolves after resume")
	loop.auto_step = false


func test_lives_exhausted_ends_run() -> void:
	var p := start()
	var hawk := hawk_on(p)
	for i in GameLoop.MAX_LIVES:
		loop.set_protection(p, 0.0)
		hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.3)
		loop.step(DT)
		eq(Game.state, Game.State.CAUGHT, "caught #%d" % (i + 1))
		run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
	eq(loop.lives, 0, "no lives left")
	eq(Game.state, Game.State.ENDED, "run ENDED after the last beat")
	eq(loop.phase, GameLoop.Phase.ENDED, "loop ENDED")
	eq(count("run_ended"), 1, "run_ended once")
	var summary: Dictionary = events("run_ended")[0][1]
	eq(summary["reason"], &"caught", "summary reason")
	eq(summary["times_caught"], GameLoop.MAX_LIVES, "summary counts deaths")
	eq(summary["lives_left"], 0, "summary lives")
	eq(summary["caught_by"].get(&"hawk", 0), GameLoop.MAX_LIVES, "summary: who caught you")
	check(not p.controls_enabled, "controls off after the end")
	# Nothing more happens to the player; the world keeps going.
	var n1 := make_bird(0.35, Vector3(50, 20, 0))
	var n2 := make_bird(0.09, Vector3(50, 20, -0.2))
	run_steps(10, DT)
	eq(count("player_caught"), GameLoop.MAX_LIVES, "no catches of the player after the end")
	check(not n2.alive and n1.alive, "NPCs still hunt after the run")


func test_restart_resets_everything() -> void:
	var p := start()
	loop.set_protection(p, 0.0)
	# Progress: grow, catch, get caught once, pause.
	for i in 4:
		var q := make_bird(p.mass / SizeRules.EAT_RATIO * 0.99, p.get_body_position() + Vector3(0, 0, -0.05))
		loop.step(DT)
		check(not q.alive, "meal %d" % i)
		loop.step(GameLoop.SWALLOW_MAX_S + 0.05)
	var hawk := make_bird(p.mass * 3.0, p.get_body_position() + Vector3(0, 0, 0.3))
	# (Inside its reach, whatever the player grew to.)
	hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.5 * loop.rule.contact_distance(hawk.get_body_radius(),
			hawk.get_wingspan(), false, p.get_body_radius(), true))
	loop.step(DT)
	eq(Game.state, Game.State.CAUGHT, "caught")
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
	hawk.global_position = Vector3(0, -900, 0)  # gone (freed at the frame's end)
	hawk.queue_free()
	# A long dry spell (catch assist), the death's danger assist and an
	# attack respite running: none of it may carry into the next run.
	for i in 400:
		loop.step(0.5)
	loop._start_respite(p)
	# (a respite longer than a new run's first flight, to tell them apart)
	loop._respite_until = loop._clock + GameLoop.OPENING_RESPITE_S * 3.0
	gt(loop.catch_assist(), 0.5, "(setup) catch assist built up")
	gt(loop.danger_assist, 0.05, "(setup) danger assist built up")
	gt(loop.respite_left(), GameLoop.OPENING_RESPITE_S * 2.0, "(setup) a long respite is running")
	loop.pause()
	gt(loop.stats.catches, 3, "made progress before restart")
	var prey := make_bird(0.01, Vector3(0, 30, -2), Vector3.FORWARD, false, true)
	prey.model.highlight = 1
	loop.watch.highlights[prey.get_instance_id()] = 1
	loop.watch.level = 0.7
	loop._emitted_level = 0.7
	# Boldness and eat-to-heal bookkeeping mid-run (fix round 4 review: their
	# reset was unpinned - mutants E15/E16 survived).
	loop.attacks_survived = 4
	loop.meals_since_life_lost = 3
	var tier_before := SizeRules.tier_for_mass(p.mass)
	ev_log.clear()
	loop.restart_run()
	eq(Game.state, Game.State.PLAYING, "PLAYING after restart")
	check(not get_tree().paused, "tree unpaused")
	eq(loop.lives, GameLoop.MAX_LIVES, "lives reset")
	near(p.mass, GameLoop.START_MASS, 1e-9, "mass reset")
	eq(p.species, &"sparrow", "species reset")
	check(p.alive and p.controls_enabled, "player alive, controls on")
	var st := loop.get_run_stats()
	for k in ["catches", "worthwhile_catches", "times_caught", "streak", "best_streak", "npc_catches"]:
		eq(st[k], 0, "stat %s reset" % k)
	near(st["mass_gained"], 0.0, 1e-12, "mass_gained reset")
	near(st["run_time"], 0.0, 1e-12, "run time reset")
	near(Game.run_time, 0.0, 1e-12, "Game.run_time reset")
	eq(st["catches_by_species"].size(), 0, "per-species counts reset")
	eq(st["apex"]["catches"], 0, "apex progress reset")
	near(st["peak_mass"], GameLoop.START_MASS, 1e-12, "peak reset")
	near(loop.protection_left(p), GameLoop.START_PROTECT_S, 1e-6, "fresh start protection")
	eq(loop.since_catch, 0.0, "time since the last catch reset")
	eq(loop.catch_assist(), 0.0, "no catch assist carried over")
	eq(loop.danger_assist, 0.0, "no danger assist carried over")
	near(loop.respite_left(), 0.5, 1e-6, "no respite carried over: only the new run's first flight (renewed each step)")
	check(not loop._first_flight_over and not loop._first_tier_grace_given and loop._first_catch_at < 0.0,
			"...a new first flight, its first catch and its first tier-up's grace still to come")
	eq(loop.stats.attacks, 0, "attacks reset")
	eq(st["escapes"], 0, "escapes reset")
	eq(eco.resets, 2, "ecosystem reset again")
	eq(prey.model.highlight, 0, "highlights cleared")
	eq(count("run_started"), 1, "run_started on restart")
	eq(loop.attacks_survived, 0, "boldness reset: a new run's sky is not bold")
	eq(loop.meals_since_life_lost, 0, "the eat-to-heal count reset")
	# A restart is a reset, not a tier change (contract note, fix round 4):
	# player_tier_changed fires for tier changes in play (growth, a death's
	# penalty); after a restart listeners resync on run_started, so the
	# UI does not toast "sparrow" as a tier change at every new run.
	gt(float(tier_before), float(SizeRules.species_index(&"sparrow")), "(setup) the player had grown out of the sparrow")
	eq(count("tier"), 0, "restart emits no player_tier_changed")
	var threat_resets := events("threat")
	check(threat_resets.size() >= 1 and threat_resets[-1][1] == 0.0, "threat cue reset to 0")
	# Restart from ENDED too.
	loop.end_run(&"quit")
	eq(Game.state, Game.State.ENDED, "ended")
	loop.restart_run()
	eq(Game.state, Game.State.PLAYING, "restart from ENDED")
	eq(loop.phase, GameLoop.Phase.PLAYING, "phase PLAYING")


func test_ui_driven_transitions() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	start_logging()
	Game.set_state(Game.State.MENU)
	Game.set_state(Game.State.PLAYING)
	eq(count("run_started"), 1, "MENU -> PLAYING by the UI starts a run")
	eq(loop.phase, GameLoop.Phase.PLAYING, "phase follows")
	eq(p.respawn_count, 1, "player placed")
	var runs0 := loop.records.runs
	Game.set_state(Game.State.MENU)
	eq(loop.phase, GameLoop.Phase.IDLE, "PLAYING -> MENU abandons the run")
	eq(count("run_ended"), 0, "abandoning shows no summary")
	eq(loop.records.runs, runs0 + 1, "but the run is recorded")
	Game.set_state(Game.State.PLAYING)
	eq(count("run_started"), 2, "second run")
	Game.set_state(Game.State.ENDED)
	eq(count("run_ended"), 1, "external ENDED ends the run with a summary")
	eq(events("run_ended")[0][1]["reason"], &"quit", "reason quit")
	loop.to_menu()
	eq(Game.state, Game.State.MENU, "to_menu")


func _consistent(p: SimBird) -> String:
	var gs := Game.state
	match loop.phase:
		GameLoop.Phase.PLAYING:
			if not (gs == Game.State.PLAYING or gs == Game.State.PAUSED):
				return "phase PLAYING but Game %s" % Game.state_name()
			if not p.alive:
				return "PLAYING with a dead player"
		GameLoop.Phase.CAUGHT:
			if not (gs == Game.State.CAUGHT or gs == Game.State.PAUSED):
				return "phase CAUGHT but Game %s" % Game.state_name()
			if p.alive:
				return "CAUGHT with a live player"
		GameLoop.Phase.ENDED:
			if not (gs == Game.State.ENDED or gs == Game.State.PAUSED):
				return "phase ENDED but Game %s" % Game.state_name()
		GameLoop.Phase.IDLE:
			if not (gs == Game.State.MENU or gs == Game.State.BOOT):
				return "phase IDLE but Game %s" % Game.state_name()
	if loop.phase == GameLoop.Phase.PLAYING and not p.controls_enabled:
		return "PLAYING with controls off"
	if get_tree().paused != (gs == Game.State.PAUSED):
		return "tree paused=%s in %s" % [get_tree().paused, Game.state_name()]
	if loop.lives < 0 or loop.lives > GameLoop.MAX_LIVES:
		return "lives out of range: %d" % loop.lives
	if loop.phase == GameLoop.Phase.ENDED and loop.lives > 0 and not loop.stats.victory \
			and loop.get_last_summary().get("reason", &"") == &"caught":
		return "ended by being caught with lives left"
	if p.mass < GameLoop.START_MASS - 1e-9 and loop.phase != GameLoop.Phase.IDLE:
		return "mass below the start mass"
	return ""


func test_endless_run_end_then_ui_play_starts_fresh() -> void:
	# Win, continue in endless mode, lose every life: ENDED. A UI that then
	# sets PLAYING directly (as it may from ENDED) gets a brand-new run.
	var p := start()
	loop.set_protection(p, 0.0)
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	p.mass = eagle * 1.05
	loop.step(DT)
	for k in GameLoop.APEX_CATCHES:
		make_bird(p.mass * 0.3, p.get_body_position() + p.get_forward() * 0.3)
		loop.step(DT)
		run_steps(int(0.25 / DT), DT)
	check(loop.stats.victory, "(setup) won")
	loop.continue_after_victory()
	check(loop.endless and Game.state == Game.State.PLAYING, "(setup) endless play")
	loop.end_run(&"quit")
	eq(Game.state, Game.State.ENDED, "(setup) endless run over")
	Game.set_state(Game.State.PLAYING)
	await get_tree().process_frame
	eq(loop.phase, GameLoop.Phase.PLAYING, "ENDED -> PLAYING after an endless run starts a new run")
	check(not loop.endless, "the new run is not endless")
	eq(loop.lives, GameLoop.MAX_LIVES, "full lives")
	near(p.mass, GameLoop.START_MASS, 1e-9, "back to a sparrow")
	check(p.controls_enabled and p.alive, "controls on, alive")
	check(not loop.stats.victory, "no victory carried over")


func test_state_machine_fuzz() -> void:
	var p := start()
	var hawk := hawk_on(p)
	hawk.global_position = Vector3(0, -500, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	# Weighted so every phase/state pair is visited often: danger and pause
	# are common (pausing mid-beat is the tricky case), leaving the run rare.
	var weights := {"step": 6, "beat": 2, "danger": 8, "pause": 6, "resume": 4, "restart": 3,
			"menu": 1, "ui_play": 3, "ui_menu": 1, "ui_pause": 2, "ui_resume": 2, "feed": 3, "end": 1,
			"win": 2, "continue": 1}
	var starts := [1]  # start() above began the first run
	var wins := [0]
	var endless_replays := 0
	var continued := 0
	var on_start := func() -> void: starts[0] += 1
	var on_win := func(_s: Dictionary) -> void: wins[0] += 1
	Events.run_started.connect(on_start)
	loop.victory.connect(on_win)
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	var ops: Array[String] = []
	for k: String in weights:
		for w in int(weights[k]):
			ops.append(k)
	var hist := {}
	var seen := {}
	var bad := ""
	for i in FUZZ_OPS:
		var op: String = ops[rng.randi() % ops.size()]
		hist[op] = int(hist.get(op, 0)) + 1
		match op:
			"step":
				run_steps(rng.randi_range(1, 20), DT)
			"beat":
				run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
			"danger":
				loop.set_protection(p, 0.0)
				hawk.mass = maxf(1.3, p.mass * 2.0)
				hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.2)
				loop.step(DT)
				hawk.global_position = Vector3(0, -500, 0)
			"pause":
				loop.pause()
			"resume":
				loop.resume()
			"restart":
				loop.restart_run()
			"menu":
				loop.to_menu()
			"ui_play":
				if Game.state == Game.State.MENU or Game.state == Game.State.ENDED:
					if loop.endless and loop.phase == GameLoop.Phase.ENDED:
						endless_replays += 1
					Game.set_state(Game.State.PLAYING)
			"ui_menu":
				Game.set_state(Game.State.MENU)
			"ui_pause":
				if Game.state == Game.State.PLAYING:
					Game.set_state(Game.State.PAUSED)
			"ui_resume":
				if Game.state == Game.State.PAUSED:
					loop.resume()
			"feed":
				if p.alive:
					var q := make_bird(p.mass / SizeRules.EAT_RATIO * 0.99, p.get_body_position() + Vector3(0, 0, -0.05))
					loop.step(DT)
					if q.alive:
						q.alive = false
						q.global_position = Vector3(0, -900, 0)
			"end":
				loop.end_run(&"quit")
			"win":
				# Fast-forward to the apex and complete the goal.
				if loop.phase == GameLoop.Phase.PLAYING and p.alive and not loop.endless:
					p.mass = eagle * 1.05
					loop.step(DT)
					var fed: Array[SimBird] = []
					for k in GameLoop.APEX_CATCHES:
						if loop.phase != GameLoop.Phase.PLAYING:
							break
						fed.append(make_bird(p.mass * 0.3, p.get_body_position() + p.get_forward() * 0.3))
						loop.step(DT)
						run_steps(int(0.25 / DT), DT)
					# Leave no big birds behind to eat the test's hawk later.
					for q in fed:
						if q.alive:
							q.alive = false
							q.global_position = Vector3(0, -900, 0)
					# Then what a player might do next: stay on the summary,
					# keep flying, or keep flying and end that too.
					var r := rng.randf()
					if loop.phase == GameLoop.Phase.ENDED and r >= 0.35:
						continued += 1
						loop.continue_after_victory()
						if r >= 0.7:
							loop.end_run(&"quit")
			"continue":
				if loop.phase == GameLoop.Phase.ENDED and loop.stats.victory and Game.state == Game.State.ENDED:
					continued += 1
				loop.continue_after_victory()
		await get_tree().process_frame  # lets deferred corrections run
		var key := "%s/%s" % [GameLoop.Phase.keys()[loop.phase], Game.state_name()]
		seen[key] = int(seen.get(key, 0)) + 1
		bad = _consistent(p)
		# A run counts once in the records and a victory once, however it
		# ends (a won run that is continued and ends again is still one).
		if bad == "" and loop.records.runs > starts[0]:
			bad = "records count %d runs for %d started" % [loop.records.runs, starts[0]]
		if bad == "" and loop.records.victories > wins[0]:
			bad = "records count %d victories for %d won" % [loop.records.victories, wins[0]]
		if bad != "":
			bad = "after op %d (%s): %s" % [i, op, bad]
			break
	eq(bad, "", "state invariants hold through %d random operations" % FUZZ_OPS)
	metric("op_histogram", hist)
	metric("phase_state_visits", seen)
	Events.run_started.disconnect(on_start)
	metric("wins_continued_replayed", [wins[0], continued, endless_replays])
	gt(float(wins[0]), 2.0, "fuzz won runs")
	gt(float(continued), 1.0, "fuzz continued won runs")
	gt(float(endless_replays), 0.0, "fuzz started a new run straight from an ended endless run")
	# Coverage: the fuzz really visited every legal combination.
	for key in ["PLAYING/PLAYING", "PLAYING/PAUSED", "CAUGHT/CAUGHT", "CAUGHT/PAUSED",
			"ENDED/ENDED", "IDLE/MENU"]:
		gt(float(seen.get(key, 0)), 4.0, "fuzz visited %s" % key)
