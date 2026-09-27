extends "res://tests/unit/ai/ai_sim.gd"
## VERIFIER PROBE (A7 at the start of a run). A sparrow-sized mock player
## (the game's START_MASS 0.03 kg) flies laps at a sparrow's cruise (9 m/s)
## inside a 60-NPC ecosystem for 180 s. How often does anything start a hunt
## on it, compared with NPC birds of the same species ("the player is just
## another bird")?

func _run(seed_value: int, pm: float, speed: float) -> Dictionary:
	await make_world(false, 1)
	var p := MockPlayer.new()
	p.mass = pm
	p.path_center = Vector3(-20, 0, 10)
	p.path_radius = 110.0
	p.path_height = 20.0
	p.speed = speed
	add_child(p)
	p.step(0.0)
	var e := make_eco(60, seed_value)
	e.focus = p
	var hunting := {}
	var on_player := 0
	var on_same := 0
	var same_bird_s := 0.0
	var hunters := {}
	var species := SizeRules.species_for_mass(pm)
	for i in int(180.0 / DT):
		p.step(DT)
		e.step(DT)
		for n in e.get_npcs():
			if n.species == species:
				same_bird_s += DT
			var id := n.get_instance_id()
			var tgt: Bird = n.target if is_instance_valid(n.target) else null
			var key := tgt.get_instance_id() if tgt else 0
			if tgt != null and hunting.get(id, 0) != key:
				if tgt == p:
					on_player += 1
					hunters[String(n.species)] = hunters.get(String(n.species), 0) + 1
				elif tgt.species == species:
					on_same += 1
			hunting[id] = key
	var r := {"species": String(species), "hunts_on_player": on_player, "player_hunted_by": hunters,
		"hunts_on_npc_same_species": on_same, "npc_same_species_minutes": snappedf(same_bird_s / 60.0, 0.1),
		"hunts_per_player_minute": snappedf(on_player / 3.0, 0.01),
		"hunts_per_npc_same_species_minute": snappedf(on_same / maxf(same_bird_s / 60.0, 0.01), 0.01)}
	e.queue_free()
	eco = null
	remove_child(p)
	p.queue_free()
	await clear_sim()
	return r


func test_sparrow_player_is_hunted_like_an_npc_sparrow() -> void:
	var rows := {}
	for c in [[5, 0.03, 9.0], [9, 0.03, 9.0], [5, 0.1, 11.0], [5, 0.3, 13.0]]:
		var r := await _run(c[0], c[1], c[2])
		rows["seed%d_%.2f" % [c[0], c[1]]] = r
		print("[ai-verify] hunted seed %d player %.2f kg @ %.0f m/s: %s" % [c[0], c[1], c[2], r])
		gt(r["hunts_on_player"], 0, "seed %d %.2f kg: something hunted the player in 3 minutes" % [c[0], c[1]])
	metric("hunted", rows)
