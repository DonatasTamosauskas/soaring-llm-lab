extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (round 2): determinism per seed over a longer, fuller run
## than the suite's (20 s, 30 NPCs, no catches): 60 NPCs, 90 s, a mock
## player flying laps, the stand-in catch rule on (catches, respawns and
## re-plans all happen). Two runs with reset(seed) must end in the same sky;
## a third with another seed must not. Also a run in a FRESH ecosystem
## instance with the same seed (no reset) must match (no hidden static state).


func _fingerprint(e: Ecosystem) -> String:
	var parts := []
	for n in e.get_npcs():
		parts.append("%s:%s:%s:%.4f" % [n.species, n.global_position.snapped(Vector3.ONE * 0.001), n.state, n.energy])
	return str(hash(",".join(parts))) + "/%d" % parts.size()


func _run(e: Ecosystem, p: Bird, seed_value: int, do_reset: bool) -> Array:
	if do_reset:
		e.reset(seed_value)
	var chk := make_checker()
	p.angle = 0.0
	p.mass = 0.1
	p.times_caught = 0
	p.set_meta(&"npc_ignore", false)
	p.step(0.0)
	for i in int(90.0 / DT):
		p.step(DT)
		e.step(DT)
		chk.step(DT)
	return [_fingerprint(e), chk.catches.size(), e.stats()["spawned"]]


func test_long_determinism() -> void:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 30.0
	p.speed = 12.0
	add_child(p)
	var e := make_eco(60, 21)
	e.focus = p
	var a := await _run(e, p, 21, true)
	var b := await _run(e, p, 21, true)
	var c := await _run(e, p, 22, true)
	e.queue_free()
	await wait_frames(2)
	var h := Habitat.for_world(world)
	var learned := h.thermals.filter(func(t: Dictionary) -> bool: return t["learned"]).size()
	print("[ai] v2r before fresh: npc_chasers meta on player = %s, learned thermals kept in the shared Habitat = %d, npc_ignore = %s" % [p.get_meta(&"npc_chasers", 0), learned, p.get_meta(&"npc_ignore", false)])
	var e2 := make_eco(60, 21)
	e2.focus = p
	var d := await _run(e2, p, 21, false)
	e2.queue_free()
	await wait_frames(2)
	# Same again with the two hidden states cleared by hand.
	p.set_meta(&"npc_chasers", 0)
	h.refresh()
	var e3 := make_eco(60, 21)
	e3.focus = p
	var g := await _run(e3, p, 21, false)
	print("[ai] v2r determinism a=%s b=%s c=%s fresh=%s fresh_cleared=%s" % [a, b, c, d, g])
	eq(a[0], g[0], "fresh Ecosystem after clearing npc_chasers + Habitat.refresh(): same sky")
	e2 = e3
	eq(a[0], b[0], "same seed after reset: same sky after 90 s with catches (%d catches)" % a[1])
	check(a[0] != c[0], "another seed: another sky")
	eq(a[0], d[0], "same seed in a fresh Ecosystem instance: same sky")
	e2.queue_free()
	remove_child(p)
	p.queue_free()
	await clear_sim()
