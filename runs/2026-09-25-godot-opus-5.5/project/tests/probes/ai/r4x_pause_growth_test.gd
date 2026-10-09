extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 4, requirements lens), in the AI arena:
##  1. pause: the brief's "pausing" - Game.PAUSED sets get_tree().paused and
##     gameplay (AI) must be pausable (ARCHITECTURE section 4). With the
##     Ecosystem auto-stepping on real physics frames, pausing the tree must
##     freeze every NPC (position, flap animation) and unpausing resume it.
##  2. NPC growth: GameLoop grows an NPC predator after a meal
##     (pred.mass = new_mass at any time, contract). The bird's flight
##     envelope and model scale must follow the new mass (A4 holds for the
##     grown bird too): top speed in a tucked dive and level cruise within
##     10% of SizeRules.performance(new mass).
## Report: artifacts/ai/verify/r4/pause_growth.json
##   tools/gd.sh ai_verify2 --headless res://tests/runner.tscn -- --dir=res://tests/probes/ai --suite=r4x_pause_growth

var _out := {}


func after_all() -> void:
	var dir := Paths.artifacts("ai").path_join("verify/r4")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("pause_growth.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(_out, "  "))
	f.close()


func test_r4x_pause_freezes_the_sky() -> void:
	await make_world(false, 1)
	var e := make_eco(60, 5)
	# The test runner is PROCESS_MODE_ALWAYS (tests run while paused); in the
	# game the Ecosystem sits under Main, which inherits the pausable root.
	e.process_mode = Node.PROCESS_MODE_PAUSABLE
	e.auto_step = true
	await wait_physics(150)
	check(e.count() > 50, "(setup) the sky is populated on real physics frames (%d)" % e.count())
	var pos := {}
	var phase := {}
	for n in e.get_npcs():
		pos[n.get_instance_id()] = n.global_position
		if n.model:
			phase[n.get_instance_id()] = n.model.flap_phase
	get_tree().paused = true
	await wait_physics(60)
	await wait_frames(10)
	var moved := 0
	var flapped := 0
	for n in e.get_npcs():
		var id := n.get_instance_id()
		if pos.has(id) and n.global_position.distance_to(pos[id]) > 1e-4:
			moved += 1
		if phase.has(id) and n.model and absf(n.model.flap_phase - float(phase[id])) > 1e-5:
			flapped += 1
	var t_paused: float = e.stats()["time"]
	await wait_physics(30)
	var t_paused2: float = e.stats()["time"]
	get_tree().paused = false
	await wait_physics(60)
	var moved_after := 0
	for n in e.get_npcs():
		var id := n.get_instance_id()
		if pos.has(id) and n.global_position.distance_to(pos[id]) > 0.05:
			moved_after += 1
	_out["pause"] = {"moved_while_paused": moved, "flapped_while_paused": flapped,
		"eco_time_advanced_while_paused": t_paused2 - t_paused, "moved_after_unpause": moved_after, "npcs": e.count()}
	print("[ai-r4x] pause: %s" % JSON.stringify(_out["pause"]))
	eq(moved, 0, "no NPC moves while the tree is paused")
	eq(flapped, 0, "no NPC wing animation runs while paused")
	near(t_paused2 - t_paused, 0.0, 1e-6, "the ecosystem clock stops while paused")
	gt(moved_after, 40, "NPCs fly on after unpausing")
	e.queue_free()
	eco = null
	await clear_sim()


func test_r4x_grown_predator_flies_its_new_size() -> void:
	var w := await make_open_world()
	var rows := {}
	for c in [[&"hawk", 2.2], [&"crow", 0.8], [&"sparrow", 0.05]]:
		var sp: StringName = c[0]
		var m1: float = c[1]
		var n := spawn(sp, Vector3(0, 400, 0), Vector3.ZERO, w)
		n.can_hunt = false
		n.can_flee = false
		# Fly a little at the old size, then grow as GameLoop would after a meal.
		for i in 72:
			n.tick(DT)
		n.mass = m1
		var perf := SizeRules.performance(m1)
		var span := SizeRules.wingspan_for_mass(m1)
		# The flight model itself: a tucked dive's top speed and level cruise.
		var f := n.flight
		var fm := NpcFlight.new(m1, float(SpeciesProfile.of(sp)["glide_ratio"]))
		fm.set_velocity(Vector3(0, 0, -fm.cruise))
		var top := 0.0
		for i in int(25.0 / DT):
			fm.step(DT, Vector3(0, -1, -0.05), 999.0, 0.0, 1.0)
			top = maxf(top, fm.speed)
		var row := {"new_mass": m1, "flight_mass": f.mass, "flight_max_speed": f.max_speed, "perf_max_speed": perf["max_speed"],
			"flight_cruise": f.cruise, "perf_cruise": perf["cruise"], "flight_turn": f.turn_rate, "perf_turn": perf["turn_rate"],
			"model_scale": n.model.scale.x if n.model else -1.0, "wingspan": span, "dive_top": top}
		rows[String(sp)] = row
		near(f.mass, m1, 1e-6, "%s: flight model takes the new mass" % sp)
		near(f.max_speed, perf["max_speed"], perf["max_speed"] * 0.1, "%s: max speed follows the new mass" % sp)
		near(f.cruise, perf["cruise"], perf["cruise"] * 0.1, "%s: cruise follows the new mass" % sp)
		near(f.turn_rate, perf["turn_rate"], perf["turn_rate"] * 0.1, "%s: turn rate follows the new mass" % sp)
		near(top, perf["max_speed"], perf["max_speed"] * 0.1, "%s: tucked dive top speed at the new mass" % sp)
		if n.model:
			near(n.model.scale.x, span, span * 0.01, "%s: model scale follows the new wingspan" % sp)
		# And the grown bird keeps flying sanely.
		for i in int(10.0 / DT):
			n.tick(DT)
		check(is_finite(n.global_position.y) and n.flight.speed <= perf["max_speed"] * 1.001, "%s: flies on within its new envelope" % sp)
		despawn(n)
	_out["growth"] = rows
	print("[ai-r4x] growth: %s" % JSON.stringify(rows))
	w.queue_free()
	await clear_sim()
