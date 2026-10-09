extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): is the Ecosystem deterministic per seed ACROSS
## PROCESSES (the brief: "deterministic with a seed")? Runs one seeded
## scenario (60 NPCs, 60 s, mock player laps, no catches) and prints a
## fingerprint of the sky plus the order Ecosystem._rebalance iterates the
## plan keys in (it sorts an Array of StringName keys; Godot orders
## StringNames by pointer, not by text). Run this probe in two or more
## separate processes and compare the printed lines.


func _fingerprint(e: Ecosystem) -> String:
	var parts := []
	for n in e.get_npcs():
		parts.append("%s:%s:%s" % [n.species, n.global_position.snapped(Vector3.ONE * 0.001), n.state])
	return str(hash(",".join(parts))) + "/%d" % parts.size()


func test_cross_process_fingerprint() -> void:
	# Allocate some unrelated StringNames first so the heap layout differs a
	# little from run to run, as it would in a real game session.
	var junk := []
	for i in int(Paths.arg("junk", "0")):
		junk.append(StringName("junk_%d_%d" % [i, Time.get_ticks_usec()]))
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	p.mass = 0.09
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 42)
	e.focus = p
	var order := []
	for i in int(60.0 / DT):
		p.step(DT)
		e.step(DT)
		if i == 0:
			var keys := e._plan.keys()
			keys.sort()
			order = keys.map(func(k: StringName) -> String: return String(k))
	var text_sorted := order.duplicate()
	text_sorted.sort()
	print("[ai] v2r crossproc fingerprint=%s plan_key_order=%s text_order_matches=%s" % [_fingerprint(e), ",".join(order), order == text_sorted])
	check(true, "ran")
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await clear_sim()
