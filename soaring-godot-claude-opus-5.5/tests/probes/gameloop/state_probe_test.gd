extends "res://tests/unit/game/game_fixture.gd"
## Verifier probes (round 1) for G3/G7/G8: run-flow edge cases the area's own
## suite does not exercise — continuing after a victory, restarting or
## quitting in the middle of the CAUGHT beat, respawning at a real World's
## spawn, the state fuzz under other seeds, and the records' bookkeeping.

const DT := 1.0 / 72.0


## A World with a non-default spawn and one refuge (for spawn/refuge probes).
class ProbeWorld extends World:
	var spawn := Transform3D(Basis(Vector3.UP, 1.0), Vector3(120, 55, -40))
	var refuges: Array[Dictionary] = []

	func get_player_spawn() -> Transform3D:
		return spawn

	func get_refuges() -> Array[Dictionary]:
		return refuges


var world: ProbeWorld = null


func after_each() -> void:
	if world and is_instance_valid(world):
		world.queue_free()
	world = null
	await cleanup()


func _feed(p: SimBird, qm: float) -> SimBird:
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true,
			SizeRules.body_radius_for_mass(qm))
	var q := make_bird(qm, p.get_body_position() + p.get_forward() * c * 0.5)
	loop.step(DT)
	loop.step(0.25)
	return q


## Grows the player to eagle and completes the apex goal.
func _win(p: SimBird) -> void:
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	p.mass = eagle * 1.01
	loop.step(DT)
	for i in GameLoop.APEX_CATCHES:
		_feed(p, eagle * 0.3)


## A predator catches the player (no beat played out).
func _catch_player(p: SimBird) -> SimBird:
	loop.set_protection(p, 0.0)
	var h := make_bird(maxf(1.6, p.mass * 2.0), p.get_body_position() + Vector3(0, 0, 0.3))
	loop.step(DT)
	h.alive = false  # out of the way for the rest of the probe
	return h


func _beat() -> void:
	run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)


func test_victory_then_continue_counts_once_in_records() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	var wins := [0]
	loop.victory.connect(func(_s: Dictionary) -> void: wins[0] += 1)
	start_logging()
	_win(p)
	eq(Game.state, Game.State.ENDED, "victory ends the run")
	eq(loop.records.runs, 1, "after victory: one run recorded")
	eq(loop.records.victories, 1, "after victory: one victory recorded")
	loop.continue_after_victory()
	eq(Game.state, Game.State.PLAYING, "continued")
	for i in GameLoop.MAX_LIVES:
		_catch_player(p)
		_beat()
	eq(Game.state, Game.State.ENDED, "continued run ends when lives run out")
	eq(wins[0], 1, "only one victory signal")
	var ends := events("run_ended")
	eq(ends.size(), 2, "(observed) run_ended fires for the victory and again for the continued run's end")
	metric("runs_recorded", loop.records.runs)
	metric("victories_recorded", loop.records.victories)
	if ends.size() == 2:
		var s2: Dictionary = ends[1][1]
		metric("second_summary_reason", s2["reason"])
		metric("second_summary_victory", s2["victory"])
		metric("second_summary_new_records", s2["new_records"])
	# One run played, one victory won: records must say so.
	eq(loop.records.runs, 1, "a continued victory run counts as ONE run in the records")
	eq(loop.records.victories, 1, "a continued victory run counts as ONE victory in the records")


func test_endless_run_end_then_direct_play_starts_fresh() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	_win(p)
	loop.continue_after_victory()
	for i in GameLoop.MAX_LIVES:
		_catch_player(p)
		_beat()
	eq(Game.state, Game.State.ENDED, "endless run over")
	# A UI (or the UI's fallback path) sets PLAYING from ENDED directly.
	Game.set_state(Game.State.PLAYING)
	await get_tree().process_frame
	eq(loop.phase, GameLoop.Phase.PLAYING, "direct ENDED -> PLAYING after an endless run starts a new run")
	eq(loop.lives, GameLoop.MAX_LIVES, "fresh lives")
	near(p.mass, GameLoop.START_MASS, 1e-9, "fresh mass")
	check(p.alive and p.controls_enabled, "player alive with controls")


func test_restart_in_the_middle_of_the_beat() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.2
	loop.step(DT)
	_catch_player(p)
	eq(Game.state, Game.State.CAUGHT, "caught")
	var respawns := [0]
	loop.player_respawned.connect(func(_s: float) -> void: respawns[0] += 1)
	run_steps(30, DT)  # part-way through the beat
	loop.restart_run()
	eq(Game.state, Game.State.PLAYING, "restart mid-beat -> PLAYING")
	check(p.alive and p.controls_enabled, "alive with controls")
	run_steps(int(4.0 / DT), DT)  # well past where the old beat would have ended
	eq(respawns[0], 0, "the aborted beat never fires a respawn later")
	near(p.mass, GameLoop.START_MASS, 1e-9, "no late penalty from the aborted beat")
	eq(loop.lives, GameLoop.MAX_LIVES, "lives stay full")
	eq(loop.phase, GameLoop.Phase.PLAYING, "still playing")
	eq(loop.get_run_stats()["respawn_in"], 0.0, "no respawn countdown")


func test_quit_to_menu_in_the_middle_of_the_beat() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	_catch_player(p)
	start_logging()
	run_steps(20, DT)
	# What UI's "Quit to menu" does:
	loop.quit_run()
	Game.set_state(Game.State.MENU)
	run_steps(int(4.0 / DT), DT)
	eq(Game.state, Game.State.MENU, "stays in the menu")
	eq(loop.phase, GameLoop.Phase.IDLE, "loop idle")
	eq(count("run_ended"), 0, "no summary for quitting")
	eq(p.respawn_count, 1, "no respawn fired into the menu")
	loop.start_run()
	check(p.alive and p.controls_enabled, "the next run starts with a live player")
	eq(loop.lives, GameLoop.MAX_LIVES, "full lives")


func test_respawn_at_the_worlds_spawn() -> void:
	world = ProbeWorld.new()
	add_child(world)
	make_loop()
	await get_tree().process_frame  # GameLoop finds the World deferred
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	vnear(p.global_position, world.spawn.origin, 1e-4, "run starts at World.get_player_spawn()")
	var want_heading := -world.spawn.basis.z
	vnear(p.heading, want_heading.normalized(), 1e-4, "facing the spawn's direction")
	p.global_position = Vector3(0, 20, 0)
	loop.teleported(p)
	loop.step(DT)
	_catch_player(p)
	_beat()
	eq(p.respawn_count, 2, "respawned via PlayerBird-style respawn()")
	vnear(p.global_position, world.spawn.origin, 1e-4, "respawned at World.get_player_spawn()")


func test_refuge_blocks_wide_predators_only() -> void:
	world = ProbeWorld.new()
	world.refuges = [{"position": Vector3(0, 20, 0), "radius": 3.0, "max_span": 0.5}]
	add_child(world)
	make_loop()
	await get_tree().process_frame
	start_logging()
	# Hawk (1.6 m span) at a sparrow hiding inside the refuge: blocked.
	var hawk := make_bird(1.3, Vector3(0, 20, 0.3))
	var hidden := make_bird(0.03, Vector3(0, 20, 0))
	# Starling (0.40 m span, fits) at a wren inside the same refuge: allowed.
	var starling := make_bird(0.1, Vector3(1.5, 20, 0.1))
	var wren := make_bird(0.012, Vector3(1.5, 20, 0.0))
	run_steps(10, DT)
	check(hidden.alive, "a hawk cannot catch a sparrow inside a hedge-sized refuge")
	check(not wren.alive, "a starling (fits) still catches a wren inside it")
	# The sparrow leaves cover: now it can be caught.
	hidden.global_position = Vector3(0, 20, 6.0)
	hawk.global_position = Vector3(0, 20, 6.3)
	loop.teleported(hidden)
	loop.teleported(hawk)
	run_steps(int(1.5 / DT), DT)
	check(not hidden.alive, "outside the refuge the hawk catches it")
	check(hawk.alive and starling.alive, "predators fine")


func test_teleported_is_not_swept() -> void:
	# A 2 m jump in one 72 Hz frame is below the automatic teleport threshold
	# (90 m/s x dt + 1 m = 2.25 m): only teleported() keeps it from sweeping.
	for announce in [false, true]:
		make_loop()
		var hawk := make_bird(1.3, Vector3(0, 20, 1.0))
		var sparrow := make_bird(0.03, Vector3(0, 20, 0))
		sparrow.global_position = Vector3(0, 20, 0)
		loop.step(DT)  # remembers start positions (hawk 1 m behind, out of reach)
		# Hmm: make sure that first step was not already a catch.
		var alive0 := sparrow.alive
		hawk.global_position = Vector3(0, 20, -1.0)  # jump through the sparrow
		if announce:
			loop.teleported(hawk)
		loop.step(DT)
		if alive0:
			eq(not sparrow.alive, not announce, "2 m jump through a sparrow: caught=%s when teleported() %s" % [
				not announce, "is called" if announce else "is not called"])
		else:
			fail("setup: first frame already caught")
		await cleanup()


func test_catch_assist_ramps_by_body_time_and_survives_death() -> void:
	make_loop()
	var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	var samples := {}
	for t in [29.0, 75.0, 120.0, 200.0]:
		while loop.since_catch < t - 1e-6:
			loop.step(minf(0.5, t - loop.since_catch))
		samples[t] = loop.catch_assist()
	near(samples[29.0], 0.0, 1e-6, "no assist before 30 s without a catch (sparrow)")
	near(samples[75.0], 0.5, 1e-3, "half assist at 75 s")
	near(samples[120.0], 1.0, 1e-6, "full assist at 120 s")
	near(samples[200.0], 1.0, 1e-6, "assist capped")
	# With full assist a prey at 1.5x the unassisted reach is caught.
	loop.step(DT)
	var unassisted := CatchRule.new()
	unassisted.player_time_scale = SizeRules.time_scale(p.mass)
	var c0 := unassisted.contact_distance(p.get_body_radius(), p.get_wingspan(), true, SizeRules.body_radius_for_mass(0.012))
	var q := make_bird(0.012, p.get_body_position() + Vector3(0, 0, -c0 * 1.5))
	loop.step(DT)
	check(not q.alive, "full assist: prey at 1.5x the normal reach is caught")
	near(loop.catch_assist(), 0.0, 1e-6, "a catch resets the assist")
	# Deaths do not reset it (documented).
	while loop.since_catch < 100.0:
		loop.step(0.5)
	var before := loop.catch_assist()
	_catch_player(p)
	_beat()
	gt(loop.catch_assist(), before - 1e-6, "a death does not reset the assist")
	# Body time: an eagle waits ~4x longer (in seconds) for the same assist.
	await cleanup()
	make_loop()
	var e := make_bird(3.0, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	e.mass = 3.0
	loop.set_protection(e, 0.0)
	while loop.since_catch < 100.0:
		loop.step(0.5)
	near(loop.catch_assist(), 0.0, 1e-6, "eagle: no assist after 100 s (under 30 body-seconds)")
	metric("eagle_time_scale", SizeRules.time_scale(3.0))


# ---- State fuzz with other seeds and extra operations ----------------------

func _consistent(p: SimBird, wins: int) -> String:
	var gs := Game.state
	match loop.phase:
		GameLoop.Phase.PLAYING:
			if not (gs == Game.State.PLAYING or gs == Game.State.PAUSED):
				return "phase PLAYING but Game %s" % Game.state_name()
			if not p.alive:
				return "PLAYING with a dead player"
			if not p.controls_enabled:
				return "PLAYING with controls off"
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
	if get_tree().paused != (gs == Game.State.PAUSED):
		return "tree paused=%s in %s" % [get_tree().paused, Game.state_name()]
	if loop.lives < 0 or loop.lives > GameLoop.MAX_LIVES:
		return "lives out of range: %d" % loop.lives
	if p.mass > GameLoop.MAX_PLAYER_MASS + 1e-9:
		return "mass above the cap"
	if loop.phase != GameLoop.Phase.IDLE and p.mass < GameLoop.START_MASS - 1e-9:
		return "mass below start"
	if p.species != SizeRules.species_for_mass(p.mass) and loop.phase != GameLoop.Phase.IDLE:
		return "species %s does not follow mass %.3f" % [p.species, p.mass]
	return ""


var _resume_to: Game.State = Game.State.PLAYING


## Mirrors UIRoot: on entering PAUSED it remembers CAUGHT if paused from
## CAUGHT, else PLAYING, and resume() sets that state.
func _ui_tracks_resume(new_state: int, old_state: int) -> void:
	if new_state == Game.State.PAUSED:
		_resume_to = Game.State.CAUGHT if old_state == Game.State.CAUGHT else Game.State.PLAYING


func test_state_fuzz_other_seeds() -> void:
	var results := {}
	for seed_ in [1, 77, 4242, 99991]:
		make_loop()
		var p := make_bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
		loop.start_run()
		var hawk := make_bird(1.6, Vector3(0, -500, 0))
		var wins := [0]
		loop.victory.connect(func(_s: Dictionary) -> void: wins[0] += 1)
		_resume_to = Game.State.PLAYING
		Events.game_state_changed.connect(_ui_tracks_resume)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_
		var weights := {"step": 6, "beat": 2, "danger": 5, "pause": 3, "resume": 3, "restart": 2,
				"menu": 1, "ui_play": 3, "ui_menu": 1, "ui_pause": 3, "ui_resume": 3, "feed": 4,
				"end": 1, "win": 1, "continue": 2, "unfocus": 1}
		var ops: Array[String] = []
		for k: String in weights:
			for w in int(weights[k]):
				ops.append(k)
		var bad := ""
		var seen := {}
		for i in 600:
			var op: String = ops[rng.randi() % ops.size()]
			match op:
				"step":
					run_steps(rng.randi_range(1, 20), DT)
				"beat":
					run_steps(int(GameLoop.CAUGHT_BEAT_S / DT) + 2, DT)
				"danger":
					if p.alive:
						loop.set_protection(p, 0.0)
						hawk.mass = maxf(1.6, p.mass * 2.0)
						hawk.global_position = p.get_body_position() + Vector3(0, 0, 0.2)
						loop.teleported(hawk)
						loop.step(DT)
						hawk.global_position = Vector3(0, -500, 0)
						loop.teleported(hawk)
				"pause":
					loop.pause()
				"resume":
					loop.resume()
				"restart":
					loop.restart_run()
				"menu":
					loop.to_menu()
				"ui_play":
					# UI's bridge.start_run(): the loop's start_run, then PLAYING if not reached.
					loop.start_run()
					if Game.state != Game.State.PLAYING:
						Game.set_state(Game.State.PLAYING)
				"ui_menu":
					loop.quit_run()
					Game.set_state(Game.State.MENU)
				"ui_pause", "unfocus":
					# UI pauses from PLAYING or CAUGHT (menu button / headset off).
					if Game.state == Game.State.PLAYING or Game.state == Game.State.CAUGHT:
						Game.set_state(Game.State.PAUSED)
				"ui_resume":
					# UI's resume(): back to the state it saw before PAUSED.
					if Game.state == Game.State.PAUSED:
						Game.set_state(_resume_to)
				"feed":
					if p.alive and loop.phase == GameLoop.Phase.PLAYING:
						make_bird(p.mass / SizeRules.EAT_RATIO * rng.randf_range(0.1, 0.99),
								p.get_body_position() + p.get_forward() * 0.05)
						loop.step(DT)
						loop.step(0.25)
				"end":
					loop.end_run(&"quit")
				"win":
					if p.alive and loop.phase == GameLoop.Phase.PLAYING and Game.state == Game.State.PLAYING:
						_win(p)
				"continue":
					loop.continue_after_victory()
			await get_tree().process_frame
			var key := "%s/%s" % [GameLoop.Phase.keys()[loop.phase], Game.state_name()]
			seen[key] = int(seen.get(key, 0)) + 1
			bad = _consistent(p, wins[0])
			if bad != "":
				bad = "seed %d, after op %d (%s): %s" % [seed_, i, op, bad]
				break
		Events.game_state_changed.disconnect(_ui_tracks_resume)
		results[seed_] = {"bad": bad, "seen": seen, "wins": wins[0], "victories_recorded": loop.records.victories}
		eq(bad, "", "state invariants hold (seed %d)" % seed_)
		await cleanup()
	metric("fuzz", results)
