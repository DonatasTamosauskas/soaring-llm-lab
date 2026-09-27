extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): Ecosystem._rebalance spawns plan keys in the
## order of `keys.sort()` on StringName keys, which Godot orders by pointer,
## not text. Plan keys like &"crow:hunter" are built at run time; once a
## re-plan drops them they are freed, and re-created later at another
## address. So after reset(seed) the same seed can spawn in another order -
## another sky. Here: seed 42 at starling size, then other player sizes
## (other plans), then seed 42 at starling size again - same sky?


func _fingerprint(e: Ecosystem) -> String:
	var parts := []
	for n in e.get_npcs():
		parts.append("%s:%s:%s" % [n.species, n.global_position.snapped(Vector3.ONE * 0.001), n.state])
	return str(hash(",".join(parts))) + "/%d" % parts.size()


func _run(e: Ecosystem, p: Bird, seed_value: int, pm: float) -> Array:
	e.reset(seed_value)
	p.angle = 0.0
	p.mass = pm
	p.step(0.0)
	var order := []
	for i in int(30.0 / DT):
		p.step(DT)
		e.step(DT)
		if i == 0:
			var keys := e._plan.keys()
			keys.sort()
			order = keys.map(func(k: StringName) -> String: return String(k))
	return [_fingerprint(e), ",".join(order)]


func test_same_seed_same_sky_after_other_runs() -> void:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	add_child(p)
	var e := make_eco(60, 42)
	e.focus = p
	var first := await _run(e, p, 42, 0.09)
	var mismatches := 0
	var rows := [first]
	for pm: float in [1.3, 0.5, 3.0, 0.03, 0.3]:
		await _run(e, p, 7, pm)
		# Let freed StringNames go and the heap churn a little.
		for k in 200:
			var _s := StringName("churn_%d_%f" % [k, pm])
		var again := await _run(e, p, 42, 0.09)
		rows.append(again)
		if again[0] != first[0]:
			mismatches += 1
	for r in rows:
		print("[ai] v2r reset-order fingerprint=%s order=%s" % r)
	eq(mismatches, 0, "seed 42 gives the same sky every time it is reset to (%d of 5 differed)" % mismatches)
	e.queue_free()
	remove_child(p)
	p.queue_free()
	await clear_sim()
