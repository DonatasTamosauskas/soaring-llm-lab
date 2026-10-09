extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (A3) beyond the builder's cases:
##  * a wren hunted by a sparrow next to the nest box (the 10 cm hole);
##  * a sparrow hunted by a *starling* (small predator, 0.40 m span) near a
##    hedge (refuge max span 0.30);
##  * a hawk stooping from behind and above on a pigeon: the prey must not
##    react before the hawk is inside its awareness radius, and must react
##    before contact or within reaction time of entering its (reduced,
##    rear/above) awareness.

func _cover_trials(prey_sp: StringName, hunter_sp: StringName, refuge_filter: Callable, trials: int) -> Dictionary:
	var h := Habitat.for_world(world)
	var rs: Array = []
	for r in h.refuges:
		if refuge_filter.call(r):
			rs.append(r)
	var res := {"trials": trials, "hid": 0, "caught": 0, "headed": 0, "refuges": rs.size()}
	if rs.is_empty():
		return res
	for t in trials:
		var r: Dictionary = rs[t % rs.size()]
		var rp: Vector3 = r["position"]
		var a := TAU * (t + 0.5) / trials
		var start := rp + Vector3(cos(a) * 10.0, 3.0, sin(a) * 10.0)
		var prey := spawn(prey_sp, start, Vector3(-sin(a), 0, cos(a)) * 8.0)
		prey.can_hunt = false
		var hunter := spawn(hunter_sp, start + Vector3(cos(a) * 22.0, 4.0, sin(a) * 22.0), -Vector3(cos(a), 0, sin(a)) * 10.0)
		hunter.can_flee = false
		hunter.hunger = 1.0
		hunter.brain._pending_prey = prey
		hunter.brain._enter(NpcBird.State.HUNT)
		make_checker()
		var m := {"headed": false}
		run(20.0, func(_i: int) -> bool:
			if prey.state == NpcBird.State.FLEE and not prey.refuge.is_empty() and prey.velocity.length() > 1.0:
				var to_r: Vector3 = prey.refuge["position"] - prey.global_position
				if prey.velocity.normalized().dot(to_r.normalized()) > 0.8:
					m["headed"] = true
			return not prey.alive or prey.hidden)
		res["hid"] += 1 if prey.hidden else 0
		res["caught"] += 0 if prey.alive else 1
		res["headed"] += 1 if m["headed"] else 0
		despawn(prey)
		despawn(hunter)
		checker = null
		await wait_frames(1)
	return res


func test_wren_nest_box_and_sparrow_hedge_vs_small_hunters() -> void:
	await make_world(false, 1)
	var nb := await _cover_trials(&"wren", &"sparrow", func(r: Dictionary) -> bool: return float(r["max_span"]) <= 0.2, 8)
	print("[ai-verify] wren vs sparrow at nest box: ", nb)
	var hg := await _cover_trials(&"sparrow", &"starling", func(r: Dictionary) -> bool: return float(r["max_span"]) > 0.2 and float(r["max_span"]) <= 0.3, 8)
	print("[ai-verify] sparrow vs starling at hedges: ", hg)
	metric("nest_box", nb)
	metric("hedge", hg)
	gt(nb["hid"] + nb["caught"], 0, "something happened at the nest box")
	gt(float(nb["hid"]) / nb["trials"], 0.5, "wrens reach the nest box most of the time")
	gt(float(hg["hid"]) / hg["trials"], 0.5, "sparrows reach a hedge gap most of the time (starling hunter)")
	await clear_sim()


func test_stoop_from_behind_above() -> void:
	var open := await make_open_world()
	var aw: float = SpeciesProfile.of(&"pigeon")["awareness_m"]
	var react: float = SpeciesProfile.of(&"pigeon")["reaction_s"]
	var rows := []
	var early := 0
	var never := 0
	for t in 6:
		var prey := spawn(&"pigeon", Vector3(0, 60, 0), Vector3(0, 0, -11), open)
		prey.can_hunt = false
		prey.home = Vector3(0, 0, -3000)
		prey.brain._goal = Vector3(0, 60, -3000)
		prey.brain._goal_t = -999.0
		var hawk := spawn(&"hawk", Vector3(3.0 * (t - 3), 95.0, 45.0 + 5.0 * t), Vector3(0, 0, -17), open)
		hawk.can_flee = false
		hawk.hunger = 1.0
		hawk.brain._pending_prey = prey
		hawk.brain._enter(NpcBird.State.HUNT)
		make_checker()
		var m := {"enter": -1.0, "flee": -1.0, "d_flee": -1.0, "caught": false}
		run(15.0, func(i: int) -> bool:
			var d := prey.global_position.distance_to(hawk.global_position)
			var tt := (i + 1) * DT
			if m["enter"] < 0.0 and d <= aw:
				m["enter"] = tt
			if prey.state == NpcBird.State.FLEE and m["flee"] < 0.0:
				m["flee"] = tt
				m["d_flee"] = d
			if not prey.alive:
				m["caught"] = true
			return m["flee"] >= 0.0 or not prey.alive)
		if m["flee"] >= 0.0 and m["enter"] < 0.0:
			early += 1
		if m["flee"] < 0.0 and not m["caught"]:
			never += 1
		rows.append(m)
		despawn(prey)
		despawn(hawk)
		checker = null
	print("[ai-verify] stoop from behind-above (aw %.0f m, reaction %.2f s): %s" % [aw, react, rows])
	metric("stoop_rows", rows)
	eq(early, 0, "no reaction before the hawk is within awareness range")
	eq(never, 0, "the pigeon either reacted or was caught")
	open.queue_free()
	await clear_sim()
