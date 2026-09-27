extends TestCase
## Independent verifier probes for the gameloop area (round 1, engineering /
## contract lens). NOT part of the area's suite: it lives outside
## tests/unit so no other run picks it up. Run with:
##   tools/gd.sh gameloop_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/gameloop
## Self-contained (own records file, own helpers) so it cannot disturb the
## area's fixture files if suites run concurrently.

const DT := 1.0 / 72.0
const Y := 20.0
const REC := "user://gameloop_verify_probe_records.cfg"

var loop: GameLoop
var made: Array[Node] = []


class _FakeModel extends Node3D:
	var highlight := 0
	var flap_phase := 0.0
	var flap_amount := 0.0
	var wing_fold := 0.0


class _RefugeWorld extends World:
	func get_refuges() -> Array[Dictionary]:
		return [{"name": "probe_hedge", "position": Vector3(0, 20, 0), "radius": 3.0, "max_span": 0.3}]


func _mk_loop() -> GameLoop:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REC))
	loop = GameLoop.new()
	loop.auto_step = false
	loop.records_path = REC
	loop.npc_spawn_grace_s = 0.0
	loop.verbose = false
	add_child(loop)
	made.append(loop)
	return loop


func _bird(mass: float, pos: Vector3, facing: Vector3 = Vector3.FORWARD, player: bool = false,
		with_model: bool = false) -> SimBird:
	var b := SimBird.new()
	b.player_mode = player
	b.mass = mass
	b.species = SizeRules.species_for_mass(mass)
	if with_model:
		var m := _FakeModel.new()
		b.model = m
		b.add_child(m)
	add_child(b)
	b.global_position = pos
	b.set_heading(facing)
	made.append(b)
	return b


func after_each() -> void:
	for n in made:
		if is_instance_valid(n):
			n.queue_free()
	made.clear()
	loop = null
	get_tree().paused = false
	await get_tree().process_frame
	if Game.state != Game.State.MENU:
		Game.set_state(Game.State.MENU)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(REC))


func _feed(p: SimBird, prey_mass: float) -> SimBird:
	var c := loop.rule.contact_distance(p.get_body_radius(), p.get_wingspan(), true,
			SizeRules.body_radius_for_mass(prey_mass))
	var q := _bird(prey_mass, p.get_body_position() + p.get_forward() * c * 0.5)
	loop.step(DT)
	loop.step(0.25)
	return q


func _win(p: SimBird) -> void:
	var eagle: float = SizeRules.species_data(&"eagle")["mass"]
	p.mass = eagle * 0.97
	loop.step(DT)
	_feed(p, eagle * 0.3)
	for i in GameLoop.APEX_CATCHES:
		_feed(p, eagle * 0.3)


## P1: after continue_after_victory() the endless run ends; a UI that drives
## Game.set_state(PLAYING) from ENDED (the documented fallback path) must get
## a fresh run, and one run must count once in the records.
func test_p1_endless_run_end_then_ui_play() -> void:
	_mk_loop()
	var p := _bird(0.03, Vector3.ZERO, Vector3.FORWARD, true)
	loop.start_run()
	loop.set_protection(p, 0.0)
	_win(p)
	eq(Game.state, Game.State.ENDED, "(setup) victory ended the run")
	var runs_after_win := loop.records.runs
	var vic_after_win := loop.records.victories
	loop.continue_after_victory()
	eq(Game.state, Game.State.PLAYING, "(setup) endless play")
	loop.end_run(&"quit")
	eq(Game.state, Game.State.ENDED, "(setup) endless run ended")
	metric("records_runs_delta_same_run", loop.records.runs - runs_after_win)
	metric("records_victories_delta_same_run", loop.records.victories - vic_after_win)
	eq(loop.records.runs - runs_after_win, 0, "a won-then-continued run is counted once in records.runs")
	eq(loop.records.victories - vic_after_win, 0, "its victory is counted once")
	var started := [0]
	var cb := func() -> void: started[0] += 1
	Events.run_started.connect(cb)
	Game.set_state(Game.State.PLAYING)
	Events.run_started.disconnect(cb)
	metric("phase_after_ui_play", GameLoop.Phase.keys()[loop.phase])
	metric("player_mass_after_ui_play", p.mass)
	eq(started[0], 1, "UI ENDED -> PLAYING starts a fresh run (as it does after a normal run)")
	eq(loop.phase, GameLoop.Phase.PLAYING, "loop phase follows Game.PLAYING")
	near(p.mass, GameLoop.START_MASS, 1e-9, "player reset to the start mass")


## P2a: the builder's 60-bird cost scene, counting how many birds are still
## alive (and so actually in the catch pass) while the median is measured.
func test_p2a_cost_scene_alive_counts() -> void:
	var r := await _cost_scene(false)
	metric("alive_at_step", r["alive"])
	metric("median_us", r["median"])
	metric("p95_us", r["p95"])
	metric("median_alive", r["median_alive"])
	check(true, "measurement only")


## P2b: the same scene with every bird kept alive (revived after each
## frame): the catch pass really sees 60 birds in tight flocks every frame.
func test_p2b_cost_scene_all_alive() -> void:
	var r := await _cost_scene(true)
	metric("median_us", r["median"])
	metric("p95_us", r["p95"])
	metric("median_alive", r["median_alive"])
	lt(float(r["median"]), 200.0, "60 live birds in tight flocks: median catch pass < 200 us (builder's budget)")


func _cost_scene(revive: bool) -> Dictionary:
	_mk_loop()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var bs: Array[SimBird] = []
	for i in 60:
		var centre := Vector3((i % 4) * 30.0, Y, 0) if i < 40 else Vector3(rng.randf_range(-200, 200), Y, rng.randf_range(-200, 200))
		var spread := 3.0 if i < 40 else 0.0
		bs.append(_bird(exp(rng.randf_range(log(0.004), log(4.5))),
				centre + Vector3(rng.randf_range(-spread, spread), rng.randf_range(-spread, spread), rng.randf_range(-spread, spread)),
				Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1))))
	var times: Array[float] = []
	var alive_n: Array[float] = []
	var alive_at := {}
	for s in 200:
		for b in bs:
			if b.alive:
				b.fly(b.heading.rotated(Vector3.UP, 0.05), b.cruise_speed(), DT)
		loop.step(DT)
		times.append(float(loop.perf["catch"]))
		var n := 0
		for b in bs:
			if b.alive:
				n += 1
		alive_n.append(float(n))
		if s in [0, 1, 5, 20, 50, 100, 199]:
			alive_at[s] = n
		if revive:
			for b in bs:
				b.alive = true
	times.sort()
	var an := alive_n.duplicate()
	an.sort()
	return {"median": times[100], "p95": times[190], "alive": alive_at, "median_alive": an[100]}


## P3: refuges (documented in GAMELOOP.md, untested by the area): prey inside
## a refuge cannot be caught by a predator wider than max_span; a small
## predator that fits still can; outside the refuge the rule is unchanged.
func test_p3_refuges_block_only_big_predators() -> void:
	var w := _RefugeWorld.new()
	add_child(w)
	made.append(w)
	_mk_loop()
	await get_tree().process_frame  # GameLoop finds the World deferred
	var sp := _bird(0.03, Vector3(0, 20, 0))
	var hawk := _bird(1.3, Vector3(0, 20, 0.3))
	var moth := _bird(0.004, Vector3(1, 20, 0.15))
	var wren := _bird(0.012, Vector3(1, 20, 0.2))
	var sp2 := _bird(0.03, Vector3(10, 20, 0))
	var hawk2 := _bird(1.3, Vector3(10, 20, 0.3))
	for i in 3:
		loop.step(DT)
	check(sp.alive, "sparrow inside the refuge is safe from a hawk (span 1.6 > 0.3)")
	check(not moth.alive, "a wren (span 0.16 fits) still catches a moth inside the refuge")
	check(not sp2.alive, "outside the refuge the hawk catches the sparrow")
	check(hawk.alive and hawk2.alive and wren.alive, "predators unaffected")


## P4: determinism of the integrated simulation (same seed, same run).
func test_p4_integrated_sim_is_deterministic() -> void:
	var outs: Array[String] = []
	for k in 2:
		var sim := IntegratedSim.new()
		add_child(sim)
		await get_tree().process_frame
		var r: Dictionary = await sim.run(&"competent", 77, 150.0)
		outs.append(str([r["tier_at"], r["catches"], r["deaths"], r["npc_catches"], r["chases"]]))
		sim.queue_free()
		await get_tree().process_frame
	metric("run", outs[0])
	eq(outs[0], outs[1], "same seed -> identical integrated run")


## P5: threat/target/highlight cost with birds that MOVE (highlights and
## targets change), not a frozen crowd.
func test_p5_watch_cost_moving_birds() -> void:
	_mk_loop()
	var p := _bird(0.35, Vector3(0, 30, 0), Vector3.FORWARD, true)
	loop.start_run()
	p.mass = 0.35
	loop.set_protection(p, 600.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var bs: Array[SimBird] = []
	for i in 59:
		var m := exp(rng.randf_range(log(0.004), log(4.5)))
		var pos := Vector3(rng.randf_range(-25, 25), 30 + rng.randf_range(-8, 8), rng.randf_range(-25, 25))
		bs.append(_bird(m, pos, Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)), false, true))
	var times: Array[float] = []
	var flips := 0
	var last := {}
	for s in 300:
		p.fly(p.heading.rotated(Vector3.UP, 0.03), p.cruise_speed(), DT)
		for b in bs:
			if b.alive:
				b.fly(b.heading.rotated(Vector3.UP, 0.04), b.cruise_speed(), DT)
		loop.step(DT)
		times.append(float(loop.perf["watch"]))
		for b in bs:
			var h: int = (b.model as _FakeModel).highlight
			if last.get(b, h) != h:
				flips += 1
			last[b] = h
	times.sort()
	metric("watch_median_us", times[150])
	metric("watch_p95_us", times[285])
	metric("highlight_changes", flips)
	lt(times[150], 300.0, "moving crowd: watch median < 300 us")
	lt(times[285], 300.0, "moving crowd: watch p95 < 300 us")


## P6: the loop reads persisted records itself at _ready (the area's test
## replaces loop.records by hand instead of exercising this path).
func test_p6_loop_loads_records_on_ready() -> void:
	var r := RunRecords.new(REC)
	r.submit({"score": 4321, "peak_tier": 6, "peak_mass": 0.55, "catches": 9, "best_streak": 3,
			"victory": false, "duration_s": 100.0, "apex": {"reached_at": -1.0}})
	loop = GameLoop.new()
	loop.auto_step = false
	loop.records_path = REC
	loop.verbose = false
	add_child(loop)
	made.append(loop)
	eq(loop.get_run_stats()["best_score"], 4321, "a new GameLoop reads best score from user:// on _ready")
	eq(loop.get_run_stats()["best_tier"], 6, "... and best tier")


## P7: smoke test with the AI area's real Ecosystem/NpcBird on the flat base
## World (informational: another area's in-progress code). GameLoop must
## resolve NPC-vs-NPC catches on real NpcBirds without script errors and
## write highlights on real BirdModels.
func test_p7_real_ecosystem_smoke() -> void:
	var w := World.new()
	add_child(w)
	made.append(w)
	var p := _bird(0.03, Vector3(0, 30, 0), Vector3.FORWARD, true)
	var eco_scene: PackedScene = load("res://scenes/ai/ecosystem.tscn")
	var eco: Node = eco_scene.instantiate()
	add_child(eco)
	made.append(eco)
	_mk_loop()
	loop.auto_step = true
	await get_tree().process_frame
	loop.start_run()
	loop.set_protection(p, 600.0)
	var npc_npc := [0]
	var cb := func(pred: Bird, _q: Bird) -> void:
		if not pred.is_player():
			npc_npc[0] += 1
	Events.bird_caught.connect(cb)
	var hl := {0: 0, 1: 0, 2: 0}
	for i in 12:
		await get_tree().create_timer(1.0, false, true).timeout
		# fly the player through the crowd slowly so highlights get exercised
		p.global_position = p.global_position + Vector3(0, 0, -3)
	for b in Birds.all():
		var m: Variant = b.get(&"model")
		if m is Object and is_instance_valid(m) and "highlight" in m:
			hl[int(m.get(&"highlight"))] = int(hl.get(int(m.get(&"highlight")), 0)) + 1
	Events.bird_caught.disconnect(cb)
	loop.auto_step = false
	metric("npcs", Birds.count() - 1)
	metric("npc_catches_12s", npc_npc[0])
	metric("highlight_histogram", hl)
	metric("run_stats_npc_catches", loop.stats.npc_catches)
	gt(float(Birds.count()), 20.0, "the real ecosystem populated the sky")
