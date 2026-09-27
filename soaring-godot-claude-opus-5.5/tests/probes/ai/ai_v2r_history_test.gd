extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): does a seeded scenario depend on what ran
## before it in the same process? Scenario X (AI test world, fresh World +
## fresh Ecosystem, seed 3, crow-sized mock player, 60 s) is run first, then
## after scenarios with other player sizes (other plans, other masses), then
## again after clearing NpcFlight's static level-table cache. Prints each
## fingerprint and the order the plan keys are spawned in.


func _fingerprint(e: Ecosystem) -> String:
	var parts := []
	for n in e.get_npcs():
		parts.append("%s:%s:%s" % [n.species, n.global_position.snapped(Vector3.ONE * 0.001), n.state])
	return str(hash(",".join(parts))) + "/%d" % parts.size()


func _scenario(pm: float, seconds: float) -> Array:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.mass = pm
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 90.0
	p.path_height = 30.0
	p.speed = 11.0
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, 3)
	e.focus = p
	var order := ""
	for i in int(seconds / DT):
		p.step(DT)
		e.step(DT)
		if i == 0:
			var keys := e._plan.keys()
			keys.sort()
			order = ",".join(keys.map(func(k: StringName) -> String: return String(k)))
	var fp := _fingerprint(e)
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await clear_sim()
	return [fp, order]


func test_history_independence() -> void:
	var a := await _scenario(0.5, 60.0)
	await _scenario(0.03, 30.0)
	await _scenario(1.3, 30.0)
	await _scenario(3.0, 30.0)
	var b := await _scenario(0.5, 60.0)
	NpcFlight._table_cache.clear()
	var c := await _scenario(0.5, 60.0)
	print("[ai] v2r history first=%s after_others=%s after_cache_clear=%s" % [a, b, c])
	eq(a[0], b[0], "same seeded scenario gives the same sky after other scenarios ran in the process")
	eq(a[0], c[0], "and after clearing NpcFlight's static table cache")
